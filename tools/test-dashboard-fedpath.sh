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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# #252: dashboard extracted to standalone component.
DASHBOARD_SH="$REPO_ROOT/federation-dashboard/bin/federation-dashboard"

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
    # Defense-in-depth: reap any python federation-dashboard-server.py child the
    # process-group kill missed, scoped to this test's temp dir so a real
    # production dashboard is never touched (#1300).
    pkill -f "federation-dashboard-server.py.*$TMPDIR_TEST" 2>/dev/null || true
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
    # Launch the wrapper under setsid so it leads its own process group: $! is
    # then the real group-leader PID, and cleanup()'s `kill -TERM "-$pid"` reaps
    # the wrapper AND its python federation-dashboard-server.py child. The old
    # un-setsid'd `( ... ) &` recorded a non-leader subshell PID, so the
    # negative-PID group kill was a no-op and every booted server orphaned
    # across colony-lint runs (#1300).
    if [ -n "$cwd" ]; then
        # shellcheck disable=SC2016  # $1-$4 are the inner bash -c argv, expanded by the inner shell, not here.
        setsid bash -c 'cd "$1" && exec bash "$2" "$3" "$4"' _ \
            "$cwd" "$DASHBOARD_SH" "$fed_dir" "$port" >"$log_file" 2>&1 < /dev/null &
    else
        setsid bash "$DASHBOARD_SH" "$fed_dir" "$port" >"$log_file" 2>&1 < /dev/null &
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

# ============================================================================
# Case D (#288): wrapper must `cd "$FED_DIR"` for `agentis ...` invocations.
# `agentis` resolves .agentis/ via cwd. If the wrapper inherits a cwd outside
# the federation root (e.g. systemd-run --user defaults to $HOME), then
# `agentis daemon list --json` returns [] and the collector renders every
# agent as state=stopped/health=unknown even when the federation is alive.
#
# Fixture: 21 stub agents across 5 colonies. Mock `agentis` on $PATH that
# emits 21 running-daemon JSON records ONLY when $PWD ends with the fixture
# fed dir name; otherwise emits []. Boot wrapper from cd /tmp (outside the
# fixture). Post-fix, the rendered HTML's agents array reports
# state=running × 21 because the wrapper subshell-cd's into $FED_DIR.
# Pre-fix, this assertion fails with state=stopped × 21.
# ============================================================================
CASE_D_ROOT="$TMPDIR_TEST/case-d"
FED_D="$CASE_D_ROOT/fixture-fed"
mkdir -p "$FED_D/.agentis/logs" "$FED_D/.agentis/daemon" "$FED_D/.agentis/experience"

# Five colonies × varying agent counts to total 21 (mirrors dev-apprenticeship
# shape but the names are arbitrary — the mock returns all of them).
D_COLONIES="triage code-review planning implementation release"
D_AGENTS_triage="router prioritizer labeler issue_creator"
D_AGENTS_code_review="logic_reviewer style_reviewer security_reviewer test_reviewer approval_decider"
D_AGENTS_planning="scope_estimator risk_assessor task_decomposer plan_reviewer"
D_AGENTS_implementation="code_writer test_writer refactorer commit_composer"
D_AGENTS_release="ship_decider changelog_writer version_bumper release_checker"

for col in $D_COLONIES; do
    mkdir -p "$FED_D/$col/agents" "$FED_D/$col/config"
    cat > "$FED_D/$col/config/colony.toml" <<TOML
[colony]
name = "$col"
TOML
done

# Generate 21 .ag files (one per agent name above).
add_agent() {
    local col="$1" name="$2"
    cat > "$FED_D/$col/agents/$name.ag" <<AG
cb 100;
fn tick() { return Void; }
AG
}
for a in $D_AGENTS_triage; do add_agent triage "$a"; done
for a in $D_AGENTS_code_review; do add_agent code-review "$a"; done
for a in $D_AGENTS_planning; do add_agent planning "$a"; done
for a in $D_AGENTS_implementation; do add_agent implementation "$a"; done
for a in $D_AGENTS_release; do add_agent release "$a"; done

# Mock agentis. Only emits daemon JSON when cwd basename matches the fixture
# fed dir name — that mirrors how real `agentis` reads .agentis/ relative to
# cwd and so detects whether the dashboard wrapper actually cd'd into FED_DIR.
MOCK_BIN_D="$CASE_D_ROOT/bin"
mkdir -p "$MOCK_BIN_D"
FED_D_NAME="$(basename "$FED_D")"
cat > "$MOCK_BIN_D/agentis" <<MOCK
#!/bin/bash
# Mock agentis for #288 regression test.
# Emits 21 running-daemon JSON only when invoked with cwd inside the fixture
# fed dir; emits [] otherwise. Treats remediation history as always [].
sub="\${1:-}"
if [ "\$sub" = "daemon" ] && [ "\${2:-}" = "list" ]; then
    if [ "\$(basename "\$PWD")" = "$FED_D_NAME" ]; then
        cat <<'JSON'
[
  {"source":"$FED_D/triage/agents/router.ag","agent_id":"a01","state":"running","health":"healthy","pid":1001,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/triage/agents/prioritizer.ag","agent_id":"a02","state":"running","health":"healthy","pid":1002,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/triage/agents/labeler.ag","agent_id":"a03","state":"running","health":"healthy","pid":1003,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/triage/agents/issue_creator.ag","agent_id":"a04","state":"running","health":"healthy","pid":1004,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/code-review/agents/logic_reviewer.ag","agent_id":"a05","state":"running","health":"healthy","pid":1005,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/code-review/agents/style_reviewer.ag","agent_id":"a06","state":"running","health":"healthy","pid":1006,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/code-review/agents/security_reviewer.ag","agent_id":"a07","state":"running","health":"healthy","pid":1007,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/code-review/agents/test_reviewer.ag","agent_id":"a08","state":"running","health":"healthy","pid":1008,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/code-review/agents/approval_decider.ag","agent_id":"a09","state":"running","health":"healthy","pid":1009,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/planning/agents/scope_estimator.ag","agent_id":"a10","state":"running","health":"healthy","pid":1010,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/planning/agents/risk_assessor.ag","agent_id":"a11","state":"running","health":"healthy","pid":1011,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/planning/agents/task_decomposer.ag","agent_id":"a12","state":"running","health":"healthy","pid":1012,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/planning/agents/plan_reviewer.ag","agent_id":"a13","state":"running","health":"healthy","pid":1013,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/implementation/agents/code_writer.ag","agent_id":"a14","state":"running","health":"healthy","pid":1014,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/implementation/agents/test_writer.ag","agent_id":"a15","state":"running","health":"healthy","pid":1015,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/implementation/agents/refactorer.ag","agent_id":"a16","state":"running","health":"healthy","pid":1016,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/implementation/agents/commit_composer.ag","agent_id":"a17","state":"running","health":"healthy","pid":1017,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/release/agents/ship_decider.ag","agent_id":"a18","state":"running","health":"healthy","pid":1018,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/release/agents/changelog_writer.ag","agent_id":"a19","state":"running","health":"healthy","pid":1019,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/release/agents/version_bumper.ag","agent_id":"a20","state":"running","health":"healthy","pid":1020,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""},
  {"source":"$FED_D/release/agents/release_checker.ag","agent_id":"a21","state":"running","health":"healthy","pid":1021,"started_at":1,"confidence":0.5,"confidence_generation":1,"confidence_written_at":1,"tick_ok":1,"tick_err":0,"quarantine":""}
]
JSON
        exit 0
    fi
    echo '[]'
    exit 0
fi
# Any other subcommand (remediation history etc.) — return harmless [] so the
# wrapper keeps going. We're only asserting on daemon-state derivation here.
echo '[]'
exit 0
MOCK
chmod +x "$MOCK_BIN_D/agentis"

PORT_D="$(free_port)"
LOG_D="$TMPDIR_TEST/dashboard-D.log"

# Boot wrapper from /tmp (cwd != FED_D) with the mock agentis on PATH.
# The wrapper inherits /tmp as cwd — exactly the systemd-run --user failure
# mode #288 reproduces. setsid -> own process group so cleanup()'s negative-PID
# kill reaps the wrapper + python child instead of orphaning them (#1300).
# shellcheck disable=SC2016  # $1-$4 are the inner bash -c argv, expanded by the inner shell, not here.
setsid bash -c 'cd /tmp && PATH="$1:$PATH" exec bash "$2" "$3" "$4"' _ \
    "$MOCK_BIN_D" "$DASHBOARD_SH" "$FED_D" "$PORT_D" >"$LOG_D" 2>&1 < /dev/null &
DASH_PID_D=$!
DASH_PIDS="$DASH_PIDS $DASH_PID_D"

ready_d=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -f -s -o /dev/null "http://127.0.0.1:$PORT_D/" 2>/dev/null; then
        ready_d=1
        break
    fi
    sleep 0.5
done
if [ "$ready_d" -ne 1 ]; then
    fail "D.0: cwd-fix dashboard never became ready" "log tail: $(tail -10 "$LOG_D" 2>/dev/null | tr '\n' ' ')"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

HTML_D="$TMPDIR_TEST/index-D.html"
curl -s "http://127.0.0.1:$PORT_D/" -o "$HTML_D" || true

if [ ! -s "$HTML_D" ]; then
    fail "D.0: GET / returned empty body"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Extract the agents array from the rendered HTML and tally state values.
# Pre-fix this returns 21 stopped, 0 running. Post-fix it returns 21 running.
RUN_COUNT="$(python3 -c '
import re, json, sys
with open(sys.argv[1]) as f:
    html = f.read()
m = re.search(r"\"agents\"\s*:\s*(\[.+?\])\s*,\s*\"experience", html, re.DOTALL)
if not m:
    print("0")
    sys.exit(0)
agents = json.loads(m.group(1))
print(sum(1 for a in agents if a.get("state") == "running"))
' "$HTML_D")"

if [ "$RUN_COUNT" = "21" ]; then
    pass "D.1: wrapper subshell-cd's into FED_DIR so agentis returns 21 running daemons"
else
    fail "D.1: wrapper inherited cwd and lost daemon list" "expected 21 running, got $RUN_COUNT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
