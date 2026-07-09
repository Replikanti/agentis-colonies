#!/usr/bin/env bash
# test-code-writer-redraft-gate.sh (#1516): source-assertion test of the
# recovery-over-redraft gate in dev-apprenticeship/implementation/agents/
# code_writer.ag. Agentis is absent on CI runners, so this asserts the SOURCE
# structure of the gate (same style as test-idle-prompt-gates.sh /
# test-code-writer-completion-markers.sh) rather than executing the runtime.
#
# The incident (#1516): a stale in-flight edit-loop phase memo survived a host
# suspend + agent restart and re-triggered a full draft->edit->finalize->
# force-push cycle for an issue that ALREADY had an open PR, silently destroying
# the operator's commits. The fix makes an existing MR terminal:
#   - needs_draft is derived from `!mr_exists` ONLY (the should_draft_code
#     updated_at re-trigger no longer authorises rebuilding over an existing PR);
#   - when an MR exists AND a lingering `code_edit_loop:phase:<iid>` memo is set,
#     the gate resets it (ag_edit_reset) + clears the job dir so no later tick
#     resumes a stale --finalize;
#   - the #1350 MR-less rescue is preserved (no MR ⇒ needs_draft true), so an
#     abandoned job (phase set, no MR, dead process) still reaches a fresh draft
#     via the existing ag_edit_step ERROR->ag_edit_reset self-healing path.
#
# Asserts:
#   E. recovery-over-redraft — needs_draft is set from `!mr_exists`, and the
#      should_draft_code(...) OR-re-trigger is GONE from the gate.
#   F. stale-phase reset — the mr_exists branch reads code_edit_loop:phase: and
#      calls ag_edit_reset(...) + clear_job_dir(...) on a non-empty phase memo.
#   G. MR-less rescue preserved — has_mr_for_branch still feeds the gate, so
#      `!mr_exists` yields needs_draft true (a fresh draft for an MR-less issue).
#
# Exit 0 all-pass, 1 any-fail.
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
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Extract the gate block: from the `let mr_exists =` line through the
# `let needs_draft =` line that follows it. python keeps this robust to
# whitespace/line drift.
GATE="$(AG="$AG" python3 - <<'PY'
import os, re
src = open(os.environ["AG"], encoding="utf-8").read()
m = re.search(r"let mr_exists = .*?let needs_draft = [^\n]*\n", src, re.S)
print(m.group(0) if m else "")
PY
)"

# ---------------------------------------------------------------------------
# E: recovery-over-redraft.
# ---------------------------------------------------------------------------
if printf '%s' "$GATE" | grep -Eq 'let[[:space:]]+mr_exists[[:space:]]*=[[:space:]]*has_mr_for_branch\(owner, repo, first_iid_str\)'; then
    pass "E: mr_exists is derived from has_mr_for_branch(owner, repo, first_iid_str)"
else
    fail "E: mr_exists = has_mr_for_branch(...)" "gate=[$GATE]"
fi

if printf '%s' "$GATE" | grep -Eq 'let[[:space:]]+needs_draft[[:space:]]*=[[:space:]]*!mr_exists;'; then
    pass "E: needs_draft = !mr_exists (an existing MR is terminal — never re-drafted)"
else
    fail "E: needs_draft = !mr_exists" "gate=[$GATE]"
fi

# The should_draft_code updated_at re-trigger must be GONE from the gate block
# (its return to `true` on an updated_at bump is exactly the incident trigger).
if printf '%s' "$GATE" | grep -q 'should_draft_code('; then
    fail "E: should_draft_code re-trigger must be removed from the gate" "gate=[$GATE]"
else
    pass "E: should_draft_code updated_at re-trigger removed from the gate (no rebuild over an existing PR)"
fi

# ---------------------------------------------------------------------------
# F: stale-phase reset (mr_exists branch).
# ---------------------------------------------------------------------------
# Isolate the `if mr_exists { ... }` body.
MR_BRANCH="$(AG="$AG" python3 - <<'PY'
import os, re
src = open(os.environ["AG"], encoding="utf-8").read()
i = src.find("let mr_exists = has_mr_for_branch")
seg = src[i:i+2500] if i >= 0 else ""
m = re.search(r"if mr_exists \{(.*?)\n        \};", seg, re.S)
print(m.group(1) if m else "")
PY
)"

if printf '%s' "$MR_BRANCH" | grep -q 'code_edit_loop:phase:'; then
    pass "F: the mr_exists branch reads code_edit_loop:phase:<iid>"
else
    fail "F: mr_exists branch reads the phase memo" "branch=[$MR_BRANCH]"
fi

if printf '%s' "$MR_BRANCH" | grep -Eq 'if len\(stale_phase\) > 0' \
   && printf '%s' "$MR_BRANCH" | grep -q 'ag_edit_reset(owner, repo, first_iid_str)' \
   && printf '%s' "$MR_BRANCH" | grep -q 'clear_job_dir(first_iid_str)'; then
    pass "F: a non-empty phase ⇒ ag_edit_reset(...) + clear_job_dir(...) (no stale finalize resumes)"
else
    fail "F: phase-set reset calls ag_edit_reset + clear_job_dir" "branch=[$MR_BRANCH]"
fi

# ---------------------------------------------------------------------------
# G: MR-less rescue preserved (no deadlock on the abandoned-job case).
# ---------------------------------------------------------------------------
# needs_draft = !mr_exists means `!has_mr_for_branch(...)` ⇒ true, i.e. an issue
# with NO MR (a dead/abandoned job) still gets a fresh draft. Assert the gate
# still consults has_mr_for_branch (G is the logical complement of E) and that
# the reset is guarded by `if mr_exists` so the no-MR case is left to
# ag_edit_step's own self-healing ERROR path (never reset here → never wedged).
if printf '%s' "$GATE" | grep -q 'has_mr_for_branch(owner, repo, first_iid_str)'; then
    pass "G: gate consults has_mr_for_branch — !mr_exists ⇒ needs_draft true (MR-less rescue preserved)"
else
    fail "G: MR-less rescue preserved via has_mr_for_branch" "gate=[$GATE]"
fi

# The phase reset lives INSIDE `if mr_exists { ... }`, so the no-MR abandoned-job
# case is NOT reset here — it flows through to a fresh draft (E) and, if a
# detached process is still marked in-flight, ag_edit_step self-heals it.
if printf '%s' "$MR_BRANCH" | grep -q 'ag_edit_reset'; then
    pass "G: the reset is gated by mr_exists (the no-MR abandoned-job case is never reset here — reaches a fresh draft)"
else
    fail "G: reset must be inside the mr_exists branch" "branch=[$MR_BRANCH]"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
