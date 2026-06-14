#!/usr/bin/env bash
# run-invariant-hunt.sh — STATEFUL-INVARIANT-FUZZING entrypoint for the Dark Factory federation (#1035).
#
# The LLM is the HYPOTHESIS GENERATOR; the FUZZER is the JUDGE. For a target this script runs
# `auditor/agents/invariant-prover.ag` once on the agentis substrate: it env-ins the target (file:fn + class)
# and the contract source, GENERATES a Foundry stateful-invariant test (a `Handler` exposing the protocol's
# actions as bounded actor functions + a set of DEEP `invariant_*` properties; verbatim from a supplied
# HANDLER_FIXTURE on the offline path, or via `prompt()` on the live path), VERIFIES it by driving Foundry's
# built-in stateful invariant fuzzer through `evm-harness/forge-invariant.sh`, and `print`s an
# `INVARIANT|<target>|<verdict>` line whose verdict is the FUZZER's exit code — never the LLM's opinion. On a
# FINDING it also prints the SHRUNK exploit call-sequence (the reproducible witness). Every run is recorded as
# experience (`learn` + `emit dark-factory:invariant_verdict`) so invariant-prover fitness reweights over
# targets. It mirrors run-symbolic.sh's per-target substrate loop; the difference is the verdict's SOURCE —
# stateful fuzzing over call SEQUENCES, the tool built for the multi-step bug a single-function audit misses.
#
# A FINDING is a CANDIDATE the fuzzer reproduced — still a LEAD a human triages, NEVER auto-submitted. CLEAN
# means every deep invariant held across the fuzzed search (no finding in this budget, not a proof). A
# HARNESS_ERROR (the test did not compile, no invariant matched, or forge is absent) is not a verdict. As
# everywhere in this colony, submission stays an explicit, human-gated action and this tool NEVER posts to a
# bounty platform.
#
# Usage:
#   run-invariant-hunt.sh --repo <foundry project> --target <Contract.sol[:Name]> [options]
#
# Options:
#   --repo <dir>         Foundry project root (must hold foundry.toml). REQUIRED — the test is built here.
#   --target <C.sol[:Name]>  Target contract label (the lens), e.g. "Vault.sol:Vault". REQUIRED.
#   --class <id>         The bug class id the target is filed under, e.g. "C-erc4626" ("" if unknown).
#   --handler-fixture <file>  Ready-made invariant `*.t.sol` used VERBATIM (the offline/deterministic path —
#                        NO LLM). When set the verdict is the fuzzer's over THIS test. Omit = live (LLM) path.
#   --code <file>        Path to the target contract source the LLM reads to write the handler (live path).
#                        Defaults to <repo>/src/<Contract.sol> when omitted and a fixture is NOT supplied.
#   --match <prefix>     Invariant function-name prefix the fuzzer runs (default "invariant").
#   --backend <mock|flat-cyborg|claude>  LLM backend for the live generation path (default: flat-cyborg =
#                        flat-rate PTY wrapper; claude = metered -p API; mock = offline wiring smoke). On the
#                        offline path (a HANDLER_FIXTURE) the LLM is NOT called.
#   --model <id>         Optional model id (claude: passed to the CLI; flat-cyborg: set as llm.model).
#   --runs N             Forge invariant runs budget (search width). Default: the project's [invariant] config.
#   --depth D            Forge invariant depth budget (calls per sequence). Default: the project's config.
#   --seed S             Forge --fuzz-seed for a reproducible search. Default: forge's own seed.
#   --out <dir>          Output dir for the run + report (default: ./invariant-out).
#   --agentis <bin>      agentis binary (default: `agentis` on PATH).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
REPO="" ; TARGET="" ; CLASS="" ; FIXTURE="" ; CODE="" ; MATCH="invariant"
BACKEND="flat-cyborg" ; MODEL="" ; RUNS="" ; DEPTH="" ; SEED="" ; OUT="$PWD/invariant-out"

need() { [ "$1" -ge 2 ] || { echo "run-invariant-hunt.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$#"; REPO="$2"; shift 2 ;;
    --target) need "$#"; TARGET="$2"; shift 2 ;;
    --class) need "$#"; CLASS="$2"; shift 2 ;;
    --handler-fixture) need "$#"; FIXTURE="$2"; shift 2 ;;
    --code) need "$#"; CODE="$2"; shift 2 ;;
    --match) need "$#"; MATCH="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --model) need "$#"; MODEL="$2"; shift 2 ;;
    --runs) need "$#"; RUNS="$2"; shift 2 ;;
    --depth) need "$#"; DEPTH="$2"; shift 2 ;;
    --seed) need "$#"; SEED="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-invariant-hunt.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "run-invariant-hunt.sh: --repo <foundry project root> required" >&2; exit 2; }
[ -f "$REPO/foundry.toml" ] || { echo "run-invariant-hunt.sh: --repo is not a foundry project (no foundry.toml): $REPO" >&2; exit 2; }
[ -n "$TARGET" ] || { echo "run-invariant-hunt.sh: --target <Contract.sol[:Name]> required" >&2; exit 2; }
[ -n "$MATCH" ] || { echo "run-invariant-hunt.sh: --match prefix must be non-empty" >&2; exit 2; }
for v in "$RUNS" "$DEPTH" "$SEED"; do
  case "$v" in '') ;; *[!0-9]*) echo "run-invariant-hunt.sh: --runs/--depth/--seed must be whole numbers" >&2; exit 2 ;; esac
done
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-invariant-hunt.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

# Resolve operator paths to ABSOLUTE — the colony runs from the rundir (a different cwd) and the exec sandbox
# cannot read $HOME, so a relative or home-rooted path would silently read empty. We build the test inside the
# rundir's copy of --repo so the sandbox can always reach it.
REPO="$(cd "$REPO" && pwd)"
if [ -n "$FIXTURE" ]; then
  [ -f "$FIXTURE" ] || { echo "run-invariant-hunt.sh: --handler-fixture not found: $FIXTURE" >&2; exit 2; }
  FIXTURE="$(cd "$(dirname "$FIXTURE")" && pwd)/$(basename "$FIXTURE")"
fi
# Default the code path to <repo>/src/<Contract.sol> on the live path (the LLM reads it to write the handler).
if [ -z "$FIXTURE" ] && [ -z "$CODE" ]; then
  _c="${TARGET%%:*}"
  [ -f "$REPO/src/$_c" ] && CODE="$REPO/src/$_c"
fi
if [ -n "$CODE" ]; then
  [ -f "$CODE" ] || { echo "run-invariant-hunt.sh: --code not found: $CODE" >&2; exit 2; }
  CODE="$(cd "$(dirname "$CODE")" && pwd)/$(basename "$CODE")"
fi

PROVER="$HERE/auditor/agents/invariant-prover.ag"
GATE="$HERE/evm-harness/forge-invariant.sh"
[ -f "$PROVER" ] || { echo "run-invariant-hunt.sh: invariant-prover agent not found at $PROVER" >&2; exit 3; }
[ -f "$GATE" ] || { echo "run-invariant-hunt.sh: forge-invariant gate not found at $GATE" >&2; exit 3; }

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$PROVER" "$RUN/invariant-prover.ag"
cp "$GATE" "$RUN/forge-invariant.sh"
# Stage a fresh copy of the foundry project into the rundir so the sandboxed exec sh can write the test into
# its test/ dir and run forge there (it cannot reach a $HOME-rooted --repo). Drop any pre-existing *.t.sol so
# the generated test is the ONLY one the fuzzer scopes to.
REPO_IN_RUN="$RUN/repo"
cp -R "$REPO" "$REPO_IN_RUN"
rm -f "$REPO_IN_RUN/test/"*.t.sol 2>/dev/null || true
mkdir -p "$REPO_IN_RUN/test"

# Stage the (optional) fixture + code into the rundir so the sandboxed reader can reach them.
FIXTURE_IN_RUN=""
if [ -n "$FIXTURE" ]; then
  cp "$FIXTURE" "$RUN/handler-fixture.t.sol"
  FIXTURE_IN_RUN="$RUN/handler-fixture.t.sol"
fi
CODE_IN_RUN=""
if [ -n "$CODE" ]; then
  cp "$CODE" "$RUN/target-code.sol"
  CODE_IN_RUN="$RUN/target-code.sol"
fi

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  # 600s: writing a stateful-invariant handler for a real protocol is the same order of cost as a discovery read.
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p${MODEL:+ --model $MODEL}"; echo "llm.cli_timeout_ms = 600000"; }
  [ "$BACKEND" = "flat-cyborg" ] && { echo "llm.cli_timeout_ms = 600000"; [ -n "$MODEL" ] && echo "llm.model = $MODEL"; }
  echo "trace.level = normal"
  # The prover reads code + the fixture and writes/runs the test through exec sh; pass its whole env contract.
  echo "exec.env_passthrough = TARGET_FN,TARGET_CLASS,INV_REPO,INV_OUT,INV_MATCH,HANDLER_FIXTURE,CODE_PATH,INV_RUNS,INV_DEPTH,INV_SEED,FORGE_INVARIANT"
  # A forge invariant run (build + a few hundred fuzzed sequences) far exceeds the 10s default.
  echo "exec.default_timeout_ms = 600000"
  # Each verify is recorded as experience; invariant-prover fitness reweights over targets.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

SLUG="$(printf '%s' "$TARGET" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
INV_OUT="$REPO_IN_RUN/test/Inv_${SLUG}.t.sol"
CELL_LOG="$RUN/invariant_${SLUG}.log"

echo "run-invariant-hunt.sh: generating + stateful-fuzzing $TARGET ($CLASS) ..." >&2
( cd "$RUN" && env \
    TARGET_FN="$TARGET" \
    TARGET_CLASS="$CLASS" \
    INV_REPO="$REPO_IN_RUN" \
    INV_OUT="$INV_OUT" \
    INV_MATCH="$MATCH" \
    HANDLER_FIXTURE="$FIXTURE_IN_RUN" \
    CODE_PATH="$CODE_IN_RUN" \
    INV_RUNS="$RUNS" \
    INV_DEPTH="$DEPTH" \
    INV_SEED="$SEED" \
    FORGE_INVARIANT="$RUN/forge-invariant.sh" \
    "$AGENTIS" go invariant-prover.ag --enable-exec --enable-messaging ) >"$CELL_LOG" 2>&1 || \
    echo "run-invariant-hunt.sh: invariant-prover run failed for '$TARGET' (see $CELL_LOG)" >&2

# The prover's contract: exactly one `INVARIANT|<file:fn>|<verdict>` line, then (on a FINDING) `STEP|...`
# lines. Take the LAST verdict match. No line at all = treat as HARNESS_ERROR (no verdict was produced).
VLINE="$(grep 'INVARIANT|' "$CELL_LOG" | tail -1 || true)"
if [ -z "$VLINE" ]; then
  VERD="HARNESS_ERROR"
else
  VERD="$(printf '%s' "$VLINE" | sed 's/.*INVARIANT|//' | cut -d'|' -f2)"
fi
case "$VERD" in
  FINDING|CLEAN|HARNESS_ERROR) ;;
  *) VERD="HARNESS_ERROR" ;;
esac
# Collect the shrunk exploit sequence (the STEP| lines) the prover printed on a FINDING.
STEPS="$(grep '^STEP|' "$CELL_LOG" | sed 's/^STEP|//' || true)"

GEN_KIND="generated(LLM)"; [ -n "$FIXTURE_IN_RUN" ] && GEN_KIND="fixture"

REPORT="$OUT/invariant-report.md"
{
  echo "# Dark Factory — stateful-invariant-fuzzing verdicts"
  echo
  echo "- backend: $BACKEND"
  echo "- The LLM HYPOTHESIZES (writes the handler + the deep invariants); the FUZZER JUDGES (the verdict is"
  echo "  its exit code over randomized multi-call sequences, never the LLM's opinion). FINDING = an invariant"
  echo "  broke under a concrete SHRUNK call-sequence (a CANDIDATE with a reproducible witness); CLEAN = every"
  echo "  invariant held across the fuzzed search (no finding in this budget, NOT a proof); HARNESS_ERROR is"
  echo "  not a verdict. A FINDING is a LEAD a human triages — this colony NEVER auto-submits."
  echo
  echo "| Target | Class | Handler | Verdict |"
  echo "|---|---|---|---|"
  printf '| %s | %s | %s | %s |\n' "$TARGET" "$CLASS" "$GEN_KIND" "$VERD"
  echo
  if [ "$VERD" = "FINDING" ] && [ -n "$STEPS" ]; then
    echo "## Shrunk exploit call-sequence (the fuzzer's reproducible witness)"
    echo
    echo '```'
    printf '%s\n' "$STEPS"
    echo '```'
    echo
    echo "A human triages this candidate before any submission. This colony never posts."
  fi
} > "$REPORT"

echo >&2
echo "================ INVARIANT-HUNT: $TARGET -> $VERD ================" >&2
echo "run-invariant-hunt.sh: verdict + any witness at $REPORT" >&2
if [ "$VERD" = "FINDING" ]; then
  echo "run-invariant-hunt.sh: a multi-step invariant was BROKEN — the shrunk exploit sequence is a reproducible witness a human triages. This colony never auto-submits." >&2
elif [ "$VERD" = "CLEAN" ]; then
  echo "run-invariant-hunt.sh: every deep invariant held across the fuzzed search — no finding in this budget (not a proof of safety). Nothing to triage." >&2
else
  echo "run-invariant-hunt.sh: HARNESS_ERROR — the test did not compile / no invariant matched / forge absent. No verdict was produced." >&2
fi
