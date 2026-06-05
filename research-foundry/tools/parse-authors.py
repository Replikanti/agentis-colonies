#!/usr/bin/env python3
"""Parse authors.toml and print an arXiv-metadata "authors" line.

Usage: parse-authors.py <authors.toml>

Reads the [[authors]] array from the supplied TOML file and emits a
single semicolon-separated line of `Name <email>` entries (email
omitted when absent). On missing / unparseable / empty TOML, prints
the placeholder `AUTHOR-PLACEHOLDER <author@example.org>` and exits 0
so the submitter pipeline never crashes on operator-side config
mistakes — same idempotent contract as substitute-author.py.

Extracted from inline `python3 -c '...'` in submitter.ag for Wave 7v
of the exec-sh purge (agentis substrate `compute_python_args` cannot
take an inline -c string; it requires a script path on disk).
"""

import sys

try:
    import tomllib
except Exception:  # pragma: no cover - py < 3.11 fallback
    try:
        import tomli as tomllib
    except Exception:
        print("AUTHOR-PLACEHOLDER <author@example.org>")
        sys.exit(0)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("AUTHOR-PLACEHOLDER <author@example.org>")
        return 0
    try:
        with open(argv[1], "rb") as f:
            d = tomllib.load(f)
    except Exception:
        print("AUTHOR-PLACEHOLDER <author@example.org>")
        return 0
    authors = d.get("authors") or []
    out: list[str] = []
    for a in authors:
        name = a.get("name", "AUTHOR-PLACEHOLDER")
        email = a.get("email", "")
        if email:
            out.append(f"{name} <{email}>")
        else:
            out.append(name)
    print("; ".join(out) if out else "AUTHOR-PLACEHOLDER")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
