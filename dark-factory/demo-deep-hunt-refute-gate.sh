#!/usr/bin/env bash
# demo-deep-hunt-refute-gate.sh — OFFLINE, DETERMINISTIC proof of the STAGE 4.5 refute/validity gate (#1938):
# deep-hunt-gate.sh runs an INVARIANT-MODE adversarial refuter over each invariant-hunt FINDING BEFORE it is
# merged into verified_findings.json. Survivors -> verified[]; refuted findings -> a new additive refuted[]
# bucket (with the reason); a gate error -> verified[] tagged refute_gate=unassessed (fail-open). Every gate
# call is driven by a FAST offline stub wired through the EXISTING run-refute.sh --agentis seam — NO live
# agentis, NO forge, NO network.
#
# Assertions:
#   1) GATE ON: three false-positive ANCHORS (incl. reserve-protocol RebalancingLib C6) each land in refuted[]
#      with a non-empty refute_reason and are ABSENT from verified[]; the positive-control survivor lands in
#      verified[]. totals.verified / totals.refuted are correct.
#   2) BYTE-IDENTITY: --no-refute reproduces the RAW pre-#1938 merge byte-for-byte — matched against BOTH a
#      reference re-implementation of the original inline adapter AND the checked-in golden
#      fixtures/deep-hunt/raw-merge.golden.json.
#   3) NO-OP: a CLEAN (non-FINDING) invariant log is a no-op — deep-hunt-gate.sh prints `0` and never writes.
#   4) FAIL-OPEN: a gate that produces no verdict (chrome only) does NOT destroy the finding — it lands in
#      verified[] tagged refute_gate=unassessed and is logged loudly, distinguishable from a clean merge.
#   5) READ-ONLY / NEVER-SUBMIT: no network / submission verb on deep-hunt-gate.sh's executable lines.
#
# The three anchors are the session's live false positives, encoded as CI fixtures with their provenance:
#   a) reserve-protocol/reserve-index-dtf @ d37a3814, contracts/utils/RebalancingLib.sol (C6) — REFUTED on BOTH
#      axes: a per-auction maxAuctionSize mis-read as a cumulative cap, and openAuction is AUCTION_LAUNCHER-gated.
#   b) balancer/balancer-v3 Vault.settle() (C6) — REFUTED on axis (a): crediting the settler for surplus is
#      documented by-design and needs a victim to leave tokens unsettled (a user-error precondition).
#   c) balancer/balancer-v3 Vault (SYS-solvency) — REFUTED on axis (b): hooks are trusted pool components
#      (a malicious hook is a malicious pool, out of scope) plus an absurd witness amount.
#
# Usage:  dark-factory/demo-deep-hunt-refute-gate.sh   (GENERATE_GOLDEN=1 rewrites the checked-in golden)
# Requires: python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', no process substitution, literal ASCII only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/deep-hunt-gate.sh"
GOLDEN="$HERE/fixtures/deep-hunt/raw-merge.golden.json"

FAILS=0
note() { echo "demo-deep-hunt-refute-gate.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$GATE" ] || { note "deep-hunt-gate.sh not found / not executable: $GATE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-deep-hunt-refute-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# (a) A throwaway target repo holding the four contract sources the findings reference. None trips
#     run-refute.sh's #1699 C6-accounting signal (no value-moving decl + `-=`), so no fallback perturbs the run.
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target"
mkdir -p "$REPO/contracts/utils" "$REPO/pkg/vault/contracts" "$REPO/contracts"
printf 'contract RebalancingLib { function openAuction(uint256 size) external {} }\n' > "$REPO/contracts/utils/RebalancingLib.sol"
printf 'contract Vault { function settle(address token, uint256 amount) external {} }\n' > "$REPO/pkg/vault/contracts/Vault.sol"
printf 'contract VaultHooks { function onAfterSwap(uint256 amount) external {} }\n'   > "$REPO/pkg/vault/contracts/VaultHooks.sol"
printf 'contract LendingPool { function redeem(uint256 shares) external {} }\n'       > "$REPO/contracts/LendingPool.sol"

# ----------------------------------------------------------------------------------------------------------
# (b) The four STAGE 4.5 FINDING fixtures: each a run/invariant_<slug>.log carrying an INVARIANT|<t>|FINDING
#     line + the shrunk STEP| witness the merge adapter reads (fn = first identifier-before-'(' in the STEP|s).
# ----------------------------------------------------------------------------------------------------------
mk_finding() {
    # mk_finding <dzout-dir> <slug> <invariant-target> <step1> [<step2>]
    mf_dz="$1"; mf_slug="$2"; mf_inv="$3"; mf_s1="$4"; mf_s2="${5:-}"
    mkdir -p "$mf_dz/run"
    {
        printf 'INVARIANT|%s|FINDING\n' "$mf_inv"
        printf 'STEP|%s\n' "$mf_s1"
        [ -n "$mf_s2" ] && printf 'STEP|%s\n' "$mf_s2"
    } > "$mf_dz/run/invariant_${mf_slug}.log"
}

DZ_A1="$WORK/dz-rebalancing"
DZ_A2="$WORK/dz-settle"
DZ_A3="$WORK/dz-hooks"
DZ_CT="$WORK/dz-control"
mk_finding "$DZ_A1" "rebalancing" "RebalancingLib.maxAuctionSize <= budget" "openAuction(1000)" "bid(500)"
mk_finding "$DZ_A2" "settle"      "Vault settle credit conserves tokens"    "settle(token, 0)"
mk_finding "$DZ_A3" "hooks"       "Vault total assets >= total liabilities" "onAfterSwap(999999999)"
mk_finding "$DZ_CT" "control"     "LendingPool solvency: assets >= shares"  "redeem(1)" "drain()"

# A fifth fixture: a CLEAN (non-FINDING) verdict — the merge no-op path.
DZ_CLEAN="$WORK/dz-clean"
mkdir -p "$DZ_CLEAN/run"
printf 'INVARIANT|SomeLib bound holds|CLEAN\n' > "$DZ_CLEAN/run/invariant_clean.log"

# ----------------------------------------------------------------------------------------------------------
# (c) The fast offline invariant-mode refuter stub through the --agentis seam. run-refute.sh env-ins
#     CAND_FILE_FN (= <relfile>:<fn>) and CAND_INVARIANT (the broken-invariant sentence). The stub REFUTES the
#     three anchors (each with a specific reason) and confirms the positive control REAL. STUB_SILENT=1 emits
#     TUI chrome with NO VERDICT| line (the fail-open path). NO live agentis / network.
# ----------------------------------------------------------------------------------------------------------
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    fn="${CAND_FILE_FN:-}"
    cls="${CAND_CLASS:-}"
    if [ "${STUB_SILENT:-0}" = "1" ]; then
      printf 'high * /effort\n'
      printf 'esc to interrupt\n'
      exit 0
    fi
    case "$fn" in
      *RebalancingLib*)
        echo "VERDICT|REFUTED|$fn|$cls|per-auction maxAuctionSize is mis-read as a cumulative cap and openAuction is AUCTION_LAUNCHER-role gated" ;;
      *Vault.sol:settle*)
        echo "VERDICT|REFUTED|$fn|$cls|crediting the settler for surplus is documented by-design and needs a victim to leave tokens unsettled" ;;
      *VaultHooks*)
        echo "VERDICT|REFUTED|$fn|$cls|hooks are trusted pool components so a malicious hook is a malicious pool and the witness amount is absurd" ;;
      *LendingPool*)
        echo "VERDICT|REAL|$fn|$cls|an unprivileged redeem drains the pool and the solvency invariant is a genuine protocol guarantee" ;;
      *)
        echo "VERDICT|REFUTED|$fn|$cls|unrecognized candidate" ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

# gate_call <dzout> <relfile> <class> <verified-json> [<extra-run-refute-args-via-env>] -> prints the token.
# DF_AGENT_MAX_ATTEMPTS keeps the (never-clearing) chrome path fast.
gate_call() {
    gc_dz="$1"; gc_rel="$2"; gc_cls="$3"; gc_vj="$4"; shift 4
    DF_AGENT_MAX_ATTEMPTS=2 "$GATE" \
      --deep-out "$gc_dz" --relfile "$gc_rel" --class "$gc_cls" \
      --repo "$REPO" --verified-json "$gc_vj" \
      --backend mock --agentis "$STUB" "$@"
}

# ==========================================================================================================
# (1) GATE ON: anchors refuted, control verified, totals correct.
# ==========================================================================================================
note "1) gate ON: three FP anchors -> refuted[], the positive control -> verified[] ..."
VJ="$WORK/verified_findings.json"
# STAGE 4 normally seeds this file; start from a small pre-existing shape to prove the buckets are ADDITIVE.
python3 - > "$VJ" <<'PY'
import json
print(json.dumps({"repo": "target", "gate": "refute", "verified": [], "totals": {"candidates": 0, "verified": 0}}, indent=2))
PY

T_A1="$(gate_call "$DZ_A1" "contracts/utils/RebalancingLib.sol" "C6" "$VJ" 2>"$WORK/a1.err")"
T_A2="$(gate_call "$DZ_A2" "pkg/vault/contracts/Vault.sol" "C6" "$VJ" 2>"$WORK/a2.err")"
T_A3="$(gate_call "$DZ_A3" "pkg/vault/contracts/VaultHooks.sol" "SYS-solvency" "$VJ" 2>"$WORK/a3.err")"
T_CT="$(gate_call "$DZ_CT" "contracts/LendingPool.sol" "C6" "$VJ" 2>"$WORK/ct.err")"

if [ "$T_A1" = "refuted" ] && [ "$T_A2" = "refuted" ] && [ "$T_A3" = "refuted" ] && [ "$T_CT" = "1" ]; then
  ok "the three anchors each printed 'refuted' and the positive control printed '1' (the three-value dispatch contract)"
else
  bad "wrong dispatch tokens (anchors '$T_A1'/'$T_A2'/'$T_A3', control '$T_CT'; want refuted/refuted/refuted/1)"
  sed 's/^/      /' "$WORK/a1.err" "$WORK/a3.err" >&2
fi

if python3 - "$VJ" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
# verified[]: ONLY the positive control survived.
vlocs = [v["location"] for v in d.get("verified", [])]
assert vlocs == ["contracts/LendingPool.sol:redeem"], "verified[] is not exactly the control: %r" % vlocs
assert d["totals"]["verified"] == 1, "totals.verified != 1: %r" % d["totals"]["verified"]
ctl = d["verified"][0]
assert ctl["source"] == "invariant-hunt" and ctl["verdict"] == "FINDING", "control entry mis-shaped: %r" % ctl
assert "refute_gate" not in ctl, "a cleanly-verified survivor must NOT be tagged unassessed: %r" % ctl
# refuted[]: exactly the three anchors, each with a non-empty reason and the REFUTED verdict.
r = d.get("refuted", [])
assert d["totals"]["refuted"] == 3, "totals.refuted != 3: %r" % d["totals"].get("refuted")
assert len(r) == 3, "refuted[] len != 3: %d" % len(r)
rlocs = sorted(e["location"] for e in r)
assert rlocs == [
    "contracts/utils/RebalancingLib.sol:openAuction",
    "pkg/vault/contracts/Vault.sol:settle",
    "pkg/vault/contracts/VaultHooks.sol:onAfterSwap",
], "refuted[] holds the wrong findings: %r" % rlocs
for e in r:
    assert e["refute_verdict"] == "REFUTED", "a refuted entry is not marked REFUTED: %r" % e
    assert e["source"] == "invariant-hunt", "a refuted entry lost its source tag: %r" % e
    assert e["refute_reason"].strip(), "a refuted entry has a blank refute_reason: %r" % e
    assert e["severity"] == "High", "a refuted entry lost its severity: %r" % e
# the reserve RebalancingLib anchor carries the specific (both-axes) reason.
reb = [e for e in r if "RebalancingLib" in e["location"]][0]
assert "cumulative cap" in reb["refute_reason"] and "AUCTION_LAUNCHER" in reb["refute_reason"], \
    "the RebalancingLib anchor lost its reason: %r" % reb["refute_reason"]
# no anchor leaked into verified[]; the control did not leak into refuted[].
allv = " ".join(vlocs)
assert "RebalancingLib" not in allv and "Vault" not in allv, "an anchor leaked into verified[]: %r" % vlocs
assert not any("LendingPool" in e["location"] for e in r), "the control leaked into refuted[]"
PY
then ok "verified[] holds ONLY the control (totals.verified=1), refuted[] holds the 3 anchors with reasons (totals.refuted=3), and no bucket leaked"
else bad "the gate-ON aggregation is wrong"
fi

# ==========================================================================================================
# (2) BYTE-IDENTITY: --no-refute reproduces the raw pre-#1938 merge, matched against the reference AND the golden.
# ==========================================================================================================
note "2) --no-refute reproduces the raw pre-#1938 merge byte-for-byte ..."
VJ_RAW="$WORK/raw-merge.json"   # starts non-existent -> the adapter's data={} path, four appends in fixed order
gate_call "$DZ_A1" "contracts/utils/RebalancingLib.sol" "C6" "$VJ_RAW" --no-refute >/dev/null 2>&1
gate_call "$DZ_A2" "pkg/vault/contracts/Vault.sol" "C6" "$VJ_RAW" --no-refute >/dev/null 2>&1
gate_call "$DZ_A3" "pkg/vault/contracts/VaultHooks.sol" "SYS-solvency" "$VJ_RAW" --no-refute >/dev/null 2>&1
gate_call "$DZ_CT" "contracts/LendingPool.sol" "C6" "$VJ_RAW" --no-refute >/dev/null 2>&1

# The reference: a faithful copy of the PRE-#1938 STAGE 4.5 inline merge adapter, run over the same four logs
# in the same order. If deep-hunt-gate.sh's --no-refute path drifts from the original bytes, this fails.
VJ_REF="$WORK/raw-merge.reference.json"
python3 - "$VJ_REF" "$DZ_A1" "contracts/utils/RebalancingLib.sol" "C6" \
                    "$DZ_A2" "pkg/vault/contracts/Vault.sol" "C6" \
                    "$DZ_A3" "pkg/vault/contracts/VaultHooks.sol" "SYS-solvency" \
                    "$DZ_CT" "contracts/LendingPool.sol" "C6" <<'PY'
import sys, os, json, glob, re
out = sys.argv[1]
rows = sys.argv[2:]
def merge(verified_json, dzout, relfile, dclass):
    logs = sorted(glob.glob(os.path.join(dzout, "run", "invariant_*.log")))
    logs = [p for p in logs if not re.search(r"_c[0-9]+\.log$", os.path.basename(p))]
    if not logs:
        return
    verdict = None; inv_target = ""; steps = []
    with open(logs[-1], encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            if "INVARIANT|" in line:
                cols = line.split("INVARIANT|", 1)[1].strip().split("|")
                inv_target = cols[0].strip()
                if len(cols) >= 2:
                    verdict = cols[1].strip()
            if line.startswith("STEP|"):
                steps.append(line[len("STEP|"):].rstrip("\n"))
    if verdict != "FINDING":
        return
    fn = ""
    for s in steps:
        m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*\(", s)
        if m:
            fn = m.group(1); break
    if not fn:
        fn = os.path.splitext(os.path.basename(relfile))[0]
    steps_joined = " ; ".join(steps)
    broken = "stateful invariant broken on " + (inv_target or relfile)
    entry = {
        "location": "%s:%s" % (relfile, fn),
        "file": relfile,
        "class": dclass,
        "severity": "High",
        "exploit": (broken + " | " + steps_joined) if steps_joined else broken,
        "poc_sketch": steps_joined,
        "verdict": "FINDING",
        "reason": "stateful-invariant fuzzer reproduced a shrunk exploit sequence",
        "source": "invariant-hunt",
    }
    try:
        data = json.load(open(verified_json, encoding="utf-8"))
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}
    data.setdefault("verified", []).append(entry)
    totals = data.setdefault("totals", {})
    totals["verified"] = int(totals.get("verified", 0)) + 1
    with open(verified_json, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
for i in range(0, len(rows), 3):
    merge(out, rows[i], rows[i + 1], rows[i + 2])
PY

if cmp -s "$VJ_RAW" "$VJ_REF"; then
  ok "deep-hunt-gate.sh --no-refute is BYTE-IDENTICAL to a faithful re-implementation of the pre-#1938 inline merge adapter"
else
  bad "the --no-refute merge DRIFTED from the pre-#1938 adapter bytes:"
  diff "$VJ_REF" "$VJ_RAW" | sed 's/^/      /' >&2
fi

# Regenerate the checked-in golden on demand (GENERATE_GOLDEN=1), else assert byte-identity against it.
if [ "${GENERATE_GOLDEN:-0}" = "1" ]; then
  mkdir -p "$(dirname "$GOLDEN")"
  cp "$VJ_RAW" "$GOLDEN"
  note "GENERATE_GOLDEN=1 -> rewrote $GOLDEN"
fi
if [ -f "$GOLDEN" ]; then
  if cmp -s "$VJ_RAW" "$GOLDEN"; then
    ok "deep-hunt-gate.sh --no-refute matches the checked-in golden fixtures/deep-hunt/raw-merge.golden.json byte-for-byte"
  else
    bad "the --no-refute merge no longer matches the checked-in golden (regenerate with GENERATE_GOLDEN=1 if the shape legitimately changed):"
    diff "$GOLDEN" "$VJ_RAW" | sed 's/^/      /' >&2
  fi
else
  bad "the checked-in golden $GOLDEN is missing (run once with GENERATE_GOLDEN=1)"
fi

# ==========================================================================================================
# (3) NO-OP: a CLEAN (non-FINDING) invariant log prints `0` and writes nothing.
# ==========================================================================================================
note "3) a CLEAN (non-FINDING) log is a no-op ..."
VJ_CLEAN="$WORK/clean.json"
printf '{"verified": [], "totals": {"verified": 0}}\n' > "$VJ_CLEAN"
cp "$VJ_CLEAN" "$WORK/clean.orig"
T_CLEAN="$(gate_call "$DZ_CLEAN" "contracts/Foo.sol" "C6" "$VJ_CLEAN" 2>/dev/null)"
if [ "$T_CLEAN" = "0" ] && cmp -s "$VJ_CLEAN" "$WORK/clean.orig"; then
  ok "a CLEAN log prints '0' and leaves verified_findings.json byte-unchanged (the pre-existing no-op path)"
else
  bad "a CLEAN log was not a clean no-op (token '$T_CLEAN')"
fi

# ==========================================================================================================
# (4) FAIL-OPEN: a gate that yields no verdict tags the finding refute_gate=unassessed rather than deleting it.
# ==========================================================================================================
note "4) fail-open: a no-verdict gate error keeps the finding, tagged unassessed ..."
VJ_FO="$WORK/failopen.json"
printf '{"verified": [], "totals": {"verified": 0}}\n' > "$VJ_FO"
T_FO="$(STUB_SILENT=1 gate_call "$DZ_A1" "contracts/utils/RebalancingLib.sol" "C6" "$VJ_FO" 2>"$WORK/fo.err")"
if [ "$T_FO" = "1" ] && python3 - "$VJ_FO" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["totals"]["verified"] == 1, "the fail-open finding was not kept: %r" % d["totals"].get("verified")
assert d.get("refuted") in (None, []), "a gate ERROR must not be recorded as REFUTED"
v = d["verified"][0]
assert v.get("refute_gate") == "unassessed", "the fail-open entry is not tagged unassessed: %r" % v
assert "RebalancingLib" in v["location"], "wrong finding kept"
PY
then ok "a no-verdict gate error keeps the fuzzer-witnessed finding in verified[] tagged refute_gate=unassessed (never silently destroyed, never mis-filed as refuted)"
else bad "the fail-open path is wrong (token '$T_FO')"
fi
if grep -q 'FAIL-OPEN' "$WORK/fo.err"; then
  ok "deep-hunt-gate.sh logs the fail-open loudly to stderr (visible to the operator)"
else
  bad "no loud FAIL-OPEN log for the gate error"
fi

# ==========================================================================================================
# (5) READ-ONLY / NEVER-SUBMIT posture.
# ==========================================================================================================
note "5) read-only / never-submit posture ..."
if grep -vE '^[[:space:]]*#' "$GATE" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "deep-hunt-gate.sh invokes a network / submission verb on an executable line"
else
  ok "deep-hunt-gate.sh has no network / no submission verb on any executable line (read-only, never submits)"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — STAGE 4.5 refute gate (deep-hunt-gate.sh: invariant-mode refuter -> verified[]/refuted[], byte-identical --no-refute) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
