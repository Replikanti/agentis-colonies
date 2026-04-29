#!/usr/bin/env python3
"""scan-cross-repo-refs.py - extract cross-repo refs from a stdin blob.

Companion helper for `tools/scan-cross-repo-refs.sh` (#317). Reads any
textual blob from stdin (PR body, comment, description), runs a pure
regex over it, and writes one `<owner>/<repo>#<N>` ref per line on
stdout. The scanner deduplicates refs (set, preserve first-seen order)
and filters out the obvious code-ref forms that resemble cross-repo
references syntactically but mean something else (`#L42` line refs, the
trailing word characters past the digit run, etc.).

The regex follows the plan §3 spec verbatim:

    (?<![\\w./-])                    # left boundary
    ([a-zA-Z0-9][a-zA-Z0-9._-]*)     # owner (no leading dot)
    /
    ([a-zA-Z0-9][a-zA-Z0-9._-]*)     # repo (no leading dot)
    #
    (?!L\\d)                         # not a line ref (#L42)
    (\\d+)                           # issue/PR number
    (?!\\w)                          # right boundary

Empty stdin -> empty stdout, exit 0. No matches -> empty stdout, exit 0.

`--self <owner>/<repo>` filters self-references — a PR in `acme/backend`
that mentions `acme/backend#42` is not a cross-repo ref, so the scanner
drops it. The flag is optional; without it every match is emitted.

Exit codes: 0 always on success, 2 on malformed `--self`.
"""
import argparse
import re
import sys

PATTERN = re.compile(
    r'(?<![\w./-])'
    r'([a-zA-Z0-9][a-zA-Z0-9._-]*)'
    r'/'
    r'([a-zA-Z0-9][a-zA-Z0-9._-]*)'
    r'#'
    r'(?!L\d)'
    r'(\d+)'
    r'(?!\w)'
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--self",
        dest="self_ref",
        default="",
        help="owner/repo to drop from output (filters self-references)",
    )
    args = ap.parse_args()

    self_ref = args.self_ref
    if self_ref:
        if "/" not in self_ref:
            sys.stderr.write(
                "scan-cross-repo-refs: --self expected owner/repo (got '%s')\n"
                % self_ref
            )
            return 2
        # Light schema check; the dispatcher already validates upstream.
        parts = self_ref.split("/", 1)
        if not parts[0] or not parts[1]:
            sys.stderr.write(
                "scan-cross-repo-refs: --self expected owner/repo (got '%s')\n"
                % self_ref
            )
            return 2

    blob = sys.stdin.read()
    if not blob:
        return 0

    seen = set()
    for m in PATTERN.finditer(blob):
        owner, repo, num = m.group(1), m.group(2), m.group(3)
        ref = "%s/%s#%s" % (owner, repo, num)
        if ref in seen:
            continue
        if self_ref and ("%s/%s" % (owner, repo)) == self_ref:
            continue
        seen.add(ref)
        sys.stdout.write(ref + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
