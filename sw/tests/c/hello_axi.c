// Stage 5 bare-metal: prints a banner over AMD AXI UartLite @ 0xC000_0000,
// counts a few things to exercise the fabric, then exits through the legacy
// MMIO exit port so `sim-c` can still grade it.
//
// On FPGA the MMIO exit is tied off and the `exit_valid` LED simply lights;
// on sim the harness drops simulation on the exit write.

#include <stdint.h>
#include "../../common/uartlite.h"
#include "../../common/mmio.h"

static void put_hex(uint32_t v) {
    static const char H[] = "0123456789abcdef";
    uartlite_puts("0x");
    for (int i = 7; i >= 0; --i) {
        uartlite_putc(H[(v >> (i * 4)) & 0xf]);
    }
}

static void put_dec(uint32_t v) {
    char buf[12];
    int i = 0;
    if (v == 0) { uartlite_putc('0'); return; }
    while (v) { buf[i++] = '0' + (v % 10); v /= 10; }
    while (i--) uartlite_putc(buf[i]);
}

int main(void) {
    uartlite_puts("\r\n");
    uartlite_puts("Hello from RV32IMA over AXI UartLite!\r\n");

    uint32_t sum = 0;
    for (uint32_t i = 1; i <= 10; ++i) sum += i;
    uartlite_puts("sum(1..10) = ");
    put_dec(sum);
    uartlite_puts(" (expect 55)\r\n");

    uartlite_puts("magic = ");
    put_hex(0xdeadbeef);
    uartlite_puts("\r\n");

    uartlite_puts("PASS\r\n");

    mmio_exit(0);
    return 0;
}
