#!/usr/bin/env python3
# score-match.py — corpus-bench-only scorer (issue #1697). REPLACES the old free-text token-overlap oracle
# (novelty-gate.sh shelled out per lead x per truth row), which failed across every threshold because a
# concluded Sherlock report's prose and a terse verified-finding lead share too few generic-DeFi words to
# clear any overlap floor without also matching unrelated rows. This matcher is LOCATION-first: a
# verified_findings.json lead carries a structured `location = <file>:<function>:<line>`, and each truth row's
# `signature` prose reliably names both the affected `*.sol` file basename and the function — so requiring BOTH
# tokens to co-occur in one signature disambiguates the ambiguous file basename (e.g. GatewayTransferNative.sol
# appears in many rows; a specific function name appears in one) and makes recall threshold-independent.
#
# SEMANTIC MECHANISM JUDGE (issue #1829). The location-first matcher above errs in BOTH directions, because a
# name is neither necessary nor sufficient evidence of the same bug:
#   * NAME-DIVERGENT TRUE MATCH (false negative): the hunter names the factory/helper that actually contains the
#     faulty code while the GT prose anchors its `.sol` link on the strategy contract and never names that
#     function -> the same root cause scores MISS.
#   * NAME-COINCIDENT FALSE MATCH (false positive): a candidate names a function a GT row also names, but
#     describes a DIFFERENT mechanism -> an unrelated row scores HIT.
# `--judge <cache|cmd>` replaces the token matcher with one LLM decision per lead over batches of truth rows,
# deciding ROOT CAUSE + MECHANISM identity. In judge mode the judge is AUTHORITATIVE: there is NO fallback to
# the token matcher, because a silent fallback would re-import exactly the two failure modes above. An
# unparseable reply is a JUDGE-ERROR (never a silent NO-MATCH) and the run ABORTS with exit 4 above
# `--judge-max-error-rate` — a degraded backend must not produce a plausible-looking low recall.
# `--judge off` is the DEFAULT and keeps the #1697 matcher frozen and byte-identical.
#
# GT EQUIVALENCE CLASSES (issue #1840). A concluded judging repo routinely accepts TWO rows for the SAME
# underlying bug, described differently and found by very different watson counts. The judge is asked for at
# most one MATCH per candidate and only ever sees one `--judge-batch` slice at a time, so a lead that finds
# such a bug credits whichever twin the model happened to name — and because the headline metric is stratified
# by rarity, the RARE twin is the one silently lost. `--gt-dupes <file>` fixes that GT-side: a per-contest
# artifact (built once by gt-dupes.sh, archived next to truth.tsv) lists judged duplicate PAIRS, which are
# unioned into equivalence CLASSES, and a lead that matched any member credits every member.
# The precision contract is deliberately narrow:
#   * DENOMINATORS NEVER MOVE — `gt_total` and every severity/rarity stratum stay one entry per accepted row.
#   * EXPANSION TOUCHES `row_hit` ONLY — `LEADS`/`matched_leads` and the `--per-lead` lines are untouched, so
#     one lead can never become N matched leads and the unmatched-lead triage queue keeps its meaning.
#   * EVERY EXPANDED HIT IS SEPARABLE — the `DUP` / `DUPHIT` trailers make `hits - expanded_hits` recover the
#     pre-#1840 number from the SAME replay, so no published figure can hide how much came from expansion.
#   * FAIL-CLOSED — a pair naming a sev_id absent from truth.tsv is a hard exit 3 (a stale or wrong-contest
#     artifact must never silently mis-credit), and a class larger than `--gt-dupes-max-class` is not expanded
#     at all. The merge bar (`--gt-dupes-min-confidence`, default 85) is applied at SCORING time and sits
#     deliberately far above the judge's scoring gate, because a false merge silently moves the headline.
# The flag is opt-in and absent by default, so every existing scorecard stays byte-identical.
#
# THE SCORING GATE, AND RECORDING THE RULER (issue #1841). The judge's decision rule says location divergence
# is NOT disqualifying, but the judge does not obey that rule in its CONFIDENCE: when a lead describes the GT
# row's root cause from a location the row's prose never names (a superseded copy, a factory, a helper), it
# returns MATCH with a confidence in the 60s. At the old `--judge-min-confidence` default of 70 that hedge
# became a scored MISS, so the rule and the ruler contradicted each other and the contradiction was resolved
# against the pipeline. The default is now 60 — placed deliberately BELOW the entire observed 62-68
# location-divergence band rather than through the middle of it, which makes it an OUTLIER FLOOR against a
# MATCH the judge itself disbelieves, not a recall parameter. It is inert on the measured data (43 judging
# calls over 2 contests: nothing at all is dropped at 50 or 60 on either). No threshold value can create a
# false positive: the #1829 false-positive direction is decided by the MATCH/NO-MATCH DECISION, and the gate
# only ever DROPS MATCHes. Because a gate that moves a headline silently is the actual hazard, judge mode now
# also emits `GATE\t<threshold>\t<gated_matches>\t<gated_rows>`: the threshold in force, how many MATCH
# decisions it dropped, and how many rows that cost. A run reporting a nonzero `gated_rows` is a run whose
# headline is gate-sensitive and must publish the sensitivity alongside it.
#
# This is a BENCH scorer only. It does NOT touch novelty-gate.sh (the LIVE hunting-pipeline boundary/novelty
# gate, frozen for the #1698/#1699 re-measurement) or extract-gt.sh (truth.tsv schema unchanged).
#
# Usage: score-match.py <truth.tsv> <verified_findings.json> [--min-overlap N] [--per-lead]
#                       [--judge <off|cache|cmd>] [--judge-cmd <path>] [--judge-cache <file.jsonl>]
#                       [--judge-log <file.jsonl>] [--judge-batch N] [--judge-min-confidence N]
#                       [--judge-max-error-rate PCT] [--gt-dupes <file.tsv>]
#                       [--gt-dupes-min-confidence N] [--gt-dupes-max-class N]
#   truth.tsv           extract-gt.sh output: sev_id \t severity \t rarity \t title \t signature (per row).
#   verified_findings.json  run-zone-hunt.sh verify output: {"verified": [ {location, file, ...}, ... ]}.
#   --min-overlap N     ONLY governs the location-unavailable fallback (a lead with no parseable function).
#                       Location-resolvable leads are threshold-INDEPENDENT; N never affects them. Default 2.
#   --judge <mode>      off (DEFAULT, the frozen #1697 token matcher) | cache (replay recorded decisions only;
#                       a cache MISS is fatal, exit 4 — deterministic, CI-safe, no LLM) | cmd (invoke
#                       --judge-cmd for a miss and record it read-through into --judge-cache).
#   --judge-cmd <path>  judge driver: one request JSON on stdin -> `VERDICT|` lines on stdout. Default
#                       mech-judge.sh next to this script (which drives the flat-cyborg PTY wrapper).
#   --judge-cache <f>   JSONL read-through cache keyed by the sha256 of the canonical request. A judged number
#                       is only reproducible via its recorded cache/log — archive it next to the scorecard.
#   --judge-log <f>     JSONL append-only log of every LIVE judging call (request + raw reply + decisions).
#   --judge-batch N     truth rows shown per judging call (default 12): the lead is judged against ALTERNATIVE
#                       rows, so a name-coincident candidate has a better home to go to.
#   --judge-min-confidence N  MATCH decisions below this confidence (0-100) do not score. Default 60 (#1841:
#                       an outlier floor placed BELOW the observed 62-68 location-divergence hedge band, not a
#                       recall parameter). The value in force is reported in the `GATE` trailer, and one
#                       archived decision cache re-derives the number at any threshold.
#   --judge-max-error-rate P  abort (exit 4) when JUDGE-ERRORs exceed this percentage of leads. Default 20.
#   --gt-dupes <f>      #1840 GT-equivalence artifact next to truth.tsv (gt-dupes.sh output): `#` comment /
#                       provenance lines plus one `DUP\t<sev_a>\t<sev_b>\t<confidence>\t<reason>` row per
#                       judged duplicate pair. Pairs are unioned into classes and a matched member credits the
#                       whole class. Applies in EVERY --judge mode: equivalence is a property of the ground
#                       truth, not of the matcher. Absent by default (output byte-identical without it).
#   --gt-dupes-min-confidence N  merge bar applied at SCORING time (0-100, default 85 — deliberately far above
#                       the judge's scoring gate). One archived artifact therefore re-derives the expanded
#                       number, the unexpanded number, and any threshold in between.
#   --gt-dupes-max-class N  a class of more than N rows is NOT expanded at all (default 3), with a warning on
#                       stderr — fail-closed against a runaway merge chain.
#   --per-lead          ADDITIVE (default output byte-identical without it): after the normal output, append
#                       one `LEAD\t<class>\t<HIT|MISS>` line per verified lead — HIT when that lead matched a
#                       real GT row, MISS otherwise. This is per-lead REAL-BUG PRECISION material for the
#                       bench->knowledge fitness feeder (bench-to-knowledge.sh, issue #1711): a class's HITs
#                       are its leads that hit ground truth, its MISSes are unmatched noise. The lead's `class`
#                       field is NORMALIZED (a leading `class=` prefix is stripped; empty/missing -> `unknown`)
#                       so the `class=C3` vs `C3` inconsistency in verified_findings.json collapses to one key.
# Output (stdout): one `<sev_id>\t<HIT|MISS>` line per truth row (input order), then a trailer line
#   `LEADS\t<verified_n>\t<matched_leads>` (verified lead count; leads matching >=1 truth row). In judge mode
#   TWO extra trailer lines follow it: `JUDGE\t<calls>\t<errors>` and (#1841) `GATE\t<min_confidence>\t
#   <gated_matches>\t<gated_rows>` — the confidence gate in force, how many valid MATCH decisions it dropped,
#   and how many truth rows are MISS ONLY because of it. Under `--gt-dupes`, one
#   `DUP\t<classes>\t<expanded_hits>` trailer plus one `DUPHIT\t<credited_sev_id>\t<directly_matched_sev_id>`
#   line per expanded row follow those. With `--per-lead`, one `LEAD\t<class>\t<HIT|MISS>` line per verified
#   lead comes last.
# Exit: 0 always on a well-formed run; 2 bad args; 3 unreadable/malformed input, a stale --gt-dupes artifact,
#       or an unrunnable judge driver;
#       4 judge mode degraded (cache miss under --judge cache, or JUDGE-ERRORs over --judge-max-error-rate).
import sys
import os
import re
import json
import hashlib
import subprocess

# Generic-DeFi stopwords stripped from the technical-token FALLBACK only — these words appear in almost every
# finding's prose, so counting them as overlap is exactly what made the old oracle useless.
STOPWORDS = {
    "token", "swap", "refund", "attacker", "gateway", "fee", "amount",
    "transfer", "user", "address", "contract", "chain", "value", "native",
}

# camelCase / PascalCase-with-internal-cap identifiers (claimRefund, withdrawToNativeChain, AccountEncoder) ...
_CAMEL_RE = re.compile(r"\b[A-Za-z]+[A-Z][A-Za-z0-9]*\b")
# ... plus `name(` call tokens (decompressAccounts(, onRevert() — the function actually being described.
_CALL_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def die(rc, msg):
    sys.stderr.write("score-match.py: " + msg + "\n")
    sys.exit(rc)


def technical_tokens(text):
    """Overlap tokens for the fallback: camelCase identifiers + call names, minus generic-DeFi stopwords."""
    toks = set()
    for m in _CAMEL_RE.findall(text):
        toks.add(m.lower())
    for m in _CALL_RE.findall(text):
        toks.add(m.lower())
    return {t for t in toks if t not in STOPWORDS}


def lead_location(lead):
    """(file_basename, function_name) from a lead. Prefer the structured `location = file:function:line`;
    fall back to the top-level `file` field for the basename when location has no usable path/function."""
    loc = (lead.get("location") or "").strip()
    parts = loc.split(":") if loc else []
    file_path = parts[0].strip() if parts and parts[0].strip() else ""
    function = ""
    if len(parts) >= 2:
        cand = parts[1].strip()
        # A 2-part `file:line` carries a number, not a function; `file:function[:line]` carries a name.
        if cand and not cand.isdigit():
            function = cand
    if not file_path:
        file_path = (lead.get("file") or "").strip()
    basename = os.path.basename(file_path).lower() if file_path else ""
    return basename, function


def lead_text(lead):
    """Free text of a lead, for the technical-token fallback (same fields the old oracle joined)."""
    return " ".join(
        str(lead.get(k, "") or "")
        for k in ("location", "file", "class", "exploit", "poc_sketch")
    )


def normalized_class(lead):
    """Uniform bug-class key for a lead (--per-lead only). verified_findings.json mixes `class=C3` and `C3`;
    strip a leading `class=` and surrounding whitespace, and map an empty/missing class to `unknown` so the
    fitness feeder aggregates one key per class regardless of the upstream formatting inconsistency."""
    raw = str(lead.get("class", "") or "").strip()
    if raw.startswith("class="):
        raw = raw[len("class="):].strip()
    return raw if raw else "unknown"


def lead_matches_row(basename, function, ltokens, signature, min_overlap):
    sig = signature.lower()
    file_ok = bool(basename) and basename in sig  # basename carries `.sol`, so this is inherently anchored
    if function:
        # PRIMARY (location) gate: file basename AND function name both present -> threshold-independent.
        if not file_ok:
            return False
        return re.search(r"\b" + re.escape(function.lower()) + r"\b", sig) is not None
    # FALLBACK: no parseable function. Require the file (when known) + a technical-token overlap floor.
    sig_tokens = technical_tokens(signature)
    overlap = len(ltokens & sig_tokens)
    if basename:
        return file_ok and overlap >= min_overlap
    # LAST RESORT: file also unknown -> stopword-filtered technical overlap alone.
    return overlap >= min_overlap


# ==============================================================================================================
# SEMANTIC MECHANISM JUDGE (#1829) — everything below is reached ONLY under --judge cache|cmd. The default
# --judge off path never enters here and never changes.
# ==============================================================================================================
JUDGE_MODES = ("off", "cache", "cmd")
VERDICT_PREFIX = "VERDICT|"


def lead_id(i):
    """Judge-facing id of the i-th lead in `resolved` order. verified_findings.json leads carry no stable id,
    but the input order IS deterministic for a given file, so `L<index>` is a stable request key component."""
    return "L" + str(i)


def judge_request(lid, lead, rows_chunk):
    """(canonical_request_json, sha256_key) for one lead judged against one batch of truth rows. The key is
    CONTENT-derived, so a recorded decision replays for the same lead+rows regardless of run order.

    CACHE-GENERATION HAZARD — READ BEFORE TOUCHING mech-judge.sh's PROMPT. The key covers `{lead, rows}` ONLY.
    The PROMPT is deliberately NOT part of it, and replay re-parses the recorded `raw_reply` rather than
    re-asking. So editing the prompt (or the `VERDICT|` grammar, or the decision rule) does NOT invalidate any
    recorded decision: old and new decisions keep colliding on the same key and one cache file silently mixes
    two DECISION GENERATIONS, with no field anywhere that says which is which. Any prompt change must
    therefore VERSION THE KEY FIRST — stamp a `judge_rev` (a sha256 of the prompt builder) on every newly
    recorded entry, report the distinct revisions found at replay time (pre-existing entries read
    `unversioned`), and offer a hard-fail switch for a mixed cache. Do not "just tweak the wording": the whole
    reproducibility claim of a judged recall number rests on this key."""
    req = {
        "lead": {
            "id": lid,
            "location": str(lead.get("location", "") or ""),
            "file": str(lead.get("file", "") or ""),
            "class": str(lead.get("class", "") or ""),
            "exploit": str(lead.get("exploit", "") or ""),
            "poc_sketch": str(lead.get("poc_sketch", "") or ""),
        },
        "rows": [{"sev_id": sev_id, "signature": signature} for sev_id, signature in rows_chunk],
    }
    text = json.dumps(req, sort_keys=True, separators=(",", ":"))
    return text, hashlib.sha256(text.encode("utf-8")).hexdigest()


def parse_verdicts(raw, lid, valid_sev_ids):
    """Parse a judge reply into (decisions, dropped).

    Grammar (one per line, anything else on the line ignored):
      VERDICT|<lead_id>|<sev_id>|MATCH|<confidence>|<reason>
      VERDICT|<lead_id>|NONE|NO-MATCH|<confidence>|<reason>
    A verdict about a DIFFERENT lead is ignored (never cross-credited). A MATCH naming a sev_id that is not in
    this request's rows is DROPPED and counted as an error — a hallucinated row id must never score a hit.
    An empty `decisions` list is the caller's JUDGE-ERROR signal; it is NEVER read as a silent NO-MATCH."""
    decisions = []
    dropped = 0
    for line in (raw or "").splitlines():
        line = line.strip()
        if not line.startswith(VERDICT_PREFIX):
            continue
        parts = line.split("|")
        if len(parts) < 5:
            continue
        line_lid = parts[1].strip()
        sev_id = parts[2].strip()
        decision = parts[3].strip().upper()
        reason = parts[5].strip() if len(parts) >= 6 else ""
        if line_lid != lid or decision not in ("MATCH", "NO-MATCH"):
            continue
        try:
            confidence = int(float(parts[4].strip()))
        except ValueError:
            continue
        if decision == "MATCH":
            if sev_id not in valid_sev_ids:
                dropped += 1
                continue
        else:
            sev_id = "NONE"
        decisions.append((sev_id, decision, confidence, reason))
    return decisions, dropped


def load_judge_cache(path):
    """key -> recorded entry, from a JSONL cache (last entry for a key wins). A missing/unreadable cache is an
    EMPTY cache: under --judge cache the first miss then dies, which is the intended loud failure."""
    cache = {}
    if not path:
        return cache
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if isinstance(entry, dict) and entry.get("key"):
                    cache[entry["key"]] = entry
    except OSError:
        pass
    return cache


def append_jsonl(path, entry):
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n")
    except OSError as e:
        die(3, "cannot append to " + path + ": " + str(e))


def invoke_judge(judge_cmd, request_text):
    """Run the judge driver with the request on stdin; return its stdout verbatim. A non-zero exit or an empty
    reply is NOT fatal here — it simply yields no parseable verdict, i.e. a JUDGE-ERROR upstream."""
    try:
        proc = subprocess.run([judge_cmd], input=request_text, capture_output=True, text=True)
    except OSError as e:
        die(3, "cannot run --judge-cmd " + str(judge_cmd) + ": " + str(e))
    return proc.stdout or ""


def run_judge(leads, rows, mode, judge_cmd, cache_path, log_path, batch, min_conf):
    """Judge every lead against every truth row, in batches.

    Returns (row_hit, lead_hit, calls, errors, gated_matches, gated_row_indices) — the last two are the #1841
    GATE accounting: how many otherwise-valid MATCH decisions `min_conf` dropped, and which truth rows they
    named. A hallucinated row id is NEVER counted here (it is already an error upstream), so `gated_matches`
    only ever reports decisions the judge made about real rows and the gate then discarded.

    The recorded RAW REPLY is authoritative on a cache hit (it is re-parsed by the same parser the live path
    uses), so `--judge cache` and `--judge cmd` over the same decisions produce byte-identical scorecards."""
    valid_sev_ids = {sev_id for sev_id, _sig in rows}
    row_index = {sev_id: ri for ri, (sev_id, _sig) in enumerate(rows)}
    cache = load_judge_cache(cache_path)
    row_hit = [False] * len(rows)
    lead_hit = [False] * len(leads)
    calls = 0
    errors = 0
    gated_matches = 0
    gated_row_indices = set()
    for li, lead in enumerate(leads):
        lid = lead_id(li)
        for start in range(0, len(rows), batch):
            text, key = judge_request(lid, lead, rows[start:start + batch])
            calls += 1
            entry = cache.get(key)
            if entry is None:
                if mode == "cache":
                    die(4, "--judge cache: no recorded decision for lead " + lid + " (request key " + key
                        + "); record it first with --judge cmd --judge-cache <file>")
                raw = invoke_judge(judge_cmd, text)
                decisions, dropped = parse_verdicts(raw, lid, valid_sev_ids)
                entry = {
                    "key": key,
                    "lead_id": lid,
                    "request": text,
                    "raw_reply": raw,
                    "decisions": [
                        {"sev_id": d[0], "decision": d[1], "confidence": d[2], "reason": d[3]} for d in decisions
                    ],
                }
                cache[key] = entry
                append_jsonl(cache_path, entry)
                append_jsonl(log_path, entry)
            else:
                decisions, dropped = parse_verdicts(entry.get("raw_reply", ""), lid, valid_sev_ids)
            # A dropped (hallucinated) row id is an error; so is a reply with nothing parseable at all. The
            # latter is the fail-closed rule this mode exists for: no verdict is never read as NO-MATCH.
            errors += dropped
            if not decisions:
                errors += 1
                continue
            for sev_id, decision, confidence, _reason in decisions:
                if decision != "MATCH":
                    continue
                ri = row_index.get(sev_id)
                if ri is None:
                    continue
                # #1841 GATE accounting, before the scoring decision: the judge said MATCH about a REAL row
                # and only the confidence gate stops it from scoring. Recording it here is what makes the
                # gate's cost visible in the scorecard instead of silent.
                if confidence < min_conf:
                    gated_matches += 1
                    gated_row_indices.add(ri)
                    continue
                row_hit[ri] = True
                lead_hit[li] = True
    return row_hit, lead_hit, calls, errors, gated_matches, gated_row_indices


# ==============================================================================================================
# GT EQUIVALENCE CLASSES (#1840) — reached ONLY under --gt-dupes. Without the flag nothing below runs and the
# scorecard is byte-identical to the pre-#1840 output in every --judge mode.
# ==============================================================================================================
GT_DUPES_TAG = "DUP"


def load_gt_dupes(path, min_conf):
    """Parse a gt-dupes.tsv artifact into (classes, named_sev_ids).

    Grammar: `#` comment / provenance lines and blank lines are skipped; every other line must be
      DUP \t <sev_a> \t <sev_b> \t <confidence 0-100> [\t <reason>]
    Pairs at or above `min_conf` are unioned (union-find) into equivalence CLASSES; a pair BELOW the bar is
    still parsed and its ids still validated by the caller, it simply does not merge — so one archived
    artifact re-derives the number at any threshold. `classes` holds only groups of >= 2 rows, ordered by
    first appearance in the file. A malformed record is a hard error, never a silent skip: half-applying an
    artifact this scorer does not understand is exactly how a mis-credit would slip through."""
    parent = {}
    order = []

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def add(x):
        if x not in parent:
            parent[x] = x
            order.append(x)

    try:
        fh = open(path, encoding="utf-8", errors="ignore")
    except OSError as e:
        die(3, "cannot read --gt-dupes " + path + ": " + str(e))
    with fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.split("\t")
            where = path + ":" + str(lineno) + ": "
            if cols[0] != GT_DUPES_TAG:
                die(3, where + "unknown record tag '" + cols[0] + "' (expected " + GT_DUPES_TAG + ")")
            if len(cols) < 4:
                die(3, where + GT_DUPES_TAG + " needs <sev_a> <sev_b> <confidence> [reason], TAB-separated")
            sev_a, sev_b = cols[1].strip(), cols[2].strip()
            if not sev_a or not sev_b:
                die(3, where + "empty sev_id in a " + GT_DUPES_TAG + " pair")
            if sev_a == sev_b:
                die(3, where + "self-pair '" + sev_a + "' (a row is not a duplicate of itself)")
            try:
                confidence = int(float(cols[3].strip()))
            except ValueError:
                die(3, where + "confidence must be a number, got '" + cols[3].strip() + "'")
            add(sev_a)
            add(sev_b)
            if confidence < min_conf:
                continue
            root_a, root_b = find(sev_a), find(sev_b)
            if root_a != root_b:
                parent[root_b] = root_a

    groups = {}
    for sev_id in order:
        groups.setdefault(find(sev_id), []).append(sev_id)
    classes = [members for members in groups.values() if len(members) >= 2]
    return classes, set(order)


def expand_row_hits(row_hit, classes, rows, max_class):
    """Credit the equivalence CLASS instead of the single row a matcher happened to name.

    Returns `(expanded_row_hit, expansions)` where `expansions` is the list of
    `(credited_sev_id, directly_matched_sev_id)` pairs in truth-row order. Expansion reads the DIRECT hits
    only, never its own output, so credit cannot cascade beyond one class. A class larger than `max_class` is
    left entirely alone (fail-closed against a runaway merge) with a warning on stderr."""
    index = {sev_id: ri for ri, (sev_id, _sig) in enumerate(rows)}
    direct = list(row_hit)
    expanded = list(row_hit)
    expansions = []
    for members in classes:
        if len(members) > max_class:
            sys.stderr.write("score-match.py: --gt-dupes: equivalence class of " + str(len(members))
                             + " rows (" + ", ".join(members) + ") exceeds --gt-dupes-max-class "
                             + str(max_class) + "; NOT expanded\n")
            continue
        indices = sorted(index[m] for m in members)
        source = next((ri for ri in indices if direct[ri]), None)
        if source is None:
            continue
        for ri in indices:
            if not direct[ri]:
                expanded[ri] = True
                expansions.append((rows[ri][0], rows[source][0]))
    expansions.sort(key=lambda pair: index[pair[0]])
    return expanded, expansions


def main(argv):
    truth_path = None
    verified_path = None
    min_overlap = 2
    per_lead = False
    judge_mode = "off"
    judge_cmd = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mech-judge.sh")
    judge_cache = ""
    judge_log = ""
    judge_batch = 12
    # #1841: BELOW the observed 62-68 location-divergence hedge band, not through it — an outlier floor, not a
    # recall knob. Keep this in sync with JUDGE_MINCONF_DEFAULT in run-corpus-bench.sh + generation-recall.sh
    # (demo-mech-judge.sh assertion (s) fails on divergence).
    judge_min_conf = 60
    judge_max_error_rate = 20
    gt_dupes = ""
    gt_dupes_min_conf = 85
    gt_dupes_max_class = 3

    def int_arg(flag, raw):
        try:
            return int(raw)
        except ValueError:
            die(2, flag + " must be an integer")

    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--min-overlap":
            if i + 1 >= len(argv):
                die(2, "--min-overlap requires a value")
            try:
                min_overlap = int(argv[i + 1])
            except ValueError:
                die(2, "--min-overlap must be an integer")
            i += 2
        elif a == "--per-lead":
            per_lead = True
            i += 1
        elif a in ("--judge", "--judge-cmd", "--judge-cache", "--judge-log",
                   "--judge-batch", "--judge-min-confidence", "--judge-max-error-rate"):
            if i + 1 >= len(argv):
                die(2, a + " requires a value")
            val = argv[i + 1]
            if a == "--judge":
                if val not in JUDGE_MODES:
                    die(2, "--judge must be one of: " + "|".join(JUDGE_MODES))
                judge_mode = val
            elif a == "--judge-cmd":
                judge_cmd = val
            elif a == "--judge-cache":
                judge_cache = val
            elif a == "--judge-log":
                judge_log = val
            elif a == "--judge-batch":
                judge_batch = int_arg(a, val)
            elif a == "--judge-min-confidence":
                judge_min_conf = int_arg(a, val)
            else:
                judge_max_error_rate = int_arg(a, val)
            i += 2
        elif a in ("--gt-dupes", "--gt-dupes-min-confidence", "--gt-dupes-max-class"):
            if i + 1 >= len(argv):
                die(2, a + " requires a value")
            val = argv[i + 1]
            if a == "--gt-dupes":
                gt_dupes = val
            elif a == "--gt-dupes-min-confidence":
                gt_dupes_min_conf = int_arg(a, val)
            else:
                gt_dupes_max_class = int_arg(a, val)
            i += 2
        elif a in ("-h", "--help"):
            sys.stdout.write(__doc__ or "")
            return 0
        elif a.startswith("-"):
            die(2, "unknown arg: " + a)
        elif truth_path is None:
            truth_path = a
            i += 1
        elif verified_path is None:
            verified_path = a
            i += 1
        else:
            die(2, "unexpected extra arg: " + a)
    if truth_path is None or verified_path is None:
        die(2, "usage: score-match.py <truth.tsv> <verified_findings.json> [--min-overlap N]")
    if judge_batch < 1:
        die(2, "--judge-batch must be >= 1")
    if judge_mode == "cache" and not judge_cache:
        die(2, "--judge cache requires --judge-cache <file.jsonl> (the recorded decisions to replay)")
    if gt_dupes_max_class < 2:
        die(2, "--gt-dupes-max-class must be >= 2 (the smallest equivalence class is a pair); omit "
               "--gt-dupes to score without any class expansion")

    try:
        rows = []
        with open(truth_path, encoding="utf-8", errors="ignore") as fh:
            for lineno, line in enumerate(fh, 1):
                line = line.rstrip("\n")
                if not line:
                    continue
                cols = line.split("\t")
                if len(cols) < 5 or not cols[0]:
                    continue
                # #1845: NONE is the sentinel parse_verdicts() forcibly writes into a NO-MATCH decision, so a
                # ground-truth row carrying that literal id would COLLIDE with every rejection the judge makes.
                # extract-gt.sh can only ever emit H-N / M-N ids, so this cannot happen on real corpus data —
                # but nothing here enforced it, which left the guarantee resting on a convention plus the
                # `decision != "MATCH"` guard in the scoring loop rather than on the data model. Fail closed:
                # a hand-authored fixture must not be able to make a NO-MATCH credit a row.
                if cols[0] == "NONE":
                    die(3, "truth.tsv row %d uses the reserved sev_id 'NONE' — that literal is the NO-MATCH "
                           "sentinel in the judge reply grammar and can never name a ground-truth row" % lineno)
                rows.append((cols[0], cols[4]))  # (sev_id, signature)
    except OSError as e:
        die(3, "cannot read truth.tsv: " + str(e))

    # #1840: load + validate the equivalence artifact BEFORE any judging happens, so a stale one costs zero
    # LLM calls. A pair naming a sev_id this truth.tsv does not contain is a hard error: such an artifact is
    # either stale or from another contest, and silently skipping it would mis-credit the headline.
    gt_dupe_classes = []
    if gt_dupes:
        gt_dupe_classes, gt_dupe_named = load_gt_dupes(gt_dupes, gt_dupes_min_conf)
        known_sev_ids = {sev_id for sev_id, _sig in rows}
        unknown = sorted(s for s in gt_dupe_named if s not in known_sev_ids)
        if unknown:
            die(3, "--gt-dupes " + gt_dupes + " names sev_id(s) absent from " + truth_path + ": "
                + ", ".join(unknown) + " — the artifact is stale or from another contest; rebuild it with "
                + "gt-dupes.sh")

    try:
        with open(verified_path, encoding="utf-8", errors="ignore") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as e:
        die(3, "cannot read verified_findings.json: " + str(e))

    leads = data.get("verified", []) if isinstance(data, dict) else []
    # Pre-resolve each lead once (location + fallback tokens) so the O(rows x leads) loop stays cheap.
    resolved = []
    lead_objs = []   # parallel to `resolved`; the raw lead dicts (judge mode only)
    lead_class = []  # parallel to `resolved`; normalized bug-class key per lead (--per-lead only)
    for lead in leads:
        if not isinstance(lead, dict):
            continue
        basename, function = lead_location(lead)
        ltokens = technical_tokens(lead_text(lead)) if not function else set()
        resolved.append((basename, function, ltokens))
        lead_objs.append(lead)
        lead_class.append(normalized_class(lead))

    matched_leads = 0
    judge_calls = 0
    judge_errors = 0
    judge_gated_matches = 0
    judge_gated_rows = set()
    if judge_mode == "off":
        # FROZEN #1697 location-first path — untouched, and the only path that calls lead_matches_row().
        lead_hit = [False] * len(resolved)
        row_hit = [False] * len(rows)
        for li, (basename, function, ltokens) in enumerate(resolved):
            for ri, (_sev_id, signature) in enumerate(rows):
                if lead_matches_row(basename, function, ltokens, signature, min_overlap):
                    row_hit[ri] = True
                    lead_hit[li] = True
    else:
        # #1829 judge mode: the judge is AUTHORITATIVE — no token fallback, no silent NO-MATCH.
        row_hit, lead_hit, judge_calls, judge_errors, judge_gated_matches, judge_gated_rows = run_judge(
            lead_objs, rows, judge_mode, judge_cmd, judge_cache, judge_log, judge_batch, judge_min_conf)
        if resolved and (judge_errors * 100.0) / len(resolved) > judge_max_error_rate:
            die(4, "judge error rate " + str(judge_errors) + "/" + str(len(resolved)) + " leads exceeds "
                + "--judge-max-error-rate " + str(judge_max_error_rate) + "%; refusing to report a recall "
                + "number from a degraded judge (check --judge-log for the raw replies)")
    matched_leads = sum(1 for h in lead_hit if h)

    # #1840 GT-equivalence crediting, applied to BOTH matchers (equivalence is a property of the ground truth,
    # not of the matcher). It expands `row_hit` ONLY — `lead_hit`/`matched_leads` are already final above, so
    # one lead can never become N matched leads.
    gt_expansions = []
    if gt_dupes:
        row_hit, gt_expansions = expand_row_hits(row_hit, gt_dupe_classes, rows, gt_dupes_max_class)

    out = []
    for ri, (sev_id, _signature) in enumerate(rows):
        out.append(f"{sev_id}\t{'HIT' if row_hit[ri] else 'MISS'}")
    out.append(f"LEADS\t{len(resolved)}\t{matched_leads}")
    # ADDITIVE judge trailer (#1829): present ONLY in judge mode, so the default output stays byte-identical.
    # `calls` counts every lead x row-batch judging request (cache hits included, so a replay reports the same
    # number as the live run); `errors` counts JUDGE-ERRORs (unparseable reply / hallucinated row id).
    if judge_mode != "off":
        out.append(f"JUDGE\t{judge_calls}\t{judge_errors}")
        # ADDITIVE gate trailer (#1841), judge-mode-only exactly like JUDGE, and emitted AFTER the #1840
        # expansion so `gated_rows` counts only rows that are still MISS in the FINAL scorecard — a row the
        # gate dropped but an equivalence class credited anyway cost nothing. `gated_matches` is the raw count
        # of dropped MATCH decisions (several can name the same row). Nonzero `gated_rows` means the headline
        # is gate-sensitive: re-derive it at another threshold from the same cache before publishing.
        gated_rows = sum(1 for ri in judge_gated_rows if not row_hit[ri])
        out.append(f"GATE\t{judge_min_conf}\t{judge_gated_matches}\t{gated_rows}")
    # ADDITIVE GT-equivalence trailers (#1840): present ONLY under --gt-dupes, so every pinned scorecard
    # without the flag stays byte-identical. `DUP` reports the loaded class count and how many rows were
    # credited THROUGH a class rather than directly — `hits - expanded_hits` is exactly the pre-#1840 number
    # from the same replay — and one `DUPHIT` line per expanded row attributes it to the row actually matched.
    if gt_dupes:
        out.append(f"DUP\t{len(gt_dupe_classes)}\t{len(gt_expansions)}")
        for credited_sev_id, matched_sev_id in gt_expansions:
            out.append(f"DUPHIT\t{credited_sev_id}\t{matched_sev_id}")
    # ADDITIVE per-lead real-bug precision material (issue #1711): only appended under --per-lead so the
    # default output stays byte-identical for run-corpus-bench.sh --self-test. A lead is a HIT when it matched
    # a real GT row (lead_hit[li]); MISS = unmatched noise. Class is the normalized key.
    if per_lead:
        for li in range(len(resolved)):
            out.append(f"LEAD\t{lead_class[li]}\t{'HIT' if lead_hit[li] else 'MISS'}")
    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
