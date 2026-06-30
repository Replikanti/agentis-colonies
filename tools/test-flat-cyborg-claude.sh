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
#   4-7. WRAPPER channel-selection logic against a stub flat-cyborg.
#   8-15 (#1340). The prose/fence/sentinel-wrapped unwrap path: a clean object,
#      an `FCB_<hex>_BEGIN` screen-scrape sentinel prefix, a ```json fence, a
#      no-language fence, a short prose trailer, a pure-prose passthrough, a
#      long-prose-with-tiny-json passthrough (margin guard), and a soft-wrap.
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

# ===========================================================================
# RESULT-FILE channel (#1219): exercise the WRAPPER's channel-selection logic
# with a STUB `flat-cyborg` on PATH (no real flat-cyborg / claude needed). The
# stub parses the --cmd-file prompt for the RESULT_FILE path the wrapper told
# claude to write to, then — per FCSTUB_MODE — writes the result file and/or the
# screen reply and exits with FCSTUB_RC. We assert the wrapper:
#   1. prefers the result-file reply when claude wrote it (exit 0),
#   2. falls back to the screen-scrape reply when the file is empty,
#   3. honours a non-empty result file even on a flat-cyborg non-zero exit,
#   4. propagates the flat-cyborg exit code when nothing was produced.
# ===========================================================================
WRAPPER="$SCRIPT_DIR/flat-cyborg-claude.sh"
if [ ! -f "$WRAPPER" ]; then
    fail "missing wrapper: $WRAPPER"
else
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/flat-cyborg" <<'STUB_EOF'
#!/usr/bin/env bash
set -eu
CMDFILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cmd-file) CMDFILE="$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
# Recover the path the wrapper asked claude to write its reply to.
RESULT_FILE="$(grep -F 'file-writing tool:' "$CMDFILE" 2>/dev/null | sed 's/.*file-writing tool: //' | head -1)"
case "${FCSTUB_MODE:-file}" in
    file)        printf '%s' "$FCSTUB_FILE_REPLY"   > "$RESULT_FILE" ;;
    screen-only) printf '%s\n' "$FCSTUB_SCREEN_REPLY" ;;            # screen (stdout) only, no file
    file-and-rc) printf '%s' "$FCSTUB_FILE_REPLY"   > "$RESULT_FILE" ;;
    none)        : ;;                                               # neither file nor screen
esac
exit "${FCSTUB_RC:-0}"
STUB_EOF
    chmod +x "$STUB_DIR/flat-cyborg"

    run_wrapper() {  # $1=mode $2=rc ; reads FCSTUB_FILE_REPLY/FCSTUB_SCREEN_REPLY from env
        PATH="$STUB_DIR:$PATH" FCSTUB_MODE="$1" FCSTUB_RC="$2" \
            sh "$WRAPPER" "draft something. Return ONLY the raw JSON object."
    }

    # 1. result file written -> wrapper returns the file reply (exit 0)
    FILE_JSON='{"action":"LONG","size":0.5,"setup":"file_channel"}'
    OUTW="$(FCSTUB_FILE_REPLY="$FILE_JSON" run_wrapper file 0 2>/dev/null)"; RCW=$?
    if [ "$RCW" -eq 0 ] && printf '%s' "$OUTW" | python3 -c '
import json,sys
d=json.load(sys.stdin); assert d["setup"]=="file_channel", d
' >/dev/null 2>&1; then
        pass "test 4: wrapper returns the result-file reply when claude wrote it"
    else
        fail "test 4: result-file reply preferred" "rc=$RCW out=[$OUTW]"
    fi

    # 2. no file written, screen has the reply -> fallback to screen-scrape
    OUTW="$(FCSTUB_SCREEN_REPLY='{"action":"FLAT","setup":"screen_fallback"}' run_wrapper screen-only 0 2>/dev/null)"; RCW=$?
    if [ "$RCW" -eq 0 ] && printf '%s' "$OUTW" | python3 -c '
import json,sys
d=json.load(sys.stdin); assert d["setup"]=="screen_fallback", d
' >/dev/null 2>&1; then
        pass "test 5: wrapper falls back to the screen reply when no result file"
    else
        fail "test 5: screen-scrape fallback" "rc=$RCW out=[$OUTW]"
    fi

    # 3. flat-cyborg exits non-zero BUT the result file was written -> use it, exit 0
    OUTW="$(FCSTUB_FILE_REPLY='{"setup":"file_despite_timeout"}' run_wrapper file-and-rc 124 2>/dev/null)"; RCW=$?
    if [ "$RCW" -eq 0 ] && printf '%s' "$OUTW" | python3 -c '
import json,sys
d=json.load(sys.stdin); assert d["setup"]=="file_despite_timeout", d
' >/dev/null 2>&1; then
        pass "test 6: non-empty result file honoured even on flat-cyborg non-zero exit"
    else
        fail "test 6: result file beats a non-zero exit" "rc=$RCW out=[$OUTW]"
    fi

    # 4. nothing produced + non-zero exit -> propagate the flat-cyborg exit code
    set +e
    OUTW="$(run_wrapper none 17 2>/dev/null)"; RCW=$?
    set -e
    if [ "$RCW" -eq 17 ]; then
        pass "test 7: flat-cyborg exit code propagates when no reply is produced"
    else
        fail "test 7: propagate exit on empty reply" "rc=$RCW (expected 17) out=[$OUTW]"
    fi

    rm -rf "$STUB_DIR"
fi

# ===========================================================================
# Prose / fence / sentinel-wrapped JSON unwrap (#1340). Heavier prompts (notably
# implementation/code_writer's code-draft) reliably hit flat-cyborg's --extract
# screen-scrape fallback, which leaks an `FCB_<hex>_BEGIN` sentinel into stdout,
# or the interactive session answers conversationally with a fenced/prose-wrapped
# object. The trimmed reply then no longer starts with `{`, so unwrap used to
# pass it through unchanged and the typed `prompt(...) -> Schema` decode failed
# every tick. The unwrap filter now extracts the JSON span — but ONLY when it
# actually parses AND the surrounding prose is short (<=160 chars), so genuine
# prose and long-form replies still pass through byte-for-byte.
# ===========================================================================

# Assert: unwrap($1) parses as JSON and its `setup` field == $2.
assert_setup() {  # $1=input $2=expected_setup $3=test_label
    local _out
    _out="$(unwrap "$1")"
    if printf '%s' "$_out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["setup"] == sys.argv[1], (d.get("setup"), sys.argv[1])
' "$2" >/dev/null 2>&1; then
        pass "$3"
    else
        fail "$3" "out=[$_out]"
    fi
}

# Assert: unwrap($1) is returned byte-for-byte unchanged (prose passthrough).
assert_passthrough() {  # $1=input $2=test_label
    local _out
    _out="$(unwrap "$1")"
    if [ "$_out" = "$1" ]; then
        pass "$2"
    else
        fail "$2" "out=[$_out]"
    fi
}

# --- Test 8: a clean single-line JSON object survives the fast path ----------
assert_setup '{"count":1,"patterns":"abc","setup":"clean_fast_path"}' \
    "clean_fast_path" \
    "test 8: clean single-line JSON returned valid via the fast path"

# --- Test 9: FCB_<hex>_BEGIN screen-scrape sentinel prefix is stripped -------
SENTINEL_JSON='FCB_e67818bbb8163396b060_BEGIN
{"count": 1, "patterns": "x", "setup": "sentinel_strip"}'
assert_setup "$SENTINEL_JSON" \
    "sentinel_strip" \
    "test 9: FCB_<hex>_BEGIN sentinel-prefixed JSON is unwrapped and valid"

# --- Test 10: ```json fenced object is unwrapped -----------------------------
FENCED_JSON='```json
{"count": 2, "setup": "fenced_lang"}
```'
assert_setup "$FENCED_JSON" \
    "fenced_lang" \
    "test 10: json-language-fenced JSON is unwrapped and valid"

# --- Test 11: a no-language ``` fence is unwrapped ---------------------------
FENCE_NOLANG='```
{"count": 3, "setup": "fence_no_lang"}
```'
assert_setup "$FENCE_NOLANG" \
    "fence_no_lang" \
    "test 11: no-language-fenced JSON is unwrapped and valid"

# --- Test 12: a short prose trailer after the object is stripped -------------
TRAILER_JSON='{"count": 4, "setup": "trailer_prose"}

Let me know if you need anything else.'
assert_setup "$TRAILER_JSON" \
    "trailer_prose" \
    "test 12: short prose trailer after JSON is stripped, object stays valid"

# --- Test 13: a pure-prose reply passes through byte-for-byte ----------------
assert_passthrough 'I considered the request but there is nothing to draft here.' \
    "test 13: pure-prose reply (no JSON) passes through byte-for-byte"

# --- Test 14: long prose merely CONTAINING a tiny JSON object passes through -
# The margin guard (<=160 chars of surrounding prose) must keep a genuine
# long-form analysis that happens to contain a `{...}` from being mis-extracted.
LONG_PROSE_JSON='After reviewing the issue in depth across the affected modules, the call sites, and the surrounding documentation, I concluded that the safest course of action is to defer and document the rationale clearly. {"note":"tiny"} That summary above captures the reasoning.'
assert_passthrough "$LONG_PROSE_JSON" \
    "test 14: long prose containing a tiny JSON object passes through (margin guard)"

# --- Test 15: an embedded soft-wrap inside prose-free JSON collapses ----------
SOFTWRAP_JSON='{"count": 5, "patterns": "price bounced from VAL with
  rising volume on the retest", "setup": "soft_wrap_batch"}'
OUT15="$(unwrap "$SOFTWRAP_JSON")"
LINES15="$(printf '%s' "$OUT15" | wc -l | tr -d ' ')"
if [ "$LINES15" = "0" ] && printf '%s' "$OUT15" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["setup"] == "soft_wrap_batch", d.get("setup")
assert d["patterns"] == "price bounced from VAL with rising volume on the retest", repr(d["patterns"])
' >/dev/null 2>&1; then
    pass "test 15: embedded soft-wrap JSON collapses to one valid line, fields intact"
else
    fail "test 15: embedded soft-wrap JSON collapses to one valid line, fields intact" \
         "out=[$OUT15] lines=$LINES15"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
