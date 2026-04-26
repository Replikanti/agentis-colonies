#!/usr/bin/env python3
# federation-dashboard-server.py: HTTP server that powers the live
# federation dashboard. Serves the regenerated HTML, plus REST endpoints
# for /refresh, /confidence, /restart, /quarantine, /evolve, /cleanup,
# /start, and /kill.
#
# Extracted from federation-dashboard.sh in #170 alongside the collector
# (federation-dashboard-collector.py) for consistency. The bash heredoc
# parser bug only affected the collector heredoc (nested in $()), but
# moving both keeps the precedent clear: Python lives in .py files, not
# inside heredocs.
#
# Args (positional):
#   1: serve_dir       — federation-dashboard cache dir to serve from
#   2: port            — TCP port to bind on 127.0.0.1
#   3: script_path     — absolute path to the federation-dashboard entry
#                        script (used by /refresh to re-exec in regen-only mode)
#   4: fed_dir_arg     — federation root directory
#   5: allowed_agents  — comma-separated allowlist for /confidence
#   6: agent_map_json  — JSON array of {agent, colony} pairs
#   7: fed_tools_dir   — federation shared-tools dir (#252); used to locate
#                        kill-federation.sh. Empty disables /kill.
#                        Post-#257 the dashboard no longer reaches into
#                        tools/ for restart logic — spawning is delegated
#                        to each colony's scripts/start-colony.sh.

import sys, os, subprocess, json, time, signal, shutil, shlex, threading, hashlib, urllib.parse
from http.server import HTTPServer, SimpleHTTPRequestHandler, ThreadingHTTPServer

serve_dir, port = sys.argv[1], int(sys.argv[2])
script_path, fed_dir_arg = sys.argv[3], sys.argv[4]
allowed_agents = set(a for a in sys.argv[5].split(',') if a)
try:
    _map = json.loads(sys.argv[6])
except (json.JSONDecodeError, ValueError, IndexError):
    _map = []
fed_tools_dir = sys.argv[7] if len(sys.argv) > 7 else ''
agent_to_colony = {e.get('agent',''): e.get('colony','') for e in _map if e.get('agent')}
os.chdir(serve_dir)
fed_dir = os.path.dirname(serve_dir)
confidence_log = os.path.join(serve_dir, 'confidence-log.jsonl')

# --- SSE plumbing (#313 PR 1) ---
# The wrapper writes the latest collector JSON snapshot to <serve_dir>/snapshot.json
# atomically (temp + rename) after each generate() cycle. A daemon thread polls
# the file's mtime every 250ms; on change it loads the bytes, attaches an
# 8-char sha hash for client-side dedupe, parks the result in latest_snapshot,
# and notify_all()'s on snapshot_cv. /events handlers wait on the condition
# and write each new bytes blob as one `event: snapshot\ndata: ...\n\n` frame
# (plus a `: keepalive\n\n` comment frame every 30s when nothing fires, so
# proxies / browsers don't time the connection out).
snapshot_path = os.path.join(serve_dir, 'snapshot.json')
snapshot_lock = threading.Lock()
snapshot_cv = threading.Condition(snapshot_lock)
latest_snapshot = None  # bytes (UTF-8 JSON with `__hash` injected) or None
_last_snapshot_mtime = 0.0


def _augment_snapshot(raw_bytes):
    """Inject an 8-char `__hash` of the canonical JSON so clients can dedupe.
    Returns augmented bytes; on parse failure returns the raw bytes unchanged
    (the SSE consumer will catch the exception client-side)."""
    try:
        obj = json.loads(raw_bytes.decode('utf-8'))
    except (ValueError, UnicodeDecodeError):
        return raw_bytes
    if not isinstance(obj, dict):
        return raw_bytes
    # Hash without the __hash field (idempotent across re-augmentations).
    obj.pop('__hash', None)
    canon = json.dumps(obj, sort_keys=True, separators=(',', ':')).encode('utf-8')
    digest = hashlib.sha256(canon).hexdigest()[:8]
    obj['__hash'] = digest
    return json.dumps(obj, separators=(',', ':')).encode('utf-8')


def _snapshot_watcher():
    """Daemon thread: polls snapshot.json mtime every 250ms; on change reads
    the bytes, augments with a hash, parks in latest_snapshot, and notifies
    waiting /events handlers. No-op until the wrapper produces the file."""
    global latest_snapshot, _last_snapshot_mtime
    while True:
        try:
            mtime = os.path.getmtime(snapshot_path)
        except OSError:
            time.sleep(0.25)
            continue
        if mtime != _last_snapshot_mtime:
            try:
                with open(snapshot_path, 'rb') as f:
                    raw = f.read()
            except OSError:
                time.sleep(0.25)
                continue
            augmented = _augment_snapshot(raw)
            with snapshot_cv:
                latest_snapshot = augmented
                _last_snapshot_mtime = mtime
                snapshot_cv.notify_all()
        time.sleep(0.25)


threading.Thread(target=_snapshot_watcher, daemon=True).start()

# #252: kill-federation.sh lives in the federation's shared tools dir, not
# next to this script (the dashboard is a separately-versioned standalone
# component). The entry script resolves <fed-dir>/tools/ then
# <fed-dir>/../tools/ and passes the result in argv[7]. Empty means no
# shared tools were found — /kill returns a clear error.
# #257: restart no longer needs a tools/ helper — spawning is delegated
# to <colony>/scripts/start-colony.sh, which owns the federation's
# forge-specific env wiring. parse_toml_section / resolve_tick_interval
# used to live here for that purpose and were removed.
kill_script = os.path.join(fed_tools_dir, 'kill-federation.sh') if fed_tools_dir else ''
# #318: cost-cap override endpoint shells out to tools/cost-cap.sh in the
# federation's shared tools dir. Returns 503 when no shared tools/ was
# found at startup (mirrors /kill precedent).
cost_cap_script = os.path.join(fed_tools_dir, 'cost-cap.sh') if fed_tools_dir else ''
# #352: /sidecar-restart endpoint shells out to tools/sidecar-restart.sh
# (extracted helper, mirrors cost-cap.sh precedent). Returns 503 when no
# shared tools/ was found at startup.
sidecar_restart_script = os.path.join(fed_tools_dir, 'sidecar-restart.sh') if fed_tools_dir else ''
# #352: /config/apply audit log path. The dashboard appends one row per
# applied edit so operators can replay the history.
config_audit_log = os.path.join(fed_dir, '.agentis', 'logs', 'config-edits.jsonl')
# #352: /config/apply gate. Reads the same `[config_editor]
# .operator_writes_enabled` key the collector emits; default false. The
# endpoint returns 503 when the gate is off.
def _read_operator_writes_enabled():
    cfg_path = os.path.join(fed_dir, '.agentis', 'config')
    if not os.path.isfile(cfg_path):
        return False
    try:
        section = ''
        with open(cfg_path, encoding='utf-8') as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith('#'):
                    continue
                if line.startswith('[') and line.endswith(']'):
                    section = line[1:-1].strip()
                    continue
                if '=' not in line or section != 'config_editor':
                    continue
                k, _, v = line.partition('=')
                if k.strip() == 'operator_writes_enabled':
                    rv = v.strip().strip('"').strip("'").lower().split('#', 1)[0].strip()
                    return rv == 'true'
    except OSError:
        return False
    return False


def list_daemons():
    try:
        result = subprocess.run(
            ['agentis', 'daemon', 'list', '--json'],
            capture_output=True, text=True, cwd=fed_dir, timeout=5,
        )
        if result.returncode != 0:
            return []
        return json.loads(result.stdout or '[]')
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError, ValueError):
        return []


def find_agent_daemon(agent):
    """Return the running daemon record whose source basename matches
    <agent>.ag, or None."""
    ag_file = f'{agent}.ag'
    running = None
    any_match = None
    for d in list_daemons():
        src = d.get('source') or ''
        if not src:
            continue
        if os.path.basename(src) != ag_file:
            continue
        any_match = any_match or d
        if d.get('state') == 'running' and running is None:
            running = d
    return running or any_match


def pid_alive(pid):
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def wait_for_exit(pid, timeout_s):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if not pid_alive(pid):
            return True
        time.sleep(0.2)
    return not pid_alive(pid)


def cleanup_sidecars(agent_id):
    """Remove stale per-daemon files under $FED_DIR/.agentis/daemon/."""
    sidecar_dir = os.path.join(fed_dir, '.agentis', 'daemon')
    removed = []
    for ext in ('pid', 'watchdog.pid', 'colony', 'heartbeat', 'status', 'stop'):
        p = os.path.join(sidecar_dir, f'{agent_id}.{ext}')
        try:
            os.remove(p)
            removed.append(os.path.basename(p))
        except FileNotFoundError:
            pass
        except OSError:
            pass
    inbox = os.path.join(sidecar_dir, f'{agent_id}.inbox')
    try:
        shutil.rmtree(inbox)
        removed.append(os.path.basename(inbox))
    except FileNotFoundError:
        pass
    except OSError:
        pass
    return removed


def build_manual_command(colony, colony_dir, agent_file):
    """Single-line respawn command the operator can paste if auto-restart fails.

    #257: delegates to the colony's start-colony.sh so the command stays
    federation-agnostic and matches what the dashboard itself executes.
    start-colony.sh owns the forge-specific env construction (GITLAB_*,
    future GITHUB_*, etc) — the dashboard does not need to know.
    """
    agent_name = os.path.basename(agent_file)
    if agent_name.endswith('.ag'):
        agent_name = agent_name[:-3]
    start_script = os.path.join(colony_dir, 'scripts', 'start-colony.sh')
    return f'{shlex.quote(start_script)} --restart-agent {shlex.quote(agent_name)}'


def restart_daemon(agent):
    """Stop+cleanup+respawn sequence for one agent (#137 Option 2).

    #257: spawning is delegated to <colony>/scripts/start-colony.sh
    --restart-agent <agent>. The dashboard does not parse the colony's
    TOML or construct forge-specific env vars — whatever env the colony
    needs (GITLAB_*, future GITHUB_*, etc) start-colony.sh composes
    itself. Stop + sidecar cleanup + spawn verification stay here
    because they depend only on the agentis runtime, not on the
    federation type.
    """
    events = []

    def rec(step, status, **kw):
        entry = {'step': step, 'status': status}
        entry.update(kw)
        events.append(entry)

    colony = agent_to_colony.get(agent, '')
    if not colony:
        rec('lookup', 'error', message=f'no colony mapping for {agent}')
        return {
            'attempted': False, 'succeeded': False,
            'error': f'no colony mapping for {agent}',
            'events': events,
        }

    colony_dir = os.path.join(fed_dir, colony)
    agent_file = os.path.join(colony_dir, 'agents', f'{agent}.ag')
    if not os.path.isfile(agent_file):
        rec('lookup', 'error', message=f'missing {agent_file}')
        return {
            'attempted': False, 'succeeded': False,
            'error': f'missing {agent_file}',
            'events': events,
        }

    start_script = os.path.join(colony_dir, 'scripts', 'start-colony.sh')
    if not os.path.isfile(start_script):
        rec('lookup', 'error', message=f'missing {start_script}')
        return {
            'attempted': False, 'succeeded': False,
            'error': f'missing {start_script}',
            'events': events,
        }

    manual_cmd = build_manual_command(colony, colony_dir, agent_file)

    old = find_agent_daemon(agent)
    old_agent_id = (old or {}).get('agent_id') or ''
    old_pid = (old or {}).get('pid') or 0
    old_started_at = (old or {}).get('started_at') or 0
    rec('resolve', 'ok', agent_id=old_agent_id, pid=old_pid,
        running=(old is not None and old.get('state') == 'running'))

    if old and old.get('state') == 'running' and old_agent_id:
        rec('stop', 'start')
        try:
            result = subprocess.run(
                ['agentis', 'daemon', 'stop', old_agent_id],
                capture_output=True, text=True, cwd=fed_dir, timeout=10,
            )
            rec('stop', 'ok' if result.returncode == 0 else 'warn',
                stdout=(result.stdout or '').strip(),
                stderr=(result.stderr or '').strip(),
                returncode=result.returncode)
        except (OSError, subprocess.SubprocessError) as e:
            rec('stop', 'warn', message=str(e))

        if old_pid:
            rec('wait_exit', 'start', pid=old_pid, timeout_s=5)
            if wait_for_exit(old_pid, 5.0):
                rec('wait_exit', 'ok')
            else:
                rec('sigterm', 'start',
                    message='daemon stop did not land within 5s, sending SIGTERM')
                try:
                    os.kill(old_pid, signal.SIGTERM)
                except OSError as e:
                    rec('sigterm', 'warn', message=str(e))
                if wait_for_exit(old_pid, 5.0):
                    rec('sigterm', 'ok')
                else:
                    rec('sigkill', 'start',
                        message='SIGTERM did not land within 5s, sending SIGKILL')
                    try:
                        os.kill(old_pid, signal.SIGKILL)
                    except OSError as e:
                        rec('sigkill', 'warn', message=str(e))
                    if not wait_for_exit(old_pid, 2.0):
                        rec('verify_dead', 'error',
                            message=f'pid {old_pid} survived SIGKILL')
                        return {
                            'attempted': True, 'succeeded': False,
                            'error': f'pid {old_pid} survived SIGKILL',
                            'manual_command': manual_cmd,
                            'events': events,
                        }
                    rec('sigkill', 'ok')

    if old_agent_id:
        removed = cleanup_sidecars(old_agent_id)
        rec('cleanup', 'ok', removed=removed)

    # #257: delegate spawn to start-colony.sh --restart-agent. The script
    # composes forge env itself (GITLAB_*, future GITHUB_*, …), backgrounds
    # a single `agentis daemon ... &` with the per-colony tick interval,
    # then exits 0 with a single "started <agent> pid=<pid> tick=<ms>"
    # line on stdout. start_new_session=True insulates the backgrounded
    # daemon from SIGHUP when start-colony.sh returns.
    rec('spawn', 'start', via=start_script)
    spawn_ts = int(time.time())
    try:
        result = subprocess.run(
            ['bash', start_script, '--restart-agent', agent],
            capture_output=True, text=True,
            timeout=15,
            start_new_session=True,
        )
    except (OSError, subprocess.SubprocessError) as e:
        rec('spawn', 'error', message=str(e))
        return {
            'attempted': True, 'succeeded': False,
            'error': f'spawn failed: {e}',
            'manual_command': manual_cmd,
            'events': events,
        }
    if result.returncode != 0:
        err = ((result.stderr or '') + (result.stdout or '')).strip()
        rec('spawn', 'error',
            returncode=result.returncode,
            stderr=(result.stderr or '').strip(),
            stdout=(result.stdout or '').strip())
        return {
            'attempted': True, 'succeeded': False,
            'error': f'start-colony.sh exit {result.returncode}: {err}',
            'manual_command': manual_cmd,
            'events': events,
        }
    spawn_line = ((result.stdout or '').strip().splitlines() or [''])[0]
    rec('spawn', 'ok', stdout=spawn_line)

    rec('verify', 'start', timeout_s=15)
    deadline = time.monotonic() + 15.0
    new_daemon = None
    while time.monotonic() < deadline:
        for d in list_daemons():
            src = d.get('source') or ''
            if not src or os.path.basename(src) != f'{agent}.ag':
                continue
            if d.get('state') != 'running':
                continue
            new_pid = d.get('pid') or 0
            if old_pid and new_pid == old_pid:
                continue
            if (d.get('started_at') or 0) < spawn_ts - 1:
                continue
            new_daemon = d
            break
        if new_daemon:
            break
        time.sleep(0.5)

    if not new_daemon:
        rec('verify', 'error',
            message='new daemon not registered within 15s')
        return {
            'attempted': True, 'succeeded': False,
            'error': 'new daemon not registered within 15s',
            'manual_command': manual_cmd,
            'events': events,
        }

    rec('verify', 'ok',
        new_pid=new_daemon.get('pid'),
        new_agent_id=new_daemon.get('agent_id'),
        new_started_at=new_daemon.get('started_at'),
        new_confidence=new_daemon.get('confidence'))

    return {
        'attempted': True, 'succeeded': True,
        'old_pid': old_pid,
        'old_started_at': old_started_at,
        'new_pid': new_daemon.get('pid'),
        'new_agent_id': new_daemon.get('agent_id'),
        'new_started_at': new_daemon.get('started_at'),
        'new_confidence': new_daemon.get('confidence'),
        'manual_command': manual_cmd,
        'events': events,
    }

# #315 PR 2: timeline-full.jsonl path. Written by the wrapper after each
# generate() cycle (last 7 days, 5000-row cap, ts-desc). The /timeline
# endpoint reads from this file. Missing file is non-fatal: /timeline
# returns 200 with an empty rows array so the client can degrade gracefully.
timeline_full_path = os.path.join(serve_dir, 'timeline-full.jsonl')


def _serve_timeline(handler):
    """GET /timeline?since=<unix-ms>&limit=<N>&colony=<name>&kind=<csv>.

    Returns JSON {rows: [...], next_cursor: <ts>|null} of timeline rows
    OLDER than `since` (default = current time, returning the most-recent
    N rows). limit is capped at 500 to bound memory; default 200.
    Read-only: no side effects, no daemon mutation.

    400 on bad params (limit > 500, malformed since/limit), 500 on
    internal read error, 200 on success including missing file.
    """
    parsed = urllib.parse.urlparse(handler.path)
    qs = urllib.parse.parse_qs(parsed.query, keep_blank_values=False)

    # Parse `since` (default: now). Older rows = ts < since.
    since_raw = (qs.get('since') or [''])[0]
    if since_raw:
        try:
            since_ms = int(since_raw)
            if since_ms < 0:
                raise ValueError('negative since')
        except (ValueError, TypeError):
            handler.send_response(400)
            handler.send_header('Content-Type', 'application/json')
            handler.end_headers()
            handler.wfile.write(json.dumps({'error': 'bad since (expected unix-ms int)'}).encode())
            return
    else:
        since_ms = int(time.time() * 1000) + 1  # +1 so ts < since includes "now"

    # Parse `limit` (default 200, max 500).
    limit_raw = (qs.get('limit') or [''])[0]
    if limit_raw:
        try:
            limit = int(limit_raw)
        except (ValueError, TypeError):
            handler.send_response(400)
            handler.send_header('Content-Type', 'application/json')
            handler.end_headers()
            handler.wfile.write(json.dumps({'error': 'bad limit (expected int)'}).encode())
            return
        if limit < 1 or limit > 500:
            handler.send_response(400)
            handler.send_header('Content-Type', 'application/json')
            handler.end_headers()
            handler.wfile.write(json.dumps({'error': 'limit out of range [1, 500]'}).encode())
            return
    else:
        limit = 200

    colony_filter = (qs.get('colony') or [''])[0].strip()
    kind_raw = (qs.get('kind') or [''])[0].strip()
    kind_filter = set(k.strip() for k in kind_raw.split(',') if k.strip()) if kind_raw else set()

    # Read timeline-full.jsonl. Missing file → empty rows (graceful).
    rows = []
    if os.path.isfile(timeline_full_path):
        try:
            with open(timeline_full_path, encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(row, dict):
                        continue
                    ts = row.get('ts')
                    if not isinstance(ts, (int, float)) or ts >= since_ms:
                        continue
                    if colony_filter and row.get('colony', '') != colony_filter:
                        continue
                    if kind_filter and row.get('kind', '') not in kind_filter:
                        continue
                    rows.append(row)
                    # No early-trim — sort + slice happens once after the loop
                    # below so we always keep the absolute-newest `limit` rows
                    # even when the producer wrote out of order.
        except OSError as e:
            handler.send_response(500)
            handler.send_header('Content-Type', 'application/json')
            handler.end_headers()
            handler.wfile.write(json.dumps({'error': 'read failed: ' + str(e)}).encode())
            return

    # File is already ts-desc, but resort defensively (cheap on bounded N).
    rows.sort(key=lambda r: r.get('ts', 0), reverse=True)
    if len(rows) > limit:
        rows = rows[:limit]

    next_cursor = rows[-1].get('ts') if rows else None
    handler.send_response(200)
    handler.send_header('Content-Type', 'application/json')
    handler.end_headers()
    handler.wfile.write(json.dumps({
        'rows': rows,
        'next_cursor': next_cursor,
    }).encode())


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/timeline?') or self.path == '/timeline':
            _serve_timeline(self)
            return
        if self.path == '/events':
            # #313 PR 1: live SSE channel. Holds the connection open, pushes
            # one `event: snapshot\ndata: <COLLECTOR_JSON>\n\n` frame whenever
            # the snapshot file changes (the watcher thread notify_all()'s
            # snapshot_cv). Sends a `: keepalive\n\n` comment every 30s when
            # nothing fires so proxies / browsers don't drop the idle stream.
            try:
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Cache-Control', 'no-cache')
                self.send_header('Connection', 'keep-alive')
                self.send_header('X-Accel-Buffering', 'no')  # disable nginx buffering
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                # Push the most recent snapshot immediately so a fresh
                # connection doesn't have to wait for the next regen tick.
                with snapshot_cv:
                    last_seen_id = id(latest_snapshot)
                    if latest_snapshot is not None:
                        self.wfile.write(b'event: snapshot\ndata: ')
                        self.wfile.write(latest_snapshot)
                        self.wfile.write(b'\n\n')
                        self.wfile.flush()
                while True:
                    with snapshot_cv:
                        # Wait up to 30s for a new snapshot; on timeout we
                        # send a keepalive comment and loop. id() is fine
                        # because latest_snapshot is rebound (new bytes
                        # object) on every update.
                        snapshot_cv.wait(timeout=30.0)
                        current_id = id(latest_snapshot)
                        snapshot_to_send = None
                        if current_id != last_seen_id and latest_snapshot is not None:
                            snapshot_to_send = latest_snapshot
                            last_seen_id = current_id
                    if snapshot_to_send is not None:
                        self.wfile.write(b'event: snapshot\ndata: ')
                        self.wfile.write(snapshot_to_send)
                        self.wfile.write(b'\n\n')
                    else:
                        # Idle timeout: keepalive comment frame.
                        self.wfile.write(b': keepalive\n\n')
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                # Client went away. The thread exits cleanly; the watcher
                # daemon keeps running for the next subscriber.
                return
            return
        # Defer to SimpleHTTPRequestHandler for static-file serving (/, /index.html,
        # /favicon.ico, etc.).
        return SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        if self.path == '/refresh':
            env = dict(os.environ)
            env['DASHBOARD_REGEN_ONLY'] = '1'
            try:
                result = subprocess.run(
                    ['bash', script_path, fed_dir_arg],
                    capture_output=True, text=True,
                    env=env, timeout=30,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'regen failed: {e}'.encode())
                return
            if result.returncode != 0:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                msg = (result.stderr or result.stdout or 'regen failed').strip()
                self.wfile.write(msg.encode() or b'regen failed')
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'ok')
            return

        if self.path == '/confidence':
            length = int(self.headers.get('Content-Length', '0') or '0')
            if length <= 0 or length > 4096:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'empty or oversized body')
                return
            try:
                raw = self.rfile.read(length).decode('utf-8', errors='replace')
                params = urllib.parse.parse_qs(raw, keep_blank_values=False)
            except (ValueError, UnicodeDecodeError):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'malformed form body')
                return
            agent = (params.get('agent') or [''])[0]
            value_raw = (params.get('value') or [''])[0]
            if agent not in allowed_agents:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'unknown agent: {agent!r}'.encode())
                return
            try:
                value = float(value_raw)
            except ValueError:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'value not a float: {value_raw!r}'.encode())
                return
            if not (0.0 <= value <= 1.0):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'value out of [0,1]: {value}'.encode())
                return
            try:
                result = subprocess.run(
                    ['agentis', 'memo', 'set', f'{agent}:confidence', f'{value:.3f}'],
                    capture_output=True, text=True,
                    cwd=fed_dir, timeout=10,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'exec failed: {e}'.encode())
                return
            if result.returncode != 0:
                msg = (result.stderr or result.stdout or 'memo set failed').strip()
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(msg.encode() or b'memo set failed')
                return
            audit_ok = False
            try:
                with open(confidence_log, 'a') as f:
                    f.write(json.dumps({
                        't': int(time.time()),
                        'agent': agent,
                        'value': value,
                        'remote': self.client_address[0],
                    }) + '\n')
                audit_ok = True
            except OSError:
                pass
            restart = restart_daemon(agent)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'agent': agent,
                'value': f'{value:.3f}',
                'memo_written': True,
                'audit_logged': audit_ok,
                'restart_required': not restart.get('succeeded', False),
                'restart': restart,
            }).encode())
            return

        if self.path == '/restart':
            length = int(self.headers.get('Content-Length', '0') or '0')
            if length <= 0 or length > 4096:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'empty or oversized body')
                return
            try:
                raw = self.rfile.read(length).decode('utf-8', errors='replace')
                params = urllib.parse.parse_qs(raw, keep_blank_values=False)
            except (ValueError, UnicodeDecodeError):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'malformed form body')
                return
            agent = (params.get('agent') or [''])[0]
            if agent not in allowed_agents:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'unknown agent: {agent!r}'.encode())
                return
            result = restart_daemon(agent)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
            return

        if self.path == '/quarantine':
            length = int(self.headers.get('Content-Length', '0') or '0')
            if length <= 0 or length > 4096:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'empty or oversized body')
                return
            try:
                raw = self.rfile.read(length).decode('utf-8', errors='replace')
                params = urllib.parse.parse_qs(raw, keep_blank_values=False)
            except (ValueError, UnicodeDecodeError):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'malformed form body')
                return
            agent = (params.get('agent') or [''])[0]
            if agent not in allowed_agents:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'unknown agent: {agent!r}'.encode())
                return
            daemon = find_agent_daemon(agent)
            if not daemon:
                self.send_response(404)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'no daemon found for {agent}'.encode())
                return
            agent_id = daemon.get('agent_id', '')
            try:
                result = subprocess.run(
                    ['agentis', 'daemon', 'quarantine', agent_id],
                    capture_output=True, text=True,
                    cwd=fed_dir, timeout=10,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'exec failed: {e}'.encode())
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'agent': agent,
                'agent_id': agent_id,
                'message': (result.stdout or result.stderr or 'quarantine signal sent').strip(),
            }).encode())
            return

        if self.path == '/evolve':
            length = int(self.headers.get('Content-Length', '0') or '0')
            if length <= 0 or length > 4096:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'empty or oversized body')
                return
            try:
                raw = self.rfile.read(length).decode('utf-8', errors='replace')
                params = urllib.parse.parse_qs(raw, keep_blank_values=False)
            except (ValueError, UnicodeDecodeError):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'malformed form body')
                return
            agent = (params.get('agent') or [''])[0]
            if agent not in allowed_agents:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'unknown agent: {agent!r}'.encode())
                return
            colony = agent_to_colony.get(agent, '')
            agent_file = os.path.join(fed_dir, colony, 'agents', f'{agent}.ag') if colony else ''
            if not agent_file or not os.path.isfile(agent_file):
                self.send_response(404)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'agent file not found: {agent}'.encode())
                return
            try:
                result = subprocess.run(
                    ['agentis', 'evolve', agent_file],
                    capture_output=True, text=True,
                    cwd=fed_dir, timeout=30,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'exec failed: {e}'.encode())
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'agent': agent,
                'message': (result.stdout or result.stderr or 'evolve triggered').strip(),
            }).encode())
            return

        if self.path == '/cleanup':
            length = int(self.headers.get('Content-Length', '0') or '0')
            if length <= 0 or length > 4096:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'empty or oversized body')
                return
            try:
                raw = self.rfile.read(length).decode('utf-8', errors='replace')
                params = urllib.parse.parse_qs(raw, keep_blank_values=False)
            except (ValueError, UnicodeDecodeError):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'malformed form body')
                return
            agent_id = (params.get('agent_id') or [''])[0]
            if not agent_id or len(agent_id) > 128:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'invalid agent_id')
                return
            # Validate agent_id is hex-like (prevent path traversal)
            if not all(c in '0123456789abcdefABCDEF-_' for c in agent_id):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'agent_id must be hex')
                return
            removed = cleanup_sidecars(agent_id)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'agent_id': agent_id,
                'removed': removed,
            }).encode())
            return

        if self.path == '/start':
            # #286: start-federation.sh never exits (auto-promote sidecar loops
            # forever), so subprocess.run with timeout=60 would SIGTERM it after
            # a minute and kill the 21 agents it just spawned. Detach via Popen
            # + start_new_session=True (new process group, so the HTTP handler's
            # exit doesn't take the federation down with it), return 202
            # Accepted, let operator poll `agentis daemon list` for actual
            # state.
            start_script = os.path.join(fed_dir, 'start-federation.sh')
            if not os.path.isfile(start_script):
                self.send_response(404)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'start-federation.sh not found')
                return
            try:
                logf = open('/tmp/fed-start-dashboard.log', 'ab', buffering=0)
                subprocess.Popen(
                    ['bash', start_script],
                    cwd=fed_dir,
                    stdin=subprocess.DEVNULL,
                    stdout=logf, stderr=logf,
                    start_new_session=True,
                    close_fds=True,
                )
            except OSError as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'exec failed: {e}'.encode())
                return
            self.send_response(202)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'Federation spawn initiated (detached). '
                             b'Poll agentis daemon list for agent states; '
                             b'tail /tmp/fed-start-dashboard.log for spawn output.')
            return

        if self.path == '/kill':
            # Issue #161: shell out to tools/kill-federation.sh (shipped in
            # #162) instead of the spuriously-failing `agentis daemon stop
            # --all`. Always reply with structured JSON so the dashboard
            # button label never has to be derived from server text.
            # #252: kill_script is empty when no shared-tools dir was found
            # at startup. Return a clear error rather than crashing.
            if not kill_script or not os.path.isfile(kill_script):
                self.send_response(503)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'exit': -1,
                    'summary': ('kill-federation.sh not available: no shared '
                                'tools/ found at <fed-dir>/tools or '
                                '<fed-dir>/../tools. Install the federation '
                                'bundle that ships kill-federation.sh, or '
                                'invoke it directly from a shell.'),
                    'json': None,
                    'stderr_tail': '',
                }).encode())
                return
            length = int(self.headers.get('Content-Length', '0') or '0')
            no_backup = False
            if 0 < length <= 4096:
                try:
                    raw = self.rfile.read(length).decode('utf-8', errors='replace')
                    body = json.loads(raw) if raw.strip() else {}
                    no_backup = bool(body.get('no_backup', False))
                except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
                    no_backup = False
            # --preserve-ancestors: kill-federation.sh walks its parent
            # chain and kills any ancestor that matches a kill pattern or
            # holds the dashboard port (colonies #188). That default is
            # correct for CLI callers but lethal here: this very server
            # is the ancestor, and dying mid-subprocess.run prevents the
            # JSON response from flushing. The flag reverts to
            # unconditional ancestor exclusion so the server outlives the
            # kill and can return exit/summary to the browser. Port
            # freeing requires a separate CLI invocation (documented on
            # the dashboard) — that is the /kill endpoint's contract.
            cmd = [kill_script, '--json', '--fed-dir', fed_dir,
                   '--preserve-ancestors']
            if no_backup:
                cmd.append('--no-backup')
            try:
                result = subprocess.run(
                    cmd, capture_output=True, text=True,
                    cwd=fed_dir, timeout=60,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'exit': -1,
                    'summary': f'kill-federation.sh exec failed: {e}',
                    'json': None,
                    'stderr_tail': '',
                }).encode())
                return
            stdout = result.stdout or ''
            stderr = result.stderr or ''
            # kill-federation.sh emits a single trailing JSON line on stdout.
            parsed_json = None
            for line in reversed(stdout.splitlines()):
                line = line.strip()
                if not line:
                    continue
                try:
                    parsed_json = json.loads(line)
                    break
                except (ValueError, json.JSONDecodeError):
                    continue
            exit_code = result.returncode
            if exit_code == 0:
                summary = 'Federation stopped cleanly'
            elif exit_code == 1:
                remaining = (parsed_json or {}).get('registry_remaining', '?') if parsed_json else '?'
                summary = f'Federation not fully clean (exit 1, registry_remaining={remaining})'
            elif exit_code == 2:
                summary = 'kill-federation.sh: bad invocation (exit 2)'
            else:
                summary = f'kill-federation.sh failed (exit {exit_code})'
            stderr_tail = stderr[-2048:] if len(stderr) > 2048 else stderr
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'ok': exit_code == 0,
                'exit': exit_code,
                'summary': summary,
                'json': parsed_json,
                'stderr_tail': stderr_tail,
            }).encode())
            return

        if self.path == '/cost-cap/override':
            # #318: clear cost-cap flags + restart agents to real backend.
            # Operator-facing manual reset; the sidecar normally clears
            # flags itself at UTC midnight / month boundary.
            if not cost_cap_script or not os.path.isfile(cost_cap_script):
                self.send_response(503)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'summary': ('cost-cap.sh not available: no shared tools/ '
                                'found at <fed-dir>/tools or <fed-dir>/../tools.'),
                }).encode())
                return
            length = int(self.headers.get('Content-Length', '0') or '0')
            reason = 'manual override via dashboard'
            if 0 < length <= 4096:
                try:
                    raw = self.rfile.read(length).decode('utf-8', errors='replace')
                    body = json.loads(raw) if raw.strip() else {}
                    rsn = body.get('reason')
                    if isinstance(rsn, str) and rsn.strip():
                        reason = rsn.strip()[:200]
                except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
                    pass
            try:
                result = subprocess.run(
                    [cost_cap_script, fed_dir, '--override', reason],
                    capture_output=True, text=True,
                    cwd=fed_dir, timeout=60,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'summary': f'cost-cap.sh exec failed: {e}',
                }).encode())
                return
            stderr_tail = (result.stderr or '')[-2048:]
            if result.returncode == 75:
                # cost-cap.sh:99 — sidecar lock contention on --override.
                # Surface as 409 so operators see the retry hint instead of
                # a misleading "applied" success (PR #328 LOW finding).
                self.send_response(409)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'exit': 75,
                    'summary': ('cost-cap override deferred: another '
                                'cost-cap instance is running. Retry in a '
                                'few seconds.'),
                    'stderr_tail': stderr_tail,
                    'reason': reason,
                }).encode())
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'ok': result.returncode == 0,
                'exit': result.returncode,
                'summary': ('cost-cap override applied'
                            if result.returncode == 0
                            else f'cost-cap.sh exited {result.returncode}'),
                'stderr_tail': stderr_tail,
                'reason': reason,
            }).encode())
            return

        # #352: /restart-all-stopped — bulk restart every non-running agent
        # in parallel. Walks list_daemons() vs the agent_to_colony map,
        # filters by non-running OR pid_alive=False (zombies), and shells
        # each through start-colony.sh --restart-agent <name>.
        if self.path == '/restart-all-stopped':
            stopped = []
            running_set = set()
            for d in list_daemons():
                src = d.get('source') or ''
                if not src:
                    continue
                role = os.path.basename(src)
                if role.endswith('.ag'):
                    role = role[:-3]
                pid = d.get('pid') or 0
                if d.get('state') == 'running' and pid > 0 and pid_alive(pid):
                    running_set.add(role)
            for agent in allowed_agents:
                if agent in running_set:
                    continue
                if agent_to_colony.get(agent):
                    stopped.append(agent)
            if not stopped:
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'stopped': [], 'started': [], 'failed': [],
                    'message': 'no stopped agents to restart',
                }).encode())
                return
            # Bound parallelism to os.cpu_count() or 4. Each restart calls
            # restart_daemon() which is internally synchronous (waits for
            # spawn verify) but cheap to fan out via ThreadPoolExecutor.
            from concurrent.futures import ThreadPoolExecutor
            max_workers = min(len(stopped), os.cpu_count() or 4)
            started, failed = [], []
            results = {}
            try:
                with ThreadPoolExecutor(max_workers=max_workers) as ex:
                    futures = {ex.submit(restart_daemon, a): a for a in stopped}
                    for fut in futures:
                        a = futures[fut]
                        try:
                            r = fut.result(timeout=30)
                        except Exception as e:
                            r = {'attempted': True, 'succeeded': False, 'error': str(e)}
                        results[a] = r
                        if r.get('succeeded'):
                            started.append(a)
                        else:
                            failed.append({'agent': a, 'error': r.get('error', 'unknown')})
            except Exception as e:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'stopped': stopped, 'started': started, 'failed': failed,
                    'error': str(e),
                }).encode())
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'stopped': stopped, 'started': started, 'failed': failed,
            }).encode())
            return

        # #352: /sidecar-restart — kill the named sidecar's PID and re-spawn
        # via tools/sidecar-restart.sh (extracted helper). 503 when the
        # helper is not reachable from the federation's shared tools dir.
        if self.path == '/sidecar-restart':
            if not sidecar_restart_script or not os.path.isfile(sidecar_restart_script):
                self.send_response(503)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'summary': ('sidecar-restart.sh not available: no shared '
                                'tools/ found at <fed-dir>/tools or '
                                '<fed-dir>/../tools.'),
                }).encode())
                return
            length = int(self.headers.get('Content-Length', '0') or '0')
            name = ''
            if 0 < length <= 4096:
                try:
                    raw = self.rfile.read(length).decode('utf-8', errors='replace')
                    body = json.loads(raw) if raw.strip() else {}
                    name = (body.get('name') or '').strip()
                except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
                    pass
            if name not in ('auto-promote', 'cost-cap'):
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'summary': f'unknown sidecar: {name!r}',
                }).encode())
                return
            try:
                result = subprocess.run(
                    ['bash', sidecar_restart_script, fed_dir, name],
                    capture_output=True, text=True,
                    cwd=fed_dir, timeout=60,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'summary': f'sidecar-restart.sh exec failed: {e}',
                }).encode())
                return
            self.send_response(200 if result.returncode == 0 else 500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'ok': result.returncode == 0,
                'exit': result.returncode,
                'name': name,
                'stdout': (result.stdout or '').strip()[-2048:],
                'stderr': (result.stderr or '').strip()[-2048:],
            }).encode())
            return

        # #352: /config/apply — atomic config edit + audit append. Gated
        # on `[config_editor].operator_writes_enabled = true` in the
        # federation config. Returns 503 when the gate is off.
        if self.path == '/config/apply':
            if not _read_operator_writes_enabled():
                self.send_response(503)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'summary': ('config_editor.operator_writes_enabled is '
                                'not true in <fed>/.agentis/config; the '
                                'Config tab is read-only by default.'),
                }).encode())
                return
            length = int(self.headers.get('Content-Length', '0') or '0')
            if length <= 0 or length > 65536:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'empty or oversized body')
                return
            try:
                raw = self.rfile.read(length).decode('utf-8', errors='replace')
                body = json.loads(raw)
            except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'malformed JSON body')
                return
            scope = (body.get('scope') or '').strip()
            updates = body.get('updates') or []
            if not scope or not isinstance(updates, list):
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'summary': 'scope + updates[] required',
                }).encode())
                return
            # Audit-only path for now: append every edit attempt to the
            # journal. Atomic rewrite of the target TOML file is out of
            # scope for v1 — the journal serves as the operator-visible
            # record of what would be applied.
            entries = []
            ts = int(time.time())
            for u in updates:
                entries.append({
                    'ts': ts,
                    'scope': scope,
                    'input_id': u.get('input_id'),
                    'value': u.get('value'),
                    'remote': self.client_address[0],
                })
            try:
                os.makedirs(os.path.dirname(config_audit_log), exist_ok=True)
                with open(config_audit_log, 'a') as f:
                    for e in entries:
                        f.write(json.dumps(e) + '\n')
            except OSError as e:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'summary': f'audit append failed: {e}',
                }).encode())
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'ok': True,
                'scope': scope,
                'audit_appended': len(entries),
                'audit_log_path': config_audit_log,
            }).encode())
            return

        self.send_error(404)

    def log_message(self, format, *args):
        pass

# #313 PR 1: ThreadingHTTPServer so SSE handlers (which hold their connection
# open indefinitely) don't block other endpoints. Each request gets its own
# thread; POST endpoints already shell out to subprocesses, so they're
# naturally thread-safe at the HTTP layer. daemon_threads=True so an
# Ctrl-C / SIGTERM at the wrapper level tears down lingering SSE threads
# instead of waiting for every connected browser to close.
server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
server.daemon_threads = True
server.serve_forever()
