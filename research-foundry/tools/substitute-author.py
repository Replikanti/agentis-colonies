#!/usr/bin/env python3
"""Substitute the LaTeX \\author{...} byline in main.tex from authors.toml.

Usage: substitute-author.py <authors.toml> <main.tex>

Reads authors.toml and rewrites the first `\\author{...}` macro in
main.tex to an amsart-compatible author block:

    \\author{Martin Holy}\\thanks{ORCID iD: 0009-0001-0459-5158}

amsart requires `\\thanks{...}` to be a separate macro from
`\\author{...}` — embedding `\\thanks` inside `\\author{...}` raises
`Class amsart Error: \\thanks should be given separately, not inside
author name.` and the compile aborts (#620). Multi-author is rendered
as concatenated `\\author{}\\thanks{}` pairs (no separator); amsart
treats any number of `\\author{}` macros as multiple authors.

The first-`\\author{}` match uses a balanced-brace depth counter so
the rendered block's own `\\thanks{...}` braces do not confuse a
second pass; running the helper twice in succession is a
byte-identical no-op (#618).

The choice to match `\\author{...}` rather than a literal token (e.g.
`AUTHOR-PLACEHOLDER`) is deliberate: the upstream LLM editor prompt
asks for the placeholder but real-world output is also
`\\author{Anonymous}`, `\\author{}`, or any other LLM-invented byline.
The helper must work regardless of what the LLM emits inside
`\\author{...}` (#618; original literal-token-only version landed in
#617 for #616).

Idempotent (exits 0 without rewriting) when:
- the TOML path is missing or unparseable,
- no [[authors]] entries are present or all are name-less,
- the .tex file has no `\\author{...}` macro at all,
- the .tex file is missing,
- the existing `\\author{...}` byline already matches the rendered
  block (running the helper twice in succession).
"""

import sys


def _find_author_macro(tex: str) -> tuple[int, int] | None:
    """Find the byte range of the first `\\author{...}` macro with
    balanced braces. Returns (start, end_exclusive) or None.
    """
    head = "\\author{"
    idx = tex.find(head)
    if idx < 0:
        return None
    depth = 1
    i = idx + len(head)
    n = len(tex)
    while i < n:
        c = tex[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return (idx, i + 1)
        i += 1
    return None


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: substitute-author.py <authors.toml> <main.tex>",
            file=sys.stderr,
        )
        return 2

    toml_path, tex_path = sys.argv[1], sys.argv[2]

    try:
        import tomllib
    except ImportError:
        try:
            import tomli as tomllib  # type: ignore
        except ImportError:
            return 0

    try:
        with open(toml_path, "rb") as f:
            data = tomllib.load(f)
    except Exception:
        return 0

    authors = data.get("authors") or []
    blocks = []
    for a in authors:
        name = (a.get("name") or "").strip()
        if not name:
            continue
        orcid = (a.get("arxiv_orcid") or "").strip()
        author_block = "\\author{" + name + "}"
        if orcid:
            author_block += "\\thanks{ORCID iD: " + orcid + "}"
        blocks.append(author_block)

    if not blocks:
        return 0

    replacement = "".join(blocks)

    try:
        with open(tex_path, "r", encoding="utf-8") as f:
            tex = f.read()
    except FileNotFoundError:
        return 0

    match = _find_author_macro(tex)
    if match is None:
        return 0

    start, end = match
    # Idempotency check: compare the rendered block against the bytes
    # starting at the first \\author{} we just found, NOT just the
    # matched single-macro range — after a previous rewrite, the
    # multi-pair replacement extends past the first \\author{}'s
    # closing brace (`\\thanks{...}` and subsequent \\author{}\\thanks{}
    # for multi-author). Without the longer slice the helper would
    # duplicate `\\thanks{...}` on every re-run.
    if tex[start:start + len(replacement)] == replacement:
        return 0

    new_tex = tex[:start] + replacement + tex[end:]

    with open(tex_path, "w", encoding="utf-8") as f:
        f.write(new_tex)

    return 0


if __name__ == "__main__":
    sys.exit(main())
