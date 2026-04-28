#!/bin/bash
# Forge dispatcher for the release colony (ADR-0002, #256).
#
# Agents call this script via exec sh instead of the backend-specific
# wrappers (gitlab-api.sh, github-api.sh). The dispatcher reads the
# FORGE_TYPE env var (exported by start-colony.sh from the [forge].type
# config key) and forwards argv verbatim to the matching backend wrapper.
#
# Agents receive identical normalized JSON regardless of backend. See
# doc/adr/ADR-0002-forge-abstraction.md for the shape contract.
#
# Exit codes:
#   0   success (from the underlying wrapper)
#   1   backend wrapper failure (from the underlying wrapper)
#   2   unknown flag / usage error
#   99  requested FORGE_TYPE has no backend wrapper yet (see #256 PRs 2-6)

set -e

FORGE_TYPE="${FORGE_TYPE:-gitlab}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# #316 M3a: --repo <owner/repo> dispatch.
#
# Pre-scan argv for --repo (consumes 2 args). The flag is stripped before
# argv reaches the backend wrapper so each per-colony github-api.sh stays
# byte-identical at the verb-parser level. When --repo is present AND
# FORGE_TYPE=github AND GITHUB_REPOS_JSON is non-empty (multi-repo
# config from M2), delegate (owner, repo) -> {token, url, me} resolution
# to tools/forge-resolve-repo.py and re-export the five GITHUB_* env vars
# for the duration of this wrapper invocation. Tokens travel through the
# environment, never argv (the python helper emits shell-quoted exports
# on stdout, the dispatcher consumes via `eval`).
#
# Single-block configs (no GITHUB_REPOS_JSON in env) ignore --repo
# silently — the agent's repo_arg() helper returns "" when the iterator
# emits a single legacy-env line, so this branch is unreachable on the
# back-compat path. gitlab backend silently strips --repo too: GitLab
# multi-repo runtime is post-M6 (per ADR-0002 multi-repo subsection).
REPO_OVERRIDE=""
NEW_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            if [ -z "${2:-}" ]; then
                echo "forge-api.sh: --repo requires owner/repo arg" >&2
                exit 2
            fi
            REPO_OVERRIDE="$2"
            shift 2
            ;;
        *)
            NEW_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- ${NEW_ARGS[@]+"${NEW_ARGS[@]}"}

if [ -n "$REPO_OVERRIDE" ] && [ "$FORGE_TYPE" = "github" ] && [ -n "${GITHUB_REPOS_JSON:-}" ]; then
    REPO_OWNER="${REPO_OVERRIDE%%/*}"
    REPO_NAME="${REPO_OVERRIDE#*/}"
    if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ] || [ "$REPO_OWNER" = "$REPO_OVERRIDE" ]; then
        echo "forge-api.sh: --repo expected owner/repo (got '$REPO_OVERRIDE')" >&2
        exit 2
    fi
    REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
    LOOKUP="$REPO_ROOT/tools/forge-resolve-repo.py"
    if [ ! -f "$LOOKUP" ]; then
        echo "forge-api.sh: --repo dispatch helper missing: $LOOKUP" >&2
        exit 2
    fi
    RESOLVED="$(python3 "$LOOKUP" "$REPO_OWNER" "$REPO_NAME")" || {
        echo "forge-api.sh: --repo $REPO_OVERRIDE not in GITHUB_REPOS_JSON" >&2
        exit 2
    }
    eval "$RESOLVED"
    export GITHUB_OWNER GITHUB_REPO GITHUB_TOKEN GITHUB_URL GITHUB_ME
fi

case "$FORGE_TYPE" in
    gitlab)
        backend="$SCRIPT_DIR/gitlab-api.sh"
        ;;
    github)
        backend="$SCRIPT_DIR/github-api.sh"
        ;;
    *)
        echo "forge-api.sh: unknown FORGE_TYPE '$FORGE_TYPE' (expected: gitlab|github)" >&2
        exit 2
        ;;
esac

if [ ! -x "$backend" ]; then
    echo "forge-api.sh: backend wrapper missing or not executable: $backend" >&2
    echo "forge-api.sh: this indicates a broken install — re-copy the release colony scripts/ directory." >&2
    exit 99
fi

exec "$backend" "$@"
