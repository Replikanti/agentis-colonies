#!/usr/bin/env bash
# run-corpus-bench.sh — the dark-factory CORPUS bench. Sibling of ../run-capability-bench.sh (#1490, single
# synthetic fixture): this one calibrates against REAL concluded contests instead of a planted bug, the same
# question the session-only "hunt-bench" calibration answered (2026-07-11, never persisted) — does the pipeline
# recall what an elite crowd of watsons already found, and does it hold up on the RARE bugs that separate an
# elite hunter from the crowd, not just the easy consensus ones everybody catches?
#
# Unlike run-capability-bench.sh (one fixture, a planted residual bug, offline STAGE1/live STAGE2), this bench:
#   1. pulls GROUND TRUTH from real Sherlock judging-repo reports (extract-gt.sh; rarity = watson "Found by"
#      count per finding — 1-2 rare, 3-8 mid, 9+ consensus),
#   2. runs the REAL end-to-end federation pipeline (run-zone-hunt.sh: map -> brief -> discover -> verify) over
#      the real contest CODE repo through a real LLM backend,
#   3. scores the pipeline's verified findings against ground truth via the SAME overlap oracle
#      (novelty-gate.sh) run-capability-bench.sh already uses, stratified by severity + rarity.
#
# Corpus is a manifest (corpus.tsv), not re-hosted code or findings — see corpus.tsv + README.md.
#
# Usage: run-corpus-bench.sh [--self-test] [--fetch] [--gt] [--hunt] [--score] [--live]
#                            [--id <id>]... [--work <dir>] [--corpus <file>] [--backend <mock|flat-cyborg|claude>]
#                            [--jobs <N>] [--min-overlap <N>] [--agentis <bin>] [--json] [-h]
#   (no action flag)  same as --self-test.
#   --self-test       Deterministic, CI-safe, no network/LLM: extract-gt.sh over fixtures/sample-judging-readme.md
#                     must byte-match fixtures/expected-truth.tsv. This is the safety property that gates CI,
#                     exactly like run-capability-bench.sh's STAGE 1.
#   --fetch           Clone code+judging repos for the selected --id(s) (default: every corpus.tsv row).
#   --gt              (Re)build truth.tsv per selected contest from its cloned judging repo.
#   --hunt            Run the REAL federation (run-zone-hunt.sh) over each selected contest's cloned code.
#                     Needs `agentis` + a real backend; never run on CI.
#   --score           Score each contest's verified_findings.json against its truth.tsv; print the scorecard.
#   --live            Shorthand for --fetch --gt --hunt --score (the full real-backend measurement).
#   --id <id>         Restrict to one corpus.tsv row (repeatable). Default: every row.
#   --work <dir>      Work dir for clones + run-zone-hunt.sh output (default: ./corpus-bench-work).
#   --corpus <file>   corpus.tsv (default: corpus.tsv next to this script).
#   --backend <b>     LLM backend for --hunt (default: flat-cyborg, the federation default; see ../../CLAUDE.md).
#   --jobs <N>        run-zone-hunt.sh intra-zone concurrency (default 1).
#   --min-overlap <N> novelty-gate.sh overlap threshold for scoring (default 2, same default as the capability bench).
#   --agentis <bin>   agentis binary (default: `agentis` on PATH).
#   --json            Emit the aggregate scorecard as one JSON object on stdout (human log still goes to stderr).
# Exit: 0 = requested stage(s) completed (a low/zero recall is DATA, not a failure — same posture as the
#       capability bench's live stage) ; 1 = --self-test regressed ; 2 = bad args ; 3 = missing prerequisite.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DF="$(cd "$HERE/../.." && pwd)"   # dark-factory/
GATE="$DF/novelty-gate.sh"
ZONEHUNT="$DF/run-zone-hunt.sh"
EXTRACTGT="$HERE/extract-gt.sh"
FETCHCORPUS="$HERE/fetch-corpus.sh"
CORPUS="$HERE/corpus.tsv"

WORK="$PWD/corpus-bench-work"
IDS="" ; BACKEND="flat-cyborg" ; JOBS="1" ; MINOV="2" ; AGENTIS="agentis" ; JSON=0
DO_SELFTEST=0 ; DO_FETCH=0 ; DO_GT=0 ; DO_HUNT=0 ; DO_SCORE=0 ; ANY_ACTION=0
declare -a ID_ARGS=()

nv() { [ "$1" -ge 2 ] || { echo "run-corpus-bench.sh: $2 requires a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do case "$1" in
  --self-test)   DO_SELFTEST=1; ANY_ACTION=1; shift;;
  --fetch)       DO_FETCH=1; ANY_ACTION=1; shift;;
  --gt)          DO_GT=1; ANY_ACTION=1; shift;;
  --hunt)        DO_HUNT=1; ANY_ACTION=1; shift;;
  --score)       DO_SCORE=1; ANY_ACTION=1; shift;;
  --live)        DO_FETCH=1; DO_GT=1; DO_HUNT=1; DO_SCORE=1; ANY_ACTION=1; shift;;
  --id)          nv "$#" "$1"; IDS="$IDS $2"; ID_ARGS+=(--id "$2"); shift 2;;
  --work)        nv "$#" "$1"; WORK="$2"; shift 2;;
  --corpus)      nv "$#" "$1"; CORPUS="$2"; shift 2;;
  --backend)     nv "$#" "$1"; BACKEND="$2"; shift 2;;
  --jobs)        nv "$#" "$1"; JOBS="$2"; shift 2;;
  --min-overlap) nv "$#" "$1"; MINOV="$2"; shift 2;;
  --agentis)     nv "$#" "$1"; AGENTIS="$2"; shift 2;;
  --json)        JSON=1; shift;;
  -h|--help)     awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0;;
  *) echo "run-corpus-bench.sh: unknown arg: $1" >&2; exit 2;;
esac; done
[ "$ANY_ACTION" -eq 1 ] || DO_SELFTEST=1

say() { echo "run-corpus-bench.sh: $*" >&2; }

# overlaps: is `stdin` text KNOWN (overlaps) w.r.t. exclusion file $1? echo 1 if KNOWN else 0.
overlaps() {
  "$GATE" --exclusion "$1" --min-overlap "$MINOV" >/dev/null 2>&1
  [ "$?" -eq 1 ] && echo 1 || echo 0
}

# ---- --self-test (default; deterministic, no network/LLM) ------------------------------------------------
if [ "$DO_SELFTEST" -eq 1 ]; then
  command -v python3 >/dev/null 2>&1 || { echo "run-corpus-bench.sh: [SKIP] python3 not installed" >&2; exit 0; }
  TMP_TRUTH="$(mktemp)"
  bash "$EXTRACTGT" "$HERE/fixtures/sample-judging-readme.md" "$TMP_TRUTH" 2>/dev/null
  if diff -q "$TMP_TRUTH" "$HERE/fixtures/expected-truth.tsv" >/dev/null 2>&1; then
    say "SELF-TEST: extract-gt.sh output byte-matches fixtures/expected-truth.tsv -> PASS"
    rm -f "$TMP_TRUTH"
    [ "$ANY_ACTION" -eq 1 ] && [ "$DO_FETCH$DO_GT$DO_HUNT$DO_SCORE" = "0000" ] && exit 0
  else
    say "SELF-TEST: extract-gt.sh output DIFFERS from fixtures/expected-truth.tsv -> FAIL"
    diff "$TMP_TRUTH" "$HERE/fixtures/expected-truth.tsv" >&2 || true
    rm -f "$TMP_TRUTH"
    exit 1
  fi
fi
[ "$DO_FETCH$DO_GT$DO_HUNT$DO_SCORE" = "0000" ] && exit 0

[ -f "$CORPUS" ] || { echo "run-corpus-bench.sh: corpus manifest not found: $CORPUS" >&2; exit 2; }
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"

# ---- --fetch ----------------------------------------------------------------------------------------------
if [ "$DO_FETCH" -eq 1 ]; then
  say "FETCH: cloning corpus rows into $WORK ..."
  bash "$FETCHCORPUS" --out "$WORK" --corpus "$CORPUS" "${ID_ARGS[@]}" \
    || { echo "run-corpus-bench.sh: fetch-corpus.sh failed" >&2; exit 3; }
fi

# ---- --gt ---------------------------------------------------------------------------------------------------
if [ "$DO_GT" -eq 1 ]; then
  while IFS=$'\t' read -r id _code _judging _subdir _scope; do
    case "$id" in ""|\#*) continue;; esac
    if [ -n "$IDS" ]; then case " $IDS " in *" $id "*) : ;; *) continue;; esac; fi
    readme="$WORK/$id/judging/README.md"
    [ -f "$readme" ] || { echo "run-corpus-bench.sh: [$id] no judging README at $readme (run --fetch first)" >&2; continue; }
    say "GT: [$id] extracting truth.tsv ..."
    bash "$EXTRACTGT" "$readme" "$WORK/$id/truth.tsv"
  done < "$CORPUS"
fi

# ---- --hunt (REAL federation) --------------------------------------------------------------------------------
if [ "$DO_HUNT" -eq 1 ]; then
  [ -x "$ZONEHUNT" ] || { echo "run-corpus-bench.sh: run-zone-hunt.sh not found/executable at $ZONEHUNT" >&2; exit 3; }
  while IFS=$'\t' read -r id _code _judging project_subdir scope_hint; do
    case "$id" in ""|\#*) continue;; esac
    if [ -n "$IDS" ]; then case " $IDS " in *" $id "*) : ;; *) continue;; esac; fi
    [ -n "$project_subdir" ] || { echo "run-corpus-bench.sh: [$id] corpus.tsv row has no project_subdir; skipping" >&2; continue; }
    code_dir="$WORK/$id/code/$project_subdir"
    [ -d "$code_dir" ] || { echo "run-corpus-bench.sh: [$id] no cloned code at $code_dir (run --fetch first)" >&2; continue; }
    say "HUNT: [$id] running the real federation (run-zone-hunt.sh --backend $BACKEND) ..."
    "$ZONEHUNT" --repo "$code_dir" --out "$WORK/$id/zone-hunt-out" --backend "$BACKEND" --jobs "$JOBS" \
      --agentis "$AGENTIS" ${scope_hint:+--scope-hint "$scope_hint"} \
      || say "  [$id] run-zone-hunt.sh exited non-zero; scoring whatever it produced"
  done < "$CORPUS"
fi

# ---- --score --------------------------------------------------------------------------------------------------
declare -a CONTEST_JSON=()
G_TOTAL=0 ; G_HITS=0
G_H_TOTAL=0 ; G_H_HITS=0 ; G_M_TOTAL=0 ; G_M_HITS=0
G_RARE_TOTAL=0 ; G_RARE_HITS=0 ; G_MID_TOTAL=0 ; G_MID_HITS=0 ; G_CONS_TOTAL=0 ; G_CONS_HITS=0
G_VERIFIED=0 ; G_MATCHED_LEADS=0 ; G_UNMATCHED_LEADS=0

if [ "$DO_SCORE" -eq 1 ]; then
  command -v python3 >/dev/null 2>&1 || { echo "run-corpus-bench.sh: python3 not installed (scoring needs it)" >&2; exit 3; }
  while IFS=$'\t' read -r id _code _judging _subdir _scope; do
    case "$id" in ""|\#*) continue;; esac
    if [ -n "$IDS" ]; then case " $IDS " in *" $id "*) : ;; *) continue;; esac; fi
    truth="$WORK/$id/truth.tsv"
    verified_json="$WORK/$id/zone-hunt-out/verify/verified_findings.json"
    if [ ! -f "$truth" ]; then say "SCORE: [$id] no truth.tsv (run --gt first); skipping"; continue; fi
    if [ ! -f "$verified_json" ]; then say "SCORE: [$id] no verified_findings.json (run --hunt first); skipping"; continue; fi
    say "SCORE: [$id] scoring verified findings against truth.tsv ..."

    LEADS_TXT="$(mktemp)"
    python3 - "$verified_json" > "$LEADS_TXT" <<'PY'
import sys, json
data = json.load(open(sys.argv[1], encoding="utf-8"))
for f in data.get("verified", []):
    row = " ".join([f.get("location", ""), f.get("class", ""), f.get("exploit", ""), f.get("poc_sketch", "")])
    print(row.replace("\t", " ").replace("\n", " "))
PY
    verified_n="$(wc -l < "$LEADS_TXT" | tr -d ' ')"

    # ALL-truth exclusion file (signature column only) — used to flag which leads matched *something* (for
    # precision/triage), never to auto-claim novelty for the rest (unmatched != confirmed-novel; see README.md).
    ALL_SIG="$(mktemp)"
    cut -f5 "$truth" > "$ALL_SIG"

    c_total=0 ; c_hits=0
    c_h_total=0 ; c_h_hits=0 ; c_m_total=0 ; c_m_hits=0
    c_rare_total=0 ; c_rare_hits=0 ; c_mid_total=0 ; c_mid_hits=0 ; c_cons_total=0 ; c_cons_hits=0
    while IFS=$'\t' read -r sev_id severity rarity title signature; do
      [ -n "${sev_id:-}" ] || continue
      c_total=$((c_total+1))
      SIGFILE="$(mktemp)"; printf '%s\n' "$signature" > "$SIGFILE"
      hit=0
      while IFS= read -r lead; do
        [ -n "$lead" ] || continue
        [ "$(printf '%s' "$lead" | overlaps "$SIGFILE")" = "1" ] && { hit=1; break; }
      done < "$LEADS_TXT"
      rm -f "$SIGFILE"
      [ "$hit" = 1 ] && c_hits=$((c_hits+1))
      case "$severity" in
        High)   c_h_total=$((c_h_total+1)); [ "$hit" = 1 ] && c_h_hits=$((c_h_hits+1)) ;;
        Medium) c_m_total=$((c_m_total+1)); [ "$hit" = 1 ] && c_m_hits=$((c_m_hits+1)) ;;
      esac
      if   [ "$rarity" -le 2 ] 2>/dev/null; then c_rare_total=$((c_rare_total+1)); [ "$hit" = 1 ] && c_rare_hits=$((c_rare_hits+1))
      elif [ "$rarity" -le 8 ] 2>/dev/null; then c_mid_total=$((c_mid_total+1));  [ "$hit" = 1 ] && c_mid_hits=$((c_mid_hits+1))
      else                                       c_cons_total=$((c_cons_total+1)); [ "$hit" = 1 ] && c_cons_hits=$((c_cons_hits+1))
      fi
      say "  [$id] $([ "$hit" = 1 ] && echo HIT || echo MISS) $sev_id (rarity $rarity): $title"
    done < "$truth"

    matched_leads=0
    while IFS= read -r lead; do
      [ -n "$lead" ] || continue
      [ "$(printf '%s' "$lead" | overlaps "$ALL_SIG")" = "1" ] && matched_leads=$((matched_leads+1))
    done < "$LEADS_TXT"
    unmatched_leads=$((verified_n - matched_leads))
    rm -f "$LEADS_TXT" "$ALL_SIG"

    say "  [$id] recall $c_hits/$c_total, High $c_h_hits/$c_h_total, Medium $c_m_hits/$c_m_total, rare $c_rare_hits/$c_rare_total, mid $c_mid_hits/$c_mid_total, consensus $c_cons_hits/$c_cons_total, verified-leads $verified_n (matched $matched_leads, unmatched $unmatched_leads — needs manual triage, NOT auto-claimed novel)"

    CONTEST_JSON+=("{\"id\":\"$id\",\"gt_total\":$c_total,\"hits\":$c_hits,\"high\":{\"total\":$c_h_total,\"hits\":$c_h_hits},\"medium\":{\"total\":$c_m_total,\"hits\":$c_m_hits},\"rare\":{\"total\":$c_rare_total,\"hits\":$c_rare_hits},\"mid\":{\"total\":$c_mid_total,\"hits\":$c_mid_hits},\"consensus\":{\"total\":$c_cons_total,\"hits\":$c_cons_hits},\"verified_leads\":$verified_n,\"matched_leads\":$matched_leads,\"unmatched_leads\":$unmatched_leads}")

    G_TOTAL=$((G_TOTAL+c_total)); G_HITS=$((G_HITS+c_hits))
    G_H_TOTAL=$((G_H_TOTAL+c_h_total)); G_H_HITS=$((G_H_HITS+c_h_hits))
    G_M_TOTAL=$((G_M_TOTAL+c_m_total)); G_M_HITS=$((G_M_HITS+c_m_hits))
    G_RARE_TOTAL=$((G_RARE_TOTAL+c_rare_total)); G_RARE_HITS=$((G_RARE_HITS+c_rare_hits))
    G_MID_TOTAL=$((G_MID_TOTAL+c_mid_total)); G_MID_HITS=$((G_MID_HITS+c_mid_hits))
    G_CONS_TOTAL=$((G_CONS_TOTAL+c_cons_total)); G_CONS_HITS=$((G_CONS_HITS+c_cons_hits))
    G_VERIFIED=$((G_VERIFIED+verified_n)); G_MATCHED_LEADS=$((G_MATCHED_LEADS+matched_leads)); G_UNMATCHED_LEADS=$((G_UNMATCHED_LEADS+unmatched_leads))
  done < "$CORPUS"

  say ""
  say "================ CORPUS-BENCH AGGREGATE ================"
  say "overall recall: $G_HITS/$G_TOTAL"
  say "by severity   : High $G_H_HITS/$G_H_TOTAL, Medium $G_M_HITS/$G_M_TOTAL"
  say "by rarity     : rare(1-2) $G_RARE_HITS/$G_RARE_TOTAL, mid(3-8) $G_MID_HITS/$G_MID_TOTAL, consensus(9+) $G_CONS_HITS/$G_CONS_TOTAL"
  say "verified leads: $G_VERIFIED total, $G_MATCHED_LEADS matched a truth row, $G_UNMATCHED_LEADS unmatched (manual triage required before any novelty claim)"

  if [ "$JSON" -eq 1 ]; then
    joined="$(IFS=,; echo "${CONTEST_JSON[*]:-}")"
    printf '{"contests":[%s],"aggregate":{"gt_total":%d,"hits":%d,"high":{"total":%d,"hits":%d},"medium":{"total":%d,"hits":%d},"rare":{"total":%d,"hits":%d},"mid":{"total":%d,"hits":%d},"consensus":{"total":%d,"hits":%d},"verified_leads":%d,"matched_leads":%d,"unmatched_leads":%d}}\n' \
      "$joined" "$G_TOTAL" "$G_HITS" "$G_H_TOTAL" "$G_H_HITS" "$G_M_TOTAL" "$G_M_HITS" \
      "$G_RARE_TOTAL" "$G_RARE_HITS" "$G_MID_TOTAL" "$G_MID_HITS" "$G_CONS_TOTAL" "$G_CONS_HITS" \
      "$G_VERIFIED" "$G_MATCHED_LEADS" "$G_UNMATCHED_LEADS"
  fi
fi

exit 0
