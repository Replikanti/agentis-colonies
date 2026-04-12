# check-exec-sh.sh known limitations

`tools/check-exec-sh.sh` is a grep-level guardrail against the
shell-injection class of bug that slipped through in agentis-colonies#49.
It scans every `.ag` file and flags unsafe `+` concatenation segments
that land in an `exec sh` command without a `shell_escape(...)` or
`to_string(...)` wrap.

Because it is grep-level by design (per #57), it has a short list of
known false positives and false negatives. Authors hitting one of
these cases can suppress a finding on a specific line by adding
`// colony-lint: safe-exec-concat` to the same line or the line
immediately above.

## 1. False positive: literal `+` inside a single-line `let`

Symptom:
```
[UNSAFE] tick.ag:12: let cmd = "./scripts/search.sh --query foo+bar";
```

The checker splits on `+` after seeing one in the right-hand side of a
`let`, so a plain string literal that happens to contain a `+`
character is flagged even though nothing is being concatenated.

Workaround:
```
let cmd = "./scripts/search.sh --query foo+bar"; // colony-lint: safe-exec-concat
```

Long-term fix candidate: teach the splitter to skip `+` characters
inside double-quoted segments. A few lines of awk would drop this
false-positive rate to near zero.

## 2. False negative: multi-line concatenation

The checker is line-oriented. This pattern is silently missed:

```
let cmd = "./foo "
    + draft.title;
```

Because grep sees `let cmd = "./foo "` on one line and `+ draft.title`
on another, the right-hand side never triggers the concat check.
Review your own `.ag` files manually for this pattern, especially
after merging a PR that reformats long lines.

## 3. False negative: `to_string(body)` when `body` is already a string

`to_string` is treated as a known-safe wrapper. It is an identity on
string values and does not shell-escape. If an LLM-tainted value flows
through `to_string` before concatenation, the checker trusts it even
though the value is still dangerous:

```
let cmd = "gh issue create --title " + to_string(issue_title);
```

If `issue_title` is LLM-tainted, this is a shell injection even though
the checker passes it. Use `shell_escape(issue_title)` for
user-controlled or LLM-controlled values.

## 4. False negative: function-call indirection

The checker does not follow function calls. This is explicit design
per agentis-colonies#57 ("grep-level check, not a full parser"):

```
let cmd = build_cmd(raw_title);
exec sh cmd;
```

If `build_cmd` internally concatenates `raw_title` into a shell
command without `shell_escape`, the injection is invisible to the
checker. The rule of thumb is: keep `exec sh` call sites close to the
`let` that builds the command, and don't introduce helper functions
just for command construction.

## When to use the suppression comment

Add `// colony-lint: safe-exec-concat` only when you have manually
verified that the flagged concatenation is safe. The most common
legitimate case is case 1 above: a literal `+` inside a hardcoded
string. If you find yourself using the suppression for case 2, 3, or
4, that is a signal to refactor instead — pull the value through
`shell_escape(...)`, inline the helper, or rewrite the `let` to
appease the grep.
