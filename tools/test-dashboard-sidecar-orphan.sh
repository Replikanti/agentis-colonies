#!/bin/bash
# tools/test-dashboard-sidecar-orphan.sh: covers #378 — the dashboard must
# distinguish "sidecar dead" (install file gone, no recent ticks) from
# "sidecar orphaned" (install file gone, recent ticks prove the loop is
# still alive). Bare `not-installed` mislabels the latter.
#
# The collector emits two new shapes for orphan detection:
#   * data.sidecars[i].status === 'orphan' (new enum value)
#   * data.sidecars[i].running_orphan === true (new boolean field)
# Both gated on `last_tick_ts` being fresher than ORPHAN_INFER_S (= 7200s).
#
# Five fixtures, each driving the collector directly via run_collector
# and asserting (status, running_orphan) for the relevant sidecar:
#   A: auto-promote orphan      → ('orphan',        true)
#   B: cost-cap orphan          → ('orphan',        true)  in sidecars[1]
#   C: auto-promote stale orphan→ ('not-installed', false) — pins 7200s
#   D: installed + ticking      → ('healthy',       false)
#   E: installed but never-ticked → ('silent',      false)
#
# Usage: ./tools/test-dashboard-sidecar-orphan.sh
# Exit 0 on full pass.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COLLECTOR="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-collector.py"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if [ ! -r "$COLLECTOR" ]; then
    fail "0: federation-dashboard-collector.py not readable" "$COLLECTOR"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Synthetic federation layout. Each fixture parameterises whether the
# install file is present and what mtime the sidecar log carries — the
# two inputs the orphan branch in _sidecar_status() reads.
build_fixture() {
    local fed_dir="$1"
    local install_kind="$2"   # 'auto-promote' | 'cost-cap' | 'auto-promote-installed' | 'none'
    local log_kind="$3"       # 'auto-promote' | 'cost-cap' | 'both' | 'none'
    local log_mtime="$4"      # seconds since epoch (only used when log_kind!=none)
    local interval_s="$5"     # only consumed by 'auto-promote-installed'

    rm -rf "$fed_dir"
    mkdir -p "$fed_dir/.agentis/logs" \
             "$fed_dir/.agentis/experience" \
             "$fed_dir/.agentis/daemon" \
             "$fed_dir/.dashboard" \
             "$fed_dir/stub-colony/agents" \
             "$fed_dir/stub-colony/config"

    cat > "$fed_dir/stub-colony/config/colony.toml" <<TOML
[colony]
name = "stub-colony"
TOML

    cat > "$fed_dir/stub-colony/agents/orphan_agent.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG

    case "$install_kind" in
        auto-promote-installed)
            cat > "$fed_dir/.auto-promote-install.toml" <<TOML
[auto_promote]
enabled = true
interval_s = ${interval_s}
TOML
            ;;
        none|auto-promote|cost-cap)
            # No install file written — the orphan path requires the file
            # to be missing.
            :
            ;;
    esac

    if [ "$log_kind" = "auto-promote" ] || [ "$log_kind" = "both" ]; then
        : > "$fed_dir/.agentis/logs/auto-promote.log"
        touch -d "@${log_mtime}" "$fed_dir/.agentis/logs/auto-promote.log"
    fi
    if [ "$log_kind" = "cost-cap" ] || [ "$log_kind" = "both" ]; then
        : > "$fed_dir/.agentis/logs/cost-cap.log"
        touch -d "@${log_mtime}" "$fed_dir/.agentis/logs/cost-cap.log"
    fi
}

# Drive the collector and return the JSON blob for the test to grep.
run_collector() {
    local fed_dir="$1"
    local epoch="$2"
    local exp_dir="$fed_dir/.agentis/experience"
    local log_dir="$fed_dir/.agentis/logs"
    local dash_dir="$fed_dir/.dashboard"
    python3 "$COLLECTOR" \
        '[]' \
        '[]' \
        "$fed_dir" \
        "$epoch" \
        "$exp_dir" \
        "$log_dir" \
        "$dash_dir" \
        '[]' \
        '' \
        2>/dev/null
}

# Extract data.sidecars[i].<field> from the collector blob without leaking
# JSON parsing into bash. Mirror of test-dashboard-sidecar-grace.sh's
# inline python3 calls.
extract_sidecar_field() {
    local json="$1"
    local idx="$2"
    local field="$3"
    printf '%s' "$json" | python3 -c "
import json, sys
try:
    blob = json.load(sys.stdin)
    sidecars = blob.get('sidecars') or []
    if len(sidecars) > $idx:
        print(json.dumps(sidecars[$idx].get('$field')))
    else:
        print('null')
except Exception as e:
    print('ERR:' + str(e))
"
}

INTERVAL_S=1800   # production default; matches install.sh §7 + the grace test.
NOW="$(date '+%s')"
ORPHAN_INFER_S=$((4 * INTERVAL_S))   # 7200s — the collector's hoisted threshold.

# ----- Fixture A: auto-promote orphan (install gone, recent log) -----
FED_A="$TMPDIR_TEST/fed_a"
# log mtime 600s ago — well inside ORPHAN_INFER_S (= 7200s).
build_fixture "$FED_A" "none" "auto-promote" "$((NOW - 600))" "$INTERVAL_S"
JSON_A="$(run_collector "$FED_A" "$NOW")"
A_STATUS="$(extract_sidecar_field "$JSON_A" 0 status)"
A_ORPHAN="$(extract_sidecar_field "$JSON_A" 0 running_orphan)"
if [ "$A_STATUS" = '"orphan"' ] && [ "$A_ORPHAN" = "true" ]; then
    pass "A: auto-promote orphan → status='orphan', running_orphan=true (#378)"
else
    fail "A: expected ('orphan', true), got ($A_STATUS, $A_ORPHAN)"
fi

# ----- Fixture B: cost-cap orphan (install gone, recent log on cost-cap) -----
FED_B="$TMPDIR_TEST/fed_b"
build_fixture "$FED_B" "none" "cost-cap" "$((NOW - 600))" "$INTERVAL_S"
JSON_B="$(run_collector "$FED_B" "$NOW")"
B_STATUS="$(extract_sidecar_field "$JSON_B" 1 status)"
B_ORPHAN="$(extract_sidecar_field "$JSON_B" 1 running_orphan)"
if [ "$B_STATUS" = '"orphan"' ] && [ "$B_ORPHAN" = "true" ]; then
    pass "B: cost-cap orphan → sidecars[1].status='orphan', running_orphan=true (#378)"
else
    fail "B: expected ('orphan', true), got ($B_STATUS, $B_ORPHAN)"
fi

# ----- Fixture C: auto-promote stale orphan — pins ORPHAN_INFER_S threshold -----
FED_C="$TMPDIR_TEST/fed_c"
# log mtime 7300s ago — just past ORPHAN_INFER_S=7200, so the orphan branch
# must fall through to bare 'not-installed'. Pinning the threshold here
# turns any future tuning of ORPHAN_INFER_S into a test failure rather
# than silent semantic drift.
build_fixture "$FED_C" "none" "auto-promote" "$((NOW - (ORPHAN_INFER_S + 100)))" "$INTERVAL_S"
JSON_C="$(run_collector "$FED_C" "$NOW")"
C_STATUS="$(extract_sidecar_field "$JSON_C" 0 status)"
C_ORPHAN="$(extract_sidecar_field "$JSON_C" 0 running_orphan)"
if [ "$C_STATUS" = '"not-installed"' ] && [ "$C_ORPHAN" = "false" ]; then
    pass "C: stale orphan (log >7200s) → status='not-installed', running_orphan=false (pins 4×1800s)"
else
    fail "C: expected ('not-installed', false), got ($C_STATUS, $C_ORPHAN)"
fi

# ----- Fixture D: installed + ticking → status='healthy' -----
FED_D="$TMPDIR_TEST/fed_d"
build_fixture "$FED_D" "auto-promote-installed" "auto-promote" "$((NOW - 60))" "$INTERVAL_S"
echo "$NOW" > "$FED_D/.agentis/logs/auto-promote.sidecar_started_at"
JSON_D="$(run_collector "$FED_D" "$NOW")"
D_STATUS="$(extract_sidecar_field "$JSON_D" 0 status)"
D_ORPHAN="$(extract_sidecar_field "$JSON_D" 0 running_orphan)"
if [ "$D_STATUS" = '"healthy"' ] && [ "$D_ORPHAN" = "false" ]; then
    pass "D: installed + ticking → status='healthy', running_orphan=false"
else
    fail "D: expected ('healthy', false), got ($D_STATUS, $D_ORPHAN)"
fi

# ----- Fixture E: installed but never ticked → status='silent' -----
FED_E="$TMPDIR_TEST/fed_e"
build_fixture "$FED_E" "auto-promote-installed" "none" "0" "$INTERVAL_S"
JSON_E="$(run_collector "$FED_E" "$NOW")"
E_STATUS="$(extract_sidecar_field "$JSON_E" 0 status)"
E_ORPHAN="$(extract_sidecar_field "$JSON_E" 0 running_orphan)"
if [ "$E_STATUS" = '"silent"' ] && [ "$E_ORPHAN" = "false" ]; then
    pass "E: installed but never ticked → status='silent', running_orphan=false"
else
    fail "E: expected ('silent', false), got ($E_STATUS, $E_ORPHAN)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
