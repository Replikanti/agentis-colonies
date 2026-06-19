#!/bin/bash
# tools/test-flat-cyborg-claude.sh (#1163): unit-test the JSON-shaped-reply
# UNWRAP LOGIC only. We do NOT invoke flat-cyborg or claude (they need the
# binary + a logged-in ~/.claude). Instead we exercise the SAME filter the live
# wrapper pipes its reply through — tools/flat-cyborg-unwrap.py — so the wrapper
# and this test can never drift apart.
#
# Background (#1163): on the flat-rate flat-cyborg path, claude's
# --extract-structural screen-scrape LINE-WRAPS long TUI output, injecting
# newline+indent INSIDE a JSON string, so the strategist's Decision JSON failed
# to parse. The wrapper now collapses soft-wrap whitespace, but ONLY for replies
# that look like a single JSON object — prose/code replies from other federations
# must pass through byte-for-byte.
#
# Cases:
#   1. A JSON object with an embedded `\n  ` soft-wrap collapses to one line and
#      stays valid JSON (parseable, fields intact).
#   2. A JSON object already on one line is returned unchanged-but-valid.
#   3. A multi-line prose reply (not `{…}`-shaped) passes through byte-for-byte.
#
# Auto-discovered by tools/colony-lint.sh's tools-test loop. Exit 0 if all pass.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNWRAP="$SCRIPT_DIR/flat-cyborg-unwrap.py"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] test-flat-cyborg-claude.sh: python3 not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi
if [ ! -f "$UNWRAP" ]; then
    fail "missing filter: $UNWRAP"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Run the real unwrap filter on stdin given as $1. Output captured verbatim.
unwrap() {
    printf '%s' "$1" | python3 "$UNWRAP"
}

# --- Test 1: JSON object with embedded soft-wrap collapses to one valid line --
# The TUI folded the `rationale` value across two screen rows, injecting a
# newline + two-space indent inside the string. The filter must collapse it.
WRAPPED_JSON='{"action":"LONG","size":0.5,"rationale":"price bounced from VAL with
  rising volume on the retest","setup":"volume_profile"}'
OUT1="$(unwrap "$WRAPPED_JSON")"
# (a) result is a single line.
LINES1="$(printf '%s' "$OUT1" | wc -l | tr -d ' ')"
# (b) result parses as JSON and the fields survive intact.
if [ "$LINES1" = "0" ] && printf '%s' "$OUT1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["action"] == "LONG", d.get("action")
assert d["size"] == 0.5, d.get("size")
assert d["setup"] == "volume_profile", d.get("setup")
# the soft-wrap newline+indent collapsed to a single space inside the string.
assert d["rationale"] == "price bounced from VAL with rising volume on the retest", repr(d["rationale"])
' >/dev/null 2>&1; then
    pass "test 1: embedded soft-wrap JSON collapses to one valid line, fields intact"
else
    fail "test 1: embedded soft-wrap JSON collapses to one valid line, fields intact" \
         "out=[$OUT1] lines=$LINES1"
fi

# --- Test 2: single-line JSON returned unchanged-but-valid -------------------
ONELINE_JSON='{"action":"FLAT","size":0.0,"rationale":"mid range","setup":"volume_profile"}'
OUT2="$(unwrap "$ONELINE_JSON")"
if [ "$OUT2" = "$ONELINE_JSON" ] && printf '%s' "$OUT2" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["action"] == "FLAT", d.get("action")
assert d["size"] == 0.0, d.get("size")
' >/dev/null 2>&1; then
    pass "test 2: already-one-line JSON returned unchanged and still valid"
else
    fail "test 2: already-one-line JSON returned unchanged and still valid" \
         "out=[$OUT2]"
fi

# --- Test 3: multi-line prose passes through byte-for-byte -------------------
# A reply that is not `{…}`-shaped (prose / markdown / explanation from another
# federation) must be returned exactly as received — newlines preserved.
PROSE="Here is my analysis:

- The market is ranging.
- I would wait for a breakout.

No trade right now."
OUT3="$(unwrap "$PROSE")"
if [ "$OUT3" = "$PROSE" ]; then
    pass "test 3: multi-line prose passes through byte-for-byte (no JSON unwrap)"
else
    fail "test 3: multi-line prose passes through byte-for-byte (no JSON unwrap)" \
         "out=[$OUT3]"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
