#!/usr/bin/env python3
# tools/auto-promote-decisions.py: per-agent promote/evolve/skip decider.
#
# Extracted from the PYEVAL heredoc in tools/auto-promote.sh (#245) to dodge
# the macOS bash 3.2 parser bug on `$(python3 - <<'TAG' ... TAG)`. Same pattern
# as the federation-dashboard-*.py family (#170 / #172) and the adjacent
# auto-promote-config-parser.py / auto-promote-lock.py helpers.
#
# Two invocation modes:
#
# Legacy (auto-promote.sh sidecar) — 11 or 12 positional args:
#   1  daemons JSON     (`agentis daemon list --json` output)
#   2  fed_dir          federation directory (for .agentis/experience/ lookup)
#   3  min_entries
#   4  min_acting_entries
#   5  min_runtime_hours
#   6  reject_rate_threshold
#   7  delta_slope_window
#   8  delta_slope_min
#   9  promote_steps    space-separated "from:to:override" triples
#   10 evolve_slope_neg_for
#   11 evolve_reject_above
#   12 containerized    optional "true"/"false" (default false; #622).
#                       When "true", the PID liveness probe falls back to
#                       `effective_state == "running"` from the daemon-list
#                       JSON because container PIDs are not visible from
#                       the host PID namespace.
#
# Preview (dashboard, #248) — read-only, loads config itself:
#   --preview --config <auto-promote-config.yaml> [--containerized] \
#       <daemons_json> <fed_dir>
#
# Output: JSON array of decision records on stdout. Each record has at least
# {agent, colony, decision} where decision is one of {promote, evolve, skip}.
# Consumed by the `while IFS='|' read ...` loop downstream in auto-promote.sh
# and by federation-dashboard-collector.py via --preview (#248).
#
# Contract is frozen by doc/auto-promote.md and test-auto-promote.sh.

import hashlib
import json
import math
import os
import subprocess
import sys
import time


def _load_config(path):
    """Load auto-promote-config.yaml into the same CFG_* shape the sh sidecar
    receives via auto-promote-config-parser.py. Returns the 9 threshold values
    as a tuple: (min_entries, min_acting_entries, min_runtime_hours,
    reject_rate_threshold, delta_slope_window, delta_slope_min,
    promote_steps_raw, evolve_slope_neg_for, evolve_reject_above)."""
    # Import the simple parser from the sibling helper so both entrypoints
    # share one YAML reader. PyYAML if available, fallback otherwise. The
    # sibling file has a hyphen in its name (not a legal Python identifier),
    # so we load it via importlib rather than `import`.
    try:
        import yaml  # type: ignore
        with open(path) as f:
            cfg = yaml.safe_load(f) or {}
    except ImportError:
        import importlib.util
        script_dir = os.path.dirname(os.path.abspath(__file__))
        parser_path = os.path.join(script_dir, 'auto-promote-config-parser.py')
        spec = importlib.util.spec_from_file_location('apcp', parser_path)
        apcp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(apcp)
        cfg = apcp.parse_yaml_simple(path)

    p = cfg.get('promote', {}).get('prerequisites', {})
    reject = float(p.get('reject_rate_threshold', 0.05))
    default_acting = math.ceil(3.0 / reject) if reject > 0 else 60
    steps = cfg.get('promote', {}).get('steps', [])

    def _fmt_step(s):
        if 'from' not in s or 'to' not in s:
            return None
        override = s.get('min_acting_entries_override')
        if override is None:
            return '%s:%s:' % (s['from'], s['to'])
        return '%s:%s:%d' % (s['from'], s['to'], int(override))

    promote_steps_raw = ' '.join(t for t in (_fmt_step(s) for s in steps) if t is not None)
    e = cfg.get('evolve', {}).get('trigger', {})

    return (
        int(p.get('min_entries', 200)),
        int(p.get('min_acting_entries', default_acting)),
        float(p.get('min_runtime_hours', 48)),
        reject,
        int(p.get('delta_slope_window', 100)),
        float(p.get('delta_slope_min', 0)),
        promote_steps_raw,
        int(e.get('delta_slope_negative_for', 1000)),
        float(e.get('reject_rate_above', 0.20)),
    )


def main():
    argv = sys.argv[1:]

    containerized = False
    if argv and argv[0] == '--preview':
        # Preview mode: read-only call from federation-dashboard-collector.
        # Syntax:
        #   --preview --config <yaml> [--containerized] <daemons_json> <fed_dir>
        rest = argv[1:]
        if not rest or rest[0] != '--config' or len(rest) < 2:
            sys.stderr.write(
                'Usage: %s --preview --config <yaml> '
                '[--containerized] <daemons_json> <fed_dir>\n'
                % os.path.basename(sys.argv[0])
            )
            return 2
        config_path = rest[1]
        rest = rest[2:]
        # Optional --containerized flag (#622).
        if rest and rest[0] == '--containerized':
            containerized = True
            rest = rest[1:]
        if len(rest) != 2:
            sys.stderr.write(
                'Usage: %s --preview --config <yaml> '
                '[--containerized] <daemons_json> <fed_dir>\n'
                % os.path.basename(sys.argv[0])
            )
            return 2
        daemons = json.loads(rest[0])
        fed_dir = rest[1]
        (min_entries, min_acting_entries, min_runtime_hours,
         reject_rate_threshold, delta_slope_window, delta_slope_min,
         promote_steps_raw, evolve_slope_neg_for,
         evolve_reject_above) = _load_config(config_path)
    else:
        # Legacy positional mode used by auto-promote.sh sidecar. Keep byte-
        # identical contract — test-auto-promote.sh asserts it. The 12th arg
        # ('true'/'false') is optional and toggles containerized liveness
        # (#622); absence keeps the pre-#622 behaviour.
        daemons = json.loads(sys.argv[1])
        fed_dir = sys.argv[2]
        min_entries = int(sys.argv[3])
        min_acting_entries = int(sys.argv[4])
        min_runtime_hours = float(sys.argv[5])
        reject_rate_threshold = float(sys.argv[6])
        delta_slope_window = int(sys.argv[7])
        delta_slope_min = float(sys.argv[8])
        promote_steps_raw = sys.argv[9]
        evolve_slope_neg_for = int(sys.argv[10])
        evolve_reject_above = float(sys.argv[11])
        if len(sys.argv) >= 13:
            containerized = (sys.argv[12].lower() == 'true')

    # Tags that mark a row as exercising a tier-gated acting branch (not observe).
    # See doc/auto-promote.md#classification — must match the tag strings emitted
    # by .ag agents per the canonical pattern in CLAUDE.md.
    ACTING_TAGS = {"acted", "review-gated", "emitted", "replicated"}
    OBSERVE_TAGS = {"observed"}

    def classify_entry(entry):
        """Return 'acting', 'observe', or 'legacy' based on the tags field."""
        tags = entry.get('tags') or []
        if not isinstance(tags, list):
            return 'legacy'
        tag_set = {str(t) for t in tags}
        if tag_set & ACTING_TAGS:
            return 'acting'
        if tag_set & OBSERVE_TAGS:
            return 'observe'
        return 'legacy'

    # Parse promote steps ("from:to:override" triples; empty override = use global).
    promote_steps = []
    for triple in promote_steps_raw.split():
        parts = triple.split(':')
        if len(parts) == 3:
            override = int(parts[2]) if parts[2] else None
            promote_steps.append((float(parts[0]), float(parts[1]), override))
        elif len(parts) == 2:
            # Tolerate legacy 2-field format from older configs.
            promote_steps.append((float(parts[0]), float(parts[1]), None))

    now = time.time()
    decisions = []

    # Phase 3 PR 2 of #624: per-pid explorer enrichment. When the daemon
    # under inspection runs explorer.ag, decorate the top-level decision
    # record with {pid, agent_id, specialty, fitness_score} so the
    # dashboard Promote Candidates panel can key by pid (instead of
    # collapsing the 5 specialties to a single "explorer" row) and
    # render specialty + generation in the label. The fitness scalar is
    # computed by the sibling tools/explorer-fitness.py helper which
    # does the cross-agent join (explorer NOVEL settles x auditor
    # confidences x HITL accept ratio). Memo reads are filesystem-direct
    # so this works in both legacy mode and the containerized mode the
    # dashboard uses (#622 PR-1), since the .agentis/ dir is the same
    # host-side bind mount in both cases.
    script_dir = os.path.dirname(os.path.abspath(__file__))
    fitness_script = os.path.join(script_dir, 'explorer-fitness.py')

    def _explorer_memo_read(_fed_dir, key):
        """Read latest value from <fed_dir>/.agentis/memo/<key>.jsonl
        (and the parent-level fallback that mirrors the experience-file
        resolver above). Returns '' on any error."""
        candidates = [
            os.path.join(_fed_dir, '.agentis', 'memo', key + '.jsonl'),
            os.path.normpath(os.path.join(_fed_dir, '..', '.agentis', 'memo', key + '.jsonl')),
        ]
        for path in candidates:
            try:
                with open(path) as f:
                    last_val = ''
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            row = json.loads(line)
                        except (json.JSONDecodeError, ValueError):
                            continue
                        if isinstance(row, dict):
                            v = row.get('value')
                            if v is not None:
                                last_val = v
                    if last_val != '':
                        return last_val
            except (OSError, IOError):
                continue
        return ''

    def _explorer_fitness(_fed_dir, _pid, _agent_id):
        """Invoke explorer-fitness.py and parse its JSON output. Returns
        (fitness_score, breakdown) tuple; on any failure returns
        (0.0, None) so the caller can omit the field cleanly."""
        try:
            proc = subprocess.run(
                ['python3', fitness_script, _fed_dir, str(_pid), str(_agent_id)],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            return (0.0, None)
        if proc.returncode != 0:
            return (0.0, None)
        try:
            payload = json.loads(proc.stdout)
        except (json.JSONDecodeError, ValueError):
            return (0.0, None)
        if not isinstance(payload, dict):
            return (0.0, None)
        try:
            score = float(payload.get('fitness_score', 0.0))
        except (ValueError, TypeError):
            score = 0.0
        breakdown = payload.get('breakdown')
        return (score, breakdown if isinstance(breakdown, dict) else None)

    # Phase 7 PR-A (#628): cache `<colony>/agents/<agent>.ag` sha256
    # per agent inside this loop so the same hash is reused across the
    # evolve decision and the ledger row writer downstream. Returns ''
    # when the .ag file is unreachable so the caller can omit the field
    # cleanly.
    _parent_sha_cache = {}

    def _resolve_parent_sha(_fed_dir, _colony, _agent_name):
        cache_key = (_colony, _agent_name)
        if cache_key in _parent_sha_cache:
            return _parent_sha_cache[cache_key]
        candidate = os.path.join(_fed_dir, _colony, 'agents', _agent_name + '.ag')
        result = ''
        try:
            with open(candidate, 'rb') as fh:
                result = hashlib.sha256(fh.read()).hexdigest()
        except OSError:
            result = ''
        _parent_sha_cache[cache_key] = result
        return result

    # Phase 7 PR-A (#628): scan `<fed_dir>/evolution-ledger.jsonl` for
    # the max recorded generation matching the resolved parent_sha for
    # this agent. Returns 0 when the ledger is absent or no row matches.
    # The ledger path is the auto-evolve-ab.sh default — overridable via
    # `evolve.ledger_path` config but auto-promote-decisions.py reads the
    # default location for legacy-mode positional invocation parity.
    _ledger_rows_cache = None

    def _load_ledger_rows(_fed_dir):
        nonlocal _ledger_rows_cache
        if _ledger_rows_cache is not None:
            return _ledger_rows_cache
        ledger_path = os.path.join(_fed_dir, 'evolution-ledger.jsonl')
        rows = []
        try:
            with open(ledger_path) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rows.append(json.loads(line))
                    except (json.JSONDecodeError, ValueError):
                        continue
        except OSError:
            pass
        _ledger_rows_cache = rows
        return rows

    def _resolve_generation_current(_fed_dir, _parent_sha):
        if not _parent_sha:
            return 0
        sha8 = _parent_sha[:8]
        max_gen = 0
        for row in _load_ledger_rows(_fed_dir):
            if not isinstance(row, dict):
                continue
            if row.get('parent_sha8') != sha8 and row.get('parent_sha') != _parent_sha:
                continue
            gen = row.get('generation')
            try:
                gen_int = int(gen) if gen is not None else 0
            except (ValueError, TypeError):
                gen_int = 0
            if gen_int > max_gen:
                max_gen = gen_int
        return max_gen

    for d in daemons:
        source = d.get('source', '')
        if not source:
            continue
        agent_name = os.path.basename(source)
        if agent_name.endswith('.ag'):
            agent_name = agent_name[:-3]

        pid = d.get('pid', 0)
        state = d.get('state', '')
        agent_id = d.get('agent_id', '')
        colony = d.get('colony', '')
        started_at = d.get('started_at', 0)
        confidence = d.get('confidence')

        # Phase 3 PR 2 of #624: compute explorer-only enrichment up
        # front. Fields are merged into every decisions.append() below
        # via `**explorer_extra` so the early-return skip paths (dead
        # pid, unseeded confidence) still surface pid + specialty + the
        # fitness score the dashboard needs to render per-pid rows. For
        # non-explorer agents `explorer_extra` is empty and the existing
        # decision shape is preserved byte-for-byte (test 12 / test 14
        # contract).
        explorer_extra = {}
        explorer_fitness_evidence = None
        if agent_name == 'explorer':
            specialty = _explorer_memo_read(fed_dir, 'explorer:' + str(pid) + ':specialty')
            generation_raw = _explorer_memo_read(fed_dir, 'explorer:' + str(pid) + ':generation')
            try:
                generation = int(generation_raw) if generation_raw else 0
            except (ValueError, TypeError):
                generation = 0
            fitness_score, fitness_breakdown = _explorer_fitness(fed_dir, pid, agent_id)
            explorer_extra = {
                'pid': pid,
                'agent_id': agent_id,
                'specialty': specialty,
                'fitness_score': fitness_score,
            }
            explorer_fitness_evidence = {
                'specialty': specialty,
                'generation': generation,
                'fitness_score': fitness_score,
            }
            if fitness_breakdown is not None:
                explorer_fitness_evidence['breakdown'] = fitness_breakdown

        def _attach_explorer_evidence(record):
            """Merge Phase 3 PR 2 explorer enrichment into a decision
            record. No-op for non-explorer agents (explorer_extra is
            empty). For explorer rows, adds the top-level fields and
            stamps explorer_fitness into record['evidence'] when an
            evidence dict already exists."""
            if explorer_extra:
                record.update(explorer_extra)
                if explorer_fitness_evidence is not None:
                    ev = record.get('evidence')
                    if isinstance(ev, dict):
                        ev['explorer_fitness'] = explorer_fitness_evidence
            return record

        # Safety guard 3: Per-agent confidence existence check
        # If confidence is None, agent has never been seeded — skip
        if confidence is None:
            decisions.append(_attach_explorer_evidence({
                'agent': agent_name,
                'colony': colony,
                'decision': 'skip',
                'reason': 'confidence not seeded (recall_latest returned null)',
                'pid': pid,
            }))
            continue

        # Safety guard 4: liveness check
        # If pid is missing (0) or dead, skip — we can't verify the daemon
        # is actually running, so acting on it is unsafe.
        #
        # In containerized mode (#622) the host PID namespace can't see
        # container PIDs, so os.kill(pid, 0) is a false-negative every
        # tick. Fall back to `effective_state == "running"` from the
        # daemon-list JSON (also valid for legacy mode; the runtime
        # tracks zombie/running/etc. with a stale-heartbeat probe).
        if containerized:
            effective_state = d.get('effective_state') or state
            if effective_state != 'running':
                decisions.append(_attach_explorer_evidence({
                    'agent': agent_name,
                    'colony': colony,
                    'decision': 'skip',
                    'reason': f'effective_state={effective_state!r} not running',
                    'pid': pid,
                    'confidence': confidence,
                }))
                continue
        else:
            if not pid or pid <= 0:
                decisions.append(_attach_explorer_evidence({
                    'agent': agent_name,
                    'colony': colony,
                    'decision': 'skip',
                    'reason': 'no pid reported by daemon list',
                    'confidence': confidence,
                }))
                continue
            try:
                os.kill(pid, 0)
            except OSError:
                decisions.append(_attach_explorer_evidence({
                    'agent': agent_name,
                    'colony': colony,
                    'decision': 'skip',
                    'reason': f'pid {pid} not alive',
                    'pid': pid,
                    'confidence': confidence,
                }))
                continue

        # Compute runtime hours
        runtime_hours = (now - started_at) / 3600 if started_at else 0

        # Find experience file: .agentis/experience/<agent_id>.jsonl
        # Try fed-local first (preferred since #238 — keeps sibling
        # federations under a shared parent isolated), then the
        # parent-level .agentis/ that the symlinked single-federation
        # layout produced by `dev-apprenticeship/install.sh` lands on
        # (#333). Mirrors the resolver in
        # federation-dashboard/bin/federation-dashboard so the
        # dashboard's Experience Growth and the sidecar's prereq
        # checklist agree on entry counts.
        exp_file = None
        exp_entries = []
        for pattern in [
            os.path.join(fed_dir, '.agentis', 'experience', f'{agent_id}.jsonl'),
            os.path.join(fed_dir, '.agentis', 'experience', f'{agent_name}.jsonl'),
            os.path.normpath(os.path.join(fed_dir, '..', '.agentis', 'experience', f'{agent_id}.jsonl')),
            os.path.normpath(os.path.join(fed_dir, '..', '.agentis', 'experience', f'{agent_name}.jsonl')),
        ]:
            if os.path.isfile(pattern):
                exp_file = pattern
                break

        if exp_file:
            try:
                with open(exp_file) as f:
                    for line in f:
                        line = line.strip()
                        if line:
                            try:
                                exp_entries.append(json.loads(line))
                            except json.JSONDecodeError:
                                pass
            except OSError:
                pass

        entry_count = len(exp_entries)

        # Classify rows by tag so fitness stats ignore observe-step noise.
        acting_entries_list = []
        observe_count = 0
        legacy_count = 0
        for e in exp_entries:
            cls = classify_entry(e)
            if cls == 'acting':
                acting_entries_list.append(e)
            elif cls == 'observe':
                observe_count += 1
            else:
                legacy_count += 1
        acting_count = len(acting_entries_list)

        def _linreg_slope(values):
            if len(values) < 2:
                return 0.0
            n = len(values)
            sx = sum(range(n))
            sy = sum(values)
            sxy = sum(i * v for i, v in enumerate(values))
            sx2 = sum(i * i for i in range(n))
            denom = n * sx2 - sx * sx
            if denom == 0:
                return 0.0
            return (n * sxy - sx * sy) / denom

        # Reject rate on acting rows only. Observe rows are hardcoded to
        # outcome="success" by the canonical .ag pattern, so including them
        # biases the rate toward zero regardless of actual acting quality.
        reject_count = sum(1 for e in acting_entries_list
                           if e.get('verdict') == 'reject'
                           or e.get('outcome') == 'reject'
                           or e.get('rejected', False))
        reject_rate_acting = reject_count / acting_count if acting_count > 0 else 0.0

        # Delta slope over the last N acting rows.
        window_acting = acting_entries_list[-delta_slope_window:] if len(acting_entries_list) >= delta_slope_window else acting_entries_list
        deltas_acting = []
        for e in window_acting:
            delta = e.get('delta')
            if delta is not None:
                try:
                    deltas_acting.append(float(delta))
                except (ValueError, TypeError):
                    pass
        delta_slope_acting = _linreg_slope(deltas_acting)

        # Evolve slope over the longer window, acting rows only.
        evolve_window = acting_entries_list[-evolve_slope_neg_for:] if len(acting_entries_list) >= evolve_slope_neg_for else acting_entries_list
        evolve_deltas = []
        for e in evolve_window:
            delta = e.get('delta')
            if delta is not None:
                try:
                    evolve_deltas.append(float(delta))
                except (ValueError, TypeError):
                    pass
        evolve_slope = _linreg_slope(evolve_deltas)

        evidence = {
            'entries_total': entry_count,
            'entries_acting': acting_count,
            'entries_observe': observe_count,
            'entries_legacy_untagged': legacy_count,
            'runtime_hours': round(runtime_hours, 1),
            'reject_rate_acting': round(reject_rate_acting, 4),
            'delta_slope_acting': round(delta_slope_acting, 6),
            'evolve_slope': round(evolve_slope, 6),
            'confidence': confidence,
            'pid': pid,
        }

        # --- Evolve check (takes priority if agent is degrading) ---
        # Evolve signals are computed from acting rows only: observe-step rows
        # carry a structural "success" outcome and zero delta, so including
        # them would mask degradation on the tier-gated acting path.
        slope_signal = (
            len(acting_entries_list) >= evolve_slope_neg_for
            and evolve_slope < 0
        )
        reject_signal = (
            acting_count > 0 and reject_rate_acting > evolve_reject_above
        )
        evolve_triggered = slope_signal or reject_signal

        if evolve_triggered:
            # Phase 7 PR-A (#628): emit `evolve_window_stagnant`,
            # `parent_sha`, and `generation_current` on every evolve
            # decision so the downstream auto-evolve-ab.sh harness has
            # the full context to write its ledger row without having
            # to recompute the same values.
            evolve_window_stagnant = slope_signal and reject_signal
            parent_sha = _resolve_parent_sha(fed_dir, colony, agent_name)
            generation_current = _resolve_generation_current(fed_dir, parent_sha)
            decisions.append(_attach_explorer_evidence({
                'agent': agent_name,
                'colony': colony,
                'decision': 'evolve',
                'reason': f'evolve triggered (slope={evolve_slope:.6f}, reject_rate_acting={reject_rate_acting:.4f})',
                'evidence': evidence,
                'evolve_window_stagnant': evolve_window_stagnant,
                'parent_sha': parent_sha,
                'generation_current': generation_current,
            }))
            continue

        # --- Promote check ---
        # Find applicable step for current confidence by tier-range membership
        # (ADR-0001: shadow [0.4,0.6), propose [0.6,0.8), review-gated [0.8,0.95)).
        # Pre-#331 this used strict equality with step_from (within 0.001), which
        # broke for any confidence not exactly seeded on a tier boundary — e.g.
        # 0.61 from a typo at install matched no step and the agent was stuck.
        target_step = None
        for step_from, step_to, step_override in promote_steps:
            if step_from <= confidence < step_to:
                target_step = (step_from, step_to, step_override)
                break

        if target_step is None:
            decisions.append(_attach_explorer_evidence({
                'agent': agent_name,
                'colony': colony,
                'decision': 'skip',
                'reason': f'no applicable promote step for confidence={confidence}',
                'evidence': evidence,
            }))
            continue

        step_from, step_to, step_override = target_step
        # Per-step override replaces global min_acting_entries for this step.
        # None -> use global; integer (including 0) -> use override verbatim.
        effective_min_acting = step_override if step_override is not None else min_acting_entries

        # Check all prerequisites. Fitness gates (reject_rate, delta_slope)
        # are skipped when effective_min_acting == 0 because both quantities
        # are undefined on zero acting rows — see doc/auto-promote.md#bootstrap.
        fails = []
        if entry_count < min_entries:
            fails.append(f'entries_total={entry_count} < {min_entries}')
        if acting_count < effective_min_acting:
            fails.append(f'entries_acting={acting_count} < {effective_min_acting}')
        if runtime_hours < min_runtime_hours:
            fails.append(f'runtime={runtime_hours:.1f}h < {min_runtime_hours}h')
        if effective_min_acting > 0:
            if reject_rate_acting >= reject_rate_threshold:
                fails.append(f'reject_rate_acting={reject_rate_acting:.4f} >= {reject_rate_threshold}')
            if delta_slope_acting < delta_slope_min:
                fails.append(f'delta_slope_acting={delta_slope_acting:.6f} < {delta_slope_min}')

        # Record the effective threshold in evidence so the journal explains
        # why this agent's bar differed from the global default.
        evidence['min_acting_entries_effective'] = effective_min_acting

        # #248 (PR B): structured prereqs for dashboard rendering. The textual
        # reason string above stays for journal back-compat; the dashboard walks
        # this list to show a checklist instead of parsing the string.
        prereqs = [
            {'name': 'entries_total', 'value': entry_count,
             'threshold': min_entries, 'op': '>=',
             'meets': entry_count >= min_entries},
            {'name': 'entries_acting', 'value': acting_count,
             'threshold': effective_min_acting, 'op': '>=',
             'meets': acting_count >= effective_min_acting},
            {'name': 'runtime_hours', 'value': round(runtime_hours, 1),
             'threshold': min_runtime_hours, 'op': '>=',
             'meets': runtime_hours >= min_runtime_hours},
        ]
        if effective_min_acting > 0:
            prereqs.append({
                'name': 'reject_rate_acting',
                'value': round(reject_rate_acting, 4),
                'threshold': reject_rate_threshold, 'op': '<',
                'meets': reject_rate_acting < reject_rate_threshold,
            })
            prereqs.append({
                'name': 'delta_slope_acting',
                'value': round(delta_slope_acting, 6),
                'threshold': delta_slope_min, 'op': '>=',
                'meets': delta_slope_acting >= delta_slope_min,
            })
        evidence['prereqs'] = prereqs

        if fails:
            decisions.append(_attach_explorer_evidence({
                'agent': agent_name,
                'colony': colony,
                'decision': 'skip',
                'reason': 'prerequisites not met: ' + '; '.join(fails),
                'evidence': evidence,
            }))
            continue

        # All prerequisites passed — promote
        decisions.append(_attach_explorer_evidence({
            'agent': agent_name,
            'colony': colony,
            'decision': 'promote',
            'from': step_from,
            'to': step_to,
            'evidence': evidence,
        }))

    print(json.dumps(decisions))


if __name__ == '__main__':
    sys.exit(main() or 0)
