#!/usr/bin/env bash
# test-reviewer-head-gate.sh (#1461): per-(iid, head) dedup contract for the
# four advisory code-review reviewers (style/logic/security/test).
#
# Live evidence (PR #1454, 2026-07-07): the code-review colony posted ~15
# [draft-review] comments in ~90 minutes on ONE unchanged head — each reviewer
# re-prompting + re-posting a near-identical verdict every tick, and burning a
# full prompt() session per reviewer per tick against the #1352 slot cap. The
# #1370 per-issue handled-marker class, but for MR reviews: reviewers gated on
# the MR being open, not on (iid, head SHA) having been reviewed at their tier.
#
# The fix ports qa_reviewer's verdict_head idiom (#1401 / the #1484 precedent):
# each reviewer gets a byte-identical head_fingerprint() plus a recall_latest
# gate placed BEFORE the review prompt(), keyed on `<reviewer>:reviewed_head:<iid>`
# and written at EVERY acting tier. An unchanged head returns before any LLM
# round-trip AND before any note post — killing both the [draft-review] spam and
# the redundant prompt() cost. A new push changes the diff, changes the
# fingerprint, and falls through to a fresh review.
#
# The .ag has no runtime unit harness (colony-lint's per-agent `agentis commit`
# parse is its gate) and the review judgement itself is an LLM call, so — exactly
# like tools/test-qa-reviewer.sh — the contract is asserted at the source level
# (awk/grep over the .ag) plus a fixture-driven check of the head fingerprint the
# gate rides on. For each reviewer we assert:
#
#   (a) head_fingerprint() is defined and its body is byte-identical to
#       qa_reviewer.head_fingerprint (the shared idiom the #1484 gate depends on).
#   (b) the reviewed_head recall_latest gate precedes the review prompt() in the
#       same function (this recall is also the check-prompt-gate.sh staleness
#       gate) and the `reviewed == head` branch returns before any prompt/post.
#   (c) the per-head marker is written at every acting tier (autonomous +
#       review-gated + propose + shadow + clean) — count == 5.
#   (d) the two posting-tier markers (autonomous, review-gated) sit inside an
#       `if len(result) > 0` post-success guard (a failed post retries next tick).
#
# Plus a cross-agent byte-identity check pinning head_fingerprint across all SIX
# code-review agents (the four reviewers + qa_reviewer + approval_decider), and a
# fixture run of the same hashlib pipeline the agents exec (stable on identical
# diff, changes on new push).
#
# Matches the test style of tools/test-qa-reviewer.sh (bash, [PASS]/[FAIL] lines,
# `Results: N passed, M failed`). Exit 0 all-pass, 1 any-fail. Auto-discovered
# and run by colony-lint.sh's `find "$REPO_ROOT/tools" -name "test-*.sh"` loop.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
COLONY="$REPO_ROOT/dev-apprenticeship/code-review"
QA_AG="$COLONY/agents/qa_reviewer.ag"
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

REVIEWERS="style logic security test"

# ---------------------------------------------------------------------------
# Shared head-fingerprint body extracted from qa_reviewer (the pin target).
# ---------------------------------------------------------------------------
if [ ! -f "$QA_AG" ]; then
    echo "[FAIL] qa_reviewer.ag present: missing $QA_AG"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi
QA_FP="$(awk '/^fn head_fingerprint\(/{f=1} f{print} /^}/{if(f) f=0}' "$QA_AG")"

# ---------------------------------------------------------------------------
# Per-reviewer contract assertions.
# ---------------------------------------------------------------------------
for r in $REVIEWERS; do
    AG="$COLONY/agents/${r}_reviewer.ag"
    if [ ! -f "$AG" ]; then
        fail "($r) ${r}_reviewer.ag present" "missing $AG"
        continue
    fi

    # (a) head_fingerprint() defined + byte-identical to qa_reviewer's.
    FP="$(awk '/^fn head_fingerprint\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
    if [ -n "$FP" ] && [ "$FP" = "$QA_FP" ]; then
        pass "($r) head_fingerprint() body is byte-identical to qa_reviewer's"
    else
        fail "($r) fingerprint byte-identity" "the head_fingerprint body differs from qa_reviewer — the gate would silently never match"
    fi
    # The agent execs the same portable hashlib pipeline (no sha256sum on macOS).
    if grep -q 'hashlib.sha256(sys.stdin.buffer.read()).hexdigest()\[:16\]' "$AG"; then
        pass "($r) fingerprints the diff with the portable python3 hashlib sha256[:16] pipeline"
    else
        fail "($r) fingerprint pipeline" "head_fingerprint must use the python3 hashlib sha256[:16] pipeline"
    fi

    # (b) reviewed_head recall_latest gate precedes the review prompt() in
    # tick_for_repo (this recall is also check-prompt-gate.sh's staleness gate).
    gate_line="$(grep -n "recall_latest(scoped_memo(owner, repo, \"${r}_reviewer:reviewed_head:\" + to_string(mr_iid)))" "$AG" | head -n1 | cut -d: -f1)"
    prompt_line="$(grep -n 'let review = prompt(' "$AG" | head -n1 | cut -d: -f1)"
    if [ -n "$gate_line" ] && [ -n "$prompt_line" ] && [ "$gate_line" -lt "$prompt_line" ]; then
        pass "($r) per-head memo gate (${r}_reviewer:reviewed_head:<iid>) precedes the review prompt() — no re-prompt on unchanged head"
    else
        fail "($r) dedup gate before prompt" "gate_line=$gate_line prompt_line=$prompt_line"
    fi
    # The `reviewed == head` branch returns before any LLM call or post.
    if [ -n "$gate_line" ] && sed -n "$((gate_line + 1)),$((gate_line + 3))p" "$AG" | grep -q 'return;'; then
        pass "($r) unchanged head returns before any LLM call or post"
    else
        fail "($r) early return" "the reviewed == head branch must return;"
    fi

    # (c) the per-head marker is written at every acting tier — autonomous +
    # review-gated + propose + shadow + clean == 5 (the #1370 pattern).
    marker_writes="$(grep -c "memo_write(scoped_memo(owner, repo, \"${r}_reviewer:reviewed_head:\" + to_string(mr_iid)), head)" "$AG")"
    if [ "$marker_writes" -eq 5 ]; then
        pass "($r) all five tier branches write the per-head marker (autonomous + review-gated + propose + shadow + clean)"
    else
        fail "($r) marker at every tier" "expected 5 marker writes, found $marker_writes"
    fi

    # (d) the two posting-tier markers (autonomous, review-gated) are gated on a
    # successful post (inside `if len(result) > 0`) so a failed post retries.
    post_guarded="$(awk "/if len\\(result\\) > 0/{f=1} f && /memo_write\\(scoped_memo\\(owner, repo, \"${r}_reviewer:reviewed_head:\"/{c++} /};/{f=0} END{print c+0}" "$AG")"
    if [ "$post_guarded" -ge 2 ]; then
        pass "($r) autonomous + review-gated markers are gated on a successful post (failed post retries)"
    else
        fail "($r) post-success guard" "expected >=2 marker writes under 'if len(result) > 0', found $post_guarded"
    fi

    # The gate suppresses the WHOLE prompt(), so the existing #201
    # pattern-learn prompt keeps its own independent last_pattern_learn_ts gate
    # (untouched — it learns from human comments that arrive without a head
    # change). Assert the reviewed_head gate lands AFTER that block.
    learn_gate_line="$(grep -n "recall_latest(scoped_memo(owner, repo, \"${r}_reviewer:last_pattern_learn_ts\"))" "$AG" | head -n1 | cut -d: -f1)"
    if [ -n "$learn_gate_line" ] && [ -n "$gate_line" ] && [ "$learn_gate_line" -lt "$gate_line" ]; then
        pass "($r) reviewed_head gate is inserted AFTER the #201 pattern-learn block (its cadence is untouched)"
    else
        fail "($r) gate placement" "reviewed_head gate must follow the last_pattern_learn_ts block (learn=$learn_gate_line gate=$gate_line)"
    fi
done

# ---------------------------------------------------------------------------
# Cross-agent byte-identity: head_fingerprint identical across ALL SIX agents.
# ---------------------------------------------------------------------------
# The #1484 review gate depends on approval_decider recomputing the SAME
# fingerprint qa_reviewer marks; extending the idiom to the four reviewers must
# not fork it. A single drift anywhere silently disables a gate.
all_identical=1
mismatch=""
for f in style_reviewer logic_reviewer security_reviewer test_reviewer qa_reviewer approval_decider; do
    AG="$COLONY/agents/$f.ag"
    if [ ! -f "$AG" ]; then
        all_identical=0
        mismatch="$mismatch $f(missing)"
        continue
    fi
    body="$(awk '/^fn head_fingerprint\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
    if [ -z "$body" ] || [ "$body" != "$QA_FP" ]; then
        all_identical=0
        mismatch="$mismatch $f"
    fi
done
if [ "$all_identical" -eq 1 ]; then
    pass "head_fingerprint is byte-identical across all six code-review agents (4 reviewers + qa_reviewer + approval_decider)"
else
    fail "cross-agent fingerprint identity" "head_fingerprint drifted in:$mismatch"
fi

# ---------------------------------------------------------------------------
# Fixture: the per-head fingerprint is stable on an identical diff and changes
# on a new push — the exact hashlib pipeline the agents exec (reused verbatim
# from tools/test-qa-reviewer.sh case (d); dash-safe, plain JSON fixtures).
# ---------------------------------------------------------------------------
FP_PY='import sys, hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])'
FIX_CLEAN='{"changes": [{"old_path": "a.sh", "new_path": "a.sh", "diff": "@@ -1 +1 @@\n-old\n+new"}]}'
FIX_PUSHED='{"changes": [{"old_path": "a.sh", "new_path": "a.sh", "diff": "@@ -1 +1 @@\n-old\n+newer"}]}'
fp1="$(printf '%s' "$FIX_CLEAN" | python3 -c "$FP_PY")"
fp2="$(printf '%s' "$FIX_CLEAN" | python3 -c "$FP_PY")"
fp3="$(printf '%s' "$FIX_PUSHED" | python3 -c "$FP_PY")"
if [ -n "$fp1" ] && [ "$fp1" = "$fp2" ] && [ "$fp1" != "$fp3" ]; then
    pass "head fingerprint fixture: stable on identical diff (no re-review), changes on new push (fresh review)"
else
    fail "fingerprint fixture" "fp1=$fp1 fp2=$fp2 fp3=$fp3"
fi

# ---------------------------------------------------------------------------
# Parse check (same as the per-agent syntax pass in colony-lint.sh). Skipped
# (not failed) when agentis is not installed.
# ---------------------------------------------------------------------------
if command -v agentis >/dev/null 2>&1; then
    LINT_TMP="$(mktemp -d)"
    (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
    for r in $REVIEWERS; do
        AG="$COLONY/agents/${r}_reviewer.ag"
        if (cd "$LINT_TMP" && agentis commit "$AG") >/dev/null 2>&1; then
            pass "($r) ${r}_reviewer.ag parses (agentis commit)"
        else
            fail "($r) ${r}_reviewer.ag parses (agentis commit)" "syntax error in ${r}_reviewer.ag"
        fi
    done
    rm -rf "$LINT_TMP"
else
    echo "[SKIP] agentis not on PATH — skipping .ag parse check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
