# -----------------------------------------------------------------------------
# Makefile for the SP701 (xc7s100fgga676-2) blinky smoke test.
#
# Targets:
#   make synth   - run non-project Vivado build flow (synth+impl+bitstream)
#   make prog    - program the FPGA over JTAG (uses vivado_lab if available)
#   make clean   - remove build artifacts
# -----------------------------------------------------------------------------

SHELL := /bin/bash

VIVADO_SETTINGS := /opt/Xilinx/2025.2/Vivado/settings64.sh
VIVADO_LAB_BIN  := /opt/Xilinx/2025.2/Vivado_Lab/bin/vivado_lab

BUILD_DIR       := build
BITSTREAM       := $(BUILD_DIR)/blinky.bit

BUILD_TCL       := ../scripts/build_blinky.tcl
PROG_TCL        := ../scripts/prog_blinky.tcl

# Keep the tree tidy: route Vivado log/journal into build/ instead of leaving
# them in the cwd. We deliberately do NOT pass -nolog/-nojournal because those
# fully disable logging and make -log / -journal paths no-ops; instead we
# explicitly redirect the log+journal into build/.
VIVADO_BATCH_FLAGS := -mode batch

.PHONY: synth prog clean

synth:
	@mkdir -p $(BUILD_DIR)
	@echo "==> sourcing Vivado settings and running $(BUILD_TCL)"
	. $(VIVADO_SETTINGS) && \
	    vivado $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/vivado.log \
	        -journal $(BUILD_DIR)/vivado.jou \
	        -source $(BUILD_TCL)

prog:
	@mkdir -p $(BUILD_DIR)
	@echo "==> programming SP701 over JTAG"
	@if command -v vivado_lab >/dev/null 2>&1; then \
	    echo "==> using vivado_lab from PATH"; \
	    vivado_lab $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/prog.log \
	        -journal $(BUILD_DIR)/prog.jou \
	        -source $(PROG_TCL); \
	elif [ -x $(VIVADO_LAB_BIN) ]; then \
	    echo "==> using $(VIVADO_LAB_BIN)"; \
	    $(VIVADO_LAB_BIN) $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/prog.log \
	        -journal $(BUILD_DIR)/prog.jou \
	        -source $(PROG_TCL); \
	else \
	    echo "==> vivado_lab not found; falling back to full Vivado"; \
	    . $(VIVADO_SETTINGS) && \
	    vivado $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/prog.log \
	        -journal $(BUILD_DIR)/prog.jou \
	        -source $(PROG_TCL); \
	fi

clean:
	rm -rf $(BUILD_DIR)
	rm -f vivado*.log vivado*.jou vivado*.str
	rm -rf .Xil
