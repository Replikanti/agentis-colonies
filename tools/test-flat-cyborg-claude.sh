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
# Descendant reaping (#1367): a live process-group-kill test would need real
# flat-cyborg + claude, so instead we statically assert the wrapper (a) parses
# clean and (b) its EXIT trap performs a process-group KILL of the flat-cyborg
# invocation. The two source-greps pin the mechanism: `set -m` (own pgroup) and
# a `kill -KILL -- "-$FC_PGID"` (negative-pgid group signal) in the trap.
# ===========================================================================
if [ ! -f "$WRAPPER" ]; then
    fail "missing wrapper for reaping checks: $WRAPPER"
else
    if bash -n "$WRAPPER" 2>/dev/null && sh -n "$WRAPPER" 2>/dev/null; then
        pass "test 8: wrapper parses clean under bash -n and sh -n"
    else
        fail "test 8: wrapper parses clean (bash -n / sh -n)"
    fi
    # shellcheck disable=SC2016  # Matching the literal wrapper source ($FC_PGID is intentional, not expanded here).
    if grep -q 'set -m' "$WRAPPER" && grep -q 'kill -KILL -- "-\$FC_PGID"' "$WRAPPER"; then
        pass "test 9: EXIT trap reaps the flat-cyborg process group (set -m + kill -KILL -PGID)"
    else
        fail "test 9: EXIT trap performs a process-group kill" \
             "missing 'set -m' or 'kill -KILL -- \"-\$FC_PGID\"'"
    fi

    # --- test 10: FUNCTIONAL reap + clean-stdout (#1367) ----------------------
    # The static greps above pin the MECHANISM; this drives the REAL wrapper with
    # a stub `flat-cyborg` that (a) writes a valid result-file reply and (b)
    # spawns a TRACKED grandchild that outlives flat-cyborg. We assert two
    # safety-critical properties the live overheating fix depends on:
    #   (1) stdout is EXACTLY the reply — no `set -m` job-control noise
    #       (`[1]`/`Done`/`Killed`) leaks into the channel the agentis caller
    #       parses (a single leaked line corrupts every prompt() reply);
    #   (2) when the shell HAS job control (`set -m` took), the leaked grandchild
    #       is SIGKILLed by the EXIT trap. Where job control is unavailable
    #       (non-interactive dash / no controlling tty), `set -m` is a no-op and
    #       the reap cannot fire — we skip the kill assertion there rather than
    #       fail, since the stdout-cleanliness property (1) still holds and is
    #       the one that protects the reply channel.
    REAP_STUB_DIR="$(mktemp -d)"
    GC_PIDFILE="$(mktemp)"
    cat > "$REAP_STUB_DIR/flat-cyborg" <<REAP_STUB_EOF
#!/usr/bin/env bash
set -eu
CMDFILE=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --cmd-file) CMDFILE="\$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
RESULT_FILE="\$(grep -F 'file-writing tool:' "\$CMDFILE" 2>/dev/null | sed 's/.*file-writing tool: //' | head -1)"
printf '%s' '{"reply":"clean","n":1}' > "\$RESULT_FILE"
# A grandchild that outlives flat-cyborg — the leak the reap must clean up.
( sleep 30 ) &
echo "\$!" > "$GC_PIDFILE"
exit 0
REAP_STUB_EOF
    chmod +x "$REAP_STUB_DIR/flat-cyborg"

    REAP_OUT="$(PATH="$REAP_STUB_DIR:$PATH" sh "$WRAPPER" "draft. return JSON." 2>/dev/null)"
    if [ "$REAP_OUT" = '{"reply":"clean","n":1}' ]; then
        pass "test 10a: wrapper stdout is exactly the reply (no set -m job-control noise leaks)"
    else
        fail "test 10a: stdout clean under the reap path" "out=[$REAP_OUT]"
    fi

    GC_PID="$(cat "$GC_PIDFILE" 2>/dev/null || echo '')"
    # Was job control actually available in this shell? (No controlling tty /
    # non-interactive dash turns `set -m` into a no-op — reaping cannot fire.)
    if ( set -m ) 2>/dev/null && [ -n "$GC_PID" ]; then
        # Give the EXIT trap a beat; then the grandchild must be gone.
        sleep 0.5
        if kill -0 "$GC_PID" 2>/dev/null; then
            fail "test 10b: EXIT trap SIGKILLs the leaked grandchild" "grandchild $GC_PID still alive"
            kill -KILL "$GC_PID" 2>/dev/null || true
        else
            pass "test 10b: EXIT trap reaped the leaked grandchild (process group SIGKILLed)"
        fi
    else
        pass "test 10b: [SKIP] job control unavailable in this shell — reap is a no-op (stdout still clean)"
        if [ -n "$GC_PID" ]; then kill -KILL "$GC_PID" 2>/dev/null || true; fi
    fi
    rm -rf "$REAP_STUB_DIR" "$GC_PIDFILE"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
