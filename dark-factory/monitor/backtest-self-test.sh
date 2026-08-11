#!/bin/sh
# backtest-self-test.sh — the one-command, no-external-RPC reproducible artifact
# behind the Monitor colony's scorecard self-test row (#1889).
#
# It manufactures the whole proof locally: boot a throwaway anvil, deploy the
# minimal SolvencyFixture with supply == assets (the solvency invariant
# `totalSupply() <= totalAssets()` HOLDS), mine a quiet baseline, then
# `mintUnbacked()` to BREAK the invariant, and finally point the EXISTING,
# UNMODIFIED monitor/backtest.sh at the local anvil to replay the invariant-
# watcher verdict logic tick-by-tick. anvil keeps full historical state for its
# own chain, so backtest.sh's archive-probe + `cast call --block <N>` replay run
# unchanged against it — no public archive RPC, no forge, no LLM.
#
# The run PASSES when backtest.sh pages before the incident block (a true
# positive with a positive lead time) AND the quiet pre-incident window is clean
# (zero false pages) — exactly the scorecard's PASS criterion, reproduced end to
# end from the shipped verdict logic. Its stdout is copied to
# <workdir>/self-test-report.txt for an operator to inspect.
#
# READ-ONLY / self-contained: the only chain is a local anvil this script boots
# and tears down; the fixture is self-test scaffolding, never a real target.
#
# POSIX sh / dash-safe. Exit codes: 0 PASS; 1 the replay did not PASS; 3 a
# required tool (anvil / cast / python3) is missing; 4 anvil / deploy failure.
set -eu

# --- resolve paths -------------------------------------------------------------
SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
MONITOR_DIR="$(dirname "$SCRIPT_PATH")"
LIB="$MONITOR_DIR/lib/solvency-fixture.sh"
BACKTEST="$MONITOR_DIR/backtest.sh"
SOLVENCY_FIXTURE_BIN="$MONITOR_DIR/lib/solvency-fixture.bin"
export SOLVENCY_FIXTURE_BIN

err() { echo "backtest-self-test.sh: $1" >&2; }

[ -f "$LIB" ] || { err "fixture lib not found: $LIB"; exit 4; }
[ -f "$BACKTEST" ] || { err "backtest.sh not found: $BACKTEST"; exit 4; }
[ -f "$SOLVENCY_FIXTURE_BIN" ] || { err "fixture bytecode not found: $SOLVENCY_FIXTURE_BIN"; exit 4; }

# --- dependency gate (mirror backtest.sh's exit 3 convention) -------------------
for dep in anvil cast python3; do
    command -v "$dep" >/dev/null 2>&1 || { err "$dep required (self-test boots a local anvil and replays via cast)"; exit 3; }
done

# shellcheck source=/dev/null
. "$LIB"

# --- ephemeral workspace + teardown --------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/monitor-self-test.XXXXXX")"
REPORT="$WORK/self-test-report.txt"
ANVIL_LOG="$WORK/anvil.log"
# Reap anvil (fixture_stop) and the workdir on ANY exit, so no local chain and no
# temp files survive the run.
# shellcheck disable=SC2329  # invoked indirectly via the trap below
cleanup() {
    fixture_stop "${FIXTURE_ANVIL_PID:-}"
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- boot a local anvil on a free port -----------------------------------------
PORT="$(fixture_pick_port)"
RPC="http://127.0.0.1:$PORT"
echo "backtest-self-test.sh: booting local anvil on $RPC ..."
fixture_start_anvil "$PORT" "$ANVIL_LOG" || { err "anvil failed to come up (see $ANVIL_LOG)"; exit 4; }

# --- deploy the fixture: supply == assets, the invariant HOLDS -----------------
ADDR="$(fixture_deploy "$RPC" 1000 1000)"
case "$ADDR" in
    0x*) ;;
    *) err "fixture deploy failed (no contract address)"; exit 4 ;;
esac
echo "backtest-self-test.sh: deployed SolvencyFixture at $ADDR (totalSupply=$(fixture_read "$RPC" "$ADDR" 'totalSupply()') totalAssets=$(fixture_read "$RPC" "$ADDR" 'totalAssets()'))"

# --- mine a quiet baseline (invariant holds throughout) ------------------------
# Tall enough that the replay's quiet window [incident-14, incident-4) does not
# underflow block 0 with the windows below (pre 10 + lead 2 + quiet-lead 2).
fixture_mine "$RPC" 20

# --- break the invariant: mintUnbacked pushes supply above assets --------------
fixture_break "$RPC" "$ADDR" 500
BREAK_BLOCK="$(fixture_block "$RPC")"
# Anchor the "incident" one block AFTER the break so the page on the break block
# earns a positive (+1) lead time — the credibility claim (page BEFORE the anchor).
INCIDENT=$((BREAK_BLOCK + 1))
# A couple of post-incident blocks so the page window [incident-2, incident+2]
# has state to read.
fixture_mine "$RPC" 3
echo "backtest-self-test.sh: broke solvency at block $BREAK_BLOCK (totalSupply=$(fixture_read "$RPC" "$ADDR" 'totalSupply()') > totalAssets=$(fixture_read "$RPC" "$ADDR" 'totalAssets()')); incident anchor = block $INCIDENT"

# --- replay the UNMODIFIED backtest.sh against the local anvil ------------------
echo "backtest-self-test.sh: replaying the invariant-watcher verdict logic via the unmodified backtest.sh ..."
echo
rc=0
sh "$BACKTEST" \
    --rpc-url "$RPC" \
    --target "$ADDR" \
    --incident-block "$INCIDENT" \
    --lhs-sig 'totalSupply()' \
    --rhs-sig 'totalAssets()' \
    --rel le \
    --pre-window 10 \
    --lead-window 2 \
    --quiet-lead 2 \
    --post-window 2 \
    --out "$WORK/replay.tsv" >"$REPORT" 2>&1 || rc=$?
cat "$REPORT"

echo
if [ "$rc" -eq 0 ] && grep -Eq '^result[[:space:]]*:[[:space:]]*PASS' "$REPORT"; then
    echo "backtest-self-test.sh: result: PASS — the monitor paged before the incident with a clean quiet window (reproduced from the shipped verdict logic, no archive RPC). Report: $REPORT"
    exit 0
fi
err "the replay did NOT PASS (backtest.sh exit $rc) — see the report above"
exit 1
