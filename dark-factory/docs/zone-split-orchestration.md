# Zone-split orchestration (epic #1611)

Auto-derive a target's DISCOVERY manifest from the code itself, then hunt it. Until now the
`scope.tsv` that `run-discovery.sh --scope` consumes was hand-written per target: the operator read the
repo, grouped contracts into subsystems, and guessed which taxonomy bug classes applied to each. **M1
(#1612)** automates that first pass — `map-zones.sh` (shell plumbing) + `zone-mapper.ag` (substrate
classification) emit a ready-to-hunt `scope.tsv` and a structured `zones.json`.

The manifest stays fully operator-editable: M1 produces a *starting point*, not an authority. A
mis-clustered zone is one line to fix, and nothing downstream trusts the map blindly.

## The zone model

A **zone** is a candidate subsystem: one directory of in-scope Solidity/Anchor sources, grouped by
directory, that an attacker would probe as a unit. Each zone carries:

- a stable **id** (the slug of its relative directory),
- a human **name** and **description** (from the substrate),
- its **files** (relative to the repo; a big contract is function-sliced — see below),
- **loc** (lines of code across the zone),
- an advisory **hardening_score**,
- **bug_classes_likely** — the subset of the taxonomy's `C1..C14` classes the substrate picked.

### `.ag` vs shell split

The split is deliberate and mirrors how `run-discovery.sh` delegates the per-cell hunt to `hunter.ag`:

| Layer | Owns |
|-------|------|
| **shell** (`map-zones.sh`) | MECHANICAL: locate sources, group by directory, count LOC, compute `hardening_score`, function-slice big contracts, format `zones.json` + `scope.tsv`, invoke the substrate once per zone. |
| **`.ag`** (`zone-mapper.ag`) | SEMANTIC: given ONE zone's concatenated code + the taxonomy, decide its name, its applicable bug classes, and a one-line description — the reasoning a static keyword-grep cannot justify. |

The substrate owns the classification because mapping a bespoke subsystem to applicable bug classes is a
reasoning task; a static grep list mis-labels custom code and cannot explain *why* a class applies (the
depth lever M2 builds on).

## `zones.json` schema

A JSON array, one object per zone, every object carrying all seven keys:

```json
[
  {
    "id": "contracts_vault",
    "name": "vault deposits",
    "files": ["contracts/vault/Vault.sol", "contracts/vault/VaultMath.sol"],
    "loc": 46,
    "hardening_score": 60,
    "bug_classes_likely": ["C1", "C6", "C11"],
    "description": "ERC4626-style share vault: share-price accounting, rounding, first-depositor inflation"
  }
]
```

## `hardening_score` derivation

An integer in `[0, 100]`, computed **offline** and **deterministically** from two signals:

- **post-audit churn** (via `audit-delta.sh --since <ref>`): a zone whose files changed *after* the audit
  froze is LESS battle-tested → a lower score. Monotone-decreasing in the zone's churn ratio.
- **git file age**: older files are more reviewed → a higher score (capped at 30 days).

Pinned formula: `round((1 - churn_ratio) * 60 + (age_days / 30) * 40)`, clamped to `[0, 100]`.

**It is advisory, never a gate.** A low-hardening zone still ships in `scope.tsv` and is still hunted —
the score is a hint for the operator's attention, not a filter. `demo-map-zones.sh` asserts both the
monotonicity and the not-a-gate property.

## The `scope.tsv` ↔ `run-discovery.sh` contract

`scope.tsv` is **pipe-delimited** (despite the `.tsv` name), exactly the format `run-discovery.sh
--scope` documents and parses today — so `map-zones.sh` output feeds the hunt with no glue:

```
<subsystem label> | <classid,classid,...> | <file[,file...]>
```

- `#`-prefixed and blank lines are ignored; fields are whitespace-trimmed; files are relative to the repo.
- A big contract is written `file@fn1+fn2+...` (the `slice-fns.sh` slice format) so a deep per-cell read
  fits the hunter's per-call budget.
- No `|`, newline, or backtick may appear inside any field (shell-safety, asserted by the demo).

### Round-trip: `run-discovery.sh --list-cells`

`run-discovery.sh` gained an opt-in `--list-cells` (alias `-n`) DRY RUN: it runs the *same* manifest
normalization as the hunt loop and prints one `CELL|<subsystem>|<class>|<files>` line per cell it WOULD
hunt, then exits — BEFORE any `agentis init` / config / report side-effect, needing neither `--brief` nor
an agentis binary. It is the offline round-trip that proves `map-zones.sh`'s `scope.tsv` enumerates the
intended cells. With no `--list-cells` every guard is inert and the shipped hunt path is byte-identical.

## M2: per-zone brief generation (#1619)

M1 produces the *manifest* (which subsystems, which bug classes). **M2 (#1619)** produces the *depth* — a
per-zone **hunt brief** that primes the discovery hunt. `gen-briefs.sh` (shell plumbing) + `brief-writer.ag`
(substrate authoring) read M1's `zones.json` + `scope.tsv` and emit one `briefs/brief_<zone_id>.md` per zone,
plus a `briefs/zone_briefs.json` index (`zone_id → {brief, classes}`).

### The `SCOPE_BRIEF` contract (locked)

A brief is fed VERBATIM to the hunter: `run-discovery.sh --brief <file>` resolves it to an absolute path and
passes it as env `SCOPE_BRIEF` to every `(subsystem × class)` cell; `hunter.ag` reads it
(`cat_file(getenv("SCOPE_BRIEF"))`) and injects it into the prompt as the `=== PROTOCOL BRIEF … ===` section,
AFTER the taxonomy-class lens and BEFORE `=== RULES ===`. So a brief is **plain-text markdown, ONE per run**.
Per-zone briefing therefore needs no new hunt-path wiring — the M3 fan-out will run
`run-discovery.sh --only <zone> --brief brief_<zone>.md` once per zone on the *existing* single-`--brief` flag.

### Emitted brief schema

Fixed shell-authored scaffold, in order; only the attack-surface **body** is substrate-authored:

```
# <zone name> — hunt brief   (zone: <zone_id>)
In-scope files: <files / @fn-slices from scope.tsv>
Bug classes to hunt: <Cn (taxonomy title), …>

## Invariants to break / attack surface
<SUBSTRATE BODY: brief-writer.ag's per-class invariants-to-break + folded audit residual + prior-pattern
 hints; a mechanical fallback of the class titles when the substrate SKIPs / is unavailable / --fixture absent>
### Audit-residual leads (surface prior auditors missed)   ← only when --audit-residuals matched this zone

## In scope — a valid finding        <Medium/High only; the external-attacker impact language>
## Out of scope — NEVER report        <the audit BOUNDARY set when present, else the generic exclusion>
## Honesty mandate                    <trace the code; write + run a real Foundry PoC; a rigorous SAFE is valid>
```

The whole brief is markdown-safe: no NUL, ≤ 2000 lines (the `sed -n '1,2000p'` window `hunter.ag` reads), and
no bare `CANDIDATE|` / `BLACKBOARD-` token (defensive — a brief must never masquerade as a hunter output line
`run-discovery.sh`'s scraper reads). `gen-briefs.sh` sanitises the substrate body to guarantee this.

### `.ag` vs shell split

| Layer | Owns |
|-------|------|
| **shell** (`gen-briefs.sh`) | MECHANICAL: read `zones.json`/`scope.tsv`, gather the code refs, match the audit residual, invoke `brief-writer.ag` (or slice the `--fixture` body), assemble the deterministic scaffold + scope boundaries + honesty mandate, write `brief_<id>.md` + `zone_briefs.json`. |
| **`.ag`** (`brief-writer.ag`) | SEMANTIC: given ONE zone's concatenated in-scope code + its bug classes + the taxonomy + (optional) audit residual/boundary, author the DEPTH body — concrete invariants-to-break per class, the residual surface the audits missed, prior-pattern hints. |

`brief-writer.ag`'s output is a block delimited by `DARK-FACTORY:BRIEF-BEGIN|<zone_id>` … `DARK-FACTORY:BRIEF-END`
(the `report-writer.ag` sentinel-block idiom — a multi-line body cannot ride a single `PREFIX|value` line), or
the single token `SKIP`. `gen-briefs.sh` awk-slices the same block from a live `agentis go` log or from
`--fixture` (the `run-gate-agent.sh --classify-log` precedent: identical extraction over a canned log).

### Residual sourcing (degrade-gracefully)

`gen-briefs.sh --audit-residuals <file>` CONSUMES `audit-scout.ag`'s output — its `BOUNDARY|<known>` +
`RESIDUAL|<subsystem>|<class>|<why-missed>|<sketch>` lines. Per zone, a `RESIDUAL|` line is matched by bug-class
membership or a subsystem-name match, folded into the body, and its `BOUNDARY|` set seeds the out-of-scope
section. M2 does NOT itself fetch or run `audit-scout.ag` — it only consumes its output *if present*; absent
`--audit-residuals`, briefs still emit (residual folding is optional enrichment).

### Round-trip: `run-discovery.sh --brief … --list-cells`

M2's ONLY `run-discovery.sh` edit is an ADDITIVE, opt-in, byte-identical-default extension of M1's
`--list-cells` dry-run: when `--brief` is ALSO given, it validates the brief, resolves it to an absolute path,
and prints `BRIEF|<abs>|<line-count>` BEFORE the cell enumeration — the offline (no-agentis) proof that a
generated brief resolves and is what would be handed to every cell as `SCOPE_BRIEF`. With no `--brief`,
`BRIEF=""` so the block is skipped and the M1 `--list-cells` output is unchanged; the shipped hunt path is
byte-identical. `demo-gen-briefs.sh` pins the whole chain (map → brief → round-trip → residual fold) offline.

## M3: parallel fan-out (#1625)

M1 produces the manifest, M2 the depth; **M3 (#1625)** adds THROUGHPUT. `run-discovery.sh` gains an opt-in
`--jobs N` (alias `-j N`, default `1`) bounded-concurrency fan-out: instead of hunting the `(subsystem ×
class)` cells strictly serially, it runs up to N of them CONCURRENTLY. Wall-clock drops from the *sum* of the
cells toward the *slowest cell* per concurrency wave — the lever that makes a large auto-mapped manifest
(many zones × many classes) practical to hunt in one pass.

`--jobs 1` (the default) is **byte-for-byte identical** to the pre-M3 hunt: it runs the current serial loop
against the ONE shared agentis store with live #1001 blackboard steering, and every piece of the fan-out
machinery sits behind `[ "$JOBS" -gt 1 ]`. `run-discovery.sh` factors the per-cell invocation (`run_cell`)
and the per-cell scrape (`scrape_cell_log`) into functions the serial loop and the parallel-aggregation pass
call **identically**, so the serial report cannot drift.

### The OOM/thrash discipline — a HARD cap, never fail-open

The headline risk is memory. Each cell is an `agentis go` → LLM PTY session, and a real hunt spawns
downstream `forge`/`solc` builds; N of those at once can melt a single ~30 GB host. M3 enforces a **hard
ceiling**: effective concurrency `= min(--jobs, LLM_MAX_DISCOVERY_CELLS)`, default cap `4`, enforced by a
self-contained `wait -n` job-slot loop that keeps at most that many `run_cell` processes live at any instant.
`--jobs 99` on a default host is silently clamped to 4 (with a stderr warning). Tune the cap per host via
`LLM_MAX_DISCOVERY_CELLS` — raise it on a big box, drop it to 2 on a laptop.

This is deliberately NOT `tools/lib/llm-session-slot.sh`: that daemon-tier semaphore **fails open** after
`LLM_SLOT_WAIT_S` (it cannot guarantee "never more than N"), caps host-global LLM sessions at a different
granularity than the outer `agentis go` process, and resolves its pool from `COLONY_DIR`/`AGENTIS_*` — env an
operator-run discovery batch does not set. A small self-contained hard cap is both smaller and honest for the
"the cap is never exceeded" guarantee; `demo-discovery-parallel.sh` asserts it (including the clamp path).

### Blackboard under concurrency (isolate-and-aggregate)

The #1001 blackboard is a SHARED in-run memo: each cell reads the board before it prompts and posts its
CANDIDATE back, so a lead an earlier cell found steers later cells. That read-append-write is race-free today
ONLY because cells run **sequentially** against one shared store. Under `--jobs > 1` there is no "later" cell
to steer, and concurrent writes into one agentis store would risk lost updates / corruption. M3 resolves this
by **isolation**: each parallel cell gets its OWN agentis store — a `cp -r` of the initialised `$RUN`
template into `$RUN/cell-<slug>_<cls>/` — so there is no shared board to race. Every cell therefore starts
with an EMPTY board, `hunter.ag`'s `focus_block()` returns `""`, and its prompt is byte-identical to the
pre-#1001 single-cell prompt. **Cross-cell #1001 steering is deliberately disabled under `--jobs > 1`** — a
documented throughput-vs-steering trade. Serial (`--jobs 1`) keeps the shared store WITH live steering.

The **rejected** alternative was making the shared board concurrency-safe (atomic append / `mkdir`-lock). It
was rejected because #1001's read-append-write encodes a "later cell sees an earlier cell's lead" ORDERING
that is meaningless when cells run concurrently — even a race-free append buys only a nondeterministic partial
view while forcing concurrent writes into one store (corruption risk) and a `hunter.ag` protocol change.
Isolation is smaller, honest, and the only option that makes the aggregated result deterministic.

### Deterministic aggregation

Cells finish out of order, but results are collected AFTER the pool fully drains, by scraping each cell's log
in **manifest order** with the same `scrape_cell_log` the serial path uses. So the final `discovery-report.md`
candidate/coordination rows — and the additive machine-readable `discovery-results.json` (emitted on both
paths: `{repo, backend, jobs, cells:[…], totals:{cells,candidates,steers}}`) — are identical to the serial
result set and independent of completion order. `demo-discovery-parallel.sh` pins the whole contract offline
via a fast stub wired through the existing `--agentis` seam (no live agentis/forge/network): serial == golden,
concurrency observed + cap never exceeded (incl. the clamp), aggregation == serial, per-cell isolation,
`STEERS = 0` under parallelism, and a failed cell still degrades (its log is scraped, the run finishes).

## M4: verify integration (#1630)

M3 emits `discovery-results.json` — a machine-readable set of UNVERIFIED candidate LEADS. A candidate is worth a
human's attention ONLY after a SECOND, independent gate fails to kill it. **M4 (#1630)** is that bridge:
`verify-findings.sh` drives the gate over EVERY candidate and aggregates the survivors into
`verified_findings.json`, the CONFIRMED-only input the M5 capstone hands to the submission pass.

### Input → gate → output

- **Input.** `verify-findings.sh --results <discovery-results.json> --repo <dir> --out <dir>`. It reads the M3
  JSON (never the markdown report) and splits each `cells[].candidates[]` string on `|` into its five fields —
  `<file:fn:line>|<classid>|<severity>|<exploit>|<poc sketch>` — deriving each candidate's code file as the part
  before the FIRST `:` of the location (resolved against `--repo`). It is **READ-ONLY**: it never mutates
  `discovery-results.json`.
- **Gate (`--gate`, default `refute`).** Per candidate it writes a one-line gate manifest from the candidate's
  own fields and invokes the operator-selected gate AS-IS:
  - `refute` (default): `run-refute.sh` — a hostile skeptic re-reads the candidate against the real control-flow
    and defaults to REFUTED on any doubt; **CONFIRMED = the `REAL` verdict**, read from the
    `| <location> | <class> | <VERDICT> | <reason> |` row of the per-candidate `refute-report.md`. Default
    because its `<file:fn>|<class>|<sev>|<exploit>|<code-file>` manifest is the best match for a discovery
    candidate and it has the offline `--agentis` + `--backend mock` stub seam.
  - `poc`: `run-poc.sh` — CONFIRMED = the `POC|<target>|FINDING` line.
  - `symbolic`: `run-symbolic.sh` — CONFIRMED = the `SYMBOLIC|<file:fn>|COUNTEREXAMPLE` line.
- **Per-candidate isolation (degrade).** Each gate call is wrapped so a gate that ERRORS on one candidate is
  logged and SKIPPED (never fatal), and any candidate the gate cannot CONFIRM (incl. a missing code file that
  the gate cannot evaluate) is DROPPED as unverified. One bad candidate never aborts the batch; a rigorous
  negative (zero survivors) is a valid outcome.
- **Output — `verified_findings.json` (CONFIRMED-only).**
  `{repo, gate, verified:[{subsystem, location, file, class, severity, exploit, poc_sketch, verdict, reason}],
  totals:{candidates, verified}}`, emitted via `python3 json.dumps` (the repo convention).

`demo-verify-findings.sh` pins the schema, the CONFIRMED-only filtering (REFUTED dropped), the read-only
invariant (`discovery-results.json` byte-unchanged), the degrade path, and never-submit — all offline via the
`--agentis` refute stub.

## M5: gate + deliver — the capstone (#1630)

M1 maps, M2 primes, M3 hunts, M4 verifies. **M5 (#1630)** is the CAPSTONE that chains them into ONE end-to-end
autonomous zone-hunt: `run-zone-hunt.sh --repo <dir>`. It EDITS none of the shipped scripts — it only invokes
them as-is — and it CLOSES epic #1611.

### The chain (exact)

```
map-zones.sh (M1)  →  gen-briefs.sh (M2)  →  per-zone run-discovery.sh (M3)  →  merge  →
verify-findings.sh (M4)  →  per verified finding: run-audit-pass.sh  →  deliver-submission.sh
```

- **M1/M2** run once; offline via `--map-fixture` / `--brief-fixture`, live via `--backend`/`--agentis`.
- **M3 — per-zone loop.** Because `run-discovery.sh` takes ONE `--brief`, the capstone honors M2's per-zone
  briefs by looping: for each zone in `zones.json`, `run-discovery.sh --only "<zone name>" --brief
  "briefs/brief_<id>.md" --jobs N …` into `<out>/discovery/<id>`, then MERGES each zone's
  `discovery-results.json` (concat `cells[]`, sum `totals`) into `discovery-results.merged.json`. Zones loop
  **serially** — the intra-zone `--jobs` is the only parallelism, so the M3 OOM cap is never stacked across
  zones.
- **M4** verifies the merged candidates (refute gate) → `verified_findings.json`.
- **M5 tail — per verified finding.** `run-audit-pass.sh` is called with the finding facts:
  `--finding-location`, `--finding-impact` (the exploit), `--poc-repo` (the repo), `--poc-target` (the code
  file basename), `--poc-hypothesis` (the exploit), `--poc-class`, `--severity-band`, `--in-scope` (the intake
  scope context), `--backend`/`--agentis`/`--out`, plus the mode switch: `--pass-fixture` offline or `--live`.
  When `pass-result.txt == PENDING-HUMAN-REVIEW` AND a `submission-draft.md` is present, `deliver-submission.sh`
  STAGES the marked draft into `<out>/drop/<slug>/` (manifest.json + submission-draft.md + OUTCOME.md).

### The HALT / NEVER-SUBMIT invariant (load-bearing)

The capstone contains NO `curl`/`wget`/`submit`/egress verb on any executable line. The never-submit invariant
is enforced by the TWO baked-in gates it REUSES per finding — its two enforcement points:

1. `run-audit-pass.sh` terminates at `PENDING-HUMAN-REVIEW` — it NEVER emits a submit; the best case is a draft.
   A blocked finding (`BLOCKED-SCOPE`/`NO-RESIDUAL`/`NO-POC`/`BLOCKED-IMPACT`) writes NO draft, so nothing is
   staged.
2. `deliver-submission.sh` REFUSES (exit 3) any draft lacking `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW` and only
   STAGES it into a LOCAL drop-dir.

The delivery/notify page (Slack) targets only the operator's OWN workspace, never a bounty platform. Because
`deliver-submission.sh` already pages internally, **the capstone does NOT call `notify-submission.sh` itself** —
that would double-page; with no Slack env the page is a silent no-op.

### Per-finding error propagation

Each finding's `run-audit-pass → deliver-submission` body is wrapped so a single bad finding (e.g. a submission
pass that hard-fails) is LOGGED and SKIPPED; the batch finishes over every remaining finding and the capstone
exits 0. `demo-run-zone-hunt.sh` pins the whole chain, the HALT on every delivered path, never-submit (no
egress, no draft for a scope-blocked finding), and per-finding propagation — all offline via ONE `--agentis`
stub + the M1/M2/M5 `--fixture` seams.

## The M1..M5 map

| Milestone | Scope |
|-----------|-------|
| **M1 (#1612)** | zone mapping: `map-zones.sh` + `zone-mapper.ag` → `zones.json` + `scope.tsv`; the `--list-cells` round-trip. |
| **M2 (#1619)** | per-zone brief generation: `gen-briefs.sh` + `brief-writer.ag` → `brief_<zone>.md`, fed to `run-discovery.sh --brief`. |
| **M3 (#1625)** | parallel fan-out: `run-discovery.sh --jobs N` bounded-concurrency over the `(subsystem × class)` cells + isolated per-cell stores + a hard cap + deterministic aggregation. |
| **M4 (#1630)** | verify integration: `verify-findings.sh` routes each surfaced lead into the refute (default) / poc / symbolic gate → CONFIRMED-only `verified_findings.json` (read-only over the M3 output). |
| **M5 (#1630)** | gate + deliver — the capstone: `run-zone-hunt.sh` chains map→brief→per-zone discovery→merge→verify→run-audit-pass→deliver-submission and HALTS every finding at `PENDING-HUMAN-REVIEW` (never submits). **Closes epic #1611.** |

## Three honest caveats

1. **Classification AND brief depth are LLM-backend-gated.** `zone-mapper.ag` and `brief-writer.ag` reason
   only as well as the backend behind `prompt()`; a `mock` run does not reason (the demos assert execution and
   format, never a specific class or a specific invariant). M2 ships the MACHINERY — the deterministic
   scaffold + substrate authoring + a fixture-proven format that round-trips into `hunter.ag` — but the LIVE
   brief quality (the decisive depth lever) is only as good as that backend and is a research risk measured
   against the manual baselines, not something the plumbing can guarantee. `--fixture` stubs the output for
   deterministic, offline CI; it proves wiring + format, never live quality.
2. **Concurrency needs a hard cap (M3, #1625).** Fanning the hunt across many cells without a ceiling would
   bunch `prompt()` sessions and OOM-thrash a single host. M3 (`run-discovery.sh --jobs N`) caps effective
   concurrency at `min(--jobs, LLM_MAX_DISCOVERY_CELLS=4)` with a self-contained hard `wait -n` slot (never
   fail-open), isolates each cell's store, and defaults to `--jobs 1` (serial, byte-identical). M1's own
   zone-mapping pass still runs zones sequentially.
3. **READ-ONLY, NEVER-SUBMIT.** `map-zones.sh` touches no network and has no submission path. Surfacing a
   starting manifest is the whole job; verification and any submission stay separate, human-gated actions.
