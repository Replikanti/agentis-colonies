# Tribe Zeta — Volume Divergence

> Part of the [Trading Binance](../) federation.

Tribe Zeta specialises in the **volume-divergence fade** trading setup. The
strategist agent reads OHLCV candle context, compares the current candle's
volume against a 20-bar volume moving average (volumeMA(20)), and fades
unconfirmed price extremes: SHORT an unconfirmed new local high made on weak
volume, LONG an unconfirmed new local low, FLAT when volume confirms the move
or the picture is ambiguous. The deterministic verifier
(`tools/verify-trade.sh`) settles each decision HOLD_PERIOD candles forward
and emits a PnL verdict in basis points.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| strategist | `agents/strategist.ag` | volume-divergence fades (unconfirmed extremes vs volumeMA(20)) | ~ K verified WIN trades |

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
