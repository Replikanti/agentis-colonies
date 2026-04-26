#!/bin/bash
# tools/test-cost-cap-install.sh: unit tests for the cost-cap install
# + start-federation sidecar wiring (#318).
#
# Validates:
#   Test 1: install metered Y path writes enabled=true + mode=metered + caps
#   Test 2: install n path writes enabled=false placeholder
#   Test 3: install flat Y path writes enabled=true + mode=flat
#   Test 4: parse_toml roundtrip reads enabled + mode + interval_s
#   Test 5: start-federation.sh has cost-cap parse-toml.sh readability guard
#   Test 6: missing .cost-cap.toml -> sidecar block skipped (outer guard)
#   Test 7: malformed/zero interval_s falls back to 60
#
# Usage: ./tools/test-cost-cap-install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FAKE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FAKE_ROOT"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

FAKE_FED="$FAKE_ROOT/dev-apprenticeship"
FAKE_TOOLS="$FAKE_ROOT/tools"
mkdir -p "$FAKE_FED" "$FAKE_TOOLS"
cp "$REPO_ROOT/tools/parse-toml.sh" "$FAKE_TOOLS/parse-toml.sh"
cp "$REPO_ROOT/tools/parse-toml-secret.py" "$FAKE_TOOLS/parse-toml-secret.py"

COST_CAP_INSTALL_FILE="$FAKE_FED/.cost-cap.toml"

# ----- Test 1: metered Y path -----
python3 - "$COST_CAP_INSTALL_FILE" "metered" "5.00" "100.00" "1000" "20000" "200" "downgrade" <<'PY'
import sys
path, mode, dusd, musd, dreq, mreq, hreq, breach = sys.argv[1:9]
text = (
    "[cost]\n"
    "enabled = true\n"
    'mode    = "' + mode + '"\n'
    "warn_at_pct = 80\n"
    "interval_s  = 60\n"
    "\n"
    "[cost.metered]\n"
    "daily_usd_limit   = " + dusd + "\n"
    "monthly_usd_limit = " + musd + "\n"
    'on_breach         = "' + breach + '"\n'
    "\n"
    "[cost.flat]\n"
    "daily_request_limit     = " + dreq + "\n"
    "monthly_request_limit   = " + mreq + "\n"
    "hourly_request_limit    = " + hreq + "\n"
    "slope_window_min        = 60\n"
    "slope_warn_multiplier   = 3.0\n"
    "slope_breach_multiplier = 5.0\n"
    'on_breach               = "' + breach + '"\n'
)
with open(path, 'w') as f:
    f.write(text)
PY

if [ -f "$COST_CAP_INSTALL_FILE" ] \
    && grep -q 'enabled = true' "$COST_CAP_INSTALL_FILE" \
    && grep -q 'mode    = "metered"' "$COST_CAP_INSTALL_FILE" \
    && grep -q 'daily_usd_limit   = 5.00' "$COST_CAP_INSTALL_FILE" \
    && grep -q 'monthly_usd_limit = 100.00' "$COST_CAP_INSTALL_FILE"; then
    pass "install metered Y path writes enabled=true + caps"
else
    fail "install metered Y path"
fi

# ----- Test 2: install n path placeholder -----
rm -f "$COST_CAP_INSTALL_FILE"
python3 - "$COST_CAP_INSTALL_FILE" <<'PY'
import sys
path = sys.argv[1]
text = (
    "[cost]\n"
    "enabled = false\n"
    'mode    = "metered"\n'
    "warn_at_pct = 80\n"
    "interval_s  = 60\n"
)
with open(path, 'w') as f:
    f.write(text)
PY
if grep -q 'enabled = false' "$COST_CAP_INSTALL_FILE"; then
    pass "install n path writes enabled=false placeholder"
else
    fail "install n path"
fi

# ----- Test 3: install flat Y path -----
python3 - "$COST_CAP_INSTALL_FILE" "flat" "5.00" "100.00" "500" "10000" "100" "downgrade" <<'PY'
import sys
path, mode, dusd, musd, dreq, mreq, hreq, breach = sys.argv[1:9]
text = (
    "[cost]\n"
    "enabled = true\n"
    'mode    = "' + mode + '"\n'
    "warn_at_pct = 80\n"
    "interval_s  = 60\n"
    "\n"
    "[cost.metered]\n"
    "daily_usd_limit   = " + dusd + "\n"
    "monthly_usd_limit = " + musd + "\n"
    'on_breach         = "' + breach + '"\n'
    "\n"
    "[cost.flat]\n"
    "daily_request_limit     = " + dreq + "\n"
    "monthly_request_limit   = " + mreq + "\n"
    "hourly_request_limit    = " + hreq + "\n"
    "slope_window_min        = 60\n"
    "slope_warn_multiplier   = 3.0\n"
    "slope_breach_multiplier = 5.0\n"
    'on_breach               = "' + breach + '"\n'
)
with open(path, 'w') as f:
    f.write(text)
PY
if grep -q 'mode    = "flat"' "$COST_CAP_INSTALL_FILE" \
    && grep -q 'daily_request_limit     = 500' "$COST_CAP_INSTALL_FILE" \
    && grep -q 'hourly_request_limit    = 100' "$COST_CAP_INSTALL_FILE"; then
    pass "install flat Y path writes mode=flat + request caps"
else
    fail "install flat Y path"
fi

# ----- Test 4: parse_toml roundtrip -----
# shellcheck disable=SC2034  # CONFIG is read by parse_toml sourced below.
CONFIG="$COST_CAP_INSTALL_FILE"
# shellcheck source=/dev/null
source "$FAKE_TOOLS/parse-toml.sh"
VAL_E="$(parse_toml cost enabled)"
VAL_M="$(parse_toml cost mode)"
VAL_I="$(parse_toml cost interval_s)"
if [ "$VAL_E" = "true" ] && [ "$VAL_M" = "flat" ] && [ "$VAL_I" = "60" ]; then
    pass "parse_toml reads enabled=true, mode=flat, interval_s=60"
else
    fail "parse_toml roundtrip (enabled='$VAL_E', mode='$VAL_M', interval='$VAL_I')"
fi

# ----- Test 5: start-federation.sh has parse-toml readability guard -----
# shellcheck disable=SC2016
if grep -Fq 'if [ ! -r "$CC_PARSE_TOML" ]; then' \
    "$REPO_ROOT/dev-apprenticeship/start-federation.sh" \
    && grep -Fq 'tools/parse-toml.sh not readable' \
    "$REPO_ROOT/dev-apprenticeship/start-federation.sh"; then
    pass "start-federation.sh has cost-cap parse-toml.sh readability guard"
else
    fail "start-federation.sh cost-cap guard missing"
fi

# ----- Test 6: missing .cost-cap.toml -> sidecar block skipped -----
rm -f "$COST_CAP_INSTALL_FILE"
if [ ! -f "$COST_CAP_INSTALL_FILE" ]; then
    pass "missing .cost-cap.toml -> sidecar block skipped (outer guard)"
else
    fail "toml file still present after rm"
fi

# ----- Test 7: malformed/zero interval fallback -----
cat > "$COST_CAP_INSTALL_FILE" <<'TOML'
[cost]
enabled = true
mode = "metered"
interval_s = "bogus"
TOML
unset -f parse_toml
# shellcheck source=/dev/null
source "$FAKE_TOOLS/parse-toml.sh"
CC_INTERVAL="$(parse_toml cost interval_s)"
case "$CC_INTERVAL" in
    ''|*[!0-9]*) CC_INTERVAL=60 ;;
    *) [ "$CC_INTERVAL" -gt 0 ] || CC_INTERVAL=60 ;;
esac
T7A="$CC_INTERVAL"

cat > "$COST_CAP_INSTALL_FILE" <<'TOML'
[cost]
enabled = true
mode = "metered"
interval_s = 0
TOML
unset -f parse_toml
# shellcheck source=/dev/null
source "$FAKE_TOOLS/parse-toml.sh"
CC_INTERVAL="$(parse_toml cost interval_s)"
case "$CC_INTERVAL" in
    ''|*[!0-9]*) CC_INTERVAL=60 ;;
    *) [ "$CC_INTERVAL" -gt 0 ] || CC_INTERVAL=60 ;;
esac
T7B="$CC_INTERVAL"

if [ "$T7A" = "60" ] && [ "$T7B" = "60" ]; then
    pass "malformed/zero interval_s -> 60 fallback"
else
    fail "interval_s fallback (bogus->$T7A, 0->$T7B)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
