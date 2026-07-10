#!/usr/bin/env bash
# test-code-writer-ownership-hold.sh (#1560): structural wiring assertions for
# the ownership-hold gate in implementation/code_writer.ag — the fix for the
# "operator commits, no MR" branch re-drafting + refusing every tick and
# burning a full prompt()+edit-job+fetch cycle on every retry.
#
# The .ag has no runtime unit harness (colony-lint's per-agent `agentis commit`
# parse is its gate), so — like tools/test-code-writer-rebase-sweep.sh — we
# assert the wiring at the grep level plus a parse check. The invariants that
# MUST hold:
#
#   1. ag_attempt_poll maps STATUS=ownership_refused to a DISTINCT verdict
#      (OWNERSHIP_REFUSED), never folded into the generic ERROR string.
#   2. ag_edit_step's OWNERSHIP_REFUSED branch calls ownership_probe + parses the
#      head, and writes the ownership_hold memo ONLY when that head is non-empty.
#   3. ownership_held branches on the probe's PROBE_STATUS: an UNREACHABLE remote
#      KEEPS the hold (transient, fail-safe), a REACHABLE-but-absent branch
#      (empty head) RELEASES it (deletion), and a moved head RELEASES it. The
#      two empty-head cases (unreachable vs deleted) must NOT collapse together —
#      that collapse was the never-releasing-hold bug #1560's review caught.
#   4. The needs-draft gate calls ownership_held(...) BEFORE the `let draft =
#      prompt(` line (line-order assertion, mirrors rebase-sweep's
#      reb_line < rec_line technique).
#   5. Every new exec-sh command built in the new functions wraps its dynamic
#      values in shell_escape(...).
#   6. mr_exists / has_mr_for_branch precedes ownership_held in source order
#      (the pre-existing MR-opened bypass is unconditional and checked first).
#   7. A direct shell invocation: `--probe-remote-head` combined with
#      `--one-attempt` exits 2 (the new mutual-exclusivity guard).
#
# Exit 0 all-pass, 1 any-fail.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
AG="$REPO_ROOT/dev-apprenticeship/implementation/agents/code_writer.ag"
ORCH="$REPO_ROOT/tools/code-edit-in-checkout.sh"
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

ATTEMPT_POLL="$(awk '/^fn ag_attempt_poll\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
EDIT_STEP="$(awk '/^fn ag_edit_step\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
OWNERSHIP_HELD="$(awk '/^fn ownership_held\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
PROBE_FN="$(awk '/^fn ownership_probe\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"

# 1. ag_attempt_poll: STATUS=ownership_refused -> a DISTINCT OWNERSHIP_REFUSED
# verdict, not folded into ERROR.
if printf '%s' "$ATTEMPT_POLL" | grep -q 'status == "ownership_refused"' \
   && printf '%s' "$ATTEMPT_POLL" | grep -q 'return "OWNERSHIP_REFUSED";'; then
    pass "ag_attempt_poll maps STATUS=ownership_refused to a distinct OWNERSHIP_REFUSED verdict"
else
    fail "ownership_refused mapping" "ag_attempt_poll must map status == \"ownership_refused\" to \"OWNERSHIP_REFUSED\""
fi
# It must be checked as its OWN branch, not merged into the generic fallback.
if printf '%s' "$ATTEMPT_POLL" | grep -B1 'return "OWNERSHIP_REFUSED";' | grep -q 'status == "ownership_refused"'; then
    pass "OWNERSHIP_REFUSED is its own branch (not the generic ERROR fallback)"
else
    fail "distinct branch" "the ownership_refused check must directly guard the OWNERSHIP_REFUSED return"
fi

# 2. ag_edit_step: the OWNERSHIP_REFUSED branch exists, probes, and writes the
# hold memo ONLY inside the non-empty-probe guard.
if printf '%s' "$EDIT_STEP" | grep -q 'if mv == "OWNERSHIP_REFUSED"'; then
    pass "ag_edit_step has an OWNERSHIP_REFUSED branch"
else
    fail "OWNERSHIP_REFUSED branch" "ag_edit_step must branch on mv == \"OWNERSHIP_REFUSED\""
fi
# It must appear BEFORE the existing ERROR branch (mirrors the plan's ordering).
own_line="$(grep -n 'if mv == "OWNERSHIP_REFUSED"' "$AG" | head -n1 | cut -d: -f1)"
err_line="$(grep -n 'if mv == "ERROR"' "$AG" | head -n1 | cut -d: -f1)"
if [ -n "$own_line" ] && [ -n "$err_line" ] && [ "$own_line" -lt "$err_line" ]; then
    pass "the OWNERSHIP_REFUSED branch runs BEFORE the plain ERROR branch in ag_edit_step"
else
    fail "branch order" "own_line=$own_line err_line=$err_line"
fi
OWN_BLOCK="$(printf '%s' "$EDIT_STEP" | awk '/if mv == "OWNERSHIP_REFUSED"/{f=1} f{print} /^    };$/{if(f){exit}}')"
if printf '%s' "$OWN_BLOCK" | grep -q 'ownership_probe(owner, repo, branch)' \
   && printf '%s' "$OWN_BLOCK" | grep -q 'pr_check_token(ownership_probe(owner, repo, branch), "REMOTE_HEAD")'; then
    pass "the OWNERSHIP_REFUSED branch probes the remote head via ownership_probe + pr_check_token(REMOTE_HEAD)"
else
    fail "probe call" "the OWNERSHIP_REFUSED branch must parse the head from ownership_probe via pr_check_token"
fi
if printf '%s' "$OWN_BLOCK" | grep -q 'if len(probe_head) > 0' \
   && printf '%s' "$OWN_BLOCK" | grep -q 'code_edit_loop:ownership_hold:'; then
    pass "the ownership_hold memo is written only inside a non-empty-head guard"
else
    fail "guarded memo write" "the OWNERSHIP_REFUSED branch must guard the ownership_hold memo_write on len(probe_head) > 0"
fi
# The memo_write call itself must sit inside that guard (not unconditional).
GUARD_BLOCK="$(printf '%s' "$OWN_BLOCK" | awk '/if len\(probe_head\) > 0/{f=1} f{print} /};/{if(f){exit}}')"
if printf '%s' "$GUARD_BLOCK" | grep -q 'memo_write(scoped_memo(owner, repo, "code_edit_loop:ownership_hold:" + iid), probe_head)'; then
    pass "memo_write(ownership_hold, probe_head) sits inside the non-empty-head guard"
else
    fail "memo_write placement" "memo_write for ownership_hold must be inside the len(probe_head) > 0 guard"
fi
# Cleanup + return value match the existing ERROR branch (ag_edit_reset + clear_job_dir + return "ERROR").
if printf '%s' "$OWN_BLOCK" | grep -q 'ag_edit_reset(owner, repo, iid);' \
   && printf '%s' "$OWN_BLOCK" | grep -q 'clear_job_dir(iid);' \
   && printf '%s' "$OWN_BLOCK" | grep -q 'return "ERROR";'; then
    pass "the OWNERSHIP_REFUSED branch cleans up + returns \"ERROR\" identically to the plain ERROR branch"
else
    fail "cleanup+return parity" "the OWNERSHIP_REFUSED branch must ag_edit_reset + clear_job_dir + return \"ERROR\""
fi

# 3. ownership_held: branches on PROBE_STATUS to tell an UNREACHABLE remote
# (keep the hold — transient) apart from a REACHABLE-but-deleted branch (release
# — the never-releasing-hold bug the review caught). A moved head also releases.
if printf '%s' "$OWNERSHIP_HELD" | grep -q 'pr_check_token(raw, "PROBE_STATUS")'; then
    pass "ownership_held reads PROBE_STATUS (tells unreachable from deleted)"
else
    fail "PROBE_STATUS read" "ownership_held must parse PROBE_STATUS, not just len(probe) == 0"
fi
# The unreachable branch KEEPS the hold: return true, and NO memo clear.
UNREACH_BLOCK="$(printf '%s' "$OWNERSHIP_HELD" | awk '/if status != "ok"/{f=1} f{print} /};/{if(f){exit}}')"
if printf '%s' "$UNREACH_BLOCK" | grep -q 'return true;' \
   && ! printf '%s' "$UNREACH_BLOCK" | grep -q 'memo_write'; then
    pass "unreachable (status != \"ok\") KEEPS the hold — return true, no memo clear"
else
    fail "unreachable keeps hold" "the status != \"ok\" branch must return true without clearing the memo"
fi
# The reachable-but-absent branch RELEASES the hold (deletion): clears the memo + return false.
DELETED_BLOCK="$(printf '%s' "$OWNERSHIP_HELD" | awk '/if len\(probe_head\) == 0/{f=1} f{print} /};/{if(f){exit}}')"
if printf '%s' "$DELETED_BLOCK" | grep -q 'code_edit_loop:ownership_hold:.*"")' \
   && printf '%s' "$DELETED_BLOCK" | grep -q 'return false;'; then
    pass "reachable-but-absent (len(probe_head) == 0) RELEASES the hold — this is the deleted-branch fix"
else
    fail "deleted releases" "len(probe_head) == 0 (reachable + gone) must clear the memo and return false"
fi
# The moved-head case compares for EQUALITY.
if printf '%s' "$OWNERSHIP_HELD" | grep -q 'if probe_head == recorded'; then
    pass "ownership_held compares probe_head == recorded for EQUALITY"
else
    fail "equality compare" "ownership_held must compare probe_head == recorded"
fi
# Ordering: PROBE_STATUS check -> deleted-release -> equality-keep -> moved-release.
status_line="$(printf '%s' "$OWNERSHIP_HELD" | grep -n 'if status != "ok"' | head -n1 | cut -d: -f1)"
deleted_line="$(printf '%s' "$OWNERSHIP_HELD" | grep -n 'if len(probe_head) == 0' | head -n1 | cut -d: -f1)"
equal_line="$(printf '%s' "$OWNERSHIP_HELD" | grep -n 'if probe_head == recorded' | head -n1 | cut -d: -f1)"
if [ -n "$status_line" ] && [ -n "$deleted_line" ] && [ -n "$equal_line" ] \
   && [ "$status_line" -lt "$deleted_line" ] && [ "$deleted_line" -lt "$equal_line" ]; then
    pass "ownership_held ordering: status-check < deleted-release < equality-keep"
else
    fail "held ordering" "status_line=$status_line deleted_line=$deleted_line equal_line=$equal_line"
fi

# 4. Needs-draft gate: ownership_held(...) is called BEFORE `let draft = prompt(`.
own_gate_line="$(grep -n 'ownership_held(owner, repo, first_iid_str)' "$AG" | head -n1 | cut -d: -f1)"
draft_line="$(grep -n 'let draft = prompt(' "$AG" | head -n1 | cut -d: -f1)"
if [ -n "$own_gate_line" ] && [ -n "$draft_line" ] && [ "$own_gate_line" -lt "$draft_line" ]; then
    pass "needs-draft gate calls ownership_held(...) BEFORE the draft prompt() call"
else
    fail "gate before prompt" "own_gate_line=$own_gate_line draft_line=$draft_line"
fi
# It must be the FIRST statement inside `if needs_draft {` — before input_unchanged.
needs_draft_line="$(grep -n 'if needs_draft {' "$AG" | head -n1 | cut -d: -f1)"
input_unchanged_line="$(grep -n 'if input_unchanged(owner, repo, first_iid_str, first_upd)' "$AG" | head -n1 | cut -d: -f1)"
if [ -n "$needs_draft_line" ] && [ -n "$own_gate_line" ] && [ -n "$input_unchanged_line" ] \
   && [ "$needs_draft_line" -lt "$own_gate_line" ] && [ "$own_gate_line" -lt "$input_unchanged_line" ]; then
    pass "ownership_held runs as the FIRST check inside needs_draft, before input_unchanged"
else
    fail "first-statement ordering" "needs_draft_line=$needs_draft_line own_gate_line=$own_gate_line input_unchanged_line=$input_unchanged_line"
fi
# It returns without prompting when held.
GATE_BLOCK="$(sed -n "${own_gate_line},$((own_gate_line + 4))p" "$AG")"
if printf '%s' "$GATE_BLOCK" | grep -q 'return;'; then
    pass "the ownership-held gate returns for the tick (skips the draft)"
else
    fail "held-gate return" "the ownership_held(...) check must return; when held"
fi

# 5. exec-sh safety: every dynamic value in the two new functions is
# shell_escape'd, and the safe-exec-concat pragma is present.
if printf '%s' "$PROBE_FN" | grep -q 'shell_escape(owner)' \
   && printf '%s' "$PROBE_FN" | grep -q 'shell_escape(repo)' \
   && printf '%s' "$PROBE_FN" | grep -q 'shell_escape(branch)'; then
    pass "ownership_probe shell_escapes owner/repo/branch"
else
    fail "probe exec-sh safety" "ownership_probe must shell_escape owner/repo/branch"
fi
if grep -B1 'code-edit-in-checkout.sh --owner " + shell_escape(owner) + " --repo " + shell_escape(repo) + " --issue x --branch " + shell_escape(branch)' "$AG" | grep -q 'colony-lint: safe-exec-concat'; then
    pass "the probe exec-sh command line carries the safe-exec-concat lint pragma"
else
    fail "safe-exec-concat pragma" "the probe exec-sh command line needs the lint pragma"
fi
if printf '%s' "$PROBE_FN" | grep -q -- '--probe-remote-head'; then
    pass "ownership_probe invokes code-edit-in-checkout.sh --probe-remote-head"
else
    fail "probe flag" "ownership_probe must pass --probe-remote-head"
fi

# 6. mr_exists / has_mr_for_branch precedes ownership_held in source order (the
# pre-existing MR-opened bypass is unconditional, checked first).
mr_exists_line="$(grep -n 'let mr_exists = has_mr_for_branch(owner, repo, first_iid_str);' "$AG" | head -n1 | cut -d: -f1)"
if [ -n "$mr_exists_line" ] && [ -n "$own_gate_line" ] && [ "$mr_exists_line" -lt "$own_gate_line" ]; then
    pass "mr_exists (has_mr_for_branch) is computed BEFORE ownership_held is consulted"
else
    fail "mr_exists ordering" "mr_exists_line=$mr_exists_line own_gate_line=$own_gate_line"
fi

# 7. --probe-remote-head combined with another mode flag exits 2 (usage error).
if [ -f "$ORCH" ]; then
    OUT="$(bash "$ORCH" --owner o --repo r --issue 1 --branch b --title t --task t --probe-remote-head --one-attempt 2>&1)"
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "--probe-remote-head combined with --one-attempt exits 2 (usage error)"
    else
        fail "--probe-remote-head mutual exclusivity" "rc=$RC out=$OUT"
    fi
else
    fail "orchestrator present" "missing $ORCH"
fi

# Parse check: the agent commits cleanly under `agentis commit`.
if command -v agentis >/dev/null 2>&1; then
    LINT_TMP="$(mktemp -d)"
    (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
    if (cd "$LINT_TMP" && agentis commit "$AG") >/dev/null 2>&1; then
        pass "code_writer.ag parses (agentis commit) with the ownership-hold gate"
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
