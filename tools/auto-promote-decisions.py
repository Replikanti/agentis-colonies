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
# Legacy (auto-promote.sh sidecar) — 11 positional args:
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
#
# Preview (dashboard, #248) — read-only, loads config itself:
#   --preview --config <auto-promote-config.yaml> <daemons_json> <fed_dir>
#
# Output: JSON array of decision records on stdout. Each record has at least
# {agent, colony, decision} where decision is one of {promote, evolve, skip}.
# Consumed by the `while IFS='|' read ...` loop downstream in auto-promote.sh
# and by federation-dashboard-collector.py via --preview (#248).
#
# Contract is frozen by doc/auto-promote.md and test-auto-promote.sh.

import json
import math
import os
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

    if argv and argv[0] == '--preview':
        # Preview mode: read-only call from federation-dashboard-collector.
        # Syntax: --preview --config <yaml> <daemons_json> <fed_dir>
        if len(argv) != 5 or argv[1] != '--config':
            sys.stderr.write(
                'Usage: %s --preview --config <yaml> <daemons_json> <fed_dir>\n'
                % os.path.basename(sys.argv[0])
            )
            return 2
        config_path = argv[2]
        daemons = json.loads(argv[3])
        fed_dir = argv[4]
        (min_entries, min_acting_entries, min_runtime_hours,
         reject_rate_threshold, delta_slope_window, delta_slope_min,
         promote_steps_raw, evolve_slope_neg_for,
         evolve_reject_above) = _load_config(config_path)
    else:
        # Legacy positional mode used by auto-promote.sh sidecar. Keep byte-
        # identical contract — test-auto-promote.sh asserts it.
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

    # Tags that mark a row as exercising a tier-gated acting branch (not observe).
    # See doc/auto-promote.md#classification — must match the tag strings emitted
    # by .ag agents per the canonical pattern in CLAUDE.md.
    ACTING_TAGS = {"acted", "review-gated", "emitted"}
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

        # Safety guard 3: Per-agent confidence existence check
        # If confidence is None, agent has never been seeded — skip
        if confidence is None:
            decisions.append({
                'agent': agent_name,
                'colony': colony,
                'decision': 'skip',
                'reason': 'confidence not seeded (recall_latest returned null)',
                'pid': pid,
            })
            continue

        # Safety guard 4: PID liveness check
        # If pid is missing (0) or dead, skip — we can't verify the daemon
        # is actually running, so acting on it is unsafe.
        if not pid or pid <= 0:
            decisions.append({
                'agent': agent_name,
                'colony': colony,
                'decision': 'skip',
                'reason': 'no pid reported by daemon list',
                'confidence': confidence,
            })
            continue
        try:
            os.kill(pid, 0)
        except OSError:
            decisions.append({
                'agent': agent_name,
                'colony': colony,
                'decision': 'skip',
                'reason': f'pid {pid} not alive',
                'pid': pid,
                'confidence': confidence,
            })
            continue

        # Compute runtime hours
        runtime_hours = (now - started_at) / 3600 if started_at else 0

        # Find experience file: .agentis/experience/<agent_id>.jsonl
        # Try both agent_id-based and agent_name-based paths
        exp_file = None
        exp_entries = []
        for pattern in [
            os.path.join(fed_dir, '.agentis', 'experience', f'{agent_id}.jsonl'),
            os.path.join(fed_dir, '.agentis', 'experience', f'{agent_name}.jsonl'),
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
        evolve_triggered = False
        if len(acting_entries_list) >= evolve_slope_neg_for and evolve_slope < 0:
            evolve_triggered = True
        if acting_count > 0 and reject_rate_acting > evolve_reject_above:
            evolve_triggered = True

        if evolve_triggered:
            decisions.append({
                'agent': agent_name,
                'colony': colony,
                'decision': 'evolve',
                'reason': f'evolve triggered (slope={evolve_slope:.6f}, reject_rate_acting={reject_rate_acting:.4f})',
                'evidence': evidence,
            })
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
            decisions.append({
                'agent': agent_name,
                'colony': colony,
                'decision': 'skip',
                'reason': f'no applicable promote step for confidence={confidence}',
                'evidence': evidence,
            })
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
            decisions.append({
                'agent': agent_name,
                'colony': colony,
                'decision': 'skip',
                'reason': 'prerequisites not met: ' + '; '.join(fails),
                'evidence': evidence,
            })
            continue

        # All prerequisites passed — promote
        decisions.append({
            'agent': agent_name,
            'colony': colony,
            'decision': 'promote',
            'from': step_from,
            'to': step_to,
            'evidence': evidence,
        })

    print(json.dumps(decisions))


if __name__ == '__main__':
    sys.exit(main() or 0)
