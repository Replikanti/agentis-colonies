#!/bin/bash
# tools/test-start-colony-model-routing.sh: pin the per-agent reasoning-model
# routing added in #1451. The short-reply typed-JSON / binary-gate agents run
# on `CLAUDE_REASONING_MODEL=haiku` + `FLAT_CYBORG_RESULT_FILE=0` (screen-scrape
# mode); every other agent stays on `sonnet` + the default result-file channel
# (`FLAT_CYBORG_RESULT_FILE=1`), byte-identical to pre-#1451.
#
# The routing is wired as a per-agent env prefix on each `agentis daemon`
# launch inside start-colony.sh. Because flat-cyborg-claude.sh (the llm.command)
# is spawned as a direct subprocess of the daemon, it inherits that process env
# and reads the two vars via `${VAR:-default}` — so asserting the daemon's env
# per agent is the real regression signal.
#
# We do NOT need the agentis binary: a recording `agentis` shim on $PATH
# intercepts the daemon launch, records `<agent> model=<...> rf=<...>` captured
# from its own environment, then sleeps briefly and exits 0 so the script's
# `sleep 0.5` + `kill -0` liveness check passes and reaches `started ...`. We
# drive the `--restart-agent <name>` single-daemon path (fast, no 2s stagger)
# for every agent across the three edited colonies (triage, planning, release)
# and assert the recorded (model, result_file) pair. A `bash -n` parse assert
# per edited script guards syntax. The implementation and code-review colonies
# are intentionally NOT exercised: they have zero haiku agents and stay
# byte-identical.
#
# Usage: ./tools/test-start-colony-model-routing.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
cleanup() {
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# Each colony's start-colony.sh expects a populated [forge.gitlab] section.
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

# Recording `agentis` shim. On the daemon LAUNCH form (`agentis daemon <path>
# --colony ...`) it appends the resolved agent name plus the reasoning-model and
# result-file values it inherited from the launch env prefix to $RECORD_FILE,
# then sleeps 1s and exits 0 so the script's liveness check sees a live PID.
# `agentis daemon list --json` (queried by the restart-path kill-before-spawn
# block) returns an empty array so no PIDs are killed. Anything else is a no-op.
SHIM_DIR="$TMPDIR_TEST/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/agentis" <<'SHIM'
#!/bin/bash
if [ "${1:-}" = "daemon" ] && [ "${2:-}" = "list" ]; then
    printf '[]\n'
    exit 0
fi
if [ "${1:-}" = "daemon" ]; then
    agent="$(basename "${2:-}" .ag)"
    printf '%s model=%s rf=%s\n' \
        "$agent" \
        "${CLAUDE_REASONING_MODEL:-unset}" \
        "${FLAT_CYBORG_RESULT_FILE:-unset}" >> "$RECORD_FILE"
    sleep 1
    exit 0
fi
exit 0
SHIM
chmod +x "$SHIM_DIR/agentis"

# Per-colony expected routing: "<agent>=<model>/<result_file>". The 5 haiku
# agents (triage router/labeler/prioritizer, planning scope_estimator, release
# ship_decider) MUST record haiku/0; every other agent in these colonies MUST
# record sonnet/1 (byte-identical to today's single sonnet default). This table
# dual-sources the reasoning_route_for() cases in each script on purpose, so a
# routing drift breaks the test loudly.
expect_triage="router=haiku/0 labeler=haiku/0 prioritizer=haiku/0 issue_creator=sonnet/1"
expect_planning="scope_estimator=haiku/0 risk_assessor=sonnet/1 task_decomposer=sonnet/1 plan_reviewer=sonnet/1"
expect_release="ship_decider=haiku/0 release_checker=sonnet/1 changelog_writer=sonnet/1 version_bumper=sonnet/1"

test_colony_routing() {
    local colony="$1"
    local expect_str="$2"
    local script="$REPO_ROOT/dev-apprenticeship/$colony/scripts/start-colony.sh"

    if [ ! -x "$script" ]; then
        fail "$colony: start-colony.sh missing or not executable" "$script"
        return
    fi

    local pair agent want model_want rf_want
    for pair in $expect_str; do
        agent="${pair%%=*}"
        want="${pair#*=}"
        model_want="${want%%/*}"
        rf_want="${want#*/}"

        local record="$TMPDIR_TEST/$colony.$agent.record"
        : > "$record"
        local out="$TMPDIR_TEST/$colony.$agent.log"

        if ! PATH="$SHIM_DIR:$PATH" RECORD_FILE="$record" \
                bash "$script" --restart-agent "$agent" "$FIXTURE_TOML" >"$out" 2>&1; then
            rc=$?
            fail "$colony/$agent: --restart-agent returned rc=$rc" "body=$(head -c 200 "$out")"
            continue
        fi

        # The recording shim writes exactly one line for the daemon launch.
        local line
        line="$(grep -E "^$agent " "$record" 2>/dev/null | tail -1 || true)"
        if [ -z "$line" ]; then
            fail "$colony/$agent: no daemon-launch record captured" "record=$(head -c 200 "$record")"
            continue
        fi
        if [ "$line" = "$agent model=$model_want rf=$rf_want" ]; then
            pass "$colony/$agent: reasoning route $model_want + rf=$rf_want (#1451)"
        else
            fail "$colony/$agent: wrong route" "got '$line' want '$agent model=$model_want rf=$rf_want'"
        fi
    done
}

test_colony_routing triage   "$expect_triage"
test_colony_routing planning "$expect_planning"
test_colony_routing release  "$expect_release"

# Parse-check every edited script (bash -n) so a syntax slip in the helper or
# the env-prefixed launch lines fails here rather than at daemon-launch time.
test_parse() {
    local colony="$1"
    local script="$REPO_ROOT/dev-apprenticeship/$colony/scripts/start-colony.sh"
    if bash -n "$script" 2>"$TMPDIR_TEST/$colony.parse.err"; then
        pass "$colony: start-colony.sh parses (bash -n)"
    else
        fail "$colony: start-colony.sh bash -n failed" "$(head -c 200 "$TMPDIR_TEST/$colony.parse.err")"
    fi
}

test_parse triage
test_parse planning
test_parse release

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
