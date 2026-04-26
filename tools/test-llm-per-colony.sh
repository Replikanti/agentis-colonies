#!/usr/bin/env bash
# tools/test-llm-per-colony.sh: per-colony [llm] config block + start-colony.sh
# wiring (#319 PR 1 of 5).
#
# Validates:
#   t1: no [llm] block at all in colony.toml -> zero --config-override flags
#       on the daemon CLI. Pre-#319 colonies stay byte-identical.
#   t2: [llm] backend = "mock" -> exactly one --config-override pair spliced
#       (llm.backend=mock).
#   t3: [llm] backend = "cli", command = "claude" -> two --config-override
#       pairs spliced (llm.backend=cli + llm.command=claude).
#   t4: [llm] backend = "http", model = "...", api_key_env = "..." -> three
#       --config-override pairs spliced (one per non-empty key).
#   t5: precedence guard — when both <fed>/.agentis/llm-backend-override
#       (cost-cap downgrade) and a populated [llm] block in colony.toml are
#       present, the override-file backend wins and the colony block is
#       ignored. This catches the precedence bug between #319 (per-colony
#       config) and the existing #318 cost-cap downgrade primitive.
#
# Each test builds a synthetic federation under /tmp/qa-319-pr1-fed/ and
# invokes start-colony.sh --restart-agent <name> with a shim `agentis` on
# PATH that records its argv to a file. The test then greps the recorded
# argv for the expected --config-override pairs.
#
# Auto-skips when the agentis binary is unreachable AND we cannot stand up
# the shim (which only needs bash + python3 — both are colony-lint
# prerequisites). In practice the shim is always available.
#
# Usage: ./tools/test-llm-per-colony.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

FIXTURE_ROOT="/tmp/qa-319-pr1-fed"
rm -rf "$FIXTURE_ROOT"
mkdir -p "$FIXTURE_ROOT"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

# The shim records every `agentis daemon ...` invocation's argv to
# AGENTIS_RECORD_FILE so the test can grep it for --config-override pairs.
# `daemon list` returns "[]" so the kill-before-spawn block in
# start-colony.sh exits early without trying to terminate anything.
build_shim() {
    local shim_dir="$1"
    local record_file="$2"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/agentis" <<'SHIM'
#!/usr/bin/env bash
# Stub `agentis` for the per-colony [llm] override test. Records argv on
# the `daemon <path> ...` invocation only; ignores `daemon list` and
# `memo set` so the start-colony.sh pre-flight runs to completion.
case "${1:-}" in
    daemon)
        if [ "${2:-}" = "list" ]; then
            printf '[]\n'
            exit 0
        fi
        # Record the daemon launch argv so the test can grep it.
        if [ -n "${AGENTIS_RECORD_FILE:-}" ]; then
            printf '%s\n' "$*" >> "$AGENTIS_RECORD_FILE"
        fi
        # Sleep just long enough for start-colony.sh's `sleep 0.5` +
        # `kill -0` liveness probe to see us as alive.
        sleep 1
        exit 0
        ;;
    memo)
        # Memo seed during full-colony bootstrap. Ignore.
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
SHIM
    chmod +x "$shim_dir/agentis"
}

# Build a minimal triage colony fixture under FIXTURE_ROOT/<tag>/. The
# start-colony.sh script is COPIED (not symlinked) so its symlink-
# resolved $0 -> SCRIPT_DIR -> REPO_ROOT walk lands inside the fixture,
# which is necessary for the cost-cap override-file precedence test
# (t5): the script reads `<fed-root>/.agentis/llm-backend-override`
# where `<fed-root>` is `$REPO_ROOT/dev-apprenticeship`. We symlink the
# tools/ tree so parse-toml.sh (and its python helper) is reached
# through the script's `. "$REPO_ROOT/tools/parse-toml.sh"` line.
make_colony_fixture() {
    local tag="$1"
    local llm_block="$2"
    local fed="$FIXTURE_ROOT/$tag/dev-apprenticeship"
    mkdir -p "$fed/triage/scripts" "$fed/triage/config" "$fed/triage/agents" "$fed/.agentis/logs"
    ln -sf "$REPO_ROOT/tools" "$FIXTURE_ROOT/$tag/tools"
    cp "$REPO_ROOT/dev-apprenticeship/triage/scripts/start-colony.sh" "$fed/triage/scripts/start-colony.sh"
    chmod +x "$fed/triage/scripts/start-colony.sh"
    ln -sf "$REPO_ROOT/dev-apprenticeship/triage/scripts/forge-api.sh"   "$fed/triage/scripts/forge-api.sh"
    ln -sf "$REPO_ROOT/dev-apprenticeship/triage/scripts/gitlab-api.sh"  "$fed/triage/scripts/gitlab-api.sh"
    ln -sf "$REPO_ROOT/dev-apprenticeship/triage/scripts/github-api.sh"  "$fed/triage/scripts/github-api.sh"
    # Stub agent file so the daemon launch argv contains the path.
    : > "$fed/triage/agents/labeler.ag"
    {
        printf '[forge]\ntype = "gitlab"\n\n'
        printf '[forge.gitlab]\nurl = "https://example.invalid"\ntoken = "fake"\nproject = "org/repo"\n\n'
        printf '%s\n' "$llm_block"
    } > "$fed/triage/config/colony.toml"
}

# Run start-colony.sh --restart-agent labeler for a fixture and capture
# the daemon-launch argv into the recorded file. Returns the exit code
# of start-colony.sh.
run_for_fixture() {
    local tag="$1"
    local shim_dir="$FIXTURE_ROOT/$tag/shim"
    local record_file="$FIXTURE_ROOT/$tag/agentis-argv.log"
    local fed="$FIXTURE_ROOT/$tag/dev-apprenticeship"
    build_shim "$shim_dir" "$record_file"
    : > "$record_file"
    # Restrict PATH to shim + minimum so the real agentis cannot leak in.
    PATH="$shim_dir:/usr/bin:/bin" \
        AGENTIS_RECORD_FILE="$record_file" \
        bash "$fed/triage/scripts/start-colony.sh" \
            --restart-agent labeler \
            "$fed/triage/config/colony.toml" \
            >"$FIXTURE_ROOT/$tag/start-colony.stdout" \
            2>"$FIXTURE_ROOT/$tag/start-colony.stderr" || true
    cat "$record_file"
}

# Count exact occurrences of `llm.<key>=<value>` lines in the recorded
# argv (across multiple --config-override token pairs).
override_count() {
    local recorded="$1"
    # Split on whitespace so the 'llm.foo=bar' tokens are one per line.
    printf '%s\n' "$recorded" | tr ' ' '\n' | grep -c '^llm\.' || true
}

assert_has_override() {
    local name="$1" recorded="$2" needle="$3"
    if printf '%s\n' "$recorded" | tr ' ' '\n' | grep -qx "$needle"; then
        pass "$name"
    else
        fail "$name" "expected token '$needle' missing from argv: $recorded"
    fi
}

assert_no_override() {
    local name="$1" recorded="$2"
    local count
    count=$(override_count "$recorded")
    if [ "$count" -eq 0 ]; then
        pass "$name"
    else
        fail "$name" "expected zero llm.* overrides, got $count: $recorded"
    fi
}

# ----- t1: no [llm] block at all -----
make_colony_fixture t1 ""
T1_OUT="$(run_for_fixture t1)"
assert_no_override "t1: colony.toml without [llm] emits zero --config-override flags" "$T1_OUT"

# ----- t2: [llm] backend = "mock" -----
make_colony_fixture t2 '[llm]
backend = "mock"'
T2_OUT="$(run_for_fixture t2)"
assert_has_override "t2: [llm] backend = mock splices --config-override llm.backend=mock" "$T2_OUT" "llm.backend=mock"
T2_COUNT=$(override_count "$T2_OUT")
if [ "$T2_COUNT" = "1" ]; then
    pass "t2: exactly one llm.* override emitted (got $T2_COUNT)"
else
    fail "t2: expected exactly 1 llm.* override, got $T2_COUNT" "argv=$T2_OUT"
fi

# ----- t3: [llm] backend = "cli", command = "claude" -----
make_colony_fixture t3 '[llm]
backend = "cli"
command = "claude"'
T3_OUT="$(run_for_fixture t3)"
assert_has_override "t3: [llm] cli backend splices llm.backend=cli"     "$T3_OUT" "llm.backend=cli"
assert_has_override "t3: [llm] cli backend splices llm.command=claude" "$T3_OUT" "llm.command=claude"
T3_COUNT=$(override_count "$T3_OUT")
if [ "$T3_COUNT" = "2" ]; then
    pass "t3: exactly two llm.* overrides emitted (got $T3_COUNT)"
else
    fail "t3: expected exactly 2 llm.* overrides, got $T3_COUNT" "argv=$T3_OUT"
fi

# ----- t4: [llm] backend = "http", model = "...", api_key_env = "..." -----
make_colony_fixture t4 '[llm]
backend = "http"
model = "claude-sonnet-4"
api_key_env = "ANTHROPIC_API_KEY"'
T4_OUT="$(run_for_fixture t4)"
assert_has_override "t4: [llm] http backend splices llm.backend=http"                         "$T4_OUT" "llm.backend=http"
assert_has_override "t4: [llm] http backend splices llm.model=claude-sonnet-4"               "$T4_OUT" "llm.model=claude-sonnet-4"
assert_has_override "t4: [llm] http backend splices llm.api_key_env=ANTHROPIC_API_KEY"       "$T4_OUT" "llm.api_key_env=ANTHROPIC_API_KEY"
T4_COUNT=$(override_count "$T4_OUT")
if [ "$T4_COUNT" = "3" ]; then
    pass "t4: exactly three llm.* overrides emitted (got $T4_COUNT)"
else
    fail "t4: expected exactly 3 llm.* overrides, got $T4_COUNT" "argv=$T4_OUT"
fi

# ----- t5: cost-cap override file precedence -----
# Both <fed>/.agentis/llm-backend-override (= "mock") AND a fully
# populated [llm] block in colony.toml are present. The override file
# must win — agents are downgraded to mock without leaking the colony's
# http config onto the daemon CLI. Per the function precedence comment:
# "downgrade should be a clean snap to mock without leaking colony-
# specific keys."
make_colony_fixture t5 '[llm]
backend = "http"
model = "claude-sonnet-4"
api_key_env = "ANTHROPIC_API_KEY"'
mkdir -p "$FIXTURE_ROOT/t5/dev-apprenticeship/.agentis"
echo "mock" > "$FIXTURE_ROOT/t5/dev-apprenticeship/.agentis/llm-backend-override"
T5_OUT="$(run_for_fixture t5)"
assert_has_override "t5: cost-cap override file -> llm.backend=mock spliced" "$T5_OUT" "llm.backend=mock"
T5_COUNT=$(override_count "$T5_OUT")
if [ "$T5_COUNT" = "1" ]; then
    pass "t5: cost-cap override wins — exactly one llm.* override emitted (got $T5_COUNT, [llm] block ignored)"
else
    fail "t5: expected exactly 1 llm.* override (cost-cap precedence), got $T5_COUNT" "argv=$T5_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
