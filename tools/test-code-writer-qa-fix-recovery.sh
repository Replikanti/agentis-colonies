#!/usr/bin/env bash
# test-code-writer-qa-fix-recovery.sh (#1521): structural wiring assertions for
# the bounded QA-block recovery loop (the fix-if-qa-block pattern — the adversarial
# analog of fix-if-red #1332) in implementation/code_writer.ag.
#
# A green PR blocked by an adversarial qa_reviewer verdict (the #1484 marker
# `<!-- qa-verdict head=<fp16> status=block -->`) used to sit HELD forever: the
# gate is fail-safe but nothing consumed the block to revise the code. This sweep
# closes the loop — re-drives the fix on the block reason, bounded by a MONOTONIC
# PER-ISSUE cap, behind a default-OFF operator flag.
#
# The .ag has no runtime unit harness (colony-lint's per-agent `agentis commit`
# parse is its gate), so — like tools/test-code-writer-review-resolver.sh — we
# assert the sweep-path wiring at the grep level plus a parse check. The SAFETY
# invariants that MUST hold (this path re-pushes to PRs):
#
#   1. block-on-current-head-detected-and-redriven: head_fingerprint +
#      block_reason_for_head drive the detection; the launch is code-edit-job.sh
#      --recover with the block reason as --task; returns 1.
#   2. stale-block-on-old-head-not-redriven: detection keys on the RECOMPUTED
#      head_fp, so a marker with a different head= returns "" => no launch.
#   3. per-issue-cap-monotonic-across-heads-escalates-after-2: qa_fix:attempts is
#      per ISSUE, never keyed on head, bumped after launch; the 3rd block posts
#      the qa_fix:escalated note and does NOT launch.
#   4. same-block-not-redriven-twice: qa_fix:last_block:<iid> == head_fp early
#      returns.
#   5. feature-flag-off-is-noop: getenv("QA_FIX_RECOVERY_ENABLED") != "1" is the
#      FIRST statement of recover_qa_block_prs, before any forge read.
#   6. guarded-push-refuse-does-not-loop: the launch uses --recover (inherits the
#      #1516 guarded_push foreign-commit refusal); a non-RUNNING result still
#      bumps qa_fix:attempts, so a refusal escalates after 2, never loops.
#   7. routing-exactly-one-path: red -> recover_red_prs (state green guard),
#      conflicting -> rebase_conflicting_prs (mergeable != conflicting guard),
#      green+block -> this sweep; tick order rebase -> red -> resolve_review ->
#      qa-block -> draft, each returns 1 to halt the tick.
#   8. head-fingerprint-byte-identical: code_writer.head_fingerprint is
#      byte-identical to qa_reviewer / approval_decider.
#   9. autonomous-tier-only + safe-exec-concat-pragmas.
#
# Matches the test style of tools/test-code-writer-review-resolver.sh (bash,
# [PASS]/[FAIL] lines, `Results: N passed, M failed`). Exit 0 all-pass, 1 any-fail.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
AG="$REPO_ROOT/dev-apprenticeship/implementation/agents/code_writer.ag"
QA_AG="$REPO_ROOT/dev-apprenticeship/code-review/agents/qa_reviewer.ag"
AD_AG="$REPO_ROOT/dev-apprenticeship/code-review/agents/approval_decider.ag"
INSTALL_SH="$REPO_ROOT/dev-apprenticeship/install.sh"
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

# Bodies of the functions where the per-PR safety logic lives.
QA_AT="$(awk '/^fn recover_qa_block_at\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
QA_PRS="$(awk '/^fn recover_qa_block_prs\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
QA_REASON="$(awk '/^fn block_reason_for_head\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"

# ---------------------------------------------------------------------------
# 1. block-on-current-head-detected-and-redriven
# ---------------------------------------------------------------------------
if printf '%s' "$QA_AT" | grep -Fq 'let head_fp = head_fingerprint(changes_raw)' \
   && printf '%s' "$QA_AT" | grep -Fq 'let reason = block_reason_for_head(notes_raw, head_fp)'; then
    pass "detection: head_fingerprint(mr-changes) + block_reason_for_head(mr-notes, head_fp)"
else
    fail "detection helpers" "recover_qa_block_at must compute head_fp and block_reason_for_head"
fi
if printf '%s' "$QA_AT" | grep -Fq 'code-edit-job.sh' \
   && printf '%s' "$QA_AT" | grep -q -- '--recover' \
   && printf '%s' "$QA_AT" | grep -Fq '+ reason'; then
    pass "re-drive: launches code-edit-job.sh --recover with the block reason as the --task brief"
else
    fail "--recover launch with reason" "the launch must be code-edit-job.sh --recover and feed reason into --task"
fi
# The block reason drives at most one re-drive; a launch returns 1 for the tick.
QA_AT_LAST="$(printf '%s\n' "$QA_AT" | tail -n 8)"
if printf '%s' "$QA_AT_LAST" | grep -Fq 'return 1;'; then
    pass "a QA-fix launch returns 1 (one job per tick, do not also draft)"
else
    fail "return 1 on launch" "recover_qa_block_at must return 1 after a launch"
fi
# The brief follows resolve_review_at's shape (MINIMAL, scoped, the block reason).
if printf '%s' "$QA_AT" | grep -Fq 'A pre-merge QA review BLOCKED this change' \
   && printf '%s' "$QA_AT" | grep -Fq 'MINIMAL change'; then
    pass "brief: reason-derived, instructs a MINIMAL, scoped fix (resolve_review_at shape)"
else
    fail "brief text" "the --task must carry the block reason + a MINIMAL-change instruction"
fi

# ---------------------------------------------------------------------------
# 2. stale-block-on-old-head-not-redriven
# ---------------------------------------------------------------------------
# Detection keys on the RECOMPUTED head_fp; block_reason_for_head only matches a
# marker whose head= equals it (re.escape(h)), so a stale block on an old head
# yields "" and the empty-reason guard early-returns (no launch).
if printf '%s' "$QA_REASON" | grep -Fq 'head=\"+re.escape(h)+\" status=(pass|block) -->'; then
    pass "stale-block: block_reason_for_head matches ONLY the marker for the recomputed head_fp"
else
    fail "head-keyed reason" "block_reason_for_head must key the marker on the passed head_fp"
fi
if printf '%s' "$QA_AT" | grep -Fq 'if len(reason) == 0 { return 0; }'; then
    pass "stale-block: an empty reason (no block for the CURRENT head) early-returns (no re-drive)"
else
    fail "empty-reason guard" "recover_qa_block_at must return 0 when block_reason_for_head is empty"
fi
# block_reason_for_head prints "" when the newest matching marker is status=pass
# (a re-review that cleared the head) — the #1493 newest-first race guard.
if printf '%s' "$QA_REASON" | grep -Fq 'if m.group(1)==\"block\":' \
   && printf '%s' "$QA_REASON" | grep -Fq 'print(\"\"); sys.exit(0)'; then
    pass "stale-block: a newest status=pass marker yields \"\" (flipped-to-pass = no re-drive)"
else
    fail "pass-flip guard" "block_reason_for_head must return \"\" when the newest match is status=pass"
fi

# ---------------------------------------------------------------------------
# 3. per-issue-cap-monotonic-across-heads-escalates-after-2
# ---------------------------------------------------------------------------
# The attempt counter is per ISSUE (qa_fix:attempts:<iid>), NEVER keyed on head.
if printf '%s' "$QA_AT" | grep -Fq 'qa_fix:attempts:" + iid_str' \
   && ! printf '%s' "$QA_AT" | grep -Fq 'qa_fix:attempts:" + head_fp'; then
    pass "cap: qa_fix:attempts keyed on the ISSUE iid, never on the head fp (monotonic per issue)"
else
    fail "per-issue cap key" "qa_fix:attempts must key on iid_str, never head_fp"
fi
# qa_fix_attempts reads the same per-issue key (no head component).
QA_ATTEMPTS_FN="$(awk '/^fn qa_fix_attempts\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
if printf '%s' "$QA_ATTEMPTS_FN" | grep -Fq 'qa_fix:attempts:" + iid_str'; then
    pass "cap: qa_fix_attempts reads qa_fix:attempts:<iid> (per-issue), missing => 0"
else
    fail "qa_fix_attempts key" "qa_fix_attempts must read qa_fix:attempts:<iid>"
fi
# Cap 2: >= 2 gives up, posts the one-time escalation note, and does NOT launch.
if printf '%s' "$QA_AT" | grep -Fq 'if attempts >= 2' \
   && printf '%s' "$QA_AT" | grep -Fq 'QA auto-fix gave up' \
   && printf '%s' "$QA_AT" | grep -Fq 'needs a human'; then
    pass "cap: >= 2 attempts posts the one-time 'needs a human' escalation note"
else
    fail "cap escalation" "recover_qa_block_at must escalate at attempts >= 2 with a human note"
fi
GIVEUP_BLOCK="$(printf '%s' "$QA_AT" | awk '/if attempts >= 2/{f=1} f{print} /^    };/{if(f){exit}}')"
if printf '%s' "$GIVEUP_BLOCK" | grep -Fq 'return 0;'; then
    pass "cap: the give-up branch returns 0 (no 3rd code-edit-job launched)"
else
    fail "give-up returns 0" "after the cap the function must return 0, not launch"
fi
# The escalation note is one-time, guarded by qa_fix:escalated:<iid>.
if printf '%s' "$QA_AT" | grep -Fq 'qa_fix:escalated:" + iid_str' \
   && printf '%s' "$QA_AT" | grep -Fq 'if len(escalated) == 0'; then
    pass "cap: the escalation note is one-time (guarded by qa_fix:escalated:<iid>)"
else
    fail "escalation guard" "the human note must be guarded by qa_fix:escalated:<iid>"
fi

# ---------------------------------------------------------------------------
# 4. same-block-not-redriven-twice (idempotency)
# ---------------------------------------------------------------------------
# The head-fp watermark (qa_fix:last_block:<iid>) suppresses a second re-drive of
# the SAME head's block; it is written AFTER launch and SKIPPED on a RUNNING
# cap-defer (#1379). A NEW head has a NEW fp, so a fresh block on it is a fresh
# attempt (still under the per-issue cap).
if printf '%s' "$QA_AT" | grep -Fq 'qa_fix:last_block:" + iid_str' \
   && printf '%s' "$QA_AT" | grep -Fq 'if last_block == head_fp { return 0; }'; then
    pass "idempotency: qa_fix:last_block:<iid> == head_fp early-returns (same block re-driven once)"
else
    fail "last_block watermark" "recover_qa_block_at must early-return when last_block == head_fp"
fi
lastblock_pos="$(printf '%s\n' "$QA_AT" | grep -n 'qa_fix:last_block:" + iid_str), head_fp)' | head -n1 | cut -d: -f1)"
job_pos="$(printf '%s\n' "$QA_AT" | grep -n 'code-edit-job.sh' | head -n1 | cut -d: -f1)"
running_pos="$(printf '%s\n' "$QA_AT" | grep -n 'if job_state == "RUNNING"' | head -n1 | cut -d: -f1)"
if [ -n "$lastblock_pos" ] && [ -n "$job_pos" ] && [ -n "$running_pos" ] \
   && [ "$job_pos" -lt "$running_pos" ] && [ "$running_pos" -lt "$lastblock_pos" ]; then
    pass "idempotency: qa_fix:last_block written AFTER launch, skipped on RUNNING cap-defer (#1379)"
else
    fail "watermark after launch, skipped on RUNNING defer" "job_pos=$job_pos running_pos=$running_pos lastblock_pos=$lastblock_pos"
fi
# The attempt memo is BUMPED (+1) after launch and lands behind the RUNNING guard,
# so a deferral never consumes the 2-attempt budget.
attempts_pos="$(printf '%s\n' "$QA_AT" | grep -n 'qa_fix:attempts:" + iid_str), to_string(next_attempt))' | head -n1 | cut -d: -f1)"
if printf '%s' "$QA_AT" | grep -Fq 'let next_attempt = attempts + 1' \
   && [ -n "$attempts_pos" ] && [ -n "$running_pos" ] && [ "$running_pos" -lt "$attempts_pos" ]; then
    pass "cap: qa_fix:attempts:<iid> bumped (+1) after launch, skipped on RUNNING cap-defer (never reset per head)"
else
    fail "attempt memo bump" "recover_qa_block_at must bump qa_fix:attempts:<iid> behind the RUNNING guard"
fi

# ---------------------------------------------------------------------------
# 5. feature-flag-off-is-noop
# ---------------------------------------------------------------------------
# getenv("QA_FIX_RECOVERY_ENABLED") != "1" must be the FIRST statement of
# recover_qa_block_prs — before repo_tier, before any forge read (zero-forge-read
# no-op when off).
FLAG_LINE="$(printf '%s\n' "$QA_PRS" | grep -n 'getenv("QA_FIX_RECOVERY_ENABLED")' | head -n1 | cut -d: -f1)"
TIER_LINE="$(printf '%s\n' "$QA_PRS" | grep -n 'repo_tier("code_writer"' | head -n1 | cut -d: -f1)"
FORGE_LINE="$(printf '%s\n' "$QA_PRS" | grep -n 'forge-api.sh' | head -n1 | cut -d: -f1)"
if printf '%s' "$QA_PRS" | grep -Fq 'if getenv("QA_FIX_RECOVERY_ENABLED") != "1" { return 0; }' \
   && [ -n "$FLAG_LINE" ] && [ -n "$TIER_LINE" ] && [ -n "$FORGE_LINE" ] \
   && [ "$FLAG_LINE" -lt "$TIER_LINE" ] && [ "$FLAG_LINE" -lt "$FORGE_LINE" ]; then
    pass "flag-off: the QA_FIX_RECOVERY_ENABLED gate is the FIRST statement (before tier + any forge read)"
else
    fail "flag-first no-op" "flag=$FLAG_LINE tier=$TIER_LINE forge=$FORGE_LINE — the flag must gate first"
fi
# The knob is on the install.sh allowlist (write_key literal) + #1437 residue list.
if grep -Fq "write_key 'exec.env_passthrough'" "$INSTALL_SH" \
   && grep "write_key 'exec.env_passthrough'" "$INSTALL_SH" | grep -Fq 'QA_FIX_RECOVERY_ENABLED'; then
    pass "flag: QA_FIX_RECOVERY_ENABLED is on the install.sh exec.env_passthrough write_key literal (getenv sees it)"
else
    fail "allowlist write_key" "QA_FIX_RECOVERY_ENABLED must be on the write_key exec.env_passthrough literal"
fi
if awk '/^[[:space:]]*for[[:space:]]+knob[[:space:]]+in/{c=1} c{print} /;[[:space:]]*do/{if(c)exit}' "$INSTALL_SH" | grep -Fq 'QA_FIX_RECOVERY_ENABLED'; then
    pass "flag: QA_FIX_RECOVERY_ENABLED is in the install.sh #1437 residue-check for-knob list"
else
    fail "residue list" "QA_FIX_RECOVERY_ENABLED must be in the #1437 for knob in ... residue list"
fi

# ---------------------------------------------------------------------------
# 6. guarded-push-refuse-does-not-loop
# ---------------------------------------------------------------------------
# The launch uses --recover (inherits the #1516 guarded_push foreign-commit
# refusal from code-edit-in-checkout.sh). A refusal is a non-RUNNING result, so it
# falls through to the attempts bump — counted toward the cap, escalates after 2,
# never loops. Assert: only a RUNNING state skips the attempts write.
if printf '%s' "$QA_AT" | grep -Fq 'if job_state == "RUNNING"'; then
    pass "guarded-push: only a RUNNING cap-defer skips the attempts write; a refusal counts toward the cap"
else
    fail "RUNNING-only skip" "only job_state == RUNNING may skip the attempts bump (a refusal must count)"
fi

# ---------------------------------------------------------------------------
# 7. routing-exactly-one-path
# ---------------------------------------------------------------------------
# green+block owns this sweep: state == green AND mergeable != conflicting.
if printf '%s' "$QA_AT" | grep -Fq 'if state != "green" { return 0; }'; then
    pass "routing: acts ONLY on STATE=green (red -> recover_red_prs, pending -> no CI race)"
else
    fail "green-only guard" "recover_qa_block_at must early-return unless state == green"
fi
if printf '%s' "$QA_AT" | grep -Fq 'if mergeable == "conflicting" { return 0; }'; then
    pass "routing: skips MERGEABLE=conflicting (owned by rebase_conflicting_prs)"
else
    fail "conflicting guard" "recover_qa_block_at must skip mergeable == conflicting"
fi
if printf '%s' "$QA_AT" | grep -Fq 'index_of(src, "fix/issue-") != 0'; then
    pass "routing: own-PRs-only (head branch must start fix/issue-)"
else
    fail "own-PRs-only guard" "recover_qa_block_at must reject branches not starting fix/issue-"
fi
# Tick order: rebase -> red -> resolve_review -> qa-block -> draft, each halts.
rebase_line="$(grep -n 'rebase_conflicting_prs(owner, repo) == 1' "$AG" | head -n1 | cut -d: -f1)"
red_line="$(grep -n 'recover_red_prs(owner, repo) == 1' "$AG" | head -n1 | cut -d: -f1)"
rev_line="$(grep -n 'resolve_review_prs(owner, repo) == 1' "$AG" | head -n1 | cut -d: -f1)"
qa_line="$(grep -n 'recover_qa_block_prs(owner, repo) == 1' "$AG" | head -n1 | cut -d: -f1)"
learn_line="$(grep -n '1. Learn from recently merged MRs' "$AG" | head -n1 | cut -d: -f1)"
if [ -n "$rebase_line" ] && [ -n "$red_line" ] && [ -n "$rev_line" ] && [ -n "$qa_line" ] && [ -n "$learn_line" ] \
   && [ "$rebase_line" -lt "$red_line" ] && [ "$red_line" -lt "$rev_line" ] \
   && [ "$rev_line" -lt "$qa_line" ] && [ "$qa_line" -lt "$learn_line" ]; then
    pass "routing: tick order rebase -> red -> resolve_review -> qa-block -> draft"
else
    fail "tick order" "rebase=$rebase_line red=$red_line rev=$rev_line qa=$qa_line learn=$learn_line"
fi
# The qa-block sweep launch halts the tick (returns before drafting).
if [ -n "$qa_line" ] && sed -n "${qa_line},$((qa_line + 8))p" "$AG" | grep -q 'return;'; then
    pass "routing: a QA-fix launch returns for the tick (does not also draft)"
else
    fail "return-without-draft" "the recover_qa_block_prs==1 branch must return;"
fi

# ---------------------------------------------------------------------------
# 8. head-fingerprint-byte-identical
# ---------------------------------------------------------------------------
CW_FP="$(awk '/^fn head_fingerprint\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
if [ -f "$QA_AG" ]; then
    QA_FP="$(awk '/^fn head_fingerprint\(/{f=1} f{print} /^}/{if(f) f=0}' "$QA_AG")"
    if [ -n "$CW_FP" ] && [ "$CW_FP" = "$QA_FP" ]; then
        pass "byte-identity: code_writer.head_fingerprint == qa_reviewer.head_fingerprint"
    else
        fail "fp byte-identity (qa_reviewer)" "the two head_fingerprint bodies differ — a stale block would never be detectable"
    fi
else
    fail "qa_reviewer.ag present" "missing $QA_AG"
fi
if [ -f "$AD_AG" ]; then
    AD_FP="$(awk '/^fn head_fingerprint\(/{f=1} f{print} /^}/{if(f) f=0}' "$AD_AG")"
    if [ -n "$CW_FP" ] && [ "$CW_FP" = "$AD_FP" ]; then
        pass "byte-identity: code_writer.head_fingerprint == approval_decider.head_fingerprint"
    else
        fail "fp byte-identity (approval_decider)" "code_writer/approval_decider head_fingerprint bodies differ"
    fi
else
    fail "approval_decider.ag present" "missing $AD_AG"
fi

# ---------------------------------------------------------------------------
# 9. autonomous-tier-only + safe-exec-concat-pragmas + prompt-free
# ---------------------------------------------------------------------------
if printf '%s' "$QA_PRS" | grep -Fq 'repo_tier("code_writer", owner, repo) != "autonomous"'; then
    pass "autonomous-tier-only: recover_qa_block_prs early-returns when tier != autonomous"
else
    fail "autonomous-only gate" "recover_qa_block_prs must gate on the autonomous tier"
fi
if printf '%s' "$QA_AT" | grep -Fq 'shell_escape(iid_str)' \
   && printf '%s' "$QA_AT" | grep -Fq 'shell_escape(owner)' \
   && printf '%s' "$QA_AT" | grep -Fq 'shell_escape(repo)'; then
    pass "exec-sh safety: dynamic values are shell_escape'd (iid/owner/repo)"
else
    fail "exec-sh shell_escape" "the sweep exec-sh commands must shell_escape dynamic values"
fi
if grep -B1 'mr-changes " + shell_escape(iid_str) + repo_arg(owner, repo);' "$AG" | grep -Fq 'colony-lint: safe-exec-concat' \
   && grep -B1 'post-note " + shell_escape(iid_str)' "$AG" | grep -Fq 'colony-lint: safe-exec-concat'; then
    pass "exec-sh safety: sweep forge-call exec-sh lines carry the safe-exec-concat lint pragma"
else
    fail "safe-exec-concat pragma" "the sweep exec-sh command lines need the lint pragma"
fi
if printf '%s' "$QA_AT" | grep -Fq 'prompt(' || printf '%s' "$QA_PRS" | grep -Fq 'prompt('; then
    fail "no prompt on sweep path" "the QA-block sweep must stay prompt-free (mirror resolve_review_at)"
else
    pass "sweep path is prompt-free (check-prompt-gate not triggered)"
fi

# ---------------------------------------------------------------------------
# 10. Parse check: the agent commits cleanly under `agentis commit`.
# ---------------------------------------------------------------------------
if command -v agentis >/dev/null 2>&1; then
    LINT_TMP="$(mktemp -d)"
    (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
    if (cd "$LINT_TMP" && agentis commit "$AG") >/dev/null 2>&1; then
        pass "code_writer.ag parses (agentis commit) with the QA-block recovery path"
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
