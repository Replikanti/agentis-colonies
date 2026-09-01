# Building a federation `.ag`-first

Every claim here comes from this repository's own record: 1,329 commits mined for
migrations, 98 production `.ag` files (60,204 lines) surveyed for idioms, and a
battery of programs run against agentis 1.28.0 to characterise the runtime. Where
a rule has an incident behind it, the incident is named. Where something is
source-read rather than executed, it says so.

It is organised around **decisions** and **traps**, not syntax. The syntax is in
`agentis-core/docs/language.md`; what is not written down anywhere is which side
of the boundary a line of code belongs on, and what will silently do the wrong
thing after it compiles.

---

## 1. The one question

You are not choosing between agentis and shell, any more than a Rust program
chooses between Rust and `git`. Calling an external tool is normal. Putting your
program's *logic* in the string you hand that tool is the mistake, and it is easy
to make because both look identical:

```
grep -F "gene_name \"BUB1B\"" ann.gtf | grep -P '\tgene\t' | head -1
└──────────── calling a tool ────────────┘ └──── your program deciding ────┘
```

So, before writing any `exec sh`:

> **Does this shell command choose, rank, truncate, or classify?**
> If yes, that part is the decision surface and it does not go in the pipe.

This is the highest-yield question in the guide. The same class of mistake was
found **seven times** across two federations over four months, and in one file the
same person re-found it three separate times. In every instance the wrong answer
was silent and plausible.

A useful sharpening: **normalisation may happen in shell; judgement may not.**
Lowercasing a label is normalisation. Matching it against a set is judgement.
That line resolved the cleanest case in the record ([PR #2071]).

---

## 2. Narrow outside, decide inside

The rule is not "never shell out". It is:

- **Outside:** bulk mechanical work — narrowing millions of records to hundreds,
  running a real tool (`bcftools`, `cast`, `forge`, `git`), producing an effect.
- **Inside:** which of those records is authoritative, how they are ordered, what
  counts as a match, what the threshold is, and what to do when the answer is
  ambiguous.

### State the threshold as a number

`grand-rounds/baseline/agents/pipeline.ag` is the only place in the corpus where
the boundary is justified with a measurement rather than an adjective:

> Measured on GENCODE v45 before moving the boundary: BUB1B 168 lines, CEP57 265,
> TRIP13 75, CENATAC 119 — exactly one `gene` row each. That sits inside the
> documented tens-to-hundreds limit, which is why the narrowing stays external
> and the row selection moved in.

Do the same. "A few rows" is not a boundary; 265 is.

### Instrument the boundary so it cannot drift

The same file writes a per-stage row count to `stage-rows.tsv` (`record_rows()`)
and asserts it in tests. That turns "no bulk stream enters `.ag`" from a comment
into a regression guard. Copy the idea.

### Truncation is a decision, not a guard

`head -200` looks like it is protecting the boundary. It is also deciding what is
invisible: a gene ranked past the window cannot be ordered. Four such literals sat
in shell strings until they became `exo_variants_window()` and
`exo_genes_window()` in `.ag`. If a number changes results, it belongs where the
results are decided.

### Worked examples from the record

| What was in shell | Why it was wrong | Became |
|---|---|---|
| `grep -P '\tgene\t' \| head -1` | picks which GTF row *is* the gene, and which wins when several match | `first_gene_row()` scans the narrowed lines in `.ag` |
| `bcftools query -l \| head -1` | picks the proband from however many samples a VCF holds — silently attaching one person's identifier to another's variants | `sole_sample()`, which says so loudly when there is more than one |
| `... -r chr:pos-pos \| head -1` | picks *which allele's* population frequency stands for a candidate — in the code path whose only job is deciding whether to refute it | `.ag` sees every row; several ⇒ unassessable, and it prints why |
| `fn_names(f)[:8]` | selects which functions the classifier sees, by file order | measured live: the eight selected were all admin setters; the vulnerable functions were never shown, and the model classified correctly when given them un-sliced |
| shell `case` computing an action's outcome | the shell owned the verdict | migrated in three declared stages: decide → dispatch → outcome |

### When `head -1` is fine

Scalar extraction where the pattern matches once **by construction**: a count out
of a tool's stats output, an "is there at least one record" test, a single
configured value. The distinction is whether more than one match is *possible*,
not whether you have seen one.

And a warning from the same file: a guard built on a shell `grep` over another
tool's prose had **never fired** — its pattern did not match anything `bcftools`
actually writes. Where a summary line *did* match twice, `head -1` could take the
`0` from "Checked 0 ref mismatches" while a later line reported 12. A guard that
fails open is a guard that has never run. Mutation-test every guard.

---

## 3. Moving work in is not free

A guide that only says "move it into `.ag`" reproduces the next bug. **Four
incidents in this repository were caused by the migration itself**, not by the
shell it replaced.

CB is charged per language-level operation. An `exec sh` call is a **flat-cost
black box** — roughly 20-28 CB regardless of how much work the subprocess does
inside. A native pipeline pays **per element**. So a rewrite is only cheaper when
the element count is small.

Measured on agentis 1.28.0 (differencing N=100 against N=1000 to cancel fixed
overhead; linear to the CB across both decades):

| Shape | CB per element |
|---|---|
| bare recursive loop | 13 |
| recursive build via `push` | 19 |
| recursive walk `get(xs,i)` | 22 |
| `map` / `filter` | **7** |

The default budget for `agentis go` is **10,000** — about **450 iterations** of a
trivial loop. A hand-rolled walk over 1,000 elements costs ~22,000 CB, more than
twice that.

Incidents:

- A native rewrite measured **4.7× over** the agent's own `cb_budget` on live data
  (2,807 CB against a budget of 600), on an input that grows by one element per
  release. The PR had claimed "strictly cheaper CB"; the risk assessment had used
  the 2,000 daemon *fallback* rather than the configured budget, and got the
  direction backwards.
- The same trap re-appeared twice more in the same campaign, once in the fix.
- A row selection moved into `.ag` made a helper ingest 75-265 lines **per record**
  instead of one — ~5,495 CB per call, aborting at record 138 of 500. Real input
  would have died with a runtime error and no output.

**Before moving a loop in:**

1. Measure against the agent's own `cb <N>;` literal, not the daemon default.
2. Use the input size the data will reach in a year, not today's.
3. Prefer **one array builtin** over a `map`/`filter` walk, and a `map`/`filter`
   over hand-rolled recursion — the ordering is 1 : 7 : 22.
4. If the work is irreducibly per-element and large, leaving it outside is the
   correct answer. Say so in a comment, with the number.

---

## 4. Traps that pass `agentis commit`

`agentis commit` is a parser plus an **advisory** typechecker. Type errors print
`warning:` and execution proceeds. Return-type annotations are not checked at all:
`fn f(x: int) -> string { return x; }` commits and runs clean. Everything in this
section compiles.

### 4.1 The five that change your design

**`print` output is discarded entirely on an uncaught error.** Fifty lines emitted
before a crash produce **zero** lines on stdout. `--trace` does not help. This
silently destroys "add prints and see how far it got", and a crashed tick leaves
no record of what it was doing. Output survives if the error is *caught*.
**Use `file_append("trace.log", ...)` for progress** — filesystem effects survive.

**There are no loops and no reassignment.** `while`, `for` and `i = 5` are parse
errors. Recursion is the only iteration and the frame limit is **4096** (usable
depth 4094), so **you cannot iterate over more than ~4094 items recursively, ever,
regardless of budget** — a 4,200-element build dies with 89.9M CB unspent.
`map`/`filter`/`reduce` do not consume frames and are the only option above that.

The depth error is also mislabelled: it reports as `CognitiveOverload` with
`required 0` while millions of CB remain, prints the entire 4,096-frame stack
(57-168 KB), and its `at:` line names whatever call sat on the boundary — often a
builtin, not your recursion. **The real message is always the last two lines.**

**`decide()` with no backend deterministically returns `options[0]`.** The default
config ships `llm.backend = mock`, and *deleting the line still selects the mock*.
Nothing errors: `prompt(...) -> string` returns `"mock"`, `-> int` returns `0`,
and `decide()` falls through to the first option. A misconfigured federation does
not crash — **every gate takes its first branch forever, confidently**. This is
why the convention is *argmax first, `decide()` second*: score and order the
options from facts, then call `decide()` on the already-ranked list, so the
offline behaviour degrades to "take the best" rather than "take the first listed".

**`exec sh`'s "sandbox" is a working directory, not confinement — on the
default profile.** Cwd is `.agentis/sandbox`, but `ls ..` reaches the object
store and `.agentis/identity/` — the key material — and absolute paths
anywhere on the filesystem work. That is still exactly true for `basic` (the
default), `no-net` and `no-fs-write`: none of the three own a mount namespace,
so none confine reads. As of v1.29.0, `strict` and `hardened` tmpfs-mask
`<state>/identity` fail-closed (abort rather than run with the signing key
exposed) — set `exec.sandbox_profile = strict`/`hardened` if a federation
needs the identity dir hidden from its own exec children. macOS and any host
with unprivileged user namespaces disabled stay unconfined on **every**
profile, `strict`/`hardened` included. ([agentis-core#966], v1.29.0)

**`cb N` inside an agent escapes the enclosing budget.** It assigns absolutely
rather than drawing down, so a top-level `cb` gives *zero* protection against a
runaway agent. Worse, the trace line `[agent X] entered, CB=40` shows the
**parent's** remaining, which reads as if the agent were constrained. Budget
control must be per-agent.

### 4.2 Silent wrong answers

- **`parse_int("abc")` returns `0`**, not an error — indistinguishable from
  `parse_int("0")`. Same for `parse_float`. Validate first:
  `if regex_match("^-?[0-9]+$", trim(s)) { parse_int(s) } else { -1 }`.
- **`substring` and `len` are byte-indexed.** A one-byte slice inside a UTF-8
  sequence returns `""`, and `index_of(haystack, "")` is `0` — so a character-class
  validator built from `index_of(allowed, c) >= 0` **accepts all non-ASCII while
  correctly rejecting ASCII**, which is exactly the shape that survives review.
  Use a whole-string `regex_match("^[a-z0-9_-]+$", s)`, or reject `c == ""`
  explicitly.
- **`mod(-7, 2) == -1`** (sign follows the dividend) and a negative list index
  wraps to `18446744073709551615`. `get(xs, mod(h, n))` is a landmine for negative
  `h`.
- **Integer division truncates toward zero** and **overflow wraps silently**.
- **`to_string(["a, b"]) == to_string(["a","b"])** — the list rendering is a
  display format, lossy and not re-parseable. Use the `json_array_*` family.
- **`getenv` returns `""` identically** for unset, not-allowlisted, and
  force-denied. `HOME`, `PATH` and `AGENTIS_*` are denied **even when explicitly
  allowlisted**. A misspelled allowlist entry is indistinguishable from a knob
  deliberately left unset.
- **`emit` to a misspelled channel succeeds and drops silently.** At
  `max_queue_depth` the bus pops the *oldest* message and increments a counter,
  with no error. (Source-read.)

### 4.3 Things that are hard errors, so guard them

`get(map, missing_key)`, `get(list, out_of_range)`, `file_read(missing)`, and an
undeclared struct field all raise. There is **no `get(m, k, default)`** and no
`has_key`. Use `try { get(m,k); } catch e { "DEFAULT"; }`, or `file_exists()`.

`try`/`catch` catches missing keys, bad indices, undefined functions, string
ordering, **and even the frame-depth limit**. It does **not** save you from CB
exhaustion — the handler needs budget and re-raises immediately.

### 4.4 Names that do not exist

An unknown name typechecks as `Any` and fails only at runtime with
`undefined function`. There are 253 builtins; the language doc covers about 50.

Plausible but absent: `to_upper` (yet `to_lower` exists), `split`, `join`, `sort`,
`contains`, `min`, `max`, `abs`, `to_int`, `has_key`, `panic`, `assert`, `slice`,
`first`, `last`. The real names are `regex_split`, `sort_strings`,
`sort_unique_strings`, `abs_int`, `min_int`, `max_int`, `parse_int`, `parse_float`,
`typeof`.

**Detection trick:** call the name with zero arguments. `undefined function: X`
means it is not a builtin; `arity mismatch: expected N args` means it is, and you
get its arity for free.

The same defaulting means **redefining a real builtin also passes silently** —
`trim` is shadowed in four files and `to_lower` in two, each dragging in
hand-rolled helpers for something the runtime already does.

### 4.5 Syntax that bites

- **No infix boolean operators.** `||`, `or` and `&&` each fail differently. The
  idiom is **`if` as an expression**: `let both = if a { b } else { false };`
  A missing `else` yields `void`, not `false` — never rely on it in a boolean
  position.
- **`else if` does not parse.** Nest: `} else { if cond { ... } else { ... } }`.
  64 files use the nested form; only 7 use `else if`.
- **There *is* a list literal** — `[]` and `[1,2,3]` work. An empty literal infers
  `List<Any>`, so an explicit `list<string>` annotation warns and then runs anyway.
- **Lambdas need annotated parameters, a return type, and a block**:
  `filter(xs, |x: string| -> bool { return false; })`.
- **`"n=" + 5` is a hard type error.** Use `to_string()`, or `print` (variadic).
- **String `<` is a runtime error** whose message reads *"got string and string"*,
  which sends you hunting for a type problem that is not there. Use
  `sort_strings`.
- **`${...}` inside an `exec sh` string is agentis interpolation, not shell.**
  Bare `$VAR` reaches the shell; `${VAR}` is resolved against `.ag` scope and
  inserted **unquoted**. Pair every dynamic value with `shell_escape()`.
- **`exec argv [...]` sidesteps the trap above entirely (v1.29.0,
  [agentis-core#963]).** `exec argv ["prog", arg1, arg2]` — optionally `exec
  argv json timeout <ms> [...]` — hands the vector to the OS as-is: no word
  splitting, no globbing, no `$VAR`/`|`/`;`/backtick expansion. There is no
  interpolation to guard against, so `shell_escape()` on an `argv` element is
  wrong, not just redundant — it adds literal quote characters to what the
  program receives. `exec sh` + `shell_escape()` stays correct for anything
  that genuinely needs a shell: pipes, redirection, globs.
- **Comments are `//` only.** `#` is a lexer error.
- **The entry point is top-level statements.** A file whose whole body is
  `fn main()` runs, prints nothing, and exits **0**.

---

## 5. Idioms that are house style

**The tick and the tier ladder.** 70 of 98 production files define
`fn tick(reason: string) -> void` and nothing else at top level. One `tier()` call,
four branches, fall through to shadow. `tier()` is a builtin.

**One-shot pipelines** use `agent` blocks called in sequence as plain functions
after the top-level statements seed the bus and memos. Seed every memo key you
will later `recall_latest()` — a missing key returns `Void`, which stringifies to
`"void"` and crashes `len()`.

**Total helpers over `try`/`catch`, when the failure is yours to name.** Two
philosophies coexist: 769 `try` blocks with a neutral default (`catch e { ""; }`
appears 437 times), versus making every helper total and refusing loudly with a
named reason:

```rust
if gtf_present != "yes" {
    print("coordinator: ERROR — MVA_GTF does not exist: ", gtf, " Refusing: gtf-missing");
    memo_write("baseline:abort_reason", "gtf-missing");
    emit("baseline:abort", "gtf-missing");
    return;
}
```

25 distinct named abort reasons in one file. Prefer this where an operator needs
to know *why*; the abort memo survives the print buffer being discarded (§4.1).

**Argmax first, `decide()` second** — see §4.1.

**A canary before adopting an evolved prompt:** run the candidate against a
fixture, check every field of the returned struct is non-empty, `catch → false`.

**Mechanical extraction does not go through the LLM.**
`parse_int(to_string(json_get(raw, "[0].iid")))` is total on every failure mode
and one round-trip cheaper than asking.

---

## 6. What you will have to write yourself

Every entry is a missing builtin, ranked by how many times this repository has
independently reimplemented it.

| Missing | Definitions | Note |
|---|---|---|
| field/column accessor | 39 | Four incompatible designs. **`field(line,-1)` returns the first field; `nth_field(s,sep,-1)` returns `""`** — porting between them changes behaviour silently. |
| total `listen()`/`recall_latest()` | 10 | Six different names for the same Void normaliser; one diverges semantically. |
| `join` | ~21 | Eleven names across five federations. |
| self-identity (`self_name`, `self_addr`) | 29 | `colony_name()` and `tribe_name()` are the same function. |
| membership test | 13 | |
| `replace_all` | 5 | `regex_split` cannot substitute when the needle has metacharacters. |
| `take(list, n)` / top-K | 8 | |
| zero-pad / format | 3 | Two of the three hard-code their width. |
| ISO-8601 → epoch | — | Worked around in two opposite ways; one federation **abandoned a feedback signal** rather than add an interpreter. |
| `exec sh` exit status | 32 | `; echo __rc=$?` then regex it back out. |
| stderr print | — | |

**No longer missing, as of v1.29.0:** `confidence_value()` ([agentis-core#967])
is now a builtin — the row that used to sit here counted the ~70 hand-copied
`get_confidence()` definitions it replaces, migrated to the builtin in
agentis-colonies #2092. It is a read-only diagnostic/logging call; branching
still goes through `tier()`, never `confidence_value()`.

Before writing one of these, check it is still missing. **146 `exec sh "printenv X"`
calls exist on the premise that "agentis 1.6.0 has no getenv builtin"** —
`getenv()` has 577 uses elsewhere in the same repository. Stale workarounds
outlive their reason and propagate by copy.

---

## 7. Write the ratchet

The one thing here that generalises without judgement.

One federation has **zero** `git`, `gh`, `date`, `jq`, `awk`, `sed`, `grep`,
`head`, `curl` or `test` in any `exec sh` string, while talking to two forge APIs
and editing real git checkouts. The cause is not care. It is a lint with two
finding classes:

- `[NEW-ESCAPE]` — a new violation fails.
- `[STALE-ALLOWLIST]` — an allowlist row whose site was already fixed *also*
  fails, so pruning is forced.

Together those give the **shrinking-debt property**: the debt can only go down,
and CI stays green throughout. That federation's allowlist is now empty.

Where the escape is a dynamic argument rather than shell logic, `exec argv
[...]` (v1.29.0, [agentis-core#963]) is the structural fix, not another
allowlist row: no shell at all, so no interpolation and no `shell_escape()`
to get right.

Two cautions from the record:

**Scope it repo-wide, or the fix will not travel.** That lint is hard-coded to one
federation. The escape hatch it purged is still live in **57 places** elsewhere —
including `templates/`, which is what the scaffolder copies, so every new colony
inherits it. A federation-scoped lint does not prevent the mistake; it prevents
*that federation* from repeating it, while the mistake keeps arriving through
`new-colony.sh`. ([#2083])

**Mutation-test the guard itself.** A leak-guard mutation assertion in this repo
ran `bash "$GUARD" ...` and read *any* non-zero exit as "the guard fired". A
missing script exits 127, so a bundle shipping **no guard at all** printed
`[ok] fails on a planted leak`. A test that could not fail, asserting that a
guard could not fail — dead for the life of the release. When you write a guard,
break it on purpose and confirm the test goes red.

---

## 8. A checklist

Before you write `exec sh`:

- [ ] Does this command choose, rank, truncate, or classify? Then split it.
- [ ] Is the narrowing threshold a measured number, in a comment?
- [ ] Is every dynamic value wrapped in `shell_escape()`?
- [ ] Are you about to write a helper the runtime already has? (§6)

Before you move a loop into `.ag`:

- [ ] Measured against this agent's own `cb <N>;`, at next year's input size?
- [ ] One array builtin rather than a per-element walk?
- [ ] Under ~4,094 elements if it recurses?

Before you call it done:

- [ ] Does every guard fail when you break it on purpose?
- [ ] Does a refusal name a reason, in a memo that survives a crashed print buffer?
- [ ] Does `decide()` receive an already-ranked list?
- [ ] Is the lint repo-wide, and does it force stale allowlist rows out?

---

*Sources: `Replikanti/agentis-colonies` commit history and issues #2081, #2083,
#2084; `agentis-core` issues #963, #966, #967. Runtime behaviour verified against
agentis 1.28.0; items marked source-read were not executed.*

[PR #2071]: https://github.com/Replikanti/agentis-colonies/pull/2071
[#2083]: https://github.com/Replikanti/agentis-colonies/issues/2083
[agentis-core#963]: https://github.com/Replikanti/agentis-core/issues/963
[agentis-core#966]: https://github.com/Replikanti/agentis-core/issues/966
[agentis-core#967]: https://github.com/Replikanti/agentis-core/issues/967
