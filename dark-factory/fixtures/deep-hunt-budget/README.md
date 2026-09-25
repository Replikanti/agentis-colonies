# deep-hunt-budget fixtures (#2258)

Canned `forge test --json` outputs in the forge 1.x diagnostic format (captured shape: forge 1.7.1 prints the rich
solc diagnostic on stdout and the terse `Error: Compilation failed` on stderr). `demo-deep-hunt-budget.sh` serves them
through a fake `forge` on PATH to pin `evm-harness/forge-invariant.sh`'s compile-scope diag row:

| file | expected scope |
|---|---|
| `target.stdout` | `target` — the only error location is in the target source |
| `harness.stdout` | `harness` — the error is in the harness; the `Note:` pointer into the source is not an error location |
| `mixed.stdout` | `mixed` — one error in the source, one in the harness |
| `warn-harness.stdout` | `harness` — a warning in the source is ignored, the error is in the harness |
| `unlocated.stdout` | `unlocated` — a compile failure with no `-->` location (solc version resolution) |
| `compiled.stdout` | `compiled` — a parseable suite, no compile-error signature |

`failed.stderr` is the stderr of every failing case.
