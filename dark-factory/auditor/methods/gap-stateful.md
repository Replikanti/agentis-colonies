# GAP: multi-transaction invariant violations

The methods in the registry are all either (a) STATIC reads of one function/contract, or
(b) a single hand-written PoC of one hypothesis. None of them SYSTEMATICALLY searches the
space of operation SEQUENCES. So a bug that holds for every single call but breaks under a
specific interleaving of calls by multiple actors slips through.

## Evidence — a known-bug control the current methods miss
`method-discovery/controls` contains `BuggyBank`: its `transfer(to, amount)` accidentally
does `total += amount` (double-counts the accounting total on an internal transfer). Read in
isolation, `transfer()` looks fine; `deposit`, `withdraw`, `transfer` each look fine. The
solvency invariant `total == token.balanceOf(bank)` only breaks after a deposit -> transfer
SEQUENCE — exactly the kind of cross-call state corruption that a one-pass read or a single
PoC does not reliably surface, but that a stateful search over random call sequences finds in
milliseconds. A paired `SafeBank` twin (no double-count) must NOT trip the method (no false
positive) — that two-sided discrimination is the adoption gate.
