#!/usr/bin/env bash
# run-funnel.sh — the TARGET-INTAKE FUNNEL: turn "what should we look at" from a human pick into a ranked,
# freshness-checked, self-deduped QUEUE (#1054, epic #1053). Volume=1 (a human hand-picks every target and
# writes the recon by hand) makes expected yield ~0 against #1041's honest per-target odds; this funnel raises
# volume by mechanising intake.
#
# Pipeline (a PURE transform over the candidate JSON, so it is offline-testable end to end):
#   1. DISCOVER  -> a normalized candidate list. Live: RUNNING Sherlock contests (the cleanest JSON API, reused
#                   from contest-watch.sh's items[] pattern) + a best-effort Cantina/Code4rena probe. `--from
#                   <json>` reads the candidate list from a file INSTEAD of the network (deterministic tests +
#                   reproducible runs). With NO network AND no --from -> `[SKIP]` + exit 0 (CI-safe).
#   2. FRESHNESS -> drop any candidate whose `status` is not RUNNING (a closed window / rotated scope).
#   3. SELF-DEDUP-> drop any candidate whose key `platform:id` already appears in the ledger
#                   ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/funnel-ledger.txt. The batch runner (#1055) APPENDS
#                   `key<TAB>verdict<TAB>ts` rows there; the funnel only READS it.
#   4. SCORE     -> a deterministic weighted sum from the available signals (see SCORING below). Pure fn of the
#                   candidate fields -> the same input always yields the same ranking.
#   5. EMIT      -> the ranked queue (highest score first), one TSV line per candidate:
#                   `score<TAB>platform:id<TAB>url<TAB>title<TAB>scope_hint`. Written to stdout AND to
#                   ${DARK_FACTORY_DIR}/targets.queue.
#
# SCORING (documented here so it is auditable; computed in the python block below, integers only -> stable
# sort). The four levers correlate with a real shot per #1041's "less-saturated" thesis. score = sum of:
#   recency  : newer launched_at = less audit-time elapsed = less saturated. 40 * max(0, 1 - age_days/30),
#              i.e. 40 at launch, decaying linearly to 0 by 30 days old (a closed-ish window). [0..40]
#   prize    : a larger prize/TVL signal = more eyes worth it. 25 * min(1, log10(1+prize_usd)/7) — log-scaled
#              so $10M does not swamp every other lever; ~0 at $0, ~25 at >=$10M. [0..25]
#   platform : a fresh permissionless CONTEST (bug density highest day-1) outranks a permanent bounty.
#              contest -> 20, permanent -> 8, anything else -> 0. [0..20]
#   scope    : a SMALLER in-scope surface = higher finding density per unit effort. 15 * max(0, 1 - n/20),
#              where n = the scope_hint contract/file count (0 -> full 15, >=20 -> 0). [0..15]
# Max 100. Ties break by platform:id ascending (deterministic). A missing/garbled field contributes 0 for
# that lever (never crashes the rank). The score is advisory ranking only — it never gates a submission.
#
# This tool NEVER contacts a platform to SUBMIT. Discovery + ranking only; a queued target is a LEAD a human
# (or the #1055 batch runner) triages. Offline / no-network behaviour matches the sibling scripts.
#
# Usage: run-funnel.sh [--from <candidates.json>] [--min-score N] [--limit N] [-h]
#   --from      : read the candidate list from <file> (a JSON array of candidate objects) instead of the
#                 network. The deterministic path used by demo-funnel.sh and for reproducible runs.
#   --min-score : drop candidates scoring below N after ranking (default 0 = keep all).
#   --limit     : keep at most N top-ranked candidates (default 0 = no cap).
# Candidate object fields (all optional except a usable key): {platform,id,title,url,scope_hint,prize_hint,
#   launched_at,status,scope_count}. `platform` in {sherlock,cantina,code4rena,immunefi,...}; `status` must be
#   RUNNING to survive the freshness filter; `launched_at` an ISO-8601 / epoch hint; `prize_hint` a USD number
#   (bare or "$1,000,000"); `scope_count` the in-scope contract/file count (else inferred from scope_hint).
# Requires: python3. Outbound HTTPS only on the live (no --from) path. Exit 0 on success OR clean [SKIP];
# exit 2 on bad args.
set -u

DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"
LEDGER="$DIR/funnel-ledger.txt"
QUEUE="$DIR/targets.queue"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise
# crash on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "run-funnel.sh: $2 requires a value" >&2; exit 2; }; }
FROM="" ; MIN_SCORE="0" ; LIMIT="0"
while [ $# -gt 0 ]; do case "$1" in
  --from) nv "$#" "$1"; FROM="$2"; shift 2;;
  --min-score) nv "$#" "$1"; MIN_SCORE="$2"; shift 2;;
  --limit) nv "$#" "$1"; LIMIT="$2"; shift 2;;
  -h|--help) sed -n '2,48p' "$0"; exit 0;;
  *) echo "run-funnel.sh: unknown arg $1" >&2; exit 2;;
esac; done

command -v python3 >/dev/null || { echo "[SKIP] python3 not installed" >&2; exit 0; }
mkdir -p "$DIR"; touch "$LEDGER"

# ----------------------------------------------------------------------------------------------------------
# 1) DISCOVER -> a normalized candidate JSON array written to $RAW. --from reads it from a file; otherwise the
#    live path queries Sherlock (+ a best-effort Cantina/C4 probe). No --from AND no reachable source -> SKIP.
# ----------------------------------------------------------------------------------------------------------
RAW="$(mktemp "${TMPDIR:-/tmp}/funnel-raw.XXXXXX")"
trap 'rm -f "$RAW"' EXIT

if [ -n "$FROM" ]; then
  [ -r "$FROM" ] || { echo "run-funnel.sh: --from <file> not readable: $FROM" >&2; exit 2; }
  cp "$FROM" "$RAW"
else
  # Live discovery. Sherlock first (cleanest JSON; the contest-watch.sh items[] pattern). A network failure
  # leaves an empty array -> SKIP below rather than a false-empty queue.
  SHERLOCK="$(mktemp "${TMPDIR:-/tmp}/funnel-sherlock.XXXXXX")"
  CANTINA="$(mktemp "${TMPDIR:-/tmp}/funnel-cantina.XXXXXX")"
  C4="$(mktemp "${TMPDIR:-/tmp}/funnel-c4.XXXXXX")"
  trap 'rm -f "$RAW" "$SHERLOCK" "$CANTINA" "$C4"' EXIT
  GOT_NET=0
  if curl -sS --max-time 20 https://mainnet-contest.sherlock.xyz/contests -o "$SHERLOCK" 2>/dev/null \
       && [ -s "$SHERLOCK" ]; then GOT_NET=1; else echo '[]' > "$SHERLOCK"; fi
  # Best-effort permanent/permissionless probes (HTML SPAs — treat a keyword hit as "go look", low weight).
  curl -sS --max-time 20 -A 'Mozilla/5.0' https://cantina.xyz/competitions -o "$CANTINA" 2>/dev/null \
    && [ -s "$CANTINA" ] && GOT_NET=1 || : > "$CANTINA"
  curl -sS --max-time 20 -A 'Mozilla/5.0' https://code4rena.com/audits -o "$C4" 2>/dev/null \
    && [ -s "$C4" ] && GOT_NET=1 || : > "$C4"
  [ "$GOT_NET" -eq 1 ] || { echo "[SKIP] no network and no --from <candidates.json> — nothing to discover" >&2; exit 0; }
  # Normalize the live sources into the same candidate-array shape --from accepts.
  SHERLOCK="$SHERLOCK" CANTINA="$CANTINA" C4="$C4" python3 - > "$RAW" <<'PY'
import os, json
out = []
# --- Sherlock: a RUNNING contest per items[] entry (page 1 newest), normalized to the candidate schema. ---
try:
    d = json.load(open(os.environ["SHERLOCK"]))
except Exception:
    d = []
items = d if isinstance(d, list) else (d.get("items") if isinstance(d, dict) else [])
for c in (items or []):
    if not isinstance(c, dict):
        continue
    cid = c.get("id")
    out.append({
        "platform": "sherlock",
        "id": cid,
        "title": str(c.get("title", "")),
        "url": "https://audits.sherlock.xyz/contests/%s" % cid,
        "scope_hint": str(c.get("repo", c.get("scope", "")) or ""),
        "prize_hint": c.get("prize_pool", c.get("rewards", "")),
        "launched_at": c.get("starts_at", c.get("start_date", "")),
        "status": str(c.get("status", "")).upper(),
        "kind": "contest",
    })
# --- Cantina / Code4rena: a crude keyword probe -> ONE "go look" lead keyed by platform+date if the page
#     mentions an actively-open competition cluster. SPA/RSC pages give no clean JSON, so this is best-effort
#     and intentionally low-signal (the score's platform lever keeps it below a real contest). ---
import datetime
today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
KW = ("accepting submissions", "live competition", "submissions open", "active competition")
for plat, envk, base in (("cantina", "CANTINA", "https://cantina.xyz/competitions"),
                         ("code4rena", "C4", "https://code4rena.com/audits")):
    try:
        html = open(os.environ[envk], encoding="utf-8", errors="ignore").read()
    except Exception:
        html = ""
    if html and any(k in html.lower() for k in KW):
        out.append({
            "platform": plat,
            "id": "probe-%s" % today,
            "title": "%s: possible open competition (verify manually)" % plat,
            "url": base,
            "scope_hint": "",
            "prize_hint": "",
            "launched_at": today,
            "status": "RUNNING",
            "kind": "contest",
        })
print(json.dumps(out))
PY
fi

# ----------------------------------------------------------------------------------------------------------
# 2-5) FRESHNESS -> SELF-DEDUP -> SCORE -> EMIT. A single pure transform: drop status!=RUNNING, drop ledger
#      keys, score by the documented weighted sum, sort by score desc (then platform:id asc), emit the TSV.
# ----------------------------------------------------------------------------------------------------------
RAW="$RAW" LEDGER="$LEDGER" MIN_SCORE="$MIN_SCORE" LIMIT="$LIMIT" python3 - > "$QUEUE" <<'PY'
import os, json, math, re, datetime

raw_path = os.environ["RAW"]
ledger_path = os.environ["LEDGER"]
try:
    min_score = int(os.environ.get("MIN_SCORE", "0"))
except ValueError:
    min_score = 0
try:
    limit = int(os.environ.get("LIMIT", "0"))
except ValueError:
    limit = 0

NOW = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)  # naive UTC, for age arithmetic

try:
    cands = json.load(open(raw_path))
except Exception:
    cands = []
if not isinstance(cands, list):
    cands = []

# The ledger keys already-processed targets (key<TAB>verdict<TAB>ts). Read-only here; #1055 appends to it.
seen = set()
try:
    for line in open(ledger_path, encoding="utf-8", errors="ignore"):
        k = line.split("\t", 1)[0].strip()
        if k:
            seen.add(k)
except Exception:
    pass


def key_of(c):
    return "%s:%s" % (str(c.get("platform", "")).strip(), str(c.get("id", "")).strip())


def parse_launched(v):
    """A launched_at hint -> age in whole days (UTC). Accepts epoch seconds or an ISO-8601 date/datetime.
    Unparseable -> None (the recency lever then contributes 0, never a crash)."""
    if v is None or v == "":
        return None
    s = str(v).strip()
    # epoch seconds
    if re.fullmatch(r"\d{9,12}", s):
        try:
            dt = datetime.datetime.utcfromtimestamp(int(s[:10]))
        except Exception:
            return None
    else:
        iso = s.replace("Z", "").replace("T", " ").strip()
        dt = None
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d", "%Y/%m/%d"):
            try:
                dt = datetime.datetime.strptime(iso[:len(fmt) + 4], fmt)
                break
            except Exception:
                dt = None
        if dt is None:
            try:
                dt = datetime.datetime.strptime(iso[:10], "%Y-%m-%d")
            except Exception:
                return None
    age = (NOW - dt).total_seconds() / 86400.0
    return age


def parse_prize(v):
    """A prize/TVL hint -> a USD float. Accepts a number or strings like "$1,000,000" / "1.2M" / "500k"."""
    if v is None or v == "":
        return 0.0
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip().lower().replace("$", "").replace(",", "").replace("usd", "").strip()
    m = re.match(r"^([0-9]*\.?[0-9]+)\s*([kmb]?)", s)
    if not m:
        return 0.0
    n = float(m.group(1))
    return n * {"": 1, "k": 1e3, "m": 1e6, "b": 1e9}[m.group(2)]


def scope_count(c):
    """The in-scope contract/file count. Prefer an explicit scope_count; else count comma/newline-separated
    entries (or .sol mentions) in scope_hint; 0 if nothing usable (full scope lever credit)."""
    sc = c.get("scope_count")
    if isinstance(sc, (int, float)):
        return int(sc)
    if isinstance(sc, str) and sc.strip().isdigit():
        return int(sc.strip())
    hint = str(c.get("scope_hint", "") or "").strip()
    if not hint:
        return 0
    sols = len(re.findall(r"\.sol\b", hint))
    if sols:
        return sols
    parts = [p for p in re.split(r"[,\n;]+", hint) if p.strip()]
    return len(parts)


def score_of(c):
    # recency: 40 at launch, linear to 0 by 30 days old.
    age = parse_launched(c.get("launched_at"))
    recency = 0.0 if age is None else min(40.0, 40.0 * max(0.0, 1.0 - age / 30.0))
    # prize: log10-scaled, ~25 by $10M.
    prize = parse_prize(c.get("prize_hint"))
    prize_term = 25.0 * min(1.0, math.log10(1.0 + prize) / 7.0) if prize > 0 else 0.0
    # platform: a fresh contest outranks a permanent bounty.
    kind = str(c.get("kind", "")).strip().lower()
    plat = str(c.get("platform", "")).strip().lower()
    if kind == "contest" or plat in ("sherlock", "cantina", "code4rena"):
        plat_term = 20.0
    elif kind == "permanent" or plat in ("immunefi", "hats"):
        plat_term = 8.0
    else:
        plat_term = 0.0
    # scope: smaller surface = higher density. 15 at 0 contracts, 0 at >=20.
    n = scope_count(c)
    scope_term = min(15.0, 15.0 * max(0.0, 1.0 - n / 20.0))
    return int(round(recency + prize_term + plat_term + scope_term))


ranked = []
for c in cands:
    if not isinstance(c, dict):
        continue
    if str(c.get("status", "")).strip().upper() != "RUNNING":   # 2) FRESHNESS
        continue
    k = key_of(c)
    if k == ":" or k.endswith(":") or k.startswith(":"):
        continue
    if k in seen:                                               # 3) SELF-DEDUP
        continue
    s = score_of(c)                                            # 4) SCORE
    if s < min_score:
        continue
    title = str(c.get("title", "") or "").replace("\t", " ").replace("\n", " ").strip()
    url = str(c.get("url", "") or "").replace("\t", " ").strip()
    scope_hint = str(c.get("scope_hint", "") or "").replace("\t", " ").replace("\n", " ").strip()
    ranked.append((s, k, url, title, scope_hint))

# 5) EMIT: score DESC, then key ASC (deterministic tie-break).
ranked.sort(key=lambda r: (-r[0], r[1]))
if limit > 0:
    ranked = ranked[:limit]
for s, k, url, title, scope_hint in ranked:
    print("%d\t%s\t%s\t%s\t%s" % (s, k, url, title, scope_hint))
PY

# Mirror the queue to stdout (the file is the durable artifact; stdout is the live view).
cat "$QUEUE"
# grep -c prints the count (0 on no match) but exits 1 when empty; `|| true` keeps
# the single printed number instead of appending a second 0.
N="$(grep -c . "$QUEUE" 2>/dev/null || true)"
echo "run-funnel: ranked ${N:-0} candidate(s) -> $QUEUE" >&2
