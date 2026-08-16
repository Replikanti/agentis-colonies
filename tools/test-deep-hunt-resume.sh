#!/usr/bin/env bash
# tools/test-deep-hunt-resume.sh -- deterministic offline guard for #1934 (dark-factory):
# deep-hunt idempotent skip-completed, gated behind --deep-hunt-resume.
#
# STAGE 4.5 of run-zone-hunt.sh loops over (zone, class) rows and unconditionally
# re-invokes run-invariant-hunt.sh for each -- re-running a deep-hunt therefore redoes
# every already-settled (CLEAN/FINDING) zone. #1934 adds a default-OFF
# `--deep-hunt-resume` flag: when set, a row whose $DZOUT/run already holds a TERMINAL
# lens verdict (an aggregate `invariant_*.log` -- never a per-candidate `_c<N>.log` --
# carrying an `INVARIANT|...|CLEAN` or `INVARIANT|...|FINDING` line) is skipped instead
# of re-run. A HARNESS_ERROR / interrupted lens (no terminal verdict line) is NOT
# skipped -- it is a gap and re-runs, same as a never-reached row.
#
# Pure bash/grep over the runner source plus the extracted skip-predicate for-loop --
# no agentis runtime, no LLM, no forge, no network. Auto-discovered and run by
# tools/colony-lint.sh's `tools/test-*.sh` loop.
#
# Assertions:
#   (a) SOURCE GUARD: the runner declares DEEP_HUNT_RESUME=0 (default OFF), parses
#       `--deep-hunt-resume`, and the STAGE 4.5 skip guard is gated on
#       `[ "$DEEP_HUNT_RESUME" = 1 ]`. Also: the skip path logs + `continue`s, and the
#       terminal-verdict grep excludes per-candidate `_c<N>.log` files.
#   (b) PREDICATE: the extracted skip-predicate for-loop (same code the runner ships,
#       not a re-implementation), evaluated against small fixture $DZOUT/run dirs:
#         - an aggregate log with INVARIANT|...|CLEAN            -> terminal (skip)
#         - an aggregate log with INVARIANT|...|FINDING          -> terminal (skip)
#         - an aggregate log with INVARIANT|...|HARNESS_ERROR    -> NOT terminal (re-run)
#         - no aggregate log at all (missing $DZOUT/run)          -> NOT terminal (re-run)
#         - a terminal verdict present ONLY in a per-candidate `_c1.log` (the aggregate
#           itself is HARNESS_ERROR)                              -> NOT terminal (re-run)
#
# Usage: bash tools/test-deep-hunt-resume.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$REPO_ROOT/dark-factory/run-zone-hunt.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

summary_exit() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
}

if [ ! -f "$RUNNER" ]; then
    fail "runner exists" "$RUNNER not found"
    summary_exit
fi

run_src="$(cat "$RUNNER")"

# (a) source guard: default declaration, flag parse, gate condition, skip-log + continue,
# and the per-candidate exclusion in the terminal-verdict grep.
a_fail=""
printf '%s\n' "$run_src" | grep -Fq 'DEEP_HUNT_RESUME=0' \
    || a_fail="${a_fail} no-default"
printf '%s\n' "$run_src" | grep -Fq -- '--deep-hunt-resume) DEEP_HUNT_RESUME=1; shift ;;' \
    || a_fail="${a_fail} no-parse"
# shellcheck disable=SC2016  # matching the literal guard-condition line, $ must not expand
printf '%s\n' "$run_src" | grep -Fq 'if [ "$DEEP_HUNT_RESUME" = 1 ] && [ -d "$DZOUT/run" ]; then' \
    || a_fail="${a_fail} not-gated"
printf '%s\n' "$run_src" | grep -Fq -- "already hunted (terminal verdict), skipping [--deep-hunt-resume]" \
    || a_fail="${a_fail} no-skip-log"
# shellcheck disable=SC2016  # matching the literal case-arm, $ must not expand
printf '%s\n' "$run_src" | grep -Fq '*_c[0-9]*.log) continue ;;' \
    || a_fail="${a_fail} no-per-candidate-exclusion"
# shellcheck disable=SC2016  # matching the literal grep pattern, $ must not expand
printf '%s\n' "$run_src" | grep -Fq 'INVARIANT\|[^|]*\|(CLEAN|FINDING)([[:space:]]|$)' \
    || a_fail="${a_fail} no-terminal-verdict-pattern"

if [ -z "$a_fail" ]; then
    pass "(a) runner declares DEEP_HUNT_RESUME default OFF, parses --deep-hunt-resume, gates the skip guard, and logs+continues on a terminal verdict"
else
    fail "(a) runner wires --deep-hunt-resume into the STAGE 4.5 skip guard" \
         "missing piece(s):$a_fail"
fi

# Extract the live skip-predicate for-loop verbatim (from the `_dhr_terminal=0` init
# through its closing `done`) so the behavioural assertions below exercise the SAME
# code the runner ships, same technique test-invariant-hunt-composable-timeout.sh uses.
PREDICATE_BLOCK="$(awk '
  /^        _dhr_terminal=0$/ { f=1 }
  f { print }
  f && /^        done$/ { exit }
' "$RUNNER")"

if [ -z "$PREDICATE_BLOCK" ]; then
    fail "skip-predicate block extracted" "no '_dhr_terminal=0 ... done' for-loop in the runner"
    summary_exit
fi

# Run the extracted block in a subshell with DZOUT pointed at a fixture dir, then print
# the resulting _dhr_terminal (0 = re-run, 1 = skip).
predicate_for() {  # $1 = DZOUT (a directory, need not have a run/ subdir)
    # shellcheck disable=SC2034  # DZOUT is read by PREDICATE_BLOCK via eval below, invisible to shellcheck
    # shellcheck disable=SC2154  # _dhr_terminal is set by PREDICATE_BLOCK via eval below, invisible to shellcheck
    ( DZOUT="$1"; eval "$PREDICATE_BLOCK"; printf '%s\n' "$_dhr_terminal" )
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

b_fail=""

# CLEAN aggregate -> terminal (skip)
d="$WORK/clean"; mkdir -p "$d/run"
printf 'INVARIANT|Foo.sol|CLEAN\n' > "$d/run/invariant_Foo.log"
got="$(predicate_for "$d")"
[ "$got" = "1" ] || b_fail="${b_fail} clean-got-${got}-want-1"

# FINDING aggregate -> terminal (skip)
d="$WORK/finding"; mkdir -p "$d/run"
printf 'STEP|withdraw()\nINVARIANT|Bar.sol|FINDING\n' > "$d/run/invariant_Bar.log"
got="$(predicate_for "$d")"
[ "$got" = "1" ] || b_fail="${b_fail} finding-got-${got}-want-1"

# HARNESS_ERROR aggregate (no CLEAN/FINDING verdict) -> NOT terminal (re-run)
d="$WORK/harness-error"; mkdir -p "$d/run"
printf 'INVARIANT|Baz.sol|HARNESS_ERROR\n' > "$d/run/invariant_Baz.log"
got="$(predicate_for "$d")"
[ "$got" = "0" ] || b_fail="${b_fail} harness-error-got-${got}-want-0"

# missing $DZOUT/run entirely -> NOT terminal (re-run)
d="$WORK/missing"
got="$(predicate_for "$d")"
[ "$got" = "0" ] || b_fail="${b_fail} missing-run-got-${got}-want-0"

# terminal verdict present ONLY in a per-candidate _c1.log; the aggregate itself is
# HARNESS_ERROR -> NOT terminal (the guard must read the aggregate, never a candidate)
d="$WORK/candidate-only"; mkdir -p "$d/run"
printf 'INVARIANT|Qux.sol|HARNESS_ERROR\n' > "$d/run/invariant_Qux.log"
printf 'INVARIANT|Qux.sol|CLEAN\n' > "$d/run/invariant_Qux_c1.log"
got="$(predicate_for "$d")"
[ "$got" = "0" ] || b_fail="${b_fail} candidate-only-got-${got}-want-0"

if [ -z "$b_fail" ]; then
    pass "(b) skip-predicate: CLEAN/FINDING aggregate -> terminal; HARNESS_ERROR/missing/candidate-only -> not terminal"
else
    fail "(b) skip-predicate terminal-verdict selection" \
         "mismatch(es):$b_fail"
fi

summary_exit
