#!/bin/bash
# run-replay.sh — offline historical-feed replay orchestrator for the
# trading-binance federation (#573 PR-3).
#
# Streams PR-2 CSV candles from `trading-binance/data/<symbol>/<tf>/<date>.csv`
# tick-by-tick to agentis daemons running inside a single podman container.
# Mirrors tribes-bench/run-stage3-docker.sh architectural shape (emit_step
# helper, run dir under <federation>/runs/<timestamp>/, sandbox cp idiom)
# but adapts the rotation loop into a candle-tick loop instead of a
# planted-bug-surface rotation.
#
# Spawns one source strategist daemon per tribe (alpha / beta / gamma /
# delta / epsilon / zeta). Each tribe's M2-Malthusian replicate gate grows the
# population from there. The deterministic PnL verifier
# (`tools/verify-trade.sh`) settles trades HOLD_PERIOD candles forward
# of each decision; no LLM is involved in the verifier path.
#
# Env vars (all optional; defaults shown):
#   REPLAY_DATA_DIR              PR-2 CSV root.
#                                Default: trading-binance/data
#   REPLAY_SYMBOL                Binance futures symbol.
#                                Default: BTCUSDT
#   REPLAY_TIMEFRAME             Candle interval: 30m | 1h | 1d.
#                                Default: 30m
#   REPLAY_START                 UTC YYYY-MM-DD lower bound (inclusive).
#                                Default: "" (first available shard)
#   REPLAY_END                   UTC YYYY-MM-DD upper bound (inclusive).
#                                Default: "" (last available shard)
#   REPLAY_SPEED                 Replay multiplier. 100 = 1h market data
#                                in 36s wall clock. Default: 100
#   REPLAY_DAEMON_COUNT          Number of strategist daemons to spawn.
#                                Default: 6
#   REPLAY_LLM_BACKEND           llm.backend value injected into hermetic
#                                config. Default: openai
#   REPLAY_OPENAI_ENDPOINT       Chat-completions URL.
#                                Default: https://openrouter.ai/api/v1/chat/completions
#   REPLAY_OPENAI_MODEL          Model id when backend=openai.
#                                Default: qwen/qwen3-coder-30b-a3b-instruct
#   REPLAY_OPENAI_KEY_ENV        Env var carrying the LLM API key.
#                                Default: OPENROUTER_API_KEY
#   REPLAY_OPENAI_TIMEOUT_MS     Per-request timeout (ms). Default: 180000
#   REPLAY_DAEMON_CB_PER_TICK    Per-tick CB replenishment written into
#                                hermetic .agentis/config as
#                                `daemon.cb_per_tick`. Default 2000 —
#                                well above the agentis-core default of
#                                100 which empirically bricks LLM-heavy
#                                strategist daemons after ~1 tick once
#                                the `cb 200000000;` lifetime budget
#                                drains. Mirrors tribes-bench #528.
#                                Hermetic memo store also bumped from
#                                agentis-core default 500 to 50000 in the
#                                hermetic config to cover ~100 ticks ×
#                                5 daemons × per-pid decision keys.
#                                Mirrors tribes-bench #544 chunk 2.
#   REPLAY_DAEMON_HEARTBEAT_MS   Watchdog heartbeat threshold (ms). Default
#                                1800000 (30min). agentis-core default is
#                                10000ms which kills daemons mid-prompt
#                                when LLM round-trip exceeds 10s (Qwen3
#                                with 21KB candle context takes 5-15s).
#                                Mirrors tribes-bench #571.
#   REPLAY_LOOKBACK_WINDOW       Past candles visible to daemon per tick.
#                                Default: 200
#   REPLAY_HOLD_PERIOD           Forward candles for PnL settlement.
#                                Default: 8
#   REPLAY_DRY_RUN               1 = emit_step the plan, skip podman.
#                                Default: "" (real run)
#   REPLAY_RUN_DIR               Output dir override. Default: auto-
#                                timestamped under trading-binance/runs/
#   REPLAY_IMAGE_TAG             Container image tag built from
#                                Containerfile.replay.
#                                Default: trading-binance-replay:latest
#   REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD
#                                Verified-trade count required before
#                                strategist.ag rewrites its prompt body
#                                (M98 v3). Set to a large number (e.g.
#                                999) to disable prompt evolution for
#                                the A/B control arm. Default: 3
#   REPLAY_STRATEGIST_PROMPT_GEN_CAP
#                                Per-lineage generation cap before
#                                reset; forward-compat knob threaded
#                                into the daemon env so the A/B harness
#                                can pin it. Default: 10
#   REPLAY_STRATEGIST_PROMPT_MAX_BYTES
#                                Hard byte cap on rewritten prompt
#                                bodies; forward-compat. Default: 8192
#   REPLAY_STRATEGIST_PROMPT_LEVENSHTEIN_FLOOR
#                                Minimum dissimilarity percent for a
#                                rewrite to be accepted (else no-op);
#                                forward-compat. Default: 20
#   REPLAY_STRATEGIST_FITNESS_REWARD_WIN_PER_BPS
#                                Fitness reward multiplier per bps of
#                                positive PnL; forward-compat. Default: 1
#   REPLAY_STRATEGIST_FITNESS_PENALTY_LOSS_PER_BPS
#                                Fitness penalty multiplier per bps of
#                                negative PnL; forward-compat. Default: 1
#
# Flags:
#   --dry-run    Same as REPLAY_DRY_RUN=1.
#
# Output layout (under trading-binance/runs/<YYYYMMDDTHHMMSSZ>/):
#   orchestrator.log              orchestrator's own log
#   run-meta.json                 config dump (symbol, tf, range, knobs)
#   candles.csv                   unified candle stream from load-candles.py
#   laptop-node/
#     bootstrap.sh                container bootstrap (real run only)
#     .agentis/
#       sandbox/context-stream/   per-tick context CSVs
#       logs/
#       spend/
#   trade-ledger.jsonl            empty placeholder; PR-4 populates
#   telemetry-combined.csv        empty placeholder; PR-5 analyser fills
#
# Exit codes:
#   0   replay completed (or dry-run plan emitted)
#   1   prerequisite missing (podman, python3 outside dry-run)
#   2   invalid env (e.g. unknown timeframe)
#   3   candle loading failed
#   4   container spawn failed

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

# --- Argument parsing ---
DRY_RUN="${REPLAY_DRY_RUN:-0}"
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
            echo "run-replay: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# --- Env-var defaults ---
DATA_DIR_RAW="${REPLAY_DATA_DIR:-$FED_DIR/data}"
SYMBOL="${REPLAY_SYMBOL:-BTCUSDT}"
TIMEFRAME="${REPLAY_TIMEFRAME:-30m}"
START="${REPLAY_START:-}"
END="${REPLAY_END:-}"
SPEED="${REPLAY_SPEED:-100}"
DAEMON_COUNT="${REPLAY_DAEMON_COUNT:-6}"
LLM_BACKEND="${REPLAY_LLM_BACKEND:-openai}"
OPENAI_ENDPOINT="${REPLAY_OPENAI_ENDPOINT:-https://openrouter.ai/api/v1/chat/completions}"
OPENAI_MODEL="${REPLAY_OPENAI_MODEL:-qwen/qwen3-coder-30b-a3b-instruct}"
OPENAI_KEY_ENV="${REPLAY_OPENAI_KEY_ENV:-OPENROUTER_API_KEY}"
OPENAI_TIMEOUT_MS="${REPLAY_OPENAI_TIMEOUT_MS:-180000}"
DAEMON_CB_PER_TICK="${REPLAY_DAEMON_CB_PER_TICK:-2000}"
DAEMON_HEARTBEAT_MS="${REPLAY_DAEMON_HEARTBEAT_MS:-1800000}"
LOOKBACK_WINDOW="${REPLAY_LOOKBACK_WINDOW:-200}"
HOLD_PERIOD="${REPLAY_HOLD_PERIOD:-8}"
IMAGE_TAG="${REPLAY_IMAGE_TAG:-trading-binance-replay:latest}"

# Strategist M98 v3 prompt-evolution + fitness knobs. The first one
# (THRESHOLD) is the A/B emergence experiment's primary lever:
#   control arm  = 999  (evolution effectively off)
#   treatment arm = 3   (evolution armed, matches strategist.ag default)
# The rest are forward-compat knobs threaded through to the per-tribe
# daemon env so the A/B harness has a single surface to pin them on.
: "${REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD:=3}"
: "${REPLAY_STRATEGIST_PROMPT_GEN_CAP:=10}"
: "${REPLAY_STRATEGIST_PROMPT_MAX_BYTES:=8192}"
: "${REPLAY_STRATEGIST_PROMPT_LEVENSHTEIN_FLOOR:=20}"
: "${REPLAY_STRATEGIST_FITNESS_REWARD_WIN_PER_BPS:=1}"
: "${REPLAY_STRATEGIST_FITNESS_PENALTY_LOSS_PER_BPS:=1}"

# --- Validation ---
case "$TIMEFRAME" in
    30m|1h|1d) ;;
    *)
        echo "run-replay: REPLAY_TIMEFRAME must be one of 30m|1h|1d (got '$TIMEFRAME')" >&2
        exit 2
        ;;
esac

case "$TIMEFRAME" in
    30m) INTERVAL_SECONDS=1800 ;;
    1h)  INTERVAL_SECONDS=3600 ;;
    1d)  INTERVAL_SECONDS=86400 ;;
esac

val=""
for var_name in SPEED DAEMON_COUNT LOOKBACK_WINDOW HOLD_PERIOD OPENAI_TIMEOUT_MS; do
    eval "val=\${$var_name}"
    case "$val" in
        ''|*[!0-9]*)
            echo "run-replay: $var_name must be a positive integer (got: $val)" >&2
            exit 2
            ;;
    esac
done
unset val

if [ "$SPEED" -lt 1 ]; then
    echo "run-replay: REPLAY_SPEED must be >= 1 (got: $SPEED)" >&2
    exit 2
fi
if [ "$DAEMON_COUNT" -lt 1 ]; then
    echo "run-replay: REPLAY_DAEMON_COUNT must be >= 1 (got: $DAEMON_COUNT)" >&2
    exit 2
fi

# Resolve DATA_DIR to absolute path (so we can pass it into containers /
# helpers safely regardless of where the orchestrator is launched from).
if [ -d "$DATA_DIR_RAW" ]; then
    DATA_DIR="$(cd "$DATA_DIR_RAW" && pwd)"
else
    # Resolve later — load-candles.py is the single point of "data dir
    # exists" enforcement so the dry-run path can still emit_step a plan
    # without a populated data dir on disk.
    DATA_DIR="$DATA_DIR_RAW"
fi

# --- Per-run hermetic dir ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${REPLAY_RUN_DIR:-$FED_DIR/runs/$TS}"
ORCH_LOG="$RUN_DIR/orchestrator.log"
RUN_META="$RUN_DIR/run-meta.json"
CANDLES_CSV="$RUN_DIR/candles.csv"
LAPTOP_DIR="$RUN_DIR/laptop-node"
SANDBOX_CTX="$LAPTOP_DIR/.agentis/sandbox/context-stream"
TRADE_LEDGER="$RUN_DIR/trade-ledger.jsonl"
TELEMETRY_CSV="$RUN_DIR/telemetry-combined.csv"

# --- Dry-run / real-run dispatch helpers (mirrors tribes-bench idiom) ---
emit_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '+ %s\n' "$*"
    else
        printf '+ %s\n' "$*" >>"$ORCH_LOG"
        # shellcheck disable=SC2294
        eval "$@"
    fi
}

emit_step() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '# %s\n' "$*"
    else
        printf '# %s\n' "$*" >>"$ORCH_LOG"
    fi
}

# --- Prerequisite checks (skipped in dry-run for portability) ---
if [ "$DRY_RUN" = "0" ]; then
    for bin in podman python3; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            echo "run-replay: $bin not found on PATH" >&2
            exit 1
        fi
    done
    if [ "$LLM_BACKEND" = "openai" ]; then
        eval "openai_key_value=\${$OPENAI_KEY_ENV:-}"
        if [ -z "${openai_key_value:-}" ]; then
            echo "run-replay: \$$OPENAI_KEY_ENV is empty (required for llm.backend=openai)" >&2
            exit 1
        fi
        unset openai_key_value
    fi
    mkdir -p "$RUN_DIR" "$LAPTOP_DIR" "$SANDBOX_CTX" "$LAPTOP_DIR/.agentis/logs" "$LAPTOP_DIR/.agentis/spend"
    : >"$ORCH_LOG"
    : >"$TRADE_LEDGER"
    : >"$TELEMETRY_CSV"
fi

emit_step "run-replay: starting (dry_run=$DRY_RUN)"
emit_step "run dir: $RUN_DIR"
emit_step "replay symbol: $SYMBOL"
emit_step "timeframe: $TIMEFRAME (interval=${INTERVAL_SECONDS}s)"
emit_step "date range: start=${START:-<first>} end=${END:-<last>}"
emit_step "replay speed: $SPEED"
emit_step "daemon count: $DAEMON_COUNT"
emit_step "lookback window: $LOOKBACK_WINDOW"
emit_step "hold period: $HOLD_PERIOD"
emit_step "llm backend: $LLM_BACKEND"
emit_step "image tag: $IMAGE_TAG"
emit_step "data dir: $DATA_DIR"

# --- 1) Load candles via helper (single point of file-existence enforcement) ---
# Candles land in two places:
#   - $RUN_DIR/candles.csv (host-side; primary copy for the analyser
#     pipeline that consumes the run dir after the container exits).
#   - $LAPTOP_DIR/candles.csv (mirror; visible inside the container at
#     /run-root/candles.csv so the strategist daemons' verifier
#     invocations resolve via CANDLES_CSV env).
# The mirror is cp'd (not symlinked) so the container does not need
# host-path resolution at runtime.
load_candles() {
    emit_step "loading candle stream via load-candles.py"
    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "python3 $TOOLS_DIR/load-candles.py --data-dir $DATA_DIR --symbol $SYMBOL --timeframe $TIMEFRAME --start \"$START\" --end \"$END\" > $CANDLES_CSV"
        emit_cmd "cp $CANDLES_CSV $LAPTOP_DIR/candles.csv"
        return 0
    fi
    if ! python3 "$TOOLS_DIR/load-candles.py" \
            --data-dir "$DATA_DIR" \
            --symbol "$SYMBOL" \
            --timeframe "$TIMEFRAME" \
            --start "$START" \
            --end "$END" >"$CANDLES_CSV" 2>>"$ORCH_LOG"; then
        echo "run-replay: load-candles.py failed (see $ORCH_LOG)" >&2
        exit 3
    fi
    cp "$CANDLES_CSV" "$LAPTOP_DIR/candles.csv"
    candle_lines=$(($(wc -l <"$CANDLES_CSV") - 1))
    emit_step "candles loaded: $candle_lines rows (mirrored into laptop-node)"
}

# --- 2) Build (or reuse) the container image ---
build_image() {
    emit_step "checking for existing image $IMAGE_TAG (build if missing)"
    emit_cmd "podman image exists $IMAGE_TAG || podman build -t $IMAGE_TAG -f $TOOLS_DIR/Containerfile.replay $FED_DIR"
}

# --- 3) Per-node bootstrap script generator ---
# write_bootstrap emits a self-contained bash script into <node-dir>/
# bootstrap.sh that, when executed inside the container, performs:
#   1. agentis init in /run-root (idempotent)
#   2. Append llm config lines to .agentis/config
#   3. Copy the 6 tribe colonies + tools/ from the read-only /repo bind-mount
#      into /run-root
#   4. Spawn one source strategist daemon per tribe (alpha / beta / gamma /
#      delta / epsilon / zeta). Replication grows the population from there per the
#      M2-Malthusian gate inside strategist.ag.
#   5. Block until /run-root/.shutdown is touched by the host orchestrator
#
# Per-tribe env passthrough: VERIFIER_PATH points at the deterministic
# PnL verifier shipped in PR-4 (`tools/verify-trade.sh`), CANDLES_CSV at
# the unified candle stream produced by load-candles.py, and HOLD_PERIOD
# at the per-trade settlement window.
write_bootstrap() {
    bootstrap_path="$LAPTOP_DIR/bootstrap.sh"
    emit_step "generating bootstrap script at $bootstrap_path (tribes=6 daemon_per_tribe=1)"

    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "write-bootstrap path=$bootstrap_path tribes=alpha,beta,gamma,delta,epsilon,zeta symbol=$SYMBOL timeframe=$TIMEFRAME"
        return
    fi

    {
        printf '#!/bin/bash\n'
        printf '# Auto-generated by run-replay.sh — runs inside the container.\n'
        printf 'set -euo pipefail\n'
        printf 'cd /run-root\n'
        printf 'agentis init >/dev/null 2>&1 || true\n'
        printf '{\n'
        printf '  printf "exec.env_passthrough = DAEMON_ID,TRIBE_NAME,REPLAY_SYMBOL,REPLAY_TIMEFRAME,REPLAY_LOOKBACK_WINDOW,REPLAY_HOLD_PERIOD,HOLD_PERIOD,VERIFIER_PATH,CANDLES_CSV,TRADE_LEDGER,AGENTIS_ROOT,STRATEGIST_PROMPT_EVOLUTION_THRESHOLD,STRATEGIST_PROMPT_GEN_CAP,STRATEGIST_PROMPT_MAX_BYTES,STRATEGIST_PROMPT_LEVENSHTEIN_FLOOR,STRATEGIST_FITNESS_REWARD_WIN_PER_BPS,STRATEGIST_FITNESS_PENALTY_LOSS_PER_BPS\\n"\n'
        printf '  printf "experience.enabled = true\\n"\n'
        printf '  printf "telemetry.enabled = true\\n"\n'
        printf '  printf "llm.backend = %s\\n"\n' "$LLM_BACKEND"
        printf '  printf "daemon.cb_per_tick = %s\\n"\n' "$DAEMON_CB_PER_TICK"
        # Watchdog heartbeat must exceed worst-case LLM round-trip time
        # (Qwen3-coder on 21KB candle context: 5-15s observed). Without
        # this bump, the default 10s heartbeat kills children mid-prompt
        # before any decision is written. Mirrors tribes-bench #571.
        printf '  printf "daemon.heartbeat_interval_ms = %s\\n"\n' "$DAEMON_HEARTBEAT_MS"
        # Candle OHLCV strings trip agentis-core's PII heuristic
        # (long numeric runs flagged as phone / credit_card / czech_birth_number).
        # Without this allow, every prompt() returns 'capability denied: pii_transmit'
        # and no decisions are ever produced. Closes #581.
        printf '  printf "pii_transmit = allow\\n"\n'
        # agentis-core default memo cap is 500 keys. Strategist daemons
        # write strategist:<pid>:decision:tick-<N> per-tick — 5 daemons
        # × ~100 ticks fills 500 fast and subsequent memo_write calls
        # fail with 'memo: max 500 keys exceeded'. Settlement path (and
        # M98 v3 prompt-evolution buffer) both depend on memo, so the
        # whole experiment degrades. Mirrors tribes-bench #544 chunk 2.
        printf '  printf "memo.max_keys = 50000\\n"\n'
        if [ "$LLM_BACKEND" = "openai" ]; then
            printf '  printf "llm.openai.endpoint = %s\\n"\n' "$OPENAI_ENDPOINT"
            printf '  printf "llm.openai.model = %s\\n"\n' "$OPENAI_MODEL"
            printf '  printf "llm.openai.api_key_env = %s\\n"\n' "$OPENAI_KEY_ENV"
            printf '  printf "llm.openai.timeout_ms = %s\\n"\n' "$OPENAI_TIMEOUT_MS"
        fi
        printf '} >> .agentis/config\n'
        printf 'for t in alpha beta gamma delta epsilon zeta; do\n'
        printf '    cp -r /repo/trading-binance/tribe-$t /run-root/tribe-$t\n'
        printf 'done\n'
        printf 'cp -r /repo/trading-binance/tools /run-root/tools\n'
        printf 'mkdir -p /run-root/.agentis/sandbox /run-root/.agentis/logs\n'
        # Seed propose-tier confidence for each tribe's strategist daemon.
        printf 'for t in alpha beta gamma delta epsilon zeta; do\n'
        printf '    (cd /run-root && agentis memo set strategist:confidence 0.7 >/dev/null 2>&1 || true)\n'
        printf 'done\n'
        # Spawn one source strategist daemon per tribe. Each tribe's
        # M2-Malthusian replicate path grows the population from there.
        printf 'for t in alpha beta gamma delta epsilon zeta; do\n'
        printf '    DAEMON_ID=1 TRIBE_NAME=tribe-$t REPLAY_SYMBOL=%s REPLAY_TIMEFRAME=%s REPLAY_LOOKBACK_WINDOW=%s REPLAY_HOLD_PERIOD=%s HOLD_PERIOD=%s VERIFIER_PATH=/run-root/tools/verify-trade.sh CANDLES_CSV=/run-root/candles.csv TRADE_LEDGER=/run-root/trade-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=%s STRATEGIST_PROMPT_GEN_CAP=%s STRATEGIST_PROMPT_MAX_BYTES=%s STRATEGIST_PROMPT_LEVENSHTEIN_FLOOR=%s STRATEGIST_FITNESS_REWARD_WIN_PER_BPS=%s STRATEGIST_FITNESS_PENALTY_LOSS_PER_BPS=%s agentis daemon /run-root/tribe-$t/agents/strategist.ag --colony tribe-$t --enable-exec --enable-messaging --enable-replication --allow-replica-replication --tick-interval %s > /run-root/.agentis/logs/strategist-$t.log 2>&1 &\n' \
            "$SYMBOL" "$TIMEFRAME" "$LOOKBACK_WINDOW" "$HOLD_PERIOD" "$HOLD_PERIOD" \
            "$REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD" \
            "$REPLAY_STRATEGIST_PROMPT_GEN_CAP" \
            "$REPLAY_STRATEGIST_PROMPT_MAX_BYTES" \
            "$REPLAY_STRATEGIST_PROMPT_LEVENSHTEIN_FLOOR" \
            "$REPLAY_STRATEGIST_FITNESS_REWARD_WIN_PER_BPS" \
            "$REPLAY_STRATEGIST_FITNESS_PENALTY_LOSS_PER_BPS" \
            "$((INTERVAL_SECONDS * 1000 / SPEED))"
        printf 'done\n'
        printf 'while [ ! -e /run-root/.shutdown ]; do sleep 5; done\n'
        printf 'exit 0\n'
    } >"$bootstrap_path"
    chmod +x "$bootstrap_path"
}

# --- 4) Spawn the container ---
spawn_container() {
    emit_step "spawning replay-laptop container (image=$IMAGE_TAG)"
    emit_cmd "podman run -d --replace --name replay-laptop -e $OPENAI_KEY_ENV=\"\${$OPENAI_KEY_ENV:-}\" -v $REPO_ROOT:/repo:ro -v $LAPTOP_DIR:/run-root:rw $IMAGE_TAG /run-root/bootstrap.sh"
}

# --- 5) Cleanup trap ---
install_cleanup_trap() {
    emit_step "installing cleanup trap (stop + rm container)"
    emit_cmd "trap 'podman stop --time 5 replay-laptop 2>/dev/null || true; podman rm -f replay-laptop 2>/dev/null || true' EXIT INT TERM"
}

# --- 6) Tick stream (main replay loop) ---
# For each tick:
#   1. Slice rows [idx-LOOKBACK_WINDOW .. idx] from candles.csv into
#      <run-dir>/laptop-node/.agentis/sandbox/context-stream/tick-<idx>.csv
#   2. Update memos so the strategist daemon picks up the new context path
#   3. Sleep interval_seconds / SPEED so the daemon has a chance to react
tick_stream() {
    emit_step "starting tick stream (interval=${INTERVAL_SECONDS}s sped to $(( INTERVAL_SECONDS / SPEED ))s)"
    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "python3 -c 'replay-loop placeholder: lookback=$LOOKBACK_WINDOW hold=$HOLD_PERIOD speed=$SPEED' # tick loop runs in real mode"
        return
    fi
    python3 - "$CANDLES_CSV" "$SANDBOX_CTX" "$LOOKBACK_WINDOW" "$HOLD_PERIOD" \
            "$INTERVAL_SECONDS" "$SPEED" "$RUN_DIR" <<'PYREPLAY'
import os
import subprocess
import sys
import time

candles_csv, ctx_dir, lookback, hold, interval, speed, run_dir = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]),
    int(sys.argv[5]), int(sys.argv[6]), sys.argv[7],
)
with open(candles_csv) as f:
    header = f.readline().rstrip("\n")
    rows = [line.rstrip("\n") for line in f if line.strip()]
total = len(rows)
if total <= lookback + hold:
    sys.stderr.write(
        "tick-stream: not enough candles ("
        + str(total) + ") for lookback="
        + str(lookback) + " + hold=" + str(hold) + "\n"
    )
    sys.exit(0)
sleep_s = max(1, interval // max(1, speed))
log_path = os.path.join(run_dir, "orchestrator.log")
for idx in range(lookback, total - hold):
    window = rows[idx - lookback:idx + 1]
    out_path = os.path.join(ctx_dir, "tick-" + str(idx) + ".csv")
    with open(out_path, "w") as out:
        out.write(header + "\n")
        out.write("\n".join(window) + "\n")
    rel = "context-stream/tick-" + str(idx) + ".csv"
    subprocess.run(
        ["podman", "exec", "replay-laptop", "agentis", "memo", "set",
         "replay:current_tick", str(idx)],
        check=False,
    )
    subprocess.run(
        ["podman", "exec", "replay-laptop", "agentis", "memo", "set",
         "replay:context_path", rel],
        check=False,
    )
    with open(log_path, "a") as log:
        log.write("# tick " + str(idx) + "/" + str(total - hold) + " ctx=" + rel + "\n")
    time.sleep(sleep_s)
PYREPLAY
}

# --- 7) Shutdown signal ---
signal_shutdown() {
    emit_step "signalling shutdown (touch /run-root/.shutdown)"
    emit_cmd "podman exec replay-laptop touch /run-root/.shutdown 2>/dev/null || true"
}

# --- 8) run-meta.json ---
write_run_meta() {
    emit_step "writing run-meta.json"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    emit_cmd "python3 -c 'import json; json.dump({\"started_at\":\"$started_at\",\"symbol\":\"$SYMBOL\",\"timeframe\":\"$TIMEFRAME\",\"start\":\"$START\",\"end\":\"$END\",\"speed\":$SPEED,\"daemon_count\":$DAEMON_COUNT,\"lookback_window\":$LOOKBACK_WINDOW,\"hold_period\":$HOLD_PERIOD,\"llm_backend\":\"$LLM_BACKEND\",\"image_tag\":\"$IMAGE_TAG\"}, open(\"$RUN_META\",\"w\"), indent=2)'"
}

# --- 9) Analyser placeholder ---
# analyse-replay.py is the PR-5 deliverable; PR-3 just stubs the call so
# the orchestrator wiring is observable. Failure is non-fatal.
analyse_placeholder() {
    emit_step "analyser placeholder (PR-5 will populate $TELEMETRY_CSV)"
    emit_cmd "ls $LAPTOP_DIR/.agentis/spend 2>/dev/null || true"
}

# --- Orchestration body ---
install_cleanup_trap
load_candles
build_image
write_bootstrap
write_run_meta
spawn_container
tick_stream

if [ "$DRY_RUN" = "1" ]; then
    emit_step "dry-run complete; no container spawned"
    exit 0
fi

signal_shutdown
analyse_placeholder

emit_step "run-replay: done"
echo "[run-replay] run dir: $RUN_DIR"
