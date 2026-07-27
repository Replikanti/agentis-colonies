#!/usr/bin/env bash
# mech-judge.sh — the SEMANTIC MECHANISM JUDGE driver for the corpus bench (issue #1829). score-match.py's
# location-first matcher decides "same bug?" by NAME co-occurrence, which is wrong in both directions: it
# MISSES a candidate that describes the GT row's exact root cause from a factory/helper the GT prose never
# names, and it CREDITS a candidate that merely shares a function name while describing a different mechanism.
# This driver replaces that decision with one LLM judgement per lead: does the candidate describe the SAME
# ROOT CAUSE and the SAME EXPLOIT MECHANISM as one of the ground-truth rows it is shown?
#
# CONTRACT: exactly ONE judging request as JSON on stdin -> `VERDICT|` lines on stdout, nothing else (same
# "echo only the verdict line" idiom as auditor/scripts/run-gate-agent.sh). The request is score-match.py's
# canonical form:
#   {"lead":{"id","location","file","class","exploit","poc_sketch"},"rows":[{"sev_id","signature"},...]}
# and the reply grammar is:
#   VERDICT|<lead_id>|<sev_id>|MATCH|<confidence 0-100>|<one-line reason>
#   VERDICT|<lead_id>|NONE|NO-MATCH|<confidence 0-100>|<one-line reason>
# Only lines matching that prefix are forwarded; a reply the model garbles yields NO lines, which score-match.py
# counts as a JUDGE-ERROR. This driver NEVER fabricates a verdict to fill the gap — fail-closed by construction.
#
# The LLM path goes through the flat-cyborg PTY wrapper (${MECH_JUDGE_LLM_CMD:-<federation-root>/flat-cyborg-claude.sh},
# the same LLM_WRAP-style indirection run-autoharness.sh / run-method-discovery.sh use), so judging bills against
# the flat-rate subscription session and never the metered print-mode API. FLAT_CYBORG_IDLE_MS defaults to 12000
# here: the wrapper's own 8000 default is too short for a multi-row reasoning prompt and truncates the reply.
#
# Usage: mech-judge.sh [--backend <flat-cyborg|mock>] [--self-test] [-h]
#   --backend flat-cyborg  (default) judge through the flat-cyborg wrapper.
#   --backend mock         judge through fixtures/mech-judge/judge-stub.sh (offline, deterministic; CI).
#   --self-test            offline driver contract check (no stdin, no LLM): the mock backend round-trips a
#                          request into well-formed verdict lines; the flat-cyborg path is the DEFAULT and this
#                          script never shells out to the metered print-mode API; a malformed reply produces no
#                          fabricated MATCH.
# Exit: 0 = the request was judged (verdict lines on stdout; NONE when the reply was unparseable — the caller
#       counts that as a JUDGE-ERROR) ; 1 = --self-test regressed ; 2 = bad args ; 3 = missing prerequisite.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DF="$(cd "$HERE/../.." && pwd)"           # dark-factory/
STUB="$HERE/fixtures/mech-judge/judge-stub.sh"
WRAP="${MECH_JUDGE_LLM_CMD:-$DF/flat-cyborg-claude.sh}"

BACKEND="flat-cyborg"
SELFTEST=0

nv() { [ "$1" -ge 2 ] || { echo "mech-judge.sh: $2 requires a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do case "$1" in
  --backend)   nv "$#" "$1"; BACKEND="$2"; shift 2 ;;
  --self-test) SELFTEST=1; shift ;;
  -h|--help)   awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
  *) echo "mech-judge.sh: unknown arg: $1" >&2; exit 2 ;;
esac; done

case "$BACKEND" in
  flat-cyborg|mock) : ;;
  *) echo "mech-judge.sh: unknown backend: $BACKEND (expected flat-cyborg|mock)" >&2; exit 2 ;;
esac

# The decision rule the judge applies. Stated explicitly because BOTH naive heuristics are wrong: names are
# neither sufficient (the yieldoor-style name twin) nor necessary (the yearn-style factory-located true match).
build_prompt() {
  printf '%s\n' \
"You are the MECHANISM JUDGE for a smart-contract audit bench. You decide whether a hunter's candidate finding" \
"is the SAME BUG as one of the ground-truth findings from a concluded audit contest." \
"" \
"DECISION RULE:" \
"- MATCH a ground-truth row only when the candidate describes the SAME ROOT CAUSE (the same faulty code" \
"  behaviour) AND the SAME EXPLOIT MECHANISM (the same way that behaviour is abused) as that row." \
"- Shared file or function names are NOT sufficient evidence. A candidate that names a function the row also" \
"  names but describes a DIFFERENT mechanism is NO-MATCH." \
"- Divergent file or function names are NOT disqualifying. A candidate located in a factory, helper, library" \
"  or getter that describes the row's root cause and mechanism is a MATCH, even if the row's prose never" \
"  mentions that file or function." \
"- Emit at most ONE MATCH per candidate, unless two rows are demonstrably the same underlying bug." \
"- When nothing matches, say so explicitly with the NONE row id. NEVER reply with nothing." \
"" \
"REQUEST (JSON: one candidate lead, plus the ground-truth rows to judge it against):" \
"$1" \
"" \
"Think briefly, then output ONLY verdict lines, one per line, in EXACTLY this grammar:" \
"VERDICT|<lead_id>|<sev_id>|MATCH|<confidence 0-100>|<one-line reason>" \
"VERDICT|<lead_id>|NONE|NO-MATCH|<confidence 0-100>|<one-line reason>" \
"Use the lead_id from the request verbatim. Use a sev_id that appears in the request verbatim. No other output."
}

# ---- --self-test (offline; no stdin, no LLM) ----------------------------------------------------------------
if [ "$SELFTEST" -eq 1 ]; then
  FAILS=0
  ok()  { echo "  [PASS] $*"; }
  bad() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

  [ -x "$STUB" ] || { echo "mech-judge.sh: mock stub not found/executable: $STUB" >&2; exit 3; }

  REQ_FIXTURE='{"lead":{"class":"C16","exploit":"the first depositor seeds one wei and donates assets so the next deposit mints zero shares","file":"src/StrategyFactory.sol","id":"L0","location":"src/StrategyFactory.sol:newStrategy:41","poc_sketch":"seed 1 wei, donate, deposit"},"rows":[{"sev_id":"S-1","signature":"first depositor inflates the share price"}]}'

  # (a) mock backend round-trip: a request in, well-formed verdict lines out.
  OUT="$(printf '%s' "$REQ_FIXTURE" | bash "$0" --backend mock 2>/dev/null)"
  if printf '%s\n' "$OUT" | grep -qE '^VERDICT\|L0\|S-1\|MATCH\|[0-9]+\|'; then
    ok "(a) the mock backend round-trips a request into well-formed VERDICT| lines"
  else
    bad "(a) mock backend produced no well-formed verdict line"
    printf '%s\n' "$OUT" | sed 's/^/         | /' | head -5
  fi

  # (b) the flat-cyborg PTY wrapper is the DEFAULT judging path and the metered print-mode API is never invoked
  #     (prose mentions of it in this header are ignored — only non-comment lines are inspected).
  if grep -q 'BACKEND="flat-cyborg"' "$0" && grep -q 'MECH_JUDGE_LLM_CMD' "$0" && grep -q 'flat-cyborg-claude.sh' "$0"; then
    ok "(b1) the flat-cyborg wrapper (MECH_JUDGE_LLM_CMD indirection) is the DEFAULT judging backend"
  else
    bad "(b1) the flat-cyborg wrapper is not wired as the default backend"
  fi
  if grep -vE '^[[:space:]]*#' "$0" | grep -qE 'claude[[:space:]]+-p'; then
    bad "(b2) this driver shells out to the metered print-mode API instead of the flat-cyborg wrapper"
  else
    ok "(b2) no metered print-mode API invocation — judging always goes through the flat-cyborg wrapper"
  fi

  # (c) a malformed reply must NOT be turned into a verdict: no MATCH is ever fabricated.
  MAL="$(printf '%s' "$REQ_FIXTURE" | MECH_JUDGE_STUB_MODE=malformed bash "$0" --backend mock 2>/dev/null)"
  if printf '%s' "$MAL" | grep -q 'MATCH'; then
    bad "(c) a malformed judge reply produced a verdict line (fabricated decision)"
    printf '%s\n' "$MAL" | sed 's/^/         | /' | head -5
  else
    ok "(c) a malformed judge reply yields NO verdict line (the caller counts it a JUDGE-ERROR, never a NO-MATCH)"
  fi

  echo
  if [ "$FAILS" -eq 0 ]; then
    echo "mech-judge.sh: PASS — request -> VERDICT| lines over the mock backend, flat-cyborg-only LLM path,"
    echo "mech-judge.sh:        and no fabricated MATCH from an unparseable reply."
    exit 0
  fi
  echo "mech-judge.sh: FAIL — $FAILS driver-contract assertion(s) regressed" >&2
  exit 1
fi

# ---- judge one request ---------------------------------------------------------------------------------------
REQ="$(cat)"
[ -n "$REQ" ] || { echo "mech-judge.sh: empty request on stdin" >&2; exit 2; }

if [ "$BACKEND" = "mock" ]; then
  [ -x "$STUB" ] || { echo "mech-judge.sh: mock stub not found/executable: $STUB" >&2; exit 3; }
  RAW="$(printf '%s' "$REQ" | "$STUB" 2>/dev/null)"
else
  [ -x "$WRAP" ] || { echo "mech-judge.sh: LLM wrapper not found/executable: $WRAP" >&2; exit 3; }
  export FLAT_CYBORG_IDLE_MS="${FLAT_CYBORG_IDLE_MS:-12000}"
  RAW="$("$WRAP" "$(build_prompt "$REQ")" 2>/dev/null)"
fi

# Forward ONLY the verdict lines. An unparseable reply forwards nothing — score-match.py then records a
# JUDGE-ERROR and, above --judge-max-error-rate, refuses to report a recall number at all.
printf '%s\n' "$RAW" | grep '^VERDICT|' || true
exit 0
