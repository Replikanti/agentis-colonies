#!/usr/bin/env bash
# demo-param-audit.sh — the gate for the #2245 iteration-5 OUTPUT-GATED PARAMETER AUDIT (knob PARAM_AUDIT=1).
#
# What the change is. Iteration 4 measured a GENERATION loss: the cell reached the function that admits the value
# and never listed that function's arguments, so the lead living in one of them was never written down. Per-shape
# class text did not change that, and a gate-less "check every argument" paragraph is the #2213 shape (Delta=+0).
# So iteration 5 gives generation the mechanism that worked on the dismissal side:
#   * an emission contract in hunter.ag — `PARAM|#k|<file:function>|<parameter>|<source>` per admitted value,
#     answered by `PARAM-TRACE|#k|bounded-at:<path>:<line>|...` or `PARAM-TRACE|#k|unbounded|...`;
#   * a deterministic OUTPUT gate in run-discovery.sh (four components: uncovered / unanswered / absent / open
#     lead), armed ONLY by the honesty-gated `PARAM-AUDIT|` sentinel;
#   * a STRICT bound contract: the cited range must CHECK the value and NAME the parameter — a role check never
#     bounds, a deploy script or a deployed value bounds nothing;
#   * ONE named re-ask (PARAM_REASK_ITEMS), run BEFORE the rubric gate;
#   * inside a rubric-ON cell only, PROMOTION of an unbounded lead that got neither a CANDIDATE nor a DISMISS
#     naming it to a tier-1 `Medium` candidate — one per location, never duplicating a rubric promotion.
# `PARAM_AUDIT=1` opts in; unset (the DEFAULT) leaves the prompt and the driver byte-identical. The knob is
# INDEPENDENT of SEVERITY_RUBRIC / GROUND_EVIDENCE / OPERATIONALIZE_LENS.
#
# Nothing asserted here is a recall claim — recall is the operator's pre-registered measurement.
#
# Eight parts. Parts 1-7 are the CI floor: pure grep/awk plus the SHIPPED shell functions sliced out of
# run-discovery.sh and an offline `--agentis` stub, so they need no agentis, no forge, no network and no LLM.
#   1) hunter.ag SOURCE-GUARD — the seven helpers, the marker/sentinel coupling, the `== "1"` polarity, the
#      ""-when-disabled gates, the rubric-gated lead rule, the splice order `+ rubric` -> `+ paudit` -> `+ extres`,
#      the grammar, the independence of the four knobs, and the token invariants.
#   2) WIRING — exec.env_passthrough + the cell env, the three record boundaries (and the shipped awk program over
#      a PTY-wrapped record), the cap pinned equal in agent and shell, the re-ask phrase table pinned against the
#      agent text in both directions, the path regex byte-identical to _dismiss_evidence_ok's, the gate order
#      inside run_cell, the non-`.log` suffixes, and the untouched refute side.
#   3) PURITY — overfitting + domain-noun denylists over the prompt-visible text (with a negative control) and
#      substrate purity of the new `.ag` code.
#   4) FIXTURES — the sliced gate over synthetic logs: every bound-contract branch both ways, id pairing, the
#      four components and their guards, and inertness without the sentinel.
#   5) PROMOTION — shape, the `Medium` cap, one per location, the rubric-promoted skip, the unresolvable drop,
#      and the candidate-cell guard.
#   6) END-TO-END through run-discovery.sh with an offline --agentis stub: re-ask + promotion, a compliant control,
#      knob-OFF byte-identity, DF_PARAM_MAX_REASKS=0, the enumeration-only arm (rubric off), and the gate ORDER
#      (param re-ask before the rubric re-ask, no duplicate promotion).
#   7) MUTATION RESISTANCE — five mutations of a COPY of the sliced functions, each of which must flip a fixture.
#   8) NEEDS agentis ([SKIP] otherwise) — the byte-identity probe over the helpers extracted from hunter.ag, and a
#      live mock hunt cell printing the sentinel only with the knob.
# Every detector has a NEGATIVE CONTROL: a guard that never fires is indistinguishable from one that cannot.
#
# Usage:  dark-factory/demo-param-audit.sh
# Exit: 0 = all assertions held; non-zero = a regression.
# Dash-safe fixtures: no $'...', literal glyphs only, printf with no \xHH escapes.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HUNTER="$HERE/auditor/agents/hunter.ag"
REFUTER="$HERE/auditor/agents/refuter.ag"
DISCOVERY="$HERE/run-discovery.sh"
REFUTE="$HERE/run-refute.sh"
VERIFY="$HERE/verify-findings.sh"

FAILS=0
note() { echo "demo-param-audit.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$HUNTER" "$REFUTER" "$DISCOVERY" "$REFUTE" "$VERIFY"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done

WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
# Never touch a live hunt registry: every driver run below gets its own throwaway state dir.
DARK_FACTORY_DIR="$WORK/df-state"; export DARK_FACTORY_DIR
mkdir -p "$DARK_FACTORY_DIR"

# The multi-line `"..." + "..."` joins are flattened, so an assertion matches the PROMPT text the model receives.
HUNTER_FLAT="$(tr '\n' ' ' < "$HUNTER" | sed 's/"[[:space:]]*+[[:space:]]*"//g')"

# _agfn <file> <fn> — one `.ag` helper, sliced by line range (never a copy that can drift).
_agfn() {
  awk -v want="^fn $2\\\\(" '$0 ~ want {f=1} f{print} f&&/^}$/{exit}' "$1"
}
# _shfn <file> <fn> — the same for a shell function.
_shfn() {
  sed -n "/^$2() {\$/,/^}\$/p" "$1"
}
# _flat <text> — the same `" + "` flattening, for one sliced helper.
_flat() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/"[[:space:]]*+[[:space:]]*"//g'
}

# ----------------------------------------------------------------------------------------------------------
# PART 1 — hunter.ag SOURCE-GUARD
# ----------------------------------------------------------------------------------------------------------
note "1) hunter.ag declares the seven iteration-5 helpers ..."
PA_FNS="param_audit_marker param_audit_cap param_audit_block param_lead_rule param_audit_enabled param_reask_block param_audit_directive"
MISS=""
for fn in $PA_FNS; do
  grep -q "^fn $fn(" "$HUNTER" || MISS="$MISS $fn"
done
if [ -z "$MISS" ]; then
  ok "all 7 marker/cap/block/lead-rule/toggle/re-ask/directive helpers are declared in hunter.ag"
else
  bad "hunter.ag is missing iteration-5 helper(s):$MISS"
fi

note "2) the marker is the block's literal FIRST LINE, and the sentinel is gated on it ..."
if _agfn "$HUNTER" param_audit_block | sed -n 2p | grep -q 'return param_audit_marker() + "\\n"'; then
  ok "param_audit_block() opens with param_audit_marker() — the sentinel greps a string that really renders"
else
  bad "param_audit_block() no longer opens with param_audit_marker() — the honesty-gated sentinel would stop firing"
fi
if grep -q 'if index_of(instruction, param_audit_marker()) >= 0 {' "$HUNTER" \
   && grep -q 'print("PARAM-AUDIT|" + subsystem + "|" + cls + "|on");' "$HUNTER"; then
  ok "PARAM-AUDIT| is printed only when the marker is demonstrably IN the prompt about to be sent"
else
  bad "the PARAM-AUDIT| sentinel is missing or no longer gated on index_of(instruction, param_audit_marker())"
fi
if grep -A2 'print("PARAM-AUDIT|" + subsystem' "$HUNTER" | grep -q 'param_audit_enabled()'; then
  bad "the PARAM-AUDIT| sentinel consults the toggle — it must be gated on the marker only (the honesty contract)"
else
  ok "the sentinel consults no toggle — a cell log cannot claim an audit that was not assembled"
fi

note "3) DEFAULT-OFF polarity and the \"\"-when-disabled gates ..."
if _agfn "$HUNTER" param_audit_enabled | grep -q 'getenv("PARAM_AUDIT") == "1"'; then
  ok "param_audit_enabled() is == \"1\" (unset / \"0\" / \"true\" are all OFF — the DEFAULT)"
else
  bad "param_audit_enabled() changed polarity — an unmeasured generation gate must not ship default-ON (#2191)"
fi
if _agfn "$HUNTER" param_audit_directive | grep -q 'if !param_audit_enabled() { return ""; }'; then
  ok "param_audit_directive() returns \"\" when the knob is off — concatenating it is a no-op"
else
  bad "param_audit_directive() lost its \"\"-when-disabled early return — the default prompt would change"
fi
if _agfn "$HUNTER" param_reask_block | grep -q 'if items == "" { return ""; }'; then
  ok "param_reask_block() is \"\" without PARAM_REASK_ITEMS — every FIRST attempt prompts identically"
else
  bad "param_reask_block() no longer short-circuits on an empty PARAM_REASK_ITEMS"
fi
if _agfn "$HUNTER" param_audit_directive | grep -qi 'code\|detector\|has_'; then
  bad "param_audit_directive() grew a payload/detector argument — the flag must stay the ONLY gate"
else
  ok "param_audit_directive() takes no payload and consults no detector — the flag is the only gate"
fi

note "4) the LEAD rule renders only inside a rubric-ON cell ..."
if _agfn "$HUNTER" param_lead_rule | grep -q 'if !severity_rubric_enabled() { return ""; }'; then
  ok "param_lead_rule() is \"\" unless severity_rubric_enabled() — PARAM_AUDIT=1 alone is the enumeration gate only"
else
  bad "param_lead_rule() is not gated on severity_rubric_enabled() — it would point at a DISMISS grammar the cell was never shown"
fi
if _agfn "$HUNTER" param_audit_directive | grep -q 'return param_audit_block() + param_lead_rule() + param_reask_block() + "\\n";'; then
  ok "param_audit_directive() reads block -> lead rule (rubric-gated) -> re-ask block"
else
  bad "param_audit_directive() changed its concatenation (block + lead rule + re-ask block)"
fi

note "5) the SPLICE ORDER: + rubric -> + paudit -> + extres ..."
L_RUB="$(grep -n '^  + rubric$' "$HUNTER" | head -1 | cut -d: -f1)"
L_PAU="$(grep -n '^  + paudit$' "$HUNTER" | head -1 | cut -d: -f1)"
L_EXT="$(grep -n '^  + extres$' "$HUNTER" | head -1 | cut -d: -f1)"
if [ -n "$L_RUB" ] && [ -n "$L_PAU" ] && [ -n "$L_EXT" ] && [ "$L_RUB" -lt "$L_PAU" ] && [ "$L_PAU" -lt "$L_EXT" ]; then
  ok "the audit sits after the rubric (its lead rule points at the DISMISS grammar) and before the resolver verb"
else
  bad "the audit's splice point moved (rubric=$L_RUB paudit=$L_PAU extres=$L_EXT)"
fi
if grep -q '^let paudit = param_audit_directive();$' "$HUNTER"; then
  ok "the directive is assembled once, at top level, beside the other conditional reads"
else
  bad "hunter.ag no longer assembles param_audit_directive() into a top-level 'paudit' binding"
fi

note "6) the grammar is stated verbatim (the driver parses exactly these shapes) ..."
GRAM_MISS=""
for g in 'PARAM|#<k>|<file:function>|<parameter as written>|<caller or role or config or derived>' \
         'PARAM-TRACE|#<k>|bounded-at:<path>:<line>[-<line>]|<the check at that line>' \
         'PARAM-TRACE|#<k>|unbounded|<the call or write that consumes it, and what an out-of-range value does there>'; do
  case "$HUNTER_FLAT" in *"$g"*) ;; *) GRAM_MISS="$GRAM_MISS [$g]" ;; esac
done
case "$HUNTER_FLAT" in *"answers NOTHING"*) ;; *) GRAM_MISS="$GRAM_MISS [answers NOTHING]" ;; esac
case "$HUNTER_FLAT" in *"An audit line is never itself a finding"*) ;; *) GRAM_MISS="$GRAM_MISS [never itself a finding]" ;; esac
if [ -z "$GRAM_MISS" ]; then
  ok "the PARAM| / PARAM-TRACE| grammar, the id-pairing rule and the never-a-finding clause are all in the prompt text"
else
  bad "the prompt grammar drifted from what the driver parses:$GRAM_MISS"
fi

note "7) the four knobs stay INDEPENDENT ..."
IND_BAD=""
_agfn "$HUNTER" param_audit_enabled | grep -q 'SEVERITY_RUBRIC\|GROUND_EVIDENCE\|OPERATIONALIZE_LENS' && IND_BAD="$IND_BAD param_audit_enabled"
for fn in severity_rubric_enabled ground_evidence_enabled operationalize_enabled; do
  _agfn "$HUNTER" "$fn" | grep -q 'PARAM_AUDIT' && IND_BAD="$IND_BAD $fn"
done
if [ -z "$IND_BAD" ]; then
  ok "no toggle reads another knob's env var — one knob, one delta per arm"
else
  bad "a toggle couples two knobs:$IND_BAD"
fi

note "8) TOKEN INVARIANTS: no audit token carries CANDIDATE|, SAFE or VERDICT| ..."
TOK_BAD=""
for tok in 'PARAM|' 'PARAM-TRACE|' 'PARAM-AUDIT|' 'PARAM-PROMOTED|' 'PARAM-DROPPED|' 'bounded-at:' 'unbounded'; do
  case "$tok" in *'CANDIDATE|'*|*'SAFE'*|*'VERDICT|'*) TOK_BAD="$TOK_BAD $tok" ;; esac
done
if [ -z "$TOK_BAD" ]; then
  ok "none of the audit tokens contains CANDIDATE|, SAFE or VERDICT| — lib/run-agent-validated.sh cannot false-accept a reply on them"
else
  bad "an audit token would false-accept a reply shape:$TOK_BAD"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 2 — WIRING
# ----------------------------------------------------------------------------------------------------------
note "9) exec.env_passthrough + the cell env carry both names (#1426: getenv() reads the SANITISED env) ..."
D_PASS="$(grep 'echo "exec.env_passthrough' "$DISCOVERY" | head -1)"
W_MISS=""
case "$D_PASS" in *PARAM_AUDIT*) ;; *) W_MISS="$W_MISS PARAM_AUDIT(passthrough)" ;; esac
case "$D_PASS" in *PARAM_REASK_ITEMS*) ;; *) W_MISS="$W_MISS PARAM_REASK_ITEMS(passthrough)" ;; esac
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
grep -q 'PARAM_AUDIT="${PARAM_AUDIT:-}"' "$DISCOVERY" || W_MISS="$W_MISS PARAM_AUDIT(env)"
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
grep -q 'PARAM_REASK_ITEMS="$rc_param_items"' "$DISCOVERY" || W_MISS="$W_MISS PARAM_REASK_ITEMS(env)"
if [ -z "$W_MISS" ]; then
  ok "both names are allowlisted AND exported into the hunter cell env — neither the opt-in nor the re-ask can be silently inert"
else
  bad "the iteration-5 wiring is incomplete (#1426):$W_MISS"
fi
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
if grep -q '^DF_PARAM_MAX_REASKS="${DF_PARAM_MAX_REASKS:-1}"$' "$DISCOVERY" \
   && grep -q 'case "$DF_PARAM_MAX_REASKS" in .*DF_PARAM_MAX_REASKS=1' "$DISCOVERY"; then
  ok "DF_PARAM_MAX_REASKS defaults to 1 and a garbage value falls back to 1 (0 = gate-only)"
else
  bad "DF_PARAM_MAX_REASKS is not validated like its two siblings"
fi

note "10) the three tokens are RECORD BOUNDARIES in _join_wrapped_candidates ..."
BOUNDARY_LINE="$(grep -n 'BLACKBOARD-/ ||' "$DISCOVERY" | head -1 | cut -d: -f2-)"
B_MISS=""
for b in 'PARAM-AUDIT\|' 'PARAM\|' 'PARAM-TRACE\|'; do
  case "$BOUNDARY_LINE" in *"$b"*) ;; *) B_MISS="$B_MISS $b" ;; esac
done
if [ -n "$BOUNDARY_LINE" ] && [ -z "$B_MISS" ]; then
  ok "_join_wrapped_candidates lists PARAM-AUDIT|, PARAM| and PARAM-TRACE| next to the sibling boundary tokens"
else
  bad "the boundary alternation is missing:$B_MISS"
fi
JWC_AWK="$WORK/join-wrapped.awk"
_shfn "$DISCOVERY" _join_wrapped_candidates | sed -n "/^  awk '\$/,/^  ' /p" | sed '1d; $d' > "$JWC_AWK"
if [ ! -s "$JWC_AWK" ]; then
  bad "could not extract the _join_wrapped_candidates awk program (reshaped?)"
else
  JB_BAD=""
  for tok in 'PARAM-AUDIT|vault|C1|on' 'PARAM|#1|Vault.sol:exit|amount|caller' 'PARAM-TRACE|#1|unbounded|forwarded as is'; do
    printf 'CANDIDATE|Vault.sol:exit:48|C1|Medium|the exit leg reverts|deploy a\n  stub and assert the revert\n%s\nSAFE\n' "$tok" > "$WORK/wrap.log"
    JOINED="$(awk -f "$JWC_AWK" "$WORK/wrap.log")"
    if [ "$(printf '%s\n' "$JOINED" | grep -c 'CANDIDATE|' || true)" != "1" ] || printf '%s\n' "$JOINED" | grep -q 'PARAM'; then
      JB_BAD="$JB_BAD ${tok%%|*}"
    fi
  done
  if [ -z "$JB_BAD" ]; then
    ok "each audit line closes an open PTY-wrapped CANDIDATE record instead of being glued into its PoC sketch"
  else
    bad "the shipped awk program glued an audit line into a candidate:$JB_BAD"
  fi
fi

note "11) the CAP is one number in the agent and in the shell ..."
AG_CAP="$(_agfn "$HUNTER" param_audit_cap | sed -n 's/^[[:space:]]*return \([0-9][0-9]*\);$/\1/p' | head -1)"
SH_CAP="$(_shfn "$DISCOVERY" _param_audit_cap | sed -n "s/^[[:space:]]*printf '%s\\\\n' \([0-9][0-9]*\)\$/\1/p" | head -1)"
if [ -n "$AG_CAP" ] && [ "$AG_CAP" = "$SH_CAP" ]; then
  ok "param_audit_cap() = _param_audit_cap = $AG_CAP"
else
  bad "the cap drifted between agent ($AG_CAP) and shell ($SH_CAP)"
fi
if _agfn "$HUNTER" param_audit_block | grep -q 'to_string(param_audit_cap())'; then
  ok "the block quotes the cap through param_audit_cap() — the number the model is told cannot drift from the one enforced"
else
  bad "param_audit_block() no longer renders the cap from param_audit_cap()"
fi

note "12) the re-ask phrase table and the agent text agree in BOTH directions ..."
BLOCK_FLAT="$(_flat "$(_agfn "$HUNTER" param_audit_block)")"
_shfn "$DISCOVERY" _param_requirement > "$WORK/req.sh"
# shellcheck disable=SC1090,SC1091  # sliced out of run-discovery.sh at runtime, by design
. "$WORK/req.sh"
# <failure-id>=<phrase that must sit in BOTH the requirement and the block> (one pair per line)
REQ_PAIRS='bound-cite-missing=path:line
bound-cite-missing=in code you were given
bound-cite-unresolved=in code you were given
bound-cite-deploy=deployment script
bound-cite-deploy=bounds nothing
bound-not-a-check=CHECK the value
bound-not-a-check=require/revert/assert
bound-not-a-check=min/max/clamp
bound-names-other=NAME the parameter
bound-names-other=WHO calls
bound-names-other=WHAT value is passed
bound-deployed-state=deployed value
bound-deployed-state=what the code ADMITS'
REQ_BAD=""
while IFS= read -r pair; do
  [ -n "$pair" ] || continue
  rid="${pair%%=*}"; phrase="${pair#*=}"
  case "$(_param_requirement "$rid")" in *"$phrase"*) ;; *) REQ_BAD="$REQ_BAD req:${rid}[$phrase]" ;; esac
  case "$BLOCK_FLAT" in *"$phrase"*) ;; *) REQ_BAD="$REQ_BAD block:[$phrase]" ;; esac
done <<EOF
$REQ_PAIRS
EOF
# Reverse direction: every failure id the decider can print has a pinned phrase above.
for rid in $(_shfn "$DISCOVERY" _param_bound_ok | grep -oE "printf 'bound-[a-z-]+" | sed "s/printf '//" | sort -u); do
  printf '%s\n' "$REQ_PAIRS" | grep -q "^$rid=" || REQ_BAD="$REQ_BAD unpinned:$rid"
done
if [ -z "$REQ_BAD" ]; then
  ok "every failure id the decider prints has a re-ask phrase, and every pinned phrase is in both the table and the prompt"
else
  bad "the re-ask table and the agent text disagree:$REQ_BAD"
fi

note "13) the bound decider's path regex is byte-identical to _dismiss_evidence_ok's ..."
PB_RE="$(_shfn "$DISCOVERY" _param_bound_ok | sed -n "s/^[[:space:]]*pb_pathline_re='\(.*\)'\$/\1/p")"
DE_RE="$(_shfn "$DISCOVERY" _dismiss_evidence_ok | sed -n "s/^[[:space:]]*de_pathline_re='\(.*\)'\$/\1/p")"
if [ -n "$PB_RE" ] && [ "$PB_RE" = "$DE_RE" ]; then
  ok "one citation shape for both output gates ($PB_RE)"
else
  bad "the path regexes drifted: pb='$PB_RE' de='$DE_RE'"
fi

note "14) the GATE ORDER inside run_cell: trace loop -> param loop -> rubric loop -> rubric promote -> param promote ..."
RC="$(_shfn "$DISCOVERY" run_cell)"
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
L_TR="$(printf '%s\n' "$RC" | grep -n '_all_checks_untraced "\$rc_log"; then' | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
L_PL="$(printf '%s\n' "$RC" | grep -n '_param_reask_needed "\$rc_log" "\$REPO"; do' | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
L_RL="$(printf '%s\n' "$RC" | grep -n '_rubric_reask_needed "\$rc_log" "\$REPO" "\$BRIEF"; do' | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
L_RP="$(printf '%s\n' "$RC" | grep -n '_rubric_promote "\$rc_log"' | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
L_PP="$(printf '%s\n' "$RC" | grep -n '_param_promote "\$rc_log"' | head -1 | cut -d: -f1)"
if [ -n "$L_TR" ] && [ -n "$L_PL" ] && [ -n "$L_RL" ] && [ -n "$L_RP" ] && [ -n "$L_PP" ] \
   && [ "$L_TR" -lt "$L_PL" ] && [ "$L_PL" -lt "$L_RL" ] && [ "$L_RL" -lt "$L_RP" ] && [ "$L_RP" -lt "$L_PP" ]; then
  ok "a DISMISS written for the param re-ask is judged by the unchanged rubric gate, and the param promotion sees the rubric's"
else
  bad "the gate order in run_cell moved (trace=$L_TR param=$L_PL rubric=$L_RL rubric-promote=$L_RP param-promote=$L_PP)"
fi
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
if grep -q 'param-attempt-\$rc_param"' "$DISCOVERY" && ! grep -q 'param-attempt-\$rc_param\.log' "$DISCOVERY" \
   && grep -q 'pp_out="\$pp_log.param-promoted"' "$DISCOVERY" && grep -q '"\$sc_log.param-audit.tsv"' "$DISCOVERY"; then
  ok "the attempt, sidecar and readout suffixes do NOT end in .log (one log per cell for every readout)"
else
  bad "an iteration-5 attempt/sidecar/readout file ends in .log or was renamed"
fi
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
if _shfn "$DISCOVERY" _param_promote | grep -q '>> "\$pp_out"' && ! _shfn "$DISCOVERY" _param_promote | grep -q '>> "\$pp_log"'; then
  ok "_param_promote writes only its sidecar — the cell log stays a pure model transcript"
else
  bad "_param_promote writes into the cell log"
fi
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
if _shfn "$DISCOVERY" _cell_candidates | grep -q '_param_promoted_candidates "\$1"' \
   && grep -q '\[ -s "\$sc_log.param-promoted" \]; then' "$DISCOVERY"; then
  ok "_cell_candidates unions the promoted records and scrape_cell_log's candidate guard sees the sidecar"
else
  bad "a promoted parameter lead could not reach \$REPORT / candidates[]"
fi

note "15) the refute side is untouched (refuter.ag, run-refute.sh, verify-findings.sh) ..."
UNT_BAD=""
for f in "$REFUTER" "$REFUTE" "$VERIFY"; do
  grep -q 'PARAM_AUDIT\|PARAM-AUDIT\|PARAM-TRACE\|_param_' "$f" && UNT_BAD="$UNT_BAD ${f##*/}"
done
if [ -z "$UNT_BAD" ]; then
  ok "no iteration-5 token reached the refute gate or the verifier — no new judge, no refuter change"
else
  bad "an iteration-5 token leaked into:$UNT_BAD"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 3 — PURITY
# ----------------------------------------------------------------------------------------------------------
note "16) OVERFITTING + DOMAIN-NOUN GUARD over the prompt-visible text ..."
PROMPT_TXT="$WORK/prompt-text.txt"
{
  _agfn "$HUNTER" param_audit_marker
  _agfn "$HUNTER" param_audit_block
  _agfn "$HUNTER" param_lead_rule
  _agfn "$HUNTER" param_reask_block
} > "$PROMPT_TXT"
DENY='Curve|Convex|Pendle|Balancer|Uniswap|Aave|Compound|useEth|use_eth|WETH|wrapNative|slot0|ERC-?[0-9]|\.sol'
GT_ID='(^|[^[:alnum:]_])[HM]-[0-9]{1,2}([^[:alnum:]_]|$)'
# The generic domain nouns the block must stay free of: it describes a METHOD, so an example noun would steer the
# hunt toward one shape (and could echo a held-out one).
NOUNS='(^|[^[:alnum:]_])(fee|fees|deadline|deadlines|chain|chains|bridge|bridges|deposit|deposits|buffer|buffers|duration|durations|lockup|lockups|rounding|oracle|oracles|pool|pools|token|tokens|slippage|price|prices)([^[:alnum:]_]|$)'
if [ ! -s "$PROMPT_TXT" ]; then
  bad "could not slice the iteration-5 prompt text out of hunter.ag"
elif grep -Eq "$DENY" "$PROMPT_TXT"; then
  bad "the audit text names a protocol/product/file specific"
  grep -nE "$DENY" "$PROMPT_TXT" | head -3 | sed 's/^/      /' >&2
elif grep -qi 'corpus-bench' "$PROMPT_TXT"; then
  bad "the audit text names the corpus (#2231)"
elif grep -EqI "$GT_ID" "$PROMPT_TXT"; then
  bad "the audit text carries a ground-truth finding id (#2233)"
elif grep -Eqi "$NOUNS" "$PROMPT_TXT"; then
  bad "the audit text carries a domain noun — the block must stay example-free"
  grep -nEi "$NOUNS" "$PROMPT_TXT" | head -3 | sed 's/^/      /' >&2
else
  ok "the audit text names no protocol, product, file, corpus, ground-truth id or domain noun (pure-meta)"
fi
# NEGATIVE CONTROL: the three detectors must fire on a planted hint (the GT id is composed at run time).
printf 'the Balancer pool charges a fee on Foo.sol and GT %s-9 confirms it\n' 'H' > "$WORK/planted.txt"
if grep -Eq "$DENY" "$WORK/planted.txt" && grep -EqI "$GT_ID" "$WORK/planted.txt" && grep -Eqi "$NOUNS" "$WORK/planted.txt"; then
  ok "the overfitting, ground-truth-id and domain-noun detectors all fire on a planted hint (negative control)"
else
  bad "a denylist detector does not fire on a planted hint — the guard is dead"
fi

note "17) substrate purity (#1587): the new .ag code is builtins-only ..."
PURE="$WORK/pure.txt"
awk '/--- #2245 iteration 5: OUTPUT-GATED PARAMETER AUDIT/{f=1} f&&/^\/\/ --- #2235 READ THE EXTERNAL PROTOCOL/{exit} f{print}' "$HUNTER" \
  | grep -v '^[[:space:]]*//' > "$PURE"
if [ ! -s "$PURE" ] || ! grep -q 'fn param_audit_block' "$PURE"; then
  bad "could not slice the iteration-5 block out of hunter.ag (header renamed?)"
elif grep -Eq 'exec sh|python3 -c|reduce\(|regex_' "$PURE"; then
  bad "the iteration-5 block introduced an embedded interpreter / regex / reduce"
else
  ok "the iteration-5 block uses only O(1) string concat and getenv (no exec sh, no regex/reduce, no per-element cost)"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 4 — THE GATE, FIXTURE-DRIVEN (the shipped functions, sliced — never copied)
# ----------------------------------------------------------------------------------------------------------
note "18) the shipped gate functions slice out of run-discovery.sh and load ..."
FNS="$WORK/gate-fns.sh"
{
  for fn in _count_stdin _ids_of_lines _check_ids _join_wrapped_candidates _dismiss_lines \
            _tier2_resolve_file _tier2_emit_loc; do
    _shfn "$DISCOVERY" "$fn"
  done
  grep -oE '^_param_[a-z_]+\(\) \{$' "$DISCOVERY" | sed 's/() {$//' | while IFS= read -r fn; do
    _shfn "$DISCOVERY" "$fn"
  done
} > "$FNS"
FNS_OK=1
for need in _param_audit_armed _param_bound_ok _param_rows _param_audit_gap _param_reask_needed _param_open_items \
            _param_promote _param_promoted_candidates _param_uncovered_fns _param_requested_fns _check_ids _tier2_emit_loc; do
  grep -q "^$need() {\$" "$FNS" || { FNS_OK=0; bad "could not slice $need out of run-discovery.sh"; }
done
if [ "$FNS_OK" -eq 1 ]; then
  # shellcheck disable=SC1090  # sliced out of run-discovery.sh at runtime, by design
  . "$FNS"
  ok "the iteration-5 gate functions (and the shipped helpers they reuse) extracted and sourced"
fi

# The fixture repository: one file whose line numbers the citations below point at.
FXR="$WORK/fx-repo"
mkdir -p "$FXR/contracts" "$FXR/script"
{
  printf '%s\n' '// SPDX-License-Identifier: MIT'
  printf '%s\n' 'pragma solidity ^0.8.20;'
  printf '%s\n' 'contract Counter {'
  printf '%s\n' '    uint256 public count;'
  printf '%s\n' '    uint256 public limit;'
  printf '%s\n' '    address public owner;'
  printf '%s\n' '    function increment(uint256 by) external {'
  printf '%s\n' '        require(by <= limit, "too much");'
  printf '%s\n' '        count += by;'
  printf '%s\n' '    }'
  printf '%s\n' '    function setLimit(uint256 newLimit) external onlyRole(KEEPER) {'
  printf '%s\n' '        require(msg.sender == owner, "auth");'
  printf '%s\n' '        limit = newLimit;'
  printf '%s\n' '    }'
  printf '%s\n' '    function add(uint256 by) external {'
  printf '%s\n' '        count += Math.min(by, limit);'
  printf '%s\n' '    }'
  printf '%s\n' '    function drain(uint256 amt) external {'
  printf '%s\n' '        count -= amt;'
  printf '%s\n' '    }'
  printf '%s\n' '}'
} > "$FXR/contracts/Counter.sol"
printf '%s\n' 'contract Deploy { function run() external { c.setLimit(100); require(true); } }' > "$FXR/script/Deploy.s.sol"
FXF="contracts/Counter.sol"

# _bo <label> <trace-line> <param> <root> <expected: ok|<fail-id>>
_bo() {
  _bo_got="$(_param_bound_ok "$2" "$3" "$4")" && _bo_got=ok
  if [ "$_bo_got" = "$5" ]; then ok "$1 -> $_bo_got"; else bad "$1 -> got '$_bo_got', want '$5'"; fi
}
if [ "$FNS_OK" -eq 1 ]; then
  note "19) the BOUND CONTRACT, every branch both ways ..."
  _bo "bounded-at a require that checks AND names the parameter" "PARAM-TRACE|#1|bounded-at:$FXF:8|require by <= limit" by "$FXR" ok
  _bo "bounded-at a min() call that names the parameter" "PARAM-TRACE|#1|bounded-at:$FXF:16|clamped to the limit" by "$FXR" ok
  _bo "a leading underscore on either side still names it" "PARAM-TRACE|#1|bounded-at:$FXF:8|require" _by "$FXR" ok
  _bo "ROLE CHECK: a require on the caller's identity" "PARAM-TRACE|#1|bounded-at:$FXF:12|only the owner may call" newLimit "$FXR" bound-names-other
  _bo "ROLE CHECK: a role modifier on the declaration line (the signature names the argument)" "PARAM-TRACE|#1|bounded-at:$FXF:11|role-gated" newLimit "$FXR" bound-names-other
  _bo "a range with no check at all" "PARAM-TRACE|#1|bounded-at:$FXF:19|subtracted" amt "$FXR" bound-not-a-check
  _bo "a check that names a DIFFERENT parameter" "PARAM-TRACE|#1|bounded-at:$FXF:8|require" amt "$FXR" bound-names-other
  _bo "no path:line in field 3" "PARAM-TRACE|#1|bounded-at:the setter|it is checked" by "$FXR" bound-cite-missing
  _bo "a cited file that does not exist" "PARAM-TRACE|#1|bounded-at:contracts/Nope.sol:8|require" by "$FXR" bound-cite-unresolved
  _bo "an absolute path" "PARAM-TRACE|#1|bounded-at:/etc/Counter.sol:8|require" by "$FXR" bound-cite-unresolved
  _bo "a .. segment" "PARAM-TRACE|#1|bounded-at:contracts/../contracts/Counter.sol:8|require" by "$FXR" bound-cite-unresolved
  _bo "a deployment script" "PARAM-TRACE|#1|bounded-at:script/Deploy.s.sol:1|set to 100 at deploy" newLimit "$FXR" bound-cite-deploy
  _bo "deployed-state wording on a real check" "PARAM-TRACE|#1|bounded-at:$FXF:8|as deployed the limit is small" by "$FXR" bound-deployed-state
  _bo "EMPTY root = citation-SHAPE only (documented, like _dismiss_evidence_ok)" "PARAM-TRACE|#1|bounded-at:contracts/Nope.sol:8|require" by "" ok
  _bo "EMPTY root still refuses an absolute path" "PARAM-TRACE|#1|bounded-at:/etc/Counter.sol:8|require" by "" bound-cite-unresolved

  SENT='PARAM-AUDIT|counter|C1|on'
  RUB='SEVERITY-RUBRIC|counter|C1|on'
  # _cl <name> <line...> — write a synthetic cell log and print its path.
  _cl() {
    _cl_path="$WORK/$1.log"; shift
    : > "$_cl_path"
    for _cl_line in "$@"; do printf '%s\n' "$_cl_line" >> "$_cl_path"; done
    printf '%s\n' "$_cl_path"
  }
  # _eq <label> <got> <want>
  _eq() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', want '$3'"; fi; }

  note "20) ID PAIRING (the #2223 rule: ids, never text) ..."
  L="$(_cl pair "$SENT" "PARAM|#1|$FXF:increment|by|caller" "PARAM|#2|$FXF:drain|amt|caller" \
        "PARAM-TRACE|#1|unbounded|a paraphrase that shares no words with the PARAM line" \
        "PARAM-TRACE|#9|unbounded|an answer to a number nobody listed" "SAFE")"
  _eq "a paraphrased answer pairs by id; an orphan #9 answers nothing, so #2 stays unanswered" "$(_param_unanswered_ids "$L" | tr '\n' ' ')" "2 "
  L="$(_cl malformed "$SENT" "PARAM|#1|$FXF:increment|by|caller" "PARAM-TRACE|#1|probably fine|looked at it" "SAFE")"
  _eq "a field 3 that is neither bounded-at: nor unbounded answers nothing" "$(_param_unanswered_ids "$L" | tr '\n' ' ')" "1 "
  L="$(_cl unnum "$SENT" "PARAM|#1|$FXF:increment|by|caller" "PARAM|$FXF:drain|amt|caller" "PARAM-TRACE|#1|unbounded|x" "SAFE")"
  _eq "an un-numbered PARAM line counts as a shortfall" "$(_param_unnumbered "$L")" "1"
  _eq "... and puts the cell's gap above zero" "$(_param_audit_gap "$L" "$FXR")" "1"

  note "21) COVERAGE: G1 from DISMISS| and CALLEE-VECTOR|, suspended at the cap; G3 on zero PARAM lines ..."
  L="$(_cl g1d "$SENT" "DISMISS|$FXF:drain:19|guard|$FXF:8 stops it" "PARAM|#1|$FXF:increment|by|caller" \
        "PARAM-TRACE|#1|bounded-at:$FXF:8|require" "SAFE")"
  _eq "an examined function (DISMISS|) with no PARAM line is uncovered" "$(_param_uncovered_fns "$L" | tr '\n' ' ')" "$FXF:drain "
  L="$(_cl g1c "$SENT" "CALLEE-VECTOR|drain|token|settable|dismissed: fixed" "PARAM|#1|$FXF:increment|by|caller" \
        "PARAM-TRACE|#1|bounded-at:$FXF:8|require" "SAFE")"
  _eq "an examined function (CALLEE-VECTOR|) with no PARAM line is uncovered" "$(_param_uncovered_fns "$L" | tr '\n' ' ')" "drain "
  L="$(_cl g1ok "$SENT" "DISMISS|$FXF:increment|guard|$FXF:8 stops it" "PARAM|#1|$FXF:increment|by|caller" \
        "PARAM-TRACE|#1|bounded-at:$FXF:8|require" "SAFE")"
  _eq "CONTROL: a covered, answered, bounded cell has gap 0" "$(_param_audit_gap "$L" "$FXR")" "0"
  if _param_reask_needed "$L" "$FXR"; then bad "the compliant control is re-asked"; else ok "the compliant control is never re-asked"; fi
  CAPL="$WORK/cap.log"
  { printf '%s\n' "$SENT" "DISMISS|$FXF:drain|guard|$FXF:8 stops it"
    i=1; while [ "$i" -le 21 ]; do
      printf 'PARAM|#%s|%s:increment|by|caller\n' "$i" "$FXF"
      printf 'PARAM-TRACE|#%s|bounded-at:%s:8|require\n' "$i" "$FXF"
      i=$((i + 1))
    done
    printf 'SAFE\n'; } > "$CAPL"
  _eq "G1 is SUSPENDED once all 20 ids are used" "$(_param_uncovered_fns "$CAPL" | _count_stdin)" "0"
  _eq "the id above the cap is counted, never audited" "$(_param_over_cap "$CAPL")" "1"
  _eq "... and _param_rows carries exactly the 20 in-cap ids" "$(_param_rows "$CAPL" "$FXR" | _count_stdin)" "20"
  L="$(_cl g3 "$SENT" "DISMISS|$FXF:drain|guard|$FXF:8 stops it" "SAFE")"
  _eq "G3: zero PARAM lines in a no-candidate cell (plus the uncovered DISMISS) opens the gate" "$(_param_audit_gap "$L" "$FXR")" "2"
  ITEMS="$(_param_open_items "$L" "$FXR" "$FXF@increment+drain+setLimit")"
  case "$ITEMS" in
    *"uncovered: $FXF:drain"*"no PARAM lines — functions given: increment, drain, setLimit"*)
      ok "the re-ask names the uncovered function and the functions this cell was given ($ITEMS)" ;;
    *) bad "the G1/G3 re-ask items are wrong: '$ITEMS'" ;;
  esac

  note "22) LEADS: G4 discharged by a DISMISS naming the parameter, open otherwise, inert without the rubric ..."
  LEAD_BASE="PARAM|#1|$FXF:drain|amt|caller"
  LEAD_TR="PARAM-TRACE|#1|unbounded|subtracted from the count with no floor"
  L="$(_cl g4dis "$SENT" "$RUB" "$LEAD_BASE" "$LEAD_TR" "DISMISS|$FXF:drain|guard|$FXF:8 caps amt" "SAFE")"
  _eq "a DISMISS at the same function whose evidence names the parameter discharges the lead" "$(_param_rows "$L" "$FXR" | cut -f6)" "dismiss"
  _eq "... so the gap is 0" "$(_param_audit_gap "$L" "$FXR")" "0"
  L="$(_cl g4k "$SENT" "$RUB" "$LEAD_BASE" "$LEAD_TR" "DISMISS|$FXF:drain|no-attacker|see #1 — nobody gains" "SAFE")"
  _eq "a DISMISS naming the lead's #k discharges it too" "$(_param_rows "$L" "$FXR" | cut -f6)" "dismiss"
  L="$(_cl g4open "$SENT" "$RUB" "$LEAD_BASE" "$LEAD_TR" "DISMISS|$FXF:drain|guard|$FXF:8 stops the caller" "SAFE")"
  _eq "a DISMISS at the same function about something else leaves the lead OPEN" "$(_param_rows "$L" "$FXR" | cut -f6)" "open"
  _eq "... and G4 counts it" "$(_param_open_leads "$L" "$FXR" | _count_stdin)" "1"
  L="$(_cl g4other "$SENT" "$RUB" "$LEAD_BASE" "$LEAD_TR" "DISMISS|$FXF:increment|guard|amt is fine here" "SAFE")"
  _eq "a DISMISS naming the parameter at a DIFFERENT function does not discharge it (G1 + G4)" "$(_param_audit_gap "$L" "$FXR")" "2"
  L="$(_cl g4dem "$SENT" "$RUB" "PARAM|#1|$FXF:setLimit|newLimit|role" "PARAM-TRACE|#1|bounded-at:$FXF:12|only the owner" "SAFE")"
  _eq "a DEMOTED bound (role check) is a lead exactly like an unbounded answer" "$(_param_rows "$L" "$FXR" | cut -f5,6 | tr '\t' ' ')" "demoted:bound-names-other open"
  ITEMS="$(_param_open_items "$L" "$FXR" "")"
  case "$ITEMS" in
    *"not bounded by the cited line: #1 (the cited check does not NAME the parameter"*) ok "the re-ask names the demoted id with its requirement phrase" ;;
    *) bad "the demoted-bound re-ask item is wrong: '$ITEMS'" ;;
  esac
  L="$(_cl g4norub "$SENT" "$LEAD_BASE" "$LEAD_TR" "SAFE")"
  _eq "G4 is INERT without SEVERITY-RUBRIC| (PARAM_AUDIT=1 alone = the enumeration gate only)" "$(_param_audit_gap "$L" "$FXR")" "0"
  L="$(_cl g4over "$SENT" "$RUB" "PARAM|#21|$FXF:drain|amt|caller" "PARAM-TRACE|#21|unbounded|x" "SAFE")"
  _eq "id 21 is never gated (no row, no lead) — only counted" "$(_param_rows "$L" "$FXR" | _count_stdin) $(_param_over_cap "$L")" "0 1"

  note "23) INERTNESS: the same logs without PARAM-AUDIT| are untouched ..."
  INERT_BAD=""
  for lg in g1d g3 g4open g4dem unnum; do
    grep -v '^PARAM-AUDIT|' "$WORK/$lg.log" > "$WORK/$lg-off.log"
    [ "$(_param_audit_gap "$WORK/$lg-off.log" "$FXR")" = "0" ] || INERT_BAD="$INERT_BAD $lg:gap"
    _param_reask_needed "$WORK/$lg-off.log" "$FXR" && INERT_BAD="$INERT_BAD $lg:reask"
    [ -z "$(_param_open_items "$WORK/$lg-off.log" "$FXR" "$FXF@drain")" ] || INERT_BAD="$INERT_BAD $lg:items"
    _param_promote "$WORK/$lg-off.log" C1 "$FXF" "$FXR"
    [ ! -e "$WORK/$lg-off.log.param-promoted" ] || INERT_BAD="$INERT_BAD $lg:promoted"
  done
  if [ -z "$INERT_BAD" ]; then
    ok "no sentinel => gap 0, no re-ask, no items, no sidecar — the gate reads the SENTINEL, never the env"
  else
    bad "the gate is not inert without its sentinel:$INERT_BAD"
  fi

  # ----------------------------------------------------------------------------------------------------------
  # PART 5 — PROMOTION
  # ----------------------------------------------------------------------------------------------------------
  note "24) PROMOTION: shape, Medium, one per location, rubric-promoted skip, unresolvable drop, candidate guard ..."
  L="$(_cl prom "$SENT" "$RUB" "PARAM|#1|$FXF:drain|amt|caller" "PARAM|#2|$FXF:drain|by|derived" \
        "PARAM-TRACE|#1|unbounded|subtracted | with no floor" "PARAM-TRACE|#2|unbounded|also unchecked" \
        "DISMISS|$FXF:drain|guard|$FXF:8 stops the caller" "SAFE")"
  _param_promote "$L" C1 "$FXF" "$FXR"
  PC="$(_param_promoted_candidates "$L")"
  if [ "$(printf '%s\n' "$PC" | grep -c 'CANDIDATE|' || true)" = "1" ]; then
    ok "two open leads at ONE location promote exactly ONE candidate"
  else
    bad "one location promoted $(printf '%s\n' "$PC" | grep -c 'CANDIDATE|' || true) candidates"
  fi
  if printf '%s\n' "$PC" | grep -q "^CANDIDATE|$FXF:drain|class=C1|Medium|amt (caller) reaches subtracted / with no floor with no bound in drain|PoC sketch: " \
     && [ "$(printf '%s\n' "$PC" | awk -F'|' '{ print NF }')" = "6" ]; then
    ok "the promoted record has the candidate shape (6 fields, class=, Medium, resolvable location, | scrubbed to /)"
  else
    bad "the promoted record's shape is wrong: $PC"
  fi
  if grep -q "^PARAM-PROMOTED|$FXF:drain|#1,#2|amt, by\$" "$L.param-promoted"; then
    ok "the provenance line lists every id and parameter at the location"
  else
    bad "the PARAM-PROMOTED provenance line is wrong: $(grep PARAM-PROMOTED "$L.param-promoted" 2>/dev/null)"
  fi
  _eq "_param_promoted_count" "$(_param_promoted_count "$L")" "1"
  printf 'RUBRIC-PROMOTED|%s:drain|no-attacker\nCANDIDATE|%s:drain|class=C1|Medium|x|y\n' "$FXF" "$FXF" > "$L.rubric-promoted"
  _param_promote "$L" C1 "$FXF" "$FXR"
  if [ -z "$(_param_promoted_candidates "$L")" ] && grep -q "^PARAM-DROPPED|$FXF:drain|rubric-promoted\$" "$L.param-promoted"; then
    ok "a location the rubric gate already promoted is SKIPPED (one lead per location across both gates) and recorded"
  else
    bad "the rubric-promoted location was promoted a second time"
  fi
  rm -f "$L.rubric-promoted"
  L="$(_cl promunres "$SENT" "$RUB" "PARAM|#1|Elsewhere.sol:mystery|amt|caller" "PARAM-TRACE|#1|unbounded|x" "SAFE")"
  _param_promote "$L" C1 "$FXF" "$FXR"
  if [ -z "$(_param_promoted_candidates "$L")" ] && grep -q '^PARAM-DROPPED|Elsewhere.sol:mystery|unresolved$' "$L.param-promoted"; then
    ok "a location outside the cell's file list is DROPPED and counted, never guessed"
  else
    bad "an unresolvable location was promoted (or not recorded)"
  fi
  L="$(_cl promcand "$SENT" "$RUB" "PARAM|#1|$FXF:drain|amt|caller" "PARAM-TRACE|#1|unbounded|x" \
        "CANDIDATE|$FXF:increment:8|C1|Medium|something else|poc" "SAFE")"
  _param_promote "$L" C1 "$FXF" "$FXR"
  if [ ! -e "$L.param-promoted" ] && ! _param_reask_needed "$L" "$FXR"; then
    ok "a cell with a model CANDIDATE is never re-asked and never promoted (its rows are still recorded)"
  else
    bad "a candidate cell was re-asked or promoted"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# PART 6 — END-TO-END through run-discovery.sh (offline --agentis stub, no LLM)
# ----------------------------------------------------------------------------------------------------------
# The stub replaces the SUBSTRATE, so this part tests the DRIVER half: gate, re-ask, promotion, JSON, report. It
# prints the sentinels itself, exactly as demo-severity-rubric.sh's stub does.
HSTUB="$WORK/agentis-hunt-stub"
cat > "$HSTUB" <<'STUBEOF'
#!/bin/sh
set -u
F=contracts/Counter.sol
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    if [ "${SEVERITY_RUBRIC:-}" = "1" ]; then printf 'SEVERITY-RUBRIC|%s|%s|on\n' "${SUBSYSTEM:-}" "${HUNT_CLASS:-}"; fi
    if [ "${PARAM_AUDIT:-}" = "1" ]; then printf 'PARAM-AUDIT|%s|%s|on\n' "${SUBSYSTEM:-}" "${HUNT_CLASS:-}"; fi
    if [ -n "${DISMISS_REASK_GROUNDS:-}" ]; then
      [ -n "${STUB_ORDER:-}" ] && printf 'rubric\n' >> "$STUB_ORDER"
      # The rubric re-ask holds its weak ground and no longer names the parameter: the lead re-opens on the final
      # log, so both gates would promote the SAME location unless the param gate skips it.
      printf 'DISMISS|%s:increment|no-attacker|nobody profits from it\n' "$F"
      printf 'PARAM|#1|%s:increment|by|caller\n' "$F"
      printf 'PARAM-TRACE|#1|unbounded|added to the running count with no ceiling\n'
      printf 'SAFE\n'; exit 0
    fi
    if [ -n "${PARAM_REASK_ITEMS:-}" ]; then
      [ -n "${STUB_ORDER:-}" ] && printf 'param\n' >> "$STUB_ORDER"
      [ -n "${STUB_REASK_LOG:-}" ] && printf '%s\n' "$PARAM_REASK_ITEMS" >> "$STUB_REASK_LOG"
      case "${STUB_PREASK:-lead}" in
        weak) printf 'DISMISS|%s:increment|no-attacker|by is caller-chosen but nobody gains\n' "$F" ;;
        *)    printf 'DISMISS|%s:increment|guard|%s:12 stops the caller\n' "$F" "$F" ;;
      esac
      printf 'PARAM|#1|%s:increment|by|caller\n' "$F"
      printf 'PARAM-TRACE|#1|unbounded|added to the running count with no ceiling\n'
      printf 'SAFE\n'; exit 0
    fi
    case "${STUB_PMODE:-noparam}" in
      compliant)
        printf 'DISMISS|%s:increment|guard|%s:8 rejects it outright\n' "$F" "$F"
        printf 'PARAM|#1|%s:increment|by|caller\n' "$F"
        printf 'PARAM-TRACE|#1|bounded-at:%s:8|require by <= limit\n' "$F" ;;
      lead)
        printf 'DISMISS|%s:increment|guard|%s:12 stops the caller\n' "$F" "$F"
        printf 'PARAM|#1|%s:increment|by|caller\n' "$F"
        printf 'PARAM-TRACE|#1|unbounded|added to the running count with no ceiling\n' ;;
      *)
        printf 'DISMISS|%s:increment|guard|%s:8 rejects it outright\n' "$F" "$F" ;;
    esac
    printf 'SAFE\n'
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$HSTUB"

# _hunt <label> — one offline hunt cell; prints the out dir.
_hunt() {
  _h_label="$1"
  _h_repo="$WORK/$_h_label-repo"; mkdir -p "$_h_repo/contracts"
  cp "$FXR/contracts/Counter.sol" "$_h_repo/contracts/Counter.sol"
  printf 'counter | C25 | contracts/Counter.sol@increment+setLimit\n' > "$WORK/$_h_label-scope.tsv"
  printf '# brief\nInvariants to break: the documented paths stay available.\nKnown issues to exclude: none.\n' \
    > "$WORK/$_h_label-brief.md"
  "$DISCOVERY" --repo "$_h_repo" --scope "$WORK/$_h_label-scope.tsv" --brief "$WORK/$_h_label-brief.md" \
    --only counter --classes C25 --backend mock --agentis "$HSTUB" --out "$WORK/$_h_label" \
    > "$WORK/$_h_label.out" 2>&1 || true
  printf '%s\n' "$WORK/$_h_label"
}
HCELL=run/hunt_counter_C25.log

note "25) end-to-end (a): no PARAM lines -> ONE param re-ask naming the function -> the unbounded lead is PROMOTED ..."
STUB_REASK_LOG="$WORK/reask-items.txt"; export STUB_REASK_LOG
SEVERITY_RUBRIC=1 PARAM_AUDIT=1 STUB_PMODE=noparam STUB_PREASK=lead _hunt pa > "$WORK/pa.dir"
PDIR="$(cat "$WORK/pa.dir")"
if [ -f "$PDIR/$HCELL.param-attempt-1" ] && [ ! -f "$PDIR/$HCELL.param-attempt-2" ] && [ -s "$PDIR/$HCELL.param-promoted" ]; then
  ok "exactly one param re-ask (superseded attempt kept as .param-attempt-1), then the surviving lead was promoted"
else
  bad "the end-to-end param re-ask/promotion did not happen as specified"
  tail -12 "$WORK/pa.out" | sed 's/^/      /' >&2
fi
if grep -q 'no PARAM lines — functions given: increment, setLimit' "$STUB_REASK_LOG" 2>/dev/null; then
  ok "PARAM_REASK_ITEMS reached the cell naming the functions it was given"
else
  bad "the re-ask addressing never reached the cell: '$(cat "$STUB_REASK_LOG" 2>/dev/null)'"
fi
if [ "$(find "$PDIR/run" -name 'hunt_*.log' | wc -l | tr -d ' ')" = "1" ]; then
  ok "exactly ONE hunt_*.log exists for the cell"
else
  bad "the cell produced $(find "$PDIR/run" -name 'hunt_*.log' | wc -l | tr -d ' ') hunt_*.log files"
fi
if grep -q 'Medium' "$PDIR/discovery-report.md" && grep -q 'increment' "$PDIR/discovery-report.md"; then
  ok "the promoted lead reached discovery-report.md as a Medium candidate row"
else
  bad "the promoted lead never reached discovery-report.md"
fi
PJSON="$PDIR/discovery-results.json"
KEY_MISS=""
for k in '"params":1' '"params_unbounded":1' '"param_promoted":1'; do
  grep -q "$k" "$PJSON" || KEY_MISS="$KEY_MISS $k"
done
grep -q '"candidates":\[".*Counter.sol:increment|class=C25|Medium' "$PJSON" || KEY_MISS="$KEY_MISS candidates[]"
if [ -z "$KEY_MISS" ]; then
  ok "the additive keys are present and the promoted record is inside candidates[] (it reaches STAGE 4 and the refute gate)"
else
  bad "a key or the promoted record is missing from the cell JSON:$KEY_MISS"
fi
if [ -s "$PDIR/$HCELL.param-audit.tsv" ] && [ "$(cut -f5,6 "$PDIR/$HCELL.param-audit.tsv" | tr '\t' ' ')" = "unbounded open" ]; then
  ok "the per-parameter readout <log>.param-audit.tsv records the lead (unbounded, open)"
else
  bad "the per-parameter readout is missing or wrong"
fi

note "26) end-to-end (b): a COMPLIANT cell is neither re-asked nor promoted ..."
SEVERITY_RUBRIC=1 PARAM_AUDIT=1 STUB_PMODE=compliant _hunt pb > "$WORK/pb.dir"
BDIR="$(cat "$WORK/pb.dir")"
if [ ! -f "$BDIR/$HCELL.param-attempt-1" ] && [ ! -s "$BDIR/$HCELL.param-promoted" ] \
   && grep -q '"params":1' "$BDIR/discovery-results.json" && ! grep -q 'params_unbounded\|param_promoted\|param_bound_failed' "$BDIR/discovery-results.json"; then
  ok "a covered, answered, genuinely bounded parameter costs nothing (params=1, no other key)"
else
  bad "the compliant control was re-asked, promoted, or mis-keyed"
fi

note "27) end-to-end (c): KNOB UNSET — the cell JSON is byte-identical, whatever the transcript carries ..."
STUB_PMODE=noparam _hunt pc1 > "$WORK/pc1.dir"
STUB_PMODE=lead _hunt pc2 > "$WORK/pc2.dir"
PARAM_AUDIT=0 STUB_PMODE=lead _hunt pc3 > "$WORK/pc3.dir"
C1D="$(cat "$WORK/pc1.dir")"; C2D="$(cat "$WORK/pc2.dir")"; C3D="$(cat "$WORK/pc3.dir")"
if cmp -s "$C1D/run/results-cells.jsonl" "$C2D/run/results-cells.jsonl" && cmp -s "$C1D/run/results-cells.jsonl" "$C3D/run/results-cells.jsonl"; then
  ok "PARAM lines with no sentinel (unset or PARAM_AUDIT=0) leave the cell JSON byte-identical to a transcript with none"
else
  bad "the knob-OFF cell JSON differs:"
  diff "$C1D/run/results-cells.jsonl" "$C2D/run/results-cells.jsonl" | head -4 | sed 's/^/      /' >&2
fi
OFF_BAD=""
for d in "$C1D" "$C2D" "$C3D"; do
  [ -e "$d/$HCELL.param-attempt-1" ] && OFF_BAD="$OFF_BAD attempt"
  [ -e "$d/$HCELL.param-promoted" ] && OFF_BAD="$OFF_BAD sidecar"
  [ -e "$d/$HCELL.param-audit.tsv" ] && OFF_BAD="$OFF_BAD readout"
  grep -q 'PARAM-AUDIT|' "$d/$HCELL" && OFF_BAD="$OFF_BAD sentinel"
done
if [ -z "$OFF_BAD" ]; then
  ok "knob off: no sentinel, no re-ask, no sidecar, no readout file"
else
  bad "the knob-OFF run is NOT inert:$OFF_BAD"
fi

note "28) end-to-end (d): DF_PARAM_MAX_REASKS=0 records and promotes, never re-asks ..."
DF_PARAM_MAX_REASKS=0 SEVERITY_RUBRIC=1 PARAM_AUDIT=1 STUB_PMODE=lead _hunt pd > "$WORK/pd.dir"
DDIR="$(cat "$WORK/pd.dir")"
if [ ! -f "$DDIR/$HCELL.param-attempt-1" ] && grep -q '^CANDIDATE|' "$DDIR/$HCELL.param-promoted" 2>/dev/null; then
  ok "gate-only mode: no re-ask, and the open lead is still promoted"
else
  bad "DF_PARAM_MAX_REASKS=0 re-asked, or did not promote"
fi

note "29) end-to-end (e): PARAM_AUDIT=1 ALONE is the enumeration gate only (rubric off: re-ask, never promotion) ..."
STUB_REASK_LOG="$WORK/reask-items-e.txt"; export STUB_REASK_LOG
PARAM_AUDIT=1 STUB_PMODE=noparam STUB_PREASK=lead _hunt pe > "$WORK/pe.dir"
EDIR="$(cat "$WORK/pe.dir")"
if [ -f "$EDIR/$HCELL.param-attempt-1" ] && [ ! -s "$EDIR/$HCELL.param-promoted" ] \
   && ! grep -q 'param_promoted' "$EDIR/discovery-results.json" && grep -q '"params_unbounded":1' "$EDIR/discovery-results.json"; then
  ok "the enumeration gap was re-asked, the unbounded answer is recorded, and nothing was promoted without the rubric"
else
  bad "the audit-only arm promoted a lead or skipped the enumeration re-ask"
fi

note "30) end-to-end (f): GATE ORDER — the param re-ask runs first, its DISMISS is then rubric-re-asked, one promotion ..."
STUB_ORDER="$WORK/order.txt"; export STUB_ORDER
SEVERITY_RUBRIC=1 PARAM_AUDIT=1 STUB_PMODE=noparam STUB_PREASK=weak _hunt pf > "$WORK/pf.dir"
FDIR="$(cat "$WORK/pf.dir")"
if [ "$(tr '\n' ' ' < "$STUB_ORDER" 2>/dev/null)" = "param rubric " ]; then
  ok "both loops fired, in order: param re-ask, then the rubric re-ask of the insufficient DISMISS it produced"
else
  bad "the re-ask order was '$(tr '\n' ' ' < "$STUB_ORDER" 2>/dev/null)', want 'param rubric'"
fi
unset STUB_ORDER
FCANDS="$(grep -o 'Counter.sol:increment|class=C25|Medium' "$FDIR/discovery-results.json" | wc -l | tr -d ' ')"
if [ -s "$FDIR/$HCELL.rubric-promoted" ] && [ "$FCANDS" = "1" ] \
   && grep -q '^PARAM-DROPPED|contracts/Counter.sol:increment|rubric-promoted$' "$FDIR/$HCELL.param-promoted"; then
  ok "the rubric gate promoted the location and the param gate SKIPPED it — exactly one Medium candidate"
else
  bad "the two gates did not share one promotion per location (candidates=$FCANDS)"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 7 — MUTATION RESISTANCE (each rule must be load-bearing)
# ----------------------------------------------------------------------------------------------------------
if [ "$FNS_OK" -eq 1 ]; then
  note "31) five mutations of a COPY of the sliced functions — each must flip a named fixture ..."
  ROLE_TR="PARAM-TRACE|#1|bounded-at:$FXF:12|only the owner"
  MIN_TR="PARAM-TRACE|#1|bounded-at:$FXF:16|clamped"
  UNARMED="$WORK/g1d-off.log"
  CANDL="$WORK/promcand.log"
  DEDUP="$WORK/mut-dedup.log"
  cp "$WORK/prom.log" "$DEDUP"
  printf 'RUBRIC-PROMOTED|%s:drain|no-attacker\n' "$FXF" > "$DEDUP.rubric-promoted"
  # _probe — the five fixture verdicts under whatever functions are currently defined, as one line.
  _probe() {
    _p1="$(_param_bound_ok "$ROLE_TR" newLimit "$FXR")" && _p1=ok
    _p2="$(_param_bound_ok "$MIN_TR" by "$FXR")" && _p2=ok
    _p3="$(_param_audit_gap "$UNARMED" "$FXR")"
    if _param_reask_needed "$CANDL" "$FXR"; then _p4=reask; else _p4=noreask; fi
    _param_promote "$DEDUP" C1 "$FXF" "$FXR"
    _p5="$(_param_promoted_count "$DEDUP")"
    printf 'role=%s min=%s unarmed-gap=%s cand=%s dedup=%s\n' "$_p1" "$_p2" "$_p3" "$_p4" "$_p5"
  }
  BASE="$(_probe)"
  if [ "$BASE" = "role=bound-names-other min=ok unarmed-gap=0 cand=noreask dedup=0" ]; then
    ok "control (unmutated): $BASE"
  else
    bad "the unmutated control is wrong: $BASE"
  fi
  GUARD_SET="$(_shfn "$DISCOVERY" _dismiss_evidence_ok | sed -n "s/^[[:space:]]*de_guard_re='\(.*\)'\$/\1/p")"
  # _mutate <label> <field-that-must-flip> <sed-or-grep program kind> <program>
  _mutate() {
    _m_file="$WORK/mut-$1.sh"
    case "$3" in
      grepv) grep -vF "$4" "$FNS" > "$_m_file" ;;
      sed)   sed "$4" "$FNS" > "$_m_file" ;;
    esac
    if cmp -s "$FNS" "$_m_file"; then bad "mutation '$1' did not apply (the targeted line moved?)"; return; fi
    # shellcheck disable=SC1090  # a mutated copy of the sliced functions, generated at runtime by design
    _m_got="$( . "$_m_file"; _probe )"
    _m_want="$(printf '%s\n' "$BASE" | tr ' ' '\n' | grep "^$2=")"
    _m_now="$(printf '%s\n' "$_m_got" | tr ' ' '\n' | grep "^$2=")"
    if [ "$_m_want" != "$_m_now" ]; then
      ok "mutation '$1' flips $2 ($_m_want -> $_m_now)"
    else
      bad "mutation '$1' flips NOTHING on $2 — the rule it removes is not load-bearing"
    fi
  }
  # shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
  _mutate drop-name-clause role grepv "printf 'bound-names-other"
  _mutate guard-token-set min sed "s/^  pb_check_re=.*/  pb_check_re='$(printf '%s' "$GUARD_SET" | sed 's/[\\&/]/\\&/g')'/"
  # shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
  _mutate drop-arming-check unarmed-gap grepv '_param_audit_armed "$pag_log" ||'
  _mutate drop-candidate-guard cand grepv "grep -q 'CANDIDATE|'; then return"
  # shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
  _mutate drop-rubric-skip dedup grepv 'RUBRIC-PROMOTED|$pp_final|'
fi

# ----------------------------------------------------------------------------------------------------------
# PART 8 — NEEDS agentis: the AGENT half (clean [SKIP] otherwise)
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  note "32-33) byte-identity probe + live-under-mock sentinel ..."
  skip "no agentis binary on PATH — the extracted-helper probe and the real mock hunt cell cannot run"
else
  note "32) byte-identity probe: param_audit_directive() is 0 bytes under EVERY other-knob combination when unset ..."
  FRAG="$WORK/param.frag"; : > "$FRAG"
  FRAG_MISS=""
  for fn in severity_rubric_enabled $PA_FNS; do
    _agfn "$HUNTER" "$fn" >> "$FRAG"; printf '\n' >> "$FRAG"
    grep -q "^fn $fn(" "$FRAG" || FRAG_MISS="$FRAG_MISS $fn"
  done
  if [ -n "$FRAG_MISS" ]; then
    bad "could not extract the helpers from hunter.ag by line range:$FRAG_MISS"
  else
    SB="$WORK/probe"; mkdir -p "$SB"
    ( cd "$SB" && agentis init >/dev/null 2>&1 ) || true
    printf 'exec.env_passthrough = PARAM_AUDIT,PARAM_REASK_ITEMS,SEVERITY_RUBRIC,GROUND_EVIDENCE,OPERATIONALIZE_LENS\n' > "$SB/.agentis/config"
    {
      printf 'cb 300000;\n\n'
      cat "$FRAG"
      printf 'print("BLOCKLEN=" + to_string(len(param_audit_block())));\n'
      printf 'print("LEADLEN=" + to_string(len(param_lead_rule())));\n'
      printf 'print("DIRLEN=" + to_string(len(param_audit_directive())));\n'
    } > "$SB/probe.ag"
    # _pl <KEY> <env assignments...> — one probe value under the given env (everything else unset).
    _pl() {
      _pl_k="$1"; shift
      _pl_v="$( cd "$SB" && env -u PARAM_AUDIT -u PARAM_REASK_ITEMS -u SEVERITY_RUBRIC -u GROUND_EVIDENCE -u OPERATIONALIZE_LENS "$@" agentis go probe.ag 2>&1 | grep "^$_pl_k=" | tail -1 )"  # no-pii: length-only probe, no prompt()
      printf '%s\n' "${_pl_v#"$_pl_k"=}"
    }
    BLOCK_LEN="$(_pl BLOCKLEN)"
    LEAD_LEN="$(_pl LEADLEN SEVERITY_RUBRIC=1)"
    case "$BLOCK_LEN" in
      ''|*[!0-9]*|0) bad "the probe did not complete or the block is empty (BLOCKLEN='$BLOCK_LEN')" ;;
      *) ok "the audit block is $BLOCK_LEN bytes and the lead rule $LEAD_LEN bytes (the MEASURED prompt cost, printed rather than assumed)" ;;
    esac
    ZERO_BAD=""
    for sr in "" SEVERITY_RUBRIC=1; do
      for ge in "" GROUND_EVIDENCE=1; do
        for ol in "" OPERATIONALIZE_LENS=1; do
          for pa in "" PARAM_AUDIT=0 PARAM_AUDIT=true; do
            # shellcheck disable=SC2086  # the empty members must vanish, the set ones must split into env words
            _d="$(_pl DIRLEN PARAM_REASK_ITEMS=x $sr $ge $ol $pa)"
            [ "$_d" = "0" ] || ZERO_BAD="$ZERO_BAD [$sr $ge $ol $pa -> $_d]"
          done
        done
      done
    done
    if [ -z "$ZERO_BAD" ]; then
      ok "knob unset/0/true: the directive is 0 bytes under all 24 combinations of the other three knobs (with a populated PARAM_REASK_ITEMS) — the assembled instruction is byte-identical"
    else
      bad "a knob-OFF combination rendered audit bytes:$ZERO_BAD"
    fi
    DIR_ALONE="$(_pl DIRLEN PARAM_AUDIT=1)"
    DIR_RUB="$(_pl DIRLEN PARAM_AUDIT=1 SEVERITY_RUBRIC=1)"
    LEAD_OFF="$(_pl LEADLEN PARAM_AUDIT=1)"
    if [ "$DIR_ALONE" = "$((BLOCK_LEN + 1))" ] && [ "$LEAD_OFF" = "0" ]; then
      ok "PARAM_AUDIT=1 alone renders the block only ($DIR_ALONE bytes) — the lead rule is ABSENT with the rubric off"
    else
      bad "PARAM_AUDIT=1 alone rendered $DIR_ALONE bytes (want $((BLOCK_LEN + 1))), lead rule $LEAD_OFF bytes (want 0)"
    fi
    if [ "$DIR_RUB" = "$((BLOCK_LEN + LEAD_LEN + 1))" ] && [ "$LEAD_LEN" -gt 0 ] 2>/dev/null; then
      ok "PARAM_AUDIT=1 + SEVERITY_RUBRIC=1 adds exactly the lead rule ($DIR_RUB bytes)"
    else
      bad "the rubric-ON directive is $DIR_RUB bytes (want $((BLOCK_LEN + LEAD_LEN + 1)))"
    fi
  fi

  note "33) live-under-mock: the sentinel fires with PARAM_AUDIT=1 and is ABSENT by default ..."
  _mock() {
    _m_label="$1"
    _m_repo="$WORK/$_m_label-repo"; mkdir -p "$_m_repo/contracts"
    cp "$FXR/contracts/Counter.sol" "$_m_repo/contracts/Counter.sol"
    printf 'counter | C25 | contracts/Counter.sol\n' > "$WORK/$_m_label-scope.tsv"
    printf '# brief\nInvariants to break: the documented paths stay available.\nKnown issues to exclude: none.\n' \
      > "$WORK/$_m_label-brief.md"
    "$DISCOVERY" --repo "$_m_repo" --scope "$WORK/$_m_label-scope.tsv" --brief "$WORK/$_m_label-brief.md" \
      --only counter --classes C25 --backend mock --agentis agentis --out "$WORK/$_m_label" \
      > "$WORK/$_m_label.out" 2>&1 || true
    printf '%s\n' "$WORK/$_m_label/run/hunt_counter_C25.log"
  }
  M_ON="$(PARAM_AUDIT=1 _mock mock-on)"
  M_OFF="$(_mock mock-off)"
  if [ ! -f "$M_ON" ] || [ ! -f "$M_OFF" ]; then
    bad "the mock hunt cells produced no cell log (run-discovery.sh did not reach hunter.ag)"
    tail -5 "$WORK/mock-on.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    if grep -q '^PARAM-AUDIT|counter|C25|on$' "$M_ON"; then
      ok "PARAM_AUDIT=1: the sentinel fired end-to-end (run-discovery.sh -> env_passthrough -> hunter.ag getenv -> index_of(instruction, marker))"
    else
      bad "PARAM_AUDIT=1: NO PARAM-AUDIT| sentinel — the opt-in did not reach hunter.ag (env_passthrough gap?)"
    fi
    if grep -q 'PARAM-AUDIT|' "$M_OFF"; then
      bad "default (env unset): a PARAM-AUDIT| sentinel appeared — the audit is NOT default-OFF"
    else
      ok "default (env unset): NO PARAM-AUDIT| sentinel — the audit is opt-in"
    fi
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "ALL ASSERTIONS HELD — the #2245 iteration-5 parameter audit is wired, output-gated, independent and default OFF."
  note "NOTE: nothing above is a recall claim; that is the operator's pre-registered measurement."
  exit 0
fi
note "$FAILS assertion(s) FAILED"
exit 1
