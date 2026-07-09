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
#       --branch <name> --title <t> --task <text> [--decompose] [--recover]
#
#   --decompose first drives claude to split <task> into an ordered list of
#   sub-edits, then runs the edit+verify loop once per subtask on the same
#   branch -> one commit/PR (code_writer passes it for epic-labelled issues).
#   Set FORGE_TYPE=gitlab to run the same clone -> edit -> verify -> commit ->
#   MR loop against GitLab (GITHUB_* / GITLAB_* env supplies the host + token).
#
#   --decompose-only --subtasks-out <file> (#1422 M1) runs ONLY the
#   decomposition drive (implies --decompose) and writes the ordered
#   NUL-delimited subtask list to <file>, then prints a single line
#       DECOMPOSED count=<n>
#   and exits 0 BEFORE the per-subtask loop — no edit, no commit, no PR. It
#   surfaces decomposition as a stand-alone primitive so code_writer.ag can
#   drive the per-subtask edit sequence itself (the AG-driven decompose loop),
#   exactly as --one-attempt surfaced the single edit drive. The monolithic
#   fallback guarantees count>=1. <file> must live OUTSIDE the per-issue job dir
#   so the caller's job-dir cleanup cannot reap it.
#
#   --recover (#1332) re-drives an EXISTING PR's branch whose CI went red.
#   Instead of cutting a fresh branch off the default branch, it checks OUT the
#   existing remote head branch (which already carries the prior commit), FORCES
#   the verify gate ON (an empty CODE_EDIT_VERIFY_CMD cannot skip it — the gate
#   reproduces the red CI locally and the loop iterates to fix it), and on a new
#   commit it PUSHES the branch only — the PR already exists, so it NEVER opens a
#   second PR. Exit 0 if it pushed a fix, 3 (NO_EDITS) if the loop produced
#   nothing new.
#
#   --one-attempt (#1406, #1354 step 1) runs exactly ONE flat-cyborg editing
#   attempt in the prepared workspace — no internal retry/continue loop, no
#   commit, no PR — and prints a single structured outcome line on stdout:
#       ONE_ATTEMPT exit=<code> churn=<staged-lines-changed> verify=<pass|fail|unverifiable|skipped>
#   then exits 0. The optional --continuation <file> supplies the editing
#   prompt VERBATIM (instead of the default task template) so the caller-driven
#   loop migrating into code_writer.ag (#1354) can re-drive an incomplete
#   attempt.
#
#   --reuse (#1354 step 2a) makes an attempt build ON the diff already in the
#   workspace instead of resetting to the default branch, so successive
#   --one-attempt processes (separate loop ticks) accumulate on one branch.
#   --finalize (#1354 step 2a) does NO editing: it commits the workspace's
#   accumulated staged diff, pushes, and opens the PR — the terminal step of the
#   caller-driven loop (implies --reuse; exit 3/NO_EDITS if nothing is staged).
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
#   0  PR opened (URL printed on stdout); with --one-attempt: the ONE_ATTEMPT
#      outcome line was printed (its exit= field carries the session's code)
#   3  NO_EDITS — claude made no change to the tree (caller retries later; this
#      is NOT an error and must NOT open an empty PR)
#   5  OWNERSHIP_YIELD (#1516) — the branch carries commits this agent did not
#      create (foreign/operator commits, or a fail-closed ambiguity: ls-remote
#      error / missing own-sha record); the force-push was REFUSED and the
#      PR/branch left intact for the operator. code-edit-job.sh folds any
#      non-0/non-3 exit into STATUS=error, which code_writer.ag treats as a
#      non-destructive retry.
#   other  failure (clone/branch/edit/commit/push/PR-open)
#
# Knobs (env vars):
#   FLAT_CYBORG_IDLE_MS          flat-cyborg idle settle window (default 45000;
#                                #1345: editing sessions run xhigh extended
#                                thinking, whose pauses exceed the old 8000ms —
#                                a short window screen-scraped a partial reply)
#   CODE_EDIT_MODEL              claude --model for the editing session (default
#                                `opus` = Opus 4.8, the strongest model — code
#                                generation is the heaviest workload in the
#                                federation; agents' lighter prompt() reasoning
#                                runs on Sonnet 5 via flat-cyborg-claude.sh).
#                                Accepts an alias (`opus`/`sonnet`/`fable`) or a
#                                full model id.
#   CODE_EDIT_EFFORT             claude --settings effortLevel for the editing
#                                session (default `high` — code generation is
#                                the federation's heaviest workload and
#                                warrants stronger reasoning than the `medium`
#                                default used for lighter prompt() reasoning in
#                                flat-cyborg-claude.sh). Accepts
#                                low|medium|high|xhigh; an unrecognised value
#                                falls back to `high` with a warning.
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
# --description (#1349) is OPTIONAL: the reviewer-facing PR/MR body drafted by
# code_writer.ag's prompt() (its "2-3 sentences for the PR body" summary),
# threaded through code-edit-job.sh. Empty => fall back to the static template
# at create-mr time. The LLM reasoning lives in the .ag prompt(), NOT here.
DESCRIPTION_ARG=""
DECOMPOSE=0
# --decompose-only (#1422 M1): run ONLY the decomposition drive (the same drive
# --decompose runs first) and write the ordered NUL-delimited subtask list to
# the caller-named --subtasks-out file, then print `DECOMPOSED count=<n>` and
# exit 0 BEFORE the per-subtask edit loop. It runs NO edits, NO commit, NO PR.
# This surfaces the decomposition as a stand-alone primitive so code_writer.ag
# can drive the per-subtask sequence itself (the AG-driven decompose loop),
# exactly as --one-attempt surfaced the single edit drive. --decompose-only
# implies --decompose (the drive must actually run to yield >1 subtask). The
# default --decompose path (no --decompose-only) is byte-untouched.
DECOMPOSE_ONLY=0
SUBTASKS_OUT=""
RECOVER=0
# --rebase (#1518): the standalone pure-git conflict-recovery mode for our OWN
# CONFLICTING PRs. It runs NO editing engine and NO prompt(): it rebases the
# existing PR branch onto the current default branch, deterministically
# union-merges the one proven-safe conflict class (two-sided additive inserts
# under CHANGELOG.md `## [Unreleased]`), and fail-closes every other shape to a
# one-time human note. Its ONLY write is through guarded_push (#1516).
REBASE=0
# --one-attempt (#1406): the single-attempt primitive for the #1354
# caller-driven loop. --continuation names a file whose contents replace the
# default task prompt for that one drive.
ONE_ATTEMPT=0
CONTINUATION_FILE=""
# --reuse / --finalize (#1354 step 2a): the two primitives the caller-driven
# loop needs ON TOP of --one-attempt. --reuse keeps the diff accumulated so far
# on the existing per-issue branch INSTEAD of resetting to the default branch,
# so a SEPARATE --one-attempt process (the next loop tick) builds on the prior
# attempt's edits rather than starting from scratch. --finalize does NO editing
# at all: it commits the workspace's accumulated staged diff, pushes, and opens
# the PR — the terminal step of the loop. --finalize implies --reuse (it must
# not reset away the diff it is about to commit).
REUSE=0
FINALIZE=0

usage() {
    echo "usage: code-edit-in-checkout.sh --owner <o> --repo <r> --issue <iid> --branch <name> --title <t> --task <text> [--description <d>] [--decompose] [--decompose-only --subtasks-out <file>] [--recover] [--rebase] [--one-attempt] [--continuation <file>] [--reuse] [--finalize]" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --owner)  OWNER="${2:-}";  shift 2 ;;
        --repo)   REPO="${2:-}";   shift 2 ;;
        --issue)  ISSUE="${2:-}";  shift 2 ;;
        --branch) BRANCH="${2:-}"; shift 2 ;;
        --title)  TITLE="${2:-}";  shift 2 ;;
        --task)   TASK="${2:-}";   shift 2 ;;
        --description) DESCRIPTION_ARG="${2:-}"; shift 2 ;;
        --decompose) DECOMPOSE=1; shift ;;
        --decompose-only) DECOMPOSE_ONLY=1; DECOMPOSE=1; shift ;;
        --subtasks-out) SUBTASKS_OUT="${2:-}"; shift 2 ;;
        --recover) RECOVER=1; shift ;;
        --rebase) REBASE=1; shift ;;
        --one-attempt) ONE_ATTEMPT=1; shift ;;
        --continuation) CONTINUATION_FILE="${2:-}"; shift 2 ;;
        --reuse) REUSE=1; shift ;;
        --finalize) FINALIZE=1; REUSE=1; shift ;;
        *) echo "code-edit-in-checkout.sh: unknown flag: $1" >&2; usage; exit 2 ;;
    esac
done

# Legacy single-block fan-out (#316): the .ag passes empty --owner/--repo (the
# iter-repos sentinel) and the colony env carries the real values in
# GITHUB_OWNER/GITHUB_REPO. Resolve them here so the multi-repo and legacy paths
# share one orchestrator.
if [ -z "$OWNER" ]; then OWNER="${GITHUB_OWNER:-}"; fi
if [ -z "$REPO" ]; then REPO="${GITHUB_REPO:-}"; fi

# GitLab single-project fallback: no GITHUB_* env, but the colony exports a
# URL-encoded GITLAB_PROJECT (group%2Fproject, possibly nested group%2Fsub%2Frepo).
# Decode the %2F separators and split into owner/repo so CLONE_URL resolves.
# Mirrors the iter-repos.py / forge-api.sh GitLab handling. Without this, GitLab
# federations error at the required-args check below and the code-edit never runs.
if { [ -z "$OWNER" ] || [ -z "$REPO" ]; } && [ -n "${GITLAB_PROJECT:-}" ]; then
    _gl_proj="${GITLAB_PROJECT//%2F//}"
    _gl_proj="${_gl_proj//%2f//}"
    [ -z "$OWNER" ] && OWNER="${_gl_proj%/*}"
    [ -z "$REPO" ] && REPO="${_gl_proj##*/}"
fi

if [ -z "$OWNER" ] || [ -z "$REPO" ] || [ -z "$ISSUE" ] || [ -z "$BRANCH" ] || [ -z "$TITLE" ] || [ -z "$TASK" ]; then
    echo "code-edit-in-checkout.sh: --owner, --repo, --issue, --branch, --title, --task are all required" >&2
    usage
    exit 2
fi

# --continuation is only meaningful for the single-attempt primitive; a caller
# passing it on the default multi-attempt path is a bug — fail loudly (exit 2,
# same convention as an unknown flag) rather than silently ignoring the file.
if [ -n "$CONTINUATION_FILE" ]; then
    if [ "$ONE_ATTEMPT" -ne 1 ]; then
        echo "code-edit-in-checkout.sh: --continuation requires --one-attempt" >&2
        usage
        exit 2
    fi
    if [ ! -r "$CONTINUATION_FILE" ]; then
        echo "code-edit-in-checkout.sh: --continuation file not readable: $CONTINUATION_FILE" >&2
        exit 2
    fi
fi

# --finalize is the no-edit terminal step (commit the accumulated diff + PR);
# combining it with an editing primitive OR --recover is a caller bug — fail
# loudly. (--recover has its OWN terminal path: it pushes to the existing PR
# branch and prints RECOVERED, never opening a PR — so --finalize --recover
# would silently suppress the PR finalize is documented to open.)
if [ "$FINALIZE" -eq 1 ] && { [ "$ONE_ATTEMPT" -eq 1 ] || [ "$DECOMPOSE" -eq 1 ] || [ "$RECOVER" -eq 1 ]; }; then
    echo "code-edit-in-checkout.sh: --finalize cannot be combined with --one-attempt/--decompose/--recover" >&2
    usage
    exit 2
fi

# --reuse only makes sense ON TOP of --one-attempt (accumulate on the prior
# attempt) or --finalize (which implies it). Bare --reuse on the default path
# would silently run the WHOLE in-shell multi-attempt loop against the reused
# branch and open a PR — the exact state machine #1354 is migrating OUT — so a
# caller that drops --one-attempt on a continuation tick would get a surprising,
# destructive path (loop + commit + PR + workspace removal). Reject it.
if [ "$REUSE" -eq 1 ] && [ "$ONE_ATTEMPT" -ne 1 ] && [ "$FINALIZE" -ne 1 ]; then
    echo "code-edit-in-checkout.sh: --reuse requires --one-attempt or --finalize" >&2
    usage
    exit 2
fi

# --decompose-only (#1422 M1) is the stand-alone decomposition primitive: it
# runs ONLY the decompose drive and needs a caller-named --subtasks-out file to
# write the ordered subtask list to. It is mutually exclusive with the editing
# primitives (--one-attempt/--reuse/--finalize) and --recover — it makes no edit
# and opens no PR, so combining it with a path that does would be a caller bug.
if [ "$DECOMPOSE_ONLY" -eq 1 ]; then
    if [ -z "$SUBTASKS_OUT" ]; then
        echo "code-edit-in-checkout.sh: --decompose-only requires --subtasks-out <file>" >&2
        usage
        exit 2
    fi
    if [ "$ONE_ATTEMPT" -eq 1 ] || [ "$REUSE" -eq 1 ] || [ "$FINALIZE" -eq 1 ] || [ "$RECOVER" -eq 1 ]; then
        echo "code-edit-in-checkout.sh: --decompose-only cannot be combined with --one-attempt/--reuse/--finalize/--recover" >&2
        usage
        exit 2
    fi
fi

# --rebase (#1518) is the standalone pure-git conflict-recovery op: it makes no
# edit, drives no LLM, and reuses the branch's existing remote head. Combining it
# with ANY editing/decompose primitive or --recover is a caller bug — fail loudly
# (exit 2) rather than half-running two conflicting state machines on one branch.
if [ "$REBASE" -eq 1 ]; then
    if [ "$ONE_ATTEMPT" -eq 1 ] || [ "$REUSE" -eq 1 ] || [ "$FINALIZE" -eq 1 ] || [ "$DECOMPOSE" -eq 1 ] || [ "$DECOMPOSE_ONLY" -eq 1 ] || [ "$RECOVER" -eq 1 ]; then
        echo "code-edit-in-checkout.sh: --rebase cannot be combined with --one-attempt/--reuse/--finalize/--decompose/--decompose-only/--recover" >&2
        usage
        exit 2
    fi
fi

# Normalise the title into a clean Conventional Commits subject, reused for both
# the commit message and the PR/MR title. code_writer drafts a
# `type(scope): summary` title, but be defensive: collapse whitespace/newlines,
# strip a trailing period, ensure a conventional type prefix (default `fix:`),
# and cap the subject at 72 chars. This keeps titles short + conventional even if
# the upstream draft ever regresses to a multi-sentence prose blob.
normalize_title() {
    _t=$(printf '%s' "$1" | tr '\n\t' '  ' | sed -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//' -e 's/\.$//')
    case "$_t" in
        feat:*|fix:*|docs:*|test:*|refactor:*|chore:*|perf:*|build:*|ci:*|style:*|revert:*) : ;;
        feat\(*|fix\(*|docs\(*|test\(*|refactor\(*|chore\(*|perf\(*|build\(*|ci\(*|style\(*|revert\(*) : ;;
        *) _t="fix: $_t" ;;
    esac
    # Cap at 72 *characters*, not bytes, INDEPENDENT of the ambient locale.
    # `cut -c` is byte-wise under C/POSIX, and `LC_ALL=C.UTF-8` only helps when
    # that locale is actually installed (it often is NOT on CI runners), so a
    # multibyte char straddling byte 72 could be sliced into invalid UTF-8 that a
    # forge JSON API rejects (#1316). python3 slices by code point and re-encodes,
    # so the result is always valid UTF-8 capped at 72 characters (#1330 fix).
    printf '%s' "$_t" | python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().decode("utf-8", "ignore")[:72].encode("utf-8"))'
}
TITLE="$(normalize_title "$TITLE")"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Federation-wide LLM-session concurrency cap (#1352): the editing flat-cyborg
# sessions count against the same K-slot pool as the reasoning sessions
# (flat-cyborg-claude.sh), so the total concurrent PTY-session count is bounded.
# A slot is claimed before each editing session and freed by the post-session
# reap; a slot leaked by a SIGKILL'd detached job self-heals via the helper's
# PID-liveness reclaim. Sourcing is best-effort (absent lib → no-op).
# shellcheck source=lib/llm-session-slot.sh
# shellcheck disable=SC1091
[ -r "$SCRIPT_DIR/lib/llm-session-slot.sh" ] && . "$SCRIPT_DIR/lib/llm-session-slot.sh"
command -v acquire_llm_slot >/dev/null 2>&1 || { acquire_llm_slot() { :; }; release_llm_slot() { :; }; }

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

# ---------------------------------------------------------------------------
# #1516: own-sha record for the fail-closed force-push ownership gate.
# The record lives under the already-gitignored .agentis/ runtime tree (NOT in
# the checkout, NOT in the agentis memo store), keyed per issue exactly like
# $WS, so it SURVIVES the `rm -rf "$WS"` success-cleanup below and is available
# on the next attempt of the same issue. record_pushed_sha stamps the local
# head we just pushed; read_pushed_sha reads it back (whitespace-stripped).
# $OWNER/$REPO/$ISSUE/$BRANCH are validated non-empty at lines 199-203.
# ---------------------------------------------------------------------------
PUSHED_SHA_DIR="$FED_DIR/.agentis/code-edit-pushed/$COLONY_NAME/$OWNER-$REPO"
PUSHED_SHA_FILE="$PUSHED_SHA_DIR/issue-$ISSUE.sha"
YIELDED_FLAG="$PUSHED_SHA_DIR/issue-$ISSUE.yielded"
record_pushed_sha() {
    mkdir -p "$PUSHED_SHA_DIR" 2>/dev/null || true
    printf '%s\n' "$1" > "$PUSHED_SHA_FILE" 2>/dev/null || true
}
read_pushed_sha() {
    if [ -f "$PUSHED_SHA_FILE" ]; then
        tr -d ' \t\r\n' < "$PUSHED_SHA_FILE" || true
    fi
}

# post_yield_note: post an at-most-once generic issue note explaining the
# ownership refusal, guarded by the per-issue .yielded flag so the retry loop
# never spams the thread. FORGE_API is resolved (hoisted) before the push site,
# so it is set by call time. A failed note must NOT change the refusal outcome
# (we still exit 5), so every step is `|| true`.
post_yield_note() {
    if [ -f "$YIELDED_FLAG" ]; then
        echo "[code-edit] ownership gate: yield note already posted for #$ISSUE — not re-posting" >&2
        return 0
    fi
    _yn="code_writer declined to force-push branch \`$BRANCH\`: it carries commits not created by this agent — yielding to the operator; the automated push was skipped to preserve those commits."
    if [ -n "${FORGE_API:-}" ] && [ -x "${FORGE_API:-/nonexistent}" ]; then
        if [ "$FORGE_TYPE" = "gitlab" ]; then
            env GITLAB_URL="$API_BASE" GITLAB_PROJECT="$OWNER%2F$REPO" \
                "$FORGE_API" add-note "$ISSUE" --body "$_yn" >/dev/null 2>&1 || true
        else
            env GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" GITHUB_URL="$GITHUB_URL" \
                "$FORGE_API" add-note "$ISSUE" --body "$_yn" >/dev/null 2>&1 || true
        fi
    fi
    mkdir -p "$PUSHED_SHA_DIR" 2>/dev/null || true
    : > "$YIELDED_FLAG" 2>/dev/null || true
}

# guarded_push: the SINGLE force-push chokepoint (#1516). All three push paths
# (normal-loop finalize, --finalize, --recover) funnel through it. The prior
# `push --force-with-lease` guarded only against a CONCURRENT push racing ours
# (the lease matches a freshly-fetched ref) — it did NOTHING against foreign
# commits already at the remote head, which is exactly how the incident lost 4
# operator commits. Distinguishing "foreign commits I must not clobber" from "my
# own prior attempt I am legitimately replacing" (#1363 MR-less rescue) needs the
# explicit own-sha record above.
#
# Decision (fail CLOSED — a false refuse only leaves the PR for a human; a false
# allow destroys work):
#   * ls-remote error                            -> REFUSE (never read as "no branch")
#   * remote branch absent (exit 0, empty head)  -> first push, proceed + record
#   * remote head is an ANCESTOR of our local head -> fast-forward, proceed + record
#   * remote head == our own recorded sha          -> replacing our own attempt, proceed
#   * otherwise (foreign commits) / empty own-sha  -> REFUSE, post note once, exit 5
guarded_push() {
    _local="$(git_capture -C "$WS" rev-parse HEAD 2>/dev/null || true)"
    if [ -z "$_local" ]; then
        echo "[code-edit] ownership gate: cannot resolve local HEAD in $WS — refusing to push (fail-closed)" >&2
        exit 5
    fi
    set +e
    _lsr="$(git_capture -C "$WS" ls-remote origin "refs/heads/$BRANCH" 2>/dev/null)"
    _lsr_rc=$?
    set -e
    if [ "$_lsr_rc" -ne 0 ]; then
        echo "[code-edit] ownership gate: ls-remote for $BRANCH failed (exit $_lsr_rc) — refusing to force-push (fail-closed, a network/auth error is NOT 'no remote branch')" >&2
        exit 5
    fi
    _remote="$(printf '%s\n' "$_lsr" | awk 'NR==1{print $1}')"
    if [ -z "$_remote" ]; then
        # Branch genuinely absent on the remote: the first push for this branch.
        run_git -C "$WS" push --force-with-lease origin "$BRANCH"
        record_pushed_sha "$_local"
        return 0
    fi
    # Fast-forward: the remote head is already an ancestor of what we push, so no
    # remote commit is dropped. Safe regardless of who authored the remote head.
    if git_capture -C "$WS" merge-base --is-ancestor "$_remote" "$_local" >/dev/null 2>&1; then
        run_git -C "$WS" push --force-with-lease origin "$BRANCH"
        record_pushed_sha "$_local"
        return 0
    fi
    # Non-fast-forward: the push WOULD drop remote commits. Allow ONLY when the
    # remote head is exactly our own recorded last-pushed sha (we are replacing
    # our own prior attempt). Fail closed on an empty or mismatched record.
    _own="$(read_pushed_sha)"
    if [ -n "$_own" ] && [ "$_own" = "$_remote" ]; then
        run_git -C "$WS" push --force-with-lease origin "$BRANCH"
        record_pushed_sha "$_local"
        return 0
    fi
    echo "[code-edit] ownership gate: remote head $_remote of $BRANCH is neither an ancestor of our push nor our own recorded sha (${_own:-none}) — refusing to force-push, yielding to the operator" >&2
    post_yield_note
    exit 5
}

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

# Resolve the forge API wrapper here (#1516 hoisted it before the push so the
# ownership-gate yield note can reach it; #1518 needs it EARLIER still, before
# the --rebase handler below, whose own human-note path and guarded_push both
# post through it). Resolution has no dependency on the checkout state, so
# hoisting it up here is inert for every existing path (create-mr reuses it far
# below).
if [ "$FORGE_TYPE" = "gitlab" ]; then
    FORGE_API="$FED_DIR/$COLONY_NAME/scripts/gitlab-api.sh"
else
    FORGE_API="$FED_DIR/$COLONY_NAME/scripts/github-api.sh"
fi
if [ ! -x "$FORGE_API" ]; then
    echo "[code-edit] $FORGE_TYPE-api.sh not found/executable at $FORGE_API" >&2
    exit 1
fi

if [ "$REUSE" -eq 1 ]; then
    # Caller-driven continuation/finalize (#1354 step 2a): the diff accumulated
    # by prior --one-attempt drives lives on the existing per-issue branch in
    # THIS workspace. Keep it — do NOT reset to the default branch or re-cut the
    # branch, which would discard the loop's progress. Just re-enter the branch.
    # A missing local branch means no attempt ran yet: a caller error, not a
    # fresh-clone-and-edit request.
    if ! git_capture -C "$WS" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null 2>&1; then
        echo "[code-edit] --reuse/--finalize: no local branch $BRANCH in $WS to build on (run at least one --one-attempt first)" >&2
        exit 2
    fi
    run_git -C "$WS" checkout "$BRANCH"
    echo "[code-edit] reuse: continuing on existing branch $BRANCH, keeping the accumulated diff" >&2
else
    # Idempotent fresh state on the default branch.
    run_git -C "$WS" checkout "$DEFAULT_BRANCH"
    run_git -C "$WS" reset --hard "origin/$DEFAULT_BRANCH"
    run_git -C "$WS" clean -fd

    # -----------------------------------------------------------------------
    # 2. Branch.
    #   normal mode  : deterministic per-issue branch cut off the default branch
    #                  (reuse, no empty-branch litter).
    #   recover mode (#1332): check OUT the EXISTING remote head branch — it
    #                  already carries the prior (now-red-on-CI) commit, so we
    #                  build the fix ON TOP of it rather than off a clean default.
    #                  Reset hard to origin/<branch> so the local tree matches the
    #                  pushed state (idempotent across recovery re-drives).
    #   rebase mode (#1518): same as recover — check OUT the existing remote head
    #                  branch (idempotent across re-drives), because the whole op
    #                  is "replay THIS branch onto the moved default branch".
    # -----------------------------------------------------------------------
    if [ "$RECOVER" -eq 1 ] || [ "$REBASE" -eq 1 ]; then
        run_git -C "$WS" checkout -B "$BRANCH" "origin/$BRANCH"
        run_git -C "$WS" reset --hard "origin/$BRANCH"
    else
        run_git -C "$WS" checkout -B "$BRANCH" "origin/$DEFAULT_BRANCH"
    fi
fi

# ---------------------------------------------------------------------------
# --rebase (#1518): standalone pure-git conflict recovery for our OWN
# CONFLICTING PRs. Runs NO editing engine and NO prompt() — it exits here before
# any of the flat-cyborg machinery below. Fetch, rebase the branch onto the
# current default branch, and:
#   * clean rebase (no conflict, head moved)      -> guarded_push; REBASED; exit 0
#   * already current (nothing replayed)          -> NO_REBASE_NEEDED; exit 3
#   * conflict, lone CHANGELOG.md [Unreleased]     -> deterministic union-merge
#                                                     (changelog-union-resolve.py),
#                                                     rebase --continue, then
#                                                     guarded_push; exit 0
#   * ANY other conflict shape / guard miss / parse error / >1 conflicted file
#                                                 -> git rebase --abort + one-time
#                                                    human note; exit 6
# The ONLY write is guarded_push (#1516): a rebase rewrites history so the new
# head is NEVER an ancestor of the old remote, which forces guarded_push onto its
# own-sha branch — it force-pushes only when the remote head equals code_writer's
# recorded own sha (we own the branch) and REFUSES (exit 5 + at-most-once yield
# note) on a foreign/operator commit. So an auto-rebase over an operator-carrying
# branch degrades to the yield note and NEVER loops or clobbers.
# ---------------------------------------------------------------------------
if [ "$REBASE" -eq 1 ]; then
    REBASE_NOTED_FLAG="$PUSHED_SHA_DIR/issue-$ISSUE.rebase-noted"
    # post_rebase_note: at-most-once human note keyed to the CONFLICTING remote
    # head (mirrors post_yield_note + the #1516 at-most-once pattern). A guard
    # miss is not a retry-blindly error: one note, then wait for a human. The
    # flag stores the head sha, so a genuinely NEW conflicting head (main moved
    # again) is allowed exactly one fresh note.
    post_rebase_note() {
        _rn_head="$(git_capture -C "$WS" rev-parse "origin/$BRANCH" 2>/dev/null || true)"
        if [ -f "$REBASE_NOTED_FLAG" ] && [ "$(tr -d ' \t\r\n' < "$REBASE_NOTED_FLAG" 2>/dev/null)" = "$_rn_head" ]; then
            echo "[code-edit] rebase: human note already posted for #$ISSUE head ${_rn_head:-none} — not re-posting" >&2
            return 0
        fi
        _rn="code_writer could not auto-rebase branch \`$BRANCH\` onto \`$DEFAULT_BRANCH\`: the conflict is outside the auto-resolvable class (two-sided additive \`CHANGELOG.md\` \`[Unreleased]\` inserts) — the branch was left untouched (\`git rebase --abort\`) and needs a human rebase."
        if [ -n "${FORGE_API:-}" ] && [ -x "${FORGE_API:-/nonexistent}" ]; then
            if [ "$FORGE_TYPE" = "gitlab" ]; then
                env GITLAB_URL="$API_BASE" GITLAB_PROJECT="$OWNER%2F$REPO" \
                    "$FORGE_API" add-note "$ISSUE" --body "$_rn" >/dev/null 2>&1 || true
            else
                env GITHUB_OWNER="$OWNER" GITHUB_REPO="$REPO" GITHUB_URL="$GITHUB_URL" \
                    "$FORGE_API" add-note "$ISSUE" --body "$_rn" >/dev/null 2>&1 || true
            fi
        fi
        mkdir -p "$PUSHED_SHA_DIR" 2>/dev/null || true
        printf '%s\n' "$_rn_head" > "$REBASE_NOTED_FLAG" 2>/dev/null || true
    }
    # rebase_abort_note: byte-restore the branch (abort restores the pre-rebase
    # state), post one note, exit 6. code-edit-job.sh maps rc 6 -> error, which
    # the .ag treats as a bounded, NON-destructive retry (no push happened).
    rebase_abort_note() {
        git_capture -C "$WS" rebase --abort >/dev/null 2>&1 || true
        post_rebase_note
        echo "[code-edit] rebase: aborted, branch $BRANCH left for a human (#$ISSUE)" >&2
        exit 6
    }

    CHANGELOG_RESOLVER="$SCRIPT_DIR/changelog-union-resolve.py"

    run_git -C "$WS" fetch origin

    set +e
    git -C "$WS" rebase "origin/$DEFAULT_BRANCH" >/dev/null 2>&1
    _rb_rc=$?
    set -e

    if [ "$_rb_rc" -eq 0 ]; then
        # Clean rebase (no conflict). If nothing was replayed the head is still
        # origin/BRANCH and there is nothing to push — return NO_REBASE_NEEDED so
        # the .ag counts it distinctly from a real rebase push.
        _rb_new="$(git_capture -C "$WS" rev-parse HEAD 2>/dev/null || true)"
        _rb_old="$(git_capture -C "$WS" rev-parse "origin/$BRANCH" 2>/dev/null || true)"
        if [ -n "$_rb_new" ] && [ "$_rb_new" = "$_rb_old" ]; then
            echo "[code-edit] rebase: $BRANCH already current on $DEFAULT_BRANCH — nothing to push" >&2
            echo "NO_REBASE_NEEDED"
            exit 3
        fi
        guarded_push
        echo "[code-edit] rebase: clean rebase of $BRANCH onto $DEFAULT_BRANCH pushed" >&2
        echo "REBASED $BRANCH"
        exit 0
    fi

    # Conflict path. Bounded loop over the replayed commit stack (a rebase may
    # stop on a conflict at each replayed commit). ONLY the lone CHANGELOG.md
    # [Unreleased] two-sided-additive class is auto-resolved; every other shape
    # -> abort + one note. The step cap is a belt-and-braces guard against a
    # pathological non-terminating stack.
    _rb_step=0
    while [ -d "$WS/.git/rebase-merge" ] || [ -d "$WS/.git/rebase-apply" ]; do
        _rb_step=$(( _rb_step + 1 ))
        if [ "$_rb_step" -gt 100 ]; then
            echo "[code-edit] rebase: exceeded conflict-step cap (100) — aborting" >&2
            rebase_abort_note
        fi
        _rb_conf="$(git_capture -C "$WS" diff --name-only --diff-filter=U 2>/dev/null || true)"
        _rb_confn="$(printf '%s\n' "$_rb_conf" | grep -c . 2>/dev/null || true)"
        if [ "$_rb_confn" != "1" ]; then
            echo "[code-edit] rebase: $_rb_confn conflicted files (expected exactly 1 CHANGELOG.md) — not auto-resolvable" >&2
            rebase_abort_note
        fi
        case "$_rb_conf" in
            CHANGELOG.md|*/CHANGELOG.md) : ;;
            *)
                echo "[code-edit] rebase: conflicted file '$_rb_conf' is not CHANGELOG.md — not auto-resolvable" >&2
                rebase_abort_note
                ;;
        esac
        if [ ! -f "$CHANGELOG_RESOLVER" ]; then
            echo "[code-edit] rebase: changelog-union-resolve.py missing at $CHANGELOG_RESOLVER" >&2
            rebase_abort_note
        fi
        set +e
        python3 "$CHANGELOG_RESOLVER" "$WS/$_rb_conf"
        _rb_cl_rc=$?
        set -e
        if [ "$_rb_cl_rc" -ne 0 ]; then
            echo "[code-edit] rebase: CHANGELOG union resolver refused (exit $_rb_cl_rc) — not auto-resolvable" >&2
            rebase_abort_note
        fi
        run_git -C "$WS" add "$_rb_conf"
        set +e
        GIT_EDITOR=true git -C "$WS" rebase --continue >/dev/null 2>&1
        _rb_cont_rc=$?
        set -e
        # A non-zero --continue with NO pending rebase state is a hard failure
        # (not a further conflict the loop-top would re-handle) -> fail closed.
        if [ "$_rb_cont_rc" -ne 0 ] && [ ! -d "$WS/.git/rebase-merge" ] && [ ! -d "$WS/.git/rebase-apply" ]; then
            echo "[code-edit] rebase: 'git rebase --continue' failed (exit $_rb_cont_rc) with no pending conflict — aborting" >&2
            rebase_abort_note
        fi
    done

    # Rebase completed via one or more union-merges. Push through the gate.
    _rb_new="$(git_capture -C "$WS" rev-parse HEAD 2>/dev/null || true)"
    _rb_old="$(git_capture -C "$WS" rev-parse "origin/$BRANCH" 2>/dev/null || true)"
    if [ -n "$_rb_new" ] && [ "$_rb_new" = "$_rb_old" ]; then
        echo "[code-edit] rebase: no net change after resolve — nothing to push" >&2
        echo "NO_REBASE_NEEDED"
        exit 3
    fi
    guarded_push
    echo "[code-edit] rebase: resolved CHANGELOG [Unreleased] conflict, pushed $BRANCH onto $DEFAULT_BRANCH" >&2
    echo "REBASED $BRANCH"
    exit 0
fi

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
#
# #1346: only auto-select `npm test` when `node_modules/` is present. A fresh
# clone with a declared `test` script but no installed deps runs a test runner
# that isn't there → exit 127 (command-not-found), which the loop below would
# feed back as a "fix this" failure and make the editing agent undo its own
# correct edit chasing an unfixable env gap. Falling through to the light
# change-scoped gate avoids that; the PR's own CI installs deps and is the
# authoritative gate.
detect_verify_cmd() {
    if [ -n "${CODE_EDIT_VERIFY_CMD:-}" ]; then printf '%s' "$CODE_EDIT_VERIFY_CMD"; return 0; fi
    if [ -f "$WS/package.json" ] && grep -q '"test"' "$WS/package.json" 2>/dev/null && [ -d "$WS/node_modules" ]; then printf '%s' 'npm test --silent'; return 0; fi
    if [ -f "$WS/Makefile" ] && grep -qE '^test:' "$WS/Makefile" 2>/dev/null; then printf '%s' 'make test'; return 0; fi
    if [ -d "$WS/tests" ] && command -v pytest >/dev/null 2>&1; then printf '%s' 'pytest -q'; return 0; fi
    printf '%s' ''
}

# run_bounded <seconds> <cmd...> (#1342): run a command with a hard wall-clock cap
# that works on stock macOS, which ships NO `timeout` binary. The old verify paths
# used `timeout ...` only "when timeout exists" and ran the command UNBOUNDED
# otherwise — so on macOS a watch-mode test runner selected as the project gate
# (a bare `vitest`/`npm test` that never exits) hung the detached job forever with
# live-but-wedged children. Preference order: real `timeout` (GNU/coreutils), then
# `gtimeout` (Homebrew coreutils on macOS); if neither is on PATH, fall back to a
# POSIX background-process + `sleep N; kill` watchdog. The fallback runs the command
# in its own process group (bash job control) so the SIGKILL reaps the whole subtree
# — a watch-mode runner forks children a bare `kill $pid` would orphan. Whichever of
# the command / the watchdog finishes first wins; the loser is torn down. A watchdog
# kill is normalised to exit 124 to match `timeout`'s convention. Runs in the
# CALLER's cwd/env (callers still `cd "$WS"` and scrub tokens with `env -u`).
run_bounded() {
    _rb_s="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${_rb_s}s" "$@"; return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${_rb_s}s" "$@"; return $?
    fi
    set -m 2>/dev/null || true
    "$@" &
    _rb_pid=$!
    ( sleep "$_rb_s"; kill -KILL -"$_rb_pid" 2>/dev/null || kill -KILL "$_rb_pid" 2>/dev/null ) &
    _rb_watch=$!
    wait "$_rb_pid" 2>/dev/null; _rb_rc=$?
    kill -KILL -"$_rb_watch" 2>/dev/null || kill -KILL "$_rb_watch" 2>/dev/null || true
    wait "$_rb_watch" 2>/dev/null || true
    if [ "$_rb_rc" -gt 128 ]; then _rb_rc=124; fi
    return "$_rb_rc"
}

# run_verify <cmd>: run the gate inside $WS, time-bounded and token-scrubbed (the
# gate never needs forge creds), combined output captured to $VERIFY_OUT. Returns
# the gate's exit code.
run_verify() {
    _vt_s=$(( VERIFY_TIMEOUT_MS / 1000 ))
    [ "$_vt_s" -lt 1 ] && _vt_s=1
    ( cd "$WS" && run_bounded "$_vt_s" env -u GITHUB_TOKEN -u GITLAB_TOKEN sh -c "$1" ) >"$VERIFY_OUT" 2>&1
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
                        if ! ( cd "$WS" && run_bounded "$_lv_tt" env -u GITHUB_TOKEN -u GITLAB_TOKEN sh "$_lv_f" ) >>"$VERIFY_OUT" 2>&1; then _lv_rc=1; fi
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
# Effort-level routing (#1444): the editing session defaults to "high" instead
# of inheriting the operator's account-level effortLevel — code generation is
# the federation's heaviest workload and warrants the strongest reasoning.
# Harden against a typo reaching `claude --settings` unvalidated: only a
# known-good value is ever interpolated into the JSON string. Computed ONCE
# here so all three `claude --model ... --settings` invocation sites below
# (decompose, one-attempt, multi-attempt loop) reference the same value.
CODE_EDIT_EFFORT="${CODE_EDIT_EFFORT:-high}"
case "$CODE_EDIT_EFFORT" in
    low|medium|high|xhigh) ;;
    *)
        echo "code-edit-in-checkout.sh: invalid CODE_EDIT_EFFORT '$CODE_EDIT_EFFORT', falling back to high" >&2
        CODE_EDIT_EFFORT=high
        ;;
esac
EFFORT_SETTINGS='{"effortLevel":"'"$CODE_EDIT_EFFORT"'"}'
# Verify gate (#1253): run the repo's gate after a settled attempt and only stop
# when it passes; feed failures back as another iteration (bounded by the same
# attempts/budget). Empty VERIFY_CMD -> no gate -> M1 behaviour.
VERIFY_CMD="$(detect_verify_cmd)"
# Recover mode (#1332): the verify gate MUST run — it is the local reproduction
# of the red CI we are recovering from. Neutralise the two ways the gate can be
# skipped: an explicit `CODE_EDIT_VERIFY_CMD=true` force-skip collapses to the
# built-in light change-scoped gate (empty VERIFY_CMD), and the loop below never
# treats a settled-but-unverified attempt as done. detect_verify_cmd's
# auto-detect (npm/make/pytest) is still honoured when present.
if [ "$RECOVER" -eq 1 ]; then
    case "$VERIFY_CMD" in
        true|:) VERIFY_CMD="" ;;
    esac
    echo "[code-edit] recover mode: verify gate forced ON" >&2
fi
VERIFY_TIMEOUT_MS="${CODE_EDIT_VERIFY_TIMEOUT_MS:-300000}"
case "$VERIFY_TIMEOUT_MS" in ''|*[!0-9]*) VERIFY_TIMEOUT_MS=300000 ;; esac
VERIFY_OUT="$(mktemp)"
[ -n "$VERIFY_CMD" ] && echo "[code-edit] verification gate: $VERIFY_CMD" >&2

# ---------------------------------------------------------------------------
# macOS Keychain sidestep (#1343): the editing claude session flat-cyborg spawns
# below is a child of THIS detached job, which crossed the agentis `exec`
# boundary — that sanitizes the env (USER/LOGNAME unset) and drops the GUI
# security session, so macOS claude cannot reach the login Keychain and comes up
# "Not logged in", making ZERO edits (setsid / setpgrp / launchctl asuser detach
# variants all failed to restore Keychain access). Support an opt-in file
# credential path: read a long-lived token from a gitignored file and export it
# as CLAUDE_CODE_OAUTH_TOKEN so the spawned session authenticates without the
# Keychain. The token MUST be one produced by `claude setup-token` (long-lived,
# headless) — a raw OAuth `accessToken` copied out of ~/.claude/.credentials.json
# is the WRONG type for this env var and 401s ("Invalid authentication
# credentials"). Default path lives under the already-gitignored .agentis/ tree.
# No-op when the file is absent (Linux hosts keep the inherited Keychain/creds
# path unchanged), and we never clobber a CLAUDE_CODE_OAUTH_TOKEN the caller
# already set.
CLAUDE_OAUTH_TOKEN_FILE="${CLAUDE_OAUTH_TOKEN_FILE:-$FED_DIR/.agentis/secrets/claude-oauth-token}"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -s "$CLAUDE_OAUTH_TOKEN_FILE" ]; then
    CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '\r\n' < "$CLAUDE_OAUTH_TOKEN_FILE")"
    export CLAUDE_CODE_OAUTH_TOKEN
    echo "[code-edit] exported CLAUDE_CODE_OAUTH_TOKEN from $CLAUDE_OAUTH_TOKEN_FILE (macOS Keychain sidestep)" >&2
fi

# ---------------------------------------------------------------------------
# --one-attempt (#1406, #1354 step 1): the single-attempt primitive for the
# caller-driven loop that is migrating the attempt/budget/progress/verify state
# machine up into code_writer.ag. Runs exactly ONE flat-cyborg editing drive
# (the same invocation the multi-attempt loop below uses), reaps strays,
# measures the staged churn, runs the verify gate once, and reports
#     ONE_ATTEMPT exit=<code> churn=<staged-lines-changed> verify=<outcome>
# as the SINGLE final stdout line, then exits 0 — the outcome line is the
# contract; the CALLER decides whether to re-drive (via --continuation),
# commit, or give up. No retry loop, no commit, no push, no PR here. The
# per-issue workspace is kept (its staged diff is the attempt's artifact).
# verify outcomes:
#     pass          gate exit 0
#     fail          gate failed (non-zero, non-127)
#     unverifiable  gate exit 127 — the gate command itself is missing or
#                   unrunnable here, NOT a code failure (#1346 / #1391)
#     skipped       zero churn, no detected gate, or a force-skip
#                   (CODE_EDIT_VERIFY_CMD=true) — nothing was verified
# ---------------------------------------------------------------------------
if [ "$ONE_ATTEMPT" -eq 1 ]; then
    if [ -n "$CONTINUATION_FILE" ]; then
        cat "$CONTINUATION_FILE" > "$TASKFILE"
        echo "[code-edit] one-attempt: driving with the caller's continuation prompt ($CONTINUATION_FILE)" >&2
    else
        printf 'Implement issue #%s in this repository by editing the files directly with your tools. %s\n\nBegin editing immediately and keep exploration minimal — the task below already specifies the change; read only the specific files you must modify.\n\n%s\n\nMake the change and stop; do not run git or open a PR.' \
            "$ISSUE" "$TITLE" "$TASK" > "$TASKFILE"
    fi
    echo "[code-edit] running flat-cyborg editing agent in $WS (one-attempt)" >&2
    set +e
    acquire_llm_slot
    flat-cyborg --extract --extract-structural --no-jitter --auto-approve --wrap-input 72 --cwd "$WS" \
        --idle-ms "${FLAT_CYBORG_IDLE_MS:-45000}" \
        --timeout-ms "$PER_ATTEMPT_MS" \
        --cmd-file "$TASKFILE" -- claude --model "${CODE_EDIT_MODEL:-opus}" --settings "$EFFORT_SETTINGS" >&2
    FC_RC=$?
    set -e
    reap_editing_strays
    release_llm_slot
    cur_lines="$(staged_line_count)"
    verify_outcome="skipped"
    if [ "$cur_lines" -gt 0 ] && [ -n "$VERIFY_CMD" ]; then
        case "$VERIFY_CMD" in
            true|:)
                echo "[code-edit] one-attempt: verify gate force-skipped (CODE_EDIT_VERIFY_CMD=$VERIFY_CMD)" >&2
                ;;
            *)
                echo "[code-edit] verifying ($VERIFY_CMD) ..." >&2
                set +e; run_verify "$VERIFY_CMD"; verify_rc=$?; set -e
                if [ "$verify_rc" -eq 0 ]; then
                    verify_outcome="pass"
                elif [ "$verify_rc" -eq 127 ]; then
                    verify_outcome="unverifiable"
                else
                    verify_outcome="fail"
                fi
                ;;
        esac
    fi
    echo "[code-edit] one-attempt outcome: exit=$FC_RC churn=$cur_lines verify=$verify_outcome" >&2
    echo "ONE_ATTEMPT exit=$FC_RC churn=$cur_lines verify=$verify_outcome"
    exit 0
fi

# The editing engine (decompose + the multi-attempt continue-on-incomplete
# loop) is skipped ENTIRELY under --finalize (#1354 step 2a), which only commits
# a diff that prior --one-attempt drives already accumulated in this workspace.
if [ "$FINALIZE" -ne 1 ]; then
# Decompose (#1254): for a large/epic task, split it into an ORDERED list of
# small sub-edits and run the edit loop once per subtask on the SAME branch,
# accumulating into ONE commit/PR. Without --decompose (or if decomposition
# yields nothing) the whole task is the single "subtask" -> identical to M1/M2.
#
# #1422 M1: the decomposition drive + parse + monolithic fallback + count are
# factored into fill_subtasks_file() so --decompose-only can reuse them VERBATIM
# without entering the per-subtask edit loop. The default --decompose path calls
# it and falls straight through to the loop below, so its behaviour stays
# byte-identical. The function sets the globals SUBTASKS_FILE / SUBTASK_COUNT
# (and SUBTASKS_LIST, cleaned up by the EXIT trap). The monolithic fallback
# guarantees SUBTASK_COUNT >= 1.
fill_subtasks_file() {
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
        acquire_llm_slot
        flat-cyborg --extract --extract-structural --no-jitter --auto-approve --wrap-input 72 --cwd "$WS" \
            --idle-ms "${FLAT_CYBORG_IDLE_MS:-45000}" --timeout-ms "$PER_ATTEMPT_MS" \
            --cmd-file "$TASKFILE" -- claude --model "${CODE_EDIT_MODEL:-opus}" --settings "$EFFORT_SETTINGS" >&2
        set -e
        reap_editing_strays
        release_llm_slot
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
    # Explicit success: the trailing `[ -gt ] &&` above returns non-zero when
    # SUBTASK_COUNT==1, which — as this function's last command called under
    # `set -e` — would abort the script before the loop / --decompose-only exit.
    return 0
}
fill_subtasks_file

# #1422 M1: --decompose-only surfaces the ordered subtask list as a stand-alone
# primitive and STOPS here — it runs NO per-subtask edit, NO commit, NO PR. Copy
# the NUL-delimited records to the caller-named --subtasks-out file (which lives
# OUTSIDE the per-issue job dir, so a caller's clear_job_dir cannot reap it) and
# print the poll token the launcher re-keys onto the poll line. The monolithic
# fallback guarantees count>=1, so the caller always gets at least one record.
if [ "$DECOMPOSE_ONLY" -eq 1 ]; then
    mkdir -p "$(dirname "$SUBTASKS_OUT")"
    cp "$SUBTASKS_FILE" "$SUBTASKS_OUT"
    echo "[code-edit] decompose-only: wrote $SUBTASK_COUNT subtask(s) for issue #$ISSUE to $SUBTASKS_OUT" >&2
    echo "DECOMPOSED count=$SUBTASK_COUNT"
    exit 0
fi

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
    acquire_llm_slot
    flat-cyborg --extract --extract-structural --no-jitter --auto-approve --wrap-input 72 --cwd "$WS" \
        --idle-ms "${FLAT_CYBORG_IDLE_MS:-45000}" \
        --timeout-ms "$this_timeout" \
        --cmd-file "$TASKFILE" -- claude --model "${CODE_EDIT_MODEL:-opus}" --settings "$EFFORT_SETTINGS" >&2
    FC_RC=$?
    set -e

    # Reap orphaned editing-session descendants before measuring/looping (#1249).
    reap_editing_strays
    release_llm_slot
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
        if [ "$verify_rc" -eq 127 ]; then
            # #1346: exit 127 = the gate command itself is missing/unrunnable
            # here (e.g. `npm test` with no installed test runner), NOT a code
            # failure. Feeding it back would make the editing agent undo its
            # correct edit chasing an unfixable env gap. Treat as UNVERIFIABLE:
            # keep the edit and stop; the PR's own CI is the authoritative gate.
            echo "[code-edit] verification UNVERIFIABLE (gate exit 127, command missing/unrunnable) — keeping the edit; the PR's own CI is the authoritative gate" >&2
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
fi  # end editing engine (skipped under --finalize, #1354 step 2a)

if [ "$FINALIZE" -eq 1 ]; then
    # No editing ran; the artifact is the diff prior --one-attempt drives left in
    # the workspace. Stage it and refuse to open an empty PR (exit 3 = the same
    # NO_EDITS "nothing to do, not an error" contract the loop path uses).
    FC_RC=0
    run_git -C "$WS" add -A
    if run_git -C "$WS" diff --cached --quiet; then
        echo "NO_EDITS"
        echo "[code-edit] --finalize: no staged changes in $WS to commit — nothing to finalize" >&2
        exit 3
    fi
    echo "[code-edit] --finalize: committing the accumulated diff and opening the PR for #$ISSUE" >&2
fi

if [ "$FC_RC" -ne 0 ]; then
    echo "[code-edit] last attempt exited non-zero (exit $FC_RC, likely idle/timeout) but edits were produced — committing the diff" >&2
fi

run_git -C "$WS" commit -m "$TITLE (#$ISSUE)"
guarded_push

# Recover mode (#1332): the PR already exists, so we ONLY push the fix — we do
# NOT open a second PR. A new commit landed (the diff check above proved it), so
# this is a successful recovery push. The same `--force-with-lease` push as the
# normal path (no destructive force-push). Keep the per-issue workspace so a
# subsequent recovery re-drive of the same red PR reuses it (fetch+reset).
if [ "$RECOVER" -eq 1 ]; then
    echo "[code-edit] recover: pushed fix to existing branch $BRANCH (PR already open — not creating a new PR)" >&2
    echo "RECOVERED $BRANCH"
    exit 0
fi

# ---------------------------------------------------------------------------
# 5. Open the PR/MR via the colony's forge API wrapper create-mr verb. The
#    wrapper reads its token from the env (already present here) and prints the
#    forge's PR/MR JSON; we extract the URL and print it on stdout. The verb +
#    flags (--source/--title/--description) are forge-symmetric; only the env
#    contract differs (github: OWNER/REPO/URL; gitlab: PROJECT/URL).
# ---------------------------------------------------------------------------
# Build the PR/MR body. A static "Closes #N" line tells a reviewer nothing about
# the change (#1347), so we thread the reviewer-facing summary the AGENT already
# drafted (#1349): code_writer.ag's prompt() returns a "2-3 sentences for the PR
# body" summary, passed here verbatim as --description. The LLM reasoning belongs
# in the agent's prompt(), NOT in shell plumbing — so this orchestrator does NOT
# summarise the diff itself. When --description is empty (no upstream summary) we
# fall back to the static template. Either way we append `Closes #N` ourselves so
# the issue auto-closes on merge regardless of which path produced the body.
STATIC_DESCRIPTION="Closes #$ISSUE.

Autonomously implemented by the dev-apprenticeship federation."

if printf '%s' "$DESCRIPTION_ARG" | grep -q '[^[:space:]]'; then
    DESCRIPTION="$DESCRIPTION_ARG

Closes #$ISSUE"
else
    DESCRIPTION="$STATIC_DESCRIPTION"
fi

# FORGE_API is resolved above (hoisted before the push for the #1516 yield note).

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
