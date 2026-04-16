// Stage 4 timer-interrupt demo.
//
// Arms the CLINT timer for a short interval, enables MTIE + MIE, and counts
// how many times the trap handler fires.  After N ticks the main loop
// disables interrupts, prints PASS, and exits.
//
// Each time the handler runs it re-arms mtimecmp for the next tick.  This
// exercises: mtvec installation, mie/mstatus bit toggling, mcause readout
// of an interrupt cause (MSB=1), re-arming MTI, and mret.

#include <stdint.h>
#include "mmio.h"

#define CLINT_BASE         0x02000000u
#define CLINT_MSIP         ((volatile uint32_t *)(CLINT_BASE + 0x0000))
#define CLINT_MTIMECMP_LO  ((volatile uint32_t *)(CLINT_BASE + 0x4000))
#define CLINT_MTIMECMP_HI  ((volatile uint32_t *)(CLINT_BASE + 0x4004))
#define CLINT_MTIME_LO     ((volatile uint32_t *)(CLINT_BASE + 0xBFF8))
#define CLINT_MTIME_HI     ((volatile uint32_t *)(CLINT_BASE + 0xBFFC))

#define TICK_PERIOD 200u   // CPU cycles between timer IRQs
#define TARGET_TICKS 8u

static volatile uint32_t irq_count = 0;
static volatile uint32_t last_cause = 0;

static inline uint64_t read_mtime(void) {
    uint32_t hi1, lo, hi2;
    do {
        hi1 = *CLINT_MTIME_HI;
        lo  = *CLINT_MTIME_LO;
        hi2 = *CLINT_MTIME_HI;
    } while (hi1 != hi2);
    return ((uint64_t)hi1 << 32) | lo;
}

static inline void arm_mtimecmp(uint64_t when) {
    // Writing lo first after clearing hi to a huge value prevents a spurious
    // early fire during the lo↔hi window.
    *CLINT_MTIMECMP_HI = 0xFFFFFFFFu;
    *CLINT_MTIMECMP_LO = (uint32_t)(when & 0xFFFFFFFFu);
    *CLINT_MTIMECMP_HI = (uint32_t)(when >> 32);
}

__attribute__((interrupt("machine")))
static void trap_handler(void) {
    uint32_t c;
    asm volatile("csrr %0, mcause" : "=r"(c));
    last_cause = c;
    irq_count++;
    // Re-arm for the next tick.  Reading mtime + adding the period is the
    // usual way; this gets us fixed-period drift-compensated ticks.
    arm_mtimecmp(read_mtime() + TICK_PERIOD);
}

int main(void) {
    asm volatile("csrw mtvec, %0" :: "r"((uintptr_t)trap_handler));
    asm volatile("csrw mie,   %0" :: "r"(1u << 7));  // MTIE

    // Arm first tick and enable global interrupts.
    arm_mtimecmp(read_mtime() + TICK_PERIOD);
    asm volatile("csrrsi zero, mstatus, 0x8");       // set MIE

    // Spin until we've accumulated enough ticks.
    while (irq_count < TARGET_TICKS) {
        // busy wait — interrupts will advance irq_count
    }

    asm volatile("csrrci zero, mstatus, 0x8");       // clear MIE

    // Sanity check the last observed cause is the timer interrupt cause
    // (0x80000007).  If not, fail loudly.
    if (last_cause != 0x80000007u) {
        mmio_puts("FAIL: unexpected mcause\n");
        mmio_exit(1);
    }

    mmio_puts("PASS\n");
    mmio_exit(0);
    return 0;
}
