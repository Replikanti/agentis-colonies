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

THE BASE REGION IS DECISIVE (adversarial-review fix, #1518). Line SHAPE alone
(is it a `- ` bullet?) does NOT prove ADDITIVITY: a side that EDITS or DELETES a
base bullet is still all-`- `-bullet-shaped, and unioning it resurrects the
deleted bullet / duplicates the edited one — a valid-markdown CORRUPTED CHANGELOG
that CI can't catch. Without the merge base we cannot tell "two independent
inserts" (safe to union) from "one side edited/deleted a base bullet" (union
corrupts). So the caller runs the rebase under `merge.conflictStyle=zdiff3`,
which emits the base region inside every hunk:

    <<<<<<< HEAD
    ...HEAD (main) side...
    ||||||| <base marker>
    ...merge-base region...
    =======
    ...our side...
    >>>>>>> <commit>

The ONLY safe subset is a PURE two-sided additive insert where NOTHING existed at
the conflict point — i.e. the base region is EMPTY. A NON-EMPTY base region means
at least one side changed pre-existing content, so we REFUSE (exit 3). A hunk with
NO base marker (a 2-way / add-add shape) is treated as empty-base = OK.

Guard (ALL required, fail-closed — any miss => exit 3):
  * basename is exactly `CHANGELOG.md`
  * a `## [Unreleased]` heading exists
  * EVERY conflict hunk lies STRICTLY between the `## [Unreleased]` line and the
    next `## [` heading (i.e. entirely inside the Unreleased section)
  * EVERY conflict hunk's zdiff3 base region is EMPTY (no non-whitespace content)
    — a non-empty base region means a side edited/deleted a base bullet, which
    union would corrupt, so it is REFUSED
  * both sides of every hunk are additive-bullet-only: each non-blank line is a
    `- ` bullet or an indented continuation/sub-bullet — never a heading, never a
    `## [` version line, never prose

On success the file is rewritten in place with each hunk replaced by
(HEAD-side lines) + (our-side lines), all conflict markers (including the base
region) dropped.

Exit codes:
    0   resolved and written in place
    3   guard failed (caller aborts the rebase + posts a human note)
    2   usage error, unreadable file, or malformed conflict markers (parse error)
"""

import os
import sys

CONFLICT_START = "<<<<<<<"
CONFLICT_BASE = "|||||||"   # zdiff3 merge-base region marker
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

    # Parse conflict hunks. Each hunk is (start, base, mid, end) referencing the
    # marker lines; `base` is the zdiff3 `|||||||` index or None when the hunk
    # carries no base region (a 2-way / add-add shape). Malformed nesting/ordering
    # is a parse error (exit 2).
    hunks = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if line.startswith(CONFLICT_START):
            start = i
            base = None
            mid = None
            end = None
            j = i + 1
            while j < n:
                lj = lines[j]
                if lj.startswith(CONFLICT_START):
                    _parse_error("nested `<<<<<<<` at line %d" % (j + 1))
                if lj.startswith(CONFLICT_BASE) and mid is None and base is None:
                    base = j
                elif lj.startswith(CONFLICT_MID) and mid is None:
                    mid = j
                elif lj.startswith(CONFLICT_END):
                    end = j
                    break
                j += 1
            if mid is None or end is None:
                _parse_error("unterminated conflict hunk starting at line %d" % (start + 1))
            hunks.append((start, base, mid, end))
            i = end + 1
            continue
        if line.startswith(CONFLICT_MID) or line.startswith(CONFLICT_END) \
                or line.startswith(CONFLICT_BASE):
            _parse_error("stray conflict marker at line %d" % (i + 1))
        i += 1

    if not hunks:
        _parse_error("no conflict hunks found (nothing to resolve)")

    # Guard every hunk: strictly inside [Unreleased], EMPTY base region (so
    # neither side edited/deleted a base bullet), both sides additive-only.
    for (start, base, mid, end) in hunks:
        if not (unreleased_idx < start and end < next_heading_idx):
            _fail_guard(
                "conflict hunk at lines %d-%d is not strictly inside the "
                "[Unreleased] section (%d..%d)"
                % (start + 1, end + 1, unreleased_idx + 1, next_heading_idx)
            )
        # zdiff3 base region: a NON-EMPTY base means a side changed pre-existing
        # content — union would resurrect a deleted bullet or duplicate an edited
        # one, so REFUSE. A hunk with no base marker (base is None) is an add/add
        # shape where nothing pre-existed => empty base => OK.
        if base is not None:
            base_region = lines[base + 1:mid]
            for bl in base_region:
                if bl.strip() != "":
                    _fail_guard(
                        "non-empty merge-base region in the hunk at lines %d-%d "
                        "(a side edited/deleted a base bullet — union would "
                        "corrupt): %r" % (start + 1, end + 1, bl)
                    )
            head_side = lines[start + 1:base]
        else:
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
    # lines (all markers + the base region dropped). Iterate the hunks in order.
    out = []
    cursor = 0
    for (start, base, mid, end) in hunks:
        out.extend(lines[cursor:start])
        head_end = base if base is not None else mid
        out.extend(lines[start + 1:head_end])   # HEAD (default-branch) bullets first
        out.extend(lines[mid + 1:end])          # our bullets after
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
