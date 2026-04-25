/* No-libc rv32 init — pure asm, no libc startup. Critical: must initialize
 * gp from __global_pointer$ before any la pseudo-op, because the assembler
 * relaxes la to addi rd,gp,off when the target lies within +/-2 KB of gp.
 * Without this, gp=0 at entry → la produces kernel-side addresses → SIGSEGV.
 */
.section .text
.global _start
_start:
.option push
.option norelax
1:  auipc   gp, %pcrel_hi(__global_pointer$)
    addi    gp, gp, %pcrel_lo(1b)
.option pop

    /* Heartbeat: write(1, msg, MSGLEN); nanosleep(5s) */
2:
    li      a7, 64                  /* __NR_write */
    li      a0, 1                   /* fd = stdout (dup'd to /dev/console) */
    la      a1, msg
    li      a2, 42                  /* strlen("URBANA-USERSPACE: ...write1}\n")=42 */
    ecall

    li      a7, 101                 /* __NR_nanosleep */
    la      a0, ts
    mv      a1, zero
    ecall
    j       2b

.section .rodata
msg:
    .ascii  "URBANA-USERSPACE: FLAG{nolibc_asm_write1}\n"
.equ        MSGLEN, . - msg

.section .data
ts:
    .word   5                       /* tv_sec  */
    .word   0                       /* tv_nsec */
