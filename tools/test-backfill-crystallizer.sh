#!/bin/bash
# tools/test-backfill-crystallizer.sh: unit tests for the #1431 backfill /
# incremental-ingest pipeline (tools/backfill-crystallizer.sh +
# tools/lib/backfill-gen.py). The canonical-context layer has its own drift
# sentinel (test-canonical-context.sh); this file covers the driver
# generator's escaping + budget contract, the dry-run table, the
# --issues-json offline path, and (when an `agentis` binary is on PATH) an
# end-to-end run that verifies the generated driver actually lands
# KnowledgeBase entries in a scratch federation.
#
# Usage: ./tools/test-backfill-crystallizer.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO_ROOT/tools/lib/backfill-gen.py"
TOOL="$REPO_ROOT/tools/backfill-crystallizer.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ----- 1. Driver generator: shape, budget, escaping -----

cat > "$WORK/triples.jsonl" <<'JSONL'
{"class":"label","iid":7,"ctx":"kw=bug scope=team","coarse":"kw=bug","action":"bug"}
{"class":"prioritize","iid":7,"ctx":"kw=bug labels=","coarse":"kw=bug","action":"P1"}
{"class":"route","iid":8,"ctx":"kw= labels=quo\"te","coarse":"kw=","action":"ali\\ce"}
JSONL

python3 "$GEN" < "$WORK/triples.jsonl" > "$WORK/driver.ag"

if grep -qxF 'cb 800;' "$WORK/driver.ag"; then
    pass "driver cb budget = 500 + 100 * 3 triples"
else
    fail "driver cb budget — expected 'cb 800;', got: $(head -1 "$WORK/driver.ag")"
fi

if grep -qF 'learn("label", "kw=bug scope=team", "bug", "success", ["distilled", "triage", "backfill"]);' "$WORK/driver.ag"; then
    pass "driver emits the learn row with the backfill tag"
else
    fail "driver learn row missing or malformed"
fi

if grep -qF 'let d0 = try { distill("label", "kw=bug", "bug", "heuristic"); } catch e { ""; };' "$WORK/driver.ag" \
    && grep -qF 'if len(d0) > 0 { knowledge_validate(d0); };' "$WORK/driver.ag"; then
    pass "driver emits guarded distill + knowledge_validate per triple"
else
    fail "driver distill/validate pair missing or malformed"
fi

if grep -qF 'labels=quo\"te' "$WORK/driver.ag" \
    && grep -qF 'ali\\ce' "$WORK/driver.ag"; then
    pass "driver escapes double quotes and backslashes in .ag literals"
else
    fail "driver escaping — quote/backslash not escaped:"
    grep -n 'quo\|ali' "$WORK/driver.ag" || true
fi

# Malformed / incomplete lines are dropped, not fatal.
printf '%s\n%s\n' 'not-json' '{"class":"label","ctx":"x"}' \
    | python3 "$GEN" > "$WORK/empty-driver.ag"
if [ ! -s "$WORK/empty-driver.ag" ]; then
    pass "generator drops malformed/incomplete triples (empty driver)"
else
    fail "generator should emit nothing for malformed input, got:"
    cat "$WORK/empty-driver.ag"
fi

# ----- 2. Dry-run table -----

TABLE="$(python3 "$GEN" --table < "$WORK/triples.jsonl" 2>/dev/null)"
if printf '%s\n' "$TABLE" | grep -q "^label	1	no	kw=bug	bug$"; then
    pass "dry-run table row shape (class/occurrences/would_crystallize/coarse/action)"
else
    fail "dry-run table — expected 'label 1 no kw=bug bug' row, got:"
    printf '%s\n' "$TABLE"
fi

# Repeats aggregate and cross the would-crystallize threshold at 3.
cat "$WORK/triples.jsonl" "$WORK/triples.jsonl" "$WORK/triples.jsonl" \
    > "$WORK/triples3.jsonl"
TABLE3="$(python3 "$GEN" --table < "$WORK/triples3.jsonl" 2>/dev/null)"
if printf '%s\n' "$TABLE3" | grep -q "^label	3	yes	kw=bug	bug$"; then
    pass "dry-run table marks 3+ occurrences as would_crystallize=yes"
else
    fail "dry-run threshold — expected 'label 3 yes' row, got:"
    printf '%s\n' "$TABLE3"
fi

# ----- 3. Orchestrator: --issues-json offline path + --dry-run -----

FED="$WORK/fed"
mkdir -p "$FED/.agentis"
cat > "$WORK/issues.json" <<'JSON'
[{"iid": 1, "title": "bug crash in build", "description": "",
  "labels": ["bug", "P1"], "assignees": [{"username": "alice"}],
  "author": {"username": "op"}, "updated_at": "2026-07-01T00:00:00Z"},
 {"iid": 2, "title": "bug crash in build", "description": "",
  "labels": ["bug", "P1"], "assignees": [{"username": "alice"}],
  "author": {"username": "op"}, "updated_at": "2026-07-02T00:00:00Z"},
 {"iid": 3, "title": "bug crash in build", "description": "",
  "labels": ["bug", "P1"], "assignees": [{"username": "alice"}],
  "author": {"username": "op"}, "updated_at": "2026-07-03T00:00:00Z"}]
JSON

OUT="$("$TOOL" --fed-dir "$FED" --issues-json "$WORK/issues.json" --dry-run)"
if printf '%s\n' "$OUT" | grep -q "^label	3	yes"; then
    pass "orchestrator --dry-run aggregates the 3-issue fixture into a crystallizable class"
else
    fail "orchestrator --dry-run — expected a 'label 3 yes' row, got:"
    printf '%s\n' "$OUT"
fi

if "$TOOL" --fed-dir "$WORK/nonexistent" --issues-json "$WORK/issues.json" --dry-run >/dev/null 2>&1; then
    fail "orchestrator should refuse a --fed-dir without .agentis/"
else
    pass "orchestrator refuses a --fed-dir without .agentis/ (exit != 0)"
fi

if "$TOOL" --fed-dir "$FED" --bogus-flag >/dev/null 2>&1; then
    fail "orchestrator should exit 2 on unknown flags"
else
    pass "orchestrator rejects unknown flags"
fi

# ----- 4. End-to-end (requires agentis on PATH) -----

if ! command -v agentis >/dev/null 2>&1; then
    echo "[SKIP] agentis not on PATH — skipping end-to-end driver run"
else
    E2E_FED="$WORK/e2e-fed"
    mkdir -p "$E2E_FED"
    (cd "$E2E_FED" && agentis init >/dev/null 2>&1) || true
    # The driver needs the experience + knowledge stores enabled (same keys
    # dev-apprenticeship/install.sh writes).
    {
        printf 'experience.enabled = true\n'
        printf 'knowledge.enabled = true\n'
        printf 'learning.enabled = true\n'
    } >> "$E2E_FED/.agentis/config"
    if "$TOOL" --fed-dir "$E2E_FED" --issues-json "$WORK/issues.json" > "$WORK/e2e.out" 2>&1; then
        KB_JSON="$( (cd "$E2E_FED" && agentis knowledge export 2>/dev/null) || printf '[]')"
        if printf '%s' "$KB_JSON" | grep -qF '"kw=bug,build,crash"' \
            || printf '%s' "$KB_JSON" | grep -qF 'kw=bug'; then
            pass "end-to-end: backfill lands distilled entries in the KnowledgeBase"
        else
            fail "end-to-end: knowledge export carries no backfilled entry, got: $(printf '%s' "$KB_JSON" | head -c 300)"
        fi
    else
        fail "end-to-end: backfill run failed:"
        cat "$WORK/e2e.out"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
