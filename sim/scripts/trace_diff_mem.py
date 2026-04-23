#!/usr/bin/env python3
"""Diff two dmem-bus traces from sim_linux.cpp.

Trace line forms (sim/cpp/sim_linux.cpp):
  i<cycle>: VA=0x<va> PA=0x<pa> {LD|ST} sz=<n> [wmask=0x<m> wdata=0x<wd>]
  r<cycle>: VA=0x<va> PA=0x<pa> {LD|ST} rdata=0x<rd>[ FAULT][ PFAULT]

Goal: find the first memory-level event where pipeline and multicycle
diverge. Two flavors of divergence:

  (A) translation diverges: same VA seen in both streams maps to a
      different PA in pipeline vs multicycle.
  (B) data diverges: same (VA,PA) load returns a different rdata, OR
      a different store wdata is written, AT THE SAME OP INDEX.

Cycle counts can differ between the two cores (different microarchitecture);
we compare by the SEQUENCE of issued ops, optionally narrowed to a PA range.
"""
import argparse, re, sys

ISSUE_RE = re.compile(
    r"i(\d+):\s+VA=0x([0-9a-fA-F]+)\s+PA=0x([0-9a-fA-F]+)\s+(LD|ST)\s+sz=(\d+)"
    r"(?:\s+wmask=0x([0-9a-fA-F]+)\s+wdata=0x([0-9a-fA-F]+))?"
)
RSP_RE = re.compile(
    r"r(\d+):\s+VA=0x([0-9a-fA-F]+)\s+PA=0x([0-9a-fA-F]+)\s+(LD|ST)\s+rdata=0x([0-9a-fA-F]+)"
    r"(\s+FAULT)?(\s+PFAULT)?"
)

def parse(path, pa_min=0, pa_max=0xFFFFFFFF):
    """Return list of paired ops: (cycle_i, va, pa, kind, sz, wmask, wdata,
    cycle_r, rdata, fault, pfault). Pairs an i-line with the next r-line for
    the same (VA,PA,kind). Drops orphans."""
    pending = None
    out = []
    with open(path, "r", errors="replace") as f:
        for ln in f:
            mi = ISSUE_RE.search(ln)
            if mi:
                cyc = int(mi.group(1))
                va  = int(mi.group(2), 16)
                pa  = int(mi.group(3), 16)
                if pa < pa_min or pa > pa_max:
                    pending = None
                    continue
                kind = mi.group(4)
                sz   = int(mi.group(5))
                wm   = int(mi.group(6), 16) if mi.group(6) else 0
                wd   = int(mi.group(7), 16) if mi.group(7) else 0
                pending = (cyc, va, pa, kind, sz, wm, wd)
                continue
            mr = RSP_RE.search(ln)
            if mr and pending is not None:
                cyc_r = int(mr.group(1))
                va_r  = int(mr.group(2), 16)
                pa_r  = int(mr.group(3), 16)
                kind_r = mr.group(4)
                rd    = int(mr.group(5), 16)
                fault = bool(mr.group(6))
                pfault= bool(mr.group(7))
                if (va_r, pa_r, kind_r) == (pending[1], pending[2], pending[3]):
                    out.append(pending + (cyc_r, rd, fault, pfault))
                    pending = None
    return out

def fmt(op):
    cyc_i, va, pa, kind, sz, wm, wd, cyc_r, rd, fl, pfl = op
    base = f"i={cyc_i} r={cyc_r} VA=0x{va:08x} PA=0x{pa:08x} {kind} sz={sz}"
    if kind == "ST":
        return f"{base} wmask=0x{wm:x} wdata=0x{wd:08x}{' FAULT' if fl else ''}{' PFAULT' if pfl else ''}"
    return f"{base} rdata=0x{rd:08x}{' FAULT' if fl else ''}{' PFAULT' if pfl else ''}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace_a"); ap.add_argument("trace_b")
    ap.add_argument("--pamin", type=lambda x:int(x,0), default=0,
                    help="filter ops with PA below this")
    ap.add_argument("--pamax", type=lambda x:int(x,0), default=0xFFFFFFFF,
                    help="filter ops with PA above this")
    ap.add_argument("--vafilter", type=lambda x:int(x,0), default=None,
                    help="only show ops touching this VA's word")
    ap.add_argument("--context", type=int, default=8)
    ap.add_argument("--show-all", action="store_true",
                    help="dump entire matched op stream side-by-side")
    args = ap.parse_args()

    a = parse(args.trace_a, args.pamin, args.pamax)
    b = parse(args.trace_b, args.pamin, args.pamax)

    if args.vafilter is not None:
        word = args.vafilter & ~3
        a = [op for op in a if (op[1] & ~3) == word]
        b = [op for op in b if (op[1] & ~3) == word]

    print(f"parsed A={len(a)} B={len(b)} mem ops")

    if args.show_all:
        for k in range(max(len(a), len(b))):
            la = fmt(a[k]) if k < len(a) else "—"
            lb = fmt(b[k]) if k < len(b) else "—"
            mark = "" if (k < len(a) and k < len(b) and
                          a[k][1:7] == b[k][1:7] and a[k][8:12] == b[k][8:12]) \
                       else "  ***"
            print(f"#{k}: A: {la}\n     B: {lb}{mark}")
        return 0

    # Compare matched ops: VA, PA, kind, sz, wmask, wdata, rdata, fault, pfault
    n = min(len(a), len(b))
    for i in range(n):
        ka = (a[i][1], a[i][2], a[i][3], a[i][4], a[i][5], a[i][6],
              a[i][8], a[i][9], a[i][10], a[i][11])
        kb = (b[i][1], b[i][2], b[i][3], b[i][4], b[i][5], b[i][6],
              b[i][8], b[i][9], b[i][10], b[i][11])
        if ka != kb:
            kind = "TRANSLATION" if (ka[0] == kb[0] and ka[1] != kb[1]) \
                   else ("DATA" if (ka[0] == kb[0] and ka[1] == kb[1]) else "ORDER")
            print(f"\nFIRST MEM DIVERGENCE at op#{i}  ({kind}):")
            print(f"  A: {fmt(a[i])}")
            print(f"  B: {fmt(b[i])}")
            print(f"\n  previous {args.context} ops (A):")
            for k in range(max(0, i-args.context), i):
                print(f"    #{k}: {fmt(a[k])}")
            print(f"\n  previous {args.context} ops (B):")
            for k in range(max(0, i-args.context), i):
                print(f"    #{k}: {fmt(b[k])}")
            return 1
    print(f"OK: {n} mem ops match (A={len(a)} B={len(b)})")
    return 0

if __name__ == "__main__": sys.exit(main())
