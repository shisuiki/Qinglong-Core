/* Linker script for the FreeRTOS demo on the RV32IMA SoC.
 * 64 KiB SRAM at 0x80000000; stack at the top.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    SRAM (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
}

SECTIONS {
    .text.init : {
        *(.text.init)
    } > SRAM

    .text : {
        *(.text)
        *(.text.*)
    } > SRAM

    .rodata : {
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
    } > SRAM

    .data : {
        _data_start = .;
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
        _data_end = .;
    } > SRAM

    .bss : {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        _bss_end = .;
    } > SRAM

    . = ALIGN(16);
    _heap_start = .;

    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM);

    /DISCARD/ : { *(.eh_frame) *(.comment) *(.note*) }
}
