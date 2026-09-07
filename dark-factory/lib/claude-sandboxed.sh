#!/usr/bin/env bash
# dark-factory/lib/claude-sandboxed.sh — sandboxed `claude` for the flat-cyborg-
# driven hunt cells. Generalized from the proven ~/df-work prototype.
#
# WHY: a hunt cell drives a full Claude Code session (Bash/Read/Edit/Write +
# Foundry) against an untrusted target clone. Without isolation that session can
# read anything the daemon user can — sibling hunts, held-out ground truth, the
# operator's AB-NOTE / corpus truth.tsv, other ~/.claude sessions — and could
# exfiltrate via the web tools. This wrapper gives the driven `claude` a
# bubblewrap view containing ONLY the toolchain, the target repo, the cell run
# dir, and the claude auth/config it needs, and denies WebFetch/WebSearch.
#
# The five hunt emitters (run-discovery / run-refute / run-invariant-hunt /
# map-zones / gen-briefs) point agentis-core's `llm.flat_cyborg.target` at this
# script and export the two bind vars below into the agentis invocation env;
# `run_flat_cyborg` does not env_clear, so they propagate daemon -> flat-cyborg
# -> here.
#
# FAIL-CLOSED: HUNT_SANDBOX_RUN is mandatory (`:?` aborts loudly) so a missing
# bind var can never silently run an UNSANDBOXED session that believes it is
# sandboxed. When bwrap is absent OR DF_NO_SANDBOX=1, we fall through to the real
# claude with a loud stderr warning (so CI / dev hosts without bwrap still work).
set -u

# Resolve the real claude WITHOUT recursing into this wrapper. DF_CLAUDE_BIN lets
# the demo point at a stub; otherwise take the first `claude` on PATH that is not
# this script.
# canon: POSIX-portable path canonicalization (no GNU `readlink -f` — colony-lint's
# portability ratchet forbids it). Resolves symlinked directories via `pwd -P`; the
# final component is left as-is, which is enough to tell a candidate apart from this
# wrapper (the config-target seam means `claude` is never PATH-shadowed by us).
canon() { d="$(dirname "$1")"; b="$(basename "$1")"; ( cd "$d" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$b" ); }
REAL="${DF_CLAUDE_BIN:-}"
if [ -z "$REAL" ]; then
  self="$(canon "$0")"
  for cand in $(command -v -a claude 2>/dev/null); do
    if [ "$(canon "$cand")" != "$self" ]; then REAL="$cand"; break; fi
  done
fi
[ -n "$REAL" ] || { echo "claude-sandboxed.sh: no real 'claude' binary found on PATH" >&2; exit 127; }

# Fail-closed on the run-dir bind; repo bind is optional (gen-briefs may run
# without --repo).
RUN="${HUNT_SANDBOX_RUN:?claude-sandboxed.sh: HUNT_SANDBOX_RUN must be set (fail-closed sandbox)}"
REPO="${HUNT_SANDBOX_REPO:-}"
H="$HOME"

# Fallthrough: no bwrap, or explicit opt-out -> real claude, web tools still
# denied, but NO filesystem isolation. Warn loudly so it is never mistaken for a
# sandboxed run.
if [ -n "${DF_NO_SANDBOX:-}" ] || ! command -v bwrap >/dev/null 2>&1; then
  if [ -n "${DF_NO_SANDBOX:-}" ]; then
    echo "claude-sandboxed.sh: WARNING DF_NO_SANDBOX=1 -> running claude UNSANDBOXED (web tools still denied)" >&2
  else
    echo "claude-sandboxed.sh: WARNING bwrap not found -> running claude UNSANDBOXED (web tools still denied)" >&2
  fi
  exec "$REAL" --disallowedTools WebFetch WebSearch "$@"
fi

# Build the bind set. Optional paths are bound only when they exist so the
# wrapper works on a host without foundry / svm / a repo.
binds=(
  --die-with-parent --unshare-pid
  --ro-bind /usr /usr --ro-bind /etc /etc
  --symlink usr/lib /lib --symlink usr/lib64 /lib64 --symlink usr/bin /bin --symlink usr/sbin /sbin
  --dev /dev --proc /proc --ro-bind /run /run
  --tmpfs /tmp --tmpfs "$H"
  --ro-bind "$REAL" "$REAL"
)
[ -e "$H/.claude" ]      && binds+=(--bind "$H/.claude" "$H/.claude")            # session/trust persistence (rw)
[ -e "$H/.claude.json" ] && binds+=(--bind "$H/.claude.json" "$H/.claude.json") # workspace-trust store (rw)
[ -e "$H/.foundry" ]     && binds+=(--ro-bind "$H/.foundry" "$H/.foundry")      # forge/cast/anvil toolchain
[ -e "$H/.svm" ]         && binds+=(--ro-bind "$H/.svm" "$H/.svm")              # solc version manager cache
[ -n "$REPO" ] && [ -e "$REPO" ] && binds+=(--bind "$REPO" "$REPO")            # target clone (rw: PoC/forge out)
binds+=(--bind "$RUN" "$RUN")                                                    # cell run/out dir (rw)
binds+=(
  --setenv PATH "$H/.foundry/bin:$(dirname "$REAL"):/usr/local/bin:/usr/bin:/bin"
  --setenv HOME "$H"
  --chdir "$PWD"
)

exec bwrap "${binds[@]}" "$REAL" --disallowedTools WebFetch WebSearch "$@"
