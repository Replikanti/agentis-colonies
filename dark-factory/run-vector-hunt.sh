#!/usr/bin/env bash
# run-vector-hunt.sh — invariant-driven VECTOR-ENUMERATION deep-hunt engine (#2156, milestone D2 of epic #2130).
#
# The THIRD per-target PoC engine alongside run-invariant-hunt.sh (the fuzzer) and run-poc.sh (the concrete
# exploit). Where run-poc.sh reproduces ONE human-supplied hypothesis, this AUTOMATES the human vector-
# enumeration + property-construction we did by hand for the yieldoor H-3 / yearn H-1 findings: per value-custody
# economic INVARIANT it enumerates a BOUNDED set of concrete attack VECTORS (crossing a GENERIC economic-
# invariant catalog with D1's #2145 code-derived `CALLEE-VECTOR|` candidates), drives EACH vector through the
# existing concrete-PoC gate (run-poc.sh -> evm-harness/forge-poc.sh), and merges ONLY reproduced (PoC-PASS)
# vectors into verified_findings.json tagged `source=vector-hunt`.
#
# GENERIC / CONTAMINATION DISCIPLINE (#2130): the invariant catalog is embedded in this script and is selected
# by --class / value-custody — it is NEVER read from the target brief. A vector is templated only from an
# invariant the catalog owns plus a `CALLEE-VECTOR|` line the hunter emitted from the code (D1). No
# target-specific token is ever introduced here. A zone D1 did not fire on still gets a bounded generic set.
#
# VERIFICATION GATE = the CONCRETE-PoC path (STOP-1 decision, #2156): a `CALLEE-VECTOR|` is already a concrete
# attack hypothesis (fn x callee-expr x hazard), so it feeds run-poc.sh --hypothesis directly. PoC-PASS
# (`POC|<t>|FINDING`) = reproduced = merged; CLEAN / HARNESS_ERROR merge nothing. This is NOT the invariant
# fuzzer (run-invariant-hunt.sh / invariant-prover.ag), which judges a fuzzed property over sequences.
#
# FORGE-SLOT OWNERSHIP: run-poc.sh / forge-poc.sh do NOT self-acquire a forge slot (unlike run-invariant-hunt.sh),
# so THIS loop owns lib/forge-slot.sh around each PoC run — `FORGE_MAX_SLOTS` is respected end-to-end. The vector
# count is bounded by --max-vectors (default 6); content-hash dedup + a per-vector verdict marker make the loop
# resumable (--resume) so a vector is never re-verified.
#
# OFFLINE / TEST SEAM: --poc-runner <script> replaces run-poc.sh with a deterministic stub (demo-vector-hunt.sh),
# so the whole enumerate -> per-vector verify -> only-PASS-merged -> dedup loop is provable with NO agentis, NO
# forge, NO network. This engine NEVER contacts a bounty platform.
#
# Usage:
#   run-vector-hunt.sh --repo <project> --target <C.sol[:Name]> [--callee-vectors <file>] [options]
#
# Options:
#   --repo <dir>            Project root (foundry.toml => forge PoC; hardhat.config.* => hardhat PoC). REQUIRED.
#   --target <C.sol[:Name]> Target contract label (the lens), e.g. "Vault.sol:Vault". REQUIRED.
#   --class <id>            The bug-class / value-custody id the target is filed under (selects the applicable
#                           invariant catalog rows; "" => the full value-custody catalog).
#   --callee-vectors <file> The harvested `CALLEE-VECTOR|<fn>|<callee-expr>|<hazard>|<CANDIDATE|dismissed:...>`
#                           lines for this zone (D1 #2145). Empty / omitted => invariant-only fallback.
#   --max-vectors N         Explicit cap on the enumerated vector set (default 6).
#   --backend <mock|flat-cyborg|claude>  LLM backend threaded to the PoC runner (default flat-cyborg).
#   --model <id>            Optional model id threaded to the PoC runner.
#   --out <dir>            Output dir for the run (default ./vector-hunt-out). Per-vector dirs + verdict markers
#                          live under <out>/vector-hunt/.
#   --verified-json <path>  The findings artifact PoC-PASS vectors are merged into (default <out>/verified_findings.json).
#   --poc-runner <script>   The per-vector verifier (default: run-poc.sh). The offline/test seam.
#   --agentis <bin>         agentis binary threaded to the PoC runner (default: `agentis` on PATH).
#   --resume                Skip any vector whose <hash>.verdict marker already exists (idempotent re-run).
#   --retries N             Bounded retries for a transient PoC verdict (HARNESS_ERROR/TRANSIENT_ERROR); default 1.
#   --cli-timeout-ms N      Starting LLM CLI timeout ceiling (ms) threaded to the PoC runner (default: env
#                           DF_POC_CLI_TIMEOUT_MS or 600000, the PoC-write floor).
#   --cli-timeout-max-ms N  Hard cap the TIMEOUT escalation raises the ceiling toward (default: env
#                           DF_POC_CLI_TIMEOUT_MAX_MS or 1200000).
#   --timeout-retries N     Bounded TIMEOUT-escalation count on a terminal LlmTimeout (agentis-core#996: exit 75 /
#                           `[llm.timeout]`); default 1 (env DF_POC_TIMEOUT_RETRIES). Each escalation raises the
#                           ceiling toward the cap and re-runs — SEPARATE from --retries; a size-timeout is NEVER
#                           blindly re-run, and a RUNAWAY that blows through a raised ceiling stops after this many
#                           raises with a terminal TIMEOUT (never an unbounded loop).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# #2038: host-wide forge-subprocess concurrency cap (K=${FORGE_MAX_SLOTS:-2}). run-poc.sh/forge-poc.sh do NOT
# self-acquire a slot, so this loop MUST own it around each PoC run.
# shellcheck source=lib/forge-slot.sh
# shellcheck disable=SC1091
. "$HERE/lib/forge-slot.sh"
# Backstop: free a held slot on ANY exit path (happy path, error, signal). Safe no-op when none is held.
trap release_forge_slot EXIT

AGENTIS="agentis"
REPO="" ; TARGET="" ; CLASS="" ; CALLEE_VECTORS="" ; MAX_VECTORS=6
BACKEND="flat-cyborg" ; MODEL="" ; OUT="$PWD/vector-hunt-out" ; VERIFIED_JSON="" ; POC_RUNNER="$HERE/run-poc.sh"
RESUME=0 ; RETRIES=1
# #2178: the TIMEOUT-escalation knobs. Starting ceiling (the floor), the hard cap the escalation raises toward,
# and the bounded escalation count — all env-overridable per dark-factory cell (flags win over env).
CLI_TIMEOUT_MS="${DF_POC_CLI_TIMEOUT_MS:-600000}"
CLI_TIMEOUT_MAX_MS="${DF_POC_CLI_TIMEOUT_MAX_MS:-1200000}"
TIMEOUT_RETRIES="${DF_POC_TIMEOUT_RETRIES:-1}"

need() { [ "$1" -ge 2 ] || { echo "run-vector-hunt.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$#"; REPO="$2"; shift 2 ;;
    --target) need "$#"; TARGET="$2"; shift 2 ;;
    --class) need "$#"; CLASS="$2"; shift 2 ;;
    --callee-vectors) need "$#"; CALLEE_VECTORS="$2"; shift 2 ;;
    --max-vectors) need "$#"; MAX_VECTORS="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --model) need "$#"; MODEL="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --verified-json) need "$#"; VERIFIED_JSON="$2"; shift 2 ;;
    --poc-runner) need "$#"; POC_RUNNER="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --resume) RESUME=1; shift ;;
    --retries) need "$#"; RETRIES="$2"; shift 2 ;;
    --cli-timeout-ms) need "$#"; CLI_TIMEOUT_MS="$2"; shift 2 ;;
    --cli-timeout-max-ms) need "$#"; CLI_TIMEOUT_MAX_MS="$2"; shift 2 ;;
    --timeout-retries) need "$#"; TIMEOUT_RETRIES="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-vector-hunt.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "run-vector-hunt.sh: --repo <project root> required" >&2; exit 2; }
[ -n "$TARGET" ] || { echo "run-vector-hunt.sh: --target <Contract.sol[:Name]> required" >&2; exit 2; }
case "$MAX_VECTORS" in ''|*[!0-9]*) echo "run-vector-hunt.sh: --max-vectors must be a positive integer" >&2; exit 2 ;; esac
[ "$MAX_VECTORS" -ge 1 ] || { echo "run-vector-hunt.sh: --max-vectors must be >= 1" >&2; exit 2; }
case "$RETRIES" in ''|*[!0-9]*) echo "run-vector-hunt.sh: --retries must be a whole number" >&2; exit 2 ;; esac
case "$CLI_TIMEOUT_MS" in ''|*[!0-9]*) echo "run-vector-hunt.sh: --cli-timeout-ms / DF_POC_CLI_TIMEOUT_MS must be a positive integer of milliseconds" >&2; exit 2 ;; esac
[ "$CLI_TIMEOUT_MS" -ge 1 ] || { echo "run-vector-hunt.sh: --cli-timeout-ms / DF_POC_CLI_TIMEOUT_MS must be >= 1" >&2; exit 2; }
case "$CLI_TIMEOUT_MAX_MS" in ''|*[!0-9]*) echo "run-vector-hunt.sh: --cli-timeout-max-ms / DF_POC_CLI_TIMEOUT_MAX_MS must be a positive integer of milliseconds" >&2; exit 2 ;; esac
[ "$CLI_TIMEOUT_MAX_MS" -ge "$CLI_TIMEOUT_MS" ] || { echo "run-vector-hunt.sh: --cli-timeout-max-ms ($CLI_TIMEOUT_MAX_MS) must be >= --cli-timeout-ms ($CLI_TIMEOUT_MS)" >&2; exit 2; }
case "$TIMEOUT_RETRIES" in ''|*[!0-9]*) echo "run-vector-hunt.sh: --timeout-retries / DF_POC_TIMEOUT_RETRIES must be a whole number" >&2; exit 2 ;; esac
[ -x "$POC_RUNNER" ] || { echo "run-vector-hunt.sh: --poc-runner not found/executable: $POC_RUNNER" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "run-vector-hunt.sh: python3 is required (enumeration)" >&2; exit 3; }
if [ -n "$CALLEE_VECTORS" ]; then
  [ -f "$CALLEE_VECTORS" ] || { echo "run-vector-hunt.sh: --callee-vectors file not found: $CALLEE_VECTORS" >&2; exit 2; }
fi

REPO="$(cd "$REPO" && pwd)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
VHDIR="$OUT/vector-hunt"; mkdir -p "$VHDIR"
[ -n "$VERIFIED_JSON" ] || VERIFIED_JSON="$OUT/verified_findings.json"

RELFILE="${TARGET%%:*}"   # the file part of the lens (used as verified[].file / location prefix).

# ----------------------------------------------------------------------------------------------------------
# ENUMERATE (deterministic): cross the GENERIC economic-invariant catalog with the parsed CALLEE-VECTOR lines.
# The catalog + the hazard->invariant map are embedded here (NOT read from the brief). Each vector is content-
# hashed for dedup, the ordered set is capped at --max-vectors, and one `VECTOR|<hash>|<invariant>|<fn>|
# <callee>|<hazard>|<hypothesis>` line is emitted per vector (observable + offline-checkable).
# ----------------------------------------------------------------------------------------------------------
VECFILE="$VHDIR/vectors.tsv"
python3 - "$CALLEE_VECTORS" "$CLASS" "$RELFILE" "$MAX_VECTORS" "$VECFILE" <<'PY'
import sys, os, re, hashlib

callee_file, cls, relfile, max_vectors, vecfile = sys.argv[1:6]
max_vectors = int(max_vectors)

# GENERIC economic-invariant catalog (names no protocol). The value-custody rows apply to any custody zone;
# the hazard rows are selected by a CALLEE-VECTOR line's assessed hazard.
VALUE_CUSTODY = ["solvency", "share-price-monotonicity", "no-unauthorized-mint"]
HAZARD_INVARIANT = {
    "reentrant": "reentrancy-state-consistency",
    "return-value": "return-value-trust",
    "gas": "gas-liveness",
}

def hazard_to_invariant(h):
    return HAZARD_INVARIANT.get(h, "solvency")

def hypothesis(inv, fn, callee, hazard):
    # A GENERIC hypothesis: names ONLY what D1 exposed via the CALLEE-VECTOR (fn, callee-expr, hazard) plus the
    # catalog invariant. run-poc.sh consumes this verbatim as --hypothesis.
    if fn or callee:
        return ("Under the %s economic invariant, the attacker-controlled callee %s reached from %s can violate "
                "it via a %s hazard: treat the callee as unknown code (it may reenter, revert, return arbitrary "
                "data, or consume all forwarded gas) and check the caller's state at the exact moment control "
                "passes to it." % (inv, callee or "the external call", fn or "the entry point", hazard))
    return ("Enumerate a concrete attack sequence that violates the %s economic invariant of the target under "
            "an attacker-controlled external callee." % inv)

def content_hash(inv, fn, callee, hazard):
    return hashlib.sha256(("%s|%s|%s|%s" % (inv, fn, callee, hazard)).encode("utf-8")).hexdigest()

vectors = []   # ordered (hash, inv, fn, callee, hazard, hypothesis)
seen = set()

def add(inv, fn, callee, hazard):
    h = content_hash(inv, fn, callee, hazard)
    if h in seen:
        return
    seen.add(h)
    vectors.append((h, inv, fn, callee, hazard, hypothesis(inv, fn, callee, hazard)))

candidates = 0
if callee_file and os.path.isfile(callee_file):
    with open(callee_file, encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("CALLEE-VECTOR|"):
                continue
            parts = line.split("|")
            # CALLEE-VECTOR|<fn>|<callee-expr>|<hazard>|<CANDIDATE|dismissed: reason>
            if len(parts) < 5:
                continue
            fn = parts[1].strip()
            callee = parts[2].strip()
            hazard = parts[3].strip()
            disp = "|".join(parts[4:]).strip()
            # Only a CANDIDATE seeds a PoC — a `dismissed:` vector never does (contamination + budget discipline).
            if not disp.startswith("CANDIDATE"):
                continue
            candidates += 1
            add(hazard_to_invariant(hazard), fn, callee, hazard)

# Invariant-only fallback: a zone D1 did not fire on (no CANDIDATE) still gets a bounded generic set from the
# value-custody catalog so the loop is never empty on a custody zone.
if candidates == 0:
    for inv in VALUE_CUSTODY:
        add(inv, "", "", "invariant")

vectors = vectors[:max_vectors]

with open(vecfile, "w", encoding="utf-8") as out:
    for (h, inv, fn, callee, hazard, hyp) in vectors:
        out.write("\t".join([h, inv, fn, callee, hazard, hyp]) + "\n")

# Emit the observable VECTOR| lines (the demo golden pins these).
for (h, inv, fn, callee, hazard, hyp) in vectors:
    print("VECTOR|%s|%s|%s|%s|%s|%s" % (h, inv, fn, callee, hazard, hyp))
PY

N_VECTORS="$(grep -c . "$VECFILE" 2>/dev/null || echo 0)"
echo "run-vector-hunt.sh: enumerated $N_VECTORS vector(s) for $TARGET (class '${CLASS:-<none>}', cap $MAX_VECTORS)" >&2

# ----------------------------------------------------------------------------------------------------------
# VERIFY loop: drive each vector through the PoC runner under a forge slot; parse the `POC|<t>|<verdict>` line.
# FINDING => merge (a hit); CLEAN => nothing; HARNESS_ERROR/TRANSIENT_ERROR => bounded retry then recorded
# unverified. Each vector's verdict is stamped to <hash>.verdict so --resume skips an already-verified vector.
# ----------------------------------------------------------------------------------------------------------
run_poc_once() {
  # run_poc_once <hash> <hypothesis> <callee-expr> <hazard> <cli-timeout-ms> -> echoes the parsed verdict
  # (FINDING|CLEAN|TIMEOUT|HARNESS_ERROR|TRANSIENT_ERROR).
  rp_hash="$1"; rp_hyp="$2"; rp_callee="$3"; rp_haz="$4"; rp_timeout="$5"
  rp_dir="$VHDIR/$rp_hash"; mkdir -p "$rp_dir"
  rp_log="$rp_dir/poc.log"
  # #2171: thread the CALLEE-VECTOR callee-expr + hazard so run-poc.sh -> poc-writer.ag can model an out-of-scope
  # SETTABLE callee as an attacker-deployed hostile stub instead of refuting the vector for being unprovable. Both
  # are "" for an invariant-only fallback vector -> the stub path stays inert (byte-identical to pre-#2171).
  # #2178: thread --cli-timeout-ms so the TIMEOUT escalation below can RAISE the runner's llm.cli_timeout_ms.
  # Thread --model only when set, so the runner's own default is preserved (byte-identical to no flag).
  if [ -n "$MODEL" ]; then
    "$POC_RUNNER" --repo "$REPO" --target "$TARGET" --class "$CLASS" --hypothesis "$rp_hyp" \
      --callee-expr "$rp_callee" --callee-hazard "$rp_haz" --cli-timeout-ms "$rp_timeout" \
      --backend "$BACKEND" --model "$MODEL" --out "$rp_dir" --agentis "$AGENTIS" >"$rp_log" 2>&1 || true
  else
    "$POC_RUNNER" --repo "$REPO" --target "$TARGET" --class "$CLASS" --hypothesis "$rp_hyp" \
      --callee-expr "$rp_callee" --callee-hazard "$rp_haz" --cli-timeout-ms "$rp_timeout" \
      --backend "$BACKEND" --out "$rp_dir" --agentis "$AGENTIS" >"$rp_log" 2>&1 || true
  fi
  rp_vline="$(grep 'POC|' "$rp_log" | grep -v 'POC-FILE|' | tail -1 || true)"
  if [ -z "$rp_vline" ]; then
    echo "HARNESS_ERROR"; return 0
  fi
  rp_verd="$(printf '%s' "$rp_vline" | sed 's/.*POC|//' | cut -d'|' -f2)"
  case "$rp_verd" in
    FINDING|CLEAN|TIMEOUT|HARNESS_ERROR|TRANSIENT_ERROR) echo "$rp_verd" ;;
    *) echo "HARNESS_ERROR" ;;
  esac
}

N_VERIFIED=0
# shellcheck disable=SC2034  # VINV is captured only to keep the positional field split correct (it is already
# baked into VHYP); VH/VFN/VHYP plus VCALLEE/VHAZ (#2171, threaded to the PoC runner for the hostile-stub gate)
# are read below.
while IFS="$(printf '\t')" read -r VH VINV VFN VCALLEE VHAZ VHYP; do
  [ -n "$VH" ] || continue
  MARKER="$VHDIR/$VH.verdict"
  if [ "$RESUME" -eq 1 ] && [ -f "$MARKER" ]; then
    echo "run-vector-hunt.sh: --resume: vector $VH already verified ($(cat "$MARKER")) — skipping" >&2
    [ "$(cat "$MARKER" 2>/dev/null)" = "FINDING" ] && N_VERIFIED=$((N_VERIFIED + 1))
    continue
  fi

  acquire_forge_slot
  CUR_TIMEOUT="$CLI_TIMEOUT_MS"
  VERD="$(run_poc_once "$VH" "$VHYP" "$VCALLEE" "$VHAZ" "$CUR_TIMEOUT")"
  # #2178 TIMEOUT escalation — a SEPARATE, bounded counter, entirely distinct from the transient $RETRIES loop
  # below (a TIMEOUT must NEVER be blindly re-run: a size-timeout will time out identically). The ONLY lever is
  # RAISING the llm.cli_timeout_ms ceiling once toward the hard cap and re-running (AC2's "OR raise ceiling").
  # RUNAWAY GUARD: bounded by DF_POC_TIMEOUT_RETRIES AND the monotone ceiling capped at DF_POC_CLI_TIMEOUT_MAX_MS —
  # a genuine RUNAWAY that blows through a raised ceiling with zero output is stopped after these raises with a
  # terminal TIMEOUT, never an unbounded loop. The loop also stops the moment the ceiling reaches the cap (a
  # further raise would be a no-op).
  TIMEOUT_ESC=0
  while [ "$VERD" = "TIMEOUT" ] && [ "$TIMEOUT_ESC" -lt "$TIMEOUT_RETRIES" ] && [ "$CUR_TIMEOUT" -lt "$CLI_TIMEOUT_MAX_MS" ]; do
    TIMEOUT_ESC=$((TIMEOUT_ESC + 1))
    NEXT_TIMEOUT=$((CUR_TIMEOUT * 2))
    [ "$NEXT_TIMEOUT" -gt "$CLI_TIMEOUT_MAX_MS" ] && NEXT_TIMEOUT="$CLI_TIMEOUT_MAX_MS"
    echo "run-vector-hunt.sh: vector $VH TIMEOUT — raising llm.cli_timeout_ms ${CUR_TIMEOUT} -> ${NEXT_TIMEOUT}ms (escalation $TIMEOUT_ESC/$TIMEOUT_RETRIES, cap ${CLI_TIMEOUT_MAX_MS}ms)" >&2
    CUR_TIMEOUT="$NEXT_TIMEOUT"
    VERD="$(run_poc_once "$VH" "$VHYP" "$VCALLEE" "$VHAZ" "$CUR_TIMEOUT")"
  done
  # Bounded retry on a transient/build verdict (mirrors the #2045/#2048 TRANSIENT_ERROR discipline). A TIMEOUT
  # NEVER enters this loop (handled by the escalation above) — a size-timeout must not be blindly re-run.
  ATTEMPT=0
  while { [ "$VERD" = "HARNESS_ERROR" ] || [ "$VERD" = "TRANSIENT_ERROR" ]; } && [ "$ATTEMPT" -lt "$RETRIES" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    echo "run-vector-hunt.sh: vector $VH transient ($VERD) — retry $ATTEMPT/$RETRIES" >&2
    VERD="$(run_poc_once "$VH" "$VHYP" "$VCALLEE" "$VHAZ" "$CUR_TIMEOUT")"
  done
  release_forge_slot

  printf '%s\n' "$VERD" > "$MARKER"

  if [ "$VERD" = "FINDING" ]; then
    # MERGE: append a schema-compatible verified[] entry (key shape lifted from deep-hunt-gate.sh) tagged
    # source=vector-hunt, deduped on location + vector_hash so a vector is never merged twice.
    python3 - "$VERIFIED_JSON" "$RELFILE" "$VFN" "$CLASS" "$VHYP" "$VH" <<'PY'
import sys, os, json
verified_json, relfile, fn, cls, hyp, vhash = sys.argv[1:7]
if not fn:
    fn = os.path.splitext(os.path.basename(relfile))[0]
location = "%s:%s" % (relfile, fn)
try:
    data = json.load(open(verified_json, encoding="utf-8"))
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
verified = data.setdefault("verified", [])
# Dedup on location + vector_hash — a resumed / re-run vector is never merged twice.
for e in verified:
    if e.get("location") == location and e.get("vector_hash") == vhash:
        sys.exit(0)
entry = {
    "location": location,
    "file": relfile,
    "class": cls,
    "severity": "High",
    "exploit": hyp,
    "poc_sketch": hyp,
    "verdict": "FINDING",
    "reason": "concrete-exploit PoC reproduced the enumerated attack vector",
    "source": "vector-hunt",
    "vector_hash": vhash,
}
verified.append(entry)
totals = data.setdefault("totals", {})
totals["verified"] = int(totals.get("verified", 0)) + 1
with open(verified_json, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
    N_VERIFIED=$((N_VERIFIED + 1))
    echo "run-vector-hunt.sh: vector $VH PoC-PASS -> merged into $(basename "$VERIFIED_JSON")" >&2
  else
    echo "run-vector-hunt.sh: vector $VH -> $VERD (nothing merged)" >&2
  fi
done < "$VECFILE"

echo "VECTOR-HUNT|$TARGET|$N_VERIFIED/$N_VECTORS"
echo "run-vector-hunt.sh: $N_VERIFIED/$N_VECTORS vector(s) reproduced as PoC-PASS and merged (source=vector-hunt)" >&2
