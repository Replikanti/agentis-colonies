#!/usr/bin/env bash
# tools/test-llm-per-colony.sh: per-colony [llm] config block + start-colony.sh
# wiring (#319 PR 1 of 5; reduced to NO-RUNTIME-EFFECT in #351 — see below).
#
# Validates the post-#351 contract:
#
#   `agentis daemon` does NOT accept `--config-override` (the flag was
#   referenced in colonies docs but never landed upstream). PR #348 spliced
#   it anyway, breaking every restart on any colony with either a [llm]
#   block or a cost-cap downgrade override file. #351 removes the splice;
#   the [llm] block stays in the schema as forward-compatible documentation
#   but emits no daemon flags. Cost-cap downgrade (#318) is also reduced to
#   no-op until upstream lands the flag.
#
#   t1: no [llm] block at all -> zero --config-override flags. Same as old.
#   t2: [llm] backend = "mock" -> still zero --config-override flags
#       (post-#351 the splice is a no-op so the block has no runtime effect).
#       restart-agent must succeed (the regression we're guarding against).
#   t3: [llm] backend = "cli", command = "claude" -> zero overrides, restart
#       still succeeds. Same shape as t2 but verifies multiple keys also
#       silently no-op.
#   t4: [llm] http with three keys -> zero overrides, restart succeeds.
#   t5: cost-cap override file (= "mock") + [llm] http block both present
#       -> zero overrides emitted, restart still succeeds. The file write is
#       harmless; agents fall through to <fed>/.agentis/config.
#   t6 (regression): the literal token `--config-override` MUST NEVER appear
#       in the recorded argv across any t1-t5 run. This is the primary
#       safety net catching any future re-introduction of the splice before
#       upstream ships the flag.
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

# Per-run unique fixture root (#1008). A fixed path like /tmp/qa-319-pr1-fed
# collides when several copies of this test run concurrently (sibling
# worktrees on one host under a shared colony-lint pipeline): one copy's
# startup `rm -rf` or EXIT-trap cleanup wipes another copy's
# start-colony.stdout mid-flight, so assert_restart_ok reads an empty file
# and the t5 subcase fails with empty stdout AND stderr. mktemp -d gives
# each run its own tree, so two concurrent runs never touch each other's
# fixtures. TMPDIR is honoured when set.
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/qa-319-pr1-fed.XXXXXX")"
# Cleanup reaps both the fixture tree AND any still-sleeping shim daemons
# this run backgrounded. The shims' argv embeds the unique $FIXTURE_ROOT
# path, so `pkill -f` matches ONLY this run's processes — a concurrent copy
# (different mktemp dir) is never hit. This is the #1008 host-global-marker
# rule applied here: scope every pgrep/pkill to a per-run unique token.
cleanup() {
    pkill -f "$FIXTURE_ROOT" 2>/dev/null || true
    rm -rf "$FIXTURE_ROOT"
}
trap cleanup EXIT

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
        # #1008: deterministic readiness, not a sleep-vs-sleep race. The
        # OLD shim slept a fixed 1s "just long enough for start-colony.sh's
        # `sleep 0.5`"; under host CPU contention either side's scheduling
        # could slip and start-colony.sh's `kill -0` probe could miss us, so
        # no `started` line was printed and the harness read empty stdout.
        # Instead, drop a sentinel the instant we're up (so the harness can
        # poll for genuine readiness) and then stay alive long enough for the
        # liveness probe to observe us regardless of load. AGENTIS_READY_FILE
        # is exported by run_for_fixture.
        if [ -n "${AGENTIS_READY_FILE:-}" ]; then
            : > "$AGENTIS_READY_FILE"
        fi
        sleep 5
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

# Retry-with-backoff read of the recorded argv file. The shim `agentis`
# appends to `$record_file` via `>>` from a forked child of start-colony.sh,
# and our follow-up read can race the kernel flush of that append on busy
# hosts. Up to 10 attempts x 150ms backoff (~1.5s ceiling) suppresses the
# race without changing the shim or start-colony.sh. See #509 (flush race)
# and #257 (the underlying `--restart-agent` flow that owns the real
# ordering bug).
read_recorded_argv() {
    local record_file="$1"
    local content=""
    local _i
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        content="$(cat "$record_file" 2>/dev/null || true)"
        [ -n "$content" ] && break
        sleep 0.15
    done
    printf '%s' "$content"
}

# Run start-colony.sh --restart-agent labeler for a fixture and capture
# the daemon-launch argv into the recorded file. Returns the exit code
# of start-colony.sh.
run_for_fixture() {
    local tag="$1"
    local shim_dir="$FIXTURE_ROOT/$tag/shim"
    local record_file="$FIXTURE_ROOT/$tag/agentis-argv.log"
    local ready_file="$FIXTURE_ROOT/$tag/daemon-ready"
    local fed="$FIXTURE_ROOT/$tag/dev-apprenticeship"
    build_shim "$shim_dir" "$record_file"
    : > "$record_file"
    rm -f "$ready_file"
    # Restrict PATH to shim + minimum so the real agentis cannot leak in.
    # AGENTIS_READY_FILE (#1008) is the deterministic readiness sentinel the
    # shim touches the instant the simulated daemon is up.
    PATH="$shim_dir:/usr/bin:/bin" \
        AGENTIS_RECORD_FILE="$record_file" \
        AGENTIS_READY_FILE="$ready_file" \
        bash "$fed/triage/scripts/start-colony.sh" \
            --restart-agent labeler \
            "$fed/triage/config/colony.toml" \
            >"$FIXTURE_ROOT/$tag/start-colony.stdout" \
            2>"$FIXTURE_ROOT/$tag/start-colony.stderr" || true
    read_recorded_argv "$record_file"
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

assert_no_config_override_token() {
    local name="$1" recorded="$2"
    if printf '%s\n' "$recorded" | tr ' ' '\n' | grep -qx -- '--config-override'; then
        fail "$name" "FORBIDDEN '--config-override' token leaked into argv (regression of #351): $recorded"
    else
        pass "$name"
    fi
}

assert_restart_ok() {
    local name="$1" tag="$2"
    # start-colony.sh exits 0 on success and prints `started <agent> pid=<n> tick=<ms>`.
    #
    # #1008: deterministic readiness. The shim touches AGENTIS_READY_FILE the
    # instant the simulated daemon is up (not a fixed sleep), so the daemon's
    # liveness is load-independent. We poll for BOTH signals with a bounded
    # `until`-style loop + timeout ceiling: the readiness sentinel (proves the
    # daemon came up) and the `started` stdout line (proves start-colony.sh
    # parsed + printed its contract). Polling, not sleeping, removes the
    # sleep-vs-sleep race regardless of host CPU contention. The fixture dir is
    # per-run unique (mktemp) so a concurrent copy can no longer delete this
    # run's stdout mid-flight, which was the empty-stdout/empty-stderr failure.
    local stdout_file="$FIXTURE_ROOT/$tag/start-colony.stdout"
    local ready_file="$FIXTURE_ROOT/$tag/daemon-ready"
    local _i
    for _i in $(seq 1 200); do  # 200 x 50ms = 10s ceiling, ample under load
        if [ -f "$ready_file" ] && grep -qE '^started ' "$stdout_file" 2>/dev/null; then
            pass "$name"
            return 0
        fi
        sleep 0.05
    done
    fail "$name" "expected 'started <agent>' line in stdout: $(cat "$stdout_file" 2>/dev/null) / stderr: $(cat "$FIXTURE_ROOT/$tag/start-colony.stderr" 2>/dev/null) / ready=$([ -f "$ready_file" ] && echo yes || echo no)"
}

# ----- t1: no [llm] block at all -----
make_colony_fixture t1 ""
T1_OUT="$(run_for_fixture t1)"
assert_no_override "t1: colony.toml without [llm] emits zero llm.* overrides" "$T1_OUT"
assert_no_config_override_token "t1: --config-override token absent (post-#351)" "$T1_OUT"
assert_restart_ok "t1: --restart-agent succeeds" t1

# ----- t2: [llm] backend = "mock" — schema-only, no runtime effect -----
make_colony_fixture t2 '[llm]
backend = "mock"'
T2_OUT="$(run_for_fixture t2)"
assert_no_override "t2: [llm] mock present but emits zero llm.* overrides (#351)" "$T2_OUT"
assert_no_config_override_token "t2: --config-override token absent" "$T2_OUT"
assert_restart_ok "t2: --restart-agent succeeds with [llm] block" t2

# ----- t3: [llm] backend = "cli", command = "claude" — schema-only -----
make_colony_fixture t3 '[llm]
backend = "cli"
command = "claude"'
T3_OUT="$(run_for_fixture t3)"
assert_no_override "t3: [llm] cli + command keys emit zero overrides" "$T3_OUT"
assert_no_config_override_token "t3: --config-override token absent" "$T3_OUT"
assert_restart_ok "t3: --restart-agent succeeds with multi-key [llm]" t3

# ----- t4: [llm] http full block — schema-only -----
make_colony_fixture t4 '[llm]
backend = "http"
model = "claude-sonnet-4"
api_key_env = "ANTHROPIC_API_KEY"'
T4_OUT="$(run_for_fixture t4)"
assert_no_override "t4: [llm] http full block emits zero overrides" "$T4_OUT"
assert_no_config_override_token "t4: --config-override token absent" "$T4_OUT"
assert_restart_ok "t4: --restart-agent succeeds with full http [llm]" t4

# ----- t5: cost-cap override file present — also no-op until upstream flag lands -----
# Pre-#351 the override file's "mock" value was spliced as
# --config-override llm.backend=mock and broke the spawn (agentis didn't
# accept the flag). Post-#351 the file is harmless: the helper emits
# nothing, the daemon inherits federation-wide config, and the operator-
# triggered restart succeeds. Cost-cap downgrade itself stays broken until
# upstream agentis ships --config-override (filed as #351's track 2).
make_colony_fixture t5 '[llm]
backend = "http"
model = "claude-sonnet-4"
api_key_env = "ANTHROPIC_API_KEY"'
mkdir -p "$FIXTURE_ROOT/t5/dev-apprenticeship/.agentis"
echo "mock" > "$FIXTURE_ROOT/t5/dev-apprenticeship/.agentis/llm-backend-override"
T5_OUT="$(run_for_fixture t5)"
assert_no_override "t5: cost-cap override file present, but emits zero overrides post-#351" "$T5_OUT"
assert_no_config_override_token "t5: --config-override token absent even with override file present" "$T5_OUT"
assert_restart_ok "t5: --restart-agent succeeds with both override file AND [llm] block" t5

# ----- t6 (regression): aggregate check across all 5 prior tests -----
# Walks every recorded argv file and asserts the literal --config-override
# token is absent. This is the primary safety net for future drift.
ALL_RECORDED=""
for tag in t1 t2 t3 t4 t5; do
    # Re-read via the retry helper for the same flush-race reason
    # documented above (#509).
    ALL_RECORDED="$ALL_RECORDED $(read_recorded_argv "$FIXTURE_ROOT/$tag/agentis-argv.log")"
done
if printf '%s\n' "$ALL_RECORDED" | tr ' ' '\n' | grep -qx -- '--config-override'; then
    fail "t6: --config-override token leaked across one of t1-t5" "$ALL_RECORDED"
else
    pass "t6: --config-override never appears in any recorded argv (regression guard for #351)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
