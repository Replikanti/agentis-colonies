#!/usr/bin/env python3
# tools/apply-line-edits.py (#1208): deterministically apply a list of
# line-numbered RANGE edits to a file's content and emit the new full content.
#
# Why this exists: code_writer's autonomous existing-file path used to ask the
# LLM for search/replace edits whose `old_str` had to reproduce the file's
# source BYTE-FOR-BYTE (apply-edits.py, #1195/#1204). On markdown that fails:
# the model drops `**` markdown from the anchor, so old_str never matches and
# the edit is dropped. Line-NUMBERED range edits remove the failure mode
# entirely — the model never has to reproduce exact source bytes, it only
# names the line numbers to replace (the prompt shows a `N|`-prefixed view).
# THIS script then splices the replacement text in deterministically.
#
# Contract:
#   - The original file content arrives on stdin (large content travels via
#     a pipe, never argv, to dodge ARG_MAX).
#   - The edits JSON array arrives in the LINE_EDITS env var (also off-argv;
#     edits can themselves be large). Each edit is
#       {"start_line": int, "end_line": int, "new_text": str}
#     with 1-based, inclusive line numbers; new_text may be multi-line, or
#     empty to DELETE the [start_line, end_line] span.
#   - On success: the new full content is written to stdout, exit 0.
#   - On any validation failure: a JSON `{"error": "..."}` is written to
#     stderr, exit non-zero, and NOTHING is written to stdout (no partial /
#     garbage content — the corruption guard).
#
# Validation (any failure -> loud, non-zero, NO stdout):
#   - LINE_EDITS is a non-empty JSON array of objects, each carrying integer
#     start_line / end_line and a string new_text.
#   - 1 <= start_line <= end_line <= len(lines) for every edit.
#   - Edits are NON-OVERLAPPING (sorted by start_line, no span intersects the
#     next). Overlap is ambiguous -> fail rather than guess.
#
# Application: edits are applied sorted DESCENDING by start_line, so replacing
# an earlier range never shifts the (already-validated) line numbers of a
# later range. For each edit, lines[start-1 : end] is replaced by new_text
# split back into lines; the original span's trailing newline boundary is
# preserved so a multi-line block edit keeps the file's line structure and we
# neither drop nor double a newline at the splice. Every line OUTSIDE an edited
# range stays byte-verbatim.

import json
import os
import sys


def fail(msg):
    sys.stderr.write(json.dumps({"error": msg}))
    sys.stderr.write("\n")
    sys.exit(1)


def _split_replacement(new_text, trailer):
    # Turn new_text into the list of replacement lines to splice in, preserving
    # the spliced block's trailing newline boundary. We mirror apply-edits.py's
    # careful trailer handling: re-attach the original span's terminator only
    # when new_text does not already supply one, so the edited block neither
    # drops nor doubles a trailing newline.
    #
    # `trailer` is "\r\n", "\n", or "" — the line terminator of the LAST
    # original line in the replaced span. An empty new_text yields no lines
    # (a pure deletion of the span).
    if new_text == "":
        return []
    if trailer and not new_text.endswith(("\r\n", "\n")):
        new_text = new_text + trailer
    return new_text.splitlines(keepends=True)


def main():
    content = sys.stdin.read()

    raw = os.environ.get("LINE_EDITS", "")
    if raw.strip() == "":
        fail("LINE_EDITS env var is empty (expected a JSON array of edits)")

    try:
        edits = json.loads(raw)
    except Exception as e:
        fail("LINE_EDITS is not valid JSON: " + str(e))

    if not isinstance(edits, list):
        fail("LINE_EDITS must be a JSON array of edits")

    if len(edits) == 0:
        fail("LINE_EDITS is an empty array (no edits to apply)")

    # Preserve each original line's exact terminator so every line OUTSIDE an
    # edited range is rebuilt byte-verbatim.
    lines = content.splitlines(keepends=True)
    n = len(lines)

    # Validate and normalize every edit before touching the content. We build a
    # list of (start, end, new_text) tuples with 1-based inclusive bounds.
    norm = []
    for i, edit in enumerate(edits):
        if not isinstance(edit, dict):
            fail("edit %d is not an object" % i)
        if "start_line" not in edit or "end_line" not in edit or "new_text" not in edit:
            fail("edit %d is missing 'start_line', 'end_line', or 'new_text'" % i)
        start = edit["start_line"]
        end = edit["end_line"]
        new_text = edit["new_text"]
        # bool is a subclass of int; reject it so True/False can't pose as a
        # line number.
        if isinstance(start, bool) or not isinstance(start, int):
            fail("edit %d 'start_line' must be an integer" % i)
        if isinstance(end, bool) or not isinstance(end, int):
            fail("edit %d 'end_line' must be an integer" % i)
        if not isinstance(new_text, str):
            fail("edit %d 'new_text' must be a string" % i)
        if start < 1:
            fail("edit %d: start_line %d is < 1 (lines are 1-based)" % (i, start))
        if end < start:
            fail("edit %d: end_line %d < start_line %d" % (i, end, start))
        if end > n:
            fail("edit %d: end_line %d exceeds file line count %d" % (i, end, n))
        norm.append((start, end, new_text))

    # Non-overlap check: sort by start_line, then assert each span ends strictly
    # before the next one begins. Equal/overlapping spans are ambiguous -> fail.
    by_start = sorted(norm, key=lambda t: t[0])
    for j in range(1, len(by_start)):
        prev_end = by_start[j - 1][1]
        cur_start = by_start[j][0]
        if cur_start <= prev_end:
            fail("edits overlap: span ending at line %d intersects span starting "
                 "at line %d (edits must be non-overlapping)" % (prev_end, cur_start))

    # Apply DESCENDING by start_line so replacing an earlier range never shifts
    # the line indices of a later (not-yet-applied) range.
    for start, end, new_text in sorted(by_start, key=lambda t: t[0], reverse=True):
        span_last = lines[end - 1]
        if span_last.endswith("\r\n"):
            trailer = "\r\n"
        elif span_last.endswith("\n"):
            trailer = "\n"
        else:
            trailer = ""
        replacement = _split_replacement(new_text, trailer)
        lines[start - 1:end] = replacement

    sys.stdout.write("".join(lines))


if __name__ == "__main__":
    main()
