# Provenance — `syncpool v0.1.5` snapshot

> **WARNING — TRIBES-BENCH PLANTED-BUG TARGET — INTENTIONALLY VULNERABLE — NEVER COMPILE INTO PRODUCTION.**
>
> This directory ships a verbatim snapshot of an upstream Rust crate at a
> deliberately-vulnerable historical tag. One documented RustSec advisory
> applies to the source as it lands in this repository. The snapshot
> exists only as a planted-bug target for the tribes-bench Stage 4
> Phase 1 federation; do not link, build, or ship it as part of any
> production artifact.

## Upstream

- **Project:** [`Chopinsky/byte_buffer`](https://github.com/Chopinsky/byte_buffer) (sub-crate: `syncpool`)
- **Tag:** `0.1.5` (crates.io publish)
- **Cargo VCS commit SHA:** `f3cf71b0986f417abc95d485f5446230906f32b6`
- **Vendoring date:** 2026-05-12
- **Original repo URL:** `https://github.com/Chopinsky/byte_buffer.git`

## Why `0.1.5`

The RustSec advisory below was patched in `0.1.6`. `0.1.5` is the last
published release in the `0.1.x` line that still carries the unsound
`unsafe impl<T> Send for Bucket2<T>` without the `T: Send` bound that
the fix added.

| Advisory | First fixed in | First affected version |
|---|---|---|
| RUSTSEC-2020-0142 (CVE-2020-36462) | `0.1.6` | `0.1.0` |

## Files vendored

| File | Source | Notes |
|------|--------|-------|
| `src/bucket.rs` | upstream `src/bucket.rs` at `0.1.5` | Banner comment prepended on lines 1-2 (see "Banner comment" below). Holds the planted-bug `Send` impl on `Bucket2<T>`. All other content verbatim. |
| `Cargo.toml` | upstream `Cargo.toml` at `0.1.5` | `publish = false` added (see "publish = false" below). Otherwise verbatim. |
| `LICENSE-MIT` | upstream repo `LICENSE` at `f3cf71b0986f417abc95d485f5446230906f32b6` | Verbatim. The crates.io tarball does not ship a LICENSE file; the upstream byte_buffer repo's root `LICENSE` is used. Renamed `LICENSE` → `LICENSE-MIT` to match this repo's per-target convention. |

`src/lib.rs`, `src/pool.rs`, `src/boxed.rs`, `src/utils.rs`,
`src/experimental/*`, `examples/`, `README.md`, and `Cargo.lock` from
the upstream tree are intentionally not vendored — only the file
holding the planted-bug `Send` impl is required by the verifier.

`src/bucket.rs` line count after the banner edit: original upstream file
plus the 2-line banner. The planted-bug line number in `bugs.json` is
derived from `grep -n` against the post-banner source in this
directory, so it shifts by +2 versus an unedited upstream checkout.

## Banner comment

The first two lines of `src/bucket.rs` (above the original
`#![allow(unused)]` attribute) are:

```
// TRIBES-BENCH STAGE 4 PHASE 1 CHUNK 2 PLANTED-BUG TARGET. INTENTIONALLY VULNERABLE
// (syncpool v0.1.5). NEVER COMPILE INTO PRODUCTION. See PROVENANCE.md.
```

This banner is not present upstream. It exists to make accidental
copy-paste into a production crate visibly wrong at the very top of
the file.

## `publish = false`

The vendored `Cargo.toml` has `publish = false` added in the `[package]`
block (issue #522 retro-add policy for every vendored Stage 4 target).
This guarantees `cargo publish` from this directory cannot push an
intentionally-vulnerable snapshot to crates.io even if the working tree
is mistakenly run as a publishable crate.

## License summary

The `syncpool` crate is licensed under the **MIT license**
(`LICENSE-MIT`) — see `Cargo.toml`'s `license = "MIT"` field and the
`LICENSE-MIT` file in this directory. The crates.io publish does not
ship a LICENSE file; this vendor copy uses the upstream byte_buffer
repo's root `LICENSE` file (which the `syncpool` sub-crate inherits)
renamed to `LICENSE-MIT` for naming uniformity with the other Stage 4
targets in this cohort.

## RustSec advisories that apply to this snapshot

This snapshot pre-dates the fix for the advisory below. The advisory
drives the planted-bug entry in `bugs.json`.

| Advisory | Function | Class | Stage 4 bug id |
|---|---|---|---|
| [RUSTSEC-2020-0142](https://rustsec.org/advisories/RUSTSEC-2020-0142.html) | `unsafe impl Send for Bucket2` | `send_violation` (Send without `T: Send` bound — non-Send T can cross threads via the pool's push/pull surface) | `S4-SYPL-001` |

The `bugs.json` entry carries a `rationale` field with the matching
RustSec ID and function name so the manifest is reviewable without
cross-referencing this file.

## Reproduction

```bash
# Snapshot reproduction (don't run inside this worktree).
git clone https://github.com/Chopinsky/byte_buffer.git /tmp/syncpool-vendor
cd /tmp/syncpool-vendor
git checkout f3cf71b0986f417abc95d485f5446230906f32b6
```

The planted-bug line number can be re-derived against the vendored
source under this directory:

```bash
grep -n 'unsafe impl<T> Send for Bucket2<T>' src/bucket.rs   # S4-SYPL-001
```

The line reported by `grep -n` against this directory's source matches
the `line` field in `bugs.json` exactly.
