#!/usr/bin/env bash
# demo-holdout-exam.sh — proof of the #2262 held-out exam tooling (M1: the per-row triage scorer; M2: the exam
# runner core, bench/corpus-bench/exam/exam.sh).
#
# Every rare row of a held-out exam used to be scored by hand: read the truth row, look for candidates and
# verified findings at the same function, grep the cell logs, read the DISMISS lines and the refute verdicts,
# then decide HIT / MISS and the MISS cause. bench/corpus-bench/triage.py mechanises the READING: per truth row
# it collects the evidence at the row's location and PROPOSES a class (HIT-candidate / refuted /
# found-dismissed / scope-out-of-map / unmeasured / generation / unanchored) with the evidence lines next to
# it. The operator confirms; the tool never claims a HIT.
#
# M2 moves the rest of the host-only harness into the repo, contest-agnostic: exam.sh freezes a contest's map +
# briefs from a pinned checkout (contamination-checked on both sides), stages one zone or the whole contest into
# an arm dir, runs the breadth pass with a knob PROFILE (profiles/*.env) and optionally STAGE 4.5 over the same
# output, writes run.meta / .done / MANIFEST.tsv even after a crash, drives a plan sequentially under a PID lock
# from a snapshot of itself, kills by path, and hands every finished arm to triage.py.
#
# This demo has TWO parts (both CI-safe: no network, no LLM, no forge):
#   1) SOURCE-GUARD (always): triage.py reads ONLY real output logs (`hunt_*.log*` cell logs and
#      `refute_*.log` refute logs — never the `hunter.ag` / `refuter.ag` source copies every RUN dir holds,
#      which carry the same sentinel literals); it IMPORTS the frozen score-match.py pair rule instead of
#      re-implementing it; the fixture tree carries no absolute home path and its decoy `.ag` files carry no
#      GT-id token or `corpus-bench` literal (the #2231 guard scans every `.ag` under dark-factory/). The
#      behavioural part below SKIPs cleanly (exit 0) without python3.
#      Runner (M2): no pgrep/pkill anywhere in exam/ (a pattern-matching killer matches its own command line —
#      kill-by-path reads ps + /proc instead); no absolute home path and no corpus.tsv contest id (as a word) in
#      exam/ or fixtures/exam/; no profile value carries a path; exam.sh embeds no heredoc python and exports
#      the three Claude Code killswitches.
#   2) BEHAVIOURAL (when python3 is present): `triage.py --self-test` reproduces the fixed triage table in
#      bench/corpus-bench/fixtures/triage/ byte-for-byte and holds the decoy / superseded / unmeasured /
#      rare-subset / determinism assertions. `exam.sh self-test` then drives a mock two-zone exam end to end
#      over fixtures/exam/ with a stub agentis (--backend mock): profile grammar, freeze (+ both contamination
#      gates, the dirty-checkout refusal, multi-root clone), plan, stage (filter, class injection, drift
#      refusal), run (breadth + STAGE 4.5 knob routing, knob hygiene, hard stop), drive (lock, snapshot re-exec,
#      --resume, HEAD pin, triage hand-off) and kill-by-path.
#
# Usage:  dark-factory/demo-holdout-exam.sh
# Exit: 0 = all assertions hold (SKIPs cleanly when python3 is absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CB="$HERE/bench/corpus-bench"
TRIAGE="$CB/triage.py"
FIX="$CB/fixtures/triage"
EXAM="$CB/exam"
EXFIX="$CB/fixtures/exam"

FAILS=0
note() { echo "demo-holdout-exam.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$TRIAGE" ] || { note "triage.py not found: $TRIAGE" >&2; exit 3; }
for f in truth.tsv map/zones.json map/scope.tsv expected-triage.tsv expected-triage.md; do
  [ -f "$FIX/$f" ] || { note "fixture missing: $FIX/$f" >&2; exit 3; }
done
for f in "$EXAM/exam.sh" "$EXAM/exam-helper.py" "$EXAM/profiles/KNOBS" "$EXFIX/agentis-stub.sh" "$EXFIX/truth.tsv"; do
  [ -f "$f" ] || { note "exam runner file missing: $f" >&2; exit 3; }
done

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD (CI-safe, no toolchain).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #2262 triage scorer ..."

if grep -q 'f.startswith("hunt_")' "$TRIAGE" && grep -q 'f.startswith("refute_") and f.endswith(".log")' "$TRIAGE" \
   && ! grep -qE '^[[:space:]]*(import glob|from glob|.*\.rglob\()' "$TRIAGE"; then
  ok "triage.py reads only hunt_*.log* cell logs + refute_*.log refute logs (no tree-wide glob that could reach a .ag copy)"
else
  bad "triage.py log selection is not restricted to hunt_*.log* / refute_*.log"
fi

if grep -q '"score-match.py"' "$TRIAGE" && grep -q 'spec_from_file_location' "$TRIAGE" \
   && ! grep -qE '^def (parse_row_locations|lead_location|lead_matches_locations|bare_codefile)\(' "$TRIAGE"; then
  ok "triage.py imports score-match.py's pair rule read-only (no local re-implementation)"
else
  bad "triage.py does not import the frozen pair rule, or re-defines it"
fi

home_hits="$(grep -rnE '/home/|/Users/|/root/' "$FIX" 2>/dev/null || true)"
if [ -z "$home_hits" ]; then
  ok "fixtures/triage/ carries no absolute home path"
else
  bad "absolute home path under fixtures/triage/:"
  printf '%s\n' "$home_hits" | sed "s|^$HERE/||" | head -5
fi

decoys="$(find "$FIX" -name '*.ag' -type f 2>/dev/null | sort)"
if [ -n "$decoys" ]; then
  # shellcheck disable=SC2086
  ag_hits="$(grep -nE 'corpus-bench|(^|[^[:alnum:]_])[HM]-[0-9]{1,2}([^[:alnum:]_]|$)' $decoys 2>/dev/null || true)"
  if [ -z "$ag_hits" ]; then
    ok "the decoy .ag source copies ($(printf '%s\n' "$decoys" | wc -l | tr -d ' ')) carry no GT-id token and no corpus-bench literal (#2231)"
  else
    bad "a decoy .ag carries a GT-id token or corpus-bench literal (#2231 guard would fire)"
  fi
else
  bad "no decoy .ag source copy under fixtures/triage/ — the negative control is gone"
fi

note "source-guarding the #2262 exam runner ..."

killers="$(grep -rnIE '(^|[^[:alnum:]_-])(pgrep|pkill)([^[:alnum:]_-]|$)' "$EXAM" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -z "$killers" ]; then
  ok "exam/ calls no pgrep/pkill (kill-by-path reads ps + /proc; a pattern killer matches its own command line)"
else
  bad "exam/ calls pgrep/pkill:"; printf '%s\n' "$killers" | sed "s|^$HERE/||" | head -5
fi

ex_home="$(grep -rnIE '/home/|/Users/|/root/' "$EXAM" "$EXFIX" 2>/dev/null || true)"
if [ -z "$ex_home" ]; then
  ok "exam/ + fixtures/exam/ carry no absolute home path"
else
  bad "absolute home path under exam/ or fixtures/exam/:"; printf '%s\n' "$ex_home" | sed "s|^$HERE/||" | head -5
fi

ids="$(grep -v '^#' "$CB/corpus.tsv" | cut -f1 | grep . | paste -sd'|' -)"
if [ -n "$ids" ]; then
  ex_ids="$(grep -rnwiIE "$ids" "$EXAM" "$EXFIX" 2>/dev/null || true)"
  if [ -z "$ex_ids" ]; then
    ok "exam/ + fixtures/exam/ name no corpus.tsv contest ($(printf '%s\n' "$ids" | tr '|' '\n' | grep -c .) ids checked as words)"
  else
    bad "a corpus.tsv contest id appears under exam/ or fixtures/exam/:"; printf '%s\n' "$ex_ids" | sed "s|^$HERE/||" | head -5
  fi
else
  bad "corpus.tsv yields no contest id — the contest-name guard checks nothing"
fi

prof_paths="$(grep -nE '^[^#]*=.*/' "$EXAM"/profiles/*.env 2>/dev/null || true)"
if [ -z "$prof_paths" ]; then
  ok "no shipped profile value carries a path (contest / host facts live in freeze.meta + the plan TSV)"
else
  bad "a shipped profile carries a path:"; printf '%s\n' "$prof_paths" | sed "s|^$HERE/||" | head -5
fi

if ! grep -qE "<<-?[[:space:]]*'?PY'?|python3 -[[:space:]]" "$EXAM/exam.sh" \
   && grep -q '^export CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1$' "$EXAM/exam.sh" \
   && grep -q '^export CLAUDE_CODE_NO_MODEL_FALLBACK=1$' "$EXAM/exam.sh" \
   && grep -q '^export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1$' "$EXAM/exam.sh"; then
  ok "exam.sh embeds no heredoc python and exports the three Claude Code killswitches"
else
  bad "exam.sh embeds heredoc python or lost a killswitch export"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) BEHAVIOURAL — the fixed triage table (SKIP cleanly without python3).
# ----------------------------------------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 not installed — install python3 to run the triage.py self-test"
else
  note "running triage.py --self-test (behavioural) ..."
  st_out="$(python3 "$TRIAGE" --self-test 2>&1)"; st_rc=$?
  if [ "$st_rc" -eq 0 ]; then
    ok "triage.py --self-test PASSED (fixed triage table reproduced from fixtures/triage/)"
  else
    bad "triage.py --self-test FAILED (exit $st_rc)"
    printf '%s\n' "$st_out" | sed 's/^/         | /' | tail -25
  fi
  if ! command -v git >/dev/null 2>&1 || ! timeout --version 2>/dev/null | grep -q 'GNU coreutils' || [ ! -d /proc/self ]; then
    skip "exam.sh self-test needs git, GNU timeout and /proc — skipped on this host"
  else
    note "running exam.sh self-test (mock two-zone exam end to end) ..."
    ex_out="$(bash "$EXAM/exam.sh" self-test 2>&1)"; ex_rc=$?
    if [ "$ex_rc" -eq 0 ]; then
      ok "exam.sh self-test PASSED ($(printf '%s\n' "$ex_out" | grep -c '\[OK\]') assertions: freeze, plan, stage, run, drive, triage hand-off, kill)"
    else
      bad "exam.sh self-test FAILED (exit $ex_rc)"
      printf '%s\n' "$ex_out" | grep -E -A6 '\[FAIL\]' | sed 's/^/         | /' | head -40
    fi
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #2262 triage scorer reads only real output logs, imports the frozen pair rule, and reproduces"
  note "      the fixed per-row triage table (every class a PROPOSAL; the operator confirms); the exam runner"
  note "      freezes, stages, runs, drives and hands off to triage with no contest fact in the repo."
  exit 0
fi
note "DEMO FAILED — a #2262 triage / exam-runner assertion did not hold" >&2
exit 1
