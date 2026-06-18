#!/bin/bash
# test-run-stage2-llm-backend.sh — assert run-stage2.sh injects the
# right backend-specific config keys when STAGE2_LLM_BACKEND selects
# openai or ollama, defaults to flat-cyborg, and stays inert on the
# metered-claude path (#438, #1136).
#
# Five cases:
#
#   T0: STAGE2_LLM_BACKEND unset (default) produces a hermetic
#       .agentis/config with llm.backend = flat-cyborg +
#       llm.flat_cyborg.idle_ms = 4000 and NO openai / ollama keys.
#   T1: STAGE2_LLM_BACKEND=openai produces a hermetic .agentis/config
#       containing all four llm.openai.* keys at their documented
#       defaults.
#   T2: STAGE2_LLM_BACKEND=ollama produces a config containing
#       llm.endpoint and llm.model at their documented defaults.
#   T3: STAGE2_LLM_BACKEND=claude produces NO llm.openai.* and NO
#       llm.endpoint / llm.model lines (regression guard).
#   T4: STAGE2_LLM_BACKEND=flat-cyborg (explicit) produces
#       llm.backend = flat-cyborg + llm.flat_cyborg.idle_ms = 4000 and
#       NO openai / ollama keys.
#
# STAGE2_WALL_CLOCK_S=1 makes the harness exit after a single 1-second
# snapshot tick. The federation daemons + worker that start-federation.sh
# spawned are reaped by tools/kill-federation.sh in trap cleanup so the
# next case starts from a clean slate.
#
# Skips when `agentis` is not on PATH (same convention as
# test-stage2-baseline-runner.sh).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"
KILL_SCRIPT="$REPO_ROOT/tools/kill-federation.sh"

PASS=0
FAIL=0
SKIP=0

assert_grep_F() {
    # $1 label, $2 file, $3 needle (literal)
    label="$1"; file="$2"; needle="$3"
    if [ -f "$file" ] && grep -Fq -- "$needle" "$file"; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       file:   $file"
        echo "       needle: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_no_active_key() {
    # $1 label, $2 file, $3 key prefix (regex-escaped, anchored at line start)
    # -- key MUST NOT appear as an active (uncommented) config line.
    # `agentis init` ships a commented-out exemplar for every backend, so
    # we anchor with `^` to skip any `# ...` line.
    label="$1"; file="$2"; key="$3"
    if [ ! -f "$file" ]; then
        echo "[FAIL] $label (file missing: $file)"
        FAIL=$((FAIL + 1))
        return
    fi
    if grep -Eq -- "^${key}" "$file"; then
        echo "[FAIL] $label"
        echo "       file:        $file"
        echo "       active key:  $key"
        FAIL=$((FAIL + 1))
    else
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    fi
}

skip_case() {
    echo "[SKIP] $1 ($2)"
    SKIP=$((SKIP + 1))
}

if ! command -v agentis >/dev/null 2>&1; then
    echo "SKIP: agentis not on PATH"
    exit 77
fi
for bin in jq python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "SKIP: $bin not on PATH"
        exit 77
    fi
done

# --- Cleanup helper: kill federation under the given run dir, then nuke
# the whole runs/<ts> tree so it doesn't pollute the federation runs/.
# Always recorded so trap can reap whatever is in flight on test exit.
LAST_RUN_DIR=""
cleanup_run() {
    rd="$1"
    if [ -z "$rd" ] || [ ! -d "$rd" ]; then
        return 0
    fi
    if [ -x "$KILL_SCRIPT" ]; then
        bash "$KILL_SCRIPT" --fed-dir "$rd" --no-backup >/dev/null 2>&1 || true
    fi
    if [ -f "$rd/worker.pid" ]; then
        wpid="$(cat "$rd/worker.pid" 2>/dev/null || echo)"
        if [ -n "$wpid" ]; then
            kill "$wpid" 2>/dev/null || true
        fi
    fi
    rm -rf "$rd" 2>/dev/null || true
}

trap 'cleanup_run "$LAST_RUN_DIR"' EXIT INT TERM

# --- Snapshot existing runs/ so we can identify the new run dir each case
list_run_dirs() {
    if [ -d "$FED_DIR/runs" ]; then
        ls -1d "$FED_DIR/runs"/* 2>/dev/null || true
    fi
}

run_case() {
    # $1 label, $2 backend value (passed via STAGE2_LLM_BACKEND env)
    # On stdout: prints the new RUN_DIR on success, empty on failure.
    label="$1"; backend="$2"
    before="$(list_run_dirs)"
    log="$(mktemp)"
    # Pass backend explicitly; env-clear keeps the test hermetic against
    # operator-set STAGE2_OPENAI_* overrides.
    if [ -n "$backend" ]; then
        env -u STAGE2_OPENAI_MODEL -u STAGE2_OPENAI_ENDPOINT \
            -u STAGE2_OPENAI_KEY_ENV -u STAGE2_OPENAI_TIMEOUT_MS \
            -u STAGE2_OLLAMA_ENDPOINT -u STAGE2_OLLAMA_MODEL \
            -u STAGE2_FLAT_CYBORG_IDLE_MS -u STAGE2_FLAT_CYBORG_MODEL \
            -u STAGE2_RESUME_RUN_DIR -u STAGE2_CRASH_AT_S \
            STAGE2_LLM_BACKEND="$backend" \
            STAGE2_WALL_CLOCK_S=1 STAGE2_SNAPSHOT_S=1 \
            bash "$FED_DIR/tools/run-stage2.sh" >"$log" 2>&1 || true
    else
        env -u STAGE2_LLM_BACKEND \
            -u STAGE2_OPENAI_MODEL -u STAGE2_OPENAI_ENDPOINT \
            -u STAGE2_OPENAI_KEY_ENV -u STAGE2_OPENAI_TIMEOUT_MS \
            -u STAGE2_OLLAMA_ENDPOINT -u STAGE2_OLLAMA_MODEL \
            -u STAGE2_FLAT_CYBORG_IDLE_MS -u STAGE2_FLAT_CYBORG_MODEL \
            -u STAGE2_RESUME_RUN_DIR -u STAGE2_CRASH_AT_S \
            STAGE2_WALL_CLOCK_S=1 STAGE2_SNAPSHOT_S=1 \
            bash "$FED_DIR/tools/run-stage2.sh" >"$log" 2>&1 || true
    fi
    after="$(list_run_dirs)"
    new_dir=""
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if ! printf '%s\n' "$before" | grep -Fxq -- "$d"; then
            new_dir="$d"
            break
        fi
    done <<EOF_RUNS
$after
EOF_RUNS
    rm -f "$log"
    if [ -z "$new_dir" ]; then
        echo "[FAIL] $label: run-stage2.sh did not create a new runs/<ts> dir" >&2
        return 1
    fi
    LAST_RUN_DIR="$new_dir"
    printf '%s\n' "$new_dir"
}

# --- T0: default (unset) backend → flat-cyborg ---
echo "--- T0: STAGE2_LLM_BACKEND unset (default flat-cyborg) ---"
RUN_T0="$(run_case "T0" "" || true)"
if [ -n "$RUN_T0" ]; then
    CFG="$RUN_T0/.agentis/config"
    assert_grep_F "T0: llm.backend defaults to flat-cyborg" "$CFG" \
        "llm.backend = flat-cyborg"
    assert_grep_F "T0: llm.flat_cyborg.idle_ms default injected" "$CFG" \
        "llm.flat_cyborg.idle_ms = 4000"
    assert_no_active_key "T0: no active llm.openai.endpoint key" "$CFG" "llm\\.openai\\.endpoint"
    assert_no_active_key "T0: no active llm.openai.model key" "$CFG" "llm\\.openai\\.model"
    assert_no_active_key "T0: no active llm.endpoint key" "$CFG" "llm\\.endpoint"
    assert_no_active_key "T0: no active llm.model key" "$CFG" "llm\\.model"
else
    echo "[FAIL] T0: no run dir produced"
    FAIL=$((FAIL + 1))
fi
cleanup_run "$RUN_T0"
LAST_RUN_DIR=""

# --- T1: openai backend ---
echo "--- T1: STAGE2_LLM_BACKEND=openai ---"
RUN_T1="$(run_case "T1" "openai" || true)"
if [ -n "$RUN_T1" ]; then
    CFG="$RUN_T1/.agentis/config"
    assert_grep_F "T1: llm.openai.endpoint default injected" "$CFG" \
        "llm.openai.endpoint = https://api.openai.com/v1/chat/completions"
    assert_grep_F "T1: llm.openai.model default injected" "$CFG" \
        "llm.openai.model = gpt-4o-mini"
    assert_grep_F "T1: llm.openai.api_key_env default injected" "$CFG" \
        "llm.openai.api_key_env = OPENAI_API_KEY"
    assert_grep_F "T1: llm.openai.timeout_ms default injected" "$CFG" \
        "llm.openai.timeout_ms = 180000"
    assert_grep_F "T1: llm.backend rewritten to openai" "$CFG" \
        "llm.backend = openai"
else
    echo "[FAIL] T1: no run dir produced"
    FAIL=$((FAIL + 1))
fi
cleanup_run "$RUN_T1"
LAST_RUN_DIR=""

# --- T2: ollama backend ---
echo "--- T2: STAGE2_LLM_BACKEND=ollama ---"
RUN_T2="$(run_case "T2" "ollama" || true)"
if [ -n "$RUN_T2" ]; then
    CFG="$RUN_T2/.agentis/config"
    assert_grep_F "T2: llm.endpoint default injected" "$CFG" \
        "llm.endpoint = http://127.0.0.1:11434/api/generate"
    assert_grep_F "T2: llm.model default injected" "$CFG" \
        "llm.model = llama3.1:8b"
    assert_grep_F "T2: llm.backend rewritten to ollama" "$CFG" \
        "llm.backend = ollama"
    # No openai keys leaked into the ollama path.
    assert_no_active_key "T2: no active llm.openai.endpoint key" "$CFG" "llm\\.openai\\.endpoint"
    assert_no_active_key "T2: no active llm.openai.model key" "$CFG" "llm\\.openai\\.model"
else
    echo "[FAIL] T2: no run dir produced"
    FAIL=$((FAIL + 1))
fi
cleanup_run "$RUN_T2"
LAST_RUN_DIR=""

# --- T3: claude (default) backend — no regression ---
echo "--- T3: STAGE2_LLM_BACKEND=claude ---"
RUN_T3="$(run_case "T3" "claude" || true)"
if [ -n "$RUN_T3" ]; then
    CFG="$RUN_T3/.agentis/config"
    assert_grep_F "T3: llm.backend rewritten to claude" "$CFG" \
        "llm.backend = claude"
    assert_no_active_key "T3: no active llm.openai.endpoint key" "$CFG" "llm\\.openai\\.endpoint"
    assert_no_active_key "T3: no active llm.openai.model key" "$CFG" "llm\\.openai\\.model"
    assert_no_active_key "T3: no active llm.openai.api_key_env key" "$CFG" "llm\\.openai\\.api_key_env"
    assert_no_active_key "T3: no active llm.openai.timeout_ms key" "$CFG" "llm\\.openai\\.timeout_ms"
    assert_no_active_key "T3: no active llm.endpoint key" "$CFG" "llm\\.endpoint"
    assert_no_active_key "T3: no active llm.model key" "$CFG" "llm\\.model"
else
    echo "[FAIL] T3: no run dir produced"
    FAIL=$((FAIL + 1))
fi
cleanup_run "$RUN_T3"
LAST_RUN_DIR=""

# --- T4: flat-cyborg (explicit) backend ---
echo "--- T4: STAGE2_LLM_BACKEND=flat-cyborg ---"
RUN_T4="$(run_case "T4" "flat-cyborg" || true)"
if [ -n "$RUN_T4" ]; then
    CFG="$RUN_T4/.agentis/config"
    assert_grep_F "T4: llm.backend rewritten to flat-cyborg" "$CFG" \
        "llm.backend = flat-cyborg"
    assert_grep_F "T4: llm.flat_cyborg.idle_ms default injected" "$CFG" \
        "llm.flat_cyborg.idle_ms = 4000"
    assert_no_active_key "T4: no active llm.openai.endpoint key" "$CFG" "llm\\.openai\\.endpoint"
    assert_no_active_key "T4: no active llm.openai.model key" "$CFG" "llm\\.openai\\.model"
    assert_no_active_key "T4: no active llm.endpoint key" "$CFG" "llm\\.endpoint"
    assert_no_active_key "T4: no active llm.model key" "$CFG" "llm\\.model"
else
    echo "[FAIL] T4: no run dir produced"
    FAIL=$((FAIL + 1))
fi
cleanup_run "$RUN_T4"
LAST_RUN_DIR=""

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
