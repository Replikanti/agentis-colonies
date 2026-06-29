#!/usr/bin/env bash
# test-code-edit-job.sh (#1214): exercise the FAST detached launcher
# tools/code-edit-job.sh WITHOUT a real Claude Code / git session. The slow
# orchestrator (code-edit-in-checkout.sh) is replaced by a STUB pointed at via
# the CODE_EDIT_ORCH override env. The stub sleeps briefly (so the launcher must
# return WHILE it is still running) then writes a known result keyed by exit code.
#
# Asserts:
#   1. first call returns LAUNCHED, creates a job dir with status=running, a
#      recorded pid, and a LIVE detached process (returns fast, < a few sec)
#   2. a second call while running returns RUNNING and does NOT start a second
#      orchestrator (exactly one child observed)
#   3. after the stub finishes:
#        exit 0 -> DONE <url>   (url from the stub's stdout)
#        exit 3 -> NO_EDITS
#        exit 7 -> ERROR ...
#   4. dead-pid-with-running-status -> ERROR (no hang)
#   5. the token NEVER appears in the launcher's stdout/stderr
#
# Auto-discovered by tools/colony-lint.sh's tools-test loop. Exit 0 if all pass.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
LAUNCHER="$REPO_ROOT/tools/code-edit-job.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if [ ! -f "$LAUNCHER" ]; then
    fail "launcher missing: $LAUNCHER"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_TOKEN="ghp_FAKE_TOKEN_DO_NOT_LEAK_abcdef0123456789"
OWNER="acme"
REPO="widget"

# A fake colony tree so the launcher resolves COLONY_DIR -> FED_DIR -> the job
# dir under <fed>/.agentis/jobs/<colony>/issue-<iid>/.
FED_DIR="$WORK/fed"
COLONY_DIR="$FED_DIR/implementation"
mkdir -p "$COLONY_DIR"

# ---------------------------------------------------------------------------
# Stub orchestrator. Behaviour driven by env so a single file covers all modes:
#   STUB_SLEEP    : seconds to sleep before exiting (default 2) — long enough
#                   that the launcher must return while it is still running.
#   STUB_EXIT     : exit code (0 -> success, 3 -> NO_EDITS, other -> error).
#   STUB_URL      : PR URL printed on stdout (success path).
#   STUB_MARKER   : a file the stub touches on start, so the test can count how
#                   many orchestrator instances actually launched.
# It also asserts GITHUB_TOKEN reached it via the inherited env (never argv).
# ---------------------------------------------------------------------------
STUB="$WORK/stub-orch.sh"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -u
# Record one start (append) so the harness can count launches.
if [ -n "${STUB_MARKER:-}" ]; then echo "start $$ token=${GITHUB_TOKEN:-MISSING} args=[$*]" >> "$STUB_MARKER"; fi
sleep "${STUB_SLEEP:-2}"
if [ "${STUB_EXIT:-0}" -eq 0 ]; then
    printf '%s\n' "${STUB_URL:-https://example.test/pr/1}"
fi
exit "${STUB_EXIT:-0}"
STUB_EOF
chmod +x "$STUB"

# run_launcher <issue> : invoke the launcher with the colony env + the stub
# orchestrator override. Identifying args are constant; the issue iid keys the
# job dir. STUB_* knobs are inherited from the caller's env.
run_launcher() {
    local iid="$1"
    env \
        COLONY_DIR="$COLONY_DIR" \
        CODE_EDIT_ORCH="$STUB" \
        GITHUB_TOKEN="$FAKE_TOKEN" \
        GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
        STUB_SLEEP="${STUB_SLEEP:-2}" STUB_EXIT="${STUB_EXIT:-0}" \
        STUB_URL="${STUB_URL:-https://example.test/pr/1}" \
        STUB_MARKER="${STUB_MARKER:-}" \
        bash "$LAUNCHER" \
            --owner "$OWNER" --repo "$REPO" --issue "$iid" \
            --branch "fix/issue-$iid" --title "implement thing" \
            --task "Edit the files to implement the thing."
}

job_dir_for() { echo "$FED_DIR/.agentis/jobs/implementation/issue-$1"; }

# ===========================================================================
# Scenario A (exit 0 -> DONE): launch, observe RUNNING, then DONE <url>.
# ===========================================================================
IID=42
MARKER_A="$WORK/marker-a.log"
export STUB_SLEEP=2 STUB_EXIT=0 STUB_URL="https://example.test/pr/42" STUB_MARKER="$MARKER_A"

OUTA1="$WORK/a1.out"; ERRA1="$WORK/a1.err"
run_launcher "$IID" >"$OUTA1" 2>"$ERRA1"
RCA1=$?
A1="$(cat "$OUTA1")"

if [ "$RCA1" -eq 0 ] && [ "$A1" = "LAUNCHED" ]; then
    pass "A: first call returns LAUNCHED and exits 0 (fast)"
else
    fail "A: first call LAUNCHED" "rc=$RCA1 stdout=[$A1] err=$(cat "$ERRA1")"
fi

JD="$(job_dir_for "$IID")"
if [ -d "$JD" ] && [ "$(cat "$JD/status" 2>/dev/null)" = "running" ]; then
    pass "A: job dir created with status=running"
else
    fail "A: job dir status=running" "dir=$JD status=$(cat "$JD/status" 2>/dev/null)"
fi

JPID="$(cat "$JD/pid" 2>/dev/null || echo '')"
if [ -n "$JPID" ] && kill -0 "$JPID" 2>/dev/null; then
    pass "A: a live detached pid is recorded"
else
    fail "A: live detached pid recorded" "pid=[$JPID]"
fi

# Token must not appear in the launcher's own stdout/stderr.
if grep -q "$FAKE_TOKEN" "$OUTA1" "$ERRA1"; then
    fail "A: token LEAKED into launcher stdout/stderr"
else
    pass "A: token never appears in launcher stdout/stderr"
fi

# Second call WHILE running -> RUNNING, and must NOT start a second job.
OUTA2="$WORK/a2.out"; ERRA2="$WORK/a2.err"
run_launcher "$IID" >"$OUTA2" 2>"$ERRA2"
A2="$(cat "$OUTA2")"
if [ "$A2" = "RUNNING" ]; then
    pass "A: second call while running returns RUNNING"
else
    fail "A: second call RUNNING" "stdout=[$A2]"
fi

# Exactly ONE orchestrator instance ever started (idempotency).
STARTS="$(grep -c '^start ' "$MARKER_A" 2>/dev/null || echo 0)"
if [ "$STARTS" -eq 1 ]; then
    pass "A: idempotent — exactly one orchestrator launched despite two calls"
else
    fail "A: only one orchestrator launched" "starts=$STARTS"
fi

# Wait for the detached stub to finish (sleep 2 + margin), then poll -> DONE.
i=0
while kill -0 "$JPID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
# Give the worker a beat to write the terminal status atomically.
sleep 0.3

OUTA3="$WORK/a3.out"; ERRA3="$WORK/a3.err"
run_launcher "$IID" >"$OUTA3" 2>"$ERRA3"
A3="$(cat "$OUTA3")"
if [ "$A3" = "DONE https://example.test/pr/42" ]; then
    pass "A: poll after finish returns DONE <pr-url>"
else
    fail "A: DONE <pr-url>" "stdout=[$A3] log=$(cat "$JD/log" 2>/dev/null)"
fi

# Terminal poll consumes/clears the job dir so the next call would relaunch.
if [ ! -d "$JD" ]; then
    pass "A: terminal poll cleared the job dir (consumed)"
else
    fail "A: job dir cleared after DONE" "still exists: $JD"
fi

# The stub saw the token via the inherited environment (never argv).
if grep -q "token=$FAKE_TOKEN" "$MARKER_A"; then
    pass "A: detached child inherited GITHUB_TOKEN via env"
else
    fail "A: token inherited by detached child" "marker=$(cat "$MARKER_A" 2>/dev/null)"
fi

# ===========================================================================
# Scenario B (exit 3 -> NO_EDITS).
# ===========================================================================
IID=43
MARKER_B="$WORK/marker-b.log"
export STUB_SLEEP=1 STUB_EXIT=3 STUB_MARKER="$MARKER_B"
run_launcher "$IID" >/dev/null 2>&1
JD="$(job_dir_for "$IID")"
JPID="$(cat "$JD/pid" 2>/dev/null || echo '')"
i=0
while kill -0 "$JPID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
sleep 0.3
B="$(run_launcher "$IID" 2>/dev/null)"
if [ "$B" = "NO_EDITS" ]; then
    pass "B: exit-3 orchestrator -> NO_EDITS"
else
    fail "B: NO_EDITS on exit 3" "stdout=[$B]"
fi

# ===========================================================================
# Scenario C (exit 7 -> ERROR).
# ===========================================================================
IID=44
MARKER_C="$WORK/marker-c.log"
export STUB_SLEEP=1 STUB_EXIT=7 STUB_MARKER="$MARKER_C"
run_launcher "$IID" >/dev/null 2>&1
JD="$(job_dir_for "$IID")"
JPID="$(cat "$JD/pid" 2>/dev/null || echo '')"
i=0
while kill -0 "$JPID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
sleep 0.3
C="$(run_launcher "$IID" 2>/dev/null)"
case "$C" in
    ERROR*) pass "C: non-0/non-3 orchestrator exit -> ERROR" ;;
    *) fail "C: ERROR on exit 7" "stdout=[$C]" ;;
esac

# ===========================================================================
# Scenario D (dead pid + status=running -> ERROR, no hang). Forge a job dir by
# hand: status=running but pid points at a definitely-dead process.
# ===========================================================================
IID=45
JD="$(job_dir_for "$IID")"
mkdir -p "$JD"
printf 'running' > "$JD/status"
# A pid that is not alive: spawn `true`, reap it, reuse its (now-dead) pid.
( exec true ) & DEAD=$!
wait "$DEAD" 2>/dev/null || true
# In the unlikely event the pid was recycled, fall back to a huge unused pid.
if kill -0 "$DEAD" 2>/dev/null; then DEAD=2147480000; fi
printf '%s' "$DEAD" > "$JD/pid"

# A poll of an existing (forged) running-but-dead job never launches the stub,
# so the STUB_* knobs are irrelevant here; the launcher must return on its own.
export STUB_SLEEP=1 STUB_EXIT=0 STUB_MARKER=''
D="$(run_launcher "$IID" 2>/dev/null)" || true
case "$D" in
    ERROR*) pass "D: dead-pid + status=running -> ERROR (no hang)" ;;
    *) fail "D: ERROR on dead pid" "stdout=[$D]" ;;
esac
if [ ! -d "$JD" ]; then
    pass "D: stale dead-pid job dir cleared for relaunch"
else
    fail "D: dead-pid job dir cleared" "still exists: $JD"
fi

# ===========================================================================
# Scenario E (#1254): --decompose is forwarded to the orchestrator; a normal
# run omits it. The stub records its argv to a marker file.
# ===========================================================================
poll_done() {
    _jd="$1"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -f "$_jd/status" ] && grep -q "done" "$_jd/status" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

DEC_MARKER="$WORK/dec-marker"; : > "$DEC_MARKER"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    STUB_SLEEP=0 STUB_EXIT=0 STUB_URL="https://example.test/pr/dec" STUB_MARKER="$DEC_MARKER" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 700 \
        --branch "fix/issue-700" --title "epic" --task "do it" --decompose >/dev/null 2>&1
poll_done "$(job_dir_for 700)" || true
if grep -q -- '--decompose' "$DEC_MARKER" 2>/dev/null; then
    pass "E: --decompose is forwarded to the orchestrator"
else
    fail "E: --decompose passthrough" "marker=$(cat "$DEC_MARKER" 2>/dev/null)"
fi

NEG_MARKER="$WORK/neg-marker"; : > "$NEG_MARKER"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    STUB_SLEEP=0 STUB_EXIT=0 STUB_URL="https://example.test/pr/nodec" STUB_MARKER="$NEG_MARKER" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 701 \
        --branch "fix/issue-701" --title "normal" --task "do it" >/dev/null 2>&1
poll_done "$(job_dir_for 701)" || true
if grep -q -- '--decompose' "$NEG_MARKER" 2>/dev/null; then
    fail "E: normal run wrongly forwarded --decompose" "marker=$(cat "$NEG_MARKER" 2>/dev/null)"
else
    pass "E: a normal run does NOT pass --decompose"
fi

# ===========================================================================
# Scenario F (#1367): global concurrency cap. With CODE_EDIT_MAX_CONCURRENT=1
# and ONE live `running` sibling job present, a NEW issue's launch must print
# the not-yet-done sentinel `RUNNING`, NOT spawn an orchestrator, and NOT
# create its own job dir (so the next tick re-evaluates cleanly). Raising the
# cap lets the same launch proceed (LAUNCHED + job dir created).
# ===========================================================================
# Forge a live sibling job by hand: status=running with a pid that stays alive
# for the duration of this scenario.
LIVE_IID=800
LIVE_JD="$(job_dir_for "$LIVE_IID")"
mkdir -p "$LIVE_JD"
printf 'running' > "$LIVE_JD/status"
sleep 30 & LIVE_PID=$!
printf '%s' "$LIVE_PID" > "$LIVE_JD/pid"

CAP_MARKER="$WORK/cap-marker"; : > "$CAP_MARKER"
CAP_IID=801
CAP_OUT="$WORK/cap.out"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    CODE_EDIT_MAX_CONCURRENT=1 \
    STUB_SLEEP=5 STUB_EXIT=0 STUB_URL="https://example.test/pr/801" STUB_MARKER="$CAP_MARKER" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue "$CAP_IID" \
        --branch "fix/issue-$CAP_IID" --title "capped" --task "do it" >"$CAP_OUT" 2>/dev/null
CAPW="$(cat "$CAP_OUT")"
if [ "$CAPW" = "RUNNING" ]; then
    pass "F: at cap, a new launch prints the not-yet-done sentinel RUNNING"
else
    fail "F: capped launch prints RUNNING" "stdout=[$CAPW]"
fi
if [ ! -d "$(job_dir_for "$CAP_IID")" ]; then
    pass "F: a capped launch does NOT create the issue's job dir"
else
    fail "F: capped launch leaves no job dir" "dir exists: $(job_dir_for "$CAP_IID")"
fi
if [ ! -s "$CAP_MARKER" ]; then
    pass "F: a capped launch does NOT spawn the orchestrator"
else
    fail "F: capped launch spawned nothing" "marker=$(cat "$CAP_MARKER" 2>/dev/null)"
fi

# Under the cap (raise to 2 with one live sibling) the same launch proceeds.
UNCAP_MARKER="$WORK/uncap-marker"; : > "$UNCAP_MARKER"
UNCAP_IID=802
UNCAP_OUT="$WORK/uncap.out"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    CODE_EDIT_MAX_CONCURRENT=2 \
    STUB_SLEEP=5 STUB_EXIT=0 STUB_URL="https://example.test/pr/802" STUB_MARKER="$UNCAP_MARKER" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue "$UNCAP_IID" \
        --branch "fix/issue-$UNCAP_IID" --title "uncapped" --task "do it" >"$UNCAP_OUT" 2>/dev/null
UNCAPW="$(cat "$UNCAP_OUT")"
UNCAP_JD="$(job_dir_for "$UNCAP_IID")"
if [ "$UNCAPW" = "LAUNCHED" ] && [ -d "$UNCAP_JD" ] \
   && [ "$(cat "$UNCAP_JD/status" 2>/dev/null)" = "running" ]; then
    pass "F: under the cap, the same launch proceeds (LAUNCHED + job dir)"
else
    fail "F: under-cap launch proceeds" "stdout=[$UNCAPW] dir=$UNCAP_JD"
fi
# Clean up the forged live sibling + the under-cap detached job.
kill "$LIVE_PID" 2>/dev/null || true
UNCAP_PID="$(cat "$UNCAP_JD/pid" 2>/dev/null || echo '')"
[ -n "$UNCAP_PID" ] && kill "$UNCAP_PID" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
