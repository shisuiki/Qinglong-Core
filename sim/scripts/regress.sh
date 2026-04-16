#!/usr/bin/env bash
# Regression runner: iterate every ELF in sw/riscv-tests/isa/ that matches a
# given family and run it under Verilator.  Prints a summary table.
#
# usage: regress.sh <path-to-Vsoc_tb_top>
#
# env:
#   FAMILIES   space-separated list of families to run (default: rv32ui rv32mi)
#   TIMEOUT    per-test cycle cap (default 400000)
#   KEEP_GOING 1 to continue on failure (default 1)

set -u

BIN="${1:?usage: regress.sh <path-to-Vsoc_tb_top>}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ISA_DIR="$REPO/sw/riscv-tests/isa"
OUT_DIR="$REPO/sim/build/regress"
mkdir -p "$OUT_DIR"

FAMILIES="${FAMILIES:-rv32ui rv32mi rv32um rv32ua}"
TIMEOUT="${TIMEOUT:-400000}"
KEEP_GOING="${KEEP_GOING:-1}"

pass=0
fail=0
failed_tests=()

for fam in $FAMILIES; do
    pattern="$ISA_DIR/${fam}-p-*"
    for elf in $pattern; do
        # Skip .dump / non-ELF sidecars
        [[ "$elf" == *.dump ]] && continue
        [[ ! -f "$elf" ]] && continue
        [[ -d "$elf" ]] && continue
        test_name="$(basename "$elf")"
        log="$OUT_DIR/${test_name}.log"
        rc=0
        "$BIN" +elf="$elf" +timeout="$TIMEOUT" +quiet >"$log" 2>&1 || rc=$?
        if [[ $rc -eq 0 ]]; then
            echo "  PASS  $test_name"
            pass=$((pass+1))
        else
            echo "  FAIL  $test_name  (rc=$rc, see $log)"
            fail=$((fail+1))
            failed_tests+=("$test_name")
            [[ "$KEEP_GOING" == 1 ]] || break 2
        fi
    done
done

echo
echo "=============================================="
echo "Regression summary:  PASS=$pass  FAIL=$fail"
if [[ ${#failed_tests[@]} -gt 0 ]]; then
    echo "Failing tests:"
    for t in "${failed_tests[@]}"; do echo "  $t"; done
fi
echo "=============================================="

exit $fail
