#!/usr/bin/env python3
"""Shared predicate + enumerator for the labeler priority-rule audit/purge (#1478, #1482).

#1474 / PR #1477 added a deterministic runtime filter
(`strip_priority_like_labels()`) that strips priority-like tokens from
labeler's suggested labels AND from the crystallized-rule replay path
(`fire_label_rule()` -> `apply_label_rule_hit()`). That closes the *code*
side: a contaminated rule can no longer APPLY a bare `P1`-`P4` / `urgent`
token.

This module is the *data* side (#1478): a one-time audit + purge over the
existing crystallized rule pool for rules that were crystallized BEFORE the
filter shipped and still carry a priority-like token baked into their
`action` slot. It is the SINGLE source of truth for the contamination
predicate — both `audit-priority-rules.sh` (enumerate + report) and
`purge-priority-rules.sh` (retire the flagged rules) drive this one file, so
the heuristic cannot drift between the two operator scripts. The predicate
mirrors PR #1477's `strip_priority_like_labels()` token-for-token; when that
runtime helper changes, change `is_priority_like_token()` here in lockstep.

Recovering the rule pool (#1482): the FIRST cut of this tool (PR #1481)
re-implemented agentis-core's crystallizer persistence in Python — reading
`_crystallizer_index/<class>.jsonl` and resolving each rule from the
content-addressed object store. That was wrong three ways: it keyed rules by
`rule_id` when core persists bodies by `content_hash`; it `json.loads`-ed
core's binary semantic-DAG object bytes; and it text-scanned the whole blob
(so a rule's *condition* text — `kw=urgent,crash` — could false-flag a clean
action). Deployments without semantic-DAG persistence had no index at all.

The fix recovers rules through **agentis itself**. The operator scripts run
`agentis knowledge export` (the documented #1478 recipe: export -> filter ->
`import --replace`) and feed its JSON to this module via `--export`. That is
the one code path core guarantees works across both the semantic-DAG and the
plain-JSON knowledge-dir layouts. A `--knowledge-dir DIR` fallback reads a
plain-JSON rule pool directly (per-class `*.json` arrays) for offline
inspection and for deployments where the export CLI is unavailable.

Whatever the source, only the `action` slot is inspected for contamination
(comma-separated label tokens). The `condition` slot is NEVER scanned — a
priority-like keyword in an issue title (`kw=urgent,crash`) is legitimate
grouping context, not a contaminated action. There is no whole-blob text
scan: a rule whose `action` cannot be recovered is reported `unresolved` and
is never flagged (the purge only ever retires what it can prove is dirty).

The predicate (identical to PR #1477):
  A single label token is "priority-like" (contaminated) when, lowercased:
    - it matches `^p\\d+$`  (bare `P1`-`P4`, ...), OR
    - it equals `urgent`, OR
    - it starts with `priority` AND is NOT a canonical *scoped* label
      (`priority::critical` and friends carry `::` and are legitimate).
  Extra always-canonical tokens can be supplied via --allow (never flagged).

Modes:
  report  (default) — human-readable table on stdout, exit 0.
  --json            — one JSON object per CONTAMINATED rule on stdout (JSONL),
                      consumed by purge-priority-rules.sh. A trailing summary
                      object with {"_summary": true, ...} closes the stream.

Total-on-failure: a missing/empty/unparseable export yields an empty report
(exit 0), never a crash — safe to run against a cold federation.
"""

import argparse
import json
import os
import re
import sys

_BARE_P = re.compile(r"^p\d+$")

# Keys under which the rule fields may travel in an `agentis knowledge export`
# document (or a plain-JSON knowledge-dir rule). Probed in order; first
# non-empty string wins. `content_hash` is a *deliberate* trailing fallback
# for `rule_id` so a row that only carries the persistence key still resolves
# (#1482 finding 1: never key off the wrong field silently).
_ID_KEYS = ("rule_id", "id", "content_hash")
_ACTION_KEYS = ("action", "recommendation", "rule_action", "canonical_action")
_CLASS_KEYS = ("action_type", "class", "topic", "action_class")


def is_priority_like_token(token, allow=None):
    """True when `token` is a contaminated priority-like label token.

    Mirrors PR #1477's `strip_priority_like_labels()` predicate. `allow` is
    an optional set of extra always-canonical tokens (lowercased) that must
    never be flagged (e.g. an operator's scoped priority vocabulary).
    """
    t = token.strip().lower()
    if not t:
        return False
    if allow and t in allow:
        return False
    if _BARE_P.match(t):
        return True
    if t == "urgent":
        return True
    if t.startswith("priority"):
        # Scoped labels (`priority::critical`) are the canonical form and
        # are legitimate; a bare `priority`-prefixed token is contamination.
        if "::" in t:
            return False
        return True
    return False


def classify_action(action_csv, allow=None):
    """Split a comma-separated action slot and partition its tokens.

    Returns (all_tokens, contaminated_tokens, clean_tokens) preserving order,
    dropping empty/whitespace tokens.
    """
    all_tokens = [t.strip() for t in action_csv.split(",") if t.strip()]
    contaminated = [t for t in all_tokens if is_priority_like_token(t, allow)]
    clean = [t for t in all_tokens if not is_priority_like_token(t, allow)]
    return all_tokens, contaminated, clean


def _first_str(rule, keys):
    """First key in `keys` whose value is a non-empty string, else None."""
    for key in keys:
        val = rule.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
    return None


def _rule_id(rule):
    return _first_str(rule, _ID_KEYS) or ""


def _rule_action_type(rule):
    return _first_str(rule, _CLASS_KEYS) or ""


def _rule_action(rule):
    """The rule's `action` slot verbatim (may be empty string), else None.

    Only the action is returned — never the condition, never a whole-blob
    fallback (#1482 finding 3). A rule missing every action key resolves to
    None and is reported `unresolved`.
    """
    for key in _ACTION_KEYS:
        val = rule.get(key)
        if isinstance(val, str):
            return val
    return None


def _telemetry_counts(rule):
    """(use_count, success_count) pulled from the rule row; (0, 0) when absent."""
    def _int(*keys):
        for k in keys:
            v = rule.get(k)
            if isinstance(v, bool):
                continue
            if isinstance(v, int):
                return v
            if isinstance(v, str) and v.strip().isdigit():
                return int(v.strip())
        return 0
    return _int("use_count", "uses"), _int("success_count", "successes")


def iter_rules(doc):
    """Yield rule dicts out of a parsed export document, shape-tolerant.

    `agentis knowledge export` and the plain-JSON knowledge-dir layout wrap
    the rule list differently across core versions, so accept:
      - a bare list of rule dicts,
      - {"rules": [...]} / {"crystallizer_rules": [...]},
      - {"crystallizer"|"knowledge": {"rules": [...]}},
      - {rule_id: rule_dict, ...} mapping,
      - a single bare rule dict (has an action-type or action key).
    Anything else yields nothing (total-on-failure).
    """
    if isinstance(doc, list):
        for r in doc:
            if isinstance(r, dict):
                yield r
        return
    if not isinstance(doc, dict):
        return
    for key in ("rules", "crystallizer_rules"):
        val = doc.get(key)
        if isinstance(val, list):
            for r in val:
                if isinstance(r, dict):
                    yield r
            return
    for key in ("crystallizer", "knowledge"):
        val = doc.get(key)
        if isinstance(val, dict):
            for r in iter_rules(val):
                yield r
            return
    # A bare rule dict?
    if _rule_action_type(doc) or any(k in doc for k in _ACTION_KEYS):
        yield doc
        return
    # A {rule_id: rule} mapping.
    for val in doc.values():
        if isinstance(val, dict):
            yield val


def load_export(text):
    """Parse an export blob into a list of rule dicts.

    Accepts a single JSON document OR a JSONL stream (one rule per line),
    which is how some `agentis knowledge export` builds emit. Returns [] on
    any parse failure.
    """
    text = text.strip()
    if not text:
        return []
    try:
        doc = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        rules = []
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if isinstance(row, dict):
                rules.append(row)
        return rules
    return list(iter_rules(doc))


def load_knowledge_dir(knowledge_dir):
    """Fallback source: read plain-JSON rules from a knowledge directory.

    For deployments without semantic-DAG persistence (#1482 finding 4) the
    rule pool lives as plain JSON on disk rather than behind the crystallizer
    index. Each `<class>.json` file holds that class's rules (an array, or a
    dict wrapping one). Files are read as whole documents through the same
    shape-tolerant `iter_rules`, so the `action_type` is taken from the row
    when present and otherwise defaults to the filename stem.
    """
    rules = []
    if not knowledge_dir or not os.path.isdir(knowledge_dir):
        return rules
    try:
        names = sorted(os.listdir(knowledge_dir))
    except OSError:
        return rules
    for fn in names:
        if not fn.endswith(".json"):
            continue
        stem = fn[:-5]
        path = os.path.join(knowledge_dir, fn)
        if not os.path.isfile(path):
            continue
        try:
            with open(path) as f:
                doc = json.load(f)
        except (OSError, json.JSONDecodeError, ValueError):
            continue
        for row in iter_rules(doc):
            # Default the class to the filename stem when the row omits it,
            # so a bare per-class array still classifies correctly.
            if not _rule_action_type(row):
                row = dict(row)
                row["action_type"] = stem
            rules.append(row)
    return rules


def enumerate_rules(rules, classes, allow=None):
    """Yield a record dict per rule in the requested classes.

    record = {rule_id, action_type, action, contaminated, clean,
              contaminated_tokens, source, use_count, success_count}
    `contaminated` is True when at least one *action* token is priority-like.
    `action` is None for `unresolved` rules (never flagged).
    """
    want = set(classes)
    seen = set()
    for rule in rules:
        if not isinstance(rule, dict):
            continue
        action_type = _rule_action_type(rule)
        if want and action_type not in want:
            continue
        rule_id = _rule_id(rule)
        # Dedup on (id, class); a blank id still yields once per row so a
        # contaminated-but-idless rule is never silently dropped.
        dedup_key = (rule_id, action_type) if rule_id else None
        if dedup_key is not None:
            if dedup_key in seen:
                continue
            seen.add(dedup_key)

        action = _rule_action(rule)
        uses, succ = _telemetry_counts(rule)
        rec = {
            "rule_id": rule_id,
            "action_type": action_type,
            "action": action,
            "source": "export",
            "use_count": uses,
            "success_count": succ,
            "contaminated": False,
            "contaminated_tokens": [],
            "clean": [],
        }
        if action is None:
            rec["unresolved"] = True
            yield rec
            continue
        _all, dirty, clean = classify_action(action, allow)
        rec["contaminated"] = bool(dirty)
        rec["contaminated_tokens"] = dirty
        rec["clean"] = clean
        yield rec


def _load_rules(args):
    """Resolve the rule pool from --export (primary) or --knowledge-dir."""
    if args.knowledge_dir:
        return load_knowledge_dir(args.knowledge_dir)
    # --export path: '-' or empty means stdin.
    src = args.export
    if not src or src == "-":
        return load_export(sys.stdin.read())
    try:
        with open(src) as f:
            return load_export(f.read())
    except OSError:
        return []


def _parse_classes(spec):
    return [c.strip() for c in spec.split(",") if c.strip()]


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Audit crystallized rule action slots for priority-like contamination (#1478, #1482).")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--export", default="-",
                     help="path to an `agentis knowledge export` JSON document "
                          "('-' or omitted = read from stdin)")
    src.add_argument("--knowledge-dir", default="",
                     help="fallback: a plain-JSON knowledge directory of per-class "
                          "rule files (deployments without semantic-DAG persistence)")
    ap.add_argument("--class", dest="classes", default="label",
                    help="comma-separated action_type list to scan (default: label)")
    ap.add_argument("--allow", default="",
                    help="comma-separated extra always-canonical tokens (never flagged)")
    ap.add_argument("--json", action="store_true",
                    help="emit one JSON object per contaminated rule (JSONL) + a _summary line")
    args = ap.parse_args(argv)

    allow = {t.strip().lower() for t in args.allow.split(",") if t.strip()}
    classes = _parse_classes(args.classes)

    rules = _load_rules(args)

    total = 0
    contaminated = []
    unresolved = 0
    for rec in enumerate_rules(rules, classes, allow):
        total += 1
        if rec.get("unresolved"):
            unresolved += 1
        elif rec["contaminated"]:
            contaminated.append(rec)

    if args.json:
        for rec in contaminated:
            sys.stdout.write(json.dumps({
                "rule_id": rec["rule_id"],
                "action_type": rec["action_type"],
                "action": rec["action"],
                "contaminated_tokens": rec["contaminated_tokens"],
                "clean": rec["clean"],
                "source": rec["source"],
                "use_count": rec["use_count"],
                "success_count": rec["success_count"],
            }, sort_keys=True) + "\n")
        sys.stdout.write(json.dumps({
            "_summary": True,
            "classes": classes,
            "rules_scanned": total,
            "contaminated": len(contaminated),
            "unresolved": unresolved,
        }, sort_keys=True) + "\n")
        return 0

    # Human report.
    print("priority-rule audit (#1478, #1482)")
    print("  classes scanned : " + ",".join(classes))
    print("  rules scanned   : " + str(total))
    print("  contaminated    : " + str(len(contaminated)))
    print("  unresolved      : " + str(unresolved) + " (action slot not recoverable — not flagged)")
    if not contaminated:
        print("  -> clean: no rule action slot carries a bare P1-P4 / urgent / non-canonical priority token.")
        return 0
    print("")
    print("  contaminated rules:")
    for rec in contaminated:
        rate = ""
        if rec["use_count"]:
            rate = " success=%d/%d" % (rec["success_count"], rec["use_count"])
        print("    - " + (rec["rule_id"] or "(no rule_id)"))
        print("        action        : " + (rec["action"] or ""))
        print("        priority-like : " + ", ".join(rec["contaminated_tokens"]))
        print("        clean remainder: " + (", ".join(rec["clean"]) if rec["clean"] else "(none — rule slot empties out)"))
        print("        source        : " + rec["source"] + rate)
    return 0


if __name__ == "__main__":
    sys.exit(main())
