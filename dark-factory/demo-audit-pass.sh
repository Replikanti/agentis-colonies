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

# #1535: the POC stage's LIVE runner (run-poc.sh) is CLI-flag driven from the POC_* facts, NOT env-only like
# the five .ag gates — run_stage_live must dispatch it through run_poc_live, building --repo/--target/
# --hypothesis/--class from getenv(POC_*), each shell_escape()d.
if grep -q 'fn run_poc_live(' "$COORD" \
   && grep -q -- '--repo " + shell_escape(getenv("POC_REPO"))' "$COORD" \
   && grep -q -- '--target " + shell_escape(getenv("POC_TARGET"))' "$COORD" \
   && grep -q -- '--hypothesis " + shell_escape(getenv("POC_HYPOTHESIS"))' "$COORD" \
   && grep -q -- '--class " + shell_escape(getenv("POC_CLASS"))' "$COORD" \
   && grep -q 'if stage == "poc" { return run_poc_live(runner); }' "$COORD"; then
  ok "coordinator.ag builds run-poc.sh's CLI (--repo/--target/--hypothesis/--class) from the POC_* facts"
else
  bad "coordinator.ag missing the poc CLI-flag construction from POC_*"
fi

# #1535: the devise stage threads a per-stage NEGATIVE_TOKEN (NO-RESIDUAL) into run-gate-agent.sh so a BARE
# NO-RESIDUAL line is surfaced instead of dropped — WITHOUT piping it as `NO-RESIDUAL|reason` (which the
# unanchored `RESIDUAL|` substring checks would misread as success/residual). audit-scout.ag stays untouched.
if grep -q 'fn stage_negative_token(' "$COORD" \
   && grep -q 'if stage == "devise" { return "NO-RESIDUAL"; }' "$COORD" \
   && grep -q 'VERDICT_NEGATIVE=" + shell_escape(stage_negative_token(stage))' "$COORD"; then
  ok "coordinator.ag threads a per-stage VERDICT_NEGATIVE (devise -> NO-RESIDUAL), not a piped token"
else
  bad "coordinator.ag missing the stage_negative_token/VERDICT_NEGATIVE threading"
fi

# ----------------------------------------------------------------------------------------------------------
# 1b) OFFLINE round-trip through run-gate-agent.sh's verdict extraction (#1535) — pure shell, ALWAYS on
#     (no agentis, no LLM). Proves the devise NEGATIVE_TOKEN surfaces a bare NO-RESIDUAL that the old
#     single-prefix grep dropped, while the piped RESIDUAL| line and the omit-the-flag path are unchanged.
# ----------------------------------------------------------------------------------------------------------
GATE_RUNNER="$HERE/auditor/scripts/run-gate-agent.sh"
note "round-tripping the devise NEGATIVE_TOKEN extraction offline (no agentis) ..."
if [ ! -f "$GATE_RUNNER" ]; then
  bad "run-gate-agent.sh not found: $GATE_RUNNER"
else
  RT="$(mktemp -d)"
  printf 'chatter\nRESIDUAL|vault|C1|why|sketch\ntail\n' > "$RT/residual.log"
  printf 'chatter\nNO-RESIDUAL\ntail\n' > "$RT/no-residual.log"
  # (a) regression: a piped RESIDUAL|... line is still extracted with the negative token configured.
  _r="$(bash "$GATE_RUNNER" --classify-log "$RT/residual.log" --verdict-prefix RESIDUAL --negative-token NO-RESIDUAL 2>/dev/null)"
  [ "$_r" = "RESIDUAL|vault|C1|why|sketch" ] && ok "devise extraction still surfaces a piped RESIDUAL| line (regression-safe)" || bad "expected the RESIDUAL| line, got '$_r'"
  # (b) the fix: a BARE NO-RESIDUAL token is now surfaced (previously dropped by the single-prefix grep).
  _n="$(bash "$GATE_RUNNER" --classify-log "$RT/no-residual.log" --verdict-prefix RESIDUAL --negative-token NO-RESIDUAL 2>/dev/null)"
  [ "$_n" = "NO-RESIDUAL" ] && ok "devise extraction now surfaces the bare NO-RESIDUAL token (#1535 fix)" || bad "expected NO-RESIDUAL, got '$_n'"
  # (c) additive-only: omitting --negative-token preserves the old (bare-token-dropping) behavior for the five
  #     stages that never set one — proving the fix is opt-in per-stage, not a global behavior change.
  _o="$(bash "$GATE_RUNNER" --classify-log "$RT/no-residual.log" --verdict-prefix RESIDUAL 2>/dev/null)"
  [ -z "$_o" ] && ok "without --negative-token the bare token stays dropped (byte-identical to pre-fix)" || bad "expected empty without the token, got '$_o'"
  # (d) the coordinator maps the surfaced bare token to the informative no-residual (not generic incomplete).
  if grep -q 'if index_of(line, "NO-RESIDUAL") >= 0 { return "no-residual"; }' "$COORD"; then
    ok "coordinator.ag devise_class maps the surfaced NO-RESIDUAL -> no-residual"
  else
    bad "coordinator.ag devise_class missing the NO-RESIDUAL -> no-residual mapping"
  fi
  rm -rf "$RT"
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
# #1666: `agentis memo get` has an intermittent PER-CALL flaky read — reproduced at scale, the on-disk memo
# file is already byte-complete/correct at the exact moment a check fails, so this is NOT a write-completion
# race. This is a bounded RETRY of the read itself (re-issuing the identical `agentis memo get` each attempt),
# not a sync/sleep wait for a write to finish — do not "simplify" this back into a single-shot call or a fixed
# sleep; see the #1666 plan for the reproduction that ruled those out.
# Does the trace contain a row for stage $2?  `trace_has <dir> <stage>`
trace_has() {
  _th_tries=0
  while [ "$_th_tries" -lt 8 ]; do
    pass_trace "$1" | grep -q "stage=$2	" && return 0
    _th_tries=$((_th_tries + 1))
  done
  return 1
}
# Sibling of trace_has() for an arbitrary grep pattern (used by the LIVE stub-runner dispatch check below,
# which greps a `stage=...\tverdict=...` shape rather than a bare stage name) — same bounded read-retry
# rationale as trace_has(), NOT a write-completion wait.  `trace_has_row <dir> <pattern>`
trace_has_row() {
  _thr_tries=0
  while [ "$_thr_tries" -lt 8 ]; do
    pass_trace "$1" | grep -q "$2" && return 0
    _thr_tries=$((_thr_tries + 1))
  done
  return 1
}

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

# --- (c-bis) LIVE stub-runner dispatch (#1535): NO PASS_FIXTURE => the real run_stage_live path. Prove the
#     poc branch builds run-poc.sh's CLI from the POC_* facts (arg-capture stub) and poc_class parses the
#     POC|...|FINDING line run-poc.sh now emits. Stub runners stand in for the .ag gates + run-poc.sh — no
#     LLM, no forge/hardhat. impact/dup/report stay unwired -> the pass honestly halts at impact (INCOMPLETE).
note "exercising the LIVE run_stage_live dispatch with stub runners (poc CLI-args + POC| parsing) ..."
LV="$WORK/live"; mkdir -p "$LV"
CAP="$LV/poc-args.txt"
# Generic gate stub: echoes the productive token per VERDICT_PREFIX (scope + devise proceed).
cat > "$LV/gate-stub.sh" <<'STUB'
#!/usr/bin/env bash
case "${VERDICT_PREFIX:-}" in
  SCOPE-GATE) echo "SCOPE-GATE|PAYABLE" ;;
  RESIDUAL)   echo "RESIDUAL|vault|C1|stub|stub" ;;
  *)          echo "${VERDICT_PREFIX:-UNKNOWN}|STUB" ;;
esac
STUB
# PoC-capture stub: records the CLI args it was called with, then emits the POC|...|FINDING verdict line.
cat > "$LV/poc-stub.sh" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$CAP"
echo "POC|stub-target|FINDING"
STUB
chmod +x "$LV/gate-stub.sh" "$LV/poc-stub.sh"
cp "$COORD" "$LV/coordinator.ag"
( cd "$LV" && agentis init >/dev/null 2>&1 )
{
  echo "llm.backend = mock"
  echo "trace.level = normal"
  echo "exec.env_passthrough = PASS_ENABLED,STAGES,SCOPE_GATE_RUN,DEVISE_RUN,POC_RUN,IMPACT_GATE_RUN,DUP_RUN,REPORT_RUN,POC_REPO,POC_TARGET,POC_HYPOTHESIS,POC_CLASS"
  echo "exec.default_timeout_ms = 30000"
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$LV/.agentis/config"
( cd "$LV" && env PASS_ENABLED=1 \
    SCOPE_GATE_RUN="$LV/gate-stub.sh" DEVISE_RUN="$LV/gate-stub.sh" POC_RUN="$LV/poc-stub.sh" \
    POC_REPO="/stub/repo" POC_TARGET="Vault.sol:Vault" POC_HYPOTHESIS="reentrancy drain" POC_CLASS="C-reentrancy" \
    agentis go coordinator.ag --enable-exec --enable-messaging ) >"$LV/pass.log" 2>&1
# The poc branch must have called the stub with all four flags carrying the POC_* values (proves the CLI-arg
# construction + shell_escape()ing — e.g. the spaced --hypothesis survives as one argument).
_cap_missing=""
for kv in "--repo /stub/repo" "--target Vault.sol:Vault" "--hypothesis reentrancy drain" "--class C-reentrancy"; do
  grep -qF -- "$kv" "$CAP" 2>/dev/null || _cap_missing="$_cap_missing [$kv]"
done
[ -z "$_cap_missing" ] && ok "run_poc_live built run-poc.sh's CLI from the POC_* facts (--repo/--target/--hypothesis/--class)" || bad "poc CLI missing args:$_cap_missing"
# poc_class parsed the stub's POC|...|FINDING line (the exact shape run-poc.sh now emits) -> verdict=finding.
if trace_has_row "$LV" 'stage=poc	verdict=finding'; then
  ok "poc_class parsed the POC|...|FINDING line -> stage=poc verdict=finding"
else
  bad "poc stage did not normalize to verdict=finding (poc_class/POC| parsing)"; pass_trace "$LV" | sed 's/^/        | /'
fi

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
