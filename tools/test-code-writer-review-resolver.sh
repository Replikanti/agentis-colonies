#!/usr/bin/env bash
# test-code-writer-review-resolver.sh (#1360): structural wiring assertions for
# the bounded review-finding recovery loop (the review-resolver pattern) in
# implementation/code_writer.ag.
#
# The .ag has no runtime unit harness (colony-lint's per-agent `agentis commit`
# parse is its gate), so — exactly like tools/test-code-writer-ci-recovery.sh —
# we assert the resolver-path wiring at the grep level plus a parse check. The
# SAFETY invariants that MUST hold (this path re-pushes to PRs):
#
#   1. The resolver runs at the autonomous tier ONLY (re-pushing is a terminal
#      write).
#   2. resolve_review_prs runs AFTER recover_red_prs and BEFORE the draft path,
#      and a launch returns without drafting (one code-edit job per tick).
#   3. Own PRs only: head branch must start `fix/issue-` (never touch a PR we did
#      not open).
#   4. Acts ONLY on state green (red is owned by recover_red_prs — no race;
#      pending => don't race CI), read from the forge mr-pipeline-status STATUS
#      token and classified by the .ag-local ci_state() helper (#1355).
#   5. Idempotency: re-drive only when the newest actionable note id is strictly
#      greater than the review_fix:last_note:<iid> watermark, written AFTER the
#      launch but SKIPPED on a RUNNING cap-defer (#1379) so a deferral never
#      blocks re-entry; fail-closed on any real launch.
#   6. Retry cap 2 per PR via review_fix:attempts:<iid> (bumped after launch,
#      skipped on a RUNNING cap-defer so a deferral never consumes the budget);
#      after that it gives up + logs (needs human) and does NOT launch a 3rd job.
#   7. The launch uses code-edit-job.sh --recover (push-only; no new PR), with a
#      findings-derived --task, keying --issue on the PR iid and --branch on src.
#   8. Every dynamic exec-sh value is shell_escape'd and each resolver forge call
#      line carries the // colony-lint: safe-exec-concat pragma.
#
# Matches the test style of tools/test-code-writer-ci-recovery.sh (bash,
# [PASS]/[FAIL] lines, `Results: N passed, M failed`). Exit 0 all-pass, 1 any-fail.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
AG="$REPO_ROOT/dev-apprenticeship/implementation/agents/code_writer.ag"
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if [ ! -f "$AG" ]; then
    echo "[FAIL] code_writer.ag present: missing $AG"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# Bodies of the two functions where the per-PR safety logic lives.
RESOLVE_AT="$(awk '/^fn resolve_review_at\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
RESOLVE_PRS="$(awk '/^fn resolve_review_prs\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"

# 1. Autonomous-only gate in resolve_review_prs.
if printf '%s' "$RESOLVE_PRS" | grep -Fq 'repo_tier("code_writer", owner, repo) != "autonomous"'; then
    pass "review-resolver is gated on the autonomous tier (terminal-write guard)"
else
    fail "autonomous-only gate" "resolve_review_prs must early-return when tier != autonomous"
fi

# 2. resolve_review_prs is CALLED in tick_for_repo AFTER recover_red_prs and
# BEFORE step 1 (learn from merged MRs), and returns without drafting on a launch.
rec_line="$(grep -n 'recover_red_prs(owner, repo) == 1' "$AG" | head -n1 | cut -d: -f1)"
rev_line="$(grep -n 'resolve_review_prs(owner, repo) == 1' "$AG" | head -n1 | cut -d: -f1)"
learn_line="$(grep -n '1. Learn from recently merged MRs' "$AG" | head -n1 | cut -d: -f1)"
if [ -n "$rec_line" ] && [ -n "$rev_line" ] && [ -n "$learn_line" ] \
   && [ "$rec_line" -lt "$rev_line" ] && [ "$rev_line" -lt "$learn_line" ]; then
    pass "resolve_review_prs runs AFTER recover_red_prs and BEFORE the draft path"
else
    fail "resolver ordering" "rec_line=$rec_line rev_line=$rev_line learn_line=$learn_line"
fi
# It returns for the tick on a launch (one job per tick, do not also draft).
if [ -n "$rev_line" ] && sed -n "${rev_line},$((rev_line + 8))p" "$AG" | grep -q 'return;'; then
    pass "a review-fix launch returns for the tick (does not also draft)"
else
    fail "return-without-draft" "the resolve_review_prs==1 branch must return;"
fi

# 3. Own PRs only: head must start fix/issue- (index_of == 0).
if printf '%s' "$RESOLVE_AT" | grep -Fq 'index_of(src, "fix/issue-") != 0'; then
    pass "own-PRs-only guard: head branch must start fix/issue- (index_of == 0)"
else
    fail "own-PRs-only guard" "resolve_review_at must reject branches not starting fix/issue-"
fi

# 4. Acts ONLY on state green (the inverse of recover_at's red-only guard); the
# verdict is read from the forge mr-pipeline-status STATUS token, classified by
# ci_state(). It must NOT act on red.
if printf '%s' "$RESOLVE_AT" | grep -Fq 'if state != "green" { return 0; }'; then
    pass "acts ONLY on STATE=green (red/pending are skipped — no CI race)"
else
    fail "green-only guard" "resolve_review_at must early-return unless state == green"
fi
if printf '%s' "$RESOLVE_AT" | grep -Fq 'if state != "red"'; then
    fail "no red handling" "resolve_review_at must NOT act on red (red is owned by recover_red_prs)"
else
    pass "does not act on red (delegated to recover_red_prs)"
fi
if printf '%s' "$RESOLVE_AT" | grep -Fq 'mr-pipeline-status ' && printf '%s' "$RESOLVE_AT" | grep -Fq 'ci_state(pr_check_token(checks_out, "STATUS"))'; then
    pass "state comes from mr-pipeline-status (STATUS token) classified by ci_state()"
else
    fail "mr-pipeline-status wiring" "resolve_review_at must call forge-api.sh mr-pipeline-status and classify STATUS via ci_state()"
fi

# 5. Idempotency: re-drive only when the newest actionable note id is strictly
# greater than the review_fix:last_note:<iid> watermark, written BEFORE launch.
if printf '%s' "$RESOLVE_AT" | grep -Fq 'review_fix:last_note:' \
   && printf '%s' "$RESOLVE_AT" | grep -Fq 'if note_id <= parse_int(last_seen) { return 0; }'; then
    pass "idempotency: re-drives only when note_id > review_fix:last_note watermark"
else
    fail "note-id idempotency" "resolve_review_at must gate on note_id > last_seen watermark"
fi
# The watermark memo is written AFTER the launch and is GATED behind the RUNNING
# cap-defer guard (#1379): a deferred launch (no job dir created) must NOT advance
# the watermark, else re-entry for this note id is blocked. Fail-closed otherwise —
# any real launch (incl. a crash mid-launch) writes it. Ordering: launch < RUNNING
# guard < watermark write.
notewm_pos="$(printf '%s\n' "$RESOLVE_AT" | grep -n 'review_fix:last_note:" + iid_str), note_id_str)' | head -n1 | cut -d: -f1)"
job_pos="$(printf '%s\n' "$RESOLVE_AT" | grep -n 'code-edit-job.sh' | head -n1 | cut -d: -f1)"
running_pos="$(printf '%s\n' "$RESOLVE_AT" | grep -n 'if job_state == "RUNNING"' | head -n1 | cut -d: -f1)"
if [ -n "$notewm_pos" ] && [ -n "$job_pos" ] && [ -n "$running_pos" ] \
   && [ "$job_pos" -lt "$running_pos" ] && [ "$running_pos" -lt "$notewm_pos" ]; then
    pass "review_fix:last_note watermark written AFTER launch, skipped on RUNNING cap-defer (#1379)"
else
    fail "watermark after launch, skipped on RUNNING defer" "job_pos=$job_pos running_pos=$running_pos notewm_pos=$notewm_pos"
fi

# 6. Retry cap 2: give up after >= 2 attempts with the human-needed log; the
# give-up branch returns 0 (no 3rd launch); the attempt memo is bumped before launch.
if printf '%s' "$RESOLVE_AT" | grep -Fq 'if attempts >= 2' \
   && printf '%s' "$RESOLVE_AT" | grep -Fq 'review-fix gave up on PR' \
   && printf '%s' "$RESOLVE_AT" | grep -Fq 'needs human'; then
    pass "retry cap 2: gives up + logs 'needs human' after 2 attempts"
else
    fail "retry cap give-up" "resolve_review_at must stop + log at attempts >= 2"
fi
GIVEUP_BLOCK="$(printf '%s' "$RESOLVE_AT" | awk '/if attempts >= 2/{f=1} f{print} /};/{if(f){exit}}')"
if printf '%s' "$GIVEUP_BLOCK" | grep -Fq 'return 0;'; then
    pass "the give-up branch returns 0 (no 3rd code-edit-job launched)"
else
    fail "give-up returns 0" "after the cap the function must return 0, not launch"
fi
# The attempt memo is BUMPED (+1) AFTER a real launch and SKIPPED on a RUNNING
# cap-defer (#1379), so a deferral never consumes the 2-attempt budget. next_attempt
# is still computed up-front; the memo_write lands behind the RUNNING guard.
attempts_pos="$(printf '%s\n' "$RESOLVE_AT" | grep -n 'review_fix:attempts:" + iid_str), to_string(next_attempt))' | head -n1 | cut -d: -f1)"
if printf '%s' "$RESOLVE_AT" | grep -Fq 'let next_attempt = attempts + 1' \
   && [ -n "$attempts_pos" ] && [ -n "$running_pos" ] && [ "$running_pos" -lt "$attempts_pos" ]; then
    pass "review_fix:attempts:<iid> bumped (+1) after launch, skipped on RUNNING cap-defer"
else
    fail "attempt memo bump" "resolve_review_at must bump review_fix:attempts:<iid> behind the RUNNING guard"
fi

# 7. Launches code-edit-job.sh with --recover (push-only; no new PR), a
# findings-derived --task, keyed on the PR iid and the PR's actual head branch.
if printf '%s' "$RESOLVE_AT" | grep -Fq 'code-edit-job.sh' \
   && printf '%s' "$RESOLVE_AT" | grep -q -- '--recover'; then
    pass "launches code-edit-job.sh --recover (re-drive existing branch, push only)"
else
    fail "--recover launch" "resolve_review_at must launch code-edit-job.sh with --recover"
fi
# Re-drives the PR's ACTUAL head branch (src), NOT a reconstructed fix/issue-<iid>.
if printf '%s' "$RESOLVE_AT" | grep -Fq 'let branch_name = src' \
   && ! printf '%s' "$RESOLVE_AT" | grep -Fq 'let branch_name = "fix/issue-" + iid_str'; then
    pass "re-drives the PR's actual head branch (src), not a reconstructed fix/issue-<iid>"
else
    fail "head branch" "resolve_review_at must pass --branch src, never fix/issue-<PR-iid>"
fi
# The task is derived from the actionable findings bodies and asks for a MINIMAL change.
if printf '%s' "$RESOLVE_AT" | grep -Fq 'Address these code-review findings' \
   && printf '%s' "$RESOLVE_AT" | grep -Fq 'MINIMAL change' \
   && printf '%s' "$RESOLVE_AT" | grep -Fq '+ bodies'; then
    pass "review-fix task is findings-derived and instructs a MINIMAL, scoped change"
else
    fail "review-fix task text" "the task must concatenate the findings bodies + a MINIMAL change"
fi
# --issue keys on the PR iid; the verb reads the durable notes via the mr-notes verb.
if printf '%s' "$RESOLVE_AT" | grep -Fq -- '--issue " + shell_escape(iid_str)' \
   && printf '%s' "$RESOLVE_AT" | grep -Fq 'mr-notes " + shell_escape(iid_str)'; then
    pass "keys --issue on the PR iid and reads findings via the durable mr-notes verb"
else
    fail "issue keying / mr-notes" "resolve_review_at must key --issue on iid and read mr-notes"
fi

# 8. exec-sh safety: every dynamic value in the resolver exec-sh commands is
# shell_escape'd; each resolver forge call line carries the safe-exec-concat pragma.
if printf '%s' "$RESOLVE_AT" | grep -Fq 'mr-pipeline-status " + shell_escape(iid_str) + repo_arg' \
   && printf '%s' "$RESOLVE_AT" | grep -Fq 'shell_escape(owner)' \
   && printf '%s' "$RESOLVE_AT" | grep -Fq 'shell_escape(repo)'; then
    pass "dynamic exec-sh values are shell_escape'd (iid/owner/repo)"
else
    fail "exec-sh shell_escape" "resolver exec-sh commands must shell_escape dynamic values"
fi
if grep -B1 'mr-notes " + shell_escape' "$AG" | grep -Fq 'colony-lint: safe-exec-concat' \
   && grep -B1 'merge-requests --state opened" + repo_arg(owner, repo)' "$AG" | grep -Fq 'colony-lint: safe-exec-concat'; then
    pass "resolver forge-call exec-sh lines carry the safe-exec-concat lint pragma"
else
    fail "safe-exec-concat pragma" "the resolver exec-sh command lines need the lint pragma"
fi
# No prompt() is added on the resolver path (it mirrors recover_at — keep it
# prompt-free so check-prompt-gate.sh is not triggered).
if printf '%s' "$RESOLVE_AT" | grep -Fq 'prompt('; then
    fail "no prompt on resolver path" "resolve_review_at must stay prompt-free (mirror recover_at)"
else
    pass "resolver path is prompt-free (check-prompt-gate not triggered)"
fi

# 9. Parse check: the agent commits cleanly under `agentis commit` (same as the
# per-agent syntax pass in colony-lint.sh). Skipped (not failed) when agentis is
# not installed.
if command -v agentis >/dev/null 2>&1; then
    LINT_TMP="$(mktemp -d)"
    (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
    if (cd "$LINT_TMP" && agentis commit "$AG") >/dev/null 2>&1; then
        pass "code_writer.ag parses (agentis commit) with the review-resolver path"
    else
        fail "code_writer.ag parses (agentis commit)" "syntax error in code_writer.ag"
    fi
    rm -rf "$LINT_TMP"
else
    echo "[SKIP] agentis not on PATH — skipping .ag parse check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
