#!/usr/bin/env bash
# test-code-writer-decompose-ag.sh (#1422 M2): grep-level + agentis-commit-parse
# structural assertions for implementation/code_writer.ag's AG-driven decompose
# loop (ag_decompose_step over the M1 --decompose-only primitive).
#
# The decompose FSM cannot be exercised end-to-end without a live federation
# (it drives detached flat-cyborg sessions across ticks), so — like
# test-code-writer-plan-post.sh — this pins the load-bearing INVARIANTS at the
# source level:
#   (a) the agent parses (agentis commit);
#   (b) recursion base case — subtask_idx advances ONLY under the `i < n` guard,
#       and `i == n` is the ONLY transition into decomp="finalize";
#   (c) one-PR invariant — exactly ONE --finalize drive is reachable from
#       ag_decompose_step (a single is_finalize=true launch in the finalize state);
#   (d) multi-subtask accumulation — force_reuse is `i > 1` (subtask >= 2 uses
#       --reuse to accumulate on subtask 1's fresh branch);
#   (e) #1537 M3: the in-shell --decompose fallback is RETIRED — no decompose_flag
#       and no bare " --decompose" concat remain in the dispatch;
#   (f) ag_decompose_reset clears all SIX memo keys + the subtasks file;
#   (g) clear_job_dir fires after STATUS=decomposed and each subtask boundary;
#   (h) #1537 M3: an epic ALWAYS drives the AG decompose loop —
#       `let ag_decompose_on = is_epic;` (the AG_DECOMPOSE_LOOP opt-out is gone).
#
# Matches the test style of tools/test-code-writer-plan-post.sh (bash,
# [PASS]/[FAIL] lines, `Results: N passed, M failed`). Exit 0 all-pass, 1
# any-fail. Auto-discovered by colony-lint.sh's `find tools -name test-*.sh`
# loop. Related: #1422, #1354, #1353.

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

# --- Isolate ag_decompose_step's body so the invariant greps below cannot be
#     satisfied by an unrelated function (e.g. a stray --finalize in ag_edit_step).
DECOMP_BODY="$(awk '/^fn ag_decompose_step\(/{c=1} c{print} c&&/^}/{exit}' "$AG")"

# 1. The decompose entry points exist: ag_decompose_step + the two M1-consuming
#    launch helpers.
if grep -F -q -- 'fn ag_decompose_step(' "$AG" \
  && grep -F -q -- 'fn ag_decompose_launch(' "$AG" \
  && grep -F -q -- 'fn ag_decompose_reset(' "$AG"; then
  pass "ag_decompose_step + ag_decompose_launch + ag_decompose_reset defined"
else
  fail "decompose functions defined" "expected fn ag_decompose_step/_launch/_reset in $AG"
fi

# 2 (b). Recursion base case: subtask_idx advances ONLY under an `i < n` guard,
#        and `i == n` is the SOLE transition into decomp="finalize".
#        - exactly one write of subtask_idx to (i + 1), and it sits under `if i < n`;
#        - exactly one write of decomp to "finalize" from the editing advance.
idx_adv="$(printf '%s\n' "$DECOMP_BODY" | grep -c -F -- 'code_edit_loop:subtask_idx:" + iid), to_string(i + 1)')"
guard_lt="$(printf '%s\n' "$DECOMP_BODY" | grep -c -F -- 'if i < n {')"
if [ "$idx_adv" = "1" ] && [ "$guard_lt" = "1" ]; then
  pass "base case: subtask_idx advances (i+1) exactly once, under the 'if i < n' guard"
else
  fail "base case i<n advance" "idx_adv=$idx_adv guard_lt=$guard_lt (both must be 1)"
fi

# The advance must come BEFORE the finalize transition (the else-arm of i<n),
# i.e. the subtask_idx=i+1 write precedes the decomp="finalize" write in the body.
adv_line="$(printf '%s\n' "$DECOMP_BODY" | grep -n -F -- 'code_edit_loop:subtask_idx:" + iid), to_string(i + 1)' | head -1 | cut -d: -f1)"
fin_line="$(printf '%s\n' "$DECOMP_BODY" | grep -n -F -- 'code_edit_loop:decomp:" + iid), "finalize"' | head -1 | cut -d: -f1)"
if [ -n "$adv_line" ] && [ -n "$fin_line" ] && [ "$adv_line" -lt "$fin_line" ]; then
  pass "base case: the i<n advance precedes the i==n finalize transition"
else
  fail "advance-before-finalize ordering" "adv_line=$adv_line fin_line=$fin_line"
fi

# 3 (c). One-PR invariant: exactly ONE --finalize drive is reachable from
#        ag_decompose_step — a single is_finalize=true ag_attempt_launch call in
#        the finalize state (subtask edits pass is_finalize=false).
fin_launch="$(printf '%s\n' "$DECOMP_BODY" | grep -c -F -- 'ag_attempt_launch(owner, repo, iid, branch, title, task, description, true, false)')"
edit_launch="$(printf '%s\n' "$DECOMP_BODY" | grep -c -F -- 'ag_attempt_launch(owner, repo, iid, branch, title, subtask_text, description, false, force_reuse)')"
if [ "$fin_launch" = "1" ] && [ "$edit_launch" = "1" ]; then
  pass "one-PR invariant: exactly one is_finalize=true launch (finalize) + one per-subtask launch"
else
  fail "one-PR invariant launch count" "finalize_launch=$fin_launch edit_launch=$edit_launch (both must be 1)"
fi

# Also: only ONE transition memo into decomp="finalize" exists in the whole body.
fin_transitions="$(printf '%s\n' "$DECOMP_BODY" | grep -c -F -- 'code_edit_loop:decomp:" + iid), "finalize"')"
if [ "$fin_transitions" = "1" ]; then
  pass "one-PR invariant: exactly one decomp=\"finalize\" transition"
else
  fail "single finalize transition" "count=$fin_transitions (must be 1)"
fi

# 4 (d). Multi-subtask accumulation: force_reuse is `i > 1` so subtask >= 2 rides
#        --reuse onto subtask 1's fresh branch.
if printf '%s\n' "$DECOMP_BODY" | grep -F -q -- 'let force_reuse = i > 1;'; then
  pass "accumulation: force_reuse = i > 1 (subtask >= 2 uses --reuse)"
else
  fail "force_reuse = i > 1" "expected 'let force_reuse = i > 1;' in ag_decompose_step"
fi

# 5 (e). #1537 M3: the in-shell --decompose fallback is RETIRED. The dispatch no
#        longer builds a decompose_flag or concats a bare " --decompose" — epics
#        route unconditionally through ag_decompose_step over --decompose-only.
if ! grep -F -q -- 'decompose_flag' "$AG" \
  && ! grep -F -q -- ' --decompose"' "$AG"; then
  pass "retired: no decompose_flag / bare --decompose concat remains in the dispatch"
else
  fail "in-shell --decompose fallback retired" "found a lingering decompose_flag or bare ' --decompose' concat (should be removed in #1537 M3)"
fi

# 6 (f). ag_decompose_reset clears ALL SIX memo keys + the subtasks file.
RESET_BODY="$(awk '/^fn ag_decompose_reset\(/{c=1} c{print} c&&/^}/{exit}' "$AG")"
missing_key=""
for key in decomp subtask_count subtask_idx phase attempts; do
  printf '%s\n' "$RESET_BODY" | grep -F -q -- "code_edit_loop:$key:\" + iid" || missing_key="$missing_key $key"
done
# The 6th cleared artifact is the stable subtasks file (rm -f), + the cont file.
if [ -z "$missing_key" ] \
  && printf '%s\n' "$RESET_BODY" | grep -F -q -- 'code-edit-subtasks/issue-' \
  && printf '%s\n' "$RESET_BODY" | grep -F -q -- 'code-edit-cont/issue-'; then
  pass "ag_decompose_reset clears decomp/subtask_count/subtask_idx/phase/attempts + subtasks & cont files"
else
  fail "ag_decompose_reset key coverage" "missing_memo_keys=[$missing_key] (needs all 5 memo keys + subtasks + cont file rm)"
fi

# 7 (g). clear_job_dir fires after STATUS=decomposed (before the first subtask
#        launch) AND on each subtask boundary (the editing-advance path).
#        At least two clear_job_dir(iid) calls live in ag_decompose_step, one in
#        the "decomposed" block and one in the editing-advance block.
cjd_count="$(printf '%s\n' "$DECOMP_BODY" | grep -c -F -- 'clear_job_dir(iid);')"
if [ -n "$cjd_count" ] && [ "$cjd_count" -ge 2 ]; then
  pass "clear_job_dir fires after decomposed + subtask boundaries ($cjd_count call sites)"
else
  fail "clear_job_dir call sites" "count=$cjd_count (need >= 2: post-decomposed + subtask advance)"
fi

# 8 (h). #1537 M3: an epic ALWAYS drives the AG decompose loop — ag_decompose_on
#        is now the unconditional `is_epic` (the AG_DECOMPOSE_LOOP getenv opt-out
#        is retired), so no getenv("AG_DECOMPOSE_LOOP") read remains.
if grep -F -q -- 'let ag_decompose_on = is_epic;' "$AG" \
  && ! grep -F -q -- 'getenv("AG_DECOMPOSE_LOOP")' "$AG"; then
  pass "ag_decompose_on = is_epic (unconditional epic -> AG decompose; opt-out retired)"
else
  fail "ag_decompose_on unconditional" "expected 'let ag_decompose_on = is_epic;' and NO getenv(\"AG_DECOMPOSE_LOOP\") read"
fi

# 9. Dispatch routes ag_decompose_on to ag_decompose_step (verdict contract).
if grep -F -q -- 'ag_decompose_step(owner, repo, issue_iid, branch_name, draft.title, task_text, draft.summary)' "$AG"; then
  pass "dispatch routes the decompose path to ag_decompose_step"
else
  fail "dispatch -> ag_decompose_step" "expected the ag_decompose_step call in the verdict resolution"
fi

# 10. The stable subtasks path lives OUTSIDE the job dir (code-edit-subtasks/),
#     so clear_job_dir cannot reap the M1 --subtasks-out records mid-loop.
if grep -F -q -- '.agentis/code-edit-subtasks/issue-' "$AG" \
  && grep -F -q -- ' --decompose-only --subtasks-out ' "$AG"; then
  pass "subtasks list is written OUTSIDE the job dir via --decompose-only --subtasks-out"
else
  fail "subtasks-out path outside job dir" "expected code-edit-subtasks/ path + --decompose-only --subtasks-out launch"
fi

# 11 (#1422 review finding 1 — decompose-collapse). "reuse the branch" and
#     "continuation framing" MUST be decoupled in ag_attempt_launch: a decompose
#     subtask >= 2 must --reuse (accumulate on the one branch) but get a FRESH
#     tightly-scoped per-subtask prompt on its first attempt, NOT the whole-issue
#     continuation preamble ("finish anything incomplete … complete and correct")
#     which is a within-attempt RETRY device. Feeding that preamble to a fresh
#     subtask can collapse decomposition back to monolithic.
LAUNCH_BODY="$(awk '/^fn ag_attempt_launch\(/{c=1} c{print} c&&/^}/{exit}' "$AG")"
# (a) want_continuation is gated on attempts>0 ONLY (never force_reuse).
if printf '%s\n' "$LAUNCH_BODY" | grep -F -q -- 'let want_continuation = if is_finalize { false; } else { attempts > 0; };'; then
  pass "finding 1: want_continuation = attempts>0 only (continuation framing is a retry device, not force_reuse)"
else
  fail "finding 1: want_continuation decoupled from force_reuse" "expected 'let want_continuation = if is_finalize { false; } else { attempts > 0; };'"
fi
# (b) want_reuse still accumulates on force_reuse OR attempts>0.
if printf '%s\n' "$LAUNCH_BODY" | grep -F -q -- 'let want_reuse = if is_finalize { false; } else { if force_reuse { true; } else { attempts > 0; }; };'; then
  pass "finding 1: want_reuse = force_reuse OR attempts>0 (subtask >= 2 still --reuse, accumulation preserved)"
else
  fail "finding 1: want_reuse preserves accumulation" "expected want_reuse = force_reuse OR attempts>0"
fi
# (c) the reuse-WITHOUT-continuation flag branch (fresh scoped prompt) is reachable.
if printf '%s\n' "$LAUNCH_BODY" | grep -F -q -- '" --one-attempt --reuse";'; then
  pass "finding 1: '--one-attempt --reuse' (reuse without --continuation) branch reachable — fresh scoped subtask prompt"
else
  fail "finding 1: reuse-without-continuation flag branch" "expected a bare '\" --one-attempt --reuse\";' flag branch"
fi
# (d) the whole-issue continuation preamble is guarded ONLY by want_continuation:
#     the preamble write (the 'if want_continuation {' block) must be the sole
#     gate, so a fresh subtask (want_continuation=false) never writes it.
cont_guard_line="$(printf '%s\n' "$LAUNCH_BODY" | grep -n -F -- 'if want_continuation {' | head -1 | cut -d: -f1)"
preamble_line="$(printf '%s\n' "$LAUNCH_BODY" | grep -n -F -- 'Continue implementing this issue in the CURRENT working checkout' | head -1 | cut -d: -f1)"
if [ -n "$cont_guard_line" ] && [ -n "$preamble_line" ] && [ "$cont_guard_line" -lt "$preamble_line" ]; then
  pass "finding 1: whole-issue continuation preamble is written ONLY inside the 'if want_continuation' guard"
else
  fail "finding 1: continuation preamble guarded by want_continuation" "guard_line=$cont_guard_line preamble_line=$preamble_line"
fi

# 12 (#1422 review finding 2 — portability). read_subtask must NOT use
#     gawk-specific `RS="\0"` (BSD/busybox awk return the wrong record); it must
#     split on NUL with the portable bash `read -r -d ""` mechanism the in-shell
#     reference uses.
READSUB_BODY="$(awk '/^fn read_subtask\(/{c=1} c{print} c&&/^}/{exit}' "$AG")"
if printf '%s\n' "$READSUB_BODY" | grep -F -q -- 'read -r -d' \
  && ! printf '%s\n' "$READSUB_BODY" | grep -F -q -- 'RS=' \
  && ! printf '%s\n' "$READSUB_BODY" | grep -F -q -- 'awk'; then
  pass "finding 2: read_subtask splits NUL via portable 'read -r -d' (no gawk RS=\"\\0\")"
else
  fail "finding 2: read_subtask portability" "expected 'read -r -d' and NO awk/RS= in read_subtask body"
fi

# 12b (#1422 review finding 2 — behavioural). The exact extraction mechanism
#     read_subtask emits must return records BYTE-IDENTICAL to the orchestrator's
#     own in-shell `read -r -d ''` loop, for: a 3-record list, a multi-line
#     monolithic-fallback single record, and UTF-8 content.
RS_WORK="$(mktemp -d)"
printf 'subtask one\0subtask twö — café ☕\0subtask three\0' > "$RS_WORK/three.txt"
printf 'Line one.\nLine two — ünïcode.\nLine three.\0' > "$RS_WORK/mono.txt"
# read_subtask's emitted bash -c body (kept in lockstep with the .ag).
rs_extract() { n="$2" f="$1" bash -c 'i=0; while IFS= read -r -d "" rec; do i=$((i+1)); if [ "$i" = "$n" ]; then printf "%s" "$rec"; break; fi; done < "$f"'; }
# The orchestrator reference: read -r -d '' fd loop (code-edit-in-checkout.sh).
rs_ref() { _i=0; while IFS= read -r -d '' _c <&9; do _i=$((_i + 1)); if [ "$_i" = "$2" ]; then printf '%s' "$_c"; break; fi; done 9< "$1"; }
rs_fail=0
for spec in "three.txt:1" "three.txt:2" "three.txt:3" "mono.txt:1"; do
  fn="${spec%:*}"; idx="${spec#*:}"
  g="$(rs_extract "$RS_WORK/$fn" "$idx")"; r="$(rs_ref "$RS_WORK/$fn" "$idx")"
  [ "$g" = "$r" ] || { rs_fail=1; echo "  [diff] $fn rec $idx: extract=[$g] ref=[$r]"; }
done
rm -rf "$RS_WORK"
if [ "$rs_fail" = 0 ]; then
  pass "finding 2: read_subtask extraction is byte-identical to the in-shell read -r -d '' reference (3-record, multi-line, UTF-8)"
else
  fail "finding 2: extraction byte-identity vs in-shell reference"
fi

# -----------------------------------------------------------------------------
# Parse check: the agent commits cleanly under `agentis commit`, same as the
# per-agent syntax pass in colony-lint.sh. Skipped (not failed) when agentis is
# not installed, matching the CI runner contract. This is the guard for the
# read_subtask `read -r -d ""` escaping through the `.ag` string (the one dialect
# trap) and the decoupled ag_attempt_launch flag logic.
# -----------------------------------------------------------------------------
if command -v agentis >/dev/null 2>&1; then
  LINT_TMP="$(mktemp -d)"
  trap 'rm -rf "$LINT_TMP"' EXIT
  (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
  if (cd "$LINT_TMP" && agentis commit "$AG") >/dev/null 2>&1; then
    pass "code_writer.ag parses (agentis commit)"
  else
    fail "code_writer.ag parses (agentis commit)" "syntax error in code_writer.ag"
  fi
else
  echo "[SKIP] agentis not on PATH — skipping .ag parse check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
