#!/usr/bin/env bash
# research-foundry/tools/test-submitter-classifier.sh -- regression
# test for the submitter's HITL-reject classifier.
#
# Covers:
#   (a) #643 -- the `topic_boring` regex no longer shadows `trivially`,
#       which is a `style_violation` per the editor's seed prompt.
#       Reproduces the classifier's Python one-liner inline so the
#       test runs without `agentis` or a live federation.
#
# Standard library only -- no pytest, no live federation. Python3 is
# required for the regex reproduction (matches the .ag prod path).
#
# Usage: bash research-foundry/tools/test-submitter-classifier.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"
SUBMITTER_AG="$FED_DIR/submitter/agents/submitter.ag"

PASS=0
FAIL=0
SKIP=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1: $2"; SKIP=$((SKIP + 1)); }

if [ ! -f "$SUBMITTER_AG" ]; then
    echo "[FAIL] submitter.ag not found at $SUBMITTER_AG" >&2
    exit 1
fi

# (a) #643 -- word-boundary regex sanity. Re-implement the
# classifier's Python one-liner verbatim and assert the
# misclassification reproducer from the issue body now lands in
# `style_violation`, while the substring matches that legitimately
# belong in `topic_boring` (the plain word `trivial`) are preserved.
classify() {
    python3 -c '
import sys, re
s = sys.argv[1].lower()
if re.search(r"\bwrong\b|\bincorrect\b|\berror\b|proof.*fail", s): print("math_wrong")
elif re.search(r"\bunreadable\b|\btypo\b|\bgrammar\b|\bprose\b", s): print("writing_bad")
elif re.search(r"\buninteresting\b|\btrivial\b|not.*novel", s): print("topic_boring")
elif re.search(r"off.?topic|\bscope\b|wrong.*category", s): print("scope_off")
elif re.search(r"\bobviously\b|\bclearly\b|\btrivially\b|\bhedge\b|\bstyle\b", s): print("style_violation")
else: print("other")
' "$1"
}

# (a1) #643 reproducer: "argument trivially follows" -- the original
# bug's seed input. Expected `style_violation`, NOT `topic_boring`.
got="$(classify 'argument trivially follows')"
if [ "$got" = "style_violation" ]; then
    pass "(a1) #643 'argument trivially follows' classifies as style_violation"
else
    fail "(a1) #643 'argument trivially follows' classifies as style_violation" \
         "got '$got'"
fi

# (a2) #643 follow-up phrasing from the issue body: a typical reviewer
# remark "this trivially generalises to ..." MUST also resolve to
# style_violation (the canonical math-style forbidden vocabulary).
got="$(classify 'a trivially correct proof')"
if [ "$got" = "style_violation" ]; then
    pass "(a2) #643 'a trivially correct proof' classifies as style_violation"
else
    fail "(a2) #643 'a trivially correct proof' classifies as style_violation" \
         "got '$got'"
fi

# (a3) Preserve original semantics: the bare word `trivial` (no -ly
# suffix) is still legitimately a `topic_boring` signal.
got="$(classify 'this result is trivial')"
if [ "$got" = "topic_boring" ]; then
    pass "(a3) #643 'this result is trivial' still classifies as topic_boring"
else
    fail "(a3) #643 'this result is trivial' still classifies as topic_boring" \
         "got '$got'"
fi

# (a4) Word-boundary safety check: the substring `error` inside a
# longer non-error word ("mirrored") must not shadow into math_wrong.
got="$(classify 'the figure is mirrored along axis')"
if [ "$got" = "other" ]; then
    pass "(a4) #643 'mirrored' does not shadow into math_wrong"
else
    fail "(a4) #643 'mirrored' does not shadow into math_wrong" \
         "got '$got'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
