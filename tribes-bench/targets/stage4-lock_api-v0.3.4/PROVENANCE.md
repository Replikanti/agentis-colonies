# Provenance — `lock_api v0.3.4` snapshot

> **WARNING — TRIBES-BENCH PLANTED-BUG TARGET — INTENTIONALLY VULNERABLE — NEVER COMPILE INTO PRODUCTION.**
>
> This directory ships a verbatim snapshot of an upstream Rust crate at a
> deliberately-vulnerable historical tag. One documented RustSec advisory
> drives three planted-bug entries against this snapshot. The snapshot
> exists only as a planted-bug target for the tribes-bench Stage 4
> Phase 1 federation; do not link, build, or ship it as part of any
> production artifact.

## Upstream

- **Project:** [`Amanieu/parking_lot`](https://github.com/Amanieu/parking_lot) (sub-crate: `lock_api`)
- **Tag:** `0.3.4` (crates.io publish)
- **Cargo VCS commit SHA:** `761a4d567fddde152d624c38464f4833f05c7f62`
- **Vendoring date:** 2026-05-12
- **Original repo URL:** `https://github.com/Amanieu/parking_lot`

## Why `0.3.4`

The RustSec advisory below was patched in `0.4.2`. `0.3.4` is the last
published release in the `0.3.x` line that still carries the unsound
`Send` impls on the three Mapped*Guard types (`MappedMutexGuard`,
`MappedRwLockReadGuard`, `MappedRwLockWriteGuard`) without the
`T: Send` / `T: Sync` bounds that the fix added.

| Advisory | First fixed in | First affected version |
|---|---|---|
| RUSTSEC-2020-0070 (CVE-2020-35910) | `0.4.2` | `0.1.0` |

## Files vendored

| File | Source | Notes |
|------|--------|-------|
| `src/mutex.rs` | upstream `lock_api/src/mutex.rs` at `0.3.4` | Banner comment prepended on lines 1-2 (see "Banner comment" below). Holds the `MappedMutexGuard` planted-bug site. All other content verbatim. |
| `src/rwlock.rs` | upstream `lock_api/src/rwlock.rs` at `0.3.4` | Banner comment prepended on lines 1-2. Holds the `MappedRwLockReadGuard` + `MappedRwLockWriteGuard` planted-bug sites. All other content verbatim. |
| `Cargo.toml` | upstream `lock_api/Cargo.toml` at `0.3.4` | `publish = false` added (see "publish = false" below). Otherwise verbatim. |
| `LICENSE-APACHE` | upstream `lock_api/LICENSE-APACHE` at `0.3.4` | Verbatim. |
| `LICENSE-MIT` | upstream `lock_api/LICENSE-MIT` at `0.3.4` | Verbatim. |

`src/lib.rs`, `src/remutex.rs`, `tests/`, `benches/`, `CHANGELOG.md`,
and `README.md` from the upstream tree are intentionally not vendored
— only the two files holding the three planted-bug `Send` impls are
required by the verifier.

`src/mutex.rs` and `src/rwlock.rs` line counts after the banner edit:
original upstream file plus the 2-line banner. All planted-bug line
numbers in `bugs.json` are derived from `grep -n` against the
post-banner sources in this directory, so they shift by +2 versus an
unedited upstream checkout.

## Banner comment

The first two lines of `src/mutex.rs` and `src/rwlock.rs` (above the
original SPDX copyright header) are:

```
// TRIBES-BENCH STAGE 4 PHASE 1 CHUNK 2 PLANTED-BUG TARGET. INTENTIONALLY VULNERABLE
// (lock_api v0.3.4). NEVER COMPILE INTO PRODUCTION. See PROVENANCE.md.
```

This banner is not present upstream. It exists to make accidental
copy-paste into a production crate visibly wrong at the very top of
each file.

## `publish = false`

The vendored `Cargo.toml` has `publish = false` appended in the
`[package]` block (issue #522 retro-add policy for every vendored Stage
4 target). This guarantees `cargo publish` from this directory cannot
push an intentionally-vulnerable snapshot to crates.io even if the
working tree is mistakenly run as a publishable crate.

## License summary

The `lock_api` crate is dual-licensed under the **Apache License,
Version 2.0** (`LICENSE-APACHE`) and the **MIT license** (`LICENSE-MIT`)
— see `Cargo.toml`'s `license = "Apache-2.0/MIT"` field and the two
`LICENSE-*` files in this directory. Both are compatible with this
repository's Apache-2.0-leaning posture.

## RustSec advisories that apply to this snapshot

This snapshot pre-dates the fix for the advisory below. The advisory
drives three planted-bug entries in `bugs.json` (3-for-1: one advisory,
three independent unsound `Send` impls in the same release).

| Advisory | Function | Class | Stage 4 bug id |
|---|---|---|---|
| [RUSTSEC-2020-0070](https://rustsec.org/advisories/RUSTSEC-2020-0070.html) | `unsafe impl Send for MappedMutexGuard` | `missing_lock` (Send bound omits `T: Send` so the mapped guard can cross threads while the lock invariant on `T` does not hold) | `S4-LAPI-001` |
| [RUSTSEC-2020-0070](https://rustsec.org/advisories/RUSTSEC-2020-0070.html) | `unsafe impl Send for MappedRwLockReadGuard` | `missing_lock` (same pattern on the read-projected guard; Send without `T: Sync` lets `&T` cross threads) | `S4-LAPI-002` |
| [RUSTSEC-2020-0070](https://rustsec.org/advisories/RUSTSEC-2020-0070.html) | `unsafe impl Send for MappedRwLockWriteGuard` | `missing_lock` (same pattern on the write-projected guard; Send without `T: Send` lets `&mut T` cross threads) | `S4-LAPI-003` |

Each `bugs.json` entry carries a `rationale` field with the matching
RustSec ID and function name so the manifest is reviewable without
cross-referencing this file.

## Reproduction

```bash
# Snapshot reproduction (don't run inside this worktree).
git clone https://github.com/Amanieu/parking_lot.git /tmp/lock_api-vendor
cd /tmp/lock_api-vendor
git checkout 761a4d567fddde152d624c38464f4833f05c7f62
```

The three planted-bug line numbers can be re-derived against the
vendored source under this directory:

```bash
grep -n "unsafe impl<'a, R: RawMutex + 'a, T: ?Sized + 'a> Send for MappedMutexGuard"        src/mutex.rs    # S4-LAPI-001
grep -n "unsafe impl<'a, R: RawRwLock + 'a, T: ?Sized + 'a> Send for MappedRwLockReadGuard"  src/rwlock.rs   # S4-LAPI-002
grep -n "unsafe impl<'a, R: RawRwLock + 'a, T: ?Sized + 'a> Send for MappedRwLockWriteGuard" src/rwlock.rs   # S4-LAPI-003
```

The lines reported by `grep -n` against this directory's source match
the `line` field in `bugs.json` exactly.
