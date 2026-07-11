#!/usr/bin/env bash
# demo-watch-competitions.sh — OFFLINE, DETERMINISTIC proof (#1635) of watch-competitions.sh: the audit-
# COMPETITION freshness watcher. No network: canned Sherlock + Cantina fixtures are fed via the --sherlock-from
# / --cantina-from offline hatches, and the Sherlock `ends_at` is computed RELATIVE TO "today" at demo-
# generation time (python3 -c) so the future-ends assertion never rots with the calendar.
#
# Cases, all offline:
#   1. run 1 over the fixtures: a RUNNING Sherlock contest with a future ends_at surfaces (platform:sherlock);
#      a Cantina "active" competition surfaces (cantina:fresh-lending, scope_hint kyc:yes); a JUDGING Sherlock
#      contest is dropped (status), a RUNNING-but-PRE-SEEDED Sherlock contest is dropped (ledger dedup gating a
#      live comp), a private RUNNING Sherlock contest is dropped (not permissionless), and a "complete" Cantina
#      competition is dropped (status). Every emitted row is exactly 5 tab columns; the queue FILE == stdout.
#   2. run 2 over the SAME fixtures + the run-1-updated ledger: zero new rows (both surfaced keys now ledgered)
#      — the first-seen idempotency this tool guards.
#   3. no --*-from + unreachable --sherlock-url/--cantina-url -> [SKIP] + exit 0, with BOTH --out and --ledger
#      byte-for-byte UNTOUCHED (sentinels written before the run, compared after).
#
# Mirrors the other dark-factory demo-*.sh (assert-based PASS/FAIL lines, a trap-cleaned temp dir, exit non-zero
# on failure). Dash-safe: `set -u` only, no pipefail, no `$'...'`, no arrays/[[/mapfile — runs under `sh`.
#
# Usage:  dark-factory/demo-watch-competitions.sh
# Requires: python3 (the watcher's normalizer). Exit: 0 = all assertions held; non-zero = a failure.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WATCHER="$HERE/watch-competitions.sh"

FAILS=0
note() { echo "demo-watch-competitions.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$WATCHER" ] || { note "watch-competitions.sh not found / not executable: $WATCHER" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-watch-competitions.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A future unix timestamp (30 days out) computed relative to "today" so the Sherlock future-ends check never rots.
FUTURE_TS="$(python3 -c 'import datetime; print(int((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=30)).timestamp()))')"

# ----------------------------------------------------------------------------------------------------------
# Sherlock fixture (a `{"items":[...]}` slice of the real contests schema). Designed outcomes:
#   9001 RUNNING, private:false, future ends_at, prize_pool 100000 -> surfaces (platform:sherlock).
#   9002 SHERLOCK_JUDGING                                          -> DROPPED (status not RUNNING).
#   9003 RUNNING but PRE-SEEDED into the ledger before run 1       -> DROPPED (ledger dedup gates a live comp).
#   9004 RUNNING, private:true                                     -> DROPPED (not permissionless).
# ----------------------------------------------------------------------------------------------------------
SHERLOCK="$WORK/demo-sherlock.json"
cat > "$SHERLOCK" <<JSON
{"page":1,"next_page":null,"items":[
  {"id":9001,"slug":"fresh-vault-audit","title":"Fresh Vault Audit","status":"RUNNING","private":false,"ends_at":$FUTURE_TS,"prize_pool":"100000"},
  {"id":9002,"slug":"judging-audit","title":"Judging Audit","status":"SHERLOCK_JUDGING","private":false,"prize_pool":"200000"},
  {"id":9003,"slug":"seeded-audit","title":"Seeded Running Audit","status":"RUNNING","private":false,"ends_at":$FUTURE_TS,"prize_pool":"300000"},
  {"id":9004,"slug":"private-audit","title":"Private Audit","status":"RUNNING","private":true,"ends_at":$FUTURE_TS,"prize_pool":"400000"}
]}
JSON

# ----------------------------------------------------------------------------------------------------------
# Cantina fixture (a bare array). Designed outcomes:
#   uuid-fresh status "active", kycRequired:true, url .../competitions/fresh-lending -> surfaces
#     (cantina:fresh-lending, scope_hint kyc:yes).
#   uuid-done  status "complete"                                                     -> DROPPED (status).
# ----------------------------------------------------------------------------------------------------------
CANTINA="$WORK/demo-cantina.json"
cat > "$CANTINA" <<'JSON'
[
  {"id":"uuid-fresh","name":"Fresh Lending Comp","url":"https://cantina.xyz/competitions/fresh-lending","status":"active","kycRequired":true,"totalRewardPot":"50000"},
  {"id":"uuid-done","name":"Done Comp","url":"https://cantina.xyz/competitions/done","status":"complete","kycRequired":false,"totalRewardPot":"90000"}
]
JSON

LEDGER="$WORK/seen-competitions.txt"
OUT1="$WORK/run1.queue"

# Pre-seed the ledger with sherlock:9003 (a live RUNNING contest) to prove dedup gates even a live comp.
printf 'sherlock:9003\t2020-01-01T00:00:00Z\n' > "$LEDGER"

note "1) run 1 over the Sherlock + Cantina fixtures (live filter + first-seen ledger) ..."
OUT="$("$WATCHER" --sherlock-from "$SHERLOCK" --cantina-from "$CANTINA" --ledger "$LEDGER" --out "$OUT1" 2>/dev/null)"; RC=$?
echo "----- run 1 queue -----"
printf '%s\n' "$OUT" | sed 's/^/    /'
echo "------------------------"
[ "$RC" -eq 0 ] && ok "watch-competitions exits 0 on the offline fixtures" || bad "watcher exited $RC (expected 0)"

KEYS="$(printf '%s\n' "$OUT" | awk -F'\t' 'NF>=2{print $2}')"
has_key() { printf '%s\n' "$KEYS" | grep -qxF "$1"; }
scope_of() { printf '%s\n' "$OUT" | awk -F'\t' -v k="$1" '$2==k{print $5}'; }

# (a) the RUNNING future-ends Sherlock contest surfaces, tagged platform:sherlock.
if has_key sherlock:9001; then
  ok "sherlock:9001 (RUNNING, future ends) surfaces"
  case "$(scope_of sherlock:9001)" in
    *"platform:sherlock"*) ok "sherlock:9001 scope_hint carries platform:sherlock";;
    *) bad "sherlock:9001 scope_hint missing platform:sherlock: [$(scope_of sherlock:9001)]";;
  esac
else
  bad "sherlock:9001 did not surface in run 1"
fi

# (b) the Cantina active competition surfaces via its url-slug key, tagged kyc:yes.
if has_key cantina:fresh-lending; then
  ok "cantina:fresh-lending (status active) surfaces via its url-slug key"
  case "$(scope_of cantina:fresh-lending)" in
    *"kyc:yes"*) ok "cantina:fresh-lending scope_hint carries kyc:yes";;
    *) bad "cantina:fresh-lending scope_hint missing kyc:yes: [$(scope_of cantina:fresh-lending)]";;
  esac
else
  bad "cantina:fresh-lending did not surface in run 1"
fi

# Absence assertions: the live filter + ledger dedup gate the JUDGING, pre-seeded-RUNNING, private, and
# complete competitions — each carrying a bigger prize than the surfaced ones, a strong absence proof.
for k in sherlock:9002 sherlock:9003 sherlock:9004 cantina:done; do
  if has_key "$k"; then bad "filter FAILED: '$k' should have been dropped but is in the queue"; fi
done
has_key sherlock:9002 || ok "a SHERLOCK_JUDGING contest is dropped (status) despite a \$200k prize"
has_key sherlock:9003 || ok "a RUNNING-but-pre-seeded contest is dropped (ledger dedup gates a live comp)"
has_key sherlock:9004 || ok "a private:true RUNNING contest is dropped (not permissionless)"
has_key cantina:done  || ok "a status:complete Cantina competition is dropped"

# The emit is a clean 5-column TSV (run-batch.sh reads exactly `_score key url title scope`).
if [ -n "$OUT" ] && printf '%s\n' "$OUT" | awk -F'\t' 'NF!=5{exit 1}'; then
  ok "every emitted row is a 5-column TSV (matches run-batch.sh's IFS read)"
else
  bad "a row is not exactly 5 tab-separated columns"
fi

# The queue FILE equals the stdout view (the tool writes both).
if [ "$(cat "$OUT1" 2>/dev/null)" = "$OUT" ]; then
  ok "the queue file equals the stdout view"
else
  bad "the queue file differs from stdout"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) idempotency: run 2 over the SAME fixtures + the run-1-updated ledger -> zero new rows (both surfaced
#     keys are now ledgered). A competition surfaces ONCE (first-seen), then dedups.
# ----------------------------------------------------------------------------------------------------------
note "2) run 2 over the same fixtures + updated ledger: first-seen idempotency ..."
OUT2="$WORK/run2.queue"
OUT_R2="$("$WATCHER" --sherlock-from "$SHERLOCK" --cantina-from "$CANTINA" --ledger "$LEDGER" --out "$OUT2" 2>/dev/null)"; RC=$?
echo "----- run 2 queue -----"
printf '%s\n' "$OUT_R2" | sed 's/^/    /'
echo "------------------------"
[ "$RC" -eq 0 ] && ok "run 2 exits 0" || bad "run 2 exited $RC (expected 0)"
if [ -z "$OUT_R2" ]; then
  ok "run 2 emits zero new rows (both first-seen keys now ledgered — idempotent)"
else
  bad "run 2 emitted rows (ledger dedup regressed): [$OUT_R2]"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) no --*-from + unreachable urls -> a clean [SKIP] + exit 0, with BOTH --out and --ledger byte-for-byte
#     UNTOUCHED. Sentinels are written first so "untouched" is a hard assertion.
# ----------------------------------------------------------------------------------------------------------
note "3) no --*-from + unreachable urls degrade cleanly (offline [SKIP], ledger+queue untouched) ..."
SKIP_OUT="$WORK/skip.queue"
SKIP_LEDGER="$WORK/skip-ledger.txt"
OUT_SENTINEL="sentinel-queue-must-not-be-touched"
LEDGER_SENTINEL="sentinel-ledger-must-not-be-touched"
printf '%s\n' "$OUT_SENTINEL" > "$SKIP_OUT"
printf '%s\n' "$LEDGER_SENTINEL" > "$SKIP_LEDGER"
ERRF="$WORK/skip.err"
"$WATCHER" --sherlock-url "https://nonexistent-example.example.invalid/contests" \
  --cantina-url "https://nonexistent-example.example.invalid/competitions" \
  --ledger "$SKIP_LEDGER" --out "$SKIP_OUT" >/dev/null 2>"$ERRF"; RC=$?
[ "$RC" -eq 0 ] && ok "no --*-from + unreachable urls exits 0 (clean degradation, not an error)" || bad "unreachable path exited $RC (expected 0)"
if grep -q '\[SKIP\]' "$ERRF"; then ok "a [SKIP] line is emitted on stderr"; else bad "no [SKIP] line on the unreachable path"; fi
if [ "$(cat "$SKIP_OUT" 2>/dev/null)" = "$OUT_SENTINEL" ]; then
  ok "the --out queue file is UNTOUCHED on the SKIP"
else
  bad "the --out queue file was modified on the SKIP path"
fi
if [ "$(cat "$SKIP_LEDGER" 2>/dev/null)" = "$LEDGER_SENTINEL" ]; then
  ok "the --ledger file is UNTOUCHED on the SKIP"
else
  bad "the --ledger file was modified on the SKIP path"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: a RUNNING future-ends Sherlock contest and an active Cantina competition surfaced (the latter"
  note "      tagged kyc:yes), while a JUDGING contest, a RUNNING-but-pre-seeded contest, a private contest,"
  note "      and a complete competition were each dropped; a second run over the same fixtures + updated"
  note "      ledger emitted zero new rows (first-seen idempotency); and a no-fixtures + unreachable-urls run"
  note "      degraded to a clean [SKIP] + exit 0 with both the queue and the ledger byte-for-byte untouched."
  note "      Offline + deterministic; never touches a real endpoint, never submits."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
