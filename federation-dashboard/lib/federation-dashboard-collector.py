#!/usr/bin/env python3
# federation-dashboard-collector.py: collects per-agent enriched data
# (experience stats, .ag descriptions, log lines, PID liveness, event
# timeline, confidence change history) and prints a single JSON blob to
# stdout for federation-dashboard.sh to embed in the served HTML.
#
# Extracted from federation-dashboard.sh in #170 to fix a macOS bash
# heredoc-in-$() parser bug. DO NOT inline this back into the shell
# script — bash 3.2 (macOS default) does not fully honor single-quoted
# heredoc delimiters when the heredoc is nested inside $(), causing
# backticks in Python comments to be evaluated as command substitutions
# and re-parsing the heredoc body as bash code at runtime.
#
# Args (positional):
#   1: daemons_json        — JSON array from `agentis daemon list --json`,
#                            or "@<path>" to read from file (#293 — bypass
#                            Linux MAX_ARG_STRLEN once the federation grows
#                            past ~21 daemons and the JSON blob crosses the
#                            128 KB per-argv-string cap).
#   2: agent_map_json      — JSON array of {agent, colony} pairs
#   3: fed_dir             — federation root directory
#   4: epoch               — current epoch seconds
#   5: exp_dir             — .agentis/experience/ path
#   6: log_dir             — .agentis/logs/ path
#   7: dash_dir            — federation-dashboard cache dir
#   8: colony_list_json    — JSON array of colony names
#   9: fed_tools_dir       — federation shared-tools dir (or empty); used to
#                            locate auto-promote-decisions.py + config (#252)
#   10..: all_agents       — agent names (one per positional arg)

import sys, os, json, time, re, datetime, subprocess

# #683: number of `tick_interval` periods of `<agent>:last_check` staleness
# tolerated before a daemon's `pid_alive` flips to false. Replaces the PID-
# based `os.kill(pid, 0)` liveness probe, which produced false DEGRADED
# bannering on containerized federations (`research-foundry`,
# `tribes-bench`) where the dashboard runs outside the container's PID
# namespace and cannot see the agent PIDs at all. Memo freshness is
# namespace-independent: every tick writes `<agent>:last_check`, so
# `now - last_check < STALENESS_TICKS * tick_interval` is a reliable
# liveness predicate on every deployment topology.
#
# #700: env-configurable so listen-driven federations (e.g.
# `research-foundry`'s long-poll `listen()` cadence, where ticks can
# legitimately go quiet for minutes between events) can widen the window
# without code change. #716: default raised from `3` to `15` after the
# Run #14 forensic showed listen-driven explorers hitting the promote-tier
# cascade SKIP path during legitimate quiet windows. `15` covers the
# documented ~10-minute quiet window on both 60s and 120s ticks; operators
# wanting tighter classification keep the env override.
# Clamped to >= 1 so a misconfigured `0` cannot turn every agent
# permanently stale.
#
# #736: per-role staleness window now lives in the shared
# tools/agentis_memo_freshness.py module (STALENESS_TICKS_BY_ROLE +
# staleness_ticks_for()). The global STALENESS_TICKS below is retained
# only as a safe-default fallback for the missing-helper case (older
# federation install without the shared module).
try:
    STALENESS_TICKS = max(1, int(os.environ.get("FEDERATION_DASHBOARD_STALENESS_TICKS", "15")))
except (TypeError, ValueError):
    STALENESS_TICKS = 15

def _read(arg):
    """Resolve `@<path>` argv prefix to file contents; otherwise pass through."""
    if arg.startswith('@'):
        with open(arg[1:], 'r', encoding='utf-8') as f:
            return f.read()
    return arg

daemons_json   = _read(sys.argv[1])
agent_map_json = sys.argv[2]
fed_dir        = sys.argv[3]
epoch          = int(sys.argv[4])
exp_dir        = sys.argv[5]
log_dir        = sys.argv[6]
dash_dir       = sys.argv[7]
colony_list_json = sys.argv[8]
fed_tools_dir  = sys.argv[9]
all_agents     = sys.argv[10:]

# #709: memo-freshness helpers (read_memo_raw / parse_last_check_epoch /
# resolve_tick_interval_ms / STALENESS_TICKS) live in the shared
# tools/agentis_memo_freshness.py module so this collector and
# tools/auto-promote-decisions.py consume the single source of truth
# instead of mirroring the implementation (former drift documented in
# #683/#697/#700/#705/#706/#708). The federation's shared-tools dir is
# already passed as argv[9] -- we route the import via that path. If the
# helper module is missing (older federation install), `freshness` stays
# None and every daemon collapses to `pid_alive=false`, matching the
# pre-existing missing-helper safe-default contract.
if fed_tools_dir and fed_tools_dir not in sys.path:
    sys.path.insert(0, fed_tools_dir)
try:
    import agentis_memo_freshness as freshness
except ImportError:
    freshness = None

def safe_json(s, default):
    try: return json.loads(s or '[]')
    except (json.JSONDecodeError, TypeError, ValueError): return default

daemons    = safe_json(daemons_json, [])
agent_map  = safe_json(agent_map_json, [])
colonies   = safe_json(colony_list_json, [])

# #412: index agent records by `(colony, role)` tuple instead of `role`
# alone. Federations like `tribes-bench` run N colonies × 1 same-named
# agent each (5 colonies × `hunter`), and a single-key map collapses the
# N records into one — the per-agent table then renders 1 row instead of
# N. Tuple keying preserves one record per (colony, agent_name) pair.
# Federations with globally-unique agent names (e.g. `dev-apprenticeship`'s
# 21 agents) are unaffected: every (colony, name) pair already maps to a
# distinct entry under either keying.
#
# `name_to_colony` is preserved as a plain dict for backward compatibility
# with the spend / lifecycle / id_to_role lookups below — those paths
# resolve agent_id → role first, and collisions on `role` there are
# benign (each agent_id is globally unique). The rendering loop uses
# `agent_map` (list of {agent, colony} pairs) directly to iterate one
# record per (colony, agent_name) pair without losing the colony binding.
name_to_colony = {}
for e in agent_map:
    a = e.get('agent', '')
    c = e.get('colony', '')
    # First-seen wins — keep deterministic for downstream consumers that
    # only need a single colony per role (id_to_role / spend bucketing).
    if a and a not in name_to_colony:
        name_to_colony[a] = c

# #316 M5a: pre-compute multi-repo expansion per colony.
# Each colony's `start-colony.sh --print-repos-json` echoes the
# `GITHUB_REPOS_JSON` env value the script would export under the
# multi-block `[[forge.github]]` configuration shape, or empty for
# legacy single-block configs. Parsed once here so the rate-limit
# loop and the per-agent confidence overlay below can both reuse the
# answer without re-spawning subprocesses. Empty list means "single-
# block / N=1 / no GitHub backend" — every downstream call site MUST
# fall back to the legacy single-record behaviour for byte-identity.
repos_for_colony = {}
for colony in colonies:
    repos_for_colony[colony] = []
    script = os.path.join(fed_dir, colony, 'scripts', 'start-colony.sh')
    if not os.path.isfile(script):
        continue
    try:
        probe = subprocess.run(
            ['bash', script, '--print-repos-json'],
            capture_output=True, text=True, timeout=5,
        )
    except (subprocess.SubprocessError, OSError):
        continue
    if probe.returncode != 0:
        continue
    raw = (probe.stdout or '').strip()
    if not raw:
        continue
    try:
        repos = json.loads(raw)
    except json.JSONDecodeError:
        continue
    if not isinstance(repos, list):
        continue
    for entry in repos:
        if not isinstance(entry, dict):
            continue
        owner = str(entry.get('owner') or '').strip()
        repo  = str(entry.get('repo')  or '').strip()
        if owner and repo:
            repos_for_colony[colony].append((owner, repo))

# Build (colony, role) -> daemon mapping from daemon list source field.
# #412: tuple keying so federations with N colonies × 1 same-named agent
# (e.g. `tribes-bench` with 5 × `hunter`) keep one daemon record per
# colony instead of collapsing all N into the last-seen entry. The colony
# half comes from the `source` field's parent directory
# (`tribe-alpha/agents/hunter.ag` → colony `tribe-alpha`, role `hunter`);
# legacy single-segment sources fall back to the colony from `name_to_colony`
# / a blank string so federations whose daemons predate the multi-segment
# source convention still render a usable record.
role_to_daemon = {}
id_to_role = {}
# #412: agent_id → colony lookup, used by the spend / cost aggregation
# below to resolve a daemon's owning colony without going through the
# (now-tuple) role_to_daemon map. agent_id is globally unique, so this
# stays a flat dict.
id_to_colony = {}
for d in daemons:
    src = d.get('source') or ''
    if not src:
        continue
    role = os.path.basename(src)
    if role.endswith('.ag'):
        role = role[:-3]
    # Derive colony from source path: `<colony>/agents/<role>.ag` → `<colony>`.
    parts = src.split('/')
    daemon_colony = ''
    if len(parts) >= 3 and parts[-2] == 'agents':
        daemon_colony = parts[-3]
    if not daemon_colony:
        daemon_colony = name_to_colony.get(role, '')
    role_to_daemon[(daemon_colony, role)] = d
    aid = d.get('agent_id') or ''
    if aid:
        # id_to_role stays role-only (each agent_id is globally unique, no
        # collision risk) — used by spend / lifecycle bucketing where the
        # downstream consumers expect a bare role string.
        id_to_role[aid] = role
        id_to_colony[aid] = daemon_colony

result = []
total_exp = 0
colony_exp = {c: 0 for c in colonies}

# #412: iterate over `agent_map` (the per-(colony, agent) records the
# entry script builds from the on-disk colony×agents/*.ag tree) instead
# of the flat `all_agents` list, so each (colony, agent_name) pair gets
# its own record. The flat list is preserved for backward compat with
# callers that drive the collector directly (e.g. fixture tests) — when
# `agent_map` is empty we fall back to the legacy single-record-per-name
# iteration to keep that path byte-identical.
agent_pairs = []
for e in agent_map:
    a = e.get('agent', '')
    c = e.get('colony', '')
    if a:
        agent_pairs.append((c, a))
if not agent_pairs:
    # Legacy fallback: synthesize pairs from the flat list using the
    # single-key colony map (same behaviour as pre-#412).
    seen = set()
    for a in all_agents:
        if a in seen:
            continue
        seen.add(a)
        agent_pairs.append((name_to_colony.get(a, ''), a))

for colony, agent in agent_pairs:
    daemon = role_to_daemon.get((colony, agent))

    rec = {
        'name': agent, 'colony': colony,
        'confidence': None, 'confidence_generation': None,
        'confidence_written_at': None,
        'health': 'unknown', 'state': 'stopped',
        'pid': 0, 'pid_alive': False,
        'is_running': False,
        'agent_id': '', 'started_at': 0, 'quarantine': '',
        'tick_ok': 0, 'tick_err': 0,
        'experience_count': 0, 'experience_rate': 0.0,
        'experience_outcomes': {'success': 0, 'failure': 0, 'no-op': 0},
        'experience_variance': None, 'experience_slope_recent': None,
        'fitness_window': 0,
        'last_action': '', 'last_action_ts': 0,
        'description': '',
        'recent_experience': [], 'recent_logs': [],
        'source': '',
        'confidence_gates': [], 'confidence_cap': None,
        'agent_last_ok_ts': 0,
    }

    if daemon:
        rec['confidence'] = daemon.get('confidence')
        rec['confidence_generation'] = daemon.get('confidence_generation')
        rec['confidence_written_at'] = daemon.get('confidence_written_at')
        rec['health'] = daemon.get('health') or 'unknown'
        rec['state'] = daemon.get('state') or 'unknown'
        rec['pid'] = daemon.get('pid') or 0
        rec['agent_id'] = daemon.get('agent_id') or ''
        rec['started_at'] = daemon.get('started_at') or 0
        rec['quarantine'] = daemon.get('quarantine') or ''
        rec['source'] = daemon.get('source') or ''
        rec['tick_ok'] = daemon.get('tick_ok') or daemon.get('ticks_ok') or 0
        rec['tick_err'] = daemon.get('tick_err') or daemon.get('ticks_err') or 0
        # #683: replace PID-based liveness (`os.kill(pid, 0)`) with a
        # memo-freshness check on `<agent>:last_check`. The old probe
        # required the dashboard to share a PID namespace with the
        # daemons, which is false on containerized federations
        # (`research-foundry`, `tribes-bench`) — every PID looked dead
        # from the host and the banner flipped to DEGRADED even when the
        # agents were ticking happily inside the container. Memo
        # freshness is namespace-independent and uses the canonical
        # `memo_write("<agent>:last_check", now)` that every `.ag` agent
        # already writes at the end of every tick (e.g.
        # `research-foundry/formulator/agents/formulator.ag:448`,
        # `tribes-bench/tribe-alpha/agents/hunter.ag:1438`). Per-repo
        # fallback (`<owner>__<repo>:<agent>:last_check`) mirrors the
        # confidence overlay fan-out for multi-repo colonies that scope
        # memos per repo; the freshest record across the per-repo set
        # wins. Bare key first, per-repo only when bare missing AND the
        # colony actually has repos. Field name `pid_alive` preserved so
        # the template + `is_running` derivation stay byte-identical.
        last_check_epoch = None
        bare_raw = freshness.read_memo_raw(fed_dir, agent + ':last_check') if freshness else None
        last_check_epoch = freshness.parse_last_check_epoch(bare_raw) if freshness else None
        if last_check_epoch is None:
            repos = repos_for_colony.get(colony, [])
            if repos:
                per_repo_max = None
                for owner, repo in repos:
                    pr_key = '%s__%s:%s:last_check' % (owner, repo, agent)
                    pr_raw = freshness.read_memo_raw(fed_dir, pr_key) if freshness else None
                    pr_epoch = freshness.parse_last_check_epoch(pr_raw) if freshness else None
                    if pr_epoch is not None:
                        if per_repo_max is None or pr_epoch > per_repo_max:
                            per_repo_max = pr_epoch
                last_check_epoch = per_repo_max
        if last_check_epoch is not None:
            tick_interval_ms = freshness.resolve_tick_interval_ms(agent, colony, fed_dir=fed_dir, fed_tools_dir=fed_tools_dir) if freshness else 60000
            # #736: per-role staleness window (tick-driven 5, listen-driven 60,
            # dev-apprenticeship 30, unknown roles fall back to global 15).
            # Missing-helper fallback keeps the global STALENESS_TICKS=15.
            role_ticks = freshness.staleness_ticks_for(agent) if freshness else STALENESS_TICKS
            window_seconds = role_ticks * (tick_interval_ms / 1000.0)
            rec['pid_alive'] = (epoch - last_check_epoch) < window_seconds
        else:
            rec['pid_alive'] = False
        # Heartbeat-file fallback for containerized federations. Mirrors the
        # auto-promote sidecar fix (PR #799). The `.ag` convention
        # `memo_write("<agent>:last_check", now)` at end-of-tick is
        # unreliable -- many tick bodies short-circuit before reaching the
        # write site (missing-upstream picker-empty paths, tier branches
        # that bail early, `exec sh` failures on the `date -u +%Y-...`
        # helper). Concrete reproducer: noticer.ag wrote 20 last_check
        # entries across 118 actual ticks (~17% coverage) during the
        # post-#798 claude run, while the runtime's per-tick heartbeat
        # file kept perfect coverage. The dashboard was therefore showing
        # "18 daemons with dead PID" while every daemon was alive and
        # ticking inside the container -- false-negative every refresh.
        # Fall back to `<fed_dir>/.agentis/daemon/<agent_id>.heartbeat`
        # line 1 (ms-since-epoch of the last completed tick, written by
        # `write_heartbeat_ext` in `src/daemon/runner.rs` every tick
        # regardless of `.ag` branch taken). Same staleness window as
        # last_check so the safety semantics are byte-identical for
        # daemons that DO write last_check reliably (host-mode
        # dev-apprenticeship agents) -- only containerized federations
        # see a behaviour change, and the change is strictly more lenient
        # in the fresh direction (no false-positive zombie detection).
        if not rec['pid_alive'] and rec.get('agent_id'):
            heartbeat_path = os.path.join(fed_dir, '.agentis', 'daemon', str(rec['agent_id']) + '.heartbeat')
            try:
                with open(heartbeat_path) as _hbf:
                    line1 = _hbf.readline().strip()
                    if line1.isdigit():
                        hb_epoch = int(line1) / 1000.0
                        tick_interval_ms = freshness.resolve_tick_interval_ms(agent, colony, fed_dir=fed_dir, fed_tools_dir=fed_tools_dir) if freshness else 60000
                        role_ticks = freshness.staleness_ticks_for(agent) if freshness else STALENESS_TICKS
                        window_seconds = role_ticks * (tick_interval_ms / 1000.0)
                        rec['pid_alive'] = (epoch - hb_epoch) < window_seconds
            except (OSError, IOError, ValueError):
                pass

    # #300: derived "actually running" predicate. Registry state alone is
    # not enough — a daemon's registry row stays state=running even after
    # the OS has reaped its PID (zombie pattern). The dashboard summary
    # must agree with per-agent rendering: a row with state=running but
    # pid_alive=false is a dead/zombie agent and should NOT count as
    # running. Per-agent table already reflects this (badge-dead);
    # `is_running` extends the same effective-state semantics to the
    # top-line "Agents Running" stat box.
    rec['is_running'] = (rec['state'] == 'running' and rec['pid_alive'])

    # .ag description (first comment block) + confidence gate scan (#160)
    ag_path = os.path.join(fed_dir, colony, 'agents', agent + '.ag') if colony else ''
    if ag_path and os.path.isfile(ag_path):
        desc_lines = []
        ag_lines = []
        try:
            with open(ag_path) as f:
                ag_lines = f.readlines()
        except OSError:
            pass
        # Description from leading comment block
        for line in ag_lines:
            stripped = line.rstrip('\n')
            if stripped.startswith('//'):
                desc_lines.append(stripped[2:].strip())
            elif stripped.strip() == '':
                if desc_lines:
                    break
            else:
                break
        rec['description'] = '\n'.join(desc_lines)

        # #160 + #176: extract confidence gates. After M4 (#176) agents branch on
        # tier("<name>") == "<tier>" instead of raw confidence literals. Map
        # each tier-branch back to its numeric lower bound so downstream tooling
        # (dashboard promote/demote buttons, auto-promote.sh) keeps working.
        # Fall back to the pre-M4 `if confidence >= X` form if the agent has
        # not been migrated yet. clamp_auto cap idiom is unchanged.
        TIER_LEVELS = {
            'dormant': 0.0,
            'shadow': 0.4,
            'propose': 0.6,
            'review-gated': 0.8,
            'autonomous': 0.95,
        }
        gates = []
        for lineno, line in enumerate(ag_lines, 1):
            m_tier = re.search(r'my_tier\s*==\s*"(dormant|shadow|propose|review-gated|autonomous)"', line)
            if m_tier:
                gates.append({'level': TIER_LEVELS[m_tier.group(1)], 'line': lineno, 'tier': m_tier.group(1)})
                continue
            m = re.search(r'\bif\s+confidence\s+>=\s+([0-9]+(?:\.[0-9]+)?)', line)
            if m:
                gates.append({'level': float(m.group(1)), 'line': lineno})
        rec['confidence_gates'] = gates
        ag_text = ''.join(ag_lines)
        if re.search(r'\bfn\s+clamp_auto\s*\(', ag_text):
            cm = re.search(r'\blet\s+cap\s*=\s*([0-9]+(?:\.[0-9]+)?)', ag_text)
            if cm:
                rec['confidence_cap'] = float(cm.group(1))

    # Experience data (from .agentis/experience/<agent_id>.jsonl)
    agent_id = rec['agent_id']
    if agent_id and os.path.isdir(exp_dir):
        exp_path = os.path.join(exp_dir, agent_id + '.jsonl')
        if os.path.isfile(exp_path):
            entries = []
            try:
                with open(exp_path) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            entries.append(json.loads(line))
                        except json.JSONDecodeError:
                            continue
            except OSError:
                pass

            rec['experience_count'] = len(entries)
            total_exp += len(entries)
            if colony in colony_exp:
                colony_exp[colony] += len(entries)

            for e in entries:
                outcome = (e.get('outcome') or 'no-op').lower()
                if outcome in rec['experience_outcomes']:
                    rec['experience_outcomes'][outcome] += 1
                else:
                    rec['experience_outcomes']['no-op'] += 1

            # Rate: entries written in the last hour
            hour_ago = epoch - 3600
            recent_hour = [e for e in entries if (e.get('ts') or 0) > hour_ago]
            rec['experience_rate'] = round(len(recent_hour), 1)

            if entries:
                last = entries[-1]
                rec['last_action'] = str(last.get('in') or '')[:80]
                rec['last_action_ts'] = last.get('ts') or 0

            rec['recent_experience'] = entries[-10:]

            # #160: variance + slope over last 100 entries (matches the window
            # auto-promote.sh uses for delta_slope_window). Computing this
            # server-side over the full file means actionGate('evolve') tooltips
            # describe the actual sample size, not just the 10-entry UI slice.
            FITNESS_WINDOW = 100
            deltas_window = [e.get('delta') for e in entries[-FITNESS_WINDOW:] if isinstance(e.get('delta'), (int, float))]
            rec['fitness_window'] = len(deltas_window)
            if len(deltas_window) >= 2:
                mean = sum(deltas_window) / len(deltas_window)
                rec['experience_variance'] = sum((v - mean) ** 2 for v in deltas_window) / len(deltas_window)
            if len(deltas_window) >= 3:
                n = len(deltas_window)
                sX = sum(range(n))
                sY = sum(deltas_window)
                sXY = sum(i * v for i, v in enumerate(deltas_window))
                sX2 = sum(i * i for i in range(n))
                denom = n * sX2 - sX * sX
                if denom != 0:
                    rec['experience_slope_recent'] = (n * sXY - sX * sY) / denom

    # Recent log lines
    if agent_id and os.path.isdir(log_dir):
        log_path = os.path.join(log_dir, agent_id + '.log')
        if os.path.isfile(log_path):
            try:
                with open(log_path) as f:
                    lines = f.readlines()
                rec['recent_logs'] = [l.rstrip('\n') for l in lines[-50:]]
            except OSError:
                pass

    # #316 M5a: per-repo confidence overlay. Multi-repo colonies (N>=2
    # entries in [[forge.github]]) carry per-(agent, repo) overrides via
    # M4-shipped `<owner>__<repo>:<agent>:confidence` memos. We surface
    # the overrides as a sibling field so the dashboard's per-agent
    # row + modal can render a `(per-repo)` pill plus drill-down.
    # Bound the cost: only fetch when (a) the colony actually has >=2
    # repos and (b) the daemon's unscoped confidence is non-None (a
    # daemon with no confidence at all has nothing to override). Default
    # to an empty list so legacy single-block / N=1 / GitLab colonies
    # render byte-identical to v0.7.0.
    rec['per_repo_confidence'] = []
    repos = repos_for_colony.get(colony, [])
    if len(repos) >= 2 and rec['confidence'] is not None:
        for owner, repo in repos:
            memo_key = '%s__%s:%s:confidence' % (owner, repo, agent)
            conf_value = None
            try:
                memo_proc = subprocess.run(
                    ['agentis', 'memo', 'get', memo_key],
                    cwd=fed_dir, capture_output=True, text=True, timeout=2,
                )
                if memo_proc.returncode == 0:
                    raw = (memo_proc.stdout or '').strip()
                    if raw:
                        try:
                            conf_value = float(raw)
                        except (TypeError, ValueError):
                            conf_value = None
            except (subprocess.SubprocessError, OSError):
                conf_value = None
            rec['per_repo_confidence'].append({
                'owner': owner,
                'repo': repo,
                'confidence': conf_value,
            })

    result.append(rec)

colony_exp['total'] = total_exp

# --- Event timeline from log files ---
events = []
# #167: per-role epoch-ms of the most recent log line that classified as
# anything other than `error`. Drives the dashboard's "stale errors"
# auto-hide (errors from agents whose last_ok_ts > 1h ago are filtered
# out of the timeline so they don't drown out actively failing agents).
last_ok_ts_by_role = {}
if os.path.isdir(log_dir):
    try:
        for fn in sorted(os.listdir(log_dir)):
            if not fn.endswith('.log'):
                continue
            aid = fn[:-4]
            role = id_to_role.get(aid, aid[:8])
            fpath = os.path.join(log_dir, fn)
            try:
                with open(fpath) as f:
                    lines = f.readlines()
                # #167: widen from 30 to 100 lines so `last_ok_ts_by_role`
                # has enough history to detect "agent has ticked cleanly
                # in the last hour" — at 60s tick interval that's ~100
                # ticks of headroom, comfortably beyond the 1h window.
                for line in lines[-100:]:
                    line = line.strip()
                    if not line:
                        continue
                    # Try to extract timestamp from line start. Two formats
                    # supported: (1) raw 13-digit epoch-ms produced by the
                    # agentis daemon (the actual production format), (2)
                    # bracketed/ISO YYYY-MM-DD[T ]HH:MM:SS (kept as a
                    # fallback for older logs and external producers; do
                    # NOT remove without auditing every log emitter).
                    ts_ms_match = re.match(r'^(\d{13})\s+(.*)', line)
                    ts_iso_match = re.match(r'^\[?(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})\]?\s*(.*)', line)
                    ts = 0
                    content = line
                    if ts_ms_match:
                        try:
                            ts = int(ts_ms_match.group(1))
                            content = ts_ms_match.group(2)
                        except ValueError:
                            ts = 0
                    elif ts_iso_match:
                        iso = ts_iso_match.group(1).replace(' ', 'T')
                        try:
                            ts = int(datetime.datetime.fromisoformat(iso).timestamp() * 1000)
                            content = ts_iso_match.group(2)
                        except (ValueError, OSError):
                            ts = 0
                            content = ts_iso_match.group(2)
                    # Classify event type (word-boundary match to avoid
                    # false positives like "react"->action, "referred"->error)
                    etype = 'log'
                    cl = content.lower()
                    if re.search(r'\bemit\b', cl):
                        etype = 'emit'
                    elif re.search(r'\brecv\b|\blisten\b', cl):
                        etype = 'recv'
                    elif re.search(r'\bsuggest', cl):
                        etype = 'suggest'
                    elif re.search(r'\berror\b|\bfailed\b', cl):
                        etype = 'error'
                    elif re.search(r'\baction\b|\bdraft\b', cl):
                        etype = 'action'
                    elif re.search(r'\bfinding', cl):
                        etype = 'finding'
                    # #167: track the most recent non-error timestamp per
                    # role. Includes `log` (plain tick lines) — a clean
                    # tick is exactly what "ticking cleanly" means.
                    if etype != 'error' and ts > 0:
                        prev = last_ok_ts_by_role.get(role, 0)
                        if ts > prev:
                            last_ok_ts_by_role[role] = ts
                    # Only include interesting events in timeline
                    if etype != 'log':
                        events.append({
                            'ts': ts,
                            'agent': role,
                            'type': etype,
                            'content': content[:200],
                        })
            except OSError:
                pass
    except OSError:
        pass
# Sort by timestamp descending, limit to 100. ts is integer epoch-ms; entries
# with ts == 0 (unparseable) sort to the end.
events.sort(key=lambda e: e.get('ts', 0), reverse=True)
events = events[:100]

# #167: stamp `agent_last_ok_ts` on each agent record from the per-role
# tracking above. Defaults to 0 when no parseable non-error line was
# seen — the client-side "stale errors" filter treats 0 as "unknown,
# do not auto-hide" so silent agents stay visible.
for rec in result:
    name = rec['name']
    # Lookup mirrors the role-resolution fallback above: when no daemon
    # is registered (orphan log) the role becomes aid[:8], so we try the
    # truncated form too.
    rec['agent_last_ok_ts'] = (
        last_ok_ts_by_role.get(name) or
        last_ok_ts_by_role.get(name[:8], 0)
    )

# --- Confidence change log ---
conf_changes = []
conf_log_path = os.path.join(dash_dir, 'confidence-log.jsonl')
if os.path.isfile(conf_log_path):
    try:
        with open(conf_log_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    conf_changes.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        pass
conf_changes = conf_changes[-50:]

# --- Forge rate-limits (federation-dashboard 0.3.0; #316 M5a per-repo) ---
# Per-colony forge API budget. Each colony's `start-colony.sh
# --rate-limit-status` execs its `forge-api.sh rate-limit-status` in the
# fully-loaded env (FORGE_TYPE + GITLAB_*/GITHUB_*) and prints the JSON
# contract `{remaining, limit, reset_at}` from PR 7 of #256. The dashboard
# never parses colony.toml itself — that is the #257 decoupling principle.
# Failure modes (timeout, non-zero exit, malformed JSON) collapse into
# `{remaining: null, limit: null, reset_at: null, error: "<reason>"}` so
# the tile can render a per-colony status without bringing down regen.
#
# #316 M5a: when the colony's [[forge.github]] array carries N>=2 entries
# (read from the pre-computed `repos_for_colony` map above), fan the
# rate-limit fetch out across each repo via `start-colony.sh
# --rate-limit-status --repo owner/repo` and emit a new shape:
#     forge_rate_limits[colony] = {
#         repos:    [{owner, repo, remaining, limit, reset_at}, ...],
#         aggregate: {remaining, limit, reset_at},
#     }
# The aggregate is sum-of-remaining / sum-of-limit / earliest reset_at
# across the per-repo records (None values skipped). Single-block / N=1
# / GitLab colonies preserve the existing scalar shape byte-identically
# — that is the load-bearing back-compat invariant for v0.7.0 operators.
def _scalar_rate_limit(script):
    """Run start-colony.sh --rate-limit-status (no per-repo arg) and
    return a `{remaining, limit, reset_at}` dict (with optional `error`
    field when the call fails). Mirrors the v0.7.0 scalar contract."""
    try:
        rl_out = subprocess.run(
            ['bash', script, '--rate-limit-status'],
            capture_output=True, text=True, timeout=10,
        )
    except subprocess.TimeoutExpired:
        return {'remaining': None, 'limit': None, 'reset_at': None, 'error': 'timeout'}
    except (subprocess.SubprocessError, OSError) as e:
        return {'remaining': None, 'limit': None, 'reset_at': None, 'error': type(e).__name__}
    if rl_out.returncode != 0:
        return {'remaining': None, 'limit': None, 'reset_at': None,
                'error': 'exit ' + str(rl_out.returncode)}
    try:
        payload = json.loads(rl_out.stdout or '{}')
    except json.JSONDecodeError:
        return {'remaining': None, 'limit': None, 'reset_at': None,
                'error': 'malformed json'}
    return {
        'remaining': payload.get('remaining'),
        'limit':     payload.get('limit'),
        'reset_at':  payload.get('reset_at'),
    }


def _per_repo_rate_limit(script, owner, repo):
    """Run start-colony.sh --rate-limit-status --repo owner/repo and
    return the per-repo `{remaining, limit, reset_at}` dict (with
    optional `error` field). Same failure-mode contract as the scalar
    helper above; the `--repo` flag is consumed by forge-api.sh
    (M3a-shipped) which re-resolves GITHUB_OWNER/REPO/TOKEN/URL/ME via
    tools/forge-resolve-repo.py before exec'ing the backend wrapper."""
    repo_arg = '%s/%s' % (owner, repo)
    try:
        rl_out = subprocess.run(
            ['bash', script, '--rate-limit-status', '--repo', repo_arg],
            capture_output=True, text=True, timeout=10,
        )
    except subprocess.TimeoutExpired:
        return {'remaining': None, 'limit': None, 'reset_at': None, 'error': 'timeout'}
    except (subprocess.SubprocessError, OSError) as e:
        return {'remaining': None, 'limit': None, 'reset_at': None, 'error': type(e).__name__}
    if rl_out.returncode != 0:
        return {'remaining': None, 'limit': None, 'reset_at': None,
                'error': 'exit ' + str(rl_out.returncode)}
    try:
        payload = json.loads(rl_out.stdout or '{}')
    except json.JSONDecodeError:
        return {'remaining': None, 'limit': None, 'reset_at': None,
                'error': 'malformed json'}
    return {
        'remaining': payload.get('remaining'),
        'limit':     payload.get('limit'),
        'reset_at':  payload.get('reset_at'),
    }


forge_rate_limits = {}
for colony in colonies:
    script = os.path.join(fed_dir, colony, 'scripts', 'start-colony.sh')
    if not os.path.isfile(script):
        forge_rate_limits[colony] = {'remaining': None, 'limit': None,
                                     'reset_at': None, 'error': 'no start-colony.sh'}
        continue
    repos = repos_for_colony.get(colony, [])
    if len(repos) < 2:
        # Single-block / N=1 / GitLab — byte-identical to v0.7.0.
        forge_rate_limits[colony] = _scalar_rate_limit(script)
        continue
    # Multi-block N>=2: fan out per-repo, then derive an aggregate.
    per_repo_records = []
    for owner, repo in repos:
        rec_repo = _per_repo_rate_limit(script, owner, repo)
        per_repo_records.append({
            'owner': owner,
            'repo': repo,
            'remaining': rec_repo.get('remaining'),
            'limit': rec_repo.get('limit'),
            'reset_at': rec_repo.get('reset_at'),
            'error': rec_repo.get('error'),
        })
    rem_total = 0
    lim_total = 0
    earliest_reset = None
    for r in per_repo_records:
        if isinstance(r['remaining'], (int, float)):
            rem_total += r['remaining']
        if isinstance(r['limit'], (int, float)):
            lim_total += r['limit']
        if r['reset_at']:
            if earliest_reset is None or r['reset_at'] < earliest_reset:
                earliest_reset = r['reset_at']
    forge_rate_limits[colony] = {
        'repos': per_repo_records,
        'aggregate': {
            'remaining': rem_total if rem_total > 0 else None,
            'limit': lim_total if lim_total > 0 else None,
            'reset_at': earliest_reset,
        },
    }

# --- Promote decisions (#248) ---
# Invoke auto-promote-decisions.py in --preview mode so the dashboard's
# Promote Candidates list uses the same math the scheduler uses (acting
# vs observe classification per #186, per-step bootstrap override, runtime
# hours gate). Previously the template computed its own fitness from
# success/total across all rows, which silently diverged from the
# scheduler; operators saw "N skipped" for reasons the sidecar did not
# enforce. See issue #248.
decisions = []
# #252: helpers live in the federation's shared tools dir, not next to this
# file (the dashboard is a separately-versioned standalone component now).
# fed_tools_dir comes from the entry script's resolution chain
# (<fed-dir>/tools/ then <fed-dir>/../tools/). Empty string disables this
# panel — the JSON shipped to the template is `decisions: []`.
decider = os.path.join(fed_tools_dir, 'auto-promote-decisions.py') if fed_tools_dir else ''
config  = os.path.join(fed_tools_dir, 'auto-promote-config.yaml')  if fed_tools_dir else ''
if decider and config and os.path.isfile(decider) and os.path.isfile(config):
    try:
        dec_out = subprocess.run(
            ['python3', decider, '--preview', '--config', config,
             daemons_json, fed_dir],
            capture_output=True, text=True, timeout=15,
        )
        if dec_out.returncode == 0:
            try:
                decisions = json.loads(dec_out.stdout or '[]')
            except json.JSONDecodeError:
                decisions = []
    except (subprocess.SubprocessError, OSError):
        decisions = []

# --- Promotion forecast (#276) ---
# Project per-agent days-to-next-tier from the per-colony confidence series
# already cached in history.json (the same series the Confidence Trend chart
# renders). Linear regression on (t, conf) points → slope per second; for
# each promote-path skip decision compute (next_tier - confidence) / slope.
# All edge cases collapse to None: <3 history points, agent at autonomous,
# flat/declining slope, colony missing from h.confidence (#143 skip-null),
# unseeded confidence, or projected window > 30 days (clamped to 30 so the
# template can render ">30d" instead of an unbounded number). Tier ladder
# matches ADR-0001 normative tiers (0.4 → 0.6 → 0.8 → 0.95).
hist_path = os.path.join(dash_dir, 'history.json')
try:
    with open(hist_path) as f:
        hist_entries = json.load(f) or []
except (OSError, json.JSONDecodeError, ValueError):
    hist_entries = []
colony_slopes = {}  # colony -> conf-per-second (None if not enough data)
if isinstance(hist_entries, list) and len(hist_entries) >= 3:
    cols = set()
    for h in hist_entries:
        if isinstance(h, dict) and isinstance(h.get('confidence'), dict):
            cols.update(h['confidence'].keys())
    for col in cols:
        pts = []
        for h in hist_entries:
            if not isinstance(h, dict):
                continue
            cm = h.get('confidence') or {}
            v = cm.get(col)
            t = h.get('t')
            if v is None or t is None:
                continue
            try:
                pts.append((float(t), float(v)))
            except (TypeError, ValueError):
                continue
        if len(pts) < 3:
            continue
        n = len(pts)
        sx = sum(p[0] for p in pts)
        sy = sum(p[1] for p in pts)
        sxy = sum(p[0] * p[1] for p in pts)
        sx2 = sum(p[0] * p[0] for p in pts)
        denom = n * sx2 - sx * sx
        if denom == 0:
            continue
        colony_slopes[col] = (n * sxy - sx * sy) / denom

def _next_tier_target(conf):
    # ADR-0001 ladder. Returns None for autonomous (top tier) or unseeded.
    if conf is None:
        return None
    if conf < 0.6:
        return 0.6
    if conf < 0.8:
        return 0.8
    if conf < 0.95:
        return 0.95
    return None

for d in decisions:
    if not isinstance(d, dict):
        continue
    if d.get('decision') != 'skip':
        continue
    ev = d.get('evidence')
    if not isinstance(ev, dict) or not ev.get('prereqs'):
        continue
    conf = ev.get('confidence')
    target = _next_tier_target(conf)
    slope = colony_slopes.get(d.get('colony', ''))
    forecast_days = None
    if target is not None and slope is not None and slope > 0:
        delta = target - conf
        if delta > 0:
            days = (delta / slope) / 86400.0
            if days >= 30:
                forecast_days = 30.0
            else:
                forecast_days = round(days, 1)
    ev['forecast_days_to_next_tier'] = forecast_days

# --- Sidecar liveness (#248 PR B) ---
# Surface auto-promote scheduler state so the dashboard can render a
# HEALTHY / DEGRADED banner. Source of truth:
#   .auto-promote-install.toml  — whether the sidecar was ever installed
#                                 (install.sh §7) and the configured cadence
#   .agentis/logs/auto-promote.log — mtime is the last tick (sidecar appends
#                                 '=== {iso}: sidecar tick ===' + auto-promote.sh
#                                 stdout every interval_s; see
#                                 start-federation.sh §auto-promote scheduler).
# When no install file exists we emit installed=false and the banner falls
# back to daemon-liveness only. No sidecar running is not itself DEGRADED.
#
# Orphan detection (#378): when the install file is missing we have no
# operator-set interval_s to compare against, so we infer "still running"
# from a recent log tick using 4× the production default of 1800s baked
# into install.sh §7. 4× matches the `down` cutoff in _sidecar_status()
# below — keeps the orphan liveness ceiling identical to a healthy install.
ORPHAN_INFER_S = 4 * 1800
sidecar = {'installed': False, 'enabled': False, 'interval_s': None,
           'last_tick_ts': None, 'log_path': None,
           'started_at_ts': None, 'in_startup_grace': False,
           'running_orphan': False}
install_file = os.path.join(fed_dir, '.auto-promote-install.toml')
if os.path.isfile(install_file):
    sidecar['installed'] = True
    try:
        in_section = False
        with open(install_file) as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith('#'):
                    continue
                if line.startswith('[') and line.endswith(']'):
                    in_section = (line[1:-1].strip() == 'auto_promote')
                    continue
                if not in_section or '=' not in line:
                    continue
                k, _, v = line.partition('=')
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                if k == 'enabled':
                    sidecar['enabled'] = (v.lower() == 'true')
                elif k == 'interval_s':
                    try:
                        sidecar['interval_s'] = int(v)
                    except ValueError:
                        pass
    except OSError:
        pass
log_file = os.path.join(fed_dir, '.agentis', 'logs', 'auto-promote.log')
if os.path.isfile(log_file):
    sidecar['log_path'] = log_file
    try:
        sidecar['last_tick_ts'] = int(os.path.getmtime(log_file))
    except OSError:
        pass
# Sidecar-start timestamp lets the template suppress DEGRADED on a fresh
# restart, where auto-promote.log inherits a stale mtime from the previous
# run (#274). The file is written by start-federation.sh's sidecar block
# right before the subshell is backgrounded.
started_at_file = os.path.join(fed_dir, '.agentis', 'logs',
                               'auto-promote.sidecar_started_at')
started_at_ts = None
if os.path.isfile(started_at_file):
    try:
        with open(started_at_file) as f:
            started_at_ts = int(f.read().strip())
    except (OSError, ValueError):
        started_at_ts = None
if started_at_ts is not None:
    sidecar['started_at_ts'] = started_at_ts
    if sidecar['interval_s'] is not None and sidecar['interval_s'] > 0:
        now_ts = int(time.time())
        sidecar['in_startup_grace'] = (
            (now_ts - started_at_ts) < (sidecar['interval_s'] + 120)
        )

# Orphan check (#378): install file gone but a recent log tick proves the
# loop is still running. Only meaningful when last_tick_ts is fresher than
# ORPHAN_INFER_S — older ticks resolve to plain `not-installed`.
if not sidecar['installed'] and sidecar['last_tick_ts'] is not None:
    now_ts_orphan = int(time.time())
    if (now_ts_orphan - sidecar['last_tick_ts']) < ORPHAN_INFER_S:
        sidecar['running_orphan'] = True

# --- LLM Cost telemetry (#311 PR B) ---
# Reads the per-agent spend log written by agentis-core (#311 PR A, agentis
# v1.4.7). Each row in <agentis_root>/spend/<agent_id>.jsonl is one prompt()
# invocation; schema:
#   {"v":1,"ts":<ms>,"agent":"<sha8>","colony":"<name>","backend":"...",
#    "model":"...","input_tokens":N,"output_tokens":N,"cost_usd":F,
#    "cost_source":"native|table|unknown","cb":N,"instr_hash":"<8hex>",
#    "cached":bool,"ok":bool}
# Spend dir lives alongside experience dir (both under .agentis/); we derive
# its path from exp_dir to inherit the same fed-local-first resolution the
# wrapper already performs.
TABLE_PIN_DATE = '2026-04-01'

def collect_spend_log(spend_dir, id_to_colony, id_to_role, epoch_s):
    """Walk <spend_dir>/*.jsonl and aggregate cost into 3 windows + sparkline
    buckets. Returns the `cost` block embedded in the collector JSON output.

    Skips malformed rows silently (mirror existing collector tolerance).
    Sparkline buckets: 24x1h (last 24 hours, oldest first) and 30x24h (last
    30 days, oldest first). All cost values rounded to 4 decimal places to
    keep the embedded JSON small.
    """
    today_start_ms = int(datetime.datetime.fromtimestamp(epoch_s)
                         .replace(hour=0, minute=0, second=0, microsecond=0)
                         .timestamp() * 1000)
    week_start_ms  = (epoch_s - 7 * 86400) * 1000
    month_start_ms = (epoch_s - 30 * 86400) * 1000
    spark_24h_origin_ms = (epoch_s - 24 * 3600) * 1000
    spark_30d_origin_ms = (epoch_s - 30 * 86400) * 1000

    fed_total = {'today': 0.0, 'week': 0.0, 'month': 0.0}
    by_colony = {}
    by_agent  = {}
    recent_by_agent = {}  # agent_id -> last 5 spend rows (most recent last)
    spark_24h = [0.0] * 24
    spark_30d = [0.0] * 30
    newest_ts_ms = 0
    # #352: token aggregation for the new Cost tab's "LLM Tokens" section.
    # Federation-wide + per-agent input/output token counts, same windows
    # as the dollar aggregation above. Cheap (one extra read per row that
    # we already touched for the cost aggregation).
    fed_tokens = {'input_today': 0, 'input_7d': 0, 'input_30d': 0,
                  'output_today': 0, 'output_7d': 0, 'output_30d': 0}
    tokens_by_agent = {}

    if not os.path.isdir(spend_dir):
        return {
            'federation': fed_total,
            'by_colony': by_colony,
            'by_agent':  by_agent,
            'recent_by_agent': recent_by_agent,
            'sparkline_24h': spark_24h,
            'sparkline_30d': spark_30d,
            'currency': 'USD',
            'stale_seconds': None,
            'table_pin_date': TABLE_PIN_DATE,
            # #352: token totals for the Cost tab's tokens section.
            'tokens_federation': fed_tokens,
            'tokens_by_agent': tokens_by_agent,
        }

    try:
        files = sorted(os.listdir(spend_dir))
    except OSError:
        files = []

    for fn in files:
        if not fn.endswith('.jsonl'):
            continue
        aid = fn[:-6]
        # Resolve agent SHA-8 to its colony via the daemon mapping; the
        # JSONL row also carries the colony, but the daemon mapping wins
        # when both disagree (matches experience-table behaviour).
        # #412: agent_id → colony directly, so federations with N colonies
        # × 1 same-named agent (e.g. tribes-bench's 5 hunters) attribute
        # spend to the correct colony rather than the first-seen one.
        role = id_to_role.get(aid, '')
        colony_from_map = id_to_colony.get(aid, '')
        path = os.path.join(spend_dir, fn)
        # Bounded ring buffer of the last 5 valid rows for this agent. The
        # JSONL writer in #311 PR A appends only — newest is always at EOF —
        # but defensive sort by ts after the read keeps us safe against
        # tooling that ever reorders.
        agent_recent = []
        try:
            with open(path) as f:
                for raw in f:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        row = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(row, dict):
                        continue
                    cost = row.get('cost_usd')
                    if not isinstance(cost, (int, float)):
                        continue
                    ts_ms = row.get('ts')
                    if not isinstance(ts_ms, (int, float)) or ts_ms <= 0:
                        continue
                    ts_ms = int(ts_ms)
                    if ts_ms > newest_ts_ms:
                        newest_ts_ms = ts_ms
                    cost = float(cost)
                    colony = colony_from_map or row.get('colony') or ''
                    agent_key = aid

                    # Per-window aggregation
                    if ts_ms >= today_start_ms:
                        fed_total['today'] += cost
                    if ts_ms >= week_start_ms:
                        fed_total['week'] += cost
                    if ts_ms >= month_start_ms:
                        fed_total['month'] += cost

                    if colony:
                        cb = by_colony.setdefault(colony, {'today': 0.0, 'week': 0.0, 'month': 0.0})
                        if ts_ms >= today_start_ms: cb['today'] += cost
                        if ts_ms >= week_start_ms:  cb['week']  += cost
                        if ts_ms >= month_start_ms: cb['month'] += cost

                    ab = by_agent.setdefault(agent_key, {'today': 0.0, 'week': 0.0, 'month': 0.0})
                    if ts_ms >= today_start_ms: ab['today'] += cost
                    if ts_ms >= week_start_ms:  ab['week']  += cost
                    if ts_ms >= month_start_ms: ab['month'] += cost

                    # #352: token aggregation. Same window logic, accumulate
                    # input + output separately so the Tokens section can
                    # render either side in isolation.
                    in_tok = row.get('input_tokens') or 0
                    out_tok = row.get('output_tokens') or 0
                    try:
                        in_tok = int(in_tok)
                        out_tok = int(out_tok)
                    except (TypeError, ValueError):
                        in_tok = 0
                        out_tok = 0
                    if ts_ms >= today_start_ms:
                        fed_tokens['input_today'] += in_tok
                        fed_tokens['output_today'] += out_tok
                    if ts_ms >= week_start_ms:
                        fed_tokens['input_7d'] += in_tok
                        fed_tokens['output_7d'] += out_tok
                    if ts_ms >= month_start_ms:
                        fed_tokens['input_30d'] += in_tok
                        fed_tokens['output_30d'] += out_tok
                    tb = tokens_by_agent.setdefault(agent_key, {'input': 0, 'output': 0})
                    if ts_ms >= week_start_ms:
                        tb['input'] += in_tok
                        tb['output'] += out_tok

                    # Sparkline bucketing (oldest-first, fixed-width)
                    if ts_ms >= spark_24h_origin_ms:
                        idx = int((ts_ms - spark_24h_origin_ms) // (3600 * 1000))
                        if 0 <= idx < 24:
                            spark_24h[idx] += cost
                    if ts_ms >= spark_30d_origin_ms:
                        idx = int((ts_ms - spark_30d_origin_ms) // (86400 * 1000))
                        if 0 <= idx < 30:
                            spark_30d[idx] += cost

                    # Slim row for the modal-expansion table: only fields the
                    # template renders. Keeps the embedded JSON small and
                    # avoids passing through PII-shaped values (the schema in
                    # #311 PR A is already PII-clean by construction).
                    agent_recent.append({
                        'ts': ts_ms,
                        'backend': row.get('backend') or '',
                        'model':   row.get('model')   or '',
                        'input_tokens':  row.get('input_tokens')  or 0,
                        'output_tokens': row.get('output_tokens') or 0,
                        'cost_usd': round(cost, 6),
                        'cost_source': row.get('cost_source') or 'unknown',
                        'cached': bool(row.get('cached')),
                        'ok': bool(row.get('ok', True)),
                    })
        except OSError:
            continue
        if agent_recent:
            agent_recent.sort(key=lambda r: r['ts'])
            recent_by_agent[aid] = agent_recent[-5:]

    def _round(v):
        return round(v, 4)
    fed_total = {k: _round(v) for k, v in fed_total.items()}
    by_colony = {c: {k: _round(v) for k, v in d.items()} for c, d in by_colony.items()}
    by_agent  = {a: {k: _round(v) for k, v in d.items()} for a, d in by_agent.items()}
    spark_24h = [_round(v) for v in spark_24h]
    spark_30d = [_round(v) for v in spark_30d]

    stale_seconds = None
    if newest_ts_ms > 0:
        stale_seconds = max(0, int(epoch_s - newest_ts_ms / 1000))

    return {
        'federation': fed_total,
        'by_colony': by_colony,
        'by_agent':  by_agent,
        'recent_by_agent': recent_by_agent,
        'sparkline_24h': spark_24h,
        'sparkline_30d': spark_30d,
        # #352: token totals for the Cost tab tokens section.
        'tokens_federation': fed_tokens,
        'tokens_by_agent': tokens_by_agent,
        'currency': 'USD',
        'stale_seconds': stale_seconds,
        'table_pin_date': TABLE_PIN_DATE,
    }

# Spend dir is the sibling of exp_dir under <agentis_root>/. Inheriting the
# resolved exp_dir avoids re-implementing the fed-local-first chain the
# wrapper already encodes.
spend_dir = os.path.join(os.path.dirname(exp_dir), 'spend') if exp_dir else ''
cost = collect_spend_log(spend_dir, id_to_colony, id_to_role, epoch)


# --- #359: per-minute burn rate + projections (Cost tab) ---
# 5-minute EMA of cost_usd + tokens from spend log, plus 1h/1d/1w/1m
# projections. Surfaced on the Cost tab as 4 stat tiles. Operator can also
# override the traffic-light thresholds via <fed>/.agentis/config:
#   [dashboard]
#   cost_yellow_per_h = 1.0   # default
#   cost_red_per_h    = 5.0   # default
def collect_cost_burn_rate(spend_dir, epoch_s, fed_config_keys):
    """Walk the spend log, compute the 5-min EMA of cost & tokens, and
    project out to 1h / 1d / 1w / 1m. Returns a dict with 7 numeric
    fields suitable for direct rendering. All zero if spend dir missing
    or empty (the live federation will trickle in fresh rows over time).
    """
    window_seconds = 300  # 5 minutes
    cutoff_ms = (epoch_s - window_seconds) * 1000
    sum_cost = 0.0
    sum_tokens = 0
    if spend_dir and os.path.isdir(spend_dir):
        try:
            for fn in os.listdir(spend_dir):
                if not fn.endswith('.jsonl'):
                    continue
                path = os.path.join(spend_dir, fn)
                try:
                    with open(path) as f:
                        for raw in f:
                            raw = raw.strip()
                            if not raw:
                                continue
                            try:
                                row = json.loads(raw)
                            except json.JSONDecodeError:
                                continue
                            if not isinstance(row, dict):
                                continue
                            ts = row.get('ts')
                            if not isinstance(ts, (int, float)):
                                continue
                            ts_ms = int(ts)
                            if ts_ms < cutoff_ms:
                                continue
                            c = row.get('cost_usd')
                            if isinstance(c, (int, float)):
                                sum_cost += float(c)
                            i_tok = row.get('input_tokens') or 0
                            o_tok = row.get('output_tokens') or 0
                            try:
                                sum_tokens += int(i_tok) + int(o_tok)
                            except (TypeError, ValueError):
                                pass
                except OSError:
                    continue
        except OSError:
            pass
    rate_per_min_usd = sum_cost / 5.0
    rate_per_min_tokens = sum_tokens / 5.0
    # Threshold overrides: read from fed_config_keys (the federation-wide
    # `[dashboard]` section). Yellow defaults to $1/h, red to $5/h —
    # operator-tunable so cheap dev backends can stay green and expensive
    # fleets can flag faster.
    cost_yellow = 1.0
    cost_red = 5.0
    for kv in (fed_config_keys or []):
        if kv.get('section') != 'dashboard':
            continue
        try:
            if kv.get('key') == 'cost_yellow_per_h':
                cost_yellow = float((kv.get('raw_value') or '').strip()
                                    .strip('"').strip("'") or '1.0')
            elif kv.get('key') == 'cost_red_per_h':
                cost_red = float((kv.get('raw_value') or '').strip()
                                 .strip('"').strip("'") or '5.0')
        except (TypeError, ValueError):
            pass
    return {
        'rate_per_min_usd': round(rate_per_min_usd, 6),
        'rate_per_min_tokens': int(rate_per_min_tokens),
        'projected_1h_usd':  round(rate_per_min_usd * 60, 4),
        'projected_1d_usd':  round(rate_per_min_usd * 60 * 24, 4),
        'projected_1w_usd':  round(rate_per_min_usd * 60 * 24 * 7, 4),
        'projected_1m_usd':  round(rate_per_min_usd * 60 * 24 * 30, 4),
        'cost_threshold_yellow_usd_per_h': cost_yellow,
        'cost_threshold_red_usd_per_h': cost_red,
        'window_seconds': window_seconds,
    }


# --- #359: forensic last-N watchdog kills (Recovery tab) ---
# Reads <fed>/.agentis/lifecycle/events.jsonl, filters to the watchdog
# kill flavour (heuristic: event names containing "killed", "watchdog",
# or "respawn"; severity inferred from new_status). Returns up to 10
# most-recent rows, ts-desc, with {ts, agent, reason} for the renderer.
def collect_watchdog_kills(lifecycle_path, id_to_role, max_rows=10):
    if not lifecycle_path or not os.path.isfile(lifecycle_path):
        return []
    out = []
    try:
        with open(lifecycle_path) as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    row = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict):
                    continue
                ev = (row.get('event') or '').lower()
                ns = (row.get('new_status') or '').lower()
                # Match any kill / watchdog / respawn flavour. Real-world
                # writers haven't standardised yet; this catches every
                # variant we know about + leaves room for new ones.
                if not ('killed' in ev or 'watchdog' in ev or 'sigkill' in ev
                        or 'respawn' in ev or 'critical' in ns):
                    continue
                ts = row.get('ts')
                if not isinstance(ts, (int, float)):
                    continue
                ts_ms = int(ts) if int(ts) >= 10**11 else int(ts) * 1000
                aid = row.get('agent_id') or ''
                role = id_to_role.get(aid, aid)
                reason = (row.get('reason') or row.get('event')
                          or 'watchdog kill')
                out.append({
                    'ts': ts_ms,
                    'agent_id': aid,
                    'agent': role or '?',
                    'event': row.get('event') or '',
                    'reason': reason,
                })
    except OSError:
        return []
    out.sort(key=lambda r: r['ts'], reverse=True)
    return out[:max_rows]

# --- Per-agent unified timeline (#315 PR 1) ---
# Merges four on-disk JSONL streams into a single chronological array per
# agent: experience (kind=learn), spend (kind=prompt), confidence-log
# (kind=confidence_change), lifecycle (kind=lifecycle, payload carries the
# event subtype). Read once, bucket once; embed last 50 reverse-chrono per
# agent. Federation-wide stream + /timeline endpoint are PR 2 (#315).
#
# Schema per row:
#   {ts: <int, ms>, agent_id: "<sha8>", kind: "<enum>",
#    payload: <object, source-specific>, severity: "info"|"warning"|"error"}
#
# All ts coerced to epoch-ms on read (experience writes seconds, spend
# writes ms, lifecycle writes seconds, confidence-log writes seconds).
TIMELINE_PER_AGENT_CAP = 50

# Bucket lifecycle events by agent_id ONCE — file is ~12k lines on the live
# federation; per-agent re-reads would be O(N*M).
lifecycle_dir = os.path.join(os.path.dirname(exp_dir), 'lifecycle') if exp_dir else ''
lifecycle_path = os.path.join(lifecycle_dir, 'events.jsonl') if lifecycle_dir else ''
lifecycle_by_aid = {}
if lifecycle_path and os.path.isfile(lifecycle_path):
    try:
        with open(lifecycle_path) as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    row = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict):
                    continue
                aid = row.get('agent_id') or ''
                if not aid:
                    continue
                lifecycle_by_aid.setdefault(aid, []).append(row)
    except OSError:
        pass

# Bucket confidence-log entries by agent_id ONCE for the same reason. The
# `conf_changes` array above is federation-wide (last 50 across all agents)
# and not suitable for per-agent slicing.
conf_log_path = os.path.join(dash_dir, 'confidence-log.jsonl')
conf_by_aid = {}
if os.path.isfile(conf_log_path):
    try:
        with open(conf_log_path) as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    row = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict):
                    continue
                # confidence-log rows historically key by either agent_id
                # (sha8) or agent (role) — accept both, prefer agent_id when
                # present so the per-agent bucketing matches the daemon's
                # canonical id (mirrors the spend-log convention).
                aid = row.get('agent_id') or ''
                if not aid:
                    continue
                conf_by_aid.setdefault(aid, []).append(row)
    except OSError:
        pass


def _coerce_ms(ts):
    """Coerce a timestamp to epoch-ms. Accepts seconds (10-digit), ms
    (13-digit), or None/garbage. Returns 0 on failure."""
    if not isinstance(ts, (int, float)):
        return 0
    n = int(ts)
    if n <= 0:
        return 0
    # 13-digit ms: ~ year 2001+ in ms. 10-digit s: ~ year 2001+ in s.
    # Anything < 10**11 is treated as seconds (covers 1973-5138 in s).
    return n if n >= 10 ** 11 else n * 1000


def _summary_severity(kind, payload):
    """Best-effort severity classification — kept conservative so the modal
    doesn't paint everything red. info by default; warning for known
    health-degradation lifecycle events; error reserved for explicit
    failure outcomes."""
    if kind == 'learn':
        outcome = (payload.get('outcome') or '').lower()
        if outcome == 'failure':
            return 'error'
        return 'info'
    if kind == 'prompt':
        return 'info' if payload.get('ok', True) else 'error'
    if kind == 'confidence_change':
        return 'info'
    if kind == 'lifecycle':
        ev = (payload.get('event') or '').lower()
        if 'critical' in (payload.get('new_status') or '').lower():
            return 'warning'
        if 'quarantine' in ev or 'restart' in ev or 'health_changed' in ev:
            return 'warning'
        if 'failed' in ev or 'crashed' in ev:
            return 'error'
    return 'info'


def build_agent_timeline(agent_id, exp_entries, spend_entries, conf_entries, lifecycle_entries):
    """Merge the four sources for a single agent and return the last
    TIMELINE_PER_AGENT_CAP rows, sorted by ts descending. All four input
    lists may be empty — output is then []. Each input is an iterable of
    raw JSONL dicts; this function normalizes them into the unified shape.
    """
    rows = []

    for e in exp_entries or []:
        if not isinstance(e, dict):
            continue
        ts_ms = _coerce_ms(e.get('ts'))
        if ts_ms == 0:
            continue
        payload = {
            'outcome': e.get('outcome'),
            'delta': e.get('delta'),
            'action': e.get('action'),
            'in': e.get('in'),
        }
        rows.append({
            'ts': ts_ms,
            'agent_id': agent_id,
            'kind': 'learn',
            'payload': payload,
            'severity': _summary_severity('learn', payload),
        })

    for s in spend_entries or []:
        if not isinstance(s, dict):
            continue
        ts_ms = _coerce_ms(s.get('ts'))
        if ts_ms == 0:
            continue
        payload = {
            'cost_usd': s.get('cost_usd'),
            'input_tokens': s.get('input_tokens'),
            'output_tokens': s.get('output_tokens'),
            'model': s.get('model'),
            'backend': s.get('backend'),
            'ok': s.get('ok', True),
        }
        rows.append({
            'ts': ts_ms,
            'agent_id': agent_id,
            'kind': 'prompt',
            'payload': payload,
            'severity': _summary_severity('prompt', payload),
        })

    for c in conf_entries or []:
        if not isinstance(c, dict):
            continue
        ts_ms = _coerce_ms(c.get('ts'))
        if ts_ms == 0:
            continue
        payload = {
            'from': c.get('from') if c.get('from') is not None else c.get('prev'),
            'to': c.get('to') if c.get('to') is not None else c.get('new'),
            'delta': c.get('delta'),
            'reason': c.get('reason') or c.get('source'),
        }
        rows.append({
            'ts': ts_ms,
            'agent_id': agent_id,
            'kind': 'confidence_change',
            'payload': payload,
            'severity': _summary_severity('confidence_change', payload),
        })

    for ev in lifecycle_entries or []:
        if not isinstance(ev, dict):
            continue
        ts_ms = _coerce_ms(ev.get('ts'))
        if ts_ms == 0:
            continue
        # Pass the whole row through as payload so the renderer can show
        # subtype-specific detail (e.g. old_status -> new_status for
        # agent.health_changed). Strip agent_id (already on the envelope)
        # to keep the payload small.
        payload = {k: v for k, v in ev.items() if k != 'agent_id'}
        rows.append({
            'ts': ts_ms,
            'agent_id': agent_id,
            'kind': 'lifecycle',
            'payload': payload,
            'severity': _summary_severity('lifecycle', payload),
        })

    rows.sort(key=lambda r: r['ts'], reverse=True)
    return rows[:TIMELINE_PER_AGENT_CAP]


# Inject `timeline` into each agent record. Sources: experience entries are
# already cached in rec['recent_experience'] but only as a 10-row tail —
# re-read the full file via the existing exp_path resolution to keep the
# 50-row window. Spend rows live in cost['recent_by_agent'] but capped at
# 5; mirror the same logic to read the full spend file. Lifecycle and
# confidence-log are bucketed above.
for rec in result:
    aid = rec.get('agent_id') or ''
    if not aid:
        rec['timeline'] = []
        continue

    # Re-read experience file for up to 50 rows (vs the 10-row tail in
    # rec['recent_experience']). The collector pattern above already
    # tolerates missing files / malformed lines.
    exp_entries_full = []
    if exp_dir and os.path.isdir(exp_dir):
        ep = os.path.join(exp_dir, aid + '.jsonl')
        if os.path.isfile(ep):
            try:
                with open(ep) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            exp_entries_full.append(json.loads(line))
                        except json.JSONDecodeError:
                            continue
            except OSError:
                pass

    spend_entries_full = []
    if spend_dir and os.path.isdir(spend_dir):
        sp = os.path.join(spend_dir, aid + '.jsonl')
        if os.path.isfile(sp):
            try:
                with open(sp) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            spend_entries_full.append(json.loads(line))
                        except json.JSONDecodeError:
                            continue
            except OSError:
                pass

    rec['timeline'] = build_agent_timeline(
        aid,
        exp_entries_full,
        spend_entries_full,
        conf_by_aid.get(aid, []),
        lifecycle_by_aid.get(aid, []),
    )

# --- Federation-wide unified timeline (#315 PR 2) ---
# Merge every agent's normalized rows into one reverse-chronological feed for
# the federation-wide tile. Each row inherits the PR 1 envelope ({ts,
# agent_id, kind, payload, severity}) and is augmented with agent_name +
# colony for chip rendering on the client.
#
# Implementation note: we deliberately rebuild per-agent rows from the
# already-loaded source dicts rather than reading rec['timeline'], because
# the per-agent slice is capped at TIMELINE_PER_AGENT_CAP (50). For the
# federation-wide top-N we want the absolute newest rows across all agents
# regardless of any single agent's per-agent volume — an agent firing 100
# events in the last hour shouldn't lose its 51st-newest entry just because
# the per-agent view trimmed it. Total complexity stays O(N_lifecycle +
# N_experience + N_spend + N_confidence) — the source dicts are already
# bucketed (lifecycle_by_aid, conf_by_aid) or read once per agent above.
TIMELINE_FED_CAP = 200

# Lookup table: agent_id -> {name, colony}. Built once for O(1) augmentation
# of every row in the merged stream.
aid_to_meta = {}
for rec in result:
    aid = rec.get('agent_id') or ''
    if aid:
        aid_to_meta[aid] = {
            'agent_name': rec.get('name', ''),
            'colony': rec.get('colony', ''),
        }

federation_timeline = []
for rec in result:
    aid = rec.get('agent_id') or ''
    if not aid:
        continue
    meta = aid_to_meta.get(aid, {'agent_name': rec.get('name', ''),
                                 'colony': rec.get('colony', '')})
    # Re-read just enough to build a per-agent row stream WITHOUT the
    # 50-row per-agent cap. Spend / experience JSONLs are re-opened here
    # (one short pass per agent — bounded by the spend / experience file
    # size, NOT by total federation history); lifecycle + confidence-log
    # are pulled from the buckets the four source-bucketing reads above
    # already filled in memory, so they're free at this point.
    exp_for_agent = []
    if exp_dir and os.path.isdir(exp_dir):
        ep = os.path.join(exp_dir, aid + '.jsonl')
        if os.path.isfile(ep):
            try:
                with open(ep) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            exp_for_agent.append(json.loads(line))
                        except json.JSONDecodeError:
                            continue
            except OSError:
                pass

    spend_for_agent = []
    if spend_dir and os.path.isdir(spend_dir):
        sp = os.path.join(spend_dir, aid + '.jsonl')
        if os.path.isfile(sp):
            try:
                with open(sp) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            spend_for_agent.append(json.loads(line))
                        except json.JSONDecodeError:
                            continue
            except OSError:
                pass

    # Use build_agent_timeline with a temporarily-disabled cap by passing
    # the same lists; build_agent_timeline always caps at TIMELINE_PER_AGENT_CAP
    # so we re-implement the merge inline to keep the cap separate.
    rows = []
    for e in exp_for_agent:
        if not isinstance(e, dict):
            continue
        ts_ms = _coerce_ms(e.get('ts'))
        if ts_ms == 0:
            continue
        payload = {
            'outcome': e.get('outcome'),
            'delta':   e.get('delta'),
            'action':  e.get('action'),
            'in':      e.get('in'),
        }
        rows.append({
            'ts': ts_ms, 'agent_id': aid, 'kind': 'learn',
            'payload': payload,
            'severity': _summary_severity('learn', payload),
        })
    for s in spend_for_agent:
        if not isinstance(s, dict):
            continue
        ts_ms = _coerce_ms(s.get('ts'))
        if ts_ms == 0:
            continue
        payload = {
            'cost_usd':      s.get('cost_usd'),
            'input_tokens':  s.get('input_tokens'),
            'output_tokens': s.get('output_tokens'),
            'model':         s.get('model'),
            'backend':       s.get('backend'),
            'ok':            s.get('ok', True),
        }
        rows.append({
            'ts': ts_ms, 'agent_id': aid, 'kind': 'prompt',
            'payload': payload,
            'severity': _summary_severity('prompt', payload),
        })
    for c in conf_by_aid.get(aid, []):
        if not isinstance(c, dict):
            continue
        ts_ms = _coerce_ms(c.get('ts'))
        if ts_ms == 0:
            continue
        payload = {
            'from':   c.get('from') if c.get('from') is not None else c.get('prev'),
            'to':     c.get('to')   if c.get('to')   is not None else c.get('new'),
            'delta':  c.get('delta'),
            'reason': c.get('reason') or c.get('source'),
        }
        rows.append({
            'ts': ts_ms, 'agent_id': aid, 'kind': 'confidence_change',
            'payload': payload,
            'severity': _summary_severity('confidence_change', payload),
        })
    for ev in lifecycle_by_aid.get(aid, []):
        if not isinstance(ev, dict):
            continue
        ts_ms = _coerce_ms(ev.get('ts'))
        if ts_ms == 0:
            continue
        payload = {k: v for k, v in ev.items() if k != 'agent_id'}
        rows.append({
            'ts': ts_ms, 'agent_id': aid, 'kind': 'lifecycle',
            'payload': payload,
            'severity': _summary_severity('lifecycle', payload),
        })
    for row in rows:
        row['agent_name'] = meta['agent_name']
        row['colony'] = meta['colony']
        federation_timeline.append(row)

federation_timeline.sort(key=lambda r: r.get('ts', 0), reverse=True)
federation_timeline = federation_timeline[:TIMELINE_FED_CAP]

# Inject per-agent cost windows into each agent record (mirrors the
# experience_count placement above). The agent table can then expose a
# "$ today" sortable column without requiring a second lookup at render time.
for rec in result:
    aid = rec.get('agent_id') or ''
    bucket = cost['by_agent'].get(aid) if aid else None
    rec['cost_today'] = bucket['today'] if bucket else 0.0
    rec['cost_7d']    = bucket['week']  if bucket else 0.0
    rec['cost_30d']   = bucket['month'] if bucket else 0.0

# --- Cost cap state (#318) ---
# Read <fed>/.agentis/cost-cap-banner.json (warning/breach detail) +
# <fed>/.agentis/cost-cap-state.json (state machine snapshot) and a
# `installed` flag from <fed>/.cost-cap.toml. The dashboard tile shows
# mode-aware progress bars (metered: $/cap, flat: requests + slope) and
# a status pill (active|warning|downgraded|stopped). Sidecar liveness
# follows the same #274 grace pattern as auto-promote.
cost_cap = {
    'installed': False,
    'enabled': False,
    'mode': 'metered',
    'status': 'active',
    'reasons': [],
    'metrics': {},
    'since_ts': None,
    'period_day': '',
    'period_month': '',
    'log_path': None,
    'last_tick_ts': None,
    'started_at_ts': None,
    'in_startup_grace': False,
    'running_orphan': False,
    'on_breach': None,
}
cost_cap_install = os.path.join(fed_dir, '.cost-cap.toml')
cost_cap_interval = None
if os.path.isfile(cost_cap_install):
    cost_cap['installed'] = True
    try:
        section = None
        with open(cost_cap_install) as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith('#'):
                    continue
                if line.startswith('[') and line.endswith(']'):
                    section = line[1:-1].strip()
                    continue
                if section is None or '=' not in line:
                    continue
                k, _, v = line.partition('=')
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                if section == 'cost':
                    if k == 'enabled':
                        cost_cap['enabled'] = (v.lower() == 'true')
                    elif k == 'mode':
                        cost_cap['mode'] = v or 'metered'
                    elif k == 'interval_s':
                        try:
                            cost_cap_interval = int(v)
                        except ValueError:
                            pass
    except OSError:
        pass

cost_cap_banner = os.path.join(fed_dir, '.agentis', 'cost-cap-banner.json')
if os.path.isfile(cost_cap_banner):
    try:
        with open(cost_cap_banner) as f:
            banner = json.load(f) or {}
        cost_cap['status'] = banner.get('state') or cost_cap['status']
        cost_cap['reasons'] = banner.get('reasons') or []
        cost_cap['metrics'] = banner.get('metrics') or {}
        cost_cap['since_ts'] = banner.get('since_ts')
        cost_cap['period_day'] = banner.get('period_day') or ''
        cost_cap['period_month'] = banner.get('period_month') or ''
        cost_cap['on_breach'] = banner.get('on_breach')
        if banner.get('mode'):
            cost_cap['mode'] = banner['mode']
    except (OSError, json.JSONDecodeError, ValueError):
        pass

cost_cap_state = os.path.join(fed_dir, '.agentis', 'cost-cap-state.json')
if os.path.isfile(cost_cap_state):
    try:
        with open(cost_cap_state) as f:
            state = json.load(f) or {}
        if not cost_cap['metrics']:
            cost_cap['metrics'] = state.get('metrics') or {}
        if state.get('status'):
            cost_cap['status'] = state['status']
        if state.get('mode'):
            cost_cap['mode'] = state['mode']
        if cost_cap['since_ts'] is None:
            cost_cap['since_ts'] = state.get('since_ts')
        if not cost_cap['period_day']:
            cost_cap['period_day'] = state.get('period_day') or ''
        if not cost_cap['period_month']:
            cost_cap['period_month'] = state.get('period_month') or ''
    except (OSError, json.JSONDecodeError, ValueError):
        pass

cost_cap_log = os.path.join(fed_dir, '.agentis', 'logs', 'cost-cap.log')
if os.path.isfile(cost_cap_log):
    cost_cap['log_path'] = cost_cap_log
    try:
        cost_cap['last_tick_ts'] = int(os.path.getmtime(cost_cap_log))
    except OSError:
        pass

cost_cap_started_at = os.path.join(fed_dir, '.agentis', 'logs',
                                   'cost-cap.sidecar_started_at')
if os.path.isfile(cost_cap_started_at):
    try:
        with open(cost_cap_started_at) as f:
            cost_cap['started_at_ts'] = int(f.read().strip())
    except (OSError, ValueError):
        cost_cap['started_at_ts'] = None
if (cost_cap['started_at_ts'] is not None and cost_cap_interval is not None
        and cost_cap_interval > 0):
    now_ts = int(time.time())
    cost_cap['in_startup_grace'] = (
        (now_ts - cost_cap['started_at_ts']) < (cost_cap_interval + 120)
    )

# Orphan check (#378), parallel to the auto-promote path above.
if not cost_cap['installed'] and cost_cap['last_tick_ts'] is not None:
    now_ts_orphan = int(time.time())
    if (now_ts_orphan - cost_cap['last_tick_ts']) < ORPHAN_INFER_S:
        cost_cap['running_orphan'] = True

# Auto-detection warning: cost_source unknown rate above 50% suggests
# operator should switch to flat mode. Surface in the JSON so the
# dashboard tile can render a hint badge.
m = cost_cap.get('metrics') or {}
unknown = m.get('unknown_cost_pct')
if isinstance(unknown, (int, float)) and unknown > 0.5 and cost_cap['mode'] == 'metered':
    cost_cap['mode_mismatch_hint'] = True
else:
    cost_cap['mode_mismatch_hint'] = False

# --- #352: Per-sidecar listing for the Overview tab ---
# Builds an array of one record per sidecar (auto-promote, cost-cap) for
# the dashboard's `renderSidecarStatus(data)` to render. Each record
# carries name, installed/enabled, age, and a derived health label
# (healthy / silent / down / disabled / not-installed). The auto-promote
# and cost-cap blocks above already collected the raw fields; this section
# unifies them into a single shape the template iterates over.
def _sidecar_status(installed, enabled, in_startup_grace, last_tick_ts,
                   interval_s, now_ts):
    """Reduce sidecar liveness fields to a single status enum the UI uses
    for the per-row pill colour."""
    # Orphan check must run before the `not-installed` short-circuit (#378):
    # a running loop without an install file resolves to `orphan`, not the
    # bare `not-installed` label that misleads the operator into thinking
    # the sidecar is dead.
    if not installed:
        if last_tick_ts is not None and (now_ts - last_tick_ts) < ORPHAN_INFER_S:
            return 'orphan'
        return 'not-installed'
    if not enabled:
        return 'disabled'
    if in_startup_grace:
        return 'healthy'
    if last_tick_ts is None:
        return 'silent'  # never ticked since last installed
    if interval_s is None or interval_s <= 0:
        return 'degraded'  # configured wrong; shouldn't happen
    age = now_ts - last_tick_ts
    if age > 4 * interval_s:
        return 'down'
    if age > 2 * interval_s:
        return 'silent'
    return 'healthy'

now_ts_for_sidecars = int(time.time())
sidecars = [
    {
        'name': 'auto-promote',
        'installed': sidecar.get('installed', False),
        'enabled': sidecar.get('enabled', False),
        'interval_s': sidecar.get('interval_s'),
        'last_tick_ts': sidecar.get('last_tick_ts'),
        'started_at_ts': sidecar.get('started_at_ts'),
        'in_startup_grace': sidecar.get('in_startup_grace', False),
        'running_orphan': sidecar.get('running_orphan', False),
        'status': _sidecar_status(
            sidecar.get('installed', False),
            sidecar.get('enabled', False),
            sidecar.get('in_startup_grace', False),
            sidecar.get('last_tick_ts'),
            sidecar.get('interval_s'),
            now_ts_for_sidecars,
        ),
    },
    {
        'name': 'cost-cap',
        'installed': cost_cap.get('installed', False),
        'enabled': cost_cap.get('enabled', False),
        'interval_s': cost_cap_interval,
        'last_tick_ts': cost_cap.get('last_tick_ts'),
        'started_at_ts': cost_cap.get('started_at_ts'),
        'in_startup_grace': cost_cap.get('in_startup_grace', False),
        'running_orphan': cost_cap.get('running_orphan', False),
        'status': _sidecar_status(
            cost_cap.get('installed', False),
            cost_cap.get('enabled', False),
            cost_cap.get('in_startup_grace', False),
            cost_cap.get('last_tick_ts'),
            cost_cap_interval,
            now_ts_for_sidecars,
        ),
    },
]

# --- #352 (rewritten in #357): Config editor scope ---
# Reads <fed>/.agentis/config + per-colony colony.toml to surface
# (a) optional operator_writes_disabled flag (defensive opt-out — default
# false, i.e. the Config tab is editable by default after #357), and
# (b) per-colony + federation-wide config snapshots so the editor can
# render without a second round-trip. Each scope record:
#   {scope, path, exists, mtime, keys: [{section, key, value}]}
def _read_toml_scope(path):
    """Lightweight TOML reader. Returns {sections: {[section]: {key: val}},
    flat: [(section, key, raw_value)], mtime, exists, error?}.
    Only handles the simple key=value subset our configs use; complex
    arrays or inline tables are surfaced as raw strings without
    structured editing affordance."""
    rec = {
        'path': path,
        'exists': os.path.isfile(path),
        'mtime': None,
        'keys': [],
        'error': None,
    }
    if not rec['exists']:
        return rec
    try:
        # #357: emit ms-precision mtime so the dashboard can drift-check
        # /config/apply against sub-second external rewrites. Server reads
        # mtime in ns and compares ms; the dashboard echoes the value back
        # in the apply payload.
        rec['mtime'] = int(os.path.getmtime(path) * 1000)
    except OSError:
        pass
    try:
        section = ''
        with open(path, encoding='utf-8') as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith('#'):
                    continue
                if line.startswith('[') and line.endswith(']'):
                    section = line[1:-1].strip()
                    continue
                if '=' not in line:
                    continue
                k, _, v = line.partition('=')
                k = k.strip()
                v = v.strip()
                # #359: detect inline arrays (`labels = ["a", "b"]`) and inline
                # tables (`limits = { hi = 1, lo = 0 }`) BEFORE the strip-quotes
                # logic below. The strip-quotes branch only fires when the
                # value starts AND ends with the same quote char, so an inline
                # array slipped through unmodified — but the rendered <input>
                # then carried the literal `["a", "b"]` text and any operator
                # edit corrupted the array. Mark complex values so the
                # renderer can show them read-only with a "complex value"
                # marker instead of an editable input.
                complex_value = False
                if v.startswith('[') or v.startswith('{'):
                    complex_value = True
                # Strip trailing comment (only on scalar values; complex
                # values can contain `#` legitimately inside string elements).
                if (not complex_value and '#' in v
                        and not v.startswith('"') and not v.startswith("'")):
                    v = v.partition('#')[0].rstrip()
                # Unwrap surrounding double quotes / single quotes on SCALAR
                # values so the editor renders a clean value field. The raw
                # form (with quotes intact) is reserved for a future
                # "raw mode" view — for v1 of the Config tab the unquoted
                # value is what the operator wants to edit.
                # Complex values (inline arrays / tables) skip the strip so
                # the read-only marker shows the on-disk text verbatim.
                if (not complex_value
                        and len(v) >= 2
                        and ((v[0] == '"' and v[-1] == '"')
                             or (v[0] == "'" and v[-1] == "'"))):
                    v = v[1:-1]
                rec['keys'].append({
                    'section': section,
                    'key': k,
                    'raw_value': v,
                    'complex_value': complex_value,
                })
    except (OSError, ValueError) as e:
        rec['error'] = str(e)
    return rec

# #357: defensive opt-out gate. Default false (== editable). Only flips
# to read-only when the operator explicitly sets
# `[config_editor].operator_writes_disabled = true` in <fed>/.agentis/
# config. Existing federations have neither key, so they get the new
# editable default with no migration.
operator_writes_disabled = False
fed_config_path = os.path.join(fed_dir, '.agentis', 'config')
fed_config_scope = _read_toml_scope(fed_config_path)
for kv in fed_config_scope.get('keys') or []:
    if kv.get('section') == 'config_editor' and kv.get('key') == 'operator_writes_disabled':
        rv = (kv.get('raw_value') or '').strip().strip('"').strip("'").lower()
        operator_writes_disabled = (rv == 'true')

config_scopes = [
    {'scope': 'federation', 'label': 'federation default', **fed_config_scope},
]
for col in colonies:
    p = os.path.join(fed_dir, col, 'config', 'colony.toml')
    rec = _read_toml_scope(p)
    rec['scope'] = col
    rec['label'] = col + ' override'
    config_scopes.append(rec)

# #359: cross-colony matrix. One row per dotted key that has at least one
# override; columns = federation default + per-colony scopes. The renderer
# shows the matrix on the Config tab so an operator can see at-a-glance
# which colonies override which keys without flipping between scopes.
def _build_config_matrix(scopes):
    """Build {dotted_key: {scope_name: value}} from the scopes list. We
    only emit rows where at least one colony overrides the federation
    default — pure-federation keys are not interesting here."""
    by_key = {}  # dotted_key -> {scope_name: value}
    for s in scopes:
        scope_name = s.get('scope') or ''
        if not scope_name:
            continue
        for kv in (s.get('keys') or []):
            section = kv.get('section') or ''
            key = kv.get('key') or ''
            if not key:
                continue
            dotted = (section + '.' + key) if section else key
            row = by_key.setdefault(dotted, {})
            row[scope_name] = {
                'value': kv.get('raw_value'),
                'complex_value': bool(kv.get('complex_value')),
            }
    # Filter: keep rows where at least one non-federation scope sets the
    # key (== an override exists). Pure-federation keys are uninteresting.
    matrix_rows = []
    for dotted in sorted(by_key.keys()):
        cells = by_key[dotted]
        non_fed_scopes = [s for s in cells.keys() if s != 'federation']
        if not non_fed_scopes:
            continue
        matrix_rows.append({
            'key': dotted,
            'cells': cells,
        })
    return matrix_rows

config_matrix = _build_config_matrix(config_scopes)

config_editor_block = {
    'operator_writes_disabled': operator_writes_disabled,
    'scopes': config_scopes,
    'audit_log_path': os.path.join(fed_dir, '.agentis', 'logs', 'config-edits.jsonl'),
    # #359: cross-colony matrix — sorted list of dotted keys × per-scope
    # values for every key with at least one override.
    'matrix': config_matrix,
}

# #359: per-minute burn rate + projections (Cost tab) and forensic last-N
# watchdog kills (Recovery tab). Both source from existing on-disk streams
# already touched by the collector — no extra disk traffic on the hot path
# beyond the spend / lifecycle reads we already perform once each.
cost_burn = collect_cost_burn_rate(spend_dir, epoch,
                                   fed_config_scope.get('keys') or [])
cost.update({
    'rate_per_min_usd': cost_burn['rate_per_min_usd'],
    'rate_per_min_tokens': cost_burn['rate_per_min_tokens'],
    'projected_1h_usd': cost_burn['projected_1h_usd'],
    'projected_1d_usd': cost_burn['projected_1d_usd'],
    'projected_1w_usd': cost_burn['projected_1w_usd'],
    'projected_1m_usd': cost_burn['projected_1m_usd'],
    'cost_threshold_yellow_usd_per_h': cost_burn['cost_threshold_yellow_usd_per_h'],
    'cost_threshold_red_usd_per_h': cost_burn['cost_threshold_red_usd_per_h'],
    'burn_window_seconds': cost_burn['window_seconds'],
})

watchdog_kills = collect_watchdog_kills(lifecycle_path, id_to_role, max_rows=10)

output = {
    'agents': result,
    'experience_counts': colony_exp,
    'events': events,
    'confidence_changes': conf_changes,
    'decisions': decisions,
    'sidecar': sidecar,
    # #352: per-sidecar listing for renderSidecarStatus(data).
    'sidecars': sidecars,
    'forge_rate_limits': forge_rate_limits,
    'cost': cost,
    'cost_cap': cost_cap,
    # #315 PR 2: federation-wide unified timeline (last 200, ts-desc).
    'timeline': federation_timeline,
    # #352 (rewritten #357): config editor scope + defensive opt-out
    # gate. Default-editable; `operator_writes_disabled = true` flips to
    # read-only. Plus cross-colony matrix per #359.
    'config_editor': config_editor_block,
    # #359: forensic last-10 watchdog-kill events (Recovery tab).
    'watchdog_kills': watchdog_kills,
    # #359: epoch-now stamp so renderers don't have to derive a "stale"
    # cue from a missing field; SSE pushes update this in-place.
    'now_epoch': epoch,
}
print(json.dumps(output))
