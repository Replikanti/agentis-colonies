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
# #1471 — TARGET-LINKAGE GATE (fresh-deploy only). When the real target is hard to harness, the LLM that
# generates the `*.t.sol` can silently substitute its OWN toy contract of the SAME name and "find" a bug it
# planted there — a FINDING against fabricated code with zero bounty value. The optional
# `--require-import <target-src>` (+ `--require-contract <Name>`) pair closes that: BEFORE forge runs, the
# test file must (a) carry an `import` line whose path ends with the target's basename AND (b) — when a
# contract name is given — NOT declare its OWN `contract <Name>` shadow. A miss => HARNESS_ERROR (2), never a
# verdict. Applied ONLY in pure fresh-deploy mode: the caller OMITS both flags in fork/composability mode
# (there the target is referenced by on-chain address, not a source import). When `--require-import` is empty
# the behaviour is BYTE-IDENTICAL to today.
#
# Usage:
#   forge-invariant.sh --repo <foundry-project-root> --target <Invariant.t.sol>
#                      [--match <invariant_ prefix>] [--runs N] [--depth D] [--seed S]
#                      [--fork-url <http(s)-rpc>] [--fork-block <n>]
#                      [--require-import <target-src>] [--require-contract <Name>]
#
# Verdict / exit contract (mirrors halmos-verify.sh's shape):
#   CLEAN          exit 0  — >=1 invariant ran and ALL held across every fuzzed sequence: no finding.
#   FINDING        exit 1  — >=1 invariant FAILED; the shrunk exploit sequence is printed to stderr and
#                            captured in the JSON. A reproducible multi-step witness -> a CANDIDATE.
#   HARNESS_ERROR  exit 2  — bad args, repo is not a foundry project, forge missing, compile/setup error,
#                            no invariant function matched (nothing was actually checked), a fork RPC that was
#                            unreachable / could not instantiate the forked environment, or (#1471) the test
#                            failed the target-linkage gate (did not import the in-scope target, or shadowed
#                            it with a same-named toy contract).
#   TRANSIENT_ERROR exit 3 — (#2033) fresh-deploy only: forge produced NO parseable result, but the harness
#                            STATICALLY declares an invariant_* function AND the failure carries no compile-error
#                            signature (or forge was signal-killed — 137 SIGKILL/OOM, 143 SIGTERM). That is a run
#                            STARVED / killed / timed out under concurrent batch load, not a broken harness: the
#                            cell is VALID and RE-RUNNABLE and must NOT be finalized as HARNESS_ERROR (the false
#                            negative #2033 fixes). Returned only after FORGE_INVARIANT_RETRIES (default 1) extra
#                            attempts still fail. A genuine compile error (deterministic solc/forge signature)
#                            short-circuits to HARNESS_ERROR (2) with today's single-shot cost; FORK MODE is
#                            excluded entirely (the no-result path there stays byte-identical to today).
set -uo pipefail

REPO=""
TARGET=""
MATCH="invariant"
RUNS=""
DEPTH=""
SEED=""
FORK_URL=""
FORK_BLOCK=""
REQ_IMPORT=""
REQ_CONTRACT=""

usage() { sed -n '2,52p' "$0"; }

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
    # #1471: TARGET-LINKAGE GATE (fresh-deploy only). --require-import <target-src> arms the gate; the test must
    # import a path ending in this file's basename. --require-contract <Name> additionally forbids a same-named
    # shadow contract. Both empty (the default, and every fork/composability caller) => the gate is INERT.
    --require-import)   REQ_IMPORT="${2:-}"; shift 2 ;;
    --require-contract) REQ_CONTRACT="${2:-}"; shift 2 ;;
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

# --- #1926 PRE-COMPILE ADJACENT-DUPLICATE-LINE GUARD --------------------------------------------
# The harness generator occasionally streams a duplication artifact — an unbalanced statement-opener
# (`bond = BondToken(address(new InvProxy(`) emitted on two adjacent byte-identical lines, leaving the first
# unclosed → a guaranteed syntax error the repair rounds thrash on. dedup-harness-lines.sh removes only such a
# provably-broken duplicate (unbalanced-paren, substantive, adjacent, byte-identical — imports/balanced
# statements are never touched), so BOTH the #1471 grep below and forge operate on the normalized file. Called
# best-effort: it is a no-op (target left bit-for-bit identical) on every well-formed harness, and a missing
# helper degrades to today's behaviour, so it can never turn a valid harness into a spurious HARNESS_ERROR.
_dedup_sh="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/dedup-harness-lines.sh"
[ -f "$_dedup_sh" ] && sh "$_dedup_sh" "$TARGET_PATH" || true

# --- #1471 TARGET-LINKAGE GATE (fresh-deploy only) ----------------------------------------------
# When --require-import is set the generated/staged test MUST structurally reference the in-scope target
# BEFORE we spend a fuzzing budget on it — otherwise a test that imports NOTHING and defines its OWN toy
# `contract <Name>` of the same name lets the fuzzer "find" a planted bug in FABRICATED code and report a
# false FINDING (the live Liquity BOLD StabilityPool substitution, #1471). Two static checks on the test:
#   (1) it must carry an `import` line whose quoted path ENDS WITH the target basename (e.g. StabilityPool.sol,
#       or the staged `target-code.sol` name the runner imports); AND
#   (2) if --require-contract <Name> is set, it must NOT DECLARE its own `contract <Name>` shadow — a trailing
#       non-identifier char emulates the word boundary so `contract StabilityPoolHarness` does NOT match.
# A miss on either => HARNESS_ERROR (2), never a verdict. When --require-import is EMPTY (every fork/
# composability caller and every pre-#1471 caller) this block is a no-op and the run is byte-identical to today.
# `banner()` is defined further below (after arg parse), so emit the HARNESS_ERROR banner inline here.
if [ -n "$REQ_IMPORT" ]; then
  # Escape EVERY non-alphanumeric char so the basename / contract name match LITERALLY in the ERE below
  # (the `.` in `<name>.sol` most of all) and no metachar in the untrusted value can alter the pattern.
  _tgt_base="$(basename "$REQ_IMPORT")"
  _tgt_base_re="$(printf '%s' "$_tgt_base" | sed 's/[^a-zA-Z0-9]/\\&/g')"
  if ! grep -Eq "^[[:space:]]*import[^;]*[\"'/]${_tgt_base_re}[\"']" "$TARGET_PATH"; then
    echo "================ FORGE-INVARIANT: HARNESS_ERROR (#1471 target-linkage — the test does not import the in-scope target (${_tgt_base}); a fabricated / substituted target is NOT a verdict) ================" >&2
    exit 2
  fi
  if [ -n "$REQ_CONTRACT" ]; then
    _tgt_ctr_re="$(printf '%s' "$REQ_CONTRACT" | sed 's/[^a-zA-Z0-9]/\\&/g')"
    if grep -Eq "^[[:space:]]*contract[[:space:]]+${_tgt_ctr_re}([^A-Za-z0-9_]|$)" "$TARGET_PATH"; then
      echo "================ FORGE-INVARIANT: HARNESS_ERROR (#1471 target-linkage — the test declares its OWN 'contract ${REQ_CONTRACT}' shadow instead of importing the in-scope target; a self-authored toy is NOT a verdict) ================" >&2
      exit 2
    fi
  fi
fi

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

banner() { echo "================ FORGE-INVARIANT: $1 ================" >&2; }

# --- #2033 TRANSIENT vs. GENUINE run-failure classification -------------------------------------
# A forge run STARVED under concurrent batch load (OOM-killed, SIGTERM'd, or timed out) leaves the SAME "no
# parseable result" footprint as a genuine compile error, so today both collapse to HARNESS_ERROR (2) — the
# false negative #2033 fixes (3 valid enzyme-onyx harnesses were recorded HARNESS_ERROR yet pass standalone).
# The two helpers below tell them apart deterministically. A GENUINE compile error still fails fast and
# byte-identically (its stderr carries a solc/forge signature, so _transient_candidate is false and it is
# never retried); FORK MODE is excluded entirely (the no-result path there stays byte-identical to today).
#
# _compile_error_sig <errfile>: TRUE (0) when forge/solc stderr carries a deterministic compile-error marker.
_compile_error_sig() {
  grep -Eq 'Compiler run failed|Error \([0-9]+\):|ParserError|DeclarationError|TypeError|Identifier not found|Source .* not found' "$1" 2>/dev/null
}
# _declares_invariant: TRUE (0) when the harness STATICALLY declares a `function <MATCH>...(` — i.e. there IS
# an invariant to run, so a no-result outcome is a RUN failure, not a "nothing to check" harness defect.
_declares_invariant() {
  grep -Eq "function[[:space:]]+${MATCH}[A-Za-z0-9_]*[[:space:]]*\(" "$TARGET_PATH" 2>/dev/null
}
# _transient_candidate: fresh-deploy only, harness declares an invariant, AND EITHER forge was signal-killed
# (137 SIGKILL/OOM, 143 SIGTERM — any 128+signum, from the captured FORGE_RC) OR its stderr lacks every
# compile-error signature. The SOLE gate for both the retry decision and the exit-3 TRANSIENT_ERROR verdict.
_transient_candidate() {
  [ -z "$FORK_URL" ] || return 1
  _declares_invariant || return 1
  [ "${FORGE_RC:-0}" -ge 128 ] && return 0
  _compile_error_sig "$TMPD/err.txt" && return 1
  return 0
}

# Retry knobs (#2033). Both default to today's single-shot cost on the compile-error path (which short-
# circuits via _compile_error_sig and is never retried): FORGE_INVARIANT_RETRIES extra attempts on a suspected
# transient, FORGE_INVARIANT_RETRY_BACKOFF_S seconds of backoff between them (giving contention a window to
# clear). Non-numeric overrides fall back to the defaults.
FORGE_INVARIANT_RETRIES="${FORGE_INVARIANT_RETRIES:-1}"
FORGE_INVARIANT_RETRY_BACKOFF_S="${FORGE_INVARIANT_RETRY_BACKOFF_S:-5}"
case "$FORGE_INVARIANT_RETRIES" in ''|*[!0-9]*) FORGE_INVARIANT_RETRIES=1 ;; esac
case "$FORGE_INVARIANT_RETRY_BACKOFF_S" in ''|*[!0-9]*) FORGE_INVARIANT_RETRY_BACKOFF_S=5 ;; esac

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
# --- run forge (--json) with a bounded retry on a suspected transient (#2033) -------------------
# forge prints the suite object to stdout on --json; build/setup errors go to stderr. forge's own exit status
# is 1 on a failing test, but we parse the structured output for the verdict rather than trust the code (a
# compile error and a real finding both exit non-zero — only the parse distinguishes them). We DO capture the
# code (FORGE_RC, no `|| true`) so a signal kill (137/143) is a positive transient signal for
# _transient_candidate. When the result is unparseable AND it looks transient (fresh-deploy, harness declares
# an invariant, no compile-error signature or signal-killed) we re-run up to FORGE_INVARIANT_RETRIES times with
# a short backoff — a genuine compile error short-circuits and is never retried (byte-identical cost to today).
_attempt=0
while : ; do
  ( cd "$REPO" && forge "${ARGS[@]}" ) >"$TMPD/out.json" 2>"$TMPD/err.txt"
  FORGE_RC=$?
  PARSE="$(python3 "$TMPD/parse.py" "$MATCH" "$TMPD/out.json" 2>/dev/null || true)"
  ERROUT="$(cat "$TMPD/err.txt" 2>/dev/null || true)"
  if { printf '%s' "$PARSE" | grep -q 'PARSE_ERROR' || [ ! -s "$TMPD/out.json" ]; } \
     && _transient_candidate && [ "$_attempt" -lt "$FORGE_INVARIANT_RETRIES" ]; then
    _attempt=$((_attempt + 1))
    echo "== forge-invariant: no parseable result, no compile-error signature, harness declares ${MATCH}* (forge rc=${FORGE_RC}); suspected transient starvation — retry ${_attempt}/${FORGE_INVARIANT_RETRIES} after ${FORGE_INVARIANT_RETRY_BACKOFF_S}s ==" >&2
    sleep "$FORGE_INVARIANT_RETRY_BACKOFF_S"
    continue
  fi
  break
done

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
  # #2033: the retry loop above has already exhausted FORGE_INVARIANT_RETRIES (it breaks only when out of
  # attempts or the failure is not a transient candidate). A fresh-deploy no-result that STILL looks transient
  # (harness declares an invariant AND either forge was signal-killed or its stderr carries no compile-error
  # signature) is a re-runnable TRANSIENT_ERROR (3), NOT a broken harness — the run was starved/killed under
  # concurrent batch load. Every OTHER no-result outcome (fork mode, genuine compile error, no invariant
  # declared) stays HARNESS_ERROR (2), byte-identical to today.
  if _transient_candidate; then
    banner "TRANSIENT_ERROR (forge produced no parseable result after ${_attempt} retry attempt(s) — no compile-error signature and the harness declares ${MATCH}* (forge rc=${FORGE_RC}); the run was starved/killed/timed out under concurrent batch load, this cell is VALID and RE-RUNNABLE, NOT a broken harness)"
    printf '%s\n' "$ERROUT" | grep -iE 'killed|out of memory|oom|tim(e|ed) out|signal|error' | head -5 >&2 || true
    exit 3
  fi
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
