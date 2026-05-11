# Provenance — `owning_ref v0.4.1` snapshot

> **WARNING — TRIBES-BENCH PLANTED-BUG TARGET — INTENTIONALLY VULNERABLE — NEVER COMPILE INTO PRODUCTION.**
>
> This directory ships a verbatim snapshot of an upstream Rust crate at a
> deliberately-vulnerable historical tag. One documented RustSec advisory
> applies to the source as it lands in this repository. The snapshot
> exists only as a planted-bug target for the tribes-bench Stage 4
> Phase 1 federation; do not link, build, or ship it as part of any
> production artifact.

## Upstream

- **Project:** [`Kimundi/owning-ref-rs`](https://github.com/Kimundi/owning-ref-rs)
- **Tag:** `v0.4.1`
- **Commit SHA:** `677c5bbe33210e65ababfd46eeb2b7aaab41f94d`
- **Vendoring date:** 2026-05-11
- **Original repo URL:** `https://github.com/Kimundi/owning-ref-rs.git`

## Why `0.4.1`

`owning_ref` is **unmaintained** and the advisory below has **no fix**.
`0.4.1` is the latest published version of the crate; it still carries
all three unsound bug patterns (HRTB-missing on `map` / `map_with_owner`
+ co-existing borrow leak in `as_owner_mut`). Vendoring at "latest
published" matches the plan's policy for unmaintained crates.

| Advisory | First fixed in | First affected version |
|---|---|---|
| RUSTSEC-2022-0040 | (no fix — unmaintained) | `0.1.0` |

## Files vendored

| File | Source | Notes |
|------|--------|-------|
| `src/lib.rs` | upstream `src/lib.rs` at `v0.4.1` | Banner comment prepended on lines 1-2 (see "Banner comment" below). All other content verbatim. |
| `Cargo.toml` | upstream `Cargo.toml` at `v0.4.1` | Verbatim. |
| `LICENSE-MIT` | upstream `LICENSE` at `v0.4.1` | Verbatim. Renamed `LICENSE` → `LICENSE-MIT` to match this repo's per-target convention (the crate is MIT-only — there is no upstream `LICENSE-APACHE`). |

`tests/`, `examples/`, `CHANGELOG.md`, and `README.md` from the upstream
tree are intentionally not vendored — they are not needed for the
planted-bug target.

`src/lib.rs` line count after the banner edit: original upstream file
plus the 2-line banner. All planted-bug line numbers in `bugs.json`
are derived from `grep -n` against the post-banner source in this
directory, so they shift by +2 versus an unedited upstream checkout.

## Banner comment

The first two lines of `src/lib.rs` (above the original
`#![warn(missing_docs)]` attribute) are:

```
// TRIBES-BENCH STAGE 4 PHASE 1 CHUNK 1 PLANTED-BUG TARGET. INTENTIONALLY VULNERABLE
// (owning_ref v0.4.1). NEVER COMPILE INTO PRODUCTION. See PROVENANCE.md.
```

This banner is not present upstream. It exists to make accidental
copy-paste into a production crate visibly wrong at the very top of
the file.

## License summary

The `owning_ref` crate is licensed under the **MIT license**
(`LICENSE-MIT`) — see `Cargo.toml`'s `license = "MIT"` field and the
`LICENSE-MIT` file in this directory. The upstream repo ships a single
`LICENSE` file; this vendor copy renames it to `LICENSE-MIT` so the
per-target license naming is uniform with the dual-licensed
crossbeam-deque / generator targets in this Stage 4 cohort. There is
no `LICENSE-APACHE` for this crate because the upstream does not
dual-license it.

## RustSec advisories that apply to this snapshot

This snapshot will never be patched — `owning_ref` is unmaintained.
The advisory drives all three planted-bug entries in `bugs.json`.

| Advisory | Function | Class | Stage 4 bug id |
|---|---|---|---|
| [RUSTSEC-2022-0040](https://rustsec.org/advisories/RUSTSEC-2022-0040.html) | `OwningRef::map` | `dangling_borrow` (missing HRTB on closure return) | `S4-ORDB-001` |
| [RUSTSEC-2022-0040](https://rustsec.org/advisories/RUSTSEC-2022-0040.html) | `OwningRef::map_with_owner` | `dangling_borrow` (same HRTB hole, paired-argument variant) | `S4-ORDB-002` |
| [RUSTSEC-2022-0040](https://rustsec.org/advisories/RUSTSEC-2022-0040.html) | `OwningRef::as_owner_mut` | `dangling_borrow` (co-existing &mut O alongside &T derived from O) | `S4-ORDB-003` |

Each `bugs.json` entry carries a `rationale` field with the matching
RustSec ID and function name so the manifest is reviewable without
cross-referencing this file.

## Reproduction

```bash
# Snapshot reproduction (don't run inside this worktree).
git clone https://github.com/Kimundi/owning-ref-rs.git /tmp/owning-ref-vendor
cd /tmp/owning-ref-vendor
git checkout v0.4.1
git rev-parse v0.4.1
# Expected: 677c5bbe33210e65ababfd46eeb2b7aaab41f94d
```

The three planted-bug line numbers can be re-derived against the
vendored source under this directory:

```bash
grep -n 'pub fn map<F, U: ?Sized>(self, f: F) -> OwningRef<O, U>' src/lib.rs            # S4-ORDB-001
grep -n 'pub fn map_with_owner<F, U: ?Sized>(self, f: F) -> OwningRef<O, U>' src/lib.rs # S4-ORDB-002
grep -n 'pub fn as_owner_mut(&mut self) -> &mut O' src/lib.rs                          # S4-ORDB-003
```

The lines reported by `grep -n` against this directory's source match
the `line` field in `bugs.json` exactly.
