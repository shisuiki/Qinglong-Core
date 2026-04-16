// Stage 1 C demo: minimal printf-style puts over the MMIO console, then exit.
// No libc — we link only crt0.S + this file.

#include <stdint.h>
#include "../../common/mmio.h"

static void put_hex(uint32_t v) {
    static const char H[] = "0123456789abcdef";
    mmio_puts("0x");
    for (int i = 7; i >= 0; --i) {
        mmio_putc(H[(v >> (i * 4)) & 0xf]);
    }
}

static void put_dec(uint32_t v) {
    char buf[12];
    int i = 0;
    if (v == 0) { mmio_putc('0'); return; }
    while (v) { buf[i++] = '0' + (v % 10); v /= 10; }
    while (i--) mmio_putc(buf[i]);
}

int main(void) {
    mmio_puts("Hello from RV32I!\n");

    // Compute a few things to exercise arith + loops.
    uint32_t sum = 0;
    for (uint32_t i = 1; i <= 10; ++i) sum += i;
    mmio_puts("sum(1..10) = ");
    put_dec(sum);
    mmio_puts(" (expect 55)\n");

    uint32_t fib_a = 0, fib_b = 1;
    for (int i = 0; i < 10; ++i) {
        uint32_t t = fib_a + fib_b;
        fib_a = fib_b;
        fib_b = t;
    }
    mmio_puts("fib(10) = ");
    put_dec(fib_a);
    mmio_puts(" (expect 55)\n");

    mmio_puts("magic = ");
    put_hex(0xdeadbeef);
    mmio_puts("\n");

    mmio_puts("bye\n");
    return 0;
}
