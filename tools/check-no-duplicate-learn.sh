#!/usr/bin/env bash
# check-no-duplicate-learn.sh: fail if any research-foundry .ag helper
# (`fn _publish_<role>(...)` or `fn _submitter_*(...)`) emits an
# unconditional top-level `learn(..., ["emitted", ...])` row.
#
# Background (#636): at the `autonomous` and `review-gated` tiers the
# tick branch emits a `learn(..., ["acted" | "review-gated", ...])`
# row, then calls `_publish_<role>(...)`. If that helper also emits
# an unconditional `learn(..., ["emitted", ...])` row, ACTING-tagged
# rows inflate 2x per tick because `acted`, `review-gated`, and
# `emitted` all live in `ACTING_TAGS` in auto-promote-decisions.py.
#
# Fix pattern: gate the helper's `learn()` on `if my_tier == "propose"`.
# This check enforces that every `learn(..., ["emitted", ...])` row
# inside a `_publish_*` / `_submitter_*` helper body is wrapped in an
# `if my_tier == "propose"` block.
#
# Usage: ./tools/check-no-duplicate-learn.sh [path-to-repo-root-or-file]
# Exit 0 if clean, 1 if a violation is found.
#
# Accepts either a repo root (scans research-foundry/ recursively) or a
# single .ag file path (single-file mode for unit-test fixtures).
#
# Runs on bash 3.2+ (stock macOS /bin/bash) and bash 4+.

set -euo pipefail

SCAN_ARG="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# Single-file mode: target is a regular .ag file.
if [ -f "$SCAN_ARG" ]; then
    files=("$SCAN_ARG")
else
    TARGET_DIR="$SCAN_ARG/research-foundry"
    if [ ! -d "$TARGET_DIR" ]; then
        # No research-foundry tree to scan -- treat as clean.
        exit 0
    fi
    files=()
    while IFS= read -r -d '' ag_file; do
        files+=("$ag_file")
    done < <(find "$TARGET_DIR" -type f -name "*.ag" -print0 2>/dev/null)
fi

violations=0

# scan_file <path>
# For each `fn _publish_<role>(...) -> ... { ... }` or
# `fn _submitter_<phase>(...) -> ... { ... }` block in the file,
# verify that every `learn(..., ["emitted", ...])` call inside the
# helper body is wrapped in an `if my_tier == "propose"` block.
#
# The body is defined as the lines between the `fn` opening brace
# and the matching closing brace at column 1 (top-level `}`).
scan_file() {
    local ag_file="$1"
    python3 - "$ag_file" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Find every `fn _publish_<role>(` or `fn _submitter_<phase>(` line.
fn_re = re.compile(r'^fn (_publish_[a-z_]+|_submitter_[a-z_]+)\s*\(')
learn_re = re.compile(r'\blearn\s*\(')
emitted_tag_re = re.compile(r'"emitted"')
gate_re = re.compile(r'\bif\s+my_tier\s*==\s*"propose"')

# A `_publish_prompt_body_and_wrap_variant` helper exists in every
# .ag file but never calls learn() -- skip it.
SKIP_HELPERS = {"_publish_prompt_body_and_wrap_variant"}

violations = []

i = 0
n = len(lines)
while i < n:
    line = lines[i]
    m = fn_re.match(line)
    if not m:
        i += 1
        continue
    helper = m.group(1)
    if helper in SKIP_HELPERS:
        i += 1
        continue

    # Walk forward to the opening `{` of the helper body.
    body_start = None
    j = i
    while j < n:
        if '{' in lines[j]:
            body_start = j
            break
        j += 1
    if body_start is None:
        i += 1
        continue

    # Walk forward to the matching top-level `}` (column 1).
    body_end = None
    k = body_start + 1
    while k < n:
        if lines[k].startswith('}'):
            body_end = k
            break
        k += 1
    if body_end is None:
        i += 1
        continue

    # Scan body for learn() rows that include an "emitted" tag. The
    # tag list may span multiple lines (rare; not in today's codebase),
    # so the per-line `learn(...` match is paired with a per-line
    # `"emitted"` literal match -- both must be on the same line, since
    # every `learn(..., ["emitted", ...])` row in research-foundry/
    # today is single-line.
    for li in range(body_start, body_end + 1):
        text = lines[li]
        if not learn_re.search(text):
            continue
        if not emitted_tag_re.search(text):
            continue
        # Walk upward to find an `if my_tier == "propose"` gate. If we
        # hit the helper start without seeing one, the learn() is
        # unconditional from the helper's perspective -- a #636
        # violation. The walk does not try to track brace nesting; the
        # canonical fix wraps the learn() in a one-line gate immediately
        # preceding it, which this loop catches.
        gated = False
        for back in range(li, body_start - 1, -1):
            if gate_re.search(lines[back]):
                gated = True
                break
        if not gated:
            violations.append((path, li + 1, helper, lines[li].rstrip()))

    i = body_end + 1

if violations:
    for v in violations:
        print(f"[FAIL] {v[0]}:{v[1]} helper={v[2]} unconditional emitted learn(): {v[3].strip()}")
    sys.exit(1)
PY
}

if [ ${#files[@]} -gt 0 ]; then
    for ag_file in "${files[@]}"; do
        if ! scan_file "$ag_file"; then
            violations=$((violations + 1))
        fi
    done
fi

if [ "$violations" -eq 0 ]; then
    exit 0
fi

echo ""
echo 'Issue #636: tier-branch helpers must gate their learn(..., ["emitted", ...])'
echo 'row on if my_tier == "propose". At autonomous / review-gated tiers, the'
echo 'inline tier branch already emits an acted/review-gated row; an unconditional'
echo 'helper-level emitted row inflates the ACTING_TAGS row count 2x per tick.'
exit 1
