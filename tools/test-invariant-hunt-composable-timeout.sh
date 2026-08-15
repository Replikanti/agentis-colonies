#!/usr/bin/env bash
# tools/test-invariant-hunt-composable-timeout.sh -- deterministic regression guard
# for #1915 (dark-factory). Composable-fresh generation (INV_AUX non-empty) asks the
# model to deploy+wire the target AND every --aux contract in ONE prompt -- observed
# live to blow the flat 600s `llm.cli_timeout_ms` budget that was sized for a single-
# target discovery-style read (both on the initial call and agentis-core's retry,
# which re-issues the SAME prompt against the SAME budget -- no rescue). The fix
# computes a GEN_TIMEOUT_MS value (600s base + 600s per staged aux contract, capped
# at 1_800_000ms) and wires it into BOTH backend config branches; INV_AUX empty (no
# --aux) stays 600000 => byte-identical single-target path. exec.default_timeout_ms
# (the forge-run budget) is intentionally left unscaled -- the observed failure is
# generation-side, not forge-run-side.
#
# Pure bash/awk/grep over the runner -- no agentis runtime, no LLM, no forge
# required. Auto-discovered and run by tools/colony-lint.sh's `tools/test-*.sh` loop.
#
# Assertions:
#   (a) The runner defines the GEN_TIMEOUT_MS base/scale/cap computation AND wires
#       it into BOTH the claude-branch and flat-cyborg-branch `cli_timeout_ms` lines
#       (not a bare 600000 literal).
#   (b) The extracted GEN_TIMEOUT_MS computation, executed with stubbed INV_AUX /
#       _aux_idx, yields: 600000 (INV_AUX empty, byte-identical single-target case);
#       1200000 (_aux_idx=1); 1800000 (_aux_idx=2, cap boundary); 1800000
#       (_aux_idx=5, cap holds -- doesn't grow unboundedly).
#   (c) exec.default_timeout_ms = 600000 is still a bare literal (intentionally
#       unscaled per this plan).
#
# Usage: bash tools/test-invariant-hunt-composable-timeout.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$REPO_ROOT/dark-factory/run-invariant-hunt.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

summary_exit() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    if [ "$FAIL" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

if [ ! -f "$RUNNER" ]; then
    fail "runner exists" "$RUNNER not found"
    summary_exit
fi

run_src="$(cat "$RUNNER")"

# (a) The runner defines the GEN_TIMEOUT_MS base/scale/cap lines AND wires the
# variable into BOTH backend branches' cli_timeout_ms line (a pre-change bare
# `llm.cli_timeout_ms = 600000` literal on either branch fails here).
a_fail=""
printf '%s\n' "$run_src" | grep -Fq 'GEN_TIMEOUT_MS=600000' \
    || a_fail="${a_fail} no-base"
# shellcheck disable=SC2016  # matching the literal assignment line, $ must not expand
printf '%s\n' "$run_src" | grep -Fq 'GEN_TIMEOUT_MS=$((600000 + 600000 * _aux_idx))' \
    || a_fail="${a_fail} no-scale"
# shellcheck disable=SC2016  # matching the literal cap-guard line, $ must not expand
printf '%s\n' "$run_src" | grep -Fq '[ "$GEN_TIMEOUT_MS" -gt 1800000 ] && GEN_TIMEOUT_MS=1800000' \
    || a_fail="${a_fail} no-cap"
# shellcheck disable=SC2016  # matching the literal echo line, $ must not expand
_gen_wired_count="$(printf '%s\n' "$run_src" | grep -Fc 'echo "llm.cli_timeout_ms = $GEN_TIMEOUT_MS"' || true)"
if [ "${_gen_wired_count:-0}" -lt 2 ]; then
    a_fail="${a_fail} not-wired-into-both-branches(found=${_gen_wired_count:-0}-want=2)"
fi
printf '%s\n' "$run_src" | grep -Fq 'BACKEND" = "claude"' \
    || a_fail="${a_fail} no-claude-branch"
printf '%s\n' "$run_src" | grep -Fq 'BACKEND" = "flat-cyborg"' \
    || a_fail="${a_fail} no-flat-cyborg-branch"

if [ -z "$a_fail" ]; then
    pass "(a) runner computes GEN_TIMEOUT_MS (base/scale/cap) and wires it into both backend branches"
else
    fail "(a) runner wires GEN_TIMEOUT_MS into both backend config branches" \
         "missing piece(s):$a_fail"
fi

# Extract the live GEN_TIMEOUT_MS computation block verbatim (from the assignment
# line through the closing `fi`) so the behavioural assertions exercise the SAME
# code the runner ships (not a re-implementation), same technique the slim-source
# test uses on slim_sol_source().
GEN_BLOCK="$(awk '
  /^GEN_TIMEOUT_MS=600000$/ { f=1 }
  f { print }
  f && /^fi$/ { exit }
' "$RUNNER")"

if [ -z "$GEN_BLOCK" ]; then
    fail "GEN_TIMEOUT_MS block extracted" "no 'GEN_TIMEOUT_MS=600000 ... fi' block in the runner"
    summary_exit
fi

# Run the extracted block in a subshell with INV_AUX / _aux_idx stubbed, then
# print the resulting GEN_TIMEOUT_MS.
compute_gen_timeout() {  # $1 = INV_AUX value, $2 = _aux_idx value
    # shellcheck disable=SC2034  # INV_AUX is read by GEN_BLOCK via eval below, invisible to shellcheck
    ( INV_AUX="$1"; _aux_idx="$2"; eval "$GEN_BLOCK"; printf '%s\n' "$GEN_TIMEOUT_MS" )
}

b_fail=""

got="$(compute_gen_timeout "" 0)"
[ "$got" = "600000" ] || b_fail="${b_fail} empty-INV_AUX-got-${got}-want-600000"

got="$(compute_gen_timeout "x" 1)"
[ "$got" = "1200000" ] || b_fail="${b_fail} aux1-got-${got}-want-1200000"

got="$(compute_gen_timeout "x" 2)"
[ "$got" = "1800000" ] || b_fail="${b_fail} aux2-cap-got-${got}-want-1800000"

got="$(compute_gen_timeout "x" 5)"
[ "$got" = "1800000" ] || b_fail="${b_fail} aux5-cap-holds-got-${got}-want-1800000"

if [ -z "$b_fail" ]; then
    pass "(b) GEN_TIMEOUT_MS computes 600000 (empty)/1200000 (aux=1)/1800000 (aux=2, cap)/1800000 (aux=5, cap holds)"
else
    fail "(b) GEN_TIMEOUT_MS base/scale/cap values" \
         "mismatch(es):$b_fail"
fi

# (c) exec.default_timeout_ms is still a bare, unscaled literal.
if printf '%s\n' "$run_src" | grep -Fq 'echo "exec.default_timeout_ms = 600000"'; then
    pass "(c) exec.default_timeout_ms = 600000 is still a bare literal (intentionally unscaled)"
else
    fail "(c) exec.default_timeout_ms unscaled" \
         "exec.default_timeout_ms = 600000 literal not found (unexpected change to the forge-run budget)"
fi

summary_exit
