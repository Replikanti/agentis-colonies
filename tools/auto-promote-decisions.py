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
# Cross-run aggregation (Phase 5 PR-C of #626) — opt-in side-effect mode:
#   --cross-run --window <N> --persistent-dir <dir> \
#       <daemons_json> <fed_dir> <... legacy positional args ...>
# Runs the same per-agent decision loop, then APPENDS a per-run record to
# `<persistent-dir>/run-history.jsonl` (aggregating `evidence.colony_fitness`
# rows by specialty) and DERIVES `<persistent-dir>/fittest_specialties.json`
# from the last N records using exponential decay (weight = 0.7^(N-1-i)).
# The decisions JSON array on stdout is UNCHANGED (no extra rows, no
# reordering) so `auto-promote.sh`'s `while IFS='|' read` loop is
# byte-identity safe vs legacy callers.
#
# Output: JSON array of decision records on stdout. Each record has at least
# {agent, colony, decision} where decision is one of {promote, evolve, skip}.
# Consumed by the `while IFS='|' read ...` loop downstream in auto-promote.sh
# and by federation-dashboard-collector.py via --preview (#248).
#
# Contract is frozen by doc/auto-promote.md and test-auto-promote.sh.

import datetime
import hashlib
import json
import math
import os
import subprocess
import sys
import time


# #709: memo-freshness helpers (read_memo_raw / parse_last_check_epoch /
# resolve_tick_interval_ms / STALENESS_TICKS) extracted into the shared
# tools/agentis_memo_freshness.py module so this sidecar and the dashboard
# collector consume the single source of truth instead of mirroring the
# implementation (former drift documented in #683/#697/#700/#705/#706/#708).
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)
import agentis_memo_freshness as freshness  # noqa: E402


def _load_config(path):
    """Load auto-promote-config.yaml into the same CFG_* shape the sh sidecar
    receives via auto-promote-config-parser.py. Returns the 9 base threshold
    values plus the 3 #823 efficiency-bonus params as a 12-tuple:
    (min_entries, min_acting_entries, min_runtime_hours,
    reject_rate_threshold, delta_slope_window, delta_slope_min,
    promote_steps_raw, evolve_slope_neg_for, evolve_reject_above,
    w_efficiency, min_rule_hit_acting_ticks, rule_hit_tag_allowlist)."""
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

    # #823: rule-hit efficiency-bonus params. Additive to the per-colony
    # fitness scalar, not a hard promote gate (selection-pressure signal).
    # Defaults match the YAML so federations that omit the keys are
    # behaviourally identical to those that paste in the defaults.
    w_efficiency = float(cfg.get('weights', {}).get('efficiency_bonus', 0.15))
    min_rule_hit_acting_ticks = int(p.get('min_rule_hit_acting_ticks', 5))
    rule_hit_tag_allowlist = list(cfg.get('promote', {}).get(
        'rule_hit_tag_allowlist', ['distilled', 'rule-hit']))

    # Demote arm (#898). Defaults match the demote: block in
    # auto-promote-config.yaml so federations whose configs predate the
    # block behave identically.
    d = cfg.get('demote', {}) or {}
    demote_enabled = bool(d.get('enabled', True))
    demote_slope_threshold = float(d.get('delta_slope_threshold', -0.05))
    demote_min_entries = int(d.get('min_entries_for_demote', 30))
    demote_hard_floor = float(d.get('hard_floor', 0.4))

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
        w_efficiency,
        min_rule_hit_acting_ticks,
        rule_hit_tag_allowlist,
        demote_enabled,
        demote_slope_threshold,
        demote_min_entries,
        demote_hard_floor,
    )


def main():
    argv = sys.argv[1:]

    # Phase 5 PR-C (#626): opt-in cross-run aggregation flag. Parsed
    # before --preview / legacy dispatch so the flag can ride alongside
    # either invocation form. When set, after the decisions loop builds
    # the JSON array, an additional side-effect writes
    # <persistent_dir>/run-history.jsonl + fittest_specialties.json. The
    # stdout JSON array is byte-identical to the legacy form (test 12 of
    # test-auto-promote.sh enforces; the new --cross-run path is opt-in).
    cross_run_enabled = False
    cross_run_window = 5
    persistent_dir = None
    filtered = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--cross-run':
            cross_run_enabled = True
            i += 1
            continue
        if a == '--window':
            if i + 1 >= len(argv):
                sys.stderr.write('Usage: --window <N> requires a value\n')
                return 2
            try:
                cross_run_window = int(argv[i + 1])
            except (ValueError, TypeError):
                sys.stderr.write('Usage: --window <N> requires an integer\n')
                return 2
            i += 2
            continue
        if a == '--persistent-dir':
            if i + 1 >= len(argv):
                sys.stderr.write('Usage: --persistent-dir <dir> requires a value\n')
                return 2
            persistent_dir = argv[i + 1]
            i += 2
            continue
        filtered.append(a)
        i += 1
    argv = filtered

    if cross_run_enabled and not persistent_dir:
        sys.stderr.write('--cross-run requires --persistent-dir <dir>\n')
        return 2

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
         evolve_reject_above, w_efficiency,
         min_rule_hit_acting_ticks,
         rule_hit_tag_allowlist,
         demote_enabled, demote_slope_threshold,
         demote_min_entries, demote_hard_floor) = _load_config(config_path)
    else:
        # Legacy positional mode used by auto-promote.sh sidecar. Keep byte-
        # identical contract — test-auto-promote.sh asserts it. The 12th arg
        # ('true'/'false') is optional and toggles containerized liveness
        # (#622); absence keeps the pre-#622 behaviour.
        daemons = json.loads(argv[0])
        fed_dir = argv[1]
        min_entries = int(argv[2])
        min_acting_entries = int(argv[3])
        min_runtime_hours = float(argv[4])
        reject_rate_threshold = float(argv[5])
        delta_slope_window = int(argv[6])
        delta_slope_min = float(argv[7])
        promote_steps_raw = argv[8]
        evolve_slope_neg_for = int(argv[9])
        evolve_reject_above = float(argv[10])
        if len(argv) >= 12:
            containerized = (argv[11].lower() == 'true')
        # #823: legacy positional invocation (auto-promote.sh sidecar) does
        # not pass the efficiency-bonus knobs — auto-promote-config-parser.py
        # has not been extended for this PR. Fall back to the same defaults
        # _load_config does, so a federation whose .ag agents emit zero
        # rule-hit tags sees efficiency_bonus = 0 on every agent and the
        # legacy → preview byte-identity contract (test 12) holds.
        w_efficiency = 0.15
        min_rule_hit_acting_ticks = 5
        rule_hit_tag_allowlist = ['distilled', 'rule-hit']
        # #898: demote arm. Legacy positional invocation reads four extra
        # `CFG_DEMOTE_*` exports from auto-promote-config-parser.py at
        # positions 12-15 (after the optional containerized flag at 11).
        # Defaults match _load_config + the YAML demote: block so a
        # federation that pre-dates the demote arm sees byte-identical
        # behaviour as long as the new positions are absent.
        demote_enabled = True
        demote_slope_threshold = -0.05
        demote_min_entries = 30
        demote_hard_floor = 0.4
        if len(argv) >= 16:
            demote_enabled = (argv[12].lower() in ('true', '1', 'yes'))
            demote_slope_threshold = float(argv[13])
            demote_min_entries = int(argv[14])
            demote_hard_floor = float(argv[15])

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

    def _count_rule_hit_ticks(entries, allowlist):
        """Count rows whose `tags` field contains any allowlisted rule-hit
        tag (#823). Callers pass the already-classified acting-entries list,
        so the result is a strict subset of acting_count and the ratio
        rule_hit_ticks / acting_count is well-defined on [0, 1].

        Canonical allowlist literals come from auto-promote-config.yaml and
        match the noticer distillation pilot tag schema (#820): `distilled`
        for the first rule-hit on a rule, `rule-hit` for subsequent hits.
        Operators can extend the allowlist (e.g. with `rule-reinforced`)
        without code change."""
        allow = {str(t) for t in allowlist}
        n = 0
        for e in entries:
            tags = e.get('tags') or []
            if not isinstance(tags, list):
                continue
            if {str(t) for t in tags} & allow:
                n += 1
        return n

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

    # Phase 9 PR-B (#663): generalised per-pid enrichment. Phase 3 PR 2
    # of #624 introduced explorer-only fields (`pid`, `agent_id`,
    # `specialty`, `fitness_score`) at the top level of every decision
    # record so the dashboard could render one row per explorer pid
    # instead of collapsing the 5 specialties into one. PR-B widens
    # that path to all 18 research-foundry colonies via SIDE_BY_COLONY
    # below: each known colony triggers a colony-fitness.py invocation
    # (with the appropriate --colony flag) plus a memo read for the
    # per-pid specialty + generation. Agents not listed in
    # SIDE_BY_COLONY (e.g. dev-apprenticeship colonies, ad-hoc
    # fixtures in tests) keep the pre-PR-B contract: no top-level
    # decoration, no `colony_fitness` evidence key. That keeps
    # test-auto-promote.sh test 12 (legacy/preview byte-identity on a
    # /fake/x.ag fixture) green. PR-C will populate the per-pid memos
    # for non-explorer colonies; this PR's keys default to empty/None
    # so the dashboard's existing per-pid renderer keeps working.
    script_dir = os.path.dirname(os.path.abspath(__file__))
    fitness_script = os.path.join(script_dir, 'colony-fitness.py')

    # Mirror of tools/colony-fitness.py SIDE_BY_COLONY. Hardcoded
    # locally so this module stays import-free (the sibling file has a
    # hyphen and is not a legal Python identifier; importlib would
    # work but adds a hot-path syscall the sidecar pays every tick).
    SIDE_BY_COLONY = {
        'explorer': 'discovery',
        'noticer': 'discovery',
        'skeptic': 'discovery',
        'formulator': 'discovery',
        'verifier': 'discovery',
        'novelty': 'discovery',
        'arxiv-search': 'audit',
        'oeis-search': 'audit',
        'groupprops-search': 'audit',
        'scholar-search': 'audit',
        'prior_advocate': 'audit',
        'auditor': 'audit',
        'introducer': 'preprint',
        'theorist': 'preprint',
        'computer': 'preprint',
        'editor': 'preprint',
        'reviewer': 'preprint',
        'submitter': 'preprint',
    }

    def _colony_memo_read(_fed_dir, key):
        """Read latest value from <fed_dir>/.agentis/memo/<key>.jsonl
        (and the parent-level fallback that mirrors the experience-file
        resolver above). Returns '' on any error.

        Phase 9 PR-B (#663): renamed from `_explorer_memo_read`; same
        contract, takes any memo key. PR-C will populate
        `<colony>:<pid>:specialty` + `:generation` for non-explorer
        colonies; PR-B reads return empty strings for those keys."""
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

    def _colony_fitness(_fed_dir, _pid, _agent_id, _colony_name):
        """Invoke colony-fitness.py and parse its JSON output. Returns
        (fitness_score, breakdown) tuple; on any failure returns
        (0.0, None) so the caller can omit the field cleanly.

        Phase 9 PR-B (#663): renamed from `_explorer_fitness`; takes
        the colony name and forwards it via `--colony <name>` so the
        sibling helper picks the discovery/audit/preprint formula."""
        try:
            proc = subprocess.run(
                ['python3', fitness_script,
                 _fed_dir, str(_pid), str(_agent_id),
                 '--colony', str(_colony_name)],
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

        # Phase 9 PR-B (#663): generalised per-pid enrichment for the
        # 18 research-foundry colonies (Phase 3 PR 2 of #624 was
        # explorer-only). Fields are merged into every decisions.append()
        # below via `**colony_extra` so the early-return skip paths
        # (dead pid, unseeded confidence) still surface pid + specialty
        # + the fitness score the dashboard needs to render per-pid
        # rows. Agents not listed in SIDE_BY_COLONY (e.g. test fixtures
        # like /fake/x.ag, dev-apprenticeship colonies) keep
        # `colony_extra` empty and the pre-PR-B decision shape — that
        # is the test 12 / test 14 byte-identity contract.
        colony_extra = {}
        colony_fitness_evidence = None
        explorer_fitness_evidence = None
        if agent_name in SIDE_BY_COLONY:
            specialty = _colony_memo_read(fed_dir, agent_name + ':' + str(pid) + ':specialty')
            generation_raw = _colony_memo_read(fed_dir, agent_name + ':' + str(pid) + ':generation')
            try:
                generation = int(generation_raw) if generation_raw else 0
            except (ValueError, TypeError):
                generation = 0
            fitness_score, fitness_breakdown = _colony_fitness(fed_dir, pid, agent_id, agent_name)
            colony_extra = {
                'pid': pid,
                'agent_id': agent_id,
                'specialty': specialty,
                'fitness_score': fitness_score,
            }
            colony_fitness_evidence = {
                'colony': agent_name,
                'side': SIDE_BY_COLONY.get(agent_name, ''),
                'specialty': specialty,
                'generation': generation,
                'fitness_score': fitness_score,
            }
            if fitness_breakdown is not None:
                colony_fitness_evidence['breakdown'] = fitness_breakdown
            # Phase 9 PR-B back-compat alias: the dashboard's pre-PR-B
            # Promote Candidates renderer reads `evidence.explorer_fitness`
            # to label per-pid rows. Mirror the colony_fitness payload
            # under that key for the explorer colony so the existing
            # template keeps working without changes. PR-C-aware
            # dashboards should prefer `evidence.colony_fitness`.
            if agent_name == 'explorer':
                explorer_fitness_evidence = {
                    'specialty': specialty,
                    'generation': generation,
                    'fitness_score': fitness_score,
                }
                if fitness_breakdown is not None:
                    explorer_fitness_evidence['breakdown'] = fitness_breakdown

        def _attach_explorer_evidence(record):
            """Merge per-colony enrichment into a decision record.
            No-op for agents not listed in SIDE_BY_COLONY (test
            fixtures, dev-apprenticeship daemons). For listed colonies
            adds the top-level pid/agent_id/specialty/fitness_score
            fields and stamps `colony_fitness` into record['evidence']
            when an evidence dict already exists. For the explorer
            colony also stamps `explorer_fitness` as a back-compat
            alias so pre-PR-B dashboard templates keep rendering."""
            if colony_extra:
                record.update(colony_extra)
                ev = record.get('evidence')
                if isinstance(ev, dict):
                    if colony_fitness_evidence is not None:
                        ev['colony_fitness'] = colony_fitness_evidence
                    if explorer_fitness_evidence is not None:
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
        # tick. #706: trust memo freshness (`<agent>:last_check` within
        # STALENESS_TICKS * tick_interval) over `effective_state`, since
        # the daemon registry's state field stays stale across sleep/reboot
        # cycles even when the in-process tick loop keeps writing the memo.
        # `effective_state == "running"` remains a valid fall-through for
        # legacy callers; the memo path simply unblocks daemons whose
        # registry record lies. #736: per-role staleness window via
        # staleness_ticks_for() -- tick-driven roles (5), listen-driven
        # research-foundry roles (60), dev-apprenticeship roles (30),
        # unknown roles fall back to the global STALENESS_TICKS (15).
        # #799: the `<agent>:last_check` memo write convention is
        # unreliable -- many .ag tick bodies short-circuit before reaching
        # the memo_write call (missing-upstream picker-empty paths, tier
        # branches that bail out early, exec sh failures on the
        # `date -u +%Y-...` helper). Concrete reproducer: noticer.ag wrote
        # 20 last_check entries across 118 actual ticks (~17% coverage)
        # during the post-#798 claude run, because the noticer-without-
        # upstream-output path returns before either of its two write
        # sites. Result was the auto-promote sidecar skipping all 18
        # research-foundry colonies with reason 'memo last_check stale'
        # while the runtime was clearly ticking them (118 'tick conf' log
        # lines per heartbeat). Fall back to the runtime-maintained
        # heartbeat file at `<fed_dir>/.agentis/daemon/<agent_id>.heartbeat`
        # (line 1 = ms-since-epoch of the last completed tick, written by
        # `write_heartbeat_ext` in `src/daemon/runner.rs` every tick
        # regardless of `.ag` branch taken). Apply the same staleness
        # window as last_check so the safety semantics are preserved.
        if containerized:
            last_check_epoch = freshness.parse_last_check_epoch(freshness.read_memo_raw(fed_dir, agent_name + ':last_check'))
            fresh = False
            if last_check_epoch is not None:
                tick_ms = freshness.resolve_tick_interval_ms(agent_name, colony, fed_dir)
                fresh = (time.time() - last_check_epoch) < freshness.staleness_ticks_for(agent_name) * (tick_ms / 1000.0)
            # #799: heartbeat-file fallback -- runtime-maintained, branch-agnostic.
            if not fresh and agent_id:
                heartbeat_path = os.path.join(fed_dir, '.agentis', 'daemon', str(agent_id) + '.heartbeat')
                try:
                    with open(heartbeat_path) as _hbf:
                        line1 = _hbf.readline().strip()
                        if line1.isdigit():
                            hb_epoch = int(line1) / 1000.0
                            tick_ms = freshness.resolve_tick_interval_ms(agent_name, colony, fed_dir)
                            fresh = (time.time() - hb_epoch) < freshness.staleness_ticks_for(agent_name) * (tick_ms / 1000.0)
                except (OSError, IOError, ValueError):
                    pass
            effective_state = d.get('effective_state') or state
            if not fresh and effective_state != 'running':
                decisions.append(_attach_explorer_evidence({
                    'agent': agent_name,
                    'colony': colony,
                    'decision': 'skip',
                    'reason': f'memo last_check stale, heartbeat file stale or missing, and effective_state={effective_state!r} not running',
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

        # #823: rule-hit efficiency bonus. Additive selection-pressure
        # signal layered on top of the per-colony fitness scalar so two
        # agents producing identical outcome quality can still be ranked
        # by how much LLM use the rule cache saved. Gated below the acting
        # floor to suppress sub-statistical-sample noise (one rule-hit at
        # n=2 reads as 50% rule-driven on near-zero evidence). The bonus
        # is purely a ranking signal here; promote prereq gates downstream
        # are unchanged so the binary promote/skip outcome is identical
        # for federations whose .ag agents emit zero rule-hit tags
        # (backward-compat — see #820 for the canonical tag schema).
        rule_hit_ticks = _count_rule_hit_ticks(acting_entries_list, rule_hit_tag_allowlist)
        efficiency_floor_met = acting_count >= min_rule_hit_acting_ticks
        if efficiency_floor_met and acting_count > 0:
            rule_hit_ratio = rule_hit_ticks / acting_count
            efficiency_bonus = rule_hit_ratio * w_efficiency
        else:
            rule_hit_ratio = 0.0
            efficiency_bonus = 0.0

        # Enrich the per-colony fitness payload (if attached) with the new
        # bonus so the dashboard and cross-run aggregator see one combined
        # `fitness_score_total` = colony scalar + (rule_hit_ratio * w_efficiency).
        # `colony_fitness_evidence` was populated earlier in this loop for
        # agents in SIDE_BY_COLONY only; mutating in place propagates via
        # the by-reference attach in _attach_explorer_evidence below.
        if colony_fitness_evidence is not None:
            base_score = float(colony_fitness_evidence.get('fitness_score', 0.0))
            colony_fitness_evidence['rule_hit_ticks'] = rule_hit_ticks
            colony_fitness_evidence['rule_hit_ratio'] = round(rule_hit_ratio, 6)
            colony_fitness_evidence['efficiency_bonus'] = round(efficiency_bonus, 6)
            colony_fitness_evidence['efficiency_floor_met'] = efficiency_floor_met
            colony_fitness_evidence['fitness_score_total'] = round(base_score + efficiency_bonus, 6)

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
            # #823: rule-hit efficiency-bonus fields. Surfaced on every
            # decision record that builds an evidence dict so the dashboard
            # can render the bonus alongside the other prereq stats. For
            # agents whose .ag emits no `distilled` / `rule-hit` learn rows
            # all four fields read as zero / false (backward compatible).
            'rule_hit_ticks': rule_hit_ticks,
            'rule_hit_ratio': round(rule_hit_ratio, 6),
            'efficiency_bonus': round(efficiency_bonus, 6),
            'efficiency_floor_met': efficiency_floor_met,
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

        # --- Demote check (#898) ---
        # Closes the federation feedback loop the v1.18.0 eval_ag_with_outcome
        # substrate exposure opened. Triggers strictly before the promote
        # check so an agent at autonomous with sustained negative slope gets
        # stepped down BEFORE we even attempt to promote it (which is a no-op
        # at the ladder top — pre-#898 explorer was stuck at 0.95 forever
        # despite -5.25 aggregate fitness, see smoke #18 forensic).
        #
        # Trigger conjunction (all must hold):
        # (1) demote_enabled — federation opted in via config (default true)
        # (2) entry_count >= demote_min_entries — bootstrap stability;
        #     don't demote on noise from the first few rows
        # (3) acting_count > 0 — slope is undefined on zero acting rows
        # (4) delta_slope_acting <= demote_slope_threshold — the agent
        #     is materially degrading on the acting branch
        # (5) confidence > demote_hard_floor — never demote below shadow;
        #     at the floor, evolve_self is the next step instead
        #
        # Step calculation: pick the largest step_from in the ladder that
        # is strictly less than the current confidence. For confidence=0.95
        # with ladder [(0.4,0.6),(0.6,0.8),(0.8,0.95)] that's 0.8. For 0.8
        # it's 0.6. For 0.6 it's 0.4 (the floor — we step TO the floor but
        # never below). For 0.4 we don't fire (caught by gate 5).
        # Compute the MEAN delta on the acting window for the demote
        # threshold. Using mean instead of slope (the metric for evolve)
        # is intentional: demote reacts to a sustained low absolute
        # fitness level (e.g. 56 partials × -0.10 = -5.6 net), where the
        # linear-regression slope is 0 because the deltas are uniform.
        # Slope would only catch DEGRADATION (negative trend) — which is
        # what evolve already does. Demote is the lighter-touch precursor
        # firing on absolute level.
        demote_delta_mean = (
            sum(deltas_acting) / len(deltas_acting)
            if deltas_acting else 0.0
        )

        demote_floor_met = confidence > demote_hard_floor
        demote_signal_met = (
            acting_count > 0
            and demote_delta_mean <= demote_slope_threshold
        )
        demote_entries_met = entry_count >= demote_min_entries
        demote_triggered = (
            demote_enabled
            and demote_floor_met
            and demote_signal_met
            and demote_entries_met
        )
        if os.environ.get('AUTO_PROMOTE_DEBUG'):
            sys.stderr.write(
                f'DEMOTE_DBG {agent_name}: enabled={demote_enabled} '
                f'conf={confidence} floor={demote_hard_floor} floor_met={demote_floor_met} '
                f'mean_delta={demote_delta_mean} thresh={demote_slope_threshold} signal_met={demote_signal_met} '
                f'entries={entry_count} min={demote_min_entries} entries_met={demote_entries_met} '
                f'triggered={demote_triggered}\n'
            )

        if demote_triggered:
            # Find the largest step_from strictly below current confidence;
            # this is the rung we step DOWN to. Ladder is sorted ascending
            # by step_from so the last match wins.
            demote_target = None
            for step_from, step_to, step_override in promote_steps:
                if step_from < confidence:
                    demote_target = step_from
            # If no ladder rung is below current (e.g. confidence=0.3 below
            # the lowest step_from=0.4), fall through — we should not be
            # here because gate 5 would have caught it, but defend in case
            # an operator pinned the ladder above the hard floor.
            if demote_target is not None and demote_target < confidence:
                demote_prereqs = [
                    {'name': 'demote_enabled', 'value': demote_enabled,
                     'threshold': True, 'op': '==',
                     'meets': demote_enabled},
                    {'name': 'entries_total', 'value': entry_count,
                     'threshold': demote_min_entries, 'op': '>=',
                     'meets': demote_entries_met},
                    {'name': 'delta_mean_acting',
                     'value': round(demote_delta_mean, 6),
                     'threshold': demote_slope_threshold, 'op': '<=',
                     'meets': demote_signal_met},
                    {'name': 'confidence_above_floor',
                     'value': confidence,
                     'threshold': demote_hard_floor, 'op': '>',
                     'meets': demote_floor_met},
                ]
                evidence['demote_prereqs'] = demote_prereqs
                decisions.append(_attach_explorer_evidence({
                    'agent': agent_name,
                    'colony': colony,
                    'decision': 'demote',
                    'from': confidence,
                    'to': demote_target,
                    'reason': (
                        f'demote triggered (mean_delta={demote_delta_mean:.6f} '
                        f'<= {demote_slope_threshold}, '
                        f'confidence {confidence} > floor {demote_hard_floor})'
                    ),
                    'evidence': evidence,
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

    # Phase 5 PR-C (#626): cross-run fitness aggregation. Side-effect
    # only — stdout is unchanged so legacy callers (auto-promote.sh's
    # `while IFS='|' read` loop, federation-dashboard-collector via
    # --preview) see the same JSON they always did. Aggregates the
    # current run's per-pid `evidence.colony_fitness.fitness_score` by
    # specialty, appends one record to run-history.jsonl, then re-derives
    # fittest_specialties.json from the last N records using exponential
    # decay (weight = 0.7^(N-1-i)).
    if cross_run_enabled and persistent_dir:
        try:
            _aggregate_cross_run(decisions, persistent_dir, cross_run_window)
        except (OSError, ValueError) as e:
            sys.stderr.write(
                'auto-promote-decisions: cross-run aggregation failed '
                '(non-fatal): ' + str(e) + '\n'
            )


# Phase 5 PR-C (#626): cross-run aggregation helpers. Kept module-level
# (not nested) so tests can drive them directly with synthetic decision
# arrays without going through the full main() entrypoint.

CROSS_RUN_SCHEMA_VERSION = 1
CROSS_RUN_DECAY_FACTOR = 0.7


def _aggregate_cross_run(decisions, persistent_dir, window):
    """Append this run's per-specialty fitness to run-history.jsonl and
    re-derive fittest_specialties.json from the last `window` records.

    Side-effect only; never raises into the stdout path. Caller wraps
    in try/except so an IO failure remains non-fatal."""
    os.makedirs(persistent_dir, exist_ok=True)
    history_path = os.path.join(persistent_dir, 'run-history.jsonl')
    fittest_path = os.path.join(persistent_dir, 'fittest_specialties.json')

    # Aggregate the current run's decisions by specialty. Use
    # evidence.colony_fitness.{specialty, fitness_score} since PR-B
    # ensures it is attached to every research-foundry colony's decision
    # record (explorer-only in PR-A, all 18 in PR-B). Test fixtures
    # outside SIDE_BY_COLONY contribute nothing here, which is fine.
    by_specialty = {}
    for d in decisions:
        if not isinstance(d, dict):
            continue
        ev = d.get('evidence')
        if not isinstance(ev, dict):
            continue
        cf = ev.get('colony_fitness')
        if not isinstance(cf, dict):
            continue
        sp = cf.get('specialty')
        if not isinstance(sp, str) or not sp:
            continue
        try:
            score = float(cf.get('fitness_score', 0.0))
        except (TypeError, ValueError):
            continue
        agg = by_specialty.setdefault(sp, {'sum_fitness': 0.0, 'count': 0})
        agg['sum_fitness'] += score
        agg['count'] += 1
    for sp, agg in by_specialty.items():
        if agg['count'] > 0:
            agg['avg_fitness'] = agg['sum_fitness'] / agg['count']
        else:
            agg['avg_fitness'] = 0.0

    run_record = {
        'schema': CROSS_RUN_SCHEMA_VERSION,
        'run_id': time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()),
        'run_end_ts': int(time.time()),
        'by_specialty': by_specialty,
    }
    with open(history_path, 'a') as fh:
        fh.write(json.dumps(run_record))
        fh.write('\n')

    # Re-derive fittest_specialties.json from the last N records.
    records = []
    try:
        with open(history_path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                if not isinstance(row, dict):
                    continue
                if row.get('schema') != CROSS_RUN_SCHEMA_VERSION:
                    sys.stderr.write(
                        'auto-promote-decisions: skipping run-history.jsonl '
                        'record with schema=' + str(row.get('schema'))
                        + ' (expected ' + str(CROSS_RUN_SCHEMA_VERSION) + ')\n'
                    )
                    continue
                records.append(row)
    except OSError:
        records = []

    if not records:
        return

    if window > 0:
        records = records[-window:]
    n = len(records)

    weighted_sum = {}
    total_weight = {}
    runs_seen = {}
    for i, rec in enumerate(records):
        weight = CROSS_RUN_DECAY_FACTOR ** (n - 1 - i)
        bs = rec.get('by_specialty') or {}
        if not isinstance(bs, dict):
            continue
        for sp, agg in bs.items():
            if not isinstance(agg, dict):
                continue
            try:
                avg = float(agg.get('avg_fitness', 0.0))
            except (TypeError, ValueError):
                continue
            weighted_sum[sp] = weighted_sum.get(sp, 0.0) + weight * avg
            total_weight[sp] = total_weight.get(sp, 0.0) + weight
            runs_seen[sp] = runs_seen.get(sp, 0) + 1

    ranked = []
    for sp in weighted_sum:
        tw = total_weight.get(sp, 0.0)
        if tw <= 0:
            continue
        ranked.append({
            'specialty': sp,
            'avg_fitness': weighted_sum[sp] / tw,
            'runs_seen': runs_seen.get(sp, 0),
        })
    ranked.sort(key=lambda r: r['avg_fitness'], reverse=True)

    payload = {
        'schema': CROSS_RUN_SCHEMA_VERSION,
        'generated_at': int(time.time()),
        'window_size': window,
        'decay_factor': CROSS_RUN_DECAY_FACTOR,
        'ranked': ranked,
    }
    tmp_path = fittest_path + '.tmp'
    with open(tmp_path, 'w') as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write('\n')
    os.replace(tmp_path, fittest_path)


if __name__ == '__main__':
    sys.exit(main() or 0)
