#!/usr/bin/env bash
# run-batch.sh — the BATCH/CONTINUOUS RUNNER that operationalizes the proven engines at volume by
# consuming the #1054 funnel queue (epic #1053). The funnel raises target VOLUME from 1; this loop is
# what actually feeds those targets through a hunt, stages findings, and records outcomes so the funnel
# dedups next run and the coordinator policy can learn across targets.
#
# Loop (per ${DARK_FACTORY_DIR}/targets.queue line `score<TAB>key<TAB>url<TAB>title<TAB>scope_hint`,
#       highest score first — the funnel already ranked it):
#   1. SKIP if `key` is already in funnel-ledger.txt (resumable; reuses the funnel's dedup contract).
#   2. HUNT the target under a per-target timeout:
#        --hunt-cmd "<cmd>"  : the cmd is the seam. It receives BATCH_KEY / BATCH_URL / BATCH_SCOPE in
#                              env and MUST print one `VERDICT|<confirmed|dry|refuted>[|detail]` line.
#                              This is what the demo drives and what an operator wires to a real hunt.
#        default (no cmd)    : best-effort — if the entry carries a resolvable 0x address, route to
#                              run-autoharness.sh (needs ETH_RPC + FORK_BLOCK in env; absent -> `dry`
#                              + a skip note). Otherwise `dry` + `needs recon`. Full contest-URL ->
#                              foundry-repo -> invariant resolution is target-specific and out of scope.
#   3. VERDICT is the HUNT's (its VERDICT line / exit code), NEVER an LLM. On `confirmed`, stage the
#      finding under <out>/submission/<key>/ (a report stub marked PENDING HUMAN REVIEW). This colony
#      NEVER auto-submits to any platform — a staged finding is a LEAD a human reviews + submits.
#   4. APPEND `key<TAB>verdict<TAB>ts` to funnel-ledger.txt (the funnel dedups it next run) AND to
#      policy-outcomes.log (the coordinator can fold outcomes into its action policy).
#   Bounded by --max-targets; resumable after interruption (the ledger is the checkpoint).
#
# This tool NEVER contacts a platform to submit. Offline / no-queue behaviour matches the sibling scripts.
#
# Usage: run-batch.sh [--queue <file>] [--hunt-cmd "<cmd>"] [--pre-hunt-gate "<cmd>"] [--max-targets N]
#                      [--out <dir>] [--timeout S] [-h]
#   --queue        : the ranked queue to consume (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/targets.queue).
#   --hunt-cmd     : a command run per target (BATCH_KEY/BATCH_URL/BATCH_SCOPE in env) that prints a
#                    `VERDICT|<confirmed|dry|refuted>[|detail]` line. Default = best-effort autoharness.
#   --pre-hunt-gate: OPTIONAL (epic #1894 M4). A command run per target BEFORE the hunt, same env contract
#                    as --hunt-cmd (BATCH_KEY/BATCH_URL/BATCH_SCOPE), that MUST print one
#                    `TARGET-UNIQUENESS|<GO|FLAG|SKIP>|...` line (the #1899 target-uniqueness-gate.sh
#                    contract verbatim). GO -> proceed to the hunt. Anything else — FLAG/SKIP, no line,
#                    or a non-zero exit — records `skipped-known` to the ledger and spends NO hunt. Default
#                    "" (absent flag) = today's behaviour, byte-identical; this is a pure operator-wired
#                    seam, not auto-invoking any specific gate script.
#   --max-targets  : process at most N targets this run (default 5). Alias: --budget.
#   --out          : staging root for confirmed findings (default $PWD/batch-out).
#   --timeout      : per-target timeout in seconds when `timeout` is available (default 600).
# Requires: bash. Exit 0 on success OR clean [SKIP]; exit 2 on bad args.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"
LEDGER="$DIR/funnel-ledger.txt"
POLICY_LOG="$DIR/policy-outcomes.log"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would
# otherwise crash on $2 (unbound) instead of the promised exit 2. $1 = remaining argc, $2 = flag name.
nv() { [ "$1" -ge 2 ] || { echo "run-batch.sh: $2 requires a value" >&2; exit 2; }; }
QUEUE="$DIR/targets.queue" ; HUNT_CMD="" ; PRE_HUNT_GATE="" ; MAX_TARGETS="5" ; OUT="$PWD/batch-out" ; PER_TIMEOUT="600"
while [ $# -gt 0 ]; do case "$1" in
  --queue)        nv "$#" "$1"; QUEUE="$2"; shift 2;;
  --hunt-cmd)     nv "$#" "$1"; HUNT_CMD="$2"; shift 2;;
  --pre-hunt-gate) nv "$#" "$1"; PRE_HUNT_GATE="$2"; shift 2;;
  --max-targets|--budget) nv "$#" "$1"; MAX_TARGETS="$2"; shift 2;;
  --out)          nv "$#" "$1"; OUT="$2"; shift 2;;
  --timeout)      nv "$#" "$1"; PER_TIMEOUT="$2"; shift 2;;
  -h|--help)      sed -n '2,41p' "$0"; exit 0;;
  *) echo "run-batch.sh: unknown arg: $1" >&2; exit 2;;
esac; done

mkdir -p "$DIR"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
TIMEOUT_BIN="$(command -v timeout || true)"

# Empty / missing queue -> nothing to do (CI-safe; [SKIP] to stderr, mirroring run-funnel.sh).
if [ ! -s "$QUEUE" ]; then
  echo "[SKIP] no queue at $QUEUE (run run-funnel.sh first) — nothing to process" >&2
  exit 0
fi

# Run a command under the per-target timeout when `timeout(1)` is available, else plain.
with_timeout() {
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$PER_TIMEOUT" "$@"; else "$@"; fi
}

# True if `key` (col 1) already has a ledger row -> already processed -> skip (resumable + dedup).
ledger_has() { [ -f "$LEDGER" ] && cut -f1 "$LEDGER" 2>/dev/null | grep -qxF "$1"; }

# Append the outcome to the dedup ledger (the funnel reads it) AND the policy-outcomes log.
record() {  # $1 = key, $2 = verdict
  local t; t="$(ts)"
  printf '%s\t%s\t%s\n' "$1" "$2" "$t" >> "$LEDGER"
  printf '%s\t%s\t%s\n' "$1" "$2" "$t" >> "$POLICY_LOG"
}

# First 0x+40hex address found in the entry's url/scope, if any.
addr_of() { printf '%s' "$1" | grep -oiE '0x[0-9a-f]{40}' | head -1 || true; }

# Run the hunt for one target -> echo a single `VERDICT|<word>[|detail]` line. Verdict is the engine's.
run_hunt() {  # $1 = key, $2 = url, $3 = scope
  local k="$1" u="$2" s="$3" a ec
  if [ -n "$HUNT_CMD" ]; then
    BATCH_KEY="$k" BATCH_URL="$u" BATCH_SCOPE="$s" with_timeout sh -c "$HUNT_CMD" 2>/dev/null \
      | grep -m1 '^VERDICT|' || echo "VERDICT|dry|hunt-cmd produced no VERDICT line"
    return 0
  fi
  a="$(addr_of "$u $s")"
  if [ -z "$a" ]; then
    echo "VERDICT|dry|skip: needs recon (no auto-resolvable address in url/scope)"; return 0
  fi
  if [ -z "${ETH_RPC:-}" ] || [ -z "${FORK_BLOCK:-}" ]; then
    echo "VERDICT|dry|skip: address $a found but ETH_RPC + FORK_BLOCK unset (run-autoharness needs them)"; return 0
  fi
  # run-autoharness exit: 1 = FINDING (confirmed), anything else = dry (no finding / harness error).
  ec=0
  with_timeout "$HERE/run-autoharness.sh" --address "$a" --rpc "$ETH_RPC" --block "$FORK_BLOCK" \
    --out "$OUT/work/$k" >/dev/null 2>&1 || ec=$?
  if [ "$ec" -eq 1 ]; then echo "VERDICT|confirmed|autoharness FINDING on $a"
  else echo "VERDICT|dry|autoharness: no finding / harness error on $a (exit $ec)"; fi
}

processed=0 ; staged=0 ; skipped=0
# Read the queue into an array first so a hunt-cmd is free to consume stdin.
mapfile -t LINES < "$QUEUE"
for line in "${LINES[@]}"; do
  [ -n "$line" ] || continue
  IFS=$'\t' read -r _score key url title scope <<< "$line"
  : "${title:=}"  # title is captured for completeness; unused beyond the record
  [ -n "${key:-}" ] || continue
  if ledger_has "$key"; then skipped=$((skipped+1)); echo "skip (already in ledger): $key" >&2; continue; fi
  if [ "$processed" -ge "$MAX_TARGETS" ]; then
    echo "run-batch: reached --max-targets $MAX_TARGETS; stopping (re-run to continue — resumable via the ledger)" >&2
    break
  fi
  processed=$((processed+1))
  if [ -n "$PRE_HUNT_GATE" ]; then
    gline="$(BATCH_KEY="$key" BATCH_URL="${url:-}" BATCH_SCOPE="${scope:-}" \
              with_timeout sh -c "$PRE_HUNT_GATE" 2>/dev/null | grep -m1 '^TARGET-UNIQUENESS|' || true)"
    gverdict="$(printf '%s' "$gline" | cut -d'|' -f2)"
    if [ "$gverdict" != "GO" ]; then
      echo "run-batch: pre-hunt-gate $key -> ${gverdict:-FLAG(no-verdict)} — skipping (no hunt spent)" >&2
      record "$key" "skipped-known"
      printf '%s\t%s\n' "$key" "skipped-known"
      continue
    fi
    echo "run-batch: pre-hunt-gate $key -> GO" >&2
  fi
  echo "run-batch: hunting $key (${url:-no-url}) ..." >&2
  v="$(run_hunt "$key" "${url:-}" "${scope:-}")"
  verdict="$(printf '%s' "$v" | cut -d'|' -f2)"; [ -n "$verdict" ] || verdict="dry"
  detail="$(printf '%s' "$v" | cut -d'|' -f3-)"
  if [ "$verdict" = "confirmed" ]; then
    sd="$OUT/submission/$key"; mkdir -p "$sd"
    {
      echo "# FINDING — PENDING HUMAN REVIEW — NOT SUBMITTED"
      echo
      echo "- Target: $key"
      echo "- URL: ${url:-}"
      echo "- Scope: ${scope:-}"
      echo "- Detail: ${detail:-}"
      echo
      echo "Verdict came from the hunt engine (exit code / VERDICT line), never an LLM. A human reviews"
      echo "this package and submits it manually; this colony has no platform-egress and never auto-posts."
    } > "$sd/report.md"
    staged=$((staged+1))
    echo "run-batch: FINDING staged -> $sd/report.md (NOT submitted)" >&2
  fi
  record "$key" "$verdict"
  printf '%s\t%s%s\n' "$key" "$verdict" "${detail:+	($detail)}"
done

echo "run-batch: processed $processed, staged $staged finding(s), skipped $skipped already-ledgered; outcomes -> $LEDGER" >&2
