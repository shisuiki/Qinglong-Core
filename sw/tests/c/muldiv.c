// Stage-2 M-extension smoke test.  Exercises every funct3 of RV32M and a few
// corner cases (signed overflow, divide-by-zero), then exits with 0 on success.
// Compiled with -march=rv32im_zicsr so `*`, `/`, `%` emit hardware MUL/DIV/REM.

#include <stdint.h>
#include "mmio.h"

static void fail(int code) {
    mmio_puts("FAIL\n");
    mmio_exit(code);
}

static void check_u32(uint32_t got, uint32_t want, int id) {
    if (got != want) fail(id);
}
static void check_s32(int32_t got, int32_t want, int id) {
    if (got != want) fail(id);
}

int main(void) {
    // ---- MUL (signed or unsigned, low 32) ----
    check_s32( 7 *  6,  42, 1);
    check_s32(-7 *  6, -42, 2);
    check_s32(-7 * -6,  42, 3);
    check_u32((uint32_t)0xFFFFFFFFu * 2u, 0xFFFFFFFEu, 4);

    // ---- MULH / MULHU / MULHSU (upper 32 bits) ----
    {
        int64_t  p  = (int64_t)(int32_t)0x12345678 * (int64_t)(int32_t)-3;
        int32_t  hi = (int32_t)(p >> 32);
        int32_t  got;
        asm volatile ("mulh %0, %1, %2" : "=r"(got) : "r"((int32_t)0x12345678), "r"((int32_t)-3));
        check_s32(got, hi, 5);
    }
    {
        uint64_t p   = (uint64_t)0xDEADBEEFu * (uint64_t)0xFEEDFACEu;
        uint32_t hi  = (uint32_t)(p >> 32);
        uint32_t got;
        asm volatile ("mulhu %0, %1, %2" : "=r"(got) : "r"(0xDEADBEEFu), "r"(0xFEEDFACEu));
        check_u32(got, hi, 6);
    }
    {
        int64_t  p  = (int64_t)(int32_t)-1 * (int64_t)(uint32_t)0x80000000u;
        int32_t  hi = (int32_t)(p >> 32);
        int32_t  got;
        asm volatile ("mulhsu %0, %1, %2" : "=r"(got) : "r"((int32_t)-1), "r"(0x80000000u));
        check_s32(got, hi, 7);
    }

    // ---- DIV / REM (signed) ----
    check_s32( 100 /  7,  14, 10);
    check_s32( 100 %  7,   2, 11);
    check_s32(-100 /  7, -14, 12);
    check_s32(-100 %  7,  -2, 13);
    check_s32(-100 / -7,  14, 14);
    check_s32( 100 / -7, -14, 15);

    // ---- DIVU / REMU (unsigned) ----
    check_u32(0xFFFFFFFEu / 2u, 0x7FFFFFFFu, 20);
    check_u32(0xFFFFFFFFu % 7u, 3u,          21);

    // ---- Divide-by-zero semantics (M-ext: Q=-1, R=dividend) ----
    {
        int32_t q, r;
        asm volatile ("div  %0, %1, %2" : "=r"(q) : "r"((int32_t)42), "r"((int32_t)0));
        asm volatile ("rem  %0, %1, %2" : "=r"(r) : "r"((int32_t)42), "r"((int32_t)0));
        check_s32(q, -1, 30);
        check_s32(r, 42, 31);
    }

    // ---- Signed overflow (INT_MIN / -1 → INT_MIN, REM → 0) ----
    {
        int32_t q, r;
        asm volatile ("div %0, %1, %2" : "=r"(q) : "r"((int32_t)0x80000000), "r"((int32_t)-1));
        asm volatile ("rem %0, %1, %2" : "=r"(r) : "r"((int32_t)0x80000000), "r"((int32_t)-1));
        check_s32(q, (int32_t)0x80000000, 40);
        check_s32(r, 0,                   41);
    }

    mmio_puts("PASS\n");
    mmio_exit(0);
    return 0;
}
