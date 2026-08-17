# Dark Factory — stateful-invariant-fuzzing verdicts

- backend: flat-cyborg
- The LLM HYPOTHESIZES (writes the handler + the deep invariants); the FUZZER JUDGES (the verdict is
  its exit code over randomized multi-call sequences, never the LLM's opinion). FINDING = an invariant
  broke under a concrete SHRUNK call-sequence (a CANDIDATE with a reproducible witness); CLEAN = every
  invariant held across the fuzzed search (no finding in this budget, NOT a proof); HARNESS_ERROR is
  not a verdict. A FINDING is a LEAD a human triages — this colony NEVER auto-submits.

| Target | Class | Handler | Verdict |
|---|---|---|---|
| pkg/vault/contracts/Vault.sol | SYS-solvency | generated(LLM) | FINDING |

## Shrunk exploit call-sequence (the fuzzer's reproducible witness)

```
setHookFee(18413)  [sender=0x0000000000000000000000000000000000000533]
swapExactIn(30071341427582034436683112828988167624610892816689921058961, true, true)  [sender=0x0000000000000000000000000000000000005360]
```

A human triages this candidate before any submission. This colony never posts.
