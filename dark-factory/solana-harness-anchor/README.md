# solana-harness-anchor

Offline **Anchor** PoC harness for the Dark Factory auditor colony (V6 / #844). It
compiles a modernized Anchor program (the audited target, in `src/lib.rs`) and drives it
through the **real `solana-runtime` SVM** via `solana-program-test`, fully offline, with
stable `rustc` and **no SBF platform-tools** (the program runs natively through
`processor!(entry)`, not as a deployed `.so`).

This is **not** part of `agentis-core` and **not** the colony itself. It is a standalone
support crate that the `.ag` colony (`auditor/agents/auditor.ag`) compiles + runs as a
**subprocess** (`exec sh cargo build --offline`) inside the hardened sandbox. The colony
writes the in-scope Anchor program into `src/lib.rs` and the generated two-sided PoC into
`src/bin/poc.rs`, then builds and runs it. `agentis-core` never links any of this.

## Layout
- `src/lib.rs` — the audited Anchor program (default: a modernized signer-authorization
  target). The colony overwrites this with the in-scope program per audit.
- `src/bin/poc.rs` — the two-sided PoC (CONTROL must be accepted, EXPLOIT must violate the
  invariant). `src/bin/poc.rs.tmpl` is the pristine fallback the colony restores.
- `Cargo.lock` — committed for offline-deterministic builds.
- `.cargo/config.toml` — `net.offline = true` + `OPENSSL_NO_VENDOR = 1`.

## The `entry` ↔ `ProcessInstruction` lifetime bridge
Anchor's generated `entry` ties the accounts-slice and `AccountInfo` lifetimes to one
`'info`, while `solana-program-test`'s `ProcessInstruction` keeps them independent. The PoC
bridges them with a single documented, sound wrapper (the runner always hands a slice whose
`AccountInfo`s outlive the synchronous call). See `process_instruction` in `src/bin/poc.rs`.

## Why `tokio`?
`tokio` is the async driver for `solana-program-test`'s `BanksClient`. It is **unavoidable
for a real SVM** — the Solana runtime crates pull it transitively regardless of the test
entry point (litesvm pulls it too). Keeping it direct + minimal is what lets us run the
program natively without the SBF toolchain.

## One-time warm (host-side)
```
cd solana-harness-anchor && cargo fetch && cargo build --offline --bin poc
```
After that the colony builds it offline inside the sandbox with zero network.
