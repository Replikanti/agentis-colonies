#!/usr/bin/env bash
# test-mr-pipeline-status-verb.sh (#1355): tests for the `mr-pipeline-status`
# verb in the code-review AND implementation colony forge wrappers
# (github-api.sh / gitlab-api.sh).
#
# mr-pipeline-status is the THIN read-only CI read the bounded red-PR recovery
# loop / auto-merge sweep uses. It prints exactly two space-separated tokens on
# stdout:
#     STATUS=<raw-status> REF=<head-branch>
# The red/green/pending CLASSIFICATION that used to live in the old `pr-checks`
# verb moved OUT of the forge wrapper into the consuming .ag (`ci_state()`) under
# #1355, so this verb no longer maps statuses — it forwards a single raw status
# word:
#   - GitLab forwards the head-pipeline `status` VERBATIM (empty string when the
#     MR has no pipeline yet).
#   - GitHub has no single "pipeline status", so the wrapper still REDUCES the
#     head commit's check-runs to ONE raw word — `success` | `failed` | `pending`
#     — matching the GitLab vocabulary so the .ag classifier stays forge-agnostic.
#     `pending` covers "not verified yet": empty check_runs, any not-`completed`
#     run, OR a pagination overflow (total_count > fetched, never `success`).
#
# This test stubs the forge API via a curl shim that serves canned JSON keyed
# on the request URL (same harness shape as test-merge-verb.sh).
#
# Cases (GitHub + implementation github-api.sh):
#   failed   : a failing/cancelled check ⇒ STATUS=failed
#   pending  : an in_progress check, and (separately) an empty check_runs list
#   success  : all checks success/skipped ⇒ STATUS=success
#   pagination: total_count > fetched ⇒ STATUS=pending (never success)
#   REF      : head.ref echoed correctly
# Cases (GitLab, verbatim status):
#   pipeline failed ⇒ failed; running ⇒ running; success ⇒ success;
#   missing pipeline ⇒ empty STATUS; source_branch ⇒ REF
#
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] test-mr-pipeline-status-verb.sh: python3 not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi

TMPDIR_SHIM="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SHIM"' EXIT

# ---------------------------------------------------------------------------
# GitHub curl shim: serves canned JSON per URL. The pull / check-runs payloads
# for the current scenario live in $SHIM_FIXTURES.
# ---------------------------------------------------------------------------
cat > "$TMPDIR_SHIM/curl-github" <<'CURL_SHIM'
#!/usr/bin/env bash
URL=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X) shift 2 ;;
        -d|--data) shift 2 ;;
        -H) shift 2 ;;
        -G) shift ;;
        --data-urlencode) shift 2 ;;
        -sS|-S|-s|-f) shift ;;
        -w|--max-time) shift 2 ;;
        -o) OUT="$2"; shift 2 ;;
        *) URL="$1"; shift ;;
    esac
done
body=""
code="200"
case "$URL" in
    */commits/*/check-runs)
        body="$(cat "$SHIM_FIXTURES/checks.json")"
        ;;
    */pulls/*)
        body="$(cat "$SHIM_FIXTURES/pull.json")"
        ;;
    *)
        body='{}'
        ;;
esac
if [ -n "$OUT" ]; then
    printf '%s' "$body" > "$OUT"
fi
printf '%s' "$code"
CURL_SHIM
chmod +x "$TMPDIR_SHIM/curl-github"

# ---------------------------------------------------------------------------
# GitLab curl shim: serves the MR JSON for the current scenario.
# ---------------------------------------------------------------------------
cat > "$TMPDIR_SHIM/curl-gitlab" <<'CURL_SHIM'
#!/usr/bin/env bash
URL=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X) shift 2 ;;
        -d|--data) shift 2 ;;
        -H) shift 2 ;;
        -G) shift ;;
        --data-urlencode) shift 2 ;;
        -sS|-S|-s|-f) shift ;;
        -w|--max-time) shift 2 ;;
        -o) OUT="$2"; shift 2 ;;
        *) URL="$1"; shift ;;
    esac
done
body=""
code="200"
case "$URL" in
    */merge_requests/*)
        body="$(cat "$SHIM_FIXTURES/mr.json")"
        ;;
    *)
        body='{}'
        ;;
esac
if [ -n "$OUT" ]; then
    printf '%s' "$body" > "$OUT"
fi
printf '%s' "$code"
CURL_SHIM
chmod +x "$TMPDIR_SHIM/curl-gitlab"

# Install both shims under the name `curl`; the active one is symlinked per call.
make_curl() {
    # $1 = github|gitlab
    rm -f "$TMPDIR_SHIM/curl"
    ln -s "$TMPDIR_SHIM/curl-$1" "$TMPDIR_SHIM/curl"
}

# Each GitHub fixture dir carries pull.json + checks.json.
mk_gh_fixture() {
    # $1 = dir, $2 = pull.json, $3 = checks.json
    mkdir -p "$1"
    printf '%s' "$2" > "$1/pull.json"
    printf '%s' "$3" > "$1/checks.json"
}
mk_gl_fixture() {
    # $1 = dir, $2 = mr.json
    mkdir -p "$1"
    printf '%s' "$2" > "$1/mr.json"
}

run_github() {
    # $1 = script path, $2 = fixtures dir
    make_curl github
    SHIM_FIXTURES="$2" PATH="$TMPDIR_SHIM:$PATH" \
        GITHUB_URL=https://api.github.test GITHUB_TOKEN=tok \
        GITHUB_OWNER=acme GITHUB_REPO=widget \
        "$1" mr-pipeline-status 7 2>/dev/null
}
run_gitlab() {
    make_curl gitlab
    SHIM_FIXTURES="$2" PATH="$TMPDIR_SHIM:$PATH" \
        GITLAB_URL=https://gitlab.test GITLAB_TOKEN=tok \
        GITLAB_PROJECT=acme%2Fwidget \
        "$1" mr-pipeline-status 7 2>/dev/null
}

# ===========================================================================
# GitHub scenarios, run against BOTH the code-review and implementation
# colony github-api.sh (the verb must be byte-equivalent in both).
# ===========================================================================
GH_PULL='{"head": {"sha": "abc123", "ref": "fix/issue-7"}}'
GH_GREEN='{"check_runs": [{"name": "ci", "status": "completed", "conclusion": "success"}, {"name": "lint", "status": "completed", "conclusion": "skipped"}]}'
GH_RED='{"check_runs": [{"name": "ci", "status": "completed", "conclusion": "failure"}]}'
GH_PENDING='{"check_runs": [{"name": "ci", "status": "completed", "conclusion": "success"}, {"name": "e2e", "status": "in_progress", "conclusion": null}]}'
GH_EMPTY='{"check_runs": []}'
GH_PAGINATED='{"total_count": 31, "check_runs": [{"name": "ci", "status": "completed", "conclusion": "success"}, {"name": "lint", "status": "completed", "conclusion": "success"}]}'

for SCRIPT in \
    "$REPO_ROOT/dev-apprenticeship/code-review/scripts/github-api.sh" \
    "$REPO_ROOT/dev-apprenticeship/implementation/scripts/github-api.sh"; do

    label="$(basename "$(dirname "$(dirname "$SCRIPT")")")"
    if [ ! -x "$SCRIPT" ]; then
        fail "github-api.sh ($label)" "not found/executable: $SCRIPT"
        continue
    fi

    # failed
    D="$TMPDIR_SHIM/$label-red"; mk_gh_fixture "$D" "$GH_PULL" "$GH_RED"
    out="$(run_github "$SCRIPT" "$D")"
    if [ "$out" = "STATUS=failed REF=fix/issue-7 MERGEABLE=false" ]; then
        pass "github/$label: failing check ⇒ STATUS=failed (REF echoed)"
    else
        fail "github/$label: failed" "got [$out]"
    fi

    # pending (in_progress)
    D="$TMPDIR_SHIM/$label-pending"; mk_gh_fixture "$D" "$GH_PULL" "$GH_PENDING"
    out="$(run_github "$SCRIPT" "$D")"
    if [ "$out" = "STATUS=pending REF=fix/issue-7 MERGEABLE=false" ]; then
        pass "github/$label: in_progress check ⇒ STATUS=pending"
    else
        fail "github/$label: pending (in_progress)" "got [$out]"
    fi

    # pending (empty check_runs)
    D="$TMPDIR_SHIM/$label-empty"; mk_gh_fixture "$D" "$GH_PULL" "$GH_EMPTY"
    out="$(run_github "$SCRIPT" "$D")"
    if [ "$out" = "STATUS=pending REF=fix/issue-7 MERGEABLE=false" ]; then
        pass "github/$label: empty check_runs ⇒ STATUS=pending (CI not verified)"
    else
        fail "github/$label: pending (empty)" "got [$out]"
    fi

    # success
    D="$TMPDIR_SHIM/$label-green"; mk_gh_fixture "$D" "$GH_PULL" "$GH_GREEN"
    out="$(run_github "$SCRIPT" "$D")"
    if [ "$out" = "STATUS=success REF=fix/issue-7 MERGEABLE=false" ]; then
        pass "github/$label: all success/skipped ⇒ STATUS=success"
    else
        fail "github/$label: success" "got [$out]"
    fi

    # pagination (total_count > fetched, all green) ⇒ pending (never success)
    D="$TMPDIR_SHIM/$label-page"; mk_gh_fixture "$D" "$GH_PULL" "$GH_PAGINATED"
    out="$(run_github "$SCRIPT" "$D")"
    if [ "$out" = "STATUS=pending REF=fix/issue-7 MERGEABLE=false" ]; then
        pass "github/$label: pagination (total_count 31 > 2 fetched) ⇒ STATUS=pending (fail-safe)"
    else
        fail "github/$label: pagination fail-safe" "got [$out]"
    fi

    # non-numeric ⇒ exit 2
    make_curl github
    set +e
    out="$(SHIM_FIXTURES="$D" PATH="$TMPDIR_SHIM:$PATH" \
        GITHUB_URL=https://api.github.test GITHUB_TOKEN=tok \
        GITHUB_OWNER=acme GITHUB_REPO=widget \
        "$SCRIPT" mr-pipeline-status abc 2>&1)"
    rc=$?
    set -e 2>/dev/null || true
    if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi 'numeric'; then
        pass "github/$label: non-numeric pr number ⇒ exit 2 + clear error"
    else
        fail "github/$label: non-numeric" "rc=$rc out=$out"
    fi
done

# ===========================================================================
# GitLab scenarios (code-review + implementation gitlab-api.sh). The raw
# head-pipeline status is forwarded VERBATIM (no red/green/pending mapping).
# ===========================================================================
GL_FAILED='{"source_branch": "fix/issue-7", "head_pipeline": {"status": "failed"}}'
GL_RUNNING='{"source_branch": "fix/issue-7", "head_pipeline": {"status": "running"}}'
GL_SUCCESS='{"source_branch": "fix/issue-7", "head_pipeline": {"status": "success"}}'
GL_MISSING='{"source_branch": "fix/issue-7"}'

for SCRIPT in \
    "$REPO_ROOT/dev-apprenticeship/code-review/scripts/gitlab-api.sh" \
    "$REPO_ROOT/dev-apprenticeship/implementation/scripts/gitlab-api.sh"; do

    label="$(basename "$(dirname "$(dirname "$SCRIPT")")")"
    if [ ! -x "$SCRIPT" ]; then
        fail "gitlab-api.sh ($label)" "not found/executable: $SCRIPT"
        continue
    fi

    D="$TMPDIR_SHIM/$label-gl-failed"; mk_gl_fixture "$D" "$GL_FAILED"
    out="$(run_gitlab "$SCRIPT" "$D")"
    if [ "$out" = "STATUS=failed REF=fix/issue-7" ]; then
        pass "gitlab/$label: pipeline failed ⇒ STATUS=failed (REF echoed)"
    else
        fail "gitlab/$label: failed" "got [$out]"
    fi

    D="$TMPDIR_SHIM/$label-gl-running"; mk_gl_fixture "$D" "$GL_RUNNING"
    out="$(run_gitlab "$SCRIPT" "$D")"
    if [ "$out" = "STATUS=running REF=fix/issue-7" ]; then
        pass "gitlab/$label: pipeline running ⇒ STATUS=running (verbatim)"
    else
        fail "gitlab/$label: running" "got [$out]"
    fi

    D="$TMPDIR_SHIM/$label-gl-success"; mk_gl_fixture "$D" "$GL_SUCCESS"
    out="$(run_gitlab "$SCRIPT" "$D")"
    if [ "$out" = "STATUS=success REF=fix/issue-7" ]; then
        pass "gitlab/$label: pipeline success ⇒ STATUS=success"
    else
        fail "gitlab/$label: success" "got [$out]"
    fi

    D="$TMPDIR_SHIM/$label-gl-missing"; mk_gl_fixture "$D" "$GL_MISSING"
    out="$(run_gitlab "$SCRIPT" "$D")"
    if [ "$out" = "STATUS= REF=fix/issue-7" ]; then
        pass "gitlab/$label: missing pipeline ⇒ empty STATUS (CI not verified)"
    else
        fail "gitlab/$label: empty (missing)" "got [$out]"
    fi

    make_curl gitlab
    set +e
    out="$(SHIM_FIXTURES="$D" PATH="$TMPDIR_SHIM:$PATH" \
        GITLAB_URL=https://gitlab.test GITLAB_TOKEN=tok GITLAB_PROJECT=acme%2Fwidget \
        "$SCRIPT" mr-pipeline-status abc 2>&1)"
    rc=$?
    set -e 2>/dev/null || true
    if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi 'numeric'; then
        pass "gitlab/$label: non-numeric iid ⇒ exit 2 + clear error"
    else
        fail "gitlab/$label: non-numeric" "rc=$rc out=$out"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
