// Stage 5 smoke test: exercise the AXI4-Lite master shim + sim BRAM slave at
// 0xC000_0000. Store a word, read it back, store+read a second word, then emit
// PASS / exit 0. Fails (exit 1) on any mismatch.

    .section .text.init, "ax"
    .globl _start
_start:
    li      t0, 0xC0001000      // AXI-Lite BRAM slave base (UartLite lives at 0xC0000000)
    li      t1, 0xCAFEBABE
    sw      t1, 0(t0)
    lw      t2, 0(t0)
    bne     t1, t2, fail

    li      t1, 0x12345678
    sw      t1, 16(t0)
    lw      t2, 16(t0)
    bne     t1, t2, fail

    // byte-strobed write: clobber only the low byte
    li      t1, 0x000000AA
    sb      t1, 0(t0)
    lw      t2, 0(t0)
    li      t3, 0xCAFEBAAA
    bne     t2, t3, fail

    // print PASS
    la      t0, 0xD0580000
    li      t1, 'P'
    sb      t1, 0(t0)
    li      t1, 'A'
    sb      t1, 0(t0)
    li      t1, 'S'
    sb      t1, 0(t0)
    li      t1, 'S'
    sb      t1, 0(t0)
    li      t1, '\n'
    sb      t1, 0(t0)
    la      t0, 0xD0580004
    li      t1, 0
    sw      t1, 0(t0)
1:  j       1b

fail:
    la      t0, 0xD0580004
    li      t1, 1
    sw      t1, 0(t0)
2:  j       2b
