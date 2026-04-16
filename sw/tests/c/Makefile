RISCV_PREFIX ?= riscv64-unknown-elf-
CC     := $(RISCV_PREFIX)gcc
OBJDUMP:= $(RISCV_PREFIX)objdump

COMMON := ../../common
LDFILE := $(COMMON)/link.ld

CFLAGS := -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding \
          -Os -Wall -Wextra -I$(COMMON)
LDFLAGS:= -T $(LDFILE) -static -Wl,--no-relax

SRCS   := $(wildcard *.c)
ELFS   := $(SRCS:.c=.elf)
DUMPS  := $(SRCS:.c=.dump)

.PHONY: all clean
all: $(ELFS) $(DUMPS)

%.elf: %.c $(COMMON)/crt0.S $(LDFILE)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(COMMON)/crt0.S $< -lgcc

%.dump: %.elf
	$(OBJDUMP) -D $< > $@

clean:
	rm -f *.elf *.dump
