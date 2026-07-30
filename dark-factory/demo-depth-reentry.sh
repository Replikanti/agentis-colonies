#!/usr/bin/env bash
# demo-depth-reentry.sh — OFFLINE, DETERMINISTIC proof of the #1857 DEPTH-ONLY RE-ENTRY:
# run-discovery.sh's opt-in `--depth-from <discovery-results.json>` consumes a RECORDED run, seeds the cell
# accumulator with that run's BREADTH cells and hunts ONLY the depth pass over them. Two arms that differ
# only in `--depth-lens-quota` then share ONE breadth sample, which is the confound (#1850's four lost rows
# were unattributable because both arms re-hunted the stochastic breadth pass) this exists to remove.
#
# Every assertion runs against CHECKED-IN RECORDINGS of two real plaza `src` arms
# (bench/corpus-bench/fixtures/depth-reentry/) driven through the EXISTING `--agentis <bin>` seam by a fast
# offline stub: NO live agentis / forge / LLM / network, and no hunt is ever performed.
#
# Assertions:
#   1) QUOTA-1 ACCEPTANCE:  re-entering the recorded SPREAD arm at `--depth-lens-quota 1` reproduces that
#      run's own `depth-plan.tsv` (columns 1-3) EXACTLY, in order. This is the property the flag exists for:
#      the plan a re-entry computes IS the plan the original run computed.
#   2) QUOTA-3 ACCEPTANCE:  the same, on the recorded #1850 quota-3 arm at `--depth-lens-quota 3`. The PAIR
#      is what pins the allocation — forcing either quota fails exactly one of them.
#   3) THE DEPTH FILTER (correctness, not hygiene): the seed carries 6 breadth cells, and replaying the SAME
#      artifact UNFILTERED computes a DIFFERENT plan (extra C17/C5 lenses; `startAuction` outranks
#      `transferReserveToAuction`) — depth candidates feed back into the ranking and the lens order.
#   4) CARRIED CELLS VERBATIM: the seeded records are BYTE-FOR-BYTE the recorded ones, so
#      `verify-findings.sh` -> `score-match.py` score a depth-only arm exactly like a full run.
#   5) CARRIED TOTALS:      totals.cells = carried + depth, totals.candidates = carried + depth-produced,
#      and `depth_from` records the source, its repo and the carried counts.
#   6) --jobs EQUIVALENCE:  `--jobs 3` produces the identical depth sequence AND the identical carried set as
#      `--jobs 1` (the re-entry replaces the whole breadth pass, so parallelism cannot reach it).
#   7) DEFAULT-INERTNESS:   with no `--depth-from` the report is byte-identical to the checked-in golden and
#      `discovery-results.json` grows no `depth_from` key.
#   8) REPO REFUSAL:        a recording from a DIFFERENT target exits 3 naming both repos and leaves NO
#      output dir behind (every artifact-only refusal fires before the first side effect).
#   9) COMMIT REFUSAL + THE HONEST BANNER: a recording carrying a different `commit` exits 3 naming both
#      SHAs; a recording with NO commit (every artifact predating this flag) prints an UNVERIFIED banner and
#      RUNS — it must not be fatal, and the banner must not claim a check that was not made.
#  10) MISSING TARGET FILE: a plan whose target no longer exists under `--repo` exits 3 naming it — the one
#      guard that reaches the working tree.
#  11) NO BREADTH CELLS:    an all-depth (or empty) recording exits 3 rather than being planned as empty.
#  12) FLAG REFUSALS:       `--list-cells`, `--only`, `--classes`, `--scope` and `--depth-max-cells 0` each
#      exit 2 naming the flag — none of them can affect a plan derived from recorded cells.
#  13) NEVER-SUBMIT:        no network / submission verb on run-discovery.sh's executable lines.
#
# Usage:  dark-factory/demo-depth-reentry.sh
# Requires: python3 + git (assertion 9 [SKIP]s without git). Exit: 0 = all held.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', no process substitution, literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DISCOVERY="$HERE/run-discovery.sh"
FIX="$HERE/bench/corpus-bench/fixtures/depth-reentry"
GOLDEN="$HERE/fixtures/zone-map/discovery-report.golden.md"
SPREAD="$FIX/plaza-spread/discovery-results.json"
QUOTA3="$FIX/plaza-quota3/discovery-results.json"

FAILS=0
note() { echo "demo-depth-reentry.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$DISCOVERY" ] || { note "run-discovery.sh not found / not executable: $DISCOVERY" >&2; exit 3; }
[ -f "$GOLDEN" ]    || { note "golden report not found: $GOLDEN" >&2; exit 3; }
for f in "$SPREAD" "$QUOTA3" "$FIX/plaza-spread/depth-plan.expected.tsv" "$FIX/plaza-quota3/depth-plan.expected.tsv"; do
  [ -f "$f" ] || { note "fixture not found: $f" >&2; exit 3; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-depth-reentry.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# (a) Offline inputs.
#     The re-entry target is deliberately named `plaza-evm` — the basename the recordings carry — so the
#     provenance guard is EXERCISED by every run below, never bypassed. It holds empty stubs at exactly the
#     six paths the two recorded plans target (the depth-target existence guard reaches the working tree).
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target-root/plaza-evm"
mkdir -p "$REPO/src"
for c in Pool BondOracleAdapter Auction BalancerRouter LifiRouter OracleReader; do
  printf 'contract %s {}\n' "$c" > "$REPO/src/$c.sol"
done

BRIEF="$WORK/brief.md"
{
  printf '# Protocol brief (offline stub)\n'
  printf 'Invariants to break: share-price accounting, rounding, liquidation solvency.\n'
  printf 'Known issues to exclude: none.\n'
} > "$BRIEF"

# The fast offline stub through the --agentis seam. A depth cell mirrors hunter.ag's DEPTH-CELL| diagnostic
# and answers SAFE, so no depth candidate perturbs the carried accounting the assertions read.
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    if [ -n "${DEPTH_TARGET:-}" ]; then
      printf 'DEPTH-CELL|%s|%s|%s\n' "${SUBSYSTEM:-}" "${HUNT_CLASS:-}" "${DEPTH_TARGET:-}"
      printf 'SAFE\n'
      exit 0
    fi
    # The breadth reply used ONLY by the golden-corpus inertness run (7) — the re-entry never hunts breadth.
    printf 'CANDIDATE|%s:%s:1|%s|Medium|stub external exploit path|stub foundry PoC sketch\n' \
      "${SUBSYSTEM:-}" "${HUNT_CLASS:-}" "${HUNT_CLASS:-}"
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

# reentry <out-dir> <input> <extra flags...> — one depth-only re-entry through the shipped entrypoint.
reentry() {
  re_out="$1"; re_in="$2"; shift 2
  "$DISCOVERY" --repo "$REPO" --brief "$BRIEF" --backend mock --agentis "$STUB" \
    --out "$re_out" --depth-from "$re_in" "$@" >"$re_out.log" 2>"$re_out.err"
}

# ----------------------------------------------------------------------------------------------------------
# (1) QUOTA-1 ACCEPTANCE — the recorded SPREAD arm, replayed.
#     MUTATION: clamp the quota to >= 2 in _plan_depth_cells, or iterate locations before rounds
#     unconditionally — the emitted sequence stops matching the recording.
# ----------------------------------------------------------------------------------------------------------
note "1) re-entering the recorded spread arm at --depth-lens-quota 1 reproduces its depth plan ..."
Q1_OUT="$WORK/out-q1"
reentry "$Q1_OUT" "$SPREAD" --depth-max-cells 12 --depth-lens-quota 1
RC=$?
if [ "$RC" -eq 0 ]; then
  ok "the depth-only re-entry exits 0 against the recorded spread arm"
else
  bad "the depth-only re-entry exited $RC"; sed 's/^/      /' "$Q1_OUT.err" >&2
fi
cut -f1-3 "$Q1_OUT/run/depth-plan.tsv" > "$WORK/q1.plan" 2>/dev/null || : > "$WORK/q1.plan"
if cmp -s "$WORK/q1.plan" "$FIX/plaza-spread/depth-plan.expected.tsv"; then
  ok "1) the replayed plan is the recorded 12-row spread plan, in order (columns 1-3)"
else
  bad "1) the replayed plan diverged from the recording:"
  diff "$FIX/plaza-spread/depth-plan.expected.tsv" "$WORK/q1.plan" | sed 's/^/      /' >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (2) QUOTA-3 ACCEPTANCE — the recorded #1850 concentrated arm, replayed.
#     MUTATION: force quota = 1 in the round-robin — (2) fails while (1) still passes; the PAIR pins the
#     allocation, neither assertion does it alone.
# ----------------------------------------------------------------------------------------------------------
note "2) re-entering the recorded quota-3 arm at --depth-lens-quota 3 reproduces its depth plan ..."
Q3_OUT="$WORK/out-q3"
reentry "$Q3_OUT" "$QUOTA3" --depth-max-cells 12 --depth-lens-quota 3
RC=$?
[ "$RC" -eq 0 ] || { bad "2) the quota-3 re-entry exited $RC"; sed 's/^/      /' "$Q3_OUT.err" >&2; }
cut -f1-3 "$Q3_OUT/run/depth-plan.tsv" > "$WORK/q3.plan" 2>/dev/null || : > "$WORK/q3.plan"
if cmp -s "$WORK/q3.plan" "$FIX/plaza-quota3/depth-plan.expected.tsv"; then
  ok "2) the replayed plan is the recorded 12-row concentrated plan, in order (columns 1-3)"
else
  bad "2) the replayed quota-3 plan diverged from the recording:"
  diff "$FIX/plaza-quota3/depth-plan.expected.tsv" "$WORK/q3.plan" | sed 's/^/      /' >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (3) THE DEPTH FILTER is a CORRECTNESS requirement. A recorded file holds breadth AND depth cells; a depth
#     candidate fed back into the accumulator changes loc_count/loc_sev/loc_prod, which moves BOTH the
#     location ranking and the per-location lens order. Replaying the same artifact with the filter removed
#     is therefore a different experiment wearing the same name.
#     MUTATION: drop the `phase != "depth"` filter in the seed step.
# ----------------------------------------------------------------------------------------------------------
note "3) the seed carries breadth cells ONLY, and an unfiltered replay computes a different plan ..."
UNFILT="$WORK/unfiltered.json"
python3 - "$QUOTA3" "$UNFILT" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
for c in d["cells"]:
    c.pop("phase", None)            # the same records, with the only thing the filter reads removed
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
PY
UNF_OUT="$WORK/out-unfiltered"
reentry "$UNF_OUT" "$UNFILT" --depth-max-cells 12 --depth-lens-quota 3
cut -f1-3 "$UNF_OUT/run/depth-plan.tsv" > "$WORK/unf.plan" 2>/dev/null || : > "$WORK/unf.plan"
if python3 - "$Q3_OUT/discovery-results.json" "$WORK/q3.plan" "$WORK/unf.plan" <<'PY'
import sys
import json
d = json.load(open(sys.argv[1], encoding="utf-8"))
carried = [c for c in d["cells"] if c.get("phase") != "depth"]
assert len(carried) == 6, "the seed carried %d cells, expected the 6 breadth ones" % len(carried)
assert d["depth_from"]["carried_cells"] == 6, "depth_from.carried_cells is %r" % d["depth_from"]["carried_cells"]

def rows(p):
    out = []
    for line in open(p, encoding="utf-8"):
        line = line.rstrip("\n")
        if line:
            out.append(line.split("\t"))
    return out

filt, unfilt = rows(sys.argv[2]), rows(sys.argv[3])
assert filt != unfilt, "the unfiltered replay produced the SAME plan - the filter is not load-bearing here"
# The two DOCUMENTED differences, so this cannot pass on an unrelated divergence.
extra = set(r[1] for r in unfilt) - set(r[1] for r in filt)
assert {"C17", "C5"} <= extra, "the unfiltered plan did not gain the C17/C5 lenses: %r" % sorted(extra)
def rank(rs, fn):
    for i, r in enumerate(rs):
        if r[2].endswith("@" + fn):
            return i
    return 10 ** 6
assert rank(unfilt, "startAuction") < rank(unfilt, "transferReserveToAuction"), \
    "the unfiltered plan did not re-rank startAuction above transferReserveToAuction"
assert rank(filt, "transferReserveToAuction") < rank(filt, "startAuction"), \
    "the FILTERED plan lost the recorded ranking"
PY
then ok "3) exactly 6 breadth cells are seeded; the unfiltered replay gains C17/C5 and re-ranks startAuction"
else bad "3) the depth filter is not load-bearing / the seeded cell set is wrong"
fi

# ----------------------------------------------------------------------------------------------------------
# (4) CARRIED CELLS VERBATIM. The seeded records must be the SOURCE records byte-for-byte, which is what makes
#     a depth-only arm a drop-in for verify-findings.sh -> score-match.py.
#     MUTATION: sort_keys=True, ensure_ascii=True (both fixtures carry non-ASCII prose), or dropping a field.
# ----------------------------------------------------------------------------------------------------------
note "4) the carried breadth cells are byte-for-byte the recorded ones ..."
if python3 - "$QUOTA3" "$Q3_OUT/run/results-cells.jsonl" <<'PY'
import sys, json
src = json.load(open(sys.argv[1], encoding="utf-8"))
want = [json.dumps(c, ensure_ascii=False, separators=(",", ":"))
        for c in src["cells"] if c.get("phase") != "depth"]
got = [ln for ln in open(sys.argv[2], encoding="utf-8").read().split("\n") if ln][:len(want)]
assert got == want, "the seeded accumulator is not the recorded one:\n  got  %r\n  want %r" % (
    got[:1], want[:1])
PY
then ok "4) run/results-cells.jsonl opens with the recorded breadth cells, byte-for-byte"
else bad "4) the carried cells were re-serialised differently from the recording"
fi

# ----------------------------------------------------------------------------------------------------------
# (5) CARRIED TOTALS. A re-entry's counters continue the recorded run's rather than starting at zero, so its
#     totals are directly comparable with the source run's.
#     MUTATION: reset the counters to 0 instead of seeding them from the carried records.
# ----------------------------------------------------------------------------------------------------------
note "5) the totals carry the recorded breadth accounting ..."
if python3 - "$Q3_OUT/discovery-results.json" "$QUOTA3" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
src = json.load(open(sys.argv[2], encoding="utf-8"))
breadth = [c for c in src["cells"] if c.get("phase") != "depth"]
carried_cands = sum(len(c.get("candidates") or []) for c in breadth)
depth = [c for c in d["cells"] if c.get("phase") == "depth"]
assert d["totals"]["cells"] == len(breadth) + len(depth) == 6 + 12, "totals.cells is %r" % d["totals"]["cells"]
assert d["totals"]["depth_cells"] == 12, "totals.depth_cells is %r" % d["totals"]["depth_cells"]
found = sum(len(c.get("candidates") or []) for c in depth)
assert d["totals"]["candidates"] == carried_cands + found, \
    "totals.candidates is %r, expected carried %d + depth %d" % (d["totals"]["candidates"], carried_cands, found)
assert d["depth_from"]["carried_cells"] == 6, "depth_from.carried_cells is %r" % d["depth_from"]["carried_cells"]
assert d["depth_from"]["carried_candidates"] == carried_cands, "depth_from.carried_candidates is %r" % d["depth_from"]["carried_candidates"]
assert d["depth_from"]["repo"] == "plaza-evm", "depth_from.repo is %r" % d["depth_from"]["repo"]
PY
then ok "5) totals.cells = 6 carried + 12 depth, candidates = carried + depth-produced, depth_from records the source"
else bad "5) the carried totals are wrong"
fi

# ----------------------------------------------------------------------------------------------------------
# (6) --jobs EQUIVALENCE. The re-entry replaces the WHOLE breadth pass, so concurrency has nothing to reach;
#     the depth sequence and the carried set must be identical to the serial run's.
#     MUTATION: make the seed step order-dependent on --jobs.
# ----------------------------------------------------------------------------------------------------------
note "6) --jobs 3 produces the identical depth sequence and carried set as --jobs 1 ..."
J3_OUT="$WORK/out-q3-jobs3"
reentry "$J3_OUT" "$QUOTA3" --depth-max-cells 12 --depth-lens-quota 3 --jobs 3
RC=$?
[ "$RC" -eq 0 ] || { bad "6) the --jobs 3 re-entry exited $RC"; sed 's/^/      /' "$J3_OUT.err" >&2; }
cut -f1-3 "$J3_OUT/run/depth-plan.tsv" > "$WORK/j3.plan" 2>/dev/null || : > "$WORK/j3.plan"
if cmp -s "$WORK/j3.plan" "$WORK/q3.plan" && cmp -s "$J3_OUT/run/results-cells.jsonl" "$Q3_OUT/run/results-cells.jsonl"; then
  ok "6) the --jobs 3 depth plan and cell accumulator are identical to the serial ones"
else
  bad "6) --jobs 3 changed the depth-only re-entry"
fi

# ----------------------------------------------------------------------------------------------------------
# (7) DEFAULT-INERTNESS. With the flag absent the shipped path must be untouched: the report is byte-identical
#     to the checked-in golden and the JSON grows no depth_from key.
#     MUTATION: emit depth_from unconditionally, or let the new branch run when DEPTH_FROM is empty.
# ----------------------------------------------------------------------------------------------------------
note "7) with no --depth-from the shipped path is byte-identical (golden pin) ..."
GREPO="$WORK/target"
mkdir -p "$GREPO/contracts/vault" "$GREPO/contracts/rewards" "$GREPO/contracts/liquidation"
printf 'contract Vault {}\n'       > "$GREPO/contracts/vault/Vault.sol"
printf 'contract Rewards {}\n'     > "$GREPO/contracts/rewards/Rewards.sol"
printf 'contract Liquidation {}\n' > "$GREPO/contracts/liquidation/Liquidation.sol"
GSCOPE="$WORK/scope.tsv"
{
  printf 'vault deposits | C1,C6 | contracts/vault/Vault.sol\n'
  printf 'rewards distributor | C11 | contracts/rewards/Rewards.sol\n'
  printf 'liquidation engine | C10 | contracts/liquidation/Liquidation.sol\n'
} > "$GSCOPE"
INERT_OUT="$WORK/out-inert"
"$DISCOVERY" --repo "$GREPO" --scope "$GSCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$INERT_OUT" --jobs 1 >/dev/null 2>"$WORK/inert.err"
RC=$?
[ "$RC" -eq 0 ] || { bad "7) the no-flag run exited $RC"; sed 's/^/      /' "$WORK/inert.err" >&2; }
if cmp -s "$INERT_OUT/discovery-report.md" "$GOLDEN"; then
  ok "7) discovery-report.md is byte-for-byte identical to the golden (the shipped path is unchanged)"
else
  bad "7) the no-flag discovery-report.md diverged from the golden:"
  diff "$GOLDEN" "$INERT_OUT/discovery-report.md" | sed 's/^/      /' >&2
fi
if python3 - "$INERT_OUT/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert "depth_from" not in d, "a run without --depth-from grew a depth_from key: %r" % list(d)
# The provenance key ships on EVERY run (an additive, soft-git key); a non-git target degrades to "unknown".
assert "commit" in d, "discovery-results.json lost the commit provenance key: %r" % list(d)
PY
then ok "7) the no-flag JSON carries no depth_from key (and keeps the additive commit key)"
else bad "7) the depth_from key leaked into a run that did not ask for it"
fi

# ----------------------------------------------------------------------------------------------------------
# (8) REPO REFUSAL. A recording from a different target cannot be replayed here, and the refusal fires before
#     the output dir exists — a refused re-entry leaves nothing behind.
#     MUTATION: downgrade the mismatch to a warning.
# ----------------------------------------------------------------------------------------------------------
note "8) a recording from a DIFFERENT target is refused (exit 3) and leaves no output dir ..."
OTHER="$WORK/other-root/some-other-target"
mkdir -p "$OTHER/src"
for c in Pool BondOracleAdapter Auction BalancerRouter LifiRouter OracleReader; do
  printf 'contract %s {}\n' "$c" > "$OTHER/src/$c.sol"
done
R8_OUT="$WORK/out-wrong-repo"
"$DISCOVERY" --repo "$OTHER" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$R8_OUT" --depth-from "$SPREAD" --depth-max-cells 12 >/dev/null 2>"$WORK/r8.err"
RC=$?
if [ "$RC" -eq 3 ]; then ok "8) the repo mismatch exits 3"; else bad "8) the repo mismatch exited $RC, expected 3"; fi
if grep -q 'plaza-evm' "$WORK/r8.err" && grep -q 'some-other-target' "$WORK/r8.err"; then
  ok "8) the refusal names BOTH the recorded repo and the one given"
else
  bad "8) the refusal does not name both repos:"; sed 's/^/      /' "$WORK/r8.err" >&2
fi
[ -d "$R8_OUT" ] && bad "8) the refused re-entry left an output dir behind at $R8_OUT" \
  || ok "8) no output dir was created by the refused re-entry"

# ----------------------------------------------------------------------------------------------------------
# (9) COMMIT REFUSAL + THE HONEST BANNER. From this change onward every run records `commit`, so a stale
#     checkout of the same repo IS detectable. An artifact recorded BEFORE it (both plaza arms, and every
#     other file on disk today) carries none — that case must print an UNVERIFIED banner and RUN, because
#     making it fatal would refuse every artifact that exists.
#     MUTATION: skip the commit comparison; or make the absent case fatal.
# ----------------------------------------------------------------------------------------------------------
note "9) a recorded commit that does not match the checkout is refused; an absent one is loudly UNVERIFIED ..."
if command -v git >/dev/null 2>&1; then
  GITREPO="$WORK/git-root/plaza-evm"
  mkdir -p "$GITREPO/src"
  for c in Pool BondOracleAdapter Auction BalancerRouter LifiRouter OracleReader; do
    printf 'contract %s {}\n' "$c" > "$GITREPO/src/$c.sol"
  done
  git -C "$GITREPO" init -q
  git -C "$GITREPO" config user.email demo@example.invalid
  git -C "$GITREPO" config user.name "demo"
  git -C "$GITREPO" add -A
  git -C "$GITREPO" commit -qm "recorded baseline"
  STALE="$WORK/stale-commit.json"
  python3 - "$SPREAD" "$STALE" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["commit"] = "deadbee"                 # a recording made at a commit this checkout is not at
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
PY
  R9_OUT="$WORK/out-stale-commit"
  "$DISCOVERY" --repo "$GITREPO" --brief "$BRIEF" --backend mock --agentis "$STUB" \
    --out "$R9_OUT" --depth-from "$STALE" --depth-max-cells 12 >/dev/null 2>"$WORK/r9.err"
  RC=$?
  HEAD_SHA="$(git -C "$GITREPO" rev-parse --short HEAD)"
  if [ "$RC" -eq 3 ] && grep -q 'deadbee' "$WORK/r9.err" && grep -q "$HEAD_SHA" "$WORK/r9.err"; then
    ok "9) a stale recorded commit exits 3 naming both the recorded SHA and the checkout's"
  else
    bad "9) the commit mismatch exited $RC (expected 3) or did not name both SHAs:"
    sed 's/^/      /' "$WORK/r9.err" >&2
  fi
  R9B_OUT="$WORK/out-no-commit"
  "$DISCOVERY" --repo "$GITREPO" --brief "$BRIEF" --backend mock --agentis "$STUB" \
    --out "$R9B_OUT" --depth-from "$SPREAD" --depth-max-cells 12 >/dev/null 2>"$WORK/r9b.err"
  RC=$?
  if [ "$RC" -eq 0 ] && grep -q 'UNVERIFIED' "$WORK/r9b.err"; then
    ok "9) an artifact with no recorded commit prints the UNVERIFIED banner and still runs"
  else
    bad "9) the no-commit path exited $RC (expected 0) or printed no UNVERIFIED banner:"
    sed 's/^/      /' "$WORK/r9b.err" >&2
  fi
else
  skip "9) git is not installed - the commit-provenance assertions are not applicable"
fi

# ----------------------------------------------------------------------------------------------------------
# (10) MISSING TARGET FILE. The only guard that reaches the working tree: a plan target the checkout no
#      longer carries means the tree moved under the recording.
#      MUTATION: drop the existence check.
# ----------------------------------------------------------------------------------------------------------
note "10) a depth target that no longer exists under --repo is refused (exit 3) ..."
TRIM="$WORK/trim-root/plaza-evm"
mkdir -p "$TRIM/src"
for c in Pool BondOracleAdapter Auction BalancerRouter LifiRouter; do
  printf 'contract %s {}\n' "$c" > "$TRIM/src/$c.sol"     # src/OracleReader.sol deliberately absent
done
R10_OUT="$WORK/out-missing-file"
# The quota is PINNED here even though this assertion is about the existence guard: leaving it at the default
# would couple a missing-file assertion to the allocation, so a default change would fail this block too.
"$DISCOVERY" --repo "$TRIM" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$R10_OUT" --depth-from "$SPREAD" --depth-max-cells 12 --depth-lens-quota 1 >/dev/null 2>"$WORK/r10.err"
RC=$?
if [ "$RC" -eq 3 ] && grep -q 'src/OracleReader.sol' "$WORK/r10.err"; then
  ok "10) a plan target missing from the checkout exits 3 naming the file"
else
  bad "10) the missing-target run exited $RC (expected 3) or did not name the file:"
  sed 's/^/      /' "$WORK/r10.err" >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (11) NO BREADTH CELLS. An all-depth (or empty) recording has nothing to plan a depth pass FROM; planning it
#      as empty would exit 0 having done nothing while still writing an output dir.
#      MUTATION: allow an empty plan.
# ----------------------------------------------------------------------------------------------------------
note "11) a recording with no breadth cell is refused (exit 3) ..."
ALLDEPTH="$WORK/all-depth.json"
python3 - "$QUOTA3" "$ALLDEPTH" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["cells"] = [c for c in d["cells"] if c.get("phase") == "depth"]
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
PY
R11_OUT="$WORK/out-all-depth"
"$DISCOVERY" --repo "$REPO" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$R11_OUT" --depth-from "$ALLDEPTH" --depth-max-cells 12 >/dev/null 2>"$WORK/r11.err"
RC=$?
if [ "$RC" -eq 3 ] && grep -q '0 breadth cell' "$WORK/r11.err"; then
  ok "11) an all-depth recording exits 3 saying there is nothing to plan a depth pass from"
else
  bad "11) the all-depth run exited $RC (expected 3) or said nothing useful:"
  sed 's/^/      /' "$WORK/r11.err" >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (12) FLAG REFUSALS. None of --list-cells / --only / --classes / --scope can affect a plan derived from
#      recorded cells (the zone class order comes from the recorded `class` fields, not from a manifest), and
#      --depth-max-cells 0 is a depth-only run with no depth budget. Accepting any of them is a silent lie.
#      MUTATION: accept any one of them.
# ----------------------------------------------------------------------------------------------------------
note "12) --list-cells / --only / --classes / --scope / --depth-max-cells 0 are each refused (exit 2) ..."
: > "$WORK/scope-dummy.tsv"
R12_FAILS=0
refuse() {
  rf_label="$1"; shift
  "$DISCOVERY" --repo "$REPO" --brief "$BRIEF" --backend mock --agentis "$STUB" \
    --out "$WORK/out-refuse" --depth-from "$SPREAD" "$@" >/dev/null 2>"$WORK/refuse.err"
  rf_rc=$?
  if [ "$rf_rc" -ne 2 ]; then
    bad "12) $rf_label exited $rf_rc, expected 2"
    sed 's/^/      /' "$WORK/refuse.err" >&2
    R12_FAILS=$((R12_FAILS + 1))
  elif ! grep -q -- "$rf_label" "$WORK/refuse.err"; then
    bad "12) the refusal of $rf_label does not name the flag"
    sed 's/^/      /' "$WORK/refuse.err" >&2
    R12_FAILS=$((R12_FAILS + 1))
  fi
}
refuse --list-cells       --depth-max-cells 12 --list-cells
refuse --only             --depth-max-cells 12 --only "some subsystem"
refuse --classes          --depth-max-cells 12 --classes C1,C2
refuse --scope            --depth-max-cells 12 --scope "$WORK/scope-dummy.tsv"
refuse --depth-max-cells  --depth-max-cells 0
[ "$R12_FAILS" -eq 0 ] && ok "12) all five refusals exit 2 and name the flag they refused"
[ -d "$WORK/out-refuse" ] && bad "12) a refused argv left an output dir behind" \
  || ok "12) no refused argv created an output dir"

# ----------------------------------------------------------------------------------------------------------
# (13) NEVER-SUBMIT. The re-entry adds no egress: run-discovery.sh still carries no network / submission verb
#      on any executable line.
#      MUTATION: add any egress call.
# ----------------------------------------------------------------------------------------------------------
note "13) read-only / never-submit posture ..."
if grep -vE '^[[:space:]]*#' "$DISCOVERY" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "13) run-discovery.sh invokes a network/submission verb on an executable line"
else
  ok "13) run-discovery.sh has no network / no submission verb on any executable line"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "ALL ASSERTIONS HELD (#1857 depth-only re-entry)"
  exit 0
fi
note "$FAILS assertion(s) FAILED"
exit 1
