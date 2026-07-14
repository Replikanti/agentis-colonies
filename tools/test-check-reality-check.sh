#!/bin/bash
# tools/test-check-reality-check.sh: unit tests for
# check-reality-check.sh (#1453).
#
# Validates:
#   Test 1: an acting agent (forge-api.sh add-note) with no
#           "<agent>:pending_verdict" wiring and no waiver fails with
#           [UNWIRED], naming the file and the add-note verb
#   Test 2: same agent + literal "myagent:pending_verdict" string passes
#   Test 3: same agent, no pending_verdict, but a
#           "// colony-lint: reality-check-waived: <reason>" annotation
#           passes
#   Test 4: an agent whose only match is the READ verb
#           `forge-api.sh merge-requests ...` (not the `merge` write verb)
#           passes — regression guard for the false-positive class found
#           while grounding the plan
#   Test 5: an agent that only mentions a write verb inside a `//` doc
#           comment (no real call) passes — comment-stripping proven
#   Test 6: the real repo passes clean end-to-end (all 22 current
#           dev-apprenticeship agents already wired or waived)
#   Test 7: a scan root with no dev-apprenticeship/ subdir exits 2
#
# Usage: ./tools/test-check-reality-check.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -e

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TOOLS_DIR/.." && pwd)"
CHECK="$TOOLS_DIR/check-reality-check.sh"

FAKE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FAKE_ROOT"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# ----- Test 1: unwired acting agent fails with [UNWIRED] -----
T1="$FAKE_ROOT/t1"
mkdir -p "$T1/dev-apprenticeship/triage/agents"
cat > "$T1/dev-apprenticeship/triage/agents/myagent.ag" <<'EOF'
fn tick() -> void {
    exec sh "$COLONY_DIR/scripts/forge-api.sh add-note 5 --body x";
}
EOF
T1_OUT="$("$CHECK" "$T1" 2>&1)" && T1_RC=0 || T1_RC=$?
if [ "$T1_RC" -eq 1 ] \
    && printf '%s' "$T1_OUT" | grep -q '\[UNWIRED\].*myagent\.ag' \
    && printf '%s' "$T1_OUT" | grep -q 'add-note'; then
    pass "unwired acting agent fails with [UNWIRED] naming the file and verb"
else
    fail "unwired acting agent — expected exit 1 + [UNWIRED]/add-note, got rc=$T1_RC: $T1_OUT"
fi

# ----- Test 2: pending_verdict wiring passes -----
T2="$FAKE_ROOT/t2"
mkdir -p "$T2/dev-apprenticeship/triage/agents"
cat > "$T2/dev-apprenticeship/triage/agents/myagent.ag" <<'EOF'
fn tick() -> void {
    exec sh "$COLONY_DIR/scripts/forge-api.sh add-note 5 --body x";
    memo_write("myagent:pending_verdict", "5");
}
EOF
if "$CHECK" "$T2" >/dev/null 2>&1; then
    pass "pending_verdict-wired acting agent passes"
else
    fail "wired acting agent — expected exit 0, got: $("$CHECK" "$T2" 2>&1 || true)"
fi

# ----- Test 3: documented waiver passes -----
T3="$FAKE_ROOT/t3"
mkdir -p "$T3/dev-apprenticeship/triage/agents"
cat > "$T3/dev-apprenticeship/triage/agents/myagent.ag" <<'EOF'
fn tick() -> void {
    // colony-lint: reality-check-waived: no separable signal
    exec sh "$COLONY_DIR/scripts/forge-api.sh add-note 5 --body x";
}
EOF
if "$CHECK" "$T3" >/dev/null 2>&1; then
    pass "waived acting agent passes"
else
    fail "waived acting agent — expected exit 0, got: $("$CHECK" "$T3" 2>&1 || true)"
fi

# ----- Test 4: merge-requests (read verb) does NOT trigger ACTS -----
T4="$FAKE_ROOT/t4"
mkdir -p "$T4/dev-apprenticeship/triage/agents"
cat > "$T4/dev-apprenticeship/triage/agents/myagent.ag" <<'EOF'
fn tick() -> void {
    exec sh "$COLONY_DIR/scripts/forge-api.sh merge-requests --state opened --per-page 50";
}
EOF
if "$CHECK" "$T4" >/dev/null 2>&1; then
    pass "merge-requests (read verb) is not classified as an acting write call"
else
    fail "merge-requests false-positive — expected exit 0, got: $("$CHECK" "$T4" 2>&1 || true)"
fi

# ----- Test 5: comment-only verb mention does NOT trigger ACTS -----
T5="$FAKE_ROOT/t5"
mkdir -p "$T5/dev-apprenticeship/triage/agents"
cat > "$T5/dev-apprenticeship/triage/agents/myagent.ag" <<'EOF'
fn tick() -> void {
    // example: forge-api.sh create-tag --name v1
}
EOF
if "$CHECK" "$T5" >/dev/null 2>&1; then
    pass "doc-comment-only verb mention is not classified as an acting write call"
else
    fail "comment-only mention — expected exit 0, got: $("$CHECK" "$T5" 2>&1 || true)"
fi

# ----- Test 6: real repo passes clean end-to-end -----
T6_OUT="$("$CHECK" "$REPO_ROOT" 2>&1)" && T6_RC=0 || T6_RC=$?
if [ "$T6_RC" -eq 0 ]; then
    pass "real repo: every dev-apprenticeship acting agent wired or waived"
else
    fail "real repo — expected exit 0, got rc=$T6_RC: $T6_OUT"
fi

# ----- Test 7: missing dev-apprenticeship/ dir exits 2 (infra error) -----
T7="$FAKE_ROOT/t7"
mkdir -p "$T7"
T7_OUT="$("$CHECK" "$T7" 2>&1)" && T7_RC=0 || T7_RC=$?
if [ "$T7_RC" -eq 2 ] && printf '%s' "$T7_OUT" | grep -q 'dev-apprenticeship'; then
    pass "missing dev-apprenticeship/ dir exits 2 with an infra-error message"
else
    fail "missing dev-apprenticeship/ dir — expected exit 2, got rc=$T7_RC: $T7_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
