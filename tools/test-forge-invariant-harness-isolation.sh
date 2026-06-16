#!/usr/bin/env bash
# Regression guard for #1069: forge-invariant.sh must compile the generated harness in ISOLATION from
# the target project's OWN test files, so a target whose own *.t.sol do not compile (solc drift) cannot
# degrade a self-contained harness to a false HARNESS_ERROR. Deterministic (grep over the script; no
# forge, no LLM). Asserts the --skip-other-tests logic is present and wired into the forge args.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FI="$HERE/../dark-factory/evm-harness/forge-invariant.sh"
fail=0
pass()  { printf '  ok   %s\n' "$1"; }
bad()   { printf '  FAIL %s\n' "$1"; fail=1; }
check() { if grep -qE "$1" "$FI"; then pass "$2"; else bad "$2"; fi; }

[ -f "$FI" ] || { echo "forge-invariant.sh not found at $FI"; exit 1; }

check 'SKIP_ARGS=\(\)'           "SKIP_ARGS array declared"
check 'find .*REPO/test'         "enumerates the target test dir"
check 'harness_abs'              "excludes the harness from the skip set"
check 'SKIP_ARGS\+=\(--skip'     "appends --skip per other test file"
check 'ARGS=\(test .*SKIP_ARGS'  "SKIP_ARGS wired into the forge ARGS"

if [ "$fail" -eq 0 ]; then
  echo "test-forge-invariant-harness-isolation: all assertions passed"; exit 0
else
  echo "test-forge-invariant-harness-isolation: FAILED"; exit 1
fi
