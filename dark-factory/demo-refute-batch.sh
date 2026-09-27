#!/usr/bin/env bash
# demo-refute-batch.sh — OFFLINE, DETERMINISTIC proof of #2284: the refute gate's BATCHED FIRST READ
# (lib/refute-batch.py + run-refute.sh --batch-first-read / --first-read-log + verify-findings.sh --refute-batch).
# No live agentis / forge / network: every refute call goes through the existing run-refute.sh --agentis seam
# with a fast stub that mirrors refuter.ag's batch output (a `REFUTE-BATCH|` sentinel, then one `REFUTE-ITEM|<k>`
# block per staged candidate) and answers EVERY candidate the same way in both modes, so a batched run can be
# compared byte-for-byte with an unbatched one.
#
# Assertions:
#   a) PLANNER: same file + function with different lines form one group; `File.sol:123` runs individually; code
#      files that differ only in case never merge; balanced chunks at max 6 (8 -> 4+4, 7 -> 4+3, 13 -> 5+4+4);
#      a leftover chunk of one at max 2 runs individually; `summary` predicts the sessions; usage/input errors
#      exit 2/3; the summary's bare_codefile() is the same code as verify-findings.sh's.
#   b) VERDICT INDEPENDENCE: a 3-member group answered REAL / REFUTED / REFUTED gets exactly those verdicts, and
#      verified[] carries only the REAL member with its own exploit, reason and class.
#   c) ON == OFF on the same answers: verified_findings.json and refute-constraints.tsv are byte-identical, and
#      every gates/<n>_*/ carries identical verdict.txt, eff-class.txt, candidate.manifest, report data row and
#      refute-constraints.tsv. ON adds only gates-batch/ and, per batched member, batch.txt (+ gate.rc).
#   d) OFF IS INERT: the default and --refute-batch 0 are byte-identical, write no gates-batch/ and no batch.txt,
#      and every recorded session is a `first` read.
#   e) FALLBACKS NEVER LOSE A CANDIDATE: a dropped block, a class-mismatched block, a batch reply that is chrome
#      on every attempt and a reply without `REFUTE-BATCH|` each give the affected members their own `first`
#      session and the OFF verdicts.
#   f) EXCLUSIONS: adjudicated, missing-code-file, malformed, sub-floor and tier-2 candidates are never batched,
#      and candidates == verified + errored + refuted + dropped_subfloor holds.
#   g) RUBRIC INTERPLAY: with SEVERITY_RUBRIC=1 a batch block standing on an insufficient ground gets its re-ask
#      individually (a `reask` session) and ends exactly as the OFF run does.
#   h) CONCURRENCY: ON --jobs 3 is byte-identical to ON --jobs 1, peak concurrent sessions never exceed effective
#      jobs, and the LLM_MAX_VERIFY_GATES=1 clamp holds.
#   i) SESSION COUNTS: `batch` sessions == planned batches; `first` sessions == the individually refuted ones.
#   j) ARGUMENT GUARDS: --refute-batch 2, DF_REFUTE_BATCH_MAX=1 and =x exit 2 before any side effect; --gate poc
#      with batching ON warns and stays inert; run-refute.sh exits 2 on a mixed-code-file batch, a one-candidate
#      batch, --batch-first-read with --invariant-mode / --only, and --first-read-log with a 2-line manifest; a
#      --first-read-log without a verdict falls back to the candidate's own first read; the batch timeout scales.
#   k) STATIC + PROBE: CAND_BATCH_PATH rides the passthrough; _rf_batch_attempt exports the rubric/evidence/scope
#      knobs exactly as _rf_attempt does; REFUTE-BATCH| is honesty-gated; exactly one prompt() call; and (only
#      when `agentis` is installed) the single-candidate instruction is byte-identical to the pre-#2284 one.
#
# Usage:  dark-factory/demo-refute-batch.sh
# Requires: python3 (the floor); bash >= 4.3 for the --jobs assertions. Exit: 0 = all assertions held.
# POSIX sh / dash-safe style: no pipefail, no $'...', no process substitution, literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/verify-findings.sh"
REFUTE="$HERE/run-refute.sh"
PLANNER="$HERE/lib/refute-batch.py"
REFUTER_AG="$HERE/auditor/agents/refuter.ag"

FAILS=0
note() { echo "demo-refute-batch.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (want '$2', got '$1')"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
for f in "$VERIFY" "$REFUTE" "$PLANNER"; do
  [ -x "$f" ] || { note "not found / not executable: $f" >&2; exit 3; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-refute-batch.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------------------------------------
# The stub. `answer` is the ONE decision both modes share: REAL iff the exploit carries REALBUG (or INSUFF on a
# rubric re-ask), else REFUTED with a constraint. STUB_* knobs break the BATCH reply only, never a single read.
# ---------------------------------------------------------------------------------------------------------------
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
answer() {
  a_fn="$1"; a_cls="$2"; a_expl="$3"; a_real=0
  case "$a_expl" in *REALBUG*) a_real=1 ;; esac
  case "$a_expl" in *INSUFF*) [ -n "${RUBRIC_REASK_GROUNDS:-}" ] && a_real=1 ;; esac
  if [ "$a_real" -eq 1 ]; then
    echo "VERDICT|REAL|$a_fn|$a_cls|the unguarded path in $a_fn holds for $a_cls"
    return 0
  fi
  if [ "${SEVERITY_RUBRIC:-}" = "1" ]; then
    case "$a_expl" in
      *INSUFF*) echo "REFUTE-GROUND|no-attacker|no unprivileged attacker gains anything" ;;
      *) echo "REFUTE-GROUND|guard|src/Pool.sol:1 require(msg.sender == owner)" ;;
    esac
  fi
  echo "CONSTRAINT|$a_cls|a claim must name the unprivileged trigger and the divergence it causes"
  if [ -n "${STUB_SAME_REASON:-}" ]; then
    echo "VERDICT|REFUTED|$a_fn|$a_cls|one shared guard stops it"
  else
    echo "VERDICT|REFUTED|$a_fn|$a_cls|a guard in $a_fn stops the $a_cls path"
  fi
}
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
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
    [ "${SEVERITY_RUBRIC:-}" = "1" ] && echo "SEVERITY-RUBRIC|refute|on"
    if [ -n "${CAND_BATCH_PATH:-}" ]; then
      if [ -n "${STUB_BATCH_CHROME:-}" ]; then
        printf 'high · /effort\n'
        printf 'esc to interrupt\n'
        exit 0
      fi
      [ -n "${STUB_NO_BATCH_SENTINEL:-}" ] || echo "REFUTE-BATCH|refute|$(grep -c . "$CAND_BATCH_PATH")"
      echo "reasoning through every candidate first ..."
      echo
      while IFS='|' read -r k fn cls sev expl; do
        [ -n "$k" ] || continue
        [ "$k" = "${STUB_DROP_ITEM:-none}" ] && continue
        [ "$k" = "${STUB_MISCLASS_ITEM:-none}" ] && cls="C99"
        echo "REFUTE-ITEM|$k"
        answer "$fn" "$cls" "$expl"
      done < "$CAND_BATCH_PATH"
    else
      answer "${CAND_FILE_FN:-}" "${CAND_CLASS:-}" "${CAND_EXPLOIT:-}"
    fi
    exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB"

REPO="$WORK/target"; mkdir -p "$REPO/src"
printf 'contract Pool { function swap() public {} function setFee(uint f) public { fee = f; } }\n' > "$REPO/src/Pool.sol"
printf 'contract Vault { function mint(uint a) public returns (uint) { return a; } }\n' > "$REPO/src/Vault.sol"

# MAIN: two groups (swap x3, setFee x2) interleaved with two individual candidates (a singleton function and a
# line-only location). Candidate order after the parse: 1 swap:10, 2 setFee:40, 3 mint, 4 swap:12, 5 setFee:41,
# 6 Vault.sol:77, 7 swap. Expected plan: batch 1 = {1,4,7}, batch 2 = {2,5}; 2 individual.
MAIN="$WORK/main-results.json"
python3 - "$MAIN" <<'PY'
import sys, json
c = lambda loc, cls, sev, expl: "|".join([loc, cls, sev, expl, "sketch for " + loc])
d = {"repo": "target", "backend": "mock", "cells": [
    {"subsystem": "pool", "class": "C2", "candidates": [
        c("src/Pool.sol:swap:10", "C2", "High", "REALBUG swap reads a stale reserve after the callback"),
        c("src/Pool.sol:setFee:40", "C5", "High", "REALBUG setFee has no access check"),
        c("src/Vault.sol:mint:5", "C1", "High", "mint rounds shares up")]},
    {"subsystem": "pool", "class": "C6", "candidates": [
        c("src/Pool.sol:swap:12", "C6", "High", "swap skips the fee on the second hop"),
        c("src/Pool.sol:setFee:41", "C9", "Medium", "setFee accepts a fee above the cap"),
        c("src/Vault.sol:77", "C1", "High", "a line-only location")]},
    {"subsystem": "pool", "class": "C22", "candidates": [
        c("src/Pool.sol:swap", "C22", "Medium", "swap forwards the wrong eth flag")]}]}
open(sys.argv[1], "w").write(json.dumps(d, indent=2) + "\n")
PY

# run_verify <out> <results> [args...] — stderr -> <out>.log; every session -> <out>.sess.
run_verify() {
  rv_out="$1"; rv_res="$2"; shift 2
  DF_REFUTE_SESSION_LOG="$rv_out.sess" "$VERIFY" --results "$rv_res" --repo "$REPO" --out "$rv_out" \
    --backend mock --agentis "$STUB" "$@" 2> "$rv_out.log" >/dev/null
}
# kinds <sess> <kind> -> how many sessions of that kind were recorded.
kinds() { if [ -f "$1" ]; then awk -F'\t' -v k="$2" '$2==k' "$1" | grep -c . || true; else echo 0; fi; }
# verdicts <out> -> `<gate dir name> <verdict>` per tier-1 gate, in numeric order.
verdicts() {
  for vd in "$1"/gates/*/; do
    [ -f "$vd/verdict.txt" ] && printf '%s %s\n' "$(basename "$vd")" "$(cut -f1 "$vd/verdict.txt")"
  done | sort -n
}
# same_gates <a> <b> -> "same" when every gates/<n>_*/ carries identical verdict/class/manifest/report row/constraints.
same_gates() {
  sg_diff=0
  for sg_d in "$1"/gates/*/; do
    sg_n="$(basename "$sg_d")"
    for sg_f in verdict.txt eff-class.txt candidate.manifest refute-out/refute-constraints.tsv; do
      cmp -s "$sg_d/$sg_f" "$2/gates/$sg_n/$sg_f" || { sg_diff=1; echo "    differs: $sg_n/$sg_f" >&2; }
    done
    grep '^| ' "$sg_d/refute-out/refute-report.md" | grep -v '^| Candidate' > "$WORK/row.a" 2>/dev/null
    grep '^| ' "$2/gates/$sg_n/refute-out/refute-report.md" | grep -v '^| Candidate' > "$WORK/row.b" 2>/dev/null
    cmp -s "$WORK/row.a" "$WORK/row.b" || { sg_diff=1; echo "    differs: $sg_n report row" >&2; }
  done
  [ "$(find "$1/gates" -mindepth 1 -maxdepth 1 | wc -l)" = "$(find "$2/gates" -mindepth 1 -maxdepth 1 | wc -l)" ] || sg_diff=1
  if [ "$sg_diff" -eq 0 ]; then echo same; else echo differ; fi
}
# same_out <a> <b> -> "same" when verified_findings.json and refute-constraints.tsv are byte-identical.
same_out() {
  if cmp -s "$1/verified_findings.json" "$2/verified_findings.json" \
     && cmp -s "$1/refute-constraints.tsv" "$2/refute-constraints.tsv"; then echo same; else echo differ; fi
}

# ---------------------------------------------------------------------------------------------------------------
note "a) the planner (lib/refute-batch.py)"
# eligible <file> <location|codefile>... -> one eligible row per argument, n from 1.
eligible() {
  el_f="$1"; shift; : > "$el_f"; el_n=0
  for el_a in "$@"; do
    el_n=$((el_n + 1))
    printf '%s\ts%s\t%s\t%s\n' "$el_n" "$el_n" "${el_a%%|*}" "${el_a#*|}" >> "$el_f"
  done
}
plan_line() { python3 "$PLANNER" plan --in "$1" --max "$2" 2>&1 >/dev/null | grep '^BATCHPLAN|'; }
eligible "$WORK/e1" "src/A.sol:f:1|src/A.sol" "src/A.sol:f:90|src/A.sol" "src/A.sol:g:3|src/A.sol"
check "$(plan_line "$WORK/e1" 6)" "BATCHPLAN|3|1|2|1" "same file + function on different lines = one batch of 2; the other function runs individually"
eligible "$WORK/e2" "src/A.sol:123|src/A.sol" "src/A.sol:123|src/A.sol"
check "$(plan_line "$WORK/e2" 6)" "BATCHPLAN|2|0|0|2" "\`File.sol:123\` (no function part) is refuted individually, never batched"
eligible "$WORK/e3" "src/A.sol:f|src/A.sol" "src/a.sol:f|src/a.sol"
check "$(plan_line "$WORK/e3" 6)" "BATCHPLAN|2|0|0|2" "code files that differ only in case are never merged"
# sizes <n> <max> -> the chunk sizes of one n-member group, space separated.
sizes() {
  sz_i=0; sz_args=""
  while [ "$sz_i" -lt "$1" ]; do sz_i=$((sz_i + 1)); sz_args="$sz_args src/A.sol:f:$sz_i|src/A.sol"; done
  # shellcheck disable=SC2086
  eligible "$WORK/esz" $sz_args
  python3 "$PLANNER" plan --in "$WORK/esz" --max "$2" 2>/dev/null | awk -F'\t' '$2==1 { printf "%s%s", sep, $3; sep=" " }'
}
check "$(sizes 8 6)" "4 4" "8 at max 6 -> 4+4"
check "$(sizes 7 6)" "4 3" "7 at max 6 -> 4+3"
check "$(sizes 13 6)" "5 4 4" "13 at max 6 -> 5+4+4"
check "$(sizes 6 6)" "6" "6 at max 6 -> one batch of 6"
eligible "$WORK/e5" "src/A.sol:f:1|src/A.sol" "src/A.sol:f:2|src/A.sol" "src/A.sol:f:3|src/A.sol" "src/A.sol:f:4|src/A.sol" "src/A.sol:f:5|src/A.sol"
check "$(plan_line "$WORK/e5" 2)" "BATCHPLAN|5|2|4|1" "5 at max 2 -> 2+2 and the leftover chunk of one runs individually"
MEMBERS="$(python3 "$PLANNER" plan --in "$WORK/e5" --max 2 2>/dev/null | tr '\t' ',' | tr '\n' ' ')"
check "$MEMBERS" "1,1,2,1,s1 1,2,2,2,s2 2,1,2,3,s3 2,2,2,4,s4 " "member rows are batch,k,size,n,slug in manifest order"
check "$(python3 "$PLANNER" summary --results "$MAIN" | tr '\n' ' ')" "BATCHPLAN|7|2|5|2 first_read_sessions=4 of 7 (43% fewer) " \
  "summary predicts 7 first reads -> 4 sessions on the MAIN fixture"
python3 "$PLANNER" plan --in "$WORK/e1" --max 1 >/dev/null 2>&1; check "$?" "2" "--max 1 is a usage error (exit 2)"
python3 "$PLANNER" plan --max 6 >/dev/null 2>&1; check "$?" "2" "plan without --in is a usage error (exit 2)"
python3 "$PLANNER" plan --in "$WORK/nope.tsv" --max 6 >/dev/null 2>&1; check "$?" "3" "an unreadable input exits 3"
# The summary's bare_codefile() is a copy of verify-findings.sh's: compare the code with comments stripped.
bcf() { awk '/def bare_codefile\(location\):/ {f=1} f {print} f && /return s$/ {exit}' "$1" | sed 's/#.*$//; s/[[:space:]]*$//' | grep -v '^[[:space:]]*$'; }
bcf "$VERIFY" > "$WORK/bcf.v"; bcf "$PLANNER" > "$WORK/bcf.p"
if [ -s "$WORK/bcf.v" ] && cmp -s "$WORK/bcf.v" "$WORK/bcf.p"; then
  ok "lib/refute-batch.py's bare_codefile() is the same code as verify-findings.sh's"
else
  bad "bare_codefile() has drifted between verify-findings.sh and lib/refute-batch.py"; diff "$WORK/bcf.v" "$WORK/bcf.p"
fi

# ---------------------------------------------------------------------------------------------------------------
note "b/c/d/i) MAIN fixture: OFF (default), --refute-batch 0, ON"
run_verify "$WORK/off" "$MAIN"; check "$?" "0" "the default (OFF) run exits 0"
run_verify "$WORK/off0" "$MAIN" --refute-batch 1 --refute-batch 0
( DF_REFUTE_BATCH=1 run_verify "$WORK/on" "$MAIN" ); check "$?" "0" "DF_REFUTE_BATCH=1 exits 0"
run_verify "$WORK/onflag" "$MAIN" --refute-batch 1

check "$(verdicts "$WORK/on" | grep -E '^(1|4|7)_' | tr '\n' ' ')" \
  "1_src_Pool_sol_swap_10 REAL 4_src_Pool_sol_swap_12 REFUTED 7_src_Pool_sol_swap REFUTED " \
  "b) the 3-member swap group answered REAL / REFUTED / REFUTED keeps exactly those verdicts per candidate"
INDEP="$(python3 - "$WORK/on/verified_findings.json" <<'PY'
import sys, json
v = json.load(open(sys.argv[1]))["verified"]
swap = [e for e in v if e["location"].startswith("src/Pool.sol:swap")]
ok = (len(swap) == 1 and swap[0]["location"] == "src/Pool.sol:swap:10" and swap[0]["class"] == "C2"
      and swap[0]["exploit"].startswith("REALBUG swap reads a stale reserve")
      and swap[0]["reason"] == "the unguarded path in src/Pool.sol:swap:10 holds for C2")
print("independent" if ok else "contaminated: " + json.dumps(swap))
PY
)"
check "$INDEP" "independent" "b) verified[] carries only the REAL swap member, with its own exploit, reason and class"

check "$(same_out "$WORK/off" "$WORK/on")" "same" "c) ON vs OFF: verified_findings.json and refute-constraints.tsv are byte-identical"
check "$(same_gates "$WORK/off" "$WORK/on")" "same" \
  "c) every gates/<n>_*/ has identical verdict.txt, eff-class.txt, candidate.manifest, report data row and refute-constraints.tsv"
EXTRA="$( { for d in "$WORK/on"/gates/*/; do ls "$d"; done; ls "$WORK/on"; } | sort | uniq > "$WORK/names.on"
          { for d in "$WORK/off"/gates/*/; do ls "$d"; done; ls "$WORK/off"; } | sort | uniq > "$WORK/names.off"
          comm -23 "$WORK/names.on" "$WORK/names.off" | tr '\n' ' ')"
check "$EXTRA" "batch.txt gate.rc gates-batch " "c) ON adds only gates-batch/ and, per batched member, batch.txt (+ gate.rc)"
check "$(cat "$WORK"/on/gates/*/batch.txt | sort | tr '\t' ',' | tr '\n' ' ')" "1,1,3 1,2,3 1,3,3 2,1,2 2,2,2 " \
  "c) batch.txt records <batch>,<k>,<size> for the five batched members"
check "$(same_out "$WORK/on" "$WORK/onflag")" "same" "--refute-batch 1 and DF_REFUTE_BATCH=1 are the same run"

if [ ! -e "$WORK/off/gates-batch" ] && [ -z "$(find "$WORK/off" "$WORK/off0" -name batch.txt)" ] \
   && cmp -s "$WORK/off/verified_findings.json" "$WORK/off0/verified_findings.json"; then
  ok "d) OFF (default and --refute-batch 0) writes no gates-batch/ and no batch.txt, and the two are byte-identical"
else
  bad "d) an OFF run wrote batch artifacts or differs from --refute-batch 0"
fi
check "$(kinds "$WORK/off.sess" first) $(grep -c . "$WORK/off.sess")" "7 7" "d) OFF records seven sessions, every one a \`first\` read"
if grep -q 'batched first-read session' "$WORK/off.log"; then bad "d) the OFF banner names batched sessions"; else ok "d) the OFF banner is unchanged"; fi

PLANNED_B="$(grep -o 'BATCHPLAN|[0-9|]*' "$WORK/on.log" | head -1 | cut -d'|' -f3)"
check "$PLANNED_B $(kinds "$WORK/on.sess" batch)" "2 2" "i) \`batch\` sessions == the planned batches (2)"
check "$(kinds "$WORK/on.sess" first) $(kinds "$WORK/on.sess" reask) $(kinds "$WORK/on.sess" c6)" "2 0 0" \
  "i) \`first\` sessions == the 2 individually refuted candidates (7 first reads -> 4 sessions)"
if grep -q 'VERIFY \[refute\]: 7 candidate(s), 2 confirmed, 0 errored (malformed/unresolvable), 0 skipped, 5 candidate(s) in 2 batched first-read session(s)' "$WORK/on.log"; then
  ok "the ON banner names the batched sessions"
else
  bad "the ON banner is wrong"; grep 'VERIFY \[' "$WORK/on.log"
fi
check "$(cut -f4 "$WORK"/on/gates-batch/1_*/refute-out/batch-status.tsv | tr '\n' ' ')" "ok ok ok " "every member of a clean batch reply splits ok"
if [ -z "$(find "$WORK/on/gates-batch" -path '*/refute-out/refute-report.md')" ]; then
  ok "the batched first read writes no refute-report.md of its own"
else
  bad "the batched first read wrote a refute-report.md"
fi

# ---------------------------------------------------------------------------------------------------------------
note "e) fallbacks: a bad batch reply costs sessions, never a candidate"
fallback() {  # fallback <name> <env assignment> <want first> <want batch> <want status of k=2>
  env "$2" DF_AGENT_MAX_ATTEMPTS=2 DF_REFUTE_BATCH=1 DF_REFUTE_SESSION_LOG="$WORK/fb-$1.sess" \
    "$VERIFY" --results "$MAIN" --repo "$REPO" --out "$WORK/fb-$1" --backend mock --agentis "$STUB" \
    2> "$WORK/fb-$1.log" >/dev/null
  fb_st="$(awk -F'\t' '$1==2 {print $4}' "$WORK"/fb-"$1"/gates-batch/1_*/refute-out/batch-status.tsv)"
  if [ "$(same_out "$WORK/off" "$WORK/fb-$1")" = "same" ] && [ "$(same_gates "$WORK/off" "$WORK/fb-$1")" = "same" ] \
     && [ "$(kinds "$WORK/fb-$1.sess" first)" = "$3" ] && [ "$(kinds "$WORK/fb-$1.sess" batch)" = "$4" ] \
     && [ "$fb_st" = "$5" ]; then
    ok "e) $1: member status '$5', $3 own first reads, $4 batch session(s), verdicts identical to OFF"
  else
    bad "e) $1: first=$(kinds "$WORK/fb-$1.sess" first) batch=$(kinds "$WORK/fb-$1.sess" batch) status='$fb_st' (want $3/$4/'$5') or verdicts differ"
  fi
}
fallback dropped-block STUB_DROP_ITEM=2 4 2 missing
fallback class-mismatch STUB_MISCLASS_ITEM=2 4 2 class-mismatch
fallback chrome STUB_BATCH_CHROME=1 7 4 no-batch-reply
fallback no-sentinel STUB_NO_BATCH_SENTINEL=1 7 2 no-batch-reply
env STUB_SAME_REASON=1 DF_REFUTE_BATCH=1 "$VERIFY" --results "$MAIN" --repo "$REPO" --out "$WORK/contagion" \
  --backend mock --agentis "$STUB" 2>/dev/null >/dev/null
if grep -q 'WARNING: two or more batch members carry a byte-identical reason' "$WORK"/contagion/gates-batch/1_*/gate.log; then
  ok "e) byte-identical reasons across batch members raise the report-only contagion WARNING"
else
  bad "e) no contagion WARNING for byte-identical reasons"
fi

# ---------------------------------------------------------------------------------------------------------------
note "f) exclusions: adjudicated / malformed / missing file / sub-floor / tier-2 are never batched"
EXCL="$WORK/excl-results.json"
python3 - "$EXCL" <<'PY'
import sys, json
c = lambda loc, cls, sev, expl: "|".join([loc, cls, sev, expl, "sketch"])
d = {"repo": "target", "cells": [{"subsystem": "pool", "class": "C2", "candidates": [
        c("src/Pool.sol:swap:10", "C2", "High", "REALBUG swap reads a stale reserve"),
        c("src/Pool.sol:swap:11", "C3", "High", "an operator already ruled this one"),
        c("src/Pool.sol:swap:12", "", "High", "a truncated record"),
        c("src/Pool.sol:swap:13", "C6", "Low", "a sub-floor dust loss"),
        c("src/Missing.sol:swap:1", "C2", "High", "the code file is gone"),
        c("src/Pool.sol:swap:14", "C4", "High", "swap mis-orders two writes")]}],
     "tier2": [{"subsystem": "pool", "class": "C2", "id": 1, "kind": "trace", "location": "src/Pool.sol:swap",
                "loc_source": "trace", "loc_rule": "fn", "check": "swap reserve after callback", "why": "unresolved"}]}
open(sys.argv[1], "w").write(json.dumps(d, indent=2) + "\n")
PY
printf 'src/Pool.sol:swap:11\tC3\tHigh\tconfirmed\thuman ruling\n' > "$WORK/adjudicated.tsv"
run_verify "$WORK/excl-on" "$EXCL" --refute-batch 1 --adjudicated "$WORK/adjudicated.tsv" --pay-floor medium --tier2 1
run_verify "$WORK/excl-off" "$EXCL" --adjudicated "$WORK/adjudicated.tsv" --pay-floor medium --tier2 1
check "$(find "$WORK/excl-on/gates" -name batch.txt | sed 's|.*/gates/||; s|/batch.txt||' | sort | tr '\n' ' ')" \
  "1_src_Pool_sol_swap_10 5_src_Pool_sol_swap_14 " "f) only the two gate-bound swap candidates were batched (the sub-floor row never reaches the loop)"
if [ -z "$(find "$WORK/excl-on/gates-tier2" -name batch.txt)" ] && [ -d "$WORK/excl-on/gates-tier2" ]; then
  ok "f) the tier-2 record ran its own gate (gates-tier2/, no batch.txt)"
else
  bad "f) a tier-2 record was batched or never gated"
fi
check "$(same_out "$WORK/excl-off" "$WORK/excl-on")" "same" "f) the exclusion fixture is byte-identical ON vs OFF"
INV="$(python3 - "$WORK/excl-on" <<'PY'
import sys, json, os, glob
out = sys.argv[1]
d = json.load(open(os.path.join(out, "verified_findings.json")))
t = d["totals"]
refuted = sum(1 for p in glob.glob(os.path.join(out, "gates", "*", "verdict.txt"))
              if open(p).read().split("\t", 1)[0] == "REFUTED")
print(t["candidates"], t["verified"] + t["errored"] + refuted + t["dropped_subfloor"],
      t["verified"], t["errored"], refuted, t["dropped_subfloor"])
PY
)"
check "$INV" "6 6 2 2 1 1" "f) candidates == verified + errored + refuted + dropped_subfloor (6 == 2 + 2 + 1 + 1)"

# ---------------------------------------------------------------------------------------------------------------
note "g) rubric interplay: an insufficient ground inside a batch block is re-asked individually"
RUB="$WORK/rub-results.json"
sed 's/setFee accepts a fee above the cap/INSUFF setFee accepts a fee above the cap/' "$MAIN" > "$RUB"
( SEVERITY_RUBRIC=1 run_verify "$WORK/rub-off" "$RUB" )
( SEVERITY_RUBRIC=1 run_verify "$WORK/rub-on" "$RUB" --refute-batch 1 )
RUB_REASK="$(awk -F'\t' '$2=="reask" {print $4}' "$WORK/rub-on.sess" | tr '\n' ' ')"
if [ "$(same_out "$WORK/rub-off" "$WORK/rub-on")" = "same" ] && [ "$(same_gates "$WORK/rub-off" "$WORK/rub-on")" = "same" ] \
   && [ "$RUB_REASK" = "src/Pool.sol:setFee:41 " ] && [ "$(kinds "$WORK/rub-off.sess" reask)" = "1" ] \
   && grep -q '^SEVERITY-RUBRIC|' "$WORK"/rub-on/gates/5_*/refute-out/run/refute_*_41.log \
   && grep -q 'recovered under the severity rubric' "$WORK"/rub-on/gates/5_*/verdict.txt; then
  ok "g) the batch block's insufficient ground armed the rubric gate (header sentinel carried into the split log), got ONE individual \`reask\`, and ended REAL exactly as OFF"
else
  bad "g) rubric interplay broke (reask='$RUB_REASK', off reask=$(kinds "$WORK/rub-off.sess" reask))"
fi

# ---------------------------------------------------------------------------------------------------------------
note "h) concurrency: --jobs 3 == --jobs 1, the pool cap holds"
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; then
  skip "h) bash < 4.3 (no wait -n): verify-findings.sh degrades --jobs to serial"
else
  mkdir -p "$WORK/ctr3" "$WORK/ctr1"
  ( STUB_CTR="$WORK/ctr3" STUB_SLEEP=0.3 run_verify "$WORK/j3" "$MAIN" --refute-batch 1 --jobs 3 )
  ( STUB_CTR="$WORK/ctr1" STUB_SLEEP=0.1 LLM_MAX_VERIFY_GATES=1 run_verify "$WORK/jcap" "$MAIN" --refute-batch 1 --jobs 3 )
  check "$(same_out "$WORK/on" "$WORK/j3") $(same_gates "$WORK/on" "$WORK/j3")" "same same" "h) ON --jobs 3 is byte-identical to ON --jobs 1"
  check "$(same_out "$WORK/on" "$WORK/jcap")" "same" "h) ON under the LLM_MAX_VERIFY_GATES=1 clamp is byte-identical too"
  MAX3="$(cat "$WORK/ctr3/max" 2>/dev/null || echo 0)"; MAX1="$(cat "$WORK/ctr1/max" 2>/dev/null || echo 0)"
  if [ "$MAX3" -ge 2 ] && [ "$MAX3" -le 3 ] && [ "$MAX1" = "1" ]; then
    ok "h) peak concurrent sessions: $MAX3 under --jobs 3 (<= 3, a batch is one slot) and 1 under the clamp"
  else
    bad "h) peak concurrent sessions out of bounds (jobs 3: $MAX3, clamp: $MAX1)"
  fi
fi

# ---------------------------------------------------------------------------------------------------------------
note "j) argument guards"
run_verify "$WORK/bad1" "$MAIN" --refute-batch 2; check "$?" "2" "--refute-batch 2 is a usage error (exit 2)"
( DF_REFUTE_BATCH_MAX=1 run_verify "$WORK/bad2" "$MAIN" --refute-batch 1 ); check "$?" "2" "DF_REFUTE_BATCH_MAX=1 is a usage error (exit 2)"
( DF_REFUTE_BATCH_MAX=x run_verify "$WORK/bad3" "$MAIN" ); check "$?" "2" "DF_REFUTE_BATCH_MAX=x is a usage error (exit 2)"
if [ ! -e "$WORK/bad1/gates" ] && [ ! -e "$WORK/bad2/gates" ] && [ ! -e "$WORK/bad3/gates" ]; then
  ok "bad batching knobs fail before any side effect"
else
  bad "a bad batching knob ran the gate"
fi
run_verify "$WORK/poc" "$MAIN" --gate poc --refute-batch 1
if grep -q 'WARNING: --refute-batch batches the refute gate only (--gate poc)' "$WORK/poc.log" && [ ! -e "$WORK/poc/gates-batch" ]; then
  ok "--gate poc with batching ON warns and stays inert"
else
  bad "--gate poc with batching ON did not warn or wrote gates-batch/"
fi
RR="$WORK/rr"; mkdir -p "$RR"
printf 'src/Pool.sol:swap:1|C1|High|x|src/Pool.sol\nsrc/Pool.sol:swap:2|C2|High|y|src/Vault.sol\n' > "$RR/mixed.manifest"
printf 'src/Pool.sol:swap:1|C1|High|x|src/Pool.sol\nsrc/Pool.sol:swap:2|C2|High|y|src/Pool.sol\n' > "$RR/two.manifest"
printf '# a comment\nsrc/Pool.sol:swap:1|C1|High|x|src/Pool.sol\n' > "$RR/one.manifest"
rr() { "$REFUTE" --code-dir "$REPO" --backend mock --agentis "$STUB" --out "$RR/out" "$@" >/dev/null 2>&1; echo "$?"; }
check "$(rr --candidates "$RR/mixed.manifest" --batch-first-read)" "2" "run-refute.sh: --batch-first-read over two code files exits 2"
check "$(rr --candidates "$RR/one.manifest" --batch-first-read)" "2" "run-refute.sh: --batch-first-read over one candidate exits 2"
check "$(rr --candidates "$RR/two.manifest" --batch-first-read --invariant-mode)" "2" "run-refute.sh: --batch-first-read with --invariant-mode exits 2"
check "$(rr --candidates "$RR/two.manifest" --batch-first-read --only src/Pool.sol:swap:1)" "2" "run-refute.sh: --batch-first-read with --only exits 2"
printf 'VERDICT|REAL|x|C1|y\n' > "$RR/good.log"
check "$(rr --candidates "$RR/two.manifest" --first-read-log "$RR/good.log")" "2" "run-refute.sh: --first-read-log with a 2-line manifest exits 2"
printf 'high · /effort\nesc to interrupt\n' > "$RR/chrome.log"
DF_REFUTE_SESSION_LOG="$RR/fr.sess" "$REFUTE" --candidates "$RR/one.manifest" --code-dir "$REPO" --backend mock \
  --agentis "$STUB" --first-read-log "$RR/chrome.log" --out "$RR/fr" 2> "$RR/fr.log" >/dev/null
if grep -q 'first-read log unusable — refuting individually' "$RR/fr.log" && [ "$(kinds "$RR/fr.sess" first)" = "1" ] \
   && grep -q '| src/Pool.sol:swap:1 | C1 | REFUTED |' "$RR/fr/refute-report.md"; then
  ok "a --first-read-log without a verdict falls back to the candidate's own first read"
else
  bad "a verdict-less --first-read-log did not fall back"
fi
printf 'VERDICT|REAL|src/Pool.sol:swap:1|C1|the batched read kept it\n' > "$RR/real.log"
DF_REFUTE_SESSION_LOG="$RR/fr2.sess" "$REFUTE" --candidates "$RR/one.manifest" --code-dir "$REPO" --backend mock \
  --agentis "$STUB" --first-read-log "$RR/real.log" --out "$RR/fr2" 2>/dev/null >/dev/null
if [ ! -s "$RR/fr2.sess" ] && grep -q '| src/Pool.sol:swap:1 | C1 | REAL | the batched read kept it |' "$RR/fr2/refute-report.md"; then
  ok "a usable --first-read-log replaces the first session (no session recorded, its verdict reaches the report)"
else
  bad "a usable --first-read-log was not used"
fi
# The batch timeout scales with the batch (claude backend writes llm.cli_timeout_ms; HOME is sandboxed because that
# backend pre-trusts the run dir in ~/.claude.json).
mkdir -p "$WORK/home"
printf 'src/Pool.sol:swap:%s|C1|High|x|src/Pool.sol\n' 1 2 3 > "$RR/three.manifest"
printf 'src/Pool.sol:swap:%s|C1|High|x|src/Pool.sol\n' 1 2 3 4 5 6 7 > "$RR/seven.manifest"
tmo() { HOME="$WORK/home" "$REFUTE" --code-dir "$REPO" --backend claude --agentis "$STUB" --out "$RR/t" "$@" >/dev/null 2>&1
        grep '^llm.cli_timeout_ms' "$RR/t/run/.agentis/config" | cut -d' ' -f3; }
check "$(tmo --candidates "$RR/one.manifest") $(tmo --candidates "$RR/three.manifest" --batch-first-read) $(tmo --candidates "$RR/seven.manifest" --batch-first-read)" \
  "600000 1080000 1800000" "the session timeout: 600 s single, 600 s + 240 s per extra candidate, capped at 1800 s"

# ---------------------------------------------------------------------------------------------------------------
note "k) static guards + the single-candidate prompt probe"
if grep 'echo "exec.env_passthrough' "$REFUTE" | grep -q 'CAND_BATCH_PATH'; then
  ok "CAND_BATCH_PATH rides run-refute.sh's exec.env_passthrough (getenv() reads the SANITIZED env)"
else
  bad "CAND_BATCH_PATH is not on the passthrough line — batching would be silently inert"
fi
# body <fn> -> the indented function's body from run-refute.sh.
body() { awk -v s="  $1() {" '$0==s {f=1} f {print} f && $0=="  }" {exit}' "$REFUTE"; }
KNOBS_OK=1
# shellcheck disable=SC2016,SC1003  # literal source lines, matched verbatim (grep -F)
for knob in 'SEVERITY_RUBRIC="${SEVERITY_RUBRIC:-}" \' 'GROUND_EVIDENCE="${GROUND_EVIDENCE:-}" \' 'SCOPE_ASSUMPTIONS_PATH="$SCOPE_IN_RUN" \' \
            'BRIEF_PATH="$BRIEF_IN_RUN" \' '"$AGENTIS" go refuter.ag --enable-exec --enable-messaging --grant-pii ) >"$1" 2>&1 || \'; do
  body _rf_attempt | grep -qF "$knob" || KNOBS_OK=0
  body _rf_batch_attempt | grep -qF "$knob" || KNOBS_OK=0
done
# shellcheck disable=SC2016,SC1003  # literal source lines, matched verbatim (grep -F)
body _rf_batch_attempt | grep -qF 'CAND_BATCH_PATH="$BATCH_FILE" \' || KNOBS_OK=0
# shellcheck disable=SC1003  # a literal source line, matched verbatim (grep -F)
body _rf_batch_attempt | grep -qF 'RUBRIC_REASK_GROUNDS="" \' || KNOBS_OK=0
if [ "$KNOBS_OK" -eq 1 ]; then
  ok "_rf_batch_attempt exports SEVERITY_RUBRIC, GROUND_EVIDENCE, SCOPE_ASSUMPTIONS_PATH and the brief exactly as _rf_attempt, plus the batch, with the re-ask forced off"
else
  bad "_rf_batch_attempt's env contract drifted from _rf_attempt's"
fi
if grep -qF 'if len(batch) == 0 { return single_instruction(candInvariant, candFn, candClass, candSev, candExploit, brief, aux); }' "$REFUTER_AG" \
   && grep -qF 'let instruction = refute_instruction(batch, candInvariant, candFn, candClass, candSev, candExploit, brief, aux);' "$REFUTER_AG" \
   && grep -qF 'let batch = cat_file(getenv("CAND_BATCH_PATH"));' "$REFUTER_AG"; then
  ok "refuter.ag: an empty batch returns single_instruction(), the pre-#2284 concatenation"
else
  bad "refuter.ag's single-candidate path no longer short-circuits on an empty batch"
fi
if grep -qF 'if index_of(instruction, batch_marker()) >= 0 { print("REFUTE-BATCH|refute|" + to_string(batch_count(batch))); }' "$REFUTER_AG"; then
  ok "REFUTE-BATCH| is printed only when the batch marker is IN the assembled instruction"
else
  bad "the REFUTE-BATCH| sentinel is missing or not honesty-gated"
fi
L_SENT="$(grep -n 'print("REFUTE-BATCH|refute|"' "$REFUTER_AG" | head -1 | cut -d: -f1)"
L_PROMPT="$(grep -n '^let verdict = prompt(' "$REFUTER_AG" | head -1 | cut -d: -f1)"
if [ "$(grep -c '= prompt(' "$REFUTER_AG")" = "1" ] && [ -n "$L_SENT" ] && [ -n "$L_PROMPT" ] && [ "$L_SENT" -lt "$L_PROMPT" ]; then
  ok "refuter.ag keeps exactly ONE prompt() call, and the sentinel is printed before it"
else
  bad "refuter.ag has more than one prompt() call, or the sentinel follows it"
fi
if grep -q 'judge_body("", aux)' "$REFUTER_AG" && [ "$(grep -c '^ *+ severity_rubric_directive()$' "$REFUTER_AG")" = "2" ]; then
  ok "the batch prompt reuses judge_body(\"\", aux): the rubric directive is still spliced in exactly two places"
else
  bad "the batch prompt carries its own copy of the judge body"
fi

if ! command -v agentis >/dev/null 2>&1; then
  skip "k) agentis not installed: the rendered-prompt probe is skipped (the static guards above still hold)"
else
  # Render the instruction (the prompt() line and everything after it cut away, so nothing reaches an LLM) and
  # compare its sha256 with goldens minted from the pre-#2284 refuter.ag under the same inputs.
  PB="$WORK/probe"; mkdir -p "$PB"
  ( cd "$PB" && agentis init >/dev/null 2>&1 ) || true
  printf 'exec.env_passthrough = CAND_FILE_FN,CAND_CLASS,CAND_SEVERITY,CAND_EXPLOIT,CODE_PATH,BRIEF_PATH,AUX_CODE_PATH,CAND_INVARIANT,INV_HARNESS_PATH,SEVERITY_RUBRIC,RUBRIC_REASK_GROUNDS,GROUND_EVIDENCE,SCOPE_ASSUMPTIONS_PATH,CAND_BATCH_PATH\n' > "$PB/.agentis/config"
  printf 'contract A { function f() public { x -= 1; } }\n' > "$PB/code.sol"
  printf 'brief line\n' > "$PB/brief.md"
  printf 'A1|token|README.md:3|standard ERC20 only\n' > "$PB/scope.txt"
  printf '1|A.sol:f:3|C6|High|drain via f\n2|A.sol:f:9|C2|Medium|reenter f\n' > "$PB/batch.txt"
  { awk '/^let verdict = prompt\(/ {exit} {print}' "$REFUTER_AG"
    printf 'print("SHA=" + sha256_hex(instruction));\n'
    printf 'print("TIEBREAKS=" + to_string(len(regex_split("TIE-BREAK: if after", instruction)) - 1));\n'
  } > "$PB/probe.ag"
  probe() {
    ( cd "$PB" && env CAND_FILE_FN=A.sol:f CAND_CLASS=C6 CAND_SEVERITY=High CAND_EXPLOIT="drain via f" \
        CODE_PATH="$PB/code.sol" BRIEF_PATH="$PB/brief.md" "$@" agentis go probe.ag --enable-exec 2>&1 ) | grep "^$P_KEY=" | tail -1 | cut -d= -f2  # no-pii: the probe never calls prompt() — it prints a hash
  }
  P_KEY=SHA
  G1="$(probe)"; G2="$(probe SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 SCOPE_ASSUMPTIONS_PATH="$PB/scope.txt")"
  G3="$(probe CAND_INVARIANT="inv broken")"; G4="$(probe AUX_CODE_PATH="$PB/code.sol" SEVERITY_RUBRIC=1 RUBRIC_REASK_GROUNDS=no-attacker)"
  check "$G1" "282f52be3c435bdcc504389d1c29522c64f15e7e87153e8b9f16d347a89147e1" "k) probe: the default single-candidate instruction is byte-identical to the pre-#2284 one"
  check "$G2" "52ca1620ee73fe614f7d0d0b01683b047d6cbd765854e5fc513fc1d017821928" "k) probe: rubric + evidence contract + scope block — byte-identical"
  check "$G3" "17fd95e2d4c731d245ed9ec8cabee60bc588c6ec31c5e2f939f92ea21428a040" "k) probe: the #1938 invariant mode — byte-identical"
  check "$G4" "1e6abf61d72b57ab722fe9fe1d35b6d3c271e512a3e8f08ff854c63153d5e8f8" "k) probe: appendix + rubric re-ask — byte-identical"
  P_KEY=TIEBREAKS
  check "$(probe CAND_BATCH_PATH="$PB/batch.txt" SEVERITY_RUBRIC=1)" "1" "k) probe: the batch instruction carries the judge body (and its tie-break) exactly once"
  B_OUT="$( cd "$PB" && env CAND_FILE_FN=A.sol:f CAND_CLASS=batch CODE_PATH="$PB/code.sol" BRIEF_PATH="$PB/brief.md" \
      CAND_BATCH_PATH="$PB/batch.txt" agentis go probe.ag --enable-exec 2>&1 )"  # no-pii: the probe never calls prompt()
  S_OUT="$( cd "$PB" && env CAND_FILE_FN=A.sol:f CAND_CLASS=C6 CODE_PATH="$PB/code.sol" BRIEF_PATH="$PB/brief.md" \
      agentis go probe.ag --enable-exec 2>&1 )"  # no-pii: the probe never calls prompt()
  if printf '%s\n' "$B_OUT" | grep -q '^REFUTE-BATCH|refute|2$' && ! printf '%s\n' "$S_OUT" | grep -q 'REFUTE-BATCH|'; then
    ok "k) probe: a staged batch prints REFUTE-BATCH|refute|2; the single-candidate probes print none"
  else
    bad "k) probe: the batch sentinel did not render"
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the batched first read holds (per-candidate verdicts, ON == OFF on the same answers, fallbacks lose nothing)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) failed"
exit 1
