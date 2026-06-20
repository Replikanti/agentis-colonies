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
#       --branch <name> --title <t> --task <text>
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
# Knobs (env vars): FLAT_CYBORG_IDLE_MS, FLAT_CYBORG_TIMEOUT_MS,
#                   CODE_EDIT_TIMEOUT_MS (overall flat-cyborg edit timeout,
#                   default 600000).
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

usage() {
    echo "usage: code-edit-in-checkout.sh --owner <o> --repo <r> --issue <iid> --branch <name> --title <t> --task <text>" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --owner)  OWNER="${2:-}";  shift 2 ;;
        --repo)   REPO="${2:-}";   shift 2 ;;
        --issue)  ISSUE="${2:-}";  shift 2 ;;
        --branch) BRANCH="${2:-}"; shift 2 ;;
        --title)  TITLE="${2:-}";  shift 2 ;;
        --task)   TASK="${2:-}";   shift 2 ;;
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

# Presence-only check via `${GITHUB_TOKEN:+x}` so the token VALUE is never
# expanded onto a command line (stays out of any external `set -x` trace): the
# expansion yields the literal `x` when the token is set+non-empty, empty
# otherwise. The value itself is only ever read by the GIT_ASKPASS helper and
# inherited by github-api.sh — never named in this script.
if [ -z "${GITHUB_TOKEN:+x}" ]; then
    echo "code-edit-in-checkout.sh: GITHUB_TOKEN must be set in the environment" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
# Derive the git host base from the API base. api.github.com -> github.com;
# a GHE API base like https://ghe.example.com/api/v3 -> https://ghe.example.com.
# A schemeless-host URL (file:// — used by the offline test harness, never in
# production) forwards its path verbatim so a local bare repo can stand in for
# the remote.
GIT_HOST="$(GH_URL="$GITHUB_URL" python3 -c '
import os
from urllib.parse import urlsplit
u = urlsplit(os.environ["GH_URL"])
host = u.netloc
if u.scheme == "file":
    # file:///path -> file:///path (path carries the location, no netloc).
    print("file://" + u.path.rstrip("/"))
elif host == "api.github.com":
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
# "Password for ...") and answers each. Token rides $GITHUB_TOKEN in the env it
# inherits; it is never written into this file.
cat > "$ASKPASS" <<'ASKPASS_EOF'
#!/usr/bin/env sh
case "$1" in
    *Username*|*username*) printf '%s' "x-access-token" ;;
    *) printf '%s' "${GITHUB_TOKEN}" ;;
esac
ASKPASS_EOF
chmod 700 "$ASKPASS"

# A task file for flat-cyborg --cmd-file (a multi-KB instruction must not ride
# argv — ARG_MAX, same lesson as #1171). Cleaned up on exit alongside ASKPASS.
TASKFILE="$(mktemp)"
trap 'rm -f "$ASKPASS" "$TASKFILE"' EXIT

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
# 1. Workspace: idempotent fresh clone/reset.
# ---------------------------------------------------------------------------
WS="$FED_DIR/.agentis/workspaces/$COLONY_NAME/$OWNER-$REPO"

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

# ---------------------------------------------------------------------------
# 3. Edit: run claude (via flat-cyborg) as an editing agent inside the
#    checkout. We mirror flat-cyborg-claude.sh's flags MINUS --extract /
#    --extract-structural: here claude EDITS files with its own tools, so we do
#    not need to scrape a reply off the screen. --cwd points it at the checkout;
#    --auto-approve lets it write without an interactive confirm; --no-jitter +
#    the idle/timeout knobs keep behaviour identical to the wrapper.
# ---------------------------------------------------------------------------
printf 'Implement issue #%s in this repository by editing the files directly with your tools. %s\n\n%s\n\nMake the change and stop; do not run git or open a PR.' \
    "$ISSUE" "$TITLE" "$TASK" > "$TASKFILE"

echo "[code-edit] running flat-cyborg editing agent in $WS" >&2
set +e
flat-cyborg --no-jitter --auto-approve --cwd "$WS" \
    --idle-ms "${FLAT_CYBORG_IDLE_MS:-8000}" \
    --timeout-ms "${CODE_EDIT_TIMEOUT_MS:-600000}" \
    --cmd-file "$TASKFILE" -- claude
FC_RC=$?
set -e
if [ "$FC_RC" -ne 0 ]; then
    echo "[code-edit] flat-cyborg editing agent failed (exit $FC_RC)" >&2
    exit "$FC_RC"
fi

# ---------------------------------------------------------------------------
# 4. Commit the diff. No staged change => NO_EDITS => exit 3 (retry, not error).
# ---------------------------------------------------------------------------
run_git -C "$WS" add -A
if run_git -C "$WS" diff --cached --quiet; then
    echo "NO_EDITS"
    echo "[code-edit] claude produced no file changes — not committing, not opening a PR" >&2
    exit 3
fi

run_git -C "$WS" commit -m "feat: $TITLE (#$ISSUE)"
run_git -C "$WS" push --force-with-lease origin "$BRANCH"

# ---------------------------------------------------------------------------
# 5. Open the PR via the colony's github-api.sh create-mr verb. That wrapper
#    reads GITHUB_TOKEN/OWNER/REPO from the env (already present here) and prints
#    the GitHub PR JSON; we extract html_url and print it on stdout.
# ---------------------------------------------------------------------------
GITHUB_API="$FED_DIR/$COLONY_NAME/scripts/github-api.sh"
DESCRIPTION="Implements #$ISSUE.

$TASK"

if [ ! -x "$GITHUB_API" ]; then
    echo "[code-edit] github-api.sh not found/executable at $GITHUB_API" >&2
    exit 1
fi

# `env` (not a plain VAR=val prefix on the assignment) so the github-api.sh
# subprocess inherits OWNER/REPO/URL/default-branch cleanly. GITHUB_TOKEN is
# deliberately NOT named here: it is already in this script's inherited
# environment, so the child inherits it automatically. Never referencing
# $GITHUB_TOKEN as an expanded word keeps the token out of any external `set -x`
# trace of this script (the token never appears on a command line).
PR_JSON="$(env \
    GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" GITHUB_URL="$GITHUB_URL" \
    GITLAB_DEFAULT_BRANCH="$DEFAULT_BRANCH" \
    "$GITHUB_API" create-mr --source "$BRANCH" --title "$TITLE" --description "$DESCRIPTION")" || {
        echo "[code-edit] create-mr failed" >&2
        exit 1
    }

PR_URL="$(PR="$PR_JSON" python3 -c '
import os, json, sys
try:
    d = json.loads(os.environ["PR"])
except Exception:
    sys.exit(1)
print(d.get("html_url") or d.get("url") or "")
')" || true

if [ -z "$PR_URL" ]; then
    echo "[code-edit] PR opened but could not parse html_url from create-mr response" >&2
    exit 1
fi

echo "$PR_URL"
exit 0
