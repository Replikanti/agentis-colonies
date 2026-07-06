#!/usr/bin/env python3
"""Shared canonical-context builder for the triage crystallizer pilots (#1431).

Single source of truth for turning a raw forge issue into the SAME
(canonical_ctx, coarse_ctx, canonical_action) triple the triage agents
build inline at replay/distill time (#1234 router, #1235 labeler, #1430
prioritizer). The backfill/ingestion path (tools/backfill-crystallizer.sh)
MUST emit byte-identical condition strings, or the ingested rules are
unreachable from Stage 1's prefix match and Stage 1b's BM25 class-confirm.

Drift guard: tools/test-canonical-context.sh asserts (a) the VOCAB literal
below equals the inline VOCAB in each agent's .ag builder byte-for-byte and
(b) pinned fixture outputs. If you change VOCAB or the ctx shapes here,
change the agents too (and vice versa).

Modes:
  issue    read ONE raw issue JSON object on stdin, print one TSV line:
             <iid>\t<ctx>\t<coarse>\t<action>\t<query>
           or nothing when the issue is not "decided" for the class.
  triples  read a raw issues ARRAY on stdin, print one JSON object per
           line: {"class","iid","ctx","coarse","action"} for every
           requested class the issue is decided for. Honors --since
           (ISO timestamp; only issues with updated_at strictly greater),
           --max (cap on ISSUES considered), --order (newest|oldest;
           incremental callers MUST use oldest so the cursor advances
           monotonically through history instead of jumping past the
           un-processed tail when a window holds more than --max issues)
           and --cursor-out (write the max updated_at of the PROCESSED
           issues, for the incremental-ingest cursor).

Env: ME = operator username (scope dimension, labeler class only),
     PV = operator priority-label vocabulary (free text, #226).

Field normalization: accepts both GitLab and GitHub raw shapes —
iid|number, labels as strings or {name} objects, assignees username|login,
author|user.username|login.
"""

import argparse
import json
import os
import re
import sys

# Keep byte-identical to the inline VOCAB in triage/agents/{labeler,router,
# prioritizer}.ag (drift-asserted by tools/test-canonical-context.sh).
VOCAB = ["bug", "crash", "error", "fail", "segfault", "panic", "exception",
         "docs", "documentation", "readme", "feature", "enhancement",
         "request", "question", "security", "vuln", "cve", "performance",
         "perf", "slow", "test", "ci", "build", "regression", "refactor",
         "dependency"]

QUERY_MAX = 1200


def is_pri(label, pv):
    """Priority-like label heuristic — mirror prioritizer.ag (#1430)."""
    l2 = str(label).strip().lower()
    if not l2:
        return False
    if l2.startswith("priority"):
        return True
    if re.fullmatch(r"p\d+", l2):
        return True
    if l2 == "urgent":
        return True
    if pv and l2 in pv:
        return True
    return False


def norm_issue(x):
    """Normalize a raw GitLab/GitHub issue into one common shape."""
    if not isinstance(x, dict):
        return None
    iid = x.get("iid", x.get("number"))
    if iid is None:
        return None
    labels = []
    for l in x.get("labels") or []:
        name = l.get("name") if isinstance(l, dict) else l
        name = str(name).strip() if name is not None else ""
        if name:
            labels.append(name)
    assignees = []
    for a in x.get("assignees") or []:
        if isinstance(a, dict):
            u = a.get("username") or a.get("login") or ""
            if str(u).strip():
                assignees.append(str(u).strip())
    if not assignees:
        a1 = x.get("assignee")
        if isinstance(a1, dict):
            u = a1.get("username") or a1.get("login") or ""
            if str(u).strip():
                assignees.append(str(u).strip())
    author_obj = x.get("author") if isinstance(x.get("author"), dict) else x.get("user")
    author = ""
    if isinstance(author_obj, dict):
        author = str(author_obj.get("username") or author_obj.get("login") or "").strip()
    return {
        "iid": iid,
        "title": str(x.get("title") or ""),
        "description": str(x.get("description") or x.get("body") or ""),
        "labels": labels,
        "assignees": assignees,
        "author": author,
        "updated_at": str(x.get("updated_at") or ""),
    }


def kw_hits(text):
    toks = set(re.findall(r"[a-z]+", text.lower()))
    return sorted({w for w in VOCAB if w in toks})


def one_line(text):
    return re.sub(r"\s+", " ", text).strip()[:QUERY_MAX]


def build(issue, klass, me, pv):
    """Return (ctx, coarse, action, query) or None when not decided."""
    labels = issue["labels"]
    if klass == "label":
        # Decided = the operator applied at least one label. The action
        # EXCLUDES priority-like labels — those belong to the "prioritize"
        # class (#1430); mixing them here would mint label rules that fight
        # the prioritizer over the same write.
        action_labels = sorted({l for l in labels if not is_pri(l, pv)})
        if not labels or not action_labels:
            return None
        hits = kw_hits(issue["title"] + " " + issue["description"])
        # #1435: an empty keyword signature would distill the bare "kw="
        # condition, which prefix-matches EVERY context of the class once
        # crystallized (agents guard the same way at their distill sites).
        if not hits:
            return None
        scope = "personal" if (me and issue["author"] == me) else "team"
        ctx = "kw=" + ",".join(hits) + " scope=" + scope
        coarse = "kw=" + ",".join(hits)
        action = ",".join(action_labels)
        query = one_line(issue["title"] + " " + issue["description"])
        return ctx, coarse, action, query
    if klass == "route":
        if not issue["assignees"]:
            return None
        hits = kw_hits(issue["title"])
        # #1435: see the label-class comment — never mint a "kw=" condition.
        if not hits:
            return None
        slabels = sorted(set(labels))
        ctx = "kw=" + ",".join(hits) + " labels=" + ",".join(slabels)
        coarse = "kw=" + ",".join(hits)
        action = issue["assignees"][0].strip().lstrip("@")
        if not action.strip():
            return None
        query = one_line(issue["title"] + " " + " ".join(slabels))
        return ctx, coarse, action, query
    if klass == "prioritize":
        pri = sorted({l for l in labels if is_pri(l, pv)})
        if not pri:
            return None
        hits = kw_hits(issue["title"])
        # #1435: see the label-class comment — never mint a "kw=" condition.
        if not hits:
            return None
        nonpri = sorted({l for l in labels if not is_pri(l, pv)})
        ctx = "kw=" + ",".join(hits) + " labels=" + ",".join(nonpri)
        coarse = "kw=" + ",".join(hits)
        action = pri[0]
        query = one_line(issue["title"] + " " + " ".join(nonpri))
        return ctx, coarse, action, query
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["issue", "triples"])
    ap.add_argument("--class", dest="klass",
                    choices=["label", "route", "prioritize"],
                    help="required in issue mode")
    ap.add_argument("--classes", default="label,route,prioritize",
                    help="comma list, triples mode")
    ap.add_argument("--since", default="",
                    help="only issues with updated_at strictly greater (ISO)")
    ap.add_argument("--max", type=int, default=200,
                    help="cap on issues considered")
    ap.add_argument("--order", choices=["newest", "oldest"], default="newest",
                    help="processing order when --max truncates; incremental "
                         "callers use oldest for monotonic cursor progress")
    ap.add_argument("--cursor-out", default="",
                    help="file to write max processed updated_at into")
    args = ap.parse_args()

    me = os.environ.get("ME", "").strip()
    pv = os.environ.get("PV", "").lower()

    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0

    if args.mode == "issue":
        if not args.klass:
            print("canonical-context.py: --class required in issue mode",
                  file=sys.stderr)
            return 2
        issue = norm_issue(data)
        if issue is None:
            return 0
        built = build(issue, args.klass, me, pv)
        if built is None:
            return 0
        ctx, coarse, action, query = built
        # Diagnostic TSV surface: flatten fields so a pathological label
        # with an embedded tab/newline cannot corrupt the line. The
        # machine path (triples mode) JSON-escapes instead.
        print(str(issue["iid"]) + "\t" + one_line(ctx) + "\t"
              + one_line(coarse) + "\t" + one_line(action) + "\t" + query)
        return 0

    # triples mode
    if not isinstance(data, list):
        return 0
    classes = [c for c in args.classes.split(",") if c.strip()]
    issues = [i for i in (norm_issue(x) for x in data) if i is not None]
    if args.since:
        issues = [i for i in issues if i["updated_at"] > args.since]
    issues.sort(key=lambda i: i["updated_at"],
                reverse=(args.order == "newest"))
    if args.max > 0:
        issues = issues[:args.max]
    cursor = ""
    for issue in issues:
        if issue["updated_at"] > cursor:
            cursor = issue["updated_at"]
        for klass in classes:
            built = build(issue, klass, me, pv)
            if built is None:
                continue
            ctx, coarse, action, _query = built
            print(json.dumps({"class": klass, "iid": issue["iid"],
                              "ctx": ctx, "coarse": coarse,
                              "action": action}, sort_keys=True))
    if args.cursor_out and cursor:
        with open(args.cursor_out, "w", encoding="utf-8") as f:
            f.write(cursor)
    return 0


if __name__ == "__main__":
    sys.exit(main())
