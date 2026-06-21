#!/bin/bash
# tools/test-ms-to-human.sh (#1246): unit-test the millisecond-duration
# formatter tools/ms-to-human.sh.
#
# Contract under test -- one assertion per documented range:
#   < 1000                 -> <N>ms     (500     -> 500ms)
#   >= 1000,  < 60000      -> <S>s      (2000    -> 2s)
#   >= 60000, < 3600000    -> <M>m<S>s  (90000   -> 1m30s)
#   >= 3600000             -> <H>h<M>m  (5400000 -> 1h30m)
# plus the guard cases: missing / empty / negative / non-integer all -> 0ms,
# exit 0 (the helper is total -- it never crashes).
#
# Auto-discovered by tools/colony-lint.sh's tools-test loop. Exit 0 if all pass.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FMT="$SCRIPT_DIR/ms-to-human.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# SKIP cleanly (exit 0) if the helper is not present yet.
if [ ! -f "$FMT" ]; then
    echo "[SKIP] test-ms-to-human.sh: $FMT absent"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# assert_eq <description> <expected> [args...]
# Runs the helper under `sh` (proves dash-safety) with the given args and
# compares stdout to <expected>, also requiring a clean exit.
assert_eq() {
    desc="$1"; expected="$2"; shift 2
    out="$(sh "$FMT" "$@" 2>/dev/null)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc" "rc=$rc out=$(printf '%q' "$out") want=$(printf '%q' "$expected")"
    fi
}

# --- one assertion per documented range ---
assert_eq "< 1000 -> <N>ms (500 -> 500ms)"                   "500ms" 500
assert_eq ">= 1000, < 60000 -> <S>s (2000 -> 2s)"            "2s"    2000
assert_eq ">= 60000, < 3600000 -> <M>m<S>s (90000 -> 1m30s)" "1m30s" 90000
assert_eq ">= 3600000 -> <H>h<M>m (5400000 -> 1h30m)"        "1h30m" 5400000

# --- guard cases: all -> 0ms, exit 0 ---
assert_eq "missing arg -> 0ms"     "0ms"            # no $1 at all
assert_eq "empty arg -> 0ms"       "0ms" ""         # explicit empty string
assert_eq "negative arg -> 0ms"    "0ms" -5         # '-' is non-digit
assert_eq "non-integer arg -> 0ms" "0ms" "1.5abc"   # decimals / letters

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
