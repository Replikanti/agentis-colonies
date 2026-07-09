#!/usr/bin/env bash
# demo-audit-pass.sh — #1509 (epic #1505 CAPSTONE): proof that coordinator.ag's PASS_ENABLED submission pass
# sequences the shipped stages in ONE fixed order with HARD early-exit gates and a HUMAN-GATED halt — offline,
# deterministic, NO network and NO real LLM.
#
# The submission stages (scope-gate, audit-scout DEVISE, poc-writer, impact-gate, dup-scout, report-writer)
# each shipped independently under epic #1505. This capstone wires them into the coordinator as ONE autonomous
# pass: discover -> scope -> devise -> poc -> impact -> dup -> report -> HALT, threading each stage's verdict
# into the next and hard-halting on a blocking gate. It NEVER emits a submit — the terminal best case is the
# report-writer's own SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW draft, permanently human-gated.
#
# TWO parts:
#   1) SOURCE-GUARD (always, CI-safe): the PASS_ENABLED gate, submission_pass/pass_step, the six stages in
#      the fixed STAGES order, the two hard gate predicates, the coordinator:pass_result terminal + the
#      PENDING-HUMAN-REVIEW marker, and that no submit is emitted.
#   2) LIVE offline pass (backend `mock`, PASS_ENABLED=1 + PASS_FIXTURE, deterministic): (a) a full-proceed
#      fixture runs all six stages in order -> PENDING-HUMAN-REVIEW; (b) an out-of-scope asset halts after
#      scope (downstream rows ABSENT) -> BLOCKED-SCOPE; (c) a simulated-state impact halts after impact
#      (dup/report ABSENT) -> BLOCKED-IMPACT; (d) no path prints/emits a submit.
#
# Usage:  dark-factory/demo-audit-pass.sh
# Exit: 0 = all assertions hold (live part SKIPs cleanly when agentis absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
COORD="$HERE/auditor/agents/coordinator.ag"

FAIL=0
note() { echo "demo-audit-pass.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*" >&2; FAIL=1; }
skip() { echo "  [SKIP] $*"; }

[ -f "$COORD" ] || { note "coordinator agent not found: $COORD" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD — the #1509 pass wiring must exist regardless of toolchain.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1509 coordinator submission-pass wiring ..."

if grep -q 'getenv("PASS_ENABLED")' "$COORD" && grep -q 'submission_pass();' "$COORD"; then
  ok "coordinator.ag gates a third mode on PASS_ENABLED -> submission_pass()"
else
  bad "coordinator.ag missing the PASS_ENABLED gate / submission_pass() call"
fi

if grep -q 'fn submission_pass()' "$COORD" && grep -q 'fn pass_step(' "$COORD"; then
  ok "coordinator.ag defines submission_pass() + pass_step()"
else
  bad "coordinator.ag missing submission_pass()/pass_step()"
fi

# The six stages in the fixed STAGES order (the coordinator OWNS the order; a caller may seed STAGES but the
# canonical default literal encodes the mandatory partial order).
if grep -q 'scope\\ndevise\\npoc\\nimpact\\ndup\\nreport' "$COORD"; then
  ok "coordinator.ag encodes the fixed STAGES order scope->devise->poc->impact->dup->report"
else
  bad "coordinator.ag missing the fixed STAGES order"
fi

# The two hard gate predicates require the EXACT productive token.
if grep -q 'fn scope_proceeds(' "$COORD" && grep -q 'v == "payable"' "$COORD" \
   && grep -q 'fn impact_proceeds(' "$COORD" && grep -q 'v == "substantiated"' "$COORD"; then
  ok "coordinator.ag hard gates require the exact productive token (scope==payable, impact==substantiated)"
else
  bad "coordinator.ag missing the hard gate predicates"
fi

# Each blocking gate's halt reason + the advisory dup + the terminal human-gate.
if grep -q 'BLOCKED-SCOPE' "$COORD" && grep -q 'NO-RESIDUAL' "$COORD" && grep -q 'NO-POC' "$COORD" \
   && grep -q 'BLOCKED-IMPACT' "$COORD" && grep -q 'PENDING-HUMAN-REVIEW' "$COORD"; then
  ok "coordinator.ag encodes the blocking-gate reasons + the PENDING-HUMAN-REVIEW terminal"
else
  bad "coordinator.ag missing a blocking-gate reason / the human-gate terminal"
fi

# The pass publishes its result to the durable memo the bootstrap reads back.
if grep -q 'memo_write("coordinator:pass_result"' "$COORD" && grep -q 'memo_write("coordinator:pass_trace"' "$COORD"; then
  ok "coordinator.ag publishes coordinator:pass_result + coordinator:pass_trace"
else
  bad "coordinator.ag missing the pass_result/pass_trace memos"
fi

# NEVER a submit: the pass must not emit any submit event or call a platform verb.
if grep -qiE 'emit\("[^"]*submit|submit\(|post_submission|bounty.*submit' "$COORD"; then
  bad "coordinator.ag appears to emit/attempt a submit — the pass must stay human-gated"
else
  ok "coordinator.ag emits NO submit — the pass halts at the human-gate draft"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) LIVE offline pass — deterministic, mock backend, PASS_FIXTURE only. No LLM, no network.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the deterministic offline pass"
  if [ "$FAIL" -eq 0 ]; then note "PASS — source-guard holds (live part skipped)"; exit 0; fi
  note "FAIL — a source-guard assertion regressed" >&2; exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Run ONE PASS_ENABLED coordinator pass with fixture $2 in a fresh store $1. Leaves the run log at $1/pass.log
# and the durable memos coordinator:pass_trace / coordinator:pass_result readable via `agentis memo get`.
run_pass() {
  _d="$1"; _fx="$2"
  mkdir -p "$_d"; cp "$COORD" "$_d/coordinator.ag"
  ( cd "$_d" && agentis init >/dev/null 2>&1 )
  {
    echo "llm.backend = mock"
    echo "trace.level = normal"
    echo "exec.env_passthrough = PASS_ENABLED,PASS_FIXTURE,STAGES,SCOPE_GATE_RUN,DEVISE_RUN,POC_RUN,IMPACT_GATE_RUN,DUP_RUN,REPORT_RUN"
    echo "exec.default_timeout_ms = 30000"
    echo "learning.enabled = true"
    echo "experience.enabled = true"
  } > "$_d/.agentis/config"
  ( cd "$_d" && env PASS_ENABLED=1 PASS_FIXTURE="$_fx" \
      agentis go coordinator.ag --enable-exec --enable-messaging ) >"$_d/pass.log" 2>&1
}
pass_result() { ( cd "$1" && agentis memo get coordinator:pass_result ) 2>/dev/null; }
pass_trace()  { ( cd "$1" && agentis memo get coordinator:pass_trace ) 2>/dev/null; }
# Does the trace contain a row for stage $2?  `trace_has <dir> <stage>`
trace_has() { pass_trace "$1" | grep -q "stage=$2	"; }

note "running the deterministic offline pass under three fact-states ..."

# --- (a) full-proceed: all six stages run in order -> PENDING-HUMAN-REVIEW. --------------------------------
run_pass "$WORK/a" "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted"
RA="$(pass_result "$WORK/a")"
note "(a) full-proceed fixture -> $RA"
if [ "$RA" = "PENDING-HUMAN-REVIEW" ]; then ok "full-proceed -> PENDING-HUMAN-REVIEW (the human-gate draft)"; else bad "expected PENDING-HUMAN-REVIEW, got '$RA'"; fi
_missing=""
for st in scope devise poc impact dup report; do trace_has "$WORK/a" "$st" || _missing="$_missing $st"; done
[ -z "$_missing" ] && ok "all six stages ran in order (scope devise poc impact dup report)" || bad "full-proceed missing stage rows:$_missing"

# --- (b) out-of-scope asset: halts after scope; devise/poc/impact/dup/report ABSENT -> BLOCKED-SCOPE. ------
run_pass "$WORK/b" "scope=out-of-scope-asset"
RB="$(pass_result "$WORK/b")"
note "(b) scope=out-of-scope-asset -> $RB"
if [ "$RB" = "BLOCKED-SCOPE" ]; then ok "out-of-scope asset -> BLOCKED-SCOPE"; else bad "expected BLOCKED-SCOPE, got '$RB'"; fi
trace_has "$WORK/b" scope && ok "scope stage ran" || bad "scope stage row missing"
_down=""
for st in devise poc impact dup report; do trace_has "$WORK/b" "$st" && _down="$_down $st"; done
[ -z "$_down" ] && ok "downstream stages provably NOT executed after the scope halt" || bad "downstream stages ran after halt:$_down"

# --- (c) simulated-state impact: halts after impact; dup/report ABSENT -> BLOCKED-IMPACT. -----------------
run_pass "$WORK/c" "scope=payable;poc=finding;impact=simulated-state"
RC="$(pass_result "$WORK/c")"
note "(c) scope=payable;poc=finding;impact=simulated-state -> $RC"
if [ "$RC" = "BLOCKED-IMPACT" ]; then ok "simulated-state impact -> BLOCKED-IMPACT"; else bad "expected BLOCKED-IMPACT, got '$RC'"; fi
_ran=""
for st in scope devise poc impact; do trace_has "$WORK/c" "$st" && _ran="$_ran $st"; done
[ "$_ran" = " scope devise poc impact" ] && ok "scope->devise->poc->impact ran, then halted at impact" || bad "unexpected pre-impact stage set:$_ran"
_after=""
for st in dup report; do trace_has "$WORK/c" "$st" && _after="$_after $st"; done
[ -z "$_after" ] && ok "dup/report provably NOT executed after the impact halt" || bad "dup/report ran after halt:$_after"

# --- (d) the never-submit invariant across ALL three runs. ------------------------------------------------
if grep -RiqE 'SUBMIT|submitting|posted to (immunefi|the platform|bounty)' "$WORK"/*/pass.log; then
  bad "a submit token appeared in a pass log — the pass must never submit"
else
  ok "no path printed/emitted a submit across all three runs (permanently human-gated)"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAIL" -eq 0 ]; then note "PASS — coordinator submission-pass integration holds"; exit 0; fi
note "FAIL — a submission-pass assertion regressed" >&2
exit 1
