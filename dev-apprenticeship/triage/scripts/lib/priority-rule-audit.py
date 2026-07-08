#!/usr/bin/env python3
"""Shared predicate + enumerator for the labeler priority-rule audit/purge (#1478).

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
`purge-priority-rules.sh` (retire the flagged rules) call this one file, so
the heuristic cannot drift between the two operator scripts. The predicate
mirrors PR #1477's `strip_priority_like_labels()` token-for-token; when that
runtime helper changes, change `is_priority_like_token()` here in lockstep.

The predicate (identical to PR #1477):
  A single label token is "priority-like" (contaminated) when, lowercased:
    - it matches `^p\\d+$`  (bare `P1`-`P4`, ...), OR
    - it equals `urgent`, OR
    - it starts with `priority` AND is NOT a canonical *scoped* label
      (`priority::critical` and friends carry `::` and are legitimate).
  Extra always-canonical tokens can be supplied via --allow (never flagged).

Rule enumeration reads the on-disk crystallizer state agentis-core persists
under `<fed>/.agentis/knowledge/`:
  - `_crystallizer_index/<action_type>.jsonl` — the rule_id list per class,
  - `_crystallizer_telemetry/<rule_id>.jsonl` — per-rule use/success (for the
    report only),
and resolves each rule's `action` slot from the index row when it carries
one, else from the content-addressed object under `<fed>/.agentis/objects/`.
A rule whose action cannot be recovered is reported as `unresolved` and is
never flagged (the purge only ever retires what it can prove is dirty).

Modes:
  report  (default) — human-readable table on stdout, exit 0.
  --json            — one JSON object per CONTAMINATED rule on stdout (JSONL),
                      consumed by purge-priority-rules.sh. A trailing summary
                      object with {"_summary": true, ...} closes the stream.

Total-on-failure: a missing knowledge dir / unreadable file yields an empty
report (exit 0), never a crash — safe to run against a cold federation.
"""

import argparse
import json
import os
import re
import sys

_BARE_P = re.compile(r"^p\d+$")
# Free-text fallback scan (used only when a rule's action is recovered as an
# unstructured blob rather than a clean comma list): find priority-like
# tokens embedded in the serialized bytes.
_TEXT_SCAN = re.compile(r"[A-Za-z0-9:_-]+")


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


def _scan_text_for_priority(blob, allow=None):
    """Fallback: pull priority-like tokens out of an unstructured rule blob."""
    hits = []
    for tok in _TEXT_SCAN.findall(blob):
        if is_priority_like_token(tok, allow) and tok not in hits:
            hits.append(tok)
    return hits


def _object_candidates(objects_dir, rule_id):
    """Plausible on-disk paths for a content-addressed rule object.

    agentis-core content-addresses rules by hash; different core versions
    shard the object store differently, so probe the flat and the common
    2-/4-char sharded layouts.
    """
    if not objects_dir or not rule_id:
        return []
    cands = [os.path.join(objects_dir, rule_id)]
    if len(rule_id) > 2:
        cands.append(os.path.join(objects_dir, rule_id[:2], rule_id[2:]))
    if len(rule_id) > 4:
        cands.append(os.path.join(objects_dir, rule_id[:2], rule_id[2:4], rule_id[4:]))
    return cands


def _action_from_obj(objects_dir, rule_id):
    """Recover (action_str, source) for a rule from its content object.

    Returns (None, "") when no object is found or no action can be pulled.
    """
    for path in _object_candidates(objects_dir, rule_id):
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as f:
                raw = f.read()
        except OSError:
            continue
        text = raw.decode("utf-8", "replace")
        try:
            obj = json.loads(text)
        except (json.JSONDecodeError, ValueError):
            obj = None
        if isinstance(obj, dict):
            for key in ("action", "recommendation", "rule_action", "canonical_action"):
                val = obj.get(key)
                if isinstance(val, str) and val.strip():
                    return val, "object:" + key
        # Structured parse failed — hand back the raw blob for a text scan.
        return text, "object:raw"
    return None, ""


def _action_from_index_row(row):
    """Pull an action string out of a `_crystallizer_index` row when present."""
    for key in ("action", "recommendation", "rule_action", "canonical_action"):
        val = row.get(key)
        if isinstance(val, str) and val.strip():
            return val, "index:" + key
    return None, ""


def _telemetry(tel_dir, rule_id):
    """(use_count, success_count) for a rule; (0, 0) when absent/unreadable."""
    path = os.path.join(tel_dir, rule_id + ".jsonl")
    uses = 0
    succ = 0
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                uses += 1
                if r.get("success") is True:
                    succ += 1
    except OSError:
        return (0, 0)
    return (uses, succ)


def enumerate_rules(knowledge_dir, objects_dir, classes, allow=None):
    """Yield a record dict per rule in the requested classes.

    record = {rule_id, action_type, action, contaminated, clean,
              contaminated_tokens, source, use_count, success_count}
    `contaminated` is True when at least one action token is priority-like.
    `action` is None for `unresolved` rules (never flagged).
    """
    index_dir = os.path.join(knowledge_dir, "_crystallizer_index")
    tel_dir = os.path.join(knowledge_dir, "_crystallizer_telemetry")
    if not os.path.isdir(index_dir):
        return
    want = set(classes)
    try:
        idx_files = sorted(os.listdir(index_dir))
    except OSError:
        return
    for fn in idx_files:
        if not fn.endswith(".jsonl"):
            continue
        action_type = fn[:-6]
        if want and action_type not in want:
            continue
        seen = set()
        try:
            fh = open(os.path.join(index_dir, fn))
        except OSError:
            continue
        with fh as f:
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
                rule_id = row.get("rule_id", "")
                if not rule_id or rule_id in seen:
                    continue
                seen.add(rule_id)

                action, source = _action_from_index_row(row)
                if action is None:
                    action, source = _action_from_obj(objects_dir, rule_id)

                uses, succ = _telemetry(tel_dir, rule_id)
                rec = {
                    "rule_id": rule_id,
                    "action_type": action_type,
                    "action": action,
                    "source": source,
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
                if source == "object:raw":
                    # Unstructured blob — text-scan for embedded tokens.
                    hits = _scan_text_for_priority(action, allow)
                    rec["contaminated"] = bool(hits)
                    rec["contaminated_tokens"] = hits
                else:
                    _all, dirty, clean = classify_action(action, allow)
                    rec["contaminated"] = bool(dirty)
                    rec["contaminated_tokens"] = dirty
                    rec["clean"] = clean
                yield rec


def _parse_classes(spec):
    return [c.strip() for c in spec.split(",") if c.strip()]


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Audit crystallized rule action slots for priority-like contamination (#1478).")
    ap.add_argument("--knowledge-dir", required=True,
                    help="<fed>/.agentis/knowledge directory")
    ap.add_argument("--objects-dir", default="",
                    help="<fed>/.agentis/objects directory (content-addressed rule store)")
    ap.add_argument("--class", dest="classes", default="label",
                    help="comma-separated action_type list to scan (default: label)")
    ap.add_argument("--allow", default="",
                    help="comma-separated extra always-canonical tokens (never flagged)")
    ap.add_argument("--json", action="store_true",
                    help="emit one JSON object per contaminated rule (JSONL) + a _summary line")
    args = ap.parse_args(argv)

    allow = {t.strip().lower() for t in args.allow.split(",") if t.strip()}
    classes = _parse_classes(args.classes)

    total = 0
    contaminated = []
    unresolved = 0
    for rec in enumerate_rules(args.knowledge_dir, args.objects_dir, classes, allow):
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
    print("priority-rule audit (#1478)")
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
        print("    - " + rec["rule_id"])
        print("        action        : " + (rec["action"] or ""))
        print("        priority-like : " + ", ".join(rec["contaminated_tokens"]))
        print("        clean remainder: " + (", ".join(rec["clean"]) if rec["clean"] else "(none — rule slot empties out)"))
        print("        source        : " + rec["source"] + rate)
    return 0


if __name__ == "__main__":
    sys.exit(main())
