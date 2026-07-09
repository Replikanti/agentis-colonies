#!/usr/bin/env bash
# test-code-writer-rebase-sweep.sh (#1518): structural wiring assertions for the
# auto-rebase sweep in implementation/code_writer.ag (sibling of the #1332
# fix-if-red recovery sweep).
#
# The .ag has no runtime unit harness (colony-lint's per-agent `agentis commit`
# parse is its gate), so — like tools/test-code-writer-ci-recovery.sh — we assert
# the sweep wiring at the grep level plus a parse check. The SAFETY invariants
# that MUST hold (this path force-pushes rebased branches):
#
#   1. The sweep runs at the autonomous tier ONLY (force-pushing is terminal)
#      AND FIRST in tick_for_repo — BEFORE recover_red_prs and the draft path
#      (a CONFLICTING PR has no fresh CI, so rebase must run first to produce one).
#   2. Own PRs only: head branch must start `fix/issue-` (never touch a foreign PR).
#   3. Acts ONLY on MERGEABLE==conflicting; unknown/true/false are skipped +
#      re-polled next tick (UNKNOWN is NEVER treated as clean or conflicting).
#   4. Retry cap 2 per PR via the rebase:attempts:<iid> memo (bumped BEFORE launch,
#      fail-closed); after that it gives up + logs and does NOT launch a 3rd job.
#   5. Launches code-edit-job.sh with --rebase (NOT --recover).
#   6. Every dynamic exec-sh value is shell_escape'd.
#
# Matches test-code-writer-ci-recovery.sh style. Exit 0 all-pass, 1 any-fail.
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

REBASE_AT="$(awk '/^fn rebase_at\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
REBASE_PRS="$(awk '/^fn rebase_conflicting_prs\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"

# 1a. Autonomous-only gate in rebase_conflicting_prs.
if printf '%s' "$REBASE_PRS" | grep -q 'repo_tier("code_writer", owner, repo) != "autonomous"'; then
    pass "rebase sweep is gated on the autonomous tier (force-push is terminal)"
else
    fail "autonomous-only gate" "rebase_conflicting_prs must early-return when tier != autonomous"
fi

# 1b. rebase_conflicting_prs runs FIRST in tick_for_repo — BEFORE recover_red_prs
# AND before the learn/draft path.
reb_line="$(grep -n 'rebase_conflicting_prs(owner, repo) == 1' "$AG" | head -n1 | cut -d: -f1)"
rec_line="$(grep -n 'recover_red_prs(owner, repo) == 1' "$AG" | head -n1 | cut -d: -f1)"
learn_line="$(grep -n '1. Learn from recently merged MRs' "$AG" | head -n1 | cut -d: -f1)"
if [ -n "$reb_line" ] && [ -n "$rec_line" ] && [ "$reb_line" -lt "$rec_line" ]; then
    pass "rebase_conflicting_prs runs BEFORE recover_red_prs in tick_for_repo"
else
    fail "rebase before recover" "reb_line=$reb_line rec_line=$rec_line"
fi
if [ -n "$reb_line" ] && [ -n "$learn_line" ] && [ "$reb_line" -lt "$learn_line" ]; then
    pass "rebase_conflicting_prs runs at the TOP of tick_for_repo (before learn + draft)"
else
    fail "rebase before draft" "reb_line=$reb_line learn_line=$learn_line"
fi
# It returns for the tick on a launch (one job per tick, do not also draft).
if [ -n "$reb_line" ] && sed -n "${reb_line},$((reb_line + 8))p" "$AG" | grep -q 'return;'; then
    pass "a rebase launch returns for the tick (does not also draft)"
else
    fail "return-without-draft" "the rebase_conflicting_prs==1 branch must return;"
fi

# 2. Own PRs only: head must start fix/issue- (index_of == 0).
if printf '%s' "$REBASE_AT" | grep -q 'index_of(src, "fix/issue-") != 0'; then
    pass "own-PRs-only guard: head branch must start fix/issue- (index_of == 0)"
else
    fail "own-PRs-only guard" "rebase_at must reject branches not starting fix/issue-"
fi

# 3. Acts ONLY on MERGEABLE==conflicting; unknown/true/false fall through.
if printf '%s' "$REBASE_AT" | grep -q 'pr_check_token(checks_out, "MERGEABLE")' \
   && printf '%s' "$REBASE_AT" | grep -q 'if mergeable != "conflicting" { return 0; }'; then
    pass "acts ONLY on MERGEABLE==conflicting (unknown/true/false skipped -> re-poll)"
else
    fail "conflicting-only guard" "rebase_at must read MERGEABLE and early-return unless == conflicting"
fi
# The MERGEABLE token comes from the thin mr-pipeline-status verb.
if printf '%s' "$REBASE_AT" | grep -q 'mr-pipeline-status '; then
    pass "mergeability comes from the mr-pipeline-status verb (MERGEABLE token)"
else
    fail "mr-pipeline-status wiring" "rebase_at must call forge-api.sh mr-pipeline-status"
fi
# UNKNOWN must NOT be branched into a rebase or a clean-treatment — the ONLY
# acted-on value is the literal "conflicting"; assert no `== "unknown"` action.
if ! printf '%s' "$REBASE_AT" | grep -q 'mergeable == "unknown"'; then
    pass "UNKNOWN is never special-cased into an action (falls through to skip)"
else
    fail "unknown not acted on" "rebase_at must not branch on mergeable == unknown"
fi

# 4a. Retry cap 2: give up after >= 2 attempts.
if printf '%s' "$REBASE_AT" | grep -q 'if attempts >= 2' \
   && printf '%s' "$REBASE_AT" | grep -q 'auto-rebase gave up on PR'; then
    pass "retry cap 2: gives up + logs after 2 attempts"
else
    fail "retry cap give-up" "rebase_at must stop + log at attempts >= 2"
fi
# 4b. The give-up branch returns 0 (no 3rd launch).
GIVEUP_BLOCK="$(printf '%s' "$REBASE_AT" | awk '/if attempts >= 2/{f=1} f{print} /};/{if(f){exit}}')"
if printf '%s' "$GIVEUP_BLOCK" | grep -q 'return 0;'; then
    pass "the give-up branch returns 0 (no 3rd rebase job launched)"
else
    fail "give-up returns 0" "after the cap the function must return 0, not launch"
fi
# 4c. The attempt memo is BUMPED (+1) before launch, keyed rebase:attempts:<iid>.
if printf '%s' "$REBASE_AT" | grep -q 'rebase:attempts:' \
   && printf '%s' "$REBASE_AT" | grep -q 'let next_attempt = attempts + 1' \
   && printf '%s' "$REBASE_AT" | grep -q 'memo_write(scoped_memo(owner, repo, "rebase:attempts:" + iid_str), to_string(next_attempt))'; then
    pass "attempt memo rebase:attempts:<iid> bumped (+1) before launch (fail-closed)"
else
    fail "attempt memo bump" "rebase_at must bump rebase:attempts:<iid> before launching"
fi
# 4d. The cap memo is a SEPARATE namespace from the CI-fix cap (no cross-contamination).
if printf '%s' "$REBASE_AT" | grep -q 'rebase:attempts:' \
   && ! printf '%s' "$REBASE_AT" | grep -q 'ci_fix:attempts:'; then
    pass "rebase cap uses its OWN memo namespace (rebase:attempts, not ci_fix:attempts)"
else
    fail "separate cap namespace" "rebase_at must not reuse the ci_fix:attempts memo"
fi

# 5. Launches code-edit-job.sh with --rebase, NOT --recover.
if printf '%s' "$REBASE_AT" | grep -q 'code-edit-job.sh' \
   && printf '%s' "$REBASE_AT" | grep -q -- '--rebase'; then
    pass "launches code-edit-job.sh --rebase"
else
    fail "--rebase launch" "rebase_at must launch code-edit-job.sh with --rebase"
fi
if printf '%s' "$REBASE_AT" | grep -q -- '--recover'; then
    fail "must not use --recover" "rebase_at must launch --rebase, never --recover"
else
    pass "rebase_at does NOT use --recover (rebase is a separate op)"
fi
# Rebases the PR's ACTUAL head branch (src), not a reconstructed fix/issue-<PR-iid>.
if printf '%s' "$REBASE_AT" | grep -q 'let branch_name = src' \
   && ! printf '%s' "$REBASE_AT" | grep -q 'let branch_name = "fix/issue-" + iid_str'; then
    pass "rebases the PR's actual head branch (src), not a reconstructed name"
else
    fail "head branch" "rebase_at must pass --branch src (the PR's real source_branch)"
fi

# 6. exec-sh safety: every dynamic value in the sweep exec-sh commands is
# wrapped in shell_escape().
if printf '%s' "$REBASE_AT" | grep -q 'mr-pipeline-status " + shell_escape(iid_str) + repo_arg' \
   && printf '%s' "$REBASE_AT" | grep -q 'shell_escape(iid_str)' \
   && printf '%s' "$REBASE_AT" | grep -q 'shell_escape(owner)' \
   && printf '%s' "$REBASE_AT" | grep -q 'shell_escape(repo)' \
   && printf '%s' "$REBASE_AT" | grep -q 'shell_escape(branch_name)'; then
    pass "dynamic exec-sh values are shell_escape'd (iid/owner/repo/branch)"
else
    fail "exec-sh shell_escape" "sweep exec-sh commands must shell_escape dynamic values"
fi
# The two sweep exec-sh command lines carry the safe-exec-concat lint pragma.
if grep -B1 'mr-pipeline-status " + shell_escape(iid_str) + repo_arg(owner, repo)' "$AG" | grep -q 'colony-lint: safe-exec-concat' \
   && grep -B1 'code-edit-job.sh --owner " + shell_escape(owner) + " --repo " + shell_escape(repo) + " --issue " + shell_escape(iid_str) + " --branch " + shell_escape(branch_name) + " --title " + shell_escape(rebase_title)' "$AG" | grep -q 'colony-lint: safe-exec-concat'; then
    pass "sweep exec-sh lines carry the safe-exec-concat lint pragma"
else
    fail "safe-exec-concat pragma" "the sweep exec-sh command lines need the lint pragma"
fi

# Parse check: the agent commits cleanly under `agentis commit`.
if command -v agentis >/dev/null 2>&1; then
    LINT_TMP="$(mktemp -d)"
    (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
    if (cd "$LINT_TMP" && agentis commit "$AG") >/dev/null 2>&1; then
        pass "code_writer.ag parses (agentis commit) with the rebase sweep"
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
