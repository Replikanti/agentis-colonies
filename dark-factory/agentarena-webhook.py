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
    400 bad-request      bad/duplicate Content-Length, short body, invalid or non-strict JSON (NaN/Infinity,
                         a number that overflows to inf, a lone surrogate, nesting deeper than 32),
                         missing/non-string *_url
    400 timeout          the body did not arrive before the 10 s whole-request deadline
    400 bad-task-id      task_id is not 1-128 chars of [A-Za-z0-9_-] with an alphanumeric first char
    401 unauthorized     missing, wrong or repeated Authorization header (checked before the body is read)
    404 not-found        any path other than exactly /webhook
    405 method-not-allowed  /webhook with a method other than POST (Allow: POST)
    411 length-required  Transfer-Encoding present or Content-Length missing
    413 too-large        declared Content-Length above 65536 (the body is never read)
    500 write-failed     the inbox write failed
    503 busy             more than 16 requests in flight
    (no response)        the request line + headers did not arrive before the 10 s deadline
                         (logged as status=0 outcome=timeout)

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
import math
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
# 5 s: the longest a single socket read may stall. A legitimate sender pushes
# < 1 KB in one segment, so any read that waits this long is a stalled client.
# Below ~1 s it can cut a slow tunnel leg; much higher lets idle connections pin
# the in-flight cap. It resets on every byte, so on its own it does not stop a
# slow-drip client: REQUEST_DEADLINE_S does.
SOCKET_TIMEOUT_S = 5
# 10 s: whole-request deadline (request line + headers + body), counted from the
# accept and enforced on every read whatever the drip rate. A legitimate
# notification arrives in milliseconds; 10 s is 2x the per-read stall limit, so
# a sender may stall once and still finish. Without it, 16 clients dripping one
# header byte every few seconds hold every in-flight slot indefinitely and the
# real notification gets 503 (slowloris). Much lower risks cutting a slow tunnel
# leg; higher lengthens how long each such client holds a slot. With it, holding
# the receiver busy needs a sustained connection flood, which is the front's job.
REQUEST_DEADLINE_S = 10
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
# 32: maximum container nesting (the top-level object is depth 1). The
# notification is a flat object, so 32 leaves room for nested metadata the
# platform may add, while staying far below what strict consumers accept
# (serde_json's default recursion limit is 128, jq's depth limit 10000). An
# uncapped depth would let a token holder write a file a strict parser rejects.
MAX_DEPTH = 32
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
    # allow_nan=False: a non-finite float that slipped past the parser is an
    # internal invariant failure (500), never a non-JSON token in the inbox.
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                      allow_nan=False) + "\n"


def _strict_float(text):
    """json.loads parse_float hook: an overflowing literal (1e999) is rejected, not inf."""
    value = float(text)
    if not math.isfinite(value):
        raise ValueError("non-finite number")
    return value


def _has_surrogate(text):
    return any(0xD800 <= ord(c) <= 0xDFFF for c in text)


def strict_json_ok(obj):
    """True when obj re-serializes to strict RFC 8259 JSON: nesting <= MAX_DEPTH and
    no lone surrogate in any key or string (a paired surrogate escape decodes to one
    astral character, so any surrogate code point left is unpaired). Iterative, so a
    deep document cannot exhaust the stack here."""
    stack = [(obj, 1)]
    while stack:
        node, depth = stack.pop()
        if isinstance(node, str):
            if _has_surrogate(node):
                return False
        elif isinstance(node, (dict, list)):
            if depth > MAX_DEPTH:
                return False
            if isinstance(node, dict):
                for k, v in node.items():
                    if _has_surrogate(k):
                        return False
                    stack.append((v, depth + 1))
            else:
                stack.extend((v, depth + 1) for v in node)
    return True


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

    def __init__(self, addr, token, df_dir, log_stream=None, max_inflight=MAX_INFLIGHT,
                 request_deadline=REQUEST_DEADLINE_S):
        self.token_header = b"token " + token.encode("utf-8")
        self.request_deadline = request_deadline
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


class _DeadlineReader(io.RawIOBase):
    """Socket reader that enforces one absolute deadline across all reads.

    Every recv waits at most min(SOCKET_TIMEOUT_S, time left); once the deadline
    has passed the next read raises socket.timeout, however slowly bytes drip in.
    """

    def __init__(self, sock, deadline):
        super().__init__()
        self._sock = sock
        self._deadline = deadline

    def readable(self):
        return True

    def readinto(self, buf):
        remaining = self._deadline - time.monotonic()
        if remaining <= 0:
            raise socket.timeout("request deadline")
        self._sock.settimeout(min(SOCKET_TIMEOUT_S, remaining))
        return self._sock.recv_into(buf)


class WebhookHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    timeout = SOCKET_TIMEOUT_S
    server_version = PROG
    sys_version = ""

    def setup(self):
        super().setup()
        deadline = time.monotonic() + self.server.request_deadline
        self.rfile.close()
        self.rfile = io.BufferedReader(_DeadlineReader(self.connection, deadline))

    def version_string(self):
        return self.server_version

    def log_message(self, format, *args):  # noqa: A002 - base-class signature
        # No default access log: it would echo the request line verbatim.
        pass

    def log_error(self, format, *args):  # noqa: A002 - base-class signature
        # The base class reports a header-phase timeout here; the connection is
        # closed without a response. Never format args (request data).
        if format.startswith("Request timed out"):
            _emit(self.server, 0, "timeout")

    def send_error(self, code, message=None, explain=None):
        # The base class calls this for malformed request lines/headers and
        # unknown methods; its default HTML body echoes request data. Older
        # Pythons leave request_version at HTTP/0.9 here, which suppresses the
        # status line; always answer with one.
        if self.request_version == "HTTP/0.9":
            self.request_version = "HTTP/1.0"
        self._respond(code, {"error": "malformed"})
        _emit(self.server, code, "malformed")

    def _respond(self, status, obj, extra=()):
        body = json.dumps(obj, separators=(",", ":")).encode("ascii")
        try:
            # The read deadline may have shrunk the socket timeout; give the
            # (tiny, fixed) response the normal per-operation budget.
            self.connection.settimeout(SOCKET_TIMEOUT_S)
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
        except socket.timeout:
            return self._reject(400, "timeout", nbytes=length)
        except OSError:
            return self._reject(400, "bad-request")
        if len(body) != length:
            return self._reject(400, "bad-request", nbytes=len(body))
        # 5. strict JSON (finite numbers, no lone surrogates, depth <= MAX_DEPTH),
        #    an object with string *_url fields (URL policy belongs to #2326)
        try:
            obj = json.loads(body.decode("utf-8"), parse_constant=_reject_constant,
                             parse_float=_strict_float)
        except (ValueError, RecursionError):
            return self._reject(400, "bad-request", nbytes=length)
        if not strict_json_ok(obj):
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


def make_server(ip, port, token, df_dir, log_stream=None, max_inflight=MAX_INFLIGHT,
                request_deadline=REQUEST_DEADLINE_S):
    cls = WebhookServer6 if ip.version == 6 else WebhookServer
    return cls((str(ip), port), token, df_dir, log_stream=log_stream, max_inflight=max_inflight,
               request_deadline=request_deadline)


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
    # Anything the handlers write to stderr (e.g. a default access log) lands in
    # resolver_err and is checked below.
    real_stderr = sys.stderr
    sys.stderr = resolver_err
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
        # strict JSON: every inbox file must parse under a strict RFC 8259 parser
        urls = ('"task_repository_url":"https://example.invalid/r","task_details_url":"https://example.invalid/d",'
                '"post_findings_url":"https://example.invalid/f"')

        def strict_case(label, tid, extra):
            st = post(('{"task_id":"%s",%s,%s}' % (tid, urls, extra)).encode())[0]
            check(st == 400 and not os.path.exists(os.path.join(inbox_dir(df), tid + ".json")),
                  "body: %s -> 400, no inbox file" % label)

        try:
            canonical({"x": float("inf")})
            raised = False
        except ValueError:
            raised = True
        check(raised, "canonical() refuses a non-finite float (last line of defence, allow_nan=False)")
        strict_case("NaN in an extra field", "task-nan", '"x":NaN')
        strict_case("1e999 (overflows to inf)", "task-inf", '"x":1e999')
        strict_case("-1e999", "task-ninf", '"x":-1e999')
        strict_case("lone surrogate \\ud800 in a value", "task-sur", '"x":"\\ud800"')
        strict_case("lone surrogate \\udc00 in a key", "task-surk", '"\\udc00":1')
        strict_case("nesting depth %d" % (MAX_DEPTH + 1), "task-deep", '"x":' + "[" * MAX_DEPTH + "]" * MAX_DEPTH)
        strict_case("32000-deep nesting", "task-deep2", '"x":' + "[" * 32000 + "]" * 32000)
        # framing
        dup_body = json.dumps(_payload("task-dupcl")).encode()
        st = post(dup_body, headers=["Content-Length: %d" % len(dup_body)])[0]
        check(st == 400, "size: two Content-Length headers -> 400")
        te_body = json.dumps(_payload("task-te")).encode()
        st = post(te_body, headers=["Transfer-Encoding: chunked"])[0]
        check(st == 411, "size: Transfer-Encoding alongside a valid Content-Length -> 411")
        # the base class's own error paths answer with the fixed body, never an echo
        st, _, body = h.send(b"ECHOMARK-ZQ\r\n\r\n")
        check(st == 400 and body == b'{"error":"malformed"}', "malformed request line -> 400, fixed JSON body")
        st, _, body = h.send(b"FROBECHO /webhook HTTP/1.0\r\n\r\n")
        check(st == 501 and body == b'{"error":"malformed"}', "unknown method -> 501, fixed JSON body")
        check(all(m not in out for m in ("ECHOMARK", "FROBECHO", "POST /webhook")
                  for out in (log.getvalue(), resolver_err.getvalue())),
              "no request line is echoed into the log or stderr (no default access log)")
        # task_id traversal / shape
        for bad in ("..", "../escape", "a/b", "a\\b", ".hidden", "-rf", "x\x00y", "abc\n", "", "a" * 129, 7):
            st, _, body = post(json.dumps(_payload(bad)).encode())
            check(st == 400 and b"bad-task-id" in body, "task_id: %r -> 400 bad-task-id" % (bad,))
        check(_files_under(root) == [], "no regular file anywhere under the temp root after every reject")
        # strict boundary: depth == MAX_DEPTH and a paired surrogate escape are fine
        ok_deep = ('{"task_id":"task-depth-ok",%s,"x":%s,"y":"\\ud83d\\ude00"}'
                   % (urls, "[" * (MAX_DEPTH - 1) + "]" * (MAX_DEPTH - 1)))
        check(post(ok_deep.encode())[0] == 202, "body: depth %d + a paired surrogate escape -> 202" % MAX_DEPTH)
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

        # deadline: a slow-drip client is cut at the whole-request deadline, freeing its slot
        drip = make_server(ipaddress.ip_address("127.0.0.1"), 0, token, os.path.join(root, "df-drip"),
                           log_stream=log, max_inflight=1, request_deadline=1.0)
        servers.append(drip)
        threading.Thread(target=drip.serve_forever, daemon=True).start()
        dport = drip.server_address[1]
        d = socket.create_connection(("127.0.0.1", dport), timeout=10)
        try:
            d.sendall(b"POST /webhook HTTP/1.0\r\nX-Pad: ")
            d.settimeout(0.2)
            t0 = time.monotonic()
            cut = None
            while time.monotonic() - t0 < 4.0:
                try:
                    d.sendall(b"a")
                    if d.recv(1) == b"":
                        cut = time.monotonic() - t0
                        break
                except socket.timeout:
                    continue
                except OSError:
                    cut = time.monotonic() - t0
                    break
            check(cut is not None and cut < 3.0,
                  "deadline: client dripping a header byte every 0.2 s is cut at the 1 s request deadline")
            st = 0
            for _ in range(10):  # the slot is released just after the FIN the dripper saw
                st = _Http(dport).request("POST", WEBHOOK_PATH, body=json.dumps(_payload("task-after-drip")).encode(),
                                          auth=good)[0]
                if st != 503:
                    break
                time.sleep(0.05)
            check(st == 202, "deadline: authenticated request on the cap-1 server after the cut -> 202")
        finally:
            d.close()
        check("status=0 outcome=timeout" in log.getvalue(), "deadline: the cut is logged as outcome=timeout")

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
        # the bind is refused before the token is resolved (no keyring lookup for a bad config)
        saved = os.environ.get(TOKEN_ENV)
        os.environ[TOKEN_ENV] = "secret://env/AGENTARENA_WEBHOOK_SELFTEST_UNSET"
        try:
            with redirect_stderr(resolver_err):
                rc = main(["--bind", "0.0.0.0", "--port", "0"])
        finally:
            if saved is None:
                os.environ.pop(TOKEN_ENV, None)
            else:
                os.environ[TOKEN_ENV] = saved
        check(rc == 2, "startup: bad --bind + unresolvable secret -> 2 (bind checked before any secret lookup)")
    finally:
        sys.stderr = real_stderr
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
