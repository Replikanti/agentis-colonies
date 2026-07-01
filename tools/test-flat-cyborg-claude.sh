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
#   16-18 (#1369). The plain-prompt DESCENDANT REAP: the wrapper parses clean
#      (16), source-pins the tty-independent /proc PPid-chain walk and asserts no
#      `set -m` job control (17), and — with a stub flat-cyborg that detaches a
#      grandchild into its OWN session via setsid — FUNCTIONALLY reaps it on
#      SIGTERM teardown, including a no-controlling-tty sub-case via `setsid -w`
#      (18). These invoke the wrapper against a STUB flat-cyborg; they still never
#      invoke the real flat-cyborg / claude binaries.
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

# ===========================================================================
# Descendant reap (#1369). The plain-prompt wrapper backgrounds
# `flat-cyborg … -- claude` and, on EXIT or a trapped signal (the daemon tearing
# a wedged wrapper down), SIGKILLs the whole transitive /proc parent-PID-chain
# closure rooted at the flat-cyborg child PID. This SUPERSEDES the retired #1367
# (B4) `set -m` process-group reap, which (a) no-ops without a controlling tty —
# true on the CI runner AND in the agentis daemon, the exact production context —
# and (b) could not cross flat-cyborg's own PTY session boundary anyway. The /proc
# PPid walk is tty-independent and crosses group/session boundaries, so it fires
# where `set -m` could not. Mirrors the cwd-match reap on the edit-job path
# (code-edit-in-checkout.sh:reap_editing_strays, #1248/#1249).
# ===========================================================================

# --- Test 16: the wrapper parses clean under both sh -n and bash -n ----------
if [ ! -f "$WRAPPER" ]; then
    fail "test 16: missing wrapper: $WRAPPER"
elif sh -n "$WRAPPER" 2>/dev/null && bash -n "$WRAPPER" 2>/dev/null; then
    pass "test 16: wrapper parses clean under both sh -n and bash -n"
else
    fail "test 16: wrapper parses clean under both sh -n and bash -n"
fi

# --- Test 17: source pins the tty-independent /proc walk, not set -m ----------
# The reap must be the PPid-chain walk keyed on the backgrounded flat-cyborg PID
# (`FC_PID=$!`), driven from the EXIT/signal cleanup, killing the closure with
# SIGKILL — and must NOT (re)introduce `set -m` job control (a no-op without a
# controlling terminal, which is why #1367's attempt failed on CI and in the
# daemon).
if [ -f "$WRAPPER" ] \
   && grep -q 'reap_fc_descendants' "$WRAPPER" \
   && grep -qF 'FC_PID=$!' "$WRAPPER" \
   && grep -Eq '/proc/\[0-9\]\*/status' "$WRAPPER" \
   && grep -q 'kill -KILL' "$WRAPPER" \
   && ! grep -Eq '^[[:space:]]*set -m([^[:alnum:]_]|$)' "$WRAPPER"; then
    pass "test 17: reap uses the tty-independent /proc PPid-chain walk, no set -m"
else
    fail "test 17: reap uses the tty-independent /proc PPid-chain walk, no set -m"
fi

# --- Test 18: FUNCTIONAL reap — SIGTERM teardown SIGKILLs a setsid-detached
# grandchild, unconditionally (no job-control-availability skip: the /proc walk
# does not depend on job control), incl. a no-controlling-tty `setsid -w` case. --
# Needs setsid (to reproduce the PTY-session escape) + /proc (the walk's substrate
# — and the wrapper's reap itself is a documented no-op without /proc, e.g. macOS).
if [ ! -f "$WRAPPER" ]; then
    fail "test 18: missing wrapper: $WRAPPER"
elif ! command -v setsid >/dev/null 2>&1 || [ ! -d /proc ]; then
    echo "[SKIP] test 18: functional reap needs setsid + /proc (not both present)"
else
    # first pid whose PPid == $1 (pure /proc; no pgrep dependency).
    child_of() {
        for _st in /proc/[0-9]*/status; do
            [ -r "$_st" ] || continue
            _pp="$(awk '/^PPid:/{print $2; exit}' "$_st" 2>/dev/null || true)"
            if [ "$_pp" = "$1" ]; then
                _p="${_st#/proc/}"; printf '%s' "${_p%/status}"; return 0
            fi
        done
        return 1
    }
    # a pid is "dead" when it no longer exists OR is a reaped/zombie entry.
    pid_dead() {
        kill -0 "$1" 2>/dev/null || return 0
        _s="$(awk '/^State:/{print $2; exit}' "/proc/$1/status" 2>/dev/null || true)"
        [ "$_s" = "Z" ]
    }
    # poll up to ~8s for a non-empty pidfile to appear.
    wait_for_pidfile() {
        _i=0
        while [ "$_i" -lt 80 ]; do
            [ -s "$1" ] && return 0
            sleep 0.1; _i=$((_i + 1))
        done
        return 1
    }
    # poll up to ~5s for a pid to become dead.
    wait_dead() {
        _i=0
        while [ "$_i" -lt 50 ]; do
            pid_dead "$1" && return 0
            sleep 0.1; _i=$((_i + 1))
        done
        return 1
    }

    REAP_STUB_DIR="$(mktemp -d)"
    # Stub flat-cyborg: spawn a "claude" grandchild that detaches into its OWN
    # session (setsid) — the PTY-session escape a PGID group-kill can't reach —
    # yet stays a PPid descendant of THIS stub (the wrapper's FC_PID); record its
    # pid, then BLOCK so the stub stays alive for the reap to walk into. (A stub
    # that exited would reparent the grandchild to init and defeat the point.)
    cat > "$REAP_STUB_DIR/flat-cyborg" <<'RSTUB_EOF'
#!/usr/bin/env bash
set -eu
GC_PIDFILE="${REAP_GC_PIDFILE:?reap stub needs REAP_GC_PIDFILE}"
python3 - "$GC_PIDFILE" <<'PY' &
import os, sys, time
pidfile = sys.argv[1]
pid = os.fork()
if pid == 0:
    os.setsid()                       # new session — the PTY-session escape
    with open(pidfile, "w") as fh:
        fh.write(str(os.getpid()))
    time.sleep(600)                   # long-lived leaked descendant
else:
    os.waitpid(pid, 0)                # stay alive as the grandchild's parent
PY
wait
RSTUB_EOF
    chmod +x "$REAP_STUB_DIR/flat-cyborg"

    # --- Test 18a: plain background invocation, torn down with SIGTERM ---------
    set +e
    GC_A="$REAP_STUB_DIR/gc_a.pid"; rm -f "$GC_A"
    PATH="$REAP_STUB_DIR:$PATH" REAP_GC_PIDFILE="$GC_A" \
        sh "$WRAPPER" "reap probe A" >/dev/null 2>&1 &
    WRAP_A=$!
    if wait_for_pidfile "$GC_A"; then
        GCPID_A="$(cat "$GC_A" 2>/dev/null)"
        kill -TERM "$WRAP_A" 2>/dev/null     # daemon-style teardown of a live wrapper
        wait "$WRAP_A" 2>/dev/null
        if [ -n "$GCPID_A" ] && wait_dead "$GCPID_A"; then
            pass "test 18a: SIGTERM teardown SIGKILLs the setsid-detached grandchild"
        else
            fail "test 18a: grandchild survived the reap" "gc=$GCPID_A"
        fi
        [ -n "$GCPID_A" ] && kill -KILL "$GCPID_A" 2>/dev/null   # cleanup on failure
    else
        kill -KILL "$WRAP_A" 2>/dev/null
        fail "test 18a: grandchild never registered (stub did not start?)"
    fi
    set -e

    # --- Test 18b: NO controlling tty (setsid -w) — the daemon's real context --
    # `set -m` reaps no-op here; the /proc walk must still fire. Run the whole
    # wrapper in a fresh session with no controlling terminal, tear it down mid-run.
    set +e
    GC_B="$REAP_STUB_DIR/gc_b.pid"; rm -f "$GC_B"
    PATH="$REAP_STUB_DIR:$PATH" REAP_GC_PIDFILE="$GC_B" \
        setsid -w sh "$WRAPPER" "reap probe B" >/dev/null 2>&1 &
    SETSID_B=$!
    if wait_for_pidfile "$GC_B"; then
        GCPID_B="$(cat "$GC_B" 2>/dev/null)"
        # setsid(1) without --fork EXECs the wrapper in place (a backgrounded subshell
        # is not a process-group leader, so setsid() succeeds without forking) — then
        # $SETSID_B IS the wrapper. Only when it forks is the wrapper $SETSID_B's child.
        # Resolve both cases: otherwise child_of returns the flat-cyborg stub (FC_PID)
        # and we SIGTERM *that*, orphaning the grandchild to init before the wrapper's
        # own reap runs — a teardown-target bug that masquerades as a reap failure.
        if tr '\0' ' ' < "/proc/$SETSID_B/cmdline" 2>/dev/null | grep -Fq "$WRAPPER"; then
            WRAP_B="$SETSID_B"                          # setsid exec'd the wrapper in place
        else
            WRAP_B="$(child_of "$SETSID_B" 2>/dev/null)"   # setsid forked; wrapper is its child
        fi
        [ -n "$WRAP_B" ] && kill -TERM "$WRAP_B" 2>/dev/null
        wait "$SETSID_B" 2>/dev/null
        if [ -n "$GCPID_B" ] && wait_dead "$GCPID_B"; then
            pass "test 18b: no-tty (setsid -w) teardown still reaps the grandchild"
        else
            fail "test 18b: grandchild survived the no-tty reap" "gc=$GCPID_B wrap=$WRAP_B"
        fi
        [ -n "$GCPID_B" ] && kill -KILL "$GCPID_B" 2>/dev/null   # cleanup on failure
    else
        kill -KILL "$SETSID_B" 2>/dev/null
        fail "test 18b: grandchild never registered under setsid -w"
    fi
    set -e

    rm -rf "$REAP_STUB_DIR"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
