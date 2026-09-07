#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2329
# demo-claude-sandboxed.sh — proof of #2125: lib/claude-sandboxed.sh gives the
# flat-cyborg-driven Claude a bubblewrap view containing ONLY the toolchain, the
# target repo, and the cell run dir; denies WebFetch/WebSearch; is fail-closed on
# a missing bind var; falls through (with a loud warning) when bwrap is absent or
# DF_NO_SANDBOX=1; and every one of the five hunt emitters is wired to it.
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

TMP="$(mktemp -d)"
HOME_DECOY="$(mktemp "$HOME/.df-sandbox-decoy.XXXXXX")"
cleanup() { rm -rf "$TMP"; rm -f "$HOME_DECOY"; }
trap cleanup EXIT

# Layout: RUN (bound rw) under an OUT parent (NOT bound); a REPO (bound rw); two
# decoys the sandboxed session must NOT be able to read.
OUT="$TMP/out"; RUN="$OUT/run"; REPO="$TMP/repo"
mkdir -p "$RUN" "$REPO"
PARENT_DECOY="$OUT/AB-NOTE-decoy.txt"          # in RUN's PARENT (held-out GT lives here)
echo "SECRET-GROUND-TRUTH" > "$PARENT_DECOY"
echo "SECRET-HOME-FILE"    > "$HOME_DECOY"     # under $HOME, outside the binds
echo "target-source"       > "$REPO/probe.sol" # inside the bound repo (readable)

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
  if echo w > "$RUN_WRITE"  2>/dev/null; then echo "RUN_WRITABLE";  else echo "RUN_NOTWRITABLE";  fi
  if echo w > "$REPO_WRITE" 2>/dev/null; then echo "REPO_WRITABLE"; else echo "REPO_NOTWRITABLE"; fi
} > "$D_RESULT" 2>&1
STUBEOF
chmod +x "$STUB"

RESULT="$RUN/stub-result.txt"
# env threaded to the stub INSIDE the sandbox (bwrap keeps the env; the wrapper
# only overrides PATH/HOME).
stub_env=(
  D_PARENT="$PARENT_DECOY" D_HOME="$HOME_DECOY" D_PROBE="$REPO/probe.sol"
  RUN_WRITE="$RUN/w.txt" REPO_WRITE="$REPO/w.txt" D_RESULT="$RESULT"
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
  else
    bad "the sandboxed stub produced no result file (wrapper did not run the stub inside bwrap)"
  fi
else
  skip "bwrap not available — skipping live isolation asserts (fail-closed + wiring asserts still run)"
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
echo "demo-claude-sandboxed.sh: 4) static wiring — each of the five hunt emitters sets the target AND exports both bind vars ..."
for f in run-discovery.sh run-refute.sh run-invariant-hunt.sh map-zones.sh gen-briefs.sh; do
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

# Live smoke recipe (manual, needs a real claude + bwrap):
#   HUNT_SANDBOX_RUN=/tmp/run HUNT_SANDBOX_REPO=/path/to/clone \
#     dark-factory/lib/claude-sandboxed.sh -p 'run: ls -a ~ ; cat ~/.bash_history'
#   -> should list only the tmpfs $HOME (no real dotfiles / history), and any
#      WebFetch/WebSearch attempt is refused.

echo
if [ "$FAILS" -eq 0 ]; then
  echo "demo-claude-sandboxed.sh: PASS — sandbox hides everything outside the repo + run dir,"
  echo "                         denies the web tools, is fail-closed, falls through safely, and all five emitters are wired."
  exit 0
fi
echo "demo-claude-sandboxed.sh: DEMO FAILED — a #2125 sandbox assertion did not hold" >&2
exit 1
