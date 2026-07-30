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
- **bug_classes_likely** — the subset of the taxonomy's `C1..C15` classes the substrate picked.

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
  zones. Zone ORDER is value-custody-first (#1826) and every zone's OUTCOME is recorded (#1830, below).
- **M4** verifies the merged candidates (refute gate) → `verified_findings.json`.
- **M5 tail — per verified finding.** `run-audit-pass.sh` is called with the finding facts:
  `--finding-location`, `--finding-impact` (the exploit), `--poc-repo` (the repo), `--poc-target` (the code
  file basename), `--poc-hypothesis` (the exploit), `--poc-class`, `--severity-band`, `--in-scope` (the intake
  scope context), `--backend`/`--agentis`/`--out`, plus the mode switch: `--pass-fixture` offline or `--live`.
  When `pass-result.txt == PENDING-HUMAN-REVIEW` AND a `submission-draft.md` is present, `deliver-submission.sh`
  STAGES the marked draft into `<out>/drop/<slug>/` (manifest.json + submission-draft.md + OUTCOME.md).

### M3 coverage: the record, the cell budget, the targeted re-hunt (#1830)

Before #1830 a truncated zone-hunt was **indistinguishable from a clean sweep**. STAGE 3 logged a failing zone
and continued; the merge glob (`if not os.path.isfile(p): continue`) skipped a zone dir with no
`discovery-results.json` exactly like a zone that never existed; and the merged file's keys were
`repo, backend, jobs, cells, totals` with no zone field anywhere. Measured on a preserved bench work dir: one
target hunted **1 of its 7 zones** (the zone holding the epic's named rare bug was never reached) and its
merged artifact reported a plausible 6-cell / 12-candidate run with **no representation of the other six
zones at all**.

**The record.** `<out>/coverage/zone-coverage.json` — a fixed path, not a flag, because it is a contract (it is
the input the autonomous self-tuning loop needs; a coordinator cannot close a gap that is never written down).
It is written **unconditionally and pessimistically**: before STAGE 3 runs a single zone it already contains
one entry per zone in `zones.json` with `status: "not_reached"`, and each entry is rewritten in place as the
zone transitions. **Absence is therefore not representable** — a zone can never be silently missing, only
visibly `not_reached` — and an externally-imposed kill still leaves a truthful record on disk. `zones[]` is
ordered by, and always the same length as, the #1826 priority order; paths in `results` /
`attempts[].artifacts` are relative to `<out>` so the record is portable.

```json
{
  "schema": "zone-coverage/v1",
  "repo": "…", "commit": "…", "started_at": "…", "updated_at": "…",
  "budget": { "unit": "cells", "per_zone": 0, "run": 0 },
  "zones": [
    { "id": "src", "name": "…", "value_custody": true, "order": 1,
      "status": "hunted", "cells_planned": 6, "cells_charged": 6,
      "classes_hunted": ["C1", "C6", "C11"], "budget_truncated": false,
      "cells": 6, "candidates": 12, "failed_cells": 0, "exit_code": 0,
      "started_at": "…", "ended_at": "…",
      "results": "discovery/src/discovery-results.json", "detail": "", "attempts": [] }
  ],
  "totals": { "zones": 7, "cells_planned": 21, "cells_charged": 6, "candidates": 12, "failed_cells": 0,
              "by_status": { "hunted": 1, "hunted_empty": 0, "hunted_degraded": 0, "failed": 0,
                             "budget_exhausted": 0, "in_flight": 0, "no_brief": 0, "not_reached": 6 } },
  "complete": false,
  "gap_zones": ["…"]
}
```

**The state vocabulary is closed** — a consumer branches on `status`, and each state licenses exactly one
conclusion:

| `status` | set when | what a consumer is entitled to conclude |
|---|---|---|
| `not_reached` | by `init`, before the loop; never updated | **Zero evidence.** Never attempted. NOT a negative. A re-hunt is a plain first attempt. |
| `no_brief` | STAGE 2 emitted no `briefs/brief_<id>.md` | **Upstream defect**, not a hunt outcome. A re-hunt cannot fix it (`--rehunt-gaps` does not re-run STAGE 2); needs a fresh full run. |
| `unscoped` | the zone ran **zero cells** — it has no matching line in `scope.tsv` | **Zero evidence, never a negative.** `map-zones.sh` emits a scope line only `if not skeleton and classes and z["id"] not in failed_zones`, so an unclassified zone and a `classification_failed` zone are both in `zones.json` and absent from the manifest — yet `gen-briefs.sh` walks `zones.json`, so they DO get a brief and reach STAGE 3. An **upstream mapping defect**: re-map the target; a re-hunt against the same map cannot fix it. |
| `in_flight` | immediately before `run-discovery.sh` is invoked | **Attempt started, outcome unknown** — the process died mid-zone (external kill, OOM). Artifacts partial. Retry as-is. |
| `failed` | `run-discovery.sh` exited non-zero | **Attempt made, the tool failed.** NOT a negative. Distinct from `in_flight`: a second failure is a defect to escalate, not an environment problem. |
| `budget_exhausted` | admission denied — 0 cells of the RUN budget remained | **The zone is hunt-able; the run declined to pay.** NOT a negative. Every zone AFTER it was denied too (the pool is spent, so the loop stops). Remedy: raise `--run-cell-budget`, or re-hunt. |
| `budget_unenforceable` | admission denied for a reason LOCAL to this zone: no class prefix lands exactly on the cap | **The zone is hunt-able; a PARTIAL hunt of it cannot be expressed.** NOT a negative, and deliberately not `budget_exhausted`: no pool was spent, the zones after it are unaffected (the sweep continues), and the remedy differs — give this zone its full planned budget, or re-map so its subsystem name is unique. |
| `hunted_degraded` | exit 0 **and** `totals.failed > 0` | **Partial coverage** — at least one cell produced no sentinel after retries (#1707). NOT a rigorous negative. |
| `hunted_empty` | exit 0, no failed cells, no candidates | **Rigorous negative for the classes actually hunted** — read together with `budget_truncated`. |
| `hunted` | exit 0, no failed cells, candidates > 0 | **Complete coverage** of the classes hunted; its candidates are in the merged file. |

`budget_truncated` is a **qualifier, not a status**: a zone whose per-zone cap shortened its class list was
genuinely hunted, but its `hunted_empty` is not a rigorous negative. Hence two derived fields, computed in one
place (`lib/zone-coverage.py`) so no consumer re-derives policy: `complete` = every zone is
`hunted`/`hunted_empty` **and** untruncated; `gap_zones` = the ids that fail that test, in priority order.

**A zone that ran zero cells can never be a `hunted_*` state.** This is the one derivation worth stating twice,
because getting it wrong re-creates the whole defect inside the record: `run-discovery.sh` exits **0** with
`totals:{cells:0,candidates:0,failed:0}` whenever `--only <name>` matched no manifest line, so
`failed == 0 and candidates == 0` is not evidence of cleanliness there. The guard is on the OUTCOME (zero cells
ran), not on any single cause, so an unclassified zone, a `classification_failed` zone and a `zones.json` name
that `map-zones.sh`'s `clean()` rewrote before it reached `scope.tsv` all land on `unscoped` rather than on a
fake rigorous negative. STAGE 3 also names the case up front, as a sibling of the missing-brief guard, so such
a zone is never hunted and never charged budget.

**Fail-loud, always on.** When `complete == false` STAGE 3 prints a `COVERAGE GAP:` banner + a per-status
breakdown to stderr; `discovery-results.merged.json` carries an additive top-level `coverage` object
(`complete`, `gap_zones`, `by_status`) plus the per-zone `totals.failed` the merge used to drop; and the
closing banner reports `<covered>/<total> zone(s) covered` instead of a hunted-zone count. Opt-in gate
(default OFF): `--require-coverage <pct>` exits **4** before STAGE 4/5, so a degraded run cannot produce a
plausible-looking result set — the record is already on disk when it aborts.

**The budget unit is CELLS**, enforced as an **admission decision before a zone starts**:
`--zone-cell-budget N` (one zone) and `--run-cell-budget N` (all of STAGE 3), both default `0` = OFF. A zone's
planned cell count comes from the shipped `run-discovery.sh --list-cells` dry run (#1612) — a pure manifest
parse that returns before the agentis-binary check, so it needs no binary, no LLM and no network. The
effective cap is `min(zone budget or ∞, run budget − spent or ∞)`:

- cap ≥ planned → hunt unchanged; the invocation is **byte-identical** (no `--classes` argument is added).
- 0 < cap < planned → hunt with `--classes <first cap distinct classes>` (scope.tsv order = the mapper's
  relevance order, so the least-likely classes are the ones dropped) + `budget_truncated: true` — **but only
  when that lands exactly on the cap, and that is measured, not assumed.** `--classes` is a per-manifest-LINE
  override in `run-discovery.sh`, not a cell filter, while the class list is per-CELL; `map-zones.sh` keys
  scope lines on `clean(name)` with no dedup, so a zone whose subsystem name matches **several** lines would
  admit `lines × cap` cells and would apply classes to files the mapper never assigned them to. A second
  `--list-cells` probe with the candidate override therefore measures the real admitted count; if it is not
  exactly the cap the zone is **denied as `budget_unenforceable`** (with the measured count in `detail`)
  instead of being mis-charged. That denial does **not** stop the sweep: unenforceability is a property of the
  one zone, not of a spent pool — nothing was charged, so the zones behind it are unaffected and a trivially
  enforceable neighbour is still hunted. (This is also why it is not `budget_exhausted`: that status would tell
  the operator to raise a budget when the real remedy may be to re-map the target.)
- cap == 0 → the zone is `budget_exhausted` and **the loop stops**; every remaining zone is `budget_exhausted`.
  This is the only path that stops the sweep, and it is reachable only with `--run-cell-budget > 0` — so the
  "the run cell budget was already spent" detail on the zones behind it can never be a false claim.
- probe failure → `cells_planned: null` + a `detail`; with budgets OFF nothing changes, with a run budget ON
  the zone is charged the whole remainder and is the last zone admitted.

Two things this deliberately does **not** do. It does not bound wall-clock, tokens or memory — cell *count* is
invariant to the #1825 function-slice cap while per-cell *cost* is not (that change measured **+0 cells,
+6…20 % payload**), so the budget is a **coverage-shaping knob, not a cost cap**. And it introduces **no
ordering of its own**: it consumes `.zone-list.tsv` exactly as #1826 sorted it, and "the first denial stops the
loop" is what keeps that true — best-effort packing (skip an expensive high-priority zone, admit a cheap
low-priority one) would silently invert #1826 and is an explicit non-goal, pinned by a self-test that asserts
the denied set is exactly the non-custody tail. Wall-clock deadlines were rejected: the observed truncations
were imposed from *outside* the pipeline (an internal deadline would have prevented none of them, only added a
second way to truncate), and enforcing one means killing an in-flight zone mid-run, which *creates* the
ambiguous half-written state this record exists to remove. `in_flight` records the externally-killed case
honestly instead of pretending to prevent it.

**Re-entrance (`--rehunt-gaps`, default OFF).** STAGE 1/2 are skipped; `map/zones.json`, `map/scope.tsv`,
`briefs/briefs/` and the coverage record must already exist under `--out`, else exit 3 naming the missing
artifact. The work list comes from the **record**, not the filesystem: every zone whose status is
`not_reached` / `budget_exhausted` / `in_flight` / `failed`, in priority order. Partial zones
(`hunted_degraded`, or `budget_truncated`) are excluded by default — a re-hunt would redo cells that already
produced results — and included only under `--rehunt-include-partial`. `no_brief` is **never** selected: the
missing prerequisite is not collapsed into a retryable failure. Because `failed` / `in_flight` (and an
included partial) have prior artifacts that `run-discovery.sh` destroys on re-entry (`rm -rf $RUN`,
`> $REPORT`), the runner first moves `discovery/<zid>` → `discovery/<zid>.attempt-<n>` and pushes the prior
terminal state into `attempts[]`, so the failure evidence survives and `attempts` length is the give-up input.
`--rehunt-max-attempts <N>` (default 2) leaves a zone alone once it has N attempts: one `--rehunt-gaps` pass is
exactly one pass over the gap set, never a loop. Budgets compose: `--rehunt-gaps --run-cell-budget N` re-hunts
as much of the gap set as the budget allows and records the rest as `budget_exhausted` again.

Two properties of the archive make the re-entrance safe, and both are load-bearing:

- **The suffix is the first FREE `.attempt-<n>` on disk, never a counter derived from the record.** A full
  re-sweep rewrites the record while the archives stay on disk, so a record-derived counter could point at an
  existing archive and `mv` would destroy it. Nothing in the pipeline ever deletes an archive. For the same
  reason `init` **carries `attempts[]` over** when it re-sweeps into an existing `--out`: that list is retry
  history and the `--rehunt-max-attempts` give-up input, not per-run state, so zeroing it would both un-bound
  the give-up counter and desync it from the dirs on disk.
- **The merge is a UNION ACROSS ATTEMPTS.** If archived dirs were excluded, a re-hunt that yields *less* than
  the attempt it archived would silently delete real candidates from `discovery-results.merged.json` — while
  reporting a *better* coverage verdict than the run it replaced. That is a worse failure than the one this
  issue fixes. So the merge reads every attempt of every zone and deduplicates cells by
  `(subsystem, class, files)` — and when one cell exists in several attempts their **candidate lists are
  UNIONED**, not arbitrated. Electing a single winning cell (say, the one with the most candidates) still drops
  leads: an attempt that surfaced ONE real lead would lose to a later attempt that surfaced TWO unrelated ones.
  **No candidate any attempt ever produced is discarded here** — refuting a candidate is STAGE 4's job, not the
  merge's. The dedupe key is the WHOLE candidate string precisely because it cannot collapse two genuinely
  distinct leads: only byte-identical candidates merge. The cell keeps the current attempt's other fields (its
  status is the fresher truth about this run) and only gains the archived attempts' extra candidates. Totals
  are derived from the deduplicated set (so they cannot desync from `cells[]`), and the merged file declares
  the policy plus `carried_over_cells` under its `merge` key — a count that includes cells whose content came
  only PARTLY from an archive, so a partial carry is as visible as a whole one, on stderr and in the file.
  STAGE 4/5 then run over that union.

`demo-run-zone-hunt.sh` blocks (f)–(o) pin all of it offline: the record is total and the default path inert;
a truncated run is distinguishable from a clean sweep (with a negative control reproducing the 1-of-7 shape);
a failed zone keeps its exit code; the re-hunt is targeted, unions to the clean-sweep cell total, and preserves
the prior attempt. Blocks (k)–(n) pin the four properties an adversarial review found missing — a zero-cell
zone is a gap, the union cannot lose a candidate, an unenforceable cap denies instead of mis-charging, and a
full re-sweep neither resets the give-up counter nor clobbers an archive. Block (o) pins the narrower case a
re-review then found: a later attempt that surfaces MORE (but different) leads on a cell must not drop the
earlier one. Every one of those assertions is mutation-tested — reverting its fix makes it fire — and block (k)
drives BOTH zero-cell triggers, so narrowing the guard from "zero cells ran" to "no classes in zones.json"
fails CI on the trigger that has a scope line under a rewritten name.

### Gap remediation: what a re-hunt may act on (#1828 M1)

#1830 writes the record and offers the queries; it decides nothing. #1828 adds the **decision** — and the
first thing a decision needs is a pinned answer to "which gaps is a re-hunt even allowed to touch?". That rule
already exists in `zone-coverage.py gaps`; this section states it as a contract so a consumer can rely on it.

| `status` | `gaps` action | actionable? | why |
|---|---|---|---|
| `hunted` / `hunted_empty` (untruncated) | *(absent)* | — | not a gap at all |
| `hunted` + `budget_truncated` | `retry`, only under `--include-partial` | opt-in | the zone WAS hunted; a re-hunt redoes cells that already produced results |
| `hunted_degraded` | `retry`, only under `--include-partial` | opt-in | same: partial coverage, not zero coverage |
| `not_reached` | `hunt` | yes | zero evidence, nothing to preserve |
| `budget_exhausted` | `hunt` | yes | hunt-able; the run declined to pay. Remedy: more budget, or a re-hunt |
| `budget_unenforceable` | `hunt` | yes | never ran; remedy is its full planned budget, or a re-map |
| `in_flight` | `retry` | yes | prior artifacts exist — move them aside first |
| `failed` | `retry` | yes | prior artifacts exist — move them aside first |
| *any of the above with `attempts >= --max-attempts`* | `capped` | no | leave it alone; one pass is one pass |
| `no_brief` | `no-brief` | **never** | an upstream defect; a re-hunt against the same briefs cannot fix it |
| `unscoped` | `unscoped` | **never** | an upstream MAPPING defect; a re-hunt against the same map cannot fix it |

Two properties of that table are load-bearing for anything that loops over it, and both are verified against
the shipped helper (`demo-gap-policy.sh` block 1):

- **The attempt ceiling bounds only the artifact-bearing statuses.** `attempts[]` is appended only by
  `zone-coverage.py retry`, which `run-zone-hunt.sh` calls only on the `retry` action. A zone denied on
  admission is recorded `budget_exhausted` with **no** attempt entry, so `gaps --max-attempts N` keeps
  emitting `hunt` for it at N = 1, 2, 3, 99 — forever. **Any autonomous loop over the gap set must therefore
  carry its own pass bound**; `--rehunt-max-attempts` is not one. (Measured: with the three bounds below
  removed, the `budget_unenforceable` fixture launched 129 re-hunt passes in 90 s and was still going.)
- **`summary --json`.`gap_zones` is a strict SUPERSET of the `gaps` TSV.** The partials are the difference.
  Actionability must be read from the TSV; `gap_zones` is for reporting only.

### Self-tuning breadth: the remediation loop (#1828 M2/M3)

The loop lives in a **new layer above** the capstone — `lib/gap-policy.py` (the rule) + `run-zone-sweep.sh`
(the driver). **`run-zone-hunt.sh` is not modified by #1828 at all**: it stays the single-pass, tactical
entrypoint, which is the strongest available form of default-inertness (a file that is not touched cannot
regress its golden pin). Putting the policy inside the capstone would have made a 1000-line script
self-recursive and would have folded "how much may I spend" into the loop that spends it.

**The four verbs**, evaluated in this order over the TSV (`actionable` = `hunt|retry` rows):

1. record `complete` → `give_up|nothing_actionable`.
2. re-hunt passes already done ≥ `--max-rehunt-passes` → `give_up|pass_ceiling`.
3. no actionable row → `give_up|attempt_ceiling` if anything is `capped`; else `remap_target|upstream_defect`
   if anything is `no-brief`/`unscoped`; else `give_up|partial_only` if the only gaps are partials; else
   `give_up|nothing_actionable`.
4. actionable rows exist →
   a. **no-progress guard**: the previous pass was a plain `rehunt_now` and closed nothing → the budget branch
      if there is headroom, else `give_up|no_progress`;
   b. every actionable gap is `budget_exhausted`/`budget_unenforceable` → the budget branch;
   c. **budget branch**: `--budget-ceiling` defaults to **0 = no raise permitted**, so
      `raise_budget_and_rehunt` is unreachable by default. With headroom the raise goes **straight to the
      ceiling** (so at most ONE raise per sweep is possible), carrying `zone_cell_budget=0` only when an
      actionable zone is `budget_unenforceable` — the per-zone cap is exactly what could not be expressed for
      it. Without headroom: `give_up|budget_ceiling`;
   d. otherwise `rehunt_now`.

**Three independent bounds** stop the loop, and each is pinned on its own by `demo-run-zone-sweep.sh` block
(C): the sweep's `--max-rehunt-passes` (default 2), the no-progress guard (4a), and the budget branch (4b/4c).
None of them reads `attempts[]`, because — per the finding above — `attempts[]` cannot bound the case that
matters.

**`remap_target` is a REPORTED decision, never an action.** The sweep never re-runs STAGE 1/2 by itself: a
re-map invalidates the briefs and the very record the policy is reasoning over. The same goes for re-slicing.

**Every exit path writes the report**, including the abort paths — `<out>/coverage/gap-remediation.json` (the
`gap-remediation/v1` ledger: one entry per pass with `gaps_before`/`gaps_after` and a `closed` set *derived*
from them, never asserted by the caller) and `<out>/coverage/gap-report.md`. Exit **0** only when the final
record is `complete`; exit **5** when gaps remain after the policy exhausted its options, with the report
named on stderr — an incomplete sweep is never silent. An aborted breadth pass propagates the inner exit code
and still leaves a report saying no coverage record was written.

Policy **learning** from re-hunt outcomes is deliberately out of scope (#1828 M4): the verb set is fixed and
the rule is deterministic — same record, same ledger, same verb, every time.

### M3 within-contract depth: re-reading a function a breadth cell already flagged (#1827)

Breadth surfaces roughly **one** bug per `(function × class)` and misses co-located ones. Two diagnosing
sites: on `Strategy.checkPoolActivity` the hunter found the narrow-int/DoS bug and missed the two
oracle-check bugs in the same function; on a whole target it named the right contracts and none of the five
ground-truth findings. `hunter.ag` already asks for "EVERY qualifying bug", and breadth still yields ≤ 1
candidate per cell across the corpus — so **the binding constraint is attention over a whole-zone payload,
not the output contract**. Narrow the payload and re-ask, but only where a lead already proves the function
carries attack surface.

**What a depth cell is.** A full, ordinary cell — same agent, same retry policy, same scrape — with three
differences: `IN_SCOPE` is a single `file@fn` (routed through the existing `slice-fns.sh` slicer, so the
payload is that one function plus its contract header), `DEPTH_TARGET` names it, and `DEPTH_KNOWN` quotes the
lead(s) the function already produced **verbatim** as an exclusion. The prompt then asks for a bug whose
*mechanism* differs from every excluded line, and keeps the `SAFE` escape and the trace-the-code rule intact
— the cheapest fake (re-reporting the known bug) is foreclosed by construction, and fabricating a second one
is explicitly disallowed. `hunter.ag` prints `DEPTH-CELL|<subsystem>|<class>|<file@fn>`, which
`_join_wrapped_candidates()` treats as a record **boundary** (alongside `CANDIDATE|`, `BLACKBOARD-*` and a
blank line) so it can never be glued onto an open candidate record as prose.

**Cross-lens first, same-class last.** At both diagnosing sites the co-located miss lives under a *different*
taxonomy class than the hit. So a location's lens order is: the zone's classes that did **not** produce a lead
there (in manifest order) first, then the producing one(s) last. That ordering is a *hypothesis the held-out
A/B measures*, not an assumption — the per-cell logs say which lens produced what, so it is re-tunable
without redesign.

**The plan, computed once.** After every breadth cell has run, `run-discovery.sh::_plan_depth_cells()` reads
the accumulated `results-cells.jsonl` — **not** the blackboard memo, because under `--jobs > 1` every cell's
board is empty and a memo-derived list would differ per path, while the accumulator is written in manifest
order on both. Flagged locations are ranked by (a) severity, High before Medium, (b) breadth-candidate count
descending, (c) first appearance in manifest order. Targets are computed **once, before the first depth cell
runs**, so a depth candidate can never spawn further depth cells — one pass, never a loop (the same rule
`--rehunt-gaps` follows).

**How the cap is allocated — the quota-round-robin (#1850).** The original allocation spent the cap
*breadth-first*: one class per location per pass. Measured, that never gave any location more than one or two
lenses, so the mechanism the depth pass exists for — hunting **one** function repeatedly under different
lenses — was never exercised, and #1827's held-out A/B failed on exactly that criterion. The fix is a single
integer, `--depth-lens-quota N` (`run-zone-hunt.sh --zone-depth-lens-quota`, default **1**, the #1827 spread —
reverted from an initial default of 3 after the #1850 measurement below did not support it): each location
takes **N consecutive lenses** before the plan moves to the next one, and after every location has had N the
rounds repeat (positions N+1…2N, and so on) until the cap is spent.

- **Why not "exhaust the top location"?** A location's lens list *is* the zone's class list, so per-location
  spend is already bounded by the classes the zone advertises — but full exhaustion is still strictly worse.
  On the recorded 12-cell plan that diagnosed this defect, the zone advertised 6 classes: full exhaustion
  (N = 6) hands ranks 1 and 2 six cells each and the rank-4 location — the one the acceptance criterion names
  — gets **zero**. At N = 3 ranks 1–4 get three lenses each and that location gets exactly three.
- **Why not N = 2?** It reaches more locations but gives the top ones exactly what the breadth-first spread
  already gave them, which produced nothing at the target. N = 3 is the smallest quota that clears "hunted
  under ≥ 3 distinct lenses" while still reaching rank 4 at that cap.
- **A location with fewer remaining lenses than the quota** emits all it has and the stream continues. There
  is no reserved-but-unspent quota: the plan is one ordered stream truncated at `cap`, work-conserving by
  construction.
- **N = 1 is the old allocation, byte-for-byte.** The quota-round-robin degenerates to the original
  `for pass { for location }` loop, which is why the breadth-first spread needs no second code path and why
  #1827's measured arm stays re-derivable at any later commit. `demo-discovery-parallel.sh` (13d) pins that
  sequence verbatim.
- **No adaptive stopping.** "Keep hunting this function until it stops yielding" is deliberately NOT
  implemented — letting a depth result re-plan depth would break the one-pass rule above.

The ranking, the `(location × lens)` pair multiset and the cap semantics (`min(cap, planned pairs)`) are
**unchanged** by the quota — only the emission order moves — which is what keeps the cost accounting below
exactly as it was. `totals.depth_lens_quota` records which allocation produced a given set of depth cells, so
two depth arms can never be compared without seeing that they were spent differently.

**Cells, not hidden prompts.** A depth cell is counted in `totals.cells`, appears in `cells[]` tagged
`"phase":"depth"`, and is reported in `totals.depth_cells` alongside `totals.depth_lens_quota` (both emitted
**only** when the flag is on, so a depth-off run's JSON key set is unchanged). Its
`files` field is the narrowed `file@fn`, which also keeps its `(subsystem, class, files)` merge key distinct
from the breadth cell of the same class. Sized on real numbers — a plaza `src` zone is 6 breadth cells, the
whole run 18 — a cap of 4/zone is +67 % on that zone and +22 % on the run; a cap of 12 is +200 % / +100 %.
The payload per depth cell is a single-KB function slice against an 85.8–96.6 KB whole-zone cell, but
run-discovery.sh charges *reasoning*, not payload, so a depth cell still costs one cell. Undercounting them
to look cheap is exactly the failure this design refuses.

**Interaction with the cell budget (#1830), stated rather than assumed.** Depth cells spend the same pool as
breadth cells. `run-zone-hunt.sh --zone-depth-cells N` forwards `--depth-max-cells` per zone, and the
effective allowance is `min(N, max(0, cap − planned breadth cells))` — i.e. **depth is trimmed to 0 before a
single breadth class is dropped**. Breadth coverage is the #1824/#1825/#1826 investment and is never traded
for depth. A budgeted run with depth on therefore covers fewer zones unless the operator raises the budget by
(zones-with-candidates × depth cap). Depth cells are **not** enumerable by `--list-cells` (they depend on the
breadth results), so the **cap is charged up front** — the conservative choice, matching the existing "an
unmeasurable zone is charged the whole remaining budget" precedent. A zone that finds no lead therefore shows
its cap charged and 0 depth cells spent. `cells_planned` keeps meaning "what `--list-cells` measured";
`cells_charged` becomes breadth + depth and the coverage `detail` names the split (and, when the operator set
one, the lens quota). **No new coverage status** — the state vocabulary above is untouched. The quota is an
*ordering*, never a cost: `--zone-depth-lens-quota` is forwarded only when depth is genuinely admitted, and it
never moves `cells_charged`, so the two A/B arms remain cost-comparable.

**Substrate cost.** `DEPTH_KNOWN` is consumed as **one opaque string**: never `regex_split`/`reduce`d, so the
CB cost is O(1) in the number of known leads. That is the recidivist trap here — an interpreted per-element
walk pays ~70+ CB per element and blows the enforced `cb_per_tick` ceiling. Measured by bisecting the minimum
budget at which `depth_block()` completes: **44 CB at 1, 8, 64 and 256 known leads** — flat. The sweep runs in
`demo-discovery-parallel.sh` under a `cb 2000;` probe (the *enforced* ceiling, not the declarative `cb
300000;` header the one-shot `agentis go` path uses), with the function **extracted from `hunter.ag` by line
range**, never copy-pasted — a duplicated twin would silently drift from the agent it claims to measure.

**Default OFF, and the held-out gate that could flip it.** `--depth-max-cells` / `--zone-depth-cells` ship at
`0`, and the #1850 quota does not change that: it changes how the cap is spent, not whether it is spent.
Flipping any default requires a single-variable A/B on a **held-out** target — declared before the code was
written, and deliberately not a diagnosing site, because "the hunter now surfaces 2 bugs on the function we
tuned against" is satisfiable by teaching-to-test.

The **#1827 gate** ran against plaza `src/Pool.sol::startAuction` and recorded **P2 FAIL**: the depth arm
gained seven ground-truth rows the control missed, none of them from the co-located set the criterion named.
That result refutes *depth budgeted breadth-first*; it does not test *within-contract depth*, because at a cap
of 12 over 10 flagged locations the budget never concentrated — the held-out function got exactly one extra
lens out of five available. Hence #1850, and hence a fresh gate.

The **#1850 gate** is the `notional` pricing surface — `src/AbstractYieldStrategy.sol::price` and its override
one dispatch step down, `src/single-sided-lp/AbstractSingleSidedLP.sol::convertToAssets`. Its co-located
ground-truth set is two findings that are **both rare and both High** (a donation/escrow inflation and a
context-dependent pricing fallback), whose Root Cause sections cite the same two line ranges; the mechanisms
are plainly distinct, so a single candidate cannot satisfy both. It is fresh for this defect (no notional
function appears in the plaza/crestal diagnosis), it is inside today's function slice — `price` at rank 15 of
a cap-16 slice, `convertToAssets` at rank 12 of 25, so the measurement isolates allocation from the
#1825/#1834 coverage work — and the preserved baseline run flagged neither site. Disclosure, so the held-out
claim is not overstated: notional **has** been hunted before, and `convertToAssets` is cited in `map-zones.sh`
as the motivation for the valuation-slot reservation — but that is a **coverage** inspection (is the function
in the payload at all), never a depth or allocation one.

The control is the breadth-first spread at the same cap; the treatment is the same target, same cap, same
backend/model, with `--depth-lens-quota 3`. Both arms are scored under the **same ruler** — the same judge
gate and the same GT-equivalence crediting rule, because a rare figure from one crediting rule is not
comparable to a rare figure from another. `price` sits one slot from truncation, so the slice replay must be
re-run at measurement time; if it has fallen out, the target is invalid and the run does not count.

**PASS requires all six:**

| | Criterion |
|---|---|
| P0 | **Mechanism (GT-free).** In the treatment at least one flagged location receives **≥ 3 distinct lenses** — countable as `"phase":"depth"` cells sharing one `file@fn` in `discovery-results.json` — while the control's maximum lenses-per-location at the same cap is ≤ 2. |
| P1 | The treatment surfaces **≥ 2 candidates** at one of the held-out sites, judged **mechanistically distinct from each other** (not a paraphrase pair). |
| P2 | The treatment matches **≥ 1 ground-truth row the control does not, and that new match is one of the co-located pair**. A new match anywhere else is luck elsewhere, not within-contract depth. |
| P3 | No regression: every ground-truth row the control matched is still matched by the treatment. |
| P4 | Precision floor: treatment candidate count ≤ 2× the control's, and treatment matched/total ratio ≥ 0.5× the control's. |
| P5 | Cost honesty: both arms run the same per-zone cap; in each arm `totals.depth_cells` ≤ cap and equals the observed extra, and each scored artifact records `totals.depth_lens_quota`. |

**Pre-committed consequences.** P0 failing is an *implementation* defect, not a result — fix and re-run,
nothing is recorded as a measurement. P0 holding while P3 fails **refutes** the concentrated allocation: the
default quota reverts to `1`, the flag stays, and the negative is recorded. P0 and P3 holding while P2 fails
means concentration did not buy co-located rare recall on a fresh target: depth stays OFF and the default
quota stays 3 only if the treatment's total ground-truth matches ≥ the control's, otherwise it reverts to 1 —
the next lever is then the widened depth slice or the location ranking, each its own issue, never a quiet
retune here. All six holding settles the *allocation* question only; flipping `--zone-depth-cells` off `0`
remains a separate decision, since it doubles cells. A measured non-result is a result.

Re-running the diagnosing site (plaza at cap 12 with `--depth-lens-quota 3`) is reported as a confirmatory
diagnostic and **licenses nothing on its own** — breadth is stochastic, so a miss there is a ranking
observation, not an allocation failure.

`demo-discovery-parallel.sh` blocks (11)–(17) and `demo-run-zone-hunt.sh` blocks (p)–(t) pin all of the
mechanics offline: default-inertness down to the byte-identical golden report and an argv carrying no new
argument; the env wiring (including the `exec.env_passthrough` registration, without which `getenv()` is
silently inert); the ranked quota-round-robin order; the `--depth-lens-quota 1` compatibility pin; one
function hunted under three distinct lenses at cap 3 on a 4-class zone (the offline analogue of P0), with the
quota-1 arm as its control; zero cost when no lead was found; determinism and serial/parallel identity; the
`DEPTH-CELL|` record boundary; depth being trimmed before breadth under a budget; and the CB sweep. Each is
mutation-tested — reverting its fix makes it fire.

### Depth-only re-entry: measuring an allocation without re-hunting breadth (#1857)

Every depth A/B above shares one confound: both arms re-run the **stochastic** breadth pass, so a row the
treatment lost may have been lost by breadth variance rather than by the allocation. That is exactly why
#1850's four lost mid/consensus rows were unattributable and why the default reverted to `1`. Fixing the
breadth sample is therefore a prerequisite for the measurement, not a convenience.

`run-discovery.sh --depth-from <discovery-results.json>` consumes a **recorded** run, seeds the cell
accumulator with that run's **breadth** cells and falls straight into the unmodified depth block above.
`_plan_depth_cells()`, `run_cell()` and `scrape_cell_log()` are reused verbatim, so the plan a re-entry
computes **is** the plan the original run computed — `demo-depth-reentry.sh` (1)/(2) pin that against both
recorded plaza arms' own `depth-plan.tsv`. Two re-entries differing only in `--depth-lens-quota` then differ
only in the allocation.

**What it consumes, and why not the other file.** The input is `discovery-results.json`, never the raw
`run/results-cells.jsonl`: the JSONL carries no provenance at all (no repo, no totals, no backend), so none
of the refusals below would be possible. The recorded **breadth** cells are carried into `cells[]`
byte-for-byte, so a depth-only arm is a drop-in for `verify-findings.sh --results` → `score-match.py` and is
scored on breadth+depth exactly like a full run.

**Depth cells are filtered out of the seed, and that is correctness, not hygiene.** A depth candidate fed
back into the accumulator changes `loc_count` / `loc_sev` / `loc_prod`, which moves both the location ranking
and the per-location lens order. Replaying the quota-3 arm *unfiltered* yields extra `C17`/`C5` lenses and
promotes `startAuction` above `transferReserveToAuction` — a different experiment wearing the same name.

**Refusal matrix.**

| Situation | Exit | Why |
|---|---|---|
| `--depth-from` with `--list-cells` / `--only` / `--classes` / `--scope` | 2 | none can affect a plan derived from recorded cells — the zone class order comes from those cells' own `class` fields, not from a manifest, so accepting them would be a silent lie |
| `--depth-from` without `--depth-max-cells > 0` | 2 | a depth-only run with no depth budget is a no-op that would still write an output dir |
| missing input file / no `python3` | 2 / 3 | the operator's argv vs. an unmet dependency |
| recorded `repo` ≠ `basename --repo` | 3 | the artifact belongs to another target |
| recorded `commit` present and ≠ current HEAD | 3 | the checkout moved under the recording |
| a depth target the checkout no longer carries | 3 | the one guard that reaches the working tree |
| the input records **0** breadth cells | 3 | nothing to plan a depth pass from |

Exit **2** = the operator typed something that cannot be honoured; exit **3** = the artifact does not match
this target (the #1840 fail-closed precedent). Every artifact-only refusal fires **before** the output dir
exists, so a refused re-entry leaves nothing behind.

**What the guard cannot detect — stated, not papered over.** Every run now records `commit` (a *soft* git
dependency: a non-git target degrades to `"unknown"` and never fails), so from this change onward a stale
checkout is refused. It buys nothing for artifacts recorded **before** it, which is every artifact that
exists today including both plaza arms: such a re-entry prints
`the input records no commit; re-entry provenance is UNVERIFIED` and runs. It also cannot detect a **dirty
working tree** (`rev-parse` is identical with uncommitted edits — it pins the commit, not the content), two
different repos cloned into identically-named directories, or a changed `scope.tsv` (deliberately: the plan
never reads the manifest, which is why `--scope` is refused rather than validated). **Re-entering against the
checkout that produced the input is the operator's responsibility**; `depth_from.commit` puts that on the
record. No guard here implies a check it does not make.

**The A/B recipe.** One breadth run, then two re-entries:

```sh
# 1. one breadth pass — this is the sample both arms will share
run-discovery.sh --repo <target> --scope <scope.tsv> --brief <brief.md> --out breadth-out

# 2. two arms over that ONE sample, differing only in the allocation
run-discovery.sh --repo <target> --brief <brief.md> --out arm-q1 \
  --depth-from breadth-out/discovery-results.json --depth-max-cells 12 --depth-lens-quota 1
run-discovery.sh --repo <target> --brief <brief.md> --out arm-q3 \
  --depth-from breadth-out/discovery-results.json --depth-max-cells 12 --depth-lens-quota 3
```

Both arms carry the identical breadth rows into `cells[]`, so they are scored under the same ruler and the
difference between them is the allocation. `depth_from` in each output records the source, its repo and
commit, and the carried counts.

**Out of scope, deliberately:** no `run-zone-hunt.sh` capstone flag (the primitive is driven directly until
one real A/B has used it), no re-hunting of breadth under `--depth-from` (the input is authoritative and
read-only — there is no partial or top-up mode), and no re-deciding the `--depth-lens-quota` default: this
builds the instrument, #1827's measurement moves the default.

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

## The integration-seam / composability lens (C15, #1644)

The `(subsystem × class)` map treats every bug class as one lens among equals. But one lens recurred on
recent hunts often enough to formalize as a first-class class: the **integration seam** — the boundary where
the target's own code calls INTO a *second* protocol (an adapter, a guard, an oracle read, a router wrapper).
That boundary is under-audited by construction: protocol A's auditors trust B, and B's auditors never see A's
integration code, so nobody owns the seam. `C15 — Integration-seam / composability` in
[`auditor/bug-taxonomy.md`](../auditor/bug-taxonomy.md) makes it a real class the map can pick and the brief
can deepen. It ships as THREE additive pieces over the existing machinery — no new agent:

1. **The C15 taxonomy class** — the `hits/hunt/breaks/sev/seen` entry encoding the six heuristics below.
2. **A prompt-only zone-mapper detection rule** — `zone-mapper.ag` includes `C15` in a zone's class list when
   the zone's contracts are named `*Adapter`/`*Guard`/`*Bridge`/`*Oracle`/`*Wrapper`/`*Router`/`*Strategy`,
   OR they import/call an external protocol's interface. It is a *prompt* rule, not a shell regex: an
   import-based integration with a plain contract name (no suffix) is still the seam, and the LLM reasons over
   that where a filename grep would miss it. No new `exec sh`/builtin logic (substrate-pure by construction).
3. **A conditional brief-writer `seamClause`** — `brief-writer.ag` mirrors its existing
   `residualClause`/`boundaryClause` additive pattern: when the zone's class list carries the comma-bounded
   token `,C15,` it appends a dedicated "Integration-seam hunt guide" subsection (the six heuristics as a hunt
   guide, sourced from the C15 taxonomy section that already flows into the class lens); when `C15` is ABSENT
   the clause is the EMPTY STRING, so the brief for a non-integration zone is **byte-identical** to today.

### The six heuristics

1. **Asset/balance mis-accounting across the integration** — does the value an adapter *reports* match the
   assets actually *held* after the external call round-trips? A mispriced share/pool-token is theft. This is
   the top seam: the ERC4626 share-price-vs-real-assets invariant across the integration boundary.
2. **The under-audited tail** — new/exotic/recently-added adapters are the tail nobody re-reviewed; the
   widely-forked mainline is picked over. Prioritise the recently-added ones.
3. **Find the global value-conservation backstop FIRST** — a protocol-wide withdraw-invariant + an
   operation-type lock + a cumulative-slippage cap degrades a single-adapter bug to a REVERT, not a drain.
   The lens pays off where per-adapter correctness is the ONLY barrier, or where the integration code is FRESH.
4. **Cross-integration composition** — flashloan via adapter A → manipulate a position priced by adapter B →
   extract; two adapters composing into a state single-adapter checks miss. Check for an op-type lock.
5. **Scope discipline** — attack the TARGET's OWN integration code (adapter/guard/wrapper/oracle-read), NOT
   the integrated protocol. "The integrated protocol misbehaves" is usually out-of-scope-by-trust; payable =
   theft/freezing of the target's users via its own integration logic.
6. **Freshness synergy** — the lens is an AMPLIFIER on fresh integration-heavy targets (oracle-integrated
   AMMs, ERC4626 adapter vaults, multi-adapter pool managers), not a way to crack a mature hardened one —
   there a single-adapter bug expects a revert, not a drain. Freshness × seam is where the lens earns its keep.

`demo-seam-lens.sh` pins the whole lens offline over a dedicated `fixtures/seam-lens/` tree (integration
contracts + a plain-token negative control): the C15 tag round-trips into `scope.tsv` only on integration
zones, the C15 briefs carry the six-heuristic hunt guide, the plain zone stays seam-free (the no-C15
byte-clean control), plus the taxonomy/zone-mapper/brief-writer source guards. It touches NONE of the shared
`fixtures/zone-map/` tree, so `demo-map-zones.sh` / `demo-gen-briefs.sh` stay byte-identical.

## The M1..M5 map

| Milestone | Scope |
|-----------|-------|
| **M1 (#1612)** | zone mapping: `map-zones.sh` + `zone-mapper.ag` → `zones.json` + `scope.tsv`; the `--list-cells` round-trip. |
| **M2 (#1619)** | per-zone brief generation: `gen-briefs.sh` + `brief-writer.ag` → `brief_<zone>.md`, fed to `run-discovery.sh --brief`. |
| **M3 (#1625)** | parallel fan-out: `run-discovery.sh --jobs N` bounded-concurrency over the `(subsystem × class)` cells + isolated per-cell stores + a hard cap + deterministic aggregation. |
| **M4 (#1630)** | verify integration: `verify-findings.sh` routes each surfaced lead into the refute (default) / poc / symbolic gate → CONFIRMED-only `verified_findings.json` (read-only over the M3 output). |
| **M5 (#1630)** | gate + deliver — the capstone: `run-zone-hunt.sh` chains map→brief→per-zone discovery→merge→verify→run-audit-pass→deliver-submission and HALTS every finding at `PENDING-HUMAN-REVIEW` (never submits). **Closes epic #1611.** |

## Four honest caveats

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
4. **The seam lens is triage/focus machinery, not depth (C15, #1644).** The C15 class + the zone-mapper
   detection rule + the brief `seamClause` improve where the hunt *looks* — they route integration zones to
   the seam heuristics and prime the brief. But the DEPTH of any actual seam hunt (does a specific adapter
   mis-account? is the global backstop truly absent?) stays LLM-backend-gated, exactly like caveat #1: the
   demo proves the lens wiring + the six-heuristic content + the byte-identical no-C15 path, never live hunt
   quality. Freshness × seam is where it pays off; on a mature hardened multi-adapter manager expect reverts.
