# Provenance — `crossbeam-deque v0.7.2` snapshot

> **WARNING — TRIBES-BENCH PLANTED-BUG TARGET — INTENTIONALLY VULNERABLE — NEVER COMPILE INTO PRODUCTION.**
>
> This directory ships a verbatim snapshot of an upstream Rust crate at a
> deliberately-vulnerable historical tag. One documented RustSec advisory
> applies to the source as it lands in this repository. The snapshot
> exists only as a planted-bug target for the tribes-bench Stage 4
> Phase 1 federation; do not link, build, or ship it as part of any
> production artifact.

## Upstream

- **Project:** [`crossbeam-rs/crossbeam`](https://github.com/crossbeam-rs/crossbeam) (sub-crate: `crossbeam-deque`)
- **Tag:** `crossbeam-deque-0.7.2`
- **Commit SHA:** `28ad2b7e015832b47db7e389dd9ebce3e94b3adb`
- **Vendoring date:** 2026-05-11
- **Original repo URL:** `https://github.com/crossbeam-rs/crossbeam.git`

## Why `0.7.2`

The RustSec advisory below was patched in `0.7.4`. There was never a
public `0.7.3` release — `0.7.2` is the last published release in the
`0.7.x` line that still carries the vulnerable `Stealer::steal*`
implementation, so it is the last-known-vulnerable vendor tag for the
0.7 series.

| Advisory | First fixed in | First affected version |
|---|---|---|
| RUSTSEC-2021-0093 | `0.7.4` (also `0.8.1` on 0.8.x) | `0.6.0` |

## Files vendored

| File | Source | Notes |
|------|--------|-------|
| `src/lib.rs` | upstream `crossbeam-deque/src/lib.rs` at `crossbeam-deque-0.7.2` | Banner comment prepended on lines 1-2 (see "Banner comment" below). All other content verbatim. |
| `Cargo.toml` | upstream `crossbeam-deque/Cargo.toml` at `crossbeam-deque-0.7.2` | Verbatim. |
| `LICENSE-MIT` | upstream `crossbeam-deque/LICENSE-MIT` at `crossbeam-deque-0.7.2` | Verbatim. |
| `LICENSE-APACHE` | upstream `crossbeam-deque/LICENSE-APACHE` at `crossbeam-deque-0.7.2` | Verbatim. |

`tests/`, `benches/`, `CHANGELOG.md`, and `README.md` from the upstream
tree are intentionally not vendored — they are not needed for the
planted-bug target.

`src/lib.rs` line count after the banner edit: original upstream file
plus the 2-line banner. All planted-bug line numbers in `bugs.json`
are derived from `grep -n` against the post-banner source in this
directory, so they shift by +2 versus an unedited upstream checkout.

## Banner comment

The first two lines of `src/lib.rs` (above the original module
doc-comment / license header) are:

```
// TRIBES-BENCH STAGE 4 PHASE 1 CHUNK 1 PLANTED-BUG TARGET. INTENTIONALLY VULNERABLE
// (crossbeam-deque v0.7.2). NEVER COMPILE INTO PRODUCTION. See PROVENANCE.md.
```

This banner is not present upstream. It exists to make accidental
copy-paste into a production crate visibly wrong at the very top of
the file.

## License summary

The `crossbeam-deque` crate is dual-licensed under the **Apache License,
Version 2.0** (`LICENSE-APACHE`) and the **MIT license** (`LICENSE-MIT`)
— see `Cargo.toml`'s `license = "MIT OR Apache-2.0"` field and the two
`LICENSE-*` files in this directory. Both are compatible with this
repository's Apache-2.0-leaning posture.

## RustSec advisories that apply to this snapshot

This snapshot pre-dates the fix for the advisory below. The advisory
drives the planted-bug entry in `bugs.json`.

| Advisory | Function | Class | Stage 4 bug id |
|---|---|---|---|
| [RUSTSEC-2021-0093](https://rustsec.org/advisories/RUSTSEC-2021-0093.html) | `Stealer::steal` | `data_race` (concurrent pop + steal of the same slot → double-free of heap-allocated tasks) | `S4-CBDR-001` |

The `bugs.json` entry carries a `rationale` field with the matching
RustSec ID and function name so the manifest is reviewable without
cross-referencing this file.

## Reproduction

```bash
# Snapshot reproduction (don't run inside this worktree).
git clone https://github.com/crossbeam-rs/crossbeam.git /tmp/crossbeam-vendor
cd /tmp/crossbeam-vendor
git checkout crossbeam-deque-0.7.2
git rev-parse crossbeam-deque-0.7.2
# Expected: 28ad2b7e015832b47db7e389dd9ebce3e94b3adb
```

The planted-bug line number can be re-derived against the vendored
source under this directory:

```bash
grep -n 'pub fn steal(&self) -> Steal<T>' src/lib.rs   # S4-CBDR-001 (first match)
```

The line reported by `grep -n` against this directory's source matches
the `line` field in `bugs.json` exactly.
