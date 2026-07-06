#!/usr/bin/env python3
"""Backfill driver generator for the triage crystallizer pool (#1431).

Reads triples JSONL (one {"class","iid","ctx","coarse","action"} object per
line, produced by tools/lib/canonical-context.py triples mode) on stdin.

Default mode emits a standalone .ag driver that replays every triple
through the substrate learning surface:

    learn(<class>, <ctx>, <action>, "success", ["distilled","triage","backfill"]);
    let dN = try { distill(<class>, <coarse>, <action>, "heuristic"); } catch e { ""; };
    if len(dN) > 0 { knowledge_validate(dN); };

Run via `agentis go` from the federation root so the rows land in the
federation's .agentis knowledge base. Crystallization itself happens on the
daemons' periodic M141 pass (agentis-core `evolution.crystallize_*`
defaults): a (class, coarse, action) triple occurring >= 3 times reaches
the >= 3 empirical_validations gate and materializes as a replayable rule.
distill() raises until >= 3 successful records exist for the topic — the
learn() row emitted per triple feeds exactly that gate, and the try/catch
keeps early triples non-fatal (they still count via learn()).

--table mode prints the dry-run summary instead (class, occurrences,
would-crystallize marker per distinct (coarse, action) pair) and writes no
driver.

The learn tag "backfill" keeps these rows out of the acting-path fitness
buckets (auto-promote keys on acted/emitted/review-gated/observed tier
tags) while staying greppable for provenance.
"""

import json
import sys


def esc(s):
    """Escape a python string into an .ag double-quoted literal body."""
    out = []
    for ch in str(s):
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ord(ch) < 0x20:
            out.append(" ")
        else:
            out.append(ch)
    return "".join(out)


def main():
    table_mode = "--table" in sys.argv[1:]
    triples = []
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            t = json.loads(line)
        except Exception:
            continue
        if not isinstance(t, dict):
            continue
        if not all(isinstance(t.get(k), str) and t.get(k) for k in
                   ("class", "ctx", "coarse", "action")):
            continue
        if t["class"] not in ("label", "route", "prioritize"):
            continue
        triples.append(t)

    if table_mode:
        counts = {}
        for t in triples:
            key = (t["class"], t["coarse"], t["action"])
            counts[key] = counts.get(key, 0) + 1
        print("class\toccurrences\twould_crystallize\tcoarse_ctx\taction")
        for (klass, coarse, action), n in sorted(
                counts.items(), key=lambda kv: (-kv[1], kv[0])):
            would = "yes" if n >= 3 else "no"
            print(f"{klass}\t{n}\t{would}\t{coarse}\t{action}")
        print(f"# triples={len(triples)} distinct={len(counts)}", file=sys.stderr)
        return 0

    if not triples:
        return 0

    # 5 (call) + ~15 learn + ~10 distill + ~10 validate + string/let
    # overhead per triple — 100 CB per triple is a generous ceiling; +500
    # base keeps tiny drivers comfortable.
    budget = 500 + 100 * len(triples)
    lines = [f"cb {budget};", ""]
    for i, t in enumerate(triples):
        k, c, co, a = (esc(t["class"]), esc(t["ctx"]),
                       esc(t["coarse"]), esc(t["action"]))
        lines.append(f'learn("{k}", "{c}", "{a}", "success", ["distilled", "triage", "backfill"]);')
        lines.append(f'let d{i} = try {{ distill("{k}", "{co}", "{a}", "heuristic"); }} catch e {{ ""; }};')
        lines.append(f'if len(d{i}) > 0 {{ knowledge_validate(d{i}); }};')
        lines.append("")
    lines.append(f'print("[backfill] processed {len(triples)} triples");')
    sys.stdout.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
