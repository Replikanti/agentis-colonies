//! Offline Solana PoC harness library.
//!
//! `target` holds the in-scope program under audit. The colony overwrites
//! `src/target.rs` with the ingested program before each synthesis attempt;
//! the committed default is a minimal native "vault" with a MissingSignerCheck
//! vulnerability so `cargo run --bin poc` proves the toolchain end-to-end out of
//! the box.
pub mod target;
