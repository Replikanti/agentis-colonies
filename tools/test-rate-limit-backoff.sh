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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
