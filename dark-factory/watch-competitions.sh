#!/usr/bin/env bash
# watch-competitions.sh — the audit-COMPETITION freshness watcher (#1635, #1643): a standalone (NOT sourcing
# watch-new-listings.sh or run-immunefi-intake.sh) read-only scan of THREE keyless competition sources —
# Sherlock's `mainnet-contest.sherlock.xyz/contests`, Cantina's `cantina.xyz/api/v0/competitions`, and
# CodeHawks' `codehawks.cyfrin.io/contests` — that surfaces a live audit competition ONCE, the first run it is
# seen, rather than re-ranking the whole set. It is the competition-side mirror of the shipped #1623 new-listing
# watcher: the shell layer does all fetching (curl, unauthenticated GETs only) and ONE embedded python3 block
# does ALL parse / normalize / filter / emit — never shell parsing. All three platforms feed ONE common
# normalized record through a single python normalizer (Sherlock's paginated `{"items":[...]}` shape, Cantina's
# bare top-level array, and CodeHawks' `data-sveltekit-fetched` HTML-embedded tRPC JSON all mapped into the same
# dict), so the emit/ledger/scoring/SKIP logic is single-sourced. CodeHawks is NOT API-key-gated: the `/contests`
# page is server-rendered SvelteKit that embeds the keyless `competitions.getCompetitions` tRPC response in the
# HTML, so a plain `curl -A "Mozilla/5.0"` (no browser, no node) returns all contests — no Playwright needed.
#
# Usage: watch-competitions.sh [--sherlock-from <file>] [--cantina-from <file>] [--codehawks-from <file>]
#                              [--sherlock-url <endpoint>] [--cantina-url <endpoint>] [--codehawks-url <url>]
#                              [--max-pages N] [--ledger <file>] [--out <file>] [-h]
#   --sherlock-from : offline hatch — read a raw Sherlock contests JSON (a `{"items":[...]}` object or a bare
#                      array) from <file> instead of a live fetch. No network. Unreadable -> exit 2.
#   --cantina-from  : offline hatch — read a raw Cantina competitions JSON (a bare array or a `{"data":[...]}`
#                      wrapper) from <file> instead of a live fetch. No network. Unreadable -> exit 2.
#   --codehawks-from: offline hatch — read a raw CodeHawks `/contests` page HTML (the `data-sveltekit-fetched`
#                      tRPC embed) from <file> instead of a live fetch. No network. Unreadable -> exit 2.
#   --sherlock-url  : the live Sherlock endpoint (default https://mainnet-contest.sherlock.xyz/contests).
#   --cantina-url   : the live Cantina endpoint (default https://cantina.xyz/api/v0/competitions).
#   --codehawks-url : the live CodeHawks contests page (default https://codehawks.cyfrin.io/contests).
#   --max-pages     : Sherlock live pagination cap (default 5). Positive integer; a bad value (non-numeric,
#                      zero, negative) is operator error -> exit 2 — a swallowed bad value would silently
#                      truncate the fetch and yield a confident-looking false "nothing live".
#   --ledger        : the self-dedup ledger path (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/
#                      seen-competitions.txt), `key<TAB>first_seen_ts` per line. Missing/unreadable -> empty
#                      set, never a crash.
#   --out           : queue output path (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/competitions.queue —
#                      a name distinct from new-listings.queue/immunefi.queue).
#
# DISCOVERY (three source modes per platform, generalizing #1623's single-endpoint SKIP to three platforms):
#   - `--sherlock-from` / `--cantina-from` / `--codehawks-from` given -> read that file, no network (unreadable
#     -> exit 2).
#   - absent -> live fetch of `--sherlock-url` / `--cantina-url` / `--codehawks-url` (Sherlock paginated
#     `?page=1..--max-pages`; CodeHawks a single keyless `curl -A "Mozilla/5.0"` of the SvelteKit page).
#   - `command -v python3` missing -> `[SKIP]` + exit 0. On the live path, `command -v curl` missing ->
#     `[SKIP]` + exit 0.
#   - A platform on the live path whose fetch fails/empties contributes nothing, but the OTHERS still
#     proceed — a partial outage must NOT suppress a healthy platform's new competitions. The CodeHawks
#     HTML-embed parse is additionally wrapped in a try/except that contributes ZERO on any drift/malformation,
#     so a CodeHawks-side break never disturbs Sherlock/Cantina.
#   - If, after resolution, NO platform has any usable input -> `[SKIP]` + exit 0 with `--out` and `--ledger`
#     byte-for-byte UNTOUCHED.
#
# COMMON normalized record (one python dict per competition — the ONLY schema the emit/ledger path sees):
#   platform "sherlock"|"cantina"|"codehawks" · id (list-endpoint id) · key (dedup key, below) · name · url ·
#   status (raw/derived, lowercased) · live (bool, per-platform rule) · prize_usd (float, best-effort) · kyc
#   (bool) · ends (ISO date or "-") · repo (best-effort from LIST fields, else "-"). CodeHawks additionally
#   carries `prize_label` (raw `reward+currency`, e.g. `7.25eth`/`20000usdc`), surfaced in scope_hint's prize:
#   field so the amount shows even when the currency is not USD-scored. `clean()` strips tabs/newlines from
#   every string field (TSV-safety), verbatim from watch-new-listings.sh.
#
# KEY rule (derived ONLY from list-endpoint fields, so the dedup key never mutates between runs):
#   Sherlock : `sherlock:<numeric id>` (always present in the list, stable — slugs need a per-contest detail
#              fetch, which is deferred, so they must NOT drive the key).
#   Cantina  : `cantina:<slug>` where slug = last non-empty path segment of `url` lowercased, else the uuid id.
#   CodeHawks: `codehawks:<urlSlug>` (the contest's stable `urlSlug`, present on every embed row).
#
# LIVE filter (per platform, stated exactly):
#   Sherlock : live = (status.lower() == "running") AND not private; additionally, when `ends_at` parses,
#              require it to be in the future. JUDGING / ESCALATION / any non-RUNNING status is dropped; a
#              private (invite-only) contest is dropped (not permissionless).
#   Cantina  : live = status.lower() NOT IN {complete, escalations_ended, closed, judging, ended, completed} —
#              an allowlist-by-exclusion (no live-status string can be confirmed while none is open), failing
#              toward surfacing rather than hiding a genuine live competition.
#   CodeHawks: there is NO status/phase enum in the embed — submissions-open is DATE-DERIVED. live = the
#              contest is inside its `[startDate, endDate)` window (`startDate <= today < endDate`) AND
#              `finalised == false` AND `inviteOnly == false`. Everything else drops: `finalised` (ended),
#              `inviteOnly` (not permissionless), `today < startDate` (upcoming), `today >= endDate`
#              (judging/appeals/ended — a future `appealEndDate` does NOT keep submissions open), and any
#              contest whose dates do not parse (fail toward hiding an unconfirmable one).
#   NO hard language/DeFi filter on any platform (all are Solidity-centric audit comps); any tag rides in
#   scope_hint.
#
# EMIT + LEDGER (first-seen only): emit(comp) iff comp.live AND comp.key not in the ledger. After a successful
# run, append every live comp's key not already ledgered as `key<TAB><now_iso_utc>`. Non-live comps are neither
# emitted nor ledgered (so an upcoming comp that later flips live WILL surface as new). Unlike #1623 there is no
# window re-surface signal: a live comp surfaces ONCE then dedups — two runs over the same input yield zero new.
#   5-column TSV `score<TAB>key<TAB>url<TAB>title<TAB>scope_hint`, written to stdout AND --out (mkdir -p first):
#     score = int(round(prize_term + freshness_term)), prize_term = 70*min(1, log10(1+prize_usd)/7),
#     freshness_term = 30 (every emitted row is freshly surfaced). Sorted score DESC then key ASC (house
#     tie-break). scope_hint (single field, no extra columns) =
#     `platform:<sherlock|cantina|codehawks> status:<raw-or-derived> prize:<usd-or-label-or-'-'> kyc:<yes|no>
#     ends:<date-or-'-'> repo:<repo-or-'-'>` (CodeHawks's prize: carries the raw `reward+currency` label).
#
# Requires: python3 (the normalizer). curl only on a live-fetch path (a read-only public GET). Read-only /
# NEVER-SUBMIT: only unauthenticated GETs; no write beyond the local ledger/queue, no platform call. The
# operator wires the recurring schedule (cron/systemd timer) — out of scope here.
# Exit 0 on success or a clean [SKIP]; 2 on bad/missing args.
#
# OUT OF SCOPE (follow-ups): Code4rena (no clean keyless endpoint); per-contest Sherlock scope/repo enrichment
# via `GET /contests/<id>` (repo stays best-effort from LIST fields only, so the key/ledger stay list-only and
# stable). CodeHawks NO LONGER needs a browser — the #1643 keyless HTML-embed path lands it as a third channel.
set -u

DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "watch-competitions.sh: $2 requires a value" >&2; exit 2; }; }
SHERLOCK_FROM="" ; CANTINA_FROM="" ; CODEHAWKS_FROM=""
SHERLOCK_URL="https://mainnet-contest.sherlock.xyz/contests"
CANTINA_URL="https://cantina.xyz/api/v0/competitions"
CODEHAWKS_URL="https://codehawks.cyfrin.io/contests"
MAX_PAGES="5"
LEDGER="$DIR/seen-competitions.txt" ; OUT="$DIR/competitions.queue" ; MAX_TIME="30"
while [ $# -gt 0 ]; do case "$1" in
  --sherlock-from)  nv "$#" "$1"; SHERLOCK_FROM="$2"; shift 2;;
  --cantina-from)   nv "$#" "$1"; CANTINA_FROM="$2"; shift 2;;
  --codehawks-from) nv "$#" "$1"; CODEHAWKS_FROM="$2"; shift 2;;
  --sherlock-url)   nv "$#" "$1"; SHERLOCK_URL="$2"; shift 2;;
  --cantina-url)    nv "$#" "$1"; CANTINA_URL="$2"; shift 2;;
  --codehawks-url)  nv "$#" "$1"; CODEHAWKS_URL="$2"; shift 2;;
  --max-pages)
    nv "$#" "$1"
    case "$2" in
      ''|*[!0-9]*) echo "watch-competitions.sh: --max-pages must be a positive integer: $2" >&2; exit 2;;
    esac
    [ "$2" -ge 1 ] 2>/dev/null || { echo "watch-competitions.sh: --max-pages must be >= 1: $2" >&2; exit 2; }
    MAX_PAGES="$2"; shift 2;;
  --ledger)        nv "$#" "$1"; LEDGER="$2"; shift 2;;
  --out)           nv "$#" "$1"; OUT="$2"; shift 2;;
  -h|--help)       sed -n '2,98p' "$0"; exit 0;;
  *) echo "watch-competitions.sh: unknown arg: $1" >&2; exit 2;;
esac; done

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

# Temp files collected here for a single trap-cleaned lifetime.
TMPDIR_WC="$(mktemp -d "${TMPDIR:-/tmp}/watch-competitions.XXXXXX")"
trap 'rm -rf "$TMPDIR_WC"' EXIT

# --- Sherlock source resolution -> SHERLOCK_FILES (a space-separated list of page files, or empty) ----------
SHERLOCK_FILES=""
if [ -n "$SHERLOCK_FROM" ]; then
  [ -r "$SHERLOCK_FROM" ] || { echo "watch-competitions.sh: --sherlock-from <file> not readable: $SHERLOCK_FROM" >&2; exit 2; }
  SHERLOCK_FILES="$SHERLOCK_FROM"
else
  if command -v curl >/dev/null 2>&1; then
    page=1
    while [ "$page" -le "$MAX_PAGES" ]; do
      case "$SHERLOCK_URL" in
        *\?*) purl="${SHERLOCK_URL}&page=${page}";;
        *)    purl="${SHERLOCK_URL}?page=${page}";;
      esac
      pf="$TMPDIR_WC/sherlock-p${page}.json"
      curl -sS --max-time "$MAX_TIME" "$purl" -o "$pf" 2>/dev/null || :
      if [ -s "$pf" ]; then
        SHERLOCK_FILES="$SHERLOCK_FILES $pf"
      else
        # First empty page ends pagination (a healthy feed returns items on page 1); a later empty page just
        # stops the walk. Either way the other platform is unaffected.
        break
      fi
      page=$((page + 1))
    done
  fi
fi

# --- Cantina source resolution -> CANTINA_FILE (one file, or empty) -----------------------------------------
CANTINA_FILE=""
if [ -n "$CANTINA_FROM" ]; then
  [ -r "$CANTINA_FROM" ] || { echo "watch-competitions.sh: --cantina-from <file> not readable: $CANTINA_FROM" >&2; exit 2; }
  CANTINA_FILE="$CANTINA_FROM"
else
  if command -v curl >/dev/null 2>&1; then
    cf="$TMPDIR_WC/cantina.json"
    curl -sS --max-time "$MAX_TIME" "$CANTINA_URL" -o "$cf" 2>/dev/null || :
    [ -s "$cf" ] && CANTINA_FILE="$cf"
  fi
fi

# --- CodeHawks source resolution -> CODEHAWKS_FILE (one raw `/contests` page HTML file, or empty) ------------
# The live fetch is a single keyless GET of the SvelteKit page WITH a browser-shaped UA (matches the verified-
# working request); the embed-JSON extraction happens defensively inside the python normalizer.
CODEHAWKS_FILE=""
if [ -n "$CODEHAWKS_FROM" ]; then
  [ -r "$CODEHAWKS_FROM" ] || { echo "watch-competitions.sh: --codehawks-from <file> not readable: $CODEHAWKS_FROM" >&2; exit 2; }
  CODEHAWKS_FILE="$CODEHAWKS_FROM"
else
  if command -v curl >/dev/null 2>&1; then
    chf="$TMPDIR_WC/codehawks.html"
    curl -sS -A "Mozilla/5.0" --max-time "$MAX_TIME" "$CODEHAWKS_URL" -o "$chf" 2>/dev/null || :
    [ -s "$chf" ] && CODEHAWKS_FILE="$chf"
  fi
fi

# No usable input from ANY platform -> a clean [SKIP], ledger + queue byte-for-byte untouched. (When curl is
# missing on a pure live run all three resolutions produce nothing and we land here.)
if [ -z "${SHERLOCK_FILES# }" ] && [ -z "$CANTINA_FILE" ] && [ -z "$CODEHAWKS_FILE" ]; then
  if ! command -v curl >/dev/null 2>&1 && [ -z "$SHERLOCK_FROM" ] && [ -z "$CANTINA_FROM" ] && [ -z "$CODEHAWKS_FROM" ]; then
    echo "[SKIP] curl not installed" >&2
  else
    echo "[SKIP] no network / empty response from all platforms — nothing to watch" >&2
  fi
  exit 0
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true

# NORMALIZE (both schemas -> one record) + FILTER + EMIT + LEDGER UPDATE (python3 only, no shell JSON parsing).
SHERLOCK_FILES="$SHERLOCK_FILES" CANTINA_FILE="$CANTINA_FILE" CODEHAWKS_FILE="$CODEHAWKS_FILE" LEDGER="$LEDGER" OUT="$OUT" python3 - <<'PY'
import datetime
import json
import math
import os
import re
import sys

sherlock_files = os.environ.get("SHERLOCK_FILES", "").split()
cantina_file = os.environ.get("CANTINA_FILE", "").strip()
codehawks_file = os.environ.get("CODEHAWKS_FILE", "").strip()
ledger_path = os.environ["LEDGER"]
out_path = os.environ["OUT"]

CANTINA_DEAD = {"complete", "escalations_ended", "closed", "judging", "ended", "completed"}
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
    """A date from an ISO string OR a unix epoch (seconds or millis); None when it does not parse."""
    if v in (None, ""):
        return None
    if isinstance(v, (int, float)):
        try:
            ts = float(v)
            if ts > 1e11:            # millis
                ts /= 1000.0
            return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).date()
        except Exception:
            return None
    s = str(v).strip()
    if re.match(r"^[0-9]+$", s):
        return parse_date(int(s))
    try:
        return datetime.date.fromisoformat(s[:10])
    except Exception:
        return None


def looks_like_repo(u):
    u = str(u or "").lower()
    return any(h in u for h in ("github.com", "bitbucket.org", "sourcehut.org", "sr.ht", "git."))


def clean(s):
    """A TSV/label-safe field: no tabs or newlines (they would corrupt the queue's columns)."""
    return re.sub(r"[\t\r\n]+", " ", str(s or "")).strip()


def load(path):
    try:
        return json.load(open(path, encoding="utf-8", errors="ignore"))
    except Exception:
        return None


def slug_of(url):
    """Last non-empty path segment of a url, lowercased."""
    s = str(url or "").split("?", 1)[0].split("#", 1)[0]
    parts = [p for p in s.split("/") if p]
    return parts[-1].lower() if parts else ""


# --- Sherlock: union all page files' `items` by numeric id (identical code path for 1 or N files) -----------
sherlock_items = {}
sherlock_order = []
for pf in sherlock_files:
    raw = load(pf)
    if isinstance(raw, dict):
        for k in ("items", "contests", "data", "results"):
            if isinstance(raw.get(k), list):
                raw = raw[k]
                break
    if not isinstance(raw, list):
        continue
    for it in raw:
        if not isinstance(it, dict):
            continue
        cid = it.get("id")
        if cid in (None, ""):
            continue
        cid = str(cid).strip()
        if cid not in sherlock_items:
            sherlock_items[cid] = it
            sherlock_order.append(cid)

comps = []
for cid in sherlock_order:
    it = sherlock_items[cid]
    status = str(it.get("status") or "").strip().lower()
    private = bool(it.get("private"))
    ends = parse_date(it.get("ends_at") if it.get("ends_at") is not None else it.get("endsAt"))
    live = (status == "running") and not private
    if live and ends is not None and ends < today:
        live = False
    prize = usd(it.get("prize_pool") if it.get("prize_pool") is not None else it.get("rewards"))
    if not prize:
        prize = usd(it.get("total_rewards") if it.get("total_rewards") is not None else it.get("totalRewards"))
    repo = "-"
    for cand in (it.get("repo"), it.get("template_repo_name"), it.get("github_url")):
        if looks_like_repo(cand):
            repo = str(cand)
            break
    name = str(it.get("title") or it.get("name") or ("sherlock contest %s" % cid))
    slug = str(it.get("slug") or "").strip()
    url = str(it.get("url") or "")
    if not url:
        url = "https://audits.sherlock.xyz/contests/%s" % (slug or cid)
    comps.append({
        "platform": "sherlock",
        "id": cid,
        "key": "sherlock:%s" % cid,
        "name": name,
        "url": url,
        "status": status,
        "live": live,
        "prize_usd": prize,
        "kyc": False,
        "ends": ends.isoformat() if ends is not None else "-",
        "repo": repo,
    })

# --- Cantina: a bare array (or a {"data":[...]}/{"competitions":[...]} wrapper) ------------------------------
craw = load(cantina_file) if cantina_file else None
if isinstance(craw, dict):
    for k in ("competitions", "data", "results", "items"):
        if isinstance(craw.get(k), list):
            craw = craw[k]
            break
if not isinstance(craw, list):
    craw = []
for it in craw:
    if not isinstance(it, dict):
        continue
    cid = it.get("id")
    if cid in (None, ""):
        continue
    cid = str(cid).strip()
    url = str(it.get("url") or "")
    slug = slug_of(url) or cid.lower()
    status = str(it.get("status") or "").strip().lower()
    live = status not in CANTINA_DEAD
    prize = usd(it.get("totalRewardPot") if it.get("totalRewardPot") is not None else it.get("total_reward_pot"))
    if not prize:
        prize = usd(it.get("prize") if it.get("prize") is not None else it.get("rewards"))
    ends = parse_date(it.get("endDate") if it.get("endDate") is not None else it.get("ends_at"))
    kyc = bool(it.get("kycRequired") if it.get("kycRequired") is not None else it.get("kyc_required"))
    repo = "-"
    for cand in (it.get("repoUrl"), it.get("repo"), it.get("githubUrl")):
        if looks_like_repo(cand):
            repo = str(cand)
            break
    name = str(it.get("name") or it.get("title") or ("cantina competition %s" % slug))
    if not url:
        url = "https://cantina.xyz/competitions/%s" % slug
    comps.append({
        "platform": "cantina",
        "id": cid,
        "key": "cantina:%s" % slug,
        "name": name,
        "url": url,
        "status": status,
        "live": live,
        "prize_usd": prize,
        "kyc": kyc,
        "ends": ends.isoformat() if ends is not None else "-",
        "repo": repo,
    })

# --- CodeHawks: keyless HTML embed (server-rendered SvelteKit `data-sveltekit-fetched` tRPC block). ENTIRELY
# DEFENSIVE — the whole extraction is wrapped in try/except so ANY failure (block absent, JSON malformed, embed
# drift, HTML instead of the page) contributes ZERO records and NEVER disturbs the Sherlock/Cantina records
# already in `comps`. There is NO status enum: submissions-open is DATE-DERIVED (see the header LIVE filter). ---
if codehawks_file:
    try:
        with open(codehawks_file, encoding="utf-8", errors="ignore") as fh:
            html = fh.read()
        m = re.search(
            r'data-sveltekit-fetched[^>]*data-url="[^"]*competitions\.getCompetitions[^"]*"[^>]*>(.*?)</script>',
            html, re.S)
        if m:
            outer = json.loads(m.group(1).strip())
            body = json.loads(outer["body"]) if isinstance(outer, dict) else None
            contests = []
            for elem in as_list(body):
                if isinstance(elem, dict):
                    data = elem.get("result", {}).get("data") if isinstance(elem.get("result"), dict) else None
                    if isinstance(data, list):
                        contests.extend(data)
            for it in contests:
                if not isinstance(it, dict):
                    continue
                slug = str(it.get("urlSlug") or "").strip()
                if not slug:
                    continue
                start = parse_date(it.get("startDate"))
                ends = parse_date(it.get("endDate"))
                finalised = bool(it.get("finalised"))
                invite = bool(it.get("inviteOnly"))
                # Derived phase (order matters): finalised -> ended; inviteOnly -> not permissionless;
                # undatable -> unknown (hide); today < start -> upcoming; today >= end -> judging/appeals;
                # else the [start, end) window is open. Only `open` surfaces. A future appealEndDate is NOT
                # consulted — submissions close at endDate.
                if finalised:
                    phase = "ended"
                elif invite:
                    phase = "invite-only"
                elif start is None or ends is None:
                    phase = "unknown"
                elif today < start:
                    phase = "upcoming"
                elif today >= ends:
                    phase = "judging"
                else:
                    phase = "open"
                live = (phase == "open")
                reward = it.get("reward")
                currency = str(it.get("currency") or "").strip()
                # currencyUsdRate is unreliable (observed 1 for ETH) -> USD-score ONLY stable currencies; the raw
                # reward+currency always rides in scope_hint via prize_label so nothing is hidden.
                prize = usd(reward) if currency.lower() in {"usdc", "usd", "dai", "busd"} else 0.0
                if reward in (None, ""):
                    prize_label = ""
                else:
                    rtxt = ("%g" % reward) if isinstance(reward, (int, float)) else str(reward)
                    prize_label = ("%s%s" % (rtxt, currency)) if currency else rtxt
                repo = str(it.get("githubUrl")) if looks_like_repo(it.get("githubUrl")) else "-"
                name = str(it.get("name") or it.get("company") or slug)
                comps.append({
                    "platform": "codehawks",
                    "id": slug,
                    "key": "codehawks:%s" % slug,
                    "name": name,
                    "url": "https://codehawks.cyfrin.io/c/%s" % slug,
                    "status": phase,
                    "live": live,
                    "prize_usd": prize,
                    "prize_label": prize_label,
                    "kyc": bool(it.get("requiresKyc")),
                    "ends": ends.isoformat() if ends is not None else "-",
                    "repo": repo,
                })
    except Exception as exc:
        sys.stderr.write("watch-competitions: codehawks parse skipped (%s)\n" % exc)

# DEDUP by key (case-insensitive), keep first occurrence — mirrors watch-new-listings.sh, applied before the
# emit pass so a repeated key is never double-counted / double-appended to the ledger.
_seen_keys = set()
_deduped = []
for c in comps:
    k = c["key"].lower()
    if k in _seen_keys:
        continue
    _seen_keys.add(k)
    _deduped.append(c)
comps = _deduped

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
n_sherlock = 0
n_cantina = 0
n_codehawks = 0
n_live = 0
new_ledger_keys = []
for c in comps:
    if not c["live"]:
        continue
    n_live += 1
    key = c["key"]
    is_new = key.lower() not in seen
    if is_new:
        new_ledger_keys.append(key)
    else:
        continue
    prize = c["prize_usd"] or 0.0
    prize_term = 70.0 * min(1.0, math.log10(1.0 + prize) / 7.0)
    score = int(round(prize_term + 30.0))
    if c["platform"] == "sherlock":
        n_sherlock += 1
    elif c["platform"] == "cantina":
        n_cantina += 1
    else:
        n_codehawks += 1
    # CodeHawks records carry a raw `reward+currency` label so the amount shows even when un-USD-scored;
    # Sherlock/Cantina set no prize_label, so their computation is byte-identical to before.
    prize_str = c.get("prize_label") if c.get("prize_label") else (str(int(prize)) if prize else "-")
    scope = "platform:%s status:%s prize:%s kyc:%s ends:%s repo:%s" % (
        c["platform"], clean(c["status"]) or "-", prize_str, "yes" if c["kyc"] else "no",
        c["ends"] or "-", clean(c["repo"]) or "-")
    rows.append((score, key, clean(c["url"]), clean(c["name"]) or key, scope))

# RANK: score DESC, then key ASC (house tie-break convention).
rows.sort(key=lambda r: (-r[0], r[1].lower()))

lines = ["%d\t%s\t%s\t%s\t%s" % r for r in rows]
with open(out_path, "w", encoding="utf-8") as fh:
    for line in lines:
        fh.write(line + "\n")
for line in lines:
    print(line)

# LEDGER UPDATE: append every live comp's key not already tracked (append-only, after a successful run).
if new_ledger_keys:
    with open(ledger_path, "a", encoding="utf-8") as fh:
        for key in new_ledger_keys:
            fh.write("%s\t%s\n" % (key, now_ts))

ledger_total = len(seen | {k.lower() for k in new_ledger_keys})
sys.stderr.write(
    "watch-competitions: %d new (%d sherlock, %d cantina, %d codehawks) of %d live of %d total -> %s; "
    "ledger now tracks %d key(s)\n" % (
        len(rows), n_sherlock, n_cantina, n_codehawks, n_live, len(comps), out_path, ledger_total))
PY
