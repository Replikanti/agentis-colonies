// Two-sided-gate negative-test fixture: a DELIBERATELY RIGGED PoC harness.
//
// It screams the `INVARIANT VIOLATED:` sentinel UNCONDITIONALLY and has NO control
// path — it never builds an authorized signer, never calls withdraw() on the legit
// case, and never proves it can accept anything. A naive "sentinel present => verified"
// gate would mark this VERIFIED (a false positive). The two-sided assess() gate
// MUST classify it `inconclusive:no-control` because the `CONTROL OK:` marker is absent.
//
// Exercised by pointing the colony at it: BOUNTY_POC=.../rigged_harness.rs agentis go ...
// Expected: `Verdict: INCONCLUSIVE (inconclusive:no-control)` — panic != verified.
//
// std-only so it compiles + runs offline with plain `rustc`.

include!("target.rs");

fn main() {
    // No control. No exercise of the target. Just an unconditional scream.
    let _ = withdraw; // reference the target so the include isn't dead, but never call it discriminatingly
    eprintln!("INVARIANT VIOLATED: rigged harness fired without exercising the target");
    std::process::exit(101);
}
