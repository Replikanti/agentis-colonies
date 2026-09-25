#!/usr/bin/env bash
# demo-severity-rubric.sh — the gate for the #2245 iteration-2 CONTEST-SEVERITY DISMISSAL RUBRIC.
#
# What the change is. Iteration 1 measured the binding constraint precisely: on the held-out shape 3 of 3 runs
# REACHED the ground-truth mechanism and 0 of 3 KEPT it, and all three losses applied ONE criterion — "no
# unprivileged attacker gain and no funds locked => not a bug" — at two different decision points, the hunter's
# SAFE and the refute gate's REFUTED. So iteration 2 changes neither routing nor generation. It installs the
# contest SEVERITY rubric at BOTH decision points, with:
#   * ONE shared rubric + CLOSED ground list, byte-identical in hunter.ag and refuter.ag (part 3 diffs them);
#   * a structured output line per side — `DISMISS|<file:function[:line]>|<ground-id>|<evidence>` on the hunt
#     side, `REFUTE-GROUND|<ground-id>|<evidence>` on the gate side;
#   * a bounded, NAMED re-ask in each driver when the ground is insufficient;
#   * on the hunt side only, PROMOTION of the surviving location to a tier-1 `Medium` candidate;
#   * on the gate side, NO verdict flip: after a failed re-ask the verdict STAYS `REFUTED`, the reason is
#     prefixed `rubric-insufficient: ` and one row lands in `<out>/rubric-dismissals.tsv`.
# `SEVERITY_RUBRIC=1` opts in; unset (the DEFAULT) leaves both agents' prompts and both drivers' behaviour
# byte-identical to today. The knob is INDEPENDENT of OPERATIONALIZE_LENS (issue #2245 STOP-1 decision 3).
#
# ITERATION 3 — the per-ground EVIDENCE contract, behind its OWN knob `GROUND_EVIDENCE=1`. Iteration 2 measured
# the next constraint exactly: the rubric works where it is applied honestly (the held-out row went 0/2 -> 2/2 on
# the hunt side, 0/1 -> 1/2 on the gate side) and all three remaining losses have ONE shape — a SUFFICIENT
# ground id attached to evidence that does not establish that ground's definition. The shipped gate checks the
# ground ID; nothing checked the evidence. So iteration 3 adds a DETECTOR, not a second mechanism:
#   * ONE shared per-ground contract string, byte-identical in both agents (part 3 diffs it), appended INSIDE
#     the rubric directive — so it can only ever reach a rubric-ON cell, and `SEVERITY_RUBRIC=1` alone still
#     renders exactly the iteration-2 prompt;
#   * ONE shared decider, `_dismiss_evidence_ok`, byte-identical in both drivers (part 3 diffs it too): citation
#     existence + a validating-line shape for `guard`/`unreachable`/`known-issue`, the literal `delta=0:` token
#     for `no-loss`, a number plus a bound for `immaterial-quantified`, and the admitted-vs-deployed veto on all
#     of them (mechanical checks only — issue #2245 iteration-3 STOP-1 decision 3);
#   * a contract failure folds into the EXISTING insufficient path: same one bounded re-ask (now naming what is
#     missing), same hunt-side promotion, same gate-side `REFUTED` + `rubric-insufficient: ` + sidecar row;
#   * the TAINT rule (decision 2): a contract-FAILING sufficient line keeps its location open even when a
#     sibling line passes. `severity_rubric_block()` stays FROZEN so the two arms stay comparable.
# `GROUND_EVIDENCE` unset (the DEFAULT) leaves every prompt and both drivers byte-identical to iteration 2.
#
# The default is OFF on purpose and is NOT a defect this gate should "fix": #2191 shipped a mechanically perfect
# lens that scored rare-recall delta=+0, and #2213 measured delta=+0 for an ungated prompt directive. Nothing
# asserted here is a recall claim — recall is the operator's pre-registered measurement, not this file's job.
#
# Ten parts. Parts 1-9 are the CI floor: pure grep/awk plus the SHIPPED shell functions sliced out of the two
# drivers and two offline `--agentis` stubs, so they need no agentis, no forge, no network and no LLM.
#   1) hunter.ag SOURCE-GUARD — the six helpers, the marker/sentinel coupling, the `== "1"` default-OFF
#      polarity, the ""-when-disabled gate, the splice position (after config_realizability_rule(), before the
#      resolver verb), the absence of a detector, and the DISMISS| emission contract.
#   2) refuter.ag SOURCE-GUARD — the five helpers, the splice position INSIDE judge_body in BOTH modes and
#      BEFORE the tie-break (which the change deliberately leaves alone), the sentinel's honesty gate, and the
#      load-bearing output ORDER (REFUTE-GROUND| -> CONSTRAINT| -> VERDICT|).
#   3) ANTI-DRIFT — severity_rubric_marker() and severity_rubric_block() are BYTE-IDENTICAL between the two
#      agents; _rubric_sufficient_grounds() is byte-identical between the two drivers; and every ground id the
#      shells decide on appears in the prompt text the models are shown (a shell list that has drifted from the
#      rubric would silently re-ask on a ground the model was never offered). Iteration 3 adds the same discipline
#      to its five agent helpers, to _dismiss_evidence_ok/_contract_requirement across the two drivers, to the
#      FROZEN iteration-2 rubric string, and to the two literal contract tokens in BOTH directions.
#   4) WIRING — both `exec.env_passthrough` registrations (the #1426 trap: getenv() reads the SANITISED env, so
#      an unregistered knob is silently inert), the two new record boundaries in _join_wrapped_candidates, the
#      new boundary in all three refute scrapers, and the token invariants (`DISMISS|`, `SEVERITY-RUBRIC|`,
#      `RUBRIC-PROMOTED|`, `REFUTE-GROUND|` carry neither `CANDIDATE|` nor `VERDICT|`).
#   5) OVERFITTING DENYLIST + SUBSTRATE PURITY — the prompt text names no protocol, product, contract,
#      function, token, unit or corpus target, carries no ground-truth finding id, and the new `.ag` code is
#      builtins-only (no `exec sh`, no embedded interpreter, no regex/reduce, no per-element cost).
#   6) THE DETERMINISTIC GATE, FIXTURE-DRIVEN — the shipped functions sliced out of run-discovery.sh over
#      synthetic cell logs: one log per insufficient ground, one per sufficient ground (must NOT fire), one
#      STACKING three insufficient grounds on one location (must fire — the union rule), one with an unknown /
#      malformed ground (must fire), one whose location does not resolve (promotion dropped, gap still
#      recorded), the promoted line's SHAPE and severity floor, and the inertness of all of it without the
#      sentinel.
#   7) THE HUNT GATE END-TO-END — real run-discovery.sh runs through an offline `--agentis` stub: re-ask +
#      promotion, re-ask + recovery on a sufficient ground, no re-ask when the first ground is sufficient, the
#      superseded attempt's non-`.log` suffix, the additive JSON keys, and the knob-OFF inertness.
#   8) THE REFUTE GATE END-TO-END — real run-refute.sh runs through an offline `--agentis` stub: a sufficient
#      ground is not re-asked, an insufficient one is re-asked once and can recover to REAL (contributing NO
#      constraint), a held insufficient ground keeps the verdict `REFUTED` with the `rubric-insufficient: `
#      prefix and one sidecar row, a missing ground counts as insufficient, a PTY-wrapped ground line is never
#      glued into the verdict reason or the constraint sentence, and with the knob off the report is
#      BYTE-IDENTICAL and no sidecar is created at all.
#   9) verify-findings.sh IS UNTOUCHED — its verdict vocabulary is still exactly `REAL|REFUTED|ERROR`, nothing
#      in the new code path writes a fifth token, and the tier-2 contract is unchanged.
#  10) LIVE UNDER MOCK ([SKIP] without an `agentis` binary) — the only part that exercises the AGENT half
#      (passthrough -> getenv -> honesty-gated sentinel) rather than the driver half: a real mock hunt cell must
#      print the sentinel with SEVERITY_RUBRIC=1 and must NOT print it by default, plus a byte-identity probe
#      running the helpers EXTRACTED from the agents by line range (0 bytes when the knob is unset).
# Every detector has a NEGATIVE CONTROL: a guard that never fires is indistinguishable from a guard that
# cannot fire.
#
# Usage:  dark-factory/demo-severity-rubric.sh
# Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HUNTER="$HERE/auditor/agents/hunter.ag"
REFUTER="$HERE/auditor/agents/refuter.ag"
DISCOVERY="$HERE/run-discovery.sh"
REFUTE="$HERE/run-refute.sh"
VERIFY="$HERE/verify-findings.sh"
FIXSOL="$HERE/fixtures/operationalize/contracts/PlainCounter.sol"

FAILS=0
note() { echo "demo-severity-rubric.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$HUNTER" "$REFUTER" "$DISCOVERY" "$REFUTE" "$VERIFY" "$FIXSOL"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done

WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
# Never touch a live hunt registry: every driver run below gets its own throwaway state dir.
DARK_FACTORY_DIR="$WORK/df-state"; export DARK_FACTORY_DIR
mkdir -p "$DARK_FACTORY_DIR"

# The multi-line `"..." + "..."` string joins are flattened first, so an assertion can match the PROMPT text
# the model actually receives rather than one source line of it (the demo-operationalize-lens.sh idiom).
HUNTER_FLAT="$(tr '\n' ' ' < "$HUNTER" | sed 's/"[[:space:]]*+[[:space:]]*"//g')"
REFUTER_FLAT="$(tr '\n' ' ' < "$REFUTER" | sed 's/"[[:space:]]*+[[:space:]]*"//g')"

# _agfn <file> <fn> — the source text of one `.ag` helper, sliced by line range so nothing here is a copy that
# can drift from the shipped agent.
_agfn() {
  awk -v want="^fn $2\\\\(" '$0 ~ want {f=1} f{print} f&&/^}$/{exit}' "$1"
}
# _shfn <file> <fn> — the same for a shell function.
_shfn() {
  sed -n "/^$2() {\$/,/^}\$/p" "$1"
}

# ----------------------------------------------------------------------------------------------------------
# PART 1 — hunter.ag SOURCE-GUARD
# ----------------------------------------------------------------------------------------------------------
note "1) hunter.ag declares the six #2245 helpers ..."
HUNT_FNS="severity_rubric_marker severity_rubric_block dismiss_rule severity_rubric_enabled severity_rubric_directive dismiss_reask_block"
MISS=""
for fn in $HUNT_FNS; do
  grep -q "^fn $fn(" "$HUNTER" || MISS="$MISS $fn"
done
if [ -z "$MISS" ]; then
  ok "all 6 marker/block/emission/toggle/directive/re-ask helpers are declared in hunter.ag"
else
  bad "hunter.ag is missing #2245 helper(s):$MISS"
fi

note "2) the marker is the block's literal FIRST LINE (the sentinel cannot desync from the text) ..."
MARKER="$(_agfn "$HUNTER" severity_rubric_marker | sed -n 's/^[[:space:]]*return "\(.*\)";$/\1/p' | head -1)"
if [ -z "$MARKER" ]; then
  bad "could not read severity_rubric_marker()'s literal out of hunter.ag"
elif _agfn "$HUNTER" severity_rubric_block | sed -n 2p | grep -q 'return severity_rubric_marker() +'; then
  ok "severity_rubric_block() opens with severity_rubric_marker() — the sentinel greps a string that really renders"
else
  bad "severity_rubric_block() no longer opens with severity_rubric_marker() — the honesty-gated sentinel would silently stop firing"
fi

note "3) DEFAULT-OFF polarity: only the literal \"1\" opts in ..."
if _agfn "$HUNTER" severity_rubric_enabled | grep -q 'getenv("SEVERITY_RUBRIC") == "1"'; then
  ok "severity_rubric_enabled() is == \"1\" (unset / \"0\" / \"true\" are all OFF — the DEFAULT)"
else
  bad "severity_rubric_enabled() changed polarity — an unmeasured dismissal rubric must not ship default-ON (#2191)"
fi
if _agfn "$HUNTER" severity_rubric_directive | grep -q 'if !severity_rubric_enabled() { return ""; }'; then
  ok "severity_rubric_directive() returns \"\" when the knob is off — concatenating it is a no-op, so the default prompt is byte-identical"
else
  bad "severity_rubric_directive() lost its \"\"-when-disabled early return — the default prompt would change"
fi
# The knob is the ONLY gate: a detector argument would add a SECOND variable to a single-variable arm, and a
# severity judgment is cross-class anyway (it cannot be routed to a zone — that is why this is not a class).
if _agfn "$HUNTER" severity_rubric_directive | grep -qi 'code\|detector\|has_'; then
  bad "severity_rubric_directive() grew a payload/detector argument — the flag must stay the ONLY gate (single-variable arm)"
else
  ok "severity_rubric_directive() takes no payload and consults no detector — the flag is the only gate"
fi
if _agfn "$HUNTER" dismiss_reask_block | grep -q 'if open == "" { return ""; }'; then
  ok "dismiss_reask_block() is \"\" without DISMISS_REASK_GROUNDS — every FIRST attempt prompts identically"
else
  bad "dismiss_reask_block() no longer short-circuits on an empty DISMISS_REASK_GROUNDS — first attempts would differ"
fi

note "4) the SPLICE POSITION: the rubric is read after the config rule and before the resolver verb ..."
L_CFG="$(grep -n '^  + config_realizability_rule()$' "$HUNTER" | head -1 | cut -d: -f1)"
L_RUB="$(grep -n '^  + rubric$' "$HUNTER" | head -1 | cut -d: -f1)"
L_EXT="$(grep -n '^  + extres$' "$HUNTER" | head -1 | cut -d: -f1)"
if [ -n "$L_CFG" ] && [ -n "$L_RUB" ] && [ -n "$L_EXT" ] && [ "$L_CFG" -lt "$L_RUB" ] && [ "$L_RUB" -lt "$L_EXT" ]; then
  ok "the rubric sits in the shared RULES block between config_realizability_rule() and the resolver verb (it QUALIFIES the trusted-role exclusion two lines above it)"
else
  bad "the rubric's splice point moved (config=$L_CFG rubric=$L_RUB extres=$L_EXT) — it must be read AFTER the trusted-role exclusion it qualifies"
fi
if grep -q '^let rubric = severity_rubric_directive();$' "$HUNTER"; then
  ok "the directive is assembled once, at top level, beside the other conditional reads"
else
  bad "hunter.ag no longer assembles severity_rubric_directive() into a top-level 'rubric' binding"
fi

note "5) the SENTINEL is honesty-gated on the marker being in the assembled prompt ..."
if grep -q 'if index_of(instruction, severity_rubric_marker()) >= 0 {' "$HUNTER" \
   && grep -q 'print("SEVERITY-RUBRIC|" + subsystem + "|" + cls + "|on");' "$HUNTER"; then
  ok "SEVERITY-RUBRIC| is printed only when the marker is demonstrably IN the prompt about to be sent (never on the toggle's return value)"
else
  bad "the SEVERITY-RUBRIC| sentinel is missing or no longer gated on index_of(instruction, severity_rubric_marker())"
fi
# The gate in run-discovery.sh reads THIS sentinel, so a sentinel gated on getenv() would let a cell be re-asked
# and PROMOTED on a rubric that was never injected.
if grep -A2 'print("SEVERITY-RUBRIC|" + subsystem' "$HUNTER" | grep -q 'severity_rubric_enabled()'; then
  bad "the SEVERITY-RUBRIC| sentinel consults the toggle — it must be gated on the marker only (the honesty contract)"
else
  ok "the sentinel consults no toggle — a cell log cannot claim a rubric that was not assembled"
fi

note "6) the DISMISS| emission contract is stated with a location, a ground and its evidence ..."
DISMISS_OK=1
case "$HUNTER_FLAT" in
  *"DISMISS|<file:function[:line]>|<ground-id>|<the evidence that ground requires>"*) ;;
  *) DISMISS_OK=0 ;;
esac
case "$HUNTER_FLAT" in *"BEFORE your terminal verdict"*) ;; *) DISMISS_OK=0 ;; esac
if [ "$DISMISS_OK" -eq 1 ]; then
  ok "the emission contract asks for DISMISS|<file:function[:line]>|<ground-id>|<evidence>, BEFORE the terminal verdict"
else
  bad "the DISMISS| emission contract or its before-the-verdict placement changed — run-discovery.sh's scraper and gate both depend on it"
fi
# A dismissal must never be offered as a substitute for reporting the lead.
case "$HUNTER_FLAT" in
  *"never substitutes for a report"*) ok "the contract states a DISMISS line is never itself a finding and never replaces a CANDIDATE line" ;;
  *) bad "the DISMISS| contract lost its 'never substitutes for a report' clause — it would become an escape hatch from reporting" ;;
esac

note "6.1) hunter.ag declares the five #2245 iteration-3 helpers ..."
GE_FNS="ground_evidence_marker ground_evidence_block ground_evidence_enabled ground_evidence_directive ground_evidence_reask_clause"
MISS=""
for fn in $GE_FNS; do
  grep -q "^fn $fn(" "$HUNTER" || MISS="$MISS $fn"
done
if [ -z "$MISS" ]; then
  ok "all 5 marker/contract/toggle/directive/re-ask-clause helpers are declared in hunter.ag"
else
  bad "hunter.ag is missing #2245 iteration-3 helper(s):$MISS"
fi

note "6.2) the contract knob is INDEPENDENT and default-OFF, and its marker is the block's first line ..."
if _agfn "$HUNTER" ground_evidence_enabled | grep -q 'getenv("GROUND_EVIDENCE") == "1"'; then
  ok "ground_evidence_enabled() reads its OWN env var and is == \"1\" (unset / \"0\" / \"2\" are all OFF — the DEFAULT)"
else
  bad "ground_evidence_enabled() is not a default-OFF read of GROUND_EVIDENCE — a value sub-mode of SEVERITY_RUBRIC was explicitly rejected (it would make the iteration-2 arm unreproducible)"
fi
# The iteration-2 toggle must NOT have learned about the second knob: SEVERITY_RUBRIC=1 alone has to render
# exactly what the iteration-2 arm was measured with.
if _agfn "$HUNTER" severity_rubric_enabled | grep -q 'GROUND_EVIDENCE'; then
  bad "severity_rubric_enabled() now consults GROUND_EVIDENCE — the two knobs must stay independent"
else
  ok "severity_rubric_enabled() is untouched — SEVERITY_RUBRIC=1 alone still renders the iteration-2 prompt"
fi
if _agfn "$HUNTER" ground_evidence_block | sed -n 2p | grep -q 'return ground_evidence_marker() +'; then
  ok "ground_evidence_block() opens with ground_evidence_marker() — the sentinel greps a string that really renders"
else
  bad "ground_evidence_block() no longer opens with its marker — the honesty-gated sentinel would silently stop firing"
fi
if _agfn "$HUNTER" ground_evidence_directive | grep -q 'if !ground_evidence_enabled() { return ""; }' \
   && _agfn "$HUNTER" ground_evidence_reask_clause | grep -q 'if !ground_evidence_enabled() { return ""; }'; then
  ok "both the contract and the extra re-ask sentence are \"\" when the knob is off — concatenating them is a no-op"
else
  bad "the contract directive or the re-ask clause lost its \"\"-when-disabled early return — the iteration-2 prompt would change"
fi

note "6.3) the contract is spliced INSIDE the rubric directive, between the rubric and the emission contract ..."
if _agfn "$HUNTER" severity_rubric_directive \
   | grep -q 'return severity_rubric_block() + ground_evidence_directive() + dismiss_rule() + dismiss_reask_block();'; then
  ok "severity_rubric_directive() reads rubric -> per-ground contract -> emission contract (and GROUND_EVIDENCE=1 with the rubric OFF is inert by construction: no block, no marker, no sentinel)"
else
  bad "the contract is not concatenated inside severity_rubric_directive() — it could reach a rubric-OFF cell, or not reach a rubric-ON one"
fi
if _agfn "$HUNTER" dismiss_reask_block | grep -q '+ ground_evidence_reask_clause()'; then
  ok "dismiss_reask_block() carries the knob-gated second sentence (the iteration-2 re-ask text is byte-identical with the contract off)"
else
  bad "dismiss_reask_block() does not carry ground_evidence_reask_clause() — a contract failure could be re-asked without saying what is missing"
fi

note "6.4) the GROUND-EVIDENCE| sentinel is honesty-gated on the contract's own marker ..."
if grep -q 'if index_of(instruction, ground_evidence_marker()) >= 0 {' "$HUNTER" \
   && grep -q 'print("GROUND-EVIDENCE|" + subsystem + "|" + cls + "|on");' "$HUNTER"; then
  ok "GROUND-EVIDENCE| is printed only when the contract is demonstrably IN the prompt about to be sent"
else
  bad "the GROUND-EVIDENCE| sentinel is missing or no longer gated on index_of(instruction, ground_evidence_marker())"
fi
if grep -A2 'print("GROUND-EVIDENCE|" + subsystem' "$HUNTER" | grep -q 'ground_evidence_enabled()'; then
  bad "the GROUND-EVIDENCE| sentinel consults the toggle — it must be gated on the marker only (the honesty contract that makes the shell layer inert)"
else
  ok "the sentinel consults no toggle — a cell log cannot claim a contract that was not assembled"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 2 — refuter.ag SOURCE-GUARD
# ----------------------------------------------------------------------------------------------------------
note "7) refuter.ag declares the five #2245 helpers ..."
REF_FNS="severity_rubric_marker severity_rubric_block ground_rule severity_rubric_enabled severity_rubric_directive rubric_reask_block"
MISS=""
for fn in $REF_FNS; do
  grep -q "^fn $fn(" "$REFUTER" || MISS="$MISS $fn"
done
if [ -z "$MISS" ]; then
  ok "all 6 rubric helpers are declared in refuter.ag"
else
  bad "refuter.ag is missing #2245 helper(s):$MISS"
fi
if _agfn "$REFUTER" severity_rubric_enabled | grep -q 'getenv("SEVERITY_RUBRIC") == "1"' \
   && _agfn "$REFUTER" severity_rubric_directive | grep -q 'if !severity_rubric_enabled() { return ""; }'; then
  ok "the gate side has the SAME default-OFF polarity and the same \"\"-when-disabled contract"
else
  bad "refuter.ag's toggle polarity or its \"\"-when-disabled gate does not match hunter.ag's"
fi
if _agfn "$REFUTER" rubric_reask_block | grep -q 'if open == "" { return ""; }'; then
  ok "rubric_reask_block() is \"\" without RUBRIC_REASK_GROUNDS — every FIRST call prompts identically"
else
  bad "rubric_reask_block() no longer short-circuits on an empty RUBRIC_REASK_GROUNDS"
fi

note "8) the SPLICE POSITION: inside judge_body, in BOTH modes, BEFORE the tie-break ..."
SPLICES="$(grep -c '^ *+ severity_rubric_directive()$' "$REFUTER" || true)"
L_D1="$(grep -n 'TIE-BREAK: if after an honest trace' "$REFUTER" | head -1 | cut -d: -f1)"
L_D2="$(grep -n 'TIE-BREAK (INVERTED for a witnessed finding)' "$REFUTER" | head -1 | cut -d: -f1)"
L_S1="$(grep -n '^ *+ severity_rubric_directive()$' "$REFUTER" | head -1 | cut -d: -f1)"
L_S2="$(grep -n '^ *+ severity_rubric_directive()$' "$REFUTER" | sed -n 2p | cut -d: -f1)"
if [ "$SPLICES" = "2" ] && [ -n "$L_S1" ] && [ -n "$L_S2" ] \
   && [ "$L_S1" -lt "$L_D1" ] && [ "$L_S2" -lt "$L_D2" ]; then
  ok "the rubric is spliced in BOTH judge_body branches (discovery-lead and the #1938 invariant mode), each time BEFORE its tie-break"
else
  bad "the refuter splice is wrong (splices=$SPLICES at $L_S1/$L_S2, tie-breaks at $L_D1/$L_D2) — the rubric must qualify rule (b) before the tie-break is read"
fi
# The conservative tie-break IS the precision mechanism of this gate (#1938). This change must not touch it.
case "$REFUTER_FLAT" in
  *"answer REFUTED. Surviving this gate must require the claim to be unambiguously real; uncertainty kills it."*)
    ok "the conservative discovery-lead TIE-BREAK is untouched (the precision mechanism the plan explicitly refuses to loosen)" ;;
  *) bad "the conservative TIE-BREAK text changed — loosening it was explicitly rejected; only the GROUNDS are qualified by this change" ;;
esac
case "$REFUTER_FLAT" in
  *"TIE-BREAK (INVERTED for a witnessed finding): the fuzzer already reproduced this exact exploit sequence"*)
    ok "the #1938 INVERTED tie-break of the invariant mode is untouched too" ;;
  *) bad "the invariant-mode TIE-BREAK text changed — this iteration must not touch either tie-break" ;;
esac

note "9) the gate-side output ORDER is stated: REFUTE-GROUND| then CONSTRAINT| then VERDICT| ..."
ORDER_OK=1
case "$REFUTER_FLAT" in
  *"REFUTE-GROUND|<ground-id>|<the evidence that ground requires>"*) ;;
  *) ORDER_OK=0 ;;
esac
case "$REFUTER_FLAT" in
  *"It goes BEFORE the CONSTRAINT| line, and therefore before the VERDICT| line"*) ;;
  *) ORDER_OK=0 ;;
esac
if [ "$ORDER_OK" -eq 1 ]; then
  ok "the ground line is asked for BEFORE the constraint and the verdict (anything after the verdict is swallowed into its reason)"
else
  bad "the REFUTE-GROUND| grammar or its before-the-verdict placement changed — _join_wrapped_verdict would swallow it and shift verify-findings.sh's field read"
fi
if grep -q 'if index_of(instruction, severity_rubric_marker()) >= 0 { print("SEVERITY-RUBRIC|refute|on"); }' "$REFUTER"; then
  ok "the gate-side sentinel is honesty-gated on the marker too, and is printed BEFORE the prompt() call"
else
  bad "refuter.ag's SEVERITY-RUBRIC| sentinel is missing or not gated on the assembled instruction"
fi

note "9.1) refuter.ag carries the SAME five iteration-3 helpers, the same splice and the same sentinel ..."
MISS=""
for fn in $GE_FNS; do
  grep -q "^fn $fn(" "$REFUTER" || MISS="$MISS $fn"
done
if [ -n "$MISS" ]; then
  bad "refuter.ag is missing #2245 iteration-3 helper(s):$MISS"
elif _agfn "$REFUTER" severity_rubric_directive \
     | grep -q 'return severity_rubric_block() + ground_evidence_directive() + ground_rule() + rubric_reask_block();'; then
  ok "the gate side splices the contract in the same place, so it lands in BOTH judge modes (the directive is read by each)"
else
  bad "refuter.ag does not concatenate ground_evidence_directive() inside severity_rubric_directive()"
fi
if _agfn "$REFUTER" rubric_reask_block | grep -q '+ ground_evidence_reask_clause()'; then
  ok "rubric_reask_block() carries the same knob-gated second sentence"
else
  bad "rubric_reask_block() does not carry ground_evidence_reask_clause()"
fi
if grep -q 'if index_of(instruction, ground_evidence_marker()) >= 0 { print("GROUND-EVIDENCE|refute|on"); }' "$REFUTER"; then
  ok "the gate-side GROUND-EVIDENCE| sentinel is honesty-gated on the marker too, and is printed BEFORE the prompt() call"
else
  bad "refuter.ag's GROUND-EVIDENCE| sentinel is missing or not gated on the assembled instruction"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 3 — ANTI-DRIFT: one rubric, one ground list, four copies that cannot diverge
# ----------------------------------------------------------------------------------------------------------
note "10) the rubric + closed ground list is BYTE-IDENTICAL in hunter.ag and refuter.ag ..."
for fn in severity_rubric_marker severity_rubric_block; do
  _agfn "$HUNTER" "$fn"  > "$WORK/h-$fn.txt"
  _agfn "$REFUTER" "$fn" > "$WORK/r-$fn.txt"
  if [ ! -s "$WORK/h-$fn.txt" ] || [ ! -s "$WORK/r-$fn.txt" ]; then
    bad "could not slice $fn() out of both agents"
  elif cmp -s "$WORK/h-$fn.txt" "$WORK/r-$fn.txt"; then
    ok "$fn() is byte-identical in both agents ($(wc -c < "$WORK/h-$fn.txt" | tr -d ' ') bytes) — one standard, two decision points"
  else
    bad "$fn() has DRIFTED between hunter.ag and refuter.ag — the hunt side and the gate side would judge severity differently"
    diff "$WORK/h-$fn.txt" "$WORK/r-$fn.txt" | head -6 | sed 's/^/      /' >&2
  fi
done
# NEGATIVE CONTROL for the diff itself: a mutated copy must be detected.
sed 's/Medium is NOT reserved/Medium is reserved/' "$WORK/h-severity_rubric_block.txt" > "$WORK/mutated-block.txt"
if cmp -s "$WORK/h-severity_rubric_block.txt" "$WORK/mutated-block.txt"; then
  bad "the anti-drift comparison cannot detect a one-word mutation — the guard is dead"
else
  ok "the anti-drift comparison fires on a one-word mutation of the rubric (negative control)"
fi

note "11) the SHELL ground list is byte-identical in both drivers and matches the prompt text ..."
_shfn "$DISCOVERY" _rubric_sufficient_grounds > "$WORK/d-grounds.sh"
_shfn "$REFUTE"    _rubric_sufficient_grounds > "$WORK/r-grounds.sh"
if [ ! -s "$WORK/d-grounds.sh" ] || [ ! -s "$WORK/r-grounds.sh" ]; then
  bad "could not slice _rubric_sufficient_grounds() out of both drivers"
elif cmp -s "$WORK/d-grounds.sh" "$WORK/r-grounds.sh"; then
  ok "_rubric_sufficient_grounds() is byte-identical in run-discovery.sh and run-refute.sh"
else
  bad "_rubric_sufficient_grounds() has DRIFTED between the two drivers — one gate would accept a ground the other rejects"
fi
# shellcheck disable=SC1090,SC1091  # sliced out of run-discovery.sh at runtime, by design
. "$WORK/d-grounds.sh"
GROUND_MISS=""
for g in $(_rubric_sufficient_grounds); do
  case "$HUNTER_FLAT" in *"$g"*) ;; *) GROUND_MISS="$GROUND_MISS $g(hunter)" ;; esac
  case "$REFUTER_FLAT" in *"$g"*) ;; *) GROUND_MISS="$GROUND_MISS $g(refuter)" ;; esac
done
for g in no-attacker trusted-config alt-path dust-unquantified; do
  case "$HUNTER_FLAT" in *"$g"*) ;; *) GROUND_MISS="$GROUND_MISS $g(hunter)" ;; esac
  case "$REFUTER_FLAT" in *"$g"*) ;; *) GROUND_MISS="$GROUND_MISS $g(refuter)" ;; esac
done
if [ -z "$GROUND_MISS" ]; then
  ok "all 9 ground ids the shells decide on (5 sufficient + 4 insufficient) appear in BOTH prompt texts"
else
  bad "a ground id the shell decides on is not offered to the model:$GROUND_MISS"
fi
# The UNION rule is the whole reason the gate groups by LOCATION: the measured loss stacked three of them.
case "$HUNTER_FLAT" in
  *"ANY UNION of them is STILL insufficient"*) ok "the rubric states the UNION rule explicitly (three weak grounds do not build one strong one)" ;;
  *) bad "the rubric lost its UNION rule — the measured loss stacked THREE insufficient grounds on one lead" ;;
esac
case "$HUNTER_FLAT" in
  *"A missing, empty or unrecognised ground id counts as INSUFFICIENT."*)
    ok "the rubric states that a missing/unrecognised ground is insufficient — which is exactly what makes the sufficient list the shells' single decider" ;;
  *) bad "the rubric no longer states that a missing/unrecognised ground is insufficient (the shell has no second list to fall back on)" ;;
esac

note "11.1) the per-ground EVIDENCE contract is BYTE-IDENTICAL in both agents ..."
for fn in $GE_FNS; do
  _agfn "$HUNTER" "$fn"  > "$WORK/h-$fn.txt"
  _agfn "$REFUTER" "$fn" > "$WORK/r-$fn.txt"
  if [ ! -s "$WORK/h-$fn.txt" ] || [ ! -s "$WORK/r-$fn.txt" ]; then
    bad "could not slice $fn() out of both agents"
  elif cmp -s "$WORK/h-$fn.txt" "$WORK/r-$fn.txt"; then
    ok "$fn() is byte-identical in both agents ($(wc -c < "$WORK/h-$fn.txt" | tr -d ' ') bytes)"
  else
    bad "$fn() has DRIFTED between hunter.ag and refuter.ag — the hunt side and the gate side would demand different evidence"
    diff "$WORK/h-$fn.txt" "$WORK/r-$fn.txt" | head -6 | sed 's/^/      /' >&2
  fi
done
sed 's/ADMITTED IS NOT DEPLOYED/ADMITTED IS DEPLOYED/' "$WORK/h-ground_evidence_block.txt" > "$WORK/mutated-contract.txt"
if cmp -s "$WORK/h-ground_evidence_block.txt" "$WORK/mutated-contract.txt"; then
  bad "the contract anti-drift comparison cannot detect a mutation — the guard is dead"
else
  ok "the contract anti-drift comparison fires on a mutation of the admitted-vs-deployed rule (negative control)"
fi

note "11.2) the iteration-2 rubric string is FROZEN — every new sentence lives in the new block ..."
FROZEN_BAD=""
for tok in 'delta=0:' 'loss=' 'ADMITTED IS NOT DEPLOYED' 'EVIDENCE CONTRACT PER GROUND'; do
  grep -Fq "$tok" "$WORK/h-severity_rubric_block.txt" && FROZEN_BAD="$FROZEN_BAD [$tok]"
done
if [ -z "$FROZEN_BAD" ]; then
  ok "severity_rubric_block() carries NONE of the iteration-3 contract tokens — the arm delta is entirely in the new block, so the two arms stay comparable"
else
  bad "an iteration-3 token leaked into the FROZEN iteration-2 rubric string:$FROZEN_BAD — the rubric arm would no longer be reproducible"
fi

note "11.3) the shell DECIDER and its requirement table are byte-identical in both drivers ..."
for fn in _dismiss_evidence_ok _contract_requirement _ground_contract_armed; do
  _shfn "$DISCOVERY" "$fn" > "$WORK/d-$fn.sh"
  _shfn "$REFUTE"    "$fn" > "$WORK/r-$fn.sh"
  if [ ! -s "$WORK/d-$fn.sh" ] || [ ! -s "$WORK/r-$fn.sh" ]; then
    bad "could not slice $fn() out of both drivers"
  elif cmp -s "$WORK/d-$fn.sh" "$WORK/r-$fn.sh"; then
    ok "$fn() is byte-identical in run-discovery.sh and run-refute.sh — one decider, two decision points"
  else
    bad "$fn() has DRIFTED between the two drivers — one gate would accept evidence the other rejects"
    diff "$WORK/d-$fn.sh" "$WORK/r-$fn.sh" | head -6 | sed 's/^/      /' >&2
  fi
done

note "11.4) the shell requirement table and the agents' contract text cannot drift apart, in EITHER direction ..."
CONTRACT_TXT="$WORK/contract-text.txt"
{ _agfn "$HUNTER" ground_evidence_block; _agfn "$HUNTER" ground_evidence_reask_clause; } > "$CONTRACT_TXT"
TOK_MISS=""
for tok in 'delta=0:' 'loss='; do
  grep -Fq "$tok" "$CONTRACT_TXT" || TOK_MISS="$TOK_MISS $tok(prompt)"
  grep -Fq "$tok" "$WORK/d-_contract_requirement.sh" || TOK_MISS="$TOK_MISS $tok(shell)"
done
if [ -z "$TOK_MISS" ]; then
  ok "the two literal tokens the decider greps for (delta=0:, loss=) appear VERBATIM in the prompt AND in the re-ask table — neither side can ask for what the other never defined"
else
  bad "a machine-checked token is missing from one side:$TOK_MISS"
fi
# Every contract id the decider can print must have a phrase in the table (an unknown id would be re-asked
# with the generic fallback, i.e. with no requirement at all).
ID_MISS=""
for cid in cite-missing cite-unresolved cite-not-a-guard cite-not-validating no-zero-delta reachability-as-no-loss unquantified admitted-vs-deployed; do
  grep -Fq "$cid" "$WORK/d-_dismiss_evidence_ok.sh" || ID_MISS="$ID_MISS $cid(decider)"
  grep -Fq "$cid" "$WORK/d-_contract_requirement.sh" || ID_MISS="$ID_MISS $cid(table)"
done
if [ -z "$ID_MISS" ]; then
  ok "all 8 contract ids are emitted by the decider AND carry a one-line requirement in the table"
else
  bad "a contract id is not decidable or has no requirement phrase:$ID_MISS"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 4 — WIRING: registrations, boundaries, token invariants
# ----------------------------------------------------------------------------------------------------------
note "12) both exec.env_passthrough lines register the new knobs (#1426: getenv() reads the SANITISED env) ..."
D_PASS="$(grep 'echo "exec.env_passthrough' "$DISCOVERY" | head -1)"
R_PASS="$(grep 'echo "exec.env_passthrough' "$REFUTE" | head -1)"
PASS_MISS=""
case "$D_PASS" in *SEVERITY_RUBRIC*) ;; *) PASS_MISS="$PASS_MISS SEVERITY_RUBRIC(discovery)" ;; esac
case "$D_PASS" in *DISMISS_REASK_GROUNDS*) ;; *) PASS_MISS="$PASS_MISS DISMISS_REASK_GROUNDS(discovery)" ;; esac
case "$R_PASS" in *SEVERITY_RUBRIC*) ;; *) PASS_MISS="$PASS_MISS SEVERITY_RUBRIC(refute)" ;; esac
case "$R_PASS" in *RUBRIC_REASK_GROUNDS*) ;; *) PASS_MISS="$PASS_MISS RUBRIC_REASK_GROUNDS(refute)" ;; esac
if [ -z "$PASS_MISS" ]; then
  ok "all four knobs ride exec.env_passthrough — the opt-in and both re-ask channels can actually reach the agents"
else
  bad "an unregistered knob would be SILENTLY INERT (#1426):$PASS_MISS"
fi
# And they must actually be exported into the cell environment, not merely allowlisted.
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
if grep -q 'SEVERITY_RUBRIC="${SEVERITY_RUBRIC:-}"' "$DISCOVERY" && grep -q 'DISMISS_REASK_GROUNDS="$rc_dismiss_grounds"' "$DISCOVERY"; then
  ok "run-discovery.sh exports both into the hunter cell env (allowlisting alone passes nothing through)"
else
  bad "run-discovery.sh does not export SEVERITY_RUBRIC / DISMISS_REASK_GROUNDS into the cell env"
fi
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
if grep -q 'SEVERITY_RUBRIC="${SEVERITY_RUBRIC:-}"' "$REFUTE" && grep -q 'RUBRIC_REASK_GROUNDS="$RUBRIC_GROUNDS"' "$REFUTE"; then
  ok "run-refute.sh exports both into the refuter cell env, in the SAME _rf_attempt that carries brief/aux/invariant"
else
  bad "run-refute.sh does not export SEVERITY_RUBRIC / RUBRIC_REASK_GROUNDS into the refuter env"
fi

note "13) the two new model-emitted tokens are RECORD BOUNDARIES in _join_wrapped_candidates ..."
BOUNDARY_LINE="$(grep -n 'BLACKBOARD-/ ||' "$DISCOVERY" | head -1 | cut -d: -f2-)"
BOUND_MISS=""
case "$BOUNDARY_LINE" in *'SEVERITY-RUBRIC\|'*) ;; *) BOUND_MISS="$BOUND_MISS SEVERITY-RUBRIC|" ;; esac
case "$BOUNDARY_LINE" in *'DISMISS\|'*) ;; *) BOUND_MISS="$BOUND_MISS DISMISS|" ;; esac
if [ -z "$BOUNDARY_LINE" ]; then
  bad "could not find the _join_wrapped_candidates boundary alternation in run-discovery.sh"
elif [ -z "$BOUND_MISS" ]; then
  ok "_join_wrapped_candidates lists SEVERITY-RUBRIC| and DISMISS| next to the sibling boundary tokens"
else
  bad "the _join_wrapped_candidates boundary alternation is missing:$BOUND_MISS"
fi
# Behavioural half: the SHIPPED awk program over a PTY-wrapped CANDIDATE followed by a DISMISS line.
JWC_AWK="$WORK/join-wrapped.awk"
_shfn "$DISCOVERY" _join_wrapped_candidates | sed -n "/^  awk '\$/,/^  ' /p" | sed '1d; $d' > "$JWC_AWK"
WRAP_LOG="$WORK/wrapped-cell.log"
{
  printf 'SEVERITY-RUBRIC|vault|C25|on\n'
  printf 'CANDIDATE|Vault.sol:exitPool:48|C25|Medium|the exit leg reverts on a zero-weight leg|deploy a pool\n'
  printf '  stub, set the weight to zero, and assert the exit call reverts\n'
  printf 'DISMISS|Vault.sol:joinPool|no-attacker|nobody profits from the reverted entry\n'
  printf 'SAFE\n'
} > "$WRAP_LOG"
if [ ! -s "$JWC_AWK" ]; then
  bad "could not extract the _join_wrapped_candidates awk program from run-discovery.sh (reshaped?)"
else
  JOINED="$(awk -f "$JWC_AWK" "$WRAP_LOG")"
  JOINED_N="$(printf '%s\n' "$JOINED" | grep -c 'CANDIDATE|' || true)"
  if [ "$JOINED_N" = "1" ] && ! printf '%s\n' "$JOINED" | grep -q 'DISMISS|'; then
    ok "a DISMISS| line closes the open CANDIDATE record instead of being glued into its PoC sketch"
  else
    bad "the DISMISS| boundary does not hold: $JOINED_N candidate record(s), DISMISS glued=$(printf '%s\n' "$JOINED" | grep -c 'DISMISS|' || true)"
  fi
fi

note "14) REFUTE-GROUND| is a closing boundary in ALL THREE refute scrapers ..."
SCRAPE_MISS=""
_shfn "$REFUTE" _join_wrapped_verdict    | grep -q 'REFUTE-GROUND' || SCRAPE_MISS="$SCRAPE_MISS _join_wrapped_verdict"
_shfn "$REFUTE" _join_wrapped_constraint | grep -q 'REFUTE-GROUND' || SCRAPE_MISS="$SCRAPE_MISS _join_wrapped_constraint"
grep -q '^_join_wrapped_ground() {$' "$REFUTE" || SCRAPE_MISS="$SCRAPE_MISS _join_wrapped_ground(missing)"
if [ -z "$SCRAPE_MISS" ]; then
  ok "the ground token closes both existing scrapers and has its own THIRD scraper (touching _join_wrapped_verdict was avoided by design)"
else
  bad "the refute scrapers are not all ground-aware:$SCRAPE_MISS"
fi

note "15) TOKEN INVARIANTS: no diagnostic token carries CANDIDATE| or VERDICT| ..."
TOK_BAD=""
for tok in 'DISMISS|' 'SEVERITY-RUBRIC|' 'RUBRIC-PROMOTED|' 'REFUTE-GROUND|'; do
  case "$tok" in *'CANDIDATE|'*) TOK_BAD="$TOK_BAD $tok:CANDIDATE" ;; esac
  case "$tok" in *'VERDICT|'*) TOK_BAD="$TOK_BAD $tok:VERDICT" ;; esac
done
# The four ground ids a model may ever write into one of those lines must be equally clean.
for g in $(_rubric_sufficient_grounds) no-attacker trusted-config alt-path dust-unquantified; do
  case "$g" in *'CANDIDATE|'*|*'VERDICT|'*) TOK_BAD="$TOK_BAD ground:$g" ;; esac
done
if [ -z "$TOK_BAD" ]; then
  ok "none of the four tokens (nor any ground id) contains CANDIDATE| or VERDICT| — lib/run-agent-validated.sh's two sentinel predicates cannot false-accept a reply on them"
else
  bad "a token or ground id would false-accept a reply shape:$TOK_BAD"
fi
# The PROMOTED sidecar deliberately DOES carry a synthesised CANDIDATE| line — that is the promotion — but it
# must never be written into the cell log itself, which stays a pure model transcript.
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
if _shfn "$DISCOVERY" _rubric_promote | grep -q '>> "\$rp_out"' \
   && ! _shfn "$DISCOVERY" _rubric_promote | grep -q '>> "\$rp_log"'; then
  ok "_rubric_promote writes only the .rubric-promoted sidecar — the cell log stays a pure model transcript"
else
  bad "_rubric_promote writes into the cell log — a synthesised candidate would be indistinguishable from a model-emitted one in the transcript"
fi
# Marker/attempt files must NOT end in `.log` (hunt-dashboard + `find -name 'hunt_*.log'` readouts).
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
if grep -q 'rubric-attempt-\$rc_rubric' "$DISCOVERY" && ! grep -q 'rubric-attempt-\$rc_rubric.log' "$DISCOVERY" \
   && grep -q 'rubric-promoted' "$DISCOVERY"; then
  ok "the superseded attempt and the promotion sidecar use suffixes that do NOT end in .log (one log per cell for every readout)"
else
  bad "a #2245 marker/attempt file ends in .log — it would be scraped as a second cell log by the dashboard and the readouts"
fi

note "15.1) GROUND_EVIDENCE rides BOTH exec.env_passthrough lines and BOTH cell env blocks (#1426) ..."
GE_MISS=""
case "$D_PASS" in *GROUND_EVIDENCE*) ;; *) GE_MISS="$GE_MISS passthrough(discovery)" ;; esac
case "$R_PASS" in *GROUND_EVIDENCE*) ;; *) GE_MISS="$GE_MISS passthrough(refute)" ;; esac
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
grep -q 'GROUND_EVIDENCE="${GROUND_EVIDENCE:-}"' "$DISCOVERY" || GE_MISS="$GE_MISS env(discovery)"
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
grep -q 'GROUND_EVIDENCE="${GROUND_EVIDENCE:-}"' "$REFUTE" || GE_MISS="$GE_MISS env(refute)"
if [ -z "$GE_MISS" ]; then
  ok "the second knob is allowlisted AND exported on both sides — an unregistered knob would be SILENTLY INERT"
else
  bad "the GROUND_EVIDENCE wiring is incomplete (#1426):$GE_MISS"
fi

note "15.2) GROUND-EVIDENCE| is a record boundary in ALL FOUR scrapers ..."
GB_MISS=""
case "$BOUNDARY_LINE" in *'GROUND-EVIDENCE\|'*) ;; *) GB_MISS="$GB_MISS _join_wrapped_candidates" ;; esac
_shfn "$REFUTE" _join_wrapped_verdict    | grep -q 'GROUND-EVIDENCE' || GB_MISS="$GB_MISS _join_wrapped_verdict"
_shfn "$REFUTE" _join_wrapped_constraint | grep -q 'GROUND-EVIDENCE' || GB_MISS="$GB_MISS _join_wrapped_constraint"
_shfn "$REFUTE" _join_wrapped_ground     | grep -q 'GROUND-EVIDENCE' || GB_MISS="$GB_MISS _join_wrapped_ground"
if [ -z "$GB_MISS" ]; then
  ok "the new sentinel closes an open record in the hunt scraper and in all three refute scrapers"
else
  bad "the GROUND-EVIDENCE| boundary is missing from:$GB_MISS"
fi
# Behavioural half, on the SHIPPED awk program: the sentinel must not be glued into a wrapped candidate.
if [ -s "$JWC_AWK" ]; then
  GE_WRAP_LOG="$WORK/wrapped-cell-ge.log"
  {
    printf 'SEVERITY-RUBRIC|vault|C25|on\n'
    printf 'GROUND-EVIDENCE|vault|C25|on\n'
    printf 'CANDIDATE|Vault.sol:exitPool:48|C25|Medium|the exit leg reverts on a zero-weight leg|deploy a pool\n'
    printf '  stub, set the weight to zero, and assert the exit call reverts\n'
    printf 'GROUND-EVIDENCE|vault|C25|on\n'
    printf 'SAFE\n'
  } > "$GE_WRAP_LOG"
  GE_JOINED="$(awk -f "$JWC_AWK" "$GE_WRAP_LOG")"
  if [ "$(printf '%s\n' "$GE_JOINED" | grep -c 'CANDIDATE|' || true)" = "1" ] \
     && ! printf '%s\n' "$GE_JOINED" | grep -q 'GROUND-EVIDENCE|'; then
    ok "a GROUND-EVIDENCE| line closes the open CANDIDATE record instead of being glued into its PoC sketch"
  else
    bad "the GROUND-EVIDENCE| boundary does not hold in the shipped awk program"
  fi
fi

note "15.3) the new token carries neither CANDIDATE| nor VERDICT| ..."
GE_TOK_BAD=""
GE_TOK='GROUND-EVIDENCE|'
case "$GE_TOK" in *'CANDIDATE|'*) GE_TOK_BAD="$GE_TOK_BAD $GE_TOK:CANDIDATE" ;; esac
case "$GE_TOK" in *'VERDICT|'*) GE_TOK_BAD="$GE_TOK_BAD $GE_TOK:VERDICT" ;; esac
if [ -z "$GE_TOK_BAD" ]; then
  ok "GROUND-EVIDENCE| contains neither sentinel substring — neither of lib/run-agent-validated.sh's predicates can false-accept a cell on it"
else
  bad "the new token would false-accept a reply shape:$GE_TOK_BAD"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 5 — OVERFITTING DENYLIST + SUBSTRATE PURITY
# ----------------------------------------------------------------------------------------------------------
note "16) OVERFITTING GUARD: the rubric stays PURE-META (no protocol, product or corpus target) ..."
PROMPT_TXT="$WORK/prompt-text.txt"
{
  _agfn "$HUNTER" severity_rubric_block
  _agfn "$HUNTER" dismiss_rule
  _agfn "$HUNTER" dismiss_reask_block
  _agfn "$REFUTER" ground_rule
  _agfn "$REFUTER" rubric_reask_block
  # #2245 iteration 3: the per-ground contract and its re-ask sentence are prompt-visible text too, so they are
  # judged by exactly the same denylist — the contract names path:line shapes and two literal tokens, never a
  # protocol, a file, a unit or a corpus target.
  _agfn "$HUNTER" ground_evidence_block
  _agfn "$HUNTER" ground_evidence_reask_clause
} > "$PROMPT_TXT"
# The generic product denylist of demo-operationalize-lens.sh, plus the two corpus rules colony-lint already
# enforces on every prompt-visible file (#2231/#2233): the literal `corpus-bench`, and a bare ground-truth
# finding id. The CONTEST NAMES themselves are deliberately NOT listed here — writing them into a tracked file
# under dark-factory/ is the very thing that discipline forbids; they live only in the docs-only provenance
# table of bench/corpus-bench/bug-class-coverage.md, and the shipped #2231 lint scan (which covers
# auditor/** and every .ag, i.e. both files the rubric lives in) is what keeps them out of the lens.
DENY='Curve|Convex|Pendle|Balancer|Uniswap|Aave|Compound|useEth|use_eth|WETH|wrapNative|slot0|ERC-?[0-9]|\.sol'
GT_ID='(^|[^[:alnum:]_])[HM]-[0-9]{1,2}([^[:alnum:]_]|$)'
if [ ! -s "$PROMPT_TXT" ]; then
  bad "could not slice the rubric prompt text out of the two agents"
elif grep -Eq "$DENY" "$PROMPT_TXT"; then
  bad "the rubric names a protocol/product/parameter specific (it would leak an answer into a hunt)"
  grep -nE "$DENY" "$PROMPT_TXT" | head -3 | sed 's/^/      /' >&2
elif grep -qi 'corpus-bench' "$PROMPT_TXT"; then
  bad "the rubric names the corpus — the lens must never carry the benchmark it is scored on (#2231)"
elif grep -EqI "$GT_ID" "$PROMPT_TXT"; then
  bad "the rubric carries a ground-truth finding id (#2233) — provenance belongs in the issue number, never in a contest's finding id"
else
  ok "the rubric names no protocol, product, contract, function, unit, corpus or ground-truth id (pure-meta — injecting it cannot leak an answer)"
fi
# The rubric text must be INSIDE the shipped #2231/#2233 lint scope, which is what actually keeps a contest
# name out of it — this demo deliberately does not re-list the contest names to check them against.
if [ "$(printf '%s\n' "$HUNTER" "$REFUTER" | grep -c '/auditor/agents/')" = "2" ]; then
  ok "both rubric copies live under dark-factory/auditor/ (and are .ag), so colony-lint's #2231/#2233 prompt-visibility scan covers them"
else
  bad "a rubric copy moved outside the #2231/#2233 scan scope — a contest name could enter the lens unchecked"
fi
# NEGATIVE CONTROL: both detectors must actually fire on a planted hint. The ground-truth id is COMPOSED at
# run time rather than written out, so this file never itself carries one.
printf 'the Balancer pool returns a 1e18 value from Foo.sol and GT %s-9 confirms it\n' 'H' > "$WORK/planted.txt"
if grep -Eq "$DENY" "$WORK/planted.txt" && grep -EqI "$GT_ID" "$WORK/planted.txt"; then
  ok "the overfitting + ground-truth-id detectors both fire on a planted hint (negative control)"
else
  bad "the overfitting / ground-truth-id detector does not fire on a planted hint — the guard is dead"
fi

note "17) substrate purity (#1587): the new .ag code is builtins-only ..."
PURE="$WORK/pure.txt"
{
  # The slice runs from the iteration-2 header to the next unrelated block, so it covers the iteration-3
  # helpers too (they sit between the two).
  awk '/--- #2245 iteration 2: CONTEST-SEVERITY DISMISSAL RUBRIC/{f=1} f&&/^\/\/ --- #2235 READ THE EXTERNAL PROTOCOL/{exit} f{print}' "$HUNTER"
  awk '/--- #2245 iteration 2: CONTEST-SEVERITY DISMISSAL RUBRIC/{f=1} f&&/^\/\/ --- #1938 invariant-hunt judgment mode/{exit} f{print}' "$REFUTER"
} | grep -v '^[[:space:]]*//' > "$PURE"
if ! grep -q 'ground_evidence_block' "$PURE"; then
  bad "the substrate-purity slice does not cover the #2245 iteration-3 helpers (block moved?)"
elif [ ! -s "$PURE" ]; then
  bad "could not slice the #2245 blocks out of the two agents (header comment renamed?)"
elif grep -Eq 'exec sh|python3 -c|reduce\(|regex_' "$PURE"; then
  bad "the #2245 block introduced an embedded interpreter / regex / reduce (substrate-purity ratchet + per-element CB cost)"
  grep -nE 'exec sh|python3 -c|reduce\(|regex_' "$PURE" | head -3 | sed 's/^/      /' >&2
else
  ok "both #2245 blocks use only native builtins and O(1) string concat (no exec sh, no regex/reduce, no per-element cost)"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 6 — THE DETERMINISTIC GATE, FIXTURE-DRIVEN (the shipped functions, sliced — never copied)
# ----------------------------------------------------------------------------------------------------------
note "18) the shipped gate functions slice out of run-discovery.sh and load ..."
GATE_FNS="$WORK/gate-fns.sh"
{
  _shfn "$DISCOVERY" _rubric_sufficient_grounds
  _shfn "$DISCOVERY" _dismiss_lines
  _shfn "$DISCOVERY" _dismiss_ground
  # #2245 iteration 3: the contract layer, sliced from the SAME driver so the fixtures below exercise exactly
  # what production runs — never a copy that could drift.
  _shfn "$DISCOVERY" _ground_contract_armed
  _shfn "$DISCOVERY" _dismiss_evidence_ok
  _shfn "$DISCOVERY" _contract_requirement
  _shfn "$DISCOVERY" _dismiss_contract_rows
  _shfn "$DISCOVERY" _contract_failed_dismissals
  _shfn "$DISCOVERY" _insufficient_dismissal_rows
  _shfn "$DISCOVERY" _insufficient_dismissal_locs
  _shfn "$DISCOVERY" _rubric_dismissal_gap
  _shfn "$DISCOVERY" _rubric_reask_needed
  _shfn "$DISCOVERY" _rubric_open_grounds
  _shfn "$DISCOVERY" _rubric_promote
  _shfn "$DISCOVERY" _rubric_promoted_candidates
  _shfn "$DISCOVERY" _rubric_promoted_count
  _shfn "$DISCOVERY" _cell_candidates
  # _cell_candidates also unions the #2245 iteration-5 and #2264 promoted records; slice their (sidecar-only) readers too,
  # so the sourced union never calls an undefined function.
  _shfn "$DISCOVERY" _param_promoted_candidates
  _shfn "$DISCOVERY" _promise_promoted_candidates
  _shfn "$DISCOVERY" _join_wrapped_candidates
  # _rubric_promote validates its location with the SHIPPED tier-2 helpers, so the slice must carry them or the
  # extracted gate would behave differently here than in production (the whole point of slicing).
  _shfn "$DISCOVERY" _tier2_resolve_file
  _shfn "$DISCOVERY" _tier2_emit_loc
} > "$GATE_FNS"
GATE_LOADED=0
if grep -q '^_rubric_dismissal_gap() {$' "$GATE_FNS" && grep -q '^_rubric_promote() {$' "$GATE_FNS" \
   && grep -q '^_tier2_emit_loc() {$' "$GATE_FNS" && grep -q '^_rubric_reask_needed() {$' "$GATE_FNS" \
   && grep -q '^_dismiss_evidence_ok() {$' "$GATE_FNS" && grep -q '^_dismiss_contract_rows() {$' "$GATE_FNS"; then
  # shellcheck disable=SC1090  # sliced out of run-discovery.sh at runtime, by design
  . "$GATE_FNS"
  GATE_LOADED=1
  ok "the shipped gate functions (_rubric_dismissal_gap / _rubric_reask_needed / _rubric_promote / _cell_candidates / ...) extracted from run-discovery.sh and sourced"
else
  bad "could not extract the #2245 gate functions from run-discovery.sh (renamed or reshaped?)"
fi

# _cl <name> <line...> — write a synthetic cell log and print its path.
_cl() {
  _cl_name="$1"; shift
  _cl_path="$WORK/$_cl_name.log"
  : > "$_cl_path"
  for _cl_line in "$@"; do printf '%s\n' "$_cl_line" >> "$_cl_path"; done
  printf '%s\n' "$_cl_path"
}
# _assert_gate <label> <log> <expected-gap> <expected-trip: yes|no>
_assert_gate() {
  _ag_label="$1"; _ag_log="$2"; _ag_gap="$3"; _ag_trip="$4"
  _ag_got="$(_rubric_dismissal_gap "$_ag_log")"
  if _rubric_reask_needed "$_ag_log"; then _ag_fired=yes; else _ag_fired=no; fi
  if [ "$_ag_got" = "$_ag_gap" ] && [ "$_ag_fired" = "$_ag_trip" ]; then
    ok "$_ag_label: gap=$_ag_got, gate trips=$_ag_fired (as specified)"
  else
    bad "$_ag_label: gap=$_ag_got (want $_ag_gap), gate trips=$_ag_fired (want $_ag_trip)"
  fi
}

if [ "$GATE_LOADED" -eq 1 ]; then
  SENT='SEVERITY-RUBRIC|vault|C25|on'
  note "19) the gate fires on each INSUFFICIENT ground and on none of the SUFFICIENT ones ..."
  for g in no-attacker trusted-config alt-path dust-unquantified; do
    _assert_gate "insufficient '$g'" \
      "$(_cl "ins-$g" "$SENT" "DISMISS|Vault.sol:exitPool|$g|the ground text" "SAFE")" 1 yes
  done
  for g in guard unreachable no-loss known-issue immaterial-quantified; do
    _assert_gate "sufficient '$g'" \
      "$(_cl "suf-$g" "$SENT" "DISMISS|Vault.sol:exitPool|$g|Vault.sol:112 stops it" "SAFE")" 0 no
  done
  # Case-insensitivity: a model that shouts its ground id must not be punished for it.
  _assert_gate "sufficient 'GUARD' (upper case)" \
    "$(_cl "suf-upper" "$SENT" "DISMISS|Vault.sol:exitPool|GUARD|Vault.sol:112 stops it" "SAFE")" 0 no

  note "20) THE UNION RULE: three insufficient grounds on ONE location still leave it open ..."
  _assert_gate "three stacked insufficient grounds, one location" \
    "$(_cl "stack3" "$SENT" \
        "DISMISS|Vault.sol:exitPool|trusted-config|the owner configured it" \
        "DISMISS|Vault.sol:exitPool|no-attacker|nobody profits" \
        "DISMISS|Vault.sol:exitPool|alt-path|another exit still works" "SAFE")" 1 yes
  # ... while ONE sufficient ground on that same location closes it, however many weak ones surround it.
  _assert_gate "three insufficient + one sufficient, same location" \
    "$(_cl "stack3ok" "$SENT" \
        "DISMISS|Vault.sol:exitPool|trusted-config|the owner configured it" \
        "DISMISS|Vault.sol:exitPool|no-attacker|nobody profits" \
        "DISMISS|Vault.sol:exitPool|guard|Vault.sol:112 rejects the zero leg" "SAFE")" 0 no
  # Two DIFFERENT locations, one weak each: the gap counts LOCATIONS, not lines.
  _assert_gate "two distinct weak locations" \
    "$(_cl "twoloc" "$SENT" \
        "DISMISS|Vault.sol:exitPool|no-attacker|nobody profits" \
        "DISMISS|Pool.sol:joinPool|alt-path|another entry works" "SAFE")" 2 yes
  # A repeated identical dismissal cannot inflate the gap (sort -u on the record).
  _assert_gate "the same dismissal repeated three times" \
    "$(_cl "dupes" "$SENT" \
        "DISMISS|Vault.sol:exitPool|no-attacker|nobody profits" \
        "DISMISS|Vault.sol:exitPool|no-attacker|nobody profits" \
        "DISMISS|Vault.sol:exitPool|no-attacker|nobody profits" "SAFE")" 1 yes

  note "21) an unknown / malformed / missing ground counts as insufficient ..."
  _assert_gate "unrecognised ground id" \
    "$(_cl "unknown" "$SENT" "DISMISS|Vault.sol:exitPool|not-a-real-ground|whatever" "SAFE")" 1 yes
  _assert_gate "empty ground field" \
    "$(_cl "emptyg" "$SENT" "DISMISS|Vault.sol:exitPool||no ground at all" "SAFE")" 1 yes
  _assert_gate "malformed record (no ground field)" \
    "$(_cl "malformed" "$SENT" "DISMISS|Vault.sol:exitPool" "SAFE")" 1 yes
  # A DISMISS line with no LOCATION cannot be acted on and is not counted (nothing to re-ask or promote).
  _assert_gate "no location field" \
    "$(_cl "noloc" "$SENT" "DISMISS||no-attacker|nobody profits" "SAFE")" 0 no

  note "22) the gate is INERT without the sentinel, and never touches a cell that has a lead or never answered ..."
  _assert_gate "no SEVERITY-RUBRIC| sentinel (the knob-off shape)" \
    "$(_cl "nosent" "DISMISS|Vault.sol:exitPool|no-attacker|nobody profits" "SAFE")" 0 no
  CAND_LOG="$(_cl "withcand" "$SENT" \
      "DISMISS|Vault.sol:exitPool|no-attacker|nobody profits" \
      "CANDIDATE|Vault.sol:joinPool:31|C25|Medium|a real lead|a sketch")"
  if [ "$(_rubric_dismissal_gap "$CAND_LOG")" = "1" ] && ! _rubric_reask_needed "$CAND_LOG"; then
    ok "a cell that produced a CANDIDATE is never re-asked, yet its insufficient dismissal is still RECORDED (gap=1)"
  else
    bad "the candidate guard is wrong: gap=$(_rubric_dismissal_gap "$CAND_LOG"), re-ask needed=$(_rubric_reask_needed "$CAND_LOG" && echo yes || echo no)"
  fi
  NOVALID_LOG="$(_cl "novalid" "$SENT" "DISMISS|Vault.sol:exitPool|no-attacker|nobody profits" "SAFE")"
  : > "$NOVALID_LOG.novalid"
  if ! _rubric_reask_needed "$NOVALID_LOG"; then
    ok "a #1707 chrome-miss cell (.novalid) is never re-asked by this gate — it already owns its FAILED reason"
  else
    bad "the .novalid guard does not hold — the gate would spend a call on a cell that never answered"
  fi
  TIMEOUT_LOG="$(_cl "timeout" "$SENT" "DISMISS|Vault.sol:exitPool|no-attacker|nobody profits" "SAFE")"
  : > "$TIMEOUT_LOG.timeout"
  if ! _rubric_reask_needed "$TIMEOUT_LOG"; then
    ok "a #1955 timeout cell (.timeout) is never re-asked by this gate either"
  else
    bad "the .timeout guard does not hold"
  fi

  note "23) the re-ask NAMES the open locations and their grounds ..."
  OPEN_LOG="$(_cl "open" "$SENT" \
      "DISMISS|Vault.sol:exitPool|trusted-config|the owner configured it" \
      "DISMISS|Pool.sol:joinPool|no-attacker|nobody profits" "SAFE")"
  OPEN="$(_rubric_open_grounds "$OPEN_LOG")"
  # The order is the NORMALISED record order (_dismiss_lines applies `sort -u` so a repeated dismissal cannot
  # inflate the gap), which is deterministic but lexicographic — so this asserts CONTENT, not sequence.
  OPEN_OK=1
  case "$OPEN" in *'Vault.sol:exitPool (trusted-config)'*) ;; *) OPEN_OK=0 ;; esac
  case "$OPEN" in *'Pool.sol:joinPool (no-attacker)'*) ;; *) OPEN_OK=0 ;; esac
  case "$OPEN" in *', '*) ;; *) OPEN_OK=0 ;; esac
  if [ "$OPEN_OK" -eq 1 ]; then
    ok "the re-ask names both open locations with the ground each was dismissed on ($OPEN)"
  else
    bad "the re-ask addressing is wrong: '$OPEN'"
  fi
  if [ -z "$(_rubric_open_grounds "$(_cl "clean" "$SENT" "SAFE")")" ]; then
    ok "a cell with no insufficient dismissal produces an EMPTY re-ask address (so DISMISS_REASK_GROUNDS stays empty and the prompt is unchanged)"
  else
    bad "_rubric_open_grounds is non-empty for a clean cell — a first attempt could receive a re-ask block"
  fi

  note "24) PROMOTION: the surviving location becomes ONE tier-1 Medium candidate, with a resolvable location ..."
  PROM_LOG="$(_cl "promote" "$SENT" \
      "DISMISS|PlainCounter.sol:increment:42|no-attacker|the owner set the cap to zero so the documented increment path reverts" "SAFE")"
  _rubric_promote "$PROM_LOG" C25 "contracts/PlainCounter.sol
contracts/Other.sol"
  PROM_CANDS="$(_rubric_promoted_candidates "$PROM_LOG")"
  PROM_N="$(printf '%s\n' "$PROM_CANDS" | grep -c 'CANDIDATE|' || true)"
  if [ "$PROM_N" = "1" ]; then
    ok "exactly ONE candidate is synthesised per surviving location (promotion fires at most once per location)"
  else
    bad "promotion produced $PROM_N candidate line(s), want 1"
  fi
  case "$PROM_CANDS" in
    'CANDIDATE|contracts/PlainCounter.sol:increment|class=C25|Medium|'*)
      ok "the promoted record has the pinned shape: a resolved <path>:<function>, class=<cls>, severity Medium" ;;
    *) bad "the promoted record's shape is wrong: '$PROM_CANDS'" ;;
  esac
  # The severity FLOOR is Medium and nothing else: a promoted lead must never claim High.
  if printf '%s\n' "$PROM_CANDS" | grep -q '|High|'; then
    bad "a promoted candidate claims High — the promotion is capped at Medium by design"
  else
    ok "no promoted candidate claims High (the cap is part of the precision argument)"
  fi
  # The provenance line rides with it, and is NOT a candidate.
  if grep -q '^RUBRIC-PROMOTED|contracts/PlainCounter.sol:increment|no-attacker$' "$PROM_LOG.rubric-promoted" \
     && [ "$(_rubric_promoted_count "$PROM_LOG")" = "1" ]; then
    ok "each promotion carries a RUBRIC-PROMOTED|<loc>|<ground> provenance line, and the counter reads 1"
  else
    bad "the promotion provenance line or its counter is wrong"
  fi
  # _cell_candidates unions the promoted record with the model-emitted ones at both scrape sites.
  if [ "$(_cell_candidates "$PROM_LOG" | grep -c 'CANDIDATE|' || true)" = "1" ]; then
    ok "_cell_candidates surfaces the promoted record (this is how it reaches \$REPORT, candidates[], the depth plan and the refute gate)"
  else
    bad "_cell_candidates does not surface the promoted record — the promotion would never leave the sidecar"
  fi

  note "25) an UNRESOLVABLE location is DROPPED, never guessed — but the gap is still recorded ..."
  DROP_LOG="$(_cl "drop" "$SENT" \
      "DISMISS|NotInThisZone.sol:mystery|no-attacker|nobody profits" "SAFE")"
  _rubric_promote "$DROP_LOG" C25 "contracts/PlainCounter.sol"
  if [ ! -s "$DROP_LOG.rubric-promoted" ] && [ "$(_rubric_dismissal_gap "$DROP_LOG")" = "1" ] \
     && [ "$(_rubric_promoted_count "$DROP_LOG")" = "0" ]; then
    ok "a location outside this cell's own file list promotes NOTHING (no guessed path), while insufficient_dismissals still records it"
  else
    bad "the unresolvable-location case is wrong: sidecar=$( [ -s "$DROP_LOG.rubric-promoted" ] && echo present || echo absent ), gap=$(_rubric_dismissal_gap "$DROP_LOG"), promoted=$(_rubric_promoted_count "$DROP_LOG")"
  fi
  # A location with no function half cannot be pair-credited, so it is dropped too (the _tier2_emit_loc pin).
  BARE_LOG="$(_cl "bare" "$SENT" "DISMISS|contracts/PlainCounter.sol|no-attacker|nobody profits" "SAFE")"
  _rubric_promote "$BARE_LOG" C25 "contracts/PlainCounter.sol"
  if [ ! -s "$BARE_LOG.rubric-promoted" ]; then
    ok "a file-only location (no function) promotes nothing — the shipped _tier2_emit_loc shape gate is what decides, not a new one"
  else
    bad "a file-only location was promoted — its record could not be pair-credited and would pollute the candidate set"
  fi
  # A `|` inside the model's evidence must not add a field to the synthesised record.
  PIPE_LOG="$(_cl "pipe" "$SENT" \
      "DISMISS|PlainCounter.sol:increment|no-attacker|the cap is zero so increment reverts" "SAFE")"
  _rubric_promote "$PIPE_LOG" C25 "contracts/PlainCounter.sol"
  PIPE_FIELDS="$(_rubric_promoted_candidates "$PIPE_LOG" | head -1 | awk -F'|' '{print NF}')"
  if [ "$PIPE_FIELDS" = "6" ]; then
    ok "the synthesised candidate has exactly the 6 fields every downstream reader splits on"
  else
    bad "the synthesised candidate has $PIPE_FIELDS fields, want 6"
  fi

  # --- #2245 iteration 3: the PER-GROUND EVIDENCE CONTRACT, one fixture pair per branch ---------------------
  # A tiny synthetic tree with KNOWN line numbers is the resolution root: the decider reads the cited range, so
  # a fixture that did not really contain the text would prove nothing about the check.
  CREPO="$WORK/contract-repo"; mkdir -p "$CREPO/src" "$CREPO/script"
  {
    printf 'pragma solidity ^0.8.20;\n'                       # 1
    printf 'contract Guarded {\n'                             # 2
    printf '    uint256 public cap;\n'                        # 3
    printf '    function setCap(uint256 c) external {\n'       # 4
    printf '        require(c > 0, "zero cap");\n'             # 5
    printf '        cap = c;\n'                                # 6
    printf '    }\n'                                           # 7
    printf '    uint256 public total;\n'                       # 8
  } > "$CREPO/src/Guarded.sol"
  printf 'guarded.setCap(100);\n' > "$CREPO/script/Deploy.s.sol"
  printf 'Known issues to exclude: "the fee split rounds down by one wei" is accepted by design.\n' \
    > "$WORK/contract-brief.md"
  CBRIEF="$WORK/contract-brief.md"

  # _contract_case <label> <expected: PASS|<contract-id>> <dismiss-line>
  _contract_case() {
    _cc_label="$1"; _cc_want="$2"; _cc_line="$3"
    if _cc_got="$(_dismiss_evidence_ok "$_cc_line" "$CREPO" "$CBRIEF")"; then _cc_got=PASS; fi
    if [ "$_cc_got" = "$_cc_want" ]; then
      ok "contract '$_cc_label' -> $_cc_got (as specified)"
    else
      bad "contract '$_cc_label' -> ${_cc_got:-<empty>} (want $_cc_want)"
    fi
  }

  note "25.1) guard: an existing line that IS a check passes; a fabricated path and a non-check line do not ..."
  _contract_case "guard, cited require"      PASS             'DISMISS|Guarded.sol:setCap|guard|src/Guarded.sol:5 rejects the zero value outright'
  _contract_case "guard, path not in tree"   cite-unresolved  'DISMISS|Guarded.sol:setCap|guard|src/NotHere.sol:5 rejects it outright'
  _contract_case "guard, line is not a check" cite-not-a-guard 'DISMISS|Guarded.sol:setCap|guard|src/Guarded.sol:8 shows the accounting'
  _contract_case "guard, no citation at all" cite-missing     'DISMISS|Guarded.sol:setCap|guard|the owner-only modifier stops it'

  note "25.2) unreachable: a validating setter line passes; a deployment script never does ..."
  _contract_case "unreachable, setter require" PASS                'DISMISS|Guarded.sol:setCap|unreachable|src/Guarded.sol:4-5 validates the state away'
  _contract_case "unreachable, deploy script"  cite-not-validating 'DISMISS|Guarded.sol:setCap|unreachable|script/Deploy.s.sol:1 sets it to a safe value'
  _contract_case "unreachable, non-validating line" cite-not-validating 'DISMISS|Guarded.sol:setCap|unreachable|src/Guarded.sol:8 shows the total'
  # This is DELIBERATELY the inverse of the #2225 configuration rule, which REQUIRES a deploy/test citation.
  if _shfn "$DISCOVERY" _uncited_dismissal_lines | grep -q 'test|tests|script|scripts|deploy|docs'; then
    ok "the #2225 rule (a configuration dismissal must cite what the repo SHIPS) is untouched — the two rules ask opposite questions on purpose"
  else
    bad "the #2225 configuration-citation rule changed — this iteration must not touch it"
  fi

  note "25.3) no-loss: a zero delta beside a path passes; a reachability argument and a missing delta do not ..."
  _contract_case "no-loss, delta + path"     PASS                    'DISMISS|Guarded.sol:setCap|no-loss|src/Guarded.sol:6 delta=0:the recorded total'
  _contract_case "no-loss, measured reachability wording" reachability-as-no-loss \
    'DISMISS|Guarded.sol:setCap|no-loss|the percentage never sets the units, so that state does not occur; src/Guarded.sol:6 delta=0:the recorded total'
  _contract_case "no-loss, no zero delta"    no-zero-delta           'DISMISS|Guarded.sol:setCap|no-loss|nothing is lost and nobody waits, see src/Guarded.sol:6'
  _contract_case "no-loss, delta but no path" cite-missing           'DISMISS|Guarded.sol:setCap|no-loss|delta=0:the recorded total'

  note "25.4) ADMITTED IS NOT DEPLOYED: deployed-state evidence closes nothing without a validating citation ..."
  _contract_case "no-loss resting on a deployed read" admitted-vs-deployed \
    'DISMISS|Guarded.sol:setCap|no-loss|ONCHAIN @block 1234 every shipped market pairs correctly, delta=0:the recorded total in src/Guarded.sol:6'
  _contract_case "the same plus a validating citation" PASS \
    'DISMISS|Guarded.sol:setCap|no-loss|ONCHAIN @block 1234 as deployed, and src/Guarded.sol:5 rejects every other admitted value, delta=0:the recorded total'
  _contract_case "a deployed read whose only citation is the deploy script" admitted-vs-deployed \
    'DISMISS|Guarded.sol:setCap|no-loss|as deployed, script/Deploy.s.sol:1 sets it, delta=0:the recorded total'

  note "25.5) immaterial-quantified: a loss amount with a bound passes; a bare ratio does not ..."
  _contract_case "loss + bound"        PASS          'DISMISS|Guarded.sol:setCap|immaterial-quantified|loss=3 units out of 1000000 units minted'
  _contract_case "a ratio of counters" unquantified  'DISMISS|Guarded.sol:setCap|immaterial-quantified|a vanishing fraction of the recorded counters'
  _contract_case "an amount with no bound" unquantified 'DISMISS|Guarded.sol:setCap|immaterial-quantified|loss=3 units, which is negligible'

  note "25.6) known-issue: a quoted line that is in the brief passes; one that is not does not ..."
  _contract_case "quotes a brief line"      PASS            'DISMISS|Guarded.sol:setCap|known-issue|the brief lists "the fee split rounds down by one wei"'
  _contract_case "quotes something else"    cite-unresolved 'DISMISS|Guarded.sol:setCap|known-issue|the brief lists "an entirely different accepted behaviour"'
  _contract_case "no quoted fragment"       cite-missing    'DISMISS|Guarded.sol:setCap|known-issue|the brief already lists it'

  note "25.7) an INSUFFICIENT ground id is not this decider's business, and an empty root is shape-only ..."
  _contract_case "an insufficient id passes the contract (the id check already rejected it)" PASS \
    'DISMISS|Guarded.sol:setCap|no-attacker|nobody profits'
  if _so_got="$(_dismiss_evidence_ok 'DISMISS|Guarded.sol:setCap|guard|src/Unknowable.sol:5 rejects it' "" "")"; then _so_got=PASS; fi
  if [ "$_so_got" = PASS ]; then
    ok "with no resolution root the check is citation-SHAPE only — documented behaviour, exactly like _uncited_dismissal_lines's empty repo_dir, never a false failure"
  else
    bad "the shape-only degradation is broken (got '$_so_got') — a run with a non-repo code dir would fail every citation"
  fi

  note "25.8) THE TAINT RULE: a contract-failing line keeps its location open even beside a passing sibling ..."
  CSENT="$SENT
GROUND-EVIDENCE|vault|C25|on"
  TAINT_LOG="$(_cl "taint" "$CSENT" \
      "DISMISS|Guarded.sol:accrue|no-loss|the emission is absorbed by the next depositor, see src/Guarded.sol:6" \
      "DISMISS|Guarded.sol:accrue|immaterial-quantified|loss=2 units out of 1000000 units minted" "SAFE")"
  TAINT_GAP="$(_rubric_dismissal_gap "$TAINT_LOG" "$CREPO" "$CBRIEF")"
  TAINT_ROWS="$(_dismiss_contract_rows "$TAINT_LOG" "$CREPO" "$CBRIEF")"
  if [ "$TAINT_GAP" = "1" ] && [ "$(printf '%s\n' "$TAINT_ROWS" | awk -F'\t' 'NR==1{print $3}')" = "no-zero-delta" ]; then
    ok "the location stays OPEN on the failing no-loss line although its immaterial-quantified sibling PASSES the form check (the one recall-for-precision trade of this iteration)"
  else
    bad "the taint rule does not hold (gap=$TAINT_GAP rows='$TAINT_ROWS')"
  fi
  # ... and the RE-ASK names the ground AND what is missing from it, from the single shell table.
  TAINT_OPEN="$(_rubric_open_grounds "$TAINT_LOG" "$CREPO" "$CBRIEF")"
  case "$TAINT_OPEN" in
    *'Guarded.sol:accrue (no-loss: write the literal token delta=0:'*)
      ok "the re-ask names '<location> (<ground>: <requirement>)' with the phrase from _contract_requirement" ;;
    *) bad "the contract re-ask addressing is wrong: '$TAINT_OPEN'" ;;
  esac
  # NEGATIVE CONTROL: the same location with only the PASSING sibling is CLOSED.
  PASSONLY_LOG="$(_cl "passonly" "$CSENT" \
      "DISMISS|Guarded.sol:accrue|immaterial-quantified|loss=2 units out of 1000000 units minted" "SAFE")"
  if [ "$(_rubric_dismissal_gap "$PASSONLY_LOG" "$CREPO" "$CBRIEF")" = "0" ] \
     && [ "$(_contract_failed_dismissals "$PASSONLY_LOG" "$CREPO" "$CBRIEF")" = "0" ]; then
    ok "a dismissal whose sufficient ground MEETS its contract still closes its location, and counts no contract failure (negative control)"
  else
    bad "a contract-passing dismissal no longer closes its location — the gate would re-ask everything"
  fi

  note "25.9) INERTNESS: without the GROUND-EVIDENCE| sentinel the same logs decide exactly as iteration 2 ..."
  IT2_LOG="$(_cl "taint-it2" "$SENT" \
      "DISMISS|Guarded.sol:accrue|no-loss|the emission is absorbed by the next depositor, see src/Guarded.sol:6" \
      "DISMISS|Guarded.sol:accrue|immaterial-quantified|loss=2 units out of 1000000 units minted" "SAFE")"
  if [ "$(_rubric_dismissal_gap "$IT2_LOG" "$CREPO" "$CBRIEF")" = "0" ] \
     && [ -z "$(_dismiss_contract_rows "$IT2_LOG" "$CREPO" "$CBRIEF")" ] \
     && ! _rubric_reask_needed "$IT2_LOG" "$CREPO" "$CBRIEF"; then
    ok "no GROUND-EVIDENCE| sentinel => no contract check anywhere => the sufficient ground closes the location, exactly as the measured iteration-2 arm decided it"
  else
    bad "the contract layer is NOT inert without its sentinel — the iteration-2 arm would not be reproducible"
  fi
  NOSENT_LOG="$(_cl "ge-nosent" "GROUND-EVIDENCE|vault|C25|on" \
      "DISMISS|Guarded.sol:accrue|no-loss|the emission is absorbed by the next depositor" "SAFE")"
  if [ "$(_rubric_dismissal_gap "$NOSENT_LOG" "$CREPO" "$CBRIEF")" = "0" ]; then
    ok "the contract sentinel ALONE (no SEVERITY-RUBRIC| line) decides nothing either — the rubric gate is still the outer gate"
  else
    bad "a log with only the contract sentinel produced a shortfall — the two gates are not nested"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# PART 7 — THE HUNT GATE END-TO-END through run-discovery.sh (offline --agentis stub, no LLM)
# ----------------------------------------------------------------------------------------------------------
# The stub replaces the SUBSTRATE, so this part tests the DRIVER half: the gate, the re-ask, the promotion, the
# JSON and the report. The AGENT half (passthrough -> getenv -> honesty-gated sentinel) is covered by the source
# guards above and, when an agentis binary exists, by part 10. The stub prints the sentinel itself, exactly as
# demo-discovery-parallel.sh's stub prints REFUTE-CONSTRAINTS|/DEPTH-CELL|.
HSTUB="$WORK/agentis-hunt-stub"
cat > "$HSTUB" <<'STUBEOF'
#!/bin/sh
set -u
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    if [ "${SEVERITY_RUBRIC:-}" = "1" ]; then
      printf 'SEVERITY-RUBRIC|%s|%s|on\n' "${SUBSYSTEM:-}" "${HUNT_CLASS:-}"
    fi
    if [ "${GROUND_EVIDENCE:-}" = "1" ]; then
      printf 'GROUND-EVIDENCE|%s|%s|on\n' "${SUBSYSTEM:-}" "${HUNT_CLASS:-}"
    fi
    if [ -n "${DISMISS_REASK_GROUNDS:-}" ]; then
      # The RE-ASK turn. Record what the driver named, so the caller can assert the addressing reached the cell.
      [ -n "${STUB_REASK_LOG:-}" ] && printf '%s\n' "$DISMISS_REASK_GROUNDS" >> "$STUB_REASK_LOG"
      # The re-ask keeps the SAME location the first turn named (STUB_LOC), so the "unresolvable location"
      # arm stays unresolvable across both turns instead of silently becoming promotable.
      case "${STUB_REASK:-hold}" in
        comply)  printf 'DISMISS|%s|guard|PlainCounter.sol:12 rejects it outright\n' "${STUB_LOC:-PlainCounter.sol:increment}" ;;
        holdcontract) printf 'DISMISS|%s|no-loss|nothing is lost and nobody waits on the documented path\n' "${STUB_LOC:-PlainCounter.sol:increment}" ;;
        candidate) printf 'CANDIDATE|PlainCounter.sol:increment:12|%s|Medium|the documented path reverts under an admitted cap|set the cap to zero and assert the revert\n' "${HUNT_CLASS:-}"; printf 'SAFE\n'; exit 0 ;;
        *)       printf 'DISMISS|%s|no-attacker|nobody profits from the reverted call\n' "${STUB_LOC:-PlainCounter.sol:increment}" ;;
      esac
      printf 'SAFE\n'
      exit 0
    fi
    case "${STUB_MODE:-insufficient}" in
      sufficient) printf 'DISMISS|PlainCounter.sol:increment|guard|PlainCounter.sol:12 rejects it outright\n' ;;
      unresolvable) printf 'DISMISS|Elsewhere.sol:mystery|no-attacker|nobody profits from the reverted call\n' ;;
      contractfail) printf 'DISMISS|PlainCounter.sol:increment|no-loss|nothing is lost and nobody waits on the documented path\n' ;;
      contractpass) printf 'DISMISS|PlainCounter.sol:increment|no-loss|contracts/PlainCounter.sol:12 delta=0:the recorded count\n' ;;
      nodismiss) : ;;
      *) printf 'DISMISS|PlainCounter.sol:increment|no-attacker|nobody profits from the reverted call\n' ;;
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
  cp "$FIXSOL" "$_h_repo/contracts/PlainCounter.sol"
  printf 'counter | C25 | contracts/PlainCounter.sol\n' > "$WORK/$_h_label-scope.tsv"
  printf '# brief\nInvariants to break: the documented paths stay available.\nKnown issues to exclude: none.\n' \
    > "$WORK/$_h_label-brief.md"
  "$DISCOVERY" --repo "$_h_repo" --scope "$WORK/$_h_label-scope.tsv" --brief "$WORK/$_h_label-brief.md" \
    --only counter --classes C25 --backend mock --agentis "$HSTUB" --out "$WORK/$_h_label" \
    > "$WORK/$_h_label.out" 2>&1 || true
  printf '%s\n' "$WORK/$_h_label"
}
HCELL=run/hunt_counter_C25.log

note "26) end-to-end: an insufficient dismissal is re-asked once and then PROMOTED ..."
STUB_REASK_LOG="$WORK/reask-addr.txt"; export STUB_REASK_LOG
SEVERITY_RUBRIC=1 STUB_MODE=insufficient STUB_REASK=hold _hunt prom > "$WORK/prom.dir"
PDIR="$(cat "$WORK/prom.dir")"
if [ -f "$PDIR/$HCELL.rubric-attempt-1" ] && [ -s "$PDIR/$HCELL.rubric-promoted" ]; then
  ok "the driver re-asked once (superseded attempt kept as .rubric-attempt-1) and then promoted the surviving lead"
else
  bad "the end-to-end re-ask/promotion did not happen (attempt-1=$( [ -f "$PDIR/$HCELL.rubric-attempt-1" ] && echo yes || echo no ), sidecar=$( [ -s "$PDIR/$HCELL.rubric-promoted" ] && echo yes || echo no ))"
  tail -12 "$WORK/prom.out" | sed 's/^/      /' >&2
fi
if grep -q 'PlainCounter.sol:increment (no-attacker)' "$WORK/reask-addr.txt" 2>/dev/null; then
  ok "DISMISS_REASK_GROUNDS reached the cell naming the open location and its ground"
else
  bad "the re-ask addressing never reached the cell — DISMISS_REASK_GROUNDS was empty or unexported"
fi
if [ "$(find "$PDIR/run" -name 'hunt_*.log' | wc -l | tr -d ' ')" = "1" ]; then
  ok "exactly ONE hunt_*.log exists for the cell (the attempt + promotion suffixes are invisible to every readout)"
else
  bad "the cell produced $(find "$PDIR/run" -name 'hunt_*.log' | wc -l | tr -d ' ') hunt_*.log files — a readout would double-count the cell"
fi
if grep -q 'Medium' "$PDIR/discovery-report.md" && grep -q 'increment' "$PDIR/discovery-report.md"; then
  ok "the promoted lead reached discovery-report.md as a normal Medium candidate row"
else
  bad "the promoted lead never reached discovery-report.md"
fi
PJSON="$PDIR/discovery-results.json"
KEY_MISS=""
for k in '"dismissals":1' '"insufficient_dismissals":1' '"rubric_promoted":1'; do
  grep -q "$k" "$PJSON" || KEY_MISS="$KEY_MISS $k"
done
if [ -z "$KEY_MISS" ]; then
  ok "all three additive per-cell keys are present and correct (dismissals / insufficient_dismissals / rubric_promoted)"
else
  bad "an additive per-cell key is missing or wrong:$KEY_MISS"
fi
if grep -q '"candidates":\[""*CANDIDATE\|"candidates":\[".*increment' "$PJSON"; then
  ok "the promoted record is inside the cell's candidates[] — it reaches STAGE 4 and the refute gate like a model-emitted one"
else
  bad "the promoted record is not in candidates[] — it could never reach the refute gate"
fi

note "27) end-to-end: a re-ask that names a SUFFICIENT ground closes the gate with no promotion ..."
SEVERITY_RUBRIC=1 STUB_MODE=insufficient STUB_REASK=comply _hunt comply > "$WORK/comply.dir"
CDIR="$(cat "$WORK/comply.dir")"
if [ -f "$CDIR/$HCELL.rubric-attempt-1" ] && [ ! -s "$CDIR/$HCELL.rubric-promoted" ]; then
  ok "the re-ask happened and the sufficient ground closed the gate — nothing was promoted"
else
  bad "a complying re-ask still promoted (or was never re-asked)"
fi
if ! grep -q 'rubric_promoted' "$CDIR/discovery-results.json" && ! grep -q 'insufficient_dismissals' "$CDIR/discovery-results.json" \
   && grep -q '"dismissals":1' "$CDIR/discovery-results.json"; then
  ok "the JSON records the dismissal DOSAGE but neither an insufficient nor a promoted one (keys are emitted only when non-zero)"
else
  bad "the complying cell's JSON keys are wrong"
fi

note "28) end-to-end: a FIRST dismissal on a sufficient ground is never re-asked at all ..."
SEVERITY_RUBRIC=1 STUB_MODE=sufficient _hunt suff > "$WORK/suff.dir"
SDIR="$(cat "$WORK/suff.dir")"
if [ ! -f "$SDIR/$HCELL.rubric-attempt-1" ] && [ ! -s "$SDIR/$HCELL.rubric-promoted" ]; then
  ok "no re-ask, no promotion — the gate spends nothing on a cell that justified its dismissal the first time"
else
  bad "a sufficient first ground still triggered a re-ask or a promotion"
fi

note "29) end-to-end: an unresolvable dismissal location is recorded but never promoted ..."
SEVERITY_RUBRIC=1 STUB_MODE=unresolvable STUB_REASK=hold STUB_LOC=Elsewhere.sol:mystery _hunt unres > "$WORK/unres.dir"
UDIR="$(cat "$WORK/unres.dir")"
if [ ! -s "$UDIR/$HCELL.rubric-promoted" ] && grep -q '"insufficient_dismissals":1' "$UDIR/discovery-results.json"; then
  ok "the gap is on the record and nothing was promoted from a location outside the cell's file list"
else
  bad "the unresolvable end-to-end case is wrong"
fi

note "30) DEFAULT OFF: with the knob unset the driver behaviour is byte-identical ..."
STUB_MODE=insufficient _hunt off > "$WORK/off.dir"
ODIR="$(cat "$WORK/off.dir")"
OFF_OK=1
[ -f "$ODIR/$HCELL.rubric-attempt-1" ] && OFF_OK=0
[ -e "$ODIR/$HCELL.rubric-promoted" ] && OFF_OK=0
grep -q 'insufficient_dismissals\|rubric_promoted' "$ODIR/discovery-results.json" && OFF_OK=0
grep -q 'SEVERITY-RUBRIC|' "$ODIR/$HCELL" && OFF_OK=0
if [ "$OFF_OK" -eq 1 ]; then
  ok "knob unset: no sentinel, no re-ask, no promotion, and none of the three new JSON keys — the gate is inert by construction"
else
  bad "the knob-OFF run is NOT inert (attempt/sidecar/JSON key/sentinel present)"
fi
# The INERTNESS CONTROL that matters: even a cell that emits DISMISS lines is untouched without the sentinel,
# because the gate reads the honesty-gated sentinel and not the env var.
if [ "$(_rubric_dismissal_gap "$ODIR/$HCELL" 2>/dev/null || echo 0)" = "0" ]; then
  ok "the gate reads the SENTINEL, not the env: a DISMISS-bearing log with no sentinel has gap 0 (negative control)"
else
  bad "the gate counted a shortfall on a log with no sentinel — it is keyed on the wrong signal"
fi

note "30.1) end-to-end: a SUFFICIENT ground whose EVIDENCE fails its contract is re-asked and then PROMOTED ..."
STUB_REASK_LOG="$WORK/ge-reask-addr.txt"; export STUB_REASK_LOG
SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 STUB_MODE=contractfail STUB_REASK=holdcontract _hunt gefail > "$WORK/gefail.dir"
GFDIR="$(cat "$WORK/gefail.dir")"
if [ -f "$GFDIR/$HCELL.rubric-attempt-1" ] && [ -s "$GFDIR/$HCELL.rubric-promoted" ]; then
  ok "a dismissal the ID check ACCEPTS (no-loss is on the sufficient list) but the CONTRACT rejects is re-asked once and, when it holds, promoted — the same path, no second mechanism"
else
  bad "the contract end-to-end re-ask/promotion did not happen (attempt-1=$( [ -f "$GFDIR/$HCELL.rubric-attempt-1" ] && echo yes || echo no ), sidecar=$( [ -s "$GFDIR/$HCELL.rubric-promoted" ] && echo yes || echo no ))"
  tail -12 "$WORK/gefail.out" | sed 's/^/      /' >&2
fi
if grep -q 'no-loss: write the literal token delta=0:' "$WORK/ge-reask-addr.txt" 2>/dev/null; then
  ok "the re-ask reached the cell naming the ground AND what its contract is missing"
else
  bad "the contract re-ask addressing never reached the cell: '$(cat "$WORK/ge-reask-addr.txt" 2>/dev/null)'"
fi
GFJSON="$GFDIR/discovery-results.json"
GF_MISS=""
for k in '"insufficient_dismissals":1' '"rubric_promoted":1' '"contract_failed_dismissals":1'; do
  grep -q "$k" "$GFJSON" || GF_MISS="$GF_MISS $k"
done
if [ -z "$GF_MISS" ]; then
  ok "the cell JSON carries the new additive key beside the iteration-2 ones (contract_failed_dismissals — the arm's anti-Goodhart readout)"
else
  bad "an additive per-cell key is missing or wrong:$GF_MISS"
fi

note "30.2) CONTROL: the same ground with contract-MEETING evidence is never re-asked ..."
SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 STUB_MODE=contractpass _hunt gepass > "$WORK/gepass.dir"
GPDIR="$(cat "$WORK/gepass.dir")"
if [ ! -f "$GPDIR/$HCELL.rubric-attempt-1" ] && [ ! -s "$GPDIR/$HCELL.rubric-promoted" ] \
   && ! grep -q 'contract_failed_dismissals\|insufficient_dismissals' "$GPDIR/discovery-results.json"; then
  ok "a zero delta beside a path closes the location: no re-ask, no promotion, no contract key (the contract is a floor on FORM — it costs nothing when the form is met)"
else
  bad "a contract-PASSING dismissal still triggered the gate"
fi

note "30.3) ITERATION-2 REPRODUCTION: SEVERITY_RUBRIC=1 ALONE leaves the contract-failing cell untouched ..."
SEVERITY_RUBRIC=1 STUB_MODE=contractfail STUB_REASK=holdcontract _hunt ge-it2 > "$WORK/ge-it2.dir"
GIDIR="$(cat "$WORK/ge-it2.dir")"
GI_OK=1
grep -q 'GROUND-EVIDENCE|' "$GIDIR/$HCELL" && GI_OK=0
[ -f "$GIDIR/$HCELL.rubric-attempt-1" ] && GI_OK=0
[ -e "$GIDIR/$HCELL.rubric-promoted" ] && GI_OK=0
grep -q 'contract_failed_dismissals\|insufficient_dismissals\|rubric_promoted' "$GIDIR/discovery-results.json" && GI_OK=0
grep -q 'SEVERITY-RUBRIC|' "$GIDIR/$HCELL" || GI_OK=0
if [ "$GI_OK" -eq 1 ]; then
  ok "the rubric sentinel fires and the contract one does not: the very dismissal iteration 3 catches is closed on its ground id, exactly as the measured iteration-2 arm closed it (the arm stays reproducible)"
else
  bad "SEVERITY_RUBRIC=1 alone did NOT reproduce the iteration-2 behaviour — the two arms would not be comparable"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 8 — THE REFUTE GATE END-TO-END through run-refute.sh (offline --agentis stub, no LLM)
# ----------------------------------------------------------------------------------------------------------
RSTUB="$WORK/agentis-refute-stub"
cat > "$RSTUB" <<'STUBEOF'
#!/bin/sh
set -u
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    fn="${CAND_FILE_FN:-}"; cls="${CAND_CLASS:-}"
    if [ "${SEVERITY_RUBRIC:-}" = "1" ]; then printf 'SEVERITY-RUBRIC|refute|on\n'; fi
    if [ "${GROUND_EVIDENCE:-}" = "1" ]; then printf 'GROUND-EVIDENCE|refute|on\n'; fi
    if [ -n "${RUBRIC_REASK_GROUNDS:-}" ]; then
      [ -n "${STUB_REASK_LOG:-}" ] && printf '%s\n' "$RUBRIC_REASK_GROUNDS" >> "$STUB_REASK_LOG"
      case "${STUB_REASK:-hold}" in
        noground)
          printf 'VERDICT|REFUTED|%s|%s|owner-only intentional guard, nobody profits\n' "$fn" "$cls" ;;
        real)
          printf 'VERDICT|REAL|%s|%s|the admitted configuration makes the documented path unavailable\n' "$fn" "$cls" ;;
        comply)
          printf 'REFUTE-GROUND|guard|Pool.sol:31 rejects the state outright\n'
          printf 'CONSTRAINT|%s|a claim must name the state the code admits\n' "$cls"
          printf 'VERDICT|REFUTED|%s|%s|the guard at Pool.sol:31 stops it\n' "$fn" "$cls" ;;
        holdcontract)
          printf 'REFUTE-GROUND|no-loss|the allocation never empties the pool, so that state does not occur; pool.sol:1 delta=0:the pool units\n'
          printf 'CONSTRAINT|%s|a claim must name the state the code admits\n' "$cls"
          printf 'VERDICT|REFUTED|%s|%s|with the pool populated the documented call succeeds\n' "$fn" "$cls" ;;
        *)
          printf 'REFUTE-GROUND|no-attacker|no unprivileged caller gains anything\n'
          printf 'CONSTRAINT|%s|a claim must name the unprivileged trigger\n' "$cls"
          printf 'VERDICT|REFUTED|%s|%s|owner-only intentional guard, nobody profits\n' "$fn" "$cls" ;;
      esac
      exit 0
    fi
    case "${STUB_MODE:-insufficient}" in
      sufficient)
        printf 'REFUTE-GROUND|guard|Pool.sol:31 rejects the state outright\n'
        printf 'VERDICT|REFUTED|%s|%s|the guard at Pool.sol:31 stops it\n' "$fn" "$cls" ;;
      noground)
        printf 'VERDICT|REFUTED|%s|%s|owner-only intentional guard, nobody profits\n' "$fn" "$cls" ;;
      wrapped)
        printf 'REFUTE-GROUND|no-attacker|no unprivileged caller gains anything and the\n'
        printf '    alternative exit remains open for everyone\n'
        printf 'CONSTRAINT|%s|a claim must name the unprivileged trigger\n' "$cls"
        printf 'VERDICT|REFUTED|%s|%s|owner-only intentional guard, nobody profits\n' "$fn" "$cls" ;;
      real)
        printf 'VERDICT|REAL|%s|%s|no guard stops the unprivileged caller\n' "$fn" "$cls" ;;
      contractfail)
        printf 'REFUTE-GROUND|no-loss|the allocation never empties the pool, so that state does not occur; pool.sol:1 delta=0:the pool units\n'
        printf 'CONSTRAINT|%s|a claim must name the state the code admits\n' "$cls"
        printf 'VERDICT|REFUTED|%s|%s|with the pool populated the documented call succeeds\n' "$fn" "$cls" ;;
      contractpass)
        printf 'REFUTE-GROUND|no-loss|pool.sol:1 delta=0:the pool units, which the documented call leaves untouched\n'
        printf 'CONSTRAINT|%s|a claim must name the state the code admits\n' "$cls"
        printf 'VERDICT|REFUTED|%s|%s|the documented call leaves the accounting untouched\n' "$fn" "$cls" ;;
      *)
        printf 'REFUTE-GROUND|no-attacker|no unprivileged caller gains anything\n'
        printf 'CONSTRAINT|%s|a claim must name the unprivileged trigger\n' "$cls"
        printf 'VERDICT|REFUTED|%s|%s|owner-only intentional guard, nobody profits\n' "$fn" "$cls" ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$RSTUB"

RCODE="$WORK/refute-code"; mkdir -p "$RCODE"
# Deliberately NOT a value-moving function with a deduction idiom: that would arm the #1699 C6 fallback and
# confound every assertion below with a second extra call.
printf 'contract Pool { function exitPool() external {} }\n' > "$RCODE/pool.sol"
printf 'Pool.sol:exitPool | C25 | Medium | the documented exit reverts on a zero-weight leg | pool.sol\n' > "$WORK/rcands.tsv"

# _refute <label> — one offline refute run; prints the out dir.
_refute() {
  _r_label="$1"
  "$REFUTE" --candidates "$WORK/rcands.tsv" --code-dir "$RCODE" --backend mock --agentis "$RSTUB" \
    --out "$WORK/$_r_label" > "$WORK/$_r_label.rout" 2>&1 || true
  printf '%s\n' "$WORK/$_r_label"
}
_verdict_of() { awk -F'|' 'NF>=5 { v=$4; gsub(/[[:space:]]/,"",v); if (v=="REAL"||v=="REFUTED"||v=="ERROR") { print v; exit } }' "$1/refute-report.md"; }
_reason_of()  { awk -F'|' 'NF>=5 { v=$4; gsub(/[[:space:]]/,"",v); if (v=="REAL"||v=="REFUTED"||v=="ERROR") { r=$5; sub(/^[[:space:]]+/,"",r); print r; exit } }' "$1/refute-report.md"; }

note "31) end-to-end: a REFUTED verdict on a SUFFICIENT ground is not re-asked ..."
SEVERITY_RUBRIC=1 STUB_MODE=sufficient _refute r-suff > "$WORK/r-suff.dir"
RS="$(cat "$WORK/r-suff.dir")"
if [ ! -f "$RS/run/refute_Pool_sol_exitPool_rubric1.log" ] && [ ! -e "$RS/rubric-dismissals.tsv" ] \
   && [ "$(_verdict_of "$RS")" = "REFUTED" ]; then
  ok "a justified refutation costs no extra call, creates no sidecar and keeps its verdict"
else
  bad "the sufficient-ground refute case is wrong (verdict=$(_verdict_of "$RS"))"
  tail -8 "$WORK/r-suff.rout" | sed 's/^/      /' >&2
fi

note "32) end-to-end: an INSUFFICIENT ground is re-asked once and can recover to REAL ..."
STUB_REASK_LOG="$WORK/r-reask-addr.txt"; export STUB_REASK_LOG
SEVERITY_RUBRIC=1 STUB_MODE=insufficient STUB_REASK=real _refute r-real > "$WORK/r-real.dir"
RR="$(cat "$WORK/r-real.dir")"
if [ "$(_verdict_of "$RR")" = "REAL" ]; then
  ok "the rubric re-ask converted the verdict to REAL — the gate's OWN second judgement, no mechanical flip"
else
  bad "the rubric re-ask did not recover the candidate (verdict=$(_verdict_of "$RR"))"
  tail -10 "$WORK/r-real.rout" | sed 's/^/      /' >&2
fi
case "$(_reason_of "$RR")" in
  'recovered under the severity rubric'*) ok "the report reason records that the FIRST read refuted on an insufficient ground" ;;
  *) bad "the recovered reason is not attributed: '$(_reason_of "$RR")'" ;;
esac
if grep -q 'no-attacker' "$WORK/r-reask-addr.txt" 2>/dev/null; then
  ok "RUBRIC_REASK_GROUNDS reached the refuter naming the insufficient ground"
else
  bad "the refute re-ask addressing never reached the agent"
fi
if [ ! -s "$RR/refute-constraints.tsv" ]; then
  ok "a candidate the rubric re-ask CONVERTED contributes NO constraint — teaching the overturned standard forward would teach a mistake (the #1699 precedent)"
else
  bad "a rubric-recovered candidate still wrote a constraint row"
fi
if [ ! -e "$RR/rubric-dismissals.tsv" ]; then
  ok "no sidecar row for a candidate that recovered"
else
  bad "a recovered candidate wrote a rubric-dismissals.tsv row"
fi

note "33) end-to-end: an insufficient ground HELD through the re-ask keeps the verdict REFUTED ..."
SEVERITY_RUBRIC=1 STUB_MODE=insufficient STUB_REASK=hold _refute r-hold > "$WORK/r-hold.dir"
RH="$(cat "$WORK/r-hold.dir")"
if [ "$(_verdict_of "$RH")" = "REFUTED" ]; then
  ok "the verdict column is still exactly REFUTED — a fifth token would be read as 'no verdict row' by verify-findings.sh and the candidate silently dropped"
else
  bad "the held-ground case changed the verdict vocabulary (got '$(_verdict_of "$RH")')"
fi
case "$(_reason_of "$RH")" in
  'rubric-insufficient: '*) ok "the reason is prefixed 'rubric-insufficient: ' so the outcome is legible in the report itself" ;;
  *) bad "the held-ground reason is not prefixed: '$(_reason_of "$RH")'" ;;
esac
if [ -s "$RH/rubric-dismissals.tsv" ]; then
  RHF="$(awk -F'\t' 'NR==1{print NF}' "$RH/rubric-dismissals.tsv")"
  RHG="$(awk -F'\t' 'NR==1{print $3}' "$RH/rubric-dismissals.tsv")"
  # #2245 iteration 3 appended a FIFTH column, <contract-id>, EMPTY when the ground ID itself was insufficient
  # (which is this case) — an additive change to an operator-only artefact with one consumer, this file.
  RHC="$(awk -F'\t' 'NR==1{print $5}' "$RH/rubric-dismissals.tsv")"
  if [ "$RHF" = "5" ] && [ "$RHG" = "no-attacker" ] && [ -z "$RHC" ]; then
    ok "one sidecar row with the pinned 5 columns <class>/<file:fn>/<ground-id>/<reason>/<contract-id>, naming the held ground, with an EMPTY contract id (the id itself was insufficient — nothing to check)"
  else
    bad "the sidecar row shape is wrong (fields=$RHF ground=$RHG contract='$RHC')"
  fi
else
  bad "no rubric-dismissals.tsv row for a held insufficient ground — the NO-GO would be invisible"
fi
# At most ONE extra call per candidate: the default ceiling is 1 and the C6 fallback must not stack on top.
if [ "$(find "$RH/run" -name 'refute_*_rubric*.log' | wc -l | tr -d ' ')" = "1" ]; then
  ok "exactly ONE extra hostile read was spent (DF_RUBRIC_MAX_REASKS default 1, and it runs before the C6 fallback)"
else
  bad "the re-ask budget is not bounded at 1 (found $(find "$RH/run" -name 'refute_*_rubric*.log' | wc -l | tr -d ' ') extra logs)"
fi

note "34) end-to-end: a MISSING ground counts as insufficient, and 0 re-asks is gate-only ..."
SEVERITY_RUBRIC=1 STUB_MODE=noground STUB_REASK=hold _refute r-nog > "$WORK/r-nog.dir"
RN="$(cat "$WORK/r-nog.dir")"
if [ -f "$RN/run/refute_Pool_sol_exitPool_rubric1.log" ] && [ -s "$RN/rubric-dismissals.tsv" ] \
   && [ "$(awk -F'\t' 'NR==1{print $3}' "$RN/rubric-dismissals.tsv")" = "no-attacker" ]; then
  ok "a REFUTED verdict with NO ground line at all is re-asked (a missing ground is not a free pass), and the sidecar records the ground the SECOND read held"
else
  bad "the missing-ground case is wrong (ground recorded: '$(awk -F'\t' 'NR==1{print $3}' "$RN/rubric-dismissals.tsv" 2>/dev/null)')"
  tail -8 "$WORK/r-nog.rout" | sed 's/^/      /' >&2
fi
# ... and when the SECOND read also names nothing, the sidecar says so rather than inventing a ground.
SEVERITY_RUBRIC=1 STUB_MODE=noground STUB_REASK=noground _refute r-nog2 > "$WORK/r-nog2.dir"
RN2="$(cat "$WORK/r-nog2.dir")"
if [ "$(awk -F'\t' 'NR==1{print $3}' "$RN2/rubric-dismissals.tsv" 2>/dev/null)" = "none given" ]; then
  ok "a re-ask that names no ground either is recorded as 'none given' — the sidecar never invents a ground"
else
  bad "a groundless re-ask was not recorded as 'none given'"
fi
SEVERITY_RUBRIC=1 DF_RUBRIC_MAX_REASKS=0 STUB_MODE=insufficient _refute r-zero > "$WORK/r-zero.dir"
RZ="$(cat "$WORK/r-zero.dir")"
if [ ! -f "$RZ/run/refute_Pool_sol_exitPool_rubric1.log" ] && [ -s "$RZ/rubric-dismissals.tsv" ]; then
  ok "DF_RUBRIC_MAX_REASKS=0 is gate-ONLY: the insufficient ground is recorded and no extra call is spent"
else
  bad "the 0-re-ask (gate-only) mode is wrong"
fi

note "35) a PTY-WRAPPED ground line is never glued into the verdict reason or the constraint sentence ..."
SEVERITY_RUBRIC=1 STUB_MODE=wrapped STUB_REASK=hold _refute r-wrap > "$WORK/r-wrap.dir"
RW="$(cat "$WORK/r-wrap.dir")"
WRAP_REASON="$(_reason_of "$RW")"
WRAP_CONS="$(awk -F'\t' 'NR==1{print $3}' "$RW/refute-constraints.tsv" 2>/dev/null || true)"
WRAP_OK=1
case "$WRAP_REASON" in *'no unprivileged caller gains'*) WRAP_OK=0 ;; esac
case "$WRAP_CONS" in *'no unprivileged caller gains'*) WRAP_OK=0 ;; esac
case "$WRAP_REASON" in 'rubric-insufficient: '*) ;; *) WRAP_OK=0 ;; esac
if [ "$WRAP_OK" -eq 1 ]; then
  ok "the wrapped ground's continuation text stayed out of both the verdict reason and the constraint sentence"
else
  bad "a wrapped REFUTE-GROUND record leaked into a scraped field (reason='$WRAP_REASON' constraint='$WRAP_CONS')"
fi

note "36) DEFAULT OFF on the gate side: the report is byte-identical and no sidecar is created ..."
STUB_MODE=insufficient _refute r-off > "$WORK/r-off.dir"
ROFF="$(cat "$WORK/r-off.dir")"
STUB_MODE=insufficient _refute r-off2 > "$WORK/r-off2.dir"
ROFF2="$(cat "$WORK/r-off2.dir")"
ROFF_OK=1
[ -e "$ROFF/rubric-dismissals.tsv" ] && ROFF_OK=0
[ -f "$ROFF/run/refute_Pool_sol_exitPool_rubric1.log" ] && ROFF_OK=0
[ "$(_verdict_of "$ROFF")" = "REFUTED" ] || ROFF_OK=0
case "$(_reason_of "$ROFF")" in 'rubric-insufficient: '*) ROFF_OK=0 ;; esac
cmp -s "$ROFF/refute-report.md" "$ROFF2/refute-report.md" || ROFF_OK=0
if [ "$ROFF_OK" -eq 1 ]; then
  ok "knob unset: no sentinel => no re-ask, no sidecar file at all, the verdict and reason untouched, and the report reproduces byte for byte"
else
  bad "the knob-OFF refute run is NOT inert"
  tail -8 "$WORK/r-off.rout" | sed 's/^/      /' >&2
fi

note "36.1) end-to-end: a REFUTED verdict whose SUFFICIENT ground fails its contract is re-asked, and a held one keeps REFUTED ..."
STUB_REASK_LOG="$WORK/r-ge-addr.txt"; export STUB_REASK_LOG
SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 STUB_MODE=contractfail STUB_REASK=holdcontract _refute r-gefail > "$WORK/r-gefail.dir"
RGF="$(cat "$WORK/r-gefail.dir")"
if [ -f "$RGF/run/refute_Pool_sol_exitPool_rubric1.log" ] && [ "$(_verdict_of "$RGF")" = "REFUTED" ]; then
  ok "the measured loss shape — a reachability argument filed under the SUFFICIENT ground no-loss — now buys one more hostile read, and the verdict column still reads exactly REFUTED"
else
  bad "the refute contract gate did not fire (re-ask=$( [ -f "$RGF/run/refute_Pool_sol_exitPool_rubric1.log" ] && echo yes || echo no ), verdict=$(_verdict_of "$RGF"))"
  tail -10 "$WORK/r-gefail.rout" | sed 's/^/      /' >&2
fi
case "$(_reason_of "$RGF")" in
  'rubric-insufficient: '*) ok "the held contract failure is legible in the report row itself (same prefix as a held insufficient id — one outcome vocabulary, not two)" ;;
  *) bad "the held contract failure is not prefixed: '$(_reason_of "$RGF")'" ;;
esac
if [ -s "$RGF/rubric-dismissals.tsv" ]; then
  RGF_G="$(awk -F'\t' 'NR==1{print $3}' "$RGF/rubric-dismissals.tsv")"
  RGF_C="$(awk -F'\t' 'NR==1{print $5}' "$RGF/rubric-dismissals.tsv")"
  if [ "$RGF_G" = "no-loss" ] && [ "$RGF_C" = "reachability-as-no-loss" ]; then
    ok "the sidecar names BOTH the accepted ground id and the contract it failed (ground=$RGF_G contract=$RGF_C) — which is what makes the arm readable per contract id"
  else
    bad "the sidecar row does not carry the contract id (ground='$RGF_G' contract='$RGF_C')"
  fi
else
  bad "no rubric-dismissals.tsv row for a held contract failure"
fi
if grep -q 'no-loss: a "that state never occurs" argument' "$WORK/r-ge-addr.txt" 2>/dev/null; then
  ok "RUBRIC_REASK_GROUNDS reached the refuter naming the ground AND its missing evidence"
else
  bad "the refute contract re-ask addressing never reached the agent: '$(cat "$WORK/r-ge-addr.txt" 2>/dev/null)'"
fi

note "36.2) CONTROL: a contract-MEETING no-loss verdict is not re-asked and writes no sidecar ..."
SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 STUB_MODE=contractpass _refute r-gepass > "$WORK/r-gepass.dir"
RGP="$(cat "$WORK/r-gepass.dir")"
if [ ! -f "$RGP/run/refute_Pool_sol_exitPool_rubric1.log" ] && [ ! -e "$RGP/rubric-dismissals.tsv" ] \
   && [ "$(_verdict_of "$RGP")" = "REFUTED" ]; then
  ok "a zero delta beside a path costs no extra call and keeps the refutation exactly as it was"
else
  bad "a contract-PASSING refutation was still re-asked or side-filed (verdict=$(_verdict_of "$RGP"))"
fi

note "36.3) a contract re-ask that answers REAL recovers the candidate and teaches nothing forward ..."
SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 STUB_MODE=contractfail STUB_REASK=real _refute r-gereal > "$WORK/r-gereal.dir"
RGR="$(cat "$WORK/r-gereal.dir")"
if [ "$(_verdict_of "$RGR")" = "REAL" ] && [ ! -s "$RGR/refute-constraints.tsv" ] && [ ! -e "$RGR/rubric-dismissals.tsv" ]; then
  ok "the gate's OWN second read overturned the first (no mechanical flip anywhere), and the overturned standard is not taught forward as a constraint"
else
  bad "the contract recovery path is wrong (verdict=$(_verdict_of "$RGR"))"
fi

note "36.4) ITERATION-2 REPRODUCTION on the gate side: SEVERITY_RUBRIC=1 alone leaves the same verdict alone ..."
SEVERITY_RUBRIC=1 STUB_MODE=contractfail STUB_REASK=holdcontract _refute r-ge-it2 > "$WORK/r-ge-it2.dir"
RGI="$(cat "$WORK/r-ge-it2.dir")"
RGI_OK=1
grep -q 'GROUND-EVIDENCE|' "$RGI/run/refute_Pool_sol_exitPool.log" 2>/dev/null && RGI_OK=0
[ -f "$RGI/run/refute_Pool_sol_exitPool_rubric1.log" ] && RGI_OK=0
[ -e "$RGI/rubric-dismissals.tsv" ] && RGI_OK=0
[ "$(_verdict_of "$RGI")" = "REFUTED" ] || RGI_OK=0
case "$(_reason_of "$RGI")" in 'rubric-insufficient: '*) RGI_OK=0 ;; esac
if [ "$RGI_OK" -eq 1 ]; then
  ok "the exact verdict iteration 3 catches is accepted on its ground id alone, with no extra call and no sidecar — the iteration-2 arm reproduces byte-for-byte"
else
  bad "SEVERITY_RUBRIC=1 alone did NOT reproduce the iteration-2 gate behaviour"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 9 — verify-findings.sh IS UNTOUCHED
# ----------------------------------------------------------------------------------------------------------
note "37) verify-findings.sh's verdict vocabulary is still exactly REAL|REFUTED|ERROR ..."
if grep -q 'v=="REAL"||v=="REFUTED"||v=="ERROR"' "$VERIFY"; then
  ok "the verdict vocabulary verify-findings.sh matches on is unchanged (that is WHY the gate keeps REFUTED)"
else
  bad "verify-findings.sh's verdict vocabulary changed — this iteration must not touch it"
fi
# Nothing in the new code path may write a fifth token into the verdict column.
if grep -nE "printf '\| %s \| %s \| %s \| %s \|" "$REFUTE" | grep -q 'VERD'; then
  ok "run-refute.sh still emits the verdict column from \$VERD alone (the rubric changes the REASON, never the verdict token)"
else
  bad "the report row no longer emits the verdict from \$VERD — a new token could reach the verdict column"
fi
NEWTOK=""
for t in RUBRIC-INSUFFICIENT INSUFFICIENT UNJUSTIFIED; do
  grep -q "VERD=\"$t\"" "$REFUTE" && NEWTOK="$NEWTOK $t"
done
if [ -z "$NEWTOK" ]; then
  ok "no assignment introduces a fifth verdict token anywhere in run-refute.sh"
else
  bad "run-refute.sh assigns a new verdict token:$NEWTOK — verify-findings.sh would drop the candidate as 'no verdict row'"
fi
# And the whole file must be untouched by this change: no #2245 edit may land in it.
if ! grep -q '2245' "$VERIFY"; then
  ok "verify-findings.sh carries no #2245 edit (one export reaches both gates through the plain subprocess call)"
else
  bad "verify-findings.sh was modified by this change — the plan pins it as untouched"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 10 — LIVE UNDER MOCK: the AGENT half (needs the agentis binary; clean [SKIP] otherwise)
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  note "38-39) live-under-mock sentinel ON/OFF + the byte-identity probe ..."
  skip "no agentis binary on PATH — the real hunt cells and the extracted-helper probe cannot run"
else
  note "38) live-under-mock: the sentinel fires with SEVERITY_RUBRIC=1 and is ABSENT by default ..."
  _mock() {
    _m_label="$1"
    _m_repo="$WORK/$_m_label-repo"; mkdir -p "$_m_repo/contracts"
    cp "$FIXSOL" "$_m_repo/contracts/PlainCounter.sol"
    printf 'counter | C25 | contracts/PlainCounter.sol\n' > "$WORK/$_m_label-scope.tsv"
    printf '# brief\nInvariants to break: the documented paths stay available.\nKnown issues to exclude: none.\n' \
      > "$WORK/$_m_label-brief.md"
    "$DISCOVERY" --repo "$_m_repo" --scope "$WORK/$_m_label-scope.tsv" --brief "$WORK/$_m_label-brief.md" \
      --only counter --classes C25 --backend mock --agentis agentis --out "$WORK/$_m_label" \
      > "$WORK/$_m_label.out" 2>&1 || true
    printf '%s\n' "$WORK/$_m_label/run/hunt_counter_C25.log"
  }
  M_ON="$(SEVERITY_RUBRIC=1 _mock mock-on)"
  M_OFF="$(_mock mock-off)"
  M_BOTH="$(SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 _mock mock-both)"
  if [ ! -f "$M_ON" ] || [ ! -f "$M_OFF" ]; then
    bad "the mock hunt cells produced no cell log (run-discovery.sh did not reach hunter.ag)"
    tail -5 "$WORK/mock-on.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    if grep -q '^SEVERITY-RUBRIC|counter|C25|on$' "$M_ON"; then
      ok "SEVERITY_RUBRIC=1: the sentinel fired end-to-end (run-discovery.sh -> env_passthrough -> hunter.ag getenv -> index_of(instruction, marker))"
    else
      bad "SEVERITY_RUBRIC=1: NO SEVERITY-RUBRIC| sentinel — the opt-in did not reach hunter.ag (env_passthrough gap?)"
    fi
    if grep -q 'SEVERITY-RUBRIC|' "$M_OFF"; then
      bad "default (env unset): a SEVERITY-RUBRIC| sentinel appeared — the rubric is NOT default-OFF"
    else
      ok "default (env unset): NO SEVERITY-RUBRIC| sentinel — the rubric is opt-in and the prompt is unchanged"
    fi
    # #2245 iteration 3: the DISCRIMINATING live check — the two knobs must be separately observable, because
    # that separation is what makes the two arms comparable.
    if grep -q 'GROUND-EVIDENCE|' "$M_ON"; then
      bad "SEVERITY_RUBRIC=1 alone printed a GROUND-EVIDENCE| sentinel — the iteration-2 arm would carry the iteration-3 contract"
    else
      ok "SEVERITY_RUBRIC=1 alone: the rubric sentinel fires and the contract sentinel does NOT (the iteration-2 arm, end-to-end)"
    fi
    if [ -f "$M_BOTH" ] && grep -q '^SEVERITY-RUBRIC|counter|C25|on$' "$M_BOTH" \
       && grep -q '^GROUND-EVIDENCE|counter|C25|on$' "$M_BOTH"; then
      ok "both knobs: BOTH sentinels fire end-to-end (run-discovery.sh -> env_passthrough -> hunter.ag getenv -> index_of(instruction, marker)) — the iteration-3 arm"
    else
      bad "SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1: the contract sentinel did not fire — the second opt-in does not reach hunter.ag (env_passthrough gap?)"
    fi
    if grep -q 'GROUND-EVIDENCE|' "$M_OFF"; then
      bad "default (env unset): a GROUND-EVIDENCE| sentinel appeared — the contract is NOT default-OFF"
    else
      ok "default (env unset): neither sentinel — the pre-#2245 prompt is reproduced"
    fi
  fi

  note "39) byte-identity probe: the directive is EXACTLY 0 bytes when the knob is unset ..."
  FRAG="$WORK/rubric.frag"; : > "$FRAG"
  FRAG_MISS=""
  for fn in $HUNT_FNS $GE_FNS; do
    _agfn "$HUNTER" "$fn" >> "$FRAG"
    printf '\n' >> "$FRAG"
    grep -q "^fn $fn(" "$FRAG" || FRAG_MISS="$FRAG_MISS $fn"
  done
  if [ -n "$FRAG_MISS" ]; then
    bad "could not extract the #2245 helpers from hunter.ag by line range (renamed?):$FRAG_MISS"
  else
    SB="$WORK/probe"; mkdir -p "$SB"
    ( cd "$SB" && agentis init >/dev/null 2>&1 ) || true
    printf 'exec.env_passthrough = SEVERITY_RUBRIC,DISMISS_REASK_GROUNDS,GROUND_EVIDENCE\n' > "$SB/.agentis/config"
    {
      printf 'cb 300000;\n\n'
      cat "$FRAG"
      printf 'print("BLOCKLEN=" + to_string(len(severity_rubric_block()) + len(dismiss_rule())));\n'
      printf 'print("CONTRACTLEN=" + to_string(len(ground_evidence_block())));\n'
      printf 'print("DIRLEN=" + to_string(len(severity_rubric_directive())));\n'
    } > "$SB/probe.ag"
    # _dirlen <knob-value|""> [reask-grounds]: the toggle-gated directive length. An empty first argument runs
    # with SEVERITY_RUBRIC UNSET; the optional second sets DISMISS_REASK_GROUNDS, which is how the re-ask block
    # is measured — and how the knob-OFF byte-identity contract is proven to survive a populated env.
    # The third argument is #2245 iteration 3's GROUND_EVIDENCE (empty = unset), so the same probe measures both
    # knobs and every combination of them.
    _dirlen() {
      _dl_g="${2:-}"; _dl_c="${3:-}"
      if [ -n "$1" ]; then
        _dl="$( cd "$SB" && SEVERITY_RUBRIC="$1" DISMISS_REASK_GROUNDS="$_dl_g" GROUND_EVIDENCE="$_dl_c" agentis go probe.ag 2>&1 | grep '^DIRLEN=' | tail -1 )"  # no-pii: the probe never calls prompt() — it prints two string lengths
      else
        _dl="$( cd "$SB" && DISMISS_REASK_GROUNDS="$_dl_g" GROUND_EVIDENCE="$_dl_c" agentis go probe.ag 2>&1 | grep '^DIRLEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
      fi
      printf '%s\n' "${_dl#DIRLEN=}"
    }
    BLOCK_LEN="$( cd "$SB" && agentis go probe.ag 2>&1 | grep '^BLOCKLEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
    BLOCK_LEN="${BLOCK_LEN#BLOCKLEN=}"
    CONTRACT_LEN="$( cd "$SB" && agentis go probe.ag 2>&1 | grep '^CONTRACTLEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
    CONTRACT_LEN="${CONTRACT_LEN#CONTRACTLEN=}"
    DIR_UNSET="$(_dirlen "")"
    DIR_ON="$(_dirlen "1")"
    DIR_ZERO="$(_dirlen "0")"
    DIR_TRUE="$(_dirlen "true")"
    DIR_UNSET_WITH_ENV="$(_dirlen "" "Vault.sol:exitPool (no-attacker)")"
    case "$BLOCK_LEN" in
      ''|*[!0-9]*) bad "the byte-identity probe did not complete (BLOCKLEN='$BLOCK_LEN')" ;;
      0) bad "the rubric block is empty — the directive could never reach a prompt" ;;
      *) ok "the rubric + emission contract is $BLOCK_LEN bytes (the MEASURED prompt-byte cost of a rubric-ON cell, printed rather than assumed)" ;;
    esac
    case "$DIR_UNSET" in
      0) ok "SEVERITY_RUBRIC unset: severity_rubric_directive() is \"\" (0 bytes) — the DEFAULT prompt is byte-identical to the pre-#2245 one" ;;
      ''|*[!0-9]*) bad "the toggle probe did not complete with the env unset (got '$DIR_UNSET')" ;;
      *) bad "SEVERITY_RUBRIC unset: the directive is $DIR_UNSET bytes — the default is NOT byte-identical" ;;
    esac
    if [ "$DIR_ON" = "$BLOCK_LEN" ] && [ "$BLOCK_LEN" != "0" ] 2>/dev/null; then
      ok "SEVERITY_RUBRIC=1: the directive = $DIR_ON bytes = rubric + emission contract (the opt-in really injects it)"
    else
      bad "SEVERITY_RUBRIC=1: the directive ($DIR_ON) != rubric + emission contract ($BLOCK_LEN)"
    fi
    if [ "$DIR_ZERO" = "0" ] && [ "$DIR_TRUE" = "0" ]; then
      ok "SEVERITY_RUBRIC=0 and =true are BOTH off — only the literal \"1\" opts in (the deliberately inverted polarity)"
    else
      bad "a non-\"1\" value opted in (\"0\" -> $DIR_ZERO bytes, \"true\" -> $DIR_TRUE bytes)"
    fi
    if [ "$DIR_UNSET_WITH_ENV" = "0" ]; then
      ok "a populated DISMISS_REASK_GROUNDS cannot leak into a knob-OFF prompt (the re-ask block lives INSIDE the gated directive)"
    else
      bad "DISMISS_REASK_GROUNDS added $DIR_UNSET_WITH_ENV bytes to a knob-OFF prompt — the byte-identity contract is broken"
    fi

    # #2245 iteration 3: the SECOND knob, measured on the same probe.
    DIR_BOTH="$(_dirlen "1" "" "1")"
    DIR_CONTRACT_ONLY="$(_dirlen "" "" "1")"
    DIR_RUBRIC_CONTRACT_ZERO="$(_dirlen "1" "" "0")"
    case "$CONTRACT_LEN" in
      ''|*[!0-9]*) bad "the contract probe did not complete (CONTRACTLEN='$CONTRACT_LEN')" ;;
      0) bad "the per-ground contract is empty — it could never reach a prompt" ;;
      *) ok "the per-ground evidence contract is $CONTRACT_LEN bytes (the MEASURED prompt-byte delta of the iteration-3 arm, printed rather than assumed)" ;;
    esac
    if [ "$DIR_ON" = "$BLOCK_LEN" ] && [ "$DIR_BOTH" = "$((BLOCK_LEN + CONTRACT_LEN))" ]; then
      ok "SEVERITY_RUBRIC=1 alone renders exactly the iteration-2 string ($DIR_ON bytes) and adding GROUND_EVIDENCE=1 adds exactly the contract ($DIR_BOTH bytes) — one delta, one arm"
    else
      bad "the two-knob arithmetic is wrong (rubric-only=$DIR_ON, both=$DIR_BOTH, rubric=$BLOCK_LEN, contract=$CONTRACT_LEN)"
    fi
    if [ "$DIR_CONTRACT_ONLY" = "0" ]; then
      ok "GROUND_EVIDENCE=1 with the rubric OFF is INERT by construction (0 bytes): the contract lives inside the rubric directive, so there is no block, no marker, no sentinel and no shell layer"
    else
      bad "GROUND_EVIDENCE=1 alone rendered $DIR_CONTRACT_ONLY bytes — the two-knob confusion case is NOT inert"
    fi
    if [ "$DIR_RUBRIC_CONTRACT_ZERO" = "$BLOCK_LEN" ]; then
      ok "GROUND_EVIDENCE=0 is OFF — only the literal \"1\" opts in on the second knob too (the same deliberately inverted polarity)"
    else
      bad "GROUND_EVIDENCE=0 changed the prompt ($DIR_RUBRIC_CONTRACT_ZERO bytes, want $BLOCK_LEN)"
    fi
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "ALL ASSERTIONS HELD — the #2245 dismissal rubric (iteration 2) and the per-ground EVIDENCE contract"
  note "(iteration 3) are wired, output-gated on both sides, mutually independent and BOTH default OFF."
  note "NOTE: nothing above is a recall claim. Whether the contract recovers the held-out row is the operator's"
  note "pre-registered measurement (2 held-out repeats, GO iff the row survives to verified_findings.json)."
  exit 0
fi
note "$FAILS assertion(s) FAILED"
exit 1
