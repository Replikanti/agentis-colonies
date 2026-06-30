#!/usr/bin/env sh
# gen-mr-description.sh (#1347): generate a reviewer-facing MR/PR body from the
# issue (title + body) and the committed diff, via the result-file channel that
# flat-cyborg-claude.sh already exposes. Emits GitHub-flavored markdown with
# EXACTLY three sections — `## Problem`, `## Fix`, `## Testing` — and nothing
# else; in particular NO `Closes #N` line (the caller appends that).
#
# Why this exists: code-edit-in-checkout.sh used to open every PR/MR with a
# static `Closes #N. Autonomously implemented ...` body that carried no summary
# of the actual change, so a reviewer had to read the diff to learn what the MR
# did. This turns the issue + diff into a short, specific summary.
#
# Contract with the caller: on ANY failure mode — no LLM command, the LLM
# erroring, or an empty/whitespace-only reply — this prints NOTHING and exits 0,
# so code-edit-in-checkout.sh can fall back to its static template by inspecting
# stdout alone (no exit-code branching).
#
# Usage:
#   gen-mr-description.sh --issue <iid> --title <t> --task <body> [--diff-file <path>]
# The committed diff is read from --diff-file (a `git diff <base> HEAD` capture)
# or, when that flag is omitted/unreadable, from stdin. The diff is byte-capped
# (GEN_MR_DIFF_MAX_BYTES, default 60000) so a large change never overflows the
# LLM context — the head of a diff is the most informative part for a summary.
#
# GEN_MR_LLM_CMD overrides the LLM command (the test harness stubs
# flat-cyborg-claude.sh through it); it must read the prompt on stdin and print
# the reply on stdout, exactly like flat-cyborg-claude.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LLM_CMD="${GEN_MR_LLM_CMD:-$SCRIPT_DIR/flat-cyborg-claude.sh}"

ISSUE=""
TITLE=""
TASK=""
DIFF_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --issue) ISSUE="${2:-}"; shift 2 ;;
        --title) TITLE="${2:-}"; shift 2 ;;
        --task)  TASK="${2:-}";  shift 2 ;;
        --diff-file) DIFF_FILE="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done

# No usable LLM command -> cannot generate; caller falls back (silent exit 0).
# `command -v` resolves both a PATH name and an absolute executable path.
command -v "$LLM_CMD" >/dev/null 2>&1 || exit 0

# Read + byte-cap the committed diff (from the file or stdin).
DIFF_MAX="${GEN_MR_DIFF_MAX_BYTES:-60000}"
if [ -n "$DIFF_FILE" ] && [ -f "$DIFF_FILE" ]; then
    DIFF="$(head -c "$DIFF_MAX" "$DIFF_FILE")"
else
    DIFF="$(head -c "$DIFF_MAX")"
fi

# Built as a quoted multi-line assignment (not a heredoc) to mirror
# flat-cyborg-claude.sh and stay clear of any heredoc-indent surprises.
PROMPT="You are writing the description for the merge/pull request that resolves this issue. Output GitHub-flavored markdown with EXACTLY these three section headings, in this order, and nothing else:

## Problem
## Fix
## Testing

Under each heading write a few specific sentences grounded in the issue and the committed diff below: Problem = what was wrong and why it mattered; Fix = what the diff changes and how it resolves the problem; Testing = how the change was or should be verified. Do NOT add any other heading, a title line, a 'Closes #...' line, or any preamble or sign-off — output the three sections only.

--- ISSUE #$ISSUE: $TITLE ---
$TASK

--- COMMITTED DIFF ---
$DIFF"

# Drive the LLM. The wrapper reads its prompt from \$1 (falling back to stdin),
# so piping the prompt in works; a wrapper/LLM failure is swallowed -> fall back.
OUT="$(printf '%s' "$PROMPT" | "$LLM_CMD" 2>/dev/null)" || exit 0

# Empty / whitespace-only reply -> print nothing so the caller falls back.
printf '%s' "$OUT" | grep -q '[^[:space:]]' || exit 0

printf '%s\n' "$OUT"
