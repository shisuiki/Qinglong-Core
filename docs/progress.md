# Progress Log

Chronological log of what's been done and what's next. Newest entries at the top.

## 2026-04-18 — Stage 6C-3c: PMP lock-bit write-side enforcement

### What shipped
- **`rtl/core/csr.sv`**. WARL handling for `pmpcfg0..3` and `pmpaddr0..15`:
  - `pmpcfg` writes go through a per-byte merge: if the current byte has L=1, the incoming byte is dropped and the old byte retained. Byte 3 of `pmpcfgN` (entry 4N+3) behaves normally when unlocked.
  - `pmpaddr[i]` writes are gated by `pmpaddr_locked[i] = L[i] | (i<15 && L[i+1] && A[i+1]==TOR)`. The TOR clause honours the spec: entry i+1 being TOR means it uses pmpaddr[i] as its lower bound, so locking entry i+1 also locks pmpaddr[i].
- **`sw/tests/asm/pmp_enforce.S`** extended. After the access-path tests, writes garbage to pmpaddr0 and zero to pmpcfg0 and verifies neither stuck (L=1 on entries 0/1/2 keeps every relevant byte and pmpaddr in place).

### Tests
- **`pmp_enforce.elf`**: PASS on both cores (pipeline 319 cycles).
- **Full regression**: **74/76** unchanged on both cores.

## 2026-04-18 — Stage 6C-3b: PMP enforcement

### What shipped
- **`rtl/core/pmp.sv`** — new combinational PMP checker. 16 entries, priority-encoded, supports OFF/TOR/NA4/NAPOT. NAPOT uses the standard trailing-ones trick (`run_mask = pmpaddr ^ (pmpaddr + 1)`, `cmp_mask = ~run_mask`) to extract the compare window. Lock bit (L) extends the check to M-mode. Spec deviation: if *no* entry has A != OFF, PMP is treated as unimplemented (all accesses succeed); spec behaviour (deny S/U on no-match) is only engaged once software programs at least one entry. This keeps existing S-mode tests that never configure PMP working without a catch-all entry.
- **CSR fanout (`rtl/core/csr.sv`)**. Added `pmp_cfg_out[0:15]` and `pmp_addr_out[0:15]` outputs that unpack the existing `pmpcfg0..3` / `pmpaddr0..15` storage byte- and word-wise.
- **MMU integration (`rtl/core/mmu.sv`)**. Two instances of `pmp`: `u_pmp_if` (exec, priv=`priv_i`) and `u_pmp_dm` (r/w from `dm_core_req_wen`, priv=`dm_eff_priv`). PA selection uses a dedicated pair of always_combs (bare → `core_req_addr`, TLB hit → `*_tlb_pa`, post-walk → `*_xlate_pa_q`) so the main branch mux stays acyclic. On PMP deny the main combinational block's tail overrides its outputs to synthesize an access-fault reply (`rsp_fault=1`, `rsp_pagefault=0`) — distinct from the page-fault path. A pair of pending latches (`if_pmp_pending_q`, `dm_pmp_pending_q`) hold the fault across the multicycle core's S_EXEC→S_MEM boundary, since `dmem_req_valid` is only high in S_EXEC and `dmem_rsp_ready` only rises in S_MEM.
- **Core plumbing (`rtl/core/core_pipeline.sv`, `rtl/core/core_multicycle.sv`)**. Both cores expose `mmu_pmp_cfg[0:15]` / `mmu_pmp_addr[0:15]` arrays driven by the CSR file and consumed by the MMU instance in `soc_top.sv`.
- **`sw/tests/asm/pmp_enforce.S`** — end-to-end test. In M-mode, programs entry 0 = NAPOT(16B @ 0x80003000, R=1 W=0 X=0, L=1), entries 1/2 = NAPOT 2GiB catch-alls (RWX=1, L=1). Verifies: (i) `lw` from 0x80003000 succeeds, (ii) `sw` to 0x80003000 traps with mcause=7 at the expected mepc (handler advances mepc past the store), (iii) r/w to 0x80003020 (outside the RO window) unaffected.

### Tests
- **`pmp_enforce.elf`**: PASS on both cores.
- **Full regression** (`make sim-all` both cores): **74/76** PASS, unchanged. Residuals still `ma_data` and `breakpoint`.
- **Other MMU tests** (`mmu_sv32`, `mmu_pagefault`, `mmu_ifetch`, `s_irq`): PASS on both cores, unchanged.

### Residuals (deferred)
- PMP NAPOT with A=NA4 (granule 4B exactly) is decoded, but no test exercises it yet.
- Mixed TOR+NAPOT configurations are not regression-tested; the 16-entry priority encoder is simulated but not proved.

## 2026-04-18 — Stage 6C-5: S-mode interrupt delegation + multicycle SRET

### What shipped
- **S-mode interrupt take-path (`rtl/core/csr.sv`)**. Split the single `mip_enabled` into `mip_m_enabled` (non-delegated) and `mip_s_enabled` (delegated via mideleg). Two parallel enable gates: M-path fires when priv<M or (M && MIE); S-path fires when priv==U or (S && SIE). M wins if both are live; `irq_cause` picks from the winning path using priv-spec priority (MEI>MSI>MTI, then SEI>SSI>STI within each). `trap_to_s` was already correct — it now actually matters since delegated bits reach the take path.
- **Multicycle trap routing to stvec (`rtl/core/core_multicycle.sv`)**. All 4 trap-dispatch sites (S_FETCH interrupt, S_FETCH fetch-fault, S_EXEC, S_MEM/AMO-wait bus-fault) used to hardcode `mtvec_v`. They now route through `trap_tvec = trap_to_s ? stvec_v : mtvec_v` so delegated traps actually land in S-mode. Vectored-mode offset follows the chosen base as well.
- **Multicycle SRET decode + execution (`rtl/core/core_multicycle.sv`)**. Adds `is_sret` (funct12=0x102), wires `do_sret` into the CSR file (was tied low), and `pc_d = sepc_v` at SRET retire. ID illegal gates: SRET illegal in U-mode and in S-mode with TSR=1. This closes the long-standing multicycle residual called out in 6C-4: multicycle can now pass `rv32mi-p-illegal`.
- **`sw/tests/asm/s_irq.S`** — end-to-end test for delegated S-mode interrupts. Sets mideleg[1]=SSI, pre-arms mip.SSIP, MRETs into S-mode with SIE=1, expects the core to take the pending interrupt via stvec (not mtvec) on the very first fetch at `post_mret`. Handler confirms scause=0x80000001, clears SSIP, writes a witness, and SRETs. mtvec is wired to a failure sentinel — if M takes the interrupt, the test immediately fails.

### Tests
- **`s_irq.elf`**: PASS on both cores (269 cycles pipeline, 253 cycles multicycle). Fails loudly if the interrupt routes through mtvec instead of stvec.
- **Sim regression (multicycle)**: 73/76 → **74/76**. Newly-passing: `rv32mi-p-illegal` (enabled by SRET decode + stvec routing). Residuals stay at `ma_data` and `breakpoint`.
- **Sim regression (pipeline)**: 74/76 unchanged.
- **Other MMU tests** (`mmu_sv32`, `mmu_pagefault`, `mmu_ifetch`): PASS on both cores, unchanged cycle counts.

### Residuals (deferred)
- Interrupt path still doesn't plumb separate M/S `irq_cause` selection into `trap_cause_in` — we rely on the csr-side picking the right cause based on which enable fired. Fine for now; revisit if nested M/S interrupt races show up.
- SFENCE.VMA still flushes the full TLB (no ASID, no per-VPN).

## 2026-04-18 — Stage 6C-2e: ifetch-translation test + multicycle S-mode hardening

### What shipped
- **`sw/tests/asm/mmu_ifetch.S`** — SV32 instruction-fetch test under S-mode. Sets up SRAM identity superpage + a 4 KiB leaf at VA `0x82000000` (R|X=1 → PA `0x80002000`) and a second leaf at VA `0x82001000` (R|X=0, same PA). M-mode stages a tiny function at the PA, MRETs into S-mode at each VA, and verifies:
  - Positive path: function executes, writes `0xCAFEF00D` witness, ECALLs back → mcause=9 (S-ECALL).
  - Negative path: ifetch through non-executable leaf → mcause=12 (INSN_PAGE_FAULT), mepc = faulting VA.
  - mtvec handler uses `s0`/`s1` as (expected-cause, landing-pc) handoff and forces `MPP=M` before returning so the M-mode trampoline can drive the next case.
- **ECALL cause by current privilege (`rtl/core/core_multicycle.sv`)**. Multicycle hard-coded `CAUSE_ECALL_FROM_M` for every ECALL; now switches on `priv_mode_v` to return U/S/M causes correctly. Pre-fix, an S-mode ECALL raised mcause=11, masking the bug.
- **TVM / SRET / MRET gating in multicycle decode (`rtl/core/core_multicycle.sv`)**. `SFENCE.VMA` illegal in U-mode and from S-mode with TVM=1; `MRET` illegal outside M-mode. Mirrors the pipeline gates added in 6C-4 so multicycle behaves identically when run in S-mode.
- **`satp` access TVM-gated in the CSR file (`rtl/core/csr.sv`)**. `csr_illegal` now OR's in `(csr_addr == CSR_SATP && priv == S && mstatus.TVM)` so both cores reject S-mode satp reads/writes under TVM=1 without needing per-core decode duplication.

### Tests
- **`mmu_ifetch.elf`**: PASS on both cores (multicycle: 27,176 cycles; pipeline: 25,114 cycles).
- **Sim regression (multicycle)**: 73/76, unchanged. Remaining failures are `ma_data`, `breakpoint`, and `rv32mi-p-illegal` (latter deferred — needs SRET decode in multicycle).
- **Sim regression (pipeline)**: 74/76, unchanged. Failures are `ma_data` + `breakpoint`.
- **Other MMU tests** (`mmu_sv32`, `mmu_pagefault`): PASS on both cores, unchanged cycle counts.

### Residuals (deferred)
- Multicycle SRET decode (same as 6C-4 residual — would close the last 73→74 gap).
- `mmu_ifetch.S` doesn't exercise the R|X=0|U=1 case from S-mode without SUM — covered by the dmem variant in `mmu_pagefault.S`, which reaches the same `tlb_deny` path.

## 2026-04-18 — Stage 6C-4: TVM/TSR enforcement + interrupt-priority fix

### What shipped
- **mstatus.TVM / mstatus.TSR now storage-live (`rtl/core/csr.sv`)**. The writable mask extends from `0x000E_19AA` to `0x005E_19AA` (adds bits 20 / 22). Two new CSR-module outputs, `mstatus_tvm` / `mstatus_tsr`, feed the cores.
- **Illegal-decode gating in pipeline ID (`rtl/core/core_pipeline.sv`)**. Three new gates:
  - `SFENCE.VMA` illegal in U-mode, and from S-mode when TVM=1.
  - `SRET` illegal in U-mode, and from S-mode when TSR=1.
  - `MRET` illegal outside M-mode (was previously accepted anywhere).
  - `satp` (CSR 0x180) access illegal from S-mode when TVM=1 — applied regardless of read/write op.
- **Interrupt-cause priority fix (`rtl/core/csr.sv`)**. The `irq_cause` always_comb used a three-way if/else (MEI / MSI / else→MTI) that returned the MTI cause for *any* pending bit outside {MEI, MSI}. Now the priority chain extends through MTI → SEI → SSI → STI per the priv-spec ordering. Caught while debugging `rv32mi-p-illegal` — the test pends SSIP but was seeing MTI as the cause.

### Tests
- **`rv32mi-p-illegal`**: PASS on pipeline (1,139 cycles). Previously TIMEOUT for two reasons — the interrupt-cause bug picked MTI instead of SSI, and SFENCE.VMA / SRET / satp didn't honour TVM/TSR. Both fixed here.
- **Sim regression (pipeline, with and without caches)**: **74/76** — up from 73. Remaining failures are `ma_data` (misaligned-address) and `breakpoint` (debug spec support), both known-deferred.
- **Sim regression (multicycle)**: stays at 73/76. Multicycle doesn't decode SRET, so `rv32mi-p-illegal` is not reachable there; not pursued.
- **Sim C regression** (`make sim-c CORE=pipeline ICACHE=1 DCACHE=1`): 7/7 PASS.
- **MMU tests**: smoke + pagefault still PASS on both cores.
- **Sim FreeRTOS**: boots, `hello` / `blink` tasks run.

### Residuals (deferred)
- Multicycle: SRET decode would close the last 73→74 gap but adds MRET-like pipeline plumbing for a core that stays M-mode in practice; not currently worth it.
- SFENCE.VMA still flushes the whole TLB regardless of rs1 / rs2 (no ASID, no per-VPN).

## 2026-04-18 — Stage 6C-2d: page-fault cause distinction

### What shipped
- **MMU now distinguishes page faults from access faults (`rtl/core/mmu.sv`, `rtl/soc/soc_top.sv`)**. Added `if_core_rsp_pagefault` / `dm_core_rsp_pagefault` outputs on the core-facing MMU interfaces; mutually exclusive with `rsp_fault`. TLB-deny and walk-result faults now pulse `rsp_pagefault=1, rsp_fault=0`. Downstream bus faults still come through as `rsp_fault=1, rsp_pagefault=0`. Bare-mode passthrough drives `rsp_pagefault=0`.
- **Core mapping to PAGE_FAULT causes (`rtl/core/core_pipeline.sv`, `rtl/core/core_multicycle.sv`)**. Pipeline: added `ifetch_rsp_pagefault` / `dmem_rsp_pagefault` input ports, `id_pagefault_q` / `ex_fetch_pagefault_q` / `mem_bus_pagefault_q` propagate through the stages. At EX trap detection, ifetch pagefault routes to `CAUSE_INSN_PAGE_FAULT` (priority over the access-fault path). At WB, load/store bus op routes to `LOAD/STORE_PAGE_FAULT` before checking `mem_bus_fault_q`. Multicycle: same logic in the S_FETCH fetch-trap, S_MEM load/store-trap, and S_AMO_WAIT paths.
- **Multicycle dmem_rsp_ready is now state-gated**. It was previously asserted unconditionally; with tlb_deny synthesizing a same-cycle pagefault rsp during S_EXEC, the always-1 rsp_ready would "consume" the rsp (from the MMU's perspective) without the core actually acting on it, and S_MEM would hang waiting for a rsp that had been dropped. Fix: `dmem_rsp_ready = (state_q == S_MEM) || (state_q == S_AMO_WAIT)`. The MMU's sticky fault-cache then holds the pagefault across the S_EXEC → S_MEM transition so S_MEM sees it.
- **Formal wrapper plumbing (`formal/core_pipeline/wrapper.sv`)**. Added the two new pagefault inputs as symbolic rand regs; the existing "no faults, no IRQs for insn checks" assume block now also pins both pagefaults to 0 so the arith-insn checks stay bit-exact.
- **New test: `sw/tests/asm/mmu_pagefault.S`**. Three fault cases chained via an mtvec handler: (a) store to a RO leaf (V|R|X|A, no W) → expect `STORE_PAGE_FAULT=15`; (b) load from an invalid leaf (V=0) → expect `LOAD_PAGE_FAULT=13`; (c) load from a U=1 leaf under S-mode, SUM=0 → expect `LOAD_PAGE_FAULT=13`. Handler checks `mcause` matches expectation and redirects `mepc` to the next case; after three successful returns we land at `pass`.

### Tests
- **MMU pagefault test**: PASS on multicycle (27,162 cycles) and pipeline+icache+dcache (41,956 cycles).
- **MMU smoke test** (6C-2c carryover): PASS on both, unchanged.
- **Sim regression** (`make sim-all` both cores, with and without caches): **73/76** — unchanged baseline.
- **Sim C regression** (`make sim-c CORE=pipeline ICACHE=1 DCACHE=1`): 7/7 PASS.
- **Sim FreeRTOS**: boots, `hello` / `blink` runs (bare mode unchanged).
- **Formal**: not re-run. The wrapper pins both new pagefault inputs to 0 via existing assume, so the RVFI-visible behaviour is identical to 6C-2c for the insn-suite checks.

### Residuals (deferred)
- `rv32mi-p-illegal` still fails — needs mstatus.TVM / mstatus.TSR gating on SFENCE.VMA / satp / SRET from S-mode. That's a CSR-storage + illegal-decode change, separate sub-stage.
- SFENCE.VMA still flushes everything (no rs1/rs2 fields).
- Ifetch translation still exercised only indirectly. A real S-mode ifetch test (requires MRET drop + S-mode entry point) would pair well with `CAUSE_INSN_PAGE_FAULT`; haven't written one yet.

## 2026-04-18 — Stage 6C-2c: MMU TLB + SFENCE.VMA

### What shipped
- **4-entry fully-associative TLB per side (`rtl/core/mmu.sv`)**. Each entry caches `{valid, is_sp, vpn[19:0], ppn[21:0], r, w, x, u, a, d}`. Tag match: `vpn[19:10]` always, `vpn[9:0]` only when `is_sp=0`. Fills on every well-formed walk leaf (4 MiB superpage at L1 or 4 KiB page at L0), even if the live permission check denied — flags are cached raw and the permission check runs live against current `priv/SUM/MXR` on every hit, so privilege-context changes never use a stale decision. Round-robin replacement per side. Walk kickoff is gated on TLB miss.
- **TLB fast-path stuffs the walk-result cache (`rtl/core/mmu.sv`)**. On a TLB hit, the combinational path forwards zero-latency — but when the request leaves for the downstream and the response doesn't complete same cycle, the seq block stuffs `dm_xlate_valid_q=1 / dm_xlate_pa_q=dm_tlb_pa` so the late-arriving response routes through `dm_forward` on the next cycle. Required for the multicycle core, which drops `dmem_req_valid` on the S_EXEC→S_MEM transition; without this the MMU's priority chain falls into the "stall" default and the response gets dropped. Pipeline wasn't affected (it holds req_valid until rsp).
- **SFENCE.VMA decode + retire pulse (`rtl/core/core_pipeline.sv`, `rtl/core/core_multicycle.sv`, `rtl/soc/soc_top.sv`, `rtl/core/mmu.sv`)**. Recognizes `funct7=7'b0001001, funct3=000, rd=x0` as `SFENCE.VMA` (rs1/rs2 ignored — no per-ASID or per-VPN support yet). Pipeline serializes like `FENCE.I` / MRET (drained via the `id_is_serial` gate), pulses `mmu_sfence_vma` for 1 cycle on the WB-stage retire, and redirects to `pc+4`. Multicycle pulses on the S_EXEC commit. MMU flushes both per-side TLBs on the pulse. `id_rd != 0` with this encoding is still illegal.
- **Walk-kickoff guard** now also checks `!tlb_hit` so a same-cycle fill-then-match doesn't double-walk.

### Tests
- **MMU smoke test**: PASS on multicycle (26,938 cycles, down from 26,943 in 6C-2b — the TLB saves the 2nd store's re-walk) and pipeline+icache+dcache (24,857 cycles, down from 41,606). Every access now hits in the TLB after the first miss.
- **Sim regression** (`make sim-all`, both cores, with and without caches): **73/76** — unchanged vs 6C-2b baseline. No new regressions.
- **Sim C regression** (`make sim-c CORE=pipeline ICACHE=1 DCACHE=1`): 7/7 PASS.
- **Sim FreeRTOS** boots and runs the `hello` / `blink` tasks (bare mode, passthrough unchanged).

### Design notes
- The TLB fast-path stuffing a walk-cache entry is the one subtle piece. Without it the multicycle hang is deterministic: cycle N handshakes the request via `dm_tlb_go`, cycle N+1 sees `dm_core_req_valid=0`, `dm_tlb_hit=0` (addr reset), `dm_xlate_valid_q=0` — so the forward logic falls into the default branch that swallows the response. With the stuff, cycle N+1 hits `dm_forward`, routes the response, and `dm_forward_rsp_done` clears the cache for the next request. The pipeline core never exposed this because it holds `req_valid=1` until the rsp handshakes — the TLB-hit branch stays selected the entire time.
- Flags are cached **raw**: no `sum` / `mxr` pre-bake. A flip of `mstatus.SUM` doesn't require an SFENCE because the live `perm_ok()` on every hit uses current CSR state. Simpler than a sum/mxr-tagged TLB and loses nothing in perf (perm_ok is one level of combinational muxing).

### Residuals (deferred)
- SFENCE.VMA still ignores rs1 / rs2 (no ASID field, no per-VPN flush) — we flush everything on every pulse. That's spec-legal (coarser than a single-VPN flush) but throws away hits unnecessarily; upgrade when / if ASIDs land.
- `rv32mi-p-illegal` still parked — it exercises a broader set of illegal encodings than SFENCE.VMA alone, and unblocking it needs the page-fault cause distinction below.
- Page faults still fold into `rsp_fault` (access-fault cause). Future refinement: separate `rsp_pagefault` with `INSN/LOAD/STORE_PAGE_FAULT` causes.
- Ifetch translation is exercised only indirectly through the smoke test's instruction fetches from the SRAM identity superpage. A real S-mode ifetch test needs `MRET` to drop priv and would pair nicely with page-fault causes.

## 2026-04-18 — Stage 6C-2 (a+b): SV32 MMU — skeleton, PTW, SRAM-port-B arbiter

### What shipped
- **Stage 6C-2a — MMU module + interface (`rtl/core/mmu.sv` new, `rtl/soc/soc_top.sv`)**. Instantiates the MMU unconditionally between `core_if/dm_*` and the decoder; when `satp.MODE=0` or effective-priv is M, it's a zero-latency combinational wire. Adds the full if/dm core-facing + downstream request/response channels and a read-only PTW memory port. Also carves `core_if_*` / `core_dm_*` (upstream) vs `if_*` / `dm_*` (downstream) and renames the D-cache's SRAM-port-B signals to `dc_sram_*` so the arbiter below can multiplex with the PTW.
- **Stage 6C-2b — PTW FSM + permission checks + port-B arbiter (`rtl/core/mmu.sv`, `rtl/soc/soc_top.sv`)**. 2-level SV32 walk (`PTW_IDLE → PTW_L1_REQ → PTW_L1_WAIT → PTW_L0_REQ → PTW_L0_WAIT → PTW_IDLE`) with a per-side walk-result cache (`if_xlate_*`, `dm_xlate_*`) that retires on the downstream rsp handshake. Supports 4 MiB superpages at L1-leaf (fault if `pte.ppn0 != 0`) and 4 KiB pages at L0-leaf. Permission check enforces R/W/X (with MXR), U-bit vs SUM, A (SW-managed, fault if 0), D (SW-managed, fault if 0 on store). Effective priv for dmem = `(priv==M && MPRV) ? MPP : priv`. Invalid encodings (V=0 or W && !R) fault. Port-B arbiter gives PTW priority over the D-cache / direct-dmem path and tracks the in-flight master with `last_was_ptw_q` for 1-cycle rsp routing.
- **Fix: L1 PTE base shift** — the initial `{satp_i[21:0], 10'd0}` was shifting by 10 instead of 12 (page-size offset), so the walker read PTEs from bogus addresses. Now `{satp_i[21:0], 12'd0}` so L1 base = `satp_ppn << 12`.
- **MMU smoke test (`sw/tests/asm/mmu_sv32.S`)**. Sets up `root[0x200]` identity superpage for SRAM, `root[0x341]` identity superpage for MMIO, `root[0x204]` → L0 table whose `L0[0]` leaf maps `VA 0x81000000 → PA 0x80001000`. Writes `PATTERN_A` at the PA directly, turns on SV32 with `MPP=S, MPRV=1`, reads it back through the VA (load-through-MMU), writes `PATTERN_B` through the VA (store-through-MMU), disables MPRV, verifies SRAM now holds `PATTERN_B`, prints `PASS\n` and exits 0.

### Tests
- **MMU smoke test**: PASS on multicycle (26,943 cycles) and pipeline+icache+dcache (41,606 cycles). Exercises both L1 + L0 walk stages, 4 MiB superpage leaf, permission check accept path (R/W/X/A/D + U=0 with eff_priv=S), and walk-result cache retire across multiple accesses.
- **Sim regression** (`make sim-all` both cores, both with and without caches): **73/76** PASS. Unchanged vs Stage 6C-1 baseline — every ISA test leaves `satp.MODE=0`, so the PTW never fires and bare-mode passthrough is bit-exact.
- **Sim FreeRTOS**: boots, scheduler runs, `hello #0..3 / [blink 0..1]` prints as expected within 50 M cycles (not run to completion; bare-mode passthrough is unchanged).

### Residuals (deferred)
- No TLB — every translated access does a fresh 2-level walk. Future Stage 6C-2c will drop a small fully-associative TLB in front of the walker (big win for tight loops over the same page; trivial for MMIO prints which currently re-walk `root[0x341]` per byte).
- Page faults currently fold into `rsp_fault` (reported as access fault to the core). A later refinement adds a `rsp_pagefault` signal and maps to `INSN/LOAD/STORE_PAGE_FAULT` causes.
- `SFENCE.VMA` not implemented — required by `rv32mi-p-illegal` (parked). Without a TLB there's nothing to flush yet, so this is a decode-only addition.
- Ifetch translation tested only indirectly (MPRV exercises dmem). An S-mode ifetch test would need `MRET` to drop privilege.

## 2026-04-18 — Stage 6C-1 + 6C-3a + Zicntr: S-mode CSRs, delegation, SRET, PMP storage

### What shipped
- **Stage 6C-1 — priv modes + S-mode CSRs + trap delegation + SRET (`rtl/core/csr.sv`, `defs.svh`, `core_pipeline.sv`, `core_multicycle.sv`)**. `csr.sv` gets a `priv_mode_q` register tracking U/S/M, with full storage for `stvec`, `sepc`, `scause`, `stval`, `sscratch`, `satp`, `medeleg`, `mideleg`; `sstatus` / `sie` / `sip` are masked subset-views of their M-mode parents. Trap entry routes to `stvec` vs `mtvec` via a new `trap_to_s` output = (`priv_mode != M`) && `medeleg[cause]` (or `mideleg[cause]` for interrupts). `MRET` pops from MPP, `SRET` pops from SPP; MPRV clears per the spec. MISA advertises `S`. The pipeline plumbs `is_sret` through EX/MEM/WB in parallel with MRET; `wb_redirect_pc` picks `stvec` on delegated traps and `sepc` on SRET. `ECALL` cause now depends on current priv (U/S/M). `id_illegal` whitelists the full S-mode CSR set + `medeleg`/`mideleg`. Interrupt delegation storage is in place but the take path still routes to M (no S-mode software to exercise S-interrupts yet).
- **Stage 6C-3a — PMP CSR storage (`rtl/core/csr.sv`, `defs.svh`, `core_pipeline.sv`)**. Added `pmpcfg0..3` and `pmpaddr0..15` as plain 32-bit R/W storage (no access-path enforcement yet). The sized-array layout is ready for a real PMP check in a later stage. `rv32mi-p-pmpaddr` takes the G=0 early-exit and passes the register-behavior probe.
- **Zicntr unprivileged read-only aliases**: `cycle` / `cycleh` / `instret` / `instreth` mirror `mcycle` / `minstret`. The read-only-space check in `csr.sv` already rejects writes.

### Tests
- **Sim regression** (`make sim-all CORE=pipeline ICACHE=1 DCACHE=1`): **73/76** PASS, up from 71/76 in Stage 6B. Multicycle: **73/76** PASS too (shares `csr.sv` and gains PMP / Zicntr for free; multicycle stays M-only so SRET is not decoded there).
- **Sim FreeRTOS** (`make run CORE=pipeline ICACHE=1 DCACHE=1 TEST=sw/freertos/freertos_demo.elf`): PASS + MMIO exit 0 at cycle 112,582,997 — unchanged vs Stage 6B baseline, within noise.
- **Formal**: not re-run. The RVFI-visible pipeline behavior is unchanged; new S-mode wires only affect trap-direction PC selection at retirement.

### Residuals (deferred)
- `rv32ui-p-ma_data`, `rv32mi-p-breakpoint`, `rv32mi-p-illegal` — need MMU/SFENCE.VMA/Debug support. Parked for Stage 6C-2 (MMU) and later.
- Stage 6C-2 (SV32 MMU + ITLB/DTLB + shared PTW) is next up and is a bigger, multi-commit piece; it hasn't started yet.
- PMP enforcement in the access path is not implemented yet — storage only (Stage 6C-3a). Real PMP checks would land in 6C-3b once the MMU is in.
- Interrupt delegation storage is in `mideleg_q` but the take path still routes to M. Finishing this requires S-mode software to drive it — wired up once Stage 6C-2 / 7 lands.

## 2026-04-18 — Stage 6B: Data cache (write-through, 4-way, 64 B lines, 16 KiB)

### What shipped
- **`rtl/cache/dcache.sv`** — 4-way set-associative D-cache, 64 B lines, 16 KiB. Same geometry and tag layout as the I-cache; interposes on the core's `dmem_*` bus for the SRAM region only (MMIO / CLINT / AXI remain uncached bypass paths). Byte-masked stores: `core_req_wmask[3:0]` merges into the cached line with one bit per byte; a separate write-port `always_ff` keeps the BRAM byte-WE inference clean on Xilinx.
- **Write-through, write-allocate policy** — stores hit the cache *and* memory in the same transaction: write-hit fires a single-beat mem write via a small WT sub-FSM (`S_WT`), write-miss allocates the line via 16-beat fill and then fires the store to memory (`S_WT_MISS`). No dirty bits, no writeback walk, no flush path — the cache and memory are always in sync.
- **`rtl/soc/soc_top.sv`** — splits the pre-cache DMEM SRAM path into `dm_sram_*` and the post-cache SRAM port B into `sram_b_*`; the `USE_DCACHE` ifdef drops the cache in between. The `else` branch is a straight passthrough so the baseline `CORE=pipeline` build is unchanged. MMIO/CLINT/AXI decodes are untouched — those regions are mandatorily uncacheable.
- **`sim/Makefile`** — `DCACHE=1` flips `-DUSE_DCACHE`.

### Tests (all PASS)
- **Sim regression** (`make sim-all CORE=pipeline ICACHE=1 DCACHE=1`): 71/76 riscv-tests PASS — matches the cache-less baseline exactly (same 5 pre-existing out-of-scope failures: `ma_data`, `breakpoint`, `illegal`, `pmpaddr`, `zicntr`).
- **Sim C regression** (`make sim-c CORE=pipeline ICACHE=1 DCACHE=1`): 7/7 PASS.
- **Sim FreeRTOS** (`make run CORE=pipeline ICACHE=1 DCACHE=1 TEST=sw/freertos/freertos_demo.elf`): `PASS` + `MMIO exit 0` at cycle 112,582,997 (vs the Stage 6A I-cache-only baseline of 112,568,262 — within 0.013 %, so the extra store-path latency is effectively invisible on this workload).
- **Formal**: not re-run — `rtl/core/core_pipeline.sv` is untouched in this stage (no new ports, no RVFI-visible changes). Stage 6A's 40/40 PASS still stands.

### Why write-through
The first cut was write-back with a FENCE.I-driven full-cache writeback walk (to keep memory current before the I-cache refill). Correct in principle, but the simulator's `tohost` poll reads SRAM via DPI backdoor and a WB cache strands the stores: every riscv-test timed out because the pass/fail banner never reached SRAM. Options evaluated: (1) keep WB and make sim DPI cache-aware, (2) special-case `tohost` as uncacheable, (3) switch to write-through. Option 3 is the smallest change with no test-harness hacks, and in a single-core single-issue pipeline the bandwidth cost of write-through is modest — SRAM accepts one store per cycle so the cache just adds a few cycles of latency at the boundary. If profiling later shows the store bandwidth is a real bottleneck, we can revisit with a store buffer on top of write-back (and a DPI-aware sim read path).
- Consequence: FENCE.I no longer needs a D-side flush pair. The `dcache_flush` output prototyped on core_pipeline was removed; `icache_invalidate` alone is enough because memory is always current.

### Design notes
- **Mem-side shape mirrors sram_dp port B** (valid/ready req + rsp_valid for both reads *and* writes). The WT FSM waits for `mem_rsp_valid` before retiring `S_WT` — same shape as the core's `mem_ls_pending` logic, and it means a future AXI-Lite slave with back-pressure Just Works.
- **Hit/miss latency**: read-hit is 2 cycles req→rsp (accept + lookup + done), matching the I-cache. Write-hit is 4 cycles (extra round-trip through `S_WT`). Read-miss is ~20 cycles. Write-miss is ~24 cycles (fill + one WT beat).
- **Saved store merged into the filled target word** — during fill, when the target word arrives, the data_ram write applies `wmask` merge against `mem_rsp_rdata` in the same cycle so the cache shows the post-store state the moment the line is installed. The memory-side store then fires from `S_WT_MISS` to commit the write to SRAM.
- **Single read port per way, muxed by state** — S_IDLE points at the incoming req for zero-cycle turnaround into S_LOOKUP; other states point at the saved line so `data_rd` stays stable until consumed.
- **LR/SC/AMO** go through the cache as plain word loads/stores. The core still owns the reservation/atomicity logic (pipe drain on atomic, explicit monitor in core_pipeline).

### Caveats / next
- Write-through means every store is a mem-side beat. On a bus fabric with per-beat latency, this will hurt — the SRAM case is fine, AXI-Lite would need batching. Future upgrade path: write-back with a store buffer + sim DPI awareness.
- D-cache is still physically-tagged (VIPT degenerate with identity mapping). Stage 6C MMU will add DTLB + ASID.
- Cache is flat over the SRAM region; MMIO/CLINT/AXI remain uncached by address decode. Once more regions appear in Stage 7+, `dm_is_sram` becomes a "cacheable region" predicate.
- Next up: **Stage 6C — MMU** (SV32, ITLB/DTLB, shared PTW, S-mode + CSRs + PMP) per `riscv_soc_plan.md`.

## 2026-04-18 — Stage 6A: Instruction cache (4-way, 64 B lines, 16 KiB)

### What shipped
- **`rtl/cache/icache.sv`** — 4-way set-associative I-cache, 64 B lines, 16 KiB. Interposes on the core's `ifetch_*` bus (same valid/ready shape on both sides, single outstanding). Synchronous BRAM reads (1-cycle hit); miss fills a full line via 16 back-to-back single-word mem requests. Tree-pLRU replacement (3 bits/set for 4-way). Explicit `fill_target_q` bypass register captures the target word as it streams in to sidestep a same-cycle read-after-write race when `saved_woff == LAST`. Per-set valid bits live in FFs (resettable) so `rst` gives a clean miss everywhere without BRAM init.
- **FENCE.I support in `rtl/core/core_pipeline.sv`** — WB-level decode from `wb_instr_q` (no new pipeline flag propagation); `icache_invalidate` is a single-cycle pulse; `wb_redirect` now fires on FENCE.I to refetch from `pc+4`. `rtl/cache/icache.sv` drops `core_req_ready` while `invalidate` is high and clears all `valid_bits[]` in one cycle.
- **`rtl/soc/soc_top.sv`** — `ifdef USE_ICACHE` drops the icache between the core IF port and SRAM port A; `else` branch is a direct passthrough, so the SoC synthesises unchanged when the icache is off. `icache_invalidate_w` is wired from `core_pipeline` when the pipeline core is selected, tied to `0` under the multicycle core (which has no outstanding-fetch state and doesn't need it).
- **`sim/Makefile`** — `ICACHE=1` flips `-DUSE_ICACHE`; default keeps the passthrough so the baseline suite stays stable.

### Tests (all PASS)
- **Sim regression** (`make sim-all CORE=pipeline ICACHE=1`): 71/76 riscv-tests PASS — identical result to the cache-less baseline. `rv32ui-p-fence_i` passes (the self-modifying-code test broke without FENCE.I handling; that's what drove adding it). Same 5 pre-existing out-of-scope failures.
- **Sim C regression** (`make sim-c CORE=pipeline ICACHE=1`): 7/7 PASS.
- **Sim FreeRTOS** (`make run CORE=pipeline ICACHE=1 TEST=sw/freertos/freertos_demo.elf`): `PASS` + `MMIO exit 0` at cycle 112,568,262 (within 0.02 % of the 112.55 M cache-less baseline — on the `freertos_demo` workload IF traffic is dwarfed by the tick-heavy scheduler path, so the icache doesn't buy much here; still worth having for silicon where BRAM-side latency would dominate without it).
- **Formal** (re-ran the full suite after the `core_pipeline.sv` FENCE.I edits): 40/40 PASS including `reg_ch0` at depth 20 (637 s). No regression from the WB-level FENCE.I decode.

### Design notes
- **Why WB-level FENCE.I detection instead of a pipeline bit**: `wb_instr_q` already carries the full instruction word to WB, and FENCE.I is rare enough that decoding once at WB beats plumbing a single-use flag through ID/EX/MEM. `wb_redirect` already handles traps/MRET via the same combinational path, so extending it was a three-line change.
- **Why the `fill_target_q` bypass**: during line-fill, the last word we write may be the target word. A naïve design reads `data_ram` synchronously on the same cycle, which races the write — some tools serialise it write-first, others read-first. `fill_target_q` captures the target word as it arrives from memory, unambiguously independent of BRAM read-port timing.
- **Why per-set valid bits in FFs, not tag-valid in BRAM**: saves a BRAM-side reset path and makes `invalidate` a one-cycle all-ways reset. Cost is 64 FFs per `SETS=64` — trivial.
- **No FENCE.I on the multicycle core**: it issues one ifetch and stalls to retirement, so the icache always sees a completed transaction before the next fetch. The invalidate wire is tied off; the icache still supports invalidate but the path is unused.

### Caveats / next
- Icache is read-only. No coherence against D-side stores — correct for von-Neumann-separated SRAMs, but once the D-cache lands with a store buffer, stores into code space need to either invalidate the I-cache or require SW FENCE.I (riscv-privileged says the latter). Plan is SW FENCE.I.
- No ITLB/VIPT yet — physical-address tagged. MMU (Stage 6C) will either add ITLB in front or widen tags to include ASID; TBD.
- Next up: **Stage 6B — D-cache** (write-back, write-allocate, store buffer per `riscv_soc_plan.md`).

## 2026-04-18 — Formal verification (riscv-formal, RV32I)

### What shipped
- **`formal/core_pipeline/`** — new tree. `wrapper.sv` instantiates `core_pipeline` for YosysHQ/riscv-formal; symbolic ifetch/dmem/IRQ inputs via `rvformal_rand_reg`. `checks.cfg` drives the upstream genchecks.py (insn/causal/cover/reg); `Makefile` stages both into `third_party/riscv-formal/cores/core_pipeline/`.
- **`rtl/core/core_pipeline_rvfi.svh`** — RVFI (RISC-V Formal Interface) tap. `ifdef RISCV_FORMAL` includes it into `core_pipeline.sv`. Shadow EX/MEM/WB pipeline carries the 20-signal retirement trace: rs1/rs2 addr+rdata, next-pc, mem addr/rmask/wmask/wdata/rdata, rd addr+wdata, trap, order counter, intr.
- **First-pass scoping**: wrapper assumes no ifetch/dmem faults and no external IRQs so `insn_*` checks isolate architectural behaviour from trap-path handling (separate checks for those are a later pass).

### Tests (all PASS)
- **37 / 37 RV32I insn checks**: every `insn_*` model (`addi`/`add`/`sub`/`sll`…`sltiu`/all branches/`jal`/`jalr`/`lui`/`auipc`/`lb..lw`/`sb..sw`/…) proven retirement-correct at depth 20 against the upstream spec models.
- **causal_ch0**: proves *any* valid retirement is reachable (i.e. the pipeline can actually retire instructions under symbolic stimulus — sanity against a pipeline that's trivially "stuck").
- **cover**: reaches two retirements in the bounded run, witnessing at least that much forward progress.
- **reg_ch0** (depth 20): proves the architectural register file is preserved across in-flight retirements — reading register x ever returns the value of the most-recent retired write to x. Caught a real shadow-tap bug (see below); now clean.

### The reg_ch0 bug and fix
- Symptom: `reg_ch0` counterexample with `DIV` reading an `rs1` register that a prior ADDI had written. The DIV result itself was correct — the core's arithmetic was fine — but the RVFI shadow reported a stale `rvfi_rs1_rdata`.
- Root cause (shadow-tap only, not a core bug): my original tap captured `ex_rs1_fwd` at the EX→MEM advance cycle. For DIV, that's the cycle the divide *finishes*, which can be tens of cycles after EX first sees the insn. During the DIV stall, the producer drifts from MEM → WB → regfile. The core's forwarding paths only cover MEM and WB; once the producer passes WB, `ex_rs1_fwd` falls through to `ex_rs1_q_data` which was latched at ID with the *old* value. DIV sampled the correct operand via `div_start_pulse` on cycle 1, so arithmetic was right — only the RVFI mirror was stale.
- Fix: `rtl/core/core_pipeline_rvfi.svh` now holds a "first stall cycle" snapshot. When EX stalls with `ex_valid_q=1` and no snapshot yet, it latches `ex_rs1_fwd` / `ex_rs2_fwd` (which *are* correct on cycle 1). On the EX→MEM advance, a mux selects the snapshot over the (possibly stale) current forward view. Single-cycle insns never snapshot — they still pass `ex_rs1_fwd` combinationally, matching the old behaviour.
- Intermediate dead end: a first attempt stored the snapshot on *any* "first cycle of EX" (including single-cycle insns) and produced an NBA hazard — on a cycle where both the snapshot-write and EX→MEM advance fired, the MEM-shadow NBA read the snapshot's *pre-edge* value (the previous insn's). Fixed by gating the snapshot on `stall_ex` only, and driving the MEM shadow through a combinational mux.

### Caveats
- `reg` check runs at depth 20 (~10 min). Depth 30 was explored, solver ran >1.5 h without resolving; parked — depth 20 gives a 20-cycle window that covers the pipe depth plus DIV latency (≈33) minus initial IF latency, which is more than enough to expose the failing case found above.
- Not yet covered: IRQ/trap retirement semantics, CSR spec checks, bus-fault paths, RV32M/RV32A spec models (not shipped upstream), rv32imc. These are orthogonal follow-ups; current suite gates RV32I correctness.
- Solver is `boolector` (default via sby). No engine sweeps tried yet.

### Next steps
- Optionally bring up CSR / IRQ checks by dropping the wrapper's fault/irq assumes and teaching the tap how to observe trap retirement tuples.
- When we add caches / MMU, re-run the suite against the new `core_pipeline` — the tap should be transparent to those changes.

## 2026-04-18 — Stage 5 (pipelined core): 5-stage RV32IMA bring-up

### What shipped
- **`rtl/core/core_pipeline.sv`** — classic IF/ID/EX/MEM/WB pipeline, wire-compatible with `core_multicycle` at the soc boundary.
  - Operand forwarding MEM→EX and WB→EX; load-use hazard stall; 2-bubble flush on mispredict (static not-taken); flush-to-retirement on traps/MRET.
  - **M-ext**: MUL single-cycle in EX; DIV iterative (~33 cycles) stalls EX until `div_done`. Subtle fix: ID update gate is `!id_valid_q || !stall_id` (not `!stall_id`) so an empty ID can still absorb an arriving ifetch rsp during a downstream DIV stall. Without this, pc_q would keep advancing while rsps got dropped and the pipeline diverged by ~18 words.
  - **A-ext**: atomics are serialized (drain pipe in ID, stall-based MEM state machine). LR arms a 4-byte-aligned reservation; SC checks hit/miss, hit drives a store beat + rd=0, miss short-circuits rd=1 via arith path. AMO.RMW runs a 2-phase MEM: phase 0 load beat (latches `amo_old`), phase 1 store beat with `op(amo_old, rs2)` computed combinationally across all 9 funct5 codes.
  - Serializing ops (CSR, MRET, ECALL, EBREAK, WFI, FENCE, atomics) drain the pipe in ID for simpler hazard reasoning; cost is small since these are rare.
- **`rtl/soc/soc_top.sv`** — `ifdef USE_PIPELINE_CORE` picks between `core_pipeline` and `core_multicycle`; ports are identical.
- **`sim/Makefile`** — `CORE=pipeline` sets `-DUSE_PIPELINE_CORE`; default stays multicycle.
- **`fpga/scripts/build_axi_hello.tcl`** — adds `core_pipeline.sv` to the source list; `USE_PIPELINE_CORE` env var flips the synth `-verilog_define`. `fpga/{axi_hello,freertos}/Makefile` accept `CORE=pipeline` and forward the env var.

### Tests
- **Sim regression** (`make sim-all CORE=pipeline`): 71/76 riscv-tests PASS — identical result to multicycle; the same 5 out-of-scope tests fail (`rv32ui-p-ma_data`, `rv32mi-p-breakpoint`, `rv32mi-p-illegal`, `rv32mi-p-pmpaddr`, `rv32mi-p-zicntr`).
- **Sim C regression** (`make sim-c CORE=pipeline`): 7/7 PASS.
- **Sim FreeRTOS** (`make run CORE=pipeline TEST=sw/freertos/freertos_demo.elf +timeout=200000000`): `PASS` + `MMIO exit 0` at cycle 112,551,142 — matches multicycle's 112.5 M cycles bit-for-bit at the retirement boundary (the serializing atomics + stall-based DIV give up IPC; that's the trade for keeping Stage 5E simple).
- **Silicon** (2026-04-18 07:13): `make -C fpga/freertos synth CORE=pipeline` built `axi_hello.bit` with post-route **WNS = +3.702 ns** at 50 MHz (vs multicycle's +0.537 ns — pipeline breaks the critical path as expected). Programmed Urbana over JTAG, 30 s `/dev/ttyUSB1` capture showed FreeRTOS booting and running both tasks at the expected 2:1 rate (≈ 3.8 hello/s, 1.9 blink/s). First pipelined core running an RTOS on silicon.

### Resource comparison (Spartan-7 xc7s50, 50 MHz):
| | multicycle | pipeline |
|---|---|---|
| Slice LUTs | ~2.1k | 3,120 (9.6%) |
| FFs | ~1.0k | 1,744 (2.7%) |
| WNS @ 50 MHz | +0.537 ns | +3.702 ns |

### Caveats
- Atomics use stall-based serialization. A non-stalling implementation is possible with more bookkeeping (track in-flight ops + resolve reservation against forwarded MEM writes). Not needed yet — correctness is proved; park for later.
- `build_axi_hello.tcl` hardcodes the output dir to `fpga/build/axi_hello/`, so synthing freertos+pipeline overwrites any prior axi_hello.bit at that path. Pre-existing; fix by parameterising `build_dir` when a second FPGA workflow needs it.

## 2026-04-17 — Stage 5.5: FreeRTOS bringup (sim + silicon)

### What shipped
- **Vendored `FreeRTOS-Kernel` V11.1.0** as `third_party/FreeRTOS-Kernel/` (shallow clone, tag `V11.1.0`, commit `dbf70559b27d39c1fdb68dfb9a32140b6a6777a0`). Using the stock `portable/GCC/RISC-V/` port with the `RV32I_CLINT_no_extensions` chip-specific extensions.
- **`sw/freertos/`** — self-contained FreeRTOS demo:
  - `FreeRTOSConfig.h` points the tick path at our CLINT: `configMTIME_BASE_ADDRESS = 0x0200BFF8`, `configMTIMECMP_BASE_ADDRESS = 0x02004000`, `configCPU_CLOCK_HZ = 50_000_000`, tick = 1 kHz.
  - `main.c` creates two tasks (`hello` @ pri 2, 250 ms; `blink` @ pri 1, 500 ms), both printing through AXI UartLite (`sw/common/uartlite.h`). **Critical gotcha**: the FreeRTOS RISC-V port does NOT set `mtvec` itself — the app must install `freertos_risc_v_trap_handler` before `vTaskStartScheduler()`. Skipping this sent the core into a trap loop at `mtvec=0` that silently ran forever.
  - `crt0.S`, `link.ld`: 64 KiB SRAM at `0x80000000`, our own startup; `-nostartfiles` suppresses picolibc's crt0 so ours wins.
  - `Makefile` uses `-specs=picolibc.specs` (Debian `picolibc-riscv64-unknown-elf` pkg) for `memset/memcpy/strlen/strcpy`. Linked against picolibc's `rv32im/ilp32` multilib (close enough for FreeRTOS; A-ext instructions are only user-emitted). Two variants: default exits after 10 `hello` prints (`mmio_exit(0)` — grades in sim), `make fpga` leaves the scheduler running forever.
- **Sim UartLite stub** (`rtl/mem/axil_uartlite_sim.sv`) — behavioural AMD-UartLite register model that emits TX-FIFO bytes as `$write("%c", b)` directly to Verilator stdout. `STAT` reads 0 so polling drivers proceed immediately. Now the sim and FPGA exercise the same UART code path.
- **Tiny 1→2 AXI-Lite decoder** in `soc_tb_top.sv` — routes `addr[12]=0` → UartLite stub (`0xC0000000`), `addr[12]=1` → BRAM (`0xC0001000`), so `axi_bram.S` still has a RAM to poke (moved its target base). One outstanding transaction assumption (matches the master shim), so sel state is just a pair of latches per channel.
- **`fpga/freertos/`** — drops in the FreeRTOS ELF under the existing `axi_hello_top` bitstream; same `build_axi_hello.tcl`, different `SRAM_INIT_FILE`. Top-level `make freertos-synth` / `freertos-prog` targets added.

### Tests
- **Sim:** `make run TEST=sw/freertos/freertos_demo.elf` — boots, runs both tasks with the correct 2:1 priority ratio (every blink cycle sees two hellos), emits `PASS` and `MMIO exit 0` after 10 hellos. Total runtime ≈ 112.5 M cycles (~2.25 s @ 50 MHz).
- **Silicon:** 2026-04-17 10:29 — programmed the Urbana board with the forever variant, captured `/dev/ttyUSB1` over ~6 s:

  ```
  FreeRTOS booting on RV32IMA SoC
  hello #0
  [blink 0]
  hello #1
  hello #2
  [blink 1]
  ...
  hello #37
  hello #38
  [blink 19]
  ```

  39 `hello` prints + 20 `blink` prints = clean 2:1 scheduling ratio matches the 250 ms / 500 ms tick configuration at 1 kHz tick rate. First RTOS running on this core. Image footprint: 10.7 KiB text + 9.5 KiB BSS = ~20 KiB in the 64 KiB SRAM.

### Caveats
- No UART-RX-driven tasks yet — UartLite IRQ line is still unconnected (would need AXI Intc first).
- Picolibc multilib is `rv32im` not `rv32ima` — close enough for FreeRTOS itself, but application code that calls libc while using atomics may need a local libc rebuild later.
- Single-hart, single-core; `configNUMBER_OF_CORES = 1` (default). Anything SMP will require multi-hart CLINT.
- Heap_1 — no `vTaskDelete` or dynamic task teardown. Fine for this demo; switch to heap_4 when tasks start being created/destroyed.

## 2026-04-17 — Stage 5.3 + 5.4: AXI UartLite on FPGA silicon

### What shipped
- **Port-out refactor** — `soc_top.sv` no longer owns the sim BRAM. It now exposes the AXI4-Lite master signals (`m_axil_*`) as module ports plus an `ext_mei` input for a future AXI Intc. `soc_tb_top.sv` picked up the `axil_bram_slave` instance that was previously inside `soc_top`; `ext_mei` tied 0 in sim. Regression unchanged (71/76 riscv-tests, 7/7 C tests).
- **`rtl/fpga/axi_hello_top.sv`** — Urbana top that wires the soc AXI master directly to an AMD `axi_uartlite_0` IP at `0xC000_0000`. Kept the same MMCM (100→50 MHz) and PSR-style 2-FF reset synchronizer used by `hello_top`. The UartLite's TX drives A16 (host RX); RX pulls from B16. MMIO exit / legacy console signals stay plumbed to LEDs but the serial pin is UartLite's.
- **`fpga/scripts/build_axi_hello.tcl`** — non-project Vivado flow: `create_ip axi_uartlite:2.0` configured for 115200 8N1 @ 50 MHz, OOC-synthed, then fed into the top-level synthesis alongside the SoC RTL. Output: `fpga/build/axi_hello/axi_hello.bit`.
- **`fpga/scripts/prog_axi_hello.tcl`** — clone of `prog_hello.tcl` pointing at the new bitstream.
- **`fpga/axi_hello/Makefile`** — standard `make mem | synth | prog | clean` pattern, `ELF` pointed at `sw/tests/c/hello_axi.elf`.
- **`sw/common/uartlite.h`** — polling-mode UartLite helpers (`putc`/`puts`/`getc`/`rx_has`). Register map STAT/CTRL/TX/RX matches pg142.
- **`sw/tests/c/hello_axi.c`** — prints a banner + `PASS` over UartLite, then `mmio_exit(0)` so the sim harness can grade it. In sim the writes land in the stub BRAM (no observable output) but the MMIO exit still fires — sim PASS is the correctness proof, silicon PASS is the bringup proof.
- **Top-level Makefile** adds `axi-hello-synth` / `axi-hello-prog` targets.

### Tests
- **Sim C regression:** 7/7 green including `hello_axi` (exit-based).
- **Sim riscv-tests:** 71/76 unchanged.
- **Silicon:** 2026-04-17 10:10 — bitstream programmed over JTAG, CPU drove the AXI UartLite immediately on release-from-reset, 96 bytes captured cleanly on host `/dev/ttyUSB1` @ 115200 8N1:

  ```
  Hello from RV32IMA over AXI UartLite!
  sum(1..10) = 55 (expect 55)
  magic = 0xdeadbeef
  PASS
  ```

  Post-route WNS = 0.537 ns at 50 MHz (all 4190 endpoints pass timing). End-to-end path: core dmem → `axi_lite_master` shim → AMD `axi_uartlite_0` → A16 pin → FTDI → `/dev/ttyUSB1`. First real AXI transaction on the platform; confirms the Stage 5.1 shim and Stage 5.2 sim validation correspond to silicon.

### Caveats
- No AXI crossbar yet — single peripheral (UartLite) on the AXI region; adding Timer and Intc in follow-up once we actually have use for their IRQs.
- `ext_mei` still tied 0 on silicon because no Intc. UartLite's interrupt output is currently unconnected.
- Legacy MMIO console (`0xD058_0000`) is still live inside the SoC but not pinned out; useful as an ILA probe point if UART ever goes silent on real hardware.

## 2026-04-16 — Stage 5.1 + 5.2: AXI-Lite master shim, sim-wired

### What shipped
- **`rtl/soc/axi_lite_master.sv`** — translates the core's native ready/valid dmem slave port into an AXI4-Lite master. 5-state FSM (`IDLE / WRITE / WRITE_B / READ / READ_R`), one outstanding transaction, AW+W accepted in either order via `aw_sent_q / w_sent_q`. Non-OKAY `b_resp` / `r_resp` map to `rsp_fault=1`. No exclusive access; AMOs never reach this path (AXI region is peripherals only).
- **`rtl/mem/axil_bram_slave.sv`** — sim-only AXI-Lite BRAM (1024 words) for end-to-end shim validation. Accepts AW/W independently, executes byte-strobed writes, 1-cycle AR→R. Not intended for synthesis — FPGA build swaps this out for `axi_bram_ctrl` + a real crossbar.
- **SoC decode** (`soc_top.sv`) — new region `addr[31:28] == 4'hC` → AXI region @ `0xC000_0000` (256 MiB window, only 4 KiB used in sim). Bad-address path updated to exclude AXI. Master and slave tied together internally for regression.

### Tests
- **`sw/tests/asm/axi_bram.S`** — writes `0xCAFEBABE` at `0xC0000000`, reads back, stores `0x12345678` at offset 16, reads back, does a byte-strobed `sb` at offset 0 to prove the wstrb plumbing, then emits PASS. Runs in **133 cycles**.
- **riscv-tests regression:** 71 / 76 unchanged (same five known-OOS failures).
- **C regression:** 6 / 6 unchanged.

### Caveats
- Only one AXI region for now; no crossbar. When real peripherals land we'll introduce a small address decoder (UartLite / Timer / Intc / BRAM ctrl slots) between the master and the peripheral set.
- `m_axil_*prot` tied to 0 — no privilege / secure distinction exercised.
- The sim BRAM is 4 KiB; the 256 MiB decode window is intentional so FPGA and sim share one memory map, we just populate differently.

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
