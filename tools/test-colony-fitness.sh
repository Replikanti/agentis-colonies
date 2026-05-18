#!/bin/bash
# tools/test-colony-fitness.sh -- unit tests for the generalised
# colony-fitness.py introduced in Phase 9 PR-B of #663.
#
# Asserts:
#   1. --colony explorer is byte-identical to explorer-fitness.py (the
#      back-compat shim must preserve the Phase 3 PR 2 contract).
#   2. --colony noticer (discovery side) returns a valid scalar.
#   3. --colony auditor (audit side) returns a valid scalar.
#   4. --colony submitter (preprint side) returns a valid scalar.
#   5. Bash syntax is clean (no bash file here, but lint the Python via
#      `python3 -c 'import py_compile; py_compile.compile(...)'`).
#
# Standard library only; no live federation needed -- the helper
# silently degrades to all-default scores when no experience .jsonl
# files exist.
#
# Usage: bash tools/test-colony-fitness.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLONY_FITNESS="$SCRIPT_DIR/colony-fitness.py"
EXPLORER_FITNESS="$SCRIPT_DIR/explorer-fitness.py"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -x "$COLONY_FITNESS" ]; then
    fail "colony-fitness.py executable" "$COLONY_FITNESS not executable"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/.agentis/experience" "$WORK_DIR/.agentis/memo"

# Test 0: py_compile both files so a syntax error is loud.
if python3 -c "import py_compile, sys; py_compile.compile(sys.argv[1], doraise=True); py_compile.compile(sys.argv[2], doraise=True)" \
        "$COLONY_FITNESS" "$EXPLORER_FITNESS" 2>/dev/null; then
    pass "py_compile clean"
else
    fail "py_compile clean" "$(python3 -c "import py_compile, sys; py_compile.compile(sys.argv[1], doraise=True); py_compile.compile(sys.argv[2], doraise=True)" "$COLONY_FITNESS" "$EXPLORER_FITNESS" 2>&1)"
fi

# Test 1: explorer-fitness.py shim produces byte-identical output to
# colony-fitness.py --colony explorer.
SHIM_OUT="$(python3 "$EXPLORER_FITNESS" "$WORK_DIR" 1 nonexistent-agent 2>&1)"
DIRECT_OUT="$(python3 "$COLONY_FITNESS" "$WORK_DIR" 1 nonexistent-agent --colony explorer 2>&1)"

if [ "$SHIM_OUT" = "$DIRECT_OUT" ]; then
    pass "1. explorer-fitness.py shim byte-identical to colony-fitness.py --colony explorer"
else
    fail "1. explorer-fitness.py shim byte-identical to colony-fitness.py --colony explorer" \
        "shim=<$SHIM_OUT> direct=<$DIRECT_OUT>"
fi

# Also assert the explorer output shape preserves the Phase 3 PR 2
# contract: top-level {fitness_score, breakdown} only -- no `side` /
# `colony` keys that would break the dashboard's pre-PR-B reader.
EXP_SHAPE_OK="$(python3 -c "
import json, sys
payload = json.loads(sys.argv[1])
required = {'fitness_score', 'breakdown'}
extra = set(payload.keys()) - required
if extra:
    print('FAIL_EXTRA %r' % sorted(extra))
elif not required.issubset(payload.keys()):
    print('FAIL_MISSING %r' % sorted(required - set(payload.keys())))
else:
    print('ok')
" "$DIRECT_OUT" 2>&1)"
if [ "$EXP_SHAPE_OK" = "ok" ]; then
    pass "1b. explorer output shape preserved (no side/colony keys leaked)"
else
    fail "1b. explorer output shape preserved (no side/colony keys leaked)" "$EXP_SHAPE_OK"
fi

# Test 2: --colony noticer returns a valid scalar with discovery-side
# breakdown.
NOTICER_OUT="$(python3 "$COLONY_FITNESS" "$WORK_DIR" 2 nonexistent-noticer --colony noticer 2>&1)"
NOTICER_OK="$(python3 -c "
import json, sys
p = json.loads(sys.argv[1])
score = p.get('fitness_score')
side = p.get('side')
colony = p.get('colony')
if not isinstance(score, (int, float)):
    print('FAIL_SCORE')
elif side != 'discovery':
    print('FAIL_SIDE got=%r' % side)
elif colony != 'noticer':
    print('FAIL_COLONY got=%r' % colony)
else:
    print('ok score=%s' % score)
" "$NOTICER_OUT" 2>&1)"
case "$NOTICER_OK" in
    "ok"*)
        pass "2. --colony noticer returns a valid scalar"
        ;;
    *)
        fail "2. --colony noticer returns a valid scalar" "$NOTICER_OK from $NOTICER_OUT"
        ;;
esac

# Test 3: --colony auditor returns a valid scalar with audit-side
# breakdown.
AUDITOR_OUT="$(python3 "$COLONY_FITNESS" "$WORK_DIR" 3 nonexistent-auditor --colony auditor 2>&1)"
AUDITOR_OK="$(python3 -c "
import json, sys
p = json.loads(sys.argv[1])
score = p.get('fitness_score')
side = p.get('side')
colony = p.get('colony')
breakdown = p.get('breakdown') or {}
if not isinstance(score, (int, float)):
    print('FAIL_SCORE')
elif side != 'audit':
    print('FAIL_SIDE got=%r' % side)
elif colony != 'auditor':
    print('FAIL_COLONY got=%r' % colony)
elif 'hitl_upheld_rate' not in breakdown:
    print('FAIL_BREAKDOWN keys=%r' % sorted(breakdown.keys()))
else:
    print('ok score=%s' % score)
" "$AUDITOR_OUT" 2>&1)"
case "$AUDITOR_OK" in
    "ok"*)
        pass "3. --colony auditor returns a valid scalar"
        ;;
    *)
        fail "3. --colony auditor returns a valid scalar" "$AUDITOR_OK from $AUDITOR_OUT"
        ;;
esac

# Test 4: --colony submitter returns a valid scalar with preprint-side
# breakdown, including the submitter-only `submitter_multiplier` field.
SUB_OUT="$(python3 "$COLONY_FITNESS" "$WORK_DIR" 4 nonexistent-submitter --colony submitter 2>&1)"
SUB_OK="$(python3 -c "
import json, sys
p = json.loads(sys.argv[1])
score = p.get('fitness_score')
side = p.get('side')
colony = p.get('colony')
breakdown = p.get('breakdown') or {}
if not isinstance(score, (int, float)):
    print('FAIL_SCORE')
elif side != 'preprint':
    print('FAIL_SIDE got=%r' % side)
elif colony != 'submitter':
    print('FAIL_COLONY got=%r' % colony)
elif 'submitter_multiplier' not in breakdown:
    print('FAIL_BREAKDOWN keys=%r' % sorted(breakdown.keys()))
else:
    print('ok score=%s' % score)
" "$SUB_OUT" 2>&1)"
case "$SUB_OK" in
    "ok"*)
        pass "4. --colony submitter returns a valid scalar"
        ;;
    *)
        fail "4. --colony submitter returns a valid scalar" "$SUB_OK from $SUB_OUT"
        ;;
esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
