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

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
