#!/usr/bin/env bash
# run-poc.sh — CONCRETE-EXPLOIT-PoC entrypoint for the Dark Factory federation (#1507).
#
# The SECOND PoC class alongside run-invariant-hunt.sh. Where the invariant hunt writes a stateful-invariant
# HANDLER and lets the fuzzer JUDGE over sequences, this runs `auditor/agents/poc-writer.ag` once on the agentis
# substrate to GENERATE a single CONCRETE attack-SEQUENCE test that reproduces one specific bug HYPOTHESIS
# end-to-end, then VERIFIES it through the toolchain-parametric gate (evm-harness/hardhat-poc.sh for a hardhat
# project, evm-harness/forge-poc.sh for a foundry one — chosen by evm-harness/detect-toolchain.sh over --repo).
# It prints a `POC|<target>|<verdict>` line whose verdict is the GATE's exit code — never the LLM's opinion.
#
# INVERTED POLARITY: a concrete PoC is written to PASS iff the exploit works, so a PASSING test is a FINDING
# (the exploit reproduced -> a CANDIDATE), a FAILING test is CLEAN (refuted), and a compile/tooling error or a
# #1471 linkage reject is HARNESS_ERROR (not a verdict). The inversion lives in the gate, not here.
#
# A FINDING is a CANDIDATE the PoC reproduced — still a LEAD a human triages, NEVER auto-submitted. This tool
# NEVER posts to a bounty platform. It deliberately does NOT reimplement pattern-store / fork / composability /
# aux staging (those stay invariant-only); a concrete exploit is a single deploy.
#
# Usage:
#   run-poc.sh --repo <hardhat-or-foundry-project> --target <Contract.sol[:Name]> --hypothesis "<attack>" [options]
#
# Options:
#   --repo <dir>          Project root (hardhat.config.* => hardhat PoC; foundry.toml => foundry PoC). REQUIRED.
#   --target <C.sol[:Name]>  Target contract label (the lens), e.g. "Vault.sol:Vault". REQUIRED.
#   --hypothesis <text>   The concrete attack-SEQUENCE hypothesis to reproduce (free-form prose). REQUIRED unless
#                         --poc-fixture is given (the offline path needs no hypothesis).
#   --class <id>          The bug class id the target is filed under (e.g. "C-erc4626"; "" if unknown).
#   --kind <hardhat|foundry>  Override the auto-detected toolchain (default: detect-toolchain.sh over --repo).
#   --poc-fixture <file>  A ready-made PoC test used VERBATIM (the offline/deterministic path — NO LLM).
#   --code <file>         Path to the target contract source the LLM reads + that arms the #1471 linkage gate.
#                         Defaults to <repo>/<file> then <repo>/src|contracts/<file> when omitted (live path).
#   --fixtures-dir <dir>  Path to the target's OWN test fixtures/deploy helpers the prompt should reuse.
#   --match <prefix>      Foundry test-fn prefix (default "test"; ignored by the hardhat gate).
#   --backend <mock|flat-cyborg|claude>  LLM backend for the live path (default flat-cyborg). Offline (fixture)
#                         => the LLM is NOT called.
#   --model <id>          Optional model id (claude: passed to the CLI; flat-cyborg: set as llm.model).
#   --repair-rounds N     Extra bounded compile-repair rounds (default: the agent's own default, 2).
#   --out <dir>           Output dir for the run + report (default: ./poc-out).
#   --agentis <bin>       agentis binary (default: `agentis` on PATH).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
REPO="" ; TARGET="" ; HYPOTHESIS="" ; CLASS="" ; KIND="" ; FIXTURE="" ; CODE="" ; FIXTURES_DIR=""
MATCH="test" ; BACKEND="flat-cyborg" ; MODEL="" ; REPAIR_ROUNDS="" ; OUT="$PWD/poc-out"

need() { [ "$1" -ge 2 ] || { echo "run-poc.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$#"; REPO="$2"; shift 2 ;;
    --target) need "$#"; TARGET="$2"; shift 2 ;;
    --hypothesis) need "$#"; HYPOTHESIS="$2"; shift 2 ;;
    --class) need "$#"; CLASS="$2"; shift 2 ;;
    --kind) need "$#"; KIND="$2"; shift 2 ;;
    --poc-fixture) need "$#"; FIXTURE="$2"; shift 2 ;;
    --code) need "$#"; CODE="$2"; shift 2 ;;
    --fixtures-dir) need "$#"; FIXTURES_DIR="$2"; shift 2 ;;
    --match) need "$#"; MATCH="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --model) need "$#"; MODEL="$2"; shift 2 ;;
    --repair-rounds) need "$#"; REPAIR_ROUNDS="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-poc.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "run-poc.sh: --repo <project root> required" >&2; exit 2; }
[ -n "$TARGET" ] || { echo "run-poc.sh: --target <Contract.sol[:Name]> required" >&2; exit 2; }
[ -n "$MATCH" ] || { echo "run-poc.sh: --match prefix must be non-empty" >&2; exit 2; }
[ -n "$HYPOTHESIS" ] || [ -n "$FIXTURE" ] || { echo "run-poc.sh: --hypothesis is required on the live path (or supply --poc-fixture)" >&2; exit 2; }
case "$REPAIR_ROUNDS" in '') ;; *[!0-9]*) echo "run-poc.sh: --repair-rounds must be a whole number" >&2; exit 2 ;; esac
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-poc.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

DETECT="$HERE/evm-harness/detect-toolchain.sh"
[ -f "$DETECT" ] || { echo "run-poc.sh: detect-toolchain.sh not found at $DETECT" >&2; exit 3; }

# Resolve --repo to ABSOLUTE — the colony runs from the rundir (a different cwd) and the exec sandbox cannot read
# $HOME, so a relative / home-rooted path would silently read empty. We build the test inside the rundir's copy.
REPO="$(cd "$REPO" && pwd)"

# Choose the toolchain: an explicit --kind wins; otherwise detect-toolchain.sh over --repo.
if [ -z "$KIND" ]; then
  KIND="$(bash "$DETECT" "$REPO" 2>/dev/null || true)"
fi
case "$KIND" in
  hardhat) GATE="$HERE/evm-harness/hardhat-poc.sh" ;;
  foundry) GATE="$HERE/evm-harness/forge-poc.sh" ;;
  *) echo "run-poc.sh: could not determine toolchain for $REPO (no hardhat.config.* or foundry.toml); pass --kind hardhat|foundry" >&2; exit 2 ;;
esac
[ -f "$GATE" ] || { echo "run-poc.sh: PoC gate not found at $GATE" >&2; exit 3; }

PROVER="$HERE/auditor/agents/poc-writer.ag"
[ -f "$PROVER" ] || { echo "run-poc.sh: poc-writer agent not found at $PROVER" >&2; exit 3; }

# Resolve optional paths to ABSOLUTE + stage them into the rundir (the sandboxed reader cannot reach $HOME).
if [ -n "$FIXTURE" ]; then
  [ -f "$FIXTURE" ] || { echo "run-poc.sh: --poc-fixture not found: $FIXTURE" >&2; exit 2; }
  FIXTURE="$(cd "$(dirname "$FIXTURE")" && pwd)/$(basename "$FIXTURE")"
fi
# Default the code path to the target source the LLM reads (live path). The `--target` FILE part may be a full
# repo-relative path OR the bare convention name; try `<repo>/<file>`, then `<repo>/src/<file>` (foundry) and
# `<repo>/contracts/<file>` (hardhat).
if [ -z "$FIXTURE" ] && [ -z "$CODE" ]; then
  _c="${TARGET%%:*}"
  if [ -f "$REPO/$_c" ]; then CODE="$REPO/$_c"
  elif [ -f "$REPO/src/$_c" ]; then CODE="$REPO/src/$_c"
  elif [ -f "$REPO/contracts/$_c" ]; then CODE="$REPO/contracts/$_c"
  fi
fi
if [ -n "$CODE" ]; then
  [ -f "$CODE" ] || { echo "run-poc.sh: --code not found: $CODE" >&2; exit 2; }
  CODE="$(cd "$(dirname "$CODE")" && pwd)/$(basename "$CODE")"
fi
if [ -n "$FIXTURES_DIR" ]; then
  [ -d "$FIXTURES_DIR" ] || { echo "run-poc.sh: --fixtures-dir not found: $FIXTURES_DIR" >&2; exit 2; }
  FIXTURES_DIR="$(cd "$FIXTURES_DIR" && pwd)"
fi

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$PROVER" "$RUN/poc-writer.ag"
cp "$HERE/evm-harness/hardhat-poc.sh" "$RUN/hardhat-poc.sh"
cp "$HERE/evm-harness/forge-poc.sh"   "$RUN/forge-poc.sh"
GATE_IN_RUN="$RUN/$(basename "$GATE")"

# Stage a fresh copy of the project into the rundir so the sandboxed exec sh can write the test into its test/
# dir and run the toolchain there. Drop any pre-existing PoC test so the generated one is the ONLY one run.
REPO_IN_RUN="$RUN/repo"
cp -R "$REPO" "$REPO_IN_RUN"
mkdir -p "$REPO_IN_RUN/test"

# Stage the (optional) fixture + code so the sandboxed reader can reach them.
FIXTURE_IN_RUN=""
if [ -n "$FIXTURE" ]; then
  case "$KIND" in
    hardhat) cp "$FIXTURE" "$RUN/poc-fixture.test.js"; FIXTURE_IN_RUN="$RUN/poc-fixture.test.js" ;;
    *)       cp "$FIXTURE" "$RUN/poc-fixture.t.sol";   FIXTURE_IN_RUN="$RUN/poc-fixture.t.sol" ;;
  esac
fi
CODE_IN_RUN=""
if [ -n "$CODE" ]; then
  cp "$CODE" "$RUN/target-code.sol"
  CODE_IN_RUN="$RUN/target-code.sol"
fi
FIXTURES_DIR_IN_RUN=""
if [ -n "$FIXTURES_DIR" ]; then
  cp -R "$FIXTURES_DIR" "$RUN/target-fixtures"
  FIXTURES_DIR_IN_RUN="$RUN/target-fixtures"
fi

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  # 600s: writing a concrete exploit PoC for a real protocol is the same order of cost as a discovery read.
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p${MODEL:+ --model $MODEL}"; echo "llm.cli_timeout_ms = 600000"; }
  [ "$BACKEND" = "flat-cyborg" ] && { echo "llm.cli_timeout_ms = 600000"; [ -n "$MODEL" ] && echo "llm.model = $MODEL"; }
  echo "trace.level = normal"
  # The poc-writer reads code + the fixture and writes/runs the test through exec sh; pass its whole env contract.
  echo "exec.env_passthrough = TARGET_FN,TARGET_CLASS,BUG_HYPOTHESIS,POC_KIND,POC_REPO,POC_OUT,POC_HARNESS,POC_FIXTURE,CODE_PATH,TARGET_FIXTURES_DIR,POC_MATCH,POC_REPAIR_ROUNDS"
  # A hardhat npm install + compile + test (or a forge build + concrete run) far exceeds the 10s default.
  echo "exec.default_timeout_ms = 600000"
  # Each verify is recorded as experience; poc-writer fitness reweights over targets.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

SLUG="$(printf '%s' "$TARGET" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
case "$KIND" in
  hardhat) POC_OUT="$REPO_IN_RUN/test/Poc_${SLUG}.poc.test.js" ;;
  *)       POC_OUT="$REPO_IN_RUN/test/Poc_${SLUG}.t.sol" ;;
esac
CELL_LOG="$RUN/poc_${SLUG}.log"

echo "run-poc.sh: generating + verifying a concrete-exploit PoC for $TARGET ($CLASS) [$KIND] ..." >&2
( cd "$RUN" && env \
    TARGET_FN="$TARGET" \
    TARGET_CLASS="$CLASS" \
    BUG_HYPOTHESIS="$HYPOTHESIS" \
    POC_KIND="$KIND" \
    POC_REPO="$REPO_IN_RUN" \
    POC_OUT="$POC_OUT" \
    POC_HARNESS="$GATE_IN_RUN" \
    POC_FIXTURE="$FIXTURE_IN_RUN" \
    CODE_PATH="$CODE_IN_RUN" \
    TARGET_FIXTURES_DIR="$FIXTURES_DIR_IN_RUN" \
    POC_MATCH="$MATCH" \
    POC_REPAIR_ROUNDS="$REPAIR_ROUNDS" \
    "$AGENTIS" go poc-writer.ag --enable-exec --enable-messaging ) >"$CELL_LOG" 2>&1 || \
    echo "run-poc.sh: poc-writer run failed for '$TARGET' (see $CELL_LOG)" >&2

# The agent's contract: exactly one `POC|<target>|<verdict>` line, then (on a FINDING) a `POC-FILE|<path>` line.
# Take the LAST verdict match. No line at all = HARNESS_ERROR (no verdict was produced).
VLINE="$(grep 'POC|' "$CELL_LOG" | grep -v 'POC-FILE|' | tail -1 || true)"
if [ -z "$VLINE" ]; then
  VERD="HARNESS_ERROR"
else
  VERD="$(printf '%s' "$VLINE" | sed 's/.*POC|//' | cut -d'|' -f2)"
fi
case "$VERD" in
  FINDING|CLEAN|HARNESS_ERROR) ;;
  *) VERD="HARNESS_ERROR" ;;
esac
POC_FILE_LINE="$(grep '^POC-FILE|' "$CELL_LOG" | tail -1 | sed 's/^POC-FILE|//' || true)"

# Machine-readable verdict line on our OWN stdout, in the same `PREFIX|VALUE` shape the five .ag gates emit, so
# a caller that scrapes run-poc.sh directly (coordinator.ag::run_poc_live -> poc_class()) can grep the verdict
# without reaching into the throwaway per-run cell log. ADDITIVE (#1535): it does NOT replace the human-facing
# `================ POC: $TARGET -> $VERD ================` banner below (pinned by demo-poc-gen.sh's e2e grep).
echo "POC|$TARGET|$VERD"

GEN_KIND="generated(LLM)"; [ -n "$FIXTURE_IN_RUN" ] && GEN_KIND="fixture"

REPORT="$OUT/poc-report.md"
{
  echo "# Dark Factory — concrete-exploit PoC verdicts"
  echo
  echo "- toolchain: $KIND"
  echo "- backend: $BACKEND"
  echo "- The LLM WRITES a concrete attack-sequence PoC; the GATE JUDGES (the verdict is its exit code — a PoC"
  echo "  test that PASSES means the exploit reproduced = FINDING; a test that FAILED = CLEAN (refuted);"
  echo "  HARNESS_ERROR is not a verdict). A FINDING is a runnable witness a human triages — this colony NEVER"
  echo "  auto-submits."
  echo
  echo "| Target | Class | Kind | PoC | Verdict |"
  echo "|---|---|---|---|---|"
  printf '| %s | %s | %s | %s | %s |\n' "$TARGET" "$CLASS" "$KIND" "$GEN_KIND" "$VERD"
  echo
  if [ "$VERD" = "FINDING" ] && [ -n "$POC_FILE_LINE" ]; then
    echo "## Runnable PoC (the reproducible witness)"
    echo
    echo "\`$POC_FILE_LINE\`"
    echo
    echo "A human triages + runs this candidate before any submission. This colony never posts."
  fi
} > "$REPORT"

echo >&2
echo "================ POC: $TARGET -> $VERD ================" >&2
echo "run-poc.sh: verdict + any PoC path at $REPORT" >&2
if [ "$VERD" = "FINDING" ]; then
  echo "run-poc.sh: the concrete exploit PoC PASSED — a reproducible witness a human triages. This colony never auto-submits." >&2
elif [ "$VERD" = "CLEAN" ]; then
  echo "run-poc.sh: the PoC ran and FAILED — the exploit did not reproduce in this harness. Nothing to triage." >&2
else
  echo "run-poc.sh: HARNESS_ERROR — the PoC did not compile / no test ran / toolchain absent / linkage reject. No verdict." >&2
fi
