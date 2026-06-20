#!/bin/bash
# tools/test-apply-line-edits.sh (#1208): unit-test the deterministic
# line-numbered range applier tools/apply-line-edits.py.
#
# Background (#1208): code_writer's autonomous existing-file path used to ask
# the LLM for search/replace edits whose `old_str` had to reproduce the file's
# source BYTE-FOR-BYTE. On markdown that fails — the model drops `**` markdown
# from the anchor, so old_str never matches. The fix is line-NUMBERED range
# edits: the model names the line numbers to replace (a `N|`-prefixed view is
# shown in the prompt) and never reproduces exact source bytes. apply-line-
# edits.py splices the replacement text in deterministically.
#
# Contract under test:
#   - original content on stdin, edits JSON in $LINE_EDITS, new content on
#     stdout (large values ride a pipe / env var, never argv -> no ARG_MAX).
#   - edits = [{"start_line": int, "end_line": int, "new_text": str}], 1-based
#     inclusive; new_text may be multi-line or empty (deletion).
#   - validation: 1 <= start <= end <= nlines, NON-OVERLAPPING. Any failure ->
#     non-zero exit, JSON {"error": ...} on stderr, and NO stdout.
#   - edits apply DESCENDING by start_line so an earlier replacement never
#     shifts a later range's line numbers; lines outside ranges stay verbatim.
#
# Cases:
#   1. single in-range replace.
#   2. multiple in-range replaces (two disjoint single-line spans).
#   3. descending-apply offset correctness: a multi-line replace at an earlier
#      line must NOT shift the later edit's line numbers.
#   4. deletion (empty new_text) drops the span.
#   5. out-of-bounds start<1 loud-fails (non-zero, JSON error, no stdout).
#   6. out-of-bounds end>nlines loud-fails.
#   7. overlapping ranges loud-fail.
#   8. large (~50KB) content round-trips; one mid-file line edited, rest verbatim.
#   9. lines outside the edited range are byte-verbatim (terminators preserved).
#
# Auto-discovered by tools/colony-lint.sh's tools-test loop. Exit 0 if all pass.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLY="$SCRIPT_DIR/apply-line-edits.py"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] test-apply-line-edits.sh: python3 not on PATH"
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
# Case 1: single in-range replace.
# -----------------------------------------------------------------------------
OUT="$(printf 'one\ntwo\nthree\n' | LINE_EDITS='[{"start_line":2,"end_line":2,"new_text":"TWO"}]' python3 "$APPLY" 2>/dev/null)"
RC=$?
EXP1="$(printf 'one\nTWO\nthree')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXP1" ]; then
    pass "single in-range replace"
else
    fail "single in-range replace" "rc=$RC out=$(printf '%q' "$OUT")"
fi

# -----------------------------------------------------------------------------
# Case 2: multiple in-range replaces (two disjoint single-line spans).
# -----------------------------------------------------------------------------
OUT="$(printf 'a\nb\nc\nd\n' | LINE_EDITS='[{"start_line":1,"end_line":1,"new_text":"A"},{"start_line":3,"end_line":3,"new_text":"C"}]' python3 "$APPLY" 2>/dev/null)"
RC=$?
EXP2="$(printf 'A\nb\nC\nd')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXP2" ]; then
    pass "multiple in-range replaces apply correctly"
else
    fail "multiple replaces" "rc=$RC out=$(printf '%q' "$OUT")"
fi

# -----------------------------------------------------------------------------
# Case 3: descending-apply offset correctness. Replace line 1 with a THREE-line
# block AND replace line 3 with one line, in a single call. If edits applied
# ascending, growing line 1 would shift line 3's target; applying descending
# (line 3 first, then line 1) keeps both anchored to the ORIGINAL numbers.
# Original: a/b/c -> edit1 {1,1 -> "X\nY\nZ"}, edit2 {3,3 -> "C"}.
# Correct result: X/Y/Z/b/C  (NOT X/Y/Z/C/b or a shifted "c").
# -----------------------------------------------------------------------------
OUT="$(printf 'a\nb\nc\n' | LINE_EDITS='[{"start_line":1,"end_line":1,"new_text":"X\nY\nZ"},{"start_line":3,"end_line":3,"new_text":"C"}]' python3 "$APPLY" 2>/dev/null)"
RC=$?
EXP3="$(printf 'X\nY\nZ\nb\nC')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXP3" ]; then
    pass "descending-apply: earlier multi-line replace does not shift later edit's line numbers"
else
    fail "descending-apply offset" "rc=$RC out=$(printf '%q' "$OUT") exp=$(printf '%q' "$EXP3")"
fi

# -----------------------------------------------------------------------------
# Case 4: deletion (empty new_text) drops the span.
# -----------------------------------------------------------------------------
OUT="$(printf 'keep1\ndrop\nkeep2\n' | LINE_EDITS='[{"start_line":2,"end_line":2,"new_text":""}]' python3 "$APPLY" 2>/dev/null)"
RC=$?
EXP4="$(printf 'keep1\nkeep2')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXP4" ]; then
    pass "deletion (empty new_text) drops the span"
else
    fail "deletion" "rc=$RC out=$(printf '%q' "$OUT")"
fi

# -----------------------------------------------------------------------------
# Case 5: out-of-bounds start<1 loud-fails (non-zero, JSON error, NO stdout).
# -----------------------------------------------------------------------------
ERR_FILE="$(mktemp)"
OUT="$(printf 'one\ntwo\n' | LINE_EDITS='[{"start_line":0,"end_line":1,"new_text":"x"}]' python3 "$APPLY" 2>"$ERR_FILE")" && RC=0 || RC=$?
ERR="$(cat "$ERR_FILE")"; rm -f "$ERR_FILE"
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q '"error"'; then
    pass "out-of-bounds start<1 fails loudly (non-zero, JSON error, no stdout)"
else
    fail "start<1 out-of-bounds" "rc=$RC out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
fi

# -----------------------------------------------------------------------------
# Case 6: out-of-bounds end>nlines loud-fails.
# -----------------------------------------------------------------------------
ERR_FILE="$(mktemp)"
OUT="$(printf 'one\ntwo\n' | LINE_EDITS='[{"start_line":1,"end_line":5,"new_text":"x"}]' python3 "$APPLY" 2>"$ERR_FILE")" && RC=0 || RC=$?
ERR="$(cat "$ERR_FILE")"; rm -f "$ERR_FILE"
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q '"error"'; then
    pass "out-of-bounds end>nlines fails loudly (non-zero, JSON error, no stdout)"
else
    fail "end>nlines out-of-bounds" "rc=$RC out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
fi

# -----------------------------------------------------------------------------
# Case 7: overlapping ranges loud-fail (ambiguous -> never guess, NO stdout).
# Spans [1,2] and [2,3] share line 2.
# -----------------------------------------------------------------------------
ERR_FILE="$(mktemp)"
OUT="$(printf 'a\nb\nc\n' | LINE_EDITS='[{"start_line":1,"end_line":2,"new_text":"x"},{"start_line":2,"end_line":3,"new_text":"y"}]' python3 "$APPLY" 2>"$ERR_FILE")" && RC=0 || RC=$?
ERR="$(cat "$ERR_FILE")"; rm -f "$ERR_FILE"
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q '"error"'; then
    pass "overlapping ranges fail loudly (non-zero, JSON error, no stdout)"
else
    fail "overlapping ranges" "rc=$RC out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
fi

# -----------------------------------------------------------------------------
# Case 8: large content (~50KB) round-trips via env/stdin. Build 2000 unique
# lines, edit one mid-file line by NUMBER, confirm that line changed and every
# other line is preserved verbatim. Content rides a pipe (stdin); edits ride
# $LINE_EDITS — never argv.
# -----------------------------------------------------------------------------
BIG="$(python3 -c 'import sys; sys.stdout.write("".join("line %05d filler text here\n" % i for i in range(2000)))')"
# Edit line 1000 (1-based). Expected: that one line becomes EDITED_MARKER.
EXP8="$(python3 -c 'import sys
lines=["line %05d filler text here" % i for i in range(2000)]
lines[999]="EDITED_MARKER"
sys.stdout.write("\n".join(lines)+"\n")')"
OUT="$(printf '%s' "$BIG" | LINE_EDITS='[{"start_line":1000,"end_line":1000,"new_text":"EDITED_MARKER"}]' python3 "$APPLY" 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXP8" ]; then
    pass "large content round-trips via env/stdin (~50KB, line-1000 edit, rest preserved)"
else
    fail "large content" "rc=$RC bytes_in=$(printf '%s' "$BIG" | wc -c) bytes_out=$(printf '%s' "$OUT" | wc -c)"
fi

# -----------------------------------------------------------------------------
# Case 9: lines OUTSIDE the edited range are byte-verbatim, terminators and all.
# Use a mix of content + a no-final-newline last line; edit only the middle and
# confirm the head/tail bytes are untouched.
# -----------------------------------------------------------------------------
IN9="$(printf 'header line\nmiddle to change\nfooter line')"
OUT="$(printf '%s' "$IN9" | LINE_EDITS='[{"start_line":2,"end_line":2,"new_text":"CHANGED"}]' python3 "$APPLY" 2>/dev/null)"
RC=$?
EXP9="$(printf 'header line\nCHANGED\nfooter line')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXP9" ]; then
    pass "lines outside the edited range stay byte-verbatim (no-final-newline tail preserved)"
else
    fail "outside-range verbatim" "rc=$RC out=$(printf '%q' "$OUT") exp=$(printf '%q' "$EXP9")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
