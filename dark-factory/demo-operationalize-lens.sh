#!/usr/bin/env bash
# demo-operationalize-lens.sh — the gate for the #2211 "OPERATIONALIZE BEFORE YOU HUNT" method directive
# (milestone M1).
#
# What the change is: hunter.ag gained a PURE-META method directive — "convert the bug class into CONCRETE,
# code-grounded operationalized checks for THIS zone, WRITE THEM OUT as `OPCHECK|<construct>|<invariant>`
# lines, THEN trace each one" — injected into the shared hunt instruction. It carries NO detector: the method
# applies to essentially any zone, so the FLAG is the only gate, which is what keeps the M2 corpus A/B a
# single-variable experiment. `OPERATIONALIZE_LENS=1` opts IN; unset (the DEFAULT) leaves the directive "" and
# the assembled prompt byte-identical to the pre-#2211 one. An `OPERATIONALIZE|<subsystem>|<cls>|on` sentinel,
# gated on the marker actually being in the prompt, makes the injection observable in the cell log.
#
# The default is OFF on purpose and is NOT a defect this gate should "fix": #2191 shipped a mechanically
# perfect lens that scored rare-recall delta=+0, so an UNMEASURED recall directive stays opt-in until the M2
# A/B measures it. Parts 1-2 below prove the MACHINERY; part 3 proves the model actually COMPLIES. Neither
# proves recall — that is M2's job, and no assertion here may be read as a capability claim.
#
# #2214 Lever 1 closes the loop on that contract. The directive now also asks for one
# `TRACE|<check>|<CLEAN|BUG|UNRESOLVED>|<evidence>` line per derived check, and — the load-bearing half —
# run-discovery.sh GATES ON THE OUTPUT: a cell that answers with no candidate while distinct `TRACE|` <
# distinct `OPCHECK|` is re-asked once (DF_TRACE_MAX_REASKS, default 1) and, if the shortfall survives,
# recorded as a FAILED `untraced-opcheck` cell (=> the zone is hunted_degraded, not a trusted clean sweep).
# Part 4 below is that gate's offline acceptance bar; it is inert whenever the lens is OFF, and so is the gate.
#
# #2214 PR C closes the RESIDUAL cause the M3 measurement exposed: the gate made every check traced, and the
# cell then DISMISSED the rare bug anyway — five times, on "a trusted deployer picks that pairing", without
# checking what the audited repo itself configures — while a sibling check closed CLEAN on an unverified
# external-protocol fact. So two rules and one harness pin land here:
#   * CONFIG-REALIZABILITY (hunter.ag, GENERAL — in the shared RULES block, NOT lens-gated, because the
#     measured dismissals happened in arms with the lens UNSET). Its prompt-byte delta is measured, not
#     silent: part 2's probe prints RULELEN and asserts it is non-zero.
#   * EXTERNAL FACTS (inside the lens block, so the lens-OFF prompt keeps its byte-identity contract): a
#     CLEAN resting on a claim about an external protocol must cite what it was verified against, else
#     UNRESOLVED.
#   * The harness pin: an uncited config-grounds dismissal, or an uncited external-grounds CLEAN, counts as
#     untraced for the EXISTING gate (same one re-ask, same `untraced-opcheck` reason, no new status
#     vocabulary), and UNRESOLVED checks get an additive per-cell `unresolved` counter instead of folding
#     into SAFE. Parts 5-6 below are the offline fixtures for both.
#
# Six parts:
#   1) SOURCE-GUARD (the CI floor — pure grep/awk: no agentis, no forge, no network). The four helpers, the
#      marker/sentinel coupling, the `== "1"` (default-OFF) polarity, the ""-when-disabled gate, the splice
#      position directly above the lens it refers to, the env_passthrough registration, both new record
#      boundaries, the `opchecks` dosage metric, the directive's load-bearing sentences, an OVERFITTING
#      denylist (no protocol/product hint may ever be re-added to the text), substrate purity, the fixtures'
#      shapes, and the decision that the taxonomy gains NO new class.
#   2) LIVE-UNDER-MOCK ([SKIP] without an `agentis` binary). Real offline hunt cells through
#      run-discovery.sh --backend mock: with OPERATIONALIZE_LENS=1 the sentinel MUST be printed, with the env
#      unset it MUST be absent. Plus a DIRLEN byte-identity probe running the helpers EXTRACTED FROM hunter.ag
#      BY LINE RANGE (so a copy-pasted twin cannot drift from the agent it measures).
#   3) LIVE-AGENT MUTATION GATE ([SKIP] without `flat-cyborg`+`agentis` on PATH). A mock backend never
#      reasons and a stub demo block is not interpreted, so this is the ONLY test that proves the directive
#      reached the LLM and changed its OUTPUT. The SAME cell runs TWICE over the same fixture with only the
#      flag flipped: ON must emit >=2 code-grounded OPCHECK| lines BEFORE the first CANDIDATE|/SAFE token,
#      OFF must emit none. The pair IS the mutation.
#   4) #2214 FOLLOW-THROUGH GATE (CI floor again — pure grep + the SHIPPED shell functions sliced out of
#      run-discovery.sh by line range, so a copy-pasted twin cannot drift). The gate's arithmetic on both
#      sides (fires / does not fire), the duplicate-check tolerance, the candidate-emitting and lens-OFF
#      cases, the re-ask bound, the `.untraced` FAILED branch and the unchanged default-OFF JSON key set.
#   5) #2214 PR C DISMISSAL RULES IN THE PROMPT (CI floor): both rules' load-bearing sentences, the
#      placement decision (config rule in the shared RULES block and NOT inside the lens block; external-fact
#      rule inside the lens block), the flag-independence of the config rule and the same overfitting
#      denylist applied to its text.
#   6) #2214 PR C CITATION DISCIPLINE (CI floor): the shipped detectors, again sliced out of
#      run-discovery.sh, over synthetic cell logs — a config-grounds dismissal with and without a
#      `path:line` citation, the VERBATIM dismissal sentence a measured arm-run produced, an external-fact
#      CLEAN with and without a source, the UNRESOLVED counter, and the lens-OFF inertness of all of it.
#   7) #2223 PER-CHECK PAIRING BY ID (CI floor): the numbered grammar in the directive, and the shipped
#      pairing functions over synthetic logs — matching ids pass, the #2222 QA counter-example (unrelated
#      TRACE lines) trips, an orphan id is counted, a cell with ONE uncited check and a correct UNRESOLVED
#      carry stays `ok` with both recorded per check, a legacy un-numbered transcript falls back to the count
#      rule, and a lens-OFF cell keeps both its byte-identical prompt and its exact JSON key set.
#   8) #2217 PR A SECOND-TIER RECORDS (CI floor): the shipped tier-2 functions, sliced out of run-discovery.sh
#      again, over synthetic cell logs — an UNRESOLVED carry becomes ONE record located from the check's own
#      `Contract.function` text (`loc_source: opcheck`), a check that names nothing falls back to the zone file
#      list (`loc_source: zone`), decoration/slice suffixes can never produce an unparseable location, the
#      per-zone cap of 3 keeps the rare class first and COUNTS what it dropped, the selection does not depend
#      on cell arrival order, and — the load-bearing half — the feature OFF emits EXACTLY 0 bytes on the same
#      non-empty supply, so a default run's JSON is byte-identical. A tier-2 record is an UNSETTLED CHECK, not
#      a candidate: it carries no severity and nothing here may be read as a recall claim.
#
# #2223 also changes WHEN a cell is failed, which parts 4 and 7 both pin: a cell that answered NONE of its
# derived checks is still a FAILED `untraced-opcheck` cell, while a PARTIAL shortfall is recorded per check on
# an `ok` cell (`untraced_ids`/`uncited_ids`/`unresolved_ids`). The measured reason is in the #2214 M3 archive:
# the `dismissal` r1 C23 cell carried the rare row as UNRESOLVED correctly and was discarded anyway, because
# ONE unrelated uncited line in the same cell failed the whole cell.
#
# Usage:  dark-factory/demo-operationalize-lens.sh
# Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HUNTER="$HERE/auditor/agents/hunter.ag"
TAXONOMY="$HERE/auditor/bug-taxonomy.md"
DISCOVERY="$HERE/run-discovery.sh"
ZONEHUNT="$HERE/run-zone-hunt.sh"
FIXDIR="$HERE/fixtures/operationalize/contracts"
PAIRED="$FIXDIR/PairedPoolVault.sol"
PLAIN="$FIXDIR/PlainCounter.sol"

FAILS=0
note() { echo "demo-operationalize-lens.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$HUNTER" "$TAXONOMY" "$DISCOVERY" "$ZONEHUNT" "$PAIRED" "$PLAIN"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done

WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# The multi-line `"..." + "..."` string joins are flattened first, so an assertion can match the PROMPT text
# the model actually receives rather than one source line of it (the demo-callee-trust-lens.sh idiom).
HUNTER_FLAT="$(tr '\n' ' ' < "$HUNTER" | sed 's/"[[:space:]]*+[[:space:]]*"//g')"

# ----------------------------------------------------------------------------------------------------------
# PART 1 — SOURCE-GUARD (CI floor: grep/awk only)
# ----------------------------------------------------------------------------------------------------------
note "1) hunter.ag declares the four #2211 helpers ..."
OPZ_FNS="operationalize_marker operationalize_block operationalize_enabled operationalize_directive trace_reask_block"
MISSING_FN=""
for fn in $OPZ_FNS; do
  grep -q "^fn $fn(" "$HUNTER" || MISSING_FN="$MISSING_FN $fn"
done
if [ -z "$MISSING_FN" ]; then
  ok "all 5 marker/block/toggle/directive/re-ask helpers are declared in hunter.ag"
else
  bad "hunter.ag is missing #2211/#2223 helper(s):$MISSING_FN"
fi

# NO detector, deliberately: a coarse net over "does this zone touch anything external" would gate nothing
# (the method applies everywhere) while adding a SECOND variable to the M2 A/B. If a detector is ever added,
# this assertion is the place to argue about it — silently growing one would invalidate the experiment.
if grep -A3 '^fn operationalize_directive(' "$HUNTER" | grep -qi 'code\|detector\|has_'; then
  bad "operationalize_directive() grew a payload/detector argument — the flag must stay the ONLY gate (M2 single-variable)"
else
  ok "operationalize_directive() takes no payload and consults no detector (the flag is the only gate)"
fi

# #2214 PR C: the config-realizability rule is a FIFTH helper and is deliberately NOT one of the four above —
# it is general (no flag, no lens), so it is asserted separately here and in part 5.
if grep -q '^fn config_realizability_rule(' "$HUNTER"; then
  ok "hunter.ag declares config_realizability_rule() (the #2214 PR C general dismissal rule)"
else
  bad "hunter.ag is missing config_realizability_rule() — the #2214 PR C dismissal rule would not exist"
fi

note "2) the marker helper IS what the sentinel greps, and IS the block's first line ..."
if grep -A2 '^fn operationalize_block(' "$HUNTER" | grep -q 'return operationalize_marker() + "\\n"'; then
  ok "operationalize_block() opens with operationalize_marker() (a reword cannot desync the sentinel gate)"
else
  bad "operationalize_block() no longer opens with operationalize_marker() — the sentinel could silently stop firing"
fi
MARKER="$(sed -n '/^fn operationalize_marker(/,/^}$/p' "$HUNTER" | sed -n 's/^[[:space:]]*return "\(.*\)";$/\1/p')"
# #2214: the marker literal itself must stay BYTE-IDENTICAL while the block around it grows. It is the string
# the honesty-gated sentinel greps for in the ASSEMBLED instruction, so editing the directive's first line
# would silently stop the OPERATIONALIZE| sentinel from firing — and the #2214 gate keys on that sentinel too,
# which would make the whole follow-through gate inert without a single assertion turning red.
if [ "$MARKER" = "=== OPERATIONALIZE BEFORE YOU HUNT (do this FIRST, explicitly, in your reasoning) ===" ]; then
  ok "operationalize_marker() is byte-identical to the shipped #2211 literal (the sentinel gate and the #2214 output gate both key on it)"
else
  bad "operationalize_marker() changed ('$MARKER') — the OPERATIONALIZE| sentinel (and with it the #2214 untraced gate) would stop firing"
fi
if [ -n "$MARKER" ]; then
  case "$HUNTER_FLAT" in
    *"$MARKER"*) ok "the marker literal is a substring of the rendered directive text (index_of can match it)" ;;
    *) bad "the marker literal is NOT a substring of the rendered directive — the sentinel gate would never fire" ;;
  esac
else
  bad "could not read the marker literal out of operationalize_marker()"
fi

note "3) default-OFF polarity: only the literal \"1\" opts in ..."
if grep -A2 '^fn operationalize_enabled(' "$HUNTER" | grep -q 'return getenv("OPERATIONALIZE_LENS") == "1";'; then
  ok "operationalize_enabled() is getenv(\"OPERATIONALIZE_LENS\") == \"1\" — unset/any other value = OFF = the default"
else
  bad "operationalize_enabled() no longer reads == \"1\" — the directive would not be default-OFF"
fi
# The inversion vs CALLEE_TRUST/INTEGRATION_LENS is the POINT, not an inconsistency to tidy away. Pin it.
if grep -A2 '^fn operationalize_enabled(' "$HUNTER" | grep -q '!= "0"'; then
  bad "operationalize_enabled() was flipped to the default-ON (!= \"0\") polarity — #2211 M1 ships OPT-IN until M2 measures it"
else
  ok "the toggle was NOT \"fixed\" into the default-ON polarity of its siblings (M3 flips it, on measured evidence)"
fi
if grep -A2 '^fn operationalize_directive(' "$HUNTER" | grep -q 'if !operationalize_enabled() { return ""; }'; then
  ok "operationalize_directive() returns \"\" when the flag is off (an OFF cell prompts byte-identical)"
else
  bad "operationalize_directive() lost its \"\"-when-disabled early return — the default arm's prompt would change"
fi

note "4) the splice position: the directive sits IMMEDIATELY ABOVE the lens it refers to ..."
if grep -q '^  + opz$' "$HUNTER" \
   && grep -B1 '^  + opz$' "$HUNTER" | grep -q '^  + cons$' \
   && grep -A1 '^  + opz$' "$HUNTER" | grep -q 'HUNT THIS BUG CLASS (the lens)'; then
  ok "'+ opz' is spliced between '+ cons' and the lens header (the directive's \"the LENS below\" referent follows it)"
else
  bad "the '+ opz' splice is gone or no longer sits between '+ cons' and the '=== HUNT THIS BUG CLASS' header"
fi
if grep -q '^let opz = operationalize_directive();$' "$HUNTER"; then
  ok "the directive is bound once per cell via 'let opz = operationalize_directive();'"
else
  bad "the 'let opz = operationalize_directive();' binding is gone"
fi

note "5) the toggle actually reaches hunter.ag (exec.env_passthrough) ..."
# getenv() reads the SANITISED env: without the allowlist entry the opt-in could never arrive and the whole
# directive would be unreachable (the #1426/#2157 silently-inert failure mode).
# [,"] terminator, so a LATER knob appended after this one does not fail this assertion spuriously.
if grep -q '^  echo "exec.env_passthrough = .*,OPERATIONALIZE_LENS[,"]' "$DISCOVERY"; then
  ok "run-discovery.sh registers OPERATIONALIZE_LENS on exec.env_passthrough (the opt-in can reach hunter.ag)"
else
  bad "run-discovery.sh does NOT pass OPERATIONALIZE_LENS through exec.env_passthrough — the flag would be inert"
fi

note "6) the OPERATIONALIZE| sentinel and its honesty gate ..."
if grep -q 'print("OPERATIONALIZE|" + subsystem + "|" + cls + "|on");' "$HUNTER"; then
  ok "the sentinel is printed as OPERATIONALIZE|<subsystem>|<cls>|on"
else
  bad "the OPERATIONALIZE|<subsystem>|<cls>|on sentinel emission is gone or reshaped"
fi
if grep -B1 'print("OPERATIONALIZE|"' "$HUNTER" | grep -q 'if index_of(instruction, operationalize_marker()) >= 0 {'; then
  ok "the sentinel is gated on the marker actually being in the assembled instruction (index_of), not on the toggle"
else
  bad "the OPERATIONALIZE sentinel is no longer gated on the marker being present in the assembled instruction"
fi
if grep 'print("OPERATIONALIZE|"' "$HUNTER" | grep -q 'CANDIDATE|'; then
  bad "the OPERATIONALIZE sentinel carries a 'CANDIDATE|' substring (would false-accept a cell)"
else
  ok "the sentinel carries no 'CANDIDATE|' substring (lib/run-agent-validated.sh cannot false-accept a cell on it)"
fi
if grep -q 'OPERATIONALIZE|<subsystem>|<cls>|on' "$HUNTER" && grep -q 'OPCHECK|#<k>|<construct>|<invariant>' "$HUNTER" \
   && grep -q 'TRACE|#<k>|<CLEAN|BUG|UNRESOLVED>|<evidence>' "$HUNTER"; then
  ok "hunter.ag's header Stdout contract documents the OPERATIONALIZE| sentinel and the NUMBERED OPCHECK|#k / TRACE|#k grammar (#2223)"
else
  bad "hunter.ag's header Stdout contract does not document the OPERATIONALIZE|/OPCHECK| lines"
fi
if grep -q 'OPERATIONALIZE_LENS #2211' "$HUNTER"; then
  ok "hunter.ag's Env contract documents OPERATIONALIZE_LENS and its default"
else
  bad "hunter.ag's Env contract does not document the OPERATIONALIZE_LENS knob"
fi

note "7) the directive carries its load-bearing sentences ..."
DIRECTIVE_MISS=""
for s in \
  "=== OPERATIONALIZE BEFORE YOU HUNT (do this FIRST, explicitly, in your reasoning) ===" \
  "Do NOT jump to the obvious bug" \
  "convert the class into CONCRETE" \
  "An operationalized check is not a theme" \
  "Method: scan the zone's functions for every place it touches an EXTERNAL protocol" \
  "Cover both directions of any paired operation" \
  "WRITE OUT the operationalized checks you derived for this zone, THEN trace each one against the" \
  "Do not restate the class titles" \
  "Emit each derived check, BEFORE you begin tracing and before any CANDIDATE line, on its own line, " \
  "NUMBERING the checks #1, #2, #3 ... in the order you derive them:" \
  "OPCHECK|#<k>|<the specific construct in this zone's code>|<the exact invariant it must satisfy>" \
  "never invent a construct that is not in the code" \
  "FOLLOW THROUGH — a check you write and abandon is worse than one you never derived." \
  "REFERENCES THE SAME NUMBER you gave that check" \
  "TRACE|#<k>|<CLEAN or BUG or UNRESOLVED>|<the function or line in THIS zone that settles it>" \
  "The number is how a trace is matched to its check" \
  "SAFE is a valid answer ONLY when every OPCHECK number you wrote has a TRACE line with the same number." \
  "EXTERNAL FACTS — the other way a derived check dies quietly" \
  "that claim is a FACT YOU MUST VERIFY, not an assumption you may lean on" \
  "the verdict is UNRESOLVED — never CLEAN"
do
  case "$HUNTER_FLAT" in *"$s"*) ;; *) DIRECTIVE_MISS="$DIRECTIVE_MISS [$s]" ;; esac
done
if [ -z "$DIRECTIVE_MISS" ]; then
  ok "the directive keeps its header, the derive-write-then-trace method, the paired-operation clause, the OPCHECK| emission contract, the #2214 TRACE| follow-through contract, the #2214 PR C external-fact citation rule and the anti-fabrication guard"
else
  bad "the directive lost load-bearing text:$DIRECTIVE_MISS"
fi

# #2214: the TRACE verdict vocabulary must not contain a `CANDIDATE|` substring — lib/run-agent-validated.sh
# validates a hunter reply by grepping for exactly that, so a verdict word carrying it would let a reply that
# never reached a verdict pass validation.
case "$HUNTER_FLAT" in
  *"TRACE|#<k>|<CLEAN or BUG or UNRESOLVED>"*)
    ok "the TRACE| verdict vocabulary is CLEAN/BUG/UNRESOLVED — no 'CANDIDATE|' substring for the reply-shape validator to false-accept" ;;
  *)
    bad "the TRACE| verdict vocabulary changed — check it still carries no 'CANDIDATE|' substring (lib/run-agent-validated.sh would false-accept)" ;;
esac

note "8) OVERFITTING GUARD: the directive stays PURE-META (no protocol/product hint) ..."
# The whole claim behind #2211 is that the BLIND (pure-meta) variant recovers bugs the generic pass misses.
# Re-adding a domain hint — the tokens the hand-fed probe variants used — would hand the model an answer and
# invalidate every measurement taken with the directive on, so the denylist is an assertion, not a comment.
BLOCK_BODY="$WORK/operationalize-body.txt"
awk '/^fn operationalize_block\(/{f=1} f{print} f&&/^}$/{exit}' "$HUNTER" > "$BLOCK_BODY"
DENY='Curve|Convex|Pendle|Balancer|Uniswap|Aave|useEth|use_eth|WETH|wrapNative|decimals|slot0|ERC-?[0-9]|\.sol'
if [ ! -s "$BLOCK_BODY" ]; then
  bad "could not slice operationalize_block() out of hunter.ag"
elif grep -Eq "$DENY" "$BLOCK_BODY"; then
  bad "the directive block names a protocol/product/parameter specific (it would leak an answer into a hunt)"
  grep -nE "$DENY" "$BLOCK_BODY" | head -3 | sed 's/^/      /' >&2
else
  ok "the directive names no protocol, contract, function, flag, token standard or unit (pure-meta — injecting it cannot leak an answer)"
fi

note "9) substrate purity (#1587): the #2211 block is builtins-only ..."
# CODE lines only: the block's own prose legitimately discusses reading code, and a grep over comments would
# flag the documentation of the very rule it enforces.
OPZ_BLOCK="$WORK/operationalize-block.txt"
awk '/--- #2211 OPERATIONALIZE-BEFORE-YOU-HUNT DIRECTIVE/{f=1} f&&/^\/\/ --- #2145 ATTACKER-CONTROLLED-CALLEE DIRECTIVE/{exit} f{print}' \
  "$HUNTER" | grep -v '^[[:space:]]*//' > "$OPZ_BLOCK"
if [ ! -s "$OPZ_BLOCK" ]; then
  bad "could not slice the #2211 block out of hunter.ag (header comment renamed?)"
elif grep -Eq 'exec sh|python3 -c|reduce\(|regex_' "$OPZ_BLOCK"; then
  bad "the #2211 block introduced an embedded interpreter / regex / reduce (substrate-purity ratchet + per-element CB cost)"
  grep -nE 'exec sh|python3 -c|reduce\(|regex_' "$OPZ_BLOCK" | head -3 | sed 's/^/      /' >&2
else
  ok "the #2211 block uses only native builtins and O(1) string concat (no exec sh, no regex/reduce, no per-element cost)"
fi

note "10) all three model-emitted tokens are RECORD BOUNDARIES in run-discovery.sh ..."
# OPCHECK| lines are MODEL-emitted free text that lands in the same log as the CANDIDATE| records. Without a
# boundary, an OPCHECK line following a PTY-wrapped CANDIDATE would be glued onto it as prose.
BOUNDARY_LINE="$(grep -n 'BLACKBOARD-/ ||' "$DISCOVERY" | head -1 | cut -d: -f2-)"
BOUND_MISS=""
case "$BOUNDARY_LINE" in *'OPERATIONALIZE\|'*) ;; *) BOUND_MISS="$BOUND_MISS OPERATIONALIZE|" ;; esac
case "$BOUNDARY_LINE" in *'OPCHECK\|'*) ;; *) BOUND_MISS="$BOUND_MISS OPCHECK|" ;; esac
# #2214: the TRACE| line has exactly the same hazard as the OPCHECK| line it answers — it is model-emitted
# free text landing in the same log, so without a boundary it would be glued onto an open CANDIDATE| record.
case "$BOUNDARY_LINE" in *'TRACE\|'*) ;; *) BOUND_MISS="$BOUND_MISS TRACE|" ;; esac
if [ -z "$BOUNDARY_LINE" ]; then
  bad "could not find the _join_wrapped_candidates boundary alternation in run-discovery.sh"
elif [ -z "$BOUND_MISS" ]; then
  ok "_join_wrapped_candidates lists OPERATIONALIZE|, OPCHECK| and TRACE| next to the sibling boundary tokens"
else
  bad "the _join_wrapped_candidates boundary alternation is missing:$BOUND_MISS"
fi

# Behavioural half: run the SHIPPED awk program (sliced out of run-discovery.sh, so a copy-pasted twin cannot
# drift from it) over a synthetic PTY-wrapped CANDIDATE followed by an OPCHECK line. Pure awk, stays in CI.
JWC_AWK="$WORK/join-wrapped.awk"
sed -n '/^_join_wrapped_candidates() {$/,/^}$/p' "$DISCOVERY" \
  | sed -n "/^  awk '$/,/^  ' /p" | sed "1d; \$d" > "$JWC_AWK"
WRAP_LOG="$WORK/wrapped-cell.log"
{
  printf 'OPERATIONALIZE|vault|C23|on\n'
  printf 'OPCHECK|the literal flag passed to the external pool|both legs of the round trip pass the same value\n'
  printf 'CANDIDATE|Vault.sol:exitPool:48|C23|High|the exit leg hardcodes the opposite convention|deploy a\n'
  printf '  pool stub, enter then exit, and assert the returned representation differs\n'
  printf 'OPCHECK|the share accounting on both legs|total shares equals the sum of per-user shares\n'
  printf 'CANDIDATE|Vault.sol:joinPool:31|C23|Medium|the entry leg reads a stale stored rate|stub the pool,\n'
  printf '  move the rate between the two calls, and assert the entered amount uses the stale one\n'
  printf 'TRACE|the share accounting on both legs|CLEAN|the totals are updated in the same statement\n'
  printf 'SAFE\n'
} > "$WRAP_LOG"
if [ ! -s "$JWC_AWK" ]; then
  bad "could not extract the _join_wrapped_candidates awk program from run-discovery.sh (reshaped?)"
else
  JOINED="$(awk -f "$JWC_AWK" "$WRAP_LOG")"
  JOINED_N="$(printf '%s\n' "$JOINED" | grep -c 'CANDIDATE|')"
  if [ "$JOINED_N" -ne 2 ]; then
    bad "the two wrapped records did not reconstruct into exactly two CANDIDATE| lines (got $JOINED_N)"
  elif printf '%s' "$JOINED" | grep -q 'OPCHECK\|OPERATIONALIZE\|TRACE|'; then
    bad "an OPCHECK|/OPERATIONALIZE|/TRACE| line was glued onto an open CANDIDATE| record as prose (the boundary does not hold)"
  elif printf '%s' "$JOINED" | grep -q 'assert the returned representation differs' \
       && printf '%s' "$JOINED" | grep -q 'assert the entered amount uses the stale one'; then
    ok "an OPCHECK| line and a TRACE| line each close a PTY-wrapped CANDIDATE record: two joined candidates, both wrapped tails kept, no OPCHECK/TRACE text inside them"
  else
    bad "a wrapped continuation line was lost while joining the records"
  fi
fi

note "11) the per-cell 'opchecks' dosage metric (#2211 M2's cheap measurement) ..."
if grep -q 'ac_opn=' "$DISCOVERY" && grep -Fq 'opchecks\":$ac_opn' "$DISCOVERY"; then
  ok "_accumulate_cell derives \"opchecks\":<n> from the cell LOG (what the agent emitted, not what the shell intended)"
else
  bad "_accumulate_cell no longer records the per-cell opchecks count derived from the log"
fi
# Appended LAST and only when non-zero, so _plan_depth_cells's forward key scan is untouched and a cell that
# emitted none keeps its exact pre-#2211 key set.
if grep -q 'if \[ "\$ac_opn" -gt 0 \]; then ac_opchecks_json=' "$DISCOVERY"; then
  ok "the key is emitted only when the model emitted at least one OPCHECK| (a cell with none keeps its exact key set)"
else
  bad "the opchecks key is emitted unconditionally — an OFF-arm cell's JSON would no longer be byte-identical"
fi
# #2214: the same discipline for the two follow-through counters. `untraced` is ALSO how a cell that DID
# produce candidates records its shortfall — such a cell is never re-asked and never failed, so this field is
# the only place its abandoned checks reach the readout.
if grep -q 'if \[ "\$ac_trn" -gt 0 \]; then ac_traces_json=' "$DISCOVERY" \
   && grep -q 'if \[ "\$ac_un" -gt 0 \]; then ac_untraced_json=' "$DISCOVERY"; then
  ok "_accumulate_cell records \"traces\" and \"untraced\" only when non-zero (a lens-OFF cell's JSON key set is byte-identical to the pre-#2214 one)"
else
  bad "the #2214 traces/untraced counters are missing or emitted unconditionally (a lens-OFF cell's JSON would change shape)"
fi
# #2214 PR C appends `unresolved` after them, under the same discipline (non-zero only, LAST). What the pin
# protects is the FORWARD key scan (subsystem -> class -> files -> status -> candidates), so a later issue may
# append further additive keys AFTER the #2223 ones — #2245 iteration 2 appends three — but nothing may be
# inserted before them.
if grep -q '"\$ac_opchecks_json" "\$ac_traces_json" "\$ac_untraced_json" "\$ac_unresolved_json" \\' "$DISCOVERY" \
   && grep -q '"\$ac_untraced_ids_json" "\$ac_uncited_ids_json" "\$ac_unresolved_ids_json"' "$DISCOVERY"; then
  ok "the counters are appended after opchecks and the #2223 rule/orphan/id fields after them (the _plan_depth_cells forward key scan is untouched)"
else
  bad "the #2214/#2223 counters are no longer appended after the fixed fields of the cell object — the forward key scan could break"
fi
if grep -q 'if \[ "\$ac_unres" -gt 0 \]; then ac_unresolved_json=' "$DISCOVERY"; then
  ok "_accumulate_cell records \"unresolved\" only when non-zero (a cell with no UNRESOLVED check keeps its exact key set)"
else
  bad "the #2214 PR C unresolved counter is missing or emitted unconditionally (a lens-OFF cell's JSON would change shape)"
fi

note "12) DECISION: no new taxonomy class — this is a cross-class METHOD directive ..."
# The pin is "no class was minted FOR THIS change", asserted against the next UNALLOCATED taxonomy slot.
# C24 was allocated by #2218 (stale state assumption between touchpoints), C25 by #2245 iteration 1 (empty
# distribution / zero participation edge) and C26 by #2245 iteration 4 (admitted parameter / unenforced
# bound) and C27 by #2265 (variant coverage gap) — unrelated domain classes — so the slot moved to C28; the
# decision below is unchanged.
if grep -q '^## C28 ' "$TAXONOMY"; then
  bad "bug-taxonomy.md gained a '## C28 ' class — #2211 is explicitly a method directive, NOT a new class"
else
  ok "bug-taxonomy.md declares no new class (the directive is cross-class, it replaces no lens and adds none)"
fi
if grep -q 'OPERATIONALIZE_LENS=1' "$TAXONOMY"; then
  ok "bug-taxonomy.md's hunter usage notes record the directive as default-OFF and opt-in"
else
  bad "bug-taxonomy.md does not document the #2211 directive as an opt-in, no-new-class method step"
fi

note "13) the two fixtures carry the shapes they exist for ..."
if grep -q 'shares = pool.join(amount, false);' "$PAIRED" \
   && grep -q 'amount = pool.exit(shares, true);' "$PAIRED"; then
  ok "PairedPoolVault.sol: a paired operation whose entry and exit legs pass the SAME literal flag oppositely"
else
  bad "PairedPoolVault.sol lost the entry-vs-exit literal-flag asymmetry it exists to carry"
fi
if grep -q 'contract PlainCounter' "$PLAIN" && ! grep -q 'interface \|\.call(\|external returns' "$PLAIN"; then
  ok "PlainCounter.sol: no external touchpoint at all (the control arm)"
else
  bad "PlainCounter.sol gained an external call surface — it no longer isolates the no-touchpoint case"
fi
# A fixture naming a real protocol would overfit the gate (and, in a public repo, read as a target hint).
# Note the DENY list above applies to the DIRECTIVE only: a literal flag name inside the fixture is the point.
if grep -Eqi 'Curve|Convex|Pendle|Balancer|Uniswap|Aave' "$PAIRED" "$PLAIN"; then
  bad "a fixture names a real protocol — fixtures must stay protocol-agnostic"
else
  ok "neither fixture names a real protocol (generic pool interface only)"
fi
# FIXTURE HYGIENE (a measured contamination, not a hypothetical): an early draft of PairedPoolVault.sol
# explained in its own header comment that the gate expects OPCHECK| lines. The payload is fed to the model
# VERBATIM, so the OFF arm dutifully emitted OPCHECK| lines with the directive absent and the mutation gate
# read as contaminated. A fixture must never narrate the test it is fed to.
# #2214 extends the same guard to the TRACE| half of the contract: a fixture that names it would teach the
# OFF arm to emit trace lines and would make the follow-through gate unreadable in exactly the same way.
if grep -Eq 'OPCHECK|OPERATIONALIZE|operationaliz|TRACE\|' "$PAIRED" "$PLAIN"; then
  bad "a fixture's own text names the OPCHECK|/TRACE|/OPERATIONALIZE contract — it would teach the model the expected output and contaminate the OFF arm"
  grep -nE 'OPCHECK|OPERATIONALIZE|operationaliz|TRACE\|' "$PAIRED" "$PLAIN" | head -3 | sed 's/^/      /' >&2
else
  ok "neither fixture narrates the gate that consumes it, OPCHECK| or TRACE| (the OFF arm cannot be taught the expected output)"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 2 — LIVE UNDER MOCK (needs the agentis binary; clean [SKIP] otherwise)
# ----------------------------------------------------------------------------------------------------------
# _arm <label> <fixture-basename> <backend>: stage a one-contract repo + scope + brief, run ONE hunter cell
# through run-discovery.sh, print the cell log path. Used by parts 2 and 3 (only the backend differs), so the
# live gate exercises the SAME path the mock gate does.
_arm() {
  _label="$1"; _sol="$2"; _backend="$3"
  _repo="$WORK/$_label-repo"; mkdir -p "$_repo/contracts"
  cp "$FIXDIR/$_sol.sol" "$_repo/contracts/$_sol.sol"
  printf 'vault | C23 | contracts/%s.sol\n' "$_sol" > "$WORK/$_label-scope.tsv"
  printf '# brief\nInvariants to break: the two legs of a round trip agree.\nKnown issues to exclude: none.\n' \
    > "$WORK/$_label-brief.md"
  "$DISCOVERY" --repo "$_repo" --scope "$WORK/$_label-scope.tsv" --brief "$WORK/$_label-brief.md" \
    --only "vault" --classes C23 --backend "$_backend" --agentis agentis --out "$WORK/$_label" \
    > "$WORK/$_label.out" 2>&1 || true
  printf '%s\n' "$WORK/$_label/run/hunt_vault_C23.log"
}

if ! command -v agentis >/dev/null 2>&1; then
  note "14-15) live-under-mock sentinel ON/OFF + byte-identity probe ..."
  skip "no agentis binary on PATH — the mock hunt cells and the extracted-helper probe cannot run"
else
  note "14) live-under-mock: the sentinel appears with OPERATIONALIZE_LENS=1 and is ABSENT by default ..."
  ON_LOG="$(OPERATIONALIZE_LENS=1 _arm mock-on PairedPoolVault mock)"
  OFF_LOG="$(_arm mock-off PairedPoolVault mock)"
  if [ ! -f "$ON_LOG" ] || [ ! -f "$OFF_LOG" ]; then
    bad "the mock hunt cells produced no cell log (run-discovery.sh did not reach hunter.ag)"
    tail -5 "$WORK/mock-on.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    if grep -q '^OPERATIONALIZE|vault|C23|on$' "$ON_LOG"; then
      ok "OPERATIONALIZE_LENS=1: the sentinel fired end-to-end (run-discovery.sh -> env_passthrough -> hunter.ag getenv)"
    else
      bad "OPERATIONALIZE_LENS=1: NO OPERATIONALIZE| sentinel — the opt-in did not reach hunter.ag (env_passthrough gap?)"
    fi
    if grep -q 'OPERATIONALIZE|' "$OFF_LOG"; then
      bad "default (env unset): an OPERATIONALIZE| sentinel appeared — the directive is NOT default-OFF"
    else
      ok "default (env unset): NO OPERATIONALIZE| sentinel — the directive is opt-in and the prompt is unchanged"
    fi
  fi

  note "15) byte-identity probe: the directive is EXACTLY 0 bytes when the flag is unset ..."
  # The helpers are EXTRACTED FROM hunter.ag BY LINE RANGE, so this probe measures the shipped code rather
  # than a copy that can drift (the demo-discovery-parallel.sh 18g idiom).
  FRAG="$WORK/opz.frag"; : > "$FRAG"
  FRAG_MISS=""
  # #2214 PR C: the general config rule is extracted alongside the four lens helpers, so the SAME probe that
  # proves the lens is 0 bytes when OFF also MEASURES what the general rule adds to every prompt.
  for fn in $OPZ_FNS config_realizability_rule; do
    awk -v want="^fn $fn\\\\(" '$0 ~ want {f=1} f{print} f&&/^}$/{exit}' "$HUNTER" >> "$FRAG"
    printf '\n' >> "$FRAG"
    grep -q "^fn $fn(" "$FRAG" || FRAG_MISS="$FRAG_MISS $fn"
  done
  if [ -n "$FRAG_MISS" ]; then
    bad "could not extract #2211 helpers from hunter.ag by line range (renamed?):$FRAG_MISS"
  else
    SB="$WORK/probe"; mkdir -p "$SB"
    ( cd "$SB" && agentis init >/dev/null 2>&1 ) || true
    printf 'exec.env_passthrough = OPERATIONALIZE_LENS,TRACE_REASK_IDS\n' > "$SB/.agentis/config"
    {
      printf 'cb 300000;\n\n'
      cat "$FRAG"
      printf 'print("BLOCKLEN=" + to_string(len(operationalize_block())));\n'
      printf 'print("DIRLEN=" + to_string(len(operationalize_directive())));\n'
      printf 'print("RULELEN=" + to_string(len(config_realizability_rule())));\n'
    } > "$SB/probe.ag"
    # _dirlen <flag-value|""> [reask-ids]: the toggle-gated directive length. An empty first argument runs
    # with OPERATIONALIZE_LENS UNSET; #2223's optional second argument sets TRACE_REASK_IDS, which is how the
    # re-ask block is measured (and how the lens-OFF byte-identity contract is proven to survive it).
    _dirlen() {
      _dl_ids="${2:-}"
      if [ -n "$1" ]; then
        _dl="$( cd "$SB" && OPERATIONALIZE_LENS="$1" TRACE_REASK_IDS="$_dl_ids" agentis go probe.ag 2>&1 | grep '^DIRLEN=' | tail -1 )"  # no-pii: the probe never calls prompt() — it prints two string lengths
      else
        _dl="$( cd "$SB" && TRACE_REASK_IDS="$_dl_ids" agentis go probe.ag 2>&1 | grep '^DIRLEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
      fi
      printf '%s\n' "${_dl#DIRLEN=}"
    }
    BLOCK_LEN="$( cd "$SB" && agentis go probe.ag 2>&1 | grep '^BLOCKLEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
    BLOCK_LEN="${BLOCK_LEN#BLOCKLEN=}"
    DIR_UNSET="$(_dirlen "")"
    DIR_ON="$(_dirlen "1")"
    DIR_ZERO="$(_dirlen "0")"
    DIR_TRUE="$(_dirlen "true")"
    case "$BLOCK_LEN" in
      ''|*[!0-9]*) bad "the byte-identity probe did not complete (BLOCKLEN='$BLOCK_LEN')" ;;
      0) bad "operationalize_block() is empty — the directive could never reach a prompt" ;;
      *) ok "operationalize_block() is $BLOCK_LEN bytes (the directive is really assembled)" ;;
    esac
    case "$DIR_UNSET" in
      0) ok "OPERATIONALIZE_LENS unset: operationalize_directive() is \"\" (0 bytes) — concatenating it is a no-op, so the DEFAULT prompt is byte-identical to the pre-#2211 one" ;;
      ''|*[!0-9]*) bad "the toggle probe did not complete with the env unset (got '$DIR_UNSET')" ;;
      *) bad "OPERATIONALIZE_LENS unset: the directive is $DIR_UNSET bytes — the default is NOT byte-identical" ;;
    esac
    if [ "$DIR_ON" = "$BLOCK_LEN" ] && [ "$BLOCK_LEN" != "0" ] 2>/dev/null; then
      ok "OPERATIONALIZE_LENS=1: operationalize_directive() = $DIR_ON bytes = the full block (the opt-in really injects it)"
    else
      bad "OPERATIONALIZE_LENS=1: operationalize_directive() ($DIR_ON) != the full block ($BLOCK_LEN)"
    fi
    # Any value OTHER than "1" is OFF — including the two that a well-meaning operator would expect to work.
    # #2214 PR C: the general rule's PROMPT-BYTE DELTA. It is injected on EVERY cell, lens on or off, so the
    # honest thing is to measure it and put the number in the readout — not to claim the prompt is unchanged.
    RULE_LEN="$( cd "$SB" && agentis go probe.ag 2>&1 | grep '^RULELEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
    RULE_LEN="${RULE_LEN#RULELEN=}"
    case "$RULE_LEN" in
      ''|*[!0-9]*) bad "the #2214 PR C rule probe did not complete (RULELEN='$RULE_LEN')" ;;
      0) bad "config_realizability_rule() is empty — the general dismissal rule would never reach a prompt" ;;
      *) ok "config_realizability_rule() is $RULE_LEN bytes: the MEASURED prompt-byte delta this general rule adds to every cell (lens on or off)" ;;
    esac
    if [ "$DIR_ZERO" = "0" ] && [ "$DIR_TRUE" = "0" ]; then
      ok "OPERATIONALIZE_LENS=0 and =true are both OFF (only the literal \"1\" opts in — no accidental default-ON)"
    else
      bad "a value other than \"1\" turned the directive ON (=0 gave '$DIR_ZERO', =true gave '$DIR_TRUE')"
    fi
    # #2223: the re-ask block lives INSIDE the lens directive, so TRACE_REASK_IDS can never reach a lens-OFF
    # prompt — the byte-identity contract survives a knob that only ever fires on a re-ask.
    DIR_OFF_IDS="$(_dirlen "" "#2, #5")"
    DIR_ON_IDS="$(_dirlen "1" "#2, #5")"
    if [ "$DIR_OFF_IDS" = "0" ]; then
      ok "TRACE_REASK_IDS set with the lens OFF: operationalize_directive() is still 0 bytes (the re-ask block cannot leak into a lens-OFF prompt)"
    else
      bad "TRACE_REASK_IDS set with the lens OFF gave a $DIR_OFF_IDS-byte directive — the lens-OFF prompt is NOT byte-identical"
    fi
    case "$DIR_ON_IDS" in
      ''|*[!0-9]*) bad "the #2223 re-ask probe did not complete (got '$DIR_ON_IDS')" ;;
      *)
        if [ "$DIR_ON_IDS" -gt "$DIR_ON" ]; then
          ok "TRACE_REASK_IDS set with the lens ON: $DIR_ON_IDS bytes vs $DIR_ON without it — the re-ask really names the open checks in the prompt"
        else
          bad "TRACE_REASK_IDS changed nothing with the lens ON ($DIR_ON_IDS vs $DIR_ON) — the re-ask would replay the same prompt (env_passthrough gap?)"
        fi ;;
    esac
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# PART 3 — LIVE-AGENT MUTATION GATE. The directive is ENGLISH PROSE interpreted by the model: no `.ag` code
# implements "derive the checks and write them out", so nothing above can tell whether the model COMPLIES.
# A mock backend replays a scripted transcript and never reasons, and a stub demo block is not interpreted by
# the agent runtime at all — so this part runs hunter.ag for real over `flat-cyborg` (this federation's
# mandatory live backend) and gates on the model's OUTPUT. Clean [SKIP] otherwise, so CI (no logged-in
# session) stays green without pretending to have exercised it.
# ----------------------------------------------------------------------------------------------------------
if ! command -v flat-cyborg >/dev/null 2>&1 || ! command -v agentis >/dev/null 2>&1; then
  note "16) live-agent ON/OFF mutation gate ..."
  skip "no flat-cyborg/agentis on PATH — the real hunter.ag compliance with the directive cannot be exercised"
else
  note "16) live-agent ON/OFF mutation gate: same fixture, same cell, only the flag flips ..."
  LIVE_ON_LOG="$(OPERATIONALIZE_LENS=1 _arm live-on PairedPoolVault flat-cyborg)"
  LIVE_OFF_LOG="$(_arm live-off PairedPoolVault flat-cyborg)"

  # Code-groundedness is asserted MECHANICALLY: every OPCHECK| line must carry an identifier that literally
  # occurs in the fixture's CODE (comments stripped, so the directive cannot be satisfied by echoing prose).
  # This is what "code-grounded, not a theme" means, and it is what a fabricated block fails.
  FIX_TOKENS="$WORK/fixture-tokens.txt"
  sed 's://.*::' "$PAIRED" | grep -oE '[A-Za-z_][A-Za-z0-9_]*' | sort -u \
    | grep -vE '^(pragma|solidity|interface|function|external|internal|private|public|returns|return|uint256|address|mapping|contract|immutable|constructor|require|bool|memory|storage|view|msg|sender|true|false)$' \
    | awk 'length($0) >= 4' > "$FIX_TOKENS"
  _line_grounded() {
    _l="$1"
    while IFS= read -r _t; do
      [ -n "$_t" ] || continue
      case "$_l" in *"$_t"*) return 0 ;; esac
    done < "$FIX_TOKENS"
    return 1
  }

  if [ ! -f "$LIVE_ON_LOG" ]; then
    bad "ON arm: no cell log — run-discovery.sh did not reach a verdict over the real backend"
    tail -8 "$WORK/live-on.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    OP_N="$(grep -cE '^[[:space:]]*OPCHECK\|' "$LIVE_ON_LOG")"
    case "$OP_N" in ''|*[!0-9]*) OP_N=0 ;; esac
    if [ "$OP_N" -ge 2 ]; then
      ok "ON arm: the model emitted $OP_N OPCHECK| lines — the directive reached the LLM and changed its output"
    else
      bad "ON arm: only $OP_N OPCHECK| line(s) — the model did not comply with the emission contract"
      tail -8 "$WORK/live-on.out" 2>/dev/null | sed 's/^/      /' >&2
    fi
    if [ "$OP_N" -gt 0 ]; then
      UNGROUNDED=0
      while IFS= read -r opline; do
        _line_grounded "$opline" || UNGROUNDED=$((UNGROUNDED + 1))
      done <<EOF
$(grep -E '^[[:space:]]*OPCHECK\|' "$LIVE_ON_LOG")
EOF
      if [ "$UNGROUNDED" -eq 0 ]; then
        ok "ON arm: every OPCHECK| line names an identifier that literally occurs in the fixture's code (code-grounded, not themes)"
      else
        bad "ON arm: $UNGROUNDED of $OP_N OPCHECK| lines name nothing in the fixture's code (the model produced themes, or fabricated constructs)"
      fi
    fi
    # #2214: the FOLLOW-THROUGH half of the same contract, on the same live reply. This is the only place the
    # TRACE| clause is proven to be interpreted by the model rather than merely present in the prompt — and it
    # is the ON arm the live gate must not trip: a compliant cell emits at least as many DISTINCT TRACE| lines
    # as DISTINCT OPCHECK| lines, which is exactly _opcheck_trace_gap()'s arithmetic (part 4).
    _distinct_live() { grep -E "^[[:space:]]*$1\|" "$2" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u | grep -c . || true; }
    ON_OPD="$(_distinct_live OPCHECK "$LIVE_ON_LOG")"
    ON_TRD="$(_distinct_live TRACE "$LIVE_ON_LOG")"
    case "$ON_OPD" in ''|*[!0-9]*) ON_OPD=0 ;; esac
    case "$ON_TRD" in ''|*[!0-9]*) ON_TRD=0 ;; esac
    if [ "$ON_TRD" -ge "$ON_OPD" ] && [ "$ON_TRD" -gt 0 ]; then
      ok "ON arm: $ON_TRD distinct TRACE| line(s) for $ON_OPD distinct OPCHECK| line(s) — the model followed every derived check through, so the #2214 gate does not trip"
    else
      bad "ON arm: only $ON_TRD distinct TRACE| line(s) for $ON_OPD distinct OPCHECK| line(s) — the model wrote checks it never traced (the #2214 gate would degrade this cell)"
      grep -E '^[[:space:]]*(OPCHECK|TRACE)\|' "$LIVE_ON_LOG" | head -6 | sed 's/^/      /' >&2
    fi
    # #2223: the ON arm must also NUMBER its checks and answer them by number — the pairing key the harness
    # uses. Asserted on the live reply, because the numbering is prose the model has to follow, not code:
    # every OPCHECK line carries an id, and no derived id is left without a TRACE of the same id.
    ON_OP_IDS="$(grep -E '^[[:space:]]*OPCHECK\|' "$LIVE_ON_LOG" | sed 's/^[[:space:]]*//' | cut -d'|' -f2 | sed 's/[[:space:]]//g' | grep -cE '^#[0-9]+$' || true)"
    case "$ON_OP_IDS" in ''|*[!0-9]*) ON_OP_IDS=0 ;; esac
    if [ "$OP_N" -gt 0 ] && [ "$ON_OP_IDS" -eq "$OP_N" ]; then
      ok "ON arm: all $ON_OP_IDS OPCHECK| line(s) carry a #<k> id — the model numbered its checks (the #2223 pairing key)"
    else
      bad "ON arm: only $ON_OP_IDS of $OP_N OPCHECK| line(s) carry a #<k> id — the harness would fall back to the count rule"
      grep -E '^[[:space:]]*OPCHECK\|' "$LIVE_ON_LOG" | head -4 | sed 's/^/      /' >&2
    fi
    # ... and the pairing must RESOLVE: every derived id answered by a TRACE line carrying that id. Computed
    # here from the same grammar (the shipped functions are only sourced in part 4), so this is the live half
    # of what part 7 pins offline — the acceptance bar the count rule could not express.
    _live_ids() { grep -E "^[[:space:]]*$1\|" "$2" | sed 's/^[[:space:]]*//' | cut -d'|' -f2 | sed 's/[[:space:]]//g' | grep -E '^#[0-9]+$' | sort -u; }
    LIVE_TR_IDS=" $(_live_ids TRACE "$LIVE_ON_LOG" | tr '\n' ' ')"
    LIVE_UNPAIRED=0
    for live_id in $(_live_ids OPCHECK "$LIVE_ON_LOG"); do
      case "$LIVE_TR_IDS" in *" $live_id "*) ;; *) LIVE_UNPAIRED=$((LIVE_UNPAIRED + 1)) ;; esac
    done
    if [ "$ON_OP_IDS" -gt 0 ] && [ "$LIVE_UNPAIRED" -eq 0 ]; then
      ok "ON arm: the id pairing resolves EVERY derived check (0 unpaired of $ON_OP_IDS) — the #2223 gate does not trip on a compliant cell"
    else
      bad "ON arm: $LIVE_UNPAIRED derived check id(s) have no TRACE line of the same id — the live reply would be degraded by the #2223 gate"
      grep -E '^[[:space:]]*(OPCHECK|TRACE)\|' "$LIVE_ON_LOG" | head -8 | sed 's/^/      /' >&2
    fi
    # "Operationalize BEFORE you hunt" is an ORDERING claim — asserted by line number, not by eyeball.
    OP_LINE="$(grep -nE '^[[:space:]]*OPCHECK\|' "$LIVE_ON_LOG" | head -1 | cut -d: -f1)"
    VER_LINE="$(grep -nE '^[[:space:]]*(CANDIDATE\||SAFE[[:space:]]*$)' "$LIVE_ON_LOG" | head -1 | cut -d: -f1)"
    if [ -z "$OP_LINE" ] || [ -z "$VER_LINE" ]; then
      bad "ON arm: could not locate both the first OPCHECK| line and the first CANDIDATE|/SAFE token (OPCHECK@'$OP_LINE' verdict@'$VER_LINE')"
    elif [ "$OP_LINE" -lt "$VER_LINE" ]; then
      ok "ON arm: the first OPCHECK| line (line $OP_LINE) precedes the first CANDIDATE|/SAFE token (line $VER_LINE) — the checks really were derived BEFORE tracing"
    else
      bad "ON arm: the first OPCHECK| line (line $OP_LINE) comes AFTER the verdict (line $VER_LINE) — the checks were written up post hoc, not derived first"
    fi
  fi

  if [ ! -f "$LIVE_OFF_LOG" ]; then
    bad "OFF arm: no cell log — run-discovery.sh did not reach a verdict over the real backend"
    tail -8 "$WORK/live-off.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    OFF_OP_N="$(grep -cE '^[[:space:]]*OPCHECK\|' "$LIVE_OFF_LOG")"
    case "$OFF_OP_N" in ''|*[!0-9]*) OFF_OP_N=0 ;; esac
    OFF_TR_N="$(grep -cE '^[[:space:]]*TRACE\|' "$LIVE_OFF_LOG")"
    case "$OFF_TR_N" in ''|*[!0-9]*) OFF_TR_N=0 ;; esac
    if [ "$OFF_OP_N" -eq 0 ] && [ "$OFF_TR_N" -eq 0 ] && ! grep -q 'OPERATIONALIZE|' "$LIVE_OFF_LOG"; then
      ok "OFF arm: zero OPCHECK| lines, zero TRACE| lines and no OPERATIONALIZE| sentinel — all three appear and disappear with the flag alone (this pair IS the mutation)"
    else
      bad "OFF arm: $OFF_OP_N OPCHECK| / $OFF_TR_N TRACE| line(s) / a sentinel appeared without the flag — the OFF arm is contaminated and the A/B would not be single-variable"
    fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# PART 4 — #2214 LEVER 1: THE OPCHECK -> TRACE FOLLOW-THROUGH GATE (offline; runs in CI with no binaries).
# The measured gap: in the archived #2213 treatment arm the 6 oracles cells wrote 5/11/8/12/4/8 OPCHECK lines
# and ZERO TRACE lines, and 4 of the 6 answered SAFE — i.e. the derived checks, which ARE the method, were
# abandoned and the zone still scored as a clean sweep. Prompt text is not a gate; this is the gate.
# The shell functions under test are SLICED OUT of run-discovery.sh by line range and sourced, so this part
# measures the shipped code rather than a copy that can drift (the same idiom as the awk extraction in 10).
# ----------------------------------------------------------------------------------------------------------
note "17) the shipped gate functions slice out of run-discovery.sh and load ..."
GATE_FNS="$WORK/gate-fns.sh"
{
  sed -n '/^_distinct_sentinel_count() {$/,/^}$/p' "$DISCOVERY"
  # #2214 PR C: _opcheck_trace_gap now calls these two, so the slice must carry them or the extracted gate
  # would behave differently here than in production (which is the whole point of slicing rather than copying).
  sed -n '/^_distinct_trace_lines() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_uncited_dismissal_lines() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_uncited_dismissals() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_unresolved_trace_count() {$/,/^}$/p' "$DISCOVERY"
  # #2223: the per-check pairing helpers _opcheck_trace_gap now dispatches to, plus the predicates parts 4
  # and 7 assert on. Same rule as above — sliced, never copied.
  sed -n '/^_ids_of_lines() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_check_ids() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_count_stdin() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_untraced_rule() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_missing_check_ids() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_orphan_trace_ids() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_unnumbered_opchecks() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_uncited_check_ids() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_unresolved_check_ids() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_shortfall_id_list() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_all_checks_untraced() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_json_id_array() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_opcheck_trace_gap() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_untraced_safe() {$/,/^}$/p' "$DISCOVERY"
} > "$GATE_FNS"
GATE_LOADED=0
if grep -q '^_opcheck_trace_gap() {$' "$GATE_FNS" && grep -q '^_untraced_safe() {$' "$GATE_FNS" \
   && grep -q '^_uncited_dismissals() {$' "$GATE_FNS" && grep -q '^_unresolved_trace_count() {$' "$GATE_FNS" \
   && grep -q '^_all_checks_untraced() {$' "$GATE_FNS" && grep -q '^_missing_check_ids() {$' "$GATE_FNS" \
   && grep -q '^_untraced_rule() {$' "$GATE_FNS" && grep -q '^_unresolved_check_ids() {$' "$GATE_FNS"; then
  # shellcheck disable=SC1090  # sliced out of run-discovery.sh at runtime, by design
  . "$GATE_FNS"
  GATE_LOADED=1
  ok "the shipped gate, citation and #2223 pairing functions (_opcheck_trace_gap / _untraced_safe / _all_checks_untraced / _missing_check_ids / _untraced_rule / _uncited_check_ids / _unresolved_check_ids / ...) extracted from run-discovery.sh and sourced"
else
  bad "could not extract the #2214/#2223 gate functions from run-discovery.sh (renamed or reshaped?)"
fi

# _cell_log <name> <line...> — write a synthetic cell log and print its path.
_cell_log() {
  _cl_name="$1"; shift
  _cl_path="$WORK/$_cl_name.log"
  : > "$_cl_path"
  for _cl_line in "$@"; do printf '%s\n' "$_cl_line" >> "$_cl_path"; done
  printf '%s\n' "$_cl_path"
}
# _assert_gap <label> <log> <expected-gap> <expected-trip: yes|no> [repo_dir]
# [repo_dir] (#2225) is threaded to _opcheck_trace_gap/_untraced_safe so the EXTERNAL-branch content check
# (a cited range must STATE a fact token, not just name the file) can be exercised against real fixture files;
# omitted (the default, "") for every fixture that predates #2225 and does not need it.
_assert_gap() {
  _ag_label="$1"; _ag_log="$2"; _ag_gap="$3"; _ag_trip="$4"; _ag_repo="${5:-}"
  _ag_got="$(_opcheck_trace_gap "$_ag_log" "$_ag_repo")"
  if _untraced_safe "$_ag_log" "$_ag_repo"; then _ag_fired=yes; else _ag_fired=no; fi
  if [ "$_ag_got" = "$_ag_gap" ] && [ "$_ag_fired" = "$_ag_trip" ]; then
    ok "$_ag_label: gap=$_ag_got, gate trips=$_ag_fired (as specified)"
  else
    bad "$_ag_label: gap=$_ag_got (want $_ag_gap), gate trips=$_ag_fired (want $_ag_trip)"
  fi
}

if [ "$GATE_LOADED" -eq 1 ]; then
  note "18) the gate arithmetic: it fires on an abandoned check and NEVER on a cell that followed through ..."
  # (a) the #2213 shape, shrunk: checks derived, verdict SAFE, most of them never traced.
  UNTRACED_LOG="$(_cell_log untraced \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|the entry leg flag|both legs pass the same value' \
    'OPCHECK|the exit leg flag|both legs pass the same value' \
    'OPCHECK|the stored rate|it is refreshed before it is read' \
    'OPCHECK|the share total|it equals the sum of the per-user shares' \
    'OPCHECK|the fee cut|it is taken once per round trip' \
    'TRACE|the entry leg flag|CLEAN|the entry call passes the literal' \
    '  TRACE|the exit leg flag|UNRESOLVED|the exit path leaves this zone' \
    'SAFE')"
  _assert_gap "SAFE with 5 checks and 2 traces" "$UNTRACED_LOG" 3 yes
  # (b) full follow-through: every check answered, including an honest UNRESOLVED. This is the arm the gate
  #     must leave alone, or the directive would be punishing compliance.
  TRACED_LOG="$(_cell_log traced \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|the entry leg flag|both legs pass the same value' \
    'OPCHECK|the stored rate|it is refreshed before it is read' \
    'OPCHECK|the fee cut|it is taken once per round trip' \
    'TRACE|the entry leg flag|CLEAN|the entry call passes the literal' \
    'TRACE|the stored rate|UNRESOLVED|the setter is outside this payload' \
    'TRACE|the fee cut|CLEAN|the fee is applied in the exit path only' \
    'SAFE')"
  _assert_gap "SAFE with 3 checks and 3 traces (one honest UNRESOLVED)" "$TRACED_LOG" 0 no

  note "19) the gate is INERT with the lens off, and never re-asks a cell that produced a lead ..."
  # (c) the production default: no directive => no OPCHECK| => nothing to gate, whatever else the log holds.
  OFF_CELL_LOG="$(_cell_log lens-off \
    'BLACKBOARD-FOCUS|a sibling lead' \
    'SAFE')"
  _assert_gap "lens OFF (no OPERATIONALIZE|, no OPCHECK|)" "$OFF_CELL_LOG" 0 no
  # (d) a cell that DID surface a lead: the shortfall is real and is recorded as the `untraced` JSON field,
  #     but the cell is neither re-asked (a re-ask could lose the lead) nor failed.
  CAND_LOG="$(_cell_log candidate \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|the entry leg flag|both legs pass the same value' \
    'OPCHECK|the stored rate|it is refreshed before it is read' \
    'TRACE|the entry leg flag|BUG|the exit leg passes the opposite value' \
    'CANDIDATE|Vault.sol:exitPool:48|C23|High|the exit leg hardcodes the opposite convention|stub the pool and round-trip')"
  _assert_gap "a candidate-emitting cell with 1 untraced check" "$CAND_LOG" 1 no
  # (e) a #1707 chrome miss / #1955 timeout already owns its FAILED reason — the gate must not claim it.
  : > "$UNTRACED_LOG.novalid"
  if _untraced_safe "$UNTRACED_LOG"; then
    bad "a cell carrying a .novalid marker was claimed by the untraced gate (it would mask the chrome/timeout reason)"
  else
    ok "a cell with a .novalid/.timeout marker keeps its own FAILED reason (the gate does not claim it)"
  fi
  rm -f "$UNTRACED_LOG.novalid"

  note "20) the COUNT-RULE FALLBACK (#2223): an un-numbered transcript is still matched by DISTINCT-LINE COUNT ..."
  # These logs carry no `#k` id, so they take the count rule — the pre-#2223 arithmetic, byte for byte, kept
  # for older transcripts and for a model that ignores the numbering half of the contract. Verbatim repetition
  # cannot inflate the requirement (5 OPCHECK lines, 3 distinct) and cannot discharge it either (a pasted
  # TRACE line counts once). Part 7 pins the id rule that supersedes it whenever the checks ARE numbered.
  DUPE_LOG="$(_cell_log dupes \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|the entry leg flag|both legs pass the same value' \
    'OPCHECK|the entry leg flag|both legs pass the same value' \
    'OPCHECK|the stored rate|it is refreshed before it is read' \
    'OPCHECK|the stored rate|it is refreshed before it is read' \
    'OPCHECK|the fee cut|it is taken once per round trip' \
    'TRACE|the entry leg flag|CLEAN|the entry call passes the literal' \
    'TRACE|the stored rate|CLEAN|the setter runs first' \
    'TRACE|the fee cut|CLEAN|the fee is applied once' \
    'SAFE')"
  _assert_gap "5 OPCHECK lines (3 distinct) answered by 3 traces" "$DUPE_LOG" 0 no
  PASTED_LOG="$(_cell_log pasted \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|the entry leg flag|both legs pass the same value' \
    'OPCHECK|the stored rate|it is refreshed before it is read' \
    'OPCHECK|the fee cut|it is taken once per round trip' \
    'TRACE|the entry leg flag|CLEAN|the entry call passes the literal' \
    'TRACE|the entry leg flag|CLEAN|the entry call passes the literal' \
    'TRACE|the entry leg flag|CLEAN|the entry call passes the literal' \
    'SAFE')"
  _assert_gap "3 checks answered by the SAME trace line pasted 3 times" "$PASTED_LOG" 2 yes
else
  note "18-20) gate arithmetic, inertness and TRACE grammar ..."
  bad "skipped: the #2214 gate functions could not be sourced (see 17)"
fi

note "21) run_cell bounds the re-ask, and scrape_cell_log has a DISTINCT untraced-opcheck FAILED branch ..."
GATE_SRC_MISS=""
# The re-ask is bounded by a validated knob, default 1, 0 = gate-only. An unbounded loop over a model that
# never complies would burn a hunt budget on one cell.
grep -q 'DF_TRACE_MAX_REASKS="${DF_TRACE_MAX_REASKS:-1}"' "$DISCOVERY" || GATE_SRC_MISS="$GATE_SRC_MISS [DF_TRACE_MAX_REASKS-default-1]"
grep -q 'case "$DF_TRACE_MAX_REASKS" in' "$DISCOVERY" || GATE_SRC_MISS="$GATE_SRC_MISS [knob-validation]"
# #2235 threaded the external-cache root through as the optional THIRD argument (empty on every run without
# --external-resolve), so the pin accepts it and still fails if the loop stops passing the repo.
grep -q 'while \[ "$rc_reask" -le "$DF_TRACE_MAX_REASKS" \] && _untraced_safe "$rc_log" "$REPO" "$EXTERNAL_CACHE"; do' "$DISCOVERY" \
  || GATE_SRC_MISS="$GATE_SRC_MISS [bounded-re-ask-loop]"
# The superseded attempt is preserved, under a suffix that is NOT a `.log` (readouts and the hunt dashboard
# enumerate `hunt_*.log` and must keep seeing exactly one log per cell).
grep -q 'mv -f "$rc_log" "$rc_log.untraced-attempt-$rc_reask"' "$DISCOVERY" \
  || GATE_SRC_MISS="$GATE_SRC_MISS [attempt-preserved-under-non-.log-suffix]"
# #2225: both calls now thread $REPO through, so the EXTERNAL-branch content check can resolve a cited file.
grep -q '_opcheck_trace_gap "$rc_log" "$REPO" "$EXTERNAL_CACHE" > "$rc_log.untraced"' "$DISCOVERY" || GATE_SRC_MISS="$GATE_SRC_MISS [untraced-marker]"
grep -q 'if \[ -f "$sc_log.untraced" \]; then' "$DISCOVERY" || GATE_SRC_MISS="$GATE_SRC_MISS [scrape-untraced-branch]"
grep -q 'FAILED — untraced-opcheck: SAFE with %s untraced OPCHECK(s) (NOT a rigorous negative)' "$DISCOVERY" \
  || GATE_SRC_MISS="$GATE_SRC_MISS [distinguishable-FAILED-row]"
if [ -z "$GATE_SRC_MISS" ]; then
  ok "the re-ask is bounded (DF_TRACE_MAX_REASKS, default 1, 0 = gate-only), the superseded attempt is kept out of the *.log namespace, and the surviving shortfall becomes a distinguishable 'untraced-opcheck' FAILED row"
else
  bad "the #2214 gate wiring in run-discovery.sh regressed:$GATE_SRC_MISS"
fi
# The FAILED row must ride the EXISTING status vocabulary: lib/zone-coverage.py derives hunted_degraded from
# (exit 0 AND totals.failed > 0), so inventing a new cell status would silently drop these cells out of the
# degraded derivation and out of every downstream readout.
UNTRACED_BRANCH="$WORK/untraced-branch.txt"
awk '/if \[ -f "\$sc_log.untraced" \]; then/{f=1} f{print} f&&/^  fi$/{exit}' "$DISCOVERY" > "$UNTRACED_BRANCH"
if [ ! -s "$UNTRACED_BRANCH" ]; then
  bad "could not slice the .untraced branch out of scrape_cell_log"
elif grep -q 'FAILED_CELLS=$((FAILED_CELLS + 1))' "$UNTRACED_BRANCH" \
     && grep -q '_accumulate_cell "$sc_subsys" "$sc_cls" "$sc_files" "$sc_log" failed "$sc_phase"' "$UNTRACED_BRANCH"; then
  ok "an untraced-opcheck cell counts as FAILED and records \"status\":\"failed\" (zone-coverage.py still derives hunted_degraded; no new status vocabulary)"
else
  bad "the .untraced branch no longer increments FAILED_CELLS / records status \"failed\" — the zone would score as a trusted clean sweep"
fi
# Finally, the knob is SHELL-read: documenting it as an exec.env_passthrough entry would be cargo cult (the
# #1426 trap applies to getenv() inside an .ag agent only), and adding it there would change the hunter's env.
if grep -q '^  echo "exec.env_passthrough = .*DF_TRACE_MAX_REASKS' "$DISCOVERY"; then
  bad "DF_TRACE_MAX_REASKS was added to exec.env_passthrough — it is read by this shell, and the entry changes the hunter's env for nothing"
else
  ok "DF_TRACE_MAX_REASKS stays a SHELL-read knob (no exec.env_passthrough entry, so the hunter's env is unchanged)"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 5 — #2214 PR C: THE TWO DISMISSAL RULES, AND WHERE THEY LIVE (offline; runs in CI with no binaries).
# The M3 measurement made every check traced and the rare row was still MISSED: five cells dismissed it on
# "a trusted deployer picks that pairing", and a sibling closed CLEAN on an unverified external fact. The
# PLACEMENT is the load-bearing decision, so it is asserted, not just commented: the config rule must reach a
# cell with the lens OFF (that is where the dismissals were measured), and the external-fact rule must stay
# inside the lens block (so the lens-OFF prompt keeps its byte-identity contract).
# ----------------------------------------------------------------------------------------------------------
note "22) the config-realizability rule sits in the shared RULES block and is GENERAL (no flag, no lens) ..."
# The span between the rule and the subsystem line is asserted by CONTENT, not by a fixed line distance:
# #2235 splices two ""-when-off verb blocks (PR B's `extres`, PR C's `onchain`) in there, each with its own
# comment, #2245 iteration 2 splices a third (`rubric`) and iteration 5 a fourth (`paudit`, the PARAM_AUDIT=1
# parameter audit — also ""-when-off, pinned 0 bytes by demo-param-audit.sh) and #2256 a fifth (`fcov`, the
# FUNCTION_COVERAGE=1 READ| contract — ""-when-off, pinned 0 bytes by demo-function-coverage.sh) and #2264 a sixth
# (`bprom`, the BREADTH_PROMISES=1 PTRACE| contract — "" without a non-empty accepted block, pinned 0 bytes by
# demo-breadth-promises.sh), so a distance window would have to be widened on
# every such insertion. What must stay true is that NOTHING ELSE sits between them, and that every block that
# does is ""-when-off — an unconditional block there would change the lens-OFF prompt.
RULE_SPAN="$(sed -n '/^  + config_realizability_rule()$/,/Subsystem under review/p' "$HUNTER")"
RULE_SPAN_EXTRA="$(printf '%s\n' "$RULE_SPAN" | grep -vE '^[[:space:]]*//|^[[:space:]]*$' \
  | grep -vE '^  \+ (config_realizability_rule\(\)|rubric|paudit|fcov|bprom|extres|onchain)$' | grep -v 'Subsystem under review' || true)"
if grep -q '^  + config_realizability_rule()$' "$HUNTER" \
   && grep -A5 'Never report a listed KNOWN ISSUE' "$HUNTER" | grep -q '+ config_realizability_rule()' \
   && printf '%s\n' "$RULE_SPAN" | grep -q 'Subsystem under review' \
   && [ -z "$RULE_SPAN_EXTRA" ]; then
  ok "'+ config_realizability_rule()' is spliced INSIDE the === RULES === block, right after the trusted-role exclusion it qualifies, and ahead of the subsystem line, with only the #2235/#2245 \"\"-when-off blocks between them"
else
  bad "the config-realizability rule is not spliced into the RULES block between the trusted-role exclusion and the subsystem line${RULE_SPAN_EXTRA:+ (unexpected line(s) in the span: $RULE_SPAN_EXTRA)}"
fi
RULE_BODY="$WORK/config-rule-body.txt"
awk '/^fn config_realizability_rule\(/{f=1} f{print} f&&/^}$/{exit}' "$HUNTER" > "$RULE_BODY"
if [ ! -s "$RULE_BODY" ]; then
  bad "could not slice config_realizability_rule() out of hunter.ag"
elif grep -q 'getenv(' "$RULE_BODY"; then
  bad "config_realizability_rule() consults getenv() — the rule would be flag-gated, and the measured dismissals happened with the lens UNSET"
else
  ok "config_realizability_rule() reads no env: the rule is unconditional, so it reaches the lens-OFF cells that produced the measured dismissals"
fi
# Exactly ONE call site (the RULES splice). A second one inside the lens plumbing would quietly make the
# general rule lens-dependent again.
RULE_CALLS="$(grep -c '^[^/]*config_realizability_rule()' "$HUNTER")"
case "$RULE_CALLS" in ''|*[!0-9]*) RULE_CALLS=0 ;; esac
if [ "$RULE_CALLS" -eq 2 ]; then
  ok "config_realizability_rule() has exactly one declaration and one call site (the RULES splice)"
else
  bad "config_realizability_rule() appears at $RULE_CALLS code sites (want 2: the declaration and the single RULES splice)"
fi
note "23) the placement decision is enforced: config rule OUTSIDE the lens block, external-fact rule INSIDE ..."
PRC_BLOCK_BODY="$WORK/operationalize-body-prc.txt"
awk '/^fn operationalize_block\(/{f=1} f{print} f&&/^}$/{exit}' "$HUNTER" > "$PRC_BLOCK_BODY"
if [ ! -s "$PRC_BLOCK_BODY" ]; then
  bad "could not slice operationalize_block() for the #2214 PR C placement check"
else
  if grep -qi 'CONFIGURATION REALIZABILITY\|config_realizability_rule' "$PRC_BLOCK_BODY"; then
    bad "the config-realizability rule leaked INTO operationalize_block() — it would vanish on every lens-OFF cell, which is where the dismissals were measured"
  else
    ok "the config rule is NOT inside the lens block (a lens-OFF cell still gets it)"
  fi
  if grep -q 'EXTERNAL FACTS' "$PRC_BLOCK_BODY"; then
    ok "the external-fact rule IS inside the lens block (it extends the TRACE grammar, so the lens-OFF prompt keeps its byte-identity contract)"
  else
    bad "the external-fact rule is not inside operationalize_block() — either it is missing, or it changed the lens-OFF prompt"
  fi
  # The same overfitting denylist part 8 applies to the lens text: this rule rides EVERY prompt, so a
  # domain hint here would leak an answer into every hunt, not just the opted-in ones.
  if grep -Eq "$DENY" "$RULE_BODY"; then
    bad "the config-realizability rule names a protocol/product/parameter specific (it rides every prompt — this would leak an answer into every hunt)"
    grep -nE "$DENY" "$RULE_BODY" | head -3 | sed 's/^/      /' >&2
  else
    ok "the config-realizability rule stays pure-meta (no protocol, contract, flag, unit or product name)"
  fi
fi
note "24) both rules carry their load-bearing sentences ..."
PRC_MISS=""
for s_prc in \
  "CONFIGURATION REALIZABILITY (this governs every dismissal on configuration grounds)." \
  "The audited repository's OWN configuration is part of the audit." \
  "search THIS repository — deployment scripts, tests, fixtures, example configs and documentation" \
  "check whether the constructor or the setter VALIDATES that pairing at all" \
  "a pairing this repository itself ships, documents, or accepts WITHOUT validation is IN SCOPE" \
  "Every such dismissal MUST cite the file:line you checked" \
  "A configuration-grounds dismissal with NO file:line citation is not a result: record the check as UNRESOLVED"
do
  case "$HUNTER_FLAT" in *"$s_prc"*) ;; *) PRC_MISS="$PRC_MISS [$s_prc]" ;; esac
done
if [ -z "$PRC_MISS" ]; then
  ok "the config rule keeps the grep-the-repo obligation, the constructor/setter validation check, the in-scope rule and the file:line citation requirement"
else
  bad "the #2214 PR C config rule lost load-bearing text:$PRC_MISS"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 6 — #2214 PR C / #2225: CITATION DISCIPLINE, MEASURED ON THE SHIPPED DETECTORS (offline; CI floor).
# The detectors are HEURISTICS over model-emitted free text (documented as such in run-discovery.sh's header)
# and they ride the EXISTING gate: an uncited dismissal is added to the follow-through shortfall, so it is
# re-asked once and then recorded with the SAME `untraced-opcheck` reason. No new status vocabulary.
# #2225: rule 2 (EXTERNAL grounds) as shipped by #2214 accepted a citation by NAME (a URL, a bare source-file
# name, a bare interface identifier) with no check that the cited text says anything at all — measured M-12
# went 2/3 -> 0/3 on exactly that shape. The fixtures below use a synthetic two-file "repo" (no real protocol
# named, per this repo's public-content rule) so the EXTERNAL-branch content check can be exercised against
# real cited ranges, not just prose.
# ----------------------------------------------------------------------------------------------------------
EXT_REPO="$WORK/ext-repo"
mkdir -p "$EXT_REPO/interfaces" "$EXT_REPO/vendor"
{
  echo "// synthetic fixture interface: getters only, states no scaling/normalisation fact"
  echo "interface IRateSource {"
  echo "    function getRate() external view returns (uint256);"
  echo "    function getRateSource() external view returns (address);"
  echo "}"
} > "$EXT_REPO/interfaces/IRateSource.sol"
{
  echo "// synthetic fixture library: the cited line states the fixed-point unit outright"
  echo "library FixedPointMath {"
  echo "    uint256 internal constant UNIT = 1e18;"
  echo "}"
} > "$EXT_REPO/vendor/FixedPointMath.sol"

if [ "$GATE_LOADED" -eq 1 ]; then
  note "25) a config-grounds dismissal: accepted WITH a path:line citation, untraced WITHOUT one ..."
  # (a) the dismissal did the work the rule asks for and says where it looked.
  CFG_CITED_LOG="$(_cell_log cfg-cited \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|the flag-vs-source pairing|the configured pair must agree on the referent' \
    'OPCHECK|the fee cut|it is taken once per round trip' \
    'TRACE|the flag-vs-source pairing|CLEAN|script/DeployVault.s.sol:115 configures the matching pair and the constructor rejects the other one, so the deploy-time choice is validated' \
    'TRACE|the fee cut|CLEAN|the fee is applied in the exit path only' \
    'SAFE')"
  _assert_gap "config-grounds dismissal WITH a path:line citation" "$CFG_CITED_LOG" 0 no
  # (b) the same dismissal with the citation removed: the cell asserted a configuration fact it never checked.
  CFG_UNCITED_LOG="$(_cell_log cfg-uncited \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|the flag-vs-source pairing|the configured pair must agree on the referent' \
    'OPCHECK|the fee cut|it is taken once per round trip' \
    'TRACE|the flag-vs-source pairing|CLEAN|a valid configuration exists and only the trusted deployer can pair them wrongly, so it is a deploy-time misconfiguration' \
    'TRACE|the fee cut|CLEAN|the fee is applied in the exit path only' \
    'SAFE')"
  _assert_gap "the same dismissal WITHOUT a citation" "$CFG_UNCITED_LOG" 1 yes
  # (e) the VERBATIM sentence a measured arm-run produced on the rare row this PR exists for (referents
  #     genericised, dismissal clause word for word). If the detector does not trip on this, it is decoration.
  MEASURED_LOG="$(_cell_log cfg-measured \
    'OPERATIONALIZE|vault|C22|on' \
    'OPCHECK|the cross-issuer rate presumption|the two sides must be denominated in the same unit' \
    'TRACE|the cross-issuer rate presumption|CLEAN|But: it exists only under a specific deploy-time pairing ... set by the trusted deployer ... not an attacker-triggerable code seam ... out of scope' \
    'SAFE')"
  _assert_gap "the VERBATIM measured dismissal sentence" "$MEASURED_LOG" 1 yes
  # (#2225 item 3) directory-scoped citation shape: a test-evidence path is acceptable proof of what the repo
  # ships; a src/ contract only DECLARES the flag, it does not say what value is actually configured for it.
  CFG_TESTDIR_LOG="$(_cell_log cfg-testdir \
    'OPERATIONALIZE|vault|C22|on' \
    'OPCHECK|the cross-issuer rate presumption|the two sides must be denominated in the same unit' \
    'TRACE|the cross-issuer rate presumption|CLEAN|tests/TestStrategyImpl.sol:110-117 wires the mismatched pair and only a trusted deployer sets it, so it is a deploy-time misconfiguration' \
    'SAFE')"
  _assert_gap "config-grounds dismissal citing a tests/ path:line range" "$CFG_TESTDIR_LOG" 0 no
  CFG_SRCDIR_LOG="$(_cell_log cfg-srcdir \
    'OPERATIONALIZE|vault|C22|on' \
    'OPCHECK|the cross-issuer rate presumption|the two sides must be denominated in the same unit' \
    'TRACE|the cross-issuer rate presumption|CLEAN|src/PriceOracle.sol:49 declares the flag and only a trusted deployer sets it, so it is a deploy-time misconfiguration' \
    'SAFE')"
  _assert_gap "the same dismissal citing a src/ path:line (names the flag, not what is shipped)" "$CFG_SRCDIR_LOG" 1 yes
  # (h) #2225 QA fix: a well-shaped tests/ citation whose FILE DOES NOT EXIST under the repo — a fabricated
  # or hallucinated path:line is not "in this repository" either, and must not pass on shape alone.
  CFG_MISSING_LOG="$(_cell_log cfg-missing \
    'OPERATIONALIZE|vault|C22|on' \
    'OPCHECK|the cross-issuer rate presumption|the two sides must be denominated in the same unit' \
    'TRACE|the cross-issuer rate presumption|CLEAN|tests/Missing.t.sol:5 wires the mismatched pair and only a trusted deployer sets it, so it is a deploy-time misconfiguration' \
    'SAFE')"
  _assert_gap "config-grounds dismissal citing a tests/ path:line whose file does not exist" "$CFG_MISSING_LOG" 1 yes "$EXT_REPO"
  # Without a repo_dir, the same non-existent citation falls back to the shape-only check (accepted) — the
  # documented empty-repo_dir behaviour, not a regression: existence cannot be resolved with no repo to check.
  _assert_gap "the same citation with no repo_dir given (existence unverifiable, shape accepted)" "$CFG_MISSING_LOG" 0 no

  note "26) an external-protocol claim: needs an IN-REPO citation that STATES the fact, not just names a source ..."
  # (c) the M-12 shape, in its three uncited forms: a bare URL, a bare interface identifier, a bare library
  # name. #2225 drops all three acceptances for THIS branch — none of them points at text stating the fact.
  EXT_UNCITED_LOG="$(_cell_log ext-uncited \
    'OPERATIONALIZE|vault|C2|on' \
    'OPCHECK|the external rate read|the returned value must carry the unit this zone assumes' \
    'TRACE|the external rate read|CLEAN|the call always returns a normalised ratio by construction, a documented invariant of the upstream protocol' \
    'SAFE')"
  _assert_gap "external-fact CLEAN with no source at all" "$EXT_UNCITED_LOG" 1 yes
  EXT_URL_LOG="$(_cell_log ext-url \
    'OPERATIONALIZE|vault|C2|on' \
    'OPCHECK|the external rate read|the returned value must carry the unit this zone assumes' \
    'TRACE|the external rate read|CLEAN|documented at https://docs.example-protocol.test/rates, it always returns a normalised ratio' \
    'SAFE')"
  _assert_gap "external-fact CLEAN citing a bare URL" "$EXT_URL_LOG" 1 yes
  EXT_IFACE_LOG="$(_cell_log ext-iface \
    'OPERATIONALIZE|vault|C2|on' \
    'OPCHECK|the external rate read|the returned value must carry the unit this zone assumes' \
    'TRACE|the external rate read|CLEAN|IRateSource.getRate always returns a normalised ratio by construction' \
    'SAFE')"
  _assert_gap "external-fact CLEAN naming a bare interface identifier, no path:line" "$EXT_IFACE_LOG" 1 yes
  EXT_LIBNAME_LOG="$(_cell_log ext-libname \
    'OPERATIONALIZE|vault|C2|on' \
    'OPCHECK|the external rate read|the returned value must carry the unit this zone assumes' \
    'TRACE|the external rate read|CLEAN|FixedPointMath always returns the normalised ratio by design, a well-known convention' \
    'SAFE')"
  _assert_gap "external-fact CLEAN naming a bare library, no path:line" "$EXT_LIBNAME_LOG" 1 yes

  # (a) a real repo path:line whose cited RANGE only declares getters — names the file, states no fact.
  EXT_GETTERS_LOG="$(_cell_log ext-getters \
    'OPERATIONALIZE|vault|C2|on' \
    'OPCHECK|the external rate read|the returned value must carry the unit this zone assumes' \
    'TRACE|the external rate read|CLEAN|interfaces/IRateSource.sol:3-4 documents the getters this call reads, so it always returns a normalised ratio' \
    'SAFE')"
  _assert_gap "external-fact CLEAN citing a getters-only repo range" "$EXT_GETTERS_LOG" 1 yes "$EXT_REPO"
  # (b) a real repo path:line whose cited range literally STATES the fact (the fixed-point unit) — accepted.
  EXT_STATED_LOG="$(_cell_log ext-stated \
    'OPERATIONALIZE|vault|C2|on' \
    'OPCHECK|the external rate read|the returned value must carry the unit this zone assumes' \
    'TRACE|the external rate read|CLEAN|vendor/FixedPointMath.sol:3 fixes the unit, so it always returns the same normalised ratio' \
    'SAFE')"
  _assert_gap "external-fact CLEAN citing a range that states the unit" "$EXT_STATED_LOG" 0 no "$EXT_REPO"
  # Without a repo to resolve the citation against, the same cited range falls back to the shape check alone
  # (accepted) — the content check degrades gracefully rather than false-failing on an unresolvable path.
  _assert_gap "the same citation with no repo_dir given (content unverifiable, shape accepted)" "$EXT_STATED_LOG" 0 no
  # (g) #2225 QA fix: a well-shaped citation whose FILE DOES NOT EXIST under the repo — a fabricated or
  # hallucinated path:line is not "in this repository" either, so it must not be accepted as verified.
  EXT_MISSING_LOG="$(_cell_log ext-missing \
    'OPERATIONALIZE|vault|C2|on' \
    'OPCHECK|the external rate read|the returned value must carry the unit this zone assumes' \
    'TRACE|the external rate read|CLEAN|lib/Nonexistent.sol:12 fixes the unit, so it always returns the same normalised ratio' \
    'SAFE')"
  _assert_gap "external-fact CLEAN citing a repo range whose file does not exist" "$EXT_MISSING_LOG" 1 yes "$EXT_REPO"
  # Without a repo_dir, the same non-existent citation falls back to the shape-only check (accepted) — the
  # documented empty-repo_dir behaviour, not a regression: existence cannot be resolved with no repo to check.
  _assert_gap "the same citation with no repo_dir given (existence unverifiable, shape accepted)" "$EXT_MISSING_LOG" 0 no

  note "27) UNRESOLVED is the honest verdict the rules ask for — counted, never a dismissal, never SAFE-trusted ..."
  # An UNRESOLVED check carries the same "I could not verify it" words as an uncited CLEAN and must NOT be
  # punished for them: the rules ask for exactly this verdict.
  UNRES_LOG="$(_cell_log unresolved \
    'OPERATIONALIZE|vault|C2|on' \
    'OPCHECK|the external rate read|the returned value must carry the unit this zone assumes' \
    'OPCHECK|the flag-vs-source pairing|the configured pair must agree on the referent' \
    'TRACE|the external rate read|UNRESOLVED|the callee is outside this payload and its documented normalisation could not be verified from what I was given' \
    'TRACE|the flag-vs-source pairing|UNRESOLVED|no deployment script or test in this payload sets the pair, so the trusted-deployer claim is unchecked' \
    'SAFE')"
  _assert_gap "two honest UNRESOLVED verdicts" "$UNRES_LOG" 0 no
  UNRES_N="$(_unresolved_trace_count "$UNRES_LOG")"
  if [ "$UNRES_N" = "2" ]; then
    ok "_unresolved_trace_count reports 2 distinct UNRESOLVED checks (the additive per-cell \"unresolved\" field; they do not fold into SAFE unseen)"
  else
    bad "_unresolved_trace_count reported '$UNRES_N' for a cell with two UNRESOLVED checks"
  fi
  # Repetition cannot inflate the counter either (same discipline as the gap arithmetic).
  UNRES_DUPE_LOG="$(_cell_log unresolved-dupes \
    'OPERATIONALIZE|vault|C2|on' \
    'OPCHECK|the external rate read|the returned value must carry the unit this zone assumes' \
    'TRACE|the external rate read|UNRESOLVED|the callee is outside this payload' \
    'TRACE|the external rate read|UNRESOLVED|the callee is outside this payload' \
    'SAFE')"
  UNRES_DUPE_N="$(_unresolved_trace_count "$UNRES_DUPE_LOG")"
  if [ "$UNRES_DUPE_N" = "1" ]; then
    ok "a pasted UNRESOLVED line counts once (distinct-line discipline, same as the gap arithmetic)"
  else
    bad "the UNRESOLVED counter counted a pasted duplicate ('$UNRES_DUPE_N' for one distinct check)"
  fi

  note "28) the citation detectors are INERT with the lens off ..."
  # The dismissal prose is there, but with no lens there are no TRACE| lines and no sentinel: nothing to gate.
  PRC_OFF_LOG="$(_cell_log prc-lens-off \
    'BLACKBOARD-FOCUS|a sibling lead' \
    'This pairing is a deploy-time misconfiguration set by the trusted deployer, so it is out of scope.' \
    'SAFE')"
  _assert_gap "lens OFF, dismissal prose in the reply text" "$PRC_OFF_LOG" 0 no
  PRC_OFF_UNRES="$(_unresolved_trace_count "$PRC_OFF_LOG")"
  if [ "$PRC_OFF_UNRES" = "0" ]; then
    ok "a lens-OFF cell reports 0 unresolved checks, so its JSON key set is byte-identical to the pre-#2214 one"
  else
    bad "a lens-OFF cell reported '$PRC_OFF_UNRES' unresolved checks — its JSON would gain a key"
  fi
else
  note "25-28) #2214 PR C citation fixtures ..."
  bad "skipped: the gate functions could not be sourced (see 17)"
fi

note "29) the harness pin reuses the EXISTING gate: same re-ask, same reason, one additive JSON key ..."
PRC_SRC_MISS=""
grep -q '#2214 PR C — CITATION DISCIPLINE ON A DISMISSAL' "$DISCOVERY" \
  || PRC_SRC_MISS="$PRC_SRC_MISS [heuristics-documented-in-header]"
grep -q 'otg_unc="$(_uncited_dismissals "$otg_log" "$otg_repo" "$otg_cache")"' "$DISCOVERY" \
  || PRC_SRC_MISS="$PRC_SRC_MISS [uncited-folded-into-the-gap]"
grep -q 'if \[ "$ac_unres" -gt 0 \]; then ac_unresolved_json=' "$DISCOVERY" \
  || PRC_SRC_MISS="$PRC_SRC_MISS [unresolved-key-only-when-non-zero]"
grep -q '"\$ac_untraced_json" "\$ac_unresolved_json" \\' "$DISCOVERY" \
  || PRC_SRC_MISS="$PRC_SRC_MISS [unresolved-key-after-untraced]"
grep -q 'UNRESOLVED check(s)' "$DISCOVERY" || PRC_SRC_MISS="$PRC_SRC_MISS [unresolved-surfaced-to-the-operator]"
if [ -z "$PRC_SRC_MISS" ]; then
  ok "the detectors are documented as heuristics in the header, fold into _opcheck_trace_gap, and the \"unresolved\" key is additive, non-zero-only and LAST"
else
  bad "the #2214 PR C wiring in run-discovery.sh regressed:$PRC_SRC_MISS"
fi
# No new status vocabulary: the FAILED row an uncited dismissal produces is the EXISTING untraced-opcheck one.
if grep -E 'printf .*FAILED — ' "$DISCOVERY" | grep -qi 'uncited\|citation'; then
  bad "a NEW FAILED reason was invented for uncited dismissals — the pin must reuse the untraced-opcheck row (zone-coverage.py knows no other vocabulary)"
else
  ok "an uncited dismissal rides the existing 'untraced-opcheck' FAILED row (no new status vocabulary for the dashboard/coverage derivation to learn)"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 7 — #2223: PER-CHECK PAIRING BY ID (offline; runs in CI with no binaries).
# The #2222 QA counter-example is the reason this part exists: 3 OPCHECK lines answered by 3 distinct but
# semantically UNRELATED TRACE lines satisfy a COUNT rule exactly (gap 0, gate silent). With the checks
# numbered, the same reply answers nothing. The second half of the change is the DEGRADATION UNIT: a partial
# shortfall marks the CHECK, not the cell, because the #2214 M3 `dismissal` r1 C23 cell carried the rare row
# as a correct UNRESOLVED and was discarded for one unrelated uncited line beside it.
# The functions under test are the SAME sliced-out shipped ones part 4 loaded (see 17).
# ----------------------------------------------------------------------------------------------------------
# _assert_cell <label> <log> <rule> <gap> <trip: yes|no> <fails-wholesale: yes|no> [repo_dir]
# The four things a cell's record has to say under #2223: which rule decided it, how many checks are open,
# whether the gate re-asks it, and whether the FAILED-row path claims it.
_assert_cell() {
  _ac_label="$1"; _ac_log="$2"; _ac_rule="$3"; _ac_gap="$4"; _ac_trip="$5"; _ac_fail="$6"; _ac_repo="${7:-}"
  _ac_got_rule="$(_untraced_rule "$_ac_log")"
  _ac_got_gap="$(_opcheck_trace_gap "$_ac_log" "$_ac_repo")"
  if _untraced_safe "$_ac_log" "$_ac_repo"; then _ac_got_trip=yes; else _ac_got_trip=no; fi
  if _all_checks_untraced "$_ac_log"; then _ac_got_fail=yes; else _ac_got_fail=no; fi
  if [ "$_ac_got_rule" = "$_ac_rule" ] && [ "$_ac_got_gap" = "$_ac_gap" ] \
     && [ "$_ac_got_trip" = "$_ac_trip" ] && [ "$_ac_got_fail" = "$_ac_fail" ]; then
    ok "$_ac_label: rule=$_ac_got_rule, open=$_ac_got_gap, re-ask=$_ac_got_trip, FAILED-row=$_ac_got_fail (as specified)"
  else
    bad "$_ac_label: rule=$_ac_got_rule/$_ac_rule, open=$_ac_got_gap/$_ac_gap, re-ask=$_ac_got_trip/$_ac_trip, FAILED-row=$_ac_got_fail/$_ac_fail"
  fi
}

if [ "$GATE_LOADED" -eq 1 ]; then
  note "30) ids pair a trace to its check: matching ids pass, UNRELATED trace lines no longer discharge them ..."
  # (a) the compliant shape: three numbered checks, three answers under the same numbers.
  ID_OK_LOG="$(_cell_log id-ok \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|#1|the entry leg flag|both legs pass the same value' \
    'OPCHECK|#2|the stored rate|it is refreshed before it is read' \
    'OPCHECK|#3|the fee cut|it is taken once per round trip' \
    'TRACE|#1|CLEAN|the entry call passes the literal' \
    'TRACE|#2|CLEAN|the setter runs in the same statement' \
    'TRACE|#3|CLEAN|the fee is applied in the exit path only' \
    'SAFE')"
  _assert_cell "3 numbered checks answered by their 3 ids" "$ID_OK_LOG" id 0 no no
  # (b) THE #2222 QA COUNTER-EXAMPLE: three distinct TRACE lines, none of them naming a derived id — one
  #     wrong id, one restating a check the pre-#2223 grammar allowed, one about something else entirely.
  #     The count rule scored this 0. It answers nothing, so it is the ONE shape that still fails wholesale.
  ID_UNRELATED_LOG="$(_cell_log id-unrelated \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|#1|the entry leg flag|both legs pass the same value' \
    'OPCHECK|#2|the stored rate|it is refreshed before it is read' \
    'OPCHECK|#3|the fee cut|it is taken once per round trip' \
    'TRACE|#7|CLEAN|a check this cell never derived' \
    'TRACE|the stored rate|CLEAN|the setter runs in the same statement' \
    'TRACE|the deposit path|CLEAN|nothing in the derived list is about this' \
    'SAFE')"
  _assert_cell "3 ids answered by 3 unrelated TRACE lines (the #2222 counter-example)" "$ID_UNRELATED_LOG" id 3 yes yes
  ID_UNRELATED_NAMED="$(_shortfall_id_list "$ID_UNRELATED_LOG")"
  if [ "$ID_UNRELATED_NAMED" = "#1, #2, #3" ]; then
    ok "the re-ask names the missing ids explicitly ($ID_UNRELATED_NAMED) — the count rule could not name one"
  else
    bad "the re-ask id list is '$ID_UNRELATED_NAMED' (want '#1, #2, #3')"
  fi
  # (c) an orphan: every derived check IS answered, and one extra trace names an id that does not exist.
  #     It discharges nothing and is counted on its own — a renumbered or invented answer is a defect, not a
  #     silent no-op, but it is not a shortfall either (nothing was left open).
  ID_ORPHAN_LOG="$(_cell_log id-orphan \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|#1|the entry leg flag|both legs pass the same value' \
    'OPCHECK|#2|the stored rate|it is refreshed before it is read' \
    'TRACE|#1|CLEAN|the entry call passes the literal' \
    'TRACE|#2|CLEAN|the setter runs in the same statement' \
    'TRACE|#9|CLEAN|a check that was never derived in this cell' \
    'SAFE')"
  _assert_cell "a TRACE naming a non-existent id" "$ID_ORPHAN_LOG" id 0 no no
  ID_ORPHAN_N="$(_orphan_trace_ids "$ID_ORPHAN_LOG" | _count_stdin)"
  if [ "$ID_ORPHAN_N" = "1" ]; then
    ok "trace_orphans=1 for the id no OPCHECK line declares (counted, never able to discharge a check)"
  else
    bad "trace_orphans reported '$ID_ORPHAN_N' for one orphan trace id"
  fi

  note "31) DEGRADATION IS PER CHECK: one uncited dismissal no longer discards the cell's correct UNRESOLVED ..."
  # The measured shape (#2214 M3 `dismissal` r1, C23): four checks, all traced. #2 is closed on an uncited
  # configuration dismissal; #4 carries the rare row honestly as UNRESOLVED. Before #2223 the whole cell was
  # failed and the UNRESOLVED carry went with it. Now the cell is `ok`, #2 is named as uncited, and #4
  # survives WITH its check text — which is the record #2217 consumes.
  ID_MIXED_LOG="$(_cell_log id-mixed \
    'OPERATIONALIZE|vault|C22|on' \
    'OPCHECK|#1|the share totals|they equal the sum of the per-user shares' \
    'OPCHECK|#2|the flag-vs-source pairing|the configured pair must agree on the referent' \
    'OPCHECK|#3|the fee cut|it is taken once per round trip' \
    'OPCHECK|#4|the cross-issuer rate presumption|the two sides must be denominated in the same unit' \
    'TRACE|#1|CLEAN|both totals are updated in the same statement' \
    'TRACE|#2|CLEAN|a valid configuration exists and only the trusted deployer can pair them wrongly, so it is a deploy-time misconfiguration' \
    'TRACE|#3|CLEAN|the fee is applied in the exit path only' \
    'TRACE|#4|UNRESOLVED|no deployment script or test in this payload sets the pair, so the presumption could not be settled here' \
    'SAFE')"
  _assert_cell "one uncited check beside a correct UNRESOLVED carry" "$ID_MIXED_LOG" id 1 yes no
  ID_MIXED_UNCITED="$(_uncited_check_ids "$ID_MIXED_LOG" | _json_id_array)"
  if [ "$ID_MIXED_UNCITED" = "2" ]; then
    ok "uncited_ids=[2] — the citation rules of #2224/#2227 mark THAT check, not the cell"
  else
    bad "uncited_ids=[$ID_MIXED_UNCITED] (want [2]) — the per-trace attribution is wrong"
  fi
  ID_MIXED_UNRES="$(_unresolved_check_ids "$ID_MIXED_LOG" | cut -f1 | _json_id_array)"
  ID_MIXED_UNRES_TXT="$(_unresolved_check_ids "$ID_MIXED_LOG" | cut -f2-)"
  if [ "$ID_MIXED_UNRES" = "4" ] && [ -n "$ID_MIXED_UNRES_TXT" ]; then
    case "$ID_MIXED_UNRES_TXT" in
      *"cross-issuer rate presumption"*)
        ok "unresolved_ids=[4] carries the check's own text ('$(printf '%s' "$ID_MIXED_UNRES_TXT" | cut -c1-48)...') — the carry survives the cell for #2217" ;;
      *) bad "unresolved_ids=[4] carries the wrong check text: '$ID_MIXED_UNRES_TXT'" ;;
    esac
  else
    bad "unresolved_ids=[$ID_MIXED_UNRES] (want [4], with the OPCHECK text attached)"
  fi
  # The FAILED-row path is reserved for a cell that answered NOTHING it derived — the #2213 shape.
  ID_NONE_LOG="$(_cell_log id-none \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|#1|the entry leg flag|both legs pass the same value' \
    'OPCHECK|#2|the stored rate|it is refreshed before it is read' \
    'SAFE')"
  _assert_cell "the #2213 shape: checks derived, none traced" "$ID_NONE_LOG" id 2 yes yes

  note "32) the count rule is the FALLBACK, and only for a transcript that numbered nothing ..."
  # (e) a legacy cell: OPCHECK lines with no id at all. It keeps the pre-#2223 arithmetic and reports which
  #     rule decided it, so a readout can tell a legacy cell from a numbered one without re-reading the log.
  LEGACY_LOG="$(_cell_log id-legacy \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|the entry leg flag|both legs pass the same value' \
    'OPCHECK|the stored rate|it is refreshed before it is read' \
    'TRACE|the entry leg flag|CLEAN|the entry call passes the literal' \
    'SAFE')"
  _assert_cell "a legacy transcript with no ids" "$LEGACY_LOG" count 1 yes no
  LEGACY_IDS="$(_shortfall_id_list "$LEGACY_LOG")"
  if [ -z "$LEGACY_IDS" ]; then
    ok "untraced_rule=count and the re-ask names no id (a count-rule cell cannot name one — the re-ask stays the pre-#2223 verbatim replay)"
  else
    bad "a count-rule cell produced an id list ('$LEGACY_IDS') — it has no ids to name"
  fi
  # A cell that numbered SOME of its checks is under the id rule, and the un-numbered ones still count: they
  # can be paired with nothing, so they are open checks (they just have no id for the re-ask to name).
  PARTIAL_ID_LOG="$(_cell_log id-partial \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|#1|the entry leg flag|both legs pass the same value' \
    'OPCHECK|the stored rate|it is refreshed before it is read' \
    'TRACE|#1|CLEAN|the entry call passes the literal' \
    'SAFE')"
  _assert_cell "a half-numbered cell (one un-numbered check left open)" "$PARTIAL_ID_LOG" id 1 yes no

  note "33) lens OFF: no rule, no ids, no new JSON key ..."
  # (f) the production default. No OPCHECK line => no rule is recorded at all => every #2223 field is ABSENT
  #     (not empty, not `[]`), so a lens-OFF cell's JSON key set is byte-identical to the pre-#2223 one.
  OFF_ID_LOG="$(_cell_log id-lens-off \
    'BLACKBOARD-FOCUS|a sibling lead' \
    'This pairing is a deploy-time misconfiguration set by the trusted deployer, so it is out of scope.' \
    'SAFE')"
  _assert_cell "lens OFF (no OPERATIONALIZE|, no OPCHECK|)" "$OFF_ID_LOG" "" 0 no no
  OFF_FIELDS=""
  [ -z "$(_untraced_rule "$OFF_ID_LOG")" ] || OFF_FIELDS="$OFF_FIELDS [untraced_rule]"
  [ "$(_orphan_trace_ids "$OFF_ID_LOG" | _count_stdin)" = "0" ] || OFF_FIELDS="$OFF_FIELDS [trace_orphans]"
  [ -z "$(_missing_check_ids "$OFF_ID_LOG" | _json_id_array)" ] || OFF_FIELDS="$OFF_FIELDS [untraced_ids]"
  [ -z "$(_uncited_check_ids "$OFF_ID_LOG" | _json_id_array)" ] || OFF_FIELDS="$OFF_FIELDS [uncited_ids]"
  [ -z "$(_unresolved_check_ids "$OFF_ID_LOG")" ] || OFF_FIELDS="$OFF_FIELDS [unresolved_ids]"
  if [ -z "$OFF_FIELDS" ]; then
    ok "a lens-OFF cell produces no rule, no orphans and no id lists — all five #2223 keys are absent, so its JSON key set is unchanged"
  else
    bad "a lens-OFF cell would gain #2223 key(s):$OFF_FIELDS"
  fi
else
  note "30-33) #2223 per-check pairing fixtures ..."
  bad "skipped: the gate functions could not be sourced (see 17)"
fi

note "34) the #2223 wiring in run-discovery.sh and hunter.ag ..."
ID_SRC_MISS=""
# The five additive JSON fields, each emitted only when it carries something (a lens-OFF cell keeps its key set).
grep -q 'if \[ -n "$ac_rule" \]; then ac_rule_json=' "$DISCOVERY" || ID_SRC_MISS="$ID_SRC_MISS [untraced_rule-key]"
grep -q 'if \[ "$ac_orph" -gt 0 \]; then ac_orphans_json=' "$DISCOVERY" || ID_SRC_MISS="$ID_SRC_MISS [trace_orphans-key]"
grep -q 'if \[ -n "$ac_untraced_ids" \]; then ac_untraced_ids_json=' "$DISCOVERY" || ID_SRC_MISS="$ID_SRC_MISS [untraced_ids-key]"
grep -q 'if \[ -n "$ac_uncited_ids" \]; then ac_uncited_ids_json=' "$DISCOVERY" || ID_SRC_MISS="$ID_SRC_MISS [uncited_ids-key]"
grep -q 'if \[ -n "$ac_unresolved_ids" \]; then ac_unresolved_ids_json=' "$DISCOVERY" || ID_SRC_MISS="$ID_SRC_MISS [unresolved_ids-key]"
# The FAILED marker is written ONLY for a total shortfall — this is the whole per-check degradation change.
grep -q 'if _untraced_safe "$rc_log" "$REPO" "$EXTERNAL_CACHE" && _all_checks_untraced "$rc_log"; then' "$DISCOVERY" \
  || ID_SRC_MISS="$ID_SRC_MISS [FAILED-row-only-when-every-check-untraced]"
# The re-ask names the ids, and carries them into the prompt through a registered passthrough entry.
grep -q 'rc_reask_ids="$(_shortfall_id_list "$rc_log" "$REPO" "$EXTERNAL_CACHE")"' "$DISCOVERY" || ID_SRC_MISS="$ID_SRC_MISS [re-ask-names-ids]"
grep -q 'TRACE_REASK_IDS="$rc_reask_ids"' "$DISCOVERY" || ID_SRC_MISS="$ID_SRC_MISS [re-ask-ids-in-cell-env]"
grep -q '^  echo "exec.env_passthrough = .*,TRACE_REASK_IDS' "$DISCOVERY" || ID_SRC_MISS="$ID_SRC_MISS [TRACE_REASK_IDS-passthrough]"
# The status semantics are STATED in the script header, not left to be reverse-engineered from the branches.
grep -q '#2223 — PER-CHECK PAIRING BY ID, AND THE EXACT STATUS SEMANTICS' "$DISCOVERY" \
  || ID_SRC_MISS="$ID_SRC_MISS [status-semantics-in-header]"
# hunter.ag's re-ask block is lens-gated (it is concatenated INSIDE operationalize_directive, which is "" when
# the flag is off), so no env value can reach a lens-OFF prompt.
grep -q 'return operationalize_block() + trace_reask_block();' "$HUNTER" || ID_SRC_MISS="$ID_SRC_MISS [re-ask-block-inside-the-lens]"
if [ -z "$ID_SRC_MISS" ]; then
  ok "the five additive keys are conditional, the FAILED row is reserved for a cell that answered NONE of its checks, and the re-ask carries the open ids into a LENS-GATED prompt block"
else
  bad "the #2223 wiring regressed:$ID_SRC_MISS"
fi
# The partial shortfall must still be SURFACED — an `ok` cell that quietly drops checks is the failure mode
# this whole gate exists to refuse.
if grep -q 'sc_open_ids="$(_shortfall_id_list "$sc_log" "$REPO" "$EXTERNAL_CACHE")"' "$DISCOVERY" \
   && grep -q 'unanswered after the re-ask' "$DISCOVERY"; then
  ok "scrape_cell_log prints the open check ids of a PARTIAL shortfall (recorded \"ok\", never silently clean)"
else
  bad "a partial shortfall is no longer surfaced to the operator — an 'ok' cell could drop checks unseen"
fi
# No new status vocabulary, again: #2223 adds fields, never a cell status lib/zone-coverage.py does not know.
if grep -E '_accumulate_cell .*"\$sc_log" ' "$DISCOVERY" | grep -vqE ' (ok|failed) '; then
  bad "a cell status other than ok/failed was introduced — zone-coverage.py's hunted_degraded derivation knows only those two"
else
  ok "the cell status vocabulary is still exactly ok/failed (no new status for the dashboard/coverage derivation to learn)"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 8 — #2217 PR A: SECOND-TIER (tier-2) RECORDS (offline; runs in CI with no binaries).
# The carry this part gates: the #2223 per-check breakdown already records WHICH derived checks a cell left
# open, and those records die inside the cell object. A tier-2 record lifts one out — with a location derived
# from the check's OWN text — into a top-level `tier2[]` array, ranked and capped per zone. It costs ZERO
# extra LLM calls and changes no prompt: every input is already in the cell log, and the derivation is pure
# shell. As everywhere else here, the functions under test are SLICED OUT of run-discovery.sh by line range
# and sourced, so this measures the shipped code rather than a copy that can drift.
# A tier-2 record is NOT a candidate and carries NO severity. Nothing below may be read as a recall claim.
# ----------------------------------------------------------------------------------------------------------
note "35) the shipped tier-2 functions slice out of run-discovery.sh and load ..."
T2_FNS="$WORK/tier2-fns.sh"
{
  # _json_str is a ONE-LINE function, so it is matched by prefix rather than by the `^}$` range the others use.
  sed -n '/^_json_str() {/p' "$DISCOVERY"
  for _t2fn in _count_stdin _ids_of_lines _check_ids _distinct_trace_lines _uncited_dismissal_lines \
               _uncited_check_ids _unresolved_check_ids _tier2_flat _opcheck_text _trace_evidence \
               _unresolved_check_rows _uncited_check_rows _tier2_emit_loc _tier2_emit_bare_loc \
               _tier2_resolve_file \
               _tier2_location _tier2_rare _tier2_records _tier2_select _tier2_json_array \
               _tier2_top_json _tier2_totals_json; do
    sed -n "/^$_t2fn() {\$/,/^}\$/p" "$DISCOVERY"
  done
} > "$T2_FNS"
T2_LOADED=0
T2_FN_MISS=""
for _t2fn in _json_str _tier2_location _tier2_records _tier2_select _tier2_json_array _tier2_top_json _tier2_totals_json _unresolved_check_rows _uncited_check_rows; do
  grep -q "^$_t2fn() {" "$T2_FNS" || T2_FN_MISS="$T2_FN_MISS $_t2fn"
done
if [ -z "$T2_FN_MISS" ]; then
  # shellcheck disable=SC1090  # sliced out of run-discovery.sh at runtime, by design
  . "$T2_FNS"
  T2_LOADED=1
  ok "the shipped tier-2 functions (_tier2_location / _tier2_records / _tier2_select / _tier2_top_json / _tier2_totals_json / ...) extracted from run-discovery.sh and sourced"
else
  bad "could not extract the #2217 tier-2 functions from run-discovery.sh (renamed or reshaped?):$T2_FN_MISS"
fi

# A generic two-contract zone: one oracle-shaped contract whose function the check text can NAME, and a
# sibling whose function can only be found by grepping for its declaration. Protocol-agnostic on purpose —
# a fixture that named a real protocol would overfit the gate and, in a public repo, read as a target hint.
T2REPO="$WORK/tier2-repo"
mkdir -p "$T2REPO/src/oracles"
cat > "$T2REPO/src/oracles/YieldTokenOracle.sol" <<'T2SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract YieldTokenOracle {
    function _calculateBaseToQuote(uint256 amount) internal view returns (uint256) {
        return amount;
    }

    function latestAnswer() external view returns (uint256) {
        return 1e18;
    }
}
T2SOL
cat > "$T2REPO/src/oracles/RateAdapter.sol" <<'T2SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract RateAdapter {
    function convertRate(uint256 amount) public pure returns (uint256) {
        return amount;
    }
}
T2SOL
T2FILES="src/oracles/YieldTokenOracle.sol,src/oracles/RateAdapter.sol"

if [ "$T2_LOADED" -eq 1 ]; then
  note "36) an UNRESOLVED carry becomes ONE tier-2 record, located from the check's OWN text ..."
  # The r2 shape from the #2214 archive, genericised: the cell derived a decimals-scaling check that NAMES its
  # location as `Contract.function`, answered it UNRESOLVED, and answered everything else. The cell is `ok`,
  # the zone is not degraded, and before #2217 that carry died inside the cell object.
  T2_R2_LOG="$(_cell_log tier2-r2 \
    'OPERATIONALIZE|oracles|C23|on' \
    'OPCHECK|#1|YieldTokenOracle._calculateBaseToQuote scaling|the quote is scaled by the quote token decimals, not a hardcoded unit' \
    'OPCHECK|#2|the refresh order|the stored index is refreshed before it is read' \
    'TRACE|#1|UNRESOLVED|the decimals of the quote token are not visible in this payload' \
    'TRACE|#2|CLEAN|the setter runs before the reader in the same call' \
    'SAFE')"
  T2_R2_TSV="$WORK/tier2-r2.tsv"
  _tier2_records oracles C23 "$T2FILES" "$T2_R2_LOG" "$T2REPO" > "$T2_R2_TSV"
  T2_R2_N="$(grep -c . "$T2_R2_TSV" 2>/dev/null || true)"
  T2_R2_LOC="$(cut -f8 "$T2_R2_TSV" | head -1)"
  T2_R2_SRC="$(cut -f9 "$T2_R2_TSV" | head -1)"
  T2_R2_RULE="$(cut -f10 "$T2_R2_TSV" | head -1)"
  T2_R2_KIND="$(cut -f4 "$T2_R2_TSV" | head -1)"
  T2_R2_WHY="$(cut -f12 "$T2_R2_TSV" | head -1)"
  if [ "$T2_R2_N" = "1" ] && [ "$T2_R2_KIND" = "unresolved" ] \
     && [ "$T2_R2_LOC" = "src/oracles/YieldTokenOracle.sol:_calculateBaseToQuote" ] \
     && [ "$T2_R2_SRC" = "opcheck" ] && [ "$T2_R2_RULE" = "contract-fn" ]; then
    ok "the UNRESOLVED check becomes exactly ONE record at $T2_R2_LOC (loc_source=opcheck, loc_rule=contract-fn); the CLEAN sibling contributes none"
  else
    bad "the UNRESOLVED carry did not become one located record (n=$T2_R2_N kind=$T2_R2_KIND loc=$T2_R2_LOC src=$T2_R2_SRC rule=$T2_R2_RULE)"
  fi
  # The record must carry the cell's OWN reason, not a harness paraphrase: `why` is the TRACE evidence span.
  case "$T2_R2_WHY" in
    "the decimals of the quote token are not visible in this payload")
      ok "the record's \"why\" is the TRACE line's own evidence span (the cell's reason for not settling it)" ;;
    *) bad "the record's \"why\" is not the TRACE evidence span (got '$T2_R2_WHY')" ;;
  esac
  # The location must be parseable by score-match.py's lead_location() — bare path, ONE colon, a function half.
  if printf '%s\n' "$T2_R2_LOC" | grep -qE '^[A-Za-z0-9_./-]+\.sol:[A-Za-z_][A-Za-z0-9_]*$'; then
    ok "the derived location passes the pinned <path>.sol:<function> shape (score-match.py can pair-credit it)"
  else
    bad "the derived location is outside the pinned shape — no consumer could parse it into (file, function)"
  fi

  note "37) a check with NO derivable location falls back to the zone file list ..."
  T2_ZONE_LOG="$(_cell_log tier2-zone \
    'OPERATIONALIZE|oracles|C23|on' \
    'OPCHECK|#1|the wrapper rate source|the wrapper and the yield leg must read the SAME rate source' \
    'TRACE|#1|UNRESOLVED|both legs resolve their source through a registry this zone does not contain' \
    'SAFE')"
  T2_ZONE_TSV="$WORK/tier2-zone.tsv"
  _tier2_records oracles C23 "$T2FILES" "$T2_ZONE_LOG" "$T2REPO" > "$T2_ZONE_TSV"
  T2_Z_LOC="$(cut -f8 "$T2_ZONE_TSV" | head -1)"
  T2_Z_SRC="$(cut -f9 "$T2_ZONE_TSV" | head -1)"
  T2_Z_RULE="$(cut -f10 "$T2_ZONE_TSV" | head -1)"
  if [ "$T2_Z_LOC" = "src/oracles/YieldTokenOracle.sol" ] && [ "$T2_Z_SRC" = "zone" ] && [ "$T2_Z_RULE" = "file-only" ]; then
    ok "no Contract.function and no call-shaped mention: the record falls back to the cell's FIRST file with loc_source=zone (honest, and ranked last under the cap)"
  else
    bad "the zone fallback did not fire as specified (loc=$T2_Z_LOC src=$T2_Z_SRC rule=$T2_Z_RULE)"
  fi
  # The middle rule: a call-shaped mention whose DECLARATION is grepped out of this cell's files, in CSV order.
  T2_GREP_LOC="$(_tier2_location 'the convertRate( ) rounding|rounding favours the pool on both legs' "$T2FILES" "$T2REPO" | cut -f1)"
  T2_GREP_SRC="$(_tier2_location 'the convertRate( ) rounding|rounding favours the pool on both legs' "$T2FILES" "$T2REPO" | cut -f2,3 | tr '\t' '/')"
  if [ "$T2_GREP_LOC" = "src/oracles/RateAdapter.sol:convertRate" ] && [ "$T2_GREP_SRC" = "opcheck/fn-grep" ]; then
    ok "a call-shaped mention resolves through the fn-grep rule to the file that DECLARES it ($T2_GREP_LOC)"
  else
    bad "the fn-grep rule did not resolve the call-shaped mention (loc=$T2_GREP_LOC src/rule=$T2_GREP_SRC)"
  fi

  # #2217 M5 bug 2: a check text can name the contract it is about WITHOUT ever writing a `Contract.function`
  # pair. Before the contract-only rule such a text fell through to the zone fallback and was located at the
  # cell's FIRST file — a name no scoreboard can credit against the contract the check actually named. The
  # texts below are the M5 shape, genericised onto this fixture zone (a fixture that named a real protocol
  # would overfit the gate and, in a public repo, read as a target hint).
  note "37b) a BARE CONTRACT NAME resolves to that contract's file, ahead of the fn-grep and zone rules ..."
  T2_CO_TXT='YieldTokenOracle useAltRate immutable bool selecting rateA vs rateB, paired with the quote leg|the quote leg must price the SAME referent the selected rate is denominated in'
  T2_CO="$(_tier2_location "$T2_CO_TXT" "$T2FILES" "$T2REPO" | tr '\t' '/')"
  if [ "$T2_CO" = "src/oracles/YieldTokenOracle.sol/opcheck/contract-only" ]; then
    ok "a bare contract name with no Contract.function pair resolves to THAT contract's file (loc_source=opcheck, loc_rule=contract-only) instead of the zone's first file"
  else
    bad "the contract-only rule did not fire on a bare contract name (got '$T2_CO')"
  fi
  # ... and when the SAME text also mentions a call-shaped name the resolved file DECLARES, the function half
  # is appended — the pair-creditable shape, still under the contract-only rule.
  T2_COFN="$(_tier2_location "$T2_CO_TXT, and the latestAnswer( ) path must agree" "$T2FILES" "$T2REPO" | tr '\t' '/')"
  if [ "$T2_COFN" = "src/oracles/YieldTokenOracle.sol:latestAnswer/opcheck/contract-only" ]; then
    ok "the same text plus a call-shaped mention the resolved file declares gains the :function half (pair-creditable, still contract-only)"
  else
    bad "the contract-only rule did not append the function half (got '$T2_COFN')"
  fi
  # A call-shaped mention declared in some OTHER file must NOT be appended — that would contradict the
  # contract the rule just resolved — and must NOT let the fn-grep rule relocate the record to that file.
  T2_COX="$(_tier2_location "$T2_CO_TXT, and the convertRate( ) rounding" "$T2FILES" "$T2REPO" | tr '\t' '/')"
  if [ "$T2_COX" = "src/oracles/YieldTokenOracle.sol/opcheck/contract-only" ]; then
    ok "a call-shaped mention declared in a DIFFERENT file neither becomes the function half nor relocates the record (contract-only outranks fn-grep)"
  else
    bad "a foreign call-shaped mention moved the contract-only location (got '$T2_COX')"
  fi
  # A capitalised word that names no file of this zone is not a contract: the resolve IS the gate, so the
  # record still falls through to the zone fallback exactly as before.
  T2_CON="$(_tier2_location 'SettlementQueue entries drift after a partial redemption|the drift must stay bounded' "$T2FILES" "$T2REPO" | tr '\t' '/')"
  if [ "$T2_CON" = "src/oracles/YieldTokenOracle.sol/zone/file-only" ]; then
    ok "a capitalised word matching NO zone file falls through to the zone fallback as before (the resolve is the gate, not the capitalisation)"
  else
    bad "a bare name matching no zone file did not fall through to file-only (got '$T2_CON')"
  fi

  note "38) SANITISATION: decoration and slice suffixes can never produce a location outside the pinned shape ..."
  T2_SAN_BAD=""
  for _t2case in \
    'the `YieldTokenOracle._calculateBaseToQuote` scaling (see the header)' \
    'YieldTokenOracle.sol:_calculateBaseToQuote@_calculateBaseToQuote must scale' \
    'src/oracles/YieldTokenOracle.sol:_calculateBaseToQuote:132 is the site' \
    '"YieldTokenOracle._calculateBaseToQuote" ~(test/Oracle.t.sol) must scale'
  do
    _t2loc="$(_tier2_location "$_t2case" "$T2FILES" "$T2REPO" | cut -f1)"
    case "$_t2loc" in
      src/oracles/YieldTokenOracle.sol|src/oracles/YieldTokenOracle.sol:_calculateBaseToQuote) ;;
      *) T2_SAN_BAD="$T2_SAN_BAD [$_t2case -> $_t2loc]" ;;
    esac
  done
  if [ -z "$T2_SAN_BAD" ]; then
    ok "backticks, quotes, parentheses, an @fn slice suffix, a ~(...) tail and an extra ':' all degrade to a well-shaped location or the zone fallback — never to a string no consumer can parse"
  else
    bad "sanitisation let a malformed location through:$T2_SAN_BAD"
  fi

  note "39) the per-zone CAP keeps the 3 highest-ranked records and COUNTS what it dropped ..."
  # Five candidates across two cells of one zone: a rare-class (C23) cell and a non-rare (C1) one. The rank is
  # rare class first, then unresolved before uncited, then the location rule, then cell order / check id.
  T2_CAP_A="$(_cell_log tier2-cap-a \
    'OPERATIONALIZE|oracles|C23|on' \
    'OPCHECK|#1|YieldTokenOracle._calculateBaseToQuote scaling|the quote is scaled by the quote token decimals' \
    'OPCHECK|#2|the wrapper rate source|both legs must read the SAME rate source' \
    'OPCHECK|#3|the convertRate( ) rounding|rounding favours the pool on both legs' \
    'TRACE|#1|UNRESOLVED|the decimals of the quote token are not visible in this payload' \
    'TRACE|#2|UNRESOLVED|the registry that resolves the source is outside this zone' \
    'TRACE|#3|CLEAN|by construction the external venue always returns a normalised unit ratio' \
    'SAFE')"
  T2_CAP_B="$(_cell_log tier2-cap-b \
    'OPERATIONALIZE|oracles|C1|on' \
    'OPCHECK|#1|YieldTokenOracle.latestAnswer staleness|the answer is rejected when it is older than the heartbeat' \
    'OPCHECK|#2|the queue order|entries are drained in insertion order' \
    'TRACE|#1|UNRESOLVED|the heartbeat is a deployment parameter this payload does not carry' \
    'TRACE|#2|UNRESOLVED|the queue implementation lives outside this zone' \
    'SAFE')"
  T2_CAP_TSV="$WORK/tier2-cap.tsv"
  : > "$T2_CAP_TSV"
  _tier2_records oracles C23 "$T2FILES" "$T2_CAP_A" "$T2REPO" >> "$T2_CAP_TSV"
  _tier2_records oracles C1  "$T2FILES" "$T2_CAP_B" "$T2REPO" >> "$T2_CAP_TSV"
  T2_CAP_ALL="$(grep -c . "$T2_CAP_TSV" 2>/dev/null || true)"
  T2_CAP_KEPT="$(_tier2_select "$T2_CAP_TSV" 3 | cut -f5,4,7 | tr '\t' '/' | tr '\n' ' ' | sed 's/ $//')"
  if [ "$T2_CAP_ALL" = "5" ] && [ "$T2_CAP_KEPT" = "unresolved/C23/1 unresolved/C23/2 uncited/C23/3" ]; then
    ok "5 candidates, cap 3: the kept set is the rare class first, unresolved before uncited, contract-fn before the zone fallback ($T2_CAP_KEPT)"
  else
    bad "the cap did not select the specified 3 (all=$T2_CAP_ALL kept='$T2_CAP_KEPT')"
  fi
  T2_CAP_TOTALS="$(_tier2_totals_json "$T2_CAP_TSV" 1 3)"
  if [ "$T2_CAP_TOTALS" = ',"tier2":3,"tier2_dropped":2' ]; then
    ok "the totals record BOTH halves: 3 kept and 2 dropped by the cap (an over-supply is never silently truncated)"
  else
    bad "totals.tier2/tier2_dropped are wrong (got '$T2_CAP_TOTALS', want ',\"tier2\":3,\"tier2_dropped\":2')"
  fi
  # The cap is applied over the WHOLE zone after every cell is accumulated, so it must be independent of the
  # order the accumulator happened to append in. Re-run with the two cells swapped: same three records.
  T2_CAP_TSV2="$WORK/tier2-cap-swapped.tsv"
  : > "$T2_CAP_TSV2"
  _tier2_records oracles C1  "$T2FILES" "$T2_CAP_B" "$T2REPO" >> "$T2_CAP_TSV2"
  _tier2_records oracles C23 "$T2FILES" "$T2_CAP_A" "$T2REPO" >> "$T2_CAP_TSV2"
  if [ "$(_tier2_select "$T2_CAP_TSV2" 3 | cut -f5,4,7 | tr '\t' '/' | tr '\n' ' ' | sed 's/ $//')" = "$T2_CAP_KEPT" ]; then
    ok "the selection is unchanged when the cells are accumulated in the opposite order (the rank decides, not the arrival order)"
  else
    bad "the selection depends on cell arrival order — it would differ between --jobs 1 and --jobs N"
  fi
  # The rare-class list is a PRIORITY LIST and nothing else, and it is one env-overridable comma list.
  if [ "$(_tier2_rare C23)" = "0" ] && [ "$(_tier2_rare C1)" = "1" ] \
     && [ "$(DF_TIER2_RARE_CLASSES=C1 _tier2_rare C1)" = "0" ] \
     && [ "$(DF_TIER2_RARE_CLASSES=C1 _tier2_rare C23)" = "1" ]; then
    ok "DF_TIER2_RARE_CLASSES is the single, env-overridable priority list (default C19-C24; overriding it moves the priority, nothing else)"
  else
    bad "the rare-class priority list is not env-overridable as one list"
  fi

  note "40) OFF is EXACTLY 0 bytes, on the SAME non-empty supply ..."
  # This is the byte-identity contract, proven on a TSV that really carries records: with the feature off both
  # fragments are empty strings, and concatenating an empty string into the assembly printf is a no-op. So a
  # feature-OFF run cannot differ from a pre-#2217 run by construction, not by inspection.
  T2_OFF_TOP="$(_tier2_top_json "$T2_CAP_TSV" 0 3)"
  T2_OFF_TOT="$(_tier2_totals_json "$T2_CAP_TSV" 0 3)"
  T2_CAP0_TOP="$(_tier2_top_json "$T2_CAP_TSV" 1 0)"
  if [ -z "$T2_OFF_TOP" ] && [ -z "$T2_OFF_TOT" ] && [ -z "$T2_CAP0_TOP" ]; then
    ok "feature OFF (and cap 0) emit 0 bytes for BOTH the tier2[] array and the totals — no key, not an empty array"
  else
    bad "the OFF path emits bytes (top='$T2_OFF_TOP' totals='$T2_OFF_TOT' cap0='$T2_CAP0_TOP') — a default run's JSON would change shape"
  fi
  # ON, the fragment must be well-formed JSON carrying the documented schema keys and an EMPTY severity.
  T2_ON_TOP="$(_tier2_top_json "$T2_CAP_TSV" 1 3)"
  if printf '{"totals":{}%s}\n' "$T2_ON_TOP" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["tier2"][0]; assert len(d["tier2"])==3; assert sorted(r)==["check","class","id","kind","loc_rule","loc_source","location","severity","subsystem","why"], sorted(r); assert r["severity"]=="", r; assert isinstance(r["id"], int)' 2>/dev/null; then
    ok "the emitted fragment parses as JSON, carries exactly the documented schema keys, an integer id and an EMPTY severity (a tier-2 record assesses none)"
  else
    bad "the tier2[] fragment is not well-formed JSON with the documented schema (severity must ship empty)"
  fi

  note "41) the UNRESOLVED row source cannot drift from the shipped #2223 carry ..."
  # _unresolved_check_rows REUSES _unresolved_check_ids for its first two columns rather than re-implementing
  # the parse, so the tier-2 source set and the shipped `unresolved_ids` JSON can never disagree about WHICH
  # checks were carried. Pin it on a log that carries two.
  if [ "$(_unresolved_check_rows "$T2_CAP_A" | cut -f1 | tr '\n' ' ')" = "$(_unresolved_check_ids "$T2_CAP_A" | cut -f1 | tr '\n' ' ')" ]; then
    ok "_unresolved_check_rows carries exactly the ids _unresolved_check_ids reports (one parse, two projections)"
  else
    bad "the tier-2 rows and the #2223 unresolved_ids carry DIFFERENT check ids — one of them re-implemented the parse"
  fi
  # The uncited source set is likewise the set the #2225/#2227 detectors flag, never a second opinion.
  if [ "$(_uncited_check_rows "$T2_CAP_A" | cut -f1 | tr '\n' ' ')" = "$(_uncited_check_ids "$T2_CAP_A" | cut -f1 | tr '\n' ' ')" ]; then
    ok "_uncited_check_rows carries exactly the ids _uncited_check_ids flags (the tier-2 source set is the STOP-1 set: unresolved + uncited, nothing else)"
  else
    bad "the tier-2 uncited rows disagree with _uncited_check_ids — the source set grew a second opinion"
  fi
fi

note "42) the #2217 wiring in run-discovery.sh and run-zone-hunt.sh ..."
T2_SRC_MISS=""
# Default OFF, on BOTH switches, and the cap forces the whole feature off at 0.
grep -q '^TIER2=0$' "$DISCOVERY" || T2_SRC_MISS="$T2_SRC_MISS [TIER2-defaults-to-0]"
grep -q -- '--tier2) TIER2=1; shift ;;' "$DISCOVERY" || T2_SRC_MISS="$T2_SRC_MISS [--tier2-flag]"
grep -q 'if \[ "${DF_TIER2:-}" = "1" \]; then TIER2=1; fi' "$DISCOVERY" || T2_SRC_MISS="$T2_SRC_MISS [DF_TIER2-env-switch]"
grep -q 'DF_TIER2_MAX_PER_ZONE="${DF_TIER2_MAX_PER_ZONE:-3}"' "$DISCOVERY" || T2_SRC_MISS="$T2_SRC_MISS [cap-default-3]"
grep -q '\[ "$DF_TIER2_MAX_PER_ZONE" -gt 0 \] || TIER2=0' "$DISCOVERY" || T2_SRC_MISS="$T2_SRC_MISS [cap-0-forces-OFF]"
# The records go to a RUN-scoped TSV, never into the cell object — that is what keeps every per-cell key set
# (and _plan_depth_cells's forward key scan) byte-identical.
grep -q '_tier2_records "$ac_subsys" "$ac_cls" "$ac_files" "$ac_log" "$REPO" "$EXTERNAL_CACHE" >> "$TIER2_TSV"' "$DISCOVERY" \
  || T2_SRC_MISS="$T2_SRC_MISS [records-to-run-scoped-tsv]"
grep -q 'if \[ "$TIER2" -eq 1 \]; then : > "$TIER2_TSV"; fi' "$DISCOVERY" || T2_SRC_MISS="$T2_SRC_MISS [tsv-created-only-when-ON]"
# The two new %s slots of the assembly printf are fed by variables initialised EMPTY and assigned only under
# the flag — the OFF path cannot reach the emitters at all.
grep -q '^TIER2_JSON=""$' "$DISCOVERY" || T2_SRC_MISS="$T2_SRC_MISS [TIER2_JSON-initialised-empty]"
grep -q '^TIER2_TOTALS_JSON=""$' "$DISCOVERY" || T2_SRC_MISS="$T2_SRC_MISS [TIER2_TOTALS_JSON-initialised-empty]"
# #2256 interleaves its own two ""-when-off fragments (totals.coverage_cells, top-level function_coverage[]) — they
# are pinned 0 bytes with the knob off by demo-function-coverage.sh; the tier-2 pair is still consumed in order.
# #2264 adds a third pair the same way (totals.promise_extractions, top-level breadth_promises[]), pinned 0 bytes with
# the knob off by demo-breadth-promises.sh.
grep -q '"$DEPTH_TOTAL_JSON" "$TIER2_TOTALS_JSON" "$FCOV_TOTALS_JSON" "$BP_TOTALS_JSON" "$TIER2_JSON" "$FCOV_JSON" "$BP_JSON" > "$RESULTS_JSON"' "$DISCOVERY" \
  || T2_SRC_MISS="$T2_SRC_MISS [assembly-consumes-both-fragments]"
# The schema is DOCUMENTED in the script header, not left to be reverse-engineered from the printf.
grep -q 'SCHEMA — top-level `tier2\[\]` of discovery-results.json' "$DISCOVERY" || T2_SRC_MISS="$T2_SRC_MISS [schema-in-header]"
grep -q 'loc_source  "opcheck" = derived from the CHECK TEXT' "$DISCOVERY" || T2_SRC_MISS="$T2_SRC_MISS [loc_source-documented]"
# The merge unions tier-2 records across zones and attempts, dedupes on the WHOLE record, and adds no key when
# there is nothing to carry.
grep -q 'tier2, tier2_seen = \[\], set()' "$ZONEHUNT" || T2_SRC_MISS="$T2_SRC_MISS [merge-collects-tier2]"
grep -q 'rk = json.dumps(r, sort_keys=True)' "$ZONEHUNT" || T2_SRC_MISS="$T2_SRC_MISS [merge-dedupes-whole-record]"
grep -q 'out\["totals"\]\["tier2"\] = len(tier2)' "$ZONEHUNT" || T2_SRC_MISS="$T2_SRC_MISS [merge-totals-tier2]"
if [ -z "$T2_SRC_MISS" ]; then
  ok "the second tier is default-OFF on both switches, cap-0-inert, written to a RUN-scoped TSV (never into a cell object), assembled through two fragments that are empty unless it is ON, documented in the header, and unioned by the merge"
else
  bad "the #2217 wiring regressed:$T2_SRC_MISS"
fi
# A tier-2 record must never be countable as a candidate: the emitters carry no CANDIDATE| substring (the
# reply-shape validator greps for exactly that) and never touch the candidate accumulator.
if sed -n '/^# --- #2217 PR A: SECOND-TIER/,/^# _opcheck_trace_gap /p' "$DISCOVERY" | grep -q 'CANDIDATE|'; then
  bad "the #2217 block mentions a 'CANDIDATE|' token — a tier-2 record could be mistaken for a lead"
else
  ok "the #2217 block emits no 'CANDIDATE|' substring and touches no candidate accumulator (a tier-2 record is an UNSETTLED CHECK, not a lead)"
fi

note "43) live-under-mock: --tier2 changes NOTHING on a run that carried no unsettled check ..."
if ! command -v agentis >/dev/null 2>&1; then
  skip "no agentis binary on PATH — the end-to-end --tier2 byte-identity run cannot run"
else
  T2SCOPE="$WORK/tier2-scope.tsv"
  T2BRIEF="$WORK/tier2-brief.md"
  printf 'vault | C23 | contracts/PairedPoolVault.sol\n' > "$T2SCOPE"
  printf '# brief\nInvariants to break: the two legs of a round trip agree.\nKnown issues to exclude: none.\n' > "$T2BRIEF"
  T2E2E_REPO="$WORK/tier2-e2e-repo"; mkdir -p "$T2E2E_REPO/contracts"
  cp "$PAIRED" "$T2E2E_REPO/contracts/PairedPoolVault.sol"
  OPERATIONALIZE_LENS=1 "$DISCOVERY" --repo "$T2E2E_REPO" --scope "$T2SCOPE" --brief "$T2BRIEF" \
    --only vault --classes C23 --backend mock --agentis agentis --out "$WORK/t2-on" --tier2 \
    > "$WORK/t2-on.out" 2>&1 || true
  OPERATIONALIZE_LENS=1 "$DISCOVERY" --repo "$T2E2E_REPO" --scope "$T2SCOPE" --brief "$T2BRIEF" \
    --only vault --classes C23 --backend mock --agentis agentis --out "$WORK/t2-off" \
    > "$WORK/t2-off.out" 2>&1 || true
  if [ ! -f "$WORK/t2-on/discovery-results.json" ] || [ ! -f "$WORK/t2-off/discovery-results.json" ]; then
    bad "the mock --tier2 arms produced no discovery-results.json (run-discovery.sh did not complete)"
    tail -5 "$WORK/t2-on.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    if grep -q '"tier2"' "$WORK/t2-off/discovery-results.json"; then
      bad "a run WITHOUT --tier2 emitted a tier2 key — the feature is not default-OFF end to end"
    elif cmp -s "$WORK/t2-on/discovery-results.json" "$WORK/t2-off/discovery-results.json"; then
      ok "--tier2 on a run whose cells settled (or derived) nothing is BYTE-IDENTICAL to the default run — the flag parses, and an empty supply adds no key"
    else
      bad "--tier2 changed the emitted JSON on a run with no unsettled check"
      diff "$WORK/t2-off/discovery-results.json" "$WORK/t2-on/discovery-results.json" | head -5 | sed 's/^/      /' >&2
    fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #2211 operationalize directive (pure-meta text, default-OFF flag, OPERATIONALIZE| sentinel, OPCHECK| contract), the #2214 OPCHECK->TRACE follow-through gate, the #2214 PR C dismissal-citation discipline, the #2223 per-check pairing by id (with per-CHECK degradation) and the #2217 PR A second-tier carry (derivation, location, ranking, cap, default-OFF byte-identity) hold"
  note "NOTE: this gate proves WIRING and model COMPLIANCE only. Rare-tier recall is UNMEASURED until the #2211 M2 corpus A/B runs."
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
