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
#                        kill-federation.sh and resolve-tick-interval.py.
#                        Empty disables /kill and falls back to default tick.

import sys, os, subprocess, json, time, signal, shutil, shlex, threading, re, urllib.parse
from http.server import HTTPServer, SimpleHTTPRequestHandler

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
# #252: helpers live in the federation's shared tools dir, not next to this
# script (the dashboard is a separately-versioned standalone component now).
# The entry script resolves <fed-dir>/tools/ then <fed-dir>/../tools/ and
# passes the result in argv[7]. Empty means no shared tools were found —
# /kill returns a clear error, resolve_tick_interval falls back to 60000.
_resolver_script = os.path.join(fed_tools_dir, 'resolve-tick-interval.py') if fed_tools_dir else ''
kill_script = os.path.join(fed_tools_dir, 'kill-federation.sh') if fed_tools_dir else ''


def resolve_tick_interval(agent, colony_dir):
    """Return tick interval (str, ms) for *agent* using resolve-tick-interval.py.

    Falls back to '60000' if the resolver is missing or fails.
    """
    try:
        r = subprocess.run(
            [sys.executable, _resolver_script, agent, colony_dir],
            capture_output=True, text=True, timeout=5,
        )
        val = r.stdout.strip()
        return val if r.returncode == 0 and val.isdigit() else '60000'
    except (OSError, subprocess.SubprocessError):
        return '60000'


def parse_toml_section(toml_path, section):
    """Extract key=value pairs under [section] from a colony TOML file."""
    out = {}
    try:
        with open(toml_path, 'r', encoding='utf-8') as f:
            in_section = False
            for raw in f:
                line = raw.rstrip('\n')
                stripped_chars = []
                quote = None
                i = 0
                while i < len(line):
                    ch = line[i]
                    if quote:
                        stripped_chars.append(ch)
                        if ch == '\\' and i + 1 < len(line):
                            stripped_chars.append(line[i + 1])
                            i += 2
                            continue
                        if ch == quote:
                            quote = None
                    else:
                        if ch == '#':
                            break
                        if ch in ('"', "'"):
                            quote = ch
                        stripped_chars.append(ch)
                    i += 1
                s = ''.join(stripped_chars).strip()
                if not s:
                    continue
                if s.startswith('[') and s.endswith(']'):
                    in_section = (s[1:-1].strip() == section)
                    continue
                if not in_section or '=' not in s:
                    continue
                k, _, v = s.partition('=')
                k = k.strip()
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
                    v = v[1:-1]
                out[k] = v
    except OSError:
        pass
    return out


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
    """Single-line respawn command the operator can paste if auto-restart fails."""
    agent_name = os.path.basename(agent_file)
    if agent_name.endswith('.ag'):
        agent_name = agent_name[:-3]
    tick = resolve_tick_interval(agent_name, colony_dir)
    env_refs = (
        'GITLAB_URL="$GITLAB_URL" GITLAB_TOKEN="$GITLAB_TOKEN" '
        'GITLAB_PROJECT="$GITLAB_PROJECT" GITLAB_ME="$GITLAB_ME" '
        f'COLONY_DIR={shlex.quote(colony_dir)}'
    )
    return (
        f'cd {shlex.quote(colony_dir)} && '
        f'{env_refs} '
        f'agentis daemon {shlex.quote(agent_file)}'
        f' --colony {shlex.quote(colony)}'
        f' --enable-exec --enable-messaging --tick-interval {tick} &'
    )


def restart_daemon(agent):
    """Stop+cleanup+respawn sequence for one agent (#137 Option 2)."""
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

    config_path = os.path.join(colony_dir, 'config', 'colony.toml')
    gitlab = parse_toml_section(config_path, 'gitlab')
    gl_url = gitlab.get('url', '')
    gl_token = gitlab.get('token', '')
    gl_project_raw = gitlab.get('project', '')
    if not gl_url or not gl_token or not gl_project_raw:
        rec('config', 'error',
            message=f'incomplete [gitlab] in {config_path}: '
                    f'url={bool(gl_url)} token={bool(gl_token)} project={bool(gl_project_raw)}')
        return {
            'attempted': False, 'succeeded': False,
            'error': f'incomplete [gitlab] section in {config_path}',
            'events': events,
        }
    gl_me = gitlab.get('me', '')
    gl_project = gl_project_raw.replace('/', '%2F')
    env_overrides = {
        'GITLAB_URL': gl_url,
        'GITLAB_TOKEN': gl_token,
        'GITLAB_PROJECT': gl_project,
        'GITLAB_ME': gl_me,
        'COLONY_DIR': colony_dir,
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

    # Respawn detached so the dashboard process can die without taking
    # the fresh daemon with it.
    tick = resolve_tick_interval(agent, colony_dir)
    rec('spawn', 'start', tick_interval=tick)
    env = dict(os.environ)
    env.update(env_overrides)
    spawn_ts = int(time.time())
    try:
        proc = subprocess.Popen(
            [
                'agentis', 'daemon', agent_file,
                '--colony', colony,
                '--enable-exec',
                '--enable-messaging',
                '--tick-interval', tick,
            ],
            cwd=colony_dir,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
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
    rec('spawn', 'ok', launcher_pid=proc.pid, spawn_ts=spawn_ts)

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
        code = proc.poll()
        threading.Thread(target=proc.wait, daemon=True).start()
        rec('verify', 'error',
            message=f'new daemon not registered within 15s (launcher exit={code})')
        return {
            'attempted': True, 'succeeded': False,
            'error': 'new daemon not registered within 15s',
            'manual_command': manual_cmd,
            'events': events,
        }

    threading.Thread(target=proc.wait, daemon=True).start()

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

class Handler(SimpleHTTPRequestHandler):
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
            # Start federation: look for start-federation.sh in fed_dir
            start_script = os.path.join(fed_dir, 'start-federation.sh')
            if not os.path.isfile(start_script):
                self.send_response(404)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'start-federation.sh not found')
                return
            try:
                result = subprocess.run(
                    ['bash', start_script],
                    capture_output=True, text=True,
                    cwd=fed_dir, timeout=60,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'exec failed: {e}'.encode())
                return
            out = (result.stdout or '').strip()
            err = (result.stderr or '').strip()
            if result.returncode != 0:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                msg = (err or out or 'start-federation.sh failed').strip()
                self.wfile.write(msg.encode() or b'start-federation.sh failed')
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write((out + ('\n' + err if err else '') or 'Federation started').encode())
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

        self.send_error(404)

    def log_message(self, format, *args):
        pass

HTTPServer(('127.0.0.1', port), Handler).serve_forever()
