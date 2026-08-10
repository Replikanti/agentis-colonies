#!/bin/bash
# tools/test-colony-lint-bash32.sh: bash-3.2 compat smoke for colony-lint.sh.
#
# Verifies that:
#   1. tools/colony-lint.sh parses under the host bash.
#   2. tools/colony-lint.sh parses under bash-3.2 when available (stock macOS
#      /bin/bash). Skipped when no bash-3.2 binary is on PATH.
#   3. tools/colony-lint-flag-allowlist.awk parses (awk -f ... </dev/null).
#
# Background: #271 — the awk literal that lived inline at colony-lint.sh:179
# tickled the same bash 3.2 parser bug already worked around for the
# auto-promote.sh family in #245 / #172. Extracting the awk body to a
# separate file (loaded via awk -f) keeps the shell script free of
# heredoc / quoting shapes that bash 3.2 miscompiles.
#
# Usage: ./tools/test-colony-lint-bash32.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/colony-lint.sh"
AWK_FILE="$SCRIPT_DIR/colony-lint-flag-allowlist.awk"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; }

if [ ! -f "$LINT" ]; then
    fail "colony-lint.sh not found: $LINT"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if [ ! -f "$AWK_FILE" ]; then
    fail "allowlist awk file not found: $AWK_FILE"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 1: host bash parses colony-lint.sh ---
if bash -n "$LINT" 2>/tmp/colony-lint-bash32-err.$$; then
    pass "bash -n colony-lint.sh"
else
    fail "bash -n colony-lint.sh failed: $(cat /tmp/colony-lint-bash32-err.$$)"
fi
rm -f /tmp/colony-lint-bash32-err.$$

# --- Test 2: bash-3.2 parses colony-lint.sh (when available) ---
if command -v bash-3.2 >/dev/null 2>&1; then
    if bash-3.2 -n "$LINT" 2>/tmp/colony-lint-bash32-err.$$; then
        pass "bash-3.2 -n colony-lint.sh"
    else
        fail "bash-3.2 -n colony-lint.sh failed: $(cat /tmp/colony-lint-bash32-err.$$)"
    fi
    rm -f /tmp/colony-lint-bash32-err.$$
else
    skip "bash-3.2 not on PATH"
fi

# --- Test 3: awk -f parses the extracted allowlist ---
if awk -f "$AWK_FILE" </dev/null >/dev/null 2>/tmp/colony-lint-bash32-err.$$; then
    pass "awk -f colony-lint-flag-allowlist.awk </dev/null"
else
    fail "awk -f colony-lint-flag-allowlist.awk failed: $(cat /tmp/colony-lint-bash32-err.$$)"
fi
rm -f /tmp/colony-lint-bash32-err.$$

# --- Test 5: bash 3.2 parses #321 secret-set + secret-resolver scripts ---
# Per the issue refinement: tools/secret-set.sh and tools/test-secret-resolver.sh
# (added in #321 PR) MUST run on stock macOS /bin/bash (3.2). Keep both
# under the same parser smoke check that already covers colony-lint.sh.
SECRET_SCRIPTS="$SCRIPT_DIR/secret-set.sh $SCRIPT_DIR/test-secret-resolver.sh"
for s in $SECRET_SCRIPTS; do
    if [ ! -f "$s" ]; then
        skip "$(basename "$s") not found (yet)"
        continue
    fi
    if bash -n "$s" 2>/tmp/colony-lint-bash32-err.$$; then
        pass "bash -n $(basename "$s")"
    else
        fail "bash -n $(basename "$s") failed: $(cat /tmp/colony-lint-bash32-err.$$)"
    fi
    rm -f /tmp/colony-lint-bash32-err.$$
    if command -v bash-3.2 >/dev/null 2>&1; then
        if bash-3.2 -n "$s" 2>/tmp/colony-lint-bash32-err.$$; then
            pass "bash-3.2 -n $(basename "$s")"
        else
            fail "bash-3.2 -n $(basename "$s") failed: $(cat /tmp/colony-lint-bash32-err.$$)"
        fi
        rm -f /tmp/colony-lint-bash32-err.$$
    fi
done

# --- Test 5: destructive kill-tests skipped by default (#329) ---
# colony-lint.sh auto-discovers tools/test-*.sh and ran them all, including
# test-kill-{endpoint,federation}.sh which shell out to kill-federation.sh
# and (despite the #296 cwd-filter) kill the operator's live federation.
# We assert the source carries a case-statement that gates both scripts on
# AGENTIS_RUN_KILL_TESTS=1 with a [SKIP] emit by default. NOT spawning the
# loop here on purpose — that would re-introduce the very bug we're
# fixing.
test5_ok=1
if ! grep -q 'test-kill-endpoint.sh' "$LINT"; then
    test5_ok=0
fi
if ! grep -q 'test-kill-federation.sh' "$LINT"; then
    test5_ok=0
fi
if ! grep -q 'AGENTIS_RUN_KILL_TESTS' "$LINT"; then
    test5_ok=0
fi
if ! grep -q 'destructive .* AGENTIS_RUN_KILL_TESTS=1 to run' "$LINT"; then
    test5_ok=0
fi
if [ "$test5_ok" = "1" ]; then
    pass "kill-tests gated behind AGENTIS_RUN_KILL_TESTS (#329)"
else
    fail "kill-tests guard missing or malformed in colony-lint.sh"
fi

# --- Test 6: tools-test runner shape (#1750/#1869) ---
# Same source-assertion technique as test 5 (spawning the loop here would
# re-run every tools test, including the live-daemon ones). Four invariants:
#   a) each test is wall-clock bounded, with an operator override;
#   b) the failure branch prints the captured output instead of RE-RUNNING
#      the script — a re-run doubles a live-daemon test's daemons and shows
#      a transcript from a different execution than the verdict;
#   c) the three live-daemon tests are gated behind an explicit skip knob
#      (default: run);
#   d) the loop is bracketed by the daemon leak guard.
test6_ok=1
test6_why=""
if ! grep -q 'COLONY_LINT_TEST_TIMEOUT_S' "$LINT"; then
    test6_ok=0; test6_why="$test6_why no-timeout-knob"
fi
# shellcheck disable=SC2016 # matching the literal source text, not expanding
if ! grep -q 'timeout "\$TEST_TIMEOUT_S" bash "\$t"' "$LINT"; then
    test6_ok=0; test6_why="$test6_why no-timeout-wrapper"
fi
# shellcheck disable=SC2016 # matching the literal source text, not expanding
if grep -q 'bash "\$t" 2>&1 | tail' "$LINT"; then
    test6_ok=0; test6_why="$test6_why display-only-rerun-back"
fi
if ! grep -q 'COLONY_LINT_SKIP_LIVE_DAEMON' "$LINT"; then
    test6_ok=0; test6_why="$test6_why no-live-daemon-env"
fi
if ! grep -q -- '--no-live-daemon' "$LINT"; then
    test6_ok=0; test6_why="$test6_why no-live-daemon-flag"
fi
if ! grep -q 'test-ag-decompose-burnin.sh|test-dashboard-freshness-liveness.sh|test-single-block-byte-identity.sh' "$LINT"; then
    test6_ok=0; test6_why="$test6_why no-live-daemon-case"
fi
if ! grep -q 'no agentis daemon leaked by tools tests' "$LINT"; then
    test6_ok=0; test6_why="$test6_why no-leak-guard"
fi
if ! grep -q 'daemon_pids_before' "$LINT" || ! grep -q 'daemon_pids_after' "$LINT"; then
    test6_ok=0; test6_why="$test6_why no-leak-snapshot"
fi
if [ "$test6_ok" = "1" ]; then
    pass "tools-test runner: bounded, single-run, live-daemon skip knob + leak guard (#1750/#1869)"
else
    fail "tools-test runner shape drifted in colony-lint.sh:$test6_why"
fi

# --- Test 4: missing tomllib/tomli triggers [SKIP], no traceback (#272) ---
# Skip when this script is invoked from inside colony-lint.sh — running
# the lint again from here would recurse (lint discovers this test, runs
# it, test 4 runs lint again, ...). The lint exports
# AGENTIS_COLONY_LINT_NESTED=1 around each test-*.sh invocation so we
# can detect that and short-circuit. Local direct runs see =0 and
# exercise the full check.
if [ "${AGENTIS_COLONY_LINT_NESTED:-0}" = "1" ]; then
    skip "tomllib/tomli missing -> [SKIP] (nested colony-lint run)"
else
    stub_dir=$(mktemp -d)
    cat > "$stub_dir/python3" <<'PYSTUB'
#!/usr/bin/env bash
case "${2:-}" in *"import tomllib"*|*"import tomli"*) exit 1 ;; esac
exec /usr/bin/python3 "$@"
PYSTUB
    chmod +x "$stub_dir/python3"
    stub_out=$(PATH="$stub_dir:$PATH" "$LINT" 2>&1 || true)
    rm -rf "$stub_dir"
    if printf '%s\n' "$stub_out" | grep -q 'config check (no TOML parser' \
        && ! printf '%s\n' "$stub_out" | grep -q 'Traceback'; then
        pass "tomllib/tomli missing -> [SKIP] config check, no traceback"
    else
        fail "tomllib/tomli missing did not degrade to [SKIP] cleanly"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
