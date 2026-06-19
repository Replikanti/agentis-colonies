#!/usr/bin/env bash
# test-mr-handoff-durable.sh: durable code_writer -> commit_composer MR handoff
# (#1151). Found during the #1117 first live federation run: the handoff relied
# on commit_composer catching a transient `implementation:code_draft` bus event
# inside a 100ms listen() window. When the event was missed the federation
# committed correct code to the branch but never opened the MR.
#
# The fix adds a durable single-slot memo handoff:
#   - code_writer, right after a successful autonomous commit, persists a
#     tab-delimited (issue_id, branch_name, summary) signal to the scoped memo
#     `implementation:pending_mr`.
#   - commit_composer's no-event branch (len(code_str) < 5) consults that memo,
#     and at the autonomous tier opens the MR via the same `create-mr` exec
#     path, emits `implementation:mr_ready`, records an idempotency marker
#     (`commit_composer:last_mr_issue`), and clears the pending memo.
#
# This test asserts the wiring is present and well-formed (grep-level) on both
# agents and that both `.ag` files parse. A full daemon-level integration run is
# out of scope.
#
# Usage: ./tools/test-mr-handoff-durable.sh [REPO_ROOT]
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
CODE_WRITER="$REPO_ROOT/dev-apprenticeship/implementation/agents/code_writer.ag"
COMMIT_COMPOSER="$REPO_ROOT/dev-apprenticeship/implementation/agents/commit_composer.ag"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# =============================================================================
# code_writer: persists the durable pending_mr memo after a successful commit.
# =============================================================================
if [ -f "$CODE_WRITER" ]; then
    if grep -q 'implementation:pending_mr' "$CODE_WRITER"; then
        pass "#1151 code_writer: writes the durable implementation:pending_mr memo"
    else
        fail "#1151 code_writer: missing implementation:pending_mr memo write"
    fi

    # The durable write must live in the committed-code path: it sits between
    # the `Committed code to` log line and the success learn() tags.
    if awk '
        /Committed code to/ { seen_commit = 1 }
        seen_commit && /implementation:pending_mr/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$CODE_WRITER"; then
        pass "#1151 code_writer: pending_mr memo written after the successful commit"
    else
        fail "#1151 code_writer: pending_mr memo not on the post-commit path"
    fi

    # Tab-delimited (issue_id, branch_name, summary) payload.
    if grep -Eq 'to_string\(draft\.issue_id\)[[:space:]]*\+[[:space:]]*"\\t"[[:space:]]*\+[[:space:]]*draft\.branch_name[[:space:]]*\+[[:space:]]*"\\t"[[:space:]]*\+[[:space:]]*draft\.summary' "$CODE_WRITER"; then
        pass "#1151 code_writer: pending_mr payload is tab-delimited issue/branch/summary"
    else
        fail "#1151 code_writer: pending_mr payload is not the tab-delimited issue/branch/summary triple"
    fi
else
    fail "#1151 code_writer: agent file not found at $CODE_WRITER"
fi

# =============================================================================
# commit_composer: durable fallback in the no-event branch.
# =============================================================================
if [ -f "$COMMIT_COMPOSER" ]; then
    # Reads the durable memo.
    if grep -q 'recall_latest(scoped_memo(owner, repo, "implementation:pending_mr"))' "$COMMIT_COMPOSER"; then
        pass "#1151 commit_composer: reads the durable implementation:pending_mr memo"
    else
        fail "#1151 commit_composer: does not recall the implementation:pending_mr memo"
    fi

    # The recall happens inside the no-event branch (after len(code_str) < 5),
    # before the live-event create-mr path.
    if awk '
        /len\(code_str\) < 5/ { in_noevent = 1 }
        in_noevent && /recall_latest\(scoped_memo\(owner, repo, "implementation:pending_mr"\)\)/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$COMMIT_COMPOSER"; then
        pass "#1151 commit_composer: durable recall sits inside the no-event branch"
    else
        fail "#1151 commit_composer: durable recall is not in the no-event branch"
    fi

    # Idempotency marker read + write.
    if grep -q 'commit_composer:last_mr_issue' "$COMMIT_COMPOSER"; then
        pass "#1151 commit_composer: tracks the last_mr_issue idempotency marker"
    else
        fail "#1151 commit_composer: missing the last_mr_issue idempotency marker"
    fi

    # Opens the MR via the same create-mr exec path.
    if grep -q 'create-mr --source' "$COMMIT_COMPOSER"; then
        pass "#1151 commit_composer: opens the MR via the create-mr exec path"
    else
        fail "#1151 commit_composer: missing the create-mr exec path"
    fi

    # The durable-handoff MR open carries its own log line.
    if grep -q 'Opened MR via durable handoff' "$COMMIT_COMPOSER"; then
        pass "#1151 commit_composer: logs the durable-handoff MR open"
    else
        fail "#1151 commit_composer: missing the durable-handoff MR open log line"
    fi

    # Emits implementation:mr_ready from the fallback path. The no-event branch
    # spans from `len(code_str) < 5` to its terminal top-level `return;`; assert
    # the emit appears inside that span.
    if awk '
        /len\(code_str\) < 5/ { in_noevent = 1 }
        in_noevent && /emit\("implementation:mr_ready"/ { found = 1 }
        in_noevent && /^        return;/ { in_noevent = 0 }
        END { exit(found ? 0 : 1) }
    ' "$COMMIT_COMPOSER"; then
        pass "#1151 commit_composer: emits implementation:mr_ready in the fallback path"
    else
        fail "#1151 commit_composer: does not emit implementation:mr_ready in the fallback path"
    fi

    # Clears the pending memo after a successful durable open (single-slot reset).
    if grep -q 'memo_write(scoped_memo(owner, repo, "implementation:pending_mr"), "")' "$COMMIT_COMPOSER"; then
        pass "#1151 commit_composer: clears the pending_mr memo after a durable open"
    else
        fail "#1151 commit_composer: does not clear the pending_mr memo after a durable open"
    fi

    # No double-open: BOTH the live-event MR open AND the durable fallback must
    # set last_mr_issue + clear pending_mr, else the fast path leaves pending_mr
    # set and the next tick's fallback re-opens a duplicate MR (QA #1151).
    mark_writes="$(grep -c 'memo_write(scoped_memo(owner, repo, "commit_composer:last_mr_issue"),' "$COMMIT_COMPOSER")"
    clear_writes="$(grep -c 'memo_write(scoped_memo(owner, repo, "implementation:pending_mr"), "")' "$COMMIT_COMPOSER")"
    if [ "$mark_writes" -ge 2 ] && [ "$clear_writes" -ge 2 ]; then
        pass "#1151 commit_composer: both live-event and fallback paths set last_mr_issue + clear pending_mr (no double-open)"
    else
        fail "#1151 commit_composer: live-event path missing the idempotency write (marks=$mark_writes clears=$clear_writes, need >=2 each)"
    fi

    # One tier() per tick: the fallback uses repo_tier(), and the no-event
    # branch returns before the live-event path's own repo_tier() can run.
    fallback_tier_count=$(grep -c 'repo_tier("commit_composer", owner, repo)' "$COMMIT_COMPOSER")
    if [ "$fallback_tier_count" = "2" ]; then
        pass "#1151 commit_composer: two repo_tier() sites (fallback + live), mutually exclusive per tick"
    else
        fail "#1151 commit_composer: expected exactly 2 repo_tier() sites, found $fallback_tier_count"
    fi

    # No new prompt() introduced in the fallback path (check-prompt-gate stays
    # clean): the no-event branch derives MR fields deterministically. Strip
    # `//` line comments before matching so the explanatory comment that names
    # prompt() is not mistaken for a call (mirrors check-prompt-gate.sh).
    if awk '
        { clean = $0; sub(/\/\/.*/, "", clean) }
        clean ~ /len\(code_str\) < 5/ { in_noevent = 1 }
        in_noevent && clean ~ /^        return;/ { in_noevent = 0 }
        in_noevent && clean ~ /prompt\(/ { found = 1 }
        END { exit(found ? 1 : 0) }
    ' "$COMMIT_COMPOSER"; then
        pass "#1151 commit_composer: fallback path adds no prompt() (deterministic MR fields)"
    else
        fail "#1151 commit_composer: fallback path introduced a prompt() (check-prompt-gate risk)"
    fi
else
    fail "#1151 commit_composer: agent file not found at $COMMIT_COMPOSER"
fi

# =============================================================================
# Both .ag files parse (agentis commit), when the runtime is installed.
# =============================================================================
if command -v agentis >/dev/null 2>&1; then
    PARSE_TMP="$(mktemp -d)"
    trap 'rm -rf "$PARSE_TMP"' EXIT
    (cd "$PARSE_TMP" && agentis init >/dev/null 2>&1) || true
    for ag in "$CODE_WRITER" "$COMMIT_COMPOSER"; do
        name="$(basename "$ag")"
        if (cd "$PARSE_TMP" && agentis commit "$ag") >/dev/null 2>&1; then
            pass "#1151 $name: parses (agentis commit)"
        else
            fail "#1151 $name: parse error (agentis commit)"
        fi
    done
else
    echo "[SKIP] agentis binary not installed — .ag parse check skipped"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
