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

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS — a usage-limit notice halts the hunt (exit 6, limit_halted) instead of becoming failed cells, and --rehunt-gaps resumes it"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed"
exit 1
