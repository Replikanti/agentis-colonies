#!/usr/bin/env python3
"""cross-repo-grep.py - cross-repo reference detection for code-review prompts.

Companion helper for `tools/cross-repo-grep.sh` (#317). Reads a diff JSON
spool from `$DIFF_INPUT_FILE` (or stdin when the env is unset/empty),
extracts the added/changed identifiers, batches them into one regex per
sibling repo declared in `$CROSS_REPO_REPOS`, runs `git -C <path> grep`
in each sibling, and prints a compact context block to stdout suitable
for prefixing onto an LLM review prompt.

Inputs (env):
  DIFF_INPUT_FILE       Path to the JSON spool emitted by
                        `forge-api.sh mr-changes`. Stdin is consumed
                        when the var is unset or the file is empty.
  CROSS_REPO_REPOS      CSV of `<owner>/<repo>` entries the operator
                        opted into as cross-repo context sources.
  CROSS_REPO_REPO_PATHS CSV of absolute paths, parallel to
                        CROSS_REPO_REPOS — mandatory when v1 grep
                        runs (no auto-derivation).
  CROSS_REPO_ACTIVE     Optional `<owner>/<repo>` of the active repo
                        (the one whose diff we are reviewing). When
                        present, that entry is filtered out of the
                        sibling list so we never grep our own checkout.
  CROSS_REPO_MAX_REFS   Cap on emitted match blocks. Default 10.
  CROSS_REPO_MAX_LINES  Cap on total emitted context lines. Default 200.

Outputs:
  stdout                Either the empty string (no matches / disabled),
                        or one block of the form:
                            Cross-repo references (N symbols, M repos):

                            [<owner>/<repo>] <path>:<line>
                              <context>
                            ...

                            [K more refs elided]
  stderr                Warnings on malformed input. Never crashes the
                        agent — every failure mode degrades to "no refs".
  exit                  Always 0 on degrade-to-empty paths. Exit 2 only
                        when the operator's CROSS_REPO_REPO_PATHS CSV
                        length does not match CROSS_REPO_REPOS.

Performance notes (plan §4 risk 4): one `git grep -l -E` per sibling, then
one `git grep -n -E` for context only on matched files. Caps below the
M=200-line ceiling. Sequential for ≤5 siblings; parallel grep is left for
a later iteration.
"""
import os
import re
import subprocess
import sys


KEYWORDS = set([
    "if", "for", "while", "def", "class", "function", "let", "const", "var",
    "return", "import", "from", "package", "use", "mod", "fn", "pub", "priv",
    "as", "new", "delete", "this", "self", "super", "extends", "typeof",
    "instanceof", "null", "true", "false",
])


def _read_diff_text():
    path = os.environ.get("DIFF_INPUT_FILE", "")
    if path:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError as exc:
            sys.stderr.write("cross-repo-grep: could not read DIFF_INPUT_FILE: %s\n" % exc)
            return ""
    try:
        return sys.stdin.read()
    except (OSError, ValueError):
        return ""


def _added_lines_from_diff(text):
    """Walk the forge-api mr-changes JSON and yield the added-line bodies.

    The shape is `[ {file, hunks: [ {lines: [{kind, text}, ...]} ]} ]` for
    the post-#256 forge-api wire format. We tolerate missing keys / wrong
    types — anything we can't parse just contributes zero symbols, which
    is the same as a no-context tick.
    """
    if not text or not text.strip():
        return []
    try:
        import json
        data = json.loads(text)
    except (ValueError, TypeError):
        # Fall back to a raw-text scan: pull out lines that start with `+`
        # but not `+++` (the unified-diff add marker). Cheap, tolerant of
        # any free-form diff body.
        out = []
        for ln in text.splitlines():
            if ln.startswith("+") and not ln.startswith("+++"):
                out.append(ln[1:])
        return out
    out = []
    if isinstance(data, list):
        for entry in data:
            if not isinstance(entry, dict):
                continue
            hunks = entry.get("hunks") or entry.get("changes") or []
            if not isinstance(hunks, list):
                continue
            for hunk in hunks:
                if isinstance(hunk, dict):
                    lines = hunk.get("lines") or []
                    if isinstance(lines, list):
                        for ln in lines:
                            if isinstance(ln, dict):
                                kind = ln.get("kind", "")
                                if kind == "added" or kind == "+":
                                    txt = ln.get("text", "")
                                    if isinstance(txt, str):
                                        out.append(txt)
                            elif isinstance(ln, str):
                                if ln.startswith("+") and not ln.startswith("+++"):
                                    out.append(ln[1:])
                elif isinstance(hunk, str):
                    if hunk.startswith("+") and not hunk.startswith("+++"):
                        out.append(hunk[1:])
            # Also accept a flat `diff` string per file.
            diff = entry.get("diff")
            if isinstance(diff, str):
                for ln in diff.splitlines():
                    if ln.startswith("+") and not ln.startswith("+++"):
                        out.append(ln[1:])
    return out


_TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")


def _extract_symbols(added_lines):
    seen = {}
    first_idx = {}
    order = []
    for ln in added_lines:
        for m in _TOKEN_RE.findall(ln):
            if m in KEYWORDS:
                continue
            if m in seen:
                seen[m] += 1
            else:
                seen[m] = 1
                first_idx[m] = len(order)
                order.append(m)
    # Sort by frequency descending, then by first-seen index ascending so
    # the cap truncation favours the symbols that hit the diff hardest.
    order.sort(key=lambda s: (-seen[s], first_idx[s]))
    return order


def _split_csv(value):
    if not value:
        return []
    return [x.strip() for x in value.split(",") if x.strip()]


def _git_grep_files(path, regex):
    try:
        proc = subprocess.run(
            ["git", "-C", path, "grep", "-l", "-E", regex],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, ValueError):
        return []
    if proc.returncode not in (0, 1):
        return []
    out = proc.stdout.decode("utf-8", errors="replace")
    return [ln for ln in out.splitlines() if ln]


def _git_grep_context(path, regex, files, max_lines):
    """Run `git grep -n -E -C 0` and yield (file, line_no, body) triples.

    We pull a 5-line context window via two grep passes — first the
    matching line numbers, then a `sed -n <a>,<b>p` per match — so the
    output stays portable to bash 3.2 callers that drive this helper
    directly. Implementation lives in Python which has no portability
    constraints, but we still use a single `git grep` to keep the cost
    down on big sibling repos.
    """
    if not files or max_lines <= 0:
        return []
    try:
        proc = subprocess.run(
            ["git", "-C", path, "grep", "-n", "-E", regex, "--"] + files,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, ValueError):
        return []
    if proc.returncode not in (0, 1):
        return []
    out = proc.stdout.decode("utf-8", errors="replace")
    triples = []
    for ln in out.splitlines():
        # `<path>:<line>:<body>` shape — split on the first two colons only
        # so the body itself can contain colons.
        first = ln.find(":")
        if first < 0:
            continue
        second = ln.find(":", first + 1)
        if second < 0:
            continue
        f = ln[:first]
        try:
            lineno = int(ln[first + 1:second])
        except ValueError:
            continue
        body = ln[second + 1:]
        triples.append((f, lineno, body))
    return triples


def main():
    repos_csv = os.environ.get("CROSS_REPO_REPOS", "")
    paths_csv = os.environ.get("CROSS_REPO_REPO_PATHS", "")
    repos = _split_csv(repos_csv)
    paths = _split_csv(paths_csv)

    if not repos:
        return 0

    if len(paths) != len(repos):
        sys.stderr.write(
            "cross-repo-grep: CROSS_REPO_REPO_PATHS length (%d) does not match "
            "CROSS_REPO_REPOS length (%d) — declare both CSVs in parallel.\n"
            % (len(paths), len(repos))
        )
        return 2

    active = os.environ.get("CROSS_REPO_ACTIVE", "").strip()
    pairs = []
    for key, path in zip(repos, paths):
        if active and key == active:
            continue
        if not os.path.isdir(path):
            sys.stderr.write(
                "cross-repo-grep: skipping '%s' — not a directory: %s\n"
                % (key, path)
            )
            continue
        pairs.append((key, path))

    if not pairs:
        return 0

    try:
        max_refs = int(os.environ.get("CROSS_REPO_MAX_REFS", "10") or "10")
    except ValueError:
        max_refs = 10
    try:
        max_lines = int(os.environ.get("CROSS_REPO_MAX_LINES", "200") or "200")
    except ValueError:
        max_lines = 200

    diff_text = _read_diff_text()
    added = _added_lines_from_diff(diff_text)
    symbols = _extract_symbols(added)

    if not symbols:
        return 0

    # Cap the symbol-set we batch into the regex. 100 unique symbols is the
    # plan's per-tick ceiling; longer hunks get truncated before the regex
    # is even built so the grep command line stays bounded.
    if len(symbols) > 100:
        symbols = symbols[:100]

    # Build the batched alternation regex. Word boundaries (POSIX
    # `[[:<:]]`/`[[:>:]]` are not portable across BSD vs GNU `git grep`)
    # are emulated with `(^|[^A-Za-z0-9_])` and `($|[^A-Za-z0-9_])`. We
    # keep the regex simple — `git grep -E` rejects PCRE features.
    escaped = [re.escape(s) for s in symbols]
    regex = "(^|[^A-Za-z0-9_])(" + "|".join(escaped) + ")($|[^A-Za-z0-9_])"

    blocks = []
    used_lines = 0
    repos_hit = set()
    elided = 0
    for key, path in pairs:
        if len(blocks) >= max_refs and used_lines >= max_lines:
            elided += 1
            continue
        files = _git_grep_files(path, regex)
        if not files:
            continue
        triples = _git_grep_context(path, regex, files, max_lines - used_lines)
        for (f, lineno, body) in triples:
            if len(blocks) >= max_refs:
                elided += 1
                continue
            if used_lines >= max_lines:
                elided += 1
                continue
            block = "[%s] %s:%d\n  %s\n" % (key, f, lineno, body)
            blocks.append(block)
            repos_hit.add(key)
            used_lines += 2

    if not blocks:
        return 0

    header = "Cross-repo references (%d refs, %d repos):\n\n" % (
        len(blocks), len(repos_hit)
    )
    sys.stdout.write(header)
    sys.stdout.write("\n".join(blocks))
    if elided > 0:
        sys.stdout.write("\n[%d more refs elided]\n" % elided)
    return 0


if __name__ == "__main__":
    sys.exit(main())
