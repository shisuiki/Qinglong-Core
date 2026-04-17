RISCV_PREFIX ?= riscv64-unknown-elf-
CC     := $(RISCV_PREFIX)gcc
OBJDUMP:= $(RISCV_PREFIX)objdump
SIZE   := $(RISCV_PREFIX)size

REPO_DIR := $(abspath ../..)
KERNEL   := $(REPO_DIR)/third_party/FreeRTOS-Kernel
PORT_DIR := $(KERNEL)/portable/GCC/RISC-V
EXT_DIR  := $(PORT_DIR)/chip_specific_extensions/RV32I_CLINT_no_extensions

LDFILE   := link.ld

INCLUDES := \
    -I. \
    -I$(REPO_DIR)/sw/common \
    -I$(KERNEL)/include \
    -I$(PORT_DIR) \
    -I$(EXT_DIR)

# rv32im matches picolibc's closest multilib variant; A-ext instructions are
# only emitted for explicit atomics (FreeRTOS uses none), so rv32im is safe.
# picolibc supplies memset/memcpy/strlen etc.; we still use our own crt0.S.
CFLAGS := -march=rv32im_zicsr -mabi=ilp32 -mcmodel=medany \
          -nostartfiles -ffreestanding \
          -specs=picolibc.specs \
          -Os -g -Wall -Wextra -Wno-unused-parameter \
          $(INCLUDES)

# portASM.S uses assembler .include for the chip-specific extensions file.
ASFLAGS := $(CFLAGS) -Wa,-I$(EXT_DIR)

LDFLAGS := -T $(LDFILE) -static -Wl,--no-relax

KSRCS_C := \
    $(KERNEL)/tasks.c \
    $(KERNEL)/queue.c \
    $(KERNEL)/list.c \
    $(KERNEL)/portable/MemMang/heap_1.c \
    $(PORT_DIR)/port.c

KSRCS_S := $(PORT_DIR)/portASM.S

APP_SRCS := main.c crt0.S

OBJDIR := build
KOBJS_C := $(patsubst %.c,$(OBJDIR)/kernel_%.o,$(notdir $(KSRCS_C)))
KOBJS_S := $(patsubst %.S,$(OBJDIR)/kernel_%.o,$(notdir $(KSRCS_S)))
AOBJS_C := $(patsubst %.c,$(OBJDIR)/app_%.o,$(filter %.c,$(APP_SRCS)))
AOBJS_S := $(patsubst %.S,$(OBJDIR)/app_%.o,$(filter %.S,$(APP_SRCS)))

ELF    := freertos_demo.elf
DUMP   := freertos_demo.dump

.PHONY: all clean fpga
all: $(ELF) $(DUMP)

# Variant with the in-main "exit after 10 hellos" branch compiled out, so on
# silicon the scheduler keeps running forever.
fpga: CFLAGS += -DFREERTOS_FPGA
fpga: $(ELF) $(DUMP)

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(OBJDIR)/kernel_%.o: $(KERNEL)/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) -c -o $@ $<
$(OBJDIR)/kernel_%.o: $(KERNEL)/portable/MemMang/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) -c -o $@ $<
$(OBJDIR)/kernel_%.o: $(PORT_DIR)/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) -c -o $@ $<
$(OBJDIR)/kernel_%.o: $(PORT_DIR)/%.S | $(OBJDIR)
	$(CC) $(ASFLAGS) -c -o $@ $<

$(OBJDIR)/app_%.o: %.c | $(OBJDIR)
	$(CC) $(CFLAGS) -c -o $@ $<
$(OBJDIR)/app_%.o: %.S | $(OBJDIR)
	$(CC) $(ASFLAGS) -c -o $@ $<

$(ELF): $(KOBJS_C) $(KOBJS_S) $(AOBJS_C) $(AOBJS_S) $(LDFILE)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(AOBJS_S) $(AOBJS_C) $(KOBJS_C) $(KOBJS_S)
	$(SIZE) $@

$(DUMP): $(ELF)
	$(OBJDUMP) -D $< > $@

clean:
	rm -rf $(OBJDIR) $(ELF) $(DUMP)
