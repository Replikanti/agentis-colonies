#!/usr/bin/env bash
# run-immunefi-intake.sh — Immunefi bounty INTAKE + ranking (#1506, epic #1505). Two front doors into ONE shared
# ranking path: an OPERATOR-SUPPLIED programs file (--programs), OR public-API DISCOVERY (--live / --bounties,
# #1592). The discovery path fetches the read-only public bounties.json, MAPS each surviving program into the
# same operator-programs schema the ranking block below already consumes, then falls through the UNCHANGED
# freshness / dedup / TSV path — so --live is a fetch + schema-map in front of the proven ranker, not a fork.
# It emits the SAME 5-column TSV run-funnel.sh / prospector-queue.sh emit, so `run-batch.sh --queue <this>`
# consumes it with ZERO changes to run-batch.sh. Read-only: a plain unauthenticated public GET, never a write,
# never a submission.
#
# Usage: run-immunefi-intake.sh (--programs <file> | --live | --bounties <file>) [--url <endpoint>] [--floor <usd>]
#                               [--min-score N] [--limit N] [--out <file>] [--audit-delta <path>]
#                               [--dead-targets <file>] [--payinfo-out <file>] [-h]
#   --programs    : an OPERATOR-SUPPLIED JSON array of program objects (schema below). Missing / unreadable and
#                   no --live/--bounties -> exit 2. Mutually complementary with the discovery flags below.
#   --live        : DISCOVERY — fetch the public bounties.json from --url, MAP it into the programs schema, then
#                   rank it exactly like --programs. On ANY fetch failure / empty body -> `[SKIP]` + exit 0 with
#                   the queue UNTOUCHED (mirrors run-funnel.sh's no-network SKIP). Read-only GET; never submits.
#   --bounties    : the offline/test hatch for --live (mirrors run-funnel.sh's --from): read the raw bounties.json
#                   array from <file> instead of fetching, then map + rank identically. No network.
#   --url         : the bounties endpoint --live fetches (default https://immunefi.com/public-api/bounties.json);
#                   overridable for a mirror, or an unreachable host to exercise the offline SKIP.
#   --floor       : drop discovered programs whose maxBounty is below <usd> (default 10000) — prunes low-EV
#                   programs from the 6 MB feed before ranking. Applies to the discovery path only.
#   --min-score   : drop programs scoring below N after ranking (default 0 = keep all).
#   --limit       : keep at most N top-ranked programs (default 0 = no cap).
#   --out         : queue output path (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/immunefi.queue). A name
#                   distinct from targets.queue / prospector.queue so the three intake paths never clobber.
#   --audit-delta : path to audit-delta.sh (default: the sibling next to this script).
#   --dead-targets: path to the router's dead-targets ledger (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/
#                   dead-targets.txt, written by ingest-slack-outcome.sh's #1562 mark-dead action). A FRESHNESS-style
#                   skip (mirrors the status!=active drop): any program whose `<id>@<in_scope_commit>` key matches a
#                   dead-targets line's first (tab-separated) column is dropped, so a target the platform rejected
#                   out-of-scope / as a known-issue is never re-queued. The `target@commit` key contract holds when
#                   the operator's program `id` equals the `--target` passed to deliver-submission.sh (the fixture
#                   convention, e.g. `enzyme-onyx`); a missing / unreadable ledger drops nothing (no crash).
#   --payinfo-out : PAYABILITY sidecar path (default `<--out>.payinfo.json`, #1930). Written ONLY when at least
#                   one queued program resolved a pay_floor, so a run that resolves none produces no empty-file
#                   churn. Shape: `{"immunefi:<id>": {"pay_floor": "<sev>", "rewards": {"<sev>": <usd>, ...},
#                   "payable_impacts": ["<Severity>: <title>", ...]}}` — the free-text impact titles do not fit
#                   the 5-col TSV, so the queue carries only the machine-readable `payfloor:<sev>` token and the
#                   sidecar carries the rest. Consumed by run-zone-hunt.sh --pay-floor / --payable-impacts.
#
# Programs-file schema (a JSON array; all fields OPTIONAL except `id`):
#   {"id":"lombard","name":"Lombard Finance","url":"https://immunefi.com/bug-bounty/lombard/",
#    "chain":"ethereum","asset_repo":"https://github.com/example/lombard","in_scope_commit":"abc1234",
#    "reward_max_usd":250000,"submission_fee_usd":10,"vault_usd":40000,"status":"active",
#    "scope_hint":"contracts/Vault.sol, contracts/Oracle.sol",
#    "local_repo":"/path/to/an/operator-provided/local/clone"}
#   `local_repo` is OPTIONAL and used ONLY to compute the delta term via audit-delta.sh (never a network fetch —
#   the operator points it at a checkout they already have); absent / erroring -> delta term 0, never a crash.
#
# DISCOVERY (--live / --bounties, #1592): the inline python MAPPER below reads the raw bounties.json array and
#   keeps a program iff [ (language ∩ {Solidity,Vyper,Yul}) OR (ecosystem ∩ EVM chains: ethereum/arbitrum/
#   optimism/base/polygon/bsc/avalanche/…) ] AND not `inviteOnly` AND (no `endDate` OR endDate >= today) AND
#   maxBounty >= --floor. Each survivor maps to the programs schema above: slug->id, project->name, a constructed
#   bug-bounty url, ecosystem[0] (else language[0])->chain, a repo-looking assets[].url (else "-")->asset_repo,
#   maxBounty->reward_max_usd, status:"active"; plus live-only carries — `kyc` (bool, surfaced NOT filtered), a
#   precomputed `discovery_bonus` (int 0..30, net of the #1599 audit-density penalty) and the surfaced
#   `audit_density`/`competition_audited` signals. The mapper writes the mapped array to a temp file and points
#   PROGRAMS at it, so the SAME require/readable checks and ranking block run verbatim. A missing/garbled field
#   ranks at its lever's 0, never a crash (matches the operator path's rule).
#
# PAYABILITY (#1930, live-only): the mapper also derives, per program, the `pay_floor` — the LOWEST severity the
#   program actually PAYS (rank low<medium<high<critical; the lowest one whose max reward > 0) — and the
#   `payable_impacts`, the program's own published impact titles at or above that floor. The derivation is
#   SHAPE-TOLERANT (the feed's reward key names are not pinned in this repo): a recursive walk collects
#   (severity, amount) pairs wherever a dict carries a key matching /severity|level/i with a value in
#   {critical,high,medium,low} and a sibling key matching /amount|usd|payout|reward|max/i (the proven
#   walk_next_data() shape from bounty-payability-gate.sh); where an asset-type-ish key exists only
#   `smart_contract` entries count, and an entry with NO asset-type key at all is kept (fail-open). If the
#   structured walk yields nothing, a free-text `rewardsBody` scan (mirroring bounty-payability-gate.sh's
#   rewards_from_body()) is the fallback. NOTHING RESOLVABLE => no floor asserted: no `payfloor:` token, no
#   sidecar row, never a crash (the file's "a missing field contributes 0" rule). WHY it matters: a Medium
#   finding on a program whose rewards table starts at High earns $0, so the floor is what makes the hunt spend
#   its depth on PAYABLE severities, and the impact titles are the targeting signal for WHICH lens pays.
#
# FRESHNESS : keep only programs whose `status` is case-insensitively "active" (mirrors run-funnel.sh's RUNNING),
#             AND whose `<id>@<in_scope_commit>` key is NOT in the --dead-targets ledger (the #1562 loop closer).
# SCORE (integers, max 100; documented here so it is auditable, computed in the python block below):
#   bounty_term (0..70) : 70 * min(1, log10(1+reward_max_usd)/7) — log-scaled (so a $50M bounty does not swamp
#                         every other lever), reweighted UP since bounty is the dominant intake lever here.
#   delta_term  (0..30) : 0 when local_repo is absent / audit-delta.sh errors / files_changed==0 (NO-DELTA =
#                         nothing changed post-audit = no residual bonus). Else
#                         freshness (0..20) = 20 * max(0, 1 - latest_change_days_ago/60)
#                       + breadth   (0..10) = 10 * min(1, files_changed/10).
#   discovery_bonus (0..30) : live-only, PRECOMPUTED by the mapper (absent -> 0 on operator programs, so operator
#                         ranks are byte-identical). = freshness (0..15, linear decay from the most-recent of
#                         launchDate/updatedDate) + audit_scarcity (0..8 = 8*max(0,1-n_audits/4)) + accounting_fit
#                         (0..7, a keyword hit vault/lending/stablecoin/swap/amm/yield/staking/collateral)
#                         MINUS audit_penalty, clamped >=0. audit_penalty (#1599): each competition/contest
#                         reference (immunefi audit-competition, sherlock/cantina/code4rena/codehawks/hats) found
#                         in knownIssues/programOverview/description/rewardsBody = -15; each named auditor firm
#                         (spearbit, trail of bits, certora, halborn, cyfrin, zellic, ...) = -3,
#                         capped -9. So a competition-hardened target ranks BELOW a genuinely-unaudited one of
#                         equal bounty: a fresh launch date and an empty `audits` array do NOT mean unaudited — a
#                         prior audit competition / heavy auditor coverage = hardened, low-EV. delta_term and
#                         discovery_bonus are mutually exclusive in practice (live carries no local_repo) so the
#                         per-path ceiling stays 100.
#   The levers SUM (never multiply) — consistent with run-funnel.sh / prospector-queue.sh's additive scoring; a
#   product would zero a strong bounty whenever local_repo is absent (the common case) and make the ranking
#   degenerate to "has a local clone or not". The score is advisory ranking only — it NEVER gates a submission.
# DEDUP  : by key `immunefi:<id>` (case-insensitive); keep the highest-scoring row on a collision.
# EMIT   : `score<TAB>immunefi:<id><TAB>url<TAB>name<TAB>scope_hint`, score DESC then key ASC. scope_hint packs
#          `chain:<chain> repo:<asset_repo> commit:<in_scope_commit> delta:<files>f/<days>d fee:<fee>
#          vault:<vault>` (preserves the fee/vault EV-gating data for a future evaluate stage without a 6th
#          column). On the live path col 5 also carries `kyc:<yes|no> aud:<n> comp:<yes|no>` (n = audit_density =
#          competition + named-firm hits) and, when one resolved, `payfloor:<sev>` (#1930) — the flags ride
#          INSIDE scope_hint, so the row stays exactly 5 columns. Written to stdout AND --out. The free-text
#          payable impact titles go to the --payinfo-out sidecar, never into the TSV.
#
# Requires: python3; curl only on the --live path (a read-only public GET); git only reached indirectly via
# audit-delta.sh when a program carries a local_repo. Exit 0 on success or a clean [SKIP] (no network on --live);
# 2 on bad/missing args (none of --programs / --live / --bounties).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "run-immunefi-intake.sh: $2 requires a value" >&2; exit 2; }; }
PROGRAMS="" ; MIN_SCORE="0" ; LIMIT="0" ; OUT="$DIR/immunefi.queue" ; AUDIT_DELTA="$HERE/audit-delta.sh"
DEAD_TARGETS="$DIR/dead-targets.txt"
# #1930: empty = "derive it from --out" (resolved after the flag walk, so --out order does not matter).
PAYINFO_OUT=""
LIVE="" ; BOUNTIES="" ; URL="https://immunefi.com/public-api/bounties.json" ; FLOOR="10000" ; MAX_TIME="30"
while [ $# -gt 0 ]; do case "$1" in
  --programs)     nv "$#" "$1"; PROGRAMS="$2"; shift 2;;
  --live)         LIVE="1"; shift;;
  --bounties)     nv "$#" "$1"; BOUNTIES="$2"; shift 2;;
  --url)          nv "$#" "$1"; URL="$2"; shift 2;;
  --floor)        nv "$#" "$1"; FLOOR="$2"; shift 2;;
  --min-score)    nv "$#" "$1"; MIN_SCORE="$2"; shift 2;;
  --limit)        nv "$#" "$1"; LIMIT="$2"; shift 2;;
  --out)          nv "$#" "$1"; OUT="$2"; shift 2;;
  --audit-delta)  nv "$#" "$1"; AUDIT_DELTA="$2"; shift 2;;
  --dead-targets) nv "$#" "$1"; DEAD_TARGETS="$2"; shift 2;;
  --payinfo-out)  nv "$#" "$1"; PAYINFO_OUT="$2"; shift 2;;
  -h|--help)      sed -n '2,113p' "$0"; exit 0;;
  *) echo "run-immunefi-intake.sh: unknown arg: $1" >&2; exit 2;;
esac; done
# #1930: the sidecar rides next to the queue by default, so the two artifacts of one intake stay together.
[ -n "$PAYINFO_OUT" ] || PAYINFO_OUT="$OUT.payinfo.json"

# DISCOVERY (#1592): --live fetches the public bounties.json, --bounties reads a raw array from a file (the
# offline/test hatch). Either way the MAPPER transforms the raw array into the operator-programs schema, writes
# it to a temp file, and points PROGRAMS at it — so the require/readable checks + the whole ranking block below
# run VERBATIM. A fetch failure / empty body -> [SKIP] + exit 0 with the queue untouched (no ranking block runs).
if [ -n "$LIVE" ] || [ -n "$BOUNTIES" ]; then
  command -v python3 >/dev/null || { echo "[SKIP] python3 not installed" >&2; exit 0; }
  RAW="$(mktemp "${TMPDIR:-/tmp}/immunefi-raw.XXXXXX")"
  MAPPED="$(mktemp "${TMPDIR:-/tmp}/immunefi-mapped.XXXXXX")"
  trap 'rm -f "$RAW" "$MAPPED"' EXIT
  if [ -n "$BOUNTIES" ]; then
    [ -r "$BOUNTIES" ] || { echo "run-immunefi-intake.sh: --bounties <file> not readable: $BOUNTIES" >&2; exit 2; }
    cp "$BOUNTIES" "$RAW"
  else
    curl -sS --max-time "$MAX_TIME" "$URL" -o "$RAW" 2>/dev/null || :
    [ -s "$RAW" ] || { echo "[SKIP] --live: no network / empty response from $URL — nothing to discover" >&2; exit 0; }
  fi
  # MAPPER: raw bounties.json array -> filtered + mapped operator-programs array (JSON only, never shell parsing).
  FLOOR="$FLOOR" python3 - "$RAW" "$MAPPED" <<'PY'
import sys, json, re, datetime

raw_path, mapped_path = sys.argv[1], sys.argv[2]
try:
    floor = float(__import__("os").environ.get("FLOOR", "10000") or 0)
except ValueError:
    floor = 10000.0

EVM = {"ethereum", "arbitrum", "optimism", "base", "polygon", "matic", "bsc", "binance", "avalanche", "avax",
       "fantom", "gnosis", "xdai", "scroll", "linea", "zksync", "mantle", "blast", "mode", "celo", "moonbeam",
       "aurora", "metis", "fraxtal", "manta", "opbnb", "kava", "canto", "core", "sonic", "berachain"}
LANGS = {"solidity", "vyper", "yul"}
ACCT = ("vault", "lending", "stablecoin", "swap", "amm", "yield", "staking", "collateral")
# AUDIT-DENSITY penalty (#1599): a fresh launchDate + an empty structured `audits` array can hide a heavily-
# hardened codebase — a prior audit COMPETITION and/or named-firm reviews whose evidence lives in the program's
# TEXT (knownIssues/programOverview/description), not the `audits` count. COMP = high-precision contest-platform /
# audit-competition signals; FIRMS = named auditor firms. Deliberately NO short/ambiguous tokens (no bare `c4`,
# `macro`, `hats`, `oak`, or the bare word `audit`) NOR library/tooling names that aren't audit attribution
# (`openzeppelin`/`consensys` are ubiquitous Solidity library/tooling mentions, not evidence of an audit —
# excluded per #1606; the audit arm `consensys diligence` is kept) so common prose never false-hits. Generic
# public firm / contest-platform names only — no client or sensitive names.
COMP = ("audit-competition", "audit competition", "audit contest", "sherlock", "cantina", "code4rena",
        "code-423n4", "codehawks", "hats.finance", "hats finance")
FIRMS = ("spearbit", "trail of bits", "trailofbits", "yaudit", "yacademy",
         "certora", "halborn", "cyfrin", "zellic", "consensys diligence", "quantstamp",
         "sigma prime", "sigmaprime", "dedaub", "chainsecurity", "pashov", "guardian audits", "hexens",
         "0xmacro", "peckshield", "slowmist", "oak security", "ackee")
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


# --- PAYABILITY derivation (#1930) -------------------------------------------------------------------------
# The feed's reward/impact key NAMES are not pinned in this repo, so both walks match keys by REGEX and tolerate
# nesting — the same shape bounty-payability-gate.sh's walk_next_data() already uses on __NEXT_DATA__ trees.
SEV_KEY = re.compile(r"severity|level", re.I)
AMT_KEY = re.compile(r"amount|usd|payout|reward|max", re.I)
ASSET_KEY = re.compile(r"asset.?type|assetstype|^type$", re.I)
IMPACT_KEY = re.compile(r"impact", re.I)
TITLE_KEYS = ("title", "impact", "name", "description")
SEV_VALUES = ("critical", "high", "medium", "low")
SEV_RANK = {"low": 1, "medium": 2, "high": 3, "critical": 4}
MAX_IMPACTS = 20
MAX_IMPACT_CHARS = 200


def is_smart_contract(v):
    """`Smart Contract` / `smart_contract` / `smart-contract` all normalise to the same token."""
    return "smart_contract" in re.sub(r"[^a-z0-9]+", "_", str(v or "").lower())


def walk_rewards(node, found):
    """Collect {severity: max usd} wherever a dict carries a severity-ish key with a known severity value AND a
    sibling amount-ish key. Where the SAME dict also carries an asset-type-ish key, only smart_contract entries
    count; a dict with NO asset-type key at all is kept (fail-open — an over-strict filter would silently assert
    'this program pays nothing', the one verdict that must never be invented)."""
    if isinstance(node, dict):
        sev_val = None
        amt_val = None
        asset_ok = True
        for k, v in node.items():
            if SEV_KEY.search(k) and isinstance(v, str) and v.strip().lower() in SEV_VALUES:
                sev_val = v.strip().lower()
            if AMT_KEY.search(k) and isinstance(v, (int, float, str)):
                cand = usd(v)
                if cand > 0:
                    amt_val = max(amt_val or 0.0, cand)
            if ASSET_KEY.search(k) and isinstance(v, str) and v.strip():
                asset_ok = is_smart_contract(v)
        if sev_val is not None and amt_val is not None and asset_ok:
            if amt_val > found.get(sev_val, 0.0):
                found[sev_val] = amt_val
        for v in node.values():
            walk_rewards(v, found)
    elif isinstance(node, list):
        for v in node:
            walk_rewards(v, found)


def rewards_from_body(text):
    """Free-text `rewardsBody` fallback — mirrors bounty-payability-gate.sh's rewards_from_body() verbatim:
    scan for `<Severity>: ... $<amount>` mentions; never invents an entry for a severity that is not mentioned."""
    out = {}
    if not text:
        return out
    for sev in SEV_VALUES:
        for m in re.finditer(sev, text, re.I):
            tail = text[m.end():m.end() + 80]
            am = re.search(r"\$?\s*([0-9][0-9,]*\.?[0-9]*)\s*([kmb]?)\b", tail, re.I)
            if am:
                val = usd(am.group(1) + am.group(2))
                if val > out.get(sev, 0.0):
                    out[sev] = val
    return out


def rewards_of(b):
    """{severity: max usd} for a program: the structured walk first, the rewardsBody scan as the fallback."""
    found = {}
    for key in b:
        if re.search(r"reward|bount|payout", key, re.I) and isinstance(b[key], (dict, list)):
            walk_rewards(b[key], found)
    if not found:
        walk_rewards(b, found)
    if not found:
        found = rewards_from_body(str(b.get("rewardsBody") or ""))
    return {s: a for s, a in found.items() if a > 0}


def pay_floor_of(rewards):
    """The LOWEST severity by rank whose max reward is > 0; "" when nothing resolved (no floor asserted)."""
    ranked = sorted((SEV_RANK[s], s) for s in rewards if s in SEV_RANK)
    return ranked[0][1] if ranked else ""


def impact_title(entry):
    """A published impact entry -> its title. A plain string IS the title; a dict yields its first title-ish
    non-empty string field. Anything else contributes nothing (never a stringified dict)."""
    if isinstance(entry, str):
        return entry.strip()
    if isinstance(entry, dict):
        for k in TITLE_KEYS:
            for kk, vv in entry.items():
                if kk.lower() == k and isinstance(vv, str) and vv.strip():
                    return vv.strip()
    return ""


def impact_severity(entry):
    if isinstance(entry, dict):
        for k, v in entry.items():
            if SEV_KEY.search(k) and isinstance(v, str) and v.strip().lower() in SEV_VALUES:
                return v.strip().lower()
    return ""


def walk_impacts(node, out):
    """Every element of every `impacts`-ish list anywhere in the program object (the feed nests them per asset
    type on some shapes), in document order."""
    if isinstance(node, dict):
        for k, v in node.items():
            if IMPACT_KEY.search(k) and isinstance(v, list):
                out.extend(v)
            walk_impacts(v, out)
    elif isinstance(node, list):
        for v in node:
            walk_impacts(v, out)


def payable_impacts_of(b, floor):
    """The program's OWN published impact titles at or above the pay floor, as `"<Severity>: <title>"` (or the
    bare title when the entry claims no severity — a title that makes no severity claim is SURFACED, not
    filtered). Deduped, order-preserving, capped; scrubbed of tabs/newlines/NUL so it is TSV/JSON-safe."""
    floor_rank = SEV_RANK.get(floor, 0)
    entries = []
    walk_impacts(b, entries)
    out, seen = [], set()
    for e in entries:
        title = re.sub(r"[\t\r\n\x00]+", " ", impact_title(e)).strip()[:MAX_IMPACT_CHARS].strip()
        if not title:
            continue
        sev = impact_severity(e)
        if sev and SEV_RANK[sev] < floor_rank:
            continue
        label = ("%s: %s" % (sev.capitalize(), title)) if sev else title
        if label.lower() in seen:
            continue
        seen.add(label.lower())
        out.append(label)
        if len(out) >= MAX_IMPACTS:
            break
    return out


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

out = []
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
    # asset_repo: first assets[].url that looks like a code host, else "-".
    repo = "-"
    for a in as_list(b.get("assets")):
        u = a.get("url") if isinstance(a, dict) else a
        if looks_like_repo(u):
            repo = str(u)
            break
    chain = (ecos[0] if ecos else (langs[0] if langs else "")) or "?"
    # discovery_bonus = freshness (0..15) + audit_scarcity (0..8) + accounting_fit (0..7).
    dates = [d for d in (parse_date(b.get("launchDate")), parse_date(b.get("updatedDate"))) if d is not None]
    if dates:
        days_ago = (today - max(dates)).days
        freshness = 15.0 * max(0.0, 1.0 - days_ago / 180.0)
    else:
        freshness = 0.0
    n_audits = len(as_list(b.get("audits")))
    audit_scarcity = 8.0 * max(0.0, 1.0 - n_audits / 4.0)
    acct_blob = (str(b.get("project") or "") + " " + " ".join(str(x) for x in as_list(b.get("impacts")))).lower()
    accounting_fit = 7.0 if any(k in acct_blob for k in ACCT) else 0.0
    # AUDIT-DENSITY penalty (#1599): scan the TEXT fields (never the structured `audits` count) for competition /
    # named-firm evidence. json.dumps(..., default=str) flattens nested lists/dicts/URLs into one lowercase
    # substring-searchable blob and never crashes on absent fields (they serialize as `null`).
    audit_blob = json.dumps(
        [b.get(k) for k in ("knownIssues", "programOverview", "description", "rewardsBody", "audits", "impacts")],
        default=str, ensure_ascii=False).lower()
    comp_hits = sum(1 for k in COMP if k in audit_blob)
    firm_hits = sum(1 for k in FIRMS if k in audit_blob)
    competition_audited = comp_hits > 0
    audit_density = comp_hits + firm_hits
    penalty = (15 if comp_hits else 0) + min(9, 3 * firm_hits)
    # Fold the penalty into the live-only bonus and clamp at 0 so it is a BOUNDED reduction, never negative (a
    # negative bonus would corrupt the additive score / DESC sort). score_of is untouched: absent on operator
    # programs -> +0, so the operator-path score stays byte-identical.
    discovery_bonus = int(round(max(0.0, freshness + audit_scarcity + accounting_fit - penalty)))
    # #1930 PAYABILITY: nothing resolvable -> pay_floor "" -> no scope token, no sidecar row, no crash.
    pay_rewards = rewards_of(b)
    pay_floor = pay_floor_of(pay_rewards)
    payable_impacts = payable_impacts_of(b, pay_floor) if pay_floor else []
    out.append({
        "id": slug,
        "name": str(b.get("project") or slug),
        "url": "https://immunefi.com/bug-bounty/%s/" % slug,
        "chain": chain,
        "asset_repo": repo,
        "in_scope_commit": "",
        "reward_max_usd": reward,
        "status": "active",
        "kyc": bool(b.get("kyc")),
        "discovery_bonus": discovery_bonus,
        "audit_density": audit_density,
        "competition_audited": competition_audited,
        "pay_floor": pay_floor,
        "pay_rewards": pay_rewards,
        "payable_impacts": payable_impacts,
    })

json.dump(out, open(mapped_path, "w", encoding="utf-8"))
PY
  PROGRAMS="$MAPPED"
fi

[ -n "$PROGRAMS" ] || { echo "run-immunefi-intake.sh: one of --programs <file> / --live / --bounties <file> is required" >&2; exit 2; }
[ -r "$PROGRAMS" ] || { echo "run-immunefi-intake.sh: --programs <file> not readable: $PROGRAMS" >&2; exit 2; }

command -v python3 >/dev/null || { echo "[SKIP] python3 not installed" >&2; exit 0; }
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true

# ----------------------------------------------------------------------------------------------------------
# FRESHNESS (status==active) -> SCORE (bounty_term + delta_term) -> DEDUP (immunefi:<id>) -> EMIT the TSV. A
# pure transform over the operator's programs JSON; the only side channel is a read-only call to audit-delta.sh
# per program that carries a local_repo (git diff, no network). A malformed program contributes nothing; a
# missing/garbled field ranks at the appropriate lever's 0 (never crashes the rank).
# ----------------------------------------------------------------------------------------------------------
PROGRAMS="$PROGRAMS" MIN_SCORE="$MIN_SCORE" LIMIT="$LIMIT" AUDIT_DELTA="$AUDIT_DELTA" DEAD_TARGETS="$DEAD_TARGETS" \
PAYINFO_OUT="$PAYINFO_OUT" python3 - > "$OUT" <<'PY'
import os, json, math, re, subprocess

programs_path = os.environ["PROGRAMS"]
audit_delta = os.environ.get("AUDIT_DELTA", "")
dead_targets_path = os.environ.get("DEAD_TARGETS", "")
payinfo_out = os.environ.get("PAYINFO_OUT", "")


def load_dead_keys(path):
    """The set of `target@commit` keys the #1562 router marked dead (first tab-separated column of each line).
    Missing / unreadable ledger -> an empty set (drops nothing, never crashes)."""
    keys = set()
    if not path or not os.path.exists(path):
        return keys
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                key = line.split("\t", 1)[0].strip()
                if key:
                    keys.add(key.lower())
    except Exception:
        return set()
    return keys


dead_keys = load_dead_keys(dead_targets_path)
try:
    min_score = int(os.environ.get("MIN_SCORE", "0"))
except ValueError:
    min_score = 0
try:
    limit = int(os.environ.get("LIMIT", "0"))
except ValueError:
    limit = 0


def clean(s):
    """A TSV/label-safe field: no tabs or newlines (they would corrupt the queue's columns)."""
    return re.sub(r"[\t\r\n]+", " ", str(s or "")).strip()


def usd(v):
    """A USD figure -> float. Accepts a number or strings like "$250,000" / "1.2M" / "50k"; 0 when unusable."""
    if v is None or v == "":
        return 0.0
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip().lower().replace("$", "").replace(",", "").replace("usd", "").strip()
    m = re.match(r"^([0-9]*\.?[0-9]+)\s*([kmb]?)", s)
    if not m:
        return 0.0
    return float(m.group(1)) * {"": 1, "k": 1e3, "m": 1e6, "b": 1e9}[m.group(2)]


def delta_of(p):
    """(files_changed, days_ago) for a program via audit-delta.sh, when it carries a local_repo + in_scope_commit.
    ANY failure (no local_repo, missing audit-delta, bad repo/since exit 3, NO-DELTA, unparseable) -> (0, None):
    the delta term then contributes 0, never a crash (matches the 'missing field contributes 0' rule)."""
    repo = str(p.get("local_repo", "") or "").strip()
    since = str(p.get("in_scope_commit", "") or "").strip()
    if not repo or not since or not audit_delta or not os.path.exists(audit_delta):
        return 0, None
    try:
        r = subprocess.run(["bash", audit_delta, "--repo", repo, "--since", since],
                           capture_output=True, text=True, timeout=60)
        if r.returncode != 0 or not r.stdout.strip():
            return 0, None
        d = json.loads(r.stdout.strip())
        n = int(d.get("files_changed", 0) or 0)
        days = d.get("latest_change_days_ago")
        days = int(days) if isinstance(days, (int, float)) else None
        return (n, days) if n > 0 else (0, None)
    except Exception:
        return 0, None


def score_of(p, files, days):
    reward = usd(p.get("reward_max_usd"))
    bounty_term = 70.0 * min(1.0, math.log10(1.0 + reward) / 7.0) if reward > 0 else 0.0
    if files > 0:
        freshness = 20.0 * max(0.0, 1.0 - (days / 60.0)) if days is not None else 0.0
        breadth = 10.0 * min(1.0, files / 10.0)
        delta_term = freshness + breadth
    else:
        delta_term = 0.0
    # discovery_bonus: live-only, precomputed by the #1592 mapper; absent on operator programs -> +0 (so the
    # operator-path score is byte-identical to before this hook existed).
    return int(round(bounty_term + delta_term + int(p.get("discovery_bonus", 0) or 0)))


try:
    progs = json.load(open(programs_path, encoding="utf-8", errors="ignore"))
except Exception:
    progs = []
if not isinstance(progs, list):
    progs = []

rows = []
payinfo = {}   # #1930: `immunefi:<id>` -> the payability sidecar row, filled only for a RESOLVED pay_floor.
for p in progs:
    if not isinstance(p, dict):
        continue
    if str(p.get("status", "")).strip().lower() != "active":     # FRESHNESS
        continue
    pid = clean(p.get("id", ""))
    if not pid:
        continue
    commit_key = clean(p.get("in_scope_commit", ""))
    if ("%s@%s" % (pid, commit_key)).lower() in dead_keys:        # FRESHNESS: skip router-marked-dead targets
        continue
    files, days = delta_of(p)
    s = score_of(p, files, days)
    if s < min_score:
        continue
    key = "immunefi:%s" % pid
    url = clean(p.get("url", ""))
    name = clean(p.get("name", "")) or pid
    chain = clean(p.get("chain", "")) or "?"
    repo = clean(p.get("asset_repo", "")) or "-"
    commit = clean(p.get("in_scope_commit", "")) or "-"
    fee = usd(p.get("submission_fee_usd"))
    vault = usd(p.get("vault_usd"))
    daystr = ("%dd" % days) if days is not None else "-d"
    scope = "chain:%s repo:%s commit:%s delta:%df/%s fee:%s vault:%s" % (
        chain, repo, commit, files, daystr,
        ("%d" % fee) if fee else "-", ("%d" % vault) if vault else "-")
    # kyc: live-only carry from the #1592 mapper; surfaced (never a filter). Absent on operator programs -> the
    # scope_hint is unchanged (still 5 columns; the flag rides inside the scope_hint field).
    if "kyc" in p:
        scope += " kyc:%s" % ("yes" if p.get("kyc") else "no")
    # audit-density (#1599): live-only carries from the mapper, surfaced inside scope_hint col 5 (never a filter;
    # keeps the TSV at 5 columns). Absent on operator programs -> scope_hint unchanged (byte-identical operator TSV).
    if "audit_density" in p:
        scope += " aud:%d" % int(p.get("audit_density", 0) or 0)
    if "competition_audited" in p:
        scope += " comp:%s" % ("yes" if p.get("competition_audited") else "no")
    # payfloor (#1930): the LOWEST severity this program actually pays. Live-only, and only when the mapper
    # RESOLVED one — an unresolved floor emits NO token, so a row whose reward data is absent/garbled looks
    # exactly like a pre-#1930 row and nothing downstream can mistake "unknown" for "pays everything".
    pay_floor = str(p.get("pay_floor", "") or "").strip().lower()
    if pay_floor:
        scope += " payfloor:%s" % pay_floor
        payinfo[key] = {
            "pay_floor": pay_floor,
            "rewards": p.get("pay_rewards", {}) if isinstance(p.get("pay_rewards"), dict) else {},
            "payable_impacts": [clean(t) for t in (p.get("payable_impacts") or []) if clean(t)],
        }
    rows.append((s, key, url, name, scope))

# RANK: score DESC, then key ASC (deterministic tie-break). run-batch consumes highest first.
rows.sort(key=lambda r: (-r[0], r[1].lower()))
# DEDUP by key (case-insensitive): an operator's programs file may list the same program twice; keep the
# highest-scoring row (the first after the sort above). No persistent ledger — the Immunefi source is a small,
# operator-refreshed static file, and run-batch.sh's own ledger already prevents re-processing a triaged target.
seen = set()
deduped = []
for r in rows:
    k = r[1].lower()
    if k in seen:
        continue
    seen.add(k)
    deduped.append(r)
rows = deduped
if limit > 0:
    rows = rows[:limit]
for s, key, url, name, scope in rows:
    print("%d\t%s\t%s\t%s\t%s" % (s, key, url, name, scope))

# PAYABILITY SIDECAR (#1930): mirrors EXACTLY the rows that survived rank/dedup/limit, so the sidecar and the
# queue can never disagree about which targets were queued. Written ONLY when at least one row resolved a
# pay_floor — a run that resolves none leaves no empty file behind. A write failure is never fatal: the queue
# (the durable artifact run-batch.sh consumes) is already on stdout by this point.
emitted = {key for _s, key, _u, _n, _sc in rows}
payinfo = {k: v for k, v in payinfo.items() if k in emitted}
if payinfo and payinfo_out:
    try:
        d = os.path.dirname(payinfo_out)
        if d:
            os.makedirs(d, exist_ok=True)
        with open(payinfo_out, "w", encoding="utf-8") as fh:
            json.dump(payinfo, fh, indent=2, sort_keys=True)
            fh.write("\n")
    except Exception as exc:
        import sys
        sys.stderr.write("run-immunefi-intake: could not write the payability sidecar %s (%s); the queue is "
                         "unaffected\n" % (payinfo_out, exc.__class__.__name__))
PY

# Mirror the queue to stdout (the file is the durable artifact; stdout is the live view), matching run-funnel.
cat "$OUT"
N="$(grep -c . "$OUT" 2>/dev/null || true)"
echo "run-immunefi-intake: ranked ${N:-0} active program(s) by bounty + post-audit delta -> $OUT" >&2
# #1930: name the sidecar when one was written, so the operator knows where the pay floor + payable impacts are.
[ -s "$PAYINFO_OUT" ] && echo "run-immunefi-intake: payability sidecar (pay_floor + payable impacts) -> $PAYINFO_OUT" >&2
echo "run-immunefi-intake: consume with  run-batch.sh --queue $OUT  (human reviews + submits; never auto-posted)" >&2
