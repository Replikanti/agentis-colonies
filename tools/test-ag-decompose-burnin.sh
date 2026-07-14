#!/usr/bin/env bash
# tools/test-ag-decompose-burnin.sh (#1537 merge-gate): a deterministic,
# offline reproduction of the three burn-in conditions the #1537 plan
# (issue comment) requires before the AG-driven decompose loop
# (code_writer.ag's ag_decompose_step, #1422/#1537 M3) can be trusted as the
# SOLE epic-editing path:
#
#   1. A real epic-labeled issue drives ag_decompose_step through N focused
#      per-subtask edits (NOT one monolithic drive) onto ONE branch -> exactly
#      ONE PR.
#   2. Subtasks >= 2 stay SCOPED (decomposition does not collapse back to
#      monolithic) AND subtask records extract correctly on the host
#      awk/shell mechanism.
#   3. Resume-after-tick-gap / daemon-restart mid-sequence lands on the RIGHT
#      subtask (no skip, no repeat, no early-finalize).
#
# The #1537 plan explicitly allows "a controlled fixture-PR reproduction ...
# in lieu of waiting for an organic epic" as burn-in evidence. This script IS
# that reproduction: a local bare git repo reached via a file:// remote (no
# network, no real GitHub), stub `flat-cyborg` + `github-api.sh` scripts
# standing in for the LLM and the forge, exactly like the established pattern
# in tools/test-code-edit-rebase.sh / tools/test-code-edit-ownership.sh.
#
# Two parts:
#
#   PART 1 (offline, no agentis needed — proves conditions 1 & 2): chains the
#   EXACT sequence of tools/code-edit-in-checkout.sh primitives
#   ag_decompose_step drives (--decompose-only, then --one-attempt /
#   --one-attempt --reuse per subtask, then --finalize) and asserts N
#   distinct, correctly-scoped edits land as staged changes that accumulate
#   on ONE workspace/branch and collapse into exactly ONE commit + ONE
#   create-mr call. This is the shell-primitive half of the .ag FSM
#   (tools/test-code-writer-decompose-ag.sh already source-asserts the .ag
#   side drives this exact sequence — see its invariants (a)-(h)); this test
#   is the runtime half, proving the primitives themselves behave as that FSM
#   assumes.
#
#   PART 2 (needs `agentis` on PATH — proves condition 3): runs the REAL
#   code_writer.ag under a REAL `agentis daemon` process against the same
#   local fixtures, drives it until subtask 1 of a 2-subtask epic completes,
#   SIGTERM/SIGKILLs the daemon (simulating a tick-gap / daemon restart),
#   relaunches it, and asserts the resumed daemon: (a) reads subtask_idx=2
#   back from the durable memo store (survives the kill), (b) does NOT
#   re-run the decomposition step, (c) does NOT repeat subtask 1's edit, (d)
#   DOES run subtask 2's edit exactly once, (e) finalizes into exactly ONE
#   commit/PR, and (f) never opens a second PR on later ticks (the terminal
#   has_mr_for_branch gate holds). This is the ONLY way to exercise
#   ag_decompose_step's own memo-keyed FSM logic (as opposed to the shell
#   primitives it drives) across a genuine process restart — Part 1 and the
#   structural test can't reach it, since neither runs the .ag file at all.
#   Skips (not fails) when `agentis` is not on PATH, matching every other
#   agentis-binary-gated test in this suite (colony-lint's CI baseline runs
#   with agentis absent).
#
# Auto-discovered by tools/colony-lint.sh's `find tools -name test-*.sh` loop
# (bash, [PASS]/[FAIL]/[SKIP] lines, `Results: N passed, M failed` trailer).
# Exit 0 all-pass-or-skip, 1 any-fail. Related: #1537, #1422, #1254.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
ORCH="$REPO_ROOT/tools/code-edit-in-checkout.sh"
AG_FILE="$REPO_ROOT/dev-apprenticeship/implementation/agents/code_writer.ag"

PASS=0; FAIL=0; SKIP=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; SKIP=$((SKIP + 1)); }

if ! command -v git >/dev/null 2>&1; then
    echo "[SKIP] test-ag-decompose-burnin.sh: git not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi
if [ ! -f "$ORCH" ]; then
    fail "tool missing" "orch=$ORCH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
if [ ! -f "$AG_FILE" ]; then
    fail "agent missing" "ag=$AG_FILE"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

FAKE_TOKEN="ghp_FAKE_TOKEN_DO_NOT_LEAK_abcdef0123456789"
export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

# seed_remote: fresh bare remote (file:// "GitHub") with a main branch.
seed_remote() {
    _bare="$1"; _seed="$2"
    rm -rf "$_bare" "$_seed"
    mkdir -p "$_bare"
    git init --quiet --bare --initial-branch=main "$_bare" 2>/dev/null || git init --quiet --bare "$_bare"
    git init --quiet --initial-branch=main "$_seed" 2>/dev/null || git init --quiet "$_seed"
    (
        cd "$_seed" || exit 1
        git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
        printf 'hello\n' > README.md
        git add -A
        git commit --quiet -m "seed: initial commit"
        git branch -M main 2>/dev/null || true
        git remote add origin "$_bare"
        git push --quiet origin main
    )
}

# install_fc_stub <stub_bin_dir> <fc_log> <fc_class_log> <marker1> <marker2>:
# a flat-cyborg stub covering BOTH call shapes code-edit-in-checkout.sh makes:
#   - the decomposition drive (--cwd + a --cmd-file asking it to write an
#     ordered subtask list to a named output file) -> writes two FIXED,
#     distinctly-marked subtask lines;
#   - a per-subtask edit drive (--cwd + a --cmd-file carrying the subtask
#     text) -> writes a marker-specific file into --cwd, so which subtask
#     text reached the edit step is directly observable on disk.
install_fc_stub() {
    _bin="$1"; _fc_log="$2"; _fc_class="$3"; _m1="$4"; _m2="$5"
    cat > "$_bin/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf 'call: %s\n' "\$*" >> "$_fc_log"
CWD=""
CMDFILE=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --cwd) CWD="\$2"; shift 2 ;;
        --cmd-file) CMDFILE="\$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
if [ -n "\$CMDFILE" ] && [ -f "\$CMDFILE" ]; then
    if grep -qF 'Write ONLY the list to this exact file with your file-writing tool:' "\$CMDFILE"; then
        OUTFILE="\$(grep -o 'Write ONLY the list to this exact file with your file-writing tool: [^ ]*' "\$CMDFILE" | sed 's/^.*tool: //')"
        printf 'Implement %s: create file one.txt\n' "$_m1" > "\$OUTFILE"
        printf 'Implement %s: create file two.txt\n' "$_m2" >> "\$OUTFILE"
        echo "DECOMPOSE_CALL" >> "$_fc_class"
        exit 0
    fi
    if [ -n "\$CWD" ]; then
        if grep -qF "$_m1" "\$CMDFILE"; then
            printf 'subtask one done\n' > "\$CWD/one.txt"
            echo "EDIT_CALL:one" >> "$_fc_class"
        elif grep -qF "$_m2" "\$CMDFILE"; then
            printf 'subtask two done\n' > "\$CWD/two.txt"
            echo "EDIT_CALL:two" >> "$_fc_class"
        else
            echo "EDIT_CALL:unknown" >> "$_fc_class"
        fi
    fi
fi
exit 0
STUB_EOF
    chmod +x "$_bin/flat-cyborg"
}

# read_subtask_n <subtasks_file> <n>: byte-identical to code_writer.ag's own
# read_subtask() extraction (bash `read -r -d ""` over the NUL-delimited
# records) — see tools/test-code-writer-decompose-ag.sh finding 2 for the
# portability rationale (no gawk-specific RS="\0").
read_subtask_n() {
    n="$2" f="$1" bash -c 'i=0; while IFS= read -r -d "" rec; do i=$((i+1)); if [ "$i" = "$n" ]; then printf "%s" "$rec"; break; fi; done < "$f"'
}

# =============================================================================
# PART 1 (offline): conditions 1 & 2 via the exact primitive sequence
# ag_decompose_step drives — --decompose-only, then --one-attempt per subtask
# (force_reuse = i>1, mirroring the .ag's `let force_reuse = i > 1;`), then
# --finalize.
# =============================================================================
P1_WORK="$(mktemp -d)"
trap 'rm -rf "$P1_WORK"' EXIT

OWNER="acme"; REPO="widget"; IID=901
REMOTE_BASE="$P1_WORK/remote"
BARE="$REMOTE_BASE/$OWNER/$REPO.git"
SEED="$P1_WORK/seed"
FED_DIR="$P1_WORK/fed"
COLONY_DIR="$FED_DIR/implementation"
STUB_BIN="$P1_WORK/bin"
mkdir -p "$STUB_BIN" "$COLONY_DIR/scripts"

seed_remote "$BARE" "$SEED"

CREATE_MR_LOG="$P1_WORK/create-mr.log"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
verb="\${1:-}"
case "\$verb" in
    create-mr)
        { echo "create-mr called with: \$*"; } >> "$CREATE_MR_LOG"
        printf '%s\n' '{"html_url": "https://example.test/pr/OK"}'
        ;;
    *)
        printf '%s\n' '{}'
        ;;
esac
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

MARK1="SUBTASK_MARKER_ONE_qz8"
MARK2="SUBTASK_MARKER_TWO_qz8"
FC_LOG="$P1_WORK/fc-flags.log"
FC_CLASS="$P1_WORK/fc-classified.log"
install_fc_stub "$STUB_BIN" "$FC_LOG" "$FC_CLASS" "$MARK1" "$MARK2"

export PATH="$STUB_BIN:$PATH"

COMMONENV=(
    COLONY_DIR="$COLONY_DIR"
    GITHUB_URL="file://$REMOTE_BASE"
    GITHUB_TOKEN="$FAKE_TOKEN"
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO"
    CODE_EDIT_VERIFY_CMD="true"
    PATH="$STUB_BIN:$PATH"
)

BRANCH="fix/issue-$IID"
TASK_TEXT="Epic: implement two things.
Sub-part A: $MARK1
Sub-part B: $MARK2"

SUBTASKS_OUT="$P1_WORK/subtasks-$IID.txt"
OUT1="$P1_WORK/out1.txt"
env "${COMMONENV[@]}" bash "$ORCH" \
    --owner "$OWNER" --repo "$REPO" --issue "$IID" \
    --branch "$BRANCH" --title "feat: epic $IID" --task "$TASK_TEXT" \
    --decompose-only --subtasks-out "$SUBTASKS_OUT" >"$OUT1" 2>"$P1_WORK/err1.txt"
RC1=$?
if [ "$RC1" -eq 0 ] && grep -q '^DECOMPOSED count=2$' "$OUT1"; then
    pass "part1/condition1: --decompose-only exit 0, DECOMPOSED count=2 (real decomposition, not a single monolithic subtask)"
else
    fail "part1/condition1: decompose-only" "rc=$RC1 out=$(cat "$OUT1") err=$(tail -5 "$P1_WORK/err1.txt")"
fi
NUL_RECS="$(tr -cd '\0' < "$SUBTASKS_OUT" | wc -c | tr -d ' ')"
if [ "$NUL_RECS" = "2" ]; then
    pass "part1/condition2: 2 NUL-delimited subtask records written"
else
    fail "part1/condition2: expected 2 NUL records" "got $NUL_RECS"
fi

SUB1="$(read_subtask_n "$SUBTASKS_OUT" 1)"
SUB2="$(read_subtask_n "$SUBTASKS_OUT" 2)"
if [ -n "$SUB1" ] && [ -n "$SUB2" ] && [ "$SUB1" != "$SUB2" ] && printf '%s' "$SUB1" | grep -qF "$MARK1" && printf '%s' "$SUB2" | grep -qF "$MARK2"; then
    pass "part1/condition2: subtask records extract correctly on host awk/shell (distinct, correctly-scoped markers)"
else
    fail "part1/condition2: subtask extraction" "sub1=[$SUB1] sub2=[$SUB2]"
fi

OUT2="$P1_WORK/out2.txt"
env "${COMMONENV[@]}" bash "$ORCH" \
    --owner "$OWNER" --repo "$REPO" --issue "$IID" \
    --branch "$BRANCH" --title "feat: epic $IID" --task "$SUB1" \
    --one-attempt >"$OUT2" 2>"$P1_WORK/err2.txt"
RC2=$?
WS="$FED_DIR/.agentis/workspaces/implementation/$OWNER-$REPO/issue-$IID"
STAGED1="$(git -C "$WS" diff --cached --name-only 2>/dev/null | sort | tr '\n' ',')"
if [ "$RC2" -eq 0 ] && [ "$STAGED1" = "one.txt," ]; then
    pass "part1/condition1+2: subtask 1 --one-attempt staged EXACTLY one.txt (a FOCUSED per-subtask edit, not monolithic, not leaking subtask 2)"
else
    fail "part1: subtask 1 scoping" "rc=$RC2 staged=[$STAGED1] out=$(cat "$OUT2")"
fi

OUT3="$P1_WORK/out3.txt"
env "${COMMONENV[@]}" bash "$ORCH" \
    --owner "$OWNER" --repo "$REPO" --issue "$IID" \
    --branch "$BRANCH" --title "feat: epic $IID" --task "$SUB2" \
    --one-attempt --reuse >"$OUT3" 2>"$P1_WORK/err3.txt"
RC3=$?
STAGED2="$(git -C "$WS" diff --cached --name-only 2>/dev/null | sort | tr '\n' ',')"
if [ "$RC3" -eq 0 ] && [ "$STAGED2" = "one.txt,two.txt," ]; then
    pass "part1/condition2: subtask 2 --one-attempt --reuse ACCUMULATED on the SAME branch/workspace (one.txt kept, two.txt added — decomposition did not collapse)"
else
    fail "part1: subtask 2 accumulation" "rc=$RC3 staged=[$STAGED2] out=$(cat "$OUT3")"
fi

OUT4="$P1_WORK/out4.txt"
env "${COMMONENV[@]}" bash "$ORCH" \
    --owner "$OWNER" --repo "$REPO" --issue "$IID" \
    --branch "$BRANCH" --title "feat: epic $IID" --task "$TASK_TEXT" \
    --description "Two-part epic implementation." \
    --finalize >"$OUT4" 2>"$P1_WORK/err4.txt"
RC4=$?
PR_URL="$(tail -1 "$OUT4")"
if [ "$RC4" -eq 0 ] && [ "$PR_URL" = "https://example.test/pr/OK" ]; then
    pass "part1/condition1: --finalize exit 0, PR URL printed"
else
    fail "part1: finalize" "rc=$RC4 out=$(cat "$OUT4") err=$(tail -8 "$P1_WORK/err4.txt")"
fi
MR_CALLS="$( [ -f "$CREATE_MR_LOG" ] && grep -c '^create-mr called with:' "$CREATE_MR_LOG" || echo 0)"
if [ "$MR_CALLS" -eq 1 ]; then
    pass "part1/condition1: create-mr called EXACTLY ONCE (N edits -> ONE PR, not N)"
else
    fail "part1/condition1: exactly one create-mr call" "count=$MR_CALLS"
fi
COMMITS="$(git --git-dir="$BARE" log --oneline "refs/heads/$BRANCH" 2>/dev/null | wc -l | tr -d ' ')"
COMMIT_FILES="$(git --git-dir="$BARE" show --name-only --format= "refs/heads/$BRANCH" 2>/dev/null | sort | tr '\n' ',')"
if [ "$COMMITS" = "2" ] && [ "$COMMIT_FILES" = "one.txt,two.txt," ]; then
    pass "part1/condition1: exactly ONE new commit on the branch (2 total incl. seed), touching BOTH subtask files"
else
    fail "part1: one commit with both files" "commits=$COMMITS files=[$COMMIT_FILES]"
fi

rm -rf "$P1_WORK"
trap - EXIT

# =============================================================================
# PART 2 (needs agentis): condition 3 via a real `agentis daemon` process
# driving the ACTUAL code_writer.ag, killed and restarted mid-sequence.
# =============================================================================
if ! command -v agentis >/dev/null 2>&1; then
    skip "part2/condition3: agentis not on PATH — live-daemon resume-after-restart burn-in not run (condition 3 unproven in this environment; see #1537 plan for the organic-epic / operator-run alternative)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    [ "$FAIL" -eq 0 ]
    exit $?
fi

P2_WORK="$(mktemp -d)"
DAEMON_PID=""
cleanup2() {
    [ -n "$DAEMON_PID" ] && kill -KILL "$DAEMON_PID" 2>/dev/null || true
    rm -rf "$P2_WORK"
}
trap cleanup2 EXIT

OWNER2="acme"; REPO2="widget"; IID2=701
EPIC_UPDATED_AT="2026-01-01T00:00:00Z"
REMOTE_BASE2="$P2_WORK/remote"
BARE2="$REMOTE_BASE2/$OWNER2/$REPO2.git"
SEED2="$P2_WORK/seed"
FED_DIR2="$P2_WORK/fed"
COLONY_DIR2="$FED_DIR2/implementation"
STUB_BIN2="$P2_WORK/bin"
mkdir -p "$STUB_BIN2" "$COLONY_DIR2/scripts"

# tools symlink so `$COLONY_DIR/../../tools/...` (the path code_writer.ag's
# exec-sh calls compose) resolves to the REAL tools under test.
ln -s "$REPO_ROOT/tools" "$P2_WORK/tools"

seed_remote "$BARE2" "$SEED2"

cp "$REPO_ROOT/dev-apprenticeship/implementation/scripts/forge-api.sh" "$COLONY_DIR2/scripts/forge-api.sh"
chmod +x "$COLONY_DIR2/scripts/forge-api.sh"

CREATE_MR_LOG2="$P2_WORK/create-mr.log"
ADD_NOTE_LOG2="$P2_WORK/add-note.log"
MR_OPEN_FLAG="$P2_WORK/mr-open-$IID2"
cat > "$COLONY_DIR2/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
verb="\${1:-}"
case "\$verb" in
    merge-requests)
        # Reflects reality once create-mr has fired: has_mr_for_branch() (and
        # the recovery sweeps) query this to detect an existing PR. Without
        # this the fixture would loop code_writer into re-decomposing and
        # opening a SECOND PR every tick forever -- a fixture gap, not the
        # thing under test. A real forge shows the PR here immediately.
        if [ -f "$MR_OPEN_FLAG" ]; then
            printf '%s\n' '[{"iid":$IID2,"source_branch":"fix/issue-$IID2"}]'
        else
            printf '%s\n' '[]'
        fi
        ;;
    assigned-issues)
        printf '%s\n' '[{"iid":$IID2,"updated_at":"$EPIC_UPDATED_AT","labels":["epic"]}]'
        ;;
    issue)
        printf '%s\n' '{"iid":$IID2,"title":"Epic: two-part fixture","body":"Epic body.","labels":["epic"],"updated_at":"$EPIC_UPDATED_AT"}'
        ;;
    add-note|post-note)
        { echo "\$verb called with: \$*"; } >> "$ADD_NOTE_LOG2"
        printf '%s\n' '{"id": 1}'
        ;;
    create-mr)
        { echo "create-mr called with: \$*"; } >> "$CREATE_MR_LOG2"
        touch "$MR_OPEN_FLAG"
        printf '%s\n' '{"html_url": "https://example.test/pr/$IID2"}'
        ;;
    *)
        printf '%s\n' '[]'
        ;;
esac
STUB_EOF
chmod +x "$COLONY_DIR2/scripts/github-api.sh"

MARK1_2="SUBTASK_MARKER_ONE_qz8"
MARK2_2="SUBTASK_MARKER_TWO_qz8"
FC_LOG2="$P2_WORK/fc-calls.log"
FC_CLASS2="$P2_WORK/fc-classified.log"
install_fc_stub "$STUB_BIN2" "$FC_LOG2" "$FC_CLASS2" "$MARK1_2" "$MARK2_2"

# The reasoning stub is code_writer.ag's `llm.command` (the draft prompt() —
# a SEPARATE mechanism from the flat-cyborg editing calls above, invoked
# directly by the agentis runtime, not via exec sh).
cat > "$STUB_BIN2/reasoning-stub.sh" <<STUB_EOF
#!/usr/bin/env sh
PROMPT="\${1:-}"
if [ -z "\$PROMPT" ]; then PROMPT="\$(cat)"; fi
case "\$PROMPT" in
    *"You are a code writer agent"*)
        printf '%s' '{"issue_id": $IID2, "branch_name": "fix/issue-$IID2", "title": "feat: epic $IID2", "files": "- one.txt\n- two.txt", "summary": "Implements the two-part epic.", "confidence": 0.97}'
        ;;
    *)
        printf '%s' '{}'
        ;;
esac
STUB_EOF
chmod +x "$STUB_BIN2/reasoning-stub.sh"

export PATH="$STUB_BIN2:$PATH"

( cd "$FED_DIR2" && agentis init ) >"$P2_WORK/init.log" 2>&1
# exec.env_passthrough value mirrors dev-apprenticeship/install.sh's current
# fresh-install write (the allowlist gating both getenv() reads AND the env
# visible to exec-sh-spawned shells, per CLAUDE.md's LLM-backend section) --
# COLONY_DIR/FORGE_TYPE/GITHUB_* are the load-bearing subset for this fixture.
cat > "$FED_DIR2/.agentis/config" <<CFG
llm.backend = claude
llm.command = $STUB_BIN2/reasoning-stub.sh
llm.args =
trace.level = normal
learning.enabled = true
experience.enabled = true
knowledge.enabled = true
exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT,LABELER_RULE_FIRST,LABELER_RULE_CONFIDENCE,ROUTER_RULE_FIRST,ROUTER_RULE_CONFIDENCE,LABELER_BM25_RECALL,ROUTER_BM25_RECALL,TRIAGE_BM25_K,PRIORITIZER_RULE_FIRST,PRIORITIZER_RULE_CONFIDENCE,PRIORITIZER_BM25_RECALL,QA_ADVERSARIAL_LLM_CMD,CODE_EDIT_MAX_ATTEMPTS,MERGE_REVIEW_TIMEOUT_S,MERGE_REVIEW_TIMEOUT_ACTION,CODE_EDIT_TIMEOUT_MS,CODE_EDIT_TOTAL_BUDGET_MS,CODE_EDIT_VERIFY_CMD,CODE_EDIT_VERIFY_TIMEOUT_MS,CODE_EDIT_MAX_SUBTASKS,CODE_EDIT_MODEL,CODE_EDIT_EFFORT,AG_DECOMPOSE_LOOP,QA_FIX_RECOVERY_ENABLED
CFG

( cd "$FED_DIR2" && agentis memo set code_writer:confidence 0.97 ) >/dev/null
( cd "$FED_DIR2" && agentis memo set code_writer:require_assignee false ) >/dev/null

DAEMON_ENV=(
    COLONY_DIR="$COLONY_DIR2"
    GITHUB_URL="file://$REMOTE_BASE2"
    GITHUB_TOKEN="$FAKE_TOKEN"
    GITHUB_OWNER="$OWNER2" GITHUB_REPO="$REPO2" GITHUB_ME="bot"
    FORGE_TYPE="github"
    CODE_EDIT_VERIFY_CMD="true"
    PATH="$STUB_BIN2:$PATH"
)

WS2="$FED_DIR2/.agentis/workspaces/implementation/$OWNER2-$REPO2/issue-$IID2"

wait_for() {
    # wait_for <description> <timeout_s> <check_cmd...>
    _desc="$1"; _timeout="$2"; shift 2
    _n=0
    while [ "$_n" -lt "$_timeout" ]; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
        _n=$((_n + 1))
    done
    echo "  [timeout] waiting for: $_desc (waited ${_timeout}s)" >&2
    return 1
}

( cd "$FED_DIR2" && env "${DAEMON_ENV[@]}" agentis daemon "$AG_FILE" \
    --colony implementation --enable-exec --enable-messaging \
    --tick-interval 400 --cb-per-tick 8000 --prompt-timeout-s 30 \
    </dev/null >"$P2_WORK/daemon1.log" 2>&1 ) &
DAEMON_PID=$!
sleep 1
if kill -0 "$DAEMON_PID" 2>/dev/null; then
    pass "part2: live agentis daemon (run 1) launched against code_writer.ag"
else
    fail "part2: daemon run 1 launched" "log tail: $(tail -20 "$P2_WORK/daemon1.log")"
fi

if wait_for "subtask 1 done (one.txt staged, subtask_idx=2)" 60 bash -c "
    [ -f '$WS2/one.txt' ] && [ ! -f '$WS2/two.txt' ] &&
    [ \"\$(cd '$FED_DIR2' && agentis memo get code_edit_loop:subtask_idx:$IID2 2>/dev/null)\" = '2' ]
"; then
    pass "part2/condition3 setup: subtask 1 completed live (one.txt staged, two.txt absent, subtask_idx advanced to 2)"
else
    fail "part2/condition3 setup: subtask 1 completion" "daemon1.log tail: $(tail -40 "$P2_WORK/daemon1.log")"
fi

kill -TERM "$DAEMON_PID" 2>/dev/null || true
_n=0
while kill -0 "$DAEMON_PID" 2>/dev/null && [ "$_n" -lt 10 ]; do sleep 1; _n=$((_n + 1)); done
kill -KILL "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null
DAEMON_PID=""
pass "part2/condition3: daemon run 1 killed (simulating a tick-gap / daemon restart mid-sequence)"

IDX_AFTER_KILL="$(cd "$FED_DIR2" && agentis memo get code_edit_loop:subtask_idx:$IID2 2>/dev/null)"
if [ "$IDX_AFTER_KILL" = "2" ]; then
    pass "part2/condition3: subtask-index memo state SURVIVED the kill (durable store, not in-process only): subtask_idx=2"
else
    fail "part2/condition3: memo state survived the kill" "subtask_idx=[$IDX_AFTER_KILL]"
fi

( cd "$FED_DIR2" && env "${DAEMON_ENV[@]}" agentis daemon "$AG_FILE" \
    --colony implementation --enable-exec --enable-messaging \
    --tick-interval 400 --cb-per-tick 8000 --prompt-timeout-s 30 \
    </dev/null >"$P2_WORK/daemon2.log" 2>&1 ) &
DAEMON_PID=$!
sleep 1
if kill -0 "$DAEMON_PID" 2>/dev/null; then
    pass "part2/condition3: daemon run 2 (the 'restart') launched"
else
    fail "part2/condition3: daemon run 2 launched" "log tail: $(tail -20 "$P2_WORK/daemon2.log")"
fi

if wait_for "PR opened (create-mr called) after resume" 60 bash -c "[ -f '$CREATE_MR_LOG2' ]"; then
    pass "part2/condition3: daemon run 2 reached finalize and opened the PR after resume"
else
    fail "part2/condition3: PR opened after resume" "daemon2.log tail: $(tail -60 "$P2_WORK/daemon2.log")"
fi

# Settle window: prove the PR-open state is TERMINAL (has_mr_for_branch now
# sees the PR via the merge-requests stub) -- no re-decompose / second PR on
# later ticks.
sleep 4

MR_CALLS2="$( [ -f "$CREATE_MR_LOG2" ] && grep -c '^create-mr called with:' "$CREATE_MR_LOG2" || echo 0)"
if [ "$MR_CALLS2" -eq 1 ]; then
    pass "part2/condition3: create-mr called EXACTLY ONCE across both daemon runs + settle window (no double-PR after resume)"
else
    fail "part2/condition3: exactly one create-mr call across restart" "count=$MR_CALLS2"
fi

DECOMPOSE_CALLS="$( [ -f "$FC_CLASS2" ] && grep -c '^DECOMPOSE_CALL$' "$FC_CLASS2" || echo 0)"
EDIT_ONE_CALLS="$( [ -f "$FC_CLASS2" ] && grep -c '^EDIT_CALL:one$' "$FC_CLASS2" || echo 0)"
EDIT_TWO_CALLS="$( [ -f "$FC_CLASS2" ] && grep -c '^EDIT_CALL:two$' "$FC_CLASS2" || echo 0)"
if [ "$DECOMPOSE_CALLS" -eq 1 ]; then
    pass "part2/condition3: decomposition ran EXACTLY ONCE (the restart did NOT re-decompose from scratch)"
else
    fail "part2/condition3: exactly one decompose call across restart" "count=$DECOMPOSE_CALLS log=$(cat "$FC_CLASS2" 2>/dev/null)"
fi
if [ "$EDIT_ONE_CALLS" -eq 1 ] && [ "$EDIT_TWO_CALLS" -eq 1 ]; then
    pass "part2/condition3: subtask 1 ran EXACTLY ONCE (no repeat) AND subtask 2 ran EXACTLY ONCE (no skip) -- resume landed on the correct subtask"
else
    fail "part2/condition3: no-repeat/no-skip on resume" "edit_one=$EDIT_ONE_CALLS edit_two=$EDIT_TWO_CALLS log=$(cat "$FC_CLASS2" 2>/dev/null)"
fi

COMMITS2="$(git --git-dir="$BARE2" log --oneline "refs/heads/fix/issue-$IID2" 2>/dev/null | wc -l | tr -d ' ')"
COMMIT_FILES2="$(git --git-dir="$BARE2" show --name-only --format= "refs/heads/fix/issue-$IID2" 2>/dev/null | sort | tr '\n' ',')"
if [ "$COMMITS2" = "2" ] && [ "$COMMIT_FILES2" = "one.txt,two.txt," ]; then
    pass "part2/condition3: final commit contains BOTH subtask files (subtask 1 not lost across the restart, subtask 2 not skipped)"
else
    fail "part2/condition3: final commit content" "commits=$COMMITS2 files=[$COMMIT_FILES2]"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
