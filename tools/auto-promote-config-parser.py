#!/usr/bin/env python3
"""auto-promote-config-parser.py - Parse auto-promote-config.yaml.

Emits shell-eval-able `CFG_*=value` lines on stdout, consumed by
`eval "$(python3 auto-promote-config-parser.py <path>)"` in auto-promote.sh.

Extracted from tools/auto-promote.sh in #245 to eliminate the embedded
`eval "$(python3 - <<'PYCONFIG' ... PYCONFIG)"` heredoc. The macOS bash 3.2
parser cannot parse that combination (eval + `$(...)` + heredoc), silently
breaking the auto-promote sidecar on every macOS host. Same fix pattern as
#170 / #172 applied to federation-dashboard.sh (see CLAUDE.md no-heredoc
invariant).

Tries PyYAML first, falls back to a minimal parser for the flat config
structure we need (same shape as the legacy inline parser).

Args (positional):
    1: config_path — path to auto-promote-config.yaml
"""
import math
import sys


def _strip_inline_comment(s):
    """Strip YAML inline comments (# ...) respecting quoted strings."""
    quote = None
    for i, ch in enumerate(s):
        if quote:
            if ch == '\\' and i + 1 < len(s):
                continue
            if ch == quote:
                quote = None
            continue
        if ch in ('"', "'"):
            quote = ch
            continue
        if ch == '#':
            return s[:i].rstrip()
    return s


def _parse_value(v):
    v = _strip_inline_comment(v)
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
        return v[1:-1]
    if v == 'true':
        return True
    if v == 'false':
        return False
    try:
        return int(v)
    except ValueError:
        pass
    try:
        return float(v)
    except ValueError:
        pass
    return v


def parse_yaml_simple(path):
    """Minimal YAML parser for our flat config structure.

    Handles scalar values and simple lists (- from/to pairs).
    """
    cfg = {}
    with open(path) as f:
        lines = f.readlines()

    indent_stack = [(-1, cfg)]
    # Track the last dict appended to a list so continuation keys
    # (e.g. "to: 0.6" indented under "- from: 0.4") can be added.
    last_list_dict = None

    for idx, raw in enumerate(lines):
        line = raw.rstrip('\n')
        stripped = line.lstrip()

        if not stripped or stripped.startswith('#'):
            continue

        indent = len(line) - len(stripped)

        while len(indent_stack) > 1 and indent_stack[-1][0] >= indent:
            indent_stack.pop()

        parent = indent_stack[-1][1]

        if stripped.startswith('- '):
            item_content = stripped[2:].strip()
            if ':' in item_content:
                k, _, v = item_content.partition(':')
                k = k.strip()
                v = v.strip()
                if not isinstance(parent, list):
                    continue
                new_dict = {k: _parse_value(v)}
                parent.append(new_dict)
                last_list_dict = new_dict
            else:
                if isinstance(parent, list):
                    parent.append(_parse_value(item_content))
                    last_list_dict = None
            continue

        if ':' not in stripped:
            continue

        k, _, v = stripped.partition(':')
        k = k.strip()
        v = v.strip()

        if not v:
            is_list = False
            for upcoming in lines[idx + 1:]:
                us = upcoming.lstrip()
                if not us or us.startswith('#'):
                    continue
                if us.startswith('- '):
                    is_list = True
                break

            child = [] if is_list else {}
            if isinstance(parent, dict):
                parent[k] = child
            indent_stack.append((indent, child))
            last_list_dict = None
        else:
            if isinstance(parent, dict):
                parent[k] = _parse_value(v)
            elif isinstance(parent, list) and last_list_dict is not None:
                last_list_dict[k] = _parse_value(v)

    return cfg


def main():
    if len(sys.argv) != 2:
        sys.stderr.write('Usage: %s <config_path>\n' % sys.argv[0])
        return 2
    config_path = sys.argv[1]

    try:
        import yaml
        with open(config_path) as f:
            cfg = yaml.safe_load(f)
    except ImportError:
        cfg = parse_yaml_simple(config_path)

    p = cfg.get('promote', {}).get('prerequisites', {})
    print('CFG_MIN_ENTRIES=%s' % p.get('min_entries', 200))
    # Default: ceil(3 / reject_rate_threshold). With reject_rate_threshold=0.05
    # that is 60 — see doc/auto-promote.md#formula for rule-of-three derivation.
    reject = float(p.get('reject_rate_threshold', 0.05))
    default_acting = math.ceil(3.0 / reject) if reject > 0 else 60
    print('CFG_MIN_ACTING_ENTRIES=%s' % p.get('min_acting_entries', default_acting))
    print('CFG_MIN_RUNTIME_HOURS=%s' % p.get('min_runtime_hours', 48))
    print('CFG_REJECT_RATE_THRESHOLD=%s' % reject)
    print('CFG_DELTA_SLOPE_WINDOW=%s' % p.get('delta_slope_window', 100))
    print('CFG_DELTA_SLOPE_MIN=%s' % p.get('delta_slope_min', 0))

    steps = cfg.get('promote', {}).get('steps', [])
    # Encode each step as "from:to:override" where override is either a non-negative
    # integer (per-step min_acting_entries_override) or empty (use global default).
    # Empty third field distinguishes "no override" from "override = 0".
    def _fmt_step(s):
        if 'from' not in s or 'to' not in s:
            return None
        override = s.get('min_acting_entries_override')
        if override is None:
            return '%s:%s:' % (s['from'], s['to'])
        return '%s:%s:%d' % (s['from'], s['to'], int(override))

    step_triples = ' '.join(t for t in (_fmt_step(s) for s in steps) if t is not None)
    print("CFG_PROMOTE_STEPS='%s'" % step_triples)

    e = cfg.get('evolve', {}).get('trigger', {})
    print('CFG_EVOLVE_SLOPE_NEG_FOR=%s' % e.get('delta_slope_negative_for', 1000))
    print('CFG_EVOLVE_REJECT_ABOVE=%s' % e.get('reject_rate_above', 0.20))

    ec = cfg.get('evolve', {}).get('config', {})
    print('CFG_EVOLVE_GENERATIONS=%s' % ec.get('generations', 3))
    print('CFG_EVOLVE_POPULATION=%s' % ec.get('population', 4))
    print("CFG_EVOLVE_WEIGHTS='%s'" % ec.get('weights', 'cb,val,exp'))

    dr = cfg.get('dry_run', True)
    print('CFG_DRY_RUN=%s' % ('true' if dr else 'false'))

    return 0


if __name__ == '__main__':
    sys.exit(main())
