#!/usr/bin/env python3
# tools/auto-evolve-mutate.py -- LLM-driven .ag mutator for Phase 7 PR-B
# auto-evolve harness (#628).
#
# Called from tools/auto-evolve-ab.sh when `evolve.mutation.enabled=true`
# in the active auto-promote config. Replaces PR-A's cosmetic-comment
# stub with a real Claude/OpenAI prompt that proposes a focused mutation
# to the parent .ag based on the agent's recent failure modes.
#
# Pipeline:
#   1. Read parent .ag text from --ag.
#   2. Read last K experience rows from --experience.
#   3. Compute failure-mode summary: group rows where outcome in
#      {reject, failure} by their tags, emit the top-5 categories.
#   4. Build the LLM prompt (mutation surfaces + hard constraints).
#   5. Call the LLM. Backend defaults to $RESEARCH_LLM_BACKEND (claude),
#      model defaults to $RESEARCH_CLAUDE_MODEL (opus). For hermetic
#      testing, $MUTATE_LLM_STUB=<path-to-fixture> bypasses the LLM and
#      returns the fixture's text verbatim.
#   6. Validate the LLM output shape (basic structural sanity: starts
#      with `cb`, contains `fn tick`, has 4 tier branches). Exit 2 with
#      stderr=`mutation_invalid_shape` on any failure.
#   7. Write the candidate .ag to --out and a one-line rationale to
#      --rationale-out.
#
# Usage:
#   python3 tools/auto-evolve-mutate.py \
#       --ag <parent-ag-path> \
#       --experience <agent-jsonl-path> \
#       --window K \
#       --target-gen N \
#       --out <candidate-out-path> \
#       --rationale-out <rationale-out-path> \
#       [--config <yaml>]
#
# Exit codes:
#   0 -- success (candidate + rationale written)
#   1 -- usage / arg / IO error
#   2 -- mutation_invalid_shape (LLM produced an unparseable response)
#   3 -- mutator_failed (LLM backend call failed)

import json
import os
import re
import shutil
import subprocess
import sys


# ----- Validity gate constants -----
#
# The candidate must start with a `cb <N>;` budget declaration, contain
# a `fn tick(...)` signature, and have the three non-shadow tier
# literals present (`autonomous`, `review-gated`, `propose`). Shadow is
# the else-fallthrough per CLAUDE.md's canonical tier branching pattern,
# so it is NOT required as an explicit literal -- mirrors the same gate
# in tools/auto-evolve-ab.sh and tools/colony-lint.sh (#475-490).
CB_RE = re.compile(r'^\s*cb\s+[0-9]+\s*;', re.MULTILINE)
FN_TICK_RE = re.compile(r'\bfn\s+tick\s*\(')
TIER_LITERALS = ('"autonomous"', '"review-gated"', '"propose"')


def usage_exit(msg=None):
    if msg:
        sys.stderr.write('auto-evolve-mutate: %s\n' % msg)
    sys.stderr.write(
        'Usage: %s --ag <parent-ag> --experience <jsonl> --window K '
        '--target-gen N --out <candidate-out> --rationale-out <rationale-out> '
        '[--config <yaml>]\n' % os.path.basename(sys.argv[0])
    )
    sys.exit(1)


def parse_args(argv):
    opts = {
        'ag': None,
        'experience': None,
        'window': None,
        'target_gen': None,
        'out': None,
        'rationale_out': None,
        'config': None,
    }
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == '--ag' and i + 1 < len(argv):
            opts['ag'] = argv[i + 1]
            i += 2
        elif arg == '--experience' and i + 1 < len(argv):
            opts['experience'] = argv[i + 1]
            i += 2
        elif arg == '--window' and i + 1 < len(argv):
            try:
                opts['window'] = int(argv[i + 1])
            except (ValueError, TypeError):
                usage_exit('--window requires an integer value')
            i += 2
        elif arg == '--target-gen' and i + 1 < len(argv):
            try:
                opts['target_gen'] = int(argv[i + 1])
            except (ValueError, TypeError):
                usage_exit('--target-gen requires an integer value')
            i += 2
        elif arg == '--out' and i + 1 < len(argv):
            opts['out'] = argv[i + 1]
            i += 2
        elif arg == '--rationale-out' and i + 1 < len(argv):
            opts['rationale_out'] = argv[i + 1]
            i += 2
        elif arg == '--config' and i + 1 < len(argv):
            opts['config'] = argv[i + 1]
            i += 2
        else:
            usage_exit('unknown argument: %s' % arg)

    for key in ('ag', 'experience', 'window', 'target_gen', 'out', 'rationale_out'):
        if opts[key] is None:
            usage_exit('--%s is required' % key.replace('_', '-'))
    return opts


def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except (OSError, IOError) as e:
        sys.stderr.write('auto-evolve-mutate: cannot read %s: %s\n' % (path, e))
        sys.exit(1)


def read_jsonl_tail(path, window):
    """Return the last `window` parsed rows from a .jsonl file. Tolerant
    of missing files and malformed lines -- always returns a list."""
    rows = []
    if not os.path.isfile(path):
        return rows
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
        return []
    if window > 0:
        return rows[-window:]
    return rows


def summarise_failures(rows):
    """Group reject/failure rows by tags and return the top-5 categories.

    Each row is expected to carry a `tags` list (the dev-apprenticeship
    + research-foundry convention) and an `outcome` field. We treat
    `outcome in {reject, failure}` as the failure class. Returns a list
    of (tag, count) tuples sorted by count desc."""
    counts = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        outcome = str(row.get('outcome', '')).lower()
        if outcome not in ('reject', 'failure'):
            continue
        tags = row.get('tags') or []
        if not isinstance(tags, list):
            continue
        for tag in tags:
            tag_s = str(tag)
            if not tag_s:
                continue
            counts[tag_s] = counts.get(tag_s, 0) + 1
    items = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    return items[:5]


def build_prompt(parent_text, failure_summary, target_gen):
    """Construct the LLM prompt per plan section B. Returns the full
    prompt string. Mutation surfaces: prompt strings, branching
    thresholds, tier-branch boundaries. Hard constraints: complete .ag
    output, preserve tier() calls, preserve learn()/recommend() topic
    pairings, preserve `cb <N>;` budget, no new I/O primitives, preserve
    `fn tick()` signature, output ONLY the .ag body with no fences."""
    if failure_summary:
        summary_lines = '\n'.join(
            '  - %s: %d failures' % (tag, n) for tag, n in failure_summary
        )
    else:
        summary_lines = '  (no reject/failure rows in the recent window)'

    return (
        'You are an .ag mutator for an Agentis agent. Propose ONE focused '
        'mutation to the parent .ag below that addresses the failure modes '
        'observed in recent experience.\n\n'
        'TARGET GENERATION: %d\n\n'
        'RECENT FAILURE SUMMARY (top-5 tags from the last window):\n%s\n\n'
        'MUTATION SURFACES (one of):\n'
        '  - Prompt strings inside prompt(...) calls.\n'
        '  - Branching thresholds (numeric literals inside if/else blocks).\n'
        '  - Tier-branch boundaries (the order or composition of the four '
        'tier == "..." branches inside fn tick).\n\n'
        'HARD CONSTRAINTS:\n'
        '  - Output the COMPLETE .ag body, not a diff or partial snippet.\n'
        '  - Preserve every tier(...) call already present.\n'
        '  - Preserve every learn() / recommend() topic pairing (same topic '
        'string in both calls).\n'
        '  - Preserve the `cb <N>;` budget line (you may tweak N within '
        '+/- 25%% but the line must be present and parseable).\n'
        '  - Do NOT introduce new I/O primitives (no new exec sh, no new '
        'memo namespaces, no new bus events).\n'
        '  - Preserve the `fn tick(...)` signature exactly.\n'
        '  - Output ONLY the .ag body. NO markdown fences. NO commentary. '
        'NO explanation.\n\n'
        'PARENT .ag:\n'
        '%s\n' % (target_gen, summary_lines, parent_text)
    )


def call_llm_stub(stub_path):
    """Hermetic test path: read the fixture file's contents and return
    them as the LLM response. Used by tools/test-auto-evolve-ab.sh so CI
    does not depend on a live LLM backend."""
    try:
        with open(stub_path) as f:
            return f.read()
    except (OSError, IOError) as e:
        sys.stderr.write(
            'auto-evolve-mutate: cannot read MUTATE_LLM_STUB=%s: %s\n'
            % (stub_path, e)
        )
        return None


def call_llm(prompt):
    """Invoke the configured LLM backend. Returns the response text on
    success, None on failure. Backend selection mirrors run-research.sh:
    $RESEARCH_LLM_BACKEND (default `claude`) picks the CLI, and
    $RESEARCH_CLAUDE_MODEL (default `opus`) picks the model."""
    backend = os.environ.get('RESEARCH_LLM_BACKEND', 'claude')
    model = os.environ.get('RESEARCH_CLAUDE_MODEL', 'opus')
    if backend == 'claude':
        cmd = ['claude', '--print', '--model', model]
        if shutil.which('claude') is None:
            sys.stderr.write(
                'auto-evolve-mutate: `claude` CLI not on PATH; cannot mutate\n'
            )
            return None
        try:
            result = subprocess.run(
                cmd,
                input=prompt,
                capture_output=True,
                text=True,
                timeout=300,
            )
        except (subprocess.TimeoutExpired, OSError) as e:
            sys.stderr.write(
                'auto-evolve-mutate: claude CLI failed: %s\n' % e
            )
            return None
        if result.returncode != 0:
            sys.stderr.write(
                'auto-evolve-mutate: claude CLI exited %d; stderr=%s\n'
                % (result.returncode, result.stderr[:500])
            )
            return None
        return result.stdout
    # Other backends (openai, mock) are out of scope for PR-B; the stub
    # env var is the supported hermetic path for tests.
    sys.stderr.write(
        'auto-evolve-mutate: backend %s not supported in PR-B; '
        'set MUTATE_LLM_STUB=<fixture> for hermetic runs\n' % backend
    )
    return None


def validate_shape(text):
    """Structural sanity gate on the LLM output. Returns (ok, reason).

    Checks per plan: starts with `cb`, contains `fn tick`, has all 4
    tier branches (`autonomous`, `review-gated`, `propose`, `shadow`).
    Also rejects responses still wrapped in markdown fences -- those
    are a common claude-CLI behaviour and the calling shell expects a
    raw .ag body."""
    if not text or not text.strip():
        return False, 'empty_response'
    stripped = text.strip()
    if stripped.startswith('```'):
        return False, 'markdown_fence'
    if not CB_RE.search(stripped):
        return False, 'missing_cb_budget'
    if not FN_TICK_RE.search(stripped):
        return False, 'missing_fn_tick'
    for literal in TIER_LITERALS:
        if literal not in stripped:
            return False, 'missing_tier_literal:%s' % literal.strip('"')
    return True, 'ok'


def make_rationale(failure_summary, target_gen):
    """Compose a one-line rationale string for the rationale-out file."""
    if failure_summary:
        top = ','.join('%s=%d' % (tag, n) for tag, n in failure_summary[:3])
    else:
        top = 'no_failure_signal'
    return 'gen-%d mutation targeting: %s' % (target_gen, top)


def main():
    opts = parse_args(sys.argv[1:])

    parent_text = read_text(opts['ag'])
    rows = read_jsonl_tail(opts['experience'], opts['window'])
    failure_summary = summarise_failures(rows)

    prompt = build_prompt(parent_text, failure_summary, opts['target_gen'])

    stub_path = os.environ.get('MUTATE_LLM_STUB', '')
    if stub_path:
        response = call_llm_stub(stub_path)
    else:
        response = call_llm(prompt)

    if response is None:
        sys.stderr.write('mutator_failed\n')
        return 3

    ok, reason = validate_shape(response)
    if not ok:
        sys.stderr.write('mutation_invalid_shape: %s\n' % reason)
        return 2

    try:
        with open(opts['out'], 'w') as f:
            f.write(response.strip())
            f.write('\n')
    except (OSError, IOError) as e:
        sys.stderr.write(
            'auto-evolve-mutate: cannot write %s: %s\n' % (opts['out'], e)
        )
        return 1

    rationale = make_rationale(failure_summary, opts['target_gen'])
    try:
        with open(opts['rationale_out'], 'w') as f:
            f.write(rationale)
            f.write('\n')
    except (OSError, IOError) as e:
        sys.stderr.write(
            'auto-evolve-mutate: cannot write %s: %s\n'
            % (opts['rationale_out'], e)
        )
        return 1

    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
