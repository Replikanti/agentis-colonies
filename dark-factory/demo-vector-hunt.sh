#!/usr/bin/env bash
# demo-vector-hunt.sh — OFFLINE, DETERMINISTIC proof of the #2156 (milestone D2, epic #2130) invariant-driven
# VECTOR-ENUMERATION deep-hunt loop: run-vector-hunt.sh crosses a GENERIC economic-invariant catalog with D1's
# code-derived `CALLEE-VECTOR|` candidates, drives EACH enumerated vector through the concrete-PoC gate, and
# merges ONLY reproduced (PoC-PASS) vectors into verified_findings.json (source=vector-hunt). The PoC gate is
# driven by a FAST offline stub wired through the EXISTING --poc-runner seam — NO live agentis, NO forge, NO
# network.
#
# Assertions:
#   Part 1 SOURCE-GUARD (no forge/agentis):
#     1) run-vector-hunt.sh exists + is executable.
#     2) the GENERIC economic-invariant catalog + the hazard->invariant map + the --max-vectors cap +
#        source=vector-hunt + the --poc-runner / --resume seams are all present in the engine.
#     3) forge-slot OWNERSHIP: the engine sources lib/forge-slot.sh and brackets each PoC run with
#        acquire_forge_slot / release_forge_slot (run-poc.sh does NOT self-acquire).
#     4) READ-ONLY / never-submit: no network / submission verb on any executable line.
#   Part 2 LIVE-UNDER-STUB (pure shell):
#     5) the emitted VECTOR| set == expected-vectors.golden (cap respected, content-hash dedup holds, a
#        `dismissed:` CALLEE-VECTOR never seeds a vector).
#     6) every enumerated (CANDIDATE) vector routed to the PoC runner (a per-vector poc.log exists per hash).
#     7) exactly the ONE PoC-PASS vector merged into verified_findings.json == verified.golden.json.
#     8) a 2nd --resume run is a BYTE-IDENTICAL no-op (resumability / dedup).
#     9) the cap truncates: --max-vectors 2 emits exactly 2 VECTOR| lines.
#
# Usage:  dark-factory/demo-vector-hunt.sh   (GENERATE_GOLDEN=1 rewrites the checked-in goldens)
# Requires: python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression / the engine is absent
# (the fail-before source-guard). POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal ASCII only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/run-vector-hunt.sh"
FX="$HERE/fixtures/vector-hunt"
CALLEE_VECTORS="$FX/callee-vectors.txt"
STUB="$FX/poc-runner-stub.sh"
GOLDEN_VEC="$FX/expected-vectors.golden"
GOLDEN_VJ="$FX/verified.golden.json"

FAILS=0
note() { echo "demo-vector-hunt.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

# ==========================================================================================================
# PART 1 — SOURCE-GUARD (no forge / no agentis / no network).
# ==========================================================================================================
note "1) run-vector-hunt.sh exists + is executable ..."
if [ -x "$ENGINE" ]; then
  ok "run-vector-hunt.sh is present and executable"
else
  bad "run-vector-hunt.sh not found / not executable: $ENGINE (fail-before: the engine does not exist yet)"
  note "FAIL — the vector-hunt engine is absent" >&2
  exit 3
fi

note "2) the generic invariant catalog + hazard->invariant map + cap + source tag + seams are present ..."
MISS=""
for anchor in \
  'solvency' 'share-price-monotonicity' 'no-unauthorized-mint' \
  'reentrancy-state-consistency' 'return-value-trust' 'gas-liveness' \
  'HAZARD_INVARIANT' '--max-vectors' 'source=vector-hunt' '"source": "vector-hunt"' \
  '--poc-runner' '--resume' 'VECTOR-HUNT|' 'vector_hash'
do
  grep -F -q -e "$anchor" "$ENGINE" || MISS="$MISS $anchor"
done
if [ -z "$MISS" ]; then
  ok "the catalog rows, the hazard->invariant map, the cap flag, the source=vector-hunt tag, and the --poc-runner/--resume seams are all present"
else
  bad "the engine is missing load-bearing anchors:$MISS"
fi

note "3) forge-slot OWNERSHIP: the engine sources lib/forge-slot.sh and brackets each PoC run ..."
if grep -Fq 'lib/forge-slot.sh' "$ENGINE" \
   && grep -Fq 'acquire_forge_slot' "$ENGINE" \
   && grep -Fq 'release_forge_slot' "$ENGINE"; then
  ok "run-vector-hunt.sh owns the forge slot (acquire/release around each PoC run — run-poc.sh does not self-acquire, so FORGE_MAX_SLOTS is respected)"
else
  bad "the engine does not source lib/forge-slot.sh or does not bracket the PoC run with acquire/release"
fi

note "4) read-only / never-submit posture ..."
if grep -vE '^[[:space:]]*#' "$ENGINE" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "run-vector-hunt.sh invokes a network / submission verb on an executable line"
else
  ok "run-vector-hunt.sh has no network / no submission verb on any executable line (read-only, never submits)"
fi

# ==========================================================================================================
# PART 2 — LIVE-UNDER-STUB (pure shell: the whole loop under the offline --poc-runner seam).
# ==========================================================================================================
[ -x "$STUB" ] || { bad "the offline poc-runner stub is missing / not executable: $STUB"; }
[ -f "$CALLEE_VECTORS" ] || { bad "the callee-vectors fixture is missing: $CALLEE_VECTORS"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-vector-hunt.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Isolate the forge-slot pool to this run — never touch the host-wide pool a live hunt shares.
export FORGE_SLOTS_DIR="$WORK/forge-slots"
mkdir -p "$WORK/target"

run_engine() {
  # run_engine <out-dir> <max-vectors> [extra-args...]
  re_out="$1"; re_max="$2"; shift 2
  "$ENGINE" \
    --repo "$WORK/target" --target "Vault.sol:Vault" --class "C-erc4626" \
    --callee-vectors "$CALLEE_VECTORS" --poc-runner "$STUB" \
    --max-vectors "$re_max" --out "$re_out" --backend mock --agentis /bin/true "$@"
}

note "5) the emitted VECTOR| set == expected-vectors.golden (cap / dedup / dismissed-exclusion) ..."
OUT1="$WORK/out1"
run_engine "$OUT1" 6 > "$WORK/run1.out" 2> "$WORK/run1.err"
grep '^VECTOR|' "$WORK/run1.out" > "$WORK/vectors.emitted"

if [ "${GENERATE_GOLDEN:-0}" = "1" ]; then
  mkdir -p "$FX"
  cp "$WORK/vectors.emitted" "$GOLDEN_VEC"
  cp "$OUT1/verified_findings.json" "$GOLDEN_VJ"
  note "GENERATE_GOLDEN=1 -> rewrote $GOLDEN_VEC and $GOLDEN_VJ"
fi

if [ -f "$GOLDEN_VEC" ] && cmp -s "$WORK/vectors.emitted" "$GOLDEN_VEC"; then
  ok "the enumerated VECTOR| set is byte-identical to expected-vectors.golden (the duplicate CANDIDATE collapsed, the dismissed vector was excluded, the cap held)"
else
  bad "the enumerated VECTOR| set drifted from the golden:"
  [ -f "$GOLDEN_VEC" ] && diff "$GOLDEN_VEC" "$WORK/vectors.emitted" | sed 's/^/      /' >&2
fi
# A dismissed CALLEE-VECTOR (setFee) must NEVER appear as an enumerated vector.
if grep -Fq 'setFee' "$WORK/vectors.emitted"; then
  bad "a dismissed: CALLEE-VECTOR (setFee) leaked into the enumerated set"
else
  ok "the dismissed: CALLEE-VECTOR (setFee) never seeded a vector (contamination + budget discipline)"
fi

note "6) every enumerated vector routed to the PoC runner (a per-vector poc.log exists per hash) ..."
ROUTE_OK=1
while IFS='|' read -r _p vh _rest; do
  [ "$_p" = "VECTOR" ] || continue
  [ -f "$OUT1/vector-hunt/$vh/poc.log" ] || { ROUTE_OK=0; bad "no PoC log for enumerated vector $vh"; }
done < "$WORK/vectors.emitted"
[ "$ROUTE_OK" -eq 1 ] && ok "each enumerated vector was routed through the --poc-runner seam (a per-vector poc.log was captured)"

note "7) exactly the ONE PoC-PASS vector merged into verified_findings.json == verified.golden.json ..."
if [ -f "$GOLDEN_VJ" ] && cmp -s "$OUT1/verified_findings.json" "$GOLDEN_VJ"; then
  ok "verified_findings.json holds exactly the one PoC-PASS vector (source=vector-hunt), byte-identical to the golden — CLEAN vectors merged nothing"
else
  bad "the merged verified_findings.json drifted from the golden:"
  [ -f "$GOLDEN_VJ" ] && diff "$GOLDEN_VJ" "$OUT1/verified_findings.json" | sed 's/^/      /' >&2
fi
# Independent structural check: exactly one verified entry, tagged source=vector-hunt, PASS-only.
if python3 - "$OUT1/verified_findings.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d.get("verified", [])
assert len(v) == 1, "verified[] len != 1: %d" % len(v)
e = v[0]
assert e["source"] == "vector-hunt", "wrong source tag: %r" % e.get("source")
assert e["verdict"] == "FINDING", "not a FINDING: %r" % e.get("verdict")
assert e["location"] == "Vault.sol:executeDeposit", "wrong location: %r" % e.get("location")
assert e.get("vector_hash"), "missing vector_hash"
assert d["totals"]["verified"] == 1, "totals.verified != 1"
PY
then ok "the merged entry is exactly one PoC-PASS vector tagged source=vector-hunt on the reentrant executeDeposit vector"
else bad "the merged entry shape is wrong"
fi

note "8) a 2nd --resume run is a BYTE-IDENTICAL no-op (resumability / dedup) ..."
cp "$OUT1/verified_findings.json" "$WORK/vj.before"
run_engine "$OUT1" 6 --resume > "$WORK/run2.out" 2> "$WORK/run2.err"
if cmp -s "$WORK/vj.before" "$OUT1/verified_findings.json"; then
  ok "the --resume re-run left verified_findings.json byte-identical (no vector re-verified, no finding re-merged)"
else
  bad "the --resume re-run mutated verified_findings.json:"
  diff "$WORK/vj.before" "$OUT1/verified_findings.json" | sed 's/^/      /' >&2
fi

note "9) the cap truncates: --max-vectors 2 emits exactly 2 VECTOR| lines ..."
OUT3="$WORK/out3"
run_engine "$OUT3" 2 > "$WORK/run3.out" 2> "$WORK/run3.err"
N_CAP="$(grep -c '^VECTOR|' "$WORK/run3.out" 2>/dev/null || echo 0)"
if [ "$N_CAP" -eq 2 ]; then
  ok "--max-vectors 2 bounded the enumerated set to exactly 2 vectors (the explicit cap)"
else
  bad "--max-vectors 2 emitted $N_CAP vectors (expected 2)"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the invariant-driven vector-enumeration loop (run-vector-hunt.sh: enumerate -> per-vector forge-verify -> only-PoC-PASS merged, deduped + resumable) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
