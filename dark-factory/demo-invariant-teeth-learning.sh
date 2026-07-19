#!/usr/bin/env bash
# demo-invariant-teeth-learning.sh — proof of the #1728 TEETH-SIGNAL wiring into the invariant learning loop.
#
# The invariant-hunt deep-hunt learns from a FINDING (it persists the winning pattern to invpat:latest:<class>
# and recall_pattern() reuses it), but a CLEAN dead-ended: a TOOTHLESS invariant (holds because it is too weak
# to break) and a CREDIBLE one (holds because the target is really clean under a KILLING invariant) were
# indistinguishable, so the loop learned nothing from either. #1728 wires the #1724 mutant-kill seam in as an
# ACCEPTANCE/LEARNING signal that fires STRICTLY AFTER the fuzzer verdict + the `INVARIANT|` marker are printed:
# on a CLEAN only, invariant-prover.ag runs mutant-kill.sh --class/--invariant, parses the `kill ratio: K / M`
# line with FLAT builtins, and classifies the CLEAN into credible (K>=1 -> reward `partial` + persist to a NEW
# `invpat:teeth:<class>` recall tier), toothless (killed nothing -> not persisted, tag `toothless-clean`), or
# unmeasured (SKIP/error/all-ERROR -> today's behaviour, byte-identical). The FUZZER stays the SOLE verdict.
#
# This is a SOURCE-GUARD + offline-behavioural demo (always CI-safe, no LLM, no agentis; the LIVE kill-ratio
# assertions run only when forge is on PATH and SKIP cleanly otherwise). It pins:
#   (a) run_mutant_kill is ONE `exec sh` with --class/--invariant, every dynamic value shell_escape()d;
#   (b) the teeth exec + teeth_of + persist_teeth sit AFTER the `INVARIANT|` marker and NONE of them reference
#       verdict_of / final_verdict / --require-import / --require-contract (fuzzer stays sole verdict; #1471 gate
#       untouched), and the mutant-kill exec is CLEAN-only;
#   (c) recall_pattern consults invpat:teeth: and persist_teeth writes invpat:teeth: while persist_pattern still
#       guards FINDING and writes invpat:latest: (the FINDING learning path is intact);
#   (d) graceful len(mk)==0 / len(klass)==0 fallback + the unmeasured bucket;
#   (e) the runner stages mutant-kill.sh + mutants/ and threads MUTANT_KILL on exec.env_passthrough + the env;
#   (f) LIVE (forge present): mutant-kill.sh --class C-erc4626 --invariant inv_victim_not_robbed.t.sol reports
#       `kill ratio: 1 / 1 killed` (-> credible) and inv_toothless.t.sol reports `kill ratio: 0 / 1 killed`
#       (-> toothless) — pinning the exact thresholds teeth_of() keys on against the #1724 kill-set.
#
# Usage:  dark-factory/demo-invariant-teeth-learning.sh
# Exit: 0 = all assertions hold (live part SKIPs cleanly when forge is absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
RUNNER="$HERE/run-invariant-hunt.sh"
HARNESS="$HERE/evm-harness/mutant-kill.sh"
MUTANTS_DIR="$HERE/evm-harness/mutants"

FAILS=0
note() { echo "demo-invariant-teeth-learning.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$PROVER" ]  || { note "prover not found: $PROVER" >&2; exit 3; }
[ -f "$RUNNER" ]  || { note "runner not found: $RUNNER" >&2; exit 3; }
[ -f "$HARNESS" ] || { note "harness not found: $HARNESS" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# (a) TEETH EXEC — ONE `exec sh` calling mutant-kill.sh --class/--invariant, every dynamic value shell_escape()d.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1728 run_mutant_kill exec ..."

if grep -q 'fn run_mutant_kill(mk: string, klass: string, inv: string) -> string' "$PROVER"; then
  ok "run_mutant_kill() is defined on the prover"
else
  bad "run_mutant_kill() missing from the prover"
fi

# Exactly ONE exec sh inside run_mutant_kill (mutant iteration lives inside mutant-kill.sh — no per-element .ag
# recursion). Pull the function body and count `exec sh` occurrences.
_rmk_body="$(awk '/fn run_mutant_kill\(/{f=1} f{print} f&&/^}/{exit}' "$PROVER")"
_rmk_execs="$(printf '%s\n' "$_rmk_body" | grep -c 'exec sh')"
if [ "$_rmk_execs" -eq 1 ]; then
  ok "run_mutant_kill runs EXACTLY ONE exec sh (no per-element .ag recursion)"
else
  bad "run_mutant_kill has $_rmk_execs exec sh calls (expected exactly 1)"
fi

if printf '%s\n' "$_rmk_body" | grep -q -- '--class " + shell_escape(klass)' \
   && printf '%s\n' "$_rmk_body" | grep -q -- '--invariant " + shell_escape(inv)'; then
  ok "the exec passes --class/--invariant with every dynamic value shell_escape()d"
else
  bad "the exec does not shell_escape() the --class/--invariant values"
fi

if printf '%s\n' "$_rmk_body" | grep -q 'shell_escape(mk)'; then
  ok "the mutant-kill.sh path itself is shell_escape()d"
else
  bad "the mutant-kill.sh path is not shell_escape()d"
fi

if printf '%s\n' "$_rmk_body" | grep -q 'colony-lint: safe-exec-concat'; then
  ok "run_mutant_kill carries the // colony-lint: safe-exec-concat annotation"
else
  bad "run_mutant_kill missing the // colony-lint: safe-exec-concat annotation"
fi

# ----------------------------------------------------------------------------------------------------------
# (b) FUZZER STAYS SOLE VERDICT — the teeth logic sits AFTER the `INVARIANT|` marker and never references the
#     verdict machinery or the #1471 gate; the mutant-kill exec is CLEAN-only.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that the teeth logic sits AFTER the verdict marker + never touches it ..."

_marker_ln="$(grep -n 'print("INVARIANT|"' "$PROVER" | head -1 | cut -d: -f1)"
_rmk_ln="$(grep -n 'fn run_mutant_kill(' "$PROVER" | head -1 | cut -d: -f1)"
_teethof_ln="$(grep -n 'fn teeth_of(' "$PROVER" | head -1 | cut -d: -f1)"
_persistteeth_ln="$(grep -n 'fn persist_teeth(' "$PROVER" | head -1 | cut -d: -f1)"
_measure_ln="$(grep -n 'let teeth = measure_teeth(' "$PROVER" | head -1 | cut -d: -f1)"
if [ -n "$_marker_ln" ] && [ -n "$_rmk_ln" ] && [ -n "$_teethof_ln" ] && [ -n "$_persistteeth_ln" ] && [ -n "$_measure_ln" ] \
   && [ "$_rmk_ln" -gt "$_marker_ln" ] && [ "$_teethof_ln" -gt "$_marker_ln" ] \
   && [ "$_persistteeth_ln" -gt "$_marker_ln" ] && [ "$_measure_ln" -gt "$_marker_ln" ]; then
  ok "run_mutant_kill / teeth_of / persist_teeth / the measure call all sit AFTER the INVARIANT| marker print"
else
  bad "a teeth function/call is NOT strictly after the INVARIANT| marker (verdict must stay finalized first)"
fi

# The teeth functions must NEVER reference the verdict machinery or the #1471 gate. Slice the file from the
# first teeth function to EOF and assert none of those tokens appear on a non-comment line.
_teeth_slice="$(awk -v s="$_rmk_ln" 'NR>=s' "$PROVER" | grep -v '^[[:space:]]*//')"
if printf '%s\n' "$_teeth_slice" | grep -Eq 'verdict_of|final_verdict|--require-import|--require-contract'; then
  bad "a teeth function references verdict_of / final_verdict / the #1471 gate (must stay untouched)"
  printf '%s\n' "$_teeth_slice" | grep -En 'verdict_of|final_verdict|--require-import|--require-contract' | sed 's/^/         | /'
else
  ok "no teeth function references verdict_of / final_verdict / --require-import / --require-contract"
fi

# The mutant-kill exec must be CLEAN-only: measure_teeth returns early for a non-CLEAN verdict, so a FINDING /
# HARNESS_ERROR path runs NO exec at all (byte-identical to before).
if grep -q 'fn measure_teeth(verd: string, mk: string, klass: string, inv: string) -> string' "$PROVER" \
   && awk '/fn measure_teeth\(/{f=1} f{print} f&&/^}/{exit}' "$PROVER" | grep -q 'if verd != "CLEAN" { return "none"; }'; then
  ok "measure_teeth runs the kill-set on a CLEAN ONLY (non-CLEAN => no exec, byte-identical)"
else
  bad "measure_teeth is not gated CLEAN-only"
fi

# The verdict marker + the FINDING STEP| path + the #1471 link_args gate are still byte-present + unchanged.
if grep -q 'print("INVARIANT|" + targetFn + "|" + verdict);' "$PROVER" \
   && grep -q 'fn verdict_of(rc: int) -> string' "$PROVER" \
   && grep -q 'fn final_verdict(rc: int, violated: bool) -> string' "$PROVER" \
   && grep -q -- '--require-import ' "$PROVER"; then
  ok "the INVARIANT| marker, verdict_of, final_verdict, and the #1471 --require-import gate are all still present"
else
  bad "a verdict/marker/#1471-gate anchor is missing (the fuzzer-sole-verdict contract must be intact)"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) FINDING LEARNING INTACT + NEW invpat:teeth: TIER — recall consults it, persist_teeth writes it, and the
#     FINDING path (persist_pattern -> invpat:latest:) is untouched.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the invpat:teeth: recall tier + the untouched FINDING path ..."

if grep -q 'recall_latest("invpat:teeth:" + klass)' "$PROVER"; then
  ok "recall_pattern consults the invpat:teeth:<class> tier"
else
  bad "recall_pattern does not consult invpat:teeth:<class>"
fi

# Recall precedence: invpat:latest: (FINDING) is consulted BEFORE invpat:teeth:, so a FINDING is never overridden.
_latest_ln="$(grep -n 'recall_latest("invpat:latest:" + klass)' "$PROVER" | head -1 | cut -d: -f1)"
_teeth_ln="$(grep -n 'recall_latest("invpat:teeth:" + klass)' "$PROVER" | head -1 | cut -d: -f1)"
_invented_ln="$(grep -n 'recall_latest("invpat:invented:" + klass)' "$PROVER" | head -1 | cut -d: -f1)"
if [ -n "$_latest_ln" ] && [ -n "$_teeth_ln" ] && [ -n "$_invented_ln" ] \
   && [ "$_latest_ln" -lt "$_teeth_ln" ] && [ "$_teeth_ln" -lt "$_invented_ln" ]; then
  ok "recall precedence is FINDING (invpat:latest:) > teeth-clean (invpat:teeth:) > invented (invpat:invented:)"
else
  bad "recall precedence is not latest > teeth > invented (a FINDING could be overridden by a teeth pattern)"
fi

if grep -q 'memo_write("invpat:teeth:" + klass, psig);' "$PROVER"; then
  ok "persist_teeth writes the NEW invpat:teeth:<class> namespace"
else
  bad "persist_teeth does not write invpat:teeth:<class>"
fi

# persist_pattern is byte-untouched: still FINDING-guarded, still writes invpat:latest:.
if grep -q 'fn persist_pattern(verd: string, klass: string, target: string, matchPrefix: string) -> void' "$PROVER" \
   && awk '/fn persist_pattern\(/{f=1} f{print} f&&/^}/{exit}' "$PROVER" | grep -q 'if verd == "FINDING"' \
   && awk '/fn persist_pattern\(/{f=1} f{print} f&&/^}/{exit}' "$PROVER" | grep -q 'memo_write("invpat:latest:" + klass, psig);'; then
  ok "persist_pattern still guards FINDING and writes invpat:latest: (the FINDING learning path is intact)"
else
  bad "the FINDING -> invpat:latest: persist path changed (it must stay byte-untouched)"
fi

# The learn() call carries a DISTINCT teeth outcome/tag (credible-clean=partial vs toothless-clean vs finding).
if grep -q 'fn learn_outcome(base: string, tth: string) -> string' "$PROVER" \
   && grep -q 'return "credible-clean";' "$PROVER" \
   && grep -q 'return "toothless-clean";' "$PROVER" \
   && grep -q 'learn("invariant-prove", targetClass + ":" + targetFn' "$PROVER"; then
  ok "learn() derives a distinct teeth outcome (partial) + tag (credible-clean / toothless-clean)"
else
  bad "learn() does not carry the distinct teeth outcome/tag"
fi

# The bus emit for the verdict stays byte-identical (its outcome field is verdict-derived, not teeth-derived).
if grep -q 'emit("dark-factory:invariant_verdict", "{\\"target\\":\\"" + targetFn + "\\",\\"class\\":\\"" + targetClass + "\\",\\"verdict\\":\\"" + verdict + "\\",\\"gen\\":\\"" + genMode + "\\",\\"outcome\\":\\"" + outcome + "\\"}");' "$PROVER"; then
  ok "the invariant_verdict emit stays byte-identical (verdict-derived outcome field)"
else
  bad "the invariant_verdict emit was altered (it must stay byte-identical)"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) GRACEFUL DEGRADATION — empty MUTANT_KILL / empty class => no exec; SKIP/error/all-ERROR => unmeasured.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the graceful-degradation fallback ..."

if printf '%s\n' "$_rmk_body" | grep -q 'if len(mk) == 0 { return ""; }' \
   && printf '%s\n' "$_rmk_body" | grep -q 'if len(klass) == 0 { return ""; }'; then
  ok "run_mutant_kill returns \"\" (no exec) when MUTANT_KILL or class is empty"
else
  bad "run_mutant_kill missing the empty-MUTANT_KILL / empty-class no-exec guard"
fi

_teethof_body="$(awk '/fn teeth_of\(/{f=1} f{print} f&&/^}/{exit}' "$PROVER")"
if printf '%s\n' "$_teethof_body" | grep -q 'index_of(mkOut, "\[SKIP\]") >= 0 { return "unmeasured"; }' \
   && printf '%s\n' "$_teethof_body" | grep -q 'rc_of(mkOut) != 0 { return "unmeasured"; }' \
   && printf '%s\n' "$_teethof_body" | grep -q 'index_of(mkOut, "kill ratio:") < 0 { return "unmeasured"; }'; then
  ok "teeth_of falls back to unmeasured on SKIP / gate error / no kill-ratio line"
else
  bad "teeth_of missing a SKIP / error / no-ratio unmeasured fallback"
fi

# The toothless bucket requires a GENUINE survivor ((m-e)>=1) so all-mutants-ERROR (interface mismatch on a real
# target) is unmeasured, NEVER penalized as toothless.
if printf '%s\n' "$_teethof_body" | grep -q '(m - e) >= 1 { return "toothless"; }' \
   && printf '%s\n' "$_teethof_body" | grep -q 'if k >= 1 { return "credible"; }'; then
  ok "teeth_of classifies credible (K>=1) / toothless ((M-E)>=1) / else unmeasured (all-ERROR never penalized)"
else
  bad "teeth_of missing the credible/toothless/unmeasured discrimination"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) RUNNER WIRING — stages mutant-kill.sh + mutants/ and threads MUTANT_KILL on passthrough + the env.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the runner MUTANT_KILL wiring ..."

if grep -q 'cp "$MUTANT_KILL_SRC" "$RUN/mutant-kill.sh"' "$RUNNER" \
   && grep -q 'cp -R "$MUTANTS_SRC" "$RUN/mutants"' "$RUNNER"; then
  ok "run-invariant-hunt.sh stages mutant-kill.sh + the mutants/ tree into the rundir"
else
  bad "run-invariant-hunt.sh does not stage mutant-kill.sh + mutants/ into the rundir"
fi

# MUTANT_KILL must be a passthrough entry (comma-anchored so it matches whether it is mid-list or last — #1731
# appended INV_CORPUS after it, so it is no longer necessarily the final entry).
if grep -q 'exec.env_passthrough = .*,MUTANT_KILL[,"]' "$RUNNER"; then
  ok "MUTANT_KILL is on the exec.env_passthrough allowlist (else getenv would read empty)"
else
  bad "MUTANT_KILL is not on exec.env_passthrough (the getenv read would be silently inert)"
fi

if grep -q 'MUTANT_KILL="$MUTANT_KILL_IN_RUN" \\' "$RUNNER"; then
  ok "the env block threads MUTANT_KILL=\"\$MUTANT_KILL_IN_RUN\" into the agentis go invocation"
else
  bad "the env block does not thread MUTANT_KILL into the agentis go invocation"
fi

# The staging is guarded so a missing kill-set degrades gracefully (MUTANT_KILL_IN_RUN stays "").
if grep -q 'if \[ -f "$MUTANT_KILL_SRC" \] && \[ -d "$MUTANTS_SRC" \]; then' "$RUNNER"; then
  ok "the staging is guarded (missing kill-set => MUTANT_KILL_IN_RUN empty => graceful fallback)"
else
  bad "the staging is not guarded against a missing kill-set"
fi

# ----------------------------------------------------------------------------------------------------------
# (f) LIVE — pin the exact kill ratios teeth_of() keys on against the #1724 C-erc4626 kill-set (SKIP w/o forge).
# ----------------------------------------------------------------------------------------------------------
if ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run the live kill-ratio assertions"
else
  note "running the live mutant-kill.sh kill-ratio assertions under forge ..."
  _good_out="$("$HARNESS" --class C-erc4626 --invariant "$MUTANTS_DIR/C-erc4626/inv_victim_not_robbed.t.sol" 2>&1)"; _good_rc=$?
  if [ "$_good_rc" -eq 0 ] && printf '%s' "$_good_out" | grep -q 'kill ratio: 1 / 1 killed'; then
    ok "good invariant x C-erc4626: kill ratio 1 / 1 killed (K>=1 -> credible)"
  else
    bad "good invariant x C-erc4626 did not report 'kill ratio: 1 / 1 killed' (exit $_good_rc)"
    printf '%s\n' "$_good_out" | sed 's/^/         | /' | tail -8
  fi
  _tooth_out="$("$HARNESS" --class C-erc4626 --invariant "$MUTANTS_DIR/C-erc4626/inv_toothless.t.sol" 2>&1)"; _tooth_rc=$?
  if [ "$_tooth_rc" -eq 0 ] && printf '%s' "$_tooth_out" | grep -q 'kill ratio: 0 / 1 killed'; then
    ok "toothless invariant x C-erc4626: kill ratio 0 / 1 killed (K==0, survivor -> toothless)"
  else
    bad "toothless invariant x C-erc4626 did not report 'kill ratio: 0 / 1 killed' (exit $_tooth_rc)"
    printf '%s\n' "$_tooth_out" | sed 's/^/         | /' | tail -8
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #1728 teeth-signal is wired — invariant-prover.ag runs mutant-kill.sh --class/--invariant in ONE"
  note "      shell_escape()d exec on a CLEAN ONLY, strictly AFTER the fuzzer's INVARIANT| marker; classifies the"
  note "      CLEAN into credible (persist to the NEW invpat:teeth: recall tier + partial learn) / toothless /"
  note "      unmeasured with flat builtins; recall precedence stays FINDING > teeth > invented; the FINDING ->"
  note "      invpat:latest: path, the verdict/marker, and the #1471 gate are byte-untouched; and the runner"
  note "      stages the kill-set + threads MUTANT_KILL. (The live kill ratios are the fuzzer's — run under forge.)"
  exit 0
fi
note "DEMO FAILED — a #1728 teeth-signal assertion did not hold" >&2
exit 1
