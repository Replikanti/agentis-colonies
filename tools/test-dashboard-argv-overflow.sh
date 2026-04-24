#!/bin/bash
# tools/test-dashboard-argv-overflow.sh: regression test for #293 — large
# dashboard payloads (history.json, collector JSON, remediation JSON,
# daemon-list JSON) must travel via temp files (`@<path>` argv prefix), not
# as inline argv strings, so that they do not hit Linux's MAX_ARG_STRLEN
# (128 KB per single argv string) once the federation has been running for
# several hours.
#
# Same class of failure as #279 (github-api.sh overran via inline argv) but
# in a different code path (federation-dashboard wrapper -> python3 helpers).
#
# Strategy:
#   1. Stage a synthetic history.json larger than MAX_ARG_STRLEN (~200 KB).
#      Each entry carries a unique sentinel so we can grep the rendered HTML
#      for it afterwards.
#   2. Run `DASHBOARD_REGEN_ONLY=1 federation-dashboard $FED_DIR` so the
#      wrapper substitutes that history into the page and exits without
#      backgrounding a server.
#   3. Assert exit 0 and that index.html actually contains the sentinel —
#      that is what proves the @-prefix temp-file plumbing reached the
#      renderer's `{{HISTORY}}` substitution.
#
# Usage: ./tools/test-dashboard-argv-overflow.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DASHBOARD_SH="$REPO_ROOT/federation-dashboard/bin/federation-dashboard"

PASS=0
FAIL=0
SKIP=0
TMPDIR_TEST="$(mktemp -d)"

cleanup() {
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1${2:+: $2}"; SKIP=$((SKIP + 1)); }

if [ ! -x "$DASHBOARD_SH" ]; then
    skip "0: federation-dashboard not on PATH" "$DASHBOARD_SH"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- Federation fixture ---
FED_DIR="$TMPDIR_TEST/fed"
mkdir -p "$FED_DIR/.dashboard" \
         "$FED_DIR/.agentis/logs" \
         "$FED_DIR/.agentis/daemon" \
         "$FED_DIR/.agentis/experience" \
         "$FED_DIR/stub-colony/agents" \
         "$FED_DIR/stub-colony/config"

cat > "$FED_DIR/stub-colony/config/colony.toml" <<'TOML'
[colony]
name = "stub-colony"
TOML

cat > "$FED_DIR/stub-colony/agents/argv_agent.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG

# --- Synthetic 200 KB+ history.json ---
# Each entry is ~250 bytes of well-formed history schema; ~1500 entries lands
# at >200 KB, comfortably past Linux's 128 KB MAX_ARG_STRLEN per-argv cap.
# The first entry carries a unique sentinel string the assertion grep relies
# on; without the #293 fix, building the argv would fail with E2BIG before
# the renderer ever opened the template.
#
# Timestamps are anchored to *now* so that federation-dashboard-history.py's
# 7-day pruning cutoff (epoch - 7*86400) does NOT drop the fixture before the
# renderer reads it. Anything older than 7 days would be silently truncated,
# masking the regression.
SENTINEL="argv_overflow_sentinel_unique_marker_293_a4b9c2"
HISTORY_FILE="$FED_DIR/.dashboard/history.json"
NOW_EPOCH="$(date '+%s')"
python3 - "$HISTORY_FILE" "$SENTINEL" "$NOW_EPOCH" <<'PY'
import json, sys
path, sentinel, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
entries = []
# Anchor entry — the assertion grep expects this string in index.html.
entries.append({
    't': now - 60,
    'experience': {'total': 0, sentinel: 0},
    'confidence': {'stub-colony': 0.5},
})
# Bulk filler — push past 200 KB. Spread timestamps across the last hour so
# nothing crosses the 7-day prune cutoff.
for i in range(1, 1500):
    entries.append({
        't': now - 3600 + i,
        'experience': {'total': i, 'colony_filler_padding_string_to_inflate_the_blob_repeated_for_size': i},
        'confidence': {'stub-colony': round(0.5 + (i % 20) * 0.001, 3)},
    })
data = json.dumps(entries)
assert len(data) > 200 * 1024, 'fixture too small: %d bytes' % len(data)
with open(path, 'w', encoding='utf-8') as f:
    f.write(data)
PY

# Sanity: confirm the fixture is actually large enough to have tripped the
# pre-fix argv path. If this fails, the test would silently no-op the
# regression.
HIST_BYTES="$(wc -c < "$HISTORY_FILE" | tr -d ' ')"
if [ "$HIST_BYTES" -lt 200000 ]; then
    fail "0: history.json fixture is only $HIST_BYTES bytes (need >200000)"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# --- Run the dashboard in regen-only mode ---
LOG_FILE="$TMPDIR_TEST/dashboard.log"
set +e
DASHBOARD_REGEN_ONLY=1 bash "$DASHBOARD_SH" "$FED_DIR" >"$LOG_FILE" 2>&1
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
    fail "1: regen-only run exited $RC" "log tail: $(tail -10 "$LOG_FILE" 2>/dev/null | tr '\n' ' ')"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi
pass "1: regen-only run exited 0 with $HIST_BYTES-byte history.json"

# --- Assert the sentinel landed in the rendered page ---
HTML_FILE="$FED_DIR/.dashboard/index.html"
if [ ! -s "$HTML_FILE" ]; then
    fail "2: index.html was not generated"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

if grep -q "$SENTINEL" "$HTML_FILE"; then
    pass "2: rendered HTML contains synthetic history sentinel ($SENTINEL)"
else
    fail "2: sentinel missing from index.html — @-prefix routing did not reach the renderer" "html size: $(wc -c < "$HTML_FILE")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
