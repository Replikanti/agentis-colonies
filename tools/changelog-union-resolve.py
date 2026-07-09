#!/usr/bin/env python3
"""changelog-union-resolve.py - deterministic union-merge of a conflicted CHANGELOG.

The ONE proven-safe conflict class the #1518 auto-rebase stage resolves without a
human: two independent additive bullet inserts under a Keep-a-Changelog
`## [Unreleased]` section. When `main` merged a CHANGELOG `[Unreleased]` entry
while our own PR branch added a different one, a rebase leaves a conflict hunk
whose two sides are BOTH just new bullets — keeping both (union) is the correct,
lossless resolution.

This helper is invoked by `tools/code-edit-in-checkout.sh --rebase` on a rebase
conflict whose ONLY conflicted file is a `CHANGELOG.md`. It is deterministic and
uses NO LLM: it is a pure text transform behind a strict, fail-CLOSED containment
guard. Anything outside the proven class is REFUSED (the caller then aborts the
rebase and posts a one-time human note) — the helper NEVER edits a released
section, NEVER touches non-additive content, and NEVER guesses.

During `git rebase origin/<default>`, git replays OUR commits on top of the
default branch, so in a conflict hunk the `<<<<<<< HEAD` side is the
DEFAULT-BRANCH (main) content and the `>>>>>>>` side is OUR commit. The union
keeps the HEAD (main) bullets FIRST, then our bullets, matching the intent
"main's entry landed first, ours appends after it".

Guard (ALL required, fail-closed — any miss => exit 3):
  * basename is exactly `CHANGELOG.md`
  * a `## [Unreleased]` heading exists
  * EVERY conflict hunk lies STRICTLY between the `## [Unreleased]` line and the
    next `## [` heading (i.e. entirely inside the Unreleased section)
  * both sides of every hunk are additive-bullet-only: each non-blank line is a
    `- ` bullet or an indented continuation/sub-bullet — never a heading, never a
    `## [` version line, never prose

On success the file is rewritten in place with each hunk replaced by
(HEAD-side lines) + (our-side lines), the three conflict markers dropped.

Exit codes:
    0   resolved and written in place
    3   guard failed (caller aborts the rebase + posts a human note)
    2   usage error, unreadable file, or malformed conflict markers (parse error)
"""

import os
import sys

CONFLICT_START = "<<<<<<<"
CONFLICT_MID = "======="
CONFLICT_END = ">>>>>>>"


def _is_additive_line(line):
    """A conflict-side line is additive iff it is blank, a `- ` bullet, or an
    indented continuation/sub-bullet. Headings and flush-left prose are NOT."""
    stripped = line.strip()
    if stripped == "":
        return True
    if line.startswith("#"):
        return False
    if stripped.startswith("- "):
        return True
    # Indented continuation / nested bullet (leading whitespace, any content).
    if line[:1] in (" ", "\t"):
        return True
    return False


def _fail_guard(msg):
    sys.stderr.write("changelog-union-resolve: guard: %s\n" % msg)
    sys.exit(3)


def _parse_error(msg):
    sys.stderr.write("changelog-union-resolve: parse error: %s\n" % msg)
    sys.exit(2)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: changelog-union-resolve.py <path-to-CHANGELOG.md>\n")
        return 2

    path = argv[1]

    # Guard: basename must be exactly CHANGELOG.md. Fail-closed (exit 3) — the
    # caller only ever hands us a lone CHANGELOG.md, but we re-check here so the
    # helper is safe to run standalone.
    if os.path.basename(path) != "CHANGELOG.md":
        _fail_guard("basename is not CHANGELOG.md: %s" % path)

    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        _parse_error("cannot read %s: %s" % (path, exc))
        return 2  # unreachable (｀_parse_error exits) — keeps linters happy

    # Preserve a trailing-newline-less final line faithfully.
    lines = text.split("\n")

    # Locate the Unreleased section boundaries on the RAW lines (conflict markers
    # included) so a `## [` heading that appears INSIDE a hunk is correctly seen
    # as breaking containment.
    unreleased_idx = None
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("## [Unreleased]") or s.startswith("## [unreleased]"):
            unreleased_idx = i
            break
    if unreleased_idx is None:
        _fail_guard("no `## [Unreleased]` heading found")

    next_heading_idx = len(lines)
    for i in range(unreleased_idx + 1, len(lines)):
        if lines[i].startswith("## ["):
            next_heading_idx = i
            break

    # Parse conflict hunks. Each hunk is (start_idx, mid_idx, end_idx) referencing
    # the marker lines. Malformed nesting/ordering is a parse error (exit 2).
    hunks = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if line.startswith(CONFLICT_START):
            start = i
            mid = None
            end = None
            j = i + 1
            while j < n:
                if lines[j].startswith(CONFLICT_START):
                    _parse_error("nested `<<<<<<<` at line %d" % (j + 1))
                if lines[j].startswith(CONFLICT_MID) and mid is None:
                    mid = j
                elif lines[j].startswith(CONFLICT_END):
                    end = j
                    break
                j += 1
            if mid is None or end is None:
                _parse_error("unterminated conflict hunk starting at line %d" % (start + 1))
            hunks.append((start, mid, end))
            i = end + 1
            continue
        if line.startswith(CONFLICT_MID) or line.startswith(CONFLICT_END):
            _parse_error("stray conflict marker at line %d" % (i + 1))
        i += 1

    if not hunks:
        _parse_error("no conflict hunks found (nothing to resolve)")

    # Guard every hunk: strictly inside [Unreleased], both sides additive-only.
    for (start, mid, end) in hunks:
        if not (unreleased_idx < start and end < next_heading_idx):
            _fail_guard(
                "conflict hunk at lines %d-%d is not strictly inside the "
                "[Unreleased] section (%d..%d)"
                % (start + 1, end + 1, unreleased_idx + 1, next_heading_idx)
            )
        head_side = lines[start + 1:mid]
        our_side = lines[mid + 1:end]
        for side_name, side in (("HEAD", head_side), ("ours", our_side)):
            for ln in side:
                if not _is_additive_line(ln):
                    _fail_guard(
                        "non-additive line on the %s side of the hunk at "
                        "lines %d-%d: %r" % (side_name, start + 1, end + 1, ln)
                    )

    # Resolve: rebuild the file, replacing each hunk with HEAD-side then our-side
    # lines (markers dropped). Iterate the hunks in order.
    out = []
    cursor = 0
    for (start, mid, end) in hunks:
        out.extend(lines[cursor:start])
        out.extend(lines[start + 1:mid])   # HEAD (default-branch) bullets first
        out.extend(lines[mid + 1:end])     # our bullets after
        cursor = end + 1
    out.extend(lines[cursor:])

    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(out))
    except OSError as exc:
        _parse_error("cannot write %s: %s" % (path, exc))

    sys.stderr.write(
        "changelog-union-resolve: union-merged %d conflict hunk(s) in %s\n"
        % (len(hunks), path)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
