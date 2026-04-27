# Tribes Bench

![Version: 0.1.0](https://img.shields.io/badge/version-0.1.0-blue) ![Status: Experimental](https://img.shields.io/badge/status-experimental-purple)

**Version:** `0.1.0` · [Changelog](./CHANGELOG.md) · **Requires:** agentis >= `1.4.1` · **Status:** Experimental

> A research scaffold that tests whether the agentis runtime's
> emergent-layer primitives (replication, scarcity, selection,
> reputation, market) produce qualitatively different behaviour than
> LangGraph-class multi-agent tools. Two seed tribes hunt
> command-injection bugs in a synthetic Rust target via a deterministic
> verifier — no human in the loop, no API budget, deterministic ground
> truth.

This federation was scaffolded via
[`tools/new-federation.sh`](../tools/new-federation.sh) and conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md). The
agent contract follows
[ADR-0001](../doc/adr/ADR-0001-confidence-tiers.md) end-to-end.

## Hypothesis

A federation that uses the agentis emergent-layer primitives produces
better findings-quality (true-positive rate, time-to-first-true-positive,
robustness to noise) than a LangGraph-class multi-agent harness on the
same target. Stage 0 wires the bench end-to-end without exercising any
of those primitives — it is a wiring test only. Stage 1 enables
replication + scarcity. Stage 2 adds selection + the cognitive market.

## Staircase

| Stage | Issue | Adds | What it proves |
|-------|-------|------|----------------|
| **0** | [#363](https://github.com/Replikanti/agentis-colonies/issues/363) | Two seed tribes, deterministic verifier, telemetry CSV | The harness runs end-to-end against a known-truth target. |
| **1** | [#364](https://github.com/Replikanti/agentis-colonies/issues/364) | Replication + cognitive-budget scarcity | Drift between tribes is observable, and CB scarcity affects who survives. |
| **2** | [#365](https://github.com/Replikanti/agentis-colonies/issues/365) | Selection + cognitive market + federated reputation | The emergent layer either improves or matches a fixed-pipeline baseline on the same target. |

## What Stage 0 proves vs. doesn't

**Stage 0 proves:**

- Both tribes' hunter agents tick at the configured interval against a
  hermetic per-run `.agentis/` root.
- The deterministic verifier classifies findings true / false on the
  three planted command-injection bugs (`ci-001`, `ci-002`, `ci-003`)
  in `targets/stage0/vulnerable.rs`.
- The telemetry analyser emits a per-minute per-tribe CSV with
  `agents_alive`, `cb_balance`, `findings_emitted`, `true_positives`,
  `false_positives`.
- `tools/colony-lint.sh` accepts the federation clean (structure,
  config, `.ag` syntax, tier-branch convention, exec-sh safety).

**Stage 0 does NOT prove:**

- No claim about which seed prompt is "better" — the prompts in
  `tribe-alpha/agents/hunter.ag` and `tribe-beta/agents/hunter.ag` are
  intentionally framed differently to expose drift in Stage 1.
- No replication, no agent death, no resource competition.
- No federated reputation. No cognitive market.
- No real-world target. The synthetic Rust file is ~50 LOC with three
  unambiguous bugs.

## Reproduction recipe

```bash
cd tribes-bench/
./install.sh                        # idempotent: copies colony.toml + seeds memo
bash tools/run-stage0.sh            # one-shot run with default 900s wall clock
```

The script creates `runs/<utc-timestamp>/`, initialises a hermetic
`.agentis/` inside it, exports `TARGET_DIR` / `BUGS_MANIFEST` /
`VERIFIER_PATH`, launches both tribes via `start-federation.sh`, sleeps
the wall-clock cap, and produces `runs/<utc-timestamp>/telemetry.csv`.

| Env var | Default | Effect |
|---------|---------|--------|
| `STAGE0_WALL_CLOCK_S` | `900` | Wall-clock cap in seconds. Lower for smoke tests. |

`install.sh` seeds `hunter:confidence = 0.7` (mid-`propose` per
[ADR-0001](../doc/adr/ADR-0001-confidence-tiers.md)) so the very first
tick lands on the propose branch. `run-stage0.sh` re-seeds inside its
hermetic `.agentis/` root for the same reason.

The LLM backend defaults to Claude CLI (subscription-backed). Override
by editing `[llm].backend` in each tribe's `colony.toml` after install.

## Telemetry CSV

`runs/<utc-timestamp>/telemetry.csv` columns:

| Column | Meaning |
|--------|---------|
| `minute` | Unix-minute bucket (`floor(ts_seconds / 60)`) |
| `tribe` | `tribe-alpha` or `tribe-beta` |
| `agents_alive` | Count of hunter agents that ticked or spent CB in this bucket |
| `cb_balance` | Sum of CB spent on `prompt()` calls in this bucket (from `.agentis/spend/`) |
| `findings_emitted` | Count of `learn()` rows tagged `tribes-bench` |
| `true_positives` | Subset of `findings_emitted` carrying the `acted` tag (verifier returned `verified=true`) |
| `false_positives` | Subset carrying the `false-positive` tag (verifier returned `verified=false`) |

A run with `findings_emitted == true_positives + false_positives + observed-tag rows` is healthy.

## Layout

```
tribes-bench/
  tribe-alpha/        First tribe colony (one hunter agent)
    agents/hunter.ag  Seed prompt: format!()-as-shell-builder heuristic
    config/, scripts/
  tribe-beta/         Second tribe colony (one hunter agent)
    agents/hunter.ag  Seed prompt: source-to-sink data-flow heuristic
    config/, scripts/
  targets/stage0/
    vulnerable.rs     ~50 LOC Rust with three planted bugs
    bugs.json         Ground-truth manifest (id, line, line_tolerance, signature)
  tools/
    verify-finding.sh  Pure-shell + jq verifier (no LLM, no agentis)
    test-verify-finding.sh  Six-fixture unit test
    run-stage0.sh      Hermetic one-shot run wrapper
    analyse-stage0.py  Telemetry CSV producer
  start-federation.sh  ADR-0003-friendly launcher
  install.sh           Memo seed + colony.toml copy
```

## Tier contract

Every agent in this federation gates its behaviour on the four-tier
confidence ladder defined in
[ADR-0001](../doc/adr/ADR-0001-confidence-tiers.md):

- `shadow` — observe + memo, no emit, no external write
- `propose` — emit on bus + draft external writes
- `review-gated` — direct external writes (non-terminal)
- `autonomous` — terminal external writes (merge, tag, ack alert, post reply, …)

Stage 0 hunters seed at `0.7` (mid-`propose`). Verification (running
`tools/verify-finding.sh`) is internal — not an external write — so
calling it from the propose branch is consistent with ADR-0001.

## Related

- Issue: [#363](https://github.com/Replikanti/agentis-colonies/issues/363) — Stage 0 wiring (this PR)
- Issue: [#364](https://github.com/Replikanti/agentis-colonies/issues/364) — Stage 1 replication + scarcity
- Issue: [#365](https://github.com/Replikanti/agentis-colonies/issues/365) — Stage 2 selection + market + reputation
