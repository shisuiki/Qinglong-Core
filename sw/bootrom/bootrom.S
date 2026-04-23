// BootROM for Stage 7e DDR-backed Linux boot.
//
// Resides in SRAM at 0x8000_0000 (RESET_PC). Polls on a magic word at
// 0x4700_0000 (top of DDR, past where kernel/dtb/initramfs can reach) that is
// written by the Vivado JTAG-to-AXI master once OpenSBI + kernel + DTB have
// been staged in DDR. When the magic matches, jumps to OpenSBI at
// 0x4000_0000 with a0 = hart ID (= 0) and a1 = DTB physical address.
//
// Handshake words (all in DDR, so the same JTAG master that writes OpenSBI
// can also set them):
//   0x4700_0000  BOOT_MAGIC     = 0xDEADBEEF when host side is ready
//   0x4700_0004  BOOT_ENTRY_PA  = OpenSBI entry (typically 0x40000000)
//   0x4700_0008  BOOT_DTB_PA    = DTB physical address (typically 0x42200000)

#define BOOT_HS_BASE 0x47000000

    .section .text.init, "ax"
    .globl _start
_start:
    // Disable interrupts while we poll.
    csrwi   mstatus, 0
    csrwi   mie, 0

    // Scratch stack in SRAM (unused, but well-defined).
    li      sp, 0x80010000        // top of 64 KiB SRAM (exclusive)

    li      t0, BOOT_HS_BASE
    li      t1, 0xDEADBEEF

    // DDR contents survive FPGA reprogram; a stale 0xDEADBEEF from a prior
    // session would make BootROM exit its poll on the first iteration and
    // jump to a stale BOOT_ENTRY_PA. Explicitly clear the handshake region
    // before polling so we always start from a known state.
    sw      zero, 0(t0)           // HS_MAGIC
    sw      zero, 4(t0)           // BOOT_ENTRY_PA
    sw      zero, 8(t0)           // BOOT_DTB_PA
    fence

poll:
    lw      t2, 0(t0)             // read HS_MAGIC
    bne     t2, t1, poll

    // Clear magic so a later reset without rewrite won't re-boot.
    sw      zero, 0(t0)
    fence

    // Load entry/dtb from the handshake words.
    lw      a2, 4(t0)             // BOOT_ENTRY_PA
    lw      a1, 8(t0)             // BOOT_DTB_PA
    li      a0, 0                 // hart 0

    // Jump into DDR. From here ifetch goes through the AXI arbiter path.
    jr      a2
