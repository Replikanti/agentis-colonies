#!/usr/bin/env bash
# demo-refute-retry-errored.sh — OFFLINE, DETERMINISTIC proof of verify-findings.sh's serial RETRY PASS for
# gate-ERROR candidates (#2288). A refute gate that RAN but answered ERROR (a flat-cyborg transport crash, or no
# VERDICT| reply after the in-call attempts) used to leave its candidate unassessed for good. The retry pass
# re-runs those candidates after the tier-1 walk has drained, one at a time, through the unchanged single-candidate
# gate. Every gate call is a FAST offline stub through run-refute.sh's EXISTING --agentis seam, keyed per function
# with per-key call counters (NO live agentis / network). DF_AGENT_MAX_ATTEMPTS=1 and DF_AGENT_TRANSPORT_RETRIES=0
# make every in-call failure terminal, so one stub answer is one gate verdict.
#
# Main fixture (manifest order):
#   1 Flaky    C1  chrome on its first call, REAL afterwards        -> recovered on retry 1, lands in verified[]
#   2 Crash    C2  transport crash first, REFUTED + CONSTRAINT after -> recovered on retry 1, implicit refuted
#   3 Chrome   C3  chrome on every call                              -> residual after 2 retries, errors[]
#   4 Vault    C1  REAL                                              -> verified[] (main walk)
#   5 Token    C5  REFUTED                                           -> implicit refuted (main walk)
#   6 Truncated    blank class/severity (#1691 preflight)            -> errors[], never retried, never gated
#
# Assertions:
#   a) AC1: Flaky ends in verified[] AFTER the main-walk confirmation, retry.txt = `1\tREAL`, errored-attempt-0/
#      holds the main walk's ERROR, and the cell's canonical files are the final attempt's.
#   b) Crash's recovery is an implicit refuted (not in verified[] / errors[]) and its constraint reaches
#      refute-constraints.tsv.
#   c) AC2a: Chrome stays in errors[] with `"retried": 2`, totals.errored_after_retry == 1, errored-attempt-0/ and
#      -1/ both exist; Truncated stays in errors[] WITHOUT `retried` and never reaches the stub.
#   d) The counting invariant `candidates == verified + errored + refuted + dropped_subfloor` with exact numbers.
#   e) ORDERING: the main walk overlaps gates (positive control, concurrency >= 2); every retry call starts after
#      the last main-walk call ended; exactly one gate is in flight during retries; DF_REFUTE_SESSION_LOG kinds are
#      `first` for the main walk and `retry` for the retries.
#   f) --jobs 1 and --jobs 3 give byte-identical verified_findings.json + refute-constraints.tsv.
#   g) AC4, =0: Flaky's stub count is 1; no `retried` key, no new totals key, no errored-attempt-* dir, no
#      retry.txt, no banner suffix.
#   h) On an error-free fixture the default (2) run and the =0 run are byte-identical (JSON, constraints and the
#      gates/ file list).
#   i) Guards: `--retry-errored x`, `--retry-errored -1` and DF_REFUTE_RETRY_ERRORED=abc exit 2 before any side
#      effect; `--gate poc` keeps the pass inert (noted only when set explicitly).
#   j) A `--refute-batch 1` member that errors is retried individually: one `retry` session, no second batch.
#
# Usage:  dark-factory/demo-refute-retry-errored.sh
# Requires: bash >= 4.3 (for the --jobs 3 assertions) + python3. Exit: 0 = all held.
# Dash-safe stub: no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/verify-findings.sh"

FAILS=0
note() { echo "demo-refute-retry-errored.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$VERIFY" ] || { note "verify-findings.sh not found / not executable: $VERIFY" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-refute-retry-errored.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PAR_OK=1
bash -c '[ "${BASH_VERSINFO:-0}" -gt 4 ] || { [ "${BASH_VERSINFO:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 3 ]; }' 2>/dev/null || PAR_OK=0

# One stub answer = one gate verdict: no in-call retry of either kind.
export DF_AGENT_MAX_ATTEMPTS=1
export DF_AGENT_TRANSPORT_RETRIES=0
unset DF_REFUTE_RETRY_ERRORED DF_REFUTE_RETRY_PASS DF_REFUTE_BATCH DF_REFUTE_SESSION_LOG SEVERITY_RUBRIC 2>/dev/null || true

# ----------------------------------------------------------------------------------------------------------
# The target repo. No abstract contracts (no #1861 appendix) and no `-=` accounting signal (no #1699 C6 re-read),
# so every gate call is exactly one stub call.
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target"
mkdir -p "$REPO/contracts" "$REPO/src"
for c in Flaky:flip Crash:boom Chrome:stall Vault:stake Token:transfer Pair:swap; do
  printf 'contract %s { function %s() public {} }\n' "${c%%:*}" "${c#*:}" > "$REPO/contracts/${c%%:*}.sol"
done
printf 'contract Truncated { function fn() public {} }\n' > "$REPO/src/Truncated.sol"

# ----------------------------------------------------------------------------------------------------------
# The stub. STUB_DIR holds the per-key call counters and the S/E event log (`S <pass> <fn>` / `E <pass> <fn>`,
# pass = the retry attempt, 0 = main walk); one line per append, so file order is event order.
# ----------------------------------------------------------------------------------------------------------
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    fn="${CAND_FILE_FN:-}"; cls="${CAND_CLASS:-}"; pass="${DF_REFUTE_RETRY_PASS:-0}"
    if [ -n "${CAND_BATCH_PATH:-}" ]; then key="batch"; fn="batch"; else key="$(printf '%s_%s' "$fn" "$cls" | tr -c 'A-Za-z0-9\n' '_')"; fi
    d="${STUB_DIR:?}"
    n=0; [ -f "$d/count.$key" ] && n="$(cat "$d/count.$key")"
    n=$((n + 1)); printf '%s' "$n" > "$d/count.$key"
    echo "S $pass $fn" >> "$d/events"
    sleep "${STUB_SLEEP:-0}"
    echo "E $pass $fn" >> "$d/events"
    if [ "$key" = "batch" ]; then
      printf 'high · /effort\n'; printf 'esc to interrupt\n'; exit 0
    fi
    case "$fn" in
      *Flaky.sol*)
        if [ "$n" -eq 1 ]; then printf 'high · /effort\n'; printf 'esc to interrupt\n'; exit 0; fi
        echo "VERDICT|REAL|$fn|$cls|survived a hostile read on the second try" ;;
      *Crash.sol*)
        if [ "$n" -eq 1 ]; then echo "LLM transport error: flat-cyborg exited (status 1)"; exit 1; fi
        echo "CONSTRAINT|$cls|a crash claim must name the reachable caller"
        echo "VERDICT|REFUTED|$fn|$cls|no reachable caller" ;;
      *Chrome.sol*)
        printf 'high · /effort\n'; printf 'esc to interrupt\n' ;;
      *Token.sol*)
        echo "CONSTRAINT|$cls|a transfer claim must show the missing check"
        echo "VERDICT|REFUTED|$fn|$cls|the owner check exists" ;;
      *Pair.sol*)
        if [ "$cls" = "C2" ] && [ "$n" -eq 1 ]; then printf 'high · /effort\n'; printf 'esc to interrupt\n'; exit 0; fi
        echo "VERDICT|REAL|$fn|$cls|survived a hostile read" ;;
      *)
        echo "VERDICT|REAL|$fn|$cls|survived a hostile read" ;;
    esac
    exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB"

# mk_results <out> <spec...> — a discovery-results.json with one cell per `loc|class|sev|exploit|sketch` spec.
mk_results() {
  mr_out="$1"; shift
  python3 - "$@" > "$mr_out" <<'PY'
import sys, json
cells = []
for spec in sys.argv[1:]:
    parts = spec.split("|")
    cells.append({"subsystem": "sub " + parts[0].split(":")[0], "class": parts[1], "files": parts[0].split(":")[0],
                  "candidates": [spec], "coordination": []})
print(json.dumps({"repo": "target", "backend": "mock", "jobs": 1, "cells": cells,
                  "totals": {"cells": len(cells), "candidates": len(cells), "steers": 0}}, indent=2))
PY
}

MAIN="$WORK/main.json"
mk_results "$MAIN" \
  "contracts/Flaky.sol:flip:3|C1|High|a flip mints free shares|call flip twice" \
  "contracts/Crash.sol:boom:4|C2|High|boom bricks the pool|call boom" \
  "contracts/Chrome.sol:stall:7|C3|High|stall freezes withdrawals|call stall" \
  "contracts/Vault.sol:stake:12|C1|High|stake inflates the share price|donate first" \
  "contracts/Token.sol:transfer:5|C5|Low|transfer lacks an owner check|anyone moves funds" \
  "src/Truncated.sol:fn:~(test/Truncated.t.sol:test_fn||||"

# run_verify <tag> <results> [extra args...] — one verify run with its own stub state; env passes through.
run_verify() {
  rv_tag="$1"; rv_res="$2"; shift 2
  mkdir -p "$WORK/stub-$rv_tag"
  STUB_DIR="$WORK/stub-$rv_tag" DF_REFUTE_SESSION_LOG="$WORK/sessions-$rv_tag.tsv" \
    "$VERIFY" --results "$rv_res" --repo "$REPO" --out "$WORK/out-$rv_tag" --gate refute --backend mock \
    --agentis "$STUB" "$@" >"$WORK/$rv_tag.out" 2>"$WORK/$rv_tag.err"
}

# ----------------------------------------------------------------------------------------------------------
# a)-e) the main fixture under --jobs 3 at the default (ON).
# ----------------------------------------------------------------------------------------------------------
if [ "$PAR_OK" -eq 1 ]; then MAIN_JOBS=3; else MAIN_JOBS=1; skip "bash lacks 'wait -n' — the main run is serial and the overlap control is skipped"; fi
note "a)-e) main fixture, retry pass at its default, --jobs $MAIN_JOBS ..."
STUB_SLEEP=0.3 run_verify j3 "$MAIN" --jobs "$MAIN_JOBS"
RC=$?
[ "$RC" -eq 0 ] && ok "verify-findings.sh exits 0 over the 6-candidate fixture" \
  || { bad "the main run exited $RC"; sed 's/^/      /' "$WORK/j3.err" >&2; }
O="$WORK/out-j3"
if python3 - "$O/verified_findings.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
t = d["totals"]
locs = [v["location"] for v in d["verified"]]
assert locs == ["contracts/Vault.sol:stake:12", "contracts/Flaky.sol:flip:3"], \
    "verified[] is not [main-walk Vault, recovered Flaky]: %r" % locs
assert d["verified"][1]["verdict"] == "REAL", d["verified"][1]
errs = d["errors"]
assert [e["location"] for e in errs] == ["contracts/Chrome.sol:stall:7", "src/Truncated.sol:fn:~(test/Truncated.t.sol:test_fn"], \
    "errors[] is not [Chrome residual, Truncated preflight]: %r" % errs
assert errs[0].get("retried") == 2, "the residual Chrome row does not carry retried: 2: %r" % errs[0]
assert "no VERDICT" in errs[0]["reason"], "the residual reason is not the last attempt's: %r" % errs[0]
assert "retried" not in errs[1], "the #1691 preflight row carries a retried key: %r" % errs[1]
assert all("Crash.sol" not in l for l in locs + [e["location"] for e in errs]), "Crash is not an implicit refuted"
assert t["candidates"] == 6 and t["verified"] == 2 and t["errored"] == 2 and t["dropped_subfloor"] == 0, t
assert t["retried_candidates"] == 3 and t["errored_after_retry"] == 1, t
refuted = t["candidates"] - t["verified"] - t["errored"] - t["dropped_subfloor"]
assert refuted == 2, "implicit refuted != 2 (Crash + Token): %r" % refuted
PY
then ok "a)+c)+d) verified[] = [Vault, recovered Flaky]; errors[] = [Chrome retried 2, Truncated without retried]; Crash is an implicit refuted; candidates 6 == 2 verified + 2 errored + 2 refuted + 0 sub-floor; retried_candidates 3, errored_after_retry 1"
else bad "a)+c)+d) the retry-pass classification is wrong"
fi
FL="$O/gates/1_contracts_Flaky_sol_flip_3"; CR="$O/gates/2_contracts_Crash_sol_boom_4"; CH="$O/gates/3_contracts_Chrome_sol_stall_7"
[ "$(cat "$FL/retry.txt" 2>/dev/null)" = "$(printf '1\tREAL')" ] && ok "a) Flaky retry.txt = '1<TAB>REAL'" || bad "a) Flaky retry.txt is '$(cat "$FL/retry.txt" 2>/dev/null)'"
{ [ -d "$FL/errored-attempt-0" ] && [ ! -e "$FL/errored-attempt-1" ] && [ "$(cut -f1 "$FL/errored-attempt-0/verdict.txt" 2>/dev/null)" = "ERROR" ] \
  && [ -f "$FL/errored-attempt-0/gate.log" ] && [ -f "$FL/errored-attempt-0/refute-report.md" ] \
  && ls "$FL/errored-attempt-0"/refute_*.log >/dev/null 2>&1 && [ ! -d "$FL/errored-attempt-0/run" ]; } \
  && ok "a) Flaky's main-walk ERROR is archived FLAT in errored-attempt-0/ (gate.log, verdict.txt, refute-report.md, refute_*.log; no nested run/), and no attempt-1 dir exists" \
  || bad "a) Flaky's errored-attempt-0/ archive is wrong"
{ [ "$(cut -f1 "$FL/verdict.txt" 2>/dev/null)" = "REAL" ] && grep -q 'VERDICT|REAL' "$FL"/refute-out/run/refute_*.log 2>/dev/null \
  && ! grep -q 'esc to interrupt' "$FL"/refute-out/run/refute_*.log 2>/dev/null; } \
  && ok "a) Flaky's canonical verdict.txt and refute-out/run/ hold the FINAL attempt only" \
  || bad "a) Flaky's canonical files still carry the errored attempt"
[ "$(cat "$CR/retry.txt" 2>/dev/null)" = "$(printf '1\tREFUTED')" ] && ok "b) Crash retry.txt = '1<TAB>REFUTED'" || bad "b) Crash retry.txt is '$(cat "$CR/retry.txt" 2>/dev/null)'"
grep -q 'TRANSIENT, RE-RUNNABLE' "$CR/errored-attempt-0/verdict.txt" 2>/dev/null \
  && ok "b) Crash's archived main-walk verdict is the #2045 transport row" || bad "b) Crash's archived verdict is not the transport row"
if grep -q "$(printf 'contracts/Crash.sol:boom:4\ta crash claim must name the reachable caller')" "$O/refute-constraints.tsv"; then
  ok "b) the recovered REFUTED's constraint reaches refute-constraints.tsv (the aggregation runs after the pass)"
else
  bad "b) the recovered constraint is missing from refute-constraints.tsv"; sed 's/^/      /' "$O/refute-constraints.tsv" >&2
fi
{ [ "$(cat "$CH/retry.txt" 2>/dev/null)" = "$(printf '2\tERROR')" ] && [ -d "$CH/errored-attempt-0" ] && [ -d "$CH/errored-attempt-1" ] \
  && [ ! -e "$CH/errored-attempt-2" ]; } \
  && ok "c) Chrome: retry.txt = '2<TAB>ERROR', errored-attempt-0/ and -1/ exist, the final attempt stays canonical" \
  || bad "c) Chrome's retry artifacts are wrong"
S="$WORK/stub-j3"
[ "$(cat "$S/count.contracts_Flaky_sol_flip_3_C1" 2>/dev/null)" = "2" ] && [ "$(cat "$S/count.contracts_Chrome_sol_stall_7_C3" 2>/dev/null)" = "3" ] \
  && [ "$(cat "$S/count.contracts_Vault_sol_stake_12_C1" 2>/dev/null)" = "1" ] \
  && ok "stub call counts: Flaky 2, Chrome 3 (1 + 2 retries), Vault 1 (a healthy candidate is never retried)" \
  || bad "unexpected stub call counts: $(cd "$S" && grep -H . count.* | tr '\n' ' ')"
grep -q 'Truncated' "$S/events" && bad "c) the preflight candidate reached the stub" || ok "c) the #1691 preflight candidate never reached the stub"
grep -q '\[refute\] RETRY 1/2 contracts/Flaky.sol:flip:3 (C1)' "$WORK/j3.err" && grep -q -- '-> recovered (REAL)' "$WORK/j3.err" \
  && grep -q -- '-> still ERRORED after 2 retries' "$WORK/j3.err" \
  && grep -q '3 retried (2 recovered, 1 still errored)' "$WORK/j3.err" \
  && ok "the RETRY / recovered / still-ERRORED lines and the banner suffix are logged" \
  || bad "the retry log lines or the banner suffix are missing"

if python3 - "$S/events" "$PAR_OK" <<'PY'
import sys
ev = [l.split(" ", 2) for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
main_end = max(i for i, e in enumerate(ev) if e[0] == "E" and e[1] == "0")
retry_starts = [i for i, e in enumerate(ev) if e[0] == "S" and e[1] != "0"]
assert len(retry_starts) == 4, "expected 4 retry calls (Flaky 1, Crash 1, Chrome 2): %r" % retry_starts
assert min(retry_starts) > main_end, "a retry started before the main walk drained"
def peak(rows):
    live = best = 0
    for e in rows:
        live += 1 if e[0] == "S" else -1
        best = max(best, live)
    return best
pm = peak([e for e in ev if e[1] == "0"])
pr = peak([e for e in ev if e[1] != "0"])
assert pr == 1, "retry concurrency is %d, not 1" % pr
if sys.argv[2] == "1":
    assert pm >= 2, "positive control failed: the main walk never overlapped (peak %d)" % pm
print("main-walk peak %d, retry peak %d" % (pm, pr))
PY
then ok "e) every retry call starts after the last main-walk call ended, exactly one gate is in flight during retries, and the main walk overlapped (positive control)"
else bad "e) the retry pass is not serial / not deferred"
fi
if python3 - "$WORK/sessions-j3.tsv" <<'PY'
import sys
kinds = [l.split("\t")[1] for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
assert kinds.count("first") == 5, "first sessions != 5: %r" % kinds
assert kinds.count("retry") == 4, "retry sessions != 4: %r" % kinds
assert set(kinds) == {"first", "retry"}, kinds
PY
then ok "e) DF_REFUTE_SESSION_LOG: 5 main-walk sessions logged as 'first', 4 retry sessions as 'retry'"
else bad "e) the session-log kinds are wrong"; sed 's/^/      /' "$WORK/sessions-j3.tsv" >&2
fi

# ----------------------------------------------------------------------------------------------------------
# f) --jobs 1 == --jobs 3.
# ----------------------------------------------------------------------------------------------------------
note "f) --jobs 1 vs --jobs $MAIN_JOBS ..."
run_verify j1 "$MAIN" --jobs 1
RC=$?
[ "$RC" -eq 0 ] || { bad "the --jobs 1 run exited $RC"; sed 's/^/      /' "$WORK/j1.err" >&2; }
cmp -s "$WORK/out-j1/verified_findings.json" "$O/verified_findings.json" && cmp -s "$WORK/out-j1/refute-constraints.tsv" "$O/refute-constraints.tsv" \
  && ok "f) verified_findings.json and refute-constraints.tsv are byte-identical between --jobs 1 and --jobs $MAIN_JOBS" \
  || { bad "f) --jobs 1 and --jobs $MAIN_JOBS diverged"; diff "$WORK/out-j1/verified_findings.json" "$O/verified_findings.json" | sed 's/^/      /' >&2; }

# ----------------------------------------------------------------------------------------------------------
# g) AC4: =0 is the pre-#2288 behaviour.
# ----------------------------------------------------------------------------------------------------------
note "g) DF_REFUTE_RETRY_ERRORED=0 ..."
DF_REFUTE_RETRY_ERRORED=0 run_verify off "$MAIN" --jobs 1
RC=$?
[ "$RC" -eq 0 ] || { bad "the =0 run exited $RC"; sed 's/^/      /' "$WORK/off.err" >&2; }
OFF="$WORK/out-off"
{ [ "$(cat "$WORK/stub-off/count.contracts_Flaky_sol_flip_3_C1" 2>/dev/null)" = "1" ] \
  && ! grep -q '"retried' "$OFF/verified_findings.json" && ! grep -q 'errored_after_retry' "$OFF/verified_findings.json" \
  && [ -z "$(find "$OFF/gates" \( -name 'errored-attempt-*' -o -name retry.txt \) -print)" ] \
  && ! grep -q 'retried' "$WORK/off.err" && ! grep -q 'retry pass' "$WORK/off.err" \
  && grep -q '"errored": 4' "$OFF/verified_findings.json"; } \
  && ok "g) =0: Flaky is called once, no retried / retry totals key, no errored-attempt-* dir, no retry.txt, no banner suffix, 4 errored" \
  || bad "g) =0 is not inert"

# ----------------------------------------------------------------------------------------------------------
# h) An error-free fixture: default (2) == =0, byte for byte.
# ----------------------------------------------------------------------------------------------------------
note "h) error-free fixture: the default run == the =0 run ..."
CLEAN="$WORK/clean.json"
mk_results "$CLEAN" \
  "contracts/Vault.sol:stake:12|C1|High|stake inflates the share price|donate first" \
  "contracts/Token.sol:transfer:5|C5|Low|transfer lacks an owner check|anyone moves funds" \
  "src/Truncated.sol:fn:~(test/Truncated.t.sol:test_fn||||"
run_verify clean-on "$CLEAN" --jobs 1
RC1=$?
DF_REFUTE_RETRY_ERRORED=0 run_verify clean-off "$CLEAN" --jobs 1
RC2=$?
( cd "$WORK/out-clean-on/gates" && find . -type f | sort ) > "$WORK/clean-on.files"
( cd "$WORK/out-clean-off/gates" && find . -type f | sort ) > "$WORK/clean-off.files"
{ [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] \
  && cmp -s "$WORK/out-clean-on/verified_findings.json" "$WORK/out-clean-off/verified_findings.json" \
  && cmp -s "$WORK/out-clean-on/refute-constraints.tsv" "$WORK/out-clean-off/refute-constraints.tsv" \
  && [ -s "$WORK/out-clean-on/refute-constraints.tsv" ] \
  && cmp -s "$WORK/clean-on.files" "$WORK/clean-off.files"; } \
  && ok "h) no gate ERROR: the default run and the =0 run are byte-identical (JSON, non-empty constraints, gates/ file list)" \
  || bad "h) the error-free default run diverged from =0"

# ----------------------------------------------------------------------------------------------------------
# i) Guards.
# ----------------------------------------------------------------------------------------------------------
note "i) argument guards ..."
for g in "--retry-errored x" "--retry-errored -1" "env:abc"; do
  gout="$WORK/out-guard-$(printf '%s' "$g" | tr -c 'A-Za-z0-9' '_')"
  case "$g" in
    env:*) DF_REFUTE_RETRY_ERRORED="${g#env:}" "$VERIFY" --results "$MAIN" --repo "$REPO" --out "$gout" --agentis "$STUB" >/dev/null 2>"$WORK/guard.err" ;;
    *)     "$VERIFY" --results "$MAIN" --repo "$REPO" --out "$gout" --agentis "$STUB" $g >/dev/null 2>"$WORK/guard.err" ;;
  esac
  GRC=$?
  { [ "$GRC" -eq 2 ] && grep -q 'retry-errored' "$WORK/guard.err" && [ ! -d "$gout" ]; } \
    && ok "i) '$g' exits 2 with a retry-errored message and writes no output dir" \
    || bad "i) '$g' did not fail fast (exit $GRC)"
done
PREONLY="$WORK/preflight-only.json"
mk_results "$PREONLY" "src/Truncated.sol:fn:~(test/Truncated.t.sol:test_fn||||"
"$VERIFY" --results "$PREONLY" --repo "$REPO" --out "$WORK/out-poc" --gate poc --agentis "$STUB" --retry-errored 2 >/dev/null 2>"$WORK/poc.err"
P1=$?
"$VERIFY" --results "$PREONLY" --repo "$REPO" --out "$WORK/out-poc2" --gate poc --agentis "$STUB" >/dev/null 2>"$WORK/poc2.err"
P2=$?
{ [ "$P1" -eq 0 ] && [ "$P2" -eq 0 ] && grep -q 'retry pass inert' "$WORK/poc.err" && ! grep -q 'retry pass inert' "$WORK/poc2.err" \
  && ! grep -q 'retried' "$WORK/out-poc/verified_findings.json"; } \
  && ok "i) --gate poc: the pass is inert (an explicit --retry-errored is noted, the default is silent)" \
  || bad "i) --gate poc did not keep the retry pass inert"

# ----------------------------------------------------------------------------------------------------------
# j) A --refute-batch 1 member that errors is retried individually.
# ----------------------------------------------------------------------------------------------------------
note "j) --refute-batch 1: an errored batch member ..."
BATCH="$WORK/batch.json"
mk_results "$BATCH" \
  "contracts/Pair.sol:swap:3|C1|High|swap skips the fee|swap twice" \
  "contracts/Pair.sol:swap:3|C2|High|swap rounds the reserve|swap dust"
run_verify batch "$BATCH" --jobs 1 --refute-batch 1 --cluster-findings 0
RC=$?
[ "$RC" -eq 0 ] || { bad "the batch run exited $RC"; sed 's/^/      /' "$WORK/batch.err" >&2; }
if python3 - "$WORK/out-batch/verified_findings.json" "$WORK/sessions-batch.tsv" "$WORK/out-batch/gates/2_contracts_Pair_sol_swap_3/retry.txt" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert [(v["location"], v["class"]) for v in d["verified"]] == [("contracts/Pair.sol:swap:3", "C1"), ("contracts/Pair.sol:swap:3", "C2")], d["verified"]
assert d["errors"] == [] and d["totals"]["retried_candidates"] == 1 and d["totals"]["errored_after_retry"] == 0, d["totals"]
rows = [l.split("\t") for l in open(sys.argv[2], encoding="utf-8").read().splitlines() if l.strip()]
kinds = [r[1] for r in rows]
assert kinds.count("batch") == 1, "the retry re-batched: %r" % kinds
assert kinds.count("retry") == 1, "the errored member was not re-read exactly once: %r" % kinds
assert open(sys.argv[3], encoding="utf-8").read() == "1\tREAL\n"
PY
then ok "j) the errored batch member is recovered by ONE individual 'retry' read (one batch session in total, no re-batch)"
else bad "j) the batched member's retry is wrong"; sed 's/^/      /' "$WORK/sessions-batch.tsv" >&2
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #2288 retry pass (serial, deferred, recovered verdicts classified, residual errors kept, =0 inert) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
