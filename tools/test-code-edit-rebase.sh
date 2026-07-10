#!/usr/bin/env bash
# test-code-edit-rebase.sh (#1518): exercise the --rebase mode of
# tools/code-edit-in-checkout.sh against a real local git "remote" (a bare repo
# reached via a file:// GITHUB_URL), WITHOUT a real Claude session — --rebase is
# pure git, so no flat-cyborg stub is needed.
#
# --rebase re-bases our OWN CONFLICTING PR branch onto the moved default branch:
#   * clean rebase (no conflict)                 -> guarded_push force-push; REBASED; exit 0
#   * lone CHANGELOG.md [Unreleased] two-sided    -> deterministic union-merge; REBASED; exit 0
#   * conflict touching a RELEASED heading        -> git rebase --abort + one-time note; exit 6
#   * a non-CHANGELOG code conflict               -> abort + one-time note; exit 6
#   * a foreign commit at the remote head         -> guarded_push REFUSES; #1516 note; exit 5
#
# The ONLY write is guarded_push (#1516). A rebase rewrites history, so the new
# head is never an ancestor of the old remote — guarded_push then force-pushes
# ONLY when the remote head equals code_writer's recorded own sha. The harness
# seeds that record (via the .agentis/code-edit-pushed/... file the orchestrator
# reads) to model "code_writer opened + pushed this branch".
#
# Asserts:
#   B1. CONFLICTING (main moved, no file overlap) + clean rebase pushes (REBASED, exit 0)
#   B2. CHANGELOG [Unreleased] two-sided insert union-merges (both bullets, main first)
#   B3. conflict touching a RELEASED `## [x.y.z]` heading is NOT auto-resolved (abort+note, exit 6)
#   B4. a real code conflict (non-CHANGELOG file) -> note + no push (abort, exit 6)
#   B5. ownership: a foreign commit at remote head -> guarded_push refuses -> note, no destructive push (exit 5)
#   B6. a CHANGELOG conflict where one side EDITS/DELETES a base [Unreleased] bullet
#       (both sides bullet-shaped) is NOT auto-resolved: the zdiff3 base region is
#       non-empty -> abort + note + exit 6, no corrupting union pushed
#       (adversarial-review corruption regression guard).
#   Z1. the --rebase mode forces merge.conflictStyle=zdiff3 (source-grep, so a
#       future refactor can't silently drop it and re-open the corruption hole).
#   J1. code-edit-job.sh forwards --rebase; a normal run does NOT
#
# Auto-discovered by tools/colony-lint.sh's tools-test loop. Exit 0 if all pass.
set -u

unset GITHUB_REPOS_JSON FORGE_TYPE 2>/dev/null || true

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
ORCH="$REPO_ROOT/tools/code-edit-in-checkout.sh"
LAUNCHER="$REPO_ROOT/tools/code-edit-job.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if ! command -v git >/dev/null 2>&1; then
    echo "[SKIP] test-code-edit-rebase.sh: git not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] test-code-edit-rebase.sh: python3 not on PATH"
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
# COLONY_NAME = basename(COLONY_DIR) = implementation; the orchestrator records
# the own-sha under this path.
PUSHED_DIR="$FED_DIR/.agentis/code-edit-pushed/implementation/$OWNER-$REPO"

NOTE_LOG="$WORK/add-note.log"

# install_note_stub: a github-api.sh stub that RECORDS add-note calls (so we can
# assert the human/yield notes fire) and would record create-mr too (which the
# rebase path must NEVER call). Echoes canned JSON.
install_note_stub() {
    mkdir -p "$COLONY_DIR/scripts"
    cat > "$COLONY_DIR/scripts/github-api.sh" <<STUB_EOF
#!/usr/bin/env bash
set -eu
verb="\${1:-}"
{ echo "\$verb called with: \$*"; } >> "$NOTE_LOG"
printf '%s\n' '{"html_url": "https://example.test/pr/SHOULD-NOT-OPEN"}'
STUB_EOF
    chmod +x "$COLONY_DIR/scripts/github-api.sh"
}

# record_own_sha: model "code_writer pushed this branch" by writing its recorded
# own last-pushed sha = the current remote branch tip, so guarded_push force-pushes.
# $1 = iid, $2 = sha
record_own_sha() {
    mkdir -p "$PUSHED_DIR"
    printf '%s\n' "$2" > "$PUSHED_DIR/issue-$1.sha"
}

# run_rebase: run the orchestrator --rebase for one issue. Sets RC + OUT.
# $1 = iid
run_rebase() {
    _iid="$1"
    env \
        COLONY_DIR="$COLONY_DIR" \
        GITHUB_URL="file://$REMOTE_BASE" \
        GITHUB_TOKEN="$FAKE_TOKEN" \
        GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
        bash "$ORCH" \
            --owner "$OWNER" --repo "$REPO" --issue "$_iid" \
            --branch "fix/issue-$_iid" --title "chore: auto-rebase #$_iid" \
            --task "Auto-rebase (pure git)." --rebase >"$WORK/out.txt" 2>"$WORK/err.txt"
    RC=$?
    OUT="$(cat "$WORK/out.txt")"
}

fresh_remote() {
    rm -rf "$BARE" "$SEED"
    mkdir -p "$BARE"
    git init --quiet --bare --initial-branch=main "$BARE" 2>/dev/null || git init --quiet --bare "$BARE"
    git init --quiet --initial-branch=main "$SEED" 2>/dev/null || git init --quiet "$SEED"
}

# ===========================================================================
# B1: CONFLICTING (main moved with an UNRELATED file) + clean rebase pushes.
# Branch adds file A on old main; main then adds file B (no overlap). Rebase is
# clean; guarded_push force-pushes (own-sha recorded). Pushed tip carries A + B.
# ===========================================================================
IID=70
fresh_remote
(
    cd "$SEED" || exit 1
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    printf 'hello\n' > README.md
    git add -A; git commit --quiet -m "seed"
    git branch -M main 2>/dev/null || true
    git remote add origin "$BARE"
    git push --quiet origin main
    # Our PR branch off the seed commit: adds A.
    git checkout --quiet -b "fix/issue-$IID"
    printf 'ours\n' > A_FEATURE.txt
    git add -A; git commit --quiet -m "feat: A (#$IID)"
    git push --quiet origin "fix/issue-$IID"
    # main advances with an unrelated file B.
    git checkout --quiet main
    printf 'mainland\n' > B_MAIN.txt
    git add -A; git commit --quiet -m "feat: B on main"
    git push --quiet origin main
)
BRANCH_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
install_note_stub
record_own_sha "$IID" "$BRANCH_TIP"
run_rebase "$IID"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "^REBASED fix/issue-$IID$"; then
    pass "B1: clean rebase pushes (exit 0, REBASED <branch>)"
else
    fail "B1: clean rebase exit 0 + REBASED" "rc=$RC out=[$OUT] err=$(tail -4 "$WORK/err.txt")"
fi
if git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-$IID:A_FEATURE.txt" 2>/dev/null \
   && git --git-dir="$BARE" cat-file -e "refs/heads/fix/issue-$IID:B_MAIN.txt" 2>/dev/null; then
    pass "B1: pushed tip carries our file A AND main's file B (rebased onto moved main)"
else
    fail "B1: rebased tip has A + B"
fi
if [ ! -f "$NOTE_LOG" ] || ! grep -q 'add-note' "$NOTE_LOG" 2>/dev/null; then
    pass "B1: no human note on a clean rebase"
else
    fail "B1: no note expected" "log=$(cat "$NOTE_LOG")"
fi

# ===========================================================================
# B2: CHANGELOG [Unreleased] two-sided insert union-merges. Branch adds a bullet
# under [Unreleased]; main adds a DIFFERENT bullet under [Unreleased] -> rebase
# conflict inside [Unreleased]. Deterministic union keeps both, main bullet first.
# ===========================================================================
IID=71
fresh_remote
mk_changelog() {
    # $1 = extra bullet line under [Unreleased]
    printf '# Changelog\n\n## [Unreleased]\n%s\n\n## [1.0.0] - 2024-01-01\n- Initial\n' "$1"
}
(
    cd "$SEED" || exit 1
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2024-01-01\n- Initial\n' > CHANGELOG.md
    git add -A; git commit --quiet -m "seed"
    git branch -M main 2>/dev/null || true
    git remote add origin "$BARE"
    git push --quiet origin main
    git checkout --quiet -b "fix/issue-$IID"
    printf '# Changelog\n\n## [Unreleased]\n- Our bullet Y\n\n## [1.0.0] - 2024-01-01\n- Initial\n' > CHANGELOG.md
    git add -A; git commit --quiet -m "docs: our changelog (#$IID)"
    git push --quiet origin "fix/issue-$IID"
    git checkout --quiet main
    printf '# Changelog\n\n## [Unreleased]\n- Main bullet X\n\n## [1.0.0] - 2024-01-01\n- Initial\n' > CHANGELOG.md
    git add -A; git commit --quiet -m "docs: main changelog"
    git push --quiet origin main
)
BRANCH_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
rm -f "$NOTE_LOG"
install_note_stub
record_own_sha "$IID" "$BRANCH_TIP"
run_rebase "$IID"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "^REBASED fix/issue-$IID$"; then
    pass "B2: CHANGELOG two-sided insert union-merges (exit 0, REBASED)"
else
    fail "B2: exit 0 + REBASED" "rc=$RC out=[$OUT] err=$(tail -6 "$WORK/err.txt")"
fi
# Inspect the pushed CHANGELOG: both bullets kept, main bullet FIRST, no markers.
RESOLVED="$(git --git-dir="$BARE" show "refs/heads/fix/issue-$IID:CHANGELOG.md" 2>/dev/null)"
if printf '%s' "$RESOLVED" | grep -q '^- Main bullet X$' \
   && printf '%s' "$RESOLVED" | grep -q '^- Our bullet Y$'; then
    pass "B2: both bullets kept in the pushed CHANGELOG (union)"
else
    fail "B2: both bullets kept" "resolved=[$RESOLVED]"
fi
if printf '%s' "$RESOLVED" | grep -qE '^(<<<<<<<|=======|>>>>>>>)'; then
    fail "B2: conflict markers must be gone" "resolved=[$RESOLVED]"
else
    pass "B2: no conflict markers in the pushed CHANGELOG"
fi
MAIN_LN="$(printf '%s\n' "$RESOLVED" | grep -n '^- Main bullet X$' | head -1 | cut -d: -f1)"
OUR_LN="$(printf '%s\n' "$RESOLVED" | grep -n '^- Our bullet Y$' | head -1 | cut -d: -f1)"
if [ -n "$MAIN_LN" ] && [ -n "$OUR_LN" ] && [ "$MAIN_LN" -lt "$OUR_LN" ]; then
    pass "B2: main (HEAD) bullet ordered before ours"
else
    fail "B2: main-first order" "main=$MAIN_LN our=$OUR_LN"
fi

# ===========================================================================
# B3: a conflict touching a RELEASED `## [x.y.z]` heading is NOT auto-resolved.
# Branch + main both edit a bullet under a released section -> the conflict is
# NOT inside [Unreleased] -> containment guard fails -> abort + one note + exit 6,
# branch tip unchanged (nothing pushed).
# ===========================================================================
IID=72
fresh_remote
(
    cd "$SEED" || exit 1
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2024-01-01\n- Original released bullet\n' > CHANGELOG.md
    git add -A; git commit --quiet -m "seed"
    git branch -M main 2>/dev/null || true
    git remote add origin "$BARE"
    git push --quiet origin main
    git checkout --quiet -b "fix/issue-$IID"
    printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2024-01-01\n- Our edit of released bullet\n' > CHANGELOG.md
    git add -A; git commit --quiet -m "docs: our released edit (#$IID)"
    git push --quiet origin "fix/issue-$IID"
    git checkout --quiet main
    printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2024-01-01\n- Main edit of released bullet\n' > CHANGELOG.md
    git add -A; git commit --quiet -m "docs: main released edit"
    git push --quiet origin main
)
BRANCH_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
rm -f "$NOTE_LOG"
install_note_stub
record_own_sha "$IID" "$BRANCH_TIP"
run_rebase "$IID"
if [ "$RC" -eq 6 ]; then
    pass "B3: released-heading conflict NOT auto-resolved (exit 6)"
else
    fail "B3: exit 6" "rc=$RC out=[$OUT] err=$(tail -6 "$WORK/err.txt")"
fi
NEW_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
if [ "$NEW_TIP" = "$BRANCH_TIP" ]; then
    pass "B3: branch tip unchanged (abort restored it, nothing pushed)"
else
    fail "B3: tip must be unchanged" "before=$BRANCH_TIP after=$NEW_TIP"
fi
if grep -q 'add-note' "$NOTE_LOG" 2>/dev/null; then
    pass "B3: exactly one human note posted"
else
    fail "B3: human note expected" "log=$(cat "$NOTE_LOG" 2>/dev/null)"
fi
if ! grep -q 'create-mr' "$NOTE_LOG" 2>/dev/null; then
    pass "B3: no PR opened on the abort path"
else
    fail "B3: create-mr must not fire"
fi

# ===========================================================================
# B4: a real code conflict (non-CHANGELOG file) -> note + no push (exit 6).
# ===========================================================================
IID=73
fresh_remote
(
    cd "$SEED" || exit 1
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    printf 'line1\noriginal\nline3\n' > src.txt
    git add -A; git commit --quiet -m "seed"
    git branch -M main 2>/dev/null || true
    git remote add origin "$BARE"
    git push --quiet origin main
    git checkout --quiet -b "fix/issue-$IID"
    printf 'line1\nOURS\nline3\n' > src.txt
    git add -A; git commit --quiet -m "feat: our src (#$IID)"
    git push --quiet origin "fix/issue-$IID"
    git checkout --quiet main
    printf 'line1\nMAIN\nline3\n' > src.txt
    git add -A; git commit --quiet -m "feat: main src"
    git push --quiet origin main
)
BRANCH_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
rm -f "$NOTE_LOG"
install_note_stub
record_own_sha "$IID" "$BRANCH_TIP"
run_rebase "$IID"
if [ "$RC" -eq 6 ]; then
    pass "B4: non-CHANGELOG code conflict NOT auto-resolved (exit 6)"
else
    fail "B4: exit 6" "rc=$RC out=[$OUT] err=$(tail -6 "$WORK/err.txt")"
fi
NEW_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
if [ "$NEW_TIP" = "$BRANCH_TIP" ]; then
    pass "B4: branch tip unchanged (nothing pushed)"
else
    fail "B4: tip must be unchanged" "before=$BRANCH_TIP after=$NEW_TIP"
fi
if grep -q 'add-note' "$NOTE_LOG" 2>/dev/null; then
    pass "B4: one human note posted"
else
    fail "B4: human note expected" "log=$(cat "$NOTE_LOG" 2>/dev/null)"
fi

# ===========================================================================
# B5: ownership composition. A CONFLICTING PR whose remote head carries a FOREIGN
# commit (NOT code_writer's recorded own sha) — a clean rebase succeeds locally
# but guarded_push REFUSES (exit 5) and posts the #1516 yield note; the remote
# head is NOT clobbered. Same clean-rebase shape as B1, but the own-sha record is
# set to a DIFFERENT sha (an operator pushed over our branch).
# ===========================================================================
IID=74
fresh_remote
(
    cd "$SEED" || exit 1
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    printf 'hello\n' > README.md
    git add -A; git commit --quiet -m "seed"
    git branch -M main 2>/dev/null || true
    git remote add origin "$BARE"
    git push --quiet origin main
    git checkout --quiet -b "fix/issue-$IID"
    printf 'ours\n' > A_FEATURE.txt
    git add -A; git commit --quiet -m "feat: A (#$IID)"
    # An operator commit lands on top of our branch (foreign to code_writer).
    printf 'operator change\n' > OPERATOR.txt
    git add -A; git commit --quiet -m "operator: manual tweak"
    git push --quiet origin "fix/issue-$IID"
    git checkout --quiet main
    printf 'mainland\n' > B_MAIN.txt
    git add -A; git commit --quiet -m "feat: B on main"
    git push --quiet origin main
)
FOREIGN_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
rm -f "$NOTE_LOG"
install_note_stub
# Record an own-sha that does NOT match the remote head (the operator commit is
# foreign) — guarded_push must refuse.
record_own_sha "$IID" "0000000000000000000000000000000000000000"
run_rebase "$IID"
if [ "$RC" -eq 5 ]; then
    pass "B5: foreign commit at remote head -> guarded_push REFUSES (exit 5)"
else
    fail "B5: exit 5" "rc=$RC out=[$OUT] err=$(tail -6 "$WORK/err.txt")"
fi
NEW_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
if [ "$NEW_TIP" = "$FOREIGN_TIP" ]; then
    pass "B5: remote head NOT clobbered (operator commit preserved)"
else
    fail "B5: remote head must be unchanged" "before=$FOREIGN_TIP after=$NEW_TIP"
fi
if grep -q 'add-note' "$NOTE_LOG" 2>/dev/null; then
    pass "B5: the #1516 yield note posted (yielded to the operator)"
else
    fail "B5: yield note expected" "log=$(cat "$NOTE_LOG" 2>/dev/null)"
fi

# ===========================================================================
# B6: a CHANGELOG [Unreleased] conflict where OUR side EDITS a base bullet AND
# DELETES another (both sides all-`- `-bullet-shaped) must NOT auto-resolve. Under
# the forced zdiff3 style the merge-base region is non-empty, so the resolver
# refuses -> abort + one note + exit 6, branch tip unchanged. Without zdiff3 +
# the base-region guard this unioned to a corrupted CHANGELOG (resurrected the
# deleted bullet, duplicated the edited one) — the adversarial-review finding.
# ===========================================================================
IID=75
fresh_remote
(
    cd "$SEED" || exit 1
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    printf '# Changelog\n\n## [Unreleased]\n- alpha\n- beta\n- gamma\n\n## [1.0.0] - 2024-01-01\n- Initial\n' > CHANGELOG.md
    git add -A; git commit --quiet -m "seed"
    git branch -M main 2>/dev/null || true
    git remote add origin "$BARE"
    git push --quiet origin main
    # ours: edit alpha + DELETE beta (both lines still `- ` bullets).
    git checkout --quiet -b "fix/issue-$IID"
    printf '# Changelog\n\n## [Unreleased]\n- alpha our-edit\n- gamma\n\n## [1.0.0] - 2024-01-01\n- Initial\n' > CHANGELOG.md
    git add -A; git commit --quiet -m "docs: our edit+delete (#$IID)"
    git push --quiet origin "fix/issue-$IID"
    # main: edit alpha differently.
    git checkout --quiet main
    printf '# Changelog\n\n## [Unreleased]\n- alpha main-edit\n- beta\n- gamma\n\n## [1.0.0] - 2024-01-01\n- Initial\n' > CHANGELOG.md
    git add -A; git commit --quiet -m "docs: main edit"
    git push --quiet origin main
)
BRANCH_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
rm -f "$NOTE_LOG"
install_note_stub
record_own_sha "$IID" "$BRANCH_TIP"
run_rebase "$IID"
if [ "$RC" -eq 6 ]; then
    pass "B6: edit/delete of a base [Unreleased] bullet NOT auto-resolved (exit 6)"
else
    fail "B6: exit 6" "rc=$RC out=[$OUT] err=$(tail -8 "$WORK/err.txt")"
fi
NEW_TIP="$(git --git-dir="$BARE" rev-parse "refs/heads/fix/issue-$IID")"
if [ "$NEW_TIP" = "$BRANCH_TIP" ]; then
    pass "B6: branch tip unchanged (no corrupting union pushed)"
else
    fail "B6: tip must be unchanged" "before=$BRANCH_TIP after=$NEW_TIP"
fi
# Belt-and-braces: whatever the pushed tip is, it must NOT contain the corruption
# signature (both alpha edits AND a resurrected beta all present at once).
PUSHED_CL="$(git --git-dir="$BARE" show "refs/heads/fix/issue-$IID:CHANGELOG.md" 2>/dev/null)"
if printf '%s' "$PUSHED_CL" | grep -q '^- alpha main-edit$' \
   && printf '%s' "$PUSHED_CL" | grep -q '^- alpha our-edit$'; then
    fail "B6: corrupted union reached the remote" "pushed=[$PUSHED_CL]"
else
    pass "B6: no corrupted union on the remote (both alpha edits are not both present)"
fi
if grep -q 'add-note' "$NOTE_LOG" 2>/dev/null; then
    pass "B6: one human note posted"
else
    fail "B6: human note expected" "log=$(cat "$NOTE_LOG" 2>/dev/null)"
fi

# ===========================================================================
# Z1: the --rebase mode forces merge.conflictStyle=zdiff3 on BOTH the initial
# rebase and the rebase --continue (source-grep regression guard).
# ===========================================================================
ZD_COUNT="$(grep -c 'merge.conflictStyle=zdiff3' "$ORCH" 2>/dev/null || echo 0)"
if [ "$ZD_COUNT" -ge 2 ]; then
    pass "Z1: --rebase forces merge.conflictStyle=zdiff3 on both rebase + rebase --continue"
else
    fail "Z1: zdiff3 forced" "expected >=2 merge.conflictStyle=zdiff3 in ORCH, got $ZD_COUNT"
fi

# ===========================================================================
# J1: code-edit-job.sh forwards --rebase (and a normal run does not). The slow
# orchestrator is replaced by a stub pointed at via CODE_EDIT_ORCH.
# ===========================================================================
STUB_ORCH="$WORK/stub-orch.sh"
cat > "$STUB_ORCH" <<'STUB_EOF'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_MARKER:-}" ]; then echo "args=[$*]" >> "$STUB_MARKER"; fi
printf '%s\n' "REBASED fix/issue-${STUB_IID:-0}"
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

REB_MARKER="$WORK/reb-marker"; : > "$REB_MARKER"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB_ORCH" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    STUB_MARKER="$REB_MARKER" STUB_IID=80 \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 80 \
        --branch "fix/issue-80" --title "chore: auto-rebase #80" \
        --task "Rebase." --rebase >/dev/null 2>&1
poll_done "$(job_dir_for 80)" || true
if grep -q -- '--rebase' "$REB_MARKER" 2>/dev/null; then
    pass "J1: code-edit-job.sh forwards --rebase to the orchestrator"
else
    fail "J1: --rebase passthrough" "marker=$(cat "$REB_MARKER" 2>/dev/null)"
fi

NOREB_MARKER="$WORK/noreb-marker"; : > "$NOREB_MARKER"
env COLONY_DIR="$COLONY_DIR" CODE_EDIT_ORCH="$STUB_ORCH" GITHUB_TOKEN="$FAKE_TOKEN" \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" \
    STUB_MARKER="$NOREB_MARKER" STUB_IID=81 \
    bash "$LAUNCHER" --owner "$OWNER" --repo "$REPO" --issue 81 \
        --branch "fix/issue-81" --title "normal" --task "do it" >/dev/null 2>&1
poll_done "$(job_dir_for 81)" || true
if grep -q -- '--rebase' "$NOREB_MARKER" 2>/dev/null; then
    fail "J2: normal run wrongly forwarded --rebase" "marker=$(cat "$NOREB_MARKER" 2>/dev/null)"
else
    pass "J2: a normal run does NOT forward --rebase"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
