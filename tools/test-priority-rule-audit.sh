#!/bin/bash
# tools/test-priority-rule-audit.sh: regression tests for the #1478/#1482
# priority-rule audit + purge helpers.
#
# PR #1481's first cut re-implemented agentis-core's crystallizer persistence
# in Python and got the lookup key, the object serialization, and the
# text-scan fallback wrong, so `audit` silently reported `contaminated: 0`
# against real state and `purge --apply` was a permanent no-op (#1482). These
# tests exercise the rebuilt export-driven helpers against real-shaped
# fixtures so that class of regression cannot ship again:
#   - a contaminated `action` (rule_id != content_hash) IS detected,
#   - a clean rule whose *condition* carries a priority-like keyword is NOT
#     flagged (no whole-blob text scan),
#   - a scoped `priority::*` action stays clean,
#   - the plain-JSON knowledge-dir fallback is exercised,
#   - the audit -> purge selection path drops exactly the flagged rules while
#     preserving the export document's shape.
#
# Usage: ./tools/test-priority-rule-audit.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/dev-apprenticeship/triage/scripts/lib"
AUDIT="$LIB/priority-rule-audit.py"
PURGE="$LIB/priority-rule-purge.py"
FIX="$REPO_ROOT/dev-apprenticeship/triage/tests/fixtures"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ----- 1. Contaminated action detected against a real-shaped export -----

REPORT="$(python3 "$AUDIT" --export "$FIX/real_shaped_index_row.json" --class label)"

if echo "$REPORT" | grep -q "contaminated    : 1"; then
    pass "real-shaped export: 1 contaminated rule detected (no false 'contaminated: 0')"
else
    fail "real-shaped export: expected 'contaminated    : 1', got:"
    printf '%s\n' "$REPORT" | sed 's/^/      /'
fi

if echo "$REPORT" | grep -q "rl_9f3c1d7a2b4e6f8091a2b3c4d5e6f708"; then
    pass "flagged rule resolved by rule_id (not content_hash)"
else
    fail "expected the P1-carrying rule_id in the report"
fi

# ----- 2. Clean rule with a priority-like CONDITION is NOT flagged -----

if echo "$REPORT" | grep -q "rl_clean0001aaaa2222bbbb3333cccc4444"; then
    fail "clean-action rule flagged on its condition text (whole-blob scan regression)"
else
    pass "clean-action rule with 'urgent' in its condition is NOT flagged"
fi

# ----- 3. Scoped priority::* action stays clean -----

if echo "$REPORT" | grep -q "rl_scoped00011111222233334444555566"; then
    fail "scoped priority::critical action wrongly flagged"
else
    pass "scoped priority::* action treated as canonical (not flagged)"
fi

# ----- 4. JSON --json stream: exactly one contaminated line + summary -----

JSONOUT="$(python3 "$AUDIT" --export "$FIX/real_shaped_index_row.json" --class label --json)"
N_CONTAM="$(echo "$JSONOUT" | grep -c '"contaminated_tokens"' || true)"
if [ "$N_CONTAM" = "1" ] && echo "$JSONOUT" | grep -q '"_summary": true'; then
    pass "--json emits exactly one contaminated line + a _summary"
else
    fail "--json stream malformed (contaminated lines=$N_CONTAM):"
    printf '%s\n' "$JSONOUT" | sed 's/^/      /'
fi

# ----- 5. Knowledge-dir-layout fallback (no semantic-DAG persistence) -----

KDREPORT="$(python3 "$AUDIT" --knowledge-dir "$FIX/knowledge_dir_layout" --class label)"
if echo "$KDREPORT" | grep -q "contaminated    : 1" \
    && echo "$KDREPORT" | grep -q "kd_dirty_urgent_0001"; then
    pass "knowledge-dir fallback: contaminated 'urgent' action detected"
else
    fail "knowledge-dir fallback missed the contaminated rule:"
    printf '%s\n' "$KDREPORT" | sed 's/^/      /'
fi

if echo "$KDREPORT" | grep -q "kd_clean_0002"; then
    fail "knowledge-dir fallback: clean rule flagged on its condition keywords"
else
    pass "knowledge-dir fallback: clean rule with priority-like condition NOT flagged"
fi

# class filter: a route rule carrying 'P2' is invisible to a label scan.
if echo "$KDREPORT" | grep -q "kd_route_0003"; then
    fail "class filter leaked a 'route' rule into a 'label' scan"
else
    pass "class filter: non-label rule excluded from a label scan"
fi

# ----- 6. Purge selection path: drops exactly the flagged rule, preserves shape -----

python3 "$AUDIT" --export "$FIX/real_shaped_index_row.json" --class label --json > "$WORK/flagged.jsonl"

# Dry-run touches nothing and names the flagged rule.
DRY="$(python3 "$PURGE" --export "$FIX/real_shaped_index_row.json" < "$WORK/flagged.jsonl")"
if echo "$DRY" | grep -q "DRY-RUN" \
    && echo "$DRY" | grep -q "rl_9f3c1d7a2b4e6f8091a2b3c4d5e6f708" \
    && echo "$DRY" | grep -q "would remove 1 rule"; then
    pass "purge dry-run previews the single flagged rule and writes nothing"
else
    fail "purge dry-run preview wrong:"
    printf '%s\n' "$DRY" | sed 's/^/      /'
fi

# Apply writes a filtered pool with the flagged rule gone and the clean ones kept.
python3 "$PURGE" --export "$FIX/real_shaped_index_row.json" --apply \
    --out "$WORK/filtered.json" < "$WORK/flagged.jsonl" > /dev/null

KEPT="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(",".join(r["rule_id"] for r in d["rules"]))' "$WORK/filtered.json")"

if ! echo "$KEPT" | grep -q "rl_9f3c1d7a2b4e6f8091a2b3c4d5e6f708" \
    && echo "$KEPT" | grep -q "rl_clean0001aaaa2222bbbb3333cccc4444" \
    && echo "$KEPT" | grep -q "rl_scoped00011111222233334444555566"; then
    pass "purge --apply removes the contaminated rule, keeps clean + scoped rules, preserves {rules:[...]} shape"
else
    fail "purge --apply filter wrong; kept ids: $KEPT"
fi

# Re-auditing the filtered pool must report a clean pool.
RECLEAN="$(python3 "$AUDIT" --export "$WORK/filtered.json" --class label)"
if echo "$RECLEAN" | grep -q "contaminated    : 0"; then
    pass "re-audit of the purged pool reports contaminated: 0"
else
    fail "re-audit of purged pool still shows contamination:"
    printf '%s\n' "$RECLEAN" | sed 's/^/      /'
fi

# ----- 7. Total-on-failure: empty/absent export yields a clean report, exit 0 -----

if echo "" | python3 "$AUDIT" --export - --class label | grep -q "contaminated    : 0"; then
    pass "empty export -> clean report, no crash"
else
    fail "empty export did not yield a clean report"
fi

echo ""
echo "priority-rule-audit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
