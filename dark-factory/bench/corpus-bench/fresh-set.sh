#!/usr/bin/env bash
# fresh-set.sh — build a FRESH held-out contest set for the corpus bench, and probe the hunter model for
# training-memorised findings (#2263). Every capability change needs a never-touched held-out set to be measured;
# this replaces the manual routine (list concluded judging repos, clone, extract GT, count rare rows, check the
# code repo really carries source, check contamination, detect project roots, reserve) with one pipeline.
# The engine is fresh-set.py (python3 stdlib); this wrapper parses + validates flags, checks prerequisites,
# refuses an unsafe work dir and drives --self-test.
#
# Usage:
#   fresh-set.sh --work <dir> (--ledger <file> | --no-ledger) [build options]          # build + report
#   fresh-set.sh --work <dir> --reserve <id,id,...> [--allow-review] [--allow-memorized] [--corpus <tsv>]
#   fresh-set.sh probe <contest-dir> [--name <text>] [--backend flat-cyborg|stub] [--model <id>] [--stub <cmd>]
#                [--rescore] [--cued [--batch <N>] [--memorized-rare-rate <R>]]
#   fresh-set.sh --self-test
#
# Build options:
#   --work <dir>            REQUIRED, no default. Clones, truth.tsv, the report and RESERVED.tsv land here, laid out
#                           like fetch-corpus.sh (<work>/<id>/{code,judging,truth.tsv}). Refused (exit 2) when it
#                           resolves INSIDE this repo, so ground truth can never become repo text.
#   --ledger <file> | --no-ledger   exactly one is REQUIRED (no host default): the hunted-targets ledger to match
#                           every candidate against, or an explicit statement that none is checked.
#   --source sherlock-gh|candidates-file   discovery source (default sherlock-gh; candidates-file is implied by
#                           --candidates-from). sherlock-gh pages the org's public repos (GitHub REST, optional
#                           GH_TOKEN / GITHUB_TOKEN, never printed) and keeps `<slug>` + `<slug>-judging` pairs.
#   --org <org>             GitHub org for sherlock-gh (default sherlock-audit).
#   --listing-from <json>   offline hatch: a saved JSON array of repo objects instead of the API (repeatable).
#   --refresh-listing       re-fetch the listing instead of re-using <work>/.listing/ (a re-run costs 0 API calls).
#   --candidates-from <tsv> a hand list `slug  code_repo  judging_repo  [platform]` (any platform with GitHub
#                           judging repos).
#   --repos-from <dir>      copy <dir>/<owner>/<repo>/ instead of cloning (offline; no .git, no submodules).
#   --corpus <tsv>          corpus manifest whose repos are EXCLUDED (default: corpus.tsv next to this script).
#   --exclude <file>        more exclusions (repeatable): any whitespace field of a non-# line equal to a
#                           candidate's slug, id, code repo or judging repo — prior RESERVED.tsv manifests, spent
#                           exam lists, one slug per line.
#   --scan-root <dir>       text tree scanned for contamination (default: this repo's top level).
#   --scan-exclude <prefix> a scan-root-relative path prefix left out of the scan (repeatable).
#   --since YYYY-MM / --until YYYY-MM   keep candidates whose `date` (the slug's month) is in range.
#   --only <id|slug>        restrict to these candidates (repeatable).
#   --min-rare <N>          fewest rare rows (found-by <= 2) a contest needs (default 1); fewer -> LOW-RARE, and
#                           its code is never cloned.
#   --max-candidates <N>    clone at most N non-excluded candidates, newest first.
#   --discover-only         stop after exclusion; write <work>/candidates.tsv only (no clone).
#   --probe                 run the memorisation probe (below) on every CLEAN / REVIEW contest that has no
#                           recorded reply yet; a recorded <work>/<id>/probe/reply.txt is always re-scored.
#   --backend / --model / --stub   the probe backend (flat-cyborg | stub), model pin (default opus, the hunt's
#                           llm.model default) and stub command (default fixtures/fresh-set/probe-stub.sh).
#   --cued [--batch N] [--memorized-rare-rate R]   with --probe: also run the CUED probe (below); a recorded cued
#                           probe is always re-scored.
#
# Statuses, in gate order (a contest carries the FIRST gate it fails): EXCLUDED (in --corpus / an --exclude
# file) > NO-GT (no judging README or 0 accepted H/M rows) > LOW-RARE > NO-CODE (empty-submodule / readme-only /
# no-solidity / fetch-failed) > CONTAMINATED (a strong name hit anywhere, any hit in a prompt-visible file, or a
# strong ledger hit) > MEMORIZED (the probe recalls >= 1 rare row) > REVIEW (weak name-token hits only) > CLEAN.
# The report <work>/fresh-set-report.tsv holds COUNTS only; GT text stays in <work>/<id>/truth.tsv.
#
# Reserve: reads the report (no network) and writes the sealed <work>/RESERVED.tsv (corpus.tsv row format, one
# `# lock` line per contest with the code/judging SHAs and GT counts). Refused (exit 4, nothing written) for an
# unknown id, a non-CLEAN status (REVIEW needs --allow-review, MEMORIZED needs --allow-memorized), no detected
# project root, or an id already in --corpus. Run the set with:
#   run-corpus-bench.sh --work <work> --corpus <work>/RESERVED.tsv ...
#
# probe <contest-dir>: the training-memorisation probe, standalone on ANY contest dir holding truth.tsv — a
# fresh-set work dir row or an already-frozen fetch-corpus.sh dir (spent sets can be probed retroactively). It
# asks the hunter model — the hunt's backend (flat-cyborg over lib/claude-sandboxed.sh, every tool off) and model
# pin (--model) — which accepted High/Medium findings it REMEMBERS for the named contest, with NO code and NO
# ground truth in the prompt (a leak guard refuses a prompt carrying a GT title, id, location function or .sol
# name: exit 4). The reply is scored OFFLINE against truth.tsv by a conservative matcher (a non-generic
# contract/function name AND mechanism keywords) -> per row recalled_from_memory yes|partial|no, per contest a
# memorisation rate. prompt.txt + reply.txt are recorded VERBATIM in <contest-dir>/probe/ with probe.tsv and
# summary.tsv. --name overrides the protocol name (default: contest.tsv, else the code README H1); --rescore
# re-scores the recorded reply without calling the model.
#
# probe <contest-dir> --cued: the RECOGNITION probe. Free recall is biased toward NONE by its do-not-guess rule, so
# the cued probe gives the model, per GT row with a column-6 location, ONLY `<contract>:<function>` (never a title,
# a description or a mechanism) plus the contest name, and asks whether an accepted High/Medium finding was
# reported there and, if yes, its root cause. --batch N locations per prompt (default 20), each batch with one
# DECOY: a real function of <contest-dir>/code that no GT row names. Scored offline by the same conservative
# matcher (the cue gives the names, so credit rests on the mechanism the model adds) -> cued_recall per row
# (probe/cued.tsv), cued_rate + rare_cued_rate + decoy_fp_rate (probe/cued-summary.tsv; a high decoy_fp_rate =
# a model that says YES to everything). MEMORIZED when rare_cued_rate > --memorized-rare-rate (default 0.25).
# Prompts and replies are recorded verbatim (probe/cued-prompt-<n>.txt, cued-reply-<n>.txt).
#
# --self-test: offline fixture suite (FRESH_SET_OFFLINE=1 trips any network access; no token; stub backend).
# A probe whose backend fails (non-zero exit or an empty reply) is never scored: the reply is kept as
# probe/reply.failed.txt, `probe` exits 3 and a build marks the contest memo=failed (it stays unprobed).
# Exit: 0 ok ; 1 self-test failed ; 2 usage error or unsafe --work / contest dir ; 3 missing prerequisite,
#       unreadable input or a failed probe backend ; 4 reserve / probe refused ; 5 network reached under
#       FRESH_SET_OFFLINE=1.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HERE/fresh-set.py"
FIX="$HERE/fixtures/fresh-set"

usage() { awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; }
die() { echo "fresh-set.sh: $2" >&2; exit "$1"; }

prereqs() {
  command -v python3 >/dev/null 2>&1 || die 3 "python3 is required"
  command -v git >/dev/null 2>&1 || die 3 "git is required"
  [ -f "$PY" ] || die 3 "engine not found: $PY"
}

# realpath without creating anything (the path may not exist yet); python3 is a prerequisite anyway.
realp() { python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

REPO_TOP=""
repo_top() {
  if [ -z "$REPO_TOP" ]; then
    local t
    t="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$t" ] || t="$(cd "$HERE/../../.." && pwd -P)"
    REPO_TOP="$(realp "$t")"
  fi
  printf '%s\n' "$REPO_TOP"
}

# 0 when $1 resolves to the repo top level or anything below it.
inside_repo() {
  local p top
  p="$(realp "$1")"
  top="$(repo_top)"
  case "$p/" in "$top"/*) return 0 ;; esac
  return 1
}

# ---- --self-test -------------------------------------------------------------------------------------------------
# The ok/bad reporting below is the `test && ok || bad` idiom of the sibling self-tests (ok never fails).
# shellcheck disable=SC2015
self_test() {
  local T FAILS=0 rc
  T="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$T'" EXIT
  ok()  { echo "  [PASS] $*"; }
  bad() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
  run() { env -u GH_TOKEN -u GITHUB_TOKEN FRESH_SET_OFFLINE=1 bash "$0" "$@"; }
  same() { # $1 expected, $2 actual, $3 label
    if diff -u "$1" "$2" >"$T/diff.out" 2>&1; then ok "$3"; else bad "$3"; sed 's/^/         | /' "$T/diff.out" | head -30; fi
  }
  local COMMON=(--listing-from "$FIX/listing.json" --org fixture-org --repos-from "$FIX/repos"
                --corpus "$FIX/corpus.tsv" --scan-root "$FIX/scan-root")

  echo "fresh-set.sh --self-test (offline: FRESH_SET_OFFLINE=1, no token, stub backend)"

  # (1) build over the fixtures, no ledger: all seven contest pairs classified, byte-exact.
  run --work "$T/a" "${COMMON[@]}" --no-ledger >"$T/a.out" 2>"$T/a.err"; rc=$?
  [ "$rc" -eq 0 ] && ok "(1) build --no-ledger exits 0" || { bad "(1) build --no-ledger exit $rc"; sed 's/^/         | /' "$T/a.err" | tail -10; }
  same "$FIX/expected-report.tsv" "$T/a/fresh-set-report.tsv" \
    "(1) report byte-matches: CLEAN / NO-CODE readme-only + empty-submodule / CONTAMINATED (prompt-visible) / EXCLUDED / REVIEW / NO-GT; rare_loc pins --code"

  # (2) the same build with the hunted-targets ledger: alpha flips to CONTAMINATED, every other status holds.
  run --work "$T/b" "${COMMON[@]}" --ledger "$FIX/ledger.tsv" >"$T/b.out" 2>"$T/b.err"; rc=$?
  [ "$rc" -eq 0 ] && ok "(2) build --ledger exits 0" || bad "(2) build --ledger exit $rc"
  same "$FIX/expected-report.ledger.tsv" "$T/b/fresh-set-report.tsv" "(2) --ledger report byte-matches (alpha -> CONTAMINATED)"

  # (3) reserve.
  run --work "$T/a" --reserve alpha --corpus "$FIX/corpus.tsv" >/dev/null 2>&1; rc=$?
  grep -v '^# built=' "$T/a/RESERVED.tsv" >"$T/reserved.got" 2>/dev/null
  grep -v '^# built=' "$FIX/expected-reserved.tsv" >"$T/reserved.want"
  if [ "$rc" -eq 0 ]; then same "$T/reserved.want" "$T/reserved.got" "(3) --reserve alpha writes the expected RESERVED.tsv"
  else bad "(3) --reserve alpha exit $rc"; fi
  cp "$T/a/RESERVED.tsv" "$T/reserved.before" 2>/dev/null
  run --work "$T/a" --reserve bravo --corpus "$FIX/corpus.tsv" >/dev/null 2>&1; rc=$?
  { [ "$rc" -eq 4 ] && cmp -s "$T/reserved.before" "$T/a/RESERVED.tsv"; } \
    && ok "(3) --reserve bravo (NO-CODE) exits 4 and writes nothing" || bad "(3) --reserve bravo exit $rc (want 4, manifest untouched)"
  run --work "$T/a" --reserve nosuch --corpus "$FIX/corpus.tsv" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 4 ] && ok "(3) --reserve of an unknown id exits 4" || bad "(3) --reserve unknown id exit $rc (want 4)"
  run --work "$T/a" --reserve foxtrot --corpus "$FIX/corpus.tsv" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 4 ] && ok "(3) --reserve foxtrot (REVIEW) exits 4 without --allow-review" || bad "(3) --reserve foxtrot exit $rc (want 4)"
  run --work "$T/a" --reserve foxtrot --allow-review --corpus "$FIX/corpus.tsv" >/dev/null 2>&1; rc=$?
  { [ "$rc" -eq 0 ] && grep -q '^foxtrot	' "$T/a/RESERVED.tsv"; } \
    && ok "(3) --reserve foxtrot --allow-review exits 0" || bad "(3) --reserve foxtrot --allow-review exit $rc"

  # (4) usage guards: a work dir / contest dir inside the repo, and a build without a ledger decision.
  local INREPO="$HERE/.fresh-set-selftest-inrepo"
  run --work "$INREPO" "${COMMON[@]}" --no-ledger >/dev/null 2>&1; rc=$?
  { [ "$rc" -eq 2 ] && [ ! -e "$INREPO" ]; } && ok "(4) --work inside the repo exits 2 and creates nothing" \
    || bad "(4) --work inside the repo exit $rc (want 2, nothing created)"
  run probe "$FIX" --backend stub >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "(4) probe on a contest dir inside the repo exits 2" || bad "(4) probe inside the repo exit $rc (want 2)"
  run --work "$T/c" "${COMMON[@]}" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "(4) a build with neither --ledger nor --no-ledger exits 2" || bad "(4) no ledger decision exit $rc (want 2)"

  # (5) the GitHub listing client and the probe matcher, unit level (stub fetcher / synthetic rows).
  if env -u GH_TOKEN -u GITHUB_TOKEN python3 "$PY" selftest-listing >"$T/l.out" 2>&1; then
    ok "(5) listing client: rate-limit partial keeps page 1, token header only with a token, cache, trip-wire"
  else bad "(5) listing client"; grep -v PASS "$T/l.out" | sed 's/^/         | /'; fi
  if python3 "$PY" selftest-probe >"$T/p.out" 2>&1; then
    ok "(5) probe matcher: conservative yes/partial/no, one row per reply line, leak guard, backend argv"
  else bad "(5) probe matcher"; grep -v PASS "$T/p.out" | sed 's/^/         | /'; fi

  # (6) --discover-only + --exclude: a prior RESERVED manifest excludes its contest; the unpaired repo is dropped.
  run --work "$T/d" "${COMMON[@]}" --no-ledger --discover-only --exclude "$FIX/expected-reserved.tsv" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && grep -q '^alpha	.*	EXCLUDED	exclude-list	' "$T/d/candidates.tsv" \
     && grep -q '^2099-05-echo	.*	EXCLUDED	corpus	' "$T/d/candidates.tsv" \
     && ! grep -q 'hotel' "$T/d/candidates.tsv" && [ ! -d "$T/d/bravo" ]; then
    ok "(6) --discover-only: RESERVED.tsv as --exclude, corpus exclusion, unpaired repo dropped, nothing cloned"
  else bad "(6) --discover-only / --exclude (exit $rc)"; fi

  # (7) standalone probe on an already-FROZEN contest dir (fetch-corpus.sh layout, no contest.tsv): the
  #     contest name comes from the judging clone's origin remote + the code README H1.
  local FZ="$T/frozen/alpha"
  mkdir -p "$FZ/code" "$FZ/judging"
  cp "$T/a/alpha/truth.tsv" "$FZ/truth.tsv"
  cp "$FIX/repos/fixture-org/2099-01-alpha/README.md" "$FZ/code/README.md"
  git -C "$FZ/judging" init -q 2>/dev/null && git -C "$FZ/judging" remote add origin "https://github.com/fixture-org/2099-01-alpha-judging.git"
  run probe "$FZ" --backend stub --model fixture-model >"$T/fz.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "(7) probe on a frozen contest dir exits 0" || { bad "(7) frozen probe exit $rc"; sed 's/^/         | /' "$T/fz.out" | tail -5; }
  same "$FIX/expected-probe.tsv" "$FZ/probe/probe.tsv" "(7) per-row recalled_from_memory byte-matches (rare yes + partial, generic-name partial)"
  if grep -q 'verdict' "$FZ/probe/summary.tsv" && grep -q '	MEMORIZED	stub	fixture-model$' "$FZ/probe/summary.tsv"; then
    ok "(7) summary: MEMORIZED, backend + model pin recorded"
  else bad "(7) summary.tsv"; sed 's/^/         | /' "$FZ/probe/summary.tsv" 2>/dev/null; fi
  if grep -q '"2099-01-alpha"' "$FZ/probe/prompt.txt" && grep -q 'Alpha Lending' "$FZ/probe/prompt.txt" \
     && ! grep -qiE '\.sol|claimRewards|sweepDust|[HM]-[0-9]' "$FZ/probe/prompt.txt"; then
    ok "(7) prompt.txt recorded verbatim: names the contest, carries no code and no ground truth"
  else bad "(7) prompt.txt content"; fi
  grep -q '^stub model=fixture-model$' "$FZ/probe/reply.txt" \
    && ok "(7) reply.txt recorded verbatim; the --model pin reached the backend" || bad "(7) reply.txt / model pin"
  cp "$FZ/probe/probe.tsv" "$T/probe.first"
  run probe "$FZ" --rescore >/dev/null 2>&1; rc=$?
  { [ "$rc" -eq 0 ] && cmp -s "$T/probe.first" "$FZ/probe/probe.tsv"; } \
    && ok "(7) --rescore re-scores the recorded reply offline, identically" || bad "(7) --rescore exit $rc / drift"
  run probe "$FZ" --backend stub --name "Stale exchange rate lets sweepDust round fee shares to zero" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 4 ] && ok "(7) the leak guard refuses a prompt carrying a GT title (exit 4)" || bad "(7) leak guard exit $rc (want 4)"
  FRESH_SET_PROBE_STUB_MODE=fail run probe "$FZ" --backend stub --model fixture-model >/dev/null 2>&1; rc=$?
  { [ "$rc" -eq 3 ] && [ -f "$FZ/probe/reply.failed.txt" ] && [ ! -e "$FZ/probe/reply.txt" ] \
    && [ ! -e "$FZ/probe/summary.tsv" ]; } \
    && ok "(7) a dead backend exits 3 and is never scored (no reply.txt / summary.tsv left to read as not-memorized)" \
    || bad "(7) failed probe exit $rc (want 3, nothing scored)"

  # (7c) the CUED probe on the same frozen dir: only `<contract>:<function>` cues + one decoy per batch.
  mkdir -p "$FZ/code/proj/src"
  cp "$FIX/repos/fixture-org/2099-01-alpha/proj/src/Vault.sol" "$FZ/code/proj/src/Vault.sol"
  run probe "$FZ" --cued --backend stub --model fixture-model >"$T/cz.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "(7c) cued probe on a frozen contest dir exits 0" || { bad "(7c) cued probe exit $rc"; sed 's/^/         | /' "$T/cz.out" | tail -5; }
  same "$FIX/expected-cued.tsv" "$FZ/probe/cued.tsv" "(7c) per-row cued_recall byte-matches (located rare row yes, decoy NONE, unlocated rows not asked)"
  if grep -q '	1.00	1	0	0.00	0.25	1	MEMORIZED	stub	fixture-model$' "$FZ/probe/cued-summary.tsv"; then
    ok "(7c) cued-summary: rare_cued_rate 1.00 > 0.25 -> MEMORIZED, decoy_fp_rate 0.00"
  else bad "(7c) cued-summary.tsv"; sed 's/^/         | /' "$FZ/probe/cued-summary.tsv" 2>/dev/null; fi
  if grep -qx 'C[0-9]|Vault:claimRewards' "$FZ/probe/cued-prompt-1.txt" && grep -qx 'C[0-9]|Vault:pause' "$FZ/probe/cued-prompt-1.txt" \
     && ! grep -qiE '\.sol|sweepDust|reentr|payout|drain|slippage|[HM]-[0-9]' "$FZ/probe/cued-prompt-1.txt"; then
    ok "(7c) cued prompt: the location cue + a decoy, no title / mechanism / GT id / .sol name"
  else bad "(7c) cued prompt content"; fi
  run probe "$FZ" --cued --rescore --memorized-rare-rate 1.0 >/dev/null 2>&1; rc=$?
  { [ "$rc" -eq 0 ] && grep -q '	1.00	1	not-memorized	stub	fixture-model$' "$FZ/probe/cued-summary.tsv"; } \
    && ok "(7c) --memorized-rare-rate is the threshold: 1.00 is not > 1.0 -> not-memorized (offline re-score)" \
    || bad "(7c) --memorized-rare-rate threshold (exit $rc)"
  FRESH_SET_PROBE_STUB_MODE=yes-all run probe "$FZ" --cued --backend stub --model fixture-model >/dev/null 2>&1; rc=$?
  { [ "$rc" -eq 0 ] && grep -q '	1	1	1.00	0.25	1	not-memorized	stub	fixture-model$' "$FZ/probe/cued-summary.tsv" \
    && grep -q '^H-1	.*	YES	no	0$' "$FZ/probe/cued.tsv"; } \
    && ok "(7c) a say-YES-to-everything model: decoy_fp_rate 1.00, a content-free YES is cued_recall no -> not MEMORIZED" \
    || { bad "(7c) yes-all model (exit $rc)"; sed 's/^/         | /' "$FZ/probe/cued-summary.tsv" 2>/dev/null; }

  # (8) build --probe --cued folds both probes into the report: alpha -> MEMORIZED, not reservable without
  #     --allow-memorized.
  run --work "$T/a" "${COMMON[@]}" --no-ledger --probe --cued --backend stub --model fixture-model >/dev/null 2>"$T/a2.err"; rc=$?
  [ "$rc" -eq 0 ] && ok "(8) build --probe exits 0" || { bad "(8) build --probe exit $rc"; tail -5 "$T/a2.err" | sed 's/^/         | /'; }
  same "$FIX/expected-report.probe.tsv" "$T/a/fresh-set-report.tsv" "(8) --probe report byte-matches (alpha MEMORIZED, foxtrot probed + still REVIEW)"
  same "$FIX/expected-probe.tsv" "$T/a/alpha/probe/probe.tsv" "(8) the build's probe of alpha scores like the standalone probe"
  same "$FIX/expected-cued.tsv" "$T/a/alpha/probe/cued.tsv" "(8) the build's cued probe of alpha scores like the standalone one"
  run --work "$T/a" --reserve alpha --corpus "$FIX/corpus.tsv" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 4 ] && ok "(8) --reserve of a MEMORIZED contest exits 4" || bad "(8) --reserve MEMORIZED exit $rc (want 4)"
  run --work "$T/a" --reserve alpha --allow-memorized --corpus "$FIX/corpus.tsv" >/dev/null 2>&1; rc=$?
  { [ "$rc" -eq 0 ] && grep -q '^# lock alpha .* memo_rare=1/2 memo_cued=1/1$' "$T/a/RESERVED.tsv"; } \
    && ok "(8) --allow-memorized reserves it, the lock line carries memo_rare + memo_cued" || bad "(8) --allow-memorized exit $rc"

  # No run may have reached the network: the trip-wire turns any attempt into exit 5 + a loud line.
  if cat "$T"/*.err "$T"/*.out 2>/dev/null | grep -q 'TRIP-WIRE'; then bad "a run reached the network trip-wire"
  else ok "no run reached the network (FRESH_SET_OFFLINE trip-wire silent)"; fi

  echo
  if [ "$FAILS" -eq 0 ]; then echo "fresh-set.sh: self-test PASS"; return 0; fi
  echo "fresh-set.sh: self-test FAIL — $FAILS check(s)" >&2
  return 1
}

# ---- dispatch ----------------------------------------------------------------------------------------------------
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --self-test) [ $# -eq 1 ] || die 2 "--self-test takes no other argument"; prereqs; self_test; exit $? ;;
  "") usage >&2; exit 2 ;;
esac

nv() { [ "$1" -ge 2 ] || die 2 "$2 requires a value"; }
int() { printf '%s' "$2" | grep -qE '^[0-9]+$' || die 2 "$1 wants a non-negative integer, got: $2"; }
rate() { printf '%s' "$2" | grep -qE '^(0(\.[0-9]+)?|1(\.0+)?)$' || die 2 "$1 wants a rate in [0, 1], got: $2"; }

if [ "$1" = "probe" ]; then
  shift
  prereqs
  [ $# -ge 1 ] && [ "${1#-}" = "$1" ] || die 2 "usage: fresh-set.sh probe <contest-dir> [options]"
  CDIR="$1"; shift
  PARGS=()
  while [ $# -gt 0 ]; do case "$1" in
    --name|--model|--stub) nv "$#" "$1"; PARGS+=("$1" "$2"); shift 2 ;;
    --backend) nv "$#" "$1"
               case "$2" in flat-cyborg|stub) ;; *) die 2 "--backend must be flat-cyborg or stub" ;; esac
               PARGS+=("$1" "$2"); shift 2 ;;
    --rescore|--cued) PARGS+=("$1"); shift ;;
    --batch) nv "$#" "$1"; int "$1" "$2"; [ "$2" -ge 1 ] || die 2 "--batch must be >= 1"; PARGS+=("$1" "$2"); shift 2 ;;
    --memorized-rare-rate) nv "$#" "$1"; rate "$1" "$2"; PARGS+=("$1" "$2"); shift 2 ;;
    *) die 2 "unknown probe arg: $1" ;;
  esac; done
  [ -d "$CDIR" ] || die 3 "contest dir not found: $CDIR"
  inside_repo "$CDIR" && die 2 "contest dir resolves inside the repo ($(repo_top)) — ground truth must never become repo text"
  exec python3 "$PY" probe "$CDIR" "${PARGS[@]}"
fi

WORK=""; RESERVE=""; LEDGER=""; NO_LEDGER=0
ARGS=()
BUILD_ONLY=0; RESERVE_ONLY=0
ym() { printf '%s' "$2" | grep -qE '^[0-9]{4}-[0-9]{2}$' || die 2 "$1 wants YYYY-MM, got: $2"; }
while [ $# -gt 0 ]; do case "$1" in
  --work)    nv "$#" "$1"; WORK="$2"; shift 2 ;;
  --reserve) nv "$#" "$1"; RESERVE="$2"; shift 2 ;;
  --corpus)  nv "$#" "$1"; ARGS+=("$1" "$2"); shift 2 ;;
  --allow-review|--allow-memorized) ARGS+=("$1"); RESERVE_ONLY=1; shift ;;
  --ledger)  nv "$#" "$1"; LEDGER="$2"; ARGS+=("$1" "$2"); BUILD_ONLY=1; shift 2 ;;
  --no-ledger) NO_LEDGER=1; ARGS+=("$1"); BUILD_ONLY=1; shift ;;
  --source)  nv "$#" "$1"
             case "$2" in sherlock-gh|candidates-file) ;; *) die 2 "--source must be sherlock-gh or candidates-file" ;; esac
             ARGS+=("$1" "$2"); BUILD_ONLY=1; shift 2 ;;
  --backend) nv "$#" "$1"
             case "$2" in flat-cyborg|stub) ;; *) die 2 "--backend must be flat-cyborg or stub" ;; esac
             ARGS+=("$1" "$2"); BUILD_ONLY=1; shift 2 ;;
  --since|--until) nv "$#" "$1"; ym "$1" "$2"; ARGS+=("$1" "$2"); BUILD_ONLY=1; shift 2 ;;
  --min-rare|--max-candidates|--batch) nv "$#" "$1"; int "$1" "$2"; ARGS+=("$1" "$2"); BUILD_ONLY=1; shift 2 ;;
  --memorized-rare-rate) nv "$#" "$1"; rate "$1" "$2"; ARGS+=("$1" "$2"); BUILD_ONLY=1; shift 2 ;;
  --org|--listing-from|--candidates-from|--repos-from|--exclude|--scan-root|--scan-exclude|--only|--model|--stub)
             nv "$#" "$1"; ARGS+=("$1" "$2"); BUILD_ONLY=1; shift 2 ;;
  --discover-only|--refresh-listing|--probe|--cued) ARGS+=("$1"); BUILD_ONLY=1; shift ;;
  *) die 2 "unknown arg: $1 (see --help)" ;;
esac; done

prereqs
[ -n "$WORK" ] || die 2 "--work <dir> is required (no default)"
inside_repo "$WORK" && die 2 "--work resolves inside the repo ($(repo_top)) — clones and truth.tsv must stay outside repo text"

if [ -n "$RESERVE" ]; then
  [ "$BUILD_ONLY" -eq 0 ] || die 2 "--reserve takes only --work, --corpus, --allow-review, --allow-memorized"
  exec python3 "$PY" reserve --work "$WORK" --reserve "$RESERVE" "${ARGS[@]}"
fi
[ "$RESERVE_ONLY" -eq 0 ] || die 2 "--allow-review / --allow-memorized only apply to --reserve"
if [ -n "$LEDGER" ] && [ "$NO_LEDGER" -eq 1 ]; then die 2 "pass exactly one of --ledger <file> / --no-ledger"; fi
if [ -z "$LEDGER" ] && [ "$NO_LEDGER" -eq 0 ]; then die 2 "a build needs --ledger <file> or an explicit --no-ledger"; fi
if [ -n "$LEDGER" ] && [ ! -r "$LEDGER" ]; then die 3 "--ledger not readable: $LEDGER"; fi
exec python3 "$PY" build --work "$WORK" --repo-top "$(repo_top)" "${ARGS[@]}"
