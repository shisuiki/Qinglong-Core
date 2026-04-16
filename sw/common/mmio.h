#ifndef QY_MMIO_H
#define QY_MMIO_H
#include <stdint.h>

#define MMIO_CONSOLE 0xD0580000u
#define MMIO_EXIT    0xD0580004u
#define MMIO_STATUS  0xD0580008u

static inline void mmio_putc(char c) {
    *(volatile uint8_t*)MMIO_CONSOLE = (uint8_t)c;
}

static inline void mmio_puts(const char* s) {
    while (*s) mmio_putc(*s++);
}

__attribute__((noreturn)) static inline void mmio_exit(int code) {
    *(volatile uint32_t*)MMIO_EXIT = (uint32_t)code;
    for (;;) { /* spin */ }
}

#endif
