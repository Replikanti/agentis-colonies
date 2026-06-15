#!/usr/bin/env bash
# demo-fm4-audit.sh — FM4 (#1058, epic #1041): audit-informed deep-invariant synthesis.
#
# Generic conservation / single-function invariants are exactly what auditors and formal tools check FIRST,
# so re-deriving them finds nothing new. FM4 folds the target's PRIOR AUDIT FINDINGS + the known-gap lens
# into the harness-generation prompt, so the LLM aims at what audits MISS (cross-function emergent state,
# deep economic value-extraction, multi-step accounting drift) and does NOT re-report an already-disclosed
# bug (worthless on a first-reporter bounty).
#
# The LLM-quality uplift is the model's job and can't be asserted offline; this demo proves the WIRING is
# correct and deterministic via run-autoharness.sh --dry-prompt (build + print the prompt, no LLM/forge):
#   - WITH --audit-context: the assembled prompt carries the FM4 audit-targeting block + the gap instruction
#     + the do-not-re-derive-disclosed instruction + the supplied audit findings verbatim;
#   - WITHOUT it: the prompt is byte-free of the FM4 block (additive — non-audit runs are unchanged);
#   - an unreadable --audit-context is a hard usage error (exit 2), never a silent skip.
# Offline + deterministic; needs neither forge nor the LLM wrapper.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/run-autoharness.sh"

FAIL=0
pass() { echo "demo-fm4-audit.sh: [PASS] $1"; }
fail() { echo "demo-fm4-audit.sh: [FAIL] $1" >&2; FAIL=1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A minimal recon spec (run-autoharness just embeds it) and a prior-audit context with a unique marker
# string + a clearly-disclosed finding so leakage/absence is unambiguous to assert.
cat > "$WORK/recon.txt" <<'TXT'
TARGET: 0x000000000000000000000000000000000000dEaD  (ExampleVault)
FUNCTIONS: deposit(uint256), withdraw(uint256), borrow(uint256)
FORK_BLOCK: 19000000
INVARIANT: total user claims never exceed vault assets.
TXT
DISCLOSED_MARKER="FM4_DISCLOSED_donation_inflation_OZ_audit_2024"
cat > "$WORK/audit.txt" <<TXT
KNOWN-GAP CLASSES for this target (auditors covered conservation; these are the gaps):
  - cross-function emergent state between borrow() and withdraw()
  - rounding drift compounded across many deposit/withdraw cycles
ALREADY-DISCLOSED (do not re-report):
  - $DISCLOSED_MARKER : first-deposit share-inflation, fixed in v2 (OZ audit).
TXT

# 1. WITH --audit-context: the FM4 block + instructions + the disclosed marker must be in the prompt.
P_WITH="$("$RUN" --spec "$WORK/recon.txt" --audit-context "$WORK/audit.txt" --dry-prompt 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && pass "--dry-prompt exits 0 with --audit-context" || fail "--dry-prompt + --audit-context exit $rc (expected 0)"
printf '%s' "$P_WITH" | grep -q 'FM4: AUDIT-INFORMED INVARIANT TARGETING' && pass "prompt carries the FM4 audit-targeting header" || fail "FM4 header missing from prompt"
printf '%s' "$P_WITH" | grep -qi 'GAP classes auditors' && pass "prompt instructs targeting the audit-GAP classes (not generic conservation)" || fail "gap-targeting instruction missing"
printf '%s' "$P_WITH" | grep -qi 'do NOT re-derive any finding listed below as already DISCLOSED' && pass "prompt instructs NOT to re-derive disclosed findings" || fail "disclosed-avoidance instruction missing"
printf '%s' "$P_WITH" | grep -qF "$DISCLOSED_MARKER" && pass "the supplied disclosed finding is folded into the prompt verbatim" || fail "audit-context contents not injected"
printf '%s' "$P_WITH" | grep -q '=== TARGET RECON ===' && pass "the base recon prompt is still present (FM4 is additive)" || fail "base recon prompt lost"

# 2. WITHOUT --audit-context: the FM4 block must be ABSENT (additive; non-audit runs unchanged).
P_NONE="$("$RUN" --spec "$WORK/recon.txt" --dry-prompt 2>/dev/null)"
if ! printf '%s' "$P_NONE" | grep -q 'FM4: AUDIT-INFORMED'; then
  pass "no --audit-context -> prompt has NO FM4 block (additive, default unchanged)"
else
  fail "FM4 block leaked into the prompt without --audit-context"
fi

# 3. Unreadable --audit-context is a hard usage error (exit 2), not a silent skip.
ec=0; "$RUN" --spec "$WORK/recon.txt" --audit-context "$WORK/does-not-exist.txt" --dry-prompt >/dev/null 2>&1 || ec=$?
[ "$ec" -eq 2 ] && pass "unreadable --audit-context -> exit 2 (hard error, not silent)" || fail "unreadable --audit-context gave exit $ec (expected 2)"

if [ "$FAIL" -eq 0 ]; then
  echo "demo-fm4-audit.sh: PASS: FM4 audit-informed targeting is wired correctly — prior-audit findings + the"
  echo "      gap lens + the do-not-re-report-disclosed instruction reach the generation prompt under"
  echo "      --audit-context, the prompt is unchanged without it, and a missing context file errors loudly."
  echo "      (The invariant-quality uplift is the LLM's; this proves the deterministic wiring.)"
  exit 0
fi
echo "demo-fm4-audit.sh: FAIL — see [FAIL] lines above" >&2
exit 1
