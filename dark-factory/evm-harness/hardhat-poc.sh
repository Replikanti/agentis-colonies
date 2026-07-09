#!/usr/bin/env bash
# hardhat-poc.sh — the CONCRETE-EXPLOIT verdict gate for HARDHAT projects (#1507).
#
# This is the hardhat sibling of forge-invariant.sh. Where forge-invariant.sh runs Foundry's stateful-invariant
# FUZZER over a `Handler` and treats a BROKEN invariant as the finding, this gate runs a single CONCRETE
# attack-SEQUENCE PoC (a mocha/ethers test that reproduces one specific exploit) and treats a PASSING test as the
# finding. A concrete PoC is written to PASS iff the exploit works, so this gate INVERTS the runner's natural
# pass/fail polarity — mocha exits 0 on pass, but a passing exploit PoC is a FINDING, not a clean run.
#
#   INVERTED POLARITY (the one subtlety):
#     test RAN + PASSED (>=1 pass, 0 failures)  -> FINDING       (exit 1) — the exploit reproduced -> a CANDIDATE
#     test RAN + FAILED (>=1 failure)           -> CLEAN         (exit 0) — the exploit assertion did not hold
#     nothing ran / compile / tooling error / linkage reject -> HARNESS_ERROR (exit 2) — NOT a verdict
#   The inversion lives ENTIRELY here (in `classify`), documented in this header, and is pinned on CI against
#   captured mocha `--reporter json` fixtures (reports/{pass,fail,empty}.json) so it can never silently flip.
#
# #1471 — TARGET-LINKAGE GATE (anti-fabrication). When the real target is hard to harness, the LLM that
# generates the PoC can silently drive its OWN toy contract of the same name and "reproduce" a bug it planted
# there — a FINDING against fabricated code with zero bounty value. The optional `--require-import <target-src>`
# (+ `--require-contract <Name>`) pair closes that: BEFORE any npm/compile spend, the test must (a) REFERENCE the
# in-scope target — an `import`/`require` path ending in the target basename, OR a `getContractFactory("<Name>")`
# / `getContractAt("<Name>"` call for the real artifact name — AND (b) NOT introduce a same-named `contract
# <Name>` shadow `.sol` under the repo test dir. A miss => HARNESS_ERROR (2), never a verdict. This is
# best-effort STRUCTURAL (as #1471 is for foundry): JS references contracts by artifact-name string, so we key on
# the real `<Name>` and forbid a shadow. When `--require-import` is empty the block is a no-op. The linkage gate
# runs FIRST (before tool presence) so it is CI-testable without node.
#
# npm on CI is not friendly (it needs a registry), so the LIVE path (npm install + npx hardhat compile/test) runs
# only when the toolchain is present; the `--classify <reporter-json>` mode below exposes the verdict-PARSING
# path for a captured JSON with NO node at all, which is what the demo + colony-lint exercise.
#
# Usage:
#   hardhat-poc.sh --repo <hardhat-project-root> --target <exploit.poc.test.js>
#                  [--require-import <target-src>] [--require-contract <Name>] [--match <ignored>]
#   hardhat-poc.sh --classify <mocha-reporter-json>          # parse-only: emit the verdict for a captured JSON
#
# Verdict / exit contract (IDENTICAL to forge-invariant.sh's codes):
#   CLEAN          exit 0  — the PoC ran and FAILED (the exploit assertion did not hold): no finding.
#   FINDING        exit 1  — the PoC ran and PASSED: the exploit reproduced -> a CANDIDATE (a runnable witness).
#   HARNESS_ERROR  exit 2  — bad args, repo is not a hardhat project, node/npx missing, npm install / compile
#                            error, no test ran, no parseable reporter JSON, or (#1471) the test failed the
#                            target-linkage gate.
set -uo pipefail

REPO=""
TARGET=""
REQ_IMPORT=""
REQ_CONTRACT=""
CLASSIFY=""
MATCH="test"   # accepted for uniform invocation with forge-poc.sh; the hardhat gate scopes by --target, not a fn prefix.

usage() { sed -n '2,45p' "$0"; }

banner() { echo "================ HARDHAT-POC: $1 ================" >&2; }

# classify_json <reporter-json-file> : print PASSES=/FAILURES=/TESTS= parsed from a mocha `--reporter json`
# document, then map to the INVERTED-polarity verdict + exit code. A missing/unparseable stats block or zero
# tests is HARNESS_ERROR — never a false verdict. The JSON is read as a FILE arg (never stdin) so the heredoc
# body cannot be confused for input.
classify_json() {
  _cj="$1"
  if [ ! -f "$_cj" ]; then
    banner "HARNESS_ERROR (no reporter JSON to classify: $_cj)"; return 2
  fi
  _tmp_py="$(mktemp "${TMPDIR:-/tmp}/hardhat-poc-parse.XXXXXX.py")" || { banner "HARNESS_ERROR (cannot create temp)"; return 2; }
  cat > "$_tmp_py" <<'PY'
import sys, json
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    print("PARSE_ERROR"); sys.exit(0)
stats = doc.get("stats") if isinstance(doc, dict) else None
if not isinstance(stats, dict):
    print("PARSE_ERROR"); sys.exit(0)
def n(k):
    v = stats.get(k, 0)
    return v if isinstance(v, int) else 0
passes = n("passes")
failures = n("failures")
# `tests` counts the total run; fall back to passes+failures when the reporter omits it.
tests = n("tests") or (passes + failures)
print("PASSES=%d" % passes)
print("FAILURES=%d" % failures)
print("TESTS=%d" % tests)
PY
  _parse="$(python3 "$_tmp_py" "$_cj" 2>/dev/null || true)"
  rm -f "$_tmp_py"
  if printf '%s' "$_parse" | grep -q 'PARSE_ERROR'; then
    banner "HARNESS_ERROR (no parseable mocha reporter JSON — the test suite did not produce structured output)"; return 2
  fi
  _passes="$(printf '%s\n' "$_parse" | sed -n 's/^PASSES=//p' | head -1)"
  _failures="$(printf '%s\n' "$_parse" | sed -n 's/^FAILURES=//p' | head -1)"
  _tests="$(printf '%s\n' "$_parse" | sed -n 's/^TESTS=//p' | head -1)"
  case "$_passes" in ''|*[!0-9]*) _passes=0 ;; esac
  case "$_failures" in ''|*[!0-9]*) _failures=0 ;; esac
  case "$_tests" in ''|*[!0-9]*) _tests=0 ;; esac
  # No test actually ran -> nothing was checked -> not a verdict.
  if [ "$_tests" -eq 0 ]; then
    banner "HARNESS_ERROR (no PoC test ran — nothing was checked)"; return 2
  fi
  # INVERTED polarity: a passing exploit PoC (>=1 pass, 0 failures) is the FINDING.
  if [ "$_passes" -ge 1 ] && [ "$_failures" -eq 0 ]; then
    banner "FINDING (the concrete exploit PoC PASSED — the attack reproduced; a runnable witness a human triages)"; return 1
  fi
  # The PoC ran but FAILED (the exploit assertion did not hold) -> refuted -> no finding.
  banner "CLEAN (the PoC ran and FAILED — the exploit assertion did not hold in this harness; no finding)"; return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --require-import)   REQ_IMPORT="${2:-}"; shift 2 ;;
    --require-contract) REQ_CONTRACT="${2:-}"; shift 2 ;;
    --classify) CLASSIFY="${2:-}"; shift 2 ;;
    # Accepted + IGNORED (uniform invocation with forge-poc.sh, which scopes by a test-fn prefix; hardhat scopes
    # by the --target file, so the prefix is meaningless here).
    --match) MATCH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "hardhat-poc: unknown arg $1" >&2; exit 2 ;;
  esac
done

# --- parse-only mode: classify a captured reporter JSON with NO toolchain (the CI verdict-parse path) ---------
if [ -n "$CLASSIFY" ]; then
  classify_json "$CLASSIFY"; exit $?
fi

# --- usage / harness validation -----------------------------------------------------------------
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "hardhat-poc: --repo <hardhat project root> required" >&2; exit 2; }
# Resolve --repo to ABSOLUTE up front (mirrors run-poc.sh's `REPO="$(cd "$REPO" && pwd)"`). Several sections
# below `cd "$REPO"` into a subshell and then re-reference "$REPO/..." inside it — a RELATIVE --repo would
# double the path there (a false HARNESS_ERROR when hand-invoked outside the run-poc.sh pipeline, #1531).
REPO="$(cd "$REPO" && pwd)"
# A hardhat project is identified by a hardhat.config.{js,ts,cjs,mjs}.
CONFIG_FILE=""
for _c in hardhat.config.js hardhat.config.cjs hardhat.config.ts hardhat.config.mjs; do
  [ -f "$REPO/$_c" ] && { CONFIG_FILE="$_c"; break; }
done
[ -n "$CONFIG_FILE" ] || { echo "hardhat-poc: $REPO is not a hardhat project (no hardhat.config.{js,ts,cjs,mjs})" >&2; exit 2; }
[ -n "$TARGET" ] || { echo "hardhat-poc: --target <exploit.poc.test.js> required" >&2; exit 2; }
if [ -f "$TARGET" ]; then
  TARGET_PATH="$TARGET"
elif [ -f "$REPO/$TARGET" ]; then
  TARGET_PATH="$REPO/$TARGET"
else
  echo "hardhat-poc: target test not found: $TARGET" >&2; exit 2
fi
# Same absolute-path resolution as $REPO above — TARGET_PATH is also re-referenced inside `cd "$REPO"` subshells.
TARGET_PATH="$(cd "$(dirname "$TARGET_PATH")" && pwd)/$(basename "$TARGET_PATH")"

# --- #1471 TARGET-LINKAGE GATE (runs BEFORE any npm/compile spend, so it is CI-testable without node) --------
# (1) the PoC must REFERENCE the in-scope target: an import/require path ending in the target basename OR a
#     getContractFactory/getContractAt call for the real artifact name (<Name>); AND
# (2) it must NOT introduce a same-named `contract <Name>` shadow `.sol` under the repo test dir.
# A miss on either => HARNESS_ERROR (2). Empty --require-import => the block is a no-op (byte-identical to today).
if [ -n "$REQ_IMPORT" ]; then
  # Escape EVERY non-alphanumeric char so the basename / name matches LITERALLY (the `.` in `<name>.sol` most of
  # all) and no metachar in the untrusted value can alter the pattern.
  _tgt_base="$(basename "$REQ_IMPORT")"
  _tgt_base_re="$(printf '%s' "$_tgt_base" | sed 's/[^a-zA-Z0-9]/\\&/g')"
  _ref_ok=0
  # (a) an import/require path ending in the target basename (TS/typechain style).
  grep -Eq "(import|require)[^;]*[\"'/]${_tgt_base_re}[\"']" "$TARGET_PATH" && _ref_ok=1
  # (b) a getContractFactory("<Name>") / getContractAt("<Name>", ...) call for the real artifact name.
  if [ "$_ref_ok" -eq 0 ] && [ -n "$REQ_CONTRACT" ]; then
    _tgt_ctr_re="$(printf '%s' "$REQ_CONTRACT" | sed 's/[^a-zA-Z0-9]/\\&/g')"
    grep -Eq "getContract(Factory|At)\([[:space:]]*[\"']${_tgt_ctr_re}[\"']" "$TARGET_PATH" && _ref_ok=1
  fi
  if [ "$_ref_ok" -eq 0 ]; then
    banner "HARNESS_ERROR (#1471 target-linkage — the PoC does not reference the in-scope target (${_tgt_base}${REQ_CONTRACT:+ / artifact ${REQ_CONTRACT}}); a fabricated / substituted target is NOT a verdict)"
    exit 2
  fi
  # (2) forbid a same-named `contract <Name>` shadow `.sol` under the repo test dir (the JS/TS test drives
  # artifacts by name, so a toy `.sol` of the same name planted under test/ would be silently picked up).
  if [ -n "$REQ_CONTRACT" ] && [ -d "$REPO/test" ]; then
    _tgt_ctr_re="$(printf '%s' "$REQ_CONTRACT" | sed 's/[^a-zA-Z0-9]/\\&/g')"
    while IFS= read -r _sf; do
      [ -n "$_sf" ] || continue
      if grep -Eq "^[[:space:]]*contract[[:space:]]+${_tgt_ctr_re}([^A-Za-z0-9_]|$)" "$_sf"; then
        banner "HARNESS_ERROR (#1471 target-linkage — a same-named 'contract ${REQ_CONTRACT}' shadow .sol under the test dir ($(basename "$_sf")); a self-authored toy is NOT a verdict)"
        exit 2
      fi
    done < <(find "$REPO/test" -type f -name '*.sol' 2>/dev/null)
  fi
fi

echo "== hardhat-poc: concrete-exploit PoC $(basename "$TARGET_PATH") ==" >&2

# --- tool presence ------------------------------------------------------------------------------
# We do NOT hardcode any install location — the caller exports the toolchain onto PATH.
command -v node >/dev/null 2>&1 || { banner "HARNESS_ERROR (node not installed — install Node.js to run the hardhat PoC)"; exit 2; }
command -v npx  >/dev/null 2>&1 || { banner "HARNESS_ERROR (npx not installed — install Node.js/npm to run the hardhat PoC)"; exit 2; }

# --- install deps -------------------------------------------------------------------------------
# `npm ci` is reproducible but requires a lockfile; otherwise fall back to `npm install --legacy-peer-deps`
# (hardhat's peer-dep graph frequently conflicts under strict npm >= 7 resolution — the documented recipe).
INSTALL_LOG="$(mktemp "${TMPDIR:-/tmp}/hardhat-poc-install.XXXXXX")" || { banner "HARNESS_ERROR (cannot create temp)"; exit 2; }
trap 'rm -f "$INSTALL_LOG"' EXIT
if [ -d "$REPO/node_modules" ]; then
  : # already installed (e.g. a warm rundir) — skip the network spend.
elif [ -f "$REPO/package-lock.json" ]; then
  ( cd "$REPO" && npm ci ) >"$INSTALL_LOG" 2>&1 || ( cd "$REPO" && npm install --legacy-peer-deps ) >"$INSTALL_LOG" 2>&1 || {
    banner "HARNESS_ERROR (npm ci / npm install failed — dependency install error)"; sed 's/^/  | /' "$INSTALL_LOG" | tail -8 >&2; exit 2; }
else
  ( cd "$REPO" && npm install --legacy-peer-deps ) >"$INSTALL_LOG" 2>&1 || {
    banner "HARNESS_ERROR (npm install --legacy-peer-deps failed — dependency install error)"; sed 's/^/  | /' "$INSTALL_LOG" | tail -8 >&2; exit 2; }
fi

# --- compile ------------------------------------------------------------------------------------
COMPILE_LOG="$(mktemp "${TMPDIR:-/tmp}/hardhat-poc-compile.XXXXXX")" || { banner "HARNESS_ERROR (cannot create temp)"; exit 2; }
( cd "$REPO" && npx hardhat compile ) >"$COMPILE_LOG" 2>&1 || {
  banner "HARNESS_ERROR (npx hardhat compile failed — the project / PoC did not compile)"; sed 's/^/  | /' "$COMPILE_LOG" | tail -10 >&2; rm -f "$COMPILE_LOG"; exit 2; }
rm -f "$COMPILE_LOG"

# --- run the PoC + capture the mocha reporter JSON ---------------------------------------------
# `hardhat test` has NO `--reporter` flag — the mocha reporter is config-driven (`mocha.reporter`). So we run
# through a generated WRAPPER config (`--config`) that requires the project's own config and merges
# `mocha.reporter = "json"`, keeping the project's plugins/solc/network intact. `--no-compile` (we already
# compiled above) keeps hardhat's compile chatter off stdout so ONLY the mocha JSON lands there. The wrapper is
# CommonJS (`.cjs`) so it loads regardless of the project's package `type`; an ESM/TS base config that cannot be
# require()d yields no parseable JSON -> HARNESS_ERROR (honest, never a false verdict). A non-zero exit (a
# failing test) is EXPECTED for a CLEAN verdict, so we never trust the exit code — only the parsed stats decide.
WRAP="$REPO/.hardhat-poc.reporter.cjs"
cat > "$WRAP" <<'JS'
// Auto-generated by hardhat-poc.sh (#1507) — wraps the project's own config to force mocha's json reporter.
const base = require(process.env.HHPOC_BASE_CONFIG);
const cfg = (base && base.default) ? base.default : base;
const merged = Object.assign({}, cfg);
merged.mocha = Object.assign({}, cfg.mocha, { reporter: "json" });
module.exports = merged;
JS
cleanup_run() { rm -f "$WRAP" "${OUT_JSON:-}"; rm -f "$INSTALL_LOG"; }
trap 'cleanup_run' EXIT
OUT_JSON="$(mktemp "${TMPDIR:-/tmp}/hardhat-poc-out.XXXXXX.json")" || { banner "HARNESS_ERROR (cannot create temp)"; exit 2; }
( cd "$REPO" && HHPOC_BASE_CONFIG="$REPO/$CONFIG_FILE" npx hardhat --config "$WRAP" test --no-compile "$TARGET_PATH" ) >"$OUT_JSON" 2>/dev/null || true
# Re-run with the human-readable reporter so the result + any revert traces are visible in logs (stderr).
( cd "$REPO" && npx hardhat test --no-compile "$TARGET_PATH" 1>&2 2>&1 ) || true
if [ ! -s "$OUT_JSON" ]; then
  banner "HARNESS_ERROR (npx hardhat test produced no reporter output — the PoC did not run, or the project config could not be wrapped)"; exit 2
fi
classify_json "$OUT_JSON"; rc=$?
exit "$rc"
