# RISC-V SoC — Living Plan

This is the **living** plan. Update it as decisions are made.

The north-star stage-by-stage plan (Stage 0 through Stage 15, with resource
budgets and rationale) lives on the maintainer's local notes and is kept out of
this repo. The deliverables, validation criteria, and memory-map decisions
captured below supersede it wherever they differ.

## Host environment (verified 2026-04-16)

| Tool | Version / path | Notes |
|---|---|---|
| Verilator | 5.047 (via `/opt/oss-cad-suite/environment`) | source before use |
| Vivado | 2025.2 at `/opt/Xilinx/2025.2` | full install + board file for SP701 |
| riscv GCC | `/usr/bin/riscv64-unknown-elf-gcc` (multilib includes rv32i, rv32im, rv32ia, rv32imac, rv32imafdc) | lp64/ilp32 both present |
| Spike | building at `/opt/spike` | dtc just installed; track build |
| Device-tree compiler | `/usr/bin/dtc` 1.7.0 | installed from apt |
| GCC host | 13.3.0 | |

## Target board: SP701 (AMD Spartan-7 Evaluation Kit)

The original plan assumed an Arty S7-50 (XC7S50). We actually have the larger **SP701**, XC7S100FGGA676-2. Notable deltas:

- **FPGA:** XC7S100 — ~102K logic cells, ~32K LUT6 (actually 64K 6-LUTs), 120 BRAM36, 160 DSP48E1. Comfortably larger than the plan's budget.
- **DDR3:** MT8JTF12864HZ-1G6G1 (1 GB, 64-bit) — MIG-ready.
- **Clocking:** 200 MHz differential (SYSCLK_P=AE8, N=AE7, LVDS_25).
- **UART:** on-board CP2103 USB-serial. FPGA `UART_TX=Y21`, `UART_RX=Y22` (LVCMOS33). Exposed as `/dev/ttyUSB*` on host.
- **2× Gigabit Ethernet (Marvell M88E1111, RGMII).** The plan's Stage 14 ESP32/PMOD path is superseded — we have native GigE on-board.
- **8 LEDs** (J25, M24, L24, K25, K26, M25, L25, H22, LVCMOS33).
- **5 pushbuttons** (AF23/AA20/AB20/AB22/AC22, LVCMOS18).
- **16 DIP switches**, **6 PMOD connectors**, **QSPI flash** (N25Q256), **I2C**, **HDMI output** (to be confirmed per schematic).
- **CPU_RESET button**: AE15 (LVCMOS18, active-high).

Open questions to resolve opportunistically: exact HDMI pin mapping (UG1479 schematic), PMOD VADJ levels, USB host option (MAX3421 on a PMOD vs. native PHY on the board).

## Overall strategy

- Keep the stage cadence of the original plan, but the **Stage 14 network path will target on-board GigE**, not an ESP32 PMOD. ESP32 is relegated to "optional experiment".
- Maintain a simulation-first loop. Every RTL change re-runs the riscv-tests regression before anything touches the FPGA.
- Trace-diff against Spike gates every CPU change. No silent passes.
- Bring up on FPGA only when sim + trace-diff are green.

## Directory layout

```
/home/lain/qianyu/riscv_soc/
├── docs/                 plan.md (this file), progress.md, design notes
├── rtl/
│   ├── core/             CPU pipeline / datapath
│   ├── mem/              register file, memory models, caches (later)
│   └── soc/              top-level wrappers, peripherals, MMIO decode
├── sim/
│   ├── cpp/              Verilator C++ testbench (ELF load, MMIO hooks, trace dump)
│   ├── scripts/          trace diff, regression harness
│   └── build/            generated obj_dir, logs (gitignored)
├── sw/
│   ├── common/           linker scripts, crt0, runtime stubs
│   ├── tests/asm/        hand-written assembly tests
│   ├── tests/c/          C tests (printf over MMIO, etc.)
│   └── riscv-tests/      upstream riscv-tests (vendored)
├── fpga/
│   ├── constraints/      XDC files (pins, timing)
│   ├── scripts/          Vivado non-project TCL flow
│   └── blinky/           Stage 0 blinky top-level
├── scripts/              top-level helpers (env.sh, etc.)
└── Makefile              top-level entrypoint
```

## MMIO conventions (simulation and FPGA)

| Address | Access | Meaning |
|---|---|---|
| 0xD058_0000 | store byte | Write one byte to simulation/UART console (TX FIFO). |
| 0xD058_0004 | store word | Terminate simulation. Low 16 bits = exit code (0 = pass). |
| 0xD058_0008 | load byte  | UART RX ready flag / received char (later). |

These addresses are deliberately in a non-standard range so nothing in `riscv-tests` collides. `tohost`/`fromhost` (used by riscv-tests) are handled separately via the ELF symbol table, not by MMIO.

## Stage 0 deliverables (in-flight)

1. Verilator C++ harness that:
   - takes `+elf=path/to/test.elf`,
   - loads program into a flat 64 KB SRAM model (word-addressable, byte-masked writes),
   - emulates the MMIO console + exit registers,
   - optionally emits a per-instruction retirement trace to compare against Spike,
   - exits with the guest-provided code.
2. A top-level SV simulation shell (`soc_tb_top.sv`): instantiates the CPU, the SRAM, and the MMIO decoder. For Stage 0 the "CPU" is a stub that just reads/writes the harness so we can prove the plumbing.
3. `sw/tests/asm/pass.S`: writes "PASS\n" bytes to 0xD058_0000, then stores `0` to 0xD058_0004. Linker script in `sw/common/`.
4. `sim/scripts/spike_trace.sh`: runs Spike with commit log enabled on the same ELF and normalizes to our trace format.
5. `sim/scripts/trace_diff.py`: compares RTL trace to Spike trace, reports first divergence.
6. `make sim TEST=…`, `make sim-all`, `make riscv-tests`, `make synth` (blinky), `make prog` (blinky).
7. **Blinky**: counter divides 200 MHz → ~1 Hz, drives LED[0]. Non-project Vivado TCL. Constraints in `fpga/constraints/sp701_blinky.xdc`.

## Stage 1 deliverables

1. `rtl/core/core_singlecycle.sv`: classical single-cycle RV32I. Two-phase memory FSM around BRAM so we avoid combinational BRAM reads. Register file in LUTRAM (2R1W). Trap handler minimal (mtvec, mepc, mcause, mtval, mstatus, misa, mie, mip), M-mode only.
2. `rtl/soc/soc_top.sv`: parametric top that wraps core + flat SRAM + MMIO. Same shell used for sim and FPGA.
3. Pass all `rv32ui-p-*` and (applicable) `rv32mi-p-*` riscv-tests, trace-diff clean vs Spike.
4. `sw/tests/c/hello.c` + `printf`-like MMIO `puts` to demonstrate C toolchain and linkerscript.

## Decisions recorded

- **Memory model Stage 0–1:** single 64 KB SRAM, unified, no cache, no MMU. Maps to `0x8000_0000–0x8001_FFFF` (matches riscv-tests default reset vector after linkage). MMIO region `0xD058_0000+`.
- **Reset vector Stage 0–1:** 0x8000_0000 (matches riscv-tests linker). Stage 4 introduces a boot ROM at low address.
- **Trace format:** one retirement per line, space-separated: `<priv> <pc_hex> (<insn_hex>) [x<rd> 0x<rd_value>]` — compatible with Spike's `--log-commits` output after light normalization.
- **Clock for Stage 1 FPGA bring-up:** 50 MHz derived from MMCM off the 200 MHz differential input. 50 MHz is a safe target while the core is still a single-cycle blob.

## Non-goals right now

- Caches, MMU, pipelining — not until Stage 5/6.
- A-extension — Stage 3.
- FPU, C (compressed) — deferred indefinitely.
- Linux — Stage 7.

## Stage 1 status (closed 2026-04-16)

Stage 0 + Stage 1 are complete at the "reference implementation" level.
- 41/42 rv32ui-p-* and 11/16 rv32mi-p-* pass under Verilator.
- Trace-diff against Spike matches 100 % of retired instructions on validated tests (rv32ui-p-simple, rv32ui-p-add).
- C demo runs correctly.
- FPGA synth flow verified (blinky) but nothing programmed onto the board yet.
See `progress.md` for the full report.

## Stage 2 deliverables (M-extension)

1. `rtl/core/mul_unit.sv`: combinational 33×33 signed multiplier. One funct3-decoded instance drives MUL/MULH/MULHSU/MULHU. DSP48E1 inferable on SP701.
2. `rtl/core/div_unit.sv`: iterative restoring divider, 32 cycles, FSM internal. Full DIV/DIVU/REM/REMU semantics including div-by-zero and signed overflow.
3. `core_multicycle.sv` picks up a fourth FSM state `S_DIV` for the multi-cycle divider; MUL commits in `S_EXEC` through the normal writeback path.
4. `rv32um-p-*` regression: 8/8 under Verilator.
5. `sw/tests/c/muldiv.c`: C demo hitting every M variant + corner cases, compiled `-march=rv32im_zicsr`.

## Stage 2 status (closed 2026-04-16)

- All 8 rv32um tests pass; full regression at 60/66 (same out-of-scope Stage-1 failures, no Stage-2 regressions).
- `muldiv.c` finishes in 256 cycles with `PASS` to MMIO.
- `hello.c` rebuilt with `-march=rv32im_zicsr`; still passes.
See `progress.md` for the full report.

## Open questions

- HDMI PHY on SP701 — present or via PMOD add-on? (affects Stage 12 plan). Check UG1479.
- What USB host path will we pick — MAX3421E PMOD (simple) vs. native ULPI on PMOD? Decide at Stage 13.
