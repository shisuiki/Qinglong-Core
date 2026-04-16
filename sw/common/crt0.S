// Minimal bare-metal startup for Stage 0/1 sim programs.
// Sets up sp, zeros .bss, jumps to main(), then hands off to __exit via MMIO.

    .section .text.init, "ax"
    .globl _start
_start:
    la      sp, _stack_top

    // zero bss
    la      t0, _bss_start
    la      t1, _bss_end
1:
    bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    // disable interrupts for Stage 0/1
    csrwi   mstatus, 0
    csrwi   mie,     0

    // call main(argc=0, argv=NULL); return value goes to exit MMIO
    mv      a0, zero
    mv      a1, zero
    call    main

    // fall through to __exit
    .globl __exit
__exit:
    li      t0, 0xD0580004
    sw      a0, 0(t0)
1:  j       1b
