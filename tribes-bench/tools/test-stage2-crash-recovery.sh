#!/bin/bash
# test-stage2-crash-recovery.sh — Stage 2 M3 (#394) crash-recovery drill.
#
# 7-case test from §5 Test B of the plan. Mirrors the shape of
# test-stage2-cognitive-market.sh: PASS/FAIL/SKIP helpers, exit 0 on
# green. Shells out to run-stage2.sh with STAGE2_CRASH_AT_S +
# STAGE2_RESUME_RUN_DIR.
#
# Skip pattern: agentis not on PATH or no LLM API key in env -> SKIP all
# live cases. Static cases (1-4) always run.
#
# Cases:
#   1. run-stage2.sh declares STAGE2_CRASH_AT_S env var in its docstring.
#   2. run-stage2.sh declares STAGE2_RESUME_RUN_DIR env var in its docstring.
#   3. run-stage2.sh declares the new 48h / 1h defaults in its docstring.
#   4. run-stage2.sh exit-99 path is hooked from inside the snapshot loop.
#   5. Live: STAGE2_CRASH_AT_S=10 STAGE2_WALL_CLOCK_S=30
#      STAGE2_SNAPSHOT_S=5 -> exit 99, runs/<ts>/ + bug-ledger.jsonl +
#      .agentis/ + at least one snapshot persist.
#   6. Live: STAGE2_RESUME_RUN_DIR=<the crashed run> STAGE2_WALL_CLOCK_S=20
#      STAGE2_SNAPSHOT_S=5 -> exit 0, run-meta-resume-1.json appears,
#      old snapshots are NOT clobbered, new snapshots are appended,
#      bug-ledger.jsonl is NOT truncated.
#   7. Snapshot payload: at least one snapshot under the resumed run
#      contains the 7-section header stanzas.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
SKIP=0

assert_eq() {
    label="$1"; exp="$2"; got="$3"
    if [ "$exp" = "$got" ]; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       expected: $exp"
        echo "       got:      $got"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
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

skip_case() {
    echo "[SKIP] $1 ($2)"
    SKIP=$((SKIP + 1))
}

cleanup_federation() {
    KILL="$FED_DIR/../tools/kill-federation.sh"
    if [ -x "$KILL" ]; then
        bash "$KILL" --fed-dir "$FED_DIR" --no-backup >/dev/null 2>&1 || true
    fi
}
trap cleanup_federation EXIT

RS="$FED_DIR/tools/run-stage2.sh"

# --- 1-3. Static doc assertions ---
assert_contains "run-stage2.sh declares STAGE2_CRASH_AT_S" "$RS" "STAGE2_CRASH_AT_S"
assert_contains "run-stage2.sh declares STAGE2_RESUME_RUN_DIR" "$RS" "STAGE2_RESUME_RUN_DIR"
assert_contains "run-stage2.sh wall-clock default 172800 (48h)" "$RS" "172800"
assert_contains "run-stage2.sh snapshot default 3600 (1h)" "$RS" "3600"

# --- 4. exit 99 hooked from inside the snapshot loop ---
assert_contains "run-stage2.sh exits 99 on simulated crash" "$RS" "exit 99"

# --- 5/6/7. Live drill (skip without agentis + LLM key) ---
HAS_KEY=0
if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${CLAUDE_API_KEY:-}" ] || [ -n "${OPENAI_API_KEY:-}" ]; then
    HAS_KEY=1
fi
if ! command -v agentis >/dev/null 2>&1; then
    skip_case "live crash drill (T+0)" "agentis not on PATH"
    skip_case "live resume drill (T+1)" "agentis not on PATH"
    skip_case "snapshot stanza payload check" "agentis not on PATH"
elif [ "$HAS_KEY" = "0" ]; then
    skip_case "live crash drill (T+0)" "no LLM API key in env"
    skip_case "live resume drill (T+1)" "no LLM API key in env"
    skip_case "snapshot stanza payload check" "no LLM API key in env"
else
    # T+0: launch with crash trigger.
    CRASH_LOG="$(mktemp)"
    set +e
    STAGE2_WALL_CLOCK_S=30 STAGE2_SNAPSHOT_S=5 STAGE2_CRASH_AT_S=10 \
        bash "$RS" >"$CRASH_LOG" 2>&1
    crash_exit=$?
    set -e
    if [ "$crash_exit" = "99" ]; then
        echo "[PASS] live: STAGE2_CRASH_AT_S triggered exit 99"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] live: expected exit 99, got $crash_exit"
        FAIL=$((FAIL + 1))
    fi
    last_run="$(ls -td "$FED_DIR"/runs/2* 2>/dev/null | head -1 || true)"
    if [ -n "$last_run" ] && [ -d "$last_run/.agentis" ] && [ -f "$last_run/bug-ledger.jsonl" ]; then
        echo "[PASS] live: post-crash run dir + .agentis/ + bug-ledger persist"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] live: post-crash artefacts missing under $last_run"
        FAIL=$((FAIL + 1))
    fi
    pre_snap_count="$(ls "$last_run/snapshots/"*.txt 2>/dev/null | wc -l | tr -d ' ')"
    if [ -n "$pre_snap_count" ] && [ "$pre_snap_count" -ge 1 ]; then
        echo "[PASS] live: pre-crash snapshots persist ($pre_snap_count file(s))"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] live: pre-crash snapshots missing"
        FAIL=$((FAIL + 1))
    fi
    pre_bl_lines="$(wc -l < "$last_run/bug-ledger.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"

    # T+1: resume the same run dir.
    if [ -n "$last_run" ]; then
        RESUME_LOG="$(mktemp)"
        set +e
        STAGE2_RESUME_RUN_DIR="$last_run" STAGE2_WALL_CLOCK_S=20 STAGE2_SNAPSHOT_S=5 \
            bash "$RS" >"$RESUME_LOG" 2>&1
        resume_exit=$?
        set -e
        if [ "$resume_exit" = "0" ]; then
            echo "[PASS] live resume: exit 0"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] live resume: expected exit 0, got $resume_exit"
            FAIL=$((FAIL + 1))
        fi
        if [ -f "$last_run/run-meta-resume-1.json" ]; then
            echo "[PASS] live resume: run-meta-resume-1.json written"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] live resume: run-meta-resume-1.json missing"
            FAIL=$((FAIL + 1))
        fi
        post_snap_count="$(ls "$last_run/snapshots/"*.txt 2>/dev/null | wc -l | tr -d ' ')"
        if [ -n "$post_snap_count" ] && [ "$post_snap_count" -gt "$pre_snap_count" ]; then
            echo "[PASS] live resume: snapshot count grew ($pre_snap_count -> $post_snap_count)"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] live resume: snapshot count did not grow"
            FAIL=$((FAIL + 1))
        fi

        # #399: bug-ledger size-delta — resume must not truncate.
        post_bl_lines="$(wc -l < "$last_run/bug-ledger.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"
        if [ "$post_bl_lines" -ge "$pre_bl_lines" ]; then
            echo "[PASS] live resume: bug-ledger preserved ($pre_bl_lines -> $post_bl_lines lines)"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] live resume: bug-ledger truncated ($pre_bl_lines -> $post_bl_lines lines)"
            FAIL=$((FAIL + 1))
        fi

        # #399: no duplicate (bug_id, ts) rows in resumed bug-ledger.
        if command -v jq >/dev/null 2>&1; then
            dup_count="$(jq -s 'group_by([.bug_id, .ts]) | map(select(length > 1)) | length' "$last_run/bug-ledger.jsonl" 2>/dev/null || echo -1)"
            if [ "$dup_count" = "0" ]; then
                echo "[PASS] live resume: no duplicate (bug_id, ts) rows in bug-ledger"
                PASS=$((PASS + 1))
            else
                echo "[FAIL] live resume: $dup_count duplicate (bug_id, ts) row group(s) in bug-ledger"
                FAIL=$((FAIL + 1))
            fi
        else
            echo "[SKIP] live resume: jq missing — duplicate-row check skipped"
            SKIP=$((SKIP + 1))
        fi

        # Snapshot stanza payload: at least one snapshot must contain
        # the 7-section header form.
        sample_snap="$(ls -t "$last_run/snapshots/"*.txt 2>/dev/null | head -1 || true)"
        if [ -n "$sample_snap" ] && \
           grep -Fq "## daemon-list" "$sample_snap" && \
           grep -Fq "## experience-counts" "$sample_snap" && \
           grep -Fq "## spend-counts" "$sample_snap" && \
           grep -Fq "## bug-ledger" "$sample_snap" && \
           grep -Fq "## market-csv" "$sample_snap" && \
           grep -Fq "## reputation-memos" "$sample_snap" && \
           grep -Fq "## per-tribe-cb" "$sample_snap"; then
            echo "[PASS] live: snapshot has 7 header stanzas ($sample_snap)"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] live: snapshot missing one or more header stanzas ($sample_snap)"
            FAIL=$((FAIL + 1))
        fi
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
