#!/usr/bin/env bash
# apply-audit-density.sh — FRESHNESS-FIRST DE-RANK by target audit-density (#1898, epic #1894 M2). A queue ->
# queue RE-RANK (never a gate — every input row survives, only the ORDER changes): for each row whose
# scope_hint (col 5) carries a resolvable `repo:<value>` token, runs audit-history-probe.sh (reused VERBATIM,
# via a --probe-cmd seam mirroring run-batch.sh's --hunt-cmd) and subtracts a flat bounded penalty from the
# row's score when the probe verdict is `heavily_audited=true`, then re-sorts DESC-then-key-ASC — the same
# tie-break run-immunefi-intake.sh already uses. A heavily-picked-over target sinks below an equally-scored
# fresh one without ever being dropped from the queue.
#
# Usage: apply-audit-density.sh --queue <file> [--probe-cmd "<cmd>"] [--penalty N] [--out <file>] [-h]
#   --queue      : the 5-col TSV to re-rank (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/immunefi.queue,
#                  the same default run-immunefi-intake.sh writes, so the two chain with zero extra flags).
#   --probe-cmd  : the seam, mirroring run-batch.sh's --hunt-cmd idiom: PROBE_REPO=<row's extracted repo> is
#                  set in env, then `sh -c "$PROBE_CMD"` runs and its stdout is captured. Default (no
#                  --probe-cmd): `"$HERE/audit-history-probe.sh \"\$PROBE_REPO\""` — audit-history-probe.sh
#                  invoked directly, VERBATIM, unmodified. The captured stdout MUST be the probe's JSON verdict
#                  object (`{"heavily_audited":true|false,"repo_audit_density":N,...}`) on its first line;
#                  empty / unparseable / missing `heavily_audited` key -> treated as no-signal (fail-safe).
#   --penalty    : flat penalty subtracted from a heavily-audited row's score (default 20; non-negative
#                  integer, else exit 2).
#   --out        : output path (default = the --queue path itself, i.e. re-ranks in place).
#   -h/--help    : print this header.
#
# PER-ROW LOGIC (5-col TSV: score<TAB>immunefi:<id><TAB>url<TAB>name<TAB>scope_hint):
#   1. `repo:` token extraction from scope_hint via the space-separated
#      `chain:X repo:Y commit:Z delta:Af/Bd fee:F vault:V [...]` shape run-immunefi-intake.sh emits. `repo:-`
#      (the "no repo" sentinel) or no `repo:` token at all -> score UNCHANGED (no signal, no de-rank).
#   2. A resolvable repo -> run the probe via the seam above. No output / non-JSON / non-zero exit / missing
#      `heavily_audited` key (mirrors audit-history-probe.sh's own [SKIP] contract: unreachable/offline/
#      no-git/no-python3 -> no stdout JSON) -> score UNCHANGED, never a crash (fail-safe on missing signal).
#   3. `heavily_audited=true` -> new_score = max(0, score - PENALTY). `heavily_audited=false` -> unchanged.
#      The max(0, ...) clamp bounds the penalty: it can only ever pull a score DOWN toward 0, never negative,
#      so it can never invert rank via underflow.
#   4. A malformed row (not exactly 5 tab-separated columns, or col 1 not an integer) passes through UNCHANGED
#      — never dropped (permutation guarantee holds even for garbage input), same fail-open rule
#      bounty-payability-gate.sh already applies to malformed rows.
#
# RE-RANK: ALL rows (penalized + untouched + malformed) are re-sorted by (new_score DESC, key ASC) — the
# exact tie-break run-immunefi-intake.sh uses (`rows.sort(key=lambda r: (-r[0], r[1].lower()))`). Row COUNT
# in == row count out and the row SET is unchanged (rank-only permutation) — nothing is ever added or dropped.
#
# SKIP contract: --queue missing/empty -> [SKIP], exit 0, --out unwritten (mirrors bounty-payability-gate.sh's
# empty-queue SKIP). python3 not installed -> [SKIP], exit 0.
# Bad args: unknown flag / a missing value / a non-negative-integer --penalty -> exit 2.
#
# Requires: python3 (JSON-safe parse boundary for the probe's stdout — never shell JSON parsing). Emits the
# SAME 5-col TSV run-immunefi-intake.sh / run-batch.sh already speak:
# score<TAB>immunefi:<id><TAB>url<TAB>name<TAB>scope_hint.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "apply-audit-density.sh: $2 requires a value" >&2; exit 2; }; }

QUEUE="$DIR/immunefi.queue"
PROBE_CMD="" ; PENALTY="20" ; OUT=""

while [ $# -gt 0 ]; do case "$1" in
  --queue)     nv "$#" "$1"; QUEUE="$2"; shift 2;;
  --probe-cmd) nv "$#" "$1"; PROBE_CMD="$2"; shift 2;;
  --penalty)
    nv "$#" "$1"
    case "$2" in
      ''|*[!0-9]*) echo "apply-audit-density.sh: --penalty must be a non-negative integer: $2" >&2; exit 2;;
    esac
    PENALTY="$2"; shift 2;;
  --out)       nv "$#" "$1"; OUT="$2"; shift 2;;
  -h|--help)   sed -n '2,55p' "$0"; exit 0;;
  *) echo "apply-audit-density.sh: unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$OUT" ] || OUT="$QUEUE"
[ -n "$PROBE_CMD" ] || PROBE_CMD="\"$HERE/audit-history-probe.sh\" \"\$PROBE_REPO\""

# Empty / missing queue -> nothing to re-rank (mirrors bounty-payability-gate.sh's SKIP contract).
if [ ! -s "$QUEUE" ]; then
  echo "[SKIP] no queue at $QUEUE — nothing to re-rank" >&2
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

# run_probe: $1 = the row's extracted repo -> prints the probe's raw stdout (a JSON verdict object, or nothing
# on no-signal). Mirrors run-batch.sh's run_hunt(): env var in, sh -c "$CMD", captured stdout, 2>/dev/null.
run_probe() {
  PROBE_REPO="$1" sh -c "$PROBE_CMD" 2>/dev/null || :
}

kept=0
penalized=0
# ROWS_FILE: score\tkey\turl\tname\tscope\tpenalty_applied — the penalty-annotated queue, fed to python for the
# final re-sort (JSON-safe boundary kept to the probe-verdict parse only; the row rewrite itself is plain TSV).
ROWS_FILE="$(mktemp "${TMPDIR:-/tmp}/apply-audit-density-rows.XXXXXX")"
trap 'rm -f "$ROWS_FILE"' EXIT

while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  cols="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
  if [ "$cols" != "5" ]; then
    # Malformed row: never crash, never drop — pass through unchanged (fail-open, permutation guarantee).
    printf '%s\n' "$line" >> "$ROWS_FILE"
    kept=$((kept + 1))
    continue
  fi
  score="$(printf '%s' "$line" | cut -f1)"
  key="$(printf '%s' "$line" | cut -f2)"
  url="$(printf '%s' "$line" | cut -f3)"
  name="$(printf '%s' "$line" | cut -f4)"
  scope="$(printf '%s' "$line" | cut -f5)"
  kept=$((kept + 1))

  case "$score" in
    ''|*[!0-9-]*) printf '%s\n' "$line" >> "$ROWS_FILE"; continue;;
  esac

  repo="$(printf '%s' "$scope" | grep -oE 'repo:[^ ]+' | head -1)"
  repo="${repo#repo:}"
  if [ -z "$repo" ] || [ "$repo" = "-" ]; then
    # No repo signal at all -> unchanged (fail-safe: no signal, no de-rank).
    printf '%s\t%s\t%s\t%s\t%s\n' "$score" "$key" "$url" "$name" "$scope" >> "$ROWS_FILE"
    continue
  fi

  verdict="$(run_probe "$repo")"
  heavily="$(printf '%s' "$verdict" | PENALTY="$PENALTY" python3 -c '
import json, os, sys
raw = sys.stdin.read().strip()
try:
    obj = json.loads(raw.splitlines()[0]) if raw else {}
except Exception:
    obj = {}
if not isinstance(obj, dict) or "heavily_audited" not in obj:
    print("unknown")
else:
    print("true" if obj.get("heavily_audited") else "false")
' 2>/dev/null || echo "unknown")"

  if [ "$heavily" = "true" ]; then
    new_score="$score"
    [ "$new_score" -gt "$PENALTY" ] && new_score=$((score - PENALTY)) || new_score=0
    penalized=$((penalized + 1))
    printf '%s\t%s\t%s\t%s\t%s\n' "$new_score" "$key" "$url" "$name" "$scope" >> "$ROWS_FILE"
  else
    # heavily_audited=false OR unresolved/unreachable/no-signal ("unknown") -> UNCHANGED (fail-safe).
    printf '%s\t%s\t%s\t%s\t%s\n' "$score" "$key" "$url" "$name" "$scope" >> "$ROWS_FILE"
  fi
done < "$QUEUE"

# Final re-sort: (new_score DESC, key ASC) — the exact tie-break run-immunefi-intake.sh uses. Malformed rows
# (not 5 cols) sort by key="" (ASC-first) at whatever score int() can salvage from col 1, else 0 — they are
# never dropped, only positioned; row count/set is unaffected either way.
ROWS_FILE="$ROWS_FILE" python3 - > "$OUT.tmp.$$" <<'PY'
import os

rows_path = os.environ["ROWS_FILE"]
rows = []
with open(rows_path, encoding="utf-8", errors="ignore") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        cols = line.split("\t")
        if len(cols) != 5:
            rows.append((0, "", line))
            continue
        try:
            score = int(cols[0])
        except ValueError:
            score = 0
        rows.append((score, cols[1].lower(), line))

rows.sort(key=lambda r: (-r[0], r[1]))
for _, _, line in rows:
    print(line)
PY
rc=$?
if [ "$rc" -ne 0 ]; then
  rm -f "$OUT.tmp.$$"
  exit "$rc"
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
mv "$OUT.tmp.$$" "$OUT"
cat "$OUT"

echo "apply-audit-density: penalized $penalized of $kept row(s) (heavily-audited, penalty=$PENALTY) -> $OUT" >&2
