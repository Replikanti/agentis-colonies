# Tribe Delta — Price Action

> Part of the [Trading Binance](../) federation.

Tribe Delta specialises in the **price action** trading setup. The
strategist agent reads OHLCV candle context, classifies the last 5-10
candles by shape (engulfing, pin bar, doji, momentum), and emits LONG /
SHORT / FLAT decisions on bullish engulfings at recent lows and bearish
engulfings at recent highs (FLAT on indecision). The deterministic
verifier (`tools/verify-trade.sh`) settles each decision HOLD_PERIOD
candles forward and emits a PnL verdict in basis points.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| strategist | `agents/strategist.ag` | price-action signals (engulfings, pin bars, momentum) | ~ K verified WIN trades |

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
