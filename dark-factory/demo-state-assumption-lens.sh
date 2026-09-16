#!/usr/bin/env bash
# demo-state-assumption-lens.sh — OFFLINE, DETERMINISTIC source-guard for the STATE-ASSUMPTION lens (#2218):
# one new bug class, C24, for the shape the #2213 corpus forensics clustered the pure GENERATION misses into
# — a value written or DEFINED at touchpoint A is consumed at touchpoint B as if nothing changed in between.
#
#   C24 — Stale state assumption between touchpoints: an accrual index / rate snapshot reused across the
#         interval it was supposed to price, an emission carried per unit of a supply that is floored
#         elsewhere, a request/cooldown state that blocks the user's remedy while a third party's
#         liquidation/valuation path stays live, a price cached in memory and reused after an external call.
#
# The lens IS the taxonomy section (hunter.ag slices `## <cls> ` out of auditor/bug-taxonomy.md and builds the
# cell prompt from it) plus a deterministic zone-mapper route. hunter.ag itself is NOT touched — a pure-meta
# directive block in the hunter is the shape that measured Delta=+0 in #2213, and it cannot be routed per zone.
# So this demo is a source-guard, and it guards the things that can silently rot:
#   1. the ANTI-CATCH-ALL contract — C24 carries its `NOT this class` list (naming the neighbour classes it
#      must not absorb), its FOUR-part required-evidence rule, both mechanism flavours (TIME gap + DEFINITION
#      gap) and both named sub-shapes (closed-form, blocked-remedy). A class whose hunt collapses to "verify
#      every assumption" fires on every zone and burns the cell budget (#1830).
#   2. the `class_section()` EXTRACTION anchor — hunter.ag slices with `index($0,"## "c" ")==1`, so `C2` must
#      not swallow `C22`/`C23`/`C24` and the `C23` slice must stop before `## C24`. This runs that exact awk
#      against the real file: it is the one way this change could silently break an already-working lens.
#   3. the two DELIBERATE non-changes — no `class_to_keyword()` entry for C24 in invariant-prover.ag (that map
#      routes the depth/metamorphic action menu, an unmeasured second variable; C22/C23 have no entry either),
#      and no `C24`/`state_assumption` token in hunter.ag. Pinned as DECISIONS, so a later "while I'm here"
#      edit has to argue with a failing test instead of silently widening the measurement.
#   4. the zone-mapper ROUTE — the deterministic C24 net + its force-include + the STALE-STATE| diagnostic +
#      the ONLY-WHEN-shaped detection rule (demo-map-zones.sh owns the behavioural half: TRUE/FALSE fixtures,
#      chain order, prompt-leak and append-once).
#
# This demo proves the MACHINERY and the TEXT, never the capability: whether C24 actually recovers a rare row
# is #2218 M2's zone-restricted re-hunt measurement on the frozen corpus bases, an operator step, not CI.
#
# Usage:  dark-factory/demo-state-assumption-lens.sh
# Requires: awk + grep (the floor — no agentis, no forge, no network, CI-safe).
# Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TAXONOMY="$HERE/auditor/bug-taxonomy.md"
MAPPER="$HERE/auditor/agents/zone-mapper.ag"
HUNTER="$HERE/auditor/agents/hunter.ag"
PROVER="$HERE/auditor/agents/invariant-prover.ag"

FAILS=0
note() { echo "demo-state-assumption-lens.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -f "$TAXONOMY" ] || { note "bug-taxonomy.md not found: $TAXONOMY" >&2; exit 3; }
[ -f "$MAPPER" ]   || { note "zone-mapper.ag not found: $MAPPER" >&2; exit 3; }
[ -f "$HUNTER" ]   || { note "hunter.ag not found: $HUNTER" >&2; exit 3; }
[ -f "$PROVER" ]   || { note "invariant-prover.ag not found: $PROVER" >&2; exit 3; }

# hunter.ag's own class_section() awk anchor, verbatim in shape: take the `## <cls> ` section and stop at the
# next `## ` header that is not this class.
class_section() {
  awk -v c="$1" 'index($0,"## "c" ")==1{f=1} f&&index($0,"## ")==1&&index($0,"## "c" ")!=1{exit} f{print}' \
    "$TAXONOMY" 2>/dev/null
}

# ----------------------------------------------------------------------------------------------------------
# (a) The taxonomy declares C24 as a top-level section (what class_section() anchors on).
# ----------------------------------------------------------------------------------------------------------
note "1) bug-taxonomy.md declares the C24 class header ..."
if grep -q '^## C24 ' "$TAXONOMY"; then
  ok "bug-taxonomy.md declares the '## C24 ' class header"
else
  bad "bug-taxonomy.md missing the '## C24 ' class header"
fi

# ----------------------------------------------------------------------------------------------------------
# (b) ANTI-CATCH-ALL contract: the guard headers, the FOUR-part evidence rule, and the enumerate instruction.
#     Asserted as TEXT so the guards cannot be quietly deleted while the class stays declared.
# ----------------------------------------------------------------------------------------------------------
note "2) C24 carries its NOT-this-class + four-part required-evidence guards and the enumeration instruction ..."
C24="$(class_section C24)"
miss=""
case "$C24" in *"**NOT this class:**"*) ;; *) miss="$miss [NOT this class]" ;; esac
case "$C24" in *"**required evidence (else report SAFE):**"*) ;; *) miss="$miss [required evidence]" ;; esac
case "$C24" in *"enumerate, do not intuit"*) ;; *) miss="$miss [enumerate, do not intuit]" ;; esac
case "$C24" in *"(i)"*) ;; *) miss="$miss [(i)]" ;; esac
case "$C24" in *"(ii)"*) ;; *) miss="$miss [(ii)]" ;; esac
case "$C24" in *"(iii)"*) ;; *) miss="$miss [(iii)]" ;; esac
case "$C24" in *"(iv)"*) ;; *) miss="$miss [(iv)]" ;; esac
if [ -z "$miss" ]; then
  ok "C24 carries NOT-this-class, the FOUR-part required-evidence contract, and the enumeration instruction"
else
  bad "C24 is missing its anti-catch-all guards:$miss"
fi

# The NOT-this-class list must NAME the neighbour classes C24 would otherwise absorb. Without them the class
# degenerates into "every bug is a stale assumption" and re-labels work the other lenses already do.
note "3) the NOT-this-class list names every neighbour class C24 must not absorb ..."
nb_miss=""
for k in C2 C9 C22 C23 C8 C21 C6 C10; do
  case "$C24" in *"($k"*) ;; *) nb_miss="$nb_miss [$k]" ;; esac
done
if [ -z "$nb_miss" ]; then
  ok "C24 disambiguates itself against C2/C9/C22/C23/C8/C21/C6/C10"
else
  bad "C24's NOT-this-class list lost a neighbour class:$nb_miss"
fi

# Both MECHANISM flavours and both named SUB-SHAPES: the class is a DOMAIN description, and these four names
# are what keep it from collapsing into a "be more thorough" meta-directive (the #2213 measured null shape).
note "4) both mechanism flavours and both named sub-shapes survive ..."
sh_miss=""
for k in "TIME gap" "DEFINITION gap" "closed-form" "blocked-remedy"; do
  case "$C24" in *"$k"*) ;; *) sh_miss="$sh_miss [$k]" ;; esac
done
if [ -z "$sh_miss" ]; then
  ok "C24 names both flavours (TIME gap / DEFINITION gap) and both sub-shapes (closed-form / blocked-remedy)"
else
  bad "C24 lost a mechanism flavour or sub-shape:$sh_miss"
fi

# The hunt must ask for the two TOUCHPOINTS, the one-sentence assumption, the falsifier and the re-read
# question — named, countable artefacts, not "the assumptions".
note "5) the hunt enumerates the NAMED artefacts (two touchpoints, assumption, falsifier, re-read) ..."
h_miss=""
for k in "two touchpoints" "ONE sentence" "FALSIFY" "permissionless entrypoint" "RE-READS"; do
  case "$C24" in *"$k"*) ;; *) h_miss="$h_miss [$k]" ;; esac
done
if [ -z "$h_miss" ]; then
  ok "C24's hunt enumerates the two touchpoints, the one-sentence assumption, the falsifiers and the re-read question"
else
  bad "C24 hunt lost an enumeration target:$h_miss"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) EXTRACTION PIN: hunter.ag's `## <cls> ` awk anchor over the REAL taxonomy. C2 must not swallow
#     C22/C23/C24, and the C23 slice must stop before `## C24` (the prefix-collision risk this change adds).
# ----------------------------------------------------------------------------------------------------------
note "6) class_section() extraction pin: C2 / C22 / C23 / C24 slice cleanly ..."
# shellcheck disable=SC2016  # matched VERBATIM against hunter.ag's source (an awk anchor inside an exec-sh string)
if grep -qF 'index($0,\"## \"c\" \")==1' "$HUNTER"; then
  ok "hunter.ag still slices the taxonomy with the '## <cls> ' anchor this test replicates"
else
  bad "hunter.ag's class_section() anchor changed — this extraction pin no longer guards the real code path"
fi
for c in C2 C22 C23 C24; do
  if [ -n "$(class_section "$c")" ]; then
    ok "class_section($c) returns a non-empty slice"
  else
    bad "class_section($c) returned an EMPTY slice — the class is unreachable from hunter.ag"
  fi
done
case "$(class_section C2)" in
  *"## C24"*) bad "the C2 slice swallowed the C24 section (prefix collision)" ;;
  *) ok "the C2 slice does not contain '## C24' (C2's own lens is intact)" ;;
esac
case "$(class_section C23)" in
  *"## C24"*) bad "the C23 slice ran past its own section into C24" ;;
  *) ok "the C23 slice stops before '## C24'" ;;
esac
case "$C24" in
  *"## C23"*) bad "the C24 slice ran backwards into C23" ;;
  *) ok "the C24 slice contains only its own class text" ;;
esac

# The routing note hunter/zone-mapper authors read first must mention C24, else the class is invisible to a
# human extending the taxonomy.
note "7) the Hunter usage notes route a stale-state zone to C24 ..."
if grep -q 'CONSUMES it at a LATER point for a decision without re-reading it → C24' "$TAXONOMY"; then
  ok "the Hunter usage notes carry the C24 routing clause"
else
  bad "the Hunter usage notes lost the C24 routing clause"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) The two DELIBERATE non-changes, pinned as decisions rather than omissions.
# ----------------------------------------------------------------------------------------------------------
note "8) deliberate non-changes: hunter.ag untouched, no class_to_keyword() entry for C24 ..."
if grep -qE 'C24|state_assumption' "$HUNTER"; then
  bad "hunter.ag gained a C24 / state_assumption token — the lens is the taxonomy section, not a hunter directive block (the #2213 pure-meta shape measured Delta=+0)"
else
  ok "hunter.ag carries no C24 / state_assumption token (the class reaches the cell through the taxonomy menu only)"
fi
if grep -q 'class_to_keyword' "$PROVER"; then
  if grep -qE 'class_is\(k, "c24"\)' "$PROVER"; then
    bad "invariant-prover.ag gained a class_to_keyword() entry for C24 — that re-routes the depth/metamorphic action menu, an unmeasured second variable (C22/C23 have no entry either)"
  else
    ok "invariant-prover.ag's class_to_keyword() has no C24 entry (C24 falls through to the generic default, like C22/C23)"
  fi
else
  bad "invariant-prover.ag no longer defines class_to_keyword() — this decision pin no longer guards anything"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) The zone-mapper ROUTE: the deterministic net, its force-include, the diagnostic line, and the
#     ONLY-WHEN-shaped detection rule with its explicit escape clause. (demo-map-zones.sh owns the
#     behavioural half — TRUE/FALSE fixtures, chain order, prompt-leak, append-once.)
# ----------------------------------------------------------------------------------------------------------
note "9) zone-mapper.ag carries the deterministic C24 net, its force-include and the STALE-STATE| diagnostic ..."
net_miss=""
for f in has_accrual_update_surface has_emission_per_supply_surface has_request_gated_solvency_surface \
         contains_state_assumption_signal apply_state_assumption_backstop; do
  grep -q "fn $f" "$MAPPER" || net_miss="$net_miss [$f]"
done
grep -q 'force_include(classesCsv, "C24")' "$MAPPER" || net_miss="$net_miss [force_include C24]"
grep -q '"STALE-STATE|"' "$MAPPER" || net_miss="$net_miss [STALE-STATE| diagnostic]"
if [ -z "$net_miss" ]; then
  ok "zone-mapper.ag defines the three C24 nets, contains_state_assumption_signal, apply_state_assumption_backstop -> force_include C24, and the STALE-STATE| line"
else
  bad "zone-mapper.ag is missing part of the #2218 C24 route:$net_miss"
fi

note "10) the C24 detection rule is ONLY-WHEN shaped and carries its do-NOT-add escape ..."
# The instruction is a multi-line `"..." + "..."` concatenation, so a sentence can straddle two source lines.
# Slice the PROMPT region (`let instruction =` .. the `prompt(` call) and flatten the string joins, so every
# assertion below is about the text the model actually receives — never about the file's comments.
MAPPER_FLAT="$(awk '/^let instruction =/{f=1} f{print} /let verdict = prompt\(/{exit}' "$MAPPER" \
  | tr '\n' ' ' | sed 's/"[[:space:]]*+[[:space:]]*"//g')"
rule_hit=1
case "$MAPPER_FLAT" in *"STALE STATE ASSUMPTION BETWEEN TOUCHPOINTS DETECTION RULE (C24)"*) ;; *) rule_hit=0 ;; esac
case "$MAPPER_FLAT" in *"INCLUDE \`C24\` (stale state assumption between touchpoints) ONLY WHEN"*) ;; *) rule_hit=0 ;; esac
case "$MAPPER_FLAT" in *"do NOT add C24"*) ;; *) rule_hit=0 ;; esac
if [ "$rule_hit" -eq 1 ]; then
  ok "zone-mapper.ag has the C24 detection rule, its ONLY-WHEN gate and its 'do NOT add C24' escape clause"
else
  bad "zone-mapper.ag missing the C24 detection rule, its ONLY-WHEN gate or its 'do NOT add C24' escape clause"
fi
# The rule must stay a CLASS description: no contest name, no fixture name, no ground-truth row id may leak
# into the prompt (that would make the measurement a memorisation test rather than a lens test).
if printf '%s' "$MAPPER_FLAT" | grep -qiE 'yieldoor|notional|staleindex|freshindex|GT M-'; then
  bad "a contest/fixture/ground-truth identifier leaked into the zone-mapper PROMPT — the detection rules must describe the CLASS, never the corpus rows they were derived from"
else
  ok "no contest/fixture/ground-truth identifier appears in the zone-mapper prompt (the rules describe classes, not the corpus)"
fi
# The net helper names are POST-classification machinery: they must never reach the prompt, or a zone on
# which the net does not fire would no longer get the byte-identical instruction its verdict was measured on.
if printf '%s' "$MAPPER_FLAT" | grep -qE 'state_assumption|STALE-STATE\|'; then
  bad "a C24 net helper name leaked into the zone-mapper PROMPT (the net is post-classification only)"
else
  ok "no C24 net helper name appears in the zone-mapper prompt (the net stays post-classification only)"
fi
if grep -q 'pick the 1-4 that genuinely fit' "$MAPPER"; then
  ok "zone-mapper.ag still caps the LLM class list at 1-4 per zone (#1830 cell-budget guard)"
else
  bad "the 'pick the 1-4 that genuinely fit' class-count cap is gone (cell-budget regression)"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the C24 state-assumption lens (guarded class text + deterministic zone-mapper route) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
