# Skeptic Colony

> Part of the [Math Foundry](../) federation.

The skeptic colony listens for `math-foundry:notice_done` and runs a
strict prompt that defaults to dismissing the noticer's surprise
unless it cannot be matched to a classical result. The skeptic's
verdict label gates the formulator: when the verdict is `dismissed`,
the formulator skips the tick and no problem is forged. The default
is pass-through — an empty or missing skeptic memo does not block the
formulator (Phase 4 PR-A #625).

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| skeptic | `agents/skeptic.ag` | when a surprise resists classical matching vs trivially restates a known result | ~10 ACCEPT-ed problems |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```
