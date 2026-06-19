# 6-tribe LLM evolutionary-search run

**Run:** `20260619T142507Z` · **Symbol:** BTCUSDT 1h · **Window:** 2026-03-01 → 2026-03-05 (~70 tradable ticks, lookback 50, hold 8) · **Backend:** `claude-p` (Claude Code print mode, flat-rate subscription) · **Tribes:** 6 (alpha..zeta), each a distinct setup hypothesis.

This is the first **end-to-end** run of the 6-tribe LLM evolutionary search on the flat-rate path — the goal being that the federation actually **uses the agentis substrate** (LLM strategists → deterministic settlement → fitness → M98 prompt evolution → M2 replicate), not just a demo.

## The path to running it (4 merged infra fixes)

The flat-rate replay was blocked by a stack of container/LLM-channel bugs, each fixed:

| PR | Fix |
|----|-----|
| #1160 | SELinux `:z` on the `/repo` + `/run-root` bind mounts (container boot, exit 126) |
| #1162 | mount `~/.claude.json` + route flat-cyborg via the `--extract-structural` wrapper (claude auth + reply) |
| #1164 | strategist JSON-only directive + `flat-cyborg-unwrap.py` (kill prose, undo TUI line-wrap) |
| #1165 | **`claude-p` backend** — the decisive fix |

The flat-cyborg `--extract-structural` **TUI screen-scrape** gave **0% parse success** in the daemon replay (every tick `unexpected character 'N'` / line-wrapped JSON), even at single-tribe concurrency, despite single isolated calls working. `claude -p` (print mode) is non-interactive → clean single-shot stdout JSON, **same flat-rate subscription**, ~10× faster (~12s vs ~120s). Mirrors #1152's code-gen resolution.

## Substrate ran end-to-end ✅

| Metric | Value |
|---|---|
| Decisions (ledger rows) | **269** |
| **Parse errors** | **0** (claude-p clean across all 269) |
| Action spread | 216 FLAT / 42 LONG / 11 SHORT (53 directional, ~20%) |
| Settled trades | 174 (138 FLAT / 26 LOSS / 10 WIN) |
| **M98 prompt evolution** | **fired — 3–5 generations per tribe** (strategy prompts rewritten from settled-trade outcomes; the `settled_trades` buffer resets to `[]` after each evolution, confirming it) |
| M2 replicate | did **not** fire — correct: no tribe cleared the replicate fitness threshold |

Per-tribe final fitness (bps-derived): −362, 0, −97, 0, **+40**, −183. One tribe ended marginally positive; the rest flat/negative.

## Honest trading outcome ❌ (no edge — as predicted)

Across the 36 settled **directional** trades: **10 WIN / 26 LOSS**, total **−1130 bps**, mean **−31.4 bps/trade** — negative expectancy; every tribe net-negative or flat. This matches the deterministic-backtest prior (the fade and momentum reference signals both lost on this window). The LLM strategists, evolving over a single 5-day window, found **no durable edge**.

## What this run demonstrates

- **The substrate works**: LLM strategists decide → the deterministic verifier settles real PnL → fitness updates → M98 evolves the prompts → replicate is correctly gated on fitness. The flat-rate channel (claude-p) is reliable (0 parse errors over 269 decisions).
- **The trading hypothesis does not** (yet): no positive expectancy on this window. The verifier again prevented self-deception — it reports the losses honestly.

## Caveats

Single in-sample 5-day window; no walk-forward / out-of-sample; 6 fixed setup hypotheses; evolution had only ~70 ticks to work with (3–5 generations is early). A real search needs many windows + out-of-sample validation before any edge claim. Raw `trade-ledger.jsonl` + logs are gitignored (reproducible via `run-replay.sh` with the documented params).
