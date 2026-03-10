#!/bin/bash
# =============================================================================
# Multi-Environment Benchmark Deployment & Orchestration
#
# Builds Singularity images for each GPU architecture, deploys to remote
# clusters, and runs benchmarks automatically.
#
# Environments:
#   MI300X (gfx942) - PCAD UFRGS / Grid5000
#   MI210  (gfx90a) - Grid5000
#   MI50   (gfx906) - Grid5000
#   RX 7900 XT (gfx1100) - Grid5000
#
# Usage:
#   ./scripts/deploy_benchmarks.sh [build|deploy|run|collect|all] [OPTIONS]
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_info()   { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()  { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() { echo -e "${BLUE}${BOLD}=== $1 ===${NC}"; }
print_step()   { echo -e "${CYAN}[STEP]${NC} $1"; }

# ==================== Environment Definitions ====================
# Configure these for your clusters
# Format: ENV_NAME|GPU_ARCH|SSH_HOST|REMOTE_WORKDIR|RSF_DIR|NOTES

# Default environment configurations - EDIT THESE for your setup
declare -A ENV_CONFIGS
ENV_CONFIGS=(
    ["MI300X"]="gfx942|user@pcad.inf.ufrgs.br|/home/user/hipcomp|/home/user/fletcher-io/original/run|PCAD UFRGS"
    ["MI210"]="gfx90a|user@grid5000-mi210.example|/home/user/hipcomp|/home/user/fletcher-io/original/run|Grid5000"
    ["MI50"]="gfx906|user@grid5000-mi50.example|/home/user/hipcomp|/home/user/fletcher-io/original/run|Grid5000"
    ["RX7900XT"]="gfx1100|user@grid5000-rx7900.example|/home/user/hipcomp|/home/user/fletcher-io/original/run|Grid5000"
)

# Override with config file if present
CONFIG_FILE="${PROJECT_ROOT}/environments.conf"

# ==================== Help ====================
show_help() {
    cat << 'EOF'
Multi-Environment Benchmark Deployment & Orchestration

USAGE:
    ./scripts/deploy_benchmarks.sh COMMAND [OPTIONS]

COMMANDS:
    build       Build Singularity images for all GPU architectures
    deploy      Copy images and scripts to remote environments
    run         Execute benchmarks on remote environments (via SSH)
    collect     Collect results from all environments
    all         Run build + deploy + run + collect
    local       Run benchmarks on the current machine (no SSH)
    status      Check GPU availability on all environments
    config      Show/edit environment configuration

OPTIONS:
    -e, --env ENV       Target specific environment (MI300X, MI210, MI50, RX7900XT)
    -c, --config FILE   Config file with environment definitions
    -a, --algorithms    Algorithms to benchmark (default: "lz4 snappy cascaded")
    -i, --iterations N  Benchmark iterations (default: 10)
    --rsf-dir DIR       RSF data directory on remote host
    --dry-run           Show commands without executing
    -h, --help          Show this help

CONFIGURATION:
    Create environments.conf in the project root with format:
    
    # environments.conf
    MI300X_ARCH=gfx942
    MI300X_HOST=user@pcad.inf.ufrgs.br
    MI300X_WORKDIR=/home/user/hipcomp
    MI300X_RSF=/home/user/fletcher-io/original/run
    MI300X_NOTES="PCAD UFRGS"
    
    MI210_ARCH=gfx90a
    MI210_HOST=user@grid5000-node
    MI210_WORKDIR=/home/user/hipcomp
    MI210_RSF=/data/fletcher-io/original/run
    MI210_NOTES="Grid5000 Lyon"
    
    # ... same for MI50 and RX7900XT

EXAMPLES:
    # Build all Singularity images
    ./scripts/deploy_benchmarks.sh build

    # Build only MI300X image
    ./scripts/deploy_benchmarks.sh build -e MI300X

    # Run benchmarks locally (auto-detect GPU)
    ./scripts/deploy_benchmarks.sh local

    # Full pipeline: build, deploy, run, collect
    ./scripts/deploy_benchmarks.sh all

    # Collect results from all environments
    ./scripts/deploy_benchmarks.sh collect

EOF
}

# ==================== Parse Config File ====================
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        print_info "Loading config from: $CONFIG_FILE"
        source "$CONFIG_FILE"
        
        # Rebuild ENV_CONFIGS from config variables
        for env_name in MI300X MI210 MI50 RX7900XT; do
            local arch_var="${env_name}_ARCH"
            local host_var="${env_name}_HOST"
            local workdir_var="${env_name}_WORKDIR"
            local rsf_var="${env_name}_RSF"
            local notes_var="${env_name}_NOTES"
            
            if [ -n "${!arch_var}" ] && [ -n "${!host_var}" ]; then
                ENV_CONFIGS[$env_name]="${!arch_var}|${!host_var}|${!workdir_var:-/tmp/hipcomp}|${!rsf_var:-}|${!notes_var:-}"
            fi
        done
    fi
}

# ==================== Parse Arguments ====================
COMMAND="${1:-help}"
shift || true

TARGET_ENV=""
ALGORITHMS="lz4 snappy cascaded"
ITERATIONS=10
DRY_RUN=false
CUSTOM_RSF=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--env)       TARGET_ENV="$2"; shift 2 ;;
        -c|--config)    CONFIG_FILE="$2"; shift 2 ;;
        -a|--algorithms) ALGORITHMS="$2"; shift 2 ;;
        -i|--iterations) ITERATIONS="$2"; shift 2 ;;
        --rsf-dir)      CUSTOM_RSF="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        -h|--help)      show_help; exit 0 ;;
        *)              print_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

load_config

# Helper: get field from ENV_CONFIGS
get_env_field() {
    local env_name="$1"
    local field_num="$2"  # 1=arch, 2=host, 3=workdir, 4=rsf, 5=notes
    echo "${ENV_CONFIGS[$env_name]}" | cut -d'|' -f"$field_num"
}

# List of environments to process
get_target_envs() {
    if [ -n "$TARGET_ENV" ]; then
        echo "$TARGET_ENV"
    else
        echo "MI300X MI210 MI50 RX7900XT"
    fi
}

# ==================== COMMAND: build ====================
cmd_build() {
    print_header "Building Singularity Images"
    
    local def_file="$PROJECT_ROOT/../defhip_benchmark.def"
    if [ ! -f "$def_file" ]; then
        # Try project root
        def_file="$PROJECT_ROOT/defhip_benchmark.def"
    fi
    
    if [ ! -f "$def_file" ]; then
        print_error "Singularity definition not found: $def_file"
        print_info "Expected at: $(dirname $PROJECT_ROOT)/defhip_benchmark.def"
        exit 1
    fi
    
    local build_dir="$PROJECT_ROOT/build_singularity"
    mkdir -p "$build_dir"
    
    for env_name in $(get_target_envs); do
        local arch=$(get_env_field "$env_name" 1)
        local sif_file="$build_dir/hipcomp_${env_name}_${arch}.sif"
        
        if [ -f "$sif_file" ]; then
            print_warn "$sif_file already exists, skipping (delete to rebuild)"
            continue
        fi
        
        print_step "Building image for $env_name ($arch)..."
        
        if [ "$DRY_RUN" = "true" ]; then
            echo "  [DRY-RUN] singularity build --build-arg GPU_ARCH=$arch $sif_file $def_file"
        else
            singularity build --build-arg GPU_ARCH="$arch" "$sif_file" "$def_file"
        fi
        
        print_info "Built: $sif_file"
        echo ""
    done
    
    print_info "All images built in: $build_dir"
}

# ==================== COMMAND: deploy ====================
cmd_deploy() {
    print_header "Deploying to Remote Environments"
    
    local build_dir="$PROJECT_ROOT/build_singularity"
    
    for env_name in $(get_target_envs); do
        local arch=$(get_env_field "$env_name" 1)
        local host=$(get_env_field "$env_name" 2)
        local workdir=$(get_env_field "$env_name" 3)
        local sif_file="$build_dir/hipcomp_${env_name}_${arch}.sif"
        
        print_step "Deploying to $env_name ($host)..."
        
        if [ ! -f "$sif_file" ]; then
            print_warn "Image not found: $sif_file (run 'build' first)"
            continue
        fi
        
        if [ "$DRY_RUN" = "true" ]; then
            echo "  [DRY-RUN] ssh $host 'mkdir -p $workdir'"
            echo "  [DRY-RUN] scp $sif_file $host:$workdir/"
            echo "  [DRY-RUN] scp scripts/run_benchmarks_auto.sh $host:$workdir/"
        else
            ssh "$host" "mkdir -p $workdir/results $workdir/testdata $workdir/scripts"
            scp "$sif_file" "$host:$workdir/"
            scp "$SCRIPT_DIR/run_benchmarks_auto.sh" "$host:$workdir/scripts/"
            scp "$SCRIPT_DIR/convert_rsf_to_binary.py" "$host:$workdir/scripts/"
            scp "$SCRIPT_DIR/prepare_rsf_testdata.sh" "$host:$workdir/scripts/"
            scp "$SCRIPT_DIR/singularity_entrypoint.sh" "$host:$workdir/scripts/"
        fi
        
        print_info "Deployed to $env_name"
        echo ""
    done
}

# ==================== COMMAND: run ====================
cmd_run() {
    print_header "Launching Benchmarks on Remote Environments"
    
    for env_name in $(get_target_envs); do
        local arch=$(get_env_field "$env_name" 1)
        local host=$(get_env_field "$env_name" 2)
        local workdir=$(get_env_field "$env_name" 3)
        local rsf_dir=$(get_env_field "$env_name" 4)
        [ -n "$CUSTOM_RSF" ] && rsf_dir="$CUSTOM_RSF"
        local sif_name="hipcomp_${env_name}_${arch}.sif"
        
        print_step "Running on $env_name ($host)..."
        
        # Build the run command
        local run_cmd="cd $workdir && singularity run"
        
        # Bind mounts
        run_cmd="$run_cmd --bind $workdir/testdata:/opt/arcto/testdata"
        run_cmd="$run_cmd --bind $workdir/results:/opt/arcto/results"
        
        if [ -n "$rsf_dir" ]; then
            run_cmd="$run_cmd --bind $rsf_dir:/rsf"
            run_cmd="$run_cmd $sif_name -r /rsf -a '$ALGORITHMS' -i $ITERATIONS"
        else
            run_cmd="$run_cmd $sif_name -a '$ALGORITHMS' -i $ITERATIONS"
        fi
        
        if [ "$DRY_RUN" = "true" ]; then
            echo "  [DRY-RUN] ssh $host '$run_cmd'"
        else
            print_info "Executing: ssh $host '...'"
            ssh "$host" "$run_cmd" 2>&1 | tee "$PROJECT_ROOT/results/remote_${env_name}.log" || {
                print_warn "Remote execution returned non-zero on $env_name"
            }
        fi
        
        print_info "Completed $env_name"
        echo ""
    done
}

# ==================== COMMAND: collect ====================
cmd_collect() {
    print_header "Collecting Results from All Environments"
    
    local collect_dir="$PROJECT_ROOT/results/collected_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$collect_dir"
    
    # Combined CSV
    local combined_csv="$collect_dir/all_results.csv"
    echo "Algorithm,TestFile,FileSizeBytes,FileSizeMB,ChunkSize,CompressionRatio,CompThroughputGBs,DecompThroughputGBs,Platform,GPU,GPUArch,EnvLabel,Iterations,Warmup,Timestamp" > "$combined_csv"
    
    for env_name in $(get_target_envs); do
        local host=$(get_env_field "$env_name" 2)
        local workdir=$(get_env_field "$env_name" 3)
        
        print_step "Collecting from $env_name ($host)..."
        
        local env_dir="$collect_dir/$env_name"
        mkdir -p "$env_dir"
        
        if [ "$DRY_RUN" = "true" ]; then
            echo "  [DRY-RUN] scp -r $host:$workdir/results/* $env_dir/"
        else
            scp -r "$host:$workdir/results/*" "$env_dir/" 2>/dev/null || {
                print_warn "  Could not fetch results from $env_name"
                continue
            }
            
            # Append to combined CSV (skip headers)
            find "$env_dir" -name "results.csv" -exec tail -n +2 {} \; >> "$combined_csv"
        fi
        
        print_info "  Collected from $env_name"
    done
    
    echo ""
    print_info "Combined results: $combined_csv"
    
    # Print summary
    if [ -s "$combined_csv" ]; then
        print_header "Cross-Environment Summary"
        echo ""
        echo "Environment | Algorithm | Avg Ratio | Avg Comp GB/s | Avg Decomp GB/s"
        echo "------------|-----------|-----------|---------------|----------------"
        
        # Simple summary using awk
        tail -n +2 "$combined_csv" | grep -v "FAILED\|ERROR\|PARSE" | \
            awk -F',' '{
                key = $12 "|" $1
                ratio[key] += $6
                comp[key] += $7
                decomp[key] += $8
                count[key]++
            }
            END {
                for (k in count) {
                    split(k, parts, "|")
                    printf "%-11s | %-9s | %9.2f | %13.2f | %s\n", 
                        parts[1], parts[2], 
                        ratio[k]/count[k], comp[k]/count[k], decomp[k]/count[k]
                }
            }' | sort
        echo ""
    fi
    
    print_info "All results collected to: $collect_dir"
}

# ==================== COMMAND: local ====================
cmd_local() {
    print_header "Running Benchmarks Locally"
    
    local rsf_arg=""
    if [ -n "$CUSTOM_RSF" ]; then
        rsf_arg="-r $CUSTOM_RSF"
    elif [ -d "$PROJECT_ROOT/../fletcher-io/original/run" ]; then
        rsf_arg="-r $PROJECT_ROOT/../fletcher-io/original/run"
    fi
    
    local dry_arg=""
    [ "$DRY_RUN" = "true" ] && dry_arg="--dry-run"
    
    exec "$SCRIPT_DIR/run_benchmarks_auto.sh" \
        -a "$ALGORITHMS" \
        -i "$ITERATIONS" \
        $rsf_arg \
        $dry_arg
}

# ==================== COMMAND: status ====================
cmd_status() {
    print_header "Environment Status"
    echo ""
    printf "%-10s | %-8s | %-30s | %s\n" "Env" "Arch" "Host" "Status"
    echo "-----------|----------|--------------------------------|--------"
    
    for env_name in $(get_target_envs); do
        local arch=$(get_env_field "$env_name" 1)
        local host=$(get_env_field "$env_name" 2)
        
        local status="?"
        if [ "$DRY_RUN" = "true" ] || [ "$host" = "user@pcad.inf.ufrgs.br" ] || [[ "$host" == *"example"* ]]; then
            status="NOT CONFIGURED"
        else
            if ssh -o ConnectTimeout=5 "$host" "rocm-smi --showproductname 2>/dev/null | head -1" 2>/dev/null; then
                status="OK"
            else
                status="UNREACHABLE"
            fi
        fi
        
        printf "%-10s | %-8s | %-30s | %s\n" "$env_name" "$arch" "$host" "$status"
    done
    echo ""
    print_info "Edit $CONFIG_FILE to configure SSH hosts"
}

# ==================== COMMAND: config ====================
cmd_config() {
    print_header "Environment Configuration"
    echo ""
    
    if [ -f "$CONFIG_FILE" ]; then
        print_info "Current config ($CONFIG_FILE):"
        cat "$CONFIG_FILE"
    else
        print_warn "No config file found. Creating template..."
        cat > "$CONFIG_FILE" << 'CONF'
# =============================================================================
# hipCOMP Benchmark Environment Configuration
# =============================================================================
# Edit the SSH hosts and paths for each GPU environment.
# The deploy_benchmarks.sh script uses these to automate benchmarks.

# --- MI300X (gfx942) ---
MI300X_ARCH=gfx942
MI300X_HOST=user@pcad.inf.ufrgs.br
MI300X_WORKDIR=/home/user/hipcomp
MI300X_RSF=/home/user/fletcher-io/original/run
MI300X_NOTES="PCAD UFRGS"

# --- MI210 (gfx90a) ---
MI210_ARCH=gfx90a
MI210_HOST=user@grid5000-mi210-node
MI210_WORKDIR=/home/user/hipcomp
MI210_RSF=/home/user/fletcher-io/original/run
MI210_NOTES="Grid5000"

# --- MI50 (gfx906) ---
MI50_ARCH=gfx906
MI50_HOST=user@grid5000-mi50-node
MI50_WORKDIR=/home/user/hipcomp
MI50_RSF=/home/user/fletcher-io/original/run
MI50_NOTES="Grid5000"

# --- RX 7900 XT (gfx1100) ---
RX7900XT_ARCH=gfx1100
RX7900XT_HOST=user@grid5000-rx7900-node
RX7900XT_WORKDIR=/home/user/hipcomp
RX7900XT_RSF=/home/user/fletcher-io/original/run
RX7900XT_NOTES="Grid5000"
CONF
        print_info "Template created: $CONFIG_FILE"
        print_info "Edit it with your actual SSH hosts and paths"
    fi
}

# ==================== Main Dispatch ====================
case "$COMMAND" in
    build)   cmd_build ;;
    deploy)  cmd_deploy ;;
    run)     cmd_run ;;
    collect) cmd_collect ;;
    all)
        cmd_build
        cmd_deploy
        cmd_run
        cmd_collect
        ;;
    local)   cmd_local ;;
    status)  cmd_status ;;
    config)  cmd_config ;;
    help|-h|--help)
        show_help
        ;;
    *)
        print_error "Unknown command: $COMMAND"
        show_help
        exit 1
        ;;
esac
