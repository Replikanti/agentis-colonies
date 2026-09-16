#!/usr/bin/env bash
# generation-recall.sh — the dark-factory GENERATION-recall harness (issue #1730). Sibling of
# run-corpus-bench.sh, but it scores the GENERATOR's hypotheses against ground truth instead of the pipeline's
# post-confirmation verified findings — isolating the GENERATION step from fuzzer/refuter confirmation. It
# answers the #1716 question the ON-vs-OFF A/B could not: of the GT bugs the pipeline never SUBMITTED, how
# many did it actually NAME (a breadth candidate or a generated invariant) but then fail to CONFIRM?
#
# It reuses, UNCHANGED, the two frozen corpus-bench primitives — extract-gt.sh (truth.tsv schema) and
# score-match.py (the #1697 location-first matcher, pinned by run-corpus-bench.sh --self-test) — and a thin
# adapter, hypotheses-to-leads.py, that projects the two GENERATION artifacts a corpus-bench run already
# stages into the `{"verified":[...]}` lead shape score-match.py consumes:
#   * the breadth hunter's PRE-REFUTE candidates  (zone-hunt-out/discovery/discovery-results.merged.json)
#   * the deep-hunt lens's generated invariant targets  (zone-hunt-out/deep-hunt/*/run/invariant_*.log,
#     the `INVARIANT|<file:fn>|<verdict>` lines) — scored with the FUZZER VERDICT IGNORED, so a CLEAN
#     invariant that still NAMES a GT bug's location counts toward generation-recall.
#
# METRIC (pinned): generation-recall = (DISTINCT GT truth.tsv rows location-first matched by >=1 GENERATED
# hypothesis) / (total GT rows). The fuzzer verdict is IGNORED; matching is score-match.py's file-basename +
# function co-occurrence rule, which is threshold-INDEPENDENT for location-resolvable leads. Reported overall
# + by severity (High/Medium) + by rarity (rare 1-2 / mid 3-8 / consensus 9+) — the same strata as
# run-corpus-bench.sh; the rare tier is the headline capability number. Every contest ALSO reports
# `reachable rare = k/N` (#2215): the rare rows the matcher can resolve at all. A rare row whose ground truth
# carries no resolvable `<file>:<function>` anchor is a denominator the hunter cannot move, so quoting the
# headline without it reads a MATCHER bound as a CAPABILITY bound. When a contest also has a
# verify/verified_findings.json, the GENERATION-minus-VERIFIED DELTA (GT rows a hypothesis NAMED but the
# fuzzer/refuter then failed to confirm — the #1716 expressiveness gap, made measurable) is printed too.
#
# MODES:
#
# TIER 2 (#2217 PR B) — SCORED SEPARATELY, NEVER FOLDED IN. A tier-2 record is a check a cell DERIVED and did
# not settle, lifted out of the cell object by run-discovery.sh --tier2 with a location its own text implies.
# That is weaker evidence than a candidate the model chose to file, so this harness scores TWICE: the PRIMARY
# generation-recall is computed from a lead set the adapter emits WITHOUT --include-tier2 — it contains NO
# tier-2 lead, by construction, whatever the merged file carries — and the tier-2 contribution is reported on
# its own line (and as `tier2_hits` in --json) as the GT rows credited ONLY once tier-2 leads are added. Both
# sides of that subtraction are measured with the SAME ruler (same --min-overlap / --judge / --gt-dupes), so
# the secondary number is a delta, never a second metric.
#
#   --self-test (default; CI-safe, no network/LLM/forge): run the adapter over fixtures/generation-recall/
#     and assert (a) the projected union byte-matches expected-leads.json; (b) score-match.py over it
#     byte-matches expected-scorecard.txt AND is IDENTICAL at --min-overlap 2 and 5 (threshold-independent);
#     (c) generation-recall > verified-recall on the SAME fixture — the CLEAN invariant that named the GT bug
#     HITs generation but the fuzzer's DROP leaves verified a MISS (the generation-vs-confirmation delta);
#     (d) #2215 — the LOC/LOCHIT trailers are skipped by the recall reader, never counted as truth rows;
#     (e) #2231 — corpus_role resolves dev / holdout / unknown from corpus.tsv; (f) #2217 — a tier2[] record
#     at a GT location is projected ONLY under --include-tier2, is counted in tier2_hits, leaves the primary
#     number untouched, and does so identically at --min-overlap 2 and 5.
#   --from-work <dir> [--id <id>]... [--min-overlap N] [--json]: read an already-fetched/hunted corpus-bench
#     work dir and, per contest, project <id>/zone-hunt-out/discovery/discovery-results.merged.json +
#     <id>/zone-hunt-out/deep-hunt/*/run/invariant_*.log through the adapter, score the union against
#     <id>/truth.tsv, and report per-bug HIT/MISS + the stratified aggregate (+ the DELTA when
#     verify/verified_findings.json is present). A missing artifact is a logged skip, NEVER a false 0.
#
# Usage: generation-recall.sh [--self-test] | [--from-work <dir> [--id <id>]... [--min-overlap N] [--json]
#                             [--corpus <corpus.tsv>]
#                             [--judge <off|cache|cmd>] [--judge-cmd <p>] [--judge-cache <f>] [--judge-log <f>]
#                             [--judge-batch N] [--judge-min-confidence N] [--gt-dupes <f>]
#                             [--gt-dupes-min-confidence N]] [-h]
#   --judge* : #1829 — forwarded verbatim to score-match.py for BOTH the generation scorecard and the
#              verified-recall side of the DELTA, so the two halves are always measured with the SAME ruler.
#              Default `off` = the frozen #1697 token matcher; `--self-test` is always judge-off.
#              `--judge-min-confidence` defaults to 60 (#1841, the SAME value run-corpus-bench.sh uses) and is
#              ALWAYS forwarded explicitly in judge mode, so the gate this harness prints is the one it
#              passed, and the two harnesses can never disagree about which gate produced a number.
#   --corpus  : #2231 — the manifest the per-contest `role` (dev|holdout) is read from (default: corpus.tsv
#              next to this script). Every per-contest headline prints that role and a `dev` contest is
#              labelled IN-DISTRIBUTION: the lenses were designed on it, so its recall is not a claim.
#   #2215     : a truth.tsv with column 6 (`extract-gt.sh --code`) additionally lets score-match.py credit a
#              lead whose OWN (file, function) equals one of the row's GT location anchors. Those rows are
#              reported separately (`GT location anchors: ... credited ONLY via a location pair`) and are
#              always subtractable, so both the anchored and the frozen #1697 number come from one replay.
#   --gt-dupes* : #1840 — same deal for the GT-equivalence artifact: forwarded to BOTH halves of the DELTA, so
#              a duplicated GT pair is credited identically on the generation and the verified side. The
#              artifact is PER CONTEST (`<work>/<id>/gt-dupes.tsv`), so pass it with a single `--id`. Absent
#              by default; `--self-test` never uses it.
# Exit: 0 = stage ran (a low/zero recall is DATA, not a failure) ; 1 = --self-test regressed ; 2 = bad args ;
#       3 = missing prerequisite.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ADAPTER="$HERE/hypotheses-to-leads.py"
SCOREMATCH="$HERE/score-match.py"
FIX="$HERE/fixtures/generation-recall"
# #2231 hold-out policy: the manifest that says whether a contest is `dev` (lenses were designed on it,
# so its number is IN-DISTRIBUTION) or `holdout` (the only rows a recall CLAIM may be made on).
CORPUS="$HERE/corpus.tsv"

MODE="self-test"
# #1841: the scoring gate this harness forwards AND prints. Must equal score-match.py's judge_min_conf default
# and run-corpus-bench.sh's JUDGE_MINCONF_DEFAULT (demo-mech-judge.sh assertion (s) fails on divergence).
JUDGE_MINCONF_DEFAULT=60
WORK="" ; IDS="" ; MINOV="2" ; JSON=0
JUDGE="off" ; JUDGE_CMD="" ; JUDGE_CACHE="" ; JUDGE_LOG="" ; JUDGE_BATCH="" ; JUDGE_MINCONF=""
GT_DUPES="" ; GT_DUPES_MINCONF=""

nv() { [ "$1" -ge 2 ] || { echo "generation-recall.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do case "$1" in
  --self-test)   MODE="self-test"; shift ;;
  --from-work)   nv "$#"; MODE="from-work"; WORK="$2"; shift 2 ;;
  --id)          nv "$#"; IDS="$IDS $2"; shift 2 ;;
  --min-overlap) nv "$#"; MINOV="$2"; shift 2 ;;
  --corpus)      nv "$#"; CORPUS="$2"; shift 2 ;;
  --json)        JSON=1; shift ;;
  --judge)                nv "$#"; JUDGE="$2"; shift 2 ;;
  --judge-cmd)            nv "$#"; JUDGE_CMD="$2"; shift 2 ;;
  --judge-cache)          nv "$#"; JUDGE_CACHE="$2"; shift 2 ;;
  --judge-log)            nv "$#"; JUDGE_LOG="$2"; shift 2 ;;
  --judge-batch)          nv "$#"; JUDGE_BATCH="$2"; shift 2 ;;
  --judge-min-confidence) nv "$#"; JUDGE_MINCONF="$2"; shift 2 ;;
  --gt-dupes)                nv "$#"; GT_DUPES="$2"; shift 2 ;;
  --gt-dupes-min-confidence) nv "$#"; GT_DUPES_MINCONF="$2"; shift 2 ;;
  -h|--help)     awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
  *) echo "generation-recall.sh: unknown arg: $1" >&2; exit 2 ;;
esac; done

say() { echo "generation-recall.sh: $*" >&2; }

# #1829: judge flags forwarded to score-match.py. The mode is ALWAYS passed explicitly (never an empty array
# expansion) and defaults to `off`, which selects the frozen #1697 matcher — byte-identical output.
declare -a JUDGE_ARGS=(--judge "$JUDGE")
if [ "$JUDGE" != "off" ]; then
  [ -n "$JUDGE_CMD" ]     && JUDGE_ARGS+=(--judge-cmd "$JUDGE_CMD")
  [ -n "$JUDGE_CACHE" ]   && JUDGE_ARGS+=(--judge-cache "$JUDGE_CACHE")
  [ -n "$JUDGE_LOG" ]     && JUDGE_ARGS+=(--judge-log "$JUDGE_LOG")
  [ -n "$JUDGE_BATCH" ]   && JUDGE_ARGS+=(--judge-batch "$JUDGE_BATCH")
  # #1841: resolve to the shared default when unset and forward ALWAYS — the printed gate is by construction
  # the applied gate, on this harness exactly as on run-corpus-bench.sh.
  [ -n "$JUDGE_MINCONF" ] || JUDGE_MINCONF="$JUDGE_MINCONF_DEFAULT"
  JUDGE_ARGS+=(--judge-min-confidence "$JUDGE_MINCONF")
fi

# #1840: the GT-equivalence flags, forwarded to BOTH halves of the DELTA so one ruler measures both. The array
# is EMPTY by default, hence the `${arr[@]+...}` guard at every expansion (an unguarded empty expansion trips
# `set -u` on older bash).
declare -a DUPE_ARGS=()
if [ -n "$GT_DUPES" ]; then
  DUPE_ARGS+=(--gt-dupes "$GT_DUPES")
  [ -n "$GT_DUPES_MINCONF" ] && DUPE_ARGS+=(--gt-dupes-min-confidence "$GT_DUPES_MINCONF")
fi

# corpus_role <id> — echo the #2231 role (`dev`|`holdout`) of a corpus.tsv row, `?` when the id is not in the
# manifest (a hand-staged work dir, a CodeHawks target). Column 5, read BEFORE the optional scope_hint: with
# IFS=TAB an empty field collapses, so a role appended after a blank scope_hint would be read as one.
corpus_role() {
  _r=""
  [ -f "$CORPUS" ] && _r="$(awk -F'\t' -v id="$1" '$1==id && $1 !~ /^#/ {print $5; exit}' "$CORPUS" 2>/dev/null)"
  case "$_r" in dev|holdout) printf '%s' "$_r" ;; *) printf '?' ;; esac
}

# recall_hits <truth.tsv> <leads.json> — print "<hits> <total>" (HIT truth rows / total truth rows) from
# score-match.py at --min-overlap "$MINOV" (and the selected --judge / --gt-dupes mode). Empty on failure.
recall_hits() {
  _t="$1"; _j="$2"
  _sc="$(python3 "$SCOREMATCH" "$_t" "$_j" --min-overlap "$MINOV" "${JUDGE_ARGS[@]}" \
           ${DUPE_ARGS[@]+"${DUPE_ARGS[@]}"} 2>/dev/null)" || return 1
  _total=0; _hits=0
  while IFS="$(printf '\t')" read -r _f1 _f2 _f3; do
    # Trailer lines, NOT truth rows. DUP/DUPHIT (#1840) and GATE (#1841) belong here for the same reason
    # LEADS/JUDGE do: a DUPHIT line's second field is a sev_id, not HIT/MISS, so counting it would inflate
    # BOTH the denominator and (silently) the recall this DELTA is built from. LOC/LOCHIT (#2215) are the same
    # shape and belong in the same list.
    case "$_f1" in LEADS|JUDGE|GATE|DUP|DUPHIT|LOC|LOCHIT) continue ;; esac
    [ -n "$_f1" ] || continue
    _total=$((_total + 1))
    [ "$_f2" = "HIT" ] && _hits=$((_hits + 1))
  done <<RECALL_EOF
$_sc
RECALL_EOF
  printf '%s %s' "$_hits" "$_total"
}

# ==========================================================================================================
# --self-test (default): the offline, deterministic acceptance bar.
# ==========================================================================================================
if [ "$MODE" = "self-test" ]; then
  FAILS=0
  ok()  { echo "  [PASS] $*"; }
  bad() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

  command -v python3 >/dev/null 2>&1 || { echo "generation-recall.sh: [SKIP] python3 not installed" >&2; exit 0; }
  for f in "$ADAPTER" "$SCOREMATCH"; do
    [ -f "$f" ] || { say "prerequisite missing: $f"; exit 3; }
  done
  for f in discovery-results.merged.json invariant-targets.txt truth.tsv verified_findings.json expected-leads.json expected-scorecard.txt; do
    [ -f "$FIX/$f" ] || { say "fixture missing: $FIX/$f"; exit 3; }
  done

  # (a) the adapter projects the discovery candidates + the INVARIANT| line (verdict ignored) into a union
  #     lead set that BYTE-matches expected-leads.json.
  LEADS="$(python3 "$ADAPTER" --from-discovery "$FIX/discovery-results.merged.json" --from-invariants "$FIX/invariant-targets.txt" 2>/dev/null)"
  if [ "$LEADS" = "$(cat "$FIX/expected-leads.json")" ]; then
    ok "(a) hypotheses-to-leads.py projects discovery + invariant hypotheses byte-matching expected-leads.json"
  else
    bad "(a) adapter output DIFFERS from expected-leads.json"
    diff <(printf '%s\n' "$LEADS") "$FIX/expected-leads.json" >&2 || true
  fi

  # (b) score-match.py over the projected leads byte-matches expected-scorecard.txt AND is IDENTICAL at
  #     --min-overlap 2 and 5 (location-first recall is threshold-independent).
  SC2="$(python3 "$SCOREMATCH" "$FIX/truth.tsv" "$FIX/expected-leads.json" --min-overlap 2 2>/dev/null)"
  SC5="$(python3 "$SCOREMATCH" "$FIX/truth.tsv" "$FIX/expected-leads.json" --min-overlap 5 2>/dev/null)"
  EXPECT="$(cat "$FIX/expected-scorecard.txt")"
  if [ "$SC2" = "$EXPECT" ] && [ "$SC5" = "$EXPECT" ]; then
    ok "(b) score-match.py over the projected leads matches expected-scorecard.txt at --min-overlap 2 and 5"
  else
    bad "(b) generation scorecard DIFFERS from expected-scorecard.txt (or is threshold-dependent)"
    { printf '%s\n' "--- expected ---"; printf '%s\n' "$EXPECT"; printf '%s\n' "--- min-overlap 2 ---"; printf '%s\n' "$SC2"; printf '%s\n' "--- min-overlap 5 ---"; printf '%s\n' "$SC5"; } >&2
  fi

  # (c) generation-recall > verified-recall on the SAME fixture: the CLEAN invariant that NAMED the GT bug
  #     HITs generation, but the fuzzer's DROP leaves verified_findings.json a MISS for that row.
  GEN="$(recall_hits "$FIX/truth.tsv" "$FIX/expected-leads.json")"
  VER="$(recall_hits "$FIX/truth.tsv" "$FIX/verified_findings.json")"
  GEN_HITS="${GEN%% *}"; GEN_TOTAL="${GEN##* }"
  VER_HITS="${VER%% *}"; VER_TOTAL="${VER##* }"
  echo "  generation-recall $GEN_HITS/$GEN_TOTAL vs verified-recall $VER_HITS/$VER_TOTAL (delta = the named-but-unconfirmed GT rows)"
  if [ -n "$GEN_HITS" ] && [ -n "$VER_HITS" ] && [ "$GEN_HITS" -gt "$VER_HITS" ]; then
    ok "(c) generation-recall ($GEN_HITS) > verified-recall ($VER_HITS) — the generation-vs-confirmation delta holds"
  else
    bad "(c) expected generation-recall > verified-recall, got gen=$GEN_HITS ver=$VER_HITS"
  fi

  # (d) #2215: the LOC/LOCHIT trailers must NOT be counted as truth rows. They share the DUPHIT shape (second
  #     field is a sev_id, not HIT/MISS), so a reader that forgot to skip them would inflate the denominator
  #     AND silently re-attribute recall. Scored over fixtures/score-locations/, whose expected scorecard
  #     carries both trailers: the only correct answer is 2 hits out of 4 truth rows.
  L_FIX="$HERE/fixtures/score-locations"
  if [ -f "$L_FIX/truth.tsv" ] && [ -f "$L_FIX/verified_findings.json" ]; then
    LOC_RC="$(recall_hits "$L_FIX/truth.tsv" "$L_FIX/verified_findings.json")"
    if [ "$LOC_RC" = "2 4" ]; then
      ok "(d) recall_hits skips the #2215 LOC/LOCHIT trailers (2/4, not inflated by the 2 trailer lines)"
    else
      bad "(d) recall_hits over fixtures/score-locations/ returned '$LOC_RC', expected '2 4' — a LOC/LOCHIT trailer is being counted as a truth row"
    fi
  else
    bad "(d) fixture missing: $L_FIX/{truth.tsv,verified_findings.json}"
  fi

  # (e) #2231: the hold-out lookup this harness labels every headline with. A `dev` id must resolve to `dev`
  #     (its number is IN-DISTRIBUTION), a `holdout` id to `holdout`, and an id absent from the manifest to `?`
  #     — never silently to a clean-looking role.
  R_DEV="$(corpus_role notional)"; R_HOLD="$(corpus_role mellow)"; R_UNK="$(corpus_role not-a-contest)"
  if [ "$R_DEV" = "dev" ] && [ "$R_HOLD" = "holdout" ] && [ "$R_UNK" = "?" ]; then
    ok "(e) corpus_role resolves dev / holdout / unknown from corpus.tsv column 5 (#2231 hold-out policy)"
  else
    bad "(e) corpus_role returned dev='$R_DEV' holdout='$R_HOLD' unknown='$R_UNK' (expected dev/holdout/?)"
  fi

  # (f) #2217 PR B: the tier-2 projection and the DUAL-scoring rule that keeps it out of the headline. Three
  #     things must hold at once, and the first is the load-bearing one: an input that CARRIES tier-2 records
  #     must project byte-identically to the pre-#2217 lead set unless the flag is passed, so the primary
  #     number can never absorb a tier-2 hit by accident. Then the flag adds exactly one lead flagged
  #     `"tier": 2`, and over a truth file with one GT row that ONLY the tier-2 record names, the primary
  #     stays 2/3 while the tier-2 delta is +1 — at --min-overlap 2 AND 5, because a tier-2 lead carries a
  #     function and is therefore scored by the same threshold-independent location rule as a tier-1 lead.
  T2_DISC="$FIX/discovery-results.tier2.json"
  T2_TRUTH="$FIX/truth.tier2.tsv"
  T2_LEADS="$FIX/expected-leads.tier2.json"
  if [ -f "$T2_DISC" ] && [ -f "$T2_TRUTH" ] && [ -f "$T2_LEADS" ]; then
    T2_OFF="$(python3 "$ADAPTER" --from-discovery "$T2_DISC" --from-invariants "$FIX/invariant-targets.txt" 2>/dev/null)"
    if [ "$T2_OFF" = "$(cat "$FIX/expected-leads.json")" ]; then
      ok "(f1) a top-level tier2[] CANNOT leak into the default lead set (no --include-tier2 => byte-identical to expected-leads.json)"
    else
      bad "(f1) the DEFAULT projection of discovery-results.tier2.json DIFFERS from expected-leads.json — the primary lead set is contaminated"
      diff <(printf '%s\n' "$T2_OFF") "$FIX/expected-leads.json" >&2 || true
    fi

    T2_ON="$(python3 "$ADAPTER" --from-discovery "$T2_DISC" --from-invariants "$FIX/invariant-targets.txt" --include-tier2 2>/dev/null)"
    T2_N="$(printf '%s\n' "$T2_ON" | grep -c '"tier": 2' || true)"
    if [ "$T2_ON" = "$(cat "$T2_LEADS")" ] && [ "$T2_N" = "1" ]; then
      ok "(f2) --include-tier2 adds exactly ONE lead flagged \"tier\": 2, byte-matching expected-leads.tier2.json"
    else
      bad "(f2) the --include-tier2 projection DIFFERS from expected-leads.tier2.json (tier-2 leads found: $T2_N, expected 1)"
      diff <(printf '%s\n' "$T2_ON") "$T2_LEADS" >&2 || true
    fi

    T2_SAVED_MINOV="$MINOV"
    T2_F3=1 ; T2_SEEN=""
    for _mo in 2 5; do
      MINOV="$_mo"
      _p="$(recall_hits "$T2_TRUTH" "$FIX/expected-leads.json")" || _p=""
      _u="$(recall_hits "$T2_TRUTH" "$T2_LEADS")" || _u=""
      T2_SEEN="$T2_SEEN [min-overlap $_mo: primary '$_p', union '$_u']"
      { [ "$_p" = "2 3" ] && [ "$_u" = "3 3" ]; } || T2_F3=0
    done
    MINOV="$T2_SAVED_MINOV"
    echo "  primary generation-recall 2/3 (no tier-2 lead in the scored set), tier-2 (SECONDARY) +1 GT row credited only with --include-tier2"
    if [ "$T2_F3" -eq 1 ]; then
      ok "(f3) the tier-2 record credits the GT row the tier-1 leads MISS (tier2_hits = 3-2 = 1) while the primary stays 2/3, at --min-overlap 2 and 5"
    else
      bad "(f3) tier-2 dual scoring regressed — expected primary '2 3' and union '3 3' at both thresholds, got$T2_SEEN"
    fi
  else
    bad "(f) fixture missing: $FIX/{discovery-results.tier2.json,truth.tier2.tsv,expected-leads.tier2.json}"
  fi

  echo
  if [ "$FAILS" -eq 0 ]; then
    say "PASS — the generation-recall adapter projects breadth candidates + verdict-ignored invariant targets"
    say "       into leads the FROZEN score-match.py scores; generation-recall exceeds verified-recall on the"
    say "       fixture because a CLEAN invariant that NAMED the GT bug is a generation HIT the fuzzer dropped."
    exit 0
  fi
  say "FAIL — $FAILS generation-recall self-test assertion(s) regressed"
  exit 1
fi

# ==========================================================================================================
# --from-work: score the GENERATION artifacts of an already-fetched/hunted corpus-bench work dir.
# ==========================================================================================================
if [ "$MODE" = "from-work" ]; then
  command -v python3 >/dev/null 2>&1 || { echo "generation-recall.sh: python3 not installed (scoring needs it)" >&2; exit 3; }
  [ -d "$WORK" ] || { echo "generation-recall.sh: --from-work dir not found: $WORK" >&2; exit 3; }
  WORK="$(cd "$WORK" && pwd)"

  # Contest ids: the explicit --id list, else every immediate subdir carrying a truth.tsv.
  SEL_IDS=""
  if [ -n "$IDS" ]; then
    SEL_IDS="$IDS"
  else
    for d in "$WORK"/*/; do
      [ -d "$d" ] || continue
      _id="$(basename "$d")"
      [ -f "$WORK/$_id/truth.tsv" ] && SEL_IDS="$SEL_IDS $_id"
    done
  fi
  [ -n "$SEL_IDS" ] || { say "no contest with a truth.tsv under $WORK (run corpus-bench --fetch --gt --hunt first)"; exit 3; }

  declare -a CONTEST_JSON=()
  G_TOTAL=0 ; G_HITS=0
  G_H_TOTAL=0 ; G_H_HITS=0 ; G_M_TOTAL=0 ; G_M_HITS=0
  G_RARE_TOTAL=0 ; G_RARE_HITS=0 ; G_MID_TOTAL=0 ; G_MID_HITS=0 ; G_CONS_TOTAL=0 ; G_CONS_HITS=0
  G_RARE_REACHABLE=0 ; G_LOC_CREDITED=0
  G_VER_TOTAL=0 ; G_VER_HITS=0 ; ANY_VERIFIED=0
  # #2217 PR B: the SECONDARY tier-2 totals. Kept in their own accumulators (never added to G_HITS) so the
  # aggregate below cannot print a headline that quietly includes them. The caveat is printed ONCE per run.
  G_T2_HITS=0 ; G_T2_LEADS=0 ; T2_CAVEAT_DONE=0

  for id in $SEL_IDS; do
    truth="$WORK/$id/truth.tsv"
    [ -f "$truth" ] || { say "SCORE: [$id] no truth.tsv (run --gt first); skipping"; continue; }
    disc="$WORK/$id/zone-hunt-out/discovery/discovery-results.merged.json"
    inv_glob="$WORK/$id/zone-hunt-out/deep-hunt/*/run/invariant_*.log"

    # Assemble adapter args from the artifacts that ACTUALLY exist — a missing artifact is a logged skip.
    declare -a ADP=()
    [ -f "$disc" ] && ADP+=(--from-discovery "$disc")
    # A glob matching nothing must not become a false 0: only pass --from-invariants when a log exists.
    _inv_first=""
    for _g in $inv_glob; do [ -f "$_g" ] && { _inv_first="$_g"; break; }; done
    [ -n "$_inv_first" ] && ADP+=(--from-invariants "$inv_glob")
    if [ "${#ADP[@]}" -eq 0 ]; then
      say "SCORE: [$id] no generation artifact (discovery-results.merged.json / deep-hunt invariant logs); skipping"
      continue
    fi

    leads="$WORK/$id/generation-leads.json"
    if ! python3 "$ADAPTER" "${ADP[@]}" > "$leads" 2>/dev/null; then
      say "SCORE: [$id] hypotheses-to-leads.py failed; skipping"; continue
    fi
    say "SCORE: [$id] scoring the union of generation hypotheses against truth.tsv ..."

    SCORE_OUT="$(python3 "$SCOREMATCH" "$truth" "$leads" --min-overlap "$MINOV" "${JUDGE_ARGS[@]}" \
                   ${DUPE_ARGS[@]+"${DUPE_ARGS[@]}"} 2>/dev/null)" \
      || { say "SCORE: [$id] score-match.py failed; skipping"; continue; }

    declare -A HITMAP=()
    judge_calls=0 ; judge_errors=0 ; dup_classes=0 ; dup_expanded=0 ; loc_rows=0 ; loc_credited=0
    gate_conf="$JUDGE_MINCONF" ; gate_dropped=0 ; gate_rows=0
    # A GATE trailer carries FOUR fields, so the reader takes f4 too; every other line leaves it empty.
    while IFS="$(printf '\t')" read -r f1 f2 f3 f4; do
      [ "$f1" = "LEADS" ] && continue
      if [ "$f1" = "JUDGE" ]; then judge_calls="$f2"; judge_errors="$f3"; continue; fi
      # #1841 trailer: the confidence gate in force and what it cost. A trailer, never a truth row.
      if [ "$f1" = "GATE" ]; then gate_conf="$f2"; gate_dropped="$f3"; gate_rows="$f4"; continue; fi
      # #1840 trailers: DUP carries counts and DUPHIT an attribution pair — neither is a truth row, and a
      # DUPHIT's second field is a sev_id rather than HIT/MISS, so both must be skipped before HITMAP.
      if [ "$f1" = "DUP" ]; then dup_classes="$f2"; dup_expanded="$f3"; continue; fi
      [ "$f1" = "DUPHIT" ] && continue
      # #2215 trailers: LOC carries the anchored-row / location-credited counts, LOCHIT attributes one
      # location-credited row to the lead location that credited it. Trailers, never truth rows.
      if [ "$f1" = "LOC" ]; then loc_rows="$f2"; loc_credited="$f3"; continue; fi
      [ "$f1" = "LOCHIT" ] && continue
      [ -n "$f1" ] && HITMAP["$f1"]="$f2"
    done <<SCORE_EOF
$SCORE_OUT
SCORE_EOF

    c_total=0 ; c_hits=0
    c_h_total=0 ; c_h_hits=0 ; c_m_total=0 ; c_m_hits=0
    c_rare_total=0 ; c_rare_hits=0 ; c_mid_total=0 ; c_mid_hits=0 ; c_cons_total=0 ; c_cons_hits=0
    c_rare_reachable=0

    # #2215 REACHABLE RARE. A rare row the matcher can never resolve is a denominator the pipeline cannot move,
    # so a headline that does not state it invites reading a matcher bound as a capability bound. With a
    # 6-column truth.tsv (extract-gt.sh --code) "reachable" = the row carries a resolved `<file>:<function>`
    # anchor. With a legacy 5-column one there is no anchor to check, so it degrades to the weaker
    # "signature names at least one `.sol` basename" test and SAYS SO in the printed line.
    loc_col=0
    while IFS="$(printf '\t')" read -r _l1 _l2 _l3 _l4 _l5 _l6; do
      [ -n "${_l6:-}" ] && { loc_col=1; break; }
    done < "$truth"

    while IFS="$(printf '\t')" read -r sev_id severity rarity title _signature locations; do
      [ -n "${sev_id:-}" ] || continue
      c_total=$((c_total + 1))
      reachable=0
      if [ "$loc_col" = 1 ]; then
        [ -n "${locations:-}" ] && reachable=1
      else
        case "$_signature" in *.sol*) reachable=1 ;; esac
      fi
      hit=0; [ "${HITMAP[$sev_id]:-MISS}" = "HIT" ] && hit=1
      [ "$hit" = 1 ] && c_hits=$((c_hits + 1))
      case "$severity" in
        High)   c_h_total=$((c_h_total + 1)); [ "$hit" = 1 ] && c_h_hits=$((c_h_hits + 1)) ;;
        Medium) c_m_total=$((c_m_total + 1)); [ "$hit" = 1 ] && c_m_hits=$((c_m_hits + 1)) ;;
      esac
      if   [ "$rarity" -le 2 ] 2>/dev/null; then c_rare_total=$((c_rare_total + 1)); [ "$hit" = 1 ] && c_rare_hits=$((c_rare_hits + 1)); [ "$reachable" = 1 ] && c_rare_reachable=$((c_rare_reachable + 1))
      elif [ "$rarity" -le 8 ] 2>/dev/null; then c_mid_total=$((c_mid_total + 1));  [ "$hit" = 1 ] && c_mid_hits=$((c_mid_hits + 1))
      else                                       c_cons_total=$((c_cons_total + 1)); [ "$hit" = 1 ] && c_cons_hits=$((c_cons_hits + 1))
      fi
      say "  [$id] $([ "$hit" = 1 ] && echo HIT || echo MISS) $sev_id (rarity $rarity): $title"
    done < "$truth"

    role="$(corpus_role "$id")"
    role_note="role=$role"
    [ "$role" = "dev" ] && role_note="role=dev, IN-DISTRIBUTION (lens designed on this contest, #2231)"
    say "  [$id] [$role_note] generation-recall $c_hits/$c_total, High $c_h_hits/$c_h_total, Medium $c_m_hits/$c_m_total, rare $c_rare_hits/$c_rare_total, mid $c_mid_hits/$c_mid_total, consensus $c_cons_hits/$c_cons_total"
    reach_note=""; [ "$loc_col" = 0 ] && reach_note=" (legacy: basename-in-signature)"
    say "  [$id] reachable rare = $c_rare_reachable/$c_rare_total$reach_note — rare rows this matcher can resolve at all; the headline above is bounded by it, not only by the hunter"
    [ "$loc_col" = 1 ] && say "  [$id] GT location anchors (#2215): $loc_rows anchored row(s), $loc_credited row(s) credited ONLY via a location pair (generation-recall without them: $((c_hits - loc_credited))/$c_total)"
    [ "$JUDGE" != "off" ] && say "  [$id] scored by the SEMANTIC MECHANISM JUDGE (--judge $JUDGE, min-confidence $gate_conf, #1829): $judge_calls judging calls, $judge_errors JUDGE-ERROR(s); gate dropped $gate_dropped MATCH decision(s), costing $gate_rows row(s) (#1841)"
    [ -n "$GT_DUPES" ] && say "  [$id] GT-equivalence crediting (#1840) from $GT_DUPES: $dup_classes class(es), $dup_expanded row(s) credited through a class (generation-recall without them: $((c_hits - dup_expanded))/$c_total)"

    # #2217 PR B — the SECONDARY tier-2 number. Everything above was scored from `$leads`, which the adapter
    # emitted WITHOUT --include-tier2 and therefore contains no tier-2 lead at all: the primary number is
    # protected by construction, not by arithmetic. The tier-2 contribution is the DELTA between the same
    # ruler applied to the union and to that primary set — both measured through recall_hits, so --min-overlap,
    # --judge and --gt-dupes are identical on both sides and the subtraction is apples-to-apples.
    t2_hits=0 ; t2_leads=0
    if [ -f "$disc" ] && grep -q '"tier2"' "$disc" 2>/dev/null; then
      leads_t2="$WORK/$id/generation-leads.tier2.json"
      if python3 "$ADAPTER" "${ADP[@]}" --include-tier2 > "$leads_t2" 2>/dev/null; then
        # The adapter's output is json.dumps(indent=2, sort_keys=True), so a projected tier-2 lead is exactly
        # one `"tier": 2` line — counting them needs no second JSON parse.
        t2_leads="$(grep -c '"tier": 2' "$leads_t2" 2>/dev/null || true)"
        case "$t2_leads" in ''|*[!0-9]*) t2_leads=0 ;; esac
        _u="$(recall_hits "$truth" "$leads_t2")" || _u=""
        _p="$(recall_hits "$truth" "$leads")" || _p=""
        if [ -n "$_u" ] && [ -n "$_p" ]; then
          t2_hits=$(( ${_u%% *} - ${_p%% *} ))
          [ "$t2_hits" -ge 0 ] || t2_hits=0
        fi
      else
        say "  [$id] hypotheses-to-leads.py --include-tier2 failed; tier-2 reported as 0 (the primary number above is unaffected)"
      fi
    fi
    if [ "$t2_leads" -gt 0 ]; then
      say "  [$id] tier-2 (SECONDARY, #2217): +$t2_hits GT row(s) credited ONLY by a tier-2 lead ($t2_leads projected) — NOT part of the $c_hits/$c_total above, which is scored from a lead set containing no tier-2 lead"
      if [ "$T2_CAVEAT_DONE" -eq 0 ]; then
        say "  tier-2 CAVEAT: a tier-2 location is a NAME derived by regex from an unsettled check's text, not a finding the model asserted — mechanism-blind at a higher rate than a tier-1 candidate. A 'we found it' claim is still an operator read of the cell log (#2214 scoring discipline)."
        T2_CAVEAT_DONE=1
      fi
    fi

    # GENERATION-minus-VERIFIED DELTA — GT rows a hypothesis NAMED but the fuzzer/refuter never confirmed.
    verified_json="$WORK/$id/zone-hunt-out/verify/verified_findings.json"
    v_hits="" ; v_total=""
    if [ -f "$verified_json" ]; then
      VR="$(recall_hits "$truth" "$verified_json")" || VR=""
      if [ -n "$VR" ]; then
        v_hits="${VR%% *}"; v_total="${VR##* }"
        say "  [$id] verified-recall $v_hits/$v_total; generation-minus-verified DELTA $((c_hits - v_hits)) (GT rows NAMED by a hypothesis but not confirmed by the fuzzer/refuter)"
        G_VER_TOTAL=$((G_VER_TOTAL + v_total)); G_VER_HITS=$((G_VER_HITS + v_hits)); ANY_VERIFIED=1
      fi
    else
      say "  [$id] no verify/verified_findings.json — generation-only (no DELTA)"
    fi

    CONTEST_JSON+=("{\"id\":\"$id\",\"role\":\"$role\",\"gt_total\":$c_total,\"generation_hits\":$c_hits,\"high\":{\"total\":$c_h_total,\"hits\":$c_h_hits},\"medium\":{\"total\":$c_m_total,\"hits\":$c_m_hits},\"rare\":{\"total\":$c_rare_total,\"hits\":$c_rare_hits},\"mid\":{\"total\":$c_mid_total,\"hits\":$c_mid_hits},\"consensus\":{\"total\":$c_cons_total,\"hits\":$c_cons_hits},\"rare_reachable\":$c_rare_reachable,\"location_credited\":$loc_credited,\"tier2_hits\":$t2_hits,\"tier2_leads\":$t2_leads,\"verified_hits\":${v_hits:-null}}")

    G_TOTAL=$((G_TOTAL + c_total)); G_HITS=$((G_HITS + c_hits))
    G_H_TOTAL=$((G_H_TOTAL + c_h_total)); G_H_HITS=$((G_H_HITS + c_h_hits))
    G_M_TOTAL=$((G_M_TOTAL + c_m_total)); G_M_HITS=$((G_M_HITS + c_m_hits))
    G_RARE_TOTAL=$((G_RARE_TOTAL + c_rare_total)); G_RARE_HITS=$((G_RARE_HITS + c_rare_hits))
    G_MID_TOTAL=$((G_MID_TOTAL + c_mid_total)); G_MID_HITS=$((G_MID_HITS + c_mid_hits))
    G_CONS_TOTAL=$((G_CONS_TOTAL + c_cons_total)); G_CONS_HITS=$((G_CONS_HITS + c_cons_hits))
    G_RARE_REACHABLE=$((G_RARE_REACHABLE + c_rare_reachable)); G_LOC_CREDITED=$((G_LOC_CREDITED + loc_credited))
    G_T2_HITS=$((G_T2_HITS + t2_hits)); G_T2_LEADS=$((G_T2_LEADS + t2_leads))
  done

  say ""
  say "================ GENERATION-RECALL AGGREGATE ================"
  say "overall generation-recall: $G_HITS/$G_TOTAL"
  say "by severity              : High $G_H_HITS/$G_H_TOTAL, Medium $G_M_HITS/$G_M_TOTAL"
  say "by rarity                : rare(1-2) $G_RARE_HITS/$G_RARE_TOTAL, mid(3-8) $G_MID_HITS/$G_MID_TOTAL, consensus(9+) $G_CONS_HITS/$G_CONS_TOTAL"
  say "hold-out                 : a role=dev contest above is IN-DISTRIBUTION (#2231) — the lenses were designed on its ground truth; recall CLAIMS belong to the role=holdout rows of corpus.tsv"
  say "reachable rare           : $G_RARE_REACHABLE/$G_RARE_TOTAL (#2215; rows carrying a resolvable location anchor — the ceiling this matcher can reach)"
  say "location-credited rows   : $G_LOC_CREDITED (credited ONLY by a GT location pair; the same replay without them reads $((G_HITS - G_LOC_CREDITED))/$G_TOTAL)"
  say "tier-2 (SECONDARY, #2217): +$G_T2_HITS GT row(s) credited only when tier-2 leads are added ($G_T2_LEADS projected) — NEVER folded into the overall/severity/rarity numbers above, which are scored from lead sets containing no tier-2 lead"
  if [ "$ANY_VERIFIED" -eq 1 ]; then
    say "generation-minus-verified: generation $G_HITS/$G_TOTAL vs verified $G_VER_HITS/$G_VER_TOTAL, DELTA $((G_HITS - G_VER_HITS)) (NAMED but unconfirmed — the #1716 expressiveness gap)"
  fi

  if [ "$JSON" -eq 1 ]; then
    joined="$(IFS=,; echo "${CONTEST_JSON[*]:-}")"
    printf '{"contests":[%s],"aggregate":{"gt_total":%d,"generation_hits":%d,"high":{"total":%d,"hits":%d},"medium":{"total":%d,"hits":%d},"rare":{"total":%d,"hits":%d},"mid":{"total":%d,"hits":%d},"consensus":{"total":%d,"hits":%d},"rare_reachable":%d,"location_credited":%d,"tier2_hits":%d,"tier2_leads":%d,"verified_hits":%d,"verified_total":%d}}\n' \
      "$joined" "$G_TOTAL" "$G_HITS" "$G_H_TOTAL" "$G_H_HITS" "$G_M_TOTAL" "$G_M_HITS" \
      "$G_RARE_TOTAL" "$G_RARE_HITS" "$G_MID_TOTAL" "$G_MID_HITS" "$G_CONS_TOTAL" "$G_CONS_HITS" \
      "$G_RARE_REACHABLE" "$G_LOC_CREDITED" "$G_T2_HITS" "$G_T2_LEADS" "$G_VER_HITS" "$G_VER_TOTAL"
  fi
  exit 0
fi

echo "generation-recall.sh: unknown mode: $MODE" >&2
exit 2
