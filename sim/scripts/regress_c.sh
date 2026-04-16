#!/usr/bin/env bash
# Regression runner for the in-tree C tests under sw/tests/c/.
# A test passes if the harness exits cleanly AND the log contains a
# `[sim] MMIO exit 0` line (exit code 0 through the MMIO exit register).
#
# usage: regress_c.sh <path-to-Vsoc_tb_top>
#
# env:
#   TIMEOUT    per-test cycle cap (default 200000)
#   KEEP_GOING 1 to continue on failure (default 1)

set -u

BIN="${1:?usage: regress_c.sh <path-to-Vsoc_tb_top>}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
C_DIR="$REPO/sw/tests/c"
OUT_DIR="$REPO/sim/build/regress_c"
mkdir -p "$OUT_DIR"

TIMEOUT="${TIMEOUT:-200000}"
KEEP_GOING="${KEEP_GOING:-1}"

pass=0
fail=0
failed_tests=()

for elf in "$C_DIR"/*.elf; do
    [[ -f "$elf" ]] || continue
    test_name="$(basename "$elf" .elf)"
    log="$OUT_DIR/${test_name}.log"
    rc=0
    "$BIN" +elf="$elf" +timeout="$TIMEOUT" >"$log" 2>&1 || rc=$?

    if [[ $rc -eq 0 ]] && grep -q '\[sim\] MMIO exit 0' "$log"; then
        echo "  PASS  $test_name"
        pass=$((pass+1))
    else
        echo "  FAIL  $test_name  (rc=$rc, see $log)"
        fail=$((fail+1))
        failed_tests+=("$test_name")
        [[ "$KEEP_GOING" == 1 ]] || break
    fi
done

echo
echo "=============================================="
echo "C regression summary:  PASS=$pass  FAIL=$fail"
if [[ ${#failed_tests[@]} -gt 0 ]]; then
    echo "Failing tests:"
    for t in "${failed_tests[@]}"; do echo "  $t"; done
fi
echo "=============================================="

exit $fail
