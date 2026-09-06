#!/usr/bin/env bash
# run-symbolic.sh — GENERATE-AND-VERIFY entrypoint for the Dark Factory federation (#1015 M2).
#
# The LLM is the HYPOTHESIS GENERATOR; HALMOS is the JUDGE. For each candidate this script runs
# `auditor/agents/symbolic-prover.ag` once on the agentis substrate: it env-ins the candidate (file:fn +
# the invariant to encode + class) and the relevant code, GENERATES a Halmos `*.t.sol` property spec
# (verbatim from a supplied SPEC_FIXTURE on the offline path, or via `prompt()` on the live path), VERIFIES
# it with the SOUND M1 gate `evm-harness/halmos-verify.sh`, and `print`s a `SYMBOLIC|<file:fn>|<verdict>`
# line whose verdict is HALMOS's exit code — never the LLM's opinion. Every run is recorded as experience
# (`learn` + `emit dark-factory:symbolic_verdict`); that write is what `experience.enabled` gates (see the
# config block below), NOT a fitness reweighting — the store is per-invocation and nothing reads it back.
# It mirrors run-refute.sh's per-candidate substrate loop; the difference is the verdict's SOURCE.
#
# This composes with M1: M1 shipped the callable Halmos gate + example specs + demo-halmos.sh; M2 closes
# the loop from a candidate to a symbolic verdict by GENERATING the spec the gate runs. A COUNTEREXAMPLE is
# a CONFIRMED bug (a concrete witness a human can replay); a PROVED safely refutes the lead by a proof; an
# INCONCLUSIVE / harness error is not a verdict. As everywhere in this colony, a confirmed bug is still a
# LEAD a human reviews — submission stays an explicit, human-gated action and this tool NEVER posts to a
# bounty platform.
#
# Usage:
#   run-symbolic.sh --candidates <cands.tsv> --repo <foundry project> [options]
#
# Candidate manifest (one candidate per line; `#` and blank lines ignored). Columns are `|`-separated:
#   <file:fn> | <classid> | <invariant sentence> | <code-file> | <spec-fixture>
# where:
#   <file:fn>          free-form candidate label (the lens), e.g. "Ledger.sol:transferSafe".
#   <classid>          the bug class id, e.g. "C-acct" ("" if unknown).
#   <invariant sentence> the property the generated spec must encode (used by the LLM on the live path).
#   <code-file>        OPTIONAL path (absolute, or relative to --code-dir) to the relevant in-scope code
#                      the LLM reads to write the spec. "" to skip (e.g. when a fixture is supplied).
#   <spec-fixture>     OPTIONAL path to a ready-made `*.t.sol` spec used VERBATIM (the offline/deterministic
#                      path — NO LLM). When set the verdict is Halmos's over THIS spec. "" = live (LLM) path.
# e.g.
#   Ledger.sol:transferSafe  | C-acct | total value is conserved across a transfer | code/ledger.sol | specs/proved.t.sol
#   Vault.sol:withdraw       | C10    | sum of balances never exceeds totalSupply  | code/vault.sol  |
#
# Options:
#   --candidates <file>  Candidate manifest (see above). REQUIRED.
#   --repo <dir>         Foundry project root (must hold foundry.toml). REQUIRED — the spec is built here.
#   --code-dir <dir>     Base dir for a candidate's relative <code-file>/<spec-fixture> (default: dir of
#                        --candidates).
#   --only <file:fn>     Verify only the candidate whose file:fn matches (re-run / smoke one).
#   --backend <mock|flat-cyborg|claude>  LLM backend for the live spec-generation path (default:
#                        flat-cyborg = flat-rate PTY wrapper; claude = metered -p API; mock = offline wiring
#                        smoke). On the offline path (a SPEC_FIXTURE in the manifest) the LLM is NOT called.
#   --model <id>         Optional model id (claude: passed to the CLI; flat-cyborg: set as llm.model).
#   --out <dir>          Output dir for the run + verdicts (default: ./symbolic-out).
#   --agentis <bin>      agentis binary (default: `agentis` on PATH).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# #2119: wide flat-cyborg PTY by default for every flat-cyborg config emission (see the helper header).
# shellcheck source=lib/flat-cyborg-env.sh
# shellcheck disable=SC1091
. "$HERE/lib/flat-cyborg-env.sh"
AGENTIS="agentis"
# agentis-core#993: pre-accept Claude Code's workspace-trust dialog for the RUN dir
# (below), so a flat-cyborg/claude symbolic-oracle session does not block + exit 75.
# shellcheck source=lib/ensure-claude-trust.sh
# shellcheck disable=SC1091
. "$HERE/lib/ensure-claude-trust.sh"
CANDS="" ; REPO="" ; CODE_DIR="" ; ONLY=""
BACKEND="flat-cyborg" ; MODEL="" ; OUT="$PWD/symbolic-out"

need() { [ "$1" -ge 2 ] || { echo "run-symbolic.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --candidates) need "$#"; CANDS="$2"; shift 2 ;;
    --repo) need "$#"; REPO="$2"; shift 2 ;;
    --code-dir) need "$#"; CODE_DIR="$2"; shift 2 ;;
    --only) need "$#"; ONLY="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --model) need "$#"; MODEL="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-symbolic.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$CANDS" ] && [ -f "$CANDS" ] || { echo "run-symbolic.sh: --candidates <file:fn|class|invariant|code-file|spec-fixture manifest> required" >&2; exit 2; }
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "run-symbolic.sh: --repo <foundry project root> required" >&2; exit 2; }
[ -f "$REPO/foundry.toml" ] || { echo "run-symbolic.sh: --repo is not a foundry project (no foundry.toml): $REPO" >&2; exit 2; }
[ -n "$CODE_DIR" ] || CODE_DIR="$(cd "$(dirname "$CANDS")" && pwd)"
[ -d "$CODE_DIR" ] || { echo "run-symbolic.sh: --code-dir not a directory: $CODE_DIR" >&2; exit 2; }
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-symbolic.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

# Resolve operator paths to ABSOLUTE — the colony runs from the rundir (a different cwd) and the exec
# sandbox cannot read $HOME, so a relative or home-rooted path would silently read empty. We build the
# spec inside the rundir's copy of --repo so the sandbox can always reach it.
REPO="$(cd "$REPO" && pwd)"
CODE_DIR="$(cd "$CODE_DIR" && pwd)"

PROVER="$HERE/auditor/agents/symbolic-prover.ag"
GATE="$HERE/evm-harness/halmos-verify.sh"
[ -f "$PROVER" ] || { echo "run-symbolic.sh: symbolic-prover agent not found at $PROVER" >&2; exit 3; }
[ -f "$GATE" ] || { echo "run-symbolic.sh: halmos-verify gate not found at $GATE" >&2; exit 3; }

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$PROVER" "$RUN/symbolic-prover.ag"
cp "$GATE" "$RUN/halmos-verify.sh"
# Stage a fresh copy of the foundry project into the rundir so the sandboxed exec sh can write the spec
# into its test/ dir and run halmos there (it cannot reach a $HOME-rooted --repo). Drop any pre-existing
# *.t.sol so a candidate's generated spec is the ONLY one halmos scopes to.
REPO_IN_RUN="$RUN/repo"
cp -R "$REPO" "$REPO_IN_RUN"
rm -f "$REPO_IN_RUN/test/"*.t.sol 2>/dev/null || true
mkdir -p "$REPO_IN_RUN/test"

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  # 600s: writing a symbolic spec is the same order of cost as a discovery read.
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p${MODEL:+ --model $MODEL}"; echo "llm.cli_timeout_ms = 600000"; }
  [ "$BACKEND" = "flat-cyborg" ] && { echo "llm.cli_timeout_ms = 600000"; [ -n "$MODEL" ] && echo "llm.model = $MODEL"; }
  echo "trace.level = normal"
  # The prover reads code + the fixture and writes/runs the spec through exec sh; pass its whole env contract.
  echo "exec.env_passthrough = CAND_FILE_FN,CAND_CLASS,CAND_INVARIANT,SPEC_REPO,SPEC_OUT,SPEC_FUNCTION,SPEC_FIXTURE,CODE_PATH,HALMOS_VERIFY"
  # A cargo-free halmos run is fast, but forge build + z3 over a spec exceeds the 10s default.
  echo "exec.default_timeout_ms = 180000"
  # Experience is ENABLED because `learn()` is a WRITE this flag GATES (#1878, measured on agentis v1.28.0):
  # symbolic-prover.ag ends every verify with learn("symbolic-prove", ...), and with `experience.enabled =
  # false` agentis raises `runtime error: experience not enabled` on that call — and a runtime error DISCARDS
  # the cell's whole accumulated stdout, so the `SYMBOLIC|<file:fn>|<verdict>` line this script parses never
  # appears and every candidate degrades to HARNESS_ERROR (#1877's silent false zero). `learning.enabled` gates
  # recommend()/adapt()/score_options() only — nothing on this path calls them — and is kept paired so a future
  # adaptive call cannot make `agentis go` refuse to start. It is NOT fitness reweighting: the store is
  # per-invocation and write-only, so no prover fitness accrues over candidates. Guard:
  # demo-experience-flags.sh.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

# #993: trust the RUN dir before the first `agentis go` so a flat-cyborg/claude
# symbolic-oracle session is not blocked on the workspace-trust dialog (mock never
# spawns claude). Best-effort — never fails the run.
case "$BACKEND" in flat-cyborg|claude) df_ensure_claude_trust "$RUN" ;; esac

REPORT="$OUT/symbolic-report.md"
{
  echo "# Dark Factory — symbolic generate-and-verify verdicts"
  echo
  echo "- backend: $BACKEND"
  echo "- The LLM HYPOTHESIZES (writes the property spec); HALMOS JUDGES (the verdict is its exit code,"
  echo "  never the LLM's opinion). PROVED = invariant holds for ALL inputs (lead refuted by a proof);"
  echo "  COUNTEREXAMPLE = a concrete input is a real bug (CONFIRMED with a witness); INCONCLUSIVE /"
  echo "  HARNESS_ERROR are not verdicts. A confirmed bug is a LEAD a human reviews; this colony never posts."
  echo
  echo "| Candidate (file:fn) | Class | Spec | Verdict |"
  echo "|---|---|---|---|"
} > "$REPORT"

CHECKED=0 ; PROVED=0 ; CEX=0 ; INCONC=0 ; ERR=0
# Manifest loop: one candidate per line, `file:fn | class | invariant | code-file | spec-fixture`.
while IFS='|' read -r CFN CLS INV CODEF FIXT || [ -n "${CFN:-}" ]; do
  CFN="$(printf '%s' "$CFN" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$CFN" in ''|\#*) continue ;; esac
  CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  INV="$(printf '%s' "$INV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  CODEF="$(printf '%s' "$CODEF" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  FIXT="$(printf '%s' "$FIXT" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$ONLY" ] && [ "$CFN" != "$ONLY" ] && continue

  SLUG="$(printf '%s' "$CFN" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"

  # Resolve + stage the (optional) code file into the rundir so the sandboxed exec sh can read it.
  CODE_IN_RUN=""
  if [ -n "$CODEF" ]; then
    case "$CODEF" in /*) CSRC="$CODEF" ;; *) CSRC="$CODE_DIR/$CODEF" ;; esac
    if [ -f "$CSRC" ]; then
      CODE_IN_RUN="$RUN/code_${SLUG}.txt"
      cp "$CSRC" "$CODE_IN_RUN"
    else
      echo "run-symbolic.sh: code file not found for '$CFN': $CSRC (continuing without code)" >&2
    fi
  fi

  # Resolve + stage the (optional) spec fixture. A fixture takes the OFFLINE/deterministic path (no LLM).
  FIXT_IN_RUN=""
  if [ -n "$FIXT" ]; then
    case "$FIXT" in /*) FSRC="$FIXT" ;; *) FSRC="$CODE_DIR/$FIXT" ;; esac
    if [ -f "$FSRC" ]; then
      FIXT_IN_RUN="$RUN/fixture_${SLUG}.t.sol"
      cp "$FSRC" "$FIXT_IN_RUN"
    else
      echo "run-symbolic.sh: spec fixture not found for '$CFN': $FSRC; skipping" >&2
      continue
    fi
  fi

  CHECKED=$((CHECKED + 1))
  SPEC_OUT="$REPO_IN_RUN/test/Spec_${SLUG}.t.sol"
  CELL_LOG="$RUN/symbolic_${SLUG}.log"
  echo "run-symbolic.sh: generating + verifying $CFN ($CLS) ..." >&2
  # --grant-pii: candidate/invariant text + target contract source can carry addresses/identifiers
  # that trip the PII heuristic; input is benign public contract text (#1690).
  ( cd "$RUN" && env \
      CAND_FILE_FN="$CFN" \
      CAND_CLASS="$CLS" \
      CAND_INVARIANT="$INV" \
      SPEC_REPO="$REPO_IN_RUN" \
      SPEC_OUT="$SPEC_OUT" \
      SPEC_FUNCTION="check" \
      SPEC_FIXTURE="$FIXT_IN_RUN" \
      CODE_PATH="$CODE_IN_RUN" \
      HALMOS_VERIFY="$RUN/halmos-verify.sh" \
      "$AGENTIS" go symbolic-prover.ag --enable-exec --enable-messaging --grant-pii ) >"$CELL_LOG" 2>&1 || \
      echo "run-symbolic.sh: symbolic-prover run failed for '$CFN' (see $CELL_LOG)" >&2

  # The prover's contract: exactly one `SYMBOLIC|<file:fn>|<verdict>` line. Take the LAST match. No line
  # at all = treat as HARNESS_ERROR (the run did not even produce a verdict).
  VLINE="$(grep 'SYMBOLIC|' "$CELL_LOG" | tail -1 || true)"
  if [ -z "$VLINE" ]; then
    VERD="HARNESS_ERROR"
  else
    VERD="$(printf '%s' "$VLINE" | sed 's/.*SYMBOLIC|//' | cut -d'|' -f2)"
  fi
  case "$VERD" in
    PROVED)         PROVED=$((PROVED + 1)) ;;
    COUNTEREXAMPLE) CEX=$((CEX + 1)) ;;
    INCONCLUSIVE)   INCONC=$((INCONC + 1)) ;;
    *)              VERD="HARNESS_ERROR"; ERR=$((ERR + 1)) ;;
  esac
  SPEC_KIND="generated(LLM)"; [ -n "$FIXT_IN_RUN" ] && SPEC_KIND="fixture"
  printf '| %s | %s | %s | %s |\n' "$CFN" "$CLS" "$SPEC_KIND" "$VERD" >> "$REPORT"
done < "$CANDS"

{
  echo
  echo "---"
  echo "Checked: $CHECKED    PROVED (safe): $PROVED    COUNTEREXAMPLE (confirmed bug): $CEX    INCONCLUSIVE: $INCONC    HARNESS_ERROR: $ERR"
} >> "$REPORT"

echo >&2
echo "================ SYMBOLIC: $CHECKED checked, $PROVED proved, $CEX counterexample, $INCONC inconclusive, $ERR error ================" >&2
echo "run-symbolic.sh: verdicts at $REPORT" >&2
if [ "$CEX" -gt 0 ]; then
  echo "run-symbolic.sh: $CEX candidate(s) CONFIRMED by a Halmos counterexample — a human reviews each before any submission. This colony never posts." >&2
else
  echo "run-symbolic.sh: no counterexample — nothing was confirmed as a bug by the solver. Nothing submitted." >&2
fi
