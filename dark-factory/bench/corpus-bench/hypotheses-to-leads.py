#!/usr/bin/env python3
# hypotheses-to-leads.py — corpus-bench GENERATION-recall adapter (issue #1730). Projects the pipeline's
# GENERATED hypotheses — the breadth hunter's PRE-REFUTE candidates and the deep-hunt lens's generated
# invariant targets — into the exact `{"verified":[{location,file,class,exploit,poc_sketch}]}` lead shape the
# FROZEN score-match.py already consumes, WITHOUT teaching score-match.py a new candidate format. This keeps
# the #1698/#1699 re-measurement scorer byte-identical (it is pinned by run-corpus-bench.sh --self-test) and
# lets generation-recall.sh score the GENERATION step in isolation from fuzzer/refuter confirmation.
#
# Why an external adapter and not a `score-match.py --key`: the discovery candidate is a pipe-delimited STRING
# (`file:fn:line|classid|severity|exploit|poc`), not a lead object, so a key swap alone cannot parse it; and
# score-match.py is frozen. All projection logic lives here.
#
# Two input modes (either or BOTH; both given -> the UNION, discovery leads first then invariant leads):
#   --from-discovery <discovery-results.merged.json>
#       walk cells[].candidates[] (run-discovery.sh / run-zone-hunt.sh merge schema), split each
#       `file:fn:line|classid|severity|exploit|poc` string into a lead. The `location` is passed through
#       verbatim (score-match.py's lead_location parses file+function off it); `file` is the bare source path.
#   --from-invariants <file|glob>
#       parse `INVARIANT|<file:fn>|<verdict>` lines (run-invariant-hunt.sh / the run-zone-hunt.sh deep-hunt
#       adapter emit exactly one per prover run) into a `{location:"file:fn", file, class:"invariant"}` lead.
#       The VERDICT is DISCARDED on purpose: a CLEAN invariant that still NAMES a real bug's location is a
#       GENERATION hit — the fuzzer's failure to confirm is the generation-vs-confirmation delta, not a miss
#       of the generation step. A glob argument matching nothing is an empty (not an error) result; a plain
#       path that is unreadable is exit 3.
#
# Output (stdout): `{"verified":[ ... ]}` as pretty JSON (indent=2, sort_keys) + trailing newline.
# Exit: 0 on a well-formed run ; 2 bad args ; 3 unreadable/malformed input.
import sys
import os
import glob
import json


def die(rc, msg):
    sys.stderr.write("hypotheses-to-leads.py: " + msg + "\n")
    sys.exit(rc)


def bare_codefile(location):
    """Reduce a (possibly decorated) candidate/invariant location to the bare repo-relative source path — the
    same strip order verify-findings.sh uses, so the `file` fallback basename resolves even when the hunter
    decorated the location with a `:~(test/..)` tail or an `@func` compound suffix."""
    s = location
    s = s.split("~", 1)[0]    # drop a `:~(test/File.t.sol:test_fn)` test-reference tail (and its colons)
    s = s.split(":", 1)[0]    # the file is the part before the FIRST ':' delimiter
    s = s.split("@", 1)[0]    # drop a compound `@func` suffix
    s = s.strip().rstrip("(").strip()
    return s


def leads_from_discovery(path):
    """cells[].candidates[] -> leads. Defensive field parsing: a short/malformed candidate never crashes,
    missing fields become empty strings (score-match.py then simply cannot resolve that lead)."""
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as e:
        die(3, "cannot read --from-discovery input: " + str(e))
    leads = []
    cells = data.get("cells", []) if isinstance(data, dict) else []
    for cell in cells:
        if not isinstance(cell, dict):
            continue
        for cand in cell.get("candidates", []):
            if not isinstance(cand, str):
                continue
            parts = cand.split("|", 4)
            while len(parts) < 5:
                parts.append("")
            location, classid, _severity, exploit, sketch = parts[0], parts[1], parts[2], parts[3], parts[4]
            leads.append({
                "location": location.strip(),
                "file": bare_codefile(location),
                "class": classid.strip(),
                "exploit": exploit.strip(),
                "poc_sketch": sketch.strip(),
            })
    return leads


def leads_from_invariants(pattern):
    """`INVARIANT|<file:fn>|<verdict>` lines -> leads (verdict DISCARDED). Accepts a plain file OR a glob; a
    glob matching nothing yields no leads, a named-but-unreadable plain path is exit 3."""
    files = sorted(glob.glob(pattern))
    if not files:
        if glob.has_magic(pattern):
            return []  # a glob with no matches is an empty (logged-skip) result, not an error
        die(3, "cannot read --from-invariants input: " + pattern)
    leads = []
    for path in files:
        try:
            with open(path, encoding="utf-8", errors="ignore") as fh:
                lines = fh.readlines()
        except OSError as e:
            die(3, "cannot read --from-invariants input: " + str(e))
        for line in lines:
            if line.lstrip().startswith("#"):
                continue  # a `#` comment (e.g. a fixture header documenting the format) is never a real line
            if "INVARIANT|" not in line:
                continue
            seg = line.split("INVARIANT|", 1)[1].strip()
            cols = seg.split("|")
            target = cols[0].strip()  # file:fn ; cols[1] is the fuzzer verdict — intentionally discarded
            if not target:
                continue
            leads.append({
                "location": target,
                "file": bare_codefile(target),
                "class": "invariant",
            })
    return leads


def main(argv):
    discovery = None
    invariants = None
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--from-discovery":
            if i + 1 >= len(argv):
                die(2, "--from-discovery requires a value")
            discovery = argv[i + 1]
            i += 2
        elif a == "--from-invariants":
            if i + 1 >= len(argv):
                die(2, "--from-invariants requires a value")
            invariants = argv[i + 1]
            i += 2
        elif a in ("-h", "--help"):
            sys.stdout.write(__doc__ or "")
            return 0
        else:
            die(2, "unknown arg: " + a)
    if discovery is None and invariants is None:
        die(2, "usage: hypotheses-to-leads.py [--from-discovery <merged.json>] [--from-invariants <file|glob>]")

    leads = []
    if discovery is not None:
        leads.extend(leads_from_discovery(discovery))
    if invariants is not None:
        leads.extend(leads_from_invariants(invariants))

    sys.stdout.write(json.dumps({"verified": leads}, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
