# riscv-tests (Stage 0) — build report

Vendored upstream tree: `riscv-software-src/riscv-tests` (shallow clone
with the `env/` submodule). ELFs live at the upstream default location,
`sw/riscv-tests/isa/<name>` (no separate `build/` dir); `*.dump` files
are their disassemblies. Built with:

```
./configure --with-xlen=32
make -f Makefile.top isa   # wrapper that forwards to isa/ for the -p- families only
```

## Linker base address

From `env/p/link.ld`:

```
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;         <-- load address
  .text.init : { *(.text.init) }
  ...
}
```

Base / entry region: **`0x8000_0000`** — matches the SRAM window
`0x8000_0000 – 0x8000_FFFF` in the simulation memory map. No linker
changes needed.

## Built test families

| Family        | ELFs built | Source Makefrag               |
|---------------|-----------:|-------------------------------|
| `rv32ui-p-*`  |         42 | `isa/rv32ui/Makefrag`         |
| `rv32um-p-*`  |          8 | `isa/rv32um/Makefrag`         |
| `rv32ua-p-*`  |         10 | `isa/rv32ua/Makefrag`         |
| `rv32mi-p-*`  |         16 | `isa/rv32mi/Makefrag`         |
| `rv32si-p-*`  |          6 | `isa/rv32si/Makefrag`         |
| **total**     |     **82** |                               |

### rv32ui-p-* (42)

add addi and andi auipc beq bge bgeu blt bltu bne fence_i jal jalr lb
lbu ld_st lh lhu lui lw ma_data or ori sb sh simple sll slli slt slti
sltiu sltu sra srai srl srli st_ld sub sw xor xori

### rv32um-p-* (8)

div divu mul mulh mulhsu mulhu rem remu

### rv32ua-p-* (10)

amoadd_w amoand_w amomax_w amomaxu_w amomin_w amominu_w amoor_w
amoswap_w amoxor_w lrsc

### rv32mi-p-* (16)

breakpoint csr illegal instret_overflow lh-misaligned lw-misaligned
ma_addr ma_fetch mcsr pmpaddr sbreak scall sh-misaligned shamt
sw-misaligned zicntr

### rv32si-p-* (6)

csr dirty ma_fetch sbreak scall wfi

## Current pass/fail baseline (2026-04-20, core_multicycle, `make build`)

| Family    | PASS | FAIL | Notes on failures                                 |
|-----------|-----:|-----:|---------------------------------------------------|
| rv32ui    | 41   | 1    | `ma_data` — we trap misaligned, test expects hw   |
| rv32um    |  8   | 0    |                                                   |
| rv32ua    | 10   | 0    |                                                   |
| rv32mi    | 15   | 1    | `breakpoint` — no debug trigger module (by design)|
| rv32si    |  5   | 1    | `dirty` — timeout, Sv32 A/D-bit handling suspect  |
| **total** | 79   | 3    | 3 known gaps, not regressions                     |

Run the full baseline any time with:

```
cd sim && make build
FAMILIES="rv32ui rv32um rv32ua rv32mi rv32si" \
  TIMEOUT=800000 \
  bash scripts/regress.sh build/obj_dir/Vsoc_tb_top
```

## Tests that failed to build

**None** among the four families we care about — all 76 target ELFs
produced and disassembled cleanly.

The upstream `make isa` target also tries to build the `-v-` (virtual
memory) variants (`rv32u{i,m,a,f,d,c}-v-*`), which fail with
`fatal error: string.h: No such file or directory` because the base
`rv32i`/`rv32im`/`rv32ia` multilibs don't ship newlib headers on the
default include path, and those tests `#include <string.h>` from
`env/v/string.c`. We don't have an MMU in Stage 0 anyway, so this is
ignored — `Makefile.top` asks only for the `-p-` dumps, so the `-v-`
build rules are never triggered.

The rv32 floating-point / compressed / bit-manip families (`rv32uc`,
`rv32uf`, `rv32ud`, `rv32uzfh`, `rv32uzb*`) are out of scope for the
RV32IMA core and are not built by the wrapper. `rv32si` **is** now
built (added when OpenSBI/Linux bring-up put S-mode on the critical
path).

## Entry-point sanity check

```
$ riscv64-unknown-elf-objdump -d rv32ui-p-add | head -5
rv32ui-p-add:     file format elf32-littleriscv


Disassembly of section .text.init:
```

First few instructions (from `objdump -d rv32ui-p-add`):

```
80000000 <_start>:
80000000:	0500006f          	j	80000050 <reset_vector>

80000004 <trap_vector>:
80000004:	34202f73          	csrr	t5,mcause
80000008:	00800f93          	li	t6,8
8000000c:	03ff0863          	beq	t5,t6,8000003c <write_tohost>
80000010:	00900f93          	li	t6,9
80000014:	03ff0463          	beq	t5,t6,8000003c <write_tohost>
```

`_start` is at exactly **`0x80000000`** and jumps forward to the
`reset_vector`, exactly as expected. The trap vector sits at
`0x80000004` (the bottom of `mtvec` for the `-p-` environment), which
is fine because our reset PC is `0x80000000` and the CPU walks through
`_start` normally.

## Notes / gotchas for Verilator

- The `tohost` symbol lives in its own `.tohost` section, aligned to
  `0x1000`. In the test binaries it ends up at **`0x80001000`** (after
  the one-page `.text.init`). The harness should resolve `tohost` /
  `fromhost` by reading the ELF symbol table, not hard-code the
  address — a few tests with a larger init section could push it.
- The upstream Makefile passes `-march=rv32g -mabi=ilp32`. It never
  actually emits F/D/C instructions in the `-p-` tests we build, so a
  plain `rv32ima` core will execute them. Disassembled ELFs confirm
  only base-I + M + A instructions are present.
- `autoconf` is not needed — the `configure` script is pre-generated
  and committed in the upstream repo.
