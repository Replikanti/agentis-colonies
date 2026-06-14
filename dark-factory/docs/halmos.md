# Halmos symbolic-execution verification gate (#1015 M1)

`evm-harness/halmos-verify.sh` is the **sound, exhaustive** verification gate for the discovery track.
Given a `*.t.sol` spec that asserts an invariant over symbolic inputs, [Halmos](https://github.com/a16z/halmos)
(symbolic execution + the z3 SMT solver) either **PROVES the property holds for every input**, or returns a
**concrete counterexample input that violates it**. There is no fuzzing, no sampling, and no flakiness: on a
clean verdict the correctness is the solver's, not a heuristic's.

This is the symbolic sibling of [`evm-harness/forge-verify.sh`](../evm-harness/forge-verify.sh). The two
are complementary oracles:

| Gate | Method | What a pass means |
|---|---|---|
| `forge-verify.sh` | EXECUTION — runs one concrete PoC tx | this *one* path breaks the invariant (a witnessed exploit) |
| `halmos-verify.sh` | SYMBOLIC — runs z3 over ALL inputs | the property holds for *every* input, or here is a concrete counterexample |

`halmos-verify.sh` does not replace `forge-verify.sh`; it is an **additional** sound oracle.

## How it fits the epic

The discovery colony's LLM **hypothesizes**: it reads a protocol and proposes an invariant and a sketch of
how it might break. An LLM proposal is, on its own, unverified — it can hallucinate both the bug and the
fix. Halmos is the **sound verdict**. When a candidate is routed to a Halmos-gated check, the system's
correctness on that check is *Halmos's*, not the LLM's: a `PROVED` is a real proof over all inputs, and a
`COUNTEREXAMPLE` is a concrete witness a human can replay. The LLM's job shrinks to *writing the spec*; the
truth of the answer is the solver's.

**Scope of M1 (be honest):** this milestone ships the **callable gate only** — the script, two example
specs, and an offline demo. Auto-routing discovery candidates into it (generate-a-spec-and-verify, closing
the loop from prose lead to symbolic proof) is a **later milestone**. Today a human or a higher-level script
invokes the gate with a hand-written or generated `*.t.sol`.

## Verdict / exit contract

```
halmos-verify.sh --repo <foundry-project-root> --target <Spec.t.sol>
                 [--function <prefix>] [--timeout <seconds>]
```

- `--repo` — a Foundry project root (must contain `foundry.toml`).
- `--target` — the `*.t.sol` spec, absolute or relative to `--repo`.
- `--function` — the symbolic-test name prefix Halmos runs (default `check`). By convention `check_*`
  functions assert the invariant directly over their symbolic arguments.
- `--timeout` — per-assertion solver timeout in seconds (default `60`); passed to Halmos as
  `--solver-timeout-assertion`.

The gate parses Halmos's `Symbolic test result: N passed; M failed` summary (Halmos's own process exit code
is not a reliable verdict signal) and prints a
`================ HALMOS-VERIFY: <VERDICT> ================` banner to stderr:

| Verdict | Exit | Meaning |
|---|---|---|
| **PROVED** | `0` | `M failed` == 0 and `N passed` >= 1: the property holds exhaustively over all inputs. |
| **COUNTEREXAMPLE** | `1` | >= 1 `failed` / a `Counterexample:` block: a concrete input violates the property — a real bug. |
| **INCONCLUSIVE** | `3` | solver `unknown` / a path timed out / an unbounded loop / no functions matched: no sound verdict. |
| **harness/usage** | `2` | bad args, `--repo` is not a Foundry project, or `halmos`/`forge` is not installed. |

`INCONCLUSIVE` is deliberately distinct from `PROVED`: a timeout or an `unknown` from the solver is *not* a
proof. The gate only reports `PROVED` when the solver decided every path.

## Install the toolchain

The gate resolves `forge` and `halmos` via `PATH` (it hardcodes no install location). Both must be present:

```bash
# Foundry (provides forge, which Halmos drives for compilation)
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Halmos (bundles z3)
uv tool install halmos
```

Requires **halmos >= 0.3** and **foundry** (forge). CI runners have neither, so the demo SKIPs cleanly
there (see below).

## Example specs + offline demo

`evm-harness/halmos-specs/` is a minimal, self-contained Foundry project (no external libs):

- `src/Ledger.sol` — a two-account ledger with an honest `transferSafe` and a buggy `transferBuggy` that
  forgets to debit the sender when the transferred amount equals the balance (it mints value).
- `test/LedgerProved.t.sol` — asserts value conservation against `transferSafe`. Halmos **PROVES** it
  (`Symbolic test result: 1 passed; 0 failed`) → `PROVED`, exit 0.
- `test/LedgerCounterexample.t.sol` — the same invariant against `transferBuggy`. Halmos **REFUTES** it with
  a concrete `(from, to, amount)` witness (e.g. `from = amount = 0x80, to = 0x00`) → `COUNTEREXAMPLE`,
  exit 1.

Balances are `uint8` so the symbolic search returns a sound verdict in a couple of seconds.

`dark-factory/demo-halmos.sh` runs the gate against both specs and asserts the contract (PROVED/exit 0 on
the first, COUNTEREXAMPLE/exit 1 on the second). Halmos is deterministic, so a real run *is* the
deterministic proof — there is no mock. If `halmos` or `forge` is not on `PATH`, the demo prints a single
`[SKIP]` line and exits 0 (mirroring the colony-lint skip convention) so CI passes without the tools.

```bash
# with the toolchain on PATH
dark-factory/demo-halmos.sh
#   [OK]   true invariant (transferSafe conserves value) -> PROVED (exit 0)
#   [OK]   planted bug (transferBuggy mints value) -> COUNTEREXAMPLE (exit 1)

# verify a single spec directly
dark-factory/evm-harness/halmos-verify.sh \
  --repo dark-factory/evm-harness/halmos-specs \
  --target test/LedgerProved.t.sol
```
