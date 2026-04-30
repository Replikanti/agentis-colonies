# Tribe Delta Colony

> Part of the [Tribes Bench](../) federation.

## Reasoning slice

Tribe Delta reasons about **lifetimes and aliasing** — temporal validity
of borrows and raw pointers in `unsafe { ... }` blocks. The seed prompt
asks the hunter to look for places where a borrow outlives the value it
points into: `Vec` reallocation invalidating prior `&`/`&mut` slices,
`unsafe` blocks that transmute lifetimes, and raw pointers that survive
past the safe Rust lifetime of their source. This is orthogonal to
tribe-alpha (`format!()` shell-builder pattern), tribe-beta
(source-to-sink data flow), and tribe-gamma (error-path data flow) —
those three reason about *data flow*, delta reasons about *temporal
validity*. The Stage 2 vendored `smallvec v0.6.13` target carries five
documented RustSec advisories; three of them (`use_after_free` in
`SmallVec::insert_many` and `SmallVec::grow`, `memory_corruption` in
`SmallVec::grow`) are squarely in delta's reasoning slice.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| hunter | `agents/hunter.ag` | lifetime / aliasing patterns; verifier feedback per finding | ~50 verified findings |

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
