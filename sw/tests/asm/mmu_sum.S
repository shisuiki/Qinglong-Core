// Stage 6C-8 SUM test.
//
// mstatus.SUM (permit Supervisor User Memory access) lets S-mode loads and
// stores touch pages with U=1. By default an S-mode access to a U=1 page
// raises a page fault; with SUM=1 the access is permitted. Fetches are
// *always* blocked when S-mode targets a U=1 page — SUM does not affect X.
//
// Strategy (complementary to mmu_mxr.S):
//   1. Leaf VA 0x81000000 -> PA 0x80001000 with PTE flags V|R|W|U|A|D.
//   2. MPP=S + MPRV=1 so M-mode loads translate as S.
//   3. SUM=0: load VA -> LOAD_PAGE_FAULT (u_ok rejects S-access to U-page).
//   4. SUM=1: reset MPP=S (mret cleared it to U), retry load -> PATTERN.

    .section .text.init, "ax"
    .option arch, +zicsr
    .globl _start

    .equ CONSOLE_TX,   0xD0580000
    .equ CONSOLE_EXIT, 0xD0580004

    .equ ROOT_PT,      0x8000E000
    .equ L0_PT,        0x8000D000
    .equ DATA_PA,      0x80001000
    .equ DATA_VA,      0x81000000
    .equ PATTERN,      0x5A5AA5A5

    .equ MSTATUS_MPRV,     0x00020000
    .equ MSTATUS_SUM,      0x00040000
    .equ MSTATUS_MPP_S,    0x00000800
    .equ MSTATUS_MPP_MASK, 0x00001800

    .equ CAUSE_LOAD_PAGE_FAULT, 13

_start:
    la   t0, trap_handler
    csrw mtvec, t0

    // Zero PTs.
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

    li   t0, DATA_PA
    li   t1, PATTERN
    sw   t1, 0(t0)

    // root[0x200] = identity superpage 0x80000000 (V|R|W|X|A|D = 0xCF)
    // root[0x341] = identity superpage for MMIO (V|R|W|A|D = 0xC7)
    // root[0x204] = non-leaf -> L0_PT
    // L0_PT[0x000] = leaf U=1: V|R|W|U|A|D = 0x01|0x02|0x04|0x10|0x40|0x80 = 0xD7
    //                PTE = (0x80001<<10) | 0xD7 = 0x200004D7
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
    li   t1, 0x200004D7
    sw   t1, 0(t0)

    li   t0, 0x8008000E
    csrw satp, t0
    sfence.vma

    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    li   t0, MSTATUS_MPP_S
    csrs mstatus, t0
    li   t0, MSTATUS_MPRV
    csrs mstatus, t0

    li   s0, 0
    li   s2, 1
    li   s1, DATA_VA

    // ----------- Load with SUM=0 — expect LOAD_PAGE_FAULT -----------
sum_off_site:
    lw   t1, 0(s1)

    li   t0, 1
    li   a7, 0x101
    bne  s0, t0, fail_code

    // ----------- Load with SUM=1 — expect PATTERN -------------------
    // Restore MPP=S (mret clobbered it to U) and set SUM.
    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    li   t0, MSTATUS_MPP_S
    csrs mstatus, t0
    li   t0, MSTATUS_SUM
    csrs mstatus, t0

    li   s0, 0
    li   s2, 0
sum_on_site:
    lw   t1, 0(s1)

    li   t2, PATTERN
    li   a7, 0x102
    bne  t1, t2, fail_code
    li   a7, 0x103
    bnez s0, fail_code

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

    .align 2
trap_handler:
    beqz s2, handler_unexpected_fail
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
