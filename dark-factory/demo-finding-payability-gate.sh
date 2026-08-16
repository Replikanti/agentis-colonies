#!/usr/bin/env bash
# demo-finding-payability-gate.sh — OFFLINE, DETERMINISTIC proof of the FINDING-LEVEL payability gate (#1930):
# finding-payability-gate.sh re-shapes verify-findings.sh's verified_findings.json against the program's
# published pay floor, so a Medium lead on a High-floor program is never packaged as if it were worth money.
#
# It asserts, over hand-written verified_findings.json fixtures (no network, no LLM, no forge):
#   1) --pay-floor high MOVES the Medium and the Low finding into unpayable[] and keeps High + Critical in
#      verified[], each annotated with a pay_verdict (and the unpayable ones with a pay_note naming the floor).
#   2) --mode flag keeps EVERY finding in verified[] with the same annotations and writes no unpayable[] —
#      the non-destructive alternative.
#   3) A finding with a BLANK or GARBAGE severity is NEVER dropped in either mode (pay_verdict `unknown`) —
#      the fail-open rule, because the alternative is silently discarding a real finding.
#   4) The accounting holds: totals.verified == len(verified), plus totals.unpayable + totals.verified_pregate.
#   5) An ALL-PAYABLE input leaves verified[] semantically identical to the input (only the additive
#      pay_verdict key is added) — the gate is inert when nothing is sub-floor.
#   6) repo / gate / errors[] are passed through untouched (the gate owns severity, nothing else).
#   7) The contracts: a missing findings file and unparseable JSON both [SKIP] + exit 0 with --out UNWRITTEN
#      (never a truncated artifact); a bad --pay-floor, a bad --mode, an unknown flag and a valueless flag all
#      exit 2.
#   8) NEVER-SUBMIT source guard: no network / submission verb on any executable line.
#
# Usage:  dark-factory/demo-finding-payability-gate.sh
# Requires: python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/finding-payability-gate.sh"

FAILS=0
note() { echo "demo-finding-payability-gate.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$GATE" ] || { note "finding-payability-gate.sh not found / not executable: $GATE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-finding-pay-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# The fixture: verify-findings.sh's seam-3 schema with one finding per severity band plus two un-rankable ones
# (a BLANK severity and a garbage word), so the fail-open rule is exercised from both directions.
# ----------------------------------------------------------------------------------------------------------
MIXED="$WORK/verified_findings.json"
cat > "$MIXED" <<'JSON'
{
  "repo": "demo-target",
  "gate": "refute",
  "verified": [
    {"subsystem": "vault", "location": "contracts/Vault.sol:deposit:10", "file": "contracts/Vault.sol",
     "class": "C6", "severity": "Critical", "exploit": "drains the vault", "poc_sketch": "s", "verdict": "REAL", "reason": "r"},
    {"subsystem": "vault", "location": "contracts/Vault.sol:mint:20", "file": "contracts/Vault.sol",
     "class": "C11", "severity": "High", "exploit": "mints free shares", "poc_sketch": "s", "verdict": "REAL", "reason": "r"},
    {"subsystem": "oracle", "location": "contracts/Oracle.sol:peek:30", "file": "contracts/Oracle.sol",
     "class": "C2", "severity": "Medium", "exploit": "stale price window", "poc_sketch": "s", "verdict": "REAL", "reason": "r"},
    {"subsystem": "gov", "location": "contracts/Gov.sol:vote:40", "file": "contracts/Gov.sol",
     "class": "C5", "severity": "Low", "exploit": "cosmetic", "poc_sketch": "s", "verdict": "REAL", "reason": "r"},
    {"subsystem": "queue", "location": "contracts/Queue.sol:pop:50", "file": "contracts/Queue.sol",
     "class": "C16", "severity": "", "exploit": "no severity recorded", "poc_sketch": "s", "verdict": "REAL", "reason": "r"},
    {"subsystem": "queue", "location": "contracts/Queue.sol:push:60", "file": "contracts/Queue.sol",
     "class": "C16", "severity": "catastrophic", "exploit": "a severity word nobody ranks", "poc_sketch": "s", "verdict": "REAL", "reason": "r"}
  ],
  "errors": [
    {"location": "contracts/Broken.sol:??:0", "file": "contracts/Broken.sol", "reason": "malformed candidate"}
  ],
  "totals": {"candidates": 11, "verified": 6, "errored": 1}
}
JSON

# ----------------------------------------------------------------------------------------------------------
# 1) --pay-floor high (default --mode drop): Medium + Low MOVE to unpayable[]; High + Critical stay; the two
#    un-rankable ones stay as `unknown`.
# ----------------------------------------------------------------------------------------------------------
note "1) --pay-floor high moves the sub-floor findings into unpayable[] (drop mode) ..."
DROP_OUT="$WORK/gated-drop.json"
"$GATE" --findings "$MIXED" --pay-floor high --out "$DROP_OUT" 2>"$WORK/drop.err"
RC=$?
[ "$RC" -eq 0 ] && ok "the gate exits 0 on a well-formed findings file" \
  || { bad "the gate exited $RC"; sed 's/^/      /' "$WORK/drop.err" >&2; }
if grep -q 'payable 2, unpayable 2, unknown 2 (floor=high, mode=drop)' "$WORK/drop.err"; then
  ok "the stderr summary line reports payable 2 / unpayable 2 / unknown 2 at floor=high"
else
  bad "the stderr summary line is missing or wrong:"; sed 's/^/      /' "$WORK/drop.err" >&2
fi
if python3 - "$DROP_OUT" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
kept = {v["location"]: v for v in d["verified"]}
gone = {v["location"]: v for v in d["unpayable"]}
assert "contracts/Vault.sol:deposit:10" in kept, "the Critical finding was not kept"
assert "contracts/Vault.sol:mint:20" in kept, "the High finding was not kept"
assert "contracts/Oracle.sol:peek:30" in gone, "the Medium finding was not moved to unpayable[]"
assert "contracts/Gov.sol:vote:40" in gone, "the Low finding was not moved to unpayable[]"
assert kept["contracts/Vault.sol:mint:20"]["pay_verdict"] == "payable", "High is not annotated payable"
for loc, v in gone.items():
    assert v["pay_verdict"] == "unpayable", "%s is not annotated unpayable" % loc
    assert "high" in v["pay_note"], "%s pay_note does not name the floor: %r" % (loc, v["pay_note"])
    assert "$0" in v["pay_note"], "%s pay_note does not say it earns $0: %r" % (loc, v["pay_note"])
assert d["pay_floor"] == "high", "top-level pay_floor %r" % d.get("pay_floor")
# MOVED, never deleted: every input finding is still somewhere in the artifact.
assert len(kept) + len(gone) == 6, "findings were LOST: %d + %d != 6" % (len(kept), len(gone))
# The evidence rides along with the moved finding (a bare location list would not be reviewable).
assert gone["contracts/Oracle.sol:peek:30"]["exploit"] == "stale price window", "evidence was stripped"
PY
then ok "Medium + Low moved to unpayable[] with a floor-naming pay_note; High + Critical kept; nothing lost"
else bad "the drop-mode partition assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) + 3) --mode flag keeps everything in verified[]; an un-rankable severity is never dropped in EITHER mode.
# ----------------------------------------------------------------------------------------------------------
note "2) --mode flag annotates without moving anything ..."
FLAG_OUT="$WORK/gated-flag.json"
"$GATE" --findings "$MIXED" --pay-floor high --mode flag --out "$FLAG_OUT" 2>"$WORK/flag.err"
RC=$?
[ "$RC" -eq 0 ] && ok "--mode flag exits 0" || bad "--mode flag exited $RC"
if python3 - "$FLAG_OUT" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(d["verified"]) == 6, "flag mode kept %d findings, expected all 6" % len(d["verified"])
assert "unpayable" not in d, "flag mode wrote an unpayable[] array"
verdicts = sorted(v["pay_verdict"] for v in d["verified"])
assert verdicts == ["payable", "payable", "unknown", "unknown", "unpayable", "unpayable"], \
    "flag-mode verdicts %r" % verdicts
sub = [v for v in d["verified"] if v["pay_verdict"] == "unpayable"]
assert all("pay_note" in v for v in sub), "a flagged sub-floor finding carries no pay_note"
PY
then ok "flag mode keeps all 6 in verified[], annotates each, and writes NO unpayable[]"
else bad "the flag-mode assertion failed"
fi

note "3) a blank / unrankable severity is NEVER dropped (fail-open) ..."
if python3 - "$DROP_OUT" "$FLAG_OUT" <<'PY'
import sys, json
for path in sys.argv[1:]:
    d = json.load(open(path, encoding="utf-8"))
    kept = {v["location"]: v for v in d["verified"]}
    for loc in ("contracts/Queue.sol:pop:50", "contracts/Queue.sol:push:60"):
        assert loc in kept, "%s was dropped from %s despite an unrankable severity" % (loc, path)
        assert kept[loc]["pay_verdict"] == "unknown", "%s is not annotated unknown in %s" % (loc, path)
        assert "pay_note" not in kept[loc], "%s got an unpayable pay_note in %s" % (loc, path)
    d_unpay = {v["location"] for v in d.get("unpayable", [])}
    assert not (d_unpay & {"contracts/Queue.sol:pop:50", "contracts/Queue.sol:push:60"}), \
        "an unrankable finding leaked into unpayable[] in %s" % path
PY
then ok "the blank-severity AND the garbage-severity finding stay in verified[] as pay_verdict unknown in BOTH modes"
else bad "the fail-open (unknown severity) assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# 4) The accounting: totals.verified == len(verified), plus the two new totals.
# ----------------------------------------------------------------------------------------------------------
note "4) the totals stay self-consistent for downstream readers ..."
if python3 - "$DROP_OUT" "$FLAG_OUT" <<'PY'
import sys, json
drop = json.load(open(sys.argv[1], encoding="utf-8"))
flag = json.load(open(sys.argv[2], encoding="utf-8"))
for name, d in (("drop", drop), ("flag", flag)):
    t = d["totals"]
    assert t["verified"] == len(d["verified"]), \
        "%s: totals.verified %r != len(verified) %d" % (name, t["verified"], len(d["verified"]))
    assert t["verified_pregate"] == 6, "%s: totals.verified_pregate %r != 6" % (name, t["verified_pregate"])
    assert t["unpayable"] == 2, "%s: totals.unpayable %r != 2" % (name, t["unpayable"])
    # The pre-existing totals are untouched.
    assert t["candidates"] == 11 and t["errored"] == 1, "%s: a pre-existing total was rewritten: %r" % (name, t)
assert drop["totals"]["verified"] == 4, "drop mode totals.verified %r != 4" % drop["totals"]["verified"]
assert flag["totals"]["verified"] == 6, "flag mode totals.verified %r != 6" % flag["totals"]["verified"]
PY
then ok "totals.verified == len(verified) in both modes; verified_pregate/unpayable added; candidates/errored untouched"
else bad "the totals accounting assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# 5) An ALL-PAYABLE input: verified[] is semantically identical to the input (only the additive pay_verdict).
# ----------------------------------------------------------------------------------------------------------
note "5) an all-payable input passes through inert ..."
ALLPAY="$WORK/all-payable.json"
cat > "$ALLPAY" <<'JSON'
{
  "repo": "demo-target",
  "gate": "refute",
  "verified": [
    {"location": "contracts/Vault.sol:deposit:10", "file": "contracts/Vault.sol", "class": "C6",
     "severity": "High", "exploit": "e1", "poc_sketch": "s1", "verdict": "REAL", "reason": "r1"},
    {"location": "contracts/Vault.sol:redeem:20", "file": "contracts/Vault.sol", "class": "C10",
     "severity": "Critical", "exploit": "e2", "poc_sketch": "s2", "verdict": "REAL", "reason": "r2"}
  ],
  "errors": [],
  "totals": {"candidates": 2, "verified": 2, "errored": 0}
}
JSON
ALLPAY_OUT="$WORK/all-payable.gated.json"
"$GATE" --findings "$ALLPAY" --pay-floor high --out "$ALLPAY_OUT" 2>/dev/null
if python3 - "$ALLPAY" "$ALLPAY_OUT" <<'PY'
import sys, json
src = json.load(open(sys.argv[1], encoding="utf-8"))
out = json.load(open(sys.argv[2], encoding="utf-8"))
assert out["unpayable"] == [], "an all-payable input produced a non-empty unpayable[]: %r" % out["unpayable"]
assert len(out["verified"]) == len(src["verified"]), "the finding count changed"
for a, b in zip(src["verified"], out["verified"]):
    stripped = dict(b)
    assert stripped.pop("pay_verdict") == "payable", "an all-payable finding is not annotated payable"
    assert stripped == a, "a payable finding was rewritten:\n  in  = %r\n  out = %r" % (a, stripped)
assert out["totals"]["verified"] == 2 and out["totals"]["unpayable"] == 0, "totals %r" % out["totals"]
PY
then ok "every payable finding is byte-for-byte the input entry plus the additive pay_verdict; unpayable[] empty"
else bad "the all-payable inertness assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# 6) repo / gate / errors[] pass through untouched.
# ----------------------------------------------------------------------------------------------------------
note "6) repo / gate / errors[] are passed through untouched ..."
if python3 - "$MIXED" "$DROP_OUT" <<'PY'
import sys, json
src = json.load(open(sys.argv[1], encoding="utf-8"))
out = json.load(open(sys.argv[2], encoding="utf-8"))
assert out["repo"] == src["repo"], "repo changed: %r" % out["repo"]
assert out["gate"] == src["gate"], "gate changed: %r" % out["gate"]
assert out["errors"] == src["errors"], "errors[] changed: %r" % out["errors"]
PY
then ok "repo, gate and errors[] survive the gate verbatim"
else bad "a non-severity field was rewritten by the gate"
fi

# ----------------------------------------------------------------------------------------------------------
# 7) CONTRACTS: SKIP paths leave --out UNWRITTEN; bad args fail fast with exit 2.
# ----------------------------------------------------------------------------------------------------------
note "7) SKIP + usage contracts ..."
MISSING_OUT="$WORK/never-written-1.json"
"$GATE" --findings "$WORK/does-not-exist.json" --pay-floor high --out "$MISSING_OUT" >/dev/null 2>"$WORK/skip1.err"
RC=$?
if [ "$RC" -eq 0 ] && grep -q '\[SKIP\]' "$WORK/skip1.err" && [ ! -f "$MISSING_OUT" ]; then
  ok "a missing findings file -> [SKIP] + exit 0 + --out UNWRITTEN"
else
  bad "the missing-file SKIP contract did not hold (exit $RC, out exists: $([ -f "$MISSING_OUT" ] && echo yes || echo no))"
fi
BADJSON="$WORK/not-json.json"
printf 'this is not json at all\n' > "$BADJSON"
BADJSON_OUT="$WORK/never-written-2.json"
"$GATE" --findings "$BADJSON" --pay-floor high --out "$BADJSON_OUT" >/dev/null 2>"$WORK/skip2.err"
RC=$?
if [ "$RC" -eq 0 ] && grep -q '\[SKIP\]' "$WORK/skip2.err" && [ ! -f "$BADJSON_OUT" ]; then
  ok "unparseable JSON -> [SKIP] + exit 0 + --out UNWRITTEN (never a truncated artifact)"
else
  bad "the unparseable-JSON SKIP contract did not hold (exit $RC, out exists: $([ -f "$BADJSON_OUT" ] && echo yes || echo no))"
fi
# The in-place default must also be untouched by a SKIP.
BADJSON_BEFORE="$(cat "$BADJSON")"
"$GATE" --findings "$BADJSON" --pay-floor high >/dev/null 2>&1
if [ "$(cat "$BADJSON")" = "$BADJSON_BEFORE" ]; then
  ok "an in-place SKIP leaves the findings file byte-identical"
else
  bad "an in-place SKIP rewrote the findings file"
fi

badarg() {
  ba_desc="$1"; ba_expect="$2"; shift 2
  ba_err="$WORK/badarg.err"
  "$GATE" "$@" >/dev/null 2>"$ba_err"
  ba_rc=$?
  if [ "$ba_rc" -eq 2 ] && grep -q -- "$ba_expect" "$ba_err"; then
    ok "$ba_desc fails fast with exit 2 + the usage error"
  else
    bad "$ba_desc did not fail fast as expected (exit $ba_rc):"
    sed 's/^/      /' "$ba_err" | head -3 >&2
  fi
}
badarg "a missing --pay-floor" 'is required' --findings "$MIXED"
badarg "an invalid --pay-floor" 'must be one of' --findings "$MIXED" --pay-floor sev-9
badarg "an unknown --mode" 'must be drop or flag' --findings "$MIXED" --pay-floor high --mode annihilate
badarg "an unknown flag" 'unknown arg' --findings "$MIXED" --pay-floor high --nope
badarg "a valueless flag" 'requires a value' --findings "$MIXED" --pay-floor
badarg "a missing --findings" 'is required' --pay-floor high

# ----------------------------------------------------------------------------------------------------------
# 8) NEVER-SUBMIT source guard (the demo-run-zone-hunt.sh idiom): no egress verb on an executable line.
# ----------------------------------------------------------------------------------------------------------
note "8) never-submit posture ..."
if grep -vE '^[[:space:]]*#' "$GATE" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "finding-payability-gate.sh invokes a network/submission verb on an executable line"
else
  ok "finding-payability-gate.sh has no network / no submission verb on any executable line (zero egress)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the finding-level pay gate moves sub-floor findings into unpayable[] without deleting evidence,"
  note "      never drops an unrankable severity, keeps the totals self-consistent, is inert on an all-payable"
  note "      input, leaves --out unwritten on every SKIP, and fails fast on bad args. Offline; never submits."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
