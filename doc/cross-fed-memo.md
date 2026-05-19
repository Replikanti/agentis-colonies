# Cross-federation memo reference

`cross-fed:*` is a shared memo namespace readable + writable by every
federation running on the same host. A method that proves productive
in one federation (clears its replicate threshold AND an export-fitness
gate) can publish itself into this channel; a separate federation that
has been marked as `applicable-to` can then adopt the same method at
bootstrap and verify-or-discard it under its own fitness signal.

The channel is a thin file-per-key bridge on top of the existing
per-federation memo stores: each federation writes to its own
`.agentis/memo/cross-fed:*` keys, a sidecar mirrors those keys to a
host-level shared directory, and the same sidecar mirrors keys from
the shared directory back into every other federation's memo store.
Federations never read each other's memo stores directly. See the
Storage section below.

This document is the reference for the namespace conventions, key
shapes, export/import rules, fitness gates, applicable-to curation,
and the host-dir layout. It does not cover the agent-side code that
emits or consumes the keys — that lives in PR-2 (export from
research-foundry) and PR-3 (target-fed import scaffold) of
[#629](https://github.com/Replikanti/agentis-colonies/issues/629).

## Scope

- **Included:** the `cross-fed:*` key namespace, the method-record JSON
  shape, export rules, import rules, applicable-to curation, fitness
  gates, and the host-dir layout consumed by
  `tools/cross-fed-bridge.sh`.
- **Excluded:** how a federation produces a method (PR-2: export from
  research-foundry's `_publish_<role>` autonomous-tier paths), how a
  federation consumes one (PR-3: target-fed import + test scaffold),
  and the cooperative search loop that closes the feedback loop (PR-4).

## When the bridge fires

The sidecar is a long-running loop spawned alongside (but separate
from) a federation. On each tick (default 60s) it does two passes:

1. **memo -> host.** Read every `cross-fed:*` key from
   `<fed_dir>/.agentis/memo/` and mirror each key into a file under
   `<host_dir>/`, content-addressed to skip no-op writes.
2. **host -> memo.** Read every file under `<host_dir>/` and mirror
   each one back into the federation's `.agentis/memo/cross-fed:*`
   keys.

The two passes run under a single host-level `flock` so only one
sidecar instance touches the shared dir at a time. With multiple
federations on one host each federation runs its own sidecar; the
first to acquire the lock wins the tick, the others log
`lock held by other process; no-op` and exit 0. The next tick will
retry.

## Key shapes

All keys are flat `cross-fed:<kind>:<...>` strings. The `<source-fed>`
component is the federation's directory name as it appears under
`<repo-root>/`. The `<method-id>` component is a short content-derived
identifier (the `body_sha` first 16 hex chars in PR-2's exporter).

### `cross-fed:method:<source-fed>:<method-id>`

The productive-method record itself, as JSON. Carries every field the
target federation needs to decide whether to adopt and, after adopting,
to verify under its own fitness signal. Example:

```json
{
  "id": "a1b2c3d4e5f60718",
  "source_fed": "research-foundry",
  "source_agent": "explorer",
  "source_pid": 1042,
  "source_tick": 5731,
  "specialty": "group_theory",
  "variant": "character-table-sieve",
  "verdict_chain": ["formulator:novel", "verifier:verified_new"],
  "fitness_at_export": 0.82,
  "body_sha": "a1b2c3d4e5f60718...",
  "abstract": "Sieve conjugacy classes by character-degree gcd to surface sporadic-vs-classical anomalies.",
  "created_at": 1747584000
}
```

### `cross-fed:method-body:<source-fed>:<method-id>`

The raw prompt body, content-addressed. Split from the record so the
record stays cheap to scan and the body can be fetched on demand. The
bridge mirrors both as separate files.

### `cross-fed:fitness:<source-fed>:<method-id>`

Fitness scalar at export time, as a JSON number (e.g. `0.82`). Stored
separately so a future curation tool can re-scan all exported methods
and prune the floor without rewriting the method record.

### `cross-fed:applicable-to:<method-id>`

JSON array of federation names the method is eligible to be adopted
into. Operator-edited at MVP; future PRs may derive it from a
similarity score across federation specialties.

```json
["trading-binance", "tribes-bench"]
```

A method whose `applicable-to` array does NOT contain the target
federation's name is **not** imported by that federation's adoption
loop.

### `cross-fed:import-log:<target-fed>:<method-id>`

Adoption record written by the target federation when it first picks
up the method. JSON with timestamp + the adopter agent's pid:

```json
{
  "imported_at": 1747600000,
  "target_fed": "trading-binance",
  "adopter_pid": 4096,
  "adopter_agent": "strategy_explorer"
}
```

PR-3 wires this; PR-1 only sets up the storage.

## Method record JSON shape

The `cross-fed:method:*` record carries:

| Field | Type | Source |
|---|---|---|
| `id` | string | first 16 hex chars of `body_sha` |
| `source_fed` | string | federation directory name |
| `source_agent` | string | `.ag` file basename without extension |
| `source_pid` | int | daemon pid that produced the method |
| `source_tick` | int | daemon tick at export time |
| `specialty` | string | producing agent's specialty (`group_theory`, `combinatorics`, …) |
| `variant` | string | short label distinguishing variants of the same specialty |
| `verdict_chain` | array of strings | ordered verdict trail (`formulator:novel`, `verifier:verified_new`) |
| `fitness_at_export` | float | fitness score at the moment of export |
| `body_sha` | string | sha256 of `cross-fed:method-body:…` payload, 64 hex chars |
| `abstract` | string | one-sentence operator-facing description |
| `created_at` | int | unix-seconds export timestamp |

## Export rules

A method becomes exportable when **both** gates fire:

1. **Verdict gate.** The method's `verdict_chain` advances from
   `NOVEL` to `VERIFIED_NEW` (or the federation's equivalent
   accept-verdict for novel productive output). This is the same
   gate that controls the source federation's internal replicate
   path.
2. **Fitness gate.** The method's producer agent's `fitness_score` at
   the moment the accept verdict fires meets the federation's
   `export_fitness_threshold`. The threshold MUST be **>= the
   replicate threshold** — see _Fitness gates_ below.

When both fire, the source federation's `_publish_<role>`
autonomous-tier path writes the four `cross-fed:*` keys above to its
own memo store. The bridge sidecar picks them up on the next tick and
mirrors them into the host dir.

Operator override: writing a `cross-fed:export-suppress:<method-id>`
key blocks an export retroactively. The bridge leaves any already-
mirrored copy in place but does not re-publish the keys if they are
deleted from the host dir.

## Import rules

At target-federation bootstrap (PR-3 wires this; PR-1 only specifies
the contract), the target federation's adoption loop:

1. Lists every `cross-fed:method:*` key in its own memo store
   (mirrored by the bridge from the host dir).
2. Filters to records whose `cross-fed:applicable-to:<method-id>`
   array contains the target federation's directory name.
3. For each remaining record, fetches the `cross-fed:method-body:*`
   key, hands the body to a fresh adopter agent on its first tick,
   and writes a `cross-fed:import-log:<target-fed>:<method-id>` record.
4. The adopter agent runs the method under the target federation's
   own fitness signal. The signal is local; PR-1 makes no claim
   about cross-federation fitness equivalence.

First-tick adoption is intentional: the target federation's adopter
must verify or discard the imported method before its own
`evolve`/`auto-evolve` loop can prune the genealogy. Letting it sit
in memo unverified would create stale `cross-fed:import-log:*` rows
the operator has no easy way to age out.

## Applicable-to curation

MVP (PR-1, PR-2, PR-3) keeps `cross-fed:applicable-to:*` operator-
edited. The bridge sidecar mirrors whatever value the operator
writes; no automated curation runs against it.

A federation that wants to opt out of being a target writes
`cross-fed:opt-out: true` to its own memo at bootstrap; PR-3's
import scaffold respects the flag.

Future work (post-PR-4): derive `applicable-to` from a per-method
specialty similarity score against each federation's declared
specialties. The MVP shape lets that scoring service write the same
key without changing the bridge contract.

## Fitness gates

Two scalar thresholds govern the cross-federation publish path:

- **`replicate_threshold`** — the source federation's internal
  threshold above which a method's producer agent replicates inside
  the same federation (existing behaviour, unchanged).
- **`export_fitness_threshold`** — the threshold above which the same
  method publishes to the cross-federation channel. **Must be
  `>= replicate_threshold`.**

The ordering invariant matters: a method that is not productive
enough to replicate inside its own federation is, by definition, not
productive enough to publish to others. Inverting the relationship
would publish methods the source federation does not itself trust.

Both thresholds live in the source federation's
auto-promote / auto-evolve config (PR-2 wires the exporter; PR-1 only
specifies that the relationship MUST hold).

## Write-conflict policy

**Shared-key writes** — `cross-fed:applicable-to:<method-id>`,
`cross-fed:export-suppress:<method-id>`, and any future operator-curated
key that is not scoped to a single federation: **Last-Writer-Wins by
mtime**. The bridge already runs sha256-by-content dedupe on each pass;
when two federations write divergent content for the same shared key,
the most recent host-side mtime wins on the next memo-to-memo
round-trip. Operators reconciling intentional divergence must serialise
edits — the bridge does not arbitrate semantic conflicts.

**Per-fed-owned keys** — `cross-fed:method:<source-fed>:…`,
`cross-fed:method-body:<source-fed>:…`,
`cross-fed:fitness:<source-fed>:…`,
`cross-fed:import-log:<target-fed>:…`: no conflict by design. The path
embeds `<source-fed>` or `<target-fed>`, so no two federations ever
target the same host file. A federation that writes outside its own
namespace is misbehaving and the operator should treat such writes as a
trust violation per the threat-model section below.

The remaining cross-fed kinds also fall under the per-fed-owned rule —
`cross-fed:opt-out:<fed>` (each federation opts itself out; the `<fed>`
segment scopes ownership) and
`cross-fed:adopt-queue:<target-fed>:<method-id>` (queued at the target
federation's bootstrap; the `<target-fed>` segment scopes ownership).
Both are per-fed by construction, so no two federations target the same
host file and no conflict-policy arbitration is required.

## Host dir layout

The shared dir lives at `<repo-root>/cross-fed-memo/`. The bridge
mirrors one file per memo key, with the colons in the key replaced
by path separators:

```
cross-fed-memo/
  .lock                       # flock(2) target for the sidecar
  pollination-ledger.jsonl    # merged from per-fed ledgers (see below)
  method/
    <source-fed>/
      <method-id>.json        # cross-fed:method:<source-fed>:<method-id>
  method-body/
    <source-fed>/
      <method-id>.txt         # cross-fed:method-body:<source-fed>:<method-id>
  fitness/
    <source-fed>/
      <method-id>.json        # cross-fed:fitness:<source-fed>:<method-id>
  applicable-to/
    <method-id>.json          # cross-fed:applicable-to:<method-id>
  import-log/
    <target-fed>/
      <method-id>.json        # cross-fed:import-log:<target-fed>:<method-id>
```

Only `.gitkeep` is tracked in git. Every other path is regenerated by
the bridge from per-federation memo content. **Never commit
`cross-fed:*` payloads.** The host dir is host-local state, not source
code.

### Pollination ledger

Each federation that exports a method also appends a row to its own
`<fed_dir>/.agentis/pollination-ledger.jsonl` (one JSON object per
line). The bridge's `merge-ledgers` command concatenates every
per-fed ledger into the central `<host_dir>/pollination-ledger.jsonl`,
preserving timestamp order. The central ledger is the audit trail
the operator scans to see which federation published which method
when.

`pollination_ledger_merge` preserves every row from every source
verbatim, sorted by `ts` then read-order. Two federations appending
identical-timestamp rows produce two adjacent rows — this is
intentional: the ledger is an audit log, not a set. Operators wanting a
deduplicated view should post-process with
`jq -s 'unique_by(.ts,.fed,.method_id)'` (or an equivalent
projection); the bridge does not collapse rows on the operator's
behalf because the choice of dedup key is policy-dependent.

## Threat model

The `cross-fed:*` namespace is a *trusted-host, untrusted-fed* surface.
All federations on the same host share `<repo-root>/cross-fed-memo/`
through the bridge sidecar; any federation can read every other
federation's exported method record + body + fitness scalar.

Assumed threats:

1. **Malicious cross-fed write.** A compromised federation A writes a
   method record claiming a fitness score of `999.0` so the operator
   prioritises adopting it into federation B. *Mitigation:* the operator
   curates `cross-fed:applicable-to:<method-id>` before any adoption.
   The bridge does not authorise on fitness alone; the export-fitness
   threshold is a pre-filter, not a trust signal. PR-2/3 will add
   `cross-fed:export-suppress:<method-id>` as an operator-only,
   federation-agnostic blocklist entry. Last-Writer-Wins by mtime per
   the conflict-policy section; operators reconciling intentional
   divergence must serialise edits.

2. **External tampering of `<repo-root>/cross-fed-memo/`.** A process
   outside any federation rewrites a method body file between two
   sidecar ticks. *Mitigation:* sha256-by-content dedupe causes the
   bridge to overwrite the federation's `.agentis/memo/cross-fed:*` on
   the next tick if the host file changes, but the federation's own
   memo store treats the new content as just another remote method.
   The operator-curated `applicable-to` gate is the last line of
   defence. This is the same trust model as any
   `<fed_dir>/.agentis/memo/*` file, since both are operator-writable.

3. **Out-of-band federation that bypasses the bridge.** Any process
   with write access to a federation's `.agentis/memo/cross-fed:*` keys
   can plant a method without going through `pollination-ledger.jsonl`.
   *Mitigation:* the central ledger only captures bridge-mediated
   activity; out-of-band entries are visible in per-fed memo dumps but
   not in the audit trail. Recommend operator audits by `diff`ing
   `<host_dir>/methods/*` against per-fed memo dumps when paranoid.

4. **Export-fitness threshold spoofing.** A method's
   `cross-fed:fitness:<source-fed>:<method-id>` is written by the
   federation that owns it; nothing cryptographically binds the score
   to actual measured fitness. *Mitigation:* the operator sees the
   source federation in the key. Future hardening (out of Phase 8
   scope) could anchor scores to a signed `replication-ledger.jsonl`
   entry.

Not threats:

- **Method body executes during import.** Import is operator-mediated;
  no automatic execution path. The `.ag` file lands in the target
  federation's colony only after the operator approves.
- **Cross-fed write storms.** Bridge holds a flock on
  `<host_dir>/.lock`; only one sidecar tick runs at a time across
  *all* federations.

Out of Phase 8 scope (track separately):

- Cryptographic signing of method bodies + fitness scores.
- Operator audit log of `applicable-to` curation decisions.
- Per-fed network segmentation (cross-fed is single-host only).

## Related

- [#629](https://github.com/Replikanti/agentis-colonies/issues/629) —
  Phase 8 design issue (cooperative inter-federation search).
- `tools/cross-fed-bridge.sh` — the bridge sidecar entry point.
- `tools/cross-fed-bridge.py` — the Python helper that does the
  actual file/key sync.
- `tools/test-cross-fed-bridge.sh` — smoke tests.
- [`doc/auto-promote.md`](./auto-promote.md) — adjacent reference for
  the internal replicate path that this channel layers on top of.
