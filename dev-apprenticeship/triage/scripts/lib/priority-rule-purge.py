#!/usr/bin/env python3
"""Retire priority-contaminated crystallized rules from an exported pool (#1478, #1482).

The mutation half of the #1478 audit/purge pass, rebuilt for #1482 on the
proven export -> filter -> `import --replace` recipe (#1478) instead of the
first cut's Python re-implementation of core's on-disk persistence.

It reads two inputs, both derived from the SAME `agentis knowledge export`
document so dry-run and apply select identically:

  --export PATH   the full export JSON (from `agentis knowledge export`), and
  stdin           the audit `--json` stream (one contaminated rule per line +
                  a trailing `_summary` object) — the SINGLE selection path,
                  shared with the human report, so the two can never diverge.

It drops every flagged rule (matched by `rule_id` within its `action_type`)
from the export document while PRESERVING the document's top-level shape, and
emits the filtered document so the operator script can pipe it straight into
`agentis knowledge import --replace`. That replaces the whole pool with the
cleaned set — the retired rules are gone, and the clean decision
re-crystallizes from post-#1474 verdicts on the daemons' next pass.

Dry-run by default: prints exactly what WOULD be retired and emits no filtered
document. `--apply --out PATH` writes the filtered document to PATH (which the
operator script imports) and prints the same preview.

Exit codes: 0 ok (including nothing-to-do), 1 bad/empty export, 2 usage.
"""

import argparse
import importlib.util
import json
import os
import sys

# The contamination predicate + field-resolution helpers live ONLY in
# priority-rule-audit.py (single source of truth). Import it by path because
# the filename is hyphenated and not a legal module name.
_AUDIT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "priority-rule-audit.py")
_spec = importlib.util.spec_from_file_location("priority_rule_audit", _AUDIT_PATH)
_audit = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_audit)


def _read_flagged(stream):
    """Parse the audit --json stream into a set of (rule_id, action_type)."""
    drop = set()
    for line in stream:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict) or obj.get("_summary"):
            continue
        rid = obj.get("rule_id")
        cls = obj.get("action_type")
        if not rid:
            # Idless rows cannot be matched back safely — never dropped.
            continue
        drop.add((rid, cls or ""))
    return drop


def _matches(rule, drop):
    key = (_audit._rule_id(rule), _audit._rule_action_type(rule))
    return key in drop


def filter_document(doc, drop):
    """Return (filtered_doc, removed_count) preserving the top-level shape.

    Recurses through the same wrappers `iter_rules` understands so the
    re-imported document round-trips through `agentis knowledge import`.
    """
    if isinstance(doc, list):
        kept = [r for r in doc if not (isinstance(r, dict) and _matches(r, drop))]
        return kept, len(doc) - len(kept)
    if isinstance(doc, dict):
        for key in ("rules", "crystallizer_rules"):
            if isinstance(doc.get(key), list):
                new = dict(doc)
                kept = [r for r in doc[key]
                        if not (isinstance(r, dict) and _matches(r, drop))]
                new[key] = kept
                return new, len(doc[key]) - len(kept)
        for key in ("crystallizer", "knowledge"):
            if isinstance(doc.get(key), dict):
                new = dict(doc)
                sub, removed = filter_document(doc[key], drop)
                new[key] = sub
                return new, removed
        # {rule_id: rule} mapping.
        if doc and all(isinstance(v, dict) for v in doc.values()):
            new = {k: v for k, v in doc.items() if not _matches(v, drop)}
            return new, len(doc) - len(new)
    return doc, 0


def _load_doc(path):
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return None
    text = text.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return None


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Retire priority-contaminated crystallized rules from an export (#1478, #1482).")
    ap.add_argument("--export", required=True,
                    help="path to the `agentis knowledge export` JSON document to filter")
    ap.add_argument("--apply", action="store_true",
                    help="write the filtered document to --out (default: dry-run preview)")
    ap.add_argument("--out", default="",
                    help="path to write the filtered document to (required with --apply)")
    args = ap.parse_args(argv)

    if args.apply and not args.out:
        sys.stderr.write("priority-rule-purge: --apply requires --out PATH\n")
        return 2

    doc = _load_doc(args.export)
    if doc is None:
        sys.stderr.write("priority-rule-purge: empty or unparseable export: %s\n"
                         % args.export)
        return 1

    drop = _read_flagged(sys.stdin)
    mode = "APPLY" if args.apply else "DRY-RUN"

    if not drop:
        print("priority-rule-purge [%s]: nothing to retire (0 contaminated rules)." % mode)
        return 0

    filtered, removed = filter_document(doc, drop)

    # Group the dropped ids by class for the preview.
    by_class = {}
    for rid, cls in sorted(drop):
        by_class.setdefault(cls, []).append(rid)
    for cls, ids in sorted(by_class.items()):
        verb = "retiring" if args.apply else "would retire"
        print("priority-rule-purge [%s]: class '%s' — %s %d rule(s):"
              % (mode, cls or "(unclassed)", verb, len(ids)))
        for rid in ids:
            print("    - " + rid)

    print("")
    if args.apply:
        tmp = args.out + ".tmp"
        with open(tmp, "w") as f:
            json.dump(filtered, f, sort_keys=True, indent=2)
            f.write("\n")
        os.replace(tmp, args.out)
        print("priority-rule-purge [APPLY]: wrote filtered pool (%d rule(s) removed) to %s."
              % (removed, args.out))
        print("  Import it with `agentis knowledge import --replace` to swap the pool,")
        print("  then restart the triage daemons so the in-memory pool reloads.")
        print("  Clean decisions re-crystallize from post-#1474 verdicts on the next pass.")
    else:
        print("priority-rule-purge [DRY-RUN]: would remove %d rule(s) from the pool."
              % removed)
        print("  Re-run with --apply (stop the federation first) to perform the retirement.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
