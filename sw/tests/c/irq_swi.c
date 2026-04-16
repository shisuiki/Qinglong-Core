// Stage 4 software-interrupt demo.
//
// Exercises the CLINT msip register: set msip=1, MSIE+MIE on, wait for the
// handler to observe the correct mcause, clear msip in the handler (so it
// doesn't re-fire), then return and PASS.

#include <stdint.h>
#include "mmio.h"

#define CLINT_MSIP ((volatile uint32_t *)0x02000000u)

static volatile uint32_t irq_count = 0;
static volatile uint32_t last_cause = 0;

__attribute__((interrupt("machine")))
static void trap_handler(void) {
    uint32_t c;
    asm volatile("csrr %0, mcause" : "=r"(c));
    last_cause = c;
    irq_count++;
    *CLINT_MSIP = 0;   // clear so we don't re-enter immediately
}

int main(void) {
    asm volatile("csrw mtvec, %0" :: "r"((uintptr_t)trap_handler));
    asm volatile("csrw mie,   %0" :: "r"(1u << 3));  // MSIE
    asm volatile("csrrsi zero, mstatus, 0x8");       // set MIE

    *CLINT_MSIP = 1;                                 // raise software interrupt

    // Handler should have fired by the time we observe irq_count changing.
    while (irq_count == 0) { }

    asm volatile("csrrci zero, mstatus, 0x8");

    if (last_cause != 0x80000003u) {
        mmio_puts("FAIL: unexpected mcause\n");
        mmio_exit(1);
    }

    mmio_puts("PASS\n");
    mmio_exit(0);
    return 0;
}
