#!/bin/bash
# =============================================================================
# Singularity Entrypoint for hipCOMP Benchmark Automation
# 
# This script is the default %runscript for the Singularity container.
# It detects the GPU, prepares test data, and runs benchmarks automatically.
#
# Usage (from host — prefer run_singularity.sh wrapper):
#   ./scripts/run_singularity.sh hipcomp.sif /path/to/rsf [OPTIONS]
#
# Or manually:
#   singularity run --rocm \
#     --bind /path/to/rsf/run:/data/rsf \
#     --bind ./results:/data/results \
#     hipcomp.sif -r /data/rsf -o /data/results [OPTIONS]
#
# Or exec directly:
#   singularity exec --rocm hipcomp.sif \
#     /opt/compression-experiments/scripts/run_benchmarks_auto.sh [OPTIONS]
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${HIPCOMP_ROOT:-/opt/hip-compression-toolkit}"
SCRIPTS_ROOT="${HIPCOMP_ROOT:-/opt/arcto}"

echo "=============================================="
echo "  hipCOMP Benchmark Container"
echo "=============================================="
echo ""

# Check GPU access
if command -v rocm-smi &> /dev/null; then
    echo "[INFO] ROCm detected"
    rocm-smi --showproductname 2>/dev/null | head -5 || echo "[WARN] Could not query GPU"
elif command -v nvidia-smi &> /dev/null; then
    echo "[INFO] NVIDIA GPU detected"
    nvidia-smi -L 2>/dev/null | head -5 || echo "[WARN] Could not query GPU"
else
    echo "[WARN] No GPU runtime detected — benchmarks may fail"
fi
echo ""

# Show bind mount status
echo "[INFO] Bind mount status:"
for mp in /data/rsf /data/results /data/testdata; do
    if [ -d "$mp" ] && [ "$(ls -A "$mp" 2>/dev/null)" ]; then
        echo "  $mp -> mounted ($(ls -1 "$mp" | wc -l) items)"
    elif [ -d "$mp" ]; then
        echo "  $mp -> mounted (empty)"
    else
        echo "  $mp -> not mounted"
    fi
done
echo ""

# Forward all arguments to the benchmark runner
exec "$SCRIPTS_ROOT/run_benchmarks_auto.sh" "$@"
