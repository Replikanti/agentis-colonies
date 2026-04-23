#!/bin/bash
# tools/test-start-colony-restart.sh: verify every colony's start-colony.sh
# supports the --restart-agent flag added in #257 for the federation-
# dashboard decoupling work.
#
# Without actually launching `agentis daemon`, we exercise the script's
# argument parser and agent-name validation paths:
#   - exit 2 on unknown flag
#   - exit 2 on --restart-agent with no argument
#   - exit 3 on --restart-agent with an agent name not in AGENTS=()
#
# We cannot exercise the happy path (exit 0) from a unit test without
# the agentis binary, but we can prove the script gets into the respawn
# branch by shimming $PATH so that `agentis daemon ...` is a no-op and
# then asserting the "started ..." stdout line is printed.
#
# Usage: ./tools/test-start-colony-restart.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# Each colony's start-colony.sh expects a populated [forge.gitlab] section
# (the legacy top-level [gitlab] section was retired in #256 PR 7 / v1.0.0).
# Shared minimal TOML for all five colonies.
FIXTURE_TOML="$TMPDIR_TEST/colony.toml"
cat > "$FIXTURE_TOML" <<'TOML'
[forge]
type = "gitlab"

[forge.gitlab]
url = "https://example.invalid"
token = "fake"
project = "org/repo"
me = "tester"
default_branch = "main"

[planning]
trigger_label = "needs-planning"

[implementation]
trigger_label = "implementation"
TOML

# Shim dir that intercepts `agentis` so the respawn branch does not try
# to launch a real daemon. PATH is prepended with this dir via env so
# start-colony.sh picks it up on both the happy path and the pre-flight
# memo-seeding path (which invokes `agentis memo set`).
SHIM_DIR="$TMPDIR_TEST/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/agentis" <<'SHIM'
#!/bin/bash
# Stub: swallow any subcommand, exit 0. Daemon "launch" becomes an
# immediate no-op that returns instantly — start-colony.sh's sleep 0.5
# + kill -0 liveness check then fails, but that's fine: we're testing
# argument parsing and branching, not liveness.
sleep 1
exit 0
SHIM
chmod +x "$SHIM_DIR/agentis"

# The expected AGENTS list per colony — must match the AGENTS=() arrays
# inside each start-colony.sh. If a colony gains/removes an agent, update
# both here and in the source script; this dual-sourcing is intentional,
# so the test breaks loudly when the two drift.
agents_triage="issue_creator labeler prioritizer router"
agents_planning="scope_estimator risk_assessor task_decomposer plan_reviewer"
agents_implementation="code_writer test_writer refactorer commit_composer"
agents_code_review="style_reviewer logic_reviewer security_reviewer test_reviewer approval_decider"
agents_release="release_checker ship_decider changelog_writer version_bumper"

test_one_colony() {
    local colony="$1"
    local agents_str="$2"
    local first_agent
    first_agent="$(echo "$agents_str" | awk '{print $1}')"
    local script="$REPO_ROOT/dev-apprenticeship/$colony/scripts/start-colony.sh"

    if [ ! -x "$script" ]; then
        fail "$colony: start-colony.sh missing or not executable" "$script"
        return
    fi

    # --- unknown flag => exit 2 ---
    out="$TMPDIR_TEST/$colony.unknown.log"
    if bash "$script" --bogus-flag "$FIXTURE_TOML" >"$out" 2>&1; then
        fail "$colony: --bogus-flag should fail but exited 0"
    else
        rc=$?
        if [ "$rc" = "2" ] && grep -q 'unknown flag' "$out"; then
            pass "$colony: unknown flag => exit 2 with error message"
        else
            fail "$colony: unknown flag => wrong exit/message" "rc=$rc body=$(head -c 200 "$out")"
        fi
    fi

    # --- --restart-agent with no argument => exit 2 ---
    out="$TMPDIR_TEST/$colony.noarg.log"
    if bash "$script" --restart-agent >"$out" 2>&1; then
        fail "$colony: --restart-agent with no arg should fail but exited 0"
    else
        rc=$?
        if [ "$rc" = "2" ] && grep -q 'requires an agent name' "$out"; then
            pass "$colony: --restart-agent without arg => exit 2 with error message"
        else
            fail "$colony: --restart-agent missing arg => wrong exit/message" "rc=$rc body=$(head -c 200 "$out")"
        fi
    fi

    # --- --restart-agent <unknown> => exit 3 ---
    out="$TMPDIR_TEST/$colony.unkagent.log"
    if PATH="$SHIM_DIR:$PATH" bash "$script" --restart-agent not_a_real_agent "$FIXTURE_TOML" >"$out" 2>&1; then
        fail "$colony: unknown agent should fail but exited 0"
    else
        rc=$?
        if [ "$rc" = "3" ] && grep -q "unknown agent 'not_a_real_agent'" "$out"; then
            pass "$colony: unknown agent => exit 3 with error message"
        else
            fail "$colony: unknown agent => wrong exit/message" "rc=$rc body=$(head -c 200 "$out")"
        fi
    fi

    # --- happy-path smoke: valid agent name reaches the 'started ...' line. ---
    # The shim's agentis daemon sleeps 1s and exits 0; the script's sleep 0.5
    # + kill -0 check comes BEFORE the agentis exit, so it sees the PID
    # alive and prints "started ... pid=... tick=...". The script will
    # then exit 0.
    out="$TMPDIR_TEST/$colony.happy.log"
    if PATH="$SHIM_DIR:$PATH" bash "$script" --restart-agent "$first_agent" "$FIXTURE_TOML" >"$out" 2>&1; then
        if grep -qE "^started $first_agent pid=[0-9]+ tick=[0-9]+$" "$out"; then
            pass "$colony: valid agent name reaches 'started <name> pid=<n> tick=<ms>' stdout line"
        else
            fail "$colony: happy path exit 0 but stdout line malformed" "body=$(head -c 300 "$out")"
        fi
    else
        rc=$?
        fail "$colony: happy path non-zero exit" "rc=$rc body=$(head -c 300 "$out")"
    fi

    # --- pipe-regression: the dashboard invokes start-colony.sh via
    # subprocess.run(capture_output=True, timeout=N). If the backgrounded
    # daemon inherits those capture pipes, Python blocks on read until its
    # own timeout fires, producing spurious "restart failed" responses on
    # every /restart. This test uses a shim that lives LONGER than the
    # subprocess.run timeout; if stdio is detached from the inherited
    # pipes the script returns in ~0.6s, otherwise Python hits TimeoutExpired.
    out="$TMPDIR_TEST/$colony.pipe.log"
    SHIM_PIPE_DIR="$TMPDIR_TEST/shim_pipe_$colony"
    mkdir -p "$SHIM_PIPE_DIR"
    cat > "$SHIM_PIPE_DIR/agentis" <<'SHIM'
#!/bin/bash
sleep 5
exit 0
SHIM
    chmod +x "$SHIM_PIPE_DIR/agentis"
    py_out="$(PATH="$SHIM_PIPE_DIR:$PATH" python3 - "$script" "$first_agent" "$FIXTURE_TOML" <<'PYEOF' 2>&1
import subprocess, sys, time
start = time.time()
try:
    r = subprocess.run(
        ['bash', sys.argv[1], '--restart-agent', sys.argv[2], sys.argv[3]],
        capture_output=True, text=True, timeout=3,
    )
    elapsed = time.time() - start
    print(f'OK rc={r.returncode} elapsed={elapsed:.2f} stdout={r.stdout.strip()!r}')
except subprocess.TimeoutExpired as e:
    elapsed = time.time() - start
    print(f'TIMEOUT elapsed={elapsed:.2f} stdout={(e.stdout or b"").decode(errors="replace").strip()!r}')
    sys.exit(1)
PYEOF
    )" && py_rc=0 || py_rc=$?
    echo "$py_out" > "$out"
    if [ "$py_rc" = "0" ] && echo "$py_out" | grep -q '^OK rc=0' \
         && echo "$py_out" | grep -qE "started $first_agent pid=[0-9]+ tick=[0-9]+"; then
        pass "$colony: restart returns promptly under subprocess.run(capture_output=True) (no pipe inheritance)"
    else
        fail "$colony: subprocess.run(capture_output=True) hangs or fails — daemon stdio likely inherited" "body=$(head -c 300 "$out")"
    fi
    # Clean up the long-sleeping fake daemon so it doesn't linger past the test.
    pkill -f "$SHIM_PIPE_DIR/agentis" 2>/dev/null || true
}

test_one_colony triage         "$agents_triage"
test_one_colony planning       "$agents_planning"
test_one_colony implementation "$agents_implementation"
test_one_colony code-review    "$agents_code_review"
test_one_colony release        "$agents_release"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
