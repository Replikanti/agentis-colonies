#!/usr/bin/env bash
# watch-new-listings.sh — the FRESHNESS-FIRST new-listing watcher (#1623): a standalone (NOT sourcing
# run-immunefi-intake.sh) read-only scan of the keyless Immunefi `public-api/bounties.json` that surfaces
# programs worth being FIRST to, rather than ranking the whole survivor set. The survivor filter (EVM/Solidity/
# Vyper/Yul, not `inviteOnly`, in-window `endDate`, `maxBounty >= --floor`) DUPLICATES the #1592 mapper in
# run-immunefi-intake.sh verbatim (copy-not-source, the #1609 discipline) — that file's ranking output is
# regression-critical and stays untouched. On top of the survivor filter this script layers ONE new signal:
# FRESH = launched within `--max-age-days` (via `launchDate`) OR first-seen-by-us (the program's key is absent
# from a NEW self-dedup ledger, `seen-listings.txt`, distinct from run-batch.sh's `funnel-ledger.txt`) — the
# honest proxy for "new" when `launchDate` is stale/absent. Emits the SAME 5-column
# `score<TAB>key<TAB>url<TAB>name<TAB>scope_hint` TSV run-batch.sh --queue already consumes, using the SAME
# `immunefi:<id>` key namespace run-immunefi-intake.sh uses (so the two tools' ledgers/queues share a key
# namespace; they write to DIFFERENT queue files — new-listings.queue vs immunefi.queue/targets.queue/
# prospector.queue — so running both against the same program is not a bug, just two views of it).
#
# Usage: watch-new-listings.sh [--bounties <file>] [--url <endpoint>] [--floor <usd>] [--max-age-days N]
#                               [--ledger <file>] [--out <file>] [-h]
#   --bounties     : offline hatch — read a raw bounties.json array from <file> instead of a live fetch. No
#                     network. Unreadable -> exit 2.
#   --url          : the live-fetch endpoint (default https://immunefi.com/public-api/bounties.json).
#   --floor        : drop programs whose maxBounty is below <usd> (default 10000).
#   --max-age-days : the launch-window freshness threshold in days (default 21). Must be a positive integer;
#                     a bad value (non-numeric, zero, negative) is operator error -> exit 2 — a silently
#                     swallowed bad value would otherwise yield a confident-looking false "nothing fresh".
#   --ledger       : the self-dedup ledger path (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/
#                     seen-listings.txt), `key<TAB>first_seen_ts` per line. Missing/unreadable -> empty set,
#                     never a crash.
#   --out          : queue output path (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/new-listings.queue —
#                     a name distinct from immunefi.queue/targets.queue/prospector.queue).
#
# DISCOVERY: with no --bounties this script fetches --url live (there is exactly one discovery path here,
# unlike run-immunefi-intake.sh's --programs/--live/--bounties three-way). `command -v python3` missing ->
# `[SKIP]` + exit 0. A failed/empty live fetch -> `[SKIP]` + exit 0 with BOTH --out and --ledger UNTOUCHED
# (mirrors run-immunefi-intake.sh --live's SKIP contract).
#
# FRESHNESS (the new signal): for every SURVIVOR of the duplicated EVM/funded/in-window filter,
#   is_new           = key NOT IN the ledger
#   launch_days_ago   = (today - launchDate).days when launchDate parses, else None
#   FRESH             = (launch_days_ago is not None AND launch_days_ago <= --max-age-days) OR is_new
# Only FRESH rows are emitted. reason:window (launch-window only), reason:new-listing (ledger-only), or
# reason:both when a program is fresh by BOTH criteria — packed into scope_hint col 5.
#
# LEDGER UPDATE: after a successful run, EVERY current survivor's key (not just the FRESH ones) is recorded
# into --ledger (append-only, `key<TAB>first_seen_ts`) so the NEXT run's is_new check narrows to genuinely new
# programs — this is what makes the ledger-only signal idempotent across runs.
#
# EMIT: `score<TAB>immunefi:<id><TAB>url<TAB>name<TAB>scope_hint`, score 100 for launch-window-fresh (with or
# without also being new), 60 for new-listing-only. DESC by score then key ASC (house tie-break convention).
# scope_hint packs `chain:<chain> repo:<repo-or-'-'> launch:<launchDate-or-'-'> reason:<window|new-listing|both>`.
# Written to stdout AND --out (mkdir -p the parent first).
#
# NOTE on the shared `immunefi:<id>` key namespace: this script's `new-listings.queue` and
# run-immunefi-intake.sh's `immunefi.queue` can legitimately carry the SAME key with a DIFFERENT score/scope_hint
# shape — not a bug, they are separate queue files serving separate purposes (rank-everything vs surface-fresh).
#
# Requires: python3 (the filter's floor); curl only on the live-fetch path (a read-only public GET). Read-only /
# NEVER-SUBMIT: no write beyond the local ledger/queue, no platform call. The operator wires the recurring
# schedule (cron/systemd timer) — out of scope here; this script is a single read-only invocation.
# Exit 0 on success or a clean [SKIP]; 2 on bad/missing args.
set -u

DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "watch-new-listings.sh: $2 requires a value" >&2; exit 2; }; }
BOUNTIES="" ; URL="https://immunefi.com/public-api/bounties.json" ; FLOOR="10000" ; MAX_AGE_DAYS="21"
LEDGER="$DIR/seen-listings.txt" ; OUT="$DIR/new-listings.queue" ; MAX_TIME="30"
while [ $# -gt 0 ]; do case "$1" in
  --bounties)      nv "$#" "$1"; BOUNTIES="$2"; shift 2;;
  --url)           nv "$#" "$1"; URL="$2"; shift 2;;
  --floor)         nv "$#" "$1"; FLOOR="$2"; shift 2;;
  --max-age-days)
    nv "$#" "$1"
    case "$2" in
      ''|*[!0-9]*) echo "watch-new-listings.sh: --max-age-days must be a positive integer: $2" >&2; exit 2;;
    esac
    [ "$2" -ge 1 ] 2>/dev/null || { echo "watch-new-listings.sh: --max-age-days must be >= 1: $2" >&2; exit 2; }
    MAX_AGE_DAYS="$2"; shift 2;;
  --ledger)        nv "$#" "$1"; LEDGER="$2"; shift 2;;
  --out)           nv "$#" "$1"; OUT="$2"; shift 2;;
  -h|--help)       sed -n '2,44p' "$0"; exit 0;;
  *) echo "watch-new-listings.sh: unknown arg: $1" >&2; exit 2;;
esac; done

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

RAW=""
if [ -n "$BOUNTIES" ]; then
  [ -r "$BOUNTIES" ] || { echo "watch-new-listings.sh: --bounties <file> not readable: $BOUNTIES" >&2; exit 2; }
  RAW="$BOUNTIES"
else
  command -v curl >/dev/null 2>&1 || { echo "[SKIP] curl not installed" >&2; exit 0; }
  FETCHED="$(mktemp "${TMPDIR:-/tmp}/watch-new-listings-raw.XXXXXX")"
  trap 'rm -f "$FETCHED"' EXIT
  curl -sS --max-time "$MAX_TIME" "$URL" -o "$FETCHED" 2>/dev/null || :
  [ -s "$FETCHED" ] || { echo "[SKIP] no network / empty response from $URL — nothing to watch" >&2; exit 0; }
  RAW="$FETCHED"
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true

# FILTER + FRESHNESS + EMIT + LEDGER UPDATE (python3 only, no shell JSON parsing).
RAW="$RAW" FLOOR="$FLOOR" MAX_AGE_DAYS="$MAX_AGE_DAYS" LEDGER="$LEDGER" OUT="$OUT" python3 - <<'PY'
import datetime
import json
import os
import re
import sys

raw_path = os.environ["RAW"]
ledger_path = os.environ["LEDGER"]
out_path = os.environ["OUT"]
try:
    floor = float(os.environ.get("FLOOR", "10000") or 0)
except ValueError:
    floor = 10000.0
try:
    max_age_days = int(os.environ.get("MAX_AGE_DAYS", "21") or 21)
except ValueError:
    max_age_days = 21

# EVM/LANGS survivor filter duplicated VERBATIM from run-immunefi-intake.sh's #1592 mapper (copy-not-source,
# the #1609 discipline — do not edit that file to add this watcher).
EVM = {"ethereum", "arbitrum", "optimism", "base", "polygon", "matic", "bsc", "binance", "avalanche", "avax",
       "fantom", "gnosis", "xdai", "scroll", "linea", "zksync", "mantle", "blast", "mode", "celo", "moonbeam",
       "aurora", "metis", "fraxtal", "manta", "opbnb", "kava", "canto", "core", "sonic", "berachain"}
LANGS = {"solidity", "vyper", "yul"}
today = datetime.date.today()


def as_list(v):
    if isinstance(v, list):
        return v
    if v in (None, ""):
        return []
    return [v]


def usd(v):
    if isinstance(v, (int, float)):
        return float(v)
    if not v:
        return 0.0
    m = re.match(r"^\s*\$?([0-9]*\.?[0-9]+)\s*([kmb]?)", str(v).strip().lower().replace(",", ""))
    if not m:
        return 0.0
    return float(m.group(1)) * {"": 1, "k": 1e3, "m": 1e6, "b": 1e9}[m.group(2)]


def parse_date(v):
    if not v:
        return None
    try:
        return datetime.date.fromisoformat(str(v)[:10])
    except Exception:
        return None


def looks_like_repo(u):
    u = str(u or "").lower()
    return any(h in u for h in ("github.com", "bitbucket.org", "sourcehut.org", "sr.ht", "git."))


def clean(s):
    """A TSV/label-safe field: no tabs or newlines (they would corrupt the queue's columns)."""
    return re.sub(r"[\t\r\n]+", " ", str(s or "")).strip()


try:
    raw = json.load(open(raw_path, encoding="utf-8", errors="ignore"))
except Exception:
    raw = []
if isinstance(raw, dict):                       # some feeds wrap the array under a top-level key
    for k in ("bounties", "data", "programs", "results"):
        if isinstance(raw.get(k), list):
            raw = raw[k]
            break
if not isinstance(raw, list):
    raw = []

survivors = []
for b in raw:
    if not isinstance(b, dict):
        continue
    langs = [str(x).strip().lower() for x in as_list(b.get("language"))]
    ecos = [str(x).strip().lower() for x in as_list(b.get("ecosystem"))]
    is_evm = any(l in LANGS for l in langs) or any(any(e == k or k in e for k in EVM) for e in ecos)
    if not is_evm:
        continue
    if b.get("inviteOnly"):
        continue
    end = parse_date(b.get("endDate"))
    if end is not None and end < today:
        continue
    reward = usd(b.get("maxBounty"))
    if reward < floor:
        continue
    slug = str(b.get("slug") or b.get("id") or "").strip()
    if not slug:
        continue
    repo = "-"
    for a in as_list(b.get("assets")):
        u = a.get("url") if isinstance(a, dict) else a
        if looks_like_repo(u):
            repo = str(u)
            break
    chain = (ecos[0] if ecos else (langs[0] if langs else "")) or "?"
    launch = parse_date(b.get("launchDate"))
    survivors.append({
        "key": "immunefi:%s" % slug,
        "url": "https://immunefi.com/bug-bounty/%s/" % slug,
        "name": str(b.get("project") or slug),
        "chain": chain,
        "repo": repo,
        "launch": launch,
    })

# DEDUP by key (case-insensitive): a feed may repeat a slug; keep the first occurrence (mirrors
# run-immunefi-intake.sh's dedup-keep-first convention, applied here before the freshness pass so a repeated
# key is never double-counted / double-appended to the ledger).
_seen_keys = set()
_deduped = []
for s in survivors:
    k = s["key"].lower()
    if k in _seen_keys:
        continue
    _seen_keys.add(k)
    _deduped.append(s)
survivors = _deduped

# LEDGER: `key<TAB>first_seen_ts` per line; missing/unreadable -> empty set, never a crash.
seen = set()
try:
    if os.path.exists(ledger_path):
        with open(ledger_path, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                k = line.split("\t", 1)[0].strip()
                if k:
                    seen.add(k.lower())
except Exception:
    seen = set()

now_ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
rows = []
by_window = 0
by_new = 0
new_ledger_keys = []
for s in survivors:
    key = s["key"]
    is_new = key.lower() not in seen
    launch_days_ago = (today - s["launch"]).days if s["launch"] is not None else None
    window_fresh = launch_days_ago is not None and launch_days_ago <= max_age_days
    fresh = window_fresh or is_new
    if is_new:
        new_ledger_keys.append(key)
    if not fresh:
        continue
    if window_fresh and is_new:
        reason = "both"
        score = 100
    elif window_fresh:
        reason = "window"
        score = 100
        by_window += 1
    else:
        reason = "new-listing"
        score = 60
        by_new += 1
    if reason == "both":
        by_window += 1
        by_new += 1
    launch_str = s["launch"].isoformat() if s["launch"] is not None else "-"
    scope = "chain:%s repo:%s launch:%s reason:%s" % (
        clean(s["chain"]) or "?", clean(s["repo"]) or "-", launch_str, reason)
    rows.append((score, key, clean(s["url"]), clean(s["name"]) or key, scope))

# RANK: score DESC, then key ASC (house tie-break convention).
rows.sort(key=lambda r: (-r[0], r[1].lower()))

lines = ["%d\t%s\t%s\t%s\t%s" % r for r in rows]
with open(out_path, "w", encoding="utf-8") as fh:
    for line in lines:
        fh.write(line + "\n")
for line in lines:
    print(line)

# LEDGER UPDATE: append every current survivor's key not already tracked (append-only, after a successful run).
if new_ledger_keys:
    with open(ledger_path, "a", encoding="utf-8") as fh:
        for key in new_ledger_keys:
            fh.write("%s\t%s\n" % (key, now_ts))

ledger_total = len(seen | {k.lower() for k in new_ledger_keys})
sys.stderr.write(
    "watch-new-listings: %d fresh program(s) (%d by launch-window, %d by first-seen) of %d total survivor(s) "
    "-> %s; ledger now tracks %d key(s)\n" % (
        len(rows), by_window, by_new, len(survivors), out_path, ledger_total))
PY
