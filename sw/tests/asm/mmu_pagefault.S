// Stage 6C-2d MMU page-fault cause test.
//
// Verifies that walk / permission failures come back as PAGE_FAULT causes
// (12/13/15), not ACCESS_FAULT (1/5/7). Runs three cases sequentially:
//
//   (a) STORE to a read-only leaf (V|R|X|A set, W=0) — expect STORE_PAGE_FAULT=15
//   (b) LOAD  from an invalid leaf (V=0)              — expect LOAD_PAGE_FAULT=13
//   (c) LOAD  from a U=1 leaf under S-mode, SUM=0     — expect LOAD_PAGE_FAULT=13
//
// Layout uses 4 MiB superpages for simplicity:
//   root[0x200] = identity SRAM superpage (V|R|W|X|A|D) — code path reachable
//   root[0x341] = identity MMIO superpage
//   root[0x204] = non-leaf → L0_PT (covers VA 0x81000000..)
//   L0_PT[0]    = RO leaf  → PA 0x80001000 (case a)
//   L0_PT[1]    = invalid  (case b)
//   L0_PT[2]    = U=1 leaf → PA 0x80002000 (case c, SUM=0)
//
// All three cases store the cause to a scratch word (mem[expected_cause_ptr])
// before triggering the fault, then the handler compares mcause to the
// expected value, advances mepc by 4, and returns. Three successful returns
// land us at `pass`.

    .section .text.init, "ax"
    .option arch, +zicsr
    .globl _start

    .equ CONSOLE_TX,      0xD0580000
    .equ CONSOLE_EXIT,    0xD0580004

    .equ ROOT_PT,         0x8000E000
    .equ L0_PT,           0x8000D000
    .equ DATA_PA,         0x80001000
    .equ CAUSE_SLOT,      0x80002000   // scratch; case (c) also covers this PA

    .equ VA_RO,           0x81000000   // case (a)
    .equ VA_INVALID,      0x81001000   // case (b)
    .equ VA_USER,         0x81002000   // case (c)

    .equ MSTATUS_MPRV,    0x00020000
    .equ MSTATUS_MPP_S,   0x00000800
    .equ MSTATUS_MPP_MASK,0x00001800
    .equ MSTATUS_SUM,     0x00040000

    .equ CAUSE_STORE_PF,  15
    .equ CAUSE_LOAD_PF,   13

_start:
    // -- Install mtvec handler --
    la   t0, mtvec_handler
    csrw mtvec, t0

    // -- Zero both 4 KiB page-table blocks --
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

    // -- Populate root-level PTEs --
    li   t0, ROOT_PT
    li   t1, 0x200000CF          // SRAM identity superpage (V|R|W|X|A|D)
    li   t2, 0x200*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x341000C7          // MMIO identity superpage (V|R|W|A|D, no X)
    li   t2, 0x341*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x20003401          // non-leaf → L0_PT (0x8000D<<10 | 0x01)
    li   t2, 0x204*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    // -- Populate L0 leaves --
    //   L0[0] = RO (V|R|X|A) no W    → 0x80001<<10 | 0x4B = 0x2000044B
    //   L0[1] = invalid  (V=0 so all flags can be 0 — use zero)
    //   L0[2] = U=1 (V|R|W|X|U|A|D) → 0x80002<<10 | 0xDF = 0x200008DF
    li   t0, L0_PT
    li   t1, 0x2000044B
    sw   t1, 0(t0)
    sw   zero, 4(t0)             // L0[1] invalid
    li   t1, 0x200008DF
    sw   t1, 8(t0)

    // -- Turn on SV32 --
    li   t0, 0x8008000E          // MODE=1 | (ROOT_PT>>12 = 0x8000E)
    csrw satp, t0

    // -- Set MPP=S, MPRV=1, SUM=0 --
    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    li   t0, MSTATUS_MPP_S
    csrs mstatus, t0
    li   t0, MSTATUS_MPRV
    csrs mstatus, t0
    li   t0, MSTATUS_SUM
    csrc mstatus, t0

    // =================================================================
    // Case (a): store to RO leaf — expect STORE_PAGE_FAULT.
    // =================================================================
    li   s0, CAUSE_STORE_PF
    la   s1, expected_cause
    sw   s0, 0(s1)                // record expectation first (through identity superpage)

    li   t0, VA_RO
    li   t1, 0x11111111
    sw   t1, 0(t0)                // <-- faults
    // If we fall through without fault, that's a test bug.
    j    fail

case_b:
    // =================================================================
    // Case (b): load from invalid leaf — expect LOAD_PAGE_FAULT.
    // =================================================================
    li   s0, CAUSE_LOAD_PF
    la   s1, expected_cause
    sw   s0, 0(s1)

    li   t0, VA_INVALID
    lw   t1, 0(t0)                // <-- faults
    j    fail

case_c:
    // =================================================================
    // Case (c): load from U=1 leaf under S-mode, SUM=0 — LOAD_PAGE_FAULT.
    // =================================================================
    li   s0, CAUSE_LOAD_PF
    la   s1, expected_cause
    sw   s0, 0(s1)

    li   t0, VA_USER
    lw   t1, 0(t0)                // <-- faults
    j    fail

all_pass:
    // -- Disable MPRV before using MMIO (MMIO super is RWA but clean is simpler) --
    li   t0, MSTATUS_MPRV
    csrc mstatus, t0

    la   t0, pass_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    li   t1, 0
    sw   t1, 0(t0)
1:  j    1b

fail:
    li   t0, MSTATUS_MPRV
    csrc mstatus, t0
    la   t0, fail_msg
    jal  ra, puts
    li   t0, CONSOLE_EXIT
    li   t1, 1
    sw   t1, 0(t0)
1:  j    1b

// =====================================================================
// Trap handler: compare mcause to expected, bump mepc, return.
// After 3 successful returns a global counter lands us at `all_pass`.
// =====================================================================
    .align 2
mtvec_handler:
    csrr t2, mcause
    la   t3, expected_cause
    lw   t4, 0(t3)
    bne  t2, t4, trap_mismatch

    // Advance mepc past the faulting insn (all faulting insns are 4 bytes).
    csrr t5, mepc
    addi t5, t5, 4
    csrw mepc, t5

    // Increment pass counter, then route next mepc-return to next case.
    la   t3, case_count
    lw   t2, 0(t3)
    addi t2, t2, 1
    sw   t2, 0(t3)

    // case_count == 1 → re-enter at case_b
    // case_count == 2 → re-enter at case_c
    // case_count == 3 → re-enter at all_pass
    li   t4, 1
    beq  t2, t4, to_b
    li   t4, 2
    beq  t2, t4, to_c
    li   t4, 3
    beq  t2, t4, to_pass
    j    trap_mismatch

to_b:
    la   t5, case_b
    csrw mepc, t5
    mret
to_c:
    la   t5, case_c
    csrw mepc, t5
    mret
to_pass:
    la   t5, all_pass
    csrw mepc, t5
    mret

trap_mismatch:
    // Unexpected cause — drop MPRV and print FAIL with cause hex.
    li   t0, MSTATUS_MPRV
    csrc mstatus, t0
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

    .section .data
    .align 2
expected_cause: .word 0
case_count:     .word 0

    .section .rodata
pass_msg: .asciz "PASS\n"
fail_msg: .asciz "FAIL\n"
