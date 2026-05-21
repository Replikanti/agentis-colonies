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

import sys, os, subprocess, json, time, signal, shutil, shlex, threading, hashlib, urllib.parse, re
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
# #414: (colony, agent_name) → True allowlist so /restart, /quarantine,
# /evolve, /confidence can disambiguate N×same-role topologies (e.g.
# tribes-bench's 5 colonies × 1 `hunter`). Single-key `agent_to_colony`
# above is kept for back-compat with callers that still POST `agent` only
# — when no `colony` field accompanies the request we fall back to its
# (last-write-wins) lookup, matching pre-#414 behaviour for federations
# whose role names are globally unique (e.g. dev-apprenticeship).
agent_colony_pairs = {(e.get('colony',''), e.get('agent','')) for e in _map if e.get('agent')}
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


# --- Auto-regen loop (#705) ---
# Pre-fix, the wrapper spawned a `( while true; do sleep 60; generate; done ) &`
# bash subshell next to the server. SIGKILL on the wrapper left that subshell
# reparented to init, still writing snapshot.json with the pre-restart
# environment. Multiple operator restarts compounded — each spawned a fresh
# subshell on top of orphaned predecessors, racing on snapshot.json and
# flashing the banner between HEALTHY and DEGRADED. Moving the loop into a
# Python daemon thread inside the server PID ties its lifetime to the server:
# when the server process dies (SIGKILL or otherwise) the daemon thread dies
# with it, no orphan possible. Env recipe is byte-identical to the /refresh
# POST handler below so the auto-regen path sees the same STALENESS_TICKS /
# REGEN_S knobs the operator exported when launching the dashboard.
def _auto_regen():
    interval = max(10, int(os.environ.get('FEDERATION_DASHBOARD_REGEN_S', '60')))
    while True:
        time.sleep(interval)
        try:
            env = dict(os.environ)
            env['DASHBOARD_REGEN_ONLY'] = '1'
            subprocess.run(['bash', script_path, fed_dir_arg],
                           capture_output=True, env=env, timeout=30)
        except (OSError, subprocess.SubprocessError):
            pass


threading.Thread(target=_auto_regen, daemon=True).start()

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
# #357: /config/apply gate inverted from the v0.6.0 enabled-default-false
# model to a defensive opt-out. Only `operator_writes_disabled = true` in
# `<fed>/.agentis/config` flips the endpoint to 503; absent key (the
# default for every existing federation) means writes are allowed.
def _read_operator_writes_disabled():
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
                if k.strip() == 'operator_writes_disabled':
                    rv = v.strip().strip('"').strip("'").lower().split('#', 1)[0].strip()
                    return rv == 'true'
    except OSError:
        return False
    return False


# #357: line-level TOML patcher. Walks the file as a list of lines,
# tracking the current `[section]`. For each {key, value} change in the
# payload: split key on '.' (dotted path), match the deepest section that
# fits, then rewrite the matching `<bare_key> = <value>` line preserving
# any trailing inline comment. Multi-line values (arrays, inline tables
# spanning lines) bail with MultilineValueError so the operator hits 422
# instead of silent corruption — the read-only display still works for
# those keys.
SECTION_RE = re.compile(r'^\s*\[([^\]]+)\]\s*$')


class MultilineValueError(Exception):
    pass


class KeyNotFoundError(Exception):
    pass


class TypeMismatchError(Exception):
    pass


def _split_dotted_key(dotted_key, available_sections):
    """Resolve `<section>.<bare_key>` from a dotted path. The bare key is
    always the last component; everything before it must form a known
    section header (we walk from longest prefix to shortest so deeper
    sections like `forge.gitlab` win over `forge`)."""
    parts = dotted_key.split('.')
    if len(parts) == 1:
        return ('', parts[0])
    # Try longest section prefix first.
    for cut in range(len(parts) - 1, 0, -1):
        candidate = '.'.join(parts[:cut])
        if candidate in available_sections:
            return (candidate, '.'.join(parts[cut:]))
    # Fallback: assume everything except last component is the section.
    return ('.'.join(parts[:-1]), parts[-1])


def _format_toml_value(value, declared_type):
    """Render `value` (a string from JSON) into TOML. Strings get
    double-quoted (with embedded quotes / backslashes escaped); int /
    float / bool render bare. The declared_type comes from the dashboard
    inference layer so we don't have to re-guess on the server."""
    sval = str(value)
    if declared_type == 'bool':
        if sval.lower() not in ('true', 'false'):
            raise TypeMismatchError(f'expected bool, got {sval!r}')
        return sval.lower()
    if declared_type == 'int':
        try:
            int(sval)
        except (ValueError, TypeError):
            raise TypeMismatchError(f'expected int, got {sval!r}')
        return sval
    if declared_type == 'float':
        try:
            float(sval)
        except (ValueError, TypeError):
            raise TypeMismatchError(f'expected float, got {sval!r}')
        return sval
    # text / enum → double-quoted string. Escape embedded backslashes +
    # double quotes (control chars are out of scope — the dashboard
    # inputs filter them).
    escaped = sval.replace('\\', '\\\\').replace('"', '\\"')
    return f'"{escaped}"'


def _scan_sections(lines):
    """Return the set of section headers present in `lines`, for dotted-
    key resolution against multi-level sections like `forge.gitlab`."""
    sections = set()
    for line in lines:
        m = SECTION_RE.match(line)
        if m:
            sections.add(m.group(1).strip())
    return sections


def _patch_line(lines, target_section, target_key, formatted_value):
    """Find the line `<target_key> = ...` inside `[target_section]` and
    replace its value half. Returns (idx, old_value) on success. Raises
    KeyNotFoundError if the key isn't found in that section, and
    MultilineValueError when the value spans onto subsequent lines."""
    cur_section = ''
    key_re = re.compile(
        r'^(\s*' + re.escape(target_key) + r'\s*=\s*)(.*?)(\s*(?:#.*)?)$'
    )
    for idx, line in enumerate(lines):
        m_section = SECTION_RE.match(line)
        if m_section:
            cur_section = m_section.group(1).strip()
            continue
        # Skip blank / comment lines without affecting cur_section.
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        if cur_section != target_section:
            continue
        m = key_re.match(line.rstrip('\n'))
        if not m:
            continue
        prefix, value, suffix = m.group(1), m.group(2), m.group(3)
        # Multi-line detection: value starts with [ or { but doesn't
        # close on this line. We bail rather than try to round-trip.
        if value.startswith('['):
            stripped_val = value.rstrip()
            if not stripped_val.endswith(']'):
                raise MultilineValueError(target_key)
        if value.startswith('{'):
            stripped_val = value.rstrip()
            if not stripped_val.endswith('}'):
                raise MultilineValueError(target_key)
        # Preserve a trailing newline if the original line had one.
        nl = '\n' if line.endswith('\n') else ''
        lines[idx] = f'{prefix}{formatted_value}{suffix}{nl}'
        return (idx, value)
    raise KeyNotFoundError(f'{target_section!r}.{target_key!r}')


def _atomic_write(path, content):
    """Write `content` (str) to `path` atomically: temp file in the same
    dir, fsync, then rename. Same precedent as parse-toml.sh's sibling +
    federation-dashboard-renderer.py's tmp+replace pattern."""
    tmp = f'{path}.tmp.{os.getpid()}.{int(time.time() * 1000) % 1000000}'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(content)
        f.flush()
        try:
            os.fsync(f.fileno())
        except OSError:
            pass
    os.replace(tmp, path)


def _restart_colony_agents(colony_dir, agent_names):
    """Restart each agent in `agent_names` via
    `<colony_dir>/scripts/start-colony.sh --restart-agent <name>`.
    Returns a list of {agent, ok, exit, stdout, stderr} records."""
    results = []
    start_script = os.path.join(colony_dir, 'scripts', 'start-colony.sh')
    if not os.path.isfile(start_script):
        return [{'agent': n, 'ok': False, 'error': f'missing {start_script}'} for n in agent_names]
    for name in agent_names:
        try:
            r = subprocess.run(
                [start_script, '--restart-agent', name],
                capture_output=True, text=True, timeout=30,
            )
            results.append({
                'agent': name,
                'ok': r.returncode == 0,
                'exit': r.returncode,
                'stdout': (r.stdout or '').strip()[-512:],
                'stderr': (r.stderr or '').strip()[-512:],
            })
        except (OSError, subprocess.SubprocessError) as e:
            results.append({'agent': name, 'ok': False, 'error': str(e)})
    return results


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


def find_agent_daemon(agent, colony=''):
    """Return the running daemon record whose source basename matches
    <agent>.ag, or None.

    #414: when `colony` is non-empty, also require the daemon's `source`
    starts with `<colony>/agents/` so N×same-role topologies (e.g.
    tribes-bench's 5×hunter across 5 colonies) match the correct row.
    Empty `colony` keeps pre-#414 behaviour (first-running, then any-match
    by basename) — back-compat for /restart, /quarantine and /confidence
    callers that still POST `agent` alone.
    """
    ag_file = f'{agent}.ag'
    expect_prefix = f'{colony}/agents/' if colony else ''
    running = None
    any_match = None
    for d in list_daemons():
        src = d.get('source') or ''
        if not src:
            continue
        if os.path.basename(src) != ag_file:
            continue
        if expect_prefix and not src.startswith(expect_prefix):
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


def restart_daemon(agent, colony=''):
    """Stop+cleanup+respawn sequence for one agent (#137 Option 2).

    #257: spawning is delegated to <colony>/scripts/start-colony.sh
    --restart-agent <agent>. The dashboard does not parse the colony's
    TOML or construct forge-specific env vars — whatever env the colony
    needs (GITLAB_*, future GITHUB_*, etc) start-colony.sh composes
    itself. Stop + sidecar cleanup + spawn verification stay here
    because they depend only on the agentis runtime, not on the
    federation type.

    #414: when `colony` is non-empty, use it directly (lets N×same-role
    topologies disambiguate). Empty falls back to the legacy
    `agent_to_colony[agent]` lookup, preserving pre-#414 behaviour for
    federations whose role names are globally unique.
    """
    events = []

    def rec(step, status, **kw):
        entry = {'step': step, 'status': status}
        entry.update(kw)
        events.append(entry)

    if not colony:
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

    # #414: scope the lookup to this colony so an N×same-role federation
    # (e.g. tribes-bench's 5×hunter) restarts the correct daemon.
    old = find_agent_daemon(agent, colony=colony)
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
            # #414: same-role daemons in other colonies must not be
            # mistaken for "the freshly respawned one we just kicked".
            if colony and not src.startswith(f'{colony}/agents/'):
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


def _resolve_agent_colony(agent, colony):
    """#414: validate that (colony, agent) is a known pair (or, when
    `colony` is empty, that `agent` exists at all). Returns the resolved
    colony string (possibly looked up from the legacy single-key map when
    the caller omitted it), or None when the pair is unknown.

    Empty-colony callers preserve pre-#414 behaviour for federations
    whose role names are globally unique (e.g. dev-apprenticeship).
    Colony-aware callers (post-#414 dashboards) get a hard rejection on
    unknown (colony, agent) so the operator never sees a no-op restart.
    """
    if agent not in allowed_agents:
        return None
    if colony:
        if (colony, agent) not in agent_colony_pairs:
            return None
        return colony
    return agent_to_colony.get(agent, '')


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
        # #359: /log-tail/<agent_id>?lines=N — read-only tail of an agent's
        # log file from <fed>/.agentis/logs/<agent_id>.log. Used by the
        # Recovery tab's per-agent <details> expand. Defaults: 20 lines,
        # max 200 lines (defensive — log file can be megabytes). Returns
        # text/plain. 404 if the log file is missing, 400 if the agent_id
        # is structurally invalid.
        if self.path.startswith('/log-tail/'):
            tail = self.path[len('/log-tail/'):]
            qpos = tail.find('?')
            qs = ''
            if qpos >= 0:
                qs = tail[qpos + 1:]
                tail = tail[:qpos]
            agent_id = tail.strip()
            # SHA-8 lowercase hex is the daemon's canonical id; allow
            # alphanumerics + underscore + dash so a future scheme can be
            # accommodated without re-coding the gate.
            import re as _re
            if not agent_id or not _re.match(r'^[a-zA-Z0-9_\-]{1,64}$', agent_id):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'invalid agent_id')
                return
            n_lines = 20
            if 'lines=' in qs:
                try:
                    raw_n = qs.split('lines=', 1)[1].split('&', 1)[0]
                    n_lines = max(1, min(200, int(raw_n)))
                except (TypeError, ValueError):
                    n_lines = 20
            log_path = os.path.join(fed_dir, '.agentis', 'logs', agent_id + '.log')
            if not os.path.isfile(log_path):
                # Try parent-level fallback (mirrors the resolved exp_dir
                # convention used by the collector).
                log_path_alt = os.path.join(fed_dir, '..', '.agentis', 'logs',
                                            agent_id + '.log')
                if not os.path.isfile(log_path_alt):
                    self.send_response(404)
                    self.send_header('Content-Type', 'text/plain')
                    self.end_headers()
                    self.wfile.write(b'log file not found')
                    return
                log_path = log_path_alt
            try:
                # Tail-only read: seek to last ~n_lines * 4KB worth of bytes,
                # split into lines, take the last n_lines. Avoids slurping
                # gigabyte-sized log files into memory.
                size = os.path.getsize(log_path)
                read_bytes = min(size, n_lines * 4096)
                with open(log_path, 'rb') as f:
                    if size > read_bytes:
                        f.seek(size - read_bytes)
                        f.readline()  # discard partial first line
                    chunk = f.read()
                text = chunk.decode('utf-8', errors='replace')
                lines = text.splitlines()
                tail_lines = lines[-n_lines:]
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain; charset=utf-8')
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                self.wfile.write(('\n'.join(tail_lines) + '\n').encode())
            except (OSError, ValueError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'log read failed: {e}'.encode())
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
            colony = (params.get('colony') or [''])[0]
            value_raw = (params.get('value') or [''])[0]
            resolved_colony = _resolve_agent_colony(agent, colony)
            if resolved_colony is None:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                if colony:
                    self.wfile.write(f'unknown (colony, agent): ({colony!r}, {agent!r})'.encode())
                else:
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
            restart = restart_daemon(agent, colony=resolved_colony)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'agent': agent,
                'colony': resolved_colony,
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
            colony = (params.get('colony') or [''])[0]
            resolved_colony = _resolve_agent_colony(agent, colony)
            if resolved_colony is None:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                if colony:
                    self.wfile.write(f'unknown (colony, agent): ({colony!r}, {agent!r})'.encode())
                else:
                    self.wfile.write(f'unknown agent: {agent!r}'.encode())
                return
            result = restart_daemon(agent, colony=resolved_colony)
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
            colony = (params.get('colony') or [''])[0]
            resolved_colony = _resolve_agent_colony(agent, colony)
            if resolved_colony is None:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                if colony:
                    self.wfile.write(f'unknown (colony, agent): ({colony!r}, {agent!r})'.encode())
                else:
                    self.wfile.write(f'unknown agent: {agent!r}'.encode())
                return
            daemon = find_agent_daemon(agent, colony=resolved_colony)
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
            colony = (params.get('colony') or [''])[0]
            resolved_colony = _resolve_agent_colony(agent, colony)
            if resolved_colony is None:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                if colony:
                    self.wfile.write(f'unknown (colony, agent): ({colony!r}, {agent!r})'.encode())
                else:
                    self.wfile.write(f'unknown agent: {agent!r}'.encode())
                return
            agent_file = os.path.join(fed_dir, resolved_colony, 'agents', f'{agent}.ag') if resolved_colony else ''
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

        # #352 (rewritten in #357): /config/apply — line-level TOML
        # patcher with drift detection + atomic write + per-change audit
        # append + restart of affected agents. Editable by default; the
        # `[config_editor].operator_writes_disabled = true` gate flips
        # back to 503.
        if self.path == '/config/apply':
            if _read_operator_writes_disabled():
                self.send_response(503)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'summary': ('config_editor.operator_writes_disabled is '
                                'true in <fed>/.agentis/config; the '
                                'Config tab is locked.'),
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
            # #359: dual-mode payload. Single-scope (legacy):
            #   {scope: <name>, mtime_ms: <int>, changes: [{key,value,type}]}
            # Multi-scope (bulk apply):
            #   {scopes: [<n1>, <n2>, ...], mtime_ms: <int>,
            #    changes: [{key,value,type}]}
            # The bulk path loops over scopes and reuses the same line-level
            # patcher per scope. Each scope's file write is atomic; the
            # cross-scope apply is best-effort and the response surfaces
            # `applied_scopes: [...]` + `failed_scopes: [{scope, reason}]`.
            scope = (body.get('scope') or '').strip()
            scopes_list = body.get('scopes')
            changes = body.get('changes')
            mtime_ms = body.get('mtime_ms') or 0
            try:
                mtime_ms = int(mtime_ms)
            except (ValueError, TypeError):
                mtime_ms = 0
            # If `scopes` is provided + non-empty, dispatch to the
            # multi-scope path early so we return a single aggregated
            # response. Otherwise fall through to single-scope (back-compat).
            if (isinstance(scopes_list, list) and scopes_list
                    and isinstance(changes, list) and changes):
                return self._apply_config_multi(
                    scopes_list, changes, fed_dir, config_audit_log,
                )
            if not scope or not isinstance(changes, list) or not changes:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'summary': ('scope + changes[] (with at least one entry) '
                                'OR scopes:[...] + changes[] required'),
                }).encode())
                return
            # Resolve target file. scope = "fed" or "federation" → fed-
            # wide config; anything else → <fed>/<scope>/config/colony.toml.
            if scope in ('fed', 'federation'):
                target_path = os.path.join(fed_dir, '.agentis', 'config')
                target_colony = ''
            else:
                target_path = os.path.join(fed_dir, scope, 'config', 'colony.toml')
                target_colony = scope
            if not os.path.isfile(target_path):
                self.send_response(404)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'summary': f'target file not found: {target_path}',
                }).encode())
                return
            # Drift check. Compare on-disk mtime (ms-precision) against
            # the payload's snapshot mtime; reject 409 if disk is newer.
            try:
                disk_mtime_ms = int(os.path.getmtime(target_path) * 1000)
            except OSError as e:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'ok': False, 'summary': f'stat failed: {e}'}).encode())
                return
            if mtime_ms and disk_mtime_ms > mtime_ms:
                self.send_response(409)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'drift': True,
                    'current_mtime_ms': disk_mtime_ms,
                    'payload_mtime_ms': mtime_ms,
                    'summary': 'file changed externally since the dashboard read it',
                }).encode())
                return
            # Read source as a list of lines. Walk + patch atomically:
            # all changes succeed or none. Multiple changes in one apply
            # patch the in-memory list in sequence; we only write back
            # once at the end.
            try:
                with open(target_path, encoding='utf-8') as f:
                    lines = f.readlines()
            except OSError as e:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'ok': False, 'summary': f'read failed: {e}'}).encode())
                return
            sections_present = _scan_sections(lines)
            applied = []
            try:
                for change in changes:
                    if not isinstance(change, dict):
                        raise TypeMismatchError('change entries must be objects')
                    dotted_key = (change.get('key') or '').strip()
                    declared_type = (change.get('type') or 'text').strip().lower()
                    new_value = change.get('value')
                    if not dotted_key or new_value is None:
                        raise TypeMismatchError(
                            f'change missing key or value: {change!r}'
                        )
                    target_section, bare_key = _split_dotted_key(
                        dotted_key, sections_present,
                    )
                    formatted = _format_toml_value(new_value, declared_type)
                    idx, old_value = _patch_line(
                        lines, target_section, bare_key, formatted,
                    )
                    applied.append({
                        'key': dotted_key,
                        'section': target_section,
                        'bare_key': bare_key,
                        'old_value': old_value.strip(),
                        'new_value': str(new_value),
                        'line': idx + 1,
                    })
            except MultilineValueError as e:
                self.send_response(422)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'error': 'value spans multiple lines; not supported by line-level patcher',
                    'key': str(e),
                }).encode())
                return
            except KeyNotFoundError as e:
                self.send_response(422)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'error': 'key not found in target file',
                    'key': str(e),
                }).encode())
                return
            except TypeMismatchError as e:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'error': str(e),
                }).encode())
                return
            # All-or-nothing write. Atomic temp+rename keeps the file
            # consistent if the box loses power mid-apply.
            try:
                _atomic_write(target_path, ''.join(lines))
            except OSError as e:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'summary': f'atomic write failed: {e}',
                }).encode())
                return
            # Audit append — one row per applied change.
            ts = int(time.time())
            entries = []
            for a in applied:
                entries.append({
                    'ts': ts,
                    'scope': scope,
                    'key': a['key'],
                    'old_value': a['old_value'],
                    'new_value': a['new_value'],
                    'line': a['line'],
                    'remote': self.client_address[0],
                })
            try:
                os.makedirs(os.path.dirname(config_audit_log), exist_ok=True)
                with open(config_audit_log, 'a') as f:
                    for e in entries:
                        f.write(json.dumps(e) + '\n')
            except OSError as exc:
                # Audit failure is non-fatal — the write already
                # succeeded; surface it in the response so operators
                # know the trail is incomplete.
                pass
            # Restart trigger — restart every agent in the affected
            # colony (or every agent in every colony for fed-wide).
            restart_results = []
            try:
                if target_colony:
                    colony_dir = os.path.join(fed_dir, target_colony)
                    agents_dir = os.path.join(colony_dir, 'agents')
                    if os.path.isdir(agents_dir):
                        names = sorted(
                            f[:-3] for f in os.listdir(agents_dir)
                            if f.endswith('.ag')
                        )
                        restart_results = _restart_colony_agents(colony_dir, names)
                else:
                    # fed-wide: walk every colony with a start-colony.sh.
                    for entry in sorted(os.listdir(fed_dir)):
                        sub = os.path.join(fed_dir, entry)
                        if not os.path.isdir(sub):
                            continue
                        agents_dir = os.path.join(sub, 'agents')
                        if not os.path.isdir(agents_dir):
                            continue
                        names = sorted(
                            f[:-3] for f in os.listdir(agents_dir)
                            if f.endswith('.ag')
                        )
                        restart_results.extend(
                            _restart_colony_agents(sub, names)
                        )
            except OSError:
                pass
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'ok': True,
                'scope': scope,
                'applied': applied,
                'restart_results': restart_results,
                'audit_log_path': config_audit_log,
                'new_mtime_ms': int(os.path.getmtime(target_path) * 1000),
            }).encode())
            return

        self.send_error(404)

    # #359: bulk /config/apply helper. Loops over the requested scopes,
    # reusing the same single-scope line-level patcher logic for each.
    # Best-effort: a per-scope failure does NOT abort the rest. Returns
    # a 200 if at least one scope succeeded, 207 if all scopes failed
    # (so the dashboard can surface partial-success without an error
    # toast). Each scope's file write is atomic; the cross-scope apply
    # is intentionally NOT wrapped in a single transaction (mtime drift
    # on one colony shouldn't roll back a clean apply on the others).
    def _apply_config_multi(self, scopes, changes, fed_dir_arg, audit_log):
        if _read_operator_writes_disabled():
            self.send_response(503)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'ok': False,
                'summary': ('config_editor.operator_writes_disabled is '
                            'true; the Config tab is locked.'),
            }).encode())
            return
        applied_scopes = []
        failed_scopes = []
        per_scope_results = {}
        for scope_name in scopes:
            scope_name = (scope_name or '').strip()
            if not scope_name:
                failed_scopes.append({'scope': '', 'reason': 'empty scope'})
                continue
            if scope_name in ('fed', 'federation'):
                target_path = os.path.join(fed_dir_arg, '.agentis', 'config')
                target_colony = ''
            else:
                target_path = os.path.join(fed_dir_arg, scope_name,
                                           'config', 'colony.toml')
                target_colony = scope_name
            if not os.path.isfile(target_path):
                failed_scopes.append({
                    'scope': scope_name,
                    'reason': f'target file not found: {target_path}',
                })
                continue
            # Read source as a list of lines. Patch in-memory, write back
            # atomically. Mirrors the single-scope path but trimmed of
            # the per-scope error responses (we collect into the
            # aggregated response instead).
            try:
                with open(target_path, encoding='utf-8') as f:
                    lines = f.readlines()
            except OSError as e:
                failed_scopes.append({
                    'scope': scope_name,
                    'reason': f'read failed: {e}',
                })
                continue
            sections_present = _scan_sections(lines)
            applied_here = []
            try:
                for change in changes:
                    if not isinstance(change, dict):
                        raise TypeMismatchError('change entries must be objects')
                    dotted_key = (change.get('key') or '').strip()
                    declared_type = (change.get('type') or 'text').strip().lower()
                    new_value = change.get('value')
                    if not dotted_key or new_value is None:
                        raise TypeMismatchError(
                            f'change missing key or value: {change!r}'
                        )
                    target_section, bare_key = _split_dotted_key(
                        dotted_key, sections_present,
                    )
                    formatted = _format_toml_value(new_value, declared_type)
                    idx, old_value = _patch_line(
                        lines, target_section, bare_key, formatted,
                    )
                    applied_here.append({
                        'key': dotted_key,
                        'section': target_section,
                        'bare_key': bare_key,
                        'old_value': old_value.strip(),
                        'new_value': str(new_value),
                        'line': idx + 1,
                    })
            except (MultilineValueError, KeyNotFoundError,
                    TypeMismatchError) as e:
                failed_scopes.append({
                    'scope': scope_name,
                    'reason': type(e).__name__ + ': ' + str(e),
                })
                continue
            try:
                _atomic_write(target_path, ''.join(lines))
            except OSError as e:
                failed_scopes.append({
                    'scope': scope_name,
                    'reason': f'atomic write failed: {e}',
                })
                continue
            ts_now = int(time.time())
            try:
                os.makedirs(os.path.dirname(audit_log), exist_ok=True)
                with open(audit_log, 'a') as af:
                    for a in applied_here:
                        af.write(json.dumps({
                            'ts': ts_now,
                            'scope': scope_name,
                            'key': a['key'],
                            'old_value': a['old_value'],
                            'new_value': a['new_value'],
                            'line': a['line'],
                            'remote': self.client_address[0],
                            'bulk': True,
                        }) + '\n')
            except OSError:
                pass
            # Restart trigger — same convention as single-scope.
            restart_results = []
            try:
                if target_colony:
                    colony_dir = os.path.join(fed_dir_arg, target_colony)
                    agents_dir = os.path.join(colony_dir, 'agents')
                    if os.path.isdir(agents_dir):
                        names = sorted(
                            f[:-3] for f in os.listdir(agents_dir)
                            if f.endswith('.ag')
                        )
                        restart_results = _restart_colony_agents(
                            colony_dir, names,
                        )
                else:
                    for entry in sorted(os.listdir(fed_dir_arg)):
                        sub = os.path.join(fed_dir_arg, entry)
                        if not os.path.isdir(sub):
                            continue
                        agents_dir = os.path.join(sub, 'agents')
                        if not os.path.isdir(agents_dir):
                            continue
                        names = sorted(
                            f[:-3] for f in os.listdir(agents_dir)
                            if f.endswith('.ag')
                        )
                        restart_results.extend(
                            _restart_colony_agents(sub, names)
                        )
            except OSError:
                pass
            applied_scopes.append(scope_name)
            per_scope_results[scope_name] = {
                'applied': applied_here,
                'restart_results': restart_results,
                'new_mtime_ms': int(os.path.getmtime(target_path) * 1000),
            }
        # 200 if anything succeeded; 207 (Multi-Status, repurposed
        # informally) if every scope failed so the operator can see the
        # per-scope reasons without a generic 500 / 400.
        if applied_scopes:
            status_code = 200
        else:
            status_code = 207
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({
            'ok': bool(applied_scopes),
            'applied_scopes': applied_scopes,
            'failed_scopes': failed_scopes,
            'per_scope': per_scope_results,
            'audit_log_path': audit_log,
        }).encode())

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
