#!/usr/bin/env bash
# tools/code-edit-in-checkout.sh (#1210): drive Claude Code (via flat-cyborg) to
# edit files DIRECTLY in a local git checkout, then commit the resulting
# `git diff` and open a PR.
#
# This replaces the brittle "generate edit-JSON -> apply-line-edits.py ->
# commit-files via the forge Git Database API" path that code_writer used on the
# autonomous tier. That path round-trips file CONTENT through flat-cyborg's TUI
# screen-scrape, which line-wraps and corrupts the structured JSON for large
# files (#1152 / #1195 / #1208). Editing in a real checkout sidesteps the
# screen-scrape entirely: claude's own file tools touch the working tree, and we
# commit whatever `git diff` shows. flat-cyborg stays the ONLY backend; the
# metered `claude -p` API is NOT used here.
#
# Usage:
#   code-edit-in-checkout.sh --owner <o> --repo <r> --issue <iid> \
#       --branch <name> --title <t> --task <text> [--decompose]
#
#   --decompose first drives claude to split <task> into an ordered list of
#   sub-edits, then runs the edit+verify loop once per subtask on the same
#   branch -> one commit/PR (code_writer passes it for epic-labelled issues).
#   Set FORGE_TYPE=gitlab to run the same clone -> edit -> verify -> commit ->
#   MR loop against GitLab (GITHUB_* / GITLAB_* env supplies the host + token).
#
# The forge token is read from the environment (GITHUB_TOKEN). It is NEVER
# embedded in a remote URL on disk, never echoed, and never visible under
# `set -x` (we deliberately do not enable `set -x`, and the token only flows
# through GIT_ASKPASS — see below).
#
# Token auth WITHOUT leaking the token:
#   We point git at a one-line GIT_ASKPASS helper (a temp script) that prints
#   the token from the environment when git asks for the HTTPS password, and a
#   constant ("x-access-token") for the username. The remote URL stored in the
#   checkout's `.git/config` is the plain https://<host>/<owner>/<repo>.git with
#   NO credentials in it. git invokes the helper out-of-band over a pipe, so the
#   token never appears in argv, in the remote URL, in `ps`, or in any log line.
#
# Exit codes:
#   0  PR opened (URL printed on stdout)
#   3  NO_EDITS — claude made no change to the tree (caller retries later; this
#      is NOT an error and must NOT open an empty PR)
#   other  failure (clone/branch/edit/commit/push/PR-open)
#
# Knobs (env vars):
#   FLAT_CYBORG_IDLE_MS          flat-cyborg idle settle window (default 8000)
#   CODE_EDIT_TIMEOUT_MS         per-attempt flat-cyborg edit timeout (600000)
#   CODE_EDIT_MAX_ATTEMPTS       continue-on-incomplete attempts (3)
#   CODE_EDIT_TOTAL_BUDGET_MS    overall wall-clock budget across attempts (1500000)
#   CODE_EDIT_VERIFY_CMD         verify gate command after a settled attempt
#                                (else auto-detect npm test / make test / pytest;
#                                empty = fast change-scoped check; `true` = skip)
#   CODE_EDIT_VERIFY_TIMEOUT_MS  verify gate timeout (300000)
#   CODE_EDIT_MAX_SUBTASKS       --decompose subtask cap (8)
#   FORGE_TYPE                   github (default) | gitlab
set -eu

# ---------------------------------------------------------------------------
# Arg parsing.
# ---------------------------------------------------------------------------
OWNER=""
REPO=""
ISSUE=""
BRANCH=""
TITLE=""
TASK=""
DECOMPOSE=0

usage() {
    echo "usage: code-edit-in-checkout.sh --owner <o> --repo <r> --issue <iid> --branch <name> --title <t> --task <text> [--decompose]" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --owner)  OWNER="${2:-}";  shift 2 ;;
        --repo)   REPO="${2:-}";   shift 2 ;;
        --issue)  ISSUE="${2:-}";  shift 2 ;;
        --branch) BRANCH="${2:-}"; shift 2 ;;
        --title)  TITLE="${2:-}";  shift 2 ;;
        --task)   TASK="${2:-}";   shift 2 ;;
        --decompose) DECOMPOSE=1; shift ;;
        *) echo "code-edit-in-checkout.sh: unknown flag: $1" >&2; usage; exit 2 ;;
    esac
done

# Legacy single-block fan-out (#316): the .ag passes empty --owner/--repo (the
# iter-repos sentinel) and the colony env carries the real values in
# GITHUB_OWNER/GITHUB_REPO. Resolve them here so the multi-repo and legacy paths
# share one orchestrator.
if [ -z "$OWNER" ]; then OWNER="${GITHUB_OWNER:-}"; fi
if [ -z "$REPO" ]; then REPO="${GITHUB_REPO:-}"; fi

if [ -z "$OWNER" ] || [ -z "$REPO" ] || [ -z "$ISSUE" ] || [ -z "$BRANCH" ] || [ -z "$TITLE" ] || [ -z "$TASK" ]; then
    echo "code-edit-in-checkout.sh: --owner, --repo, --issue, --branch, --title, --task are all required" >&2
    usage
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Forge selection (#1213). The orchestrator is forge-agnostic: github (default)
# or gitlab. Exported so the GIT_ASKPASS helper (a subprocess of git) can branch
# on it. The per-repo token resolution and clone/auth/create-mr blocks below all
# key off $FORGE_TYPE.
FORGE_TYPE="${FORGE_TYPE:-github}"
export FORGE_TYPE
case "$FORGE_TYPE" in
    github|gitlab) ;;
    *)
        echo "code-edit-in-checkout.sh: unknown FORGE_TYPE '$FORGE_TYPE' (expected github|gitlab)" >&2
        exit 2
        ;;
esac

# Per-repo token re-resolution (#1212). In multi-repo mode (#316) start-colony
# exports GITHUB_TOKEN as the FIRST repo's token, so cloning/pushing/opening a
# PR for a NON-first repo would auth with the wrong credential. Mirror
# forge-api.sh's `--repo` dispatch: when GITHUB_REPOS_JSON is present, re-resolve
# owner/repo to its OWN token/url/me via tools/forge-resolve-repo.py and override
# the inherited GITHUB_* env. The token rides only the helper's stdout (consumed
# by `eval`), never argv — no leak. Single-repo configs (no GITHUB_REPOS_JSON)
# are unaffected and keep the inherited token. GitLab parity is tracked by #1213.
if [ "${FORGE_TYPE:-github}" = "github" ] && [ -n "${GITHUB_REPOS_JSON:-}" ]; then
    LOOKUP="$SCRIPT_DIR/forge-resolve-repo.py"
    if [ ! -f "$LOOKUP" ]; then
        echo "code-edit-in-checkout.sh: per-repo token helper missing: $LOOKUP" >&2
        exit 1
    fi
    RESOLVED="$(python3 "$LOOKUP" "$OWNER" "$REPO")" || {
        echo "code-edit-in-checkout.sh: --repo $OWNER/$REPO not in GITHUB_REPOS_JSON" >&2
        exit 1
    }
    eval "$RESOLVED"
    export GITHUB_OWNER GITHUB_REPO GITHUB_TOKEN GITHUB_URL GITHUB_ME
fi

# Presence-only check via `${VAR:+x}` so the token VALUE is never expanded onto a
# command line (stays out of any external `set -x` trace): the expansion yields
# the literal `x` when the token is set+non-empty, empty otherwise. The value
# itself is only ever read by the GIT_ASKPASS helper and inherited by the forge
# API wrapper — never named in this script. In multi-repo (github) mode this
# validates the RESOLVED per-repo token (the block above ran first).
if [ "$FORGE_TYPE" = "gitlab" ]; then
    if [ -z "${GITLAB_TOKEN:+x}" ]; then
        echo "code-edit-in-checkout.sh: GITLAB_TOKEN must be set in the environment" >&2
        exit 1
    fi
else
    if [ -z "${GITHUB_TOKEN:+x}" ]; then
        echo "code-edit-in-checkout.sh: GITHUB_TOKEN must be set in the environment" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Resolve FED_DIR + colony name the same way the rest of the federation does.
# The colony's .ag agents run with COLONY_DIR exported (e.g.
# <fed>/implementation); FED_DIR is its grandparent. We derive a colony label
# from COLONY_DIR's basename so the per-colony workspace path is stable. Both
# fall back to cwd-relative values so the script is testable standalone.
# ---------------------------------------------------------------------------
if [ -n "${COLONY_DIR:-}" ]; then
    FED_DIR="$(cd "$COLONY_DIR/.." && pwd)"
    COLONY_NAME="$(basename "$COLONY_DIR")"
else
    FED_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    COLONY_NAME="implementation"
fi

GITHUB_URL="${GITHUB_URL:-https://api.github.com}"
# Pick the API base per forge. github: the API base (api.github.com or a GHE
# /api/v3 base). gitlab: the INSTANCE url (e.g. https://gitlab.com) — gitlab-api.sh
# itself appends /api/v4/projects/<id>.
if [ "$FORGE_TYPE" = "gitlab" ]; then
    API_BASE="${GITLAB_URL:-https://gitlab.com}"
else
    API_BASE="$GITHUB_URL"
fi
# Derive the git host base from the API base. github api.github.com -> github.com;
# a GHE / GitLab base like https://host/api/<v> -> https://host (the else-branch
# drops the /api path). A schemeless-host URL (file:// — used by the offline test
# harness, never in production) forwards its path verbatim so a local bare repo
# can stand in for the remote.
GIT_HOST="$(API_BASE="$API_BASE" FORGE_TYPE="$FORGE_TYPE" python3 -c '
import os
from urllib.parse import urlsplit
u = urlsplit(os.environ["API_BASE"])
host = u.netloc
if u.scheme == "file":
    # file:///path -> file:///path (path carries the location, no netloc).
    print("file://" + u.path.rstrip("/"))
elif os.environ["FORGE_TYPE"] == "github" and host == "api.github.com":
    print("https://github.com")
else:
    print(u.scheme + "://" + host)
')"
CLONE_URL="$GIT_HOST/$OWNER/$REPO.git"

# ---------------------------------------------------------------------------
# Token auth: a GIT_ASKPASS helper that prints the token from the env. The
# token never lands in the remote URL, argv, or any log line.
# ---------------------------------------------------------------------------
ASKPASS="$(mktemp)"
# The helper distinguishes git's two prompts ("Username for ..." vs
# "Password for ...") and answers each. It branches on FORGE_TYPE (a non-secret
# var, inherited from the env): GitHub uses username "x-access-token" + the PAT;
# GitLab uses username "oauth2" + the PAT. The token rides $GITHUB_TOKEN /
# $GITLAB_TOKEN in the env this helper inherits and is read ONLY here, in a
# subprocess — it is never written into this file nor named in the parent script.
cat > "$ASKPASS" <<'ASKPASS_EOF'
#!/usr/bin/env sh
if [ "${FORGE_TYPE:-github}" = "gitlab" ]; then
    case "$1" in
        *Username*|*username*) printf '%s' "oauth2" ;;
        *) printf '%s' "${GITLAB_TOKEN}" ;;
    esac
else
    case "$1" in
        *Username*|*username*) printf '%s' "x-access-token" ;;
        *) printf '%s' "${GITHUB_TOKEN}" ;;
    esac
fi
ASKPASS_EOF
chmod 700 "$ASKPASS"

# A task file for flat-cyborg --cmd-file (a multi-KB instruction must not ride
# argv — ARG_MAX, same lesson as #1171). Cleaned up on exit alongside ASKPASS.
TASKFILE="$(mktemp)"
trap 'rm -f "$ASKPASS" "$TASKFILE" "${VERIFY_OUT:-}" "${SUBTASKS_FILE:-}" "${SUBTASKS_LIST:-}"' EXIT

# git wrappers that thread the askpass helper + non-interactive terminal so a
# missing/invalid token fails fast instead of hanging on a prompt.
#   run_git      : side-effecting commands — git's chatter ("Your branch is up
#                  to date", "branch ... set up to track ...") is routed to
#                  stderr so ONLY the final PR URL ever reaches our stdout.
#   git_capture  : commands whose stdout we need to read (e.g. symbolic-ref).
run_git() {
    GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 git "$@" >&2
}
git_capture() {
    GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 git "$@"
}

# ---------------------------------------------------------------------------
# 1. Workspace: idempotent fresh clone/reset, ISOLATED PER JOB (#1248).
# ---------------------------------------------------------------------------
# Key the checkout by issue so concurrent detached jobs never share a working
# tree. code_writer launches one detached job per ~60s tick while each job runs
# for minutes, so several run at once; a single shared checkout let a second
# job's `git checkout -B fix/issue-B` switch the branch out from under the first
# → the first job's commit landed on the WRONG branch and its create-mr failed
# ("No commits between main and fix/issue-A"). Per-issue dirs give each job its
# own tree. A retry of the SAME issue still reuses its own dir (fetch+reset);
# different issues are fully isolated.
WS="$FED_DIR/.agentis/workspaces/$COLONY_NAME/$OWNER-$REPO/issue-$ISSUE"

if [ -d "$WS/.git" ]; then
    echo "[code-edit] reusing workspace $WS" >&2
    run_git -C "$WS" remote set-url origin "$CLONE_URL"
    run_git -C "$WS" fetch origin
else
    echo "[code-edit] cloning $OWNER/$REPO into $WS" >&2
    rm -rf "$WS"
    mkdir -p "$(dirname "$WS")"
    run_git clone "$CLONE_URL" "$WS"
fi

# Resolve the default branch from the remote HEAD (origin/HEAD -> origin/<def>).
DEFAULT_BRANCH="$(git_capture -C "$WS" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
if [ -z "$DEFAULT_BRANCH" ]; then
    # Fall back to GITLAB_DEFAULT_BRANCH (the cross-backend default-branch env
    # the federation already exports), then to main.
    DEFAULT_BRANCH="${GITLAB_DEFAULT_BRANCH:-main}"
fi

# Idempotent fresh state on the default branch.
run_git -C "$WS" checkout "$DEFAULT_BRANCH"
run_git -C "$WS" reset --hard "origin/$DEFAULT_BRANCH"
run_git -C "$WS" clean -fd

# ---------------------------------------------------------------------------
# 2. Branch: deterministic per-issue (reuse, no empty-branch litter).
# ---------------------------------------------------------------------------
run_git -C "$WS" checkout -B "$BRANCH" "origin/$DEFAULT_BRANCH"

# Reap any process still rooted in THIS job's per-issue workspace (#1249).
# flat-cyborg's --timeout-ms ends the editing session but does NOT kill claude's
# grandchildren — e.g. a Bash-tool `until …; do :; done` wait loop claude
# launched — which then orphan (re-parent to init) and peg a CPU core
# indefinitely. Matching by cwd is precise BECAUSE $WS is per-issue (#1248): the
# daemons (cwd = fed dir) and concurrent jobs (other per-issue workspaces) never
# match, and the orchestrator runs git via `git -C "$WS"` with its OWN cwd
# OUTSIDE $WS, so it is not a match either. Called after every editing run.
reap_editing_strays() {
    ws_real="$(cd "$WS" 2>/dev/null && pwd -P)" || return 0
    [ -n "$ws_real" ] || return 0
    for _cwd_link in /proc/[0-9]*/cwd; do
        _tgt="$(readlink "$_cwd_link" 2>/dev/null)" || continue
        case "$_tgt" in
            "$ws_real"|"$ws_real"/*)
                _pid="${_cwd_link#/proc/}"; _pid="${_pid%/cwd}"
                if [ "$_pid" != "$$" ]; then
                    kill -KILL "$_pid" 2>/dev/null || true
                fi
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 3. Edit: run claude (via flat-cyborg) as an editing agent inside the
#    checkout. We mirror flat-cyborg-claude.sh's FULL flag set, including
#    --extract --extract-structural --wrap-input 72. Earlier this path dropped
#    those flags on the theory that an editing agent makes file changes with its
#    own tools and never needs a scraped reply — but #1221 showed that without
#    --extract flat-cyborg does NOT reliably drive the interactive Claude session
#    to submit-and-act: the prompt is typed but never executed, so claude sits
#    idle at the input bar until --timeout-ms and produces NO edit (reproduced
#    live, even for a one-line edit). --extract is what makes flat-cyborg wait
#    for the session to be ready, submit the prompt, and let claude run to a
#    settled screen. We do NOT consume its scraped reply here (the artifact is
#    the git diff), and we redirect flat-cyborg's stdout to stderr so the
#    scraped screen text can never contaminate this script's stdout, which must
#    stay the PR URL alone. --wrap-input 72 folds the (large) task prompt so it
#    does not overflow claude's input editor; --cwd points claude at the
#    checkout; --auto-approve writes without an interactive confirm.
# ---------------------------------------------------------------------------
# staged_line_count: total churn (added+removed) of the staged diff; 0 when the
# tree is clean. Used to detect PROGRESS between attempts. Binary files report
# numstat "-" for added/removed, treated as 0.
staged_line_count() {
    run_git -C "$WS" add -A
    git_capture -C "$WS" diff --cached --numstat 2>/dev/null \
        | awk '{ a = ($1 == "-" ? 0 : $1); d = ($2 == "-" ? 0 : $2); s += a + d } END { print s + 0 }'
}

# detect_verify_cmd (#1253, #1262): the explicit verify command run in $WS.
# CODE_EDIT_VERIFY_CMD wins; else a FAST project gate (npm/make/pytest). We do
# NOT auto-pick the repo's full lint (e.g. tools/colony-lint.sh) — it is heavy
# and flaky under the federation's load and false-fails (#1262, found live on
# #1260). Empty result means "use the built-in LIGHT, change-scoped gate"
# (run_light_verify); the PR's own CI remains the authoritative full gate.
# CODE_EDIT_VERIFY_CMD=true force-skips (always passes).
detect_verify_cmd() {
    if [ -n "${CODE_EDIT_VERIFY_CMD:-}" ]; then printf '%s' "$CODE_EDIT_VERIFY_CMD"; return 0; fi
    if [ -f "$WS/package.json" ] && grep -q '"test"' "$WS/package.json" 2>/dev/null; then printf '%s' 'npm test --silent'; return 0; fi
    if [ -f "$WS/Makefile" ] && grep -qE '^test:' "$WS/Makefile" 2>/dev/null; then printf '%s' 'make test'; return 0; fi
    if [ -d "$WS/tests" ] && command -v pytest >/dev/null 2>&1; then printf '%s' 'pytest -q'; return 0; fi
    printf '%s' ''
}

# run_verify <cmd>: run the gate inside $WS, time-bounded and token-scrubbed (the
# gate never needs forge creds), combined output captured to $VERIFY_OUT. Returns
# the gate's exit code.
run_verify() {
    _vt_s=$(( VERIFY_TIMEOUT_MS / 1000 ))
    [ "$_vt_s" -lt 1 ] && _vt_s=1
    if command -v timeout >/dev/null 2>&1; then
        ( cd "$WS" && env -u GITHUB_TOKEN -u GITLAB_TOKEN timeout "${_vt_s}s" sh -c "$1" ) >"$VERIFY_OUT" 2>&1
    else
        ( cd "$WS" && env -u GITHUB_TOKEN -u GITLAB_TOKEN sh -c "$1" ) >"$VERIFY_OUT" 2>&1
    fi
}

# run_light_verify (#1262): the built-in change-scoped gate used when no explicit
# CODE_EDIT_VERIFY_CMD / fast project gate is detected. Over the STAGED changed
# files only: `bash -n` + `shellcheck` on changed *.sh, and RUN any changed
# test-*.sh (token-scrubbed + time-bounded). Fast and flake-free vs the full repo
# lint; the PR's own CI is the authoritative full gate. Output -> $VERIFY_OUT,
# returns 0 (all clean) or 1.
run_light_verify() {
    : > "$VERIFY_OUT"
    _lv_rc=0
    _lv_tt=$(( VERIFY_TIMEOUT_MS / 1000 ))
    [ "$_lv_tt" -lt 1 ] && _lv_tt=1
    _lv_list="$(mktemp)"
    git_capture -C "$WS" diff --cached --name-only --diff-filter=d > "$_lv_list" 2>/dev/null || true
    # FD 8 so the inner test runs do not consume this list.
    while IFS= read -r _lv_f <&8; do
        [ -n "$_lv_f" ] || continue
        case "$_lv_f" in
            *.sh)
                echo "[light-verify] check $_lv_f" >> "$VERIFY_OUT"
                if ! bash -n "$WS/$_lv_f" >>"$VERIFY_OUT" 2>&1; then _lv_rc=1; fi
                if command -v shellcheck >/dev/null 2>&1; then
                    if ! ( cd "$WS" && shellcheck "$_lv_f" ) >>"$VERIFY_OUT" 2>&1; then _lv_rc=1; fi
                fi
                case "$_lv_f" in
                    */test-*.sh|test-*.sh)
                        echo "[light-verify] run $_lv_f" >> "$VERIFY_OUT"
                        if command -v timeout >/dev/null 2>&1; then
                            if ! ( cd "$WS" && env -u GITHUB_TOKEN -u GITLAB_TOKEN timeout "${_lv_tt}s" sh "$_lv_f" ) >>"$VERIFY_OUT" 2>&1; then _lv_rc=1; fi
                        else
                            if ! ( cd "$WS" && env -u GITHUB_TOKEN -u GITLAB_TOKEN sh "$_lv_f" ) >>"$VERIFY_OUT" 2>&1; then _lv_rc=1; fi
                        fi
                        ;;
                esac
                ;;
        esac
    done 8< "$_lv_list"
    rm -f "$_lv_list"
    if [ "$_lv_rc" -eq 0 ]; then echo "[light-verify] no shell issues in changed files" >> "$VERIFY_OUT"; fi
    return "$_lv_rc"
}

# Bounded continue-on-incomplete loop (#1251). A single fixed-timeout shot was
# the main limiter on complex tasks: claude was interrupted mid-edit (exit 124)
# with a partial diff, or simply ran out of one turn, and nobody told it to keep
# going. Now, if a session TIMES OUT but made PROGRESS (the staged diff grew) and
# attempts/budget remain, we re-drive with a "continue, finish it" prompt that
# carries the diff-so-far. A SETTLED session (FC_RC == 0) means claude finished
# its turn — stop looping. Backward-compatible: a task that settles on attempt 1
# behaves exactly as the old single shot (one drive -> commit).
MAX_ATTEMPTS="${CODE_EDIT_MAX_ATTEMPTS:-3}"
TOTAL_BUDGET_MS="${CODE_EDIT_TOTAL_BUDGET_MS:-1500000}"
PER_ATTEMPT_MS="${CODE_EDIT_TIMEOUT_MS:-600000}"
# Harden the numeric knobs: a non-integer / empty override would otherwise make
# `[ -ge ]` print "integer expected" (silently bypassing the attempt gate) or
# abort an `$(( ))` under set -e. Fall back to the defaults on any non-digit value.
case "$MAX_ATTEMPTS"   in ''|*[!0-9]*) MAX_ATTEMPTS=3 ;; esac
case "$TOTAL_BUDGET_MS" in ''|*[!0-9]*) TOTAL_BUDGET_MS=1500000 ;; esac
case "$PER_ATTEMPT_MS"  in ''|*[!0-9]*) PER_ATTEMPT_MS=600000 ;; esac
if [ "$MAX_ATTEMPTS" -lt 1 ]; then MAX_ATTEMPTS=1; fi
# Cap on the number of decomposed sub-edits (#1254). A non-integer / empty
# override falls back to 8; never below 1.
MAX_SUBTASKS="${CODE_EDIT_MAX_SUBTASKS:-8}"
case "$MAX_SUBTASKS" in ''|*[!0-9]*) MAX_SUBTASKS=8 ;; esac
if [ "$MAX_SUBTASKS" -lt 1 ]; then MAX_SUBTASKS=1; fi
# Verify gate (#1253): run the repo's gate after a settled attempt and only stop
# when it passes; feed failures back as another iteration (bounded by the same
# attempts/budget). Empty VERIFY_CMD -> no gate -> M1 behaviour.
VERIFY_CMD="$(detect_verify_cmd)"
VERIFY_TIMEOUT_MS="${CODE_EDIT_VERIFY_TIMEOUT_MS:-300000}"
case "$VERIFY_TIMEOUT_MS" in ''|*[!0-9]*) VERIFY_TIMEOUT_MS=300000 ;; esac
VERIFY_OUT="$(mktemp)"
[ -n "$VERIFY_CMD" ] && echo "[code-edit] verification gate: $VERIFY_CMD" >&2

# Decompose (#1254): for a large/epic task, split it into an ORDERED list of
# small sub-edits and run the edit loop once per subtask on the SAME branch,
# accumulating into ONE commit/PR. Without --decompose (or if decomposition
# yields nothing) the whole task is the single "subtask" -> identical to M1/M2.
SUBTASKS_FILE="$(mktemp)"
if [ "$DECOMPOSE" -eq 1 ]; then
    SUBTASKS_LIST="$(mktemp)"
    : > "$SUBTASKS_LIST"
    {
        printf 'Decompose issue #%s (%s) into an ORDERED list of small, self-contained sub-edits, each about the size of one focused change.\n\n' "$ISSUE" "$TITLE"
        printf 'Base the list SOLELY on the task description below. Do NOT read, search, or explore repository files in this step, and do NOT edit any files — just produce the list immediately.\n'
        printf 'Write ONLY the list to this exact file with your file-writing tool: %s\n' "$SUBTASKS_LIST"
        printf 'One sub-edit per line, plain text, no numbering and no markdown.\n\nIssue task:\n%s\n' "$TASK"
    } > "$TASKFILE"
    echo "[code-edit] decomposing issue #$ISSUE into subtasks" >&2
    set +e
    flat-cyborg --extract --extract-structural --no-jitter --auto-approve --wrap-input 72 --cwd "$WS" \
        --idle-ms "${FLAT_CYBORG_IDLE_MS:-8000}" --timeout-ms "$PER_ATTEMPT_MS" \
        --cmd-file "$TASKFILE" -- claude >&2
    set -e
    reap_editing_strays
    # discard any stray edits the decomposition step made; the subtask loop owns edits.
    run_git -C "$WS" reset --hard >/dev/null 2>&1 || true
    run_git -C "$WS" clean -fd >/dev/null 2>&1 || true
    # Each parsed line becomes a NUL-separated record. NUL (not newline) is the
    # subtask delimiter so the no-decompose fallback below can hold the WHOLE
    # multi-line $TASK as a SINGLE record — the production caller's task_text is
    # always multi-line, and splitting it per line would feed claude fragments.
    awk 'NF' "$SUBTASKS_LIST" 2>/dev/null | sed 's/^[[:space:]]*[-*0-9.)]\{0,4\}[[:space:]]*//' | head -n "$MAX_SUBTASKS" | tr '\n' '\0' > "$SUBTASKS_FILE"
fi
if [ ! -s "$SUBTASKS_FILE" ]; then
    # Single record = the whole task (newlines preserved) -> one subtask -> M1/M2.
    [ "$DECOMPOSE" -eq 1 ] && echo "[code-edit] decomposition produced no subtasks — running the whole task as one (monolithic fallback)" >&2
    printf '%s\0' "$TASK" > "$SUBTASKS_FILE"
fi
SUBTASK_COUNT="$(tr -cd '\0' < "$SUBTASKS_FILE" | wc -c | tr -d ' ')"
[ "$SUBTASK_COUNT" -gt 1 ] && echo "[code-edit] decomposed issue #$ISSUE into $SUBTASK_COUNT subtasks" >&2

subtask_idx=0
while IFS= read -r -d '' CUR_TASK <&3; do
    [ -z "$CUR_TASK" ] && continue
    subtask_idx=$((subtask_idx + 1))
    [ "$SUBTASK_COUNT" -gt 1 ] && echo "[code-edit] subtask $subtask_idx/$SUBTASK_COUNT: $CUR_TASK" >&2
    loop_start="$(date +%s)"
    attempt=0
    prev_lines=0
    FC_RC=0
    continuation_mode="interrupted"

while :; do
    attempt=$((attempt + 1))
    elapsed_ms=$(( ($(date +%s) - loop_start) * 1000 ))
    remaining_ms=$(( TOTAL_BUDGET_MS - elapsed_ms ))
    [ "$remaining_ms" -lt 1000 ] && remaining_ms=1000
    this_timeout="$PER_ATTEMPT_MS"
    [ "$this_timeout" -gt "$remaining_ms" ] && this_timeout="$remaining_ms"

    if [ "$attempt" -eq 1 ]; then
        printf 'Implement issue #%s in this repository by editing the files directly with your tools. %s\n\nBegin editing immediately and keep exploration minimal — the task below already specifies the change; read only the specific files you must modify.\n\n%s\n\nMake the change and stop; do not run git or open a PR.' \
            "$ISSUE" "$TITLE" "$CUR_TASK" > "$TASKFILE"
    elif [ "$continuation_mode" = "verify" ]; then
        # Continuation prompt: the change does not pass the verification gate.
        {
            printf 'You are CONTINUING work on issue #%s: %s\n\n' "$ISSUE" "$TITLE"
            printf 'Your change so far does NOT pass the project verification gate: %s\n\nFiles changed in this checkout:\n\n' "$VERIFY_CMD"
            git_capture -C "$WS" diff --cached --stat 2>/dev/null || true
            printf '\nThe gate output (tail):\n\n'
            tail -c 4000 "$VERIFY_OUT" 2>/dev/null || true
            printf '\n\nFix the change so the gate passes, then stop. Do not run git or open a PR.\n\nIssue task:\n%s\n' "$CUR_TASK"
        } > "$TASKFILE"
        echo "[code-edit] continuing editing session (verify-fix, attempt $attempt/$MAX_ATTEMPTS, ${remaining_ms}ms budget left)" >&2
    else
        # Continuation prompt: claude was interrupted; show what changed so far.
        {
            printf 'You are CONTINUING work on issue #%s: %s\n\n' "$ISSUE" "$TITLE"
            printf 'Your previous turn was interrupted before the change was finished. Files changed so far in this checkout:\n\n'
            git_capture -C "$WS" diff --cached --stat 2>/dev/null || true
            printf '\nReview the current state, COMPLETE the remaining work for the issue below, and stop. Do not run git or open a PR.\n\nIssue task:\n%s\n' "$CUR_TASK"
        } > "$TASKFILE"
        echo "[code-edit] continuing editing session (attempt $attempt/$MAX_ATTEMPTS, ${remaining_ms}ms budget left)" >&2
    fi

    echo "[code-edit] running flat-cyborg editing agent in $WS (attempt $attempt)" >&2
    set +e
    flat-cyborg --extract --extract-structural --no-jitter --auto-approve --wrap-input 72 --cwd "$WS" \
        --idle-ms "${FLAT_CYBORG_IDLE_MS:-8000}" \
        --timeout-ms "$this_timeout" \
        --cmd-file "$TASKFILE" -- claude >&2
    FC_RC=$?
    set -e

    # Reap orphaned editing-session descendants before measuring/looping (#1249).
    reap_editing_strays
    cur_lines="$(staged_line_count)"

    # Settled (claude finished its turn). With a verifier configured + a non-empty
    # diff, "settled" is not "done": run the gate and only stop when it's GREEN;
    # otherwise feed the failure back as another iteration (#1253).
    if [ "$FC_RC" -eq 0 ]; then
        if [ "$cur_lines" -eq 0 ]; then
            break
        fi
        if [ -n "$VERIFY_CMD" ]; then
            echo "[code-edit] verifying ($VERIFY_CMD) ..." >&2
            set +e; run_verify "$VERIFY_CMD"; verify_rc=$?; set -e
        else
            echo "[code-edit] verifying (light change-scoped gate) ..." >&2
            set +e; run_light_verify; verify_rc=$?; set -e
        fi
        if [ "$verify_rc" -eq 0 ]; then
            echo "[code-edit] verification PASSED" >&2
            break
        fi
        if [ "$attempt" -ge "$MAX_ATTEMPTS" ] || [ "$(( ($(date +%s) - loop_start) * 1000 ))" -ge "$TOTAL_BUDGET_MS" ]; then
            echo "[code-edit] verification still FAILING after $attempt attempt(s) (gate exit $verify_rc) — committing anyway; the PR's own CI is the backstop" >&2
            break
        fi
        echo "[code-edit] verification FAILED (gate exit $verify_rc) — feeding the failure back (attempt $attempt -> $((attempt + 1)))" >&2
        continuation_mode="verify"
        prev_lines="$cur_lines"
        continue
    fi
    # Timed out / errored: stop unless we made progress AND budget+attempts remain.
    continuation_mode="interrupted"
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "[code-edit] reached max attempts ($MAX_ATTEMPTS) — committing whatever was produced" >&2
        break
    fi
    if [ "$(( ($(date +%s) - loop_start) * 1000 ))" -ge "$TOTAL_BUDGET_MS" ]; then
        echo "[code-edit] exhausted total edit budget — committing whatever was produced" >&2
        break
    fi
    if [ "$cur_lines" -le "$prev_lines" ]; then
        echo "[code-edit] attempt $attempt timed out (exit $FC_RC) with no new progress (staged churn $cur_lines <= $prev_lines) — stopping" >&2
        break
    fi
    echo "[code-edit] attempt $attempt timed out (exit $FC_RC) but made progress (staged churn $prev_lines -> $cur_lines) — continuing" >&2
    prev_lines="$cur_lines"
done
done 3< "$SUBTASKS_FILE"

# ---------------------------------------------------------------------------
# 4. Commit the diff. The ARTIFACT is the edit, not the editing session's exit
#    code: flat-cyborg drives an interactive Claude Code TUI that frequently
#    never settles to its idle prompt. After the loop above we decide on the
#    final staged diff:
#      * staged change present  -> commit + push + PR, regardless of FC_RC
#        (a timeout that still produced edits is a success, not a failure).
#      * no change + last FC_RC == 0 -> NO_EDITS  => exit 3 (retry, not error).
#      * no change + last FC_RC != 0 -> the session genuinely failed => exit FC_RC.
# ---------------------------------------------------------------------------
run_git -C "$WS" add -A
if run_git -C "$WS" diff --cached --quiet; then
    if [ "$FC_RC" -ne 0 ]; then
        echo "[code-edit] editing agent failed (last exit $FC_RC) and produced no edits" >&2
        exit "$FC_RC"
    fi
    echo "NO_EDITS"
    echo "[code-edit] claude produced no file changes — not committing, not opening a PR" >&2
    exit 3
fi

if [ "$FC_RC" -ne 0 ]; then
    echo "[code-edit] last attempt exited non-zero (exit $FC_RC, likely idle/timeout) but edits were produced — committing the diff" >&2
fi

run_git -C "$WS" commit -m "feat: $TITLE (#$ISSUE)"
run_git -C "$WS" push --force-with-lease origin "$BRANCH"

# ---------------------------------------------------------------------------
# 5. Open the PR/MR via the colony's forge API wrapper create-mr verb. The
#    wrapper reads its token from the env (already present here) and prints the
#    forge's PR/MR JSON; we extract the URL and print it on stdout. The verb +
#    flags (--source/--title/--description) are forge-symmetric; only the env
#    contract differs (github: OWNER/REPO/URL; gitlab: PROJECT/URL).
# ---------------------------------------------------------------------------
DESCRIPTION="Implements #$ISSUE.

$TASK"

if [ "$FORGE_TYPE" = "gitlab" ]; then
    FORGE_API="$FED_DIR/$COLONY_NAME/scripts/gitlab-api.sh"
else
    FORGE_API="$FED_DIR/$COLONY_NAME/scripts/github-api.sh"
fi
if [ ! -x "$FORGE_API" ]; then
    echo "[code-edit] $FORGE_TYPE-api.sh not found/executable at $FORGE_API" >&2
    exit 1
fi

# `env` (not a plain VAR=val prefix on the assignment) so the wrapper subprocess
# inherits OWNER/REPO/PROJECT/URL/default-branch cleanly. The token (GITHUB_TOKEN
# / GITLAB_TOKEN) is deliberately NOT named here: it is already in this script's
# inherited environment, so the child inherits it automatically. Never
# referencing the token as an expanded word keeps it out of any external `set -x`
# trace of this script (the token never appears on a command line).
if [ "$FORGE_TYPE" = "gitlab" ]; then
    # gitlab-api.sh wants GITLAB_PROJECT = URL-encoded namespace/project path.
    PR_JSON="$(env \
        GITLAB_URL="$API_BASE" GITLAB_PROJECT="$OWNER%2F$REPO" \
        GITLAB_DEFAULT_BRANCH="$DEFAULT_BRANCH" \
        "$FORGE_API" create-mr --source "$BRANCH" --title "$TITLE" --description "$DESCRIPTION")" || {
            echo "[code-edit] create-mr failed" >&2
            exit 1
        }
else
    PR_JSON="$(env \
        GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" GITHUB_URL="$GITHUB_URL" \
        GITLAB_DEFAULT_BRANCH="$DEFAULT_BRANCH" \
        "$FORGE_API" create-mr --source "$BRANCH" --title "$TITLE" --description "$DESCRIPTION")" || {
            echo "[code-edit] create-mr failed" >&2
            exit 1
        }
fi

PR_URL="$(PR="$PR_JSON" python3 -c '
import os, json, sys
try:
    d = json.loads(os.environ["PR"])
except Exception:
    sys.exit(1)
print(d.get("html_url") or d.get("web_url") or d.get("url") or "")
')" || true

if [ -z "$PR_URL" ]; then
    echo "[code-edit] PR/MR opened but could not parse its URL from the create-mr response" >&2
    exit 1
fi

# Bound disk: the PR is open and the branch pushed, so this per-issue workspace
# (#1248) is no longer needed — remove it so successful issues don't accumulate
# checkouts. The NO_EDITS / failure paths above exit earlier and KEEP their
# workspace so a retry of the same issue reuses it (fetch+reset).
rm -rf "$WS" 2>/dev/null || true

echo "$PR_URL"
exit 0
