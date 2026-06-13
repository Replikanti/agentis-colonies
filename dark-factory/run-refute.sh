#!/usr/bin/env bash
# run-refute.sh — adversarial-REFUTATION entrypoint for the Dark Factory federation (#999).
#
# After run-discovery.sh (hunter.ag) surfaces CANDIDATE leads and BEFORE the operator spends a Foundry
# PoC on one, a SECOND, independent skeptic must fail to break it. This script drives that gate on the
# agentis substrate: it runs `auditor/agents/refuter.ag` once per candidate — env-in the candidate
# (file:fn + claimed exploit + class) and the relevant code, `prompt()` a hostile reader that tries to
# REFUTE it against the actual control-flow (defaulting to REFUTED on any doubt), `emit` the verdict, and
# `print` a `VERDICT|REAL|...` / `VERDICT|REFUTED|...` line. It runs ENTIRELY through the substrate
# (prompt/emit/learn), so each refutation is recorded as experience and refuter fitness reweights — the
# colony-native form of the `adversarial-refute` step (auditor/methods/registry.md) that previously ran as
# an externally-orchestrated subagent. This is the proven pattern (#999) for porting the colony's other
# deep capabilities (deep cross-function audit, build-and-run PoC, fork-differential) onto the substrate.
#
# A REAL verdict is still a LEAD, not a finding: it only means a hostile read could not kill it, so it is
# worth a Foundry PoC. Only a PASSING evm-harness/forge-verify.sh PoC makes a lead a finding, and
# submission stays an explicit, human-gated action. This tool NEVER contacts a bounty platform.
#
# Usage:
#   run-refute.sh --candidates <cands.tsv> [options]
#
# Candidate manifest (one candidate per line; `#` and blank lines ignored). Columns are `|`-separated:
#   <file:fn> | <classid> | <severity> | <claimed exploit sentence> | <code-file>
# where <code-file> is a path (absolute, or relative to --code-dir) to a file holding the RELEVANT code
# the skeptic judges against. e.g.
#   Vault.sol:liquidate | C10 | High   | anyone can self-liquidate at a stale price to seize collateral | vault_liquidate.sol
#   Token.sol:transfer  | C5  | Medium | transfer() lacks an owner check so anyone can move funds        | token_transfer.sol
#
# Options:
#   --candidates <file>  Candidate manifest (see above). REQUIRED.
#   --code-dir <dir>     Base dir for a candidate's relative <code-file> (default: dir of --candidates).
#   --brief <file>       Optional protocol brief (invariants + known issues to exclude). Default: none.
#   --only <file:fn>     Refute only the candidate whose file:fn matches (re-run / smoke one).
#   --backend <mock|claude>  LLM backend (default: claude). mock = offline-deterministic wiring smoke.
#   --model <id>         Optional model id passed to the claude CLI.
#   --out <dir>          Output dir for the run + verdicts (default: ./refute-out).
#   --agentis <bin>      agentis binary (default: `agentis` on PATH).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
CANDS="" ; CODE_DIR="" ; BRIEF="" ; ONLY=""
BACKEND="claude" ; MODEL="" ; OUT="$PWD/refute-out"

need() { [ "$1" -ge 2 ] || { echo "run-refute.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --candidates) need "$#"; CANDS="$2"; shift 2 ;;
    --code-dir) need "$#"; CODE_DIR="$2"; shift 2 ;;
    --brief) need "$#"; BRIEF="$2"; shift 2 ;;
    --only) need "$#"; ONLY="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --model) need "$#"; MODEL="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-refute.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$CANDS" ] && [ -f "$CANDS" ] || { echo "run-refute.sh: --candidates <file:fn|class|sev|exploit|code-file manifest> required" >&2; exit 2; }
[ -n "$CODE_DIR" ] || CODE_DIR="$(cd "$(dirname "$CANDS")" && pwd)"
[ -d "$CODE_DIR" ] || { echo "run-refute.sh: --code-dir not a directory: $CODE_DIR" >&2; exit 2; }
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-refute.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

# Resolve operator paths to ABSOLUTE — the colony runs from the rundir (a different cwd), and the exec
# sandbox cannot read $HOME, so a relative or home-rooted CODE_PATH would silently read empty. We stage
# every code file into the rundir below so the sandbox can always reach it.
CODE_DIR="$(cd "$CODE_DIR" && pwd)"
if [ -n "$BRIEF" ]; then
  [ -f "$BRIEF" ] || { echo "run-refute.sh: --brief not found: $BRIEF" >&2; exit 2; }
  BRIEF="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"
fi

REFUTER="$HERE/auditor/agents/refuter.ag"
[ -f "$REFUTER" ] || { echo "run-refute.sh: refuter agent not found at $REFUTER" >&2; exit 3; }

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$REFUTER" "$RUN/refuter.ag"
# Stage the brief into the rundir so the sandboxed exec sh can read it (it cannot read $HOME).
BRIEF_IN_RUN=""
if [ -n "$BRIEF" ]; then
  cp "$BRIEF" "$RUN/brief.md"
  BRIEF_IN_RUN="$RUN/brief.md"
fi

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  # 600s: a hostile cross-function trace of a candidate is the same order of cost as a discovery read.
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p${MODEL:+ --model $MODEL}"; echo "llm.cli_timeout_ms = 600000"; }
  echo "trace.level = normal"
  # The refuter reads the candidate code + brief through exec sh; pass through its whole env contract.
  echo "exec.env_passthrough = CAND_FILE_FN,CAND_CLASS,CAND_SEVERITY,CAND_EXPLOIT,CODE_PATH,BRIEF_PATH"
  echo "exec.default_timeout_ms = 30000"
  # Each refutation is recorded as experience; refuter fitness reweights over candidates.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

REPORT="$OUT/refute-report.md"
{
  echo "# Dark Factory — adversarial refutation verdicts"
  echo
  echo "- backend: $BACKEND"
  echo "- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through"
  echo "  \`evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>\` (PoC PASSES = exploit fires)"
  echo "  before it counts; submission stays a separate, explicit human action. This colony never posts."
  echo
  echo "| Candidate (file:fn) | Class | Verdict | Reason |"
  echo "|---|---|---|---|"
} > "$REPORT"

CHECKED=0 ; REAL=0 ; REFUTED=0
# Manifest loop: one candidate per line, `file:fn | class | sev | exploit | code-file`.
while IFS='|' read -r CFN CLS SEV EXPL CODEF || [ -n "${CFN:-}" ]; do
  CFN="$(printf '%s' "$CFN" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$CFN" in ''|\#*) continue ;; esac
  CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  SEV="$(printf '%s' "$SEV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  EXPL="$(printf '%s' "$EXPL" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  CODEF="$(printf '%s' "$CODEF" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$ONLY" ] && [ "$CFN" != "$ONLY" ] && continue
  [ -n "$CODEF" ] || { echo "run-refute.sh: candidate '$CFN' has no code-file; skipping" >&2; continue; }

  # Resolve the code file (absolute as-is, else relative to --code-dir) and stage it into the rundir so
  # the sandboxed exec sh — which cannot read $HOME — can always read it by an in-rundir path.
  case "$CODEF" in
    /*) SRC="$CODEF" ;;
    *)  SRC="$CODE_DIR/$CODEF" ;;
  esac
  if [ ! -f "$SRC" ]; then
    echo "run-refute.sh: code file not found for '$CFN': $SRC; skipping" >&2
    continue
  fi
  CHECKED=$((CHECKED + 1))
  SLUG="$(printf '%s' "$CFN" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
  STAGED="$RUN/code_${SLUG}.txt"
  cp "$SRC" "$STAGED"
  CELL_LOG="$RUN/refute_${SLUG}.log"
  echo "run-refute.sh: refuting $CFN ($CLS) ..." >&2
  ( cd "$RUN" && env \
      CAND_FILE_FN="$CFN" \
      CAND_CLASS="$CLS" \
      CAND_SEVERITY="$SEV" \
      CAND_EXPLOIT="$EXPL" \
      CODE_PATH="$STAGED" \
      BRIEF_PATH="$BRIEF_IN_RUN" \
      "$AGENTIS" go refuter.ag --enable-exec --enable-messaging ) >"$CELL_LOG" 2>&1 || \
      echo "run-refute.sh: refuter run failed for '$CFN' (see $CELL_LOG)" >&2

  # The refuter's contract: exactly one `VERDICT|REAL|...` or `VERDICT|REFUTED|...` line. Take the LAST
  # match (the agent prints its verdict after free-form reasoning). No line at all = treat as REFUTED
  # (conservative: a candidate that did not even produce a verdict has not survived the gate).
  VLINE="$(grep 'VERDICT|' "$CELL_LOG" | tail -1 || true)"
  if [ -z "$VLINE" ]; then
    VERD="REFUTED" ; REASON="no verdict line produced (treated as refuted)"
    REFUTED=$((REFUTED + 1))
  else
    V="$(printf '%s' "$VLINE" | sed 's/^.*\(VERDICT|\)/\1/')"
    VERD="$(printf '%s' "$V" | cut -d'|' -f2)"
    REASON="$(printf '%s' "$V" | cut -d'|' -f5-)"
    if [ "$VERD" = "REAL" ]; then REAL=$((REAL + 1)); else REFUTED=$((REFUTED + 1)); fi
  fi
  printf '| %s | %s | %s | %s |\n' "$CFN" "$CLS" "$VERD" "$REASON" >> "$REPORT"
done < "$CANDS"

{
  echo
  echo "---"
  echo "Checked: $CHECKED    REAL (survived, verify with forge): $REAL    REFUTED (killed): $REFUTED"
} >> "$REPORT"

echo >&2
echo "================ REFUTE: $CHECKED checked, $REAL survived, $REFUTED refuted ================" >&2
echo "run-refute.sh: verdicts at $REPORT" >&2
if [ "$REAL" -gt 0 ]; then
  echo "run-refute.sh: NEXT = forge-verify each REAL lead with evm-harness/forge-verify.sh; only a PASSING PoC is a finding. Submission stays human-gated." >&2
else
  echo "run-refute.sh: every candidate refuted — nothing survived the hostile read. Nothing to verify, nothing submitted." >&2
fi
