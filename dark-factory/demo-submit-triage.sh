#!/usr/bin/env bash
# demo-submit-triage.sh — offline, deterministic proof that submit-triage.sh turns a pile of staged
# submission packages into a readiness-scored review queue, prints a per-candidate human checklist, and
# NEVER submits. No network; throwaway temp staging root.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/submit-triage.sh"

FAIL=0
pass() { echo "demo-submit-triage.sh: [PASS] $1"; }
fail() { echo "demo-submit-triage.sh: [FAIL] $1" >&2; FAIL=1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/audit-out/submission"

# COMPLETE package: report.md (with a severity + the NOT-SUBMITTED marker) + a PoC -> should be READY.
mkdir -p "$ROOT/sherlock:good"
cat > "$ROOT/sherlock:good/report.md" <<'MD'
# FINDING — PENDING HUMAN REVIEW — NOT SUBMITTED
Severity: High
Target: 0xabc (ExampleVault)
Impact: solvency invariant broken by a manipulate-price -> borrow sequence.
MD
printf 'contract PoC {}\n' > "$ROOT/sherlock:good/poc.rs"

# INCOMPLETE package: report.md only, no PoC -> should be INCOMPLETE (missing poc).
mkdir -p "$ROOT/cantina:nopoc"
cat > "$ROOT/cantina:nopoc/report.md" <<'MD'
# FINDING — PENDING HUMAN REVIEW — NOT SUBMITTED
Severity: Medium
Target: 0xdef (OtherPool)
MD

OUT="$("$RUN" --root "$ROOT" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && pass "scan exits 0" || fail "scan exit $rc"

if printf '%s\n' "$OUT" | grep -q '^READY	HIGH	sherlock:good'; then
  pass "complete package -> READY (severity HIGH parsed)"
else
  fail "complete package not READY/HIGH; got: $(printf '%s' "$OUT" | grep good)"
fi
if printf '%s\n' "$OUT" | grep '^INCOMPLETE' | grep -q 'cantina:nopoc.*poc'; then
  pass "incomplete package -> INCOMPLETE, missing 'poc' flagged"
else
  fail "incomplete package not flagged INCOMPLETE/poc; got: $(printf '%s' "$OUT" | grep nopoc)"
fi

# Checklist mode for the READY candidate.
CL="$("$RUN" --checklist "$ROOT/sherlock:good" 2>/dev/null)"
printf '%s' "$CL" | grep -qi 'PoC reproduces' && printf '%s' "$CL" | grep -qi 'submit .* MANUALLY' \
  && pass "checklist prints review items + states the operator submits manually" \
  || fail "checklist missing review items / manual-submit note"

# Empty root -> clean [SKIP], exit 0.
mkdir -p "$WORK/empty"
"$RUN" --root "$WORK/empty" >/dev/null 2>&1 && pass "empty root -> exit 0 (clean SKIP)" || fail "empty root did not exit 0"

# Never-submit: the tool has no platform egress in its source.
if ! grep -nE 'curl|wget|nc |netcat|/dev/tcp|-X[[:space:]]*(POST|PUT)|--data|--upload|gh (pr|issue|api)' "$RUN" >/dev/null 2>&1; then
  pass "submit-triage.sh has no network-egress (never submits)"
else
  fail "submit-triage.sh contains an egress call — must never submit"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "demo-submit-triage.sh: PASS: the triage tool scored a complete package READY and an incomplete one"
  echo "      INCOMPLETE (missing PoC), printed the operator review+submit checklist, SKIPped an empty root,"
  echo "      and has no egress — a READY package is a human-submitted LEAD, never auto-posted."
  exit 0
fi
echo "demo-submit-triage.sh: FAIL — see [FAIL] lines above" >&2
exit 1
