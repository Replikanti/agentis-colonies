#!/bin/bash
# walk-forward.sh — out-of-sample (walk-forward) harness for the
# trading-binance 6-tribe replay (#1167).
#
# Trades the in-sample overfit of the single-window replay for an honest
# out-of-sample read: per fold it EVOLVES the strategists on a TRAIN window
# (run-replay.sh, evolution ON), FREEZES each tribe's final evolved prompt,
# then MEASURES that frozen strategy on a later UNSEEN TEST window
# (run-replay.sh with REPLAY_SEED_PROMPTS_DIR + a very high evolution
# threshold). Metrics are computed from the TEST run only, so a tribe's edge
# is judged on data it never trained on. Rolling forward across folds and
# aggregating the OOS expectancy is the gate before any edge claim, paper
# trading, or live size.
#
# Pipeline per fold N (train = trainStart..trainEnd, test = trainEnd..testEnd):
#   1. TRAIN  run-replay.sh on the train window, evolution ON. Capture run dir.
#   2. EXTRACT for each tribe: map tribe -> daemon pid via
#              <trainrun>/laptop-node/.agentis/logs/strategist-<t>.log
#              ('child started (pid=N)'), read the evolved prompt from
#              <trainrun>/laptop-node/.agentis/memo/strategist:<N>:strategy_prompt.jsonl
#              (`.value`), write to <wf-run>/fold-N/seed/tribe-<t>.txt.
#              Tribes with no pid / empty prompt are skipped (logged).
#   3. TEST   run-replay.sh on the test window with
#              REPLAY_SEED_PROMPTS_DIR=<fold-N/seed> and
#              STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=999999 (frozen).
#              Capture run dir.
#   4. SCORE  from the TEST run's trade-ledger.jsonl + settled-log lines:
#              directional trades, WIN/LOSS, total pnl_bps, mean pnl_bps/trade
#              (expectancy), profit factor — federation-wide and per-tribe.
# Aggregate across folds -> <wf-run>/walk-forward-summary.md + results.json
# under trading-binance/runs/, with an honest verdict (does OOS expectancy
# stay > 0 across folds, or not?).
#
# Env vars (all optional; defaults shown):
#   WF_SYMBOL            Binance futures symbol. Default: BTCUSDT
#   WF_TIMEFRAME         Candle interval: 30m | 1h | 1d. Default: 1h
#   WF_LOOKBACK          Past candles visible per tick. Default: 50
#   WF_HOLD              Forward candles for PnL settlement. Default: 8
#   WF_SPEED             Replay multiplier (forwarded to run-replay.sh).
#                        Default: 90
#   WF_DATA_DIR          PR-2 CSV root. Default: trading-binance/data
#   WF_FOLDS             Comma-separated fold specs, each
#                        `trainStart:trainEnd:testEnd` (UTC YYYY-MM-DD).
#                        train = trainStart..trainEnd evolves; test =
#                        trainEnd..testEnd is frozen. Default: two consecutive
#                        BTCUSDT 1h folds in 2026-03.
#   WF_RUN_DIR           Output dir override. Default: auto-timestamped under
#                        trading-binance/runs/wf-<YYYYMMDDTHHMMSSZ>/
#   WF_FREEZE_THRESHOLD  STRATEGIST_PROMPT_EVOLUTION_THRESHOLD for the TEST
#                        phase (high = frozen). Default: 999999
#   WF_REPLAY            Path to run-replay.sh. Default: resolved relative to
#                        this script (../trading-binance/tools/run-replay.sh).
#   WF_DRY_RUN           1 = print the fold plan + run-replay invocations,
#                        launch no containers. Default: "" (real run)
#
# Flags:
#   --dry-run            Same as WF_DRY_RUN=1.
#   --extract-prompt <trainrun> <tribe> <outfile>
#                        Internal mode: extract one tribe's evolved prompt
#                        from a finished TRAIN run dir into <outfile>.
#                        Exit 0 + writes file on success; exit 5 if no pid /
#                        empty prompt (file not written). Used by step 2 and
#                        by tools/test-walk-forward.sh.
#   -h | --help          Print this header.
#
# Output layout (under trading-binance/runs/wf-<YYYYMMDDTHHMMSSZ>/):
#   walk-forward.log          orchestrator's own log
#   fold-1/ ... fold-N/
#     seed/tribe-<t>.txt      frozen evolved prompts from the TRAIN run
#     fold-meta.json          fold windows + train/test run dir pointers
#   walk-forward-summary.md   per-fold + aggregate OOS metrics + verdict
#   results.json              machine-readable aggregate
#
# Exit codes:
#   0   walk-forward completed (or dry-run plan emitted)
#   1   prerequisite missing (run-replay.sh, python3 outside dry-run)
#   2   invalid args / fold spec
#   5   --extract-prompt found no pid / empty prompt (internal mode)

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$TOOLS_DIR")"
FED_DIR="$REPO_ROOT/trading-binance"
REPLAY="${WF_REPLAY:-$FED_DIR/tools/run-replay.sh}"

# --- Tribe roster (matches run-replay.sh) ---
TRIBES="alpha beta gamma delta epsilon zeta"

# ---------------------------------------------------------------------------
# extract_prompt <trainrun> <tribe> <outfile>
# Map a tribe to its daemon pid via the strategist log, read the evolved
# prompt body from the per-pid memo jsonl, write it to <outfile>. Returns 5
# (and writes nothing) when there is no pid or the prompt is empty.
# ---------------------------------------------------------------------------
extract_prompt() {
    trainrun="$1"; tribe="$2"; outfile="$3"
    python3 - "$trainrun" "$tribe" "$outfile" <<'PYEXTRACT'
import json
import os
import re
import sys

trainrun, tribe, outfile = sys.argv[1], sys.argv[2], sys.argv[3]

log_path = os.path.join(
    trainrun, "laptop-node", ".agentis", "logs", "strategist-" + tribe + ".log"
)
pid = ""
try:
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    m = re.search(r"child started \(pid=(\d+)", text)
    if m:
        pid = m.group(1)
except OSError:
    pass

if not pid:
    sys.stderr.write("extract: no pid for tribe-" + tribe + "\n")
    sys.exit(5)

memo_path = os.path.join(
    trainrun, "laptop-node", ".agentis", "memo",
    "strategist:" + pid + ":strategy_prompt.jsonl",
)
value = ""
try:
    with open(memo_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict) and "value" in rec:
                value = rec["value"]
except OSError:
    pass

if not isinstance(value, str) or value == "":
    sys.stderr.write("extract: empty prompt for tribe-" + tribe + " (pid=" + pid + ")\n")
    sys.exit(5)

os.makedirs(os.path.dirname(os.path.abspath(outfile)), exist_ok=True)
with open(outfile, "w", encoding="utf-8") as out:
    out.write(value)
sys.stderr.write("extract: tribe-" + tribe + " pid=" + pid + " bytes=" + str(len(value)) + "\n")
sys.exit(0)
PYEXTRACT
}

# ---------------------------------------------------------------------------
# Argument parsing — handle the internal --extract-prompt mode first so it
# can run container-free in tests, then fall through to orchestration flags.
# ---------------------------------------------------------------------------
DRY_RUN="${WF_DRY_RUN:-0}"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --extract-prompt)
            if [ $# -lt 4 ]; then
                echo "walk-forward: --extract-prompt needs <trainrun> <tribe> <outfile>" >&2
                exit 2
            fi
            extract_prompt "$2" "$3" "$4"
            exit $?
            ;;
        -h|--help)
            awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SCRIPT_PATH"
            exit 0
            ;;
        *)
            echo "walk-forward: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# --- Env-var defaults ---
SYMBOL="${WF_SYMBOL:-BTCUSDT}"
TIMEFRAME="${WF_TIMEFRAME:-1h}"
LOOKBACK="${WF_LOOKBACK:-50}"
HOLD="${WF_HOLD:-8}"
SPEED="${WF_SPEED:-90}"
DATA_DIR="${WF_DATA_DIR:-$FED_DIR/data}"
FOLDS="${WF_FOLDS:-2026-03-01:2026-03-08:2026-03-12,2026-03-01:2026-03-12:2026-03-16}"
FREEZE_THRESHOLD="${WF_FREEZE_THRESHOLD:-999999}"

# --- Validation ---
case "$TIMEFRAME" in
    30m|1h|1d) ;;
    *)
        echo "walk-forward: WF_TIMEFRAME must be one of 30m|1h|1d (got '$TIMEFRAME')" >&2
        exit 2
        ;;
esac

val=""
for var_name in LOOKBACK HOLD SPEED FREEZE_THRESHOLD; do
    eval "val=\${$var_name}"
    case "$val" in
        ''|*[!0-9]*)
            echo "walk-forward: $var_name must be a positive integer (got: $val)" >&2
            exit 2
            ;;
    esac
done
unset val

# Parse + validate fold specs into newline-separated trainStart\ttrainEnd\ttestEnd.
DATE_RE='^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$'
FOLD_LINES=""
FOLD_COUNT=0
OLD_IFS="$IFS"
IFS=','
for spec in $FOLDS; do
    [ -n "$spec" ] || continue
    train_start="${spec%%:*}"
    rest="${spec#*:}"
    train_end="${rest%%:*}"
    test_end="${rest##*:}"
    if [ "$train_start" = "$spec" ] || [ "$train_end" = "$rest" ] || \
       [ -z "$train_start" ] || [ -z "$train_end" ] || [ -z "$test_end" ]; then
        IFS="$OLD_IFS"
        echo "walk-forward: bad fold spec '$spec' (want trainStart:trainEnd:testEnd)" >&2
        exit 2
    fi
    for d in "$train_start" "$train_end" "$test_end"; do
        if ! printf '%s' "$d" | grep -Eq "$DATE_RE"; then
            IFS="$OLD_IFS"
            echo "walk-forward: bad date '$d' in fold '$spec' (want YYYY-MM-DD)" >&2
            exit 2
        fi
    done
    FOLD_LINES="${FOLD_LINES}${train_start}	${train_end}	${test_end}
"
    FOLD_COUNT=$((FOLD_COUNT + 1))
done
IFS="$OLD_IFS"

if [ "$FOLD_COUNT" -lt 1 ]; then
    echo "walk-forward: WF_FOLDS parsed to 0 folds" >&2
    exit 2
fi

# --- Per-run hermetic dir ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
WF_RUN="${WF_RUN_DIR:-$FED_DIR/runs/wf-$TS}"
WF_LOG="$WF_RUN/walk-forward.log"
WF_SUMMARY="$WF_RUN/walk-forward-summary.md"
WF_RESULTS="$WF_RUN/results.json"

# --- Dry-run / real-run dispatch helpers (mirrors run-replay.sh idiom) ---
emit_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '+ %s\n' "$*"
    else
        printf '+ %s\n' "$*" >>"$WF_LOG"
        # shellcheck disable=SC2294
        eval "$@"
    fi
}

emit_step() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '# %s\n' "$*"
    else
        printf '# %s\n' "$*" >>"$WF_LOG"
    fi
}

# --- Prerequisite checks (skipped in dry-run for portability) ---
if [ "$DRY_RUN" = "0" ]; then
    if [ ! -x "$REPLAY" ]; then
        echo "walk-forward: run-replay.sh not executable at $REPLAY" >&2
        exit 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "walk-forward: python3 not found on PATH" >&2
        exit 1
    fi
    mkdir -p "$WF_RUN"
    : >"$WF_LOG"
fi

emit_step "walk-forward: starting (dry_run=$DRY_RUN)"
emit_step "run dir: $WF_RUN"
emit_step "symbol: $SYMBOL"
emit_step "timeframe: $TIMEFRAME"
emit_step "lookback: $LOOKBACK"
emit_step "hold: $HOLD"
emit_step "speed: $SPEED"
emit_step "data dir: $DATA_DIR"
emit_step "freeze threshold (TEST phase): $FREEZE_THRESHOLD"
emit_step "folds: $FOLD_COUNT"

# ---------------------------------------------------------------------------
# run_replay_phase <phase> <run-dir-out> <start> <end> <evolution-threshold> [seed-dir]
# Invoke run-replay.sh for one TRAIN or TEST phase. In dry-run, prints the
# invocation. In real mode, runs it and tees the run dir from the trailing
# "[run-replay] run dir: <path>" line into the named output file.
# ---------------------------------------------------------------------------
run_replay_phase() {
    phase="$1"; run_dir_out="$2"; start="$3"; end="$4"; ev_threshold="$5"; phase_seed="${6:-}"
    seed_env=""
    if [ -n "$phase_seed" ]; then
        seed_env="REPLAY_SEED_PROMPTS_DIR=$phase_seed "
    fi
    inv="${seed_env}REPLAY_SYMBOL=$SYMBOL REPLAY_TIMEFRAME=$TIMEFRAME REPLAY_LOOKBACK_WINDOW=$LOOKBACK REPLAY_HOLD_PERIOD=$HOLD REPLAY_SPEED=$SPEED REPLAY_DATA_DIR=$DATA_DIR REPLAY_START=$start REPLAY_END=$end REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=$ev_threshold bash $REPLAY"
    emit_step "$phase phase: window $start..$end (evolution_threshold=$ev_threshold${phase_seed:+ seed=$phase_seed})"
    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "$inv"
        return 0
    fi
    phase_out="$WF_RUN/.${phase}.out"
    # shellcheck disable=SC2086
    if ! env ${seed_env}REPLAY_SYMBOL="$SYMBOL" REPLAY_TIMEFRAME="$TIMEFRAME" \
            REPLAY_LOOKBACK_WINDOW="$LOOKBACK" REPLAY_HOLD_PERIOD="$HOLD" \
            REPLAY_SPEED="$SPEED" REPLAY_DATA_DIR="$DATA_DIR" \
            REPLAY_START="$start" REPLAY_END="$end" \
            REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD="$ev_threshold" \
            bash "$REPLAY" >"$phase_out" 2>>"$WF_LOG"; then
        echo "walk-forward: $phase run-replay.sh failed (see $WF_LOG)" >&2
        exit 1
    fi
    cat "$phase_out" >>"$WF_LOG"
    rr_dir="$(grep -E '^\[run-replay\] run dir:' "$phase_out" | tail -1 | sed -E 's/^\[run-replay\] run dir:[[:space:]]*//')"
    printf '%s' "$rr_dir" >"$run_dir_out"
}

# ---------------------------------------------------------------------------
# score_test_run <testrun> <fold-meta> <out-json>
# Compute OOS metrics (directional trades, WIN/LOSS, total pnl_bps, mean
# pnl_bps/trade, profit factor) federation-wide + per-tribe from the TEST
# run's trade-ledger.jsonl + the per-tribe settled-log lines in
# .agentis/logs/strategist-<t>.log.
# ---------------------------------------------------------------------------
score_test_run() {
    testrun="$1"; out_json="$2"
    python3 - "$testrun" "$out_json" "$TRIBES" <<'PYSCORE'
import json
import os
import re
import sys

testrun, out_json, tribes_str = sys.argv[1], sys.argv[2], sys.argv[3]
tribes = tribes_str.split()


def blank():
    return {"trades": 0, "wins": 0, "losses": 0, "total_pnl_bps": 0.0,
            "gross_win_bps": 0.0, "gross_loss_bps": 0.0}


def settle(acc, tribe, pnl):
    a = acc.setdefault(tribe, blank())
    a["trades"] += 1
    a["total_pnl_bps"] += pnl
    if pnl > 0:
        a["wins"] += 1
        a["gross_win_bps"] += pnl
    elif pnl < 0:
        a["losses"] += 1
        a["gross_loss_bps"] += -pnl


acc = {}
fed = blank()

# Primary source: trade-ledger.jsonl. Rows carry pnl_bps + (when present)
# tribe; only directional (non-FLAT) settled trades count.
ledger = os.path.join(testrun, "trade-ledger.jsonl")
try:
    with open(ledger, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict):
                continue
            action = str(rec.get("action", rec.get("direction", ""))).upper()
            if action == "FLAT":
                continue
            if "pnl_bps" not in rec:
                continue
            try:
                pnl = float(rec["pnl_bps"])
            except (TypeError, ValueError):
                continue
            tribe = str(rec.get("tribe", rec.get("tribe_name", ""))).replace("tribe-", "")
            if tribe not in tribes:
                tribe = "_unknown"
            settle(acc, tribe, pnl)
            # federation aggregate
            fed["trades"] += 1
            fed["total_pnl_bps"] += pnl
            if pnl > 0:
                fed["wins"] += 1
                fed["gross_win_bps"] += pnl
            elif pnl < 0:
                fed["losses"] += 1
                fed["gross_loss_bps"] += -pnl
except OSError:
    pass

# Fallback / per-tribe enrichment: settled-log lines. The strategist logs a
# settlement line carrying pnl_bps=<N>; parse them per tribe only when the
# ledger yielded nothing for that tribe (so we never double-count).
pnl_re = re.compile(r"pnl_bps=(-?\d+(?:\.\d+)?)")
for tribe in tribes:
    if acc.get(tribe, blank())["trades"] > 0:
        continue
    log_path = os.path.join(
        testrun, "laptop-node", ".agentis", "logs", "strategist-" + tribe + ".log"
    )
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if "settle" not in line:
                    continue
                m = pnl_re.search(line)
                if not m:
                    continue
                try:
                    pnl = float(m.group(1))
                except ValueError:
                    continue
                settle(acc, tribe, pnl)
                fed["trades"] += 1
                fed["total_pnl_bps"] += pnl
                if pnl > 0:
                    fed["wins"] += 1
                    fed["gross_win_bps"] += pnl
                elif pnl < 0:
                    fed["losses"] += 1
                    fed["gross_loss_bps"] += -pnl
    except OSError:
        pass


def finalize(a):
    trades = a["trades"]
    expectancy = (a["total_pnl_bps"] / trades) if trades else 0.0
    gl = a["gross_loss_bps"]
    if gl > 0:
        profit_factor = a["gross_win_bps"] / gl
    elif a["gross_win_bps"] > 0:
        profit_factor = None  # inf — wins, no losses
    else:
        profit_factor = 0.0
    return {
        "trades": trades,
        "wins": a["wins"],
        "losses": a["losses"],
        "total_pnl_bps": round(a["total_pnl_bps"], 4),
        "expectancy_bps": round(expectancy, 4),
        "profit_factor": (round(profit_factor, 4) if profit_factor is not None else None),
    }


out = {
    "test_run": testrun,
    "federation": finalize(fed),
    "tribes": {t: finalize(acc.get(t, blank())) for t in tribes},
}
with open(out_json, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2)
print(json.dumps(out["federation"]))
PYSCORE
}

# ---------------------------------------------------------------------------
# Per-fold loop.
# ---------------------------------------------------------------------------
fold_idx=0
FOLD_RESULT_JSONS=""
while IFS='	' read -r train_start train_end test_end; do
    [ -n "$train_start" ] || continue
    fold_idx=$((fold_idx + 1))
    fold_dir="$WF_RUN/fold-$fold_idx"
    seed_dir="$fold_dir/seed"
    fold_result="$fold_dir/test-metrics.json"
    emit_step "=== fold $fold_idx/$FOLD_COUNT : train $train_start..$train_end -> test $train_end..$test_end ==="
    if [ "$DRY_RUN" = "0" ]; then
        mkdir -p "$seed_dir"
    fi

    # 1) TRAIN — evolution ON (run-replay default threshold).
    train_run_ptr="$fold_dir/.trainrun"
    if [ "$DRY_RUN" = "0" ]; then
        mkdir -p "$fold_dir"
    fi
    run_replay_phase "train" "$train_run_ptr" "$train_start" "$train_end" "3" ""

    # 2) EXTRACT — freeze each tribe's evolved prompt into the seed dir.
    emit_step "extracting frozen prompts -> $seed_dir/tribe-<t>.txt"
    if [ "$DRY_RUN" = "1" ]; then
        for t in $TRIBES; do
            emit_cmd "bash $SCRIPT_PATH --extract-prompt <trainrun> $t $seed_dir/tribe-$t.txt"
        done
    else
        trainrun="$(cat "$train_run_ptr")"
        for t in $TRIBES; do
            if extract_prompt "$trainrun" "$t" "$seed_dir/tribe-$t.txt" 2>>"$WF_LOG"; then
                emit_step "frozen: tribe-$t"
            else
                emit_step "skipped (no pid/empty prompt): tribe-$t"
            fi
        done
    fi

    # 3) TEST — frozen (seed dir + very high evolution threshold).
    test_run_ptr="$fold_dir/.testrun"
    run_replay_phase "test" "$test_run_ptr" "$train_end" "$test_end" "$FREEZE_THRESHOLD" "$seed_dir"

    # 4) SCORE — OOS metrics from the TEST run only.
    emit_step "scoring TEST run -> $fold_result"
    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "score-test-run <testrun> $fold_result"
    else
        testrun="$(cat "$test_run_ptr")"
        score_test_run "$testrun" "$fold_result" >>"$WF_LOG" 2>&1 || true
        # Stamp the fold index + windows into the metrics file so the
        # aggregator can label folds without re-deriving from path shape.
        python3 -c 'import json,sys
p=sys.argv[1]
try:
    d=json.load(open(p))
except OSError:
    d={}
d["fold"]=int(sys.argv[2]); d["train_start"]=sys.argv[3]; d["train_end"]=sys.argv[4]; d["test_end"]=sys.argv[5]
json.dump(d, open(p,"w"), indent=2)' \
            "$fold_result" "$fold_idx" "$train_start" "$train_end" "$test_end" || true
        FOLD_RESULT_JSONS="$FOLD_RESULT_JSONS $fold_result"
        # fold-meta.json: windows + run dir pointers.
        python3 -c 'import json,sys; json.dump({"fold":int(sys.argv[1]),"train_start":sys.argv[2],"train_end":sys.argv[3],"test_end":sys.argv[4],"train_run":sys.argv[5],"test_run":sys.argv[6]}, open(sys.argv[7],"w"), indent=2)' \
            "$fold_idx" "$train_start" "$train_end" "$test_end" \
            "$(cat "$train_run_ptr")" "$(cat "$test_run_ptr")" \
            "$fold_dir/fold-meta.json"
    fi
done <<EOF
$FOLD_LINES
EOF

# ---------------------------------------------------------------------------
# Aggregate across folds -> summary + results.json (real run only).
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
    emit_step "dry-run complete; $FOLD_COUNT folds planned, no containers spawned"
    exit 0
fi

emit_step "aggregating $FOLD_COUNT folds -> $WF_SUMMARY + $WF_RESULTS"
# shellcheck disable=SC2086
python3 - "$WF_RUN" "$WF_SUMMARY" "$WF_RESULTS" "$SYMBOL" "$TIMEFRAME" $FOLD_RESULT_JSONS <<'PYAGG'
import json
import sys

wf_run, summary_path, results_path, symbol, timeframe = sys.argv[1:6]
fold_jsons = sys.argv[6:]

folds = []
for fj in fold_jsons:
    try:
        with open(fj, "r", encoding="utf-8") as f:
            folds.append(json.load(f))
    except OSError:
        continue

agg = {"trades": 0, "wins": 0, "losses": 0, "total_pnl_bps": 0.0}
for fd in folds:
    fed = fd.get("federation", {})
    agg["trades"] += fed.get("trades", 0)
    agg["wins"] += fed.get("wins", 0)
    agg["losses"] += fed.get("losses", 0)
    agg["total_pnl_bps"] += fed.get("total_pnl_bps", 0.0)

agg_trades = agg["trades"]
agg_expectancy = (agg["total_pnl_bps"] / agg_trades) if agg_trades else 0.0

# Verdict: OOS edge survives only if expectancy stays > 0 on EVERY fold AND
# the aggregate expectancy is > 0.
per_fold_exp = [fd.get("federation", {}).get("expectancy_bps", 0.0) for fd in folds]
all_positive = bool(per_fold_exp) and all(e > 0 for e in per_fold_exp)
if all_positive and agg_expectancy > 0:
    verdict = ("EDGE SURVIVES OOS: federation expectancy is positive on every "
               "fold and in aggregate (%.4f bps/trade). Gate to paper trading, "
               "with the single-symbol / single-regime caveats below." % agg_expectancy)
else:
    verdict = ("NO OOS EDGE: federation expectancy is not positive across all "
               "folds (aggregate %.4f bps/trade). The frozen evolved strategy "
               "does not generalise to unseen windows — do not advance to paper "
               "trading or live size on this evidence." % agg_expectancy)

results = {
    "symbol": symbol,
    "timeframe": timeframe,
    "fold_count": len(folds),
    "aggregate": {
        "trades": agg_trades,
        "wins": agg["wins"],
        "losses": agg["losses"],
        "total_pnl_bps": round(agg["total_pnl_bps"], 4),
        "expectancy_bps": round(agg_expectancy, 4),
    },
    "folds": folds,
    "verdict": verdict,
}
with open(results_path, "w", encoding="utf-8") as f:
    json.dump(results, f, indent=2)

lines = []
lines.append("# Walk-forward summary — " + symbol + " " + timeframe)
lines.append("")
lines.append("Out-of-sample (walk-forward) evaluation: each fold evolves the "
             "strategists on a TRAIN window, freezes the evolved prompts, and "
             "scores them on a later UNSEEN TEST window. Metrics below are from "
             "the TEST runs only.")
lines.append("")
lines.append("## Aggregate (across " + str(len(folds)) + " folds)")
lines.append("")
lines.append("| Trades | Wins | Losses | Total PnL (bps) | Expectancy (bps/trade) |")
lines.append("|---|---|---|---|---|")
lines.append("| %d | %d | %d | %.4f | %.4f |" % (
    agg_trades, agg["wins"], agg["losses"],
    round(agg["total_pnl_bps"], 4), round(agg_expectancy, 4)))
lines.append("")
for fd in folds:
    fed = fd.get("federation", {})
    window = ""
    if fd.get("train_end") and fd.get("test_end"):
        window = " (TEST window %s..%s)" % (fd.get("train_end"), fd.get("test_end"))
    lines.append("## Fold %s%s" % (str(fd.get("fold", "?")), window))
    lines.append("")
    lines.append("TEST run: " + str(fd.get("test_run", "?")))
    lines.append("")
    lines.append("| Scope | Trades | Wins | Losses | Total PnL (bps) | Expectancy (bps) | Profit factor |")
    lines.append("|---|---|---|---|---|---|---|")
    pf = fed.get("profit_factor")
    pf_s = "inf" if pf is None else ("%.4f" % pf)
    lines.append("| federation | %d | %d | %d | %.4f | %.4f | %s |" % (
        fed.get("trades", 0), fed.get("wins", 0), fed.get("losses", 0),
        fed.get("total_pnl_bps", 0.0), fed.get("expectancy_bps", 0.0), pf_s))
    for t, tm in sorted(fd.get("tribes", {}).items()):
        tpf = tm.get("profit_factor")
        tpf_s = "inf" if tpf is None else ("%.4f" % tpf)
        lines.append("| tribe-%s | %d | %d | %d | %.4f | %.4f | %s |" % (
            t, tm.get("trades", 0), tm.get("wins", 0), tm.get("losses", 0),
            tm.get("total_pnl_bps", 0.0), tm.get("expectancy_bps", 0.0), tpf_s))
    lines.append("")
lines.append("## Verdict")
lines.append("")
lines.append(verdict)
lines.append("")
lines.append("### Caveats")
lines.append("")
lines.append("- Single symbol (" + symbol + ") unless extended.")
lines.append("- Each OOS window is still one market regime.")
lines.append("- The frozen state is the evolved prompt text only (no other state).")
lines.append("- Cost is ~N x the single-run replay cost (one TRAIN + one TEST per fold).")
with open(summary_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

print(verdict)
PYAGG

emit_step "walk-forward: done"
echo "[walk-forward] run dir: $WF_RUN"
echo "[walk-forward] summary: $WF_SUMMARY"
