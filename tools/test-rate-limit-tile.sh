#!/usr/bin/env bash
# tools/test-rate-limit-tile.sh: end-to-end test for the federation-dashboard
# 0.3.0 Forge Rate Limits tile.
#
# Wires together:
#   1. federation-dashboard-collector.py — must add a `forge_rate_limits`
#      key to its output JSON, keyed by colony name, populated by execing
#      `<colony>/scripts/start-colony.sh --rate-limit-status`.
#   2. start-colony.sh --rate-limit-status — must exec
#      `<colony>/scripts/forge-api.sh rate-limit-status` and let its
#      stdout flow through to the caller.
#   3. federation-dashboard.html.template — must contain the tile markup
#      (#forge-rate-limits div and the JS that reads forge_rate_limits).
#
# Test strategy: build a minimal fixture federation with one colony whose
# scripts/forge-api.sh is a stub that prints a known JSON payload. Run
# the collector against it. Assert the JSON output contains
# `forge_rate_limits.<colony>` with the round-tripped values. Then assert
# the renderer produces HTML containing the tile and the new colony key.
#
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
COLLECTOR="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-collector.py"
RENDERER="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-renderer.py"
TEMPLATE="$REPO_ROOT/federation-dashboard/lib/federation-dashboard.html.template"
START_COLONY_SRC="$REPO_ROOT/dev-apprenticeship/triage/scripts/start-colony.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# ---- Sanity: required artifacts exist ----
for f in "$COLLECTOR" "$RENDERER" "$TEMPLATE" "$START_COLONY_SRC"; do
    if [ ! -f "$f" ]; then
        fail "0: required artifact missing" "$f"
        echo "Results: $PASS passed, $FAIL failed"
        exit 1
    fi
done

# ---- Static template assertions: tile DOM + render JS exist ----
if grep -q 'id="forge-rate-limits"' "$TEMPLATE"; then
    pass "1: template contains #forge-rate-limits container"
else
    fail "1: template missing #forge-rate-limits container"
fi

if grep -q 'forge_rate_limits' "$TEMPLATE"; then
    pass "2: template JS reads data.forge_rate_limits"
else
    fail "2: template JS does not reference forge_rate_limits"
fi

if grep -q '<h2>Forge Rate Limits</h2>' "$TEMPLATE"; then
    pass "3: template contains 'Forge Rate Limits' heading"
else
    fail "3: template missing 'Forge Rate Limits' heading"
fi

# ---- Fixture federation ----
# Layout mirrors what the dashboard's resolver expects:
#   <fed>/<colony>/scripts/start-colony.sh    (real file from triage)
#   <fed>/<colony>/scripts/forge-api.sh        (stub; prints canned JSON)
#   <fed>/<colony>/scripts/parse-toml.sh       (stub via tools)
#   <fed>/<colony>/config/colony.toml          (minimal valid config)
#   <fed>/tools/parse-toml.sh                  (real parser)
FED_DIR="$TMPDIR_TEST/fed"
COLONY="probe-colony"
mkdir -p "$FED_DIR/$COLONY/scripts" \
         "$FED_DIR/$COLONY/agents" \
         "$FED_DIR/$COLONY/config" \
         "$FED_DIR/tools" \
         "$FED_DIR/.agentis/logs" \
         "$FED_DIR/.agentis/experience"

# Real parse-toml.sh (the start-colony.sh sources via $REPO_ROOT/tools).
# Resolve via the parent of fed_dir → tools/ — start-colony.sh computes
# REPO_ROOT as $SCRIPT_DIR/../../.. so we need to mirror that depth.
# Easier: copy the real one to <fed>/../tools/.
mkdir -p "$TMPDIR_TEST/tools"
cp "$REPO_ROOT/tools/parse-toml.sh" "$TMPDIR_TEST/tools/parse-toml.sh"

# Minimal colony.toml: must satisfy the gitlab-arm validation
# (url + token + project all present).
cat > "$FED_DIR/$COLONY/config/colony.toml" <<'TOML'
[forge]
type = "gitlab"

[forge.gitlab]
url = "https://gitlab.example.test"
token = "stub-token"
project = "stub/project"
me = "stub-user"
TOML

# Stub forge-api.sh: ignore args, print the canned rate-limit JSON.
# Pinned reset matches PR 7 contract format.
EXPECTED_REMAINING=4321
EXPECTED_LIMIT=5000
EXPECTED_RESET="2026-04-24T12:00:00Z"
cat > "$FED_DIR/$COLONY/scripts/forge-api.sh" <<EOF
#!/bin/bash
# Stub for test-rate-limit-tile.sh
echo '{"remaining": $EXPECTED_REMAINING, "limit": $EXPECTED_LIMIT, "reset_at": "$EXPECTED_RESET"}'
EOF
chmod +x "$FED_DIR/$COLONY/scripts/forge-api.sh"

# Use the real triage start-colony.sh as our --rate-limit-status implementation.
# Its env-load path is identical across all 5 colonies; we only exercise the
# `--rate-limit-status` arm, which exec's $COLONY_DIR/scripts/forge-api.sh.
cp "$START_COLONY_SRC" "$FED_DIR/$COLONY/scripts/start-colony.sh"
chmod +x "$FED_DIR/$COLONY/scripts/start-colony.sh"

# ---- Smoke-test the start-colony.sh --rate-limit-status arm directly ----
# Catches breakage in the env-load → exec forge-api.sh chain before the
# collector even gets involved.
RL_OUT="$("$FED_DIR/$COLONY/scripts/start-colony.sh" --rate-limit-status 2>&1)"
if echo "$RL_OUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert d['remaining']==$EXPECTED_REMAINING and d['limit']==$EXPECTED_LIMIT and d['reset_at']=='$EXPECTED_RESET'" 2>/dev/null; then
    pass "4: start-colony.sh --rate-limit-status emits stub JSON"
else
    fail "4: start-colony.sh --rate-limit-status output unexpected" "got: $RL_OUT"
fi

# ---- Run the collector against the fixture ----
COLONY_LIST_JSON="[\"$COLONY\"]"
AGENT_MAP_JSON='[]'
DAEMONS_JSON='[]'
EPOCH="$(date '+%s')"
COLLECTOR_JSON="$(python3 "$COLLECTOR" \
    "$DAEMONS_JSON" \
    "$AGENT_MAP_JSON" \
    "$FED_DIR" \
    "$EPOCH" \
    "$FED_DIR/.agentis/experience" \
    "$FED_DIR/.agentis/logs" \
    "$TMPDIR_TEST/dash" \
    "$COLONY_LIST_JSON" \
    "" \
    2>"$TMPDIR_TEST/collector.err")"

if [ -z "$COLLECTOR_JSON" ]; then
    fail "5: collector produced no stdout" "stderr: $(cat "$TMPDIR_TEST/collector.err")"
else
    if echo "$COLLECTOR_JSON" | python3 -c 'import sys, json; json.loads(sys.stdin.read())' 2>/dev/null; then
        pass "5: collector output is valid JSON"
    else
        fail "5: collector output is not valid JSON" "$(echo "$COLLECTOR_JSON" | head -c 200)"
    fi
fi

# Assert forge_rate_limits.<colony> round-trips the stub values.
if echo "$COLLECTOR_JSON" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
rl = d.get('forge_rate_limits') or {}
c = rl.get('$COLONY') or {}
assert c.get('remaining') == $EXPECTED_REMAINING, c
assert c.get('limit') == $EXPECTED_LIMIT, c
assert c.get('reset_at') == '$EXPECTED_RESET', c
assert c.get('error') is None, c
" 2>"$TMPDIR_TEST/assert.err"; then
    pass "6: collector forge_rate_limits round-trips stub values"
else
    fail "6: forge_rate_limits assert failed" "stderr: $(cat "$TMPDIR_TEST/assert.err")"
fi

# ---- Failure-mode coverage: unknown-colony falls through cleanly ----
# Replace the stub with one that exits non-zero. The collector must still
# return valid JSON with an error field, not crash regen.
cat > "$FED_DIR/$COLONY/scripts/forge-api.sh" <<'EOF'
#!/bin/bash
echo "stub failure" >&2
exit 5
EOF
chmod +x "$FED_DIR/$COLONY/scripts/forge-api.sh"

COLLECTOR_JSON_FAIL="$(python3 "$COLLECTOR" \
    "$DAEMONS_JSON" \
    "$AGENT_MAP_JSON" \
    "$FED_DIR" \
    "$EPOCH" \
    "$FED_DIR/.agentis/experience" \
    "$FED_DIR/.agentis/logs" \
    "$TMPDIR_TEST/dash" \
    "$COLONY_LIST_JSON" \
    "" \
    2>/dev/null)"
if echo "$COLLECTOR_JSON_FAIL" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
c = (d.get('forge_rate_limits') or {}).get('$COLONY') or {}
assert c.get('remaining') is None, c
assert c.get('limit') is None, c
assert c.get('error'), c
" 2>"$TMPDIR_TEST/assert2.err"; then
    pass "7: collector tolerates non-zero exit and reports error field"
else
    fail "7: failure-mode handling broken" "stderr: $(cat "$TMPDIR_TEST/assert2.err")"
fi

# ---- Renderer end-to-end smoke ----
# Confirm the renderer substitutes COLLECTOR_JSON into the template without
# corrupting the new tile's JS.
OUT_HTML="$TMPDIR_TEST/index.html"
HISTORY_JSON='{"buckets":[]}'
REMEDIATION_JSON='[]'
python3 "$RENDERER" \
    "$TEMPLATE" \
    "$OUT_HTML" \
    "test-fed" \
    '"test-fed"' \
    "1" \
    "1" \
    "$EPOCH" \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$COLLECTOR_JSON" \
    "$HISTORY_JSON" \
    "$REMEDIATION_JSON" \
    "$COLONY_LIST_JSON" 2>"$TMPDIR_TEST/render.err" || true

if [ ! -s "$OUT_HTML" ]; then
    fail "8: renderer produced no output" "stderr: $(cat "$TMPDIR_TEST/render.err")"
elif grep -q '<h2>Forge Rate Limits</h2>' "$OUT_HTML" && grep -q 'forge_rate_limits' "$OUT_HTML"; then
    pass "8: rendered HTML contains the new tile"
else
    fail "8: rendered HTML missing tile markers"
fi

# ---- Summary ----
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
