#!/usr/bin/env python3
"""confidential.py - the confidential-mode switch and its helpers (#2327, epic #2317 M1).

A confidential tree is any directory that holds an entry named DF-CONFIDENTIAL, plus everything below it. The
AgentArena intake writes the marker into every task dir before any code lands; run-zone-hunt.sh --confidential
(or DF_CONFIDENTIAL=1) writes it into a hunt --out. There is no off switch: a marked tree is always
confidential. The marker is a visible file, not a dotfile, so a `cp -R dir/*` glob still copies it.
Full reference: docs/agentarena.md#confidential-mode.

Subcommands (stdlib only, Python >= 3.8):

    is-confidential <path>...
        Exit 0 when DF_CONFIDENTIAL is set to anything other than '' or '0', or when any <path> lies in a
        marked tree; exit 1 when none does; exit 2 on a usage error. Prints nothing. A path is checked from the
        realpath of its nearest existing ancestor (a leaf that does not exist yet is fine) up to /. A
        directory that cannot be inspected counts as marked, and so does any internal error (exit 3): the
        check fails closed. Bash callers go through lib/confidential.sh, never this subcommand directly.
    mark <dir>
        mkdir -p <dir> (0700) and write <dir>/DF-CONFIDENTIAL (0600) through a temp file opened with
        O_NOFOLLOW and os.replace. Idempotent; an existing marker of any type is left alone.
    alert --band <severity band> --routing <high|warn|low> --ref <path> [--count N]
        Print the only Slack payload confidential mode allows: kind, verdict, severity (the notify.sh routing
        word), severity_band (normalised to a closed vocabulary), ref (the realpath of the marked root that
        holds <path>), confidential, count when given, and a message built only from those keys. There is no
        title key and no free-text argument: a finding title names the task's contracts and functions, so it
        is a derivative of task code and does not leave the host. <path> outside a marked tree exits 2.
    snapshot <root> [--exclude <path>]...
        Print a sorted TSV `relpath type sha256 mode` of everything under <root> (type f|d|l|o; a symlink
        is hashed by its target string, a dir or special file carries `-`). Tabs, newlines and backslashes
        in a name are escaped.
    compare <a.tsv> <b.tsv>
        Print the added (+), removed (-) and changed (~) paths. Exit 0 when identical, 1 when they differ.
    --self-test
        Offline self-test; exit 0 pass, 1 fail.
"""
import sys

sys.dont_write_bytecode = True  # never leave a __pycache__/ next to the shipped helpers

import hashlib  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import stat  # noqa: E402
import tempfile  # noqa: E402

PROG = "confidential.py"
MARKER = "DF-CONFIDENTIAL"
MARKER_BODY = ("df-confidential/1\n"
               "This tree is confidential: see dark-factory/docs/agentarena.md#confidential-mode\n")
ENV = "DF_CONFIDENTIAL"
ROUTINGS = ("high", "warn", "low")
# The closed severity-band vocabulary of the alert. Anything else becomes "unknown", so the band can never
# carry free text.
BANDS = {"critical": "Critical", "high": "High", "medium": "Medium", "low": "Low",
         "info": "Informational", "informational": "Informational", "none": "None"}

EXIT_YES, EXIT_NO, EXIT_USAGE, EXIT_ERROR = 0, 1, 2, 3


class Usage(Exception):
    pass


def env_on(env=None):
    """DF_CONFIDENTIAL set to anything other than '' or '0'."""
    env = os.environ if env is None else env
    return env.get(ENV, "") not in ("", "0")


def _nearest_existing(path):
    p = os.path.abspath(path)
    while not os.path.lexists(p):
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    return os.path.realpath(p)


def _start_dir(path):
    """The realpath of the dir the walk starts in: the nearest existing ancestor, or a file's own dir."""
    p = _nearest_existing(path)
    if not os.path.isdir(p):
        p = os.path.dirname(p)
    return p


def _has_marker(d):
    """True when d holds a marker entry of any type. A dir we cannot inspect counts as marked (fail closed)."""
    try:
        os.lstat(os.path.join(d, MARKER))
        return True
    except (FileNotFoundError, NotADirectoryError):
        return False
    except OSError:
        return True


def marked_root(path):
    """The nearest ancestor of path (realpath) that holds a marker, or None."""
    d = _start_dir(path)
    while True:
        if _has_marker(d):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def is_confidential(paths, env=None):
    if env_on(env):
        return True
    return any(marked_root(p) is not None for p in paths)


def mark(d):
    """mkdir -p d (0700) and write d/DF-CONFIDENTIAL (0600) atomically. Raises OSError."""
    os.makedirs(d, mode=0o700, exist_ok=True)
    target = os.path.join(d, MARKER)
    if os.path.lexists(target):
        return target
    fd, tmp = -1, ""
    for i in range(100):
        tmp = os.path.join(d, ".%s.tmp.%d.%d" % (MARKER, os.getpid(), i))
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
                         0o600)
            break
        except FileExistsError:
            continue
    if fd < 0:
        raise OSError("cannot create a temp file in %s" % d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(MARKER_BODY)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return target


def _norm_band(band):
    b = (band or "").strip()
    if not b:
        return "unspecified"
    return BANDS.get(b.lower(), "unknown")


def alert(band, routing, ref, count=None):
    """The reduced finding-ready payload (dict). Raises Usage on a bad routing/count or an unmarked ref."""
    if routing not in ROUTINGS:
        raise Usage("--routing must be one of %s" % "|".join(ROUTINGS))
    if count is not None:
        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            raise Usage("--count must be a non-negative integer")
    root = marked_root(ref)
    if root is None:
        raise Usage("--ref is not inside a confidential tree (no %s at or above it)" % MARKER)
    sev = _norm_band(band)
    d = {"kind": "finding-ready", "verdict": "pending-human-review", "severity": routing,
         "severity_band": sev, "ref": root, "confidential": True}
    msg = "dark-factory confidential finding(s) ready for human review | severity " + sev
    if count is not None:
        d["count"] = count
        msg += " | count %d" % count
    d["message"] = msg + " | open " + root + " on the host"
    return d


def _esc(s):
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def _excluded(p, excludes):
    return any(p == e or p.startswith(e + os.sep) for e in excludes)


def snapshot(root, excludes=()):
    """Sorted rows (relpath, type, sha256, mode) for everything under root."""
    root = os.path.realpath(root)
    if not os.path.isdir(root):
        raise Usage("snapshot root is not a dir: %s" % root)
    ex = [os.path.realpath(e) for e in excludes]
    rows = []
    for dirpath, dirs, files in os.walk(root, followlinks=False):
        keep = []
        for n in dirs:
            p = os.path.join(dirpath, n)
            if _excluded(p, ex):
                continue
            keep.append(n)
        dirs[:] = keep
        for n in list(keep) + files:
            p = os.path.join(dirpath, n)
            if _excluded(p, ex):
                continue
            st = os.lstat(p)
            rel = _esc(os.path.relpath(p, root))
            mode = "%04o" % stat.S_IMODE(st.st_mode)
            if stat.S_ISLNK(st.st_mode):
                rows.append((rel, "l", hashlib.sha256(os.fsencode(os.readlink(p))).hexdigest(), mode))
            elif stat.S_ISREG(st.st_mode):
                h = hashlib.sha256()
                with open(p, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 16), b""):
                        h.update(chunk)
                rows.append((rel, "f", h.hexdigest(), mode))
            elif stat.S_ISDIR(st.st_mode):
                rows.append((rel, "d", "-", mode))
            else:
                rows.append((rel, "o", "-", mode))
    rows.sort()
    return rows


def _read_snapshot(path):
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 4:
                raise Usage("not a snapshot TSV: %s" % path)
            out[parts[0]] = tuple(parts[1:])
    return out


def compare(a, b):
    """Lines `+ path` / `- path` / `~ path`, sorted by path."""
    sa, sb = _read_snapshot(a), _read_snapshot(b)
    lines = []
    for k in sorted(set(sa) | set(sb)):
        if k not in sa:
            lines.append("+ " + k)
        elif k not in sb:
            lines.append("- " + k)
        elif sa[k] != sb[k]:
            lines.append("~ " + k)
    return lines


# ---------------- CLI ----------------

def _parse_alert(argv):
    band, routing, ref, count = None, None, None, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--band", "--routing", "--ref", "--count"):
            if i + 1 >= len(argv):
                raise Usage("%s requires a value" % a)
            v = argv[i + 1]
            if a == "--band":
                band = v
            elif a == "--routing":
                routing = v
            elif a == "--ref":
                ref = v
            else:
                if not v.isdigit():
                    raise Usage("--count must be a non-negative integer")
                count = int(v)
            i += 2
        else:
            raise Usage("unknown alert argument: %s" % a)
    if band is None or routing is None or not ref:
        raise Usage("alert needs --band, --routing and --ref")
    return band, routing, ref, count


def _usage():
    sys.stderr.write("usage: %s is-confidential <path>... | mark <dir> | alert --band B --routing high|warn|low "
                     "--ref <path> [--count N] | snapshot <root> [--exclude <path>]... | compare <a> <b> | "
                     "--self-test\n" % PROG)


def main(argv):
    if not argv:
        _usage()
        return EXIT_USAGE
    cmd, rest = argv[0], argv[1:]
    if cmd == "--self-test":
        return self_test()
    if cmd in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return EXIT_YES
    if cmd == "is-confidential":
        if not rest or any(not p for p in rest):
            return EXIT_USAGE
        return EXIT_YES if is_confidential(rest) else EXIT_NO
    try:
        if cmd == "mark":
            if len(rest) != 1 or not rest[0]:
                raise Usage("mark takes exactly one <dir>")
            try:
                mark(rest[0])
            except OSError as e:
                sys.stderr.write("%s: mark failed: %s\n" % (PROG, e.strerror or e))
                return EXIT_ERROR
            return EXIT_YES
        if cmd == "alert":
            band, routing, ref, count = _parse_alert(rest)
            sys.stdout.write(json.dumps(alert(band, routing, ref, count), sort_keys=True) + "\n")
            return EXIT_YES
        if cmd == "snapshot":
            if not rest:
                raise Usage("snapshot needs <root>")
            root, ex, i = rest[0], [], 1
            while i < len(rest):
                if rest[i] != "--exclude" or i + 1 >= len(rest):
                    raise Usage("snapshot takes <root> [--exclude <path>]...")
                ex.append(rest[i + 1])
                i += 2
            for r in snapshot(root, ex):
                sys.stdout.write("\t".join(r) + "\n")
            return EXIT_YES
        if cmd == "compare":
            if len(rest) != 2:
                raise Usage("compare takes <a.tsv> <b.tsv>")
            lines = compare(rest[0], rest[1])
            for ln in lines:
                sys.stdout.write(ln + "\n")
            return EXIT_NO if lines else EXIT_YES
    except Usage as e:
        sys.stderr.write("%s: %s\n" % (PROG, e))
        return EXIT_USAGE
    _usage()
    return EXIT_USAGE


# ---------------- self-test ----------------

def self_test():
    report, fails = [], []

    def check(cond, label):
        report.append("  [%s] %s" % ("PASS" if cond else "FAIL", label))
        if not cond:
            fails.append(label)

    import io
    import shutil
    from contextlib import redirect_stderr, redirect_stdout

    def run(*argv, **kw):
        env = kw.get("env", {})
        saved = os.environ.get(ENV)
        if ENV in env:
            os.environ[ENV] = env[ENV]
        else:
            os.environ.pop(ENV, None)
        out, err = io.StringIO(), io.StringIO()
        try:
            with redirect_stdout(out), redirect_stderr(err):
                rc = main(list(argv))
        finally:
            if saved is None:
                os.environ.pop(ENV, None)
            else:
                os.environ[ENV] = saved
        return rc, out.getvalue(), err.getvalue()

    root = os.path.realpath(tempfile.mkdtemp(prefix="confidential-selftest."))
    try:
        task = os.path.join(root, "df", "agentarena", "t1")
        os.makedirs(os.path.join(task, "repo", "src"))
        with open(os.path.join(task, MARKER), "w") as f:
            f.write(MARKER_BODY)
        plain = os.path.join(root, "plain", "deep")
        os.makedirs(plain)
        with open(os.path.join(task, "repo", "src", "A.sol"), "w") as f:
            f.write("contract A {}\n")
        os.symlink(os.path.join(task, "repo"), os.path.join(root, "plain", "link-to-repo"))

        # walk-up
        rc, out, err = run("is-confidential", os.path.join(task, "repo", "src"))
        check(rc == 0 and out == "" and err == "", "walk-up: nested dir under a marker -> 0, prints nothing")
        rc, _, _ = run("is-confidential", os.path.join(task, "repo", "src", "A.sol"))
        check(rc == 0, "walk-up: a file path -> 0")
        rc, _, _ = run("is-confidential", os.path.join(task, "hunt", "not", "yet"))
        check(rc == 0, "walk-up: a leaf that does not exist yet -> 0 (nearest existing ancestor)")
        rc, _, _ = run("is-confidential", os.path.join(root, "plain", "link-to-repo", "src"))
        check(rc == 0, "walk-up: a symlinked component resolves to the marked tree -> 0")
        rc, out, _ = run("is-confidential", plain)
        check(rc == 1 and out == "", "walk-up: no marker anywhere -> 1")
        rc, _, _ = run("is-confidential", plain, os.path.join(task, "repo"))
        check(rc == 0, "walk-up: any one marked path -> 0")
        rc, _, _ = run("is-confidential")
        check(rc == 2, "usage: no path -> 2")
        os.mkdir(os.path.join(root, "plain", "dirmark"))
        os.mkdir(os.path.join(root, "plain", "dirmark", MARKER))
        os.symlink("/nonexistent-target", os.path.join(root, "plain", "deep", MARKER))
        rc1, _, _ = run("is-confidential", os.path.join(root, "plain", "dirmark"))
        rc2, _, _ = run("is-confidential", plain)
        check(rc1 == 0 and rc2 == 0, "walk-up: a marker of any type (a dir, a dangling symlink) counts")
        os.unlink(os.path.join(plain, MARKER))

        # DF_CONFIDENTIAL values
        for v, want in (("1", 0), ("yes", 0), ("0", 1), ("", 1)):
            rc, _, _ = run("is-confidential", plain, env={ENV: v})
            check(rc == want, "env: DF_CONFIDENTIAL=%r -> %d" % (v, want))

        # mark
        m = os.path.join(root, "out", "hunt")
        rc, _, _ = run("mark", m)
        mp = os.path.join(m, MARKER)
        st1 = os.lstat(mp) if os.path.lexists(mp) else None
        check(rc == 0 and st1 is not None and stat.S_ISREG(st1.st_mode) and stat.S_IMODE(st1.st_mode) == 0o600
              and stat.S_IMODE(os.stat(m).st_mode) == 0o700, "mark: creates the dir (0700) and the marker (0600)")
        with open(mp) as f:
            check(f.read() == MARKER_BODY, "mark: body is df-confidential/1 + the docs pointer")
        rc, _, _ = run("mark", m)
        st2 = os.lstat(mp)
        check(rc == 0 and st2.st_ino == st1.st_ino and sorted(os.listdir(m)) == [MARKER],
              "mark: idempotent (same file, no temp left)")
        nf = os.path.join(root, "nofollow")
        os.mkdir(nf)
        os.symlink(os.path.join(root, "victim"), os.path.join(nf, MARKER))
        rc, _, _ = run("mark", nf)
        check(rc == 0 and os.path.islink(os.path.join(nf, MARKER)) and not os.path.exists(os.path.join(root, "victim")),
              "mark: an existing marker symlink is never followed or written through")
        rc, _, _ = run("mark")
        check(rc == 2, "mark: no dir -> 2")

        # alert
        rc, out, _ = run("alert", "--band", "High", "--routing", "high", "--ref", os.path.join(task, "repo"),
                         "--count", "3")
        try:
            a = json.loads(out)
        except ValueError:
            a = {}
        check(rc == 0 and set(a) == {"kind", "verdict", "severity", "severity_band", "ref", "confidential", "count",
                                     "message"}, "alert: exactly the allowed keys (with --count)")
        check("title" not in a and a.get("ref") == task and a.get("severity") == "high"
              and a.get("severity_band") == "High" and a.get("count") == 3 and a.get("confidential") is True,
              "alert: no title key; ref resolves to the marked root; routing + band + count")
        rc, out, _ = run("alert", "--band", "Medium", "--routing", "warn", "--ref", task)
        a = json.loads(out) if rc == 0 else {}
        check(rc == 0 and "count" not in a and "Medium" in a.get("message", ""), "alert: no --count -> no count key")
        rc, out, _ = run("alert", "--band", "Vault.deposit drains shares", "--routing", "low", "--ref", task)
        check(rc == 0 and "Vault" not in out and json.loads(out).get("severity_band") == "unknown",
              "alert: a free-text band never reaches the payload")
        rc, out, _ = run("alert", "--band", "High", "--routing", "high", "--ref", plain)
        check(rc == 2 and out == "", "alert: an unmarked --ref -> 2, nothing printed")
        rc, _, _ = run("alert", "--band", "High", "--routing", "page", "--ref", task)
        check(rc == 2, "alert: an unknown routing -> 2")
        rc, _, _ = run("alert", "--band", "High", "--routing", "high", "--ref", task, "--title", "x")
        check(rc == 2, "alert: there is no --title argument")

        # snapshot / compare
        sroot = os.path.join(root, "snap")
        os.makedirs(os.path.join(sroot, "a", "b"))
        os.makedirs(os.path.join(sroot, "skip"))
        with open(os.path.join(sroot, "a", "f.txt"), "w") as f:
            f.write("one\n")
        with open(os.path.join(sroot, "a", "tab\tname"), "w") as f:
            f.write("t\n")
        os.symlink("a/f.txt", os.path.join(sroot, "ln"))
        s1, s2 = os.path.join(root, "s1.tsv"), os.path.join(root, "s2.tsv")

        def snap_to(path, *extra):
            rc, out, _ = run("snapshot", sroot, *extra)
            with open(path, "w") as f:
                f.write(out)
            return rc, out

        rc, out = snap_to(s1, "--exclude", os.path.join(sroot, "skip"))
        rows = [ln.split("\t") for ln in out.splitlines()]
        check(rc == 0 and all(len(r) == 4 for r in rows) and [r[0] for r in rows] == sorted(r[0] for r in rows)
              and "skip" not in [r[0] for r in rows] and "a/tab\\tname" in [r[0] for r in rows],
              "snapshot: sorted 4-column TSV, --exclude honoured, a tab in a name escaped")
        check(any(r[0] == "ln" and r[1] == "l" for r in rows), "snapshot: a symlink is typed l (hash of its target)")
        rc, out = snap_to(s2, "--exclude", os.path.join(sroot, "skip"))
        rc, out, _ = run("compare", s1, s2)
        check(rc == 0 and out == "", "compare: identical -> 0, nothing printed")
        with open(os.path.join(sroot, "skip", "ignored"), "w") as f:
            f.write("x\n")
        with open(os.path.join(sroot, "a", "new"), "w") as f:
            f.write("n\n")
        os.unlink(os.path.join(sroot, "a", "tab\tname"))
        with open(os.path.join(sroot, "a", "f.txt"), "w") as f:
            f.write("two\n")
        os.chmod(os.path.join(sroot, "a", "b"), 0o700)
        os.chmod(os.path.join(sroot, "a", "b"), 0o711)
        snap_to(s2, "--exclude", os.path.join(sroot, "skip"))
        rc, out, _ = run("compare", s1, s2)
        lines = out.splitlines()
        check(rc == 1 and "+ a/new" in lines and "- a/tab\\tname" in lines and "~ a/f.txt" in lines
              and "~ a/b" in lines and not any("skip" in ln for ln in lines),
              "compare: add, remove, modify and mode change listed; the excluded dir is not")
        rc, _, _ = run("compare", s1)
        check(rc == 2, "compare: one file -> 2")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    sys.stdout.write("%s --self-test\n%s\n" % (PROG, "\n".join(report)))
    if fails:
        sys.stdout.write("%s --self-test: FAIL (%d)\n" % (PROG, len(fails)))
        return 1
    sys.stdout.write("%s --self-test: PASS (%d checks)\n" % (PROG, len(report)))
    return 0


if __name__ == "__main__":
    try:
        rc = main(sys.argv[1:])
    except SystemExit:
        raise
    except BaseException as e:  # fail closed: never the "not confidential" code on an internal error
        try:
            sys.stderr.write("%s: internal error: %s\n" % (PROG, type(e).__name__))
        except BaseException:
            pass
        rc = EXIT_ERROR
    sys.exit(rc)
