#!/usr/bin/env bash
# demo-watch-competitions.sh — OFFLINE, DETERMINISTIC proof (#1635, #1643) of watch-competitions.sh: the audit-
# COMPETITION freshness watcher. No network: canned Sherlock + Cantina + CodeHawks fixtures are fed via the
# --sherlock-from / --cantina-from / --codehawks-from offline hatches, and every date-dependent field is
# computed RELATIVE TO "today" at demo-generation time (python3) so the phase assertions never rot with the
# calendar.
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
#   4. CodeHawks channel (#1643): a canned `data-sveltekit-fetched` tRPC-embed fixture -> an in-window
#      permissionless contest surfaces (codehawks:<slug>, platform:codehawks, kyc:no, github scope repo, raw
#      reward+currency prize label), while upcoming / judging-with-future-appeal / finalised / invite-only
#      contests are each dropped by the date-derived submissions-open filter; re-run is idempotent; a garbage
#      HTML file degrades without crashing.
#   5. three-channel coexistence: one invocation over all three --*-from fixtures emits a single 5-column queue
#      with sherlock + cantina + codehawks keys; and a malformed CodeHawks block never suppresses the healthy
#      Sherlock/Cantina channels (graceful degrade).
#
# NOTE: cases 1-3 are byte-identical to the #1635 proof — the untouched Sherlock/Cantina assertions are the
# zero-regression guard that adding the CodeHawks channel did not perturb the existing behavior.
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
# All three live URLs point at an unreachable host so the run is a deterministic offline [SKIP] (no live curl)
# — the CodeHawks channel (#1643) is included here so the three-way "no usable input" SKIP is exercised.
"$WATCHER" --sherlock-url "https://nonexistent-example.example.invalid/contests" \
  --cantina-url "https://nonexistent-example.example.invalid/competitions" \
  --codehawks-url "https://nonexistent-example.example.invalid/contests" \
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

# ----------------------------------------------------------------------------------------------------------
# 4) CodeHawks channel (#1643): a canned `data-sveltekit-fetched` tRPC embed fixture, dates RELATIVE to "today"
#    so the phase assertions never rot. The Sherlock/Cantina inputs are /dev/null (readable + empty -> no
#    network, no records) so this exercises the CodeHawks channel in isolation. Designed outcomes:
#      2099-demo-open-defi   start today-2, end today+5, currency usdc      -> OPEN, surfaces.
#      2099-demo-upcoming    start today+3 (far-future end)                 -> DROPPED (upcoming).
#      2099-demo-judging     end today-2, appealEndDate today+5, !finalised-> DROPPED (judging/appeals — the
#                                                                             key regression: a future appeal
#                                                                             window must NOT keep it open).
#      2099-demo-ended       finalised:true                                -> DROPPED (ended).
#      2099-demo-invite      open dates but inviteOnly:true                -> DROPPED (not permissionless).
# ----------------------------------------------------------------------------------------------------------
build_codehawks_fixture() {
  python3 - "$1" <<'PY'
import sys, json, datetime
out = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)


def iso(days):
    return (now + datetime.timedelta(days=days)).strftime("%Y-%m-%dT12:00:00.000Z")


contests = [
    {"urlSlug": "2099-demo-open-defi", "name": "Demo Open DeFi Vault", "company": "DemoCorp",
     "githubUrl": "https://github.com/CodeHawks-Contests/2099-demo-open-defi",
     "reward": 20000, "currency": "usdc", "startDate": iso(-2), "endDate": iso(5),
     "appealEndDate": None, "finalised": False, "inviteOnly": False, "requiresKyc": False},
    {"urlSlug": "2099-demo-upcoming", "name": "Demo Upcoming", "company": "DemoCorp",
     "githubUrl": "https://github.com/CodeHawks-Contests/2099-demo-upcoming",
     "reward": 15000, "currency": "usdc", "startDate": iso(3), "endDate": iso(10),
     "appealEndDate": None, "finalised": False, "inviteOnly": False, "requiresKyc": False},
    {"urlSlug": "2099-demo-judging", "name": "Demo Judging", "company": "DemoCorp",
     "githubUrl": "https://github.com/CodeHawks-Contests/2099-demo-judging",
     "reward": 30000, "currency": "usdc", "startDate": iso(-10), "endDate": iso(-2),
     "appealEndDate": iso(5), "finalised": False, "inviteOnly": False, "requiresKyc": False},
    {"urlSlug": "2099-demo-ended", "name": "Demo Ended", "company": "DemoCorp",
     "githubUrl": "https://github.com/CodeHawks-Contests/2099-demo-ended",
     "reward": 40000, "currency": "usdc", "startDate": iso(-20), "endDate": iso(-10),
     "appealEndDate": iso(-5), "finalised": True, "inviteOnly": False, "requiresKyc": False},
    {"urlSlug": "2099-demo-invite", "name": "Demo Invite Only", "company": "DemoCorp",
     "githubUrl": "https://github.com/CodeHawks-Contests/2099-demo-invite",
     "reward": 50000, "currency": "usdc", "startDate": iso(-2), "endDate": iso(5),
     "appealEndDate": None, "finalised": False, "inviteOnly": True, "requiresKyc": False},
]
body = json.dumps([{"result": {"data": contests}}])
outer = json.dumps({"status": 200, "statusText": "", "headers": {}, "body": body})
html = (
    "<!doctype html><html><head><title>Contests</title></head><body>\n"
    "<script type=\"application/json\" data-sveltekit-fetched "
    "data-url=\"/trpc/competitions.getCompetitions?batch=1&amp;input=%7B%7D\" data-hash=\"demo\">"
    + outer +
    "</script>\n</body></html>\n"
)
with open(out, "w", encoding="utf-8") as fh:
    fh.write(html)
PY
}

note "4) CodeHawks channel: keyless HTML-embed fixture, date-derived submissions-open filter ..."
CODEHAWKS="$WORK/demo-codehawks.html"
build_codehawks_fixture "$CODEHAWKS"
CH_LEDGER="$WORK/ch-ledger.txt"
CH_OUT="$WORK/ch.queue"
OUT_CH="$("$WATCHER" --codehawks-from "$CODEHAWKS" --sherlock-from /dev/null --cantina-from /dev/null --ledger "$CH_LEDGER" --out "$CH_OUT" 2>/dev/null)"; RC=$?
echo "----- codehawks queue -----"
printf '%s\n' "$OUT_CH" | sed 's/^/    /'
echo "---------------------------"
[ "$RC" -eq 0 ] && ok "codehawks-only run exits 0" || bad "codehawks-only run exited $RC (expected 0)"

CH_KEYS="$(printf '%s\n' "$OUT_CH" | awk -F'\t' 'NF>=2{print $2}')"
ch_has_key() { printf '%s\n' "$CH_KEYS" | grep -qxF "$1"; }
ch_scope_of() { printf '%s\n' "$OUT_CH" | awk -F'\t' -v k="$1" '$2==k{print $5}'; }

# (a) the in-window, permissionless contest surfaces, carrying platform:codehawks / kyc:no / its github repo.
if ch_has_key codehawks:2099-demo-open-defi; then
  ok "codehawks:2099-demo-open-defi (open window) surfaces"
  case "$(ch_scope_of codehawks:2099-demo-open-defi)" in
    *"platform:codehawks"*) ok "scope_hint carries platform:codehawks";;
    *) bad "scope_hint missing platform:codehawks: [$(ch_scope_of codehawks:2099-demo-open-defi)]";;
  esac
  case "$(ch_scope_of codehawks:2099-demo-open-defi)" in
    *"kyc:no"*) ok "scope_hint carries kyc:no";;
    *) bad "scope_hint missing kyc:no: [$(ch_scope_of codehawks:2099-demo-open-defi)]";;
  esac
  case "$(ch_scope_of codehawks:2099-demo-open-defi)" in
    *"repo:https://github.com/CodeHawks-Contests/2099-demo-open-defi"*) ok "scope_hint carries the githubUrl scope repo";;
    *) bad "scope_hint missing the github repo: [$(ch_scope_of codehawks:2099-demo-open-defi)]";;
  esac
  case "$(ch_scope_of codehawks:2099-demo-open-defi)" in
    *"prize:20000usdc"*) ok "scope_hint carries the raw reward+currency label (prize:20000usdc)";;
    *) bad "scope_hint missing prize_label: [$(ch_scope_of codehawks:2099-demo-open-defi)]";;
  esac
else
  bad "codehawks:2099-demo-open-defi did not surface"
fi

# (b) date-derived drops: upcoming, judging-with-future-appeal, finalised, invite-only.
for k in codehawks:2099-demo-upcoming codehawks:2099-demo-judging codehawks:2099-demo-ended codehawks:2099-demo-invite; do
  if ch_has_key "$k"; then bad "filter FAILED: '$k' should have been dropped but is in the queue"; fi
done
ch_has_key codehawks:2099-demo-upcoming || ok "an upcoming contest (today<startDate) is dropped despite a far-future endDate"
ch_has_key codehawks:2099-demo-judging  || ok "a past-endDate contest with a FUTURE appealEndDate is dropped (judging/appeals — key regression)"
ch_has_key codehawks:2099-demo-ended    || ok "a finalised:true contest is dropped (ended)"
ch_has_key codehawks:2099-demo-invite   || ok "an inviteOnly:true contest is dropped (not permissionless)"

# (c) idempotency: run 2 over the same fixture + updated ledger -> zero new rows.
OUT_CH2="$("$WATCHER" --codehawks-from "$CODEHAWKS" --sherlock-from /dev/null --cantina-from /dev/null --ledger "$CH_LEDGER" --out "$WORK/ch2.queue" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "codehawks run 2 exits 0" || bad "codehawks run 2 exited $RC (expected 0)"
if [ -z "$OUT_CH2" ]; then
  ok "codehawks run 2 emits zero new rows (first-seen key now ledgered — idempotent)"
else
  bad "codehawks run 2 emitted rows (ledger dedup regressed): [$OUT_CH2]"
fi

# (d) a garbage HTML file (no embed block) contributes nothing and never crashes.
GARBAGE="$WORK/garbage.html"
printf '<html><body><p>no sveltekit embed here</p></body></html>\n' > "$GARBAGE"
"$WATCHER" --codehawks-from "$GARBAGE" --sherlock-from /dev/null --cantina-from /dev/null --ledger "$WORK/g-ledger.txt" --out "$WORK/g.queue" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "a garbage CodeHawks HTML file degrades cleanly (exit 0, no crash)" || bad "garbage CodeHawks HTML exited $RC (expected 0)"

# ----------------------------------------------------------------------------------------------------------
# 5) three-channel coexistence: one invocation with all of --sherlock-from / --cantina-from / --codehawks-from
#    over a FRESH ledger -> all three channels emit into one queue, every row exactly 5 tab columns; and a
#    MALFORMED CodeHawks block does NOT suppress the healthy Sherlock/Cantina channels (graceful degrade).
# ----------------------------------------------------------------------------------------------------------
note "5) three-channel coexistence + CodeHawks graceful degrade ..."
COMBO_LEDGER="$WORK/combo-ledger.txt"
COMBO_OUT="$WORK/combo.queue"
OUT_COMBO="$("$WATCHER" --sherlock-from "$SHERLOCK" --cantina-from "$CANTINA" --codehawks-from "$CODEHAWKS" --ledger "$COMBO_LEDGER" --out "$COMBO_OUT" 2>/dev/null)"; RC=$?
echo "----- combined queue -----"
printf '%s\n' "$OUT_COMBO" | sed 's/^/    /'
echo "--------------------------"
[ "$RC" -eq 0 ] && ok "combined three-channel run exits 0" || bad "combined run exited $RC (expected 0)"
CB_KEYS="$(printf '%s\n' "$OUT_COMBO" | awk -F'\t' 'NF>=2{print $2}')"
cb_has() { printf '%s\n' "$CB_KEYS" | grep -qxF "$1"; }
if cb_has sherlock:9001 && cb_has cantina:fresh-lending && cb_has codehawks:2099-demo-open-defi; then
  ok "all three channels coexist in one queue (sherlock + cantina + codehawks keys present)"
else
  bad "a channel is missing from the combined queue: [$CB_KEYS]"
fi
if [ -n "$OUT_COMBO" ] && printf '%s\n' "$OUT_COMBO" | awk -F'\t' 'NF!=5{exit 1}'; then
  ok "every combined row is a 5-column TSV (matches run-batch.sh's IFS read)"
else
  bad "a combined row is not exactly 5 tab-separated columns"
fi

# graceful degrade: a malformed CodeHawks block over the SAME fresh ledger (fresh out) must still emit the
# Sherlock + Cantina contests — a CodeHawks parse break never suppresses a healthy platform.
DEG_OUT="$("$WATCHER" --sherlock-from "$SHERLOCK" --cantina-from "$CANTINA" --codehawks-from "$GARBAGE" --ledger "$WORK/deg-ledger.txt" --out "$WORK/deg.queue" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "malformed-CodeHawks combined run exits 0" || bad "malformed-CodeHawks run exited $RC (expected 0)"
DEG_KEYS="$(printf '%s\n' "$DEG_OUT" | awk -F'\t' 'NF>=2{print $2}')"
deg_has() { printf '%s\n' "$DEG_KEYS" | grep -qxF "$1"; }
if deg_has sherlock:9001 && deg_has cantina:fresh-lending; then
  ok "a malformed CodeHawks block does NOT suppress the Sherlock/Cantina channels (graceful degrade)"
else
  bad "the Sherlock/Cantina channels were suppressed by a CodeHawks parse failure: [$DEG_KEYS]"
fi
if deg_has codehawks:2099-demo-open-defi; then
  bad "a malformed CodeHawks block should contribute ZERO records, but a codehawks key appeared"
else
  ok "a malformed CodeHawks block contributes zero records"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: a RUNNING future-ends Sherlock contest and an active Cantina competition surfaced (the latter"
  note "      tagged kyc:yes), while a JUDGING contest, a RUNNING-but-pre-seeded contest, a private contest,"
  note "      and a complete competition were each dropped; a second run over the same fixtures + updated"
  note "      ledger emitted zero new rows (first-seen idempotency); and a no-fixtures + unreachable-urls run"
  note "      degraded to a clean [SKIP] + exit 0 with both the queue and the ledger byte-for-byte untouched."
  note "      The CodeHawks channel (#1643) surfaced an in-window permissionless contest (platform:codehawks,"
  note "      kyc:no, github scope repo, raw reward+currency prize label) while dropping upcoming / judging-"
  note "      with-future-appeal / finalised / invite-only contests via the date-derived filter, was idempotent"
  note "      over a re-run, degraded on garbage HTML without crashing, coexisted with Sherlock+Cantina in one"
  note "      5-column queue, and never suppressed the healthy channels on a CodeHawks parse failure."
  note "      Offline + deterministic; never touches a real endpoint, never submits."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
