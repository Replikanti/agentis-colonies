# Tribe Beta — Fibonacci Retracement

> Part of the [Trading Binance](../) federation.

Tribe Beta specialises in the **fibonacci retracement** trading setup.
The strategist agent reads OHLCV candle context, detects the most recent
swing high / swing low over a 30-candle window, computes the 38.2 / 50 /
61.8 retracement levels, and emits LONG / SHORT / FLAT decisions on
bounces from the 61.8 level (FLAT in the 38.2-50 dead zone). The
deterministic verifier (`tools/verify-trade.sh`) settles each decision
HOLD_PERIOD candles forward and emits a PnL verdict in basis points.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| strategist | `agents/strategist.ag` | fibonacci-retracement bounces (38.2 / 50 / 61.8 levels) | ~ K verified WIN trades |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Launch via the federation-level replay orchestrator (recommended):
   ```bash
   bash ../tools/run-replay.sh
   ```

   Or start the colony directly (requires `VERIFIER_PATH`, `CANDLES_CSV`,
   `HOLD_PERIOD` env vars to be set so the strategist's settlement path
   can call the verifier):
   ```bash
   ./scripts/start-colony.sh
   ```
