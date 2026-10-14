#!/usr/bin/env bash
# demo-usage-limit.sh — proof of the #2291 usage-limit halt on the live hunt path (M1: STAGES 1-4).
#
# THE BUG (#2291): when the driven Claude session hits its usage quota it prints a notice ("You've hit your weekly
# limit · resets <when>") instead of an answer. The hunt read it as TUI chrome: retried it, then recorded a FAILED
# cell, a `hunted_degraded` zone and carried on — so a quota outage looked like a tool failure, every later call
# burned the same quota, and the run reported a partial sweep as finished. The fix: ONE shared regex
# (lib/usage_limit.py), a check at the one chokepoint every breadth / refute model call passes through
# (lib/run-agent-validated.sh), a run-level halt file, a `limit_halted` coverage status, exit 6, and a resume
# through the existing `run-zone-hunt.sh --rehunt-gaps`.
#
# Offline and CI-safe: --backend mock + the exam fixture's agentis stub (no agentis / flat-cyborg / forge / LLM /
# network). The notice is always READ from the fixture file, never printed with escapes (CI `sh` is dash).
#   1) shared module: usage_limit.py --self-test + a drift guard (the literal regex lives in ONE tracked file).
#   2) helper level: the marker / halt-file / call-count semantics of df_run_agent_validated.
#   3) end to end: a 3-zone sweep halts on the 2nd zone (serial and --jobs 2), resumes with --rehunt-gaps, and a
#      STAGE 1 halt exits 6 before any coverage record exists.
#   4) M2, STAGE 4.5: a prover cell that prints the notice is TRANSIENT_ERROR (not HARNESS_ERROR) and writes the halt;
#      the scheduler settles every later cell SKIPPED_LIMIT, the legacy serial loop launches no further row, the run
#      exits 6, and `--deep-hunt-only --deep-hunt-resume` re-runs exactly the halted + unlaunched cells. The offline
#      STAGE 4.5 harness is a reduced copy of demo-deep-hunt-budget.sh's (fixture repo, prover stub, breadth base).
#
# Usage:  dark-factory/demo-usage-limit.sh
# Exit: 0 = all assertions hold ; 1 = a regression ; 3 = a script / fixture is missing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib/run-agent-validated.sh"
ULPY="$HERE/lib/usage_limit.py"
ZONEHUNT="$HERE/run-zone-hunt.sh"
FX="$HERE/bench/corpus-bench/fixtures/exam"
STUB="$FX/agentis-stub.sh"
NOTICE="$HERE/bench/corpus-bench/fixtures/exam-void/weekly-limit-notice.txt"

FAILS=0
note() { echo "demo-usage-limit.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

for f in "$LIB" "$ULPY" "$ZONEHUNT" "$STUB" "$NOTICE" "$FX/project/src/pool/Pool.sol"; do
  [ -f "$f" ] || { note "missing: $f" >&2; exit 3; }
done
command -v python3 >/dev/null 2>&1 || { note "[SKIP] python3 not installed"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-usage-limit.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
note "1) the shared module and its single definition ..."
if python3 "$ULPY" --self-test >/dev/null 2>"$WORK/st.err"; then
  ok "usage_limit.py --self-test: the notice fixture + usage/session/5-hour positives match; rate-limit / prose / CANDIDATE negatives do not"
else
  bad "usage_limit.py --self-test regressed"; sed 's/^/      /' "$WORK/st.err"
fi
# Drift guard: the literal regex appears in no other tracked .py/.sh/.tsv file under dark-factory/ (it used to be
# copied into exam/void-patterns.tsv and model-attribution.py). This file spells the needle in two halves so it
# never matches itself.
NEEDLE="hit your ""(weekly"
if git -C "$HERE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  DRIFT="$(git -C "$HERE" ls-files -- '*.py' '*.sh' '*.tsv' | while IFS= read -r tf; do
      grep -Fl "$NEEDLE" "$HERE/$tf" 2>/dev/null; done | grep -v '/lib/usage_limit\.py$' || true)"
else
  DRIFT="$(grep -rFl --include='*.py' --include='*.sh' --include='*.tsv' "$NEEDLE" "$HERE" | grep -v '/lib/usage_limit\.py$' || true)"
fi
if [ -z "$DRIFT" ] && grep -Fq "$NEEDLE" "$ULPY"; then
  ok "drift guard: the usage-limit regex is defined ONLY in lib/usage_limit.py"
else
  bad "drift guard: a second copy of the usage-limit regex exists: ${DRIFT:-<none, but usage_limit.py lost it>}"
fi

# ----------------------------------------------------------------------------------------------------------
note "2) helper level: df_run_agent_validated on a usage-limit notice ..."
# shellcheck source=lib/run-agent-validated.sh
# shellcheck disable=SC1091
. "$LIB"
CALLC="$WORK/calls"; MODE="$WORK/mode"; LOG="$WORK/cell.log"
# shellcheck disable=SC2317,SC2329  # invoked by name through df_run_agent_validated
_ul_attempt() {
  _n="$(cat "$CALLC" 2>/dev/null || echo 0)"; _n=$((_n + 1)); printf '%s' "$_n" > "$CALLC"
  case "$(cat "$MODE")" in
    notice)    cat "$NOTICE" > "$1" ;;
    notice+tr) { cat "$NOTICE"; printf '%s\n' 'Error: runtime error: LLM transport error: flat-cyborg exited with status 1'; } > "$1" ;;
    quoted)    { printf '%s\n' 'CANDIDATE|src/pool/Pool.sol:withdraw:17|C1|High|the comment says you have'; cat "$NOTICE"; } > "$1" ;;
  esac
}
run_mode() {  # run_mode <mode> — sets RC and CALLS
  printf '%s' "$1" > "$MODE"; : > "$CALLC"; rm -f "$LOG" "$LOG".*
  df_run_agent_validated 5 "demo-usage-limit" "$LOG" hunter "" _ul_attempt 2>>"$WORK/helper.err"
  RC=$?; CALLS="$(cat "$CALLC")"; CALLS="${CALLS:-0}"
}
export DF_USAGE_LIMIT_HALT="$WORK/halt"
rm -f "$DF_USAGE_LIMIT_HALT"
run_mode notice
if [ "$RC" -eq 1 ] && [ "$CALLS" -eq 1 ] && [ -f "$LOG.novalid" ] && [ -f "$LOG.limit" ] && [ ! -f "$LOG.timeout" ] \
   && [ -f "$DF_USAGE_LIMIT_HALT" ] && [ "$(cut -f2 "$DF_USAGE_LIMIT_HALT")" = demo-usage-limit ] \
   && [ "$(cut -f5 "$DF_USAGE_LIMIT_HALT")" = "$(head -1 "$NOTICE")" ]; then
  ok "a notice: exactly 1 call (no retry), .novalid + .limit, the halt file holds the evidence line"
else
  bad "notice: rc=$RC calls=$CALLS markers=$(for m in "$LOG".*; do [ -e "$m" ] && printf '%s ' "${m##*cell.log}"; done) halt=$(cat "$DF_USAGE_LIMIT_HALT" 2>/dev/null)"
fi
rm -f "$DF_USAGE_LIMIT_HALT"
run_mode notice+tr
if [ "$RC" -eq 1 ] && [ "$CALLS" -eq 1 ] && [ -f "$LOG.limit" ] && [ ! -f "$LOG.transient" ]; then
  ok "a notice + a terminal transport error: still 1 call, .limit and no .transient (the limit ranks above transport)"
else
  bad "notice+transport: rc=$RC calls=$CALLS (expected 1 call, .limit, no .transient)"
fi
run_mode notice   # the halt file from the previous scenario is still there
if [ "$RC" -eq 1 ] && [ "$CALLS" -eq 0 ] && [ -f "$LOG.novalid" ] && [ -f "$LOG.limit" ] && [ ! -s "$LOG" ]; then
  ok "the run is already halted: 0 calls, the log is empty, .novalid + .limit"
else
  bad "already halted: rc=$RC calls=$CALLS (expected 0 calls + markers)"
fi
rm -f "$DF_USAGE_LIMIT_HALT"
run_mode quoted
if [ "$RC" -eq 0 ] && [ "$CALLS" -eq 1 ] && [ ! -f "$LOG.limit" ] && [ ! -f "$LOG.novalid" ] && [ ! -f "$DF_USAGE_LIMIT_HALT" ]; then
  ok "a valid CANDIDATE| reply that quotes the notice is valid: no marker, no halt (only sentinel-less replies are scanned)"
else
  bad "quoted: rc=$RC calls=$CALLS (a valid reply must never trip the halt)"
fi
unset DF_USAGE_LIMIT_HALT
if ( set -u; run_mode notice; [ "$RC" -eq 1 ] && [ "$CALLS" -eq 1 ] && [ -f "$LOG.limit" ] ) 2>"$WORK/unset.err" \
   && ! grep -q 'unbound variable' "$WORK/unset.err"; then
  ok "DF_USAGE_LIMIT_HALT unset: the .limit marker only, no set -u error"
else
  bad "DF_USAGE_LIMIT_HALT unset: $(head -3 "$WORK/unset.err")"
fi

# ----------------------------------------------------------------------------------------------------------
note "3) end to end: a 3-zone sweep halts on the usage limit and resumes with --rehunt-gaps ..."
REPO="$WORK/project"
cp -r "$FX/project" "$REPO"
mkdir -p "$REPO/src/vault"
cat > "$REPO/src/vault/Vault.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Synthetic fixture for demo-usage-limit.sh (#2291). Never deployed.
contract Vault {
    uint256 public cap;

    function setCap(uint256 c) external {
        cap = c;
    }
}
SOL
ZFX="$WORK/zones.fixture.txt"; BFX="$WORK/briefs.fixture.txt"
{ grep -v '^#' "$FX/zones.fixture.txt"
  printf '%s\n' 'ZONE|src_vault|vault|C2|Vault: cap configuration' 'CUSTODY|src_vault|false'; } > "$ZFX"
{ grep -v '^#' "$FX/briefs.fixture.txt"
  printf '%s\n' 'DARK-FACTORY:BRIEF-BEGIN|src_vault' 'Attack the cap setter as an external actor.' 'DARK-FACTORY:BRIEF-END'; } > "$BFX"

# zone_field <coverage.json> <zone> <python expr over z>
zone_field() {
  python3 -c 'import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
z = [x for x in r["zones"] if x["id"] == sys.argv[2]][0]
print(eval(sys.argv[3], {"z": z, "r": r}))' "$@"
}
hunt() {  # hunt <out> <log> [extra args...] — sets HRC
  _out="$1"; _log="$2"; shift 2
  "$ZONEHUNT" --repo "$REPO" --out "$_out" --backend mock --agentis "$STUB" \
    --map-fixture "$ZFX" --brief-fixture "$BFX" "$@" > "$_log" 2>&1
  HRC=$?
}

# 3a) serial: src_feed (hunted first), src_pool C1 hits the limit, C6 is never started, src_vault never reached.
OUT1="$WORK/zh1"
STUB_FAIL_CALLS=1 STUB_FAIL_STATE="$WORK/fail1" STUB_FAIL_TEXT="$NOTICE" hunt "$OUT1" "$WORK/zh1.log"
COV1="$OUT1/coverage/zone-coverage.json"
if [ "$HRC" -eq 6 ] && [ -f "$COV1" ] \
   && [ "$(zone_field "$COV1" src_feed 'z["status"]')" = hunted_empty ] \
   && [ "$(zone_field "$COV1" src_pool 'z["status"]')" = limit_halted ] \
   && [ "$(zone_field "$COV1" src_pool 'z.get("exit_code")')" = 6 ] \
   && zone_field "$COV1" src_pool 'z.get("detail", "")' | grep -q 'usage limit reached: discovery/src_pool/run/hunt_share_pool_C1.log:1: ' \
   && [ "$(zone_field "$COV1" src_vault 'z["status"]')" = not_reached ] \
   && [ "$(zone_field "$COV1" src_feed 'r["totals"]["by_status"].get("failed", 0) + r["totals"]["by_status"].get("hunted_degraded", 0)')" = 0 ]; then
  ok "serial: rc 6; src_feed hunted_empty, src_pool limit_halted (exit 6, detail names the evidence), src_vault not_reached; no failed / degraded zone"
else
  bad "serial halt: rc=$HRC"; python3 -c 'import json,sys; [print("      ", z["id"], z["status"], z.get("exit_code"), z.get("detail","")) for z in json.load(open(sys.argv[1]))["zones"]]' "$COV1" 2>/dev/null
  tail -15 "$WORK/zh1.log" | sed 's/^/      /'
fi
R1="$OUT1/discovery/src_pool/discovery-results.json"
if [ -f "$R1" ] && python3 -c 'import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
lh = d.get("limit_halted") or {}
assert lh.get("cells") == 1 and lh.get("not_started") == 1, lh
assert d["totals"]["failed"] == 0, d["totals"]
assert "weekly limit" in lh.get("evidence", ""), lh
assert [c["status"] for c in d["cells"]] == [], d["cells"]' "$R1" 2>"$WORK/r1.err" \
   && grep -q 'LIMIT-HALTED — usage limit reached; NOT assessed' "$OUT1/discovery/src_pool/discovery-report.md" \
   && ! grep -q 'rigorous NEGATIVE' "$OUT1/discovery/src_pool/discovery-report.md" \
   && [ ! -d "$OUT1/verify" ]; then
  ok "serial: src_pool results carry limit_halted {cells 1, not_started 1 (C6), evidence}, totals.failed 0, a LIMIT-HALTED row, no rigorous NEGATIVE; STAGE 4 never ran"
else
  bad "serial results: $(cat "$WORK/r1.err" 2>/dev/null | tail -1); verify dir: $([ -d "$OUT1/verify" ] && echo present || echo absent)"
fi
if grep -q '\[M3\] USAGE LIMIT HALT: discovery/src_pool/run/hunt_share_pool_C1.log:1: .*--rehunt-gaps' "$WORK/zh1.log"; then
  ok "serial: the run names the evidence and the --rehunt-gaps resume command"
else
  bad "serial: no '[M3] USAGE LIMIT HALT' line with the resume hint"
fi

# 3b) --jobs 2 with a 1 s stub sleep: C1 and C6 both launch before C1's notice lands, so C6 finishes normally.
OUT2="$WORK/zh2"
STUB_SLEEP=1 STUB_FAIL_CALLS=1 STUB_FAIL_STATE="$WORK/fail2" STUB_FAIL_TEXT="$NOTICE" hunt "$OUT2" "$WORK/zh2.log" --jobs 2
COV2="$OUT2/coverage/zone-coverage.json"
R2="$OUT2/discovery/src_pool/discovery-results.json"
if [ "$HRC" -eq 6 ] && [ "$(zone_field "$COV2" src_pool 'z["status"]')" = limit_halted ] \
   && python3 -c 'import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["totals"]["failed"] == 0 and d["limit_halted"]["cells"] == 1 and d["limit_halted"]["not_started"] == 0, d
assert [c["status"] for c in d["cells"]] == ["ok"], d["cells"]' "$R2" 2>"$WORK/r2.err"; then
  ok "--jobs 2: rc 6, src_pool limit_halted, C1 LIMIT-HALTED and C6 ok, no failed cell"
else
  bad "--jobs 2 halt: rc=$HRC $(tail -1 "$WORK/r2.err" 2>/dev/null)"; tail -10 "$WORK/zh2.log" | sed 's/^/      /'
fi

# 3c) resume the --jobs 2 halt with --rehunt-gaps (the stub's fail counter is spent, so every call now answers).
FEED_BEFORE="$(cksum < "$OUT2/discovery/src_feed/discovery-results.json")"
STUB_SLEEP=1 STUB_FAIL_CALLS=1 STUB_FAIL_STATE="$WORK/fail2" STUB_FAIL_TEXT="$NOTICE" \
  hunt "$OUT2" "$WORK/zh3.log" --jobs 2 --rehunt-gaps
if [ "$HRC" -eq 0 ] && [ -d "$OUT2/discovery/src_pool.attempt-1" ] \
   && [ "$(zone_field "$COV2" src_pool '[a["status"] for a in z["attempts"]]')" = "['limit_halted']" ] \
   && [ "$(zone_field "$COV2" src_pool 'z["status"]')" = hunted ] \
   && [ "$(zone_field "$COV2" src_vault 'z["status"]')" = hunted_empty ] \
   && [ "$(zone_field "$COV2" src_feed 'z["attempts"]')" = "[]" ] \
   && [ "$(cksum < "$OUT2/discovery/src_feed/discovery-results.json")" = "$FEED_BEFORE" ] \
   && [ "$(zone_field "$COV2" src_feed 'r["complete"]')" = True ] \
   && grep -q 'previous invocation halted on a usage limit' "$WORK/zh3.log"; then
  ok "--rehunt-gaps: rc 0; src_pool archived to .attempt-1 (attempts[0] limit_halted) and hunted, src_vault hunted, src_feed untouched, the record complete"
else
  bad "resume: rc=$HRC"; python3 -c 'import json,sys; [print("      ", z["id"], z["status"], z.get("attempts")) for z in json.load(open(sys.argv[1]))["zones"]]' "$COV2" 2>/dev/null
  tail -15 "$WORK/zh3.log" | sed 's/^/      /'
fi
if grep -q 'merge: skipping discovery/src_pool.attempt-1 .*usage-limit-halted attempt superseded' "$WORK/zh3.log"; then
  ok "the merge drops the superseded limit_halted archive discovery/src_pool.attempt-1 (decision 1b: the zone is measured once)"
else
  bad "the merge did not skip discovery/src_pool.attempt-1"
fi

# 3d) STAGE 1 halt: no --map-fixture, a demo-local stub whose zone-mapper prints the notice.
STUB1="$WORK/agentis-stub-mapper.sh"
cat > "$STUB1" <<STUBEOF
#!/bin/sh
case "\${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go) case "\${2:-}" in zone-mapper.ag) cat "$NOTICE"; exit 1 ;; esac; exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB1"
OUT4="$WORK/zh4"
"$ZONEHUNT" --repo "$REPO" --out "$OUT4" --backend mock --agentis "$STUB1" --brief-fixture "$BFX" > "$WORK/zh4.log" 2>&1
HRC=$?
if [ "$HRC" -eq 6 ] && [ ! -e "$OUT4/coverage/zone-coverage.json" ] && grep -q '\[M1\] USAGE LIMIT HALT' "$WORK/zh4.log"; then
  ok "STAGE 1 halt: the zone-mapper hits the limit -> rc 6 at the M1 boundary, no coverage record"
else
  bad "STAGE 1 halt: rc=$HRC"; tail -10 "$WORK/zh4.log" | sed 's/^/      /'
fi

# ----------------------------------------------------------------------------------------------------------
note "4) M2: a usage-limit notice inside STAGE 4.5 (deep-hunt) ..."
# Scratch state only — never the operator's ~/.dark-factory; no deep-hunt knob leaks in from the caller's environment.
export DARK_FACTORY_DIR="$WORK/dfdir" FORGE_SLOTS_DIR="$WORK/forge-slots" DEEP_CELL_POLL_S=1 FORGE_MAX_SLOTS=4
unset DEEP_HUNT_CELL_TIMEOUT_S DEEP_HUNT_ZONE_BUDGET_S DEEP_HUNT_SKIP_BROKEN_TARGET DEEP_HUNT_JOBS \
      DEEP_HUNT_REACH DEEP_HUNT_PROMISES AGENTIS_LLM_SLOTS_DIR LLM_MAX_CONCURRENT LLM_SLOT_WAIT_S DF_USAGE_LIMIT_HALT
# The fixture repo of demo-deep-hunt-budget.sh: one value-custody zone, 3 concrete contracts (REACH picks all 3),
# 2 lenses (C10 + C2) -> 6 cells in queue order VaultA C10, VaultA C2, VaultB C10, VaultB C2, VaultC C10, VaultC C2.
DREPO="$WORK/deep-repo"
mkdir -p "$DREPO/src/vault"
printf '[profile.default]\nsrc = "src"\ntest = "test"\n' > "$DREPO/foundry.toml"
for n in A B C; do
  {
    echo "// SPDX-License-Identifier: MIT"; echo "pragma solidity ^0.8.20;"
    [ "$n" = A ] && for i in 1 2 3 4 5 6 7 8 9 10; do echo "// padding line $i (VaultA is the largest file)"; done
    echo "contract Vault$n {"
    echo "    uint256 public held;"
    echo "    function deposit$n(uint256 a) external { held += a; }"
    echo "}"
  } > "$DREPO/src/vault/Vault$n.sol"
done
# The prover stub: every invariant-prover call appends `<Contract>|<class>` to $STUB_LOG; the cell named by
# $STUB_LIMIT_ON (`<Contract>|<class>`) prints the usage-limit notice (read from the fixture file) and no verdict,
# every other cell answers CLEAN.
DSTUB="$WORK/deep-stub.sh"
cat > "$DSTUB" <<'STUBEOF'
#!/bin/sh
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    case "${2:-}" in
      zone-mapper.ag) echo "ZONE-CLASS|C10"; exit 0 ;;
      invariant-prover.ag)
        tf="${TARGET_FN:-}"; name="${tf##*:}"; name="${name##*/}"; name="${name%.sol}"
        [ -n "${STUB_LOG:-}" ] && echo "$name|${TARGET_CLASS:-}" >> "$STUB_LOG"
        if [ "$name|${TARGET_CLASS:-}" = "${STUB_LIMIT_ON:-}" ]; then cat "$STUB_NOTICE"; exit 1; fi
        echo "INVARIANT|$tf|CLEAN"; exit 0 ;;
      refuter.ag) echo "VERDICT|REAL|${CAND_FILE_FN:-}|${CAND_CLASS:-}|survived"; exit 0 ;;
      *) echo "SAFE"; exit 0 ;;
    esac ;;
esac
exit 0
STUBEOF
chmod +x "$DSTUB"
export STUB_NOTICE="$NOTICE"
DMAP="$WORK/deep-map.txt"
printf 'ZONE|src_vault|vault|C10,C2|value-custody vault family\nCUSTODY|src_vault|true\n' > "$DMAP"
DBASE="$WORK/deep-base"
"$ZONEHUNT" --repo "$DREPO" --out "$DBASE" --drop-dir "$DBASE/drop" --scope-hint src/vault --backend mock \
  --agentis "$DSTUB" --map-fixture "$DMAP" \
  --pass-fixture "scope=in;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" > "$WORK/deep-base.log" 2>&1
if [ ! -f "$DBASE/map/zones.json" ] || [ ! -f "$DBASE/verify/verified_findings.json" ]; then
  bad "the offline breadth base did not build:"; sed -n '1,20p' "$WORK/deep-base.log" | sed 's/^/      /'
else
  ledger_of() { awk -F'\t' '{ printf "%s|%s=%s(%s) ", $2, $3, $4, $5 }' "$1/deep-hunt/cell-status.tsv" 2>/dev/null; }
  # deep_pass <out> <stub-log> [KNOB=V...] [-- extra flags...] — a lens-only pass over a fresh copy of the base; sets DRC.
  deep_pass() {
    _d_out="$1"; _d_slog="$2"; shift 2
    rm -rf "$_d_out"; cp -R "$DBASE" "$_d_out"; : > "$_d_slog"
    ( while [ "$#" -gt 0 ] && [ "$1" != -- ]; do export "${1?}"; shift; done
      [ "${1:-}" = -- ] && shift
      STUB_LOG="$_d_slog" "$ZONEHUNT" --repo "$DREPO" --out "$_d_out" --deep-hunt --deep-hunt-only \
        --backend mock --agentis "$DSTUB" "$@" ) > "$_d_out.log" 2>&1
    DRC=$?
  }
  # deep_resume <out> <stub-log> [KNOB=V...] — --deep-hunt-only --deep-hunt-resume over <out> (no fresh copy); sets DRC.
  deep_resume() {
    _d_out="$1"; _d_slog="$2"; shift 2
    : > "$_d_slog"
    ( for _d_kv in "$@"; do export "${_d_kv?}"; done
      STUB_LOG="$_d_slog" "$ZONEHUNT" --repo "$DREPO" --out "$_d_out" --deep-hunt --deep-hunt-only --deep-hunt-resume \
        --backend mock --agentis "$DSTUB" ) > "$_d_out.resume.log" 2>&1
    DRC=$?
  }
  RESUMED='VaultB|C10 VaultB|C2 VaultC|C10 VaultC|C2'

  # 4a) the scheduler (1 job, a cell cap so it is ON): VaultB C10 hits the limit.
  STUB_LIMIT_ON='VaultB|C10' deep_pass "$WORK/d1" "$WORK/d1.stub" DEEP_HUNT_REACH=1 DEEP_HUNT_CELL_TIMEOUT_S=3600
  D1_LEDGER="$(ledger_of "$WORK/d1")"
  if [ "$DRC" -eq 6 ] \
     && [ "$D1_LEDGER" = "VaultA|C10=CLEAN(-) VaultA|C2=CLEAN(-) VaultB|C10=TRANSIENT_ERROR(usage-limit) VaultB|C2=SKIPPED_LIMIT(usage-limit halt) VaultC|C10=SKIPPED_LIMIT(usage-limit halt) VaultC|C2=SKIPPED_LIMIT(usage-limit halt) " ] \
     && [ "$(tr '\n' ' ' < "$WORK/d1.stub")" = "VaultA|C10 VaultA|C2 VaultB|C10 " ] \
     && [ "$(cut -f2 "$WORK/d1/.usage-limit-halt" 2>/dev/null)" = "run-invariant-hunt.sh:src/vault/VaultB.sol:VaultB:C10" ] \
     && [ "$(cut -f5 "$WORK/d1/.usage-limit-halt" 2>/dev/null)" = "$(head -1 "$NOTICE")" ] \
     && grep -q '\[M4.5\] USAGE LIMIT HALT: deep-hunt/src_vault-C10-VaultB/run/invariant_.*--deep-hunt-only --deep-hunt-resume' "$WORK/d1.log" \
     && ! grep -q 'HARNESS_ERROR' "$WORK/d1/deep-hunt/cell-status.tsv"; then
    ok "scheduler: the notice cell is TRANSIENT_ERROR (usage-limit), the 3 later cells SKIPPED_LIMIT and never launched; the halt holds the evidence; rc 6 at the M4.5 boundary with the resume hint"
  else
    bad "scheduler halt: rc=$DRC ledger=[$D1_LEDGER] ran=[$(tr '\n' ' ' < "$WORK/d1.stub")] halt=[$(cat "$WORK/d1/.usage-limit-halt" 2>/dev/null)]"
    tail -8 "$WORK/d1.log" | sed 's/^/      /'
  fi
  deep_resume "$WORK/d1" "$WORK/d1r.stub" DEEP_HUNT_REACH=1 DEEP_HUNT_CELL_TIMEOUT_S=3600
  if [ "$DRC" -eq 0 ] && [ "$(tr '\n' ' ' < "$WORK/d1r.stub")" = "$RESUMED " ] && [ ! -f "$WORK/d1/.usage-limit-halt" ] \
     && grep -q 'previous invocation halted on a usage limit' "$WORK/d1.resume.log"; then
    ok "scheduler: --deep-hunt-only --deep-hunt-resume re-runs exactly the halted + skipped cells ($RESUMED), rc 0"
  else
    bad "scheduler resume: rc=$DRC ran=[$(tr '\n' ' ' < "$WORK/d1r.stub")]"; tail -8 "$WORK/d1.resume.log" | sed 's/^/      /'
  fi

  # 4b) the legacy serial loop (no time-budget knob): the same cell hits the limit, no later row is launched.
  STUB_LIMIT_ON='VaultB|C10' deep_pass "$WORK/d2" "$WORK/d2.stub" DEEP_HUNT_REACH=1
  if [ "$DRC" -eq 6 ] && [ "$(tr '\n' ' ' < "$WORK/d2.stub")" = "VaultA|C10 VaultA|C2 VaultB|C10 " ] \
     && [ ! -e "$WORK/d2/deep-hunt/cell-status.tsv" ] \
     && grep -q '\[usage-limit\] Claude usage limit reached — NOT assessed, classifying as TRANSIENT_ERROR' "$WORK/d2.log" \
     && grep -q 'INVARIANT-HUNT: src/vault/VaultB.sol:VaultB -> TRANSIENT_ERROR' "$WORK/d2.log" \
     && grep -q 'usage limit reached — no further row is launched' "$WORK/d2.log" \
     && ! grep -q 'INVARIANT-HUNT: .* -> HARNESS_ERROR' "$WORK/d2.log" \
     && grep -q '\[M4.5\] USAGE LIMIT HALT' "$WORK/d2.log"; then
    ok "serial loop: the notice cell is TRANSIENT_ERROR (never HARNESS_ERROR), no later row is launched, rc 6 at M4.5"
  else
    bad "serial halt: rc=$DRC ran=[$(tr '\n' ' ' < "$WORK/d2.stub")]"; tail -8 "$WORK/d2.log" | sed 's/^/      /'
  fi
  deep_resume "$WORK/d2" "$WORK/d2r.stub" DEEP_HUNT_REACH=1
  if [ "$DRC" -eq 0 ] && [ "$(tr '\n' ' ' < "$WORK/d2r.stub")" = "$RESUMED " ]; then
    ok "serial loop: --deep-hunt-only --deep-hunt-resume re-runs exactly the halted + unlaunched rows, rc 0"
  else
    bad "serial resume: rc=$DRC ran=[$(tr '\n' ' ' < "$WORK/d2r.stub")]"; tail -8 "$WORK/d2.resume.log" | sed 's/^/      /'
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS — a usage-limit notice halts the hunt (exit 6, limit_halted / a TRANSIENT_ERROR deep cell) instead of becoming failed cells, and --rehunt-gaps / --deep-hunt-resume resume it"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed"
exit 1
