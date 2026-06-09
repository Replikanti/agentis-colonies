# solana-harness — offline Solana PoC harness (Dark Factory)

A `solana-program-test` + `BanksClient` crate that runs a generated proof-of-concept
against a real Solana program through the **real `solana-runtime` SVM** (real account
model, signer/owner checks, lamport conservation, CPI) — compiled with **stable rustc,
no SBF platform-tools** via the native `processor!()` path. This replaces the std-only
`rustc` harness so a PoC exercises genuine Solana semantics, not hand-rolled stubs.

## How the colony uses it

Per audit the auditor colony overwrites two files, then builds + runs offline:

- `src/target.rs` — the in-scope program under audit (a native Solana processor
  exposing `pub fn process_instruction(&Pubkey, &[AccountInfo], &[u8]) -> ProgramResult`).
- `src/bin/poc.rs` — the LLM-generated **two-sided** PoC. It must print `CONTROL OK:`
  for the authorized/signed path, print `INVARIANT VIOLATED:` to stderr for the
  unauthorized path that breaks the safety invariant, and call `std::process::exit(101)`
  on violation. The colony's `assess()` gate keys on both markers (the two-sided
  contract), so the same PoC yields a non-VERIFIED verdict against a *secure*
  program (the unauthorized path is rejected → `invariant held`) — no
  false-VERIFIED.

```
CARGO_NET_OFFLINE=1 cargo run --quiet --bin poc --offline
```

The committed defaults (`src/target.rs` = a MissingSignerCheck vault, `src/bin/poc.rs`
= the matching two-sided exploit) make the harness self-verifying out of the box.

## Offline contract

`.cargo/config.toml` pins `net.offline = true` and `OPENSSL_NO_VENDOR = "1"` (link the
system OpenSSL rather than building it from vendored C source, which needs `perl-FindBin`
and is unnecessary). `Cargo.lock` is committed; the ~711-crate graph + ~3 GB warm target
are produced once by `../setup-solana-toolchain.sh` (network on) and then every build is
fully offline.

## Hardened sandbox

The hardened exec profile is `bwrap --unshare-all --ro-bind / / --tmpfs /tmp
--tmpfs /run --bind <workspace> <workspace>`: the rustc toolchain, the `~/.cargo`
registry cache, and the system OpenSSL `.so` are all **readable** inside; the network is
closed; only the workspace is writable. The warm target dir therefore must live under the
sandbox workspace (that is what `setup-solana-toolchain.sh` stages at
`$WORKDIR/.solana-harness`) so cargo can write incremental artifacts. Verified end-to-end:
the default PoC compiles incrementally and fires both markers (`exit 101`) under the exact
hardened mask with the network namespace unshared.

## Scope (v2)

This milestone delivers the toolchain + the real-SVM execution path. Turning an *arbitrary*
ingested program into a harness-compilable native target is detection's job (generalized
detection on real Anchor); calibration against real `coral-xyz/sealevel-attacks` Anchor
programs is a later milestone.
