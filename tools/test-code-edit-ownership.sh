#!/usr/bin/env bash
# test-code-edit-ownership.sh (#1516): exercise the fail-closed force-push
# OWNERSHIP GATE (guarded_push) of tools/code-edit-in-checkout.sh WITHOUT a real
# Claude Code session. The claude-edit step is a STUB flat-cyborg on PATH; the
# "remote" is a local bare git repo reached via a file:// GITHUB_URL; the forge
# API wrapper is a stub that records create-mr AND add-note calls.
#
# The gate replaces the single `push --force-with-lease` site: --force-with-lease
# guards only a CONCURRENT race, NOT foreign commits already at the remote head
# (the incident that destroyed 4 operator commits). guarded_push records the
# agent's own last-pushed sha to a sidecar under .agentis/ and, before any
# force-push, refuses when the remote head is neither an ancestor of the local
# head nor the agent's own recorded sha.
#
# Asserts:
#   O1. refuse-foreign — remote fix branch carries a commit the local rebuild
#       (off main) does not descend from, and no own-sha record exists ⇒ exit 5,
#       remote head UNCHANGED, create-mr NEVER called, the yield note posted
#       exactly ONCE (and a retry does not re-post — the .yielded flag caps it).
#   O2. allow-own-sha — the remote head is recorded as the agent's own sha (the
#       #1363 self-replace) ⇒ push succeeds, remote head ADVANCES, exit 0.
#   O3. allow-ancestor — remote head is an ancestor of the local head (the
#       --recover fast-forward shape) ⇒ push succeeds, remote ADVANCES, exit 0,
#       no yield note.
#   O4. fail-closed-lsremote — the remote becomes unreachable AFTER the clone
#       (broken by the edit stub) so `ls-remote` errors ⇒ exit 5, no push,
#       create-mr NEVER called, and NO yield note (a network error is fail-closed
#       but is not a foreign-commit yield).
#
# Auto-discovered by tools/colony-lint.sh's tools-test loop. Exit 0 if all pass.
set -u

# Isolate from the operator's ambient multi-repo forge config (see the same
# guard in test-code-edit-recover.sh).
unset GITHUB_REPOS_JSON FORGE_TYPE 2>/dev/null || true

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
ORCH="$REPO_ROOT/tools/code-edit-in-checkout.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if ! command -v git >/dev/null 2>&1; then
    echo "[SKIP] test-code-edit-ownership.sh: git not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] test-code-edit-ownership.sh: python3 not on PATH"
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
# The own-sha sidecar dir the gate keys per issue (COLONY_NAME = basename COLONY_DIR).
PUSHED_DIR="$FED_DIR/.agentis/code-edit-pushed/implementation/$OWNER-$REPO"

CREATE_MR_LOG="$WORK/create-mr.log"
ADD_NOTE_LOG="$WORK/add-note.log"
FC_FLAGS_LOG="$WORK/fc-flags.log"

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"

# seed_remote: fresh bare remote with main + a `fix/issue-<iid>` branch that
# already carries a FOREIGN/prior commit at its head (the operator commit the
# gate must not clobber, or our own prior push).
#   $1 = issue iid, $2 = head-commit filename.
seed_remote() {
    _iid="$1"; _head="$2"
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
        git checkout --quiet -b "fix/issue-$_iid"
        printf 'head change\n' > "$_head"
        git add -A
        git commit --quiet -m "operator: work on branch (#$_iid)"
        git push --quiet origin "fix/issue-$_iid"
    )
    git --git-dir="$BARE" symbolic-ref HEAD refs/heads/main
}

# install_forge_stub: a github-api.sh stub that RECORDS create-mr AND add-note
# calls (so we can assert the gate never opened a PR and posted the yield note at
# most once) and echoes canned JSON for create-mr.
install_forge_stub() {
    mkdir -p "$COLONY_DIR/scripts"
    cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
verb="\${1:-}"
case "\$verb" in
    create-mr)
        { echo "create-mr called with: \$*"; } >> "$CREATE_MR_LOG"
        printf '%s\n' '{"html_url": "https://example.test/pr/OWNERSHIP"}'
        ;;
    add-note)
        { echo "add-note called with: \$*"; } >> "$ADD_NOTE_LOG"
        printf '%s\n' '{"id": 1}'
        ;;
    *)
        { echo "other: \$*"; } >> "$CREATE_MR_LOG"
        ;;
esac
STUB_EOF
    chmod +x "$COLONY_DIR/scripts/github-api.sh"
}

# install_fc_stub: flat-cyborg stub. Writes \$FC_FIX_FILE into --cwd (the edit).
# When FC_BREAK_REMOTE is a path, it renames that path AFTER editing — breaking
# the remote between clone and push so ls-remote errors at the gate (O4).
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
if [ -n "\$CWD" ]; then
    printf 'agent edit\n' > "\$CWD/\${FC_FIX_FILE:-FIX.txt}"
fi
if [ -n "\${FC_BREAK_REMOTE:-}" ] && [ -e "\${FC_BREAK_REMOTE}" ]; then
    mv "\${FC_BREAK_REMOTE}" "\${FC_BREAK_REMOTE}.gone"
fi
exit "\${FC_STUB_RC:-0}"
STUB_EOF
    chmod +x "$STUB_BIN/flat-cyborg"
}

export PATH="$STUB_BIN:$PATH"

# ===========================================================================
# O1: refuse-foreign — the remote head is a foreign commit, no own-sha record.
# ===========================================================================
IID=70
FIXFILE="FIX_70.txt"
rm -f "$CREATE_MR_LOG" "$ADD_NOTE_LOG" "$FC_FLAGS_LOG"
rm -rf "$FED_DIR/.agentis/workspaces" "$PUSHED_DIR"
seed_remote "$IID" "OP_70.txt"
install_forge_stub
install_fc_stub
FOREIGN_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"

OUT1="$WORK/out1.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_FIX_FILE="$FIXFILE" \
    CODE_EDIT_VERIFY_CMD="true" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue "$IID" \
        --branch "fix/issue-$IID" --title "fix: harden #$IID" \
        --task "Implement." >"$OUT1" 2>"$WORK/err1.txt"
RC1=$?

if [ "$RC1" -eq 5 ]; then
    pass "O1: foreign remote head ⇒ exit 5 (ownership refused)"
else
    fail "O1: exit 5 on foreign remote head" "rc=$RC1 err=$(tail -5 "$WORK/err1.txt")"
fi
NOW_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
if [ "$NOW_TIP" = "$FOREIGN_TIP" ]; then
    pass "O1: remote head UNCHANGED (the foreign commit was preserved, no force-push)"
else
    fail "O1: remote head must be unchanged" "before=$FOREIGN_TIP after=$NOW_TIP"
fi
if [ ! -f "$CREATE_MR_LOG" ]; then
    pass "O1: create-mr NEVER called (refused before opening a PR)"
else
    fail "O1: create-mr must NOT fire on refuse" "log=$(cat "$CREATE_MR_LOG")"
fi
NOTE_COUNT="$( [ -f "$ADD_NOTE_LOG" ] && wc -l < "$ADD_NOTE_LOG" || echo 0)"
if [ "$NOTE_COUNT" -eq 1 ]; then
    pass "O1: yield note posted exactly once"
else
    fail "O1: exactly one yield note" "count=$NOTE_COUNT"
fi

# O1b: a RETRY of the same issue (workspace + .yielded flag survive the exit 5)
# must NOT re-post the note — the .yielded flag caps it.
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_FIX_FILE="$FIXFILE" \
    CODE_EDIT_VERIFY_CMD="true" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue "$IID" \
        --branch "fix/issue-$IID" --title "fix: harden #$IID" \
        --task "Implement." >/dev/null 2>>"$WORK/err1.txt"
RC1B=$?
NOTE_COUNT2="$( [ -f "$ADD_NOTE_LOG" ] && wc -l < "$ADD_NOTE_LOG" || echo 0)"
if [ "$RC1B" -eq 5 ] && [ "$NOTE_COUNT2" -eq 1 ]; then
    pass "O1b: retry still refuses (exit 5) and does NOT re-post the yield note (.yielded caps it)"
else
    fail "O1b: retry caps the yield note" "rc=$RC1B notes=$NOTE_COUNT2"
fi

# ===========================================================================
# O2: allow-own-sha — the remote head is recorded as the agent's own last push.
# ===========================================================================
IID=71
FIXFILE="FIX_71.txt"
rm -f "$CREATE_MR_LOG" "$ADD_NOTE_LOG" "$FC_FLAGS_LOG"
rm -rf "$FED_DIR/.agentis/workspaces" "$PUSHED_DIR"
seed_remote "$IID" "OWN_71.txt"
install_forge_stub
install_fc_stub
OWN_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
# Pre-seed the own-sha record with the current remote head: we are replacing our
# OWN prior attempt (the #1363 MR-less-branch rescue), which is legitimate.
mkdir -p "$PUSHED_DIR"
printf '%s\n' "$OWN_TIP" > "$PUSHED_DIR/issue-$IID.sha"

OUT2="$WORK/out2.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_FIX_FILE="$FIXFILE" \
    CODE_EDIT_VERIFY_CMD="true" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue "$IID" \
        --branch "fix/issue-$IID" --title "fix: harden #$IID" \
        --task "Implement." >"$OUT2" 2>"$WORK/err2.txt"
RC2=$?

if [ "$RC2" -eq 0 ]; then
    pass "O2: remote head == own recorded sha ⇒ push allowed, exit 0"
else
    fail "O2: exit 0 when replacing our own prior attempt" "rc=$RC2 err=$(tail -6 "$WORK/err2.txt")"
fi
NOW2_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
if [ "$NOW2_TIP" != "$OWN_TIP" ]; then
    pass "O2: remote head ADVANCED (our replacement push landed)"
else
    fail "O2: remote head must advance" "still=$OWN_TIP"
fi
if [ -f "$CREATE_MR_LOG" ]; then
    pass "O2: create-mr fired (PR opened on the allowed push)"
else
    fail "O2: create-mr should fire on the allowed push"
fi

# ===========================================================================
# O3: allow-ancestor — remote head is an ancestor of the local head (--recover
# fast-forward shape). No own-sha record needed.
# ===========================================================================
IID=72
FIXFILE="FIX_72.txt"
rm -f "$CREATE_MR_LOG" "$ADD_NOTE_LOG" "$FC_FLAGS_LOG"
rm -rf "$FED_DIR/.agentis/workspaces" "$PUSHED_DIR"
seed_remote "$IID" "PRIOR_72.txt"
install_forge_stub
install_fc_stub
ANC_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"

OUT3="$WORK/out3.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_FIX_FILE="$FIXFILE" \
    CODE_EDIT_VERIFY_CMD="true" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue "$IID" \
        --branch "fix/issue-$IID" --title "fix: recover CI for #$IID" \
        --task "Reproduce and fix." --recover >"$OUT3" 2>"$WORK/err3.txt"
RC3=$?

if [ "$RC3" -eq 0 ]; then
    pass "O3: fast-forward (remote is an ancestor) ⇒ push allowed, exit 0"
else
    fail "O3: exit 0 on fast-forward" "rc=$RC3 err=$(tail -6 "$WORK/err3.txt")"
fi
NOW3_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
if [ "$NOW3_TIP" != "$ANC_TIP" ] \
   && git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-$IID:PRIOR_72.txt" 2>/dev/null \
   && git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-$IID:$FIXFILE" 2>/dev/null; then
    pass "O3: remote ADVANCED keeping the prior commit's file + the new fix (fast-forward)"
else
    fail "O3: remote advanced on top of the ancestor" "before=$ANC_TIP after=$NOW3_TIP"
fi
if [ ! -f "$ADD_NOTE_LOG" ]; then
    pass "O3: no yield note on an allowed fast-forward push"
else
    fail "O3: no yield note expected" "log=$(cat "$ADD_NOTE_LOG")"
fi

# ===========================================================================
# O4: fail-closed-lsremote — the remote is broken AFTER the clone (the edit stub
# renames the bare repo), so ls-remote errors at the gate ⇒ exit 5, no push, no
# yield note. Distinguishes a network/auth failure (fail-closed, silent) from a
# foreign-commit refusal (fail-closed, yields with a note).
# ===========================================================================
IID=73
FIXFILE="FIX_73.txt"
rm -f "$CREATE_MR_LOG" "$ADD_NOTE_LOG" "$FC_FLAGS_LOG"
rm -rf "$FED_DIR/.agentis/workspaces" "$PUSHED_DIR"
seed_remote "$IID" "OP_73.txt"
install_forge_stub
install_fc_stub

OUT4="$WORK/out4.txt"
env \
    PATH="$STUB_BIN:$PATH" \
    COLONY_DIR="$COLONY_DIR" \
    GITHUB_URL="file://$REMOTE_BASE" \
    GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    FC_FIX_FILE="$FIXFILE" \
    FC_BREAK_REMOTE="$BARE" \
    CODE_EDIT_VERIFY_CMD="true" \
    bash "$ORCH" \
        --owner "$OWNER" --repo "$REPO" --issue "$IID" \
        --branch "fix/issue-$IID" --title "fix: harden #$IID" \
        --task "Implement." >"$OUT4" 2>"$WORK/err4.txt"
RC4=$?
# Restore the bare repo so the branch-tip assertion can read it.
[ -e "$BARE.gone" ] && mv "$BARE.gone" "$BARE"

if [ "$RC4" -eq 5 ]; then
    pass "O4: ls-remote error ⇒ exit 5 (fail-closed, network error is NOT 'no remote branch')"
else
    fail "O4: fail-closed on ls-remote error" "rc=$RC4 err=$(tail -6 "$WORK/err4.txt")"
fi
if [ ! -f "$CREATE_MR_LOG" ]; then
    pass "O4: create-mr NEVER called on the fail-closed path"
else
    fail "O4: create-mr must NOT fire" "log=$(cat "$CREATE_MR_LOG")"
fi
if [ ! -f "$ADD_NOTE_LOG" ]; then
    pass "O4: NO yield note on a network/ls-remote failure (only foreign-commit refusal yields)"
else
    fail "O4: no yield note expected on ls-remote failure" "log=$(cat "$ADD_NOTE_LOG")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
