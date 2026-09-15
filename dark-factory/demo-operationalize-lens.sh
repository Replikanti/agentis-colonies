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
# Four parts:
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
#
# Usage:  dark-factory/demo-operationalize-lens.sh
# Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HUNTER="$HERE/auditor/agents/hunter.ag"
TAXONOMY="$HERE/auditor/bug-taxonomy.md"
DISCOVERY="$HERE/run-discovery.sh"
FIXDIR="$HERE/fixtures/operationalize/contracts"
PAIRED="$FIXDIR/PairedPoolVault.sol"
PLAIN="$FIXDIR/PlainCounter.sol"

FAILS=0
note() { echo "demo-operationalize-lens.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$HUNTER" "$TAXONOMY" "$DISCOVERY" "$PAIRED" "$PLAIN"; do
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
OPZ_FNS="operationalize_marker operationalize_block operationalize_enabled operationalize_directive"
MISSING_FN=""
for fn in $OPZ_FNS; do
  grep -q "^fn $fn(" "$HUNTER" || MISSING_FN="$MISSING_FN $fn"
done
if [ -z "$MISSING_FN" ]; then
  ok "all 4 marker/block/toggle/directive helpers are declared in hunter.ag"
else
  bad "hunter.ag is missing #2211 helper(s):$MISSING_FN"
fi

# NO detector, deliberately: a coarse net over "does this zone touch anything external" would gate nothing
# (the method applies everywhere) while adding a SECOND variable to the M2 A/B. If a detector is ever added,
# this assertion is the place to argue about it — silently growing one would invalidate the experiment.
if grep -A3 '^fn operationalize_directive(' "$HUNTER" | grep -qi 'code\|detector\|has_'; then
  bad "operationalize_directive() grew a payload/detector argument — the flag must stay the ONLY gate (M2 single-variable)"
else
  ok "operationalize_directive() takes no payload and consults no detector (the flag is the only gate)"
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
if grep -q 'OPERATIONALIZE|<subsystem>|<cls>|on' "$HUNTER" && grep -q 'OPCHECK|<construct>|<invariant>' "$HUNTER"; then
  ok "hunter.ag's header Stdout contract documents both the OPERATIONALIZE| sentinel and the model-emitted OPCHECK| lines"
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
  "Emit each derived check, BEFORE you begin tracing and before any CANDIDATE line, on its own line:" \
  "OPCHECK|<the specific construct in this zone's code>|<the exact invariant it must satisfy>" \
  "never invent a construct that is not in the code" \
  "FOLLOW THROUGH — a check you write and abandon is worse than one you never derived." \
  "TRACE|<the same check, restated>|<CLEAN or BUG or UNRESOLVED>|<the function or line in THIS zone that settles it>" \
  "SAFE is a valid answer ONLY when every OPCHECK line you wrote has a matching TRACE line."
do
  case "$HUNTER_FLAT" in *"$s"*) ;; *) DIRECTIVE_MISS="$DIRECTIVE_MISS [$s]" ;; esac
done
if [ -z "$DIRECTIVE_MISS" ]; then
  ok "the directive keeps its header, the derive-write-then-trace method, the paired-operation clause, the OPCHECK| emission contract, the #2214 TRACE| follow-through contract and the anti-fabrication guard"
else
  bad "the directive lost load-bearing text:$DIRECTIVE_MISS"
fi

# #2214: the TRACE verdict vocabulary must not contain a `CANDIDATE|` substring — lib/run-agent-validated.sh
# validates a hunter reply by grepping for exactly that, so a verdict word carrying it would let a reply that
# never reached a verdict pass validation.
case "$HUNTER_FLAT" in
  *"TRACE|<the same check, restated>|<CLEAN or BUG or UNRESOLVED>"*)
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
if grep -q '"\$ac_opchecks_json" "\$ac_traces_json" "\$ac_untraced_json" >> "\$CELLS_JSONL"' "$DISCOVERY"; then
  ok "both counters are appended LAST, after opchecks (the _plan_depth_cells forward key scan is untouched)"
else
  bad "the #2214 counters are no longer the LAST fields of the cell object — the forward key scan could break"
fi

note "12) DECISION: no new taxonomy class — this is a cross-class METHOD directive ..."
if grep -q '^## C24 ' "$TAXONOMY"; then
  bad "bug-taxonomy.md gained a '## C24 ' class — #2211 is explicitly a method directive, NOT a new class"
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
  for fn in $OPZ_FNS; do
    awk -v want="^fn $fn\\\\(" '$0 ~ want {f=1} f{print} f&&/^}$/{exit}' "$HUNTER" >> "$FRAG"
    printf '\n' >> "$FRAG"
    grep -q "^fn $fn(" "$FRAG" || FRAG_MISS="$FRAG_MISS $fn"
  done
  if [ -n "$FRAG_MISS" ]; then
    bad "could not extract #2211 helpers from hunter.ag by line range (renamed?):$FRAG_MISS"
  else
    SB="$WORK/probe"; mkdir -p "$SB"
    ( cd "$SB" && agentis init >/dev/null 2>&1 ) || true
    printf 'exec.env_passthrough = OPERATIONALIZE_LENS\n' > "$SB/.agentis/config"
    {
      printf 'cb 300000;\n\n'
      cat "$FRAG"
      printf 'print("BLOCKLEN=" + to_string(len(operationalize_block())));\n'
      printf 'print("DIRLEN=" + to_string(len(operationalize_directive())));\n'
    } > "$SB/probe.ag"
    # _dirlen <flag-value|"">: the toggle-gated directive length. An empty argument runs with the env UNSET.
    _dirlen() {
      if [ -n "$1" ]; then
        _dl="$( cd "$SB" && OPERATIONALIZE_LENS="$1" agentis go probe.ag 2>&1 | grep '^DIRLEN=' | tail -1 )"  # no-pii: the probe never calls prompt() — it prints two string lengths
      else
        _dl="$( cd "$SB" && agentis go probe.ag 2>&1 | grep '^DIRLEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
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
    if [ "$DIR_ZERO" = "0" ] && [ "$DIR_TRUE" = "0" ]; then
      ok "OPERATIONALIZE_LENS=0 and =true are both OFF (only the literal \"1\" opts in — no accidental default-ON)"
    else
      bad "a value other than \"1\" turned the directive ON (=0 gave '$DIR_ZERO', =true gave '$DIR_TRUE')"
    fi
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
  sed -n '/^_opcheck_trace_gap() {$/,/^}$/p' "$DISCOVERY"
  sed -n '/^_untraced_safe() {$/,/^}$/p' "$DISCOVERY"
} > "$GATE_FNS"
GATE_LOADED=0
if grep -q '^_opcheck_trace_gap() {$' "$GATE_FNS" && grep -q '^_untraced_safe() {$' "$GATE_FNS"; then
  # shellcheck disable=SC1090  # sliced out of run-discovery.sh at runtime, by design
  . "$GATE_FNS"
  GATE_LOADED=1
  ok "_distinct_sentinel_count / _opcheck_trace_gap / _untraced_safe extracted from run-discovery.sh and sourced"
else
  bad "could not extract the #2214 gate functions from run-discovery.sh (renamed or reshaped?)"
fi

# _cell_log <name> <line...> — write a synthetic cell log and print its path.
_cell_log() {
  _cl_name="$1"; shift
  _cl_path="$WORK/$_cl_name.log"
  : > "$_cl_path"
  for _cl_line in "$@"; do printf '%s\n' "$_cl_line" >> "$_cl_path"; done
  printf '%s\n' "$_cl_path"
}
# _assert_gap <label> <log> <expected-gap> <expected-trip: yes|no>
_assert_gap() {
  _ag_label="$1"; _ag_log="$2"; _ag_gap="$3"; _ag_trip="$4"
  _ag_got="$(_opcheck_trace_gap "$_ag_log")"
  if _untraced_safe "$_ag_log"; then _ag_fired=yes; else _ag_fired=no; fi
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

  note "20) TRACE grammar: a trace is matched to its OPCHECK by DISTINCT-LINE COUNT, not by text pairing ..."
  # Verbatim repetition cannot inflate the requirement (5 OPCHECK lines, 3 distinct) and cannot discharge it
  # either (a pasted TRACE line counts once). This is the whole matching rule, pinned.
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
grep -q 'while \[ "$rc_reask" -le "$DF_TRACE_MAX_REASKS" \] && _untraced_safe "$rc_log"; do' "$DISCOVERY" \
  || GATE_SRC_MISS="$GATE_SRC_MISS [bounded-re-ask-loop]"
# The superseded attempt is preserved, under a suffix that is NOT a `.log` (readouts and the hunt dashboard
# enumerate `hunt_*.log` and must keep seeing exactly one log per cell).
grep -q 'mv -f "$rc_log" "$rc_log.untraced-attempt-$rc_reask"' "$DISCOVERY" \
  || GATE_SRC_MISS="$GATE_SRC_MISS [attempt-preserved-under-non-.log-suffix]"
grep -q '_opcheck_trace_gap "$rc_log" > "$rc_log.untraced"' "$DISCOVERY" || GATE_SRC_MISS="$GATE_SRC_MISS [untraced-marker]"
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
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #2211 operationalize directive (pure-meta text, default-OFF flag, OPERATIONALIZE| sentinel, OPCHECK| contract) and the #2214 OPCHECK->TRACE follow-through gate hold"
  note "NOTE: this gate proves WIRING and model COMPLIANCE only. Rare-tier recall is UNMEASURED until the #2211 M2 corpus A/B runs."
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
