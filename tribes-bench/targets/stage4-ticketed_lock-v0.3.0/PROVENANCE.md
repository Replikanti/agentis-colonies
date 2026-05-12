# Provenance — `ticketed_lock v0.3.0` snapshot

> **WARNING — TRIBES-BENCH PLANTED-BUG TARGET — INTENTIONALLY VULNERABLE — NEVER COMPILE INTO PRODUCTION.**
>
> This directory ships a verbatim snapshot of an upstream Rust crate at a
> deliberately-vulnerable historical tag. One documented RustSec advisory
> applies to the source as it lands in this repository. The snapshot
> exists only as a planted-bug target for the tribes-bench Stage 4
> Phase 1 federation; do not link, build, or ship it as part of any
> production artifact.

## Upstream

- **Project:** [`kvark/ticketed_lock`](https://github.com/kvark/ticketed_lock)
- **Tag:** `0.3.0` (crates.io publish)
- **Cargo VCS commit SHA:** `249888d3f57aca36448aac158be7101ba401380b`
- **Vendoring date:** 2026-05-12
- **Original repo URL:** `https://github.com/kvark/ticketed_lock`

## Why `0.3.0`

`ticketed_lock` is **unmaintained** and the advisory below has **no fix**.
`0.3.0` is the latest published version of the crate; it still carries
the unsound `unsafe impl Send for ReadTicket<T>` / `unsafe impl Send for
WriteTicket<T>` pattern that motivated RUSTSEC-2020-0119. Vendoring at
"latest published" matches the plan's policy for unmaintained crates.

| Advisory | First fixed in | First affected version |
|---|---|---|
| RUSTSEC-2020-0119 | (no fix — unmaintained) | `0.1.0` |

## Files vendored

| File | Source | Notes |
|------|--------|-------|
| `src/lib.rs` | upstream `src/lib.rs` at `0.3.0` | Banner comment prepended on lines 1-2 (see "Banner comment" below). All other content verbatim. |
| `Cargo.toml` | upstream `Cargo.toml` at `0.3.0` | `publish = false` added (see "publish = false" below). Otherwise verbatim. |
| `LICENSE-APACHE` | upstream `LICENSE` at `0.3.0` | Verbatim. Renamed `LICENSE` → `LICENSE-APACHE` to match this repo's per-target convention (the crate is Apache-2.0-only — there is no upstream `LICENSE-MIT`). |

`src/raw.rs`, `examples/`, `tests/`, `CHANGELOG.md`, and `README.md` from
the upstream tree are intentionally not vendored — they are not needed
for the planted-bug target.

`src/lib.rs` line count after the banner edit: original upstream file
plus the 2-line banner. The planted-bug line number in `bugs.json` is
derived from `grep -n` against the post-banner source in this
directory, so it shifts by +2 versus an unedited upstream checkout.

## Banner comment

The first two lines of `src/lib.rs` (above the original module
doc-comment) are:

```
// TRIBES-BENCH STAGE 4 PHASE 1 CHUNK 2 PLANTED-BUG TARGET. INTENTIONALLY VULNERABLE
// (ticketed_lock v0.3.0). NEVER COMPILE INTO PRODUCTION. See PROVENANCE.md.
```

This banner is not present upstream. It exists to make accidental
copy-paste into a production crate visibly wrong at the very top of
the file.

## `publish = false`

The vendored `Cargo.toml` has `publish = false` appended in the
`[package]` block (issue #522 retro-add policy for every vendored Stage
4 target). This guarantees `cargo publish` from this directory cannot
push an intentionally-vulnerable snapshot to crates.io even if the
working tree is mistakenly run as a publishable crate.

## License summary

The `ticketed_lock` crate is licensed under the **Apache License,
Version 2.0** (`LICENSE-APACHE`) — see `Cargo.toml`'s
`license = "Apache-2.0"` field and the `LICENSE-APACHE` file in this
directory. The upstream repo ships a single `LICENSE` file; this vendor
copy renames it to `LICENSE-APACHE` so the per-target license naming is
uniform with the dual-licensed crossbeam-deque / generator targets in
this Stage 4 cohort. There is no `LICENSE-MIT` for this crate because
the upstream does not dual-license it.

## RustSec advisories that apply to this snapshot

This snapshot will never be patched — `ticketed_lock` is unmaintained.
The advisory drives the planted-bug entry in `bugs.json`.

| Advisory | Function | Class | Stage 4 bug id |
|---|---|---|---|
| [RUSTSEC-2020-0119](https://rustsec.org/advisories/RUSTSEC-2020-0119.html) | `unsafe impl Send for ReadTicket` | `missing_lock` (ticketed lock surface does not enforce the exclusive-access invariant; Send bound on ReadTicket lets the guard escape the ticket-acquiring thread) | `S4-TKLO-001` |

The `bugs.json` entry carries a `rationale` field with the matching
RustSec ID and function name so the manifest is reviewable without
cross-referencing this file.

## Reproduction

```bash
# Snapshot reproduction (don't run inside this worktree).
git clone https://github.com/kvark/ticketed_lock.git /tmp/ticketed_lock-vendor
cd /tmp/ticketed_lock-vendor
git checkout 249888d3f57aca36448aac158be7101ba401380b
```

The planted-bug line number can be re-derived against the vendored
source under this directory:

```bash
grep -n 'unsafe impl<T: Send> Send for ReadTicket<T>' src/lib.rs   # S4-TKLO-001
```

The line reported by `grep -n` against this directory's source matches
the `line` field in `bugs.json` exactly.
