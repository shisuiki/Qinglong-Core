# Verilator build + runner for the Stage-0 SoC.
#
# `source $(REPO)/scripts/env.sh` before invoking.

REPO      := $(abspath ..)
RTL_DIR   := $(REPO)/rtl
SIM_DIR   := $(REPO)/sim
BUILD_DIR := $(SIM_DIR)/build
OBJ_DIR   := $(BUILD_DIR)/obj_dir

TOP       := soc_tb_top
BIN       := $(OBJ_DIR)/V$(TOP)

RTL_FILES := \
    $(RTL_DIR)/core/defs.svh \
    $(RTL_DIR)/core/alu.sv \
    $(RTL_DIR)/core/imm_gen.sv \
    $(RTL_DIR)/core/regfile.sv \
    $(RTL_DIR)/core/csr.sv \
    $(RTL_DIR)/core/mul_unit.sv \
    $(RTL_DIR)/core/div_unit.sv \
    $(RTL_DIR)/core/core_multicycle.sv \
    $(RTL_DIR)/core/core_pipeline.sv \
    $(RTL_DIR)/mem/sram_dp.sv \
    $(RTL_DIR)/mem/axil_bram_slave.sv \
    $(RTL_DIR)/mem/axil_uartlite_sim.sv \
    $(RTL_DIR)/soc/mmio.sv \
    $(RTL_DIR)/soc/clint.sv \
    $(RTL_DIR)/soc/axi_lite_master.sv \
    $(RTL_DIR)/soc/soc_top.sv \
    $(RTL_DIR)/soc/soc_tb_top.sv

CPP_FILES := \
    $(SIM_DIR)/cpp/sim_main.cpp \
    $(SIM_DIR)/cpp/elf_loader.cpp

VERILATOR_INC := \
    -I$(RTL_DIR)/core \
    -I$(RTL_DIR)/mem \
    -I$(RTL_DIR)/soc

VERILATOR_FLAGS := \
    --cc --exe --build -j 0 \
    --trace \
    --Mdir $(OBJ_DIR) \
    --top-module $(TOP) \
    -Wno-fatal \
    -Wno-UNOPTFLAT -Wno-WIDTH \
    -CFLAGS "-std=c++17 -O2 -Wall -I$(SIM_DIR)/cpp" \
    $(VERILATOR_INC)

TEST ?=
TIMEOUT ?= 2000000
TRACE   ?=
VCD     ?=
# CORE=pipeline selects core_pipeline via +define; default (unset) uses core_multicycle.
CORE    ?=

ifeq ($(CORE),pipeline)
VERILATOR_FLAGS += -DUSE_PIPELINE_CORE
endif
ifneq ($(DEBUG_PIPE),)
VERILATOR_FLAGS += -DDEBUG_PIPE
endif

.PHONY: build run clean sim-all

build: $(BIN)

$(BIN): $(RTL_FILES) $(CPP_FILES)
	@mkdir -p $(BUILD_DIR)
	verilator $(VERILATOR_FLAGS) $(filter-out %.svh,$(RTL_FILES)) $(CPP_FILES)

# Convenience: `make TEST=sw/tests/asm/pass.elf` or with absolute path.
run: build
	@[ -n "$(TEST)" ] || { echo 'set TEST=<path to ELF>'; exit 1; }
	@echo '==================================================='
	@echo "TEST: $(TEST)"
	@echo '==================================================='
	@$(BIN) +elf=$(TEST) +timeout=$(TIMEOUT) \
	    $(if $(TRACE),+trace=$(TRACE)) \
	    $(if $(VCD),+vcd=$(VCD))

# Default to `make run TEST=...` pattern but also support legacy `make sim TEST=...`
sim: run

# Regression over all built riscv-tests ISA ELFs (those without a suffix).
sim-all: build
	@bash $(SIM_DIR)/scripts/regress.sh $(BIN)

# Regression over the in-tree C tests.  Requires `make -C sw/tests/c` first to
# produce the ELFs.  Each test must print "PASS\n" and mmio_exit(0).
sim-c: build
	@$(MAKE) -C $(REPO)/sw/tests/c all >/dev/null
	@bash $(SIM_DIR)/scripts/regress_c.sh $(BIN)

clean:
	rm -rf $(OBJ_DIR) $(BUILD_DIR)/*.log $(BUILD_DIR)/*.trace $(BUILD_DIR)/*.vcd
