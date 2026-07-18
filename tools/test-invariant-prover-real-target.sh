#!/usr/bin/env bash
# tools/test-invariant-prover-real-target.sh -- deterministic regression
# guard for #1070-B1 (dark-factory). The dark-factory invariant-prover used
# to tell the model: "Import the target from `../src/...` if the project
# ships it there; otherwise inline a minimal copy." On a realistically-sized
# target the model frequently inlined a MOCK of the unit under test and
# fuzzed the mock, so the FUZZER's verdict was about fake code, not the real
# contract. The fix turns that bullet into a STRONG real-target directive
# (IMPORT and DEPLOY the REAL contract; a mock of an EXTERNAL dependency is
# fine, the unit under test must be the real imported contract), adds an
# ERC1967Proxy upgradeable-deploy recipe, and INJECTS the exact relative
# import path (CODE_PATH relative to dirname(INV_OUT), via
# `realpath --relative-to`) so the model can wire the import correctly.
#
# This test pins that real-target directive so it cannot silently regress to
# the import-or-inline-a-mock phrasing. Pure grep/awk over the .ag source —
# no agentis runtime, no LLM, no forge required. Auto-discovered and run by
# tools/colony-lint.sh's `tools/test-*.sh` loop.
#
# Assertions:
#   (a) The `generate_test()` instruction now DIRECTS importing + deploying
#       the REAL target ("IMPORT and DEPLOY the REAL target" + "do NOT inline
#       a mock copy of it").
#   (b) The `generate_test()` instruction no longer tells the model to
#       "inline a minimal copy" of the target (the old import-or-inline
#       bullet is gone).
#   (c) The ERC1967Proxy upgradeable-deploy guidance is present (the proxy
#       import + `_disableInitializers` recipe).
#   (d) The import-path injection is present: the `realpath --relative-to`
#       computation in the agent AND the injected `import {<Name>} from
#       "<RELPATH>"` instruction line.
#
# Usage: bash tools/test-invariant-prover-real-target.sh

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

# Extract the STATIC generation instruction. Since #1720 it is factored out of
# generate_test() into the module-level `harness_skeleton()` (the canonical
# compiling skeleton) + the `sharedScaffold` string (the requirement paragraphs
# + bug-class lens + answer contract); generate_test appends sharedScaffold and
# the compile-repair chain re-injects it. Capture BOTH blocks so the import/deploy
# directive assertions scope to that instruction and never to doc comments.
gen_body="$(awk '/^fn harness_skeleton\(/{f=1} f{print} f&&/^}/{f=0}' "$AG"; awk '/^let sharedScaffold/{f=1} f{print} f&&/;[[:space:]]*$/{f=0}' "$AG")"

if [ -z "$gen_body" ]; then
    fail "generate_test body found" "no 'fn generate_test(...)' block in $AG"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# (a) The instruction must DIRECT importing + deploying the REAL target.
if printf '%s\n' "$gen_body" | grep -Fq 'IMPORT and DEPLOY the REAL target' \
   && printf '%s\n' "$gen_body" | grep -Fq 'do NOT inline a mock copy of it'; then
    pass "(a) generate_test directs importing + deploying the REAL target"
else
    fail "(a) generate_test directs importing + deploying the REAL target" \
         "missing the 'IMPORT and DEPLOY the REAL target' + 'do NOT inline a mock copy of it' directive"
fi

# (b) The old import-or-inline-a-mock bullet must be GONE: the model must not
# be told it may "inline a minimal copy" of the target.
if printf '%s\n' "$gen_body" | grep -Fq 'otherwise inline a minimal'; then
    fail "(b) generate_test no longer offers the inline-a-mock fallback" \
         "found the old 'otherwise inline a minimal copy' directive in the instruction"
else
    pass "(b) generate_test no longer offers the inline-a-mock fallback"
fi

# (c) The ERC1967Proxy upgradeable-deploy guidance must be present.
if printf '%s\n' "$gen_body" | grep -Fq 'ERC1967Proxy' \
   && printf '%s\n' "$gen_body" | grep -Fq '_disableInitializers'; then
    pass "(c) generate_test carries the ERC1967Proxy upgradeable-deploy guidance"
else
    fail "(c) generate_test carries the ERC1967Proxy upgradeable-deploy guidance" \
         "missing the ERC1967Proxy proxy-deploy recipe for _disableInitializers upgradeable targets"
fi

# (d) The import-path injection must be present: both the `realpath
# --relative-to` computation in the agent (CODE_PATH relative to
# dirname(INV_OUT)) and the injected `import {<Name>} from "<RELPATH>"` line.
ip_fail=""
grep -Fq 'realpath --relative-to' "$AG" \
    || ip_fail="${ip_fail} relpath-compute"
grep -Fq 'Import the target with: import {' "$AG" \
    || ip_fail="${ip_fail} import-path-line"

if [ -z "$ip_fail" ]; then
    pass "(d) generate_test injects the computed relative import path"
else
    fail "(d) generate_test injects the computed relative import path" \
         "missing import-path piece(s):$ip_fail"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
