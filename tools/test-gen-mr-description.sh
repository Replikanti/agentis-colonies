#!/usr/bin/env bash
# test-gen-mr-description.sh (#1347): exercise tools/gen-mr-description.sh and its
# integration into tools/code-edit-in-checkout.sh WITHOUT a real Claude session.
# The LLM call is replaced by a STUB pointed at via GEN_MR_LLM_CMD (which the
# helper honours in place of flat-cyborg-claude.sh); the helper and the
# orchestrator are otherwise driven exactly as in production.
#
# Asserts:
#   UNIT (gen-mr-description.sh directly):
#     1. a non-empty LLM reply is emitted with the `## Problem`/`## Fix`/
#        `## Testing` sections intact (helper does NOT append `Closes #N`)
#     2. an empty / whitespace-only LLM reply makes the helper print NOTHING
#        (the fall-back signal for the caller)
#     3. a missing/unresolvable LLM command makes the helper print NOTHING
#   INTEGRATION (through code-edit-in-checkout.sh):
#     4. a generated body reaches create-mr with the three sections AND a
#        `Closes #42` line appended by the orchestrator
#     5. an empty generation falls back to the static `Autonomously implemented`
#        template, still carrying `Closes #42`
#
# Auto-discovered by tools/colony-lint.sh's tools-test loop. Exit 0 if all pass.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
GEN="$REPO_ROOT/tools/gen-mr-description.sh"
ORCH="$REPO_ROOT/tools/code-edit-in-checkout.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

skip() {
    echo "[SKIP] test-gen-mr-description.sh: $1"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
}

command -v git >/dev/null 2>&1 || skip "git not on PATH"
command -v python3 >/dev/null 2>&1 || skip "python3 not on PATH"
[ -f "$GEN" ] || { fail "helper missing: $GEN"; echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
[ -f "$ORCH" ] || { fail "orchestrator missing: $ORCH"; echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Self-isolate from any ambient federation env (same rationale as
# test-code-edit-in-checkout.sh).
unset GITHUB_REPOS_JSON GITLAB_REPOS_JSON FORGE_TYPE \
      GITHUB_OWNER GITHUB_REPO GITHUB_TOKEN GITHUB_URL \
      GITLAB_PROJECT GITLAB_TOKEN GITLAB_URL \
      LC_ALL COLONY_DIR GEN_MR_LLM_CMD 2>/dev/null || true

export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

# A stub LLM body with the three required sections. The orchestrator appends
# `Closes #N`; the helper must NOT.
# shellcheck disable=SC2016  # backticks are literal markdown code spans, not command substitution
GEN_BODY='## Problem
The verify gate auto-picked `npm test`, which hangs or exits 127.

## Fix
Generate the MR body from the issue and committed diff.

## Testing
Added tools/test-gen-mr-description.sh stubbing the LLM.'

# Stub LLM that emits the body above (consumes stdin to avoid SIGPIPE).
LLM_OK="$WORK/llm-ok.sh"
{
    echo '#!/usr/bin/env sh'
    echo 'cat >/dev/null 2>&1 || true'
    echo "cat <<'BODY_EOF'"
    printf '%s\n' "$GEN_BODY"
    echo 'BODY_EOF'
} > "$LLM_OK"
chmod +x "$LLM_OK"

# Stub LLM that emits only whitespace (the empty-generation case).
LLM_EMPTY="$WORK/llm-empty.sh"
{
    echo '#!/usr/bin/env sh'
    echo 'cat >/dev/null 2>&1 || true'
    printf '%s\n' 'printf "   \n"'
} > "$LLM_EMPTY"
chmod +x "$LLM_EMPTY"

DIFF_FILE="$WORK/diff.txt"
printf 'diff --git a/x b/x\n+changed line\n' > "$DIFF_FILE"

# ===========================================================================
# UNIT 1: non-empty reply -> three sections present, no Closes line.
# ===========================================================================
U1="$(GEN_MR_LLM_CMD="$LLM_OK" "$GEN" --issue 42 --title "feat: x" \
    --task "body text" --diff-file "$DIFF_FILE" 2>/dev/null)"
if printf '%s' "$U1" | grep -q '## Problem' \
   && printf '%s' "$U1" | grep -q '## Fix' \
   && printf '%s' "$U1" | grep -q '## Testing'; then
    pass "unit: helper emits the ## Problem / ## Fix / ## Testing sections"
else
    fail "unit: three sections present" "got: $U1"
fi
if printf '%s' "$U1" | grep -q 'Closes #'; then
    fail "unit: helper must NOT append a Closes line (caller does)" "got: $U1"
else
    pass "unit: helper does not append a Closes line"
fi

# ===========================================================================
# UNIT 2: whitespace-only reply -> helper prints nothing.
# ===========================================================================
U2="$(GEN_MR_LLM_CMD="$LLM_EMPTY" "$GEN" --issue 42 --title "feat: x" \
    --task "body text" --diff-file "$DIFF_FILE" 2>/dev/null)"
if [ -z "$U2" ]; then
    pass "unit: empty generation prints nothing (fall-back signal)"
else
    fail "unit: empty generation prints nothing" "got: $U2"
fi

# ===========================================================================
# UNIT 3: unresolvable LLM command -> helper prints nothing.
# ===========================================================================
U3="$(GEN_MR_LLM_CMD="$WORK/does-not-exist-llm" "$GEN" --issue 42 --title "feat: x" \
    --task "body text" --diff-file "$DIFF_FILE" 2>/dev/null)"
if [ -z "$U3" ]; then
    pass "unit: missing LLM command prints nothing"
else
    fail "unit: missing LLM command prints nothing" "got: $U3"
fi

# ===========================================================================
# Integration harness: bare remote + fed/colony tree + stub flat-cyborg (edit)
# + stub github-api.sh that records the --description it receives.
# ===========================================================================
FAKE_TOKEN="ghp_FAKE_TOKEN_DO_NOT_LEAK_abcdef0123456789"
OWNER="acme"; REPO="widget"
REMOTE_BASE="$WORK/remote"
BARE="$REMOTE_BASE/$OWNER/$REPO.git"
SEED="$WORK/seed"
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

FED_DIR="$WORK/fed"
COLONY_DIR="$FED_DIR/implementation"
mkdir -p "$COLONY_DIR/scripts"

# Stub github-api.sh: record the full --description to a file, echo canned JSON.
DESC_FILE="$WORK/desc.txt"
cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
shift  # drop the create-mr verb
DESC=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --description) DESC="\$2"; shift 2 ;;
        --source|--title) shift 2 ;;
        *) shift ;;
    esac
done
printf '%s' "\$DESC" > "$DESC_FILE"
printf '%s\n' '{"html_url": "https://example.test/pr/1", "number": 1}'
STUB_EOF
chmod +x "$COLONY_DIR/scripts/github-api.sh"

# Stub flat-cyborg on PATH: simulate the editing agent by writing a file in --cwd.
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/flat-cyborg" <<'STUB_EOF'
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
[ -n "$CWD" ] && printf 'generated by claude\n' > "$CWD/NEWFILE.txt"
exit 0
STUB_EOF
chmod +x "$STUB_BIN/flat-cyborg"

run_orch() {
    # $1 = GEN_MR_LLM_CMD stub for gen-mr-description.sh (inherited by the child).
    env \
        PATH="$STUB_BIN:$PATH" \
        COLONY_DIR="$COLONY_DIR" \
        GITHUB_URL="file://$REMOTE_BASE" \
        GITHUB_TOKEN="$FAKE_TOKEN" \
        GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
        GEN_MR_LLM_CMD="$1" \
        bash "$ORCH" \
            --owner "$OWNER" --repo "$REPO" --issue 42 \
            --branch "fix/issue-42" --title "add new file" \
            --task "Create NEWFILE.txt with a greeting."
}

# ===========================================================================
# INTEGRATION 1: generated body -> three sections + appended Closes #42.
# ===========================================================================
: > "$DESC_FILE"
rm -rf "$FED_DIR/.agentis/workspaces" 2>/dev/null || true
OUT_I1="$(run_orch "$LLM_OK" 2>"$WORK/err-i1.txt")"
RC_I1=$?
DESC_I1="$(cat "$DESC_FILE" 2>/dev/null || true)"
if [ "$RC_I1" -eq 0 ] && [ "$OUT_I1" = "https://example.test/pr/1" ]; then
    pass "integration: orchestrator opens the PR and prints its URL"
else
    fail "integration: PR opened" "rc=$RC_I1 out=$OUT_I1 err=$(cat "$WORK/err-i1.txt")"
fi
if printf '%s' "$DESC_I1" | grep -q '## Problem' \
   && printf '%s' "$DESC_I1" | grep -q '## Fix' \
   && printf '%s' "$DESC_I1" | grep -q '## Testing' \
   && printf '%s' "$DESC_I1" | grep -q 'Closes #42'; then
    pass "integration: create-mr body has the three sections + Closes #42"
else
    fail "integration: generated body + Closes #42" "got: $DESC_I1"
fi

# ===========================================================================
# INTEGRATION 2: empty generation -> static template fall-back (+ Closes #42).
# ===========================================================================
: > "$DESC_FILE"
rm -rf "$FED_DIR/.agentis/workspaces" 2>/dev/null || true
# Only the recorded --description matters here (the URL/rc are asserted in I1).
run_orch "$LLM_EMPTY" >/dev/null 2>"$WORK/err-i2.txt"
DESC_I2="$(cat "$DESC_FILE" 2>/dev/null || true)"
if printf '%s' "$DESC_I2" | grep -q 'Autonomously implemented by the dev-apprenticeship federation' \
   && printf '%s' "$DESC_I2" | grep -q 'Closes #42'; then
    pass "integration: empty generation falls back to the static template"
else
    fail "integration: static fall-back" "got: $DESC_I2"
fi
if printf '%s' "$DESC_I2" | grep -q '## Problem'; then
    fail "integration: fall-back must not carry generated sections" "got: $DESC_I2"
else
    pass "integration: fall-back body carries no generated sections"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
