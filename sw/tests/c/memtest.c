// Stage 7b smoke test for the MIG7 DDR3L path on Urbana.
//
// Probes a few KB at the base of the 128 MB DDR window (0x4000_0000):
//   1. Single-word write/read at four scattered addresses (catches a totally
//      dead controller).
//   2. Walking-1s pattern at a single word (catches stuck-bit data lanes).
//   3. Byte-pattern over 4 KB (catches address aliasing within one row).
// Reports pass/fail per phase via the AXI UartLite, then exits via the legacy
// MMIO port (no-op on FPGA, kills sim on Verilator builds).

#include <stdint.h>
#include "../../common/uartlite.h"
#include "../../common/mmio.h"

#define DDR_BASE  0x40000000u
#define DDR_BYTES (4u * 1024u)              // probe size — small but covers a row

static void put_hex(uint32_t v) {
    static const char H[] = "0123456789abcdef";
    uartlite_puts("0x");
    for (int i = 7; i >= 0; --i) uartlite_putc(H[(v >> (i * 4)) & 0xf]);
}

static volatile uint32_t *p32(uint32_t off) {
    return (volatile uint32_t *)(DDR_BASE + off);
}

static int phase_single_word(void) {
    static const uint32_t offs[] = {0x000, 0x010, 0x100, 0x800};
    static const uint32_t vals[] = {0xdeadbeefu, 0xcafef00du, 0x0badc0deu, 0xa5a5a5a5u};
    for (int i = 0; i < 4; ++i) *p32(offs[i]) = vals[i];
    for (int i = 0; i < 4; ++i) {
        uint32_t got = *p32(offs[i]);
        if (got != vals[i]) {
            uartlite_puts("  FAIL @ "); put_hex(DDR_BASE + offs[i]);
            uartlite_puts(" got "); put_hex(got);
            uartlite_puts(" exp "); put_hex(vals[i]);
            uartlite_puts("\r\n");
            return 0;
        }
    }
    return 1;
}

static int phase_walking_ones(void) {
    volatile uint32_t *p = p32(0);
    for (int b = 0; b < 32; ++b) {
        uint32_t v = 1u << b;
        *p = v;
        uint32_t got = *p;
        if (got != v) {
            uartlite_puts("  FAIL @ bit "); put_hex(b);
            uartlite_puts(" got "); put_hex(got);
            uartlite_puts("\r\n");
            return 0;
        }
    }
    return 1;
}

static int phase_pattern(void) {
    const uint32_t words = DDR_BYTES / 4;
    for (uint32_t i = 0; i < words; ++i) *p32(i * 4) = i ^ 0x12345678u;
    for (uint32_t i = 0; i < words; ++i) {
        uint32_t got = *p32(i * 4);
        uint32_t exp = i ^ 0x12345678u;
        if (got != exp) {
            uartlite_puts("  FAIL @ "); put_hex(DDR_BASE + i * 4);
            uartlite_puts(" got "); put_hex(got);
            uartlite_puts(" exp "); put_hex(exp);
            uartlite_puts("\r\n");
            return 0;
        }
    }
    return 1;
}

int main(void) {
    uartlite_puts("\r\nDDR3 memtest @ "); put_hex(DDR_BASE);
    uartlite_puts(" (1Gbit/128MB on Urbana)\r\n");

    int ok = 1;

    uartlite_puts("phase 1 single-word ... ");
    if (phase_single_word()) uartlite_puts("ok\r\n"); else { ok = 0; }

    uartlite_puts("phase 2 walking-1s  ... ");
    if (phase_walking_ones()) uartlite_puts("ok\r\n"); else { ok = 0; }

    uartlite_puts("phase 3 4KB pattern ... ");
    if (phase_pattern()) uartlite_puts("ok\r\n"); else { ok = 0; }

    uartlite_puts(ok ? "PASS\r\n" : "FAIL\r\n");
    mmio_exit(ok ? 0 : 1);
    return 0;
}
