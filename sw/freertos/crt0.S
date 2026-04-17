// FreeRTOS startup for the RV32IMA SoC.
//
// Differences from the bare-metal sw/common/crt0.S:
//   - mtvec is set by xPortStartScheduler, so we do NOT touch it here.
//   - mstatus.MIE stays 0 until FreeRTOS turns interrupts on.
//   - We land in main(); main() is expected to start the scheduler. If the
//     scheduler ever returns, we drop into mmio_exit(1).

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

    // leave interrupts masked; FreeRTOS enables them at scheduler start
    csrwi   mstatus, 0
    csrwi   mie,     0

    mv      a0, zero
    mv      a1, zero
    call    main

    .globl __exit
__exit:
    li      t0, 0xD0580004
    li      t1, 1
    sw      t1, 0(t0)
1:  j       1b
