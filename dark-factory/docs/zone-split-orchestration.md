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

## The M1..M5 map

| Milestone | Scope |
|-----------|-------|
| **M1 (#1612)** | zone mapping: `map-zones.sh` + `zone-mapper.ag` → `zones.json` + `scope.tsv`; the `--list-cells` round-trip. **(this)** |
| M2 | per-zone brief generation (invariants-to-break / known-issues) feeding `run-discovery.sh --brief`. |
| M3 | parallel fan-out across zones + a concurrency cap + result collection. |
| M4 | verify integration — route each surfaced lead into the forge/Halmos gate. |
| M5 | gate + deliver — the human-gated packaging capstone. |

## Three honest caveats

1. **Classification depth is LLM-backend-gated.** `zone-mapper.ag` reasons only as well as the backend
   behind `prompt()`; a `mock` run does not reason (the demo asserts execution, never a specific class).
   `--fixture` stubs the output for deterministic, offline CI.
2. **M3 needs a concurrency cap.** Fanning `zone-mapper.ag` / the hunt across many zones without a cap
   would bunch `prompt()` sessions; M3 owns that. M1 runs zones sequentially.
3. **READ-ONLY, NEVER-SUBMIT.** `map-zones.sh` touches no network and has no submission path. Surfacing a
   starting manifest is the whole job; verification and any submission stay separate, human-gated actions.
