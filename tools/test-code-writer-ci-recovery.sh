#!/usr/bin/env bash
# test-code-writer-ci-recovery.sh (#1332): structural wiring assertions for the
# bounded CI-failure recovery loop in implementation/code_writer.ag.
#
# The .ag has no runtime unit harness (colony-lint's per-agent `agentis commit`
# parse is its gate), so — exactly like tools/test-code-writer-completion-
# markers.sh — we assert the recovery-path wiring at the grep level plus a parse
# check. The SAFETY invariants that MUST hold (this path re-pushes to PRs):
#
#   1. Recovery runs at the autonomous tier ONLY (re-pushing is a terminal write)
#      AND BEFORE the draft path (it returns without drafting on a launch).
#   2. Own PRs only: head branch must start `fix/issue-` (never touch a PR we
#      did not open).
#   3. Acts ONLY on STATE=red (never pending — don't race CI).
#   4. Retry cap 2 per PR via the ci_fix:attempts:<iid> memo; after that it
#      gives up + logs (needs human) and does NOT launch a 3rd job.
#   5. Recover launches code-edit-job.sh with --recover (push-only; no new PR).
#   6. Every dynamic exec-sh value is shell_escape'd (exec-sh safety is also
#      enforced federation-wide by check-exec-sh.sh; asserted here for the
#      recovery-specific commands too).
#
# Matches the test style of tools/test-code-writer-completion-markers.sh (bash,
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

# Body of the recover_at function (where the per-PR safety logic lives).
RECOVER_AT="$(awk '/^fn recover_at\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
RECOVER_REDPRS="$(awk '/^fn recover_red_prs\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"

# 1a. Autonomous-only gate in recover_red_prs.
if printf '%s' "$RECOVER_REDPRS" | grep -q 'repo_tier("code_writer", owner, repo) != "autonomous"'; then
    pass "recovery is gated on the autonomous tier (terminal-write guard)"
else
    fail "autonomous-only gate" "recover_red_prs must early-return when tier != autonomous"
fi

# 1b. recover_red_prs is CALLED at the top of tick_for_repo, BEFORE step 1
# (learn from merged MRs), and returns without drafting on a launch.
# The recover call line number must precede the "1. Learn from recently merged" marker.
rec_line="$(grep -n 'recover_red_prs(owner, repo) == 1' "$AG" | head -n1 | cut -d: -f1)"
learn_line="$(grep -n '1. Learn from recently merged MRs' "$AG" | head -n1 | cut -d: -f1)"
draft_line="$(grep -n 'should_draft_code(owner, repo' "$AG" | head -n1 | cut -d: -f1)"
if [ -n "$rec_line" ] && [ -n "$learn_line" ] && [ "$rec_line" -lt "$learn_line" ]; then
    pass "recover_red_prs runs at the TOP of tick_for_repo (before learn + draft)"
else
    fail "recover runs before draft" "rec_line=$rec_line learn_line=$learn_line draft_line=$draft_line"
fi
# It returns for the tick on a launch (one job per tick, do not also draft):
# a `return;` must appear within the few lines after the recover_red_prs==1
# guard, before the next blank line / step-1 marker.
if [ -n "$rec_line" ] && sed -n "${rec_line},$((rec_line + 8))p" "$AG" | grep -q 'return;'; then
    pass "a recovery launch returns for the tick (does not also draft)"
else
    fail "return-without-draft" "the recover_red_prs==1 branch must return;"
fi

# 2. Own PRs only: head must start fix/issue- (index_of == 0).
if printf '%s' "$RECOVER_AT" | grep -q 'index_of(src, "fix/issue-") != 0'; then
    pass "own-PRs-only guard: head branch must start fix/issue- (index_of == 0)"
else
    fail "own-PRs-only guard" "recover_at must reject branches not starting fix/issue-"
fi

# 3. Acts only on STATE=red.
if printf '%s' "$RECOVER_AT" | grep -q 'if state != "red" { return 0; }'; then
    pass "acts ONLY on STATE=red (pending/green are skipped — no CI race)"
else
    fail "red-only guard" "recover_at must early-return unless state == red"
fi
# The status is read from the thin mr-pipeline-status verb and classified by the
# .ag-local ci_state() helper (#1355 moved the red/green/pending mapping out of
# the forge wrapper into the agent).
if printf '%s' "$RECOVER_AT" | grep -q 'mr-pipeline-status ' && printf '%s' "$RECOVER_AT" | grep -q 'ci_state(pr_check_token(checks_out, "STATUS"))'; then
    pass "state comes from mr-pipeline-status (STATUS token) classified by ci_state()"
else
    fail "mr-pipeline-status wiring" "recover_at must call forge-api.sh mr-pipeline-status and classify STATUS via ci_state()"
fi

# 4a. Retry cap 2: give up after >= 2 attempts with the human-needed log.
if printf '%s' "$RECOVER_AT" | grep -q 'if attempts >= 2' \
   && printf '%s' "$RECOVER_AT" | grep -q 'CI-fix gave up on PR' \
   && printf '%s' "$RECOVER_AT" | grep -q 'needs human'; then
    pass "retry cap 2: gives up + logs 'needs human' after 2 attempts"
else
    fail "retry cap give-up" "recover_at must stop + log at attempts >= 2"
fi
# 4b. The give-up branch returns 0 (NO 3rd launch) — the launch (return 1) is
# only reached when attempts < 2.
GIVEUP_BLOCK="$(printf '%s' "$RECOVER_AT" | awk '/if attempts >= 2/{f=1} f{print} /};/{if(f){exit}}')"
if printf '%s' "$GIVEUP_BLOCK" | grep -q 'return 0;'; then
    pass "the give-up branch returns 0 (no 3rd code-edit-job launched)"
else
    fail "give-up returns 0" "after the cap the function must return 0, not launch"
fi
# 4c. The attempt memo is BUMPED (+1) before launch (fail-closed: never exceed 2).
if printf '%s' "$RECOVER_AT" | grep -q 'ci_fix:attempts:' \
   && printf '%s' "$RECOVER_AT" | grep -q 'let next_attempt = attempts + 1' \
   && printf '%s' "$RECOVER_AT" | grep -q 'memo_write(scoped_memo(owner, repo, "ci_fix:attempts:" + iid_str), to_string(next_attempt))'; then
    pass "attempt memo ci_fix:attempts:<iid> bumped (+1) before launch"
else
    fail "attempt memo bump" "recover_at must bump ci_fix:attempts:<iid> before launching"
fi

# 5. Launches code-edit-job.sh with --recover (push-only; no new PR), with the
# minimal-change recovery task.
if printf '%s' "$RECOVER_AT" | grep -q 'code-edit-job.sh' \
   && printf '%s' "$RECOVER_AT" | grep -q -- '--recover'; then
    pass "launches code-edit-job.sh --recover (re-drive existing branch, push only)"
else
    fail "--recover launch" "recover_at must launch code-edit-job.sh with --recover"
fi
# Re-drives the PR's ACTUAL head branch (source_branch / src), NOT a branch
# reconstructed from the PR number: a PR for issue N has its own number M != N,
# so "fix/issue-" + <PR iid> targets a non-existent branch (the bug #1330 hit).
if printf '%s' "$RECOVER_AT" | grep -q 'let branch_name = src' \
   && ! printf '%s' "$RECOVER_AT" | grep -q 'let branch_name = "fix/issue-" + iid_str'; then
    pass "re-drives the PR's actual head branch (src), not a reconstructed fix/issue-<PR-iid>"
else
    fail "head branch" "recover_at must pass --branch src (the PR's real source_branch), never fix/issue-<PR-iid>"
fi
if printf '%s' "$RECOVER_AT" | grep -q 'colony-lint) is failing' \
   && printf '%s' "$RECOVER_AT" | grep -q 'MINIMAL change'; then
    pass "recovery task instructs a MINIMAL, scoped fix (colony-lint gate)"
else
    fail "recovery task text" "the recover task must name colony-lint + a MINIMAL change"
fi
# Logs the re-drive with the attempt counter.
if printf '%s' "$RECOVER_AT" | grep -q 're-driving red PR'; then
    pass "logs 're-driving red PR <iid> (attempt N/2)'"
else
    fail "re-drive log line" "recover_at must log the re-drive with the attempt number"
fi

# 6. exec-sh safety: every dynamic value in the recovery exec-sh commands is
# wrapped in shell_escape(). The mr-pipeline-status + job commands are the writes here.
if printf '%s' "$RECOVER_AT" | grep -q 'mr-pipeline-status " + shell_escape(iid_str) + repo_arg' \
   && printf '%s' "$RECOVER_AT" | grep -q 'shell_escape(iid_str)' \
   && printf '%s' "$RECOVER_AT" | grep -q 'shell_escape(owner)' \
   && printf '%s' "$RECOVER_AT" | grep -q 'shell_escape(repo)'; then
    pass "dynamic exec-sh values are shell_escape'd (iid/owner/repo)"
else
    fail "exec-sh shell_escape" "recovery exec-sh commands must shell_escape dynamic values"
fi
# The two recovery exec-sh lines carry the safe-exec-concat lint pragma.
if grep -B1 'mr-pipeline-status " + shell_escape' "$AG" | grep -q 'colony-lint: safe-exec-concat' \
   && grep -B1 'code-edit-job.sh --owner " + shell_escape(owner) + " --repo " + shell_escape(repo) + " --issue " + shell_escape(iid_str)' "$AG" | grep -q 'colony-lint: safe-exec-concat'; then
    pass "recovery exec-sh lines carry the safe-exec-concat lint pragma"
else
    fail "safe-exec-concat pragma" "the recovery exec-sh command lines need the lint pragma"
fi

# Parse check: the agent commits cleanly under `agentis commit` (same as the
# per-agent syntax pass in colony-lint.sh). Skipped (not failed) when agentis
# is not installed.
if command -v agentis >/dev/null 2>&1; then
    LINT_TMP="$(mktemp -d)"
    (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
    if (cd "$LINT_TMP" && agentis commit "$AG") >/dev/null 2>&1; then
        pass "code_writer.ag parses (agentis commit) with the recovery path"
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
