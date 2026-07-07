#!/usr/bin/env bash
# prospector-queue.sh — turn the prospector colony's QUALIFIED dossiers into a bounty-ranked AUDIT QUEUE
# the batch runner consumes (#1459, epic #1455). The prospector qualifies EVM protocols as monitoring
# targets on three boolean hard gates (verified-source / value-invariant family / value-floor); the
# coordinator now also annotates each dossier with the active bounty's max reward + the in-scope commit
# (joined from operator-supplied PROSPECTOR_BOUNTY_META — read-only, no egress). This bridge ORDERS the
# operator's finite manual-review time by EXPECTED PAYOUT: expected earnings = P(finding) x bounty size x
# P(novel) x P(in-scope), and among already-qualified targets the bounty size is the dominant lever, so the
# queue is ranked by bounty DESC (ties broken by key ASC for determinism). The boolean gates stay the FLOOR
# — the bounty weight only ORDERS what already qualifies; a qualified target with no bounty metadata still
# lists, at score 0 (last).
#
# The emitted queue is EXACTLY run-batch.sh's format (`score<TAB>key<TAB>url<TAB>title<TAB>scope_hint`,
# highest score first), so `run-batch.sh --queue <this>` feeds the qualified targets through a hunt in
# payout order. The scope_hint carries `addr:<address>` (run-batch's autoharness resolver keys on it) and
# `commit:<in-scope-commit>` (audit exactly the version the bounty covers — the "audited the wrong version"
# 0-payout guard).
#
# Dossier source (one of):
#   --dossiers <file>  read qualified dossiers from a file (one dossier JSON per line). The offline /
#                      deterministic path used by demo-prospector-queue.sh and for reproducible runs.
#   default (live)     read them from the blackboard: `agentis memo get prospector:qualified` (the index)
#                      then `agentis memo get prospector:qualified:<addr>` per entry. No agentis / empty
#                      index -> `[SKIP]` + exit 0 (CI-safe, mirroring the sibling scripts).
#
# READ-ONLY: this tool reads memos / a file and writes a local queue file. It NEVER contacts a bounty
# platform, NEVER submits, and NEVER authenticates — bounty metadata is public program-page data the
# operator supplies out-of-band. A queued target is a LEAD a human (or run-batch.sh) triages.
#
# Usage: prospector-queue.sh [--dossiers <file>] [--out <file>] [--min-bounty N] [--limit N] [--agentis <bin>] [-h]
#   --dossiers    : read dossiers from <file> (JSONL) instead of the live blackboard.
#   --out         : queue output path (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/prospector.queue).
#                   Distinct from run-funnel.sh's targets.queue so the two intake paths never clobber.
#   --min-bounty  : drop qualified targets whose bounty is below N (default 0 = keep all, incl. no-bounty).
#   --limit       : keep at most N top-ranked targets (default 0 = no cap).
#   --agentis     : agentis binary for the live path (default `agentis` on PATH).
# Requires: python3 (JSON parse + stable rank). Exit 0 on success OR clean [SKIP]; exit 2 on bad args.
set -u

DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise
# crash on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "prospector-queue.sh: $2 requires a value" >&2; exit 2; }; }
DOSSIERS="" ; OUT="$DIR/prospector.queue" ; MIN_BOUNTY="0" ; LIMIT="0" ; AGENTIS="agentis"
while [ $# -gt 0 ]; do case "$1" in
  --dossiers)   nv "$#" "$1"; DOSSIERS="$2"; shift 2;;
  --out)        nv "$#" "$1"; OUT="$2"; shift 2;;
  --min-bounty) nv "$#" "$1"; MIN_BOUNTY="$2"; shift 2;;
  --limit)      nv "$#" "$1"; LIMIT="$2"; shift 2;;
  --agentis)    nv "$#" "$1"; AGENTIS="$2"; shift 2;;
  -h|--help)    sed -n '2,44p' "$0"; exit 0;;
  *) echo "prospector-queue.sh: unknown arg: $1" >&2; exit 2;;
esac; done

command -v python3 >/dev/null || { echo "[SKIP] python3 not installed" >&2; exit 0; }

# ----------------------------------------------------------------------------------------------------------
# 1) COLLECT the qualified dossiers into a JSONL temp ($RAW), one dossier JSON per line.
#    --dossiers reads them from a file; the live path pulls them off the blackboard via `agentis memo get`.
# ----------------------------------------------------------------------------------------------------------
RAW="$(mktemp "${TMPDIR:-/tmp}/prospector-queue.XXXXXX")"
trap 'rm -f "$RAW"' EXIT

if [ -n "$DOSSIERS" ]; then
  [ -r "$DOSSIERS" ] || { echo "prospector-queue.sh: --dossiers <file> not readable: $DOSSIERS" >&2; exit 2; }
  cp "$DOSSIERS" "$RAW"
else
  if ! command -v "$AGENTIS" >/dev/null 2>&1; then
    echo "[SKIP] agentis not on PATH and no --dossiers <file> — nothing to rank" >&2; exit 0
  fi
  # The rolled-up index lists one `<addr>|<family>` cell per qualifying target; pull each per-target dossier.
  INDEX="$("$AGENTIS" memo get "prospector:qualified" 2>/dev/null || true)"
  if [ -z "$INDEX" ]; then
    echo "[SKIP] empty prospector:qualified index (run the prospector colony first) — nothing to rank" >&2; exit 0
  fi
  : > "$RAW"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    addr="${entry%%|*}"
    [ -n "$addr" ] || continue
    d="$("$AGENTIS" memo get "prospector:qualified:$addr" 2>/dev/null || true)"
    [ -n "$d" ] && printf '%s\n' "$d" >> "$RAW"
  done <<< "$INDEX"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) FILTER (qualifies==true) -> RANK (bounty DESC, key ASC) -> EMIT run-batch's TSV. A pure transform over
#    the dossier JSONL, so the whole path is offline-testable. A malformed line contributes nothing (never
#    crashes the rank); a dossier with no/garbled bounty ranks at score 0.
# ----------------------------------------------------------------------------------------------------------
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
RAW="$RAW" MIN_BOUNTY="$MIN_BOUNTY" LIMIT="$LIMIT" python3 - > "$OUT" <<'PY'
import os, json, re

raw_path = os.environ["RAW"]
try:
    min_bounty = int(os.environ.get("MIN_BOUNTY", "0"))
except ValueError:
    min_bounty = 0
try:
    limit = int(os.environ.get("LIMIT", "0"))
except ValueError:
    limit = 0


def clean(s):
    """A TSV/label-safe field: no tabs or newlines (they would corrupt the queue's columns)."""
    return re.sub(r"[\t\r\n]+", " ", str(s or "")).strip()


def bounty_of(d):
    """The dossier bounty as an int USD figure; 0 when absent / non-numeric (ranks last, never crashes)."""
    b = str(d.get("bounty", "") or "").strip()
    return int(b) if b.isdigit() else 0


rows = []
try:
    lines = open(raw_path, encoding="utf-8", errors="ignore").read().splitlines()
except Exception:
    lines = []

for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    if d.get("qualifies") is not True:            # boolean gates remain the floor
        continue
    addr = clean(d.get("target", ""))
    if not addr:
        continue
    bounty = bounty_of(d)
    if bounty < min_bounty:
        continue
    chain = clean(d.get("chain", ""))
    commit = clean(d.get("commit", ""))
    watch = clean(d.get("watch", ""))
    label = clean(d.get("label", "")) or addr
    key = "prospector:%s" % addr
    url = ""                                       # no program-page URL (operator supplies bounty metadata)
    # scope_hint carries the address (run-batch's autoharness resolver keys on it) + the in-scope commit +
    # the suggested invariant to check.
    scope = "chain:%s addr:%s commit:%s watch:%s" % (chain or "?", addr, commit or "-", watch or "-")
    rows.append((bounty, key, url, label, scope))

# RANK: expected payout DESC (bounty), then key ASC (deterministic tie-break). run-batch consumes highest first.
rows.sort(key=lambda r: (-r[0], r[1]))
# DEDUP by key: an operator's dossier set may list the same target address more than once; keep the
# highest-bounty row (the first after the sort above) so a duplicate neither double-spends the operator's
# review budget nor under-ranks the target. The dedup key is CASE-INSENSITIVE to match the coordinator's
# case-insensitive bounty join — the same address under two casings (0xAbC… / 0xabc…) is one target, so it
# collapses to one row. run-batch also dedups on its ledger, but a clean queue is better.
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
for bounty, key, url, label, scope in rows:
    print("%d\t%s\t%s\t%s\t%s" % (bounty, key, url, label, scope))
PY

# Mirror the queue to stdout (the file is the durable artifact; stdout is the live view), matching run-funnel.
cat "$OUT"
N="$(grep -c . "$OUT" 2>/dev/null || true)"
echo "prospector-queue: ranked ${N:-0} qualified target(s) by bounty -> $OUT" >&2
echo "prospector-queue: consume with  run-batch.sh --queue $OUT  (human reviews + submits; never auto-posted)" >&2
