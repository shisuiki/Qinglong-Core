# Source this file: `source scripts/env.sh` from the project root.
# Idempotent — can be sourced multiple times.

# oss-cad-suite (verilator)
if [ -z "${_QY_OSS_CAD:-}" ] && [ -f /opt/oss-cad-suite/environment ]; then
    # shellcheck disable=SC1091
    . /opt/oss-cad-suite/environment
    export _QY_OSS_CAD=1
fi

# Vivado (don't source in sim sessions — it's heavy; keep opt-in)
vivado_on() {
    # shellcheck disable=SC1091
    . /opt/Xilinx/2025.2/Vivado/settings64.sh
}

# Spike
case ":$PATH:" in
    *":/opt/spike/bin:"*) ;;
    *) export PATH="/opt/spike/bin:$PATH" ;;
esac

# Project root
QY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export QY_ROOT
export QY_BUILD="$QY_ROOT/sim/build"
mkdir -p "$QY_BUILD"

# RISC-V cross-compile prefix (Ubuntu ships riscv64-unknown-elf-gcc with rv32 multilib)
export RISCV_PREFIX="${RISCV_PREFIX:-riscv64-unknown-elf-}"
export RISCV_ARCH="${RISCV_ARCH:-rv32i}"
export RISCV_ABI="${RISCV_ABI:-ilp32}"
