// FreeRTOS Stage 5.5 bringup demo — two cooperating tasks on the RV32IMA SoC.
//
//   task_blink:  lights the exit LED bit via MMIO status every 500 ms; also
//                prints "[blink N]" to the UART so sim + FPGA both show life
//   task_hello:  prints an incrementing counter every 250 ms
//
// Tick comes from the native CLINT mtime/mtimecmp path via the FreeRTOS
// RISC-V port.  Context switches use CLINT msip internally.
//
// Runs to completion after ~10 ticks from task_hello so sim exits deterministically;
// on FPGA the loop body keeps ticking forever (hello never calls mmio_exit when
// FREERTOS_FPGA is defined at compile time).

#include "FreeRTOS.h"
#include "task.h"

#include <stdint.h>
#include "../common/uartlite.h"
#include "../common/mmio.h"

#define MMIO_STATUS 0xD0580008u

static void uart_puts(const char* s)  { uartlite_puts(s); }

static void put_dec(uint32_t v) {
    char buf[12]; int i = 0;
    if (v == 0) { uartlite_putc('0'); return; }
    while (v) { buf[i++] = '0' + (v % 10); v /= 10; }
    while (i--) uartlite_putc(buf[i]);
}

static void task_blink(void* arg) {
    (void)arg;
    uint32_t n = 0;
    for (;;) {
        uart_puts("[blink ");
        put_dec(n++);
        uart_puts("]\r\n");
        // Toggle the status MMIO so sim trace shows task activity even if
        // UART fidelity is ever in question.
        *(volatile uint32_t*)MMIO_STATUS = 0xB000 | (n & 0xFF);
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

static void task_hello(void* arg) {
    (void)arg;
    uint32_t n = 0;
    for (;;) {
        uart_puts("hello #");
        put_dec(n++);
        uart_puts("\r\n");
#ifndef FREERTOS_FPGA
        if (n == 10) {
            uart_puts("PASS\r\n");
            mmio_exit(0);
        }
#endif
        vTaskDelay(pdMS_TO_TICKS(250));
    }
}

void vAssertCalled(const char* file, int line) {
    (void)file; (void)line;
    uart_puts("ASSERT\r\n");
    mmio_exit(2);
}

// The port.c default weak exception/interrupt handlers just spin.  Provide
// thin overrides so we can see what tripped if an unexpected trap fires.
void freertos_risc_v_application_exception_handler(uint32_t mcause, uint32_t mepc) {
    (void)mcause; (void)mepc;
    uart_puts("EXC\r\n");
    mmio_exit(3);
}
void freertos_risc_v_application_interrupt_handler(uint32_t mcause) {
    (void)mcause;
    uart_puts("IRQ?\r\n");
    mmio_exit(4);
}

extern void freertos_risc_v_trap_handler(void);

int main(void) {
    uart_puts("\r\nFreeRTOS booting on RV32IMA SoC\r\n");

    // Install the FreeRTOS trap handler. The RISC-V port itself does not
    // touch mtvec — that's the application's responsibility.  Direct mode
    // (mtvec[1:0] = 00) is required.
    __asm volatile ("csrw mtvec, %0" :: "r"((uintptr_t)freertos_risc_v_trap_handler));

    xTaskCreate(task_hello, "hello", 256, NULL, 2, NULL);
    xTaskCreate(task_blink, "blink", 256, NULL, 1, NULL);

    vTaskStartScheduler();

    // Should not reach.
    uart_puts("scheduler returned?\r\n");
    mmio_exit(5);
    return 0;
}
