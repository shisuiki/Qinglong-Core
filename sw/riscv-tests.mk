#=======================================================================
# riscv-tests.mk — wrapper around the upstream riscv-tests clone.
# Lives at sw/riscv-tests.mk; expects the upstream clone at sw/riscv-tests/.
#
# Usage (from repo root):
#   make -C sw -f riscv-tests.mk          # build rv32ui/um/ua/mi -p- tests
#   make -C sw -f riscv-tests.mk list     # print names of built ELFs
#   make -C sw -f riscv-tests.mk clean    # forward to upstream clean
#   make -C sw -f riscv-tests.mk configure
#
# Requirements:
#   - riscv64-unknown-elf-{gcc,objdump} in PATH (multilib: rv32i/im/ia)
#   - See README.md for the one-time clone step.
#=======================================================================

THIS_DIR     := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
TOP_DIR      := $(THIS_DIR)riscv-tests/
ISA_DIR      := $(TOP_DIR)isa
XLEN         ?= 32
RISCV_PREFIX ?= riscv64-unknown-elf-
JOBS         ?= $(shell nproc)

# Families we care about for Stage 0 (RV32IMA, machine mode only).
# We deliberately skip the -v- (virtual-memory) variants — they require
# newlib headers that the base rv32 multilib does not ship, and we
# don't have an MMU yet.
FAMILIES := rv32ui rv32um rv32ua rv32mi

# Expand each family's -p- targets via upstream's Makefrag files.
# The Makefrags define  <family>_sc_tests = list...
define fam_p_tests
$(shell awk '/_sc_tests *=/{f=1;next} f{for(i=1;i<=NF;i++) if($$i!~/^(\\|#)/) print $$i; if($$0!~/\\$$/) f=0}' \
    $(ISA_DIR)/$(1)/Makefrag | sed 's|^|$(1)-p-|')
endef

P_TEST_NAMES := $(foreach f,$(FAMILIES),$(call fam_p_tests,$(f)))
P_TEST_DUMPS := $(addsuffix .dump,$(P_TEST_NAMES))

.PHONY: all isa list clean configure help

all: isa

# Forward to upstream: build only the -p- tests we need (as .dump
# targets, which depend on the ELF). Avoids the -v- tests that fail
# because newlib's string.h isn't on the include path.
isa:
	$(MAKE) -C $(ISA_DIR) -j$(JOBS) XLEN=$(XLEN) \
	    RISCV_PREFIX=$(RISCV_PREFIX) $(P_TEST_DUMPS)

# Print the ELF basenames that have been built (suffix-less files only).
list:
	@cd $(ISA_DIR) && ls 2>/dev/null \
	    | grep -E '^(rv32ui|rv32um|rv32ua|rv32mi)-p-[A-Za-z0-9_-]+$$' \
	    | sort

clean:
	$(MAKE) -C $(ISA_DIR) clean

configure:
	cd $(TOP_DIR) && ./configure --prefix=/tmp/unused-install-prefix \
	    --with-xlen=$(XLEN)

help:
	@echo "Targets:"
	@echo "  all / isa   Build rv32ui/um/ua/mi -p- ELFs and .dumps"
	@echo "  list        Print built ELF basenames"
	@echo "  clean       Forward to upstream 'make clean'"
	@echo "  configure   Run ./configure (needed once before first build)"
	@echo ""
	@echo "Vars: XLEN=$(XLEN) RISCV_PREFIX=$(RISCV_PREFIX) JOBS=$(JOBS)"
