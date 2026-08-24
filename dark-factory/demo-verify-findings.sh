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
#   9) #1887 CONSTRAINT AGGREGATION: the per-gate refute-constraints.tsv files are concatenated into one
#      <out>/refute-constraints.tsv in numeric GATE order, byte-identically under --jobs 1 and --jobs 3
#      (completion order must not reach a knowledge-corpus input), a REAL candidate contributes nothing, and
#      verified_findings.json is BYTE-IDENTICAL with and without the refuter's CONSTRAINT| lines.
#   10) #1962 --pay-floor: a Medium/Low candidate below --pay-floor high is dropped into dropped_subfloor[]
#      BEFORE the gate ever runs (no gate-cell side effect for it), a High candidate is gated normally, and a
#      blank/unrecognized-severity candidate is KEPT (fail-open — reaches the gate, never counted as dropped).
#      totals.dropped_subfloor == 2, top-level pay_floor == "high". The SAME discovery-results.json WITHOUT
#      --pay-floor flows every candidate through unchanged (default inertness): dropped_subfloor is empty,
#      totals.dropped_subfloor == 0, and the pre-existing totals stay exactly what assertion (1) already pins.
#   11) #1965: a BLANK-LOCATION candidate (valid class + severity) is treated identically to the no-floor path
#      under --pay-floor high — it is left untouched by the partition and dies at the pre-existing gate-loop
#      skip uncounted, NEVER landing in dropped_subfloor[]. totals.candidates is identical with and without
#      --pay-floor, and the #1962 counting invariant (candidates == verified + errored + refuted +
#      dropped_subfloor) holds in both runs.
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
    # #1707: optional TUI-chrome injection — emit chrome (NO VERDICT| sentinel) for the first
    # STUB_CHROME_ATTEMPTS attempts of each candidate (keyed by file:fn via STUB_CHROME_CTR), so the demo can
    # prove run-refute.sh RETRIES past chrome and, when it never clears, marks the candidate ERRORED
    # (UNASSESSED) rather than silently REFUTED. Unset STUB_CHROME_CTR leaves the main run untouched.
    if [ -n "${STUB_CHROME_CTR:-}" ]; then
      ckey="$(printf '%s' "$fn" | tr -cs 'A-Za-z0-9' '_')"
      cf="$STUB_CHROME_CTR/$ckey"
      cn=0; [ -f "$cf" ] && cn="$(cat "$cf")"
      cn=$((cn + 1)); printf '%s' "$cn" > "$cf"
      if [ "$cn" -le "${STUB_CHROME_ATTEMPTS:-0}" ]; then
        printf 'high · /effort\n'
        printf 'esc to interrupt\n'
        exit 0
      fi
    fi
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
# (6) #1707 INHERITED REFUTE VALIDATION: verify-findings.sh has no `agentis go` of its own — it dispatches to
#     run-refute.sh, which now validates the refuter reply carries a VERDICT| line and RETRIES on TUI chrome.
#     (a) chrome-then-VERDICT| ⇒ the refuter is retried and the REAL verdict is captured (verified, not
#     dropped); (b) chrome-on-ALL ⇒ the candidate surfaces as ERRORED-UNASSESSED (visible + distinguishable),
#     NOT silently REFUTED/dropped — the whole bug this closes.
# ----------------------------------------------------------------------------------------------------------
# A one-candidate results.json referencing a code file that exists in $REPO and a class that is NOT refuted.
CHROME_RES="$WORK/chrome-results.json"
python3 - > "$CHROME_RES" <<'PY'
import json
data = {
    "repo": "target", "backend": "mock", "jobs": 1,
    "cells": [
        {"subsystem": "vault deposits", "class": "C1",
         "files": "contracts/Vault.sol",
         "candidates": ["contracts/Vault.sol:deposit:12|C1|High|external depositor mints free shares|donate an asset to inflate the share price"],
         "coordination": []},
    ],
    "totals": {"cells": 1, "candidates": 1, "steers": 0},
}
print(json.dumps(data, indent=2))
PY

note "6a) #1707: chrome-then-VERDICT| ⇒ run-refute.sh is retried and the REAL verdict is captured ..."
CHROME_OK_OUT="$WORK/out-chrome-ok"
STUB_CHROME_CTR="$WORK/ctr-vf-ok"; mkdir -p "$STUB_CHROME_CTR"
DF_AGENT_MAX_ATTEMPTS=2 STUB_CHROME_CTR="$STUB_CHROME_CTR" STUB_CHROME_ATTEMPTS=1 \
  "$VERIFY" --results "$CHROME_RES" --repo "$REPO" --out "$CHROME_OK_OUT" --gate refute --backend mock --agentis "$STUB" \
  >"$WORK/vf-chrome-ok.out" 2>"$WORK/vf-chrome-ok.err"
RC=$?
[ "$RC" -eq 0 ] && ok "verify-findings.sh exits 0 with a chrome-then-VERDICT| candidate" \
  || { bad "chrome-then-VERDICT| verify run exited $RC"; sed 's/^/      /' "$WORK/vf-chrome-ok.err" >&2; }
if python3 - "$CHROME_OK_OUT/verified_findings.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["totals"]["verified"] == 1, "chrome-then-VERDICT| candidate not verified: %r" % d["totals"]["verified"]
assert d["totals"].get("errored", 0) == 0, "chrome-then-VERDICT| candidate wrongly errored: %r" % d["totals"].get("errored")
assert len(d["verified"]) == 1 and d["verified"][0]["verdict"] == "REAL", "the retried candidate was not captured as REAL"
assert "Vault.sol" in d["verified"][0]["location"], "wrong candidate captured"
PY
then ok "the refuter was retried past chrome and the REAL verdict captured (verified == 1, errored == 0) — no chrome false-negative"
else bad "chrome-then-VERDICT| candidate was not verified (retry did not recover the verdict)"
fi

note "6b) #1707: chrome-on-ALL ⇒ the candidate surfaces as ERRORED-UNASSESSED, NOT silently REFUTED/dropped ..."
CHROME_FAIL_OUT="$WORK/out-chrome-fail"
STUB_CHROME_CTR="$WORK/ctr-vf-fail"; mkdir -p "$STUB_CHROME_CTR"
DF_AGENT_MAX_ATTEMPTS=2 STUB_CHROME_CTR="$STUB_CHROME_CTR" STUB_CHROME_ATTEMPTS=99 \
  "$VERIFY" --results "$CHROME_RES" --repo "$REPO" --out "$CHROME_FAIL_OUT" --gate refute --backend mock --agentis "$STUB" \
  >"$WORK/vf-chrome-fail.out" 2>"$WORK/vf-chrome-fail.err"
RC=$?
[ "$RC" -eq 0 ] && ok "verify-findings.sh still exits 0 with a chrome-on-all candidate" \
  || { bad "chrome-on-all verify run exited $RC"; sed 's/^/      /' "$WORK/vf-chrome-fail.err" >&2; }
if python3 - "$CHROME_FAIL_OUT/verified_findings.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["totals"]["verified"] == 0, "a chrome-on-all candidate was wrongly verified: %r" % d["totals"]["verified"]
assert d["totals"].get("errored", 0) == 1, "chrome-on-all candidate not errored: %r" % d["totals"].get("errored")
assert len(d["verified"]) == 0, "verified[] is not empty"
errlocs = " ".join(e["location"] for e in d.get("errors", []))
assert "Vault.sol" in errlocs, "the chrome-on-all candidate is not in errors[] (silently dropped?)"
# it must NOT be a rigorous REFUTED: candidates - verified - errored == 0 (no candidate silently refuted)
cand = d["totals"]["candidates"]; ver = d["totals"]["verified"]; err = d["totals"]["errored"]
assert cand - ver - err == 0, "a chrome-on-all candidate was silently REFUTED (rigorous-refutation count != 0)"
PY
then ok "the chrome-on-all candidate is ERRORED-UNASSESSED (errored == 1, in errors[], NOT verified, NOT silently refuted)"
else bad "chrome-on-all candidate mis-handled (verified, dropped, or silently refuted instead of errored)"
fi

# ----------------------------------------------------------------------------------------------------------
# (7) #1861 IMPLEMENTATION APPENDIX + the verdict-reason truncation fix. The refute gate stages exactly ONE
#     file, so a candidate anchored in an `abstract contract` was judged with no implementation of it in view
#     and died on "…in this contract contains no…" — 21 of 22 candidates on the diagnosing target's
#     abstract-base zone, against 14 of 22 confirmed on a concrete-contract zone of the same target in the
#     same run. verify-findings.sh now resolves ONE representative implementor via lib/inheritance.py, slices
#     it with auditor/slice-fns.sh and hands it to run-refute.sh as an OPTIONAL 6th manifest column, which
#     stages it and env-ins AUX_CODE_PATH for refuter.ag.
#
#     SELF-CONTAINED: its own throwaway repo, its own stub, its own results.json — the fixtures above are
#     untouched. The stub records (candidate, class, AUX_CODE_PATH) per call, so the assertions read the env
#     the .ag actually received rather than inferring it from a verdict.
# ----------------------------------------------------------------------------------------------------------
REFUTE="$HERE/run-refute.sh"
INH_HELPER="$HERE/lib/inheritance.py"
REFUTER_AG="$HERE/auditor/agents/refuter.ag"

note "7) #1861: source guards — the appendix cannot be silently inert ..."
if grep -q 'AUX_CODE_PATH' "$REFUTER_AG" && grep -q 'AUX-CONTEXT|' "$REFUTER_AG" \
   && grep -q 'exec.env_passthrough = .*AUX_CODE_PATH' "$REFUTE"; then
  ok "refuter.ag reads AUX_CODE_PATH and prints the AUX-CONTEXT| marker, AND run-refute.sh registers AUX_CODE_PATH on exec.env_passthrough (getenv() reads the SANITIZED env — an unregistered knob is staged, never read, and the whole feature is silently inert)"
else
  bad "the AUX_CODE_PATH wiring is incomplete (refuter.ag getenv / AUX-CONTEXT| marker / run-refute.sh exec.env_passthrough)"
fi
[ -f "$INH_HELPER" ] && ok "lib/inheritance.py ships next to the gate" || bad "lib/inheritance.py is missing"

IREPO="$WORK/target-inheritance"
mkdir -p "$IREPO/base" "$IREPO/staking" "$IREPO/gw" "$IREPO/gwimpl" "$IREPO/deny" "$IREPO/denyimpl" \
         "$IREPO/plain" "$IREPO/wrap" "$IREPO/pipe"
cat > "$IREPO/base/AbstractYield.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract AbstractYield {
    function _initiateWithdraw(uint256 shares) internal virtual returns (uint256);
    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        return shares;
    }
}
SOL
cat > "$IREPO/staking/StakingStrategy.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract StakingStrategy is AbstractYield {
    function _initiateWithdraw(uint256 shares) internal override returns (uint256) {
        // DERIVED_OVERRIDE_SENTINEL - the unguarded path the abstract file does not contain
        return shares;
    }
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return shares * 2;
    }
}
SOL
# B3 fixture: an abstract base that ALSO trips run-refute.sh's #1699 compound-AND accounting signal (a
# value-moving `function withdraw` declaration AND a `-=` deduction), so the C6 fallback re-run fires.
cat > "$IREPO/gw/AbstractGateway.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract AbstractGateway {
    uint256 public total;

    function withdraw(uint256 amount) external virtual;

    function _settle(uint256 amount) internal {
        total -= amount;
    }
}
SOL
cat > "$IREPO/gwimpl/GatewayImpl.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract GatewayImpl is AbstractGateway {
    function withdraw(uint256 amount) external override {
        total -= amount;
    }
}
SOL
# B4 fixture: an abstract base with an implementor but NO accounting signal, so a REFUTED verdict is final.
cat > "$IREPO/deny/AbstractDeny.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract AbstractDeny {
    function pullFunds(uint256 amount) internal virtual returns (uint256);
}
SOL
cat > "$IREPO/denyimpl/DenyImpl.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract DenyImpl is AbstractDeny {
    function pullFunds(uint256 amount) internal override returns (uint256) {
        return amount;
    }
}
SOL
printf 'contract Plain { function doThing(uint256 a) external returns (uint256) { return a; } }\n' > "$IREPO/plain/Plain.sol"
printf 'contract Wrap { function wrapped(uint256 a) external returns (uint256) { return a; } }\n'  > "$IREPO/wrap/Wrap.sol"
printf 'contract Pipe { function piped(uint256 a) external returns (uint256) { return a; } }\n'    > "$IREPO/pipe/Pipe.sol"

# The stub: logs (candidate, class, AUX_CODE_PATH) per call, and confirms the abstract-base candidate ONLY
# when the appendix is actually readable and carries the derived override.
ISTUB="$WORK/agentis-stub-inheritance"
cat > "$ISTUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    fn="${CAND_FILE_FN:-}"
    cls="${CAND_CLASS:-}"
    aux="${AUX_CODE_PATH:-}"
    if [ -n "${STUB_ENV_LOG:-}" ]; then
      printf '%s\t%s\t%s\n' "$fn" "$cls" "$aux" >> "$STUB_ENV_LOG"
    fi
    case "$fn" in
      *AbstractYield.sol*)
        if [ -n "$aux" ] && [ -r "$aux" ] && grep -q 'DERIVED_OVERRIDE_SENTINEL' "$aux"; then
          echo "VERDICT|REAL|$fn|$cls|the derived override makes the claimed path reachable"
        else
          echo "VERDICT|REFUTED|$fn|$cls|this contract contains no implementation of the function the claim needs"
        fi
        exit 0 ;;
      *Wrap.sol*)
        echo "VERDICT|REAL|$fn|$cls|the derived override performs the"
        echo "    transfer before the accounting update, so an"
        echo "    unprivileged caller drains it TAILWORDSENTINEL"
        exit 0 ;;
      *Pipe.sol*)
        echo "VERDICT|REAL|$fn|$cls|liquidate() | then redeem() drains the pool PIPETAILSENTINEL"
        exit 0 ;;
    esac
    case "$cls" in
      *refuted*|*REFUTED*) echo "VERDICT|REFUTED|$fn|$cls|a hostile read killed it" ;;
      C6)                  echo "VERDICT|REAL|$fn|$cls|recovered under the accounting lens" ;;
      *)                   echo "VERDICT|REAL|$fn|$cls|survived a hostile read" ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$ISTUB"

IRES="$WORK/inheritance-results.json"
python3 - > "$IRES" <<'PY'
import json


def cell(sub, cls, f, loc, expl):
    return {"subsystem": sub, "class": cls, "files": f,
            "candidates": ["%s|%s|High|%s|sketch" % (loc, cls, expl)], "coordination": []}


data = {
    "repo": "target-inheritance", "backend": "mock", "jobs": 1,
    "cells": [
        cell("yield base", "C1", "base/AbstractYield.sol", "base/AbstractYield.sol:_initiateWithdraw:5",
             "the withdraw path never checks the queue"),
        cell("plain", "C1", "plain/Plain.sol", "plain/Plain.sol:doThing:1", "a plain concrete contract"),
        cell("gateway", "C-refuted", "gw/AbstractGateway.sol", "gw/AbstractGateway.sol:withdraw:7",
             "misclassified accounting bug in a value-moving withdraw"),
        cell("deny", "C-refuted", "deny/AbstractDeny.sol", "deny/AbstractDeny.sol:pullFunds:5",
             "an aux-carrying candidate the skeptic still kills"),
        cell("wrap", "C-wrap", "wrap/Wrap.sol", "wrap/Wrap.sol:wrapped:1", "a verdict whose reason wraps"),
        cell("pipe", "C-pipe", "pipe/Pipe.sol", "pipe/Pipe.sol:piped:1", "a verdict whose reason has a pipe"),
    ],
    "totals": {"cells": 6, "candidates": 6, "steers": 0},
}
print(json.dumps(data, indent=2))
PY
cp "$IRES" "$WORK/inheritance-results.orig"

IOUT="$WORK/out-inheritance"
IENV_LOG="$WORK/stub-env.tsv"; : > "$IENV_LOG"
note "7) running verify-findings.sh --gate refute over the 6 inheritance candidates (offline stub) ..."
STUB_ENV_LOG="$IENV_LOG" "$VERIFY" --results "$IRES" --repo "$IREPO" --out "$IOUT" --gate refute \
  --backend mock --agentis "$ISTUB" >"$WORK/inh-verify.out" 2>"$WORK/inh-verify.err"
RC=$?
[ "$RC" -eq 0 ] && ok "verify-findings.sh exits 0 over the inheritance candidate set" \
  || { bad "inheritance verify run exited $RC"; sed 's/^/      /' "$WORK/inh-verify.err" >&2; }

# --- B1: the abstract-base candidate reaches the stub with a readable AUX_CODE_PATH carrying the override.
if python3 - "$IENV_LOG" "$IOUT/verified_findings.json" <<'PY'
import sys, json, os
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
base = [r for r in rows if "AbstractYield.sol" in r[0]]
assert base, "the abstract-base candidate never reached the stub"
aux = base[0][2]
assert aux, "AUX_CODE_PATH was EMPTY for a candidate anchored in an abstract base"
assert os.path.isfile(aux), "AUX_CODE_PATH does not point at a staged file: %r" % aux
body = open(aux, encoding="utf-8").read()
assert "DERIVED_OVERRIDE_SENTINEL" in body, "the staged appendix does not carry the derived override: %r" % body[:200]
assert "_initiateWithdraw" in body, "the staged appendix is not sliced to the resolved member"
d = json.load(open(sys.argv[2], encoding="utf-8"))
locs = [v["location"] for v in d["verified"]]
assert any("AbstractYield.sol" in l for l in locs), \
    "the abstract-base candidate was NOT confirmed even though the appendix reached the gate: %r" % locs
PY
then ok "B1: a candidate anchored in an abstract base reaches the gate with a non-empty AUX_CODE_PATH pointing at a readable, function-sliced staged file carrying the derived override -- and is confirmed REAL only in that case"
else bad "B1: the implementation appendix did not reach the refute gate"
fi

# --- B2: a plain concrete candidate is byte-identically inert (empty env knob, 5-field manifest, no artifacts).
if python3 - "$IENV_LOG" "$IOUT" <<'PY'
import sys, os, glob
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
for marker in ("plain/Plain.sol", "wrap/Wrap.sol", "pipe/Pipe.sol"):
    hit = [r for r in rows if marker in r[0]]
    assert hit, "%s never reached the stub" % marker
    for r in hit:
        assert r[2] == "", "%s got a non-empty AUX_CODE_PATH: %r" % (marker, r[2])
cells = glob.glob(os.path.join(sys.argv[2], "gates", "*"))
plain = [c for c in cells if "Plain_sol" in os.path.basename(c)]
assert plain, "no gate cell for the plain candidate"
manifest = open(os.path.join(plain[0], "candidate.manifest"), encoding="utf-8").read()
golden = ("plain/Plain.sol:doThing:1|C1|High|a plain concrete contract|plain/Plain.sol\n")
assert manifest == golden, "the no-aux manifest is NOT byte-identical to the pre-#1861 shape:\n%r\nwant\n%r" % (manifest, golden)
assert not os.path.exists(os.path.join(plain[0], "aux.sol")), "an aux slice was written for a concrete candidate"
assert not os.path.exists(os.path.join(plain[0], "aux.txt")), "an aux record was written for a concrete candidate"
PY
then ok "B2: a candidate anchored in a plain concrete file gets an EMPTY AUX_CODE_PATH, a byte-identical 5-field candidate.manifest (golden-pinned) and no aux artifacts -- default inertness"
else bad "B2: the appendix fired on a target with no abstract base (or changed the no-aux manifest)"
fi

# --- B3: the #1699 C6 fallback re-run carries the SAME appendix (the easy miss).
if python3 - "$IENV_LOG" "$IOUT/verified_findings.json" <<'PY'
import sys, json
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
gw = [r for r in rows if "AbstractGateway.sol" in r[0]]
assert len(gw) == 2, "expected exactly 2 refuter calls for the gateway candidate (assigned + C6), got %d" % len(gw)
assert gw[0][1] == "C-refuted" and gw[1][1] == "C6", "the C6 fallback did not fire: %r" % gw
assert gw[0][2], "the FIRST attempt carried no appendix"
assert gw[1][2], "the C6 FALLBACK re-run carried NO appendix -- it judged a different payload than attempt 1"
assert gw[0][2] == gw[1][2], "the fallback re-run got a DIFFERENT appendix: %r vs %r" % (gw[0][2], gw[1][2])
d = json.load(open(sys.argv[2], encoding="utf-8"))
gwv = [v for v in d["verified"] if "AbstractGateway.sol" in v["location"]]
assert gwv and gwv[0]["class"] == "C6", "the recovered candidate is not recorded under C6: %r" % gwv
PY
then ok "B3: the #1699 C6 fallback re-run carries the same implementation appendix as the first attempt (both calls logged with an identical non-empty AUX_CODE_PATH), and the candidate is recorded under C6"
else bad "B3: the C6 fallback re-run lost the appendix"
fi

# --- B4: the appendix is NOT a rubber stamp — an aux-carrying candidate the stub refutes stays dropped.
if python3 - "$IENV_LOG" "$IOUT/verified_findings.json" <<'PY'
import sys, json
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
deny = [r for r in rows if "AbstractDeny.sol" in r[0]]
assert deny, "the deny candidate never reached the stub"
assert deny[0][2], "the deny candidate carried no appendix -- it is not a valid negative control"
assert len(deny) == 1, "the deny candidate must NOT trip the C6 fallback (no accounting signal): %r" % deny
d = json.load(open(sys.argv[2], encoding="utf-8"))
assert not any("AbstractDeny.sol" in v["location"] for v in d["verified"]), \
    "an aux-carrying candidate the gate REFUTED was kept -- the appendix became a rubber stamp"
assert not any("AbstractDeny.sol" in e["location"] for e in d.get("errors", [])), \
    "a refuted candidate was mis-filed as errored"
PY
then ok "B4: an aux-carrying candidate whose verdict is REFUTED stays dropped and out of verified[] -- the appendix informs the judgement, it does not rubber-stamp it"
else bad "B4: an aux-carrying REFUTED candidate leaked into verified[]"
fi

# --- B5: a PTY-wrapped verdict reason is rejoined whole into both verdict.txt and refute-report.md.
if python3 - "$IOUT" <<'PY'
import sys, os, glob
cells = glob.glob(os.path.join(sys.argv[1], "gates", "*Wrap_sol*"))
assert cells, "no gate cell for the wrapped-verdict candidate"
c = cells[0]
verdict = open(os.path.join(c, "verdict.txt"), encoding="utf-8").read()
assert "TAILWORDSENTINEL" in verdict, "verdict.txt lost the wrapped tail (grep | tail -1 truncation): %r" % verdict
report = open(os.path.join(c, "refute-out", "refute-report.md"), encoding="utf-8").read()
rows = [l for l in report.splitlines() if l.startswith("| ") and "REAL" in l]
assert rows, "no verdict row in refute-report.md"
assert "TAILWORDSENTINEL" in rows[0], "refute-report.md lost the wrapped tail: %r" % rows[0]
assert len(rows[0].split("|")) == 6, "the report row is no longer exactly four cells: %r" % rows[0]
PY
then ok "B5: a verdict whose reason is PTY-wrapped over three physical lines is rejoined whole into verdict.txt AND refute-report.md, and the row is still exactly four cells (#1705's _join_wrapped_candidates pattern, applied to VERDICT|)"
else bad "B5: the wrapped verdict reason is still truncated mid-sentence"
fi

# --- B6: a literal `|` in the reason neither breaks the row nor re-truncates the reason downstream.
if python3 - "$IOUT" <<'PY'
import sys, os, json, glob
cells = glob.glob(os.path.join(sys.argv[1], "gates", "*Pipe_sol*"))
assert cells, "no gate cell for the pipe-in-reason candidate"
report = open(os.path.join(cells[0], "refute-out", "refute-report.md"), encoding="utf-8").read()
rows = [l for l in report.splitlines() if l.startswith("| ") and "REAL" in l]
assert rows, "no verdict row in refute-report.md"
assert len(rows[0].split("|")) == 6, "a literal pipe in the reason broke the four-cell row: %r" % rows[0]
d = json.load(open(os.path.join(sys.argv[1], "verified_findings.json"), encoding="utf-8"))
pipe = [v for v in d["verified"] if "Pipe.sol" in v["location"]]
assert pipe, "the pipe-in-reason candidate was dropped"
reason = pipe[0]["reason"]
assert "PIPETAILSENTINEL" in reason, "the reason was re-truncated at the pipe by the -F'|' $5 read: %r" % reason
assert "|" not in reason, "a raw pipe survived into the recorded reason: %r" % reason
PY
then ok "B6: a reason containing a literal pipe keeps the report row at four cells and survives whole into verified_findings.json (the pipe is mapped to / -- without the scrub it re-truncates at verify-findings.sh's awk -F'|' \$5)"
else bad "B6: a literal pipe in the reason still breaks the row / truncates the reason"
fi

# --- B7: back-compat — a hand-written FIVE-column manifest still runs and stages no aux.
B7_OUT="$WORK/out-b7"
B7_LOG="$WORK/stub-env-b7.tsv"; : > "$B7_LOG"
printf 'base/AbstractYield.sol:_initiateWithdraw|C1|High|a five-column manifest|base/AbstractYield.sol\n' \
  > "$WORK/b7.manifest"
STUB_ENV_LOG="$B7_LOG" "$REFUTE" --candidates "$WORK/b7.manifest" --code-dir "$IREPO" \
  --backend mock --agentis "$ISTUB" --out "$B7_OUT" >"$WORK/b7.out" 2>"$WORK/b7.err"
RC=$?
if [ "$RC" -eq 0 ] && python3 - "$B7_LOG" "$B7_OUT" <<'PY'
import sys, os
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
assert rows, "run-refute.sh never invoked the refuter on the five-column manifest"
assert rows[0][2] == "", "a five-column manifest produced a non-empty AUX_CODE_PATH: %r" % rows[0][2]
report = open(os.path.join(sys.argv[2], "refute-report.md"), encoding="utf-8").read()
assert "| REFUTED |" in report or "| REAL |" in report, "no verdict row for the five-column manifest"
assert not any(f.startswith("aux_") for f in os.listdir(os.path.join(sys.argv[2], "run"))), \
    "an aux file was staged for a five-column manifest"
PY
then ok "B7: a five-column manifest (every pre-#1861 caller and fixture) still runs, stages no aux and env-ins an empty AUX_CODE_PATH -- the 6th column is strictly optional"
else bad "B7: run-refute.sh no longer accepts a five-column manifest (exit $RC)"
fi

# --- B8: bookkeeping + read-only still hold over the appendix-carrying run.
if cmp -s "$IRES" "$WORK/inheritance-results.orig" && python3 - "$IOUT/verified_findings.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
cand = d["totals"]["candidates"]; ver = d["totals"]["verified"]; err = d["totals"]["errored"]
assert cand == 6, "candidates != 6: %r" % cand
assert ver == 5, "verified != 5 (base, plain, gateway-via-C6, wrap, pipe): %r" % ver
assert err == 0, "errored != 0: %r" % err
assert cand - ver - err == 1, "rigorous-refutation count != 1 (only the deny candidate): %d" % (cand - ver - err)
assert len(d["verified"]) == ver, "verified[] length disagrees with totals.verified"
PY
then ok "B8: candidates == verified + errored + refuted (6 == 5 + 0 + 1) over the appendix-carrying run, and discovery-results.json is byte-unchanged"
else bad "B8: bookkeeping or the read-only invariant broke under the appendix"
fi

# ----------------------------------------------------------------------------------------------------------
# (9) #1887 CONSTRAINT AGGREGATION. run-refute.sh harvests the generalisable standard behind each REFUTED
#     verdict into its own `refute-constraints.tsv`; verify-findings.sh concatenates the per-gate files into
#     ONE <out>/refute-constraints.tsv in NUMERIC GATE ORDER. Two properties matter and both are asserted:
#     (a) the aggregate is DETERMINISTIC — byte-identical under --jobs 1 and --jobs > 1, because completion
#         order must never reach an artifact that feeds a knowledge corpus (the corpus would stop being
#         reproducible, and with it the #1887 A/B arm);
#     (b) verified_findings.json is UNCHANGED by the whole channel — the same inputs with and without the
#         refuter's CONSTRAINT| lines must produce a byte-identical findings file. This is the schema
#         promise: the channel adds a FILE, never a key, and never perturbs the verdict scrape.
#     Self-contained: its own repo, stub and results.json, so the fixtures above are untouched.
# ----------------------------------------------------------------------------------------------------------
note "9) #1887: the aggregated refute-constraints.tsv is gate-ordered and verified_findings.json is unchanged ..."
CREPO="$WORK/target-constraints"
mkdir -p "$CREPO/contracts"
printf 'contract A { function f() public {} }\n' > "$CREPO/contracts/A.sol"
printf 'contract B { function g() public {} }\n' > "$CREPO/contracts/B.sol"
printf 'contract C { function h() public {} }\n' > "$CREPO/contracts/C.sol"
printf 'contract D { function i() public {} }\n' > "$CREPO/contracts/D.sol"

# STUB_CONS=1 makes the refuted candidates carry a per-candidate CONSTRAINT| line BEFORE their verdict;
# unset reproduces the pre-#1887 reply exactly. Both arms answer the SAME verdicts.
CSTUB="$WORK/agentis-stub-constraints"
cat > "$CSTUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    fn="${CAND_FILE_FN:-}"
    cls="${CAND_CLASS:-}"
    case "$cls" in
      *refuted*)
        if [ "${STUB_CONS:-}" = "1" ]; then
          echo "CONSTRAINT|$cls|standard for $fn: the claim must name the unprivileged trigger"
        fi
        echo "VERDICT|REFUTED|$fn|$cls|a hostile read killed it"
        ;;
      *) echo "VERDICT|REAL|$fn|$cls|survived a hostile read" ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$CSTUB"

CRES="$WORK/constraint-results.json"
python3 - > "$CRES" <<'PY'
import json


def cell(sub, cls, f, loc):
    return {"subsystem": sub, "class": cls, "files": f,
            "candidates": ["%s|%s|High|an exploit sentence|sketch" % (loc, cls)], "coordination": []}


# Gate order is the MANIFEST order below: A (refuted), B (real), C (refuted), D (refuted). The three
# constraint rows must therefore come out A, C, D — never in completion order.
data = {
    "repo": "target-constraints", "backend": "mock", "jobs": 1,
    "cells": [
        cell("alpha", "C-refuted", "contracts/A.sol", "contracts/A.sol:f:1"),
        cell("beta", "C1", "contracts/B.sol", "contracts/B.sol:g:1"),
        cell("gamma", "C-refuted", "contracts/C.sol", "contracts/C.sol:h:1"),
        cell("delta", "C-refuted", "contracts/D.sol", "contracts/D.sol:i:1"),
    ],
    "totals": {"cells": 4, "candidates": 4, "steers": 0},
}
print(json.dumps(data, indent=2))
PY

CON_OUT="$WORK/out-constraints"
STUB_CONS=1 "$VERIFY" --results "$CRES" --repo "$CREPO" --out "$CON_OUT" --gate refute \
  --backend mock --agentis "$CSTUB" >"$WORK/con.out" 2>"$WORK/con.err"
RC=$?
NOCON_OUT="$WORK/out-noconstraints"
"$VERIFY" --results "$CRES" --repo "$CREPO" --out "$NOCON_OUT" --gate refute \
  --backend mock --agentis "$CSTUB" >"$WORK/nocon.out" 2>"$WORK/nocon.err"
RC2=$?
PAR_CON_OUT="$WORK/out-constraints-par"
STUB_CONS=1 "$VERIFY" --results "$CRES" --repo "$CREPO" --out "$PAR_CON_OUT" --gate refute --jobs 3 \
  --backend mock --agentis "$CSTUB" >"$WORK/conpar.out" 2>"$WORK/conpar.err"
RC3=$?
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$RC3" -eq 0 ]; then
  ok "9) all three verify runs (constraints on / off / --jobs 3) exit 0"
else
  bad "9) a verify run exited non-zero (on $RC / off $RC2 / parallel $RC3)"
  sed 's/^/      /' "$WORK/con.err" >&2
fi

if python3 - "$CON_OUT/refute-constraints.tsv" <<'PY'
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
assert len(rows) == 3, "expected 3 harvested constraints (A, C, D), got %d" % len(rows)
locs = [r[1] for r in rows]
assert locs == ["contracts/A.sol:f:1", "contracts/C.sol:h:1", "contracts/D.sol:i:1"], \
    "the aggregate is not in numeric GATE (manifest) order: %r" % locs
for r in rows:
    assert r[0] == "C-refuted", "wrong class column: %r" % r[0]
    assert r[2].startswith("standard for "), "wrong constraint column: %r" % r[2]
assert not any("B.sol" in l for l in locs), "a REAL candidate contributed a constraint"
PY
then ok "9a) the aggregated <out>/refute-constraints.tsv carries one row per REFUTED candidate, in numeric gate order, and none for the REAL one"
else bad "9a) the aggregated refute-constraints.tsv is missing, mis-ordered or contains a REAL candidate"
fi

if cmp -s "$CON_OUT/refute-constraints.tsv" "$PAR_CON_OUT/refute-constraints.tsv"; then
  ok "9b) the aggregate is BYTE-IDENTICAL under --jobs 3 — gate completion order never reaches the corpus input"
else
  bad "9b) --jobs 3 produced a different aggregate (the corpus would stop being reproducible):"
  diff "$CON_OUT/refute-constraints.tsv" "$PAR_CON_OUT/refute-constraints.tsv" | sed 's/^/      /' >&2
fi

if [ -f "$NOCON_OUT/refute-constraints.tsv" ] && [ ! -s "$NOCON_OUT/refute-constraints.tsv" ]; then
  ok "9c) with no CONSTRAINT| line in any reply the aggregate is an EMPTY (but present) file — refute-to-knowledge.sh turns that into a valid empty corpus"
else
  bad "9c) the constraint-free run did not produce an empty aggregate file"
fi

if cmp -s "$CON_OUT/verified_findings.json" "$NOCON_OUT/verified_findings.json"; then
  ok "9d) verified_findings.json is BYTE-IDENTICAL with and without the constraint lines — the channel adds a FILE, never a key, and never perturbs the verdict scrape"
else
  bad "9d) the constraint lines changed verified_findings.json:"
  diff "$NOCON_OUT/verified_findings.json" "$CON_OUT/verified_findings.json" | sed 's/^/      /' >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (10) #1962 --pay-floor: a well-formed candidate BELOW the floor is dropped into dropped_subfloor[] BEFORE it
#     ever reaches the gate (no per-candidate gate-cell side effect for it, no verify/refute pass spent on it);
#     a candidate AT/ABOVE the floor is gated normally; an UNRECOGNIZED-severity candidate (well-formed, not
#     one of low/medium/high/critical) fails OPEN — it is KEPT and reaches the gate, never counted as dropped.
#     Self-contained: its own throwaway repo + results.json; the fixtures above are untouched. The same
#     discovery-results.json WITHOUT --pay-floor proves default inertness (every candidate flows through
#     unchanged, dropped_subfloor empty/0).
# ----------------------------------------------------------------------------------------------------------
note "10) #1962: --pay-floor drops sub-floor candidates before the gate; default (no flag) is byte-inert ..."
PFREPO="$WORK/target-payfloor"
mkdir -p "$PFREPO/contracts"
printf 'contract High { function f() public {} }\n'    > "$PFREPO/contracts/High.sol"
printf 'contract Medium { function f() public {} }\n'  > "$PFREPO/contracts/Medium.sol"
printf 'contract Low { function f() public {} }\n'      > "$PFREPO/contracts/Low.sol"
printf 'contract Unknown { function f() public {} }\n'  > "$PFREPO/contracts/Unknown.sol"

PFRES="$WORK/payfloor-results.json"
python3 - > "$PFRES" <<'PY'
import json


def cell(sub, cls, f, loc, sev):
    return {"subsystem": sub, "class": cls, "files": f,
            "candidates": ["%s|%s|%s|an exploit sentence|sketch" % (loc, cls, sev)], "coordination": []}


# None of these classes match the stub's *refuted*/*REFUTED* pattern, so every GATED candidate comes back REAL.
data = {
    "repo": "target-payfloor", "backend": "mock", "jobs": 1,
    "cells": [
        cell("high severity", "C1", "contracts/High.sol", "contracts/High.sol:f:1", "High"),
        cell("medium severity", "C2", "contracts/Medium.sol", "contracts/Medium.sol:f:1", "Medium"),
        cell("low severity", "C3", "contracts/Low.sol", "contracts/Low.sol:f:1", "Low"),
        cell("unknown severity", "C4", "contracts/Unknown.sol", "contracts/Unknown.sol:f:1", "Informational"),
    ],
    "totals": {"cells": 4, "candidates": 4, "steers": 0},
}
print(json.dumps(data, indent=2))
PY
cp "$PFRES" "$WORK/payfloor-results.orig"

PF_OUT="$WORK/out-payfloor"
"$VERIFY" --results "$PFRES" --repo "$PFREPO" --out "$PF_OUT" --gate refute --backend mock --agentis "$STUB" \
  --pay-floor high >"$WORK/pf.out" 2>"$WORK/pf.err"
RC=$?
[ "$RC" -eq 0 ] && ok "10a) verify-findings.sh --pay-floor high exits 0" \
  || { bad "10a) --pay-floor high run exited $RC"; sed 's/^/      /' "$WORK/pf.err" >&2; }

if python3 - "$PF_OUT/verified_findings.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d.get("pay_floor") == "high", "top-level pay_floor != 'high': %r" % d.get("pay_floor")
assert d["totals"].get("dropped_subfloor") == 2, "totals.dropped_subfloor != 2: %r" % d["totals"].get("dropped_subfloor")
assert len(d.get("dropped_subfloor", [])) == 2, "dropped_subfloor[] len != 2: %d" % len(d.get("dropped_subfloor", []))
droplocs = sorted(x["location"] for x in d["dropped_subfloor"])
assert droplocs == ["contracts/Low.sol:f:1", "contracts/Medium.sol:f:1"], "wrong candidates dropped: %r" % droplocs
for x in d["dropped_subfloor"]:
    assert "below pay-floor high" in x["reason"], "dropped entry missing floor reason: %r" % x["reason"]
verlocs = sorted(v["location"] for v in d["verified"])
assert verlocs == ["contracts/High.sol:f:1", "contracts/Unknown.sol:f:1"], \
    "verified[] should be exactly High + Unknown (unrecognized-severity fails OPEN): %r" % verlocs
assert "contracts/Medium.sol:f:1" not in verlocs and "contracts/Low.sol:f:1" not in verlocs, \
    "a dropped sub-floor candidate leaked into verified[]"
errlocs = " ".join(e["location"] for e in d.get("errors", []))
assert "Medium.sol" not in errlocs and "Low.sol" not in errlocs, \
    "a dropped sub-floor candidate was mis-filed as errored instead of dropped_subfloor"
# candidates == verified + errored + refuted + dropped_subfloor (refuted = 0, nothing here is a REFUTED class)
cand = d["totals"]["candidates"]; ver = d["totals"]["verified"]; err = d["totals"]["errored"]; sub = d["totals"]["dropped_subfloor"]
assert cand == 4, "candidates != 4: %r" % cand
assert cand == ver + err + sub, "counting invariant broken: %d != %d + %d + %d (refuted=0)" % (cand, ver, err, sub)
PY
then ok "10b) Medium + Low land in dropped_subfloor (by location), are absent from verified[]/errors[], High + the unrecognized-severity candidate are kept, totals.dropped_subfloor == 2, pay_floor == 'high', and candidates == verified + errored + dropped_subfloor (4 == 2 + 0 + 2)"
else bad "10b) --pay-floor high partition/aggregation assertion failed"
fi

# no gate cell (and therefore no stub invocation / side effect) exists for either dropped candidate — the
# partition removed them from candidates.tsv BEFORE the gate loop ever ran, serial or parallel.
if python3 - "$PF_OUT" <<'PY'
import sys, os, glob
cells = glob.glob(os.path.join(sys.argv[1], "gates", "*"))
names = " ".join(os.path.basename(c) for c in cells)
assert "Medium_sol" not in names, "a gate cell exists for the dropped Medium candidate: %r" % names
assert "Low_sol" not in names, "a gate cell exists for the dropped Low candidate: %r" % names
assert any("High_sol" in os.path.basename(c) for c in cells), "no gate cell for the kept High candidate"
assert any("Unknown_sol" in os.path.basename(c) for c in cells), "no gate cell for the kept unrecognized-severity candidate"
PY
then ok "10c) NO gate cell (no stub invocation) exists under <out>/gates/ for either sub-floor candidate — the refute/verify pass was actually saved, not just hidden from the aggregate"
else bad "10c) a sub-floor candidate still produced a gate-cell side effect"
fi

note "10d) the SAME discovery-results.json WITHOUT --pay-floor is byte-inert (default = every candidate flows through) ..."
PF_NOFLOOR_OUT="$WORK/out-payfloor-noflag"
"$VERIFY" --results "$PFRES" --repo "$PFREPO" --out "$PF_NOFLOOR_OUT" --gate refute --backend mock --agentis "$STUB" \
  >"$WORK/pf-noflag.out" 2>"$WORK/pf-noflag.err"
RC=$?
[ "$RC" -eq 0 ] && ok "10d) the no-floor run exits 0" \
  || { bad "10d) the no-floor run exited $RC"; sed 's/^/      /' "$WORK/pf-noflag.err" >&2; }
if python3 - "$PF_NOFLOOR_OUT/verified_findings.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d.get("pay_floor") == "", "pay_floor should be '' when --pay-floor is unset: %r" % d.get("pay_floor")
assert not d.get("dropped_subfloor"), "dropped_subfloor should be empty when --pay-floor is unset: %r" % d.get("dropped_subfloor")
assert d["totals"].get("dropped_subfloor", 0) == 0, "totals.dropped_subfloor != 0: %r" % d["totals"].get("dropped_subfloor")
assert d["totals"]["candidates"] == 4, "candidates != 4: %r" % d["totals"]["candidates"]
assert d["totals"]["verified"] == 4, "verified != 4 (every candidate should flow through without a floor): %r" % d["totals"]["verified"]
assert d["totals"]["errored"] == 0, "errored != 0: %r" % d["totals"]["errored"]
assert len(d["verified"]) == 4, "verified[] len != 4: %d" % len(d["verified"])
PY
then ok "10e) without --pay-floor every candidate flows through unchanged (candidates=4, verified=4, errored=0), dropped_subfloor is empty and totals.dropped_subfloor == 0 -- default inertness"
else bad "10e) the no-floor run did not stay byte-inert"
fi
if cmp -s "$PFRES" "$WORK/payfloor-results.orig"; then
  ok "10f) discovery-results.json is still byte-for-byte unchanged after the --pay-floor partition (read-only invariant holds)"
else
  bad "10f) the --pay-floor partition mutated discovery-results.json"
fi

# ----------------------------------------------------------------------------------------------------------
# (11) #1965: a BLANK-LOCATION candidate (valid class + severity) must be treated exactly like the no-floor
#     path under --pay-floor -- it flows to candidates.tsv untouched and dies at the pre-existing gate-loop's
#     `[ -n "$LOCATION" ] || continue` skip, UNCOUNTED, rather than being misclassified as sub-floor by the
#     partition (which, before #1965, only ever looked at class/severity, never location). Self-contained: its
#     own throwaway repo + results.json; the fixtures above are untouched.
# ----------------------------------------------------------------------------------------------------------
note "11) #1965: a blank-location candidate stays uncounted regardless of --pay-floor ..."
BLREPO="$WORK/target-blankloc"
mkdir -p "$BLREPO/contracts"
printf 'contract Ctrl { function f() public {} }\n' > "$BLREPO/contracts/Ctrl.sol"

BLRES="$WORK/blankloc-results.json"
python3 - > "$BLRES" <<'PY'
import json


def cell(sub, cls, f, loc, sev):
    return {"subsystem": sub, "class": cls, "files": f,
            "candidates": ["%s|%s|%s|an exploit sentence|sketch" % (loc, cls, sev)], "coordination": []}


data = {
    "repo": "target-blankloc", "backend": "mock", "jobs": 1,
    "cells": [
        cell("control", "C9", "contracts/Ctrl.sol", "contracts/Ctrl.sol:f:1", "High"),
        cell("degenerate", "C9", "contracts/Ctrl.sol", "", "Medium"),
    ],
    "totals": {"cells": 2, "candidates": 2, "steers": 0},
}
print(json.dumps(data, indent=2))
PY

BL_OUT="$WORK/out-blankloc"
"$VERIFY" --results "$BLRES" --repo "$BLREPO" --out "$BL_OUT" --gate refute --backend mock --agentis "$STUB" \
  >"$WORK/bl.out" 2>"$WORK/bl.err"
RC=$?
[ "$RC" -eq 0 ] && ok "11a) the no-floor run exits 0" \
  || { bad "11a) the no-floor run exited $RC"; sed 's/^/      /' "$WORK/bl.err" >&2; }

BL_PF_OUT="$WORK/out-blankloc-payfloor"
"$VERIFY" --results "$BLRES" --repo "$BLREPO" --out "$BL_PF_OUT" --gate refute --backend mock --agentis "$STUB" \
  --pay-floor high >"$WORK/bl-pf.out" 2>"$WORK/bl-pf.err"
RC=$?
[ "$RC" -eq 0 ] && ok "11b) the --pay-floor high run exits 0" \
  || { bad "11b) the --pay-floor high run exited $RC"; sed 's/^/      /' "$WORK/bl-pf.err" >&2; }

if python3 - "$BL_OUT/verified_findings.json" "$BL_PF_OUT/verified_findings.json" <<'PY'
import sys, json
noflr = json.load(open(sys.argv[1], encoding="utf-8"))
pf = json.load(open(sys.argv[2], encoding="utf-8"))
cand_noflr = noflr["totals"]["candidates"]
cand_pf = pf["totals"]["candidates"]
assert cand_noflr == cand_pf, \
    "totals.candidates differs between no-floor (%r) and --pay-floor high (%r)" % (cand_noflr, cand_pf)
assert cand_noflr == 1, "totals.candidates != 1 (only the control candidate should ever be counted): %r" % cand_noflr
for entry in pf.get("dropped_subfloor", []):
    assert entry.get("location", "") != "", "a blank-location candidate leaked into dropped_subfloor[]: %r" % entry
    assert entry.get("file", "") != "", "a blank-file candidate leaked into dropped_subfloor[]: %r" % entry
assert pf["totals"]["dropped_subfloor"] == 0, \
    "totals.dropped_subfloor != 0 under --pay-floor high: %r" % pf["totals"]["dropped_subfloor"]
# #1962 counting invariant: candidates == verified + errored + refuted + dropped_subfloor (refuted = 0 here,
# nothing is under a *refuted* class). Must hold in BOTH runs.
for label, d in (("no-floor", noflr), ("--pay-floor high", pf)):
    cand = d["totals"]["candidates"]; ver = d["totals"]["verified"]; err = d["totals"]["errored"]; sub = d["totals"]["dropped_subfloor"]
    assert cand == ver + err + sub, "%s: counting invariant broken: %d != %d + %d + %d (refuted=0)" % (label, cand, ver, err, sub)
PY
then ok "11c) totals.candidates == 1 identically with and without --pay-floor high, dropped_subfloor[] never carries a blank-location entry, totals.dropped_subfloor == 0 under the floor, and candidates == verified + errored + dropped_subfloor holds in both runs"
else bad "11c) blank-location candidate assertion failed"
fi

# the blank-location candidate never reaches gate_candidate in EITHER run -- it dies at the pre-existing
# gate-loop skip before any gate cell is created, in both the no-floor path and the --pay-floor partition path.
if python3 - "$BL_OUT" "$BL_PF_OUT" <<'PY'
import sys, os, glob
for out_dir in sys.argv[1:]:
    cells = glob.glob(os.path.join(out_dir, "gates", "*"))
    names = " ".join(os.path.basename(c) for c in cells)
    assert any("Ctrl_sol" in os.path.basename(c) for c in cells), \
        "%s: no gate cell for the kept control candidate" % out_dir
    assert len(cells) == 1, "%s: expected exactly 1 gate cell (control only), got %d: %r" % (out_dir, len(cells), names)
PY
then ok "11d) exactly ONE gate cell exists (the control candidate) in both out dirs -- the blank-location candidate never produced a gate-cell side effect in either run"
else bad "11d) an unexpected gate-cell count/shape for the blank-location candidate"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — M4 verify integration (verify-findings.sh: refute gate -> CONFIRMED-only verified_findings.json) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
