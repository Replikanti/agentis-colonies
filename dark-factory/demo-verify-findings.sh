#!/usr/bin/env bash
# demo-verify-findings.sh — OFFLINE, DETERMINISTIC proof of M4 verify integration (#1630, epic #1611):
# verify-findings.sh drives the refute gate over EVERY candidate in an M3 discovery-results.json and aggregates
# the CONFIRMED-only survivors into verified_findings.json. Every gate call is driven by a FAST offline stub
# wired through the EXISTING run-refute.sh --agentis seam (NO live agentis / forge / network).
#
# Assertions:
#   1) verified_findings.json is valid JSON carrying the seam-3 schema keys (repo, gate, verified[], totals).
#   2) CONFIRMED-only: exactly the candidates the refute stub returned REAL are kept; the REFUTED one is dropped.
#   3) READ-ONLY: discovery-results.json is byte-for-byte UNCHANGED after the run (verify never mutates M3 output).
#   4) DEGRADE: a candidate whose gate cannot evaluate it (its code file is absent) is skipped, not fatal — the
#      run still exits 0 and the healthy candidates are still verified.
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
# (a) A throwaway target repo holding the code files three of the four candidates reference (the fourth
#     references a file NOT in the repo, to exercise the degrade path).
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target"
mkdir -p "$REPO/contracts"
printf 'contract Vault { function deposit() public {} }\n'   > "$REPO/contracts/Vault.sol"
printf 'contract Oracle { function price() public {} }\n'    > "$REPO/contracts/Oracle.sol"
printf 'contract Token { function transfer() public {} }\n'  > "$REPO/contracts/Token.sol"

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
# (c) The inline M3 discovery-results.json: 4 candidates — 2 the stub confirms REAL, 1 REFUTED (C-refuted), and
#     1 whose code file is absent from the repo (the degrade case). Built via python3 (the JSON convention).
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
        {"subsystem": "token", "class": "C-refuted",
         "files": "contracts/Token.sol",
         "candidates": ["contracts/Token.sol:transfer:5|C-refuted|Low|transfer lacks an owner check|anyone moves funds"],
         "coordination": []},
        {"subsystem": "ghost", "class": "C9",
         "files": "contracts/Missing.sol",
         "candidates": ["contracts/Missing.sol:ghost:1|C9|Medium|references a file absent from the repo|the gate cannot evaluate it"],
         "coordination": []},
    ],
    "totals": {"cells": 4, "candidates": 4, "steers": 0},
}
print(json.dumps(data, indent=2))
PY
cp "$RES" "$WORK/results.orig"   # byte-exact snapshot for the read-only assertion

# ----------------------------------------------------------------------------------------------------------
# Run verify-findings.sh over the merged candidates.
# ----------------------------------------------------------------------------------------------------------
OUT="$WORK/out"
note "running verify-findings.sh --gate refute over 4 candidates (offline stub) ..."
"$VERIFY" --results "$RES" --repo "$REPO" --out "$OUT" --gate refute --backend mock --agentis "$STUB" \
  >"$WORK/verify.out" 2>"$WORK/verify.err"
RC=$?
[ "$RC" -eq 0 ] && ok "verify-findings.sh exits 0 (even with a REFUTED + a degrade candidate present)" \
  || { bad "verify-findings.sh exited $RC"; sed 's/^/      /' "$WORK/verify.err" >&2; }
VJ="$OUT/verified_findings.json"
[ -f "$VJ" ] && ok "emitted verified_findings.json" || bad "verified_findings.json not emitted"

# ----------------------------------------------------------------------------------------------------------
# (1) schema keys + (2) CONFIRMED-only aggregation.
# ----------------------------------------------------------------------------------------------------------
note "1)+2) schema + CONFIRMED-only aggregation ..."
if python3 - "$VJ" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(d.keys()) >= {"repo", "gate", "verified", "totals"}, "top-level keys missing: %r" % list(d.keys())
assert d["gate"] == "refute", "gate != refute: %r" % d["gate"]
assert d["repo"] == "target", "repo != target: %r" % d["repo"]
assert isinstance(d["verified"], list), "verified is not a list"
assert set(d["totals"].keys()) >= {"candidates", "verified"}, "totals keys missing"
assert d["totals"]["candidates"] == 4, "candidates total != 4: %r" % d["totals"]["candidates"]
assert d["totals"]["verified"] == 2, "verified total != 2: %r" % d["totals"]["verified"]
assert len(d["verified"]) == 2, "verified list len != 2: %d" % len(d["verified"])
keys = {"subsystem", "location", "file", "class", "severity", "exploit", "poc_sketch", "verdict", "reason"}
for v in d["verified"]:
    assert set(v.keys()) == keys, "verified entry keys %r != %r" % (set(v.keys()), keys)
    assert v["verdict"] == "REAL", "a kept finding is not REAL: %r" % v["verdict"]
locs = sorted(v["location"] for v in d["verified"])
assert locs == ["contracts/Oracle.sol:price:20", "contracts/Vault.sol:deposit:12"], "kept the wrong findings: %r" % locs
# the REFUTED candidate and the degrade candidate must both be absent
alll = " ".join(v["location"] for v in d["verified"])
assert "Token.sol" not in alll, "the REFUTED candidate was not dropped"
assert "Missing.sol" not in alll, "the degrade (absent-code) candidate was not dropped"
# the derived code file is the part before the first colon of the location
byloc = {v["location"]: v for v in d["verified"]}
assert byloc["contracts/Vault.sol:deposit:12"]["file"] == "contracts/Vault.sol", "code file mis-derived"
assert byloc["contracts/Vault.sol:deposit:12"]["class"] == "C1", "class mis-parsed"
assert byloc["contracts/Vault.sol:deposit:12"]["severity"] == "High", "severity mis-parsed"
PY
then ok "verified_findings.json carries the schema keys AND only the 2 REAL findings (REFUTED + degrade dropped)"
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
# (4) DEGRADE: the absent-code candidate was skipped, not fatal — the run still verified the 2 healthy ones.
# ----------------------------------------------------------------------------------------------------------
note "4) degrade: an ungate-able candidate is skipped, not fatal ..."
if grep -q 'dropped' "$WORK/verify.err"; then
  ok "verify-findings.sh logged a dropped/skipped candidate and still completed (exit 0 above, 2 findings kept)"
else
  bad "no drop/skip was logged for the ungate-able candidate"
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
