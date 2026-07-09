#!/usr/bin/env bash
# forge-poc.sh — the CONCRETE-EXPLOIT verdict gate for FOUNDRY projects (#1507).
#
# The foundry sibling of hardhat-poc.sh and a thin cousin of forge-invariant.sh. forge-invariant.sh runs the
# stateful-invariant FUZZER over a `Handler` and treats a BROKEN invariant as the finding; this gate runs a
# single hand-driven CONCRETE attack-SEQUENCE PoC (`forge test --match-test <prefix>`, default `test`, NOT
# `invariant`) and treats a PASSING test as the finding. A concrete PoC is written to PASS iff the exploit works,
# so this gate INVERTS forge's natural pass/fail polarity — forge exits 0 on a passing test, but a passing
# exploit PoC is a FINDING, not a clean run.
#
#   INVERTED POLARITY (the one subtlety):
#     a matched test with status Success -> FINDING       (exit 1) — the exploit reproduced -> a CANDIDATE
#     a matched test that ran + Failure  -> CLEAN         (exit 0) — the exploit assertion did not hold
#     no test matched / no parseable JSON / compile error -> HARNESS_ERROR (exit 2) — NOT a verdict
#   The inversion lives ENTIRELY here (in the parse+classify), documented in this header. No counterexample /
#   sequence parsing — that is invariant-specific; a concrete PoC IS the sequence.
#
# #1471 — TARGET-LINKAGE GATE (anti-fabrication), the SAME static check as forge-invariant.sh: with
# `--require-import <target-src>` (+ `--require-contract <Name>`) the test must import a path ending in the target
# basename AND (when a name is given) NOT declare its OWN `contract <Name>` shadow. A miss => HARNESS_ERROR (2).
# When `--require-import` is empty the block is a no-op. Runs BEFORE forge so a substituted target is rejected
# without any compile/fuzz spend.
#
# Usage:
#   forge-poc.sh --repo <foundry-project-root> --target <Poc_*.t.sol>
#                [--match <test-fn prefix, default "test">]
#                [--require-import <target-src>] [--require-contract <Name>]
#
# Verdict / exit contract (IDENTICAL to forge-invariant.sh / hardhat-poc.sh):
#   CLEAN          exit 0  — the matched PoC test ran and FAILED (the exploit assertion did not hold): no finding.
#   FINDING        exit 1  — the matched PoC test ran and PASSED: the exploit reproduced -> a CANDIDATE.
#   HARNESS_ERROR  exit 2  — bad args, repo is not a foundry project, forge missing, compile/setup error, no test
#                            matched the prefix, no parseable JSON, or (#1471) the target-linkage gate rejected it.
set -uo pipefail

REPO=""
TARGET=""
MATCH="test"
REQ_IMPORT=""
REQ_CONTRACT=""

usage() { sed -n '2,40p' "$0"; }

banner() { echo "================ FORGE-POC: $1 ================" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --match)  MATCH="${2:-}"; shift 2 ;;
    --require-import)   REQ_IMPORT="${2:-}"; shift 2 ;;
    --require-contract) REQ_CONTRACT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "forge-poc: unknown arg $1" >&2; exit 2 ;;
  esac
done

# --- usage / harness validation -----------------------------------------------------------------
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "forge-poc: --repo <foundry project root> required" >&2; exit 2; }
# Resolve --repo to ABSOLUTE up front (mirrors run-poc.sh's `REPO="$(cd "$REPO" && pwd)"`). `forge` below runs
# inside a `cd "$REPO"` subshell with "$TARGET_PATH" re-referenced there — a RELATIVE --repo would double the
# path (a false HARNESS_ERROR when hand-invoked outside the run-poc.sh pipeline, #1531).
REPO="$(cd "$REPO" && pwd)"
[ -f "$REPO/foundry.toml" ] || { echo "forge-poc: $REPO is not a foundry project (no foundry.toml)" >&2; exit 2; }
[ -n "$TARGET" ] || { echo "forge-poc: --target <Poc_*.t.sol> required" >&2; exit 2; }
if [ -f "$TARGET" ]; then
  TARGET_PATH="$TARGET"
elif [ -f "$REPO/$TARGET" ]; then
  TARGET_PATH="$REPO/$TARGET"
else
  echo "forge-poc: target test not found: $TARGET" >&2; exit 2
fi
# Same absolute-path resolution as $REPO above — TARGET_PATH is also re-referenced inside `cd "$REPO"` subshells.
TARGET_PATH="$(cd "$(dirname "$TARGET_PATH")" && pwd)/$(basename "$TARGET_PATH")"
[ -n "$MATCH" ] || { echo "forge-poc: --match prefix must be non-empty" >&2; exit 2; }

# --- #1471 TARGET-LINKAGE GATE (fresh-deploy only, runs before forge) ---------------------------
# Same static check as forge-invariant.sh: (1) an `import` line whose quoted path ENDS WITH the target basename;
# (2) when --require-contract is set, NO own `contract <Name>` shadow (a trailing non-identifier char emulates
# the word boundary so `contract FooHarness` does NOT match). A miss => HARNESS_ERROR (2). Empty => no-op.
if [ -n "$REQ_IMPORT" ]; then
  _tgt_base="$(basename "$REQ_IMPORT")"
  _tgt_base_re="$(printf '%s' "$_tgt_base" | sed 's/[^a-zA-Z0-9]/\\&/g')"
  if ! grep -Eq "^[[:space:]]*import[^;]*[\"'/]${_tgt_base_re}[\"']" "$TARGET_PATH"; then
    banner "HARNESS_ERROR (#1471 target-linkage — the PoC does not import the in-scope target (${_tgt_base}); a fabricated / substituted target is NOT a verdict)"
    exit 2
  fi
  if [ -n "$REQ_CONTRACT" ]; then
    _tgt_ctr_re="$(printf '%s' "$REQ_CONTRACT" | sed 's/[^a-zA-Z0-9]/\\&/g')"
    if grep -Eq "^[[:space:]]*contract[[:space:]]+${_tgt_ctr_re}([^A-Za-z0-9_]|$)" "$TARGET_PATH"; then
      banner "HARNESS_ERROR (#1471 target-linkage — the PoC declares its OWN 'contract ${REQ_CONTRACT}' shadow instead of importing the in-scope target; a self-authored toy is NOT a verdict)"
      exit 2
    fi
  fi
fi

# --- tool presence ------------------------------------------------------------------------------
command -v forge >/dev/null 2>&1 || { banner "HARNESS_ERROR (forge not installed — run foundryup; https://getfoundry.sh)"; exit 2; }

echo "== forge-poc: concrete-exploit PoC $(basename "$TARGET_PATH") (tests ${MATCH}*) ==" >&2

# HARNESS ISOLATION (#1069, as in forge-invariant.sh): --skip every OTHER `*.sol` under the target's test dir
# from COMPILATION so the target's own (possibly solc-drifted) tests cannot degrade a self-contained PoC to a
# false HARNESS_ERROR. Enumerate-and-skip-each (forge --skip is Rust-regex, no lookahead); each path is its own
# array element so no value can mangle a flag.
SKIP_ARGS=()
_harness_abs="$(cd "$(dirname "$TARGET_PATH")" 2>/dev/null && pwd)/$(basename "$TARGET_PATH")"
if [ -d "$REPO/test" ]; then
  while IFS= read -r _tf; do
    [ -n "$_tf" ] || continue
    [ "$(cd "$(dirname "$_tf")" && pwd)/$(basename "$_tf")" = "$_harness_abs" ] && continue
    SKIP_ARGS+=(--skip "${_tf#"$REPO"/}")
  done < <(find "$REPO/test" -type f -name '*.sol' 2>/dev/null)
fi

# `${SKIP_ARGS[@]+"..."}` (not a bare expansion): under `set -u`, expanding an EMPTY array the bare way is an
# unbound-variable error on bash < 4.4 (stock macOS bash 3.2). The `+` alternate form expands to nothing safely.
ARGS=(test --match-path "$TARGET_PATH" --match-test "$MATCH" --json ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"})

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/forge-poc.XXXXXX")" || { banner "HARNESS_ERROR (cannot create temp dir)"; exit 2; }
trap 'rm -rf "$TMPD"' EXIT

# Capture forge's JSON to a file; a failing test exits non-zero, so parse the structured output rather than trust
# the code (a compile error and a real refutation both exit non-zero — only the parse distinguishes them).
( cd "$REPO" && forge "${ARGS[@]}" ) >"$TMPD/out.json" 2>"$TMPD/err.txt" || true
# Re-run WITHOUT --json so the human-readable table + traces are visible in logs (stderr).
HUMAN_ARGS=()
for a in "${ARGS[@]}"; do [ "$a" = "--json" ] || HUMAN_ARGS+=("$a"); done
( cd "$REPO" && forge "${HUMAN_ARGS[@]}" 1>&2 2>&1 ) || true

# --- parse the verdict from forge's --json ------------------------------------------------------
# forge --json emits a per-suite object: { "<path>:<Contract>": { "test_results": { "<fn>()": { "status":
# "Success"|"Failure", ... } } } }. We count matched tests that ran (RAN) and those that PASSED (PASSED). No jq;
# a small python with a raw_decode loop (robust to one or several concatenated objects). JSON as a FILE arg.
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
ran = 0; passed = 0
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
            if (res or {}).get("status", "") == "Success":
                passed += 1
print("RAN=%d" % ran)
print("PASSED=%d" % passed)
PY
PARSE="$(python3 "$TMPD/parse.py" "$MATCH" "$TMPD/out.json" 2>/dev/null || true)"
ERROUT="$(cat "$TMPD/err.txt" 2>/dev/null || true)"

RAN="$(printf '%s\n' "$PARSE" | sed -n 's/^RAN=//p' | head -1)"
PASSED="$(printf '%s\n' "$PARSE" | sed -n 's/^PASSED=//p' | head -1)"
case "$RAN" in    ''|*[!0-9]*) RAN=0 ;; esac
case "$PASSED" in ''|*[!0-9]*) PASSED=0 ;; esac

# No parseable object / empty JSON -> compile or setup error -> nothing was checked.
if printf '%s' "$PARSE" | grep -q 'PARSE_ERROR' || [ ! -s "$TMPD/out.json" ]; then
  banner "HARNESS_ERROR (forge produced no parseable result — compile/setup error or no test ran)"
  printf '%s\n' "$ERROUT" | grep -iE 'error|compil|panic' | head -5 >&2 || true
  exit 2
fi
# No test matched the prefix -> nothing was actually run -> not a verdict.
if [ "$RAN" -eq 0 ]; then
  banner "HARNESS_ERROR (no PoC test matched '${MATCH}' — nothing was checked)"
  exit 2
fi
# INVERTED polarity: a matched PoC test that PASSED (Success) is the FINDING.
if [ "$PASSED" -ge 1 ]; then
  banner "FINDING (the concrete exploit PoC PASSED — the attack reproduced; a runnable witness a human triages)"
  exit 1
fi
banner "CLEAN (the PoC ran and FAILED — the exploit assertion did not hold in this harness; no finding)"
exit 0
