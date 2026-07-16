#!/usr/bin/env bash
# demo-discovery-parallel.sh — OFFLINE, DETERMINISTIC proof of M3 parallel fan-out (#1625, epic #1611):
# run-discovery.sh's opt-in `--jobs N` (`-j N`, default 1) bounded-concurrency fan-out over the
# (subsystem x class) hunt cells. Every cell is driven by a FAST offline stub wired through the EXISTING
# `--agentis <bin>` seam (NO live agentis / forge / network): the stub tracks how many cells run at once,
# so the demo can ASSERT the hard concurrency cap is never exceeded, then prints a deterministic CANDIDATE
# line so the aggregated report can be compared against the serial baseline.
#
# Assertions:
#   1) SERIAL byte-identical:  `--jobs 1` produces a report BYTE-FOR-BYTE equal to the checked-in golden
#      (fixtures/zone-map/discovery-report.golden.md) — the shipped serial path is unchanged.
#   2) CONCURRENCY + CAP:      `--jobs 3` runs cells concurrently (observed max >= 2) AND never exceeds the
#      ceiling (max <= 3); the clamp path `--jobs 99` + `LLM_MAX_DISCOVERY_CELLS=2` holds max <= 2.
#   3) AGGREGATION == SERIAL:  the `--jobs 3` candidate rows (sorted) equal the serial ones, and the
#      `discovery-results.json` candidate multiset matches the serial run (order-independent of finish).
#   4) ISOLATION:              each cell ran in its OWN `run/cell-<slug>_<cls>/.agentis` store; no cross-cell
#      contamination (every candidate is prefixed by its own cell's subsystem:class); #1001 cross-cell
#      steering is off under `--jobs > 1` (STEERS = 0, every cell's coordination is empty).
#   5) DEGRADE:                a cell whose stub EXITS NON-ZERO still lets the run finish + scrape the rest.
#   6) READ-ONLY / NEVER-SUBMIT: no network / no submission verb on run-discovery.sh's executable lines.
#   7) WRAPPED CANDIDATE (#1705): a synthetic PTY-wrapped CANDIDATE record (STUB_WRAP=1) — exploit/poc_sketch
#      prose split across several continuation lines with no CANDIDATE|/BLACKBOARD- prefix — is reconstructed
#      WHOLE by `_join_wrapped_candidates()`: the full exploit sentence and poc_sketch survive intact, and the
#      wrap does not split into two bogus candidates.
#
# The parallel-only assertions [SKIP] cleanly when the bash that runs run-discovery.sh lacks `wait -n`
# (needs bash >= 4.3) — run-discovery.sh then degrades to serial, which the demo does not misreport.
#
# Usage:  dark-factory/demo-discovery-parallel.sh
# Requires: bash >= 4.3 (for the concurrency assertions) + python3 (the floor). Exit: 0 = all held.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', no process substitution, literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DISCOVERY="$HERE/run-discovery.sh"
GOLDEN="$HERE/fixtures/zone-map/discovery-report.golden.md"

FAILS=0
note() { echo "demo-discovery-parallel.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$DISCOVERY" ] || { note "run-discovery.sh not found / not executable: $DISCOVERY" >&2; exit 3; }
[ -f "$GOLDEN" ]    || { note "golden report not found: $GOLDEN" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-discovery-parallel.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# (a) Build the offline inputs: a throwaway target tree, the pinned scope.tsv + brief.md, and the fast stub.
#     These MUST match the corpus the checked-in golden was generated from (assertion 1 is byte-identical).
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target"
mkdir -p "$REPO/contracts/vault" "$REPO/contracts/rewards" "$REPO/contracts/liquidation"
printf 'contract Vault {}\n'       > "$REPO/contracts/vault/Vault.sol"
printf 'contract Rewards {}\n'     > "$REPO/contracts/rewards/Rewards.sol"
printf 'contract Liquidation {}\n' > "$REPO/contracts/liquidation/Liquidation.sol"

SCOPE="$WORK/scope.tsv"
{
  printf 'vault deposits | C1,C6 | contracts/vault/Vault.sol\n'
  printf 'rewards distributor | C11 | contracts/rewards/Rewards.sol\n'
  printf 'liquidation engine | C10 | contracts/liquidation/Liquidation.sol\n'
} > "$SCOPE"

BRIEF="$WORK/brief.md"
{
  printf '# Protocol brief (offline stub)\n'
  printf 'Invariants to break: share-price accounting, rounding, liquidation solvency.\n'
  printf 'Known issues to exclude: none.\n'
} > "$BRIEF"

# Fast offline stub through the --agentis seam. NO live agentis / forge / network. dash-safe.
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    # Optional fault injection: exit non-zero for one class so the demo proves a failed cell degrades.
    if [ -n "${STUB_FAIL_CLASS:-}" ] && [ "${STUB_FAIL_CLASS:-}" = "${HUNT_CLASS:-}" ]; then
      echo "stub: forced failure for ${HUNT_CLASS:-}" >&2
      exit 1
    fi
    # Concurrency accounting: register a live marker, count concurrent markers, record the max under a
    # mkdir lock, then sleep to force overlap before de-registering — so the caller can assert max <= N.
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
      sleep "${STUB_SLEEP:-0.5}"
      rmdir "$marker" 2>/dev/null || true
    fi
    if [ "${STUB_WRAP:-}" = "1" ] && [ "${HUNT_CLASS:-}" = "C1" ]; then
      # #1705: synthetic PTY-wrapped record — the CANDIDATE| line's exploit/poc_sketch prose is split
      # across several continuation lines carrying NO CANDIDATE|/BLACKBOARD- prefix and breaking
      # mid-sentence, reproducing the shape flat-cyborg's PTY capture produces when the hunter's reply
      # exceeds one physical line (hunter.ag's own ~118-120 column contract). The "|" separating the
      # exploit field from the poc_sketch field lands mid-continuation, exactly as a real wrap would.
      printf 'CANDIDATE|Vault.sol:deposit:42|%s|High|An attacker can drain the vault by depositing\n' "${HUNT_CLASS:-}"
      printf 'collateral then immediately calling emergencyWithdraw before the accounting snapshot\n'
      printf 'updates, exploiting the stale share price to redeem shares at the pre-deposit\n'
      printf 'exchange rate and capture the difference as risk-free profit.|1. deploy\n'
      printf 'MaliciousDepositor pointing at the target Vault; 2. call deposit(1000e18) then\n'
      printf 'immediately call emergencyWithdraw() in the same transaction; 3. assert\n'
      printf 'vm.assertGt(token.balanceOf(attacker), 1000e18, "drained more than deposited");\n'
    else
      printf 'CANDIDATE|%s:%s:1|%s|Medium|stub external exploit path|stub foundry PoC sketch\n' \
        "${SUBSYSTEM:-}" "${HUNT_CLASS:-}" "${HUNT_CLASS:-}"
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

# Does the bash that runs run-discovery.sh support `wait -n` (>= 4.3)? Otherwise it degrades to serial and
# the concurrency-specific assertions do not apply — [SKIP] them rather than misreport a false failure.
PAR_OK=1
bash -c '[ "${BASH_VERSINFO:-0}" -gt 4 ] || { [ "${BASH_VERSINFO:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 3 ]; }' 2>/dev/null || PAR_OK=0

# ----------------------------------------------------------------------------------------------------------
# (1) SERIAL byte-identical: --jobs 1 report == the checked-in golden.
# ----------------------------------------------------------------------------------------------------------
note "1) serial --jobs 1 report is byte-identical to the golden ..."
SER_OUT="$WORK/out-serial"
STUB_CTR="$WORK/ctr-serial"; mkdir -p "$STUB_CTR"
STUB_CTR="$STUB_CTR" STUB_SLEEP=0 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$SER_OUT" --jobs 1 >/dev/null 2>"$WORK/serial.err"
RC=$?
[ "$RC" -eq 0 ] && ok "run-discovery.sh --jobs 1 exits 0 (offline stub)" \
  || { bad "run-discovery.sh --jobs 1 exited $RC"; sed 's/^/      /' "$WORK/serial.err" >&2; }
if cmp -s "$SER_OUT/discovery-report.md" "$GOLDEN"; then
  ok "discovery-report.md is byte-for-byte identical to the golden (serial path unchanged)"
else
  bad "serial discovery-report.md diverged from the golden:"
  diff "$GOLDEN" "$SER_OUT/discovery-report.md" | sed 's/^/      /' >&2
fi
[ -f "$SER_OUT/discovery-results.json" ] && ok "emitted the additive discovery-results.json alongside the report" \
  || bad "discovery-results.json was not emitted on the serial path"

# ----------------------------------------------------------------------------------------------------------
# (2)+(3)+(4) PARALLEL: --jobs 3 concurrency + cap + aggregation == serial + isolation.
# ----------------------------------------------------------------------------------------------------------
if [ "$PAR_OK" -ne 1 ]; then
  skip "the bash running run-discovery.sh lacks 'wait -n' (needs >= 4.3) — parallel assertions not applicable"
else
  note "2) parallel --jobs 3 runs cells concurrently AND never exceeds the cap ..."
  PAR_OUT="$WORK/out-par3"
  STUB_CTR="$WORK/ctr-par3"; mkdir -p "$STUB_CTR"
  STUB_CTR="$STUB_CTR" STUB_SLEEP=0.5 \
    "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
    --out "$PAR_OUT" --jobs 3 >/dev/null 2>"$WORK/par3.err"
  RC=$?
  [ "$RC" -eq 0 ] && ok "run-discovery.sh --jobs 3 exits 0" \
    || { bad "run-discovery.sh --jobs 3 exited $RC"; sed 's/^/      /' "$WORK/par3.err" >&2; }
  MAX3=0; [ -f "$WORK/ctr-par3/max" ] && MAX3="$(cat "$WORK/ctr-par3/max")"
  [ "$MAX3" -ge 2 ] && ok "observed concurrency (max $MAX3 cells ran at once, > 1 = genuinely parallel)" \
    || bad "no concurrency observed (max $MAX3) — cells did not overlap"
  [ "$MAX3" -le 3 ] && ok "concurrency never exceeded --jobs 3 (max $MAX3 <= 3)" \
    || bad "concurrency exceeded the cap (max $MAX3 > 3)"

  note "3) the aggregated --jobs 3 result equals the serial result (order-independent) ..."
  grep '| Medium' "$GOLDEN" | sort > "$WORK/rows.serial"
  grep '| Medium' "$PAR_OUT/discovery-report.md" | sort > "$WORK/rows.par3"
  if cmp -s "$WORK/rows.serial" "$WORK/rows.par3"; then
    ok "the --jobs 3 candidate rows (sorted) equal the serial candidate rows"
  else
    bad "the --jobs 3 candidate set diverged from serial:"
    diff "$WORK/rows.serial" "$WORK/rows.par3" | sed 's/^/      /' >&2
  fi
  if python3 - "$SER_OUT/discovery-results.json" "$PAR_OUT/discovery-results.json" <<'PY'
import sys, json
a = json.load(open(sys.argv[1], encoding="utf-8"))
b = json.load(open(sys.argv[2], encoding="utf-8"))
def cands(d):
    out = []
    for c in d["cells"]:
        out.extend(c["candidates"])
    return sorted(out)
assert cands(a) == cands(b), "candidate multiset differs: %r != %r" % (cands(a), cands(b))
assert a["totals"]["candidates"] == b["totals"]["candidates"], "candidate totals differ"
assert a["totals"]["cells"] == b["totals"]["cells"], "cell totals differ"
assert b["jobs"] == 3, "parallel run did not record jobs=3"
PY
  then ok "discovery-results.json candidate multiset matches serial (order-independent)"
  else bad "discovery-results.json candidate multiset diverged from serial"
  fi

  note "4) per-cell store isolation + #1001 cross-cell steering off under --jobs > 1 ..."
  NCELLS="$(ls -d "$PAR_OUT/run/cell-"*/.agentis 2>/dev/null | wc -l | tr -d ' ')"
  [ "$NCELLS" -eq 4 ] && ok "each of the 4 cells ran in its OWN run/cell-<slug>_<cls>/.agentis store" \
    || bad "expected 4 isolated per-cell stores, found $NCELLS"
  if python3 - "$PAR_OUT/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["totals"]["steers"] == 0, "STEERS != 0 under --jobs > 1 (cross-cell steering must be off)"
for c in d["cells"]:
    assert c["coordination"] == [], "cell %r has coordination rows under --jobs > 1" % c["subsystem"]
    pref = c["subsystem"] + ":" + c["class"] + ":"
    for x in c["candidates"]:
        assert x.startswith(pref), "cross-cell contamination: %r not under %r" % (x, pref)
PY
  then ok "no cross-cell contamination; STEERS = 0 and every cell's coordination is empty (steering disabled)"
  else bad "isolation / steering-off assertion failed"
  fi
  if grep -q 'Inter-agent coordination' "$PAR_OUT/discovery-report.md"; then
    bad "the parallel report grew a coordination table (steering must be off under --jobs > 1)"
  else
    ok "the parallel report carries no coordination table (consistent with steering off)"
  fi

  note "2b) clamp: --jobs 99 with LLM_MAX_DISCOVERY_CELLS=2 holds concurrency <= 2 ..."
  CLAMP_OUT="$WORK/out-clamp"
  STUB_CTR="$WORK/ctr-clamp"; mkdir -p "$STUB_CTR"
  STUB_CTR="$WORK/ctr-clamp" STUB_SLEEP=0.5 LLM_MAX_DISCOVERY_CELLS=2 \
    "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
    --out "$CLAMP_OUT" --jobs 99 >/dev/null 2>"$WORK/clamp.err"
  RC=$?
  [ "$RC" -eq 0 ] && ok "run-discovery.sh --jobs 99 (clamped) exits 0" \
    || { bad "clamped run exited $RC"; sed 's/^/      /' "$WORK/clamp.err" >&2; }
  MAXC=0; [ -f "$WORK/ctr-clamp/max" ] && MAXC="$(cat "$WORK/ctr-clamp/max")"
  [ "$MAXC" -le 2 ] && ok "the HARD cap held: max $MAXC <= LLM_MAX_DISCOVERY_CELLS=2 despite --jobs 99" \
    || bad "the cap was exceeded under clamp (max $MAXC > 2)"
  grep -q 'clamping concurrency to 2' "$WORK/clamp.err" \
    && ok "run-discovery.sh warned it clamped --jobs 99 to the LLM_MAX_DISCOVERY_CELLS ceiling" \
    || bad "no clamp warning emitted for --jobs 99 over the cap"

  note "5) degrade: a cell whose stub EXITS NON-ZERO still lets the run finish + scrape the rest ..."
  DEG_OUT="$WORK/out-degrade"
  STUB_CTR="$WORK/ctr-degrade"; mkdir -p "$STUB_CTR"
  STUB_CTR="$WORK/ctr-degrade" STUB_SLEEP=0.2 STUB_FAIL_CLASS=C10 \
    "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
    --out "$DEG_OUT" --jobs 3 >/dev/null 2>"$WORK/degrade.err"
  RC=$?
  [ "$RC" -eq 0 ] && ok "run-discovery.sh --jobs 3 with a failing cell still exits 0 (degrades, not aborts)" \
    || { bad "the run aborted on a failing cell (exit $RC)"; sed 's/^/      /' "$WORK/degrade.err" >&2; }
  if grep -q '| C1 |' "$DEG_OUT/discovery-report.md" && grep -q '| C6 |' "$DEG_OUT/discovery-report.md" \
     && grep -q '| C11 |' "$DEG_OUT/discovery-report.md" && ! grep -q '| C10 |' "$DEG_OUT/discovery-report.md"; then
    ok "the 3 healthy cells were scraped; only the forced-failing C10 cell surfaced no candidate"
  else
    bad "degrade scraping is wrong (healthy cells missing or the failing cell surfaced a candidate)"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# (6) READ-ONLY / NEVER-SUBMIT: no network or submission verb anywhere on run-discovery.sh's executable lines.
# ----------------------------------------------------------------------------------------------------------
note "6) read-only / never-submit posture ..."
if grep -vE '^[[:space:]]*#' "$DISCOVERY" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "run-discovery.sh invokes a network/submission verb on an executable line"
else
  ok "run-discovery.sh has no network / no submission verb on any executable line (read-only, never submits)"
fi

# ----------------------------------------------------------------------------------------------------------
# (7) WRAPPED CANDIDATE (#1705): a synthetic PTY-wrapped CANDIDATE record survives extraction whole.
# ----------------------------------------------------------------------------------------------------------
note "7) synthetic PTY-wrapped CANDIDATE record (#1705) is reconstructed whole ..."
WRAP_OUT="$WORK/out-wrap"
STUB_WRAP=1 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$WRAP_OUT" --jobs 1 >/dev/null 2>"$WORK/wrap.err"
RC=$?
[ "$RC" -eq 0 ] && ok "run-discovery.sh --jobs 1 with STUB_WRAP=1 exits 0" \
  || { bad "STUB_WRAP=1 run exited $RC"; sed 's/^/      /' "$WORK/wrap.err" >&2; }

if grep -F 'capture the difference as risk-free profit.' "$WRAP_OUT/discovery-report.md" >/dev/null 2>&1; then
  ok "discovery-report.md's C1 row carries the FULL exploit sentence (not the first-line fragment)"
else
  bad "discovery-report.md's C1 row is missing the wrapped exploit tail — continuation lines were dropped"
fi
if grep -F 'MaliciousDepositor' "$WRAP_OUT/discovery-report.md" >/dev/null 2>&1 \
   && grep -F 'vm.assertGt' "$WRAP_OUT/discovery-report.md" >/dev/null 2>&1; then
  ok "discovery-report.md's C1 row carries a non-empty, fully-joined poc_sketch"
else
  bad "discovery-report.md's C1 row is missing the wrapped poc_sketch tail"
fi

if python3 - "$WRAP_OUT/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
c1 = [c for c in d["cells"] if c["class"] == "C1"]
assert len(c1) == 1, "expected exactly one C1 cell, got %d" % len(c1)
cands = c1[0]["candidates"]
assert len(cands) == 1, "the wrap split into %d candidate(s) for C1 (expected exactly 1)" % len(cands)
body = cands[0]
assert body.count("|") == 4, "expected 5 pipe-delimited fields after CANDIDATE| is stripped, got %d" % (body.count("|") + 1)
assert "capture the difference as risk-free profit." in body, "exploit field truncated in discovery-results.json"
assert "vm.assertGt" in body, "poc_sketch field truncated in discovery-results.json"
PY
then ok "discovery-results.json's C1 candidate is a single, fully-joined record (5 fields, exploit+poc intact)"
else bad "discovery-results.json's C1 candidate is malformed / truncated / split into extra candidates"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — M3 parallel fan-out (run-discovery.sh --jobs N bounded-concurrency + isolated stores) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
