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

# Self-isolate from the invoking shell. Each run below drives the orchestrator
# via `env VAR=... bash "$ORCH"`, which ADDS vars but does not CLEAR inherited
# ones. When this harness runs inside a live federation shell, the running
# agents export forge-resolution + locale vars (GITHUB_REPOS_JSON, FORGE_TYPE,
# GITHUB_OWNER, ...) that leak into every run not explicitly overriding them and
# false-fail forge resolution (e.g. "acme/widget not in GITHUB_REPOS_JSON").
# Clear that ambient baseline so the harness is deterministic regardless of where
# it is launched; no-op in clean CI where none of these are set.
unset GITHUB_REPOS_JSON GITLAB_REPOS_JSON FORGE_TYPE \
      GITHUB_OWNER GITHUB_REPO GITHUB_TOKEN GITHUB_URL \
      GITLAB_PROJECT GITLAB_TOKEN GITLAB_URL \
      LC_ALL COLONY_DIR 2>/dev/null || true

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
SRC=""; TITLE=""; DESC=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --source) SRC="\$2"; shift 2 ;;
        --title) TITLE="\$2"; shift 2 ;;
        --description) DESC="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
{
    echo "create-mr source=\$SRC title=\$TITLE"
    echo "desc_first=\$(printf '%s' "\$DESC" | head -n 1)"
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
# passed the full driving set --cwd / --auto-approve / --no-jitter / --extract /
# --wrap-input (#1221).
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
# FC_SPAWN_ORPHAN simulates a claude Bash-tool child that orphans when the
# editing session ends: detach a process rooted in --cwd, tagged so the test
# can find it. The orchestrator's cwd-based reaper must kill it (#1249).
if [ -n "\${FC_SPAWN_ORPHAN:-}" ] && [ -n "\$CWD" ]; then
    ( cd "\$CWD" 2>/dev/null && exec -a "\$FC_SPAWN_ORPHAN" sleep 30 ) &
    sleep 0.3
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

# Per-job workspace isolation (#1248): the checkout is keyed by ISSUE, and on a
# successful PR it is cleaned up (#1249 disk bound). Assert the per-issue path was
# used (flat-cyborg got --cwd .../issue-42) and that it was removed after
# success — then read the committed result from the REMOTE (the local per-issue
# checkout no longer exists).
WS="$FED_DIR/.agentis/workspaces/implementation/$OWNER-$REPO/issue-42"
if printf '%s' "$(cat "$FC_FLAGS_LOG" 2>/dev/null)" | grep -q -- "--cwd $WS"; then
    pass "run 1: editing agent ran in the per-issue workspace (.../issue-42)"
else
    fail "run 1: per-issue workspace --cwd" "flags=[$(cat "$FC_FLAGS_LOG" 2>/dev/null)]"
fi
if [ ! -e "$WS" ]; then
    pass "run 1: per-issue workspace cleaned up after a successful PR (no disk leak)"
else
    fail "run 1: workspace should be removed on success" "still present: $WS"
fi

# The edit diff was committed + pushed: branch present on the remote, the new
# file in its tip tree, and the commit-message format. Read from the bare remote
# because the local per-issue checkout is cleaned on success.
if git --git-dir="$BARE" rev-parse --verify --quiet refs/heads/fix/issue-42 >/dev/null; then
    pass "run 1: pushed fix/issue-42 to the remote"
else
    fail "run 1: pushed branch present on remote"
fi
if git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-42:NEWFILE.txt" 2>/dev/null; then
    pass "run 1: committed the editing agent's NEWFILE.txt"
else
    fail "run 1: NEWFILE.txt present in pushed commit"
fi
HEAD_MSG="$(git --git-dir="$BARE" log -1 --pretty=%s refs/heads/fix/issue-42 2>/dev/null || echo '')"
case "$HEAD_MSG" in
    "fix: add new file (#42)") pass "run 1: commit subject = normalised conventional title (#<iid>), no hardcoded feat: prefix (#1308)" ;;
    *) fail "run 1: commit subject format" "got [$HEAD_MSG]" ;;
esac

# create-mr was called with the right source + title and saw the token via env.
if [ -f "$CREATE_MR_LOG" ] && grep -q "create-mr source=fix/issue-42 title=fix: add new file" "$CREATE_MR_LOG"; then
    pass "run 1: invoked github-api.sh create-mr with the branch + normalised title"
else
    fail "run 1: create-mr invocation recorded" "log=$(cat "$CREATE_MR_LOG" 2>/dev/null)"
fi
if grep -q "token_seen=$FAKE_TOKEN" "$CREATE_MR_LOG"; then
    pass "run 1: token reached create-mr via the environment (never argv)"
else
    fail "run 1: token passed to create-mr via env"
fi

# #1308: the PR description must open with a Closes #<iid> keyword so the forge
# links the PR to the issue and auto-closes it on merge (a bare "Implements #N"
# mention does neither).
if grep -q "desc_first=Closes #42" "$CREATE_MR_LOG"; then
    pass "run 1: PR description opens with 'Closes #<iid>' (links + auto-closes the issue, #1308)"
else
    fail "run 1: PR description must start with 'Closes #<iid>'" "log=$(cat "$CREATE_MR_LOG" 2>/dev/null)"
fi

# flat-cyborg was driven as an editing agent with the FULL driving flag set:
# --cwd + --auto-approve + --no-jitter AND --extract + --wrap-input. Without
# --extract flat-cyborg does not reliably submit-and-run the interactive Claude
# session, so the prompt is typed but never executed and no edit is produced
# (#1221). We don't consume the scraped reply (the artifact is the git diff) —
# --extract is here purely to drive the session.
FC_FLAGS="$(cat "$FC_FLAGS_LOG" 2>/dev/null || echo '')"
if printf '%s' "$FC_FLAGS" | grep -q -- '--cwd' \
    && printf '%s' "$FC_FLAGS" | grep -q -- '--auto-approve' \
    && printf '%s' "$FC_FLAGS" | grep -q -- '--no-jitter'; then
    pass "run 1: flat-cyborg invoked with --cwd / --auto-approve / --no-jitter"
else
    fail "run 1: flat-cyborg editing-agent flags" "flags=[$FC_FLAGS]"
fi
if printf '%s' "$FC_FLAGS" | grep -q -- '--extract' \
    && printf '%s' "$FC_FLAGS" | grep -q -- '--wrap-input'; then
    pass "run 1: flat-cyborg driven with --extract + --wrap-input (reliable session submit, #1219)"
else
    fail "run 1: flat-cyborg must drive with --extract + --wrap-input" "flags=[$FC_FLAGS]"
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

# ===========================================================================
# Run 5 (multi-repo #316 / #1212): the inherited GITHUB_TOKEN + GITHUB_URL are
# the WRONG (first-repo) values; GITHUB_REPOS_JSON carries this repo's OWN
# token + url. The orchestrator must re-resolve via forge-resolve-repo.py and
# clone/push/open-PR with the resolved credentials, not the inherited ones.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
# Stub records the token it actually saw via env (the resolved one must win).
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
shift
{ echo "token_seen=\${GITHUB_TOKEN:-MISSING} owner=\${GITHUB_OWNER:-} repo=\${GITHUB_REPO:-}"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/5"}'
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

PERREPO_TOKEN="ghp_PERREPO_TOKEN_DO_NOT_LEAK_9876543210fedcba"
# This repo's OWN entry: correct file:// url + its own token. Built with
# json.dumps so the mktemp path is escaped safely.
REPOS_JSON_5="$(python3 -c "import json,sys; print(json.dumps([{'url':'file://'+sys.argv[1],'owner':'acme','repo':'widget','token':sys.argv[2],'me':'acme-bot'}]))" "$REMOTE_BASE" "$PERREPO_TOKEN")"

OUT5_FILE="$WORK/out5.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file:///nonexistent-inherited-base" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    GITHUB_REPOS_JSON="$REPOS_JSON_5" \
    FC_STUB_MODE="edit" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 42 \
        --branch "fix/issue-42" --title "add new file" \
        --task "Create NEWFILE.txt with a greeting." >"$OUT5_FILE" 2>"$WORK/err5.txt"
RC5=$?
OUT5="$(cat "$OUT5_FILE")"

if [ "$RC5" -eq 0 ]; then
    pass "run 5 (multi-repo): orchestrator exits 0 using the RESOLVED url (inherited url was bogus)"
else
    fail "run 5 (multi-repo): exit 0 with resolved creds" "rc=$RC5 err=$(cat "$WORK/err5.txt")"
fi
if [ "$OUT5" = "https://example.test/pr/5" ]; then
    pass "run 5 (multi-repo): prints the PR URL on stdout"
else
    fail "run 5 (multi-repo): PR URL on stdout" "stdout=[$OUT5]"
fi
if grep -q "token_seen=$PERREPO_TOKEN" "$CREATE_MR_LOG" 2>/dev/null; then
    pass "run 5 (multi-repo): create-mr saw the RESOLVED per-repo token (#1212)"
else
    fail "run 5 (multi-repo): per-repo token must reach create-mr" "log=$(cat "$CREATE_MR_LOG" 2>/dev/null)"
fi
if grep -q "token_seen=$FAKE_TOKEN" "$CREATE_MR_LOG" 2>/dev/null; then
    fail "run 5 (multi-repo): WRONG inherited token reached create-mr"
else
    pass "run 5 (multi-repo): inherited (first-repo) token did NOT leak through"
fi
if grep -q -e "$PERREPO_TOKEN" -e "$FAKE_TOKEN" "$OUT5_FILE" "$WORK/err5.txt" 2>/dev/null; then
    fail "run 5 (multi-repo): a token LEAKED into orchestrator stdout/stderr"
else
    pass "run 5 (multi-repo): neither token appears in orchestrator stdout/stderr"
fi

# ===========================================================================
# Run 6 (multi-repo #1212): the requested repo is NOT in GITHUB_REPOS_JSON.
# The orchestrator must fail LOUDLY (exit 1) before cloning, and open no PR.
# ===========================================================================
rm -f "$CREATE_MR_LOG"
REPOS_JSON_6="$(python3 -c "import json; print(json.dumps([{'url':'file:///nope','owner':'other','repo':'thing','token':'x','me':'y'}]))")"

OUT6_FILE="$WORK/out6.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file:///nonexistent-inherited-base" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    GITHUB_REPOS_JSON="$REPOS_JSON_6" \
    FC_STUB_MODE="edit" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 42 \
        --branch "fix/issue-42" --title "add new file" \
        --task "Create NEWFILE.txt with a greeting." >"$OUT6_FILE" 2>"$WORK/err6.txt"
RC6=$?

if [ "$RC6" -eq 1 ]; then
    pass "run 6 (multi-repo miss): orchestrator exits 1 (fails loudly when repo absent from GITHUB_REPOS_JSON)"
else
    fail "run 6 (multi-repo miss): exit 1 on unresolved repo" "rc=$RC6"
fi
if grep -q "not in GITHUB_REPOS_JSON" "$WORK/err6.txt" 2>/dev/null; then
    pass "run 6 (multi-repo miss): emits an explanatory error on stderr"
else
    fail "run 6 (multi-repo miss): error message on stderr" "err=$(cat "$WORK/err6.txt" 2>/dev/null)"
fi
if [ ! -f "$CREATE_MR_LOG" ]; then
    pass "run 6 (multi-repo miss): no PR opened (create-mr never invoked)"
else
    fail "run 6 (multi-repo miss): create-mr must NOT be invoked" "log=$(cat "$CREATE_MR_LOG")"
fi

# ===========================================================================
# Run 7 (GitLab parity #1213): FORGE_TYPE=gitlab. The orchestrator must drive
# the GitLab backend (gitlab-api.sh, NOT github-api.sh), pass GITLAB_PROJECT as
# the URL-encoded owner%2Frepo, let GITLAB_TOKEN reach the backend via env, and
# parse `web_url` from the MR response. A github-api.sh stub is also planted to
# prove it is NOT the one invoked.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
# GitLab backend stub: records the token/project/url it saw, echoes MR JSON.
cat > "$COLONY_DIR/scripts/gitlab-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
shift
{ echo "gitlab token_seen=\${GITLAB_TOKEN:-MISSING} project=\${GITLAB_PROJECT:-} url=\${GITLAB_URL:-}"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"web_url": "https://gitlab.example.test/acme/widget/-/merge_requests/7"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/gitlab-api.sh"
# Wrong-backend tripwire: if the orchestrator ignores FORGE_TYPE it would call
# this and pollute the log with WRONG-BACKEND.
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "WRONG-BACKEND github-api.sh called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/WRONG"}'
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

GITLAB_FAKE_TOKEN="glpat-FAKE_TOKEN_DO_NOT_LEAK_abcdef0123456789"
OUT7_FILE="$WORK/out7.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    FORGE_TYPE="gitlab" \
    GITLAB_URL="file://$REMOTE_BASE" \
    GITLAB_TOKEN="$GITLAB_FAKE_TOKEN" \
    FC_STUB_MODE="edit" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 42 \
        --branch "fix/issue-42" --title "add new file" \
        --task "Create NEWFILE.txt with a greeting." >"$OUT7_FILE" 2>"$WORK/err7.txt"
RC7=$?
OUT7="$(cat "$OUT7_FILE")"

if [ "$RC7" -eq 0 ]; then
    pass "run 7 (gitlab): orchestrator exits 0 on the GitLab path"
else
    fail "run 7 (gitlab): exit 0 on GitLab path" "rc=$RC7 err=$(cat "$WORK/err7.txt")"
fi
if [ "$OUT7" = "https://gitlab.example.test/acme/widget/-/merge_requests/7" ]; then
    pass "run 7 (gitlab): parses web_url from the MR response"
else
    fail "run 7 (gitlab): web_url on stdout" "stdout=[$OUT7]"
fi
if grep -q "^gitlab token_seen=$GITLAB_FAKE_TOKEN " "$CREATE_MR_LOG" 2>/dev/null; then
    pass "run 7 (gitlab): GITLAB_TOKEN reached gitlab-api.sh via env"
else
    fail "run 7 (gitlab): GITLAB_TOKEN to backend" "log=$(cat "$CREATE_MR_LOG" 2>/dev/null)"
fi
if grep -q "project=acme%2Fwidget" "$CREATE_MR_LOG" 2>/dev/null; then
    pass "run 7 (gitlab): GITLAB_PROJECT URL-encoded as owner%2Frepo"
else
    fail "run 7 (gitlab): GITLAB_PROJECT encoding" "log=$(cat "$CREATE_MR_LOG" 2>/dev/null)"
fi
if grep -q "WRONG-BACKEND" "$CREATE_MR_LOG" 2>/dev/null; then
    fail "run 7 (gitlab): github-api.sh was wrongly invoked for a gitlab forge"
else
    pass "run 7 (gitlab): github-api.sh was NOT invoked (forge backend selected correctly)"
fi
if grep -q "$GITLAB_FAKE_TOKEN" "$OUT7_FILE" "$WORK/err7.txt" 2>/dev/null; then
    fail "run 7 (gitlab): token LEAKED into orchestrator stdout/stderr"
else
    pass "run 7 (gitlab): token never appears in orchestrator stdout/stderr"
fi

# Run 8 (gitlab presence check): FORGE_TYPE=gitlab with no GITLAB_TOKEN must fail
# loudly (exit 1) and name GITLAB_TOKEN, not GITHUB_TOKEN.
OUT8_FILE="$WORK/out8.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    FORGE_TYPE="gitlab" \
    GITLAB_URL="file://$REMOTE_BASE" \
    FC_STUB_MODE="edit" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 42 \
        --branch "fix/issue-42" --title "add new file" \
        --task "Create NEWFILE.txt with a greeting." >"$OUT8_FILE" 2>"$WORK/err8.txt"
RC8=$?
if [ "$RC8" -eq 1 ] && grep -q "GITLAB_TOKEN must be set" "$WORK/err8.txt" 2>/dev/null; then
    pass "run 8 (gitlab no-token): fails loudly naming GITLAB_TOKEN"
else
    fail "run 8 (gitlab no-token): exit 1 + GITLAB_TOKEN message" "rc=$RC8 err=$(cat "$WORK/err8.txt" 2>/dev/null)"
fi

# ===========================================================================
# Run 9 (#1248 per-job isolation + #1249 orphan reap + disk cleanup): a job for
# a DIFFERENT issue must (a) run in its OWN per-issue workspace, (b) have its
# orphaned editing-session children reaped, and (c) leave no workspace on
# success. The stub flat-cyborg with FC_SPAWN_ORPHAN detaches a child rooted in
# --cwd that outlives the session — exactly the #1249 orphan that pegged a core.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/9"}'
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

ORPHAN_TAG="ceic-orphan-test-$$"
OUT9_FILE="$WORK/out9.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE="edit" \
    FC_SPAWN_ORPHAN="$ORPHAN_TAG" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 77 \
        --branch "fix/issue-77" --title "add new file" \
        --task "Create NEWFILE.txt with a greeting." >"$OUT9_FILE" 2>"$WORK/err9.txt"
RC9=$?
sleep 1   # let any un-reaped orphan settle so the survival check is honest

WS9="$FED_DIR/.agentis/workspaces/implementation/$OWNER-$REPO/issue-77"
FC9="$(cat "$FC_FLAGS_LOG" 2>/dev/null || echo '')"
if printf '%s' "$FC9" | grep -q -- "--cwd $WS9"; then
    pass "run 9 (isolation): job ran in its OWN per-issue workspace (.../issue-77)"
else
    fail "run 9 (isolation): per-issue --cwd" "flags=[$FC9]"
fi
if [ "$RC9" -eq 0 ] && [ ! -e "$WS9" ]; then
    pass "run 9 (disk): per-issue workspace removed after a successful PR"
else
    fail "run 9 (disk): workspace cleanup on success" "rc=$RC9 present=$([ -e "$WS9" ] && echo yes || echo no)"
fi
if pgrep -f "$ORPHAN_TAG" >/dev/null 2>&1; then
    fail "run 9 (reap): orphaned editing-session child SURVIVED the job"
    pkill -KILL -f "$ORPHAN_TAG" 2>/dev/null || true
else
    pass "run 9 (reap): orphaned editing-session child was reaped (#1249)"
fi

# ===========================================================================
# Run 10 (#1251 continue-on-incomplete): a stateful stub flat-cyborg times out
# (exit 124) on attempt 1 with a PARTIAL edit, then settles (exit 0) on attempt
# 2 completing the change. The orchestrator must ITERATE — re-drive with the
# continuation prompt, building on attempt 1's checkout — then commit the FULL
# result. This is the loop that lets big tasks finish across turns.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/10"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

# Stateful editing stub: attempt 1 -> partial edit + timeout (124); attempt 2 ->
# finish the change + settle (0). The counter persists across the two
# invocations within this single orchestrator run.
CNT_FILE="$WORK/fc-attempt-count"; rm -f "$CNT_FILE"
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
n=\$(cat "$CNT_FILE" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$CNT_FILE"
if [ "\$n" -eq 1 ]; then
    printf 'part one\n' > "\$CWD/PART1.txt"
    exit 124
fi
printf 'part two\n' > "\$CWD/PART2.txt"
exit 0
STUB_EOF
chmod +x "$STUB_BIN/flat-cyborg"

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

OUT10_FILE="$WORK/out10.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    CODE_EDIT_MAX_ATTEMPTS=3 \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 88 \
        --branch "fix/issue-88" --title "add two files" \
        --task "Create PART1.txt and PART2.txt." >"$OUT10_FILE" 2>"$WORK/err10.txt"
RC10=$?
ATTEMPTS="$(cat "$CNT_FILE" 2>/dev/null || echo 0)"

if [ "$RC10" -eq 0 ] && [ "$(cat "$OUT10_FILE")" = "https://example.test/pr/10" ]; then
    pass "run 10 (continue): orchestrator exits 0 + opens the PR after iterating"
else
    fail "run 10 (continue): exit 0 + PR url" "rc=$RC10 out=$(cat "$OUT10_FILE" 2>/dev/null) err=$(tail -3 "$WORK/err10.txt" 2>/dev/null)"
fi
if [ "$ATTEMPTS" = "2" ]; then
    pass "run 10 (continue): drove the editing session TWICE (timeout -> continue -> settle)"
else
    fail "run 10 (continue): expected 2 attempts" "got $ATTEMPTS"
fi
if grep -q "continuing editing session (attempt 2" "$WORK/err10.txt" 2>/dev/null; then
    pass "run 10 (continue): took the continuation-prompt path on attempt 2"
else
    fail "run 10 (continue): continuation log line" "err=$(tail -5 "$WORK/err10.txt" 2>/dev/null)"
fi
# attempt 2 built on attempt 1's checkout: BOTH files must be in the pushed commit.
if git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-88:PART1.txt" 2>/dev/null \
   && git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-88:PART2.txt" 2>/dev/null; then
    pass "run 10 (continue): final commit has BOTH partial + completed files (built on prior attempt)"
else
    fail "run 10 (continue): both PART1.txt + PART2.txt in pushed commit"
fi

# ===========================================================================
# Run 11 (#1251 loop bound + knob hardening): a stub that ALWAYS times out (124)
# AND always makes NEW progress (a fresh file each attempt) would loop until the
# 25-min budget if the attempt cap failed. Combined with a GARBAGE
# CODE_EDIT_MAX_ATTEMPTS ("not-a-number"), this proves (a) the non-integer knob
# is sanitized to the default and (b) the loop is hard-bounded by MAX_ATTEMPTS
# (default 3), then commits whatever was produced.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/11"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

CNT_FILE2="$WORK/fc-attempt-count-2"; rm -f "$CNT_FILE2"
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
CWD=""
while [ \$# -gt 0 ]; do case "\$1" in --cwd) CWD="\$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
n=\$(cat "$CNT_FILE2" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$CNT_FILE2"
# Always new progress + always time out: without a working attempt cap this
# loops until the budget. The sanitized MAX_ATTEMPTS must bound it.
printf 'chunk %s\n' "\$n" > "\$CWD/CHUNK_\$n.txt"
exit 124
STUB_EOF
chmod +x "$STUB_BIN/flat-cyborg"

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

OUT11_FILE="$WORK/out11.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    CODE_EDIT_MAX_ATTEMPTS="not-a-number" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 99 \
        --branch "fix/issue-99" --title "perpetual progress" \
        --task "Keep adding chunks." >"$OUT11_FILE" 2>"$WORK/err11.txt"
RC11=$?
ATTEMPTS2="$(cat "$CNT_FILE2" 2>/dev/null || echo 0)"

if [ "$ATTEMPTS2" = "3" ]; then
    pass "run 11 (bound): loop hard-capped at MAX_ATTEMPTS=3 despite perpetual progress + garbage knob"
else
    fail "run 11 (bound): expected exactly 3 attempts" "got $ATTEMPTS2 (rc=$RC11)"
fi
if [ "$RC11" -eq 0 ] && [ "$(cat "$OUT11_FILE")" = "https://example.test/pr/11" ]; then
    pass "run 11 (bound): committed what was produced + opened the PR after the cap"
else
    fail "run 11 (bound): exit 0 + PR url after cap" "rc=$RC11 out=$(cat "$OUT11_FILE" 2>/dev/null)"
fi

# ===========================================================================
# Run 12 (#1253 verify-and-fix): claude SETTLES each attempt, but the change
# fails the verification gate on attempt 1 (no DONE.marker) and passes on
# attempt 2 (marker written). The orchestrator must run the gate, feed the
# failure back, iterate, and only commit once GREEN.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/12"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

CNT_FILE3="$WORK/fc-attempt-count-3"; rm -f "$CNT_FILE3"
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
CWD=""
while [ \$# -gt 0 ]; do case "\$1" in --cwd) CWD="\$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
n=\$(cat "$CNT_FILE3" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$CNT_FILE3"
# Always settle (exit 0). Attempt 1 leaves the gate failing (no marker);
# attempt 2 writes the marker the gate checks for.
if [ "\$n" -eq 1 ]; then
    printf 'work\n' > "\$CWD/WORK.txt"
else
    printf 'done\n' > "\$CWD/DONE.marker"
fi
exit 0
STUB_EOF
chmod +x "$STUB_BIN/flat-cyborg"

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

OUT12_FILE="$WORK/out12.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    CODE_EDIT_MAX_ATTEMPTS=3 \
    CODE_EDIT_VERIFY_CMD="test -f DONE.marker" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 120 \
        --branch "fix/issue-120" --title "verify gate" \
        --task "Write the change and the DONE.marker." >"$OUT12_FILE" 2>"$WORK/err12.txt"
RC12=$?
ATTEMPTS3="$(cat "$CNT_FILE3" 2>/dev/null || echo 0)"

if [ "$RC12" -eq 0 ] && [ "$(cat "$OUT12_FILE")" = "https://example.test/pr/12" ]; then
    pass "run 12 (verify): exits 0 + opens PR only after the gate passes"
else
    fail "run 12 (verify): exit 0 + PR url" "rc=$RC12 out=$(cat "$OUT12_FILE" 2>/dev/null) err=$(tail -3 "$WORK/err12.txt" 2>/dev/null)"
fi
if [ "$ATTEMPTS3" = "2" ]; then
    pass "run 12 (verify): iterated after a failing gate (drove twice: fail -> fix -> pass)"
else
    fail "run 12 (verify): expected 2 attempts" "got $ATTEMPTS3"
fi
if grep -q "verify-fix" "$WORK/err12.txt" 2>/dev/null && grep -q "verification PASSED" "$WORK/err12.txt" 2>/dev/null; then
    pass "run 12 (verify): took the verify-fix path then verification PASSED"
else
    fail "run 12 (verify): verify-fix + PASSED log lines" "err=$(tail -6 "$WORK/err12.txt" 2>/dev/null)"
fi
if git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-120:DONE.marker" 2>/dev/null; then
    pass "run 12 (verify): committed only after the gate-satisfying marker was added"
else
    fail "run 12 (verify): DONE.marker in pushed commit"
fi

# ===========================================================================
# Run 13 (#1253 verify-budget): the gate NEVER passes. The orchestrator must
# stop at MAX_ATTEMPTS, log that verification is still failing, and commit
# anyway (the PR's own CI is the backstop) rather than loop forever.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/13"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

CNT_FILE4="$WORK/fc-attempt-count-4"; rm -f "$CNT_FILE4"
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
CWD=""
while [ \$# -gt 0 ]; do case "\$1" in --cwd) CWD="\$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
n=\$(cat "$CNT_FILE4" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$CNT_FILE4"
printf 'chunk %s\n' "\$n" > "\$CWD/WORK_\$n.txt"
exit 0
STUB_EOF
chmod +x "$STUB_BIN/flat-cyborg"

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

OUT13_FILE="$WORK/out13.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    CODE_EDIT_MAX_ATTEMPTS=2 \
    CODE_EDIT_VERIFY_CMD="test -f NEVER_EXISTS.marker" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 121 \
        --branch "fix/issue-121" --title "always failing gate" \
        --task "Add work." >"$OUT13_FILE" 2>"$WORK/err13.txt"
RC13=$?
ATTEMPTS4="$(cat "$CNT_FILE4" 2>/dev/null || echo 0)"

if [ "$ATTEMPTS4" = "2" ]; then
    pass "run 13 (verify-budget): stopped at MAX_ATTEMPTS=2 instead of looping on a never-passing gate"
else
    fail "run 13 (verify-budget): expected 2 attempts" "got $ATTEMPTS4 (rc=$RC13)"
fi
if [ "$RC13" -eq 0 ] && [ "$(cat "$OUT13_FILE")" = "https://example.test/pr/13" ] && grep -q "still FAILING" "$WORK/err13.txt" 2>/dev/null; then
    pass "run 13 (verify-budget): logged 'still FAILING' and committed anyway (CI is the backstop)"
else
    fail "run 13 (verify-budget): commit-anyway + warning" "rc=$RC13 out=$(cat "$OUT13_FILE" 2>/dev/null) err=$(tail -4 "$WORK/err13.txt" 2>/dev/null)"
fi

# ===========================================================================
# Run 14 (#1254 decompose): with --decompose, the orchestrator first asks claude
# to split the epic into an ORDERED subtask list (written to a file, no repo
# edits), then runs the edit loop ONCE PER SUBTASK on the SAME branch,
# accumulating into ONE commit/PR. The stateful stub recognises the decompose
# drive by the word "Decompose" in the cmd-file, writes a 3-line list, and edits
# nothing; each subsequent EDIT invocation writes a unique SUB_<n>.txt file.
# Asserts: exit 0 + PR url; exactly 3 EDIT invocations (one per subtask); all
# three SUB_*.txt in the pushed commit; the decomposed-into-3 log line.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/14"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

# Stateful decompose-aware stub: if the cmd-file contains "Decompose" it is the
# decomposition drive -> write a 3-line subtask list to the target path the
# prompt names ("this exact file: <path>") and make NO repo edit. Otherwise it
# is an edit drive -> bump an EDIT counter and write a unique SUB_<n>.txt.
EDIT_CNT_FILE="$WORK/fc-edit-count-14"; rm -f "$EDIT_CNT_FILE"
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
CWD=""; CMDFILE=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --cwd) CWD="\$2"; shift 2 ;;
        --cmd-file) CMDFILE="\$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
if [ -n "\$CMDFILE" ] && grep -q "Decompose" "\$CMDFILE" 2>/dev/null; then
    # Extract the target list path from the "this exact file: <path>" line.
    TARGET="\$(grep "this exact file" "\$CMDFILE" | grep -oE '/[^ ]+' | head -n1)"
    if [ -n "\$TARGET" ]; then
        printf 'subtask one\nsubtask two\nsubtask three\n' > "\$TARGET"
    fi
    exit 0
fi
n=\$(cat "$EDIT_CNT_FILE" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$EDIT_CNT_FILE"
if [ -n "\$CWD" ]; then
    printf 'edit %s\n' "\$n" > "\$CWD/SUB_\$n.txt"
fi
exit 0
STUB_EOF
chmod +x "$STUB_BIN/flat-cyborg"

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

OUT14_FILE="$WORK/out14.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 130 \
        --branch "fix/issue-130" --title "epic task" \
        --task "Do a big multi-part change." --decompose >"$OUT14_FILE" 2>"$WORK/err14.txt"
RC14=$?
EDIT_CALLS="$(cat "$EDIT_CNT_FILE" 2>/dev/null || echo 0)"

if [ "$RC14" -eq 0 ] && [ "$(cat "$OUT14_FILE")" = "https://example.test/pr/14" ]; then
    pass "run 14 (decompose): exits 0 + opens the PR after running per-subtask"
else
    fail "run 14 (decompose): exit 0 + PR url" "rc=$RC14 out=$(cat "$OUT14_FILE" 2>/dev/null) err=$(tail -4 "$WORK/err14.txt" 2>/dev/null)"
fi
if [ "$EDIT_CALLS" = "3" ]; then
    pass "run 14 (decompose): ran the edit loop ONCE PER SUBTASK (3 edit invocations)"
else
    fail "run 14 (decompose): expected 3 edit invocations" "got $EDIT_CALLS"
fi
if grep -q "decomposed issue #130 into 3 subtasks" "$WORK/err14.txt" 2>/dev/null; then
    pass "run 14 (decompose): logged the 3-subtask decomposition"
else
    fail "run 14 (decompose): decomposed-into-3 log line" "err=$(tail -6 "$WORK/err14.txt" 2>/dev/null)"
fi
if git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-130:SUB_1.txt" 2>/dev/null \
   && git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-130:SUB_2.txt" 2>/dev/null \
   && git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-130:SUB_3.txt" 2>/dev/null; then
    pass "run 14 (decompose): all THREE subtask files in ONE pushed commit (same branch)"
else
    fail "run 14 (decompose): SUB_1.txt + SUB_2.txt + SUB_3.txt in pushed commit"
fi

# ===========================================================================
# Run 15 (#1254 backward-compat regression): a MULTI-LINE --task WITHOUT
# --decompose must be treated as ONE task (one edit invocation receiving the
# whole task), NOT split one-subtask-per-line. The production caller always
# sends a multi-line task_text, so this is the common path.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/15"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

CNT_FILE5="$WORK/fc-attempt-count-5"; rm -f "$CNT_FILE5"
CMD_LOG="$WORK/fc-cmdfile-5.log"; rm -f "$CMD_LOG"
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
CWD=""; CMDF=""
while [ \$# -gt 0 ]; do case "\$1" in --cwd) CWD="\$2"; shift 2 ;; --cmd-file) CMDF="\$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
n=\$(cat "$CNT_FILE5" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$CNT_FILE5"
[ -n "\$CMDF" ] && cat "\$CMDF" >> "$CMD_LOG"
printf 'edit %s\n' "\$n" > "\$CWD/EDIT.txt"
exit 0
STUB_EOF
chmod +x "$STUB_BIN/flat-cyborg"

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

MULTI_TASK="$(printf 'Line one of the task.\nLine two of the task.\nLine three of the task.')"
OUT15_FILE="$WORK/out15.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 140 \
        --branch "fix/issue-140" --title "multi-line task" \
        --task "$MULTI_TASK" >"$OUT15_FILE" 2>"$WORK/err15.txt"
RC15=$?
EDITS5="$(cat "$CNT_FILE5" 2>/dev/null || echo 0)"

if [ "$RC15" -eq 0 ] && [ "$EDITS5" = "1" ]; then
    pass "run 15 (multi-line no-decompose): ONE edit invocation (task not split per line)"
else
    fail "run 15 (multi-line no-decompose): expected exactly 1 edit invocation" "rc=$RC15 edits=$EDITS5 err=$(tail -3 "$WORK/err15.txt" 2>/dev/null)"
fi
if grep -q "Line one of the task" "$CMD_LOG" 2>/dev/null && grep -q "Line two of the task" "$CMD_LOG" 2>/dev/null && grep -q "Line three of the task" "$CMD_LOG" 2>/dev/null; then
    pass "run 15 (multi-line no-decompose): the WHOLE multi-line task reached claude in one drive"
else
    fail "run 15 (multi-line no-decompose): whole task in the prompt" "cmdlog=$(tail -8 "$CMD_LOG" 2>/dev/null)"
fi
if grep -q "decomposed issue" "$WORK/err15.txt" 2>/dev/null; then
    fail "run 15 (multi-line no-decompose): wrongly decomposed a non --decompose run"
else
    pass "run 15 (multi-line no-decompose): did NOT decompose (no --decompose flag)"
fi

# ===========================================================================
# Run 16 (#1262 light verify gate): with NO CODE_EDIT_VERIFY_CMD (and no fast
# project gate in the WS), the built-in light gate runs — it executes any
# changed test-*.sh. The stub writes a test-*.sh that EXITS 1 on attempt 1
# (light gate fails -> feed back) then EXITS 0 on attempt 2 (passes -> commit).
# Proves the light gate runs change-scoped checks + iterates, without the heavy
# full-repo lint.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/16"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

CNT_FILE6="$WORK/fc-attempt-count-6"; rm -f "$CNT_FILE6"
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
CWD=""
while [ \$# -gt 0 ]; do case "\$1" in --cwd) CWD="\$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
n=\$(cat "$CNT_FILE6" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$CNT_FILE6"
# A changed test-*.sh that the light gate will RUN. Attempt 1 exits 1 (gate
# fails); attempt 2 exits 0 (gate passes). Both are shellcheck-clean.
if [ "\$n" -eq 1 ]; then
    printf '#!/usr/bin/env sh\nexit 1\n' > "\$CWD/test-lvprobe.sh"
else
    printf '#!/usr/bin/env sh\nexit 0\n' > "\$CWD/test-lvprobe.sh"
fi
exit 0
STUB_EOF
chmod +x "$STUB_BIN/flat-cyborg"

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

OUT16_FILE="$WORK/out16.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    CODE_EDIT_MAX_ATTEMPTS=3 \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 150 \
        --branch "fix/issue-150" --title "light gate" \
        --task "Add a test." >"$OUT16_FILE" 2>"$WORK/err16.txt"
RC16=$?
ATTEMPTS6="$(cat "$CNT_FILE6" 2>/dev/null || echo 0)"

if [ "$RC16" -eq 0 ] && [ "$(cat "$OUT16_FILE")" = "https://example.test/pr/16" ]; then
    pass "run 16 (light gate): exits 0 + opens PR after the light gate passes"
else
    fail "run 16 (light gate): exit 0 + PR url" "rc=$RC16 out=$(cat "$OUT16_FILE" 2>/dev/null) err=$(tail -4 "$WORK/err16.txt" 2>/dev/null)"
fi
if [ "$ATTEMPTS6" = "2" ]; then
    pass "run 16 (light gate): iterated after the light gate failed (ran the changed test-*.sh twice)"
else
    fail "run 16 (light gate): expected 2 attempts" "got $ATTEMPTS6"
fi
if grep -q "light change-scoped gate" "$WORK/err16.txt" 2>/dev/null && grep -q "verification PASSED" "$WORK/err16.txt" 2>/dev/null; then
    pass "run 16 (light gate): used the built-in light gate (not full colony-lint) and PASSED on retry"
else
    fail "run 16 (light gate): light-gate + PASSED log lines" "err=$(tail -6 "$WORK/err16.txt" 2>/dev/null)"
fi
if git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-150:test-lvprobe.sh" 2>/dev/null; then
    pass "run 16 (light gate): committed only after the changed test passed"
else
    fail "run 16 (light gate): test-lvprobe.sh in pushed commit"
fi

# ===========================================================================
# Run 17 (#1316): normalize_title's 72-char cap must land on a UTF-8 CHARACTER
# boundary, not a byte boundary. `cut -c` is char-aware only under a UTF-8
# locale; under C/POSIX it counts bytes, so a multibyte char straddling byte 72
# could be sliced into invalid UTF-8 the forge JSON API rejects. The fix forces
# LC_ALL=C.UTF-8 on the cut. Drive the orchestrator under LC_ALL=C with an
# 80-char title whose 72nd character is a 2-byte 'é' (bytes 72-73) and assert
# the resulting PR title + commit subject are valid UTF-8 and capped at 72 chars.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
TITLE17_FILE="$WORK/title17.txt"; rm -f "$TITLE17_FILE"
# Stub github-api.sh: record the raw --title bytes (no newline) so the test can
# validate the exact PR title the orchestrator emitted.
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
shift  # drop the verb (create-mr)
T=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --title) T="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s' "\$T" > "$TITLE17_FILE"
printf '%s\n' '{"html_url": "https://example.test/pr/17", "number": 17}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"
# Reset flat-cyborg to the plain edit stub (run 16 replaced it with a counter).
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
CWD=""
while [ \$# -gt 0 ]; do case "\$1" in --cwd) CWD="\$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
[ -n "\$CWD" ] && printf 'generated by claude\n' > "\$CWD/NEWFILE.txt"
exit 0
STUB_EOF
chmod +x "$STUB_BIN/flat-cyborg"

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

# 80-char title: "fix: " (5) + 66 'a' (-> 71 ASCII chars) + 'é' (char 72,
# bytes 72-73) + "bbbbbbbb". 'é' is built from raw bytes (0xC3 0xA9) so the
# test does not depend on its own source encoding. Already conventional
# ("fix:") so normalize_title does not prepend another type prefix.
FILL17="$(printf '%66s' '' | tr ' ' a)"
EACUTE17="$(printf '\303\251')"
MB_TITLE17="fix: ${FILL17}${EACUTE17}bbbbbbbb"

OUT17_FILE="$WORK/out17.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    LC_ALL=C \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 1316 \
        --branch "fix/issue-1316" --title "$MB_TITLE17" \
        --task "Create NEWFILE.txt." >"$OUT17_FILE" 2>"$WORK/err17.txt"
RC17=$?

if [ "$RC17" -eq 0 ]; then
    pass "run 17 (#1316): orchestrator exits 0 with a long multibyte title under LC_ALL=C"
else
    fail "run 17 (#1316): orchestrator exit 0 under LC_ALL=C" "rc=$RC17 err=$(tail -4 "$WORK/err17.txt" 2>/dev/null)"
fi

# The emitted PR title must be valid UTF-8 AND exactly 72 characters — proving
# the cut landed on the char boundary (keeping the whole 'é') and not byte 72
# (which would leave a lone 0xC3 -> invalid UTF-8).
TITLE17_CHECK="$(python3 -c 'import sys
d = open(sys.argv[1], "rb").read()
try:
    s = d.decode("utf-8")
except UnicodeDecodeError:
    print("INVALID"); raise SystemExit
print("VALID %d" % len(s))' "$TITLE17_FILE" 2>/dev/null)"
if [ "$TITLE17_CHECK" = "VALID 72" ]; then
    pass "run 17 (#1316): PR title cut on a UTF-8 char boundary (valid UTF-8, 72 chars) despite LC_ALL=C"
else
    fail "run 17 (#1316): PR title must be valid UTF-8 capped at 72 chars under LC_ALL=C" \
        "got [$TITLE17_CHECK] bytes=[$(od -An -tx1 "$TITLE17_FILE" 2>/dev/null | tr -d '\n')]"
fi

# The committed commit subject (capped title + " (#1316)") must also decode as
# UTF-8 — a sliced 'é' would corrupt it too.
git --git-dir="$BARE" log -1 --pretty=%s refs/heads/fix/issue-1316 > "$WORK/commit17.txt" 2>/dev/null
COMMIT17_CHECK="$(python3 -c 'import sys
d = open(sys.argv[1], "rb").read().rstrip(b"\n")
try:
    d.decode("utf-8"); print("VALID")
except UnicodeDecodeError:
    print("INVALID")' "$WORK/commit17.txt" 2>/dev/null)"
if [ "$COMMIT17_CHECK" = "VALID" ]; then
    pass "run 17 (#1316): committed commit subject is valid UTF-8 under LC_ALL=C"
else
    fail "run 17 (#1316): commit subject must be valid UTF-8" \
        "bytes=[$(od -An -tx1 "$WORK/commit17.txt" 2>/dev/null | tr -d '\n')]"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
