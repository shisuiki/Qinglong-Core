// Stage 6C-8 MXR test.
//
// mstatus.MXR (Make eXecutable Readable) affects the MMU permission check
// for loads: with MXR=0 a page needs R=1 to be loadable; with MXR=1 pages
// with X=1 become loadable even when R=0. Stores and fetches are NOT
// affected by MXR.
//
// Strategy:
//   1. Build a page table where VA 0x81000000 -> PA 0x80001000 with
//      PTE flags V|X|A|D (R=0, X=1).
//   2. Enable MMU with MPP=S + MPRV so loads in M-mode translate as S.
//   3. With MXR=0: load VA -> expect LOAD_PAGE_FAULT (cause 13). The
//      M-mode trap handler sets a witness, skips the faulting insn and
//      returns.
//   4. Set mstatus.MXR. Load VA again -> expect PATTERN.
//
// Tests that live-state is consulted on TLB hit: the first load fills the
// TLB entry even though perm_ok failed (fault stays out of fill), and the
// second load hits the same entry with the new MXR setting and passes.

    .section .text.init, "ax"
    .option arch, +zicsr
    .globl _start

    .equ CONSOLE_TX,   0xD0580000
    .equ CONSOLE_EXIT, 0xD0580004

    .equ ROOT_PT,      0x8000E000
    .equ L0_PT,        0x8000D000
    .equ DATA_PA,      0x80001000
    .equ DATA_VA,      0x81000000
    .equ PATTERN,      0xA5A55A5A

    .equ MSTATUS_MPRV,     0x00020000
    .equ MSTATUS_MXR,      0x00080000
    .equ MSTATUS_MPP_S,    0x00000800
    .equ MSTATUS_MPP_MASK, 0x00001800

    .equ CAUSE_LOAD_PAGE_FAULT, 13

_start:
    // mtvec = trap_handler
    la   t0, trap_handler
    csrw mtvec, t0

    // Zero page tables.
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

    // Seed pattern at PA.
    li   t0, DATA_PA
    li   t1, PATTERN
    sw   t1, 0(t0)

    // root[0x200] = identity superpage 0x80000000..0x803FFFFF (V|R|W|X|A|D)
    // root[0x341] = identity superpage for MMIO (V|R|W|A|D)
    // root[0x204] = non-leaf -> L0_PT
    // L0_PT[0x000] = leaf R=0 X=1: flags = V|X|A|D = 0x01|0x08|0x40|0x80 = 0xC9
    //                PTE = (0x80001<<10) | 0xC9 = 0x200004C9
    li   t0, ROOT_PT
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

    li   t0, L0_PT
    li   t1, 0x200004C9
    sw   t1, 0(t0)

    // satp = (1<<31) | (ROOT_PT >> 12) = 0x8008000E
    li   t0, 0x8008000E
    csrw satp, t0
    sfence.vma

    // MPP=S, MPRV=1. MXR stays 0 for the first load.
    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    li   t0, MSTATUS_MPP_S
    csrs mstatus, t0
    li   t0, MSTATUS_MPRV
    csrs mstatus, t0

    // s0 = trap witness (cleared before each expected-fault site).
    // s2 = "we expect a trap here" flag — handler cross-checks to avoid
    //      accidentally skipping over non-fault code.
    li   s0, 0
    li   s2, 1
    li   s1, DATA_VA

    // ------------- Load under MXR=0 — expect LOAD_PAGE_FAULT -------------
mxr_off_site:
    lw   t1, 0(s1)

    // Handler should have set s0=1 with scause=13.
    li   t0, 1
    li   a7, 0x101
    bne  s0, t0, fail_code

    // ------------- Load under MXR=1 — expect success ---------------------
    // mret from the handler cleared MPP back to U (least-privileged). Put
    // it back to S so the next load translates as S-mode again.
    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    li   t0, MSTATUS_MPP_S
    csrs mstatus, t0
    li   t0, MSTATUS_MXR
    csrs mstatus, t0
    li   s0, 0
    li   s2, 0               // NO trap expected here — if one fires, handler fails.
mxr_on_site:
    lw   t1, 0(s1)

    li   t2, PATTERN
    li   a7, 0x102
    bne  t1, t2, fail_code
    li   a7, 0x103
    bnez s0, fail_code            // assert no trap happened

    // Drop MPRV for clean exit.
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
    li   a7, 0x1FF
fail_code:
    la   t0, fail_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    mv   t1, a7
    sw   t1, 0(t0)
1:  j    1b

// =====================================================================
// M-mode trap handler: on LOAD_PAGE_FAULT, set s0=1 and advance mepc+=4
// to skip the faulting insn. Any other cause → fail loudly. If s2==0 we
// weren't expecting a trap at all → also fail.
// =====================================================================
    .align 2
trap_handler:
    beqz s2, handler_unexpected_fail  // trap when none expected

    csrr t0, mcause
    li   t1, CAUSE_LOAD_PAGE_FAULT
    bne  t0, t1, handler_cause_fail

    li   s0, 1
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret

handler_unexpected_fail:
    li   a7, 0x201
    j    hfail_print
handler_cause_fail:
    li   a7, 0x202
hfail_print:
    la   t0, fail_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    mv   t1, a7
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
pass_msg: .asciz "PASS\n"
fail_msg: .asciz "FAIL\n"
