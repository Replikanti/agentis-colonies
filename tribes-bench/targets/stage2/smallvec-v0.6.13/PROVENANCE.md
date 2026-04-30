# Provenance — `smallvec v0.6.13` snapshot

> **WARNING — TRIBES-BENCH PLANTED-BUG TARGET — INTENTIONALLY VULNERABLE — NEVER COMPILE INTO PRODUCTION.**
>
> This directory ships a verbatim snapshot of an upstream Rust crate at a
> deliberately-vulnerable historical tag. Five documented RustSec
> advisories apply to the source as it lands in this repository. The
> snapshot exists only as a planted-bug target for the tribes-bench
> Stage 2 federation; do not link, build, or ship it as part of any
> production artifact.

## Upstream

- **Project:** [`servo/rust-smallvec`](https://github.com/servo/rust-smallvec)
- **Tag:** `v0.6.13`
- **Commit SHA:** `78522049b3ce129d02eea4e802747ba1090a5586`
- **Vendoring date:** 2026-04-28
- **Original repo URL:** `https://github.com/servo/rust-smallvec.git`

## Files vendored

| File | Source | Notes |
|------|--------|-------|
| `lib.rs` | upstream `lib.rs` at `v0.6.13` | Banner comment prepended on lines 1-2 (see "Banner comment" below). All other content verbatim. |
| `Cargo.toml` | upstream `Cargo.toml` at `v0.6.13` | Verbatim. |
| `README.md` | upstream `README.md` at `v0.6.13` | Verbatim. |
| `LICENSE-MIT` | upstream `LICENSE-MIT` at `v0.6.13` | Verbatim. |
| `LICENSE-APACHE` | upstream `LICENSE-APACHE` at `v0.6.13` | Verbatim. |

`lib.rs` line count after the banner edit: **2376** (the original
upstream file plus the 2-line banner). All planted-bug line numbers in
`../bugs.json` are derived from `grep -n` against the post-banner source
in this directory, so they shift by +2 versus an unedited upstream
checkout.

## Banner comment

The first two lines of `lib.rs` (above the original Apache/MIT license
header) are:

```
// TRIBES-BENCH STAGE 2 PLANTED-BUG TARGET. INTENTIONALLY VULNERABLE
// (smallvec v0.6.13). NEVER COMPILE INTO PRODUCTION. See PROVENANCE.md.
```

This banner is not present upstream. It exists to make accidental
copy-paste into a production crate visibly wrong at the very top of
the file.

## License summary

The `smallvec` crate is dual-licensed under the **Apache License,
Version 2.0** (`LICENSE-APACHE`) and the **MIT license** (`LICENSE-MIT`)
— see the per-file headers and the two `LICENSE-*` files in this
directory. Both are compatible with this repository's Apache-2.0-leaning
posture.

## RustSec advisories that apply to this snapshot

This snapshot pre-dates the fixes for every advisory below. The five
advisories drive the planted-bug entries in `../bugs.json`.

| Advisory | Function | Class | Stage 2 bug id |
|---|---|---|---|
| [RUSTSEC-2018-0003](https://rustsec.org/advisories/RUSTSEC-2018-0003.html) | `SmallVec::insert_many` | `use_after_free` (double-free during unwind) | `S2-SMVUAF-001` |
| [RUSTSEC-2018-0018](https://rustsec.org/advisories/RUSTSEC-2018-0018.html) | `SmallVec::from_buf_and_len_unchecked` | `uninitialised_memory` | `S2-SMVMEM-001` |
| [RUSTSEC-2019-0009](https://rustsec.org/advisories/RUSTSEC-2019-0009.html) | `SmallVec::grow` | `use_after_free` (UAF + double-free) | `S2-SMVUAF-002` |
| [RUSTSEC-2019-0012](https://rustsec.org/advisories/RUSTSEC-2019-0012.html) | `SmallVec::grow` | `memory_corruption` | `S2-SMVMEM-002` |
| [RUSTSEC-2021-0003](https://rustsec.org/advisories/RUSTSEC-2021-0003.html) | `SmallVec::insert_many` | `heap_overflow` (lying `size_hint`) | `S2-SMVOFL-001` |

Each `bugs.json` entry carries a `rationale` field with the matching
RustSec ID and function name so the manifest is reviewable without
cross-referencing this file.

## Reproduction

```bash
# Snapshot reproduction (don't run inside this worktree).
git clone https://github.com/servo/rust-smallvec.git /tmp/smallvec-vendor
cd /tmp/smallvec-vendor
git checkout v0.6.13
git rev-parse v0.6.13
# Expected: 78522049b3ce129d02eea4e802747ba1090a5586
```

The five planted-bug line numbers can be re-derived against the vendored
source under this directory:

```bash
grep -n 'fn insert_many' lib.rs                # S2-SMVUAF-001
grep -n 'fn from_buf_and_len_unchecked' lib.rs # S2-SMVMEM-001
grep -n 'fn grow' lib.rs                       # S2-SMVUAF-002 + S2-SMVMEM-002
grep -n 'iter.size_hint()' lib.rs              # S2-SMVOFL-001
```

The lines reported by `grep -n` against this directory's `lib.rs` match
the `line` field in `../bugs.json` exactly.
