# -----------------------------------------------------------------------------
# Makefile for the Urbana Stage 5 AXI-UART hello bringup.
#
#   make mem              (re)generate BRAM init image from $(ELF) (default
#                         hello_axi.elf; override with ELF=...)
#   make synth            vivado non-project flow → build/axi_hello/axi_hello.bit
#   make prog             program over JTAG
#   make clean            wipe artifacts
#
# Examples:
#   make synth                                          # hello_axi
#   make synth ELF=$(REPO_DIR)/sw/tests/c/memtest.elf   # 7b memtest
#
# RTL lives under $repo/rtl/.
# -----------------------------------------------------------------------------

SHELL := /bin/bash

VIVADO_SETTINGS := /opt/Xilinx/2025.2/Vivado/settings64.sh
VIVADO_LAB_BIN  := /opt/Xilinx/2025.2/Vivado_Lab/bin/vivado_lab

REPO_DIR   := $(abspath ../..)
BUILD_DIR  := ../build/axi_hello
BITSTREAM  := $(BUILD_DIR)/axi_hello.bit

ELF        ?= $(REPO_DIR)/sw/tests/c/hello_axi.elf
MEM        := $(notdir $(basename $(ELF))).mem

BUILD_TCL  := ../scripts/build_axi_hello.tcl
PROG_TCL   := ../scripts/prog_axi_hello.tcl

VIVADO_BATCH_FLAGS := -mode batch

# CORE selects the RISC-V core variant; axi_hello defaults to pipeline because
# multicycle's EX stage (~36 ns) can't close at 50 MHz once DDR3/AXI fabric is
# packed next to it. Override with CORE=multicycle if you want to try anyway.
CORE ?= pipeline
ifeq ($(CORE),pipeline)
USE_PIPELINE_CORE := 1
else
USE_PIPELINE_CORE :=
endif

# ICACHE=1 / DCACHE=1 interpose the caches between core and SRAM. Mirrors
# sim/Makefile conventions.
ICACHE ?=
DCACHE ?=
ifeq ($(ICACHE),1)
USE_ICACHE := 1
else
USE_ICACHE :=
endif
ifeq ($(DCACHE),1)
USE_DCACHE := 1
else
USE_DCACHE :=
endif

.PHONY: synth prog clean mem

mem: $(MEM)

$(MEM): $(ELF) $(REPO_DIR)/scripts/elf2mem.py
	$(REPO_DIR)/scripts/elf2mem.py $(ELF) $(MEM)

synth: $(MEM)
	@mkdir -p $(BUILD_DIR)
	@echo "==> sourcing Vivado settings and running $(BUILD_TCL)"
	. $(VIVADO_SETTINGS) && \
	    SRAM_INIT_FILE=$(abspath $(MEM)) \
	    USE_PIPELINE_CORE=$(USE_PIPELINE_CORE) \
	    USE_ICACHE=$(USE_ICACHE) \
	    USE_DCACHE=$(USE_DCACHE) \
	    vivado $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/vivado.log \
	        -journal $(BUILD_DIR)/vivado.jou \
	        -source $(BUILD_TCL)

prog:
	@mkdir -p $(BUILD_DIR)
	@echo "==> programming Urbana with axi_hello.bit over JTAG"
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
