// Stage 6C-2e MMU ifetch-translation test — SV32 instruction fetch under S-mode.
//
// Exercises two paths that the dmem-only tests don't touch:
//   (a) Positive: ifetch through a translated, X=1 leaf in S-mode. We stage a
//       tiny function at PA 0x80002000, map VA 0x82000000 → that PA with R|X,
//       MRET into S-mode at VA, and verify the function ran (it writes a
//       witness pattern and ECALLs back). Trap cause 9 = S-mode ECALL.
//   (b) Negative: ifetch through an R-only leaf (X=0) in S-mode. We MRET into
//       another VA that maps to the same code but without X. Expect
//       INSN_PAGE_FAULT = cause 12, mepc = the VA of the faulting page.
//
// Ifetch under M-mode is always bare (satp ignored when priv==M), so we need
// a real MRET drop to S-mode to reach the PTW from the ifetch side. That
// means the trampoline has to be in a page that S-mode can fetch — we put
// it in the same SRAM superpage (root[0x200]) which is marked V|R|W|X.

    .section .text.init, "ax"
    .option arch, +zicsr
    .globl _start

    .equ CONSOLE_TX,      0xD0580000
    .equ CONSOLE_EXIT,    0xD0580004

    .equ ROOT_PT,         0x8000E000
    .equ L0_PT,           0x8000D000
    .equ CODE_PA,         0x80002000      // where the staged function lives
    .equ WITNESS_PA,      0x80003000      // S-mode writes this; we check from M

    .equ VA_X,            0x82000000      // mapped with X=1
    .equ VA_NX,           0x82001000      // same PA but X=0

    .equ MSTATUS_MPP_S,   0x00000800
    .equ MSTATUS_MPP_MASK,0x00001800

    .equ CAUSE_INSN_PF,   12
    .equ CAUSE_S_ECALL,   9

_start:
    // -- Install mtvec handler --
    la   t0, mtvec_handler
    csrw mtvec, t0

    // -- Zero page tables --
    li   t0, ROOT_PT
    li   t1, 4096
1:  sw   zero, 0(t0)
    addi t0, t0, 4
    addi t1, t1, -4
    bnez t1, 1b
    li   t0, L0_PT
    li   t1, 4096
2:  sw   zero, 0(t0)
    addi t0, t0, 4
    addi t1, t1, -4
    bnez t1, 2b

    // -- Root entries --
    li   t0, ROOT_PT
    li   t1, 0x200000CF          // SRAM identity superpage V|R|W|X|A|D
    li   t2, 0x200*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x341000C7          // MMIO identity superpage V|R|W|A|D
    li   t2, 0x341*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x20003401          // non-leaf → L0_PT
    li   t2, 0x208*4             // VA 0x82000000 / 4MiB = 0x208
    add  t2, t2, t0
    sw   t1, 0(t2)

    // -- L0 entries --
    //   L0[0]   = PA 0x80002000, V|R|X|A|D = 0x4F  → 0x80002<<10 | 0x4F = 0x2000084F
    //   L0[1]   = PA 0x80002000, V|R|A|D   = 0x47  → 0x80002<<10 | 0x47 = 0x20008847... wait: (0x80002<<10) | 0x47 = 0x2000_8000 | 0x47 = 0x20008047? Let me recompute.
    //     0x80002 << 10 = 0x20000_800 (but >32 bits).
    //     Actually: 0x80002 in 20 bits shifted left 10 = bits 11..30 set: 0x80002 * 1024 = 0x20000800. Right. Plus 0x47 = 0x20000847.
    //     With X: + 0x4F = 0x2000084F.
    //     Without X: + 0x47 = 0x20000847.
    li   t0, L0_PT
    li   t1, 0x2000084F
    sw   t1, 0(t0)               // L0[0] X=1
    li   t1, 0x20000847
    sw   t1, 4(t0)               // L0[1] X=0

    // -- Stage the function at CODE_PA --
    // The function writes 0xCAFEF00D to WITNESS_PA (relative to its own PC so
    // both VAs can reach it), then ECALLs. Both S-mode VAs map to the same
    // CODE_PA so the code is identical for (a) and (b). Only difference is
    // whether the PTE permits execute.
    la   t0, code_src
    la   t1, code_end
    li   t2, CODE_PA
copy_loop:
    lw   t3, 0(t0)
    sw   t3, 0(t2)
    addi t0, t0, 4
    addi t2, t2, 4
    blt  t0, t1, copy_loop

    // -- satp = MODE=1 | PPN(ROOT_PT>>12) = 0x8008000E
    li   t0, 0x8008000E
    csrw satp, t0

    // -- MPP = S, keep MPRV = 0 (we're testing ifetch translation, not dmem)
    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    li   t0, MSTATUS_MPP_S
    csrs mstatus, t0

    // =================================================================
    // Case (a): MRET into S-mode at VA_X. Execute staged function.
    // =================================================================
    // Stash expected cause (s0) and post-handler landing pc (s1), then
    // MRET into VA_X. The handler routes back to s1 after checking cause.
    li   s0, CAUSE_S_ECALL       // expected cause for (a)
    la   s1, after_case_a
    li   t0, VA_X
    csrw mepc, t0
    mret

after_case_a:
    // Verify the witness was written.
    li   t0, WITNESS_PA
    lw   t1, 0(t0)
    li   t2, 0xCAFEF00D
    bne  t1, t2, fail

    // Clear witness for case (b) to detect we didn't inadvertently re-enter.
    sw   zero, 0(t0)

    // =================================================================
    // Case (b): MRET into S-mode at VA_NX. Expect INSN_PAGE_FAULT.
    // =================================================================
    // Re-establish MPP=S (handler's mret cleared MPP to U).
    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    li   t0, MSTATUS_MPP_S
    csrs mstatus, t0

    li   s0, CAUSE_INSN_PF       // expected cause for (b)
    la   s1, after_case_b
    li   t0, VA_NX
    csrw mepc, t0
    mret

after_case_b:
    // Witness must still be zero — S-mode never got to execute.
    li   t0, WITNESS_PA
    lw   t1, 0(t0)
    bnez t1, fail

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

// =====================================================================
// mtvec handler — compare mcause to expected (s0), route to landing pc (s1).
// For case (b) the cause is INSN_PAGE_FAULT at the ifetch side; mepc will
// hold the faulting VA.
// =====================================================================
    .align 2
mtvec_handler:
    csrr t2, mcause
    bne  t2, s0, handler_fail
    // For case (b), also sanity-check mepc matches the VA we dispatched to.
    li   t3, CAUSE_INSN_PF
    bne  t2, t3, route
    csrr t4, mepc
    li   t5, VA_NX
    bne  t4, t5, handler_fail
route:
    // Force MPP=M so MRET drops us back to M-mode at the trampoline (s1).
    // Trap entry set MPP=S since we were in S-mode; without this, MRET
    // would return to S-mode and the next case's mret would trap as
    // ILLEGAL_INSTRUCTION.
    li   t6, MSTATUS_MPP_MASK
    csrs mstatus, t6
    csrw mepc, s1
    mret
handler_fail:
    la   t0, fail_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    csrr t1, mcause
    sw   t1, 0(t0)
1:  j    1b

// =====================================================================
// puts: t0 = string ptr (null-terminated). Clobbers t3, t4.
// =====================================================================
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

// =====================================================================
// Function staged at CODE_PA. Uses absolute PA writes, then ECALL back.
// Assembles once here; _start copies it to CODE_PA. Keep PIC — we only
// use immediates and absolute addresses so the copy doesn't need relocs.
// =====================================================================
    .align 2
code_src:
    li   t0, 0x80003000          // WITNESS_PA
    li   t1, 0xCAFEF00D
    sw   t1, 0(t0)
    ecall
1:  j    1b
code_end:

    .section .rodata
pass_msg: .asciz "PASS\n"
fail_msg: .asciz "FAIL\n"
