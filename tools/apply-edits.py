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
# Edits are applied sequentially. For each edit:
#   Step 1 (exact): `old_str` MUST occur EXACTLY ONCE in the current
#   (post-previous-edits) content. One match -> replace, done.
#   Step 2 (normalized fallback, #1204): if the exact match is not
#   exactly-once, retry under whitespace normalization — strip trailing
#   whitespace per line and normalize line endings (CRLF -> LF) on BOTH the
#   file and `old_str`. Leading/internal whitespace is preserved (collapsing
#   it would mis-locate the anchor). If the normalized `old_str` block matches
#   EXACTLY ONCE in the normalized file, the matching ORIGINAL line span is
#   replaced with `new_str`.
# Zero matches or more than one match at BOTH steps is a loud, non-zero
# failure. This exactly-once requirement is the corruption guard: if
# flat-cyborg's screen-scrape mangles an edit beyond whitespace drift,
# `old_str` won't match the real file -> loud failure -> the agent retries,
# and we never commit silent garbage on an ambiguous/absent anchor.

import json
import os
import sys


def fail(msg):
    sys.stderr.write(json.dumps({"error": msg}))
    sys.stderr.write("\n")
    sys.exit(1)


def _normalize_line(line):
    # Strip the line ending (CRLF or LF) and any trailing whitespace. Leading
    # and internal whitespace is preserved so the anchor cannot drift; only
    # trailing-whitespace + CRLF/LF drift is absorbed. rstrip("\r\n") drops the
    # line terminator first, then rstrip() removes trailing spaces/tabs.
    return line.rstrip("\r\n").rstrip()


def _normalized_block(text):
    # Return the list of trailing-whitespace-stripped, CRLF-normalized lines for
    # an arbitrary text block. splitlines() handles CRLF and LF uniformly and
    # does not emit a spurious trailing empty element for a final newline.
    return [_normalize_line(line) for line in text.splitlines()]


def _apply_normalized(content, old_str, new_str):
    # Whitespace-normalized fallback. Match `old_str` as a contiguous block of
    # normalized lines inside the normalized file, then map that block back to
    # the ORIGINAL line span and splice in `new_str` — preserving every original
    # byte (line endings included) OUTSIDE the matched span.
    #
    # Returns the new content on a unique normalized match, or None when the
    # normalized match count is not exactly one (caller fails loudly).
    #
    # Original lines keep their terminators via keepends=True so the rebuilt
    # file is byte-identical to the original everywhere except the replaced
    # span. The normalized view (terminator + trailing whitespace stripped) is
    # what we match on, and it is index-aligned 1:1 with `orig_lines`.
    orig_lines = content.splitlines(keepends=True)
    norm_file = [_normalize_line(line) for line in orig_lines]
    norm_old = _normalized_block(old_str)

    block = len(norm_old)
    if block == 0:
        return None

    # Scan every window of `block` consecutive normalized file lines for an
    # exact match against the normalized old_str lines. Count all matches; only
    # a unique match is allowed to apply.
    matches = []
    last = len(norm_file) - block
    i = 0
    while i <= last:
        if norm_file[i:i + block] == norm_old:
            matches.append(i)
        i += 1

    if len(matches) != 1:
        return None

    start = matches[0]
    end = start + block
    # Map the normalized span [start, end) back onto the ORIGINAL lines. The
    # head and tail keep their original terminators verbatim; only the matched
    # span is replaced by new_str. Preserve the original span's trailing
    # terminator: if the last original line in the span ended in a newline, the
    # replacement should too (so a multi-line block edit keeps the file's line
    # structure). new_str is inserted verbatim and may itself contain newlines.
    head = "".join(orig_lines[:start])
    tail = "".join(orig_lines[end:])
    span_last = orig_lines[end - 1]
    if span_last.endswith("\r\n"):
        trailer = "\r\n"
    elif span_last.endswith("\n"):
        trailer = "\n"
    else:
        trailer = ""
    # Only re-attach the span terminator when new_str does not already supply
    # one, so we neither drop nor double a trailing newline on the edited block.
    replacement = new_str
    if trailer and not new_str.endswith(("\r\n", "\n")):
        replacement = new_str + trailer
    return head + replacement + tail


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

        # Step 1: exact match (exactly-once -> apply).
        count = content.count(old_str)
        if count == 1:
            content = content.replace(old_str, new_str, 1)
            continue

        # Step 2: whitespace-normalized fallback. Only reached when the exact
        # match was absent (0) or ambiguous (>1). A unique normalized match
        # re-anchors the edit; anything else falls through to a loud failure.
        rebuilt = _apply_normalized(content, old_str, new_str)
        if rebuilt is not None:
            content = rebuilt
            continue

        if count == 0:
            fail("edit %d: old_str not found in current content (exact or "
                 "whitespace-normalized): %r" % (i, old_str))
        else:
            fail("edit %d: old_str occurs %d times (must be unique; not "
                 "uniquely resolvable under whitespace normalization "
                 "either): %r" % (i, count, old_str))

    sys.stdout.write(content)


if __name__ == "__main__":
    main()
