# Tribe Alpha — Volume Profile

> Part of the [Trading Binance](../) federation.

Tribe Alpha specialises in the **volume-profile** trading setup. The
strategist agent reads OHLCV candle context, builds a rolling 20-candle
volume profile, identifies POC / VAH / VAL, and emits LONG / SHORT / FLAT
decisions. The deterministic verifier (`tools/verify-trade.sh`) settles
each decision HOLD_PERIOD candles forward and emits a PnL verdict in
basis points.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| strategist | `agents/strategist.ag` | volume-profile bounce / rejection setups (POC / VAH / VAL) | ~ K verified WIN trades |

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
