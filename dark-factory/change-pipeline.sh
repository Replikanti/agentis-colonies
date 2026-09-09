#!/usr/bin/env bash
# change-pipeline.sh — the M4 CADENCE + LLM-BUDGET entrypoint (#2135, epic #2120 M4: first-on-fresh-code). It
# CHAINS the three merged stages into ONE budget-bounded tick, so the change-triggered hunt can run unattended
# on a schedule (a cron) instead of by hand:
#
#   watch-code-changes.sh (M1, #2128)  ->  scope-changes.sh (M2, #2131)  ->  run-change-hunts.sh (M3, #2133)
#   detect a program whose CODE moved      one scope descriptor per change   materialize@new + deduped hunt,
#                                                                            findings staged (never submitted)
#
# It REINVENTS NOTHING: each tick is just the three scripts in series, plus a two-knob budget and one
# PATCH-able JSON tick-summary the hunt-dashboard (#1913) renders as an overview panel.
#
# THE BUDGET (two knobs — reuse, do NOT invent a new semaphore; STOP-1 #2135):
#   * N hunts / tick   = `run-change-hunts.sh --max-hunts N` (M3-native; DEFAULT 1). The per-tick cap on how
#                        many changes are hunted; skips + already-ledgered rows do NOT count against it.
#   * K concurrent     = the EXISTING host-wide `lib/forge-slot.sh` semaphore (#2038). This script only
#     forge subprocs     EXPORTS `FORGE_MAX_SLOTS=K` (DEFAULT 2) so the whole M3 -> run-zone-hunt ->
#                        run-invariant-hunt subtree, which already brackets its `forge` runs with
#                        acquire/release_forge_slot, is capped host-wide. NO new concurrency layer is added
#                        here (M3 is deliberately serial; a second layer would double-count and fight it).
#   This DIVERGES from the issue body's `llm-session-slot.sh` suggestion ON PURPOSE (STOP-1 #2135): that
#   semaphore is dev-apprenticeship's fed-fixed reasoning/edit pool (`tools/lib/llm-session-slot.sh`, keyed to
#   COLONY_DIR) — the wrong scope for a dark-factory hunt cadence. The dark-factory-native forge-slot is the
#   correct host-wide LLM/forge-budget cap.
#
# DEDUP / RESUMABILITY: M3's `(program, new)` change-key ledger (hunted-changes.tsv) is the checkpoint — a tick
# is resumable and NEVER re-hunts a change. This script relies on that (built in M3); it adds no dedup of its own.
#
# ══════════════════════════════════════════════════════════════════════════════════════════════════════════
#  SCOPE GUARD (HARD, limit-safety — #2135): this milestone BUILDS + OFFLINE-demos the cadence/budget/dashboard
#  wiring ONLY. It MUST NOT install a live crontab, and MUST NOT run a live hunt against real programs. The
#  ceiling is a bare `change-pipeline.sh --once` at the DEFAULT budget (hunts-per-tick=1, forge-max-slots=2)
#  driving the MOCKED M1/M2/M3 in demo-change-pipeline.sh. The tick-summary always carries `armed:false`.
#  ARMING — installing the cron below, raising the budget, and the first live fleet sweep — is the operator's
#  explicit go, and is what M5 (the measured week) needs. There is NO daemon/loop mode: the script only ever
#  runs ONE tick per invocation, so it can only ever spend one budget's worth. This adds ZERO new egress path
#  (M3's baked-in never-submit deliver-submission.sh gate is inherited unchanged).
#
#  CRON — a COMMENTED, ready-to-install line (~6h, matching contest-watch.sh's cadence). NOT installed by this
#  script; the operator runs it by hand when arming (see dark-factory/README.md "Change-cadence" section):
#    # ( crontab -l 2>/dev/null; echo '0 */6 * * * <PATH-TO>/dark-factory/change-pipeline.sh --once >> ~/.dark-factory/change-watch/cadence.log 2>&1' ) | crontab -
# ══════════════════════════════════════════════════════════════════════════════════════════════════════════
#
# Usage: change-pipeline.sh [--once] [--hunts-per-tick N|--budget N] [--forge-max-slots K] [--bounties-from <f>]
#                           [--state-dir <dir>] [--summary <file>] [--backend <b>] [--agentis <bin>]
#                           [--model <id>] [--watch-cmd "<cmd>"] [--scope-cmd "<cmd>"] [--hunt-cmd "<cmd>"]
#                           [--source-cmd "<cmd>"] [-h]
#   --once             : run ONE cadence tick (M1 -> M2 -> M3) and exit. This is also what a BARE run does —
#                        there is no continuous/daemon mode by design (limit-safety).
#   --hunts-per-tick N : the per-tick hunt cap, forwarded verbatim to M3 `--max-hunts` (DEFAULT 1). Alias --budget.
#   --forge-max-slots K: exported as FORGE_MAX_SLOTS so lib/forge-slot.sh caps concurrent forge subprocs
#                        host-wide across the M3 subtree (DEFAULT 2).
#   --bounties-from    : the Immunefi bounties JSON M1 scans. Default
#                        ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/freshness-watch/bounties.json.
#   --state-dir        : the shared M1/M2/M3 state root. Default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/
#                        change-watch. Holds changes.tsv, scope-descriptors.tsv, hunted-changes.tsv, the hunt
#                        out/drop dirs, and (by default) the tick-summary.
#   --summary <file>   : the PATCH-able tick-summary JSON (single overwritten file). Default <state-dir>/
#                        tick-summary.json. The hunt-dashboard renders it as an overview panel.
#   --backend/--agentis/--model : forwarded to M3 (run-change-hunts.sh -> run-zone-hunt.sh) when set.
#   --watch-cmd "<cmd>": OVERRIDE seam — REPLACES the M1 invocation (the offline-demo hatch). Invoked as
#                        `sh -c "<cmd>"` with WATCH_BOUNTIES / WATCH_STATE_DIR / WATCH_OUT (the changes.tsv path)
#                        in env; it MUST populate WATCH_OUT. Default = the real watch-code-changes.sh.
#   --scope-cmd "<cmd>": OVERRIDE seam — REPLACES the M2 invocation. Invoked as `sh -c "<cmd>"` with
#                        SCOPE_CHANGES_FROM / SCOPE_OUT (the descriptors path) in env; it MUST populate
#                        SCOPE_OUT. Default = the real scope-changes.sh.
#   --hunt-cmd "<cmd>" / --source-cmd "<cmd>" : the M3 offline hatches, FORWARDED verbatim to
#                        run-change-hunts.sh's OWN `--hunt-cmd`/`--source-cmd` seams (so the REAL M3 still runs
#                        — real `--max-hunts` budget, real ledger dedup, real FORGE_MAX_SLOTS export — and only
#                        its innermost network/LLM/forge subprocess is mocked). Default = the real hunt path.
#   -h/--help          : this header.
#
# WHY M1/M2 are REPLACE seams but M3 is a FORWARD seam: M1/M2 are pure producers (changes.tsv / descriptors)
# whose live path needs the network + python3, so an offline demo replaces them wholesale. M3 is the
# budget-BEARING stage whose real behaviour (`--max-hunts`, the (program,new) ledger, the forge-slot export)
# is exactly what M4 must prove, so it stays REAL and only its innermost subprocess is mocked via M3's seams.
#
# tick-summary SCHEMA (single JSON object, atomically overwritten every tick — a reader mid-tick sees
# `status:"running"`; PATCH-able for observability of a long unattended run):
#   { last_tick, status(running|ok|quiet|error), changes_seen, descriptors, hunts_run, materialize_errors,
#     findings_staged, skipped, ledger_total, budget:{hunts_per_tick,forge_max_slots}, armed:false, tick_seq }
#   - changes_seen   = new rows M1 appended to changes.tsv this tick.
#   - descriptors    = M2 descriptor rows this tick (scope-descriptors.tsv is overwritten each run).
#   - hunts_run      = real hunt attempts that MATERIALIZED this tick (finding|clean|hunt-error ledger rows).
#   - materialize_errors = descriptors that failed to materialize this tick (materialize-error ledger rows);
#     these do NOT count as hunts (a failed materialize spends no hunt budget, per M3).
#   - findings_staged= staged submission packages this tick (drop-dir manifest.json count delta).
#   - skipped        = docs/tests-only `skip` descriptors ledgered-seen this tick (skipped-nohunt rows).
#   - ledger_total   = total (program,new) rows in the ledger after this tick.
#   - status: quiet = no changes AND no hunts AND no materialize errors; error = a stage exited non-zero; ok else.
#
# Requires: bash + the M1/M2/M3 scripts (their own deps — python3/git/cast — apply on the live path only; the
# demo replaces/mocks them). No `readlink -f`/GNU-only. Exit 0 on a completed tick (a per-row hunt failure is
# recorded, not fatal); 2 on bad/missing args.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise
# crash on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "change-pipeline.sh: $2 requires a value" >&2; exit 2; }; }

MAX_HUNTS=1
FORGE_MAX_SLOTS="${FORGE_MAX_SLOTS:-2}"
BOUNTIES_FROM="$DIR/freshness-watch/bounties.json"
STATE_DIR="$DIR/change-watch"
SUMMARY=""
BACKEND=""
AGENTIS=""
MODEL=""
WATCH_CMD=""
SCOPE_CMD=""
HUNT_CMD=""
SOURCE_CMD=""
while [ $# -gt 0 ]; do case "$1" in
  --once)             shift;;                                  # the only mode; a bare run does the same
  --hunts-per-tick|--budget) nv "$#" "$1"; MAX_HUNTS="$2"; shift 2;;
  --forge-max-slots)  nv "$#" "$1"; FORGE_MAX_SLOTS="$2"; shift 2;;
  --bounties-from)    nv "$#" "$1"; BOUNTIES_FROM="$2"; shift 2;;
  --state-dir)        nv "$#" "$1"; STATE_DIR="$2"; shift 2;;
  --summary)          nv "$#" "$1"; SUMMARY="$2"; shift 2;;
  --backend)          nv "$#" "$1"; BACKEND="$2"; shift 2;;
  --agentis)          nv "$#" "$1"; AGENTIS="$2"; shift 2;;
  --model)            nv "$#" "$1"; MODEL="$2"; shift 2;;
  --watch-cmd)        nv "$#" "$1"; WATCH_CMD="$2"; shift 2;;
  --scope-cmd)        nv "$#" "$1"; SCOPE_CMD="$2"; shift 2;;
  --hunt-cmd)         nv "$#" "$1"; HUNT_CMD="$2"; shift 2;;
  --source-cmd)       nv "$#" "$1"; SOURCE_CMD="$2"; shift 2;;
  -h|--help)          sed -n '2,101p' "$0"; exit 0;;
  *) echo "change-pipeline.sh: unknown arg: $1" >&2; exit 2;;
esac; done

case "$MAX_HUNTS" in *[!0-9]*|"") echo "change-pipeline.sh: --hunts-per-tick must be a non-negative integer" >&2; exit 2;; esac
case "$FORGE_MAX_SLOTS" in *[!0-9]*|"") echo "change-pipeline.sh: --forge-max-slots must be a non-negative integer" >&2; exit 2;; esac

CHANGES="$STATE_DIR/changes.tsv"
DESCRIPTORS="$STATE_DIR/scope-descriptors.tsv"
LEDGER="$STATE_DIR/hunted-changes.tsv"
HUNT_OUT="$STATE_DIR/change-hunt-out"
DROP_DIR="$STATE_DIR/drop"
[ -n "$SUMMARY" ] || SUMMARY="$STATE_DIR/tick-summary.json"
mkdir -p "$STATE_DIR"

# The forge-slot budget: export so the whole M3 subtree (run-change-hunts -> run-zone-hunt -> run-invariant-
# hunt, all of which source lib/forge-slot.sh) caps concurrent `forge` subprocs host-wide at K.
export FORGE_MAX_SLOTS

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
LOG="$STATE_DIR/cadence.log"
log() { echo "[$(ts)] $*" >> "$LOG"; }

# count_rows: non-`#` data rows in a TSV (0 for a missing/empty file). grep -c prints 0 + exits 1 on no match,
# which command-substitution still captures; a missing file yields "" -> 0.
count_rows() { local c; c="$(grep -cv '^#' "$1" 2>/dev/null)"; printf '%s' "${c:-0}"; }
# pkg_count: staged submission packages under the drop-dir (a package == a manifest.json).
pkg_count() { [ -d "$DROP_DIR" ] && { find "$DROP_DIR" -name manifest.json 2>/dev/null | grep -c . || echo 0; } || echo 0; }

# tick-summary is written atomically (tmp + mv) as a SINGLE overwritten file, so a reader never sees a torn
# JSON and a long unattended run reports live progress rather than silence.
changes_seen=0; descriptors=0; hunts_run=0; materialize_errors=0; findings_staged=0; skipped=0; ledger_total=0
write_summary() { # $1 = status
  local st tmp
  st="$1"; tmp="$SUMMARY.tmp.$$"
  {
    printf '{\n'
    printf '  "last_tick": "%s",\n' "$(ts)"
    printf '  "status": "%s",\n' "$st"
    printf '  "changes_seen": %s,\n' "$changes_seen"
    printf '  "descriptors": %s,\n' "$descriptors"
    printf '  "hunts_run": %s,\n' "$hunts_run"
    printf '  "materialize_errors": %s,\n' "$materialize_errors"
    printf '  "findings_staged": %s,\n' "$findings_staged"
    printf '  "skipped": %s,\n' "$skipped"
    printf '  "ledger_total": %s,\n' "$ledger_total"
    printf '  "budget": { "hunts_per_tick": %s, "forge_max_slots": %s },\n' "$MAX_HUNTS" "$FORGE_MAX_SLOTS"
    printf '  "armed": false,\n'
    printf '  "tick_seq": %s\n' "$TICK_SEQ"
    printf '}\n'
  } > "$tmp" && mv -f "$tmp" "$SUMMARY"
}

# tick_seq is monotonic across runs — read the prior summary's value (grep, no jq dependency) and increment.
TICK_SEQ=0
if [ -f "$SUMMARY" ]; then
  prev="$(grep -o '"tick_seq"[[:space:]]*:[[:space:]]*[0-9]\{1,\}' "$SUMMARY" 2>/dev/null | grep -o '[0-9]\{1,\}$' | tail -n1)"
  case "$prev" in ''|*[!0-9]*) prev=0;; esac
  TICK_SEQ="$prev"
fi
TICK_SEQ=$((TICK_SEQ + 1))

# ---- the tick ----------------------------------------------------------------------------------------------
before_changes="$(count_rows "$CHANGES")"
before_ledger="$(count_rows "$LEDGER")"   # the ledger has NO header, so this is also its total line count
before_pkgs="$(pkg_count)"
stage_err=""
log "tick #$TICK_SEQ start (hunts-per-tick=$MAX_HUNTS, forge-max-slots=$FORGE_MAX_SLOTS, state=$STATE_DIR)"
write_summary "running"

# M1 — detect moved code. REPLACE seam: --watch-cmd. Default = the real watch-code-changes.sh.
if [ -n "$WATCH_CMD" ]; then
  WATCH_BOUNTIES="$BOUNTIES_FROM" WATCH_STATE_DIR="$STATE_DIR" WATCH_OUT="$CHANGES" \
    sh -c "$WATCH_CMD" >>"$LOG" 2>&1 || { stage_err="watch"; log "[stage-error] M1 watch (exit $?)"; }
else
  "$HERE/watch-code-changes.sh" --bounties-from "$BOUNTIES_FROM" --state-dir "$STATE_DIR" --out "$CHANGES" \
    >>"$LOG" 2>&1 || { stage_err="watch"; log "[stage-error] M1 watch-code-changes.sh (exit $?)"; }
fi

# M2 — one scope descriptor per change row. REPLACE seam: --scope-cmd. Default = the real scope-changes.sh.
# scope-changes.sh needs a readable changes.tsv; an empty one yields 0 descriptors (a clean quiet tick).
if [ ! -f "$CHANGES" ]; then : > "$CHANGES"; fi
if [ -n "$SCOPE_CMD" ]; then
  SCOPE_CHANGES_FROM="$CHANGES" SCOPE_OUT="$DESCRIPTORS" \
    sh -c "$SCOPE_CMD" >>"$LOG" 2>&1 || { stage_err="scope"; log "[stage-error] M2 scope (exit $?)"; }
else
  "$HERE/scope-changes.sh" --changes-from "$CHANGES" --out "$DESCRIPTORS" \
    >>"$LOG" 2>&1 || { stage_err="scope"; log "[stage-error] M2 scope-changes.sh (exit $?)"; }
fi

# M3 — materialize@new + deduped, budget-capped hunt. FORWARD seam: --hunt-cmd/--source-cmd are passed to
# run-change-hunts.sh's OWN seams so the REAL M3 runs (real --max-hunts, real ledger dedup, real forge-slot).
m3_args=(--descriptors-from "$DESCRIPTORS" --ledger "$LEDGER" --max-hunts "$MAX_HUNTS"
         --out "$HUNT_OUT" --drop-dir "$DROP_DIR")
[ -n "$BACKEND" ] && m3_args+=(--backend "$BACKEND")
[ -n "$AGENTIS" ] && m3_args+=(--agentis "$AGENTIS")
[ -n "$MODEL" ]   && m3_args+=(--model "$MODEL")
[ -n "$HUNT_CMD" ]   && m3_args+=(--hunt-cmd "$HUNT_CMD")
[ -n "$SOURCE_CMD" ] && m3_args+=(--source-cmd "$SOURCE_CMD")
"$HERE/run-change-hunts.sh" "${m3_args[@]}" >>"$LOG" 2>&1 || { stage_err="hunt"; log "[stage-error] M3 run-change-hunts.sh (exit $?)"; }

# ---- derive the tick summary from FILE deltas (never from stderr parsing) ----------------------------------
after_changes="$(count_rows "$CHANGES")"
changes_seen=$((after_changes - before_changes)); [ "$changes_seen" -ge 0 ] || changes_seen=0
descriptors="$(count_rows "$DESCRIPTORS")"
ledger_total="$(count_rows "$LEDGER")"
findings_staged=$(( "$(pkg_count)" - before_pkgs )); [ "$findings_staged" -ge 0 ] || findings_staged=0

# Classify the ledger rows APPENDED this tick (tail past the pre-tick line count): a real hunt attempt that
# MATERIALIZED (finding|clean|hunt-error) vs a failed materialize (materialize-error, counted separately —
# it spends no hunt budget) vs a docs/tests-only skip (skipped-nohunt).
hunts_run=0; materialize_errors=0; skipped=0
if [ "$ledger_total" -gt "$before_ledger" ] && [ -f "$LEDGER" ]; then
  delta="$(tail -n +"$((before_ledger + 1))" "$LEDGER" 2>/dev/null | cut -f3)"
  hunts_run="$(printf '%s\n' "$delta" | grep -cE '^(finding|clean|hunt-error)$' || true)"
  materialize_errors="$(printf '%s\n' "$delta" | grep -cxF 'materialize-error' || true)"
  skipped="$(printf '%s\n' "$delta" | grep -cxF 'skipped-nohunt' || true)"
  case "$hunts_run" in ''|*[!0-9]*) hunts_run=0;; esac
  case "$materialize_errors" in ''|*[!0-9]*) materialize_errors=0;; esac
  case "$skipped" in ''|*[!0-9]*) skipped=0;; esac
fi

if [ -n "$stage_err" ]; then
  status="error"
elif [ "$changes_seen" -eq 0 ] && [ "$hunts_run" -eq 0 ] && [ "$materialize_errors" -eq 0 ]; then
  status="quiet"
else
  status="ok"
fi
write_summary "$status"
log "tick #$TICK_SEQ done: status=$status changes=$changes_seen descriptors=$descriptors hunts=$hunts_run materialize_errors=$materialize_errors staged=$findings_staged skipped=$skipped ledger=$ledger_total"
echo "change-pipeline: tick #$TICK_SEQ $status — changes=$changes_seen descriptors=$descriptors hunts=$hunts_run mat-err=$materialize_errors staged=$findings_staged skipped=$skipped (summary -> $SUMMARY)" >&2
exit 0
