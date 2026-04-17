// AMD AXI UartLite (pg142) helpers.  Polling-mode TX/RX, no IRQs.
//
// Register map, base-relative:
//   0x00  RX_FIFO  (RO, low 8 bits)
//   0x04  TX_FIFO  (WO, low 8 bits)
//   0x08  STAT     bit0=RX_VALID bit1=RX_FULL bit2=TX_EMPTY bit3=TX_FULL
//   0x0C  CTRL     bit0=RST_TX_FIFO bit1=RST_RX_FIFO bit4=EN_INTR

#ifndef QY_UARTLITE_H
#define QY_UARTLITE_H
#include <stdint.h>

#ifndef UARTLITE_BASE
#define UARTLITE_BASE 0xC0000000u
#endif

#define UL_RX_FIFO  (UARTLITE_BASE + 0x00u)
#define UL_TX_FIFO  (UARTLITE_BASE + 0x04u)
#define UL_STAT     (UARTLITE_BASE + 0x08u)
#define UL_CTRL     (UARTLITE_BASE + 0x0Cu)

#define UL_STAT_RX_VALID (1u << 0)
#define UL_STAT_RX_FULL  (1u << 1)
#define UL_STAT_TX_EMPTY (1u << 2)
#define UL_STAT_TX_FULL  (1u << 3)

static inline void uartlite_putc(char c) {
    while ((*(volatile uint32_t*)UL_STAT) & UL_STAT_TX_FULL) { }
    *(volatile uint32_t*)UL_TX_FIFO = (uint8_t)c;
}

static inline void uartlite_puts(const char* s) {
    while (*s) uartlite_putc(*s++);
}

static inline int uartlite_rx_has(void) {
    return (*(volatile uint32_t*)UL_STAT) & UL_STAT_RX_VALID;
}

static inline char uartlite_getc(void) {
    while (!uartlite_rx_has()) { }
    return (char)(*(volatile uint32_t*)UL_RX_FIFO & 0xFFu);
}

#endif
