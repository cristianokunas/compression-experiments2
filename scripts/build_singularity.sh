#!/bin/bash
# =============================================================================
# Build Singularity image for ARCTO benchmarks
#
# Usage:
#   ./scripts/build_singularity.sh [OPTIONS]
#
# The image includes ROCm + pre-compiled benchmarks (LZ4, Snappy, Cascaded).
# After building, use run_singularity.sh to execute benchmarks.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Auto-detect singularity or apptainer (apptainer is the upstream successor)
detect_container_runtime() {
    if command -v singularity &>/dev/null; then
        echo "singularity"
    elif command -v apptainer &>/dev/null; then
        echo "apptainer"
    else
        echo ""
    fi
}
CONTAINER_RUNTIME=$(detect_container_runtime)

# -------------------- Defaults --------------------
GPU_ARCH="gfx942"
BRANCH="devel"
OUTPUT_NAME=""
DEF_FILE="$PROJECT_ROOT/singularity/defhip_benchmark.def"
FORCE=false
BUILD_MODE=""  # auto-detected: fakeroot, sudo, sudo-g5k

# -------------------- Help --------------------
show_help() {
    cat << 'EOF'
Build Singularity image for ARCTO benchmarks.

Usage: build_singularity.sh [OPTIONS]

OPTIONS:
    -a, --arch ARCH      GPU architecture (default: gfx942)
                         Supported: gfx942 (MI300X), gfx90a (MI210),
                                    gfx906 (MI50), gfx1100 (RX7900XT)
    -b, --branch BRANCH  Git branch to build from (default: devel)
    -o, --output FILE    Output .sif filename (default: arcto_<arch>.sif)
    -m, --mode MODE      Build privilege mode (default: auto-detect)
                         fakeroot  - use --fakeroot (no sudo needed, e.g. PCAD UFRGS)
                         sudo      - use sudo (e.g. Grid5000 deployed nodes)
                         sudo-g5k  - use sudo-g5k (Grid5000 alternative)
    -f, --force          Overwrite existing image
    -h, --help           Show this help

PRIVILEGE MODES:
    The script auto-detects the best method to build the image:
      1. If running as root         -> direct build (no sudo)
      2. If sudo-g5k is available   -> sudo-g5k singularity build ...
      3. If sudo is available       -> sudo singularity build ...
      4. Fallback                   -> singularity build --fakeroot ...

    Override with: --mode fakeroot|sudo|sudo-g5k

EXAMPLES:
    # Build for MI300X (auto-detect privilege mode)
    ./scripts/build_singularity.sh

    # Build for MI210
    ./scripts/build_singularity.sh --arch gfx90a

    # Build for RX 7900 XT with fakeroot (PCAD UFRGS)
    ./scripts/build_singularity.sh --arch gfx1100 --mode fakeroot

    # Build for MI300X on Grid5000 with sudo-g5k
    ./scripts/build_singularity.sh --arch gfx942 --mode sudo-g5k

    # Build for all architectures
    for arch in gfx942 gfx90a gfx906 gfx1100; do
        ./scripts/build_singularity.sh --arch $arch
    done

AFTER BUILDING:
    # Run benchmarks (see run_singularity.sh --help for details)
    ./scripts/run_singularity.sh arcto_gfx942.sif /path/to/rsf/data
EOF
}

# -------------------- Parse Args --------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--arch)     GPU_ARCH="$2"; shift 2 ;;
        -b|--branch)   BRANCH="$2"; shift 2 ;;
        -o|--output)   OUTPUT_NAME="$2"; shift 2 ;;
        -m|--mode)     BUILD_MODE="$2"; shift 2 ;;
        -f|--force)    FORCE=true; shift ;;
        -h|--help)     show_help; exit 0 ;;
        *)             print_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# -------------------- Validate --------------------
# Map friendly names to arch codes
case "$GPU_ARCH" in
    mi300x|MI300X)   GPU_ARCH="gfx942" ;;
    mi210|MI210)     GPU_ARCH="gfx90a" ;;
    mi50|MI50)       GPU_ARCH="gfx906" ;;
    rx7900xt|RX7900XT|rx7900) GPU_ARCH="gfx1100" ;;
    gfx942|gfx90a|gfx906|gfx1100) ;; # already a valid arch code
    *) print_error "Unknown architecture: $GPU_ARCH"; exit 1 ;;
esac

# Friendly name for output
case "$GPU_ARCH" in
    gfx942)  FRIENDLY="MI300X" ;;
    gfx90a)  FRIENDLY="MI210" ;;
    gfx906)  FRIENDLY="MI50" ;;
    gfx1100) FRIENDLY="RX7900XT" ;;
esac

if [ -z "$OUTPUT_NAME" ]; then
    OUTPUT_NAME="arcto_${GPU_ARCH}.sif"
fi

if [ ! -f "$DEF_FILE" ]; then
    print_error "Definition file not found: $DEF_FILE"
    exit 1
fi

if [ -z "$CONTAINER_RUNTIME" ]; then
    print_error "Neither singularity nor apptainer found. Install one first:"
    print_info "  Apptainer: https://apptainer.org/docs/admin/main/installation.html"
    print_info "  Singularity: https://docs.sylabs.io/guides/latest/user-guide/quick_start.html"
    exit 1
fi
print_info "Container runtime: $CONTAINER_RUNTIME"

if [ -f "$OUTPUT_NAME" ] && [ "$FORCE" != "true" ]; then
    print_error "Image already exists: $OUTPUT_NAME"
    print_info "Use --force to overwrite, or -o to specify a different name"
    exit 1
fi

# -------------------- Build --------------------
echo ""
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}  Building ARCTO Singularity Image${NC}"
echo -e "${BOLD}============================================${NC}"
echo ""
print_info "Architecture: $GPU_ARCH ($FRIENDLY)"
print_info "Branch:       $BRANCH"
print_info "Definition:   $DEF_FILE"
print_info "Output:       $OUTPUT_NAME"

# -------------------- Detect Privilege Mode --------------------
detect_build_mode() {
    # 1. Already root
    if [ "$(id -u)" = "0" ]; then
        echo "root"
        return
    fi
    # 2. sudo-g5k (Grid5000 specific)
    if command -v sudo-g5k &> /dev/null; then
        echo "sudo-g5k"
        return
    fi
    # 3. Regular sudo (Grid5000 deployed node or local with sudo)
    if sudo -n true 2>/dev/null; then
        echo "sudo"
        return
    fi
    # 4. Fakeroot (PCAD UFRGS, no sudo)
    echo "fakeroot"
}

if [ -z "$BUILD_MODE" ]; then
    BUILD_MODE=$(detect_build_mode)
    print_info "Auto-detected build mode: $BUILD_MODE"
else
    print_info "Build mode: $BUILD_MODE (user-specified)"
fi

# Validate build mode
case "$BUILD_MODE" in
    root|sudo|sudo-g5k|fakeroot) ;;
    *) print_error "Invalid build mode: $BUILD_MODE (use: fakeroot, sudo, sudo-g5k)"; exit 1 ;;
esac

# Construct the build command based on privilege mode
BUILD_CMD=()
case "$BUILD_MODE" in
    root)
        BUILD_CMD=("$CONTAINER_RUNTIME" build)
        ;;
    sudo)
        BUILD_CMD=(sudo "$CONTAINER_RUNTIME" build)
        ;;
    sudo-g5k)
        BUILD_CMD=(sudo-g5k "$CONTAINER_RUNTIME" build)
        ;;
    fakeroot)
        BUILD_CMD=("$CONTAINER_RUNTIME" build --fakeroot)
        ;;
esac

# No need to change directory - the .def clones from GitHub directly
print_info "Build command: ${BUILD_CMD[*]} ${FORCE:+--force} --build-arg GPU_ARCH=$GPU_ARCH --build-arg BRANCH=$BRANCH $OUTPUT_NAME $DEF_FILE"
print_info "Starting build (this may take 20-40 minutes)..."
echo ""

"${BUILD_CMD[@]}" \
    ${FORCE:+--force} \
    --build-arg "GPU_ARCH=$GPU_ARCH" \
    --build-arg "BRANCH=$BRANCH" \
    "$OUTPUT_NAME" \
    "$DEF_FILE"

# -------------------- Verify --------------------
if [ -f "$OUTPUT_NAME" ]; then
    IMAGE_SIZE=$(du -h "$OUTPUT_NAME" | awk '{print $1}')
    echo ""
    print_info "Build successful!"
    print_info "Image: $OUTPUT_NAME ($IMAGE_SIZE)"
    echo ""
    print_info "Quick test:"
    print_info "  $CONTAINER_RUNTIME run --rocm $OUTPUT_NAME --help"
    echo ""
    print_info "Run benchmarks:"
    print_info "  ./scripts/run_singularity.sh $OUTPUT_NAME /path/to/rsf/run"
else
    print_error "Build failed - no output image found"
    exit 1
fi
