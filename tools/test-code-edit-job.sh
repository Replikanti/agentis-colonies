#!/usr/bin/env bash
# test-code-edit-job.sh (#1214): exercise the FAST detached launcher
# tools/code-edit-job.sh WITHOUT a real Claude Code / git session. The slow
# orchestrator (code-edit-in-checkout.sh) is replaced by a STUB pointed at via
# the CODE_EDIT_ORCH override env. The stub sleeps briefly (so the launcher must
# return WHILE it is still running) then writes a known result keyed by exit code.
#
# Asserts (post-#1356 the launcher is a DUMB reporter: it prints ONE raw line
# `STATUS=<s> PID_ALIVE=<0|1> RESULT=<url>` and NEVER deletes the job dir — the
# running/done/no_edits/error FSM and dir cleanup moved into code_writer.ag):
#   1. first call returns LAUNCHED, creates a job dir with status=running, a
#      recorded pid, and a LIVE detached process (returns fast, < a few sec)
#   2. a second call while running reports STATUS=running PID_ALIVE=1 and does
#      NOT start a second orchestrator (exactly one child observed)
#   3. after the stub finishes:
#        exit 0 -> STATUS=done PID_ALIVE=0 RESULT=<url> (url from the stub stdout)
#        exit 3 -> STATUS=no_edits PID_ALIVE=0 RESULT=
#        exit 7 -> STATUS=error PID_ALIVE=0 RESULT=
#      and the launcher leaves the job dir INTACT (cleanup is code_writer's job)
#   4. dead-pid-with-running-status -> STATUS=running PID_ALIVE=0 (no hang), dir
#      left intact
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
    # #1354 step 2b: a --one-attempt drive prints ONE structured outcome line
    # (not a URL); #1422 M1: a --decompose-only drive prints ONE `DECOMPOSED
    # count=<n>` line; every other drive (default / --finalize) prints the PR URL.
    case " $* " in
        *" --one-attempt "*)
            printf 'ONE_ATTEMPT exit=0 churn=%s verify=%s\n' "${STUB_CHURN:-1}" "${STUB_VERIFY:-pass}"
            ;;
        *" --decompose-only "*)
            printf 'DECOMPOSED count=%s\n' "${STUB_SUBTASKS:-3}"
            ;;
        *)
            printf '%s\n' "${STUB_URL:-https://example.test/pr/1}"
            ;;
    esac
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
export STUB_SLEEP=1 STUB_EXIT=0 STUB_URL="https://example.test/pr/42" STUB_MARKER="$MARKER_A"

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

# Second call WHILE running -> STATUS=running PID_ALIVE=1, and must NOT start a
# second job.
OUTA2="$WORK/a2.out"; ERRA2="$WORK/a2.err"
run_launcher "$IID" >"$OUTA2" 2>"$ERRA2"
A2="$(cat "$OUTA2")"
if [ "$A2" = "STATUS=running PID_ALIVE=1 RESULT=" ]; then
    pass "A: second call while running reports STATUS=running PID_ALIVE=1"
else
    fail "A: second call raw running status" "stdout=[$A2]"
fi

# Exactly ONE orchestrator instance ever started (idempotency).
STARTS="$(grep -c '^start ' "$MARKER_A" 2>/dev/null || echo 0)"
if [ "$STARTS" -eq 1 ]; then
    pass "A: idempotent — exactly one orchestrator launched despite two calls"
else
    fail "A: only one orchestrator launched" "starts=$STARTS"
fi

# Wait for the detached stub to finish (sleep 1 + margin), then poll -> DONE.
i=0
while kill -0 "$JPID" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
# Give the worker a beat to write the terminal status atomically.
sleep 0.2

OUTA3="$WORK/a3.out"; ERRA3="$WORK/a3.err"
run_launcher "$IID" >"$OUTA3" 2>"$ERRA3"
A3="$(cat "$OUTA3")"
if [ "$A3" = "STATUS=done PID_ALIVE=0 RESULT=https://example.test/pr/42" ]; then
    pass "A: poll after finish reports STATUS=done + RESULT <pr-url>"
else
    fail "A: done raw status" "stdout=[$A3] log=$(cat "$JD/log" 2>/dev/null)"
fi

# The launcher NEVER clears the job dir now (#1356) — cleanup moved to
# code_writer.ag once it decides a terminal state. A terminal poll must LEAVE
# the dir in place (still status=done) so code_writer can consume it.
if [ -d "$JD" ] && [ "$(cat "$JD/status" 2>/dev/null)" = "done" ]; then
    pass "A: terminal poll leaves the job dir intact (launcher never clears)"
else
    fail "A: job dir intact after done" "dir=$JD status=$(cat "$JD/status" 2>/dev/null)"
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
export STUB_SLEEP=0.5 STUB_EXIT=3 STUB_MARKER="$MARKER_B"
run_launcher "$IID" >/dev/null 2>&1
JD="$(job_dir_for "$IID")"
JPID="$(cat "$JD/pid" 2>/dev/null || echo '')"
i=0
while kill -0 "$JPID" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.2
B="$(run_launcher "$IID" 2>/dev/null)"
if [ "$B" = "STATUS=no_edits PID_ALIVE=0 RESULT=" ]; then
    pass "B: exit-3 orchestrator reports STATUS=no_edits"
else
    fail "B: no_edits raw status on exit 3" "stdout=[$B]"
fi

# ===========================================================================
# Scenario C (exit 7 -> ERROR).
# ===========================================================================
IID=44
MARKER_C="$WORK/marker-c.log"
export STUB_SLEEP=0.5 STUB_EXIT=7 STUB_MARKER="$MARKER_C"
run_launcher "$IID" >/dev/null 2>&1
JD="$(job_dir_for "$IID")"
JPID="$(cat "$JD/pid" 2>/dev/null || echo '')"
i=0
while kill -0 "$JPID" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.2
C="$(run_launcher "$IID" 2>/dev/null)"
if [ "$C" = "STATUS=error PID_ALIVE=0 RESULT=" ]; then
    pass "C: non-0/non-3 orchestrator exit reports STATUS=error"
else
    fail "C: error raw status on exit 7" "stdout=[$C]"
fi

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
if [ "$D" = "STATUS=running PID_ALIVE=0 RESULT=" ]; then
    pass "D: dead-pid + status=running reports PID_ALIVE=0 (no hang)"
else
    fail "D: dead-pid raw status" "stdout=[$D]"
fi
# The launcher no longer clears a dead-pid dir (#1356) — it just reports
# PID_ALIVE=0 and code_writer reads that as job-died and clears the dir. The
# launcher itself must LEAVE the forged dir intact.
if [ -d "$JD" ]; then
    pass "D: dead-pid job dir left intact (launcher never clears)"
else
    fail "D: dead-pid job dir intact" "missing: $JD"
fi

# ===========================================================================
# Scenario E (#1254): --decompose is forwarded to the orchestrator; a normal
# run omits it. The stub records its argv to a marker file.
# ===========================================================================
poll_done() {
    _jd="$1"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -f "$_jd/status" ] && grep -q "done" "$_jd/status" 2>/dev/null && return 0
        sleep 0.2
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
if [ -n "$UNCAP_PID" ]; then kill "$UNCAP_PID" 2>/dev/null || true; fi

# ===========================================================================
# Scenario G (#1349): --description is forwarded to the orchestrator verbatim,
# the same way --title/--decompose are relayed. The stub records its argv to a
# marker file (line "start ... args=[...]"). A run WITH --description must show
# the description text passed through; a run WITHOUT it must not add the flag.
# ===========================================================================
DESC_MARKER="$WORK/desc-marker"; : > "$DESC_MARKER"
DESC_TEXT="Threaded PR body: rewire the sprocket so the widget stops jamming."
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    STUB_SLEEP=0 STUB_EXIT=0 STUB_URL="https://example.test/pr/desc" STUB_MARKER="$DESC_MARKER" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 900 \
        --branch "fix/issue-900" --title "thread desc" \
        --description "$DESC_TEXT" --task "do it" >/dev/null 2>&1
poll_done "$(job_dir_for 900)" || true
if grep -q -- '--description' "$DESC_MARKER" 2>/dev/null && grep -qF "$DESC_TEXT" "$DESC_MARKER" 2>/dev/null; then
    pass "G: --description is forwarded to the orchestrator verbatim"
else
    fail "G: --description passthrough" "marker=$(cat "$DESC_MARKER" 2>/dev/null)"
fi

NODESC_MARKER="$WORK/nodesc-marker"; : > "$NODESC_MARKER"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    STUB_SLEEP=0 STUB_EXIT=0 STUB_URL="https://example.test/pr/nodesc" STUB_MARKER="$NODESC_MARKER" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 901 \
        --branch "fix/issue-901" --title "no desc" --task "do it" >/dev/null 2>&1
poll_done "$(job_dir_for 901)" || true
if grep -q -- '--description' "$NODESC_MARKER" 2>/dev/null; then
    fail "G: a run without --description wrongly forwarded it" "marker=$(cat "$NODESC_MARKER" 2>/dev/null)"
else
    pass "G: a run without --description does NOT forward the flag"
fi

# ===========================================================================
# #1354 step 2b: the caller-driven-loop launcher modes (--one-attempt surfaced
# as STATUS=attempt_done + tokens; --finalize as the ordinary done+url;
# --continuation copied into the job dir + forwarded).
# ===========================================================================
wait_terminal() {  # $1=jobdir — wait until a terminal status file settles
    local jd="$1" i
    for i in $(seq 1 60); do
        if [ -f "$jd/status" ]; then
            case "$(cat "$jd/status" 2>/dev/null)" in
                attempt_done|decomposed|done|no_edits|error) return 0 ;;
            esac
        fi
        sleep 0.1
    done
    return 1
}

# H: --one-attempt -> poll STATUS=attempt_done with re-keyed ATTEMPT_EXIT/CHURN/
#    VERIFY tokens spliced BEFORE RESULT (which stays last + empty).
H_MARKER="$WORK/h-marker"; : > "$H_MARKER"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    STUB_SLEEP=0 STUB_EXIT=0 STUB_CHURN=2 STUB_VERIFY=pass STUB_MARKER="$H_MARKER" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 950 \
        --branch "fix/issue-950" --title "attempt" --task "do it" --one-attempt >/dev/null 2>&1
wait_terminal "$(job_dir_for 950)" || true
H_POLL="$(env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 950 \
        --branch "fix/issue-950" --title "attempt" --task "do it" --one-attempt 2>/dev/null)"
if [ "$H_POLL" = "STATUS=attempt_done PID_ALIVE=0 ATTEMPT_EXIT=0 CHURN=2 VERIFY=pass RESULT=" ]; then
    pass "H (#1354): --one-attempt poll surfaces attempt_done + churn/verify tokens"
else
    fail "H (#1354): attempt_done poll tokens" "poll=[$H_POLL]"
fi
if grep -q -- '--one-attempt' "$H_MARKER"; then
    pass "H (#1354): launcher forwards --one-attempt to the orchestrator"
else
    fail "H (#1354): --one-attempt not forwarded" "marker=$(cat "$H_MARKER" 2>/dev/null)"
fi

# I: --finalize -> the ordinary done + PR URL surface (no attempt tokens).
I_MARKER="$WORK/i-marker"; : > "$I_MARKER"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    STUB_SLEEP=0 STUB_EXIT=0 STUB_URL="https://example.test/pr/fin" STUB_MARKER="$I_MARKER" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 951 \
        --branch "fix/issue-951" --title "fin" --task "do it" --finalize >/dev/null 2>&1
wait_terminal "$(job_dir_for 951)" || true
I_POLL="$(env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 951 \
        --branch "fix/issue-951" --title "fin" --task "do it" --finalize 2>/dev/null)"
if [ "$I_POLL" = "STATUS=done PID_ALIVE=0 RESULT=https://example.test/pr/fin" ]; then
    pass "I (#1354): --finalize surfaces the ordinary done + PR URL"
else
    fail "I (#1354): finalize done/url poll" "poll=[$I_POLL]"
fi
if grep -q -- '--finalize' "$I_MARKER"; then
    pass "I (#1354): launcher forwards --finalize to the orchestrator"
else
    fail "I (#1354): --finalize not forwarded" "marker=$(cat "$I_MARKER" 2>/dev/null)"
fi

# J: --continuation is copied into the job dir (surviving the caller's temp
#    lifecycle) and --reuse + --continuation are forwarded to the orchestrator.
J_MARKER="$WORK/j-marker"; : > "$J_MARKER"
J_CONT="$WORK/cont-952.txt"; printf 'CONTINUE-THE-EDIT-952' > "$J_CONT"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    STUB_SLEEP=0 STUB_EXIT=0 STUB_CHURN=3 STUB_VERIFY=fail STUB_MARKER="$J_MARKER" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 952 \
        --branch "fix/issue-952" --title "cont" --task "do it" \
        --one-attempt --reuse --continuation "$J_CONT" >/dev/null 2>&1
wait_terminal "$(job_dir_for 952)" || true
JD952="$(job_dir_for 952)"
if [ -f "$JD952/continuation" ] && grep -q 'CONTINUE-THE-EDIT-952' "$JD952/continuation" 2>/dev/null; then
    pass "J (#1354): --continuation copied into the job dir (survives caller temp)"
else
    fail "J (#1354): continuation copy" "present=$([ -f "$JD952/continuation" ] && echo yes || echo no)"
fi
if grep -q -- '--reuse' "$J_MARKER" && grep -q -- '--continuation' "$J_MARKER"; then
    pass "J (#1354): launcher forwards --reuse + --continuation to the orchestrator"
else
    fail "J (#1354): reuse/continuation not forwarded" "marker=$(cat "$J_MARKER" 2>/dev/null)"
fi

# K (#1422 M1): --decompose-only -> poll STATUS=decomposed with the re-keyed
# SUBTASKS token spliced BEFORE RESULT (which stays last + empty), and
# --decompose-only + --subtasks-out are forwarded to the orchestrator verbatim.
K_MARKER="$WORK/k-marker"; : > "$K_MARKER"
K_SUBOUT="$WORK/subtasks-953.txt"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    STUB_SLEEP=0 STUB_EXIT=0 STUB_SUBTASKS=4 STUB_MARKER="$K_MARKER" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 953 \
        --branch "fix/issue-953" --title "epic" --task "do it" \
        --decompose-only --subtasks-out "$K_SUBOUT" >/dev/null 2>&1
wait_terminal "$(job_dir_for 953)" || true
K_POLL="$(env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 953 \
        --branch "fix/issue-953" --title "epic" --task "do it" \
        --decompose-only --subtasks-out "$K_SUBOUT" 2>/dev/null)"
if [ "$K_POLL" = "STATUS=decomposed PID_ALIVE=0 SUBTASKS=4 RESULT=" ]; then
    pass "K (#1422 M1): --decompose-only poll surfaces STATUS=decomposed + SUBTASKS token"
else
    fail "K (#1422 M1): decomposed poll token" "poll=[$K_POLL]"
fi
if grep -q -- '--decompose-only' "$K_MARKER" && grep -q -- '--subtasks-out' "$K_MARKER"; then
    pass "K (#1422 M1): launcher forwards --decompose-only + --subtasks-out to the orchestrator"
else
    fail "K (#1422 M1): decompose-only/subtasks-out not forwarded" "marker=$(cat "$K_MARKER" 2>/dev/null)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
