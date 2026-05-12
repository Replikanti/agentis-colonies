# Provenance — `atom v0.3.5` snapshot

> **WARNING — TRIBES-BENCH PLANTED-BUG TARGET — INTENTIONALLY VULNERABLE — NEVER COMPILE INTO PRODUCTION.**
>
> This directory ships a verbatim snapshot of an upstream Rust crate at a
> deliberately-vulnerable historical tag. One documented RustSec advisory
> applies to the source as it lands in this repository. The snapshot
> exists only as a planted-bug target for the tribes-bench Stage 4
> Phase 1 federation; do not link, build, or ship it as part of any
> production artifact.

## Upstream

- **Project:** [`slide-rs/atom`](https://github.com/slide-rs/atom)
- **Tag:** `0.3.5` (crates.io publish)
- **Vendoring date:** 2026-05-12
- **Original repo URL:** `https://github.com/slide-rs/atom`

## Why `0.3.5`

The RustSec advisory below was patched in `0.3.6`. `0.3.5` is the last
published release in the `0.3.x` line that still carries the unsound
`unsafe impl<P> Send for Atom<P> where P: IntoRawPtr + FromRawPtr`
without the `P: Send` bound that the fix added.

| Advisory | First fixed in | First affected version |
|---|---|---|
| RUSTSEC-2020-0044 | `0.3.6` | `0.1.0` |

## Files vendored

| File | Source | Notes |
|------|--------|-------|
| `src/lib.rs` | upstream `src/lib.rs` at `0.3.5` | Banner comment prepended on lines 1-2 (see "Banner comment" below). All other content verbatim. |
| `Cargo.toml` | upstream `Cargo.toml` at `0.3.5` | `publish = false` added (see "publish = false" below). Otherwise verbatim. |
| `LICENSE-APACHE` | upstream `LICENSE` at `0.3.5` | Verbatim. Renamed `LICENSE` → `LICENSE-APACHE` to match this repo's per-target convention (the crate is Apache-2.0-only — there is no upstream `LICENSE-MIT`). |

`tests/`, `examples/`, `readme.md`, and `.travis.yml` from the upstream
tree are intentionally not vendored — they are not needed for the
planted-bug target.

`src/lib.rs` line count after the banner edit: original upstream file
plus the 2-line banner. The planted-bug line number in `bugs.json` is
derived from `grep -n` against the post-banner source in this
directory, so it shifts by +2 versus an unedited upstream checkout.

## Banner comment

The first two lines of `src/lib.rs` (above the original SPDX copyright
header) are:

```
// TRIBES-BENCH STAGE 4 PHASE 1 CHUNK 2 PLANTED-BUG TARGET. INTENTIONALLY VULNERABLE
// (atom v0.3.5). NEVER COMPILE INTO PRODUCTION. See PROVENANCE.md.
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

The `atom` crate is licensed under the **Apache License, Version 2.0**
(`LICENSE-APACHE`) — see `Cargo.toml`'s `license = "Apache-2.0"` field
and the `LICENSE-APACHE` file in this directory. The upstream repo
ships a single `LICENSE` file; this vendor copy renames it to
`LICENSE-APACHE` so the per-target license naming is uniform with the
dual-licensed crossbeam-deque / generator targets in this Stage 4
cohort. There is no `LICENSE-MIT` for this crate because the upstream
does not dual-license it.

## RustSec advisories that apply to this snapshot

This snapshot pre-dates the fix for the advisory below. The advisory
drives the planted-bug entry in `bugs.json`.

| Advisory | Function | Class | Stage 4 bug id |
|---|---|---|---|
| [RUSTSEC-2020-0044](https://rustsec.org/advisories/RUSTSEC-2020-0044.html) | `unsafe impl Send for Atom` | `data_race` (missing `P: Send` bound on the AtomicPtr-backed swap surface; two threads can race on the inner pointer's drop / reinit when P is not Send) | `S4-ATOM-001` |

The `bugs.json` entry carries a `rationale` field with the matching
RustSec ID and function name so the manifest is reviewable without
cross-referencing this file.

## Reproduction

```bash
# Snapshot reproduction (don't run inside this worktree).
git clone https://github.com/slide-rs/atom.git /tmp/atom-vendor
cd /tmp/atom-vendor
git log --oneline | head -5
```

The planted-bug line number can be re-derived against the vendored
source under this directory:

```bash
grep -n 'unsafe impl<P> Send for Atom<P>' src/lib.rs   # S4-ATOM-001
```

The line reported by `grep -n` against this directory's source matches
the `line` field in `bugs.json` exactly.
