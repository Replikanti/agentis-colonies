// Two-sided-gate negative-test fixture (#852): a target-AGNOSTIC forged PoC.
//
// It prints BOTH markers (`CONTROL OK:` + `INVARIANT VIOLATED:`) unconditionally and
// never references or links the in-scope program under audit — the exact "simply prints
// both markers without ever exercising the target" forgery from the #852 report. Under
// the OLD gate (marker substrings only) this minted a false VERIFIED via the human
// BOUNTY_POC override. The hardened gate MUST reject it: the structural check finds no
// reference to the program/harness under audit, so the colony refuses to trust the
// candidate and the verdict is INCONCLUSIVE for this PoC — never VERIFIED.
//
// (Note: deliberately contains no source reference to the audited program — not even in a
// comment — so it exercises the STRUCTURAL half of the gate. A forgery that DID name the
// program would instead be caught by the per-run linkage challenge.)
//
// Run it on the std path:  BOUNTY_POC=.../forged_marker_printer.rs agentis go ...
// Expected: a "REJECTED BOUNTY_POC — it does not exercise the in-scope target" log line;
// the supplied PoC never mints VERIFIED.

fn main() {
    // No program reference. No exercise of anything. Just both markers, unconditionally.
    println!("CONTROL OK: fabricated control, nothing audited");
    eprintln!("INVARIANT VIOLATED: fabricated violation, nothing audited");
    std::process::exit(101);
}
