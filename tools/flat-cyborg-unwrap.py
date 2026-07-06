#!/usr/bin/env python3
# tools/flat-cyborg-unwrap.py (#1163): post-process a flat-cyborg --extract
# reply so a JSON-shaped reply that flat-cyborg's --extract-structural
# screen-scrape LINE-WRAPPED (the TUI folds long output, injecting
# newline+indent INSIDE the JSON string) parses again.
#
# Heuristic (safe, narrow): the fast path only fires when the trimmed reply is
# already a single JSON object — it starts with `{` AND ends with `}`. In that
# case any run of `\s*\n\s*` (a soft TUI line-wrap + indent) collapses to one
# space, so the JSON lands on one line.
#
# Prose-wrapped JSON (added, #1340): the interactive Claude Code session driven
# by flat-cyborg sometimes ignores the "raw JSON only" instruction on heavier
# prompts and answers conversationally — `Certainly! {...}` or a ```json fence.
# flat-cyborg's --extract / --extract-structural screen-scrape fallback also
# leaks its reply SENTINEL (`FCB_<hex>_BEGIN\n{...}`) into stdout whenever claude
# does not write the result-file channel. Either way the trimmed reply no longer
# starts with `{`, so the agentis runtime fails to decode the typed
# `prompt(...) -> Schema` reply ("invalid JSON: unexpected character"). We
# therefore ALSO unwrap a JSON object/array that is fenced or surrounded by a
# SHORT prose / sentinel lead-in / trailer — but ONLY when the extracted span
# actually parses as JSON. Genuine prose replies (no parseable JSON object) and
# long-form analyses pass through BYTE-FOR-BYTE unchanged, so prose consumers are
# untouched.
#
# Shared by tools/flat-cyborg-claude.sh (the live wrapper pipes stdout through
# this) and tools/test-flat-cyborg-claude.sh (the unit test exercises this same
# file), so the wrapper and test can never drift apart.
import json
import re
import sys

# Max prose allowed on either side of an extracted JSON span. A lead-in like
# "Certainly! Here's the JSON object you requested:" or a trailer like "Let me
# know if you need anything else." is short; a genuine multi-paragraph analysis
# that merely *contains* a `{...}` is not, so it passes through untouched.
_MARGIN = 160

# Plain-text (non-JSON) sentinel unwrap (#1443): none of the JSON-shaped
# branches above fire for a bare "yes"/"no" or prose reply, so a leaked
# FCB_<hex>_BEGIN/_END screen-scrape wrapper around plain text used to pass
# through untouched, corrupting exact-string comparisons downstream. Strip
# the wrapper ONLY when the first line is a BEGIN marker and the last line
# is the matching END marker (same hex) -- a narrow, paired match so prose
# that merely mentions "FCB_..." mid-sentence is never touched. Internal
# newlines are preserved byte-for-byte (unlike the JSON path): prose
# formatting is meaningful, not just a parse artifact.
_SENTINEL_WRAP_RE = re.compile(
    r"^[ \t]*FCB_([0-9a-f]+)_BEGIN[ \t]*\n(.*)\n[ \t]*FCB_\1_END[ \t]*$",
    re.DOTALL,
)


def _collapse(js):
    # Collapse soft TUI line-wraps (newline + indent) to a single space so the
    # JSON lands on one line.
    return re.sub(r"\s*\n\s*", " ", js.strip())


def _valid_json(js):
    try:
        json.loads(js)
        return True
    except Exception:
        return False


def _unwrap(s):
    t = s.strip()
    if not t:
        return s

    # Fast path (unchanged): already a clean single JSON object.
    if t.startswith("{") and t.endswith("}"):
        c = _collapse(t)
        if _valid_json(c):
            return c
        return c  # preserve historical behaviour: collapse even if it won't parse

    # Markdown code fence: ```json ... ``` or ``` ... ``` wrapping the whole reply.
    m = re.match(r"^```[a-zA-Z0-9_-]*\s*\n?(.*?)\n?```\s*$", t, re.DOTALL)
    if m:
        inner = _collapse(m.group(1))
        if _valid_json(inner):
            return inner

    # Prose-wrapped JSON object or array: extract the outermost {...} / [...]
    # span, but only when it parses as JSON AND the surrounding prose is short.
    for open_c, close_c in (("{", "}"), ("[", "]")):
        start = t.find(open_c)
        end = t.rfind(close_c)
        if start != -1 and end > start:
            span = _collapse(t[start:end + 1])
            if _valid_json(span):
                lead = len(t[:start].strip())
                trail = len(t[end + 1:].strip())
                if lead <= _MARGIN and trail <= _MARGIN:
                    return span

    # Plain-text sentinel unwrap: none of the JSON branches above matched.
    sm = _SENTINEL_WRAP_RE.match(t)
    if sm:
        return sm.group(2)

    # Not JSON-shaped → passthrough byte-for-byte (prose consumers untouched).
    return s


if __name__ == "__main__":
    sys.stdout.write(_unwrap(sys.stdin.read()))
