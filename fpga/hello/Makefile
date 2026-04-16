# -----------------------------------------------------------------------------
# Makefile for the SP701 hello-world CPU bringup.
#
#   make hello.mem        (re)generate BRAM init image from sw/tests/c/hello.elf
#   make synth            vivado non-project flow → build/hello/hello.bit
#   make prog             program over JTAG
#   make clean            wipe artifacts
#
# RTL lives under $repo/rtl/.  This directory only holds the Makefile +
# the generated hello.mem (gitignored).
# -----------------------------------------------------------------------------

SHELL := /bin/bash

VIVADO_SETTINGS := /opt/Xilinx/2025.2/Vivado/settings64.sh
VIVADO_LAB_BIN  := /opt/Xilinx/2025.2/Vivado_Lab/bin/vivado_lab

REPO_DIR   := $(abspath ../..)
BUILD_DIR  := ../build/hello
BITSTREAM  := $(BUILD_DIR)/hello.bit

ELF        ?= $(REPO_DIR)/sw/tests/c/hello.elf
MEM        := hello.mem

BUILD_TCL  := ../scripts/build_hello.tcl
PROG_TCL   := ../scripts/prog_hello.tcl

VIVADO_BATCH_FLAGS := -mode batch

.PHONY: synth prog clean mem

mem: $(MEM)

$(MEM): $(ELF) $(REPO_DIR)/scripts/elf2mem.py
	$(REPO_DIR)/scripts/elf2mem.py $(ELF) $(MEM)

synth: $(MEM)
	@mkdir -p $(BUILD_DIR)
	@echo "==> sourcing Vivado settings and running $(BUILD_TCL)"
	. $(VIVADO_SETTINGS) && \
	    SRAM_INIT_FILE=$(abspath $(MEM)) \
	    vivado $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/vivado.log \
	        -journal $(BUILD_DIR)/vivado.jou \
	        -source $(BUILD_TCL)

prog:
	@mkdir -p $(BUILD_DIR)
	@echo "==> programming SP701 with hello.bit over JTAG"
	@if command -v vivado_lab >/dev/null 2>&1; then \
	    vivado_lab $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/prog.log \
	        -journal $(BUILD_DIR)/prog.jou \
	        -source $(PROG_TCL); \
	elif [ -x $(VIVADO_LAB_BIN) ]; then \
	    $(VIVADO_LAB_BIN) $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/prog.log \
	        -journal $(BUILD_DIR)/prog.jou \
	        -source $(PROG_TCL); \
	else \
	    . $(VIVADO_SETTINGS) && \
	    vivado $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/prog.log \
	        -journal $(BUILD_DIR)/prog.jou \
	        -source $(PROG_TCL); \
	fi

clean:
	rm -rf $(BUILD_DIR)
	rm -f  $(MEM) vivado*.log vivado*.jou vivado*.str
	rm -rf .Xil
