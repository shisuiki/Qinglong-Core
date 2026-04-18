// Stage 6C-5 (extra) exception-delegation test.
//
// Complements s_irq.S (which covered *interrupt* delegation via mideleg).
// Here we verify `medeleg[ECALL_FROM_U]=1` routes a U-mode ECALL to
// S-mode's stvec rather than M-mode's mtvec. mtvec is wired to a failure
// sentinel; hitting it = test failure. The S handler confirms scause=8
// and sepc, writes a witness to MMIO-exit, and we're done.

    .section .text.init, "ax"
    .option arch, +zicsr
    .globl _start

    .equ CONSOLE_TX,       0xD0580000
    .equ CONSOLE_EXIT,     0xD0580004

    .equ MSTATUS_MPP_MASK, 0x00001800
    .equ MSTATUS_MPP_U,    0x00000000

    .equ MEDELEG_ECALL_U,  0x00000100    // bit 8

    .equ CAUSE_ECALL_U,    8

_start:
    // mtvec = m_fail sentinel. If anything traps to M, we fail loudly.
    la   t0, m_fail
    csrw mtvec, t0

    // stvec = s_handler — this is where the delegated ECALL should land.
    la   t0, s_handler
    csrw stvec, t0

    // medeleg[ECALL_FROM_U]=1. After this, a U-mode ECALL (cause 8) is
    // taken in S-mode, not M-mode.
    li   t0, MEDELEG_ECALL_U
    csrw medeleg, t0

    // Set MPP=U and MRET into U-mode. We leave MIE/MPIE alone — the trap
    // here is synchronous (ECALL), not interrupt-driven.
    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    li   t0, MSTATUS_MPP_U
    csrs mstatus, t0

    la   t0, u_code
    csrw mepc, t0
    mret

// =====================================================================
// U-mode code — raise an ECALL.
// =====================================================================
    .align 2
u_code:
    ecall          // → cause 8, delegated via medeleg → stvec
    // If we come back from S via SRET (we don't in this test), spin.
1:  j    1b

// =====================================================================
// S-mode handler — verify scause=8 and exit PASS via CONSOLE_EXIT.
// =====================================================================
    .align 2
s_handler:
    csrr t0, scause
    li   t1, CAUSE_ECALL_U
    bne  t0, t1, handler_fail

    // sepc should point at the ecall (we don't advance it — we exit).
    csrr t0, sepc
    la   t1, u_code
    bne  t0, t1, handler_fail

    la   t0, pass_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    li   t1, 0
    sw   t1, 0(t0)
1:  j    1b

handler_fail:
    la   t0, fail_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    csrr t1, scause
    sw   t1, 0(t0)
1:  j    1b

// =====================================================================
// mtvec sentinel — if M sees this, the delegation is broken.
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
