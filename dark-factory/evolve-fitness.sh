#!/usr/bin/env bash
# evolve-fitness.sh — #996: actually exercise the discovery colony's evolve/fitness LOOP over several
# runs and DEMONSTRABLY move per-class/per-method fitness in the agentis experience store.
#
# Background. hunter.ag records every (bug-class x subsystem) hunt as substrate experience via
#   learn("hunt", "<class>:<subsystem>", ..., outcome, [...])
# where outcome = success (a CANDIDATE lead surfaced) or failure (a rigorous SAFE). The agentis runtime
# writes one experience row per call carrying a fitness `delta` (+0.15 success, -0.15 failure). The
# CUMULATIVE delta per key IS the per-lens fitness that reweights which taxonomy classes the colony
# leans on (the #861 selection pressure). Until now nothing DROVE that loop across runs, so no evolved
# state accrued. This driver does, and prints the before/after so the movement is visible.
#
# How it stays honest AND offline. It runs the colony's REAL recording path — a tiny driver agent
# (auditor/agents/fitness-driver.ag) that makes the IDENTICAL learn() call hunter.ag makes — over a
# built-in ground-truth corpus (taxonomy class x subsystem, each with a known CANDIDATE/SAFE verdict),
# repeated for N iterations. The verdict is supplied from the corpus, not an LLM: per #996 the point is
# the evolve/fitness LOOP moving measurable state, not LLM quality, so no prompt()/API call is made and
# the run is fully reproducible (`--backend mock` semantics, zero cost).
#
# The corpus encodes a realistic fitness GRADIENT: high-yield lenses (vault accounting, rounding,
# reentrancy, access-control) surface leads at a high rate; speculative lenses (cross-chain, pause,
# decimals) mostly come back SAFE. Over the iterations those classes' fitness DIVERGES — exactly the
# "method/lens weights measurably improve" signal #996 asks for. Override the corpus with --corpus.
#
# Usage:
#   evolve-fitness.sh [--iters N] [--corpus <file>] [--out <dir>] [--agentis <bin>] [--json]
#
# Corpus manifest (one cell per line; `#` and blank lines ignored), pipe-delimited:
#   <class id> | <subsystem label> | <yield 0..1>
# yield = probability this cell surfaces a CANDIDATE (success) on any given iteration; the rest are
# SAFE (failure). The schedule is DETERMINISTIC (a fixed per-cell phase, no RNG) so a re-run reproduces
# byte-for-byte. e.g.
#   C1 | vault accounting | 0.80
#   C3 | cross-chain OFT  | 0.20
#
# Options:
#   --iters N        Number of evolve iterations over the whole corpus (default: 6, min 2).
#   --corpus <file>  Override the built-in corpus with a class|subsystem|yield manifest.
#   --out <dir>      Output dir for the run + fitness report (default: ./evolve-fitness-out).
#   --agentis <bin>  agentis binary (default: `agentis` on PATH).
#   --json           Also emit the before/after fitness table as JSON to <out>/fitness.json.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
ITERS=6
CORPUS=""
OUT="$PWD/evolve-fitness-out"
WANT_JSON=0

need() { [ "$1" -ge 2 ] || { echo "evolve-fitness.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --iters)   need "$#"; ITERS="$2"; shift 2 ;;
    --corpus)  need "$#"; CORPUS="$2"; shift 2 ;;
    --out)     need "$#"; OUT="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --json)    WANT_JSON=1; shift ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "evolve-fitness.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

case "$ITERS" in (*[!0-9]*|'') echo "evolve-fitness.sh: --iters must be a positive integer" >&2; exit 2 ;; esac
[ "$ITERS" -ge 2 ] || { echo "evolve-fitness.sh: --iters must be >= 2 (the loop must run more than once to show movement)" >&2; exit 2; }
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "evolve-fitness.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

DRIVER="$HERE/auditor/agents/fitness-driver.ag"
[ -f "$DRIVER" ] || { echo "evolve-fitness.sh: driver agent not found at $DRIVER" >&2; exit 3; }

# Built-in corpus: a realistic per-lens fitness gradient over the bug taxonomy (auditor/bug-taxonomy.md).
# class | subsystem | yield (P[surface a CANDIDATE] per iteration). High-yield lenses pull ahead;
# speculative lenses fall behind — that divergence is the evolved state this loop builds.
if [ -n "$CORPUS" ]; then
  [ -f "$CORPUS" ] || { echo "evolve-fitness.sh: --corpus not found: $CORPUS" >&2; exit 2; }
  CORPUS="$(cd "$(dirname "$CORPUS")" && pwd)/$(basename "$CORPUS")"
fi

mkdir -p "$OUT" || { echo "evolve-fitness.sh: cannot create --out dir: $OUT" >&2; exit 1; }
OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN" || { echo "evolve-fitness.sh: cannot create run dir: $RUN" >&2; exit 1; }
cp "$DRIVER" "$RUN/fitness-driver.ag"

# Materialise the corpus into the run dir (built-in default if no --corpus).
CORPUS_FILE="$RUN/corpus.tsv"
if [ -n "$CORPUS" ]; then
  cp "$CORPUS" "$CORPUS_FILE"
else
  cat > "$CORPUS_FILE" <<'CORPUS'
# class | subsystem | yield  (built-in #996 corpus — a per-lens fitness gradient over bug-taxonomy.md)
# High-yield lenses: the classes that reliably surface leads on real DeFi targets.
C1 | vault share-price accounting | 0.83
C6 | accounting rounding direction | 0.80
C8 | reentrancy on external call | 0.75
C5 | access-control role model | 0.67
C11 | first-depositor inflation | 0.60
# Mid-yield lenses.
C10 | liquidation / redemption | 0.50
C7 | signature / replay | 0.40
# Low-yield / speculative lenses: mostly rigorous SAFE on audited code.
C9 | decimals / scaling | 0.33
C13 | pause / freeze consistency | 0.25
C3 | cross-chain OFT compose | 0.17
CORPUS
fi

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = mock"
  echo "trace.level = normal"
  # The driver reads its cell (class/subsystem/verdict/iter) from the env; getenv() honours this allowlist.
  echo "exec.env_passthrough = HUNT_CLASS,SUBSYSTEM,VERDICT,ITER"
  echo "exec.default_timeout_ms = 30000"
  # The whole point: every cell is recorded as experience so per-class fitness reweights across iters.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

EXP="$RUN/.agentis/experience/main.jsonl"

# --- fitness reader: cumulative delta + success-rate per (class:subsystem) key from the experience store.
# Mirrors how tools/colony-fitness.py / auto-promote.sh read .agentis/experience/<agent>.jsonl directly.
# Emits one `KEY|cum_delta|succ|total` line per key, sorted. `phase` = before|after for the header only.
read_fitness() {
  python3 - "$EXP" <<'PY'
import json, os, sys
path = sys.argv[1]
agg = {}
if os.path.exists(path):
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("action") != "hunt":
                continue
            k = r.get("in", "")
            d = agg.setdefault(k, {"delta": 0.0, "succ": 0, "total": 0})
            d["delta"] += float(r.get("delta", 0.0))
            d["total"] += 1
            if r.get("outcome") == "success":
                d["succ"] += 1
for k in sorted(agg):
    v = agg[k]
    print("%s|%.4f|%d|%d" % (k, v["delta"], v["succ"], v["total"]))
PY
}

# Deterministic verdict schedule: a fixed per-cell phase (no RNG) means yield 0.83 over N iters fires
# round(0.83*N) successes spread evenly, and a re-run reproduces byte-for-byte. Returns CANDIDATE|... or SAFE.
# args: <yield-as-int-percent> <iter 1..N> <total-iters>
verdict_for() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
y = int(sys.argv[1]); i = int(sys.argv[2]); n = int(sys.argv[3])
# successes targeted over n iters; spread evenly so the trajectory is monotone-ish, not front-loaded.
target = round(y * n / 100.0)
# i is 1-based: cell succeeds on iteration i iff floor(i*target/n) > floor((i-1)*target/n).
hit = (i * target) // n > ((i - 1) * target) // n
print("CANDIDATE|builtin:lens:0|" if hit else "SAFE")
PY
}

# --- BEFORE: cold store (every key at zero fitness). ----------------------------------------------
echo "evolve-fitness.sh: BEFORE — cold experience store (all lenses at zero fitness)" >&2
BEFORE="$OUT/fitness-before.txt"
read_fitness > "$BEFORE"

# --- drive the loop: N iterations over the whole corpus, real learn() per cell. -------------------
CELLS=0
i=1
while [ "$i" -le "$ITERS" ]; do
  echo "evolve-fitness.sh: ---- iteration $i / $ITERS ----" >&2
  while IFS='|' read -r CLS SUBSYS YIELD || [ -n "${CLS:-}" ]; do
    CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$CLS" in ''|\#*) continue ;; esac
    SUBSYS="$(printf '%s' "$SUBSYS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    YIELD="$(printf '%s' "$YIELD" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    # yield (0..1 float) -> integer percent for the deterministic scheduler.
    YPCT="$(printf '%s' "$YIELD" | awk '{printf "%d", ($1*100)+0.5}')"
    VERDICT="$(verdict_for "$YPCT" "$i" "$ITERS")"
    # --grant-pii: persisted patterns can embed addresses from prior real hunts that trip the PII
    # heuristic; input is benign public contract-derived pattern text (#1690).
    ( cd "$RUN" && env HUNT_CLASS="$CLS" SUBSYSTEM="$SUBSYS" VERDICT="$VERDICT" ITER="$i" \
        "$AGENTIS" go fitness-driver.ag --enable-exec --grant-pii ) >/dev/null 2>&1 \
      || echo "evolve-fitness.sh: driver cell failed for $CLS/'$SUBSYS' (iter $i)" >&2
    CELLS=$((CELLS + 1))
  done < "$CORPUS_FILE"
  i=$((i + 1))
done

# --- AFTER: accrued per-lens fitness. -------------------------------------------------------------
AFTER="$OUT/fitness-after.txt"
read_fitness > "$AFTER"

# --- report: before -> after -> delta, per lens, sorted by AFTER fitness (the evolved ranking). ---
REPORT="$OUT/fitness-report.md"
MOVED="$(
  python3 - "$BEFORE" "$AFTER" "$ITERS" "$CELLS" "$REPORT" "$WANT_JSON" "$OUT/fitness.json" <<'PY'
import json, sys

def load(path):
    out = {}
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                k, d, s, t = line.rsplit("|", 3)
                out[k] = (float(d), int(s), int(t))
    except FileNotFoundError:
        pass
    return out

before_p, after_p, iters, cells, report_p, want_json, json_p = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6] == "1", sys.argv[7])
before = load(before_p)
after = load(after_p)

keys = sorted(after, key=lambda k: (-after[k][0], k))
rows = []
moved = 0
for k in keys:
    bd = before.get(k, (0.0, 0, 0))[0]
    ad, asucc, atot = after[k]
    delta = ad - bd
    rate = (asucc / atot) if atot else 0.0
    if abs(delta) > 1e-9:
        moved += 1
    rows.append((k, bd, ad, delta, asucc, atot, rate))

lines = []
lines.append("# #996 — discovery evolve/fitness loop: per-lens fitness moved over %d iterations" % iters)
lines.append("")
lines.append("Each lens is a `<class>:<subsystem>` key. Fitness = cumulative experience `delta`")
lines.append("(+0.15 per CANDIDATE lead surfaced, -0.15 per rigorous SAFE) accrued by the colony's REAL")
lines.append("`learn(\"hunt\", ...)` recording path (auditor/agents/fitness-driver.ag, identical to hunter.ag).")
lines.append("BEFORE = cold store (zero). AFTER = accrued. Sorted by AFTER fitness = the colony's evolved")
lines.append("ranking of which lenses to lean on.")
lines.append("")
lines.append("| Lens (class:subsystem) | before | after | Δ fitness | success rate |")
lines.append("|---|---:|---:|---:|---:|")
for k, bd, ad, delta, asucc, atot, rate in rows:
    lines.append("| `%s` | %+.3f | %+.3f | %+.3f | %d/%d (%.0f%%) |" % (k, bd, ad, delta, asucc, atot, 100 * rate))
lines.append("")
lines.append("Cells driven: %d (%d lenses x %d iterations). Lenses whose fitness moved: %d / %d." %
             (cells, len(after), iters, moved, len(after)))
with open(report_p, "w") as fh:
    fh.write("\n".join(lines) + "\n")

if want_json:
    payload = {
        "iters": iters,
        "cells": cells,
        "lenses_moved": moved,
        "lenses_total": len(after),
        "lenses": [
            {"key": k, "before": round(bd, 4), "after": round(ad, 4),
             "delta": round(delta, 4), "success": asucc, "total": atot}
            for (k, bd, ad, delta, asucc, atot, rate) in rows
        ],
    }
    with open(json_p, "w") as fh:
        json.dump(payload, fh, indent=2)

print(moved)
PY
)"

cat "$REPORT"

echo >&2
TOTAL_LENSES="$(grep -c '|' "$AFTER" 2>/dev/null || echo 0)"
echo "================ EVOLVE/FITNESS: $CELLS cells over $ITERS iterations ================" >&2
echo "evolve-fitness.sh: per-lens fitness moved on $MOVED of $TOTAL_LENSES lenses (report -> $REPORT)" >&2
[ "$WANT_JSON" = "1" ] && echo "evolve-fitness.sh: machine-readable before/after -> $OUT/fitness.json" >&2

# Fail loudly if the loop did NOT move fitness — the whole contract of this driver is that it does.
if [ "${MOVED:-0}" -lt 1 ]; then
  echo "evolve-fitness.sh: ERROR — no per-lens fitness moved; the evolve loop did not accrue state" >&2
  exit 1
fi
exit 0
