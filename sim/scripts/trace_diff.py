#!/usr/bin/env python3
"""Compare our Verilator commit trace against a Spike --log-commits trace.

Both logs use roughly this shape (our format is designed to match):

    core   0: 3 0x<pc> (0x<insn>) [x<rd> 0x<rd_data>]

Spike adds several variants we normalize away: mem accesses, interrupts,
spike-specific annotations.  We extract (pc, insn, rd, rd_value) per retirement
and compare.

Exit 0 on first N-line prefix match (where N = len(shorter) — we don't require
both to terminate identically since Spike may run longer or bail earlier).
"""

import argparse
import re
import sys
from typing import List, Optional, Tuple

# Accept both Spike and our own trace.  Spike puts  "core N: 3 pc (insn) x5 val"
# on retirement lines; mem lines are "core N: 3 mem 0x..." — ignore.
LINE_RE = re.compile(
    r"core\s+\d+:\s*\d+\s+"                        # "core 0: 3"
    r"0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)"    # pc, insn
    r"(?:\s+x\s*(\d+)\s+0x([0-9a-fA-F]+))?"       # optional rd write
)
MEM_RE = re.compile(r"core\s+\d+:\s*\d+\s+mem\s+")
# Trap line from our trace:  "... (0x...) TRAP cause=0x..."
TRAP_RE = re.compile(r"TRAP cause=0x([0-9a-fA-F]+)")


class Commit:
    __slots__ = ("pc", "insn", "rd", "rd_val", "trap_cause")

    def __init__(self, pc: int, insn: int,
                 rd: Optional[int], rd_val: Optional[int],
                 trap_cause: Optional[int]):
        self.pc = pc
        self.insn = insn
        self.rd = rd
        self.rd_val = rd_val
        self.trap_cause = trap_cause

    def __repr__(self) -> str:
        s = f"pc=0x{self.pc:08x} insn=0x{self.insn:08x}"
        if self.rd is not None:
            s += f" x{self.rd}=0x{self.rd_val:08x}"
        if self.trap_cause is not None:
            s += f" TRAP=0x{self.trap_cause:x}"
        return s


def parse_trace(path: str, pc_floor: int = 0) -> List[Commit]:
    out: List[Commit] = []
    with open(path, "r", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if MEM_RE.search(line):
                continue
            m = LINE_RE.search(line)
            if not m:
                continue
            pc = int(m.group(1), 16)
            if pc < pc_floor:
                # Drop Spike bootrom / any commits outside our SRAM window.
                continue
            insn = int(m.group(2), 16)
            rd = int(m.group(3)) if m.group(3) is not None else None
            rd_val = int(m.group(4), 16) if m.group(4) is not None else None
            tm = TRAP_RE.search(line)
            trap_cause = int(tm.group(1), 16) if tm else None
            out.append(Commit(pc, insn, rd, rd_val, trap_cause))
    return out


def compare(rtl: List[Commit], ref: List[Commit], limit: int = 0) -> int:
    """Two-pointer compare.  Trap commits on the RTL side are "stricter than
    Spike" — e.g. our core traps on CSR 0x744 (mnscratch) while Spike accepts
    it.  When RTL traps at PC X, we consume the matching ref commit at PC X
    (if present) and continue aligned."""
    i = j = 0
    matched = 0
    while i < len(rtl) and j < len(ref):
        if limit and matched >= limit:
            break
        a = rtl[i]
        b = ref[j]

        # RTL trap: the faulting instruction jumps to mtvec.  Spike may have
        # executed that instruction (and any others up to mtvec) without
        # trapping (e.g. PMP / Smrnmi CSRs that we don't implement).  Skip
        # ref commits whose PC < mtvec-target.
        if a.trap_cause is not None:
            # Next real RTL commit (after this trap) gives the mtvec target.
            target_pc = None
            k = i + 1
            while k < len(rtl) and rtl[k].trap_cause is not None:
                k += 1
            if k < len(rtl):
                target_pc = rtl[k].pc
            if target_pc is not None:
                while j < len(ref) and ref[j].pc < target_pc:
                    j += 1
            else:
                # unknown target, just skip matching PC
                if b.pc == a.pc:
                    j += 1
            i += 1
            continue
        # Ref trap (Spike) without matching RTL commit: skip it.
        if b.trap_cause is not None:
            j += 1
            continue

        if a.pc != b.pc or a.insn != b.insn:
            print(f"MISMATCH @ rtl#{i} ref#{j}: rtl={a}  ref={b}")
            return 1

        # rd write compare (ignore x0)
        if (a.rd and a.rd != 0) or (b.rd and b.rd != 0):
            ar = a.rd or 0
            br = b.rd or 0
            av = a.rd_val or 0
            bv = b.rd_val or 0
            if ar != br or av != bv:
                print(f"RD mismatch @ rtl#{i} ref#{j}: rtl={a}  ref={b}")
                return 1

        i += 1
        j += 1
        matched += 1

    print(f"OK: matched {matched} commits (rtl={len(rtl)}, ref={len(ref)})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("rtl_trace", help="trace from Verilator run")
    ap.add_argument("ref_trace", help="trace from spike --log-commits")
    ap.add_argument("--limit", type=int, default=0, help="max commits to diff (0 = unlimited)")
    ap.add_argument("--pc-floor", type=lambda x: int(x, 0), default=0x80000000,
                    help="drop commits with pc < floor (to skip Spike bootrom)")
    args = ap.parse_args()

    rtl = parse_trace(args.rtl_trace, pc_floor=args.pc_floor)
    ref = parse_trace(args.ref_trace, pc_floor=args.pc_floor)

    if not rtl:
        print(f"ERROR: no retirements parsed from {args.rtl_trace}")
        return 2
    if not ref:
        print(f"ERROR: no retirements parsed from {args.ref_trace}")
        return 2

    return compare(rtl, ref, args.limit)


if __name__ == "__main__":
    sys.exit(main())
