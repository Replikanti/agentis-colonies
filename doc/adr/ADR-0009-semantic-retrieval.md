---
id: ADR-0009
title: Semantic retrieval (RAG) for Agentis — where the index lives and how it is built
status: Proposed
date: 2026-07-02
accepted-date:
authors: [ylohnitram]
supersedes: (none)
superseded-by: (none)
tags: [rag, retrieval, knowledge-base, exec-sh, substrate, embeddings]
---

# ADR-0009: Semantic retrieval (RAG) for Agentis — where the index lives and how it is built

## Context

Every retrieval path an Agentis agent has today is **exact-key
lookup**. There is no way to ask "find the *k* things most similar to
this" — only "give me the thing under exactly this key". Concretely,
across `agentis-core`:

- **Crystallizer.** `KnowledgeCrystallizer::lookup(action_type, ctx)`
  (`src/experience/knowledge.rs:3123`) is a `HashMap::get(action_type)`
  followed by a prefix test — `matches_context`
  (`src/experience/knowledge.rs:2497`) is literally
  `ctx.starts_with(cond) || cond.starts_with(ctx)`. A near-duplicate
  context with reordered keywords misses the rule.
- **Knowledge market.** `knowledge_buy(topic)` resolves through
  `query_by_tags(&[topic], 1)` (`src/evaluator/mod.rs:9622` →
  `src/experience/knowledge.rs:439`), an exact `by_tag.get(topic)`
  hash hit. `topic` must equal a stored tag verbatim.
- **Content-addressed DAG.** `ObjectStore::save_raw`/`load_raw`
  (`src/storage.rs:88`/`:106`) are keyed on SHA-256. Retrieval
  requires you already know the hash. This is deduplication and
  tamper-evidence, not search.
- **No similarity code exists.** A repo-wide grep for
  `embedding|vector|cosine|faiss|hnsw|semantic_search` returns only
  incidental hits (string-"embedding", Euclidean-gcd). There is no
  vector store, no similarity metric, no ANN index, and the `llm.rs`
  backends are completion-only — there is no embeddings call anywhere.

The gap shows up sharply in the `dev-apprenticeship` (coding)
federation, whose 21 agents share one retrieval model:

- `recommend(topic, dims)` is **topic-exact and agent-global** —
  every agent pulls back *all* its own prior `learn()` rows for one
  hard-coded topic string (`route`, `label`, `risk_assessment`, …)
  and stuffs the undifferentiated blob into `prompt()`. There is no
  "prior decisions similar to *this* issue".
- The crystallizer pilot in `triage/labeler.ag` and `triage/router.ag`
  is prefix-exact by design — the rule id must be byte-identical
  across repeats (`labeler.ag:794`, comments at `:844-860`), so
  fuzziness is deliberately avoided and near-duplicates fall back to
  `prompt()`.
- Decision context is almost always fetched via `forge-api.sh` and
  **dumped as raw JSON into `prompt()`** (`router.ag:686`,
  `labeler.ag:839`, `code_writer.ag:947`) rather than retrieved
  structurally. The LLM is left to find relevance inside the prompt.

Every routing / labeling / prioritizing / risk / scope / review
decision would benefit from "find the *k* most semantically similar
prior issues / MRs / decisions", and every one instead matches an
exact key or dumps a blob.

This ADR does **not** decide whether to build RAG. It decides the two
things that block any build: **which layer owns the retrieval
primitive**, and **how the similarity signal is produced** (lexical
vs. embeddings). The concrete implementation is deferred until this is
accepted.

## Decision drivers

1. **Self-contained substrate.** The v1.18.x line is a sustained
   campaign to delete `exec sh` (getenv, now_ms, sha256_hex, parse_toml,
   … ~99% reduction) and pull capabilities into hand-rolled,
   dependency-free Rust primitives (`src/toml_minimal.rs`,
   `src/smtp.rs`, `src/tar_gz.rs`). Any retrieval solution that
   requires a federation to shell out to an external vector DB fights
   this trajectory directly.
2. **Anthropic ships no embeddings API.** The default backends are
   `claude` / `flat-cyborg`, both completion-only. "True" vector RAG
   therefore requires pulling in an external embedding model (Voyage —
   Anthropic's own recommendation — or the existing `openai` / `gemini`
   backends, which do expose embeddings endpoints) plus a new trait
   method on `llm.rs` that does not exist today.
3. **Replay determinism.** `agentis replay` (`src/replay/`) re-scores a
   candidate `.ag` against historical experience with all side effects
   suppressed. A retrieval primitive that is a pure local computation
   is replay-faithful for free; one that makes a network call at query
   time is not, and must be gated through the `ReplayBackend`
   machinery like `prompt()`.
4. **Tamper-evidence.** The action-audit chain (ADR-referenced #584)
   and the content-addressed DAG are the integrity substrate. A
   retrieval index is a **derived cache** — rebuildable from the DAG
   and the experience log — so it need not enter the tamper-evident
   chain, but the decision must state that explicitly so nobody treats
   the index as a source of truth.
5. **CB honesty.** Every builtin's cost must be defensible under
   `check-cb-costs.sh`. A local BM25 scan and a network embedding call
   are two different cost bands; conflating them would mislead
   operators tuning `daemon.cb_per_tick`.
6. **Federation portability (ADR-0003).** Whatever ships must be a
   substrate capability every federation inherits, not a
   `dev-apprenticeship`-only script.

## Decision

**Own the retrieval primitive in the substrate (`agentis-core`), as a
new read-only `knowledge_search(query, k) -> list<string>` evaluator
builtin, with the similarity index living beside `by_tag` /
`action_index` in `KnowledgeBase` (`src/experience/knowledge.rs`).
Federations consume it; none of them ship their own retrieval engine.**

The DAG / `ObjectStore` is explicitly the **wrong** layer — it is
hash-addressed by design and has no room for approximate retrieval.

The similarity signal is produced in **two staged variants**, and this
ADR recommends starting with the lexical one:

- **Phase 1 (recommended first): lexical BM25/TF-IDF.** Hand-rolled in
  Rust beside the existing indices. No embedding model, no network, no
  new crate. Fully deterministic (replay-safe). Covers the dominant
  "find similar prior issue / rule / decision" need where vocabulary
  overlaps.
- **Phase 2 (only if Phase 1's recall proves insufficient): embeddings.**
  A vector index plus a new `embed()` method on the `llm.rs` backend
  trait, sourced from Voyage / OpenAI / Gemini. Adds recall on
  paraphrase and synonymy at the cost of a network dependency and
  replay gating.

**Scope boundary.** `knowledge_search` can only search what is *in* the
`KnowledgeBase` (crystallizer rules, knowledge entries, experience
rows). The coding federation's highest-value corpus — past issues and
MRs — is today fetched live from the forge and never persisted into the
KB. Making those searchable is a **separate federation-side ingestion
step** (via `learn()` / `knowledge_sell` or a dedicated ingest path)
and is out of scope for the substrate primitive. Phase 1 ships search
over internal knowledge first; forge-artifact ingestion is a follow-up.

## Options considered

### Option A — Lexical BM25 index in the substrate (recommended first)

**Where it lives.** A fifth index on `KnowledgeBase` (`knowledge.rs:275`)
alongside `by_action` / `by_category` / `by_tag`: an inverted index
(term → postings with term frequencies) plus per-document length and a
running average length for the BM25 denominator. Populated in
`index_entry` on every `insert`. A new `query_by_bm25(query, k)` sits
beside `query_by_tags` (`:439`) and returns the top-*k* entry ids ranked
by BM25 score.

**Surface.** New builtin `knowledge_search` — dispatch arm in
`eval_call_inner` (`src/evaluator/mod.rs:5858`, template: `knowledge_buy`
`:9557`), typechecker signature `(string, int) -> list<string>` in the
`:592`–`:709` region, read-only so **no capability gate** (matches
`knowledge_buy` / `sha256_hex` / `memo_list`).

**Persistence.** Derived, so it can be either (a) rebuilt at load from
the entries already replayed from the KB / crystallizer sidecars, or
(b) checkpointed to a `_knowledge_bm25/*.jsonl` sidecar mirroring the
`_crystallizer_index` layout. Rebuild-on-load is simplest and keeps the
index provably consistent with the source; sidecar is an optimization
if load time hurts.

**CB cost.** O(query_terms × postings) local scan. Fits the
`memo_list` / `json_array_object_field_values` band — extra 7, total
12 — and `check-cb-costs.sh` auto-extracts it from the `self.spend(N)`
literal. No separate registry entry.

**Tamper-evidence / replay.** Pure local computation over already-stored
data. Replay-faithful with zero gating. The index is a derived cache;
it never enters the audit chain.

**Dependencies.** None. Hand-rolled, in the spirit of `toml_minimal.rs`
/ `smtp.rs`.

- **Pros:** smallest lift; no network; deterministic; zero new deps;
  on-ethos with the exec-sh purge; unlocks the bulk of the exact-match
  gap immediately.
- **Cons:** misses pure paraphrase / synonymy (no shared vocabulary →
  no BM25 signal); quality depends on tokenization; not "real" semantic
  similarity.

### Option B — True embeddings / vector index in the substrate

**Where it lives.** An `id -> Vec<f32>` embedding map on `KnowledgeBase`,
populated on `insert` by calling a new backend `embed(text) -> Vec<f32>`;
`query_by_embedding(vec, k)` ranks by cosine. Same builtin surface as
Option A.

**Embedding source.** Anthropic has no embeddings API, so this requires
Voyage (Anthropic's recommendation) or the existing `openai` / `gemini`
backends' embeddings endpoints, plus a new `embed` method on the
`LlmBackend` trait (`src/llm.rs`) — the first non-completion call in the
codebase — and new `llm.embed.*` config keys.

**Persistence.** Vectors are expensive to recompute (each needs a
network round-trip), so unlike BM25 they **must** be checkpointed —
a `_knowledge_vectors/` sidecar, or into the DAG keyed by content hash
so a re-embed is skipped when the text is unchanged.

**CB cost.** The query must itself be embedded → a network call at query
time, landing in the `http_get` / `prompt` band (≈50), not the local
band. Ingestion embeds every inserted entry, adding steady network
cost.

**Tamper-evidence / replay.** The query-time network call is
non-deterministic and breaks `agentis replay` unless routed through the
`ReplayBackend` (record embeddings in production, replay from the audit
log) — the same treatment `prompt()` already gets. Meaningful extra
machinery.

**Dependencies.** External embedding provider + network egress + an
API-key config surface. Directly against decision driver 1.

- **Pros:** genuine semantic recall — paraphrase, synonymy, cross-lingual.
- **Cons:** external model dependency; network at ingest *and* query;
  replay gating; new backend trait method; larger cost band; against
  the self-contained trajectory.

### Option C — Federation-side retrieval (rejected)

Have `dev-apprenticeship` shell out to an external vector DB via a
`forge-api.sh`-style script.

- **Pros:** fastest to prototype; no core release-cadence dependency.
- **Cons:** reintroduces `exec sh` the whole v1.18.x line is removing;
  each federation reinvents the wheel (violates ADR-0003 portability);
  not tamper-evident; not replay-faithful. **Rejected** — it puts the
  primitive at the wrong layer.

### Option D — Status quo (baseline)

Keep dumping raw forge JSON into `prompt()` and matching exact keys.
Zero cost, but the exact-match gap persists and every decision keeps
paying full `prompt()` cost with undifferentiated context. This is the
thing the ADR exists to move away from.

## Recommendation

Accept **Option A (lexical BM25 in the substrate)** as Phase 1, with
**Option B (embeddings)** held as Phase 2 contingent on measured recall
gaps. Reject **Option C** outright and treat **Option D** as the
baseline being improved on.

Rationale: the retrieval gap is in the substrate, so the fix belongs
there (drivers 1, 6). BM25 clears drivers 2–5 with zero compromise — no
embedding model, deterministic replay, derived-cache tamper story,
honest local CB band — and delivers most of the "find similar prior X"
value. Embeddings buy real extra recall but only justify their
dependency and replay cost once BM25 is measured to fall short.

## Consequences

**If accepted:**

- `agentis-core` gains one read-only builtin `knowledge_search(query, k)`
  and a BM25 index on `KnowledgeBase`. Additive: no wire-format change,
  no schema migration, no new capability, no new config key (Phase 1).
  SemVer MINOR.
- `dev-apprenticeship` gets a pilot: replace "dump forge JSON into
  `prompt()`" with `knowledge_search(...)` in `triage/router.ag` and
  `triage/labeler.ag` first (highest-value, already crystallizer-aware),
  then fan out to `risk_assessor`, `scope_estimator`, the reviewers.
  Gated behind measuring whether the retrieved context actually lifts
  decision quality vs. the raw blob.
- A follow-up ADR/issue must cover **forge-artifact ingestion** — how
  past issues/MRs land in the `KnowledgeBase` so they are searchable at
  all — since the primitive can only search what is indexed.
- Phase 2 (embeddings), if triggered, is its own ADR: it introduces the
  first `llm.rs` embeddings method, an external provider dependency, and
  replay gating, and must not be smuggled in under this one.

**If rejected:** the coding federation keeps paying full `prompt()` cost
on undifferentiated context, and the crystallizer's prefix-exact
matching keeps missing near-duplicates — the status quo (Option D).

## Alternatives rejected

- **Retrofit similarity onto the DAG** (`src/storage.rs`). The object
  store is hash-addressed by design; approximate retrieval has no seam
  there. The index belongs at the `KnowledgeBase` layer.
- **Federation-side vector DB via `exec sh`** (Option C) — wrong layer,
  reintroduces the shell-out the substrate is removing, non-portable.
- **Embeddings-first** (Option B as Phase 1) — pays the external-model
  and replay-gating cost before proving lexical retrieval is
  insufficient.
