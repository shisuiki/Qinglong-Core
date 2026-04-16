#!/usr/bin/env bash
# Run Spike on an ELF with commit logging enabled.
# Output goes to the given path in a format compatible with our Verilator trace
# after trace_diff.py normalizes both.
#
# usage: spike_trace.sh <elf> <out.trace>

set -eu

ELF="${1:?elf path required}"
OUT="${2:?output trace path required}"

ISA="${SPIKE_ISA:-RV32I_Zicsr}"
# --priv=m matches our Stage-1 core (M-mode only, no PMP, no Smrnmi).  Without
# this Spike transitions to U-mode via PMP in the riscv-tests reset_vector and
# trace-diff picks up bogus divergences (e.g. ECALL cause 8 vs 11).
PRIV="${SPIKE_PRIV:-m}"
spike \
    --isa="$ISA" \
    --priv="$PRIV" \
    -m0x80000000:0x100000 \
    --log-commits \
    --log="$OUT" \
    "$ELF" > /dev/null 2>&1 || true

# Exit code from Spike: 0 on clean tohost=1, else non-zero.  Don't fail here —
# the diff tool compares regardless.
exit 0
