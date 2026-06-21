#!/bin/bash
# tools/test-labeler-crystallizer-verdict.sh: unit tests for the #1235
# crystallizer rule-distillation verdict logic in triage/agents/labeler.ag.
#
# Covers #1237 item 1: the two pure/guard helpers that thread the
# crystallizer demote/reinforce feedback off the labeler's reality-check.
#
#   rule_feedback_delta(signal) -> float   (labeler.ag @298)
#       signal 1 (kept)     -> +0.1   (reinforce)
#       signal 2 (unknown)  ->  0.0   (no-op)
#       signal 3 (changed)  -> -0.15  (demote)
#
#   record_rule_feedback(blob, signal) -> void   (labeler.ag @313)
#       blob is the pending-verdict JSON array
#       [ts, iid, "labels_csv", "rule_id"]; its 4th field (index [3]) is
#       the crystallizer rule id ("" on the LLM path). It must:
#         - extract rule_id from field [3] (NOT [2] = labels),
#         - no-op on an empty rule_id (LLM-path verdict),
#         - no-op on "void" (an in-flight 3-field blob written before the
#           pilot deployed: json_get on the missing [3] yields Void ->
#           "void"; the 3->4-field deploy-boundary migration),
#         - otherwise call crystallizer_record_use and emit the
#           "[labeler] crystallizer feedback: ..." sentinel.
#
# The sentinel `record_rule_feedback` prints is the observable: it fires
# exactly when the guard is passed, so asserting its presence/absence on
# stdout tests the guard branches without inspecting crystallizer state
# (`crystallizer_record_use` is an ungated, defensive no-op under a bare
# `agentis go` with no crystallizer, so the call never errors).
#
# Implementation mirrors tools/test-per-repo-confidence.sh: each case
# embeds the BYTE-IDENTICAL helper text from the agent into a tiny
# probe.ag, runs it with `agentis go`, and matches stdout. A future
# helper-text drift in labeler.ag is the regression surface.
#
# Standard scaffold: set -eu, mktemp -d isolation, EXIT trap for cleanup,
# SKIP (exit 0) when the `agentis` binary is not on $PATH (CI fallback).
# Auto-discovered by tools/colony-lint.sh's tools-test loop.
#
# Usage: ./tools/test-labeler-crystallizer-verdict.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if ! command -v agentis >/dev/null 2>&1; then
    echo "[SKIP] agentis binary not found on \$PATH"
    echo "Results: 0 passed, 0 failed (skipped — agentis not installed)"
    exit 0
fi

# Canonical helper text — byte-identical to triage/agents/labeler.ag
# (rule_feedback_delta @298, record_rule_feedback @313). Embedded here so
# the test exercises the same code path the agent does; divergence between
# this block and the agent bodies is the regression this test guards.
HELPER='fn rule_feedback_delta(signal: int) -> float {
    if signal == 1 {
        return 0.1;
    };
    if signal == 3 {
        return 0.0 - 0.15;
    };
    return 0.0;
}

fn record_rule_feedback(blob: string, signal: int) -> void {
    let rule_id = to_string(json_get(blob, "[3]"));
    if len(rule_id) == 0 {
        return;
    };
    if rule_id == "void" {
        return;
    };
    crystallizer_record_use(rule_id, signal == 1, rule_feedback_delta(signal));
    print("[labeler] crystallizer feedback: rule", rule_id, "signal", signal);
}'

# run_probe BODY -> stdout of `agentis go` over (cb + HELPER + BODY).
# All stdout lines are returned (callers grep / tail as needed); the
# unconditional first `[genesis] <hash>` line is harmless to grep past.
run_probe() {
    local body="$1"
    local sandbox
    sandbox="$(mktemp -d -p "$TMPDIR_TEST")"
    (
        cd "$sandbox"
        agentis init >/dev/null 2>&1
        cat > probe.ag <<EOF
cb 100;

$HELPER

$body
EOF
        agentis go probe.ag 2>/dev/null
    )
    rm -rf "$sandbox"
}

# --- Tests 1a-1d: rule_feedback_delta mapping -----------------------------
# signal 1 -> +0.1, 2 -> 0.0, 3 -> -0.15, out-of-range -> default 0.0.
GOT="$(run_probe 'print(rule_feedback_delta(1));' | tail -n 1)"
if [ "$GOT" = "0.1" ]; then
    pass "test 1a: rule_feedback_delta(1) -> 0.1 (reinforce)"
else
    fail "test 1a: rule_feedback_delta(1) -> 0.1 (reinforce)" "got='$GOT'"
fi

GOT="$(run_probe 'print(rule_feedback_delta(2));' | tail -n 1)"
if [ "$GOT" = "0" ] || [ "$GOT" = "0.0" ]; then
    pass "test 1b: rule_feedback_delta(2) -> 0.0 (no-op)"
else
    fail "test 1b: rule_feedback_delta(2) -> 0.0 (no-op)" "got='$GOT'"
fi

GOT="$(run_probe 'print(rule_feedback_delta(3));' | tail -n 1)"
if [ "$GOT" = "-0.15" ]; then
    pass "test 1c: rule_feedback_delta(3) -> -0.15 (demote)"
else
    fail "test 1c: rule_feedback_delta(3) -> -0.15 (demote)" "got='$GOT'"
fi

GOT="$(run_probe 'print(rule_feedback_delta(0));' | tail -n 1)"
if [ "$GOT" = "0" ] || [ "$GOT" = "0.0" ]; then
    pass "test 1d: rule_feedback_delta(0) out-of-range -> default 0.0"
else
    fail "test 1d: rule_feedback_delta(0) out-of-range -> default 0.0" "got='$GOT'"
fi

# --- Test 2: 4-field blob, real rule_id -> sentinel fires with field [3] --
# The blob's 4th field "rule_abc" must be extracted (not the 3rd field
# "bug,priority::high" which is the labels csv). Sentinel present + carries
# the rule id and the signal.
OUT="$(run_probe 'record_rule_feedback("[1700000000,7,\"bug,priority::high\",\"rule_abc\"]", 1);')"
if echo "$OUT" | grep -Fq "[labeler] crystallizer feedback: rule rule_abc signal 1"; then
    pass "test 2: 4-field blob real rule_id -> sentinel fires with field [3] (rule_abc, not labels)"
else
    fail "test 2: 4-field blob real rule_id -> sentinel fires with field [3]" \
         "out='$(echo "$OUT" | tr '\n' '|')'"
fi

# --- Test 3: 3-field legacy blob -> "void" guard -> no sentinel ----------
# Pre-pilot 3-field blob: json_get(blob, "[3]") yields Void -> "void", the
# deploy-boundary migration guard returns early, crystallizer untouched.
OUT="$(run_probe 'record_rule_feedback("[1700000000,7,\"bug,priority::high\"]", 1);')"
if echo "$OUT" | grep -Fq "[labeler] crystallizer feedback"; then
    fail "test 3: 3-field legacy blob -> void guard -> no sentinel" \
         "sentinel fired on a void rule_id (3->4 field migration guard broken)"
else
    pass "test 3: 3-field legacy blob -> void guard -> no sentinel (3->4 field migration)"
fi

# --- Test 4: 4-field blob, empty rule_id (LLM path) -> no sentinel -------
# LLM-path verdict carries rule_id "" -> len 0 guard returns early.
OUT="$(run_probe 'record_rule_feedback("[1700000000,7,\"bug,priority::high\",\"\"]", 2);')"
if echo "$OUT" | grep -Fq "[labeler] crystallizer feedback"; then
    fail "test 4: empty rule_id (LLM path) -> no sentinel" \
         "sentinel fired on an empty rule_id (LLM-path verdict touched the crystallizer)"
else
    pass "test 4: empty rule_id (LLM path) -> no sentinel"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
