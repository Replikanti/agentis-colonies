# Mutant kill-set — invariant-hunt discrimination fixtures (#1724)

A standardized, per-`TARGET_CLASS` **mutant kill-set** for the stateful-invariant discovery track. It
turns "is this invariant any good?" from an opinion into a measurement: a good invariant must **kill**
a known-buggy mutant (the fuzzer breaks it → verdict FINDING) **and** must **survive** the clean twin
(the fuzzer cannot break it → verdict CLEAN). A vacuous ("toothless") invariant survives the mutant —
so a kill measures invariant EXPRESSIVENESS, not a rigged always-fire harness.

The runnable harness is [`../mutant-kill.sh`](../mutant-kill.sh); it drives these fixtures through the
SAME [`../forge-invariant.sh`](../forge-invariant.sh) stateful-fuzzing gate the discovery track uses,
so the verdict is the FUZZER's exit code — never an LLM opinion. Both scripts SKIP cleanly (exit 0,
`[SKIP]`) when `forge` is absent, exactly like `demo-invariant-hunt.sh`.

## Directory layout

```
mutants/
  manifest.tsv                     # the kill-set index (one row per contract×invariant pair)
  README.md                        # this file
  C-erc4626/                       # one directory per TARGET_CLASS
    Vault.base.sol                 # CLEAN twin           (contract fixture)
    Vault.mutant-donation.sol      # MUTANT: donation/inflation bug (contract fixture)
    inv_victim_not_robbed.t.sol    # GOOD invariant       (invariant fixture)
    inv_toothless.t.sol            # TOOTHLESS control    (invariant fixture)
  C-accounting/
    Lending.base.sol               # CLEAN twin
    Lending.mutant-rounding.sol    # MUTANT: inverted-rounding accounting drift
    inv_debt_backed.t.sol          # GOOD invariant (solvency)
    inv_toothless.t.sol            # TOOTHLESS control
```

## Manifest format (`manifest.tsv`)

Tab-separated, one row per `(contract-fixture, invariant-fixture)` pair with its expected verdict:

```
class  contract-fixture  invariant-fixture  expected(KILLED|SURVIVED)  note
```

- Fixtures resolve as `mutants/<class>/<file>` (basenames in the row).
- `expected` is `KILLED` (the invariant broke on this contract → FINDING) or `SURVIVED` (held → CLEAN).
- Blank lines and `#` comments are ignored.

Each class encodes a three-way **discrimination** self-test: `good × mutant = KILLED`,
`good × base = SURVIVED`, `toothless × mutant = SURVIVED`.

## The STABLE-CONTRACT-NAME rule

Every contract fixture in a class declares the **same** `contract <Name>` (e.g. `Vault`, `Lending`) and
the **same** public ABI, so a single invariant test drives the base twin and every mutant unchanged. The
harness stages the chosen contract fixture to `src/Target.sol` in a throwaway foundry project, and every
invariant fixture imports it as `../src/Target.sol` (never its own same-named shadow — the #1471
target-linkage discipline). Only the buggy internals differ between base and mutant; the surface the
invariant sees is identical.

Fixtures are **forge-std-free** and self-contained: they register their fuzz targets via a
`targetContracts()` view (the StdInvariant ABI forge auto-discovers) and assert with plain `require(...)`,
so they compile in any foundry project with zero library remappings. All carry `pragma solidity ^0.8.20;`,
matching the [`../contracts/`](../contracts) fixtures.

## How to add a class

1. `mkdir mutants/C-<name>/`.
2. Add `<Name>.base.sol` — the CLEAN twin: correct code, `contract <Name>` + the public ABI the
   invariant drives.
3. Add one or more `<Name>.mutant-<bug>.sol` — same `contract <Name>` + ABI, one seeded bug that only a
   MULTI-STEP call sequence exposes (the class the stateful fuzzer is for).
4. Add `inv_<property>.t.sol` — the GOOD invariant: a `Handler` exposing the actions with `_bound`ed
   inputs, a `targetContracts()` view, and one `invariant_*` function that formalizes the protocol
   property. Import `../src/Target.sol`.
5. Add `inv_toothless.t.sol` — a deliberately VACUOUS `invariant_*` (e.g. `require(x >= 0)` on a uint),
   same handler shape and import.
6. Append the rows to `manifest.tsv`: `good×mutant=KILLED`, `good×base=SURVIVED`,
   `toothless×mutant=SURVIVED`.
7. Run `../mutant-kill.sh --self-test` (needs `forge`) to confirm every row's verdict matches `expected`.

The design of the bug and the tightness of the invariant are the whole point: make the good invariant
genuinely tight enough to kill the mutant, and the toothless one genuinely vacuous, so the discrimination
is real. Reason carefully about the `_bound` ranges — the fuzzer must be able to reach the breaking
sequence.
