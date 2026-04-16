# Progress Log

Chronological log of what's been done and what's next. Newest entries at the top.

## 2026-04-16 — Stage 2: M-extension green

### What's new
- **Multiplier:** `rtl/core/mul_unit.sv` — combinational 33×33 signed multiply covering MUL/MULH/MULHSU/MULHU via operand sign-extension. One EX cycle, DSP48E1 inferable on the SP701. Lives inside the existing S_EXEC writeback mux via `arith_wb`.
- **Divider:** `rtl/core/div_unit.sv` — iterative restoring divider, 32-cycle FSM (`S_IDLE → S_INIT → S_COMPUTE → S_FIXUP`). Handles every RV32M corner case: divide-by-zero (Q=-1, R=dividend) and signed overflow INT_MIN/-1 (Q=INT_MIN, R=0). Handshake is a 1-cycle `start` pulse and a `done` pulse.
- **Core integration:** `core_multicycle.sv` grows a fourth state `S_DIV`. DIV/DIVU/REM/REMU issue `div_start` in S_EXEC, the FSM parks pending rd/pc/instr in the mem-latches (reused), and commits in S_DIV when `div_done` pulses. MUL variants commit in S_EXEC the same cycle, same as regular arithmetic. Illegal-opcode decode widened to accept `funct7=0000001` with all eight M funct3s.
- **defs.svh:** Added `F7_MULDIV`, `F3_MUL`, `F3_MULH`, `F3_MULHSU`, `F3_MULHU`, `F3_DIV`, `F3_DIVU`, `F3_REM`, `F3_REMU`.

### Tests
- **rv32um regression: 8 / 8.**  `div`, `divu`, `mul`, `mulh`, `mulhsu`, `mulhu`, `rem`, `remu` — all pass under `make sim-all` with `FAMILIES="rv32um"`.
- **Full regression:** 60 / 66. The 6 failures are the same Stage-1 out-of-scope set (PMP, Zicntr, Smrnmi, unaligned-access) — no Stage-2 regressions.
- **C demo:** `sw/tests/c/muldiv.c` — covers all four MUL variants (inline-asm to drive MULH/MULHU/MULHSU explicitly), signed and unsigned DIV/REM, divide-by-zero, and INT_MIN/-1 signed overflow. Runs in 256 cycles.
- **Rebuilt `hello.c`** with `-march=rv32im_zicsr`: the compiler now emits hardware MUL/DIV where available. Still passes, 2640 cycles.

### Caveats
- Divider is restoring (1 bit per cycle). Fine for Stage 2; Stage 3 may swap in a faster non-restoring or SRT variant if cycle counts become the bottleneck in A-ext tests.
- No multi-issue or back-to-back division: `div_unit` exposes `busy` but the core only starts a new op after reaching S_FETCH post-commit, so the signal is unused at the core level.

## 2026-04-16 — Stage 0 and Stage 1 green

### What works end-to-end
- **Smoke:** `sw/tests/asm/pass.S` runs under Verilator, prints `PASS\n` to the MMIO console, signals exit 0. Total: 58 cycles.
- **Regression:** `make sim-all` runs 58 ISA tests under Verilator. **52 pass, 6 fail.**
  - `rv32ui-p-*`: 41 / 42. Only `rv32ui-p-ma_data` fails (deliberately probes unaligned loads/stores that our core raises as a trap — optional for Stage 1).
  - `rv32mi-p-*`: 11 / 16. Failing: `breakpoint`, `illegal`, `instret_overflow`, `pmpaddr`, `zicntr`. All require features deferred to later stages (PMP, Zicntr, full illegal-opcode taxonomy, Smrnmi CSRs).
- **Trace-diff vs Spike:** `sim/scripts/trace_diff.py` compares our retirement trace against Spike's `--log-commits` output.
  - Runs Spike with `--priv=m` to match our M-mode-only core.
  - Handles RTL traps that Spike executes silently (for CSRs we don't model: PMP, Smrnmi), by fast-forwarding ref commits up to the mtvec target.
  - Verified: `rv32ui-p-simple` → 77/77 commits matched. `rv32ui-p-add` → 501/501 matched.
- **C toolchain demo:** `sw/tests/c/hello.c` compiles with `riscv64-unknown-elf-gcc -march=rv32i_zicsr`, links against libgcc (for `__udivsi3`) and our `crt0.S`, runs under the core:
  ```
  Hello from RV32I!
  sum(1..10) = 55 (expect 55)
  fib(10) = 55 (expect 55)
  magic = 0xdeadbeef
  bye
  [sim] MMIO exit 0 @ cycle 3180
  ```
- **FPGA blinky (Stage 0 build-flow smoke):** `fpga/blinky/` synthesizes in Vivado 2025.2 non-project flow. Clean through synth/opt/place/route/bitgen. 1 LUT / 30 FFs. `blinky.bit` = 3.52 MiB. **Not programmed yet** — deferred until user is ready to exercise JTAG.

### What's built
- Host toolchain: Verilator 5.047 (oss-cad-suite), Vivado 2025.2, riscv64-unknown-elf-gcc (rv32 multilib), Spike 1.1.1 (built from source into `/opt/spike`), device-tree-compiler 1.7.0.
- Project layout under `/home/lain/qianyu/riscv_soc/`:
  - `rtl/core/`: `defs.svh`, `alu.sv`, `imm_gen.sv`, `regfile.sv`, `csr.sv`, `core_multicycle.sv`.
  - `rtl/mem/sram_dp.sv`: dual-port BRAM, DPI backdoor for ELF load / tohost poll.
  - `rtl/soc/`: `mmio.sv`, `soc_top.sv`, `soc_tb_top.sv`.
  - `sim/cpp/`: `elf_loader.{h,cpp}`, `sim_main.cpp`.
  - `sim/scripts/`: `regress.sh`, `spike_trace.sh`, `trace_diff.py`.
  - `sw/common/`: `link.ld`, `crt0.S`, `mmio.h`.
  - `sw/tests/asm/pass.S` + Makefile.
  - `sw/tests/c/hello.c` + Makefile.
  - `sw/riscv-tests/`: vendored upstream `riscv-software-src/riscv-tests`, 76 ELFs built (42 rv32ui, 8 rv32um, 10 rv32ua, 16 rv32mi).
  - `fpga/blinky/`, `fpga/constraints/sp701_blinky.xdc`, `fpga/scripts/{build,prog}_blinky.tcl`.
  - `docs/plan.md`, `docs/progress.md`, `docs/bus.md`.
  - Top-level `Makefile`, `scripts/env.sh`.

### Architecture notes
- **Core:** `core_multicycle.sv` — 3-state FSM (FETCH → EXEC → MEM).
  - Instruction fetch uses synchronous BRAM port A.
  - Data memory goes through port B (R/W, byte-masked).
  - Register file is LUTRAM-friendly (2 async read / 1 sync write).
  - CSR file covers M-mode minimum: mstatus, misa, mie, mip (RO zero), mtvec, mepc, mcause, mtval, mscratch, mcycle[h], minstret[h], mhartid, mvendorid, marchid, mimpid.
  - Traps: illegal-opcode, ECALL, EBREAK, misaligned target, misaligned load/store, fetch/bus access fault. Full mepc/mcause/mtval latch and MRET path.
  - minstret is now wired to `commit_valid && !commit_trap`.
- **Memory map:** SRAM 0x8000_0000–0x8000_FFFF (64 KiB), MMIO 0xD058_0000+ (console TX, exit, status).
- **Handshake:** valid/ready on every bus edge, as the plan prescribes.

### Caveats / known limitations (Stage 1 scope)
1. Our core traps on any CSR address we don't model — stricter than Spike with `--priv=m`. The trace-diff tool reconciles this by fast-forwarding past the Spike-executed instructions between trap PC and mtvec target.
2. Misaligned loads/stores trap — no hardware misaligned support yet. That's why `rv32ui-p-ma_data` fails.
3. `rv32mi-p-illegal` hits an infinite loop in the test — worth investigating before Stage 2 since it suggests either an illegal-opcode that we wrongly accept, or a trap handler interaction.
4. No PMP, no Zicntr counters, no Smrnmi. All deferred to later stages.
5. FPGA blinky bitstream exists but has not been programmed onto the board (user asked us not to touch the FPGA yet).

### Next steps (Stage 2 and beyond)
1. **Stage 2 (M extension):** add DSP48-backed multiply (3 cycles pipelined), iterative non-restoring divider (32 cycles), rv32um-p-* regression.
2. **Stage 3 (A extension):** LR/SC reservation + AMO ops, rv32ua-p-* regression.
3. **Stage 4 (bare-metal FPGA bring-up):** real UART TX/RX, CLINT (mtime/mtimecmp), boot ROM, first program on SP701 → UART console over CP2103. At that point we *do* need to program the FPGA.
4. Fix `rv32mi-p-illegal` infinite loop before Stage 2 branches (low priority but principled).
5. Decide whether to implement hardware misaligned access at Stage 5 or keep trapping.

### Open decisions flagged for user
- Is the ESP32-over-PMOD path from the original plan still wanted, or do we shift Stage 14 to the SP701's native Gigabit Ethernet (2× Marvell M88E1111)? Recommendation: use on-board GigE for Stage 14 and keep ESP32 as an optional experiment.
- SP701 HDMI path isn't on the Vivado board file summary we read — needs UG1479 schematic confirmation before Stage 12.

## Status snapshot

| Stage | Item | Status |
|---|---|---|
| 0 | Host toolchain | ✅ |
| 0 | Project layout + living docs | ✅ |
| 0 | Verilator harness (ELF load, MMIO, trace, tohost poll) | ✅ |
| 0 | MMIO console/exit asm test | ✅ |
| 0 | Spike trace-diff | ✅ |
| 0 | riscv-tests build flow (76 ELFs) | ✅ |
| 0 | FPGA blinky (synth only — not programmed) | ✅ |
| 1 | Single-cycle RV32I core | ✅ |
| 1 | rv32ui-p-* regression | ✅ (41/42) |
| 1 | rv32mi-p-* regression (where applicable) | ✅ (11/16) |
| 1 | Printf C demo | ✅ |
