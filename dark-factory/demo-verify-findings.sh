#!/usr/bin/env bash
# demo-verify-findings.sh — OFFLINE, DETERMINISTIC proof of M4 verify integration (#1630, epic #1611):
# verify-findings.sh drives the refute gate over EVERY candidate in an M3 discovery-results.json and aggregates
# the CONFIRMED-only survivors into verified_findings.json. Every gate call is driven by a FAST offline stub
# wired through the EXISTING run-refute.sh --agentis seam (NO live agentis / forge / network).
#
# Assertions:
#   1) verified_findings.json is valid JSON carrying the seam-3 schema keys (repo, gate, verified[], totals).
#   2) CONFIRMED-only: exactly the candidates that survive the refute stub are kept. Includes a DECORATED-but-
#      resolvable candidate (`file@func:line`, #1691) — proven NORMALIZED (its `file` field is the bare path)
#      and ASSESSED, not silently dropped as if refuted (pins the yearn-ybold fix). Also pins the #1699 C6
#      fallback: a candidate REFUTED under its assigned class whose code trips the compound-AND accounting
#      signal is retried ONCE under C6 and recovered — recorded under the class it SURVIVED (C6), not the
#      mislabelled input — while a REFUTED candidate WITHOUT the signal stays dropped (signal-gated, not blanket).
#   3) READ-ONLY: discovery-results.json is byte-for-byte UNCHANGED after the run (verify never mutates M3 output).
#   4) ERRORED (#1691): a candidate the gate cannot evaluate — an ABSENT code file, or a TRUNCATED record with
#      blank class/severity (`file:fn:~(test/...`, pins the crestal fix) — lands in totals.errored / errors[],
#      is ABSENT from verified[], and is never conflated with a rigorous REFUTED verdict. The run still exits 0
#      and the healthy candidates are still verified. Bookkeeping: candidates == verified + errored + refuted.
#   5) READ-ONLY / NEVER-SUBMIT: no network / no submission verb on verify-findings.sh's executable lines.
#
# Usage:  dark-factory/demo-verify-findings.sh
# Requires: python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', no process substitution, literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/verify-findings.sh"

FAILS=0
note() { echo "demo-verify-findings.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$VERIFY" ] || { note "verify-findings.sh not found / not executable: $VERIFY" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-verify-findings.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# (a) A throwaway target repo holding the code files most candidates reference. One candidate references a file
#     NOT in the repo (the absent-code errored path); one references a DECORATED `file@func:line` location whose
#     BARE file DOES exist (proves normalization resolves + assesses it); one is a TRUNCATED record whose bare
#     file exists but whose class/severity are blank (proves it errors on the malformed signal, not a bad path).
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target"
mkdir -p "$REPO/contracts" "$REPO/src"
printf 'contract Vault { function deposit() public {} }\n'   > "$REPO/contracts/Vault.sol"
printf 'contract Oracle { function price() public {} }\n'    > "$REPO/contracts/Oracle.sol"
printf 'contract Token { function transfer() public {} }\n'  > "$REPO/contracts/Token.sol"
printf 'contract Strategy { function aprAfterDebtChange() public {} }\n' > "$REPO/contracts/Strategy.sol"
# #1699 C6-fallback fixture: a value-moving function DECLARATION (`function swap`) AND an amount-deduction
# idiom (`-=`) — trips run-refute.sh's compound-AND accounting signal, so a candidate REFUTED under its
# assigned class is retried under C6 (the stub returns REAL for C6) and recovered.
printf 'contract Gateway { function swap(uint256 amount) public { amount -= fee; } }\n' > "$REPO/contracts/Gateway.sol"
printf 'contract BlueprintV3 { function createPrivateDeploymentRequestWithSig() public {} }\n' > "$REPO/src/BlueprintV3.sol"

# ----------------------------------------------------------------------------------------------------------
# (b) The fast offline refute stub through the --agentis seam. run-refute.sh env-ins CAND_CLASS; the stub
#     returns REFUTED for the C-refuted sentinel class and REAL for everything else. NO live agentis / network.
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
    case "$cls" in
      *refuted*|*REFUTED*) echo "VERDICT|REFUTED|$fn|$cls|a hostile read killed it" ;;
      *)                   echo "VERDICT|REAL|$fn|$cls|survived a hostile read" ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

# ----------------------------------------------------------------------------------------------------------
# (c) The inline M3 discovery-results.json: 7 candidates — 3 the stub confirms REAL directly (incl. one
#     DECORATED `file@func:line`, #1691), 1 REFUTED under its assigned class but RECOVERED under the #1699 C6
#     fallback (its code trips the compound-AND accounting signal), 1 REFUTED with NO signal so it stays dropped
#     (the negative control that proves the retry is signal-gated, not blanket), 1 whose code file is ABSENT from
#     the repo (errored), and 1 TRUNCATED record with blank class/severity + a `:~(test/...` tail (errored).
#     Built via python3 (the JSON convention). The decorated + truncated locations are the two real shapes
#     reproduced in the #1691 report; the Gateway swap candidate reproduces the #1699 dodo GatewayCrossChain case.
# ----------------------------------------------------------------------------------------------------------
RES="$WORK/discovery-results.json"
python3 - > "$RES" <<'PY'
import json
data = {
    "repo": "target", "backend": "mock", "jobs": 1,
    "cells": [
        {"subsystem": "vault deposits", "class": "C1",
         "files": "contracts/Vault.sol",
         "candidates": ["contracts/Vault.sol:deposit:12|C1|High|external depositor mints free shares|donate an asset to inflate the share price"],
         "coordination": []},
        {"subsystem": "price oracle", "class": "C2",
         "files": "contracts/Oracle.sol",
         "candidates": ["contracts/Oracle.sol:price:20|C2|Medium|a stale round is accepted on the withdraw path|push a stale price then withdraw"],
         "coordination": []},
        {"subsystem": "strategy apr", "class": "C15",
         "files": "contracts/Strategy.sol",
         "candidates": ["contracts/Strategy.sol@aprAfterDebtChange:107-116|C15|High|an external attacker with no relation forces a debt change|deploy the strategy then call aprAfterDebtChange"],
         "coordination": []},
        {"subsystem": "token", "class": "C-refuted",
         "files": "contracts/Token.sol",
         "candidates": ["contracts/Token.sol:transfer:5|C-refuted|Low|transfer lacks an owner check|anyone moves funds"],
         "coordination": []},
        {"subsystem": "gateway swap", "class": "C-refuted",
         "files": "contracts/Gateway.sol",
         "candidates": ["contracts/Gateway.sol:onCall|C-refuted|High|misclassified accounting bug in a value-moving swap|short-deduct the fee before the swap"],
         "coordination": []},
        {"subsystem": "ghost", "class": "C9",
         "files": "contracts/Missing.sol",
         "candidates": ["contracts/Missing.sol:ghost:1|C9|Medium|references a file absent from the repo|the gate cannot evaluate it"],
         "coordination": []},
        {"subsystem": "blueprint deploy", "class": "C4",
         "files": "src/BlueprintV3.sol",
         "candidates": ["src/BlueprintV3.sol:createPrivateDeploymentRequestWithSig:~(test/BlueprintV3.t.sol:test_createPrivateDeploym||||"],
         "coordination": []},
    ],
    "totals": {"cells": 7, "candidates": 7, "steers": 0},
}
print(json.dumps(data, indent=2))
PY
cp "$RES" "$WORK/results.orig"   # byte-exact snapshot for the read-only assertion

# ----------------------------------------------------------------------------------------------------------
# Run verify-findings.sh over the merged candidates.
# ----------------------------------------------------------------------------------------------------------
OUT="$WORK/out"
note "running verify-findings.sh --gate refute over 7 candidates (offline stub) ..."
"$VERIFY" --results "$RES" --repo "$REPO" --out "$OUT" --gate refute --backend mock --agentis "$STUB" \
  >"$WORK/verify.out" 2>"$WORK/verify.err"
RC=$?
[ "$RC" -eq 0 ] && ok "verify-findings.sh exits 0 (even with a REFUTED + two errored candidates present)" \
  || { bad "verify-findings.sh exited $RC"; sed 's/^/      /' "$WORK/verify.err" >&2; }
VJ="$OUT/verified_findings.json"
[ -f "$VJ" ] && ok "emitted verified_findings.json" || bad "verified_findings.json not emitted"

# ----------------------------------------------------------------------------------------------------------
# (1) schema keys + (2) CONFIRMED-only aggregation.
# ----------------------------------------------------------------------------------------------------------
note "1)+2) schema + CONFIRMED-only aggregation (incl. #1691 decorated-location normalization) ..."
if python3 - "$VJ" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(d.keys()) >= {"repo", "gate", "verified", "totals"}, "top-level keys missing: %r" % list(d.keys())
assert d["gate"] == "refute", "gate != refute: %r" % d["gate"]
assert d["repo"] == "target", "repo != target: %r" % d["repo"]
assert isinstance(d["verified"], list), "verified is not a list"
assert set(d["totals"].keys()) >= {"candidates", "verified"}, "totals keys missing"
assert d["totals"]["candidates"] == 7, "candidates total != 7: %r" % d["totals"]["candidates"]
assert d["totals"]["verified"] == 4, "verified total != 4: %r" % d["totals"]["verified"]
assert len(d["verified"]) == 4, "verified list len != 4: %d" % len(d["verified"])
keys = {"subsystem", "location", "file", "class", "severity", "exploit", "poc_sketch", "verdict", "reason"}
for v in d["verified"]:
    assert set(v.keys()) == keys, "verified entry keys %r != %r" % (set(v.keys()), keys)
    assert v["verdict"] == "REAL", "a kept finding is not REAL: %r" % v["verdict"]
locs = sorted(v["location"] for v in d["verified"])
assert locs == [
    "contracts/Gateway.sol:onCall",
    "contracts/Oracle.sol:price:20",
    "contracts/Strategy.sol@aprAfterDebtChange:107-116",
    "contracts/Vault.sol:deposit:12",
], "kept the wrong findings: %r" % locs
# both errored candidates, and the SIGNAL-LESS refuted candidate (Token), must be absent from verified[]
alll = " ".join(v["location"] for v in d["verified"])
assert "Token.sol" not in alll, "the signal-less REFUTED candidate was not dropped (retry is not signal-gated)"
assert "Missing.sol" not in alll, "the absent-code (errored) candidate leaked into verified[]"
assert "BlueprintV3" not in alll, "the truncated (errored) candidate leaked into verified[]"
# #1699: the Gateway candidate was REFUTED under its assigned class (C-refuted) but its code trips the C6
# compound-AND signal, so run-refute.sh's single C6 retry recovered it — and it is recorded under the class it
# SURVIVED (C6), not the mislabelled input class. Token has no value-moving decl / no `-=`, so it stays dropped.
gw = {v["location"]: v for v in d["verified"]}["contracts/Gateway.sol:onCall"]
assert gw["class"] == "C6", "recovered candidate not recorded under the surviving class C6: %r" % gw["class"]
assert gw["file"] == "contracts/Gateway.sol", "recovered candidate code file mis-derived: %r" % gw["file"]
# the derived code file is the BARE path before the first colon of an already-well-formed location (no-op)
byloc = {v["location"]: v for v in d["verified"]}
assert byloc["contracts/Vault.sol:deposit:12"]["file"] == "contracts/Vault.sol", "code file mis-derived"
assert byloc["contracts/Vault.sol:deposit:12"]["class"] == "C1", "class mis-parsed"
assert byloc["contracts/Vault.sol:deposit:12"]["severity"] == "High", "severity mis-parsed"
# #1691 (yearn-ybold): a DECORATED `file@func:line` location normalizes to the bare path, resolves, and is
# ASSESSED (REAL) instead of silently dropped — and its human-facing `location` keeps the decoration intact.
dec = byloc["contracts/Strategy.sol@aprAfterDebtChange:107-116"]
assert dec["file"] == "contracts/Strategy.sol", "decorated location not normalized to bare file: %r" % dec["file"]
assert dec["class"] == "C15", "decorated candidate class mis-parsed: %r" % dec["class"]
assert dec["verdict"] == "REAL", "decorated candidate was not assessed: %r" % dec["verdict"]
PY
then ok "verified_findings.json carries the schema keys AND only the 4 REAL findings (signal-less REFUTED Token + 2 errored excluded; #1691 decorated location normalized; #1699 Gateway recovered under C6)"
else bad "schema / CONFIRMED-only assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (3) READ-ONLY: discovery-results.json is byte-for-byte unchanged.
# ----------------------------------------------------------------------------------------------------------
note "3) read-only: discovery-results.json is byte-unchanged after the run ..."
if cmp -s "$RES" "$WORK/results.orig"; then
  ok "discovery-results.json is byte-for-byte identical after verify (verify never mutates M3 output)"
else
  bad "verify-findings.sh mutated discovery-results.json (read-only invariant broken)"
fi

# ----------------------------------------------------------------------------------------------------------
# (4) ERRORED (#1691): the absent-code AND the truncated candidates land in totals.errored / errors[], are
#     ABSENT from verified[], are NOT conflated with a rigorous REFUTED verdict, and the run still completes.
#     Bookkeeping: candidates == verified + errored + refuted (no candidate is double-counted or lost).
# ----------------------------------------------------------------------------------------------------------
note "4) errored: ungate-able (absent-code / truncated) candidates are LOUD and distinguishable, not silently dropped ..."
if python3 - "$VJ" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert "errors" in d and isinstance(d["errors"], list), "errors[] array missing"
assert "errored" in d["totals"], "totals.errored missing"
assert d["totals"]["errored"] == 2, "errored total != 2: %r" % d["totals"]["errored"]
assert len(d["errors"]) == 2, "errors[] len != 2: %d" % len(d["errors"])
for e in d["errors"]:
    assert set(e.keys()) == {"location", "file", "reason"}, "error entry keys %r" % set(e.keys())
    assert e["reason"], "an errored candidate has a blank reason"
errlocs = " ".join(e["location"] for e in d["errors"])
assert "Missing.sol" in errlocs, "the absent-code candidate is not in errors[]"
assert "BlueprintV3" in errlocs, "the truncated candidate is not in errors[]"
# no errored candidate leaked into verified[] as a content-less REAL (the crestal failure mode)
vlocs = " ".join(v["location"] for v in d["verified"])
assert "Missing.sol" not in vlocs and "BlueprintV3" not in vlocs, "an errored candidate was tallied as verified"
# bookkeeping: candidates == verified + errored + refuted. refuted = the remainder that was neither.
cand = d["totals"]["candidates"]; ver = d["totals"]["verified"]; err = d["totals"]["errored"]
refuted = cand - ver - err
assert refuted == 1, "rigorous-refutation count (candidates - verified - errored) != 1: %d" % refuted
PY
then ok "both ungate-able candidates are in totals.errored (=2) / errors[], absent from verified[], never conflated with REFUTED (rigorous-refutation count = 1)"
else bad "errored contract / anti-conflation assertion failed"
fi
# the run log must also make the errored candidates visible (change 4 summary line)
if grep -q 'ERRORED' "$WORK/verify.err"; then
  ok "verify-findings.sh logged the ERRORED candidates in the run output (visible to the operator)"
else
  bad "no ERRORED status was logged for the ungate-able candidates"
fi

# ----------------------------------------------------------------------------------------------------------
# (5) READ-ONLY / NEVER-SUBMIT: no network or submission verb on verify-findings.sh's executable lines.
# ----------------------------------------------------------------------------------------------------------
note "5) read-only / never-submit posture ..."
if grep -vE '^[[:space:]]*#' "$VERIFY" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "verify-findings.sh invokes a network/submission verb on an executable line"
else
  ok "verify-findings.sh has no network / no submission verb on any executable line (read-only, never submits)"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — M4 verify integration (verify-findings.sh: refute gate -> CONFIRMED-only verified_findings.json) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
