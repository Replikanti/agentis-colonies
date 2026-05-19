#!/bin/bash
# research-foundry/tools/test-colony-variants.sh -- unit tests for the
# source-of-truth colony-variants.json table introduced in Phase 9
# PR-B of #663.
#
# Asserts:
#   1. JSON parses
#   2. Every colony has 5 variants + 5 overlays
#   3. All 18 colonies enumerated
#   4. Every overlay is non-empty
#
# Standard library only -- no pytest. Mirrors the shape of
# tools/test-cull-replicas.sh.
#
# Usage: bash research-foundry/tools/test-colony-variants.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VARIANTS="$SCRIPT_DIR/colony-variants.json"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$VARIANTS" ]; then
    fail "colony-variants.json exists" "$VARIANTS not found"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Test 1: JSON parses.
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$VARIANTS" 2>/dev/null; then
    pass "1. JSON parses"
else
    fail "1. JSON parses" "$(python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$VARIANTS" 2>&1)"
fi

# Tests 2-4: 18 colonies, 5 variants each, 5 non-empty overlays each.
PY_OUT="$(python3 -c "
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

EXPECTED = {
    'explorer', 'noticer', 'skeptic', 'formulator', 'verifier', 'novelty',
    'arxiv-search', 'oeis-search', 'groupprops-search', 'scholar-search',
    'prior_advocate', 'auditor',
    'introducer', 'theorist', 'computer', 'editor', 'reviewer', 'submitter',
}

colonies = data.get('colonies') or {}
actual = set(colonies.keys())

if actual != EXPECTED:
    missing = EXPECTED - actual
    extra = actual - EXPECTED
    print('FAIL_COVERAGE missing=%r extra=%r' % (sorted(missing), sorted(extra)))
    sys.exit(0)

bad_variants = []
bad_overlay_count = []
empty_overlays = []
for name, entry in colonies.items():
    variants = entry.get('variants') or []
    overlays = entry.get('overlays') or {}
    if not isinstance(variants, list) or len(variants) != 5:
        bad_variants.append((name, len(variants) if isinstance(variants, list) else 'NOT_LIST'))
    if not isinstance(overlays, dict) or len(overlays) != 5:
        bad_overlay_count.append((name, len(overlays) if isinstance(overlays, dict) else 'NOT_DICT'))
    if isinstance(overlays, dict):
        for k, v in overlays.items():
            if not isinstance(v, str) or not v.strip():
                empty_overlays.append((name, k))

print('COUNT_OK=%d' % len(colonies))
if bad_variants:
    print('FAIL_VARIANTS %r' % bad_variants)
if bad_overlay_count:
    print('FAIL_OVERLAY_COUNT %r' % bad_overlay_count)
if empty_overlays:
    print('FAIL_OVERLAY_EMPTY %r' % empty_overlays)
" "$VARIANTS" 2>&1)"

if printf '%s' "$PY_OUT" | grep -Fq 'COUNT_OK=18'; then
    pass "3. all 18 colonies enumerated"
else
    fail "3. all 18 colonies enumerated" "$PY_OUT"
fi

if printf '%s' "$PY_OUT" | grep -Fq 'FAIL_VARIANTS'; then
    fail "2. every colony has 5 variants" "$(printf '%s' "$PY_OUT" | grep -F 'FAIL_VARIANTS')"
elif printf '%s' "$PY_OUT" | grep -Fq 'FAIL_OVERLAY_COUNT'; then
    fail "2. every colony has 5 overlays" "$(printf '%s' "$PY_OUT" | grep -F 'FAIL_OVERLAY_COUNT')"
else
    pass "2. every colony has 5 variants + 5 overlays"
fi

if printf '%s' "$PY_OUT" | grep -Fq 'FAIL_OVERLAY_EMPTY'; then
    fail "4. every overlay is non-empty" "$(printf '%s' "$PY_OUT" | grep -F 'FAIL_OVERLAY_EMPTY')"
else
    pass "4. every overlay is non-empty"
fi

# Cross-reference test 3 against the side assignment expected by
# tools/colony-fitness.py SIDE_BY_COLONY: 6 discovery + 6 audit + 6
# preprint. Catches accidental mis-mapping when adding new colonies
# in PR-C.
SIDE_OUT="$(python3 -c "
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

DISCOVERY = {'explorer', 'noticer', 'skeptic', 'formulator', 'verifier', 'novelty'}
AUDIT = {'arxiv-search', 'oeis-search', 'groupprops-search', 'scholar-search', 'prior_advocate', 'auditor'}
PREPRINT = {'introducer', 'theorist', 'computer', 'editor', 'reviewer', 'submitter'}

colonies = data.get('colonies') or {}
mismatches = []
for name, entry in colonies.items():
    declared = entry.get('side')
    if name in DISCOVERY and declared != 'discovery':
        mismatches.append((name, declared, 'discovery'))
    elif name in AUDIT and declared != 'audit':
        mismatches.append((name, declared, 'audit'))
    elif name in PREPRINT and declared != 'preprint':
        mismatches.append((name, declared, 'preprint'))

if mismatches:
    print('SIDE_MISMATCH %r' % mismatches)
else:
    print('SIDE_OK')
" "$VARIANTS" 2>&1)"

if printf '%s' "$SIDE_OUT" | grep -Fq 'SIDE_OK'; then
    pass "5. side assignment matches colony-fitness.py SIDE_BY_COLONY"
else
    fail "5. side assignment matches colony-fitness.py SIDE_BY_COLONY" "$SIDE_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
