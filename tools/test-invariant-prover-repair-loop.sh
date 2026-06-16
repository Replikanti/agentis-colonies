#!/usr/bin/env bash
# tools/test-invariant-prover-repair-loop.sh -- deterministic regression
# guard for #1073 (dark-factory). With #1069 harness-isolation, a
# HARNESS_ERROR (forge exit code not in {0,1}) on the LLM-generated path means
# OUR generated handler did NOT compile / matched no `invariant_*` -- a
# recoverable fault, not the target's other tests. The prover used to do ONE
# shot: generate -> write -> run the gate -> map the exit code to a verdict; a
# single bad first generation wasted the whole run. #1073 adds a BOUNDED
# compile-repair loop: on a HARNESS_ERROR the prover feeds forge's compiler
# error back to the model and regenerates, up to N EXTRA rounds, stopping the
# moment the gate returns a real verdict (FINDING/CLEAN). The verbatim
# HANDLER_FIXTURE path is NEVER LLM-repaired, and the FINAL verdict stays the
# gate's exit code on the LAST attempt -- never the LLM's opinion.
#
# This test pins that loop so it cannot silently regress to the one-shot
# behaviour. Pure grep/awk over the .ag source -- no agentis runtime, no LLM,
# no forge required. Auto-discovered and run by tools/colony-lint.sh's
# `tools/test-*.sh` loop.
#
# Assertions:
#   (a) A bounded repair loop exists, keyed on HARNESS_ERROR: there is a
#       `repair_loop()` bounded by a decrementing `remaining` counter (no
#       `while`/`for` in single-assignment .ag) whose round body
#       (`repair_step()`) only fires while the carried `stopped` flag is "0"
#       (i.e. the prior attempt was a HARNESS_ERROR, not a verdict).
#   (b) The bound comes from INV_REPAIR_ROUNDS with a default: a
#       `repair_rounds()` helper reads `getenv("INV_REPAIR_ROUNDS")` and
#       returns the default 2 on empty/non-numeric input.
#   (c) The repair re-`prompt()`s with the compiler error + the prior source:
#       a `repair_instruction()` carries the "did NOT compile" framing, an
#       `error_excerpt` of forge's output, and the prior test source, and
#       `repair_test()` feeds it to `prompt()`.
#   (d) FINDING/CLEAN short-circuit (no repair): `stop_flag()` flips the
#       carried `stopped` to "1" on rc 1 (FINDING) or rc 0 (CLEAN), and both
#       `repair_loop()` and `repair_step()` are no-ops once stopped.
#   (e) The fixture path is excluded from repair: the loop seeds `stopped`
#       to "1" when `usedFixture` (the operator fixture is authoritative and
#       must never be LLM-repaired).
#
# Usage: bash tools/test-invariant-prover-repair-loop.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AG="$REPO_ROOT/dark-factory/auditor/agents/invariant-prover.ag"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$AG" ]; then
    fail "ag exists" "$AG not found"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Whole-file source (the loop spans several top-level helpers + the driver).
src="$(cat "$AG")"

# (a) A bounded repair loop keyed on HARNESS_ERROR. The loop is a recursive
# `repair_loop(...)` bounded by a decrementing `remaining` counter, and its
# per-round body `repair_step(...)` only acts while the carried `stopped`
# field is "0" (a prior HARNESS_ERROR). Assert the recursion, the
# `remaining - 1` decrement, the `remaining <= 0` floor, and the
# `rstate_field(acc, 0) == "1"` stop guard.
a_fail=""
printf '%s\n' "$src" | grep -Eq 'fn[[:space:]]+repair_loop\(' \
    || a_fail="${a_fail} no-repair_loop"
printf '%s\n' "$src" | grep -Eq 'fn[[:space:]]+repair_step\(' \
    || a_fail="${a_fail} no-repair_step"
printf '%s\n' "$src" | grep -Fq 'repair_loop(next, remaining - 1' \
    || a_fail="${a_fail} no-bounded-recursion"
printf '%s\n' "$src" | grep -Fq 'if remaining <= 0' \
    || a_fail="${a_fail} no-remaining-floor"
printf '%s\n' "$src" | grep -Fq 'rstate_field(acc, 0) == "1"' \
    || a_fail="${a_fail} no-stop-guard"

if [ -z "$a_fail" ]; then
    pass "(a) a bounded repair loop exists, keyed on the HARNESS_ERROR (stopped=0) state"
else
    fail "(a) a bounded repair loop exists" \
         "missing piece(s):$a_fail"
fi

# (b) The bound comes from INV_REPAIR_ROUNDS with a default. A
# `repair_rounds()` helper reads getenv("INV_REPAIR_ROUNDS") and returns the
# default 2 on empty/non-numeric input.
b_fail=""
printf '%s\n' "$src" | grep -Eq 'fn[[:space:]]+repair_rounds\(' \
    || b_fail="${b_fail} no-repair_rounds"
printf '%s\n' "$src" | grep -Fq 'getenv("INV_REPAIR_ROUNDS")' \
    || b_fail="${b_fail} no-env-read"
# The default must be 2 for BOTH the empty case and the non-numeric case.
printf '%s\n' "$src" | grep -Fq 'if len(raw) == 0 { return 2; }' \
    || b_fail="${b_fail} no-empty-default"
printf '%s\n' "$src" | grep -Fq 'regex_find_all("[^0-9]", raw)' \
    || b_fail="${b_fail} no-numeric-guard"

if [ -z "$b_fail" ]; then
    pass "(b) the repair bound comes from INV_REPAIR_ROUNDS with a default of 2"
else
    fail "(b) the repair bound comes from INV_REPAIR_ROUNDS with a default" \
         "missing piece(s):$b_fail"
fi

# (c) The repair re-prompt()s with the compiler error + prior source. A
# `repair_instruction()` carries the "did NOT compile" framing, an
# `error_excerpt` of forge's output, and the prior source; `repair_test()`
# feeds it to prompt().
c_fail=""
printf '%s\n' "$src" | grep -Eq 'fn[[:space:]]+repair_instruction\(' \
    || c_fail="${c_fail} no-repair_instruction"
printf '%s\n' "$src" | grep -Fq 'did NOT compile' \
    || c_fail="${c_fail} no-compile-framing"
printf '%s\n' "$src" | grep -Eq 'fn[[:space:]]+error_excerpt\(' \
    || c_fail="${c_fail} no-error_excerpt"
printf '%s\n' "$src" | grep -Fq 'Your previous test was:' \
    || c_fail="${c_fail} no-prior-source"
# repair_test() must route the repair instruction through prompt().
awk '/^fn repair_test\(/{f=1} f{print} f&&/^}/{exit}' "$AG" \
    | grep -Fq 'prompt(repair_instruction(' \
    || c_fail="${c_fail} no-repair-prompt"

if [ -z "$c_fail" ]; then
    pass "(c) the repair re-prompt()s with the compiler-error excerpt + the prior test source"
else
    fail "(c) the repair re-prompt()s with the compiler error + prior source" \
         "missing piece(s):$c_fail"
fi

# (d) FINDING/CLEAN short-circuit (no repair). `stop_flag()` flips stopped to
# "1" on rc 1 (FINDING) and rc 0 (CLEAN); both the loop and the step are
# no-ops once stopped.
d_fail=""
printf '%s\n' "$src" | grep -Eq 'fn[[:space:]]+stop_flag\(' \
    || d_fail="${d_fail} no-stop_flag"
# stop_flag must map BOTH terminal exit codes to the stop state.
awk '/^fn stop_flag\(/{f=1} f{print} f&&/^}/{exit}' "$AG" \
    | grep -Fq 'if rc == 1 { return "1"; }' \
    || d_fail="${d_fail} no-finding-stop"
awk '/^fn stop_flag\(/{f=1} f{print} f&&/^}/{exit}' "$AG" \
    | grep -Fq 'if rc == 0 { return "1"; }' \
    || d_fail="${d_fail} no-clean-stop"
# repair_step must short-circuit once stopped.
awk '/^fn repair_step\(/{f=1} f{print} f&&/^}/{exit}' "$AG" \
    | grep -Fq 'if rstate_field(acc, 0) == "1" { return acc; }' \
    || d_fail="${d_fail} no-step-shortcircuit"

if [ -z "$d_fail" ]; then
    pass "(d) a FINDING/CLEAN verdict short-circuits the loop (no repair after a real verdict)"
else
    fail "(d) a FINDING/CLEAN verdict short-circuits the loop" \
         "missing piece(s):$d_fail"
fi

# (e) The fixture path is excluded from repair. The loop seeds the carried
# `stopped` flag to "1" when `usedFixture`, so the operator fixture is never
# LLM-repaired regardless of its exit code.
if printf '%s\n' "$src" | grep -Fq 'let initStopped = if usedFixture { "1" } else { firstStop };'; then
    pass "(e) the verbatim HANDLER_FIXTURE path is excluded from LLM repair (seeded stopped=1)"
else
    fail "(e) the verbatim HANDLER_FIXTURE path is excluded from repair" \
         "no 'usedFixture -> stopped=1' seed found; an operator fixture could be LLM-repaired"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
