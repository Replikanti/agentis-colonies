#!/usr/bin/env bash
# demo-watch-new-listings.sh — OFFLINE, DETERMINISTIC proof (#1623) of watch-new-listings.sh: the freshness-first
# new-listing watcher. No network: a canned bounties.json fixture is fed via the --bounties offline hatch, and
# the fixture's launchDate values are computed RELATIVE TO "today" at demo-generation time (python3 -c) so the
# window-vs-stale assertions never rot with the calendar.
#
# Six cases, all offline:
#   1. run 1 over the fixture: a launch-window-fresh program (pre-seeded into the ledger, so it surfaces via
#      window ONLY, not also new — keeps case (a) unambiguous) surfaces tagged reason:window; a stale-AND-
#      pre-seeded program is dropped (case b, both criteria fail); a stale-but-NOT-pre-seeded program surfaces
#      via first-seen despite its old launchDate, tagged reason:new-listing (case c); the duplicated survivor
#      filter still gates a non-EVM / inviteOnly / below-floor / past-endDate row each (absence assertions).
#   2. run 2 over the SAME fixture + SAME ledger: the ledger-only new-old-date program is now ABSENT — the
#      idempotency this tool actually guards (case d). The launch-window program is deliberately NOT asserted
#      absent on run 2: it is expected to legitimately re-surface every run while still inside the freshness
#      window (the intended signal, not a dedup bug) — asserting it away would be wrong.
#   3. no --bounties + an unreachable --url -> [SKIP] + exit 0, with BOTH --out and --ledger byte-for-byte
#      UNTOUCHED (sentinels written before the run, compared after).
#
# Mirrors the other dark-factory demo-*.sh (assert-based PASS/FAIL lines, a trap-cleaned temp dir, exit non-zero
# on failure). Dash-safe: `set -u` only, no pipefail, no `$'...'`, no arrays/[[/mapfile — runs under `sh`.
#
# Usage:  dark-factory/demo-watch-new-listings.sh
# Requires: python3 (the watcher's floor). Exit: 0 = all assertions held; non-zero = a failure.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WATCHER="$HERE/watch-new-listings.sh"

FAILS=0
note() { echo "demo-watch-new-listings.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$WATCHER" ] || { note "watch-new-listings.sh not found / not executable: $WATCHER" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-watch-new-listings.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Dates computed relative to "today" at demo-generation time so the window-vs-stale assertions never rot.
FRESH_DATE="$(python3 -c 'import datetime; print((datetime.date.today()-datetime.timedelta(days=3)).isoformat())')"
STALE_DATE="$(python3 -c 'import datetime; print((datetime.date.today()-datetime.timedelta(days=200)).isoformat())')"
PAST_DATE="$(python3 -c 'import datetime; print((datetime.date.today()-datetime.timedelta(days=5)).isoformat())')"

# ----------------------------------------------------------------------------------------------------------
# Fixture (a tiny slice of the real bounties.json schema). Designed outcomes:
#   fresh-window   : Solidity/ethereum, $500k, launchDate 3 days ago -> surfaces via the launch-window
#                    criterion; pre-seeded into the ledger BEFORE run 1 so it is NOT also "new" (keeps case a
#                    unambiguous: reason:window, never reason:both).
#   stale-seeded   : Solidity/ethereum, $500k, launchDate 200 days ago; pre-seeded into the ledger BEFORE run 1
#                    -> DROPPED (both criteria fail: outside the window, already ledgered).
#   new-old-date   : Solidity/ethereum, $500k, launchDate 200 days ago; NOT pre-seeded -> surfaces via the
#                    first-seen criterion despite the stale launchDate, tagged reason:new-listing.
#   sol-prog       : Rust/solana, $9M -> DROPPED (not EVM), despite the biggest reward in the fixture.
#   invite         : Solidity/ethereum, $5M, inviteOnly:true -> DROPPED.
#   low            : Solidity/ethereum, $5k (below --floor 10000) -> DROPPED.
#   past           : Solidity/ethereum, $3M, endDate 5 days ago -> DROPPED (out of window).
# ----------------------------------------------------------------------------------------------------------
BOUNTIES="$WORK/bounties.json"
cat > "$BOUNTIES" <<JSON
[
  {"slug":"fresh-window","project":"Fresh Vault","language":["Solidity"],"ecosystem":["Ethereum"],"maxBounty":500000,"launchDate":"$FRESH_DATE"},
  {"slug":"stale-seeded","project":"Stale Seeded Vault","language":["Solidity"],"ecosystem":["Ethereum"],"maxBounty":500000,"launchDate":"$STALE_DATE"},
  {"slug":"new-old-date","project":"Old-Date New Vault","language":["Solidity"],"ecosystem":["Ethereum"],"maxBounty":500000,"launchDate":"$STALE_DATE"},
  {"slug":"sol-prog","project":"Solana Vault","language":["Rust"],"ecosystem":["Solana"],"maxBounty":9000000},
  {"slug":"invite","project":"Secret Vault","language":["Solidity"],"ecosystem":["Ethereum"],"maxBounty":5000000,"inviteOnly":true},
  {"slug":"low","project":"Tiny Vault","language":["Solidity"],"ecosystem":["Ethereum"],"maxBounty":5000},
  {"slug":"past","project":"Old Closed Vault","language":["Solidity"],"ecosystem":["Ethereum"],"maxBounty":3000000,"endDate":"$PAST_DATE"}
]
JSON

LEDGER="$WORK/seen-listings.txt"
OUT1="$WORK/run1.queue"

# Pre-seed the ledger with fresh-window (keeps case a unambiguous: window-only, not also new) and stale-seeded
# (so case b fails BOTH criteria, not just the window one).
printf 'immunefi:fresh-window\t2020-01-01T00:00:00Z\n' > "$LEDGER"
printf 'immunefi:stale-seeded\t2020-01-01T00:00:00Z\n' >> "$LEDGER"

note "1) run 1 over the fixture (window-fresh, ledger-fresh, and the duplicated survivor filter) ..."
OUT="$("$WATCHER" --bounties "$BOUNTIES" --ledger "$LEDGER" --out "$OUT1" 2>/dev/null)"; RC=$?
echo "----- run 1 queue -----"
printf '%s\n' "$OUT" | sed 's/^/    /'
echo "------------------------"
[ "$RC" -eq 0 ] && ok "watch-new-listings exits 0 on the offline --bounties fixture" || bad "watcher exited $RC (expected 0)"

KEYS="$(printf '%s\n' "$OUT" | awk -F'\t' 'NF>=2{print $2}')"
has_key() { printf '%s\n' "$KEYS" | grep -qxF "$1"; }
scope_of() { printf '%s\n' "$OUT" | awk -F'\t' -v k="$1" '$2==k{print $5}'; }

# (a) fresh-window surfaces, tagged reason:window (pre-seeded, so never reason:both — unambiguous).
if has_key immunefi:fresh-window; then
  ok "fresh-window (launch 3 days ago) surfaces"
  case "$(scope_of immunefi:fresh-window)" in
    *"reason:window"*) ok "fresh-window is tagged reason:window";;
    *) bad "fresh-window scope_hint missing reason:window: [$(scope_of immunefi:fresh-window)]";;
  esac
else
  bad "fresh-window did not surface in run 1"
fi

# (b) stale-seeded is ABSENT (out of window AND already ledgered).
if has_key immunefi:stale-seeded; then
  bad "stale-seeded surfaced but should have been dropped (out of window + already ledgered)"
else
  ok "stale-seeded (launch 200 days ago, pre-seeded) is dropped"
fi

# (c) new-old-date surfaces via first-seen despite its 200-day-old launchDate, tagged reason:new-listing.
if has_key immunefi:new-old-date; then
  ok "new-old-date (launch 200 days ago, NOT pre-seeded) surfaces via first-seen"
  case "$(scope_of immunefi:new-old-date)" in
    *"reason:new-listing"*) ok "new-old-date is tagged reason:new-listing";;
    *) bad "new-old-date scope_hint missing reason:new-listing: [$(scope_of immunefi:new-old-date)]";;
  esac
else
  bad "new-old-date did not surface in run 1"
fi

# Absence assertions: the duplicated survivor filter still gates non-EVM / inviteOnly / below-floor / past-
# endDate rows, each carrying a bigger reward than the surfaced ones — a strong absence proof.
for k in immunefi:sol-prog immunefi:invite immunefi:low immunefi:past; do
  if has_key "$k"; then bad "filter FAILED: '$k' should have been dropped but is in the queue"; fi
done
has_key immunefi:sol-prog || ok "a Solana/Rust program is dropped (not EVM) despite a \$9M reward"
has_key immunefi:invite   || ok "an inviteOnly:true program is dropped despite a \$5M reward"
has_key immunefi:low      || ok "a below-floor program (\$5k < floor 10000) is dropped"
has_key immunefi:past     || ok "a past-endDate program is dropped despite a \$3M reward"

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
# (d) idempotency: run 2 over the SAME fixture + SAME (now run-1-updated) ledger -> new-old-date is now ABSENT
#     (the ledger-only mechanism this tool actually guards against duplicate detections). fresh-window is NOT
#     asserted absent here: it legitimately re-surfaces every run while still inside its freshness window —
#     that is the intended signal, not a dedup bug a future editor should "fix".
# ----------------------------------------------------------------------------------------------------------
note "2) run 2 over the same fixture + ledger: idempotency on the ledger-only signal ..."
OUT2="$WORK/run2.queue"
OUT_R2="$("$WATCHER" --bounties "$BOUNTIES" --ledger "$LEDGER" --out "$OUT2" 2>/dev/null)"; RC=$?
echo "----- run 2 queue -----"
printf '%s\n' "$OUT_R2" | sed 's/^/    /'
echo "------------------------"
[ "$RC" -eq 0 ] && ok "run 2 exits 0" || bad "run 2 exited $RC (expected 0)"
KEYS_R2="$(printf '%s\n' "$OUT_R2" | awk -F'\t' 'NF>=2{print $2}')"
if printf '%s\n' "$KEYS_R2" | grep -qxF immunefi:new-old-date; then
  bad "new-old-date resurfaced on run 2 (ledger dedup regressed — this is what makes the signal idempotent)"
else
  ok "new-old-date is absent on run 2 (ledger dedup holds — idempotent on the first-seen signal)"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) no --bounties + an unreachable --url -> a clean [SKIP] + exit 0, with BOTH --out and --ledger
#     byte-for-byte UNTOUCHED. Sentinels are written first so "untouched" is a hard assertion.
# ----------------------------------------------------------------------------------------------------------
note "3) no --bounties + an unreachable --url degrades cleanly (offline [SKIP], ledger+queue untouched) ..."
SKIP_OUT="$WORK/skip.queue"
SKIP_LEDGER="$WORK/skip-ledger.txt"
OUT_SENTINEL="sentinel-queue-must-not-be-touched"
LEDGER_SENTINEL="sentinel-ledger-must-not-be-touched"
printf '%s\n' "$OUT_SENTINEL" > "$SKIP_OUT"
printf '%s\n' "$LEDGER_SENTINEL" > "$SKIP_LEDGER"
ERRF="$WORK/skip.err"
"$WATCHER" --url "https://nonexistent-example.example.invalid/bounties.json" \
  --ledger "$SKIP_LEDGER" --out "$SKIP_OUT" >/dev/null 2>"$ERRF"; RC=$?
[ "$RC" -eq 0 ] && ok "no --bounties + unreachable --url exits 0 (clean degradation, not an error)" || bad "unreachable path exited $RC (expected 0)"
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
  note "PASS: a launch-window-fresh program surfaced (reason:window), a stale+pre-seeded program was dropped,"
  note "      a stale-but-unseeded program surfaced via first-seen (reason:new-listing) despite its old"
  note "      launchDate, the duplicated survivor filter still gated non-EVM/inviteOnly/below-floor/past-endDate"
  note "      rows, a second run over the same ledger dropped the now-seen first-seen program (idempotent) while"
  note "      the still-in-window program legitimately kept re-surfacing, and an unreachable/no-bounties run"
  note "      degraded to a clean [SKIP] + exit 0 with both the queue and the ledger byte-for-byte untouched."
  note "      Offline + deterministic; never touches a real endpoint, never submits."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
