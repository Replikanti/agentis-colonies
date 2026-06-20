#!/usr/bin/env python3
# tools/apply-edits.py (#1195): deterministically apply a list of
# search/replace edits to a file's content and emit the new full content.
#
# Why this exists: code_writer's autonomous path used to ask the LLM to
# return the FULL new content of an existing file. For a large file (e.g. a
# ~47KB README) that means regenerating ~47KB, which (a) times out the LLM
# call and (b) on the flat-cyborg TUI screen-scrape backend gets
# line-wrap-corrupted. Instead the LLM now emits SMALL targeted edits
# (`[{"old_str": ..., "new_str": ...}]`) and THIS script assembles the full
# file deterministically — no large LLM output, so it works on flat-cyborg.
#
# Contract:
#   - The original file content arrives on stdin (large content travels via
#     a pipe, never argv, to dodge ARG_MAX).
#   - The edits JSON array arrives in the APPLY_EDITS env var (also off-argv;
#     edits can themselves be large).
#   - On success: the new full content is written to stdout, exit 0.
#   - On any failure: a JSON `{"error": "..."}` is written to stderr naming
#     which edit failed, exit non-zero, and NOTHING is written to stdout
#     (no partial/garbage content).
#
# Edits are applied sequentially. For each edit, `old_str` MUST occur
# EXACTLY ONCE in the current (post-previous-edits) content. Zero matches or
# more than one match is a loud, non-zero failure. This exact-match-or-fail
# rule is the corruption guard: if flat-cyborg's screen-scrape mangles an
# edit, `old_str` won't match the real file -> loud failure -> the agent
# retries, and we never commit silent garbage.

import json
import os
import sys


def fail(msg):
    sys.stderr.write(json.dumps({"error": msg}))
    sys.stderr.write("\n")
    sys.exit(1)


def main():
    content = sys.stdin.read()

    raw = os.environ.get("APPLY_EDITS", "")
    if raw.strip() == "":
        fail("APPLY_EDITS env var is empty (expected a JSON array of edits)")

    try:
        edits = json.loads(raw)
    except Exception as e:
        fail("APPLY_EDITS is not valid JSON: " + str(e))

    if not isinstance(edits, list):
        fail("APPLY_EDITS must be a JSON array of edits")

    if len(edits) == 0:
        fail("APPLY_EDITS is an empty array (no edits to apply)")

    for i, edit in enumerate(edits):
        if not isinstance(edit, dict):
            fail("edit %d is not an object" % i)
        if "old_str" not in edit or "new_str" not in edit:
            fail("edit %d is missing 'old_str' or 'new_str'" % i)
        old_str = edit["old_str"]
        new_str = edit["new_str"]
        if not isinstance(old_str, str) or not isinstance(new_str, str):
            fail("edit %d 'old_str'/'new_str' must be strings" % i)
        if old_str == "":
            fail("edit %d has an empty 'old_str' (would match everywhere)" % i)

        count = content.count(old_str)
        if count == 0:
            fail("edit %d: old_str not found in current content: %r" % (i, old_str))
        if count > 1:
            fail("edit %d: old_str occurs %d times (must be unique): %r"
                 % (i, count, old_str))

        content = content.replace(old_str, new_str, 1)

    sys.stdout.write(content)


if __name__ == "__main__":
    main()
