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
#   11-17) #1827 WITHIN-CONTRACT DEPTH PASS (`--depth-max-cells`, default 0 = OFF) + its #1850 ALLOCATION
#          (`--depth-lens-quota`, default 1 - reverted from 3 by #1854):
#      11) INERTNESS: with the flag absent the report is byte-identical to the golden (assertion 1) AND
#          discovery-results.json carries no `phase`, no `totals.depth_cells` and no `totals.depth_lens_quota`
#          key at all.
#      12) WIRING: with the flag on, the stub proves it received DEPTH_TARGET, DEPTH_KNOWN (the verbatim
#          breadth lead) and an IN_SCOPE narrowed to the `file@fn` form — this is what pins the
#          `exec.env_passthrough` registration, without which getenv() silently returns "".
#      13) ACCOUNTING + ORDER: exactly min(cap, planned pairs) depth cells, each `"phase":"depth"`,
#          totals.cells = breadth + depth, totals.depth_cells = depth, totals.depth_lens_quota = the
#          allocation; the order is the ranked QUOTA-round-robin (High location first, other-class lens
#          before the producing one, `quota` consecutive lenses per location per round).
#      13d) COMPATIBILITY PIN: the SAME run at `--depth-lens-quota 1` reproduces #1827's breadth-first
#          spread sequence VERBATIM — the spread arm stays re-derivable with a flag, not a second code path.
#      13e) THE #1850 ACCEPTANCE, OFFLINE: on a 4-class zone at cap 3 an explicit quota 3 puts all three depth
#          cells on ONE function under three DISTINCT lenses (the offline analogue of "hunted under >= 3
#          lenses"); the same fixture at quota 1 gives the top location at most 2 of the 3.
#      14) NO-LEAD ZERO COST: a zone whose breadth cells all answer SAFE emits ZERO depth cells even at cap 12.
#      15) DETERMINISM: two identical runs produce the same depth cell sequence, and the `--jobs 3` depth set
#          equals the serial one (both derive it from the manifest-ordered accumulator, not the blackboard).
#      16) WRAP SAFETY: a `DEPTH-CELL|` line following a wrapped CANDIDATE record is a record BOUNDARY — it is
#          never glued onto the open record as prose and never scraped as a finding.
#      17c) ARG GUARD: `--depth-lens-quota 0` and a non-numeric value both fail fast with exit 2.
#      17) CB SWEEP (needs the agentis binary; clean [SKIP] otherwise): `depth_block()`, EXTRACTED FROM
#          hunter.ag BY LINE RANGE (never copy-pasted, which would drift), completes under a `cb 2000;` probe
#          — the ENFORCED cb_per_tick ceiling — at 1 / 8 / 64 / 256 known leads. The swept dimension is the
#          KNOWN-LEAD COUNT, not the obvious prompt length: a per-element walk over that list would overflow
#          long before 256 and print nothing.
#   18) #1865 IMPLEMENTATION-APPENDIX FRAMING (`--appendix <sidecar>`, absent = OFF):
#      18a) INERTNESS: with the flag absent no cell object carries an `appendix` key (report byte-identity
#           is assertion 1).
#      18b) WIRING: with a sidecar naming one zone, every cell of THAT zone received APPENDIX_FILE=<token>
#           + APPENDIX_BASE=<base> and every cell of the other zones received both EMPTY.
#      18c) ALLOWLIST: the written `exec.env_passthrough` carries both names — without them getenv() returns
#           "" and the whole framing is silently inert (the #1426/#1428 failure mode).
#      18d) SELF-CHECK: a sidecar row whose token is NOT in that manifest line's file list is IGNORED (the
#           duplicate-subsystem-name safety).
#      18e) RECORD: the per-cell `appendix` key is derived from the hunter's own APPENDIX-CONTEXT| sentinel
#           and appended after every pre-existing key; that sentinel is also a record BOUNDARY, so it is
#           never glued onto a PTY-wrapped CANDIDATE record.
#      18f) DEPTH INTERACTION: every `"phase":"depth"` cell receives an EMPTY APPENDIX_FILE (a depth payload
#           IS the narrowed function; framing it as "your contract is abstract" would be a lie).
#      18g) CB SWEEP (needs the agentis binary; clean [SKIP] otherwise): appendix_header/appendix_label/
#           appendix_rule EXTRACTED FROM hunter.ag BY LINE RANGE, under a `cb 2000;` probe, swept over the
#           IN_SCOPE TOKEN COUNT (1/8/32/64) against a CONTROL fold that omits the helper — that count is
#           the only dimension this change touches per element. An N at which the CONTROL itself overflows
#           is [SKIP]ped (a property of the pre-existing reduce, not of this change), never reported as a
#           failure this diff caused.
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
    # #1707: optional TUI-chrome injection — emit chrome (NO CANDIDATE|/SAFE sentinel) for the first
    # STUB_CHROME_ATTEMPTS attempts of each cell (keyed by subsystem+class via STUB_CHROME_CTR), so the demo
    # can prove the scraper RETRIES past chrome and, when it never clears, FAILS LOUDLY with a .novalid marker.
    if [ -n "${STUB_CHROME_CTR:-}" ]; then
      ckey="$(printf '%s' "${SUBSYSTEM:-s}_${HUNT_CLASS:-c}" | tr -cs 'A-Za-z0-9' '_')"
      cf="$STUB_CHROME_CTR/$ckey"
      cn=0; [ -f "$cf" ] && cn="$(cat "$cf")"
      cn=$((cn + 1)); printf '%s' "$cn" > "$cf"
      if [ "$cn" -le "${STUB_CHROME_ATTEMPTS:-0}" ]; then
        printf 'high · /effort\n'
        printf 'esc to interrupt\n'
        exit 0
      fi
    fi
    # #1827: record THIS cell's depth-relevant env so the demo can prove run-discovery.sh really handed
    # DEPTH_TARGET / DEPTH_KNOWN / a narrowed IN_SCOPE through (i.e. that they are on exec.env_passthrough).
    # #1865: APPENDIX_FILE/APPENDIX_BASE ride the same log for the same reason, and are written BEFORE
    # DEPTH_KNOWN: that field is itself a pipe-delimited candidate record, so it must stay the trailing
    # opaque one (readers split with a maxsplit and take the rest).
    if [ -n "${STUB_ENVLOG:-}" ]; then
      printf '%s|%s|%s|%s|%s|%s|%s\n' "${SUBSYSTEM:-}" "${HUNT_CLASS:-}" \
        "$(printf '%s' "${IN_SCOPE:-}" | tr '\n' ' ')" "${DEPTH_TARGET:-}" \
        "${APPENDIX_FILE:-}" "${APPENDIX_BASE:-}" \
        "$(printf '%s' "${DEPTH_KNOWN:-}" | tr '\n' ' ')" >> "$STUB_ENVLOG"
    fi
    # #1827: a DEPTH cell. Mirror hunter.ag's own DEPTH-CELL| diagnostic line, then answer. STUB_DEPTH_WRAP
    # emits a PTY-wrapped CANDIDATE record whose continuation lines are FOLLOWED by that diagnostic line —
    # the shape that would glue "DEPTH-CELL|..." onto the open record as prose without the #1827 boundary.
    if [ -n "${DEPTH_TARGET:-}" ]; then
      if [ "${STUB_DEPTH_WRAP:-}" = "1" ]; then
        printf 'CANDIDATE|contracts/vault/Vault.sol:deposit:10|%s|Medium|a depth lead whose exploit prose\n' "${HUNT_CLASS:-}"
        printf 'wraps across several physical lines before the run ends|1. deploy Reentrant; 2. call\n'
        printf 'deposit() twice in one tx; 3. assert vm.assertEq(shares, 0, "double-counted");\n'
        printf 'DEPTH-CELL|%s|%s|%s\n' "${SUBSYSTEM:-}" "${HUNT_CLASS:-}" "${DEPTH_TARGET:-}"
        exit 0
      fi
      printf 'DEPTH-CELL|%s|%s|%s\n' "${SUBSYSTEM:-}" "${HUNT_CLASS:-}" "${DEPTH_TARGET:-}"
      printf 'SAFE\n'
      exit 0
    fi
    # #1865: a cell whose payload carries the #1861 implementation appendix. Mirror hunter.ag's own
    # APPENDIX-CONTEXT| sentinel (printed before the model call) so the demo can prove the per-cell
    # `appendix` record is derived from the LOG. STUB_APX_WRAP emits a PTY-wrapped CANDIDATE record whose
    # continuation lines are FOLLOWED by that sentinel — the shape that would glue it onto the open record.
    if [ -n "${APPENDIX_FILE:-}" ]; then
      if [ "${STUB_APX_WRAP:-}" = "1" ]; then
        printf 'CANDIDATE|contracts/base/AbstractYield.sol:_withdraw:12|%s|High|an appendix lead whose exploit\n' "${HUNT_CLASS:-}"
        printf 'prose wraps across several physical lines before the sentinel|1. deploy Derived; 2. call\n'
        printf 'withdraw() twice in one tx; 3. assert vm.assertEq(shares, 0, "resolved-behaviour bug");\n'
        printf 'APPENDIX-CONTEXT|%s\n' "${APPENDIX_FILE:-}"
        exit 0
      fi
      printf 'APPENDIX-CONTEXT|%s\n' "${APPENDIX_FILE:-}"
    fi
    # #1707: optional bare-SAFE reply — the legit "rigorous clean" sentinel; must PASS on attempt 1.
    if [ "${STUB_SAFE:-}" = "1" ]; then
      printf 'SAFE\n'
      exit 0
    fi
    # #1827: realistic breadth leads for the depth fixture — TWO distinct functions of the SAME file, flagged
    # by DIFFERENT classes and at different severities. The HIGH one is deliberately surfaced by the SECOND
    # cell (C6) and the MEDIUM one by the FIRST (C1), so severity ranking is NOT confounded with first
    # appearance: dropping the severity criterion flips the expected depth order and fails assertion 13.
    if [ "${STUB_DEPTH:-}" = "1" ]; then
      case "${SUBSYSTEM:-}|${HUNT_CLASS:-}" in
        "vault deposits|C1")
          printf 'CANDIDATE|contracts/vault/Vault.sol:withdraw:20|C1|Medium|depth-fixture medium lead|stub sketch\n' ;;
        "vault deposits|C6")
          printf 'CANDIDATE|contracts/vault/Vault.sol:deposit:10|C6|High|depth-fixture high lead|stub sketch\n' ;;
        *) printf 'SAFE\n' ;;
      esac
      exit 0
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
# (11) #1827 INERTNESS: with no --depth-max-cells the JSON must not grow a depth key ANYWHERE. The byte-identity
# of the report itself is already pinned by the golden comparison above.
if python3 - "$SER_OUT/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert "depth_cells" not in d["totals"], "totals grew depth_cells with the depth pass OFF: %r" % d["totals"]
# #1850: the allocation record rides the SAME gate, so a depth-off run's key set is unchanged by it too.
assert "depth_lens_quota" not in d["totals"], "totals grew depth_lens_quota with the depth pass OFF: %r" % d["totals"]
for c in d["cells"]:
    assert "phase" not in c, "a breadth cell carries a phase key with the depth pass OFF: %r" % c
PY
then ok "11) depth OFF is inert: no totals.depth_cells, no totals.depth_lens_quota, no per-cell phase key (report byte-identity above)"
else bad "11) the depth-off JSON grew a depth key"
fi

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
  # #1707: a cell whose stub EXITS NON-ZERO produces no valid CANDIDATE|/SAFE sentinel, so it is RETRIED and
  # then surfaces as a DISTINCT FAILED row (no longer silently dropped). The 3 healthy cells each still
  # surface their CANDIDATE (3 candidate rows), and the failing C10 cell is a FAILED row, not a candidate.
  DEG_CANDS="$(grep -c 'stub external exploit path' "$DEG_OUT/discovery-report.md" 2>/dev/null || printf '0')"
  if [ "$DEG_CANDS" -eq 3 ] && grep -q '| C1 |' "$DEG_OUT/discovery-report.md" \
     && grep -q '| C6 |' "$DEG_OUT/discovery-report.md" && grep -q '| C11 |' "$DEG_OUT/discovery-report.md" \
     && grep -qF 'FAILED — no CANDIDATE|/SAFE reply' "$DEG_OUT/discovery-report.md"; then
    ok "the 3 healthy cells were scraped as candidates; the forced-failing C10 cell surfaced a distinct FAILED row (#1707), not a silent drop"
  else
    bad "degrade scraping is wrong (healthy candidate count $DEG_CANDS != 3, or no FAILED row for the failing cell)"
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
# (8) #1707 SENTINEL VALIDATION + RETRY: a cell whose reply is TUI chrome (no CANDIDATE|/SAFE) is RETRIED,
#     not silently scraped as a rigorous negative. (a) chrome-then-CANDIDATE recovers; (b) same under
#     --jobs > 1; (c) a legit bare SAFE passes on attempt 1 (no false-reject); (d) chrome-on-all FAILS LOUDLY.
# ----------------------------------------------------------------------------------------------------------
note "8) #1707: a cell that emits chrome then a valid CANDIDATE| is RETRIED and captured (serial) ..."
CHROME_OUT="$WORK/out-chrome-serial"
STUB_CHROME_CTR="$WORK/ctr-chrome-serial"; mkdir -p "$STUB_CHROME_CTR"
DF_AGENT_MAX_ATTEMPTS=2 STUB_CHROME_CTR="$STUB_CHROME_CTR" STUB_CHROME_ATTEMPTS=1 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$CHROME_OUT" --jobs 1 >/dev/null 2>"$WORK/chrome-serial.err"
RC=$?
[ "$RC" -eq 0 ] && ok "run-discovery.sh --jobs 1 with chrome-then-CANDIDATE exits 0" \
  || { bad "chrome-then-CANDIDATE serial run exited $RC"; sed 's/^/      /' "$WORK/chrome-serial.err" >&2; }
if grep -q '| C1 |' "$CHROME_OUT/discovery-report.md" && grep -q '| C6 |' "$CHROME_OUT/discovery-report.md" \
   && grep -q '| C10 |' "$CHROME_OUT/discovery-report.md" && grep -q '| C11 |' "$CHROME_OUT/discovery-report.md"; then
  ok "all 4 cells surfaced a CANDIDATE after the retry (no chrome false-negative)"
else
  bad "a cell was lost to chrome (retry did not recover the CANDIDATE)"
fi
if grep -q 'valid hunter sentinel on attempt 2/2' "$WORK/chrome-serial.err"; then
  ok "the scraper logged a successful retry (valid on attempt 2/2)"
else
  bad "no retry was logged — the chrome reply was not actually retried"
fi
if python3 - "$CHROME_OUT/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["totals"]["failed"] == 0, "a retried-then-valid run must have 0 failed cells: %r" % d["totals"]["failed"]
PY
then ok "discovery-results.json totals.failed == 0 (all cells recovered)"
else bad "totals.failed != 0 despite every cell recovering after retry"
fi

if [ "$PAR_OK" -ne 1 ]; then
  skip "8b) chrome-then-CANDIDATE under --jobs > 1: the bash running run-discovery.sh lacks 'wait -n'"
else
  note "8b) #1707: chrome-then-CANDIDATE is retried + captured under --jobs 3 (parallel) too ..."
  CHROME_PAR="$WORK/out-chrome-par"
  STUB_CHROME_CTR="$WORK/ctr-chrome-par"; mkdir -p "$STUB_CHROME_CTR"
  DF_AGENT_MAX_ATTEMPTS=2 STUB_CHROME_CTR="$STUB_CHROME_CTR" STUB_CHROME_ATTEMPTS=1 STUB_SLEEP=0 \
    "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
    --out "$CHROME_PAR" --jobs 3 >/dev/null 2>"$WORK/chrome-par.err"
  RC=$?
  [ "$RC" -eq 0 ] && ok "run-discovery.sh --jobs 3 with chrome-then-CANDIDATE exits 0" \
    || { bad "chrome-then-CANDIDATE parallel run exited $RC"; sed 's/^/      /' "$WORK/chrome-par.err" >&2; }
  grep '| Medium' "$CHROME_PAR/discovery-report.md" | sort > "$WORK/rows.chrome-par"
  if cmp -s "$WORK/rows.serial" "$WORK/rows.chrome-par"; then
    ok "the parallel chrome-retry candidate rows equal the serial golden rows (retry composes with --jobs > 1)"
  else
    bad "parallel chrome-retry diverged from the serial candidate set:"
    diff "$WORK/rows.serial" "$WORK/rows.chrome-par" | sed 's/^/      /' >&2
  fi
fi

note "9) #1707: a legit bare SAFE reply PASSES on attempt 1 (no false-reject, not FAILED) ..."
SAFE_OUT="$WORK/out-safe"
STUB_CHROME_CTR="$WORK/ctr-safe"; mkdir -p "$STUB_CHROME_CTR"
DF_AGENT_MAX_ATTEMPTS=2 STUB_SAFE=1 STUB_CHROME_CTR="$STUB_CHROME_CTR" STUB_CHROME_ATTEMPTS=0 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$SAFE_OUT" --jobs 1 >/dev/null 2>"$WORK/safe.err"
RC=$?
[ "$RC" -eq 0 ] && ok "run-discovery.sh with an all-SAFE hunter exits 0" \
  || { bad "SAFE run exited $RC"; sed 's/^/      /' "$WORK/safe.err" >&2; }
if grep -q 'valid hunter sentinel on attempt' "$WORK/safe.err"; then
  bad "a bare SAFE reply triggered a spurious retry (false-reject)"
else
  ok "a bare SAFE reply passed on attempt 1 — no spurious retry"
fi
if [ "$(cat "$WORK/ctr-safe/vault_deposits_C1" 2>/dev/null)" = "1" ]; then
  ok "the SAFE cell ran exactly once (counter == 1 — no retry)"
else
  bad "the SAFE cell ran more than once (counter != 1) — false-reject"
fi
if python3 - "$SAFE_OUT/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["totals"]["failed"] == 0, "a clean SAFE run must have 0 failed cells: %r" % d["totals"]["failed"]
assert d["totals"]["candidates"] == 0, "SAFE cells surfaced candidates: %r" % d["totals"]["candidates"]
PY
then ok "totals.failed == 0 and totals.candidates == 0 for the all-SAFE run"
else bad "SAFE run totals wrong (failed != 0 or candidates != 0)"
fi
if grep -q 'rigorous NEGATIVE' "$SAFE_OUT/discovery-report.md"; then
  ok "the all-SAFE run prints the rigorous NEGATIVE line (a clean result is valid)"
else
  bad "the all-SAFE clean run did not print the rigorous NEGATIVE line"
fi

note "10) #1707: chrome on ALL attempts FAILS LOUDLY (.novalid marker + FAILED row, not a silent 0) ..."
FAIL_OUT="$WORK/out-chrome-fail"
STUB_CHROME_CTR="$WORK/ctr-chrome-fail"; mkdir -p "$STUB_CHROME_CTR"
DF_AGENT_MAX_ATTEMPTS=2 STUB_CHROME_CTR="$STUB_CHROME_CTR" STUB_CHROME_ATTEMPTS=99 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$FAIL_OUT" --jobs 1 >/dev/null 2>"$WORK/chrome-fail.err"
RC=$?
[ "$RC" -eq 0 ] && ok "run-discovery.sh with all-chrome cells still exits 0 (marker/counters carry visibility)" \
  || { bad "all-chrome run exited $RC"; sed 's/^/      /' "$WORK/chrome-fail.err" >&2; }
NNV="$(ls "$FAIL_OUT/run/"*.novalid 2>/dev/null | wc -l | tr -d ' ')"
[ "$NNV" -ge 4 ] && ok "each of the 4 cells dropped a .novalid marker ($NNV markers)" \
  || bad "expected >=4 .novalid markers, found $NNV"
if grep -qF 'FAILED — no CANDIDATE|/SAFE reply' "$FAIL_OUT/discovery-report.md"; then
  ok "the report carries a distinct FAILED row for each unassessed cell"
else
  bad "no FAILED row emitted for the all-chrome cells"
fi
if grep -q 'rigorous NEGATIVE' "$FAIL_OUT/discovery-report.md"; then
  bad "an all-chrome (unassessed) run wrongly printed a rigorous NEGATIVE (a silent clean result)"
else
  ok "no rigorous NEGATIVE line — an unassessed run is NOT a clean result"
fi
if python3 - "$FAIL_OUT/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["totals"]["failed"] == 4, "expected 4 failed cells: %r" % d["totals"]["failed"]
assert d["totals"]["candidates"] == 0, "an all-chrome run surfaced candidates: %r" % d["totals"]["candidates"]
failed_cells = [c for c in d["cells"] if c.get("status") == "failed"]
assert len(failed_cells) == 4, "expected 4 status=failed cells, got %d" % len(failed_cells)
PY
then ok "discovery-results.json totals.failed == 4, every failed cell carries status=failed, 0 candidates"
else bad "discovery-results.json failed-cell accounting is wrong"
fi
if grep -q 'no valid hunter sentinel after 2 attempts' "$WORK/chrome-fail.err"; then
  ok "the loud FAILED line was logged to stderr (not a silent 0)"
else
  bad "no loud FAILED line logged for the all-chrome cells"
fi

# ----------------------------------------------------------------------------------------------------------
# (12)+(13) #1827: the depth pass is WIRED (the hunter really receives DEPTH_TARGET/DEPTH_KNOWN/narrowed
#     IN_SCOPE) and ACCOUNTED (cells counted, phase-tagged, totals.depth_cells honest, ranked round-robin).
#
#     The fixture's breadth leads are two DIFFERENT functions of the SAME file, flagged by DIFFERENT classes,
#     with the HIGH one deliberately surfaced by the SECOND cell so severity is not confounded with order:
#       cell 1  C1 -> Vault.sol:withdraw (Medium)  -> class order [C6, C1]  (other lens first, producer last)
#       cell 2  C6 -> Vault.sol:deposit  (High)    -> class order [C1, C6]
#     Ranked High-before-Medium and spent by the #1850 QUOTA-round-robin at an explicit quota 3 (each location
#     takes its whole 2-lens list before the plan moves on), the full plan is
#       1. deposit/C1   2. deposit/C6   3. withdraw/C6   4. withdraw/C1
#     so `--depth-max-cells 3` must take exactly the first three. That sequence still mutation-pins all three
#     ranking/ordering rules the pre-#1850 one did — dropping the severity criterion promotes `withdraw` (it
#     appeared first) and changes it; putting the producing lens first flips every pair — and it now
#     ADDITIONALLY fires if the allocation regresses to the breadth-first spread, which the old expectation
#     could not detect. The spread itself is not lost: (13d) pins it verbatim under `--depth-lens-quota 1`.
# ----------------------------------------------------------------------------------------------------------
note "12) #1827: with --depth-max-cells the hunter receives DEPTH_TARGET / DEPTH_KNOWN / a narrowed IN_SCOPE ..."
DEPTH_OUT="$WORK/out-depth3"
ENVLOG="$WORK/envlog-depth3"; : > "$ENVLOG"
STUB_DEPTH=1 STUB_ENVLOG="$ENVLOG" \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$DEPTH_OUT" --jobs 1 --depth-max-cells 3 --depth-lens-quota 3 >/dev/null 2>"$WORK/depth3.err"
RC=$?
[ "$RC" -eq 0 ] && ok "run-discovery.sh --depth-max-cells 3 exits 0" \
  || { bad "the depth run exited $RC"; sed 's/^/      /' "$WORK/depth3.err" >&2; }
if python3 - "$ENVLOG" <<'PY'
import sys
# maxsplit=6: the 7th field is DEPTH_KNOWN, which is itself a pipe-delimited candidate record, so it is the
# trailing field and everything after the 6th separator belongs to it.
rows = [l.split("|", 6) for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
breadth = [r for r in rows if not r[3]]
depth = [r for r in rows if r[3]]
assert len(breadth) == 4, "expected 4 breadth invocations, got %d" % len(breadth)
assert len(depth) == 3, "expected 3 depth invocations, got %d" % len(depth)
for r in breadth:
    assert r[6] == "", "a breadth cell received a non-empty DEPTH_KNOWN: %r" % r
for r in depth:
    # DEPTH_TARGET is the file@fn form and IN_SCOPE is narrowed to exactly it (the slicer's contract).
    assert "@" in r[3], "DEPTH_TARGET is not a file@fn: %r" % r[3]
    assert r[2].strip() == r[3], "IN_SCOPE %r was not narrowed to the depth target %r" % (r[2], r[3])
    # DEPTH_KNOWN quotes the breadth lead VERBATIM (this is the exclusion the model must not re-report).
    assert "Vault.sol:" in r[6] and "depth-fixture" in r[6], "DEPTH_KNOWN is not the verbatim lead: %r" % r[6]
    fn = r[3].split("@")[1]
    assert (":%s:" % fn) in r[6], "DEPTH_KNOWN %r is not the lead for the target %r" % (r[6], r[3])
PY
then ok "12) every depth cell got DEPTH_TARGET=<file@fn>, IN_SCOPE narrowed to it, and the VERBATIM breadth lead as DEPTH_KNOWN"
else bad "12) the depth env wiring assertion failed"
fi
# The stub is not the real runtime, so it sees the RAW env — passing the vars to it does NOT prove the .ag
# runtime would see them. getenv() reads the SANITIZED env: only exec.env_passthrough-allowlisted names reach
# it, and an unregistered knob is SILENTLY inert (#1426/#1428). So pin the written config directly.
DEPTH_CFG="$DEPTH_OUT/run/.agentis/config"
if [ -f "$DEPTH_CFG" ] \
   && grep '^exec.env_passthrough' "$DEPTH_CFG" | grep -q 'DEPTH_TARGET' \
   && grep '^exec.env_passthrough' "$DEPTH_CFG" | grep -q 'DEPTH_KNOWN'; then
  ok "12b) DEPTH_TARGET + DEPTH_KNOWN are on the written exec.env_passthrough allowlist (else getenv() is silently inert)"
else
  bad "12b) DEPTH_TARGET/DEPTH_KNOWN missing from exec.env_passthrough in $DEPTH_CFG — the depth pass would be inert at runtime"
fi

note "13) #1827/#1850: depth cells are counted, phase-tagged and ordered by the ranked quota-round-robin ..."
if python3 - "$DEPTH_OUT/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
depth = [c for c in d["cells"] if c.get("phase") == "depth"]
breadth = [c for c in d["cells"] if c.get("phase") != "depth"]
assert len(breadth) == 4, "expected 4 breadth cells, got %d" % len(breadth)
assert len(depth) == 3, "expected min(cap=3, 4 planned pairs) = 3 depth cells, got %d" % len(depth)
assert d["totals"]["cells"] == 7, "totals.cells must be breadth+depth = 7, got %r" % d["totals"]["cells"]
assert d["totals"]["depth_cells"] == 3, "totals.depth_cells wrong: %r" % d["totals"]["depth_cells"]
# #1850: the arm records WHICH allocation produced it, so two depth runs can never be compared blind.
assert d["totals"]["depth_lens_quota"] == 3, "totals.depth_lens_quota wrong: %r" % d["totals"].get("depth_lens_quota")
for c in breadth:
    assert "phase" not in c, "a breadth cell was phase-tagged: %r" % c
seq = [(c["class"], c["files"]) for c in depth]
assert seq == [("C1", "contracts/vault/Vault.sol@deposit"),
               ("C6", "contracts/vault/Vault.sol@deposit"),
               ("C6", "contracts/vault/Vault.sol@withdraw")], \
    "the depth order is not the ranked quota-round-robin: %r" % seq
# The depth cell's `files` differs from the breadth cell's, so run-zone-hunt.sh's (subsystem, class, files)
# merge key cannot collapse a depth cell into the breadth cell of the same class.
bkeys = set((c["subsystem"], c["class"], c["files"]) for c in breadth)
for c in depth:
    assert (c["subsystem"], c["class"], c["files"]) not in bkeys, "a depth cell collides with a breadth cell key"
PY
then ok "13) 3 depth cells, each phase=depth, totals.cells = 4+3, totals.depth_cells = 3, totals.depth_lens_quota = 3; order = [deposit/C1, deposit/C6, withdraw/C6]"
else bad "13) the depth accounting / ordering assertion failed"
fi
if [ "$(grep -c '^| ' "$DEPTH_OUT/discovery-report.md" 2>/dev/null || printf '0')" -ge 1 ] \
   && ! grep -q 'DEPTH-CELL' "$DEPTH_OUT/discovery-report.md"; then
  ok "13b) the report carries no DEPTH-CELL| diagnostic text (it is a boundary token, never a finding)"
else
  bad "13b) a DEPTH-CELL| diagnostic leaked into discovery-report.md"
fi
# The cap really binds: at a cap ABOVE the planned pair count the plan is exhausted, never padded.
DEPTH_OUT12="$WORK/out-depth12"
STUB_DEPTH=1 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$DEPTH_OUT12" --jobs 1 --depth-max-cells 12 >/dev/null 2>"$WORK/depth12.err"
if python3 - "$DEPTH_OUT12/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["totals"]["depth_cells"] == 4, "expected all 4 planned pairs at cap 12, got %r" % d["totals"]["depth_cells"]
assert d["totals"]["cells"] == 8, "totals.cells wrong at cap 12: %r" % d["totals"]["cells"]
PY
then ok "13c) at cap 12 the plan is EXHAUSTED at its 4 (location x lens) pairs — min(cap, planned), never padded"
else bad "13c) the depth plan was padded or truncated wrongly at cap 12"
fi

# ----------------------------------------------------------------------------------------------------------
# (13d) #1850 COMPATIBILITY PIN. `--depth-lens-quota 1` must reproduce #1827's breadth-first spread EXACTLY —
#     this expectation is the pre-#1850 assertion 13, kept verbatim. It is what makes the quota a single
#     integer spanning both allocations instead of a second code path, and what keeps #1827's measured arm
#     re-derivable at this commit. MUTATION: break the quota=1 degeneration (e.g. clamp the quota to >= 2, or
#     iterate locations before rounds unconditionally) and this fires while (13) still passes.
# ----------------------------------------------------------------------------------------------------------
note "13d) #1850: --depth-lens-quota 1 reproduces the pre-#1850 breadth-first spread verbatim ..."
DEPTH_Q1="$WORK/out-depth3-q1"
STUB_DEPTH=1 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$DEPTH_Q1" --jobs 1 --depth-max-cells 3 --depth-lens-quota 1 >/dev/null 2>"$WORK/depthq1.err"
if python3 - "$DEPTH_Q1/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
depth = [c for c in d["cells"] if c.get("phase") == "depth"]
assert len(depth) == 3, "expected 3 depth cells at quota 1, got %d" % len(depth)
assert d["totals"]["depth_cells"] == 3, "totals.depth_cells wrong at quota 1: %r" % d["totals"]["depth_cells"]
assert d["totals"]["depth_lens_quota"] == 1, "totals.depth_lens_quota wrong: %r" % d["totals"].get("depth_lens_quota")
seq = [(c["class"], c["files"]) for c in depth]
assert seq == [("C1", "contracts/vault/Vault.sol@deposit"),
               ("C6", "contracts/vault/Vault.sol@withdraw"),
               ("C6", "contracts/vault/Vault.sol@deposit")], \
    "quota 1 did NOT reproduce the #1827 spread: %r" % seq
PY
then ok "13d) at quota 1 the plan is the #1827 spread byte-for-byte: [deposit/C1, withdraw/C6, deposit/C6]"
else bad "13d) --depth-lens-quota 1 did not reproduce the shipped spread"
fi

# (13f) THE DEFAULT PIN. The quota shipped at 3 and was reverted to 1 after the plaza measurement: quota 3
#       found a rare row the spread never did (M-12) but the same run matched fewer rows overall, and because
#       BOTH arms re-hunt the stochastic breadth pass, those losses are not attributable to the allocation.
#       The default is therefore the value whose behaviour is measured, and it must not drift back silently —
#       a default change is a behaviour change for every operator who enables depth without naming a quota.
#       13f is the BEHAVIOURAL half of that guard (it RUNS the tool and reads totals.depth_lens_quota); its
#       orthogonal STATIC twin lives in tools/colony-lint.sh, which greps the default straight out of
#       run-discovery.sh (#1856). Deleting either leaves the other standing — if you weaken one, say so in
#       the other's failure text too.
DEPTH_DEF="$WORK/out-depth3-default"
STUB_DEPTH=1 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$DEPTH_DEF" --jobs 1 --depth-max-cells 3 >/dev/null 2>"$WORK/depthdef.err"
note "13f) #1850: the DEFAULT quota (no flag) is 1 — the spread — not the concentrated allocation ..."
if python3 - "$DEPTH_DEF/discovery-results.json" "$DEPTH_Q1/discovery-results.json" <<'PY'
import sys, json
def depth(p):
    d = json.load(open(p, encoding="utf-8"))
    return d, [(c["class"], c["files"]) for c in d["cells"] if c.get("phase") == "depth"]
dd, sd = depth(sys.argv[1])
dq, sq = depth(sys.argv[2])
assert dd["totals"]["depth_lens_quota"] == 1, \
    "the DEFAULT lens quota is not 1: %r (a default change is a behaviour change — see #1850)" % dd["totals"].get("depth_lens_quota")
assert sd == sq, "the default allocation differs from an explicit --depth-lens-quota 1:\n  default %r\n  quota1  %r" % (sd, sq)
PY
then ok "13f) the default is quota 1 and its depth sequence is identical to an explicit --depth-lens-quota 1"
else bad "13f) the default quota drifted away from the measured-safe value (1)"
fi

# ----------------------------------------------------------------------------------------------------------
# (13e) #1850 ACCEPTANCE, OFFLINE. The issue's acceptance line is "one flagged function is hunted under >= 3
#     distinct lenses at the same total depth budget". The pinned fixture above cannot express it — its zone
#     advertises only 2 classes, so no location HAS a third lens. This uses its OWN scope fixture (the pinned
#     one must not change: assertion 1 is a byte-identical golden comparison) declaring a 4-class zone over
#     the same file. The stub flags `deposit` High under C6 and `withdraw` Medium under C1; C15/C2 answer
#     SAFE. At cap 3 an explicit quota 3 must put ALL THREE cells on the top-ranked function under THREE
#     DISTINCT lenses. The quota-1 arm of the same fixture is the control: it can give the top location at
#     most 2 of the 3 cells, so this pair fails the moment the quota stops concentrating.
# ----------------------------------------------------------------------------------------------------------
note "13e) #1850: on a 4-class zone an explicit quota 3 hunts ONE function under 3 distinct lenses ..."
SCOPE4="$WORK/scope-4class.tsv"
printf 'vault deposits | C1,C6,C15,C2 | contracts/vault/Vault.sol\n' > "$SCOPE4"
Q3_OUT="$WORK/out-4class-q3"
STUB_DEPTH=1 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE4" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$Q3_OUT" --jobs 1 --depth-max-cells 3 --depth-lens-quota 3 >/dev/null 2>"$WORK/q3.err"
Q1_OUT="$WORK/out-4class-q1"
STUB_DEPTH=1 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE4" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$Q1_OUT" --jobs 1 --depth-max-cells 3 --depth-lens-quota 1 >/dev/null 2>"$WORK/q1.err"
if python3 - "$Q3_OUT/discovery-results.json" "$Q1_OUT/discovery-results.json" <<'PY'
import sys, json, collections
def depth_cells(p):
    d = json.load(open(p, encoding="utf-8"))
    return d, [c for c in d["cells"] if c.get("phase") == "depth"]
d3, q3 = depth_cells(sys.argv[1])
d1, q1 = depth_cells(sys.argv[2])
assert len(q3) == 3, "expected 3 depth cells at an explicit quota 3, got %d" % len(q3)
assert d3["totals"]["depth_lens_quota"] == 3, "the explicit --depth-lens-quota 3 was not recorded: %r" % d3["totals"].get("depth_lens_quota")
# THE ACCEPTANCE: one location, three distinct lenses.
locs = collections.Counter(c["files"] for c in q3)
assert len(locs) == 1, "the depth budget still spread over %d locations: %r" % (len(locs), dict(locs))
assert list(locs)[0].endswith("@deposit"), "the concentrated location is not the top-ranked one: %r" % list(locs)
lenses = set(c["class"] for c in q3)
assert len(lenses) == 3, "the concentrated location got %d distinct lenses, expected 3: %r" % (len(lenses), sorted(lenses))
# The CONTROL: the same fixture at quota 1 cannot concentrate — it is the mechanism check, not a tautology.
assert len(q1) == 3, "expected 3 depth cells in the quota-1 control, got %d" % len(q1)
top = collections.Counter(c["files"] for c in q1).most_common(1)[0][1]
assert top <= 2, "the quota-1 control gave the top location %d of 3 cells — the quota is not what concentrates" % top
PY
then ok "13e) at an explicit quota 3 all 3 depth cells hunt Vault.sol@deposit under 3 DISTINCT lenses; the quota-1 control gives its top location at most 2"
else bad "13e) the concentration assertion failed (the depth budget did not exhaust one location)"
fi

# ----------------------------------------------------------------------------------------------------------
# (14) #1827 NO-LEAD ZERO COST: depth is DIRECTED — a zone whose breadth cells produced no lead pays nothing.
# ----------------------------------------------------------------------------------------------------------
note "14) #1827: an all-SAFE breadth pass emits ZERO depth cells even at cap 12 ..."
NOLEAD_OUT="$WORK/out-depth-nolead"
STUB_SAFE=1 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$NOLEAD_OUT" --jobs 1 --depth-max-cells 12 >/dev/null 2>"$WORK/nolead.err"
if python3 - "$NOLEAD_OUT/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["totals"]["depth_cells"] == 0, "an all-SAFE run spent %r depth cell(s)" % d["totals"]["depth_cells"]
assert d["totals"]["cells"] == 4, "an all-SAFE run ran %r cells, expected the 4 breadth ones" % d["totals"]["cells"]
assert not [c for c in d["cells"] if c.get("phase") == "depth"], "an all-SAFE run produced a depth cell"
PY
then ok "14) no breadth lead => 0 depth cells and totals.cells stays at the 4 breadth cells (depth is directed)"
else bad "14) an all-SAFE breadth pass still spent depth cells"
fi

# ----------------------------------------------------------------------------------------------------------
# (15) #1827 DETERMINISM: the depth set is derived from the manifest-ordered accumulator, so it is stable
#      across runs AND identical under --jobs > 1 (where every breadth cell's blackboard is empty — a
#      memo-derived target list would diverge here, which is exactly why it is not memo-derived).
# ----------------------------------------------------------------------------------------------------------
note "15) #1827: the depth cell set is deterministic and --jobs 3 == serial ..."
DEPTH_OUT_B="$WORK/out-depth3b"
STUB_DEPTH=1 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$DEPTH_OUT_B" --jobs 1 --depth-max-cells 3 --depth-lens-quota 3 >/dev/null 2>"$WORK/depth3b.err"
# _depth_seq <out-dir> — the SEQUENCE of depth cells (subsystem|class|files, in cells[] order) read from
# <out-dir>/discovery-results.json. This used to open() the OUT DIR itself, so every call raised
# IsADirectoryError, wrote NOTHING to its stdout redirection, and the two "identical" empty files then
# compared equal under `cmp -s` regardless of the real depth sequence — 15/15b passed VACUOUSLY. The
# emptiness guards below keep that failure mode from coming back silently.
_depth_seq() {
  python3 - "$1/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
for c in d["cells"]:
    if c.get("phase") == "depth":
        print("%s|%s|%s" % (c["subsystem"], c["class"], c["files"]))
PY
}
_depth_seq "$DEPTH_OUT" > "$WORK/depthseq.1"
_depth_seq "$DEPTH_OUT_B" > "$WORK/depthseq.2"
if [ ! -s "$WORK/depthseq.1" ]; then
  bad "15) depth cell sequence extraction produced no rows -- the comparison below would be vacuous"
elif cmp -s "$WORK/depthseq.1" "$WORK/depthseq.2"; then
  ok "15) two identical serial runs produce the same depth cell sequence"
else
  bad "15) the depth cell sequence is not deterministic:"
  diff "$WORK/depthseq.1" "$WORK/depthseq.2" | sed 's/^/      /' >&2
fi
if [ "$PAR_OK" -ne 1 ]; then
  skip "15b) --jobs 3 depth set: the bash running run-discovery.sh lacks 'wait -n'"
else
  DEPTH_PAR="$WORK/out-depth-par"
  STUB_DEPTH=1 STUB_SLEEP=0 \
    "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
    --out "$DEPTH_PAR" --jobs 3 --depth-max-cells 3 --depth-lens-quota 3 >/dev/null 2>"$WORK/depthpar.err"
  _depth_seq "$DEPTH_PAR" > "$WORK/depthseq.par"
  if [ ! -s "$WORK/depthseq.par" ]; then
    bad "15b) depth cell sequence extraction (--jobs 3) produced no rows -- the comparison below would be vacuous"
  elif cmp -s "$WORK/depthseq.1" "$WORK/depthseq.par"; then
    ok "15b) the --jobs 3 depth set equals the serial one (derived from the manifest-ordered accumulator)"
  else
    bad "15b) the --jobs 3 depth set diverged from serial:"
    diff "$WORK/depthseq.1" "$WORK/depthseq.par" | sed 's/^/      /' >&2
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# (16) #1827 WRAP SAFETY: `_join_wrapped_candidates` closes a record on `CANDIDATE|`, `BLACKBOARD-*`, a blank
#      line — and now on `DEPTH-CELL|`. Without that boundary the diagnostic line is appended to the open
#      record as a continuation, corrupting the poc_sketch field with `DEPTH-CELL|<subsystem>|<class>|...`
#      and adding phantom pipe-delimited fields.
# ----------------------------------------------------------------------------------------------------------
note "16) #1827: a DEPTH-CELL| line after a wrapped CANDIDATE is a boundary, not a continuation ..."
DWRAP_OUT="$WORK/out-depth-wrap"
STUB_DEPTH=1 STUB_DEPTH_WRAP=1 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$DWRAP_OUT" --jobs 1 --depth-max-cells 1 >/dev/null 2>"$WORK/depthwrap.err"
RC=$?
[ "$RC" -eq 0 ] && ok "run-discovery.sh --depth-max-cells 1 with a wrapped depth reply exits 0" \
  || { bad "the wrapped depth run exited $RC"; sed 's/^/      /' "$WORK/depthwrap.err" >&2; }
if grep -q 'DEPTH-CELL' "$DWRAP_OUT/discovery-report.md"; then
  bad "16) the DEPTH-CELL| diagnostic was glued onto the wrapped CANDIDATE record and reached the report"
else
  ok "16) no DEPTH-CELL| text in the report — the diagnostic closed the record instead of continuing it"
fi
if python3 - "$DWRAP_OUT/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
depth = [c for c in d["cells"] if c.get("phase") == "depth"]
assert len(depth) == 1, "expected exactly 1 depth cell, got %d" % len(depth)
cands = depth[0]["candidates"]
assert len(cands) == 1, "the wrap + diagnostic split into %d candidate(s)" % len(cands)
body = cands[0]
assert "DEPTH-CELL" not in body, "the diagnostic line was appended to the candidate: %r" % body
assert body.count("|") == 4, "expected 5 pipe-delimited fields, got %d: %r" % (body.count("|") + 1, body)
assert 'vm.assertEq(shares, 0, "double-counted");' in body, "the wrapped poc_sketch tail was lost: %r" % body
PY
then ok "16b) the depth candidate is ONE fully-joined 5-field record; the diagnostic is neither appended nor scraped"
else bad "16b) the wrapped depth candidate is malformed (glued diagnostic / phantom fields / lost tail)"
fi

# ----------------------------------------------------------------------------------------------------------
# (17) #1827 ARG GUARD + CB SWEEP.
# ----------------------------------------------------------------------------------------------------------
note "17) #1827: --depth-max-cells validation + the depth_block() CB sweep ..."
"$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$WORK/out-badval" --depth-max-cells notanumber >/dev/null 2>"$WORK/badval.err"
BADRC=$?
if [ "$BADRC" -eq 2 ] && grep -q 'must be a non-negative integer' "$WORK/badval.err"; then
  ok "17a) --depth-max-cells notanumber fails fast with exit 2 + the usage error"
else
  bad "17a) --depth-max-cells notanumber did not fail fast (exit $BADRC)"
fi

# (17c) #1850: the quota is a POSITIVE integer. 0 is rejected too — a 0-lens quota would emit an EMPTY depth
# plan at a non-zero cap, i.e. silently disable a depth pass the operator explicitly paid for. Both errors
# must NAME the flag and the offending value, and both must fire BEFORE any run side effect.
for _bad in 0 notanumber; do
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE" --brief "$BRIEF" --backend mock --agentis "$STUB" \
    --out "$WORK/out-badquota-$_bad" --depth-max-cells 3 --depth-lens-quota "$_bad" \
    >/dev/null 2>"$WORK/badquota-$_bad.err"
  QRC=$?
  if [ "$QRC" -eq 2 ] \
     && grep -q -- '--depth-lens-quota' "$WORK/badquota-$_bad.err" \
     && grep -q "got '$_bad'" "$WORK/badquota-$_bad.err" \
     && [ ! -d "$WORK/out-badquota-$_bad" ]; then
    ok "17c) --depth-lens-quota $_bad fails fast with exit 2, names the flag + the value, and writes no output dir"
  else
    bad "17c) --depth-lens-quota $_bad did not fail fast (exit $QRC)"
  fi
done

# The CB sweep runs the SHIPPED depth_block(), EXTRACTED FROM hunter.ag BY LINE RANGE — a copy-pasted twin
# would silently drift from the agent it claims to measure. `cb 2000;` is the ENFORCED per-tick ceiling
# (cb_per_tick's default), not the declarative `cb 300000;` header the one-shot `agentis go` path uses; the
# swept dimension is the KNOWN-LEAD COUNT, because a per-element walk over DEPTH_KNOWN is the failure mode
# this design refuses (it would overflow well before 256 leads and print nothing).
HUNTER_AG="$HERE/auditor/agents/hunter.ag"
if ! command -v agentis >/dev/null 2>&1; then
  skip "17b) depth_block() CB sweep — no agentis binary on PATH"
elif [ ! -f "$HUNTER_AG" ]; then
  bad "17b) hunter.ag not found at $HUNTER_AG"
else
  DB_FRAG="$WORK/depth_block.frag"
  awk '/^fn depth_block\(/{f=1} f{print} f&&/^}$/{exit}' "$HUNTER_AG" > "$DB_FRAG"
  if ! grep -q '^fn depth_block(' "$DB_FRAG"; then
    bad "17b) could not extract depth_block() from hunter.ag by line range (was it renamed?)"
  else
    CB_OK=1
    for N in 1 8 64 256; do
      KNOWN=""; i=0
      while [ "$i" -lt "$N" ]; do
        KNOWN="${KNOWN}- contracts/vault/Vault.sol:deposit:10|C1|High|known lead $i|sketch $i\\n"
        i=$((i + 1))
      done
      SANDBOX="$WORK/cb-$N"; rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
      ( cd "$SANDBOX" && agentis init >/dev/null 2>&1 ) || true
      {
        printf 'cb 2000;\n\n'
        cat "$DB_FRAG"
        printf '\n\nprint("DEPTHLEN=" + to_string(len(depth_block("contracts/vault/Vault.sol@deposit", "%s"))));\n' "$KNOWN"
      } > "$SANDBOX/probe.ag"
      CB_OUT="$( cd "$SANDBOX" && agentis go probe.ag 2>&1 | grep '^DEPTHLEN=' | tail -1 )"
      CB_LEN="${CB_OUT#DEPTHLEN=}"
      case "$CB_LEN" in
        ''|*[!0-9]*) bad "17b) depth_block() did NOT complete under cb 2000 at $N known lead(s) (overflow / no output)"; CB_OK=0 ;;
        *) [ "$CB_LEN" -gt 0 ] || { bad "17b) depth_block() returned an EMPTY block at $N known lead(s)"; CB_OK=0; } ;;
      esac
    done
    [ "$CB_OK" -eq 1 ] && ok "17b) depth_block() completes under cb 2000 (the enforced cb_per_tick) with a non-empty block at 1/8/64/256 known leads"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# (18) #1865 IMPLEMENTATION-APPENDIX FRAMING (`--appendix <sidecar>`, absent = OFF).
#      #1861 already routes the derived implementor's slice into the hunter's payload; what this adds is the
#      FRAMING (the labelled section + the resolved-behaviour/anchoring rules) and the RECORD (the
#      APPENDIX-CONTEXT| sentinel -> the per-cell `appendix` key), at parity with the refute gate's
#      AUX-CONTEXT| / aux.txt. The fixture below is a second scope + sidecar, deliberately generic:
#        zone `abstract base`   files contracts/base/AbstractYield.sol,contracts/impl/Strategy.sol@_mint+_burn
#                               sidecar row -> token = the Strategy slice, base = AbstractYield.sol
#        zone `plain vault` / `rewards distributor`  no sidecar row at all (the control arms)
# ----------------------------------------------------------------------------------------------------------
note "18) #1865: the implementation-appendix framing is inert by default and wired when the sidecar names it ..."

# (18a) INERTNESS: the block-1 serial run carries no --appendix, so no cell object may grow the key. The
# report's byte-identity against the golden is already pinned by assertion 1.
if python3 - "$SER_OUT/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
for c in d["cells"]:
    assert "appendix" not in c, "a cell grew an appendix key with no --appendix given: %r" % c
PY
then ok "18a) with no --appendix no cell object carries an appendix key (and the report is byte-identical to the golden, assertion 1)"
else bad "18a) the appendix-off JSON grew an appendix key"
fi

mkdir -p "$REPO/contracts/base" "$REPO/contracts/impl"
printf 'abstract contract AbstractYield {}\n' > "$REPO/contracts/base/AbstractYield.sol"
printf 'contract Strategy is AbstractYield {}\n' > "$REPO/contracts/impl/Strategy.sol"
APX_TOKEN="contracts/impl/Strategy.sol@_mint+_burn"
APX_BASE="contracts/base/AbstractYield.sol"

SCOPE_APX="$WORK/scope-appendix.tsv"
{
  printf 'abstract base | C1,C6 | contracts/base/AbstractYield.sol,%s\n' "$APX_TOKEN"
  printf 'plain vault | C1 | contracts/vault/Vault.sol\n'
  printf 'rewards distributor | C11 | contracts/rewards/Rewards.sol\n'
} > "$SCOPE_APX"

# The sidecar map-zones.sh writes: TAB-delimited <subsystem> <token> <base>, one row per ATTACHING zone.
APX_TSV="$WORK/appendix.tsv"
{
  printf '# auto-generated by map-zones.sh (#1865)\n'
  printf 'abstract base\t%s\t%s\n' "$APX_TOKEN" "$APX_BASE"
} > "$APX_TSV"

APX_OUT="$WORK/out-appendix"
APX_ENVLOG="$WORK/envlog-appendix"; : > "$APX_ENVLOG"
STUB_ENVLOG="$APX_ENVLOG" \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE_APX" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$APX_OUT" --jobs 1 --appendix "$APX_TSV" >/dev/null 2>"$WORK/appendix.err"
RC=$?
[ "$RC" -eq 0 ] && ok "run-discovery.sh --appendix exits 0" \
  || { bad "the --appendix run exited $RC"; sed 's/^/      /' "$WORK/appendix.err" >&2; }

# (18b) WIRING: every cell of the NAMED zone received the exact token + base; every cell of the other zones
# received both EMPTY. Without this the feature could be staged and never actually handed to the runtime.
if python3 - "$APX_ENVLOG" "$APX_TOKEN" "$APX_BASE" <<'PY'
import sys
rows = [l.split("|", 6) for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
tok, base = sys.argv[2], sys.argv[3]
named = [r for r in rows if r[0] == "abstract base"]
others = [r for r in rows if r[0] != "abstract base"]
assert len(named) == 2, "expected 2 cells for the appendix zone, got %d" % len(named)
assert len(others) == 2, "expected 2 cells for the control zones, got %d" % len(others)
for r in named:
    assert r[4] == tok, "APPENDIX_FILE %r is not the sidecar token %r" % (r[4], tok)
    assert r[5] == base, "APPENDIX_BASE %r is not the sidecar base %r" % (r[5], base)
    assert tok in r[2], "the appendix token is not even in that cell's IN_SCOPE: %r" % r[2]
for r in others:
    assert r[4] == "" and r[5] == "", "a zone with no sidecar row received an appendix: %r" % r
PY
then ok "18b) every cell of the sidecar-named zone received APPENDIX_FILE=<token> + APPENDIX_BASE=<base>; every cell of the unnamed zones received both EMPTY"
else bad "18b) the appendix env wiring assertion failed"
fi

# (18c) ALLOWLIST: getenv() reads the SANITIZED env, so an unregistered knob is silently inert (#1426/#1428).
# The stub sees the RAW env, so 18b alone cannot prove the .ag runtime would see anything — pin the config.
APX_CFG="$APX_OUT/run/.agentis/config"
if [ -f "$APX_CFG" ] \
   && grep '^exec.env_passthrough' "$APX_CFG" | grep -q 'APPENDIX_FILE' \
   && grep '^exec.env_passthrough' "$APX_CFG" | grep -q 'APPENDIX_BASE'; then
  ok "18c) APPENDIX_FILE + APPENDIX_BASE are on the written exec.env_passthrough allowlist (else getenv() is silently inert)"
else
  bad "18c) APPENDIX_FILE/APPENDIX_BASE missing from exec.env_passthrough in $APX_CFG — the framing would be inert at runtime"
fi

# (18e) RECORD: the cell object's `appendix` key is derived from the hunter's own APPENDIX-CONTEXT| line, so
# it records what the AGENT framed, and only the framed cells carry it.
if python3 - "$APX_OUT/discovery-results.json" "$APX_TOKEN" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
tok = sys.argv[2]
for c in d["cells"]:
    if c["subsystem"] == "abstract base":
        assert c.get("appendix") == tok, "the framed cell's appendix key is %r, not %r" % (c.get("appendix"), tok)
    else:
        assert "appendix" not in c, "an unframed cell carries an appendix key: %r" % c
    # The key is appended LAST, after `phase` — the forward key scan _plan_depth_cells does must still see
    # subsystem -> class -> files -> status -> candidates in that order.
    keys = list(c.keys())
    assert keys[:5] == ["subsystem", "class", "files", "status", "candidates"], "key order changed: %r" % keys
    if "appendix" in keys:
        assert keys[-1] == "appendix", "the appendix key is not last: %r" % keys
PY
then ok "18e) the framed cells record appendix=<token> (derived from the log sentinel, appended after every pre-existing key); unframed cells carry no such key"
else bad "18e) the per-cell appendix record is missing, mis-keyed or reordered"
fi

# (18e, wrap safety) an APPENDIX-CONTEXT| line following a PTY-wrapped CANDIDATE record is a record BOUNDARY.
AWRAP_OUT="$WORK/out-appendix-wrap"
STUB_APX_WRAP=1 \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE_APX" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$AWRAP_OUT" --jobs 1 --appendix "$APX_TSV" >/dev/null 2>"$WORK/appendix-wrap.err"
RC=$?
[ "$RC" -eq 0 ] && ok "run-discovery.sh --appendix with a wrapped reply exits 0" \
  || { bad "the wrapped appendix run exited $RC"; sed 's/^/      /' "$WORK/appendix-wrap.err" >&2; }
if grep -q 'APPENDIX-CONTEXT' "$AWRAP_OUT/discovery-report.md"; then
  bad "18e2) the APPENDIX-CONTEXT| sentinel was glued onto the wrapped CANDIDATE record and reached the report"
elif python3 - "$AWRAP_OUT/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
framed = [c for c in d["cells"] if c["subsystem"] == "abstract base"]
assert framed, "no cell for the appendix zone"
for c in framed:
    assert len(c["candidates"]) == 1, "the wrap + sentinel split into %d candidate(s)" % len(c["candidates"])
    body = c["candidates"][0]
    assert "APPENDIX-CONTEXT" not in body, "the sentinel was appended to the candidate: %r" % body
    assert body.count("|") == 4, "expected 5 pipe-delimited fields, got %d: %r" % (body.count("|") + 1, body)
    assert 'vm.assertEq(shares, 0, "resolved-behaviour bug");' in body, "the wrapped poc_sketch tail was lost: %r" % body
PY
then ok "18e2) an APPENDIX-CONTEXT| line after a wrapped CANDIDATE closes the record: one fully-joined 5-field candidate, no sentinel text in it and none in the report"
else bad "18e2) the wrapped appendix candidate is malformed (glued sentinel / phantom fields / lost tail)"
fi

# (18d) SELF-CHECK: map-zones.sh keys sidecar rows on the subsystem NAME, which is not unique across
# scope.tsv lines. A row whose token is not literally in THAT line's file list must be IGNORED — otherwise a
# duplicate zone name would frame a payload that has no appendix section at all.
BAD_TSV="$WORK/appendix-mismatch.tsv"
printf 'abstract base\tcontracts/nowhere/Ghost.sol@_mint\t%s\n' "$APX_BASE" > "$BAD_TSV"
MISS_OUT="$WORK/out-appendix-mismatch"
MISS_ENVLOG="$WORK/envlog-appendix-mismatch"; : > "$MISS_ENVLOG"
STUB_ENVLOG="$MISS_ENVLOG" \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE_APX" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$MISS_OUT" --jobs 1 --appendix "$BAD_TSV" >/dev/null 2>"$WORK/appendix-mismatch.err"
RC=$?
if [ "$RC" -ne 0 ]; then
  bad "18d) the mismatched-sidecar run exited $RC"; sed 's/^/      /' "$WORK/appendix-mismatch.err" >&2
elif python3 - "$MISS_ENVLOG" "$MISS_OUT/discovery-results.json" <<'PY'
import sys, json
rows = [l.split("|", 6) for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
assert rows, "the mismatched-sidecar run invoked no cell at all"
for r in rows:
    assert r[4] == "" and r[5] == "", "a row whose token is NOT in FILES_CSV was still staged: %r" % r
d = json.load(open(sys.argv[2], encoding="utf-8"))
for c in d["cells"]:
    assert "appendix" not in c, "a cell recorded an appendix from an unusable sidecar row: %r" % c
PY
then ok "18d) a sidecar row whose token is not in that manifest line's file list is IGNORED (both env vars empty, no cell record) — the duplicate-subsystem-name safety"
else bad "18d) an unusable sidecar row was staged anyway"
fi

# (18f) DEPTH INTERACTION: a depth payload IS the narrowed function, so framing it as "your contract is
# abstract, the last section implements it" would be a lie about that payload — depth cells get EMPTY.
# The fixture is deliberately ordered so the FRAMED zone is the LAST manifest line AND the one whose breadth
# leads produce the depth plan: the per-line pair is resolved in a shell variable, so any depth call site that
# forwarded it would forward the value left over from that last line. With the framed zone anywhere else the
# leak would be masked by an empty leftover and this assertion could not fail.
SCOPE_DAPX="$WORK/scope-appendix-depth.tsv"
{
  printf 'rewards distributor | C11 | contracts/rewards/Rewards.sol\n'
  printf 'vault deposits | C1,C6 | contracts/vault/Vault.sol\n'
} > "$SCOPE_DAPX"
DAPX_TSV="$WORK/appendix-depth.tsv"
printf 'vault deposits\tcontracts/vault/Vault.sol\t%s\n' "$APX_BASE" > "$DAPX_TSV"
DAPX_OUT="$WORK/out-appendix-depth"
DAPX_ENVLOG="$WORK/envlog-appendix-depth"; : > "$DAPX_ENVLOG"
STUB_DEPTH=1 STUB_ENVLOG="$DAPX_ENVLOG" \
  "$DISCOVERY" --repo "$REPO" --scope "$SCOPE_DAPX" --brief "$BRIEF" --backend mock --agentis "$STUB" \
  --out "$DAPX_OUT" --jobs 1 --depth-max-cells 3 --depth-lens-quota 3 --appendix "$DAPX_TSV" \
  >/dev/null 2>"$WORK/appendix-depth.err"
RC=$?
if [ "$RC" -ne 0 ]; then
  bad "18f) the appendix + depth run exited $RC"; sed 's/^/      /' "$WORK/appendix-depth.err" >&2
elif python3 - "$DAPX_ENVLOG" <<'PY'
import sys
rows = [l.split("|", 6) for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
depth = [r for r in rows if r[3]]
breadth = [r for r in rows if not r[3]]
assert depth, "the fixture produced no depth cell at all"
for r in depth:
    assert r[4] == "" and r[5] == "", "a depth cell was framed as carrying an implementation appendix: %r" % r
framed = [r for r in breadth if r[0] == "vault deposits"]
assert framed, "no breadth cell for the sidecar-named zone"
for r in framed:
    assert r[4] == "contracts/vault/Vault.sol", "the breadth cell lost its appendix while depth was on: %r" % r
PY
then ok "18f) with a sidecar AND --depth-max-cells every depth cell receives an EMPTY APPENDIX_FILE while the zone's breadth cells keep theirs"
else bad "18f) a depth cell was framed with an implementation appendix"
fi

# (18g) CB SWEEP of the three new hunter.ag helpers, EXTRACTED BY LINE RANGE (a copy-pasted twin would drift
# from the agent it claims to measure). `cb 2000;` is the ENFORCED per-tick ceiling, not the declarative
# `cb 300000;` header. The swept dimension is the IN_SCOPE TOKEN COUNT, because that is the only dimension
# this change makes per-element: appendix_label is folded over the EXISTING scoped_code reduce. The control
# is the same fold WITHOUT the helper, so the assertion is a delta ("the labelled fold clears every N the
# control clears"), not an absolute budget the fixture's own prose size could dominate.
if ! command -v agentis >/dev/null 2>&1; then
  skip "18g) appendix helper CB sweep — no agentis binary on PATH"
elif [ ! -f "$HUNTER_AG" ]; then
  bad "18g) hunter.ag not found at $HUNTER_AG"
else
  APX_FRAG="$WORK/appendix_helpers.frag"
  : > "$APX_FRAG"
  for _fn in appendix_header appendix_label appendix_rule; do
    awk -v want="^fn $_fn\\\\(" '$0 ~ want {f=1} f{print} f&&/^}$/{exit}' "$HUNTER_AG" >> "$APX_FRAG"
    printf '\n' >> "$APX_FRAG"
  done
  MISSING_FN=""
  for _fn in appendix_header appendix_label appendix_rule; do
    grep -q "^fn $_fn(" "$APX_FRAG" || MISSING_FN="$MISSING_FN $_fn"
  done
  if [ -n "$MISSING_FN" ]; then
    bad "18g) could not extract from hunter.ag by line range (renamed?):$MISSING_FN"
  else
    APX_CB_OK=1
    APX_CB_NS=""
    for N in 1 8 32 64; do
      TOKENS=""; i=0
      while [ "$i" -lt "$N" ]; do
        TOKENS="${TOKENS}contracts/z/File$i.sol@fnA+fnB\\n"
        i=$((i + 1))
      done
      SANDBOX="$WORK/cb-apx-$N"; rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
      ( cd "$SANDBOX" && agentis init >/dev/null 2>&1 ) || true
      {
        printf 'cb 2000;\n\n'
        cat "$APX_FRAG"
        # CONTROL fold: the pre-#1865 scoped_code shape (labelled section headers, no helper).
        printf 'fn fold_control(files: string) -> string {\n'
        printf '    return reduce(regex_split("\\n", files), |acc: string, rel: string| -> string {\n'
        printf '        if len(rel) == 0 { return acc; }\n'
        printf '        return acc + "\\n\\n// ========== " + rel + " ==========\\n";\n'
        printf '    }, "");\n}\n\n'
        # TREATMENT fold: the same reduce with appendix_label spliced in, exactly as scoped_code does.
        printf 'fn fold_labelled(files: string, apx: string, base: string) -> string {\n'
        printf '    return reduce(regex_split("\\n", files), |acc: string, rel: string| -> string {\n'
        printf '        if len(rel) == 0 { return acc; }\n'
        printf '        return acc + "\\n\\n// ========== " + rel + " ==========\\n" + appendix_label(rel, apx, base);\n'
        printf '    }, "");\n}\n\n'
        printf 'let toks = "%s";\n' "$TOKENS"
        printf 'print("CTRLLEN=" + to_string(len(fold_control(toks))));\n'
        printf 'print("APXLEN=" + to_string(len(fold_labelled(toks, "contracts/z/File0.sol@fnA+fnB", "contracts/base/AbstractYield.sol"))));\n'
        printf 'print("RULELEN=" + to_string(len(appendix_rule("contracts/z/File0.sol@fnA+fnB", "contracts/base/AbstractYield.sol"))));\n'
      } > "$SANDBOX/probe.ag"
      APX_RAW="$( cd "$SANDBOX" && agentis go probe.ag 2>&1 )"
      CTRL_LEN="$(printf '%s\n' "$APX_RAW" | grep '^CTRLLEN=' | tail -1)"; CTRL_LEN="${CTRL_LEN#CTRLLEN=}"
      TREAT_LEN="$(printf '%s\n' "$APX_RAW" | grep '^APXLEN=' | tail -1)"; TREAT_LEN="${TREAT_LEN#APXLEN=}"
      RULE_LEN="$(printf '%s\n' "$APX_RAW" | grep '^RULELEN=' | tail -1)"; RULE_LEN="${RULE_LEN#RULELEN=}"
      case "$CTRL_LEN" in
        ''|*[!0-9]*)
          # The CONTROL itself did not clear cb 2000 at this N — that is a property of the pre-existing fold,
          # not of this change. Report it as a skip rather than a regression this diff caused.
          skip "18g) N=$N: the CONTROL fold (no appendix helper) did not complete under cb 2000 — nothing to compare"
          continue ;;
      esac
      case "$TREAT_LEN" in
        ''|*[!0-9]*) bad "18g) the labelled fold did NOT complete under cb 2000 at $N in-scope token(s) while the control did"; APX_CB_OK=0; continue ;;
      esac
      if [ "$TREAT_LEN" -le "$CTRL_LEN" ]; then
        bad "18g) at $N token(s) the labelled fold added no header for the matching token (len $TREAT_LEN <= control $CTRL_LEN)"
        APX_CB_OK=0
      fi
      case "$RULE_LEN" in
        ''|*[!0-9]*) bad "18g) appendix_rule() did not complete under cb 2000 at $N token(s)"; APX_CB_OK=0 ;;
        *) [ "$RULE_LEN" -gt 0 ] || { bad "18g) appendix_rule() returned an EMPTY block at $N token(s)"; APX_CB_OK=0; } ;;
      esac
      APX_CB_NS="${APX_CB_NS:+$APX_CB_NS/}$N"
    done
    [ "$APX_CB_OK" -eq 1 ] && ok "18g) appendix_header/appendix_label/appendix_rule complete under cb 2000 (the enforced cb_per_tick) at ${APX_CB_NS:-no} in-scope token count(s) — every N whose CONTROL fold also cleared — and the labelled fold labels exactly the matching token"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — M3 parallel fan-out (run-discovery.sh --jobs N bounded-concurrency + isolated stores) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
