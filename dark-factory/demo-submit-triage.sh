#!/usr/bin/env bash
# demo-submit-triage.sh — offline, deterministic proof that submit-triage.sh turns a pile of staged
# submission packages into a readiness-scored review queue, flags impact-credibility + duplicate-risk,
# prints a per-candidate human checklist, and NEVER submits. No network; throwaway temp staging root.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/submit-triage.sh"

FAIL=0
pass() { echo "demo-submit-triage.sh: [PASS] $1"; }
fail() { echo "demo-submit-triage.sh: [FAIL] $1" >&2; FAIL=1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/audit-out/submission"

# COMPLETE + impact-credible package: report.md (severity + NOT-SUBMITTED marker + the #1456 impact-
# quantification section and Impact category row) + a PoC + a repro manifest -> READY / IMPACT=quant.
mkdir -p "$ROOT/sherlock:good"
cat > "$ROOT/sherlock:good/report.md" <<'MD'
# Bounty finding — AccessControl
| Field | Value |
|---|---|
| Severity (Immunefi) | High |
| Impact category | Direct theft of funds / protocol takeover |
| Rule | AccessControl |
| Affected function | `manipulatePrice` |

## Impact quantification

**1000 units** of the vault balance are drained by the unauthorized caller in the PoC.

## Submission — HUMAN-GATED (NOT SUBMITTED)
STATUS: PENDING HUMAN APPROVAL — NOT SUBMITTED.
MD
printf 'fn main() {}\n' > "$ROOT/sherlock:good/poc.rs"
printf '# Reproduction manifest\n' > "$ROOT/sherlock:good/REPRODUCTION.md"

# INCOMPLETE package: report.md only, no PoC, no impact section -> INCOMPLETE (missing poc), IMPACT=qual?.
mkdir -p "$ROOT/cantina:nopoc"
cat > "$ROOT/cantina:nopoc/report.md" <<'MD'
# FINDING — PENDING HUMAN REVIEW — NOT SUBMITTED
Severity: Medium
Target: 0xdef (OtherPool)
MD

# COMPLETE package whose affected function collides with a known disclosure -> DUP-RISK under --known-issues.
mkdir -p "$ROOT/code4rena:dup"
cat > "$ROOT/code4rena:dup/report.md" <<'MD'
# Bounty finding — MissingSignerCheck
| Field | Value |
|---|---|
| Severity (Immunefi) | Critical |
| Impact category | Direct theft of user/protocol funds |
| Rule | MissingSignerCheck |
| Affected function | `withdraw` |

## Impact quantification

**1000000000 lamports** are movable by an unauthorized caller.

## Submission — HUMAN-GATED (NOT SUBMITTED)
STATUS: PENDING HUMAN APPROVAL — NOT SUBMITTED.
MD
printf 'fn main() {}\n' > "$ROOT/code4rena:dup/poc.rs"
printf '# Reproduction manifest\n' > "$ROOT/code4rena:dup/REPRODUCTION.md"

# Known-issues list (public disclosures to exclude) — one signature per line.
KNOWN="$WORK/known.txt"
cat > "$KNOWN" <<'MD'
# already-disclosed on this program
withdraw missing signer check (reported 2026-01)
MD

# --- scan WITHOUT --known-issues: novelty unchecked ---
OUT="$("$RUN" --root "$ROOT" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && pass "scan exits 0" || fail "scan exit $rc"

if printf '%s\n' "$OUT" | grep -qP '^READY\tHIGH\tquant\tunchecked\tsherlock:good'; then
  pass "complete+impact-credible -> READY, SEVERITY=HIGH, IMPACT=quant, NOVELTY=unchecked"
else
  fail "good package row wrong; got: $(printf '%s' "$OUT" | grep good)"
fi
if printf '%s\n' "$OUT" | grep '^INCOMPLETE' | grep 'cantina:nopoc' | grep -q 'poc'; then
  pass "incomplete package -> INCOMPLETE, missing 'poc' flagged"
else
  fail "incomplete package not flagged INCOMPLETE/poc; got: $(printf '%s' "$OUT" | grep nopoc)"
fi
if printf '%s\n' "$OUT" | grep 'cantina:nopoc' | grep -q 'qual?'; then
  pass "impact-less report flagged IMPACT=qual?"
else
  fail "impact-less report not flagged qual?; got: $(printf '%s' "$OUT" | grep nopoc)"
fi

# --- scan WITH --known-issues: the colliding package becomes DUP-RISK, the good one stays novel ---
OUT2="$("$RUN" --root "$ROOT" --known-issues "$KNOWN" 2>/dev/null)"
if printf '%s\n' "$OUT2" | grep 'code4rena:dup' | grep -q 'DUP-RISK'; then
  pass "known-issue collision -> DUP-RISK (not silently READY)"
else
  fail "collision not flagged DUP-RISK; got: $(printf '%s' "$OUT2" | grep dup)"
fi
if printf '%s\n' "$OUT2" | grep 'sherlock:good' | grep -q 'novel'; then
  pass "non-colliding package -> NOVELTY=novel under --known-issues"
else
  fail "good package not flagged novel; got: $(printf '%s' "$OUT2" | grep good)"
fi

# Checklist mode for the READY candidate — must surface repro + impact + dedup review items.
CL="$("$RUN" --checklist "$ROOT/sherlock:good" --known-issues "$KNOWN" 2>/dev/null)"
printf '%s' "$CL" | grep -qi 'PoC reproduces' \
  && printf '%s' "$CL" | grep -qi 'repro manifest' \
  && printf '%s' "$CL" | grep -qi 'funds-at-risk quantified' \
  && printf '%s' "$CL" | grep -qi 'submit .* MANUALLY' \
  && pass "checklist prints repro + impact + dedup review items + manual-submit note" \
  || fail "checklist missing repro/impact/dedup review items / manual-submit note"

# Empty root -> clean [SKIP], exit 0.
mkdir -p "$WORK/empty"
"$RUN" --root "$WORK/empty" >/dev/null 2>&1 && pass "empty root -> exit 0 (clean SKIP)" || fail "empty root did not exit 0"

# Bad --known-issues path -> exit 2.
"$RUN" --root "$ROOT" --known-issues "$WORK/does-not-exist" >/dev/null 2>&1
[ "$?" -eq 2 ] && pass "missing --known-issues file -> exit 2" || fail "missing --known-issues did not exit 2"

# Never-submit: the tool has no platform egress in its source.
if ! grep -nE 'curl|wget|nc |netcat|/dev/tcp|-X[[:space:]]*(POST|PUT)|--data|--upload|gh (pr|issue|api)' "$RUN" >/dev/null 2>&1; then
  pass "submit-triage.sh has no network-egress (never submits)"
else
  fail "submit-triage.sh contains an egress call — must never submit"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "demo-submit-triage.sh: PASS: the triage tool scored a complete package READY (IMPACT=quant), an"
  echo "      incomplete one INCOMPLETE (missing PoC, IMPACT=qual?), flagged a known-issue collision DUP-RISK,"
  echo "      printed the operator repro+impact+dedup checklist, SKIPped an empty root, and has no egress."
  exit 0
fi
echo "demo-submit-triage.sh: FAIL — see [FAIL] lines above" >&2
exit 1
