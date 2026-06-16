#!/usr/bin/env bash
# forge-invariant.sh — the STATEFUL-FUZZING verification gate for the discovery track (#1035).
#
# halmos-verify.sh (its symbolic sibling) PROVES a single-function property over all inputs; forge-verify.sh
# EXECUTES one concrete PoC tx. Neither finds the bugs that only emerge from a MULTI-STEP, multi-caller
# SEQUENCE of calls (the ERC4626 inflation attack, an accounting drift that compounds, a re-entrancy that
# only breaks on the third interleave) — exactly the class that survives a single-function audit.
#
# This gate runs Foundry's built-in STATEFUL INVARIANT FUZZER over a `*.t.sol` test: a `Handler` exposes the
# protocol's actions as bounded actor functions, the fuzzer drives randomized call sequences through it, and
# after every call it re-checks each `invariant_*` function. If ANY invariant breaks, Foundry SHRINKS the
# offending sequence to a minimal reproducer and reports it. The verdict is the FUZZER's: a failed invariant
# + a concrete shrunk call-sequence is a CANDIDATE finding (a reproducible exploit witness); all invariants
# holding is CLEAN. There is no LLM opinion in the verdict — only forge's pass/fail + the witness.
#
# The harness is forge-std-free by design (like evm-harness/halmos-specs): the invariant test registers its
# fuzz targets via a `targetContracts() returns (address[])` view (the StdInvariant ABI forge auto-discovers)
# and asserts with plain `require(...)`, so it compiles in ANY foundry project with zero library remappings.
#
# FM1 (#1041) — FORK MODE. The optional `--fork-url <rpc> [--fork-block <n>]` pair runs the same handler +
# deep invariants against FORKED REAL ON-CHAIN STATE (the actual deployed contract at a pinned block) instead
# of a fresh deploy. When set, the gate threads forge's own `--fork-url <rpc> [--fork-block-number <n>]` into
# the `forge test` invocation (forge 1.7.1 spelling; `--fork-url` aliases `--rpc-url`). A fork RPC failure
# (unreachable / rate-limited / "could not instantiate forked environment") yields NO parseable result, so the
# existing "no parseable result / no invariant ran" path returns HARNESS_ERROR (2) — never a false CLEAN/
# FINDING. When `--fork-url` is UNSET the forge command is BYTE-IDENTICAL to the no-fork build.
#
# Usage:
#   forge-invariant.sh --repo <foundry-project-root> --target <Invariant.t.sol>
#                      [--match <invariant_ prefix>] [--runs N] [--depth D] [--seed S]
#                      [--fork-url <http(s)-rpc>] [--fork-block <n>]
#
# Verdict / exit contract (mirrors halmos-verify.sh's shape):
#   CLEAN          exit 0  — >=1 invariant ran and ALL held across every fuzzed sequence: no finding.
#   FINDING        exit 1  — >=1 invariant FAILED; the shrunk exploit sequence is printed to stderr and
#                            captured in the JSON. A reproducible multi-step witness -> a CANDIDATE.
#   HARNESS_ERROR  exit 2  — bad args, repo is not a foundry project, forge missing, compile/setup error,
#                            no invariant function matched (nothing was actually checked), or a fork RPC
#                            that was unreachable / could not instantiate the forked environment.
set -uo pipefail

REPO=""
TARGET=""
MATCH="invariant"
RUNS=""
DEPTH=""
SEED=""
FORK_URL=""
FORK_BLOCK=""

usage() { sed -n '2,39p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --match)  MATCH="${2:-}"; shift 2 ;;
    --runs)   RUNS="${2:-}"; shift 2 ;;
    --depth)  DEPTH="${2:-}"; shift 2 ;;
    --seed)   SEED="${2:-}"; shift 2 ;;
    --fork-url)   FORK_URL="${2:-}"; shift 2 ;;
    --fork-block) FORK_BLOCK="${2:-}"; shift 2 ;;
    # FM2 (#1041): --fork-context <role=addr;...> is a GENERATION-PROMPT hint (the composability context set the
    # prover reads). The fuzzer auto-discovers its fuzz targets from the test's `targetContracts()` view, so the
    # gate itself needs nothing from the context — it ACCEPTS and IGNORES the flag so a composability-mode caller
    # (run-invariant-hunt.sh / the prover-gate wrapper) can forward it uniformly without an "unknown arg" error.
    --fork-context) shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "forge-invariant: unknown arg $1" >&2; exit 2 ;;
  esac
done

# --- usage / harness validation -----------------------------------------------------------------
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "forge-invariant: --repo <foundry project root> required" >&2; exit 2; }
[ -f "$REPO/foundry.toml" ] || { echo "forge-invariant: $REPO is not a foundry project (no foundry.toml)" >&2; exit 2; }
[ -n "$TARGET" ] || { echo "forge-invariant: --target <Invariant.t.sol> required" >&2; exit 2; }
if [ -f "$TARGET" ]; then
  TARGET_PATH="$TARGET"
elif [ -f "$REPO/$TARGET" ]; then
  TARGET_PATH="$REPO/$TARGET"
else
  echo "forge-invariant: target test not found: $TARGET" >&2; exit 2
fi
[ -n "$MATCH" ] || { echo "forge-invariant: --match prefix must be non-empty" >&2; exit 2; }
for v in "$RUNS" "$DEPTH" "$SEED"; do
  case "$v" in '') ;; *[!0-9]*) echo "forge-invariant: --runs/--depth/--seed must be whole numbers" >&2; exit 2 ;; esac
done
# FM1 (#1041): fork-arg shape validation. --fork-url must look like an http(s) URL (a typo'd / non-URL value
# must be a clean usage error, not a forge invocation that fails opaquely). --fork-block must be a whole number.
# --fork-block without --fork-url is meaningless (forge ignores it without a fork), so reject it up front.
case "$FORK_URL" in
  '') ;;
  http://*|https://*) ;;
  *) echo "forge-invariant: --fork-url must be an http(s) URL (got: $FORK_URL)" >&2; exit 2 ;;
esac
case "$FORK_BLOCK" in '') ;; *[!0-9]*) echo "forge-invariant: --fork-block must be a whole number" >&2; exit 2 ;; esac
[ -z "$FORK_BLOCK" ] || [ -n "$FORK_URL" ] || { echo "forge-invariant: --fork-block requires --fork-url (a fork block is meaningless without a fork)" >&2; exit 2; }

# --- tool presence ------------------------------------------------------------------------------
# We do NOT hardcode any install location — the caller exports the toolchain onto PATH.
command -v forge >/dev/null 2>&1 || {
  echo "forge-invariant: forge not installed (run foundryup; https://getfoundry.sh)" >&2; exit 2; }

FORK_NOTE=""
[ -n "$FORK_URL" ] && FORK_NOTE=" [fork=${FORK_URL}${FORK_BLOCK:+@${FORK_BLOCK}}]"
echo "== forge-invariant: stateful-fuzzing $(basename "$TARGET_PATH") (invariants ${MATCH}*)${FORK_NOTE} ==" >&2

# Build forge's invariant args. --match-path scopes to exactly this test file; --match-test to the
# invariant_* functions. A finite seed makes the run reproducible (the demo pins it). forge has no CLI flag
# for invariant runs/depth — those are tuned via the FOUNDRY_INVARIANT_RUNS / FOUNDRY_INVARIANT_DEPTH env
# vars (exported below), which override the project's [invariant] config; left to it when unset.
# HARNESS ISOLATION (#1069): `forge test` compiles the WHOLE project, including the target's OWN
# `*.t.sol` files. A real-world target whose own tests do not compile under our forge/solc (e.g. a
# function declared `view` that the compiler now rejects as state-modifying — solc drift in the
# target's tests) would block even a fully self-contained generated harness, degrading a real run to
# HARNESS_ERROR for a reason unrelated to our harness or the target's source. So we --skip every OTHER
# `*.sol` under the target's test dir from COMPILATION, keeping only this harness + `src`. The harness
# is self-contained by construction, so this is sound. (forge --skip is Rust-regex with no lookahead,
# hence enumerate-and-skip-each rather than one "all-but-harness" pattern; each path is its own array
# element so no value can mangle a flag.) Targets whose tests compile cleanly are unaffected — skipping
# files that would have compiled is a no-op for this single-harness run.
SKIP_ARGS=()
_harness_abs="$(cd "$(dirname "$TARGET_PATH")" 2>/dev/null && pwd)/$(basename "$TARGET_PATH")"
if [ -d "$REPO/test" ]; then
  while IFS= read -r _tf; do
    [ -n "$_tf" ] || continue
    [ "$(cd "$(dirname "$_tf")" && pwd)/$(basename "$_tf")" = "$_harness_abs" ] && continue
    SKIP_ARGS+=(--skip "${_tf#"$REPO"/}")
  done < <(find "$REPO/test" -type f -name '*.sol' 2>/dev/null)
fi

# `${SKIP_ARGS[@]+"..."}` (not a bare `"${SKIP_ARGS[@]}"`): under `set -u`, expanding an EMPTY array
# the bare way is an unbound-variable error on bash < 4.4 (stock macOS bash 3.2) — a target with no
# OTHER test files leaves SKIP_ARGS empty. The `+` alternate form expands to nothing when empty, safely.
ARGS=(test --match-path "$TARGET_PATH" --match-test "$MATCH" --json ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"})
[ -n "$SEED" ] && ARGS+=(--fuzz-seed "$SEED")
[ -n "$RUNS" ]  && export FOUNDRY_INVARIANT_RUNS="$RUNS"
[ -n "$DEPTH" ] && export FOUNDRY_INVARIANT_DEPTH="$DEPTH"
# FM1 (#1041): FORK MODE. Append forge's own fork flags ONLY when --fork-url is set, so the no-fork build is
# byte-identical to today. forge 1.7.1: `--fork-url <rpc>` (aliases --rpc-url) + `--fork-block-number <n>`.
# Each value is an array element (never a concatenated string), so no content can mangle a flag, and a fork
# that cannot be instantiated leaves forge with no parseable result -> the no-result path returns
# HARNESS_ERROR (2) below, never a false verdict.
if [ -n "$FORK_URL" ]; then
  ARGS+=(--fork-url "$FORK_URL")
  [ -n "$FORK_BLOCK" ] && ARGS+=(--fork-block-number "$FORK_BLOCK")
fi

# A scratch dir for this run's JSON + parser. Trapped so we never leak temp files.
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/forge-invariant.XXXXXX")" || { echo "forge-invariant: cannot create temp dir" >&2; exit 2; }
trap 'rm -rf "$TMPD"' EXIT

# Capture forge's JSON to a file (forge prints the suite object to stdout on --json; build/setup errors go
# to stderr). forge's own exit status is 1 on a failing test, but we parse the structured output for the
# verdict rather than trust the code (a compile error and a real finding both exit non-zero — only the
# parse distinguishes them).
( cd "$REPO" && forge "${ARGS[@]}" ) >"$TMPD/out.json" 2>"$TMPD/err.txt" || true
# Re-run WITHOUT --json so the shrunk sequence + traces are visible in logs (stderr). Build the no-json arg
# list by element so we never mangle a flag (a `${ARR[@]/--json/}` substring substitution leaves an empty
# element behind). A fixed seed keeps the human run aligned with the json run.
HUMAN_ARGS=()
for a in "${ARGS[@]}"; do [ "$a" = "--json" ] || HUMAN_ARGS+=("$a"); done
# Append a fallback --fuzz-seed ONLY when SEED is unset — when SEED is set it is ALREADY in ARGS/HUMAN_ARGS, and
# forge rejects a repeated --fuzz-seed ("cannot be used multiple times"), which would suppress the readable
# table. A fixed seed keeps the human run aligned with the json run either way.
if [ -n "$SEED" ]; then
  ( cd "$REPO" && forge "${HUMAN_ARGS[@]}" 1>&2 2>&1 ) || true
else
  ( cd "$REPO" && forge "${HUMAN_ARGS[@]}" --fuzz-seed 1 1>&2 2>&1 ) || true
fi

banner() { echo "================ FORGE-INVARIANT: $1 ================" >&2; }

# --- parse the verdict from forge's --json ------------------------------------------------------
# forge --json emits a per-suite object (sometimes several concatenated values): { "<path>:<Contract>": {
# "test_results": { "<fn>()": { "status": "Success"|"Failure", "reason": "...", "counterexample": {
# "Sequence": [...] } } } } }. We do not depend on jq; a small python reads the structure with a raw_decode
# loop (robust to a single object OR several concatenated ones), counts ran/failed invariants, and pulls the
# shrunk sequence text. The JSON is passed as a FILE argument (never stdin) so the heredoc body cannot be
# confused for input.
#
# FM1 (#1041) SAFETY: a fork/backend error (an unreachable or non-archive RPC that cannot serve the forked
# state forge touches mid-fuzz) is reported by forge as the invariant function with status=Failure and a
# `reason` like "failed to set up invariant testing environment / database error / could not instantiate
# forked environment" — and NO counterexample sequence. That is a HARNESS error, NOT a real FINDING. We
# classify any such Failure as a SETUP error (counted separately, never as a finding), so a flaky/non-archive
# fork RPC can NEVER surface a false FINDING — it degrades to HARNESS_ERROR (the FM1 contract).
cat > "$TMPD/parse.py" <<'PY'
import sys, json
match = sys.argv[1]
raw = open(sys.argv[2]).read().strip()
dec = json.JSONDecoder()
# Reason substrings that mark a HARNESS/fork/backend failure rather than a genuine invariant break.
SETUP_MARKERS = (
    "failed to set up", "setup", "set up invariant",
    "could not make raw evm call", "database error", "evm error",
    "could not instantiate forked", "backend", "historical state",
    "is not available", "error sending request", "rpc",
)
def has_counterexample(res):
    # A genuine invariant break always carries a counterexample (the shrunk failing
    # call-SEQUENCE). A fork/backend/setup failure never does. So the presence of a
    # counterexample is the decisive signal that this is a REAL finding, not a setup error.
    cex = (res or {}).get("counterexample")
    return bool(cex)
def is_setup_failure(res):
    # A HARNESS/fork/backend failure is a Failure whose `reason` matches a setup marker AND
    # which carries NO counterexample. The no-counterexample gate is decisive: it prevents a
    # genuine invariant break whose revert string merely CONTAINS a marker word (e.g. "...setup
    # budget", "...rpc id") from being misclassified as a setup error and silently dropped.
    if has_counterexample(res):
        return False
    reason = (res or {}).get("reason") or ""
    rl = reason.lower()
    for m in SETUP_MARKERS:
        if m in rl:
            return True
    return False
objs = []; idx = 0
while idx < len(raw):
    while idx < len(raw) and raw[idx] in ' \t\r\n':
        idx += 1
    if idx >= len(raw):
        break
    try:
        obj, end = dec.raw_decode(raw, idx)
    except Exception:
        break
    objs.append(obj); idx = end
if not objs:
    print("PARSE_ERROR"); sys.exit(0)
ran = 0; failed = 0; setup_err = 0; seqs = []
for obj in objs:
    if not isinstance(obj, dict):
        continue
    for suite in obj.values():
        if not isinstance(suite, dict):
            continue
        results = suite.get("test_results", {})
        if not isinstance(results, dict):
            continue
        for fn, res in results.items():
            if not fn.startswith(match):
                continue
            if (res or {}).get("status", "") == "Failure" and is_setup_failure(res):
                # A fork/backend/setup error — NOT a checked invariant, NOT a finding. Do not count it as ran.
                setup_err += 1
                continue
            ran += 1
            if (res or {}).get("status", "") == "Failure":
                failed += 1
                cex = (res or {}).get("counterexample") or {}
                seq = cex.get("Sequence") if isinstance(cex, dict) else None
                # forge nests the sequence as [<n>, [ {step}, ... ]] or just [ {step}, ... ].
                calls = None
                if isinstance(seq, list):
                    for el in seq:
                        if isinstance(el, list):
                            calls = el
                            break
                    if calls is None and seq and isinstance(seq[0], dict):
                        calls = seq
                steps = []
                for c in (calls or []):
                    if not isinstance(c, dict):
                        continue
                    fn_name = c.get("func_name") or c.get("signature") or "?"
                    steps.append("%s(%s)  [sender=%s]" % (fn_name, c.get("args", ""), c.get("sender", "")))
                seqs.append((fn.rstrip("()"), steps))
print("RAN=%d" % ran)
print("FAILED=%d" % failed)
print("SETUP_ERR=%d" % setup_err)
for label, steps in seqs:
    print("SEQBEGIN=%s" % label)
    for i, s in enumerate(steps, 1):
        print("  step %d: %s" % (i, s))
    print("SEQEND")
PY
PARSE="$(python3 "$TMPD/parse.py" "$MATCH" "$TMPD/out.json" 2>/dev/null || true)"
ERROUT="$(cat "$TMPD/err.txt" 2>/dev/null || true)"

RAN="$(printf '%s\n' "$PARSE" | sed -n 's/^RAN=//p' | head -1)"
FAILED="$(printf '%s\n' "$PARSE" | sed -n 's/^FAILED=//p' | head -1)"
SETUP_ERR="$(printf '%s\n' "$PARSE" | sed -n 's/^SETUP_ERR=//p' | head -1)"
case "$RAN" in    ''|*[!0-9]*) RAN=0 ;; esac
case "$FAILED" in ''|*[!0-9]*) FAILED=0 ;; esac
case "$SETUP_ERR" in ''|*[!0-9]*) SETUP_ERR=0 ;; esac

# A PARSE_ERROR (forge produced no JSON object) or a compile/setup failure means nothing was checked. In FORK
# MODE this same path also catches an unreachable / rate-limited RPC or a "could not instantiate forked
# environment" — forge emits no parseable suite object, so the verdict is HARNESS_ERROR (2), NEVER a false
# CLEAN/FINDING (the FM1 #1041 safety contract).
if printf '%s' "$PARSE" | grep -q 'PARSE_ERROR' || [ ! -s "$TMPD/out.json" ]; then
  if [ -n "$FORK_URL" ]; then
    banner "HARNESS_ERROR (forge produced no parseable result — compile/setup error, no test ran, or the fork RPC was unreachable / could not instantiate the forked environment)"
  else
    banner "HARNESS_ERROR (forge produced no parseable result — compile/setup error or no test ran)"
  fi
  printf '%s\n' "$ERROUT" | grep -iE 'error|compil|panic|fork|rpc' | head -5 >&2 || true
  exit 2
fi

# FM1 (#1041) SAFETY: a fork/backend/setup error (forge reports the invariant as Failure with a setup/database/
# RPC `reason` and no counterexample) means the forked state could NOT be served, so the invariant was never
# genuinely fuzzed. That is HARNESS_ERROR — never a false FINDING/CLEAN. Checked BEFORE the FAILED>0 branch so a
# fork that died mid-fuzz can never be mistaken for a reproduced exploit. This is the exact failure mode of a
# non-archive / pruned RPC asked for a block outside its recent-state window.
if [ "$SETUP_ERR" -gt 0 ] && [ "$FAILED" -eq 0 ]; then
  banner "HARNESS_ERROR (${SETUP_ERR} invariant(s) failed at setup — fork/backend/RPC could not serve the forked state; nothing was actually checked, NOT a finding)"
  printf '%s\n' "$ERROUT" | grep -iE 'historical state|not available|database error|forked environment|error sending request|rpc' | head -5 >&2 || true
  exit 2
fi

# No invariant matched the prefix (or every match was a setup error) -> nothing was actually fuzzed -> not a
# verdict.
if [ "$RAN" -eq 0 ]; then
  if [ "$SETUP_ERR" -gt 0 ]; then
    banner "HARNESS_ERROR (no invariant ran — ${SETUP_ERR} failed at setup, the fork/backend could not serve the forked state; nothing was checked)"
  else
    banner "HARNESS_ERROR (no invariant_* function matched '${MATCH}' — nothing was checked)"
  fi
  exit 2
fi

if [ "$FAILED" -gt 0 ]; then
  banner "FINDING (${FAILED} invariant(s) broken by a multi-step sequence — reproducible witness below)"
  # Surface the shrunk exploit sequence(s) so the operator + the .ag can capture them.
  printf '%s\n' "$PARSE" | awk '
    /^SEQBEGIN=/ { sub(/^SEQBEGIN=/,""); print "-- broken invariant: " $0 " — shrunk exploit sequence:"; next }
    /^SEQEND$/   { next }
    /^RAN=|^FAILED=|^SETUP_ERR=/ { next }
    { print }
  ' >&2
  exit 1
fi

banner "CLEAN (${RAN} invariant(s) held across every fuzzed call-sequence — no finding)"
exit 0
