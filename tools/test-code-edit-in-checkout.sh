#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # This test deliberately scopes PATH inside
# subshells (run 21 simulates stock macOS with no timeout/gtimeout) and via
# `env PATH=…` per-command prefixes (#1343 oauth-token cases). shellcheck's
# info-level "PATH modified in a subshell / might be lost" notes are false
# positives here — every such PATH is intentionally command- or subshell-local.
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

# #1349: the orchestrator no longer summarises the diff in shell (the #1347
# gen-mr-description.sh path was reverted). The reviewer-facing body is threaded
# in from the agent via --description; when absent (as in the default run_orch
# below) the body deterministically falls back to the static `Closes #N`
# template these tests assert. The threaded/verbatim + fallback paths get their
# own dedicated scenario near the end of this harness.

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

# ===========================================================================
# Run 18 (#1349): the agent-drafted PR/MR body is threaded through --description
# and used VERBATIM (with `Closes #<iid>` appended); when no --description is
# given the orchestrator still falls back to the static template. A dedicated
# github-api.sh stub records the FULL description body it received.
# ===========================================================================
DESC_LOG="$WORK/desc-body.log"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
if [ "\${1:-}" != "create-mr" ]; then
    echo "stub github-api.sh: unexpected verb \${1:-}" >&2
    exit 1
fi
shift
DESC=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --source) shift 2 ;;
        --title) shift 2 ;;
        --description) DESC="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s' "\$DESC" > "$DESC_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/1349", "number": 1349}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

# 18a: a supplied --description is used verbatim as the body, + `Closes #<iid>`.
DESC_CUSTOM="This change threads the agent-drafted summary into the PR body.
It replaces the static template so a reviewer sees the real explanation."
: > "$DESC_LOG"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE=edit \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 1349 \
        --branch "fix/issue-1349" --title "thread draft summary into pr description" \
        --description "$DESC_CUSTOM" \
        --task "Create NEWFILE.txt with a greeting." >"$WORK/out18a.txt" 2>"$WORK/err18a.txt"

EXPECT_DESC_A="$DESC_CUSTOM

Closes #1349"
if [ "$(cat "$DESC_LOG" 2>/dev/null)" = "$EXPECT_DESC_A" ]; then
    pass "run 18a (#1349): supplied --description is used verbatim as the PR body (+ Closes #<iid>)"
else
    fail "run 18a (#1349): --description used verbatim (+ Closes)" \
        "got=[$(cat "$DESC_LOG" 2>/dev/null)]"
fi

# 18b: with NO --description the static template still applies.
: > "$DESC_LOG"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE=edit \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 1350 \
        --branch "fix/issue-1350" --title "no description supplied" \
        --task "Create NEWFILE.txt with a greeting." >"$WORK/out18b.txt" 2>"$WORK/err18b.txt"

EXPECT_DESC_B="Closes #1350.

Autonomously implemented by the dev-apprenticeship federation."
if [ "$(cat "$DESC_LOG" 2>/dev/null)" = "$EXPECT_DESC_B" ]; then
    pass "run 18b (#1349): the static template body still applies when no --description is given"
else
    fail "run 18b (#1349): static template fallback" \
        "got=[$(cat "$DESC_LOG" 2>/dev/null)]"
fi

# ===========================================================================
# Run 19 (#1346): a verify gate that exits 127 (command missing/unrunnable —
# e.g. `npm test` on a fresh clone with no node_modules) is NOT a code failure.
# The loop must treat it as UNVERIFIABLE: stop immediately (NO re-invocation of
# the editing agent, so it can't undo its own correct edit chasing an env gap)
# and commit the diff anyway (the PR's own CI is the authoritative gate). Drive
# the orchestrator with CODE_EDIT_VERIFY_CMD set to a missing binary (a real
# exit 127) and MAX_ATTEMPTS=3; assert exactly ONE flat-cyborg invocation, the
# exit-127/UNVERIFIABLE log line (no "verification FAILED" feed-back), exit 0 +
# PR url, and the edit present in the pushed commit.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/19"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

CNT_FILE19="$WORK/fc-attempt-count-19"; rm -f "$CNT_FILE19"
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
CWD=""
while [ \$# -gt 0 ]; do case "\$1" in --cwd) CWD="\$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
n=\$(cat "$CNT_FILE19" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$CNT_FILE19"
printf 'work %s\n' "\$n" > "\$CWD/WORK_19.txt"
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

OUT19_FILE="$WORK/out19.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    CODE_EDIT_MAX_ATTEMPTS=3 \
    CODE_EDIT_VERIFY_CMD="this_binary_definitely_missing_1346" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 1346 \
        --branch "fix/issue-1346" --title "exit 127 is unverifiable" \
        --task "Add work." >"$OUT19_FILE" 2>"$WORK/err19.txt"
RC19=$?
ATTEMPTS19="$(cat "$CNT_FILE19" 2>/dev/null || echo 0)"

if [ "$ATTEMPTS19" = "1" ]; then
    pass "run 19 (#1346 exit 127): stopped after ONE attempt (no re-invocation of the editing agent on an unverifiable env gap)"
else
    fail "run 19 (#1346 exit 127): expected exactly 1 attempt" "got $ATTEMPTS19 (rc=$RC19)"
fi
if grep -q "UNVERIFIABLE" "$WORK/err19.txt" 2>/dev/null && grep -q "exit 127" "$WORK/err19.txt" 2>/dev/null; then
    pass "run 19 (#1346 exit 127): logged the UNVERIFIABLE / exit-127 message"
else
    fail "run 19 (#1346 exit 127): UNVERIFIABLE + exit-127 log line" "err=$(tail -6 "$WORK/err19.txt" 2>/dev/null)"
fi
if grep -q "verification FAILED" "$WORK/err19.txt" 2>/dev/null; then
    fail "run 19 (#1346 exit 127): must NOT feed a 127 back as a failure" "err=$(tail -6 "$WORK/err19.txt" 2>/dev/null)"
else
    pass "run 19 (#1346 exit 127): did NOT feed the 127 back as a 'fix this failure' iteration"
fi
if [ "$RC19" -eq 0 ] && [ "$(cat "$OUT19_FILE")" = "https://example.test/pr/19" ]; then
    pass "run 19 (#1346 exit 127): exit 0 + opened PR (kept the edit; CI is the authoritative gate)"
else
    fail "run 19 (#1346 exit 127): exit 0 + PR url" "rc=$RC19 out=$(cat "$OUT19_FILE" 2>/dev/null) err=$(tail -4 "$WORK/err19.txt" 2>/dev/null)"
fi
if git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-1346:WORK_19.txt" 2>/dev/null; then
    pass "run 19 (#1346 exit 127): committed the edit despite the unverifiable gate"
else
    fail "run 19 (#1346 exit 127): WORK_19.txt in pushed commit"
fi

# ===========================================================================
# Run 20 (#1346): when package.json declares a `test` script but node_modules/
# is ABSENT (fresh clone, deps not installed), detect_verify_cmd must NOT pick
# `npm test` (which would exit 127 on the missing runner) — it falls through to
# the built-in light change-scoped gate. Seed a package.json with a `test`
# script (and no node_modules), have the stub make a plain edit, and assert the
# run used the light gate (not `npm test`), passed, exit 0, and opened the PR.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/20"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

CNT_FILE20="$WORK/fc-attempt-count-20"; rm -f "$CNT_FILE20"
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
CWD=""
while [ \$# -gt 0 ]; do case "\$1" in --cwd) CWD="\$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
n=\$(cat "$CNT_FILE20" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$CNT_FILE20"
printf 'work %s\n' "\$n" > "\$CWD/WORK_20.txt"
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
    printf '{\n  "name": "widget",\n  "scripts": { "test": "vitest run" }\n}\n' > package.json
    git add -A
    git commit --quiet -m "seed: initial commit"
    git branch -M main 2>/dev/null || true
    git remote add origin "$BARE"
    git push --quiet origin main
)
git --git-dir="$BARE" symbolic-ref HEAD refs/heads/main

OUT20_FILE="$WORK/out20.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    CODE_EDIT_MAX_ATTEMPTS=2 \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 1347 \
        --branch "fix/issue-1347" --title "no node_modules falls through to light gate" \
        --task "Add work." >"$OUT20_FILE" 2>"$WORK/err20.txt"
RC20=$?

if grep -q "light change-scoped gate" "$WORK/err20.txt" 2>/dev/null; then
    pass "run 20 (#1346 no node_modules): detect_verify_cmd fell through to the light gate"
else
    fail "run 20 (#1346 no node_modules): expected the light change-scoped gate" "err=$(tail -6 "$WORK/err20.txt" 2>/dev/null)"
fi
if grep -q "npm test" "$WORK/err20.txt" 2>/dev/null; then
    fail "run 20 (#1346 no node_modules): must NOT auto-select npm test without node_modules" "err=$(tail -6 "$WORK/err20.txt" 2>/dev/null)"
else
    pass "run 20 (#1346 no node_modules): did NOT auto-select npm test on a deps-less clone"
fi
if [ "$RC20" -eq 0 ] && [ "$(cat "$OUT20_FILE")" = "https://example.test/pr/20" ]; then
    pass "run 20 (#1346 no node_modules): exit 0 + opened PR via the light gate"
else
    fail "run 20 (#1346 no node_modules): exit 0 + PR url" "rc=$RC20 out=$(cat "$OUT20_FILE" 2>/dev/null) err=$(tail -4 "$WORK/err20.txt" 2>/dev/null)"
fi

# ===========================================================================
# Run 21 (#1342 portable timeout): stock macOS ships NO `timeout` binary, and
# the old verify paths dropped the time bound entirely when `timeout` was
# absent — so a watch-mode verify command selected as the project gate hung the
# detached job forever. The fix routes both verify code paths through the
# portable `run_bounded` helper (timeout -> gtimeout -> background kill-watchdog).
# Extract that helper from the orchestrator, simulate stock macOS by running it
# under a PATH that has neither `timeout` nor `gtimeout`, feed it a deliberately
# non-terminating command, and assert it is still KILLED within the bound
# (returns timeout's 124, and wall-clock stays far under the command's runtime).
# ===========================================================================
if ! command -v sleep >/dev/null 2>&1; then
    echo "[SKIP] run 21 (#1342 portable timeout): sleep not on PATH"
else
    RB_SRC="$WORK/run_bounded.sh"
    awk '/^run_bounded\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ORCH" > "$RB_SRC"
    if ! grep -q '^run_bounded() {' "$RB_SRC" || ! grep -q '^}' "$RB_SRC"; then
        fail "run 21 (#1342 portable timeout): could not extract run_bounded from orchestrator"
    else
        # A PATH that hides timeout/gtimeout but keeps the few binaries the
        # watchdog fallback + the test command need (sleep/sh/env). command -v
        # inside run_bounded then falls through both to the kill-watchdog.
        RB_BIN="$WORK/run21-bin"; rm -rf "$RB_BIN"; mkdir -p "$RB_BIN"
        for _b in sleep sh env; do
            _p="$(command -v "$_b" 2>/dev/null)" && ln -sf "$_p" "$RB_BIN/$_b"
        done

        # shellcheck disable=SC1090
        . "$RB_SRC"

        # CODE_EDIT_VERIFY_TIMEOUT_MS -> seconds exactly as run_verify computes it.
        RB_MS=1000
        RB_S=$(( RB_MS / 1000 )); [ "$RB_S" -lt 1 ] && RB_S=1
        RB_START="$(date +%s)"
        ( PATH="$RB_BIN"; export PATH; run_bounded "$RB_S" sleep 3600 ) \
            >/dev/null 2>"$WORK/run21-err.txt"
        RB_RC=$?
        RB_END="$(date +%s)"
        RB_ELAPSED=$(( RB_END - RB_START ))

        # Prove the simulated environment really had no timeout/gtimeout, so the
        # watchdog (not a real timeout binary) is what enforced the bound.
        if ( PATH="$RB_BIN"; command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 ); then
            fail "run 21 (#1342 portable timeout): PATH sandbox still exposes timeout/gtimeout" "not a valid macOS simulation"
        else
            pass "run 21 (#1342 portable timeout): simulated stock macOS (no timeout, no gtimeout on PATH)"
        fi

        # The command asks to sleep an hour; the watchdog must kill it in ~1s. A
        # generous 60s wall-clock ceiling proves it did NOT run unbounded while
        # tolerating CI load.
        if [ "$RB_ELAPSED" -le 60 ]; then
            pass "run 21 (#1342 portable timeout): non-terminating verify command was killed within the bound (${RB_ELAPSED}s)"
        else
            fail "run 21 (#1342 portable timeout): watchdog did not kill the unbounded command" "elapsed=${RB_ELAPSED}s rc=$RB_RC"
        fi

        # timeout(1) returns 124 on a kill; run_bounded normalises its watchdog
        # kill to the same code.
        if [ "$RB_RC" -eq 124 ]; then
            pass "run 21 (#1342 portable timeout): returned 124 (timeout convention) on the watchdog kill"
        else
            fail "run 21 (#1342 portable timeout): expected rc 124 from the watchdog kill" "rc=$RB_RC"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Run 22 (#1344 raised editing-session idle window). The editing sessions run
# claude at xhigh extended thinking, whose mid-reply pauses run LONGER than a
# normal reasoning/draft session; under concurrent multi-agent load a heavy edit
# stalls for tens of seconds. The general flat-cyborg-claude.sh default idle
# window is 30000ms, but the editing invocations here MUST override it to a
# larger ~45000ms so a settle pause is not screen-scraped as a partial reply
# (which truncates the diff / empties the result). Statically assert every
# flat-cyborg editing invocation in the orchestrator defaults --idle-ms to
# 45000, and that no invocation regressed to the retired 8000ms window.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # the ${...} is a literal grep pattern, not a shell expansion
IDLE_INVOCATIONS="$(grep -cF -- '--idle-ms "${FLAT_CYBORG_IDLE_MS:-45000}"' "$ORCH" 2>/dev/null || true)"
if [ "${IDLE_INVOCATIONS:-0}" -ge 2 ]; then
    pass "run 22 (#1344 editing idle): all editing-session invocations default --idle-ms to 45000 (found $IDLE_INVOCATIONS)"
else
    fail "run 22 (#1344 editing idle): editing-session --idle-ms default not raised to 45000" "matches=${IDLE_INVOCATIONS:-0} (expected >= 2)"
fi
if grep -qF -- 'FLAT_CYBORG_IDLE_MS:-8000' "$ORCH" 2>/dev/null; then
    fail "run 22 (#1344 editing idle): orchestrator still carries the retired 8000ms idle default"
else
    pass "run 22 (#1344 editing idle): no editing invocation regressed to the retired 8000ms window"
fi

# ---------------------------------------------------------------------------
# Run 23 (#1343 macOS Keychain sidestep). The editing claude session that the
# orchestrator spawns via flat-cyborg crosses the agentis `exec` boundary, so on
# macOS it cannot read the login Keychain and comes up "Not logged in". The fix
# reads a long-lived `claude setup-token` token from a gitignored file named by
# CLAUDE_OAUTH_TOKEN_FILE and exports it as CLAUDE_CODE_OAUTH_TOKEN before
# spawning flat-cyborg. Assert:
#   (a) with CLAUDE_OAUTH_TOKEN_FILE pointing at a populated file, the token
#       reaches flat-cyborg's environment as CLAUDE_CODE_OAUTH_TOKEN, and
#   (b) with the file ABSENT, CLAUDE_CODE_OAUTH_TOKEN stays UNSET — the
#       regression guard that keeps existing Linux hosts (no token file) on
#       their inherited credential path unchanged.
# ---------------------------------------------------------------------------
OAUTH_FAKE_TOKEN="sk-ant-oat01-FAKE_SETUP_TOKEN_1343_do_not_leak"

# Fresh harness for run 23, plus a flat-cyborg stub that records the editing
# session's inherited CLAUDE_CODE_OAUTH_TOKEN to FC_OAUTH_LOG. The stub ALWAYS
# writes an "invoked" marker (so an absent-token run still yields a NON-EMPTY
# log — distinguishing "reached flat-cyborg without the token" from "never
# reached it") and appends the token line only when the env var is present.
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/23"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

FC_OAUTH_LOG="$WORK/fc-oauth-env.log"
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
printf 'invoked\n' >> "$FC_OAUTH_LOG"
if [ -n "\${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "\$CLAUDE_CODE_OAUTH_TOKEN" >> "$FC_OAUTH_LOG"
fi
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

# Each sub-run uses a DISTINCT issue/branch so a successful first PR never leaves
# a diverged remote branch that would trip the next push (flat-cyborg — and thus
# the OAuth env capture — already runs before any push, but distinct branches
# keep the run robust regardless of the downstream git outcome).

# (a) populated token file -> exported into flat-cyborg's env.
OAUTH_FILE_POPULATED="$WORK/oauth-token-present"
printf '%s\n' "$OAUTH_FAKE_TOKEN" > "$OAUTH_FILE_POPULATED"
: > "$FC_OAUTH_LOG"
env -u CLAUDE_CODE_OAUTH_TOKEN \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE=edit FC_STUB_RC=0 \
    CLAUDE_OAUTH_TOKEN_FILE="$OAUTH_FILE_POPULATED" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 4200 \
        --branch "fix/issue-4200" --title "add new file" \
        --task "Create NEWFILE.txt with a greeting." >/dev/null 2>&1 || true

if grep -qF "CLAUDE_CODE_OAUTH_TOKEN=$OAUTH_FAKE_TOKEN" "$FC_OAUTH_LOG"; then
    pass "run 23 (#1343 macOS keychain): token file exported as CLAUDE_CODE_OAUTH_TOKEN into flat-cyborg env"
else
    fail "run 23 (#1343 macOS keychain): CLAUDE_CODE_OAUTH_TOKEN not exported from populated token file" "log=[$(cat "$FC_OAUTH_LOG" 2>/dev/null)]"
fi

# The exported token is a credential and must never leak onto the orchestrator's
# stdout/stderr (mirrors the forge-token no-leak guard). The diagnostic the
# orchestrator prints names only the FILE PATH, never the token value.
: > "$FC_OAUTH_LOG"
OAUTH_LEAK_OUT="$WORK/oauth-leak.txt"
env -u CLAUDE_CODE_OAUTH_TOKEN \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE=edit FC_STUB_RC=0 \
    CLAUDE_OAUTH_TOKEN_FILE="$OAUTH_FILE_POPULATED" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 4201 \
        --branch "fix/issue-4201" --title "add new file" \
        --task "Create NEWFILE.txt with a greeting." >"$OAUTH_LEAK_OUT" 2>&1 || true
if grep -qF "$OAUTH_FAKE_TOKEN" "$OAUTH_LEAK_OUT"; then
    fail "run 23 (#1343 macOS keychain): OAuth token LEAKED into orchestrator stdout/stderr"
else
    pass "run 23 (#1343 macOS keychain): OAuth token never appears in orchestrator stdout/stderr"
fi

# (b) absent token file -> CLAUDE_CODE_OAUTH_TOKEN stays unset (Linux regression
# guard). Pointing CLAUDE_OAUTH_TOKEN_FILE at a nonexistent path reproduces a
# stock Linux host that never provisioned a token; the stub still logs its
# "invoked" marker, so a non-empty log with NO token line proves the export was
# correctly skipped (rather than the orchestrator never reaching flat-cyborg).
OAUTH_FILE_ABSENT="$WORK/oauth-token-absent"
rm -f "$OAUTH_FILE_ABSENT"
: > "$FC_OAUTH_LOG"
env -u CLAUDE_CODE_OAUTH_TOKEN \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE=edit FC_STUB_RC=0 \
    CLAUDE_OAUTH_TOKEN_FILE="$OAUTH_FILE_ABSENT" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 4202 \
        --branch "fix/issue-4202" --title "add new file" \
        --task "Create NEWFILE.txt with a greeting." >/dev/null 2>&1 || true

if [ -s "$FC_OAUTH_LOG" ] && ! grep -qE '^CLAUDE_CODE_OAUTH_TOKEN=.+' "$FC_OAUTH_LOG"; then
    pass "run 23 (#1343 macOS keychain): absent token file leaves CLAUDE_CODE_OAUTH_TOKEN unset (Linux path unchanged)"
else
    fail "run 23 (#1343 macOS keychain): CLAUDE_CODE_OAUTH_TOKEN should be unset when the token file is absent" "log=[$(cat "$FC_OAUTH_LOG" 2>/dev/null)]"
fi

# ===========================================================================
# Run 24 (#1406 --one-attempt): the single-attempt primitive for the #1354
# caller-driven loop. --one-attempt must run EXACTLY ONE flat-cyborg editing
# drive in the prepared workspace (no internal retry/continue loop), never
# commit/push/open a PR, and report a structured outcome as the SINGLE stdout
# line: `ONE_ATTEMPT exit=<code> churn=<staged-lines> verify=<outcome>`.
# --continuation <file> supplies the editing prompt VERBATIM in place of the
# default task template. The default (no-flag) path must keep its multi-attempt
# commit -> push -> PR behaviour unchanged. Sub-runs:
#   24a  successful edit + explicit passing gate -> exit=0 churn=1 verify=pass,
#        one invocation, no commit/push/PR
#   24b  zero-churn timeout -> exit=124 churn=0 verify=skipped
#   24c  --continuation prompt reaches the stub verbatim (default template
#        absent); timeout WITH progress still does NOT re-drive (the default
#        loop would) -> exit=124 churn=1, one invocation
#   24d  default (no flag) run: multi-attempt path unchanged (commit + push +
#        PR URL on stdout, no ONE_ATTEMPT line)
#   24e  failing gate maps to verify=fail with NO verify-fix re-drive
#   24f  gate exit 127 maps to verify=unverifiable (#1391 consistency)
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/24"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

# Counting stub: records every invocation + the cmd-file it was driven with,
# honours FC_STUB_MODE (edit|no-edit) and FC_STUB_RC, and on edit writes a
# one-line NEWFILE.txt (staged churn = exactly 1).
CNT_FILE24="$WORK/fc-attempt-count-24"
CMD_LOG24="$WORK/fc-cmdfile-24.log"
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
CWD=""; CMDF=""
while [ \$# -gt 0 ]; do case "\$1" in --cwd) CWD="\$2"; shift 2 ;; --cmd-file) CMDF="\$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
n=\$(cat "$CNT_FILE24" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$CNT_FILE24"
[ -n "\$CMDF" ] && cat "\$CMDF" >> "$CMD_LOG24"
if [ "\${FC_STUB_MODE:-edit}" = "edit" ] && [ -n "\$CWD" ]; then
    printf 'generated by claude\n' > "\$CWD/NEWFILE.txt"
fi
exit "\${FC_STUB_RC:-0}"
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

# --- 24a: successful edit + explicit passing gate ---------------------------
rm -f "$CNT_FILE24" "$CMD_LOG24" "$CREATE_MR_LOG"
OUT24A_FILE="$WORK/out24a.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE=edit FC_STUB_RC=0 \
    CODE_EDIT_MAX_ATTEMPTS=3 \
    CODE_EDIT_VERIFY_CMD="test -f NEWFILE.txt" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 240 \
        --branch "fix/issue-240" --title "one attempt success" \
        --task "Create NEWFILE.txt with a greeting." \
        --one-attempt >"$OUT24A_FILE" 2>"$WORK/err24a.txt"
RC24A=$?
if [ "$RC24A" -eq 0 ] && [ "$(cat "$OUT24A_FILE")" = "ONE_ATTEMPT exit=0 churn=1 verify=pass" ]; then
    pass "run 24a (#1406 one-attempt): ONE_ATTEMPT exit=0 churn=1 verify=pass is the single stdout line"
else
    fail "run 24a (#1406 one-attempt): structured outcome line" "rc=$RC24A stdout=[$(cat "$OUT24A_FILE" 2>/dev/null)] err=$(tail -3 "$WORK/err24a.txt" 2>/dev/null)"
fi
if [ "$(cat "$CNT_FILE24" 2>/dev/null || echo 0)" = "1" ]; then
    pass "run 24a (#1406 one-attempt): exactly ONE flat-cyborg invocation"
else
    fail "run 24a (#1406 one-attempt): expected exactly 1 invocation" "got $(cat "$CNT_FILE24" 2>/dev/null || echo 0)"
fi
if [ ! -f "$CREATE_MR_LOG" ] && ! git --git-dir="$BARE" rev-parse --verify --quiet refs/heads/fix/issue-240 >/dev/null; then
    pass "run 24a (#1406 one-attempt): no commit/push/PR (the caller-driven loop owns those)"
else
    fail "run 24a (#1406 one-attempt): must not push or open a PR" "create-mr=$([ -f "$CREATE_MR_LOG" ] && echo yes || echo no) branch=$(git --git-dir="$BARE" rev-parse --verify --quiet refs/heads/fix/issue-240 >/dev/null && echo pushed || echo absent)"
fi

# --- 24b: zero-churn timeout -> exit=124 churn=0 verify=skipped -------------
rm -f "$CNT_FILE24" "$CMD_LOG24"
OUT24B_FILE="$WORK/out24b.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE=no-edit FC_STUB_RC=124 \
    CODE_EDIT_MAX_ATTEMPTS=3 \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 241 \
        --branch "fix/issue-241" --title "one attempt timeout" \
        --task "Create NEWFILE.txt with a greeting." \
        --one-attempt >"$OUT24B_FILE" 2>"$WORK/err24b.txt"
RC24B=$?
if [ "$RC24B" -eq 0 ] && [ "$(cat "$OUT24B_FILE")" = "ONE_ATTEMPT exit=124 churn=0 verify=skipped" ]; then
    pass "run 24b (#1406 one-attempt): zero-churn timeout reports exit=124 churn=0 verify=skipped"
else
    fail "run 24b (#1406 one-attempt): zero-churn timeout outcome" "rc=$RC24B stdout=[$(cat "$OUT24B_FILE" 2>/dev/null)] err=$(tail -3 "$WORK/err24b.txt" 2>/dev/null)"
fi
if [ "$(cat "$CNT_FILE24" 2>/dev/null || echo 0)" = "1" ]; then
    pass "run 24b (#1406 one-attempt): timeout did not trigger an internal retry"
else
    fail "run 24b (#1406 one-attempt): expected exactly 1 invocation" "got $(cat "$CNT_FILE24" 2>/dev/null || echo 0)"
fi

# --- 24c: --continuation file is the prompt; timeout WITH progress still ----
# --- means ONE drive (the default loop would re-drive on progress) -----------
CONT24="$WORK/continuation-24.txt"
printf 'CONTINUE-MARKER-1406 line one.\nCONTINUE-MARKER-1406 line two: finish the remaining work.\n' > "$CONT24"
rm -f "$CNT_FILE24" "$CMD_LOG24"
OUT24C_FILE="$WORK/out24c.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE=edit FC_STUB_RC=124 \
    CODE_EDIT_MAX_ATTEMPTS=3 \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 242 \
        --branch "fix/issue-242" --title "one attempt continuation" \
        --task "Create NEWFILE.txt with a greeting." \
        --one-attempt --continuation "$CONT24" >"$OUT24C_FILE" 2>"$WORK/err24c.txt"
RC24C=$?
if grep -q "CONTINUE-MARKER-1406 line one" "$CMD_LOG24" 2>/dev/null \
   && grep -q "CONTINUE-MARKER-1406 line two" "$CMD_LOG24" 2>/dev/null; then
    pass "run 24c (#1406 one-attempt): --continuation file contents reached the stub as the prompt (verbatim, multi-line)"
else
    fail "run 24c (#1406 one-attempt): continuation prompt in cmd-file" "cmdlog=[$(cat "$CMD_LOG24" 2>/dev/null)]"
fi
if grep -q "Implement issue #242" "$CMD_LOG24" 2>/dev/null \
   || grep -q "Create NEWFILE.txt with a greeting" "$CMD_LOG24" 2>/dev/null; then
    fail "run 24c (#1406 one-attempt): default task template leaked into the continuation prompt" "cmdlog=[$(cat "$CMD_LOG24" 2>/dev/null)]"
else
    pass "run 24c (#1406 one-attempt): default task template NOT used when --continuation is given"
fi
if [ "$RC24C" -eq 0 ] && [ "$(cat "$OUT24C_FILE")" = "ONE_ATTEMPT exit=124 churn=1 verify=skipped" ] \
   && [ "$(cat "$CNT_FILE24" 2>/dev/null || echo 0)" = "1" ]; then
    pass "run 24c (#1406 one-attempt): timeout WITH progress still drove ONCE (exit=124 churn=1; default loop would re-drive)"
else
    fail "run 24c (#1406 one-attempt): one drive despite progress+timeout" "rc=$RC24C stdout=[$(cat "$OUT24C_FILE" 2>/dev/null)] attempts=$(cat "$CNT_FILE24" 2>/dev/null || echo 0)"
fi

# --- 24d: default (no --one-attempt) run keeps the multi-attempt path -------
rm -f "$CNT_FILE24" "$CMD_LOG24" "$CREATE_MR_LOG"
OUT24D_FILE="$WORK/out24d.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE=edit FC_STUB_RC=0 \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 243 \
        --branch "fix/issue-243" --title "default loop unchanged" \
        --task "Create NEWFILE.txt with a greeting." >"$OUT24D_FILE" 2>"$WORK/err24d.txt"
RC24D=$?
if [ "$RC24D" -eq 0 ] && [ "$(cat "$OUT24D_FILE")" = "https://example.test/pr/24" ] && [ -f "$CREATE_MR_LOG" ]; then
    pass "run 24d (#1406 default): no-flag run still commits + opens the PR (multi-attempt path unchanged)"
else
    fail "run 24d (#1406 default): commit + PR on the default path" "rc=$RC24D stdout=[$(cat "$OUT24D_FILE" 2>/dev/null)] err=$(tail -3 "$WORK/err24d.txt" 2>/dev/null)"
fi
if git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-243:NEWFILE.txt" 2>/dev/null; then
    pass "run 24d (#1406 default): edit committed + pushed on the default path"
else
    fail "run 24d (#1406 default): NEWFILE.txt in pushed commit"
fi
if grep -q "ONE_ATTEMPT" "$OUT24D_FILE" 2>/dev/null; then
    fail "run 24d (#1406 default): ONE_ATTEMPT line leaked into a default run's stdout" "stdout=[$(cat "$OUT24D_FILE" 2>/dev/null)]"
else
    pass "run 24d (#1406 default): no ONE_ATTEMPT line on the default path"
fi

# --- 24e: failing gate -> verify=fail, and NO verify-fix re-drive -----------
rm -f "$CNT_FILE24" "$CMD_LOG24"
OUT24E_FILE="$WORK/out24e.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE=edit FC_STUB_RC=0 \
    CODE_EDIT_MAX_ATTEMPTS=3 \
    CODE_EDIT_VERIFY_CMD="test -f MISSING_1406.marker" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 244 \
        --branch "fix/issue-244" --title "one attempt gate fails" \
        --task "Create NEWFILE.txt with a greeting." \
        --one-attempt >"$OUT24E_FILE" 2>"$WORK/err24e.txt"
RC24E=$?
if [ "$RC24E" -eq 0 ] && [ "$(cat "$OUT24E_FILE")" = "ONE_ATTEMPT exit=0 churn=1 verify=fail" ] \
   && [ "$(cat "$CNT_FILE24" 2>/dev/null || echo 0)" = "1" ]; then
    pass "run 24e (#1406 one-attempt): failing gate reports verify=fail with NO verify-fix re-drive"
else
    fail "run 24e (#1406 one-attempt): verify=fail mapping" "rc=$RC24E stdout=[$(cat "$OUT24E_FILE" 2>/dev/null)] attempts=$(cat "$CNT_FILE24" 2>/dev/null || echo 0)"
fi

# --- 24f: gate exit 127 -> verify=unverifiable (#1391 consistency) ----------
rm -f "$CNT_FILE24" "$CMD_LOG24"
OUT24F_FILE="$WORK/out24f.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_STUB_MODE=edit FC_STUB_RC=0 \
    CODE_EDIT_VERIFY_CMD="this_binary_definitely_missing_1406" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 245 \
        --branch "fix/issue-245" --title "one attempt unverifiable" \
        --task "Create NEWFILE.txt with a greeting." \
        --one-attempt >"$OUT24F_FILE" 2>"$WORK/err24f.txt"
RC24F=$?
if [ "$RC24F" -eq 0 ] && [ "$(cat "$OUT24F_FILE")" = "ONE_ATTEMPT exit=0 churn=1 verify=unverifiable" ]; then
    pass "run 24f (#1406 one-attempt): gate exit 127 maps to verify=unverifiable (#1391)"
else
    fail "run 24f (#1406 one-attempt): verify=unverifiable mapping" "rc=$RC24F stdout=[$(cat "$OUT24F_FILE" 2>/dev/null)] err=$(tail -3 "$WORK/err24f.txt" 2>/dev/null)"
fi

# ===========================================================================
# Run 25 (#1354 step 2a --reuse / --finalize): the caller-driven loop's two
# primitives on TOP of --one-attempt. Prove that a SEPARATE --one-attempt
# process with --reuse ACCUMULATES on the prior attempt's diff (instead of
# resetting to main), and that --finalize commits the accumulated diff + opens
# the PR without any editing.
#
# Distinct-file stub: attempt 1 uses the default stub (writes NEWFILE.txt),
# attempt 2 uses this stub (writes NEWFILE2.txt). If --reuse kept attempt 1's
# diff, attempt 2's churn is 2 (both files) and the finalized branch carries
# BOTH files; a reset-to-main would have churn 1 and only NEWFILE2.txt.
# ===========================================================================
STUB_BIN2="$WORK/bin2"
mkdir -p "$STUB_BIN2"
cat > "$STUB_BIN2/flat-cyborg" <<'STUB2_EOF'
#!/usr/bin/env bash
set -eu
CWD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cwd) CWD="$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
[ -n "$CWD" ] && printf 'second attempt content\n' > "$CWD/NEWFILE2.txt"
exit 0
STUB2_EOF
chmod +x "$STUB_BIN2/flat-cyborg"

REUSE_ISSUE=77
REUSE_BRANCH="fix/issue-77"
CONT_FILE="$WORK/cont-77.txt"
printf 'Continue the change: also add NEWFILE2.txt.\n' > "$CONT_FILE"

# Attempt 1 — fresh --one-attempt (default stub writes NEWFILE.txt).
OUT25A="$WORK/out25a.txt"
env PATH="$STUB_BIN:$PATH" COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" FC_STUB_MODE=edit FC_STUB_RC=0 \
    CODE_EDIT_VERIFY_CMD=true \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue "$REUSE_ISSUE" \
        --branch "$REUSE_BRANCH" --title "reuse/finalize primitives" \
        --task "Create NEWFILE.txt." --one-attempt >"$OUT25A" 2>"$WORK/err25a.txt"
RC25A=$?
if [ "$RC25A" -eq 0 ] && [ "$(cat "$OUT25A")" = "ONE_ATTEMPT exit=0 churn=1 verify=skipped" ]; then
    pass "run 25a (#1354 --one-attempt): attempt 1 churn=1"
else
    fail "run 25a (#1354): attempt 1" "rc=$RC25A stdout=[$(cat "$OUT25A")] err=$(tail -3 "$WORK/err25a.txt")"
fi

# Attempt 2 — --one-attempt --reuse --continuation (stub2 writes NEWFILE2.txt).
# churn 2 == both files present == --reuse kept attempt 1's diff.
OUT25B="$WORK/out25b.txt"
env PATH="$STUB_BIN2:$PATH" COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" FC_STUB_RC=0 \
    CODE_EDIT_VERIFY_CMD=true \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue "$REUSE_ISSUE" \
        --branch "$REUSE_BRANCH" --title "reuse/finalize primitives" \
        --task "Create NEWFILE.txt." --one-attempt --reuse \
        --continuation "$CONT_FILE" >"$OUT25B" 2>"$WORK/err25b.txt"
RC25B=$?
if [ "$RC25B" -eq 0 ] && [ "$(cat "$OUT25B")" = "ONE_ATTEMPT exit=0 churn=2 verify=skipped" ]; then
    pass "run 25b (#1354 --reuse): attempt 2 ACCUMULATES on attempt 1 (churn 1->2)"
else
    fail "run 25b (#1354 --reuse): expected accumulated churn=2" "rc=$RC25B stdout=[$(cat "$OUT25B")] err=$(tail -3 "$WORK/err25b.txt")"
fi

# Finalize — no editing, commit the accumulated diff + open the PR.
OUT25C="$WORK/out25c.txt"
env PATH="$STUB_BIN:$PATH" COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue "$REUSE_ISSUE" \
        --branch "$REUSE_BRANCH" --title "reuse/finalize primitives" \
        --task "Create NEWFILE.txt." --finalize >"$OUT25C" 2>"$WORK/err25c.txt"
RC25C=$?
case "$(cat "$OUT25C")" in
    https://example.test/pr/*) OK25C=1 ;;
    *) OK25C=0 ;;
esac
if [ "$RC25C" -eq 0 ] && [ "$OK25C" -eq 1 ]; then
    pass "run 25c (#1354 --finalize): commits accumulated diff + opens PR (URL on stdout)"
else
    fail "run 25c (#1354 --finalize): PR URL on stdout" "rc=$RC25C stdout=[$(cat "$OUT25C")] err=$(tail -3 "$WORK/err25c.txt")"
fi

# The pushed branch must carry BOTH files — the accumulation survived to the PR.
PUSHED_TREE="$(git --git-dir="$BARE" ls-tree -r --name-only "$REUSE_BRANCH" 2>/dev/null | sort | tr '\n' ' ')"
if printf '%s' "$PUSHED_TREE" | grep -q 'NEWFILE.txt' && printf '%s' "$PUSHED_TREE" | grep -q 'NEWFILE2.txt'; then
    pass "run 25d (#1354 --finalize): finalized branch carries BOTH accumulated files"
else
    fail "run 25d (#1354 --finalize): both files on pushed branch" "tree=[$PUSHED_TREE]"
fi

# ===========================================================================
# Run 26 (#1354 step 2a edge cases): validation + empty-finalize + no-branch.
# ===========================================================================
# 26a: --finalize + --one-attempt is a caller bug -> exit 2 (no workspace touched).
env COLONY_DIR="$COLONY_DIR" GITHUB_URL="file://$REMOTE_BASE" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue 78 --branch "fix/issue-78" \
        --title "x" --task "y" --finalize --one-attempt >"$WORK/out26a.txt" 2>&1
RC26A=$?
if [ "$RC26A" -eq 2 ]; then
    pass "run 26a (#1354): --finalize + --one-attempt rejected (exit 2)"
else
    fail "run 26a (#1354): expected exit 2" "rc=$RC26A $(tail -2 "$WORK/out26a.txt")"
fi

# 26b: --reuse with no prior attempt (no local branch) -> exit 2, not a silent
# fresh edit. Fresh issue 79, never driven.
env PATH="$STUB_BIN:$PATH" COLONY_DIR="$COLONY_DIR" GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" FC_STUB_MODE=edit \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue 79 --branch "fix/issue-79" \
        --title "x" --task "y" --one-attempt --reuse >"$WORK/out26b.txt" 2>&1
RC26B=$?
if [ "$RC26B" -eq 2 ]; then
    pass "run 26b (#1354): --reuse with no prior attempt rejected (exit 2)"
else
    fail "run 26b (#1354): expected exit 2" "rc=$RC26B $(tail -2 "$WORK/out26b.txt")"
fi

# 26c: --finalize on a branch with zero staged diff -> exit 3 NO_EDITS (never an
# empty PR). Drive one no-edit attempt (creates the branch, no diff), then finalize.
env PATH="$STUB_BIN:$PATH" COLONY_DIR="$COLONY_DIR" GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" FC_STUB_MODE=no-edit \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue 80 --branch "fix/issue-80" \
        --title "x" --task "y" --one-attempt >/dev/null 2>&1 || true
OUT26C="$WORK/out26c.txt"
env COLONY_DIR="$COLONY_DIR" GITHUB_URL="file://$REMOTE_BASE" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue 80 --branch "fix/issue-80" \
        --title "x" --task "y" --finalize >"$OUT26C" 2>"$WORK/err26c.txt"
RC26C=$?
if [ "$RC26C" -eq 3 ] && grep -q 'NO_EDITS' "$OUT26C"; then
    pass "run 26c (#1354 --finalize): empty diff -> exit 3 NO_EDITS (no empty PR)"
else
    fail "run 26c (#1354 --finalize): expected exit 3 NO_EDITS" "rc=$RC26C stdout=[$(cat "$OUT26C")] err=$(tail -3 "$WORK/err26c.txt")"
fi

# 26d: bare --reuse (no --one-attempt, no --finalize) is a caller footgun — it
# would silently run the whole in-shell multi-attempt loop + open a PR. Reject
# (exit 2) BEFORE any workspace touch. (QA #1419 F1.)
env PATH="$STUB_BIN:$PATH" COLONY_DIR="$COLONY_DIR" GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" FC_STUB_MODE=edit \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue 81 --branch "fix/issue-81" \
        --title "x" --task "y" --reuse >"$WORK/out26d.txt" 2>&1
RC26D=$?
if [ "$RC26D" -eq 2 ]; then
    pass "run 26d (#1354): bare --reuse (no --one-attempt/--finalize) rejected (exit 2)"
else
    fail "run 26d (#1354): expected exit 2" "rc=$RC26D $(tail -2 "$WORK/out26d.txt")"
fi

# 26e: --finalize --recover is nonsensical (recover has its own RECOVERED
# terminal path that suppresses the PR finalize is meant to open). Reject
# (exit 2). (QA #1419 F2.)
env COLONY_DIR="$COLONY_DIR" GITHUB_URL="file://$REMOTE_BASE" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue 82 --branch "fix/issue-82" \
        --title "x" --task "y" --finalize --recover >"$WORK/out26e.txt" 2>&1
RC26E=$?
if [ "$RC26E" -eq 2 ]; then
    pass "run 26e (#1354): --finalize + --recover rejected (exit 2)"
else
    fail "run 26e (#1354): expected exit 2" "rc=$RC26E $(tail -2 "$WORK/out26e.txt")"
fi

# ---------------------------------------------------------------------------
# Run 27 (#1444 CODE_EDIT_EFFORT). Every editing-session claude invocation
# (decompose, one-attempt, and the multi-attempt loop) must carry
# `--settings "$EFFORT_SETTINGS"` right after the existing `--model
# "${CODE_EDIT_MODEL:-opus}"` flag, computed ONCE from CODE_EDIT_EFFORT
# (default "high"). Statically assert all THREE sites carry it -- a
# copy-paste miss at exactly one of the three sites is the failure mode this
# guards against -- and that the default literal + allowlist validation are
# present in the source.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # the ${...} is a literal grep pattern, not a shell expansion
EFFORT_INVOCATIONS="$(grep -cF -- '--model "${CODE_EDIT_MODEL:-opus}" --settings "$EFFORT_SETTINGS"' "$ORCH" 2>/dev/null || true)"
if [ "${EFFORT_INVOCATIONS:-0}" -eq 3 ]; then
    pass "run 27 (#1444 CODE_EDIT_EFFORT): all three editing-session invocations carry --settings \$EFFORT_SETTINGS (found $EFFORT_INVOCATIONS)"
else
    fail "run 27 (#1444 CODE_EDIT_EFFORT): expected exactly 3 invocation sites carrying --settings" "matches=${EFFORT_INVOCATIONS:-0}"
fi
if grep -qF 'CODE_EDIT_EFFORT:-high}' "$ORCH" 2>/dev/null \
    && grep -qF 'low|medium|high|xhigh' "$ORCH" 2>/dev/null; then
    pass "run 27 (#1444 CODE_EDIT_EFFORT): default literal (high) and allowlist validation present in source"
else
    fail "run 27 (#1444 CODE_EDIT_EFFORT): missing default literal or allowlist validation in source"
fi

# ===========================================================================
# Run 28 (#1422 M1 --decompose-only): the stand-alone decomposition primitive
# runs ONLY the decompose drive, writes the ordered NUL-delimited subtask list
# to --subtasks-out, prints exactly `DECOMPOSED count=3`, and exits 0 BEFORE the
# per-subtask edit loop — ZERO edit invocations, NO commit, NO PR. The records
# must be byte-identical to the in-shell --decompose split (Run 14 pins that the
# split itself is untouched).
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/28"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

# Same stateful decompose-aware stub as Run 14: the Decompose drive writes a
# 3-line list; any EDIT drive bumps a counter (must stay 0 under --decompose-only).
EDIT_CNT_FILE28="$WORK/fc-edit-count-28"; rm -f "$EDIT_CNT_FILE28"
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
    TARGET="\$(grep "this exact file" "\$CMDFILE" | grep -oE '/[^ ]+' | head -n1)"
    if [ -n "\$TARGET" ]; then
        printf 'subtask one\nsubtask two\nsubtask three\n' > "\$TARGET"
    fi
    exit 0
fi
n=\$(cat "$EDIT_CNT_FILE28" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$EDIT_CNT_FILE28"
[ -n "\$CWD" ] && printf 'edit %s\n' "\$n" > "\$CWD/SUB_\$n.txt"
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

SUBTASKS_OUT28="$WORK/subtasks-28.txt"; rm -f "$SUBTASKS_OUT28"
OUT28_FILE="$WORK/out28.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 280 \
        --branch "fix/issue-280" --title "epic task" \
        --task "Do a big multi-part change." \
        --decompose-only --subtasks-out "$SUBTASKS_OUT28" >"$OUT28_FILE" 2>"$WORK/err28.txt"
RC28=$?
EDIT_CALLS28="$(cat "$EDIT_CNT_FILE28" 2>/dev/null || echo 0)"

if [ "$RC28" -eq 0 ] && [ "$(cat "$OUT28_FILE")" = "DECOMPOSED count=3" ]; then
    pass "run 28 (--decompose-only): exit 0 + prints exactly 'DECOMPOSED count=3'"
else
    fail "run 28 (--decompose-only): exit 0 + DECOMPOSED count=3" "rc=$RC28 out=$(cat "$OUT28_FILE" 2>/dev/null) err=$(tail -4 "$WORK/err28.txt" 2>/dev/null)"
fi
# The subtasks-out file must carry exactly 3 NUL records, byte-identical to the
# in-shell --decompose split (tr '\n' '\0' on the 3 parsed lines).
NUL_RECS28="$(tr -cd '\0' < "$SUBTASKS_OUT28" 2>/dev/null | wc -c | tr -d ' ')"
EXPECT28="$(printf 'subtask one\0subtask two\0subtask three\0')"
if [ -f "$SUBTASKS_OUT28" ] && [ "$NUL_RECS28" = "3" ] && [ "$(cat "$SUBTASKS_OUT28")" = "$EXPECT28" ]; then
    pass "run 28 (--decompose-only): wrote 3 NUL records to --subtasks-out (byte-identical to the split)"
else
    fail "run 28 (--decompose-only): 3 NUL records in --subtasks-out" "recs=$NUL_RECS28 file=$SUBTASKS_OUT28"
fi
if [ "$EDIT_CALLS28" = "0" ]; then
    pass "run 28 (--decompose-only): ran ZERO edit invocations (did not enter the per-subtask loop)"
else
    fail "run 28 (--decompose-only): expected 0 edit invocations" "got $EDIT_CALLS28"
fi
if [ ! -f "$CREATE_MR_LOG" ]; then
    pass "run 28 (--decompose-only): opened NO PR (no create-mr call)"
else
    fail "run 28 (--decompose-only): must not open a PR" "create-mr log present: $(cat "$CREATE_MR_LOG" 2>/dev/null)"
fi

# ===========================================================================
# Run 29 (#1422 M1 --decompose-only monolithic fallback): when the decompose
# drive yields NOTHING, fill_subtasks_file falls back to the whole task as ONE
# record, so --decompose-only still emits `DECOMPOSED count=1` (never count=0)
# and writes a single NUL record — the caller always gets >=1 subtask.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
{ echo "create-mr called"; } >> "$CREATE_MR_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/29"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

# Decompose stub that writes NOTHING to the target -> empty list -> fallback.
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FC_FLAGS_LOG"
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

SUBTASKS_OUT29="$WORK/subtasks-29.txt"; rm -f "$SUBTASKS_OUT29"
OUT29_FILE="$WORK/out29.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue 290 \
        --branch "fix/issue-290" --title "epic task" \
        --task "The whole indivisible task." \
        --decompose-only --subtasks-out "$SUBTASKS_OUT29" >"$OUT29_FILE" 2>"$WORK/err29.txt"
RC29=$?
NUL_RECS29="$(tr -cd '\0' < "$SUBTASKS_OUT29" 2>/dev/null | wc -c | tr -d ' ')"
if [ "$RC29" -eq 0 ] && [ "$(cat "$OUT29_FILE")" = "DECOMPOSED count=1" ] && [ "$NUL_RECS29" = "1" ]; then
    pass "run 29 (--decompose-only fallback): empty decomposition => DECOMPOSED count=1 + 1 NUL record"
else
    fail "run 29 (--decompose-only fallback): count=1 monolithic fallback" "rc=$RC29 out=$(cat "$OUT29_FILE" 2>/dev/null) recs=$NUL_RECS29"
fi
EXPECT29="$(printf 'The whole indivisible task.\0')"
if [ "$(cat "$SUBTASKS_OUT29" 2>/dev/null)" = "$EXPECT29" ]; then
    pass "run 29 (--decompose-only fallback): the single record is the WHOLE task"
else
    fail "run 29 (--decompose-only fallback): single record = whole task" "got=$(cat "$SUBTASKS_OUT29" 2>/dev/null)"
fi

# ===========================================================================
# Run 30 (#1422 M1 arg validation): --decompose-only without --subtasks-out is a
# caller error (exit 2); combining it with an editing primitive is rejected too.
# ===========================================================================
env PATH="$STUB_BIN:$PATH" COLONY_DIR="$COLONY_DIR" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" GITHUB_TOKEN="$FAKE_TOKEN" \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue 300 \
        --branch "fix/issue-300" --title "t" --task "x" --decompose-only \
        >/dev/null 2>"$WORK/err30a.txt"
RC30A=$?
env PATH="$STUB_BIN:$PATH" COLONY_DIR="$COLONY_DIR" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" GITHUB_TOKEN="$FAKE_TOKEN" \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue 300 \
        --branch "fix/issue-300" --title "t" --task "x" \
        --decompose-only --subtasks-out "$WORK/s30.txt" --one-attempt \
        >/dev/null 2>"$WORK/err30b.txt"
RC30B=$?
if [ "$RC30A" -eq 2 ] && [ "$RC30B" -eq 2 ]; then
    pass "run 30 (--decompose-only validation): missing --subtasks-out and editing-primitive combo both exit 2"
else
    fail "run 30 (--decompose-only validation): expected exit 2 for both" "rc_missing=$RC30A rc_combo=$RC30B"
fi

# ===========================================================================
# Run 31 (#1422 review finding 1 — reuse WITHOUT continuation ⇒ fresh scoped
# prompt): the crux the AG decompose loop depends on. A `--one-attempt --reuse`
# drive that carries NO --continuation must edit with the DEFAULT tightly-scoped
# per-subtask template ("Implement issue #N … <task> … Make the change and
# stop"), NOT the interrupted/verify CONTINUATION prompt. This is what lets a
# decompose subtask >= 2 accumulate on the one branch (--reuse) while still being
# scoped to its own subtask text — the fix that prevents decomposition collapse.
# ===========================================================================
rm -rf "$FED_DIR" "$REMOTE_BASE" "$SEED" "$CREATE_MR_LOG" "$FC_FLAGS_LOG"
mkdir -p "$COLONY_DIR/scripts"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
printf '%s\n' '{"html_url": "https://example.test/pr/31"}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

# Capturing stub: overwrite CMD_CAP with the cmd-file it receives each call, and
# write a unique file so churn>0 on both attempts.
CMD_CAP31="$WORK/cmdcap31.txt"; rm -f "$CMD_CAP31"
CNT31="$WORK/cnt31"; rm -f "$CNT31"
cat > "$STUB_BIN/flat-cyborg" <<STUB_EOF
#!/usr/bin/env bash
set -eu
CWD=""; CMDF=""
while [ \$# -gt 0 ]; do case "\$1" in --cwd) CWD="\$2"; shift 2 ;; --cmd-file) CMDF="\$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
[ -n "\$CMDF" ] && cat "\$CMDF" > "$CMD_CAP31"
n=\$(cat "$CNT31" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "$CNT31"
[ -n "\$CWD" ] && printf 'edit %s\n' "\$n" > "\$CWD/F_\$n.txt"
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

# Attempt 1 (subtask 1): fresh --one-attempt, creates the branch.
env PATH="$STUB_BIN:$PATH" COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" CODE_EDIT_VERIFY_CMD=true \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue 310 \
        --branch "fix/issue-310" --title "epic" \
        --task "Subtask one: add module A." --one-attempt >/dev/null 2>"$WORK/err31a.txt"
# Attempt 2 (subtask 2): --one-attempt --reuse, NO --continuation.
env PATH="$STUB_BIN:$PATH" COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" CODE_EDIT_VERIFY_CMD=true \
    bash "$ORCH" --owner "$OWNER" --repo "$REPO" --issue 310 \
        --branch "fix/issue-310" --title "epic" \
        --task "Subtask two: add module B." --one-attempt --reuse >/dev/null 2>"$WORK/err31b.txt"
RC31B=$?

# The captured attempt-2 prompt must be the FRESH scoped template for subtask 2,
# NOT a continuation prompt.
if [ "$RC31B" -eq 0 ] \
    && grep -q "Implement issue #310" "$CMD_CAP31" 2>/dev/null \
    && grep -q "Subtask two: add module B" "$CMD_CAP31" 2>/dev/null \
    && grep -q "Make the change and stop" "$CMD_CAP31" 2>/dev/null \
    && ! grep -q "You are CONTINUING" "$CMD_CAP31" 2>/dev/null \
    && ! grep -q "Continue implementing this issue" "$CMD_CAP31" 2>/dev/null; then
    pass "run 31 (finding 1): --one-attempt --reuse WITHOUT --continuation uses the fresh scoped subtask template (no continuation preamble)"
else
    fail "run 31 (finding 1): reuse-without-continuation prompt shape" "rc=$RC31B cap=[$(cat "$CMD_CAP31" 2>/dev/null | head -c 300)]"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
