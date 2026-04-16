/* Linker script for Stage 0/1 bare-metal programs.
 * Code at 0x80000000 (matches riscv-tests and our SRAM base).
 * Stack at the top of the 64 KiB SRAM.  Heap unused.
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
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    } > SRAM

    _end_data = .;

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
