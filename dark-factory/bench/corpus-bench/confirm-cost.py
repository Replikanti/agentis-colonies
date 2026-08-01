#!/usr/bin/env python3
# confirm-cost.py — issue #1867. The corpus bench reports recall but not COST: what a hunt spent to get
# there, and at what rate its candidates survived the refute gate. Both numbers already exist, split across
# two artifacts a `--hunt` run already produces:
#   * `coverage/zone-coverage.json` (#1830) — per-zone `cells` (cells spent) and `candidates` (generated).
#   * `verify/verified_findings.json` (M4) — per-candidate `subsystem` on every `verified[]` row, plus the
#     run's own trustworthy `totals.candidates` / `totals.verified`.
# This script is PURE AGGREGATION over those two files: no LLM/network calls, no new judging.
#
# THE JOIN. `run-discovery.sh` is invoked per zone with `--only "$ZNAME"` and only emits a cell when
# `SUBSYS == ONLY` exactly, and `verify-findings.sh` copies that same `subsystem` string verbatim into every
# `verified[]` row — so `zones[].name` and a verified row's `subsystem` are byte-identical by construction.
# Grouping `verified[]` by `subsystem` and joining on `zones[].name` therefore reproduces a per-zone confirmed
# count with no re-parsing of `discovery-results.merged.json` and no re-implementation of
# `verify-findings.sh`'s manifest-flattening logic. Verified against the preserved #1831 exit-criterion
# artifacts (plaza/crestal/notional): this join reproduces 1.4 / 1.5 / 17.8 cells-per-confirmed and the
# notional per-zone breakdown (`src_withdraws` 5/15, `src` 0/22) exactly.
#
# Usage: confirm-cost.py <zone-coverage.json> <verified_findings.json>
# Output (stdout): one line per zone (in zone-coverage.json's stored order), then one RUN trailer:
#   ZONE\t<id>\t<cells>\t<candidates>\t<confirmed>\t<confirm_rate_pct|n/a>\t<cells_per_confirmed|n/a>
#   RUN\t<total_cells>\t<total_candidates>\t<total_confirmed>\t<rate_pct>\t<cells_per_confirmed>
# `confirm_rate_pct` and `cells_per_confirmed` are one-decimal numbers with no unit suffix (e.g. `63.6`, not
# `63.6 %`); either is `n/a` on a zero denominator — NEVER a ZeroDivisionError and never a fabricated number.
# `RUN`'s candidate/confirmed counts come straight from verified_findings.json's own `totals.candidates` /
# `totals.verified` (the trustworthy run-level truth), NOT a sum of the per-zone confirmed counts — a
# `subsystem` that does not match any zone name (e.g. a `source=invariant-hunt` deep-hunt row, which carries
# no zone-scoped subsystem) would otherwise silently undercount the per-zone sum without ever affecting the
# run-level headline.
#
# Fail-loud, not fail-silent: if the per-zone confirmed sum disagrees with `totals.verified`, a WARN line
# naming the discrepancy goes to stderr. This is a warning, not a hard failure — the RUN trailer already uses
# the trustworthy totals, so a stale/mismatched subsystem costs a per-zone breakdown row, not the headline.
#
# Exit: 0 well-formed run; 2 bad args; 3 unreadable/malformed input.
import sys
import json


def die(rc, msg):
    sys.stderr.write("confirm-cost.py: " + msg + "\n")
    sys.exit(rc)


def load_json(path, what):
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            return json.load(fh)
    except OSError as e:
        die(3, "cannot read " + what + " " + path + ": " + str(e))
    except ValueError as e:
        die(3, what + " " + path + " is not valid JSON: " + str(e))


def fmt_ratio(numerator, denominator):
    """One-decimal string, or 'n/a' on a zero denominator — never a ZeroDivisionError."""
    if not denominator:
        return "n/a"
    return "%.1f" % (numerator / float(denominator))


def main(argv):
    if len(argv) != 3:
        die(2, "usage: confirm-cost.py <zone-coverage.json> <verified_findings.json>")
    coverage_path, verified_path = argv[1], argv[2]

    coverage = load_json(coverage_path, "zone-coverage.json")
    verified_data = load_json(verified_path, "verified_findings.json")

    zones = coverage.get("zones", []) if isinstance(coverage, dict) else None
    if not isinstance(zones, list):
        die(3, coverage_path + ": missing/malformed top-level 'zones' array")

    verified = verified_data.get("verified", []) if isinstance(verified_data, dict) else None
    if not isinstance(verified, list):
        die(3, verified_path + ": missing/malformed top-level 'verified' array")
    totals = verified_data.get("totals", {}) if isinstance(verified_data, dict) else {}
    if not isinstance(totals, dict):
        totals = {}

    # Group verified[] by subsystem — the join key, byte-identical to a zone's `name` by construction (see
    # header). A missing/blank subsystem groups under "" and simply never matches a real zone name.
    confirmed_by_subsystem = {}
    for row in verified:
        if not isinstance(row, dict):
            continue
        subsystem = str(row.get("subsystem", "") or "")
        confirmed_by_subsystem[subsystem] = confirmed_by_subsystem.get(subsystem, 0) + 1

    out_lines = []
    total_cells = 0
    per_zone_confirmed_sum = 0
    for zone in zones:
        if not isinstance(zone, dict):
            continue
        zid = str(zone.get("id", "") or "")
        name = str(zone.get("name", "") or "")
        cells = int(zone.get("cells", 0) or 0)
        candidates = int(zone.get("candidates", 0) or 0)
        confirmed = confirmed_by_subsystem.get(name, 0)
        total_cells += cells
        per_zone_confirmed_sum += confirmed
        rate = fmt_ratio(100.0 * confirmed, candidates)
        cpc = fmt_ratio(cells, confirmed)
        out_lines.append("ZONE\t%s\t%d\t%d\t%d\t%s\t%s" % (zid, cells, candidates, confirmed, rate, cpc))

    total_candidates = int(totals.get("candidates", 0) or 0)
    total_confirmed = int(totals.get("verified", 0) or 0)

    if per_zone_confirmed_sum != total_confirmed:
        sys.stderr.write(
            "confirm-cost.py: WARN: per-zone confirmed sum (%d) != totals.verified (%d) in %s — %d verified "
            "row(s) carry a subsystem that does not match any zone name in %s (e.g. a deep-hunt row with no "
            "zone-scoped subsystem); the RUN trailer below still uses totals.verified, not this sum\n"
            % (per_zone_confirmed_sum, total_confirmed, verified_path,
               total_confirmed - per_zone_confirmed_sum, coverage_path)
        )

    run_rate = fmt_ratio(100.0 * total_confirmed, total_candidates)
    run_cpc = fmt_ratio(total_cells, total_confirmed)
    out_lines.append("RUN\t%d\t%d\t%d\t%s\t%s" % (total_cells, total_candidates, total_confirmed, run_rate, run_cpc))

    sys.stdout.write("\n".join(out_lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
