#!/usr/bin/env bash
# research-foundry/tools/test-verifier-sanity-gates.sh -- regression test
# for the issue #776 wave-1 Lagrange-class mechanical sanity gates in
# `research-foundry/verifier/agents/verifier.ag`.
#
# The gates run BEFORE the LLM `prompt()` call in the verifier tick body.
# A claim that mechanically falsifies (e.g. a numeric stated_answer that
# does not divide the cited group's order, by Lagrange's theorem)
# short-circuits to `verdict.verdict = "FALSIFIED_LAGRANGE"` without
# burning a verifier round-trip; LLM-overridable cases (non-numeric
# answers, no recognised group cited) fall through to `prompt()`.
#
# This test exercises the python detector logic in lockstep with the
# version embedded in `verifier.ag`'s `_lagrange_check_symmetric` and
# `_lagrange_check_cyclic_dihedral` helpers. Since `prompt()` is not
# mockable from the test harness, the detector is invoked standalone
# here (same regex + math.factorial divisibility check as the .ag copy)
# and we grep-assert that `verifier.ag` carries the matching helper fn
# names + regex literals to catch drift.
#
# Standard library only -- no pytest, no live federation.
#
# Usage: bash research-foundry/tools/test-verifier-sanity-gates.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"
VERIFIER_AG="$FED_DIR/verifier/agents/verifier.ag"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

# Standalone detector script -- byte-for-byte the same regex + math.factorial
# divisibility logic as the python invocation embedded in verifier.ag's
# `_lagrange_check_symmetric` / `_lagrange_check_cyclic_dihedral`.
run_detector() {
    local problem="$1"
    local stated_answer="$2"
    python3 - "$problem" "$stated_answer" <<'PYEOF'
import sys,re,math
problem=sys.argv[1]
ans_raw=sys.argv[2]

# Symmetric group detector: S_n or "symmetric group on n"
m=re.search(r"\bS_(\d+)\b",problem)
if not m:
    m=re.search(r"\bsymmetric group\b[^\d]{0,40}(\d+)",problem,re.IGNORECASE)
if m:
    try:
        n=int(m.group(1))
    except Exception:
        n=0
    if 0<n<=20:
        ans_s=ans_raw.strip()
        if re.fullmatch(r"-?\d+",ans_s):
            try:
                ans=int(ans_s)
            except Exception:
                ans=0
            if ans>0:
                order=math.factorial(n)
                if order%ans!=0:
                    sys.stdout.write("FALSIFIED_LAGRANGE")
                    sys.exit(0)

# Cyclic / dihedral: C_n, Z/nZ, D_n  (|D_n| = 2n)
order=None
m=re.search(r"\bC_(\d+)\b",problem)
if m:
    try: order=int(m.group(1))
    except Exception: order=None
if order is None:
    m=re.search(r"\bZ/(\d+)Z\b",problem)
    if m:
        try: order=int(m.group(1))
        except Exception: order=None
if order is None:
    m=re.search(r"\bD_(\d+)\b",problem)
    if m:
        try: order=2*int(m.group(1))
        except Exception: order=None
if order is not None and 0<order<=10000:
    ans_s=ans_raw.strip()
    if re.fullmatch(r"-?\d+",ans_s):
        try:
            ans=int(ans_s)
        except Exception:
            ans=0
        if ans>0 and order%ans!=0:
            sys.stdout.write("FALSIFIED_LAGRANGE")
            sys.exit(0)
PYEOF
}

assert_falsified() {
    local label="$1"
    local problem="$2"
    local ans="$3"
    local got
    got="$(run_detector "$problem" "$ans")"
    if [ "$got" = "FALSIFIED_LAGRANGE" ]; then
        pass "trip Lagrange: $label"
    else
        fail "trip Lagrange: $label" "expected FALSIFIED_LAGRANGE, got '$got'"
    fi
}

assert_pass_through() {
    local label="$1"
    local problem="$2"
    local ans="$3"
    local got
    got="$(run_detector "$problem" "$ans")"
    if [ -z "$got" ]; then
        pass "pass-through (no short-circuit): $label"
    else
        fail "pass-through (no short-circuit): $label" "expected empty, got '$got'"
    fi
}

# --- (a) Three cases that MUST trip the Lagrange gate ---
# S_5 has |S_5| = 120; 9 does not divide 120 -> FALSIFIED_LAGRANGE
assert_falsified "S_5 with stated_answer=9 (9 nmid 120)" \
    "Find subgroup orders of the symmetric group S_5." "9"

# S_7 has |S_7| = 5040 = 2^4 * 3^2 * 5 * 7; 11 is prime > 7 so does not
# divide 5040 -> FALSIFIED_LAGRANGE. (The original plan mentioned 16,
# but 16 = 2^4 actually does divide 5040; corrected at implementation
# time.)
assert_falsified "S_7 with stated_answer=11 (11 nmid 5040)" \
    "Count cosets in S_7 of a chosen subgroup." "11"

# C_12 has order 12; 7 does not divide 12 -> FALSIFIED_LAGRANGE (claim-37 shape)
assert_falsified "C_12 subgroup order 7 (7 nmid 12)" \
    "Enumerate subgroups of the cyclic group C_12." "7"

# --- (b) Three valid cases that MUST pass through (no short-circuit) ---
# S_5 with stated_answer=15: 15 divides 120 -> no trip
assert_pass_through "S_5 with stated_answer=15 (15 mid 120)" \
    "Find subgroup orders of the symmetric group S_5." "15"

# C_6 with stated_answer=3: 3 divides 6 -> no trip
assert_pass_through "C_6 with stated_answer=3 (3 mid 6)" \
    "Enumerate subgroups of the cyclic group C_6." "3"

# D_6 (|D_6|=12) with stated_answer=4: 4 divides 12 -> no trip
assert_pass_through "D_6 with stated_answer=4 (4 mid 12)" \
    "Compute reflection subgroups of the dihedral group D_6." "4"

# --- (c) Inconclusive / pass-through edge cases ---
# Non-numeric stated_answer (LaTeX) -> always pass-through, never short-circuit
assert_pass_through "C_12 with LaTeX answer (non-numeric falls through)" \
    "Enumerate subgroups of the cyclic group C_12." "\\\\frac{1}{2}"

# No recognised group token -> pass-through
assert_pass_through "no group token cited (empty detector match)" \
    "Compute the third derivative of f(x) = sin(x) * exp(x)." "9"

# Empty stated_answer -> pass-through
assert_pass_through "S_5 with empty stated_answer (parse_int(\"\")=0 in .ag, guarded)" \
    "Find subgroup orders of the symmetric group S_5." ""

# --- (d) Verifier.ag drift check: the helper fns + regex literals must be present ---
if [ ! -f "$VERIFIER_AG" ]; then
    fail "(d) verifier.ag exists at $VERIFIER_AG" "file not found"
else
    drift_missing=""
    grep -q "fn _lagrange_check_symmetric" "$VERIFIER_AG" || \
        drift_missing="$drift_missing _lagrange_check_symmetric"
    grep -q "fn _lagrange_check_cyclic_dihedral" "$VERIFIER_AG" || \
        drift_missing="$drift_missing _lagrange_check_cyclic_dihedral"
    grep -q "fn _publish_falsified_verdict" "$VERIFIER_AG" || \
        drift_missing="$drift_missing _publish_falsified_verdict"
    grep -q 'FALSIFIED_LAGRANGE' "$VERIFIER_AG" || \
        drift_missing="$drift_missing FALSIFIED_LAGRANGE-label"
    # Regex literals inside the .ag's `python3 -c '...'` string are
    # double-escaped (e.g. `\\bC_(\\d+)\\b` -- the .ag layer eats one
    # level of backslash, leaving `\bC_(\d+)\b` for python).
    grep -Fq '\\bS_(\\d+)\\b' "$VERIFIER_AG" || \
        drift_missing="$drift_missing S_n-regex"
    grep -Fq '\\bC_(\\d+)\\b' "$VERIFIER_AG" || \
        drift_missing="$drift_missing C_n-regex"
    grep -Fq '\\bD_(\\d+)\\b' "$VERIFIER_AG" || \
        drift_missing="$drift_missing D_n-regex"
    grep -Fq '\\bZ/(\\d+)Z\\b' "$VERIFIER_AG" || \
        drift_missing="$drift_missing Z/nZ-regex"
    grep -Fq 'symmetric group' "$VERIFIER_AG" || \
        drift_missing="$drift_missing symmetric-group-regex"
    if [ -z "$drift_missing" ]; then
        pass "(d) verifier.ag carries all helper fn names + regex literals"
    else
        fail "(d) verifier.ag carries all helper fn names + regex literals" \
             "missing:$drift_missing"
    fi
fi

# --- (e) Gate hook order: short-circuit MUST precede the prompt() call ---
if [ -f "$VERIFIER_AG" ]; then
    # Find line of the gate-hook call and the line of the prompt() call.
    gate_line="$(grep -n "_lagrange_check_symmetric(problem_text" "$VERIFIER_AG" | head -1 | cut -d: -f1 || true)"
    prompt_line="$(grep -n "prompt(_verifier_prompt()" "$VERIFIER_AG" | head -1 | cut -d: -f1 || true)"
    if [ -n "$gate_line" ] && [ -n "$prompt_line" ] && [ "$gate_line" -lt "$prompt_line" ]; then
        pass "(e) gate hook precedes prompt() (gate@$gate_line, prompt@$prompt_line)"
    else
        fail "(e) gate hook precedes prompt()" \
             "gate_line=$gate_line, prompt_line=$prompt_line"
    fi
fi

# --- (f) Agentis parse: verifier.ag must parse clean ---
if command -v agentis >/dev/null 2>&1; then
    AG_TMP="$(mktemp -d)"
    trap 'rm -rf "$AG_TMP"' EXIT
    (cd "$AG_TMP" && agentis init >/dev/null 2>&1) || true
    if (cd "$AG_TMP" && agentis test "$VERIFIER_AG") >/dev/null 2>&1; then
        pass "(f) verifier.ag parses clean via agentis test"
    else
        fail "(f) verifier.ag parses clean via agentis test" \
             "$(cd "$AG_TMP" && agentis test "$VERIFIER_AG" 2>&1 | tail -5)"
    fi
else
    echo "[SKIP] (f) verifier.ag parses clean -- agentis binary not on PATH"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
