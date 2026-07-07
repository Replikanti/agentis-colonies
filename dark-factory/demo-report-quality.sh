#!/usr/bin/env bash
# demo-report-quality.sh — end-to-end proof that a VERIFIED audit stages an Immunefi-shaped report.md
# (severity band + impact category + severity rationale + quantified/qualitative Impact quantification) and a
# REPRODUCTION.md manifest (#1456 / #1457). Runs run-audit.sh with the offline `mock` backend against a
# std-only fixture; NO network, NO Solana toolchain. SKIPs cleanly (exit 0) when the `agentis` binary is not
# on PATH (CI runners have none), so it never fails the lint gate — it is a local / agentis-present regression.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

FAIL=0
pass() { echo "demo-report-quality.sh: [PASS] $1"; }
fail() { echo "demo-report-quality.sh: [FAIL] $1" >&2; FAIL=1; }

# --- SOURCE-level branch coverage (runs on CI too — no agentis needed) ---------------------------------------
# The report's class->string maps must not silently lose a branch. Assert every vuln class in the taxonomy has
# an `impact_category_for` branch, and every Immunefi band has a `rubric_line_for` branch. A deleted branch
# would otherwise fall through to the generic default and mislabel a real finding.
AG_SRC="$HERE/auditor/agents/auditor.ag"
fn_body() { awk "/^fn $1\\(/{s=1} s{print} s&&/^}/{exit}" "$AG_SRC" 2>/dev/null; }
IC="$(fn_body impact_category_for)"; RL="$(fn_body rubric_line_for)"
for cls in MissingSignerCheck MissingOwnerCheck AccountDataMatching ArbitraryCPI IntegerOverflow \
           Reentrancy AccessControl UncheckedCall OracleManipulation; do
  printf '%s' "$IC" | grep -qF "\"$cls\"" || fail "impact_category_for missing a branch for class $cls"
done
[ "$FAIL" -eq 0 ] && pass "impact_category_for covers all 9 taxonomy classes (no dropped branch)"
band_ok=1
for band in Critical High Medium; do printf '%s' "$RL" | grep -qF "== \"$band\"" || band_ok=0; done
printf '%s' "$RL" | grep -qi 'Informational' || band_ok=0
[ "$band_ok" -eq 1 ] && pass "rubric_line_for covers Critical/High/Medium/Informational bands" || fail "rubric_line_for missing a severity band"

# --- End-to-end report generation (needs the agentis runtime + rustc) ---------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  echo "demo-report-quality.sh: [SKIP] agentis not on PATH — report-generation e2e needs the runtime (CI has none)"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi
command -v rustc >/dev/null 2>&1 || { echo "demo-report-quality.sh: [SKIP] rustc not on PATH — std-only PoC needs it"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
TGT="$HERE/fixtures/vuln_missing_signer.rs"   # std-only MissingSignerCheck fixture (compiles offline)

run_audit() {  # $1=out dir ; $2..=extra flags
  local out="$1"; shift
  "$HERE/run-audit.sh" --target "$TGT" --backend mock --sandbox none --out "$out" "$@" >/dev/null 2>&1
}

# --- 1. VERIFIED without a snapshot: report + REPRODUCTION.md staged; impact is the qualitative fallback ---
O1="$WORK/nosnap"
run_audit "$O1"
R1="$O1/submission/report.md"; M1="$O1/submission/REPRODUCTION.md"
if [ -f "$R1" ] && [ -f "$M1" ]; then pass "VERIFIED run stages report.md + REPRODUCTION.md"; else fail "submission package incomplete (report.md / REPRODUCTION.md missing)"; fi
grep -q '## Impact quantification' "$R1" 2>/dev/null && pass "report has Impact quantification section" || fail "report missing Impact quantification"
grep -qi '| Impact category |' "$R1" 2>/dev/null && grep -qi '| Severity rationale |' "$R1" 2>/dev/null && pass "report has Impact category + Severity rationale rows" || fail "report missing impact-category / severity-rationale rows"
grep -q 'Critical' "$R1" 2>/dev/null && pass "MissingSignerCheck mapped to Critical band" || fail "severity band not Critical"
sed -n '/## Impact quantification/,/^## /p' "$R1" | grep -q 'Qualitative:' && pass "no-snapshot run -> Qualitative funds-at-risk (honest, not a fabricated figure)" || fail "no-snapshot run did not fall back to Qualitative"
# Strengthened: assert the manifest carries the ACTUAL sha256 of the staged target, not just a sha256 line.
WANT_SHA="$( { sha256sum "$TGT" 2>/dev/null || shasum -a 256 "$TGT" 2>/dev/null; } | awk '{print $1}')"
if [ -n "$WANT_SHA" ] && grep -qF "$WANT_SHA" "$M1" 2>/dev/null && grep -q 'run-audit.sh --target' "$M1" 2>/dev/null; then
  pass "REPRODUCTION.md carries the target's real sha256 ($WANT_SHA) + deterministic rerun command"
else
  fail "REPRODUCTION.md missing the correct target sha256 / rerun command"
fi

# --- 2. VERIFIED with a REAL single-account snapshot: funds-at-risk is quantified from the frozen value ---
SNAP2="$WORK/snap-single.txt"; printf 'vault.authority=1\nvault.balance=4200\naccount.lamports=750000000\naccount.data_first8_le=4200\n' > "$SNAP2"
O2="$WORK/snap"; run_audit "$O2" --snapshot "$SNAP2"
R2="$O2/submission/report.md"
sed -n '/## Impact quantification/,/^## /p' "$R2" | grep -q '750000000 lamports' && pass "real --snapshot -> quantified '750000000 lamports at risk'" || fail "snapshot run did not quantify the frozen lamports"
grep -q 'owner rebind' "$R2" 2>/dev/null && pass "snapshot report discloses the account-owner rebind (#1457)" || fail "snapshot report missing owner-rebind disclosure"
grep -q 'DISCLOSURE' "$O2/submission/REPRODUCTION.md" 2>/dev/null && pass "REPRODUCTION.md repeats the owner-rebind disclosure on snapshot runs" || fail "REPRODUCTION.md missing owner-rebind disclosure"

# --- 3. REGRESSION (#1462 review): a MULTI-account dump must quantify the program's OWN account, not a
#        longer-keyed one — marker_int is line-anchored, so `account.lamports=` must not match inside
#        `token_account.lamports=`. The reported figure must match what the PoC actually drains. ---
SNAP3="$WORK/snap-multi.txt"; printf 'token_account.lamports=999999999\naccount.lamports=50\nvault.balance=50\n' > "$SNAP3"
O3="$WORK/multi"; run_audit "$O3" --snapshot "$SNAP3"
R3="$O3/submission/report.md"
if sed -n '/## Impact quantification/,/^## /p' "$R3" | grep -q '50 lamports'; then
  pass "multi-account dump quantifies the OWN account (50 lamports), not the shadowing token_account (999999999)"
else
  fail "multi-account regression: reported figure is not 50 lamports; got: $(sed -n '/## Impact quantification/,/^## /p' "$R3" | grep -o '[0-9]* lamports' | head -1)"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "demo-report-quality.sh: PASS: a VERIFIED audit stages an Immunefi-shaped report + REPRODUCTION.md;"
  echo "      funds-at-risk is quantified ONLY from a real snapshot (qualitative otherwise), the owner-rebind is"
  echo "      disclosed, and a multi-account dump quantifies the program's own account (line-anchored marker_int)."
  exit 0
fi
echo "demo-report-quality.sh: FAIL — see [FAIL] lines above" >&2
exit 1
