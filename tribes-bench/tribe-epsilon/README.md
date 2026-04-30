# Tribe Epsilon Colony

> Part of the [Tribes Bench](../) federation.

## Reasoning slice

Tribe Epsilon reasons about **concurrency and `Send` + `Sync`** —
parallelism-induced unsoundness. The seed prompt asks the hunter to look
for shared mutable state without lock guards: `static mut`, `&Cell` /
`&RefCell` crossing thread boundaries, missing `Mutex` / `RwLock` around
`Vec` / `HashMap` accessed from multiple threads, `unsafe impl Send` /
`unsafe impl Sync` on types containing raw pointers, and inline buffer
updates (`set_len`, capacity write-back) on a `SmallVec` or `Vec` where
two threads can each obtain `&mut self` via interior mutability. None of
the existing four tribes (alpha, beta, gamma, delta) reasons about
parallelism, so epsilon adds a third axis on top of data-flow (alpha,
beta, gamma) and temporal-validity (delta). The Stage 2 vendored
`smallvec v0.6.13` target's `SmallVec::grow` bug-pair (RUSTSEC-2019-0009
+ RUSTSEC-2019-0012) and the inline `set_len` paths inside
`SmallVec::insert_many` are exactly the bug-shape epsilon's prompt is
seeded for.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| hunter | `agents/hunter.ag` | concurrency / Send+Sync patterns; verifier feedback per finding | ~50 verified findings |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. (Optional) Override the synthetic-target paths via env vars before launching:
   `TARGET_DIR` (default: `<fed>/targets/stage0`),
   `BUGS_MANIFEST` (default: `$TARGET_DIR/bugs.json`),
   `VERIFIER_PATH` (default: `<fed>/tools/verify-finding.sh`).
   tribes-bench is a non-forge federation (`forge.type = "none"`); no forge
   credentials are required.

3. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```
