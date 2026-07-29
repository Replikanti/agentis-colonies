#!/usr/bin/env bash
# demo-mech-judge.sh — proof of the #1829 SEMANTIC MECHANISM JUDGE scoring mode.
#
# The corpus bench decides "did the hunter find this ground-truth bug?" with score-match.py's location-first
# token matcher (#1697): a lead HITs a truth row when the lead's file basename AND function name both occur in
# that row's prose. That ruler is wrong in BOTH directions, which is what #1829 reports:
#   * NAME-DIVERGENT TRUE MATCH is missed — the hunter names the factory/getter that actually contains the
#     faulty code while the report's prose anchors elsewhere and never names that function.
#   * NAME-COINCIDENT FALSE MATCH is credited — a candidate shares a function name with a row while describing
#     a completely different mechanism.
# The fix is a semantic judge that decides ROOT CAUSE + MECHANISM identity instead of name co-occurrence. It is
# an OPT-IN mode of the same scorer (`--judge off|cache|cmd`, default `off`) so the frozen #1697 ruler is
# untouched, and in judge mode the judge is AUTHORITATIVE — there is no silent fallback to the token matcher,
# because a fallback would re-import exactly the two bugs above.
#
# GT EQUIVALENCE CLASSES (#1840) — a residual of the same defect, pinned here too. The judge is asked for at
# most one MATCH per candidate and only ever sees one --judge-batch slice at a time, so when a judging repo
# accepted TWO rows for the same underlying bug, a lead that found it credits whichever twin the model named.
# Because the headline is stratified by rarity and the twins usually have very different watson counts, the
# lost one is the RARE one — the pipeline finds a rare bug and is scored as if it had not. The fix is GT-side:
# an artifact next to truth.tsv lists judged duplicate pairs (gt-dupes.sh), and `score-match.py --gt-dupes`
# credits the whole equivalence class. It expands `row_hit` ONLY, so no denominator and no lead count moves.
#
# THE SCORING GATE (#1841) — the second residual of the same defect, pinned here too. The judge obeys "a
# divergent location is not disqualifying" in its DECISION but not in its CONFIDENCE: a lead that describes the
# GT row's root cause from a superseded copy / factory / helper comes back MATCH with a confidence in the 60s.
# The old `--judge-min-confidence` default of 70 then turned that hedge into a scored MISS, so the rule and the
# ruler contradicted each other. The default is now 60 — placed BELOW the whole observed 62-68 hedge band, an
# outlier floor rather than a recall parameter — and every judged scorecard carries a `GATE` trailer naming the
# threshold in force plus what it dropped, so a gate can never move a headline silently again. It cannot
# re-open the #1829 false-positive direction: the gate only ever DROPS MATCHes, so no threshold can credit a
# candidate the judge decided NO-MATCH on.
#
# This demo has FOUR parts (all CI-safe: no forge, no LLM, no network — the judge runs against a recorded
# decision cache and offline stubs):
#   1) SOURCE-GUARD (always): mech-judge.sh judges through the flat-cyborg PTY wrapper and never through the
#      metered print-mode API; score-match.py defaults to --judge off; and the judge path never consults
#      lead_matches_row (no token fallback).
#   2) BEHAVIOURAL (when python3 is present): on ONE synthetic fixture, the token matcher's WRONG answer and
#      the judge's RIGHT answer are both pinned byte-exactly — 1/4 with the one hit on the wrong row vs 3/4
#      all-correct — and the fail-closed paths hold (a malformed judge reply fabricates no MATCH and raises
#      the JUDGE-ERROR count; a degraded judge aborts with exit 4; a --judge cache miss exits 4).
#   3) GT EQUIVALENCE (#1840, when python3 is present): on a SECOND, separate fixture the lost rare twin and
#      its recovery are both pinned byte-exactly (2/4 rare 0/2 -> 3/4 rare 1/2), together with the guard rails
#      — a genuine non-duplicate that merely shares a function name is never co-credited, the LEADS trailer
#      never moves, a stale artifact is a hard exit 3, a raised merge bar re-derives the unexpanded number
#      from the same artifact, and the builder pairs exactly the twins.
#   4) LOCATION DIVERGENCE vs THE GATE (#1841, when python3 is present): on a THIRD fixture whose recorded
#      decisions carry a location-hedged `MATCH|64`, the defect and the fix are pinned byte-exactly on ONE
#      decision set — at gate 70 the row is MISS (`GATE 70 1 1`), at the shipped default it is credited
#      (`GATE 60 0 0`) with an identical `JUDGE` trailer, so the fix is a RE-SCORE and not a re-judge. Plus
#      the #1829 guard in the same fixture (a name-coincident different-mechanism lead stays MISS even at
#      `--judge-min-confidence 0`) and a source-guard that the default has exactly one value across the
#      scorer and both harnesses.
#
# Usage:  dark-factory/demo-mech-judge.sh
# Exit: 0 = all assertions hold (SKIPs cleanly when python3 is absent) ; 1 = a regression ; 3 = missing fixture.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CB="$HERE/bench/corpus-bench"
SCOREMATCH="$CB/score-match.py"
JUDGE="$CB/mech-judge.sh"
FIX="$CB/fixtures/mech-judge"
STUB="$FIX/judge-stub.sh"
DFIX="$CB/fixtures/gt-dupes"
GTDUPES="$CB/gt-dupes.sh"
LFIX="$CB/fixtures/mech-judge-location"
RUNBENCH="$CB/run-corpus-bench.sh"
GENRECALL="$CB/generation-recall.sh"

FAILS=0
note() { echo "demo-mech-judge.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$SCOREMATCH" ] || { note "scorer not found: $SCOREMATCH" >&2; exit 3; }
[ -f "$JUDGE" ]      || { note "judge driver not found: $JUDGE" >&2; exit 3; }
for f in truth.tsv leads.json judge-stub.sh judge-decisions.jsonl expected-scorecard.token.txt expected-scorecard.judge.txt; do
  [ -f "$FIX/$f" ] || { note "fixture missing: $FIX/$f" >&2; exit 3; }
done
[ -f "$GTDUPES" ] || { note "builder not found: $GTDUPES" >&2; exit 3; }
for f in truth.tsv leads.json judge-stub.sh judge-decisions.jsonl dupes-stub.sh gt-dupes.tsv \
         gt-dupes.stale.tsv expected-scorecard.nodup.txt expected-scorecard.dup.txt; do
  [ -f "$DFIX/$f" ] || { note "fixture missing: $DFIX/$f" >&2; exit 3; }
done
for f in truth.tsv leads.json judge-stub.sh judge-decisions.jsonl \
         expected-scorecard.default.txt expected-scorecard.gated.txt; do
  [ -f "$LFIX/$f" ] || { note "fixture missing: $LFIX/$f" >&2; exit 3; }
done
[ -f "$RUNBENCH" ]  || { note "harness not found: $RUNBENCH" >&2; exit 3; }
[ -f "$GENRECALL" ] || { note "harness not found: $GENRECALL" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD — the judge wiring (CI-safe, no toolchain).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1829 mechanism-judge wiring ..."

if grep -q 'MECH_JUDGE_LLM_CMD' "$JUDGE" && grep -q 'flat-cyborg-claude.sh' "$JUDGE"; then
  ok "mech-judge.sh drives the flat-cyborg PTY wrapper (MECH_JUDGE_LLM_CMD indirection, flat-rate session)"
else
  bad "mech-judge.sh does not route its LLM path through the flat-cyborg wrapper"
fi

# Only NON-COMMENT lines count: the header legitimately explains why the metered print-mode API is not used.
if grep -vE '^[[:space:]]*#' "$JUDGE" | grep -qE 'claude[[:space:]]+-p'; then
  bad "mech-judge.sh shells out to the metered print-mode API instead of the flat-cyborg wrapper"
else
  ok "mech-judge.sh never invokes the metered print-mode API (subscription-billed judging only)"
fi

if grep -q 'judge_mode = "off"' "$SCOREMATCH"; then
  ok "score-match.py defaults to --judge off (the frozen #1697 token matcher stays the default ruler)"
else
  bad "score-match.py does not default --judge to off"
fi

# No token fallback in judge mode: lead_matches_row() must be defined once and called once, and that ONE call
# site must live in the `judge_mode == "off"` branch — never inside run_judge().
lmr_refs="$(grep -vE '^[[:space:]]*#' "$SCOREMATCH" | grep -c 'lead_matches_row(')"
judge_body="$(awk '/^def run_judge\(/{f=1} f && /^def [a-z_]+\(/ && !/^def run_judge\(/{f=0} f' "$SCOREMATCH")"
if [ "$lmr_refs" -eq 2 ] && ! printf '%s\n' "$judge_body" | grep -q 'lead_matches_row'; then
  ok "the judge path never consults lead_matches_row — no silent fallback to the token matcher"
else
  bad "lead_matches_row is reachable from the judge path (refs=$lmr_refs) — the judge must be authoritative"
fi

if grep -q 'JUDGE-ERROR' "$SCOREMATCH" && grep -q 'judge-max-error-rate' "$SCOREMATCH"; then
  ok "an unparseable reply is a JUDGE-ERROR and a degraded judge aborts above --judge-max-error-rate"
else
  bad "score-match.py is missing the JUDGE-ERROR / max-error-rate fail-closed path"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) BEHAVIOURAL — the acceptance regression, pinned byte-exactly on one fixture.
# ----------------------------------------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 not on PATH — install python3 to run the mechanism-judge scoring assertions"
else
  note "running the token-vs-judge scoring regression on fixtures/mech-judge/ ..."

  # (a) the DOCUMENTED DEFECT: the token matcher scores 1/4 and its single hit is on the WRONG row.
  TOK="$(python3 "$SCOREMATCH" "$FIX/truth.tsv" "$FIX/leads.json" 2>/dev/null)"
  if [ "$TOK" = "$(cat "$FIX/expected-scorecard.token.txt")" ]; then
    ok "(a) --judge off reproduces the pinned TOKEN scorecard (1/4, and the one HIT is the name-coincident FP)"
  else
    bad "(a) the token scorecard changed — the frozen #1697 matcher must stay byte-identical"
    diff <(printf '%s\n' "$TOK") "$FIX/expected-scorecard.token.txt" >&2 || true
  fi

  # (b) --judge cache: replaying the recorded decisions fixes BOTH directions (3/4, all correct).
  CACHED="$(python3 "$SCOREMATCH" "$FIX/truth.tsv" "$FIX/leads.json" \
              --judge cache --judge-cache "$FIX/judge-decisions.jsonl" 2>/dev/null)"
  if [ "$CACHED" = "$(cat "$FIX/expected-scorecard.judge.txt")" ]; then
    ok "(b) --judge cache reproduces the pinned JUDGE scorecard (3/4: the two name-divergent true matches are"
    echo "         credited and the name-coincident false match is rejected)"
  else
    bad "(b) the --judge cache scorecard DIFFERS from expected-scorecard.judge.txt"
    diff <(printf '%s\n' "$CACHED") "$FIX/expected-scorecard.judge.txt" >&2 || true
  fi

  # (c) --judge cmd over the offline stub must produce the SAME scorecard as the recorded replay: the recorded
  #     raw reply is authoritative, so a live-judged run is exactly reproducible offline.
  LIVE="$(python3 "$SCOREMATCH" "$FIX/truth.tsv" "$FIX/leads.json" --judge cmd --judge-cmd "$STUB" 2>/dev/null)"
  if [ "$LIVE" = "$CACHED" ]; then
    ok "(c) --judge cmd (offline stub driver) and --judge cache agree byte-for-byte — a judged run replays"
  else
    bad "(c) --judge cmd and --judge cache disagree — a judged number would not be reproducible"
    diff <(printf '%s\n' "$LIVE") <(printf '%s\n' "$CACHED") >&2 || true
  fi

  # (d) a malformed judge reply fabricates NO match and is counted as a JUDGE-ERROR (never a silent NO-MATCH).
  MAL="$(MECH_JUDGE_STUB_MODE=malformed python3 "$SCOREMATCH" "$FIX/truth.tsv" "$FIX/leads.json" \
           --judge cmd --judge-cmd "$STUB" --judge-max-error-rate 100 2>/dev/null)"
  if ! printf '%s\n' "$MAL" | grep -q 'HIT' && printf '%s\n' "$MAL" | grep -qE '^JUDGE	[0-9]+	[1-9][0-9]*$'; then
    ok "(d) an unparseable judge reply yields NO hit and a nonzero JUDGE error count (fail-closed)"
  else
    bad "(d) a malformed judge reply did not fail closed"
    printf '%s\n' "$MAL" | sed 's/^/         | /' | head -8
  fi

  # (e) a degraded judge must NOT publish a plausible-looking low recall: over the max error rate -> exit 4.
  MECH_JUDGE_STUB_MODE=malformed python3 "$SCOREMATCH" "$FIX/truth.tsv" "$FIX/leads.json" \
    --judge cmd --judge-cmd "$STUB" >/dev/null 2>&1 && deg_rc=0 || deg_rc=$?
  if [ "$deg_rc" -eq 4 ]; then
    ok "(e) a judge over --judge-max-error-rate aborts with exit 4 instead of reporting a degraded recall"
  else
    bad "(e) expected exit 4 from a degraded judge, got $deg_rc"
  fi

  # (f) --judge cache is deterministic BECAUSE a miss is fatal: it never silently falls back to anything.
  python3 "$SCOREMATCH" "$CB/fixtures/score/truth.tsv" "$CB/fixtures/score/verified_findings.json" \
    --judge cache --judge-cache "$FIX/judge-decisions.jsonl" >/dev/null 2>&1 && miss_rc=0 || miss_rc=$?
  if [ "$miss_rc" -eq 4 ]; then
    ok "(f) a --judge cache MISS exits 4 (a replay never invents a decision, and never falls back to tokens)"
  else
    bad "(f) expected exit 4 from a --judge cache miss, got $miss_rc"
  fi

  # (g) the driver's own contract self-test (mock round-trip, flat-cyborg-only path, no fabricated MATCH).
  "$JUDGE" --self-test >/dev/null 2>&1 && st_rc=0 || st_rc=$?
  if [ "$st_rc" -eq 0 ]; then
    ok "(g) mech-judge.sh --self-test PASSED (driver contract: request -> VERDICT| lines, flat-cyborg only)"
  else
    bad "(g) mech-judge.sh --self-test FAILED (exit $st_rc)"
    "$JUDGE" --self-test 2>&1 | sed 's/^/         | /' | tail -10
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# 3) GT EQUIVALENCE CLASSES (#1840) — the lost rare twin, and the guard rails against over-crediting.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding + pinning the #1840 GT-equivalence crediting ..."

# (o) the pairing pass reuses the SAME judging path as scoring: mech-judge.sh (hence the flat-cyborg wrapper),
#     never the metered print-mode API. Same non-comment grep idiom as the (b2) check above.
if grep -qE '^JUDGE_CMD=.*mech-judge\.sh' "$GTDUPES" \
   && ! grep -vE '^[[:space:]]*#' "$GTDUPES" | grep -qE 'claude[[:space:]]+-p'; then
  ok "(o) gt-dupes.sh routes its LLM path through mech-judge.sh and never the metered print-mode API"
else
  bad "(o) gt-dupes.sh does not reuse mech-judge.sh, or shells out to the metered print-mode API"
fi

if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 not on PATH — install python3 to run the GT-equivalence scoring assertions"
else
  DCACHE="$DFIX/judge-decisions.jsonl"

  # (h) the DEFECT, pinned: the judge emits ONE match for the lead, so the rare twin D-2 scores MISS. 2/4,
  #     and the rare stratum reads 0/2 even though the pipeline found one of its two bugs.
  NODUP="$(python3 "$SCOREMATCH" "$DFIX/truth.tsv" "$DFIX/leads.json" \
             --judge cache --judge-cache "$DCACHE" 2>/dev/null)"
  if [ "$NODUP" = "$(cat "$DFIX/expected-scorecard.nodup.txt")" ]; then
    ok "(h) without --gt-dupes the recorded decisions reproduce the DEFECT byte-exactly (D-2, the rare twin,"
    echo "         is MISS: 2/4, rare 0/2)"
  else
    bad "(h) the un-expanded scorecard DIFFERS from expected-scorecard.nodup.txt"
    diff <(printf '%s\n' "$NODUP") "$DFIX/expected-scorecard.nodup.txt" >&2 || true
  fi

  # (i) the FIX, pinned: the SAME replay with the equivalence artifact credits the whole class. 3/4, rare 1/2,
  #     and the DUP/DUPHIT trailers make the expansion separable (hits - expanded = the (h) number).
  DUP="$(python3 "$SCOREMATCH" "$DFIX/truth.tsv" "$DFIX/leads.json" \
           --judge cache --judge-cache "$DCACHE" --gt-dupes "$DFIX/gt-dupes.tsv" 2>/dev/null)"
  if [ "$DUP" = "$(cat "$DFIX/expected-scorecard.dup.txt")" ]; then
    ok "(i) --gt-dupes credits the equivalence class on the SAME replay (D-2 flips to HIT: 3/4, rare 1/2,"
    echo "         DUP 1 1, DUPHIT D-2 D-1 — so hits minus expanded recovers the pre-#1840 2/4)"
  else
    bad "(i) the expanded scorecard DIFFERS from expected-scorecard.dup.txt"
    diff <(printf '%s\n' "$DUP") "$DFIX/expected-scorecard.dup.txt" >&2 || true
  fi

  # (j) NEGATIVE CONTROL: D-3 shares the settleEpoch function name with the hit row D-4 but is a different
  #     mechanism. It must stay MISS in BOTH runs — asserted on the row line itself, not only via the
  #     byte-compare, because this is the failure mode class expansion could introduce.
  if printf '%s\n' "$NODUP" | grep -q '^D-3	MISS$' && printf '%s\n' "$DUP" | grep -q '^D-3	MISS$'; then
    ok "(j) the name-sharing non-duplicate D-3 is MISS in BOTH runs — a shared function name never co-credits"
  else
    bad "(j) D-3 was credited: class expansion reached a row that is NOT the same bug"
    diff <(printf '%s\n' "$NODUP") <(printf '%s\n' "$DUP") >&2 || true
  fi

  # (k) PRECISION INVARIANT: expansion touches row_hit only. The LEADS trailer — verified leads and how many
  #     matched — must be byte-identical, so one lead can never become N matched leads.
  L_NODUP="$(printf '%s\n' "$NODUP" | grep '^LEADS	')"
  L_DUP="$(printf '%s\n' "$DUP" | grep '^LEADS	')"
  if [ -n "$L_NODUP" ] && [ "$L_NODUP" = "$L_DUP" ]; then
    ok "(k) the LEADS trailer is byte-identical with and without --gt-dupes ($L_NODUP) — one lead never"
    echo "         becomes N matched leads, so the unmatched-lead triage queue keeps its meaning"
  else
    bad "(k) --gt-dupes moved the LEADS trailer ('$L_NODUP' vs '$L_DUP') — expansion must touch row_hit only"
  fi

  # (l) a STALE artifact (naming a sev_id this truth.tsv does not contain) is a hard exit 3, never a silent
  #     skip: an artifact from another contest must not mis-credit the headline.
  python3 "$SCOREMATCH" "$DFIX/truth.tsv" "$DFIX/leads.json" --judge cache --judge-cache "$DCACHE" \
    --gt-dupes "$DFIX/gt-dupes.stale.tsv" >/dev/null 2>&1 && stale_rc=0 || stale_rc=$?
  if [ "$stale_rc" -eq 3 ]; then
    ok "(l) a --gt-dupes artifact naming an unknown sev_id exits 3 (stale/wrong-contest artifacts fail loud)"
  else
    bad "(l) expected exit 3 from a stale --gt-dupes artifact, got $stale_rc"
  fi

  # (m) THRESHOLD SENSITIVITY / baseline comparability: the merge bar is applied at SCORING time, so raising
  #     it above the pair's confidence re-derives the UNEXPANDED number from the very same archived artifact.
  #     The DUP attribution trailer stays (it reports 0 classes, 0 expansions) — that is what makes the two
  #     numbers auditable as one run; everything above it must match (h) byte-for-byte.
  HICONF="$(python3 "$SCOREMATCH" "$DFIX/truth.tsv" "$DFIX/leads.json" --judge cache --judge-cache "$DCACHE" \
              --gt-dupes "$DFIX/gt-dupes.tsv" --gt-dupes-min-confidence 99 2>/dev/null)"
  HICONF_BODY="$(printf '%s\n' "$HICONF" | grep -vE '^(DUP|DUPHIT)	')"
  if [ "$HICONF_BODY" = "$(cat "$DFIX/expected-scorecard.nodup.txt")" ] \
     && [ "$(printf '%s\n' "$HICONF" | grep -c '^DUPHIT	')" -eq 0 ] \
     && printf '%s\n' "$HICONF" | grep -q '^DUP	0	0$'; then
    ok "(m) --gt-dupes-min-confidence 99 re-derives the UNEXPANDED scorecard from the SAME artifact"
    echo "         (identical to (h) plus an explicit 'DUP 0 0' — both numbers come from one archive)"
  else
    bad "(m) raising the merge bar did not reproduce the unexpanded scorecard"
    diff <(printf '%s\n' "$HICONF_BODY") "$DFIX/expected-scorecard.nodup.txt" >&2 || true
  fi

  # (n) BUILDER CONTRACT: gt-dupes.sh over the offline builder stub reproduces the committed artifact body —
  #     it pairs the two twins and does NOT pair the two rows that merely share a function name.
  BTMP="$(mktemp -d)"
  bash "$GTDUPES" "$DFIX/truth.tsv" "$BTMP/gt-dupes.tsv" --judge-cmd "$DFIX/dupes-stub.sh" >/dev/null 2>&1
  if diff <(grep -v '^#' "$BTMP/gt-dupes.tsv" 2>/dev/null) <(grep -v '^#' "$DFIX/gt-dupes.tsv") >/dev/null 2>&1; then
    ok "(n) gt-dupes.sh rebuilds the committed artifact body (pairs D-1/D-2, leaves D-3/D-4 unpaired)"
  else
    bad "(n) the rebuilt gt-dupes.tsv body differs from the committed fixture"
    diff <(grep -v '^#' "$BTMP/gt-dupes.tsv" 2>/dev/null) <(grep -v '^#' "$DFIX/gt-dupes.tsv") >&2 || true
  fi
  rm -rf "$BTMP"
fi

# ----------------------------------------------------------------------------------------------------------
# 4) LOCATION DIVERGENCE vs THE GATE (#1841) — the hedged MATCH the old 70-point default threw away.
# ----------------------------------------------------------------------------------------------------------
note "pinning the #1841 confidence gate on fixtures/mech-judge-location/ ..."

# (s) SOURCE-GUARD against ruler drift: the shipped default has exactly ONE value across the scorer and both
#     harnesses, each harness forwards it UNCONDITIONALLY (so the gate it prints is the gate it applied), and
#     run-corpus-bench.sh reports the threshold in the human line AND in --json.
sm_default="$(grep -oE '^[[:space:]]*judge_min_conf = [0-9]+' "$SCOREMATCH" | grep -oE '[0-9]+$')"
rb_default="$(grep -oE '^JUDGE_MINCONF_DEFAULT=[0-9]+' "$RUNBENCH" | grep -oE '[0-9]+$')"
gr_default="$(grep -oE '^JUDGE_MINCONF_DEFAULT=[0-9]+' "$GENRECALL" | grep -oE '[0-9]+$')"
rb_forwards="$(grep -cE '^[[:space:]]*JUDGE_ARGS\+=\(--judge-min-confidence' "$RUNBENCH")"
gr_forwards="$(grep -cE '^[[:space:]]*JUDGE_ARGS\+=\(--judge-min-confidence' "$GENRECALL")"
rb_json_conf="$(grep -c 'min_confidence' "$RUNBENCH")"
# The human line must interpolate the threshold the scorer reported back, not a re-derived one. The pattern is
# deliberately a LITERAL '$gate_conf' — it is source text being grepped for, not an expansion.
# shellcheck disable=SC2016
rb_human_conf='min-confidence $gate_conf'
if [ -n "$sm_default" ] && [ "$sm_default" = "$rb_default" ] && [ "$sm_default" = "$gr_default" ] \
   && [ "$rb_forwards" -eq 1 ] && [ "$gr_forwards" -eq 1 ] \
   && grep -qF "$rb_human_conf" "$RUNBENCH" && [ "$rb_json_conf" -ge 2 ]; then
  ok "(s) one ruler, one value: score-match.py, run-corpus-bench.sh and generation-recall.sh all default the"
  echo "         gate to $sm_default, both harnesses forward it unconditionally, and run-corpus-bench.sh prints it in"
  echo "         the human line and in --json — the printed threshold IS the applied one"
else
  bad "(s) the judge gate default drifted or is not recorded (scorer '$sm_default', run-corpus-bench"
  bad "    '$rb_default', generation-recall '$gr_default'; unconditional forwards $rb_forwards/$gr_forwards)"
fi

if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 not on PATH — install python3 to run the #1841 confidence-gate scoring assertions"
else
  LCACHE="$LFIX/judge-decisions.jsonl"

  # (p) the DEFECT, pinned: at the OLD 70-point gate the location-hedged MATCH|64 on G-1 is thrown away. The
  #     GATE trailer names the ruler and its cost — 1 dropped MATCH decision, 1 row lost.
  GATED="$(python3 "$SCOREMATCH" "$LFIX/truth.tsv" "$LFIX/leads.json" \
             --judge cache --judge-cache "$LCACHE" --judge-min-confidence 70 2>/dev/null)"
  if [ "$GATED" = "$(cat "$LFIX/expected-scorecard.gated.txt")" ]; then
    ok "(p) at --judge-min-confidence 70 the recorded decisions reproduce the DEFECT byte-exactly (G-1, matched"
    echo "         from a superseded-copy location at confidence 64, is MISS; GATE 70 1 1)"
  else
    bad "(p) the gated scorecard DIFFERS from expected-scorecard.gated.txt"
    diff <(printf '%s\n' "$GATED") "$LFIX/expected-scorecard.gated.txt" >&2 || true
  fi

  # (q) the FIX, pinned: the SAME recorded decisions credit G-1 at the shipped default, and the JUDGE trailer
  #     is IDENTICAL in both runs — the fix is a RE-SCORE of decisions already made, never a re-judge.
  DEFAULTED="$(python3 "$SCOREMATCH" "$LFIX/truth.tsv" "$LFIX/leads.json" \
                 --judge cache --judge-cache "$LCACHE" 2>/dev/null)"
  J_GATED="$(printf '%s\n' "$GATED" | grep '^JUDGE	')"
  J_DEFAULT="$(printf '%s\n' "$DEFAULTED" | grep '^JUDGE	')"
  if [ "$DEFAULTED" = "$(cat "$LFIX/expected-scorecard.default.txt")" ] \
     && [ -n "$J_GATED" ] && [ "$J_GATED" = "$J_DEFAULT" ]; then
    ok "(q) the shipped default credits G-1 on the SAME decisions (GATE 60 0 0) with an identical JUDGE"
    echo "         trailer ($J_DEFAULT) — a re-score of recorded decisions, not a re-judge"
  else
    bad "(q) the default-gate scorecard DIFFERS from expected-scorecard.default.txt, or the JUDGE trailer moved"
    diff <(printf '%s\n' "$DEFAULTED") "$LFIX/expected-scorecard.default.txt" >&2 || true
  fi

  # (r) the #1829 GUARD, both directions from one fixture: G-3's exact file+function is named by a lead that
  #     describes a DIFFERENT mechanism. It is excluded by the DECISION, so NO gate value can credit it —
  #     asserted at 0 as well as at the default and the old 70, because the gate only ever DROPS MATCHes.
  ZERO="$(python3 "$SCOREMATCH" "$LFIX/truth.tsv" "$LFIX/leads.json" \
            --judge cache --judge-cache "$LCACHE" --judge-min-confidence 0 2>/dev/null)"
  if printf '%s\n' "$ZERO" | grep -q '^G-3	MISS$' \
     && printf '%s\n' "$DEFAULTED" | grep -q '^G-3	MISS$' \
     && printf '%s\n' "$GATED" | grep -q '^G-3	MISS$'; then
    ok "(r) the name-coincident different-mechanism lead leaves G-3 MISS at gate 0, 60 AND 70 — lowering the"
    echo "         gate cannot re-open the #1829 false-positive direction"
  else
    bad "(r) G-3 was credited at some threshold — a different mechanism must be rejected by the DECISION"
    printf '%s\n' "$ZERO" | sed 's/^/         | /' | head -8
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #1829 semantic mechanism judge is wired as an OPT-IN score-match.py mode. --judge off keeps"
  note "      the frozen #1697 token matcher byte-identical; --judge cache/cmd replaces it with a root-cause +"
  note "      mechanism decision that credits the name-divergent true matches and rejects the name-coincident"
  note "      false match on the same fixture (1/4 wrong -> 3/4 right). The judge is AUTHORITATIVE — no token"
  note "      fallback — and fails CLOSED: an unparseable reply is a JUDGE-ERROR, a degraded judge or a cache"
  note "      miss exits 4, and every judging call goes through the flat-cyborg subscription wrapper."
  note "      #1840 rides on the same scorer: --gt-dupes credits the GT EQUIVALENCE CLASS, so a lead that"
  note "      matched one of two accepted rows for the same bug no longer loses the rare twin (2/4 rare 0/2"
  note "      -> 3/4 rare 1/2 on the same recorded decisions). Denominators, the LEADS trailer and the"
  note "      unmatched-lead queue are untouched, a name-sharing non-duplicate is never co-credited, a stale"
  note "      artifact exits 3, and DUP/DUPHIT keep the expansion separable from the direct hits."
  note "      #1841 closes the last residual: the judge hedges its CONFIDENCE on a location it was told not to"
  note "      hold against a candidate, so the gate moved to 60 — below the whole observed hedge band, an"
  note "      outlier floor rather than a recall knob — and every judged scorecard now carries a GATE trailer"
  note "      naming the threshold and what it cost. The same recorded decisions re-score at any threshold"
  note "      (70 reproduces the old number byte-exactly), and no gate value can credit a candidate the judge"
  note "      decided NO-MATCH on."
  exit 0
fi
note "DEMO FAILED — a #1829 mechanism-judge / #1840 GT-equivalence / #1841 confidence-gate assertion did not hold" >&2
exit 1
