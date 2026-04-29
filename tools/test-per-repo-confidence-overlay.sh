#!/usr/bin/env bash
# tools/test-per-repo-confidence-overlay.sh: end-to-end test for the
# #316 M5a per-(agent, repo) confidence overlay in
# federation-dashboard-collector.py.
#
# When a colony's [[forge.github]] array has N>=2 entries AND a daemon
# carries a non-None `confidence` field, the collector now fetches per-
# (agent, repo) memo `<owner>__<repo>:<agent>:confidence` via
# `agentis memo get ... --raw` and appends the result to each agent
# record as `per_repo_confidence: [{owner, repo, confidence}, ...]`.
#
# Cases:
#   1. No memo seeded: collector still emits the overlay key but every
#      record's confidence is None (override list is the iteration
#      template; absence of memos means "no override").
#   2. Memos seeded: collector reads each per-repo memo and reflects
#      the float value in `confidence`.
#
# Standard scaffold: set -u, mktemp -d isolation, EXIT trap for cleanup.
# Auto-discovered by tools/colony-lint.sh's tools-test loop.
#
# Usage: ./tools/test-per-repo-confidence-overlay.sh
# Exit 0 if all tests pass, 1 otherwise.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
COLLECTOR="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-collector.py"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# Build a fixture federation with one colony that knows two repos.
# $1 = fed_dir, $2 = colony name, $3 = colon-separated memo seeds
# of the form "key=value:key=value:...". The shimmed `agentis` reads
# AGENTIS_MEMO_DB env to look up `memo get <key> --raw` results.
build_fed() {
    local fed="$1" colony="$2"
    mkdir -p "$fed/$colony/scripts" "$fed/$colony/agents" \
             "$fed/$colony/config" \
             "$fed/.agentis/logs" "$fed/.agentis/experience"
    # Stub start-colony.sh: --print-repos-json prints 2-entry JSON,
    # --rate-limit-status prints scalar JSON (unused in this test but
    # the collector still calls it so the whole pipeline must succeed).
    cat > "$fed/$colony/scripts/start-colony.sh" <<'SCRIPT'
#!/bin/bash
if [ "$1" = "--print-repos-json" ]; then
    echo "[{\"owner\":\"acme\",\"repo\":\"frontend\",\"token\":\"x\",\"url\":\"https://api.github.com\"},{\"owner\":\"acme\",\"repo\":\"backend\",\"token\":\"y\",\"url\":\"https://api.github.com\"}]"
    exit 0
fi
if [ "$1" = "--rate-limit-status" ]; then
    echo "{\"remaining\": 5000, \"limit\": 5000, \"reset_at\": \"2026-04-29T12:00:00Z\"}"
    exit 0
fi
exit 0
SCRIPT
    chmod +x "$fed/$colony/scripts/start-colony.sh"
}

# Shim `agentis memo get <key> --raw`. Reads AGENTIS_MEMO_DB env: a
# pipe-separated `key=value|key=value` map (colon is unusable as a
# pair separator because it appears inside scoped memo keys like
# `<owner>__<repo>:<agent>:confidence`). Unknown keys exit non-zero
# (mirrors real `agentis memo get` behaviour for missing memos).
SHIM_DIR="$TMPDIR_TEST/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/agentis" <<'SHIM'
#!/bin/bash
if [ "${1:-}" = "memo" ] && [ "${2:-}" = "get" ]; then
    KEY="${3:-}"
    DB="${AGENTIS_MEMO_DB:-}"
    OLD_IFS="$IFS"
    IFS='|'
    for pair in $DB; do
        case "$pair" in
            "${KEY}="*)
                printf '%s\n' "${pair#*=}"
                IFS="$OLD_IFS"
                exit 0
                ;;
        esac
    done
    IFS="$OLD_IFS"
    exit 1
fi
if [ "${1:-}" = "daemon" ] && [ "${2:-}" = "list" ]; then
    printf '[]\n'
    exit 0
fi
exit 0
SHIM
chmod +x "$SHIM_DIR/agentis"

# Run the collector with one synthetic agent record passed via daemons
# JSON. The daemons array carries `confidence` so the per-repo overlay
# branch fires. agent_map_json maps agent->colony.
run_collector_with_agent() {
    local fed_dir="$1" colony="$2" agent="$3" out_path="$4" memo_db="$5"
    local daemons_json
    daemons_json="$(printf '[{"source":"%s/agents/%s.ag","colony":"%s","agent_id":"aid-%s","confidence":0.55,"state":"running","health":"healthy","pid":99999}]' \
        "$colony" "$agent" "$colony" "$agent")"
    local agent_map_json
    agent_map_json="$(printf '[{"agent":"%s","colony":"%s"}]' "$agent" "$colony")"

    AGENTIS_MEMO_DB="$memo_db" PATH="$SHIM_DIR:$PATH" python3 "$COLLECTOR" \
        "$daemons_json" \
        "$agent_map_json" \
        "$fed_dir" \
        "$(date '+%s')" \
        "$fed_dir/.agentis/experience" \
        "$fed_dir/.agentis/logs" \
        "$TMPDIR_TEST/dash" \
        "[\"$colony\"]" \
        "" \
        "$agent" \
        > "$out_path" 2>"$TMPDIR_TEST/collector.err"
}

# --- Test 1: no memo seeded -> overlay emits None entries ------------
# Build a fed with 2 repos but no memo seeds. The collector should
# still emit `per_repo_confidence` as a 2-entry list, both `confidence`
# fields None — proves the iteration template fires even without
# operator data.
FED1="$TMPDIR_TEST/fed1"
COLONY1="multi"
AGENT1="router"
build_fed "$FED1" "$COLONY1"

OUT1="$TMPDIR_TEST/out1.json"
run_collector_with_agent "$FED1" "$COLONY1" "$AGENT1" "$OUT1" ""

if python3 -c "
import json, sys
with open('$OUT1') as f:
    d = json.load(f)
agents = d.get('agents') or []
assert len(agents) == 1, 'expected 1 agent, got ' + str(len(agents))
a = agents[0]
prc = a.get('per_repo_confidence')
assert isinstance(prc, list), 'per_repo_confidence must be a list, got ' + repr(type(prc))
assert len(prc) == 2, 'expected 2 per-repo records, got ' + str(len(prc))
for r in prc:
    assert r['confidence'] is None, 'expected None confidence (no memo), got ' + repr(r)
" 2>"$TMPDIR_TEST/assert1.err"; then
    pass "test 1: collector emits per_repo_confidence with None entries when no memo seeded"
else
    fail "test 1: per_repo_confidence default-empty regressed" "$(cat "$TMPDIR_TEST/assert1.err")"
fi

# --- Test 2: memos seeded -> collector reads float confidence values
# Same fixture with two memo seeds:
#     acme__frontend:router:confidence = 0.85
#     acme__backend:router:confidence  = 0.42
# The collector must surface each value in the matching record.
OUT2="$TMPDIR_TEST/out2.json"
MEMO_DB='acme__frontend:router:confidence=0.85|acme__backend:router:confidence=0.42'
run_collector_with_agent "$FED1" "$COLONY1" "$AGENT1" "$OUT2" "$MEMO_DB"

if python3 -c "
import json, sys
with open('$OUT2') as f:
    d = json.load(f)
agents = d.get('agents') or []
prc = agents[0].get('per_repo_confidence') or []
front = next((r for r in prc if r['repo'] == 'frontend'), None)
back  = next((r for r in prc if r['repo'] == 'backend'), None)
assert front is not None, 'frontend record missing'
assert back is not None, 'backend record missing'
assert abs(front['confidence'] - 0.85) < 1e-6, 'expected 0.85 for frontend, got ' + repr(front['confidence'])
assert abs(back['confidence'] - 0.42) < 1e-6, 'expected 0.42 for backend, got ' + repr(back['confidence'])
" 2>"$TMPDIR_TEST/assert2.err"; then
    pass "test 2: collector reads per-repo memo confidence values when seeded"
else
    fail "test 2: per-repo memo confidence read regressed" "$(cat "$TMPDIR_TEST/assert2.err")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
