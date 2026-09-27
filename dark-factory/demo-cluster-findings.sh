#!/usr/bin/env bash
# demo-cluster-findings.sh — OFFLINE, DETERMINISTIC proof of #2278 root-cause clustering (lib/cluster-findings.py
# + its wiring into verify-findings.sh). No live agentis / forge / network: the verify integration runs through
# the existing run-refute.sh --agentis seam with a fast stub, the same pattern demo-verify-findings.sh uses.
#
# Assertions:
#   1) SYNTHETIC FIXTURE (fixtures/cluster-findings/synthetic.json, pinned expected-clusters.tsv): three
#      cross-class duplicates of one bug in one function (class/severity formatting variants) collapse into ONE
#      entry; a near-identical text in a DIFFERENT function never merges; a function-less location and a
#      `source=invariant-hunt` entry pass through unclustered; every singleton is byte-identical to its raw copy.
#   2) SAME FUNCTION, DIFFERENT BUGS (fixtures/cluster-findings/same-function-distinct.json): three pairs of
#      distinct root causes that share a function (incl. the OracleLess `fillOrder` reentrancy vs unallowlisted
#      target case) stay separate at the pinned threshold — alone and alongside their duplicates — while each
#      finding still merges with its own duplicate. The fixture BINDS the threshold: at 0.25 a distinct pair merges.
#   3) REPRESENTATIVE + SCHEMA: the highest severity wins (even over an adjudicated member), the operator-
#      adjudicated member wins a severity tie, the more concrete poc_sketch wins a full tie; `duplicates`,
#      `also_classes` (normalised, numeric order, own class excluded) and `also_locations` are right;
#      totals.verified == len(verified), totals.verified_precluster, clustering.raw_sha256 == sha256(raw), and
#      every other top-level key is copied verbatim.
#   4) EDGE CASES: raw-view round-trips byte-for-byte to the raw list, re-appends a later `source` entry (and
#      recounts totals.verified), refuses a stale sibling (exit 3) and echoes an unclustered file unchanged;
#      `cluster` refuses an already-clustered file (exit 2), a bad threshold (exit 2) and malformed input
#      (exit 3), and two runs are byte-identical.
#   5) verify-findings.sh INTEGRATION: default ON over two confirmed same-function duplicates -> 1 clustered entry
#      + a 2-entry sibling; DF_CLUSTER_FINDINGS=0 and --cluster-findings 0 -> no sibling and a file byte-identical
#      to the ON run's sibling; a duplicate-free input under ON is byte-identical to OFF with no sibling; an OFF
#      re-run removes a stale sibling; bad knob values exit 2; a failing clusterer (DF_CLUSTER_CMD=false) restores
#      the raw file, prints a WARNING and exits 0; --jobs 3 is byte-identical to --jobs 1.
#
# Usage:  dark-factory/demo-cluster-findings.sh
# Requires: python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe style: no pipefail, no arrays, no $'...', no process substitution.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CL="$HERE/lib/cluster-findings.py"
VERIFY="$HERE/verify-findings.sh"
FIX="$HERE/fixtures/cluster-findings"

FAILS=0
note() { echo "demo-cluster-findings.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (want '$2', got '$1')"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -f "$CL" ] || { note "lib/cluster-findings.py not found: $CL" >&2; exit 3; }
[ -x "$VERIFY" ] || { note "verify-findings.sh not found / not executable: $VERIFY" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-cluster-findings.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# summarize <clustered.json> -> one TSV row per entry: location, class, severity, duplicates, also_classes,
# also_locations ('-' when the key is absent, i.e. a singleton).
summarize() {
  python3 - "$1" <<'PY'
import sys, json
for v in json.load(open(sys.argv[1], encoding="utf-8"))["verified"]:
    def g(k, j=None):
        if k not in v:
            return "-"
        return j.join(v[k]) if j is not None else str(v[k])
    print("\t".join([v["location"], v["class"], v["severity"], g("duplicates"), g("also_classes", ","),
                     g("also_locations", "|")]))
PY
}

# ---------------------------------------------------------------------------------------------------------------
note "1) synthetic fixture: cross-class duplicates merge, a different function / function-less / source entry do not"
S_OUT="$WORK/synthetic.clustered.json"
S_LINE="$(python3 "$CL" cluster --in "$FIX/synthetic.json" --out "$S_OUT")"
check "$S_LINE" "CLUSTER|8|5|3" "8 raw findings -> 5 entries (3 merged)"
summarize "$S_OUT" > "$WORK/synthetic.tsv"
if cmp -s "$WORK/synthetic.tsv" "$FIX/expected-clusters.tsv"; then
  ok "clustered entries match fixtures/cluster-findings/expected-clusters.tsv (one swap cluster, flash / file:line / source=invariant-hunt untouched)"
else
  bad "clustered entries differ from expected-clusters.tsv"; diff "$FIX/expected-clusters.tsv" "$WORK/synthetic.tsv"
fi
SINGLE="$(python3 - "$FIX/synthetic.json" "$S_OUT" <<'PY'
import sys, json
raw = json.load(open(sys.argv[1], encoding="utf-8"))["verified"]
out = json.load(open(sys.argv[2], encoding="utf-8"))["verified"]
# Entries 3, 4, 5 of the raw list are the singletons; they are entries 1, 2, 3 of the clustered list.
print("same" if all(json.dumps(raw[r], indent=2) == json.dumps(out[c], indent=2)
                    for r, c in ((3, 1), (4, 2), (5, 3))) else "differ")
PY
)"
check "$SINGLE" "same" "singleton entries are byte-identical to their raw copies"

# ---------------------------------------------------------------------------------------------------------------
note "2) same function, different bugs: distinct pairs stay separate, duplicates still merge"
D_ALL="$(python3 "$CL" cluster --in "$FIX/same-function-distinct.json" --out "$WORK/distinct.json")"
check "$D_ALL" "CLUSTER|12|6|6" "12 findings (3 functions x 2 bugs x 2 duplicates) -> 6 distinct root causes"
# subset <out> <threshold|-> <indices...> -> the CLUSTER line of that subset of same-function-distinct.json
subset() {
  sb_out="$1"; sb_t="$2"; shift 2
  python3 - "$FIX/same-function-distinct.json" "$sb_out" "$@" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["verified"] = [d["verified"][int(i)] for i in sys.argv[3:]]
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(d, indent=2) + "\n")
PY
  if [ "$sb_t" = "-" ]; then
    python3 "$CL" cluster --in "$sb_out" --out "$sb_out.c"
  else
    python3 "$CL" cluster --in "$sb_out" --out "$sb_out.c" --threshold "$sb_t"
  fi
}
# Blocks: 0-1 = fillOrder reentrancy (dup pair), 2-3 = fillOrder unallowlisted target; 4-5 / 6-7 = withdraw
# rounding / missing allowance; 8-9 / 10-11 = getPrice staleness / decimals.
DISTINCT_OK=1
for pair in "0 2" "0 3" "1 2" "1 3" "4 6" "4 7" "5 6" "5 7" "8 10" "8 11" "9 10" "9 11"; do
  # shellcheck disable=SC2086
  got="$(subset "$WORK/pair.json" - $pair)"
  [ "$got" = "CLUSTER|2|2|0" ] || { DISTINCT_OK=0; echo "    distinct pair ($pair) merged: $got"; }
done
if [ "$DISTINCT_OK" -eq 1 ]; then ok "every one of the 12 cross-bug pairs stays separate on its own"; else bad "a distinct same-function pair merged"; fi
DUP_OK=1
for pair in "0 1" "2 3" "4 5" "6 7" "8 9" "10 11"; do
  # shellcheck disable=SC2086
  got="$(subset "$WORK/pair.json" - $pair)"
  [ "$got" = "CLUSTER|2|1|1" ] || { DUP_OK=0; echo "    duplicate pair ($pair) did not merge: $got"; }
done
if [ "$DUP_OK" -eq 1 ]; then ok "each finding still merges with its own cross-class duplicate"; else bad "a duplicate pair did not merge"; fi
check "$(subset "$WORK/pair.json" 0.25 0 2)" "CLUSTER|2|1|1" \
  "the fixture binds the threshold: at 0.25 the fillOrder reentrancy / unallowlisted-target pair would merge"

# ---------------------------------------------------------------------------------------------------------------
note "3) representative choice + schema"
SCHEMA="$(python3 - "$FIX/synthetic.json" "$S_OUT" <<'PY'
import sys, json, hashlib
raw_bytes = open(sys.argv[1], "rb").read()
raw = json.loads(raw_bytes)
out = json.load(open(sys.argv[2], encoding="utf-8"))
v = out["verified"]
res = []
swap, setfee = v[0], v[4]
res.append("adjudicated-tie" if swap["reason"].startswith("operator-adjudicated") and swap["severity"] == "severity=High" else "bad-adjudicated")
res.append("sketch" if setfee["class"] == "C9" else "bad-sketch")
res.append("fields" if (swap["duplicates"], swap["also_classes"], swap["also_locations"]) == (2, ["C2", "C15"], ["src/Pool.sol:swap:121"])
           and (setfee["duplicates"], setfee["also_classes"], setfee["also_locations"]) == (1, ["C5"], []) else "bad-fields")
t = out["totals"]
res.append("totals" if t["verified"] == len(v) == 5 and t["verified_precluster"] == 8 and t["candidates"] == 9
           and t["errored"] == 1 else "bad-totals")
c = out["clustering"]
res.append("block" if c["raw_sha256"] == hashlib.sha256(raw_bytes).hexdigest() and c["raw_file"] == "verified_findings.raw.json"
           and (c["raw_verified"], c["clusters"], c["merged"], c["threshold"]) == (8, 5, 3, 0.3) else "bad-block")
res.append("keys" if all(out[k] == raw[k] for k in raw if k not in ("verified", "totals"))
           and list(out)[:len(raw)] == list(raw) else "bad-keys")
print(" ".join(res))
PY
)"
check "$SCHEMA" "adjudicated-tie sketch fields totals block keys" \
  "adjudicated member wins the High tie, concrete poc_sketch wins a full tie, duplicates/also_* + totals + clustering block + verbatim keys"
python3 - "$WORK/sev.json" <<'PY'
import sys, json
e = lambda sev, reason: {"subsystem": "s", "location": "src/A.sol:f:1", "file": "src/A.sol", "class": "C1",
                         "severity": sev, "exploit": "f calls _sync() before updating reserveA via getReserves()",
                         "poc_sketch": "p", "verdict": "REAL", "reason": reason}
d = {"verified": [e("Medium", "operator-adjudicated (confirmed): refute skipped (#2023)"), e("Critical", "gate")],
     "totals": {"verified": 2}}
open(sys.argv[1], "w").write(json.dumps(d, indent=2) + "\n")
PY
python3 "$CL" cluster --in "$WORK/sev.json" --out "$WORK/sev.c.json" >/dev/null
check "$(python3 -c 'import sys, json; print(json.load(open(sys.argv[1]))["verified"][0]["severity"])' "$WORK/sev.c.json")" \
  "Critical" "the highest severity outranks an operator-adjudicated lower-severity member"

# ---------------------------------------------------------------------------------------------------------------
note "4) raw-view + cluster edge cases"
RV="$WORK/rv"; mkdir -p "$RV"
cp "$FIX/synthetic.json" "$RV/verified_findings.raw.json"
python3 "$CL" cluster --in "$RV/verified_findings.raw.json" --out "$RV/verified_findings.json" >/dev/null
python3 "$CL" raw-view --verified "$RV/verified_findings.json" > "$WORK/rv.out"
if cmp -s "$WORK/rv.out" "$FIX/synthetic.json"; then ok "raw-view round-trips byte-for-byte to the raw list"; else bad "raw-view does not round-trip"; fi
# Simulate a later STAGE 4.5 append (deep-hunt-gate.sh: verified[] += {source: invariant-hunt}, totals.verified++).
python3 - "$RV/verified_findings.json" <<'PY'
import sys, json
p = sys.argv[1]
d = json.load(open(p))
d["verified"].append({"location": "src/Pool.sol:swap", "class": "C11", "severity": "High", "exploit": "x", "source": "invariant-hunt"})
d["totals"]["verified"] += 1
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
APPENDED="$(python3 "$CL" raw-view --verified "$RV/verified_findings.json" \
  | python3 -c 'import sys, json; d = json.load(sys.stdin); print(len(d["verified"]), d["totals"]["verified"], d["verified"][-1].get("source"), "clustering" in d, "verified_precluster" in d["totals"])')"
check "$APPENDED" "9 9 invariant-hunt False False" "raw-view re-appends a later source entry and recounts totals.verified"
printf ' ' >> "$RV/verified_findings.raw.json"
python3 "$CL" raw-view --verified "$RV/verified_findings.json" >/dev/null 2>&1; check "$?" "3" "raw-view refuses a stale (sha256-mismatched) sibling (exit 3)"
python3 "$CL" raw-view --verified "$FIX/synthetic.json" > "$WORK/echo.out"
if cmp -s "$WORK/echo.out" "$FIX/synthetic.json"; then ok "raw-view echoes an unclustered file unchanged"; else bad "raw-view altered an unclustered file"; fi
python3 "$CL" cluster --in "$S_OUT" --out "$WORK/twice.json" >/dev/null 2>&1; check "$?" "2" "cluster refuses an already-clustered file (exit 2)"
for t in 0 1.5 abc; do
  python3 "$CL" cluster --in "$FIX/synthetic.json" --out "$WORK/t.json" --threshold "$t" >/dev/null 2>&1; check "$?" "2" "cluster rejects --threshold $t (exit 2)"
done
printf '{not json' > "$WORK/broken.json"
python3 "$CL" cluster --in "$WORK/broken.json" --out "$WORK/t.json" >/dev/null 2>&1; check "$?" "3" "cluster rejects malformed input (exit 3)"
python3 "$CL" cluster --in "$FIX/synthetic.json" --out "$WORK/again.json" >/dev/null
if cmp -s "$WORK/again.json" "$S_OUT"; then ok "two cluster runs are byte-identical"; else bad "cluster is not deterministic"; fi

# ---------------------------------------------------------------------------------------------------------------
note "5) verify-findings.sh integration (offline refute stub through the --agentis seam)"
REPO="$WORK/target"; mkdir -p "$REPO/contracts"
printf 'contract Pool { function swap() public {} function setFee() public {} }\n' > "$REPO/contracts/Pool.sol"
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go) echo "VERDICT|REAL|${CAND_FILE_FN:-}|${CAND_CLASS:-}|survived a hostile read"; exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"
# results <file> <second-location> -> two candidates: the swap bug twice (dup) or swap + a different function.
results() {
  python3 - "$1" "$2" <<'PY'
import sys, json
bug = ("swap reads sqrtPriceX96 from slot0 after uniswapV3SwapCallback, so donate() inside the callback moves "
       "sqrtPriceX96 and feeGrowthGlobal0X128 credits the fee to callback-minted liquidity")
second = sys.argv[2]
c2 = second + "|C15|High|" + bug + "|callback -> donate()" if "swap" in second else \
     second + "|C5|High|setFee has no onlyOwner so anyone sets protocolFee|call setFee"
d = {"repo": "target", "backend": "mock", "jobs": 1, "cells": [
    {"subsystem": "pool", "class": "C2", "files": "contracts/Pool.sol",
     "candidates": ["contracts/Pool.sol:swap:120|C2|High|" + bug + "|reenter donate()"]},
    {"subsystem": "pool", "class": "C15", "files": "contracts/Pool.sol", "candidates": [c2]}]}
open(sys.argv[1], "w").write(json.dumps(d, indent=2) + "\n")
PY
}
DUP_RES="$WORK/dup-results.json"; results "$DUP_RES" "contracts/Pool.sol:swap:121"
UNIQ_RES="$WORK/uniq-results.json"; results "$UNIQ_RES" "contracts/Pool.sol:setFee:40"
run_verify() {  # run_verify <out> <results> [extra args...]; stderr -> <out>.log
  rv_out="$1"; rv_res="$2"; shift 2
  "$VERIFY" --results "$rv_res" --repo "$REPO" --out "$rv_out" --gate refute --backend mock --agentis "$STUB" "$@" \
    2> "$rv_out.log" >/dev/null
}
count() { python3 -c 'import sys, json; print(len(json.load(open(sys.argv[1]))["verified"]))' "$1"; }

( unset DF_CLUSTER_FINDINGS; run_verify "$WORK/on" "$DUP_RES" ); rc=$?
check "$rc" "0" "default run exits 0"
check "$(count "$WORK/on/verified_findings.json") $(count "$WORK/on/verified_findings.raw.json")" "1 2" \
  "default ON: two confirmed same-function duplicates -> 1 clustered entry, 2 in verified_findings.raw.json"
if grep -q 'clustering: 2 confirmed -> 1 distinct root cause(s) (1 merged)' "$WORK/on.log" \
   && grep -q 'VERIFY \[refute\]: 2 candidate(s), 2 confirmed, 0 errored' "$WORK/on.log"; then
  ok "stderr carries the clustering line; the VERIFY banner still reports the gate-confirmed count"
else
  bad "clustering stderr line / VERIFY banner wrong"; cat "$WORK/on.log"
fi

DF_CLUSTER_FINDINGS=0 run_verify "$WORK/off-env" "$DUP_RES"
run_verify "$WORK/off-flag" "$DUP_RES" --cluster-findings 0
if [ ! -e "$WORK/off-env/verified_findings.raw.json" ] && [ ! -e "$WORK/off-flag/verified_findings.raw.json" ] \
   && cmp -s "$WORK/off-env/verified_findings.json" "$WORK/on/verified_findings.raw.json" \
   && cmp -s "$WORK/off-flag/verified_findings.json" "$WORK/on/verified_findings.raw.json"; then
  ok "DF_CLUSTER_FINDINGS=0 and --cluster-findings 0: no sibling, output byte-identical to the ON run's sibling"
else
  bad "OFF output is not the pre-cluster list, or a sibling was written"
fi

run_verify "$WORK/uniq-on" "$UNIQ_RES"
run_verify "$WORK/uniq-off" "$UNIQ_RES" --cluster-findings 0
if cmp -s "$WORK/uniq-on/verified_findings.json" "$WORK/uniq-off/verified_findings.json" \
   && [ ! -e "$WORK/uniq-on/verified_findings.raw.json" ] && ! grep -q 'clustering:' "$WORK/uniq-on.log"; then
  ok "duplicate-free input under ON is byte-identical to OFF, with no sibling"
else
  bad "a duplicate-free ON run differs from OFF or left a sibling"
fi

run_verify "$WORK/on" "$DUP_RES" --cluster-findings 0
if [ ! -e "$WORK/on/verified_findings.raw.json" ] && [ "$(count "$WORK/on/verified_findings.json")" = "2" ]; then
  ok "an OFF re-run into the same --out removes the stale sibling"
else
  bad "a stale verified_findings.raw.json survived an OFF re-run"
fi

run_verify "$WORK/bad1" "$DUP_RES" --cluster-findings 2; check "$?" "2" "--cluster-findings 2 is a usage error (exit 2)"
DF_CLUSTER_FINDINGS=yes run_verify "$WORK/bad2" "$DUP_RES"; check "$?" "2" "DF_CLUSTER_FINDINGS=yes is a usage error (exit 2)"
DF_CLUSTER_THRESHOLD=1.5 run_verify "$WORK/bad3" "$DUP_RES"; check "$?" "2" "DF_CLUSTER_THRESHOLD=1.5 is a usage error (exit 2)"
if [ ! -e "$WORK/bad1/gates" ] && [ ! -e "$WORK/bad3/gates" ]; then ok "bad knob values fail before any side effect"; else bad "a bad knob value ran the gate"; fi

DF_CLUSTER_CMD=false run_verify "$WORK/failcl" "$DUP_RES"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'WARNING: root-cause clustering failed' "$WORK/failcl.log" \
   && cmp -s "$WORK/failcl/verified_findings.json" "$WORK/off-env/verified_findings.json" \
   && [ ! -e "$WORK/failcl/verified_findings.raw.json" ]; then
  ok "a failing clusterer restores the raw file, warns loudly and exits 0 (fail-open)"
else
  bad "a failing clusterer lost the raw file, stayed silent or failed the run (rc=$rc)"
fi

run_verify "$WORK/j1" "$DUP_RES" --jobs 1
run_verify "$WORK/j3" "$DUP_RES" --jobs 3
if cmp -s "$WORK/j1/verified_findings.json" "$WORK/j3/verified_findings.json" \
   && cmp -s "$WORK/j1/verified_findings.raw.json" "$WORK/j3/verified_findings.raw.json"; then
  ok "--jobs 3 clustered output + sibling are byte-identical to --jobs 1"
else
  bad "clustering output depends on --jobs"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS — root-cause clustering holds (same-function key, distinct bugs kept apart, raw list never lost)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) failed"
exit 1
