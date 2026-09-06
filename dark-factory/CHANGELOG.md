# Changelog — dark-factory

All notable changes to the `dark-factory/` federation will be documented in
this file.

This federation follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
at the federation level. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tags use the prefixed form `dark-factory-v<X.Y.Z>` so other federations
in this repo can release independently without collision.

Every release declares its runtime floor as `**Requires:** agentis >= X.Y.Z`.

## [Unreleased]

### Added
- **`run-zone-hunt.sh --model <id>`: thread a model id through every LLM stage of the zone-hunt pipeline**
  (#2114). Enables a model A/B (e.g. Fable 5.1 vs Opus) over the whole capstone without editing any stage
  in isolation. `--model <id>` is parsed by `run-zone-hunt.sh`, `verify-findings.sh` and `deep-hunt-gate.sh`
  (both new) and forwarded as `${MODEL:+--model "$MODEL"}` to every downstream substrate-facing call
  (`map-zones.sh`, `gen-briefs.sh`, the discovery hunt invocation, `verify-findings.sh`'s refute gate, both
  invariant-hunt invocations, and `deep-hunt-gate.sh`'s refute gate) — the same one-idiom-everywhere pattern
  `run-discovery.sh`/`run-refute.sh`/`run-invariant-hunt.sh` already use. `map-zones.sh` and `gen-briefs.sh`
  now emit `llm.model = ${MODEL:-opus}` instead of the hardcoded `llm.model = opus`. Additive and default-off:
  an unset `--model` leaves every emitted config byte-identical to before this flag existed.

### Fixed
- **hunt-dashboard: the DEPTH panel no longer mis-states the deep-hunt track — no phantom queued row for a
  no-logic zone, and automatically-refuted findings are triaged as such** (#2108). Two display-correctness
  bugs in `hunt-dashboard/hunt-dashboard.py`, fixed together. (a) `planned_deep_rows()` reconstructed the
  STAGE 4.5 lens matrix from every zone with any `bug_classes_likely`, so a zone that is all
  interface/events/abstract signatures — nothing a stateful-invariant fuzzer can deploy or call — showed a
  permanent `⬜ queued` DEPTH row that never cleared, making every hunt read as incomplete. `map-zones.sh`
  now writes a mechanical `has_implementation` boolean per zone (a comment-stripped function-body scan over
  the zone's own `.sol` files), and the dashboard excludes a zone from the planned matrix ONLY on an explicit
  `has_implementation == false` — so a legacy `zones.json` without the key, and a huntable zone merely capped
  out by `--deep-hunt-max-targets`/`--deep-hunt-max-lenses`, both still render their real queued coverage-gap
  row. (b) `deep_hunt()` derived a finding's adjudication only from the manual `deep-hunt-adjudicated.tsv`
  overlay, so an automatically-REFUTED deep-hunt finding (the #1938 4.6 refute gate, default-ON) kept showing
  as an open `◆ FINDING · needs forge PoC + triage` until a human hand-wrote the TSV. `deep_hunt()` now folds
  the per-slot `refute-gate/refute-out/refute-report.md` verdict as a FALLBACK behind the manual overlay
  (human override still wins); a gate-sourced REFUTED renders as a triaged FP with a compact `· auto (4.6
  gate)` provenance marker, while a `REAL`/survived verdict stays needs-PoC (a survivor is never
  auto-refuted).

## [0.11.0] - 2026-09-05

**Requires:** agentis >= `1.22.7`

### Added
- **Per-cell LLM timeout floor and cap now environment-overridable for discovery and deep-hunt** (#2106). Discovery
  and deep-hunt harness generation now allow operators to override the per-cell LLM timeout floor and cap via
  environment variables, enabling fine-grained control over timeouts in different deployment scenarios. New environment
  variables: `DF_HUNT_TIMEOUT_FLOOR_MS` and `DF_HUNT_TIMEOUT_CAP_MS` for discovery (run-discovery.sh),
  `DF_GEN_TIMEOUT_BASE_MS` and `DF_GEN_TIMEOUT_CAP_MS` for deep-hunt harness generation (run-invariant-hunt.sh).
  An unconditional floor>cap clamp keeps the floor as a hard minimum even if the cap is set below it,
  ensuring discovery and deep-hunt remain predictable under misconfiguration. See #2103 for motivation.

## [0.10.1] - 2026-09-04

**Requires:** agentis >= `1.22.7`

### Fixed
- **hunt-dashboard: raw breadth candidates at the same location no longer show duplicate rows with stale
  "needs PoC" siblings once one copy is verified/adjudicated** (#2024). A `--rehunt-gaps` re-find or a second
  lens pass re-flagging the identical file:fn appended another raw `leads()` entry with no dedup, and the
  operator-adjudication lookup in `_lead_state()` was keyed on `(location, class)` — so a `CONFIRMED` verdict
  recorded against one class did not apply to a sibling raw candidate at the SAME location tagged a different
  class, leaving it stuck reading "◆ survived refute · needs PoC". A new `_group_leads()` folds raw candidates
  by EXACT normalized location only (`_normloc`, no fuzzy match — two genuinely different locations never
  collapse), resolving the collapsed row's state by precedence (`op_confirmed > op_duplicate > survived >
  pending > refuted`, i.e. any verified copy wins, and a location reads refuted only when EVERY copy was) via
  the SAME shared `_lead_state()` classifier so render and `--emit-model` stay in lockstep (per #2023/#2027).
  Both `page()` and `emit_model()` now tally zones/header/chips/rows over the grouped list; a folded row's
  Detail cell discloses the fold (`· folded from N copies (...)`) and the JSON model carries additive
  `n_folded`/`classes` fields — never a silent collapse. Pinned by `demo-hunt-dashboard.sh` (block 23,
  `--emit-model` + `--render`).
- **An operator adjudication now WINS over an automated refute verdict — a confirmed finding can no longer be
  silently downgraded to REFUTED** (#2023). Two complementary fixes for one root cause (the operator
  adjudication overlay `adjudicated.tsv` was not authoritative over the STAGE-4 refute gate's
  `verify/gates/*/verdict.txt`). (1) `hunt-dashboard.py`: a single shared `_lead_state()` classifier now drives
  EVERY breadth verdict-selection site (render leads + zone counters + header tally AND the `--emit-model`
  assertion surface), applying operator precedence FIRST and the gate verdict only for un-adjudicated leads —
  closing the drift that let `#2005/#2007` fix the render path while the model path still tested the gate's
  REFUTED first. (2) `verify-findings.sh` gains an optional `--adjudicated <file>`: a candidate whose normalized
  location matches an operator adjudication is NOT re-refuted (saving a gate pass and removing the risk of the
  machine overriding the human) and its verdict is PRESERVED — a real-bug CONFIRMED/DUPLICATE stays in
  `verified_findings.json`, so a `--rehunt-gaps` pass (which `rm -rf`s the gates dir every run) can never
  downgrade it. `run-zone-hunt.sh` forwards the overlay only when it exists, keeping a first run byte-identical.
  Both surfaces are pinned by `demo-hunt-dashboard.sh` (`--emit-model` + `--render`) and `demo-verify-findings.sh`
  (skip + preserve-across-wipe); the whole feature is inert without the overlay/flag.
- **hunt-dashboard: "Discovery hunt" no longer shows 🔄 running once the sweep has ended incomplete** (#2020).
  `phase_status()` keyed the M3 phase off `reached < total_z`, so a terminated-but-incomplete sweep — a
  `hunted_degraded` (or `failed`) zone that leaves `covered < total_z` while the run has already moved on to
  deep-hunt — read as discovery still churning. M3 is now `run` only while discovery is genuinely LIVE (a zone
  `in_flight`, or the newest active sub-log is a discovery cell); a terminated incomplete sweep is a `gap` (⚠️)
  with an accurate `zone N/total · K degraded` label, mirroring the deep-hunt `active_deep_slot()` liveness gate
  (#2001). The progress bar is unchanged across the run→gap transition (`reached` is preserved).
- **Discovery fail-fast on a runaway hunter cell** (#2017). A non-terminating value-seam read (the storage C15
  case) blows through the per-cell `llm.cli_timeout_ms` with ZERO output; agentis-core then re-runs the
  `[llm.timeout]` `1 + llm.max_retries` times (default 3 attempts), so a single hang cost ~3x the budget — up to
  ~90 min on an 1800s-capped dense zone. Two changes cap it: (a) `hunter.ag` gains a bounded-termination clause
  that forces the lens to CONVERGE — it still makes the cross-file / consumer-misuse hop that finds the real
  bugs (a params/declaration file is attackable through how other contracts consume its fields), but bounds the
  effort to ~1-3 seams and then emits a terminal verdict (the substantiated `CANDIDATE`, or `SAFE`) instead of
  chasing consumers forever; and (b) `run-discovery.sh` now writes `llm.max_retries = 1` into each hunter cell's
  `.agentis/config`, capping the residual timeout path at 2x the budget (down from 3x) while KEEPING one
  in-process retry so a transient timeout (host-overheat de-bunch, session-slot wait, one-off PTY/API spike)
  still recovers on attempt 2 rather than becoming an immediate FAILED cell + false `hunted_degraded` zone.
  Backend-agnostic, colonies-side only — no core change. `demo-discovery-fail-fast.sh` (registered in
  `colony-lint`) source-guards the `= 1` emission and mechanically proves the one-retry cap plus transient
  recovery over a real `agentis go`; the (a) recall-preservation + termination is verified by a live
  flat-cyborg C1/C11/C15 triple against the storage file. This addresses the retry-COST multiplier and the
  reasoning non-termination, distinct from the timeout-SIZE tuning (#1955/#2013) and the dense-zone file-split
  (#1957).
- **Durable re-hunt launcher** (#1992). `run-zone-sweep.sh` now launches each re-hunt pass detached under
  `setsid` (its own session + a `<out>/coverage/.rehunt-pid` file), so a teardown of the sweep's process group
  (e.g. the operator's shell exiting) no longer kills the re-hunt mid-zone-iteration — previously only the first
  gap zone got hunted. The sweep still `wait`s on the child, so the happy-path exit code and ledger bookkeeping
  are unchanged; a synchronous fallback covers hosts without `setsid` (macOS). This removes only the
  process-lifecycle failure — the remaining discovery-timeout coverage cap (dense zones re-degrade on the
  STAGE 3 discovery LLM timeout regardless of a correct re-hunt set) is tracked in #1957.

## [0.10.0] - 2026-08-19

**Requires:** agentis >= `1.22.7`

### Added
- **Hide sub-floor leads from the LEADS table** (#1968). Hunt-dashboard now filters out findings below the
  program's pay floor from the main LEADS display, reducing visual clutter and focusing operator attention on
  payable candidates. Early pay-floor filtering remains active upstream in `verify-findings.sh` (#1964).

### Fixed
- **Deep-hunt DEPTH rows always show normalized severity** (#1978). DEPTH phase rows now display the actual
  discovered severity value (normalized across lenses) instead of placeholder text, making deep-hunt findings
  actionable without opening the detail view.
- **Severity/class normalizer whitespace-position-agnostic** (#1977). The hunt-dashboard normalizer now
  correctly handles malformed LLM outputs where severity/class markers appear in unexpected positions or with
  variable whitespace, improving robustness on real-world LLM variance.
- **Normalize malformed LLM severity/class values in hunt-dashboard leads** (#1975). Adds defensive parsing
  for severity and classification fields extracted from hunt results, preventing display corruption when LLMs
  emit unexpected formatting.
- **Drop span-level opacity from HARNESS_ERROR/queued Sev spans** (#1973). Hunt-dashboard severity spans for
  HARNESS_ERROR and queued states no longer apply redundant opacity, improving visual clarity and reducing
  CSS complexity.

## [0.9.0] - 2026-08-18

**Requires:** agentis >= `1.22.7`

### Added
- **Early pay-floor filter** (#1964). `verify-findings.sh` now filters out candidates below the program's
  pay floor BEFORE the resource-intensive refute, PoC, and verify gates, reducing unnecessary LLM usage.
  The hunt intake chain gains a `--pay-floor <N>` parameter threaded from `run-zone-hunt.sh`, and the
  `verified_findings.json` report now carries additive `pay_floor`, `dropped_subfloor[]`, and
  `totals.dropped_subfloor` fields to track early-rejected candidates without consuming the full audit depth.

## [0.8.0] - 2026-08-18

**Requires:** agentis >= `1.22.7`

### Added
- **HUNT-DASHBOARD — multi-hunt overview → detail, M2** (#1913). Generalizes the M1 single-hunt view to a
  multi-hunt server on ONE fixed port over a `${DARK_FACTORY_DIR:-$HOME/.dark-factory}/hunts/<id>.json`
  descriptor registry. The landing page is now an **overview grid** — one clickable card per registered hunt
  (label, optional bounty link, mini progress bar + %, the live status dot, and a compact
  `zones X/Y · N leads · K deep FINDING` summary); a finished hunt's card is a static slate, a live one
  pulses. Clicking a card opens that hunt's full M1 detail dashboard (routed via `?hunt=<id>`, bookmarkable)
  with a `← overview` control + a compact hunt-switcher pill row. Discovery reads the registry best-effort
  (a malformed descriptor is skipped) and **always re-derives liveness + artifacts live** — descriptors carry
  static metadata only; a missing/empty registry dir renders a graceful empty overview rather than crashing.
  `run-zone-hunt.sh` grows a **default-safe, opt-in registration hook**: at launch it atomically (`tmp` + `mv`)
  writes the hunt's descriptor into the registry **only when the operator has created the registry dir** — with
  that dir absent the launch writes nothing and is byte-identical to before (the hook derives the repo URL from
  the intake queue's existing `--scope-hint repo:<url>` token, zero new plumbing). Also folds in the STAGE 4.5
  three-state deep-hunt annotation (*not reached yet* / *reached — 0 lenses routed* / *N ran*, #1913 comment
  5308547720). The launcher `hunt-dashboard.sh` serves the registry when invoked with neither a descriptor nor
  path flags (single-hunt invocation preserved). New offline demo `demo-hunt-dashboard-multi.sh` (hooked into
  `colony-lint.sh`) pins registry discovery, the overview card set + per-hunt liveness, `?hunt=<id>` detail
  routing, the empty-registry path, and the opt-in atomic registration (byte-identical hunt artifacts when off).

### Changed
- **Zone-weighted per-cell hunt timeout + fail-fast on timeout** (#1956). Per-zone timeout is now weighted by
  zone `cost` (in cell counts), preventing pathological LLM hangs from blocking discovery. On `[llm.timeout]`,
  the hunt immediately advances to the next zone rather than logging and retrying.
- **`flat-cyborg` >= 0.13.0 floor for the flat-cyborg backend** (#1925). The stage `idle_ms` knobs
  (`run-refute.sh`, `run-discovery.sh`, `run-invariant-hunt.sh`, `map-zones.sh`, `gen-briefs.sh`, `run-poc.sh`)
  were never a correctness fix — completion is gated on the wrapper's closing sentinel from flat-cyborg
  `--extract-structural` mode (>= 0.13.0); `idle_ms` only bounds how fast a marker-less reply is accepted, and
  ratcheting it further does not address a completion-path regression. `run-zone-hunt.sh` now runs a soft
  preflight (active only for `--backend flat-cyborg`): a missing `flat-cyborg` binary or a version below
  0.13.0 prints a loud warning (marker-less completion can silently lose leads) and the hunt continues.

### Fixed
- **DEPTH rows show intrinsic severity, not placeholder** (#1954). Planned deep-hunt rows now correctly
  reflect the per-lens severity discovered in the hunt rather than a placeholder value.
- **Strip severity prefix from breadth LEADS** (#1959). Breadth discovery leads now display severity without
  the redundant `severity=` prefix in the leads table.
- **Payability badge on sub-floor leads** (#1961). Added display-only `$0` badge to mark findings below the
  program's pay floor, clarifying which leads are ineligible for payout.
- **Component subdirs are shellchecked** (#1945). `tools/colony-lint.sh` extends the #1554 federation-root
  sweep to also walk federation subdirectories that are NOT colonies (no `config/`, e.g.
  `dark-factory/hunt-dashboard/`) at unbounded depth, so `hunt-dashboard.sh` and any future
  `<federation>/<component>/**/*.sh` gets automatic regression coverage instead of none. Colony dirs stay
  owned by the per-colony sweep (no double-linting) and dot-dirs are pruned. Along the way,
  `evm-harness/hardhat-poc.sh` annotates its accepted-and-ignored `MATCH` flag (`SC2034`, kept for CLI
  parity with `forge-poc.sh`).

## [0.7.0] - 2026-08-17

**Requires:** agentis >= `1.22.7`

### Added
- **HUNT-DASHBOARD — reusable read-only single-hunt view, M1** (#1913). A new `hunt-dashboard/` component: a
  localhost-only HTTP dashboard that renders a live zone-hunt from its on-disk artifacts (regenerated per
  request, read-only, `127.0.0.1` only). This is a **verbatim behavioural port** of the operator-approved
  per-hunt dashboard — grouped phase tracks (MAP / BREADTH / DEPTH / DELIVER) with dual refute gates and
  phase-weighted progress; a single unified LEADS table (`Type | Sev | Class | Location | Refute gate |
  Detail`) carrying both breadth discovery leads (with their per-lead refute-gate verdict) and depth STAGE
  4.5 deep-hunt rows (the full planned lens matrix, done/running/queued, with the `verified_findings.json`
  severity join and the `(file,class)` `deep-hunt-adjudicated.tsv` triage overlay); struck-through =
  no-live-bug (refuted / CLEAN) vs open FINDING / HARNESS_ERROR-gap; a live-process (`/proc`) liveness pulse
  that stays green only while genuinely working (buffered-LLM safe, hidden `.gen-briefs/` traversal) and a
  static slate when finished; a Zones panel whose Result agrees with the LEADS table; and honest completion
  (the `__EXIT__` marker alone never renders 100%, `HARNESS_ERROR`/`failed` zones excluded from the hunted
  count). The **only** functional change vs the reference is **config-driven paths**: the hunt root / out /
  log and the header chrome (label, reward line, program/repo/project links) come from a descriptor JSON or
  CLI flags (`--descriptor`, or `--root/--out/--log/--label/--reward-line/--bounty-url/--repo-url/
  --project-url`) instead of being hardcoded to one target — no host paths, no target specifics. Loopback
  launcher `hunt-dashboard.sh` (default port `8420`, override `--port`/`$HUNT_DASHBOARD_PORT`). Offline test
  seams: `--render` (HTML to stdout), `--emit-model` (facts as JSON), and `HUNT_DASHBOARD_FAKE_*` overrides
  for the `/proc` scan; non-Linux degrades to freshness-only. New `demo-hunt-dashboard.sh` (hooked into
  `colony-lint.sh`) pins the model over a checked-in, scrubbed fixture snapshot. Multi-hunt tabs / a hunt
  registry / the overview→detail navigation are **M2** (a follow-on PR).
- **REFUTE/VALIDITY GATE OVER STAGE 4.5 INVARIANT-HUNT FINDINGS** (#1938). A fuzzer reproducing a broken
  predicate is necessary but NOT sufficient: the predicate may be a mis-specified invariant (a per-operation
  budget read as a cumulative cap), a documented by-design behaviour, or a witness only a TRUSTED role can
  drive — three such findings shipped as "verified" false positives this session (reserve RebalancingLib,
  balancer Vault.settle, balancer Vault SYS-solvency). STAGE 4.5 (`run-zone-hunt.sh --deep-hunt`) now runs an
  adversarial gate over each `INVARIANT|...|FINDING` BEFORE recording it. `refuter.ag` gains an invariant-hunt
  judgment mode gated on a new `CAND_INVARIANT` env var (byte-identical to the discovery-lead prompt when
  unset): a two-axis rubric — invariant VALIDITY and witness REACHABILITY, REAL only if BOTH hold — with an
  INVERTED tie-break (default REAL on genuine uncertainty, since the witness is already reproduced) so a rare
  witnessed finding is not lost to doubt. `run-refute.sh` gains `--invariant-mode` (and optional
  `--invariant-harness` to append the generated predicate `*.t.sol`), registering `CAND_INVARIANT` /
  `INV_HARNESS_PATH` on `exec.env_passthrough`. New `deep-hunt-gate.sh` is a verbatim port of the STAGE 4.5
  inline merge adapter plus the gate: survivors -> `verified[]`, refuted findings -> a NEW additive `refuted[]`
  bucket with the `refute_reason`, a gate error -> `verified[]` tagged `refute_gate: unassessed` (fail-open, so
  a transient gate flake never silently deletes a fuzzer-witnessed finding). The gate is ON by default within
  `--deep-hunt` (itself opt-in, so the true default run stays byte-identical); `--no-deep-hunt-refute`
  reproduces the raw pre-gate merge byte-for-byte (golden-pinned). New `demo-deep-hunt-refute-gate.sh` (hooked
  into `colony-lint.sh`) drives the gate offline through the `--agentis` stub seam and asserts the anchors are
  refuted, the positive control survives, the byte-identity of `--no-refute`, the CLEAN no-op and the fail-open
  tag; `demo-verify-findings.sh` (M4 path) and `demo-run-zone-hunt.sh` (deep-hunt CLI coverage) stay green.
- **FINDING-LEVEL PAYABILITY GATE + PAYABLE-IMPACT DISCOVERY STEERING** (#1930). The funnel now self-determines
  what a target actually PAYS and acts on it, instead of surfacing sub-floor leads as progress.
  `run-immunefi-intake.sh` derives, per discovered program, the **pay_floor** (the lowest severity with a
  non-zero smart-contract reward) and the program's published **payable impact titles** from `bounties.json` —
  shape-tolerant (a recursive severity/amount walk plus a `rewardsBody` free-text fallback), and degrade-safe:
  nothing resolvable means no floor is asserted at all. The floor rides in the queue's `scope_hint` as
  `payfloor:<sev>` (the TSV stays 5 columns) and the impact titles go to a new `--payinfo-out` sidecar
  (default `<queue>.payinfo.json`), written only when something resolved. New
  `finding-payability-gate.sh` re-shapes `verified_findings.json` against that floor: sub-floor findings gain
  `pay_verdict: unpayable` + a `$0` note and are MOVED into an `unpayable[]` array (`--mode flag` only
  annotates); an unrankable severity is never dropped (fail-open). New `lib/impact-lens.py` is the SOLE owner
  of the impact→lens map (`annotate` / `classes` / `--self-test`) — an unmapped impact title is emitted verbatim
  with an empty lens column, never a guessed class. `gen-briefs.sh` gains `--pay-floor` / `--payable-impacts`
  and renders a deterministic `## Payable impacts` section plus a floor-derived in-scope severity bar;
  `run-zone-hunt.sh` gains `--pay-floor` / `--pay-mode` / `--payable-impacts`, threads them into STAGE 2, uses
  the lens map in STAGE 4.5 to PREFER the payable-impact lenses when `--deep-hunt-max-lenses` truncates the
  fan-out, and gates the findings into `verify/verified_findings.payable.json` before STAGE 5 — so a $0 finding
  never consumes an audit pass, a staged draft or a human review. `verify/verified_findings.json` is never
  overwritten (corpus-bench / dashboard readers keep the full verification record). Every flag defaults off and
  a flagless run is byte-identical: new `demo-finding-payability-gate.sh` + `demo-payable-impact-steering.sh`
  (both hooked into `colony-lint.sh`) and new sections in `demo-immunefi-live.sh` / `demo-run-zone-hunt.sh`
  assert the inertness explicitly. `bounty-payability-gate.sh` (#1897) is unchanged and stays the PROGRAM-level
  filter; dashboard rendering of the floor / `$0-unpayable` badge is out of scope (#1913).

- **MULTI-TARGET REFUTE-CORPUS COVERAGE GATE** (#1895). New `bench/corpus-bench/refute-corpus-coverage.sh` — an
  offline, network/LLM-free probe that GATEs the expensive #1887 refute derivation + held-out A/B on whether a
  constraint corpus can move a held-out target's rare recall at all. It computes the triple intersection
  `{∪ derivation classes} ∩ {held-out hunted classes} ∩ {held-out rare(1-2) GT classes}` from checked-in /
  archived data and prints `COVERAGE-GATE: GO` only when non-empty (else `NO-GO` + the named empty leg, non-zero
  exit) — the precheck the #1887 notional→yieldoor null would have failed. `--self-test` (three fixtures: a GO,
  the #1887 NO-GO repro, and a hunted-but-not-rare-GT NO-GO) is wired into `colony-lint.sh`. The multi-target
  corpus is built with no mechanism change (multiple `--in` into `refute-to-knowledge.sh`); `demo-refute-feedback.sh`
  gains a multi-`--in` merge assertion (summed `samples` on a shared `(class, sentence)`, distinct sentences
  separate, byte-stable modulo `created_ms`, order-independent), preserving the #1887 determinism invariant.
  Docs: `bug-class-coverage.md` (the coverage matrix + C2 transfer axis + C2/C20 granularity crux) and the
  corpus-bench README. The fresh derivation + held-out A/B are human-gated and NOT part of this change.

- **OFFLINE END-TO-END FUNNEL COMPOSITION + OPERATOR RUNBOOK** (#1902, epic #1894 M6). New
  `demo-funnel-e2e.sh` runs the assembled M1–M5 chain on synthetic fixtures and asserts the CROSS-STAGE
  handoffs (payability → audit-density re-rank → uniqueness GO → gated MOCK hunt → human-gated staging →
  outcome rollup) that no single-stage demo covers — offline, deterministic, `[SKIP]` without python3, hooked
  into `colony-lint.sh`. New `FUNNEL-RUNBOOK.md` documents the offline composition, the real operator run,
  target selection (fresh AND permissionless AND pays Medium/High AND KYC-at-payout), and the human-gate /
  never-submit / flat-cyborg / content-scrub invariants. The hunt in the demo is a MOCK (plumbing only — the
  real hunt is flat-cyborg-only via `hunt-flat-cyborg.sh`); the real Medium/High submission remains a human
  click and is NOT part of this change (M6 acceptance stays open until that real outcome is recorded).

- **SUBMISSION-OUTCOME MEASUREMENT VIEW** (#1901, epic #1894 M5). New `submission-outcomes.sh --summary` — a
  read-only, zero-egress aggregator over the drop-dir's `manifest.json` + `.outcome-ingested` /
  `.pending-confirmation` markers (never `OUTCOME.md`'s own `verdict:` override line, which is present only
  when hand-filled and is not the authoritative record). Emits one TSV row per submission
  (`submission_id`/`target`/`severity`/`outcome`/`payout`/`reason`) plus a rollup-counts line, matching the
  epic's KPI: how many real submissions, with what outcomes.

- **PRE-HUNT GATE + FLAT-CYBORG HUNT WIRED INTO THE BATCH RUNNER** (#1900, epic #1894 M4). `run-batch.sh`
  gains an optional `--pre-hunt-gate <cmd>` seam (default empty = today's behaviour, byte-identical):
  before a hunt is spent, the cmd receives the same `BATCH_KEY`/`BATCH_URL`/`BATCH_SCOPE` env `--hunt-cmd`
  already gets and must print a `TARGET-UNIQUENESS|<GO|FLAG|SKIP>|...` line (the M3 `target-uniqueness-gate.sh`
  contract); anything other than `GO` records `skipped-known` to the funnel ledger and spends no hunt. New
  `hunt-flat-cyborg.sh` — a thin `--hunt-cmd` wrapper that drives the `auditor` colony's one-shot
  `agentis go` under a hardcoded `llm.backend = flat-cyborg` config and translates its
  `Verdict: VERIFIED|SAFE|INCONCLUSIVE` terminal line into `VERDICT|confirmed|refuted|dry`. Never `claude -p`.

- **PRE-HUNT TARGET-LEVEL UNIQUENESS GATE** (#1899, epic #1894 M3). New `target-uniqueness-gate.sh` — before
  a hunt is spent, decide whether a TARGET is worth hunting given how known/audited its surface already is,
  and in the same pass PRODUCE the exclusion set the finding-level gate needs. Emits exactly ONE stdout line
  `TARGET-UNIQUENESS|<GO|FLAG|SKIP>|<density|-1>|<rationale>` (rationale pipe-free, all chatter on stderr)
  and exits `0 = GO`, `1 = FLAG`, `3 = SKIP`, `2 = bad args` — a non-zero exit is a VERDICT, not an error.
  It ALWAYS writes an exclusion file (`--exclusion-out`, default
  `<DIR>/uniqueness/<owner__name>/exclusion.txt`) in the exact free-text-per-line format
  `novelty-gate.sh --exclusion` already consumes — on every verdict, including SKIP and the no-signal path —
  so this gate is the PRODUCER and `novelty-gate.sh` stays the untouched CONSUMER. Three uniqueness legs,
  each degrading independently: (a) security-relevant issues + PRs and (c) security advisories in the target
  repo, both through a `--gh-cmd` seam (`UQ_ENDPOINT` in env, `gh api` by default); (b) prior audit reports
  via `fetch-audits.sh --manifest` or a pre-populated `--audits-dir` — never assuming auth-gated
  Sherlock/Cantina/C4 judge reports are reachable; plus the `audit-history-probe.sh` density signal through
  a `--probe-cmd` seam (`-1` = unknown, never to be read as 0). The verdict errs toward FLAG: missing
  signals push to FLAG and a **GO is structurally impossible without at least two independent sources of
  real data**, so no-data can never yield a silent GO. A candidate signature with no function/CamelCase
  identifier and no vuln-class term is DROPPED, keeping the downstream consumer from false-KNOWN.
  `novelty-gate.sh`, `fetch-audits.sh` and `audit-history-probe.sh` are reused VERBATIM and untouched;
  `demo-target-uniqueness-gate.sh` proves the whole contract offline (including the end-to-end
  gate -> exclusion file -> `novelty-gate.sh` KNOWN/NOVEL handshake) with no network and no `gh` auth.

- **FRESHNESS-FIRST DE-RANK BY TARGET AUDIT-DENSITY** (#1898, epic #1894 M2). New `apply-audit-density.sh`
  — a queue -> queue RE-RANK (never a gate; every input row survives, only the order changes): for each row
  whose `scope_hint` carries a resolvable `repo:` token, it runs `audit-history-probe.sh` (reused VERBATIM,
  via a `--probe-cmd` seam mirroring `run-batch.sh`'s `--hunt-cmd`) and subtracts a flat bounded penalty
  (`--penalty`, default 20, floored at 0) from the row's score when the probe verdict is
  `heavily_audited=true`, then re-sorts DESC-then-key-ASC — the same tie-break `run-immunefi-intake.sh`
  already uses. A missing/unreachable repo or no repo signal at all leaves the score untouched (fail-safe:
  no signal, no de-rank). Standalone tool; `run-immunefi-intake.sh`/`run-batch.sh` are untouched — chained
  manually by the operator.

- **PER-SEVERITY PAYABILITY FILTER** (#1897, epic #1894 M1). New `bounty-payability-gate.sh` — a queue
  -> queue gate dropping rows whose Medium/High reward is a confirmed $0 (`--pay-floor`, default $1000),
  so a program that pays $1M Critical but nothing Medium/High never reaches a hunt. Source of truth, in
  order: the feed's `rewardsBody` (already fetched by `run-immunefi-intake.sh`, no new network for the
  common case), a per-program-page `__NEXT_DATA__` JSON-island fallback (`--page`), then an operator
  `--table` paste hatch. Unresolved rows (no source matched) are kept unchanged — fail-open, never a
  false drop. Re-emits the SAME 5-col TSV `run-batch.sh` consumes, unchanged for every surviving row.

- **REFUTER -> HUNTER CONSTRAINT CHANNEL** (#1887, mechanism only — default OFF everywhere). The refute gate
  is where most candidates die and its reason died with them. `refuter.ag` now emits, on a REFUTED verdict
  only and IMMEDIATELY BEFORE the verdict line, one target-independent `CONSTRAINT|<class>|<sentence>` naming
  the GENERALISABLE standard the claim failed. That ordering is load-bearing: after the verdict,
  `run-refute.sh::_join_wrapped_verdict` would swallow the line into the reason and shift
  `verify-findings.sh`'s `awk -F'|'` field read. `refute-report.md`'s row shape and
  `verified_findings.json`'s schema are UNCHANGED — the channel adds files, never keys.
  - `run-refute.sh` harvests `<out>/refute-constraints.tsv` (`<class>\t<file:fn>\t<constraint>`, PTY-wrap
    rejoined); a REAL verdict and a candidate the #1699 C6 fallback RECOVERS harvest nothing.
  - `verify-findings.sh` concatenates the per-gate files into one `<out>/refute-constraints.tsv` in numeric
    GATE order — byte-identical under `--jobs 1` and `--jobs > 1`.
  - NEW `refute-to-knowledge.sh` (modelled on `bench/corpus-bench/bench-to-knowledge.sh`) turns those rows
    into `refute-constraint` `KnowledgeEntry` entries (deduped by `(class, sentence)`, `--replace` mandatory,
    empty input => valid `[]` at exit 0), with an opt-in accumulating `--store` merge for production hunts.
  - `run-discovery.sh` writes `knowledge.enabled = true` and, when `REFUTE_CONSTRAINTS_JSON` is set and
    readable, imports that corpus ONCE before the cell loop; `hunter.ag` reads it back with
    `query_knowledge("refute-constraint", 32)`, filters to the cell's class, sorts + caps at 6 bullets and
    prepends a block carrying an explicit anti-Goodhart clause. Unset => the prompt is BYTE-IDENTICAL.
  - The store scope is the #1866 decision, recorded in `docs/SUBSTRATE-PRIMITIVES.md`: a **frozen,
    read-only** corpus imported once, never written by an agent, no `distill()` anywhere — which is what
    keeps `--jobs N` byte-equal to serial. `distill()` was rejected on a measured reason (it needs >= 3
    successful same-action experience records; a refute gate is single-shot against a wiped store, and the
    resulting runtime error would discard the cell's stdout — the #1877 false zero).
  - Tests: NEW `demo-refute-feedback.sh` (emit -> scrape -> feed -> import -> a REAL hunter cell's PROMPT,
    ON vs OFF), `demo-discovery-parallel.sh` block 19 (inertness, the config line, `--jobs 3 == serial` WITH
    a corpus, sentinel-as-record-boundary, measured CB), `demo-verify-findings.sh` block 9 (gate-ordered
    aggregate, `verified_findings.json` byte-unchanged), `demo-experience-flags.sh` layer 1c + the live
    hunter cell (a dropped `knowledge.enabled` fails at output level). Measurement (derivation on one
    target, held-out A/B on another) is deliberately NOT in this change.
- **REFUTER -> HUNTER TRANSFER — HELD-OUT MEASUREMENT** (#1887). The measurement half of the channel above:
  a corpus derived on `notional` (27 rows, frozen `8e5476c`) measured on held-out `yieldoor`, control (no
  corpus) vs treatment (`REFUTE_CONSTRAINTS_JSON`) under an identical ruler (`--zone-depth-cells 4
  --total-depth-cells 36`, semantic judge min-conf 60, `--backend flat-cyborg`). Primary **rare(1-2) recall
  flat 1/8 -> 1/8 (Δ=0)**; the Goodhart gate did not trigger (confirm rate 64.3% -> 63.2%). The result is
  **class-mismatch-bounded, not a transfer verdict**: the notional-derived corpus classes
  (C15/C21/C23/C2/C22) do not cover yieldoor's rare-bug classes (C19 uint16-overflow, C20 tick-centering),
  and injection is class-filtered, so the treatment had no reachable rare-bug surface — a structurally-bounded
  null. Default stays OFF, the corpus stays checked in. Scrubbed archives of both arms:
  `bench/corpus-bench/runs/1887-yieldoor-refute-transfer/` (+ the derivation archive
  `1887-notional-constraints/`); `bench/corpus-bench/bug-class-coverage.md` gains the measurement section. The
  transfer lever moves to a multi-target / class-broad corpus so a held-out target's money classes are
  covered (#1895).
- **ZONE-COUNT-AWARE TOTAL DEPTH BUDGET** (#1880). `--zone-depth-cells` is a PER-ZONE maximum, so a sweep
  admits `depth x zone count` depth cells: the #1872 Stage C `notional` run (9 zones at `--zone-depth-cells
  12`) admitted up to 108 depth cells and projected ~18-24 h, with nothing in the pipeline naming the product.
  - `run-zone-hunt.sh --total-depth-cells <N>` (default **0 = OFF = byte-identical**) is a new, separate
    ceiling over the WHOLE STAGE 3 sweep: with depth on, the per-zone allowance becomes
    `min(--zone-depth-cells, N / zone count)` (integer division, remainder deliberately unspent so every zone
    of one contest is hunted on the same ruler). It requires `--zone-depth-cells > 0` (exit 2), and it is PER
    INVOCATION — a `--rehunt-gaps` pass gets its own, computed over the gap set.
  - **`--zone-depth-cells` semantics did NOT change**, and no other default moved: every earlier arm
    (#1858/#1860/#1879, the #1831 baseline) is re-derived exactly with `--total-depth-cells 0`.
  - `bench/corpus-bench/run-corpus-bench.sh` carries the one opinionated default, `--total-depth-cells 36`,
    forwarded ONLY when depth is on. 36 is the record's number: #1879 named `--zone-depth-cells 4` on that
    same 9-zone contest as the tractable config = 36 cells, so the bound admits the configuration already
    judged tractable and leaves 2-3-zone contests at depth 12 unchanged. The bench also gained pure
    pass-throughs for the two #1830 breadth-side caps (`--zone-cell-budget` / `--run-cell-budget`, both
    default 0 = OFF).
  - Visibility, so a silently different arm cannot happen: a one-line stderr banner when the ceiling bites, a
    bench line stating the bound on every depth-on hunt, distinct coverage `detail` strings for the two causes
    of "depth 0" (sweep ceiling vs. cell-budget headroom), and the durable `budget.depth_total` /
    `budget.depth_per_zone` in `zone-coverage.json` (`zone-coverage.py budget`, emitted only when the ceiling
    is on) — the effective per-zone depth is what a recall number must be quoted against, never the flag.
  - Guards: `demo-run-zone-hunt.sh` block (v) (scaling, a ceiling below the zone count, the depth-off record
    identity, flag validation) plus a STATIC `tools/colony-lint.sh` pin on the bench default.
- **EXTERNAL-ASSUMPTION HUNT LENS — bug classes `C22` + `C23`** (#1872, STAGE A / authoring only). The
  corpus-bench `notional` contest exposed a bug shape the taxonomy had no lens for: the target's own code is
  internally consistent, and the bug is an ASSUMPTION it makes about a SECOND protocol. Seven ground-truth
  rows carried it and the hunt scored 0 on all of them. They split by the ENUMERATION the hunter has to
  perform, so this ships two narrow classes rather than one catch-all "external-protocol assumption" class
  (whose hunt would collapse to "enumerate the assumptions" — it names no artefact and fires on every zone
  that imports anything).
  - **`C22` — Cross-protocol asset / unit equivalence**: two DIFFERENT externally-issued asset
    representations (a Pendle `SY`/`PT`/`YT` triple, native ETH vs WETH, an external LP/receipt token vs its
    underlying, a token amount vs a USD amount) treated as interchangeable at a hardcoded 1:1 rate where the
    ISSUER only guarantees a live rate. Enumerates token addresses, imported interfaces and the exact points
    where two amounts meet in ONE arithmetic step or comparison.
  - **`C23` — Hardcoded external-integration parameter**: a literal / `constant` / `immutable` argument to an
    external call (a `useEth`-style bool, a `dexId`/pool-type/coin-index enum, a hardcoded pool/router/token
    address, a magic amount) that is correct for exactly ONE external configuration on a code path that can
    reach another. Enumerates, per external call, the SET of configurations in which the constant holds.
  - Both classes carry two MANDATORY guard fields beyond the usual `hits/hunt/breaks/sev/seen`: a
    `NOT this class` disambiguation against the neighbouring lenses (C2/C9/C1 for C22; C5/C12/C15 for C23)
    and a three-part `required evidence (else report SAFE)` contract — the exact line, the external
    protocol's documented contradicting behaviour, and a reachable state where it bites. Missing any of the
    three is not a candidate.
  - **`C2` amended, not forked**: the one oracle-domain-of-validity row (a derived-asset price adapter
    written against one market shape) is a hunt bullet inside the existing oracle-integrity class plus a
    `seen:` entry, so it costs no extra cell on any zone the C2 lens already covers.
  - `zone-mapper.ag` gains two PROMPT-ONLY detection rules in the C15/C6/C17/C5 house style, each an
    `INCLUDE ... ONLY WHEN ...` sentence with an explicit `do NOT add` negative clause. **No deterministic
    `apply_*_backstop`/force-include is added and the `pick the 1-4` per-zone class cap is untouched** —
    that is the cell-budget guard (#1830) and a deliberate decision, not an omission: a menu entry DISPLACES
    a class inside the cap, a force-include would ADD a cell to every matching zone unconditionally. Both
    facts are pinned by the new test.
  - `demo-external-assumption-lens.sh` (new, pure awk/grep, no network/LLM/agentis; wired into
    `colony-lint.sh`) is the regression contract for the two things that can silently rot — the class text
    losing its anti-catch-all guards, and someone later adding the force-include. It also replays
    `hunter.ag::class_section()`'s own `## <cls> ` awk anchor against the real taxonomy for `C2`/`C22`/`C23`,
    pinning the `## C2 ` vs `## C22 ` prefix collision that is the one way this change could break an
    already-working lens.
  - **Transfer status, stated honestly.** `C22` has a held-out transfer target named for a later stage;
    **`C23` is `transfer-pending`** — it ships with three `notional` rows and NO held-out instance in this
    corpus, so it must not be read as transfer-validated on the back of `C22`'s result. Finding `C23` a
    held-out instance in another contest is follow-up work. Both classes are so far validated only by the
    authoring probe on the target they were derived from; the held-out transfer measurement and the
    full-pipeline recall/cell-cost numbers are separate, later stages, and no `VERSION` bump or class-coverage
    retag happens here.
  - **Stage C measured (partial, 2026-08-10, #1879).** The full `--live` corpus-bench run (frozen at this
    commit, `--zone-depth-cells 12 --judge cmd --judge-min-confidence 60`, #1831 arm) was stopped at
    `notional` 4/9 zones after ~11h (a ~18–24h projected full run). On the two fully-hunted contests, judged:
    `crestal` (the CONTROL) rare recall **2/3 = its 2/3 baseline — no regression**, and **zero `C22`/`C23`
    candidates or verified leads there (no catch-all)**; `plaza` rare `0/5` vs a `1/5` baseline, but the lens
    fired **0** candidates on it, so that drop is hunt variance, not lens-caused. On `notional` the zone-mapper
    assigned `C22`/`C23` to **6 of 9 zones** — the Pendle/Curve/Ethena integration zones where the ground-truth
    rows live — and `C23` produced candidates at real GT locations (`PendlePTOracle._getPTRate`,
    `Curve2TokenOracle._lpTokenValue`); the dispatch-gap risk did NOT materialise. **Not yet shown:** a
    judge-confirmed rare-row CATCH by either class (`notional` was not scored). So the lens lands **proven
    clean and discriminative, recall payoff unproven** — the `notional` judged recall + the class-coverage
    retag are the follow-up (#1879).

### Changed
- **The six remaining hunt/submission-path scripts' experience flags are PROVEN load-bearing at output level**
  (#1878, closing out the #1866/#1877/#1881 arc). `screen-leads.sh`, `gen-briefs.sh`, `run-symbolic.sh`,
  `run-poc.sh`, `run-audit-pass.sh` and `auditor/scripts/run-gate-agent.sh` carried comments claiming the flags
  were bookkeeping ("fitness reweights over targets") or carried no comment at all — which is how #1877
  re-derived the wrong "structurally inert" conclusion. Measured on agentis **v1.28.0**: the flag gates the
  `learn()` **WRITE** (not a read, as #1881 assumed) — `learn()` raises `runtime error: experience not enabled`
  and **any** runtime error makes agentis DISCARD the program's whole accumulated stdout, so a cell that
  already printed its verdict line emits nothing. Mutation-proven per script: flipping `experience.enabled`
  off makes `screen-leads` report `0 reproduced / 0 held / 3 indeterminate` (every row `(no verdict)`),
  `run-symbolic` and `run-poc` lose their `SYMBOLIC|` / `POC|` lines, `gen-briefs` lose the
  `DARK-FACTORY:BRIEF-BEGIN|` block, `run-audit-pass` emit an EMPTY `pass-result.txt` instead of
  `PENDING-HUMAN-REVIEW`, and `run-gate-agent` print NOTHING (which the coordinator reads as `incomplete`).
  All comments corrected to the measured mechanism (including the superseded "READS experience intra-run"
  wording in `run-discovery.sh` / `run-refute.sh` / README and in the #1881 entry below); **no flag changed**.
  `demo-experience-flags.sh` grew from 2 to **8** source-guarded scripts + **8** live cells, each with a
  POSITIVE CONTROL (the `"action":"<name>"` experience row, or the probe verdict line for the store-less gate
  runner) so a cell cannot pass vacuously, an order-independence accrual probe on `screen-leads`, and a new
  ratchet: no `dark-factory` script may emit `experience.enabled = false` / `learning.enabled = false` without
  an explicit `# experience-flags: intentional-off (<reason>)` annotation.

### Fixed
- **`experience.enabled` / `learning.enabled` regression on the hunt + refute paths** (#1881, from #1866/#1877).
  #1877 flipped both flags to `false` on `run-discovery.sh` (STAGE 3 hunter) and `run-refute.sh` (STAGE 4 refute
  gate) as "structurally inert" — but the hunter AND the refuter READ experience *within* a run, so agentis
  hard-errors `experience not enabled`, FAILING every hunt cell and ERRORING every refute gate. The whole
  discover→verify pipeline returned a silent **false zero** (0 candidates / 0 verified) regardless of the target,
  and the stub-`agentis` demos never caught it (they never interpret the `.ag`). Restored both to `true`,
  corrected the "proven inert" comments, and added `demo-experience-flags.sh` (wired into `colony-lint`): a
  source-guard on both scripts plus, when `agentis` is present, a real hunter + refuter cell run through
  `--backend mock` asserting neither hits the runtime error — the output-level mutation guard the change lacked.

## [0.6.0] - 2026-08-01

### Added
- **STAGE 4 GATE FAN-OUT** (#1863). `verify-findings.sh` gains an opt-in `--jobs <N>` (default `1`) bounded-
  concurrency fan-out over the CANDIDATE gates, and `run-zone-hunt.sh` forwards its own `--jobs` to it. The
  refute gate was the pipeline's serial TAIL: ~4 min per gate, one gate per merged candidate, run to
  completion AFTER the parallelised hunt — on a large target that tail cost more than the hunt it followed,
  and it gets worse with every recall improvement that raises candidate yield.
  - Effective concurrency is HARD-CAPPED at `min(--jobs, LLM_MAX_VERIFY_GATES)` (default `4`) by a
    self-contained `wait -n` job-slot that **never fails open**; a `--jobs` over the cap is clamped with a
    stderr warning. The env knob is deliberately separate from `run-discovery.sh`'s `LLM_MAX_DISCOVERY_CELLS`
    — STAGE 3 and STAGE 4 are sequential stages, so one forwarded `--jobs` can never stack the two ceilings,
    and they tune independently (lower it for `--gate poc`/`--gate symbolic`, where a slot also copies the
    target repo and runs a build). `bash < 4.3` (no `wait -n`) degrades to serial with a notice.
  - **No cross-candidate refuter reweighting on EITHER path — no behaviour change.** `run-refute.sh` sets
    `learning.enabled` / `experience.enabled`, but `verify-findings.sh` invokes it ONCE PER CANDIDATE with a
    distinct `--out`, which it `rm -rf`s + `agentis init`s per invocation, over a `candidate.manifest` that
    carries exactly ONE data line. The store is therefore created fresh for one candidate and never read
    again: there was no cross-candidate reweighting to lose, and a verdict never depended on manifest
    position. `--jobs > 1` is a scheduling change, not a quality change. The rejected alternative — funnelling
    the gates through one shared refuter store — would have CREATED that reweighting for the first time, an
    unmeasured quality change under a throughput ticket, and made verdicts position-dependent.
  - Aggregation is DEFERRED until the pool drains and replayed in MANIFEST order, with the #1691 preflight
    ERROR rows carried rather than emitted inline, so `verified[]`, `errors[]` (both ERROR kinds interleaved)
    and `totals` are byte-identical to the serial run. `verified_findings.json`'s shape is unchanged — in
    particular NO `jobs` key (that would break `score-match.py` / corpus-bench); concurrency provenance goes
    to stderr only. `run-refute.sh`'s #1699 C6 retry stays a sequential step inside its candidate's single
    slot, so peak agentis concurrency is `effective_jobs`, never double.
  - `--jobs 1` (the default, everywhere including inside `run-zone-hunt.sh`) runs today's exact serial
    statement sequence and writes no new artifact. New `demo-verify-parallel.sh` pins it offline through the
    `--agentis` stub seam against a golden minted from the PRE-#1863 script: serial == golden, `cmp`
    byte-identity between `--jobs 1` and `--jobs 3`, concurrency observed + the cap never exceeded (incl. the
    clamp), C6 slot discipline, per-candidate store isolation on both paths, both degrade shapes (a
    hard-failing gate and a vanished `gate.rc` are SKIPPED — visibly unassessed, never confirmed), the arg
    guard and never-submit. `demo-run-zone-hunt.sh` adds the two forwarding pins.

### Fixed
- **THE HUNTER IS NOW TOLD ITS CONTRACT IS ABSTRACT** (#1865). #1861 got the derived implementor's BYTES into
  the hunter's payload (`lib/inheritance.py` → `map-zones.sh` → `scope.tsv` → `IN_SCOPE`), but not the
  FRAMING: the slice arrived as just another `// ========== <path> ==========` section, so the hunter was
  never told that its primary contract is ABSTRACT nor that the extra section implements it — while the
  refute gate had carried exactly that label + judging rule since #1861. There was also no hunt-side twin of
  the gate's `AUX-CONTEXT|` line and `aux.txt`, so an appendix-influenced candidate was not attributable from
  the artifacts alone. This closes both gaps and nothing else — it does NOT re-implement zone composition
  (that shipped in #1861/#1862) and it ships no measurement.
  - The hunter cannot self-detect the condition: `map-zones.sh` emits the same `path@fn1+fn2` shape for any
    zone file above the LOC threshold, so the appendix token is byte-indistinguishable from an ordinary
    slice. The fact is therefore written down where it is known — a new `<out>/appendix.tsv` sidecar
    (`<subsystem>\t<token>\t<abstract base>`), one row per zone that ACTUALLY attached a token, written only
    when at least one row exists. A target with no cross-zone abstract base emits the pre-#1865 file set, and
    `run-zone-hunt.sh` then passes no new flag at all (byte-identical STAGE 3 argv).
  - `run-discovery.sh --appendix <file>` resolves the row per manifest line and env-ins `APPENDIX_FILE` /
    `APPENDIX_BASE` (both registered on `exec.env_passthrough` — an unregistered knob is silently inert, the
    #1426/#1428 failure mode). A row is honoured only when its token literally appears in that line's file
    list, which keeps the sidecar safe under the subsystem-name ambiguity `scope.tsv` already has. Depth
    cells always get an EMPTY pair: a depth payload IS the narrowed function, so framing it as "your contract
    is abstract" would be a lie about that payload.
  - `hunter.ag` gains `appendix_header` / `appendix_label` / `appendix_rule`, each returning `""` on an empty
    token, so an appendix-free zone's payload and instruction stay byte-for-byte what they were. The label is
    folded into the EXISTING `scoped_code` reduce (one `len` + one compare per token — no new reduce, no
    per-element `exec`), and the rule adds the resolved-behaviour clause plus an ANCHORING clause: the derived
    slice is context for the base, not a second hunting ground, so the `CANDIDATE` location belongs on the
    abstract contract's own function unless the flaw is in the override's own body.
  - Attributability at parity with the gate: the hunter prints `APPENDIX-CONTEXT|<token>` before the model
    call (a record BOUNDARY for `_join_wrapped_candidates`, exactly like `DEPTH-CELL|`), `run-discovery.sh`
    logs one stderr line and derives a per-cell `appendix` key FROM THAT LOG LINE, appended after every
    pre-existing key so `_plan_depth_cells`'s forward key scan is untouched. The sentinel is gated on the
    framing having been ASSEMBLED INTO THE PROMPT (`framing_emitted()`: the labelled header in the payload
    AND the judging block in the instruction, matched through the same marker helpers the producers use),
    not on the token being non-empty — otherwise the artifact added to make appendix influence attributable
    would keep reporting "framed" after a regression that dropped the framing, and could not detect its own
    loss. Both no-op regressions now produce no sentinel, no stderr row and no `appendix` key.
  - Cost, MEASURED rather than assumed: `appendix_label` folds into the existing reduce (O(1) per token, no
    new reduce, no per-element `exec`), but the constant is roughly the whole pre-existing per-element cost
    of that reduce — under a `cb 2000;` stress probe the pre-#1865 fold clears 107 tokens and this one 55,
    and every cell pays it, appendix-free zones included. Not a runtime risk at the budget that actually
    runs: `agentis go` honours `hunter.ag`'s declared `cb 300000;`, where the fold is bounded by the 16 MiB
    string heap (~378 tokens) rather than by CB, against the ~10 files a real zone carries.
  - The known residual is stated rather than papered over: a candidate CAN be located in the appendix file,
    i.e. in a file another zone owns. Nothing downstream branches on it (coverage is derived per zone from
    that zone's own totals, dedup keys on `(subsystem, class, files)`), the cost is one extra gate call and a
    `verified[].subsystem` that can name a zone not owning `verified[].file`. A mechanical drop of
    out-of-zone candidates is deliberately NOT added — it would discard exactly the "the bug is in the
    override" finding the appendix exists to surface.
  - Tests: `demo-map-zones.sh` A9 (sidecar content + absence, on the existing #1861 fixture, incl. the
    in-zone-implementor / descendant-less / ambiguous-name negative controls and the no-helper control tree)
    and `demo-discovery-parallel.sh` 18a-18g (default inertness, stub-observed env wiring, the
    `exec.env_passthrough` allowlist, the sidecar self-check, the log-derived cell key + wrap safety, the
    depth interaction, the CB probes above, and — 18h — a LIVE assertion in which a real `agentis`
    interprets the real `hunter.ag` against a fake `claude` that dumps the prompt: both halves of the
    framing must reach the model for the framed zone and neither for an appendix-free one. That is the one
    assertion that can see the two no-op regressions; the stub-driven and fragment-extracted ones cannot.
- **ZONE SPLITTING NO LONGER SEVERS INHERITANCE** (#1861). `map-zones.sh` groups by DIRECTORY, so on a
  codebase organised around abstract base contracts the base lands in one zone and every implementation in
  others — and BOTH readers then reason about the base in isolation. Measured on the diagnosing target: the
  refute gate confirmed **1 of 22** candidates on its abstract-base zone against **14 of 22** on a
  concrete-contract zone of the same target in the same run, 9 of the refutations in the refuter's own
  *"…in this contract contains no…"* words.
  - New `lib/inheritance.py` is the single source of truth for "which contract actually implements this
    abstract base": a regex + logical-declaration index (no solc, no toolchain — this path must run offline
    on CI with python3 only) that ranks every transitive descendant by `(# of the base's body-less virtual
    members it declares WITH a body) DESC, (hops) ASC, (LOC) ASC, (path) ASC` and takes exactly ONE. It
    deliberately does NOT prefer concrete contracts: on the diagnosing base every concrete leaf resolves at
    most 2 of 5 body-less virtuals while the 1-hop intermediate abstract subclass resolves 5 of 5.
  - **Both** reads are fixed, because fixing one is a non-fix: `map-zones.sh` appends ONE function-sliced
    representative implementor to the `scope_files` of a triggering zone (the hunter's payload), and
    `verify-findings.sh` attaches the same slice to the refute gate as an OPTIONAL 6th manifest column
    (`run-refute.sh` stages it and env-ins `AUX_CODE_PATH`; `refuter.ag` appends it to the payload and gains
    exactly one judging rule). The gate fires per CANDIDATE FILE, so it also repairs zones whose implementor
    was in-zone all along — the refuter never saw the zone payload.
  - Bounded and inert by construction: at most one extra file per zone and per candidate, always
    function-sliced (never a whole file) and capped by the existing `FN_SLICE_CAP = 16`; `files`, `loc`,
    `hardening_score` and zone ids are untouched, so the #1830 coverage record, brief filenames, `--only` and
    STAGE 4.5 deep-hunt selection are byte-identical. Cells are emitted per (manifest line x class), so the
    appendix costs **bytes, never cells**. A target with no abstract base produces a byte-identical payload
    and argv (golden-pinned).
  - Every named Solidity-parsing failure mode is made INERT rather than wrong — an out-of-scan base ends the
    chain, `interface`/`library` never trigger, a contract name declared in two scanned files is ambiguous and
    contributes no edge, cycles are broken by a visited set, and C3 linearization is explicitly not modelled.
    When nothing resolves, the condition is still RECORDED (`abstract_base: true`,
    `implementation_appendix[].implementor: null`) so a low confirmation rate is attributable from the
    artifact instead of inferred from refutation prose.
  - The appendix informs the judgement, it does not rubber-stamp it: the conservative "uncertainty kills it"
    tie-break is untouched and an aux-carrying candidate the skeptic refutes is still dropped.
- **The recorded refutation reason is no longer truncated mid-sentence** (#1861, secondary). flat-cyborg's PTY
  capture wraps a long `VERDICT|` line, and `grep 'VERDICT|' | tail -1` kept only the first physical line — so
  `verdict.txt` and `refute-report.md` showed an operator half a sentence. `run-refute.sh` rejoins the wrapped
  record with `_join_wrapped_verdict()`, modelled on `run-discovery.sh`'s `_join_wrapped_candidates()` (the
  #1705 fix for the same defect on the hunter side), and normalises the reason: whitespace squeezed and any
  literal `|` mapped to `/`, since a raw pipe both breaks the four-cell markdown row AND re-truncates the
  reason at `verify-findings.sh`'s `awk -F'|' … $5` read.

### Added
- **DEPTH-ONLY RE-ENTRY — a depth A/B that is actually readable** (#1857). Every depth measurement so far
  re-hunted the **stochastic** breadth pass in both arms, so a row the treatment lost could not be
  attributed to the allocation rather than to breadth variance — which is precisely why #1850's four lost
  rows settled nothing and the `--depth-lens-quota` default reverted to `1`.
  - `run-discovery.sh --depth-from <discovery-results.json>` consumes a **recorded** run, seeds the cell
    accumulator with its **breadth** cells and falls into the unmodified #1827 depth block:
    `_plan_depth_cells()` / `run_cell()` / `scrape_cell_log()` are reused verbatim, so the plan a re-entry
    computes IS the plan the original run computed (pinned against both recorded plaza arms' own
    `depth-plan.tsv`). Two arms differing only in the quota then share ONE breadth sample.
  - The input is the sibling `discovery-results.json`, never the raw `run/results-cells.jsonl` — the JSONL
    carries no provenance, so none of the refusals would be possible. Carried cells land in `cells[]`
    byte-for-byte, so a depth-only arm is a drop-in for `verify-findings.sh` → `score-match.py`.
  - **The depth filter is correctness, not hygiene**: replaying an artifact unfiltered feeds depth
    candidates back into the ranking and computes a different plan (extra `C17`/`C5` lenses,
    `startAuction` promoted above `transferReserveToAuction`).
  - Refusals: exit **2** for an argv that cannot be honoured (`--list-cells` / `--only` / `--classes` /
    `--scope`, a missing file, `--depth-max-cells 0`), exit **3** when the artifact does not match this
    target (recorded `repo` or `commit` mismatch, a depth target the checkout no longer carries, an input
    with no breadth cell). Every artifact-only refusal fires before the output dir exists.
  - `discovery-results.json` now records `commit` on **every** run (a soft git dependency that degrades to
    `"unknown"`), so a stale checkout is refused from here on. It buys nothing for artifacts recorded
    earlier: those print `re-entry provenance is UNVERIFIED` and run, and re-entering against the checkout
    that produced the input stays the **operator's** responsibility. The banner claims no check it does not
    make. `depth_from` (source, repo, commit, carried counts) is emitted only under the flag.
  - `demo-depth-reentry.sh` — 13 offline assertions over checked-in recordings of two real plaza arms
    (`bench/corpus-bench/fixtures/depth-reentry/`, deliberately outside the bundled `fixtures/` tree), each
    mutation-tested; wired into `colony-lint.sh`. Default-inertness is pinned down to the byte-identical
    golden report and an absent `depth_from` key.

- **SELF-TUNING BREADTH — the coordinator closes its own coverage gaps** (#1828, M1–M3).
  #1830 made a truncated zone-hunt *visible* (`coverage/zone-coverage.json`, the nine-state vocabulary,
  `gaps` / `--rehunt-gaps`) but decided nothing: closing a gap was still an operator step. This adds the
  decision and the loop as a **new layer above** the capstone — **`run-zone-hunt.sh` is not modified at all**,
  which is the strongest available form of default-inertness (an untouched file cannot regress its golden
  pin) and keeps the M1..M5 orchestration tactical.
  - `lib/gap-policy.py` — the rule. `decide` maps a coverage record + the pass history to exactly one of
    `rehunt_now` / `raise_budget_and_rehunt` / `remap_target` / `give_up`; `ledger init|append|finish`
    maintains the `gap-remediation/v1` account (per pass: `gaps_before`/`gaps_after` and a `closed` set
    **derived** from them, never asserted by the caller); `report` renders the honest end-of-sweep markdown.
    It never re-derives #1830's classification — it shells out to `lib/zone-coverage.py` — and it reads
    actionability from the `gaps` TSV only, never from the strictly larger `gap_zones` list.
  - `run-zone-sweep.sh` — the driver: breadth pass → `decide` → `--rehunt-gaps` → repeat, with no operator
    step anywhere in the loop. `--max-rehunt-passes` (default 2), `--rehunt-max-attempts` (2),
    `--rehunt-include-partial`, `--budget-ceiling` (**0 = a raise is never permitted**); everything after
    `--` is forwarded verbatim, and the flags the sweep owns are rejected in the passthrough (exit 2).
    Exit 0 only when coverage is complete, exit 5 when gaps remain — and `coverage/gap-remediation.json` +
    `coverage/gap-report.md` are written on **every** exit path including the aborts.
  - **The bound cannot come from the record.** `attempts[]` is appended only by `zone-coverage.py retry`,
    which the runner calls only for artifact-bearing statuses, so a zone denied on admission
    (`budget_exhausted` / `budget_unenforceable`) never becomes `capped` at any `--max-attempts`. Three
    independent bounds replace it: the sweep's own pass ceiling, a no-progress guard (a plain re-hunt that
    closed nothing escalates or stops), and the budget branch (a raise goes straight to the authorized
    ceiling, so at most one per sweep). Measured: with all three removed the unenforceable-cap fixture
    launched 129 re-hunt passes in 90 s and was still going.
  - `remap_target` is a **reported** decision, never an action — the sweep never re-runs STAGE 1/2 by itself,
    because a re-map invalidates the briefs and the record the policy is reasoning over. Policy *learning*
    (M4) is explicitly out of scope: the verb set is fixed and the rule is deterministic.
  - New `demo-gap-policy.sh` (30 assertions: the classification contract, the gaps-vs-`gap_zones` superset
    relation, the never-`capped` finding at `--max-attempts` 1/2/3/99, every branch of the rule) and
    `demo-run-zone-sweep.sh` (29 assertions: autonomy, byte-identical inertness against a direct
    `run-zone-hunt.sh` pass, all three bounds, `remap_target`, the attempt ceiling, flag validation, abort
    honesty), both wired into `tools/colony-lint.sh`; new `fixtures/coverage/` records; contract written up
    in `docs/zone-split-orchestration.md` with operator recipes in `docs/RUNBOOK.md`.
- **GT-EQUIVALENCE CREDITING for the corpus bench — opt-in, default OFF** (#1840).
  A concluded judging repo routinely accepts **two rows for the same underlying bug**, described differently
  and found by very different watson counts. The mechanism judge (#1829) is asked for at most one MATCH per
  candidate and only ever sees one `--judge-batch` slice of the rows per call, so a lead that finds such a bug
  credits whichever twin the model named — and because the headline is stratified by rarity, the **rare twin
  is the one silently lost**: the pipeline finds a rare bug and is scored as if it had not. Equivalence is a
  property of the ground truth, not of the matcher, so it is now decided GT-side and stored per contest: new
  `gt-dupes.sh` judges every truth row against the rows after it (upper triangle, batched) through the
  **unchanged** `mech-judge.sh` driver/grammar/decision rule and writes `gt-dupes.tsv` next to `truth.tsv`
  (`DUP<TAB><sev_a><TAB><sev_b><TAB><confidence><TAB><reason>` plus a `source=judge|manual` provenance
  header); `score-match.py --gt-dupes <file>` unions the pairs into classes and credits every member of a
  class one of whose rows was matched. The precision contract is narrow by design: **denominators never move**
  (`gt_total` and every stratum stay one entry per accepted row), expansion touches `row_hit` **only** (so
  `matched_leads`, `unmatched_leads` and the `--per-lead` lines are unchanged and one lead can never become N
  matched leads), and new `DUP` / `DUPHIT` trailers make `hits - expanded_hits` recover the pre-#1840 number
  from the **same** replay. Guard rails against a wrong merge inflating exactly the stratum this protects: a
  merge bar of 85 by default (`--gt-dupes-min-confidence`, deliberately above the 70-point scoring gate) that
  is applied at **scoring** time so one archived artifact re-derives both numbers and anything in between, a
  fail-closed `--gt-dupes-max-class` cap (default 3), a mandatory per-pair reason, and a hard exit 3 when a
  pair names a `sev_id` absent from `truth.tsv` (a stale or wrong-contest artifact never silently
  mis-credits). `run-corpus-bench.sh` gains a `--dupes` stage (operator-only, like `--hunt`, and deliberately
  **not** folded into `--live`), `--gt-dupes` / `--gt-dupes-min-confidence` / `--no-gt-dupes`, per-contest
  `rare <h>/<t> (<n> via GT-equivalence)` reporting and a `"dup"` JSON block; `generation-recall.sh` forwards
  the flags so both halves of the generation-minus-verified DELTA use one ruler. Without `--gt-dupes` no
  trailer is emitted and every existing scorecard stays byte-identical. `demo-mech-judge.sh` pins the defect
  and the fix byte-exactly on a second synthetic fixture (`fixtures/gt-dupes/`, kept separate from
  `fixtures/mech-judge/` so the frozen #1829 cache keys cannot be re-baselined): 2/4 rare 0/2 -> 3/4 rare 1/2,
  plus the negative control, the untouched `LEADS` trailer, the stale-artifact exit 3, the raised-merge-bar
  re-derivation and the builder contract.
- **WITHIN-CONTRACT DEPTH PASS for the discovery hunter — opt-in, default OFF** (#1827).
  The hunter surfaced roughly **one** bug per `(function × class)` and missed co-located ones even when it
  hunted the right contract: on `Strategy.checkPoolActivity` it found the narrow-int/DoS bug and missed the
  two oracle-check bugs in the same function; on a whole target it named the right contracts and none of the
  five ground-truth findings. `hunter.ag` already asks for "EVERY qualifying bug" and breadth still yields
  ≤ 1 candidate per cell across the corpus, so the binding constraint is **attention over a whole-zone
  payload**, not the output contract. New `run-discovery.sh --depth-max-cells <N>` (default `0` = OFF) adds,
  AFTER every breadth cell has run, one EXTRA cell per (already-flagged function × alternative lens): the
  payload is narrowed to that single `file@fn` through the existing `slice-fns.sh` slicer, and the lead(s)
  the function already produced are injected VERBATIM as an exclusion, so the model must find a
  mechanistically DIFFERENT bug or answer `SAFE`. Lens order per location is the zone's OTHER classes first
  and the producing one last (at both diagnosing sites the co-located miss lives under a different taxonomy
  class); locations are ranked High-before-Medium, then by candidate count, then by first appearance, and the
  cap is spent ROUND-ROBIN so it cannot burn entirely on the first flagged function. The exhaustive
  per-(function × class) multi-pass alternative was rejected: one real zone alone declares ~180 sliced
  functions × 6 classes, and its "multi-pass inside one cell" variant would make a cell arbitrarily more
  expensive INVISIBLY to the #1830 budget. A depth cell is therefore a **real, counted, charged cell** —
  present in `cells[]` as `"phase":"depth"`, summed into `totals.cells`, reported in `totals.depth_cells` —
  never a hidden second prompt. `run-zone-hunt.sh --zone-depth-cells <N>` (default `0` = OFF) forwards it per
  zone with the effective allowance `min(N, max(0, cap − planned breadth cells))`, so under
  `--zone-cell-budget`/`--run-cell-budget` **depth is trimmed to 0 BEFORE a single breadth class is dropped**;
  `cells_charged` becomes breadth + depth (the cap is charged up front, since depth cells are not enumerable
  by `--list-cells`) and the coverage `detail` names the split. No new coverage status. `DEPTH_KNOWN` is
  consumed as ONE opaque string — never split — so the added CB cost is flat: a bisected **44 CB at 1, 8, 64
  and 256 known leads**, swept under a `cb 2000;` probe (the enforced `cb_per_tick` ceiling) against
  `depth_block()` extracted from `hunter.ag` by line range. With the flag off the whole path is inert: the
  `run-discovery.sh` argv, `discovery-report.md` (pinned byte-for-byte against the golden) and
  `discovery-results.json` keys are all unchanged. `demo-discovery-parallel.sh` (11)–(17) and
  `demo-run-zone-hunt.sh` (p)–(s) pin inertness, env wiring incl. the `exec.env_passthrough` registration,
  the ranked round-robin, zero cost with no lead, determinism + serial/parallel identity, the new
  `DEPTH-CELL|` record boundary, budget interaction and the CB sweep — all offline, all mutation-tested.
  **The defaults stay OFF** until the held-out single-variable A/B declared in
  `docs/zone-split-orchestration.md` passes its five criteria (P1–P5).
- **ZONE-COVERAGE RECORD + per-zone cell budget + targeted re-hunt for `run-zone-hunt.sh`** (#1830).
  A truncated zone-hunt used to be **indistinguishable from a clean sweep**: STAGE 3 logged a failing zone and
  continued, the merge glob skipped a zone dir with no `discovery-results.json` exactly like a zone that never
  existed, and the merged file carried no zone field at all. (Measured on a preserved bench work dir: one
  target hunted **1 of its 7 zones** — the zone holding the epic's named rare bug was never reached — and its
  merged artifact reported a plausible 6-cell / 12-candidate run with no representation of the other six.)
  New `lib/zone-coverage.py` owns `<out>/coverage/zone-coverage.json`, a versioned contract
  (`zone-coverage/v1`) written **unconditionally and before the first zone runs**, with **every** zone in
  `zones.json` present as `not_reached` and rewritten in place as it transitions — so **absence is not
  representable** and an externally-killed run still leaves a truthful record. Eight closed states
  (`not_reached` / `no_brief` / `in_flight` / `failed` / `budget_exhausted` / `hunted_degraded` /
  `hunted_empty` / `hunted`) each license exactly one conclusion, plus the `budget_truncated` qualifier; the
  derived `complete` / `gap_zones` are computed in one place. Fail-loud and always on: a `COVERAGE GAP:`
  stderr banner, an additive `coverage` object (and the previously-dropped `totals.failed`) in
  `discovery-results.merged.json`, and a `<covered>/<total> zone(s) covered` closing banner. Budgets are
  measured in **cells** and enforced as a pre-zone admission decision — `--zone-cell-budget` /
  `--run-cell-budget`, both default `0` = OFF — using the shipped `--list-cells` dry run (#1612, no binary/LLM/
  network); a cell budget bounds hunter calls and **nothing else** (not wall-clock, tokens or memory: the
  #1825 slice-cap change measured +0 cells but +6…20 % per-cell payload), and it introduces **no ordering of
  its own** — the first denial stops the loop so the cut always falls on the tail of the #1826
  value-custody-first order (best-effort packing is an explicit non-goal, pinned by a self-test).
  `--rehunt-gaps` skips STAGE 1/2 and re-enters **only** the recorded gap zones, moving a `failed`/`in_flight`
  zone's prior artifacts to `discovery/<zid>.attempt-<n>` and pushing its terminal state into `attempts[]`
  before re-entry (`failed` is never collapsed into `not_reached`); `no_brief` is never selected;
  `--rehunt-include-partial` and `--rehunt-max-attempts` bound the pass; the unchanged merge produces the
  UNION. Opt-in `--require-coverage <pct>` exits **4** before STAGE 4/5 so a degraded run cannot publish a
  plausible-looking result set. **Every knob defaults OFF/inert** — with them off the `run-discovery.sh`
  invocation gains no argument and the run is byte-identical; the record and the gap banner are the deliberate
  exception, because that is the acceptance criterion. `.zone-list.tsv` generation moved into
  `zone-coverage.py init` **verbatim** (same #1826 sort key, skip and line format) so the record order and the
  hunt order cannot drift. `demo-run-zone-hunt.sh` gains blocks (f)–(j) — including the one that matters: a
  budget-truncated run whose denied zones are present as `budget_exhausted` and are exactly the non-custody
  tail, with a negative control reproducing the 1-of-7 silent-absence shape — and its existing blocks (a)–(e)
  plus the #1717/#1774 CLI guards are untouched and still pass.
  **Four properties added after adversarial review**, each with a mutation-tested self-test (blocks (k)–(n)):
  a ninth state `unscoped` for a zone that ran **zero cells** — `map-zones.sh` writes a `scope.tsv` line only
  `if not skeleton and classes and z["id"] not in failed_zones`, so an unclassified or `classification_failed`
  zone reaches STAGE 3 with a brief, matches no manifest line, and exits 0 with `totals:{cells:0}`; deriving
  `hunted_empty` there re-created the silent-absence defect *inside* the record, so zero cells can no longer
  derive any `hunted_*` status and the case is named up front, before the zone is hunted or charged. The merge
  is a **union across attempts** (dedup by `(subsystem, class, files)`, most-candidates wins, declared under a
  `merge` key) so a re-hunt that yields less than the attempt it archived can never delete a candidate while
  reporting a cleaner verdict. The class-truncation cap is **measured** with a second `--list-cells` probe —
  `--classes` is a per-manifest-LINE override, not a cell filter, so a zone matching several scope lines used
  to be charged N while running L×N cells with mis-assigned classes; it is now denied instead of mis-charged.
  And a full re-sweep into an existing `--out` **carries `attempts[]` over** while the archive suffix is the
  first FREE `.attempt-<n>` on disk, so no archive is ever destroyed and `--rehunt-max-attempts` is a real
  bound across re-sweeps.
  **Two more from the re-review** (blocks (o) and an extended (m)): the merge unions **candidates**, not just
  cells — "most candidates wins" still dropped leads when a later attempt surfaced more, but different, leads
  on the same cell, and `carried_over_cells` stayed 0 so the loss was silent; candidate lists are now unioned
  and deduplicated on the whole candidate string (a key that cannot collapse two distinct leads), with partial
  carries counted. And a cap that cannot be enforced now has its **own** status `budget_unenforceable` and does
  **not** stop the sweep: unenforceability is a per-zone property, not a spent pool, so a trivially enforceable
  neighbour is still hunted and no zone is told to raise a run budget that does not exist. Block (k) now drives
  BOTH zero-cell triggers — the unclassified zone and a classified zone whose name `map-zones.sh`'s `clean()`
  rewrote before `scope.tsv` — so narrowing the guard back to a classification test fails CI.
- **SEMANTIC MECHANISM JUDGE as an opt-in corpus-bench scoring mode (default OFF)** (#1829).
  `score-match.py`'s location-first matcher decides "did the hunter find this ground-truth bug?" by file
  basename + function name co-occurrence, and that ruler undercounts in BOTH directions: a candidate that
  describes a truth row's exact root cause from a factory/helper/getter the report's prose never names scores
  MISS (**name-divergent true match**), while a candidate that merely shares a function name with a row but
  describes a different mechanism scores HIT — on the wrong row (**name-coincident false match**). New
  `--judge <off|cache|cmd>` replaces the name rule with a root-cause + mechanism decision: the scorer shows one
  lead (location, class, exploit, poc_sketch) against a batch of truth rows (`--judge-batch`, default 12, so a
  name twin has a better home to go to) and reads back `VERDICT|<lead_id>|<sev_id>|MATCH|<confidence>|<reason>`
  lines, scoring only MATCHes at or above `--judge-min-confidence` (default 70). **`--judge off` is the default
  and the frozen #1697 code path is byte-identical** — four existing self-tests (`run-corpus-bench.sh`,
  `generation-recall.sh`, `deep-hunt-ab.sh`, `generalization-bench.sh`) pin that. In judge mode the judge is
  **AUTHORITATIVE: there is no fallback to the token matcher**, because a silent fallback would re-import
  exactly the two defects above — an unparseable reply is a `JUDGE-ERROR` (never a quiet NO-MATCH), the
  scorecard grows one `JUDGE<TAB><calls><TAB><errors>` trailer, and the run **aborts with exit 4** above
  `--judge-max-error-rate` (default 20 %) so a degraded backend can never publish a plausible-looking low
  recall. Every call is content-keyed (sha256 of the canonical request) into a read-through `--judge-cache`
  plus an append-only `--judge-log`, so a live-judged number is replayable offline with `--judge cache` (a
  cache MISS is fatal, exit 4 — a replay never invents a decision); the README makes archiving the log
  mandatory for any quoted number. New `bench/corpus-bench/mech-judge.sh` is the judge driver (one request
  JSON on stdin -> `VERDICT|` lines on stdout, the same "echo only the verdict line" idiom as
  `run-gate-agent.sh`); its LLM path goes through `${MECH_JUDGE_LLM_CMD:-<federation-root>/flat-cyborg-claude.sh}`
  — the flat-cyborg PTY wrapper, on the flat-rate subscription session, **never** the metered print-mode API —
  with `FLAT_CYBORG_IDLE_MS` raised to 12000 (the wrapper's 8000 default truncates a multi-row reasoning
  reply). `run-corpus-bench.sh` and `generation-recall.sh` thread the `--judge*` flags through (the generation
  and verified halves of the DELTA are always measured with the SAME ruler) and report judge calls/errors in
  their per-contest lines and `--json`. New `demo-mech-judge.sh` (colony-lint) is the acceptance regression:
  on one synthetic fixture it pins BOTH scorecards byte-exactly — the token matcher's wrong `1/4` with its
  single hit on the wrong row, and the judge's correct `3/4` — so neither direction of the defect can come
  back silently, and it asserts the fail-closed paths (malformed reply fabricates no MATCH, degraded judge
  exits 4, cache miss exits 4) plus the flat-cyborg-only driver contract. CI needs no LLM, no network and no
  `agentis`: the judge runs off the recorded cache and an offline stub. `novelty-gate.sh`, `extract-gt.sh`'s
  `truth.tsv` schema and the location-first algorithm itself are untouched.
- **SHARED HARNESS-MOCK LIBRARY for generated invariant harnesses (inert when unused)**
  (#1794). Harness GENERATION — not hypothesis quality — was the transfer-validation bottleneck on complex
  targets: the prover had to hand-author EVERY external-dependency mock inside each generated test, and an LP
  oracle needing Curve/Balancer-style pricing reads (or a modular vault needing a share-vault dependency)
  produced a harness that did not compile — a `HARNESS_ERROR`, i.e. NO verdict at all rather than a CLEAN or a
  FINDING. New `auditor/harness-mocks/` ships four minimal, **dependency-free, compile-clean** Solidity mocks
  covering the shapes that actually broke the runs: `MockAggregatorV3.sol` (Chainlink feed — configurable
  decimals/answer, fresh `updatedAt` by default, `latestRoundData`/`getRoundData`, explicit
  `setAnswer`/`setStale`/`setIncompleteRound` perturbation), `MockERC20.sol` (constructor-configurable decimals,
  open `mint`/`burn`, approve/transfer/transferFrom), `MockVault4626.sol` (minimal ERC4626 share vault —
  deposit/mint/withdraw/redeem, `convertTo*`, `preview*`, `totalAssets`/`totalSupply`, classic offset-free share
  math so the donation / first-depositor inflation path stays reachable) and `MockPool.sol` (generic
  Curve/Balancer/UniV2-style pool — settable reserves + LP `totalSupply`, `get_virtual_price()` /
  `getVirtualPrice()` / `getRate()`, and a reserve-derived `get_dy(i, j, dx)` / `getAmountOut` quote). No file
  imports anything (not even a sibling), each pins the deliberately wide `pragma solidity >=0.8.0` so it compiles
  under whatever 0.8.x the staged target project pins, and no two files declare the same top-level name, so a
  harness may import all four at once. `run-invariant-hunt.sh` STAGES the library into the generated harness
  project at `<repo>/test/mocks/` before the prover writes or compiles, so a generated
  `import {MockERC20} from "./mocks/MockERC20.sol";` resolves. Staging is a pure copy into a NEW `test/mocks/`
  dir: it never edits `foundry.toml`, the `src/` tree or an existing test, never clobbers a repo that ships its
  own `test/mocks/<Name>.sol`, and the library declares no test contract and no `test*`/`invariant_*` function —
  so a harness that imports nothing new keeps a byte-identical verdict. `invariant-prover.ag` gains an ADDITIVE
  `stagedMockLibrary` directive folded into `sharedScaffold` (hence re-injected on every compile-repair round):
  when the target needs a price feed / token / share vault / pool dependency, IMPORT the staged mock with its
  exact `./mocks/<Name>.sol` path and the target's own decimals/units (the #1720 MOCK-DEP FIDELITY rule is
  unchanged and still governs), and author a bespoke mock ONLY for a shape the library does not cover. Class
  routing, the metamorphic ensemble, the `INVARIANT|` marker, `verdict_of`, the #1471 target-linkage gate and the
  #1725 handler-action normalizer count are all untouched. New `demo-harness-mocks.sh` (registered in
  `tools/colony-lint.sh`) source-guards the library contract, the staging wiring + ordering and the prompt
  directive, and behaviourally executes the runner's OWN staging block against a fixture Foundry project to prove
  the inertness and no-clobber properties (CI-safe: no LLM, no forge, no agentis).
- **MULTI-LENS PER ZONE on the deep-hunt selection — the non-custody class lenses are no longer shadowed by
  custody-first routing** (#1795, epic #1782). `run-zone-hunt.sh`'s STAGE 4.5 selection used to emit ONE row per
  zone (its `dominant_class`, custody-first `C6 → C10 → C11 → C2 → C16 → C5`), so a non-custody lens only ever
  fired on a zone with no custody-primary class. Measured on the corpus, yieldoor and plaza `src` are
  `value_custody=true` AND carry `C2`, so the oracle lens never ran there and their oracle bugs (yieldoor H-2,
  plaza H-4/H-11) were structurally unreachable. The selection now emits one row per **(zone × applicable
  implemented lens class)**: a new `lens_classes()` keeps the zone's pre-#1795 row FIRST (the custody-primary
  class for a value-custody zone, the #1790 non-custody dominant class otherwise) and then appends every
  applicable `IMPLEMENTED_NONCUSTODY` class (`C2`, `C16`, `C5`) the zone carries, in coverage-map rarity order.
  The implemented lens classes now have a **single source of truth** — `CUSTODY_PRIMARY_CLASSES` +
  `IMPLEMENTED_NONCUSTODY`, concatenated into `IMPLEMENTED_LENS_CLASSES`, which `dominant_class()` iterates —
  so the precedence order and the gate can no longer drift apart. The fan-out is bounded by a new
  `--deep-hunt-max-lenses <N>` (**default 2**); `N=1` reproduces the pre-#1795 selection exactly. Interface-only
  non-custody zones stay skipped (still a guaranteed `HARNESS_ERROR`), and value-custody zones keep their custody
  lens unchanged — no zone loses a lens it previously got. The per-zone deep-hunt out-dir is now keyed per
  **(zone, class)** (`deep-hunt/<zid>-<class>`): without it two lenses of one zone would share a run dir and
  their per-target `invariant_<t>.log` would collide, so the #1780 merge adapter (globs `invariant_*.log` under
  `<dzout>/run`, filters the per-candidate `_c<N>.log`) would read the wrong lens's verdict; the
  `deep-hunt/*/run/invariant_*.log` consumers (`generation-recall.sh`, `generalization-bench.sh`) glob the zone
  level, so the suffix is transparent to them. The zone-hunt log lines carry the class so a zone appearing more
  than once still reads correctly. `demo-invariant-ensemble.sh` guards the single source of truth, the
  `lens_classes()` cap, the flag + its validation, the per-(zone,class) out-dir, and — behaviourally, by running
  the REAL selection python over a synthetic corpus-shaped `zones.json` — the custody-row-first invariant, the
  now-emitted C2 row, the `N=2` cap, `N=1` == the pre-#1795 selection, the skipped interface-only zone, and the
  per-(zone,class) merge-adapter resolution (CI-safe, no LLM/forge/agentis). Measuring the live A/B recall of the
  wider fan-out is a separate post-merge step.
- **ACCESS-CONTROL / PRIVILEGE invariant lens class for the deep-hunt prover (default-off, byte-identical when the class does not apply)**
  (#1785, epic #1782, on the #1778 ensemble rails). A FOURTH class-routed metamorphic lens alongside the #1778
  value-custody class, the #1783 oracle class and the #1784 liveness class: the prover (`invariant-prover.ag`) gains
  an `is_access_sensitive()` detector (sibling of `is_value_custody`/`is_oracle_dependent`/`is_liveness_sensitive`,
  keywords `access`/`role`/`onlyowner`/`onlyrole`/`privilege`/`permission`/`auth`/`tradetype`, DISJOINT from the
  value-custody, oracle AND liveness sets) plus a `class_to_keyword` mapping of the bare taxonomy code `C5` (Access
  control / role model) to the new `access` keyword. `action_checklist_prompt()` gains an access branch (an
  unprivileged-caller action calling every guarded state-changing entrypoint + a param-tamper action choosing the
  sensitive attacker-influenced enum/parameter) and `metamorphic_relation_prompt()` a two-shape access menu
  (unprivileged-no-effect, param-tamper-parity), both after the liveness block. `metamorphic_variant_seed()` extends
  the CUSTODY-FIRST / ORACLE-SECOND / LIVENESS-THIRD precedence chain with an ACCESS-FOURTH branch: the value-custody,
  oracle and liveness variant strings stay byte-identical, an access-sensitive class then routes the two access
  ensemble variants (variant 0 unprivileged-no-effect via `require(sAfter == sBefore, ...)`, variant 1
  param-tamper-parity via `require(gainTamper <= gainHonest + gainHonest/1000 + 1, ...)`; index >= 2 falls back to the
  access menu), and any other class falls through to `return ""`. The class carries TWO metamorphic shapes (#1785) —
  the two REQUIRED templates — so, like the liveness branch, there is no pinned variant 2. `run-zone-hunt.sh`
  `dominant_class()` appends `C5` AFTER `C6/C10/C11/C2/C16`, and `C5` joins the `IMPLEMENTED_NONCUSTODY` gate
  (`{"C2", "C16", "C5"}`), so an access-only zone (C5 but no value-custody-primary, oracle or liveness code) is now
  selected and routes to the access lens on the live deep-hunt path (byte-identical routing for every zone that has
  `C6/C10/C11/C2/C16`; an access bug inside a higher-precedence zone still routes to that lens — a documented known
  limitation for this milestone). **Default off**: an empty `INV_ENSEMBLE_VARIANT`, or any
  non-access/non-liveness/non-oracle/non-custody class, yields a BYTE-IDENTICAL generation prompt, and a value-custody
  / oracle / liveness target hits its own branch first (the access detector fires false on it); the #1725
  normalizer-site count stays 2, and `verdict_of`, the `INVARIANT|` marker, and the #1471 target-linkage gate are
  untouched. `demo-invariant-ensemble.sh` source-guards the detector, the C5→access map, the access
  action/relation/variant text, the liveness-third / access-fourth precedence + `return ""` fallthrough, the retained
  #1725 count, and the `dominant_class`/`IMPLEMENTED_NONCUSTODY` C5 routing (CI-safe, no LLM/forge/agentis). The
  live-A/B acceptance (the notional H-10 `TradeType`/param-tamper witness through the ensemble producing an
  `INVARIANT|...|FINDING`) is a separate post-merge step, not part of this change.
- **ARITHMETIC-OVERFLOW / LIVENESS (DoS) invariant lens class for the deep-hunt prover (default-off, byte-identical when the class does not apply)**
  (#1784, epic #1782, on the #1778 ensemble rails). A THIRD class-routed metamorphic lens alongside the #1778
  value-custody class and the #1783 oracle class: the prover (`invariant-prover.ag`) gains an
  `is_liveness_sensitive()` detector (sibling of `is_value_custody`/`is_oracle_dependent`, keywords
  `liveness`/`overflow`/`uint8`/`uint16`/`observation`/`cardinality`/`index`/`revert`/`dos`/`getincrement`, DISJOINT
  from BOTH the value-custody and oracle sets) plus a `class_to_keyword` mapping of the bare taxonomy code `C16`
  (State-machine liveness / stuck-state) to the new `liveness` keyword. `action_checklist_prompt()` gains a liveness
  branch (a wrap-boundary action driving a `uint8`/`uint16` accumulator / observation index past its max + a
  full-range critical-entrypoint sweep) and `metamorphic_relation_prompt()` a two-shape liveness menu
  (no-revert-on-valid-range, narrow-int-no-wrap), both after the oracle block. `metamorphic_variant_seed()` extends
  the CUSTODY-FIRST / ORACLE-SECOND precedence chain with a LIVENESS-THIRD branch: the value-custody and oracle
  variant strings stay byte-identical, a liveness-sensitive class then routes the two liveness ensemble variants
  (variant 0 no-revert-on-valid-range via a `try/catch` revert, variant 1 narrow-int-no-wrap via
  `require(cAfter >= cBefore, ...)`; index >= 2 falls back to the liveness menu), and any other class falls through
  to `return ""`. The class carries TWO metamorphic shapes (its two REQUIRED templates), so — unlike the oracle
  branch's three — there is no pinned variant 2. `run-zone-hunt.sh` `dominant_class()` appends `C16` AFTER
  `C6/C10/C11/C2`, so a liveness-only zone with no value-custody-primary or oracle code now routes to the liveness
  lens on the live deep-hunt path (byte-identical routing for every zone that has `C6/C10/C11/C2`; an overflow bug
  inside a vault/lend/oracle zone still routes to the higher-precedence lens — a documented known limitation for
  this milestone). **Default off**: an empty `INV_ENSEMBLE_VARIANT`, or any non-liveness/non-oracle/non-custody
  class, yields a BYTE-IDENTICAL generation prompt, and a value-custody or oracle target hits its own branch first
  (the liveness detector fires false on it); the #1725 normalizer-site count stays 2, and `verdict_of`, the
  `INVARIANT|` marker, and the #1471 target-linkage gate are untouched. `demo-invariant-ensemble.sh` source-guards
  the detector, the C16→liveness map, the liveness action/relation/variant text, the oracle-second / liveness-third
  precedence + `return ""` fallthrough, the retained #1725 count, and the `dominant_class` C16 routing (CI-safe, no
  LLM/forge/agentis). The live-A/B acceptance (the yieldoor H-3 overflow-DoS witness through the ensemble producing
  an `INVARIANT|...|FINDING`) is a separate post-merge step (#1787), not part of this change.
- **ORACLE-MANIPULATION invariant lens class for the deep-hunt prover (default-off, byte-identical when the class does not apply)**
  (#1783, epic #1782, on the #1778 ensemble rails). A SECOND class-routed metamorphic lens alongside the #1778
  value-custody class: the prover (`invariant-prover.ag`) gains an `is_oracle_dependent()` detector (sibling of
  `is_value_custody`, keywords `oracle`/`price`/`feed`/`chainlink`/`slot0`/`getprice`/`latestanswer`, DISJOINT from
  the value-custody set) plus a `class_to_keyword` mapping of the bare taxonomy code `C2` (Oracle integrity) to the
  new `oracle` keyword. `action_checklist_prompt()` gains an oracle branch (price-perturbation + stale-then-fresh
  actions) and `metamorphic_relation_prompt()` a three-shape oracle menu (monotone-price-response, stale-vs-fresh
  parity, manipulation-bounded-extraction), both after the reentrancy branch. `metamorphic_variant_seed()` is
  restructured CUSTODY-FIRST / ORACLE-SECOND: the value-custody variant strings stay byte-identical, an
  oracle-dependent class then routes the three oracle ensemble variants (bounded-move price monotonicity,
  stale-vs-fresh parity, manipulation-bounded-extraction), and any other class falls through to `return ""`.
  `run-zone-hunt.sh` `dominant_class()` appends `C2` AFTER `C6/C10/C11`, so an oracle-dependent zone with no
  value-custody-primary code now routes to the oracle lens on the live deep-hunt path (byte-identical routing for
  every zone that has `C6/C10/C11`; an oracle bug inside a vault/lend zone still routes to the custody lens — a
  documented known limitation for this milestone). **Default off**: an empty `INV_ENSEMBLE_VARIANT`, or any
  non-oracle/non-custody class, yields a BYTE-IDENTICAL generation prompt, and a value-custody target (yearn/plaza)
  hits the custody branch first (the oracle detector fires false on it); the #1725 normalizer-site count stays 2,
  and `verdict_of`, the `INVARIANT|` marker, and the #1471 target-linkage gate are untouched.
  `demo-invariant-ensemble.sh` source-guards the detector, the C2→oracle map, the oracle action/relation/variant
  text, the custody-first precedence + `return ""` fallthrough, the retained #1725 count, and the `dominant_class`
  C2 routing (CI-safe, no LLM/forge/agentis). The live-A/B acceptance (an oracle target through the ensemble
  producing an `INVARIANT|...|FINDING` witness) is a separate post-merge step, not part of this change.
- **Single-run METAMORPHIC ENSEMBLE for the deep-hunt invariant lens (`--ensemble-candidates <N>`, default off)**
  (#1778). Single-draw variance was capping deep-hunt recall on value-custody targets: the rare High hides in a
  per-unit-price / per-share value-conservation break that ONE generated invariant often fails to state. For a
  value-custody target the runner now steers N DISTINCT relational-invariant VARIANTS — large-vs-small unit-price
  monotonicity (`require(pB <= pS + pS/1000 + 1, ...)` via the contract's own `simulate*`/`preview*`/`convertTo*`/
  `quote*` views), before-vs-after existing-holder per-share price, and actor-A-vs-B value parity — each its OWN
  prover generation + its OWN forge run(s) through the UNCHANGED gate/repair/teeth loop, then takes an
  ENSEMBLE-VOTE verdict (any candidate FINDING ⇒ FINDING with that candidate's shrunk witness; else any
  HARNESS_ERROR ⇒ HARNESS_ERROR; else CLEAN). The prover (`invariant-prover.ag`) gains only two additive,
  empty-by-default builders — `is_value_custody()` + `metamorphic_variant_seed()` — gated on an empty-by-default
  `INV_ENSEMBLE_VARIANT` (appended at the END of the `exec.env_passthrough` allowlist); the ensemble LOOP +
  verdict aggregation live in `run-invariant-hunt.sh`, REUSING #1726's per-class relation vocabulary as REQUIRED
  (not optional) shapes and mirroring #1731's shell-side cross-run ensemble. `run-zone-hunt.sh` forwards the flag
  verbatim via `DEEP_FWD`; `bench/corpus-bench/deep-hunt-ab.sh` forwards it into the `--live` A/B ON arm. Composes
  with the #1722 audit seed, #1755 core-dep seed, and the #1731 corpus replay (the winning candidate accumulates
  into that corpus). **Default off (N = 0/1, or the offline `--handler-fixture` path) is byte-identical to today's
  single-draw pipeline**: the aggregate is emitted as the LAST `INVARIANT|<target>|<verdict>` line (per-candidate
  diagnostics use a `CANDIDATE|` prefix carrying no `INVARIANT|` substring), so both downstream consumers (this
  runner's `tail -1`, `run-zone-hunt.sh`'s last-`INVARIANT|`-wins adapter) parse unchanged, and `verdict_of`, the
  marker contract, and the #1471 `--require-import`/`--require-contract` gate semantics are untouched.
  `demo-invariant-ensemble.sh` source-guards the wiring, the byte-identical-when-OFF guard, the three variant
  shapes, and the bench forwarding (CI-safe, no LLM/forge/agentis). The real-money acceptance bench
  (`deep-hunt-ab.sh --live --ensemble-candidates 3`, expecting the plaza pool target Δ > 0) is a separate
  post-merge step, not part of this change.

### Changed
- **The `--depth-lens-quota` default has a second, independent guard** (#1856). Mutation testing on #1854
  found `demo-discovery-parallel.sh` block 13f to be the SOLE assertion that fires when the default drifts
  (at `2` and at `3`, all other 58 + 71 demo assertions still passed). `colony-lint.sh` gains its
  orthogonal **static** twin: a value-oriented grep that the default is still the measured-safe `1`,
  tolerating indentation, quoting and a trailing comment, with a self-repairing failure message. 13f is
  behavioural (it runs the tool), the pin is static (it reads the source) — deleting either leaves the
  other standing. `demo-discovery-parallel.sh`'s stale "default quota 3" comments (left by the #1854
  revert, which #1855 fixed only in the docs) now say "an explicit quota 3", including the assertion
  message that would otherwise have misdirected a debugger straight past the cause.
- **The within-contract depth pass now CONCENTRATES its budget instead of spreading it** (#1850). The #1827
  depth pass allocated its cap breadth-first — one lens per flagged location per pass — so on the run that
  produced its held-out verdict, 12 depth cells went to 10 distinct locations and no function was ever hunted
  under more than two lenses. The mechanism the pass exists for (re-reading ONE function under several lenses
  until it stops yielding) was therefore never exercised, and the A/B that shipped the flag OFF measured an
  allocation, not the capability. `run-discovery.sh --depth-lens-quota <N>` (default **1**) replaces the
  round-robin with a **quota-round-robin**: each location takes N consecutive lenses before the plan moves on,
  in rounds, until the cap is spent. `N=1` reproduces the #1827 spread byte-for-byte, which is why the old
  allocation needs no second code path.
  The default shipped as 3 and was **reverted to 1** after the measurement: quota 3 on plaza produced the
  first rare row the depth pass has ever found (M-12, `found_by=1`, via a second lens on `exitBalancerPool`
  that the spread never gave it) but the same run matched 10/30 ground-truth rows against the control's
  13/30. The four losses are **not attributable** — both arms re-hunted the stochastic breadth pass, so that
  A/B cannot separate an allocation effect from breadth variance. Deciding the default needs a
  **breadth-fixed** A/B (a depth-only re-entry that consumes a recorded `results-cells.jsonl` instead of
  re-hunting breadth); until then the default is the value whose behaviour is measured, and `3` is available
  for the experiment.
  - **`N=1` reproduces the old allocation byte-for-byte**, so the spread arm stays re-derivable with a flag
    rather than a second code path — `demo-discovery-parallel.sh` (13d) keeps the pre-#1850 expectation
    verbatim as exactly that case. N is not a taste parameter: on the recorded 12-cell plan, full exhaustion
    (N = the zone's 6 classes) gives the acceptance-criterion location **zero** lenses, and N = 2 gives the
    top locations only what the spread already gave them. N = 3 is the smallest quota that clears "hunted
    under >= 3 distinct lenses" while still reaching the rank-4 location.
  - **Nothing else moves.** The location ranking, the `(location x lens)` pair multiset and the cap semantics
    (`min(cap, planned pairs)`) are untouched — only the emission order — so depth still ADDS cells,
    `totals.depth_cells` still equals the observed extra, `--list-cells` still enumerates breadth only, and
    the #1830 budget still trims depth to 0 before a single breadth class is dropped. Per-location spend is
    bounded by the classes the ZONE advertises, so a quota can never burn a whole cap on one function.
  - `run-zone-hunt.sh --zone-depth-lens-quota` and `bench/corpus-bench/run-corpus-bench.sh
    --zone-depth-lens-quota` forward it; both are inert unless SET, so a default depth-on argv is
    byte-identical to a pre-#1850 one and the two A/B arms differ by exactly one bench-level flag.
    `totals.depth_lens_quota` (emitted only when depth is on, like `depth_cells`) records which allocation
    produced a given set of cells, so no future reader can compare two depth arms blind.
  - **Depth itself stays OFF** (`--depth-max-cells` / `--zone-depth-cells` remain `0`): this changes how the
    cap is spent, not whether it is spent. The held-out A/B that could flip a default is declared up front in
    `docs/zone-split-orchestration.md` (P0-P5, a fresh target, pre-committed FAIL consequences) and is an
    operator run — it is NOT claimed by this change.
- **The mechanism judge's scoring gate moved 70 -> 60, and every judged scorecard now records the ruler it was
  measured with** (#1841). The judge's decision rule states that divergent file or function names are NOT
  disqualifying, and the judge obeys that in the **decision** — but not in the **confidence**: when a lead
  describes the ground-truth row's root cause from a location the row's prose never names (a superseded copy,
  a factory, a helper), it returns `MATCH` with a confidence in the 60s. The old `--judge-min-confidence`
  default of 70 then converted that hedge into a scored MISS, so the rule and the ruler contradicted each
  other and the contradiction was resolved against the pipeline. The new default sits deliberately **below**
  the entire observed 62–68 hedge band rather than through the middle of it, which makes it an **outlier
  floor** against a MATCH the judge itself disbelieves rather than a recall parameter. **Evidence base, stated
  plainly: 43 judging calls over 2 contests from ONE interim run at ONE pipeline revision — a sensitivity
  curve, not a calibration.** What it establishes is that the hedged band is 62–68 and correlates with
  location divergence, and that nothing at all is dropped at 50 or 60 on either contest, i.e. the shipped gate
  is inert on the measured data. Two named falsifiers, both observable from the artifacts this change emits: a
  future MATCH credited in `[60, 70)` that triage shows is a *different* mechanism, or a location-divergent
  true match recorded *below* 60. Either one means the confidence cannot separate the two populations and the
  answer is separating mechanism confidence from location agreement, not another retune. Because a gate that
  moves a headline silently is the real hazard, `score-match.py` now emits an additive judge-mode-only trailer
  `GATE<TAB><min_confidence><TAB><gated_matches><TAB><gated_rows>` — the threshold in force, how many valid
  MATCH decisions it dropped, and how many rows are MISS *only* because of it — and a nonzero `gated_rows` is
  the standing tripwire that a headline is gate-sensitive. `run-corpus-bench.sh` and `generation-recall.sh`
  both resolve the gate to a shared `JUDGE_MINCONF_DEFAULT=60` and **always forward the value they print**, so
  the printed threshold is by construction the applied one; `run-corpus-bench.sh --json` gains
  `judge.min_confidence` / `judge.gated_matches` / `judge.gated_rows` (`null` + zeros under `--judge off`,
  where no gate exists). Nothing touches the prompt, the `VERDICT|` grammar, the cache key, `--judge off` or
  the MATCH/NO-MATCH decision itself: the #1829 false-positive direction is decided by the DECISION and the
  gate only ever *drops* MATCHes, so no threshold value can promote a NO-MATCH — pinned by a new fixture
  (`fixtures/mech-judge-location/`) in which a name-coincident different-mechanism lead stays MISS even at
  `--judge-min-confidence 0`, while a hedged `MATCH|64` from a superseded-copy location is MISS at 70 and
  credited at the default **from the same recorded decisions with an identical `JUDGE` trailer** — the fix is
  a re-score, not a re-judge. The existing fixtures' decisions are all 85–92, so the default move changes no
  HIT/MISS anywhere; they only gain the `GATE` line. **Effect on published figures, stated rather than
  absorbed:** the 6/19 #1799 baseline is **untouched** (it was measured under `--judge off`, where no
  confidence gate exists); the interim judged run re-reads at 60 as crestal `rare 1/3 -> 2/3` and `all 4/7 ->
  5/7`, and plaza `rare 0/5` unchanged with `all 4/30 -> 5/30` because a `found_by=14` row's `62`/`63`
  decisions now score — the honest cost of choosing a floor below the band instead of inside it. Both numbers
  are re-derivable from the one archived cache: `--judge-min-confidence 70` reproduces the old scorecard
  byte-for-byte. `gt-dupes.sh`'s **recording** floor stays 70 and is no longer described as "the same gate the
  scorer applies" — it is an independent floor on which pairs get written, and the 85 merge bar is what
  decides expansion; the location-contamination argument does not reach GT-vs-GT judging, where neither side
  is a hunter location. Finally, the pre-existing **cache-generation hazard** is now documented where the next
  person will hit it (on `judge_request()` in `score-match.py` and in the bench README): the key covers
  `{lead, rows}` only, the prompt is therefore not part of it and replay re-parses the recorded reply, so any
  prompt edit must version the key first or one cache file will silently mix two decision generations.

### Fixed
- **`map-zones.sh`'s `fn_names()` no longer scrapes NatSpec prose or a commented-out declaration as a phantom
  function name, burning slice slots** (#1834). The old regex, `\bfunction\s+([A-Za-z0-9_]+)`, matched the
  WORD FOLLOWING the literal substring "function" anywhere on a line — so a NatSpec comment like `/// @notice
  Internal function which performs...` scraped `which` as a "function name", and a `//`-commented-out old
  declaration scraped the dead name too, each burning a slot in the `FN_SLICE_CAP`-bounded slice ahead of real
  declarations. Anchored the regex on `^\s*function\s+([A-Za-z0-9_]+)\s*\(` — a line that (after only leading
  whitespace) STARTS with the `function` keyword immediately followed by `(`, i.e. an actual declaration — a
  strict subset match that never adds a name the old regex wouldn't also have matched. Verified against real
  corpus-bench targets (`BondToken.sol`, `PoolFactory.sol`, `LendingPool.sol`, `Leverager.sol`): **zero**
  legitimate declarations lost, zero spurious names gained; the only names dropped are the phantom words
  themselves (`to`, `is`, `updates`, `calculates`, `resets`, `which`, `can`). Verified the fix does not move
  any of the three #1825 rare-bug functions within the cap-16 slice: `Strategy.checkPoolActivity` stays at
  rank 16 of 16, `ReserveLogic._updateIndexes` at rank 12 of 16, `Pool.startAuction` at rank 11 of 16 —
  byte-identical before and after removing the phantoms in those four files. Out of scope: comment-state
  (`/* ... */` block) tracking — `fn_names()` is a one-pass-per-line scraper with no lexer, and a declaration
  living inside a block comment is an accepted, documented residual (empirically 0 hits across 263 `.sol`
  files in the sampled corpus). New fixture `contracts/registry/Registry.sol` carries all three shapes (NatSpec
  prose, commented-out declaration, block-comment declaration) in its own file/zone — appending them to the
  existing `Liquidation.sol` fixture was tried and found unsafe, since a phantom name containing `price` shifts
  the `valuation` partition's reserved-slot count and silently bumps `_healthFactor` out of its existing cap-16
  pin. `demo-map-zones.sh` gains block `(1f)`, asserting the registry zone's function slice equals exactly
  `{setAllowed, isAllowed, renounceOwnership, oldSetAllowedBatch}` — set-equality so it fails on ANY unexpected
  phantom, and fails if the accepted block-comment residual (`oldSetAllowedBatch`) silently disappears.
- **`map-zones.sh`'s function-slice cap raised from 8 to 16, recovering three rare-bug functions the old cap
  truncated out of `scope.tsv`** (#1825). `prioritize_fn_names()` reorders a big contract's declared function
  names so value-moving (#1701) and valuation (#1799) functions survive the `[:cap]` slice ahead of admin/
  setter noise, but the truncation point itself was still a hardcoded `8`. Re-checking the corpus bench's
  preserved `scope.tsv` against the ground-truth rare findings showed the reorder was not enough: three
  functions from real audit reports still fell out past rank 8 — yieldoor's `Strategy.checkPoolActivity`
  (rank 16 of 35 declared names), yieldoor's `ReserveLogic._updateIndexes` (rank 12 of 18), and plaza's
  `Pool.startAuction` (rank 13 of 24). A flat cap of **16** is the smallest uniform value that recovers all
  three: no percentile-style adaptive rule measured against both targets clears all three without either
  overshooting the cheapest zone's payload or undershooting one of the three ranks (the rank distribution is
  not a function of the contract's declared-name count). Measured cost: **+0 discovery cells** (the cap
  changes only the per-cell payload `run-discovery.sh` hands each zone, never the cell count) and +6…20 %
  per-cell payload across the corpus targets (sub-linear, because the payload is dominated by contract
  headers and sub-threshold whole files, not marginal function bodies). `map-zones.sh` now names the literal
  `FN_SLICE_CAP = 16`, with a comment recording the zero-margin fact that `checkPoolActivity` lands at
  EXACTLY rank 16 of 16 (in the unclaimed `rest` partition) — a future addition to `VALUE_MOVING_KEYWORDS` or
  `VALUATION_KEYWORDS` can push it back out past the cap. `demo-map-zones.sh` gains a new fixture assertion
  (`accrue`/`seize`/`_healthFactor` present at cap 16, `setOracle` still absent) and converts its two existing
  #1701/#1799 regression guards from plain membership checks to ORDERING checks (`index(x) < index(y)`).
  Membership goes vacuous once the cap is large enough that a naive declaration-order slice would also contain
  the guarded name — which at cap 16 is already true of the #1701 guard (`liquidate` is declared 12th of 17,
  `redeem` 14th, so both survive an unprioritised `[:16]`). The #1799 guard is not yet vacuous at this cap
  (`convertToAssets` is declared LAST of 17 and still drops out of a naive `[:16]`); it is converted for the
  same reason pre-emptively, so the next cap raise cannot silently hollow it out.
- **`map-zones.sh`'s mechanical grouping pass no longer turns `test/`/`tests/`/`interfaces/`/`mocks/`/`script/`
  directories (or `.t.sol` files) into discovery zones** (#1824). Every directory reachable under `--repo` used
  to become a zone regardless of what it held, so `scope.tsv` routinely carried Foundry test suites, mocks,
  pure interfaces, and deployment scripts alongside the target's real code — none of which can hold a real
  bug, so classifying and hunting them was pure wasted hunter effort (there is no timeout anywhere in this
  pipeline for that effort to consume; `run-zone-hunt.sh`'s zone loop is an unbounded serial `for`). The new
  `is_excluded_zone_path()` filter drops sources matching those path conventions (segment-anchored — a
  leading `<prefix>/` or mid-path `/<prefix>/`, never a bare substring, so a real dir like `scripts_core/` is
  unaffected) from `sources` before the mechanical pass groups them into zones, so an excluded file never
  forms a zone at all — it disappears from BOTH `zones.json` and `scope.tsv`. This is **path-based, not
  `value_custody`-based**: `libraries/`, `types/`, and every other directory name are untouched and keep
  flowing into zones exactly as before (this is the guard that keeps zones like yieldoor's rare M-2 finding,
  `ReserveLogic._updateIndexes`, reachable). An explicit `--scope-hint` bypasses the filter entirely (the
  operator's explicit narrowing is trusted), so an atypically-named real directory can still be forced in
  with zero new CLI surface. `demo-map-zones.sh` gains a fixture regression: `test/`, `mocks/`, `interfaces/`,
  and `script/` zones with real (non-empty) classifications are asserted absent from both outputs, while a
  `libraries/` zone and a `scripts_core/` zone (proving the match is segment-anchored, not a substring of
  `script`) are asserted present with their classification intact.
- **The #1778 ensemble FINDING now actually merges into `verified_findings.json` (the deep-hunt merge adapter reads the AGGREGATE log, not a per-candidate one)**
  (#1778 follow-up). The `run-zone-hunt.sh` merge adapter selects the invariant log via `sorted(glob("invariant_*.log"))[-1]`.
  The ensemble writes per-candidate logs `invariant_<t>_c<N>.log` ALONGSIDE the canonical aggregate `invariant_<t>.log`
  (which carries the ensemble-vote verdict + the winning candidate's `STEP|` witness). Because `sorted()` is codepoint
  order and `_` (0x5F) > `.` (0x2E), `sorted()[-1]` landed on the last per-candidate `_c<N>` log — typically a CLEAN one —
  so a real ensemble FINDING was silently read as CLEAN and dropped (`Δ = +0` even when a candidate broke). The adapter now
  filters `_c[0-9]+\.log$` out of the glob, always reading the aggregate; single-candidate/OFF runs emit only the aggregate,
  so the filter is a no-op there. Proven live: the plaza `Pool.sol` ensemble (candidate 1 metamorphic → FINDING) was being
  dropped as CLEAN pre-fix; post-fix the aggregate FINDING + its 20-line `STEP|` witness merge. `demo-invariant-ensemble.sh`
  gains a source-guard (the `_c<N>` filter is present) + a behavioural check (selection picks the aggregate FINDING under
  codepoint sort).
- **`core_dep_seed` hands the model the REAL in-repo target import path, not `relImport` (= the staged `../../target-code.sol` basename)**
  (#1765, #1755 M5 follow-up). M5 threaded `relImport` (= `rel_import_path(invOut, codePath)`) into `core_dep_seed`
  as its `targetRel` — the import path the GENERATION directive tells the model to use for the target. But by
  `run-invariant-hunt.sh`'s path arithmetic `codePath = CODE_PATH = <RUN>/target-code.sol`, so `relImport` resolves
  to `../../target-code.sol` (basename `target-code.sol`), NOT the in-repo `../src/<Target>.sol` the M5 comment
  claimed and the catching harness actually used (`import {LiquityV2SPStrategy} from "../src/Strategy.sol";`). So the
  generation prompt handed the model an INCONSISTENT hint (import from a `target-code.sol`-basename path while ALSO
  being told to forbid `target-code.sol`) — a plausible driver of the harness-gen import-path VARIANCE (some runs
  imported `../src/…` and caught; some reached for `target-code.sol` and failed to compile → `HARNESS_ERROR`). The
  fix: `core_dep_seed`'s `targetRel` is now `vaultTargetRel` = `../` + the `--target` FILE part
  (`vault_target_rel(targetFile)`, e.g. `src/Strategy.sol` → `../src/Strategy.sol`, basename `<Target>.sol`), derived
  from `TARGET_FN` by the same file-part idiom M6 added — exactly the path the catching harness imports. The
  misleading M5 comment (`targetRel` = `rel_import_path(invOut, codePath)` = the in-repo `../src/…`) is corrected.
  This is ONLY the GENERATION prompt's hint: the #1471 arming (M6, which independently derives the basename from
  `TARGET_FN`), `verdict_of`, and the `INVARIANT|` marker are untouched. Inside the `!active => ""` builder, so it is
  **default-off byte-identical** when `--core-dep-harness` is off / the target is non-yearn. `demo-invariant-core-dep.sh`
  source-guards that the directive pins the in-repo `../src/…` import (from `TARGET_FN`) and that the call site threads
  `vaultTargetRel`, NOT `relImport`/`target-code.sol`.
- **Arm the #1471 link gate with the in-repo target path on the core-dep harness (fix M5's import pin HARNESS_ERRORing a real FINDING)**
  (#1755, M6). M5 pins the core-dep harness to import the target from its REAL in-repo `../src/<Target>.sol`
  source (basename e.g. `Strategy.sol`) — the shape that COMPILES and CATCHES the yearn first-depositor
  money-tier bug — instead of the pipeline's staged `target-code.sol`. But the prover's `link_args`
  (`auditor/agents/invariant-prover.ag`) armed the #1471 TARGET-LINKAGE gate with `--require-import <CODE_PATH>`
  = the staged `target-code.sol`, and the gate (`evm-harness/forge-invariant.sh`) basenames that arg and greps
  the harness for an `import` of THAT basename. So the catching harness (importing `../src/Strategy.sol`, basename
  `Strategy.sol` ≠ `target-code.sol`) was rejected as `HARNESS_ERROR` **before any fuzzing** — the pipeline
  mis-reported its own real FINDING as a harness error every run (an M5↔#1471 basename conflict, NOT the earlier
  mis-diagnosed `__rc`-capture bug). The fix: on the core-dep/`vaultRoute` path only, arm `--require-import` with
  the target's in-repo file path (the target label's file part, basename `Strategy.sol` — the path M5 pins the
  harness to import) instead of `target-code.sol`. The #1471 safety property is fully preserved — the gate STILL
  requires the harness to import the REAL in-scope target, and a harness importing NEITHER the staged nor the
  in-repo real target still `HARNESS_ERROR`s; only WHICH real-target path is required changes (staged copy →
  in-repo copy, the SAME real contract). Scoped strictly: on the non-core-dep path (`vaultImport == ""`)
  `link_args` is **byte-identical** — it still arms with `codePath`. The fuzzer stays the sole verdict; the
  `INVARIANT|` marker, `verdict_of`'s exit-code→token map, and the #1471 matcher LOGIC in `forge-invariant.sh`
  are untouched (only WHAT path is passed changes, not how the gate matches). `demo-invariant-core-dep.sh`
  source-guards the vaultRoute-scoped in-repo arming, the byte-identical non-core-dep fall-through, and the
  untouched matcher logic.
- **`run-zone-hunt.sh` STAGE 3 hunts value-custody zones first** (#1826). The serial per-zone discovery loop
  consumed `.zone-list.tsv` in whatever order `zones.json` carried, which `map-zones.sh` derives from
  `sorted(sources)` grouped by directory — alphabetical, not custody-aware. A wall-clock timeout imposed from
  outside the pipeline (there is no per-zone budget primitive inside it) could therefore truncate the run
  after an arbitrary, priority-blind prefix: on the `plaza` corpus target the one `value_custody` zone sat
  SECOND, after a non-custody `script/` zone. The fix sorts the same in-memory `zones` list the STAGE 3 python
  heredoc already builds by `(not value_custody, id)` before printing `.zone-list.tsv` — custody-first, zone
  id as the stable tie-break — so a truncated run now only ever drops the lowest-priority (non-custody) zones.
  No new CLI flag, no change to `.zone-list.tsv`'s 2-column shape, no change to `map-zones.sh`'s own
  zone-generation order or to the STAGE 4.5 `--deep-hunt` zone selection (which already reads `value_custody`
  directly off `zones.json`, independent of `.zone-list.tsv`). `z.get("value_custody", False)` keeps a zone
  from an older `zones.json` predating #1713 sorting as non-custody instead of raising. `demo-run-zone-hunt.sh`
  gains a new assertion block pinning: every custody zone before every non-custody zone, id-ordered within
  each group, AND byte-identical `.zone-list.tsv` output across two independent runs of the same fixture.

## [0.5.0] - 2026-07-20

### Added
- **Vault harness directive: pin the target import to its in-repo path (fix core-dep harness-gen HARNESS_ERROR variance)**
  (#1755, M5). M1–M4 make the autonomous pipeline GENERATE a harness that CATCHES the yearn first-depositor
  money-tier bug (deterministic FINDING, reproducible 4-step exploit witness, passes the #1471 link gate), but
  harness-gen is not yet RELIABLE: across two autonomous runs the LLM's import for the target contract VARIES.
  The catching run imported the target from its real in-repo source (`import {LiquityV2SPStrategy} from
  "../src/Strategy.sol";`); a second run imported the pipeline's FLATTENED staged copy (`import {...} from
  "target-code.sol";`) — a file that lives one directory ABOVE the foundry repo, not inside it, so the test fails
  to compile (`Source "target-code.sol" not found`) => HARNESS_ERROR. This adds one directive-string bullet to
  `core_dep_seed` in `auditor/agents/invariant-prover.ag`: import the target ONLY from its real in-repo
  `../src/<Target>.sol` path (the same `rel_import_path(invOut, codePath)` value the skeleton's `importLine`
  already resolves, now threaded into `core_dep_seed` as `targetRel`), and NEVER from the flattened staged
  `target-code.sol` (or any `CODE_PATH`-style flat copy) — that flat copy exists only for the #1471 link-gate's
  textual check, not as a compilable import inside the harness's Foundry repo. It is a flat string-literal
  addition inside the same `vaultRoute`/`active`-gated `!active => ""` builder, so it is **default-off
  byte-identical** when `--core-dep-harness` is off / the target is non-yearn; `verdict_of`, the `INVARIANT|`
  marker, and the #1471 `--require-import`/`--require-contract` gate are untouched. `demo-invariant-core-dep.sh`
  source-guards the new import-path-pin directive text (target imported from its in-repo `../src/` path, NOT from
  `target-code.sol`) and the updated `core_dep_seed` signature.
- **Vault harness directive: complete the first-depositor catch recipe (profitMaxUnlockTime(0) + wei-scale actions + relative victim-fairness tolerance)**
  (#1755, M4). M1–M3 make the autonomous pipeline GENERATE the right harness structure (real `TokenizedStrategy`,
  victim-fairness invariant, donation Handler, health-check disabled), but a hand-reconstruction of the exact
  autonomous catch on the etched real `TokenizedStrategy` (each step confirmed live) showed the first-depositor
  bug still does not fire for three precise reasons, each with a proven fix. This adds the remaining three
  directive-string additions to `auditor/agents/invariant-prover.ag`, all inside the existing
  `vaultRoute`/`active`-gated builders (default-off byte-identical; `verdict_of`, the `INVARIANT|` marker, and
  the #1471 `--require-import`/`--require-contract` gate untouched):
  (b) **`setProfitMaxUnlockTime(0)`** — the missing management precondition. Without it a donation realized via
  `report()` is LOCKED and unlocks linearly over the profit-unlock window, so `totalAssets` never inflates for
  share pricing and the invariant always holds (the CLEAN we kept hitting). `core_dep_seed` now instructs the
  Handler (as management, the deployer) to also call `setProfitMaxUnlockTime(0)` — a `public onlyManagement`
  function on `TokenizedStrategy` — so seed 1 wei + donate 1 wei + `report()` yields `totalAssets == 2,
  totalSupply == 1` (a 2x share price), the exact share-inflation boundary.
  (c) **Wei-scale attack actions** — the rounding theft is MAXIMAL at the `totalAssets=2 / totalSupply=1`
  boundary (proven: a victim depositing 3 wei redeems only 2, 33% robbed) and vanishes at large scale.
  `core_dep_seed` now requires the first-depositor attack actions (attacker seed, attacker donation, victim
  deposit) to include TINY WEI-SCALE amounts bounded like `[1, 1000]` in ADDITION to realistic sizes — the
  handler's realistic `1e15..1e21` victim range and `1..1e24` donation range miss the rounding entirely.
  (d) **Relative victim-fairness tolerance** — the generated invariant's absolute `+1e12` dust is coarser than
  the wei-scale loss and never trips. `victim_fairness_invariant_prompt` now asks for a RELATIVE tolerance
  (integer-math `require(redeemable * 10000 >= deposited * 9900)`, a 1% band, multiply-both-sides form) instead
  of an absolute dust, so the PROPORTIONAL theft trips at ANY scale (`2 < 3 * 0.99`); per-actor victim tracking
  is unchanged, only the tolerance form. `demo-invariant-core-dep.sh` source-guards the new
  `setProfitMaxUnlockTime(0)` + wei-scale directive text; `demo-invariant-vault-first-depositor.sh` source-guards
  the relative-tolerance assertion (and that the absolute-dust form is gone).
- **Vault harness directive: disable the profit-limit health check for the first-depositor attack**
  (#1755, M3). With M1 (real `TokenizedStrategy` staging) + M2 (victim-fairness invariant + donation Handler)
  the generated yearn-v3 harness is structurally correct, but a live forensic trace showed the first-depositor
  attack still cannot fire: yearn strategies inherit `BaseHealthCheck`, whose `report()` runs a PROFIT-LIMIT
  health check that reverts with reason `healthCheck` when a donation is realized as an outsized profit. Because
  the donation-realizing `report()` reverts, `totalAssets` never inflates and the first-depositor /
  share-inflation bug is unreachable. This extends `core_dep_seed`'s existing "open deposits as management"
  directive in `auditor/agents/invariant-prover.ag` with one instruction: right after `allowDeposits()`, the
  Handler — which is the strategy's `management` (the deployer) — MUST ALSO call `setDoHealthCheck(false)` so the
  donation-realizing `report()` succeeds and `totalAssets` inflates. It is a flat string-concat addition to the
  same `!active => ""` directive, so it is **default-off byte-identical** when `--core-dep-harness` is off /
  the target is non-yearn, and it touches ONLY the generation prompt — `verdict_of`, the `INVARIANT|` marker,
  and the #1471 `--require-import`/`--require-contract` gate are unchanged. `demo-invariant-core-dep.sh`
  source-guards the new `setDoHealthCheck(false)` + `healthCheck`-gate directive text.
- **Vault first-depositor victim-fairness invariant + donation Handler routing for yearn-v3 targets**
  (#1755, M2). With M1 the deep-hunt harness now runs the REAL `TokenizedStrategy` share path, but the GENERATION
  still misclassified the target: `run-zone-hunt.sh`'s `dominant_class()` collapses yearn's zone
  `[C15,C10,C11,C2]` to **C10**, so `invariant-prover.ag` saw `TARGET_CLASS=C10` →
  `class_to_keyword("c10")=="lend"` and the VAULT branches of the generation selectors never fired on the very
  target whose money-tier bug (the yearn-ybold H-1 first-depositor / share-inflation High) is a vault
  first-depositor. This fixes it INSIDE the prover (leaving `dominant_class()` byte-identical) with an
  EFFECTIVE-CLASS override gated on M1's `vaultRoute`: `effective_class(targetClass, vaultRoute)` returns `"C11"`
  on the vault route and feeds `effClass` into the GENERATION selectors ONLY — `action_checklist_hint`/
  `action_checklist_prompt` (the #1725 direct-donation + first-depositor micro-deposit + ≥2-actor checklist),
  `metamorphic_relation_prompt` (the #1726 round-trip/monotonicity relation), and `recall_pattern` (→
  `invpat:invented:C11`, the #1733 first-depositor seed). A new `victim_fairness_invariant_prompt()` weaves the
  #1724 `inv_victim_not_robbed` SHAPE — for every honest depositor, redeemable value
  (`shares * assetBalance / totalShares`) must stay `>=` deposited − dust, asserted with a plain
  `require(redeemable + dust >= deposited)` and per-victim `(deposited, shares)` tracking in the Handler — into
  `sharedScaffold`, gated on `vaultRoute` and re-injected each compile-repair round. **The FUZZER stays the SOLE
  verdict:** `effClass` touches ONLY the generation prompt; `verdict_of`, the `INVARIANT|` marker, `emit`,
  `learn`, `persist_pattern`/`persist_teeth`/`persist_corpus`, and the #1471 `--require-import`/
  `--require-contract` gate all keep `targetClass`. **Default-off byte-identical:** off the vault route
  (`INV_CORE_DEP` empty or a non-yearn target) `vaultRoute` is false, `effClass == targetClass`, and
  `victim_fairness_invariant_prompt` returns `""`, so the generation prompt is byte-identical to before.
  `demo-invariant-vault-first-depositor.sh` (registered in `colony-lint`) source-guards the override, the four
  `effClass` selector call sites, the victim-fairness shape + vault-gating + `""`-when-inactive, the
  untouched-`targetClass` verdict/marker/#1471/persist path, and the no-new-env contract.
- **Core-dependency harness-gen: deploy the REAL yearn-v3 `TokenizedStrategy` singleton for the deep-hunt**
  (#1755, M1). On yearn-v3 targets the ERC4626 share logic (deposit/mint/withdraw/redeem, price-per-share,
  totalSupply/totalAssets) does NOT live in the target contract — the target inherits `BaseStrategy`, which
  delegatecalls a SINGLETON `TokenizedStrategy` at the hard-coded constant
  `0xD377919FA87120584B21279a491F82D5265A139c`. A harness that etches a zero-returning stub there makes every
  share call a no-op, so the money-tier first-depositor / share-inflation bug (the yearn-ybold H-1 High) is
  structurally unfuzzable. This adds a default-off `--core-dep-harness` flag to `run-invariant-hunt.sh` that,
  ONLY when the target source carries the yearn-v3 signal (`TokenizedStrategy`/`BaseStrategy`) AND the real
  singleton is located inside the staged repo copy (`lib/tokenized-strategy/src/TokenizedStrategy.sol`, with a
  `find … -print -quit` fallback), threads `INV_CORE_DEP="<abs path>:TokenizedStrategy:0xD377…9c"` into the
  prover (appended to the `exec.env_passthrough` allowlist). `run-zone-hunt.sh` forwards the flag verbatim into
  both deep-hunt invocations. `auditor/agents/invariant-prover.ag` reads `INV_CORE_DEP`, and on `vaultRoute`
  (coreDep staged AND the yearn-v3 signal fires) weaves a `core_dep_seed` into `sharedScaffold` (so it re-injects
  on every #1073 compile-repair round) directing the model to DEPLOY the real singleton and `vm.etch` its runtime
  code at the constant address INSTEAD of a zero stub — the exact recipe proven by the M1.0 feasibility spike
  (`vm.etch` preserves the singleton's immutable `FACTORY` baked into runtime code; per-strategy ERC4626 storage
  lives at the strategy's own base slot under delegatecall, so deploying the target AFTER the etch initializes
  real share storage). **The FUZZER stays the SOLE verdict:** M1 only adds a `setUp()` deploy directive —
  `verdict_of`, the `INVARIANT|` marker, and the #1471 `--require-import`/`--require-contract` target-linkage gate
  are byte-untouched. **Default-off byte-identical:** with `--core-dep-harness` absent (or a non-yearn target
  under the flag) `INV_CORE_DEP` stays `""`, `vaultRoute` is false, `core_dep_seed` returns `""`, and both the
  generation prompt and the runner arg-construction are byte-identical to before. `demo-invariant-core-dep.sh`
  (registered in `colony-lint`) source-guards the whole wiring + the byte-identical guard + the untouched verdict
  contract, and when forge is present runs a distilled, yearn-lib-free ERC4626-behind-a-singleton fixture through
  the SAME etch recipe to pin real share accounting offline.
- **Complementary symbolic / bounded-model-checking oracle alongside the deep-hunt fuzzer** (#1732). The
  deep-hunt has a single oracle — Foundry's stateful fuzzer, which SAMPLES call sequences and so can MISS a
  value-conservation break on a rare path (#1716). This wires the ALREADY-SHIPPED SOUND gate
  `evm-harness/halmos-verify.sh` (Halmos symbolic execution + an SMT solver) in as a SECOND, INDEPENDENT oracle
  that runs over the SAME generated invariant test AFTER the fuzzer verdict, behind a default-off
  `--symbolic-oracle` flag (plus an optional `--symbolic-timeout <s>`) on `run-invariant-hunt.sh`. **The FUZZER
  stays the SOLE primary verdict:** the symbolic result is a SEPARATE `SYMBOLIC|<file:fn>|<verdict>` stderr
  marker (reusing `run-symbolic.sh`'s convention) + its own `## Symbolic oracle (complementary)` report section,
  and never reads or alters `$VERD`, the `INVARIANT|` marker, or `verified_findings.json`. The pass is ONE staged
  gate invocation (`cp` the gate into `$RUN/halmos-verify.sh`, then `sh "$RUN/halmos-verify.sh" --repo ... --target
  $INV_OUT --function $MATCH`) mapping exit `0→PROVED / 1→COUNTEREXAMPLE / 3→INCONCLUSIVE / *→HARNESS_ERROR` —
  NO `agentis` spawn, NO per-element `.ag` loop. It runs AFTER the primary `$REPORT` is written and BEFORE the
  #1731 replay block clobbers `test/`, so `$INV_OUT` is intact. **Tool-absence is a clean runner-side SKIP:**
  `halmos-verify.sh` itself exits 2 (harness/usage) when halmos/forge are absent — indistinguishable from a real
  harness error — so a `command -v halmos`+`command -v forge` guard SKIPs first (a SKIPPED report row,
  exit-neutral), and a fuzzer that generated no test (`$INV_OUT` absent) is likewise a SKIP, never a
  HARNESS_ERROR. `run-zone-hunt.sh` gains a thin pass-through of `--symbolic-oracle`/`--symbolic-timeout`
  forwarded verbatim to both deep-hunt invocations. **Zero `.ag` change:** `auditor/agents/invariant-prover.ag`
  is byte-untouched — halmos consumes the generated `invariant_*` directly via `--function`, so no dedicated
  spec is generated. **Default-off byte-identical:** with `--symbolic-oracle` OFF (the default) the runner and
  both `run-zone-hunt.sh` invocations are byte-identical to before. **Honest limitation (wiring only):** a
  no-argument `invariant_*` is symbolically executed with concrete `setUp()` state, so a `PROVED` here can be
  vacuous; the deep symbolic lift needs symbolic-argument `check_*` specs, which is a deferred generation concern
  (out of scope — this ships the WIRING, not a behavioural number). The behavioural confirmation (does symbolic
  catch value-conservation on rare paths the fuzzer misses) is a deferred live #1730 operator run. Source-guarded
  by new `demo-invariant-symbolic-oracle.sh` (wired into `colony-lint.sh`), which pins the default-off gate, the
  after-`$REPORT`/before-#1731 ordering, the staged-gate invocation, the exit→verdict map + the command-v SKIP
  guard, the fuzzer-stays-sole-verdict contract (no `verdict_of`/`final_verdict`/`$VERD`/`verified_findings`/#1471
  reference), the `SYMBOLIC|` marker + report section, the zone pass-through, the byte-untouched `.ag` anchors,
  and — under forge + agentis — the section-only-with-the-flag + primary-verdict-unchanged live contract.
- **Cross-run invariant ensemble / union replay** (#1731). Run-to-run variance (#1716) means a class that
  produced a good invariant on one run may produce nothing on the next, yet today only the WINNER's descriptor
  survives — every non-winning (but valid) hypothesis is discarded. This accumulates the UNION of ALL generated
  invariants (on a FINDING OR a CLEAN, not just the winners) and REPLAYS it against a fresh target cheaply, with
  NO extra LLM. Two roles, splitting the seed from the replay. **SEED** (`invariant-prover.ag`): a new
  `persist_corpus()` — a byte-for-byte-shaped sibling of `persist_teeth()` — writes the just-generated
  invariant's descriptor (the same `class::target::match-prefix` `psig` `persist_pattern`/`persist_teeth` use)
  into a NEW lowest-precedence `invpat:corpus:<class>` memo, on a FINDING OR a CLEAN (two separate `if` blocks —
  single-assignment `.ag` has no `||`), in ONE O(1) `memo_write` per generation (no growing-set walk, no
  per-element `.ag` loop). It early-returns when `INV_CORPUS` is empty (default-off ⇒ byte-identical, the same
  guard idiom as `run_mutant_kill`'s `len(mk)==0`), and is placed AFTER the `INVARIANT|` marker + `persist_pattern`
  + `persist_teeth`. `recall_pattern()` gains `invpat:corpus:` as its WEAKEST tier — precedence FINDING
  (`invpat:latest:`) > teeth-clean (`invpat:teeth:`) > invented (`invpat:invented:`) > cross-run corpus
  (`invpat:corpus:`) — so a proven FINDING is never overridden. **REPLAY** (`run-invariant-hunt.sh`, pure SHELL):
  a new `replay_corpus()` keeps the full generated test SOURCE per class under `--pattern-store/corpus/<class>/`
  and, under a default-off `--replay-corpus` flag, loops that BOUNDED set — re-running the SAME staged
  `forge-invariant.sh` gate per file PLUS the identical #1471 `--require-import`/`--require-contract` link args in
  pure fresh-deploy mode, mapping exit 1→FINDING/0→CLEAN/else→HARNESS_ERROR — and appends one row per replay to a
  `## Corpus replay (union of prior hypotheses)` report section. It is pure shell over a bounded set: NO
  `agentis` spawn per replay, NO per-element `.ag`, NO LLM. Accumulation is content-addressed (`cp` the
  invariant to `<sha256>.t.sol` ⇒ an identical hypothesis is stored once = dedup) and pruned to `--corpus-max`
  most-recent entries (default 16), bounding BOTH storage and replay cost. `INV_CORPUS` joins the
  `exec.env_passthrough` allowlist and is threaded as `INV_CORPUS=1` into the `agentis go` env block ONLY when
  both `--replay-corpus` and `--pattern-store` are set; `bridge_invpat`'s `^invpat:` matcher already ferries the
  new namespace across `--pattern-store`, no bridge change. `run-zone-hunt.sh` gains a thin pass-through of
  `--pattern-store`/`--replay-corpus`/`--corpus-max` forwarded verbatim to both deep-hunt invocations (absent ⇒
  byte-identical arg lists). **The FUZZER stays the SOLE verdict** and the #1471 gate is untouched: a replay
  authored for a different contract is scored HARNESS_ERROR by the same fuzzer path, never a false verdict.
  **Default-off byte-identical:** with `--replay-corpus` OFF and `INV_CORPUS` empty the pipeline is byte-identical
  to before (mirrors #1728's `MUTANT_KILL` / #1726's `--deep-hunt-aux-max 0`). **Measurement:** the union-recall
  lift is measured out-of-CI via #1730's generation-recall over an ON-vs-OFF `--replay-corpus` run — a deferred
  operator A/B; this ships the WIRING, not a recall number. Source-guarded by new
  `demo-invariant-corpus-replay.sh` (wired into `colony-lint.sh`), which pins the after-marker placement, the
  FINDING-AND-CLEAN accumulation, the one-memo/no-loop discipline, the recall precedence, the
  verdict/marker/#1471-untouched contract, the default-off guard, the staged-gate replay, the content-addressed
  dedup + `--corpus-max` prune, and — under forge + agentis — ≥2 replay rows with the cap enforced.
- **Mutant-kill teeth-signal wired into the invariant learning loop** (#1728). The deep-hunt learned from
  a FINDING (`persist_pattern` → `invpat:latest:<class>` → `recall_pattern`) but a CLEAN dead-ended without
  learning: a TOOTHLESS invariant (holds because it is too weak to break) and a CREDIBLE one (holds because
  the target really is clean under a KILLING invariant) were indistinguishable, so the loop learned nothing
  from either. This wires the #1724 mutant kill-set in as an ACCEPTANCE/LEARNING signal. STRICTLY AFTER the
  fuzzer verdict is finalized and the `INVARIANT|` marker is printed, on a CLEAN only, `invariant-prover.ag`
  makes ONE `exec sh` call to `evm-harness/mutant-kill.sh --class <TARGET_CLASS> --invariant <INV_OUT>` (every
  dynamic value `shell_escape()`d; mutant iteration lives inside `mutant-kill.sh`, no per-element `.ag`
  recursion), parses the `kill ratio: K / M killed` line with FLAT builtins (`index_of`/`regex_capture`), and
  classifies the CLEAN into **credible** (K≥1: the invariant KILLED the class mutants → `learn()` outcome
  `partial` + tag `credible-clean` + persist to a NEW `invpat:teeth:<class>` recall tier), **toothless** (K==0
  with a genuine survivor: tag `toothless-clean`, an observability `INVPAT-TEETH|…|toothless|…` line, NOT
  persisted), or **unmeasured** (SKIP without forge / gate error / no `kill ratio:` line / all mutants ERROR →
  today's FINDING-only behaviour, byte-identical). `recall_pattern` gains the `invpat:teeth:` tier BETWEEN
  `invpat:latest:` (FINDING) and `invpat:invented:` — precedence FINDING > teeth-clean > invented — so a
  credible-clean pattern is recallable when no FINDING exists yet without ever overriding a proven FINDING.
  `run-invariant-hunt.sh` stages `mutant-kill.sh` + the `mutants/` tree into the rundir (self-contained: the
  harness resolves `forge-invariant.sh` relative to its own dir, which becomes `$RUN`) and threads `MUTANT_KILL`
  on the `exec.env_passthrough` allowlist + the env block; `bridge_invpat`'s `^invpat:` matcher already carries
  the new namespace across `--pattern-store`, no runner-bridge change. **The FUZZER stays the SOLE verdict**:
  `verdict_of`, `final_verdict`, the `INVARIANT|` marker, the #1471 `--require-import`/`--require-contract`
  gate, and the FINDING → `invpat:latest:` path are all byte-untouched; the teeth-gate is strictly ADDITIVE and
  a SKIP/error/unmeasured ratio never blocks, crashes, or alters the verdict. **Known limitation:** #1724's
  kill-set is per-CLASS canonical (not per-target), so the credible-clean reward fires on class-canonical /
  `HANDLER_FIXTURE`-seeded invariants and degrades to `unmeasured` on arbitrary real targets (a live-generated
  invariant imports the real target, not the class exemplar, so the class mutants all ERROR → interface
  mismatch). The wiring is the deliverable; the live rare-recall lift is a deferred operator A/B and per-target
  mutation is a future lever. Source-guarded by new `demo-invariant-teeth-learning.sh` (wired into
  `colony-lint.sh`), which pins the ONE-exec/shell_escape discipline, the after-marker placement, the
  verdict/marker/#1471-untouched contract, the recall precedence, and — under forge — the exact C-erc4626
  `kill ratio: 1 / 1` (credible) vs `0 / 1` (toothless) thresholds `teeth_of()` keys on.
- **Metamorphic-relation invariants + multi-contract deep-hunt wiring** (#1726). Two independent levers
  for the stateful-invariant deep-hunt, both landing default-safe. **M1 (metamorphic relations,
  prompt-only):** `invariant-prover.ag` gains a flat class-keyed string builder
  `metamorphic_relation_prompt()` (reusing the existing `class_to_keyword(to_lower())` normalizer +
  anchored `class_is`, no new env var, no runner change) that appends a `=== METAMORPHIC RELATIONS
  (alternative property shape) ===` block to `sharedScaffold`. It frames the ONE deep invariant as an
  OPTIONAL round-trip / commutativity / monotonicity relation — an ALTERNATIVE shape for the SAME single
  `invariant_*` property, NEVER a second property — which is often easier to state correctly than an
  absolute predicate and targets the rounding-direction / value-leak / inflation class where rare Highs
  live. Per-class menus: vault/ERC4626 (`redeem(deposit(x)) <= x` round-trip, deposit commutativity,
  share-price monotonicity), lending/CDP (collateral + borrow→repay round-trips), staking (stake→unstake
  round-trip, claim idempotence), AMM (swap `A->B->A` no free value, add/removeLiquidity round-trip, swap
  commutativity), reentrancy (reentrant∘outer == sequential), plus a generic put/take round-trip default.
  **M2 (multi-contract deep-hunt, runner wiring):** `run-zone-hunt.sh` gains a `--deep-hunt-aux-max <N>`
  flag (**default 0 = OFF = byte-identical** single-target behaviour) that threads a value-custody zone's
  SECONDARY co-custody `.sol` into the deep-hunt as `run-invariant-hunt.sh --aux` — REUSING the already
  shipped #1075/#1077 composable-fresh multi-contract engine verbatim (`INV_AUX` → `compose_fresh_seed` →
  multi-register `targetContracts()` → the both-real HARNESS_ERROR enforcement). STAGE 4.5 emits the
  co-custody contracts as an optional 4th TSV `AUXFILES` column only when aux-max > 0; at the default 0 the
  enumerated rows and both `$INVHUNT` invocations are byte-identical to before. The #1471 linkage gate
  (`--require-import`/`--require-contract`) still fires on the PRIMARY target and the both-real safety
  protects the aux contracts — M2 touches NO `.ag` / gate code. Both legs are source-guarded by new
  `demo-invariant-metamorphic.sh` (M1) and `demo-invariant-multi-target.sh` (M2), wired into
  `colony-lint.sh`. Behavioural rare-recall validation (the live yearn A/B) is deferred to #1730.
- **Adversarial/multi-actor Handler action checklist for the deep-hunt fuzzer** (#1725). The #1716
  generation−verified A/B isolated a DELTA gap: the LLM names a plausible deep invariant but the
  Handler it writes never gives the fuzzer the ADVERSARIAL action space needed to actually break it
  (no direct-donation action, only one actor, no liquidation/sandwich/reentrancy sequence) — the
  fuzzer can only search sequences over the actions the Handler exposes. `invariant-prover.ag` gains
  two flat string-building functions, `action_checklist_hint()` (a one-line hint woven into the
  Handler's Solidity comment) and `action_checklist_prompt()` (the fuller MUST-include checklist
  appended to `sharedScaffold`'s generation prompt), both keyed off the existing `TARGET_CLASS` (no
  new env var, no new `prompt()` call, no runner change). Five protocol-CLASS branches, ordered
  most-specific-first: vault/ERC4626 (direct-donation + first-depositor + multi-actor),
  lending/CDP (multi-borrower + liquidation sequence + bounded price-oracle move), staking
  (multi-staker + reward-timing/vesting-sandwich), AMM (sandwich + direct-donation), reentrancy
  (a callback-receiver actor re-entering a sensitive function) — plus a generic multi-actor +
  direct-external-perturbation default so an unclassified target still benefits. The verdict/marker/
  #1471 gate (`verdict_of`, the `INVARIANT|<file:fn>|<verdict>` marker, and the
  `--require-import`/`--require-contract` target-linkage args) are untouched — this is prompt
  steering only, never a hard gate. `demo-invariant-handler-actions.sh` source-guards the wiring, all
  5 per-class checklists (plus the default), the untouched verdict/marker/#1471 contract, and that
  `TARGET_CLASS`'s `exec.env_passthrough` entry got no new sibling; wired into `colony-lint.sh`.
  **Out of scope**: harness compile robustness (#1720), which invariant is generated (#1722),
  multi-CONTRACT composability across targets (#1726, the explicit multi-actor-within-one-target vs.
  multi-contract follow-up). The behavioural question — does a richer Handler action space actually
  shrink the generation−verified DELTA — is deferred to a live operator re-hunt outside CI; this
  change ships the deterministic wiring only. The branch dispatch first normalizes the BARE taxonomy
  code the live-hunt pipeline actually feeds as `TARGET_CLASS` (`C1`..`C18`, e.g. `C10`/`C11`) onto its
  action class (`class_to_keyword` + anchored `class_is`, so `c1` never matches `c10`/`c11`/`c12`) —
  `C1`/`C11`→vault, `C10`→lending, `C12`→AMM, `C8`→reentrancy; ambiguous codes (rounding `C6`, oracle
  `C2`, access `C5`, …) keep the generic default. Without it the primary production path silently hit
  the default every time even though the descriptive-keyword branches were correct (#1742 QA).
- **Historical DeFi exploit-class pattern seeding** (#1733). A new curated, OFFLINE fixture,
  `auditor/methods/historical-exploits.md`, hand-authors 7 canonical, well-known PUBLIC DeFi
  exploit CLASSES — one entry per distinct `C1`/`C2`/`C5`/`C6`/`C8`/`C11`/`C16` taxonomy id from
  `bug-taxonomy.md` (no Code4rena/Immunefi scraping, no network, no protocol/client names). A new
  `seed-historical-patterns.sh` generalizes the single-line `--method-fixture` mechanism
  `run-autonomous-hunt.sh` already implements (parse a `METHOD|...` line, extract its class via
  the exact `cut -d'|' -f3 | cut -d',' -f1 | tr -d '[:space:]'` pipeline, `agentis memo set
  invpat:invented:<class> <line>`) from ONE line to N, so a fresh `--pattern-store` starts with a
  curated cold-start hint for every covered class instead of only whichever class a live
  invent-method run happened to propose. This writes into the SAME `invpat:invented:<class>`
  fallback slot `recall_pattern()` already consults when no `invpat:latest:<class>` (a prior real
  FINDING) has been persisted yet — no new memo namespace, and `invariant-prover.ag` /
  `seed-patterns.ag` / `run-autonomous-hunt.sh` are untouched. Because that memo key is one value
  per class (a later `memo set` overwrites), the fixture carries exactly one entry per distinct
  class, folding grouped sub-patterns (e.g. classic + read-only reentrancy under `C8`) into that
  one entry's free text rather than splitting them into colliding entries.
  `dark-factory/demo-historical-patterns.sh` source-guards the library's schema (exactly 7
  entries, 6 pipe-delimited fields each, no class-key collision) and the seeder's wiring
  (CI-safe, no LLM/forge), and — when `agentis` is on PATH — behaviourally seeds a throwaway
  pattern-store and reads a class entry back verbatim; wired into `colony-lint.sh`. Distinguishes
  from #1722 (per-target audit-doc seeding, a different free-text seed on the same prompt chain)
  and composes with #1724 (the mutant-kill validation harness, unrelated but complementary — a
  seeded generation hint and a mutant-kill discrimination check both raise invariant quality,
  independently). Out of scope: seeding `bugpat:exact`/`bugpat:struct` (needs real source code to
  hash, incompatible with the offline/no-scraping constraint); no version bump, no tag.
- **C5 access-control / init-upgrade / proxy class-assignment backstop for the breadth lens** (#1729,
  follow-up to the #1716 baseline whose rare generation-recall was 4/35). The breadth hunter can only NAME
  a non-conservation bug when the zone owning it is assigned the relevant class, so `run-discovery.sh` runs
  that `(zone x class)` cell — but `auditor/agents/zone-mapper.ag` had ZERO C5 coverage (its deterministic
  nets covered only the conservation-adjacent C6/C10/C11/C17), so access-control / init-upgrade / proxy
  zones (yearn-ybold / yieldoor / notional territory) never entered `scope.tsv` and their bugs were
  structurally un-NAMED. A deterministic net — `contains_access_control_signal()` (flat `index_of` on the
  pre-built `code` blob over body-level privileged/upgrade idioms: `onlyOwner`/`onlyRole`/`_checkRole`/
  `_checkOwner`/`hasRole`/`AccessControl`, and `_authorizeUpgrade`/`_disableInitializers`/`reinitializer`/
  the OZ-upgradeable `__Xxx_init` chain/`UUPSUpgradeable`/`ERC1967`/`StorageSlot`) + `apply_access_control_
  backstop()` — folds `C5` into the class CSV through `apply_backstop`, exactly mirroring the shipped
  #1681 (C10/C11) / #1698 (C6/C17) net idiom (single-assignment `let` chain, `force_include`, before
  `apply_fitness_reorder`). A best-effort `ACCESS-CONTROL / INIT-UPGRADE / PROXY DETECTION RULE (C5)` prompt
  paragraph steers the LLM; the net is the deterministic guarantee. An unconditional `ACCESS-CTRL|<id>|<bool>`
  diagnostic line (same trailing-line-scrape channel as #1713's `CUSTODY|`) makes the signal observable +
  offline-testable under the mock backend. No per-element `.ag` recursion (O(1) in zone size, well under the
  `cb_per_tick` cap), so substrate purity holds. **#1740 narrowing:** the `_init(` and `AccessControl`/
  `hasRole(` sub-signals were bare substrings over-firing on a plain non-upgradeable `_init(` helper and a
  read-only adapter merely querying another contract's role; both now require declaration/upgradeable-chain
  anchoring — `_init(` is gated behind a compound-AND on an OZ-upgradeable base signal
  (`UUPSUpgradeable`/`Initializable`/`ERC1967`), and `AccessControl`/`hasRole(` require an `is AccessControl`
  inheritance-declaration form — mirroring this file's existing `has_value_moving_function` + `has_amount_
  deduction` compound-AND idiom and the #1681 `IPool` -> `IPoolAddressesProvider` narrowing precedent. The
  deep-hunt invariant path, the refuter, and `bench/corpus-bench/generation-recall.sh` are UNCHANGED — the
  before/after is a live operator re-hunt of the corpus rare-set against the #1716 baseline. Pinned by the
  CI-safe source-guard + mock-backend behavioural block in `demo-map-zones.sh` (colony-lint block), mirroring
  the #1717 custody-path regression (now including the #1740 plainamm/reader narrowing fixtures).
- **Ground-truth-anchored generation-recall harness** (#1730, follow-up to the #1716 A/B that isolated
  invariant EXPRESSIVENESS as the deep-hunt limit). `bench/corpus-bench/generation-recall.sh` scores the
  GENERATOR's hypotheses against ground truth instead of the pipeline's post-confirmation verified findings,
  isolating the GENERATION step from fuzzer/refuter confirmation: it projects the two generation artifacts a
  corpus-bench run already stages — the breadth hunter's PRE-REFUTE candidates
  (`zone-hunt-out/discovery/discovery-results.merged.json`) and the deep-hunt lens's generated invariant
  targets (`zone-hunt-out/deep-hunt/*/run/invariant_*.log`, the `INVARIANT|<file:fn>|<verdict>` lines) —
  through a new stdlib-only adapter `bench/corpus-bench/hypotheses-to-leads.py` into the
  `{"verified":[...]}` lead shape the FROZEN `score-match.py` already consumes. The invariant's FUZZER VERDICT
  is IGNORED: a CLEAN invariant that still NAMES a GT bug's location counts toward generation-recall, so
  generation-recall > verified-recall exposes the #1716 expressiveness gap (a bug the pipeline NAMED but never
  confirmed) as an explicit generation-minus-verified DELTA. Generation-recall = (distinct GT `truth.tsv` rows
  location-first matched by >=1 generated hypothesis) / (total GT rows), stratified overall / by severity /
  by rarity (the rare tier is the headline capability number), threshold-independent at `--min-overlap` 2 and
  5. `--self-test` (default, CI-safe, no network/LLM/forge) projects `fixtures/generation-recall/` and asserts
  the byte-matched leads + scorecard and the generation-vs-verified delta; `--from-work <dir>` scores a real
  already-hunted corpus-bench work dir (a missing artifact is a logged skip, never a false 0). `score-match.py`,
  `extract-gt.sh`, `run-zone-hunt.sh`, `run-discovery.sh`, and `run-invariant-hunt.sh` are UNCHANGED — the
  adapter absorbs all projection logic, keeping the #1698/#1699 re-measurement scorer byte-identical (still
  pinned by `run-corpus-bench.sh --self-test`). Pinned by the CI-safe source-guard
  `demo-generation-recall.sh` (colony-lint block).
- **Mutation-guided invariant validation + mutant-kill acceptance-gate seam** (#1724, follow-up to the
  #1716 A/B that isolated invariant EXPRESSIVENESS, not plumbing, as the deep-hunt limit). A standardized,
  per-`TARGET_CLASS` MUTANT KILL-SET under `evm-harness/mutants/` (`manifest.tsv` index + `README.md`
  convention doc + two seeded classes: `C-erc4626` donation/inflation and `C-accounting` inverted-rounding
  accounting drift, each with a CLEAN base twin, a mutant, a GOOD invariant, and a TOOTHLESS control) plus a
  runnable harness `evm-harness/mutant-kill.sh`. The harness drives each fixture through the EXISTING
  `evm-harness/forge-invariant.sh` stateful-fuzzing gate and maps its exit to a kill result
  (`1=FINDING=KILLED`, `0=CLEAN=SURVIVED`, `2=HARNESS_ERROR=ERROR`), so the verdict is the FUZZER's, never an
  LLM opinion. Each class encodes a three-way DISCRIMINATION self-test: the good invariant KILLS the mutant
  AND SURVIVES the clean twin, while the toothless control SURVIVES the mutant — a "kill" therefore measures
  invariant expressiveness, not a rigged always-fire harness. `--self-test` iterates the manifest and asserts
  every verdict matches its expected column; `--class <c> --invariant <path>` is an offline quality metric
  (the deferred repair-loop acceptance gate's clean seam). The harness SKIPs cleanly (exit 0, `[SKIP]`)
  without `forge`, exactly like `demo-invariant-hunt.sh`. The FUZZER / `forge-invariant.sh` exit code, the
  `INVARIANT|<file:fn>|<verdict>` marker, and the #1471 target-linkage gate are byte-identical (unchanged);
  `invariant-prover.ag` is untouched. Pinned by the CI-safe source-guard `demo-invariant-mutant-kill.sh`
  (colony-lint block; live `--self-test` under forge is the operator's step). **Future work:** wiring the
  kill ratio into the deep-hunt repair loop as an explicit accept/reject acceptance gate (use-b) is deferred.
- **Audit-informed invariant seeding on the deep-hunt path** (#1722, follow-up to the #1716 A/B
  that isolated invariant EXPRESSIVENESS, not plumbing, as the limit). `run-invariant-hunt.sh`
  gains an optional `--audit-context <file>` (a target's spec / audit-scope doc); it is staged into
  the rundir and threaded to `invariant-prover.ag` as `INV_AUDIT_CONTEXT`. The prover reads it via
  the sandboxed `cat_file` and prepends a new `audit_seed()` block to the existing `generate_test`
  seed chain (alongside `recall_seed`/`fork_seed`/`compose_seed`), steering the LLM to formalize a
  protocol-SPECIFIC value-conservation property from the doc rather than only the generic per-lens
  default — reusing the existing `TARGET_CLASS`/`recall_pattern` scaffolding, not a parallel one.
  Purely additive: no `--audit-context` ⇒ empty seed ⇒ byte-identical prompt. The FUZZER
  (`evm-harness/forge-invariant.sh` exit code) stays the SOLE verdict; the `INVARIANT|` marker
  contract and the #1471 target-linkage gate are byte-identical. Pinned by the CI-safe source-guard
  `demo-invariant-audit-seed.sh` (colony-lint block; no live LLM/forge).
- **Corpus-bench → hunter fitness feedback loop** (learn + recommend wiring, #1711). The
  bench now closes the loop it only ever recorded before: `score-match.py` grew an additive
  `--per-lead` flag emitting one `LEAD<TAB><class><TAB><HIT|MISS>` line per verified lead
  (reusing the existing HIT/MISS matcher; default output stays byte-identical), and the new
  `bench/corpus-bench/bench-to-knowledge.sh` reads already-scored contests, computes per-class
  REAL-BUG precision (`hits / (hits + misses)`), normalizes the mixed `class=C3` / `C3` field,
  and imports it as agentis `hunt-fitness` KnowledgeEntry rows (`agentis knowledge import
  <json> --replace`; `--replace` is mandatory — re-import without it accumulates). `zone-mapper.ag`
  now CONSUMES that fitness via `recommend()` + `query_knowledge("hunt-fitness")`, reordering its
  emitted `ZONE|` class CSV so historically-real-bug classes hunt first (riding the existing
  post-`prompt()`/`apply_backstop` append mechanism — no shell reorder). `map-zones.sh` enables
  `knowledge.enabled` and imports `HUNT_FITNESS_JSON` (operator knob) after `agentis init`, before
  the zone loop. No fitness imported ⇒ identity (byte-identical prompt AND class CSV). MVP is global
  per-class fitness; per-protocol-type keying is a noted follow-up. agentis-core untouched
  (`learn`/`recommend`/`knowledge` primitives already exist). Pinned by the new
  `demo-hunt-fitness.sh` (all functional parts `--backend mock`).

### Fixed
- **Invariant-hunt harness generation + repair effectiveness** (#1720, follow-up to the #1716 A/B that
  showed the deep-hunt path burning its 4 repair rounds and still returning HARNESS_ERROR too often). The
  round COUNT is unchanged; each round is made more effective. `invariant-prover.ag` now (a) injects a
  compact, boilerplate-only CANONICAL COMPILING SKELETON (`harness_skeleton` → `sharedScaffold`) into the
  first-generation prompt and RE-INJECTS the same scaffold on every compile-repair round (threaded through
  `repair_instruction`/`repair_test`/`repair_step`/`repair_loop`), so a repair round re-anchors to the exact
  InvBase/`targetContracts()`/`_bound` boilerplate instead of drifting off it; the skeleton is boilerplate-only
  (generic `InvariantTest`/`Handler`, never a contract of the target's name) so it can never trip the #1471
  target-linkage/shadow gate; and (b) widens `error_excerpt` to keep the solc SOURCE context the model needs to
  locate a fault — the `-->` pointer, the numbered gutter lines, and the caret-underline lines — alongside the
  error text, with the line cap raised 80 → 160 and the byte cap 4000 → 6000. The fuzzer stays the sole verdict
  source; only generation/repair prompts change, and the both-real repair path (#1077) is untouched. Pinned by
  the new `demo-invariant-repair.sh` (source-guard, CI-safe, wired into colony-lint).

## [0.4.3] - 2026-07-16

**Requires:** agentis >= `1.22.7`

### Fixed
- **`map-zones.sh`'s big-contract function-slice now prioritizes value-moving/recovery
  functions over declaration order** (#1701). `fn_names(f)[:8]` used to truncate purely
  by file-declaration order, so any contract whose first 8 declared functions are
  admin/init setters starved the per-zone classification prompt of every
  value-moving/recovery function — reproduced live against dodo's `GatewayCrossChain.sol`
  / `GatewaySend.sol` / `GatewayTransferNative.sol`, where the old slice caught none of
  `withdraw*`/`onRevert`/`onAbort`/`onCall`. New `prioritize_fn_names(names, cap)` helper
  reorders (never drops/renames) the same `fn_names()` output: keyword-matched
  non-underscore names first, then keyword-matched underscore-prefixed names, then
  everything else, each group keeping its original declaration order — reusing
  `auditor/agents/zone-mapper.ag`'s #1698 C6/C17 value-moving/recovery vocabulary. The
  `fixtures/zone-map/contracts/liquidation/Liquidation.sol` fixture gained 4 admin
  setters ahead of `liquidate`/`redeem` so it actually reproduces the bug shape, and
  `demo-map-zones.sh` gained a regression assertion pinning `liquidate`/`redeem` into the
  liquidation zone's emitted slice. `zone-mapper.ag` itself (already fixed by #1702) and
  `slice-fns.sh` are untouched.
- **Refute gate no longer drops a real bug misassigned the wrong class** (#1699). When a
  candidate is REFUTED under its hunter-assigned class and its own code file trips a
  conservative compound-AND accounting signal (a value-moving function *declaration* AND an
  amount-deduction idiom, the vocabulary shared with `zone-mapper.ag`'s #1698
  `contains_accounting_signal`), `run-refute.sh` now re-invokes `refuter.ag` **once** under
  `C6` (accounting) and keeps the candidate only if it *independently* survives that second
  full hostile read. The retry can only convert REFUTED→REAL, costs at most one extra
  refuter call per signal-positive candidate, and is signal-gated (a candidate without the
  signal is never retried), so the false-positive rate is protected. `verify-findings.sh`
  now records the class the candidate SURVIVED under (e.g. `C6`) in `verified_findings.json`,
  not the mislabelled input class. Pinned by the deterministic offline demo
  (`demo-verify-findings.sh`). On dodo's live corpus, `GatewayCrossChain.sol:onCall` correctly
  trips the signal and is retried under C6, but does not yet recover in practice because the
  on-disk candidate's exploit text is itself truncated by an unrelated discovery-stage bug
  (#1705) — the mechanism is verified correct and ready to recover it once that lands.

## [0.4.2] - 2026-07-15

**Requires:** agentis >= `1.18.0`

### Fixed
- **`flat-cyborg-claude.sh` migrated from the burst-input flag combo to `--paste-input`**
  (#1694). Both host-run wrapper call sites (`dark-factory/flat-cyborg-claude.sh` and
  `tools/flat-cyborg-claude.sh`) dropped `--no-jitter --wrap-input 72` in favor of
  `--paste-input`: flat-cyborg's `--no-jitter` burst path chunk-times writes to defeat an
  Ink-style editor's paste-collapse heuristic, but for large prompts (a multi-KB
  DEVISE-shaped prompt can arrive empty, truncated, or garbled) this is best-effort and
  the failure is intermittent, per flat-cyborg PR #61 / commit `4ba2266`, which added a
  conservative `BURST_MAX_BYTES` guardrail on the burst path that now directs callers to
  `--paste-input` — the atomic bracketed-paste path — instead of risking a silent
  mis-delivery. `--paste-input` takes precedence over `--wrap-input` at dispatch, so the
  fold-based flag was already a dead no-op once paste wins; this change removes it along
  with the now-stale wrapper comments.
- **Decorated or truncated candidate locations from `hunter.ag` silently mis-tallied by
  `verify-findings.sh`** (#1691). Two real corpus-bench cases reproduced the failure:
  yearn-ybold's `src/.../StrategyAprOracle.sol@aprAfterDebtChange` code-file key never
  resolved on disk, so `run-refute.sh` silently dropped the candidate and
  `verify-findings.sh` tallied the drop identically to a genuine REFUTED verdict; crestal's
  truncated `src/BlueprintV3.sol:...:~(test/BlueprintV3.t.sol:...` location, with blank
  class/severity/exploit, landed a content-less REAL finding in `verified[]`. Fixed
  downstream-first: `verify-findings.sh` now derives the code file via `bare_codefile()`
  (strips a `~(...)` test tail, an `@func` suffix, and a stray trailing `(`) before
  resolving it, and routes a candidate whose normalized file doesn't resolve — or whose
  class/severity are blank (a truncation signal) — to a new distinguishable `ERRORED`
  status BEFORE the gate runs, never counted as refuted or verified. Adds
  `totals.errored` + an `errors[]` array (additive; existing `verified[]`-reading
  consumers are unaffected) so the rigorous-refutation count is
  `candidates - verified - errored`. `run-refute.sh` gets the same loud ERROR reporting
  for standalone callers; `hunter.ag`/`stateful-invariant-fuzz.ag` tighten the CANDIDATE
  output spec as defense in depth. `demo-verify-findings.sh` gains fixtures for both real
  shapes plus a `candidates == verified + errored + refuted` bookkeeping assertion.
- **Eight remaining content-transmitting `.ag` invocations under `dark-factory/` were
  missing `--grant-pii`** (#1690), the same PII-heuristic stall previously fixed for
  `hunter.ag` (#1675) and `zone-mapper.ag` — any call transmitting target source, scope,
  findings, PoCs, or persisted patterns to the model can trip the false-positive block on
  benign public Solidity/operator-authored text, and a blocked `prompt()` falls back to
  echoing the raw prompt as if it were the model's reply. Flagged every remaining site
  (the live pipeline, the persisted pattern-store readers, and the demo/mock harnesses)
  with `--grant-pii` plus a justification comment; the content-free `share-patterns.ag`
  call stays unflagged. Adds a pure-shell `colony-lint` guard requiring `--grant-pii` (or
  a `# no-pii: <reason>` waiver) on every `go <name>.ag --enable-exec`/`--enable-eval-ag`
  invocation under `dark-factory/` — matching the direct, `GO=(...)`-array, and
  heredoc-emitted-runner forms — so a fourth rediscovery of this bug class fails CI
  instead of surfacing live on a real hunt.

## [0.4.1] - 2026-07-15

**Requires:** agentis >= `1.18.0`

### Fixed
- **`run-discovery.sh` invoked `hunter.ag` without `--grant-pii`** (#1675), unlike every other
  gate/agent invocation in this colony (`demo-scope-gate.sh`, `demo-impact-gate.sh`,
  `run-gate-agent.sh`, etc.). A hunt cell's prompt (protocol source + scope brief + taxonomy)
  routinely contains hex addresses/hashes that false-positive-trip the PII heuristic; when the
  `prompt()` call was blocked, a downstream fallback echoed the raw PROMPT TEXT as if it were the
  model's output, and the `CANDIDATE|` line-grep matched the format-instruction EXAMPLE line
  embedded in the prompt itself — surfacing fabricated "candidates" made of literal placeholder
  tokens (`<file:function:line>`, `<class=C1>`, ...) instead of real analysis. Found live on a
  real Immunefi hunt. Fixed by adding `--grant-pii` to the hunter invocation, matching every
  sibling script's convention (prompt content here is public open-source Solidity + an
  operator-authored scope brief — never real PII).

## [0.4.0] - 2026-07-14

**Requires:** agentis >= `1.18.0`

### Documentation
- **Doc sweep for the target-selection front-end** (#1609/#1612, epic #1611). Reflected the intake funnel
  (`run-immunefi-intake.sh --live` + `audit-history-probe.sh`) and zone-mapping (`map-zones.sh` +
  `zone-mapper.ag`) in the top-level `README.md` federation row and the repo `CLAUDE.md` project overview
  (dark-factory is EVM + Solana/Anchor, not Solana-only); added the `zone-mapper.ag` row to the auditor
  colony `README.md` agent table and corrected the auditor agent count (22 → 24 agents, after `brief-writer.ag`
  landed alongside it in the same milestone).

### Added
- **`bench/corpus-bench/` — score the pipeline against REAL concluded Sherlock contests, not just a synthetic
  fixture.** Sibling of the fixture-based `run-capability-bench.sh` (#1490): `corpus.tsv` manifests 8 concluded
  contests (132 accepted High/Medium findings total — no code or findings re-hosted, only GitHub slugs +
  fetch/extraction logic); `extract-gt.sh` parses each judging repo's compiled `README.md` report
  (`# Issue H-1: <title>` / `## Found by <watsons>`) into `truth.tsv`, using the watson-handle count as a
  **rarity** signal (1-2 rare, 3-8 mid, 9+ consensus); `run-corpus-bench.sh` orchestrates fetch → GT-extract →
  the REAL federation (`run-zone-hunt.sh`, a real LLM backend) → scoring via the same `novelty-gate.sh` overlap
  oracle `run-capability-bench.sh` uses, reporting recall overall, by severity, and by rarity tier — flat
  recall alone hides that consensus bugs are the easy part. Verified leads matching no truth row are reported
  as `unmatched_leads` for manual triage, never auto-claimed as novel. Default (no-flag) action is a
  deterministic `--self-test` (extract-gt.sh vs a bundled fixture) — CI-safe, wired into `colony-lint.sh`; the
  real `--live` measurement (network + a real backend) is operator-run only.
- **`watch-competitions.sh` — CodeHawks as a THIRD keyless channel** (#1643). Adds CodeHawks
  (`codehawks.cyfrin.io/contests`) alongside the shipped Sherlock + Cantina channels, correcting the issue's
  premise: CodeHawks is **NOT** API-key-gated and needs **NO Playwright/browser/node**. The `/contests` page is
  server-rendered SvelteKit that embeds the keyless `competitions.getCompetitions` tRPC response in a
  `data-sveltekit-fetched` script block, so a plain `curl -A "Mozilla/5.0"` + `json.loads` returns every
  contest. New `--codehawks-from <file>` (offline hatch) / `--codehawks-url <url>` flags feed a defensive
  `codehawks` branch in the one shared normalizer. There is **no status/phase enum** in the embed, so
  submissions-open is **date-derived**: a contest surfaces only when `startDate <= today < endDate` AND
  `finalised == false` AND `inviteOnly == false`; upcoming (`today < startDate`), judging/appeals
  (`today >= endDate`, even with a future `appealEndDate`), finalised, invite-only, and undatable contests all
  drop. Dedup key `codehawks:<urlSlug>`; scope repo from the list `githubUrl`; the raw `reward+currency` rides
  in `scope_hint` as a `prize_label` (e.g. `7.25eth`/`20000usdc`) since `currencyUsdRate` is untrusted. The
  whole CodeHawks extraction is wrapped in try/except so any embed drift contributes ZERO records and never
  disturbs the Sherlock/Cantina channels — the shared record, ledger, scoring, 5-column TSV emit, and SKIP
  contract are unchanged and reused (Sherlock/Cantina behaviour is byte-identical). `demo-watch-competitions.sh`
  gains offline §4/§5 cases (relative-to-today fixture dates so the phase assertions never rot) proving
  open-surfaces / upcoming-dropped / judging-with-future-appeal-dropped / finalised-dropped / invite-dropped /
  idempotent-re-run / garbage-HTML-degrades / three-channel-coexistence + graceful-degrade; the untouched §1–§3
  Sherlock/Cantina assertions are the zero-regression guard. READ-ONLY, NEVER-SUBMIT; only Code4rena remains
  out of scope.
- **Integration-seam / composability hunt LENS — a first-class `C15` bug-class** (#1644, epic #1611).
  Formalizes the ad-hoc integration-seam lens (validated on recent hunts) as THREE additive pieces over the
  shipped M1/M2 zone-split machinery — no new agent. (1) `auditor/bug-taxonomy.md` gains a
  `## C15 — Integration-seam / composability` class in the standard `hits/hunt/breaks/sev/seen` format,
  encoding six heuristics: asset/balance mis-accounting across the integration (a mispriced share = theft —
  the ERC4626 share-price-vs-real-assets invariant across the boundary, the top seam); the new/exotic-adapter
  under-audited tail; FIND THE GLOBAL VALUE-CONSERVATION BACKSTOP FIRST (a withdraw-invariant + op-type lock +
  slippage cap degrades a single-adapter bug to a REVERT — the lens pays off only where per-adapter
  correctness is the ONLY barrier OR the code is FRESH); cross-integration composition (flashloan via adapter
  A → manipulate a position priced by adapter B → extract; check for an op-type lock); scope discipline
  (attack the target's OWN integration code, not the integrated protocol — the latter is out-of-scope-by-trust);
  and freshness synergy (an amplifier on fresh integration-heavy targets, not a way to crack a mature hardened
  one). (2) `auditor/agents/zone-mapper.ag` gains a PROMPT-ONLY detection rule (no new `exec sh`/builtin logic,
  substrate-pure) that tags a zone `C15` when its contracts are named `*Adapter`/`*Guard`/`*Bridge`/`*Oracle`/
  `*Wrapper`/`*Router`/`*Strategy` OR import/call an external protocol's interface. (3)
  `auditor/agents/brief-writer.ag` gains a conditional `seamClause` (mirrors the existing
  `residualClause`/`boundaryClause` additive pattern) that appends a dedicated "Integration-seam hunt guide"
  subsection when the zone carries the comma-bounded `,C15,` token; when C15 is ABSENT the clause is the EMPTY
  STRING, so a non-integration zone's brief is **byte-identical** to before (zero regression). A new offline,
  deterministic `demo-seam-lens.sh` (wired into `colony-lint`) over a dedicated `fixtures/seam-lens/` tree
  (integration contracts + a plain-token negative control) pins the C15 round-trip into `scope.tsv`, the
  six-heuristic seam subsection on C15 briefs, the seam-free plain-token control, and the source guards — it
  touches none of the shared `fixtures/zone-map/` tree so the M1/M2/M3/M4/M5 demos stay byte-identical.
  Empirical basis stays generic (oracle-integrated AMMs, ERC4626 adapter vaults, multi-adapter pool managers).
  Honest caveat: the lens is triage/focus machinery — it improves where the hunt LOOKS; hunt DEPTH stays
  LLM-backend-gated. READ-ONLY, NEVER-SUBMIT (nothing changes the never-submit contract).
- **`watch-competitions.sh` — audit-COMPETITION freshness watcher** (#1635). A NEW standalone, read-only,
  keyless watcher — the competition-side mirror of the shipped #1623 `watch-new-listings.sh` — that scans TWO
  keyless competition feeds (Sherlock `mainnet-contest.sherlock.xyz/contests` and Cantina
  `cantina.xyz/api/v0/competitions`) and surfaces a live audit competition ONCE, the first run it is seen. The
  shell layer does all fetching (curl, unauthenticated GETs only; Sherlock paginated `?page=1..--max-pages`,
  default 5) and ONE embedded `python3` block normalizes BOTH schemas into one common record + filters + emits
  — never shell JSON. LIVE filter: Sherlock `status == RUNNING AND not private` (future `ends_at` when it
  parses); Cantina `status NOT IN {complete, escalations_ended, closed, judging, ended, completed}` (allowlist-
  by-exclusion). The dedup key derives from LIST-endpoint fields ONLY (`sherlock:<numeric id>` /
  `cantina:<url-slug-or-uuid>`) so it never mutates between runs; a first-seen self-dedup ledger
  (`seen-competitions.txt`) means two runs over the same input yield zero new alerts. Emits the SAME 5-column
  TSV `run-batch.sh --queue` consumes (`score<TAB>key<TAB>url<TAB>title<TAB>scope_hint`, separate queue file
  `competitions.queue`), score = prize (log-scaled) + freshness, `scope_hint` packing platform/status/prize/
  kyc/ends/repo. `--sherlock-from`/`--cantina-from` are offline hatches; a partial outage on one platform's
  live fetch never suppresses the healthy one; no usable input from either / no `python3` -> `[SKIP]` + exit 0
  with the ledger + queue byte-for-byte untouched. READ-ONLY, NEVER-SUBMIT. Purely additive — edits none of the
  funnel scripts. `demo-watch-competitions.sh` is the offline, dash-safe deterministic proof. CodeHawks
  (API-key-gated -> a Playwright/browser follow-up) and Code4rena (no clean keyless endpoint) are out of scope.
- **Close the loop — M4 verify integration + M5 capstone (CLOSES epic #1611)** (#1630). Two NEW standalone
  entrypoints that CHAIN the already-shipped M1–M3 + delivery scripts and EDIT none of them.
  - **`verify-findings.sh` (M4 — the M3→verify bridge).** Drives a verification gate over EVERY candidate in an
    M3 `discovery-results.json` and aggregates the CONFIRMED-only survivors into `verified_findings.json`
    (`{repo, gate, verified:[{subsystem, location, file, class, severity, exploit, poc_sketch, verdict,
    reason}], totals}`). Per candidate it derives a one-line gate manifest from the candidate's own fields and
    invokes the operator-selected gate AS-IS: `--gate refute` (DEFAULT — `run-refute.sh`, CONFIRMED = the `REAL`
    verdict), `--gate poc` (`run-poc.sh`, CONFIRMED = `POC|…|FINDING`), or `--gate symbolic` (`run-symbolic.sh`,
    CONFIRMED = `SYMBOLIC|…|COUNTEREXAMPLE`). It is **READ-ONLY** over `discovery-results.json` (never mutates
    it), has NO submit verb, and isolates each candidate — a gate that errors on one candidate is logged +
    skipped, an un-CONFIRMED candidate is dropped, and one bad candidate never aborts the batch.
    `demo-verify-findings.sh` is the offline deterministic proof (a fast refute stub through the `--agentis`
    seam): schema keys, CONFIRMED-only filtering (REFUTED dropped), the read-only invariant, a degrade, and
    never-submit.
  - **`run-zone-hunt.sh` (M5 — the capstone).** Chains the shipped entrypoints into ONE end-to-end autonomous
    zone-hunt: `map-zones.sh (M1) → gen-briefs.sh (M2) → per-zone run-discovery.sh (M3, per-zone `--only`/
    `--brief` loop → merge) → verify-findings.sh (M4) → per verified finding: run-audit-pass.sh →
    deliver-submission.sh`. Zones loop SERIALLY (the intra-zone `--jobs` is the only parallelism, so the M3 OOM
    cap is not stacked across zones). It EDITS none of the shipped scripts. **The never-submit HALT** is
    load-bearing: the capstone adds ZERO egress and reuses two baked-in gates — `run-audit-pass.sh` terminates
    at `PENDING-HUMAN-REVIEW` (never a submit; a blocked finding writes no draft) and `deliver-submission.sh`
    REFUSES (exit 3) any draft lacking the `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW` marker and only STAGES to a
    local drop-dir (deliver already pages the operator's OWN Slack internally, so the capstone never calls
    `notify-submission.sh` — no double-page). Per-finding error propagation: a finding whose pass hard-fails is
    logged + skipped, the batch finishes, and the capstone exits 0. Offline via `--map-fixture`/
    `--brief-fixture`/`--pass-fixture` + the `--agentis` stub; live via `--backend`/`--agentis` + `--live`.
    `demo-run-zone-hunt.sh` pins the whole chain, the HALT on every delivered path, never-submit (no egress, no
    draft for a scope-blocked finding), and per-finding propagation. **Closes epic #1611.**
- **Parallel fan-out — bounded-concurrency hunt over `(subsystem × class)` cells** (#1625, epic #1611 M3).
  `run-discovery.sh` gains an opt-in `--jobs N` (alias `-j N`, default `1`) bounded-concurrency fan-out: it
  hunts up to N cells CONCURRENTLY instead of strictly serially, dropping wall-clock from the sum of the
  cells toward the slowest cell per wave. Effective concurrency is HARD-CAPPED at `min(--jobs,
  LLM_MAX_DISCOVERY_CELLS)` (default cap `4`) by a self-contained `wait -n` job-slot loop that never fails
  open — so N concurrent `agentis go` / `forge` / `solc` processes cannot OOM-thrash a single host (tune per
  host via `LLM_MAX_DISCOVERY_CELLS`; `--jobs` over the cap is clamped with a stderr warning). Under `--jobs
  > 1` each cell runs in its OWN isolated agentis store (a `cp -r` of the initialised template into
  `run/cell-<slug>_<cls>/`) so concurrent builds/memo writes never race; a consequence is that #1001
  cross-cell blackboard steering is DISABLED under parallelism (every cell's board starts empty) — a
  documented throughput-vs-steering trade. Results are aggregated AFTER the pool drains, scraped in MANIFEST
  order by the same helper the serial path uses, so `discovery-report.md` and the new additive
  `discovery-results.json` (`{repo, backend, jobs, cells, totals}`) are deterministic and independent of
  completion order. `--jobs 1` (the default) keeps the ONE shared store with live #1001 steering and is
  BYTE-FOR-BYTE identical to the pre-M3 hunt (all new machinery sits behind `[ "$JOBS" -gt 1 ]`; the serial
  loop is factored into functions the parallel path calls identically). Read-only, never submits.
  `demo-discovery-parallel.sh` is the offline deterministic proof — a fast stub through the existing
  `--agentis` seam (no live agentis/forge/network) asserts serial==golden, concurrency observed + cap never
  exceeded (incl. the clamp path), aggregation==serial (order-independent), per-cell store isolation, and
  a failed cell still degrades.
- **New-listing watcher — freshness-first Immunefi target selection** (#1623). New standalone
  `watch-new-listings.sh` (does NOT source, and makes NO edit to, `run-immunefi-intake.sh` — that file's ranking
  output stays regression-critical and byte-identical) duplicates the #1592 EVM/Solidity/Vyper/Yul, not-
  `inviteOnly`, in-window-`endDate`, `maxBounty >= --floor` survivor filter verbatim, then layers ONE new signal:
  a program is FRESH — and gets surfaced — iff it launched within `--max-age-days` (default 21, via
  `launchDate`) OR its key is absent from a NEW self-dedup ledger, `seen-listings.txt` (distinct from
  `run-batch.sh`'s `funnel-ledger.txt`) — the honest first-seen proxy for "new" when `launchDate` is
  stale/absent. Every current survivor's key is recorded to the ledger after each run, so the *next* run's
  first-seen check narrows to genuinely-new programs (idempotent on the ledger-only signal; a still-in-window
  program legitimately keeps re-surfacing every run, which is the intended freshness behaviour, not a dedup
  bug). Emits the SAME 5-column `score<TAB>key<TAB>url<TAB>name<TAB>scope_hint` TSV `run-batch.sh --queue`
  already consumes, using the SAME `immunefi:<id>` key namespace `run-immunefi-intake.sh` uses (a separate
  queue file, `new-listings.queue`, so the two tools' outputs never clobber). `[SKIP]` + exit 0 with both
  `--out` and `--ledger` untouched on no network / no `--bounties` / missing python3. Read-only, never
  submits — the operator wires the recurring cron/schedule. `demo-watch-new-listings.sh` is the offline
  deterministic proof (fixture launchDate values computed relative to "today" so the assertions never rot).
- **Brief-generation — per-zone hunt briefs that prime the discovery hunt** (#1619, epic #1611 milestone M2).
  New `gen-briefs.sh` (shell plumbing) + `auditor/agents/brief-writer.ag` (substrate authoring) turn M1's
  `zones.json` + `scope.tsv` into a per-zone `briefs/brief_<zone_id>.md` (plus a `briefs/zone_briefs.json`
  index) in the EXACT plain-markdown format `hunter.ag` consumes via `SCOPE_BRIEF`: a header + the zone's
  bug-class list, the DEPTH body (`brief-writer.ag`'s per-class invariants-to-break + folded audit residual +
  prior-pattern hints), the in/out-of-scope boundaries, and the honesty mandate. The shell does only mechanical
  plumbing (read the M1 model, gather code refs, match the audit residual, assemble the deterministic scaffold);
  the substrate authors the depth, invoked once per zone with `agentis go` (exactly as `run-discovery.sh`
  invokes `hunter.ag`), emitting a `DARK-FACTORY:BRIEF-BEGIN|…`/`…:BRIEF-END` block that `gen-briefs.sh`
  awk-slices — the `report-writer.ag` sentinel-block idiom. `--audit-residuals` (optional) CONSUMES
  `audit-scout.ag`'s `BOUNDARY|`/`RESIDUAL|` output: matched RESIDUAL leads fold into the body and the BOUNDARY
  set seeds the out-of-scope section; absent, briefs still emit (residual folding is optional enrichment).
  `run-discovery.sh` gains an ADDITIVE, opt-in, byte-identical-default extension of M1's `--list-cells` dry-run:
  when `--brief` is also given it validates + resolves it and prints `BRIEF|<abs>|<lines>` before the cell
  enumeration — the offline round-trip proof that a generated brief resolves and is what would be handed to the
  hunter as `SCOPE_BRIEF`; with no `--brief` the M1 output and the shipped hunt path are byte-identical. Every
  brief is markdown-safe (no NUL, ≤ 2000 lines, no bare `CANDIDATE|`/`BLACKBOARD-` token). Offline/CI
  determinism comes from `--fixture` (canned brief bodies, no live LLM); `fixtures/zone-map/briefs.fixture.txt`
  + `residuals.fixture.txt` + `demo-gen-briefs.sh` are the deterministic proof (wired into `colony-lint`). Brief
  QUALITY is the decisive depth lever and is LLM-backend-gated — M2 ships the machinery + a fixture-proven
  format; live depth is backend-dependent. Read-only, never submits. See `docs/zone-split-orchestration.md`.
- **Zone-mapping — auto-derive `scope.tsv` from a target** (#1612, epic #1611 milestone M1). New
  `map-zones.sh` (shell plumbing) + `auditor/agents/zone-mapper.ag` (substrate classification) auto-derive a
  target's DISCOVERY manifest from the code itself: locate in-scope Solidity/Anchor sources, group them into
  candidate ZONES by directory, count LOC, compute an advisory `hardening_score` (post-audit churn via
  `audit-delta.sh` + git file age; monotone, NEVER a gate), function-slice big contracts (`file@fn1+fn2`,
  `slice-fns.sh` format), and delegate the ONE semantic step — subsystem name × applicable bug classes
  (`C1..C14`) × description — to `zone-mapper.ag` (one `agentis go` per zone, exactly as `run-discovery.sh`
  invokes `hunter.ag`). Emits `zones.json` (7-key structured model) + `scope.tsv` (the pipe-delimited manifest
  `run-discovery.sh --scope` parses byte-for-byte), closing the auto-map → hunt loop. `run-discovery.sh` gains
  an opt-in `--list-cells` (alias `-n`) dry-run that enumerates the `CELL|<subsystem>|<class>|<files>` it WOULD
  hunt and exits BEFORE any side-effect (needs neither `--brief` nor an agentis binary) — the offline
  round-trip for the generated `scope.tsv`; with no `--list-cells` the shipped hunt path is byte-identical.
  Offline/CI determinism comes from `--fixture` (canned `ZONE|...` classification, no live LLM);
  `fixtures/zone-map/` + `demo-map-zones.sh` are the deterministic proof (wired into `colony-lint`).
  Read-only, never submits. See `docs/zone-split-orchestration.md`.
- **`--live` Immunefi target discovery** (#1592, epic #1505). `run-immunefi-intake.sh` gains a discovery mode that
  fetches the public `bounties.json` (read-only unauthenticated GET; `--url` overridable, `--bounties <file>` the
  offline hatch), MAPS each surviving program — EVM/Solidity/Vyper/Yul, not `inviteOnly`, in-window `endDate`,
  `maxBounty >= --floor` (default 10000) — into the existing operator-programs schema, then flows it through the
  UNCHANGED ranking / dedup / 5-column-TSV path (so `run-batch.sh` consumes it verbatim). Two backward-compatible
  ranking hooks carry the live-only signals: a precomputed `discovery_bonus` (freshness + audit-scarcity +
  accounting-fit, 0..30) added to the score, and a `kyc` flag surfaced in the scope_hint — both absent on
  operator-supplied programs, so their ranks stay byte-identical. Offline / no network -> `[SKIP]` + exit 0 with
  the queue untouched (mirrors `run-funnel.sh`). Read-only, never submits. `demo-immunefi-live.sh` is the offline
  deterministic proof over a canned fixture; `demo-immunefi-intake.sh` re-passes unchanged as the regression guard.

### Changed
- **Audit-density penalty precision** (#1606): dropped the ambiguous bare `openzeppelin`/`consensys` tokens from the FIRMS list (they match ubiquitous Solidity library/tooling mentions, not audit attribution); the `consensys diligence` audit-arm name is kept. A genuinely-fresh program that merely uses OpenZeppelin no longer eats an undeserved penalty.
- **Audit-density penalty in `--live` discovery ranking** (#1599, epic #1505). The `--live`/`--bounties` MAPPER
  now scans each program's TEXT fields (`knownIssues`/`programOverview`/`description`/`rewardsBody`/`audits`/
  `impacts`, never the structured `audits` count) for audit-COMPETITION references (immunefi audit-competition
  URLs, "audit competition"/"audit contest", sherlock/cantina/code4rena/codehawks/hats) and named auditor firms
  (spearbit, trail of bits, openzeppelin, certora, halborn, cyfrin, zellic, ...). It folds a bounded penalty
  (competition −15, each named firm −3 capped −9) INTO the live-only `discovery_bonus`, clamped ≥0, so a
  competition-hardened target ranks BELOW a genuinely-unaudited one of equal bounty — a fresh launch date and an
  empty `audits` array do NOT mean unaudited. The signal is surfaced in scope_hint col 5 as `aud:<n> comp:<yes|no>`
  (the row stays exactly 5 columns). `score_of` is untouched and operator-supplied programs carry none of these
  fields, so the operator-path ranks stay byte-identical (guarded by the unchanged `demo-immunefi-intake.sh`).
  `demo-immunefi-live.sh` gains a deterministic fixture-pair assertion and is now wired into `colony-lint.sh`.

### Fixed
- **`hunter.ag` crashed on an illegal blackboard memo key at the exact moment it surfaced a CANDIDATE**
  (#1657/#1658). The `outcome == "success"` branch wrote a second memo keyed
  `"dark-factory:blackboard:" + subsystem` — a human-readable zone name (spaces/`&`/`/`), illegal in a memo key
  (`[A-Za-z0-9_:.-]` only) — aborting the hunter before its finding flushed to stdout, so `run-discovery.sh`
  saw a non-zero exit and silently discarded the lead. Fired only on positive findings, so it destroyed
  exactly the productive hunts. The per-subsystem key was never read by anything (every reader reads
  `dark-factory:blackboard:leads`); removed. Found live via `bench/corpus-bench` (41 of 175 hunt cells
  crashed on this across the 8-contest corpus run) and independently reproduced on a live protocol hunt.
- **`map-zones.sh` globbed vendored dependencies and build artifacts as audit "zones"** (#1659/#1660). The
  source `find` swept the whole target repo, so it grouped `lib/` Foundry submodules (openzeppelin,
  forge-std, ...) and `node_modules/`/`out/`/`cache/`/`artifacts/` into their own zones and handed them to the
  hunter — wrong scope, wasted hunt budget — and on a large dependency tree overflowed the mechanical pass's
  single `SOURCES` env string past `MAX_ARG_STRLEN` (~128 KB), aborting the whole zone-hunt with
  `Argument list too long` (measured: a Yearn strategy vendors 5,521 `.sol` under `lib/`, 627 KB). Now prunes
  `lib/`, `node_modules/`, `out/`, `cache/`, `artifacts/`, `.git/` from the source glob.
- **`map-zones.sh`/`gen-briefs.sh` lost a zone's classification/brief when the LLM indented its reply**
  (#1662/#1663). The `ZONE|` scrape (`grep '^ZONE|' | head -1`) and the brief sentinel match
  (`$0=="DARK-FACTORY:BRIEF-BEGIN|"z`) were anchored/exact, but the LLM non-deterministically indents its
  whole answer sometimes — an indented marker line was silently missed, leaving the zone unclassified (0 hunt
  cells) or the brief mechanically stubbed, with no error. Live evidence: a real contest's CORE strategy zone
  was dropped this way while sibling zones at column 0 classified fine. Both scrapes are now whitespace-
  tolerant. Regression coverage added in `demo-map-zones.sh`/`demo-gen-briefs.sh` (#1664/#1667): an
  indented-marker fixture, derived at runtime, that fails if either scrape is ever re-anchored.
- **`map-zones.sh`/`gen-briefs.sh` silently accepted an LLM's echoed prompt template as valid content**
  (#1655/#1656). The zone-mapper/brief-writer sometimes answer a fill-in-the-blank prompt by echoing its own
  bracketed placeholder verbatim (e.g. `name="<short subsystem name>"`) instead of real content; both scripts
  accepted it at face value. Added a shared heuristic (a value that, stripped, starts with `<` and ends with
  `>` is an unfilled template) and treat it the same as an existing failed-run.
- **`demo-audit-pass.sh` flaky ~1-in-5 (a different stage-row assertion missing each run)** (#1666/#1669).
  Root-caused to an intermittent read-side flake in `agentis memo get` itself (confirmed NOT a
  write-completion race — the on-disk memo file was proven byte-complete at the exact moment a check failed;
  NOT a lingering process; NOT a `.ag` logic bug), amplified by the harness's ~24+ reads per run. Fixed with a
  bounded read-retry (8 attempts) in the test harness only; `coordinator.ag`/`run-audit-pass.sh` untouched.
  Companion issue filed in the private `agentis-core` repo (#909) to track the underlying read flakiness.

## [0.3.0] - 2026-07-10

**Requires:** agentis >= `1.18.0`

### Changed
- **Self-contained Slack router/ingest posts** (#1574, epic #1505, following #1562/#1567/#1541). Every
  operator-facing post `ingest-slack-outcome.sh` makes now carries its payload INLINE so the operator acts from
  Slack alone — no `see <file>` pointers. The greenlit hand-off (no target dir resolved) posts the ready-to-run
  `run-audit-pass.sh …` command as an in-thread mrkdwn code block (a shared `_rehunt_cmd` helper writes the SAME
  string into `RE-HUNT.md` and the message; `--out re-hunt-out` is relative + the clone path stays the one
  placeholder, so no internal/stage path leaks); the needs-info follow-up is delivered as a thread SNIPPET
  (`slack_upload`, ported verbatim from `notify-submission.sh` with an added explicit `channel` arg) plus a
  `follow-up drafted (in thread)` one-liner; and the cheap actions (mark-dead/tune-gate/reinforce) collapse into
  ONE consolidated `applied — …` confirmation instead of silent writes. The durable files (`RE-HUNT.md`,
  `FOLLOWUP.md`, `dead-targets.txt`, `gate-tuning/*`) are unchanged silent records. The never-submit invariant,
  the propose→greenlight gating, and the `.route-applied`/`.route-proposed`/`.route-greenlit` idempotency markers
  are untouched. `demo-feedback-loop.sh` asserts the in-thread command (9e/9k), the follow-up snippet (9c), the
  consolidated cheap post (9b/9d), and source guards that the old `see RE-HUNT.md` pointer is gone (9g).

### Added
- **Persist the verbatim re-hunt draft so the Slack completion snippet is the REAL submission** (#1580, closing
  the #1577 out-of-scope follow-up, epic #1505). The LIVE report gate now persists the report-writer's verbatim
  4-section body to `<--out>/submission-draft.md` (a sibling of `pass.tsv`/`pass-result.txt`) so the #1577
  `PENDING-HUMAN-REVIEW` completion callback uploads the ACTUAL submittable draft instead of the `pass.tsv` trace
  fallback. Persistence happens in the gate wrapper `run-gate-agent.sh` (a new byte-neutral `persist_draft`) — the
  only point where the full body survives, right after `extract_verdict` and BEFORE the `mktemp` `trap rm -rf EXIT`
  teardown. `report-writer.ag` gains one closing sentinel `DARK-FACTORY:DRAFT-BODY-END` (contains no
  `SUBMISSION-DRAFT|` substring, so verdict extraction is unaffected) so the wrapper slices a BOUNDED body
  (marker line .. sentinel-EXCLUDING); a truncated render missing either the marker or the sentinel writes NOTHING,
  never a run-to-EOF slice that could bake an internal store path into a Slack-bound file. The durable path threads
  LIVE via `run-audit-pass.sh` (`DRAFT_OUT="$OUT/submission-draft.md"` + `SUBMISSION_DRAFT_OUT` on the
  `exec.env_passthrough` allowlist) → coordinator `getenv` → `run_stage_live`'s gate-runner env. Byte-neutral on
  non-PASS / no-draft / offline-fixture runs (`demo-audit-pass.sh` stays green); the human gate is untouched (the
  file is local/operator-facing, nothing is auto-submitted). No `ingest-slack-outcome.sh` change — its callback
  already prefers `submission-draft.md`. `demo-feedback-loop.sh` part 10 gains case 10a3 (the real producer writes
  the bounded draft, no trailing-trace/sentinel leak, and the callback uploads that produced file byte-identically)
  plus four static wiring pins across `coordinator.ag`/`run-audit-pass.sh`/`report-writer.ag`/`run-gate-agent.sh`.
- **Re-hunt completion callback — the FINISHED result posts into the Slack thread** (#1577, closing the #1567
  seam, epic #1505). When the auto-invoked DETACHED re-hunt (#1567) FINISHES, a later `ingest-slack-outcome.sh`
  sweep (which re-enters an already-ingested stage BEFORE the `.outcome-ingested` short-circuit) posts its RESULT
  into the manifest thread ONCE (self-contained, #1574), keyed on `.re-hunt-pid` + a new `.re-hunt-reported`
  marker. A new `_rehunt_completion_check` decides FINISHED from a terminal artifact (`re-hunt-out/pass-result.txt`)
  that OVERRIDES `kill -0` (reused-pid conservatism); an ALIVE pid posts nothing and writes no marker, so a later
  sweep re-checks. Three outcome posts: `PENDING-HUMAN-REVIEW` uploads the durable draft artifact that IS present
  (via the ported `slack_upload`) + a `new draft ready` one-liner; a no-finding token
  (`BLOCKED-SCOPE`/`NO-RESIDUAL`/`NO-POC`/`BLOCKED-IMPACT`/`INCOMPLETE`) posts `no new submittable finding (<token>)`;
  an absent/empty result posts a `finished with an error (<reason>)` line whose reason is PATH-STRIPPED by
  `_rehunt_error_reason` (drops a trailing ` (see …)` pointer + any slash-bearing token, so no internal path ever
  reaches Slack). **HONEST scope:** `run-audit-pass.sh` persists no verbatim report-writer BODY (the report stage
  runs in a `mktemp` throwaway), so the `PENDING-HUMAN-REVIEW` upload prefers `submission-draft.md` if present and
  falls back to the `pass.tsv` trace — it never fabricates a finding; persisting the verbatim report body to
  `submission-draft.md` is a LIVE-substrate change to `run-gate-agent.sh`/the coordinator report stage and remains
  an **out-of-scope follow-up**. Never-submit is untouched; `demo-feedback-loop.sh` part 10 asserts the draft
  upload + snippet fallback (10a/10a2), the no-finding line (10b), the ALIVE no-op (10c), idempotency (10d), the
  path-stripped error (10e), and source guards (ordering before the short-circuit, the pid/reported gate,
  no submit/bounty-platform token in any post).
- **`deliver-submission.sh --target-dir` → manifest `local_repo`** (#1571, closing the #1567 seam). Mirrors the
  existing `--bounty-url` wiring exactly: a new `--target-dir <dir>` flag threads verbatim into `manifest.json` as
  `local_repo` — the exact key the #1567 router reads first at greenlight time. Additive, no path validation (the
  router does its own `[ -d ]` check); empty when the flag is omitted (graceful). Closes the last operator-friction
  seam so the greenlit re-hunt auto-invokes hands-free, with no `--target-dir` needed on the ingest side.
- **Feedback-informed re-hunt + router greenlight AUTO-INVOKE** (#1567, closing the #1562 seam, epic #1505).
  Two threaded halves, each riding an existing path. **(1) Feedback-informed DEVISE.** `run-audit-pass.sh` gains
  `--reviewer-feedback <text>` / `--reviewer-feedback-file <path>` (inline wins; a set-but-unreadable file →
  `exit 3`), surfaced as a `REVIEWER_FEEDBACK` env var that threads through the coordinator SUBMISSION PASS's
  per-stage passthrough (`run_stage_live` → `run-gate-agent.sh`) into `audit-scout.ag`'s DEVISE prompt — the model
  is asked to hunt a residual **around** the rejection reason instead of re-surfacing the rejected finding.
  **Guarded + byte-identical when empty** (`if len(feedback) == 0 { "" }`), and **prompt-only**: the feedback flows
  solely into `prompt()`, is `shell_escape()`d at the coordinator hop, and never reaches an `exec sh` command line.
  **(2) Router greenlight auto-invoke.** `ingest-slack-outcome.sh` gains a `--target-dir <dir>` flag and, on an
  operator `go`, resolves a target dir (the override, else a manifest `local_repo`/`target_dir`); when it resolves
  AND `run-audit-pass.sh` (`DARK_FACTORY_RUN_AUDIT_PASS`-overridable) + `setsid` are present, it **AUTO-INVOKES** the
  feedback-informed re-hunt **detached** (the `code-edit-job.sh` setsid convention, `--reviewer-feedback` + the
  finding facts) and posts `re-hunt launched (pid …)`; otherwise the **unchanged** `RE-HUNT.md` command HAND-OFF.
  **Never submits** (the re-hunt's terminal best case is a `PENDING-HUMAN-REVIEW` draft; no bounty-platform egress)
  and **idempotent** (the `.route-greenlit` gate prevents a double-launch on `--all` cron sweeps). The feedback
  rides the #1535 honest-stub live-dispatch path — fully wired when the DEVISE runner + a backend are present, and
  never falsely proceeds when a stage stubs. `demo-feedback-loop.sh` gains sub-parts 9i-9n (per-hop env threading +
  the guarded/prompt-only DEVISE, auto-invoke vs hand-off, idempotency, never-submit, router source guards).
- **Outcome → action ROUTER in `ingest-slack-outcome.sh`** (#1562, epic #1505). Once an outcome is CLASSIFIED
  (the #1561 `FEEDBACK|<disp>|<conf>|<stage>|<SIGNAL>|<root_cause>|…` line), a **deterministic** bash `case`
  (`route_actions`, never an LLM, no new `.ag`) turns `disposition + root_cause` into the next action(s). CHEAP
  actions are local, reversible writes applied immediately: `mark-dead` (append a `target@<commit>` key to
  `dead-targets.txt`, grep-guarded) — now **consulted** by `run-immunefi-intake.sh --dead-targets`, which drops a
  rejected target from the next ranked queue (a freshness-style skip, closing the loop); `tune-gate` (a durable
  calibration NOTE in `gate-tuning/<stage>.md`); `needs-info-draft` (a `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW`
  `FOLLOWUP.md` stub carrying the reviewer's question verbatim); `reinforce` (a winning-path note on `accepted`).
  SPENDY actions (`re-devise`/`hunt-deeper`) are **propose-then-greenlight**, human-gated for spend: the router posts
  a `propose:` message + writes `.route-proposed`, and the spend runs ONLY after a later operator `go` reply, which
  produces a ready-to-run **hand-off** (`RE-HUNT.md` = the reviewer reason as guidance + a pre-filled
  `run-audit-pass.sh …` command) + a `greenlit` post + `.route-greenlit`. **Honest scope:** the greenlit action is a
  command HAND-OFF the operator runs, NOT a coordinator/hunt auto-invoke (no hunt entry accepts reviewer guidance
  yet — a documented follow-up seam); `tune-gate` is a recorded HOOK (the gates do not `recall()` it yet) and the
  router never calls `learn()` a second time (no double-count). Idempotent via three per-outcome markers
  (`.route-applied`/`.route-proposed`/`.route-greenlit`), the greenlight pass re-entering before the
  `.outcome-ingested` short-circuit so a `--all` cron catches a later `go`. The never-submit invariant is unchanged
  (local writes + operator-workspace Slack posts only; `RE-HUNT.md` carries no submit primitive). `demo-feedback-loop.sh`
  gains a nine-part router section (the deterministic map, cheap auto-apply + idempotency, spendy propose-not-execute,
  greenlight-only-on-`go` + hand-off-not-auto-invoke, the `--dead-targets` skip).

### Fixed
- **Removed the dead `signal_upper()` helper in `ingest-slack-outcome.sh`** (#1564). PR #1563 (the #1561 classifier
  rework) removed its only call site; its header comment described a "runtime-absent fallback" path that no code
  reaches. Deleted the unreachable function + the stale comment; no functional change.

### Changed
- **Feedback intake classifies the raw platform response instead of a rigid `verdict:` enum** (#1561, revises
  #1526/#1557). The operator no longer hand-picks a `verdict:` token — they paste the platform's response
  **verbatim** into `OUTCOME.md`'s new `platform_response: |` block (or reply in the Slack thread starting with
  `outcome:` then the verbatim paste), and `feedback-intake.ag`'s LLM step becomes a **classifier** that maps the
  raw text to a `disposition` (`accepted`/`rejected`/`duplicate`/`needs-info`/`out-of-scope`/`unclear`) +
  `confidence` + stage + root_cause. **The learn signal stays DETERMINISTIC**: it is computed in `.ag` code from the
  classified disposition (`accepted → success`; `rejected`/`duplicate`/`out-of-scope → failure`;
  `needs-info → partial`; else → hold), never by the LLM — a mis-classification can never flip a payout into a
  failure. A **confidence gate** holds a low-confidence or `unclear` classification: `feedback-intake.ag` emits a
  `HOLD` signal (no `learn()`), and `ingest-slack-outcome.sh` posts a Slack **confirmation request** into the thread
  + writes a `.pending-confirmation` marker (keyed on the operator's reply ts, so a cron never re-spams) instead of
  `.outcome-ingested` — a later, clearer reply can still be learned. First-class `rejected` and `out-of-scope`
  dispositions replace the overloaded `closed`. An explicit operator `verdict:`/`payout:` **override** (now a
  commented-out placeholder in the `OUTCOME.md` template, inert until uncommented) always wins and bypasses the gate;
  the legacy `closed` token normalizes to `rejected`, so an in-flight `verdict:`-style `OUTCOME.md` or Slack reply
  keeps working (backward-compat). `deliver-submission.sh`'s template, `notify-submission.sh`'s reply prompt,
  `ingest-slack-outcome.sh`'s capture/write/confirm path, and `demo-feedback-loop.sh` (parts 2/6/8) all move to the
  new contract; the never-submit invariant is unchanged.

### Fixed
- **`colony-lint.sh` never shellchecked federation-root scripts** (#1554). `run-audit.sh`,
  `demo-feedback-loop.sh`, `demo-pattern-memory.sh`, and 69 other `dark-factory/*.sh` scripts live outside any
  colony's `config/`-having subdirectory, so the existing per-colony shellcheck loop in `tools/colony-lint.sh`
  never saw them — future error/warning regressions there went uncaught by CI. `colony-lint.sh` now shellchecks
  every federation-root `*.sh` (all 6 federations, not just dark-factory) at `-S warning` (error + warning only,
  not the per-colony blocks' default severity — at default these 82 previously-unlinted scripts carry ~242
  mostly-cosmetic info/style findings, a separate full style-cleanup follow-up, not this issue's regression-catch
  goal). Fixed the 3 real `-S warning` findings this surfaced: a fragile heredoc delimiter in
  `demo-pattern-memory.sh` (`<<'METHOD'` collided with a `METHOD|...` content line — SC1121, renamed to
  `METHOD_EOF`), a single-item `for` loop over a quoted path in `run-audit.sh` (SC2066, replaced with a direct
  assignment), and an unused `STAGED6F` capture in `demo-feedback-loop.sh`'s part-6f no-creds test (SC2034,
  dropped — only the stderr side effect is asserted there).
- **Secret-gist auto-create used a non-existent `gh gist create --secret` flag** (#1549, live-verified against
  a real `gh` + real bot token during the #1541 Slack delivery smoke-test). `gh gist create` has no `--secret`
  flag — gists are **secret by default** (`-p`/`--public` is the only flag, and flips the OTHER way), so the
  live create ALWAYS failed with `unknown flag: --secret`, silently degraded to the `GIST_COMMAND.txt` fallback,
  and the secret gist link never reached the package or Slack. The fallback text carried the same broken command,
  so an operator running it by hand hit the same error. Fixed by dropping `--secret` from both the live
  `gh gist create` invocation and the `GIST_COMMAND.txt` fallback text in `deliver-submission.sh` (no `--public`
  added — secret-by-default is the desired behaviour); `gist_ready()` and the best-effort `|| true` wrapping are
  unchanged. `demo-feedback-loop.sh`'s part-5 gh-stub assertions now assert the command does NOT carry `--secret`.
- **Slack field labels bolded for scannability** (#1549, same live smoke-test). The five metadata labels
  (`Project:`/`Asset:`/`Impact:`/`Severity:`/`Title:`) in `notify-submission.sh`'s bot-mode main message now
  render bold in Slack mrkdwn (`*Project:*` etc, single asterisks — values stay plain); `demo-feedback-loop.sh`'s
  part-6 curl-stub assertion now checks for the bold label form.

### Added
- **Capture the platform outcome from the Slack thread — close the feedback loop in one place** (#1557, epic
  #1505). The operator now replies IN THE SLACK THREAD (under the #1541 bot-mode submission package) with the
  platform outcome; a new reader folds that reply back into learning — no hand-edited local `OUTCOME.md`. Opt-in,
  best-effort, additive: the `OUTCOME.md` schema and `feedback-intake.ag` (the #1526 learn path) are REUSED
  UNCHANGED — only the INPUT source changes (a Slack thread reply instead of a local file). Every existing
  invariant stays byte-intact (the never-submit / no-bounty-platform-egress contract, the one-line staged-path
  stdout relied on by `deliver-submission.sh`).
  - **`notify-submission.sh`** now, on a successful main post, records two new keys into the already-staged
    `manifest.json` — `slack_thread_ts` (the main message ts) + `slack_channel` (the routed channel) — and posts
    ONE final threaded reply-with-outcome prompt showing the operator the EXACT field names the reader parses
    (`verdict:`/`severity:`/`payout:`/`reason:`/`notes:`). `slack_post()` gains an OPTIONAL 3rd `thread_ts` arg
    (the payload gains a `"thread_ts"` key only when non-empty; the existing 2-arg main-message call is unchanged).
    Both the writeback and the prompt are best-effort and route nothing onto stdout.
  - **New `dark-factory/ingest-slack-outcome.sh`** (bash, bot-mode reader, NO platform egress). `--stage <dir>` or
    `--all` (glob the drop-dir). Resolves `DARK_FACTORY_SLACK_BOT_TOKEN` (`secret://…` or raw); no token → exit-0
    no-op. Per stage: reads `slack_thread_ts`/`slack_channel` from the manifest, skips if `.outcome-ingested`
    exists, fetches the thread via `conversations.replies` (Bearer, 2xx AND `ok:true`, single page), SELECTS the
    operator reply (drops the bot's own posts by `bot_id`/`subtype`/`auth.test` user id; keeps the latest message
    with a `verdict:` line), parses `verdict:`/`severity:`/`payout:`/`reason:`/`notes:` (tolerating a
    `reviewer_notes:` alias), reads the canonical `submission_id` from the manifest, writes `OUTCOME.md` in the
    exact existing schema (column-aligned so `feedback-intake.ag`'s `^verdict:`/`^reason:` greps match unchanged),
    runs `feedback-intake.ag` FROM the auditor colony dir (so `learn()` PERSISTS — not a throwaway mktemp),
    posts a threaded confirmation (`outcome recorded -- learned <SIGNAL> on <stage>`; SIGNAL deterministic from
    the verdict, stage from feedback-intake's `FEEDBACK|` line), and marks the stage `.outcome-ingested`. Idempotent
    (a re-run/cron skips a marked stage); `--all` continues on per-stage failure; a stage with no operator reply
    yet is skipped WITHOUT a marker so a later run retries. Reading a public channel's thread needs the Slack app's
    `channels:history` scope; the trigger model is honestly operator/cron (serverless — no always-on listener).
    The resolved token appears only in the `Authorization` header, never argv/echoed.
  - **`README.md`** gains the two new manifest keys + the ingest script in the env table and script index, plus a
    new "Capturing the outcome from the Slack thread" subsection (the `channels:history` scope + reinstall +
    re-store step, the `--stage`/`--all` usage, the honest operator/cron trigger, and a suggested-but-NOT-installed
    crontab line).
  - **`demo-feedback-loop.sh` part 8** proves it offline (fake token, no network): part 6's smart curl stub gains
    `auth.test` + `conversations.replies` branches and the `chat.postMessage` branch appends a JSONL so both the
    main post AND the threaded prompt are inspectable; part 6a asserts the manifest writeback + the reply-with-
    outcome prompt; part 8 asserts the OPERATOR reply (not the bot snippet) is selected → `OUTCOME.md`
    verdict==closed / reason / reviewer_notes, `feedback-intake.ag` invoked (an `agentis` stub) + deterministic
    closed→failure, the threaded confirmation, the `.outcome-ingested` marker, a NO-OP second run, the no-token
    no-op, bad-args exit 2, the fake token never leaking, and source guards (bash never sh, no bounty-platform
    egress, `channels:history` documented, learn runs from the colony dir not a mktemp).
- **Auto-rendered PoC run-evidence screenshot attached to Slack** (#1550, epic #1505). The captured `poc-run.txt`
  (#1540) is now auto-rendered into a terminal-styled `poc-run.png` and threaded to the Slack submission package
  (bot mode, #1541) as the Immunefi Attachments artifact — a scannable screenshot of the REAL passing run beside
  the raw text log. Opt-in, best-effort, additive; every existing invariant (the exit-3 marker guard, the #1540
  PoC/gist staging, the one-line staged-path stdout contract, the never-submit contract) stays byte-intact.
  - **New `dark-factory/render-run-evidence.sh`** (bash) + **`render-run-evidence.py`** (python3/Pillow) — the
    renderer. `.sh` chooses `freeze` (charmbracelet, on PATH) → the bundled PIL renderer → SKIP, in that order;
    `freeze` is OPTIONAL and UNVERIFIED (not on the dev host — flags source-guarded, falls through to PIL on any
    failure), the PIL path is verified (Pillow 11.3.0). `.py` strips ANSI, styles a dark terminal with a mac-style
    titlebar, colourizes `[PASS]`→green / `[FAIL]`→red / else light-gray, tries a candidate list of system
    monospace TTFs (Noto Sans Mono / Liberation Mono / DejaVu, each guarded, ending in `load_default()`), sizes
    the canvas from measured line widths, and saves a PNG. **HONESTY GUARD:** the renderer draws the input
    verbatim (only recolouring lines the log already contains) — it can NEVER synthesize a `[PASS]`.
  - **`deliver-submission.sh`** grows a best-effort render step wired to the new `poc_screenshot` manifest key
    (empty default; every existing key preserved). The render call sits INSIDE the existing `[ -n "$POC_RUN_REL" ]`
    guard (which is set only when `--poc-run` pointed at a real, existing file), so a screenshot can only ever be
    rendered from a REAL captured run-log. No renderer / any render failure → `poc_screenshot` stays empty, the
    stage still exits 0, text-only `poc-run.txt` is bundled — no new REQUIRED dependency (exactly like the gh-gist
    step). Location: `poc-run.png` at the drop-dir root, alongside `poc-run.txt`.
  - **`notify-submission.sh`** attaches `poc-run.png` to the Slack thread on a new `slack_upload` call site (bot
    mode only; `slack_upload()`'s raw `--data-binary "@file"` POST is already binary-safe — no change to it). The
    plain WEBHOOK mode (#1538) has no file-upload primitive and stays screenshot-less (an existing capability gap).
  - **`demo-feedback-loop.sh` part 7** proves it offline: a real PNG (magic-byte check) + the manifest key when
    Pillow is present, graceful text-only degradation both host-dependently and DETERMINISTICALLY (a python3 stub
    intercepting only `import PIL`), a byte-identical thread attach through part 6's curl stub, and source guards
    (the honesty guard, the nested render call, the notify wiring, freeze-unverified).
- **Slack BOT-MODE delivery of the COMPLETE submission package** (#1541, epic #1505). A configured Slack Bot App
  now receives the whole copy-paste-ready Immunefi package on a successful stage — not a one-line alert. Opt-in,
  best-effort, and additive: every existing invariant stays byte-intact (the exit-3 marker guard, the #1540 gist/
  PoC staging, the #1538 webhook alert as the fallback, the never-submit / no-bounty-platform-egress contract, and
  the one-line staged-path stdout relied on by `demo-feedback-loop.sh` + `feedback-intake.ag`).
  - **New `dark-factory/notify-submission.sh`** (bash) — the rich full-package sender. Posts the five form-metadata
    fields (Project/Asset/Impact/Severity/Title) + the bounty link + the secret-gist link as a main
    `chat.postMessage` (mrkdwn), captures its `ts`, then threads the Description (the marker/`FIELD|`-stripped
    4-section body), each PoC source, `REPRODUCE.md`, and the run-evidence beneath it as file snippets via the
    MODERN external file-upload flow (`files.getUploadURLExternal` + `files.completeUploadExternal`, scope
    `files:write` — NOT the deprecated `files.upload`). SUCCESS is HTTP 2xx **AND** `ok==true` (python3 parse — a
    `200 {"ok":false}` is a FAILURE); a transient 5xx/transport error retries with bounded backoff, a hard
    `ok:false` is a loud non-retry warning printing only the Slack error code. The channel is chosen by severity
    (Critical/High→`_HIGH`, Medium→`_WARN`, else base). Every upload is best-effort (warn + skip, never fatal).
  - **`monitor/scripts/notify.sh` gains a single-post bot-mode** (POSIX-sh, dash-safe) — when
    `MONITOR_SLACK_BOT_TOKEN` (`xoxb-…`) + `MONITOR_SLACK_CHANNEL` (`C0…`) are set it delivers one
    `chat.postMessage` (Bearer, `{channel,text}`, 2xx AND `ok==true`, `ok:false`→exit 4) instead of the webhook,
    with optional `MONITOR_SLACK_CHANNEL_WARN/_HIGH` per-severity routing, reusing the existing retry/backoff +
    dedup. Bot vars UNSET → the webhook path + stdout no-op are byte-identical to before.
  - **`deliver-submission.sh`** grows a `--bounty-url <url>` flag (new `bounty_url` manifest key, empty default,
    every existing key preserved) and routes on a successful stage: bot creds resolve → the rich
    `notify-submission.sh` package (token/channel via ENV, never argv; `>&2 || true`); else the #1538 webhook alert
    (unchanged); else the stdout no-op (unchanged). The resolved token appears only in the `Authorization` header,
    never echoed.
  - **Config the operator sets**: `DARK_FACTORY_SLACK_BOT_TOKEN` (an `xoxb-…`, a `secret://…` URI or raw) +
    `DARK_FACTORY_SLACK_CHANNEL` (`C0…`, optional `…_WARN`/`…_HIGH`); Slack app scopes `chat:write` + `files:write`
    (+ optional `chat:write.public`). A bot post to the operator's OWN workspace is NOT a bounty-platform
    submission — the never-submit invariant is unchanged. Proven offline by `demo-feedback-loop.sh` part 6 (a smart
    stubbed `curl`, a fake token, no network).
- **Complete Immunefi PoC-form artifact set + auto secret-gist in the submission package** (#1540, epic #1505).
  `deliver-submission.sh` grows from staging the prose draft into staging the COMPLETE PoC-form bundle a human
  files out-of-band — additively, keeping every existing invariant byte-intact (the exit-3 marker guard, the
  never-submit / no-bounty-platform-egress contract, the #1538 Slack notify, and the one-line staged-path stdout
  relied on by `demo-feedback-loop.sh` + `feedback-intake.ag`).
  - **New optional inputs** `--poc-file <path>` (REPEATABLE), `--poc-run <path>`, `--poc-kind <foundry|hardhat>`
    (else inferred from the poc-file extension), `--poc-target <C.sol[:Name]>`, `--poc-match <prefix>` bundle the
    verbatim PoC source under `poc/<basename>`, a captured passing run-log as `poc-run.txt`, and a generated
    dash-safe `REPRODUCE.md` (toolchain + the concrete `forge test --match-path …` / `npx hardhat test …` command +
    the expected `[PASS]` line + the inverted-polarity note: a PASSING PoC = the exploit reproduced). A missing
    input warns to stderr and is skipped — the package still stages (writeup-only degradation), exit 0.
  - **FIELD→manifest extraction (folds in #1542's deferred wiring):** the five `FIELD|project|…`/`asset`/`impact`/
    `severity`/`title` lines `report-writer.ag` (#1543) now emits are extracted from the in-memory draft into a
    nested `immunefi_fields` object in `manifest.json` (draft-synced, so the form metadata can never drift — this
    is why the fields are extracted rather than re-declared as `--project`/`--asset` flags). A missing label
    defaults to `""`; every existing manifest key (`submission_id` etc.) is preserved, so `feedback-intake.ag` is
    unaffected. New manifest keys: `immunefi_fields`, `poc_files`, `poc_run`, `reproduce`, `gist_url`.
  - **Secret Gist auto-create** (best-effort, gated by `gist_ready()` = `gh` present AND a token/auth). When a PoC
    is staged, `gh gist create --secret` publishes the PoC source + `REPRODUCE.md` + a generated `GIST_README.md`
    to the operator's OWN GitHub and records the URL into the manifest. The Immunefi PoC form asks for a "secret
    Gist environment to support your PoC"; this gist is a SECOND egress but to the operator's own GitHub — NOT a
    bounty-platform submission; the human-gated-submit + never-submit invariants are unchanged. Best-effort and
    wrapped so it can NEVER fail a stage that already succeeded, with gh's stdout captured (`$(...)`) and all
    chatter routed to stderr so the one-line stdout contract holds. On no token / any failure it degrades to a
    loud stderr warning + `poc/GIST_COMMAND.txt` (the exact `gh gist create --secret` command to run by hand) + a
    `gist_url` placeholder.
  - **`run-poc.sh` run-evidence capture:** on a `FINDING` only, best-effort re-invokes the gate against the warm
    rundir to write a durable passing run-log (`poc-run.txt`) — AFTER the verdict is fixed, so it can NEVER regress
    the classify — and surfaces the runnable-PoC path + run-log on its OWN stdout as additive `POC-FILE|`/`POC-RUN|`
    lines (the coordinator hand-off / `deliver-submission --poc-file/--poc-run` source). All sub-invocations use
    `bash`, never `sh` (the #1507/#1534/#1535 dash lesson); `REPRODUCE.md`/`GIST_README.md`/`GIST_COMMAND.txt` are
    generated via `{ printf …; }` blocks (no heredoc).
  - `demo-feedback-loop.sh` gains an offline `5) POC ARTIFACT SET` section with a `gh` STUB on PATH (mirrors the
    part-4 curl stub): full artifact set + authed gist (byte-identical poc/run-log, REPRODUCE.md content, nested
    `immunefi_fields`, the stubbed gist URL, one-line stdout WITH the stub active), the no-token fallback (placeholder
    + `GIST_COMMAND.txt`, gh never runs `gist create`), writeup-only degradation, the marker guard running BEFORE any
    poc staging/gist, and the no-FIELD default-to-`""` case — no network anywhere. `demo-poc-gen.sh`'s source-guard
    gains the `run-poc.sh` run-evidence / `POC-FILE|`/`POC-RUN|` wiring assertion. **Out of scope (follow-up):**
    threading `run-poc.sh`'s new `POC-FILE|`/`POC-RUN|` stdout into `coordinator.ag`'s submission pass.
- **`report-writer.ag` emits discrete Immunefi form-metadata fields** (#1542). Between the
  `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW` marker and the existing 4-section markdown Description, the agent now
  renders exactly five machine-extractable `FIELD|<label>|<value>` lines — `FIELD|project|`, `FIELD|asset|`,
  `FIELD|impact|`, `FIELD|severity|`, `FIELD|title|` — sourced from two new optional env inputs (`PROJECT_NAME`,
  `FINDING_ASSET`) plus the existing `FINDING_TITLE`/`FINDING_IMPACT`/`SEVERITY_BAND`. Every value is resolved in
  `.ag` code via a deterministic `field_or_unknown()` default (`"<unknown>"` on blank) BEFORE it reaches the
  instruction, so the LLM only echoes already-known values — no formatting drift, no crash, never a blank
  unparseable line. The marker string and the 4-section Description are unchanged; `deliver-submission.sh`'s
  human-gate marker guard is a substring test, unaffected by lines appended after it. Feeds the Slack delivery
  format (#1541) and package bundling (#1540). **Deferred follow-up:** wiring `PROJECT_NAME`/`FINDING_ASSET`
  through `run-audit-pass.sh`'s `exec.env_passthrough` + CLI flags and into `deliver-submission.sh`'s
  `manifest.json` is caller-side plumbing, not part of this change.
- **Finding-ready Slack/Discord alert on `deliver-submission.sh` staging** (#1538, follow-up to #1526). After a
  successful stage, `deliver-submission.sh` now pages the operator with a finding-ready alert, reusing
  `monitor/scripts/notify.sh` (#1092) unconditionally — the same JSON-alert-to-`notify.sh` pattern as
  `monitor/scripts/check-drift.sh`. Opt-in on a configured webhook (`DARK_FACTORY_SLACK_WEBHOOK`, a
  `secret://...` URI resolved via `tools/parse-toml-secret.py --resolve`, falling back to
  `MONITOR_WEBHOOK_URL`); with no webhook configured this is an offline no-op (`notify.sh`'s own stdout
  no-op fallback) — no network, no behaviour change. The notify subprocess's stdout is redirected to stderr
  (`>&2`) so `notify.sh`'s no-webhook fallback line can never corrupt `deliver-submission.sh`'s documented
  stdout contract (the staged path) relied on by `demo-feedback-loop.sh` and `feedback-intake.ag`; the alert
  send is best-effort (`|| true`) so a broken/bogus webhook can never fail a stage that already succeeded.
  The alert is an operator PAGE on the operator's own channel — not a platform submission; the never-submit
  invariant is unchanged. `demo-feedback-loop.sh` gains a new offline `4) NOTIFY` section covering the
  no-webhook no-op, the alert payload shape, a bogus-webhook exit-code regression, the `bash`-not-`sh` source
  guard, and the stdout-contract regression guard.
- **Coordinator submission-pass integration — the epic #1505 CAPSTONE** (#1509, epic #1505). Wires the shipped
  submission stages (scope-gate #1511, audit-scout DEVISE, poc-writer #1507, impact-gate #1522, dup-scout #1503,
  report-writer #1508) into `coordinator.ag` as ONE fixed-order autonomous pass — `discover -> scope -> devise ->
  poc -> impact -> dup -> report -> HALT` — threading each stage's single-line verdict into the next and
  human-gated at submit. Design decision baked in: this is a THIRD coordinator mode, NOT scored argmax actions —
  the stages have a mandatory partial order + hard early-exit, not interchangeable bandit arms, so a policy weight
  must never reorder or skip them.
  - `auditor/agents/coordinator.ag` — a new PASS block, all additive and DARK unless `PASS_ENABLED` is set (the
    existing #1014 ORCHESTRATE_ENABLED reduce loop + the single decide_once path stay BYTE-IDENTICAL when the flag
    is unset — the demo-coordinator.sh no-flag regression guard). `submission_pass()` reduces `pass_step` over the
    fixed `STAGES` order; each step resolves the stage verdict, traces a row + emits `dark-factory:pass_stage` +
    `learn("coordinator-pass", ...)` (so per-stage outcome still evolves by result), threads the verdict forward,
    and HARD-halts on a blocking gate: scope not payable -> `BLOCKED-SCOPE`, devise no-residual -> `NO-RESIDUAL`,
    poc not finding -> `NO-POC`, impact not substantiated -> `BLOCKED-IMPACT`. dup HIGH is ADVISORY (threaded,
    never halts). report is terminal -> `PENDING-HUMAN-REVIEW`. The hard gate predicates (`scope_proceeds`,
    `impact_proceeds`) require the EXACT productive token; anything else (incl. the stub `incomplete`) halts —
    fail-safe toward NOT submitting. The pass NEVER emits a submit or contacts a platform. Result in
    `{PENDING-HUMAN-REVIEW, BLOCKED-SCOPE, NO-RESIDUAL, NO-POC, BLOCKED-IMPACT, INCOMPLETE}`, published to the
    durable `coordinator:pass_trace` / `coordinator:pass_result` memos.
  - Offline determinism (the CI path) via a `PASS_FIXTURE` fact (`scope=payable;devise=residual;poc=finding;
    impact=substantiated;dup=low;report=drafted`) — an absent stage key defaults to that stage's PRODUCTIVE token,
    so a partial fixture short-circuits at the divergent stage. The LIVE path exec-shs a per-stage runner
    (mirroring `run_symbolic_live`) with an honest-stub fallback (absent runner -> `incomplete` -> the pass halts).
  - `run-audit-pass.sh` — the bootstrap (sibling of `run-coordinator.sh`): seeds the finding facts + `STAGES` +
    the per-stage runner paths + optional `PASS_FIXTURE`, extends `exec.env_passthrough` to cover every pass var,
    fires ONE `agentis go coordinator.ag` with `PASS_ENABLED=1`, and reads `coordinator:pass_trace`/`pass_result`
    back. NEVER submits (same human-gate contract as `run-audit.sh`).
  - `auditor/scripts/run-gate-agent.sh` — a thin wrapper that runs any single-verdict-line gate `.ag` in a
    throwaway store and echoes its verdict line (used for the five `.ag` gates on the live path; PoC reuses
    `run-poc.sh`).
  - `demo-audit-pass.sh` (CI-safe, wired into `colony-lint.sh`) — source-guards the wiring, then runs the
    deterministic offline pass over three fact-states: full-proceed -> `PENDING-HUMAN-REVIEW`; out-of-scope asset
    -> `BLOCKED-SCOPE` (downstream rows provably absent); simulated-state impact -> `BLOCKED-IMPACT` (dup/report
    absent); and the never-submit invariant.
- **Human<->federation feedback loop — deliver drafts + intake outcomes into learning** (#1526, epic #1505).
  Closes both ends of the loop through a single operator DROP-DIRECTORY (design decision baked in: a LOCAL
  exchange point — no platform API, no gist, no scrape; offline-testable, operator-mediated, human-gated). A
  confirmed finding's report-writer (#1508) draft is staged for a human to file out-of-band; the platform's
  response is written back into the drop-dir and folded into learning, attributed to the gate that owns the
  lesson. Neither component ever submits.
  - `deliver-submission.sh` — the delivery muscle. Stages a report-writer draft under a stable submission id
    `<target>@<in-scope-commit>:<finding-slug>` into `$DROP_DIR/<slug>/` (default
    `${DARK_FACTORY_DIR:-$HOME/.dark-factory}/drop`) with `manifest.json` (canonical `submission_id` + the three
    RAW gate verdict lines + severity + finding metadata + `created_at` + `status`, via `python3 json.dumps`),
    `submission-draft.md` (verbatim), and an `OUTCOME.md` template the operator fills IN-PLACE. It REFUSES
    (exit 3) any draft lacking the `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW` marker — the human-gate invariant baked
    into the muscle — and has no platform egress (exit 0 staged / 2 bad-args / 3 missing-marker). The canonical id
    lives in `manifest.json`, not the editable template or the dirname, so an operator can never break correlation.
  - `auditor/agents/feedback-intake.ag` — the reasoning half (standalone batch agent, mirrors `scope-gate.ag` /
    `impact-gate.ag` / `report-writer.ag`). Env `SUBMISSION_DIR`. A deterministic muscle reads `manifest.json` +
    `OUTCOME.md`; the success/failure/partial signal is DETERMINISTIC from the operator verdict enum
    (`accepted`->success, `closed`->failure, `duplicate`->failure, `needs-info`->partial) so a mis-reasoning
    backend can never flip a payout into a failure. The LLM's only job is to ATTRIBUTE the outcome to the
    responsible stage; it prints `FEEDBACK|<SIGNAL>|<stage>|<rationale>`, then one `learn()` under that gate's OWN
    topic (`dup-scout`->`dup-risk`, others 1:1) with the deterministic signal, plus a
    `dark-factory:feedback_outcome` emit. Reads only the drop-dir; never submits.
  - `demo-feedback-loop.sh` — offline (bash/python3): DELIVERY (real stage + canonical id + raw verdicts + the
    exit-3 marker guard), SIGNAL (the deterministic verdict->signal map over an Enzyme Onyx `closed` fixture +
    a source-guard of the four arms / deterministic-signal `learn()` / impact-gate attribution / emit-learn-memo
    tail), and INVARIANT+LIVE (no platform egress in either component; runs the agent when agentis is present).
    Wired into `tools/colony-lint.sh`.
- **Immunefi intake + post-audit-delta discovery** (#1506, epic #1505). Two independent, offline-testable shell
  primitives that widen the intake funnel toward Immunefi bounties — the residual-surface half of discovery,
  built on the observation (borne out by the confirmed Lombard finding) that an audited protocol's rewardable
  bug almost never lives in the fortified, N-times-reviewed core but in the DELTA that landed AFTER the audit
  froze. NO new `.ag` agent; both are pure transforms, read-only, and never submit.
  - `audit-delta.sh` — a pure `git diff` detector: `--repo <dir> --since <commit-ish> [--paths <file>]` emits ONE
    JSON object (files changed on `<since>..HEAD`, an optional in-scope `--paths` intersection, the most-recent-
    change age in days, and a `DELTA`/`NO-DELTA` verdict). Never crashes on the `since==HEAD` / empty-diff edge
    (NO-DELTA, null age); exits 3 loudly on a non-git-repo / unresolvable `--since` (a shallow-clone miss surfaces
    as an error, never a silent empty delta), 2 on bad args. A general muscle other callers reuse.
  - `run-immunefi-intake.sh` — ranks an OPERATOR-SUPPLIED programs JSON (`--programs`, REQUIRED). **Design
    decision baked in: Immunefi has NO live fetch path, ever** — WebFetch is proven unreliable against the SPA and
    submission is human-gated, so the operator maintains a small static programs file out-of-band. Freshness keeps
    `status` active; scoring is an additive `bounty_term` (0..70, log-scaled) + `delta_term` (0..30, via
    `audit-delta.sh` when a program points at a local clone; 0 for NO-DELTA / no clone — never degenerate); dedup
    on `immunefi:<id>`. Emits the SAME 5-column TSV `run-batch.sh --queue` already consumes (zero changes to
    run-batch.sh), the scope_hint packing chain/repo/commit/delta/fee/vault for a future EV-gating evaluate stage.
  - `demo-immunefi-intake.sh` — ONE offline, deterministic proof of BOTH primitives (mirroring the #1485
    "two primitives + a CI-safe demo" precedent): a throwaway `git init` fixture drives audit-delta through
    DELTA / NO-DELTA / `--paths` intersection / bad-repo+bad-since (exit 3), and an operator-programs fixture
    drives the ranking (paused dropped by freshness, fresh-delta program outscoring an equal-reward NO-DELTA one,
    a no-local_repo program still ranking by bounty alone, file==stdout parity). Wired into `tools/colony-lint.sh`.
- **Submission report formatter in the substrate** (#1508). The stage AFTER scope-gate (#1511), impact-gate
  (#1522) and dup-scout (#1503) and BEFORE the human-gated submit. Once a finding is CONFIRMED, PoC'd, in-scope,
  impact-substantiated and low-dup, the last manual step of every live session was turning the terse verdict
  lines + the PoC into a platform-shaped report a human can read and file — this agent renders that draft.
  - `auditor/agents/report-writer.ag` — standalone dispatched agent (mirrors `impact-gate.ag` / `scope-gate.ag`).
    Env: `FINDING_TITLE`, `FINDING_LOCATION`, `FINDING_IMPACT`, `POC_FILE`, `SEVERITY_BAND`, `SCOPE_VERDICT`,
    `IMPACT_VERDICT`, `DUP_RISK` — the three upstream verdict lines threaded through verbatim. A deterministic
    PoC-read muscle (sed/grep: embed the test run-steps + a code excerpt) grounds the report in the real test.
    It renders exactly four Immunefi-shaped markdown sections — `## Brief/Intro`, `## Vulnerability Details`,
    `## Impact Details`, `## References` — and leads the response with the machine-checkable marker
    `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW`, making the never-submit / human-gated invariant explicit. The
    References section restates the scope/impact/dup verdict lines verbatim as an honest, evidence-based
    novelty/scope note. It NEVER submits — the output is a draft artifact only.
  - `demo-report-writer.sh` source-guards the wiring (CI-safe: env contract, PoC muscle, 4-section scaffolding,
    output marker, never-submits, emit/learn/memo tail) and runs the agent live over a fixture finding + PoC +
    upstream verdict lines when agentis is present; wired into `tools/colony-lint.sh`.
- **Concrete-exploit-sequence PoC generation for hardhat / non-invariant bug classes** (#1507). The SECOND PoC
  class alongside the forge/invariant machinery (`invariant-prover.ag` + `forge-invariant.sh`). Where the
  invariant path writes a stateful-invariant HANDLER and lets the fuzzer JUDGE over randomized SEQUENCES, this
  path writes ONE hand-driven CONCRETE attack-SEQUENCE test that reproduces a specific bug HYPOTHESIS end-to-end
  (set the pre-state, run the exact attack steps, ASSERT the exploit succeeded), covering the classes the
  invariant path does not — HARDHAT projects (a mocha/ethers exploit test) and hand-driven single-`forge test`
  foundry PoCs.
  - `auditor/agents/poc-writer.ag` — NEW standalone-dispatched agent mirroring `invariant-prover.ag` (env
    contract, `verdict_of`/`outcome_of`/`rc_of`, the #1073-shape bounded compile-repair loop, the emit/learn/memo
    tail). Env: `TARGET_FN`, `TARGET_CLASS`, `BUG_HYPOTHESIS`, `POC_KIND` (hardhat|foundry), `POC_REPO`,
    `POC_OUT`, `POC_HARNESS`, `CODE_PATH`, `TARGET_FIXTURES_DIR`, `POC_FIXTURE`, `POC_MATCH`, `POC_REPAIR_ROUNDS`.
    Emits `POC|<target>|<FINDING|CLEAN|HARNESS_ERROR>` + a `POC-FILE|<path>` line on a FINDING (the runnable PoC
    a human executes) and `dark-factory:poc_verdict`. The verdict is the gate's exit code — never the LLM's
    opinion.
  - **INVERTED verdict polarity** — a concrete-exploit PoC is written to PASS iff the exploit works, so the gate
    maps test-passed -> FINDING (exit 1), test-ran-but-failed -> CLEAN (exit 0), compile/tooling error / no test
    ran / linkage reject -> HARNESS_ERROR (exit 2). The inversion lives ENTIRELY in the gates (documented in each
    header, pinned on CI against captured mocha JSON), so `poc-writer.ag`'s `verdict_of(rc)` stays byte-identical
    to `invariant-prover.ag`'s.
  - `evm-harness/hardhat-poc.sh` — NEW hardhat verdict gate: `--repo`/`--target`/`--require-import`/
    `--require-contract` + a `--classify <reporter-json>` parse-only mode; `npm ci` (lockfile) else
    `npm install --legacy-peer-deps`, `npx hardhat compile`, then `npx hardhat test` through a generated wrapper
    config that forces mocha's `json` reporter; classifies the reporter stats with the inverted polarity. Exit
    codes 0/1/2 match `forge-invariant.sh`.
  - `evm-harness/forge-poc.sh` — NEW foundry CONCRETE-exploit gate (thin sibling of `forge-invariant.sh` for a
    single hand-driven `forge test --match-test test`, NOT `invariant`): same #1471 linkage gate + `--skip`
    harness isolation, same inverted-polarity classify (a matched test with status Success -> FINDING).
  - `evm-harness/detect-toolchain.sh` — NEW file-presence helper: `hardhat` (hardhat.config.*) / `foundry`
    (foundry.toml) / `unknown`; the single point where a caller picks hardhat-vs-forge.
  - **Anti-fabrication #1471 linkage gate** for BOTH gates: the generated PoC must reference the REAL target (an
    import/require path ending in the target basename, or — hardhat — a `getContractFactory("<Name>")`/
    `getContractAt("<Name>"` call) AND must NOT shadow it with a same-named toy contract. A miss is
    HARNESS_ERROR, never a verdict, and (hardhat) runs BEFORE any npm spend.
  - `run-poc.sh` — NEW lean operator runner mirroring `run-invariant-hunt.sh`'s rundir staging + `exec.env_passthrough`;
    auto-detects the toolchain and drives `poc-writer.ag` on the substrate. `evm-harness/hardhat-poc-fixture/` —
    NEW committed offline fixture (a real re-entrancy bug + a PoC that reproduces it + a substituted negative + a
    captured pass/fail/empty mocha JSON) exercising the gate's linkage + verdict-parse paths with NO node.
  - `demo-poc-gen.sh` — NEW CI-safe demo (source-guard + `--classify` verdict-parse + linkage-reject on CI; the
    full npm + LLM live paths toolchain-gated and SKIP on CI); wired into `tools/colony-lint.sh`. A confirmed PoC
    is a LEAD a human triages — this colony NEVER auto-submits.
- **Impact-substantiation / validity gate in the substrate** (#1522). The gate AFTER scope-gate (#1511) and
  BEFORE human submit. scope-gate closes the SCOPE wall (in-scope asset + eligible-impact set + not carved-out);
  it is necessary but NOT sufficient. A live Immunefi submission (Enzyme Onyx, `SyncDepositHandler`
  front-running) that PASSED all three scope-gate barriers was still CLOSED on an impact-validity ground: the
  PoC used a SIMULATED price increase (a hand-fed admin `updateShareValue`) and described front-running of a
  PRIVILEGED admin action, not extraction of an on-chain-provable claim the victims already held.
  - `auditor/agents/impact-gate.ag` — standalone dispatched agent (mirrors `scope-gate.ag` / `dup-scout.ag`).
    Env: `FINDING_IMPACT`, `POC_FILE`, `MECHANISM_NOTES`. A deterministic PoC-smell muscle (grep: `harness_set*`,
    mocks, price setters, admin/owner pranks) feeds an LLM judgement over three validity barriers — OWN-MECHANISM
    (vs a simulated critical transition) / NO-PRIVILEGED-TRIGGER (the loss must not need a trusted role to act) /
    PROVABLE-PRE-EXISTING-CLAIM (on-chain, per the protocol's own accounting). Emits exactly
    `IMPACT-GATE|<SUBSTANTIATED|SIMULATED-STATE|PRIVILEGED-TRIGGER|NO-PROVABLE-CLAIM>|<rationale>` — only
    `SUBSTANTIATED` should proceed to human submit. It NEVER submits. Validated live against the real Onyx PoC:
    verdict `PRIVILEGED-TRIGGER`, mirroring the platform reviewer's exact reasoning.
  - `demo-impact-gate.sh` source-guards the wiring (CI-safe) and runs the agent live over a fixture PoC (the Onyx
    simulated-state + privileged-trigger shape) when agentis is present; wired into `tools/colony-lint.sh`.
- **Scope + eligibility gate in the substrate** (#1511). The highest-leverage correctness check in the bounty
  pipeline: a confirmed finding pays NOTHING (and burns the per-report fee + reputation) unless its LOCATION is
  an in-scope asset AND its IMPACT is an eligible, non-excluded, non-audit-noted class. Two live sessions both
  died exactly here — a real bug in an unlisted module (out-of-scope asset) and a real bug in an in-scope asset
  whose impact was an explicit out-of-scope carve-out — so the gate runs BEFORE any DEVISE/PoC spend.
  - `auditor/agents/scope-gate.ag` — standalone dispatched agent (mirrors `audit-scout.ag` / `dup-scout.ag`).
    Env: `SCOPE_FILE` (the program's own scope: in-scope asset list + out-of-scope/known-issues section +
    eligible-impact set), `FINDING_LOCATION`, `FINDING_IMPACT`. The asset-path match is DETERMINISTIC (grep —
    the muscle); the impact/carve-out judgement is the LLM's over that same scope text. Emits exactly
    `SCOPE-GATE|<PAYABLE|OUT-OF-SCOPE-ASSET|EXCLUDED-CARVEOUT|INELIGIBLE-IMPACT>|<rationale>` — only `PAYABLE`
    should proceed. It NEVER submits.
  - `demo-scope-gate.sh` source-guards the wiring (CI-safe) and runs the agent live over a fixture scope when
    agentis is present; wired into `tools/colony-lint.sh`.
- **Audit-aware residual-hunt foundation** (#1485). The reward on a bounty is only in what a target's OWN
  audits MISSED, so the hunt must be audit-aware — a capability the blind auto-gen lacks (it fabricates toys
  or finds already-known issues). Two reliable shell primitives + a CI-safe demo:
  - `fetch-audits.sh <url…>` / `--manifest <file>` — the operator's one network step: download a target's
    public audit reports and `pdftotext` each PDF to text (SKIPs cleanly offline), writing `<out>/NN-*.txt`
    + an `index.tsv`, so the downstream boundary extractor + analyst read them offline.
  - `novelty-gate.sh --exclusion <file> <finding>` — rejects a finding that restates a KNOWN issue (matched
    by a shared target function/identifier plus salient-term overlap) with exit 1, passes a genuinely-novel
    one with exit 0. Errs toward flagging (a maybe-known finding is held for human review, never auto-staged),
    so the engine never surfaces an already-reported bug.
  - `demo-audit-hunter.sh` (pure bash/python3, localhost fetch — no external network) proves both, wired into
    `tools/colony-lint.sh`. This is the reliable mechanical core of the manual audit-driven hunt; the creative
    hypothesis step (analyst) remains a follow-up `.ag` colony layer. Submission stays strictly human-gated.

### Fixed
- **Coordinator submission-pass LIVE-dispatch wiring** (#1535, follow-up from #1534 QA of the #1509 capstone).
  Three gaps that only bit the operator-gated LIVE path (`run-audit-pass.sh`; the CI/offline path uses
  `PASS_FIXTURE` and never reaches the runners), so they were CI-untested and silently normalized the poc and
  devise stages to `incomplete`:
  - **poc CLI args.** `run_stage_live()` invoked every runner env-only, but `run-poc.sh` is CLI-flag driven
    (`--repo`/`--target`/`--hypothesis`/`--class`), not env. Added a poc-specific `run_poc_live()` branch that
    builds the CLI from `POC_REPO`/`POC_TARGET`/`POC_HYPOTHESIS`/`POC_CLASS` via `getenv()`, each `shell_escape()`d
    (already on `run-audit-pass.sh`'s `exec.env_passthrough`); the five `.ag` gates keep the generic env-only call.
  - **`run-poc.sh` `POC|` emit.** `run-poc.sh` only printed the human-facing `POC: <target> -> <verdict>` arrow
    banner (pinned by `demo-poc-gen.sh`), never the machine-readable `POC|<target>|<verdict>` line the coordinator
    scrapes. Added one additive `echo "POC|$TARGET|$VERD"` on stdout; the arrow banner is untouched.
  - **devise `NO-RESIDUAL` extraction.** `run-gate-agent.sh`'s single-prefix `grep -F "$PREFIX|"` dropped
    audit-scout's bare (non-piped) `NO-RESIDUAL` token before the coordinator ever saw it, so a genuine
    no-residual determination normalized to `incomplete`. Fixed at the root by threading a per-stage
    `VERDICT_NEGATIVE` (`NO-RESIDUAL` for devise, `""` elsewhere) into a new `--negative-token` extraction, plus a
    `--classify-log` pure-shell mode for CI. **`audit-scout.ag` is deliberately left UNTOUCHED** — piping the
    token as `NO-RESIDUAL|<reason>` (the alternative the issue sketched) would be a WORSE, silent regression: both
    `audit-scout.ag::outcome_of()` and `coordinator.ag::devise_class()` do UNANCHORED substring checks for
    `"RESIDUAL|"`, which `"NO-RESIDUAL|reason"` matches at offset 3, flipping a true NO-RESIDUAL into
    success/residual.
  - CI coverage: `demo-audit-pass.sh` gains an always-on offline round-trip through `run-gate-agent.sh
    --classify-log` (bare `NO-RESIDUAL` now surfaced, piped `RESIDUAL|` unchanged, omit-the-flag byte-identical)
    and an agentis-gated stub-runner LIVE dispatch (asserts the poc CLI-arg construction + `POC|...|FINDING`
    parsing); `demo-poc-gen.sh` pins the additive `POC|` emit (always-on source-guard + the gated hardhat e2e).
- **hardhat-poc.sh / forge-poc.sh relative-`--repo`/`--target` path doubling** (#1531, follow-up from #1507 /
  #1529). Hand-invoking either gate with a RELATIVE `--repo`/`--target` produced a doubled path
  (`.../hardhat-poc-fixture/hardhat-poc-fixture/...`) and a false `HARNESS_ERROR` — not reachable via the real
  pipeline (`run-poc.sh`/`demo-poc-gen.sh` always pass absolute paths), so it only bit direct manual invocation.
  Both gates now resolve `--repo` (mirroring `run-poc.sh`'s `REPO="$(cd "$REPO" && pwd)"`) and the resolved
  `--target` to absolute paths right after the existence checks, before they are re-referenced inside a
  `cd "$REPO"` subshell. Absolute-path callers are unaffected. `demo-poc-gen.sh` gains two toolchain-gated
  regression checks (relative `--repo`/`--target` from a different cwd for each gate) that reproduce the exact
  pre-fix failure and confirm the fix.
- **novelty-gate false-negative on a bare boundary-function mention** (#1496). `novelty-gate.sh` flagged a
  candidate as KNOWN whenever it shared a single function/identifier token with an exclusion line, even when
  the candidate discussed a completely different vulnerability class — so a genuinely-novel finding that merely
  *mentions* a boundary function (e.g. `withdraw()`) in an unrelated context was wrongly rejected as a
  duplicate. `salient()` now exposes the vuln-class keyword set separately from the identifier set, and the
  shared-identifier shortcut requires an overlapping vuln-class term too (`shared_funcs AND shared_vk`, not
  `shared_funcs` alone); the plain salient-term overlap threshold (`--min-overlap`) is unchanged. Regression:
  a new `residual` row in `bench/fixtures/rounding-residual/truth.tsv` and a new case in
  `demo-audit-hunter.sh`.
- **Invariant-hunt CODE_PATH resolution for nested `--target`** (#1475). `run-invariant-hunt.sh` defaulted the
  LLM source path (`CODE_PATH`) to `<repo>/src/<target-file>`, so a nested `--target` like
  `src/contracts/vault/Vault.sol:Vault` became `<repo>/src/src/contracts/vault/Vault.sol` (double `src/`) →
  `CODE_PATH` stayed **empty**. That both starved the LLM of the target source (it fabricates a toy of the same
  name) and **disarmed the #1471 linkage gate** (which only arms when `CODE_PATH` is non-empty), so the toy
  reached a FINDING instead of HARNESS_ERROR — proven live on a Symbiotic `Vault` run (FINDING against a test
  that imported nothing and declared its own `contract Vault`). Now resolves `<repo>/<target-file>` first, then
  the `<repo>/src/<basename>` convention — nested, `src/`-prefixed, and bare-basename targets all resolve, so
  the gate arms. Regression: `tools/test-invariant-codepath-resolution.sh`.
- **Invariant-hunt target-linkage gate** (#1471). Closes a false-FINDING hole on the invariant-hunt generation
  path: when the real target is hard to harness, the LLM could silently substitute its OWN toy contract of the
  same name and the fuzzer would "find" a bug it planted THERE — a FINDING against fabricated code with zero
  bounty value (proven live: a Liquity BOLD `StabilityPool` run produced a test that imported nothing and
  defined its own 16-line `contract StabilityPool`). `evm-harness/forge-invariant.sh` gains an optional
  `--require-import <target-src>` (+ `--require-contract <Name>`) gate: BEFORE forge runs, the test must carry
  an `import` line whose path ends with the target basename AND must NOT declare its own `contract <Name>`
  shadow (`StabilityPoolHarness` does not trip it) — a miss is `HARNESS_ERROR` (2), never a verdict. The
  prover (`auditor/agents/invariant-prover.ag`) threads the flags in **only in pure fresh-deploy mode** (no
  `FORK_URL`/`FORK_TARGET`/`FORK_CONTEXT`, a real `CODE_PATH`); in any fork/composability mode — where the
  target is referenced by on-chain address, not a source import — no link args are passed and the gate is
  byte-identical to before. `demo-invariant-linkage.sh` source-guards the wiring and runs the gate live when
  forge is present; wired into `tools/colony-lint.sh`.

### Added
- **Snapshot owner-rebind hard assert** (#1455 epic; #1457). Closes the owner-graph fidelity gap in
  snapshot replay: the `poc_snapshot` harness now **reads the account's real on-chain owner** from the
  dump and emits an explicit, machine-checkable `OWNER REBIND: <real owner> rebound to <program>` marker
  instead of a silent rebind (#1462 shipped only a static disclosure text). With `EXPECT_PROGRAM_OWNER`
  (run-audit `--expect-owner <base58>`, on the sandbox `exec.env_passthrough`) the harness **hard-asserts**
  owner-match — a mismatch is refused as `INCONCLUSIVE` (exit 3) *before* the exploit runs, so a re-owned
  copy is never reported VERIFIED. `run-audit.sh` REPRODUCTION.md/report disclosure updated to quote the
  harness's real-owner line + document the hard-assert; RUNBOOK "Known limitations" updated.
  `demo-owner-assert.sh` source-guards the harness + run-audit wiring (CI-safe) and runs the 3 modes live
  when the Solana toolchain is present; wired into `tools/colony-lint.sh`. (The `--poc` control-side
  "demonstrably invoke the target" hardening beyond #852's structural + target-linkage gate stays an
  operator-trust residual, flagged not closed.)
- **Bounty-weighted target prioritization in the prospector colony** (#1455 epic; #1459). The prospector
  qualifies EVM protocols as monitoring targets on three boolean hard gates; this adds a bounty dimension
  that ORDERS the operator's finite manual-review time by expected payout, without changing what qualifies.
  - **`coordinator.ag` bounty dimension** — the coordinator joins an operator-supplied
    `PROSPECTOR_BOUNTY_META` (`<address>|<reward_usd>|<in_scope_commit>`, matched case-insensitively) onto
    each dossier, adding a `bounty` reward figure + the in-scope `commit` the bounty covers. It is public
    program-page data the operator pastes in — **read-only, no egress** (the agent never fetches it) — and
    is **purely informational + for ordering**: the three hard gates remain the sole floor, and a qualified
    target with no bounty metadata still lists (ranked last). cb headroom 150000 → 200000 for the join.
  - **`prospector-queue.sh`** (new) — turns the qualified, bounty-annotated dossiers into an **audit queue
    ranked by expected payout** in the exact `run-batch.sh` TSV (`score<TAB>key<TAB>url<TAB>title<TAB>scope_hint`,
    bounty desc, ties by key asc). `scope_hint` carries `addr:<address>` (run-batch's autoharness resolver
    keys on it) + `commit:<in-scope-commit>` (the "audited the wrong version" 0-payout guard). Reads the
    `prospector:qualified` blackboard live via `agentis memo`, or `--dossiers <file>` offline; SKIPs cleanly
    when empty. `run-batch.sh --queue <this>` then hunts targets highest-payout-first. Submission stays
    strictly human-gated — the bridge has no platform egress and never posts.
  - **`demo-prospector-queue.sh`** (new, CI-safe: pure bash/python3) proves the rank order, that a big
    bounty on a non-qualifying target never enters the queue (gates are the floor), the `--min-bounty`
    floor, that `run-batch.sh` consumes the queue highest-first and stages nothing on a dry hunt, and the
    no-egress guard. Wired into `tools/colony-lint.sh`.
- **Bounty-funnel hardening: quantified impact, reproduction manifest, dedup + impact triage gates**
  (#1455 epic; #1456, #1457, #1458). Raises the *expected value per verified finding* — the funnel
  stage between `Verdict: VERIFIED` and a paid bounty — while keeping submission strictly human-gated
  (the colony still never posts to a platform).
  - **#1456 quantified impact in `report.md`** — `auditor.ag` now derives the funds-at-risk the
    two-sided PoC demonstrated (from the observed `account.lamports` / `vault.balance` markers, not a
    template constant) into a new `## Impact quantification` section, plus `Impact category` and
    `Severity rationale` table rows that map the finding onto the Immunefi severity bands. Immunefi pays
    on demonstrated fund-loss, not on a violated invariant; a marker-less (e.g. EVM/revm) run degrades to
    an explicit "quantify against the live deployment" note. New SHALLOW leaves `marker_int`,
    `funds_at_risk`, `impact_category_for`, `rubric_line_for`.
  - **#1457 reproduction manifest + owner-rebind disclosure** — `run-audit.sh` stages `REPRODUCTION.md`
    in the submission package: target sha256, harness kind, `rustc`/`cargo`/`agentis` versions,
    backend/sandbox, and a deterministic rerun command, so a platform triager can reproduce against the
    live deployment. On a snapshot-based run BOTH `REPRODUCTION.md` and the generated `report.md`
    snapshot-replay section now **disclose the account-owner rebind** (the harness program is not deployed
    on-chain) rather than shipping a silent mismatch, so the human states it up-front and re-verifies
    against real program-derived ownership before submitting. Also corrects the stale RUNBOOK
    "Known limitations" note: a supplied `BOUNTY_POC`/`--poc` is already gated by the #852 structural +
    per-run target-linkage challenge (a target-agnostic marker-printer is REJECTED as INCONCLUSIVE, not
    VERIFIED); only a sophisticated link-but-never-invoke PoC remains an operator-trust residual.
  - **#1456/#1458 triage gates in `submit-triage.sh`** — the scan gains an **IMPACT** column
    (`quant` / `qual?`) and, with a new `--known-issues <file>` public-disclosure list, a **NOVELTY**
    column that flags an already-disclosed finding as `DUP-RISK` instead of silently `READY` (Immunefi
    pays only the first reporter). The per-candidate checklist gains repro-manifest, impact-quantification,
    and dedup review items. Also fixes `severity_of` to read the real `| Severity (Immunefi) | … |` table
    row (it previously only matched a plain `Severity: …` line). Covered by `demo-submit-triage.sh`
    (offline, deterministic — no agentis, no network). Follow-ups tracked on the epic: the harness-level
    owner-match *assertion* for snapshot replay (the offline disclosure landed here; the hard assert needs
    the Solana toolchain) and bounty-weighted target prioritization in `prospector` (#1459).
  - **Review-driven correctness fix + regression tests (PR #1462)** — `marker_int` is now **line-anchored**
    (mirrors the harness `field()`'s `strip_prefix`) so `account.lamports=` never shadow-matches inside a
    longer key like `token_account.lamports=` in a multi-account dump; previously it could report a
    funds-at-risk figure that diverged from what the attached PoC drains. Added `demo-report-quality.sh`
    (agentis-gated, clean-SKIP on runners without the binary): a real `run-audit.sh --backend mock` VERIFIED
    run asserting the `report.md` impact rows/section, the `REPRODUCTION.md` sha256 + rerun command, the
    snapshot quantified-vs-qualitative split, the owner-rebind disclosure, and the multi-account regression.
    Extended `demo-submit-triage.sh` to cover INCOMPLETE-over-DUP-RISK precedence, the `dup_hit` body-match
    path, the `has_repro` present/MISSING checklist value, a no-trailing-newline known-issues line, and
    `severity_of` word-anchoring (17 assertions). `severity_of` now matches the severity WORD (`grep -iowE`)
    so an unrelated substring on a third-party report (`high`light / al`low` / be`low`) is not misread.
    `demo-report-quality.sh` (agentis-gated) additionally asserts the `shell_escape` command-injection
    defense end-to-end (a metacharacter-laden `BOUNTY_SNAPSHOT` does not execute) and the zero-value marker
    edge (`account.lamports=0` → Qualitative, not a fabricated figure). All three demos are wired into
    `colony-lint` so the CI-runnable checks (bash triage gates + source-level branch coverage) gate merges.
  - **Security hardening (PR #1462 review)** — `funds_at_risk` and `snapshot_state` now wrap the
    `BOUNTY_SNAPSHOT` path in `shell_escape()` before the `cat` in `exec sh` (replacing the
    `safe-exec-concat` waiver), so a hostile snapshot path (e.g. `x; touch pwned` set directly in an
    automation context) cannot inject a shell command. Verified: with a metacharacter-laden value the
    injected command does not run. The value is normally operator-supplied and `-f`-validated by
    `run-audit.sh`, but escaping closes the direct-env-set path too.
- **monitor: read robustness — RPC failover + read consensus, and a watch-spec drift detector** (#1098, #1097).
  Two hardening passes that keep a 24/7 read-only watch honest. NON-custodial / read-only throughout
  (`cast call` / `cast storage` / `cast balance` / `cast code` only — never a signed transaction, never fund
  access); all dynamic values `shell_escape()`d in the `.ag` and quoted in the scripts; big-number-safe (values
  stay strings; no i64 overflow); dash-safe + `set -eu` + shellcheck-clean scripts.
  - **#1098 RPC failover + read consensus** — `monitor/scripts/cast-read.sh` is now the ONE place chain reads
    happen, so failover lives in a single wrapper instead of being copy-pasted across the six watchers'
    `read_uint` / `read_view` / `read_slot` / `read_balance`. It reads a comma-separated `MONITOR_RPC_URLS`
    (falling back to the single `MONITOR_RPC_URL`), tries each endpoint IN ORDER on failure, and — when
    `MONITOR_RPC_CONSENSUS` is set (`1` ⇒ quorum 2, or any `N>=2`) — requires N endpoints to AGREE on the value
    before returning it, so a single lying / lagging node cannot drive a false `violated`. When ALL endpoints
    fail (or consensus can't be reached) it returns the no-read sentinel (empty stdout + non-zero exit),
    DISTINCT from a real verdict and feeding the dead-man's-switch / blind path (#1093). Read-only allowlist:
    only `call` / `storage` / `balance` / `code`; any write subcommand is rejected. The six watchers route
    through it via `MONITOR_CAST_READ` (defaulted to the colony's `scripts/cast-read.sh` by `start-colony.sh`);
    with `MONITOR_RPC_URLS` / `MONITOR_RPC_CONSENSUS` unset a single configured endpoint behaves exactly as
    before.
  - **#1097 watch-spec drift detector + re-derivation hook** — `run-live-watch.sh` now records a fingerprint of
    the deployed target at derivation time next to the spec at `<spec>.fingerprint.json`: the deployed-code hash
    (`cast code`) and the EIP-1967 implementation slot value (`cast storage`). `monitor/scripts/check-drift.sh`
    (a periodic job / cron) re-reads that fingerprint through `cast-read.sh` (so the failover + consensus apply)
    and raises a `monitor:alert` (kind `drift`, severity `high`, verdict `spec-stale`) when the deployed code /
    impl no longer matches — the monitor SAYS it has gone blind on a stale spec rather than silently watching
    stale invariants. No drift ⇒ quiet; a blind RPC re-read ⇒ quiet (never a false drift); an empty captured
    fingerprint ⇒ quiet. The optional re-derivation hook is documented as `run-live-watch.sh --rederive` (re-run
    the derivation to produce a fresh spec + fingerprint and hot-swap `MONITOR_INV_SPEC`; operator-gated).
  - New env contract (`MONITOR_RPC_URLS` / `MONITOR_RPC_CONSENSUS` / `MONITOR_CAST_READ`) is exported by
    `monitor/scripts/start-colony.sh`, documented in `monitor/config/colony.example.toml` (env block +
    `[monitor]` `rpc_urls` / `rpc_consensus` keys), and in `monitor/README.md` (env table + a "Read robustness"
    section and a "Watch-spec drift detection" section). Operators add each new `MONITOR_*` var to
    `exec.env_passthrough` in `.agentis/config`.
- **monitor: multi-tenant / fleet layer** (#1099) — `monitor/fleet.sh` (dash-safe, `set -eu`,
  shellcheck-clean) manages N watched targets as a NEW layer over the unmodified
  `monitor/scripts/start-colony.sh`: each target gets an isolated slot under
  `${MONITOR_FLEET_DIR:-$HOME/.agentis-monitor}/<slug>/` holding its own `target.env` (address, chain, RPC,
  webhook(s), watch-spec, tiers) and its own `.agentis` state (private daemon registry + memo baselines +
  logs), so targets never collide and an alert for target A never routes to target B's webhook. Subcommands
  `add` / `start [--all]` / `stop [--all]` / `list` / `status` / `path`; `stop` scopes the shutdown per-target
  via `kill-federation.sh --fed-dir`. New `monitor/config/target.example.toml` per-target config-unit template
  and `monitor/docs/fleet.md` operator notes (isolation model, per-target dashboard scoping). NON-custodial /
  read-only — the fleet only orchestrates the read-only colony.
- **monitor: backtest / calibration harness + scorecard + operator runbook** (#1101, #1102) — the Path C
  outreach proof. `monitor/backtest.sh` (dash-safe, `set -eu`, shellcheck-clean) points the
  `invariant-watcher`'s deterministic verdict logic at a fork pinned to HISTORICAL block heights around a
  known incident and replays it tick-by-tick via read-only `cast call --block <N>`, reporting (a) the PAGE
  at/before the incident block with its lead time and (b) a quiet pre-incident window's false-positive
  count/rate; it reuses the watcher's read path + verdict tokens (`violated`/`margin`/`ok`/`no-read`) and the
  fuse-to-worst SET rule byte-for-byte, accepts the same watch-spec `run-live-watch.sh` emits (`--spec`) or
  the single-invariant flags, and degrades gracefully (clear message, exit 4, no crash) without an archive
  node. `monitor/scorecard.md` is the credibility-artifact template (incident, lead time, which watcher
  fired, quiet-window false-positive rate), the monitoring peer of `evm-scorecard.md`. `monitor/docs/runbook.md`
  is the operator runbook: onboard a target (`run-live-watch.sh` → watch-spec → tiers → start → shadow→propose
  promotion → backtest), read an alert (verdict meanings, severity routing, ack/escalation via `notify.sh`
  #1094), respond (triage, when to page the client, dead-man's switch, postmortem template), and scope & SLA
  (non-custodial read/alert/report boundary, response-time tiers, supported + out-of-scope). NON-custodial /
  read-only throughout (`cast call` only — never a signed transaction, never fund access).
- **monitor: governance / upgrade + liquidity / flow / pause-state watchers** (#1095, #1096). Four more
  read-only, tier-gated watcher agents feed the monitor coordinator's `monitor:signal:*` blackboard, each with
  the same ADR-0001 emission pattern as `invariant-watcher` / `oracle-watcher` (one `tier()` call per tick,
  branch once; `cb 90000` matches `cb_budget`; `<agent>:last_check` written at the start AND end of every tick;
  a baseline learned via a durable memo; degrade-safe — no reader ⇒ `no-read` ⇒ no false flag; every `exec sh`
  dynamic value `shell_escape()`d). NON-custodial / read-only throughout (`cast call` / `cast storage` /
  `cast balance` only — never a signed transaction, never fund access).
  - **#1095 `governance-watcher.ag`** — the highest-value PRE-exploit early-warning. Reads the two canonical
    EIP-1967 storage slots (implementation `0x360894…d382bbc` + admin `0xb53127…5d6103`) via `cast storage`,
    plus an optional `owner()`/`admin()` view, a role-grant indicator, and a timelock-queue indicator via
    `cast call`, and flags a CHANGE vs the learned per-field baseline (an impl-slot flip / a new admin or owner /
    a role grant or pending timelock op — the upgrade-attack tell). Verdict tokens `impl-changed` /
    `admin-changed` / `owner-changed` / `gov-changed` / `ok` / `no-read`. Posts `monitor:signal:governance`.
  - **#1096 `liquidity-watcher.ag`** — reads a pool / vault reserve or TVL proxy (`totalAssets()` or, with no
    view configured, native `cast balance`) and flags a drop beyond a learned band (`MONITOR_LIQ_DROP_BP`) — a
    sudden drain; a rise is never an anomaly. Verdict `drained` / `ok` / `no-read`. Posts
    `monitor:signal:liquidity`.
  - **#1096 `flow-watcher.ag`** — reads the same level proxy and flags an abnormal net outflow burst over a
    window (a net fall since the previous reading exceeding `MONITOR_FLOW_OUT_BP` of the held reserve). Verdict
    `outflow-burst` / `ok` / `no-read`. Posts `monitor:signal:flow`.
  - **#1096 `pause-state-watcher.ag`** — reads the `paused()` / circuit-breaker boolean and flags a state
    transition vs the learned baseline (a protocol pausing itself is signal; a recovery is surfaced too).
    Verdict `paused` / `unpaused` / `ok` / `no-read`. Posts `monitor:signal:pause`.
  - `coordinator.ag` now fuses the four new `monitor:signal:*` kinds into the consolidated severity score, the
    dedup signature, AND a per-signal dossier (the emitted `monitor:alert` carries a `"signals"` map of every
    watcher's verdict), alongside the existing `invariant` / `oracle` signals — keeping its single-`tier()`-per-
    tick discipline; the fusion math is a watcher-agnostic `reduce` over the signal list.
  - All four agents are registered in `monitor/config/colony.example.toml` (`[[agents]]`, `cb_budget` matching
    `cb`) and `monitor/scripts/start-colony.sh` (`AGENTS`, `tick_interval_for`, and the `MONITOR_GOV_*` /
    `MONITOR_LIQ_*` / `MONITOR_FLOW_*` / `MONITOR_PAUSE_*` env exports). The new env contract is documented in the
    config, `monitor/README.md` (agent table + mermaid + env table + a per-watcher section), and the `[monitor]`
    comment block. Operators add each new `MONITOR_*` var to `exec.env_passthrough` in `.agentis/config`.
- **monitor: alert-delivery pipeline — the bus→webhook bridge, liveness, and a hardened sink** (#1092, #1093,
  #1094). The monitor colony emitted `monitor:alert` on the bus but nothing forwarded it, so in a real
  deployment no page was ever delivered. A new `notifier` agent (`dark-factory/monitor/agents/notifier.ag`,
  `cb 90000`) closes that last-mile gap:
  - **#1092 bus→webhook bridge** — the `notifier` `listen()`s for `monitor:alert` and forwards each alert to
    `scripts/notify.sh` via `exec sh`. The alert JSON is passed through an exported env var
    (`MONITOR_ALERT_BODY`), never interpolated into the shell text, and every other dynamic value is
    `shell_escape()`d. Forwarding is gated purely on the agent's ADR-0001 tier (one `tier()` call/tick, branch
    once); needs `--enable-messaging` + `--enable-exec` (wired into `start-colony.sh` + registered in
    `config/colony.example.toml`).
  - **#1093 heartbeat + dead-man's switch** — a periodic low-severity `heartbeat` is sent through `notify.sh`
    at `MONITOR_HEARTBEAT_INTERVAL_S` cadence (default daily) so silence is meaningful; and a memo-freshness
    dead-man's switch emits a `high`/`liveness` meta-alert when no watcher tick / fresh `*:last_check` memo is
    observed within `MONITOR_DEADMAN_WINDOW_S` (the RPC-blind / colony-down case), deduped against the last
    liveness signature so a persistent outage pages once.
  - **#1094 hardened `notify.sh`** — bounded exponential retry/backoff on a transient webhook failure
    (`5xx`/network; a `4xx` is not retried); sink-side dedup keyed on the alert signature with a cooldown
    window (`MONITOR_NOTIFY_DEDUP_COOLDOWN_S`, persisted to a small state file); and severity routing so
    `warn`/`high` land in different channels (`MONITOR_WEBHOOK_URL_WARN` / `MONITOR_WEBHOOK_URL_HIGH`, each
    falling back to `MONITOR_WEBHOOK_URL`). Dash-safe (`set -eu`, shellcheck clean, no `\xHH` escapes). Unset
    config preserves the original single-webhook stdout-fallback behaviour exactly.

  Non-custodial / read-only throughout: the notifier only reads the bus and sends an outbound notification — it
  never signs and never touches funds.

### Fixed
- **monitor: big-number-safe wei handling in `invariant-watcher` / `oracle-watcher`** (#1109). The two CORE
  watchers still read on-chain quantities through a bare `parse_int`, which SATURATES any value above i64 max
  (9223372036854775807 ≈ 9.22 ETH at 18 dp) to `0`. `invariant-watcher` reads solvency-grade magnitudes like
  `totalAssets()` / `totalSupply()` (a real $100M vault ≈ 1e26 wei), so BOTH sides read as `0`,
  `verdict_of(0, 0, ge)` returned `ok`, and the watcher reported EVERY real protocol healthy regardless of true
  state — solvency-blind on essentially every live target (confirmed: `parse_int("176142539498998091993593571")
  = 0`). The margin band `(|lhs - rhs|) * 10000 / rhs` separately overflowed i64 for any in-range 18-digit side.
  `oracle-watcher` shared the same `reading_to_int` + `(diff * 10000) / base` deviation pattern (mostly escaping
  for 8-dp prices, but unsafe for large / high-decimal feeds). Both watchers now mirror the proven #1095 /
  liquidity-watcher / value-scorer idiom: read each side as a validated DECIMAL STRING (`reading_to_dec` /
  strip-leading-zeros / digits-only validate / `""` no-read sentinel); SCALE >18-digit values down by truncating
  the same number of low-order digits from BOTH (the relation / ratio is preserved; the `""` sentinel survives
  scaling, so cold-start and RPC-blind ticks never false-fire or divide by zero) BEFORE any `parse_int`; and
  compute the basis-point margin / deviation DIVISION-FIRST (`unit = rhs / 10000`; `gap_bp = diff / unit`) so
  there is no large multiply to overflow. `oracle-watcher`'s sanity BOUNDS now compare the un-scaled price
  digit-string against MIN/MAX with the big-decimal comparator (exact for high-decimal feeds). The
  single-invariant `tick()` path, the `MONITOR_INV_SPEC` multi-invariant SET path (`spec_verdict` / `fuse_set`),
  and the alert/signal payloads (which now carry the full magnitudes as quoted JSON strings, like
  liquidity-watcher's `value_for_json`) are all big-number-safe. Everything else is preserved: one `tier()` per
  tick + branch once, `cb 90000`, `<agent>:last_check` at tick start + end, `shell_escape()` on every `exec sh`
  value, the `cast-read.sh` / `MONITOR_CAST_READ` failover read path, the no-read (`""` / `-1`) and cold-start
  sentinels → no false flag, non-custodial read-only. Verified via `agentis repl` with real 1e26 magnitudes: a
  solvent vault (`totalAssets = 176142539498998091993593571` ≥ `totalSupply = 149658545051669083717603536`, rel
  `ge`) now yields `ok` (was a false `0`-based `ok`), the same magnitude underwater (assets < shares) yields
  `violated` (was a false `ok`), a thin-margin case yields `margin`, and cold-start (`-1`) / no-read (`""`) yield
  no flag and no div-by-zero; `oracle-watcher` flags a 5% move on an 18-dp feed as `deviation` (`dev_bp = 500`,
  was blind) and bounds-violations on high-decimal feeds as `bounds`.
- **monitor: big-number-safe wei handling in `liquidity-watcher` / `flow-watcher`** (#1095, #1096). Both
  watchers read an on-chain reserve / level (a TVL proxy in wei) and fed it through a bare `parse_int`, which
  SATURATES any value above i64 max (9223372036854775807 ≈ 9.22 ETH at 18 dp) to `0` — so a 1000-ETH vault
  (1e21 wei) baselined at `0`, and a real drain to 1 ETH read as verdict `ok`: the drain was invisible on
  essentially every real target. The basis-point ratio `(base - reserve) * 10000 / base` separately overflowed
  i64 for any drop past ~0.001 ETH on an 18-dp token, computing `drop_bp = 0`. Both watchers now keep the
  reading + baseline as DECIMAL STRINGS (reusing the prospector `value-scorer`'s big-decimal idiom), SCALE both
  down to ≤18 digits by truncating the same number of low-order digits from BOTH before any `parse_int` (the
  ratio is preserved; the "" no-read / no-baseline sentinel survives scaling, so cold-start and RPC-blind ticks
  never false-fire or divide by zero), and compute the basis-point drop DIVISION-FIRST (`unit = base / 10000`;
  `drop_bp = diff / unit`) so there is no large multiply to overflow. The baseline is persisted as the same
  digit string it is compared in, and the alert/signal payloads carry the full wei magnitudes as JSON strings.
  Verified via `agentis repl`: a 1000-ETH baseline drained to 1 ETH now yields `drained` with `drop_bp ≈ 9990`
  (was `ok`/`drop_bp = 0`), an in-range 5-ETH→2.5-ETH drop yields `drop_bp = 5000`, and cold-start / no-read
  yield no flag.
- **monitor: JSON-escape free-text fields in alert/signal payloads** (#1089). `invariant-watcher` and
  `oracle-watcher` now route the operator-supplied `label`/`addr` through a `json_escape()` helper (escapes
  `\` and `"`) in every alert/signal payload builder, so a label containing a `"` can no longer corrupt the
  emitted JSON. Per-char fold (`.ag` has no string-replace builtin). Verified via `agentis repl`:
  `json_escape("a\"b\\c")` → `a\"b\\c`.
- **`flat-cyborg-claude.sh` uses `--extract-structural`** (#1083, needs flat-cyborg ≥ 0.10.2). claude
  intermittently omits the reply sentinel; strict `--extract` then burned the full `--timeout-ms` and exited
  "no fenced reply", which the agentis caller retried — repeated ~700 s gen hangs ending in HARNESS_ERROR
  (several sweep TIMEOUTs traced to exactly this). With flat-cyborg #55 (v0.10.2), `--extract-structural`
  completes on a SETTLED screen and recovers the reply marker-first → structural-fallback (fast +
  marker-less-tolerant); a marker-ful reply is extracted exactly as before.
- **invariant-prover cuts false-positive findings — realistic input bounds + mocked-dep decimal/type fidelity**
  (#1080, epic #1041). A real autonomous sweep produced two FINDINGs that triaged to harness artifacts, not
  bugs: an oracle target's unbounded price-setter let the fuzzer drive the price to absurd magnitudes
  (`2.26e30`) and trivially break a sanity-band invariant; and a mocked dependency used 18 decimals while the
  target computes that token in 6 (10^12 mismatch) → a spurious solvency break. The `generate_test()` prompt
  now directs the model to (a) `_bound` every fuzzed input — ESPECIALLY external-perturbation actions
  (price/oracle/deviation/donation/fee setters) — to a REALISTIC range, and that a break caused SOLELY by an
  absurd-magnitude input is NOT a finding; and (b) make every mock of an external dependency MATCH the real
  units/decimals/types the target assumes (read from the target source) — a mismatched mock is invalid.
  Regression guard: `tools/test-invariant-prover-false-positives.sh`.
- **invariant-hunt SLIMS the embedded contract source(s) in the generation prompt** (#1079, epic #1041). On a
  real autonomous sweep every cross-contract PAIR (two full contract sources in ONE gen prompt) and one complex
  single-contract target hit the per-run timeout: the flat-cyborg→claude generation hung on a SINGLE gen call
  for ~712 s because the prompt embeds the FULL source of each contract (a pair ≈ 90 KB of Solidity), so all
  cross-contract coverage was lost. The OUTPUT ask was already bounded (#1067); this slims the INPUT.
  `run-invariant-hunt.sh` now stages the target source (`CODE_PATH`) and each `--aux` source (#1075) through a
  portable awk Solidity-source SLIMMER (`slim_sol_source`) instead of a flat `cp`: it drops `//`/`///` line
  comments (full-line + safe trailing), `/* ... */` block comments INCLUDING multi-line NatSpec `/** ... */`
  (a single-pass block-comment state machine — a naive sed cannot span lines robustly), `import ...;` and
  `pragma ...;` statement lines, and squeezes runs of blank lines to one — while KEEPING every line of real
  callable surface + logic: the `contract <Name> is ...` declaration, state variables, every function signature
  AND body, and structs/enums/events/errors. The prover's contract is unchanged — it still `cat_file`s the same
  staged `CODE_PATH`/aux paths and the generation prompt's STRUCTURE is identical; only the embedded source
  content is smaller (roughly halved on heavily-NatSpec'd sources). Trailing-comment stripping is CONSERVATIVE:
  a `//` is stripped from a code line only when no quote (`"`/`'`) precedes it on that line, so a `//` inside a
  string literal is NEVER corrupted (correctness of the staged Solidity over maximal slimming). An empty-output
  guard never ships an empty / truncated `CODE_PATH`: a pathological all-comments/all-import source that slims to
  only blank lines falls back to the ORIGINAL verbatim. A new deterministic guard,
  `tools/test-invariant-hunt-slim-source.sh`, feeds a fixture `.sol` (every comment/import/pragma/blank-run noise
  class + real `contract`/state/function/struct/event/error code) through the live slimmer and asserts the noise
  is removed, the real code survives intact, a string-literal `//` is preserved, and the empty-output fallback
  fires — plus that the runner wires the slimmer into BOTH stagings (grep/awk over the runner, no LLM/forge).
- **invariant-prover ENFORCES both-real cross-contract deployment (composable-fresh)** (#1077, epic #1041). In
  composable-fresh mode (#1075, `INV_AUX` non-empty) the LLM was supposed to deploy + wire the target AND each
  aux contract REAL. Validation on two real pairs showed it instead deployed only the EASIER contract real and
  MOCKED/OMITTED the harder one (`--target dreUSDs --aux dreRewardsDistributor` → real distributor + a
  `RewardVaultMock`; `--target dreUSDManager --aux dreUSDOracle` → real oracle, manager never imported). A CLEAN
  on a harness that mocked the unit-under-test is a FALSE verdict. `auditor/agents/invariant-prover.ag` now
  enforces both-real via validation + targeted repair (reusing the #1073 loop) — NOT a Solidity-parsing deploy
  scaffold, and ONLY active in composable-fresh mode (the #1070-B1 single-target path is byte-identical, the
  offline `HANDLER_FIXTURE` path is untouched). A `missing_real_deploys(testSrc, names)` helper reports, over the
  `{target name} ∪ {each aux name}` set, every contract MISSING BOTH an `import {<name>}` marker AND a
  `new <name>(` marker (the latter covers the plain `new` form and the `new ERC1967Proxy(address(new <name>()...`
  proxy form) — i.e. dropped or mocked. The #1073 repair trigger is EXTENDED: a round also fires when
  composable-fresh AND `missing_real_deploys(...)` is non-empty, with a POINTED repair prompt that names the
  missing contracts ("Your test did NOT deploy these REQUIRED real contracts (you mocked or omitted them): …")
  and tells the model to keep the ones already real. After the `INV_REPAIR_ROUNDS` budget is exhausted, a
  RESIDUAL both-real violation FORCES the emitted verdict to `HARNESS_ERROR` (with a stderr reason: "harness
  mocked/omitted required real contract(s): …") — even if the gate returned CLEAN/FINDING on the partial harness
  — so a FALSE cross-contract CLEAN can never leak; a genuine FINDING/CLEAN on a harness where ALL named
  contracts are real passes through unchanged, and the gate exit code stays the source of FINDING/CLEAN when
  both-real holds. The both-real check is pure string work on the (untrusted) test source (no shell), the loop
  stays bounded by the existing single-assignment recursion (no `while`/`for`), and the stderr reason is
  `shell_escape()`d. A new deterministic guard, `tools/test-invariant-prover-both-real.sh`, pins the both-real
  check, the extra repair trigger, the pointed message, the force-`HARNESS_ERROR`-on-residual-violation override,
  and the single-target/fixture exemption (grep over the `.ag`, no LLM/forge).
- **invariant-prover drives the REAL target, not a mock** (#1070-B1, epic #1041). The live-path generation
  instruction in `auditor/agents/invariant-prover.ag` (`generate_test()`) used to tell the model: import the
  target "if the project ships it there; otherwise inline a minimal copy." On a realistically-sized target the
  model frequently inlined a MOCK of the unit under test and fuzzed the mock, so the FUZZER's verdict was about
  fake code, not the real contract. The bullet is now a STRONG real-target directive — IMPORT and DEPLOY the
  REAL contract under test; a minimal mock of an EXTERNAL dependency (an ERC20 asset, an oracle) is fine, but
  the unit under test MUST be the real imported contract — plus `setUp()` deploy guidance for both a normal
  `constructor(args)` and an OpenZeppelin **upgradeable** contract (an `ERC1967Proxy` +
  `abi.encodeCall(<Target>.initialize, ...)` recipe for the `_disableInitializers()` case). The agent also
  computes the exact relative import path (`CODE_PATH` relative to `dirname(INV_OUT)` via
  `realpath --relative-to`) and injects it as an `import {<Name>} from "<RELPATH>";` line so the model wires
  the import correctly; when no target source is supplied the import-path line is skipped (today's behaviour).
  The #1067 bounding is preserved unchanged — EXACTLY ONE lens-driven invariant + a minimal handler under the
  `~120-line` budget (the real-deploy `setUp()` now counts toward that budget). A new deterministic guard,
  `tools/test-invariant-prover-real-target.sh`, pins the real-target directive + the proxy recipe + the
  import-path injection (grep over the `.ag`, no LLM). The compile-repair loop is a separate follow-up.
- **invariant-prover bounded compile-repair loop** (#1073, epic #1041). With #1069 harness-isolation, a
  `HARNESS_ERROR` (forge exit code not in {0,1}) on the **LLM-generated** path means OUR generated handler
  failed to compile / matched no `invariant_*` — a recoverable fault, not the target's other tests. The prover
  used to do ONE shot (generate → write to `INV_OUT` → run `forge-invariant.sh` → map the exit code to a
  verdict), so a single bad first generation wasted the whole run. `auditor/agents/invariant-prover.ag` now
  runs a BOUNDED compile-repair loop: on a `HARNESS_ERROR` it extracts a capped compiler-error excerpt from
  forge's output, feeds it back to the model with the prior test source (a `repair_instruction()` reasserting
  the same hard constraints — `pragma ^0.8.20`, no forge-std, `targetContracts()`, plain `require()`,
  `<matchPrefix>_*` naming, import+deploy the REAL target, output-only), writes the repaired source through the
  SAME `shell_escape()`d `printf` mechanism (never a heredoc — the test is untrusted), and re-runs the gate.
  The loop is a bounded recursion (single-assignment `.ag` has no `while`/`for`) carrying the
  `(stopped, testSrc, runOut)` state, with the round count from `getenv("INV_REPAIR_ROUNDS")` (default **2** —
  so ≤3 total attempts — on unset/empty/non-numeric; `0` disables repair = today's one-shot). It STOPS the
  moment the gate returns a real verdict (`FINDING`/`CLEAN`), and the verbatim `HANDLER_FIXTURE` path is NEVER
  LLM-repaired (the fold is seeded already-stopped when `usedFixture`). The FINAL emitted verdict, the
  `learn()`/experience outcome, and the `INVARIANT|<file:fn>|<token>` line stay the gate's exit code on the
  LAST attempt — never the LLM's opinion (unchanged contract). `run-invariant-hunt.sh` gains a
  `--repair-rounds N` flag that threads `INV_REPAIR_ROUNDS` through. A new deterministic guard,
  `tools/test-invariant-prover-repair-loop.sh`, pins the loop (grep over the `.ag`, no LLM/forge).

### Added
- **`prospector` colony — qualify EVM protocols as monitoring targets by public on-chain/source signals**
  (#871). A new colony alongside `monitor` + `auditor` that takes a list of candidate EVM protocols and decides
  which ones are worth standing up the `monitor` colony on, and why. NON-custodial / read-only: every agent only
  READS public source/ABI + on-chain state via `cast`/explorer over `exec sh` (each dynamic value
  `shell_escape()`d) — no agent signs a transaction or touches funds, and the value-scorer uses ONLY `cast call`
  / `cast balance` (never `cast send` / a key / a write-RPC). The qualification verdict is a FACT (a source/ABI
  read + a read-only on-chain value read + a deterministic comparison), never an LLM opinion. This PR ships the
  lint-clean foundation: the colony scaffold (`prospector/{agents,config,scripts,README.md}`, `[forge] type =
  "none"` per ADR-0003), the four agents, and the confidence-tiered qualification pipeline.
  - `prospector/agents/intake.ag` — ingests the candidate protocol list from `PROSPECTOR_CANDIDATES` (newline
    `<address>|<chain>[|<metadata>]` cells), validates (`0x` + 40 hex address, integer chain id) + dedups each
    candidate, and writes the normalised `prospector:candidates` blackboard memo.
  - `prospector/agents/source-classifier.ag` — for each candidate reads its verified function-signature surface
    via a configured reader command (`PROSPECTOR_ABI_CMD`, e.g. `cast interface` or a keyless Sourcify ABI fetch;
    the address/chain reach the reader as exported env vars, never interpolated) and classifies whether it
    exposes a DeFi value-invariant family (lending / vault-4626 / AMM / stablecoin / perps / staking / bridge) —
    the monitorability gate. Posts `prospector:classified:<addr>`.
  - `prospector/agents/value-scorer.ag` — for each candidate reads a read-only on-chain value proxy (a `cast
    call` view such as `totalAssets()`, or the contract's native `cast balance`) and decides whether it clears a
    configured value floor — the value-floor gate. The value + floor are compared as BIG-DECIMAL strings (a TVL
    in wei exceeds i64, which `parse_int` cannot hold and which corrupts JSON number parsing downstream), so the
    digit strings are compared digit-wise and carried as JSON strings. Posts `prospector:value:<addr>`.
  - `prospector/agents/coordinator.ag` — fuses the three HARD GATES (verified-source + DeFi-value-invariants +
    value-floor) into a per-target qualification verdict and writes the `prospector:qualified` dossier (per-target:
    qualifies yes/no, the matched family, the failed gate when any, and the suggested invariant to watch — the
    handoff to the `monitor` colony, phrased in the monitor's `MONITOR_INV_*` terms) plus a ranked
    qualifying-target index. Single-assignment helpers, reduce/bounded-recursion (no loops), per the
    `auditor`/`monitor` coordinator pattern.
  - **Confidence-tiered qualification (ADR-0001) as the false-positive control.** Every agent makes ONE `tier()`
    call per tick and branches once; the tier gates PUBLICATION only (the verdict is identical at every tier):
    `shadow`/`dormant` score + write the dossier (no publish), `propose` emits a draft shortlist, `review-gated`/
    `autonomous` publish the ranked dossier index. `cb <N>;` matches `cb_budget`, and every tick begins + ends
    with `memo_write("<agent>:last_check", now)`.
  - `prospector/scripts/start-colony.sh` — ADR-0003-conformant daemon launcher (symlink-safe `$0`, sources
    `parse-toml.sh`, exports the `PROSPECTOR_*` env contract, `--restart-agent`, allowlisted daemon flags).
  - `prospector/README.md` — agent table + mermaid diagram + the env contract + the tier semantics + the
    `monitor`-colony handoff recipe.
  Follow-ups (out of scope here): off-chain qualification signals (web-research scoring) and freshness via
  deploy-time indexing. The colony NEVER signs and NEVER touches funds.
- **`monitor` live-watch runtime — derive a target's invariant SET once, watch the whole set continuously**
  (#1086, builds on the `monitor` colony #1085). The `monitor` colony's `invariant-watcher` evaluated ONE
  env-configured invariant against live on-chain state; dark-factory separately DERIVES a target's deep
  invariants (`run-invariant-hunt.sh` + `auditor/agents/invariant-prover.ag` + `evm-harness/`). This bridges
  the two: derive a target's invariant SET ONCE, emit a static **watch-spec**, then have the watcher re-check
  the WHOLE set continuously — no re-derivation per tick. READ-ONLY / NON-custodial throughout (a watch-spec
  is a set of facts to read + compare; it carries no keys and never describes a write).
  - `run-live-watch.sh` — given a target (`--repo`/`--target` + `--address` + `--rpc-url`), DERIVES the
    invariant set ONCE by REUSING `run-invariant-hunt.sh` (the established invariant-prover derivation entry
    point), then EXTRACTS the live-watchable two-sided comparisons (a view-call vs another view-call, or vs a
    literal bound — `require(a() <= b())` / `require(a() >= <n>)` / `assertLe(a(), b())`) from the generated
    invariant test into a **watch-spec**: a JSON array of `{label, lhs_sig, rhs_sig | rhs_const, rel,
    margin_bp}` objects (`rel` ∈ `le|ge|eq`). Complex multi-term/arithmetic invariants are deliberately
    UNDER-extracted (not a single live two-`cast` comparison) rather than emitted as an unwatchable spec. An
    offline `--spec-fixture <file>` path (the sibling of `run-invariant-hunt.sh`'s `--handler-fixture`) takes a
    hand-authored watch-spec VERBATIM — NO LLM, NO forge — so the derive→spec wiring is provable
    deterministically. POSIX-sh, dash-safe (`set -eu`), shellcheck-clean; all JSON construction goes through
    `python3 json.dumps` (the repo convention) so no signature can corrupt the spec; `--address` (0x + 40 hex)
    and `--rpc-url` (http(s)) are validated.
  - `monitor/agents/invariant-watcher.ag` — now ALSO consumes a derived watch-spec via `MONITOR_INV_SPEC` (an
    absolute PATH to the JSON file, or the JSON array INLINE). When SET, the watcher evaluates EVERY invariant
    in the set against live state each tick — `.ag` has no loops, so the set is walked by BOUNDED RECURSION
    over the array indices (cap 64; the runtime exposes no json-array-length builtin, so the walk stops at the
    first entry with no `lhs_sig`), reading each side with the SAME `shell_escape()`d `cast call` reader and
    the SAME deterministic `verdict_of()` the single-invariant path uses. Each member's verdict is posted to
    its own `monitor:signal:invariant:<label>` blackboard memo (the label is sanitized for the memo-key
    charset; the JSON payload keeps the original label), and the members are FUSED to the worst verdict across
    the set (`violated` > `margin` > `ok`) — one broken member pages the whole set. The fused verdict drives
    the EXISTING tier-gated emission (ONE `tier()` call per tick, branch once, `monitor:alert` on an anomaly),
    and the fused `monitor:signal:invariant` memo the `coordinator` already reads is unchanged. When
    `MONITOR_INV_SPEC` is UNSET the watcher's behaviour is byte-identical to before — the single env-configured
    invariant; `cb 90000` matches `cb_budget`, and every tick still ends with `memo_write(...:last_check)`.
  - `monitor/README.md` (a "Derive → watch the whole invariant set" section + the `MONITOR_INV_SPEC`
    env-contract row), `monitor/config/colony.example.toml`, and `monitor/scripts/start-colony.sh` (exports
    `MONITOR_INV_SPEC`) document the derive→watch flow. The colony stays read-only and never signs / never
    auto-submits.
- **`monitor` colony — continuous protocol monitoring with confidence-tiered alerting** (#1085). A new colony
  alongside `auditor` that continuously WATCHES a target EVM protocol and emits reasoned, high-signal anomaly
  alerts on the bus (`monitor:alert`). NON-custodial / read-only: every watcher only READS chain state via
  `cast`/RPC over `exec sh` (each dynamic value `shell_escape()`d) — no agent signs a transaction or touches
  funds. The hot-path verdicts are FACTS (an on-chain read + a deterministic comparison), never an LLM opinion.
  This PR ships the lint-clean foundation: the colony scaffold (`monitor/{agents,config,scripts,README.md}`,
  `[forge] type = "none"` per ADR-0003), two highest-value watchers, the fusion coordinator, and a webhook sink.
  - `monitor/agents/invariant-watcher.ag` — evaluates a derived protocol invariant (e.g. `totalSupply() <=
    totalAssets()`) against current on-chain state and flags a violation or a thin margin-to-violation. The
    invariant sides, target address, relation, and margin band come from env/config (getenv).
  - `monitor/agents/oracle-watcher.ag` — watches a price feed for deviation (vs a learned baseline) / staleness
    (feed age) / out-of-bounds price, same on-chain read pattern.
  - `monitor/agents/coordinator.ag` — fuses the two watcher signals off the shared `monitor:signal:*` blackboard
    (single-assignment helpers, no loops), dedups a persistent condition against the last emitted signature,
    decides fused severity, and emits one consolidated `monitor:alert`.
  - **Confidence-tiered alerting (ADR-0001) as the false-positive control.** Every agent makes ONE `tier()` call
    per tick and branches once; the tier gates EMISSION only (the verdict is identical at every tier): `shadow`/
    `dormant` observe + learn a baseline (no emit), `propose` emits a DRAFT alert (low severity), `review-gated`/
    `autonomous` emit a DIRECT page (high severity). `cb <N>;` matches `cb_budget`, and every tick ends with
    `memo_write("<agent>:last_check", now)`.
  - `monitor/scripts/start-colony.sh` — ADR-0003-conformant daemon launcher (symlink-safe `$0`, sources
    `parse-toml.sh`, exports the `MONITOR_*` env contract, `--restart-agent`, allowlisted daemon flags).
  - `monitor/scripts/notify.sh` — a thin POSIX-sh / dash-safe notifier that POSTs an alert payload to a
    Discord/Slack webhook when `MONITOR_WEBHOOK_URL` is set (no secret committed; read-only); prints to stdout
    as a no-op sink when unset.
  - `monitor/README.md` — agent table + mermaid diagram + the env contract + the tier semantics.
  Follow-ups (out of scope here): the liquidity / governance / flow watchers, the live-watch runtime (#1086),
  and a dashboard view. The colony NEVER signs, NEVER touches funds, and NEVER posts without a configured sink.
- **invariant-prover cross-contract multi-deploy harnesses (composable-fresh)** (#1075, epic #1041). The
  FRESH-DEPLOY real-target path deployed ONE target (single-contract) + mocked its externals, so the
  highest-value stablecoin bugs — which are CROSS-contract (oracle manipulation → manager mispricing; reward
  accrual → vault share inflation) — were structurally out of a single-contract harness's reach.
  `run-invariant-hunt.sh` gains a repeatable `--aux <Contract.sol[:Name]>` flag (relative to `--repo`, like
  `--target`): each value is validated the way `--target` is (exists, is a `*.sol`), staged into the rundir, and
  threaded to the prover as `INV_AUX` — a sentinel-joined list of `<abs_path>:<Name>` entries (sentinel `@@A@@`,
  which can occur in neither a filesystem path nor a Solidity identifier), also added to
  `exec.env_passthrough`. When `INV_AUX` is non-empty (composable-fresh mode)
  `auditor/agents/invariant-prover.ag` EXTENDS the generation prompt: it injects every auxiliary's source
  (clearly delimited `=== AUX CONTRACT (<name>) ===`), an import line per auxiliary (reusing the #1070-B1
  `import_line`/`rel_import_path`/`cat_file` helpers — no duplicated import/deploy machinery), and a new
  `compose_fresh_seed()` directive: deploy + WIRE the WHOLE system in `setUp()` (deploy the target AND each
  auxiliary, reading their constructors/initializers from the sources — the ERC1967Proxy recipe for upgradeable
  ones — then wire them via their setter/admin functions inferred from the sources), register the relevant
  contracts via `targetContracts()`, write a Handler whose actions SPAN the system, and EXACTLY ONE deep
  cross-contract invariant (NO free value extraction / system solvency holds across any sequence). The size
  budget grows to `~180 lines` in composable-fresh mode (still bounded). The whole composable-fresh extension is
  gated behind a non-empty `INV_AUX`, so with no `--aux` the rendered single-target prompt is **byte-identical**
  to #1070-B1 (verified by md5 of the rendered prompt), and the #1067 bounding, the #1073 compile-repair loop
  (a multi-deploy `setUp()` is MORE likely to need repair, and the new prompt flows through the same
  generate→write→gate→repair path), the fork-based `fork_seed`/`compose_seed` (FM1/FM2-fork), the offline
  `HANDLER_FIXTURE` path, and the verdict-from-gate-exit-code contract are all preserved unchanged. A new
  deterministic guard, `tools/test-invariant-prover-multideploy.sh`, pins the `--aux`→`INV_AUX` threading + the
  composable-fresh directive and asserts the no-`--aux` path is unchanged (grep over the `.ag` + the runner, no
  LLM/forge).
- `submit-triage.sh` — the **human-gated submission triage** layer (#1056, epic #1053). Scans a staging
  root for the verified-FINDING packages `run-audit.sh` / `run-batch.sh` drop under
  `<out>/submission[/<key>]/` and scores each candidate's readiness (**READY** = report.md + a PoC/witness +
  the NOT-SUBMITTED marker; **INCOMPLETE** lists the missing pieces), with a best-effort severity parse and a
  `--checklist <dir>` per-candidate review list. It NEVER contacts a platform — a READY package is a LEAD the
  operator reviews and submits MANUALLY; "take one finding end-to-end to a real submission" is the operator's
  step (a payable target + their platform account/KYC), which this tool only makes fast. `demo-submit-triage.sh`
  proves it offline + deterministically (a complete package -> READY/HIGH, an incomplete one -> INCOMPLETE
  missing `poc`, the checklist prints the manual-submit note, empty root -> SKIP, no egress).
- **FM4 — audit-informed deep-invariant synthesis** (#1058, epic #1041). Generic conservation /
  single-function invariants are what auditors and formal tools check FIRST, so re-deriving them finds
  nothing new. `run-autoharness.sh` gains `--audit-context <file>`: it folds the target's prior audit
  findings + known-gap notes into the generation prompt and instructs the LLM to target what audits MISS
  (cross-function emergent state, deep economic value-extraction, multi-step accounting drift) and to NOT
  re-derive an already-disclosed finding (worthless on a first-reporter bounty). A new `--dry-prompt` mode
  builds + prints the prompt without calling the LLM/forge, making the wiring offline-testable.
  `demo-fm4-audit.sh` asserts (deterministically, no LLM): with `--audit-context` the prompt carries the
  FM4 targeting block + the gap instruction + the do-not-re-report instruction + the disclosed findings
  verbatim; without it the prompt is unchanged (additive); an unreadable context file errors loudly. The
  invariant-quality uplift is the LLM's; this ships and proves the deterministic wiring.
- **FM3 — oracle / price perturbation as a stateful fuzz dimension** (#1057, epic #1041). FM1 forks real
  state and FM2 composes protocols, but the price/oracle stayed STATIC, so the flashloan-funded
  price-manipulation drain (where bounty money concentrates) was unreachable. The harness-generation prompt
  (`run-autoharness.sh`, main + repair) now instructs the LLM: when the target reads a price/oracle (spot
  reserve ratio, `price()`/`getPrice()`/`latestAnswer()`, a DEX quote), expose the price-MOVEMENT vector as a
  fuzzable action (a real swap on the forked pool, a donation/transfer that skews reserves, or a
  manipulable-feed write) so the seed can move the price within attacker-reachable bounds BEFORE the
  borrow/redeem/liquidate. `demo-fm3-oracle.sh` proves the dimension through the real `forge-invariant.sh`
  gate on a two-sided calibration: a spot-priced lender is over-borrowed by a fuzzed move-price->borrow
  sequence (**FINDING**) while the anchor+1%-bound twin rejects the manipulated borrow (**CLEAN**) — 0
  false-VERIFIED, verdict the fuzzer's. SKIPs cleanly without forge.
- `run-batch.sh` — the **batch/continuous runner** that operationalizes the proven engines at volume by
  consuming the #1054 funnel queue (epic #1053). Per `targets.queue` line (highest score first): skip keys
  already in `funnel-ledger.txt` (resumable; reuses the funnel dedup contract); run a hunt under a
  per-target timeout via a pluggable `--hunt-cmd` (the seam — it gets `BATCH_KEY/URL/SCOPE` in env and
  prints a `VERDICT|<confirmed|dry|refuted>` line) or a best-effort default (a resolvable `0x` address ->
  `run-autoharness.sh` given `ETH_RPC`+`FORK_BLOCK`, else `dry`+`needs recon`); the verdict is the engine's,
  NEVER an LLM; on `confirmed`, stage the finding under `<out>/submission/<key>/` marked PENDING HUMAN
  REVIEW — the colony has no platform-egress and **never auto-submits**; append `key<TAB>verdict<TAB>ts` to
  `funnel-ledger.txt` (the funnel dedups it next run) and `policy-outcomes.log`. Bounded by `--max-targets`;
  resumable via the ledger. `demo-batch.sh` proves the loop offline + deterministically (fixture queue +
  stub hunt-cmd -> score order, ledger-skip, staged confirmed, resumable no-op re-run). SKIPs cleanly with
  no queue.
- `run-funnel.sh` — the **target-intake funnel**: turns target selection from a human pick into a ranked,
  freshness-checked, self-deduped queue (#1054, part of epic #1053). Pipeline: **discover** (live RUNNING
  Sherlock contests via its JSON API, reusing `contest-watch.sh`'s `items[]` pattern, plus a best-effort
  Cantina/Code4rena probe) with a `--from <candidates.json>` offline override for deterministic/reproducible
  runs; **freshness** (drop any candidate whose `status` is not RUNNING); **self-dedup** (drop keys
  `platform:id` already in the read-only ledger `${DARK_FACTORY_DIR:-$HOME/.dark-factory}/funnel-ledger.txt`,
  whose `key<TAB>verdict<TAB>ts` rows the #1055 batch runner appends); **score** (a deterministic weighted sum
  documented in-script — recency of `launched_at` 0..40, log-scaled prize/TVL hint 0..25, platform weight
  contest>permanent 0..20, smaller in-scope size 0..15, max 100, ties broken by key ascending); and **emit** a
  ranked TSV `score<TAB>platform:id<TAB>url<TAB>title<TAB>scope_hint` to stdout AND
  `${DARK_FACTORY_DIR}/targets.queue`. No network AND no `--from` → `[SKIP]` + exit 0 (CI-safe). It NEVER
  contacts a platform to submit — a queued target is a LEAD a human (or the #1055 batch runner) triages.
- `demo-funnel.sh` — offline, deterministic proof of the funnel (mirrors the other `demo-*.sh`): feeds a
  fixture candidate list (varying `launched_at`/prize for a non-trivial rank, one non-RUNNING candidate, one
  pre-seeded in a temp ledger) to `run-funnel.sh --from` with `DARK_FACTORY_DIR` pointed at a temp dir, and
  asserts the queue is ranked by score descending, the non-RUNNING candidate is dropped (freshness), the
  ledger-seen candidate is dropped (self-dedup), and the run exits 0. No network, no LLM.

### Documentation
- `dispatcher.ag`: documented as the **standalone sync-guard** canonical copy of the dispatch fn (used by
  `demo-dispatch.sh` to diff against `coordinator.ag`'s inlined dispatch on the offline fixture path).
  It mirrors the fixture path AND the live `symbolic-prove` route (#1032); the newer live routes
  (`invariant-hunt` #1037 / auto-harness #1048 execution) live ONLY in `coordinator.ag` — which, not this
  standalone copy, is the production entry point — and are intentionally not mirrored here, so the
  invariant-hunt/auto-harness divergence flagged in #1049 is by design, not a bug. Resolves #1049
  (comment-only, no behavior change).

### Fixed
- **`forge-invariant.sh` degraded a self-contained harness to HARNESS_ERROR when the TARGET project's own
  tests don't compile** (#1069). `forge test` compiles the whole project, so a real-world target whose own
  `*.t.sol` fail under our forge/solc (e.g. a `view` function the compiler now rejects as state-modifying —
  solc drift) blocked even a fully self-contained generated harness, producing a non-verdict for a reason
  unrelated to our harness or the target's source. The gate now `--skip`s every other `*.sol` under the
  target's `test/` dir from compilation, keeping only the harness + `src`; targets whose tests compile
  cleanly are unaffected. Regression guard: `tools/test-forge-invariant-harness-isolation.sh`.
- **`invariant-prover.ag` `generate_test()` degraded to HARNESS_ERROR on realistically-sized targets**
  (#1067). The live-generation ask asked the model, in ONE completion, for a full `Handler` + abstract
  `InvBase` + a test contract asserting FIVE deep invariants (value-conservation, no-depositor-loss,
  solvency-under-any-sequence, no-free-value-extraction, share-price-monotonicity). On a real contract that
  single generation is too large to return within the LLM timeout, so the engine produced no verdict
  (HARNESS_ERROR). The ask is now **bounded**: EXACTLY ONE deep invariant — the single highest-value property
  for the current bug-class lens (e.g. solvency/collateralization for an accounting lens, share-price
  monotonicity for a vault lens) — plus a MINIMAL handler exposing only the actions needed to exercise that
  one invariant, under an explicit `~120-line` size budget, so the generation returns reliably and compiles.
  Breadth now comes from running the prover across MULTIPLE lenses (one focused invariant per run), not one
  mega-test. All hard constraints are unchanged (`pragma solidity ^0.8.20;`, no forge-std import, the
  StdInvariant `targetContracts()` ABI, plain `require(...)`, the `<matchPrefix>_*` naming, output-only
  Solidity), and the FM1/FM2 fork/compose seeds stay byte-identical when inactive.
  `tools/test-invariant-prover-bounded-gen.sh` pins the bounded ask (no LLM; grep over the `.ag` source).

## [0.2.0] — 2026-06-15

### Added
- `run-autoharness.sh` — **autonomous harness generation + hunt**. Given a target recon spec (deployed
  addresses + function signatures + fork block + the deep invariant to assert), the `$0` flat-cyborg LLM
  backend GENERATES a complete Foundry fork-fuzz harness on its own; a compile-repair loop fixes errors via
  the LLM; then the fuzzer hunts against the REAL forked protocol. No human writes the harness. Proven +
  reproducible: the LLM-generated harness rediscovers the real **Euler $197M audit-surviving bug** on a fork
  at the pre-exploit block, and reports CLEAN on a safe ERC4626 vault (sDAI) — generalises across protocols.
  Closes the harness-automation gap: the federation can go from a target's recon to a verdict autonomously.
  Needs a flat-cyborg backend wrapper + forge + an archive RPC (`[SKIP]`+exit0 otherwise). Example recon:
  `docs/autoharness-euler-example.txt`.


### Changed
- `run-audit.sh`: the default `--backend flat-cyborg` now wires `llm.command` to the new
  `flat-cyborg-claude.sh` wrapper, which drives the **interactive** claude CLI through
  flat-cyborg's PTY ($0 subscription) instead of the metered `claude -p` API. The
  `flat-cyborg` backend branch previously set only the timeout and left `llm.command`
  unset. `--backend claude` (metered `claude -p`) stays an explicit opt-in. Requires
  flat-cyborg >= v0.9.1 (`--extract` implies the screen grid).
- `run-autoharness.sh`: **rejects a vacuous stub harness**. A generated file must carry a real fork
  (`createSelectFork`), a `testFuzz_*(uint256 ...)` fuzz entrypoint, and a `require()` invariant, or it is
  sent back to the compile-repair loop with the full structural requirement re-stated — a live sDAI run
  exposed the LLM occasionally returning a degenerate `1+1==2` sanity test that compiled but hunted nothing.
  The shell-side prompt-fold + empty-retry workaround is removed now that delivery is fixed at the source:
  `flat-cyborg-claude.sh` passes `--wrap-input 72` (folds the long instruction block so it no longer
  overflows claude's editor) and flat-cyborg >= v0.10.0 gates `--extract` on the reply sentinel (a slow
  first reply is no longer captured as empty). Bumps the flat-cyborg floor to **v0.10.0**.
- `run-method-discovery.sh`: the INVENT direct-LLM **fallback** (taken when the substrate-native `agentis go`
  path yields no `METHOD|` line) now routes through the `flat-cyborg-claude.sh` wrapper instead of calling
  `claude -p` directly — so the entire dark-factory federation's live LLM generation is on the flat-rate
  subscription session. `claude -p` remains only as the explicit, opt-in `--backend claude` escape hatch in
  the sibling run scripts. `LLM_WRAP` overrides the wrapper path.


### Added

- **Cross-contract composability — the fuzzer now composes call-SEQUENCES across the target AND the protocols
  it interacts with, so flashloan-funded cross-contract value extraction (the canonical oracle/price-
  manipulation drain) is REACHABLE** (FM2, #1041). Single-contract invariant fuzzing is structurally blind to
  it; this makes the highest-value bug class findable. Builds on FM1 fork mode. **Purely additive** — with no
  `--fork-target` role beyond `target`, FM1/#1035/#1037 behaviour is byte-identical.
  - `run-invariant-hunt.sh` / `run-autonomous-hunt.sh` — a **repeatable `--fork-target '<role>=<addr>'`** that
    accepts a CONTEXT SET of deployed contracts beyond the single target (role ∈ {`target`, `dex`, `flashloan`,
    `oracle`, …}). A bare `--fork-target <addr>` (no `=`) stays the FM1 one-target shorthand (role defaults to
    `target`). Each address is validated as `0x` + 40 hex and each role against `[a-z0-9_]`; a role may not
    repeat. The set is exported to the prover as `FORK_CONTEXT` — a **semicolon-separated `role=addr` list**
    (e.g. `target=0x…;dex=0x…;flashloan=0x…`), parse-safe after validation. `run-autonomous-hunt.sh` forwards it
    via `INV_FORK_CONTEXT` to the coordinator, which appends `--fork-context` to the gate the chosen
    invariant-hunt runs (each value `shell_escape`d via `inv_opt_flag`).
  - `evm-harness/forge-invariant.sh` — accepts and IGNORES a `--fork-context <role=addr;…>` flag (a
    generation-prompt hint; the fuzzer auto-discovers its fuzz targets from the test's `targetContracts()`
    view, so the gate needs nothing from the context) so a composability-mode caller can forward it uniformly
    without an "unknown arg" error. No-fork / no-context behaviour is byte-identical.
  - `auditor/agents/invariant-prover.ag` — when `FORK_CONTEXT` carries MORE than the `target` role the
    generation prompt is extended: *"you may compose calls across these deployed contracts [role→address list];
    model an attacker funded by a flashloan from `<flashloan>` (or `vm.deal` if none); move price via `<dex>`;
    generate a Handler whose actions span all of them, and a deep invariant checking the TARGET's value/
    solvency after the cross-contract sequence — NO free value extraction."* The `HANDLER_FIXTURE` path stays
    authoritative; the `FORK_CONTEXT` addresses reach the prompt as plain text (never a shell). **Additive** —
    a `FORK_CONTEXT` with only `target` (or empty) leaves the FM1 prompt byte-identical (composability fires
    only on >1 role, counted via `regex_find_all("=", ctx)`).
  - **NEW `demo-composability.sh`** — the proof, fully synthetic + offline (no RPC; it demonstrates the
    mechanism the fork path then applies to real protocols). A `MiniAMM` (constant-product `x*y=k` whose `swap`
    moves the spot price), a `LendingVault` that prices deposited collateral at the AMM **spot** price (the
    manipulable-oracle bug) and lends quote against it, and a `FlashLender` (lend + require same-tx repayment).
    Two configs run through `run-invariant-hunt.sh` over the same budget + seed: **(A) composable** —
    `--fork-target target=<vault> --fork-target dex=<amm> --fork-target flashloan=<lender>` with a handler
    spanning all three → **FINDING** (the fuzzer composes flashloan → swap to inflate the collateral spot price
    → borrow against the overvalued collateral → swap back → repay → keep the surplus, breaking
    `invariant_vault_not_drained`; the break is a REAL value extraction, not a hard-coded assert, with a shrunk
    cross-contract witness); **(B) single-contract** — only the vault as target, a vault-only handler, same
    budget/seed → **CLEAN** (the exploit is structurally unreachable without composing the DEX + flashloan; the
    search still exercises the full budget — 256 runs × 64 depth — and holds). The A-FINDING / B-CLEAN split
    proves composability is the lift. `[SKIP]`s + exits 0 without forge/agentis; temp dirs under `${TMPDIR}`,
    trap-cleaned; a fixed `--seed` for reproducibility. The verdict is the FUZZER's exit code (no LLM — a
    deterministic fixture). A FINDING is a LEAD a human triages — this colony never auto-submits.
  - `README.md` / `docs/invariant-hunt.md` — a composability section (the `--fork-target <role>=<addr>` /
    `FORK_CONTEXT` encoding, the flashloan-attacker model, that it composes with FM1 fork mode for real
    targets, the human-gated boundary).

- **Fork-state invariant hunting — the stateful hunter now fuzzes deep invariants against FORKED REAL
  ON-CHAIN STATE (the actual deployed contract at a pinned block), not only a fresh deploy** (FM1, #1041).
  Proven foundation: `forge` invariant-fuzzed 512 sequences against the REAL deployed WETH at mainnet block
  25318855 via a public RPC and the solvency invariant (`totalSupply() <= address(WETH).balance`) held. FM1
  productises that into the hunter. **Purely additive** — with no `--fork-url` the #1035/#1037 behaviour is
  byte-identical.
  - `evm-harness/forge-invariant.sh` — optional `--fork-url <http(s)-rpc> [--fork-block <n>]`. The RPC shape
    (`http(s)://…`) and block (whole number) are validated; `--fork-block` requires `--fork-url`. When set,
    the gate threads forge 1.7.1's own `--fork-url <rpc> [--fork-block-number <n>]` (each value an array
    element, never a concatenated string) into the `forge test` invocation; when unset the forge command is
    **byte-identical** to today. A fork RPC failure (unreachable / rate-limited / "could not instantiate
    forked environment") leaves forge with no parseable result, so the existing no-result path returns
    **HARNESS_ERROR (2)** — never a false CLEAN/FINDING (the FM1 safety contract).
  - `run-invariant-hunt.sh` / `run-autonomous-hunt.sh` — `--fork-url`/`--fork-block` pass-through to the gate
    (the autonomous driver forwards them via `INV_FORK_URL`/`INV_FORK_BLOCK` to the coordinator's chosen
    `invariant-hunt`, and through the `--pattern-store` prover-gate wrapper to the prover). `run-invariant-hunt.sh`
    also exports `FORK_TARGET=<deployed address>` (+ `FORK_URL`/`FORK_BLOCK`) to the prover so the generated
    test can reference the real deployed contract by address. Absent the flags, behaviour is unchanged.
  - `auditor/agents/invariant-prover.ag` — in fork mode (`FORK_TARGET`/`FORK_URL` non-empty) the generation
    prompt is told the target is a **live deployed contract at `<address>`** and to generate a Handler that
    drives its real functions with bounded inputs and funded actors (`vm.deal`), plus a deep invariant checked
    against the forked state (solvency / no-free-value-extraction / share-price monotonicity). The
    `HANDLER_FIXTURE` path stays authoritative; the `--fork-url`/`--fork-block` are forwarded to the gate,
    each `shell_escape`d. **Purely additive** — no `FORK_*` ⇒ the generation prompt + gate command are
    byte-identical. `auditor/agents/coordinator.ag`'s `run_invariant_live` forwards `INV_FORK_URL`/`INV_FORK_BLOCK`
    to the gate the same way (each value `shell_escape`d via `inv_opt_flag`).
  - **NEW `demo-fork-hunt.sh`** — the foundation proof. Probes a public RPC (`ethereum-rpc.publicnode.com`,
    fall back to `eth.drpc.org`); when forge is absent OR no RPC is reachable it `[SKIP]`s and exits 0.
    Otherwise it builds a tiny Foundry project with the proven WETH handler + solvency invariant, forks the
    REAL deployed WETH at block 25318855, and asserts **CLEAN** (the funded handler drove the deployed
    contract's real `deposit()`/`withdraw()` over fuzzed sequences and the invariant held — the machinery ran
    against real forked state), plus a forced-bad `--fork-url http://127.0.0.1:1` → **HARNESS_ERROR (exit 2)**,
    never a false verdict. The RPC is an argument (no key hard-coded); the block is pinned for reproducibility.
    A FINDING here would be a CANDIDATE a human triages — this colony **never auto-submits**.
  - `docs/invariant-hunt.md` — a fork-mode section (the `--fork-url`/`--fork-block`/`FORK_TARGET` contract, the
    RPC-failure→HARNESS_ERROR safety, the human-gated boundary, reproducibility via the pinned block).

- **Method-invention feeds the hunt + DAG pattern memory — the federation invents its own attack methods,
  stores winning ones in the pattern DAG, and self-drives** (Integration M3, #1037, the FINAL milestone). M1
  made the coordinator live-drive the fuzzer; M2 let each lead carry its own context. M3 closes the loop: a
  winning invariant pattern (one that produced a FINDING) is **persisted to the pattern DAG** and **recalled
  to seed future hunts**, and `invent-method` can propose a **new** invariant class the next hunt then uses.
  It **reuses the existing `bugpat:*` DAG infrastructure** — the same `dag_put`/`recall_latest`/`memo_write`
  primitives the fork-matcher seed/recall agents use, in a parallel `invpat:*` namespace — rather than building
  a new store.
  - `auditor/agents/invariant-prover.ag` — two additive hooks around its GENERATE-and-VERIFY step. **RECALL
    before GENERATE:** reads `recall_latest("invpat:latest:<class>")` (falling back to `invpat:invented:<class>`
    — the invent-method hint), prints `RECALL-INVPAT|<class>|<descriptor>` when non-empty, and folds the
    descriptor into the LLM generation seed ("a prior FINDING on this class used this invariant pattern: …;
    adapt it"); on the `HANDLER_FIXTURE` path the fixture stays authoritative but the `RECALL-INVPAT|` line is
    still printed so the loop is observable. **PERSIST on FINDING:** *after* the verdict print (so a persist
    failure can never alter the verdict), and only when `verdict == "FINDING"`, computes a deterministic
    signature `<class>::<target>::<match-prefix>`, `dag_put`s it, writes `invpat:exact:<hash>` +
    `invpat:latest:<class>`, emits `dark-factory:invariant_pattern_learned`, and prints
    `INVPAT-LEARNED|<class>|<descriptor>`. Recall/persist steer GENERATION only — **the verdict stays the
    fuzzer's exit code**; `prior`/the signature flow only into the prompt + the plain-stdout `RECALL-INVPAT|`
    line, never into `exec sh`. **Purely additive** — with no recalled pattern the instruction is
    byte-identical to M2.
  - `run-invariant-hunt.sh` — a `--pattern-store <dir>` flag: a **persistent** agentis store reused across
    runs where the `invpat:*` memos are kept. A bridge (via the `agentis memo` CLI) moves them **in** before
    the prover run (so RECALL sees a prior run's confirmed shapes) and **out** after (so this run's FINDING is
    kept for the next). Absent the flag the per-run store is ephemeral → no cross-run memory (byte-identical).
  - `run-autonomous-hunt.sh` — `--pattern-store <dir>` routes the coordinator's chosen invariant-hunt through
    `invariant-prover.ag` (so persist/recall happen) **without touching `coordinator.ag`**: it hands the
    coordinator a thin prover-gate wrapper as `FORGE_INVARIANT` that speaks the gate's exact CLI + exit
    contract (`1=FINDING/0=CLEAN/2=error`), so `run_invariant_live` + `sym_rc_of`/`sym_outcome_of` are
    byte-identical, while internally routing through the prover in the persistent store (the prover's
    `RECALL-INVPAT|`/`INVPAT-LEARNED|` lines are surfaced into the orchestrate log). A `--method-fixture <file>`
    flag (Part B) consults a deterministic `METHOD|…` method-inventor proposal, parses the proposed bug class,
    and seeds it as `invpat:invented:<class>` so the next hunt's generation consults it as a hint (the live
    `method-inventor.ag` path stays prompt-driven; the fixture proves the wiring without an LLM). Absent
    `--pattern-store` the coordinator calls the bare gate directly — M1/M2 byte-identical.
  - `demo-pattern-memory.sh` — the end-to-end proof, all through `run-autonomous-hunt.sh --pattern-store`:
    **Run 1** on the vulnerable vault A (class C1) → FINDING → the winning pattern is PERSISTED to the shared
    store (`invpat:latest:C1` present + `INVPAT-LEARNED|C1|…`); **Run 2** on a structurally-different
    vulnerable vault B of the SAME class → the prover RECALLs the stored pattern (`RECALL-INVPAT|C1|…`) and
    B → FINDING (discovered → stored in the DAG → recalled → reused ACROSS targets); the **invent-method leg**
    seeds a new invariant class (`invpat:invented:C1`) that the next hunt's generation consults. Honest
    framing: the claim is the MEMORY LOOP works (persist/recall/reuse), not that recall is necessary for the
    fuzzer to find B. `[SKIP]` + exit 0 when forge/agentis are absent (CI convention).
  - `docs/autonomous-hunt.md` — a "Pattern memory (M3)" section documenting the `invpat:{exact,latest,invented}`
    namespace, the persist-on-FINDING / recall-before-generate loop, `--pattern-store`, the prover-gate
    wrapper, and the `invent-method` feed; notes it reuses the `bugpat:*` DAG infra. Wired into `README.md`.
- **Multi-candidate carrying — each pending lead verifies its OWN target, not one shared operator env**
  (Integration M2, #1037). M1's live route read the target from a SINGLE flat env (`INV_REPO`/`INV_TARGET`),
  so every candidate the loop verified hit the same operator-supplied target. M2 makes each candidate carry
  its **own** repo/target context via the durable memo channel, so the loop can verify several pending leads
  and each `invariant-hunt`/`symbolic-prove` runs on the **right** lead — closing the loop from discovery
  (many leads) to a sound verdict on each *specific* lead.
  - `auditor/agents/coordinator.ag` — `run_invariant_live(candId)` and `run_symbolic_live(candId)` now take the
    candidate id (the action `args`, threaded from the `action_outcome` live branches) and resolve repo/target/
    match (and the symbolic `sym_repo`/`sym_spec`/`sym_function`) **per-candidate-first, env-fallback** via a
    new `cand_fact(candId, field, envKey)` helper: read `candidate:<id>:<field>` (the `recall_latest`-durable
    cross-process channel), use it when non-empty, else fall back to the flat M1 env. The live-route **GATE**
    keys on the **resolved** repo+target (per-candidate OR env), so a candidate carrying only its own memo
    (flat env empty) still routes live; with neither it falls through to the honest stub. Run-level forge
    budgets (`INV_RUNS`/`INV_DEPTH`/`INV_SEED`) stay env-only. **Purely additive** — an empty per-candidate
    memo ⇒ the M1 env path ⇒ **byte-identical M1 behaviour** (the `decide_once` scoring and state-field carry
    are untouched; all M1 + sibling goldens stay green). Every resolved value is still `shell_escape()`d.
  - `run-autonomous-hunt.sh` — a repeatable `--candidate '<id>|<repo>|<target>[|<match>]'` flag. Each candidate
    is validated (a foundry dir + an existing target), `agentis memo set candidate:<id>:repo/target/match` into
    the shared store (after `agentis init`, before `agentis go` — NOT in `exec.env_passthrough`, they cross via
    the durable memo channel), and contributes one `<id>|…` cell to `PENDING`. The single `--repo/--target`
    stays as the one-candidate `cand-0` shorthand (full M1 back-compat — `demo-autonomous-hunt.sh` passes
    unchanged). With candidates supplied, `BUDGET`/`STEPS` auto-scale to `>= 2 × candidate-count` so every
    candidate is both routed and attributed; `INV_POLICY_TT` seeding keeps `invariant-hunt` winning the VERIFY
    tier for each.
  - `demo-candidate-carry.sh` — the rigorous proof. Builds the vulnerable inflation vault (project A) + hardened
    twin (project B) in two separate temp foundry projects, drives ONE `run-autonomous-hunt.sh` with TWO
    `--candidate` args, and **leaves the flat `INV_REPO`/`INV_TARGET` env EMPTY** so the ONLY way each candidate
    can resolve a target is via its carried `candidate:<id>:*` memo. Asserts BOTH the autonomous choice
    (`ACTION|invariant-hunt|cand-{0,1}`) and the SPLIT verdict (`DISPATCH|invariant-hunt|cand-0|confirmed` on A,
    `…|cand-1|refuted` on B) — a shared env could not produce two different verdicts, so the split PROVES
    per-candidate carrying. `[SKIP]` + exit 0 when forge/agentis are absent (CI convention).
  - `docs/autonomous-hunt.md` — a "Per-candidate context carrying (M2)" section documenting the
    `candidate:<id>:{repo,target,match,sym_repo,sym_spec,sym_function}` memo convention, the
    per-candidate-first/env-fallback rule, and that `run-discovery.sh`/`hunter.ag` can populate these memos as
    the discovery producer. Wired into `README.md` (the Hunt-autonomously section + the Layout map).
- **The self-orchestrating coordinator AUTONOMOUSLY chooses + LIVE-runs the stateful-invariant fuzzer — a new
  `invariant-hunt` action, end-to-end** (Integration M1, #1037). #1035 shipped the fuzzer as a *callable
  engine* (an operator runs `run-invariant-hunt.sh`); Int M1 wires it into the #1014 self-orchestrating
  coordinator so the **federation itself CHOOSES** to spend it and LIVE-runs it on a target — finding the
  multi-step bug without an operator picking the engine. This mirrors EXACTLY how `symbolic-prove` was added
  as a VERIFY-tier action (#1015 M3) and given a live route (#1032).
  - `auditor/agents/coordinator.ag` — a new `invariant-hunt` action in the VERIFY tier (alongside
    `refute`/`poc-screen`/`symbolic-prove`): `is_action` accepts it, a new `score_invariant(policy)` scores it
    at **base 94** (below `refute`(100) / `poc-screen`(98) / `symbolic-prove`(96) — the stateful fuzzer is the
    most EXPENSIVE verify, a multi-call sequence search, so the cheaper verifies go first by default), with the
    **steep ×4 policy term** so the colony can **learn** to lift it above the others (`94 + 4 × policy` beats
    `refute`(100) at policy > 1.5); a pending candidate still outranks any fresh hunt. The 3-way VERIFY argmax
    is refactored to a single-assignment **4-way climbing argmax** that preserves the default ordering
    `refute > poc-screen > symbolic-prove > invariant-hunt` on ties. It operates on the first pending candidate
    (args = the candidate id) and consumes it from `PENDING`.
  - **The LIVE route:** a new branch in `action_outcome` — when `invariant-hunt` is chosen AND no
    `DISPATCH_FIXTURE` matched AND a live invariant env is present (`FORGE_INVARIANT` gate + `INV_REPO` foundry
    dir + `INV_TARGET` invariant test), `run_invariant_live()` `exec sh`-runs `forge-invariant.sh --repo …
    --target … --match … [--runs/--depth/--seed]` (optional budgets appended only when non-empty, every value
    `shell_escape()`d), captures the exit code via the `__rc=$?` marker, and maps it **1 → confirmed** (FINDING,
    a real multi-step bug with a shrunk witness), **0 → refuted** (CLEAN, the lead is killed in this budget),
    **2/other → dry** (HARNESS_ERROR). The mapping is IDENTICAL to the symbolic route, so it **reuses**
    `sym_rc_of`/`sym_outcome_of`. The branch is **purely additive** — absent any of the three env facts it
    falls through to the existing honest stub, so behaviour with no live env is **byte-identical**. The verdict
    is forge's shrunk witness, **never the LLM** — the **CHOICE** of engine is the policy's, the **VERDICT** is
    the fuzzer's.
  - The in-substrate orchestrate loop carries a 6th policy int (field 21) + seen flag (field 22) for
    `invariant-hunt`, appended **after** the symbolic-prove fields so positions 0–20 are unchanged; a new
    `INV_POLICY_TT` env fact (ten-thousandths) seeds the loop's initial `invariant-hunt` policy so the
    coordinator can choose it from step 0 (exactly as `SYM_POLICY_TT` seeds `symbolic-prove`). `policy_string`
    sorts `invariant-hunt` between `hunt` and `invent-method` (`inva` < `inve`), so a run that never touches it
    renders the same string as before. `auditor/agents/dispatcher.ag` carries the byte-identical `is_action`
    update (the `demo-dispatch.sh` sync-guard asserts the two copies do not drift). **With `ORCHESTRATE_ENABLED`
    absent the single-decision path is byte-identical to before** (the new action never wins any
    `demo-coordinator.sh` fact-state without a seeded policy).
  - `run-autonomous-hunt.sh` — operator entrypoint mirroring `demo-symbolic-orchestrate-live.sh`'s driver.
    `--repo <foundry-root> --target <Invariant.t.sol> [--match <prefix>] [--backend <b>] [--runs N] [--depth D]
    [--seed S] [--steps N] [--out <dir>]`. Resolves `evm-harness/forge-invariant.sh` relative to `$0` into
    `FORGE_INVARIANT`, builds a fresh agentis store, seeds a pending candidate for the target + `INV_POLICY_TT`
    (= +2.0, representing the policy a prior run would have evolved), exports the LIVE env, runs ONE
    `agentis go coordinator.ag --enable-exec --enable-messaging` in ORCHESTRATE mode, prints the autonomous
    decision trail (`ACTION|`/`DISPATCH|`) + the final `coordinator:last_outcome` verdict.
  - `demo-autonomous-hunt.sh` — offline-deterministic proof. Reuses `demo-invariant-hunt.sh`'s inflation-vault
    + hardened-twin scaffolding (same contracts/handler/invariant), drives **`run-autonomous-hunt.sh`** (not
    the fuzzer directly) on each, and asserts: (A) the coordinator AUTONOMOUSLY emitted `ACTION|invariant-hunt|`
    (the coordinator chose the engine, not the operator), (B) `DISPATCH|invariant-hunt|…|confirmed` for the
    vulnerable vault + `…|refuted` for the hardened twin (the LIVE fuzzer's verdict), (C) a `learn` for
    `invariant-hunt` referencing the verdict appears in the store on the step AFTER the verdict (outcome →
    policy). `[SKIP]` + exit 0 when forge/agentis are absent (CI convention).
  - `docs/autonomous-hunt.md` — the end-to-end flow (coordinator chooses → live forge-invariant → sound verdict
    → policy evolves), the verdict→outcome mapping, and the human-gated submit boundary. Wired into `README.md`
    (`## Hunt autonomously (run-autonomous-hunt.sh, Int M1)` + the Layout map). **Requires:** foundry (forge)
    for a real run; optional for the rest of the federation.
- **The stateful-invariant-fuzzing bounty hunter — finds the MULTI-STEP bugs single-function symbolic exec
  misses** (#1035). The symbolic gate (#1015) proves a property over all inputs of ONE function; the refuter
  (#999) is a hostile LLM read of ONE claim. Both miss the **multi-step, stateful** bug — the ERC4626
  inflation attack, an accounting drift that compounds, a re-entrancy that only breaks on the third interleave
  — exactly the class that survives a single-function audit. This MVP ships the engine for that class: the LLM
  writes the deep invariants + the handler, Foundry's stateful fuzzer finds the exploit SEQUENCE, and **the
  verdict is the fuzzer's concrete failing call-sequence, never the LLM's opinion**.
  - `auditor/agents/invariant-prover.ag` — per-target substrate agent (the third GENERATE-AND-VERIFY sibling
    after `refuter.ag` and `symbolic-prover.ag`). It env-ins the target (`TARGET_FN` + class) + the contract
    source, GENERATES a Foundry stateful-invariant test — a `Handler` exposing the protocol's actions as
    bounded actor functions + a set of DEEP `invariant_*` properties (value-conservation, no-depositor-loss,
    solvency-under-any-sequence, no-free-value-extraction, share-price-monotonicity) — verbatim from a
    `HANDLER_FIXTURE` on the offline path or via `prompt()` on the live path (prompt-gate-ok per convention).
    It writes the UNTRUSTED test injection-safely (`printf '%s' <shell_escape(test)>`, NEVER a heredoc),
    VERIFIES it through the fuzzing gate, maps the exit code **1 → FINDING** / **0 → CLEAN** / **else →
    HARNESS_ERROR**, `emit`s `dark-factory:invariant_verdict`, `learn`s the attempt (FINDING=success,
    CLEAN=failure, harness=error) so invariant-prover fitness reweights, and prints `INVARIANT|<target>|
    <verdict>` plus, on a FINDING, the shrunk exploit call-sequence (one `STEP|...` line per call).
  - `evm-harness/forge-invariant.sh` — the callable gate. Runs Foundry's built-in stateful invariant fuzzer
    over a `*.t.sol` (`forge test --match-test invariant --json`), parses the JSON without `jq`, and returns
    **FINDING** (exit 1, with the shrunk exploit sequence surfaced on stderr) / **CLEAN** (exit 0, every
    invariant held across the fuzzed search) / **HARNESS_ERROR** (exit 2, compile/setup error / no invariant
    matched / forge absent). forge-std-free by design: the test registers fuzz targets via the
    `targetContracts()` StdInvariant ABI Foundry auto-discovers and asserts with plain `require(...)`, so it
    compiles in ANY Foundry project with zero remappings. runs/depth tune the search via
    `FOUNDRY_INVARIANT_RUNS`/`_DEPTH`; `--seed` pins forge's fuzz seed for reproducibility.
  - `run-invariant-hunt.sh` — operator entrypoint mirroring `run-symbolic.sh`. `--repo <foundry project>
    --target <Contract.sol[:Name]> [--handler-fixture <file>] [--backend mock|flat-cyborg|claude] [--runs N]
    [--depth D] [--seed S] [--out <dir>]`. Stages a fresh copy of `--repo` into the rundir, drops pre-existing
    `*.t.sol` so the gate scopes to exactly the generated test, drives `invariant-prover.ag` over the
    substrate, and collects the verdict + any shrunk exploit sequence into `<out>/invariant-report.md`.
    Default backend flat-cyborg.
  - `demo-invariant-hunt.sh` — offline-deterministic proof. Builds two tiny Foundry repos — a VULNERABLE
    ERC4626-style vault (no virtual offset) and a HARDENED twin (a large virtual-share/asset offset) — and
    drives the harness with a fixture handler on each: asserts the vulnerable vault → **FINDING** with a
    non-empty shrunk exploit sequence (the inflation attack: donate → seed → victimDeposit), the hardened
    vault → **CLEAN** (no false positive on the fix). A fixed `--seed` makes the search reproducible.
    `[SKIP]` + exit 0 when forge/agentis are absent (CI convention).
  - `docs/invariant-hunt.md` — the thesis (audit-surviving bugs are multi-step/stateful; the LLM writes deep
    invariants + handlers, the fuzzer finds the exploit sequence, the verdict is the fuzzer's), the
    verdict-source contract + verdict→outcome mapping, the deep-invariant taxonomy, fixture-vs-LLM paths,
    honest scope (the engine; coordinator-routing + fan-out are follow-up), and how it relates to #1015 / #1033.
    Wired into `README.md` (`## Hunt multi-step bugs (run-invariant-hunt.sh)` + the Layout map).
- **The LIVE coordinator → Halmos `symbolic-prove` route — REAL symbolic execution inside the autonomous
  loop** (#1032). #1015 M3 proved the *offline* orchestration (a `DISPATCH_FIXTURE` stood in for the sound
  verdict); #1032 closes the **live** slice for an operator-supplied single candidate: when the coordinator
  CHOOSES `symbolic-prove` and a live symbolic context is present, it runs REAL Halmos end-to-end and maps the
  solver's exit code to the gate outcome — never an LLM opinion.
  - `auditor/agents/coordinator.ag` — a new LIVE branch in `action_outcome`: when `symbolic-prove` is chosen
    AND no `DISPATCH_FIXTURE` matched AND a live symbolic env is present (`SYM_REPO` foundry dir + `SYM_SPEC`
    target spec + the `HALMOS_VERIFY` gate path), it `exec sh`-runs `halmos-verify.sh --repo <SYM_REPO>
    --target <SYM_SPEC> --function <prefix>`, captures the exit code via the `__rc=$?` marker, and maps it
    **1 → confirmed** (COUNTEREXAMPLE, a real bug), **0 → refuted** (PROVED, safe), **3/2/other → dry**
    (INCONCLUSIVE / harness). ALL dynamic values are `shell_escape()`d; the gate is resolved via the
    `HALMOS_VERIFY` env path. The branch is **purely additive** — absent any of the three env facts it falls
    through to the existing honest stub, so behaviour with no live env is **byte-identical** (verified:
    `demo-coordinator.sh` is unchanged against `origin/main`). `auditor/agents/dispatcher.ag` carries the
    byte-identical live branch (the `demo-dispatch.sh` sync-guard asserts the two copies do not drift).
  - `run-coordinator.sh` — new `--sym-repo <dir>` + `--sym-spec <file>` flags supply the single-candidate live
    symbolic context (plus `--sym-function <prefix>`, default `check`); they must be supplied together,
    `--sym-repo` must be a Foundry project, `--sym-spec` a readable file. `halmos-verify.sh` is resolved to an
    absolute path and passed as `HALMOS_VERIFY`; `SYM_REPO,SYM_SPEC,SYM_FUNCTION,HALMOS_VERIFY` are whitelisted
    in `exec.env_passthrough`; the per-step `exec.default_timeout_ms` is raised to 180s when a live context is
    supplied (Halmos runs forge build + z3 — tens of seconds). Header/usage document the flags + the
    verdict→outcome mapping.
  - `demo-symbolic-orchestrate-live.sh` — new LIVE demo: builds a tiny Foundry vault with a real
    rounding-direction solvency bug (`convertToAssets` rounds UP, minting value) + its fix (rounds DOWN) and a
    Halmos solvency spec, drives the coordinator with the live env so its chosen `symbolic-prove` runs REAL
    Halmos → the buggy spec returns a COUNTEREXAMPLE → **confirmed**, the fixed spec PROVES the invariant →
    **refuted**; asserts the outcomes flip purely from the solver's verdict. `[SKIP]` + exit 0 when
    forge/halmos/agentis are absent (CI convention). `docs/generate-verify.md` updated: the live coordinator
    route now runs Halmos end-to-end for a supplied candidate, the offline fixture path is the CI proof, and
    multi-candidate code-carrying remains the follow-up.
- **The self-orchestrating coordinator ROUTES a candidate to the SOUND symbolic engine — a new
  `symbolic-prove` action** (#1015 M3). M2 shipped the *callable* generate-and-verify step; M3 wires it into
  the #1014 self-orchestrating coordinator so the federation can **DECIDE** to route a pending candidate
  through the sound symbolic engine, with the verdict weighted into its evolving policy.
  - `auditor/agents/coordinator.ag` — new `symbolic-prove` action in the VERIFY tier (alongside
    `refute`/`poc-screen`): `is_action` accepts it, a new `score_symbolic(policy)` scores it at **base 96**
    (below `refute`(100) and `poc-screen`(98) — routing through the symbolic engine is the most expensive
    verify, so the cheaper verifies go first by default), with the **steepest policy term in the tier** (×4)
    so the colony can **learn** to lift it above either; a pending candidate still outranks any fresh hunt.
    It operates on the first pending candidate (args = the candidate id, like refute/poc-screen) and consumes
    it from `PENDING`. The in-substrate orchestrate loop carries a 5th policy int (field 19) + seen flag
    (field 20) for `symbolic-prove`, appended **after** the existing fields so positions 0–18 are unchanged.
    A new `SYM_POLICY_TT` env fact (ten-thousandths) seeds the loop's initial `symbolic-prove` policy so the
    coordinator can choose it from step 0. **With `ORCHESTRATE_ENABLED` absent the single-decision path is
    BYTE-IDENTICAL to before** (verified against `origin/main` on the `demo-coordinator.sh` fact-states — the
    new action never wins any of those states since `refute` outranks it without a seeded policy).
  - **The verdict→outcome mapping (the epic's thesis):** the SOUND symbolic verdict maps to the coordinator's
    gate-outcome enum **COUNTEREXAMPLE → confirmed** (a real bug with a concrete witness),
    **PROVED → refuted** (the lead is killed *by a proof*, safe), **INCONCLUSIVE → dry**. So the
    confirmed/refuted policy signal the coordinator evolves on now comes from a **sound engine, never an LLM
    opinion**. `auditor/agents/dispatcher.ag` documents the mapping prominently and routes `symbolic-prove`
    to `run-symbolic.sh` on the honest live stub; on the offline path the `DISPATCH_FIXTURE` carries the
    already-mapped outcome (`symbolic-prove|cand*=confirmed` = a COUNTEREXAMPLE, `=refuted` = a PROVED).
  - `run-coordinator.sh` — new `--sym-policy <float>` flag seeds the in-substrate loop's `symbolic-prove`
    policy weight (converted to `SYM_POLICY_TT` ten-thousandths) so an operator can have the coordinator
    choose the symbolic route; usage/header list the new action; the in-loop-vs-store policy cross-check is
    skipped when a seed is supplied (the seed is an in-loop offset not written to the experience store).
  - `demo-symbolic-orchestrate.sh` — offline, deterministic proof: a hunt confirms → pushes a candidate →
    the coordinator **CHOOSES** `symbolic-prove` for it → the SOUND verdict (via fixture) flows back as the
    outcome (a COUNTEREXAMPLE run and a PROVED run, asserting the policy moves in **opposite** directions) →
    the candidate is **consumed** from `PENDING` → the policy **evolves**; deterministic re-run. No real
    Halmos needed for the orchestration proof (the fixture maps the sound verdict, exactly like every other
    action's offline path). `docs/generate-verify.md` / `docs/coordinator.md` / `docs/dispatch.md` / `README.md`
    updated with the action, the score/ordering rationale, and the verdict→outcome mapping.
- **Generate-and-verify — the LLM HYPOTHESIZES a property, Halmos delivers the SOUND verdict** (#1015 M2).
  M1 shipped the *callable* Halmos gate; M2 closes the loop from a *candidate* to a symbolic verdict by
  **generating the spec** the gate runs. New `auditor/agents/symbolic-prover.ag` is a per-candidate substrate
  agent (modelled on `refuter.ag`: `cb 300000;`, one-shot, no `fn tick`; env reads via `getenv`; reads via
  `exec sh` with `// colony-lint: safe-exec-concat`; `emit`/`learn`/`memo_write`): it **GENERATES** a Halmos
  `*.t.sol` property spec for one candidate — verbatim from a `SPEC_FIXTURE` env fact on the offline /
  deterministic path (no LLM), or via `prompt()` on the live path — then **VERIFIES** it by running the M1
  `evm-harness/halmos-verify.sh` through `exec sh` and mapping its exit code to the verdict (`0`→**PROVED**
  = invariant holds for ALL inputs → candidate safe / refuted by a proof; `1`→**COUNTEREXAMPLE** = a concrete
  input is a real bug, CONFIRMED with a witness; `3`→**INCONCLUSIVE**; else→**HARNESS_ERROR**). It `emit`s
  `dark-factory:symbolic_verdict`, `learn`s the attempt (COUNTEREXAMPLE=success / PROVED=failure /
  INCONCLUSIVE=partial / error) so symbolic-prover fitness reweights, and `print`s one
  `SYMBOLIC|<file:fn>|<verdict>` marker. **The verdict is Halmos's exit code, NEVER the LLM's opinion** —
  that is the whole point of the milestone; the LLM's job shrinks to writing the property to check.
  - `run-symbolic.sh` — operator entrypoint mirroring `run-refute.sh`: drives `symbolic-prover.ag` once per
    candidate over the substrate from a `file:fn | class | invariant | code-file | spec-fixture` manifest,
    staging a fresh copy of `--repo` into the rundir (so the sandboxed `exec sh` can write the spec into
    `test/` and run Halmos there) and threading `SPEC_FIXTURE` when provided. Default backend `flat-cyborg`
    (consistent with the other `run-*.sh`); `--backend mock` + a fixture is the offline wiring smoke.
    Collects verdicts into `symbolic-report.md`. A COUNTEREXAMPLE is a CONFIRMED bug but still a **lead** a
    human reviews; submission stays human-gated and this tool NEVER posts.
  - `demo-symbolic.sh` — offline-deterministic proof of the FULL candidate → spec → Halmos → verdict loop
    with a **fixture spec** (no LLM) + **real Halmos**, over two candidates: the honest `transferSafe`
    invariant Halmos PROVES (→ PROVED / safe) and the same invariant against the buggy `transferBuggy` Halmos
    REFUTES (→ COUNTEREXAMPLE / confirmed). Reuses the M1 `evm-harness/halmos-specs` contracts; asserts both
    verdicts and that a re-run is byte-identical (deterministic). Prints `[SKIP]` + exit 0 when
    `halmos`/`forge`/`agentis` are absent (CI convention, like `demo-halmos.sh`).
  - New `docs/generate-verify.md` documents the LLM-hypothesizes / Halmos-proves loop, the verdict-source
    contract (the verdict is the solver's exit code), the offline-fixture vs live-LLM paths, how it composes
    with M1, and the honest scope: M2 is the **callable** generate-and-verify step; coordinator auto-routing
    (deciding *when* to spend a symbolic verify and feeding the verdict into the evolving policy) is a later
    milestone. On the live path, a generated spec that does not compile / imports a missing contract /
    writes an unbounded loop returns **INCONCLUSIVE** (the safe failure mode, never a false PROVED), so
    INCONCLUSIVE is the honest common case for an un-reviewed live spec; the fixture path reaches a sound
    PROVED / COUNTEREXAMPLE today. `README.md` updated (run-symbolic.sh in the verification flow + layout).
    **Requires:** halmos >= 0.3 + foundry (forge) for a real verify; both optional for the rest of the
    federation.
- **Halmos symbolic-execution verification gate — a SOUND oracle that PROVES an invariant or returns a
  concrete counterexample, exhaustive over all inputs** (#1015 M1). New `evm-harness/halmos-verify.sh` runs
  [Halmos](https://github.com/a16z/halmos) (symbolic execution + the z3 SMT solver) over a `*.t.sol` spec
  and parses its `Symbolic test result: N passed; M failed` summary into a structured verdict + exit code:
  **PROVED** (exit 0 — holds for every input), **COUNTEREXAMPLE** (exit 1 — a concrete input violates the
  property, a real bug), **INCONCLUSIVE** (exit 3 — solver `unknown` / timeout / unbounded loop / nothing
  matched), and harness/usage error (exit 2 — bad args, `--repo` not a Foundry project, or `halmos`/`forge`
  absent with an install hint). It is the SYMBOLIC sibling of `evm-harness/forge-verify.sh` (which witnesses
  one concrete exploit path) and an **additional** sound oracle alongside it — `forge-verify.sh` is
  unchanged. Tools are resolved via `PATH` (`command -v`), no install location is hardcoded; the banner
  (`================ HALMOS-VERIFY: <VERDICT> ================`) mirrors `forge-verify.sh`. Ships two
  self-contained example specs under `evm-harness/halmos-specs/` (a `Ledger` with an honest `transferSafe`
  Halmos PROVES value-conserving, a buggy `transferBuggy` Halmos REFUTES with a concrete witness, and an
  under-unrolled-loop spec the gate must report **INCONCLUSIVE** — a soundness guard so a not-fully-explored
  loop is never over-claimed as PROVED) plus `demo-halmos.sh`, which asserts all three verdicts against the
  real solver (deterministic, no mock) and prints a single `[SKIP]` + exit 0 when `halmos`/`forge` are not on
  `PATH` (so CI passes without the toolchain). New
  `docs/halmos.md` documents the verdict/exit contract, toolchain install, and how the gate fits the epic
  (the LLM hypothesizes; Halmos is the sound verdict). Honest scope: M1 is the **callable gate only** —
  auto-routing discovery candidates into it (generate-and-verify) is a later milestone. **Requires:** halmos
  >= 0.3 + foundry (forge) for a real run; both are optional for the rest of the federation.
- **The shell loop is DISSOLVED — the federation self-orchestrates the whole multi-step audit in the
  substrate** (#1014 M3). Through M2 the decision and each action's dispatch lived in the substrate, but a
  thin shell while-loop (`run-coordinator.sh`) still **drove** the loop (per step: one `agentis go`, read the
  verdict memo, push/pop `PENDING`, advance `DRY_STREAK`/`BUDGET`, re-read the policy, append a
  `decisions.tsv` row). M3 moves that **entire loop** into `coordinator.ag`: gated on a new
  `ORCHESTRATE_ENABLED` fact, the top level runs the audit as a `reduce` over a budget-bounded `STEPS` list —
  deciding, dispatching in-substrate, reading the verdict, threading `PENDING` / `DRY_STREAK` / `BUDGET` and
  the **evolving policy** entirely in-process, and accumulating the trace — then writes the final
  `decisions.tsv` body + evolved policy to durable memos (`coordinator:trace`, `coordinator:policy_after`).
  The single-decision top level is refactored into a `decide_once()` fn both paths call; with
  `ORCHESTRATE_ENABLED` **absent** the top level does **exactly one** `decide_once()`, **byte-identical** to
  before (the #1 regression guard — `demo-coordinator.sh` is unchanged). The in-process policy is carried in
  the loop's state in ten-thousandths and rendered `%.4f`, so it stays **byte-identical** to the shell's
  experience-store `read_policy()` sum step for step (the loop also `learn()`s for the durable record).
  `run-coordinator.sh` becomes a **bootstrap**: it seeds the facts + a `STEPS` budget list, fires **one**
  `agentis go coordinator.ag` with `ORCHESTRATE_ENABLED`, and reads the final trace + policy back from the
  memos — the per-step shell loop and all shell-side `PENDING`/`DRY_STREAK`/`BUDGET` threading are removed;
  `--executor stub` (offline) and the `--out` trace contract still work. New `demo-orchestrate.sh` proves
  **one** `agentis go` runs a >=3-step audit with distinct chosen actions and that the resulting
  `decisions.tsv` + evolved policy are **byte-identical** to the M2 shell-loop output for the same
  facts/fixture (re-run byte-identical, mock backend, zero cost). `docs/coordinator.md`, `docs/dispatch.md`,
  and `README.md` updated. Honest scope: the loop self-orchestrates per bootstrap invocation; a long-lived
  daemon-tick reflex (the loop running continuously without a shell bootstrap) is a separate refinement still
  on epic #1014. Because the whole loop now runs in **one** `agentis go`, `coordinator.ag`'s `cb` budget must
  cover every step cumulatively (it was raised 300000 → 2000000 to match the colony `cb_budget` and clear the
  default budget with headroom). `run-coordinator.sh` rejects a `--scope`/`--fixture` cell containing the
  reserved `@@F@@` state-field sentinel. **Requires:** agentis >= 1.19.0.

- **Every action's DISPATCH moved into the substrate** (#1014 M2). M1 moved the `hunt` slice; M2
  **generalises** the dispatch to *all* action types. `dispatcher.ag`'s `hunt_dispatch` becomes a `dispatch`
  agent fn that parses the action `<type>` from the bus payload (`<type>|<args>`) and handles `hunt`,
  `refute`, `poc-screen`, and `invent-method`. The offline verdict now comes from a `DISPATCH_FIXTURE` env
  fact whose rules are `type|glob=verdict;…` (a PREFIX glob matched against the action ARGS — a hunt's
  `subsystem|class`, a refute/poc-screen candidate id, or invent-method's empty args; first match wins,
  default `dry`) — the same `<type>|<glob>|<outcome>` shape `run-coordinator.sh`'s `--fixture` holds.
  `HUNT_FIXTURE` is kept as a backward-compat alias consulted for a `hunt` only when `DISPATCH_FIXTURE` is
  empty. The agent keeps an honest per-type LIVE stub when no fixture is set. It writes
  `coordinator:last_outcome = <type>|<args>|<verdict>` and prints `DISPATCH|<type>|<args>|<verdict>`; the
  standalone `DISPATCH_ARGS` entry now takes `<type>|<args>`. `demo-dispatch.sh` is extended to prove the
  in-substrate dispatch + memo round-trip for **hunt, refute, poc-screen, and invent-method**, each with the
  standalone-dispatcher **sync-guard** (run `dispatcher.ag` standalone, assert its `DISPATCH|`/memo equals
  the inlined coordinator path), plus the hunt determinism + fixture-flip checks; deterministic (run twice,
  byte-identical). `docs/dispatch.md`, `docs/coordinator.md`, and `README.md` updated to say all action
  dispatch is now substrate-native (the shell loop remains; only outcome-computation moved). The dispatch
  block stays **dark** when `DISPATCH_ENABLED` is absent, so a standalone `coordinator.ag` run
  (`demo-coordinator.sh`) is **byte-identical** to before this change. **Requires:** agentis >= 1.19.0.

- **The `hunt` DISPATCH moved into the substrate** (#1014 M1). The self-orchestrating coordinator no longer
  just *decides* a hunt — in **one** `agentis go` it also *dispatches* it. `coordinator.ag` `emit`s the
  chosen hunt over the in-process bus (`dark-factory:dispatch`, payload `hunt|<subsystem>|<class>`) and a
  new sibling agent fn `hunt_dispatch` derives the gate verdict from a `HUNT_FIXTURE` env fact (offline,
  no `prompt()`/LLM; the same subsystem-glob → `confirmed|dry|refuted` shape `stub_outcome()` used) and
  writes it to the durable `coordinator:last_outcome` memo (`hunt|<subsystem>|<class>|<verdict>`). The
  emit→listen→call DAG mirrors `auditor.ag`'s sub-agents; the durable memo is the substrate-native
  cross-process channel (the emit/listen bus is in-process only). New
  `auditor/agents/dispatcher.ag` is the standalone, separately-committable copy of the dispatch fn (agentis
  `go` has no file includes, so `coordinator.ag` inlines the same fns gated on a new `DISPATCH_ENABLED`
  flag). New `demo-dispatch.sh` proves it offline + deterministically: one `agentis go` prints both
  `ACTION|hunt|...` and `DISPATCH|hunt|...`, a separate `agentis memo get` reads the verdict back, a re-run
  is byte-identical, and the verdict follows the fixture. It also runs `dispatcher.ag` standalone (its
  `DISPATCH_ARGS` entry) and asserts its `DISPATCH|`/memo output equals the inlined coordinator path — a
  **sync-guard** so the two copies of the verdict fns can't silently drift. The dispatch block is **dark**
  when `DISPATCH_ENABLED` is absent, so a standalone `coordinator.ag` run (`demo-coordinator.sh`) stays
  byte-identical. New `docs/dispatch.md` documents the in-process-bus + durable-memo model and the
  event/fact contract. **Requires:** agentis >= 1.19.0.

### Changed

- **`run-coordinator.sh` dispatches EVERY action through the substrate** (#1014 M2). The
  `stub_outcome()` / `real_outcome()` shell functions and their `case` dispatch are **removed** — the shell
  computes no action's outcome. For every non-`stop` action the loop reads the verdict from the
  `coordinator:last_outcome` memo the coordinator's in-substrate `dispatch()` writes (one `agentis memo get`
  per step). The full `--fixture` content (all rows, not just the `hunt` rows) is passed as
  `DISPATCH_FIXTURE` (projected to `type|glob=verdict;…`) and added to `exec.env_passthrough`
  (`HUNT_FIXTURE` stays whitelisted for the backward-compat alias). PENDING/DRY_STREAK/BUDGET threading is
  unchanged. Header comment + `docs/coordinator.md` updated to mark dispatch-into-the-substrate **done for
  all action types**.

- **`run-coordinator.sh` dispatches a `hunt` through the substrate** (#1014 M1). The hunt branch of the
  shell `case` (`stub_outcome` / `real_outcome`) is replaced by reading the verdict from the
  `coordinator:last_outcome` memo the coordinator's in-substrate dispatch writes; `DISPATCH_ENABLED=1` +
  `HUNT_FIXTURE` are set on the decision call and added to `exec.env_passthrough`. The other action types
  (`refute` / `poc-screen` / `invent-method` / `stop`) keep their existing shell dispatch unchanged, and
  PENDING/DRY_STREAK/BUDGET threading is unchanged. Header comment + `docs/coordinator.md` updated to move
  "dispatch into the substrate" to **Done for `hunt`**.

- **Default LLM backend across the live-reasoning orchestrators switched from the metered `claude -p`
  path to the flat-rate `flat-cyborg` PTY-wrapper backend** (`llm.backend = flat-cyborg`). `run-audit.sh`,
  `run-discovery.sh`, `run-refute.sh`, and `calibrate-evm.sh` now default `BACKEND=flat-cyborg`;
  `run-method-discovery.sh` and `calibrate-sealevel.sh` (previously hardcoded `claude`) emit a
  `flat-cyborg` config; `run-coordinator.sh` gains a `--backend flat-cyborg` branch (its default stays
  `mock`). `--backend claude` remains the explicit metered `-p` opt-in for fidelity-critical work, and
  `--backend mock` (offline-deterministic) is unchanged. Docs/examples (README, RUNBOOK,
  run-observability) updated to show the flat-rate default. **Requires:** agentis >= 1.19.0 (the
  `flat-cyborg` LLM backend) and a `flat-cyborg` binary with `--no-jitter` (>= v0.9.0) on PATH. Note:
  `--extract` is a TUI screen-scrape — for reads where a refusal/malformed reply must never be misread,
  prefer `--backend claude` (fidelity hardening tracked in `Replikanti/flat-cyborg#42`).

### Fixed

- **Coordinator orchestrate loop double-counted the final action's policy on a `stop`/dry-cap stop** (#1026).
  In `ORCHESTRATE_ENABLED` mode `coordinator.ag` attributes each step's PREVIOUS action inside `step_fn`, and a
  post-loop FINAL ATTRIBUTION block attributes the last action the loop did not get to. On a `stop`/dry-cap
  termination the stop-deciding step's `decide_once` had ALREADY attributed that last executed action, so the
  final block counted it a SECOND time — a run with 2 executed hunts ended `hunt=-0.4500` (3 × −0.15) instead
  of the correct `hunt=-0.3000` (2 × −0.15). The carried state now tracks a `lastAttr` flag (state field
  18); the FINAL ATTRIBUTION fires only for an action the in-loop pass did NOT already attribute — and drops
  both the extra `learn()` AND the extra carried-int delta, so the in-loop policy still equals the
  experience-store `read_policy()` sum. Attribution is now IDEMPOTENT: every EXECUTED action (hunt / refute /
  poc-screen / invent-method) is counted EXACTLY once across both termination paths (budget-exhaustion and
  the dry-cap `stop`); `stop` is a decision, never an executed action, so it is never attributed. The
  per-step `decisions.tsv` trace rows are unchanged (the double-count was in the terminal policy only).
  `demo-orchestrate.sh` gains a #1026 regression guard (proof (5): a dry-cap-terminated run attributes the
  last action exactly once — N executed hunts → N × the delta, not N+1) and its comments note the in-substrate
  policy is now the correct once-per-action attribution (no longer reproducing the M2 shell loop's stop-path
  double-count — that was the bug). The single-decision path (`demo-coordinator.sh`, `ORCHESTRATE_ENABLED`
  absent) is byte-identical, and the budget-exhaustion GOLDEN (`hunt=0.6000;refute=-0.6000`) is unchanged
  (that path never double-counted).
- **`run-coordinator.sh` dispatch dropped a hunt's class** (#1014 v1 follow-up). The coordinator's
  `ACTION|<type>|<args>|<rationale>` line was parsed with a flat `cut -f3`/`-f4-`, but a `hunt`'s
  `<args>` is two `|`-fields (`subsystem|class`) where every other action's is one. The class leaked
  into the logged rationale and the queued PENDING candidate id was built malformed as
  `cand-N|subsystem` instead of the documented `cand-N|subsystem|class`. The parse is now type-aware
  (hunt → fields 3-4 for args, 5- for rationale), mirroring `demo-coordinator.sh`. Also documented the
  stub fixture's subsystem-prefix-glob rule (an args-glob must not contain a literal `|`) and fixed
  `README.md` heading blank-line spacing (MD022).

### Added

- Discovery: **self-orchestrating coordinator — fact-based, evolving decision policy** (v1 of #1014). The
  discovery colony used to take its workflow from a FIXED script (`run-discovery.sh`'s `(subsystem ×
  class)` fan-out) and an external operator (target / method / when-to-stop). A new
  `auditor/agents/coordinator.ag` moves that DECISION-MAKING into the substrate: each `agentis go`
  invocation it reads the current FACTS (open scope, per-class lens fitness, the shared blackboard #1001,
  pending unverified candidates, remaining step budget, and the previous action's gate OUTCOME — a FACT,
  never an LLM judgement) and an evolving POLICY, then chooses ONE next action from
  `hunt|<subsystem>|<class>` · `refute|<cand>` · `poc-screen|<cand>` · `invent-method` · `stop` and emits
  exactly one `ACTION|<type>|<args>|<rationale>` line whose rationale CITES the facts that drove it. The
  choice is a policy-weighted ARGMAX over fact-criteria (verify a pending lead before more hunting; prefer
  a blackboard-flagged subsystem and a higher-fitness lens; stop on budget-exhausted or K consecutive
  dry), then the substrate `decide(options, criteria)` builtin selects from that already-fact-ranked list
  — so the ordering is the coordinator's, from facts+policy, never a fixed order. The decision policy
  EVOLVES by outcome: the coordinator records each action's confirmed-finding → success / dry-or-refuted →
  failure with the SAME `learn()` mechanic the lens-fitness loop uses (#996), so the cumulative experience
  delta per action-type IS `coordinator:policy:<action-type>` and reweights which decisions it leans on.
  `run-coordinator.sh` is a thin DISPATCHER (NOT a decider): it loops {ask the coordinator → execute the
  chosen action → feed the outcome back} until `stop`/budget, reads the cumulative policy back from the
  experience store between calls (mirroring `evolve-fitness.sh`), and routes a real run to
  `hunter`/`refuter`/`poc-screener`/`method-inventor` or an offline stub executor. `demo-coordinator.sh`
  proves BOTH acceptance criteria OFFLINE + DETERMINISTICALLY (mock backend, no network): (a) three
  distinct fact-states choose three DIFFERENT actions — a pending candidate → refute, no-candidate with
  the top lens C8 → hunt C8 while the same options with C1 on top → hunt C1 (the choice follows the
  fitness FACT, not a fixed cell), budget=0 → stop — and (b) over a sequence where hunts confirm and
  refutes are refuted, `coordinator:policy:hunt` ROSE (`+0.000 → +0.600`) while `coordinator:policy:refute`
  FELL (`+0.000 → −0.600`), with the demo exiting non-zero if the policy did not move. v1 boundary
  (`docs/coordinator.md`): the coordinator DECIDES, the shell still DISPATCHES; full event-driven
  substrate dispatch (no shell loop), manifest reprioritisation, and multi-target portfolio decisions stay
  follow-up on the epic. The human-gated submission boundary and the forge-verify / refuter / `eval_ag`
  safety gates are unchanged — they remain FACTS the decision consumes, never bypassed.

- Discovery: **inter-agent coordination via a shared blackboard** — a first coordination primitive so
  hunter cells influence each other within a run, instead of the run being a flat sum of independent
  one-shot audits (#1001). The discovery fan-out runs every (subsystem × class) cell against ONE shared
  agentis memo store, so `hunter.ag` now READS a rolling `dark-factory:blackboard:leads` memo before it
  prompts and WRITES every CANDIDATE back to it (+ emits `dark-factory:lead`). A later cell that finds a
  sibling's lead on the board is STEERED — its prompt gains a FOCUS block telling it to corroborate a
  hit in the same subsystem or pivot toward a related attack surface a sibling already flagged.
  `run-discovery.sh` surfaces both halves of the loop (a `↳ COORDINATION:` log line when a cell is
  steered, a "posted a lead" line when one contributes) and appends an **Inter-agent coordination**
  table to the discovery report. The mechanism is inert on a clean sweep (no finding → no steer → the
  prompt and the existing rigorous-negative contract are byte-identical), so it is additive and does not
  change single-cell behavior. `demo-blackboard.sh` proves the loop end-to-end OFFLINE (deterministic
  fake LLM, no network): an oracle cell posts a stale-price lead and a downstream liquidation cell reads
  it — the demo asserts the liquidation cell's prompt actually carried the oracle lead, so the steer is
  real, not cosmetic. Scoped as ONE coordination step; the broader emergent-behavior vision (a
  coordinator that reprioritizes/prunes the cell manifest from the board) is deliberately left as
  follow-up — no overclaim of emergence.

- Substrate-native lead pre-screen via **`eval_ag`** (#997). The discovery hunter surfaces a CANDIDATE
  as a *prose* PoC sketch — an unverified lead — and the only gate was `evm-harness/forge-verify.sh`, a
  full Foundry deploy + attacker tx that needs the cloned repo + `foundryup` and runs slowly. A new
  cheap gate runs first: `auditor/agents/poc-screener.ag` lowers a lead's machine-checkable invariant to
  a self-contained `.ag` PoC harness and evaluates it through the substrate's `eval_ag` primitive — a
  metered sub-interpreter with its own CB budget. It returns the stable outcome discriminator
  (`success` / `parse_error` / `compile_error` / `inner_cb_exhausted` / …) so the screen distinguishes
  "invariant HELD" (a clean run returning `0`) from "junk harness", and a runaway harness is CONTAINED
  (the inner CB meter trips → `inner_cb_exhausted`) instead of crashing the screener. The harness
  contract mirrors the colony's exit-101 two-sided gate (return `101` = INVARIANT VIOLATED = reproduced).
  `screen-leads.sh` drives it over a `lead-id | harness.ag` manifest and emits a verdict table; every
  screen is recorded via `learn()` + `emit("dark-factory:poc_screened", …)`. A reproduced screen is a
  lead worth the forge-verify cost, NOT a finding — submission stays human-gated.
  - **Demoed end-to-end** (`screen-leads.sh --demo`, zero external prerequisites): a reentrancy-vuln
    harness → `reproduced | success | 101`, its CEI-fixed variant → `held | success | 0`, a malformed
    harness → `indeterminate | parse_error`, and a recursion-bomb harness → `indeterminate |
    inner_cb_exhausted` with the screener surviving.
  - Documented in `docs/SUBSTRATE-PRIMITIVES.md`: which substrate primitives the colony adopted and,
    honestly, why `replicate` (needs a live colony pool + peer; a fatal error otherwise), `delegate`
    (no second in-process cooperating agent), `decide` (a soft choice where the colony deliberately
    keeps a hard mechanical gate), the Lean verifier (wrong proof object for runtime exploit
    reproduction), and confidence-tiers (the colony is one-shot + human-gated, with no autonomous write
    to throttle) do not currently fit.
  - **Correction (#997 QA):** the `eval_ag` containment claim was overstated and is now narrowed to what
    actually holds. `eval_ag` does NOT sandbox `exec` in agentis v1.18.27 — a harness that calls
    `exec sh` from inside `eval_ag` escapes to the host, so the earlier "cannot touch the host" /
    "exec-free grant set" wording was wrong. What `eval_ag` DOES guarantee is **CB-exhaustion
    containment**: a runaway/infinite harness is bounded by the inner CB budget (`inner_cb_exhausted`)
    so it cannot starve or crash the screener. Harnesses must therefore be operator-trusted. The docs /
    agent comments (`README.md`, `docs/SUBSTRATE-PRIMITIVES.md`, `auditor/agents/poc-screener.ag`,
    `screen-leads.sh`) are reworded; the two-sided gate is also clarified as an author convention the
    screener does NOT mechanically enforce (it maps the final int — it cannot detect a missing control
    assertion), with mechanical two-sidedness enforced downstream by the forge-verify gate. No behavior
    change.
- `run-summary.sh` + `docs/run-observability.md` — make a one-shot run **observable** without touching
  the separately-versioned `federation-dashboard` component (#995). dark-factory runs one-shot via
  `agentis go` (no daemons, no `*:confidence` memos), so the dashboard — which assumes daemon-tick
  agents with confidence-tier memos — has nothing to poll. `run-summary.sh` closes that gap on the
  dark-factory side: pointed at a run's `--out` dir it distills the run's on-disk artifacts (the
  agentis experience log + the run report) into one stable JSON at `<out>/run-summary.json` — runs/cells
  executed, candidates found, `learn()` outcomes, **per-class fitness** (`success / attempts`, read from
  the experience store), last-run timestamp, and verdict (discovery: `LEADS`/`SAFE`; audit: the
  `Verdict:` line). It only READS what the run wrote — never mutates the store, never contacts a
  platform. JSON is built with `python3` `json.dumps` (schema `dark-factory/run-summary@1`); `--json`
  emits pure JSON on stdout (jq-safe), `--emit-event` appends one `dark-factory:run_summary` NDJSON line
  to `<out>/events.jsonl` for a tailing monitor. `docs/run-observability.md` documents the schema +
  three consumer shapes (poll the file / tail the event stream / aggregate across runs). Validated
  end-to-end against a real mock-backend discovery run and synthetic discovery/audit fixtures (LEADS +
  SAFE verdicts, non-zero per-class fitness, the no-experience-log fallback). `shellcheck`-clean,
  `bash -n`-clean.
- Substrate-native ADVERSARIAL REFUTATION — the first of the colony's deep audit capabilities ported
  off externally-orchestrated subagents onto the agentis substrate (#999). The deepest steps (deep
  cross-function audit, build-and-run PoC, fork-differential, adversarial refutation) ran as external
  subagents, so the federation was a hybrid: a thin `.ag` layer + heavy external orchestration. This
  ports the `adversarial-refute` step (`auditor/methods/registry.md`) into a real `.ag` agent as the
  proven pattern for the rest:
  - `auditor/agents/refuter.ag` — a substrate agent modelled exactly on `hunter.ag` (cb 300000;
    one-shot, no `fn tick`; env reads via `getenv`; code read via `exec sh` with
    `// colony-lint: safe-exec-concat`; two-arg `prompt(instruction, payload) -> string`; `emit`;
    `print`). It env-ins ONE candidate finding (`file:fn` + claimed exploit + class) and the relevant
    code, runs an INDEPENDENT skeptic that tries to REFUTE the claim against the actual control/data
    flow — defaulting to REFUTED on any doubt so only unambiguous leads survive — `emit`s
    `dark-factory:refute_verdict`, records the attempt via `learn()` (REAL=success, REFUTED=failure, so
    refuter fitness rewards leads that survive a hostile read), and `print`s exactly one
    `VERDICT|REAL|…` / `VERDICT|REFUTED|…` line.
  - `run-refute.sh` — operator entrypoint. Sets up the rundir + `.agentis/config` (env passthrough for
    the candidate contract + `claude` backend) and runs the refuter once per candidate from a
    `file:fn | class | severity | exploit | code-file` manifest, staging each code file into the rundir
    so the sandboxed `exec sh` (which cannot read `$HOME`) can always reach it. Collects verdicts into a
    report. A REAL verdict is a LEAD that survived the gate, not a finding — it still must reproduce
    through `evm-harness/forge-verify.sh` before it counts, and submission stays human-gated; this tool
    never posts to a platform.
  - This is the second gate, AFTER `hunter.ag` surfaces a `CANDIDATE` and BEFORE the operator spends a
    Foundry PoC: a separate skeptic with no stake in the finding must fail to break it.
  - **Demoed end-to-end on the real `claude` backend** over two sample candidates: a guarded `sweep()`
    behind `onlyOwner` was correctly **REFUTED** (the `require(msg.sender == owner)` reverts for any
    unprivileged caller), and a `withdraw()` that sends ETH before zeroing the balance was correctly
    judged **REAL** (CEI violation → reentrancy, no guard) — surviving to the forge gate. The full
    `prompt → VERDICT → emit → learn` loop ran on the substrate (2 experience rows: one success, one
    failure).
  - Follow-up (#999): port the remaining deep capabilities the same way — deep cross-function audit,
    build-and-run PoC (forge/PoC harness via sandboxed `exec`), and fork-differential analysis — so the
    federation owns the full audit pipeline end-to-end rather than depending on an external orchestrator.
- Release wiring (#1002) — `dark-factory` is now a first-class release target. The shared
  `tools/make-federation-bundle.sh dark-factory <X.Y.Z>` already stages a curated tarball from
  `BUNDLE.manifest`; this change registers the `dark-factory-v*` tag prefix in
  `.github/workflows/release.yml` so a tag push builds the bundle and creates/updates the GitHub
  release automatically (same flow as the other federations). `dark-factory/` was already tracked by
  `tools/check-changelog.sh` (added in #965), so the `[Unreleased]` soft-check covers it too. After a
  release PR merges: `git tag dark-factory-v<X.Y.Z> <merge-sha> && git push origin dark-factory-v<X.Y.Z>`.
- `evolve-fitness.sh` + `auditor/agents/fitness-driver.ag` — actually drive the discovery colony's
  evolve/fitness LOOP over several runs and DEMONSTRABLY move per-class/per-method fitness in the agentis
  experience store (#996). Until now `hunter.ag` recorded each hunt via `learn("hunt", "<class>:<subsystem>",
  ..., outcome, [...])`, but nothing drove that loop across runs, so no evolved state accrued. The new
  driver runs the colony's REAL recording path — `fitness-driver.ag` makes the IDENTICAL `learn()` call
  `hunter.ag` makes — over a built-in ground-truth corpus (taxonomy class x subsystem, each with a known
  CANDIDATE/SAFE verdict), repeated for N iterations, then reads the experience store BEFORE and AFTER and
  prints the per-lens fitness delta. It is fully offline and reproducible (`--backend mock` semantics, no
  LLM call — per #996 the point is the fitness LOOP, not LLM quality; verdicts come from the corpus), and
  exits non-zero if the loop fails to move fitness. The built-in corpus encodes a realistic gradient so
  high-yield lenses (vault accounting, rounding, reentrancy) pull ahead while speculative ones (cross-chain,
  pause) fall behind — the colony's evolved ranking of which lenses to lean on. Validated end-to-end:
  60 cells over 6 iterations moved fitness on 9/10 lenses (C1/C6 +0.600, C3 -0.600); re-runs are
  byte-identical. `--corpus` overrides the corpus, `--json` emits a machine-readable before/after table.

- `gen-agent.sh <method-name>` — close the self-extension loop (#1000). The
  method-discovery meta-loop (`method-inventor.ag` + `run-method-discovery.sh`,
  #998) invents and adopts new audit *methods* — reusable hunting techniques
  recorded as `METHOD|name|classes|technique|how-to-invoke|status|fitness` lines
  in `auditor/methods/registry.md` (an `invented` line carries an extra
  control-assertion field before `status`) — but could not turn an adopted method
  into a new AGENT; the agent set was fixed. The generator reads one
  `METHOD|<name>|...` line (parsing both the builtin 7-field and invented 8-field
  shapes) and materialises `auditor/agents/<name>.ag`, a colony-lint-valid
  one-shot discovery agent (modelled on `hunter.ag`: `cb 300000;`, env reads, a
  `safe-exec-concat` file reader, a single adversarial `prompt()`, and an
  `emit()` + `learn()` so the method's per-target fitness reweights over runs —
  the #861 evolve loop, now over a generated method-agent). The method's
  technique / how-to-invoke / control-assertion (or a generic two-sided gate for
  builtin methods) are wired into the agent's instruction; the agent prints one
  `CANDIDATE|...|method=<name>|...` line per finding (else `SAFE`) for the
  forge-verify gate. Refuses to overwrite an existing agent (exit 3) and rejects
  non-kebab-case names (exit 2). Demo: adopted the `stateful-invariant-fuzz`
  method (the multi-transaction-invariant gap the federation itself flagged in
  `auditor/methods/gap-stateful.md`) into the registry and generated
  `auditor/agents/stateful-invariant-fuzz.ag` from it — passes `colony-lint.sh`
  (`agentis commit` syntax + `check-exec-sh`).

- **Method-discovery meta-loop** — `run-method-discovery.sh` + `auditor/agents/method-inventor.ag`
  + `auditor/methods/{registry.md,gap-stateful.md}` + `auditor/method-discovery/controls/` (#998,
  #1003). The federation's self-improvement layer: when the current method-set plateaus, the
  method-inventor proposes ONE new audit method and it is adopted into the registry ONLY if it
  DISCRIMINATES on a known-bug control corpus (a planted accounting/solvency bug — `BuggyBank` —
  caught while the paired clean `SafeBank` twin stays green). That two-sided gate (buggy suite
  FAILS + safe twin PASSES) keeps method invention empirical rather than speculative. An adopted
  `invented` row carries the proposal's control-assertion before `status` (the 8-field shape
  `gen-agent.sh` consumes).

- `state-export.sh` — export / verify / import a *trained* dark-factory federation's EVOLVED STATE
  (#994, #1004): the accumulated learned `memo` plus the content-addressed Merkle DAG of audited
  patterns, packaged into a portable, **checksum-verified** artifact. It deliberately EXCLUDES the
  federation identity (private key), per-deployment config, and the transient sandbox, so an
  importer keeps their OWN identity and only inherits the learned state — the technical enabler for
  distributing a trained federation (agentis-core#864). The checksum proves integrity, not
  authenticity: sign the manifest out-of-band before third-party distribution.

- `contest-watch.sh` — a durable, host-cron-able watcher for newly-opened audit competitions (Sherlock
  API + Cantina/Code4rena probes). On a fresh contest it notifies via a state file / optional webhook /
  optional command, so an early audit pass can start day-1; it survives across sessions, unlike an
  in-session reminder. Validated: detects a RUNNING contest, stays silent when the platforms are dry.

- Discovery: **function-level slicing** + a 600s deep-read budget (#863). A scope entry can now be
  written `file@fn1+fn2` to feed the hunter ONLY those functions (plus the contract header) instead of
  the whole file — `auditor/slice-fns.sh` (awk, brace-matched) extracts them, wired through
  `hunter.ag`'s `cat_file` (via the `SLICER` env) and `run-discovery.sh`. This fixes the deep
  liquidation/redemption cells timing out on big contracts, where a whole-file concat overflowed the
  LLM per-call budget (e.g. a Compound-fork `CToken.sol` 1193→134 lines, a credit-vault
  `CollateralVaultBase.sol` 611→152 lines). The discovery LLM timeout is also raised 300s→600s — the
  reasoning, not the payload, is the real cost, and one 600s attempt beats three wasted 300s retries.

- Custom-code DISCOVERY track — the colony can now hunt bugs in bespoke, never-forked protocols, not
  just match known-fork patterns (#863). The DAG matcher (`auditor.ag`) fires only where in-scope code
  recurs a seeded pattern, so it returns nothing on custom contest code (a fresh stablecoin, a new
  vault). The discovery track closes that gap, entirely on the agentis substrate:
  - `auditor/agents/hunter.ag` — a substrate discovery agent. One invocation hunts ONE bug class over
    ONE subsystem: it slurps the in-scope contracts, loads the taxonomy lens + protocol brief, runs a
    deep adversarial `prompt()`, and records the attempt via `learn()` (+ `emit`) so per-class fitness
    reweights over targets (the #861 evolve loop, now over discovery).
  - `auditor/bug-taxonomy.md` — the discovery knowledge: 14 DeFi bug classes (share-price/ERC4626,
    oracle, cross-chain/LZ, withdrawal-queue, access-control, accounting, sig-replay, reentrancy,
    decimals, liquidation, first-depositor, slippage, compliance, fork-delta), each with a "hunt" lens
    distilled from real audits.
  - `run-discovery.sh` — operator entrypoint. Takes `--repo` + a `--scope` manifest
    (`subsystem | classes | files`) + a `--brief` (invariants-to-break, known-issues-to-exclude, trust
    model) and fans out one substrate hunter per (subsystem × class), collecting `CANDIDATE` leads into
    a report. Never posts to a platform; surfacing harness-checkable leads is the whole job.
  - `evm-harness/forge-verify.sh` — the multi-contract verification gate. A custom protocol needs a full
    Foundry deployment + attacker tx + invariant assertion (not the single-function revm harness), so a
    candidate is VERIFIED only when its `Exploit.t.sol` PoC PASSES against the in-scope repo. A lead that
    does not reproduce is not a finding (no junk submitted).
  - **Proven end-to-end on a live, 3×-audited custom yield-bearing-stablecoin Sherlock contest**: the
    substrate hunter read the ERC4626 savings + rewards-distributor contracts under the C1 share-price
    lens and returned a reasoned `SAFE` — a rigorous negative, the valid outcome on audited code. Wiring
    is mock-smoke-tested; the real claude pass completes the full prompt→verdict→learn loop.

- M4 evolution — the matcher granularity tunes itself by fitness (#861). The fuzzy matcher's
  granularity (shingle-Jaccard threshold × shingle width `k`) is the knob no human can hand-tune:
  too loose floods synthesis, too tight misses forks, and the sweet spot is unknown a priori — a
  search problem, and the fork-pair recall harness IS the fitness function. `auditor/agents/
  pattern-evolver.ag` + `evolve-matcher.sh` search the genome against a held-out fork-pair oracle
  (forkpair-recall.js), record EACH candidate as substrate experience via `learn()`, select the
  F-beta-max config (beta>1 = recall-leaning, since the two-sided gate absorbs false matches), and
  write `evolved:fuzzy_threshold` / `evolved:fuzzy_k`. `run-audit.sh --use-evolved <dir>` adopts that
  config (also `--fuzzy-threshold` / `--fuzzy-k` to set them directly); `fuzzy-match.js` /
  `forkpair-recall.js` gained a `k` arg, and reconn/recall-match pass `FUZZY_K`.
  - **Proven end-to-end on Compound→Venus**: the hand-set default (th=0.35, k=4) scores F-beta 0.549
    (recall 54%); the evolver searched 15 genome points and picked **th=0.25, k=4 → F-beta 0.674
    (recall 85%)** — a config no human chose — then `run-audit --use-evolved` adopted it
    (`adopted evolved matcher granularity threshold=0.25 k=4`) and fuzzy-matched a real fork. The
    granularity is now fitness-driven, not hand-guessed; `--beta` tunes the recall/precision trade.

- M3 held-out recall harness + knowledge-market sharing (#861). Measures whether the seeded DAG
  catches a finding's FORK it did not see seeded, and shares the corpus across the federation:
  - `recall.sh` + `auditor/agents/recall-match.ag` seed with the real `seed-patterns.ag` (zero
    seed-side drift) and match each held-out target with a mirror of reconn's exact + structural
    matchers, then tally exact-only vs structural recall per class + precision on negatives.
  - `evm-harness/make-variants.js` generates realistic fork variants of a seeded function (rename /
    reformat / re-literal = what a real N-day fork is) plus structural negatives (call-kind swap,
    injected guard) that MUST NOT match. Reuses `struct-sig.js`'s exported KEEP set so a renamed
    fork keeps the same signature; `struct-sig.js` now `module.exports` its token rules.
  - `harvest-sherlock.js` handles BOTH Sherlock judging layouts — the old `NNN-H`/`NNN-M` folders
    and the new flat `NNN.md` files (severity inside the file).
  - **Synthetic result** on 41 real shape-based findings from 4 Sherlock contests (164 held-out
    forks): exact-only recall 6%, structural recall 94%. But these forks are GENERATED
    (rename/reformat/re-literal) — exactly the transforms struct-sig was built to be invariant to —
    so 94% is an **upper bound on near-verbatim forks**, not a real-world hit-rate.
  - **Real fork-pair result** (`evm-harness/forkpair-recall.js`, the honest measurement): seed a
    function from one protocol and match the SAME function as actually deployed in a protocol that
    forked it — Compound `CToken.sol` vs its Venus `VToken.sol` fork, 48 shared functions. Exact
    signature recall is **17%** (only the simple getters; the vuln-bearing functions like
    `redeemFresh`/`accrueInterest` are ~2x rewritten in the fork and never hit). Two struct-sig
    fixes surfaced by this (modifier-order canonicalization + `uint`/`uint256` aliasing) lifted it
    from 0% to 17%.
  - **Fuzzy matcher** (`evm-harness/fuzzy-match.js`) — the recall lift for REAL forks. Matches on
    shingle-Jaccard SIMILARITY instead of signature equality, so a restructured fork still hits:
    Compound->Venus fuzzy recall **69% @ 0.30 / 54% @ 0.35 / 46% @ 0.40** (incl. the vuln functions),
    at ~52-67% precision (structurally-similar-but-different functions also match — gate-safe, a
    false candidate costs one inconclusive synthesis, never a finding). Wired into reconn
    (`match_seeded_fuzzy_evm`, the third fallback after exact + structural) and the recall harness.
    Proven end-to-end through the colony: seed Compound `redeemFresh`, audit Venus's real forked
    `redeemFresh` (Jaccard 0.41) -> `SEEDED FUZZY MATCH -> Reentrancy`, guard fired `[High]` where
    exact + structural both missed.
  - Known limitation: the in-`.ag` `strip_comments` accumulates an O(n^2) string heap and overflows
    on a full ~1500-line real contract target (the exact/structural paths run it first). Real
    full-contract auditing needs that rewritten; single-function and mid-size targets are unaffected.
  - `auditor/agents/share-patterns.ag` + `run-audit.sh --share-patterns` publish each seeded
    `bugpat:exact:<hash>` / `bugpat:struct:<hash>` to the knowledge market (`knowledge_sell`, keyed
    by content hash) so other federation members can `knowledge_buy` it — "share the DAG via the
    knowledge market". The buy side is a real economic exchange (the buyer escrows the ask price
    from its CB pool), so importing a shared pattern requires a funded consumer.

- M1+ structural-variant bug-pattern matching (#861) — `evm-harness/struct-sig.js` + a new reconn
  fallback. Exact-hash seed matching (the prior M1) catches only a byte-identical N-day fork of a
  recorded finding; this also catches a RENAMED / REFORMATTED / RE-LITTERED fork. `struct-sig.js`
  normalizes each Solidity function to a parser-free structural signature (identifier names → `_`,
  literals → `0`, keeping Solidity keywords / types / external-call kinds), so a variant collapses to
  the same content hash as the seed — no solc, so it works on a bare harvested fragment too.
  `seed-patterns.ag` now seeds `bugpat:struct:<hash> = class` alongside the exact one (guarded to sigs
  that carry a call-kind or storage-write, so a trivial getter is never seeded), and reconn
  (`match_seeded_any_evm`) tries the exact match first, then the structural fallback. Proven end-to-end
  through the colony: a Reentrancy seed matched a renamed/reformatted variant (`SEEDED STRUCTURAL
  MATCH -> Reentrancy`, guard fired `[High]`) where exact-match returned nothing, while a CEI-reordered
  SAFE version correctly did NOT match. A structurally-edited variant (reordered statements / changed
  expression shape) is out of scope for v1 — that needs an AST/semantic signal. An over-broad match can
  never mint a false finding: it only sets the candidate class; the two-sided synthesis gate stays the
  only source of truth.

### Fixed

- Discovery hunter was blind — `auditor/agents/hunter.ag` now reasons FIRST (#993). The prompt
  drove the LLM straight to a verdict, so it returned `SAFE` even on textbook in-scope bugs. The hunt
  prompt is reordered so the agent must enumerate the bug-class lens and walk the in-scope code
  BEFORE it emits `CANDIDATE`/`SAFE` — surfacing leads it previously missed, with the two-sided
  forge-verify gate still the only path from lead to finding.
- Real FULL-contract auditing — `strip_comments` no longer overflows the string heap (#861). The
  in-`.ag` `strip_comments` builds its result with `reduce(lines, |acc,l| acc + ...)`, which is
  O(n²) string allocation and overflowed the 16 MiB per-tick string heap on a full ~1500-line real
  contract — so reconn/guard died before ever matching, and the colony could only audit extracted
  single functions. agentis has no `join`/`regex_replace` builtin for an in-`.ag` O(n) rewrite, so
  the EVM path now offloads to `evm-harness/strip-comments.js` (O(n), reuses struct-sig.js's
  stripComments); the Rust path keeps the in-`.ag` stripper. Seed + match both offload, so exact
  hashes stay aligned. Proven: the full 84 KB Venus `VToken.sol` (65 functions) now audits
  end-to-end — `distilled 65 sub-graph(s)` → `SEEDED FUZZY MATCH -> Reentrancy` → guard fired
  `[High]`, where before it died in `strip_comments` with `string_heap limit exceeded`.
- Decomposed-synthesis EXPLOIT slot now uses `try_call`/`try_call_value` (revert-tolerant) for the
  attack step instead of `call`/`call_value` (which `die` on a revert). On a secure target the attack
  reverts — which means the invariant HELD — but a plain `call` turned that into a false
  `HARNESS ERROR` (exit 2) that masked the verdict and burned `retry(5)` rounds. Surfaced running the
  colony on a real complex target (Cyfrin Puppy Raffle): the decomposed synthesis produced
  sophisticated correct exploit code and CONTROL passed, but the exploit's `call` reverted → exit 2.
- Real-repo compile robustness in `evm-harness/solc-resolve.js`: (1) handle caret/range pragmas
  (`^0.7.6`, `~0.8.4`, `>=0.7.0 <0.8.0`) by selecting the floor solc version when its minor differs
  from the local pinned build (real repos overwhelmingly use caret pragmas; an exact-pin-only match
  fell through to the local solc and failed with "requires different compiler version"); (2) resolve
  Foundry-default remappings written WITHOUT a trailing slash (`@openzeppelin/contracts=lib/…/contracts`)
  via `path.join` instead of `path.resolve` (the no-trailing-slash remainder starts with `/`, which
  `path.resolve` treated as absolute and discarded the project prefix → "import not found"). Surfaced
  by running the colony on a real OpenZeppelin-based Foundry target (compiles 0.7.6 + resolves OZ imports).

### Added

- M2 harvest — `harvest-sherlock.js` pulls real findings from a Sherlock judging repo (the `NNN-H`/`NNN-M`
  valid-finding folders) into a seed manifest for the DAG bug-pattern matcher (#861). It maps each
  finding's title/lead to one of the colony's verifiable classes (Reentrancy / AccessControl /
  UncheckedCall / OracleManipulation / IntegerOverflow) by keyword cue, extracts the vulnerable function
  from the finding's `solidity` block, and emits `<NNN>.sol` + a `Class|path|func-marker` manifest that
  `run-audit.sh --seed-manifest` feeds to the seeder. Findings whose root cause is NOT one of the five
  classes (subtle / multi-contract logic) are skipped — the harness can't verify them anyway. Proven on
  the Alchemix Sherlock contest: 20 findings -> 4 real patterns seeded with their actual functions.
  (Exact-hash match catches verbatim N-day forks of these; structural-variant matching is the next step.)

- DAG bug-pattern matching — seed the federation's content-addressed DAG with real findings so the
  colony recognizes recurring patterns (N-day forks) on real targets (#861). `seed-patterns.ag` +
  `run-audit.sh --seed-manifest` record a finished-contest finding's vulnerable-function sub-graph as
  `bugpat:exact:<hash> = class`; reconn's new `match_seeded_evm` looks up each target sub-graph against
  the seed (mirroring `distill_subgraphs_evm`'s hashing) and guard fires the matched class **directly**,
  beating the LLM classifier's conservative SAFE on real audited code (which returned SAFE on 13/13 real
  contracts in testing). The two-sided real-EVM gate still verifies, so a stale/over-broad seed can never
  mint a false VERIFIED — worst case one inconclusive synthesis. Proven end-to-end: seed VulnToken's
  `mint` (AccessControl) → a fork (renamed contract, identical `mint`) matches → guard fires via the seed
  (no LLM) → synthesis VERIFIED. Exact-hash match catches byte-identical N-day forks; structural-variant
  matching + a harvest of real findings are the next steps.
- Decomposed EVM PoC synthesis (#982). The synthesis agent no longer asks the LLM for the WHOLE
  `poc.rs` in one prompt — a large OUTPUT that stalls `claude -p` on a non-trivial contract (a real
  target's one-shot never returned at a 600s timeout; a small-output fragment prompt returns in
  ~40s). Instead a fixed skeleton (`evm-harness/poc-skeleton.rs`) carries all the revm-14 boilerplate
  + helpers, and the LLM fills only two small slots — the CONTROL block and the EXPLOIT block (~15
  lines each) — which `evm-harness/assemble-poc.js` splices in. Each generation is small + fast and
  the LLM writes far less error-prone code (the helpers handle the fiddly revm API). The two-sided
  gate (`CONTROL OK:` + `INVARIANT VIOLATED:` + exit 101) is unchanged. Validated end-to-end through
  the live colony: a real OpenZeppelin Foundry target reaches VERIFIED in ~48s on the first attempt.
  Solana / std-only targets keep the single one-shot prompt (their PoCs are smaller).
- Real multi-file Foundry/Hardhat target support (#980). The EVM colony can now compile + run on
  real multi-file projects (OpenZeppelin/lib imports, inheritance, a project-pinned solc), not just
  self-contained single-file contracts. A project-aware compiler (`evm-harness/compile-project.js`
  + shared `evm-harness/solc-resolve.js`) resolves a target contract's imports via the project's
  remappings + layout (lib/ submodules, node_modules) and selects/loads the project's solc version
  (offline from an on-disk soljson cache, host-side `--warm` pre-download); a dep-fetch helper
  (`fetch-target.sh`) clones a target repo with its submodules/deps; `run-audit.sh` gains
  `--repo` / `--in-scope` / `--contract`; and the `auditor.ag` `compile_run` + reconn (`ast.js`)
  paths dispatch to the project compiler when a repo target is set. The colony detects + verifies
  the single-contract bug classes on real code via the unchanged two-sided real-EVM gate; complex
  multi-contract protocol-exploit verification remains the later frontier.
- EVM/Solidity auditing — M4 (agentis-core#858). The EVM calibration corpus + harness, the peer of
  the Solana `calibrate-sealevel.sh` / `sealevel-scorecard.md`. A five-class vuln+safe corpus in
  `evm-harness/contracts/` (Reentrancy + AccessControl reused from M1–M3, plus new UncheckedCall,
  OracleManipulation, and IntegerOverflow pairs — each vuln written to be unambiguously its own
  class, all solc-0.8.26-compileable with committed `contracts/bin/*.bin`), `calibrate-evm.sh`
  (runs `run-audit.sh` over the five class pairs, tallies true-positive / false-VERIFIED /
  non-SAFE, parameterized by `BACKEND`/`AGENTIS`/`EVM_HARNESS_DIR`), and `evm-scorecard.md` (the
  scorecard doc with the corpus table, methodology, and an operator-fillable RESULTS template).

- EVM/Solidity auditing — M2 + M3 (agentis-core#858). **M2**: real Solidity reconn ingest
  (`evm-harness/ast.js`, solc AST → the canonical `{kind,name}` node stream → DAG), replacing
  M1's `.sol` bypass so EVM targets get the full reconn→guard→tracker pipeline (target hash
  unchanged → verdict cache + two-sided gate intact). **M3**: the full EVM class set —
  `classify_evm_llm` returns Reentrancy | AccessControl | UncheckedCall | OracleManipulation |
  IntegerOverflow | Safe, each with a per-class CONTROL/EXPLOIT invariant (`evm_invariant_for`)
  fed to the revm-PoC synthesis, plus the EVM peer of the #852 anti-forgery gate
  (`pocChallenge_<nonce>` injected into the target; a supplied `--poc` must surface the nonce or
  is rejected — fail-safe). Validated end-to-end on the live runtime: AccessControl vuln →
  `VERIFIED` (Critical) + human-gated package, the guarded variant → `SAFE`; reentrancy unchanged.

- EVM/Solidity auditing in the colony — M1 (agentis-core#858). `auditor.ag` now dispatches on
  `EVM_HARNESS_DIR` / a `.sol` target: the LLM writes a self-contained `revm` PoC, the target +
  a generic reentrancy attacker are solc-compiled host-side (`evm-harness/compile.js`, solc 0.8.26
  pinned via `package.json`), and the PoC runs the unchanged two-sided gate (`CONTROL OK:` +
  `INVARIANT VIOLATED:` + `exit 101`) through the real EVM (revm). `run-audit.sh` gains
  `--evm-harness` and accepts `.sol` targets; the submission package preserves the EVM PoC +
  attacker. Validated end-to-end on the live runtime: the reentrancy vault → `VERIFIED` +
  human-gated package; the secure variant → `SAFE` (no false-VERIFY). Scope is the reentrancy
  class with a `.sol` reconn bypass; Solidity reconn ingest (M2) and the broader EVM class set
  (M3) follow.

### Security

- Harden the supplied-`BOUNTY_POC` path so a target-agnostic forged PoC cannot mint a false
  `VERIFIED` (agentis-core#852). The `assess()` two-sided gate is byte-for-byte unchanged; the
  fix lives entirely in the `BOUNTY_POC` branch of `synth_via_prompt()`. A human-supplied PoC
  must now (1) structurally reference the in-scope target/harness for the active mode
  (`poc_exercises_target`) and (2) pass a per-run target-linkage challenge: a fresh nonce const
  is appended to the target the PoC compiles against, the PoC is wrapped to echo it before its
  own `main` runs, and the run output must surface the nonce — a PoC that never links this run's
  target cannot. The documented "simply prints both markers without exercising the target"
  forgery is now rejected (new negative-test fixture `fixtures/forged_marker_printer.rs`). The
  autonomous LLM/template path is untouched, and `calibrate-sealevel.sh` (3/3 true-positive,
  0 false-VERIFIED) still passes because the committed `sealevel/*/poc.rs` link the target and
  surface the nonce. Residual (documented): a sophisticated operator-supplied PoC that links the
  target but never invokes the vulnerable path cannot be distinguished from captured stdout — an
  operator-trust assumption on the explicit override, not an autonomous gap.

### Added

- Operator runbook (V8): `docs/RUNBOOK.md` — a one-page guide an operator follows to run a
  real audit from scratch: prerequisites + one-time offline-toolchain warm, pointing at a
  scope (target, native/anchor harness, optional frozen snapshot, backend), the exact
  `run-audit.sh` command, reading the verdict (VERIFIED / INCONCLUSIVE / SAFE), where the
  report + PoC land, the manual human-gated submission step, the calibration scorecard, and
  known limitations (vuln classes, chains/shapes, the snapshot owner-rebind, the
  operator-supplied-PoC trust boundary).

- Operator entrypoint + human-gated submission package (V7): `run-audit.sh` runs the auditor
  end-to-end against an operator-chosen scope (`--target` program, optional `--harness` /
  `--anchor-harness`, optional `--snapshot`, `--backend`, `--sandbox`) and, on a VERIFIED
  finding, assembles a submission package on disk (`submission/`: the Immunefi-format
  `report.md` embedding the PoC, the PoC source, the target, the snapshot, + a `MANIFEST.txt`
  marked `PENDING HUMAN REVIEW — NOT SUBMITTED`). It NEVER contacts a bounty platform, NEVER
  auto-submits, and NEVER auto-picks a scope — the operator supplies the target, and
  submission is a separate, explicit human action. The colony has zero platform-egress
  builtins (only host-side `prompt()` + sandboxed `exec`). Validated: a VERIFIED run stages a
  complete human-gated package; a non-VERIFIED run stages nothing.

- Real on-chain state snapshot (V4): `snapshot-rpc.sh` fetches accounts from a Solana RPC
  (`getAccountInfo`, base64) host-side and freezes them to a **content-addressed** snapshot
  (real `owner` / `lamports` / `data` — not a hand-written stub). The native vault harness
  gains a `poc_snapshot` bin that seeds the vault account from a frozen snapshot's real
  `lamports` + data bytes and replays the MissingSignerCheck invariant through the real SVM
  **fully offline** (zero network in-sandbox). The colony wires it in: `snapshot_state()`
  recognises the real account format, and when the native harness is active with
  `BOUNTY_SNAPSHOT` set the report's snapshot section is produced by a real offline SVM
  replay (`run_snapshot_replay` / `harness_snap_section`) instead of a std-only stub.
  Validated against a real mainnet account (the USDC mint): the frozen snapshot's real data
  drives a `CONTROL OK` + `INVARIANT VIOLATED` two-sided replay offline. A zero-value /
  foreign snapshot stays inconclusive (no false-VERIFIED).

- Calibration on real `coral-xyz/sealevel-attacks` lessons (V6): an offline,
  Anchor-capable PoC harness (`solana-harness-anchor/` — `anchor-lang` 0.31 +
  `solana-program-test` 2.x + `spl-token`, committed `Cargo.lock`, stable rustc, no SBF
  platform-tools) compiles a real Anchor program and drives it through the real
  `solana-runtime` SVM. The corpus (`sealevel/`) holds three lessons modernized verbatim
  to anchor 0.31 — signer-authorization (`MissingSignerCheck`), account-data-matching
  (`AccountDataMatching`), owner-checks (`MissingOwnerCheck`) — each with insecure + secure
  variants and a verified two-sided exploit PoC. The colony routes to the Anchor harness
  via `SOLANA_ANCHOR_HARNESS_DIR` (a `harness_dir()` helper + anchor branches in
  `poc_instruction` / `compile_run`); detection and the two-sided `assess()` gate are
  unchanged. `calibrate-sealevel.sh` runs the full detect → validate pipeline over the
  corpus and writes `sealevel-scorecard.md`. Demonstrated: the auditor runs end-to-end on a
  real lesson **fully offline inside the hardened sandbox** (host-side only the LLM call;
  the LLM-generated PoC compiles + runs offline through real `solana-program-test`, with a
  human-gated report), with ≥3 true-positive VERIFIED on the insecure lessons and **zero
  false-VERIFIED** on the secure variants — holding even when detection over-flags a secure
  variant, because the two-sided gate (the secure program rejects the exploit) is the source
  of truth, not the detector.

- Program-specific invariant library (V5): each detected vulnerability class now
  drives synthesis through a class-specific invariant (`invariant_for(class)`)
  instead of a single hardcoded signer-drain story. The PoC-generation prompt
  (`poc_instruction(class)`) embeds the right control/exploit invariant per class —
  ownership substitution for `MissingOwnerCheck`, identity mismatch for
  `AccountDataMatching`, program-id redirection for `ArbitraryCPI`, arithmetic wrap
  for `IntegerOverflow`, non-signer authority for `MissingSignerCheck` — and the
  standardized report's severity / summary / impact / remediation are class-aware
  (`severity_for` / `summary_for` / `impact_for` / `remediation_for`). Detection now
  routes every recognised class to synthesis (previously only `MissingSignerCheck`
  was synthesized and `IntegerOverflow` stopped at a "DETECTED" stub). The built-in
  deterministic template is signer-shaped, so a non-`MissingSignerCheck` class with
  no usable LLM-generated PoC resolves to `inconclusive` — never a false-VERIFIED.
  The two-sided gate (`CONTROL OK:` + `INVARIANT VIOLATED:`) is unchanged and still
  blocks rigged/always-fire harnesses for every class.

### Changed

- Detection verdict for `IntegerOverflow` in offline / `mock` mode is now
  `inconclusive` (routed through synthesis with the overflow invariant) rather than
  the previous non-committal `DETECTED`, since no deterministic overflow template
  exists; a real LLM backend generates the two-sided overflow PoC.

- Generalised detection (V3): an LLM-driven classifier (`classify_llm`) reads the
  program source and returns a vulnerability class (`MissingSignerCheck` /
  `MissingOwnerCheck` / `AccountDataMatching` / `ArbitraryCPI` / `IntegerOverflow`
  / `Safe`), generalising past the structural heuristic to real Anchor shapes it
  cannot see (e.g. an `authority: AccountInfo` field that should be a `Signer`).
  It is primary when a real LLM backend is configured; the structural heuristic
  remains the offline / `mock`-deterministic fallback (the mock backend yields no
  class token, so detection falls through unchanged). A mis-classification only
  routes to synthesis — the two-sided real-SVM gate stays the source of truth, so
  it can never cause a false-VERIFIED.

## [0.1.0] — 2026-06-09

**Requires:** agentis >= `1.18.0`

### Added

- Initial dark-factory federation: an autonomous Solana/Anchor bounty
  auditor. A single `auditor` colony runs an `agentis go`-driven audit
  pipeline (reconn → guard → tracker → synthesis) entirely on the agentis
  substrate, fully offline.
- Real LLM-driven two-sided PoC synthesis: the prompt-driven synthesis path
  generates a proof-of-concept that must exercise BOTH a control (an
  authorized caller is accepted → `CONTROL OK:`) and an exploit (an
  unauthorized caller breaks the safety invariant → `INVARIANT VIOLATED:`),
  so a rigged always-fire harness cannot pass the validation gate.
- Offline `solana-program-test` toolchain: a committed harness crate
  (`solana-harness/`) drives the ingested program through the real
  `solana-runtime` SVM (real account model, signer/owner checks, lamport
  conservation) compiled with stable rustc — no SBF platform-tools, no
  network at audit time. The one-time dependency-graph warm build is staged
  by `setup-solana-toolchain.sh`.
- Human-gated submission: a verified finding is written as a standardized
  Immunefi-shaped report and, at `review-gated` / `autonomous` tier, staged
  with a `pending_human_review` marker. The colony NEVER auto-posts to a
  bounty platform — submission is always an explicit human action.

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.10.1...HEAD
[0.10.1]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.10.0...dark-factory-v0.10.1
[0.10.0]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.9.0...dark-factory-v0.10.0
[0.9.0]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.8.0...dark-factory-v0.9.0
[0.8.0]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.7.0...dark-factory-v0.8.0
[0.7.0]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.6.0...dark-factory-v0.7.0
[0.6.0]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.5.0...dark-factory-v0.6.0
[0.5.0]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.4.3...dark-factory-v0.5.0
[0.4.3]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.4.2...dark-factory-v0.4.3
[0.4.2]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.4.1...dark-factory-v0.4.2
[0.4.1]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.4.0...dark-factory-v0.4.1
[0.4.0]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.3.0...dark-factory-v0.4.0
[0.3.0]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.2.0...dark-factory-v0.3.0
[0.2.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/dark-factory-v0.2.0
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/dark-factory-v0.1.0
