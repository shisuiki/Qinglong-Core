// Stage 6C-9 U-mode MMU integration test.
//
// Exercises the full stack: user-mode ifetch through a translated U=1
// leaf, user-mode data load through a second translated U=1 leaf, and
// ECALL_FROM_U returning to M-mode mtvec. Previous tests (mmu_ifetch,
// mmu_sv32, mmu_mxr/sum, ...) drove MMU from M-mode via MPRV or from
// S-mode via MRET, but no test has put the core at priv=U with MMU on.
//
// Layout:
//   - root[0x200]  identity 4 MiB SRAM superpage (no U bit — for PTW)
//   - root[0x341]  identity 4 MiB MMIO superpage (no U — M-mode console)
//   - root[0x208]  non-leaf -> L0_PT   (VA range 0x82000000..0x821FFFFF)
//   - L0[0]        VA 0x82000000 -> PA 0x80002000  (V|R|X|U|A|D)  user code
//   - L0[1]        VA 0x82001000 -> PA 0x80003000  (V|R|U|A|D)    user data
//
// The staged user code at PA 0x80002000 does:
//     lw   t0, 0(s1)            ; s1 = 0x82001000
//     li   t1, PATTERN
//     bne  t0, t1, <stuck>      ; loop forever on bad data
//     li   a0, 0x12345          ; witness marker
//     ecall
//
// mtvec handler: mcause==8 && a0==0x12345 → pass. Any other cause → fail
// loudly (test uses distinct a7 exit codes).

    .section .text.init, "ax"
    .option arch, +zicsr
    .globl _start

    .equ CONSOLE_TX,   0xD0580000
    .equ CONSOLE_EXIT, 0xD0580004

    .equ ROOT_PT,      0x8000E000
    .equ L0_PT,        0x8000D000
    .equ CODE_PA,      0x80002000
    .equ DATA_PA,      0x80003000
    .equ CODE_VA,      0x82000000
    .equ DATA_VA,      0x82001000
    .equ PATTERN,      0xC0DEC0DE

    .equ MSTATUS_MPP_U,    0x00000000
    .equ MSTATUS_MPP_MASK, 0x00001800

    .equ CAUSE_ECALL_U,    8

_start:
    la   t0, mtvec_handler
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

    // Seed data page with PATTERN.
    li   t0, DATA_PA
    li   t1, PATTERN
    sw   t1, 0(t0)

    // Stage user code at CODE_PA by copying from u_code_src..u_code_end.
    la   t0, u_code_src
    la   t1, u_code_end
    li   t2, CODE_PA
stage_loop:
    beq  t0, t1, stage_done
    lw   t3, 0(t0)
    sw   t3, 0(t2)
    addi t0, t0, 4
    addi t2, t2, 4
    j    stage_loop
stage_done:

    // Root PT entries.
    li   t0, ROOT_PT
    li   t1, 0x200000CF      // SRAM identity superpage (no U — for PTW)
    li   t2, 0x200*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x341000C7      // MMIO identity superpage (no U)
    li   t2, 0x341*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x20003401      // non-leaf -> L0_PT
    li   t2, 0x208*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    // L0[0] = CODE_VA -> CODE_PA, V|R|X|U|A|D = 0xDB
    //   PTE = (0x80002<<10) | 0xDB = 0x200008DB
    // L0[1] = DATA_VA -> DATA_PA, V|R|U|A|D = 0xD3
    //   PTE = (0x80003<<10) | 0xD3 = 0x20000CD3
    li   t0, L0_PT
    li   t1, 0x200008DB
    sw   t1, 0(t0)
    li   t1, 0x20000CD3
    sw   t1, 4(t0)

    // satp = (1<<31) | (ROOT_PT>>12) = 0x8008000E
    li   t0, 0x8008000E
    csrw satp, t0
    sfence.vma

    // Set MPP=U (MPRV doesn't apply — we want to actually be in U-mode).
    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    // MPP=U is 0, nothing to OR in.

    // Seed user regs: s1 = DATA_VA (loaded before MRET — user code reads it).
    li   s1, DATA_VA

    // mepc = CODE_VA, MRET into U-mode.
    li   t0, CODE_VA
    csrw mepc, t0
    mret

    // Unreachable (MRET to U-mode continues at CODE_VA).
1:  j    1b

// =====================================================================
// User code — copied into PA 0x80002000, executed from VA 0x82000000.
// Position-independent (no la / absolute relocs).
// =====================================================================
    .align 2
u_code_src:
    lw   t0, 0(s1)            // load from DATA_VA (translated)
    li   t1, PATTERN
    bne  t0, t1, user_stuck
    li   a0, 0x12345
    ecall
user_stuck:
1:  j    1b
u_code_end:

// =====================================================================
// M-mode trap handler. Called when user code ECALLs. Verifies cause=8
// and a0 witness, then exits PASS. Any anomaly → FAIL with a diagnostic
// a7 code.
// =====================================================================
    .align 2
mtvec_handler:
    csrr t0, mcause
    li   t1, CAUSE_ECALL_U
    li   a7, 0x201
    bne  t0, t1, fail_code

    li   t1, 0x12345
    li   a7, 0x202
    bne  a0, t1, fail_code

pass:
    la   t0, pass_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    li   t1, 0
    sw   t1, 0(t0)
1:  j    1b

fail_code:
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
