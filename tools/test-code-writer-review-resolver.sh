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

# ---------------------------------------------------------------------------
# actionable_note native reader (#1613 Phase 2 PR B): the review-resolver feeder
# is now a single json_array_reduce call (agentis >= 1.22.3), no embedded python.
# ---------------------------------------------------------------------------
ACTIONABLE="$(awk '/^fn actionable_note\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"

# 10a. Native: no embedded python / exec sh; the keep predicate rides
# json_array_reduce with the documented `must|any` grammar (system!=true must,
# is_human/is_req/is_draft-phrase in the OR half).
if ! printf '%s' "$ACTIONABLE" | grep -Fq 'python3 -c' \
   && ! printf '%s' "$ACTIONABLE" | grep -Fq 'exec sh' \
   && printf '%s' "$ACTIONABLE" | grep -Fq 'json_array_reduce(raw, ""'; then
    pass "(P2B) actionable_note is native — no embedded python / exec sh, rides json_array_reduce"
else
    fail "(P2B) native actionable_note" "actionable_note must be a plain json_array_reduce reader (no python3 -c / exec sh)"
fi
# The keep string: system!=true must-clause, the is_req startswith (^=) and the
# is_draft phrase (~) in the any half, plus the empty-me fail-safe branch that
# omits the author clause.
if printf '%s' "$ACTIONABLE" | grep -Fq 'system!=true|' \
   && printf '%s' "$ACTIONABLE" | grep -Fq 'body^=**Review Summary** (automated)' \
   && printf '%s' "$ACTIONABLE" | grep -Fq 'author.username!=" + me' \
   && printf '%s' "$ACTIONABLE" | grep -Fq 'if len(me) == 0'; then
    pass "(P2B) keep predicate: system!=true must + is_req/is_draft any half + empty-me author-omit fail-safe"
else
    fail "(P2B) keep predicate" "actionable_note must encode system!=true|author.username!=me;body^=...;body~... with the empty-me branch"
fi

# 10b. Cross-agent contract pin (mitigates the template coupling): the is_draft
# clause `body~suggested action \`request_changes\`` depends on approval_decider's
# draft template (approval_decider.ag:932 emits `suggested action \`<action>\``,
# with `request_changes` a valid action enum). Red-fail if either side is reworded
# so the two are updated together, not silently decoupled.
AD="$REPO_ROOT/dev-apprenticeship/code-review/agents/approval_decider.ag"
# shellcheck disable=SC2016  # the backticks are literal .ag template bytes, not command substitution
if printf '%s' "$ACTIONABLE" | grep -Fq 'body~suggested action `request_changes`'; then
    if [ -f "$AD" ] \
       && grep -Fq 'suggested action `" + decision.action + "`' "$AD" \
       && grep -Fq '[draft-review-decision]' "$AD" \
       && grep -Fq "'request_changes'" "$AD"; then
        pass "(P2B) cross-agent pin: actionable_note's draft clause matches approval_decider's :932 \`suggested action \`<action>\`\` template"
    else
        fail "(P2B) cross-agent template drift" "approval_decider.ag must still emit the [draft-review-decision] \`suggested action \`<action>\`\` template with request_changes a valid action"
    fi
else
    fail "(P2B) draft clause" "actionable_note must key is_draft on the phrase 'suggested action \`request_changes\`'"
fi

# 10c. Live `agentis go` behavioral probe (the test-approval-decider-review-gate.sh
# #1514 precedent; skipped when agentis is absent, so CI runners are unaffected):
# awk-extract fn actionable_note verbatim into a probe, drive an mr-notes fixture,
# and assert the keep predicate + max-id + ascending-id concat + escaping ON THE
# ACTUAL .ag path (no hand-kept oracle can drift from it).
if command -v agentis >/dev/null 2>&1; then
    AN_TMP="$(mktemp -d)"
    {
        awk '/^fn actionable_note\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG"
        # Single-tab helpers so every assertion prints on ONE line (the ascending
        # multi-note concat uses REAL `\n\n`, so we never print a body verbatim —
        # only maxid / index positions).
        cat <<'AGEOF'
fn maxid(r: string) -> string {
    let p = index_of(r, "\t");
    if p < 0 { return ""; };
    return substring(r, 0, p);
}
fn body_of(r: string) -> string {
    let p = index_of(r, "\t");
    if p < 0 { return ""; };
    return substring(r, p + 1, len(r));
}
fn sel(raw: string, me: string) -> string {
    let r = actionable_note(raw, me);
    if len(r) == 0 { return "EMPTY"; };
    return maxid(r);
}
let ME = "dev-bot";
let J_SYS = "[{\"id\":10,\"system\":true,\"author\":{\"username\":\"someone\"},\"body\":\"changed the description\"}]";
let J_OWN = "[{\"id\":11,\"system\":false,\"author\":{\"username\":\"dev-bot\"},\"body\":\"looking into it\"}]";
let J_REQ = "[{\"id\":12,\"system\":false,\"author\":{\"username\":\"dev-bot\"},\"body\":\"**Review Summary** (automated)\n\nplease fix X\"}]";
let J_HUMAN = "[{\"id\":13,\"system\":false,\"author\":{\"username\":\"alice\"},\"body\":\"this needs work\"}]";
let J_DRAFTRC = "[{\"id\":14,\"system\":false,\"author\":{\"username\":\"dev-bot\"},\"body\":\"[draft-review-decision] **Review Summary** (automated, pending approval): suggested action `request_changes`\n\nreasoning here\"}]";
let J_DRAFTAP = "[{\"id\":15,\"system\":false,\"author\":{\"username\":\"dev-bot\"},\"body\":\"[draft-review-decision] **Review Summary** (automated, pending approval): suggested action `approve`\n\nnot a request_changes situation\"}]";
let J_MULTI = "[{\"id\":13,\"system\":false,\"author\":{\"username\":\"alice\"},\"body\":\"human A\"},{\"id\":12,\"system\":false,\"author\":{\"username\":\"dev-bot\"},\"body\":\"**Review Summary** (automated)\n\nfix now\"}]";
let J_TAB = "[{\"id\":16,\"system\":false,\"author\":{\"username\":\"alice\"},\"body\":\"col1\tcol2\"}]";
let J_NULL = "[{\"id\":17,\"system\":false,\"author\":null,\"body\":\"orphan note\"}]";
let J_MEDOT = "[{\"id\":18,\"system\":false,\"author\":{\"username\":\"alice\"},\"body\":\"dotted human\"},{\"id\":19,\"system\":false,\"author\":{\"username\":\"a.b-c\"},\"body\":\"self plain\"}]";
print("SEL_SYS=[", sel(J_SYS, ME), "]");
print("SEL_OWN=[", sel(J_OWN, ME), "]");
print("SEL_REQ=[", sel(J_REQ, ME), "]");
print("SEL_HUMAN=[", sel(J_HUMAN, ME), "]");
print("SEL_DRAFTRC=[", sel(J_DRAFTRC, ME), "]");
print("SEL_DRAFTAP=[", sel(J_DRAFTAP, ME), "]");
print("SEL_NULL=[", sel(J_NULL, ME), "]");
print("SEL_EMPTYME_HUMAN=[", sel(J_HUMAN, ""), "]");
print("SEL_EMPTYME_REQ=[", sel(J_REQ, ""), "]");
print("SEL_EMPTYME_DRAFTRC=[", sel(J_DRAFTRC, ""), "]");
print("SEL_MALFORMED=[", sel("not json", ME), "]");
print("SEL_EMPTY=[", sel("[]", ME), "]");
print("MULTI_MAX=[", maxid(actionable_note(J_MULTI, ME)), "]");
print("MULTI_IFIX=[", to_string(index_of(body_of(actionable_note(J_MULTI, ME)), "fix now")), "]");
print("MULTI_IHUMAN=[", to_string(index_of(body_of(actionable_note(J_MULTI, ME)), "human A")), "]");
print("TAB_MAX=[", maxid(actionable_note(J_TAB, ME)), "]");
print("TAB_REALTAB=[", to_string(index_of(body_of(actionable_note(J_TAB, ME)), "\t")), "]");
print("TAB_ESCTAB=[", to_string(index_of(body_of(actionable_note(J_TAB, ME)), "\\t")), "]");
print("MEDOT_MAX=[", maxid(actionable_note(J_MEDOT, "a.b-c")), "]");
AGEOF
    } > "$AN_TMP/probe.ag"
    (cd "$AN_TMP" && agentis init) >/dev/null 2>&1
    AN_OUT="$( (cd "$AN_TMP" && agentis go probe.ag) 2>/dev/null )"
    g() { printf '%s\n' "$AN_OUT" | sed -n "s/^$1=\\[ \\(.*\\) \\]\$/\\1/p"; }

    if [ "$(g SEL_SYS)" = "EMPTY" ] && [ "$(g SEL_OWN)" = "EMPTY" ]; then
        pass "(P2B live) system note + own-bot plain note both EXCLUDED"
    else
        fail "(P2B live) exclude system/own-plain" "SEL_SYS='$(g SEL_SYS)' SEL_OWN='$(g SEL_OWN)' (both must be EMPTY)"
    fi
    if [ "$(g SEL_REQ)" = "12" ]; then
        pass "(P2B live) own-bot **Review Summary** (automated) note INCLUDED (is_req, startswith)"
    else
        fail "(P2B live) is_req include" "SEL_REQ='$(g SEL_REQ)' (must be 12)"
    fi
    if [ "$(g SEL_HUMAN)" = "13" ]; then
        pass "(P2B live) external human note INCLUDED (is_human, author.username != me)"
    else
        fail "(P2B live) is_human include" "SEL_HUMAN='$(g SEL_HUMAN)' (must be 13)"
    fi
    if [ "$(g SEL_DRAFTRC)" = "14" ]; then
        pass "(P2B live) [draft-review-decision] request_changes note INCLUDED (is_draft phrase)"
    else
        fail "(P2B live) is_draft include" "SEL_DRAFTRC='$(g SEL_DRAFTRC)' (must be 14)"
    fi
    if [ "$(g SEL_DRAFTAP)" = "EMPTY" ]; then
        pass "(P2B live) approve-draft whose reasoning mentions request_changes EXCLUDED (the safe-direction divergence from the old python)"
    else
        fail "(P2B live) safe divergence" "SEL_DRAFTAP='$(g SEL_DRAFTAP)' (must be EMPTY — the old python wrongly KEPT it)"
    fi
    if [ "$(g SEL_NULL)" = "17" ]; then
        pass "(P2B live) null-author note KEPT via author.username!=me (documented #903: unreachable on a real forge, cap-bounded even if reached)"
    else
        fail "(P2B live) null-author keep" "SEL_NULL='$(g SEL_NULL)' (must be 17 — the documented !=me behavior)"
    fi
    if [ "$(g SEL_EMPTYME_HUMAN)" = "EMPTY" ] && [ "$(g SEL_EMPTYME_REQ)" = "12" ] && [ "$(g SEL_EMPTYME_DRAFTRC)" = "14" ]; then
        pass "(P2B live) empty-me fail-safe: human suppressed, own req/draft markers still actionable"
    else
        fail "(P2B live) empty-me fail-safe" "human='$(g SEL_EMPTYME_HUMAN)'(EMPTY) req='$(g SEL_EMPTYME_REQ)'(12) draft='$(g SEL_EMPTYME_DRAFTRC)'(14)"
    fi
    if [ "$(g SEL_MALFORMED)" = "EMPTY" ] && [ "$(g SEL_EMPTY)" = "EMPTY" ]; then
        pass "(P2B live) malformed JSON + empty array both yield \"\" (no record)"
    else
        fail "(P2B live) malformed/empty" "SEL_MALFORMED='$(g SEL_MALFORMED)' SEL_EMPTY='$(g SEL_EMPTY)' (both EMPTY)"
    fi
    if [ "$(g MULTI_MAX)" = "13" ] \
       && [ -n "$(g MULTI_IFIX)" ] && [ "$(g MULTI_IFIX)" -ge 0 ] \
       && [ -n "$(g MULTI_IHUMAN)" ] && [ "$(g MULTI_IHUMAN)" -ge 0 ] \
       && [ "$(g MULTI_IFIX)" -lt "$(g MULTI_IHUMAN)" ]; then
        pass "(P2B live) max-id across kept notes = highest (13); bodies concatenated ascending-id (id 12 'fix now' before id 13 'human A')"
    else
        fail "(P2B live) max-id / ascending concat" "MAX='$(g MULTI_MAX)'(13) IFIX='$(g MULTI_IFIX)' IHUMAN='$(g MULTI_IHUMAN)' (0<=IFIX<IHUMAN)"
    fi
    if [ "$(g TAB_MAX)" = "16" ] && [ "$(g TAB_REALTAB)" = "-1" ] && [ -n "$(g TAB_ESCTAB)" ] && [ "$(g TAB_ESCTAB)" -ge 0 ]; then
        pass "(P2B live) a real tab in a body is escaped to \\t; the record keeps exactly one real tab, so repo_field splits into exactly two fields"
    else
        fail "(P2B live) escaped-body cell" "TAB_MAX='$(g TAB_MAX)'(16) TAB_REALTAB='$(g TAB_REALTAB)'(-1) TAB_ESCTAB='$(g TAB_ESCTAB)'(>=0)"
    fi
    if [ "$(g MEDOT_MAX)" = "18" ]; then
        pass "(P2B live) a me with '.'/'-' (a.b-c) injects no extra keep clause: self-authored note excluded, human kept (max=18, not 19)"
    else
        fail "(P2B live) me clause-injection safety" "MEDOT_MAX='$(g MEDOT_MAX)' (must be 18 — a.b-c used as identity, no grammar break)"
    fi
    rm -rf "$AN_TMP"
else
    echo "[SKIP] (P2B live) actionable_note probe — agentis not on PATH"
fi

# 11. Parse check: the agent commits cleanly under `agentis commit` (same as the
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
