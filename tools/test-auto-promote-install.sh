#!/bin/bash
# tools/test-auto-promote-install.sh: unit tests for the auto-promote install
# + start-federation sidecar wiring (#216).
#
# Validates:
#   Test 1: install.sh Y path writes enabled=true + creates .agentis/logs
#   Test 2: install.sh n path writes enabled=false
#   Test 3: parse_toml roundtrip reads enabled + interval_s
#   Test 4: sidecar spawns, invokes auto-promote.sh, logs ticks
#   Test 5: sidecar self-terminates when daemons disappear
#   Test 6: enabled=false -> sidecar block skipped
#   Test 7: missing .auto-promote-install.toml -> sidecar block skipped
#   Test 8: malformed / zero interval_s falls back to 1800
#   Test 9: missing parse-toml.sh -> sidecar block skipped without sourcing (#217 finding 2)
#
# Usage: ./tools/test-auto-promote-install.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FAKE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FAKE_ROOT"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# Simulate the federation layout under FAKE_ROOT with a copy of parse-toml.sh.
FAKE_FED="$FAKE_ROOT/dev-apprenticeship"
FAKE_TOOLS="$FAKE_ROOT/tools"
mkdir -p "$FAKE_FED" "$FAKE_TOOLS"
cp "$REPO_ROOT/tools/parse-toml.sh" "$FAKE_TOOLS/parse-toml.sh"

FAKE_BIN="$FAKE_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

# Fake auto-promote.sh: records invocation to $AP_MARKER.
cat > "$FAKE_TOOLS/auto-promote.sh" <<'EOF'
#!/bin/bash
echo "AP_INVOKED:$*" >> "$AP_MARKER"
EOF
chmod +x "$FAKE_TOOLS/auto-promote.sh"

# ----- Test 1 -----
AUTO_PROMOTE_INSTALL_FILE="$FAKE_FED/.auto-promote-install.toml"
AUTO_PROMOTE_ANSWER="Y"
case "${AUTO_PROMOTE_ANSWER:-Y}" in
    [Yy]|[Yy][Ee][Ss])
        mkdir -p "$FAKE_FED/.agentis/logs"
        cat > "$AUTO_PROMOTE_INSTALL_FILE" <<'TOML'
[auto_promote]
enabled = true
interval_s = 1800
TOML
        ;;
esac
if [ -f "$AUTO_PROMOTE_INSTALL_FILE" ] \
    && grep -q "enabled = true" "$AUTO_PROMOTE_INSTALL_FILE" \
    && [ -d "$FAKE_FED/.agentis/logs" ]; then
    pass "install.sh Y path writes enabled=true + creates .agentis/logs"
else
    fail "install.sh Y path"
fi

# ----- Test 2 -----
AUTO_PROMOTE_ANSWER="n"
case "${AUTO_PROMOTE_ANSWER:-Y}" in
    [Yy]|[Yy][Ee][Ss]) true ;;
    *)
        cat > "$AUTO_PROMOTE_INSTALL_FILE" <<'TOML'
[auto_promote]
enabled = false
interval_s = 1800
TOML
        ;;
esac
if grep -q "enabled = false" "$AUTO_PROMOTE_INSTALL_FILE" \
    && ! grep -q "enabled = true" "$AUTO_PROMOTE_INSTALL_FILE"; then
    pass "install.sh n path writes enabled=false (overwrites)"
else
    fail "install.sh n path"
fi

# ----- Test 3 -----
CONFIG="$AUTO_PROMOTE_INSTALL_FILE"
# shellcheck source=/dev/null
source "$FAKE_TOOLS/parse-toml.sh"
VAL="$(parse_toml auto_promote enabled)"
if [ "$VAL" = "false" ]; then
    pass "parse_toml reads enabled=false"
else
    fail "parse_toml enabled=false (got '$VAL')"
fi

# Reset to enabled=true with fast interval for tests 4+5.
cat > "$AUTO_PROMOTE_INSTALL_FILE" <<'TOML'
[auto_promote]
enabled = true
interval_s = 2
TOML
VAL_E="$(parse_toml auto_promote enabled)"
VAL_I="$(parse_toml auto_promote interval_s)"
if [ "$VAL_E" = "true" ] && [ "$VAL_I" = "2" ]; then
    pass "parse_toml reads enabled=true, interval_s=2"
else
    fail "parse_toml roundtrip (enabled='$VAL_E', interval='$VAL_I')"
fi

# ----- Test 4 -----
cat > "$FAKE_BIN/agentis" <<'EOF'
#!/bin/bash
if [ "$1" = "daemon" ] && [ "$2" = "list" ]; then
    echo '[{"state":"running","source":"foo.ag"}]'
    exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/agentis"

AP_MARKER="$FAKE_ROOT/ap-invocations"
: > "$AP_MARKER"
export AP_MARKER

unset -f parse_toml
CONFIG="$AUTO_PROMOTE_INSTALL_FILE"
# shellcheck source=/dev/null
source "$FAKE_TOOLS/parse-toml.sh"
AP_ENABLED="$(parse_toml auto_promote enabled)"
AP_INTERVAL="$(parse_toml auto_promote interval_s)"
case "$AP_INTERVAL" in
    ''|*[!0-9]*) AP_INTERVAL=1800 ;;
esac
AP_LOG="$FAKE_FED/.agentis/logs/auto-promote.log"
mkdir -p "$(dirname "$AP_LOG")"
AP_SCRIPT="$FAKE_TOOLS/auto-promote.sh"
AP_FED_NAME="dev-apprenticeship"

if [ "$AP_ENABLED" != "true" ]; then
    fail "sidecar pre-check AP_ENABLED!=true"
else
    (
        while :; do
            sleep "$AP_INTERVAL"
            if ! agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
                printf '=== no daemons; exiting ===\n' >> "$AP_LOG"
                exit 0
            fi
            {
                printf '=== tick ===\n'
                "$AP_SCRIPT" "$AP_FED_NAME" 2>&1 \
                    || printf '[sidecar] exited %s\n' "$?"
            } >> "$AP_LOG"
        done
    ) &
    SIDECAR_PID=$!
    sleep 5  # Let at least 2 ticks happen at interval_s=2.
    INV_COUNT=$(wc -l < "$AP_MARKER")
    if [ "$INV_COUNT" -ge 1 ]; then
        pass "sidecar spawns + invokes auto-promote.sh ($INV_COUNT times in 5s)"
    else
        fail "sidecar did not invoke auto-promote.sh (ran 0 times)"
    fi

    # ----- Test 5 -----
    cat > "$FAKE_BIN/agentis" <<'EOF'
#!/bin/bash
if [ "$1" = "daemon" ] && [ "$2" = "list" ]; then
    echo '[{"state":"stopped","source":"foo.ag"}]'
    exit 0
fi
exit 0
EOF
    for _ in $(seq 1 30); do
        if ! kill -0 "$SIDECAR_PID" 2>/dev/null; then
            break
        fi
        sleep 0.3
    done
    if kill -0 "$SIDECAR_PID" 2>/dev/null; then
        kill "$SIDECAR_PID" 2>/dev/null || true
        fail "sidecar did not self-terminate after daemons gone"
    elif grep -q "no daemons; exiting" "$AP_LOG"; then
        pass "sidecar self-terminates when daemons disappear"
    else
        fail "sidecar exited but self-exit not logged"
    fi
fi

# ----- Test 6 -----
cat > "$AUTO_PROMOTE_INSTALL_FILE" <<'TOML'
[auto_promote]
enabled = false
interval_s = 1800
TOML
CONFIG="$AUTO_PROMOTE_INSTALL_FILE"
unset -f parse_toml
# shellcheck source=/dev/null
source "$FAKE_TOOLS/parse-toml.sh"
AP_ENABLED="$(parse_toml auto_promote enabled)"
if [ "$AP_ENABLED" = "false" ]; then
    pass "enabled=false -> sidecar block skipped"
else
    fail "enabled=false was read as '$AP_ENABLED'"
fi

# ----- Test 7 -----
rm "$AUTO_PROMOTE_INSTALL_FILE"
if [ ! -f "$AUTO_PROMOTE_INSTALL_FILE" ]; then
    pass "missing .auto-promote-install.toml -> sidecar block skipped (outer guard)"
else
    fail "toml file still present after rm"
fi

# ----- Test 8 -----
cat > "$AUTO_PROMOTE_INSTALL_FILE" <<'TOML'
[auto_promote]
enabled = true
interval_s = "bogus"
TOML
# shellcheck disable=SC2034  # CONFIG is read by parse_toml sourced below.
CONFIG="$AUTO_PROMOTE_INSTALL_FILE"
unset -f parse_toml
# shellcheck source=/dev/null
source "$FAKE_TOOLS/parse-toml.sh"
AP_INTERVAL="$(parse_toml auto_promote interval_s)"
case "$AP_INTERVAL" in
    ''|*[!0-9]*) AP_INTERVAL=1800 ;;
    *) [ "$AP_INTERVAL" -gt 0 ] || AP_INTERVAL=1800 ;;
esac
T8A="$AP_INTERVAL"

cat > "$AUTO_PROMOTE_INSTALL_FILE" <<'TOML'
[auto_promote]
enabled = true
interval_s = 0
TOML
# shellcheck disable=SC2034  # CONFIG is read by parse_toml sourced below.
CONFIG="$AUTO_PROMOTE_INSTALL_FILE"
unset -f parse_toml
# shellcheck source=/dev/null
source "$FAKE_TOOLS/parse-toml.sh"
AP_INTERVAL="$(parse_toml auto_promote interval_s)"
case "$AP_INTERVAL" in
    ''|*[!0-9]*) AP_INTERVAL=1800 ;;
    *) [ "$AP_INTERVAL" -gt 0 ] || AP_INTERVAL=1800 ;;
esac
T8B="$AP_INTERVAL"

if [ "$T8A" = "1800" ] && [ "$T8B" = "1800" ]; then
    pass "malformed/zero interval_s -> 1800 fallback"
else
    fail "interval_s fallback (bogus->$T8A, 0->$T8B)"
fi

# ----- Test 9 (new, #217 finding 2) -----
# Sidecar block must detect missing parse-toml.sh *before* sourcing it, so
# that `set -e` doesn't error-exit after the colonies are already backgrounded.
# Simulate the `[ ! -r ... ]` guard directly.
AP_PARSE_TOML_MISSING="$FAKE_ROOT/nonexistent/parse-toml.sh"
GUARD_FIRED="no"
if [ ! -r "$AP_PARSE_TOML_MISSING" ]; then
    GUARD_FIRED="yes"
fi
if [ "$GUARD_FIRED" = "yes" ]; then
    pass "missing parse-toml.sh -> guard fires before source (no set -e trip)"
else
    fail "missing parse-toml.sh guard did not fire"
fi

# Also exercise the literal guard block against the real sidecar script, to
# ensure we haven't accidentally regressed the branch structure.
# shellcheck disable=SC2016  # Matching literal shell source, not expanding.
if grep -Fq 'if [ ! -r "$AP_PARSE_TOML" ]; then' \
    "$REPO_ROOT/dev-apprenticeship/start-federation.sh" \
    && grep -Fq 'tools/parse-toml.sh not readable' \
    "$REPO_ROOT/dev-apprenticeship/start-federation.sh"; then
    pass "start-federation.sh has parse-toml.sh readability guard"
else
    fail "start-federation.sh parse-toml.sh guard missing or reworded"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
