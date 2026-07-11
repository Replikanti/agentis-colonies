#!/bin/bash
# tools/test-rate-limit-backoff.sh: simulated-429 backoff tests (#1115).
#
# Validates the forge-wrapper jittered exponential backoff and the colony-side
# rate-limited observability primitives.
#
#   Test 1: a forge call that hits 429 on every attempt retries exactly
#           GITLAB_CURL_RETRIES times then gives up with exit 3 (rate
#           limited) — i.e. it backs off and stops, NOT a retry storm.
#   Test 2: the jittered backoff delays GROW across attempts (exponential
#           floor preserved: each base delay doubles).
#   Test 3: each backoff delay lies within its jitter bound
#           [base, base + base/2] (equal-jitter, +50% upper bound).
#   Test 4: the .ag agents surface a rate-limited memo state
#           (`<agent>:rate_limited_until`) and emit a `<colony>:rate-limited`
#           event so the condition is observable and the task is NOT failed
#           during backoff.
#   Test 5: the .ag agents defer (do not mark failed) while the backoff
#           window is open — the rl_active() gate + rl_mark()/rl_clear()
#           helpers are wired into every autonomous forge-write path.
#
# The forge wrapper is exercised against a STUBBED curl that returns 429 on
# every attempt, with GITLAB_BACKOFF_DRYRUN=1 so the backoff sleeps are traced
# (one integer per line to $GITLAB_BACKOFF_TRACE) instead of really sleeping —
# the test runs in well under a second with no wall-clock waits.
#
# Tests 1-5 above cover the bash-level `_backoff_sleep()` HTTP-429 curl retry
# in gitlab-api.sh — a DIFFERENT mechanism from the native `.ag`
# `rl_backoff_secs()` colony-side forge-call backoff added in #1601 (issue
# #1602: this file never exercised the latter). The section below adds LIVE
# coverage for `rl_backoff_secs`, following the `agentis go` probe precedent
# in tools/test-approval-decider-review-gate.sh: awk-extract the REAL
# function body out of an agent, drive it with fixture counts via a scratch
# probe.ag, and assert the #1601 contract — the deterministic base formula,
# the exponent-clamp overflow-safety fix (#1597), the jitter band, and
# cross-agent byte-identity. Skips cleanly when `agentis` is not on PATH so
# CI runners (which have no binary) stay green.
#
# Usage: ./tools/test-rate-limit-backoff.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FAKE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FAKE_ROOT"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

GITLAB_API="$REPO_ROOT/dev-apprenticeship/triage/scripts/gitlab-api.sh"

# Stub curl: always report HTTP 429, write nothing to the -o body file. The
# real gl_call writes the status code to stdout via -w and the body via -o, so
# we mimic that: echo 429 on stdout, leave the body file empty.
FAKE_BIN="$FAKE_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
# Find the -o <file> arg and truncate it to empty (no body), then print 429.
out=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-o" ]; then
        out="$a"
    fi
    prev="$a"
done
if [ -n "$out" ]; then
    : > "$out"
fi
printf '429'
exit 0
EOF
chmod +x "$FAKE_BIN/curl"

TRACE="$FAKE_ROOT/backoff-trace"
: > "$TRACE"

# ----- Test 1: retries exactly N times then exits 3 (no storm) -----
RC=0
PATH="$FAKE_BIN:$PATH" \
GITLAB_URL="https://gitlab.example.com" \
GITLAB_TOKEN="stub" \
GITLAB_PROJECT="org%2Fproj" \
GITLAB_CURL_RETRIES=3 \
GITLAB_BACKOFF_DRYRUN=1 \
GITLAB_BACKOFF_TRACE="$TRACE" \
    "$GITLAB_API" issues >/dev/null 2>&1 || RC=$?

TRACE_COUNT=$(wc -l < "$TRACE" | tr -d ' ')
# Budget is attempts-after-first: 3 retries => 3 backoff sleeps, then give up.
if [ "$RC" = "3" ] && [ "$TRACE_COUNT" = "3" ]; then
    pass "429-on-every-attempt: backs off 3 times then exits 3 (no retry storm)"
else
    fail "expected rc=3 + 3 backoff sleeps, got rc=$RC sleeps=$TRACE_COUNT"
fi

# ----- Test 2 + 3: delays grow + lie within jitter bounds -----
# Base delays are 3, 6, 12 (delay starts at 3, doubled each retry). Jitter is
# equal-jitter: slept in [base, base + base/2]. So bounds are:
#   attempt 1: [3, 4]   (base 3, +50% floor'd => +1)
#   attempt 2: [6, 9]   (base 6, +50% => +3)
#   attempt 3: [12, 18] (base 12, +50% => +6)
D1=$(sed -n '1p' "$TRACE")
D2=$(sed -n '2p' "$TRACE")
D3=$(sed -n '3p' "$TRACE")

grow_ok=1
case "$D1$D2$D3" in
    ''|*[!0-9]*) grow_ok=0 ;;
esac
if [ "$grow_ok" = "1" ]; then
    if [ "$D2" -gt "$D1" ] && [ "$D3" -gt "$D2" ]; then
        pass "backoff delays grow across attempts ($D1 -> $D2 -> $D3)"
    else
        fail "backoff delays did not grow ($D1 -> $D2 -> $D3)"
    fi
else
    fail "backoff trace not numeric ('$D1' '$D2' '$D3')"
fi

bounds_ok=1
check_bound() {
    # $1 value, $2 lo, $3 hi, $4 label
    if [ "$1" -lt "$2" ] || [ "$1" -gt "$3" ]; then
        echo "  out-of-bound: $4 = $1 not in [$2, $3]"
        bounds_ok=0
    fi
}
if [ "$grow_ok" = "1" ]; then
    check_bound "$D1" 3 4 "attempt-1"
    check_bound "$D2" 6 9 "attempt-2"
    check_bound "$D3" 12 18 "attempt-3"
    if [ "$bounds_ok" = "1" ]; then
        pass "each backoff delay within jitter bound [base, base+base/2]"
    else
        fail "a backoff delay fell outside its jitter bound"
    fi
else
    fail "skipping jitter-bound check (non-numeric trace)"
fi

# ----- Test 4: .ag agents surface rate-limited memo + emit -----
RL_AGENTS=(
    "dev-apprenticeship/code-review/agents/approval_decider.ag"
    "dev-apprenticeship/planning/agents/risk_assessor.ag"
    "dev-apprenticeship/planning/agents/plan_reviewer.ag"
)
memo_ok=1
emit_ok=1
for rel in "${RL_AGENTS[@]}"; do
    f="$REPO_ROOT/$rel"
    if ! grep -q ':rate_limited_until' "$f"; then
        echo "  $rel missing :rate_limited_until memo"
        memo_ok=0
    fi
    if ! grep -Eq 'emit\("(code-review|planning):rate-limited"' "$f"; then
        echo "  $rel missing <colony>:rate-limited emit"
        emit_ok=0
    fi
done
if [ "$memo_ok" = "1" ]; then
    pass "agents write a <agent>:rate_limited_until memo state"
else
    fail "an agent is missing the rate_limited_until memo"
fi
if [ "$emit_ok" = "1" ]; then
    pass "agents emit a <colony>:rate-limited observable event"
else
    fail "an agent is missing the <colony>:rate-limited emit"
fi

# ----- Test 5: backoff gate wired (defer, not fail) -----
gate_ok=1
for rel in "${RL_AGENTS[@]}"; do
    f="$REPO_ROOT/$rel"
    if ! grep -q 'rl_active(' "$f"; then
        echo "  $rel missing rl_active() backoff gate"
        gate_ok=0
    fi
    if ! grep -q 'rl_mark(' "$f"; then
        echo "  $rel missing rl_mark() on rate-limited write"
        gate_ok=0
    fi
    if ! grep -q 'rl_clear(' "$f"; then
        echo "  $rel missing rl_clear() on successful write"
        gate_ok=0
    fi
done
if [ "$gate_ok" = "1" ]; then
    pass "rl_active gate + rl_mark/rl_clear wired into every agent (defer, not fail)"
else
    fail "an agent is missing the rate-limit gate/mark/clear wiring"
fi

# ----- Test 6: native rl_backoff_secs (#1601/#1602) -----
# Cross-agent byte-identity (checked unconditionally, no agentis needed): a
# drift in the shared helper body is the exact regression #1601 pins against
# (an md5sum-pinned contract per the CHANGELOG entry).
AD_RL="$(awk '/^fn rl_backoff_secs\(/{f=1} f{print} /^}/{if(f) f=0}' "$REPO_ROOT/dev-apprenticeship/code-review/agents/approval_decider.ag")"
PR_RL="$(awk '/^fn rl_backoff_secs\(/{f=1} f{print} /^}/{if(f) f=0}' "$REPO_ROOT/dev-apprenticeship/planning/agents/plan_reviewer.ag")"
RA_RL="$(awk '/^fn rl_backoff_secs\(/{f=1} f{print} /^}/{if(f) f=0}' "$REPO_ROOT/dev-apprenticeship/planning/agents/risk_assessor.ag")"
if [ -n "$AD_RL" ] && [ "$AD_RL" = "$PR_RL" ] && [ "$AD_RL" = "$RA_RL" ]; then
    pass "rl_backoff_secs is byte-identical across approval_decider/plan_reviewer/risk_assessor"
else
    fail "rl_backoff_secs body diverged across agents (a drift here silently desyncs their backoff behavior)"
fi

if command -v agentis >/dev/null 2>&1; then
    RL_TMP="$(mktemp -d)"
    {
        printf '%s\n' "$AD_RL"
        cat <<'AGEOF'
print("c1=", rl_backoff_secs(1));
print("c2=", rl_backoff_secs(2));
print("c3=", rl_backoff_secs(3));
print("c7=", rl_backoff_secs(7));
print("c8=", rl_backoff_secs(8));
print("c64=", rl_backoff_secs(64));
print("c100=", rl_backoff_secs(100));
AGEOF
    } > "$RL_TMP/probe.ag"
    (cd "$RL_TMP" && agentis init) >/dev/null 2>&1
    RL_RC=0
    RL_OUT="$( (cd "$RL_TMP" && agentis go probe.ag) 2>&1 )" || RL_RC=$?
    getv() { printf '%s\n' "$RL_OUT" | sed -n "s/^$1= \\([0-9]*\\)\$/\\1/p"; }

    # Expected jitter band per count, mirroring the .ag formula exactly:
    #   exp = min(max(0, count-1), 6)
    #   base = min(300, 5 * 2^exp)
    #   band = [base*3/4, base*5/4]  (integer truncation, as in the .ag body)
    # NB: the jitter band is NOT further clamped to 300 in the .ag body — at
    # the saturated base=300 the band is [225, 375], confirmed against a live
    # run (see PR description). Assertions below use this real band, not a
    # naive 300s ceiling.
    band_lo() {
        c="$1"
        e=$((c - 1)); [ "$e" -lt 0 ] && e=0; [ "$e" -gt 6 ] && e=6
        b=$((5 * (1 << e))); [ "$b" -gt 300 ] && b=300
        echo $((b * 3 / 4))
    }
    band_hi() {
        c="$1"
        e=$((c - 1)); [ "$e" -lt 0 ] && e=0; [ "$e" -gt 6 ] && e=6
        b=$((5 * (1 << e))); [ "$b" -gt 300 ] && b=300
        echo $((b * 5 / 4))
    }
    check_in_band() { # $1 value $2 count $3 label
        v="$1"; c="$2"; label="$3"
        lo=$(band_lo "$c"); hi=$(band_hi "$c")
        case "$v" in '' | *[!0-9]*) echo "  $label: non-numeric output '$v'"; return 1 ;; esac
        if [ "$v" -lt "$lo" ] || [ "$v" -gt "$hi" ]; then
            echo "  $label: count=$c value=$v not in band [$lo,$hi]"
            return 1
        fi
        return 0
    }

    if [ "$RL_RC" -eq 0 ]; then
        pass "live rl_backoff_secs probe ran cleanly (agentis go, no error)"
    else
        fail "live rl_backoff_secs probe" "agentis go exited $RL_RC: $RL_OUT"
    fi

    # Deterministic base formula per count: min(300, 5*2^(count-1)), asserted
    # via each output's jitter band (exact value is non-deterministic).
    formula_ok=1
    for c in 1 2 3 7 8; do
        v="$(getv "c$c")"
        check_in_band "$v" "$c" "count=$c" || formula_ok=0
    done
    if [ "$formula_ok" = "1" ]; then
        pass "base formula min(300, 5*2^(count-1)) holds per-count (jitter band [base*0.75, base*1.25])"
    else
        fail "base formula per-count band check failed (see above)"
    fi

    # Exponent clamp / count=100 overflow-safety (#1597 fix under test): an
    # unclamped pow_int(2, 99) would throw an uncaught EvalError. count=64 and
    # count=100 must both run clean (already implied by RL_RC above, since
    # they share the same probe.ag run) AND land in the SAME saturated band
    # as count=7/8 — proof the exponent is pinned at 6, not left to overflow.
    v64="$(getv c64)"; v100="$(getv c100)"
    sat_lo=$(band_lo 100); sat_hi=$(band_hi 100)
    clamp_ok=1
    check_in_band "$v64" 100 "count=64" || clamp_ok=0
    check_in_band "$v100" 100 "count=100" || clamp_ok=0
    if [ "$clamp_ok" = "1" ] && [ "$sat_lo" = "225" ] && [ "$sat_hi" = "375" ]; then
        pass "exponent clamp: count=64/100 ran without overflow, saturating to the same 300s-base band [225,375] as count=7/8"
    else
        fail "exponent clamp / overflow-safety" "count=64 -> $v64, count=100 -> $v100 must both land in [$sat_lo,$sat_hi]"
    fi

    # Jitter bounds across several independent calls: three separate agentis
    # go invocations (distinct now_ms() per process) driving the SAME count
    # must each land in-band — the entropy source varies the value but never
    # escapes the formula's window.
    jitter_ok=1
    jitter_vals=""
    j=0
    while [ "$j" -lt 3 ]; do
        printf 'print(rl_backoff_secs(7));\n' > "$RL_TMP/jprobe_body.ag"
        {
            printf '%s\n' "$AD_RL"
            cat "$RL_TMP/jprobe_body.ag"
        } > "$RL_TMP/jprobe.ag"
        JV="$( (cd "$RL_TMP" && agentis go jprobe.ag) 2>/dev/null | tr -d '[:space:]' )"
        jitter_vals="$jitter_vals $JV"
        case "$JV" in
            '' | *[!0-9]*) jitter_ok=0 ;;
            *)
                if [ "$JV" -lt 225 ] || [ "$JV" -gt 375 ]; then
                    jitter_ok=0
                fi
                ;;
        esac
        j=$((j + 1))
    done
    if [ "$jitter_ok" = "1" ]; then
        pass "jitter bounds: 3 independent calls at count=7 all land in [225,375] (values:$jitter_vals)"
    else
        fail "jitter bounds" "an independent call fell outside [225,375] (values:$jitter_vals)"
    fi

    rm -rf "$RL_TMP"
else
    echo "[SKIP] live rl_backoff_secs probe — agentis not on PATH"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
