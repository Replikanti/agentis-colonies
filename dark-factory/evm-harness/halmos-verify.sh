#!/usr/bin/env bash
# halmos-verify.sh — the SYMBOLIC / exhaustive verification gate for the discovery track.
#
# forge-verify.sh (its sibling) EXECUTES a single concrete PoC tx and reports VERIFIED iff that one
# path breaks an invariant. halmos-verify.sh is the SOUND, exhaustive oracle: it runs Halmos
# (symbolic execution + an SMT solver, z3) over a `*.t.sol` spec and either PROVES a property holds
# for ALL inputs, or returns a CONCRETE counterexample input that violates it. There is no sampling
# and no flakiness — on a clean PROVED/COUNTEREXAMPLE verdict the correctness is the solver's, not a
# heuristic's. (See dark-factory/docs/halmos.md for how this fits the epic.)
#
# A spec function name starts with the `--function` prefix (default `check`); each such function
# asserts an invariant over its symbolic arguments. By convention `check_*` asserts the property
# directly; Halmos proves it or refutes it with a witness.
#
# Usage:
#   halmos-verify.sh --repo <foundry-project-root> --target <Spec.t.sol>
#                    [--function <prefix>] [--timeout <seconds>]
#
# Verdict / exit contract:
#   PROVED         exit 0  — summary shows `M failed` == 0 with >=1 passed: holds for ALL inputs.
#   COUNTEREXAMPLE exit 1  — >=1 `failed` / a `Counterexample:` block: a concrete input is a real bug.
#   INCONCLUSIVE   exit 3  — timeout / `unknown` / unbounded loop / no functions matched: no verdict.
#   harness/usage  exit 2  — bad args, repo is not a foundry project, or halmos/forge not installed.
set -euo pipefail

REPO=""
TARGET=""
FUNCTION="check"
# Per-assertion solver timeout in seconds. Halmos accepts a unit suffix; we pass milliseconds so the
# value reads naturally in seconds at the CLI. 0 would mean "no timeout" to halmos — we keep a finite
# default so the gate cannot hang a pipeline.
TIMEOUT="60"

usage() { sed -n '2,33p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="${2:-}"; shift 2 ;;
    --target)   TARGET="${2:-}"; shift 2 ;;
    --function) FUNCTION="${2:-}"; shift 2 ;;
    --timeout)  TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "halmos-verify: unknown arg $1" >&2; exit 2 ;;
  esac
done

# --- usage / harness validation -----------------------------------------------------------------
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "halmos-verify: --repo <foundry project root> required" >&2; exit 2; }
[ -f "$REPO/foundry.toml" ] || { echo "halmos-verify: $REPO is not a foundry project (no foundry.toml)" >&2; exit 2; }
[ -n "$TARGET" ] || { echo "halmos-verify: --target <Spec.t.sol> required" >&2; exit 2; }
# Resolve the target relative to the repo if it is not an absolute / cwd-relative path.
if [ -f "$TARGET" ]; then
  TARGET_PATH="$TARGET"
elif [ -f "$REPO/$TARGET" ]; then
  TARGET_PATH="$REPO/$TARGET"
else
  echo "halmos-verify: target spec not found: $TARGET" >&2; exit 2
fi
[ -n "$FUNCTION" ] || { echo "halmos-verify: --function prefix must be non-empty" >&2; exit 2; }
case "$TIMEOUT" in
  ''|*[!0-9]*) echo "halmos-verify: --timeout must be a whole number of seconds" >&2; exit 2 ;;
esac

# --- tool presence ------------------------------------------------------------------------------
# halmos drives `forge build` for compilation, so both must be on PATH. We do NOT hardcode any
# install location — the caller is responsible for exporting the toolchain onto PATH.
command -v forge >/dev/null 2>&1 || {
  echo "halmos-verify: forge not installed (run foundryup; https://getfoundry.sh)" >&2; exit 2; }
command -v halmos >/dev/null 2>&1 || {
  echo "halmos-verify: halmos not installed (run: uv tool install halmos)" >&2; exit 2; }

# --- scope to the contracts declared in the target spec -----------------------------------------
# halmos selects by contract name, not file path. Pull every `contract <Name>` out of the target
# and build a `--match-contract '^(A|B|...)$'` regex so the run is scoped to exactly this spec file.
CONTRACTS="$(
  grep -E '^[[:space:]]*contract[[:space:]]+[A-Za-z_]' "$TARGET_PATH" 2>/dev/null \
    | sed -E 's/^[[:space:]]*contract[[:space:]]+([A-Za-z0-9_]+).*/\1/' \
    | paste -sd '|' - || true
)"
[ -n "$CONTRACTS" ] || { echo "halmos-verify: no contract declarations found in $TARGET_PATH" >&2; exit 2; }
MATCH_CONTRACT="^(${CONTRACTS})\$"

TIMEOUT_MS=$((TIMEOUT * 1000))
echo "== halmos-verify: symbolic-checking $(basename "$TARGET_PATH") (functions ${FUNCTION}*, ${TIMEOUT}s/assertion) ==" >&2

# Capture combined output; halmos's own exit status is unreliable for the verdict (it can exit 0 even
# with a failing test), so we parse the structured summary it prints instead.
OUT="$(
  cd "$REPO" && halmos \
    --function "$FUNCTION" \
    --match-contract "$MATCH_CONTRACT" \
    --solver-timeout-assertion "${TIMEOUT_MS}ms" \
    2>&1
)" || true
echo "$OUT" >&2

# --- parse the verdict --------------------------------------------------------------------------
# Halmos prints one summary line per run: `Symbolic test result: N passed; M failed; ...`.
# `|| true` keeps a no-match grep (an errored run with no summary) from tripping `set -e`.
SUMMARY="$(printf '%s\n' "$OUT" | grep -E 'Symbolic test result:' | tail -1 || true)"

banner() { echo "================ HALMOS-VERIFY: $1 ================" >&2; }

if [ -z "$SUMMARY" ]; then
  # No summary at all: halmos errored before producing a verdict (e.g. `No tests with --match-...`,
  # a compile failure, or a crash). Not a proof and not a refutation -> inconclusive.
  banner "INCONCLUSIVE (no symbolic test result; nothing matched / run did not complete)"
  exit 3
fi

PASSED="$(printf '%s\n' "$SUMMARY" | sed -E 's/.*result:[[:space:]]*([0-9]+) passed.*/\1/')"
FAILED="$(printf '%s\n' "$SUMMARY" | sed -E 's/.*passed;[[:space:]]*([0-9]+) failed.*/\1/')"
case "$PASSED" in ''|*[!0-9]*) PASSED=0 ;; esac
case "$FAILED" in ''|*[!0-9]*) FAILED=0 ;; esac

# An `unknown`/timeout/unbounded-loop signal means a path could not be decided: even with 0 reported
# failures the result is NOT a sound proof. Treat any such marker as INCONCLUSIVE. NB halmos phrases an
# under-unrolled loop as `paths have not been fully explored due to the loop` + a `#loop-bound` wiki link
# (NOT "loop limit"), so a loop-containing spec that exceeds the unroll bound must NOT pass as PROVED —
# match halmos's ACTUAL wording, not a guess.
if printf '%s\n' "$OUT" | grep -qiE 'timed out|timeout|\bunknown\b|loop[ -]?(limit|bound)|unbounded|incomplete|not( been)? fully explored'; then
  banner "INCONCLUSIVE (solver returned unknown / a path timed out / a loop was not fully explored)"
  exit 3
fi

if [ "$FAILED" -gt 0 ] || printf '%s\n' "$OUT" | grep -q 'Counterexample:'; then
  banner "COUNTEREXAMPLE (a concrete input violates the property — real bug, ${FAILED} failing)"
  exit 1
fi

if [ "$PASSED" -ge 1 ]; then
  banner "PROVED (property holds for ALL inputs — ${PASSED} proven, 0 counterexamples)"
  exit 0
fi

# 0 passed, 0 failed, summary present but no proof: nothing was actually checked.
banner "INCONCLUSIVE (0 passed / 0 failed — no property was checked)"
exit 3
