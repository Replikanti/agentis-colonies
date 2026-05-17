#!/usr/bin/env python3
"""Substitute AUTHOR-PLACEHOLDER in main.tex from authors.toml (#616).

Usage: substitute-author.py <authors.toml> <main.tex>

Reads authors.toml, builds a LaTeX author block ("<name>\\thanks{ORCID
iD: <id>}", multi-author joined with " \\and "), and replaces the
literal token AUTHOR-PLACEHOLDER in main.tex in place.

Idempotent (exits 0 without rewriting) when:
- the TOML path is missing or unparseable,
- no [[authors]] entries are present or all are name-less,
- the .tex file lacks the literal AUTHOR-PLACEHOLDER token.

The editor colony invokes this helper after each LLM-produced tex
write (initial draft + repair pass) and before the corresponding
latexmk invocation, so the compiled PDF also reflects the real author
rather than just the .tex inside the arXiv submission tarball.
"""

import sys


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
    parts = []
    for a in authors:
        name = (a.get("name") or "").strip()
        if not name:
            continue
        orcid = (a.get("arxiv_orcid") or "").strip()
        if orcid:
            parts.append(name + "\\thanks{ORCID iD: " + orcid + "}")
        else:
            parts.append(name)

    if not parts:
        return 0

    block = " \\and ".join(parts)

    try:
        with open(tex_path, "r", encoding="utf-8") as f:
            tex = f.read()
    except FileNotFoundError:
        return 0

    if "AUTHOR-PLACEHOLDER" not in tex:
        return 0

    with open(tex_path, "w", encoding="utf-8") as f:
        f.write(tex.replace("AUTHOR-PLACEHOLDER", block))

    return 0


if __name__ == "__main__":
    sys.exit(main())
