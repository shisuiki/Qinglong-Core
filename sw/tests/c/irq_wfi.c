// Stage 4 WFI sanity: timer-interrupt loop but the wait body uses `wfi`
// instead of a plain busy loop. This exercises the decoder's WFI acceptance
// path (12'h105 in the SYSTEM-PRIV family) and confirms we fall through to
// a clean NOP-style commit, letting the next S_FETCH take the pending IRQ.

#include <stdint.h>
#include "mmio.h"

#define CLINT_MTIMECMP_LO  ((volatile uint32_t *)0x02004000u)
#define CLINT_MTIMECMP_HI  ((volatile uint32_t *)0x02004004u)
#define CLINT_MTIME_LO     ((volatile uint32_t *)0x0200BFF8u)
#define CLINT_MTIME_HI     ((volatile uint32_t *)0x0200BFFCu)

#define TICK_PERIOD 200u
#define TARGET_TICKS 4u

static volatile uint32_t irq_count = 0;

static inline uint64_t read_mtime(void) {
    uint32_t hi1, lo, hi2;
    do { hi1 = *CLINT_MTIME_HI; lo = *CLINT_MTIME_LO; hi2 = *CLINT_MTIME_HI; } while (hi1 != hi2);
    return ((uint64_t)hi1 << 32) | lo;
}

static inline void arm_mtimecmp(uint64_t when) {
    *CLINT_MTIMECMP_HI = 0xFFFFFFFFu;
    *CLINT_MTIMECMP_LO = (uint32_t)(when & 0xFFFFFFFFu);
    *CLINT_MTIMECMP_HI = (uint32_t)(when >> 32);
}

__attribute__((interrupt("machine")))
static void trap_handler(void) {
    irq_count++;
    arm_mtimecmp(read_mtime() + TICK_PERIOD);
}

int main(void) {
    asm volatile("csrw mtvec, %0" :: "r"((uintptr_t)trap_handler));
    asm volatile("csrw mie,   %0" :: "r"(1u << 7));
    arm_mtimecmp(read_mtime() + TICK_PERIOD);
    asm volatile("csrrsi zero, mstatus, 0x8");

    while (irq_count < TARGET_TICKS) {
        asm volatile("wfi");
    }

    asm volatile("csrrci zero, mstatus, 0x8");
    mmio_puts("PASS\n");
    mmio_exit(0);
    return 0;
}
