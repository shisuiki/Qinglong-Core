# Urbana FreeRTOS demo: same axi_hello RTL top, different BRAM image.

SHELL := /bin/bash

VIVADO_SETTINGS := /opt/Xilinx/2025.2/Vivado/settings64.sh
VIVADO_LAB_BIN  := /opt/Xilinx/2025.2/Vivado_Lab/bin/vivado_lab

REPO_DIR   := $(abspath ../..)
BUILD_DIR  := ../build/freertos
BITSTREAM  := $(BUILD_DIR)/axi_hello.bit

ELF        ?= $(REPO_DIR)/sw/freertos/freertos_demo.elf
MEM        := freertos_demo.mem

BUILD_TCL  := ../scripts/build_axi_hello.tcl
PROG_TCL   := ../scripts/prog_axi_hello.tcl

VIVADO_BATCH_FLAGS := -mode batch

# CORE=pipeline selects the 5-stage pipeline core; default is multicycle.
CORE ?=
ifeq ($(CORE),pipeline)
USE_PIPELINE_CORE := 1
else
USE_PIPELINE_CORE :=
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
	    vivado $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/vivado.log \
	        -journal $(BUILD_DIR)/vivado.jou \
	        -source $(BUILD_TCL)

prog:
	@mkdir -p $(BUILD_DIR)
	@echo "==> programming Urbana with freertos bitstream over JTAG"
	@if command -v vivado_lab >/dev/null 2>&1; then \
	    BITSTREAM=$(abspath $(BITSTREAM)) \
	    vivado_lab $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/prog.log \
	        -journal $(BUILD_DIR)/prog.jou \
	        -source $(PROG_TCL); \
	elif [ -x $(VIVADO_LAB_BIN) ]; then \
	    BITSTREAM=$(abspath $(BITSTREAM)) \
	    $(VIVADO_LAB_BIN) $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/prog.log \
	        -journal $(BUILD_DIR)/prog.jou \
	        -source $(PROG_TCL); \
	else \
	    . $(VIVADO_SETTINGS) && \
	    BITSTREAM=$(abspath $(BITSTREAM)) \
	    vivado $(VIVADO_BATCH_FLAGS) \
	        -log $(BUILD_DIR)/prog.log \
	        -journal $(BUILD_DIR)/prog.jou \
	        -source $(PROG_TCL); \
	fi

clean:
	rm -rf $(BUILD_DIR)
	rm -f  $(MEM) vivado*.log vivado*.jou vivado*.str
	rm -rf .Xil
