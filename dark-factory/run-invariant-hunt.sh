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
#   --fork-url <rpc>     FM1 (#1041): an http(s) RPC to FORK from — the handler + deep invariants run against
#                        FORKED REAL ON-CHAIN STATE (the actual deployed contract) instead of a fresh deploy.
#                        Threaded into the gate's `--fork-url`; also exported to the prover so the generated
#                        handler/invariant can reference the deployed contract by address. Absent => no fork
#                        (byte-identical to today). A fork RPC failure -> HARNESS_ERROR, never a false verdict.
#   --fork-block <n>     FM1 (#1041): pin the fork to a block number for REPRODUCIBILITY (requires --fork-url).
#   --fork-target <spec> FM1/FM2 (#1041): a deployed contract the generated test should drive. REPEATABLE. Two
#                        forms:
#                          * FM1 shorthand `--fork-target <addr>` (a bare 0x-address, no '=') — the single
#                            target the prover references as FORK_TARGET (the proven POC shape).
#                          * FM2 composability `--fork-target '<role>=<addr>'` — a ROLE in a CONTEXT SET of
#                            deployed contracts the handler may compose calls ACROSS (role in {target, dex,
#                            flashloan, oracle, ...}). Roles are charset [a-z0-9_]; each address is 0x + 40 hex.
#                            The whole set is exported to the prover as FORK_CONTEXT (a semicolon-separated
#                            `role=addr` list) so the generation prompt can model a flashloan-funded attacker
#                            who moves price via the dex and checks the TARGET's solvency after the cross-
#                            contract sequence. The `target` role still also sets FORK_TARGET (FM1 compat).
#                        Absent any role beyond `target` => FM1 behaviour byte-identical. Optional; "" leaves it
#                        to the test. A --fork-target does NOT require --fork-url (the context contracts may be
#                        deployed locally by the test — composability is orthogonal to fork; the two COMPOSE).
#   --repair-rounds N    #1073: number of EXTRA bounded compile-repair rounds the prover runs when its FIRST
#                        LLM-generated test does NOT compile / matches no invariant (a HARNESS_ERROR on the LLM
#                        path). On each round the prover feeds forge's compiler error back to the model and
#                        regenerates, then re-runs the gate; it STOPS the moment the gate returns a verdict
#                        (FINDING/CLEAN). Default 2 (so <=3 total attempts). 0 disables repair (one shot). The
#                        verbatim HANDLER_FIXTURE path is NEVER repaired. Exported to the prover as
#                        INV_REPAIR_ROUNDS; omitted => the prover's own default (2) applies.
#   --out <dir>          Output dir for the run + report (default: ./invariant-out).
#   --pattern-store <dir>  Int M3 (#1037): a PERSISTENT pattern-DAG store reused ACROSS runs. When set, the
#                        winning-invariant patterns the prover PERSISTS on a FINDING (`invpat:*` memos) are
#                        kept here, and any patterns a PRIOR run stored for the same bug class are RECALLED
#                        into THIS run before GENERATE — so a later hunt on the same class is seeded by an
#                        earlier hunt's confirmed invariant shape (discovered -> stored -> recalled -> reused).
#                        Absent the flag the per-run store is ephemeral -> no cross-run pattern memory (the
#                        M1/M2 behaviour is byte-identical).
#   --agentis <bin>      agentis binary (default: `agentis` on PATH).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
REPO="" ; TARGET="" ; CLASS="" ; FIXTURE="" ; CODE="" ; MATCH="invariant"
BACKEND="flat-cyborg" ; MODEL="" ; RUNS="" ; DEPTH="" ; SEED="" ; OUT="$PWD/invariant-out" ; PATTERN_STORE=""
REPAIR_ROUNDS=""  # #1073: extra compile-repair rounds; "" => the prover's own default (2)
FORK_URL="" ; FORK_BLOCK="" ; FORK_TARGET=""
# FM2 (#1041): the composability context set — one `--fork-target '<role>=<addr>'` per array slot. A bare
# `--fork-target <addr>` (FM1 shorthand, no '=') is normalised to a `target=<addr>` slot below.
FORK_TARGET_SPECS=()

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
    --repair-rounds) need "$#"; REPAIR_ROUNDS="$2"; shift 2 ;;
    --fork-url) need "$#"; FORK_URL="$2"; shift 2 ;;
    --fork-block) need "$#"; FORK_BLOCK="$2"; shift 2 ;;
    --fork-target) need "$#"; FORK_TARGET_SPECS+=("$2"); shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --pattern-store) need "$#"; PATTERN_STORE="$2"; shift 2 ;;
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
# #1073: --repair-rounds must be a whole number when set (a non-numeric value would silently fall back to the
# prover's default; reject it here so an operator typo surfaces).
case "$REPAIR_ROUNDS" in '') ;; *[!0-9]*) echo "run-invariant-hunt.sh: --repair-rounds must be a whole number" >&2; exit 2 ;; esac
# FM1 (#1041): fork-arg shape validation (mirrors the gate's). --fork-url must look like an http(s) URL,
# --fork-block a whole number requiring --fork-url.
case "$FORK_URL" in
  '') ;;
  http://*|https://*) ;;
  *) echo "run-invariant-hunt.sh: --fork-url must be an http(s) URL (got: $FORK_URL)" >&2; exit 2 ;;
esac
case "$FORK_BLOCK" in '') ;; *[!0-9]*) echo "run-invariant-hunt.sh: --fork-block must be a whole number" >&2; exit 2 ;; esac
[ -z "$FORK_BLOCK" ] || [ -n "$FORK_URL" ] || { echo "run-invariant-hunt.sh: --fork-block requires --fork-url" >&2; exit 2; }

# FM2 (#1041): resolve the repeatable --fork-target specs into the FORK_CONTEXT role->address set and the
# FM1 FORK_TARGET single-address. Each spec is either `<role>=<addr>` (a context role) or a bare `<addr>`
# (FM1 shorthand, normalised to role `target`). Validate each address (0x + 40 hex) and role ([a-z0-9_]) so a
# malformed value is a clean usage error here, never an opaque forge failure. A role may not repeat. The
# encoding exported to the prover is a semicolon-separated `role=addr` list (parse-safe: no metachar in either
# field after validation). Absent any role beyond `target`, FORK_CONTEXT carries only `target` (or is empty)
# and the prover's FM1 prompt is byte-identical (the composability extension fires only on >1 role).
FORK_CONTEXT=""
fork_ctx_has_role() {  # $1 = role -> 0 if FORK_CONTEXT already carries `<role>=`
  case ";$FORK_CONTEXT;" in *";$1="*) return 0 ;; *) return 1 ;; esac
}
for spec in ${FORK_TARGET_SPECS+"${FORK_TARGET_SPECS[@]}"}; do
  case "$spec" in
    *=*) _role="${spec%%=*}"; _addr="${spec#*=}" ;;
    *)   _role="target"; _addr="$spec" ;;
  esac
  case "$_role" in
    '' ) echo "run-invariant-hunt.sh: --fork-target role must be non-empty (got: $spec)" >&2; exit 2 ;;
    *[!a-z0-9_]*) echo "run-invariant-hunt.sh: --fork-target role must match [a-z0-9_] (got: $_role)" >&2; exit 2 ;;
  esac
  case "$_addr" in
    0x*) _hex="${_addr#0x}"; case "$_hex" in *[!0-9a-fA-F]*) _bad=1 ;; *) [ "${#_hex}" -eq 40 ] && _bad=0 || _bad=1 ;; esac ;;
    *) _bad=1 ;;
  esac
  [ "${_bad:-1}" -eq 0 ] || { echo "run-invariant-hunt.sh: --fork-target address must be 0x + 40 hex (got: $_addr)" >&2; exit 2; }
  fork_ctx_has_role "$_role" && { echo "run-invariant-hunt.sh: --fork-target role '$_role' given more than once" >&2; exit 2; }
  if [ -z "$FORK_CONTEXT" ]; then FORK_CONTEXT="$_role=$_addr"; else FORK_CONTEXT="$FORK_CONTEXT;$_role=$_addr"; fi
  [ "$_role" = "target" ] && FORK_TARGET="$_addr"
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
  # FM1 (#1041): FORK_URL/FORK_BLOCK thread the fork into the gate; FORK_TARGET is the deployed address the
  # generated handler/invariant references against the forked state. FM2 (#1041): FORK_CONTEXT carries the
  # role->address context set so the generation prompt can compose calls across the deployed protocols.
  echo "exec.env_passthrough = TARGET_FN,TARGET_CLASS,INV_REPO,INV_OUT,INV_MATCH,HANDLER_FIXTURE,CODE_PATH,INV_RUNS,INV_DEPTH,INV_SEED,FORGE_INVARIANT,FORK_URL,FORK_BLOCK,FORK_TARGET,FORK_CONTEXT,INV_REPAIR_ROUNDS"
  # A forge invariant run (build + a few hundred fuzzed sequences) far exceeds the 10s default.
  echo "exec.default_timeout_ms = 600000"
  # Each verify is recorded as experience; invariant-prover fitness reweights over targets.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

SLUG="$(printf '%s' "$TARGET" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
INV_OUT="$REPO_IN_RUN/test/Inv_${SLUG}.t.sol"
CELL_LOG="$RUN/invariant_${SLUG}.log"

# Int M3 (#1037): the PERSISTENT pattern-DAG store. When --pattern-store is set we resolve it to an
# absolute path and `agentis init` it once (idempotent — re-init of an existing store is a no-op for our
# memos). It holds the `invpat:*` memos ACROSS runs. The per-run store above is still ephemeral (wiped each
# run); the bridge below moves patterns IN before the run (so RECALL sees a prior run's confirmed shapes)
# and OUT after (so this run's FINDING is kept for the next). Absent the flag, $PATTERN_STORE stays empty and
# the whole bridge is skipped -> no cross-run memory (M1/M2 byte-identical).
if [ -n "$PATTERN_STORE" ]; then
  mkdir -p "$PATTERN_STORE"; PATTERN_STORE="$(cd "$PATTERN_STORE" && pwd)"
  [ -d "$PATTERN_STORE/.agentis" ] || ( cd "$PATTERN_STORE" && "$AGENTIS" init >/dev/null 2>&1 )
fi

# Bridge every `invpat:*` memo from $1's store into $2's store via the agentis memo CLI. The DAG content
# HASH is deterministic (sha256 of the signature), so only the memo VALUES need to travel between stores —
# `recall_latest("invpat:latest:<class>")` is what the prover reads to seed GENERATE, and re-`dag_put`ting
# the same signature reproduces the same `invpat:exact:<hash>` key locally. memo keys are restricted to a
# safe charset upstream, so no key here can carry a shell metachar.
bridge_invpat() {  # $1 = src store dir, $2 = dst store dir
  _src="$1"; _dst="$2"
  ( cd "$_src" && "$AGENTIS" memo list 2>/dev/null ) | awk '{print $1}' | grep -E '^invpat:' | while IFS= read -r k; do
    _v="$( ( cd "$_src" && "$AGENTIS" memo get "$k" ) 2>/dev/null )"
    [ -n "$_v" ] && ( cd "$_dst" && "$AGENTIS" memo set "$k" "$_v" >/dev/null 2>&1 )
  done
}

# RECALL: seed the per-run store with any patterns a PRIOR run persisted, BEFORE `agentis go` (so the
# prover's recall_pattern() sees them and folds them into GENERATE).
if [ -n "$PATTERN_STORE" ]; then
  bridge_invpat "$PATTERN_STORE" "$RUN"
fi

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
    INV_REPAIR_ROUNDS="$REPAIR_ROUNDS" \
    FORK_URL="$FORK_URL" \
    FORK_BLOCK="$FORK_BLOCK" \
    FORK_TARGET="$FORK_TARGET" \
    FORK_CONTEXT="$FORK_CONTEXT" \
    FORGE_INVARIANT="$RUN/forge-invariant.sh" \
    "$AGENTIS" go invariant-prover.ag --enable-exec --enable-messaging ) >"$CELL_LOG" 2>&1 || \
    echo "run-invariant-hunt.sh: invariant-prover run failed for '$TARGET' (see $CELL_LOG)" >&2

# PERSIST: copy any `invpat:*` the prover wrote this run (on a FINDING) back OUT to the persistent store,
# so the NEXT run on the same class recalls it. Skipped (no-op) when --pattern-store was not supplied.
if [ -n "$PATTERN_STORE" ]; then
  bridge_invpat "$RUN" "$PATTERN_STORE"
fi

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
