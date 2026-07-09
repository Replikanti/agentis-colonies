#!/usr/bin/env bash
# run-gate-agent.sh — #1509: a thin LIVE runner for any SINGLE-verdict-line gate .ag, used by the
# coordinator submission pass (coordinator.ag::run_stage_live) for its five .ag stages. It runs one gate
# agent once on the agentis substrate in a THROWAWAY store and echoes the gate's own verdict line to stdout
# (nothing else), so the coordinator can grep + normalize it exactly as it would a hand-run gate.
#
# It NEVER submits — it only runs a read-only reasoning gate and prints its one verdict line.
#
# The agent + the verdict-line prefix come from either the CLI or the env (the coordinator passes them via
# env — VERDICT_PREFIX — because run_stage_live exec-shs a single runner path). When only the prefix is
# known, the agent is derived from it (each gate owns a distinct prefix):
#   SCOPE-GATE -> scope-gate.ag   IMPACT-GATE -> impact-gate.ag   POC -> poc-writer.ag
#   DUP-RISK   -> dup-scout.ag    RESIDUAL    -> audit-scout.ag   SUBMISSION-DRAFT -> report-writer.ag
#
# Usage:
#   run-gate-agent.sh [<agent.ag>] [--verdict-prefix <PREFIX>] [--backend <mock|flat-cyborg|claude>]
# Env (all optional; the coordinator forwards the finding facts the gates read):
#   GATE_AGENT, VERDICT_PREFIX      fallbacks for the two positional/flag inputs
#   FINDING_LOCATION FINDING_IMPACT SCOPE_FILE TARGET_DIR IN_SCOPE AUDIT_DIR MECHANISM_NOTES POC_FILE
#   FINDING_FILE FINDING_ANCHOR FINDING_TITLE SEVERITY_BAND SCOPE_VERDICT IMPACT_VERDICT DUP_RISK
#
# Exit: 0 when a verdict line was printed (or the run completed); 2 usage; 3 missing prerequisite.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$HERE/../agents"
AGENT="${GATE_AGENT:-}"
PREFIX="${VERDICT_PREFIX:-}"
BACKEND="mock"
AGENTIS="agentis"

need() { [ "$1" -ge 2 ] || { echo "run-gate-agent.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --verdict-prefix) need "$#"; PREFIX="$2"; shift 2 ;;
    --backend)        need "$#"; BACKEND="$2"; shift 2 ;;
    --agentis)        need "$#"; AGENTIS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    -*) echo "run-gate-agent.sh: unknown flag $1" >&2; exit 2 ;;
    *) AGENT="$1"; shift ;;
  esac
done

# Derive the agent from the verdict prefix when only the prefix was supplied (the coordinator's env path).
if [ -z "$AGENT" ]; then
  case "$PREFIX" in
    SCOPE-GATE)       AGENT="$AGENTS_DIR/scope-gate.ag" ;;
    IMPACT-GATE)      AGENT="$AGENTS_DIR/impact-gate.ag" ;;
    POC)              AGENT="$AGENTS_DIR/poc-writer.ag" ;;
    DUP-RISK)         AGENT="$AGENTS_DIR/dup-scout.ag" ;;
    RESIDUAL)         AGENT="$AGENTS_DIR/audit-scout.ag" ;;
    SUBMISSION-DRAFT) AGENT="$AGENTS_DIR/report-writer.ag" ;;
    *) echo "run-gate-agent.sh: no agent given and no known --verdict-prefix to derive one from" >&2; exit 2 ;;
  esac
fi
# A bare filename resolves against the agents dir.
case "$AGENT" in */*) : ;; *) AGENT="$AGENTS_DIR/$AGENT" ;; esac
[ -f "$AGENT" ] || { echo "run-gate-agent.sh: gate agent not found: $AGENT" >&2; exit 3; }
[ -n "$PREFIX" ] || { echo "run-gate-agent.sh: --verdict-prefix <PREFIX> is required (the gate's verdict-line token)" >&2; exit 2; }
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-gate-agent.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

RUN="$(mktemp -d)"
trap 'rm -rf "$RUN"' EXIT
cp "$AGENT" "$RUN/$(basename "$AGENT")"
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  echo "trace.level = normal"
  # The gates read the finding facts + threaded verdicts via getenv; each must be on the passthrough allowlist.
  echo "exec.env_passthrough = FINDING_LOCATION,FINDING_IMPACT,SCOPE_FILE,TARGET_DIR,IN_SCOPE,AUDIT_DIR,MECHANISM_NOTES,POC_FILE,FINDING_FILE,FINDING_ANCHOR,FINDING_TITLE,SEVERITY_BAND,SCOPE_VERDICT,IMPACT_VERDICT,DUP_RISK,DUP_RISK_LINE"
  echo "exec.default_timeout_ms = 600000"
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

LOG="$RUN/gate.log"
# --grant-pii: gate prompts can carry repo URLs / scope text that trip the PII heuristic; the input is benign.
( cd "$RUN" && "$AGENTIS" go "$(basename "$AGENT")" --enable-exec --enable-messaging --grant-pii ) >"$LOG" 2>&1 || true

# Echo ONLY the gate's verdict line (the LAST line matching the prefix). Nothing else reaches stdout.
grep -F "$PREFIX|" "$LOG" | tail -1 || true
