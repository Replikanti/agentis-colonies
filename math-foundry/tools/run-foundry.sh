#!/bin/bash
# run-foundry.sh -- compute-first novelty discovery orchestrator for the
# math-foundry federation (#592).
#
# Streams (topic, paper_a, paper_b) tuples tick-by-tick to five agentis
# daemon colonies running inside a single podman container. Mirrors
# trading-binance/tools/run-replay.sh architectural shape (emit_step
# helper, run dir under <federation>/runs/<timestamp>/, sandbox cp
# idiom) but adapts the candle-tick loop into a topic-rotation loop and
# replaces the deterministic PnL verifier with the verifier + novelty
# colony chain described in ADR-0008.
#
# Spawns one source daemon per colony (explorer / noticer / formulator
# / verifier / novelty), each with `--enable-exec --enable-messaging`.
# The explorer colony additionally gets `--enable-replication
# --allow-replica-replication` so the M2-Malthusian replicate gate
# inside explorer.ag can grow the explorer population over time.
#
# Env vars (all optional; defaults shown):
#   FOUNDRY_TOPICS               Comma-separated topic labels rotated
#                                across ticks.
#                                Default: number_theory,combinatorics,abstract_algebra,graph_theory
#   FOUNDRY_PAPER_CORPUS         Path to cached per-topic JSON corpora
#                                (`<topic>.json` under this dir).
#                                Default: math-foundry/data/papers
#   FOUNDRY_TICK_INTERVAL_S      Seconds between foundry ticks. Default 60
#   FOUNDRY_TOTAL_TICKS          Number of ticks to drive. Default 30
#   FOUNDRY_DAEMONS_PER_COLONY   Daemon count per colony. Phase 1 = 1.
#   FOUNDRY_HOLD_PERIOD          Ticks before explorer settles a verdict.
#                                Default 4
#   FOUNDRY_LLM_BACKEND          llm.backend value injected into hermetic
#                                config. Default: openai
#   FOUNDRY_OPENAI_ENDPOINT      Chat-completions URL.
#                                Default: https://openrouter.ai/api/v1/chat/completions
#   FOUNDRY_OPENAI_MODEL         Model id when backend=openai.
#                                Default: qwen/qwen3-coder-30b-a3b-instruct
#   FOUNDRY_OPENAI_KEY_ENV       Env var carrying the LLM API key.
#                                Default: OPENROUTER_API_KEY
#   FOUNDRY_OPENAI_TIMEOUT_MS    Per-request timeout (ms). Default: 180000
#   FOUNDRY_DAEMON_CB_PER_TICK   Per-tick CB replenishment written into
#                                hermetic .agentis/config as
#                                `daemon.cb_per_tick`. Default 2000 --
#                                well above the agentis-core default of
#                                100 which empirically bricks LLM-heavy
#                                daemons after ~1 tick once the
#                                `cb 200000000;` lifetime budget drains.
#                                Mirrors trading-binance fix (#579).
#                                Hermetic memo store also bumped from
#                                agentis-core default 500 to 50000 in
#                                the hermetic config to cover ~30 ticks
#                                across 5 daemons with per-pid keys.
#                                Mirrors trading-binance fix (#587).
#   FOUNDRY_DAEMON_HEARTBEAT_MS  Watchdog heartbeat threshold (ms).
#                                Default 1800000 (30min). agentis-core
#                                default is 10000ms which kills daemons
#                                mid-prompt when LLM round-trip exceeds
#                                10s. Mirrors trading-binance fix (#583).
#   FOUNDRY_DRY_RUN              1 = emit_step the plan, skip podman.
#                                Default: "" (real run).
#   FOUNDRY_RUN_DIR              Output dir override. Default: auto-
#                                timestamped under math-foundry/runs/
#   FOUNDRY_IMAGE_TAG            Container image tag built from
#                                Containerfile.foundry.
#                                Default: math-foundry:latest
#   FOUNDRY_FITNESS_REWARD_NOVEL_PER_TICK
#                                Per-tick fitness reward when novelty
#                                referee returns NOVEL. Default: 2
#   FOUNDRY_FITNESS_PENALTY_NOT_NOVEL_PER_TICK
#                                Per-tick fitness penalty when novelty
#                                referee returns NOT_NOVEL. Default: 1
#   FOUNDRY_EXPLORER_PROMPT_EVOLUTION_THRESHOLD
#                                NOT_NOVEL streak required before
#                                explorer.ag rewrites its prompt body
#                                (M98 v3). Set to a large number (e.g.
#                                999) to disable prompt evolution.
#                                Default: 3
#   FOUNDRY_EXPLORER_PROMPT_GEN_CAP
#                                Per-lineage generation cap before reset.
#                                Default: 10
#   FOUNDRY_EXPLORER_PROMPT_MAX_BYTES
#                                Hard byte cap on rewritten prompt bodies.
#                                Default: 8192
#   FOUNDRY_EXPLORER_PROMPT_LEVENSHTEIN_FLOOR
#                                Minimum dissimilarity percent for a
#                                rewrite to be accepted (else no-op).
#                                Default: 20
#
# Flags:
#   --dry-run    Same as FOUNDRY_DRY_RUN=1.
#
# Output layout (under math-foundry/runs/<YYYYMMDDTHHMMSSZ>/):
#   orchestrator.log              orchestrator's own log
#   run-meta.json                 config dump (topics, ticks, knobs)
#   discovery-ledger.jsonl        per-tick (exploration_done /
#                                 problem_ready / novelty_verdict) rows
#   laptop-node/
#     bootstrap.sh                container bootstrap (real run only)
#     .agentis/
#       sandbox/                  per-daemon scratch (explorer Python)
#       logs/
#       spend/
#
# Exit codes:
#   0   foundry run completed (or dry-run plan emitted)
#   1   prerequisite missing (podman, python3 outside dry-run)
#   2   invalid env (e.g. empty topic list)
#   3   paper corpus loading failed
#   4   container spawn failed

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

# --- Argument parsing ---
DRY_RUN="${FOUNDRY_DRY_RUN:-0}"
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
            echo "run-foundry: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# --- Env-var defaults ---
TOPICS_RAW="${FOUNDRY_TOPICS-number_theory,combinatorics,abstract_algebra,graph_theory}"
PAPER_CORPUS_RAW="${FOUNDRY_PAPER_CORPUS:-$FED_DIR/data/papers}"
TICK_INTERVAL_S="${FOUNDRY_TICK_INTERVAL_S:-60}"
TOTAL_TICKS="${FOUNDRY_TOTAL_TICKS:-30}"
DAEMONS_PER_COLONY="${FOUNDRY_DAEMONS_PER_COLONY:-1}"
HOLD_PERIOD="${FOUNDRY_HOLD_PERIOD:-4}"
LLM_BACKEND="${FOUNDRY_LLM_BACKEND:-openai}"
OPENAI_ENDPOINT="${FOUNDRY_OPENAI_ENDPOINT:-https://openrouter.ai/api/v1/chat/completions}"
OPENAI_MODEL="${FOUNDRY_OPENAI_MODEL:-qwen/qwen3-coder-30b-a3b-instruct}"
OPENAI_KEY_ENV="${FOUNDRY_OPENAI_KEY_ENV:-OPENROUTER_API_KEY}"
OPENAI_TIMEOUT_MS="${FOUNDRY_OPENAI_TIMEOUT_MS:-180000}"
DAEMON_CB_PER_TICK="${FOUNDRY_DAEMON_CB_PER_TICK:-2000}"
DAEMON_HEARTBEAT_MS="${FOUNDRY_DAEMON_HEARTBEAT_MS:-1800000}"
IMAGE_TAG="${FOUNDRY_IMAGE_TAG:-math-foundry:latest}"

# Explorer M98 v3 prompt-evolution + fitness knobs.
: "${FOUNDRY_EXPLORER_PROMPT_EVOLUTION_THRESHOLD:=3}"
: "${FOUNDRY_EXPLORER_PROMPT_GEN_CAP:=10}"
: "${FOUNDRY_EXPLORER_PROMPT_MAX_BYTES:=8192}"
: "${FOUNDRY_EXPLORER_PROMPT_LEVENSHTEIN_FLOOR:=20}"
: "${FOUNDRY_FITNESS_REWARD_NOVEL_PER_TICK:=2}"
: "${FOUNDRY_FITNESS_PENALTY_NOT_NOVEL_PER_TICK:=1}"

# --- Validation ---
if [ -z "$TOPICS_RAW" ]; then
    echo "run-foundry: FOUNDRY_TOPICS must be a non-empty comma-separated list" >&2
    exit 2
fi

val=""
for var_name in TICK_INTERVAL_S TOTAL_TICKS DAEMONS_PER_COLONY HOLD_PERIOD OPENAI_TIMEOUT_MS; do
    eval "val=\${$var_name}"
    case "$val" in
        ''|*[!0-9]*)
            echo "run-foundry: $var_name must be a positive integer (got: $val)" >&2
            exit 2
            ;;
    esac
done
unset val

if [ "$TICK_INTERVAL_S" -lt 1 ]; then
    echo "run-foundry: FOUNDRY_TICK_INTERVAL_S must be >= 1 (got: $TICK_INTERVAL_S)" >&2
    exit 2
fi
if [ "$TOTAL_TICKS" -lt 1 ]; then
    echo "run-foundry: FOUNDRY_TOTAL_TICKS must be >= 1 (got: $TOTAL_TICKS)" >&2
    exit 2
fi
if [ "$DAEMONS_PER_COLONY" -lt 1 ]; then
    echo "run-foundry: FOUNDRY_DAEMONS_PER_COLONY must be >= 1 (got: $DAEMONS_PER_COLONY)" >&2
    exit 2
fi

# Resolve PAPER_CORPUS to absolute path when present so we can pass it
# into containers / helpers safely regardless of where the orchestrator
# is launched from.
if [ -d "$PAPER_CORPUS_RAW" ]; then
    PAPER_CORPUS="$(cd "$PAPER_CORPUS_RAW" && pwd)"
else
    PAPER_CORPUS="$PAPER_CORPUS_RAW"
fi

# --- Per-run hermetic dir ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${FOUNDRY_RUN_DIR:-$FED_DIR/runs/$TS}"
ORCH_LOG="$RUN_DIR/orchestrator.log"
RUN_META="$RUN_DIR/run-meta.json"
LAPTOP_DIR="$RUN_DIR/laptop-node"
DISCOVERY_LEDGER="$RUN_DIR/discovery-ledger.jsonl"

# --- Dry-run / real-run dispatch helpers ---
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
            echo "run-foundry: $bin not found on PATH" >&2
            exit 1
        fi
    done
    if [ "$LLM_BACKEND" = "openai" ]; then
        eval "openai_key_value=\${$OPENAI_KEY_ENV:-}"
        if [ -z "${openai_key_value:-}" ]; then
            echo "run-foundry: \$$OPENAI_KEY_ENV is empty (required for llm.backend=openai)" >&2
            exit 1
        fi
        unset openai_key_value
    fi
    mkdir -p "$RUN_DIR" "$LAPTOP_DIR" "$LAPTOP_DIR/.agentis/sandbox" "$LAPTOP_DIR/.agentis/logs" "$LAPTOP_DIR/.agentis/spend"
    : >"$ORCH_LOG"
    : >"$DISCOVERY_LEDGER"
fi

emit_step "run-foundry: starting (dry_run=$DRY_RUN)"
emit_step "run dir: $RUN_DIR"
emit_step "topics: $TOPICS_RAW"
emit_step "paper corpus: $PAPER_CORPUS"
emit_step "tick interval: ${TICK_INTERVAL_S}s"
emit_step "total ticks: $TOTAL_TICKS"
emit_step "daemons per colony: $DAEMONS_PER_COLONY"
emit_step "hold period: $HOLD_PERIOD"
emit_step "llm backend: $LLM_BACKEND"
emit_step "image tag: $IMAGE_TAG"

# --- 1) Build (or reuse) the container image ---
build_image() {
    emit_step "checking for existing image $IMAGE_TAG (build if missing)"
    emit_cmd "podman image exists $IMAGE_TAG || podman build -t $IMAGE_TAG -f $TOOLS_DIR/Containerfile.foundry $FED_DIR"
}

# --- 2) Per-node bootstrap script generator ---
# write_bootstrap emits a self-contained bash script into <node-dir>/
# bootstrap.sh that, when executed inside the container, performs:
#   1. agentis init in /run-root (idempotent)
#   2. Append llm / daemon / memo config lines to .agentis/config
#   3. Copy the 5 colonies + tools/ from the read-only /repo bind-mount
#      into /run-root
#   4. Spawn one source daemon per colony with the appropriate flag set.
#   5. Block until /run-root/.shutdown is touched by the host orchestrator.
write_bootstrap() {
    bootstrap_path="$LAPTOP_DIR/bootstrap.sh"
    emit_step "generating bootstrap script at $bootstrap_path (colonies=5 daemons_per_colony=$DAEMONS_PER_COLONY)"

    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "write-bootstrap path=$bootstrap_path colonies=explorer,noticer,formulator,verifier,novelty"
        return
    fi

    {
        printf '#!/bin/bash\n'
        printf '# Auto-generated by run-foundry.sh -- runs inside the container.\n'
        printf 'set -euo pipefail\n'
        printf 'cd /run-root\n'
        printf 'agentis init >/dev/null 2>&1 || true\n'
        printf '{\n'
        printf '  printf "exec.env_passthrough = DAEMON_ID,COLONY_NAME,HOLD_PERIOD,DISCOVERY_LEDGER,AGENTIS_ROOT,EXPLORER_PROMPT_EVOLUTION_THRESHOLD,EXPLORER_PROMPT_GEN_CAP,EXPLORER_PROMPT_MAX_BYTES,EXPLORER_PROMPT_LEVENSHTEIN_FLOOR,FOUNDRY_FITNESS_REWARD_NOVEL_PER_TICK,FOUNDRY_FITNESS_PENALTY_NOT_NOVEL_PER_TICK\\n"\n'
        printf '  printf "experience.enabled = true\\n"\n'
        printf '  printf "telemetry.enabled = true\\n"\n'
        printf '  printf "llm.backend = %s\\n"\n' "$LLM_BACKEND"
        # Per-tick CB replenishment well above the agentis-core default
        # of 100 which empirically bricks LLM-heavy daemons after one
        # tick once the cb 200000000; lifetime budget drains. Mirrors
        # trading-binance fix (#579).
        printf '  printf "daemon.cb_per_tick = %s\\n"\n' "$DAEMON_CB_PER_TICK"
        # Watchdog heartbeat must exceed worst-case LLM round-trip time
        # (Qwen3-coder on the foundry context: 5-15s observed). Without
        # this bump, the default 10s heartbeat kills children mid-prompt
        # before any verdict is written. Mirrors trading-binance fix
        # (#583).
        printf '  printf "daemon.heartbeat_interval_ms = %s\\n"\n' "$DAEMON_HEARTBEAT_MS"
        # Long arxiv abstracts trip agentis-core's PII heuristic
        # (numeric runs flagged as phone / credit_card / czech_birth_number).
        # Without this allow, every prompt() returns 'capability denied:
        # pii_transmit' and no decisions are produced. Mirrors trading-
        # binance fix (#581).
        printf '  printf "pii_transmit = allow\\n"\n'
        # agentis-core default memo cap is 500 keys. Five colonies × 30
        # ticks × multiple per-pid keys per tick fill 500 fast and
        # subsequent memo_write calls fail with 'memo: max 500 keys
        # exceeded'. Settlement path (and M98 v3 prompt-evolution
        # buffer) both depend on memo, so the whole experiment degrades.
        # Mirrors trading-binance fix (#587).
        printf '  printf "memo.max_keys = 50000\\n"\n'
        if [ "$LLM_BACKEND" = "openai" ]; then
            printf '  printf "llm.openai.endpoint = %s\\n"\n' "$OPENAI_ENDPOINT"
            printf '  printf "llm.openai.model = %s\\n"\n' "$OPENAI_MODEL"
            printf '  printf "llm.openai.api_key_env = %s\\n"\n' "$OPENAI_KEY_ENV"
            printf '  printf "llm.openai.timeout_ms = %s\\n"\n' "$OPENAI_TIMEOUT_MS"
        fi
        printf '} >> .agentis/config\n'
        printf 'for c in explorer noticer formulator verifier novelty; do\n'
        printf '    cp -r /repo/math-foundry/$c /run-root/$c\n'
        printf 'done\n'
        printf 'cp -r /repo/math-foundry/tools /run-root/tools\n'
        printf 'mkdir -p /run-root/.agentis/sandbox /run-root/.agentis/logs\n'
        printf ': > /run-root/discovery-ledger.jsonl\n'
        # Seed propose-tier confidence for each colony.
        printf 'for c in explorer noticer formulator verifier novelty; do\n'
        printf '    (cd /run-root && agentis memo set $c:confidence 0.7 >/dev/null 2>&1 || true)\n'
        printf 'done\n'
        # Spawn one explorer daemon (with replication) per
        # DAEMONS_PER_COLONY count.
        printf 'EXPLORER_TICK_INTERVAL_MS=%s\n' "$((TICK_INTERVAL_S * 1000))"
        printf 'for i in $(seq 1 %s); do\n' "$DAEMONS_PER_COLONY"
        printf '    DAEMON_ID=$i COLONY_NAME=explorer HOLD_PERIOD=%s DISCOVERY_LEDGER=/run-root/discovery-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis EXPLORER_PROMPT_EVOLUTION_THRESHOLD=%s EXPLORER_PROMPT_GEN_CAP=%s EXPLORER_PROMPT_MAX_BYTES=%s EXPLORER_PROMPT_LEVENSHTEIN_FLOOR=%s FOUNDRY_FITNESS_REWARD_NOVEL_PER_TICK=%s FOUNDRY_FITNESS_PENALTY_NOT_NOVEL_PER_TICK=%s agentis daemon /run-root/explorer/agents/explorer.ag --colony explorer --enable-exec --enable-messaging --enable-replication --allow-replica-replication --tick-interval "$EXPLORER_TICK_INTERVAL_MS" > /run-root/.agentis/logs/explorer-$i.log 2>&1 &\n' \
            "$HOLD_PERIOD" \
            "$FOUNDRY_EXPLORER_PROMPT_EVOLUTION_THRESHOLD" \
            "$FOUNDRY_EXPLORER_PROMPT_GEN_CAP" \
            "$FOUNDRY_EXPLORER_PROMPT_MAX_BYTES" \
            "$FOUNDRY_EXPLORER_PROMPT_LEVENSHTEIN_FLOOR" \
            "$FOUNDRY_FITNESS_REWARD_NOVEL_PER_TICK" \
            "$FOUNDRY_FITNESS_PENALTY_NOT_NOVEL_PER_TICK"
        printf 'done\n'
        # Spawn one noticer / formulator / verifier / novelty daemon per
        # colony per DAEMONS_PER_COLONY count.
        printf 'for c in noticer formulator verifier novelty; do\n'
        printf '    for i in $(seq 1 %s); do\n' "$DAEMONS_PER_COLONY"
        printf '        DAEMON_ID=$i COLONY_NAME=$c DISCOVERY_LEDGER=/run-root/discovery-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/$c/agents/$c.ag --colony $c --enable-exec --enable-messaging --tick-interval %s > /run-root/.agentis/logs/$c-$i.log 2>&1 &\n' "$((TICK_INTERVAL_S * 1000))"
        printf '    done\n'
        printf 'done\n'
        printf 'while [ ! -e /run-root/.shutdown ]; do sleep 5; done\n'
        printf 'exit 0\n'
    } >"$bootstrap_path"
    chmod +x "$bootstrap_path"
}

# --- 3) Spawn the container ---
spawn_container() {
    emit_step "spawning math-foundry container (image=$IMAGE_TAG)"
    emit_cmd "podman run -d --replace --name math-foundry-laptop -e $OPENAI_KEY_ENV=\"\${$OPENAI_KEY_ENV:-}\" -v $REPO_ROOT:/repo:ro -v $LAPTOP_DIR:/run-root:rw $IMAGE_TAG /run-root/bootstrap.sh"
}

# --- 4) Cleanup trap ---
install_cleanup_trap() {
    emit_step "installing cleanup trap (stop + rm container)"
    emit_cmd "trap 'podman stop --time 5 math-foundry-laptop 2>/dev/null || true; podman rm -f math-foundry-laptop 2>/dev/null || true' EXIT INT TERM"
}

# --- 5) Tick stream (main foundry loop) ---
# For each tick:
#   1. Pick the next topic (round-robin over FOUNDRY_TOPICS).
#   2. Sample two distinct papers from the topic's cached corpus.
#   3. Update memos so the explorer daemon picks up the new context.
#   4. Sleep FOUNDRY_TICK_INTERVAL_S seconds so the daemon has time to
#      react.
tick_stream() {
    emit_step "starting tick stream (interval=${TICK_INTERVAL_S}s total=${TOTAL_TICKS})"
    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "python3 -c 'foundry-loop placeholder: topics=$TOPICS_RAW total_ticks=$TOTAL_TICKS interval=$TICK_INTERVAL_S' # tick loop runs in real mode"
        return
    fi
    python3 - "$TOPICS_RAW" "$PAPER_CORPUS" "$TOTAL_TICKS" "$TICK_INTERVAL_S" "$RUN_DIR" <<'PYFOUNDRY'
import json
import os
import random
import subprocess
import sys
import time

topics_raw, paper_corpus, total_ticks, interval, run_dir = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]),
    int(sys.argv[4]), sys.argv[5],
)
topics = [t.strip() for t in topics_raw.split(",") if t.strip()]
if not topics:
    sys.stderr.write("foundry-loop: no topics\n")
    sys.exit(2)

# Load per-topic paper corpora. The corpus is a JSON file per topic
# under FOUNDRY_PAPER_CORPUS; each file contains {"papers": [{"id":...,
# "title":..., "abstract":...}, ...], "description": "...",
# "compute_hints": "..."}.
corpora = {}
for topic in topics:
    path = os.path.join(paper_corpus, topic + ".json")
    if not os.path.isfile(path):
        sys.stderr.write(
            "foundry-loop: missing corpus for topic '" + topic + "' at " + path + "\n"
        )
        sys.exit(3)
    with open(path) as f:
        try:
            data = json.load(f)
        except Exception as e:
            sys.stderr.write("foundry-loop: " + path + " not valid JSON: " + str(e) + "\n")
            sys.exit(3)
    papers = data.get("papers") or []
    if len(papers) < 2:
        sys.stderr.write(
            "foundry-loop: corpus '" + topic + "' needs at least 2 papers (has "
            + str(len(papers)) + ")\n"
        )
        sys.exit(3)
    corpora[topic] = data

log_path = os.path.join(run_dir, "orchestrator.log")
rng = random.Random(0xF0FF)
for idx in range(total_ticks):
    topic = topics[idx % len(topics)]
    data = corpora[topic]
    papers = data["papers"]
    a, b = rng.sample(papers, 2)
    memo_pairs = [
        ("replay:current_tick", str(idx)),
        ("replay:current_topic", topic),
        ("replay:current_topic_desc", data.get("description", "")),
        ("replay:current_compute_hints", data.get("compute_hints", "sympy, numpy, networkx")),
        ("replay:current_paper_a_id", str(a.get("id", ""))),
        ("replay:current_paper_a_title", str(a.get("title", ""))),
        ("replay:current_paper_a_abstract", str(a.get("abstract", ""))),
        ("replay:current_paper_b_id", str(b.get("id", ""))),
        ("replay:current_paper_b_title", str(b.get("title", ""))),
        ("replay:current_paper_b_abstract", str(b.get("abstract", ""))),
    ]
    for key, value in memo_pairs:
        subprocess.run(
            ["podman", "exec", "math-foundry-laptop", "agentis", "memo", "set", key, value],
            check=False,
        )
    with open(log_path, "a") as log:
        log.write(
            "# tick " + str(idx) + "/" + str(total_ticks)
            + " topic=" + topic + " papers=" + str(a.get("id"))
            + "," + str(b.get("id")) + "\n"
        )
    time.sleep(interval)
PYFOUNDRY
}

# --- 6) Shutdown signal ---
signal_shutdown() {
    emit_step "signalling shutdown (touch /run-root/.shutdown)"
    emit_cmd "podman exec math-foundry-laptop touch /run-root/.shutdown 2>/dev/null || true"
}

# --- 7) run-meta.json ---
write_run_meta() {
    emit_step "writing run-meta.json"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    emit_cmd "python3 -c 'import json; json.dump({\"started_at\":\"$started_at\",\"topics\":\"$TOPICS_RAW\",\"total_ticks\":$TOTAL_TICKS,\"tick_interval_s\":$TICK_INTERVAL_S,\"daemons_per_colony\":$DAEMONS_PER_COLONY,\"hold_period\":$HOLD_PERIOD,\"llm_backend\":\"$LLM_BACKEND\",\"image_tag\":\"$IMAGE_TAG\"}, open(\"$RUN_META\",\"w\"), indent=2)'"
}

# --- Orchestration body ---
install_cleanup_trap
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

emit_step "run-foundry: done"
echo "[run-foundry] run dir: $RUN_DIR"
