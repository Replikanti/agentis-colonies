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
#   --aux <C.sol[:Name]> FM2 (#1075): an AUXILIARY in-scope contract (relative to --repo, like --target) the
#                        prover should ALSO deploy + WIRE alongside the target so the generated handler can
#                        compose calls ACROSS the system (the FRESH-DEPLOY composability path — oracle ->
#                        manager mispricing, reward accrual -> vault share inflation, ...). REPEATABLE. Each
#                        value is validated like --target (exists, is a *.sol) and exported to the prover as
#                        one entry of INV_AUX (a sentinel-joined list of 3-field
#                        `<staged_slim_abs>@@F@@<Name>@@F@@<real_repo_file>` entries (#1926 — field 2 is the aux's
#                        real in-repo file so the harness imports the compilable `../src/<Name>.sol`), entry
#                        sentinel `@@A@@` + field sentinel `@@F@@` — neither can occur in a filesystem path or a
#                        Solidity identifier). No --aux =>
#                        INV_AUX empty => the single-target generation prompt is byte-identical to today. This
#                        is the FRESH-DEPLOY sibling of the FORK-mode --fork-target composability set: --aux
#                        deploys the auxiliaries from SOURCE, --fork-target references them by on-chain address.
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
#   --audit-context <file>  #1722: a target's spec / audit-scope doc. Staged into the rundir and threaded to the
#                        prover as INV_AUDIT_CONTEXT; the prover reads it via the sandboxed cat_file and prepends
#                        an `audit_seed()` block to the generation prompt, steering the LLM to formalize a
#                        protocol-SPECIFIC value-conservation property from the doc instead of only the generic
#                        per-lens default (the #1716 A/B isolated invariant EXPRESSIVENESS, not plumbing, as the
#                        limit). Purely additive: absent the flag the prompt is byte-identical to today. An
#                        unreadable file is a hard usage error (exit 2). Mirrors run-autoharness.sh's FM4 wiring.
#   --out <dir>          Output dir for the run + report (default: ./invariant-out).
#   --pattern-store <dir>  Int M3 (#1037): a PERSISTENT pattern-DAG store reused ACROSS runs. When set, the
#                        winning-invariant patterns the prover PERSISTS on a FINDING (`invpat:*` memos) are
#                        kept here, and any patterns a PRIOR run stored for the same bug class are RECALLED
#                        into THIS run before GENERATE — so a later hunt on the same class is seeded by an
#                        earlier hunt's confirmed invariant shape (discovered -> stored -> recalled -> reused).
#                        Absent the flag the per-run store is ephemeral -> no cross-run pattern memory (the
#                        M1/M2 behaviour is byte-identical).
#   --replay-corpus      #1731: CROSS-RUN ENSEMBLE / UNION replay. Accumulate EVERY generated invariant SOURCE
#                        (on a FINDING OR a CLEAN, not only the winners) under --pattern-store/corpus/<class>/
#                        and, on the NEXT run, REPLAY that accumulated union against the fresh target through
#                        the SAME staged fuzzer gate (pure shell — NO extra agentis spawn, NO LLM per replay) —
#                        re-using the #1471 link gate so a foreign-import replay is HARNESS_ERROR, never a false
#                        verdict. Also threads INV_CORPUS=1 to the prover so it accumulates the descriptor into
#                        the lowest-precedence invpat:corpus:<class> recall tier. REQUIRES --pattern-store (the
#                        corpus lives there). Default OFF => the pipeline is byte-identical to today.
#   --corpus-max N       #1731: cap the cross-run corpus at N most-recent entries per class (default 16). Bounds
#                        BOTH storage (content-addressed dedup + most-recent eviction) AND replay cost. Whole
#                        number, validated like --runs.
#   --symbolic-oracle    #1732: run a COMPLEMENTARY symbolic / bounded-model-checking pass (Halmos, via the
#                        SOUND evm-harness/halmos-verify.sh gate) over the SAME generated invariant test AFTER
#                        the fuzzer has produced its verdict. This is a SECOND, INDEPENDENT oracle — the FUZZER
#                        stays the SOLE primary verdict; the symbolic result is reported separately as a
#                        `SYMBOLIC|<file:fn>|<verdict>` marker + a `## Symbolic oracle (complementary)` report
#                        section and NEVER alters the INVARIANT| verdict or verified_findings.json. The gate is
#                        skipped (a SKIPPED report row, exit-neutral) when halmos/forge are absent or the fuzzer
#                        produced no test, so tool-absence is never a HARNESS_ERROR. Default OFF => byte-identical.
#   --symbolic-timeout S #1732: per-assertion Halmos solver timeout in seconds for the --symbolic-oracle pass
#                        (whole number; "" => the gate's own default 60). No effect without --symbolic-oracle.
#   --core-dep-harness   #1755: CORE-DEPENDENCY harness-gen. For yearn-v3 targets whose ERC4626 share logic lives
#                        in a delegatecall SINGLETON (BaseStrategy -> TokenizedStrategy), auto-detect the signal in
#                        the target source and thread the REAL singleton path into the prover so the generated
#                        harness deploys + `vm.etch`es the actual TokenizedStrategy at 0xD377...9c INSTEAD of a
#                        zero-returning stub — making deposit/mint/withdraw/redeem share accounting genuinely
#                        fuzzable (the first-depositor / share-inflation path). Default OFF => the yearn-v3 signal
#                        is never probed, INV_CORE_DEP stays "" and the pipeline is byte-identical to today. A
#                        non-yearn target under the flag also stays byte-identical (the signal does not fire).
#   --ensemble-candidates <N>  #1778: SINGLE-RUN METAMORPHIC ENSEMBLE. Kill single-draw variance by steering N
#                        DISTINCT relational-invariant VARIANTS (large-vs-small unit-price monotonicity,
#                        before-vs-after holder-price, actor-A-vs-B parity) for a value-custody target — each
#                        fuzzed INDEPENDENTLY through the UNCHANGED gate — then taking an ENSEMBLE-VOTE verdict:
#                        ANY candidate FINDING => FINDING (with that candidate's shrunk witness); else any
#                        HARNESS_ERROR => HARNESS_ERROR; else CLEAN. Each candidate is its own prover generation
#                        (INV_ENSEMBLE_VARIANT="<i>") + its own forge run(s) via the same repair/teeth gate. The
#                        aggregate is emitted as the LAST `INVARIANT|<target>|<verdict>` line so both downstream
#                        consumers (this runner + run-zone-hunt.sh's last-wins adapter) read it unchanged;
#                        per-candidate diagnostics use a `CANDIDATE|` prefix. Default 0 (= OFF); N < 2 or the
#                        offline --handler-fixture path => the single verbatim run (byte-identical to today).
#   --ground-symbols     FM-B (#1939 M2): SYMBOL GROUNDING. Before the prover runs, extract the REAL SYMBOL
#                        INVENTORY (contract/interface/library/struct/enum NAMES + external/public function
#                        signatures) from the STAGED target + aux sources with evm-harness/extract-solidity-
#                        symbols.sh and write it to `$RUN/symbol-inventory.txt`. The prover reads that FIXED
#                        rundir-relative file (NOT a new passthrough env var — chosen to avoid the
#                        exec.env_passthrough exact-string ripple) and folds the inventory into BOTH the first
#                        generation prompt AND every repair round, so the harness references ONLY names that
#                        exist in scope (the Error 7920 "Identifier not found or not unique" the composable-fresh
#                        multi-contract shape hit and survived all repair rounds). Default OFF => the file is NOT
#                        written => the prover's grounding block is empty => the prompts are byte-identical to
#                        today. Source-parsing only (no forge build / network) so it is deterministic in CI.
#   --agentis <bin>      agentis binary (default: `agentis` on PATH).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
# #2038: host-wide forge-subprocess concurrency cap (K=${FORGE_MAX_SLOTS:-2}).
# shellcheck source=lib/forge-slot.sh
# shellcheck disable=SC1091
. "$HERE/lib/forge-slot.sh"
# Backstop: free a held slot on ANY exit path (happy path, error, signal), not
# only the explicit release calls around each forge subprocess below. Safe
# no-op when no slot is held (fail-open path, or a run that never reached a
# forge call).
trap release_forge_slot EXIT
REPO="" ; TARGET="" ; CLASS="" ; FIXTURE="" ; CODE="" ; MATCH="invariant"
BACKEND="flat-cyborg" ; MODEL="" ; RUNS="" ; DEPTH="" ; SEED="" ; OUT="$PWD/invariant-out" ; PATTERN_STORE=""
REPLAY_CORPUS=""  # #1731: cross-run ENSEMBLE/UNION replay; "" => OFF (default; byte-identical to today)
CORPUS_MAX="16"   # #1731: max corpus entries kept/replayed per class (most-recent eviction; whole number)
SYMBOLIC_ORACLE=""  # #1732: complementary symbolic/BMC (halmos) oracle; "" => OFF (default; byte-identical)
SYMBOLIC_TIMEOUT="" # #1732: per-assertion halmos solver timeout (seconds); "" => the gate's own default (60)
CORE_DEP_HARNESS="" # #1755: deploy the REAL delegatecall singleton (yearn-v3 TokenizedStrategy); "" => OFF (byte-identical)
ENSEMBLE_CANDIDATES="0"  # #1778: single-run metamorphic-ensemble candidate count; 0/1 => OFF (byte-identical to today)
GROUND_SYMBOLS=0  # FM-B (#1939 M2): symbol grounding; 0 => OFF (no symbol-inventory.txt written; byte-identical prompts)
REPAIR_ROUNDS=""  # #1073: extra compile-repair rounds; "" => the prover's own default (2)
AUDIT_CONTEXT=""  # #1722: optional spec / audit-scope doc; "" => no audit seed (byte-identical prompt)
FORK_URL="" ; FORK_BLOCK="" ; FORK_TARGET=""
# FM2 (#1041): the composability context set — one `--fork-target '<role>=<addr>'` per array slot. A bare
# `--fork-target <addr>` (FM1 shorthand, no '=') is normalised to a `target=<addr>` slot below.
FORK_TARGET_SPECS=()
# FM2 (#1075): the FRESH-DEPLOY auxiliary set — one `--aux <Contract.sol[:Name]>` per array slot (relative to
# --repo, like --target). Resolved + staged + encoded into INV_AUX below. Empty => single-target behaviour.
AUX_SPECS=()

need() { [ "$1" -ge 2 ] || { echo "run-invariant-hunt.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$#"; REPO="$2"; shift 2 ;;
    --target) need "$#"; TARGET="$2"; shift 2 ;;
    --class) need "$#"; CLASS="$2"; shift 2 ;;
    --handler-fixture) need "$#"; FIXTURE="$2"; shift 2 ;;
    --code) need "$#"; CODE="$2"; shift 2 ;;
    --aux) need "$#"; AUX_SPECS+=("$2"); shift 2 ;;
    --match) need "$#"; MATCH="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --model) need "$#"; MODEL="$2"; shift 2 ;;
    --runs) need "$#"; RUNS="$2"; shift 2 ;;
    --depth) need "$#"; DEPTH="$2"; shift 2 ;;
    --seed) need "$#"; SEED="$2"; shift 2 ;;
    --repair-rounds) need "$#"; REPAIR_ROUNDS="$2"; shift 2 ;;
    --audit-context) need "$#"; AUDIT_CONTEXT="$2"; shift 2 ;;
    --fork-url) need "$#"; FORK_URL="$2"; shift 2 ;;
    --fork-block) need "$#"; FORK_BLOCK="$2"; shift 2 ;;
    --fork-target) need "$#"; FORK_TARGET_SPECS+=("$2"); shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --pattern-store) need "$#"; PATTERN_STORE="$2"; shift 2 ;;
    --replay-corpus) REPLAY_CORPUS=1; shift ;;
    --corpus-max) need "$#"; CORPUS_MAX="$2"; shift 2 ;;
    --symbolic-oracle) SYMBOLIC_ORACLE=1; shift ;;
    --symbolic-timeout) need "$#"; SYMBOLIC_TIMEOUT="$2"; shift 2 ;;
    --core-dep-harness) CORE_DEP_HARNESS=1; shift ;;
    --ensemble-candidates) need "$#"; ENSEMBLE_CANDIDATES="$2"; shift 2 ;;
    --ground-symbols) GROUND_SYMBOLS=1; shift ;;
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
# #1731: --corpus-max must be a whole number (validated like --runs). An empty value (e.g. `--corpus-max ""`)
# falls back to the default 16 so the prune/replay bound is always a usable integer.
case "$CORPUS_MAX" in
  '') CORPUS_MAX=16 ;;
  *[!0-9]*) echo "run-invariant-hunt.sh: --corpus-max must be a whole number" >&2; exit 2 ;;
esac
# #1732: --symbolic-timeout must be a whole number of seconds when set. An empty value (the default, or an
# explicit `--symbolic-timeout ""`) is passed through as "" so the halmos-verify.sh gate applies its own
# default (60); only a non-numeric value is a hard usage error so an operator typo surfaces here.
case "$SYMBOLIC_TIMEOUT" in '') ;; *[!0-9]*) echo "run-invariant-hunt.sh: --symbolic-timeout must be a whole number of seconds" >&2; exit 2 ;; esac
# #1778: --ensemble-candidates must be a whole number (validated like --corpus-max). An empty value (or an
# explicit `--ensemble-candidates ""`) falls back to 0 (OFF); N < 2 also takes the OFF single-candidate path.
case "$ENSEMBLE_CANDIDATES" in
  '') ENSEMBLE_CANDIDATES=0 ;;
  *[!0-9]*) echo "run-invariant-hunt.sh: --ensemble-candidates must be a whole number" >&2; exit 2 ;;
esac
# FM1 (#1041): fork-arg shape validation (mirrors the gate's). --fork-url must look like an http(s) URL,
# --fork-block a whole number requiring --fork-url.
case "$FORK_URL" in
  '') ;;
  http://*|https://*) ;;
  *) echo "run-invariant-hunt.sh: --fork-url must be an http(s) URL (got: $FORK_URL)" >&2; exit 2 ;;
esac
case "$FORK_BLOCK" in '') ;; *[!0-9]*) echo "run-invariant-hunt.sh: --fork-block must be a whole number" >&2; exit 2 ;; esac
[ -z "$FORK_BLOCK" ] || [ -n "$FORK_URL" ] || { echo "run-invariant-hunt.sh: --fork-block requires --fork-url" >&2; exit 2; }
# #1722: an --audit-context file must be readable. Validated HERE (before the agentis-binary check below) so an
# operator typo surfaces as a clean usage error even offline, mirroring run-autoharness.sh's FM4 --audit-context.
[ -z "$AUDIT_CONTEXT" ] || [ -r "$AUDIT_CONTEXT" ] || { echo "run-invariant-hunt.sh: --audit-context file not readable: $AUDIT_CONTEXT" >&2; exit 2; }

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
# Default the code path to the target source the LLM reads to write the handler (live path). The `--target`
# FILE part may be a full repo-relative path (`src/contracts/vault/Vault.sol`) OR the bare `src/`-convention
# name (`Morpho.sol`), so try `<repo>/<file>` FIRST, then the `<repo>/src/<file>` convention. Resolving the
# real source is what lets the LLM import the in-scope contract AND arms the #1471 target-linkage gate; a
# nested `--target` that fell through to an empty CODE_PATH used to disarm the gate and pass toy findings (#1475).
if [ -z "$FIXTURE" ] && [ -z "$CODE" ]; then
  _c="${TARGET%%:*}"
  if [ -f "$REPO/$_c" ]; then CODE="$REPO/$_c"
  elif [ -f "$REPO/src/$_c" ]; then CODE="$REPO/src/$_c"
  fi
fi
if [ -n "$CODE" ]; then
  [ -f "$CODE" ] || { echo "run-invariant-hunt.sh: --code not found: $CODE" >&2; exit 2; }
  CODE="$(cd "$(dirname "$CODE")" && pwd)/$(basename "$CODE")"
fi

# FM2 (#1075): resolve + validate each --aux <Contract.sol[:Name]> the way --target/--code are validated —
# the FILE part is relative to --repo (tried as `<repo>/<file>` then the `<repo>/src/<file>` convention the
# target's default-code path uses), must exist, and must be a *.sol. The optional `:Name` (a Solidity
# identifier) is preserved verbatim so the prover can name the import. Each resolved entry is held as
# `<abs_file>:<Name>` in AUX_ABS_SPECS; staging into the rundir + the INV_AUX encoding happen below (once the
# rundir exists). Empty AUX_SPECS leaves AUX_ABS_SPECS empty => INV_AUX empty => single-target behaviour.
AUX_ABS_SPECS=()
# #1926: parallel to AUX_ABS_SPECS — each aux's REAL in-repo file part (the pre-slim `--aux` file, `<repo>`-
# relative, which the prover's resolve_in_repo_src re-resolves inside the STAGED repo). Threaded into INV_AUX
# field 2 below so the composable harness imports the compilable `../src/<Name>.sol`, not the slimmed copy.
AUX_REL_FILES=()
for aspec in ${AUX_SPECS+"${AUX_SPECS[@]}"}; do
  case "$aspec" in
    *:*) _afile="${aspec%%:*}"; _aname="${aspec#*:}" ;;
    *)   _afile="$aspec"; _aname="" ;;
  esac
  [ -n "$_afile" ] || { echo "run-invariant-hunt.sh: --aux file part must be non-empty (got: $aspec)" >&2; exit 2; }
  case "$_afile" in
    *.sol) ;;
    *) echo "run-invariant-hunt.sh: --aux must be a *.sol file (got: $_afile)" >&2; exit 2 ;;
  esac
  if [ -f "$REPO/$_afile" ]; then _aabs="$REPO/$_afile";
  elif [ -f "$REPO/src/$_afile" ]; then _aabs="$REPO/src/$_afile";
  else echo "run-invariant-hunt.sh: --aux not found under --repo: $_afile" >&2; exit 2; fi
  _aabs="$(cd "$(dirname "$_aabs")" && pwd)/$(basename "$_aabs")"
  AUX_ABS_SPECS+=("$_aabs:$_aname")
  AUX_REL_FILES+=("$_afile")  # #1926: index-aligned with AUX_ABS_SPECS (the real in-repo file part)
done

PROVER="$HERE/auditor/agents/invariant-prover.ag"
GATE="$HERE/evm-harness/forge-invariant.sh"
# #1732: the COMPLEMENTARY symbolic/BMC gate. Resolved here (a pure variable, no side effect => byte-identical
# when --symbolic-oracle is off); it is staged into the rundir + invoked ONLY inside the flag-gated
# symbolic_oracle() below, so with the flag off the rundir and pipeline are byte-identical to today.
GATE_HALMOS="$HERE/evm-harness/halmos-verify.sh"
MUTANT_KILL_SRC="$HERE/evm-harness/mutant-kill.sh"
MUTANTS_SRC="$HERE/evm-harness/mutants"
# #1794 — the SHARED HARNESS-MOCK LIBRARY (auditor/harness-mocks/*.sol). Staged into the generated harness
# project below so the prover can IMPORT a ready dependency mock instead of hand-authoring one per run — the
# failure mode that turned complex targets (LP oracles, modular vaults) into HARNESS_ERROR. A pure variable here.
HARNESS_MOCKS_SRC="$HERE/auditor/harness-mocks"
# FM-B (#1939 M2) — the deterministic source-parsing symbol extractor. A pure variable here (no side effect =>
# byte-identical when --ground-symbols is off); it is invoked ONLY inside the flag-gated grounding block below.
SYMBOL_EXTRACT="$HERE/evm-harness/extract-solidity-symbols.sh"
[ -f "$PROVER" ] || { echo "run-invariant-hunt.sh: invariant-prover agent not found at $PROVER" >&2; exit 3; }
[ -f "$GATE" ] || { echo "run-invariant-hunt.sh: forge-invariant gate not found at $GATE" >&2; exit 3; }

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$PROVER" "$RUN/invariant-prover.ag"
cp "$GATE" "$RUN/forge-invariant.sh"
# #1728 — stage the #1724 mutant kill-set (mutant-kill.sh + the mutants/ fixture tree) into the rundir next to
# the gate so the prover's TEETH-GATE can run it from the exec sandbox (which cannot read $HOME). mutant-kill.sh
# resolves forge-invariant.sh + mutants/ relative to its OWN dir — which becomes $RUN, where $RUN/forge-invariant.sh
# already exists — so the staged copies are self-contained. Guarded so a missing kill-set degrades gracefully:
# MUTANT_KILL stays pointing at a path that may not exist, and the prover falls back to today's FINDING-only
# behaviour (its run_mutant_kill SKIP/error handling treats a missing/failed harness as `unmeasured`).
MUTANT_KILL_IN_RUN=""
if [ -f "$MUTANT_KILL_SRC" ] && [ -d "$MUTANTS_SRC" ]; then
  cp "$MUTANT_KILL_SRC" "$RUN/mutant-kill.sh"
  cp -R "$MUTANTS_SRC" "$RUN/mutants"
  MUTANT_KILL_IN_RUN="$RUN/mutant-kill.sh"
fi

# #1079: SLIM a Solidity source before it is staged into the rundir as the prover's CODE_PATH / aux source.
# The generation prompt embeds the FULL source of the target (and, in composable-fresh mode, of every aux),
# so a cross-contract pair was ~90 KB of Solidity per gen call and hung flat-cyborg->claude on a SINGLE call
# past the per-run timeout (all cross-contract coverage lost). The OUTPUT ask is already bounded (#1067); this
# slims the INPUT. We drop only NOISE the model does not need — comments, imports, pragmas, blank-line runs —
# and KEEP every line of real callable surface + logic (the `contract` decl, state vars, function signatures
# AND bodies, structs/enums/events/errors). A reasonable target is roughly halving heavily-NatSpec'd sources.
#
# Portable awk (no GNU-only features) implementing, in ONE pass with a block-comment state machine:
#   * `/* ... */` block comments INCLUDING multi-line NatSpec `/** ... */` (the state machine spans lines; a
#     naive sed cannot do this robustly). A block opened and closed on one line is removed too.
#   * full-line `//` / `///` line comments (after leading whitespace) -> the whole line is dropped.
#   * trailing `// ...` on a code line -> stripped ONLY when the line carries no quote (`"` or `'`) before it,
#     so a `//` inside a string literal is NEVER corrupted (conservative; correctness over maximal slimming).
#   * `import ...;` and `pragma ...;` statement lines (after leading whitespace) -> dropped.
#   * runs of blank lines squeezed to a single blank line.
# Real code lines are emitted verbatim. The whole transform writes to a temp file; if it somehow EMPTIES the
# source (pathological input), we fall back to a flat copy of the original so CODE_PATH is never empty/truncated.
slim_sol_source() {  # $1 = src .sol path, $2 = dest staged path
  _slim_src="$1"; _slim_dst="$2"
  awk '
    BEGIN { inblock = 0; blank = 0 }
    {
      line = $0
      out = ""
      i = 1
      n = length(line)
      # --- block-comment state machine (handles /* */, /** */, multi-line) ---
      while (i <= n) {
        if (inblock) {
          # inside a block comment: look for the closing */
          p = index(substr(line, i), "*/")
          if (p == 0) { i = n + 1 }          # no close on this line -> consume the rest
          else { i = i + p + 1; inblock = 0 } # skip past the */ and resume scanning
          continue
        }
        c = substr(line, i, 1)
        # opening of a // line comment: only honour it if no quote precedes it on the kept part so far
        # (conservative: a // inside a string literal is left alone -> the whole line is kept verbatim).
        if (c == "/" && substr(line, i + 1, 1) == "/") {
          if (index(out, "\"") == 0 && index(out, "\x27") == 0) { i = n + 1; continue }
          else { out = out substr(line, i); i = n + 1; continue }
        }
        # opening of a /* block comment (covers /** NatSpec)
        if (c == "/" && substr(line, i + 1, 1) == "*") {
          inblock = 1; i = i + 2; continue
        }
        out = out c
        i = i + 1
      }
      # strip trailing whitespace left by a removed trailing comment
      sub(/[ \t]+$/, "", out)
      # drop import/pragma statement lines (after any leading whitespace)
      tmp = out
      sub(/^[ \t]+/, "", tmp)
      if (tmp ~ /^import[ \t(]/ || tmp ~ /^pragma[ \t]/) { next }
      # squeeze runs of blank lines to one
      if (out ~ /^[ \t]*$/) {
        if (blank) { next }
        blank = 1
        print ""
        next
      }
      blank = 0
      print out
    }
  ' "$_slim_src" > "$_slim_dst" 2>/dev/null || true
  # Empty-output guard: never ship an empty CODE_PATH. A truly empty file, OR one with no non-whitespace
  # content (e.g. a pathological all-comments/all-import source that slimmed down to only blank lines), falls
  # back to the original verbatim so the prover always reads a real, complete source.
  if [ ! -s "$_slim_dst" ] || ! grep -q '[^[:space:]]' "$_slim_dst" 2>/dev/null; then
    cp "$_slim_src" "$_slim_dst"
  fi
}

# Stage a fresh copy of the foundry project into the rundir so the sandboxed exec sh can write the test into
# its test/ dir and run forge there (it cannot reach a $HOME-rooted --repo). Drop any pre-existing *.t.sol so
# the generated test is the ONLY one the fuzzer scopes to.
REPO_IN_RUN="$RUN/repo"
cp -R "$REPO" "$REPO_IN_RUN"
rm -f "$REPO_IN_RUN/test/"*.t.sol 2>/dev/null || true
mkdir -p "$REPO_IN_RUN/test"

# #1794 — STAGE THE SHARED HARNESS-MOCK LIBRARY into the harness project, BEFORE the prover writes/compiles the
# test, so a generated harness can `import {MockERC20} from "./mocks/MockERC20.sol";` and it RESOLVES (the test
# is written to $REPO_IN_RUN/test/, one directory above `mocks/`). This is a pure COPY of dependency-free,
# compile-clean Solidity into a NEW `test/mocks/` dir:
#   * it never edits foundry.toml, the src/ tree, or any existing test — nothing the fuzzer scopes to changes;
#   * the library declares no test contract and no `invariant_*`/`test*` function, so `forge test` discovers
#     nothing new and a harness that imports NOTHING from here produces a byte-IDENTICAL verdict;
#   * a repo that ALREADY ships `test/mocks/<Name>.sol` keeps its OWN file (never clobbered — the target
#     project's copy is the authority for its own build).
# The library carries `pragma solidity >=0.8.0` so it compiles under whatever 0.8.x the staged project pins.
# A missing library dir degrades gracefully to today's behaviour (the prover's generic "author a minimal mock"
# instruction still applies), so this is never a hard failure.
if [ -d "$HARNESS_MOCKS_SRC" ]; then
  mkdir -p "$REPO_IN_RUN/test/mocks"
  for _mock in "$HARNESS_MOCKS_SRC"/*.sol; do
    [ -f "$_mock" ] || continue
    _mock_dst="$REPO_IN_RUN/test/mocks/$(basename "$_mock")"
    [ -f "$_mock_dst" ] || cp "$_mock" "$_mock_dst"
  done
fi

# #1763 G1: CORE-DEPENDENCY harness-gen. Only under --core-dep-harness do we run the mechanical (no-LLM)
# detect-core-dep.sh over the target source + the staged repo copy. It emits EITHER EMPTY (no resolvable
# delegatecall singleton) or one line `<abs_singleton_src>:<Name>:<addr>|<featureset>`; we split it at `|` into
# INV_CORE_DEP="<path>:<Name>:<addr>" (schema UNCHANGED — the prover's core_dep_field/etch recipe already threads
# name/addr) and INV_CORE_FEATURES (the detected shape tags, e.g. `dcs`). yearn-v3 stays an explicit,
# byte-preserved registry case INSIDE the detector; the general delegatecall-singleton shapes (EIP-1967 proxy,
# diamond/facets, generic constant-address) are recognized but resolve a concrete address ONLY against the
# known-singleton registry, emitting EMPTY on any ambiguity (the over-fire mitigation — never a guessed address).
# Because REPO_IN_RUN is a FULL copy, a resolved singleton is present with the repo's own remappings intact, so the
# generated harness imports it in-repo. Flag off / no source / detector miss => INV_CORE_DEP="" (+ empty features)
# => today's single-target path (byte-identical, never a bad vm.etch directive).
INV_CORE_DEP=""
INV_CORE_FEATURES=""
if [ -n "$CORE_DEP_HARNESS" ]; then
  if [ -n "$CODE" ] && [ -f "$CODE" ]; then
    _det="$("$HERE/detect-core-dep.sh" "$CODE" "$REPO_IN_RUN" || true)"
    if [ -n "$_det" ]; then
      INV_CORE_DEP="${_det%%|*}"
      INV_CORE_FEATURES="${_det##*|}"
      echo "run-invariant-hunt.sh: [core-dep] singleton detected — $INV_CORE_DEP (features: $INV_CORE_FEATURES)" >&2
    else
      echo "run-invariant-hunt.sh: [core-dep] no resolvable delegatecall singleton — skipping (byte-identical)" >&2
    fi
  else
    echo "run-invariant-hunt.sh: [core-dep] no target source — skipping (byte-identical)" >&2
  fi
fi

# Stage the (optional) fixture + code into the rundir so the sandboxed reader can reach them.
FIXTURE_IN_RUN=""
if [ -n "$FIXTURE" ]; then
  cp "$FIXTURE" "$RUN/handler-fixture.t.sol"
  FIXTURE_IN_RUN="$RUN/handler-fixture.t.sol"
fi
CODE_IN_RUN=""
if [ -n "$CODE" ]; then
  # #1079: SLIM the target source on its way into the rundir (instead of a flat copy) so the generation prompt
  # embeds a smaller, comment/import-free source — the gen call no longer hangs on a ~90 KB single completion.
  slim_sol_source "$CODE" "$RUN/target-code.sol"
  CODE_IN_RUN="$RUN/target-code.sol"
fi
# #1722: stage the (optional) audit-context doc into the rundir so the sandboxed reader can reach it. Plain `cp`
# — it is a spec / audit-scope TEXT doc, NOT Solidity, so it is NOT run through slim_sol_source. Empty => "" =>
# the prover's audit_seed() returns "" => the generation prompt is byte-identical to a non-audit run.
AUDIT_IN_RUN=""
if [ -n "$AUDIT_CONTEXT" ]; then
  cp "$AUDIT_CONTEXT" "$RUN/audit-context.txt"
  AUDIT_IN_RUN="$RUN/audit-context.txt"
fi

# FM2 (#1075): stage each resolved --aux source into the rundir (so the sandboxed reader can reach it) and
# build INV_AUX — a sentinel-joined list of 3-field `<abs_path_in_run>@@F@@<Name>@@F@@<real_repo_file>` entries
# (#1926), entry sentinel `@@A@@`, field sentinel `@@F@@`. Neither sentinel can occur in a filesystem path (it
# stages each aux under a colony-controlled `aux-code-<n>.sol` name, all ASCII alnum + `-`) nor in a Solidity
# identifier, so the prover splits the list and each entry's fields unambiguously. No --aux => AUX_ABS_SPECS empty => INV_AUX stays "" => the prover's single-target prompt
# is byte-identical. The aux SOURCES + names flow only into the prover's plain-string prompt (never a shell).
INV_AUX=""
_aux_idx=0
for entry in ${AUX_ABS_SPECS+"${AUX_ABS_SPECS[@]}"}; do
  _aabs="${entry%:*}"; _aname="${entry##*:}"
  _aux_in_run="$RUN/aux-code-${_aux_idx}.sol"
  # #1079: SLIM each aux source too — a cross-contract PAIR (two full sources in one prompt) was the worst
  # offender for the gen-call timeout, so the aux staging goes through the same slimmer as the target.
  slim_sol_source "$_aabs" "$_aux_in_run"
  # #1926: encode each aux as the 3-field `<staged_slim_abs>@@F@@<Name>@@F@@<real_repo_file>` so the prover can
  # IMPORT the compilable `../src/<Name>.sol` (field 2) while still reading the slim staged copy (field 0) for the
  # PROMPT source block. AUX_REL_FILES is index-aligned with AUX_ABS_SPECS, so `_aux_idx` selects this aux's file.
  _aentry="$_aux_in_run@@F@@$_aname@@F@@${AUX_REL_FILES[$_aux_idx]}"
  if [ -z "$INV_AUX" ]; then INV_AUX="$_aentry"; else INV_AUX="$INV_AUX@@A@@$_aentry"; fi
  _aux_idx=$((_aux_idx + 1))
done

# FM-B (#1939 M2) — SYMBOL GROUNDING. With --ground-symbols set, extract the REAL symbol inventory from the
# already-STAGED target + aux sources (the slim copies written above) and write it to the FIXED rundir-relative
# `$RUN/symbol-inventory.txt`. The prover cds into $RUN and reads that file directly — a fixed file, NOT a new
# exec.env_passthrough entry, precisely so this change does not ripple the 7 pinners of that exact string. Absent
# the flag the file is NEVER written => the prover's grounding block is empty => the generation + repair prompts
# are byte-identical to today. A missing extractor or an empty inventory degrades to the un-grounded prompt.
if [ "$GROUND_SYMBOLS" = "1" ] && [ -f "$SYMBOL_EXTRACT" ]; then
  GROUND_SRCS=()
  [ -n "$CODE_IN_RUN" ] && [ -f "$CODE_IN_RUN" ] && GROUND_SRCS+=("$CODE_IN_RUN")
  _gi=0
  while [ "$_gi" -lt "$_aux_idx" ]; do
    _gaux="$RUN/aux-code-${_gi}.sol"
    [ -f "$_gaux" ] && GROUND_SRCS+=("$_gaux")
    _gi=$((_gi + 1))
  done
  sh "$SYMBOL_EXTRACT" ${GROUND_SRCS[@]+"${GROUND_SRCS[@]}"} > "$RUN/symbol-inventory.txt" 2>/dev/null || true
  echo "run-invariant-hunt.sh: [ground-symbols] wrote $(grep -c . "$RUN/symbol-inventory.txt" 2>/dev/null || echo 0) in-scope symbols to symbol-inventory.txt" >&2
fi

# #1915/#1932: composable-fresh generation (INV_AUX non-empty) deploys+wires the target AND every aux
# contract in one prompt -- materially heavier than the single-target read the flat 1200s budget (line
# ~517 below) was sized for. Scale by aux count (1200s base + 600s per staged aux contract), capped at
# 1_800_000ms (30 min) so a large --aux set cannot grow the budget unboundedly. INV_AUX empty (no --aux)
# => stays at the flat 1200000 base. agentis-core's retry re-issues the SAME prompt against the SAME
# budget (no escalation) -- the initial value must be sufficient on its own, a retry is not a rescue.
GEN_TIMEOUT_MS=1200000
if [ -n "$INV_AUX" ]; then
  GEN_TIMEOUT_MS=$((1200000 + 600000 * _aux_idx))
  [ "$GEN_TIMEOUT_MS" -gt 1800000 ] && GEN_TIMEOUT_MS=1800000
fi

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  # 1200s base: writing a stateful-invariant handler for a real protocol is the same order of cost as a
  # discovery read; #1915 scales this up via GEN_TIMEOUT_MS (computed above) for composable-fresh mode.
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p${MODEL:+ --model $MODEL}"; echo "llm.cli_timeout_ms = $GEN_TIMEOUT_MS"; }
  # idle_ms 12000 (> native 4000 default): kept as a latency knob only (#1925) -- do NOT ratchet it further.
  # Completion is gated on the wrapper's closing sentinel from flat-cyborg >= 0.13.0 (idle_gate_open()); idle_ms
  # only bounds how fast a marker-less (sentinel-less) reply is accepted once the screen goes quiet, so a
  # premature scrape of a TUI chrome element (e.g. the model-name "Fable 5") mid-generation no longer degrades
  # the run to HARNESS_ERROR the way the pre-#1925 4000ms default did. Default the model to opus so the
  # invariant path is never silently left on the weaker default model when no --model is threaded through by
  # the caller (run-zone-hunt.sh --deep-hunt does not).
  # #1915: same GEN_TIMEOUT_MS (scaled for composable-fresh mode) as the claude branch above.
  [ "$BACKEND" = "flat-cyborg" ] && { echo "llm.cli_timeout_ms = $GEN_TIMEOUT_MS"; echo "llm.flat_cyborg.idle_ms = 12000"; echo "llm.model = ${MODEL:-opus}"; }
  echo "trace.level = normal"
  # The prover reads code + the fixture and writes/runs the test through exec sh; pass its whole env contract.
  # FM1 (#1041): FORK_URL/FORK_BLOCK thread the fork into the gate; FORK_TARGET is the deployed address the
  # generated handler/invariant references against the forked state. FM2 (#1041): FORK_CONTEXT carries the
  # role->address context set so the generation prompt can compose calls across the deployed protocols.
  # FM2 (#1075): INV_AUX carries the sentinel-joined `<abs_path>@@F@@<Name>@@F@@<real_repo_file>` auxiliary-contract
  # list (#1926 3-field form) so the prover can deploy + WIRE the whole system (fresh-deploy composability) AND
  # import each aux from its compilable real in-repo source.
  # #1728: MUTANT_KILL threads the staged #1724 mutant-kill.sh path so the prover's TEETH-GATE can measure a CLEAN.
  # #1731: INV_CORPUS (=1 only under --replay-corpus + --pattern-store) arms the prover's persist_corpus so it
  # accumulates EVERY generated invariant's descriptor into the invpat:corpus:<class> recall tier.
  # #1755: INV_CORE_DEP (set only under --core-dep-harness + a resolved delegatecall singleton) carries the real
  # delegatecall singleton `<path>:<Name>:<addr>` so the prover generates a `vm.etch` of the actual singleton.
  # #1763 G1: INV_CORE_FEATURES carries the detected shape tags (e.g. `dcs`); empty when no singleton resolved.
  # #1778: INV_ENSEMBLE_VARIANT (the per-candidate metamorphic-variant index; "" on the OFF/single path) is
  # APPENDED at the END so every existing demo's substring/allowlist assertion stays green.
  echo "exec.env_passthrough = TARGET_FN,TARGET_CLASS,INV_REPO,INV_OUT,INV_MATCH,HANDLER_FIXTURE,CODE_PATH,INV_RUNS,INV_DEPTH,INV_SEED,FORGE_INVARIANT,FORK_URL,FORK_BLOCK,FORK_TARGET,FORK_CONTEXT,INV_REPAIR_ROUNDS,INV_AUX,INV_AUDIT_CONTEXT,MUTANT_KILL,INV_CORPUS,INV_CORE_DEP,INV_CORE_FEATURES,INV_ENSEMBLE_VARIANT"
  # A forge invariant run (build + a few hundred fuzzed sequences) far exceeds the 10s default.
  # #1915: intentionally left UNSCALED -- the observed composable-fresh timeout is on the generation LLM
  # call (GEN_TIMEOUT_MS above), not the forge-run budget; bump this only if a future run shows a
  # forge-run-side (not generation-side) timeout under composable mode.
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

# #1731: arm the prover's persist_corpus ONLY when the cross-run ensemble is fully wired — both --replay-corpus
# AND --pattern-store present (the corpus lives in the store). Else "" so persist_corpus early-returns and the
# pipeline is byte-identical to today (mirrors #1728's MUTANT_KILL default-empty gate). Threaded as INV_CORPUS
# into the agentis go env block below.
INV_CORPUS_VAL=""
if [ -n "$REPLAY_CORPUS" ] && [ -n "$PATTERN_STORE" ]; then INV_CORPUS_VAL=1; fi

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

# #1731 — CROSS-RUN ENSEMBLE / UNION REPLAY (the cheap, no-LLM replay side the issue asks for). Replays the
# accumulated union of PRIOR-run invariant SOURCES (stored content-addressed under
# $PATTERN_STORE/corpus/<class_slug>/) against THIS run's freshly-staged target repo, through the SAME staged
# forge-invariant gate + the identical #1471 link args (built in CORPUS_LINK_ARGS, pure fresh-deploy mode) — so a
# hypothesis authored for a DIFFERENT contract is scored HARNESS_ERROR by the same fuzzer path, never a false
# FINDING/CLEAN. It is PURE SHELL over a BOUNDED set (--corpus-max): NO agentis spawn per replay, NO per-element
# .ag loop, NO LLM. Each replay is one gate invocation whose exit maps 1->FINDING / 0->CLEAN / else->HARNESS_ERROR
# (the prover's exact contract). Appends one row per replay to a `## Corpus replay` section of $REPORT; it writes
# NOTHING back to the corpus and does NOT alter the primary INVARIANT| verdict or verified_findings.json.
replay_corpus() {  # $1 = corpus class dir, $2 = report path
  _cdir="$1"; _rpt="$2"
  [ -d "$_cdir" ] || return 0
  # ls -t: most-recent first, bounded to --corpus-max so replay cost is capped exactly like storage. The corpus
  # filenames are content-addressed (`<sha256>.t.sol`, hex only) so the word-split into distinct argv is safe.
  # shellcheck disable=SC2046  # intentional word-split of the (charset-safe) corpus filenames into positional args
  set -- $(ls -t "$_cdir"/*.t.sol 2>/dev/null | head -n "$CORPUS_MAX")
  [ "$#" -gt 0 ] || return 0
  {
    echo
    echo "## Corpus replay (union of prior hypotheses)"
    echo
    echo "Each prior-run invariant hypothesis (accumulated on a FINDING OR a CLEAN, not only winners) re-run"
    echo "against THIS target through the SAME staged fuzzer gate + the #1471 link gate. A hypothesis authored"
    echo "for a different contract is HARNESS_ERROR here, never a false verdict. Bounded by --corpus-max."
    echo
    echo "| Corpus entry | Verdict |"
    echo "|---|---|"
  } >> "$_rpt"
  _replayed=0
  for _cf in "$@"; do
    [ -f "$_cf" ] || continue
    _replayed=$((_replayed + 1))
    # Copy the corpus entry as the SOLE test in the run's repo (drop any prior *.t.sol so the fuzzer scopes only
    # to the replayed hypothesis), then run the SAME staged gate in pure fresh-deploy mode.
    rm -f "$REPO_IN_RUN/test/"*.t.sol 2>/dev/null || true
    cp "$_cf" "$REPO_IN_RUN/test/CorpusReplay.t.sol"
    set +e
    # #2038: bound this forge subprocess against the same host-wide cap as the
    # generation path below — a corpus replay loop is a second batch source of
    # forge invocations, not a single-shot gate.
    acquire_forge_slot
    sh "$RUN/forge-invariant.sh" --repo "$REPO_IN_RUN" --target "$REPO_IN_RUN/test/CorpusReplay.t.sol" --match "$MATCH" ${CORPUS_LINK_ARGS[@]+"${CORPUS_LINK_ARGS[@]}"} >/dev/null 2>&1
    _crc=$?
    release_forge_slot
    set -e
    case "$_crc" in
      1) _cv="FINDING" ;;
      0) _cv="CLEAN" ;;
      *) _cv="HARNESS_ERROR" ;;
    esac
    printf '| %s | %s |\n' "$(basename "$_cf")" "$_cv" >> "$_rpt"
  done
  echo "run-invariant-hunt.sh: replayed $_replayed prior corpus hypothes$( [ "$_replayed" -eq 1 ] && echo is || echo es ) for $CLASS" >&2
  return 0
}

# #1732 — COMPLEMENTARY SYMBOLIC / BOUNDED-MODEL-CHECKING ORACLE. A SECOND, INDEPENDENT oracle that runs the
# SOUND staged evm-harness/halmos-verify.sh gate over the SAME generated invariant test AFTER the fuzzer has
# produced its verdict. The FUZZER stays the SOLE primary verdict: this function reads NONE of $VERD /
# verdict_of / final_verdict, never touches the INVARIANT| marker or verified_findings.json, and appends only
# its own `## Symbolic oracle (complementary)` report section + a `SYMBOLIC|<target>|<verdict>` stderr marker
# (reusing run-symbolic.sh's marker convention + verdict vocabulary). It is ONE staged-gate invocation — NO
# agentis spawn, NO per-element .ag loop. Called ONLY under `if [ -n "$SYMBOLIC_ORACLE" ]` (below), so with the
# flag off it never runs and the pipeline is byte-identical to today.
#
# Tool-absence is a clean SKIP, never a HARNESS_ERROR: halmos-verify.sh itself exits 2 (harness/usage) when
# halmos/forge are absent, which would be indistinguishable from a real harness error, so we guard on
# `command -v halmos`+`command -v forge` HERE (the runner side) and, if either is missing OR the fuzzer produced
# no test ($INV_OUT absent, a fuzzer HARNESS_ERROR), append a SKIPPED row and return without a verdict.
symbolic_oracle() {  # $1 = report path
  _srpt="$1"
  {
    echo
    echo "## Symbolic oracle (complementary)"
    echo
    echo "A SECOND, INDEPENDENT oracle (Halmos symbolic execution / bounded model checking) run over the SAME"
    echo "generated invariant test AFTER the fuzzer verdict. The FUZZER stays the SOLE primary verdict above;"
    echo "this row NEVER alters it. PROVED = the property held for ALL symbolic inputs Halmos explored;"
    echo "COUNTEREXAMPLE = a concrete input violates it; INCONCLUSIVE = a path could not be decided; SKIPPED ="
    echo "halmos/forge absent or no test was generated (NOT a verdict). NB a no-argument invariant_* is checked"
    echo "with concrete setUp() state, so a PROVED here can be vacuous — deep symbolic properties need"
    echo "symbolic-argument check_* specs (a deferred generation concern, out of scope for this wiring)."
    echo
    echo "| Target | Function | Symbolic verdict |"
    echo "|---|---|---|"
  } >> "$_srpt"
  # Clean SKIP (exit-neutral): the fuzzer produced no test, OR the symbolic toolchain is absent. Never a verdict.
  if [ ! -f "$INV_OUT" ]; then
    printf '| %s | %s | %s |\n' "$TARGET" "$MATCH" "SKIPPED (no generated invariant test)" >> "$_srpt"
    echo "run-invariant-hunt.sh: [skip] symbolic oracle — the fuzzer generated no invariant test ($TARGET)" >&2
    return 0
  fi
  if ! command -v halmos >/dev/null 2>&1 || ! command -v forge >/dev/null 2>&1; then
    printf '| %s | %s | %s |\n' "$TARGET" "$MATCH" "SKIPPED (halmos/forge not on PATH)" >> "$_srpt"
    echo "run-invariant-hunt.sh: [skip] symbolic oracle — halmos/forge not installed (a SKIP, not a HARNESS_ERROR)" >&2
    return 0
  fi
  # Stage the SOUND gate into the rundir (next to the staged forge-invariant.sh) so it can run from a cwd the
  # sandbox can reach, then invoke it over the SAME generated invariant, matching the `invariant_*` functions.
  cp "$GATE_HALMOS" "$RUN/halmos-verify.sh"
  set +e
  sh "$RUN/halmos-verify.sh" --repo "$REPO_IN_RUN" --target "$INV_OUT" --function "$MATCH" ${SYMBOLIC_TIMEOUT:+--timeout "$SYMBOLIC_TIMEOUT"} >&2
  _hrc=$?
  set -e
  case "$_hrc" in
    0) SYMV="PROVED" ;;
    1) SYMV="COUNTEREXAMPLE" ;;
    3) SYMV="INCONCLUSIVE" ;;
    *) SYMV="HARNESS_ERROR" ;;
  esac
  # Emit the marker on STDERR (run-symbolic.sh's convention) and append the row. This is the ONLY channel the
  # symbolic verdict flows through — it never reaches the INVARIANT| marker, $VERD, or verified_findings.json.
  echo "SYMBOLIC|$TARGET|$SYMV" >&2
  printf '| %s | %s | %s |\n' "$TARGET" "$MATCH" "$SYMV" >> "$_srpt"
  echo "run-invariant-hunt.sh: [symbolic] complementary oracle verdict for $TARGET: $SYMV (the fuzzer verdict above is unchanged)" >&2
  return 0
}

# RECALL: seed the per-run store with any patterns a PRIOR run persisted, BEFORE `agentis go` (so the
# prover's recall_pattern() sees them and folds them into GENERATE).
if [ -n "$PATTERN_STORE" ]; then
  bridge_invpat "$PATTERN_STORE" "$RUN"
fi

# #1778 — run ONE prover candidate: generate + stateful-fuzz with a specific metamorphic ENSEMBLE variant, write
# its cell log, parse the fuzzer verdict from the LAST `INVARIANT|` marker, and ECHO that verdict on stdout. The
# OFF/single path calls this ONCE with variant="" + the canonical INV_OUT/CELL_LOG, so the generated artifacts
# land exactly where they do today and the runtime behaviour is byte-identical (INV_ENSEMBLE_VARIANT="" reaches
# the prover's metamorphic_variant_seed(), which returns "" => the generation prompt is unchanged). Each candidate
# is its OWN prover generation + its OWN forge run(s) through the SAME unchanged gate/repair/teeth loop.
# --grant-pii: target/fork context + staged contract source can carry addresses/identifiers that trip the PII
# heuristic; input is benign public contract text (#1690).
run_one_candidate() {  # $1 = variant ("" = OFF/single), $2 = INV_OUT path, $3 = cell log path -> echoes verdict
  _variant="$1"; _invout="$2"; _celllog="$3"
  # #2038: this `agentis go invariant-prover.ag` call is the actual forge
  # build+fuzz subprocess (via the gate's FORGE_INVARIANT exec sh) — bound it
  # against the host-wide cap so concurrent candidates/hunts don't starve
  # each other's forge runs.
  acquire_forge_slot
  ( cd "$RUN" && env \
      TARGET_FN="$TARGET" \
      TARGET_CLASS="$CLASS" \
      INV_REPO="$REPO_IN_RUN" \
      INV_OUT="$_invout" \
      INV_MATCH="$MATCH" \
      HANDLER_FIXTURE="$FIXTURE_IN_RUN" \
      CODE_PATH="$CODE_IN_RUN" \
      INV_AUX="$INV_AUX" \
      INV_AUDIT_CONTEXT="$AUDIT_IN_RUN" \
      INV_CORE_DEP="$INV_CORE_DEP" \
      INV_CORE_FEATURES="$INV_CORE_FEATURES" \
      INV_ENSEMBLE_VARIANT="$_variant" \
      INV_RUNS="$RUNS" \
      INV_DEPTH="$DEPTH" \
      INV_SEED="$SEED" \
      INV_REPAIR_ROUNDS="$REPAIR_ROUNDS" \
      FORK_URL="$FORK_URL" \
      FORK_BLOCK="$FORK_BLOCK" \
      FORK_TARGET="$FORK_TARGET" \
      FORK_CONTEXT="$FORK_CONTEXT" \
      FORGE_INVARIANT="$RUN/forge-invariant.sh" \
      MUTANT_KILL="$MUTANT_KILL_IN_RUN" \
      INV_CORPUS="$INV_CORPUS_VAL" \
      "$AGENTIS" go invariant-prover.ag --enable-exec --enable-messaging --grant-pii ) >"$_celllog" 2>&1 || \
      echo "run-invariant-hunt.sh: invariant-prover run failed for '$TARGET' (see $_celllog)" >&2
  release_forge_slot
  # The prover's contract: exactly one `INVARIANT|<file:fn>|<verdict>` line, then (on a FINDING) `STEP|...` lines.
  # Take the LAST verdict match. No line at all = HARNESS_ERROR (no verdict produced).
  _vline="$(grep 'INVARIANT|' "$_celllog" | tail -1 || true)"
  if [ -z "$_vline" ]; then
    _cverd="HARNESS_ERROR"
    # #1915: purely diagnostic -- never changes _cverd -- distinguishes a generation LLM call timeout
    # (agentis-core's LlmError::Timeout message) from other HARNESS_ERROR causes in the run's own stderr.
    if grep -q 'LLM call timed out after' "$_celllog" 2>/dev/null; then
      echo "run-invariant-hunt.sh: [harness-error] generation LLM call timed out (see $_celllog) -- raise GEN_TIMEOUT_MS if this recurs" >&2
    fi
  else
    _cverd="$(printf '%s' "$_vline" | sed 's/.*INVARIANT|//' | cut -d'|' -f2)"
  fi
  case "$_cverd" in
    FINDING|CLEAN|HARNESS_ERROR|TRANSIENT_ERROR) ;;  # #2033: TRANSIENT_ERROR is a re-runnable verdict, distinct from HARNESS_ERROR
    *) _cverd="HARNESS_ERROR" ;;
  esac
  printf '%s\n' "$_cverd"
}

echo "run-invariant-hunt.sh: generating + stateful-fuzzing $TARGET ($CLASS) ..." >&2
# #1778 — SINGLE-RUN METAMORPHIC ENSEMBLE dispatch. OFF (ENSEMBLE_CANDIDATES < 2, OR the offline
# --handler-fixture path where N copies would be identical) => ONE candidate with variant="" + the canonical
# INV_OUT/CELL_LOG => byte-identical to today. ON (N >= 2 on the LLM path): steer N distinct metamorphic VARIANTS
# through the UNCHANGED gate, collect their verdicts, and take the ensemble vote (any FINDING => FINDING; else any
# HARNESS_ERROR => HARNESS_ERROR; else CLEAN). The winning (FIRST-FINDING) candidate's INV_OUT + STEP| witness
# feed the #1731 corpus accumulation + teeth-gate reference; the aggregate is synthesized into $CELL_LOG as the
# LAST `INVARIANT|` line, with per-candidate `CANDIDATE|` diagnostics (which carry no `INVARIANT|` substring), so
# BOTH downstream consumers (this runner's tail -1, run-zone-hunt.sh's last-`INVARIANT|`-wins adapter) read the
# aggregate with ZERO parser change.
if [ "$ENSEMBLE_CANDIDATES" -ge 2 ] && [ -z "$FIXTURE_IN_RUN" ]; then
  echo "run-invariant-hunt.sh: [ensemble] $ENSEMBLE_CANDIDATES metamorphic candidates for $TARGET ..." >&2
  ENS_AGG="CLEAN"; ENS_HAD_HARNESS=""; ENS_HAD_TRANSIENT=""; ENS_WIN_LOG=""; ENS_WIN_INVOUT=""
  ENS_ROWS=()
  ens_i=0
  while [ "$ens_i" -lt "$ENSEMBLE_CANDIDATES" ]; do
    ens_invout="$REPO_IN_RUN/test/Inv_${SLUG}_c${ens_i}.t.sol"
    ens_celllog="$RUN/invariant_${SLUG}_c${ens_i}.log"
    # Clear any prior candidate's test so the fuzzer scopes only to THIS candidate (the #1731 replay idiom).
    rm -f "$REPO_IN_RUN/test/"*.t.sol 2>/dev/null || true
    ens_verd="$(run_one_candidate "$ens_i" "$ens_invout" "$ens_celllog")"
    echo "run-invariant-hunt.sh: [ensemble] candidate $ens_i (variant $ens_i) -> $ens_verd" >&2
    ENS_ROWS+=("CANDIDATE|$TARGET|$ens_i|$ens_i|$ens_verd")
    if [ "$ens_verd" = "FINDING" ]; then
      if [ "$ENS_AGG" != "FINDING" ]; then ENS_AGG="FINDING"; ENS_WIN_LOG="$ens_celllog"; ENS_WIN_INVOUT="$ens_invout"; fi
    elif [ "$ens_verd" = "TRANSIENT_ERROR" ]; then
      ENS_HAD_TRANSIENT=1
    elif [ "$ens_verd" = "HARNESS_ERROR" ]; then
      ENS_HAD_HARNESS=1
    fi
    ens_i=$((ens_i + 1))
  done
  # #2033 ensemble precedence: FINDING > TRANSIENT_ERROR > HARNESS_ERROR > CLEAN. A real FINDING still wins; a
  # re-runnable TRANSIENT_ERROR (forge starved/killed under load, the harness is valid) beats a permanent
  # HARNESS_ERROR so the cell is re-hunted rather than finalized as an untestable zone.
  if [ "$ENS_AGG" != "FINDING" ] && [ -n "$ENS_HAD_TRANSIENT" ]; then ENS_AGG="TRANSIENT_ERROR"
  elif [ "$ENS_AGG" != "FINDING" ] && [ -n "$ENS_HAD_HARNESS" ]; then ENS_AGG="HARNESS_ERROR"; fi
  VERD="$ENS_AGG"
  # Point INV_OUT at the winning candidate's generated test (a real file for the #1731 corpus accumulation); on a
  # non-FINDING aggregate, fall back to the LAST candidate's INV_OUT so the corpus/teeth path references a real test.
  if [ -n "$ENS_WIN_INVOUT" ]; then INV_OUT="$ENS_WIN_INVOUT"; else INV_OUT="$REPO_IN_RUN/test/Inv_${SLUG}_c$((ENSEMBLE_CANDIDATES - 1)).t.sol"; fi
  # The winning candidate's shrunk witness (only a FINDING has STEP| lines). STEPS is the #1471-style stripped form
  # for the report; the raw STEP| lines are re-emitted into the synthesized log verbatim (multi-line safe).
  ENS_WIN_STEPS_RAW=""
  if [ -n "$ENS_WIN_LOG" ]; then
    STEPS="$(grep '^STEP|' "$ENS_WIN_LOG" | sed 's/^STEP|//' || true)"
    ENS_WIN_STEPS_RAW="$(grep '^STEP|' "$ENS_WIN_LOG" || true)"
  else
    STEPS=""
  fi
  # Synthesize the canonical $CELL_LOG: per-candidate CANDIDATE| diagnostics + the winning STEP| witness + the
  # aggregate INVARIANT| as the LAST such line (both consumers take the last INVARIANT|).
  {
    echo "run-invariant-hunt.sh: [ensemble] $ENSEMBLE_CANDIDATES candidates, aggregate $VERD"
    for ens_r in ${ENS_ROWS[@]+"${ENS_ROWS[@]}"}; do printf '%s\n' "$ens_r"; done
    [ -n "$ENS_WIN_STEPS_RAW" ] && printf '%s\n' "$ENS_WIN_STEPS_RAW"
    printf 'INVARIANT|%s|%s\n' "$TARGET" "$VERD"
  } > "$CELL_LOG"
else
  VERD="$(run_one_candidate "" "$INV_OUT" "$CELL_LOG")"
  # Collect the shrunk exploit sequence (the STEP| lines) the prover printed on a FINDING.
  STEPS="$(grep '^STEP|' "$CELL_LOG" | sed 's/^STEP|//' || true)"
fi

# PERSIST: copy any `invpat:*` the prover wrote this run (on a FINDING) back OUT to the persistent store,
# so the NEXT run on the same class recalls it. Skipped (no-op) when --pattern-store was not supplied.
if [ -n "$PATTERN_STORE" ]; then
  bridge_invpat "$RUN" "$PATTERN_STORE"
fi

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
  echo "  not a verdict. TRANSIENT_ERROR (#2033) means forge was starved/killed/timed out under concurrent batch"
  echo "  load AFTER the gate's retries — the harness is VALID and this cell is RE-RUN, distinct from HARNESS_ERROR."
  echo "  A FINDING is a LEAD a human triages — this colony NEVER auto-submits."
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

# #1732 — COMPLEMENTARY SYMBOLIC / BMC ORACLE. Runs AFTER the primary $REPORT is written (the fuzzer verdict is
# already finalized) and BEFORE the #1731 replay block below clobbers test/*.t.sol, so $INV_OUT is intact. The
# whole block is gated on $SYMBOLIC_ORACLE: with the flag off it never runs => byte-identical to today. It only
# APPENDS a `## Symbolic oracle (complementary)` section to $REPORT and emits a SYMBOLIC| stderr marker; it does
# NOT read or alter $VERD, the INVARIANT| marker, or verified_findings.json (the fuzzer stays the sole verdict).
if [ -n "$SYMBOLIC_ORACLE" ]; then
  symbolic_oracle "$REPORT"
fi

# #1731 — CROSS-RUN ENSEMBLE / UNION: replay the accumulated union of PRIOR hypotheses, then accumulate THIS
# run's invariant, then prune to the cap. Gated on --replay-corpus AND --pattern-store (else a no-op, so the
# default pipeline is byte-identical to today). Order is deliberate: (a) REPLAY the corpus AS IT STANDS from
# prior runs — this run is EXCLUDED because accumulation (b) happens after — so replay = the true prior union;
# (b) ACCUMULATE this run's generated invariant (on a FINDING OR CLEAN only), content-addressed by its sha256 so
# an identical hypothesis is stored once (dedup); (c) PRUNE to CORPUS_MAX most-recent (bounding BOTH storage and
# next-run replay cost). The replay clobbers the run repo's test/ dir, so this run's INV_OUT is preserved FIRST.
if [ -n "$REPLAY_CORPUS" ] && [ -n "$PATTERN_STORE" ]; then
  CLASS_SLUG="$(printf '%s' "$CLASS" | tr -cs 'A-Za-z0-9._-' '_')"
  CORPUS_DIR="$PATTERN_STORE/corpus/$CLASS_SLUG"
  # #1471 link args for the replay gate — reproduce the prover's link_args() in PURE FRESH-DEPLOY mode only:
  # any fork/composability context references the target by on-chain address (no source import), so requiring an
  # import there is wrong. Held as an array so paths with spaces stay one argv element (shellcheck-safe).
  CORPUS_LINK_ARGS=()
  if [ -z "$FORK_URL" ] && [ -z "$FORK_TARGET" ] && [ -z "$FORK_CONTEXT" ] && [ -n "$CODE_IN_RUN" ]; then
    CORPUS_LINK_ARGS=(--require-import "$CODE_IN_RUN")
    case "$TARGET" in *:*) _tname="${TARGET#*:}" ;; *) _tname="" ;; esac
    [ -n "$_tname" ] && CORPUS_LINK_ARGS+=(--require-contract "$_tname")
  fi
  # Preserve this run's generated invariant before replay clobbers test/*.t.sol.
  THIS_INV=""
  if [ -f "$INV_OUT" ]; then THIS_INV="$RUN/this-run-invariant.t.sol"; cp "$INV_OUT" "$THIS_INV"; fi
  # (a) REPLAY the prior union (this run not yet accumulated).
  replay_corpus "$CORPUS_DIR" "$REPORT"
  # (b) ACCUMULATE this run's invariant (FINDING|CLEAN only), content-addressed => dedup.
  case "$VERD" in
    FINDING|CLEAN)
      if [ -n "$THIS_INV" ]; then
        if command -v sha256sum >/dev/null 2>&1; then _sha="$(sha256sum "$THIS_INV" | cut -d' ' -f1)"
        elif command -v shasum >/dev/null 2>&1; then _sha="$(shasum -a 256 "$THIS_INV" | cut -d' ' -f1)"
        else _sha=""; fi
        if [ -n "$_sha" ]; then
          mkdir -p "$CORPUS_DIR"
          cp "$THIS_INV" "$CORPUS_DIR/$_sha.t.sol"
          echo "run-invariant-hunt.sh: accumulated this run's $VERD invariant into the corpus ($CLASS_SLUG/$_sha.t.sol)" >&2
        fi
      fi
      ;;
  esac
  # (c) PRUNE to CORPUS_MAX most-recent (most-recent eviction; bounds storage AND replay). A while-read loop (not
  # `xargs rm`) so an empty over-cap set cannot make rm error out under `set -e`.
  if [ -d "$CORPUS_DIR" ]; then
    ls -t "$CORPUS_DIR"/*.t.sol 2>/dev/null | tail -n +"$((CORPUS_MAX + 1))" | while IFS= read -r _old; do
      [ -n "$_old" ] && rm -f "$_old"
    done
  fi
fi

echo >&2
echo "================ INVARIANT-HUNT: $TARGET -> $VERD ================" >&2
echo "run-invariant-hunt.sh: verdict + any witness at $REPORT" >&2
if [ "$VERD" = "FINDING" ]; then
  echo "run-invariant-hunt.sh: a multi-step invariant was BROKEN — the shrunk exploit sequence is a reproducible witness a human triages. This colony never auto-submits." >&2
elif [ "$VERD" = "CLEAN" ]; then
  echo "run-invariant-hunt.sh: every deep invariant held across the fuzzed search — no finding in this budget (not a proof of safety). Nothing to triage." >&2
elif [ "$VERD" = "TRANSIENT_ERROR" ]; then
  echo "run-invariant-hunt.sh: TRANSIENT_ERROR (#2033) — forge was starved/killed/timed out under concurrent batch load; the harness is VALID and this cell is RE-RUNNABLE (re-hunted on resume), NOT an untestable zone. Distinct from HARNESS_ERROR." >&2
else
  echo "run-invariant-hunt.sh: HARNESS_ERROR — the test did not compile / no invariant matched / forge absent. No verdict was produced." >&2
fi
