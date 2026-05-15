# Tribe Epsilon — Mean Reversion

> Part of the [Trading Binance](../) federation.

Tribe Epsilon specialises in the **mean reversion** trading setup. The
strategist agent reads OHLCV candle context, estimates the 50-candle
median price and the standard deviation of close-to-close returns
(without using indicator builtins), and emits LONG / SHORT / FLAT
decisions when price stretches 2+ standard deviations from the median
(FLAT in the middle of the range). The deterministic verifier
(`tools/verify-trade.sh`) settles each decision HOLD_PERIOD candles
forward and emits a PnL verdict in basis points.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| strategist | `agents/strategist.ag` | mean-reversion stretches (price-vs-50-bar-median, 2-stddev band) | ~ K verified WIN trades |

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
