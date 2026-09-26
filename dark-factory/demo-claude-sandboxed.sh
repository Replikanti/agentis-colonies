#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2329
# demo-claude-sandboxed.sh — proof of #2125: lib/claude-sandboxed.sh gives the
# flat-cyborg-driven Claude a bubblewrap view containing ONLY the toolchain, the
# target repo, and the cell run dir; denies WebFetch/WebSearch; is fail-closed on
# a missing bind var; falls through (with a loud warning) when bwrap is absent or
# DF_NO_SANDBOX=1; and every one of the six hunt emitters is wired to it.
#
# #2235 adds ONE optional bind to the same wrapper: HUNT_SANDBOX_EXTERNAL, the external-protocol source cache
# a discovery cell resolves into and cites back out of. Section 1 asserts it is INVISIBLE when the var is
# unset (the default), section 1b that it is readable AND writable when it is set — the cache is useless
# read-only, because the resolver writes it from inside the cell.
#
# #2262 masks the history-bearing parts of ~/.claude (bound rw for auth/trust): a real held-out hunter cell
# grepped ~/.claude/projects/* and read another zone's refuter transcripts. Section 1c pins the wrapper's
# cwd -> project-dir encoding to known answers; section 1d asserts, on a temp-HOME fixture, that inside the
# sandbox ONLY the session's own project dir is visible (and writable, landing on the host), while other
# sessions' transcripts, file-history, shell snapshots, paste cache, todos and the prompt history are not.
# #2262 M3 scopes ~/.claude.json the same way (section 1e): its `projects` map carries every cwd's
# `lastSessionFirstPrompt`, so the sandbox binds a filtered temp copy holding only the session's own cwd entry;
# a detached watcher merges that entry back into the real file after the session ends — also when the session's
# whole process group is SIGKILLed, which is how flat-cyborg ends every session — and a copy that cannot be built
# binds nothing (fail-closed).
# The WHOLE demo runs with HOME pointed at that fixture, so it never reads or writes the real ~/.claude or
# ~/.claude.json.
#
# CI-safe: uses a stub `claude` (DF_CLAUDE_BIN), no real claude / network / LLM.
# The live filesystem-isolation asserts run only when bwrap is available; without
# it they SKIP, but the fail-closed + fallthrough + static wiring asserts always
# run. Mirrors demo-flat-cyborg-env.sh's unit + wiring assertion shape.
#
# Usage:  dark-factory/demo-claude-sandboxed.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WRAP="$HERE/lib/claude-sandboxed.sh"
[ -x "$WRAP" ] || { echo "demo-claude-sandboxed.sh: wrapper not found/executable: $WRAP" >&2; exit 3; }

FAILS=0
ok()  { echo "  [OK]   $*"; }
bad() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip(){ echo "  [SKIP] $*"; }

# Physical path (pwd -P), so the cwd the wrapper encodes is the same with and without symlink resolution.
TMP="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
# #2262: a fixture HOME for the whole demo — the wrapper creates the session's own project dir under
# $HOME/.claude/projects, and the demo must never touch the operator's real ~/.claude.
export HOME="$TMP/home"
mkdir -p "$HOME"
HOME_DECOY="$(mktemp "$HOME/.df-sandbox-decoy.XXXXXX")"

# Layout: RUN (bound rw) under an OUT parent (NOT bound); a REPO (bound rw); two
# decoys the sandboxed session must NOT be able to read.
OUT="$TMP/out"; RUN="$OUT/run"; REPO="$TMP/repo"
# #2235: the external-protocol cache lives OUTSIDE both, exactly like the real one (a host-wide state dir).
EXTCACHE="$TMP/external"
mkdir -p "$RUN" "$REPO" "$EXTCACHE"
echo "cached-external-source" > "$EXTCACHE/IExample.sol"
PARENT_DECOY="$OUT/AB-NOTE-decoy.txt"          # in RUN's PARENT (held-out GT lives here)
echo "SECRET-GROUND-TRUTH" > "$PARENT_DECOY"
echo "SECRET-HOME-FILE"    > "$HOME_DECOY"     # under $HOME, outside the binds
echo "target-source"       > "$REPO/probe.sol" # inside the bound repo (readable)

# #2262 fixture ~/.claude: the session's own project dir (named for RUN, the cwd every run below uses; RUN is a
# short mktemp path, well under the 200-char cap, so its name is the plain substitution), a SECOND project dir
# standing in for another cell's refuter transcripts, and one secret-bearing file in every other history
# location. Credentials + settings must stay readable.
CL="$HOME/.claude"
OWN_SLUG="${RUN//[^A-Za-z0-9]/-}"
OTHER_SLUG="-other-run-zone-hunt-out-verify-gates-refute-out-run"
mkdir -p "$CL/projects/$OWN_SLUG" "$CL/projects/$OTHER_SLUG" "$CL/file-history/other-session" \
         "$CL/shell-snapshots" "$CL/paste-cache" "$CL/sessions" "$CL/todos"
echo '{"t":"OTHER-TRANSCRIPT-SECRET"}' > "$CL/projects/$OTHER_SLUG/other-session.jsonl"
echo '{"t":"OWN-PRIOR-TRANSCRIPT"}'    > "$CL/projects/$OWN_SLUG/prior-session.jsonl"
echo '{"display":"OPERATOR-PROMPT-SECRET"}' > "$CL/history.jsonl"
echo "OTHER-FILE-HISTORY"  > "$CL/file-history/other-session/Vault.sol@v1"
echo "OTHER-SNAPSHOT"      > "$CL/shell-snapshots/snapshot-bash-1-abc.sh"
echo "OTHER-PASTE"         > "$CL/paste-cache/0123abcd.txt"
echo '{"cwd":"OTHER-SESSION-META"}' > "$CL/sessions/4242.json"
echo "OTHER-TODO"          > "$CL/todos/other-session.json"
echo "CREDS-FIXTURE"       > "$CL/.credentials.json"
echo '{"fixture":"settings"}' > "$CL/settings.json"
HIST_BEFORE="$(cat "$CL/history.jsonl")"

# A stub standing in for the real `claude`: it reports what it can see from
# inside the sandbox and echoes the argv it received (to prove --disallowedTools).
STUB="$TMP/claude-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
{
  echo "ARGS: $*"
  if cat "$D_PARENT" 2>/dev/null >/dev/null; then echo "PARENT_DECOY_READABLE"; else echo "PARENT_DECOY_BLOCKED"; fi
  if cat "$D_HOME"   2>/dev/null >/dev/null; then echo "HOME_DECOY_READABLE";   else echo "HOME_DECOY_BLOCKED";   fi
  if cat "$D_PROBE"  2>/dev/null >/dev/null; then echo "REPO_READABLE";         else echo "REPO_UNREADABLE";      fi
  if cat "$D_EXT"    2>/dev/null >/dev/null; then echo "EXT_READABLE";          else echo "EXT_BLOCKED";           fi
  if echo w > "$EXT_WRITE"  2>/dev/null; then echo "EXT_WRITABLE"; else echo "EXT_NOTWRITABLE"; fi
  if echo w > "$RUN_WRITE"  2>/dev/null; then echo "RUN_WRITABLE";  else echo "RUN_NOTWRITABLE";  fi
  if echo w > "$REPO_WRITE" 2>/dev/null; then echo "REPO_WRITABLE"; else echo "REPO_NOTWRITABLE"; fi
  # #2262 probes (section 1d only): what a cell sees when it goes looking through ~/.claude.
  if [ -n "${D_CL:-}" ]; then
    echo "PROJ_LS=[$(ls -A "$D_CL/projects" 2>/dev/null | tr '\n' ' ')]"
    if cat "$D_CL/projects/$D_OTHER/other-session.jsonl" >/dev/null 2>&1; then echo "OTHER_PROJ_READABLE"; else echo "OTHER_PROJ_BLOCKED"; fi
    if [ -n "${D_OWN_PRIOR:-}" ]; then
      if cat "$D_CL/projects/$D_OWN/prior-session.jsonl" >/dev/null 2>&1; then echo "OWN_PRIOR_READABLE"; else echo "OWN_PRIOR_BLOCKED"; fi
    fi
    if echo '{"t":"own"}' > "$D_CL/projects/$D_OWN/session-new.jsonl" 2>/dev/null; then echo "OWN_WRITABLE"; else echo "OWN_NOTWRITABLE"; fi
    echo '{"display":"sandboxed-prompt"}' >> "$D_CL/history.jsonl" 2>/dev/null
    # The exact move the leaking cell made: a recursive grep over everything under ~/.claude.
    _leak="$(grep -rlE 'OTHER-TRANSCRIPT-SECRET|OPERATOR-PROMPT-SECRET|OTHER-FILE-HISTORY|OTHER-SNAPSHOT|OTHER-PASTE|OTHER-SESSION-META|OTHER-TODO' "$D_CL" 2>/dev/null | tr '\n' ' ')"
    if [ -z "$_leak" ]; then echo "NO_HISTORY_LEAK"; else echo "HISTORY_LEAK=[$_leak]"; fi
    if cat "$D_CL/.credentials.json" >/dev/null 2>&1; then echo "CREDS_READABLE"; else echo "CREDS_BLOCKED"; fi
    if cat "$D_CL/settings.json" >/dev/null 2>&1; then echo "SETTINGS_READABLE"; else echo "SETTINGS_BLOCKED"; fi
  fi
  # #2262 M3 probes (section 1e only): what a cell sees in ~/.claude.json, then (optionally) a session write.
  if [ -n "${D_CJ:-}" ]; then
    if [ ! -e "$HOME/.claude.json" ]; then echo "CJ_ABSENT"
    else
      if grep -q OTHER-PROMPT-SECRET "$HOME/.claude.json"; then echo "CJ_OTHER_LEAK"; else echo "CJ_OTHER_BLOCKED"; fi
      if grep -q OWN-EARLIER-PROMPT "$HOME/.claude.json"; then echo "CJ_OWN_VISIBLE"; else echo "CJ_OWN_MISSING"; fi
      if grep -q numStartups "$HOME/.claude.json"; then echo "CJ_TOPLEVEL_KEPT"; else echo "CJ_TOPLEVEL_LOST"; fi
    fi
    if [ -n "${D_CJ_WRITE:-}" ]; then
      printf '{"numStartups": 99, "projects": {"%s": {"hasTrustDialogAccepted": true, "lastSessionFirstPrompt": "%s"}}}\n' \
        "$D_CJ_OWN" "$D_CJ_WRITE" > "$HOME/.claude.json" && echo "CJ_WROTE"
    fi
  fi
} > "$D_RESULT" 2>&1
if [ -n "${D_CJ_SLEEP:-}" ]; then sleep "$D_CJ_SLEEP"; fi
STUBEOF
chmod +x "$STUB"

RESULT="$RUN/stub-result.txt"
# env threaded to the stub INSIDE the sandbox (bwrap keeps the env; the wrapper
# only overrides PATH/HOME).
stub_env=(
  D_PARENT="$PARENT_DECOY" D_HOME="$HOME_DECOY" D_PROBE="$REPO/probe.sol"
  RUN_WRITE="$RUN/w.txt" REPO_WRITE="$REPO/w.txt" D_RESULT="$RESULT"
  D_EXT="$EXTCACHE/IExample.sol" EXT_WRITE="$EXTCACHE/w.txt"
)

echo "demo-claude-sandboxed.sh: 1) live sandbox isolation (bwrap-gated) ..."
if command -v bwrap >/dev/null 2>&1; then
  rm -f "$RESULT"
  # Run from inside $RUN: production cells always cwd into a bound path (serial dir=$RUN, parallel $RUN/cell-*),
  # so the wrapper's `--chdir $PWD` lands on a bound dir. A cwd outside the binds would (correctly) fail bwrap.
  ( cd "$RUN" && env "${stub_env[@]}" \
      HUNT_SANDBOX_RUN="$RUN" HUNT_SANDBOX_REPO="$REPO" DF_CLAUDE_BIN="$STUB" \
      "$WRAP" -p 'probe' >/dev/null 2>&1 ) || true
  if [ -f "$RESULT" ]; then
    R="$(cat "$RESULT")"
    case "$R" in *PARENT_DECOY_BLOCKED*) ok "RUN's parent (held-out GT / AB-NOTE) is INVISIBLE inside the sandbox" ;;
                 *) bad "parent-dir decoy was readable from inside the sandbox: $R" ;; esac
    case "$R" in *HOME_DECOY_BLOCKED*)   ok "a \$HOME file outside the binds is INVISIBLE inside the sandbox" ;;
                 *) bad "home decoy was readable from inside the sandbox: $R" ;; esac
    case "$R" in *REPO_READABLE*)        ok "the bound target repo is READABLE inside the sandbox" ;;
                 *) bad "bound repo was not readable: $R" ;; esac
    case "$R" in *RUN_WRITABLE*)         ok "the bound run dir is WRITABLE inside the sandbox" ;;
                 *) bad "bound run dir was not writable: $R" ;; esac
    case "$R" in *REPO_WRITABLE*)        ok "the bound repo is WRITABLE inside the sandbox (rw bind per STOP-1)" ;;
                 *) bad "bound repo was not writable: $R" ;; esac
    case "$R" in *"--disallowedTools WebFetch WebSearch"*) ok "web tools denied: claude got --disallowedTools WebFetch WebSearch" ;;
                 *) bad "the --disallowedTools WebFetch WebSearch flags were not passed: $R" ;; esac
    # #2235: HUNT_SANDBOX_EXTERNAL was NOT set on this run, so the cache must be as invisible as any other
    # host directory — the bind is opt-in, never a widening the default run pays for.
    case "$R" in *EXT_BLOCKED*)          ok "the external cache is INVISIBLE when HUNT_SANDBOX_EXTERNAL is unset (#2235)" ;;
                 *) bad "the external cache was readable with HUNT_SANDBOX_EXTERNAL unset: $R" ;; esac
  else
    bad "the sandboxed stub produced no result file (wrapper did not run the stub inside bwrap)"
  fi
else
  skip "bwrap not available — skipping live isolation asserts (fail-closed + wiring asserts still run)"
fi

echo
echo "demo-claude-sandboxed.sh: 1b) the #2235 external-cache bind (bwrap-gated) ..."
if command -v bwrap >/dev/null 2>&1; then
  rm -f "$RESULT"
  ( cd "$RUN" && env "${stub_env[@]}" \
      HUNT_SANDBOX_RUN="$RUN" HUNT_SANDBOX_REPO="$REPO" HUNT_SANDBOX_EXTERNAL="$EXTCACHE" DF_CLAUDE_BIN="$STUB" \
      "$WRAP" -p 'probe' >/dev/null 2>&1 ) || true
  if [ -f "$RESULT" ]; then
    R="$(cat "$RESULT")"
    case "$R" in *EXT_READABLE*) ok "with HUNT_SANDBOX_EXTERNAL set, the external cache is READABLE inside the sandbox" ;;
                 *) bad "the bound external cache was not readable: $R" ;; esac
    case "$R" in *EXT_WRITABLE*) ok "the external cache is WRITABLE (the resolver fills it from inside the cell)" ;;
                 *) bad "the bound external cache was not writable: $R" ;; esac
    # The new bind widens NOTHING else: the two decoys stay blocked with the cache bound.
    case "$R" in *PARENT_DECOY_BLOCKED*) ok "the cache bind does not widen the view: RUN's parent stays invisible" ;;
                 *) bad "parent decoy became readable once the cache was bound: $R" ;; esac
    case "$R" in *HOME_DECOY_BLOCKED*)   ok "the cache bind does not widen the view: \$HOME stays invisible" ;;
                 *) bad "home decoy became readable once the cache was bound: $R" ;; esac
  else
    bad "the sandboxed stub produced no result file with HUNT_SANDBOX_EXTERNAL set"
  fi
else
  skip "bwrap not available — skipping the #2235 external-cache bind asserts"
fi

echo
echo "demo-claude-sandboxed.sh: 1c) #2262 cwd -> project-dir encoding matches Claude Code (known answers) ..."
# The wrapper's claude_project_slug, lifted verbatim. The expected values follow Claude Code's own sanitizer
# (non-[A-Za-z0-9] -> '-'; past 200 chars: cut + '-' + base36 |djb2|), cross-checked against real hashed
# project dirs Claude Code created; one long vector has a negative djb2, the other a positive one.
eval "$(sed -n '/^claude_project_slug() {$/,/^}$/p' "$WRAP")"
if ! command -v claude_project_slug >/dev/null 2>&1; then
  bad "could not lift claude_project_slug out of the wrapper"
else
  KAT_LONG1="/srv/op/.dark-factory/runs/example-contest/zone-hunt-out/verify/gates/src_Vault.sol_withdraw_142/refute-out/run/cells/cell-07/nested/path/that/keeps/going/past/the/two/hundred/char/cap/for/claude/code/project/dirs"
  KAT_LONG2="/tmp/x/refute-out/run/$(printf '%0230d' 0 | tr 0 a)"
  _k1="${KAT_LONG1//[^A-Za-z0-9]/-}"; _k2="${KAT_LONG2//[^A-Za-z0-9]/-}"
  for _kat in "/srv/op/.dark-factory/zone_hunt.out/run|-srv-op--dark-factory-zone-hunt-out-run" \
              "$KAT_LONG1|${_k1:0:200}-fn819k" \
              "$KAT_LONG2|${_k2:0:200}-e4uy0x"; do
    _in="${_kat%%|*}"; _want="${_kat#*|}"; _got="$(claude_project_slug "$_in")"
    if [ "$_got" = "$_want" ]; then ok "slug(${#_in}-char path) = ...${_want: -24}"
    else bad "slug(${#_in}-char path): got ...${_got: -24}, want ...${_want: -24}"; fi
  done
fi

echo
echo "demo-claude-sandboxed.sh: 1d) #2262 ~/.claude history isolation (bwrap-gated, temp-HOME fixture) ..."
if command -v bwrap >/dev/null 2>&1; then
  rm -f "$RESULT"
  ( cd "$RUN" && env "${stub_env[@]}" D_CL="$CL" D_OWN="$OWN_SLUG" D_OTHER="$OTHER_SLUG" D_OWN_PRIOR=1 \
      HUNT_SANDBOX_RUN="$RUN" HUNT_SANDBOX_REPO="$REPO" DF_CLAUDE_BIN="$STUB" \
      "$WRAP" -p 'probe' >/dev/null 2>&1 ) || true
  if [ -f "$RESULT" ]; then
    R="$(cat "$RESULT")"
    case "$R" in *"PROJ_LS=[$OWN_SLUG ]"*) ok "\$HOME/.claude/projects shows ONLY the session's own cwd dir inside the sandbox" ;;
                 *) bad "\$HOME/.claude/projects inside the sandbox is not exactly the own-cwd dir: $R" ;; esac
    case "$R" in *OTHER_PROJ_BLOCKED*)   ok "another session's transcript (other project dir) is INVISIBLE" ;;
                 *) bad "another session's transcript was readable inside the sandbox: $R" ;; esac
    case "$R" in *OWN_PRIOR_READABLE*)   ok "the session's own earlier transcripts stay readable (own dir is a real bind, not an empty tmpfs)" ;;
                 *) bad "the own project dir's existing transcript was not readable: $R" ;; esac
    case "$R" in *OWN_WRITABLE*)         ok "the own project dir is WRITABLE inside the sandbox" ;;
                 *) bad "the own project dir was not writable: $R" ;; esac
    case "$R" in *NO_HISTORY_LEAK*)      ok "a recursive grep over ~/.claude finds no other session's content (transcripts, history, file-history, snapshots, paste cache, sessions, todos)" ;;
                 *) bad "other sessions' content is reachable from inside the sandbox: $R" ;; esac
    case "$R" in *CREDS_READABLE*)       ok "credentials stay readable (auth keeps working)" ;;
                 *) bad "credentials were not readable inside the sandbox: $R" ;; esac
    case "$R" in *SETTINGS_READABLE*)    ok "settings stay readable" ;;
                 *) bad "settings were not readable inside the sandbox: $R" ;; esac
  else
    bad "the sandboxed stub produced no result file in the #2262 run"
  fi
  # Host side: the transcript written inside landed in the host's own-cwd dir (attribution reads it there), the
  # other session is untouched, the prompt history was neither leaked nor modified, and no stray dir appeared.
  if [ -f "$CL/projects/$OWN_SLUG/session-new.jsonl" ]; then ok "the transcript written inside the sandbox landed in the HOST's own-cwd project dir"
  else bad "the sandbox transcript did not reach the host's own-cwd project dir"; fi
  if grep -q OTHER-TRANSCRIPT-SECRET "$CL/projects/$OTHER_SLUG/other-session.jsonl" 2>/dev/null; then ok "the other session's host transcript is untouched"
  else bad "the other session's host transcript was modified or removed"; fi
  if [ "$(cat "$CL/history.jsonl")" = "$HIST_BEFORE" ]; then ok "the host prompt history is unchanged (read as empty, append discarded)"
  else bad "the host prompt history changed: $(cat "$CL/history.jsonl")"; fi
  _hostls="$(find "$CL/projects" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ')"
  _wantls="$(printf '%s\n%s\n' "$OWN_SLUG" "$OTHER_SLUG" | sort | tr '\n' ' ')"
  if [ "$_hostls" = "$_wantls" ]; then ok "no stray project dir was created on the host"
  else bad "unexpected host project dirs: [$_hostls] want [$_wantls]"; fi

  # A cwd past the 200-char cap: the wrapper must bind the HASHED name (the one Claude Code will use), creating
  # it on the host first, and still show nothing else.
  LONG_CWD="$RUN/$(printf '%0200d' 0 | tr 0 c)"
  mkdir -p "$LONG_CWD"
  LONG_SLUG="$(claude_project_slug "$LONG_CWD" 2>/dev/null || true)"
  rm -f "$RESULT"
  ( cd "$LONG_CWD" && env "${stub_env[@]}" D_CL="$CL" D_OWN="$LONG_SLUG" D_OTHER="$OTHER_SLUG" \
      HUNT_SANDBOX_RUN="$RUN" HUNT_SANDBOX_REPO="$REPO" DF_CLAUDE_BIN="$STUB" \
      "$WRAP" -p 'probe' >/dev/null 2>&1 ) || true
  R="$(cat "$RESULT" 2>/dev/null || true)"
  if [ "${#LONG_SLUG}" -gt 200 ] && case "$R" in *"PROJ_LS=[$LONG_SLUG ]"*OWN_WRITABLE*NO_HISTORY_LEAK*) true ;; *) false ;; esac \
     && [ -f "$CL/projects/$LONG_SLUG/session-new.jsonl" ]; then
    ok "a >200-char cwd gets exactly its hashed project dir (…${LONG_SLUG: -7}), writable and landing on the host"
  else
    bad "the long-cwd run did not bind exactly the hashed own dir (slug …${LONG_SLUG: -7}): $R"
  fi
else
  skip "bwrap not available — skipping the #2262 ~/.claude history isolation asserts"
fi

echo
echo "demo-claude-sandboxed.sh: 1e) #2262 M3 scoped ~/.claude.json (bwrap-gated, temp-HOME fixture) ..."
if command -v bwrap >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  CJ="$HOME/.claude.json"; CJTMP="$TMP/cjtmp"; mkdir -p "$CJTMP"
  cj_fixture() {
    printf '{\n  "numStartups": 7,\n  "oauthAccount": {"emailAddress": "fixture@example.invalid"},\n  "projects": {\n    "%s": {"hasTrustDialogAccepted": true, "lastSessionFirstPrompt": "OWN-EARLIER-PROMPT"},\n    "/srv/operator/other-session": {"hasTrustDialogAccepted": true, "lastSessionFirstPrompt": "OTHER-PROMPT-SECRET"}\n  }\n}\n' "$RUN" > "$CJ"
    chmod 600 "$CJ"
  }
  # cj_get <python expr over d> -> the value read from the host's real (fixture) file
  cj_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$CJ" "$1" 2>/dev/null; }
  cj_settled() { local i=0; while [ "$i" -lt 60 ]; do [ -z "$(ls -A "$CJTMP")" ] && return 0; sleep 0.25; i=$((i + 1)); done; return 1; }
  cj_env=(D_CJ=1 D_CJ_OWN="$RUN" TMPDIR="$CJTMP" HUNT_SANDBOX_RUN="$RUN" HUNT_SANDBOX_REPO="$REPO" DF_CLAUDE_BIN="$STUB")

  cj_fixture; rm -f "$RESULT"
  ( cd "$RUN" && env "${stub_env[@]}" "${cj_env[@]}" D_CJ_WRITE=SANDBOX-SESSION-PROMPT "$WRAP" -p 'probe' >/dev/null 2>&1 ) || true
  R="$(cat "$RESULT" 2>/dev/null || true)"
  case "$R" in *CJ_OTHER_BLOCKED*) ok "another cwd's projects entry (its lastSessionFirstPrompt) is INVISIBLE in the sandbox's ~/.claude.json" ;;
               *) bad "another cwd's entry is readable inside the sandbox: $R" ;; esac
  case "$R" in *CJ_OWN_VISIBLE*CJ_TOPLEVEL_KEPT*) ok "the session's own cwd entry (its trust flag) and every top-level key stay visible" ;;
               *) bad "the own entry / top-level keys are missing inside the sandbox: $R" ;; esac
  # cj_own -> the host file's lastSessionFirstPrompt for the session's own cwd
  cj_own() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["projects"][sys.argv[2]]["lastSessionFirstPrompt"])' "$CJ" "$RUN" 2>/dev/null; }
  if cj_settled && [ "$(cj_own)" = SANDBOX-SESSION-PROMPT ]; then
    ok "after the session exits, its own entry is merged back into the host file and the temp copy is removed"
  else
    bad "the session's own entry was not merged back (or the temp copy was left): $(ls -A "$CJTMP" | tr '\n' ' ')"
  fi
  if [ "$(cj_get 'd["projects"]["/srv/operator/other-session"]["lastSessionFirstPrompt"]')" = OTHER-PROMPT-SECRET ] \
     && [ "$(cj_get 'd["numStartups"]')" = 7 ] && [ "$(stat -c %a "$CJ" 2>/dev/null || stat -f %Lp "$CJ")" = 600 ]; then
    ok "the merge touches ONLY the session's own entry: other cwds and top-level keys are untouched, mode 0600 kept"
  else
    bad "the merge changed more than the own entry: $(cat "$CJ")"
  fi

  cj_fixture; cj_before="$(cksum < "$CJ")"
  ( cd "$RUN" && env "${stub_env[@]}" "${cj_env[@]}" "$WRAP" -p 'probe' >/dev/null 2>&1 ) || true
  if cj_settled && [ "$(cksum < "$CJ")" = "$cj_before" ]; then
    ok "a session that changes nothing leaves the host file byte-identical (no write at all)"
  else
    bad "an unchanged session rewrote the host file (or left its temp copy)"
  fi

  # flat-cyborg ends every session by SIGKILLing its process group: the merge must survive that.
  if command -v setsid >/dev/null 2>&1; then
    cj_fixture; rm -f "$RESULT"
    ( cd "$RUN" && exec env "${stub_env[@]}" "${cj_env[@]}" D_CJ_WRITE=SANDBOX-KILL-PROMPT D_CJ_SLEEP=30 \
        setsid "$WRAP" -p 'probe' >/dev/null 2>&1 ) &
    cj_pid=$!
    i=0; while [ "$i" -lt 60 ] && ! grep -qs CJ_WROTE "$RESULT"; do sleep 0.25; i=$((i + 1)); done
    kill -KILL -- "-$cj_pid" 2>/dev/null || kill -KILL "$cj_pid" 2>/dev/null
    wait "$cj_pid" 2>/dev/null
    if cj_settled && [ "$(cj_own)" = SANDBOX-KILL-PROMPT ]; then
      ok "the merge-back survives a SIGKILL of the session's whole process group (the detached watcher)"
    else
      bad "a SIGKILLed session's own entry was not merged back: $(ls -A "$CJTMP" | tr '\n' ' ')"
    fi
  else
    skip "setsid not available — skipping the process-group SIGKILL merge case"
  fi

  printf '{"projects": {"/srv/operator/other-session": {"lastSessionFirstPrompt": "OTHER-PROMPT-SECRET"}' > "$CJ"
  rm -f "$RESULT"
  _err="$( ( cd "$RUN" && env "${stub_env[@]}" "${cj_env[@]}" "$WRAP" -p 'probe' 2>&1 >/dev/null ) || true)"
  R="$(cat "$RESULT" 2>/dev/null || true)"
  if case "$R" in *CJ_ABSENT*) true ;; *) false ;; esac && case "$_err" in *"binding none"*) true ;; *) false ;; esac \
     && [ -z "$(ls -A "$CJTMP")" ]; then
    ok "fail-closed: an unreadable host file binds NO ~/.claude.json (loud warning), never the raw file"
  else
    bad "an unreadable host file was not handled fail-closed: $R / $_err"
  fi
  rm -f "$CJ"
else
  skip "bwrap or python3 not available — skipping the #2262 M3 scoped ~/.claude.json asserts"
fi

echo
echo "demo-claude-sandboxed.sh: 2) fail-closed on a missing bind var ..."
# HUNT_SANDBOX_RUN unset MUST abort (never silently run unsandboxed). DF_CLAUDE_BIN
# is set so the abort is on the bind var, not on a missing claude.
if env -u HUNT_SANDBOX_RUN DF_CLAUDE_BIN="$STUB" "$WRAP" -p x >/dev/null 2>&1; then
  bad "wrapper ran with HUNT_SANDBOX_RUN unset (should have aborted fail-closed)"
else
  ok "wrapper aborts when HUNT_SANDBOX_RUN is unset (fail-closed: never runs unsandboxed silently)"
fi

echo
echo "demo-claude-sandboxed.sh: 3) fallthrough paths warn loudly ..."
# (a) explicit opt-out.
_err="$(env "${stub_env[@]}" DF_NO_SANDBOX=1 HUNT_SANDBOX_RUN="$RUN" HUNT_SANDBOX_REPO="$REPO" DF_CLAUDE_BIN="$STUB" \
        "$WRAP" -p x 2>&1 >/dev/null || true)"
case "$_err" in *"DF_NO_SANDBOX"*UNSANDBOXED*) ok "DF_NO_SANDBOX=1 -> falls through to real claude with a loud UNSANDBOXED warning" ;;
               *) bad "DF_NO_SANDBOX=1 did not print the expected UNSANDBOXED warning: $_err" ;; esac
# (b) bwrap absent — simulated by a PATH that has bash (the wrapper's own interpreter) but NOT bwrap
# (DF_CLAUDE_BIN skips the claude lookup, so the only remaining PATH-dependent step is `command -v bwrap`).
NOBWRAP_BIN="$TMP/nobwrap-bin"; mkdir -p "$NOBWRAP_BIN"
ln -sf "$(command -v bash)" "$NOBWRAP_BIN/bash"
_err="$(cd "$RUN" && env "${stub_env[@]}" PATH="$NOBWRAP_BIN" HUNT_SANDBOX_RUN="$RUN" HUNT_SANDBOX_REPO="$REPO" DF_CLAUDE_BIN="$STUB" \
        "$WRAP" -p x 2>&1 >/dev/null || true)"
case "$_err" in *"bwrap not found"*UNSANDBOXED*) ok "bwrap absent -> falls through to real claude with a loud UNSANDBOXED warning" ;;
               *) bad "bwrap-absent path did not print the expected warning: $_err" ;; esac

echo
echo "demo-claude-sandboxed.sh: 4) static wiring — each of the six hunt emitters sets the target AND exports both bind vars ..."
for f in run-discovery.sh run-refute.sh run-invariant-hunt.sh map-zones.sh gen-briefs.sh run-poc.sh; do
  p="$HERE/$f"
  [ -f "$p" ] || { bad "$f: emitter not found"; continue; }
  # (i) points llm.flat_cyborg.target at THIS wrapper (guarded emission).
  _t="$(grep -E 'llm\.flat_cyborg\.target =' "$p" | grep 'lib/claude-sandboxed\.sh' || true)"
  # (ii) exports BOTH bind vars (catches "target set but env not threaded" and the inverse).
  _e="$(grep -E 'export HUNT_SANDBOX_REPO=.*HUNT_SANDBOX_RUN=' "$p" || true)"
  if [ -n "$_t" ] && [ -n "$_e" ]; then
    ok "$f: emits llm.flat_cyborg.target=<wrapper> AND exports HUNT_SANDBOX_REPO/HUNT_SANDBOX_RUN"
  else
    [ -z "$_t" ] && bad "$f: does NOT set llm.flat_cyborg.target to lib/claude-sandboxed.sh"
    [ -z "$_e" ] && bad "$f: does NOT export both HUNT_SANDBOX_REPO and HUNT_SANDBOX_RUN"
  fi
done

echo
echo "demo-claude-sandboxed.sh: 5) PATH resolver (no DF_CLAUDE_BIN) ..."
# These three arms exercise the real resolver in lib/claude-sandboxed.sh (no
# DF_CLAUDE_BIN test seam). On main (the #2148 bug: 'command -v -a claude' is
# invalid syntax under bash), REAL never gets set for (a)/(b), so both would
# report rc 127 instead of resolving — they only pass once the 'type -aP claude'
# fix lands.
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'FAKEEOF'
#!/bin/sh
echo "FAKE-CLAUDE-RESOLVED $*"
FAKEEOF
chmod +x "$FAKEBIN/claude"

# (a) a fake claude alone on PATH resolves the fake. Run from inside $RUN (a
# bound dir) so the wrapper's `--chdir $PWD` succeeds inside bwrap, matching
# section 1's convention.
_out="$(cd "$RUN" && HUNT_SANDBOX_RUN="$RUN" PATH="$FAKEBIN:$PATH" "$WRAP" --version 2>&1)"
_rc=$?
case "$_out" in *FAKE-CLAUDE-RESOLVED*) ok "fake claude alone on PATH resolves (no DF_CLAUDE_BIN): $_out" ;;
               *) bad "fake claude on PATH did not resolve (rc=$_rc): $_out" ;; esac

# (b) self-skip still holds when a copy of the wrapper is named claude and sorts
# first on PATH. Invoke the COPY directly (its own $0 ends in "claude", so it
# self-identifies as the PATH entry it must skip) with PATH pointing back at
# itself first, then the fake: the loop must skip that self-match and keep
# walking to the fake further down PATH.
SELFBIN="$TMP/selfbin"; mkdir -p "$SELFBIN"
cp "$WRAP" "$SELFBIN/claude"
chmod +x "$SELFBIN/claude"
_out="$(cd "$RUN" && HUNT_SANDBOX_RUN="$RUN" PATH="$SELFBIN:$FAKEBIN:$PATH" "$SELFBIN/claude" --version 2>&1)"
_rc=$?
case "$_out" in *FAKE-CLAUDE-RESOLVED*) ok "wrapper copy named 'claude' first on PATH is skipped, fake further down resolves: $_out" ;;
               *) bad "self-skip did not hold with a wrapper copy first on PATH (rc=$_rc): $_out" ;; esac

# (c) nothing on PATH -> loud 127. PATH must still resolve bash (the wrapper's
# own interpreter, per its #!/usr/bin/env bash shebang) but have no claude
# anywhere, so the failure is specifically "no claude", not "no bash".
EMPTYBIN="$TMP/emptybin"; mkdir -p "$EMPTYBIN"
ln -sf "$(command -v bash)" "$EMPTYBIN/bash"
_out="$(HUNT_SANDBOX_RUN="$RUN" PATH="$EMPTYBIN" "$WRAP" --version 2>&1)"
_rc=$?
if [ "$_rc" -eq 127 ] && case "$_out" in *"no real 'claude' binary found on PATH"*) true ;; *) false ;; esac; then
  ok "empty PATH -> loud 127 with the expected 'no real claude binary' message"
else
  bad "empty PATH did not fail loud-127 as expected (rc=$_rc): $_out"
fi

# Live smoke recipe (manual, needs a real claude + bwrap):
#   HUNT_SANDBOX_RUN=/tmp/run HUNT_SANDBOX_REPO=/path/to/clone \
#     dark-factory/lib/claude-sandboxed.sh -p 'run: ls -a ~ ; cat ~/.bash_history'
#   -> should list only the tmpfs $HOME (no real dotfiles / history), and any
#      WebFetch/WebSearch attempt is refused.

echo
if [ "$FAILS" -eq 0 ]; then
  echo "demo-claude-sandboxed.sh: PASS — sandbox hides everything outside the repo + run dir (plus, only when"
  echo "                         #2235 asks for it, the external-protocol cache), exposes only its own"
  echo "                         ~/.claude project dir and none of the other sessions' history (#2262),"
  echo "                         binds a ~/.claude.json scoped to its own cwd and merges only that entry back (#2262 M3),"
  echo "                         denies the web tools, is fail-closed, falls through safely, and all six emitters are wired."
  exit 0
fi
echo "demo-claude-sandboxed.sh: DEMO FAILED — a #2125 sandbox assertion did not hold" >&2
exit 1
