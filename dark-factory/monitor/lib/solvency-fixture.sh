#!/bin/sh
# solvency-fixture.sh — anvil boot / deploy / break helpers for the Monitor
# colony's self-test + demo (#1889). SOURCED, not executed.
#
# It stands up a throwaway, network-free proving ground for the monitor's
# invariant-watcher verdict logic: boot a LOCAL anvil, deploy the minimal
# `SolvencyFixture` (solvency-fixture.sol / .bin — supply/assets getters + a
# `mintUnbacked` lever), mine a quiet baseline, then break
# `totalSupply() <= totalAssets()` on demand. Both backtest-self-test.sh (the
# reproducible scorecard artifact) and demo-monitor.sh (the live two-layer
# daemon demo) source this so the anvil boilerplate lives in ONE place.
#
# READ-ONLY of nothing external: every chain access is against a LOCAL anvil the
# caller itself booted; the fixture is self-test scaffolding, never a real
# target and never a vulnerability PoC.
#
# Contract before calling fixture_deploy: the sourcing script must set
#   SOLVENCY_FIXTURE_BIN   absolute path to solvency-fixture.bin (this dir).
# The dev signing key is anvil's WELL-KNOWN default account #0 private key — the
# standard foundry local-test key, NOT a secret (it signs only on the caller's
# ephemeral local chain).
#
# POSIX sh / dash-safe: no bashisms, no arrays, no `\xHH` printf escapes.
#
# Functions (each returns 0 on success, non-zero on failure):
#   fixture_pick_port                       -> echoes a free TCP port on 127.0.0.1
#   fixture_start_anvil <port> <logfile>    -> boots anvil, sets FIXTURE_ANVIL_PID
#   fixture_deploy <rpc> <supply> <assets>  -> echoes the deployed 0x address
#   fixture_mine <rpc> <n>                  -> mines <n> blocks (anvil_mine)
#   fixture_break <rpc> <addr> <amount>     -> mintUnbacked(<amount>): supply > assets
#   fixture_block <rpc>                      -> echoes the current block number
#   fixture_read <rpc> <addr> <sig>         -> echoes a uint view as a decimal
#   fixture_stop <pid>                      -> kills the anvil pid + brief wait

# anvil's default account #0 private key (the standard foundry local-test key;
# public, not a secret — it only ever signs on the caller's local anvil chain).
SOLVENCY_FIXTURE_DEV_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# The anvil pid last booted by fixture_start_anvil (a global, not echoed, to
# avoid a background job racing a command substitution).
FIXTURE_ANVIL_PID=""

# Echo a free TCP port: bind :0 on the loopback, read the kernel-assigned port,
# release it. Avoids a hardcoded port colliding with a leaked/parallel anvil.
fixture_pick_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# Boot a background anvil on <port>, logging to <logfile>, and poll until it
# answers `cast block-number`. Sets FIXTURE_ANVIL_PID to the anvil pid (a single
# process — no watchdog/inner fork like an agentis daemon — so a plain kill of
# this pid reaps it; NOT launched via setsid, whose immediate exit would orphan
# the real anvil). Returns 1 (and reaps) if anvil never comes up.
fixture_start_anvil() {
    _port="$1"; _log="$2"
    anvil --port "$_port" --silent >"$_log" 2>&1 &
    FIXTURE_ANVIL_PID=$!
    _rpc="http://127.0.0.1:$_port"
    _i=0
    while [ "$_i" -lt 50 ]; do
        if cast block-number --rpc-url "$_rpc" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
        _i=$((_i + 1))
    done
    kill "$FIXTURE_ANVIL_PID" 2>/dev/null || true
    FIXTURE_ANVIL_PID=""
    return 1
}

# Deploy SolvencyFixture(supply, assets) via `cast send --create` using anvil's
# default dev account. Echoes the deployed 0x address on success; empty + non-zero
# on failure. The creation bytecode is read from SOLVENCY_FIXTURE_BIN (committed
# hex, so no compiler is needed at run time).
fixture_deploy() {
    _rpc="$1"; _supply="$2"; _assets="$3"
    [ -n "${SOLVENCY_FIXTURE_BIN:-}" ] || return 1
    [ -f "$SOLVENCY_FIXTURE_BIN" ] || return 1
    _bin="$(cat "$SOLVENCY_FIXTURE_BIN")"
    _json="$(cast send --rpc-url "$_rpc" --private-key "$SOLVENCY_FIXTURE_DEV_KEY" --json \
        --create "0x$_bin" "constructor(uint256,uint256)" "$_supply" "$_assets" 2>/dev/null)" || return 1
    printf '%s' "$_json" | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("contractAddress", ""))
except Exception:
    pass'
}

# Mine <n> blocks on the local anvil (deterministic, instant).
fixture_mine() {
    _rpc="$1"; _n="$2"
    cast rpc --rpc-url "$_rpc" anvil_mine "$_n" >/dev/null 2>&1
}

# Break the solvency invariant on demand: mintUnbacked(<amount>) raises
# totalSupply() above totalAssets() so `totalSupply() <= totalAssets()` flips to
# `violated`. Self-test lever only.
fixture_break() {
    _rpc="$1"; _addr="$2"; _amount="$3"
    cast send --rpc-url "$_rpc" --private-key "$SOLVENCY_FIXTURE_DEV_KEY" \
        "$_addr" "mintUnbacked(uint256)" "$_amount" >/dev/null 2>&1
}

# Echo the current block number of the local anvil.
fixture_block() {
    _rpc="$1"
    cast block-number --rpc-url "$_rpc" 2>/dev/null
}

# Echo a uint view (e.g. "totalSupply()") as a decimal integer.
fixture_read() {
    _rpc="$1"; _addr="$2"; _sig="$3"
    cast call --rpc-url "$_rpc" "$_addr" "$_sig" 2>/dev/null | cast --to-dec 2>/dev/null
}

# Kill the anvil pid and wait briefly for it to exit (best-effort; a teardown
# must never turn a passing run red).
fixture_stop() {
    _pid="${1:-}"
    case "$_pid" in
        ''|*[!0-9]*) return 0 ;;
    esac
    kill "$_pid" 2>/dev/null || true
    _i=0
    while [ "$_i" -lt 25 ]; do
        kill -0 "$_pid" 2>/dev/null || return 0
        sleep 0.2
        _i=$((_i + 1))
    done
    kill -9 "$_pid" 2>/dev/null || true
    return 0
}
