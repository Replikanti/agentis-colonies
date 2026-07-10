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

## The M1..M5 map

| Milestone | Scope |
|-----------|-------|
| **M1 (#1612)** | zone mapping: `map-zones.sh` + `zone-mapper.ag` → `zones.json` + `scope.tsv`; the `--list-cells` round-trip. |
| **M2 (#1619)** | per-zone brief generation: `gen-briefs.sh` + `brief-writer.ag` → `brief_<zone>.md`, fed to `run-discovery.sh --brief`. **(this)** |
| M3 | parallel fan-out across zones + a concurrency cap + result collection. |
| M4 | verify integration — route each surfaced lead into the forge/Halmos gate. |
| M5 | gate + deliver — the human-gated packaging capstone. |

## Three honest caveats

1. **Classification AND brief depth are LLM-backend-gated.** `zone-mapper.ag` and `brief-writer.ag` reason
   only as well as the backend behind `prompt()`; a `mock` run does not reason (the demos assert execution and
   format, never a specific class or a specific invariant). M2 ships the MACHINERY — the deterministic
   scaffold + substrate authoring + a fixture-proven format that round-trips into `hunter.ag` — but the LIVE
   brief quality (the decisive depth lever) is only as good as that backend and is a research risk measured
   against the manual baselines, not something the plumbing can guarantee. `--fixture` stubs the output for
   deterministic, offline CI; it proves wiring + format, never live quality.
2. **M3 needs a concurrency cap.** Fanning `zone-mapper.ag` / the hunt across many zones without a cap
   would bunch `prompt()` sessions; M3 owns that. M1 runs zones sequentially.
3. **READ-ONLY, NEVER-SUBMIT.** `map-zones.sh` touches no network and has no submission path. Surfacing a
   starting manifest is the whole job; verification and any submission stay separate, human-gated actions.
