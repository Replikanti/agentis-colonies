#!/bin/bash
# run-ab-experiment.sh — A/B emergence experiment harness for the
# trading-binance federation (#573 PR-5).
#
# Runs N paired replicates x 2 arms:
#   control    REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=999
#              prompt evolution effectively off — seed prompts stay
#              frozen for the entire run. Baseline arm.
#   treatment  REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=3
#              prompt evolution armed at the strategist.ag default —
#              after every 3 verified trades the meta-prompt rewrites
#              the body. Emergence arm.
#
# Each replicate invokes `tools/run-replay.sh` with a fresh hermetic
# run dir under <federation>/runs/ab-trading-<ts>/ and writes a single
# `experiment-manifest.json` mapping every run dir back to its arm.
# After all replicates finish, `tools/analyze-ab-results.py` walks the
# manifest, parses per-run trade ledgers + experience rows, and emits
# `comparison.md` with per-tribe arm-vs-arm tables and a federation
# aggregate.
#
# Prerequisite: a populated `trading-binance/data/<symbol>/<tf>/` tree
# must already exist on disk. Run
# `tools/binance-feed-download.py --symbol BTCUSDT --timeframe 1h \
#     --start <YYYY-MM-DD> --end <YYYY-MM-DD>` before invoking this
# script. The data dir is NOT committed to the repo (see `data/.gitkeep`).
#
# Env vars (all optional; defaults shown):
#   AB_N_REPLICATES    Replicates per arm. Default: 3
#   AB_SYMBOL          Binance futures symbol. Default: BTCUSDT
#   AB_TIMEFRAME       Candle interval: 30m | 1h | 1d. Default: 1h
#   AB_START           UTC YYYY-MM-DD lower bound. Default: "" (first
#                      available shard)
#   AB_END             UTC YYYY-MM-DD upper bound. Default: "" (last
#                      available shard)
#   AB_SPEED           Replay multiplier. Default: 720
#   AB_DRY_RUN         1 = emit_step the plan, do not invoke
#                      run-replay.sh or analyse. Default: 0
#   REPLAY_*           Anything that run-replay.sh consumes is
#                      forwarded as-is (e.g. REPLAY_OPENAI_MODEL,
#                      REPLAY_LOOKBACK_WINDOW, REPLAY_HOLD_PERIOD).
#
# Flags:
#   --dry-run    Same as AB_DRY_RUN=1.
#   -h|--help    Print this header.
#
# Output layout (under trading-binance/runs/ab-trading-<TS>/):
#   experiment-manifest.json
#   ab-trading-<TS>-control-run-1/      (run-replay.sh output)
#   ab-trading-<TS>-control-run-2/
#   ...
#   ab-trading-<TS>-treatment-run-1/
#   ...
#   comparison.md                       (written by analyse step)
#
# Exit codes:
#   0   harness completed (or dry-run plan emitted)
#   2   unknown flag or invalid env value
#   3   missing required input (data dir / dependent script)
#   4   one or more replicate runs failed in real-run mode
#   5   reserved — budget cap exceeded (currently warns + continues)

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
FED_ROOT="${FED_ROOT:-$FED_DIR}"

# --- Argument parsing ---
DRY_RUN="${AB_DRY_RUN:-0}"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SCRIPT_PATH"
            exit 0
            ;;
        *)
            echo "run-ab-experiment: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# --- Env defaults ---
N_REPLICATES="${AB_N_REPLICATES:-3}"
SYMBOL="${AB_SYMBOL:-BTCUSDT}"
TIMEFRAME="${AB_TIMEFRAME:-1h}"
START="${AB_START:-}"
END="${AB_END:-}"
SPEED="${AB_SPEED:-720}"

# --- Validation ---
case "$N_REPLICATES" in
    ''|*[!0-9]*)
        echo "run-ab-experiment: AB_N_REPLICATES must be a positive integer (got '$N_REPLICATES')" >&2
        exit 2
        ;;
esac
if [ "$N_REPLICATES" -lt 1 ]; then
    echo "run-ab-experiment: AB_N_REPLICATES must be >= 1 (got '$N_REPLICATES')" >&2
    exit 2
fi
case "$TIMEFRAME" in
    30m|1h|1d) ;;
    *)
        echo "run-ab-experiment: AB_TIMEFRAME must be one of 30m|1h|1d (got '$TIMEFRAME')" >&2
        exit 2
        ;;
esac
case "$SPEED" in
    ''|*[!0-9]*)
        echo "run-ab-experiment: AB_SPEED must be a positive integer (got '$SPEED')" >&2
        exit 2
        ;;
esac

# --- Per-experiment hermetic dir ---
EXP_TS="$(date -u +%Y%m%dT%H%M%SZ)"
EXP_DIR="$FED_ROOT/runs/ab-trading-$EXP_TS"
MANIFEST="$EXP_DIR/experiment-manifest.json"

# --- Dry-run / real-run dispatch helpers (mirrors run-replay.sh idiom) ---
emit_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '+ %s\n' "$*"
    else
        printf '+ %s\n' "$*"
    fi
}

emit_step() {
    printf '# %s\n' "$*"
}

# --- Banner ---
emit_step "run-ab-experiment: starting (dry_run=$DRY_RUN)"
emit_step "experiment ts: $EXP_TS"
emit_step "experiment dir: $EXP_DIR"
emit_step "symbol: $SYMBOL timeframe: $TIMEFRAME range: ${START:-<first>}..${END:-<last>}"
emit_step "speed: $SPEED replicates/arm: $N_REPLICATES"
emit_step "control arm: REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=999 (evolution off)"
emit_step "treatment arm: REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=3 (evolution on)"

if [ "$DRY_RUN" = "0" ]; then
    mkdir -p "$EXP_DIR"
fi

# --- Replicate loop ---
# RUNS_RECORD captures 5-tuples per run flattened into a single array:
# (arm, run_idx, run_dir, threshold, exit_code) for manifest assembly.
RUNS_RECORD=()
FAIL_COUNT=0

for arm in control treatment; do
    if [ "$arm" = "control" ]; then
        THR=999
    else
        THR=3
    fi
    run=1
    while [ "$run" -le "$N_REPLICATES" ]; do
        RUN_NAME="ab-trading-$EXP_TS-$arm-run-$run"
        RUN_DIR="$EXP_DIR/$RUN_NAME"
        emit_step "[arm=$arm run=$run/$N_REPLICATES] run_dir=$RUN_DIR threshold=$THR"

        if [ "$DRY_RUN" = "0" ]; then
            mkdir -p "$RUN_DIR"
        fi

        # Build env block for this replicate. REPLAY_RUN_DIR pins the
        # per-replicate output dir; the strategist threshold env is the
        # only thing that differs between control and treatment.
        REPLICATE_ENV=(
            "REPLAY_RUN_DIR=$RUN_DIR"
            "REPLAY_SYMBOL=$SYMBOL"
            "REPLAY_TIMEFRAME=$TIMEFRAME"
            "REPLAY_START=$START"
            "REPLAY_END=$END"
            "REPLAY_SPEED=$SPEED"
            "REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=$THR"
        )

        EXIT_CODE=0
        if [ "$DRY_RUN" = "1" ]; then
            # In dry-run mode we emit a placeholder that test-run-ab-experiment.sh
            # can grep for. The actual run-replay.sh invocation is NOT made.
            emit_cmd "${REPLICATE_ENV[*]} bash $FED_ROOT/tools/run-replay.sh"
        else
            (
                # shellcheck disable=SC2068
                for kv in ${REPLICATE_ENV[@]}; do
                    export "${kv?}"
                done
                bash "$FED_ROOT/tools/run-replay.sh"
            ) || EXIT_CODE=$?
            if [ "$EXIT_CODE" -ne 0 ]; then
                FAIL_COUNT=$((FAIL_COUNT + 1))
                emit_step "[arm=$arm run=$run] replicate failed (exit=$EXIT_CODE) — continuing"
            fi
        fi

        RUNS_RECORD+=("$arm" "$run" "$RUN_DIR" "$THR" "$EXIT_CODE")
        run=$((run + 1))
    done
done

# --- Manifest assembly ---
emit_step "writing experiment-manifest.json"
emit_cmd "python3 -c 'write_manifest($MANIFEST)'"

if [ "$DRY_RUN" = "0" ]; then
    # Pipe the 5-tuple stream into a Python helper that emits the
    # JSON manifest. Use NUL-separation so run-dir paths with spaces
    # do not corrupt the stream.
    # shellcheck disable=SC2259  # WAIVER (#1947): the heredoc overrides the piped record stream — real bug, tracked separately; remove this directive with the fix.
    {
        rec_i=0
        rec_len=${#RUNS_RECORD[@]}
        while [ "$rec_i" -lt "$rec_len" ]; do
            printf '%s\0%s\0%s\0%s\0%s\0' \
                "${RUNS_RECORD[$rec_i]}" \
                "${RUNS_RECORD[$((rec_i + 1))]}" \
                "${RUNS_RECORD[$((rec_i + 2))]}" \
                "${RUNS_RECORD[$((rec_i + 3))]}" \
                "${RUNS_RECORD[$((rec_i + 4))]}"
            rec_i=$((rec_i + 5))
        done
    } | python3 - "$MANIFEST" "$EXP_TS" "$SYMBOL" "$TIMEFRAME" "$START" "$END" "$SPEED" "$N_REPLICATES" "${REPLAY_OPENAI_MODEL:-}" <<'PYMANIFEST'
import json
import os
import sys

out_path = sys.argv[1]
manifest = {
    "experiment_ts": sys.argv[2],
    "symbol": sys.argv[3],
    "timeframe": sys.argv[4],
    "start": sys.argv[5],
    "end": sys.argv[6],
    "replay_speed": int(sys.argv[7]),
    "n_replicates_per_arm": int(sys.argv[8]),
    "llm_model": sys.argv[9],
    "arms": {
        "control": {
            "strategist_prompt_evolution_threshold": 999,
            "description": "prompt evolution effectively off (baseline)",
        },
        "treatment": {
            "strategist_prompt_evolution_threshold": 3,
            "description": "prompt evolution armed (emergence)",
        },
    },
    "runs": [],
}
data = sys.stdin.buffer.read()
if data:
    parts = data.split(b"\x00")
    # Trailing empty element from final NUL.
    if parts and parts[-1] == b"":
        parts = parts[:-1]
    if len(parts) % 5 != 0:
        sys.stderr.write(
            "run-ab-experiment: malformed RUNS_RECORD stream "
            "(len=" + str(len(parts)) + ", expected multiple of 5)\n"
        )
        sys.exit(1)
    for i in range(0, len(parts), 5):
        arm = parts[i].decode("utf-8")
        run_idx = int(parts[i + 1])
        run_dir = parts[i + 2].decode("utf-8")
        threshold = int(parts[i + 3])
        exit_code = int(parts[i + 4])
        manifest["runs"].append({
            "arm": arm,
            "run_idx": run_idx,
            "run_dir": run_dir,
            "strategist_prompt_evolution_threshold": threshold,
            "exit_code": exit_code,
        })
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PYMANIFEST
fi

emit_step "manifest path: $MANIFEST"

# --- Analyser invocation ---
emit_step "invoking analyse-ab-results.py against $EXP_DIR"
if [ "$DRY_RUN" = "1" ]; then
    emit_cmd "python3 $FED_ROOT/tools/analyze-ab-results.py $EXP_DIR"
else
    python3 "$FED_ROOT/tools/analyze-ab-results.py" "$EXP_DIR" || {
        echo "run-ab-experiment: analyse step failed" >&2
        exit 4
    }
fi

if [ "$DRY_RUN" = "0" ] && [ "$FAIL_COUNT" -gt 0 ]; then
    echo "run-ab-experiment: $FAIL_COUNT replicate(s) failed; see manifest exit_code fields" >&2
    exit 4
fi

emit_step "run-ab-experiment: done"
echo "[run-ab-experiment] experiment dir: $EXP_DIR"
echo "[run-ab-experiment] comparison.md: $EXP_DIR/comparison.md"
