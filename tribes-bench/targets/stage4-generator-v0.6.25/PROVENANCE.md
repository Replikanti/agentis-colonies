# Provenance — `generator v0.6.25` snapshot

> **WARNING — TRIBES-BENCH PLANTED-BUG TARGET — INTENTIONALLY VULNERABLE — NEVER COMPILE INTO PRODUCTION.**
>
> This directory ships a verbatim snapshot of an upstream Rust crate at a
> deliberately-vulnerable historical tag. One documented RustSec advisory
> applies to the source as it lands in this repository. The snapshot
> exists only as a planted-bug target for the tribes-bench Stage 4
> Phase 1 federation; do not link, build, or ship it as part of any
> production artifact.

## Why this crate (substitution note)

The original plan called for `atomicwrites` as the third crate. At
vendoring time `advisory-db/crates/atomicwrites/` does not exist in the
RustSec database — there is no live advisory for that crate. Per the
plan's §3 substitution policy (recorded before any source was copied),
we substitute `generator 0.6.x` carrying
[RUSTSEC-2020-0151](https://rustsec.org/advisories/RUSTSEC-2020-0151.html)
(`send_violation`). This yields the same bug-class delta versus the
existing smallvec + bumpalo pool — a stage2 class not previously
covered by any vendored target.

## Upstream

- **Project:** [`Xudong-Huang/generator-rs`](https://github.com/Xudong-Huang/generator-rs)
- **Tag:** `0.6.25`
- **Commit SHA:** `96885a9eb1d81d7de2eaa24dda824c1904230ece`
- **Vendoring date:** 2026-05-11
- **Original repo URL:** `https://github.com/Xudong-Huang/generator-rs.git`

## Why `0.6.25`

The RustSec advisory below was patched in `0.7.0`. `0.6.25` is the last
published release in the `0.6.x` line that still carries the
unsound `unsafe impl<A, T> Send for Generator<'static, A, T>` without a
`Send` bound on the captured generator function. (Note: RUSTSEC-2019-0020
exists for this crate but it covers a different earlier bug, fixed in
`0.6.18` — irrelevant at the `0.6.25` tag.)

| Advisory | First fixed in | First affected version |
|---|---|---|
| RUSTSEC-2020-0151 | `0.7.0` | (all 0.6.x and earlier where the impl exists) |

## Files vendored

| File | Source | Notes |
|------|--------|-------|
| `src/gen_impl.rs` | upstream `src/gen_impl.rs` at `0.6.25` | Banner comment prepended on lines 1-2 (see "Banner comment" below). All other content verbatim. This is the file containing the planted-bug `Send` impl. |
| `Cargo.toml` | upstream `Cargo.toml` at `0.6.25` | Verbatim. |
| `LICENSE-MIT` | upstream `LICENSE-MIT` at `0.6.25` | Verbatim. |
| `LICENSE-APACHE` | upstream `LICENSE-APACHE` at `0.6.25` | Verbatim. |

The rest of the crate (`src/lib.rs`, `src/rt.rs`, `src/scope.rs`,
`src/yield_.rs`, `src/reg_context.rs`, `src/detail/*.rs`, `build.rs`,
`tests/`, `examples/`, `benches/`, `CHANGELOG.md`, `README.md`) is
intentionally not vendored — only the file holding the planted bug is
required by the verifier, and the plan explicitly asks for the minimal
file set.

`src/gen_impl.rs` line count after the banner edit: original upstream
file plus the 2-line banner. The planted-bug line number in `bugs.json`
is derived from `grep -n` against the post-banner source in this
directory, so it shifts by +2 versus an unedited upstream checkout.

## Banner comment

The first two lines of `src/gen_impl.rs` (above the original module
doc-comment) are:

```
// TRIBES-BENCH STAGE 4 PHASE 1 CHUNK 1 PLANTED-BUG TARGET. INTENTIONALLY VULNERABLE
// (generator v0.6.25). NEVER COMPILE INTO PRODUCTION. See PROVENANCE.md.
```

This banner is not present upstream. It exists to make accidental
copy-paste into a production crate visibly wrong at the very top of
the file.

## License summary

The `generator` crate is dual-licensed under the **Apache License,
Version 2.0** (`LICENSE-APACHE`) and the **MIT license** (`LICENSE-MIT`)
— see `Cargo.toml`'s `license = "MIT/Apache-2.0"` field and the two
`LICENSE-*` files in this directory. Both are compatible with this
repository's Apache-2.0-leaning posture.

## RustSec advisories that apply to this snapshot

This snapshot pre-dates the fix for the advisory below. The advisory
drives the planted-bug entry in `bugs.json`.

| Advisory | Function | Class | Stage 4 bug id |
|---|---|---|---|
| [RUSTSEC-2020-0151](https://rustsec.org/advisories/RUSTSEC-2020-0151.html) | `unsafe impl Send for Generator` | `send_violation` (Send without a Send bound on the captured function — non-Send values like Rc can be sent across threads) | `S4-GENSV-001` |

The `bugs.json` entry carries a `rationale` field with the matching
RustSec ID and function name so the manifest is reviewable without
cross-referencing this file.

## Reproduction

```bash
# Snapshot reproduction (don't run inside this worktree).
git clone https://github.com/Xudong-Huang/generator-rs.git /tmp/generator-vendor
cd /tmp/generator-vendor
git checkout 0.6.25
git rev-parse 0.6.25
# Expected: 96885a9eb1d81d7de2eaa24dda824c1904230ece
```

The planted-bug line number can be re-derived against the vendored
source under this directory:

```bash
grep -n 'unsafe impl<A, T> Send for Generator' src/gen_impl.rs   # S4-GENSV-001
```

The line reported by `grep -n` against this directory's source matches
the `line` field in `bugs.json` exactly.
