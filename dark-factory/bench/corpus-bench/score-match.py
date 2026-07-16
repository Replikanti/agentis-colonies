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
# This is a BENCH scorer only. It does NOT touch novelty-gate.sh (the LIVE hunting-pipeline boundary/novelty
# gate, frozen for the #1698/#1699 re-measurement) or extract-gt.sh (truth.tsv schema unchanged).
#
# Usage: score-match.py <truth.tsv> <verified_findings.json> [--min-overlap N] [--per-lead]
#   truth.tsv           extract-gt.sh output: sev_id \t severity \t rarity \t title \t signature (per row).
#   verified_findings.json  run-zone-hunt.sh verify output: {"verified": [ {location, file, ...}, ... ]}.
#   --min-overlap N     ONLY governs the location-unavailable fallback (a lead with no parseable function).
#                       Location-resolvable leads are threshold-INDEPENDENT; N never affects them. Default 2.
#   --per-lead          ADDITIVE (default output byte-identical without it): after the normal output, append
#                       one `LEAD\t<class>\t<HIT|MISS>` line per verified lead — HIT when that lead matched a
#                       real GT row, MISS otherwise. This is per-lead REAL-BUG PRECISION material for the
#                       bench->knowledge fitness feeder (bench-to-knowledge.sh, issue #1711): a class's HITs
#                       are its leads that hit ground truth, its MISSes are unmatched noise. The lead's `class`
#                       field is NORMALIZED (a leading `class=` prefix is stripped; empty/missing -> `unknown`)
#                       so the `class=C3` vs `C3` inconsistency in verified_findings.json collapses to one key.
# Output (stdout): one `<sev_id>\t<HIT|MISS>` line per truth row (input order), then a trailer line
#   `LEADS\t<verified_n>\t<matched_leads>` (verified lead count; leads matching >=1 truth row). With
#   `--per-lead`, one `LEAD\t<class>\t<HIT|MISS>` line per verified lead follows the trailer.
# Exit: 0 always on a well-formed run; 2 bad args; 3 unreadable/malformed input.
import sys
import os
import re
import json

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


def main(argv):
    truth_path = None
    verified_path = None
    min_overlap = 2
    per_lead = False
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

    try:
        rows = []
        with open(truth_path, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line:
                    continue
                cols = line.split("\t")
                if len(cols) < 5 or not cols[0]:
                    continue
                rows.append((cols[0], cols[4]))  # (sev_id, signature)
    except OSError as e:
        die(3, "cannot read truth.tsv: " + str(e))

    try:
        with open(verified_path, encoding="utf-8", errors="ignore") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as e:
        die(3, "cannot read verified_findings.json: " + str(e))

    leads = data.get("verified", []) if isinstance(data, dict) else []
    # Pre-resolve each lead once (location + fallback tokens) so the O(rows x leads) loop stays cheap.
    resolved = []
    lead_class = []  # parallel to `resolved`; normalized bug-class key per lead (--per-lead only)
    for lead in leads:
        if not isinstance(lead, dict):
            continue
        basename, function = lead_location(lead)
        ltokens = technical_tokens(lead_text(lead)) if not function else set()
        resolved.append((basename, function, ltokens))
        lead_class.append(normalized_class(lead))

    matched_leads = 0
    lead_hit = [False] * len(resolved)
    row_hit = [False] * len(rows)
    for li, (basename, function, ltokens) in enumerate(resolved):
        for ri, (_sev_id, signature) in enumerate(rows):
            if lead_matches_row(basename, function, ltokens, signature, min_overlap):
                row_hit[ri] = True
                lead_hit[li] = True
    matched_leads = sum(1 for h in lead_hit if h)

    out = []
    for ri, (sev_id, _signature) in enumerate(rows):
        out.append(f"{sev_id}\t{'HIT' if row_hit[ri] else 'MISS'}")
    out.append(f"LEADS\t{len(resolved)}\t{matched_leads}")
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
