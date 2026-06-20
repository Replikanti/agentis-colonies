#!/bin/bash
# tools/test-apply-edits.sh (#1195): unit-test the deterministic search/replace
# applier tools/apply-edits.py.
#
# Background (#1195): code_writer's autonomous path used to ask the LLM to emit
# the FULL new content of an existing file. For a large file (e.g. a ~47KB
# README) that (a) times out the LLM call and (b) gets line-wrap-corrupted on
# the flat-cyborg TUI screen-scrape backend. The fix is to have the LLM emit
# small search/replace edits and assemble the full file deterministically with
# apply-edits.py — small LLM output, so it works on flat-cyborg.
#
# Contract under test:
#   - original content on stdin, edits JSON in $APPLY_EDITS, new content on
#     stdout (large values ride a pipe / env var, never argv -> no ARG_MAX).
#   - each edit's old_str must occur EXACTLY ONCE; zero or >1 matches is a loud,
#     non-zero failure with a JSON {"error": ...} on stderr and NO stdout.
#   - edits apply sequentially.
#
# Cases:
#   1. single edit replaces a unique substring.
#   2. multiple sequential edits apply in order.
#   3. zero-match old_str fails loudly (non-zero, JSON error, no stdout).
#   4. ambiguous (multi-match) old_str fails loudly (non-zero, JSON error).
#   5. large content (simulated big file) round-trips via the env/stdin path.
#
# Auto-discovered by tools/colony-lint.sh's tools-test loop. Exit 0 if all pass.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLY="$SCRIPT_DIR/apply-edits.py"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] test-apply-edits.sh: python3 not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi
if [ ! -f "$APPLY" ]; then
    fail "missing applier: $APPLY"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# -----------------------------------------------------------------------------
# Case 1: single edit replaces a unique substring.
# -----------------------------------------------------------------------------
OUT="$(printf 'hello world\n' | APPLY_EDITS='[{"old_str":"world","new_str":"there"}]' python3 "$APPLY" 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "hello there" ]; then
    pass "single edit replaces a unique substring"
else
    fail "single edit" "rc=$RC out=$(printf '%q' "$OUT")"
fi

# -----------------------------------------------------------------------------
# Case 2: multiple sequential edits apply in order.
# -----------------------------------------------------------------------------
OUT="$(printf 'a b c' | APPLY_EDITS='[{"old_str":"a","new_str":"X"},{"old_str":"c","new_str":"Z"}]' python3 "$APPLY" 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "X b Z" ]; then
    pass "multiple sequential edits apply in order"
else
    fail "multiple edits" "rc=$RC out=$(printf '%q' "$OUT")"
fi

# -----------------------------------------------------------------------------
# Case 3: zero-match old_str fails loudly (non-zero, JSON error, no stdout).
# -----------------------------------------------------------------------------
ERR_FILE="$(mktemp)"
OUT="$(printf 'hello\n' | APPLY_EDITS='[{"old_str":"nope","new_str":"x"}]' python3 "$APPLY" 2>"$ERR_FILE")" && RC=0 || RC=$?
ERR="$(cat "$ERR_FILE")"; rm -f "$ERR_FILE"
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q '"error"'; then
    pass "zero-match old_str fails loudly (non-zero, JSON error, no stdout)"
else
    fail "zero-match" "rc=$RC out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
fi

# -----------------------------------------------------------------------------
# Case 4: ambiguous (multi-match) old_str fails loudly.
# -----------------------------------------------------------------------------
ERR_FILE="$(mktemp)"
OUT="$(printf 'aa\n' | APPLY_EDITS='[{"old_str":"a","new_str":"b"}]' python3 "$APPLY" 2>"$ERR_FILE")" && RC=0 || RC=$?
ERR="$(cat "$ERR_FILE")"; rm -f "$ERR_FILE"
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q '"error"'; then
    pass "ambiguous (multi-match) old_str fails loudly"
else
    fail "ambiguous old_str" "rc=$RC out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
fi

# -----------------------------------------------------------------------------
# Case 5: large content (simulated big file) round-trips via env/stdin.
# Build ~50KB of unique lines, splice in a unique marker, edit just the marker,
# and confirm the marker changed while everything else is preserved verbatim.
# Content travels via a pipe (stdin); the edits via $APPLY_EDITS — never argv.
# -----------------------------------------------------------------------------
BIG="$(python3 -c 'print("\n".join("line %05d filler text here" % i for i in range(2000)))')"
BIG="$BIG
UNIQUE_MARKER_TOKEN_XYZ
$BIG"
EXPECTED="${BIG/UNIQUE_MARKER_TOKEN_XYZ/REPLACED_MARKER_TOKEN}"
OUT="$(printf '%s' "$BIG" | APPLY_EDITS='[{"old_str":"UNIQUE_MARKER_TOKEN_XYZ","new_str":"REPLACED_MARKER_TOKEN"}]' python3 "$APPLY" 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXPECTED" ]; then
    pass "large content round-trips via env/stdin (>50KB, marker edit, rest preserved)"
else
    fail "large content" "rc=$RC bytes_in=$(printf '%s' "$BIG" | wc -c) bytes_out=$(printf '%s' "$OUT" | wc -c)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
