// Stage 6C-2 MMU smoke test — SV32 translation via MPRV.
//
// Boots in M-mode, sets up a root + one L0 page table in SRAM, writes a known
// pattern at PA 0x80001000, enables MMU (satp.MODE=Sv32) with MPRV=1 MPP=S,
// reads the pattern through VA 0x81000000 (which maps to PA 0x80001000 via a
// 2-level walk), then writes a second pattern through the same VA and verifies
// the resulting SRAM contents. On success prints "PASS\n" and exits 0.
//
// The test exercises:
//   - PTW L1 walk, non-leaf → L0 walk, leaf
//   - Permission check accept path (R,W,X,A,D set; eff_priv=S; U=0 on an
//     S-mode access — OK because U=0 & !is_fetch)
//   - Load and store translation (both through the same cached walk result,
//     then a fresh walk on the retired handshake)
//   - Bare-mode identity superpage for MMIO (so prints work while MPRV is on,
//     though we disable MPRV before printing just to be tidy)

    .section .text.init, "ax"
    .option arch, +zicsr
    .globl _start

    .equ CONSOLE_TX,   0xD0580000
    .equ CONSOLE_EXIT, 0xD0580004

    .equ ROOT_PT,      0x8000E000
    .equ L0_PT,        0x8000D000
    .equ DATA_PA,      0x80001000
    .equ DATA_VA,      0x81000000
    .equ PATTERN_A,    0xCAFEBABE
    .equ PATTERN_B,    0xDEADBEEF

    // mstatus.MPRV bit, MPP field (bits 12:11).
    .equ MSTATUS_MPRV,   0x00020000
    .equ MSTATUS_MPP_S,  0x00000800
    .equ MSTATUS_MPP_MASK, 0x00001800

_start:
    li   s0, CONSOLE_TX
    // ------------------------------------------------------------------
    // 1. Zero page tables (both 4 KiB blocks).
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // 2. Write PATTERN_A at PA 0x80001000 (direct, MMU off).
    // ------------------------------------------------------------------
    li   t0, DATA_PA
    li   t1, PATTERN_A
    sw   t1, 0(t0)

    // ------------------------------------------------------------------
    // 3. Populate page tables.
    //
    //   root[0x200] = 4 MiB superpage, identity map for VA 0x80000000..0x803FFFFF
    //     ppn1=0x200, ppn0=0, flags V|R|W|X|A|D = 0xCF
    //     PTE = (0x200<<20) | 0xCF = 0x200000CF
    //
    //   root[0x204] = non-leaf, pointer to L0_PT @ 0x8000D000
    //     ppn = 0x8000D, flags V only (non-leaf has R=W=X=0)
    //     PTE = (0x8000D<<10) | 0x01 = 0x20003401
    //
    //   root[0x341] = 4 MiB superpage, identity map for VA 0xD0400000..0xD07FFFFF
    //     ppn1=0x341 (covers MMIO @ 0xD0580000), flags V|R|W|A|D = 0xC7 (no X)
    //     PTE = (0x341<<20) | 0xC7 = 0x341000C7
    //
    //   L0_PT[0x000] = 4 KiB leaf, VA 0x81000000 → PA 0x80001000
    //     ppn = 0x80001, flags V|R|W|X|A|D = 0xCF
    //     PTE = (0x80001<<10) | 0xCF = 0x200004CF
    // ------------------------------------------------------------------
    li   t0, ROOT_PT

    li   t1, 0x200000CF
    li   t2, 0x200*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x20003401
    li   t2, 0x204*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t1, 0x341000C7
    li   t2, 0x341*4
    add  t2, t2, t0
    sw   t1, 0(t2)

    li   t0, L0_PT
    li   t1, 0x200004CF
    sw   t1, 0(t0)

    // ------------------------------------------------------------------
    // 4. Program satp = (1<<31) | (ROOT_PT >> 12) = 0x8008000E.
    // ------------------------------------------------------------------
    li   t0, 0x8008000E
    csrw satp, t0

    // ------------------------------------------------------------------
    // 5. Set mstatus.MPP = S, MPRV = 1. All subsequent loads/stores in
    //    M-mode are treated as if issued from S-mode and go through the MMU.
    //    Ifetch remains bare (M-mode ifetch always bypasses MMU).
    // ------------------------------------------------------------------
    li   t0, MSTATUS_MPP_MASK
    csrc mstatus, t0
    li   t0, MSTATUS_MPP_S
    csrs mstatus, t0
    li   t0, MSTATUS_MPRV
    csrs mstatus, t0

    // ------------------------------------------------------------------
    // 6. Read PATTERN_A through VA 0x81000000. Must equal PATTERN_A.
    //    Keep DATA_VA in s1 across subsequent MMIO prints.
    // ------------------------------------------------------------------
    li   s1, DATA_VA
    lw   t1, 0(s1)
    li   t2, PATTERN_A
    bne  t1, t2, fail

    // ------------------------------------------------------------------
    // 7. Write PATTERN_B through the same VA — store-through-MMU.
    // ------------------------------------------------------------------
    li   t1, PATTERN_B
    sw   t1, 0(s1)

    // ------------------------------------------------------------------
    // 8. Disable MPRV so the next load hits PA directly.
    // ------------------------------------------------------------------
    li   t0, MSTATUS_MPRV
    csrc mstatus, t0

    // ------------------------------------------------------------------
    // 9. Verify PA 0x80001000 now contains PATTERN_B.
    // ------------------------------------------------------------------
    li   t0, DATA_PA
    lw   t1, 0(t0)
    li   t2, PATTERN_B
    bne  t1, t2, fail

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

// puts: t0 = string ptr (null-terminated). Clobbers t3, t4.
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
