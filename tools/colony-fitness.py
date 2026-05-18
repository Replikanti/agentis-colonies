#!/usr/bin/env python3
# tools/colony-fitness.py: per-pid fitness scalar for any of the 18
# research-foundry colonies.
#
# Renamed from tools/explorer-fitness.py (Phase 3 PR 2 of #624) and
# generalised in Phase 9 PR-B of #663. The back-compat shim
# tools/explorer-fitness.py forwards to this script with
# `--colony explorer` so the byte-identical contract test 12 in
# tools/test-auto-promote.sh keeps passing.
#
# Signature:
#   python3 tools/colony-fitness.py <fed_dir> <pid> <agent_id>
#                                   [--colony <name>] [--window K]
#
# `--colony` defaults to `explorer` for back-compat with the Phase 3
# tool. The colony name selects one of three side-specific formulas
# (see `SIDE_BY_COLONY` + `compute_fitness` below):
#
#   discovery  (explorer / noticer / skeptic / formulator / verifier /
#               novelty):
#     fitness = novel_count * audit_conf_avg * hitl_accept
#     For explorer this matches the original Phase 3 PR 2 formula. For
#     the other 5 discovery roles the `novel_count` term is a stub:
#     until PR-C lands per-role experience tagging, we count rows
#     with the same `verdict:NOVEL` tag and default to 0 if absent.
#
#   audit      (arxiv-search / oeis-search / groupprops-search /
#               scholar-search / prior_advocate / auditor):
#     fitness = hitl_upheld_rate * confidence_avg
#     Walks the K-window of acting rows tagged `hitl:upheld` vs
#     `hitl:overruled`; the confidence average comes from each row's
#     `confidence` field. Defaults to (1.0, 0.7) when no rows match.
#
#   preprint   (introducer / theorist / computer / editor / reviewer /
#               submitter):
#     fitness = compile_success_rate * hitl_accept_rate
#     compile_success_rate counts rows whose tags include
#     `compile:success` (vs `compile:failure`). hitl_accept_rate is
#     the complement of HITL rejects in the K-window. For submitter,
#     multiply by `submission_emit_count / max(drafted_count, 1)` so
#     a never-submitting agent does not look fit.
#
# Output: a single JSON object on stdout. Shape preserved across all
# three sides for back-compat with the dashboard's per-pid renderer.
#
#   {
#     "fitness_score": <float>,
#     "side": "discovery"|"audit"|"preprint",
#     "colony": "<name>",
#     "breakdown": {
#        ...per-side fields...
#        "window": K,
#     }
#   }
#
# Resilience: every filesystem read is wrapped so missing files, empty
# buffers, malformed JSON, or zero-row windows fall through to the
# documented defaults instead of crashing. The helper is invoked
# per-daemon per-regen on the dashboard hot path and must never raise.

import json
import os
import sys

DEFAULT_WINDOW = 20
DEFAULT_AUDIT_CONF = 0.5
DEFAULT_HITL_ACCEPT = 1.0
DEFAULT_CONFIDENCE = 0.7
DEFAULT_HITL_UPHELD = 1.0

# Phase 9 PR-B (#663): side dispatch for the 18 research-foundry
# colonies. Three sides x six colonies each; the side determines which
# formula compute_fitness() picks.
SIDE_BY_COLONY = {
    # Discovery (6)
    'explorer': 'discovery',
    'noticer': 'discovery',
    'skeptic': 'discovery',
    'formulator': 'discovery',
    'verifier': 'discovery',
    'novelty': 'discovery',
    # Audit (6)
    'arxiv-search': 'audit',
    'oeis-search': 'audit',
    'groupprops-search': 'audit',
    'scholar-search': 'audit',
    'prior_advocate': 'audit',
    'auditor': 'audit',
    # Preprint (6)
    'introducer': 'preprint',
    'theorist': 'preprint',
    'computer': 'preprint',
    'editor': 'preprint',
    'reviewer': 'preprint',
    'submitter': 'preprint',
}


def _read_jsonl(path):
    """Read a .jsonl file, returning the parsed rows. Tolerant of partial
    lines and missing files -- always returns a list (possibly empty)."""
    rows = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except (json.JSONDecodeError, ValueError):
                    pass
    except (OSError, IOError):
        pass
    return rows


def _read_memo_value(memo_dir, key):
    """Read the latest value from a memo .jsonl file (each line is a
    versioned record `{"value": ..., "generation": ..., "timestamp": ...}`;
    we want the last non-empty `value`). Returns "" on any error."""
    safe_key = key.replace('/', '_')
    path = os.path.join(memo_dir, safe_key + '.jsonl')
    rows = _read_jsonl(path)
    for row in reversed(rows):
        if isinstance(row, dict):
            v = row.get('value')
            if v is not None:
                return v
    return ''


def _parse_tick_from_in(in_field):
    """Auditor rows carry `in="tick <N> <VERDICT>"`. Return N as int, or
    None when parsing fails."""
    if not isinstance(in_field, str):
        return None
    parts = in_field.split()
    if len(parts) < 2 or parts[0] != 'tick':
        return None
    try:
        return int(parts[1])
    except (ValueError, TypeError):
        return None


def _has_tag(row, tag):
    if not isinstance(row, dict):
        return False
    tags = row.get('tags') or []
    if not isinstance(tags, list):
        return False
    return any(str(t) == tag for t in tags)


def _has_any_tag(row, tags):
    if not isinstance(row, dict):
        return False
    row_tags = row.get('tags') or []
    if not isinstance(row_tags, list):
        return False
    row_tag_set = {str(t) for t in row_tags}
    return bool(row_tag_set & set(tags))


def _discovery_fitness(fed_dir, pid, agent_id, colony, window):
    """Existing explorer formula generalised to all 6 discovery roles.
    For non-explorer colonies the `novel_count` term degrades to a stub
    (0 by default) until PR-C lands the cascade backtrace -- see module
    docstring."""
    exp_dir = os.path.join(fed_dir, '.agentis', 'experience')
    memo_dir = os.path.join(fed_dir, '.agentis', 'memo')

    # --- Step 1+2: per-role NOVEL count over last K rows. ---
    role_path = os.path.join(exp_dir, str(agent_id) + '.jsonl')
    role_rows = _read_jsonl(role_path)
    role_window = role_rows[-window:] if role_rows else []
    novel_count = sum(1 for r in role_window
                      if _has_tag(r, 'verdict:NOVEL'))

    # --- Step 3: audit confidence average. ---
    # Walk every experience.jsonl, pick out auditor rows, parse the tick
    # field, then look at the corresponding memo file for the confidence.
    audit_confidences = []
    explored_audit_rows = 0
    try:
        listing = os.listdir(exp_dir)
    except OSError:
        listing = []

    auditor_rows = []
    for fname in listing:
        if not fname.endswith('.jsonl'):
            continue
        path = os.path.join(exp_dir, fname)
        for row in _read_jsonl(path):
            if _has_tag(row, 'claim-auditor'):
                auditor_rows.append(row)

    auditor_rows.sort(key=lambda r: r.get('ts', 0) if isinstance(r, dict) else 0)
    auditor_window = auditor_rows[-window:]
    explored_audit_rows = len(auditor_window)

    for row in auditor_window:
        tick = _parse_tick_from_in(row.get('in'))
        if tick is None:
            continue
        suffix = ':verdict:tick-' + str(tick) + '.jsonl'
        try:
            memo_listing = os.listdir(memo_dir)
        except OSError:
            memo_listing = []
        for mname in memo_listing:
            if not mname.startswith('auditor:'):
                continue
            if not mname.endswith(suffix):
                continue
            mpath = os.path.join(memo_dir, mname)
            mrows = _read_jsonl(mpath)
            verdict_json = ''
            for mrow in reversed(mrows):
                if isinstance(mrow, dict):
                    v = mrow.get('value')
                    if v:
                        verdict_json = v
                        break
            if not verdict_json:
                continue
            try:
                vd = json.loads(verdict_json)
            except (json.JSONDecodeError, ValueError, TypeError):
                continue
            if not isinstance(vd, dict):
                continue
            conf = vd.get('confidence')
            if conf is None:
                continue
            try:
                audit_confidences.append(float(conf))
            except (ValueError, TypeError):
                pass
            break

    if audit_confidences:
        audit_conf_avg = sum(audit_confidences) / len(audit_confidences)
    else:
        audit_conf_avg = DEFAULT_AUDIT_CONF

    # --- Step 4: HITL accept ratio. ---
    hitl_raw = _read_memo_value(memo_dir, 'feedback:hitl_rejects')
    matching_rejects = 0
    if hitl_raw:
        try:
            hitl_list = json.loads(hitl_raw)
            if isinstance(hitl_list, list):
                pid_s = str(pid) if pid is not None else ''
                for entry in hitl_list[-window:]:
                    if not isinstance(entry, dict):
                        continue
                    cid = str(entry.get('claim_id', ''))
                    if pid_s and pid_s in cid:
                        matching_rejects += 1
                if matching_rejects == 0:
                    matching_rejects = min(
                        len([e for e in hitl_list[-window:]
                             if isinstance(e, dict)]),
                        window,
                    )
        except (json.JSONDecodeError, ValueError, TypeError):
            matching_rejects = 0

    if matching_rejects > window:
        matching_rejects = window
    hitl_accept = DEFAULT_HITL_ACCEPT - (float(matching_rejects) / float(window))
    if hitl_accept < 0.0:
        hitl_accept = 0.0
    if hitl_accept > 1.0:
        hitl_accept = 1.0

    fitness_score = float(novel_count) * float(audit_conf_avg) * float(hitl_accept)

    return {
        'fitness_score': fitness_score,
        'breakdown': {
            'novel_count': novel_count,
            'audit_conf_avg': audit_conf_avg,
            'hitl_accept': hitl_accept,
            'window': window,
            'explored_audit_rows': explored_audit_rows,
        },
    }


def _audit_fitness(fed_dir, pid, agent_id, colony, window):
    """Audit-side formula: hitl_upheld_rate * confidence_avg over the
    K-window of acting rows for this agent_id. Stub-friendly: when the
    experience file is absent / empty, returns the all-defaults score
    (DEFAULT_HITL_UPHELD * DEFAULT_CONFIDENCE) so PR-B's no-replication
    behaviour stays graceful."""
    exp_dir = os.path.join(fed_dir, '.agentis', 'experience')
    role_path = os.path.join(exp_dir, str(agent_id) + '.jsonl')
    role_rows = _read_jsonl(role_path)
    window_rows = role_rows[-window:] if role_rows else []

    upheld = 0
    overruled = 0
    confidences = []
    for row in window_rows:
        if _has_tag(row, 'hitl:upheld'):
            upheld += 1
        elif _has_tag(row, 'hitl:overruled'):
            overruled += 1
        conf = row.get('confidence') if isinstance(row, dict) else None
        if conf is not None:
            try:
                confidences.append(float(conf))
            except (ValueError, TypeError):
                pass

    total_hitl = upheld + overruled
    if total_hitl > 0:
        hitl_upheld_rate = float(upheld) / float(total_hitl)
    else:
        hitl_upheld_rate = DEFAULT_HITL_UPHELD

    if confidences:
        confidence_avg = sum(confidences) / float(len(confidences))
    else:
        confidence_avg = DEFAULT_CONFIDENCE

    fitness_score = float(hitl_upheld_rate) * float(confidence_avg)

    return {
        'fitness_score': fitness_score,
        'breakdown': {
            'hitl_upheld_rate': hitl_upheld_rate,
            'confidence_avg': confidence_avg,
            'upheld_count': upheld,
            'overruled_count': overruled,
            'window': window,
            'sampled_rows': len(window_rows),
        },
    }


def _preprint_fitness(fed_dir, pid, agent_id, colony, window):
    """Preprint-side formula: compile_success_rate * hitl_accept_rate
    over the K-window. For submitter, multiply by
    submission_emit_count / max(drafted_count, 1) so an agent that
    drafts but never submits scores as zero. Stub-friendly: defaults
    apply when the buffer is empty (1.0 * 1.0 * 1.0 = 1.0 with no
    submissions counted -- submitter multiplier collapses to 0/1 = 0
    when no drafted rows seen)."""
    exp_dir = os.path.join(fed_dir, '.agentis', 'experience')
    role_path = os.path.join(exp_dir, str(agent_id) + '.jsonl')
    role_rows = _read_jsonl(role_path)
    window_rows = role_rows[-window:] if role_rows else []

    compile_success = 0
    compile_failure = 0
    hitl_accept = 0
    hitl_reject = 0
    submission_emit_count = 0
    drafted_count = 0
    for row in window_rows:
        if _has_tag(row, 'compile:success'):
            compile_success += 1
        elif _has_tag(row, 'compile:failure'):
            compile_failure += 1
        if _has_any_tag(row, ['hitl:accept', 'hitl:upheld']):
            hitl_accept += 1
        elif _has_any_tag(row, ['hitl:reject', 'hitl:overruled']):
            hitl_reject += 1
        if _has_tag(row, 'submission:emitted'):
            submission_emit_count += 1
        if _has_tag(row, 'preprint:drafted'):
            drafted_count += 1

    total_compile = compile_success + compile_failure
    if total_compile > 0:
        compile_success_rate = float(compile_success) / float(total_compile)
    else:
        compile_success_rate = 1.0

    total_hitl = hitl_accept + hitl_reject
    if total_hitl > 0:
        hitl_accept_rate = float(hitl_accept) / float(total_hitl)
    else:
        hitl_accept_rate = DEFAULT_HITL_ACCEPT

    submitter_multiplier = 1.0
    if colony == 'submitter':
        # Default to 0 when no drafted_count seen so a silent submitter
        # does not coast on stub defaults.
        if drafted_count > 0:
            submitter_multiplier = float(submission_emit_count) / float(drafted_count)
        else:
            submitter_multiplier = 0.0

    fitness_score = float(compile_success_rate) * float(hitl_accept_rate) * float(submitter_multiplier)

    return {
        'fitness_score': fitness_score,
        'breakdown': {
            'compile_success_rate': compile_success_rate,
            'hitl_accept_rate': hitl_accept_rate,
            'compile_success': compile_success,
            'compile_failure': compile_failure,
            'hitl_accept': hitl_accept,
            'hitl_reject': hitl_reject,
            'submission_emit_count': submission_emit_count,
            'drafted_count': drafted_count,
            'submitter_multiplier': submitter_multiplier,
            'window': window,
            'sampled_rows': len(window_rows),
        },
    }


def compute_fitness(fed_dir, pid, agent_id, colony='explorer', window=DEFAULT_WINDOW):
    """Dispatch to the per-side formula. Returns the full output dict
    described in the module docstring. Never raises; on any unexpected
    error returns the all-defaults zero score."""
    if window <= 0:
        window = DEFAULT_WINDOW

    side = SIDE_BY_COLONY.get(colony, 'discovery')

    if side == 'audit':
        result = _audit_fitness(fed_dir, pid, agent_id, colony, window)
    elif side == 'preprint':
        result = _preprint_fitness(fed_dir, pid, agent_id, colony, window)
    else:
        result = _discovery_fitness(fed_dir, pid, agent_id, colony, window)

    result['side'] = side
    result['colony'] = colony
    return result


def _all_defaults_result(colony, window):
    side = SIDE_BY_COLONY.get(colony, 'discovery')
    if side == 'audit':
        breakdown = {
            'hitl_upheld_rate': DEFAULT_HITL_UPHELD,
            'confidence_avg': DEFAULT_CONFIDENCE,
            'upheld_count': 0,
            'overruled_count': 0,
            'window': window,
            'sampled_rows': 0,
        }
    elif side == 'preprint':
        breakdown = {
            'compile_success_rate': 1.0,
            'hitl_accept_rate': DEFAULT_HITL_ACCEPT,
            'compile_success': 0,
            'compile_failure': 0,
            'hitl_accept': 0,
            'hitl_reject': 0,
            'submission_emit_count': 0,
            'drafted_count': 0,
            'submitter_multiplier': 1.0,
            'window': window,
            'sampled_rows': 0,
        }
    else:
        breakdown = {
            'novel_count': 0,
            'audit_conf_avg': DEFAULT_AUDIT_CONF,
            'hitl_accept': DEFAULT_HITL_ACCEPT,
            'window': window,
            'explored_audit_rows': 0,
        }
    return {
        'fitness_score': 0.0,
        'side': side,
        'colony': colony,
        'breakdown': breakdown,
    }


def main():
    argv = sys.argv[1:]
    if len(argv) < 3:
        sys.stderr.write(
            'Usage: %s <fed_dir> <pid> <agent_id> [--colony <name>] [--window K]\n'
            % os.path.basename(sys.argv[0])
        )
        return 2

    fed_dir = argv[0]
    pid = argv[1]
    agent_id = argv[2]
    window = DEFAULT_WINDOW
    colony = 'explorer'

    i = 3
    while i < len(argv):
        if argv[i] == '--window' and i + 1 < len(argv):
            try:
                window = int(argv[i + 1])
            except (ValueError, TypeError):
                window = DEFAULT_WINDOW
            i += 2
        elif argv[i] == '--colony' and i + 1 < len(argv):
            colony = argv[i + 1]
            i += 2
        else:
            i += 1

    try:
        result = compute_fitness(fed_dir, pid, agent_id, colony=colony, window=window)
    except Exception:
        # Defensive: never crash the hot path. Return all-defaults zero
        # score so the dashboard sees a well-formed null result.
        result = _all_defaults_result(colony, window)

    # Phase 9 PR-B (#663): the byte-identical contract test (test 12 in
    # test-auto-promote.sh) requires that the explorer output shape
    # match the pre-rename explorer-fitness.py 1:1. For explorer we
    # omit the new `side`/`colony` keys so the legacy shape is
    # preserved. For every other colony we keep them, which gives the
    # dashboard the dispatch info it will need post-PR-C.
    if colony == 'explorer':
        legacy_result = {
            'fitness_score': result.get('fitness_score', 0.0),
            'breakdown': result.get('breakdown', {}),
        }
        print(json.dumps(legacy_result, separators=(',', ':')))
    else:
        print(json.dumps(result, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
