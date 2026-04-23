#!/usr/bin/env python3
"""Reconstruct store (addr,data) sequence from an rd-only commit trace, diff
pipeline vs multicycle.

The trace format emitted by sim_linux.cpp:
    c<cycle>: 0x<pc> (0x<insn>)[ x<rd>=0x<rd_data>][ TRAP cause=0x<cause>]

For every commit we update a shadow 32-reg file. For every `sw/sh/sb`
instruction (plus AMO that writes the RMW result back) we synthesize the
store (effective_addr, stored_data) and record it. Diff the resulting
store sequences to pinpoint which store first diverges between two runs.
"""
import argparse, re, sys

LINE_RE = re.compile(
    r"c\d+:\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)"
    r"(?:\s+x(\d+)=0x([0-9a-fA-F]+))?"
    r"(?:\s+TRAP cause=0x([0-9a-fA-F]+))?"
)

OP_STORE = 0x23
OP_AMO   = 0x2f
F3_SB, F3_SH, F3_SW = 0, 1, 2
AMO_LR, AMO_SC, AMO_SWAP, AMO_ADD = 0x02, 0x03, 0x01, 0x00
AMO_XOR, AMO_OR, AMO_AND = 0x04, 0x0c, 0x08
AMO_MIN, AMO_MAX, AMO_MINU, AMO_MAXU = 0x10, 0x14, 0x18, 0x1c

def sext(v, bits):
    m = 1 << (bits - 1)
    return (v & (m*2 - 1)) - ((v & m) << 1)

def amo_compute(funct5, old, rs2):
    m = 0xFFFFFFFF
    old_s = sext(old, 32); rs2_s = sext(rs2, 32)
    if   funct5 == AMO_SWAP: return rs2 & m
    elif funct5 == AMO_ADD:  return (old + rs2) & m
    elif funct5 == AMO_XOR:  return (old ^ rs2) & m
    elif funct5 == AMO_AND:  return (old & rs2) & m
    elif funct5 == AMO_OR:   return (old | rs2) & m
    elif funct5 == AMO_MIN:  return (old if old_s < rs2_s else rs2) & m
    elif funct5 == AMO_MAX:  return (rs2 if old_s < rs2_s else old) & m
    elif funct5 == AMO_MINU: return (old if old < rs2 else rs2) & m
    elif funct5 == AMO_MAXU: return (rs2 if old < rs2 else old) & m
    return rs2 & m

def extract_stores(path, limit=0):
    """Walk trace, maintain shadow regs, yield (commit_idx, pc, addr, data, size_bytes, kind)."""
    regs = [0]*32
    stores = []
    idx = 0
    with open(path, "r", errors="replace") as f:
        for ln in f:
            m = LINE_RE.search(ln)
            if not m: continue
            pc = int(m.group(1), 16)
            insn = int(m.group(2), 16)
            rd  = int(m.group(3)) if m.group(3) else 0
            rdv = int(m.group(4), 16) if m.group(4) else 0
            trap = int(m.group(5), 16) if m.group(5) else None

            opcode = insn & 0x7f
            if trap is None:
                rs1 = (insn >> 15) & 0x1f
                rs2 = (insn >> 20) & 0x1f
                f3  = (insn >> 12) & 0x7
                if opcode == OP_STORE:
                    # S-type imm = insn[31:25]|insn[11:7]
                    imm = ((insn >> 25) << 5) | ((insn >> 7) & 0x1f)
                    imm = sext(imm, 12)
                    addr = (regs[rs1] + imm) & 0xFFFFFFFF
                    data = regs[rs2] & 0xFFFFFFFF
                    sz = {F3_SB:1, F3_SH:2, F3_SW:4}.get(f3, 4)
                    # Mask data to the size
                    data_w = data & ((1 << (sz*8)) - 1)
                    stores.append((idx, pc, addr, data_w, sz, "s"))
                elif opcode == OP_AMO and f3 == 2:  # AMO.W only (rv32)
                    funct5 = (insn >> 27) & 0x1f
                    if funct5 == AMO_LR:
                        pass  # no store
                    elif funct5 == AMO_SC:
                        # SC: success if rd=0, data = rs2
                        # rd value is the one committed in the trace
                        if rd == (insn >> 7) & 0x1f and rdv == 0:
                            stores.append((idx, pc, regs[rs1] & 0xFFFFFFFF,
                                           regs[rs2] & 0xFFFFFFFF, 4, "sc"))
                    else:
                        # AMO_RMW: rd = old memory, new memory = op(old, rs2)
                        # we know rd (old) from trace; compute new.
                        old = rdv
                        new = amo_compute(funct5, old, regs[rs2])
                        stores.append((idx, pc, regs[rs1] & 0xFFFFFFFF,
                                       new & 0xFFFFFFFF, 4, f"amo{funct5:02x}"))

            # Apply rd write AFTER extracting source regs
            if rd != 0 and m.group(3):
                regs[rd] = rdv

            idx += 1
            if limit and idx >= limit:
                break
    return stores

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace_a"); ap.add_argument("trace_b")
    ap.add_argument("--limit", type=int, default=0,
                    help="max commits to parse per trace (0 = unlimited)")
    args = ap.parse_args()

    sa = extract_stores(args.trace_a, args.limit)
    sb = extract_stores(args.trace_b, args.limit)
    print(f"stores A={len(sa)} B={len(sb)}")

    n = min(len(sa), len(sb))
    for i in range(n):
        if sa[i] != sb[i]:
            print(f"\nFIRST STORE DIVERGENCE at store#{i}:")
            print(f"  A: commit#{sa[i][0]} pc=0x{sa[i][1]:08x} addr=0x{sa[i][2]:08x} data=0x{sa[i][3]:08x} sz={sa[i][4]} kind={sa[i][5]}")
            print(f"  B: commit#{sb[i][0]} pc=0x{sb[i][1]:08x} addr=0x{sb[i][2]:08x} data=0x{sb[i][3]:08x} sz={sb[i][4]} kind={sb[i][5]}")
            print(f"\n  previous 6 stores (from A):")
            for k in range(max(0,i-6), i):
                s = sa[k]
                print(f"    #{k} commit{s[0]}: pc=0x{s[1]:08x} addr=0x{s[2]:08x} data=0x{s[3]:08x} sz={s[4]} {s[5]}")
            return 1
    print(f"OK: {n} stores match (A={len(sa)} B={len(sb)})")
    return 0

if __name__ == "__main__": sys.exit(main())
