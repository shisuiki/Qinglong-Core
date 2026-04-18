// Stage 6C-5 S-mode interrupt delegation test.
//
// Verifies that a pending mip.SSIP bit, when delegated via mideleg[1], is
// taken in S-mode via stvec rather than M-mode via mtvec.
//
// Flow:
//   1. Install mtvec (M-mode sentinel: failure) and stvec (S-mode handler).
//   2. Enable SSIE in sie (also visible via mie masked by mideleg).
//   3. Delegate SSIP via mideleg[1]=1.
//   4. MRET into S-mode with SIE=1 and SSIP=1 → S handler should fire.
//      Handler clears SSIP, checks scause=0x80000001, sret.
//   5. After return, check a witness set by the handler and exit PASS.
//
// Negative sentinel: if M-mode's mtvec fires, we fail immediately (means
// interrupt wasn't delegated).

    .section .text.init, "ax"
    .option arch, +zicsr
    .globl _start

    .equ CONSOLE_TX,      0xD0580000
    .equ CONSOLE_EXIT,    0xD0580004

    .equ MSTATUS_MPP_S,   0x00000800
    .equ MSTATUS_MPP_MASK,0x00001800
    .equ MSTATUS_SIE,     0x00000002

    .equ MIP_SSI,         0x00000002
    .equ MIE_SSI,         0x00000002
    .equ MIDELEG_SSI,     0x00000002

    .equ CAUSE_SSI,       0x80000001

_start:
    // Install mtvec as a failure sentinel — we should never take an
    // M-mode trap in this test.
    la   t0, m_fail
    csrw mtvec, t0

    // Install stvec for the S-mode handler.
    la   t0, s_handler
    csrw stvec, t0

    // Delegate SSI (bit 1) to S-mode.
    li   t0, MIDELEG_SSI
    csrw mideleg, t0

    // Enable SSIE in mie. Since mie|sie share storage, writing mie works
    // and is visible to the S-mode path.
    li   t0, MIE_SSI
    csrw mie, t0

    // Pre-arm SSIP so the interrupt is pending the moment we MRET into
    // S-mode with SIE=1.
    li   t0, MIP_SSI
    csrw mip, t0

    // Set MPP=S and MPIE carrying SIE=1 is not automatic — mret copies
    // MPIE to MIE (M-mode). For S-mode's SIE we set it directly: after
    // mret we're in S-mode, so SIE governs.
    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    li   t0, MSTATUS_MPP_S | MSTATUS_SIE
    csrs mstatus, t0

    // MRET into S-mode at post_mret.
    la   t0, post_mret
    csrw mepc, t0
    mret

post_mret:
    // We should not reach here — the pending SSIP + SIE should have been
    // taken *before* executing any instruction at post_mret. Guard: if we
    // do reach here, spin until the interrupt arrives.
    // (In practice the core samples irq_pending at fetch boundaries, so
    // MRET itself already sees the pending interrupt and jumps to stvec.)
1:  j    1b

// =====================================================================
// S-mode handler — confirm cause, clear SSIP, set witness, sret.
// =====================================================================
    .align 2
s_handler:
    csrr t0, scause
    li   t1, CAUSE_SSI
    bne  t0, t1, handler_fail

    // Clear SSIP so we don't re-fire.
    li   t0, MIP_SSI
    csrc sip, t0

    // Set witness = 0xBEEFF00D at a known scratch PA.
    li   t0, 0x80003000
    li   t1, 0xBEEFF00D
    sw   t1, 0(t0)

    // SRET back — sepc was auto-set to post_mret on trap entry; we need
    // to redirect to after_irq so the main flow can verify and exit.
    la   t0, after_irq
    csrw sepc, t0
    sret

handler_fail:
    la   t0, fail_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    csrr t1, scause
    sw   t1, 0(t0)
1:  j    1b

after_irq:
    // We're in S-mode after SRET. Verify the witness. Use an identity
    // load path — satp=0 so accesses are bare.
    li   t0, 0x80003000
    lw   t1, 0(t0)
    li   t2, 0xBEEFF00D
    bne  t1, t2, fail_from_s

    // ECALL to bounce back to M-mode for the PASS sequence. S-mode ECALL
    // isn't delegated (medeleg is 0), so it traps to mtvec (m_fail) —
    // which is actually the wrong target. Switch approach: do a direct
    // ECALL-less path by writing to CONSOLE_EXIT from S-mode. S-mode has
    // MMIO access under bare translation, so this just works.
    la   t0, pass_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    li   t1, 0
    sw   t1, 0(t0)
1:  j    1b

fail_from_s:
    la   t0, fail_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    li   t1, 2
    sw   t1, 0(t0)
1:  j    1b

// =====================================================================
// mtvec sentinel — if M sees a trap, the delegation is broken.
// =====================================================================
    .align 2
m_fail:
    la   t0, fail_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    csrr t1, mcause
    sw   t1, 0(t0)
1:  j    1b

// =====================================================================
// puts: t0 = string ptr. Clobbers t3, t4.
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

    .section .rodata
pass_msg: .asciz "PASS\n"
fail_msg: .asciz "FAIL\n"
