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
# run-corpus-bench.sh; the rare tier is the headline capability number. When a contest also has a
# verify/verified_findings.json, the GENERATION-minus-VERIFIED DELTA (GT rows a hypothesis NAMED but the
# fuzzer/refuter then failed to confirm — the #1716 expressiveness gap, made measurable) is printed too.
#
# MODES:
#   --self-test (default; CI-safe, no network/LLM/forge): run the adapter over fixtures/generation-recall/
#     and assert (a) the projected union byte-matches expected-leads.json; (b) score-match.py over it
#     byte-matches expected-scorecard.txt AND is IDENTICAL at --min-overlap 2 and 5 (threshold-independent);
#     (c) generation-recall > verified-recall on the SAME fixture — the CLEAN invariant that named the GT bug
#     HITs generation but the fuzzer's DROP leaves verified a MISS (the generation-vs-confirmation delta).
#   --from-work <dir> [--id <id>]... [--min-overlap N] [--json]: read an already-fetched/hunted corpus-bench
#     work dir and, per contest, project <id>/zone-hunt-out/discovery/discovery-results.merged.json +
#     <id>/zone-hunt-out/deep-hunt/*/run/invariant_*.log through the adapter, score the union against
#     <id>/truth.tsv, and report per-bug HIT/MISS + the stratified aggregate (+ the DELTA when
#     verify/verified_findings.json is present). A missing artifact is a logged skip, NEVER a false 0.
#
# Usage: generation-recall.sh [--self-test] | [--from-work <dir> [--id <id>]... [--min-overlap N] [--json]
#                             [--judge <off|cache|cmd>] [--judge-cmd <p>] [--judge-cache <f>] [--judge-log <f>]
#                             [--judge-batch N] [--judge-min-confidence N] [--gt-dupes <f>]
#                             [--gt-dupes-min-confidence N]] [-h]
#   --judge* : #1829 — forwarded verbatim to score-match.py for BOTH the generation scorecard and the
#              verified-recall side of the DELTA, so the two halves are always measured with the SAME ruler.
#              Default `off` = the frozen #1697 token matcher; `--self-test` is always judge-off.
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

MODE="self-test"
WORK="" ; IDS="" ; MINOV="2" ; JSON=0
JUDGE="off" ; JUDGE_CMD="" ; JUDGE_CACHE="" ; JUDGE_LOG="" ; JUDGE_BATCH="" ; JUDGE_MINCONF=""
GT_DUPES="" ; GT_DUPES_MINCONF=""

nv() { [ "$1" -ge 2 ] || { echo "generation-recall.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do case "$1" in
  --self-test)   MODE="self-test"; shift ;;
  --from-work)   nv "$#"; MODE="from-work"; WORK="$2"; shift 2 ;;
  --id)          nv "$#"; IDS="$IDS $2"; shift 2 ;;
  --min-overlap) nv "$#"; MINOV="$2"; shift 2 ;;
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
  [ -n "$JUDGE_MINCONF" ] && JUDGE_ARGS+=(--judge-min-confidence "$JUDGE_MINCONF")
fi

# #1840: the GT-equivalence flags, forwarded to BOTH halves of the DELTA so one ruler measures both. The array
# is EMPTY by default, hence the `${arr[@]+...}` guard at every expansion (an unguarded empty expansion trips
# `set -u` on older bash).
declare -a DUPE_ARGS=()
if [ -n "$GT_DUPES" ]; then
  DUPE_ARGS+=(--gt-dupes "$GT_DUPES")
  [ -n "$GT_DUPES_MINCONF" ] && DUPE_ARGS+=(--gt-dupes-min-confidence "$GT_DUPES_MINCONF")
fi

# recall_hits <truth.tsv> <leads.json> — print "<hits> <total>" (HIT truth rows / total truth rows) from
# score-match.py at --min-overlap "$MINOV" (and the selected --judge / --gt-dupes mode). Empty on failure.
recall_hits() {
  _t="$1"; _j="$2"
  _sc="$(python3 "$SCOREMATCH" "$_t" "$_j" --min-overlap "$MINOV" "${JUDGE_ARGS[@]}" \
           ${DUPE_ARGS[@]+"${DUPE_ARGS[@]}"} 2>/dev/null)" || return 1
  _total=0; _hits=0
  while IFS="$(printf '\t')" read -r _f1 _f2 _f3; do
    # Trailer lines, NOT truth rows. DUP/DUPHIT (#1840) belong here for the same reason LEADS/JUDGE do: a
    # DUPHIT line's second field is a sev_id, not HIT/MISS, so counting it would inflate BOTH the denominator
    # and (silently) the recall this DELTA is built from.
    case "$_f1" in LEADS|JUDGE|DUP|DUPHIT) continue ;; esac
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
  G_VER_TOTAL=0 ; G_VER_HITS=0 ; ANY_VERIFIED=0

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
    judge_calls=0 ; judge_errors=0 ; dup_classes=0 ; dup_expanded=0
    while IFS="$(printf '\t')" read -r f1 f2 f3; do
      [ "$f1" = "LEADS" ] && continue
      if [ "$f1" = "JUDGE" ]; then judge_calls="$f2"; judge_errors="$f3"; continue; fi
      # #1840 trailers: DUP carries counts and DUPHIT an attribution pair — neither is a truth row, and a
      # DUPHIT's second field is a sev_id rather than HIT/MISS, so both must be skipped before HITMAP.
      if [ "$f1" = "DUP" ]; then dup_classes="$f2"; dup_expanded="$f3"; continue; fi
      [ "$f1" = "DUPHIT" ] && continue
      [ -n "$f1" ] && HITMAP["$f1"]="$f2"
    done <<SCORE_EOF
$SCORE_OUT
SCORE_EOF

    c_total=0 ; c_hits=0
    c_h_total=0 ; c_h_hits=0 ; c_m_total=0 ; c_m_hits=0
    c_rare_total=0 ; c_rare_hits=0 ; c_mid_total=0 ; c_mid_hits=0 ; c_cons_total=0 ; c_cons_hits=0
    while IFS="$(printf '\t')" read -r sev_id severity rarity title _signature; do
      [ -n "${sev_id:-}" ] || continue
      c_total=$((c_total + 1))
      hit=0; [ "${HITMAP[$sev_id]:-MISS}" = "HIT" ] && hit=1
      [ "$hit" = 1 ] && c_hits=$((c_hits + 1))
      case "$severity" in
        High)   c_h_total=$((c_h_total + 1)); [ "$hit" = 1 ] && c_h_hits=$((c_h_hits + 1)) ;;
        Medium) c_m_total=$((c_m_total + 1)); [ "$hit" = 1 ] && c_m_hits=$((c_m_hits + 1)) ;;
      esac
      if   [ "$rarity" -le 2 ] 2>/dev/null; then c_rare_total=$((c_rare_total + 1)); [ "$hit" = 1 ] && c_rare_hits=$((c_rare_hits + 1))
      elif [ "$rarity" -le 8 ] 2>/dev/null; then c_mid_total=$((c_mid_total + 1));  [ "$hit" = 1 ] && c_mid_hits=$((c_mid_hits + 1))
      else                                       c_cons_total=$((c_cons_total + 1)); [ "$hit" = 1 ] && c_cons_hits=$((c_cons_hits + 1))
      fi
      say "  [$id] $([ "$hit" = 1 ] && echo HIT || echo MISS) $sev_id (rarity $rarity): $title"
    done < "$truth"

    say "  [$id] generation-recall $c_hits/$c_total, High $c_h_hits/$c_h_total, Medium $c_m_hits/$c_m_total, rare $c_rare_hits/$c_rare_total, mid $c_mid_hits/$c_mid_total, consensus $c_cons_hits/$c_cons_total"
    [ "$JUDGE" != "off" ] && say "  [$id] scored by the SEMANTIC MECHANISM JUDGE (--judge $JUDGE, #1829): $judge_calls judging calls, $judge_errors JUDGE-ERROR(s)"
    [ -n "$GT_DUPES" ] && say "  [$id] GT-equivalence crediting (#1840) from $GT_DUPES: $dup_classes class(es), $dup_expanded row(s) credited through a class (generation-recall without them: $((c_hits - dup_expanded))/$c_total)"

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

    CONTEST_JSON+=("{\"id\":\"$id\",\"gt_total\":$c_total,\"generation_hits\":$c_hits,\"high\":{\"total\":$c_h_total,\"hits\":$c_h_hits},\"medium\":{\"total\":$c_m_total,\"hits\":$c_m_hits},\"rare\":{\"total\":$c_rare_total,\"hits\":$c_rare_hits},\"mid\":{\"total\":$c_mid_total,\"hits\":$c_mid_hits},\"consensus\":{\"total\":$c_cons_total,\"hits\":$c_cons_hits},\"verified_hits\":${v_hits:-null}}")

    G_TOTAL=$((G_TOTAL + c_total)); G_HITS=$((G_HITS + c_hits))
    G_H_TOTAL=$((G_H_TOTAL + c_h_total)); G_H_HITS=$((G_H_HITS + c_h_hits))
    G_M_TOTAL=$((G_M_TOTAL + c_m_total)); G_M_HITS=$((G_M_HITS + c_m_hits))
    G_RARE_TOTAL=$((G_RARE_TOTAL + c_rare_total)); G_RARE_HITS=$((G_RARE_HITS + c_rare_hits))
    G_MID_TOTAL=$((G_MID_TOTAL + c_mid_total)); G_MID_HITS=$((G_MID_HITS + c_mid_hits))
    G_CONS_TOTAL=$((G_CONS_TOTAL + c_cons_total)); G_CONS_HITS=$((G_CONS_HITS + c_cons_hits))
  done

  say ""
  say "================ GENERATION-RECALL AGGREGATE ================"
  say "overall generation-recall: $G_HITS/$G_TOTAL"
  say "by severity              : High $G_H_HITS/$G_H_TOTAL, Medium $G_M_HITS/$G_M_TOTAL"
  say "by rarity                : rare(1-2) $G_RARE_HITS/$G_RARE_TOTAL, mid(3-8) $G_MID_HITS/$G_MID_TOTAL, consensus(9+) $G_CONS_HITS/$G_CONS_TOTAL"
  if [ "$ANY_VERIFIED" -eq 1 ]; then
    say "generation-minus-verified: generation $G_HITS/$G_TOTAL vs verified $G_VER_HITS/$G_VER_TOTAL, DELTA $((G_HITS - G_VER_HITS)) (NAMED but unconfirmed — the #1716 expressiveness gap)"
  fi

  if [ "$JSON" -eq 1 ]; then
    joined="$(IFS=,; echo "${CONTEST_JSON[*]:-}")"
    printf '{"contests":[%s],"aggregate":{"gt_total":%d,"generation_hits":%d,"high":{"total":%d,"hits":%d},"medium":{"total":%d,"hits":%d},"rare":{"total":%d,"hits":%d},"mid":{"total":%d,"hits":%d},"consensus":{"total":%d,"hits":%d},"verified_hits":%d,"verified_total":%d}}\n' \
      "$joined" "$G_TOTAL" "$G_HITS" "$G_H_TOTAL" "$G_H_HITS" "$G_M_TOTAL" "$G_M_HITS" \
      "$G_RARE_TOTAL" "$G_RARE_HITS" "$G_MID_TOTAL" "$G_MID_HITS" "$G_CONS_TOTAL" "$G_CONS_HITS" \
      "$G_VER_HITS" "$G_VER_TOTAL"
  fi
  exit 0
fi

echo "generation-recall.sh: unknown mode: $MODE" >&2
exit 2
