# Qinglong Core

A small, from-scratch RV32 soft core for the AMD SP701 (Spartan-7 XC7S100) FPGA,
built stage by stage toward a Linux-capable SoC.

Named after Chen Qianyu from *Arknights: Endfield* — "青龙角、马尾辫、两把傻不愣登的剑~ 陈千语！“ The core is pretty dumb, but it's getting there - where's there? I don't know either to be honest.
!(https://i0.hdslb.com/bfs/new_dyn/5c0a617963c872e091d3506bb8afcd893461577311259436.gif)

## Status (Stage 1)

- **Single-cycle RV32I core** with M-mode CSRs, trap/MRET, valid/ready bus.
- **52 / 58** riscv-tests pass (41/42 `rv32ui-p-*`, 11/16 `rv32mi-p-*`; remaining
  failures need PMP / Zicntr / Smrnmi / hardware misaligned — deferred).
- **Trace-diff against Spike** matches 100 % on validated ISA tests
  (`rv32ui-p-simple`: 77/77, `rv32ui-p-add`: 501/501).
- **C hello-world** (libgcc for divs, no newlib) runs and exits cleanly.
- **SP701 blinky** synthesizes with zero warnings on Vivado 2025.2 (1 LUT / 30 FF).

See [`docs/plan.md`](docs/plan.md) for the living plan and
[`docs/progress.md`](docs/progress.md) for the chronological log.

## Layout

```
rtl/            CPU + SoC SystemVerilog (core, SRAM, MMIO)
sim/            Verilator C++ testbench + trace-diff tooling
sw/             bare-metal crt0, linker script, ASM + C demos
fpga/           SP701 XDC + Vivado non-project TCL flow
docs/           plan, progress log, bus spec
scripts/        env.sh (source this first)
```

## Build & run

### One-time setup
```bash
# Spike (built from source — vendored deps, dtc, etc.):
sudo apt-get install -y device-tree-compiler
git clone --depth 1 https://github.com/riscv-software-src/riscv-isa-sim.git /tmp/spike-src
(cd /tmp/spike-src && mkdir build && cd build && ../configure --prefix=/opt/spike && make -j$(nproc) && sudo make install)

# riscv-tests (we vendor the upstream and use a thin wrapper):
git clone --depth 1 --recurse-submodules \
    https://github.com/riscv-software-src/riscv-tests.git sw/riscv-tests
(cd sw/riscv-tests && ./configure --with-xlen=32 && make isa -j$(nproc) RISCV_PREFIX=riscv64-unknown-elf-)
```

### Simulation
```bash
source scripts/env.sh

# Build once
make -C sim build

# Smoke test
make -C sim run TEST=../sw/tests/asm/pass.elf

# Full RV32I + M-mode regression
make -C sim sim-all

# Trace-diff against Spike
sim/scripts/spike_trace.sh sw/riscv-tests/isa/rv32ui-p-add /tmp/spike.trace
make -C sim run TEST=../sw/riscv-tests/isa/rv32ui-p-add TRACE=/tmp/rtl.trace
sim/scripts/trace_diff.py /tmp/rtl.trace /tmp/spike.trace
```

### FPGA (SP701)
```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
make -C fpga/blinky synth     # bitstream in fpga/blinky/build/
make -C fpga/blinky prog      # programs the first SP701 on the JTAG chain
```

## Toolchain pinned

- Verilator 5.047 (oss-cad-suite)
- Vivado 2025.2 (non-project TCL flow)
- riscv64-unknown-elf-gcc with rv32 multilib
- Spike 1.1.1-dev

## License

Everything not from upstream is under the MIT License. `sw/riscv-tests/`
(vendored clone, not checked in here) carries its upstream license.
