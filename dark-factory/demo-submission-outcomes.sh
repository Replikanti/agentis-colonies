#!/usr/bin/env bash
# demo-submission-outcomes.sh — OFFLINE, DETERMINISTIC proof (#1901, epic #1894 M5) of submission-outcomes.sh:
# a read-only, zero-egress aggregator over a drop-dir's manifest.json + .outcome-ingested / .pending-
# confirmation markers. Fixtures are built to match the REAL on-disk shapes deliver-submission.sh /
# ingest-slack-outcome.sh write — never invented ones — so a demo pass actually predicts a pass on real data.
# No network, no agentis, no LLM.
#
# Asserts:
#   AC1 — each of the 5 fixture rows' outcome/reason/payout fields match the fixture exactly (accepted with a
#         payout override, rejected, duplicate, held/low-confidence, pending).
#   AC2 — the stderr rollup line reports accepted=1 rejected=1 duplicate=1 needs-info=0 out-of-scope=0 held=1
#         pending=1 total=5.
#   AC3 — a decoy `  payout:` line 2-space-indented INSIDE the `platform_response: |` body is never picked up
#         as the payout override (column-0 anchor proof).
#   AC4 — a second, empty drop-dir run produces zero TSV rows, exit 0, and an all-zero rollup line.
#   AC5 — a stage subdir with no manifest.json at all is silently skipped: not counted in the rollup, no crash.
#
# Usage:  dark-factory/demo-submission-outcomes.sh
# Requires: python3. Exit: 0 = all assertions held; non-zero = a failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGG="$HERE/submission-outcomes.sh"

FAILS=0
note() { echo "demo-submission-outcomes.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$AGG" ] || { note "submission-outcomes.sh not found / not executable: $AGG" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-submission-outcomes.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Never touch the real ~/.dark-factory.
export DARK_FACTORY_DIR="$WORK/dark-factory-home"
DROP="$DARK_FACTORY_DIR/drop"
mkdir -p "$DROP"

write_manifest() {
  # $1 = stage dir, $2 = submission_id, $3 = target, $4 = severity_band
  python3 -c '
import json, sys
d = {"submission_id": sys.argv[2], "target": sys.argv[3], "severity_band": sys.argv[4], "status": "delivered"}
with open(sys.argv[1] + "/manifest.json", "w") as f:
    json.dump(d, f, indent=2, sort_keys=True)
' "$1" "$2" "$3" "$4"
}

# ----------------------------------------------------------------------------------------------------------
# Fixture 1: accepted-one — .outcome-ingested disposition=accepted stage=impact-gate, plus an OUTCOME.md
# with an uncommented column-0 `payout:` override AND a decoy 2-space-indented `  payout:` line inside the
# platform_response body (AC3's negative-match proof).
# ----------------------------------------------------------------------------------------------------------
S1="$DROP/accepted-one"
mkdir -p "$S1"
write_manifest "$S1" "enzyme-onyx@a1b2c3d:sync-deposit-nav-frontrun" "enzyme-onyx" "High"
{
  printf '%s\n' "# OUTCOME — captured from the Slack thread by ingest-slack-outcome.sh (#1561)."
  printf '%s\n' "# submission_id: enzyme-onyx@a1b2c3d:sync-deposit-nav-frontrun"
  printf '%s\n' "platform_response: |"
  printf '%s\n' "  Confirmed High, paying out per policy."
  printf '%s\n' "  payout: 999 DECOY   # must NOT be read — this line is indented, not column-0"
  printf '%s\n' "verdict:        accepted   # operator override"
  printf '%s\n' "payout:         25000 USDC   # operator override"
} > "$S1/OUTCOME.md"
printf '%s\n' "ingested 2026-08-01T00:00:00Z disposition=accepted signal=SUCCESS stage=impact-gate" > "$S1/.outcome-ingested"

# Fixture 2: rejected-one — disposition=rejected stage=scope-gate, no payout line.
S2="$DROP/rejected-one"
mkdir -p "$S2"
write_manifest "$S2" "vault-thistle@f00dcafe:owner-only-bypass" "vault-thistle" "Medium"
printf '%s\n' "ingested 2026-08-01T00:00:00Z disposition=rejected signal=FAILURE stage=scope-gate" > "$S2/.outcome-ingested"

# Fixture 3: dup-one — disposition=duplicate stage=dup-scout.
S3="$DROP/dup-one"
mkdir -p "$S3"
write_manifest "$S3" "vault-thistle@f00dcafe:reentrant-withdraw" "vault-thistle" "Low"
printf '%s\n' "ingested 2026-08-01T00:00:00Z disposition=duplicate signal=FAILURE stage=dup-scout" > "$S3/.outcome-ingested"

# Fixture 4: held-one — no .outcome-ingested, only .pending-confirmation (low-confidence, held for a clearer reply).
S4="$DROP/held-one"
mkdir -p "$S4"
write_manifest "$S4" "enzyme-onyx@a1b2c3d:oracle-staleness" "enzyme-onyx" "Medium"
printf '%s\n' "held 2026-08-01T00:00:00Z reply_ts=1700000000.0001 disposition=rejected confidence=low" > "$S4/.pending-confirmation"

# Fixture 5: pending-one — manifest.json only, no markers at all (freshly staged, awaiting a platform reply).
S5="$DROP/pending-one"
mkdir -p "$S5"
write_manifest "$S5" "enzyme-onyx@a1b2c3d:rounding-drift" "enzyme-onyx" "Low"

# Fixture 6 (AC5): a stage subdir with NO manifest.json at all — must be silently skipped, never crash, never counted.
S6="$DROP/no-manifest-one"
mkdir -p "$S6"
printf '%s\n' "ingested 2026-08-01T00:00:00Z disposition=accepted signal=SUCCESS stage=impact-gate" > "$S6/.outcome-ingested"

# ----------------------------------------------------------------------------------------------------------
note "1) --summary over the mixed-outcome drop-dir ..."
OUT="$("$AGG" --summary --drop-dir "$DROP" 2>"$WORK/stderr1.txt")"
RC=$?
[ "$RC" -eq 0 ] && ok "exits 0 on a mixed-outcome drop-dir" || bad "exited $RC (expected 0)"

row_for() { printf '%s\n' "$OUT" | awk -F'\t' -v sid="$1" '$1==sid{print; found=1} END{if(!found) print ""}'; }

# AC1 — per-row fields.
R1="$(row_for "enzyme-onyx@a1b2c3d:sync-deposit-nav-frontrun")"
if [ -n "$R1" ]; then
  T="$(printf '%s' "$R1" | awk -F'\t' '{print $2}')"
  SEV="$(printf '%s' "$R1" | awk -F'\t' '{print $3}')"
  OC="$(printf '%s' "$R1" | awk -F'\t' '{print $4}')"
  PO="$(printf '%s' "$R1" | awk -F'\t' '{print $5}')"
  RS="$(printf '%s' "$R1" | awk -F'\t' '{print $6}')"
  [ "$T" = "enzyme-onyx" ] && [ "$SEV" = "High" ] && [ "$OC" = "accepted" ] && [ "$RS" = "impact-gate" ] \
    && ok "accepted-one: target/severity/outcome/reason correct" \
    || bad "accepted-one: target/severity/outcome/reason mismatch (got target=$T severity=$SEV outcome=$OC reason=$RS)"
  [ "$PO" = "25000 USDC" ] && ok "accepted-one: payout is the column-0 override (25000 USDC)" \
    || bad "accepted-one: payout mismatch (got '$PO', expected '25000 USDC')"
else
  bad "accepted-one row not found in TSV output"
fi

R2="$(row_for "vault-thistle@f00dcafe:owner-only-bypass")"
if [ -n "$R2" ]; then
  OC="$(printf '%s' "$R2" | awk -F'\t' '{print $4}')"
  RS="$(printf '%s' "$R2" | awk -F'\t' '{print $6}')"
  PO="$(printf '%s' "$R2" | awk -F'\t' '{print $5}')"
  [ "$OC" = "rejected" ] && [ "$RS" = "scope-gate" ] && [ -z "$PO" ] \
    && ok "rejected-one: outcome/reason correct, payout empty" \
    || bad "rejected-one: mismatch (outcome=$OC reason=$RS payout='$PO')"
else
  bad "rejected-one row not found in TSV output"
fi

R3="$(row_for "vault-thistle@f00dcafe:reentrant-withdraw")"
if [ -n "$R3" ]; then
  OC="$(printf '%s' "$R3" | awk -F'\t' '{print $4}')"
  RS="$(printf '%s' "$R3" | awk -F'\t' '{print $6}')"
  [ "$OC" = "duplicate" ] && [ "$RS" = "dup-scout" ] \
    && ok "dup-one: outcome/reason correct" \
    || bad "dup-one: mismatch (outcome=$OC reason=$RS)"
else
  bad "dup-one row not found in TSV output"
fi

R4="$(row_for "enzyme-onyx@a1b2c3d:oracle-staleness")"
if [ -n "$R4" ]; then
  OC="$(printf '%s' "$R4" | awk -F'\t' '{print $4}')"
  RS="$(printf '%s' "$R4" | awk -F'\t' '{print $6}')"
  [ "$OC" = "held" ] && [ "$RS" = "rejected/low-confidence" ] \
    && ok "held-one: outcome=held, reason=rejected/low-confidence" \
    || bad "held-one: mismatch (outcome=$OC reason=$RS)"
else
  bad "held-one row not found in TSV output"
fi

R5="$(row_for "enzyme-onyx@a1b2c3d:rounding-drift")"
if [ -n "$R5" ]; then
  OC="$(printf '%s' "$R5" | awk -F'\t' '{print $4}')"
  RS="$(printf '%s' "$R5" | awk -F'\t' '{print $6}')"
  [ "$OC" = "pending" ] && [ -z "$RS" ] \
    && ok "pending-one: outcome=pending, reason empty" \
    || bad "pending-one: mismatch (outcome=$OC reason='$RS')"
else
  bad "pending-one row not found in TSV output"
fi

# AC5 — the no-manifest dir never appears as a row and is not counted.
if printf '%s\n' "$OUT" | grep -q "no-manifest-one"; then
  bad "no-manifest-one leaked into the TSV output (should be silently skipped)"
else
  ok "no-manifest-one silently skipped (no row emitted)"
fi

ROW_COUNT="$(printf '%s\n' "$OUT" | grep -c . || true)"
[ "$ROW_COUNT" -eq 5 ] && ok "exactly 5 TSV rows emitted (no-manifest dir excluded)" \
  || bad "expected 5 TSV rows, got $ROW_COUNT"

# AC2 — the stderr rollup line.
ROLLUP="$(grep '^submission-outcomes.sh: rollup ' "$WORK/stderr1.txt" || true)"
EXPECTED="submission-outcomes.sh: rollup accepted=1 rejected=1 duplicate=1 needs-info=0 out-of-scope=0 held=1 pending=1 total=5"
[ "$ROLLUP" = "$EXPECTED" ] && ok "rollup line matches exactly (accepted=1 rejected=1 duplicate=1 needs-info=0 out-of-scope=0 held=1 pending=1 total=5)" \
  || bad "rollup line mismatch: got '$ROLLUP', expected '$EXPECTED'"

# ----------------------------------------------------------------------------------------------------------
note "2) --summary over an empty drop-dir ..."
EMPTY_DROP="$WORK/empty-drop"
mkdir -p "$EMPTY_DROP"
EMPTY_OUT="$("$AGG" --summary --drop-dir "$EMPTY_DROP" 2>"$WORK/stderr2.txt")"
RC=$?
[ "$RC" -eq 0 ] && ok "empty drop-dir: exits 0" || bad "empty drop-dir: exited $RC (expected 0)"
[ -z "$EMPTY_OUT" ] && ok "empty drop-dir: zero TSV rows" || bad "empty drop-dir: expected no TSV rows, got: $EMPTY_OUT"
EMPTY_ROLLUP="$(grep '^submission-outcomes.sh: rollup ' "$WORK/stderr2.txt" || true)"
EMPTY_EXPECTED="submission-outcomes.sh: rollup accepted=0 rejected=0 duplicate=0 needs-info=0 out-of-scope=0 held=0 pending=0 total=0"
[ "$EMPTY_ROLLUP" = "$EMPTY_EXPECTED" ] && ok "empty drop-dir: rollup line is all-zero" \
  || bad "empty drop-dir: rollup mismatch: got '$EMPTY_ROLLUP', expected '$EMPTY_EXPECTED'"

# ----------------------------------------------------------------------------------------------------------
note "3) missing drop-dir (never created) ..."
MISSING_OUT="$("$AGG" --summary --drop-dir "$WORK/does-not-exist" 2>"$WORK/stderr3.txt")"
RC=$?
[ "$RC" -eq 0 ] && ok "missing drop-dir: exits 0" || bad "missing drop-dir: exited $RC (expected 0)"
[ -z "$MISSING_OUT" ] && ok "missing drop-dir: zero TSV rows" || bad "missing drop-dir: expected no TSV rows"

# ----------------------------------------------------------------------------------------------------------
note "4) bad args: --drop-dir with no value -> exit 2; missing --summary -> exit 2 ..."
"$AGG" --drop-dir >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "--drop-dir with no value exits 2" || bad "--drop-dir with no value exited $RC (expected 2)"

"$AGG" --drop-dir "$DROP" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "missing --summary exits 2" || bad "missing --summary exited $RC (expected 2)"

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "all assertions passed"
  exit 0
else
  note "$FAILS assertion(s) failed"
  exit 1
fi
