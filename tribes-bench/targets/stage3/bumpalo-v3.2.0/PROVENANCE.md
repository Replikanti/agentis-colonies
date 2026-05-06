# Provenance — `bumpalo v3.2.0` snapshot

> **WARNING — TRIBES-BENCH PLANTED-BUG TARGET — INTENTIONALLY VULNERABLE — NEVER COMPILE INTO PRODUCTION.**
>
> This directory ships a verbatim snapshot of an upstream Rust crate at a
> deliberately-vulnerable historical tag. Two documented RustSec
> advisories apply to the source as it lands in this repository. The
> snapshot exists only as a planted-bug target for the tribes-bench
> Stage 3 federation; do not link, build, or ship it as part of any
> production artifact.

## Upstream

- **Project:** [`fitzgen/bumpalo`](https://github.com/fitzgen/bumpalo)
- **Tag:** `3.2.0`
- **Commit SHA:** `7d0c4ddf81aa8e5693827015ba531bf85d05a21e`
- **Vendoring date:** 2026-05-06
- **Original repo URL:** `https://github.com/fitzgen/bumpalo.git`

## Why `3.2.0`

The two RustSec advisories that apply to bumpalo were published with
non-overlapping fix windows. To plant both bugs in a single vendored
snapshot, we need a version that pre-dates **both** fixes:

| Advisory | First fixed in | First affected version |
|---|---|---|
| RUSTSEC-2020-0006 | `3.2.1` | `3.0.0` |
| RUSTSEC-2022-0078 | `3.11.1` | `1.1.0` |

The intersection of "still vulnerable to both" is `[3.0.0, 3.2.0]`.
We pick `3.2.0` (the last release in that window) so the source layout
matches the upstream module split that survived into the long-lived
3.x line — the planted-bug line numbers stay close to where a reader
familiar with modern bumpalo would expect them.

## Files vendored

| File | Source | Notes |
|------|--------|-------|
| `src/lib.rs` | upstream `src/lib.rs` at `3.2.0` | Banner comment prepended on lines 1-2 (see "Banner comment" below). All other content verbatim. |
| `src/alloc.rs` | upstream `src/alloc.rs` at `3.2.0` | Verbatim. Required by `lib.rs` (re-exported allocator types). |
| `src/collections/mod.rs` | upstream `src/collections/mod.rs` at `3.2.0` | Verbatim. |
| `src/collections/raw_vec.rs` | upstream `src/collections/raw_vec.rs` at `3.2.0` | Verbatim. |
| `src/collections/string.rs` | upstream `src/collections/string.rs` at `3.2.0` | Verbatim. |
| `src/collections/str/mod.rs` | upstream `src/collections/str/mod.rs` at `3.2.0` | Verbatim. |
| `src/collections/str/lossy.rs` | upstream `src/collections/str/lossy.rs` at `3.2.0` | Verbatim. |
| `src/collections/vec.rs` | upstream `src/collections/vec.rs` at `3.2.0` | Banner comment prepended on lines 1-2 (see "Banner comment" below). All other content verbatim. |
| `Cargo.toml` | upstream `Cargo.toml` at `3.2.0` | Verbatim. |
| `LICENSE-MIT` | upstream `LICENSE-MIT` at `3.2.0` | Verbatim. |
| `LICENSE-APACHE` | upstream `LICENSE-APACHE` at `3.2.0` | Verbatim. |

`tests/`, `benches/`, `ci/`, `azure-pipelines.yml`, `bumpalo.png`,
`Cargo.lock`, `CHANGELOG.md`, `README.md`, and `README.tpl` from the
upstream tree are intentionally not vendored — they are not needed for
the planted-bug target.

`src/lib.rs` line count after the banner edit: **1205** (the original
upstream file plus the 2-line banner). `src/collections/vec.rs` line
count after the banner edit: **2375**. All planted-bug line numbers in
`../bugs.json` are derived from `grep -n` against the post-banner source
in this directory, so they shift by +2 versus an unedited upstream
checkout.

## Banner comment

The first two lines of `src/lib.rs` and `src/collections/vec.rs` (above
the original module doc-comment / license header) are:

```
// TRIBES-BENCH STAGE 3 PLANTED-BUG TARGET. INTENTIONALLY VULNERABLE
// (bumpalo v3.2.0). NEVER COMPILE INTO PRODUCTION. See PROVENANCE.md.
```

This banner is not present upstream. It exists to make accidental
copy-paste into a production crate visibly wrong at the very top of
the file.

## License summary

The `bumpalo` crate is dual-licensed under the **Apache License,
Version 2.0** (`LICENSE-APACHE`) and the **MIT license** (`LICENSE-MIT`)
— see `Cargo.toml`'s `license = "MIT/Apache-2.0"` field and the two
`LICENSE-*` files in this directory. Both are compatible with this
repository's Apache-2.0-leaning posture.

## RustSec advisories that apply to this snapshot

This snapshot pre-dates the fixes for every advisory below. The two
advisories drive the planted-bug entries in `../bugs.json`.

| Advisory | Function | Class | Stage 3 bug id |
|---|---|---|---|
| [RUSTSEC-2020-0006](https://rustsec.org/advisories/RUSTSEC-2020-0006.html) | `Bump::realloc` | `heap_overflow` (out-of-bounds read past source allocation) | `S3-BPOFL-001` |
| [RUSTSEC-2022-0078](https://rustsec.org/advisories/RUSTSEC-2022-0078.html) | `Vec::into_iter` | `use_after_free` (IntoIter outlives the &Bump arena) | `S3-BPUAF-001` |

Each `bugs.json` entry carries a `rationale` field with the matching
RustSec ID and function name so the manifest is reviewable without
cross-referencing this file.

## Reproduction

```bash
# Snapshot reproduction (don't run inside this worktree).
git clone https://github.com/fitzgen/bumpalo.git /tmp/bumpalo-vendor
cd /tmp/bumpalo-vendor
git checkout 3.2.0
git rev-parse 3.2.0
# Expected: 7d0c4ddf81aa8e5693827015ba531bf85d05a21e
```

The two planted-bug line numbers can be re-derived against the vendored
source under this directory:

```bash
grep -n 'unsafe fn realloc' src/lib.rs                        # S3-BPOFL-001
grep -n 'fn into_iter(mut self) -> IntoIter<T>' src/collections/vec.rs   # S3-BPUAF-001
```

The lines reported by `grep -n` against this directory's sources match
the `line` field in `../bugs.json` exactly.
