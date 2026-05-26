#!/usr/bin/env bash
# research-foundry/tools/test-prompt-timeout-flag.sh -- regression guard
# for #802. Every daemon spawn line emitted by `tools/run-research.sh`'s
# `write_bootstrap()` must carry `--prompt-timeout-s "$DAEMON_PROMPT_TIMEOUT_S"`
# so a stuck `prompt()` returns as a tick-level error within the
# configured wall-clock cap rather than holding the entire watchdog
# heartbeat budget (1800s by default) and inviting a SIGKILL on the
# daemon.
#
# The generated `bootstrap.sh` is the artifact operators ship to the
# container, so the test grep's the orchestrator source for every
# `agentis daemon /run-root/.../agents/<name>.ag` line and asserts each
# carries the `--prompt-timeout-s` flag. Pure grep, no agentis runtime
# or podman required.
#
# Assertions:
#   (a) The `DAEMON_PROMPT_TIMEOUT_S=<value>` line is emitted in the
#       bootstrap header (so the spawn lines have a value to interpolate).
#   (b) Every `agentis daemon /run-root/.../agents/<colony>.ag` spawn
#       line in `run-research.sh` carries `--prompt-timeout-s
#       "$DAEMON_PROMPT_TIMEOUT_S"`.
#   (c) The orchestrator exposes `RESEARCH_DAEMON_PROMPT_TIMEOUT_S` as
#       an operator-overridable env knob with a default fall-through.
#
# Usage: bash research-foundry/tools/test-prompt-timeout-flag.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"
ORCH="$FED_DIR/tools/run-research.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$ORCH" ]; then
    fail "orch exists" "$ORCH not found"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# (a) The bootstrap emits `DAEMON_PROMPT_TIMEOUT_S=<value>` so daemon
# lines have a value to interpolate via `"$DAEMON_PROMPT_TIMEOUT_S"`.
if grep -Fq "printf 'DAEMON_PROMPT_TIMEOUT_S=" "$ORCH"; then
    pass "(a) bootstrap emits DAEMON_PROMPT_TIMEOUT_S header"
else
    fail "(a) bootstrap emits DAEMON_PROMPT_TIMEOUT_S header" \
         "no printf 'DAEMON_PROMPT_TIMEOUT_S=...' line in $ORCH"
fi

# (b) Every daemon spawn line must carry --prompt-timeout-s. Extract all
# `agentis daemon /run-root/.../agents/<colony>.ag ...` lines and assert
# the flag appears on each.
spawn_lines="$(grep -F 'agentis daemon /run-root/' "$ORCH" | grep -v '^[[:space:]]*#')"
if [ -z "$spawn_lines" ]; then
    fail "(b) found daemon spawn lines" "no 'agentis daemon /run-root/' lines in $ORCH"
else
    spawn_count="$(printf '%s\n' "$spawn_lines" | wc -l | tr -d ' ')"
    missing_count=0
    missing_lines=""
    while IFS= read -r line; do
        case "$line" in
            *'--prompt-timeout-s'*) : ;;
            *)
                missing_count=$((missing_count + 1))
                missing_lines="${missing_lines}
${line}"
                ;;
        esac
    done <<EOF
$spawn_lines
EOF
    if [ "$missing_count" -eq 0 ]; then
        pass "(b) all $spawn_count daemon spawn lines carry --prompt-timeout-s"
    else
        fail "(b) all daemon spawn lines carry --prompt-timeout-s" \
             "$missing_count of $spawn_count spawn lines missing the flag:$missing_lines"
    fi
fi

# (c) Operator-overridable env knob with a default fall-through.
if grep -Eq '^DAEMON_PROMPT_TIMEOUT_S="\$\{RESEARCH_DAEMON_PROMPT_TIMEOUT_S:-[0-9]+\}"' "$ORCH"; then
    pass "(c) RESEARCH_DAEMON_PROMPT_TIMEOUT_S env knob with default"
else
    fail "(c) RESEARCH_DAEMON_PROMPT_TIMEOUT_S env knob with default" \
         "no DAEMON_PROMPT_TIMEOUT_S=\${RESEARCH_DAEMON_PROMPT_TIMEOUT_S:-NNN} assignment in $ORCH"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
