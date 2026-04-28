# Tribes Bench

![Version: unreleased](https://img.shields.io/badge/version-unreleased-lightgrey) ![Status: Experimental](https://img.shields.io/badge/status-experimental-purple)

**Version:** `0.0.0` (unreleased) · [Changelog](./CHANGELOG.md) · **Requires:** agentis >= `1.4.1` · **Status:** Experimental

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

## Stage 1 (M1 — infrastructure only)

Stage 1 is decomposed into three sequential PRs (M1, M2, M3). M1 ships
**infrastructure only**: a third tribe (`tribe-gamma`), a 10-bug
three-class target tree under `targets/stage1/`, the verifier extended
with optional `class` dispatch, a sibling 10-column telemetry analyser,
and the launcher / installer wired for the third tribe. The emergent
Stage 1 primitives (`replicate()`, Malthusian per-replica cost,
asymmetric first-finder reward) ship in M2 and M3 — they are explicitly
**not** part of M1.

**M1 proves:**

- Three-tribe topology launches cleanly (`tribe-alpha`, `tribe-beta`,
  `tribe-gamma`) via `start-federation.sh`.
- Three CWE classes (CMD-INJ, PATH-TRAV, FMT-STR) are exercised by 10
  planted bugs in `targets/stage1/{cmd_exec,path_io,fmt_str}.rs`. Each
  file carries an `INTENTIONALLY INSECURE` header banner and compiles
  cleanly with `rustc --edition 2021`.
- The deterministic verifier dispatches on the optional `class` field
  on stdin while keeping Stage 0 behaviour byte-identical when `class`
  is absent.
- The Stage 1 telemetry CSV schema is fixed at 10 columns (Stage 0's 7
  + `bug_class`, `is_first_finder`, `tribe_size`).

**M1 does NOT prove:**

- No `replicate()` calls. No Malthusian cost. No asymmetric reward.
  Tribe-gamma is a third seed, not a replica.
- No tribe death. No CB drain → graceful daemon stop. No calibration
  verdict — those land in M2/M3 with operator-driven multi-hour runs.
- No end-to-end Stage 1 wrapper script (`tools/run-stage1.sh` ships in
  M3). For M1, the reproduction recipe is verifier + lint only:

  ```bash
  cd tribes-bench/
  ./install.sh                                # idempotent: copies tribe-gamma config too
  bash tools/test-verify-finding.sh           # Stage 0 fixtures (back-compat)
  STAGE1=1 bash tools/test-verify-finding.sh  # Stage 1 fixtures (3 classes)
  bash start-federation.sh                    # spawns 3 tribes against targets/stage0 by default
  ```

  To exercise targets/stage1 manually, set `TARGET_DIR` and
  `BUGS_MANIFEST` before launching the federation.

### Stage 1 telemetry CSV

`runs/<utc-timestamp>/telemetry.csv` produced by `tools/analyse-stage1.py`
extends the Stage 0 7-column schema with three Stage 1 columns:

| Column | Meaning in M1 | Future role |
|--------|---------------|-------------|
| `minute` | (unchanged) | |
| `tribe` | (unchanged, now includes `tribe-gamma`) | |
| `agents_alive` | (unchanged) | |
| `cb_balance` | (unchanged) | |
| `findings_emitted` | (unchanged) | |
| `true_positives` | (unchanged) | |
| `false_positives` | (unchanged) | |
| `bug_class` | **New.** Comma-joined class(es) of verified findings in the minute. Empty when no verified finding lands. Lookup runs through `targets/stage1/bugs.json` keyed on the verifier's `bug_id`. | Specialisation heatmap (Stage 1 acceptance criterion) |
| `is_first_finder` | **New, placeholder.** Always `0` in M1 — the asymmetric-reward shared journal lands in M3. Documented as forward-compat so M2/M3 are pure plumbing changes (no schema migration). | Asymmetric-reward signal (M3) |
| `tribe_size` | **New, placeholder.** Always `1` in M1 — `replicate()` lands in M2. Same forward-compat reason as `is_first_finder`. | Replication signal (M2) |

The placeholder semantics matter: M1 ships the columns deterministically
(`0` and `1`) so M2 and M3 are pure plumbing changes (no schema migration
for downstream consumers).

### Stage 1 reproduction recipe (M1)

End-to-end live runs of Stage 1 (replicate + asymmetric reward + tribe
death) are M3 scope and operator-driven. The M1-shippable recipe is the
same as the Stage 0 recipe with the addition of the Stage 1 verifier
fixtures:

```bash
cd tribes-bench/
./install.sh
bash tools/test-verify-finding.sh             # 6/6 PASS (Stage 0)
STAGE1=1 bash tools/test-verify-finding.sh    # 6/6 PASS (Stage 1 — 3 classes)
```

To smoke a single Stage 1 finding through the verifier without launching
the federation:

```bash
echo '{"line": 12, "class": "command_injection"}' \
    | TARGET_DIR=tribes-bench/targets/stage1 \
      BUGS_MANIFEST=tribes-bench/targets/stage1/bugs.json \
      bash tribes-bench/tools/verify-finding.sh
# {"verified": true, "bug_id": "S1-CMDINJ-001"}
```

## Layout

```
tribes-bench/
  tribe-alpha/        First tribe colony (one hunter agent)
    agents/hunter.ag  Seed prompt: format!()-as-shell-builder heuristic
    config/, scripts/
  tribe-beta/         Second tribe colony (one hunter agent)
    agents/hunter.ag  Seed prompt: source-to-sink data-flow heuristic
    config/, scripts/
  tribe-gamma/        Third tribe colony (one hunter agent, Stage 1 M1)
    agents/hunter.ag  Seed prompt: error-path data-flow heuristic
    config/, scripts/
  targets/stage0/
    vulnerable.rs     ~50 LOC Rust with three planted bugs
    bugs.json         Ground-truth manifest (id, line, line_tolerance, signature)
  targets/stage1/     Stage 1 M1 — three CWE classes, 10 planted bugs
    cmd_exec.rs       4 command-injection bugs (CWE-78), ~150 LOC
    path_io.rs        3 path-traversal bugs (CWE-22), ~120 LOC
    fmt_str.rs        3 format-string bugs (CWE-134), ~140 LOC
    bugs.json         Ground-truth manifest with `class` field
  tools/
    verify-finding.sh  Pure-shell + jq verifier (no LLM, no agentis)
                       Optional `class` dispatch for Stage 1
    test-verify-finding.sh  Six-fixture unit test (Stage 0)
                            STAGE1=1 mode adds 6 Stage 1 fixtures
    run-stage0.sh      Hermetic one-shot run wrapper (Stage 0)
    analyse-stage0.py  Telemetry CSV producer (Stage 0, 7 columns)
    analyse-stage1.py  Telemetry CSV producer (Stage 1 M1, 10 columns)
  start-federation.sh  ADR-0003-friendly launcher (3 tribes)
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
