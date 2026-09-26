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
# The six hunt emitters (run-discovery / run-refute / run-invariant-hunt /
# map-zones / gen-briefs / run-poc) point agentis-core's `llm.flat_cyborg.target`
# at this script and export the two bind vars below into the agentis invocation
# env; `run_flat_cyborg` does not env_clear, so they propagate daemon ->
# flat-cyborg -> here.
#
# FAIL-CLOSED: HUNT_SANDBOX_RUN is mandatory (`:?` aborts loudly) so a missing
# bind var can never silently run an UNSANDBOXED session that believes it is
# sandboxed. When bwrap is absent OR DF_NO_SANDBOX=1, we fall through to the real
# claude with a loud stderr warning (so CI / dev hosts without bwrap still work).
set -u

# Resolve the real claude WITHOUT recursing into this wrapper. DF_CLAUDE_BIN is
# a test seam for demo-claude-sandboxed.sh; production cells never set it and
# always go through the PATH resolver below.
# canon: POSIX-portable path canonicalization (no GNU `readlink -f` — colony-lint's
# portability ratchet forbids it). Resolves symlinked directories via `pwd -P`; the
# final component is left as-is, which is enough to tell a candidate apart from this
# wrapper (the config-target seam means `claude` is never PATH-shadowed by us).
canon() { d="$(dirname "$1")"; b="$(basename "$1")"; ( cd "$d" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$b" ); }
REAL="${DF_CLAUDE_BIN:-}"
if [ -z "$REAL" ]; then
  self="$(canon "$0")"
  while IFS= read -r cand; do
    if [ "$(canon "$cand")" != "$self" ]; then REAL="$cand"; break; fi
  done < <(type -aP claude 2>/dev/null)
fi
[ -n "$REAL" ] || { echo "claude-sandboxed.sh: no real 'claude' binary found on PATH" >&2; exit 127; }

# Fail-closed on the run-dir bind; repo bind is optional (gen-briefs may run
# without --repo).
RUN="${HUNT_SANDBOX_RUN:?claude-sandboxed.sh: HUNT_SANDBOX_RUN must be set (fail-closed sandbox)}"
REPO="${HUNT_SANDBOX_REPO:-}"
# #2235: the external-protocol source cache, bound rw (the resolver writes it) ONLY when the emitter exported
# the var — i.e. only under run-discovery.sh --external-resolve. Unset (the default) => the bind set below is
# byte-identical to the pre-#2235 one. It holds external-protocol source only, never target code and never
# judging / ground-truth data, and the cell reads citations back out of it instead of re-fetching them.
EXTERNAL="${HUNT_SANDBOX_EXTERNAL:-}"
H="$HOME"

# claude_project_slug <abs-cwd>: the directory name Claude Code keeps a cwd's transcripts under, in
# ~/.claude/projects/. Mirrors Claude Code's own path sanitizer exactly: every char outside [A-Za-z0-9] becomes
# '-'; a name longer than 200 chars is cut to 200 and suffixed with '-' + base36(|h|), where h is the 32-bit
# signed djb2 `h = ((h << 5) - h + code) | 0` over the path. Verified against real hashed project dirs.
# ASCII paths only (every emitter's cwd is a generated run dir): a non-ASCII path returns 1 and the caller binds
# nothing, so the transcript lands in the sandbox tmpfs (fail-closed: lost, never leaked).
claude_project_slug() {
  local LC_ALL=C
  local p="$1" s i c h=0 out="" digits=0123456789abcdefghijklmnopqrstuvwxyz
  [[ $p == *[![:ascii:]]* ]] && return 1
  s="${p//[^A-Za-z0-9]/-}"
  if [ "${#s}" -le 200 ]; then printf '%s\n' "$s"; return 0; fi
  for (( i = 0; i < ${#p}; i++ )); do
    printf -v c '%d' "'${p:i:1}"
    h=$(( (h * 31 + c) & 0xFFFFFFFF ))
  done
  [ "$h" -ge 2147483648 ] && h=$(( 4294967296 - h ))
  [ "$h" -eq 0 ] && out=0
  while [ "$h" -gt 0 ]; do out="${digits:h % 36:1}$out"; h=$(( h / 36 )); done
  printf '%s-%s\n' "${s:0:200}" "$out"
}

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
# #2262: ~/.claude also holds EVERY Claude Code session on the host — other cells' and other runs' transcripts
# and the operator's own sessions (which can quote ground truth). A real held-out hunter cell grepped
# ~/.claude/projects/* and read another zone's refuter transcripts. So, AFTER the ~/.claude bind (bwrap applies
# mounts in order), every history-bearing entry is masked: the per-session dirs become empty tmpfs, and the
# prompt history reads as empty with appends discarded (/dev/null needs --dev-bind: plain binds are nodev).
# Credentials, settings, agents, skills and plugins stay visible exactly as before.
if [ -d "$H/.claude" ]; then
  mkdir -p "$H/.claude/projects" 2>/dev/null
  for _d in projects file-history shell-snapshots session-env sessions todos debug paste-cache plans backups; do
    [ -d "$H/.claude/$_d" ] && binds+=(--tmpfs "$H/.claude/$_d")
  done
  [ -f "$H/.claude/history.jsonl" ] && binds+=(--dev-bind /dev/null "$H/.claude/history.jsonl")
  # ...then re-expose ONLY this session's own project dir, rw, so its transcript still lands on the host where
  # model attribution reads it. Both the logical and the physical cwd are bound when they differ (a symlinked
  # path component); both name THIS session's cwd, never another's. The source of a bwrap bind resolves on the
  # host, so it is the real host dir even though the destination now sits under the tmpfs.
  _own=()
  _s="$(claude_project_slug "$PWD")" && _own+=("$_s")
  _s="$(claude_project_slug "$(pwd -P)")" && [ "$_s" != "${_own[0]:-}" ] && _own+=("$_s")
  for _s in "${_own[@]}"; do
    mkdir -p "$H/.claude/projects/$_s" 2>/dev/null \
      && binds+=(--bind "$H/.claude/projects/$_s" "$H/.claude/projects/$_s")   # own transcripts only (rw)
  done
fi
# #2262 M3: ~/.claude.json is Claude Code's workspace store (the per-cwd trust flag lives in it, so the session
# needs it rw), but its `projects` map carries EVERY cwd's entry — the operator's sessions' and every other cell's
# `lastSessionFirstPrompt` included. The sandbox gets a filtered temp COPY instead: every top-level key as is,
# `projects` reduced to this session's own cwd entries (logical + physical, as for the transcript dir above). A
# detached watcher (lib/claude-json-scope.py watch-merge; detached because flat-cyborg ends a session by SIGKILLing
# its whole process group, which no exit hook of this wrapper survives) waits for this pid — bwrap after the exec
# below — to go away, merges ONLY the session's own, changed entry back into the real file, and removes the copy.
# Fail-closed: when the copy cannot be built, nothing is bound (the session sees no workspace store at all, so it
# stops at the trust dialog instead of reading other sessions' prompts).
if [ -e "$H/.claude.json" ]; then
  _cj_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/claude-json-scope.py"
  _cj_keys=("$PWD"); [ "$(pwd -P)" = "$PWD" ] || _cj_keys+=("$(pwd -P)")
  _cj_dir="$(mktemp -d "${TMPDIR:-/tmp}/df-claude-json.XXXXXX" 2>/dev/null)" || _cj_dir=""
  if [ -n "$_cj_dir" ] && [ -f "$_cj_helper" ] && command -v python3 >/dev/null 2>&1 \
     && python3 "$_cj_helper" filter "$H/.claude.json" "$_cj_dir" "${_cj_keys[@]}"; then
    binds+=(--bind "$_cj_dir/claude.json" "$H/.claude.json")                    # scoped workspace store (rw)
    python3 "$_cj_helper" watch-merge "$$" "$_cj_dir" "$H/.claude.json" "${_cj_keys[@]}" </dev/null >/dev/null 2>&1 &
  else
    echo "claude-sandboxed.sh: WARNING could not build the scoped ~/.claude.json copy — binding none (fail-closed)" >&2
    [ -z "$_cj_dir" ] || rm -rf "$_cj_dir"
  fi
fi
[ -e "$H/.foundry" ]     && binds+=(--ro-bind "$H/.foundry" "$H/.foundry")      # forge/cast/anvil toolchain
[ -e "$H/.svm" ]         && binds+=(--ro-bind "$H/.svm" "$H/.svm")              # solc version manager cache
[ -n "$REPO" ] && [ -e "$REPO" ] && binds+=(--bind "$REPO" "$REPO")            # target clone (rw: PoC/forge out)
binds+=(--bind "$RUN" "$RUN")                                                    # cell run/out dir (rw)
# AFTER the --tmpfs "$H" entry above on purpose: the cache's default location is under $HOME, and a bind that
# preceded the tmpfs would be masked by it.
[ -n "$EXTERNAL" ] && [ -e "$EXTERNAL" ] && binds+=(--bind "$EXTERNAL" "$EXTERNAL")  # #2235 external cache (rw)
binds+=(
  --setenv PATH "$H/.foundry/bin:$(dirname "$REAL"):/usr/local/bin:/usr/bin:/bin"
  --setenv HOME "$H"
  --chdir "$PWD"
)

exec bwrap "${binds[@]}" "$REAL" --disallowedTools WebFetch WebSearch "$@"
