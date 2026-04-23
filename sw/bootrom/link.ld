/* BootROM linker script. Code fits entirely in SRAM; handshake is in DDR
 * and is written at runtime by JTAG, so no HS section here. */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    SRAM (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
}

SECTIONS {
    .text.init : { *(.text.init) } > SRAM
    .text      : { *(.text) *(.text.*) } > SRAM
    .rodata    : { *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) } > SRAM
    /DISCARD/ : { *(.eh_frame) *(.comment) *(.note*) *(.data) *(.bss) }
}
