#!/usr/bin/env bash
# demo-gap-policy.sh — OFFLINE, DETERMINISTIC proof of #1828 M1 (the gap-CLASSIFICATION contract) and M2 (the
# gap-REMEDIATION policy). No agentis, no LLM, no network, no hunt: every assertion reads a checked-in
# `zone-coverage/v1` record under fixtures/coverage/ and one subprocess call to the shipped helpers.
#
# Assertions:
#   (1) CLASSIFICATION — over `all-statuses.zone-coverage.json` (one zone per status in #1830's closed
#       vocabulary, plus a zone at the attempt ceiling, a `budget_truncated` zone and a `hunted_degraded` one):
#       1.1  `hunt` for exactly not_reached | budget_exhausted | budget_unenforceable
#       1.2  `retry` for exactly in_flight | failed (the artifact-bearing statuses)
#       1.3  `no-brief` / `unscoped` are emitted as themselves and are NEVER hunt/retry — an upstream defect is
#            not collapsed into a retryable failure
#       1.4  a zone at >= --max-attempts becomes `capped`
#       1.5  a CLEAN zone emits nothing at all
#       1.6  PARTIALS appear only under --include-partial
#       1.7  THE SUPERSET RELATION: `gaps` (TSV) is a STRICT subset of `summary --json`.gap_zones. A consumer
#            that confuses the two would act on a partial it was never asked to re-hunt.
#       1.8  THE BOUND FINDING: a `budget_exhausted` zone with `attempts: []` stays `hunt` at ANY
#            --max-attempts — the record's attempt ceiling bounds only the artifact-bearing statuses, which is
#            exactly why run-zone-sweep.sh must carry its own pass bound.
#   (2) POLICY — one expected verb (+ args) per decision fixture, including both sides of the budget branch
#       and the no-progress guard. The rule is deterministic: same inputs, same verb, every time.
#
# Usage:  dark-factory/demo-gap-policy.sh
# Requires: python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', no process substitution, literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ZONECOV="$HERE/lib/zone-coverage.py"
GAPPOLICY="$HERE/lib/gap-policy.py"
FIX="$HERE/fixtures/coverage"

FAILS=0
note() { echo "demo-gap-policy.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -f "$ZONECOV" ]   || { note "helper not found: $ZONECOV" >&2; exit 3; }
[ -f "$GAPPOLICY" ] || { note "helper not found: $GAPPOLICY" >&2; exit 3; }
[ -d "$FIX" ]       || { note "fixtures not found: $FIX" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-gap-policy.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ALL="$FIX/all-statuses.zone-coverage.json"

# ----------------------------------------------------------------------------------------------------------
# (1) CLASSIFICATION — the rule #1830 already implements, PINNED so a change to RETRYABLE_STATUSES (or a
#     dropped no_brief/unscoped exclusion) fails CI here instead of silently changing what a re-hunt acts on.
# ----------------------------------------------------------------------------------------------------------
note "1) the gap-classification contract (zone-coverage.py gaps) ..."
TSV="$WORK/gaps.tsv"
python3 "$ZONECOV" gaps --file "$ALL" --max-attempts 2 > "$TSV" 2>"$WORK/gaps.err"
if [ $? -ne 0 ]; then
  bad "1.0: zone-coverage.py gaps failed over the fixture"
  sed 's/^/      /' "$WORK/gaps.err" | head -5 >&2
fi

# action_of <zone-id>  -> the action column, or the empty string when the zone is not in the work list at all.
action_of() {
  ao_zid="$1"; ao_file="${2:-$TSV}"
  awk -F'\t' -v z="$ao_zid" '$1 == z { print $3 }' "$ao_file"
}
expect_action() {
  ea_desc="$1"; ea_zid="$2"; ea_want="$3"; ea_file="${4:-$TSV}"
  ea_got="$(action_of "$ea_zid" "$ea_file")"
  if [ "$ea_got" = "$ea_want" ]; then
    ok "$ea_desc"
  else
    bad "$ea_desc — got '$ea_got', expected '$ea_want'"
  fi
}

# 1.1 / 1.2: the two retryable groups, split by whether prior artifacts exist.
expect_action "1.1: not_reached is a plain first attempt (hunt)"          z05_not_reached        hunt
expect_action "1.1: budget_exhausted is a plain first attempt (hunt)"     z06_budget_exhausted   hunt
expect_action "1.1: budget_unenforceable is a plain first attempt (hunt)" z07_budget_unenforceable hunt
expect_action "1.2: in_flight carries artifacts (retry)"                  z08_in_flight          retry
expect_action "1.2: failed carries artifacts (retry)"                     z09_failed             retry
# 1.3: the two UPSTREAM defects. They ARE in the work list (so a caller can report them) but never as work.
expect_action "1.3: no_brief is emitted as no-brief, never hunt/retry"    z11_no_brief           no-brief
expect_action "1.3: unscoped is emitted as unscoped, never hunt/retry"    z12_unscoped           unscoped
# 1.4: the attempt ceiling, on a status that HAS attempts.
expect_action "1.4: a failed zone at >= --max-attempts becomes capped"    z10_failed_capped      capped
# 1.5: a clean zone contributes nothing at all.
expect_action "1.5: a hunted zone is absent from the work list"           z01_hunted             ""
expect_action "1.5: a hunted_empty zone is absent from the work list"     z02_hunted_empty       ""
# 1.6: partials are gaps, but they are NOT work unless the caller says so.
expect_action "1.6: a budget_truncated zone is absent by default"         z03_truncated          ""
expect_action "1.6: a hunted_degraded zone is absent by default"          z04_degraded           ""
TSVP="$WORK/gaps-partial.tsv"
python3 "$ZONECOV" gaps --file "$ALL" --max-attempts 2 --include-partial > "$TSVP"
expect_action "1.6: --include-partial reaches the budget_truncated zone (retry)" z03_truncated retry "$TSVP"
expect_action "1.6: --include-partial reaches the hunted_degraded zone (retry)"  z04_degraded  retry "$TSVP"

# 1.7 THE SUPERSET RELATION. `gap_zones` is what the RECORD calls a gap; the TSV is what a RE-HUNT may act on.
#     They are deliberately different sets, and the policy must read actionability from the TSV only.
if python3 - "$ALL" "$TSV" "$TSVP" <<'PY'
import sys, json, subprocess, os
rec = json.load(open(sys.argv[1], encoding="utf-8"))
gap_zones = set(rec["gap_zones"])
tsv = set(l.split("\t")[0] for l in open(sys.argv[2], encoding="utf-8").read().splitlines() if l.strip())
tsvp = set(l.split("\t")[0] for l in open(sys.argv[3], encoding="utf-8").read().splitlines() if l.strip())
assert tsv <= gap_zones, "the work list is not a subset of gap_zones: %r" % sorted(tsv - gap_zones)
assert tsv < gap_zones, "gap_zones is NOT a strict superset — the fixture no longer covers the partial case"
assert tsvp <= gap_zones, "the --include-partial work list escapes gap_zones: %r" % sorted(tsvp - gap_zones)
missing = gap_zones - tsv
assert missing == {"z03_truncated", "z04_degraded"}, \
    "the zones in gap_zones but not in the default work list are %r" % sorted(missing)
PY
then ok "1.7: the gaps TSV is a STRICT subset of summary --json.gap_zones (the partials are the difference)"
else bad "1.7: the gaps/gap_zones superset relation assertion failed"
fi

# 1.8 THE FINDING run-zone-sweep.sh is built around: a zone denied on ADMISSION has no attempts[] entry, so no
#     value of --max-attempts ever caps it. A loop bounded by the record alone would spin on it forever.
BOUND_OK=1
for n in 1 2 3 99; do
  ATSV="$WORK/gaps-max$n.tsv"
  python3 "$ZONECOV" gaps --file "$ALL" --max-attempts "$n" > "$ATSV"
  [ "$(action_of z06_budget_exhausted "$ATSV")" = "hunt" ] || BOUND_OK=0
done
if [ "$BOUND_OK" -eq 1 ]; then
  ok "1.8: a budget_exhausted zone stays 'hunt' at --max-attempts 1/2/3/99 — the record's ceiling cannot bound it"
else
  bad "1.8: a budget_exhausted zone became capped — the sweep's own pass bound is no longer the load-bearing one"
fi

# ----------------------------------------------------------------------------------------------------------
# (2) POLICY — one verb per decision case. gap-policy.py never re-derives classification; it shells out to the
#     helper above, so a duplicated constant that drifts fails block (1) first.
# ----------------------------------------------------------------------------------------------------------
note "2) the remediation policy (gap-policy.py decide) ..."
DEC="$WORK/decision.txt"
decide() {
  dc_cov="$1"; shift
  python3 "$GAPPOLICY" decide --coverage "$FIX/$dc_cov" "$@" > "$DEC" 2>"$WORK/decide.err"
}
# expect_decision <desc> <coverage-fixture> <verb> <args-substring> [-- extra decide flags ...]
expect_decision() {
  ed_desc="$1"; ed_cov="$2"; ed_verb="$3"; ed_args="$4"; shift 4
  [ "${1:-}" != "--" ] || shift
  if ! decide "$ed_cov" "$@"; then
    bad "$ed_desc — gap-policy.py decide exited non-zero"
    sed 's/^/      /' "$WORK/decide.err" | head -5 >&2
    return
  fi
  ed_line="$(cat "$DEC")"
  ed_got_verb="$(printf '%s\n' "$ed_line" | cut -d'|' -f2)"
  ed_got_args="$(printf '%s\n' "$ed_line" | cut -d'|' -f3)"
  if [ "$ed_got_verb" = "$ed_verb" ] && [ "${ed_got_args#*"$ed_args"}" != "$ed_got_args" ]; then
    ok "$ed_desc"
  else
    bad "$ed_desc — got '$ed_got_verb|$ed_got_args', expected '$ed_verb' carrying '$ed_args'"
  fi
}

expect_decision "2.1: a plain gap (not_reached) -> rehunt_now" \
  gap-only.zone-coverage.json rehunt_now "reason=actionable_gaps"
expect_decision "2.2: every gap at the attempt ceiling -> give_up|attempt_ceiling" \
  attempt-ceiling.zone-coverage.json give_up "reason=attempt_ceiling"
expect_decision "2.3: budget denials with the DEFAULT ceiling 0 -> give_up|budget_ceiling (no raise is permitted)" \
  budget-denied.zone-coverage.json give_up "reason=budget_ceiling"
expect_decision "2.4: budget denials with an authorized ceiling -> raise_budget_and_rehunt to the CEILING" \
  budget-denied.zone-coverage.json raise_budget_and_rehunt "run_cell_budget=20" -- --budget-ceiling 20
expect_decision "2.4: ... and it carries zone_cell_budget=0 because an actionable zone is budget_unenforceable" \
  budget-denied.zone-coverage.json raise_budget_and_rehunt "zone_cell_budget=0" -- --budget-ceiling 20
expect_decision "2.5: only upstream defects left -> remap_target (a REPORTED decision, never an action)" \
  defect-only.zone-coverage.json remap_target "reason=upstream_defect"
expect_decision "2.6: only PARTIAL gaps left -> give_up|partial_only (naming the flag that would act on them)" \
  partial-only.zone-coverage.json give_up "reason=partial_only"
expect_decision "2.7: a complete record -> give_up|nothing_actionable" \
  complete.zone-coverage.json give_up "reason=nothing_actionable"
# 2.8 THE NO-PROGRESS GUARD: the previous pass was a plain re-hunt and closed nothing, so the identical action
#     provably repeats. With no authorized headroom the rule must STOP, never re-issue the same rehunt_now.
expect_decision "2.8: a re-hunt that closed nothing -> give_up|no_progress, NOT a second identical rehunt_now" \
  gap-only.zone-coverage.json give_up "reason=no_progress" -- --ledger "$FIX/no-progress.gap-remediation.json"
expect_decision "2.8: ... and with headroom it ESCALATES to the budget branch instead of repeating" \
  gap-only.zone-coverage.json raise_budget_and_rehunt "reason=no_progress" \
  -- --ledger "$FIX/no-progress.gap-remediation.json" --budget-ceiling 9
# 2.9 THE PASS CEILING, evaluated BEFORE any of the above: it is the bound that does not read the record.
expect_decision "2.9: --max-passes already reached -> give_up|pass_ceiling (the bound the record cannot supply)" \
  gap-only.zone-coverage.json give_up "reason=pass_ceiling" \
  -- --ledger "$FIX/no-progress.gap-remediation.json" --max-passes 1
# 2.10 A raise is authorized ONCE: once the run budget IS the ceiling, the branch falls through to give_up.
expect_decision "2.10: at most ONE raise per sweep — a run budget already at the ceiling gives up" \
  budget-denied.zone-coverage.json give_up "reason=budget_ceiling" \
  -- --budget-ceiling 20 --run-cell-budget 20

# 2.11 DETERMINISM + the JSON shape the driver parses.
if python3 - "$GAPPOLICY" "$FIX/budget-denied.zone-coverage.json" <<'PY'
import sys, json, subprocess
gp, cov = sys.argv[1], sys.argv[2]
def run(*extra):
    out = subprocess.run([sys.executable, gp, "decide", "--coverage", cov] + list(extra),
                         stdout=subprocess.PIPE, universal_newlines=True, check=True).stdout
    return out
a, b = run(), run()
assert a == b, "the rule is not deterministic: %r != %r" % (a, b)
d = json.loads(run("--json", "--budget-ceiling", "20"))
assert d["verb"] == "raise_budget_and_rehunt", d["verb"]
assert d["args"]["run_cell_budget"] == "20", d["args"]
assert d["actionable"] == ["z02_budget_exhausted", "z03_budget_unenforceable"], d["actionable"]
assert d["complete"] is False
PY
then ok "2.11: the rule is deterministic and --json exposes the verb/args/actionable set the driver parses"
else bad "2.11: the determinism / --json shape assertion failed"
fi

# 2.12 The ledger is the durable account: `closed` is DERIVED from before/after, never asserted by the caller,
#      so the no-progress guard cannot be fed an optimistic claim.
LED="$WORK/ledger.json"
python3 "$GAPPOLICY" ledger init --file "$LED" >/dev/null
python3 "$GAPPOLICY" ledger append --file "$LED" --decision initial --gaps-before "" --gaps-after "a,b,c" >/dev/null
python3 "$GAPPOLICY" ledger append --file "$LED" --decision rehunt_now --gaps-before "a,b,c" --gaps-after "b" >/dev/null
if python3 - "$LED" <<'PY'
import sys, json
led = json.load(open(sys.argv[1], encoding="utf-8"))
assert led["schema"] == "gap-remediation/v1", led["schema"]
assert [p["n"] for p in led["passes"]] == [1, 2]
assert led["passes"][0]["closed"] == [], led["passes"][0]
assert led["passes"][1]["closed"] == ["a", "c"], led["passes"][1]["closed"]
assert led["closed"] == ["a", "c"], led["closed"]
assert led["remaining"] == ["b"], led["remaining"]
# The breadth pass is NOT a re-hunt pass — that is what keeps --max-rehunt-passes meaning what it says.
assert led["passes_done"] == 1, led["passes_done"]
PY
then ok "2.12: the ledger DERIVES closed[] from gaps_before/after and counts only re-hunt passes"
else bad "2.12: the ledger derivation assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #1828 gap-classification contract (M1) and remediation policy (M2) hold"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
