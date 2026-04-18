// Stage 6C-6 ASID isolation test.
//
// Proves that the TLB tags entries with the ASID captured from satp at fill
// time, and that a subsequent translation under a different ASID does NOT
// stale-hit a prior ASID's cached entry. Without ASID tagging, switching
// satp (without SFENCE.VMA) would resurrect the previous mapping and the
// second load would return the wrong physical word.
//
// Layout:
//   - Two root page tables PT1/PT2, each with its own L0 table
//   - Both map VA 0x81000000 but to DIFFERENT physical pages:
//       PT1: 0x81000000 -> 0x80001000 (PATTERN_A)
//       PT2: 0x81000000 -> 0x80002000 (PATTERN_B)
//   - Both include identity superpages for SRAM + MMIO so the test continues
//     to work under MPRV regardless of which PT is active.
//
// Sequence (all under MPRV=1 MPP=S, *no* SFENCE.VMA between switches):
//   1. satp = PT1 | ASID=1 -> load DATA_VA == PATTERN_A  (walks PT1, fills TLB{asid=1})
//   2. satp = PT2 | ASID=2 -> load DATA_VA == PATTERN_B  (must miss; TLB{asid=1} != 2)
//   3. satp = PT1 | ASID=1 -> load DATA_VA == PATTERN_A  (TLB{asid=1} still hits)
//   4. satp = PT2 | ASID=2 -> load DATA_VA == PATTERN_B  (TLB{asid=2} still hits)

    .section .text.init, "ax"
    .option arch, +zicsr
    .globl _start

    .equ CONSOLE_TX,   0xD0580000
    .equ CONSOLE_EXIT, 0xD0580004

    .equ ROOT_PT1,     0x8000E000
    .equ L0_PT1,       0x8000D000
    .equ ROOT_PT2,     0x8000C000
    .equ L0_PT2,       0x8000B000
    .equ DATA_PA1,     0x80001000
    .equ DATA_PA2,     0x80002000
    .equ DATA_VA,      0x81000000
    .equ PATTERN_A,    0xCAFEBABE
    .equ PATTERN_B,    0xDEADBEEF

    .equ MSTATUS_MPRV,     0x00020000
    .equ MSTATUS_MPP_S,    0x00000800
    .equ MSTATUS_MPP_MASK, 0x00001800

    // satp = MODE=1 | ASID<<22 | PPN
    //   ROOT_PT1 ppn = 0x8000E ; ROOT_PT2 ppn = 0x8000C
    //   ASID field occupies bits 30:22.
    .equ SATP_PT1_ASID1, 0x8048000E   // 1<<31 | 1<<22 | 0x8000E
    .equ SATP_PT2_ASID2, 0x8088000C   // 1<<31 | 2<<22 | 0x8000C

_start:
    // ------------------------------------------------------------------
    // 1. Zero all four page-table pages.
    // ------------------------------------------------------------------
    la   a0, pt_zero_list
pt_zero_outer:
    lw   a1, 0(a0)
    beqz a1, pt_zero_done
    li   a2, 4096
1:  sw   zero, 0(a1)
    addi a1, a1, 4
    addi a2, a2, -4
    bnez a2, 1b
    addi a0, a0, 4
    j    pt_zero_outer
pt_zero_done:

    // ------------------------------------------------------------------
    // 2. Seed the two physical data pages.
    // ------------------------------------------------------------------
    li   t0, DATA_PA1
    li   t1, PATTERN_A
    sw   t1, 0(t0)

    li   t0, DATA_PA2
    li   t1, PATTERN_B
    sw   t1, 0(t0)

    // ------------------------------------------------------------------
    // 3. Build PT1.
    //   root[0x200] = superpage identity 0x80000000..0x803FFFFF (V|R|W|X|A|D)
    //     PTE = (0x200<<20) | 0xCF = 0x200000CF
    //   root[0x341] = superpage identity 0xD0400000..0xD07FFFFF (V|R|W|A|D)
    //     PTE = (0x341<<20) | 0xC7 = 0x341000C7
    //   root[0x204] = non-leaf -> L0_PT1
    //     PTE = (L0_PT1>>12)<<10 | 0x01 = (0x8000D<<10) | 0x01 = 0x20003401
    //   L0_PT1[0x000] = leaf, VA 0x81000000 -> PA 0x80001000 (V|R|W|X|A|D)
    //     PTE = (0x80001<<10) | 0xCF = 0x200004CF
    // ------------------------------------------------------------------
    li   t0, ROOT_PT1
    li   t1, 0x200000CF
    li   t2, 0x200*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x341000C7
    li   t2, 0x341*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x20003401
    li   t2, 0x204*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t0, L0_PT1
    li   t1, 0x200004CF
    sw   t1, 0(t0)

    // ------------------------------------------------------------------
    // 4. Build PT2 (same shape, but L0_PT2[0]=PA2 via ppn=0x80002).
    //   root[0x204] -> L0_PT2 (0x8000B): PTE = (0x8000B<<10)|1 = 0x20002C01
    //   L0_PT2[0x000] -> PA 0x80002000: PTE = (0x80002<<10)|0xCF = 0x200008CF
    // ------------------------------------------------------------------
    li   t0, ROOT_PT2
    li   t1, 0x200000CF
    li   t2, 0x200*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x341000C7
    li   t2, 0x341*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x20002C01
    li   t2, 0x204*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t0, L0_PT2
    li   t1, 0x200008CF
    sw   t1, 0(t0)

    // ------------------------------------------------------------------
    // 5. Switch ifetch off MMU path: keep M-mode so ifetch is bare. Set
    //    MPP=S and MPRV=1 so loads/stores translate via current satp.
    // ------------------------------------------------------------------
    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    li   t0, MSTATUS_MPP_S
    csrs mstatus, t0
    li   t0, MSTATUS_MPRV
    csrs mstatus, t0

    // ------------------------------------------------------------------
    // 6. Round 1 — ASID=1 with PT1. Expect PATTERN_A.
    //    Cold TLB, walks PT1, fills entry{asid=1}.
    // ------------------------------------------------------------------
    li   t0, SATP_PT1_ASID1
    csrw satp, t0
    sfence.vma          // one fence at start is fine; we only care about
                        // cross-ASID behaviour with no fence between.

    li   s1, DATA_VA
    lw   t1, 0(s1)
    li   t2, PATTERN_A
    bne  t1, t2, fail

    // ------------------------------------------------------------------
    // 7. Round 2 — switch to ASID=2 with PT2, NO SFENCE.
    //    If ASID tagging is broken, the TLB{asid=1,VA,PA=PA1} entry
    //    would hit under asid=2 and we'd see PATTERN_A here. With ASID
    //    tagging the entry misses, we walk PT2, and see PATTERN_B.
    // ------------------------------------------------------------------
    li   t0, SATP_PT2_ASID2
    csrw satp, t0

    lw   t1, 0(s1)
    li   t2, PATTERN_B
    bne  t1, t2, fail

    // ------------------------------------------------------------------
    // 8. Round 3 — back to ASID=1 with PT1, NO SFENCE.
    //    The asid=1 entry should still be valid (4-entry TLB, only two
    //    fills so far). Expect PATTERN_A again.
    // ------------------------------------------------------------------
    li   t0, SATP_PT1_ASID1
    csrw satp, t0

    lw   t1, 0(s1)
    li   t2, PATTERN_A
    bne  t1, t2, fail

    // ------------------------------------------------------------------
    // 9. Round 4 — back to ASID=2 with PT2, NO SFENCE.
    //    asid=2 entry should still hit. Expect PATTERN_B.
    // ------------------------------------------------------------------
    li   t0, SATP_PT2_ASID2
    csrw satp, t0

    lw   t1, 0(s1)
    li   t2, PATTERN_B
    bne  t1, t2, fail

    // ------------------------------------------------------------------
    // 10. Drop MPRV so the next MMIO access goes bare, and PASS.
    // ------------------------------------------------------------------
    li   t0, MSTATUS_MPRV
    csrc mstatus, t0

pass:
    la   t0, pass_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    li   t1, 0
    sw   t1, 0(t0)
1:  j    1b

fail:
    la   t0, fail_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    li   t1, 1
    sw   t1, 0(t0)
1:  j    1b

puts:
    li   t3, CONSOLE_TX
puts_loop:
    lb   t4, 0(t0)
    beqz t4, puts_done
    sb   t4, 0(t3)
    addi t0, t0, 1
    j    puts_loop
puts_done:
    ret

    .section .rodata
    .align 2
pt_zero_list:
    .word ROOT_PT1, L0_PT1, ROOT_PT2, L0_PT2, 0
pass_msg: .asciz "PASS\n"
fail_msg: .asciz "FAIL\n"
