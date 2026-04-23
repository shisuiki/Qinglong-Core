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
    $(RTL_DIR)/core/mmu.sv \
    $(RTL_DIR)/core/pmp.sv \
    $(RTL_DIR)/mem/sram_dp.sv \
    $(RTL_DIR)/mem/axil_bram_slave.sv \
    $(RTL_DIR)/mem/axil_uartlite_sim.sv \
    $(RTL_DIR)/mem/axi4_router_1x2.sv \
    $(RTL_DIR)/cache/icache.sv \
    $(RTL_DIR)/cache/dcache.sv \
    $(RTL_DIR)/soc/mmio.sv \
    $(RTL_DIR)/soc/clint.sv \
    $(RTL_DIR)/soc/plic.sv \
    $(RTL_DIR)/soc/axi4_master.sv \
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
# ICACHE=1 inserts the I-cache between the core IF port and SRAM port A.
ifeq ($(ICACHE),1)
VERILATOR_FLAGS += -DUSE_ICACHE
endif
# DCACHE=1 inserts the write-back D-cache between the core DMEM port (SRAM
# region only) and SRAM port B.
ifeq ($(DCACHE),1)
VERILATOR_FLAGS += -DUSE_DCACHE
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

# ---------------------------------------------------------------------------
# Linux sim (soc_tb_linux) — brings up OpenSBI + kernel in Verilator with a
# large DDR-backed BRAM at 0x40000000 and AXI-UartLite at 0xC0000000. The
# full boot memory map (fw_jump, kernel Image, DTB, initramfs) is preloaded
# by the C++ harness via the DDR DPI backdoor before the first clock.
# ---------------------------------------------------------------------------
LINUX_TOP       := soc_tb_linux
LINUX_OBJ_DIR   := $(BUILD_DIR)/obj_linux
LINUX_BIN       := $(LINUX_OBJ_DIR)/V$(LINUX_TOP)

LINUX_RTL_FILES := \
    $(RTL_DIR)/core/defs.svh \
    $(RTL_DIR)/core/alu.sv \
    $(RTL_DIR)/core/imm_gen.sv \
    $(RTL_DIR)/core/regfile.sv \
    $(RTL_DIR)/core/csr.sv \
    $(RTL_DIR)/core/mul_unit.sv \
    $(RTL_DIR)/core/div_unit.sv \
    $(RTL_DIR)/core/core_multicycle.sv \
    $(RTL_DIR)/core/core_pipeline.sv \
    $(RTL_DIR)/core/mmu.sv \
    $(RTL_DIR)/core/pmp.sv \
    $(RTL_DIR)/mem/sram_dp.sv \
    $(RTL_DIR)/mem/axil_bram_slave.sv \
    $(RTL_DIR)/mem/axil_bram_big.sv \
    $(RTL_DIR)/mem/axil_uartlite_sim.sv \
    $(RTL_DIR)/mem/axi4_router_linux.sv \
    $(RTL_DIR)/cache/icache.sv \
    $(RTL_DIR)/cache/dcache.sv \
    $(RTL_DIR)/soc/mmio.sv \
    $(RTL_DIR)/soc/clint.sv \
    $(RTL_DIR)/soc/plic.sv \
    $(RTL_DIR)/soc/axi4_master.sv \
    $(RTL_DIR)/soc/soc_top.sv \
    $(RTL_DIR)/soc/soc_tb_linux.sv

LINUX_CPP_FILES := $(SIM_DIR)/cpp/sim_linux.cpp

# Trace is opt-in: `make linux-build FST=1` compiles in FST scaffolding and
# enables +fst=<path>. Without FST=1 we skip the tracing codegen entirely —
# sim runs ~30% faster and the binary is ~2x smaller. 10B-cycle runs are
# prohibitive with tracing on anyway (FST grows unbounded w/ commit activity).
ifeq ($(FST),1)
LINUX_TRACE_FLAGS := --trace-fst -CFLAGS "-DVM_TRACE_FST=1"
else ifeq ($(VCD),1)
LINUX_TRACE_FLAGS := --trace -CFLAGS "-DVM_TRACE=1"
else
LINUX_TRACE_FLAGS :=
endif

LINUX_FLAGS := \
    --cc --exe --build -j 0 \
    $(LINUX_TRACE_FLAGS) \
    --Mdir $(LINUX_OBJ_DIR) \
    --top-module $(LINUX_TOP) \
    -Wno-fatal \
    -Wno-UNOPTFLAT -Wno-WIDTH \
    -CFLAGS "-std=c++17 -O3 -Wall -I$(SIM_DIR)/cpp" \
    $(VERILATOR_INC)

ifeq ($(CORE),pipeline)
LINUX_FLAGS += -DUSE_PIPELINE_CORE
endif

.PHONY: linux-build linux-clean

linux-build: $(LINUX_BIN)

$(LINUX_BIN): $(LINUX_RTL_FILES) $(LINUX_CPP_FILES)
	@mkdir -p $(LINUX_OBJ_DIR)
	verilator $(LINUX_FLAGS) $(filter-out %.svh,$(LINUX_RTL_FILES)) $(LINUX_CPP_FILES)

linux-clean:
	rm -rf $(LINUX_OBJ_DIR)
