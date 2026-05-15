# Tribe Gamma — Market Structure

> Part of the [Trading Binance](../) federation.

Tribe Gamma specialises in the **market structure** trading setup. The
strategist agent reads OHLCV candle context, classifies higher-highs /
higher-lows / lower-highs / lower-lows, detects break-of-structure (BOS)
and change-of-character (CHoCH), and emits LONG / SHORT / FLAT decisions
on confirmed structural breaks with retest. The deterministic verifier
(`tools/verify-trade.sh`) settles each decision HOLD_PERIOD candles
forward and emits a PnL verdict in basis points.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| strategist | `agents/strategist.ag` | market-structure breaks (BOS / CHoCH with retest) | ~ K verified WIN trades |

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
