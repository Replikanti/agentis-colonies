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
#      rubric would silently re-ask on a ground the model was never offered).
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
  awk '/--- #2245 iteration 2: CONTEST-SEVERITY DISMISSAL RUBRIC/{f=1} f&&/^\/\/ --- #2235 READ THE EXTERNAL PROTOCOL/{exit} f{print}' "$HUNTER"
  awk '/--- #2245 iteration 2: CONTEST-SEVERITY DISMISSAL RUBRIC/{f=1} f&&/^\/\/ --- #1938 invariant-hunt judgment mode/{exit} f{print}' "$REFUTER"
} | grep -v '^[[:space:]]*//' > "$PURE"
if [ ! -s "$PURE" ]; then
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
  _shfn "$DISCOVERY" _insufficient_dismissal_rows
  _shfn "$DISCOVERY" _insufficient_dismissal_locs
  _shfn "$DISCOVERY" _rubric_dismissal_gap
  _shfn "$DISCOVERY" _rubric_reask_needed
  _shfn "$DISCOVERY" _rubric_open_grounds
  _shfn "$DISCOVERY" _rubric_promote
  _shfn "$DISCOVERY" _rubric_promoted_candidates
  _shfn "$DISCOVERY" _rubric_promoted_count
  _shfn "$DISCOVERY" _cell_candidates
  _shfn "$DISCOVERY" _join_wrapped_candidates
  # _rubric_promote validates its location with the SHIPPED tier-2 helpers, so the slice must carry them or the
  # extracted gate would behave differently here than in production (the whole point of slicing).
  _shfn "$DISCOVERY" _tier2_resolve_file
  _shfn "$DISCOVERY" _tier2_emit_loc
} > "$GATE_FNS"
GATE_LOADED=0
if grep -q '^_rubric_dismissal_gap() {$' "$GATE_FNS" && grep -q '^_rubric_promote() {$' "$GATE_FNS" \
   && grep -q '^_tier2_emit_loc() {$' "$GATE_FNS" && grep -q '^_rubric_reask_needed() {$' "$GATE_FNS"; then
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
    if [ -n "${DISMISS_REASK_GROUNDS:-}" ]; then
      # The RE-ASK turn. Record what the driver named, so the caller can assert the addressing reached the cell.
      [ -n "${STUB_REASK_LOG:-}" ] && printf '%s\n' "$DISMISS_REASK_GROUNDS" >> "$STUB_REASK_LOG"
      # The re-ask keeps the SAME location the first turn named (STUB_LOC), so the "unresolvable location"
      # arm stays unresolvable across both turns instead of silently becoming promotable.
      case "${STUB_REASK:-hold}" in
        comply)  printf 'DISMISS|%s|guard|PlainCounter.sol:12 rejects it outright\n' "${STUB_LOC:-PlainCounter.sol:increment}" ;;
        candidate) printf 'CANDIDATE|PlainCounter.sol:increment:12|%s|Medium|the documented path reverts under an admitted cap|set the cap to zero and assert the revert\n' "${HUNT_CLASS:-}"; printf 'SAFE\n'; exit 0 ;;
        *)       printf 'DISMISS|%s|no-attacker|nobody profits from the reverted call\n' "${STUB_LOC:-PlainCounter.sol:increment}" ;;
      esac
      printf 'SAFE\n'
      exit 0
    fi
    case "${STUB_MODE:-insufficient}" in
      sufficient) printf 'DISMISS|PlainCounter.sol:increment|guard|PlainCounter.sol:12 rejects it outright\n' ;;
      unresolvable) printf 'DISMISS|Elsewhere.sol:mystery|no-attacker|nobody profits from the reverted call\n' ;;
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
  if [ "$RHF" = "4" ] && [ "$RHG" = "no-attacker" ]; then
    ok "one sidecar row with the pinned 4 columns <class>/<file:fn>/<ground-id>/<reason>, naming the held ground"
  else
    bad "the sidecar row shape is wrong (fields=$RHF ground=$RHG)"
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
  fi

  note "39) byte-identity probe: the directive is EXACTLY 0 bytes when the knob is unset ..."
  FRAG="$WORK/rubric.frag"; : > "$FRAG"
  FRAG_MISS=""
  for fn in $HUNT_FNS; do
    _agfn "$HUNTER" "$fn" >> "$FRAG"
    printf '\n' >> "$FRAG"
    grep -q "^fn $fn(" "$FRAG" || FRAG_MISS="$FRAG_MISS $fn"
  done
  if [ -n "$FRAG_MISS" ]; then
    bad "could not extract the #2245 helpers from hunter.ag by line range (renamed?):$FRAG_MISS"
  else
    SB="$WORK/probe"; mkdir -p "$SB"
    ( cd "$SB" && agentis init >/dev/null 2>&1 ) || true
    printf 'exec.env_passthrough = SEVERITY_RUBRIC,DISMISS_REASK_GROUNDS\n' > "$SB/.agentis/config"
    {
      printf 'cb 300000;\n\n'
      cat "$FRAG"
      printf 'print("BLOCKLEN=" + to_string(len(severity_rubric_block()) + len(dismiss_rule())));\n'
      printf 'print("DIRLEN=" + to_string(len(severity_rubric_directive())));\n'
    } > "$SB/probe.ag"
    # _dirlen <knob-value|""> [reask-grounds]: the toggle-gated directive length. An empty first argument runs
    # with SEVERITY_RUBRIC UNSET; the optional second sets DISMISS_REASK_GROUNDS, which is how the re-ask block
    # is measured — and how the knob-OFF byte-identity contract is proven to survive a populated env.
    _dirlen() {
      _dl_g="${2:-}"
      if [ -n "$1" ]; then
        _dl="$( cd "$SB" && SEVERITY_RUBRIC="$1" DISMISS_REASK_GROUNDS="$_dl_g" agentis go probe.ag 2>&1 | grep '^DIRLEN=' | tail -1 )"  # no-pii: the probe never calls prompt() — it prints two string lengths
      else
        _dl="$( cd "$SB" && DISMISS_REASK_GROUNDS="$_dl_g" agentis go probe.ag 2>&1 | grep '^DIRLEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
      fi
      printf '%s\n' "${_dl#DIRLEN=}"
    }
    BLOCK_LEN="$( cd "$SB" && agentis go probe.ag 2>&1 | grep '^BLOCKLEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
    BLOCK_LEN="${BLOCK_LEN#BLOCKLEN=}"
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
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "ALL ASSERTIONS HELD — the #2245 iteration-2 dismissal rubric is wired, output-gated on both sides and default OFF."
  note "NOTE: nothing above is a recall claim. Whether the rubric recovers the held-out row is the operator's"
  note "pre-registered measurement (2 held-out repeats, GO iff the row survives to verified_findings.json)."
  exit 0
fi
note "$FAILS assertion(s) FAILED"
exit 1
