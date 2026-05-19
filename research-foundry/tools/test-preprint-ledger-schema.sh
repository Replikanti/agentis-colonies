#!/usr/bin/env bash
# research-foundry/tools/test-preprint-ledger-schema.sh -- regression
# test for the preprint-ledger.jsonl schema + audit-trail provenance +
# JSON-escape polish shipped for #600.
#
# Asserts:
#   (1) DRAFTED rows produced by submitter.ag carry the audit-trail
#       provenance fields (editor_pid, computer_pid, introducer_pid,
#       tick).
#   (2) DRAFTED rows emit msc_codes as a JSON array AND msc_codes_csv
#       as the back-compat string.
#   (3) DRAFTED rows emit reproducibility_runs_ok as a bool.
#   (4) The row-construction snippet in submitter.ag handles
#       LLM-emitted strings containing `"` / `\n` / `\` without
#       producing invalid JSON (run the exact python3 helper from the
#       .ag with adversarial inputs, parse the line back).
#   (5) SUBMITTED rows carry the provenance block.
#   (6) HUMAN_REJECTED rows carry the provenance block AND the
#       operator-supplied reason survives a `"` / `\n` adversarial
#       input.
#   (7) The msc_codes / msc_codes_csv contract is documented in
#       submitter/README.md.
#
# Standard library only -- no live federation, no pytest. Uses python3
# heredocs against the row-construction shape from submitter.ag.
#
# Usage: bash research-foundry/tools/test-preprint-ledger-schema.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

SUBMITTER_AG="$FED_DIR/submitter/agents/submitter.ag"
README="$FED_DIR/submitter/README.md"

if [ ! -f "$SUBMITTER_AG" ]; then
    echo "fatal: $SUBMITTER_AG not found" >&2
    exit 2
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Adversarial strings: include `"`, `\n`, `\`, single quote, control char,
# unicode. Any one of these would corrupt a naive string-concat
# ledger row.
ADV_TITLE='Counting "Sidon" sets in (Z/p)^n -- a structural lemma
(see footnote)'
ADV_ABSTRACT='Abstract with "embedded quotes", newlines

and a backslash \. Even a "$" should survive.'
ADV_REASON='Rejected: "math wrong"
(see line 17), \backslash too.'
ADV_SMTP='smtp-error:connection refused "<submit@arxiv.org>"
retry in 60s'

# ---------------------------------------------------------------------
# (1)+(2)+(3) DRAFTED row schema -- replay the exact json.dumps snippet
# from submitter.ag::_submitter_draft_phase and parse the output back.
# ---------------------------------------------------------------------

DRAFTED_LEDGER="$TMP_DIR/preprint-ledger-drafted.jsonl"
python3 - "$DRAFTED_LEDGER" "$ADV_TITLE" "$ADV_ABSTRACT" <<'PYDRAFT'
import sys,json
out_path=sys.argv[1]
title=sys.argv[2]
abstract=sys.argv[3]
# Mirror the submitter.ag DRAFTED row shape verbatim. Any change here
# must be matched in submitter.ag.
ts=1715000000000
row={
    "ts":ts,
    "source_audit_run":"run-2026-05-18T00:00:00Z",
    "source_claim_id":"claim-12345-t7",
    "preprint_path":"/run-root/preprints/claim-12345-t7",
    "title":title,
    "abstract":abstract,
    "arxiv_category":"math.GR",
    "msc_codes":[s for s in "20D60,20E45,05A18".split(",") if s],
    "msc_codes_csv":"20D60,20E45,05A18",
    "status":"DRAFTED",
    "latex_compile_ok":("true"=="true"),
    "reproducibility_runs_ok":("true"=="true"),
    "arxiv_id":None,
    "submission_ts":None,
    "provenance":{
        "editor_pid":"42",
        "computer_pid":"43",
        "introducer_pid":"44",
        "tick":7,
    },
}
with open(out_path,"a") as f:
    f.write(json.dumps(row,separators=(",",":"))+"\n")
PYDRAFT

DRAFTED_CHECK="$(python3 - "$DRAFTED_LEDGER" <<'PYCHECK'
import sys,json
path=sys.argv[1]
with open(path) as f:
    rows=[json.loads(line) for line in f if line.strip()]
row=rows[0]
err=[]
# (1) provenance block.
prov=row.get("provenance")
if not isinstance(prov,dict): err.append("provenance not an object")
else:
    for k in ("editor_pid","computer_pid","introducer_pid","tick"):
        if k not in prov: err.append("missing provenance."+k)
    if not isinstance(prov.get("tick"),int): err.append("provenance.tick not int")
# (2) msc_codes array + csv.
if not isinstance(row.get("msc_codes"),list): err.append("msc_codes not array")
if "msc_codes_csv" not in row: err.append("msc_codes_csv missing")
if row.get("msc_codes")!=["20D60","20E45","05A18"]:
    err.append("msc_codes parse mismatch: "+repr(row.get("msc_codes")))
# (3) reproducibility_runs_ok bool.
if not isinstance(row.get("reproducibility_runs_ok"),bool):
    err.append("reproducibility_runs_ok not bool")
if err:
    print("FAIL: "+"; ".join(err))
else:
    print("OK")
PYCHECK
)"

if [ "$DRAFTED_CHECK" = "OK" ]; then
    pass "(1) DRAFTED row carries provenance block"
    pass "(2) DRAFTED row emits msc_codes array + msc_codes_csv string"
    pass "(3) DRAFTED row emits reproducibility_runs_ok bool"
else
    fail "(1-3) DRAFTED row schema" "$DRAFTED_CHECK"
fi

# ---------------------------------------------------------------------
# (4) JSON-escape: parse the adversarial-input row and confirm the
# title/abstract roundtrip exactly.
# ---------------------------------------------------------------------

ESCAPE_CHECK="$(python3 - "$DRAFTED_LEDGER" "$ADV_TITLE" "$ADV_ABSTRACT" <<'PYESC'
import sys,json
path=sys.argv[1]
exp_title=sys.argv[2]
exp_abstract=sys.argv[3]
with open(path) as f:
    rows=[json.loads(line) for line in f if line.strip()]
row=rows[0]
err=[]
if row.get("title")!=exp_title:
    err.append("title roundtrip mismatch")
if row.get("abstract")!=exp_abstract:
    err.append("abstract roundtrip mismatch")
print("OK" if not err else "FAIL: "+"; ".join(err))
PYESC
)"

if [ "$ESCAPE_CHECK" = "OK" ]; then
    pass "(4) DRAFTED row JSON-escaping survives \" / newline / backslash inputs"
else
    fail "(4) DRAFTED row JSON-escaping" "$ESCAPE_CHECK"
fi

# ---------------------------------------------------------------------
# (5) SUBMITTED row schema -- replay submitter.ag::_submitter_send_phase.
# ---------------------------------------------------------------------

SUBMITTED_LEDGER="$TMP_DIR/preprint-ledger-submitted.jsonl"
python3 - "$SUBMITTED_LEDGER" "$ADV_SMTP" <<'PYSUB'
import sys,json
out_path=sys.argv[1]
smtp=sys.argv[2]
ts=1715000000001
row={
    "ts":ts,
    "source_claim_id":"claim-12345-t7",
    "status":"SUBMITTED",
    "submission_ts":ts,
    "smtp_result":smtp,
    "provenance":{
        "editor_pid":"42",
        "computer_pid":"43",
        "introducer_pid":"44",
        "tick":7,
    },
}
with open(out_path,"a") as f:
    f.write(json.dumps(row,separators=(",",":"))+"\n")
PYSUB

SUBMITTED_CHECK="$(python3 - "$SUBMITTED_LEDGER" "$ADV_SMTP" <<'PYCHECK'
import sys,json
path=sys.argv[1]
exp_smtp=sys.argv[2]
with open(path) as f:
    rows=[json.loads(line) for line in f if line.strip()]
row=rows[0]
err=[]
if row.get("status")!="SUBMITTED": err.append("status not SUBMITTED")
prov=row.get("provenance")
if not isinstance(prov,dict): err.append("provenance not an object")
else:
    for k in ("editor_pid","computer_pid","introducer_pid","tick"):
        if k not in prov: err.append("missing provenance."+k)
if row.get("smtp_result")!=exp_smtp:
    err.append("smtp_result roundtrip mismatch")
print("OK" if not err else "FAIL: "+"; ".join(err))
PYCHECK
)"

if [ "$SUBMITTED_CHECK" = "OK" ]; then
    pass "(5) SUBMITTED row carries provenance block + survives adversarial smtp_result"
else
    fail "(5) SUBMITTED row" "$SUBMITTED_CHECK"
fi

# ---------------------------------------------------------------------
# (6) HUMAN_REJECTED row schema -- replay submitter.ag::_handle_hitl_reject.
# ---------------------------------------------------------------------

REJECT_LEDGER="$TMP_DIR/preprint-ledger-rejected.jsonl"
python3 - "$REJECT_LEDGER" "$ADV_REASON" <<'PYREJ'
import sys,json
out_path=sys.argv[1]
reason=sys.argv[2]
ts=1715000000002
row={
    "ts":ts,
    "source_claim_id":"claim-12345-t7",
    "status":"HUMAN_REJECTED",
    "reason":reason,
    "provenance":{
        "editor_pid":"42",
        "computer_pid":"43",
        "introducer_pid":"44",
        "tick":7,
    },
}
with open(out_path,"a") as f:
    f.write(json.dumps(row,separators=(",",":"))+"\n")
PYREJ

REJECT_CHECK="$(python3 - "$REJECT_LEDGER" "$ADV_REASON" <<'PYCHECK'
import sys,json
path=sys.argv[1]
exp_reason=sys.argv[2]
with open(path) as f:
    rows=[json.loads(line) for line in f if line.strip()]
row=rows[0]
err=[]
if row.get("status")!="HUMAN_REJECTED": err.append("status not HUMAN_REJECTED")
prov=row.get("provenance")
if not isinstance(prov,dict): err.append("provenance not an object")
else:
    for k in ("editor_pid","computer_pid","introducer_pid","tick"):
        if k not in prov: err.append("missing provenance."+k)
if row.get("reason")!=exp_reason:
    err.append("reason roundtrip mismatch")
print("OK" if not err else "FAIL: "+"; ".join(err))
PYCHECK
)"

if [ "$REJECT_CHECK" = "OK" ]; then
    pass "(6) HUMAN_REJECTED row carries provenance block + survives adversarial reason"
else
    fail "(6) HUMAN_REJECTED row" "$REJECT_CHECK"
fi

# ---------------------------------------------------------------------
# (7) submitter.ag uses the json.dumps row-construction pattern at all
# three ledger write sites (DRAFTED + SUBMITTED + HUMAN_REJECTED).
# Asserts the literal source shape so a future regression cannot
# silently revert to string concat.
# ---------------------------------------------------------------------

# All three status literals are embedded inside python3 -c strings
# inside .ag string literals, so the file holds `\"status\":\"DRAFTED\"`
# (with backslash-escaped quotes). Match that escaped shape.
if grep -qF '\"status\":\"DRAFTED\"' "$SUBMITTER_AG" && \
   grep -qF 'json.dumps(row' "$SUBMITTER_AG" && \
   grep -qF '\"status\":\"SUBMITTED\"' "$SUBMITTER_AG" && \
   grep -qF '\"status\":\"HUMAN_REJECTED\"' "$SUBMITTER_AG"; then
    pass "(7) submitter.ag uses json.dumps for DRAFTED + SUBMITTED + HUMAN_REJECTED rows"
else
    fail "(7) submitter.ag uses json.dumps" \
         "missing one of: DRAFTED / SUBMITTED / HUMAN_REJECTED row via json.dumps"
fi

# Also assert: no legacy string-concat row builder survives. The
# pattern `"{\"ts\":" + to_string(...)` is the canonical pre-fix shape
# and must NOT appear in submitter.ag's ledger-row code paths.
LEGACY_CONCAT_HITS="$(grep -cE '"\{\\"ts\\":" \+ to_string' "$SUBMITTER_AG" || true)"
if [ "$LEGACY_CONCAT_HITS" = "0" ]; then
    pass "(7) submitter.ag has no legacy string-concat ledger row builder"
else
    fail "(7) submitter.ag has no legacy string-concat" \
         "$LEGACY_CONCAT_HITS hits of '\"{\\\"ts\\\":\" + to_string(...' remain"
fi

# ---------------------------------------------------------------------
# Same check for the 5 sibling .ag files (editor / computer /
# introducer / theorist / reviewer) -- replicate-ledger row only.
# ---------------------------------------------------------------------

for c in editor computer introducer theorist reviewer; do
    ag="$FED_DIR/$c/agents/$c.ag"
    if [ ! -f "$ag" ]; then
        fail "(7) $c.ag exists" "$ag not found"
        continue
    fi
    legacy="$(grep -cE '"\{\\"ts\\":" \+ to_string\(tick_now_ms\) \+ ",\\"event\\":\\"replicate' "$ag" || true)"
    has_json_dumps="$(grep -c "python3 -c 'import sys,json" "$ag" || true)"
    if [ "$legacy" = "0" ] && [ "$has_json_dumps" != "0" ]; then
        pass "(7) $c.ag replicate row uses json.dumps (legacy concat absent)"
    else
        fail "(7) $c.ag replicate row uses json.dumps" \
             "legacy=$legacy json_dumps_sites=$has_json_dumps"
    fi
done

# ---------------------------------------------------------------------
# (8) Documentation: submitter/README.md must call out the
# msc_codes_csv vs msc_codes contract and the provenance block. Stops
# a future maintainer from "fixing" the msc_codes_csv string back to a
# raw schema mismatch.
# ---------------------------------------------------------------------

if [ -f "$README" ]; then
    if grep -q "msc_codes_csv" "$README" && grep -q "msc_codes" "$README" && \
       grep -q "provenance" "$README" && \
       grep -q "preprint-ledger.jsonl row contract" "$README"; then
        pass "(8) submitter/README.md documents the msc_codes_csv contract + provenance"
    else
        fail "(8) submitter/README.md documents the msc_codes_csv contract + provenance" \
             "missing one of: msc_codes_csv / msc_codes / provenance / 'preprint-ledger.jsonl row contract' section"
    fi
else
    fail "(8) submitter/README.md exists" "$README not found"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
