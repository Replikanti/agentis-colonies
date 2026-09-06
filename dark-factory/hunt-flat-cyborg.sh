#!/usr/bin/env bash
# hunt-flat-cyborg.sh — a thin `--hunt-cmd` wrapper for run-batch.sh (epic #1894 M4, #1900): drives the
# `auditor` colony's one-shot `agentis go` pipeline (auditor/scripts/start-colony.sh) under a HARDCODED
# `llm.backend = flat-cyborg` config and translates the colony's own terminal `Verdict: <word>` line into
# the `VERDICT|<confirmed|dry|refuted>[|detail]` contract `run_hunt` already parses.
#
# HARD RULE: this script MUST configure `llm.backend = flat-cyborg`. It must NEVER invoke `claude -p` —
# no --backend override is offered (see "Out of scope" below), because a knob that could point this at
# `claude` would undermine the very invariant this milestone exists to enforce.
#
# Env-in contract (set by run_hunt, identical to every other --hunt-cmd wrapper in this federation):
#   BATCH_KEY    the funnel-ledger key for this target (informational; used in the run log only).
#   BATCH_URL    the funnel queue's url column for this target (informational only — see below).
#   BATCH_SCOPE  the funnel queue's scope_hint column for this target (informational only — see below).
#
# TARGET RESOLUTION IS THE OPERATOR'S JOB — same disclaimer run-batch.sh's own header carries for its
# default engine ("Full contest-URL -> foundry-repo -> invariant resolution is target-specific and out
# of scope"). This wrapper passes through whatever BOUNTY_TARGET / BOUNTY_POC / BOUNTY_SNAPSHOT /
# SOLANA_HARNESS_DIR the operator has already exported, UNMODIFIED — it does not attempt to derive them
# from BATCH_URL/BATCH_SCOPE.
#
# Stdout-out contract: exactly one `VERDICT|<confirmed|dry|refuted>[|detail]` line (mirrors run-poc.sh's
# inverted-verdict-line convention). Unmatched/absent auditor output — including a non-zero `agentis go`
# exit — always defaults to `dry` (NEVER a false `confirmed`); this is CI-invisible by design (no demo
# asserts the live path — see below), so a `Verdict:` wording drift would only be caught operator-side.
#
# Usage: hunt-flat-cyborg.sh [-h|--help]
#   No flags beyond -h/--help. Exit 0 always (the VERDICT line IS the result; run_hunt never inspects
#   this script's own exit code). `agentis` missing on PATH -> `VERDICT|dry|agentis not on PATH`, exit 0
#   (never leaves run_hunt's grep empty-handed).
#
# CI-safety: -h/--help works with no agentis/flat-cyborg present (source-guarded). The real backend run
# only executes with agentis + `flat-cyborg` on PATH + a logged-in flat-cyborg session — all absent on
# CI. No demo pretends to exercise that live path; colony-lint's blanket per-federation-root shellcheck
# sweep (find "$fed_path" -maxdepth 1 -name "*.sh") already covers this file's static shape.
set -u

case "${1:-}" in
  -h|--help) sed -n '2,35p' "$0"; exit 0;;
  "") ;;
  *) echo "hunt-flat-cyborg.sh: unknown arg: $1" >&2; exit 2;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
# #2119: wide flat-cyborg PTY by default for every flat-cyborg config emission (see the helper header).
# shellcheck source=lib/flat-cyborg-env.sh
# shellcheck disable=SC1091
. "$HERE/lib/flat-cyborg-env.sh"
AUDITOR_AG="$HERE/auditor/agents/auditor.ag"
# agentis-core#993: pre-accept Claude Code's workspace-trust dialog for the one-shot
# run dir (below), so the (always flat-cyborg) auditor session does not block + exit 75.
# shellcheck source=lib/ensure-claude-trust.sh
# shellcheck disable=SC1091
. "$HERE/lib/ensure-claude-trust.sh"

if ! command -v agentis >/dev/null 2>&1; then
  echo "VERDICT|dry|agentis not on PATH"
  exit 0
fi
if [ ! -f "$AUDITOR_AG" ]; then
  echo "VERDICT|dry|auditor.ag not found at $AUDITOR_AG"
  exit 0
fi

# Isolated one-shot rundir, mirroring run-audit-pass.sh's / demo-audit-pass.sh's run_pass() shape.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/run"
cp "$AUDITOR_AG" "$WORK/run/auditor.ag"
( cd "$WORK/run" && agentis init >/dev/null 2>&1 )
{
  echo "llm.backend = flat-cyborg"
  echo "llm.cli_timeout_ms = 600000"
  # Passthrough allowlist matches auditor/config/colony.example.toml's own [audit] env contract verbatim
  # (SOLANA_HARNESS_DIR / BOUNTY_TARGET / BOUNTY_POC / BOUNTY_SNAPSHOT) — unset ones stay unset, we do not
  # invent values.
  echo "exec.env_passthrough = BOUNTY_TARGET,BOUNTY_POC,BOUNTY_SNAPSHOT,SOLANA_HARNESS_DIR"
} > "$WORK/run/.agentis/config"

RUN_LOG="$WORK/run/hunt.log"
# #993: trust this one-shot run dir before `agentis go` (backend is always
# flat-cyborg here) so the session is not blocked on the workspace-trust dialog.
df_ensure_claude_trust "$WORK/run"
# --grant-pii: benign public contract-source text can trip the PII heuristic (#1690), same rationale as
# auditor/scripts/start-colony.sh's own invocation, which these flags mirror verbatim.
( cd "$WORK/run" && agentis go auditor.ag --enable-exec --enable-messaging --grant-pii --sandbox-profile hardened ) \
  >"$RUN_LOG" 2>&1
ec=$?

# Translate the auditor's own terminal Verdict: line (auditor.ag prints exactly one of VERIFIED /
# INCONCLUSIVE (...) / SAFE) into the batch VERDICT contract. Last match wins; no line / any non-zero
# `agentis go` exit both fall through to `dry` — fail toward "spend nothing further".
vline="$(grep '^Verdict: ' "$RUN_LOG" 2>/dev/null | tail -1)"
case "$vline" in
  "Verdict: VERIFIED"*)      echo "VERDICT|confirmed|${BATCH_KEY:-} auditor VERIFIED" ;;
  "Verdict: SAFE"*)          echo "VERDICT|refuted|${BATCH_KEY:-} auditor SAFE" ;;
  "Verdict: INCONCLUSIVE"*)  echo "VERDICT|dry|${BATCH_KEY:-} auditor INCONCLUSIVE" ;;
  *)                         echo "VERDICT|dry|${BATCH_KEY:-} no Verdict line found (agentis go exit $ec)" ;;
esac
exit 0
