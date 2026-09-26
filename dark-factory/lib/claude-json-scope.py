#!/usr/bin/env python3
# dark-factory/lib/claude-json-scope.py — the #2262 M3 scoped ~/.claude.json for the hunt sandbox
# (lib/claude-sandboxed.sh). python3 stdlib only, no network, never writes bytecode.
#
# WHY. Claude Code keeps ONE workspace store, ~/.claude.json, with a `projects` map keyed by cwd. The sandbox must
# expose it (the per-cwd workspace-trust flag lives there — without it an interactive session blocks on the trust
# dialog, see lib/ensure-claude-trust.sh), but every OTHER cwd's entry carries that session's
# `lastSessionFirstPrompt` and friends: the operator's own sessions and every other hunt cell, readable by a hunter
# cell that goes looking. So the sandbox gets a filtered COPY instead of the real file: `projects` reduced to the
# session's own cwd entries, and every other HOST-PATH MAP dropped — `githubRepoPaths` (repo -> local checkout
# paths) and any other top-level object keyed by absolute paths — since they name other checkouts on the host
# (held-out bases included). Every other top-level key (account, settings, feature flags) is kept as is. What the session writes into its own entry is merged back
# into the real file after the session ends; nothing else it writes there is.
#
# Subcommands:
#   filter <real> <dir> <cwd>...
#       Write <dir>/claude.json (mode 0600) = <real> with `projects` reduced to the <cwd> keys it holds and the
#       host-path maps dropped (HOST_PATH_KEYS + any top-level object whose keys are all absolute paths), and
#       <dir>/own.json = those entries as they were (the merge compares against it). Exit 0; 3 when <real> is not
#       a readable JSON object (retried briefly: a writer may be mid-replace) — the wrapper then binds NOTHING.
#   merge <dir> <real> <cwd>...
#       Merge the <cwd> entries of <dir>/claude.json back into <real>: only an entry the session CHANGED (vs
#       own.json) is written, on a freshly re-read <real>, under an exclusive flock of <real>'s directory (between
#       mergers), replaced atomically, and only when <real> did not change between the read and the replace
#       (re-read + retry otherwise). An unchanged session writes nothing. Then <dir> is removed. Exit 0 always.
#   watch-merge <pid> <dir> <real> <cwd>...
#       Detach (setsid: flat-cyborg ends a session by SIGKILLing its whole process group, so no exit hook of the
#       wrapper itself would ever run), wait until <pid> (the wrapper, which exec's bwrap under the same pid) is
#       gone or a zombie, then `merge`.
import fcntl
import json
import os
import shutil
import sys
import tempfile
import time

sys.dont_write_bytecode = True


def die(rc, msg):
    sys.stderr.write("claude-json-scope.py: " + msg + "\n")
    sys.exit(rc)


def read_json(path, tries=5):
    last = None
    for _ in range(tries):
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, dict):
                return data
            last = "not a JSON object"
        except (OSError, ValueError) as exc:
            last = str(exc)
        time.sleep(0.2)
    raise ValueError(last or "unreadable")


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


# Top-level keys that map to host paths regardless of their key shape (githubRepoPaths: "owner/repo" -> [paths]).
HOST_PATH_KEYS = ("githubRepoPaths",)


def _host_path_map(key, val):
    if key in HOST_PATH_KEYS:
        return True
    return isinstance(val, dict) and bool(val) and all(isinstance(k, str) and k.startswith("/") for k in val)


def cmd_filter(argv):
    if len(argv) < 3:
        die(2, "usage: filter <real> <dir> <cwd>...")
    real, d, cwds = argv[0], argv[1], argv[2:]
    try:
        data = read_json(real)
    except ValueError as exc:
        die(3, "cannot read %s: %s" % (real, exc))
    projects = data.get("projects")
    projects = projects if isinstance(projects, dict) else {}
    own = dict((k, projects[k]) for k in cwds if k in projects)
    scoped = dict((k, v) for k, v in data.items() if k == "projects" or not _host_path_map(k, v))
    scoped["projects"] = dict(own)
    write_private(os.path.join(d, "own.json"), own)
    write_private(os.path.join(d, "claude.json"), scoped)
    return 0


def _stat_key(path):
    st = os.stat(path)
    return (st.st_ino, st.st_size, st.st_mtime_ns)


def merge(d, real, cwds):
    try:
        try:
            scoped = read_json(os.path.join(d, "claude.json"), tries=2)
            with open(os.path.join(d, "own.json"), encoding="utf-8") as fh:
                orig = json.load(fh)
        except (OSError, ValueError):
            return
        sp = scoped.get("projects") if isinstance(scoped.get("projects"), dict) else {}
        changed = dict((k, sp[k]) for k in cwds if k in sp and sp[k] != orig.get(k))
        if not changed or not os.path.exists(real):
            return
        lock = os.open(os.path.dirname(os.path.abspath(real)) or ".", os.O_RDONLY)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
            for _ in range(10):
                try:
                    before = _stat_key(real)
                    data = read_json(real, tries=3)
                    mode = os.stat(real).st_mode & 0o777
                except (OSError, ValueError):
                    return
                projects = data.get("projects")
                if not isinstance(projects, dict):
                    projects = {}
                    data["projects"] = projects
                projects.update(changed)
                fd, tmp = tempfile.mkstemp(prefix=".claude.json.", dir=os.path.dirname(os.path.abspath(real)))
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as fh:
                        json.dump(data, fh, indent=2, ensure_ascii=False)
                        fh.write("\n")
                    os.chmod(tmp, mode)
                    if _stat_key(real) != before:
                        os.unlink(tmp)       # someone replaced it meanwhile: re-read, never clobber
                        time.sleep(0.1)
                        continue
                    os.replace(tmp, real)
                    return
                except BaseException:
                    if os.path.exists(tmp):
                        os.unlink(tmp)
                    raise
        finally:
            os.close(lock)
    except Exception as exc:  # noqa: BLE001 — best effort: never leave a traceback on the hunt's stderr
        sys.stderr.write("claude-json-scope.py: merge skipped (%s)\n" % exc)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def cmd_merge(argv):
    if len(argv) < 3:
        die(2, "usage: merge <dir> <real> <cwd>...")
    merge(argv[0], argv[1], argv[2:])
    return 0


def _proc_state(pid):
    """-> (state char, start time) of <pid>, or None when it is gone."""
    try:
        with open("/proc/%d/stat" % pid) as fh:
            rest = fh.read().rsplit(")", 1)[1].split()
        return rest[0], rest[19]
    except (OSError, IndexError):
        return None


def cmd_watch_merge(argv):
    if len(argv) < 4 or not argv[0].isdigit():
        die(2, "usage: watch-merge <pid> <dir> <real> <cwd>...")
    pid, d, real, cwds = int(argv[0]), argv[1], argv[2], argv[3:]
    try:
        os.setsid()
    except OSError:
        pass
    first = _proc_state(pid)
    if first is not None:
        while True:
            now = _proc_state(pid)
            if now is None or now[0] in ("Z", "X") or now[1] != first[1]:
                break
            time.sleep(0.2)
    else:
        # no /proc (not Linux): poll with signal 0
        while True:
            try:
                os.kill(pid, 0)
            except OSError:
                break
            time.sleep(0.2)
    merge(d, real, cwds)
    return 0


COMMANDS = {"filter": cmd_filter, "merge": cmd_merge, "watch-merge": cmd_watch_merge}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        die(2, "usage: claude-json-scope.py <filter|merge|watch-merge> ...")
    return COMMANDS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
