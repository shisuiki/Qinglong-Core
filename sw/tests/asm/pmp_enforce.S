// Stage 6C-3b PMP enforcement test.
//
// Programs three PMP entries in M-mode (with L=1 so PMP applies to M too):
//   entry 0: NAPOT 16B @ 0x80003000, R=1 W=0 X=0   (read-only window)
//   entry 1: NAPOT 2GiB @ 0x00000000, R=W=X=1       (catch-all low 2 GiB)
//   entry 2: NAPOT 2GiB @ 0x80000000, R=W=X=1       (catch-all high 2 GiB)
//
// With entry 0 taking priority over entry 2 inside 0x80003000..0x8000300F,
// the expected behaviour is:
//   load  @ 0x80003000   → OK
//   store @ 0x80003000   → trap with cause=7 (store access fault)
//   load  @ 0x80003020   → OK (covered by entry 2)
//   store @ 0x80003020   → OK
//
// The trap handler for the store fault increments a witness, advances mepc
// past the offending `sw`, and mrets. A single unexpected fault (cause !=7
// at the expected PC) exits FAIL. PASS once the witness reaches 1 and both
// non-protected accesses complete.

    .section .text.init, "ax"
    .option arch, +zicsr
    .globl _start

    .equ CONSOLE_TX,      0xD0580000
    .equ CONSOLE_EXIT,    0xD0580004

    .equ CAUSE_STORE_ACC, 7

    // pmpcfg byte: [L=7][A=4:3][X=2][W=1][R=0]
    // entry 0: L=1, A=NAPOT(11), X=0, W=0, R=1 → 0b10011001 = 0x99
    // entry 1/2: L=1, A=NAPOT(11), X=1, W=1, R=1 → 0b10011111 = 0x9F
    // entry 3: OFF = 0
    .equ PMPCFG0_VAL,     0x009F9F99

    // NAPOT(16B at 0x80003000): (0x80003000 >> 2) | 0x1 = 0x20000C01
    .equ PMPADDR0_VAL,    0x20000C01
    // NAPOT(2GiB at 0x00000000): (0 >> 2) | ((1<<28)-1) = 0x0FFFFFFF
    .equ PMPADDR1_VAL,    0x0FFFFFFF
    // NAPOT(2GiB at 0x80000000): (0x80000000 >> 2) | ((1<<28)-1) = 0x2FFFFFFF
    .equ PMPADDR2_VAL,    0x2FFFFFFF

_start:
    // mtvec = m_handler (vectored mode off — direct).
    la   t0, m_handler
    csrw mtvec, t0

    // Program PMP entries before we start exercising them.
    li   t0, PMPADDR0_VAL
    csrw pmpaddr0, t0
    li   t0, PMPADDR1_VAL
    csrw pmpaddr1, t0
    li   t0, PMPADDR2_VAL
    csrw pmpaddr2, t0
    li   t0, PMPCFG0_VAL
    csrw pmpcfg0, t0

    // Witness — the handler will bump this by 1 on the expected fault.
    li   s0, 0              // fault count

    // Pre-populate 0x80003000 so a subsequent LW returns a known value.
    // Writing BEFORE locking PMP won't work — PMP is live as of the csrw
    // above. Instead, do the seed via a distinct PA we'll verify, using
    // the read-only window only for the negative test.
    // We use 0x80003020 (covered by catch-all, fully writable) as scratch.

    li   t0, 0x80003020
    li   t1, 0xAABBCCDD
    sw   t1, 0(t0)

    // Read the RO window — this access should succeed. We don't care what
    // value is there; just that the load doesn't fault.
    li   t0, 0x80003000
    lw   t1, 0(t0)          // should NOT fault

    // Negative test: store to RO window — should fault (cause 7).
    // The handler advances mepc by 4 so we fall through.
    li   t0, 0x80003000
    li   t1, 0xDEADBEEF
ro_store:
    sw   t1, 0(t0)          // expected to fault
    // After handler returns, continue.

    // Confirm we got exactly one expected fault.
    li   t1, 1
    bne  s0, t1, fail

    // Sanity: read/write the scratch should still work.
    li   t0, 0x80003020
    lw   t1, 0(t0)
    li   t2, 0xAABBCCDD
    bne  t1, t2, fail

    // All good — exit PASS.
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

// ---------------------------------------------------------------------
// M-mode trap handler.
// Accepts one CAUSE_STORE_ACC at ro_store, advances mepc, increments
// witness. Anything else → immediate FAIL.
// ---------------------------------------------------------------------
    .align 2
m_handler:
    csrr t0, mcause
    li   t1, CAUSE_STORE_ACC
    bne  t0, t1, handler_fail

    csrr t0, mepc
    la   t1, ro_store
    bne  t0, t1, handler_fail

    addi s0, s0, 1          // witness++
    addi t0, t0, 4          // step past the faulting sw
    csrw mepc, t0
    mret

handler_fail:
    la   t0, fail_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    csrr t1, mcause
    sw   t1, 0(t0)
1:  j    1b

// ---------------------------------------------------------------------
// puts: t0 = string ptr. Clobbers t3, t4.
// ---------------------------------------------------------------------
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
