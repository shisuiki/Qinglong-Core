#!/usr/bin/env python3
"""Diff two RTL commit traces from our Verilator harness.

Trace line format (sim/cpp/sim_linux.cpp):
    c<cycle>: 0x<pc> (0x<insn>)[ x<rd>=0x<rd_data>][ TRAP cause=0x<cause>]

Compares sequences by (pc, insn, rd, rd_val, trap_cause) ignoring cycle
numbers — so pipeline (fast) vs multicycle (slow) can be diffed as long
as they commit the same program in the same order.

On first divergence, prints both records and a small pre-context window.
"""
import argparse, re, sys

LINE_RE = re.compile(
    r"c\d+:\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)"
    r"(?:\s+x(\d+)=0x([0-9a-fA-F]+))?"
    r"(?:\s+TRAP cause=0x([0-9a-fA-F]+))?"
)

def parse(path, skip_pc_below=None, stop_after=0):
    out = []
    with open(path, "r", errors="replace") as f:
        for ln in f:
            m = LINE_RE.search(ln)
            if not m: continue
            pc = int(m.group(1), 16)
            if skip_pc_below is not None and pc < skip_pc_below:
                continue
            insn = int(m.group(2), 16)
            rd  = int(m.group(3)) if m.group(3) else 0
            rdv = int(m.group(4), 16) if m.group(4) else 0
            trap = int(m.group(5), 16) if m.group(5) else None
            out.append((pc, insn, rd, rdv, trap))
            if stop_after and len(out) >= stop_after:
                break
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace_a"); ap.add_argument("trace_b")
    ap.add_argument("--skip-pc-below", type=lambda x:int(x,0), default=None)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--context", type=int, default=8)
    args = ap.parse_args()

    a = parse(args.trace_a, args.skip_pc_below, args.limit)
    b = parse(args.trace_b, args.skip_pc_below, args.limit)
    print(f"parsed A={len(a)} B={len(b)} commits")

    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            print(f"\nFIRST DIVERGENCE at commit #{i}:")
            print(f"  A: pc=0x{a[i][0]:08x} insn=0x{a[i][1]:08x} x{a[i][2]}=0x{a[i][3]:08x} trap={a[i][4]}")
            print(f"  B: pc=0x{b[i][0]:08x} insn=0x{b[i][1]:08x} x{b[i][2]}=0x{b[i][3]:08x} trap={b[i][4]}")
            print(f"\n  previous {args.context} matching commits:")
            for k in range(max(0,i-args.context), i):
                ai = a[k]
                print(f"    #{k}: pc=0x{ai[0]:08x} insn=0x{ai[1]:08x} x{ai[2]}=0x{ai[3]:08x}")
            return 1
    print(f"OK: {n} commits match (A={len(a)} B={len(b)})")
    return 0

if __name__ == "__main__": sys.exit(main())
