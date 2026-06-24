#!/usr/bin/env bash
# test-code-edit-recover.sh (#1332): exercise the --recover mode of
# tools/code-edit-in-checkout.sh AND the --recover passthrough +
# retry-cap-adjacent behaviour of tools/code-edit-job.sh, WITHOUT a real Claude
# Code session. The claude-edit step is a STUB flat-cyborg on PATH; the "remote"
# is a local bare git repo reached via a file:// GITHUB_URL.
#
# --recover re-drives an EXISTING red PR's branch: it checks OUT the existing
# remote head branch (which already carries the prior commit), forces the verify
# gate ON, drives the verify-and-fix loop, and on a new commit PUSHES the branch
# ONLY — it NEVER opens a second PR (the PR already exists).
#
# Asserts (orchestrator, code-edit-in-checkout.sh):
#   R1. recover checks out the EXISTING branch (the prior commit's file survives
#       in the pushed tip) — i.e. it did NOT cut a fresh branch off main.
#   R2. the fix is committed on top + pushed; exit 0; stdout = RECOVERED <branch>
#   R3. create-mr is NEVER invoked in recover mode (no second PR)
#   R4. the verify gate RAN (forced ON even with CODE_EDIT_VERIFY_CMD=true)
#   R5. a no-edit recover run ⇒ exit 3 (NO_EDITS), no new commit pushed
#
# Asserts (launcher, code-edit-job.sh):
#   J1. --recover is forwarded to the orchestrator (stub records its argv)
#   J2. a normal run does NOT forward --recover
#
# Auto-discovered by tools/colony-lint.sh's tools-test loop. Exit 0 if all pass.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
ORCH="$REPO_ROOT/tools/code-edit-in-checkout.sh"
LAUNCHER="$REPO_ROOT/tools/code-edit-job.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if ! command -v git >/dev/null 2>&1; then
    echo "[SKIP] test-code-edit-recover.sh: git not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] test-code-edit-recover.sh: python3 not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi
if [ ! -f "$ORCH" ] || [ ! -f "$LAUNCHER" ]; then
    fail "tool missing" "orch=$ORCH launcher=$LAUNCHER"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_TOKEN="ghp_FAKE_TOKEN_DO_NOT_LEAK_abcdef0123456789"
OWNER="acme"
REPO="widget"

export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

REMOTE_BASE="$WORK/remote"
BARE="$REMOTE_BASE/$OWNER/$REPO.git"
SEED="$WORK/seed"

FED_DIR="$WORK/fed"
COLONY_DIR="$FED_DIR/implementation"

CREATE_MR_LOG="$WORK/create-mr.log"
FC_FLAGS_LOG="$WORK/fc-flags.log"

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"

# seed_remote: fresh bare remote with main + a `fix/issue-<iid>` branch that
# already carries a PRIOR commit (the red-on-CI commit recovery builds on top of).
# $1 = issue iid, $2 = prior-commit filename.
seed_remote() {
    local iid="$1" prior="$2"
    rm -rf "$BARE" "$SEED"
    mkdir -p "$BARE"
    git init --quiet --bare --initial-branch=main "$BARE" 2>/dev/null || git init --quiet --bare "$BARE"
    git init --quiet --initial-branch=main "$SEED" 2>/dev/null || git init --quiet "$SEED"
    (
        cd "$SEED" || exit 1
        git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
        printf 'hello\n' > README.md
        git add -A
        git commit --quiet -m "seed: initial commit"
        git branch -M main 2>/dev/null || true
        git remote add origin "$BARE"
        git push --quiet origin main
        # The existing red PR branch with a prior commit.
        git checkout --quiet -b "fix/issue-$iid"
        printf 'prior change\n' > "$prior"
        git add -A
        git commit --quiet -m "fix: prior work (#$iid)"
        git push --quiet origin "fix/issue-$iid"
    )
    git --git-dir="$BARE" symbolic-ref HEAD refs/heads/main
}

# install_create_mr_stub: a github-api.sh stub that RECORDS any create-mr call
# (so we can assert recover mode never opens a PR) and echoes canned JSON.
install_create_mr_stub() {
    mkdir -p "$COLONY_DIR/scripts"
    cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called with: \$*"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/SHOULD-NOT-OPEN"}'
STUB_EOF
    chmod +x "$COLONY_DIR/scripts/github-api.sh"
}

# install_fc_stub: flat-cyborg stub. FC_STUB_MODE=edit writes $FC_FIX_FILE into
# --cwd (simulate the recovery fix); no-edit touches nothing. Records its flags.
install_fc_stub() {
    cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
CWD=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --cwd) CWD="\$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
if [ "\${FC_STUB_MODE:-edit}" = "edit" ] && [ -n "\$CWD" ]; then
    printf 'recovery fix\n' > "\$CWD/\${FC_FIX_FILE:-FIX.txt}"
fi
exit "\${FC_STUB_RC:-0}"
STUB_EOF
    chmod +x "$STUB_BIN/flat-cyborg"
}

export PATH="$STUB_BIN:$PATH"

# ===========================================================================
# R1-R4: recover mode builds on the existing branch, pushes the fix, opens NO
# PR, runs the gate. CODE_EDIT_VERIFY_CMD=true would normally SKIP the gate;
# recover must force it ON anyway.
# ===========================================================================
IID=50
PRIOR="PRIOR_50.txt"
FIXFILE="FIX_50.txt"
rm -f "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
seed_remote "$IID" "$PRIOR"
install_create_mr_stub
install_fc_stub

OUTR_FILE="$WORK/outR.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE="edit" FC_FIX_FILE="$FIXFILE" \
    CODE_EDIT_VERIFY_CMD="true" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue "$IID" \
        --branch "fix/issue-$IID" --title "fix: recover CI for #$IID" \
        --task "Reproduce and fix the CI failure." --recover >"$OUTR_FILE" 2>"$WORK/errR.txt"
RCR=$?
OUTR="$(cat "$OUTR_FILE")"

if [ "$RCR" -eq 0 ]; then
    pass "R2: recover exits 0 after pushing a fix"
else
    fail "R2: recover exit 0" "rc=$RCR err=$(tail -5 "$WORK/errR.txt")"
fi
case "$OUTR" in
    "RECOVERED fix/issue-$IID") pass "R2: prints RECOVERED <branch> on stdout (no PR URL)" ;;
    *) fail "R2: RECOVERED <branch> on stdout" "stdout=[$OUTR]" ;;
esac

# R1: the pushed branch tip carries BOTH the prior commit's file AND the new fix
# — proving recover checked out the EXISTING branch, not a fresh one off main.
if git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-$IID:$PRIOR" 2>/dev/null \
   && git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-$IID:$FIXFILE" 2>/dev/null; then
    pass "R1: pushed tip has the prior commit's file + the fix (built on the EXISTING branch)"
else
    fail "R1: existing branch + fix in pushed commit"
fi

# R3: create-mr must NEVER fire in recover mode.
if [ ! -f "$CREATE_MR_LOG" ]; then
    pass "R3: recover NEVER invoked create-mr (no second PR opened)"
else
    fail "R3: create-mr must NOT be invoked in recover mode" "log=$(cat "$CREATE_MR_LOG")"
fi

# R4: the verify gate ran even though CODE_EDIT_VERIFY_CMD=true would skip it.
if grep -q "verify gate forced ON" "$WORK/errR.txt" 2>/dev/null; then
    pass "R4: verify gate forced ON in recover mode (CODE_EDIT_VERIFY_CMD=true did NOT skip it)"
else
    fail "R4: gate forced ON" "err=$(tail -8 "$WORK/errR.txt" 2>/dev/null)"
fi

# Recover does NOT use checkout -B off the default branch — it checks out the
# existing origin/<branch>. Assert the orchestrator referenced origin/<branch>.
if grep -q "recover mode" "$WORK/errR.txt" 2>/dev/null; then
    pass "R1b: recover took the existing-branch checkout path (logged 'recover mode')"
else
    fail "R1b: recover-mode log line" "err=$(tail -8 "$WORK/errR.txt" 2>/dev/null)"
fi

# ===========================================================================
# R5: a no-edit recover run ⇒ exit 3 (NO_EDITS), no NEW commit pushed (the
# branch tip stays at the prior commit).
# ===========================================================================
IID=51
PRIOR="PRIOR_51.txt"
rm -f "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
seed_remote "$IID" "$PRIOR"
install_create_mr_stub
install_fc_stub
PRIOR_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"

OUTR5_FILE="$WORK/outR5.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE="no-edit" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue "$IID" \
        --branch "fix/issue-$IID" --title "fix: recover CI for #$IID" \
        --task "Reproduce and fix the CI failure." --recover >"$OUTR5_FILE" 2>"$WORK/errR5.txt"
RCR5=$?

if [ "$RCR5" -eq 3 ] && grep -q '^NO_EDITS$' "$OUTR5_FILE"; then
    pass "R5: no-edit recover ⇒ exit 3 (NO_EDITS)"
else
    fail "R5: NO_EDITS exit 3" "rc=$RCR5 stdout=[$(cat "$OUTR5_FILE")]"
fi
NEW_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
if [ "$NEW_TIP" = "$PRIOR_TIP" ]; then
    pass "R5: no new commit pushed (branch tip unchanged on a no-edit recover)"
else
    fail "R5: branch tip must be unchanged" "prior=$PRIOR_TIP new=$NEW_TIP"
fi
if [ ! -f "$CREATE_MR_LOG" ]; then
    pass "R5: no-edit recover opened no PR"
else
    fail "R5: create-mr must NOT fire on no-edit recover" "log=$(cat "$CREATE_MR_LOG")"
fi

# ===========================================================================
# J1 / J2: code-edit-job.sh forwards --recover (and a normal run does not). The
# slow orchestrator is replaced by a stub pointed at via CODE_EDIT_ORCH that
# records its argv.
# ===========================================================================
STUB_ORCH="$WORK/stub-orch.sh"
cat > "$STUB_ORCH" <<'STUB_EOF'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_MARKER:-}" ]; then echo "args=[$*]" >> "$STUB_MARKER"; fi
printf '%s\n' "RECOVERED fix/issue-${STUB_IID:-0}"
exit 0
STUB_EOF
chmod +x "$STUB_ORCH"

job_dir_for() { echo "$FED_DIR/.agentis/jobs/implementation/issue-$1"; }
poll_done() {
    _jd="$1"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -f "$_jd/status" ] && grep -q "done" "$_jd/status" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

REC_MARKER="$WORK/rec-marker"; : > "$REC_MARKER"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB_ORCH" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    STUB_MARKER="$REC_MARKER" STUB_IID=60 \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 60 \
        --branch "fix/issue-60" --title "fix: recover CI for #60" \
        --task "Fix CI." --recover >/dev/null 2>&1
poll_done "$(job_dir_for 60)" || true
if grep -q -- '--recover' "$REC_MARKER" 2>/dev/null; then
    pass "J1: code-edit-job.sh forwards --recover to the orchestrator"
else
    fail "J1: --recover passthrough" "marker=$(cat "$REC_MARKER" 2>/dev/null)"
fi

NOREC_MARKER="$WORK/norec-marker"; : > "$NOREC_MARKER"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB_ORCH" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    STUB_MARKER="$NOREC_MARKER" STUB_IID=61 \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 61 \
        --branch "fix/issue-61" --title "normal" --task "do it" >/dev/null 2>&1
poll_done "$(job_dir_for 61)" || true
if grep -q -- '--recover' "$NOREC_MARKER" 2>/dev/null; then
    fail "J2: normal run wrongly forwarded --recover" "marker=$(cat "$NOREC_MARKER" 2>/dev/null)"
else
    pass "J2: a normal run does NOT forward --recover"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
