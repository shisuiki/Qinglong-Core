# Formal verification for core_pipeline via YosysHQ/riscv-formal.
#
# Source of truth is formal/core_pipeline/. The riscv-formal submodule expects
# the per-core config at cores/<name>/; we stage our checks.cfg + wrapper.sv
# there, then run the upstream genchecks.py.
#
# Usage:
#   source $(REPO)/scripts/env.sh   # picks up yosys/sby from oss-cad-suite
#   make gen                        # generate sby files
#   make run                        # run the insn suite
#   make clean                      # wipe generated files

REPO       := $(abspath ../..)
SUBMOD     := $(REPO)/third_party/riscv-formal
SUBMOD_CORE:= $(SUBMOD)/cores/core_pipeline
CORENAME   := core_pipeline

.PHONY: stage gen run clean

stage:
	@mkdir -p $(SUBMOD_CORE)
	@cp checks.cfg wrapper.sv $(SUBMOD_CORE)/

gen: stage
	cd $(SUBMOD_CORE) && python3 $(SUBMOD)/checks/genchecks.py

run: gen
	$(MAKE) -C $(SUBMOD_CORE)/checks

clean:
	rm -rf $(SUBMOD_CORE)
