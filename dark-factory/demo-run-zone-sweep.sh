#!/usr/bin/env bash
# demo-run-zone-sweep.sh — OFFLINE, DETERMINISTIC end-to-end proof of #1828 M3: run-zone-sweep.sh closes its
# own coverage gaps with NO operator step in the loop, and does so under two independent bounds.
#
# It drives the shipped fixtures/zone-map/ tree through the SAME offline seams demo-run-zone-hunt.sh uses
# (--map-fixture / --brief-fixture / --pass-fixture / --backend mock / --agentis <stub>) with its own minimal
# stub — no live agentis, no LLM, no forge, no network. The 1275-line capstone demo is deliberately NOT
# refactored: the two demos share fixtures, not code.
#
# Assertions:
#   (A) AUTONOMY — ONE command over a budget-truncated 4-zone run ends `complete: true`, exit 0, with the
#       report naming 2 closed / 0 remaining and a 2-entry ledger. No second operator command anywhere.
#   (B) INERTNESS — with --max-rehunt-passes 0 the sweep runs EXACTLY the inner pass an operator would have
#       run by hand: discovery-results.merged.json is BYTE-IDENTICAL (cmp) to the direct run-zone-hunt.sh
#       invocation's, and the two coverage records match once the timestamps are dropped. The sweep adds a
#       layer; it changes nothing underneath.
#   (C) BOUNDEDNESS — THE ONE THAT MATTERS. A re-hunt that closes nothing must terminate. `--rehunt-max-attempts`
#       cannot do it: a `budget_exhausted` zone never gains an `attempts[]` entry (only `zone-coverage.py retry`
#       appends one, and run-zone-hunt.sh calls it only for artifact-bearing statuses), so `gaps --max-attempts N`
#       emits `hunt` for it forever. The sweep stops anyway — `give_up|no_progress` — and the record proves the
#       spin condition was really present (a `budget_exhausted` zone with zero attempts).
#   (D) NON-RETRYABLE DEFECTS — over the unscoped-zone repo shape the sweep emits `remap_target`, runs ZERO
#       re-hunt passes, exits 5, and the report names the zone and says a re-hunt cannot fix it.
#   (E) ATTEMPT CEILING — a record whose only gap is a `failed` zone already at the ceiling: zero re-hunt
#       passes, exit 5, terminal reason `attempt_ceiling`.
#   (F) FLAG VALIDATION + ABORT HONESTY — the flags the sweep owns are rejected in the passthrough (exit 2),
#       bad integers fail fast (exit 2), and an ABORTED inner pass still leaves the ledger AND the report on
#       disk (an incomplete sweep is never silent).
#
# Usage:  dark-factory/demo-run-zone-sweep.sh
# Requires: git + python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', no process substitution, literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/run-zone-sweep.sh"
ZONEHUNT="$HERE/run-zone-hunt.sh"
FIXTURE_DIR="$HERE/fixtures/zone-map"
ZONES_FIXTURE="$FIXTURE_DIR/zones.fixture.txt"
BRIEFS_FIXTURE="$FIXTURE_DIR/briefs.fixture.txt"
PASS_FIXTURE="scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted"

FAILS=0
note() { echo "demo-run-zone-sweep.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
[ -x "$SWEEP" ]    || { note "run-zone-sweep.sh not found / not executable: $SWEEP" >&2; exit 3; }
[ -x "$ZONEHUNT" ] || { note "run-zone-hunt.sh not found / not executable: $ZONEHUNT" >&2; exit 3; }
[ -f "$ZONES_FIXTURE" ]  || { note "zones.fixture.txt not found: $ZONES_FIXTURE" >&2; exit 3; }
[ -f "$BRIEFS_FIXTURE" ] || { note "briefs.fixture.txt not found: $BRIEFS_FIXTURE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-run-zone-sweep.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# The throwaway git target: the same fixture contracts/ tree the capstone demo uses (minus the isolated #1834
# registry regression fixture, which would perturb the hardcoded 4-zone counts below).
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target"
mkdir -p "$REPO"
cp -R "$FIXTURE_DIR/contracts" "$REPO/contracts"
rm -rf "$REPO/contracts/registry"
git -C "$REPO" init -q
git -C "$REPO" config user.email demo@example.invalid
git -C "$REPO" config user.name "demo"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "audited baseline"

# ----------------------------------------------------------------------------------------------------------
# The minimal offline stub through the --agentis seam. Every cell answers SAFE: this demo measures COVERAGE
# (which zones ran, under which bound), not findings, so the verify/deliver stages stay trivially cheap.
# DEMO_FAIL_ZONE makes `agentis init` fail inside ONE zone's out-dir, which makes run-discovery.sh itself exit
# non-zero for that zone — the offline way to produce a `failed` zone (the #1830 capstone demo's own idiom).
# ----------------------------------------------------------------------------------------------------------
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
case "${1:-}" in
  init)
    if [ -n "${DEMO_FAIL_ZONE:-}" ]; then
      case "$PWD" in */discovery/$DEMO_FAIL_ZONE/*) exit 1 ;; esac
    fi
    mkdir -p .agentis; exit 0 ;;
  memo) exit 0 ;;
  go)
    case "${2:-}" in hunter.ag) echo "SAFE" ;; esac
    exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB"

# Everything after `--` is the passthrough every block hands to run-zone-hunt.sh verbatim.
sweep() {
  sw_out="$1"; shift
  "$SWEEP" --repo "${SWEEP_REPO:-$REPO}" --out "$sw_out" "$@"
}
hunt_zone_count() { grep -c '\[M3\] hunting zone' "$1" 2>/dev/null || true; }
rehunt_pass_count() { grep -c 're-hunting the gap set' "$1" 2>/dev/null || true; }

# ----------------------------------------------------------------------------------------------------------
# (A) AUTONOMY. The fixture's cell counts are liquidation 2 + vault 3 + governance 2 + oracle 2 = 9, so
#     --run-cell-budget 5 admits exactly the two VALUE-CUSTODY zones and denies the two non-custody ones
#     (pinned independently by demo-run-zone-hunt.sh block (g)). ONE sweep command, with a --budget-ceiling
#     the operator authorized ONCE, then closes both gaps by itself.
# ----------------------------------------------------------------------------------------------------------
note "A) autonomy: one command closes the budget-denied gaps by itself ..."
OUTA="$WORK/a"
sweep "$OUTA" --budget-ceiling 9 -- \
  --drop-dir "$OUTA/drop" --scope-hint contracts --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" --pass-fixture "$PASS_FIXTURE" \
  --in-scope "the whole in-scope program" --run-cell-budget 5 \
  >"$WORK/a.out" 2>"$WORK/a.err"
RCA=$?
[ "$RCA" -eq 0 ] && ok "A: the sweep exits 0 — the final coverage record is complete" \
  || { bad "A: the sweep exited $RCA"; sed 's/^/      /' "$WORK/a.err" | tail -20 >&2; }
if python3 - "$OUTA" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
led = json.load(open(os.path.join(out, "coverage", "gap-remediation.json"), encoding="utf-8"))
assert rec["complete"] is True, "the sweep left gaps: %r" % rec["gap_zones"]
assert len(rec["zones"]) == 4, "the record covers %d zones" % len(rec["zones"])
assert led["schema"] == "gap-remediation/v1", led["schema"]
# ONE breadth pass + ONE re-hunt pass: the policy raised straight to the ceiling, so no second raise is
# possible and no second pass was needed.
assert len(led["passes"]) == 2, "passes[] is %r" % [p["decision"] for p in led["passes"]]
assert led["passes"][0]["decision"] == "initial", led["passes"][0]["decision"]
assert led["passes"][1]["decision"] == "raise_budget_and_rehunt", led["passes"][1]["decision"]
assert led["passes"][1]["run_cell_budget"] == 9, led["passes"][1]["run_cell_budget"]
assert led["closed"] == ["contracts_governance", "contracts_oracle"], led["closed"]
assert led["remaining"] == [], led["remaining"]
assert led["terminal_reason"] == "complete", led["terminal_reason"]
PY
then ok "A: the ledger shows 1 breadth + 1 re-hunt pass, the raise went straight to the ceiling, both gaps closed"
else bad "A: the autonomy ledger assertion failed"
fi
if [ -f "$OUTA/coverage/gap-report.md" ] \
   && grep -q 'Closed gaps (2)' "$OUTA/coverage/gap-report.md" \
   && grep -q 'Remaining gaps (0)' "$OUTA/coverage/gap-report.md" \
   && grep -q 'contracts_governance' "$OUTA/coverage/gap-report.md"; then
  ok "A: gap-report.md names 2 closed / 0 remaining gaps, by zone id"
else
  bad "A: the gap-report.md content assertion failed"
fi
# The whole point of the issue: NO operator step in the loop. The second pass must be the sweep's own.
if [ "$(rehunt_pass_count "$WORK/a.err")" -eq 1 ] && grep -q '\[policy\] raise_budget_and_rehunt' "$WORK/a.err"; then
  ok "A: the re-hunt was decided and launched by the sweep itself (one operator command, no manual salvage)"
else
  bad "A: the sweep did not autonomously launch exactly one re-hunt pass"
fi

# ----------------------------------------------------------------------------------------------------------
# (B) INERTNESS. --max-rehunt-passes 0 = breadth only. The artifact must be byte-identical to the one a plain
#     run-zone-hunt.sh invocation produces — this is the assertion that fails the moment the sweep starts
#     influencing the pass underneath it. (run-zone-hunt.sh itself is untouched by this issue; this pins that
#     the WRAPPER is inert too.)
# ----------------------------------------------------------------------------------------------------------
note "B) inertness: --max-rehunt-passes 0 is byte-equivalent to a direct run-zone-hunt.sh pass ..."
OUTB1="$WORK/b-sweep"
sweep "$OUTB1" --max-rehunt-passes 0 -- \
  --drop-dir "$OUTB1/drop" --scope-hint contracts --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" --pass-fixture "$PASS_FIXTURE" \
  --in-scope "the whole in-scope program" --run-cell-budget 5 \
  >"$WORK/b1.out" 2>"$WORK/b1.err"
RCB1=$?
OUTB2="$WORK/b-direct"
"$ZONEHUNT" --repo "$REPO" --out "$OUTB2" \
  --drop-dir "$OUTB2/drop" --scope-hint contracts --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" --pass-fixture "$PASS_FIXTURE" \
  --in-scope "the whole in-scope program" --run-cell-budget 5 \
  >"$WORK/b2.out" 2>"$WORK/b2.err"
RCB2=$?
[ "$RCB2" -eq 0 ] || bad "B: the direct run-zone-hunt.sh control exited $RCB2"
[ "$RCB1" -eq 5 ] && ok "B: a breadth-only sweep that leaves gaps exits 5 (never a silent success)" \
  || bad "B: expected exit 5 from the breadth-only sweep, got $RCB1"
if [ "$(hunt_zone_count "$WORK/b1.err")" -eq "$(hunt_zone_count "$WORK/b2.err")" ] \
   && [ "$(rehunt_pass_count "$WORK/b1.err")" -eq 0 ]; then
  ok "B: --max-rehunt-passes 0 ran exactly ONE inner pass, hunting the same zones as the direct invocation"
else
  bad "B: the breadth-only sweep did not run exactly one inner pass"
fi
if cmp -s "$OUTB1/discovery/discovery-results.merged.json" "$OUTB2/discovery/discovery-results.merged.json"; then
  ok "B: discovery-results.merged.json is BYTE-IDENTICAL to the direct run-zone-hunt.sh invocation's"
else
  bad "B: the merged artifact differs from the direct invocation's"
fi
if python3 - "$OUTB1/coverage/zone-coverage.json" "$OUTB2/coverage/zone-coverage.json" <<'PY'
import sys, json
def strip(p):
    d = json.load(open(p, encoding="utf-8"))
    d.pop("started_at", None)
    d.pop("updated_at", None)
    for z in d["zones"]:
        z["started_at"] = z["ended_at"] = ""
    return d
a, b = strip(sys.argv[1]), strip(sys.argv[2])
assert a == b, "the coverage records differ beyond timestamps"
PY
then ok "B: the two coverage records are identical once started_at/updated_at/ended_at are dropped"
else bad "B: the coverage records differ beyond their timestamps"
fi
# Belt and braces on the strongest form of default-inertness available: the file below the sweep is untouched.
if grep -q 'run-zone-sweep' "$ZONEHUNT"; then
  bad "B: run-zone-hunt.sh references the sweep — the layering is inverted"
else
  ok "B: run-zone-hunt.sh has no knowledge of the sweep at all (the new layer is strictly above it)"
fi

# ----------------------------------------------------------------------------------------------------------
# (C) BOUNDEDNESS — the spin the plan is built around. With --run-cell-budget 4 and the vault zone failing:
#     pass 1 leaves a MIXED gap set (failed + budget_truncated + budget_exhausted), so the policy legitimately
#     says rehunt_now; the re-hunt then closes NOTHING (the failing zone fails again and the budget just moves
#     the truncation around). With --budget-ceiling 0 there is no headroom, so the no-progress guard stops it.
#     Without the two bounds this case runs forever: the `budget_exhausted` zone never becomes `capped`.
# ----------------------------------------------------------------------------------------------------------
note "C) boundedness: a re-hunt that closes nothing terminates (the budget_exhausted spin) ..."
OUTC="$WORK/c"
export DEMO_FAIL_ZONE=contracts_vault
sweep "$OUTC" -- \
  --drop-dir "$OUTC/drop" --scope-hint contracts --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" --pass-fixture "$PASS_FIXTURE" \
  --in-scope "the whole in-scope program" --run-cell-budget 4 \
  >"$WORK/c.out" 2>"$WORK/c.err"
RCC=$?
unset DEMO_FAIL_ZONE
[ "$RCC" -eq 5 ] && ok "C: the sweep exits 5 with gaps remaining (the report is written, not swallowed)" \
  || { bad "C: expected exit 5, got $RCC"; sed 's/^/      /' "$WORK/c.err" | tail -20 >&2; }
if [ "$(rehunt_pass_count "$WORK/c.err")" -le 2 ] && grep -q '\[policy\] give_up (reason=no_progress' "$WORK/c.err"; then
  ok "C: the loop stopped at give_up|no_progress within --max-rehunt-passes, without an operator"
else
  bad "C: the no-progress guard did not stop the loop"
  sed 's/^/      /' "$WORK/c.err" | grep policy >&2
fi
# THE SPIN CONDITION ITSELF: prove the record could NOT have bounded this loop.
if python3 - "$OUTC" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
led = json.load(open(os.path.join(out, "coverage", "gap-remediation.json"), encoding="utf-8"))
by_id = dict((z["id"], z) for z in rec["zones"])
denied = [z for z in rec["zones"] if z["status"] == "budget_exhausted"]
assert denied, "the fixture no longer produces a budget_exhausted zone — block (C) proves nothing"
for z in denied:
    assert z["attempts"] == [], \
        "%s gained an attempts[] entry — the finding this bound exists for no longer holds" % z["id"]
# The gap set really did not shrink: that is what the no-progress guard fired on.
rehunts = [p for p in led["passes"] if p["decision"] != "initial"]
assert rehunts, "no re-hunt pass ran, so the no-progress guard was never exercised"
assert rehunts[-1]["closed"] == [], "the last re-hunt DID close something: %r" % rehunts[-1]["closed"]
assert led["terminal_reason"] == "no_progress", led["terminal_reason"]
assert rec["complete"] is False
PY
then ok "C: the denied zone has attempts == [] — --rehunt-max-attempts could never have capped it (the finding holds)"
else bad "C: the spin-condition assertion failed"
fi
if grep -q 'Remaining gaps' "$OUTC/coverage/gap-report.md" \
   && grep -q 'raise --budget-ceiling' "$OUTC/coverage/gap-report.md"; then
  ok "C: the report names the remaining gaps and the knob that would go further"
else
  bad "C: the remaining-gap explanation is missing from the report"
fi
# THE SECOND, INDEPENDENT BOUND. The two bounds are deliberately redundant, so each must be pinned on its own:
# the same fixture at --max-rehunt-passes 1 stops on the SWEEP's own ceiling (before the policy is even asked
# a second time), which is the bound that survives any change to the rule.
OUTC2="$WORK/c2"
export DEMO_FAIL_ZONE=contracts_vault
sweep "$OUTC2" --max-rehunt-passes 1 -- \
  --drop-dir "$OUTC2/drop" --scope-hint contracts --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" --pass-fixture "$PASS_FIXTURE" \
  --in-scope "the whole in-scope program" --run-cell-budget 4 \
  >"$WORK/c2.out" 2>"$WORK/c2.err"
RCC2=$?
unset DEMO_FAIL_ZONE
if [ "$RCC2" -eq 5 ] && [ "$(rehunt_pass_count "$WORK/c2.err")" -eq 1 ] \
   && grep -q 're-hunt pass(es) done, --max-rehunt-passes is 1' "$WORK/c2.err" \
   && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["terminal_reason"]=="pass_ceiling" else 1)' \
        "$OUTC2/coverage/gap-remediation.json"; then
  ok "C: --max-rehunt-passes is enforced by the SWEEP itself — the loop stops after exactly 1 re-hunt pass"
else
  bad "C: the sweep's own pass ceiling did not stop the loop (exit $RCC2)"
  sed 's/^/      /' "$WORK/c2.err" | grep -E 'policy|--max-rehunt' >&2
fi
# THE THIRD BOUND, end to end. A `budget_unenforceable` zone (two zones sharing one scope.tsv subsystem name,
# so no --classes prefix lands exactly on the cap — #1830 block (m)) is the WORST case: it never transitions,
# never gains an attempt, and is re-emitted as `hunt` on every pass forever. It is stopped BEFORE any re-hunt
# runs, because every actionable gap is a budget denial and --budget-ceiling defaults to 0.
REPO_C3="$WORK/target-dupname"
mkdir -p "$REPO_C3/contracts/v1" "$REPO_C3/contracts/v2" "$REPO_C3/contracts/solo"
printf 'contract A { function f() public {} function g() public {} }\n' > "$REPO_C3/contracts/v1/A.sol"
printf 'contract B { function f() public {} function g() public {} }\n' > "$REPO_C3/contracts/v2/B.sol"
printf 'contract C { function h() public {} }\n' > "$REPO_C3/contracts/solo/C.sol"
git -C "$REPO_C3" init -q
git -C "$REPO_C3" config user.email demo@example.invalid
git -C "$REPO_C3" config user.name "demo"
git -C "$REPO_C3" add -A
git -C "$REPO_C3" commit -qm "audited baseline"
ZONES_C3="$WORK/zones-dupname.fixture.txt"
{
  echo "ZONE|contracts_v1|vault|C1,C6,C11|first vault dir"
  echo "ZONE|contracts_v2|vault|C2,C9|second vault dir with the SAME name"
  echo "ZONE|contracts_solo|solo keeper|C6|uniquely named, 1 cell"
  echo "CUSTODY|contracts_v1|true"
  echo "CUSTODY|contracts_v2|true"
  echo "CUSTODY|contracts_solo|false"
} > "$ZONES_C3"
BRIEFS_C3="$WORK/briefs-dupname.fixture.txt"
{
  for _z in contracts_v1 contracts_v2 contracts_solo; do
    echo "DARK-FACTORY:BRIEF-BEGIN|$_z"
    echo "Break it."
    echo "DARK-FACTORY:BRIEF-END"
  done
} > "$BRIEFS_C3"
OUTC3="$WORK/c3"
export SWEEP_REPO="$REPO_C3"
sweep "$OUTC3" -- \
  --drop-dir "$OUTC3/drop" --scope-hint contracts --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_C3" --brief-fixture "$BRIEFS_C3" --pass-fixture "$PASS_FIXTURE" \
  --in-scope "the whole in-scope program" --zone-cell-budget 2 \
  >"$WORK/c3.out" 2>"$WORK/c3.err"
RCC3=$?
unset SWEEP_REPO
if [ "$RCC3" -eq 5 ] && [ "$(rehunt_pass_count "$WORK/c3.err")" -eq 0 ] \
   && grep -q '\[policy\] give_up (reason=budget_ceiling' "$WORK/c3.err" \
   && python3 - "$OUTC3" <<'PY'
import sys, os, json
rec = json.load(open(os.path.join(sys.argv[1], "coverage", "zone-coverage.json"), encoding="utf-8"))
stuck = [z for z in rec["zones"] if z["status"] == "budget_unenforceable"]
assert stuck, "the fixture no longer produces a budget_unenforceable zone"
for z in stuck:
    assert z["attempts"] == [], "%s gained an attempts[] entry" % z["id"]
PY
then ok "C: an UNENFORCEABLE-cap zone (never transitions, never gains an attempt) stops at give_up|budget_ceiling before any re-hunt"
else
  bad "C: the unenforceable-cap zone did not stop the sweep before a re-hunt (exit $RCC3)"
  sed 's/^/      /' "$WORK/c3.err" | grep policy >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (D) NON-RETRYABLE DEFECTS. A zone in zones.json with NO line in scope.tsv runs zero cells and is `unscoped`
#     (#1830 block (k)). A re-hunt against the same map cannot fix it, so the sweep must REPORT `remap_target`
#     and run no pass at all — re-running STAGE 1/2 by itself would invalidate the record it is reasoning over.
# ----------------------------------------------------------------------------------------------------------
note "D) non-retryable defects: an unscoped zone yields remap_target and ZERO re-hunt passes ..."
REPO_D="$WORK/target-unscoped"
mkdir -p "$REPO_D"
cp -R "$FIXTURE_DIR/contracts" "$REPO_D/contracts"
rm -rf "$REPO_D/contracts/registry"
mkdir -p "$REPO_D/contracts/rewards"
printf 'contract Rewards { function claim() public {} function accrue() public {} }\n' \
  > "$REPO_D/contracts/rewards/Rewards.sol"
git -C "$REPO_D" init -q
git -C "$REPO_D" config user.email demo@example.invalid
git -C "$REPO_D" config user.name "demo"
git -C "$REPO_D" add -A
git -C "$REPO_D" commit -qm "audited baseline"
# contracts_rewards has no ZONE| line in the fixture, so map-zones.sh writes no scope.tsv line for it while
# gen-briefs.sh (which iterates zones.json) still gives it a brief: the exact `unscoped` shape.
BRIEFS_D="$WORK/briefs-unscoped.fixture.txt"
cp "$BRIEFS_FIXTURE" "$BRIEFS_D"
{
  echo "DARK-FACTORY:BRIEF-BEGIN|contracts_rewards"
  echo "Attack the reward accrual accounting."
  echo "DARK-FACTORY:BRIEF-END"
} >> "$BRIEFS_D"
OUTD="$WORK/d"
export SWEEP_REPO="$REPO_D"
sweep "$OUTD" -- \
  --drop-dir "$OUTD/drop" --scope-hint contracts --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_D" --pass-fixture "$PASS_FIXTURE" \
  --in-scope "the whole in-scope program" \
  >"$WORK/d.out" 2>"$WORK/d.err"
RCD=$?
unset SWEEP_REPO
if [ "$RCD" -eq 5 ] && [ "$(rehunt_pass_count "$WORK/d.err")" -eq 0 ] \
   && grep -q '\[policy\] remap_target' "$WORK/d.err"; then
  ok "D: remap_target is REPORTED, zero re-hunt passes run, exit 5"
else
  bad "D: the remap_target path did not behave as expected (exit $RCD)"
  sed 's/^/      /' "$WORK/d.err" | tail -20 >&2
fi
if python3 - "$OUTD" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
led = json.load(open(os.path.join(out, "coverage", "gap-remediation.json"), encoding="utf-8"))
by_id = dict((z["id"], z) for z in rec["zones"])
assert by_id["contracts_rewards"]["status"] == "unscoped", by_id["contracts_rewards"]["status"]
assert led["terminal_reason"] == "upstream_defect", led["terminal_reason"]
assert len(led["passes"]) == 1, "a pass ran anyway: %r" % [p["decision"] for p in led["passes"]]
PY
then ok "D: the ledger records exactly one (breadth) pass and terminal_reason=upstream_defect"
else bad "D: the remap_target ledger assertion failed"
fi
if grep -q 'contracts_rewards' "$OUTD/coverage/gap-report.md" \
   && grep -q 're-map the target' "$OUTD/coverage/gap-report.md"; then
  ok "D: the report names the zone and says a re-hunt cannot fix it"
else
  bad "D: the report does not explain the unscoped zone"
fi

# ----------------------------------------------------------------------------------------------------------
# (E) ATTEMPT CEILING. Prepare an --out whose governance zone already carries one recorded attempt (a direct
#     breadth pass + a direct --rehunt-gaps pass, both with the zone failing), then sweep it with
#     --rehunt-max-attempts 1: the only gap is already at the ceiling, so the sweep must decide and stop.
# ----------------------------------------------------------------------------------------------------------
note "E) attempt ceiling: a failed zone already at the ceiling yields zero re-hunt passes ..."
OUTE="$WORK/e"
DEMO_FAIL_ZONE=contracts_governance "$ZONEHUNT" --repo "$REPO" --out "$OUTE" \
  --drop-dir "$OUTE/drop" --scope-hint contracts --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" --pass-fixture "$PASS_FIXTURE" \
  --in-scope "the whole in-scope program" >/dev/null 2>&1
DEMO_FAIL_ZONE=contracts_governance "$ZONEHUNT" --repo "$REPO" --out "$OUTE" \
  --drop-dir "$OUTE/drop" --backend mock --agentis "$STUB" --pass-fixture "$PASS_FIXTURE" \
  --in-scope "the whole in-scope program" --rehunt-gaps >/dev/null 2>&1
export DEMO_FAIL_ZONE=contracts_governance
sweep "$OUTE" --rehunt-max-attempts 1 -- \
  --drop-dir "$OUTE/drop" --scope-hint contracts --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" --pass-fixture "$PASS_FIXTURE" \
  --in-scope "the whole in-scope program" \
  >"$WORK/e.out" 2>"$WORK/e.err"
RCE=$?
unset DEMO_FAIL_ZONE
if [ "$RCE" -eq 5 ] && [ "$(rehunt_pass_count "$WORK/e.err")" -eq 0 ] \
   && grep -q '\[policy\] give_up (reason=attempt_ceiling' "$WORK/e.err"; then
  ok "E: give_up|attempt_ceiling, zero re-hunt passes, exit 5"
else
  bad "E: the attempt-ceiling path did not behave as expected (exit $RCE)"
  sed 's/^/      /' "$WORK/e.err" | tail -20 >&2
fi
if python3 - "$OUTE" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
led = json.load(open(os.path.join(out, "coverage", "gap-remediation.json"), encoding="utf-8"))
gov = dict((z["id"], z) for z in rec["zones"])["contracts_governance"]
assert gov["status"] == "failed", gov["status"]
assert len(gov["attempts"]) >= 1, "the prepared attempt history was lost: %r" % gov["attempts"]
assert led["terminal_reason"] == "attempt_ceiling", led["terminal_reason"]
PY
then ok "E: the attempt history survived the sweep's own breadth pass and drove the terminal reason"
else bad "E: the attempt-ceiling ledger assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (F) FLAG VALIDATION + ABORT HONESTY (the #1717/#1830 badflag idiom — no heavy stage runs).
# ----------------------------------------------------------------------------------------------------------
note "F) flag validation and abort honesty ..."
badflag() {
  bf_desc="$1"; bf_expect="$2"; shift 2
  bf_err="$WORK/badflag.err"
  "$SWEEP" --repo "$REPO" --out "$WORK/badflag-out" "$@" >/dev/null 2>"$bf_err"
  bf_rc=$?
  if [ "$bf_rc" -eq 2 ] && grep -q -- "$bf_expect" "$bf_err"; then
    ok "$bf_desc fails fast with exit 2 + the usage error"
  else
    bad "$bf_desc did not fail fast as expected (exit $bf_rc):"
    sed 's/^/      /' "$bf_err" | head -5 >&2
  fi
}
badflag "a passthrough --rehunt-gaps" 'owned by the sweep' -- --rehunt-gaps
badflag "a passthrough --rehunt-max-attempts" 'owned by the sweep' -- --rehunt-max-attempts 3
badflag "a passthrough --rehunt-include-partial" 'owned by the sweep' -- --rehunt-include-partial
badflag "a passthrough --deep-hunt-only" 'mutually exclusive with a re-hunt' -- --deep-hunt-only
badflag "--max-rehunt-passes notanumber" 'must be a non-negative integer' --max-rehunt-passes notanumber
badflag "--budget-ceiling -1" 'must be a non-negative integer' --budget-ceiling -1
badflag "--rehunt-max-attempts 0" 'must be >= 1' --rehunt-max-attempts 0
badflag "a run-zone-hunt.sh flag before --" 'unknown flag' --run-cell-budget 5
# ABORT HONESTY: the inner pass fails on its OWN usage error; the sweep propagates it AND still writes both
# artifacts. An incomplete sweep is never silent, including when it never got to hunt anything.
OUTF="$WORK/f-abort"
sweep "$OUTF" -- --jobs 0 --backend mock --agentis "$STUB" >"$WORK/f.out" 2>"$WORK/f.err"
RCF=$?
if [ "$RCF" -ne 0 ] && [ -f "$OUTF/coverage/gap-remediation.json" ] && [ -f "$OUTF/coverage/gap-report.md" ] \
   && grep -q 'No coverage record was written' "$OUTF/coverage/gap-report.md" \
   && grep -q 'gap remediation report' "$WORK/f.err"; then
  ok "F: an aborted inner pass propagates non-zero AND still leaves the ledger + a report saying what happened"
else
  bad "F: the abort path did not leave an honest report (exit $RCF)"
  sed 's/^/      /' "$WORK/f.err" | tail -10 >&2
fi

# (#1849) The DOCUMENTED BOUNDARY of "never silent": a usage error returns before the sweep exists, so it
# writes no report — and must not, since there is nothing to report and possibly no --out to report into. It
# is loud on stderr instead. Pinned so the boundary stays a decision rather than drifting either way: if a
# future change starts writing an empty report here, or stops being loud, this fails.
OUTG="$WORK/g-usage"
"$SWEEP" --repo "$REPO" --out "$OUTG" --budget-ceiling -1 >/dev/null 2>"$WORK/g.err"
RCG=$?
if [ "$RCG" -eq 2 ] && [ ! -f "$OUTG/coverage/gap-report.md" ] && [ ! -f "$OUTG/coverage/gap-remediation.json" ] \
   && grep -q 'must be a non-negative integer' "$WORK/g.err"; then
  ok "F: a usage error exits 2 loudly with NO report — the documented boundary of the never-silent rule"
else
  bad "F: the usage-error boundary drifted (exit $RCG; report present? $([ -f "$OUTG/coverage/gap-report.md" ] && echo yes || echo no))"
  sed 's/^/      /' "$WORK/g.err" | tail -5 >&2
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — run-zone-sweep.sh (#1828 M3: autonomy, inertness, boundedness, defects, ceiling, validation) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
