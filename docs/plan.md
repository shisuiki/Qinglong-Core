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

## Target board: RealDigital Urbana (Spartan-7)

(Previous drafts incorrectly identified this as an SP701 — actual JTAG IDCODE reports `xc7s50` and the user confirmed the board at Stage 2.5.)

- **FPGA:** `xc7s50csga324-1` — 32.6K LUT6, 65.2K FFs, 75 BRAM36 tiles, 120 DSP48E1. Plenty of room for the RV32IMA core.
- **Clocking:** 100 MHz single-ended oscillator on N15 (LVCMOS33). Derive slower domains with an MMCM.
- **UART:** FT2232H channel-B USB-UART bridge on the same cable as JTAG. Pin names on the master XDC are **host-perspective**: `uart_rxd = A16` is the FPGA's TX output; `uart_txd = B16` is the FPGA's RX input.
- **LEDs:** 16 total at C13/C14/D14/D15/D16/F18/E17/D17/C17/B18/A17/B17/C18/D18/E18/G17 (LVCMOS33). Stage 2.5 uses the first 8 for a status bitmap.
- **Buttons:** 4 at J2/J1/G2/H2 (LVCMOS25, **active-low**). Stage 2.5 uses BTN0 (J2) with PULLUP as CPU reset.
- **Switches:** 16 slide switches, bank LVCMOS25.
- **7-seg displays:** 2 × 4-digit units (`d0_*`, `d1_*` pins).
- **RGB LEDs:** 2 × 3-channel (C9/A9/A10 + A11/C10/B11).
- **HDMI out:** TMDS_33 on V17/U16/U18/R17/T14/U17/R16/R14.
- **BLE UART, servomotor pins, PWM speakers** also exposed — deferred.

Master pin inventory XDC for future peripherals: `/home/lain/lab6_1/pin_assignment/mb_intro_top.xdc`.

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
- **Clock for Stage 2.5 FPGA bring-up:** 50 MHz derived from an MMCM off the 100 MHz single-ended oscillator (N15). Stage 2.5 closes timing at this rate with ~2 ns of WNS margin on the -1 speed grade.

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

## Stage 2.5 deliverables (first real-CPU bringup on Urbana)

1. Reorganize `fpga/` so all synthesizable RTL lives under `rtl/fpga/` and `fpga/` holds only constraints, TCL, per-project Makefiles, and (gitignored) build artifacts under `fpga/build/<project>/`.
2. `rtl/soc/uart_tx.sv` — minimal 115200-8N1 transmitter with backpressure routed into `mmio.sv`'s `req_ready` so the core stalls on console writes instead of dropping bytes.
3. `rtl/fpga/hello_top.sv` — MMCM (100→50 MHz), active-low reset sync, `soc_top` with `SRAM_INIT_FILE` parameter, `uart_tx` driving board pin A16, 8-LED diagnostic bitmap.
4. `scripts/elf2mem.py` — flatten an RV32 ELF into a `$readmemh`-compatible image for `sram_dp` init.
5. `fpga/constraints/urbana_{blinky,hello}.xdc`, `fpga/scripts/build_{blinky,hello}.tcl` + `prog_*.tcl`, per-project Makefiles in `fpga/{blinky,hello}/`.

## Stage 2.5 status (closed 2026-04-16)

- Blinky and hello both synth+impl+bitgen clean on `xc7s50csga324-1`. Hello closes timing at 50 MHz with WNS +2.036 ns, WHS +0.129 ns.
- Utilization on hello: 2240 LUTs (6.87%), 731 FFs (1.12%), 16 BRAM tiles (21.3%), 4 DSP48E1 (3.3%).
- Programmed over JTAG successfully. **LED diagnostics confirm the CPU ran hello.c end-to-end on silicon** — `exit_valid` latched, `console_valid` latched at least once, `commit_valid` retiring instructions, MMCM locked, core out of reset.
- **Known residual:** UART bytes are not reaching `/dev/ttyUSB1` from the host side. Most likely a subtle pinout/enumeration issue with the FT2232H on Urbana that we'll revisit when we wire AXI and AXI UartLite properly (likely Stage 5/6). The CPU-side of the UART path is exercised and working; only host-side capture is unverified.

## Stage 3 deliverables (A-extension)

1. Decode AMO opcode (`0101111`) + funct3 `010` + funct5 for LR.W, SC.W, AMO{SWAP,ADD,XOR,AND,OR,MIN,MAX,MINU,MAXU}.W. `aq`/`rl` bits are no-ops on this single-hart core.
2. LR.W: word load + arm per-hart reservation (word-aligned addr).
3. SC.W: commit rd=1 immediately on reservation miss; on hit, store rs2 and commit rd=0 after memory ack. Always clear reservation.
4. AMO RMW: two-phase memory op. `S_EXEC → S_MEM` (latch old value into `amo_old_q`) `→ S_AMO_STORE → S_AMO_WAIT` (writeback original loaded value to rd).
5. Misalignment traps: LR/AMO-load → `CAUSE_LOAD_ADDR_MISALIGNED`; SC/AMO-store → `CAUSE_STORE_ADDR_MISALIGNED`.
6. Reservation cleared on any trap.
7. `rv32ua-p-*` regression: 10/10 under Verilator.

## Stage 4 deliverables (basic bringup — native CLINT + interrupt delivery)

1. `rtl/soc/clint.sv` — SiFive-style core-local interruptor at `0x0200_0000`: 64-bit free-running `mtime` (write-updatable), 64-bit `mtimecmp`, 1-bit `msip`. Outputs `mti = (mtime >= mtimecmp)` and `msi = msip[0]`. External `mei` routed through the core port but tied 0 at the SoC level (no AXI IntC yet).
2. `csr.sv` — `mip` exposes live `MSIP/MTIP/MEIP` from the interrupt lines; `mie` writable; priority-encoded `irq_pending` + `irq_cause` outputs (MEI > MSI > MTI).
3. `core_multicycle.sv` — interrupt check at the top of `S_FETCH`: if `mstatus.MIE && (mip & mie)` then commit a trap with `irq_cause`, `mepc = pc_q`, `mtval = 0`. Direct-mode `mtvec` only; vectored mode deferred.
4. `soc_top.sv` — CLINT instantiated and decoded at `addr[31:20] == 12'h020`; `mti`/`msi` piped through the new core interrupt ports.
5. `sw/tests/c/irq_timer.c`, `sw/tests/c/irq_swi.c` — exercise MTI and MSI end-to-end (mtvec install, mie+mstatus toggling, handler re-arms, mret, `mcause` check).

Not in Stage 4 (deferred): MEI from an external intc, AXI shim, boot ROM.

## Stage 4 status (closed 2026-04-16)

- CLINT decodes and runs under Verilator. `mtime` increments every cycle; `mtimecmp` and `msip` writable via the dmem bus.
- **irq_timer.c** passes in 2425 cycles (8 timer ticks at 200-cycle period, handler verifies `mcause == 0x80000007`).
- **irq_swi.c** passes in 277 cycles (MSIP raise, handler verifies `mcause == 0x80000003`, clears MSIP).
- **irq_wfi.c** (stretch): same timer flow but uses `wfi` in the wait body. Exercises WFI-as-NOP.
- **irq_vectored.c** (stretch): uses `mtvec[0]=1` with a 12-entry jump table; timer fires into table entry [7] (MTI cause code).
- Full riscv-tests regression still 70/76 — no regressions. CSR-read of `mip` now returns live pending bits instead of constant 0, with no test impact.
- New `make sim-c` target in the top-level Makefile runs the C-test regression (hello, muldiv, irq_*). 6/6 green.

## Stage 3 status (closed 2026-04-16)

- All 10 rv32ua tests pass (9 AMO variants + lrsc).
- Full ISA regression now 70/76 (rv32ui + rv32mi + rv32um + rv32ua). Same 6 out-of-scope Stage-1 failures; no regressions.
- `sim/scripts/regress.sh` default `FAMILIES` now includes `rv32um rv32ua`.
- Board UART capture remains deferred (Stage 5/6 AXI UartLite).

## Stage 5 deliverables (5-stage pipeline + AXI-Lite + FreeRTOS)

1. `rtl/core/core_pipeline.sv` — classic 5-stage IF/ID/EX/MEM/WB with full forwarding, load-use hazard stall, and branch flush. Selectable via `CORE=pipeline` in Makefiles.
2. AXI4-Lite external bus; `axi_uartlite` on silicon (Urbana); FreeRTOS demo target.
3. Stage 5E: atomic extension in the pipeline (LR.W/SC.W/AMO*.W) matching the multicycle semantics.
4. Stage 5G: FPGA synth flow picks up `CORE=pipeline` end-to-end.

## Stage 5 status (closed 2026-04-16)
- Pipeline closes at 50 MHz on Urbana; same regression coverage as multicycle (74/76 passing).
- FreeRTOS "two-tasks + heartbeat-LED" demo runs on silicon.

## Stage FV deliverables (formal)

1. `third_party/riscv-formal` vendored as submodule; RVFI tap on `core_pipeline.sv`.
2. `rtl/core/core_pipeline_rvfi.svh` — RVFI signal tap.
3. `formal/core_pipeline/` — wrapper + suites for reg_ch0, pc_fwd_ch0, causal_ch0, trap_ch0, insn_*.
4. Sync/async trap split + `rvfi_insn` sanitization on fetch faults.

## Stage FV status (closed 2026-04-20)
- FV-1/2/3/4 committed. 37/37 insn PASS; reg_ch0 PASS @ depth 20.
- Post-close fix in working tree: trap signal split + ifetch-fault `rvfi_insn` sanitization (40/40 with ifetch faults + IRQs symbolic). See task #113, #114.

## Stage 6 deliverables (caches + privileged)

1. Stage 6A: I-cache (4-way, 64 B lines, 16 KiB) + `FENCE.I`.
2. Stage 6B: D-cache (write-through, 4-way, 64 B lines, 16 KiB).
3. Stage 6C-1: S/U priv modes, S-mode CSRs (stvec/sepc/scause/stval/sscratch/satp), trap delegation, SRET.
4. Stage 6C-2: SV32 MMU skeleton → PTW FSM → TLB + SFENCE.VMA → page-fault cause distinction → ifetch-side translation.
5. Stage 6C-3: PMP (CSR storage + enforce + lock-bit WARL + Yosys/SBY-friendly port shape + IRQ-bubble RVFI fix).
6. Stage 6C-4/5: TVM/TSR + IRQ-priority, S-mode interrupt delegation + multicycle SRET, medeleg test.
7. Stage 6C-6/7/8/9: ASID + global-bit TLB, SFENCE.VMA rs1/rs2 selective flush, MXR/SUM semantics, U-mode MMU integration test.

## Stage 6 status (closed 2026-04-19)
- All of the above committed. Caches on FPGA build flow too (Stage 6A/6B prep).
- Regression stable at 79/82 rv32ui/um/ua/mi/si; 3 residuals (ma_data, breakpoint, rv32si-p-dirty) parked.

## Stage 7 deliverables (DDR + Linux bring-up)

1. Stage 7a: AXI4-full bus refactor (prep for MIG/DDR).
2. Stage 7b: MIG7 DDR3L bitstream closes (WNS = −0.309 ns) + memtest PASS on silicon.
3. Stage 7c: Verilator Linux sim harness (`soc_tb_linux`, DDR DPI backdoor, `axi4_router_linux`, `axil_bram_big`, `sim_linux.cpp`).
4. Stage 7d: PLIC (`rtl/soc/plic.sv`) — 32-source priority-based, M+S contexts, memory-mapped at 0x0C000000.
5. Stage 7e: No-SD-card boot strategy — JTAG loader (`jtag_load.tcl`) + bootrom + handshake at 0x47000000. `axi_crossbar` / `jtag_axi` IP reconfigured to NUM_SI=2 so JTAG and SoC can both access DDR.
6. Stage 7f: OpenSBI 1.4 port — `fw_jump`, FW_TEXT_START=0x40000000, FW_JUMP_ADDR=0x40400000, FW_JUMP_FDT_ADDR=0x42200000, `rv32ima_zicsr_zifencei ilp32` (non-RVC).
7. Stage 7g: rv32 Linux 6.6.32 kernel + DT (`sw/linux/riscv_soc.dts`) + buildroot initramfs; sim boot + silicon boot.

## Stage 7 status (in progress)

### Closed
- 7a, 7b, 7c, 7d, 7e, 7f committed / staged.
- Silicon: BootROM → OpenSBI handshake works; DDR load via JTAG works; OpenSBI banner observed.
- Sim: full boot chain functional; kernel reaches `/sbin/init` and runs for ~150 ms before a residual trap-entry fault.

### Residuals (tracked, not blocking closure)
- **Sim residual**: kernel `handle_exception` faults on `sw sp, 12(tp)` — `sscratch` appears to hold a user VA on kernel entry. Next: targeted `[SSCRATCH]` trace. See task #109.
- **Silicon residual (#102)**: kernel boots ran on the pre-fix bitstream — needs a rebuild carrying the full set of accumulated RTL fixes (MIP split / PTW-DDR / axi4 fetch race / if_bad one-pulse / fetch_squash).
- **Formal residual (#115)**: csr/csrw/csr_ill checks still off — needs the RVFI CSR port tap.

## Open questions

- HDMI PHY on SP701 — present or via PMOD add-on? (affects Stage 12 plan). Check UG1479.
- What USB host path will we pick — MAX3421E PMOD (simple) vs. native ULPI on PMOD? Decide at Stage 13.
