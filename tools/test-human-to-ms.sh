#!/bin/bash
# tools/test-human-to-ms.sh (#1260): unit-test the human-duration parser
# tools/human-to-ms.sh -- the inverse of tools/ms-to-human.sh.
#
# Contract under test -- one assertion per emitted format row:
#   500ms   -> 500
#   2s      -> 2000
#   1m30s   -> 90000
#   1h30m   -> 5400000
#   59s     -> 59000
#   1m0s    -> 60000
#   1h0m    -> 3600000
# plus the `ms`-before-`m` distinction (5m -> 300000) and the guard cases:
# missing / empty / garbage all -> 0, exit 0 (the helper is total -- it never
# crashes).
#
# Auto-discovered by tools/colony-lint.sh's tools-test loop. Exit 0 if all pass.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSE="$SCRIPT_DIR/human-to-ms.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# SKIP cleanly (exit 0) if the helper is not present yet.
if [ ! -f "$PARSE" ]; then
    echo "[SKIP] test-human-to-ms.sh: $PARSE absent"
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
    out="$(sh "$PARSE" "$@" 2>/dev/null)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc" "rc=$rc out=$(printf '%q' "$out") want=$(printf '%q' "$expected")"
    fi
}

# --- one assertion per emitted format row ---
assert_eq "500ms -> 500"       "500"     "500ms"
assert_eq "2s -> 2000"         "2000"    "2s"
assert_eq "1m30s -> 90000"     "90000"   "1m30s"
assert_eq "1h30m -> 5400000"   "5400000" "1h30m"
assert_eq "59s -> 59000"       "59000"   "59s"
assert_eq "1m0s -> 60000"      "60000"   "1m0s"
assert_eq "1h0m -> 3600000"    "3600000" "1h0m"

# --- ms must be distinguished from m ---
assert_eq "5m -> 300000"       "300000"  "5m"

# --- guard cases: all -> 0, exit 0 ---
assert_eq "missing arg -> 0"   "0"            # no $1 at all
assert_eq "empty arg -> 0"     "0" ""         # explicit empty string
assert_eq "garbage arg -> 0"   "0" "1.5abc"   # not a valid duration shape

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
