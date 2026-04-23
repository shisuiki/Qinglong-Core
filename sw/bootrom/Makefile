# BootROM for the DDR-backed Linux boot flow.
#
#   make       → bootrom.elf + bootrom.mem (Xilinx mem format)
#   make clean → rm generated artifacts

RISCV_PREFIX ?= riscv64-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJDUMP := $(RISCV_PREFIX)objdump
OBJCOPY := $(RISCV_PREFIX)objcopy

REPO    := $(abspath ../..)

CFLAGS  := -march=rv32ima_zicsr_zifencei -mabi=ilp32 \
           -nostdlib -nostartfiles -ffreestanding -Os -Wall -Wextra
LDFLAGS := -T link.ld -static -Wl,--no-relax

.PHONY: all clean
all: bootrom.mem bootrom.dump

bootrom.elf: bootrom.S link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ bootrom.S

bootrom.dump: bootrom.elf
	$(OBJDUMP) -D $< > $@

bootrom.mem: bootrom.elf
	$(REPO)/scripts/elf2mem.py $< $@

clean:
	rm -f bootrom.elf bootrom.dump bootrom.mem
