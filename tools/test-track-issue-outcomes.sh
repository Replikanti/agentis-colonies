#!/usr/bin/env bash
# tools/test-track-issue-outcomes.sh: unit tests for tools/track-issue-outcomes.sh
# + tools/lib/outcome-store.sh (#1402, M4 step 1 of #1266).
#
# Hermetic, fixture-driven — mirrors tools/test-self-observe.sh: the script
# runs from a sandbox tools dir, TRACK_OUTCOMES_GH points at a stub `gh`
# serving canned `issue list` JSON plus per-issue closing-PR GraphQL
# fixtures, and a file-backed stub `agentis memo get/set` on PATH (the
# test-candidate-queue.sh shim) backs the outcome store. No real gh /
# network / agentis needed.
#
#   1. merged-PR close    -> recorded as success
#   2. not-planned close  -> recorded as noise, WITHOUT a closing-PR lookup
#   3. unmerged-PR close  -> recorded as noise
#   4. non-prefixed closed issues are never recorded
#   5. re-run             -> no duplicate records (dedup on iid)
#   6. --summary          -> per-signal-class acceptance-rate math
#   7. every stored line is well-formed JSONL with exactly the 4 fields
#
# Usage: ./tools/test-track-issue-outcomes.sh   (exit 0 = all pass, 1 = failure)
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tools/lib" "$WORK/bin" "$WORK/gh-fixtures"
cp "$SCRIPT_DIR/track-issue-outcomes.sh" "$WORK/tools/track-issue-outcomes.sh"
cp "$SCRIPT_DIR/lib/outcome-store.sh" "$WORK/tools/lib/outcome-store.sh"
chmod +x "$WORK/tools/track-issue-outcomes.sh"
TIO="$WORK/tools/track-issue-outcomes.sh"

# --- Stub `agentis`: file-backed memo get/set on PATH so the outcome store
#     runs without a real binary (mirrors test-candidate-queue.sh and the CI
#     runners, where agentis is not installed). ---
STORE="$WORK/memo"
mkdir -p "$STORE"
cat > "$WORK/bin/agentis" <<'STUB'
#!/usr/bin/env bash
STORE_DIR="$AGENTIS_STUB_STORE"
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
if [ "${1:-}" = "memo" ] && [ "${2:-}" = "get" ]; then
    f="$STORE_DIR/$(slug "${3:-}")"
    [ -f "$f" ] && cat "$f"
    exit 0
fi
if [ "${1:-}" = "memo" ] && [ "${2:-}" = "set" ]; then
    f="$STORE_DIR/$(slug "${3:-}")"
    printf '%s' "${4:-}" > "$f"
    exit 0
fi
echo "agentis-stub: unsupported args: $*" >&2
exit 2
STUB
chmod +x "$WORK/bin/agentis"
export AGENTIS_STUB_STORE="$STORE"
export PATH="$WORK/bin:$PATH"
# Default OUTCOME_STORE_KEY slugified by the stub:
STORE_FILE="$STORE/self_observe_outcomes"

# --- Stub `gh`: `issue list` serves $GH_STUB_DIR/issues.json; `api graphql`
#     serves $GH_STUB_DIR/graphql-<number>.json (empty closing-PR list when
#     the fixture is absent) and logs each lookup to $GH_STUB_DIR/graphql.log
#     so the NOT_PLANNED short-circuit is assertable. ---
cat > "$WORK/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
    cat "$GH_STUB_DIR/issues.json"
    exit 0
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
    num=""
    for a in "$@"; do case "$a" in number=*) num="${a#number=}" ;; esac; done
    echo "graphql number=$num" >> "$GH_STUB_DIR/graphql.log"
    f="$GH_STUB_DIR/graphql-$num.json"
    if [ -f "$f" ]; then
        cat "$f"
    else
        echo '{"data":{"repository":{"issue":{"closedByPullRequestsReferences":{"nodes":[]}}}}}'
    fi
    exit 0
fi
exit 0
STUB
chmod +x "$WORK/gh"
export GH_STUB_DIR="$WORK/gh-fixtures"

run_tio() {
    TRACK_OUTCOMES_GH="$WORK/gh" TRACK_OUTCOMES_REPO="o/r" "$TIO" "$@" 2>&1
}
store_lines() { cat "$STORE_FILE" 2>/dev/null || true; }

# --- Fixtures: 4 closed issues. #101 closed by a merged PR (success),
#     #102 closed not-planned (noise, no lookup), #103's closing PR was
#     closed UNMERGED (noise), #104 lacks the [self-observe] prefix. ---
cat > "$GH_STUB_DIR/issues.json" <<'JSON'
[
  {"number": 101, "title": "[self-observe] doc-drift: doc/federation-dashboard.md", "closedAt": "2026-06-20T10:00:00Z", "stateReason": "COMPLETED"},
  {"number": 102, "title": "[self-observe] todo-marker: tools/x.sh:5", "closedAt": "2026-06-21T11:00:00Z", "stateReason": "NOT_PLANNED"},
  {"number": 103, "title": "[self-observe] doc-drift: README.md", "closedAt": "2026-06-22T12:00:00Z", "stateReason": "COMPLETED"},
  {"number": 104, "title": "unrelated issue that merely mentions self-observe", "closedAt": "2026-06-23T13:00:00Z", "stateReason": "COMPLETED"}
]
JSON
cat > "$GH_STUB_DIR/graphql-101.json" <<'JSON'
{"data": {"repository": {"issue": {"closedByPullRequestsReferences": {"nodes": [{"number": 900, "merged": true}]}}}}}
JSON
cat > "$GH_STUB_DIR/graphql-103.json" <<'JSON'
{"data": {"repository": {"issue": {"closedByPullRequestsReferences": {"nodes": [{"number": 901, "merged": false}]}}}}}
JSON

OUT="$(run_tio)"

# ---- Test 1: merged-PR close -> success ----
if printf '%s\n' "$OUT" | grep -q 'recorded: #101 doc-drift -> success' \
   && store_lines | grep '"iid": 101' | grep -q '"outcome": "success"'; then
    pass "merged-PR close recorded as success (signal_class parsed from title)"
else
    fail "merged-PR success" "out=$(printf '%s\n' "$OUT" | grep 101 || true) store=$(store_lines | grep 101 || true)"
fi

# ---- Test 2: not-planned close -> noise, and the closing-PR lookup is
#      short-circuited (no graphql call for #102) ----
if store_lines | grep '"iid": 102' | grep -q '"outcome": "noise"' \
   && ! grep -q 'number=102' "$GH_STUB_DIR/graphql.log"; then
    pass "not-planned close recorded as noise without a closing-PR lookup"
else
    fail "not-planned noise" "store=$(store_lines | grep 102 || true) log=$(cat "$GH_STUB_DIR/graphql.log")"
fi

# ---- Test 3: closing PR closed UNMERGED -> noise ----
if store_lines | grep '"iid": 103' | grep -q '"outcome": "noise"'; then
    pass "unmerged-closing-PR close recorded as noise"
else
    fail "unmerged noise" "store=$(store_lines | grep 103 || true)"
fi

# ---- Test 4: a closed issue without the title prefix is never recorded ----
if ! store_lines | grep -q '"iid": 104' && [ "$(store_lines | grep -c '"iid"')" = "3" ]; then
    pass "non-prefixed issue ignored (exactly 3 records for 4 closed issues)"
else
    fail "prefix filter" "count=$(store_lines | grep -c '"iid"') store=$(store_lines)"
fi

# ---- Test 5: re-run -> no duplicate records, everything reported as known ----
OUT2="$(run_tio)"
if [ "$(store_lines | grep -c '"iid"')" = "3" ] \
   && [ "$(printf '%s\n' "$OUT2" | grep -c 'already recorded')" = "3" ] \
   && printf '%s\n' "$OUT2" | grep -q 'recorded=0, already-recorded=3'; then
    pass "re-run is idempotent: 3 records stay 3, all reported already-recorded"
else
    fail "re-run dedup" "count=$(store_lines | grep -c '"iid"') out=$(printf '%s\n' "$OUT2" | tail -2)"
fi

# ---- Test 6: --summary acceptance-rate math ----
# Store now holds: doc-drift success(#101) + noise(#103), todo-marker noise(#102)
# -> doc-drift 1/2 (50%), todo-marker 0/1 (0%), overall 1/3 (33%).
SUM="$(run_tio --summary)"
if printf '%s\n' "$SUM" | grep -Eq 'doc-drift +1/2 \(50%\) +success=1 noise=1' \
   && printf '%s\n' "$SUM" | grep -Eq 'todo-marker +0/1 \(0%\) +success=0 noise=1' \
   && printf '%s\n' "$SUM" | grep -q 'overall: 1/3 (33%)'; then
    pass "--summary: per-signal-class acceptance rates + overall (1/2, 0/1, 1/3)"
else
    fail "--summary math" "$(printf '%s\n' "$SUM")"
fi

# ---- Test 7: every stored line is well-formed JSONL with exactly the 4
#      record fields (the store contract) ----
if store_lines | python3 -c '
import json, sys
lines = [ln for ln in sys.stdin.read().split("\n") if ln != ""]
assert len(lines) == 3, "expected 3 JSONL lines, got %d" % len(lines)
fields = {"iid", "signal_class", "outcome", "closed_at"}
for ln in lines:
    rec = json.loads(ln)  # raises on any malformed line
    assert set(rec) == fields, "unexpected fields %s" % sorted(rec)
    assert isinstance(rec["iid"], int)
    assert rec["outcome"] in ("success", "noise")
    assert rec["closed_at"].endswith("Z")
'; then
    pass "store contract: 3 well-formed JSONL records with exactly {iid, signal_class, outcome, closed_at}"
else
    fail "store contract" "store=$(store_lines)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
