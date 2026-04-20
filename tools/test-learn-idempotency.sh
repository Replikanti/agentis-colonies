#!/usr/bin/env bash
# test-learn-idempotency.sh -- Verify the #239 MR-learning idempotency gate
#
# Every implementation-colony agent that learns from merged MRs must:
#   1. Define `fn should_learn_from_mr(mr_iid: int) -> bool` following the
#      single-key-memo idiom established by the #200 gates.
#   2. Call it from `fn tick` immediately after extracting the top MR iid,
#      gating the mr-changes / mr-commits + prompt + learn block.
#   3. Write `<agent>:last_learned_mr_iid` inside the gate body before any
#      downstream work, so a subsequent prompt/commit failure does not
#      re-burn the LLM budget on the same MR next tick.
#
# Without this, the `merge-requests --since <last_check>` query keeps
# returning the same MR at index [0] as long as its updated_at keeps
# getting bumped, and the learning path prompt re-fires every tick —
# the tight-loop-of-duplicate-learns signature from issue #239.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/dev-apprenticeship/implementation/agents"

pass=0
fail=0

ok()   { echo "  ok — $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL — $1"; fail=$((fail + 1)); }

check_agent() {
    local agent="$1"
    local file="$AGENTS_DIR/${agent}.ag"
    echo "[$agent]"

    if [ ! -f "$file" ]; then
        bad "missing file: $file"
        return
    fi

    if grep -Fq "fn should_learn_from_mr(mr_iid: int) -> bool {" "$file"; then
        ok "gate function defined"
    else
        bad "gate function missing"
    fi

    if grep -Fq "recall_latest(\"${agent}:last_learned_mr_iid\")" "$file"; then
        ok "gate reads ${agent}:last_learned_mr_iid"
    else
        bad "gate does not recall ${agent}:last_learned_mr_iid"
    fi

    if grep -Fq "if should_learn_from_mr(mr_iid) {" "$file"; then
        ok "tick() calls gate"
    else
        bad "tick() does not call should_learn_from_mr(mr_iid)"
    fi

    if grep -Fq "memo_write(\"${agent}:last_learned_mr_iid\", to_string(mr_iid));" "$file"; then
        ok "memo_write stashes iid"
    else
        bad "memo_write for ${agent}:last_learned_mr_iid missing"
    fi

    # Defense-in-depth: the pre-gate `if mr_iid > 0 {` was removed (the
    # gate function already handles mr_iid <= 0). A lingering copy would
    # re-nest the learn block and is likely a merge mistake.
    if grep -Fq "if mr_iid > 0 {" "$file"; then
        bad "stale 'if mr_iid > 0' left in place — should be replaced by should_learn_from_mr call"
    else
        ok "no stale 'if mr_iid > 0' gate"
    fi
}

for agent in code_writer test_writer refactorer commit_composer; do
    check_agent "$agent"
done

echo
echo "learn-idempotency: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
