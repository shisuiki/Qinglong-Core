// Stage 0 smoke test: writes "PASS\n" to the console MMIO then terminates
// simulation with exit code 0.

    .section .text.init, "ax"
    .globl _start
_start:
    la      t0, 0xD0580000     // console TX
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

    // signal simulation exit 0
    la      t0, 0xD0580004
    li      t1, 0
    sw      t1, 0(t0)
1:  j       1b
