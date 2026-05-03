#!/bin/bash
# run-stage2.sh — One-shot Stage 2 harness (#392 M1).
#
# Stage 2 M1 is pure infrastructure: 5 tribes (alpha + beta + gamma +
# delta + epsilon) scanning the vendored real-world `smallvec v0.6.13`
# target under `targets/stage2/smallvec-v0.6.13/`, verified by the
# distinct `tools/verify-finding-stage2.sh` (Stage 0/1 verifier
# unchanged for back-compat). Calibration parameters are unchanged from
# Stage 1; the federation-wide CB pool delta is zero (each tribe gets
# its own `initial_cb`).
#
# Mirrors run-stage1.sh: reads economy parameters from
# tribes-bench/calibration.toml, exports them into the federation
# environment so each tribe's start-colony.sh can seed the
# corresponding per-tribe memos, captures a periodic snapshot every
# 600s into runs/<ts>/snapshots/<elapsed>.txt, and finally drives
# tools/analyse-stage2.py at the end.
#
# Env vars:
#   STAGE2_WALL_CLOCK_S    Wall-clock cap in seconds (default: 172800
#                          = 48h, M3 #394). Lower values still work for
#                          smoke tests; the M3 reproduction recipe
#                          assumes the 48h default.
#   STAGE2_LLM_BACKEND     Override [llm].backend in colony.toml
#                          (default: leave config alone, which means cli)
#   STAGE2_SNAPSHOT_S      Snapshot interval in seconds (default: 3600
#                          = 1h, M3 #394).
#   STAGE2_CRASH_AT_S      M3 #394: when set to a positive integer N,
#                          run-stage2.sh calls kill-federation.sh after
#                          elapsed >= N and exits 99. Used by the M3
#                          crash-recovery drill.
#   STAGE2_RESUME_RUN_DIR  M3 #394: when set to a runs/<ts> path, skip
#                          mkdir + agentis init + memo seeding; reuse the
#                          existing .agentis/, bug-ledger.jsonl, and
#                          knowledge-market.csv. Snapshot numbering
#                          continues from max(existing). A fresh
#                          run-meta-resume-<n>.json is written.
#
# Exit codes:
#   0   run completed and telemetry.csv produced
#   1   prerequisite missing (agentis CLI, jq, python3)
#   2   start-federation.sh failed to launch
#   3   analyse-stage2.py failed
#   99  STAGE2_CRASH_AT_S simulated crash (M3 #394 drill)

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

WALL_CLOCK="${STAGE2_WALL_CLOCK_S:-172800}"
case "$WALL_CLOCK" in
    ''|*[!0-9]*)
        echo "run-stage2: STAGE2_WALL_CLOCK_S must be a positive integer (got: $WALL_CLOCK)" >&2
        exit 1
        ;;
esac

SNAPSHOT_INTERVAL="${STAGE2_SNAPSHOT_S:-3600}"
case "$SNAPSHOT_INTERVAL" in
    ''|*[!0-9]*)
        echo "run-stage2: STAGE2_SNAPSHOT_S must be a positive integer (got: $SNAPSHOT_INTERVAL)" >&2
        exit 1
        ;;
esac

CRASH_AT="${STAGE2_CRASH_AT_S:-}"
if [ -n "$CRASH_AT" ]; then
    case "$CRASH_AT" in
        ''|*[!0-9]*)
            echo "run-stage2: STAGE2_CRASH_AT_S must be a positive integer (got: $CRASH_AT)" >&2
            exit 1
            ;;
    esac
fi

RESUME_RUN_DIR="${STAGE2_RESUME_RUN_DIR:-}"
if [ -n "$RESUME_RUN_DIR" ] && [ ! -d "$RESUME_RUN_DIR" ]; then
    echo "run-stage2: STAGE2_RESUME_RUN_DIR not a directory: $RESUME_RUN_DIR" >&2
    exit 1
fi

# --- Prerequisite checks ---
for bin in agentis jq python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "run-stage2: $bin not found on PATH" >&2
        exit 1
    fi
done

# --- Calibration: parse calibration.toml and export to env ---
# We delegate calibration parsing to a small python helper to dodge the
# macOS bash 3.2 heredoc parser bug (CLAUDE.md "no heredocs in tools/*.sh"
# invariant). The helper uses pure stdlib tomllib (Python 3.11+) and
# falls back gracefully to documented defaults when keys are missing.
CALIBRATION="$FED_DIR/calibration.toml"
if [ ! -f "$CALIBRATION" ]; then
    echo "run-stage2: calibration.toml not found at $CALIBRATION" >&2
    exit 1
fi

INITIAL_CB="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.economy initial_cb 1000)"
BASE_COST="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.economy base_replication_cost 100)"
K_MALTHUSIAN="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.economy k_malthusian 3)"
MAX_REPLICAS="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.economy max_replicas_per_tribe 5)"
REWARD_FULL="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.reward full 200)"
REWARD_SUBSEQUENT="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.reward subsequent 50)"
DEATH_THRESHOLD="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.death threshold 100)"

export INITIAL_CB BASE_COST K_MALTHUSIAN MAX_REPLICAS REWARD_FULL REWARD_SUBSEQUENT DEATH_THRESHOLD

# --- Per-run hermetic directory (or resume an existing one) ---
if [ -n "$RESUME_RUN_DIR" ]; then
    RUN_DIR="$RESUME_RUN_DIR"
    RESUMING=1
    mkdir -p "$RUN_DIR/snapshots"
    echo "[run-stage2] resuming run dir: $RUN_DIR"
else
    TS="$(date -u +%Y%m%dT%H%M%SZ)"
    RUN_DIR="$FED_DIR/runs/$TS"
    RESUMING=0
    mkdir -p "$RUN_DIR" "$RUN_DIR/snapshots"
    echo "[run-stage2] run dir: $RUN_DIR"
fi

echo "[run-stage2] wall-clock cap: ${WALL_CLOCK}s"
echo "[run-stage2] snapshot interval: ${SNAPSHOT_INTERVAL}s"
echo "[run-stage2] calibration: initial_cb=$INITIAL_CB base_cost=$BASE_COST k=$K_MALTHUSIAN reward_full=$REWARD_FULL reward_subsequent=$REWARD_SUBSEQUENT death=$DEATH_THRESHOLD"
if [ -n "$CRASH_AT" ]; then
    echo "[run-stage2] STAGE2_CRASH_AT_S=${CRASH_AT}s (M3 crash-recovery drill)"
fi

# On resume, defensively kill any stale daemons under fed-dir and remove
# orphan *.colony files older than the highest-elapsed snapshot ts so a
# crashed daemon's leftover record doesn't masquerade as alive.
if [ "$RESUMING" = "1" ]; then
    KILL_SCRIPT_PRE="$REPO_ROOT/tools/kill-federation.sh"
    if [ -x "$KILL_SCRIPT_PRE" ]; then
        bash "$KILL_SCRIPT_PRE" --fed-dir "$FED_DIR" --no-backup \
            >>"$RUN_DIR/kill-federation.log" 2>&1 || true
    fi
    if [ -d "$RUN_DIR/.agentis/daemon" ]; then
        python3 "$TOOLS_DIR/run-stage2-prune.py" "$RUN_DIR" || true
    fi
fi

# Initialise a fresh .agentis/ inside the run dir so daemons walking up
# from cwd find this root rather than the operator's persistent store.
# Resume path skips this — the existing .agentis/ is reused as-is.
if [ "$RESUMING" = "0" ]; then
    (
        cd "$RUN_DIR"
        if [ ! -d .agentis ]; then
            agentis init >/dev/null 2>&1
        fi
    )
fi

AGENTIS_ROOT="$RUN_DIR/.agentis"
export AGENTIS_ROOT

# Configure the hermetic .agentis/config so analyse-stage2.py can find
# the inputs it expects:
#   exec.env_passthrough — the Stage 0 trio (TARGET_DIR, BUGS_MANIFEST,
#       VERIFIER_PATH) plus Stage 1 calibration vars + RUN_DIR +
#       BUG_LEDGER_PATH.
#   experience.enabled — required so learn() rows land in
#       .agentis/experience/<agent-id>.jsonl.
#   telemetry.enabled — required so daemon.started / daemon.stopped /
#       agent.completed events land in .agentis/lifecycle/events.jsonl.
# Resume path skips this — config is already correct.
CONFIG_FILE="$RUN_DIR/.agentis/config"
if [ "$RESUMING" = "0" ] && [ -f "$CONFIG_FILE" ]; then
    if ! grep -q '^exec\.env_passthrough' "$CONFIG_FILE"; then
        printf '\nexec.env_passthrough = COLONY_DIR,TRIBE_NAME,TARGET_DIR,TARGET_FILE,BUGS_MANIFEST,VERIFIER_PATH,RUN_DIR,BUG_LEDGER_PATH,INITIAL_CB,BASE_COST,K_MALTHUSIAN,MAX_REPLICAS,REWARD_FULL,REWARD_SUBSEQUENT,DEATH_THRESHOLD,AGENTIS_ROOT\n' >> "$CONFIG_FILE"
    fi
    if ! grep -q '^experience\.enabled' "$CONFIG_FILE"; then
        printf 'experience.enabled = true\n' >> "$CONFIG_FILE"
    fi
    if ! grep -q '^telemetry\.enabled' "$CONFIG_FILE"; then
        printf 'telemetry.enabled = true\n' >> "$CONFIG_FILE"
    fi
fi

# Seed all five tribes' confidence memo to 0.7 (mid-`propose`) inside
# the hermetic root. Resume path skips the seed: the existing memo
# carries the post-crash state that the test wants to verify survives.
if [ "$RESUMING" = "0" ]; then
    (
        cd "$RUN_DIR"
        agentis memo set hunter:confidence 0.7 >/dev/null 2>&1 || true
    )
fi

# --- Make sure each tribe has a colony.toml (install.sh idempotent) ---
for tribe in tribe-alpha tribe-beta tribe-gamma tribe-delta tribe-epsilon; do
    example="$FED_DIR/$tribe/config/colony.example.toml"
    target="$FED_DIR/$tribe/config/colony.toml"
    if [ ! -f "$target" ] && [ -f "$example" ]; then
        cp "$example" "$target"
    fi
done

# --- Export Stage 2 env consumed by hunter.ag via exec sh ---
export TARGET_DIR="$FED_DIR/targets/stage2/smallvec-v0.6.13"
export TARGET_FILE="lib.rs"
export BUGS_MANIFEST="$FED_DIR/targets/stage2/bugs.json"
export VERIFIER_PATH="$FED_DIR/tools/verify-finding-stage2.sh"
export RUN_DIR
export BUG_LEDGER_PATH="$RUN_DIR/bug-ledger.jsonl"

# Touch the bug-ledger so JSONL append never races mkdir. Resume path
# preserves the existing ledger (the recovery-drill assertion checks
# that the ledger survives crash + relaunch).
if [ "$RESUMING" = "0" ]; then
    : > "$BUG_LEDGER_PATH"
fi

if [ ! -f "$TARGET_DIR/$TARGET_FILE" ]; then
    echo "run-stage2: target source not found at $TARGET_DIR/$TARGET_FILE" >&2
    exit 1
fi
if [ ! -f "$BUGS_MANIFEST" ]; then
    echo "run-stage2: bugs manifest not found at $BUGS_MANIFEST" >&2
    exit 1
fi
if [ ! -x "$VERIFIER_PATH" ]; then
    echo "run-stage2: verifier not executable at $VERIFIER_PATH" >&2
    exit 1
fi

# --- Capture run metadata (M3 #394). On resume, write a sidecar instead
# of clobbering the original. ---
RUN_LLM_BACKEND="${STAGE2_LLM_BACKEND:-cli}"
STARTED_AT_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$RESUMING" = "0" ]; then
    agentis --version > "$RUN_DIR/agentis-version.txt" 2>&1 || true
    printf '%s\n' "$RUN_LLM_BACKEND" > "$RUN_DIR/llm-backend.txt"
    python3 "$TOOLS_DIR/run-baseline-meta.py" \
        "$RUN_DIR/run-meta.json" \
        "$STARTED_AT_NOW" \
        "$WALL_CLOCK" \
        "$SNAPSHOT_INTERVAL" \
        "$RUN_LLM_BACKEND" \
        "$INITIAL_CB" \
        "ecosystem"
else
    # Find the next available resume slot N.
    n=1
    while [ -f "$RUN_DIR/run-meta-resume-${n}.json" ]; do
        n=$((n + 1))
    done
    python3 "$TOOLS_DIR/run-baseline-meta.py" \
        "$RUN_DIR/run-meta-resume-${n}.json" \
        "$STARTED_AT_NOW" \
        "$WALL_CLOCK" \
        "$SNAPSHOT_INTERVAL" \
        "$RUN_LLM_BACKEND" \
        "$INITIAL_CB" \
        "ecosystem-resume-${n}"
fi

# --- Launch federation in the background, anchored at RUN_DIR ---
echo "[run-stage2] launching tribes..."
(
    cd "$RUN_DIR"
    "$FED_DIR/start-federation.sh" "$FED_DIR" >>"$RUN_DIR/start-federation.log" 2>&1
) &
FED_PID=$!

# Give start-federation.sh a moment to spawn child daemons.
sleep 5

if ! kill -0 "$FED_PID" 2>/dev/null; then
    echo "run-stage2: start-federation.sh exited early; see $RUN_DIR/start-federation.log" >&2
    exit 2
fi

# --- Sleep the wall-clock cap with periodic snapshots ---
# On resume, continue snapshot numbering from max(elapsed) of existing
# snapshot files in <run>/snapshots/ (numeric stem) so the recovery-drill
# can assert old snapshots survive AND new snapshots are appended.
elapsed=0
if [ "$RESUMING" = "1" ]; then
    elapsed="$(python3 "$TOOLS_DIR/run-stage2-snapshot-max.py" "$RUN_DIR/snapshots" 2>/dev/null || echo 0)"
    case "$elapsed" in
        ''|*[!0-9]*) elapsed=0 ;;
    esac
fi

echo "[run-stage2] sleeping ${WALL_CLOCK}s with snapshots every ${SNAPSHOT_INTERVAL}s (start elapsed=${elapsed})..."
while [ "$elapsed" -lt "$WALL_CLOCK" ]; do
    remaining=$((WALL_CLOCK - elapsed))
    if [ "$remaining" -gt "$SNAPSHOT_INTERVAL" ]; then
        sleep "$SNAPSHOT_INTERVAL"
        elapsed=$((elapsed + SNAPSHOT_INTERVAL))
    else
        sleep "$remaining"
        elapsed="$WALL_CLOCK"
    fi
    snap_path="$RUN_DIR/snapshots/${elapsed}.txt"
    bash "$TOOLS_DIR/snapshot-stanza.sh" "$RUN_DIR" "$elapsed" > "$snap_path" 2>/dev/null || true
    echo "[run-stage2] snapshot $snap_path"

    # M3 #394 crash-recovery drill: when STAGE2_CRASH_AT_S is set and
    # elapsed has reached it, kill the federation hard and exit 99 so
    # the operator drill can verify the ledger + .agentis/ survives and
    # a STAGE2_RESUME_RUN_DIR=<run> rerun continues from the same dir.
    if [ -n "$CRASH_AT" ] && [ "$elapsed" -ge "$CRASH_AT" ]; then
        echo "[run-stage2] STAGE2_CRASH_AT_S triggered at elapsed=${elapsed}s — killing federation and exiting 99"
        KILL_SCRIPT="$REPO_ROOT/tools/kill-federation.sh"
        if [ -x "$KILL_SCRIPT" ]; then
            bash "$KILL_SCRIPT" --fed-dir "$FED_DIR" --no-backup \
                >>"$RUN_DIR/kill-federation.log" 2>&1 || true
        else
            kill "$FED_PID" 2>/dev/null || true
        fi
        exit 99
    fi
done

# --- Reliable shutdown via tools/kill-federation.sh ---
echo "[run-stage2] stopping federation..."
KILL_SCRIPT="$REPO_ROOT/tools/kill-federation.sh"
if [ -x "$KILL_SCRIPT" ]; then
    bash "$KILL_SCRIPT" --fed-dir "$FED_DIR" --no-backup >>"$RUN_DIR/kill-federation.log" 2>&1 || true
else
    echo "run-stage2: kill-federation.sh not found at $KILL_SCRIPT — falling back to kill" >&2
    kill "$FED_PID" 2>/dev/null || true
fi

# Reap the colony worker spawned by start-federation.sh.
if [ -f "$RUN_DIR/worker.pid" ]; then
    worker_pid="$(cat "$RUN_DIR/worker.pid" 2>/dev/null || echo)"
    if [ -n "$worker_pid" ]; then
        kill "$worker_pid" 2>/dev/null || true
    fi
fi

# Reap the start-federation wrapper if still alive.
wait "$FED_PID" 2>/dev/null || true

# --- Telemetry ---
echo "[run-stage2] analysing run..."
ANALYSER="$TOOLS_DIR/analyse-stage2.py"
if ! python3 "$ANALYSER" "$RUN_DIR"; then
    echo "run-stage2: analyse-stage2.py failed" >&2
    exit 3
fi

echo "[run-stage2] done."
echo "[run-stage2] telemetry: $RUN_DIR/telemetry.csv"
echo "[run-stage2] bug-ledger: $RUN_DIR/bug-ledger.jsonl"
