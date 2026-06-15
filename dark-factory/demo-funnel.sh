#!/usr/bin/env bash
# demo-funnel.sh — OFFLINE, DETERMINISTIC proof of the #1054 target-intake funnel: a fixture candidate list is
# fed to run-funnel.sh via --from (NO network) and the FRESHNESS -> SELF-DEDUP -> SCORE -> ranked-queue
# transform is asserted end to end. Mirrors the other dark-factory demo-*.sh (assert-based, PASS/FAIL lines,
# temp dirs trap-cleaned, exit non-zero on any failure).
#
# The fixture is built so the score ordering is NON-TRIVIAL (varying launched_at recency + prize so the rank
# is not just input order), and it exercises every drop path:
#   - one candidate whose status is NOT RUNNING (a closed window)            -> must be absent (freshness)
#   - one candidate whose key platform:id is pre-seeded in a temp ledger     -> must be absent (self-dedup)
#   - four RUNNING, un-seen candidates with deliberately different scores     -> ranked by score DESC
#
# Asserts: (a) the queue is ranked by score descending; (b) the non-RUNNING candidate is absent; (c) the
# ledger-seen candidate is absent; (d) run-funnel.sh exits 0. DARK_FACTORY_DIR points at a temp dir so the
# real ledger/queue are never touched. No network, no LLM — a pure transform over the fixture JSON.
#
# Usage:  dark-factory/demo-funnel.sh
# Requires: python3 (same floor as run-funnel.sh). Exit: 0 = all assertions held; non-zero = a failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FUNNEL="$HERE/run-funnel.sh"

FAILS=0
note() { echo "demo-funnel.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$FUNNEL" ] || { note "run-funnel.sh not found / not executable: $FUNNEL" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-funnel.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DFD="$WORK/dark-factory"   # the temp DARK_FACTORY_DIR (ledger + queue live here, never the real ~/.dark-factory)
mkdir -p "$DFD"

# Deterministic-but-relative launched_at hints so the recency lever produces a NON-TRIVIAL, stable ordering
# regardless of the wall-clock day the demo runs. d0 = today (freshest), d18 = mid, d28 = nearly-closed window.
iso_days_ago() { python3 -c 'import sys,datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=int(sys.argv[1]))).strftime("%Y-%m-%d"))' "$1"; }
D0="$(iso_days_ago 0)"
D18="$(iso_days_ago 18)"
D28="$(iso_days_ago 28)"

# The fixture candidate list. Designed scores (recency + prize + platform + scope, see run-funnel.sh SCORING):
#   top      : today + $5M + contest + 1 contract  -> HIGHEST (recency 40, prize ~22, plat 20, scope ~14)
#   mid      : today + $5M + permanent + 1 contract -> below top (permanent platform lever 8 vs 20)
#   low      : d18  + $50k + contest + 4 contracts  -> low recency + small prize + larger scope
#   floor    : d28  + $0   + contest + 8 contracts  -> LOWEST of the survivors (near-closed, no prize)
#   closed   : today + $9M + contest, status FINISHED -> DROPPED by freshness (would top the queue if kept)
#   seen     : today + $8M + contest, RUNNING, key pre-seeded in the ledger -> DROPPED by self-dedup
# The two dropped candidates carry the BIGGEST prizes on purpose: if either leaked through it would sit at the
# very top of the ranked queue, so its mere absence is a strong assertion that the filter fired.
CANDS="$WORK/cands.json"
cat > "$CANDS" <<JSON
[
  {"platform":"sherlock","id":"top","title":"Fresh fat contest","url":"https://audits.example/top","scope_hint":"Vault.sol","prize_hint":"\$5,000,000","launched_at":"$D0","status":"RUNNING","kind":"contest"},
  {"platform":"immunefi","id":"mid","title":"Permanent bounty","url":"https://audits.example/mid","scope_hint":"Vault.sol","prize_hint":"\$5,000,000","launched_at":"$D0","status":"RUNNING","kind":"permanent"},
  {"platform":"sherlock","id":"low","title":"Older small contest","url":"https://audits.example/low","scope_hint":"A.sol, B.sol, C.sol, D.sol","prize_hint":"\$50,000","launched_at":"$D18","status":"RUNNING","kind":"contest"},
  {"platform":"sherlock","id":"floor","title":"Nearly-closed wide contest","url":"https://audits.example/floor","scope_hint":"A.sol, B.sol, C.sol, D.sol, E.sol, F.sol, G.sol, H.sol","prize_hint":"","launched_at":"$D28","status":"RUNNING","kind":"contest"},
  {"platform":"sherlock","id":"closed","title":"Closed contest","url":"https://audits.example/closed","scope_hint":"Vault.sol","prize_hint":"\$9,000,000","launched_at":"$D0","status":"FINISHED","kind":"contest"},
  {"platform":"sherlock","id":"seen","title":"Already-processed contest","url":"https://audits.example/seen","scope_hint":"Vault.sol","prize_hint":"\$8,000,000","launched_at":"$D0","status":"RUNNING","kind":"contest"}
]
JSON

# Pre-seed the ledger with the "seen" candidate's key (the #1055 batch-runner row shape: key<TAB>verdict<TAB>ts).
printf 'sherlock:seen\trefuted\t2026-06-01T00:00:00Z\n' > "$DFD/funnel-ledger.txt"

note "running the funnel over the fixture (offline, DARK_FACTORY_DIR=$DFD) ..."
QUEUE_OUT="$(DARK_FACTORY_DIR="$DFD" "$FUNNEL" --from "$CANDS" 2>/dev/null)"; RC=$?
echo "----- ranked queue -----"
printf '%s\n' "$QUEUE_OUT" | sed 's/^/    /'
echo "------------------------"

# (d) exit 0
if [ "$RC" -eq 0 ]; then ok "run-funnel.sh exited 0 on the offline --from path"
else bad "run-funnel.sh exited $RC (expected 0)"; fi

# Column 2 of each TSV row is the platform:id key; column 1 is the score.
KEYS="$(printf '%s\n' "$QUEUE_OUT" | awk -F'\t' 'NF>=2{print $2}')"
SCORES="$(printf '%s\n' "$QUEUE_OUT" | awk -F'\t' 'NF>=1{print $1}')"

has_key() { printf '%s\n' "$KEYS" | grep -qxF "$1"; }

# (b) the non-RUNNING candidate (biggest prize) was dropped by the freshness filter.
if has_key "sherlock:closed"; then bad "freshness FAILED: 'sherlock:closed' (status FINISHED) is in the queue"
else ok "freshness: the non-RUNNING candidate 'sherlock:closed' is absent"; fi

# (c) the ledger-seen candidate (also a big prize) was dropped by self-dedup.
if has_key "sherlock:seen"; then bad "self-dedup FAILED: 'sherlock:seen' (in the ledger) is in the queue"
else ok "self-dedup: the ledger-seen candidate 'sherlock:seen' is absent"; fi

# The four survivors must all be present (sanity: the filters did not over-drop).
ALL_SURVIVORS=1
for k in sherlock:top immunefi:mid sherlock:low sherlock:floor; do
  has_key "$k" || { bad "expected survivor '$k' missing from the queue"; ALL_SURVIVORS=0; }
done
[ "$ALL_SURVIVORS" -eq 1 ] && ok "all four RUNNING, un-seen survivors are present"

# (a) ranked by score DESCENDING — the printed score column must be non-increasing top to bottom.
if [ -n "$SCORES" ] && printf '%s\n' "$SCORES" | awk 'NR>1 && $1>prev{exit 1} {prev=$1}'; then
  ok "queue is ranked by score descending: $(printf '%s' "$SCORES" | tr '\n' ' ')"
else
  bad "queue is NOT sorted by score descending: $(printf '%s' "$SCORES" | tr '\n' ' ')"
fi

# Stronger ordering check: the exact expected key order (top > mid > low > floor by the documented levers).
EXPECTED=$'sherlock:top\nimmunefi:mid\nsherlock:low\nsherlock:floor'
if [ "$KEYS" = "$EXPECTED" ]; then
  ok "exact rank order matches the documented scoring (top > mid > low > floor)"
else
  bad "rank order mismatch — got:"; printf '%s\n' "$KEYS" | sed 's/^/        /'
  note "expected:"; printf '%s\n' "$EXPECTED" | sed 's/^/        /'
fi

# The queue FILE must equal the stdout view (run-funnel.sh writes both).
if [ "$(cat "$DFD/targets.queue" 2>/dev/null)" = "$QUEUE_OUT" ]; then
  ok "the targets.queue file equals the stdout view"
else
  bad "the targets.queue file differs from stdout"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the funnel turned a fixture candidate list into a ranked, freshness-checked, self-deduped queue —"
  note "      the non-RUNNING and the ledger-seen candidates (both high-prize) were dropped, the four survivors"
  note "      ranked by the deterministic weighted score, and run-funnel.sh exited 0. Offline + deterministic;"
  note "      a queued target is a LEAD a human / the #1055 batch runner triages — this tool never submits."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
