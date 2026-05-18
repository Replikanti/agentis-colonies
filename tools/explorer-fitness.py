#!/usr/bin/env python3
# tools/explorer-fitness.py: per-pid explorer fitness scalar.
#
# Phase 3 PR 2 of #624. Invoked from tools/auto-promote-decisions.py when the
# daemon under inspection runs explorer.ag, so the Promote Candidates panel
# can rank the 5 explorer specialties (Phase 3 PR 1, #644) by an empirical
# discovery quality signal instead of the generic
# entries_total / runtime_hours prereqs.
#
# Signature:
#   python3 tools/explorer-fitness.py <fed_dir> <pid> <agent_id> [--window K]
#
# Output: a single JSON object on stdout with shape:
#   {
#     "fitness_score": <float>,
#     "breakdown": {
#       "novel_count": <int>,
#       "audit_conf_avg": <float>,
#       "hitl_accept": <float>,
#       "window": K,
#       "explored_audit_rows": <int>
#     }
#   }
#
# Algorithm:
#   1. Read <fed_dir>/.agentis/experience/<agent_id>.jsonl. Take the last K
#      rows (default K=20).
#   2. Count rows whose `tags` array contains "verdict:NOVEL" -- emitted by
#      explorer.ag::_publish_explorer when the settle path receives a NOVEL
#      novelty:final_verdict. That count becomes `novel_count`.
#   3. Walk every <fed_dir>/.agentis/experience/*.jsonl looking for auditor
#      rows (`tags` contains "claim-auditor"). Auditor rows' `in` field
#      carries "tick <N> <VERDICT>". The audit confidence is not in the
#      experience row itself -- it is stored in memo as
#      `auditor:<auditor_pid>:verdict:tick-<N>.jsonl` (a JSON-encoded
#      Verdict). Join: parse the tick from the auditor row's `in` field,
#      then look at all `auditor:*:verdict:tick-<N>.jsonl` memo files to
#      pick up the confidence. Mean those confidences over the last K
#      audit rows. Defaults to 0.5 when none found.
#   4. Read <fed_dir>/.agentis/memo/feedback:hitl_rejects.jsonl. Parse the
#      JSON list value; count entries whose `claim_id` references this
#      explorer pid (the claim_id flow is explorer -> formulator ->
#      auditor -> preprint, originating at `claim:claim_id:tick-<N>`; we
#      conservatively treat any reject in the window as a global signal
#      since the claim_id<->explorer-pid join is not direct, but bound the
#      count by K so the ratio stays meaningful). `hitl_accept = 1 -
#      min(matching_rejects, K) / K`. Defaults to 1.0 when buffer is
#      empty or unparseable.
#   5. fitness_score = novel_count * audit_conf_avg * hitl_accept.
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


def compute_fitness(fed_dir, pid, agent_id, window=DEFAULT_WINDOW):
    """Compute the fitness scalar. Returns the full output dict described
    in the module docstring. Never raises; on any unexpected error returns
    the all-defaults zero score."""
    if window <= 0:
        window = DEFAULT_WINDOW

    exp_dir = os.path.join(fed_dir, '.agentis', 'experience')
    memo_dir = os.path.join(fed_dir, '.agentis', 'memo')

    # --- Step 1+2: explorer NOVEL count over last K rows. ---
    explorer_path = os.path.join(exp_dir, str(agent_id) + '.jsonl')
    explorer_rows = _read_jsonl(explorer_path)
    explorer_window = explorer_rows[-window:] if explorer_rows else []
    novel_count = sum(1 for r in explorer_window
                      if _has_tag(r, 'verdict:NOVEL'))

    # --- Step 3: audit confidence average. ---
    # Walk every experience.jsonl, pick out auditor rows, parse the tick
    # field, then look at the corresponding memo file for the confidence.
    # We pool across all auditor pids because in practice one auditor
    # daemon runs per federation, but the code stays correct if multiple
    # auditors share the experience store.
    audit_confidences = []
    explored_audit_rows = 0
    try:
        listing = os.listdir(exp_dir)
    except OSError:
        listing = []

    # Collect all (tick) tuples from the most recent K auditor rows.
    auditor_rows = []
    for fname in listing:
        if not fname.endswith('.jsonl'):
            continue
        path = os.path.join(exp_dir, fname)
        for row in _read_jsonl(path):
            if _has_tag(row, 'claim-auditor'):
                auditor_rows.append(row)

    # Sort by ts ascending so the last K are the most recent.
    auditor_rows.sort(key=lambda r: r.get('ts', 0) if isinstance(r, dict) else 0)
    auditor_window = auditor_rows[-window:]
    explored_audit_rows = len(auditor_window)

    for row in auditor_window:
        tick = _parse_tick_from_in(row.get('in'))
        if tick is None:
            continue
        # Try every auditor:<pid>:verdict:tick-<N> memo for this tick.
        # The auditor pid is not in the experience row, so we scan the
        # memo dir for matching keys.
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
                    # Best-effort: if the claim_id carries the explorer pid,
                    # count it. Otherwise still bound by the global window
                    # below.
                    if pid_s and pid_s in cid:
                        matching_rejects += 1
                # When no pid-keyed match is available, fall back to the
                # raw recent-reject count clamped to the window so the
                # ratio remains a defined signal.
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

    # --- Step 5: combine. ---
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


def main():
    argv = sys.argv[1:]
    if len(argv) < 3:
        sys.stderr.write(
            'Usage: %s <fed_dir> <pid> <agent_id> [--window K]\n'
            % os.path.basename(sys.argv[0])
        )
        return 2

    fed_dir = argv[0]
    pid = argv[1]
    agent_id = argv[2]
    window = DEFAULT_WINDOW
    if len(argv) >= 5 and argv[3] == '--window':
        try:
            window = int(argv[4])
        except (ValueError, TypeError):
            window = DEFAULT_WINDOW

    try:
        result = compute_fitness(fed_dir, pid, agent_id, window=window)
    except Exception:
        # Defensive: never crash the hot path. Return all-defaults zero
        # score so the dashboard sees a well-formed null result.
        result = {
            'fitness_score': 0.0,
            'breakdown': {
                'novel_count': 0,
                'audit_conf_avg': DEFAULT_AUDIT_CONF,
                'hitl_accept': DEFAULT_HITL_ACCEPT,
                'window': window,
                'explored_audit_rows': 0,
            },
        }

    print(json.dumps(result, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
