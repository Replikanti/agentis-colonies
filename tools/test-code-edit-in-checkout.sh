#!/usr/bin/env bash
# test-code-edit-in-checkout.sh (#1210): exercise the git orchestration of
# tools/code-edit-in-checkout.sh WITHOUT a real Claude Code session. The
# claude-edit step is replaced by a STUB `flat-cyborg` on PATH that simulates an
# editing agent (writes a file into --cwd); the GitHub PR-open step is replaced
# by a STUB github-api.sh that echoes a canned PR JSON. The "remote" is a local
# bare git repo reached via a file:// GITHUB_URL (the orchestrator forwards a
# file:// base verbatim, never used in production).
#
# Asserts:
#   1. clone + deterministic per-issue branch setup
#   2. the claude-edit diff is committed (commit message + file present)
#   3. the PR-open call fires and the orchestrator prints the PR URL on stdout
#   4. NO_EDITS path: when the stub makes no change, exit 3 + "NO_EDITS", no
#      commit, no PR
#   5. the token NEVER appears in the orchestrator's combined stdout+stderr
#      (incl. with `set -x` enabled in the orchestrator's environment)
#
# Auto-discovered by tools/colony-lint.sh's tools-test loop. Exit 0 if all pass.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
ORCH="$REPO_ROOT/tools/code-edit-in-checkout.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if ! command -v git >/dev/null 2>&1; then
    echo "[SKIP] test-code-edit-in-checkout.sh: git not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] test-code-edit-in-checkout.sh: python3 not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi
if [ ! -f "$ORCH" ]; then
    fail "orchestrator missing: $ORCH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_TOKEN="ghp_FAKE_TOKEN_DO_NOT_LEAK_abcdef0123456789"
OWNER="acme"
REPO="widget"

# git identity for commits inside the harness (CI has no global config).
export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

# ---------------------------------------------------------------------------
# A local "remote": a bare repo seeded with one commit on main. The
# orchestrator clones file://$REMOTE_BASE/<owner>/<repo>.git.
# ---------------------------------------------------------------------------
REMOTE_BASE="$WORK/remote"
BARE="$REMOTE_BASE/$OWNER/$REPO.git"
SEED="$WORK/seed"
mkdir -p "$BARE"
git init --quiet --bare --initial-branch=main "$BARE" 2>/dev/null \
    || git init --quiet --bare "$BARE"
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
)
# Point the bare repo's HEAD at main so origin/HEAD resolves on clone.
git --git-dir="$BARE" symbolic-ref HEAD refs/heads/main

# ---------------------------------------------------------------------------
# A fake colony tree so the orchestrator resolves COLONY_DIR/FED_DIR and finds
# a stub github-api.sh under <fed>/<colony>/scripts/.
# ---------------------------------------------------------------------------
FED_DIR="$WORK/fed"
COLONY_DIR="$FED_DIR/implementation"
mkdir -p "$COLONY_DIR/scripts"

# Stub github-api.sh: only the create-mr verb is needed. It records that it was
# invoked (with which --source/--title) and echoes a canned PR JSON. It also
# asserts GITHUB_TOKEN reached it via the env (never argv).
CREATE_MR_LOG="$WORK/create-mr.log"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
if [ "\${1:-}" != "create-mr" ]; then
    echo "stub github-api.sh: unexpected verb \${1:-}" >&2
    exit 1
fi
shift
SRC=""; TITLE=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --source) SRC="\$2"; shift 2 ;;
        --title) TITLE="\$2"; shift 2 ;;
        --description) shift 2 ;;
        *) shift ;;
    esac
done
{
    echo "create-mr source=\$SRC title=\$TITLE"
    echo "token_seen=\${GITHUB_TOKEN:-MISSING}"
    echo "owner=\${GITHUB_OWNER:-} repo=\${GITHUB_REPO:-}"
} >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/1", "number": 1}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

# ---------------------------------------------------------------------------
# Stub flat-cyborg on PATH. Two modes via FC_STUB_MODE:
#   edit    : parse --cwd, write a new file there (simulate an editing agent)
#   no-edit : touch nothing (simulate claude making no change)
# It also records the flags it was given so we can confirm the orchestrator
# passed --cwd / --auto-approve / --no-jitter and NOT --extract.
# ---------------------------------------------------------------------------
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
FC_FLAGS_LOG="$WORK/fc-flags.log"
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
    printf 'generated by claude\n' > "\$CWD/NEWFILE.txt"
fi
# FC_STUB_RC lets a test simulate flat-cyborg riding to its --timeout-ms and
# returning non-zero even though the edit above already landed (the real-world
# "interactive TUI never settled" case).
exit "\${FC_STUB_RC:-0}"
STUB_EOF
chmod +x "$STUB_BIN/flat-cyborg"
export PATH="$STUB_BIN:$PATH"

# Common env for an orchestrator run.
run_orch() {
    env \
        PATH="$STUB_BIN:$PATH" \
        COLONY_DIR="$COLONY_DIR" \
        GITHUB_URL="file://$REMOTE_BASE" \
        GITHUB_TOKEN="$FAKE_TOKEN" \
        GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
        FC_STUB_MODE="${1:-edit}" \
        FC_STUB_RC="${2:-0}" \
        bash "$ORCH" \
            --owner "$OWNER" --repo "$REPO" --issue 42 \
            --branch "fix/issue-42" --title "add new file" \
            --task "Create NEWFILE.txt with a greeting."
}

# ===========================================================================
# Run 1: editing agent makes a change -> commit + PR opened, URL on stdout.
# ===========================================================================
OUT1_FILE="$WORK/out1.txt"
run_orch edit >"$OUT1_FILE" 2>"$WORK/err1.txt"
RC1=$?
OUT1="$(cat "$OUT1_FILE")"

if [ "$RC1" -eq 0 ]; then
    pass "run 1: orchestrator exits 0 on a successful edit"
else
    fail "run 1: orchestrator exit 0 on success" "rc=$RC1 err=$(cat "$WORK/err1.txt")"
fi

if [ "$OUT1" = "https://example.test/pr/1" ]; then
    pass "run 1: prints the PR URL (from stub create-mr) on stdout"
else
    fail "run 1: prints PR URL on stdout" "stdout=[$OUT1]"
fi

# Workspace cloned to the derived path with a deterministic per-issue branch.
WS="$FED_DIR/.agentis/workspaces/implementation/$OWNER-$REPO"
if [ -d "$WS/.git" ]; then
    pass "run 1: cloned the repo into the per-colony workspace path"
else
    fail "run 1: workspace checkout exists" "expected $WS/.git"
fi

CUR_BRANCH="$(git -C "$WS" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
if [ "$CUR_BRANCH" = "fix/issue-42" ]; then
    pass "run 1: checked out the deterministic fix/issue-42 branch"
else
    fail "run 1: deterministic branch fix/issue-42" "on $CUR_BRANCH"
fi

# The edit diff is committed: the new file is in the tip tree + commit message.
if git -C "$WS" cat-file -e "HEAD:NEWFILE.txt" 2>/dev/null; then
    pass "run 1: committed the editing agent's NEWFILE.txt"
else
    fail "run 1: NEWFILE.txt present in HEAD commit"
fi
HEAD_MSG="$(git -C "$WS" log -1 --pretty=%s 2>/dev/null || echo '')"
case "$HEAD_MSG" in
    "feat: add new file (#42)") pass "run 1: commit message is feat: <title> (#<iid>)" ;;
    *) fail "run 1: commit message format" "got [$HEAD_MSG]" ;;
esac

# The branch was pushed to the bare remote.
if git --git-dir="$BARE" rev-parse --verify --quiet refs/heads/fix/issue-42 >/dev/null; then
    pass "run 1: pushed fix/issue-42 to the remote"
else
    fail "run 1: pushed branch present on remote"
fi

# create-mr was called with the right source + title and saw the token via env.
if [ -f "$CREATE_MR_LOG" ] && grep -q "create-mr source=fix/issue-42 title=add new file" "$CREATE_MR_LOG"; then
    pass "run 1: invoked github-api.sh create-mr with the branch + title"
else
    fail "run 1: create-mr invocation recorded" "log=$(cat "$CREATE_MR_LOG" 2>/dev/null)"
fi
if grep -q "token_seen=$FAKE_TOKEN" "$CREATE_MR_LOG"; then
    pass "run 1: token reached create-mr via the environment (never argv)"
else
    fail "run 1: token passed to create-mr via env"
fi

# flat-cyborg was driven as an editing agent: --cwd + --auto-approve +
# --no-jitter, and NOT --extract (we don't scrape a reply here).
FC_FLAGS="$(cat "$FC_FLAGS_LOG" 2>/dev/null || echo '')"
if printf '%s' "$FC_FLAGS" | grep -q -- '--cwd' \
    && printf '%s' "$FC_FLAGS" | grep -q -- '--auto-approve' \
    && printf '%s' "$FC_FLAGS" | grep -q -- '--no-jitter'; then
    pass "run 1: flat-cyborg invoked with --cwd / --auto-approve / --no-jitter"
else
    fail "run 1: flat-cyborg editing-agent flags" "flags=[$FC_FLAGS]"
fi
if printf '%s' "$FC_FLAGS" | grep -q -- '--extract'; then
    fail "run 1: flat-cyborg must NOT run in --extract mode (editing agent, no reply scrape)"
else
    pass "run 1: flat-cyborg not run in --extract mode (editing agent)"
fi

# ===========================================================================
# Token never leaks in run 1's output (stdout + stderr), even though the
# orchestrator handles the token internally. Belt-and-suspenders: also run the
# orchestrator under `set -x` and confirm the token still does not appear.
# ===========================================================================
if grep -q "$FAKE_TOKEN" "$OUT1_FILE" "$WORK/err1.txt"; then
    fail "run 1: token LEAKED into orchestrator stdout/stderr"
else
    pass "run 1: token never appears in orchestrator stdout/stderr"
fi

XTRACE_OUT="$WORK/xtrace.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE="edit" \
    bash -x "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 42 \
        --branch "fix/issue-42" --title "add new file" \
        --task "Create NEWFILE.txt with a greeting." >"$XTRACE_OUT" 2>&1 || true
if grep -q "$FAKE_TOKEN" "$XTRACE_OUT"; then
    fail "token: appears under bash -x trace (set -x leak)"
else
    pass "token: never appears under bash -x trace (set -x safe)"
fi

# ===========================================================================
# Run 2 (fresh remote): editing agent makes NO change -> NO_EDITS, exit 3,
# no commit, no PR.
# ===========================================================================
# Reset the harness state so run 2 starts clean.
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
# Re-create the stub github-api.sh (lost with the rm -rf above).
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called with: \$*"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/SHOULD-NOT-OPEN"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

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
)
git --git-dir="$BARE" symbolic-ref HEAD refs/heads/main

OUT2_FILE="$WORK/out2.txt"
run_orch no-edit >"$OUT2_FILE" 2>"$WORK/err2.txt"
RC2=$?

if [ "$RC2" -eq 3 ]; then
    pass "run 2 (no-edit): orchestrator exits 3 (NO_EDITS -> retry, not error)"
else
    fail "run 2 (no-edit): exit 3 on no edits" "rc=$RC2"
fi
if grep -q '^NO_EDITS$' "$OUT2_FILE"; then
    pass "run 2 (no-edit): prints NO_EDITS sentinel on stdout"
else
    fail "run 2 (no-edit): NO_EDITS on stdout" "stdout=[$(cat "$OUT2_FILE")]"
fi
if [ ! -f "$CREATE_MR_LOG" ]; then
    pass "run 2 (no-edit): no PR opened (create-mr never invoked)"
else
    fail "run 2 (no-edit): create-mr must NOT be invoked" "log=$(cat "$CREATE_MR_LOG")"
fi
# No branch should have been pushed for the no-edit run.
if git --git-dir="$BARE" rev-parse --verify --quiet refs/heads/fix/issue-42 >/dev/null; then
    fail "run 2 (no-edit): a branch was pushed despite no edits"
else
    pass "run 2 (no-edit): no branch pushed to the remote"
fi

# ===========================================================================
# Run 3 (fresh remote): editing agent makes a change BUT flat-cyborg exits
# non-zero (the interactive TUI never settled -> rode to --timeout-ms). The
# edit is the artifact: the orchestrator must still commit + push + open the
# PR and exit 0, not discard a completed edit because the session timed out.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called with: \$*"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/3"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

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
)
git --git-dir="$BARE" symbolic-ref HEAD refs/heads/main

OUT3_FILE="$WORK/out3.txt"
run_orch edit 124 >"$OUT3_FILE" 2>"$WORK/err3.txt"
RC3=$?
OUT3="$(cat "$OUT3_FILE")"

if [ "$RC3" -eq 0 ]; then
    pass "run 3 (timeout+edits): orchestrator exits 0 (commits despite non-zero flat-cyborg)"
else
    fail "run 3 (timeout+edits): exit 0 when edits exist" "rc=$RC3 err=$(cat "$WORK/err3.txt")"
fi
if [ "$OUT3" = "https://example.test/pr/3" ]; then
    pass "run 3 (timeout+edits): prints the PR URL on stdout"
else
    fail "run 3 (timeout+edits): PR URL on stdout" "stdout=[$OUT3]"
fi
if [ -f "$CREATE_MR_LOG" ]; then
    pass "run 3 (timeout+edits): PR opened (create-mr invoked)"
else
    fail "run 3 (timeout+edits): create-mr must be invoked when edits exist"
fi
if git --git-dir="$BARE" rev-parse --verify --quiet refs/heads/fix/issue-42 >/dev/null; then
    pass "run 3 (timeout+edits): branch pushed to the remote"
else
    fail "run 3 (timeout+edits): branch must be pushed when edits exist"
fi

# ===========================================================================
# Run 4 (fresh remote): editing agent makes NO change AND flat-cyborg exits
# non-zero -> the session genuinely failed. The orchestrator must surface the
# real failure (exit FC_RC, not the NO_EDITS retry code 3) and open no PR.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called with: \$*"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/SHOULD-NOT-OPEN"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

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
)
git --git-dir="$BARE" symbolic-ref HEAD refs/heads/main

OUT4_FILE="$WORK/out4.txt"
run_orch no-edit 17 >"$OUT4_FILE" 2>"$WORK/err4.txt"
RC4=$?

if [ "$RC4" -eq 17 ]; then
    pass "run 4 (fail+no-edits): orchestrator surfaces flat-cyborg exit code (not NO_EDITS 3)"
else
    fail "run 4 (fail+no-edits): exit FC_RC on genuine failure" "rc=$RC4 (expected 17)"
fi
if [ ! -f "$CREATE_MR_LOG" ]; then
    pass "run 4 (fail+no-edits): no PR opened (create-mr never invoked)"
else
    fail "run 4 (fail+no-edits): create-mr must NOT be invoked" "log=$(cat "$CREATE_MR_LOG")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
