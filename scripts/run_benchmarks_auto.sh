#!/bin/bash
# =============================================================================
# Automated Benchmark Runner for hipCOMP compression algorithms
# Runs LZ4, Snappy, and Cascaded benchmarks systematically
#
# Usage:
#   ./scripts/run_benchmarks_auto.sh [OPTIONS]
#
# Can be used standalone or inside a Singularity container.
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

# -------------------- Default Parameters --------------------
TESTDATA_DIR="${TESTDATA_DIR:-$PROJECT_ROOT/testdata}"
RESULTS_DIR="${RESULTS_DIR:-$PROJECT_ROOT/results}"
ALGORITHMS="${ALGORITHMS:-lz4 snappy cascaded}"
ITERATIONS=10
WARMUP=2
GPU_DEVICE=0
CHUNK_SIZES="65536"  # Default 64KB compression chunk
RSF_DIR=""           # Optional: RSF source directory for auto-generation
RSF_START_FRACTION=0.5  # Extract from middle of simulation
SKIP_TESTDATA_GEN=false
DRY_RUN=false

# -------------------- Help --------------------
show_help() {
    cat << 'EOF'
Usage: run_benchmarks_auto.sh [OPTIONS]

Run LZ4, Snappy, and Cascaded compression benchmarks automatically.
Optionally generates test data from RSF files.

OPTIONS:
    -d, --testdata DIR       Test data directory (default: testdata/)
    -o, --output DIR         Results output directory (default: results/)
    -a, --algorithms ALGOS   Space-separated list (default: "lz4 snappy cascaded")
    -i, --iterations N       Benchmark iterations (default: 10)
    -w, --warmup N           Warmup iterations (default: 2)
    -g, --gpu N              GPU device ID (default: 0)
    -p, --chunk-sizes SIZES  Space-separated compression chunk sizes in bytes
                             (default: "65536", try "65536 1048576 16777216")
    -r, --rsf-dir DIR        RSF source directory for auto test data generation
    -s, --start-fraction F   RSF extraction start fraction (default: 0.5 = middle)
    --skip-testdata          Skip test data generation even if RSF dir is set
    --dry-run                Show what would be executed without running
    -h, --help               Show this help

EXAMPLES:
    # Basic: run all benchmarks on existing test data
    ./scripts/run_benchmarks_auto.sh

    # Generate test data from RSF and run benchmarks
    ./scripts/run_benchmarks_auto.sh -r /path/to/fletcher-io/original/run

    # Run only LZ4 with 20 iterations
    ./scripts/run_benchmarks_auto.sh -a "lz4" -i 20

    # Multiple chunk sizes for throughput analysis
    ./scripts/run_benchmarks_auto.sh -p "65536 1048576 16777216"

    # Inside Singularity container
    singularity run --bind /data:/data hipcomp.sif -r /data/rsf -o /data/results

EOF
}

# -------------------- Parse Arguments --------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--testdata)      TESTDATA_DIR="$2"; shift 2 ;;
        -o|--output)        RESULTS_DIR="$2"; shift 2 ;;
        -a|--algorithms)    ALGORITHMS="$2"; shift 2 ;;
        -i|--iterations)    ITERATIONS="$2"; shift 2 ;;
        -w|--warmup)        WARMUP="$2"; shift 2 ;;
        -g|--gpu)           GPU_DEVICE="$2"; shift 2 ;;
        -p|--chunk-sizes)   CHUNK_SIZES="$2"; shift 2 ;;
        -r|--rsf-dir)       RSF_DIR="$2"; shift 2 ;;
        -s|--start-fraction) RSF_START_FRACTION="$2"; shift 2 ;;
        --skip-testdata)    SKIP_TESTDATA_GEN=true; shift ;;
        --dry-run)          DRY_RUN=true; shift ;;
        -h|--help)          show_help; exit 0 ;;
        *)                  print_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# -------------------- Detect GPU --------------------
detect_gpu_info() {
    local gpu_name="Unknown"
    local gpu_arch="unknown"
    local platform="unknown"

    if command -v rocm-smi &> /dev/null; then
        platform="amd"
        gpu_name=$(rocm-smi --showproductname --device $GPU_DEVICE 2>/dev/null \
            | grep -i "card\|GPU" | head -1 | sed 's/.*: *//' | xargs) || gpu_name="AMD GPU"
        
        if command -v rocminfo &> /dev/null; then
            gpu_arch=$(rocminfo 2>/dev/null | grep "Name:" | grep "gfx" | head -1 | awk '{print $2}') || gpu_arch="unknown"
        fi
    elif command -v nvidia-smi &> /dev/null; then
        platform="nvidia"
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader -i $GPU_DEVICE 2>/dev/null | xargs) || gpu_name="NVIDIA GPU"
    fi

    echo "$platform|$gpu_name|$gpu_arch"
}

GPU_INFO=$(detect_gpu_info)
IFS='|' read -r PLATFORM GPU_NAME GPU_ARCH <<< "$GPU_INFO"

# Map arch to friendly name
get_env_label() {
    case "$1" in
        gfx942)  echo "MI300X" ;;
        gfx90a)  echo "MI210" ;;
        gfx906)  echo "MI50" ;;
        gfx1100) echo "RX7900XT" ;;
        *)       echo "$1" ;;
    esac
}
ENV_LABEL=$(get_env_label "$GPU_ARCH")

# -------------------- Find Benchmark Executables --------------------
find_benchmarks() {
    local search_dirs=(
        "/opt/arcto/bin"
        "/opt/arcto/build/bin"
        "/opt/arcto/build/benchmarks"
        "${ARCTO_BUILD:-/nonexistent}/bin"
        "${ARCTO_BUILD:-/nonexistent}/benchmarks"
        "$PROJECT_ROOT/build/bin"
        "$PROJECT_ROOT/build/benchmarks"
        "$PROJECT_ROOT/build_latest/bin"
        "$PROJECT_ROOT/build_latest/benchmarks"
    )

    for dir in "${search_dirs[@]}"; do
        if [ -d "$dir" ] && compgen -G "$dir/benchmark_*_chunked" > /dev/null 2>&1; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

BENCHMARK_DIR=$(find_benchmarks) || {
    print_error "Benchmark executables not found!"
    print_info "Build with: cmake -DBUILD_BENCHMARKS=ON .. && make"
    exit 1
}

# -------------------- Validate --------------------
for algo in $ALGORITHMS; do
    exe="$BENCHMARK_DIR/benchmark_${algo}_chunked"
    if [ ! -f "$exe" ]; then
        print_error "Missing benchmark: $exe"
        exit 1
    fi
done

# -------------------- Generate Test Data --------------------
if [ "$SKIP_TESTDATA_GEN" = "false" ]; then
    print_header "Generating Test Data"
    
    GENERATOR="$SCRIPT_DIR/generate_testdata.sh"
    if [ ! -f "$GENERATOR" ]; then
        print_error "Test data generator not found: $GENERATOR"
        exit 1
    fi
    
    GEN_ARGS=(-o "$TESTDATA_DIR")
    if [ -n "$RSF_DIR" ]; then
        GEN_ARGS+=(-r "$RSF_DIR" -s "$RSF_START_FRACTION")
        print_info "RSF source: $RSF_DIR (start_fraction=$RSF_START_FRACTION)"
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY-RUN] bash $GENERATOR ${GEN_ARGS[*]}"
    else
        bash "$GENERATOR" "${GEN_ARGS[@]}"
    fi
    echo ""
fi

# -------------------- Validate Test Data --------------------
if [ ! -d "$TESTDATA_DIR" ] || [ -z "$(ls -A "$TESTDATA_DIR"/*.bin 2>/dev/null)" ]; then
    print_error "No test data files found in: $TESTDATA_DIR"
    print_info "Options:"
    print_info "  1. Generate from RSF: $0 -r /path/to/rsf/run"
    print_info "  2. Generate synthetic: ./scripts/generate_testdata.sh $TESTDATA_DIR"
    exit 1
fi

# -------------------- Setup Results --------------------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_TAG="${ENV_LABEL}_${TIMESTAMP}"
EXPERIMENT_DIR="$RESULTS_DIR/$RESULT_TAG"
mkdir -p "$EXPERIMENT_DIR"

# Main CSV output
RESULTS_CSV="$EXPERIMENT_DIR/results.csv"

# Write CSV header
cat > "$RESULTS_CSV" << EOF
Algorithm,TestFile,FileSizeBytes,FileSizeMB,ChunkSize,CompressionRatio,CompThroughputGBs,DecompThroughputGBs,CompTimeMs,DecompTimeMs,TransferH2DMs,TransferD2HMs,TotalTimeMs,AvgChunkTimeMs,CompThroughputStdDev,DecompThroughputStdDev,CompTimeStdDevMs,DecompTimeStdDevMs,NodeName,GPU,GPUArch,EnvLabel,Iterations,Warmup,Timestamp
EOF

# Save experiment metadata
cat > "$EXPERIMENT_DIR/metadata.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "platform": "$PLATFORM",
    "gpu_name": "$GPU_NAME",
    "gpu_arch": "$GPU_ARCH",
    "env_label": "$ENV_LABEL",
    "gpu_device": $GPU_DEVICE,
    "algorithms": "$ALGORITHMS",
    "iterations": $ITERATIONS,
    "warmup": $WARMUP,
    "chunk_sizes": "$CHUNK_SIZES",
    "testdata_dir": "$TESTDATA_DIR",
    "rsf_start_fraction": $RSF_START_FRACTION,
    "hostname": "$(hostname)",
    "benchmark_dir": "$BENCHMARK_DIR"
}
EOF

# -------------------- Print Configuration --------------------
print_header "Benchmark Configuration"
echo ""
print_info "Platform:    $PLATFORM"
print_info "GPU:         $GPU_NAME ($GPU_ARCH)"
print_info "Environment: $ENV_LABEL"
print_info "Device ID:   $GPU_DEVICE"
print_info "Algorithms:  $ALGORITHMS"
print_info "Iterations:  $ITERATIONS"
print_info "Warmup:      $WARMUP"
print_info "Chunk sizes: $CHUNK_SIZES"
print_info "Test data:   $TESTDATA_DIR"
print_info "Results:     $EXPERIMENT_DIR"
echo ""

# -------------------- Collect Test Files --------------------
mapfile -t TEST_FILES < <(find "$TESTDATA_DIR" -name "*.bin" -type f | sort)
NUM_FILES=${#TEST_FILES[@]}

if [ $NUM_FILES -eq 0 ]; then
    print_error "No .bin files found in $TESTDATA_DIR"
    exit 1
fi

print_info "Found $NUM_FILES test file(s):"
for f in "${TEST_FILES[@]}"; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo "?")
    fmb=$(echo "scale=1; $fsize / 1048576" | bc 2>/dev/null || echo "?")
    print_info "  $(basename "$f") (${fmb} MB)"
done
echo ""

# -------------------- Count Total Tests --------------------
NUM_ALGOS=$(echo $ALGORITHMS | wc -w)
NUM_CHUNKS=$(echo $CHUNK_SIZES | wc -w)
TOTAL_TESTS=$((NUM_FILES * NUM_ALGOS * NUM_CHUNKS))

print_header "Running $TOTAL_TESTS Benchmark(s)"
echo ""

# -------------------- Run Benchmarks --------------------
current_test=0
failed_tests=0
start_time=$(date +%s)

for algo in $ALGORITHMS; do
    print_header "Algorithm: ${algo^^}"
    
    exe="$BENCHMARK_DIR/benchmark_${algo}_chunked"
    
    for chunk_size in $CHUNK_SIZES; do
        chunk_label=$(numfmt --to=iec-i $chunk_size 2>/dev/null || echo "${chunk_size}B")
        
        for testfile in "${TEST_FILES[@]}"; do
            current_test=$((current_test + 1))
            testfile_name=$(basename "$testfile")
            testfile_size=$(stat -c%s "$testfile" 2>/dev/null || echo "0")
            testfile_mb=$(echo "scale=2; $testfile_size / 1048576" | bc 2>/dev/null || echo "0")
            
            print_step "[$current_test/$TOTAL_TESTS] ${algo^^} | $testfile_name (${testfile_mb} MB) | chunk=$chunk_label"
            
            if [ "$DRY_RUN" = "true" ]; then
                echo "  [DRY-RUN] $exe -f $testfile -i $ITERATIONS -w $WARMUP -g $GPU_DEVICE -p $chunk_size -c true -t false"
                echo "$algo,$testfile_name,$testfile_size,$testfile_mb,$chunk_size,DRY,DRY,DRY,DRY,DRY,$PLATFORM,$GPU_NAME,$GPU_ARCH,$ENV_LABEL,$ITERATIONS,$WARMUP,$TIMESTAMP" >> "$RESULTS_CSV"
                continue
            fi
            
            # Run benchmark
            temp_output=$(mktemp)
            temp_log="$EXPERIMENT_DIR/${algo}_${testfile_name}_chunk${chunk_size}.log"
            
            if timeout 600 $exe -f "$testfile" -i $ITERATIONS -w $WARMUP \
                    -g $GPU_DEVICE -p $chunk_size -c true -t false \
                    > "$temp_output" 2>&1; then
                
                # Parse CSV output
                # Format: Files,Dup,SizeMB,Pages,AvgPage,MaxPage,Uncompressed,Compressed,
                #         Ratio,CompGB,DecompGB,CompMs,DecompMs,H2DMs,D2HMs,TotalMs,AvgChunkMs
                result_line=$(tail -n 1 "$temp_output" 2>/dev/null)

                if [[ -n "$result_line" && "$result_line" != *"Files"* && "$result_line" != *"file"* ]]; then
                    IFS=',' read -ra fields <<< "$result_line"

                    comp_ratio="${fields[8]:-N/A}"
                    comp_throughput="${fields[9]:-N/A}"
                    decomp_throughput="${fields[10]:-N/A}"
                    comp_time_ms="${fields[11]:-N/A}"
                    decomp_time_ms="${fields[12]:-N/A}"
                    transfer_h2d="${fields[13]:-N/A}"
                    transfer_d2h="${fields[14]:-N/A}"
                    total_time_ms="${fields[15]:-N/A}"
                    avg_chunk_ms="${fields[16]:-N/A}"
                    comp_std="${fields[17]:-N/A}"
                    decomp_std="${fields[18]:-N/A}"
                    comp_time_std="${fields[19]:-N/A}"
                    decomp_time_std="${fields[20]:-N/A}"

                    echo "$algo,$testfile_name,$testfile_size,$testfile_mb,$chunk_size,$comp_ratio,$comp_throughput,$decomp_throughput,$comp_time_ms,$decomp_time_ms,$transfer_h2d,$transfer_d2h,$total_time_ms,$avg_chunk_ms,$comp_std,$decomp_std,$comp_time_std,$decomp_time_std,$(hostname),$GPU_NAME,$GPU_ARCH,$ENV_LABEL,$ITERATIONS,$WARMUP,$TIMESTAMP" >> "$RESULTS_CSV"

                    print_info "  Ratio: ${comp_ratio}x | Comp: ${comp_throughput} GB/s ±${comp_std} (${comp_time_ms}±${comp_time_std} ms) | Decomp: ${decomp_throughput} GB/s ±${decomp_std} (${decomp_time_ms}±${decomp_time_std} ms)"
                else
                    print_warn "  Could not parse CSV output"
                    echo "$algo,$testfile_name,$testfile_size,$testfile_mb,$chunk_size,PARSE_ERROR,PARSE_ERROR,PARSE_ERROR,PARSE_ERROR,PARSE_ERROR,PARSE_ERROR,PARSE_ERROR,PARSE_ERROR,PARSE_ERROR,PARSE_ERROR,PARSE_ERROR,PARSE_ERROR,PARSE_ERROR,$(hostname),$GPU_NAME,$GPU_ARCH,$ENV_LABEL,$ITERATIONS,$WARMUP,$TIMESTAMP" >> "$RESULTS_CSV"
                    failed_tests=$((failed_tests + 1))
                fi
            else
                print_warn "  Benchmark failed or timed out"
                echo "$algo,$testfile_name,$testfile_size,$testfile_mb,$chunk_size,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,$(hostname),$GPU_NAME,$GPU_ARCH,$ENV_LABEL,$ITERATIONS,$WARMUP,$TIMESTAMP" >> "$RESULTS_CSV"
                failed_tests=$((failed_tests + 1))
            fi
            
            # Save full log
            cp "$temp_output" "$temp_log" 2>/dev/null
            rm -f "$temp_output"
        done
    done
    echo ""
done

end_time=$(date +%s)
elapsed=$((end_time - start_time))
elapsed_min=$(echo "scale=1; $elapsed / 60" | bc 2>/dev/null || echo "$elapsed seconds")

# -------------------- Summary --------------------
print_header "Benchmark Complete"
echo ""
print_info "Environment: $ENV_LABEL ($GPU_NAME, $GPU_ARCH)"
print_info "Total tests: $current_test"
print_info "Failed:      $failed_tests"
print_info "Elapsed:     ${elapsed_min} min ($elapsed s)"
print_info "Results CSV: $RESULTS_CSV"
print_info "Logs:        $EXPERIMENT_DIR/"
echo ""

# Print summary table
print_header "Results Summary"
if command -v column &> /dev/null; then
    head -1 "$RESULTS_CSV"
    tail -n +2 "$RESULTS_CSV" | sort
    echo ""
    # Compact view
    echo "Algorithm | File | Ratio | Comp GB/s | Decomp GB/s"
    echo "----------|------|-------|-----------|-------------"
    tail -n +2 "$RESULTS_CSV" | awk -F',' '{printf "%-10s | %-30s | %8s | %9s | %s\n", $1, $2, $6, $7, $8}'
else
    cat "$RESULTS_CSV"
fi
echo ""

# Create a quick comparison CSV (one row per algorithm, averaged)
SUMMARY_CSV="$EXPERIMENT_DIR/summary.csv"
cat > "$SUMMARY_CSV" << EOF
# Summary: $ENV_LABEL ($GPU_NAME) - $(date)
# Averaged across all test files
EOF

print_info "Full results: $RESULTS_CSV"
print_info "Experiment:   $EXPERIMENT_DIR"
print_info "Done!"
