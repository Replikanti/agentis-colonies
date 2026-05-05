# Tribes Bench

![Version: unreleased](https://img.shields.io/badge/version-unreleased-lightgrey) ![Status: Experimental](https://img.shields.io/badge/status-experimental-purple)

**Version:** `0.0.0` (unreleased) · [Changelog](./CHANGELOG.md) · **Requires:** agentis >= `1.5.0` · **Status:** Experimental

> A research scaffold that tests whether the agentis runtime's
> emergent-layer primitives (replication, scarcity, selection,
> reputation, market) produce qualitatively different behaviour than
> LangGraph-class multi-agent tools. Five seed tribes (alpha, beta,
> gamma, delta, epsilon) hunt CVE-grade memory safety bugs in vendored
> Rust crates via a deterministic verifier — no human in the loop, no
> API budget, deterministic ground truth.

This federation was scaffolded via
[`tools/new-federation.sh`](../tools/new-federation.sh) and conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md). The
agent contract follows
[ADR-0001](../doc/adr/ADR-0001-confidence-tiers.md) end-to-end.

## Quick start

**Prerequisites**

- The `agentis` runtime binary on PATH. It is a proprietary closed
  source binary distributed for free for Linux and macOS at
  https://github.com/Replikanti/agentis. tribes-bench requires
  `agentis >= 1.5.0`.
- Claude Code CLI (`claude`) on PATH for the LLM backend.
- `git`, `python3`, and `jq` on PATH (standard on most distros).

**Three-line recipe**

```bash
bash tribes-bench/install.sh                    # idempotent setup
bash tribes-bench/tools/run-verdict-pair.sh     # ~30-min ecosystem + baseline pair
# (optional) open dashboard at http://localhost:8420 after starting it
```

`install.sh` checks the runtime version, copies each tribe's
`colony.toml` from the example, and seeds `hunter:confidence = 0.7`.
`run-verdict-pair.sh` orchestrates `run-stage2.sh` -> `run-baseline.sh`
-> `analyse-stage2.py --baseline <latest>` and prints the resulting
`comparison.md` to stdout. Each step is echoed with a leading `+ `
prefix before executing so operators can copy individual lines if
they want to drive the steps manually. Defaults:
`STAGE2_WALL_CLOCK_S=1800` and `STAGE2_BASELINE_WALL_CLOCK_S=1800`
(30 min each); override the env vars for longer pilots.

For the long-form Stage 2 M3 (48h ecosystem + 1h baseline) recipe see
[Stage 2 M3 reproduction recipe](#stage-2-m3--long-run--baseline-reproduction-recipe)
below.

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

**M1 proves** (historical — current `start-federation.sh` spawns 5 tribes after Stage 2 M2 added `tribe-delta` + `tribe-epsilon`; see Stage 2 sections below):

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
  bash start-federation.sh                    # M1: spawns 3 tribes against targets/stage0; M2 added delta + epsilon for 5 total
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

## Stage 2 (M2 — cognitive market + reputation)

Stage 2 M2 ([#393](https://github.com/Replikanti/agentis-colonies/issues/393))
turns the 5-tribe federation into an **ecosystem** by wiring four
inter-tribe coordination primitives on top of the M1 scaffolding. Pure
infrastructure — no live experimental run lands here (that's M3, #394).

**The four deliverables:**

1. **Reputation memos.** Every tribe carries a single float in
   `reputation:tribes-bench-<tribe>` initialised to `0.5` and updated
   inline in the hunter on every verified finding (`+0.05`, clamp 1.0)
   and every false positive (`-0.10`, clamp 0.0). The asymmetry
   produces a ~10-find ceiling and a ~5-find floor; no per-tick decay
   to keep the M3 cost-per-finding reading clean.

2. **Knowledge market wiring.** The hunter calls `knowledge_sell` on
   every verified finding (per-finder topic prefix
   `tribes-bench-<finder>/<bug_id>`) and `knowledge_buy` at the start
   of every 8th tick (pool-aware skip below `pool_minimum_for_buy`).
   The seller's ask-price formula is `max(1, floor(rep*10) + 1)`; the
   buyer's max_cb is `floor(rep*20) + 5`. Bootstrap stays trade-active
   at t=0 because every tribe's mid-band reputation (0.5) lists at ask
   6 against a max_cb of 15.

3. **Espionage primitive.** High-rep tribes (rep > 0.7) list a
   `tribes-bench-bundle/<self>` topic once per `bundle_period` verified
   findings, holding the last-K bug_ids. Low-rep tribes (rep < 0.3)
   with a CB surplus above `cb_surplus_threshold` buy the highest-rep
   sibling's bundle at a 5× premium. Asymmetric information at premium
   price; M3 will measure whether this stratifies the federation.

4. **Telemetry CSV.** Every buy and every sell call writes one row to
   `<run-dir>/knowledge-market.csv` via an `exec sh "printf >> ..."`
   path-safe append. Schema:

   ```
   ts_ms, agent_id, tribe, op, topic, topic_kind,
   ask_price, max_cb, paid_price, cache_hit,
   downstream_verified, op_outcome
   ```

   `tools/analyse-stage2.py` reads the log, resolves
   `downstream_verified` post-hoc by scanning the buyer's experience
   JSONL within 5 ticks, and rewrites the CSV with a header line.

**Analyser revenue contract** (per #393 §9 risk 2): seller revenue is

> `revenue = Σ(ask_price for r in rows where r.op="buy" AND r.cache_hit=0)`

NOT total trade volume. The runtime caches successful purchases under
`knowledge:<topic>`; subsequent buyers in the TTL window get
`cognitive.cache_hit` and pay zero CB to the original seller. The
trade CSV's `cache_hit` column tags every free-ride row so the M3
analyser can compute revenue strictly on substrate (non-cache-hit)
purchases.

**Calibration.** All knobs (`buy_gate_modulus`, `pool_minimum_for_buy`,
`bundle_period`, `cb_surplus_threshold`, `ask_floor`,
`ask_max_at_full_rep`, `max_cb_at_full_rep`, `premium_multiplier`,
`reputation.{initial,verify_step,false_positive_step,ceiling,floor}`)
ship in [`tribes-bench/calibration.toml`](./calibration.toml) under
`[reputation]` and `[knowledge_market]`. Defaults match the in-script
`:-` fallbacks and the hard-coded values in the hunter formulas;
operators tune via the M3 harness (#394) without touching `.ag`.

**Stage 2 M2 reproduction recipe** (offline / pure-test):

```bash
cd tribes-bench/
./install.sh                                          # idempotent; refuses on agentis < 1.5.0
bash tools/test-stage2-cognitive-market.sh            # market wiring assertions
bash tools/test-stage2-reputation.sh                  # reputation primitive assertions
```

End-to-end multi-day live runs land in M3 (#394).

## Stage 2 (M3 — long-run + baseline) reproduction recipe

Stage 2 M3 ([#394](https://github.com/Replikanti/agentis-colonies/issues/394))
ships the infrastructure for the long-run thesis verdict: a
fixed-pipeline baseline harness, a 48h/1h-default ecosystem harness, a
crash-recovery drill, and a comparison report. The thesis verdict
itself is operator-driven — M3 PR ships the tooling that produces it,
not the verdict.

**3-step recipe** (plan Decision 4):

1. Run the baseline (single tribe, no replication, no market):

   ```bash
   bash tools/run-baseline.sh
   # produces: runs/baseline-<utc-ts>/telemetry.csv
   ```

2. Run the 5-tribe ecosystem (long-run defaults: 48h wall clock, 1h
   snapshot interval):

   ```bash
   bash tools/run-stage2.sh
   # produces: runs/<utc-ts>/{telemetry.csv,knowledge-market.csv,bug-ledger.jsonl,...}
   ```

3. Produce the comparison report:

   ```bash
   python3 tools/analyse-stage2.py runs/<eco-ts> \
       --baseline runs/baseline-<bl-ts>/telemetry.csv
   # produces: runs/<eco-ts>/comparison.md
   ```

**Snapshot SHAs to record at PR-merge time** (placeholders below — the
operator running M3 must pin the actual SHAs from their pre-run
`sha256sum` of the inputs and any reproducibility-relevant binaries):

| Input | sha256 |
|---|---|
| `tribes-bench/calibration.toml` | `<pin at merge>` |
| `tribes-bench/targets/stage2/smallvec-v0.6.13/lib.rs` | `<pin at merge>` |
| `tribes-bench/targets/stage2/bugs.json` | `<pin at merge>` |

**Non-determinism caveat** (plan Decision 6). The LLM backend is the
dominant non-deterministic factor: even with identical seed prompts +
identical CB budget + identical target, two runs through Claude (or any
hosted LLM) will produce divergent finding sets. The harness pins
`agentis --version`, the snapshot SHAs, and the LLM backend label
(`runs/<ts>/llm-backend.txt`); the operator should record the LLM
provider's model version separately. The comparison report's arithmetic
is reproducible; the underlying telemetry is not byte-identical between
runs.

**M3 test inventory** (6 tribes-bench tests). Live-fire tests skip when
agentis is not on PATH or no LLM API key is in env; fixture-driven tests
always run:

| Test | Mode |
|---|---|
| `tools/test-stage2-baseline-runner.sh` | static + opportunistic live smoke (15s) |
| `tools/test-stage2-crash-recovery.sh` | static + opportunistic live drill |
| `tools/test-stage2-analyse-comparison.sh` | fixture-only (no agentis spawn) |
| `tools/test-stage2-scaffold.sh` | fixture-only (M1) |
| `tools/test-stage2-cognitive-market.sh` | fixture-only (M2) |
| `tools/test-stage2-reputation.sh` | fixture-only (M2) |

## Layout

```
tribes-bench/
  tribe-alpha/        Seed colony, one hunter agent (Stage 0/1 prompt: format!()-as-shell-builder; Stage 2 specialty: uninitialised memory)
  tribe-beta/         Seed colony, one hunter agent (Stage 0/1 prompt: source-to-sink data-flow; Stage 2 specialty: heap overflow)
  tribe-gamma/        Stage 1 M1 colony, one hunter agent (Stage 1 prompt: error-path data-flow; Stage 2 specialty: memory corruption)
  tribe-delta/        Stage 2 M2 colony, one hunter agent (specialty: use after free)
  tribe-epsilon/      Stage 2 M2 colony, one hunter agent (specialty: use after free, panic-unwind variant)
  templates/
    tribe-baseline/   Stage 2 M3 baseline-arm template (single-tribe generalist with stubbed market primitives)
  targets/stage0/
    vulnerable.rs     ~50 LOC Rust with three planted bugs
    bugs.json         Ground-truth manifest (id, line, line_tolerance, signature)
  targets/stage1/     Stage 1 M1 — three CWE classes, 10 planted bugs
    cmd_exec.rs       4 command-injection bugs (CWE-78), ~150 LOC
    path_io.rs        3 path-traversal bugs (CWE-22), ~120 LOC
    fmt_str.rs        3 format-string bugs (CWE-134), ~140 LOC
    bugs.json         Ground-truth manifest with `class` field
  targets/stage2/     Stage 2 — vendored real-world Rust crate(s) with RUSTSEC bug palette
    smallvec-v0.6.13/ Vendored smallvec lib.rs with 5 CVE-grade memory safety bugs
    bugs.json         Ground-truth manifest keyed on RUSTSEC bug class
  tools/
    verify-finding.sh         Pure-shell + jq verifier (no LLM, no agentis), Stage 0/1 dispatch
    verify-finding-stage2.sh  Stage 2 verifier with bug-class match + signature substring check
    test-verify-finding.sh    Six-fixture unit test (Stage 0); STAGE1=1 mode adds Stage 1 fixtures
    run-stage0.sh             Hermetic one-shot run wrapper (Stage 0)
    run-stage1.sh             Hermetic one-shot run wrapper (Stage 1 M1)
    run-stage2.sh             Hermetic one-shot run wrapper (Stage 2 M3 ecosystem arm)
    run-baseline.sh           Hermetic one-shot run wrapper (Stage 2 M3 baseline arm)
    run-verdict-pair.sh       Orchestrator: run-stage2 -> run-baseline -> analyse with --baseline (Stage 2 M3)
    analyse-stage0.py         Telemetry CSV producer (Stage 0, 7 columns)
    analyse-stage1.py         Telemetry CSV producer (Stage 1 M1, 10 columns)
    analyse-stage2.py         Telemetry CSV + comparison.md producer (Stage 2 M3)
    check-agentis-version.sh  Runtime floor check; prints download URL when binary missing
    snapshot-stanza.sh        Append per-pilot snapshot stanza to runs/<ts>/snapshots/
    test-stage2-*.sh          Six fixture-driven + opportunistic-live tests for Stage 2 M3
    test-run-verdict-pair.sh  Smoke test for run-verdict-pair.sh dry-run output
  start-federation.sh         ADR-0003-friendly launcher (5 tribes after Stage 2 M2)
  install.sh                  Memo seed + colony.toml copy + Next-steps summary
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

## Known gotchas

- **Dashboard cascade on `tools/kill-federation.sh`:** resolved by
  [#440](https://github.com/Replikanti/agentis-colonies/issues/440).
  The shutdown script (called automatically at the end of every
  `run-stage2.sh` / `run-baseline.sh` / `run-verdict-pair.sh`) now
  scopes dashboard kills by daemon-registry membership, so a
  `federation-dashboard` launched by hand (e.g. via `setsid -f`)
  persists across pilot runs.

## Related

- Issue: [#363](https://github.com/Replikanti/agentis-colonies/issues/363) — Stage 0 wiring
- Issue: [#364](https://github.com/Replikanti/agentis-colonies/issues/364) — Stage 1 replication + scarcity
- Issue: [#365](https://github.com/Replikanti/agentis-colonies/issues/365) — Stage 2 selection + market + reputation
- Issue: [#394](https://github.com/Replikanti/agentis-colonies/issues/394) — Stage 2 M3 verdict apparatus (5-tribe vs baseline)
- Issue: [#439](https://github.com/Replikanti/agentis-colonies/issues/439) — Stage 3 emergence prerequisites (multi-node, mutation, target rotation, real selection pressure)
