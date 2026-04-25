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
