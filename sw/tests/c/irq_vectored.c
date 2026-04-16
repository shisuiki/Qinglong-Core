// Stage 4 vectored-mtvec test.
//
// Installs an aligned vector table and sets mtvec with mode bit 0 = 1 (vectored).
// Only MTI is enabled, so the timer interrupt must jump to entry [7] of the
// table (offset +28).  The `unhandled` landing spot is there so a bad vector
// index would fail loudly instead of silently passing.

#include <stdint.h>
#include "mmio.h"

#define CLINT_MTIMECMP_LO  ((volatile uint32_t *)0x02004000u)
#define CLINT_MTIMECMP_HI  ((volatile uint32_t *)0x02004004u)
#define CLINT_MTIME_LO     ((volatile uint32_t *)0x0200BFF8u)
#define CLINT_MTIME_HI     ((volatile uint32_t *)0x0200BFFCu)

static volatile uint32_t mti_count = 0;

__attribute__((interrupt("machine")))
void timer_vector(void) {
    mti_count++;
    // Disarm so we only fire once.
    *CLINT_MTIMECMP_HI = 0xFFFFFFFFu;
    *CLINT_MTIMECMP_LO = 0xFFFFFFFFu;
}

__attribute__((interrupt("machine")))
void unhandled(void) {
    mmio_puts("FAIL: wrong vector index\n");
    mmio_exit(1);
}

// Vector table: 12 entries × 4 bytes, 4-byte aligned is enough but we over-align
// to 16 for safety.
extern void vectors(void);
asm(
    ".section .text\n"
    ".align 4\n"
    ".globl vectors\n"
    "vectors:\n"
    "    j unhandled\n"     // 0
    "    j unhandled\n"     // 1
    "    j unhandled\n"     // 2
    "    j unhandled\n"     // 3 (MSI)
    "    j unhandled\n"     // 4
    "    j unhandled\n"     // 5
    "    j unhandled\n"     // 6
    "    j timer_vector\n"  // 7 (MTI)
    "    j unhandled\n"     // 8
    "    j unhandled\n"     // 9
    "    j unhandled\n"     // 10
    "    j unhandled\n"     // 11 (MEI)
);

int main(void) {
    uintptr_t base = (uintptr_t)&vectors;
    asm volatile("csrw mtvec, %0" :: "r"(base | 1u));  // vectored mode
    asm volatile("csrw mie,   %0" :: "r"(1u << 7));    // MTIE

    // Arm timer to fire in 200 cycles.
    uint32_t now = *CLINT_MTIME_LO;
    *CLINT_MTIMECMP_HI = 0;
    *CLINT_MTIMECMP_LO = now + 200;

    asm volatile("csrrsi zero, mstatus, 0x8");

    while (mti_count == 0) {
        asm volatile("wfi");
    }

    asm volatile("csrrci zero, mstatus, 0x8");
    mmio_puts("PASS\n");
    mmio_exit(0);
    return 0;
}
