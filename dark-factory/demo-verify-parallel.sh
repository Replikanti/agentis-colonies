#!/usr/bin/env bash
# demo-verify-parallel.sh — OFFLINE, DETERMINISTIC proof of the STAGE 4 gate fan-out (#1863):
# verify-findings.sh's opt-in `--jobs N` (default 1) bounded-concurrency fan-out over the CANDIDATE gates.
# Every gate call is driven by a FAST offline stub wired through the EXISTING run-refute.sh `--agentis` seam
# (NO live agentis / forge / network): the stub tracks how many gates run at once, so the demo can ASSERT the
# hard ceiling is never exceeded, and returns deterministic verdicts so the aggregated verified_findings.json
# can be compared BYTE-FOR-BYTE against the serial baseline.
#
# The fixture deliberately mixes ALL FIVE outcome kinds, so both output arrays are exercised and — crucially —
# the two ERROR kinds INTERLEAVE in manifest order (a preflight ERROR, then a gate ERROR, then another
# preflight ERROR). That ordering is the trap this feature had to avoid: emitting preflight errors during the
# launch loop while gate `ERROR` verdicts land in the drain pass would GROUP them, and errors[] would differ
# between `--jobs 1` and `--jobs > 1` on any target carrying both kinds.
#
# Assertions:
#   1) SERIAL UNCHANGED:   the flag-free (default) run AND the explicit `--jobs 1` run both produce a
#      verified_findings.json byte-identical to the checked-in golden
#      (fixtures/verify/verified-findings.golden.json, minted against the PRE-#1863 verify-findings.sh), and
#      the serial run writes NO gate.rc artifact anywhere.
#   2) EQUIVALENCE:        `cmp` byte-identity between the `--jobs 1` and `--jobs 3` verified_findings.json —
#      so verified[] order, errors[] order (both ERROR kinds interleaved) and totals are all provably
#      concurrency-invariant. This is the contract corpus-bench's `--score` matcher depends on.
#   3) CONCURRENCY + CAP:  `--jobs 3` genuinely overlaps gates (observed max >= 2) and never exceeds the
#      ceiling (max <= 3); `--jobs 99` with LLM_MAX_VERIFY_GATES=2 holds max <= 2 and warns that it clamped.
#   4) C6 SLOT DISCIPLINE: with TWO candidates tripping run-refute.sh's #1699 C6 fallback (a SECOND sequential
#      `agentis go` for the same candidate), observed max concurrency is still <= effective_jobs — the retry
#      did not become a third source of concurrency. Plus: every gates/*/candidate.manifest carries exactly
#      ONE data line, and a STATIC check that run-refute.sh backgrounds nothing and never calls `wait`.
#   5) STORE ISOLATION:    on BOTH `--jobs 1` and `--jobs 3`, each candidate's gate runs in its OWN
#      gates/<n>_<slug>/refute-out/run/.agentis store, no two candidates share one, and no .agentis is created
#      outside a per-candidate gate dir. This is what makes "no cross-candidate refuter reweighting" a
#      MEASURED property of the serial path too, not an argument — so concurrency is quality-neutral.
#   6) DEGRADE:            under `--jobs 3`, a candidate whose gate hard-fails (forced `agentis init` failure)
#      and a candidate whose gate.rc VANISHES after a REAL verdict (the OOM-killed-job shape) are BOTH
#      SKIPPED — visibly unassessed, never silently dropped and never confirmed — while the batch finishes,
#      exits 0 and still classifies every other candidate.
#   7) ARG GUARD:          `--jobs 0` and `--jobs abc` both fail fast with exit 2 + the flag and the value.
#   8) READ-ONLY / NEVER-SUBMIT: discovery-results.json is byte-unchanged after the parallel run, and
#      verify-findings.sh has no network / submission verb on any executable line.
#
# The parallel-only assertions [SKIP] cleanly when the bash that runs verify-findings.sh lacks `wait -n`
# (needs bash >= 4.3) — verify-findings.sh then degrades to serial, which the demo does not misreport.
#
# GOLDEN MINT (maintainer path, not an assertion): `DF_WRITE_GOLDEN=<path> demo-verify-parallel.sh` runs ONLY
# the flag-free serial pass and copies its verified_findings.json to <path>. The golden MUST be minted against
# an UNMODIFIED (pre-#1863) verify-findings.sh — i.e. from a merge-base checkout, never the patched tree —
# otherwise assertion 1 proves nothing. The flag-free invocation is what makes that possible: the pre-#1863
# script rejects `--jobs` as an unknown flag.
#
# Usage:  dark-factory/demo-verify-parallel.sh
# Requires: bash >= 4.3 (for the concurrency assertions) + python3 (the floor). Exit: 0 = all held.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', no process substitution, literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/verify-findings.sh"
REFUTE="$HERE/run-refute.sh"
GOLDEN="$HERE/fixtures/verify/verified-findings.golden.json"

FAILS=0
note() { echo "demo-verify-parallel.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$VERIFY" ] || { note "verify-findings.sh not found / not executable: $VERIFY" >&2; exit 3; }
MINT="${DF_WRITE_GOLDEN:-}"
[ -n "$MINT" ] || [ -f "$GOLDEN" ] || { note "golden not found: $GOLDEN" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-verify-parallel.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# (a) A throwaway target repo. NO abstract contracts anywhere, so lib/inheritance.py never resolves an
#     implementor and every gate manifest is the plain five-column shape (#1861 stays inert here — that
#     appendix has its own pins in demo-verify-findings.sh). Two files carry the #1699 compound-AND accounting
#     signal (a value-moving `function` DECLARATION and a `-=` deduction) so their candidates trip the C6
#     fallback; Token.sol deliberately carries neither, so its REFUTED verdict is final.
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target"
mkdir -p "$REPO/contracts" "$REPO/src"
printf 'contract Vault { function stake() public {} }\n'                                  > "$REPO/contracts/Vault.sol"
printf 'contract Oracle { function price() public {} }\n'                                 > "$REPO/contracts/Oracle.sol"
printf 'contract Token { function transfer() public {} }\n'                               > "$REPO/contracts/Token.sol"
printf 'contract Chrome { function stall() public {} }\n'                                 > "$REPO/contracts/Chrome.sol"
printf 'contract Gateway { function swap(uint256 amount) public { total -= amount; } }\n' > "$REPO/contracts/Gateway.sol"
printf 'contract Router { function withdraw(uint256 a) public { total -= a; } }\n'        > "$REPO/contracts/Router.sol"
printf 'contract Truncated { function fn() public {} }\n'                                 > "$REPO/src/Truncated.sol"
# The degrade fixture's two extra files (assertion 6).
printf 'contract Boom { function bang() public {} }\n'                                    > "$REPO/contracts/Boom.sol"
printf 'contract Killed { function reap() public {} }\n'                                  > "$REPO/contracts/Killed.sol"

# ----------------------------------------------------------------------------------------------------------
# (b) The fast offline stub through the --agentis seam. It (i) accounts live concurrency under a mkdir lock so
#     the caller can assert the cap, (ii) records the store path + candidate of every gate call so isolation is
#     measured rather than argued, (iii) injects the three fault shapes the demo needs, and (iv) returns a
#     deterministic verdict. NO live agentis / network. dash-safe: literal glyphs, no arrays.
# ----------------------------------------------------------------------------------------------------------
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"
case "$cmd" in
  init)
    # Forced `agentis init` failure for one candidate's rundir: run-refute.sh runs under `set -eu`, so this
    # aborts it, the gate returns non-zero and verify-findings.sh must SKIP that candidate (never confirm it).
    if [ -n "${STUB_INIT_FAIL_MATCH:-}" ]; then
      case "$PWD" in
        *"$STUB_INIT_FAIL_MATCH"*) echo "stub: forced agentis init failure in $PWD" >&2; exit 1 ;;
      esac
    fi
    mkdir -p .agentis; exit 0 ;;
  go)
    fn="${CAND_FILE_FN:-}"
    cls="${CAND_CLASS:-}"
    # Concurrency accounting: register a live marker, count concurrent markers, record the max under a mkdir
    # lock, then sleep to force overlap before de-registering — so the caller can assert max <= N.
    ctr="${STUB_CTR:-}"
    if [ -n "$ctr" ]; then
      marker="$ctr/live.$$"
      mkdir "$marker" 2>/dev/null || true
      n=0
      for d in "$ctr"/live.*; do [ -d "$d" ] && n=$((n + 1)); done
      while ! mkdir "$ctr/lock" 2>/dev/null; do :; done
      cur=0; [ -f "$ctr/max" ] && cur="$(cat "$ctr/max")"
      [ "$n" -gt "$cur" ] && printf '%s' "$n" > "$ctr/max"
      rmdir "$ctr/lock" 2>/dev/null || true
      sleep "${STUB_SLEEP:-0}"
      rmdir "$marker" 2>/dev/null || true
    fi
    # One row per gate call: the agentis store this call ran against, plus the candidate + class. $PWD is
    # run-refute.sh's rundir, so this is the store the learning/experience keys are written into.
    if [ -n "${STUB_STORE_LOG:-}" ]; then
      printf '%s\t%s\t%s\n' "$PWD/.agentis" "$fn" "$cls" >> "$STUB_STORE_LOG"
    fi
    # OOM-KILLED-JOB shape: delete the rc artifact verify-findings.sh's drain pass reads for THIS candidate
    # ($PWD is <gate-dir>/refute-out/run) while still emitting a REAL verdict below. The parent's redirect
    # already holds the fd, so the rc byte lands in an unlinked inode — exactly what a killed job leaves.
    case "$fn" in
      *Killed.sol*) rm -f "$PWD/../../gate.rc" ;;
    esac
    # TUI-chrome injection: this candidate NEVER yields a VERDICT| line, so run-refute.sh retries to its
    # ceiling and records a loud ERROR row -> verify-findings.sh routes it into errors[] (the gate-ERROR kind).
    case "$fn" in
      *Chrome.sol*)
        printf 'high · /effort\n'
        printf 'esc to interrupt\n'
        exit 0 ;;
    esac
    case "$cls" in
      C6)                  echo "VERDICT|REAL|$fn|$cls|recovered under the accounting lens" ;;
      *refuted*|*REFUTED*) echo "VERDICT|REFUTED|$fn|$cls|a hostile read killed it" ;;
      *)                   echo "VERDICT|REAL|$fn|$cls|survived a hostile read" ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

# ----------------------------------------------------------------------------------------------------------
# (c) The inline M3 discovery-results.json: 8 candidates covering all five outcome kinds, ORDERED so the two
#     ERROR kinds interleave (preflight #2, gate-ERROR #3, preflight #7). Built via python3 (the convention).
#       1 Vault      C1         -> REAL                (confirmed)
#       2 Missing    C9         -> preflight ERROR     (code file absent from the repo)
#       3 Chrome     C3         -> gate ERROR          (no VERDICT| after the attempt ceiling)
#       4 Gateway    C-refuted  -> REFUTED then C6     (confirmed, recorded under the surviving class)
#       5 Token      C-refuted  -> REFUTED             (dropped; no accounting signal, so no C6 retry)
#       6 Router     C-refuted  -> REFUTED then C6     (confirmed; the SECOND C6 candidate, for assertion 4)
#       7 Truncated  (blank)    -> preflight ERROR     (blank class/severity = a truncated record)
#       8 Oracle     C2         -> REAL                (confirmed)
# ----------------------------------------------------------------------------------------------------------
RES="$WORK/discovery-results.json"
python3 - > "$RES" <<'PY'
import json


def cell(sub, cls, f, cand):
    return {"subsystem": sub, "class": cls, "files": f, "candidates": [cand], "coordination": []}


data = {
    "repo": "target", "backend": "mock", "jobs": 1,
    "cells": [
        cell("vault staking", "C1", "contracts/Vault.sol",
             "contracts/Vault.sol:stake:12|C1|High|an external staker mints free shares|donate to inflate the share price"),
        cell("ghost", "C9", "contracts/Missing.sol",
             "contracts/Missing.sol:ghost:1|C9|Medium|references a file absent from the repo|the gate cannot evaluate it"),
        cell("stalled gate", "C3", "contracts/Chrome.sol",
             "contracts/Chrome.sol:stall:7|C3|High|a candidate whose refuter never answers|the reply is TUI chrome"),
        cell("gateway swap", "C-refuted", "contracts/Gateway.sol",
             "contracts/Gateway.sol:swap:3|C-refuted|High|misclassified accounting bug in a value-moving swap|short-deduct the fee"),
        cell("token", "C-refuted", "contracts/Token.sol",
             "contracts/Token.sol:transfer:5|C-refuted|Low|transfer lacks an owner check|anyone moves funds"),
        cell("router withdrawals", "C-refuted", "contracts/Router.sol",
             "contracts/Router.sol:withdraw:9|C-refuted|High|misclassified accounting bug in a value-moving withdraw|short-deduct on exit"),
        cell("blueprint deploy", "C4", "src/Truncated.sol",
             "src/Truncated.sol:fn:~(test/Truncated.t.sol:test_fn||||"),
        cell("price oracle", "C2", "contracts/Oracle.sol",
             "contracts/Oracle.sol:price:20|C2|Medium|a stale round is accepted on the withdraw path|push a stale price then withdraw"),
    ],
    "totals": {"cells": 8, "candidates": 8, "steers": 0},
}
print(json.dumps(data, indent=2))
PY
cp "$RES" "$WORK/results.orig"   # byte-exact snapshot for the read-only assertion

# DF_AGENT_MAX_ATTEMPTS=2 keeps the chrome candidate's retries fast without changing any verdict.
export DF_AGENT_MAX_ATTEMPTS=2

# ----------------------------------------------------------------------------------------------------------
# (d) GOLDEN MINT — the maintainer path. Runs the DEFAULT (flag-free) invocation only, so it works against the
#     pre-#1863 verify-findings.sh, and exits before any assertion.
# ----------------------------------------------------------------------------------------------------------
if [ -n "$MINT" ]; then
  MINT_OUT="$WORK/out-mint"
  "$VERIFY" --results "$RES" --repo "$REPO" --out "$MINT_OUT" --gate refute --backend mock --agentis "$STUB" \
    >"$WORK/mint.out" 2>"$WORK/mint.err"
  MRC=$?
  [ "$MRC" -eq 0 ] || { note "mint run exited $MRC"; sed 's/^/      /' "$WORK/mint.err" >&2; exit 1; }
  mkdir -p "$(dirname "$MINT")"
  cp "$MINT_OUT/verified_findings.json" "$MINT"
  note "MINTED golden from the DEFAULT (flag-free) serial run -> $MINT"
  exit 0
fi

# Does the bash that runs verify-findings.sh support `wait -n` (>= 4.3)? Otherwise it degrades to serial and
# the concurrency-specific assertions do not apply — [SKIP] them rather than misreport a false failure.
PAR_OK=1
bash -c '[ "${BASH_VERSINFO:-0}" -gt 4 ] || { [ "${BASH_VERSINFO:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 3 ]; }' 2>/dev/null || PAR_OK=0

# ----------------------------------------------------------------------------------------------------------
# (1) SERIAL UNCHANGED — the default invocation AND --jobs 1 both equal the golden, byte for byte.
# ----------------------------------------------------------------------------------------------------------
note "1) serial: the default run and --jobs 1 are byte-identical to the pre-#1863 golden ..."
DEF_OUT="$WORK/out-default"
"$VERIFY" --results "$RES" --repo "$REPO" --out "$DEF_OUT" --gate refute --backend mock --agentis "$STUB" \
  >"$WORK/default.out" 2>"$WORK/default.err"
RC=$?
[ "$RC" -eq 0 ] && ok "verify-findings.sh (no --jobs) exits 0 over the 8-candidate fixture" \
  || { bad "the default run exited $RC"; sed 's/^/      /' "$WORK/default.err" >&2; }
if cmp -s "$DEF_OUT/verified_findings.json" "$GOLDEN"; then
  ok "the DEFAULT run's verified_findings.json is byte-for-byte identical to the golden minted against the PRE-#1863 script"
else
  bad "the default run diverged from the pre-#1863 golden:"
  diff "$GOLDEN" "$DEF_OUT/verified_findings.json" | sed 's/^/      /' >&2
fi

SER_OUT="$WORK/out-serial"
SER_STORE="$WORK/stores-serial.tsv"; : > "$SER_STORE"
STUB_STORE_LOG="$SER_STORE" \
  "$VERIFY" --results "$RES" --repo "$REPO" --out "$SER_OUT" --gate refute --backend mock --agentis "$STUB" \
  --jobs 1 >"$WORK/serial.out" 2>"$WORK/serial.err"
RC=$?
[ "$RC" -eq 0 ] && ok "verify-findings.sh --jobs 1 exits 0" \
  || { bad "the --jobs 1 run exited $RC"; sed 's/^/      /' "$WORK/serial.err" >&2; }
if cmp -s "$SER_OUT/verified_findings.json" "$GOLDEN"; then
  ok "--jobs 1 is byte-identical to the golden (the explicit default changes nothing)"
else
  bad "--jobs 1 diverged from the golden:"
  diff "$GOLDEN" "$SER_OUT/verified_findings.json" | sed 's/^/      /' >&2
fi
# The serial branch must write NO new artifact — gate.rc belongs to the parallel dispatch alone.
if [ -z "$(find "$SER_OUT" "$DEF_OUT" -name gate.rc -print 2>/dev/null)" ]; then
  ok "the serial runs wrote no gate.rc anywhere (the parallel dispatch's artifact stays off the serial path)"
else
  bad "a serial run wrote a gate.rc artifact"
fi
# The fixture must genuinely exercise all five outcome kinds, or assertion 2 is vacuous.
if python3 - "$GOLDEN" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
t = d["totals"]
assert t["candidates"] == 8, "candidates != 8: %r" % t["candidates"]
assert t["verified"] == 4, "verified != 4: %r" % t["verified"]
assert t["errored"] == 3, "errored != 3: %r" % t["errored"]
assert t["candidates"] - t["verified"] - t["errored"] == 1, "rigorous-refutation count != 1"
locs = [v["location"] for v in d["verified"]]
assert locs == [
    "contracts/Vault.sol:stake:12",
    "contracts/Gateway.sol:swap:3",
    "contracts/Router.sol:withdraw:9",
    "contracts/Oracle.sol:price:20",
], "verified[] is not the manifest-ordered expected set: %r" % locs
byloc = {v["location"]: v for v in d["verified"]}
assert byloc["contracts/Gateway.sol:swap:3"]["class"] == "C6", "the C6 fallback did not fire for Gateway"
assert byloc["contracts/Router.sol:withdraw:9"]["class"] == "C6", "the C6 fallback did not fire for Router"
errlocs = [e["location"] for e in d["errors"]]
assert errlocs == [
    "contracts/Missing.sol:ghost:1",
    "contracts/Chrome.sol:stall:7",
    "src/Truncated.sol:fn:~(test/Truncated.t.sol:test_fn",
], "errors[] is not manifest-ordered / the two ERROR kinds do not interleave: %r" % errlocs
PY
then ok "the fixture exercises all five kinds and errors[] INTERLEAVES preflight / gate-ERROR / preflight in manifest order (so assertion 2 is load-bearing)"
else bad "the fixture no longer covers the five outcome kinds in the interleaved order"
fi

# ----------------------------------------------------------------------------------------------------------
# (2)+(3)+(4)+(5) PARALLEL: equivalence, concurrency + cap, C6 slot discipline, store isolation.
# ----------------------------------------------------------------------------------------------------------
if [ "$PAR_OK" -ne 1 ]; then
  skip "the bash running verify-findings.sh lacks 'wait -n' (needs >= 4.3) — parallel assertions not applicable"
else
  note "2)+3) --jobs 3: byte-identical result, real overlap, cap never exceeded ..."
  PAR_OUT="$WORK/out-par3"
  PAR_STORE="$WORK/stores-par3.tsv"; : > "$PAR_STORE"
  mkdir -p "$WORK/ctr-par3"
  STUB_CTR="$WORK/ctr-par3" STUB_SLEEP=0.4 STUB_STORE_LOG="$PAR_STORE" \
    "$VERIFY" --results "$RES" --repo "$REPO" --out "$PAR_OUT" --gate refute --backend mock --agentis "$STUB" \
    --jobs 3 >"$WORK/par3.out" 2>"$WORK/par3.err"
  RC=$?
  [ "$RC" -eq 0 ] && ok "verify-findings.sh --jobs 3 exits 0" \
    || { bad "the --jobs 3 run exited $RC"; sed 's/^/      /' "$WORK/par3.err" >&2; }
  if cmp -s "$SER_OUT/verified_findings.json" "$PAR_OUT/verified_findings.json"; then
    ok "2) verified_findings.json is BYTE-IDENTICAL between --jobs 1 and --jobs 3 (verified[] order, errors[] order with both ERROR kinds interleaved, and totals are all concurrency-invariant)"
  else
    bad "2) the --jobs 3 result diverged from serial:"
    diff "$SER_OUT/verified_findings.json" "$PAR_OUT/verified_findings.json" | sed 's/^/      /' >&2
  fi
  MAX3=0; [ -f "$WORK/ctr-par3/max" ] && MAX3="$(cat "$WORK/ctr-par3/max")"
  [ "$MAX3" -ge 2 ] && ok "3) observed concurrency (max $MAX3 gates ran at once, > 1 = genuinely parallel)" \
    || bad "3) no concurrency observed (max $MAX3) — the gates did not overlap"
  [ "$MAX3" -le 3 ] && ok "3) concurrency never exceeded --jobs 3 (max $MAX3 <= 3)" \
    || bad "3) concurrency exceeded the cap (max $MAX3 > 3)"

  note "3b) clamp: --jobs 99 with LLM_MAX_VERIFY_GATES=2 holds concurrency <= 2 ..."
  CLAMP_OUT="$WORK/out-clamp"
  mkdir -p "$WORK/ctr-clamp"
  STUB_CTR="$WORK/ctr-clamp" STUB_SLEEP=0.4 LLM_MAX_VERIFY_GATES=2 \
    "$VERIFY" --results "$RES" --repo "$REPO" --out "$CLAMP_OUT" --gate refute --backend mock --agentis "$STUB" \
    --jobs 99 >"$WORK/clamp.out" 2>"$WORK/clamp.err"
  RC=$?
  [ "$RC" -eq 0 ] && ok "verify-findings.sh --jobs 99 (clamped) exits 0" \
    || { bad "the clamped run exited $RC"; sed 's/^/      /' "$WORK/clamp.err" >&2; }
  MAXC=0; [ -f "$WORK/ctr-clamp/max" ] && MAXC="$(cat "$WORK/ctr-clamp/max")"
  [ "$MAXC" -le 2 ] && ok "the HARD cap held: max $MAXC <= LLM_MAX_VERIFY_GATES=2 despite --jobs 99 (the cap never fails open)" \
    || bad "the cap was exceeded under clamp (max $MAXC > 2)"
  grep -q 'clamping concurrency to 2' "$WORK/clamp.err" \
    && ok "verify-findings.sh warned it clamped --jobs 99 to the LLM_MAX_VERIFY_GATES ceiling" \
    || bad "no clamp warning emitted for --jobs 99 over the cap"
  # The clamped run must still be the SAME result set — the ceiling changes scheduling, never verdicts.
  cmp -s "$SER_OUT/verified_findings.json" "$CLAMP_OUT/verified_findings.json" \
    && ok "the clamped run's verified_findings.json is byte-identical to serial too" \
    || bad "the clamped run's result diverged from serial"

  note "4) C6 slot discipline: the #1699 fallback re-run stays inside its own candidate's slot ..."
  if python3 - "$PAR_STORE" <<'PY'
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
# The two accounting-signal candidates each cost TWO gate calls (assigned class, then the C6 retry).
for marker in ("Gateway.sol", "Router.sol"):
    hits = [r for r in rows if marker in r[1]]
    assert len(hits) == 2, "%s did not fire the C6 fallback under --jobs 3 (calls: %r)" % (marker, hits)
    assert hits[0][2].startswith("C-refuted") and hits[1][2] == "C6", "%s call sequence wrong: %r" % (marker, hits)
    assert hits[0][0] == hits[1][0], "%s's C6 retry ran against a DIFFERENT store: %r" % (marker, hits)
# Token has no accounting signal, so its refutation is final — the retry must be signal-gated, not blanket.
tok = [r for r in rows if "Token.sol" in r[1]]
assert len(tok) == 1, "the signal-less candidate was retried (%d calls) — the C6 gate is not signal-gated" % len(tok)
PY
  then ok "4) both accounting-signal candidates fired the C6 retry (2 calls each, same store, C-refuted then C6) and the signal-less one did not — under --jobs 3"
  else bad "4) the C6 fallback did not behave as a sequential in-slot step under --jobs 3"
  fi
  # Peak concurrency stayed at the ceiling even though two candidates each ran two sequential agentis calls.
  [ "$MAX3" -le 3 ] \
    && ok "4) peak agentis concurrency stayed <= effective_jobs (max $MAX3) with two C6 re-runs in flight — the retry is not a third source of concurrency" \
    || bad "4) the C6 re-runs pushed concurrency past effective_jobs (max $MAX3)"

  note "5) store isolation under --jobs 3 ..."
  if python3 - "$PAR_STORE" "$PAR_OUT" <<'PY'
import sys, os, glob
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
assert rows, "no gate call was recorded"
# Every store path sits under its OWN per-candidate gate dir, and no two CANDIDATES share a store.
bycand = {}
for store, fn, _cls in rows:
    assert "/gates/" in store and store.endswith("/refute-out/run/.agentis"), "store outside a gate dir: %r" % store
    bycand.setdefault(fn, set()).add(store)
for fn, stores in bycand.items():
    assert len(stores) == 1, "candidate %r used more than one store: %r" % (fn, stores)
seen = {}
for fn, stores in bycand.items():
    s = next(iter(stores))
    assert s not in seen, "candidates %r and %r SHARE the store %r" % (fn, seen[s], s)
    seen[s] = fn
# No .agentis is created outside a per-candidate gate dir anywhere in the output tree.
for d in glob.glob(os.path.join(sys.argv[2], "**", ".agentis"), recursive=True):
    assert os.path.normpath(d).replace(os.sep, "/").find("/gates/") != -1, "an .agentis store lives outside a gate dir: %r" % d
# Every gate manifest carries exactly ONE data line — a multi-line manifest is the only shape in which
# run-refute.sh could reweight one candidate against another.
mans = glob.glob(os.path.join(sys.argv[2], "gates", "*", "candidate.manifest"))
assert mans, "no candidate.manifest was written"
for m in mans:
    lines = [l for l in open(m, encoding="utf-8").read().splitlines() if l.strip()]
    assert len(lines) == 1, "%s carries %d data lines (cross-candidate reweighting becomes possible)" % (m, len(lines))
PY
  then ok "5) each candidate gated in its OWN gates/<n>_<slug>/refute-out/run/.agentis store, no store is shared, no .agentis leaks outside a gate dir, and every candidate.manifest has exactly one data line"
  else bad "5) store isolation regressed under --jobs 3"
  fi
fi

# The SAME isolation must hold on the SERIAL path — that is what makes "no cross-candidate refuter
# reweighting" a measured property of BOTH paths, hence "concurrency is quality-neutral" rather than argued.
note "5b) the same store isolation on the SERIAL path ..."
if python3 - "$SER_STORE" "$SER_OUT" <<'PY'
import sys, os, glob
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
assert rows, "no gate call was recorded on the serial path"
seen = {}
for store, fn, _cls in rows:
    assert "/gates/" in store and store.endswith("/refute-out/run/.agentis"), "store outside a gate dir: %r" % store
    if store in seen:
        assert seen[store] == fn, "candidates %r and %r SHARE the store %r" % (fn, seen[store], store)
    seen[store] = fn
assert len(set(seen.values())) == len(seen), "two candidates resolved to the same store"
mans = glob.glob(os.path.join(sys.argv[2], "gates", "*", "candidate.manifest"))
assert mans, "no candidate.manifest was written"
for m in mans:
    lines = [l for l in open(m, encoding="utf-8").read().splitlines() if l.strip()]
    assert len(lines) == 1, "%s carries %d data lines" % (m, len(lines))
PY
then ok "5b) the serial path ALSO gives every candidate its own store and a one-line manifest — the refuter has no cross-candidate experience to lose, on either path"
else bad "5b) serial store isolation assertion failed"
fi

# STATIC twin: fan-out must live in verify-findings.sh's launch loop and NOWHERE below it. A `&` or a `wait`
# appearing in run-refute.sh would make the C6 retry (or anything else) a second, uncapped source of
# concurrency that no ceiling in this script could bound.
note "4b) static: run-refute.sh backgrounds nothing and never waits ..."
if [ -f "$REFUTE" ]; then
  _bg=0
  grep -vE '^[[:space:]]*#' "$REFUTE" | grep -qE '&[[:space:]]*$' && _bg=1
  grep -vE '^[[:space:]]*#' "$REFUTE" | grep -qE '(^|[[:space:];&|(])wait([[:space:]]|$)' && _bg=1
  [ "$_bg" -eq 0 ] \
    && ok "4b) run-refute.sh has no '&' backgrounding and no 'wait' on any executable line — fan-out lives only in verify-findings.sh's launch loop" \
    || bad "4b) run-refute.sh backgrounds work or waits on jobs — the C6 retry can escape its slot"
else
  bad "4b) run-refute.sh not found at $REFUTE"
fi

# ----------------------------------------------------------------------------------------------------------
# (6) DEGRADE: a hard-failing gate and a VANISHED gate.rc are both SKIPPED, never dropped, never confirmed.
# ----------------------------------------------------------------------------------------------------------
note "6) degrade: a hard-failing gate and an OOM-killed job are both SKIPPED, the batch still finishes ..."
DEG_RES="$WORK/degrade-results.json"
python3 - > "$DEG_RES" <<'PY'
import json


def cell(sub, cls, f, cand):
    return {"subsystem": sub, "class": cls, "files": f, "candidates": [cand], "coordination": []}


data = {
    "repo": "target", "backend": "mock", "jobs": 1,
    "cells": [
        cell("vault staking", "C1", "contracts/Vault.sol",
             "contracts/Vault.sol:stake:12|C1|High|a healthy candidate|sketch"),
        cell("boom", "C1", "contracts/Boom.sol",
             "contracts/Boom.sol:bang:1|C1|High|a candidate whose gate hard-fails|sketch"),
        cell("killed", "C1", "contracts/Killed.sol",
             "contracts/Killed.sol:reap:1|C1|High|a candidate whose background job is killed mid-flight|sketch"),
        cell("price oracle", "C2", "contracts/Oracle.sol",
             "contracts/Oracle.sol:price:20|C2|Medium|another healthy candidate|sketch"),
    ],
    "totals": {"cells": 4, "candidates": 4, "steers": 0},
}
print(json.dumps(data, indent=2))
PY
if [ "$PAR_OK" -ne 1 ]; then
  skip "6) degrade under --jobs 3: the bash running verify-findings.sh lacks 'wait -n'"
else
  DEG_OUT="$WORK/out-degrade"
  STUB_INIT_FAIL_MATCH="Boom_sol" \
    "$VERIFY" --results "$DEG_RES" --repo "$REPO" --out "$DEG_OUT" --gate refute --backend mock \
    --agentis "$STUB" --jobs 3 >"$WORK/degrade.out" 2>"$WORK/degrade.err"
  RC=$?
  [ "$RC" -eq 0 ] && ok "6) verify-findings.sh --jobs 3 still exits 0 with a hard-failing gate AND a killed job (degrades, never aborts)" \
    || { bad "6) the degrade run exited $RC"; sed 's/^/      /' "$WORK/degrade.err" >&2; }
  if python3 - "$DEG_OUT/verified_findings.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
t = d["totals"]
assert t["candidates"] == 4, "candidates != 4: %r" % t["candidates"]
assert t["verified"] == 2, "verified != 2 (the two healthy candidates): %r" % t["verified"]
assert t["errored"] == 0, "a skipped candidate was mis-filed as errored: %r" % t["errored"]
locs = [v["location"] for v in d["verified"]]
assert locs == ["contracts/Vault.sol:stake:12", "contracts/Oracle.sol:price:20"], \
    "the healthy candidates are wrong / out of manifest order: %r" % locs
assert not any("Boom.sol" in l for l in locs), "the hard-failing candidate was CONFIRMED"
assert not any("Killed.sol" in l for l in locs), \
    "the killed candidate was CONFIRMED from a stale verdict.txt — a missing gate.rc must never confirm"
assert not any("Killed.sol" in e["location"] for e in d["errors"]), "the killed candidate was mis-filed as errored"
PY
  then ok "6) both degraded candidates are absent from verified[] and from errors[]; the two healthy candidates are still confirmed in manifest order"
  else bad "6) the degrade classification is wrong"
  fi
  grep -q '2 skipped' "$WORK/degrade.err" \
    && ok "6) the run summary reports 2 skipped — a hard-failing gate and a vanished gate.rc are VISIBLY unassessed, not silent drops" \
    || { bad "6) the summary does not report 2 skipped candidates"; grep '====' "$WORK/degrade.err" | sed 's/^/      /' >&2; }
  [ -f "$DEG_OUT/gates/3_contracts_Killed_sol_reap_1/verdict.txt" ] \
    && ok "6) the killed candidate DID produce a REAL verdict.txt on disk — and was still SKIPPED, because the missing gate.rc is read as rc 1" \
    || bad "6) the killed-job fixture did not produce a verdict.txt (the assertion above would be vacuous)"
fi

# ----------------------------------------------------------------------------------------------------------
# (7) ARG GUARD: --jobs 0 and --jobs abc fail fast with exit 2, naming the flag and the value.
# ----------------------------------------------------------------------------------------------------------
note "7) arg guard: --jobs 0 / --jobs abc fail fast ..."
for _bad in 0 abc; do
  "$VERIFY" --results "$RES" --repo "$REPO" --out "$WORK/out-badjobs-$_bad" --gate refute --backend mock \
    --agentis "$STUB" --jobs "$_bad" >/dev/null 2>"$WORK/badjobs-$_bad.err"
  JRC=$?
  if [ "$JRC" -eq 2 ] && grep -q -- '--jobs' "$WORK/badjobs-$_bad.err" \
     && grep -q "got '$_bad'" "$WORK/badjobs-$_bad.err" && [ ! -d "$WORK/out-badjobs-$_bad" ]; then
    ok "7) --jobs $_bad fails fast with exit 2, names the flag + the value, and writes no output dir"
  else
    bad "7) --jobs $_bad did not fail fast (exit $JRC)"
  fi
done

# ----------------------------------------------------------------------------------------------------------
# (8) READ-ONLY / NEVER-SUBMIT.
# ----------------------------------------------------------------------------------------------------------
note "8) read-only / never-submit posture ..."
if cmp -s "$RES" "$WORK/results.orig"; then
  ok "8) discovery-results.json is byte-for-byte identical after the parallel runs (verify never mutates M3 output)"
else
  bad "8) a --jobs > 1 run mutated discovery-results.json (read-only invariant broken)"
fi
if grep -vE '^[[:space:]]*#' "$VERIFY" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "8) verify-findings.sh invokes a network/submission verb on an executable line"
else
  ok "8) verify-findings.sh has no network / no submission verb on any executable line (read-only, never submits)"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — STAGE 4 gate fan-out (verify-findings.sh --jobs N: bounded concurrency, isolated stores, deferred manifest-ordered aggregation) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
