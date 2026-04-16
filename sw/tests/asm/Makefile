RISCV_PREFIX ?= riscv64-unknown-elf-
CC     := $(RISCV_PREFIX)gcc
OBJDUMP:= $(RISCV_PREFIX)objdump

LDFILE := ../../common/link.ld

CFLAGS := -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -Wall -Wextra -O0
LDFLAGS:= -T $(LDFILE) -static -Wl,--no-relax

SRCS   := $(wildcard *.S)
ELFS   := $(SRCS:.S=.elf)
DUMPS  := $(SRCS:.S=.dump)

.PHONY: all clean
all: $(ELFS) $(DUMPS)

%.elf: %.S $(LDFILE)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

%.dump: %.elf
	$(OBJDUMP) -D $< > $@

clean:
	rm -f *.elf *.dump
