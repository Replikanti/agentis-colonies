#!/usr/bin/env python3
"""agentarena-webhook.py - AgentArena task-notification receiver (#2325, epic #2317 M1).

The shadow intake's front door. AgentArena POSTs one notification per task:

    POST /webhook
    Authorization: token <WEBHOOK_AUTH_TOKEN>
    {"task_id": ..., "task_repository_url": ..., "task_details_url": ..., "post_findings_url": ...}

The receiver authenticates, bounds and validates the notification, drops it
atomically into $DARK_FACTORY_DIR/agentarena/inbox/<task_id>.json and answers
202 {"status":"accepted"}. That is all it does: it fetches nothing, starts no
subprocess and opens no outbound connection. Consuming the inbox (fetch,
unpack, hunt) is the intake's job (#2326).

Usage:
    WEBHOOK_AUTH_TOKEN=secret://libsecret/agentarena/webhook \\
        dark-factory/agentarena-webhook.py [--bind 127.0.0.1] [--port 8421] [--port-file PATH]
    dark-factory/agentarena-webhook.py --self-test

Env:
    WEBHOOK_AUTH_TOKEN  required. A secret:// URI (resolved in-process by
                        tools/parse-toml-secret.py) or the raw token. Never
                        passed on the command line.
    DARK_FACTORY_DIR    state root, default ~/.dark-factory.

Exit codes:
    0  clean shutdown (SIGTERM / SIGINT), or --self-test passed
    1  --self-test failed
    2  usage / config error (token unset, refused bind address)
    3  token resolution failed (secret:// backend error)
    4  bind failed

Responses (every response closes the connection; bodies are fixed JSON, never
an echo of request data):

    202 accepted         new notification written to the inbox
    202 duplicate        <task_id>.json already exists; the first file wins
    400 bad-request      bad Content-Length, short body, invalid JSON, missing/non-string *_url
    400 bad-task-id      task_id is not 1-128 chars of [A-Za-z0-9_-] with an alphanumeric first char
    401 unauthorized     missing, wrong or repeated Authorization header (checked before the body is read)
    404 not-found        any path other than exactly /webhook
    405 method-not-allowed  /webhook with a method other than POST (Allow: POST)
    411 length-required  Transfer-Encoding present or Content-Length missing
    413 too-large        declared Content-Length above 65536 (the body is never read)
    500 write-failed     the inbox write failed
    503 busy             more than 16 requests in flight

R1/R3: the receiver only ever handles notification metadata, never task code,
and writes nothing outside $DARK_FACTORY_DIR/agentarena/inbox/. It touches no
Slack, memo or export sink. The token is never in argv, in a log line or in a
response.
"""
import argparse
import hmac
import importlib.util
import io
import ipaddress
import json
import os
import re
import signal
import socket
import stat
import sys
import tempfile
import threading
import time
from contextlib import redirect_stderr
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 64 KiB: the notification is four short strings (well under 1 KB); this leaves
# room for fields the platform may add while bounding memory and file size per
# request. ~4 KiB would risk rejecting a grown payload; more only enlarges what
# a token holder can write.
MAX_BODY = 65536
# 5 s: a legitimate sender pushes < 1 KB in one segment; this bounds how long a
# stalled or slow-drip client pins a handler thread. Below ~1 s it can cut a
# slow tunnel leg; much higher lets idle connections pin the in-flight cap.
SOCKET_TIMEOUT_S = 5
# 16: legitimate concurrency is ~1 (one notification per task); 16 bounds
# threads x 64 KiB buffers (~1 MiB) on a host that also runs hunts. At 1-2 one
# stalled client could 503 a real notification; unbounded, a flood spawns
# threads without limit.
MAX_INFLIGHT = 16
# 8421: unprivileged and distinct from the dashboards' 8420; any free port works.
DEFAULT_PORT = 8421
DEFAULT_BIND = "127.0.0.1"
WEBHOOK_PATH = "/webhook"
URL_FIELDS = ("task_repository_url", "task_details_url", "post_findings_url")
# 1-128 chars, alphanumeric first: covers UUIDs (36), 24-hex ObjectIds,
# cuid/nanoid ids and integers; excludes '.', '/', '\\', NUL and whitespace
# (traversal), a leading '-' (option injection once #2326 hands the id to
# shell tools) and a leading '.' (hidden files, '..'). 128 + ".json" stays far
# below NAME_MAX (255); a limit under 36 would reject UUIDs.
# Always fullmatch(): '$' would accept a trailing newline.
TASK_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")
CONTENT_LENGTH_RE = re.compile(r"[0-9]{1,20}")

TOKEN_ENV = "WEBHOOK_AUTH_TOKEN"
SELFTEST_CANARY = "agentarena-selftest-canary-5f1d8c27e04b"
SELFTEST_TOKEN_ENV = "AGENTARENA_WEBHOOK_SELFTEST_TOKEN"

PROG = "agentarena-webhook"
_BUSY_RESPONSE = (b"HTTP/1.0 503 Service Unavailable\r\n"
                  b"Content-Length: 0\r\nConnection: close\r\n\r\n")


class ConfigError(Exception):
    """Startup refusal; .code is the process exit code."""

    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


# ---------------- startup: token + bind ----------------

def _load_resolver():
    here = os.path.dirname(os.path.realpath(__file__))
    path = os.path.join(here, "..", "tools", "parse-toml-secret.py")
    spec = importlib.util.spec_from_file_location("parse_toml_secret", path)
    if spec is None or spec.loader is None:
        raise ConfigError(3, "%s: secret resolver not found (tools/parse-toml-secret.py)" % TOKEN_ENV)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except OSError:
        raise ConfigError(3, "%s: secret resolver not loadable (tools/parse-toml-secret.py)" % TOKEN_ENV)
    return mod


def load_token(env=None):
    """Resolve WEBHOOK_AUTH_TOKEN once. Raises ConfigError(2|3)."""
    env = os.environ if env is None else env
    value = env.get(TOKEN_ENV, "")
    if not value:
        # An open receiver would let anyone queue URLs the intake later
        # fetches with the platform's X-API-Key.
        raise ConfigError(2, "%s unset or empty; refusing to run unauthenticated" % TOKEN_ENV)
    if not value.startswith("secret://"):
        return value
    resolver = _load_resolver()
    try:
        token = resolver.resolve(value)
    except SystemExit as e:
        raise ConfigError(3, "%s: secret resolution failed (resolver exit %s)" % (TOKEN_ENV, e.code))
    if not token:
        raise ConfigError(3, "%s: secret resolved to an empty value" % TOKEN_ENV)
    return token


def check_bind(addr, allow_non_loopback):
    """Validate --bind. Returns the ip_address. Raises ConfigError(2)."""
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        raise ConfigError(2, "--bind must be an IP literal (got a hostname or garbage)")
    if not ip.is_loopback and not allow_non_loopback:
        raise ConfigError(2, "--bind %s is not loopback: plain HTTP on a public interface sends the token "
                             "in cleartext; terminate TLS in front and forward to a loopback listener "
                             "(--allow-non-loopback only for a TLS-terminating front on this host/container)"
                          % ip)
    return ip


# ---------------- inbox ----------------

def inbox_dir(df_dir):
    return os.path.join(df_dir, "agentarena", "inbox")


def default_df_dir():
    return os.environ.get("DARK_FACTORY_DIR") or os.path.join(os.path.expanduser("~"), ".dark-factory")


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n"


def write_inbox(df_dir, task_id, obj):
    """Atomically create inbox/<task_id>.json. Returns 'accepted' or 'duplicate'.

    tmp file (mode 0600) -> fsync -> link() to the final name: atomic and never
    overwrites, so an existing file means a duplicate and stays untouched.
    """
    base = os.path.join(df_dir, "agentarena")
    inbox = inbox_dir(df_dir)
    for d in (base, inbox):
        os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)
    data = canonical(obj).encode("ascii")
    fd, tmp = tempfile.mkstemp(dir=inbox, prefix=".incoming-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        try:
            os.link(tmp, os.path.join(inbox, task_id + ".json"))
            outcome = "accepted"
        except FileExistsError:
            outcome = "duplicate"
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
    try:
        dfd = os.open(inbox, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass
    return outcome


# ---------------- logging ----------------

def _id_shape(value):
    """Describe a rejected task_id without its value: type, length, char classes."""
    if not isinstance(value, str):
        return "type=%s" % type(value).__name__
    classes = []
    for name, pred in (("alnum", lambda c: c.isascii() and c.isalnum()),
                       ("underscore", lambda c: c == "_"),
                       ("dash", lambda c: c == "-"),
                       ("dot", lambda c: c == "."),
                       ("slash", lambda c: c == "/"),
                       ("backslash", lambda c: c == "\\"),
                       ("colon", lambda c: c == ":"),
                       ("space", lambda c: c == " "),
                       ("control", lambda c: ord(c) < 32 or ord(c) == 127),
                       ("non-ascii", lambda c: ord(c) > 127)):
        if any(pred(c) for c in value):
            classes.append(name)
    known = set("_-./\\: ")
    if any(c.isascii() and not c.isalnum() and c not in known and 32 <= ord(c) < 127 for c in value):
        classes.append("other")
    return "len=%d classes=%s" % (len(value), ",".join(classes) or "none")


def _emit(server, status, outcome, task_id=None, nbytes=0, detail=None):
    """The only log line: fixed tokens, the validated task_id and integers."""
    parts = ["%s:" % PROG, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
             "status=%d" % status, "outcome=%s" % outcome]
    if task_id is not None:
        parts.append("task_id=%s" % task_id)
    if nbytes:
        parts.append("bytes=%d" % nbytes)
    if detail:
        parts.append(detail)
    line = " ".join(parts) + "\n"
    with server.log_lock:
        try:
            server.log_stream.write(line)
            server.log_stream.flush()
        except (OSError, ValueError):
            pass


# ---------------- server ----------------

class WebhookServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, token, df_dir, log_stream=None, max_inflight=MAX_INFLIGHT):
        self.token_header = b"token " + token.encode("utf-8")
        self.df_dir = df_dir
        self.log_stream = sys.stderr if log_stream is None else log_stream
        self.log_lock = threading.Lock()
        self.slots = threading.BoundedSemaphore(max_inflight)
        super().__init__(addr, WebhookHandler)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.sendall(_BUSY_RESPONSE)
            except OSError:
                pass
            self.shutdown_request(request)
            _emit(self, 503, "busy")
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


class WebhookServer6(WebhookServer):
    address_family = socket.AF_INET6


class WebhookHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    timeout = SOCKET_TIMEOUT_S
    server_version = PROG
    sys_version = ""

    def version_string(self):
        return self.server_version

    def log_message(self, format, *args):  # noqa: A002 - base-class signature
        # No default access log: it would echo the request line verbatim.
        pass

    def send_error(self, code, message=None, explain=None):
        # The base class calls this for malformed request lines/headers and
        # unknown methods; its default HTML body echoes request data.
        self._respond(code, {"error": "malformed"})
        _emit(self.server, code, "malformed")

    def _respond(self, status, obj, extra=()):
        body = json.dumps(obj, separators=(",", ":")).encode("ascii")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        except OSError:
            pass
        self.close_connection = True

    def _reject(self, status, outcome, **kw):
        self._respond(status, {"error": outcome})
        _emit(self.server, status, outcome, **kw)

    def _not_post(self):
        if self.path != WEBHOOK_PATH:
            self._reject(404, "not-found")
        else:
            self._respond(405, {"error": "method-not-allowed"}, extra=(("Allow", "POST"),))
            _emit(self.server, 405, "method-not-allowed")

    do_GET = do_HEAD = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _not_post

    def do_POST(self):
        # 1. exact path, query string included
        if self.path != WEBHOOK_PATH:
            return self._reject(404, "not-found")
        # 2. exactly one Authorization header, constant-time compare, before any body byte
        auth = self.headers.get_all("Authorization") or []
        if len(auth) != 1 or not hmac.compare_digest(auth[0].encode("latin-1"), self.server.token_header):
            return self._reject(401, "unauthorized")
        # 3. declared length
        if self.headers.get_all("Transfer-Encoding"):
            return self._reject(411, "length-required")
        cl = self.headers.get_all("Content-Length")
        if not cl:
            return self._reject(411, "length-required")
        if len(cl) != 1 or not CONTENT_LENGTH_RE.fullmatch(cl[0].strip()):
            return self._reject(400, "bad-request")
        length = int(cl[0].strip())
        if length > MAX_BODY:
            return self._reject(413, "too-large", nbytes=length)
        # 4. exactly Content-Length bytes
        try:
            body = self.rfile.read(length)
        except OSError:
            return self._reject(400, "bad-request")
        if len(body) != length:
            return self._reject(400, "bad-request", nbytes=len(body))
        # 5. a JSON object with string *_url fields (URL policy belongs to #2326)
        try:
            obj = json.loads(body.decode("utf-8"), parse_constant=_reject_constant)
        except (ValueError, RecursionError):
            return self._reject(400, "bad-request", nbytes=length)
        if not isinstance(obj, dict) or not all(isinstance(obj.get(k), str) for k in URL_FIELDS):
            return self._reject(400, "bad-request", nbytes=length)
        # 6. task_id shape
        task_id = obj.get("task_id")
        if not isinstance(task_id, str) or not TASK_ID_RE.fullmatch(task_id):
            return self._reject(400, "bad-task-id", nbytes=length, detail=_id_shape(task_id))
        # 7. atomic drop
        try:
            outcome = write_inbox(self.server.df_dir, task_id, obj)
        except (OSError, ValueError):
            return self._reject(500, "write-failed", task_id=task_id, nbytes=length)
        self._respond(202, {"status": "accepted"})
        _emit(self.server, 202, outcome, task_id=task_id, nbytes=length)


def _reject_constant(name):
    raise ValueError("non-standard JSON constant")


def make_server(ip, port, token, df_dir, log_stream=None, max_inflight=MAX_INFLIGHT):
    cls = WebhookServer6 if ip.version == 6 else WebhookServer
    return cls((str(ip), port), token, df_dir, log_stream=log_stream, max_inflight=max_inflight)


def write_port_file(path, port):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".port-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write("%d\n" % port)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


# ---------------- self-test ----------------

class _Http:
    """Raw-socket loopback client (no HTTP-client module)."""

    def __init__(self, port):
        self.port = port

    def send(self, raw):
        with socket.create_connection(("127.0.0.1", self.port), timeout=10) as s:
            s.sendall(raw)
            return self._read(s)

    @staticmethod
    def _read(s):
        chunks = []
        while True:
            try:
                b = s.recv(65536)
            except ConnectionResetError:
                break
            if not b:
                break
            chunks.append(b)
        data = b"".join(chunks)
        head, _, body = data.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        try:
            status = int(lines[0].split()[1])
        except (IndexError, ValueError):
            status = 0
        headers = {}
        for ln in lines[1:]:
            k, _, v = ln.partition(":")
            headers[k.strip().lower()] = v.strip()
        return status, headers, body

    def request(self, method, path, body=b"", headers=None, auth=None, length=True):
        hdrs = []
        if auth is not None:
            hdrs.append("Authorization: %s" % auth)
        if length:
            hdrs.append("Content-Length: %d" % len(body))
        hdrs.extend(headers or [])
        raw = ("%s %s HTTP/1.0\r\n" % (method, path) + "".join(h + "\r\n" for h in hdrs) + "\r\n").encode("latin-1")
        return self.send(raw + body)


def _payload(task_id, **extra):
    obj = {"task_id": task_id,
           "task_repository_url": "https://example.invalid/r.zip",
           "task_details_url": "https://example.invalid/d",
           "post_findings_url": "https://example.invalid/f"}
    obj.update(extra)
    return obj


def _files_under(root):
    found = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            p = os.path.join(dirpath, name)
            if stat.S_ISREG(os.lstat(p).st_mode):
                found.append(p)
    return found


def self_test():
    report = []
    fails = []

    def check(cond, label):
        report.append("  [%s] %s" % ("PASS" if cond else "FAIL", label))
        if not cond:
            fails.append(label)

    os.environ[SELFTEST_TOKEN_ENV] = SELFTEST_CANARY
    token = load_token({TOKEN_ENV: "secret://env/" + SELFTEST_TOKEN_ENV})
    check(token == SELFTEST_CANARY, "secret://env token resolves in-process")
    good = "token " + SELFTEST_CANARY
    wrong_tok = SELFTEST_CANARY[:-1] + chr(ord(SELFTEST_CANARY[-1]) ^ 1)
    log = io.StringIO()
    resolver_err = io.StringIO()
    servers = []
    root = tempfile.mkdtemp(prefix="agentarena-webhook-selftest.")
    try:
        df = os.path.join(root, "df")
        srv = make_server(ipaddress.ip_address("127.0.0.1"), 0, token, df, log_stream=log)
        servers.append(srv)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        h = _Http(srv.server_address[1])
        ok_body = json.dumps(_payload("task-ok-1")).encode()

        def post(body, auth=good, **kw):
            return h.request("POST", WEBHOOK_PATH, body=body, auth=auth, **kw)

        # auth: 401 + nothing written
        check(post(ok_body, auth=None)[0] == 401, "auth: no Authorization header -> 401")
        check(post(ok_body, auth="token " + wrong_tok)[0] == 401, "auth: wrong token, same length -> 401")
        check(post(ok_body, auth="Bearer " + SELFTEST_CANARY)[0] == 401, "auth: Bearer scheme -> 401")
        check(post(ok_body, headers=["Authorization: " + good])[0] == 401, "auth: two Authorization headers -> 401")
        # size
        st, _, _ = h.send(("POST /webhook HTTP/1.0\r\nAuthorization: %s\r\nContent-Length: %d\r\n\r\n"
                           % (good, MAX_BODY + 1)).encode())
        check(st == 413, "size: declared Content-Length 65537 (headers only) -> 413")
        check(post(ok_body, length=False)[0] == 411, "size: no Content-Length -> 411")
        check(post(b"0\r\n\r\n", length=False, headers=["Transfer-Encoding: chunked"])[0] == 411,
              "size: Transfer-Encoding chunked -> 411")
        check(post(ok_body, length=False, headers=["Content-Length: +5"])[0] == 400,
              "size: non-integer Content-Length -> 400")
        # method / path
        st, hd, _ = h.request("GET", WEBHOOK_PATH, auth=good)
        check(st == 405 and hd.get("allow") == "POST", "method: GET /webhook -> 405 Allow: POST")
        check(h.request("POST", "/hook", body=ok_body, auth=good)[0] == 404, "path: POST /hook -> 404")
        check(h.request("POST", "/webhook?x=1", body=ok_body, auth=good)[0] == 404, "path: POST /webhook?x=1 -> 404")
        # body
        check(post(b"{not json")[0] == 400, "body: invalid JSON -> 400")
        check(post(b"[1,2]")[0] == 400, "body: JSON array -> 400")
        missing = _payload("task-x")
        del missing["post_findings_url"]
        check(post(json.dumps(missing).encode())[0] == 400, "body: missing post_findings_url -> 400")
        check(post(b'{"task_id":"a","task_repository_url":NaN}')[0] == 400, "body: NaN constant -> 400")
        # task_id traversal / shape
        for bad in ("..", "../escape", "a/b", "a\\b", ".hidden", "-rf", "x\x00y", "abc\n", "", "a" * 129, 7):
            st, _, body = post(json.dumps(_payload(bad)).encode())
            check(st == 400 and b"bad-task-id" in body, "task_id: %r -> 400 bad-task-id" % (bad,))
        check(_files_under(root) == [], "no regular file anywhere under the temp root after every reject")
        check("escape" not in log.getvalue() and "hidden" not in log.getvalue()
              and "len=2 classes=dot" in log.getvalue() and "len=9 classes=alnum,dot,slash" in log.getvalue(),
              "rejected task_id values never reach the log (only length + char classes)")

        # happy path: atomic file, exact ack, modes, < 1 s
        t0 = time.monotonic()
        st, _, body = post(ok_body)
        elapsed = time.monotonic() - t0
        check(st == 202 and body == b'{"status":"accepted"}', "happy: 202 with exactly {\"status\":\"accepted\"}")
        check(elapsed < 1.0, "happy: round trip under 1.0 s (%.3f s)" % elapsed)
        inbox = inbox_dir(df)
        f = os.path.join(inbox, "task-ok-1.json")
        with open(f, "rb") as fh:
            content = fh.read()
        check(content == canonical(_payload("task-ok-1")).encode(), "happy: inbox file is the canonical serialization")
        check(stat.S_IMODE(os.stat(f).st_mode) == 0o600, "happy: inbox file mode 0600")
        check(stat.S_IMODE(os.stat(inbox).st_mode) == 0o700
              and stat.S_IMODE(os.stat(os.path.dirname(inbox)).st_mode) == 0o700,
              "happy: agentarena/ and inbox/ are 0700")
        check(not [n for n in os.listdir(inbox) if n.startswith(".incoming-")], "happy: no .incoming-* temp left")
        # boundary: a valid body of exactly MAX_BODY bytes
        base = json.dumps(_payload("task-boundary", pad="")).encode()
        big = json.dumps(_payload("task-boundary", pad="x" * (MAX_BODY - len(base)))).encode()
        check(len(big) == MAX_BODY and post(big)[0] == 202, "size: body of exactly 65536 bytes -> 202")
        # duplicate: 202, first file untouched
        ino = os.stat(f).st_ino
        st, _, body = post(json.dumps(_payload("task-ok-1", task_details_url="https://example.invalid/other")).encode())
        with open(f, "rb") as fh:
            again = fh.read()
        check(st == 202 and body == b'{"status":"accepted"}', "duplicate: same task_id -> 202")
        check(again == content and os.stat(f).st_ino == ino, "duplicate: first file bytes + inode unchanged")
        check("outcome=duplicate task_id=task-ok-1" in log.getvalue(), "duplicate: logged as outcome=duplicate")

        # busy: cap 1, one idle connection held open -> the next gets 503
        busy = make_server(ipaddress.ip_address("127.0.0.1"), 0, token, os.path.join(root, "df-busy"),
                           log_stream=log, max_inflight=1)
        servers.append(busy)
        threading.Thread(target=busy.serve_forever, daemon=True).start()
        idle = socket.create_connection(("127.0.0.1", busy.server_address[1]), timeout=10)
        try:
            with socket.create_connection(("127.0.0.1", busy.server_address[1]), timeout=10) as s2:
                st = _Http._read(s2)[0]
            check(st == 503, "busy: second connection while the cap is held -> 503")
        finally:
            idle.close()

        # startup refusals
        with redirect_stderr(resolver_err):
            for env, want, label in (({}, 2, "token unset -> 2"),
                                     ({TOKEN_ENV: "secret://env/AGENTARENA_WEBHOOK_SELFTEST_UNSET"}, 3,
                                      "secret://env/<unset> -> 3")):
                os.environ.pop("AGENTARENA_WEBHOOK_SELFTEST_UNSET", None)
                try:
                    load_token(env)
                    got = 0
                except ConfigError as e:
                    got = e.code
                check(got == want, "startup: " + label)
        for addr, want in (("0.0.0.0", 2), ("::1", 0), ("localhost", 2), ("127.0.0.1", 0)):
            try:
                check_bind(addr, False)
                got = 0
            except ConfigError as e:
                got = e.code
            check(got == want, "startup: check_bind(%s) -> %d" % (addr, want))
        check(check_bind("0.0.0.0", True).version == 4, "startup: 0.0.0.0 accepted with --allow-non-loopback")
    finally:
        for s in servers:
            s.shutdown()
            s.server_close()
        for p in _files_under(root):
            os.unlink(p)
        for dirpath, dirs, _files in sorted(os.walk(root), key=lambda t: -len(t[0])):
            os.rmdir(dirpath)
        os.environ.pop(SELFTEST_TOKEN_ENV, None)

    captured = log.getvalue() + resolver_err.getvalue() + "\n".join(report)
    check(SELFTEST_CANARY not in captured and wrong_tok not in captured,
          "log hygiene: no token (right or wrong) in the log, resolver stderr or report")
    print("%s --self-test" % PROG)
    print("\n".join(report))
    if fails:
        print("%s --self-test: %d FAILED" % (PROG, len(fails)))
        return 1
    print("%s --self-test: all %d checks passed" % (PROG, len(report)))
    return 0


# ---------------- main ----------------

class _Stop(Exception):
    pass


def _on_signal(signum, frame):
    raise _Stop()


def main(argv=None):
    ap = argparse.ArgumentParser(prog=PROG, description="AgentArena webhook receiver (token from env %s)." % TOKEN_ENV)
    ap.add_argument("--bind", default=DEFAULT_BIND, help="IP literal to bind (default %(default)s, loopback only)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="port (default %(default)s; 0 = ephemeral)")
    ap.add_argument("--port-file", help="write the bound port here (atomic) after binding")
    ap.add_argument("--allow-non-loopback", action="store_true",
                    help="permit a non-loopback --bind (only behind a TLS-terminating front on this host)")
    ap.add_argument("--self-test", action="store_true", help="offline self-test, exit 0/1")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if not 0 <= args.port <= 65535:
        sys.stderr.write("%s: --port out of range\n" % PROG)
        return 2
    try:
        ip = check_bind(args.bind, args.allow_non_loopback)
        token = load_token()
    except ConfigError as e:
        sys.stderr.write("%s: %s\n" % (PROG, e))
        return e.code
    df_dir = default_df_dir()
    try:
        srv = make_server(ip, args.port, token, df_dir)
    except OSError as e:
        sys.stderr.write("%s: bind %s:%d failed: %s\n" % (PROG, ip, args.port, e.strerror or e))
        return 4
    del token
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    try:
        port = srv.server_address[1]
        if args.port_file:
            write_port_file(args.port_file, port)
        sys.stderr.write("%s: listening on %s port %d, inbox %s\n" % (PROG, ip, port, inbox_dir(df_dir)))
        sys.stderr.flush()
        srv.serve_forever()
    except _Stop:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
