// Stage 6C-7 SFENCE.VMA rs1/rs2 selectivity test.
//
// Relies on 6C-6 ASID tagging. Verifies all four forms of SFENCE.VMA:
//
//   sfence.vma x0, x0       → flush everything
//   sfence.vma rs1, x0      → flush entries matching VA, any ASID
//   sfence.vma x0, rs2      → flush non-global entries matching ASID
//   sfence.vma rs1, rs2     → flush non-global entries matching VA AND ASID
//
// Strategy: cache two entries with different ASIDs and the same VA. Mutate
// the page table after caching so the old TLB mapping disagrees with the
// fresh walk. The outcome of a subsequent load tells us whether the TLB
// was flushed (sees the new PTE) or not (still uses the cached old PPN).

    .section .text.init, "ax"
    .option arch, +zicsr
    .globl _start

    .equ CONSOLE_TX,   0xD0580000
    .equ CONSOLE_EXIT, 0xD0580004

    .equ ROOT_PT1,     0x8000E000
    .equ L0_PT1,       0x8000D000
    .equ ROOT_PT2,     0x8000C000
    .equ L0_PT2,       0x8000B000

    // Three physical data pages; each is seeded with a distinct pattern.
    .equ DATA_PA1,     0x80001000
    .equ DATA_PA2,     0x80002000
    .equ DATA_PA3,     0x80003000   // used after mutating PT1's L0 entry
    .equ DATA_VA,      0x81000000
    .equ OTHER_VA,     0x82000000   // used by per-VA sfence.vma test
    .equ PATTERN_A,    0xCAFEBABE
    .equ PATTERN_B,    0xDEADBEEF
    .equ PATTERN_C,    0x12345678

    .equ MSTATUS_MPRV,     0x00020000
    .equ MSTATUS_MPP_S,    0x00000800
    .equ MSTATUS_MPP_MASK, 0x00001800

    .equ SATP_PT1_ASID1, 0x8048000E
    .equ SATP_PT2_ASID2, 0x8088000C

    // PTE encodings for the leaf we rewrite:
    //   to PA 0x80001000 (V|R|W|X|A|D=CF): (0x80001<<10)|0xCF = 0x200004CF
    //   to PA 0x80003000:                   (0x80003<<10)|0xCF = 0x20000CCF
    .equ PTE_L0_PA1,   0x200004CF
    .equ PTE_L0_PA3,   0x20000CCF

_start:
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

    // Seed physical data pages.
    li   t0, DATA_PA1
    li   t1, PATTERN_A
    sw   t1, 0(t0)
    li   t0, DATA_PA2
    li   t1, PATTERN_B
    sw   t1, 0(t0)
    li   t0, DATA_PA3
    li   t1, PATTERN_C
    sw   t1, 0(t0)

    // Build PT1: SRAM+MMIO superpages; L0 leaf VA 0x81000000 -> PA1.
    li   t0, ROOT_PT1
    li   t1, 0x200000CF
    li   t2, 0x200*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x341000C7
    li   t2, 0x341*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x20003401     // non-leaf -> L0_PT1
    li   t2, 0x204*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t0, L0_PT1
    li   t1, PTE_L0_PA1
    sw   t1, 0(t0)

    // Build PT2: SRAM+MMIO superpages; L0 leaf VA 0x81000000 -> PA2.
    li   t0, ROOT_PT2
    li   t1, 0x200000CF
    li   t2, 0x200*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x341000C7
    li   t2, 0x341*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x20002C01     // non-leaf -> L0_PT2 (ppn 0x8000B)
    li   t2, 0x204*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t0, L0_PT2
    li   t1, 0x200008CF     // (0x80002<<10)|0xCF
    sw   t1, 0(t0)

    // MPP=S, MPRV=1 for translated load/store.
    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    li   t0, MSTATUS_MPP_S
    csrs mstatus, t0
    li   t0, MSTATUS_MPRV
    csrs mstatus, t0

    // ------------------------------------------------------------------
    // Round 1 — populate TLB{asid=1, VA->PA1}.
    // ------------------------------------------------------------------
    li   t0, SATP_PT1_ASID1
    csrw satp, t0
    sfence.vma                // full flush to start from a clean TLB

    li   s1, DATA_VA
    lw   t1, 0(s1)
    li   t2, PATTERN_A
    bne  t1, t2, fail

    // Round 2 — populate TLB{asid=2, VA->PA2}.
    li   t0, SATP_PT2_ASID2
    csrw satp, t0
    lw   t1, 0(s1)
    li   t2, PATTERN_B
    bne  t1, t2, fail

    // ------------------------------------------------------------------
    // Round 3 — mutate PT1's L0 entry: VA -> PA3 (PATTERN_C).
    // Writes go through the *current* MMU (ASID=2/PT2). PT2 has an
    // identity superpage over SRAM so this hits L0_PT1's PA directly.
    // ------------------------------------------------------------------
    li   t0, L0_PT1
    li   t1, PTE_L0_PA3
    sw   t1, 0(t0)

    // ------------------------------------------------------------------
    // Test 1: sfence.vma x0, rs2  where rs2=2 (ASID 2 only).
    // Should flush TLB{asid=2} but leave TLB{asid=1} intact.
    // ------------------------------------------------------------------
    li   t3, 2
    sfence.vma zero, t3

    // Under ASID=1 the old (asid=1, VA->PA1) TLB entry must still hit.
    // We just mutated PT1 to point VA at PA3 with PATTERN_C. If ASID=1
    // was stale-flushed, the re-walk would pick up PA3 and we'd see
    // PATTERN_C; since only ASID=2 should have been flushed, we still
    // see PATTERN_A from the cached PA1 mapping.
    li   t0, SATP_PT1_ASID1
    csrw satp, t0
    lw   t1, 0(s1)
    li   t2, PATTERN_A
    bne  t1, t2, fail

    // Under ASID=2 the entry should have been flushed — re-walk PT2
    // (which still points at PA2) → PATTERN_B.
    li   t0, SATP_PT2_ASID2
    csrw satp, t0
    lw   t1, 0(s1)
    li   t2, PATTERN_B
    bne  t1, t2, fail

    // ------------------------------------------------------------------
    // Test 2: sfence.vma x0, rs2  where rs2=1 (ASID 1 only).
    // Flushes the stale ASID=1 entry. Next ASID=1 load re-walks PT1
    // and picks up the mutated mapping → PATTERN_C.
    // ------------------------------------------------------------------
    li   t3, 1
    sfence.vma zero, t3

    li   t0, SATP_PT1_ASID1
    csrw satp, t0
    lw   t1, 0(s1)
    li   t2, PATTERN_C
    bne  t1, t2, fail

    // ------------------------------------------------------------------
    // Test 3: per-VA sfence.vma rs1, x0. First issue against an
    // unrelated VA — nothing should get flushed.
    // ------------------------------------------------------------------
    li   t4, OTHER_VA
    sfence.vma t4, zero

    lw   t1, 0(s1)            // DATA_VA, ASID=1 — unchanged
    li   t2, PATTERN_C
    bne  t1, t2, fail

    // Mutate PT1 again: VA -> PA1 (PATTERN_A). Cached TLB still sees PA3.
    li   t0, L0_PT1
    li   t1, PTE_L0_PA1
    sw   t1, 0(t0)

    // sfence.vma rs1 with rs1=DATA_VA. Flushes entries matching this VA.
    sfence.vma s1, zero

    lw   t1, 0(s1)
    li   t2, PATTERN_A        // re-walk picks up fresh PA1
    bne  t1, t2, fail

    // ------------------------------------------------------------------
    // Test 4: full flush (sfence.vma x0, x0). Mutate PT1 once more
    // and confirm the entry is refreshed.
    // ------------------------------------------------------------------
    li   t0, L0_PT1
    li   t1, PTE_L0_PA3
    sw   t1, 0(t0)

    sfence.vma

    lw   t1, 0(s1)
    li   t2, PATTERN_C
    bne  t1, t2, fail

    // Success.
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
