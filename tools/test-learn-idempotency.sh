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

    # Loose signature check (QA #7): match the function by name + open paren
    # only, not the full `(mr_iid: int) -> bool` signature — a harmless
    # parameter rename should not false-fail this test.
    if grep -Eq "^fn should_learn_from_mr\(" "$file"; then
        ok "gate function defined"
    else
        bad "gate function missing"
    fi

    # Post-#316 M3b, the per-repo memo key is built via scoped_memo(owner,
    # repo, "<agent>:last_learned_mr_iid"). On single-block configs scoped_memo
    # passes the suffix through unchanged so the resolved key is byte-identical
    # to the pre-M3 literal `<agent>:last_learned_mr_iid`. The literal suffix
    # must still appear (as the third arg to scoped_memo) anywhere in the file.
    if grep -Fq "scoped_memo(owner, repo, \"${agent}:last_learned_mr_iid\")" "$file"; then
        ok "gate reads ${agent}:last_learned_mr_iid via scoped_memo (M3b per-repo)"
    else
        bad "gate does not recall ${agent}:last_learned_mr_iid via scoped_memo"
    fi

    if grep -Fq "if should_learn_from_mr(" "$file"; then
        ok "tick_for_repo() calls gate"
    else
        bad "tick_for_repo() does not call should_learn_from_mr"
    fi

    # The memo_write call now wraps the key in scoped_memo; the literal
    # suffix `<agent>:last_learned_mr_iid` must still appear inside that
    # scoped_memo call (matched by the recall check above).
    if grep -Fq "memo_write(scoped_memo(owner, repo, \"${agent}:last_learned_mr_iid\")," "$file"; then
        ok "memo_write stashes iid via scoped_memo (M3b per-repo)"
    else
        bad "memo_write for ${agent}:last_learned_mr_iid via scoped_memo missing"
    fi

    # Ordering invariant (QA #6): memo_write MUST appear before the first
    # prompt() call that follows the `if should_learn_from_mr(...) {` line.
    # The at-most-once-per-iid semantics depend on the memo being stamped
    # before the prompt fires — a future refactor that moves the memo-write
    # after prompt() re-opens the re-burn window on prompt failures.
    local gate_line memo_line prompt_line
    gate_line="$(grep -n "if should_learn_from_mr(" "$file" | head -1 | cut -d: -f1 || true)"
    memo_line="$(grep -n "memo_write(scoped_memo(owner, repo, \"${agent}:last_learned_mr_iid\")," "$file" | head -1 | cut -d: -f1 || true)"
    prompt_line="$(awk -v g="${gate_line:-0}" 'NR>g && /prompt\(/ {print NR; exit}' "$file")"
    if [ -n "$gate_line" ] && [ -n "$memo_line" ] && [ -n "$prompt_line" ] \
       && [ "$memo_line" -gt "$gate_line" ] && [ "$memo_line" -lt "$prompt_line" ]; then
        ok "memo_write before first prompt() inside gate body (lines ${gate_line} < ${memo_line} < ${prompt_line})"
    else
        bad "ordering broken: gate=${gate_line:-?} memo=${memo_line:-?} prompt=${prompt_line:-?} — memo_write must be between gate and first prompt()"
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
