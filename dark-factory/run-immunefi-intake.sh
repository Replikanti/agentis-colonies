#!/usr/bin/env bash
# run-immunefi-intake.sh — Immunefi bounty INTAKE + ranking over an OPERATOR-SUPPLIED programs file (#1506,
# epic #1505). Unlike run-funnel.sh (live Sherlock/Cantina/C4 probe, --from is the test escape hatch), Immunefi
# has NO live fetch path at all, ever: WebFetch is proven unreliable against Immunefi's SPA, and submission is
# human-gated anyway, so the operator maintains a small static programs JSON out-of-band and this tool ranks it.
# It emits the SAME 5-column TSV run-funnel.sh / prospector-queue.sh emit, so `run-batch.sh --queue <this>`
# consumes it with ZERO changes to run-batch.sh. Read-only: never contacts a platform, never submits.
#
# Usage: run-immunefi-intake.sh --programs <file> [--min-score N] [--limit N] [--out <file>]
#                               [--audit-delta <path>] [--dead-targets <file>] [-h]
#   --programs    : REQUIRED — a JSON array of program objects (schema below). No live fallback; missing /
#                   unreadable -> exit 2 (there is nothing to skip to, unlike run-funnel.sh's optional --from).
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
# FRESHNESS : keep only programs whose `status` is case-insensitively "active" (mirrors run-funnel.sh's RUNNING),
#             AND whose `<id>@<in_scope_commit>` key is NOT in the --dead-targets ledger (the #1562 loop closer).
# SCORE (integers, max 100; documented here so it is auditable, computed in the python block below):
#   bounty_term (0..70) : 70 * min(1, log10(1+reward_max_usd)/7) — log-scaled (so a $50M bounty does not swamp
#                         every other lever), reweighted UP since bounty is the dominant intake lever here.
#   delta_term  (0..30) : 0 when local_repo is absent / audit-delta.sh errors / files_changed==0 (NO-DELTA =
#                         nothing changed post-audit = no residual bonus). Else
#                         freshness (0..20) = 20 * max(0, 1 - latest_change_days_ago/60)
#                       + breadth   (0..10) = 10 * min(1, files_changed/10).
#   The levers SUM (never multiply) — consistent with run-funnel.sh / prospector-queue.sh's additive scoring; a
#   product would zero a strong bounty whenever local_repo is absent (the common case) and make the ranking
#   degenerate to "has a local clone or not". The score is advisory ranking only — it NEVER gates a submission.
# DEDUP  : by key `immunefi:<id>` (case-insensitive); keep the highest-scoring row on a collision.
# EMIT   : `score<TAB>immunefi:<id><TAB>url<TAB>name<TAB>scope_hint`, score DESC then key ASC. scope_hint packs
#          `chain:<chain> repo:<asset_repo> commit:<in_scope_commit> delta:<files>f/<days>d fee:<fee>
#          vault:<vault>` (preserves the fee/vault EV-gating data for a future evaluate stage without a 6th
#          column). Written to stdout AND --out.
#
# Requires: python3; git only reached indirectly via audit-delta.sh when a program carries a local_repo. No
# network, ever. Exit 0 on success; 2 on bad/missing args (including a missing --programs).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "run-immunefi-intake.sh: $2 requires a value" >&2; exit 2; }; }
PROGRAMS="" ; MIN_SCORE="0" ; LIMIT="0" ; OUT="$DIR/immunefi.queue" ; AUDIT_DELTA="$HERE/audit-delta.sh"
DEAD_TARGETS="$DIR/dead-targets.txt"
while [ $# -gt 0 ]; do case "$1" in
  --programs)     nv "$#" "$1"; PROGRAMS="$2"; shift 2;;
  --min-score)    nv "$#" "$1"; MIN_SCORE="$2"; shift 2;;
  --limit)        nv "$#" "$1"; LIMIT="$2"; shift 2;;
  --out)          nv "$#" "$1"; OUT="$2"; shift 2;;
  --audit-delta)  nv "$#" "$1"; AUDIT_DELTA="$2"; shift 2;;
  --dead-targets) nv "$#" "$1"; DEAD_TARGETS="$2"; shift 2;;
  -h|--help)      sed -n '2,54p' "$0"; exit 0;;
  *) echo "run-immunefi-intake.sh: unknown arg: $1" >&2; exit 2;;
esac; done

[ -n "$PROGRAMS" ] || { echo "run-immunefi-intake.sh: --programs <file> is required (no live Immunefi fetch)" >&2; exit 2; }
[ -r "$PROGRAMS" ] || { echo "run-immunefi-intake.sh: --programs <file> not readable: $PROGRAMS" >&2; exit 2; }

command -v python3 >/dev/null || { echo "[SKIP] python3 not installed" >&2; exit 0; }
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true

# ----------------------------------------------------------------------------------------------------------
# FRESHNESS (status==active) -> SCORE (bounty_term + delta_term) -> DEDUP (immunefi:<id>) -> EMIT the TSV. A
# pure transform over the operator's programs JSON; the only side channel is a read-only call to audit-delta.sh
# per program that carries a local_repo (git diff, no network). A malformed program contributes nothing; a
# missing/garbled field ranks at the appropriate lever's 0 (never crashes the rank).
# ----------------------------------------------------------------------------------------------------------
PROGRAMS="$PROGRAMS" MIN_SCORE="$MIN_SCORE" LIMIT="$LIMIT" AUDIT_DELTA="$AUDIT_DELTA" DEAD_TARGETS="$DEAD_TARGETS" python3 - > "$OUT" <<'PY'
import os, json, math, re, subprocess

programs_path = os.environ["PROGRAMS"]
audit_delta = os.environ.get("AUDIT_DELTA", "")
dead_targets_path = os.environ.get("DEAD_TARGETS", "")


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
    return int(round(bounty_term + delta_term))


try:
    progs = json.load(open(programs_path, encoding="utf-8", errors="ignore"))
except Exception:
    progs = []
if not isinstance(progs, list):
    progs = []

rows = []
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
PY

# Mirror the queue to stdout (the file is the durable artifact; stdout is the live view), matching run-funnel.
cat "$OUT"
N="$(grep -c . "$OUT" 2>/dev/null || true)"
echo "run-immunefi-intake: ranked ${N:-0} active program(s) by bounty + post-audit delta -> $OUT" >&2
echo "run-immunefi-intake: consume with  run-batch.sh --queue $OUT  (human reviews + submits; never auto-posted)" >&2
