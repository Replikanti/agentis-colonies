#!/usr/bin/env python3
"""agentarena-intake.py - AgentArena intake: fetch and unpack one task (#2326, epic #2317 M1).

The core behind dark-factory/run-agentarena-intake.sh. It consumes the notifications the webhook receiver
(#2325) dropped into $DARK_FACTORY_DIR/agentarena/inbox/<task_id>.json and, per task:

    inbox -> URL policy -> task dir + lock -> fetch details -> validate details -> chain gate
          -> fetch repo zip -> central-directory pre-scan -> extract -> manifest.json

into $DARK_FACTORY_DIR/agentarena/<task_id>/:

    manifest.json   the handoff contract (ids, numbers, hashes and enum tokens only; see docs/agentarena.md)
    .lock           flock(2) target; every stage that touches the task dir holds it
    details.json    the TaskResponse, bytes as received (0600)
    repo/           the repo root (a single shared top-level dir is stripped); dirs 0700, files 0600

HTTP goes through curl, one call per hop, never -L: curl re-sends custom -H headers on every followed
redirect, including to other hosts, so redirects are followed by hand and the X-API-Key header goes only to
allowlisted hosts. The key reaches curl on stdin (-H @-), never in argv, and is stripped from curl's env.
The archive is read with zipfile through our own validating loop, never extract()/extractall(): those
quietly rewrite hostile names instead of refusing them and enforce no caps.

Usage:
    run-agentarena-intake.sh --task <id> [--details-file F --zip-file F] [--max-files N] [--max-bytes N]
                             [--curl PATH]
    run-agentarena-intake.sh --all [--max-files N] [--max-bytes N] [--curl PATH]
    run-agentarena-intake.sh --self-test

Env:
    AGENTARENA_API_KEY     live path only: a secret:// URI (resolved in-process by tools/parse-toml-secret.py)
                           or the raw key. Never on the command line, never logged.
    AGENTARENA_API_HOSTS   comma-separated host suffixes the key may be sent to; default agentarena.nethermind.io.
    DARK_FACTORY_DIR       state root, default ~/.dark-factory.

Exit codes:
    0  unpacked, skip, or no-op (--all: always, unless a usage or secret error occurs)
    1  --self-test failed
    2  usage / config error (bad task id, key unset on the live path, bad flag combination)
    3  secret resolution failed
    4  refused (terminal policy violation)
    5  deferred (retryable: fetch failure, URL policy, lock busy)

R1/R3: the log line and the manifest carry ids, numbers, hashes and enum tokens only - never a URL (redirect
targets may be presigned), a member name, details text or the key.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import io
import ipaddress
import json
import math
import os
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from urllib.parse import urlsplit

PROG = "agentarena-intake"
SCHEMA = "agentarena-task/1"

# Same literal as TASK_ID_RE in agentarena-webhook.py (demo-agentarena-intake.sh asserts they are equal).
# Always fullmatch(): '$' would accept a trailing newline.
TASK_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")

# 50000 archive members. Measured on 29 local audit-target checkouts (several are one repo at different
# commits): `git ls-files --recurse-submodules` peaks at 12,419 files, median about 1,200, so this is 4x
# headroom. Below about 12.5k a real repo of the measured kind is refused; above, the only gain is more
# inodes a hostile archive can cost us.
MAX_FILES = 50000
# 1 GiB uncompressed total, also the download cap. The measured peak is 315 MiB of tracked bytes including
# submodules, so this is about 3x headroom. Below about 320 MiB the largest measured repo is refused; above,
# a bomb can take more of the disk the hunts share. One knob covers both because a zip holds at most its
# members' bytes plus per-entry headers (stored members are 1:1).
MAX_BYTES = 1 << 30
# 2 MiB. TaskResponse is metadata plus free-text additionalDocs/qaResponses; 2 MiB is about 1,000 pages of
# plain text. Smaller risks refusing a pasted spec; larger only grows what a hostile endpoint can make us store.
MAX_DETAILS_BYTES = 2 << 20
# 3 redirects. One hop covers a redirect to presigned storage, 3 tolerates one more canonicalizing hop, and
# anything beyond that is a loop.
MAX_HOPS = 3
# curl --max-time: 120 s for details (2 MiB at >= 17 KB/s), 1800 s for the zip (the 1 GiB cap at >= 0.6 MB/s).
# A slower intake would eat into a deadline-bounded hunt, whose default margin is 45 min (#2328).
DETAILS_MAX_TIME_S = 120
ZIP_MAX_TIME_S = 1800
# The inbox file is the receiver's canonical re-serialization of a <= 64 KiB body; ASCII escaping can grow
# it, so 1 MiB is a generous bound that still refuses a planted giant file.
MAX_INBOX_BYTES = 1 << 20
# Symlink targets are read only to decide whether they escape; PATH_MAX bounds them.
MAX_LINK_BYTES = 4096
MAX_COMPONENT_BYTES = 255
MAX_PATH_BYTES = 4096

DEFAULT_HOSTS = "agentarena.nethermind.io"
KEY_ENV = "AGENTARENA_API_KEY"
HOSTS_ENV = "AGENTARENA_API_HOSTS"
# Never handed to curl, whatever their value.
SCRUB_ENV = (KEY_ENV, "WEBHOOK_AUTH_TOKEN")

# OOS3 (#2335): only EVM tasks are hunted. A Solana/other-chain intake would add its chain here together
# with its own detection; #2335 is still open, so no switch ships.
SUPPORTED_CHAINS = ("evm",)
EVM_EXTS = (".sol", ".vy", ".yul")

TERMINAL = ("unpacked", "skip", "refused")
REDIRECT_CODES = (301, 302, 303, 307, 308)
WRITE_OUT = "%{stderr}%{http_code} %{redirect_url}\n"
SUPPORTED_COMPRESSION = (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED, zipfile.ZIP_BZIP2, zipfile.ZIP_LZMA)

EXIT_OK, EXIT_SELFTEST, EXIT_USAGE, EXIT_SECRET, EXIT_REFUSED, EXIT_DEFERRED = 0, 1, 2, 3, 4, 5

SELFTEST_CANARY = "agentarena-intake-selftest-canary-9b3e61d07a2c"
SELFTEST_KEY_ENV = "AGENTARENA_INTAKE_SELFTEST_KEY"


class ConfigError(Exception):
    """Refusal before any task state is written; .code is the process exit code."""

    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


class Outcome(Exception):
    """A per-task result raised from deep inside the pipeline: status + reason token."""

    def __init__(self, status, reason):
        super().__init__(reason)
        self.status = status
        self.reason = reason


def _utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def default_df_dir(env):
    return env.get("DARK_FACTORY_DIR") or os.path.join(os.path.expanduser("~"), ".dark-factory")


def log_line(task_id, status, reason, entries=0, nbytes=0, extra=()):
    """The only per-task log line: ids, numbers and enum tokens."""
    parts = ["%s:" % PROG, _utc(), "task_id=%s" % task_id, "status=%s" % status, "reason=%s" % (reason or "-"),
             "entries=%d" % entries, "bytes=%d" % nbytes]
    parts.extend(extra)
    sys.stderr.write(" ".join(parts) + "\n")
    sys.stderr.flush()


# ---------------- key + hosts ----------------

def _load_resolver():
    here = os.path.dirname(os.path.realpath(__file__))
    path = os.path.join(here, "..", "..", "tools", "parse-toml-secret.py")
    spec = importlib.util.spec_from_file_location("parse_toml_secret", path)
    if spec is None or spec.loader is None:
        raise ConfigError(EXIT_SECRET, "%s: secret resolver not found (tools/parse-toml-secret.py)" % KEY_ENV)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except OSError:
        raise ConfigError(EXIT_SECRET, "%s: secret resolver not loadable (tools/parse-toml-secret.py)" % KEY_ENV)
    return mod


def load_key(env):
    """Resolve AGENTARENA_API_KEY once. Raises ConfigError(2|3)."""
    value = env.get(KEY_ENV, "")
    if not value:
        raise ConfigError(EXIT_USAGE, "%s unset or empty; the live path needs it (or use --details-file/--zip-file)"
                          % KEY_ENV)
    key = value
    if value.startswith("secret://"):
        resolver = _load_resolver()
        try:
            key = resolver.resolve(value)
        except SystemExit as e:
            raise ConfigError(EXIT_SECRET, "%s: secret resolution failed (resolver exit %s)" % (KEY_ENV, e.code))
        if not key:
            raise ConfigError(EXIT_SECRET, "%s: secret resolved to an empty value" % KEY_ENV)
    # The key becomes one header line on curl's stdin; a CR/LF would smuggle a second header.
    if any(ord(c) < 32 or ord(c) == 127 for c in key):
        raise ConfigError(EXIT_USAGE, "%s contains a control character" % KEY_ENV)
    return key


def parse_hosts(env):
    raw = env.get(HOSTS_ENV) or DEFAULT_HOSTS
    hosts = []
    for h in raw.split(","):
        h = h.strip().lower().strip(".")
        if h:
            hosts.append(h)
    if not hosts:
        raise ConfigError(EXIT_USAGE, "%s has no host" % HOSTS_ENV)
    return tuple(hosts)


# ---------------- URL policy ----------------

def _url_parts(url):
    """urlsplit + the checks every hop needs: https, no userinfo, a host, no control/space chars.
    Returns the SplitResult or None."""
    if not isinstance(url, str) or not url or any(ord(c) <= 32 or ord(c) == 127 for c in url):
        return None
    try:
        parts = urlsplit(url)
        parts.port  # raises ValueError on a malformed or out-of-range port
    except ValueError:
        return None
    if parts.scheme.lower() != "https" or "@" in parts.netloc or not parts.hostname:
        return None
    return parts


def url_allowed(url, hosts):
    """The full policy: https, no userinfo, port absent or 443, not an IP literal, host == or below a suffix."""
    parts = _url_parts(url)
    if parts is None or parts.port not in (None, 443):
        return False
    host = parts.hostname.lower().rstrip(".")
    try:
        ipaddress.ip_address(host)
        return False
    except ValueError:
        pass
    return any(host == s or host.endswith("." + s) for s in hosts)


# ---------------- strict JSON ----------------

def _reject_constant(name):
    raise ValueError("non-standard JSON constant")


def _strict_float(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError("non-finite number")
    return value


def strict_json(data):
    """bytes -> object, rejecting NaN/Infinity and overflowing numbers. Raises ValueError."""
    try:
        return json.loads(data.decode("utf-8"), parse_constant=_reject_constant, parse_float=_strict_float)
    except (UnicodeDecodeError, RecursionError) as e:
        raise ValueError(str(e))


# ---------------- inbox ----------------

def read_inbox(df_dir, task_id):
    """Returns (notification, None) or (None, reason)."""
    path = os.path.join(df_dir, "agentarena", "inbox", task_id + ".json")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        return None, "inbox-missing"
    except OSError:
        return None, "inbox-invalid"
    with os.fdopen(fd, "rb") as f:
        data = f.read(MAX_INBOX_BYTES + 1)
    if len(data) > MAX_INBOX_BYTES:
        return None, "inbox-invalid"
    try:
        obj = strict_json(data)
    except ValueError:
        return None, "inbox-invalid"
    if not isinstance(obj, dict):
        return None, "inbox-invalid"
    if obj.get("task_id") != task_id:
        return None, "inbox-id-mismatch"
    if not all(isinstance(obj.get(k), str) for k in ("task_details_url", "task_repository_url")):
        return None, "inbox-invalid"
    return obj, None


# ---------------- task dir ----------------

def _fsync_dir(path):
    try:
        dfd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(dfd)
    except OSError:
        pass
    finally:
        os.close(dfd)


def read_manifest(tdir):
    try:
        with open(os.path.join(tdir, "manifest.json"), "rb") as f:
            obj = strict_json(f.read(MAX_INBOX_BYTES))
    except (OSError, ValueError):
        return {}
    return obj if isinstance(obj, dict) else {}


def write_manifest(tdir, manifest):
    """temp file -> fsync -> os.replace, under the task lock."""
    data = (json.dumps(manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
            + "\n").encode("ascii")
    fd, tmp = tempfile.mkstemp(dir=tdir, prefix=".manifest-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, os.path.join(tdir, "manifest.json"))
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise
    _fsync_dir(tdir)


def _rm(path):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISDIR(st.st_mode):
        shutil.rmtree(path, ignore_errors=True)
    else:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def clean_stale(tdir):
    """Leftovers of a crashed run (we hold the lock, so nobody else is mid-run). A repo/ without a terminal
    manifest was never recorded, so it is removed too."""
    for name in os.listdir(tdir):
        if (name.startswith(".staging-") or name.endswith(".part")
                or (name.startswith(".manifest-") and name.endswith(".tmp")) or name == "repo"):
            _rm(os.path.join(tdir, name))


# ---------------- fetch ----------------

def _child_env(env, key):
    return {k: v for k, v in env.items() if k not in SCRUB_ENV and not (key and v == key)}


def _curl_hop(ctx, url, dest, cap, max_time, header):
    """One curl call, body streamed into dest (truncated first) and capped.
    Returns ('ok'|'too-large'|'curl', code, redirect_url, curl_rc)."""
    argv = [ctx.curl, "-q", "--proto", "=https", "--max-redirs", "0", "-s", "--max-time", str(max_time),
            "-H", "@-", "-w", WRITE_OUT, url]
    with tempfile.TemporaryFile() as errf, open(dest, "wb") as out:
        try:
            p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errf,
                                 env=ctx.curl_env, close_fds=True)
        except OSError:
            return "curl", 0, "", -1
        try:
            p.stdin.write(header)
            p.stdin.close()
        except OSError:
            pass
        total = 0
        over = False
        while True:
            chunk = p.stdout.read(65536)
            if not chunk:
                break
            total += len(chunk)
            if total > cap:
                over = True
                p.kill()
                break
            out.write(chunk)
        p.stdout.close()
        rc = p.wait()
        if over:
            return "too-large", 0, "", rc
        errf.seek(0)
        lines = errf.read(16384).decode("latin-1", "replace").strip().splitlines()
    code, _, redirect = (lines[-1] if lines else "").partition(" ")
    try:
        code = int(code)
    except ValueError:
        code = 0
    if rc != 0:
        return "curl", code, "", rc
    return "ok", code, redirect.strip(), rc


def fetch(ctx, url, dest, cap, max_time):
    """Follow up to MAX_HOPS redirects by hand. The key is attached only on hops that pass the full URL policy.
    Returns None on a 2xx body in dest; raises Outcome otherwise (the caller maps too-large)."""
    hop_url = url
    for _hop in range(MAX_HOPS + 1):
        header = b""
        if url_allowed(hop_url, ctx.hosts):
            header = ("X-API-Key: %s\n" % ctx.key).encode("utf-8")
        kind, code, redirect, rc = _curl_hop(ctx, hop_url, dest, cap, max_time, header)
        if kind == "too-large":
            raise Outcome("refused", "too-large")
        if kind == "curl":
            raise Outcome("deferred", "fetch-curl-%s" % ("missing" if rc == -1 else rc))
        if 200 <= code < 300:
            return
        if code in REDIRECT_CODES and redirect:
            if _url_parts(redirect) is None:
                raise Outcome("deferred", "fetch-redirect-policy")
            hop_url = redirect
            continue
        raise Outcome("deferred", "fetch-http-%d" % code)
    raise Outcome("deferred", "fetch-too-many-redirects")


# ---------------- archive ----------------

def _bad_chars(s):
    return any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in s)


def normalize_name(raw):
    """Archive member name -> (tuple of components, None) or (None, reason)."""
    if _bad_chars(raw):
        return None, "zip-bad-name"
    name = raw.replace("\\", "/")
    if name.startswith("/") or re.match(r"[A-Za-z]:", name):
        return None, "zip-slip"
    comps = [c for c in name.split("/") if c not in ("", ".")]
    if ".." in comps:
        return None, "zip-slip"
    if not comps:
        return None, "zip-bad-name"
    if any(len(c.encode("utf-8", "surrogatepass")) > MAX_COMPONENT_BYTES for c in comps):
        return None, "zip-bad-name"
    if len("/".join(comps).encode("utf-8", "surrogatepass")) > MAX_PATH_BYTES:
        return None, "zip-bad-name"
    return tuple(comps), None


def _kind(info):
    mode = info.external_attr >> 16
    fmt = stat.S_IFMT(mode)
    if fmt == 0:
        return "dir" if info.orig_filename.endswith(("/", "\\")) else "file"
    if stat.S_ISDIR(mode):
        return "dir"
    if stat.S_ISREG(mode):
        return "dir" if info.orig_filename.endswith(("/", "\\")) else "file"
    if stat.S_ISLNK(mode):
        return "link"
    return "special"


def _link_escapes(zf, info, rel):
    """True when the symlink's target is absolute or resolves outside the (stripped) root."""
    if info.file_size > MAX_LINK_BYTES:
        return True
    with zf.open(info) as f:
        raw = f.read(MAX_LINK_BYTES + 1)
    if len(raw) > MAX_LINK_BYTES:
        return True
    try:
        target = raw.decode("utf-8")
    except UnicodeDecodeError:
        return True
    target = target.replace("\\", "/")
    if not target or _bad_chars(target) or target.startswith("/") or re.match(r"[A-Za-z]:", target):
        return True
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname("/".join(rel)), target))
    return resolved == ".." or resolved.startswith("../") or resolved.startswith("/")


def prescan(zf, max_files, max_bytes):
    """Central-directory checks before any byte is written. Returns a plan dict; raises Outcome('refused', ...)."""
    infos = zf.infolist()
    if len(infos) > max_files:
        raise Outcome("refused", "too-many-files")
    if sum(i.file_size for i in infos) > max_bytes:
        raise Outcome("refused", "too-many-bytes")
    entries = []
    seen = set()
    nondirs = set()
    dirs = set()
    for info in infos:
        if info.flag_bits & 0x1 or info.compress_type not in SUPPORTED_COMPRESSION:
            raise Outcome("refused", "zip-invalid")
        comps, why = normalize_name(info.orig_filename)
        if why:
            raise Outcome("refused", why)
        kind = _kind(info)
        if kind == "special":
            raise Outcome("refused", "zip-special-file")
        if comps in seen:
            raise Outcome("refused", "zip-duplicate")
        seen.add(comps)
        (dirs if kind == "dir" else nondirs).add(comps)
        for i in range(1, len(comps)):
            dirs.add(comps[:i])
        entries.append((info, comps, kind))
    if nondirs & dirs:
        # one path used both as a file and as a directory
        raise Outcome("refused", "zip-duplicate")
    tops = {c[0] for _, c, _ in entries}
    strip = (len(tops) == 1 and any(len(c) > 1 for _, c, _ in entries)
             and all(len(c) > 1 or k == "dir" for _, c, k in entries))
    plan = []
    for info, comps, kind in entries:
        rel = comps[1:] if strip else comps
        if not rel:
            continue
        if kind == "link" and _link_escapes(zf, info, rel):
            raise Outcome("refused", "zip-symlink-escape")
        plan.append((info, rel, kind))
    return {"entries": len(infos), "plan": plan, "strip": strip}


def extract(zf, plan, staging, max_bytes):
    """Stream every planned regular file into staging. Returns (files, bytes, symlinks_skipped)."""
    os.mkdir(staging, 0o700)
    files = nbytes = links = 0
    for info, rel, kind in plan:
        if kind == "link":
            links += 1
            continue
        path = os.path.join(staging, *rel)
        if kind == "dir":
            os.makedirs(path, mode=0o700, exist_ok=True)
            continue
        parent = os.path.dirname(path)
        if parent != staging:
            os.makedirs(parent, mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        written = 0
        with os.fdopen(fd, "wb") as out, zf.open(info) as src:
            while True:
                chunk = src.read(1 << 16)
                if not chunk:
                    break
                written += len(chunk)
                nbytes += len(chunk)
                # A lying header or an overlapping-entry bomb shows up here whatever the zipfile version.
                if written > info.file_size or nbytes > max_bytes:
                    raise Outcome("refused", "too-many-bytes")
                out.write(chunk)
        files += 1
    return files, nbytes, links


def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _is_evm_path(name):
    return name.lower().endswith(EVM_EXTS)


# ---------------- one task ----------------

class Ctx(object):
    def __init__(self, env, df_dir, curl, max_files, max_bytes):
        self.env = env
        self.df_dir = df_dir
        self.curl = curl
        self.max_files = max_files
        self.max_bytes = max_bytes
        self.hosts = None
        self.key = None
        self.curl_env = None

    def ensure_key(self):
        if self.key is None:
            self.key = load_key(self.env)
            self.curl_env = _child_env(self.env, self.key)


def _new_intake(ctx, offline, attempts):
    return {"status": "", "reason": "", "chain": "unknown",
            "details_sha256": "", "details_bytes": 0, "details_id_match": False,
            "zip_sha256": "", "zip_bytes": 0, "entries": 0, "files": 0, "bytes": 0, "symlinks_skipped": 0,
            "top_dir_stripped": False, "max_files": ctx.max_files, "max_bytes": ctx.max_bytes,
            "offline": offline, "attempts": attempts, "started_at": _utc(), "finished_at": ""}


def _read_capped(path, cap):
    """Offline hatch: the file's bytes, or None when it is over cap."""
    with open(path, "rb") as f:
        data = f.read(cap + 1)
    return None if len(data) > cap else data


def _pipeline(ctx, task_id, tdir, note, intake, details_file, zip_file, warns):
    offline = details_file is not None
    part_details = os.path.join(tdir, ".details.part")
    # d. details
    if offline:
        data = _read_capped(details_file, MAX_DETAILS_BYTES)
        if data is None:
            raise Outcome("refused", "details-too-large")
        with open(part_details, "wb") as f:
            f.write(data)
    else:
        try:
            fetch(ctx, note["task_details_url"], part_details, MAX_DETAILS_BYTES, DETAILS_MAX_TIME_S)
        except Outcome as o:
            if o.reason == "too-large":
                raise Outcome("refused", "details-too-large")
            raise
        with open(part_details, "rb") as f:
            data = f.read()
    # e. validate details
    try:
        details = strict_json(data)
    except ValueError:
        raise Outcome("refused", "details-invalid")
    if not isinstance(details, dict):
        raise Outcome("refused", "details-invalid")
    selected = details.get("selectedFiles")
    if selected is None:
        selected = []
    if not isinstance(selected, list) or not all(isinstance(s, str) for s in selected):
        raise Outcome("refused", "details-invalid")
    intake["details_sha256"] = hashlib.sha256(data).hexdigest()
    intake["details_bytes"] = len(data)
    # The docs do not say which field carries the notification id; #2331 settles it, so a mismatch warns.
    ids = [details.get(k) for k in ("id", "taskId")]
    intake["details_id_match"] = any(
        (isinstance(v, str) or (isinstance(v, int) and not isinstance(v, bool))) and str(v) == task_id for v in ids)
    if not intake["details_id_match"]:
        warns.append("warn=details-id-mismatch")
    os.replace(part_details, os.path.join(tdir, "details.json"))
    # f. chain gate on selectedFiles, before the zip is fetched
    if selected:
        if not any(_is_evm_path(s) for s in selected):
            intake["chain"] = "non-evm"
            raise Outcome("skip", "non-evm")
        intake["chain"] = "evm"
    # g. zip
    if offline:
        zpath = zip_file
        if os.path.getsize(zpath) > ctx.max_bytes:
            raise Outcome("refused", "zip-too-large")
    else:
        zpath = os.path.join(tdir, ".repo.zip.part")
        try:
            fetch(ctx, note["task_repository_url"], zpath, ctx.max_bytes, ZIP_MAX_TIME_S)
        except Outcome as o:
            if o.reason == "too-large":
                raise Outcome("refused", "zip-too-large")
            raise
    intake["zip_sha256"] = _sha256_file(zpath)
    intake["zip_bytes"] = os.path.getsize(zpath)
    # h. pre-scan, i. extract
    staging = os.path.join(tdir, ".staging-%d" % os.getpid())
    try:
        with zipfile.ZipFile(zpath) as zf:
            scan = prescan(zf, ctx.max_files, ctx.max_bytes)
            intake["entries"] = scan["entries"]
            intake["top_dir_stripped"] = scan["strip"]
            if not selected:
                if not any(k == "file" and _is_evm_path("/".join(rel)) for _, rel, k in scan["plan"]):
                    intake["chain"] = "non-evm"
                    raise Outcome("skip", "non-evm")
                intake["chain"] = "evm"
            files, nbytes, links = extract(zf, scan["plan"], staging, ctx.max_bytes)
    except Outcome:
        raise
    except FileExistsError:
        raise Outcome("refused", "zip-duplicate")
    except (zipfile.BadZipFile, zipfile.LargeZipFile, EOFError, NotImplementedError, RuntimeError, ValueError):
        raise Outcome("refused", "zip-invalid")
    except OSError:
        raise Outcome("deferred", "extract-io-error")
    except Exception:  # zlib.error, lzma.LZMAError and friends from a corrupt stream
        raise Outcome("refused", "zip-invalid")
    intake["files"], intake["bytes"], intake["symlinks_skipped"] = files, nbytes, links
    os.rename(staging, os.path.join(tdir, "repo"))
    _fsync_dir(tdir)
    raise Outcome("unpacked", "")


def process_task(ctx, task_id, details_file=None, zip_file=None):
    """Returns the per-task exit code. ConfigError propagates (key/secret problems stop a sweep)."""
    offline = details_file is not None
    # a. inbox
    note, why = read_inbox(ctx.df_dir, task_id)
    if why:
        log_line(task_id, "refused", why)
        return EXIT_REFUSED
    # b. URL policy, then the key - both before anything is written
    if not offline:
        for field in ("task_details_url", "task_repository_url"):
            if not url_allowed(note[field], ctx.hosts):
                log_line(task_id, "deferred", "url-policy", extra=("see=%s" % HOSTS_ENV,))
                return EXIT_DEFERRED
        ctx.ensure_key()
    # c. task dir + lock
    base = os.path.join(ctx.df_dir, "agentarena")
    tdir = os.path.join(base, task_id)
    for d in (base, tdir):
        os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)
    lock_fd = os.open(os.path.join(tdir, ".lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            log_line(task_id, "deferred", "lock-busy")
            return EXIT_DEFERRED
        manifest = read_manifest(tdir)
        prev = manifest.get("intake") if isinstance(manifest.get("intake"), dict) else {}
        if prev.get("status") in TERMINAL:
            log_line(task_id, "noop", "already-%s" % prev["status"], prev.get("entries", 0) or 0,
                     prev.get("bytes", 0) or 0)
            return EXIT_OK
        clean_stale(tdir)
        prev_attempts = prev.get("attempts") if isinstance(prev.get("attempts"), int) else 0
        intake = _new_intake(ctx, offline, prev_attempts + 1)
        warns = []
        try:
            _pipeline(ctx, task_id, tdir, note, intake, details_file, zip_file, warns)
        except Outcome as o:
            intake["status"], intake["reason"] = o.status, o.reason
        except OSError:
            # local I/O (disk full, permissions): retryable, and never a traceback with paths in it
            intake["status"], intake["reason"] = "deferred", "io-error"
        finally:
            for name in os.listdir(tdir):
                if name.startswith(".staging-") or name.endswith(".part"):
                    _rm(os.path.join(tdir, name))
        intake["finished_at"] = _utc()
        manifest["schema"] = SCHEMA
        manifest["task_id"] = task_id
        manifest["intake"] = intake
        write_manifest(tdir, manifest)
        log_line(task_id, intake["status"], intake["reason"], intake["entries"], intake["bytes"], warns)
        return {"unpacked": EXIT_OK, "skip": EXIT_OK, "refused": EXIT_REFUSED}.get(intake["status"], EXIT_DEFERRED)
    finally:
        os.close(lock_fd)


def sweep(ctx):
    """--all: one pass over inbox/*.json, sorted, dot-files ignored. Exit 0 unless a config error stops it."""
    inbox = os.path.join(ctx.df_dir, "agentarena", "inbox")
    try:
        names = sorted(os.listdir(inbox))
    except FileNotFoundError:
        names = []
    for name in names:
        if name.startswith(".") or not name.endswith(".json"):
            continue
        stem = name[:-len(".json")]
        if not TASK_ID_RE.fullmatch(stem):
            sys.stderr.write("%s: %s inbox file with a bad name skipped\n" % (PROG, _utc()))
            continue
        process_task(ctx, stem)
    return EXIT_OK


# ---------------- main ----------------

def _positive(text):
    try:
        v = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("not an integer")
    if v < 1:
        raise argparse.ArgumentTypeError("must be >= 1")
    return v


def main(argv=None, env=None):
    env = os.environ if env is None else env
    ap = argparse.ArgumentParser(prog="run-agentarena-intake.sh",
                                 description="AgentArena intake: fetch + unpack inbox tasks (key from env %s)."
                                             % KEY_ENV)
    ap.add_argument("--task", help="process inbox/<id>.json")
    ap.add_argument("--all", action="store_true", help="one sweep of inbox/*.json (sorted)")
    ap.add_argument("--details-file", help="offline hatch: TaskResponse JSON (with --zip-file, --task only)")
    ap.add_argument("--zip-file", help="offline hatch: repo zip (with --details-file, --task only)")
    ap.add_argument("--max-files", type=_positive, default=MAX_FILES, help="archive member cap (default %(default)s)")
    ap.add_argument("--max-bytes", type=_positive, default=MAX_BYTES,
                    help="uncompressed-total and download cap in bytes (default %(default)s)")
    ap.add_argument("--curl", default="curl", help="curl binary (default: curl on PATH)")
    ap.add_argument("--self-test", action="store_true", help="offline self-test, exit 0/1")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else EXIT_USAGE
    if args.self_test:
        return self_test()
    if bool(args.task) == bool(args.all):
        sys.stderr.write("%s: exactly one of --task <id> or --all\n" % PROG)
        return EXIT_USAGE
    if (args.details_file is None) != (args.zip_file is None):
        sys.stderr.write("%s: --details-file and --zip-file go together\n" % PROG)
        return EXIT_USAGE
    if args.details_file is not None and not args.task:
        sys.stderr.write("%s: the offline hatch needs --task\n" % PROG)
        return EXIT_USAGE
    if args.task and not TASK_ID_RE.fullmatch(args.task):
        sys.stderr.write("%s: --task is not a valid task id\n" % PROG)
        return EXIT_USAGE
    for f in (args.details_file, args.zip_file):
        if f is not None and not os.path.isfile(f):
            sys.stderr.write("%s: offline hatch file not found\n" % PROG)
            return EXIT_USAGE
    os.umask(0o077)
    ctx = Ctx(env, default_df_dir(env), args.curl, args.max_files, args.max_bytes)
    try:
        ctx.hosts = parse_hosts(env)
        if args.all:
            return sweep(ctx)
        return process_task(ctx, args.task, args.details_file, args.zip_file)
    except ConfigError as e:
        sys.stderr.write("%s: %s\n" % (PROG, e))
        return e.code


# ---------------- self-test ----------------

_STUB = r'''#!%(python)s -I
# Stub curl for agentarena-intake --self-test: serves body/status/Location from map.json, records argv, env
# (values hashed) and whether stdin carried an X-API-Key header (hashed) as JSONL. Never stores the key.
import hashlib, json, os, sys
root = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(root, "map.json")) as f:
    cfg = json.load(f)
url = sys.argv[-1]
stdin = sys.stdin.buffer.read()
rec = {"argv": sys.argv[1:], "url": url,
       "env_sha": sorted(hashlib.sha256(v.encode("utf-8", "surrogateescape")).hexdigest()
                         for v in os.environ.values()),
       "env_keys": sorted(os.environ),
       "key_header": stdin.startswith(b"X-API-Key: "),
       "stdin_sha": hashlib.sha256(stdin).hexdigest()}
with open(os.path.join(root, "calls.jsonl"), "a") as f:
    f.write(json.dumps(rec) + "\n")
r = cfg.get(url)
if r is None:
    sys.exit(6)
if r.get("exit"):
    sys.exit(r["exit"])
out = sys.stdout.buffer
try:
    if r.get("body_file"):
        with open(r["body_file"], "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                out.write(chunk)
    out.flush()
except BrokenPipeError:
    sys.exit(23)
sys.stderr.write("%%d %%s\n" %% (r.get("status", 200), r.get("location", "")))
'''


def _zip_bytes(members, flag_patch=False):
    """members: list of (name, data, mode or None). Returns zip bytes."""
    import warnings
    buf = io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            for name, data, mode in members:
                zi = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
                zi.compress_type = zipfile.ZIP_DEFLATED
                if mode is not None:
                    zi.create_system = 3
                    zi.external_attr = mode << 16
                zf.writestr(zi, data)
    raw = bytearray(buf.getvalue())
    if flag_patch:
        # Set the "encrypted" bit in every local and central header.
        for sig, off in ((b"PK\x03\x04", 6), (b"PK\x01\x02", 8)):
            i = raw.find(sig)
            while i >= 0:
                raw[i + off] |= 0x01
                i = raw.find(sig, i + 4)
    return bytes(raw)


def _snapshot(root):
    snap = {}
    for dirpath, dirs, files in os.walk(root):
        for n in dirs + files:
            p = os.path.join(dirpath, n)
            st = os.lstat(p)
            rel = os.path.relpath(p, root)
            if stat.S_ISREG(st.st_mode):
                with open(p, "rb") as f:
                    snap[rel] = ("f", hashlib.sha256(f.read()).hexdigest(), stat.S_IMODE(st.st_mode))
            elif stat.S_ISDIR(st.st_mode):
                snap[rel] = ("d", "", stat.S_IMODE(st.st_mode))
            else:
                snap[rel] = ("o", "", stat.S_IMODE(st.st_mode))
    return snap


def _changed_outside(before, after, prefix):
    """Paths that changed and are not under prefix (relative to the snapshot root)."""
    keys = set(before) | set(after)
    return sorted(k for k in keys if before.get(k) != after.get(k)
                  and not (k == prefix or k.startswith(prefix + os.sep)))


def self_test():
    report = []
    fails = []

    def check(cond, label):
        report.append("  [%s] %s" % ("PASS" if cond else "FAIL", label))
        if not cond:
            fails.append(label)

    root = tempfile.mkdtemp(prefix="agentarena-intake-selftest.")
    out_buf = io.StringIO()
    err_buf = io.StringIO()
    saved_env = dict(os.environ)
    saved_umask = os.umask(0o077)
    os.umask(saved_umask)
    try:
        world = os.path.join(root, "world")          # snapshot root: df/ + outside/ sentinel
        df = os.path.join(world, "df")
        outside = os.path.join(world, "outside")
        fx = os.path.join(root, "fixtures")
        stub_dir = os.path.join(root, "stub")
        for d in (df, outside, fx, stub_dir):
            os.makedirs(d)
        with open(os.path.join(outside, "sentinel.txt"), "w") as f:
            f.write("sentinel\n")
        inbox = os.path.join(df, "agentarena", "inbox")
        os.makedirs(inbox, mode=0o700)
        os.chmod(os.path.dirname(inbox), 0o700)  # as the receiver leaves it
        stub = os.path.join(stub_dir, "curl")
        with open(stub, "w") as f:
            f.write(_STUB % {"python": sys.executable})
        os.chmod(stub, 0o755)
        calls_path = os.path.join(stub_dir, "calls.jsonl")
        api = "https://agentarena.nethermind.io/api/tasks/"

        def set_map(m):
            with open(os.path.join(stub_dir, "map.json"), "w") as f:
                json.dump(m, f)

        def calls():
            try:
                with open(calls_path) as f:
                    return [json.loads(ln) for ln in f if ln.strip()]
            except FileNotFoundError:
                return []

        def reset_calls():
            if os.path.exists(calls_path):
                os.unlink(calls_path)

        def fixture(name, data):
            p = os.path.join(fx, name)
            with open(p, "wb") as f:
                f.write(data)
            return p

        def put_inbox(task_id, details_url=None, repo_url=None, stem=None):
            obj = {"task_id": task_id,
                   "task_details_url": details_url or api + task_id,
                   "task_repository_url": repo_url or api + task_id + "/repo",
                   "post_findings_url": api + task_id + "/findings"}
            with open(os.path.join(inbox, (stem or task_id) + ".json"), "w") as f:
                f.write(json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n")

        def details(task_id, selected=None, **extra):
            obj = {"id": task_id}
            if selected is not None:
                obj["selectedFiles"] = selected
            obj.update(extra)
            return json.dumps(obj).encode()

        def run(*argv, **kw):
            env = kw.get("env")
            if env is None:
                env = dict(os.environ)
                env["DARK_FACTORY_DIR"] = df
                env.pop(KEY_ENV, None)
            env.setdefault("DARK_FACTORY_DIR", df)
            with redirect_stderr(err_buf), redirect_stdout(out_buf):
                try:
                    return main(list(argv) + ["--curl", stub], env=env)
                finally:
                    os.umask(saved_umask)

        def manifest(task_id):
            m = read_manifest(os.path.join(df, "agentarena", task_id))
            return m.get("intake", {}) if isinstance(m, dict) else {}

        def tdir(task_id):
            return os.path.join(df, "agentarena", task_id)

        def offline(task_id, det, zbytes, *extra, **kw):
            put_inbox(task_id)
            dpath = fixture(task_id + ".details.json", det)
            zpath = fixture(task_id + ".zip", zbytes)
            before = _snapshot(world)
            rc = run("--task", task_id, "--details-file", dpath, "--zip-file", zpath, *extra)
            after = _snapshot(world)
            prefix = os.path.join("df", "agentarena", task_id)
            return rc, manifest(task_id), _changed_outside(before, after, prefix)

        def refused_clean(task_id):
            left = set(os.listdir(tdir(task_id)))
            return left <= {"manifest.json", ".lock", "details.json"}

        set_map({})
        sol = b"// SPDX-License-Identifier: MIT\npragma solidity ^0.8.0;\ncontract A {}\n"
        readme = b"# fixture\n"

        # 1. happy path via the hatch
        reset_calls()
        good_zip = _zip_bytes([("proj-abc/", b"", 0o40755), ("proj-abc/src/A.sol", sol, 0o100755),
                               ("proj-abc/README.md", readme, None)])
        rc, m, outside_changes = offline("t-happy", details("t-happy", ["src/A.sol"]), good_zip)
        repo = os.path.join(tdir("t-happy"), "repo")
        check(rc == 0 and m.get("status") == "unpacked" and m.get("reason") == "", "happy: hatch -> exit 0 unpacked")
        try:
            with open(os.path.join(repo, "src", "A.sol"), "rb") as f:
                same = f.read() == sol
            with open(os.path.join(repo, "README.md"), "rb") as f:
                same = same and f.read() == readme
        except OSError:
            same = False
        check(same, "happy: top dir stripped, contents byte-identical")
        check(m.get("top_dir_stripped") is True and m.get("files") == 2 and m.get("entries") == 3
              and m.get("bytes") == len(sol) + len(readme) and m.get("chain") == "evm" and m.get("offline") is True,
              "happy: manifest counts (entries 3, files 2, bytes), chain evm, offline")
        modes_ok = stat.S_IMODE(os.stat(repo).st_mode) == 0o700 \
            and stat.S_IMODE(os.stat(os.path.join(repo, "src")).st_mode) == 0o700 \
            and stat.S_IMODE(os.stat(os.path.join(repo, "src", "A.sol")).st_mode) == 0o600 \
            and stat.S_IMODE(os.stat(tdir("t-happy")).st_mode) == 0o700
        check(modes_ok, "happy: dirs 0700, files 0600 (the archive's exec bit is dropped)")
        check(not [n for n in os.listdir(tdir("t-happy")) if n.startswith(".staging-") or n.endswith(".part")],
              "happy: no .part or .staging-* left")
        check(m.get("details_id_match") is True and len(m.get("zip_sha256", "")) == 64
              and m.get("zip_sha256") == hashlib.sha256(good_zip).hexdigest(),
              "happy: details_id_match true, zip_sha256 recorded")
        check(outside_changes == [] and calls() == [], "happy: nothing changed outside the task dir, curl never called")
        mfile = os.path.join(tdir("t-happy"), "manifest.json")
        with open(mfile) as f:
            mtext = f.read()
        check("proj-abc" not in mtext and "A.sol" not in mtext and "https" not in mtext,
              "happy: manifest holds no file name, repo name or URL")

        # 2. zip-slip
        for i, name in enumerate(("../../outside/x.txt", "/abs/x.txt", "C:\\x.txt", "..\\x.txt",
                                  "proj/../../outside/y.txt")):
            tid = "t-slip-%d" % i
            rc, m, oc = offline(tid, details(tid, ["a.sol"]), _zip_bytes([("proj/a.sol", sol, None), (name, b"pwn", None)]))
            check(rc == 4 and m.get("status") == "refused" and m.get("reason") == "zip-slip" and oc == []
                  and not os.path.exists(os.path.join(tdir(tid), "repo")) and refused_clean(tid),
                  "zip-slip: %r -> exit 4 refused zip-slip, no repo/, nothing outside" % name)
        check(sorted(os.listdir(outside)) == ["sentinel.txt"], "zip-slip: outside/ untouched")

        # 3. symlinks
        rc, m, _ = offline("t-link-esc", details("t-link-esc", ["a.sol"]),
                           _zip_bytes([("p/a.sol", sol, None), ("p/lnk", b"../../etc/passwd", 0o120777)]))
        check(rc == 4 and m.get("reason") == "zip-symlink-escape", "symlink: escaping target -> refused zip-symlink-escape")
        rc, m, _ = offline("t-link-abs", details("t-link-abs", ["a.sol"]),
                           _zip_bytes([("p/a.sol", sol, None), ("p/lnk", b"/etc/passwd", 0o120777)]))
        check(rc == 4 and m.get("reason") == "zip-symlink-escape", "symlink: absolute target -> refused zip-symlink-escape")
        rc, m, _ = offline("t-link-in", details("t-link-in", ["a.sol"]),
                           _zip_bytes([("p/a.sol", sol, None), ("p/sub/lnk", b"../a.sol", 0o120777)]))
        lnk = os.path.join(tdir("t-link-in"), "repo", "sub", "lnk")
        check(rc == 0 and m.get("status") == "unpacked" and m.get("symlinks_skipped") == 1
              and not os.path.lexists(lnk), "symlink: in-tree link -> unpacked, symlinks_skipped=1, no link on disk")

        # 4./5. caps
        rc, m, _ = offline("t-bytes", details("t-bytes", ["a.sol"]), _zip_bytes([("a.sol", b"x" * 2048, None)]),
                           "--max-bytes", "1024")
        check(rc == 4 and m.get("reason") == "too-many-bytes" and not os.path.exists(os.path.join(tdir("t-bytes"), "repo")),
              "cap: 2048-byte member with --max-bytes 1024 -> refused too-many-bytes, nothing extracted")
        rc, m, _ = offline("t-files", details("t-files", ["a.sol"]),
                           _zip_bytes([("a.sol", sol, None), ("b", b"", None), ("c", b"", None), ("d", b"", None)]),
                           "--max-files", "3")
        check(rc == 4 and m.get("reason") == "too-many-files", "cap: 4 members with --max-files 3 -> refused too-many-files")
        # lying header: the central directory declares fewer bytes than the stream holds
        lie = bytearray(_zip_bytes([("a.sol", sol * 4, None)]))
        cd = lie.find(b"PK\x01\x02")
        lie[cd + 24:cd + 28] = (8).to_bytes(4, "little")
        rc, m, _ = offline("t-lie", details("t-lie", ["a.sol"]), bytes(lie))
        check(rc == 4 and m.get("reason") in ("too-many-bytes", "zip-invalid")
              and not os.path.exists(os.path.join(tdir("t-lie"), "repo")),
              "cap: lying uncompressed size in the central directory -> refused, no repo/")

        # 6. malformed archives
        for tid, zb, want in (
                ("t-dup", _zip_bytes([("a.sol", sol, None), ("a.sol", sol, None)]), "zip-duplicate"),
                ("t-dup2", _zip_bytes([("p/a.sol", sol, None), ("p\\a.sol", sol, None)]), "zip-duplicate"),
                ("t-dup3", _zip_bytes([("p/a", b"f", None), ("p/a/b.sol", sol, None)]), "zip-duplicate"),
                ("t-fifo", _zip_bytes([("a.sol", sol, None), ("p", b"", 0o10644)]), "zip-special-file"),
                ("t-dev", _zip_bytes([("a.sol", sol, None), ("p", b"", 0o20644)]), "zip-special-file"),
                ("t-enc", _zip_bytes([("a.sol", sol, None)], flag_patch=True), "zip-invalid"),
                ("t-garbage", b"this is not a zip archive at all" * 8, "zip-invalid"),
                ("t-ctrl", _zip_bytes([("a\x01.sol", sol, None)]), "zip-bad-name"),
                ("t-long", _zip_bytes([("a" * 256 + ".sol", sol, None)]), "zip-bad-name")):
            rc, m, oc = offline(tid, details(tid, ["a.sol"]), zb)
            check(rc == 4 and m.get("reason") == want and oc == [] and refused_clean(tid),
                  "archive: %s -> refused %s" % (tid, want))

        # 7. non-EVM
        set_map({api + "t-rust": {"status": 200, "body_file": fixture("rust.details", details(
            "t-rust", ["programs/p/src/lib.rs"]))},
            api + "t-rust/repo": {"status": 200, "body_file": fixture("rust.zip", good_zip)}})
        put_inbox("t-rust")
        os.environ[SELFTEST_KEY_ENV] = SELFTEST_CANARY
        live_env = dict(os.environ)
        live_env.update({"DARK_FACTORY_DIR": df, KEY_ENV: "secret://env/" + SELFTEST_KEY_ENV})
        reset_calls()
        rc = run("--task", "t-rust", env=dict(live_env))
        m = manifest("t-rust")
        check(rc == 0 and m.get("status") == "skip" and m.get("reason") == "non-evm" and m.get("chain") == "non-evm",
              "non-evm: selectedFiles=[lib.rs] -> exit 0 skip non-evm")
        check([c["url"] for c in calls()] == [api + "t-rust"], "non-evm: only the details URL was requested")
        rc, m, _ = offline("t-rust2", details("t-rust2", []),
                           _zip_bytes([("p/Cargo.toml", b"[package]\n", None), ("p/src/lib.rs", b"fn main(){}\n", None)]))
        check(rc == 0 and m.get("status") == "skip" and m.get("reason") == "non-evm"
              and not os.path.exists(os.path.join(tdir("t-rust2"), "repo")),
              "non-evm: empty selectedFiles + Rust-only zip -> skip non-evm, no repo/")

        # 8. live path through the stub
        cdn = "https://storage.cdn-example.test/presigned/obj?sig=abc"
        live_zip = fixture("live.zip", _zip_bytes([("r/c/T.sol", sol, None)]))
        big = fixture("big.bin", b"z" * 4096)
        set_map({api + "t-live": {"status": 200, "body_file": fixture("live.details", details("t-live", ["c/T.sol"]))},
                 api + "t-live/repo": {"status": 302, "location": cdn},
                 cdn: {"status": 200, "body_file": live_zip},
                 api + "t-big": {"status": 200, "body_file": fixture("big.details", details("t-big", ["x.sol"]))},
                 api + "t-big/repo": {"status": 200, "body_file": big},
                 api + "t-500": {"status": 500, "body_file": fixture("err.txt", b"oops")},
                 api + "t-500/repo": {"status": 200, "body_file": live_zip},
                 api + "t-loop": {"status": 302, "location": api + "t-loop"},
                 api + "t-http": {"status": 302, "location": "http://agentarena.nethermind.io/x"}})
        for t in ("t-live", "t-big", "t-500", "t-loop", "t-http"):
            put_inbox(t)
        reset_calls()
        before = _snapshot(world)
        rc = run("--task", "t-live", env=dict(live_env))
        after = _snapshot(world)
        m = manifest("t-live")
        cl = calls()
        check(rc == 0 and m.get("status") == "unpacked" and m.get("offline") is False
              and os.path.isfile(os.path.join(tdir("t-live"), "repo", "c", "T.sol")),
              "live: details 200 + zip 302 -> cdn 200 -> unpacked")
        check([c["url"] for c in cl] == [api + "t-live", api + "t-live/repo", cdn], "live: three hops in order")
        want_sha = hashlib.sha256(("X-API-Key: %s\n" % SELFTEST_CANARY).encode()).hexdigest()
        empty_sha = hashlib.sha256(b"").hexdigest()
        check([c["key_header"] for c in cl] == [True, True, False]
              and [c["stdin_sha"] for c in cl] == [want_sha, want_sha, empty_sha],
              "live: the key goes on stdin to allowlisted hops only; the cross-host hop gets none")
        bad_flags = ("-L", "--location", "-X", "--request", "-d", "--data", "--data-binary", "--data-raw",
                     "--data-urlencode", "-F", "--form", "-T", "--upload-file", "-v", "--trace", "-S")
        argv_ok = all("--proto" in c["argv"] and c["argv"][c["argv"].index("--proto") + 1] == "=https"
                      and "--max-redirs" in c["argv"] and c["argv"][c["argv"].index("--max-redirs") + 1] == "0"
                      and "@-" in c["argv"] and c["argv"][c["argv"].index("@-") - 1] == "-H"
                      and not any(a in bad_flags or a.startswith("--data") for a in c["argv"])
                      and not any(SELFTEST_CANARY in a for a in c["argv"]) for c in cl)
        check(bool(cl) and argv_ok, "live: every argv has --proto =https, --max-redirs 0, -H @-; no canary, -L, -X, -d, -F, -T")
        canary_sha = hashlib.sha256(SELFTEST_CANARY.encode()).hexdigest()
        check(all(canary_sha not in c["env_sha"] and KEY_ENV not in c["env_keys"]
                  and SELFTEST_KEY_ENV not in c["env_keys"] for c in cl),
              "live: curl's env carries neither AGENTARENA_API_KEY nor any variable holding the key")
        check(_changed_outside(before, after, os.path.join("df", "agentarena", "t-live")) == [],
              "live: nothing changed outside the task dir")
        reset_calls()
        rc = run("--task", "t-big", "--max-bytes", "1024", env=dict(live_env))
        m = manifest("t-big")
        check(rc == 4 and m.get("reason") == "zip-too-large" and refused_clean("t-big"),
              "live: a download over --max-bytes -> refused zip-too-large")
        reset_calls()
        rc = run("--task", "t-500", env=dict(live_env))
        m = manifest("t-500")
        check(rc == 5 and m.get("status") == "deferred" and m.get("reason") == "fetch-http-500" and m.get("attempts") == 1,
              "live: HTTP 500 -> exit 5 deferred fetch-http-500")
        mp = json.load(open(os.path.join(stub_dir, "map.json")))
        mp[api + "t-500"] = {"status": 200, "body_file": fixture("ok500.details", details("t-500", ["T.sol"]))}
        set_map(mp)
        rc = run("--task", "t-500", env=dict(live_env))
        m = manifest("t-500")
        check(rc == 0 and m.get("status") == "unpacked" and m.get("attempts") == 2,
              "live: the next run retries a deferred task (attempts 2, unpacked)")
        rc = run("--task", "t-loop", env=dict(live_env))
        check(rc == 5 and manifest("t-loop").get("reason") == "fetch-too-many-redirects",
              "live: a redirect loop stops after %d hops -> deferred" % MAX_HOPS)
        rc = run("--task", "t-http", env=dict(live_env))
        check(rc == 5 and manifest("t-http").get("reason") == "fetch-redirect-policy",
              "live: a redirect to http:// -> deferred fetch-redirect-policy")
        check(all("/findings" not in c["url"] for c in calls()), "live: post_findings_url is never requested")
        # redirect-hop boundary: exactly MAX_HOPS redirects are followed, one more defers
        mp = json.load(open(os.path.join(stub_dir, "map.json")))
        for t, n in (("t-hop3", MAX_HOPS), ("t-hop4", MAX_HOPS + 1)):
            mp[api + t] = {"status": 200, "body_file": fixture(t + ".details", details(t, ["c/T.sol"]))}
            hops = [api + t + "/repo"] + ["https://cdn%d.cdn-example.test/%s" % (i, t) for i in range(n)]
            for a, b in zip(hops, hops[1:]):
                mp[a] = {"status": 302, "location": b}
            mp[hops[-1]] = {"status": 200, "body_file": live_zip}
            put_inbox(t)
        set_map(mp)
        rc = run("--task", "t-hop3", env=dict(live_env))
        check(rc == 0 and manifest("t-hop3").get("status") == "unpacked",
              "live: exactly %d redirects are followed -> unpacked" % MAX_HOPS)
        rc = run("--task", "t-hop4", env=dict(live_env))
        check(rc == 5 and manifest("t-hop4").get("reason") == "fetch-too-many-redirects",
              "live: redirect %d -> deferred fetch-too-many-redirects" % (MAX_HOPS + 1))
        # a key with a control character would smuggle a second header line onto curl's stdin
        put_inbox("t-ctlkey")
        env_ctl = dict(live_env)
        env_ctl[KEY_ENV] = "abc\r\nX-Injected: 1"
        reset_calls()
        before = _snapshot(world)
        rc = run("--task", "t-ctlkey", env=env_ctl)
        check(rc == 2 and calls() == [] and _snapshot(world) == before,
              "config: a key with a control character -> exit 2, curl never called, nothing written")

        # 9. URL policy
        for i, url in enumerate(("http://agentarena.nethermind.io/d", "https://u:p@agentarena.nethermind.io/d",
                                 "https://203.0.113.7/d", "https://evil.example/d",
                                 "https://agentarena.nethermind.io:8443/d", "https://xagentarena.nethermind.io/d")):
            tid = "t-pol-%d" % i
            put_inbox(tid, details_url=url)
            reset_calls()
            before = _snapshot(world)
            rc = run("--task", tid, env=dict(live_env))
            check(rc == 5 and calls() == [] and _snapshot(world) == before,
                  "url-policy: details URL #%d -> exit 5, curl never called, nothing written" % i)
        check(all("see=%s" % HOSTS_ENV in ln for ln in err_buf.getvalue().splitlines() if "reason=url-policy " in ln)
              and "reason=url-policy " in err_buf.getvalue(), "url-policy: the log line names %s" % HOSTS_ENV)
        tid = "t-pol-host"
        put_inbox(tid, details_url="https://api.arena.example/d", repo_url="https://api.arena.example/r")
        env_h = dict(live_env)
        env_h[HOSTS_ENV] = "arena.example"
        set_map({"https://api.arena.example/d": {"status": 200, "body_file": fixture("h.details", details(tid, ["a.rs"]))}})
        reset_calls()
        rc = run("--task", tid, env=env_h)
        check(rc == 0 and [c["key_header"] for c in calls()] == [True],
              "url-policy: %s=arena.example admits a subdomain and sends it the key" % HOSTS_ENV)

        # 10. idempotency + --all
        reset_calls()
        before = _snapshot(world)
        rc = run("--task", "t-live", env=dict(live_env))
        check(rc == 0 and calls() == [] and _snapshot(world) == before,
              "idempotent: re-run after unpacked -> exit 0 no-op, curl not called, nothing changed")
        all_df = os.path.join(root, "df-all")
        all_inbox = os.path.join(all_df, "agentarena", "inbox")
        os.makedirs(all_inbox)
        for t in ("t-b", "t-a"):
            with open(os.path.join(all_inbox, t + ".json"), "w") as f:
                json.dump({"task_id": t, "task_details_url": api + t, "task_repository_url": api + t + "/repo",
                           "post_findings_url": api + t + "/f"}, f)
        with open(os.path.join(all_inbox, ".incoming-x.tmp"), "w") as f:
            f.write("{")
        set_map({api + "t-a": {"status": 200, "body_file": fixture("a.details", details("t-a", ["a.sol"]))},
                 api + "t-a/repo": {"status": 200, "body_file": live_zip},
                 api + "t-b": {"status": 200, "body_file": fixture("b.details", details("t-b", ["b.sol"]))},
                 api + "t-b/repo": {"status": 200, "body_file": live_zip}})
        reset_calls()
        env_all = dict(live_env)
        env_all["DARK_FACTORY_DIR"] = all_df
        mark = len(err_buf.getvalue())
        rc = run("--all", env=env_all)
        sweep_log = err_buf.getvalue()[mark:]
        check(rc == 0 and [c["url"] for c in calls()] == [api + "t-a", api + "t-a/repo", api + "t-b", api + "t-b/repo"]
              and sweep_log.find("task_id=t-a ") < sweep_log.find("task_id=t-b ") and "incoming" not in sweep_log,
              "--all: both inbox files processed in sorted order, dot-files ignored")

        # 11. config refusals
        put_inbox("t-cfg")
        env_unset = dict(live_env)
        env_unset.pop(KEY_ENV)
        before = _snapshot(world)
        check(run("--task", "t-cfg", env=env_unset) == 2 and _snapshot(world) == before,
              "config: live path with %s unset -> exit 2, nothing written" % KEY_ENV)
        env_bad = dict(live_env)
        env_bad[KEY_ENV] = "secret://env/AGENTARENA_INTAKE_SELFTEST_UNSET"
        os.environ.pop("AGENTARENA_INTAKE_SELFTEST_UNSET", None)
        check(run("--task", "t-cfg", env=env_bad) == 3 and _snapshot(world) == before,
              "config: secret://env/<unset> -> exit 3, nothing written")
        put_inbox("t-other", stem="t-mis")
        before = _snapshot(world)
        check(run("--task", "t-mis", env=dict(live_env)) == 4 and _snapshot(world) == before
              and not os.path.exists(tdir("t-mis")) and not os.path.exists(tdir("t-other")),
              "config: inbox task_id != file stem -> exit 4, no task dir")
        check(run("--task", "../x") == 2 and run("--all", "--task", "t-cfg") == 2
              and run("--task", "t-cfg", "--details-file", os.path.join(fx, "a.details")) == 2
              and run("--all", "--details-file", "x", "--zip-file", "y") == 2
              and run("--task", "t-cfg", "--max-files", "0") == 2,
              "usage: bad id, --all with --task, half a hatch, hatch with --all, --max-files 0 -> exit 2")
        rc, m, _ = offline("t-noid", json.dumps({"selectedFiles": ["a.sol"]}).encode(), _zip_bytes([("a.sol", sol, None)]))
        check(rc == 0 and m.get("details_id_match") is False and "task_id=t-noid status=unpacked" in err_buf.getvalue()
              and "warn=details-id-mismatch" in err_buf.getvalue(),
              "details: no id/taskId match -> details_id_match false + WARN token, not a refusal")
        rc, m, _ = offline("t-nan", b'{"id":"t-nan","x":NaN}', good_zip)
        check(rc == 4 and m.get("reason") == "details-invalid", "details: NaN -> refused details-invalid")
        rc, m, _ = offline("t-sel", json.dumps({"id": "t-sel", "selectedFiles": [1]}).encode(), good_zip)
        check(rc == 4 and m.get("reason") == "details-invalid", "details: non-string selectedFiles -> details-invalid")
        rc, m, _ = offline("t-dbig", b'{"id":"t-dbig","x":"' + b"a" * MAX_DETAILS_BYTES + b'"}', good_zip)
        check(rc == 4 and m.get("reason") == "details-too-large", "details: over 2 MiB -> refused details-too-large")

        # 12. pinned defaults
        check(MAX_FILES == 50000 and MAX_BYTES == 1 << 30 and MAX_DETAILS_BYTES == 2 << 20 and MAX_HOPS == 3,
              "defaults: MAX_FILES 50000, MAX_BYTES 1 GiB, MAX_DETAILS_BYTES 2 MiB, MAX_HOPS 3")
        check(parse_hosts({}) == ("agentarena.nethermind.io",) and SUPPORTED_CHAINS == ("evm",),
              "defaults: host allowlist agentarena.nethermind.io, chains (evm,)")
    finally:
        os.environ.clear()
        os.environ.update(saved_env)
        os.umask(saved_umask)
        shutil.rmtree(root, ignore_errors=True)

    captured = out_buf.getvalue() + err_buf.getvalue() + "\n".join(report)
    check(SELFTEST_CANARY not in captured, "log hygiene: no key canary in stdout, stderr or the report")
    check("https://" not in err_buf.getvalue() and "presigned" not in err_buf.getvalue()
          and "A.sol" not in err_buf.getvalue(), "log hygiene: no URL or member name in any log line")
    print("%s --self-test" % PROG)
    print("\n".join(report))
    if fails:
        sys.stdout.write(err_buf.getvalue()[-4000:])
        print("%s --self-test: %d FAILED" % (PROG, len(fails)))
        return EXIT_SELFTEST
    print("%s --self-test: all %d checks passed" % (PROG, len(report)))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
