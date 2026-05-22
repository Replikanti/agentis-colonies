#!/usr/bin/env bash
# research-foundry/tools/test-topic-pinning.sh -- regression test for
# the #719 per-explorer topic pinning mapping in `tools/run-research.sh`.
#
# Asserts:
#   (a) `_explorer_topic_for_specialty` returns the expected topic for
#       each of the 5 bootstrap-seeded explorer specialties.
#   (b) Unknown specialties return the empty string so the orchestrator
#       skips per-daemon memo writes and the explorer falls back to the
#       global `replay:current_topic`.
#
# Standard library only -- no live federation, no podman exec.
#
# Usage: bash research-foundry/tools/test-topic-pinning.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"
ORCH="$FED_DIR/tools/run-research.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

# Extract the case-block function in isolation so sourcing the full
# orchestrator (which does heavy bootstrap work at load time) is not
# required. The 7-line block (`_explorer_topic_for_specialty()` { ... })
# is grep'd out by anchor lines, then evaluated in this shell.
extract_fn() {
    awk '/^_explorer_topic_for_specialty\(\) \{$/,/^\}$/' "$ORCH"
}

fn_body="$(extract_fn)"
if [ -z "$fn_body" ]; then
    fail "extract_fn" "could not locate _explorer_topic_for_specialty in $ORCH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
eval "$fn_body"

assert_topic() {
    local specialty="$1" expected="$2"
    local got
    got="$(_explorer_topic_for_specialty "$specialty")"
    if [ "$got" = "$expected" ]; then
        pass "mapping: $specialty -> $expected"
    else
        fail "mapping: $specialty" "expected '$expected', got '$got'"
    fi
}

assert_topic group_theory   abstract_algebra
assert_topic combinatorics  combinatorics
assert_topic number_theory  number_theory
assert_topic probability    graph_theory
assert_topic algebra        abstract_algebra
assert_topic ""             ""
assert_topic unknown_spec   ""
assert_topic evolved_x      ""

# Live-registry discovery test (#724). Mirrors the glob+regex block in
# the orchestrator's `research_loop` Python heredoc. Fixture: an initial
# explorer (daemon_id=1) plus a post-cull replica (daemon_id=7), with a
# decoy `specialty_overlay` sibling file that must be rejected.
tmp_memo_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_memo_dir"' EXIT
: > "$tmp_memo_dir/explorer:pool:specialty:1.jsonl"
: > "$tmp_memo_dir/explorer:pool:specialty:7.jsonl"
: > "$tmp_memo_dir/explorer:pool:specialty_overlay:1.jsonl"

discovered_ids="$(python3 - "$tmp_memo_dir" <<'PYDISCOVER'
import glob, os, re, sys
memo_dir = sys.argv[1]
spec_re = re.compile(r"^explorer:pool:specialty:(\d+)\.jsonl$")
ids = []
for path in glob.glob(os.path.join(memo_dir, "explorer:pool:specialty:*.jsonl")):
    m = spec_re.match(os.path.basename(path))
    if m:
        ids.append(int(m.group(1)))
ids.sort()
print(",".join(str(i) for i in ids))
PYDISCOVER
)"

if [ "$discovered_ids" = "1,7" ]; then
    pass "live-registry discovery: ids=[1,7], overlay rejected"
else
    fail "live-registry discovery" "expected '1,7', got '$discovered_ids'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
