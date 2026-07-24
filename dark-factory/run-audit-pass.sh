#!/usr/bin/env bash
# run-audit-pass.sh — #1509 (epic #1505 CAPSTONE): the BOOTSTRAP for the coordinator SUBMISSION PASS.
#
# WHAT IT IS. A single `agentis go coordinator.ag` with PASS_ENABLED=1 drives the shipped submission stages
# as ONE fixed-order autonomous pass INSIDE the substrate: scope -> devise -> poc -> impact -> dup -> report
# -> HALT. The coordinator threads each stage's single-line verdict into the next and HARD-halts on a blocking
# gate (scope not payable -> BLOCKED-SCOPE; devise no-residual -> NO-RESIDUAL; poc not finding -> NO-POC;
# impact not substantiated -> BLOCKED-IMPACT; dup HIGH is advisory, never halts). The terminal best case is
# the report-writer's own SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW draft.
#
# WHAT IT IS NOT. It NEVER submits, NEVER contacts a bounty platform, and NEVER auto-picks a scope — the
# operator supplies the finding facts + the in-scope program. Submission is always a separate, explicit human
# action: a reviewer reads the PENDING-HUMAN-REVIEW draft and files it manually. This is the same human-gate
# contract as run-audit.sh.
#
# TWO PATHS.
#   OFFLINE (deterministic, no LLM/network): pass --pass-fixture "<scope=..;devise=..;..>" and every stage's
#     verdict comes from the fixture (an absent stage key defaults to that stage's PRODUCTIVE token, so a
#     partial fixture short-circuits at the divergent stage). This is what demo-audit-pass.sh / CI exercise.
#   LIVE (operator-gated): with no fixture, each stage runs its real runner — POC_RUN=run-poc.sh and the five
#     .ag gates via auditor/scripts/run-gate-agent.sh — behind an honest-stub fallback (an absent runner ->
#     `incomplete` -> the pass HALTS, never a false-proceed). A reasoning backend is required for the gates to
#     actually reason (--backend flat-cyborg|claude).
#
# Usage:
#   run-audit-pass.sh [--pass-fixture "<scope=..;devise=..;poc=..;impact=..;dup=..;report=..>"]
#                     [--finding-location <path>] [--finding-impact <text>] [--scope-file <file>]
#                     [--target-dir <dir>] [--in-scope <text>] [--audit-dir <dir>]
#                     [--poc-repo <dir>] [--poc-target <C.sol[:Name]>] [--poc-hypothesis <text>] [--poc-class <id>]
#                     [--mechanism-notes <text>] [--finding-file <path>] [--finding-anchor <text>]
#                     [--finding-title <text>] [--severity-band <Critical|High|Medium|Low>]
#                     [--reviewer-feedback <text>] [--reviewer-feedback-file <path>]
#                     [--live] [--backend <mock|flat-cyborg|claude>] [--out <dir>] [--agentis <bin>]
#
# FEEDBACK-INFORMED RE-HUNT (#1567). --reviewer-feedback carries a prior submission's rejection reason into the
# devise stage (audit-scout.ag's DEVISE prompt) so the pass hunts a residual AROUND the failure mode instead of
# re-surfacing the rejected finding. --reviewer-feedback-file loads the same text from a file (the inline flag
# wins). Empty feedback = byte-identical behavior: the var resolves to "" and the downstream prompt is unchanged.
#
# Exit: 0 on a clean pass that reached its HALT; 2 usage error; 3 missing prerequisite.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
PASS_FIXTURE=""
FINDING_LOCATION=""
FINDING_IMPACT=""
SCOPE_FILE=""
TARGET_DIR=""
IN_SCOPE=""
AUDIT_DIR=""
POC_REPO=""
POC_TARGET=""
POC_HYPOTHESIS=""
POC_CLASS=""
MECHANISM_NOTES=""
FINDING_FILE=""
FINDING_ANCHOR=""
FINDING_TITLE=""
SEVERITY_BAND=""
FINDING_VERIFIED=""
REVIEWER_FEEDBACK=""
REVIEWER_FEEDBACK_FILE=""
LIVE=0
BACKEND="mock"
OUT="$PWD/audit-pass-out"

need() { [ "$1" -ge 2 ] || { echo "run-audit-pass.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --pass-fixture)     need "$#"; PASS_FIXTURE="$2"; shift 2 ;;
    --finding-location) need "$#"; FINDING_LOCATION="$2"; shift 2 ;;
    --finding-impact)   need "$#"; FINDING_IMPACT="$2"; shift 2 ;;
    --scope-file)       need "$#"; SCOPE_FILE="$2"; shift 2 ;;
    --target-dir)       need "$#"; TARGET_DIR="$2"; shift 2 ;;
    --in-scope)         need "$#"; IN_SCOPE="$2"; shift 2 ;;
    --audit-dir)        need "$#"; AUDIT_DIR="$2"; shift 2 ;;
    --poc-repo)         need "$#"; POC_REPO="$2"; shift 2 ;;
    --poc-target)       need "$#"; POC_TARGET="$2"; shift 2 ;;
    --poc-hypothesis)   need "$#"; POC_HYPOTHESIS="$2"; shift 2 ;;
    --poc-class)        need "$#"; POC_CLASS="$2"; shift 2 ;;
    --mechanism-notes)  need "$#"; MECHANISM_NOTES="$2"; shift 2 ;;
    --finding-file)     need "$#"; FINDING_FILE="$2"; shift 2 ;;
    --finding-anchor)   need "$#"; FINDING_ANCHOR="$2"; shift 2 ;;
    --finding-title)    need "$#"; FINDING_TITLE="$2"; shift 2 ;;
    --severity-band)    need "$#"; SEVERITY_BAND="$2"; shift 2 ;;
    --finding-verified) FINDING_VERIFIED=1; shift ;;   # #1806: finding already passed the fuzzer/refute gate -> devise advisory
    --reviewer-feedback)      need "$#"; REVIEWER_FEEDBACK="$2"; shift 2 ;;
    --reviewer-feedback-file) need "$#"; REVIEWER_FEEDBACK_FILE="$2"; shift 2 ;;
    --live)             LIVE=1; shift ;;
    --backend)          need "$#"; BACKEND="$2"; shift 2 ;;
    --out)              need "$#"; OUT="$2"; shift 2 ;;
    --agentis)          need "$#"; AGENTIS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-audit-pass.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

# --reviewer-feedback wins; a --reviewer-feedback-file is loaded ONLY when no inline text was given. A set-but-
# unreadable file is a hard missing-prerequisite (exit 3, the same code as the other absent inputs), never a
# silently-empty feedback. Empty on both -> REVIEWER_FEEDBACK stays "" and the downstream devise is byte-identical.
if [ -z "$REVIEWER_FEEDBACK" ] && [ -n "$REVIEWER_FEEDBACK_FILE" ]; then
  [ -r "$REVIEWER_FEEDBACK_FILE" ] || { echo "run-audit-pass.sh: --reviewer-feedback-file not readable: $REVIEWER_FEEDBACK_FILE" >&2; exit 3; }
  REVIEWER_FEEDBACK="$(cat "$REVIEWER_FEEDBACK_FILE")"
fi

# A fixture is the OFFLINE path; without one AND without --live, refuse (a mock backend with no fixture would
# have every gate come back non-productive -> a meaningless INCOMPLETE). --live opts into the runner path.
if [ -z "$PASS_FIXTURE" ] && [ "$LIVE" -eq 0 ]; then
  echo "run-audit-pass.sh: supply --pass-fixture <..> for the offline path, or --live for the runner path" >&2
  exit 2
fi
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-audit-pass.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

COORD_AG="$HERE/auditor/agents/coordinator.ag"
[ -f "$COORD_AG" ] || { echo "run-audit-pass.sh: coordinator agent not found at $COORD_AG" >&2; exit 3; }
GATE_RUN="$HERE/auditor/scripts/run-gate-agent.sh"
POC_RUN_SH="$HERE/run-poc.sh"

mkdir -p "$OUT" || { echo "run-audit-pass.sh: cannot create --out dir: $OUT" >&2; exit 1; }
OUT="$(cd "$OUT" && pwd)"
# #1580: durable path for the report-writer's verbatim draft (sibling of pass.tsv / pass-result.txt). Absolute
# because the coordinator + gate wrapper run in throwaway cwds. Only ever written by a real LIVE report gate.
DRAFT_OUT="$OUT/submission-draft.md"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN" || { echo "run-audit-pass.sh: cannot create run dir: $RUN" >&2; exit 1; }
cp "$COORD_AG" "$RUN/coordinator.ag"

# The canonical fixed partial order — the coordinator defaults to this same order when STAGES is unset, so
# seeding it here is documentation, not authority (the coordinator OWNS the order; the gate semantics are
# name-keyed, never positional).
STAGES="$(printf 'scope\ndevise\npoc\nimpact\ndup\nreport')"

# #1813: on --live the pass runs each gate TOP-LEVEL (below) rather than nesting them inside `agentis go`.
# Sequential flat-cyborg sessions spawned from WITHIN the coordinator's nested exec degrade — the 2nd+ screen-
# scrape returns an empty extract (#1812), which killed the whole live pass at the poc stage. run-poc and the
# .ag gates run reliably as top-level flat-cyborg sessions (exactly how the sibling drivers run them); the
# coordinator then applies its EXACT gating logic over the collected verdicts as a PASS_FIXTURE (below).
if [ "$LIVE" -eq 1 ]; then
  [ -f "$GATE_RUN" ] || { echo "run-audit-pass.sh: run-gate-agent.sh not found at $GATE_RUN" >&2; exit 3; }
  [ -f "$POC_RUN_SH" ] || { echo "run-audit-pass.sh: run-poc.sh not found at $POC_RUN_SH" >&2; exit 3; }
fi

( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p"; echo "llm.cli_timeout_ms = 600000"; }
  [ "$BACKEND" = "flat-cyborg" ] && echo "llm.cli_timeout_ms = 600000"
  echo "trace.level = normal"
  # getenv reads the SANITIZED env — EVERY pass var the coordinator reads must be on this allowlist or it is
  # silently empty. Covers the pass gate flags, the finding facts, and every *_RUN live-runner path.
  echo "exec.env_passthrough = PASS_ENABLED,PASS_FIXTURE,STAGES,SCOPE_GATE_RUN,DEVISE_RUN,POC_RUN,IMPACT_GATE_RUN,DUP_RUN,REPORT_RUN,FINDING_LOCATION,FINDING_IMPACT,SCOPE_FILE,TARGET_DIR,IN_SCOPE,AUDIT_DIR,MECHANISM_NOTES,POC_FILE,POC_REPO,POC_TARGET,POC_HYPOTHESIS,POC_CLASS,FINDING_FILE,FINDING_ANCHOR,FINDING_TITLE,SEVERITY_BAND,SCOPE_VERDICT,IMPACT_VERDICT,DUP_RISK,REVIEWER_FEEDBACK,SUBMISSION_DRAFT_OUT,PASS_BACKEND,FINDING_VERIFIED"
  # A live gate run (agentis go + reasoning) far exceeds the 30s default; the offline fixture path never execs.
  # #1808: this ceiling must cover the POC stage, whose run_poc_live exec-shs run-poc.sh — a FULL generate +
  # bounded compile-repair (up to 2 rounds @ 600s LLM each) + forge build/test cycle that legitimately runs many
  # minutes; the 600000ms ceiling killed it on the first LLM call (partial 499-byte stdout). 30min covers the
  # worst-case run-poc budget; the .ag reasoning gates finish in well under it (a ceiling, not a wait).
  if [ "$LIVE" -eq 1 ]; then echo "exec.default_timeout_ms = 1800000"; else echo "exec.default_timeout_ms = 30000"; fi
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

RUN_LOG="$RUN/pass.log"

# ---- #1813: TOP-LEVEL gate orchestration (--live) ---------------------------------------------------------
# Run each gate as its OWN top-level flat-cyborg session and collect the verdicts into a PASS_FIXTURE; the
# coordinator then GATES over that fixture (deterministic, no nested flat-cyborg), sidestepping #1812. run-poc
# runs top-level here (reliable -> FINDING) and its POC-FILE/POC-RUN paths are memo'd for the deliver wire
# (#1802). The report gate runs top-level to generate the human-review draft (report-writer embeds the PoC).
POC_FILE_LIVE=""; POC_RUN_LIVE=""
if [ "$LIVE" -eq 1 ]; then
  _scopeV=""; _impactV=""; _dupV=""
  _gate() {  # $1 verdict-prefix, $2 negative-token ("" if none), $3 POC_FILE (report only) -> echoes verdict line
    _nt=""; [ -n "$2" ] && _nt="--negative-token $2"
    # shellcheck disable=SC2086
    env VERDICT_PREFIX="$1" VERDICT_NEGATIVE="$2" GATE_BACKEND="$BACKEND" \
        FINDING_LOCATION="$FINDING_LOCATION" FINDING_IMPACT="$FINDING_IMPACT" SCOPE_FILE="$SCOPE_FILE" \
        TARGET_DIR="$TARGET_DIR" IN_SCOPE="$IN_SCOPE" AUDIT_DIR="$AUDIT_DIR" MECHANISM_NOTES="$MECHANISM_NOTES" \
        FINDING_FILE="$FINDING_FILE" FINDING_ANCHOR="$FINDING_ANCHOR" FINDING_TITLE="$FINDING_TITLE" \
        SEVERITY_BAND="$SEVERITY_BAND" REVIEWER_FEEDBACK="$REVIEWER_FEEDBACK" \
        SCOPE_VERDICT="$_scopeV" IMPACT_VERDICT="$_impactV" DUP_RISK="$_dupV" \
        POC_FILE="$3" SUBMISSION_DRAFT_OUT="$DRAFT_OUT" \
        bash "$GATE_RUN" --verdict-prefix "$1" --backend "$BACKEND" $_nt 2>>"$RUN/gates.log" || true
  }
  _sl="$(_gate SCOPE-GATE '' '')"
  case "$_sl" in
    *"SCOPE-GATE|PAYABLE"*)            _scopeV=payable ;;
    *"SCOPE-GATE|OUT-OF-SCOPE-ASSET"*) _scopeV=out-of-scope-asset ;;
    *"SCOPE-GATE|EXCLUDED-CARVEOUT"*)  _scopeV=excluded-carveout ;;
    *"SCOPE-GATE|INELIGIBLE-IMPACT"*)  _scopeV=ineligible-impact ;;
    *) _scopeV=incomplete ;;
  esac
  FIX="scope=$_scopeV"
  if [ "$_scopeV" = payable ]; then
    _dl="$(_gate RESIDUAL NO-RESIDUAL '')"
    case "$_dl" in *"NO-RESIDUAL"*) _dv=no-residual ;; *"RESIDUAL|"*) _dv=residual ;; *) _dv=incomplete ;; esac
    FIX="$FIX;devise=$_dv"
    # poc HARD -- TOP-LEVEL run-poc (the reliable path; nested run-poc hit #1812)
    bash "$POC_RUN_SH" --repo "$POC_REPO" --target "$POC_TARGET" --hypothesis "$POC_HYPOTHESIS" \
      --class "$POC_CLASS" --backend "$BACKEND" --out "$RUN/poc-live" >"$RUN/poc.log" 2>&1 || true
    _pl="$(grep '^POC|' "$RUN/poc.log" 2>/dev/null | grep -v '^POC-FILE|' | tail -1 || true)"
    case "$_pl" in *"|FINDING"*) _pv=finding ;; *"|CLEAN"*) _pv=clean ;; *) _pv=harness-error ;; esac
    FIX="$FIX;poc=$_pv"
    POC_FILE_LIVE="$(grep '^POC-FILE|' "$RUN/poc.log" 2>/dev/null | tail -1 | sed 's/^POC-FILE|//' || true)"
    POC_RUN_LIVE="$(grep '^POC-RUN|' "$RUN/poc.log" 2>/dev/null | tail -1 | sed 's/^POC-RUN|//' || true)"
    if [ "$_pv" = finding ]; then
      _il="$(_gate IMPACT-GATE '' "$POC_FILE_LIVE")"
      case "$_il" in
        *"IMPACT-GATE|SUBSTANTIATED"*)      _impactV=substantiated ;;
        *"IMPACT-GATE|SIMULATED-STATE"*)    _impactV=simulated-state ;;
        *"IMPACT-GATE|PRIVILEGED-TRIGGER"*) _impactV=privileged-trigger ;;
        *"IMPACT-GATE|NO-PROVABLE-CLAIM"*)  _impactV=no-provable-claim ;;
        *) _impactV=incomplete ;;
      esac
      FIX="$FIX;impact=$_impactV"
      if [ "$_impactV" = substantiated ]; then
        _ul="$(_gate DUP-RISK '' "$POC_FILE_LIVE")"
        case "$_ul" in *"DUP-RISK|LOW"*) _dupV=low ;; *"DUP-RISK|HIGH"*) _dupV=high ;; *"DUP-RISK|MODERATE"*) _dupV=moderate ;; *) _dupV=incomplete ;; esac
        FIX="$FIX;dup=$_dupV"
        _rl="$(_gate SUBMISSION-DRAFT '' "$POC_FILE_LIVE")"
        case "$_rl" in *"SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW"*) _rv=drafted ;; *) _rv=failed ;; esac
        FIX="$FIX;report=$_rv"
      fi
    fi
  fi
  PASS_FIXTURE="$FIX"
  echo "run-audit-pass.sh: live top-level gate verdicts -> $FIX" >&2
  # #1802: memo the concrete PoC artifact paths so the deliver wire surfaces them (run_poc_live is bypassed on
  # the top-level path, so run-audit-pass memos them directly into the coordinator store the readback reads).
  [ -n "$POC_FILE_LIVE" ] && ( cd "$RUN" && "$AGENTIS" memo set coordinator:poc_file "$POC_FILE_LIVE" >/dev/null 2>&1 || true )
  [ -n "$POC_RUN_LIVE" ]  && ( cd "$RUN" && "$AGENTIS" memo set coordinator:poc_run "$POC_RUN_LIVE" >/dev/null 2>&1 || true )
fi

# The coordinator applies its gating logic over PASS_FIXTURE (the live-built one above, or the operator's offline
# --pass-fixture) -- deterministic, no nested flat-cyborg. --grant-pii: benign public contract/finding text (#1690).
( cd "$RUN" && env \
    PASS_ENABLED=1 \
    PASS_FIXTURE="$PASS_FIXTURE" \
    STAGES="$STAGES" \
    FINDING_LOCATION="$FINDING_LOCATION" \
    FINDING_IMPACT="$FINDING_IMPACT" \
    SCOPE_FILE="$SCOPE_FILE" \
    TARGET_DIR="$TARGET_DIR" \
    IN_SCOPE="$IN_SCOPE" \
    AUDIT_DIR="$AUDIT_DIR" \
    MECHANISM_NOTES="$MECHANISM_NOTES" \
    POC_REPO="$POC_REPO" \
    POC_TARGET="$POC_TARGET" \
    POC_HYPOTHESIS="$POC_HYPOTHESIS" \
    POC_CLASS="$POC_CLASS" \
    FINDING_FILE="$FINDING_FILE" \
    FINDING_ANCHOR="$FINDING_ANCHOR" \
    FINDING_TITLE="$FINDING_TITLE" \
    SEVERITY_BAND="$SEVERITY_BAND" \
    REVIEWER_FEEDBACK="$REVIEWER_FEEDBACK" \
    SUBMISSION_DRAFT_OUT="$DRAFT_OUT" \
    FINDING_VERIFIED="$FINDING_VERIFIED" \
    "$AGENTIS" go coordinator.ag --enable-exec --enable-messaging --grant-pii ) >"$RUN_LOG" 2>&1 \
  || { echo "run-audit-pass.sh: submission pass failed (see $RUN_LOG)" >&2; exit 1; }

grep -E '^PASS\|' "$RUN_LOG" >/dev/null 2>&1 \
  || { echo "run-audit-pass.sh: pass did not complete (no PASS| marker; see $RUN_LOG)" >&2; exit 1; }

# Read the trace + result back from the durable memos the pass wrote (the substrate-native cross-process
# channel), exactly as run-coordinator.sh reads coordinator:trace / coordinator:policy_after.
TRACE="$OUT/pass.tsv"
( cd "$RUN" && "$AGENTIS" memo get coordinator:pass_trace ) 2>/dev/null > "$TRACE" || true
RESULT="$( ( cd "$RUN" && "$AGENTIS" memo get coordinator:pass_result ) 2>/dev/null )"

# #1802 — surface the concrete PoC artifact paths the pass generated (run_poc_live memo'd them off run-poc.sh's
# POC-FILE|/POC-RUN| stdout) so the caller (run-zone-hunt.sh) can bundle the runnable witness into the submission
# package via deliver-submission.sh --poc-file/--poc-run. Absent on a pass that never reached a FINDING poc stage
# (offline fixture path, or a CLEAN/HARNESS_ERROR poc) -> the files are simply not written (no PoC to bundle).
POC_FILE_PATH="$( ( cd "$RUN" && "$AGENTIS" memo get coordinator:poc_file ) 2>/dev/null )"
POC_RUN_PATH="$( ( cd "$RUN" && "$AGENTIS" memo get coordinator:poc_run ) 2>/dev/null )"
[ -n "$POC_FILE_PATH" ] && printf '%s' "$POC_FILE_PATH" > "$OUT/poc-file-path.txt"
[ -n "$POC_RUN_PATH" ] && printf '%s' "$POC_RUN_PATH" > "$OUT/poc-run-path.txt"

echo "run-audit-pass.sh: pass trace ->" >&2
while IFS= read -r row; do [ -n "$row" ] && echo "run-audit-pass.sh:   $row" >&2; done < "$TRACE"
echo "run-audit-pass.sh: pass RESULT: $RESULT" >&2
if [ "$RESULT" = "PENDING-HUMAN-REVIEW" ]; then
  echo "run-audit-pass.sh: the pass reached the human-gate draft — a reviewer reads it and files it manually. This never submits." >&2
else
  echo "run-audit-pass.sh: the pass halted before a draft ($RESULT) — nothing to review. This never submits." >&2
fi
printf '%s' "$RESULT" > "$OUT/pass-result.txt"
exit 0
