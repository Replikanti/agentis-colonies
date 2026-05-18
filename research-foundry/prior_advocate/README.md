# Prior Advocate Colony

> Part of the [Claim Auditor](../) research-foundry federation.

The prior advocate colony reads the triggering claim row from memo
(problem_text / answer / novelty_claim — the same seed the four web
searchers consume) and runs an adversarial-reviewer LLM call that
argues the claim is already known: it constructs the strongest
possible case that the claim is a corollary or restatement of an
existing result and cites the closest theorem / lemma / identity it
can find. The structured Verdict is persisted to memo for the auditor
to fold into its synthesis ctx as an additional KNOWN_PRIOR signal
alongside the four web-search reports. The default is pass-through —
an empty or missing prior_advocate memo does not block the auditor
(Phase 4 PR-B #625).

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| prior_advocate | `agents/prior_advocate.ag` | when a claim is plausibly a re-derivation of a classical result vs genuinely novel | ~10 acted ticks |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```
