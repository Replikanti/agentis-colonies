#!/bin/bash
# tools/test-dashboard-sidecar-grace.sh: regression test for #274 — the
# auto-promote sidecar must not be marked DEGRADED for the entire first
# interval after a fresh restart, even though auto-promote.log inherits a
# stale mtime from the previous run.
#
# Two fixes interact (either silences the false-positive on its own; both
# combined make it impossible to reproduce):
#   1. start-federation.sh's sidecar loop now ticks before sleeping, so the
#      log mtime is fresh within ~1s of spawn (covered by
#      test-auto-promote-install.sh).
#   2. start-federation.sh writes
#      $FED_DIR/.agentis/logs/auto-promote.sidecar_started_at on spawn;
#      federation-dashboard-collector.py reads it and emits
#      sidecar.in_startup_grace=true while now - started_at < interval_s
#      + 120s; the template gates DEGRADED on !in_startup_grace.
#
# This file pins fix #2 — it drives the collector directly and asserts the
# emitted sidecar.in_startup_grace field for the two adjacent fixtures the
# template's logic actually depends on:
#   (a) fresh started_at (now), stale auto-promote.log mtime → grace=true
#   (b) old started_at  (>2× interval ago), stale log mtime → grace=false
#
# Usage: ./tools/test-dashboard-sidecar-grace.sh
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

# Synthetic federation layout mirroring what start-federation.sh produces.
build_fixture() {
    local fed_dir="$1"
    local started_at="$2"   # seconds since epoch, or empty to skip the file
    local log_mtime="$3"    # seconds since epoch for auto-promote.log
    local interval_s="$4"

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

    cat > "$fed_dir/stub-colony/agents/grace_agent.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG

    cat > "$fed_dir/.auto-promote-install.toml" <<TOML
[auto_promote]
enabled = true
interval_s = ${interval_s}
TOML

    # Stale auto-promote.log: inherited mtime far older than now.
    : > "$fed_dir/.agentis/logs/auto-promote.log"
    touch -d "@${log_mtime}" "$fed_dir/.agentis/logs/auto-promote.log"

    if [ -n "$started_at" ]; then
        echo "$started_at" > "$fed_dir/.agentis/logs/auto-promote.sidecar_started_at"
    fi
}

# Drive the collector and extract the sidecar block.
run_collector() {
    local fed_dir="$1"
    local epoch="$2"
    local exp_dir="$fed_dir/.agentis/experience"
    local log_dir="$fed_dir/.agentis/logs"
    local dash_dir="$fed_dir/.dashboard"
    # Empty daemon/agent maps so the collector exits the per-agent loop fast.
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

INTERVAL_S=1800   # 30 min, matches the production default in the install file.
NOW="$(date '+%s')"
GRACE_DEADLINE=$((INTERVAL_S + 120))   # template gate: now - started_at < interval_s + 120

# ----- Fixture A: fresh started_at + stale log → in_startup_grace=true -----
FED_A="$TMPDIR_TEST/fed_a"
# started_at = now → 0s elapsed, well under interval_s + 120 (1920s).
# log mtime = now - 7200s → 2h stale, the exact "silent NNNNm DEGRADED"
# false-positive #274 reported.
build_fixture "$FED_A" "$NOW" "$((NOW - 7200))" "$INTERVAL_S"
JSON_A="$(run_collector "$FED_A" "$NOW")"
GRACE_A="$(printf '%s' "$JSON_A" | python3 -c '
import json, sys
try:
    blob = json.load(sys.stdin)
    print(json.dumps(blob.get("sidecar", {}).get("in_startup_grace")))
except Exception as e:
    print("ERR:" + str(e))
')"
STARTED_AT_A="$(printf '%s' "$JSON_A" | python3 -c '
import json, sys
try:
    blob = json.load(sys.stdin)
    print(json.dumps(blob.get("sidecar", {}).get("started_at_ts")))
except Exception as e:
    print("ERR:" + str(e))
')"
if [ "$GRACE_A" = "true" ]; then
    pass "A: fresh started_at + stale log → in_startup_grace=true (suppresses DEGRADED, #274)"
else
    fail "A: in_startup_grace expected true, got '$GRACE_A'" \
         "started_at_ts=$STARTED_AT_A elapsed=0s deadline=${GRACE_DEADLINE}s"
fi

# ----- Fixture B: old started_at + stale log → in_startup_grace=false -----
FED_B="$TMPDIR_TEST/fed_b"
# started_at = now - 2*(interval_s + 120) → well past the grace window.
# log mtime same staleness as A.
OLD_STARTED_AT=$((NOW - 2 * GRACE_DEADLINE))
build_fixture "$FED_B" "$OLD_STARTED_AT" "$((NOW - 7200))" "$INTERVAL_S"
JSON_B="$(run_collector "$FED_B" "$NOW")"
GRACE_B="$(printf '%s' "$JSON_B" | python3 -c '
import json, sys
try:
    blob = json.load(sys.stdin)
    print(json.dumps(blob.get("sidecar", {}).get("in_startup_grace")))
except Exception as e:
    print("ERR:" + str(e))
')"
STARTED_AT_B="$(printf '%s' "$JSON_B" | python3 -c '
import json, sys
try:
    blob = json.load(sys.stdin)
    print(json.dumps(blob.get("sidecar", {}).get("started_at_ts")))
except Exception as e:
    print("ERR:" + str(e))
')"
if [ "$GRACE_B" = "false" ]; then
    pass "B: old started_at + stale log → in_startup_grace=false (DEGRADED still triggers, #274)"
else
    fail "B: in_startup_grace expected false, got '$GRACE_B'" \
         "started_at_ts=$STARTED_AT_B elapsed=$((NOW - OLD_STARTED_AT))s deadline=${GRACE_DEADLINE}s"
fi

# ----- Fixture C: missing started_at file → grace stays false (back-compat) -----
# Federations that ran the pre-#274 sidecar produce no started_at file. The
# collector must default in_startup_grace=false so the existing DEGRADED
# logic still works for them.
FED_C="$TMPDIR_TEST/fed_c"
build_fixture "$FED_C" "" "$((NOW - 7200))" "$INTERVAL_S"
JSON_C="$(run_collector "$FED_C" "$NOW")"
GRACE_C="$(printf '%s' "$JSON_C" | python3 -c '
import json, sys
try:
    blob = json.load(sys.stdin)
    print(json.dumps(blob.get("sidecar", {}).get("in_startup_grace")))
except Exception as e:
    print("ERR:" + str(e))
')"
STARTED_AT_C="$(printf '%s' "$JSON_C" | python3 -c '
import json, sys
try:
    blob = json.load(sys.stdin)
    print(json.dumps(blob.get("sidecar", {}).get("started_at_ts")))
except Exception as e:
    print("ERR:" + str(e))
')"
if [ "$GRACE_C" = "false" ] && [ "$STARTED_AT_C" = "null" ]; then
    pass "C: missing started_at file → in_startup_grace=false, started_at_ts=null (pre-#274 back-compat)"
else
    fail "C: missing started_at file expected grace=false + started_at=null" \
         "got grace=$GRACE_C started_at=$STARTED_AT_C"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
