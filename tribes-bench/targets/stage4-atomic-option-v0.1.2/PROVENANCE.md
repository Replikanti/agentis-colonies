# Provenance — `atomic-option v0.1.2` snapshot

> **WARNING — TRIBES-BENCH PLANTED-BUG TARGET — INTENTIONALLY VULNERABLE — NEVER COMPILE INTO PRODUCTION.**
>
> This directory ships a verbatim snapshot of an upstream Rust crate at a
> deliberately-vulnerable historical tag. One documented RustSec advisory
> applies to the source as it lands in this repository. The snapshot
> exists only as a planted-bug target for the tribes-bench Stage 4
> Phase 1 federation; do not link, build, or ship it as part of any
> production artifact.

## Upstream

- **Project:** [`reem/rust-atomic-option`](https://github.com/reem/rust-atomic-option)
- **Tag:** `0.1.2` (crates.io publish)
- **Vendoring date:** 2026-05-12
- **Original repo URL:** `https://github.com/reem/rust-atomic-option.git`

## Why `0.1.2`

`atomic-option` is **unmaintained** and the advisory below has **no fix**.
`0.1.2` is the latest published version of the crate; it still carries
the unsound `unsafe impl<T> Sync for AtomicOption<T>` (no `T: Send`
bound) that motivated RUSTSEC-2020-0113. Vendoring at "latest published"
matches the plan's policy for unmaintained crates.

| Advisory | First fixed in | First affected version |
|---|---|---|
| RUSTSEC-2020-0113 | (no fix — unmaintained) | `0.1.0` |

## Files vendored

| File | Source | Notes |
|------|--------|-------|
| `src/lib.rs` | upstream `src/lib.rs` at `0.1.2` | Banner comment prepended on lines 1-2 (see "Banner comment" below). All other content verbatim. |
| `Cargo.toml` | upstream `Cargo.toml` at `0.1.2` | `publish = false` added (see "publish = false" below). Otherwise verbatim. |
| `LICENSE-MIT` | reconstructed from upstream `license = "MIT"` declaration in `Cargo.toml` (the published crate and upstream repo do not ship a `LICENSE` file). Verbatim standard MIT text with the author's copyright per `Cargo.toml`'s `authors` field. |

`tests/`, `examples/`, `CHANGELOG.md`, and `README.md` from the upstream
tree are intentionally not vendored — they are not needed for the
planted-bug target.

`src/lib.rs` line count after the banner edit: original upstream file
plus the 2-line banner. The planted-bug line number in `bugs.json` is
derived from `grep -n` against the post-banner source in this
directory, so it shifts by +2 versus an unedited upstream checkout.

## Banner comment

The first two lines of `src/lib.rs` (above the original
`#![cfg_attr(test, deny(warnings))]` attribute) are:

```
// TRIBES-BENCH STAGE 4 PHASE 1 CHUNK 2 PLANTED-BUG TARGET. INTENTIONALLY VULNERABLE
// (atomic-option v0.1.2). NEVER COMPILE INTO PRODUCTION. See PROVENANCE.md.
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

The `atomic-option` crate is licensed under the **MIT license**
(`LICENSE-MIT`) — see `Cargo.toml`'s `license = "MIT"` field and the
`LICENSE-MIT` file in this directory. The upstream crate and repo do
not ship a `LICENSE` file (only the `license` field in `Cargo.toml`
declares the terms); this vendor copy includes the standard MIT text
with the author's name from `Cargo.toml` so the tarball is
self-contained.

## RustSec advisories that apply to this snapshot

This snapshot will never be patched — `atomic-option` is unmaintained.
The advisory drives the planted-bug entry in `bugs.json`.

| Advisory | Function | Class | Stage 4 bug id |
|---|---|---|---|
| [RUSTSEC-2020-0113](https://rustsec.org/advisories/RUSTSEC-2020-0113.html) | `unsafe impl Sync for AtomicOption` | `send_violation` (Sync without `T: Send` bound — non-Send T can cross threads through `.take()`) | `S4-AOSV-001` |

The `bugs.json` entry carries a `rationale` field with the matching
RustSec ID and function name so the manifest is reviewable without
cross-referencing this file.

## Reproduction

```bash
# Snapshot reproduction (don't run inside this worktree).
git clone https://github.com/reem/rust-atomic-option.git /tmp/atomic-option-vendor
cd /tmp/atomic-option-vendor
git log --oneline | head -5
```

The planted-bug line number can be re-derived against the vendored
source under this directory:

```bash
grep -n 'unsafe impl<T> Sync for AtomicOption<T>' src/lib.rs   # S4-AOSV-001
```

The line reported by `grep -n` against this directory's source matches
the `line` field in `bugs.json` exactly.
