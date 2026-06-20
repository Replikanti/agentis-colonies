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
#   - each edit's old_str must resolve to EXACTLY ONE span — first by exact
#     match, then (#1204) by a whitespace-normalized fallback (trailing
#     whitespace stripped per line + CRLF->LF, no leading/internal collapse).
#     Zero or >1 matches at BOTH steps is a loud, non-zero failure with a JSON
#     {"error": ...} on stderr and NO stdout.
#   - edits apply sequentially.
#
# Cases:
#   1. single edit replaces a unique substring (exact match).
#   2. multiple sequential edits apply in order.
#   3. zero-match old_str fails loudly (non-zero, JSON error, no stdout).
#   4. ambiguous (multi-match) old_str fails loudly (non-zero, JSON error).
#   5. large content (simulated big file) round-trips via the env/stdin path.
#   6. (#1204) trailing-whitespace drift matches via the normalized fallback.
#   7. (#1204) CRLF-vs-LF drift matches via the normalized fallback.
#   8. (#1204) genuinely absent old_str still loud-fails (no normalized match).
#   9. (#1204) ambiguous-under-normalization old_str still loud-fails.
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

# -----------------------------------------------------------------------------
# Case 6 (#1204): trailing-whitespace drift matches via the normalized fallback.
# The file's anchor line has no trailing whitespace; the LLM-returned old_str
# carries trailing spaces (flat-cyborg TUI line-wrap drift). Exact match fails
# (0 occurrences), but the whitespace-normalized fallback finds the unique span
# and edits the RIGHT line — leaving the surrounding lines verbatim.
# -----------------------------------------------------------------------------
IN6="$(printf 'alpha\nbeta gamma\ndelta\n')"
OUT="$(printf '%s' "$IN6" | APPLY_EDITS='[{"old_str":"beta gamma   ","new_str":"BETA GAMMA"}]' python3 "$APPLY" 2>/dev/null)"
RC=$?
EXP6="$(printf 'alpha\nBETA GAMMA\ndelta')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXP6" ]; then
    pass "trailing-whitespace drift matches via normalized fallback (#1204)"
else
    fail "trailing-ws drift" "rc=$RC out=$(printf '%q' "$OUT")"
fi

# -----------------------------------------------------------------------------
# Case 7 (#1204): CRLF-vs-LF drift matches via the normalized fallback. The file
# uses CRLF line endings; the returned old_str spans two lines with LF endings.
# Exact match fails; the normalized (CRLF->LF) fallback locates the unique span.
# -----------------------------------------------------------------------------
IN7="$(printf 'one\r\ntwo\r\nthree\r\n')"
OUT="$(printf '%s' "$IN7" | APPLY_EDITS='[{"old_str":"one\ntwo","new_str":"ONE\nTWO"}]' python3 "$APPLY" 2>/dev/null)"
RC=$?
# Expected: the matched two-line span is replaced by new_str (LF); the untouched
# tail line keeps its original CRLF.
EXP7="$(printf 'ONE\nTWO\r\nthree\r\n')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXP7" ]; then
    pass "CRLF-vs-LF drift matches via normalized fallback (#1204)"
else
    fail "CRLF/LF drift" "rc=$RC out=$(printf '%q' "$OUT") exp=$(printf '%q' "$EXP7")"
fi

# -----------------------------------------------------------------------------
# Case 8 (#1204): genuinely absent old_str still loud-fails. No exact match AND
# no normalized match -> non-zero exit, JSON error on stderr, NO stdout.
# -----------------------------------------------------------------------------
ERR_FILE="$(mktemp)"
OUT="$(printf 'alpha\nbeta\n' | APPLY_EDITS='[{"old_str":"totally absent line","new_str":"x"}]' python3 "$APPLY" 2>"$ERR_FILE")" && RC=0 || RC=$?
ERR="$(cat "$ERR_FILE")"; rm -f "$ERR_FILE"
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q '"error"'; then
    pass "genuinely absent old_str still loud-fails under normalization (#1204)"
else
    fail "absent under normalization" "rc=$RC out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
fi

# -----------------------------------------------------------------------------
# Case 9 (#1204): ambiguous-under-normalization old_str still loud-fails. Two
# file lines are identical except for trailing whitespace, so they collapse to
# the same normalized line: a normalized old_str matching that line resolves to
# >1 span -> loud failure, NO stdout. Uniqueness is the correctness guard.
# -----------------------------------------------------------------------------
ERR_FILE="$(mktemp)"
# Lines 1 and 3 both normalize to "dup line" (each carries a DIFFERENT amount of
# trailing whitespace: 1 space vs 2). The old_str "dup line   " (3 trailing
# spaces) is a substring of NEITHER line, so exact match is 0; under
# normalization it matches BOTH lines -> 2 spans -> loud failure, NO stdout.
IN9="$(printf 'dup line \nmiddle\ndup line  \n')"
OUT="$(printf '%s' "$IN9" | APPLY_EDITS='[{"old_str":"dup line   ","new_str":"X"}]' python3 "$APPLY" 2>"$ERR_FILE")" && RC=0 || RC=$?
ERR="$(cat "$ERR_FILE")"; rm -f "$ERR_FILE"
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q '"error"'; then
    pass "ambiguous-under-normalization old_str still loud-fails (#1204)"
else
    fail "ambiguous under normalization" "rc=$RC out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
