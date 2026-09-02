#!/usr/bin/env bash
# dark-factory/lib/ensure-claude-trust.sh — best-effort pre-trust of a substrate RUN
# dir in Claude Code's workspace-trust ledger (~/.claude.json), so a flat-cyborg /
# claude backend session started with cwd = that dir does not block on the trust
# dialog (agentis-core#993).
#
# THE BUG THIS CLOSES. Claude Code gates every workspace on a first-run trust
# dialog: unless `projects["<abs-cwd>"].hasTrustDialogAccepted == true` exists in
# ~/.claude.json, an INTERACTIVE session (which flat-cyborg drives over a PTY —
# stdout IS a TTY, so the `-p`/non-TTY auto-skip does NOT apply) blocks on the
# dialog, ignores the piped prompt, and exits(1) after idle. The DISCOVERY
# substrate runs `agentis go <agent>.ag` with cwd = a fresh, ephemeral RUN dir
# under ~/.dark-factory/... that has never been trusted -> claude exits ->
# flat-cyborg reports `exit status: 75` ("target exited, no reply") on EVERY zone,
# blocking the whole hunt. Trust does NOT inherit to subdirs; it must be recorded
# for the EXACT dir claude runs in. `--dangerously-skip-permissions` is a separate
# gate and does not help. There is no claude flag / settings.json key / env var
# that pre-trusts a directory for an interactive session (the only skip is
# `-p`/non-TTY, which the PTY backend cannot use), so the ledger is written here.
#
# CONTRACT (mirrors the substrate's other best-effort steps — NEVER aborts a hunt):
#   - Atomic: writes a sibling temp file + os.replace() so a partial ~/.claude.json
#     is never observable (it is the user's live Claude Code state, thousands of
#     projects — a truncated write would be catastrophic).
#   - Idempotent: already-trusted dir -> no write at all.
#   - Preserves every other key/project and the file's existing mode; creates
#     ~/.claude.json (and the projects map) if absent.
#   - Best-effort: any failure (no python3, unreadable/corrupt json, unwritable
#     HOME) is logged to stderr and swallowed -> exit 0, the hunt proceeds.
#
# USAGE (source + call, or run standalone):
#   . "$HERE/lib/ensure-claude-trust.sh"
#   df_ensure_claude_trust "$RUN"        # right before the `agentis go` spawn loop
#   df_ensure_claude_trust "$d1" "$d2"   # variadic: several dirs in ONE atomic write
#   # -- or, standalone (what the #993 repro invokes) --
#   bash lib/ensure-claude-trust.sh /abs/path/to/run
#
# CONCURRENCY. The write is a whole-file read-modify-write, so it is NOT safe to run
# two copies against DIFFERENT dirs at once (both would drop the other's key). Call
# it from the FOREGROUND, before backgrounding any `agentis go` — the substrate does
# exactly that (serialized in the launch loop, never inside a `run_cell &` subshell).
#
# Gate the call on the backend actually spawning claude (flat-cyborg / claude);
# skip it for the mock backend, which never launches an LLM session.

# df_ensure_claude_trust <abs-dir> [<abs-dir> ...] — record hasTrustDialogAccepted=true
# for each ABSOLUTE dir in ~/.claude.json (one atomic write). Always returns 0.
df_ensure_claude_trust() {
  if [ "$#" -eq 0 ]; then
    echo "ensure-claude-trust: no directory given (skipping)" >&2
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ensure-claude-trust: python3 not found (skipping trust pre-accept)" >&2
    return 0
  fi
  # HOME resolved dynamically inside python (never a hardcoded path). The python
  # never exits non-zero: it prints a diagnostic and returns cleanly on any error.
  python3 - "$@" <<'PY' || true
import json, os, sys, tempfile

targets = [d for d in sys.argv[1:] if d]
home = os.path.expanduser("~")
if not home or home == "~":
    home = os.environ.get("HOME", "")
if not home:
    sys.stderr.write("ensure-claude-trust: HOME unresolved (skipping)\n")
    sys.exit(0)

path = os.path.join(home, ".claude.json")
try:
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        mode = os.stat(path).st_mode & 0o777
    else:
        data = {}
        mode = 0o600
    if not isinstance(data, dict):
        sys.stderr.write("ensure-claude-trust: ~/.claude.json is not an object (skipping)\n")
        sys.exit(0)

    projects = data.get("projects")
    if not isinstance(projects, dict):
        projects = {}
        data["projects"] = projects

    changed = False
    for target in targets:
        if not target.startswith("/"):
            sys.stderr.write("ensure-claude-trust: '%s' is not absolute (skipping)\n" % target)
            continue
        entry = projects.get(target)
        if not isinstance(entry, dict):
            entry = {}
            projects[target] = entry
        if entry.get("hasTrustDialogAccepted") is not True:
            entry["hasTrustDialogAccepted"] = True
            changed = True

    if not changed:
        sys.exit(0)  # idempotent: nothing to do, touch nothing

    # Atomic replace: temp file in the SAME dir (same filesystem) -> os.replace.
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".claude.json.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(data, out, indent=2)
            out.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
except Exception as exc:  # noqa: BLE001 — best-effort, never abort the hunt
    sys.stderr.write("ensure-claude-trust: could not update ~/.claude.json (%s); continuing\n" % exc)
    sys.exit(0)
PY
  return 0
}

# Standalone entry point: `bash ensure-claude-trust.sh <abs-dir>`. Detect direct
# execution (not sourcing) so the same file serves both the substrate wiring and
# the #993 repro command. Never returns non-zero.
_ect_self="${BASH_SOURCE:-$0}"
case "$_ect_self" in
  "$0") df_ensure_claude_trust "$@" ;;
esac
