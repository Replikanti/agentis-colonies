#!/usr/bin/env bash
# test-idle-prompt-gates.sh: #1370 grep/awk source-assertion tests for the
# idle-prompt-suppression (B3) + planning-colony thrash fix (B2).
#
# Background. Every ticking agent has a staleness gate that satisfies
# check-prompt-gate.sh, but the per-issue "handled" marker was written ONLY in
# the autonomous-tier branch after a terminal action. At the default
# sub-autonomous tier the marker was never set, so the prompt() fired every tick
# on the same `[0]` issue. The planning colony additionally thrashed because all
# four agents picked raw `[0]` of an `updated_at desc`-sorted list and each note
# they posted bumped the issue back to `[0]`.
#
# This test asserts, structurally (no .ag unit harness exists, so we grep/awk
# the source the same way tools/test-code-writer-completion-markers.sh does):
#
#   A. Planning agents (scope_estimator, task_decomposer, risk_assessor,
#      plan_reviewer):
#        A1. the per-issue handled-marker write (memo_write(handled_key(...)))
#            appears OUTSIDE the `if my_tier == "autonomous"` branch — i.e. on
#            the non-autonomous side (review-gated / propose / shadow);
#        A2. the `[0]`-style raw selection is replaced by a handled-FILTER:
#            the target iid comes from first_unhandled_iid(...), so handled
#            issues are skipped BEFORE indexing;
#        A3. the prompt is PINNED to the computed target (it references the
#            "Target issue id" instead of "pick the newest unplanned issue"),
#            so the gated and acted-on issue match.
#
#   B. plan_reviewer additionally reads the peers' PERSISTENT *_drafted keys for
#      readiness (slot_ready consults :<slot>_drafted), so it converges on the
#      same issue the peers actually completed.
#
#   C. code_writer has a tier-independent input-unchanged early-return BEFORE its
#      draft prompt(): input_unchanged(...) is consulted ahead of the
#      `draft = prompt(` line, the early-return is guarded by has_mr_for_branch
#      (so the #1363 MR-less-branch rescue is NOT regressed), and a per-tick
#      fingerprint memo (last_seen_iid) is written.
#
#   D. The planning `issues` query sorts created_at asc (stable) in both forge
#      backends, so an agent's own note-post does not reshuffle `[0]`.
#
# Matches the test style of tools/test-code-writer-completion-markers.sh (bash,
# [PASS]/[FAIL] lines, `Results: N passed, M failed`). Exit 0 all-pass, 1
# any-fail. Uses explicit if/then (never `cmd && a || b`) so CI shellcheck 0.9.0
# does not flag SC2015. Related: #1370, #1363, #1185.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PLANNING="$REPO_ROOT/dev-apprenticeship/planning/agents"
IMPL="$REPO_ROOT/dev-apprenticeship/implementation/agents"
GL_API="$REPO_ROOT/dev-apprenticeship/planning/scripts/gitlab-api.sh"
GH_API="$REPO_ROOT/dev-apprenticeship/planning/scripts/github-api.sh"
PASS=0
FAIL=0
WARN=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }
# warn(): a tracked, non-blocking observation. Used for the propose-tier
# durability gap (QA #1371): the peers should write a persistent consumable
# signal at the `propose` tier too (not just review-gated), so plan_reviewer's
# readiness does not depend on catching a single transient bus emit. Reported,
# not failed, so it does not block an otherwise-green PR.
warn() { echo "[WARN] $1${2:+: $2}"; WARN=$((WARN + 1)); }

# nonauto_region <ag-file>
# Slice the act/tier section from the `} else {` that opens the non-autonomous
# side (the line immediately following the autonomous branch's close) to end of
# file. We anchor on the first `if my_tier == "autonomous"` then take everything
# after the matching tier-else. Simpler + robust: print from the FIRST line that
# contains a non-autonomous tier string to EOF.
nonauto_region() {
  awk '
    /if my_tier == "review-gated"/ { grab=1 }
    grab { print }
  ' "$1"
}

# auto_region <ag-file>
# Slice from `if my_tier == "autonomous"` up to (not incl.) the non-autonomous
# `if my_tier == "review-gated"` branch.
auto_region() {
  awk '
    /if my_tier == "autonomous"/ { grab=1 }
    /if my_tier == "review-gated"/ { grab=0 }
    grab { print }
  ' "$1"
}

# -----------------------------------------------------------------------------
# A. Planning agents.
# -----------------------------------------------------------------------------
for agent in scope_estimator task_decomposer risk_assessor plan_reviewer; do
  AG="$PLANNING/$agent.ag"
  if [ ! -f "$AG" ]; then
    fail "$agent.ag present" "missing $AG"
    continue
  fi

  # A1. handled-marker write OUTSIDE the autonomous-only branch. The
  # non-autonomous region must carry at least one memo_write(handled_key(...)).
  region_nonauto="$(nonauto_region "$AG")"
  if printf '%s\n' "$region_nonauto" | grep -F -q -- 'memo_write(handled_key('; then
    pass "$agent: handled marker written at non-autonomous tiers (review-gated/propose/shadow)"
  else
    fail "$agent: all-tier handled marker" \
      "no memo_write(handled_key(...)) found outside the autonomous branch"
  fi

  # A1b. the autonomous branch ALSO writes the handled marker (every tier).
  region_auto="$(auto_region "$AG")"
  if printf '%s\n' "$region_auto" | grep -F -q -- 'memo_write(handled_key('; then
    pass "$agent: handled marker also written at the autonomous tier"
  else
    fail "$agent: autonomous handled marker" \
      "no memo_write(handled_key(...)) inside the autonomous branch"
  fi

  # A2. handled-FILTER before indexing: target iid comes from
  # first_unhandled_iid(...), not a raw json_get(...,"[0].iid") selection.
  if grep -F -q -- 'let target_iid = first_unhandled_iid(owner, repo, issues_raw, 0)' "$AG"; then
    pass "$agent: target_iid filters handled issues before indexing (first_unhandled_iid)"
  else
    fail "$agent: handled-filter selection" \
      "target_iid is not derived from first_unhandled_iid(owner, repo, issues_raw, 0)"
  fi

  # A2b. the early-return on no-unhandled-issue precedes the prompt() — the
  # `if target_iid <= 0 { ... return; }` guard must appear before `prompt(`.
  guard_line="$(grep -n -F -- 'let target_iid = first_unhandled_iid(' "$AG" | head -1 | cut -d: -f1)"
  prompt_line="$(awk 'index($0, "prompt(") && !/colony-lint/ { if (seen_target) { print NR; exit } } /let target_iid = first_unhandled_iid\(/ { seen_target=1 }' "$AG")"
  if [ -n "$guard_line" ] && [ -n "$prompt_line" ] && [ "$guard_line" -lt "$prompt_line" ]; then
    pass "$agent: the no-unhandled-issue filter precedes the act prompt()"
  else
    fail "$agent: filter-before-prompt ordering" \
      "first_unhandled_iid selection not found before the act prompt() (guard=$guard_line prompt=$prompt_line)"
  fi

  # A3. prompt pinned to the computed target. The three selection agents
  # (scope_estimator/task_decomposer/risk_assessor) reference the explicit
  # "Target issue id" splice; plan_reviewer is an assembly prompt that was
  # already pinned via its `Issue id:` context + "the target issue" instruction
  # (it never picked from a list). Either pin form counts.
  if grep -F -q -- 'Target issue id' "$AG" || grep -F -q -- 'the target issue' "$AG"; then
    pass "$agent: act prompt is pinned to the computed target issue"
  else
    fail "$agent: prompt pinned to target" \
      "act prompt does not reference the computed target issue"
  fi
  # No agent's prompt or comments may still describe the pre-#1370 'pick the
  # newest' raw-[0] selection (decoupled from the gate).
  if grep -F -q -- 'Pick the newest unplanned issue' "$AG"; then
    fail "$agent: stale 'pick the newest' wording" \
      "source still says 'Pick the newest unplanned issue' (decoupled from the gate)"
  else
    pass "$agent: dropped the 'pick the newest unplanned issue' wording"
  fi
done

# -----------------------------------------------------------------------------
# B. plan_reviewer reads peers' PERSISTENT *_drafted keys for readiness.
# -----------------------------------------------------------------------------
PR="$PLANNING/plan_reviewer.ag"
if [ -f "$PR" ]; then
  if grep -F -q -- '_drafted' "$PR" && grep -F -q -- 'slot_ready(owner, repo, target_iid' "$PR"; then
    pass "plan_reviewer: readiness consults the persistent peer *_drafted keys (slot_ready)"
  else
    fail "plan_reviewer: persistent-key readiness" \
      "slot_ready / *_drafted readiness path not found in plan_reviewer.ag"
  fi
fi

# -----------------------------------------------------------------------------
# B2. propose-tier DURABILITY (QA #1371). At the `propose` tier each peer
# emits its bus event ONCE and then writes its handled marker, so it never
# re-emits for that issue. plan_reviewer's slot_ready() reads BOTH the transient
# stash (filled only when its 500ms listen() window happens to catch that single
# emit) AND the persistent `<slot>_drafted` key — but the peers write the
# persistent key ONLY in their review-gated branch. So at the propose tier,
# plan_reviewer's readiness for an issue depends on catching a single point-in-
# time emit; if it misses, the slot is permanently empty (no durable fallback),
# plan_reviewer head-of-line-blocks on that issue, and the planning pipeline
# starves it. Writing the `<slot>_drafted` key in the propose branch too (a memo,
# ADR-0001-legal at every tier) closes the gap. Reported as WARN (non-blocking).
for peer in scope_estimator:scope_drafted task_decomposer:breakdown_drafted risk_assessor:risks_drafted; do
  agent="${peer%%:*}"
  key="${peer##*:}"
  AG="$PLANNING/$agent.ag"
  [ -f "$AG" ] || continue
  # Slice the propose branch: from `if my_tier == "propose"` to the next
  # `memo_write(handled_key(` (which closes the propose action).
  propose_region="$(awk '
    /if my_tier == "propose"/ { grab=1 }
    grab { print }
    grab && /memo_write\(handled_key\(/ { exit }
  ' "$AG")"
  if printf '%s\n' "$propose_region" | grep -F -q -- "$key"; then
    pass "$agent: writes the persistent $key key at the propose tier (durable plan_reviewer signal)"
  else
    warn "$agent: propose tier emits but does NOT write the persistent $key key" \
      "plan_reviewer readiness at propose depends on catching one transient emit; a miss starves the issue (head-of-line block). Fix: write the $key memo in the propose branch too (ADR-0001-legal)"
  fi
done

# -----------------------------------------------------------------------------
# C. code_writer input-unchanged early-return before the draft prompt.
# -----------------------------------------------------------------------------
CW="$IMPL/code_writer.ag"
if [ ! -f "$CW" ]; then
  fail "code_writer.ag present" "missing $CW"
else
  # C1. input_unchanged(...) is consulted BEFORE the `draft = prompt(` line.
  iu_line="$(grep -n -F -- 'if input_unchanged(owner, repo, first_iid_str, first_upd)' "$CW" | head -1 | cut -d: -f1)"
  draft_line="$(grep -n -F -- 'let draft = prompt(' "$CW" | head -1 | cut -d: -f1)"
  if [ -n "$iu_line" ] && [ -n "$draft_line" ] && [ "$iu_line" -lt "$draft_line" ]; then
    pass "code_writer: input_unchanged early-return precedes the draft prompt()"
  else
    fail "code_writer: input-unchanged ordering" \
      "input_unchanged() not found before the draft prompt() (input=$iu_line draft=$draft_line)"
  fi

  # C2. the early-return does NOT regress #1363: it is guarded by
  # has_mr_for_branch so an MR-less branch (a launched job that died) is never
  # suppressed. Slice from the input_unchanged check to the draft prompt and
  # assert has_mr_for_branch appears in that window.
  early_window="$(awk '
    /if input_unchanged\(owner, repo, first_iid_str, first_upd\)/ { grab=1 }
    /let draft = prompt\(/ { if (grab) exit }
    grab { print }
  ' "$CW")"
  if printf '%s\n' "$early_window" | grep -F -q -- 'has_mr_for_branch(owner, repo, first_iid_str)'; then
    pass "code_writer: early-return guarded by has_mr_for_branch (no #1363 MR-less rescue regression)"
  else
    fail "code_writer: has_mr_for_branch guard" \
      "input-unchanged early-return is not guarded by has_mr_for_branch (would suppress MR-less branches)"
  fi

  # C3. a tier-independent fingerprint memo (last_seen_iid) is written so the
  # early-return is robust regardless of the #1185 completion markers.
  if grep -F -q -- 'memo_write(scoped_memo(owner, repo, "code_writer:last_seen_iid")' "$CW"; then
    pass "code_writer: writes the tier-independent input fingerprint (last_seen_iid)"
  else
    fail "code_writer: fingerprint memo" \
      "no memo_write of code_writer:last_seen_iid found"
  fi

  # C4. the #1363 MR-less re-draft path is still intact. Since #1516 the gate is
  # `mr_exists = has_mr_for_branch(...)` + `needs_draft = !mr_exists`, so an
  # issue with NO MR still gets a fresh draft (the rescue), while an existing MR
  # is terminal (never re-drafted over — the #1516 fix). Assert both halves.
  if grep -F -q -- 'let mr_exists = has_mr_for_branch(owner, repo, first_iid_str);' "$CW" \
     && grep -F -q -- 'let needs_draft = !mr_exists;' "$CW"; then
    pass "code_writer: #1363 MR-less rescue preserved via needs_draft = !mr_exists (#1516)"
  else
    fail "code_writer: #1363 re-draft preserved" \
      "needs_draft is no longer derived from !has_mr_for_branch via mr_exists (regression)"
  fi
fi

# -----------------------------------------------------------------------------
# D. Stable planning issues ordering (created_at asc) in both forge backends.
# -----------------------------------------------------------------------------
if [ -f "$GL_API" ]; then
  if grep -F -q -- 'order_by=created_at' "$GL_API" && grep -F -q -- 'sort=asc' "$GL_API"; then
    pass "gitlab-api.sh: planning issues query sorts created_at asc (stable)"
  else
    fail "gitlab-api.sh stable sort" \
      "planning issues query is not order_by=created_at / sort=asc"
  fi
fi
if [ -f "$GH_API" ]; then
  if grep -F -q -- 'sort=created' "$GH_API" && grep -F -q -- 'direction=asc' "$GH_API"; then
    pass "github-api.sh: planning issues query sorts created asc (stable)"
  else
    fail "github-api.sh stable sort" \
      "planning issues query is not sort=created / direction=asc"
  fi
fi

# -----------------------------------------------------------------------------
# Parse check: every touched .ag commits cleanly under `agentis commit`, same as
# the per-agent syntax pass in colony-lint.sh. Skipped (not failed) when agentis
# is not installed, matching the CI runner contract.
# -----------------------------------------------------------------------------
if command -v agentis >/dev/null 2>&1; then
  LINT_TMP="$(mktemp -d)"
  trap 'rm -rf "$LINT_TMP"' EXIT
  (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
  for ag in "$PLANNING/scope_estimator.ag" "$PLANNING/task_decomposer.ag" \
            "$PLANNING/risk_assessor.ag" "$PLANNING/plan_reviewer.ag" \
            "$IMPL/code_writer.ag"; do
    name="$(basename "$ag")"
    if (cd "$LINT_TMP" && agentis commit "$ag") >/dev/null 2>&1; then
      pass "$name parses (agentis commit)"
    else
      fail "$name parses (agentis commit)" "syntax error in $name"
    fi
  done
else
  echo "[SKIP] agentis not on PATH — skipping .ag parse checks"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
[ "$FAIL" -eq 0 ]
