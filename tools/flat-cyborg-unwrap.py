#!/usr/bin/env python3
# tools/flat-cyborg-unwrap.py (#1163): post-process a flat-cyborg --extract
# reply so a JSON-shaped reply that flat-cyborg's --extract-structural
# screen-scrape LINE-WRAPPED (the TUI folds long output, injecting
# newline+indent INSIDE the JSON string) parses again.
#
# Heuristic (safe, narrow): only fires when the trimmed reply looks like a
# single JSON object — it starts with `{` AND ends with `}`. In that case any
# run of `\s*\n\s*` (a soft TUI line-wrap + indent) collapses to one space, so
# the JSON lands on one line. Anything else (prose, code, markdown, multi-line
# explanations from other federations) passes through BYTE-FOR-BYTE unchanged,
# so prose consumers are untouched.
#
# Shared by tools/flat-cyborg-claude.sh (the live wrapper pipes stdout through
# this) and tools/test-flat-cyborg-claude.sh (the unit test exercises this same
# file), so the wrapper and test can never drift apart.
import re
import sys

s = sys.stdin.read()
t = s.strip()
if t.startswith("{") and t.endswith("}"):
    sys.stdout.write(re.sub(r"\s*\n\s*", " ", t))
else:
    sys.stdout.write(s)
