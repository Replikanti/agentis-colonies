#!/bin/bash
# tools/test-candidate-queue.sh: unit test for tools/lib/candidate-queue.sh
# (#1273, M1 of #1266). Covers the queue primitive the issue_creator will
# consume:
#
#   1. Appending 3 records and reading back exactly 3 well-formed JSON lines.
#   2. Round-trip preservation of every field — including a title that
#      carries an embedded double-quote and newline — proving the python3
#      json.dumps encoding survives the memo read-modify-write cycle.
#   3. CANDIDATE_QUEUE_KEY override is honoured (the test points it at a
#      throwaway key).
#
# Hermetic: stubs `agentis memo get/set` with a file-backed shim on PATH so
# the test does not require a real agentis binary (mirrors the CI runners,
# where agentis is not installed).
#
# Usage: ./tools/test-candidate-queue.sh
# Exit 0 on full pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# --- Stub `agentis`: a file-backed `memo get/set` so the lib runs without
#     a real binary. One file per key under $STORE; keys are slugified so
#     `:` / `/` are filesystem-safe. ---
STORE="$TMPDIR_TEST/memo"
mkdir -p "$STORE"
cat > "$TMPDIR_TEST/agentis" <<'STUB'
#!/bin/bash
STORE_DIR="$AGENTIS_STUB_STORE"
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
if [ "${1:-}" = "memo" ] && [ "${2:-}" = "get" ]; then
    f="$STORE_DIR/$(slug "${3:-}")"
    [ -f "$f" ] && cat "$f"
    exit 0
fi
if [ "${1:-}" = "memo" ] && [ "${2:-}" = "set" ]; then
    f="$STORE_DIR/$(slug "${3:-}")"
    printf '%s' "${4:-}" > "$f"
    exit 0
fi
echo "agentis-stub: unsupported args: $*" >&2
exit 2
STUB
chmod +x "$TMPDIR_TEST/agentis"
export AGENTIS_STUB_STORE="$STORE"
export PATH="$TMPDIR_TEST:$PATH"

# Point the queue at a throwaway key and load the lib under test.
export CANDIDATE_QUEUE_KEY="test:candidate-queue:throwaway"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/candidate-queue.sh"

# --- Append 3 records. Record 2's title carries a double-quote and a
#     newline — the adversarial case for safe JSON encoding. ---
TRICKY_TITLE='He said "ship it"
on the next line'
candidate_queue_append "Plain title"      "body one"   "bug,triage"  "fp-aaa" "router"
candidate_queue_append "$TRICKY_TITLE"    "body\ntwo"  "enhancement" "fp-bbb" "labeler"
candidate_queue_append "Third & last <x>" "body three" "chore"       "fp-ccc" "prioritizer"

# --- Verify: read back, parse every non-empty line as JSON, assert the
#     count and that all fields round-tripped intact (the tricky title most
#     of all). Python does the structural assertions; the shell checks its
#     exit status. ---
if candidate_queue_read | python3 -c '
import json, sys

lines = [ln for ln in sys.stdin.read().split("\n") if ln != ""]
assert len(lines) == 3, "expected 3 JSONL lines, got %d" % len(lines)

recs = [json.loads(ln) for ln in lines]  # raises on any malformed line
fields = {"title", "body", "labels", "fingerprint", "source"}
for i, r in enumerate(recs):
    assert set(r) == fields, "record %d has fields %s" % (i, sorted(r))

assert recs[0]["title"] == "Plain title"
assert recs[0]["labels"] == "bug,triage"
assert recs[0]["fingerprint"] == "fp-aaa"
assert recs[0]["source"] == "router"

assert recs[1]["title"] == "He said \"ship it\"\non the next line", repr(recs[1]["title"])
assert recs[1]["body"] == "body\\ntwo"
assert recs[1]["source"] == "labeler"

assert recs[2]["title"] == "Third & last <x>"
assert recs[2]["body"] == "body three"
assert recs[2]["fingerprint"] == "fp-ccc"
'; then
    pass "1: 3 records append + read back as 3 well-formed JSON lines, fields intact (quote/newline safe)"
else
    fail "1: round-trip" "candidate_queue_read did not yield 3 intact records"
fi

# --- The override key actually holds the data; the default key is untouched. ---
if [ -f "$STORE/test_candidate-queue_throwaway" ] && [ ! -f "$STORE/issue_creator_candidates" ]; then
    pass "2: CANDIDATE_QUEUE_KEY override honoured (default key untouched)"
else
    fail "2: key override" "data not stored under the throwaway key"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
