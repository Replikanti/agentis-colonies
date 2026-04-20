#!/bin/bash
# tools/test-dashboard-fedpath.sh: regression test for #238 — federation-dashboard
# must prefer the federation-local .agentis/ over the parent-level one when both
# exist, to avoid sibling federations cross-reading each other's experience/logs.
#
# Fixture layout:
#   $TMP/.agentis/logs/shared_agent.log     <- parent-level ("other federation")
#   $TMP/fed/.agentis/logs/local_agent.log  <- federation-local (the one we want)
#
# Expected: the served HTML renders local_agent's event, and does NOT render
# shared_agent's event (that one belongs to a sibling federation).
#
# Also re-verifies the symlinked single-federation layout: when
# $TMP/fed-sym/.agentis is a symlink to $TMP/.agentis, the dashboard still
# resolves through the local-first check and reads shared_agent as expected.
#
# Usage: ./tools/test-dashboard-fedpath.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DASHBOARD_SH="$SCRIPT_DIR/federation-dashboard.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
DASH_PIDS=""

cleanup() {
    for pid in $DASH_PIDS; do
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in $DASH_PIDS; do
        kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    done
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if [ ! -x "$DASHBOARD_SH" ]; then
    fail "0: dashboard script missing or not executable" "$DASHBOARD_SH"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

free_port() {
    python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); p=s.getsockname()[1]; s.close(); print(p)"
}

boot_dashboard() {
    local fed_dir="$1" port="$2" log_file="$3" cwd="${4:-}"
    if [ -n "$cwd" ]; then
        ( cd "$cwd" && setsid bash "$DASHBOARD_SH" "$fed_dir" "$port" >"$log_file" 2>&1 ) &
    else
        setsid bash "$DASHBOARD_SH" "$fed_dir" "$port" >"$log_file" 2>&1 &
    fi
    local pid=$!
    DASH_PIDS="$DASH_PIDS $pid"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if curl -f -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
        sleep 0.5
    done
    echo "DASHBOARD_NEVER_READY"
    return 1
}

# --- Shared parent-level .agentis/ (simulates the "other federation" data). ---
mkdir -p "$TMPDIR_TEST/.agentis/logs" "$TMPDIR_TEST/.agentis/daemon" "$TMPDIR_TEST/.agentis/experience"
cat > "$TMPDIR_TEST/.agentis/logs/shared_agent.log" <<'LOG'
1776250011452 emit shared:event from shared_parent_agent
LOG

# ============================================================================
# Case A: standalone-federation layout — federation-local .agentis/ exists.
# Dashboard must read from <fed>/.agentis/, NOT from <fed>/../.agentis/.
# ============================================================================
FED_A="$TMPDIR_TEST/fed"
mkdir -p "$FED_A/.agentis/logs" "$FED_A/.agentis/daemon" "$FED_A/.agentis/experience" \
         "$FED_A/stub-colony/agents" "$FED_A/stub-colony/config"

cat > "$FED_A/stub-colony/config/colony.toml" <<'TOML'
[colony]
name = "stub-colony"
TOML

cat > "$FED_A/stub-colony/agents/local_agent.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG

cat > "$FED_A/.agentis/logs/local_agent.log" <<'LOG'
1776250022999 emit local:only_in_federation_local
LOG

PORT_A="$(free_port)"
LOG_A="$TMPDIR_TEST/dashboard-A.log"
boot_dashboard "$FED_A" "$PORT_A" "$LOG_A" >/dev/null || {
    fail "A.0: standalone dashboard never became ready" "log tail: $(tail -10 "$LOG_A" 2>/dev/null | tr '\n' ' ')"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
}

HTML_A="$TMPDIR_TEST/index-A.html"
curl -s "http://127.0.0.1:$PORT_A/" -o "$HTML_A" || true

if [ ! -s "$HTML_A" ]; then
    fail "A.0: GET / returned empty body"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if grep -q 'local:only_in_federation_local' "$HTML_A"; then
    pass "A.1: standalone layout reads federation-local log"
else
    fail "A.1: standalone layout should render local_agent event" "missing local:only_in_federation_local"
fi

if grep -q 'shared:event' "$HTML_A"; then
    fail "A.2: standalone layout must NOT cross-read parent-level log" "found shared:event from parent-level .agentis"
else
    pass "A.2: standalone layout does not cross-read parent-level log"
fi

# ============================================================================
# Case B: symlinked single-federation layout — <fed>/.agentis -> ../.agentis.
# Dashboard must resolve through the symlink via the local-first check and
# read the shared parent-level log as expected.
# ============================================================================
FED_B="$TMPDIR_TEST/fed-sym"
mkdir -p "$FED_B/stub-colony/agents" "$FED_B/stub-colony/config"
ln -s "../.agentis" "$FED_B/.agentis"

cat > "$FED_B/stub-colony/config/colony.toml" <<'TOML'
[colony]
name = "stub-colony"
TOML

cat > "$FED_B/stub-colony/agents/sym_agent.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG

PORT_B="$(free_port)"
LOG_B="$TMPDIR_TEST/dashboard-B.log"
boot_dashboard "$FED_B" "$PORT_B" "$LOG_B" >/dev/null || {
    fail "B.0: symlinked dashboard never became ready" "log tail: $(tail -10 "$LOG_B" 2>/dev/null | tr '\n' ' ')"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
}

HTML_B="$TMPDIR_TEST/index-B.html"
curl -s "http://127.0.0.1:$PORT_B/" -o "$HTML_B" || true

if [ ! -s "$HTML_B" ]; then
    fail "B.0: GET / returned empty body"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if grep -q 'shared:event' "$HTML_B"; then
    pass "B.1: symlinked layout resolves through symlink to parent-level log"
else
    fail "B.1: symlinked layout should render shared_agent event" "missing shared:event"
fi

# ============================================================================
# Case C: cwd-fallback layout — neither $FED/.agentis nor $FED/../.agentis
# exists. Dashboard must fall through to the third arm of the precedence
# (`.agentis/logs` relative to cwd). Regression guard for the resolver's
# final fallback branch: if someone replaces the three-step precedence with
# a two-step one, Case C fails even though Cases A and B still pass.
#
# Layout is isolated under $TMPDIR_TEST/case-c/ so the shared parent-level
# .agentis/ at $TMPDIR_TEST/.agentis/ (used by Cases A and B) is NOT
# $FED_C/../.agentis — that would be $TMPDIR_TEST/case-c/.agentis/, which
# we deliberately leave absent to force the cwd fallback.
# ============================================================================
CASE_C_ROOT="$TMPDIR_TEST/case-c"
FED_C="$CASE_C_ROOT/fed"
CWD_C="$CASE_C_ROOT/cwd"
mkdir -p "$FED_C/stub-colony/agents" "$FED_C/stub-colony/config" \
         "$CWD_C/.agentis/logs" "$CWD_C/.agentis/daemon" "$CWD_C/.agentis/experience"

cat > "$FED_C/stub-colony/config/colony.toml" <<'TOML'
[colony]
name = "stub-colony"
TOML

cat > "$FED_C/stub-colony/agents/cwd_agent.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG

cat > "$CWD_C/.agentis/logs/cwd_agent.log" <<'LOG'
1776250033777 emit cwd:only_in_cwd_fallback
LOG

# Sanity: confirm fed-local and parent-level .agentis/ are absent so the
# dashboard MUST use cwd fallback, not a silently-working fed-local path.
if [ -d "$FED_C/.agentis" ] || [ -d "$CASE_C_ROOT/.agentis" ]; then
    fail "C.0: Case C fixture misconfigured — fed-local or parent .agentis/ exists"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

PORT_C="$(free_port)"
LOG_C="$TMPDIR_TEST/dashboard-C.log"
boot_dashboard "$FED_C" "$PORT_C" "$LOG_C" "$CWD_C" >/dev/null || {
    fail "C.0: cwd-fallback dashboard never became ready" "log tail: $(tail -10 "$LOG_C" 2>/dev/null | tr '\n' ' ')"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
}

HTML_C="$TMPDIR_TEST/index-C.html"
curl -s "http://127.0.0.1:$PORT_C/" -o "$HTML_C" || true

if [ ! -s "$HTML_C" ]; then
    fail "C.0: GET / returned empty body"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if grep -q 'cwd:only_in_cwd_fallback' "$HTML_C"; then
    pass "C.1: cwd-fallback layout reads .agentis/logs relative to cwd"
else
    fail "C.1: cwd-fallback layout should render cwd_agent event" "missing cwd:only_in_cwd_fallback"
fi

# Cases A and B's shared_agent log lives at $TMPDIR_TEST/.agentis/logs,
# which is NOT $FED_C/.agentis, NOT $FED_C/../.agentis, and NOT $CWD_C/.agentis.
# Verify it doesn't leak through — the resolver must not silently walk further
# up than the three defined arms.
if grep -q 'shared:event' "$HTML_C"; then
    fail "C.2: cwd-fallback layout must NOT reach an unrelated .agentis/ elsewhere on the filesystem" "found shared:event"
else
    pass "C.2: cwd-fallback layout does not leak unrelated parent-level .agentis/"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
