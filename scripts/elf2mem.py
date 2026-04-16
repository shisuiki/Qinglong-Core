#!/usr/bin/env python3
# Flatten an RV32 ELF into a $readmemh-style hex image for sram_dp.sv.
#
# Output format: one 32-bit little-endian word per line, word 0 = SRAM byte 0.
# Unloaded words are filled with 0x00000000.
#
# Usage:
#   elf2mem.py <input.elf> <output.mem> [--base 0x80000000] [--words 16384]

import argparse
import struct
import sys

ELF_HEADER_FMT = "<16sHHIIIIIHHHHHH"   # EI_*, e_type .. e_shstrndx
PHDR_FMT       = "<IIIIIIII"           # p_type p_offset p_vaddr p_paddr p_filesz p_memsz p_flags p_align
PT_LOAD        = 1


def parse_elf(path):
    with open(path, "rb") as f:
        data = f.read()

    if data[:4] != b"\x7fELF":
        sys.exit(f"elf2mem: {path} is not an ELF")
    if data[4] != 1:
        sys.exit("elf2mem: not ELF32")
    if data[5] != 1:
        sys.exit("elf2mem: not little-endian")

    (_ident, _e_type, _e_machine, _e_version, _e_entry, e_phoff, _e_shoff,
     _e_flags, _e_ehsize, e_phentsize, e_phnum, _e_shentsize, _e_shnum,
     _e_shstrndx) = struct.unpack_from(ELF_HEADER_FMT, data, 0)

    segs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        (p_type, p_offset, p_vaddr, _p_paddr, p_filesz, _p_memsz, _p_flags,
         _p_align) = struct.unpack_from(PHDR_FMT, data, off)
        if p_type != PT_LOAD or p_filesz == 0:
            continue
        segs.append((p_vaddr, data[p_offset:p_offset + p_filesz]))
    return segs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf")
    ap.add_argument("mem")
    ap.add_argument("--base",  default="0x80000000",
                    help="SRAM base address (default: 0x80000000)")
    ap.add_argument("--words", type=int, default=16384,
                    help="SRAM size in 32-bit words (default: 16384 = 64 KiB)")
    args = ap.parse_args()

    base  = int(args.base, 0)
    size  = args.words * 4
    image = bytearray(size)

    overflow = 0
    for vaddr, payload in parse_elf(args.elf):
        off = vaddr - base
        if off < 0 or off + len(payload) > size:
            # Clamp to in-range portion; warn on any spill.
            lo = max(off, 0)
            hi = min(off + len(payload), size)
            if hi > lo:
                image[lo:hi] = payload[lo - off:hi - off]
            overflow += len(payload) - max(0, hi - lo)
        else:
            image[off:off + len(payload)] = payload

    with open(args.mem, "w") as out:
        for w in range(args.words):
            word = struct.unpack_from("<I", image, w * 4)[0]
            out.write(f"{word:08x}\n")

    msg = f"elf2mem: {args.elf} -> {args.mem} ({args.words} words)"
    if overflow:
        msg += f" ({overflow} bytes out of range dropped)"
    print(msg)


if __name__ == "__main__":
    main()
