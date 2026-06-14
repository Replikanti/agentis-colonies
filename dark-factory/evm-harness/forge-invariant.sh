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
# Usage:
#   forge-invariant.sh --repo <foundry-project-root> --target <Invariant.t.sol>
#                      [--match <invariant_ prefix>] [--runs N] [--depth D] [--seed S]
#
# Verdict / exit contract (mirrors halmos-verify.sh's shape):
#   CLEAN          exit 0  — >=1 invariant ran and ALL held across every fuzzed sequence: no finding.
#   FINDING        exit 1  — >=1 invariant FAILED; the shrunk exploit sequence is printed to stderr and
#                            captured in the JSON. A reproducible multi-step witness -> a CANDIDATE.
#   HARNESS_ERROR  exit 2  — bad args, repo is not a foundry project, forge missing, compile/setup error,
#                            or no invariant function matched (nothing was actually checked).
set -uo pipefail

REPO=""
TARGET=""
MATCH="invariant"
RUNS=""
DEPTH=""
SEED=""

usage() { sed -n '2,36p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --match)  MATCH="${2:-}"; shift 2 ;;
    --runs)   RUNS="${2:-}"; shift 2 ;;
    --depth)  DEPTH="${2:-}"; shift 2 ;;
    --seed)   SEED="${2:-}"; shift 2 ;;
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

# --- tool presence ------------------------------------------------------------------------------
# We do NOT hardcode any install location — the caller exports the toolchain onto PATH.
command -v forge >/dev/null 2>&1 || {
  echo "forge-invariant: forge not installed (run foundryup; https://getfoundry.sh)" >&2; exit 2; }

echo "== forge-invariant: stateful-fuzzing $(basename "$TARGET_PATH") (invariants ${MATCH}*) ==" >&2

# Build forge's invariant args. --match-path scopes to exactly this test file; --match-test to the
# invariant_* functions. A finite seed makes the run reproducible (the demo pins it). forge has no CLI flag
# for invariant runs/depth — those are tuned via the FOUNDRY_INVARIANT_RUNS / FOUNDRY_INVARIANT_DEPTH env
# vars (exported below), which override the project's [invariant] config; left to it when unset.
ARGS=(test --match-path "$TARGET_PATH" --match-test "$MATCH" --json)
[ -n "$SEED" ] && ARGS+=(--fuzz-seed "$SEED")
[ -n "$RUNS" ]  && export FOUNDRY_INVARIANT_RUNS="$RUNS"
[ -n "$DEPTH" ] && export FOUNDRY_INVARIANT_DEPTH="$DEPTH"

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
( cd "$REPO" && forge "${HUMAN_ARGS[@]}" --fuzz-seed "${SEED:-1}" 1>&2 2>&1 ) || true

banner() { echo "================ FORGE-INVARIANT: $1 ================" >&2; }

# --- parse the verdict from forge's --json ------------------------------------------------------
# forge --json emits a per-suite object (sometimes several concatenated values): { "<path>:<Contract>": {
# "test_results": { "<fn>()": { "status": "Success"|"Failure", "counterexample": { "Sequence": [...] } } } } }.
# We do not depend on jq; a small python reads the structure with a raw_decode loop (robust to a single
# object OR several concatenated ones), counts ran/failed invariants, and pulls the shrunk sequence text.
# The JSON is passed as a FILE argument (never stdin) so the heredoc body cannot be confused for input.
cat > "$TMPD/parse.py" <<'PY'
import sys, json
match = sys.argv[1]
raw = open(sys.argv[2]).read().strip()
dec = json.JSONDecoder()
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
ran = 0; failed = 0; seqs = []
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
case "$RAN" in    ''|*[!0-9]*) RAN=0 ;; esac
case "$FAILED" in ''|*[!0-9]*) FAILED=0 ;; esac

# A PARSE_ERROR (forge produced no JSON object) or a compile/setup failure means nothing was checked.
if printf '%s' "$PARSE" | grep -q 'PARSE_ERROR' || [ ! -s "$TMPD/out.json" ]; then
  banner "HARNESS_ERROR (forge produced no parseable result — compile/setup error or no test ran)"
  printf '%s\n' "$ERROUT" | grep -iE 'error|compil|panic' | head -5 >&2 || true
  exit 2
fi

# No invariant matched the prefix -> nothing was actually fuzzed -> not a verdict.
if [ "$RAN" -eq 0 ]; then
  banner "HARNESS_ERROR (no invariant_* function matched '${MATCH}' — nothing was checked)"
  exit 2
fi

if [ "$FAILED" -gt 0 ]; then
  banner "FINDING (${FAILED} invariant(s) broken by a multi-step sequence — reproducible witness below)"
  # Surface the shrunk exploit sequence(s) so the operator + the .ag can capture them.
  printf '%s\n' "$PARSE" | awk '
    /^SEQBEGIN=/ { sub(/^SEQBEGIN=/,""); print "-- broken invariant: " $0 " — shrunk exploit sequence:"; next }
    /^SEQEND$/   { next }
    /^RAN=|^FAILED=/ { next }
    { print }
  ' >&2
  exit 1
fi

banner "CLEAN (${RAN} invariant(s) held across every fuzzed call-sequence — no finding)"
exit 0
