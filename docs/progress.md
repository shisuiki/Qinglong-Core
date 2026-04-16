# Progress Log

Chronological log of what's been done and what's next. Newest entries at the top.

## 2026-04-16 — Stage 4: native CLINT + interrupt delivery

### What shipped
- **CLINT** (`rtl/soc/clint.sv`) — SiFive-style memory-mapped interruptor at `0x0200_0000`. 64-bit `mtime` incremented every cycle (writable so software can set the clock), 64-bit `mtimecmp`, 1-bit `msip`. Outputs `mti = (mtime >= mtimecmp)` and `msi = msip[0]`. Matches the rest of the dmem fabric: combinational `req_ready=1`, 1-cycle `rsp_valid`, byte-maskable writes.
- **`csr.sv` interrupt surface** — new inputs `ext_mti/ext_msi/ext_mei`, composed into `mip_live` (MSIP=bit3, MTIP=bit7, MEIP=bit11). CSR-read of `mip` now returns these live bits (was constant 0). `irq_pending = mstatus.MIE && (mip_live & mie_q)`, with `irq_cause` priority-encoded MEI > MSI > MTI.
- **Core trap boundary** (`core_multicycle.sv`) — interrupt check at the top of `S_FETCH`: if `irq_pending`, commit a trap with `mepc = pc_q`, `mcause = irq_cause`, `mtval = 0`, then jump to `{mtvec[31:2], 2'b00}`. The existing `trap_take`/`trap_pc_in`/`trap_cause_in`/`trap_tval_in` plumbing carries this naturally; added a `fetch_irq_trap` flag so `mtval` is architecturally 0 for interrupts while fetch-access faults still use `pc_q`.
- **SoC decode** (`soc_top.sv`) — CLINT occupies `addr[31:20] == 12'h020` (1 MiB window). Adds `clint_mti/clint_msi` wires and plugs them into the new `ext_mti/ext_msi` core ports. `ext_mei` tied 0 — no external-interrupt controller yet.

### Tests
- **`sw/tests/c/irq_timer.c`** — arms `mtimecmp` for a 200-cycle tick, enables MTIE+MIE, spins; handler verifies `mcause == 0x80000007`, re-arms the comparator for the next tick, `mret`s; main loop waits for 8 ticks then emits PASS. Runs in **2425 cycles**.
- **`sw/tests/c/irq_swi.c`** — sets CLINT `msip=1`, enables MSIE+MIE; handler verifies `mcause == 0x80000003`, clears `msip`, returns; main loop PASSes on first handler entry. Runs in **277 cycles**.
- **Full riscv-tests regression:** 70 / 76 — unchanged from Stage 3. The `mip` read-value change (was hard 0) had no effect on any existing test because they either don't touch `mip` or accept any value for it.

### Stretch additions (same day)
- **`wfi` decoded as architectural NOP.** System-PRIV accepts `12'h105` in addition to ECALL/EBREAK/MRET; commit falls through the standard single-cycle path with PC+4 and no writeback. The next S_FETCH is where interrupts land, so `wfi` is correct-by-construction in a loop `while (!done) { wfi; }`.
- **`mtvec` vectored mode supported.** When `mtvec[0]=1`, interrupt targets are `base + 4*cause_code` — exceptions still go to base. The `irq_cause_v[3:0]` field covers MSI=3 / MTI=7 / MEI=11.
- **C regression harness.** New `make sim-c` target runs every ELF in `sw/tests/c/`, passing if the MMIO-exit-0 line appears in the log. Currently 6/6 green: `hello`, `muldiv`, `irq_timer`, `irq_swi`, `irq_wfi`, `irq_vectored`.

### Counter-write fix (same day)
- **`rv32mi-p-instret_overflow` now passes** (regression 70→71/76). Root cause: `csr.sv` applied both the retire-increment and a software `csrw` to `minstret`/`minstreth` in the same cycle; the 64-bit increment was overwriting bits the software write didn't touch (e.g. writing `minstreth` would zero the just-written low word because `retire`'s +1 also clobbered it). Fix is one-liner: gate the counter increment on "not writing to that counter this cycle" — per RISC-V spec, the software write wins. Applied symmetrically to `mcycle`/`mcycleh`.

### Caveats
- No AXI shim; CLINT is on the native ready/valid fabric. Plan is to wrap the dmem bus as AXI-Lite only when MMU work starts and we also want AXI peripherals (UartLite, IntC).
- Single-hart CLINT. `mhartid` is hard 0 and the CLINT has exactly one msip / one mtimecmp.
- WFI is a no-op architectural hint in this impl — the core doesn't actually idle clock gating. Spec-compliant; room to add power optimisations later if the pipeline grows.

## 2026-04-16 — Stage 3: A-extension green

### What shipped
- **Decode.** `defs.svh` gains `OP_AMO (0101111)`, `F3_AMO_W`, and the eleven A-extension funct5 constants (`AMO_LR/SC/SWAP/ADD/XOR/OR/AND/MIN/MAX/MINU/MAXU`). `aq`/`rl` bits are accepted and ignored — this is a single-hart in-order core, so they're architectural no-ops.
- **Core integration** (`core_multicycle.sv`):
  - State enum widens to 3 bits, adds `S_AMO_STORE` and `S_AMO_WAIT`.
  - New latched regs: `is_lr_q`, `is_sc_q`, `is_rmw_q`, `amo_old_q`, `resv_valid_q`, `resv_addr_q[29:0]` (word-granular reservation).
  - LR.W path: issues a word load in `S_EXEC`, writes back `load_result` in `S_MEM` and arms the reservation there.
  - SC.W path: `sc_hit = resv_valid_q && resv_addr_q == mem_addr[31:2]`. On miss, commits rd=1 in `S_EXEC` (no bus traffic). On hit, issues the store and commits rd=0 in `S_MEM` after ack. Either way clears the reservation.
  - AMO RMW path: `S_EXEC` issues load → `S_MEM` latches `amo_old_q <= dmem_rsp_rdata` and advances to `S_AMO_STORE` → `S_AMO_STORE` drives the store with `amo_result = op(amo_old_q, rs2_data)` → `S_AMO_WAIT` commits the *original* loaded value to rd when the store rsp arrives, and clears the reservation.
  - Reservation is also cleared on any trap (fetch-fault, illegal, misalign, ECALL, EBREAK, load/store/AMO access-fault).
  - Misalignment traps: LR-misaligned → `CAUSE_LOAD_ADDR_MISALIGNED`; SC/AMO-misaligned → `CAUSE_STORE_ADDR_MISALIGNED`; `tval = mem_addr`.
  - Illegal-opcode extended to accept OP_AMO iff funct3=010 and funct5 ∈ {known set}; LR.W requires rs2 == 0.
  - `trap_pc_in` / `trap_tval_in` now also route from the `S_AMO_WAIT` state.
- **ALU driver.** Added `is_amo: alu_a=rs1, alu_b=0, alu_op=ADD` so `mem_addr = rs1` — AMOs carry no immediate offset.

### Tests
- **rv32ua regression: 10 / 10.** `amoadd_w`, `amoand_w`, `amomax_w`, `amomaxu_w`, `amomin_w`, `amominu_w`, `amoor_w`, `amoswap_w`, `amoxor_w`, `lrsc` — all PASS under Verilator. `lrsc` is the slowest at 20914 cycles (exercises reservation corners in a long loop); the AMO tests finish in 330–380 cycles each.
- **Full regression: 70 / 76.** Same six pre-existing out-of-scope Stage-1 failures (`ma_data`, `breakpoint`, `illegal`, `instret_overflow`, `pmpaddr`, `zicntr`). No regressions in rv32ui / rv32mi / rv32um.
- **`sim/scripts/regress.sh`** default `FAMILIES` widened to `rv32ui rv32mi rv32um rv32ua` so `make sim-all` now covers the full ISA set we implement.

### Caveats
- Single-hart implementation, so `aq`/`rl` ordering bits have no observable effect. When we add a second hart or cache coherence, reservation invalidation logic will need to extend beyond the single-hart model used here (e.g. snoop-driven clears).
- AMO RMW is 4 bus cycles in the best case: `S_EXEC` (load issue) → `S_MEM` (load rsp) → `S_AMO_STORE` (store issue) → `S_AMO_WAIT` (store rsp). Plenty of room to pipeline later if it becomes a bottleneck.
- Board UART capture is still unverified on silicon (deferred to Stage 5/6 AXI UartLite integration).

## 2026-04-16 — Stage 2.5: first real-CPU bringup on Urbana silicon

### What shipped
- **Layout reshuffle.** All synthesizable RTL now lives under `rtl/`, including FPGA-only tops under `rtl/fpga/`. The `fpga/` tree only holds XDCs, TCL scripts, per-project Makefiles, and (gitignored) build outputs in `fpga/build/<project>/`. Blinky still synths cleanly from the new layout.
- **UART TX** (`rtl/soc/uart_tx.sv`) — 115200-8N1, stall-on-busy semantics routed back through `mmio.sv`'s `req_ready` so the CPU stalls on console writes rather than dropping bytes. Sim ties `console_ready` high unconditionally; hello regression + muldiv still pass.
- **Hello top** (`rtl/fpga/hello_top.sv`) — MMCM (100 MHz → 50 MHz, VCO 1000), active-low reset sync, `soc_top` with pass-through `SRAM_INIT_FILE`, `uart_tx` on board pin A16, and an 8-LED status bitmap (heartbeat / MMCM locked / rst_n / out-of-reset / commit stretched / exit_valid / console latched / UART line level).
- **ELF→mem** (`scripts/elf2mem.py`) — flattens an RV32 ELF's PT_LOAD segments into a `$readmemh` hex image for `sram_dp` to initialize BRAM at bitgen time.
- **Board retarget.** Mid-stage the user corrected our board identity: it's a **RealDigital Urbana (`xc7s50csga324-1`)**, not an SP701. Rewrote XDCs (urbana_blinky.xdc, urbana_hello.xdc), swapped the part in both build TCLs, dropped the IBUFDS (single-ended 100 MHz clock on N15), flipped to active-low reset on BTN0 (J2), and moved the UART TX pin to A16 (board's `uart_rxd` = FPGA output — host-perspective naming).

### Results on silicon
- **Blinky:** synth+impl+bitgen clean on xc7s50.
- **Hello:** synth+impl+bitgen clean. Timing at 50 MHz: WNS +2.036 ns, WHS +0.129 ns. Util: 2240 LUTs (6.87%), 731 FFs (1.12%), 16 BRAM36 tiles (21.3%), 4 DSP48E1 (3.3%).
- **Programmed over JTAG successfully.** LED bitmap readout from the board:
  - LED[0] blinking ~1.5 Hz → MMCM + BUFG + core_clk alive.
  - LED[1] on → MMCM locked.
  - LED[2] on → BTN0 idle-high, reset logic sane.
  - LED[3] on → core out of reset.
  - LED[4] on → `commit_valid` retired at least one instruction (stretched pulse stuck on).
  - LED[5] on → software reached `mmio_exit(0)`.
  - LED[6] on → software emitted at least one byte to `0xD0580000` (console_valid fired).
  - LED[7] on → UART line idle-high after transmission.
- **This confirms the RV32IM core ran hello.c end-to-end on real silicon:** crt0 → main → mmio_puts → mmio_exit, all emitted traffic through the MMIO console, and halted. Everything CPU-side from BRAM init to commit-pulse is validated.

### Known residual (deferred)
- UART bytes are not landing on `/dev/ttyUSB1` from the host side. The FPGA is driving the A16 pin correctly (led[7] + led[6] prove the software wrote the console and the UART idled back to high after), but the host isn't catching the bytes — likely an FT2232H channel / baud / inversion subtlety on the Urbana's USB bridge that doesn't matter until we wire a proper AXI UART-Lite. Parked until Stage 5/6 AXI integration; won't block Stage 3 (A-extension).

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
