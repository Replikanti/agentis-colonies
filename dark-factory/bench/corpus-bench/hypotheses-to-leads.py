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
#   --include-tier2   (#2217 PR B; only meaningful with --from-discovery, default OFF)
#       additionally project the merged file's TOP-LEVEL `tier2[]` records — the checks a cell DERIVED and
#       did not settle (#2217 PR A) — into leads flagged `"tier": 2`. DEFAULT OFF is load-bearing, not a
#       convenience: generation-recall.sh's PRIMARY number is computed from the lead set this adapter emits
#       WITHOUT the flag, so a tier-2 record can never reach it, whatever the input file carries.
#   --from-invariants <file|glob>
#       parse `INVARIANT|<file:fn>|<verdict>` lines (run-invariant-hunt.sh / the run-zone-hunt.sh deep-hunt
#       adapter emit exactly one per prover run) into a `{location:"file:fn", file, class:"invariant"}` lead.
#       The VERDICT is DISCARDED on purpose: a CLEAN invariant that still NAMES a real bug's location is a
#       GENERATION hit — the fuzzer's failure to confirm is the generation-vs-confirmation delta, not a miss
#       of the generation step. A glob argument matching nothing is an empty (not an error) result; a plain
#       path that is unreadable is exit 3.
#   --errored-from <verified_findings.json> --errored-select only|exclude   (#2288 M2; both or neither, and only
#       with --from-discovery) split the discovery leads by whether the refute gate ever ASSESSED them. A
#       location string (stripped) is ERRORED-ONLY when its errors[] count in <verified_findings.json> is at
#       least its tier-1 candidate count in the merged file (and that count is > 0): every candidate there ended
#       in errors[], so no verdict exists for it. `only` emits just the tier-1 discovery leads at errored-only
#       locations (no invariant, no tier-2 lead); `exclude` emits every OTHER lead the same flags would emit
#       (the remaining discovery leads, tier-2 leads under --include-tier2, and the invariant leads).
#       generation-recall.sh scores both sets to name the GT rows that ONLY an unassessed candidate matched.
#       Without these flags the output is byte-identical to the pre-#2288 adapter.
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


def leads_from_discovery(path, include_tier2=False):
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
    if include_tier2:
        leads.extend(leads_from_tier2(data))
    return leads


def leads_from_tier2(data):
    """Top-level `tier2[]` (#2217 PR A) -> leads flagged `"tier": 2`. A tier-2 record is NOT a candidate: it
    is a check the cell derived and did not settle, it carries no severity assessment, and its `location` was
    derived by REGEX from the check's own text rather than asserted by the model. It is therefore projected
    only under --include-tier2, and score-match.py — which is FROZEN and ignores unknown lead keys — scores it
    by exactly the same location-first rule as a tier-1 lead; the `tier` key exists so a consumer can tell the
    two apart AFTER scoring, never so the scorer treats them differently."""
    if not isinstance(data, dict):
        return []
    leads = []
    for rec in data.get("tier2", []):
        if not isinstance(rec, dict):
            continue
        location = str(rec.get("location", "") or "").strip()
        if not location:
            continue  # a record without a location cannot be scored at all; dropping it beats a bare `file` guess
        check = str(rec.get("check", "") or "").strip()
        why = str(rec.get("why", "") or "").strip()
        # The cell's OWN two sentences: what it checked, and why it did not settle it. Joined (rather than
        # keeping only the check) so the technical-token fallback has the same material a tier-1 exploit has.
        exploit = " — ".join([t for t in (check, why) if t])
        leads.append({
            "location": location,
            "file": bare_codefile(location),
            "class": str(rec.get("class", "") or "").strip(),
            "exploit": exploit,
            "poc_sketch": "",
            "tier": 2,
        })
    return leads


def errored_only_locations(discovery_path, errored_path):
    """#2288 M2: the set of stripped location strings whose EVERY tier-1 candidate ended in the verify stage's
    errors[] (errors count >= candidate count > 0). Keyed on the location string verbatim, the same key
    verify-findings.sh writes into errors[] (manifest field 1 = the candidate string's first field)."""
    try:
        with open(discovery_path, encoding="utf-8", errors="ignore") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as e:
        die(3, "cannot read --from-discovery input: " + str(e))
    try:
        with open(errored_path, encoding="utf-8", errors="ignore") as fh:
            vf = json.load(fh)
    except (OSError, ValueError) as e:
        die(3, "cannot read --errored-from input: " + str(e))
    cand_n = {}
    for cell in (data.get("cells", []) if isinstance(data, dict) else []):
        if not isinstance(cell, dict):
            continue
        for cand in cell.get("candidates", []):
            if isinstance(cand, str):
                loc = cand.split("|", 1)[0].strip()
                cand_n[loc] = cand_n.get(loc, 0) + 1
    err_n = {}
    for rec in (vf.get("errors", []) if isinstance(vf, dict) else []) or []:
        if isinstance(rec, dict):
            loc = str(rec.get("location", "") or "").strip()
            err_n[loc] = err_n.get(loc, 0) + 1
    return {loc for loc, n in cand_n.items() if n > 0 and err_n.get(loc, 0) >= n}


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
    include_tier2 = False
    errored_from = None
    errored_select = None
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
        elif a == "--include-tier2":
            include_tier2 = True
            i += 1
        elif a == "--errored-from":
            if i + 1 >= len(argv):
                die(2, "--errored-from requires a value")
            errored_from = argv[i + 1]
            i += 2
        elif a == "--errored-select":
            if i + 1 >= len(argv):
                die(2, "--errored-select requires a value")
            errored_select = argv[i + 1]
            if errored_select not in ("only", "exclude"):
                die(2, "--errored-select must be only or exclude")
            i += 2
        elif a in ("-h", "--help"):
            sys.stdout.write(__doc__ or "")
            return 0
        else:
            die(2, "unknown arg: " + a)
    if discovery is None and invariants is None:
        die(2, "usage: hypotheses-to-leads.py [--from-discovery <merged.json>]"
               " [--from-invariants <file|glob>] [--include-tier2]"
               " [--errored-from <verified_findings.json> --errored-select only|exclude]")
    if (errored_from is None) != (errored_select is None):
        die(2, "--errored-from and --errored-select go together")
    if errored_from is not None and discovery is None:
        die(2, "--errored-from/--errored-select need --from-discovery")

    leads = []
    if discovery is not None:
        disc_leads = leads_from_discovery(discovery, include_tier2)
        if errored_from is not None:
            # #2288 M2: only tier-1 leads can be errored-only (a tier-2 record never reaches the refute gate)
            errored = errored_only_locations(discovery, errored_from)
            hit = [("tier" not in l and l["location"] in errored) for l in disc_leads]
            disc_leads = [l for l, h in zip(disc_leads, hit) if h == (errored_select == "only")]
        leads.extend(disc_leads)
    if invariants is not None and errored_select != "only":
        leads.extend(leads_from_invariants(invariants))

    sys.stdout.write(json.dumps({"verified": leads}, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
