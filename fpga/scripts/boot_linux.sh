#!/usr/bin/env bash
# End-to-end Linux-on-SoC boot: program bitstream → spawn UART monitor →
# preload OpenSBI/Linux/DTB over JTAG-to-AXI → arm handshake.
#
# Assumes:
#   - Urbana is plugged into USB
#   - /dev/ttyUSB1 is the FPGA UART (FTDI interface B)
#   - bitstream built at fpga/build/axi_hello/axi_hello.bit
#   - OpenSBI/kernel/DTB/initramfs built per the build pipeline
#
# Usage:
#   fpga/scripts/boot_linux.sh              # interactive — monitor stays attached
#   fpga/scripts/boot_linux.sh --log out.log
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
FPGA_DIR=$REPO_DIR/fpga
BUILD_DIR=$FPGA_DIR/build/axi_hello
BITSTREAM=$BUILD_DIR/axi_hello.bit

PROG_TCL=$FPGA_DIR/scripts/prog_axi_hello.tcl
LOAD_TCL=$FPGA_DIR/scripts/jtag_load.tcl
MON=$FPGA_DIR/scripts/uart_monitor.py

VIVADO_LAB=/opt/Xilinx/2025.2/Vivado_Lab/bin/vivado_lab
VIVADO=/opt/Xilinx/2025.2/Vivado/bin/vivado

LOG_FILE=${LOG_FILE:-$BUILD_DIR/uart.log}
PORT=${PORT:-/dev/ttyUSB1}

if [[ ! -f $BITSTREAM ]]; then
    echo "ERROR: bitstream not found: $BITSTREAM"
    echo "       run `(cd fpga/axi_hello && make synth ELF=\$REPO/sw/bootrom/bootrom.elf)` first"
    exit 1
fi

# Pick Vivado flavour. Lab edition is enough for program_hw_devices and hw_axi txns,
# doesn't need a license, and starts faster.
if command -v vivado_lab >/dev/null 2>&1; then
    VIV=vivado_lab
elif [[ -x $VIVADO_LAB ]]; then
    VIV=$VIVADO_LAB
else
    source /opt/Xilinx/2025.2/Vivado/settings64.sh
    VIV=vivado
fi

echo "==> boot_linux: vivado = $VIV"
echo "==> boot_linux: bit    = $BITSTREAM"
echo "==> boot_linux: port   = $PORT"
echo "==> boot_linux: log    = $LOG_FILE"

# 1. Program the FPGA.
echo "==> boot_linux: programming bitstream"
$VIV -mode batch -source "$PROG_TCL" >"$BUILD_DIR/prog.log" 2>&1
echo "    programmed OK"

# 2. Start UART monitor in the background, tee'd to log.
echo "==> boot_linux: starting UART monitor"
exec 3>"$LOG_FILE"   # open the log fd so tail -f can follow it
python3 "$MON" --port "$PORT" --log "$LOG_FILE" --readonly &
MON_PID=$!
trap 'kill -TERM $MON_PID 2>/dev/null || true' EXIT

sleep 1

# 3. Stage code over JTAG-to-AXI and arm handshake.
echo "==> boot_linux: loading OpenSBI + Linux + DTB via JTAG"
$VIV -mode batch -source "$LOAD_TCL" 2>&1 | tee "$BUILD_DIR/load.log"

echo "==> boot_linux: handshake fired. Watching UART for Linux banner..."
echo "    (Ctrl-C to exit; log: $LOG_FILE)"

# 4. Wait for monitor (it exits on SIGTERM/SIGINT).
wait $MON_PID || true
