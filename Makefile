# Top-level Makefile for the RV32IMA SoC project.
#
# Always `source scripts/env.sh` first so Verilator and Spike are on PATH.

.PHONY: help sim sim-all sim-c riscv-tests clean synth prog blinky-synth blinky-prog hello-synth hello-prog spike-check

help:
	@echo "Targets:"
	@echo "  make sim TEST=sw/tests/asm/pass.elf     # run one ELF under Verilator"
	@echo "  make sim-all                            # run the full riscv-tests regression"
	@echo "  make sim-c                              # run the in-tree C-test regression"
	@echo "  make riscv-tests                        # build upstream RV32I/M/A ISA tests"
	@echo "  make spike-check                        # sanity-check spike is on PATH"
	@echo "  make blinky-synth                       # Vivado synth+impl of blinky"
	@echo "  make blinky-prog                        # program blinky bitstream"
	@echo "  make hello-synth                        # Vivado synth+impl of hello-world SoC"
	@echo "  make hello-prog                         # program hello bitstream"
	@echo "  make clean"

spike-check:
	@command -v spike >/dev/null || { echo 'spike not on PATH; source scripts/env.sh'; exit 1; }
	@spike --help >/dev/null && echo "spike ok: $$(spike 2>&1 | head -1)"

# ------ simulation ------

sim: | sim/build
	$(MAKE) -C sim TEST=$(TEST)

sim-all: | sim/build
	$(MAKE) -C sim sim-all

sim-c: | sim/build
	$(MAKE) -C sim sim-c

sim/build:
	mkdir -p sim/build

# ------ software / tests ------

riscv-tests:
	$(MAKE) -C sw -f riscv-tests.mk

# ------ FPGA ------

blinky-synth:
	$(MAKE) -C fpga/blinky synth

blinky-prog:
	$(MAKE) -C fpga/blinky prog

hello-synth:
	$(MAKE) -C sw/tests/c hello.elf
	$(MAKE) -C fpga/hello synth

hello-prog:
	$(MAKE) -C fpga/hello prog

clean:
	rm -rf sim/build/obj_dir sim/build/*.log sim/build/*.trace sim/build/*.vcd
	$(MAKE) -C sw/tests/asm clean 2>/dev/null || true
	$(MAKE) -C sw/tests/c clean 2>/dev/null || true
