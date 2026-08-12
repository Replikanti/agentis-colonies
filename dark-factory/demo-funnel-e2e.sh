#!/usr/bin/env bash
# demo-funnel-e2e.sh — OFFLINE, DETERMINISTIC proof (#1902, epic #1894 M6) that the SIX target-selection
# funnel stages shipped by M1–M5 COMPOSE end-to-end. Where the per-stage demos (demo-bounty-payability-gate.sh,
# demo-apply-audit-density.sh, demo-target-uniqueness-gate.sh, demo-pre-hunt-gate.sh, demo-submission-outcomes.sh)
# each pin ONE stage in isolation, this one runs the ASSEMBLED chain on synthetic fixtures and asserts the
# CROSS-STAGE HANDOFFS — the seams between stages, which no single-stage demo can cover.
#
# The chain (each stage feeds the next):
#   synthetic 5-col queue + bounties fixture
#     -> M1  bounty-payability-gate.sh   (drop a $0-Medium row, keep the real-Medium rows; still a 5-col queue)
#     -> M2  apply-audit-density.sh      (re-rank via a --probe-cmd stub; row set preserved, audited sinks)
#     -> M3  target-uniqueness-gate.sh   (GO on the fresh top-ranked target; emit the exclusion file)
#     -> M4  run-batch.sh --pre-hunt-gate <stub> --hunt-cmd <MOCK>
#                                        (GO target hunted + confirmed; SKIP target ledgered skipped-known,
#                                         NEVER hunted — the M3->M4 handoff)
#     -> deliver-submission.sh           (stage a canned SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW package; assert
#                                         the human-gate marker is REQUIRED — an unmarked draft is refused exit 3)
#     -> M5  submission-outcomes.sh --summary
#                                        (the staged submission appears in the rollup — the deliver->M5 handoff)
#
# HONESTY GUARDS (load-bearing — read before trusting a green run):
#   * The hunt is a MOCK (`--hunt-cmd` echoing a canned `VERDICT|confirmed|...` line). It exists ONLY to prove
#     the run-batch plumbing routes a GO target to a hunt and a SKIP target away from one. It asserts NO hunting
#     capability. The REAL hunt is flat-cyborg-only via `hunt-flat-cyborg.sh` (`--backend flat-cyborg`, NEVER
#     `claude -p`); it needs a live logged-in session and is exercised only in a real operator run, never here.
#   * The M4 pre-hunt gate is an operator-wired STUB keyed on $BATCH_KEY that mirrors M3's
#     `TARGET-UNIQUENESS|<verdict>|...` output shape — NOT the real target-uniqueness-gate.sh (run-batch.sh's
#     own header keeps that a pure operator-wired seam, not an auto-invoked script). The REAL M3 verdict is
#     produced independently in stage 3 above, over the same fresh target M2 top-ranked — that is the honest
#     M2->M3->M4 seam this demo documents rather than papers over.
#   * The report-writer draft feeding deliver-submission is a canned fixture carrying the real
#     `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW` marker (report-writer.ag renders this in production; an LLM render
#     cannot run offline). The demo asserts the INTERFACE contract deliver-submission enforces on that draft —
#     the never-submit human gate — not the draft's content quality.
#
# No network, no agentis, no LLM, no real ~/.dark-factory (a throwaway DARK_FACTORY_DIR + temp drop-dir).
#
# Usage:  dark-factory/demo-funnel-e2e.sh
# Requires: python3 (the M1/M2/M3/M5 scripts need it — [SKIP] cleanly without it).
# Exit: 0 = all handoffs composed; 1 = a failure; 3 = a stage script is missing / not executable.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
M1="$HERE/bounty-payability-gate.sh"
M2="$HERE/apply-audit-density.sh"
M3="$HERE/target-uniqueness-gate.sh"
M4="$HERE/run-batch.sh"
DELIVER="$HERE/deliver-submission.sh"
M5="$HERE/submission-outcomes.sh"

FAILS=0
note() { echo "demo-funnel-e2e.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
for s in "$M1" "$M2" "$M3" "$M4" "$DELIVER" "$M5"; do
  [ -x "$s" ] || { note "stage script not found / not executable: $s" >&2; exit 3; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-funnel-e2e.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export DARK_FACTORY_DIR="$WORK/dark-factory-home"   # never touch the real ~/.dark-factory
mkdir -p "$DARK_FACTORY_DIR"

# Field <n> of a `|`-delimited line, and a keyed lookup over a queue's stdout capture.
score_of() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$2==k{print $1}'; }
rank_of()  { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '{n++} $2==k{print n; exit}'; }

# ==========================================================================================================
# STAGE 0 — the synthetic inputs. One 5-col queue (score<TAB>key<TAB>url<TAB>title<TAB>scope_hint) and one
# raw bounties.json array, both in the exact shapes run-immunefi-intake.sh emits / --bounties reads.
#   immunefi:zero-medium : rewardsBody names only Critical -> Medium/High == confirmed $0 -> M1 DROPS it.
#   immunefi:fresh-go    : Medium $5,000 / High $25,000, repo example/fresh -> M1 KEEPS; M2 leaves fresh;
#                          M3 GO's it; M4 hunts + confirms it.
#   immunefi:known-skip  : Medium $4,000, repo example/audited -> M1 KEEPS; M2 de-ranks it below fresh-go;
#                          M4's stub gate SKIPs it (skipped-known, never hunted).
# ==========================================================================================================
QUEUE0="$WORK/queue0.tsv"
{
  printf '80\timmunefi:zero-medium\thttps://immunefi.com/bug-bounty/zero-medium/\tZero Medium Co\tchain:ethereum repo:- commit:- delta:0f/-d fee:- vault:-\n'
  printf '70\timmunefi:fresh-go\thttps://immunefi.com/bug-bounty/fresh-go/\tFresh Go Co\tchain:ethereum repo:https://github.com/example/fresh commit:- delta:0f/-d fee:- vault:-\n'
  printf '65\timmunefi:known-skip\thttps://immunefi.com/bug-bounty/known-skip/\tKnown Skip Co\tchain:ethereum repo:https://github.com/example/audited commit:- delta:0f/-d fee:- vault:-\n'
} > "$QUEUE0"

BOUNTIES="$WORK/bounties.json"
python3 - "$BOUNTIES" <<'PY'
import json, sys
data = [
    {"slug": "zero-medium", "rewardsBody": "Critical: Up to USD $500,000. All other severities are out of scope."},
    {"slug": "fresh-go",    "rewardsBody": "Medium: Up to USD $5,000. High: Up to USD $25,000."},
    {"slug": "known-skip",  "rewardsBody": "Medium: Up to USD $4,000."},
]
json.dump(data, open(sys.argv[1], "w"))
PY

# ==========================================================================================================
note "STAGE 1 (M1) — bounty-payability-gate.sh: drop the \$0-Medium row, keep the real-Medium rows ..."
QUEUE1="$WORK/queue1.tsv"
M1_OUT="$("$M1" --queue "$QUEUE0" --bounties "$BOUNTIES" --out "$QUEUE1" 2>"$WORK/m1.err")"
RC=$?
[ "$RC" -eq 0 ] && ok "M1 exits 0" || bad "M1 exited $RC (want 0)"
m1_has() { printf '%s\n' "$M1_OUT" | awk -F'\t' -v k="$1" '$2==k{f=1} END{exit !f}'; }
m1_has "immunefi:zero-medium" && bad "M1: the \$0-Medium row survived (want dropped)" \
  || ok "M1: the confirmed-\$0-Medium row 'immunefi:zero-medium' is dropped"
m1_has "immunefi:fresh-go"   && ok "M1: the real-Medium fresh row is kept" \
  || bad "M1: 'immunefi:fresh-go' was dropped (want kept)"
m1_has "immunefi:known-skip" && ok "M1: the real-Medium audited row is kept" \
  || bad "M1: 'immunefi:known-skip' was dropped (want kept)"
# The output is still a valid 5-col queue (the M1->M2 contract).
if printf '%s\n' "$M1_OUT" | awk -F'\t' 'NF!=5{exit 1}'; then
  ok "M1: every surviving row is a valid 5-col TSV (M1->M2 contract holds)"
else
  bad "M1: a surviving row is not a 5-col TSV — M2 could not consume it"
fi

# ==========================================================================================================
note "STAGE 2 (M2) — apply-audit-density.sh: re-rank M1's OUTPUT; audited sinks, row set preserved ..."
# HANDOFF H1: M2 consumes M1's --out file verbatim. The stub probe reports the audited repo hot, fresh cold.
PROBE_STUB='case "$PROBE_REPO" in
  *example/fresh)   printf "%s" "{\"heavily_audited\":false,\"repo_audit_density\":1}";;
  *example/audited) printf "%s" "{\"heavily_audited\":true,\"repo_audit_density\":40}";;
  *) ;;
esac'
QUEUE2="$WORK/queue2.tsv"
M2_OUT="$("$M2" --queue "$QUEUE1" --probe-cmd "$PROBE_STUB" --penalty 20 --out "$QUEUE2" 2>"$WORK/m2.err")"
RC=$?
[ "$RC" -eq 0 ] && ok "M2 exits 0" || bad "M2 exited $RC (want 0)"
# H1: M2's row SET is exactly M1's kept output (a permutation — re-rank drops nothing).
IN_KEYS="$(awk -F'\t' 'NF==5{print $2}' "$QUEUE1" | LC_ALL=C sort)"
OUT_KEYS="$(printf '%s\n' "$M2_OUT" | awk -F'\t' 'NF==5{print $2}' | LC_ALL=C sort)"
[ "$IN_KEYS" = "$OUT_KEYS" ] \
  && ok "H1 (M1->M2): M2 re-ranked EXACTLY the rows M1 kept — a pure permutation" \
  || bad "H1 FAILED: M2 row set differs from M1's output — got [$OUT_KEYS] want [$IN_KEYS]"
FRESH_SCORE="$(score_of "$M2_OUT" "immunefi:fresh-go")"
KNOWN_SCORE="$(score_of "$M2_OUT" "immunefi:known-skip")"
[ "$FRESH_SCORE" = "70" ] && ok "M2: the fresh target's score is untouched (70)" \
  || bad "M2: fresh score changed (got $FRESH_SCORE, want 70)"
[ "$KNOWN_SCORE" = "45" ] && ok "M2: the audited target is penalized 20 (65 -> 45)" \
  || bad "M2: audited score is $KNOWN_SCORE (want 45 after the 20 penalty)"
FRESH_RANK="$(rank_of "$M2_OUT" "immunefi:fresh-go")"
KNOWN_RANK="$(rank_of "$M2_OUT" "immunefi:known-skip")"
[ "$FRESH_RANK" -lt "$KNOWN_RANK" ] \
  && ok "M2: the fresh target now outranks the audited one (rank $FRESH_RANK < $KNOWN_RANK)" \
  || bad "M2: the audited target did not sink below the fresh one (fresh $FRESH_RANK, audited $KNOWN_RANK)"
TOP_KEY="$(printf '%s\n' "$M2_OUT" | awk -F'\t' 'NF==5{print $2; exit}')"

# ==========================================================================================================
note "STAGE 3 (M3) — target-uniqueness-gate.sh: GO on the fresh top-ranked target; emit the exclusion set ..."
# HANDOFF H2: the target M3 gates is the one M2 top-ranked (example/fresh). GH/probe stubs keep it offline.
[ "$TOP_KEY" = "immunefi:fresh-go" ] \
  && ok "H2 (M2->M3): M2's top-ranked target is the fresh one M3 will gate (immunefi:fresh-go)" \
  || bad "H2 FAILED: M2's top row is '$TOP_KEY', not the fresh target M3 gates"
GH_STUB='case "$UQ_ENDPOINT" in *example/fresh/*) echo "[]";; *) ;; esac'
M3_PROBE='case "$PROBE_REPO" in *example/fresh) printf "%s" "{\"heavily_audited\":false,\"repo_audit_density\":0}";; *) ;; esac'
EXCL="$WORK/exclusion.txt"
M3_LINE="$("$M3" --repo example/fresh --gh-cmd "$GH_STUB" --probe-cmd "$M3_PROBE" --exclusion-out "$EXCL" 2>"$WORK/m3.err")"
RC=$?
[ "$RC" -eq 0 ] && ok "M3: exit 0 (GO) on the fresh target" || bad "M3: exited $RC (want 0 = GO)"
case "$M3_LINE" in
  TARGET-UNIQUENESS\|GO\|*) ok "M3: verdict line is a GO ($M3_LINE)";;
  *) bad "M3: verdict line is not a GO: $M3_LINE";;
esac
[ -f "$EXCL" ] && ok "M3: the exclusion file was written (the producer half of the novelty-gate contract)" \
  || bad "M3: no exclusion file at $EXCL"

# ==========================================================================================================
note "STAGE 4 (M4) — run-batch.sh --pre-hunt-gate <stub> --hunt-cmd <MOCK>: GO hunted, SKIP ledgered ..."
# HANDOFF H3: the pre-hunt gate (a stub mirroring M3's TARGET-UNIQUENESS shape, keyed on $BATCH_KEY) GO's the
# fresh target and SKIPs the known one; run-batch hunts the GO and ledgers the SKIP as skipped-known. The hunt
# is a MOCK — the REAL hunt is flat-cyborg-only via hunt-flat-cyborg.sh (see the honesty guards at the top).
cp "$QUEUE2" "$DARK_FACTORY_DIR/targets.queue"
LEDGER="$DARK_FACTORY_DIR/funnel-ledger.txt"
HUNTED_LOG="$WORK/hunted.log"
GATE_STUB='case "$BATCH_KEY" in *:known-skip) echo "TARGET-UNIQUENESS|SKIP|40|stub known" ;; *) echo "TARGET-UNIQUENESS|GO|0|stub fresh" ;; esac'
HUNT_MOCK="echo \"\$BATCH_KEY\" >> \"$HUNTED_LOG\"; echo \"VERDICT|confirmed|MOCK plumbing only — real hunt is flat-cyborg\""
M4_OUT="$("$M4" --queue "$DARK_FACTORY_DIR/targets.queue" --pre-hunt-gate "$GATE_STUB" --hunt-cmd "$HUNT_MOCK" \
  --out "$WORK/batch-out" --max-targets 10 2>"$WORK/m4.err")"
RC=$?
[ "$RC" -eq 0 ] && ok "M4 exits 0" || bad "M4 exited $RC (want 0)"
# GO target: hunted + confirmed.
if [ -f "$HUNTED_LOG" ] && grep -qxF "immunefi:fresh-go" "$HUNTED_LOG"; then
  ok "H3 (M3->M4): the GO target reached the mock hunt"
else
  bad "H3 FAILED: the GO target never reached the hunt"
fi
printf '%s\n' "$M4_OUT" | grep -q '^immunefi:fresh-go	confirmed' \
  && ok "M4: the GO target is reported confirmed (hunted + staged)" \
  || bad "M4: the GO target is not reported confirmed: $M4_OUT"
grep -q '^immunefi:fresh-go	confirmed	' "$LEDGER" \
  && ok "M4: the GO target is ledgered confirmed" \
  || bad "M4: no confirmed ledger row for the GO target"
# SKIP target: ledgered skipped-known, NEVER hunted.
grep -q '^immunefi:known-skip	skipped-known	' "$LEDGER" \
  && ok "H3 (M3->M4): the SKIP target is ledgered skipped-known" \
  || bad "H3 FAILED: no skipped-known ledger row for the SKIP target"
if [ ! -f "$HUNTED_LOG" ] || ! grep -qxF "immunefi:known-skip" "$HUNTED_LOG"; then
  ok "H3 (M3->M4): the SKIP target NEVER reached the hunt (no hunt spent)"
else
  bad "H3 FAILED: the SKIP target was hunted despite a non-GO gate verdict"
fi

# ==========================================================================================================
note "STAGE 5 (deliver) — deliver-submission.sh: the human-gate marker is REQUIRED (never-submit invariant) ..."
DROP="$WORK/drop"
# HANDOFF H4a — the NEGATIVE: a draft WITHOUT the human-gate marker is REFUSED (exit 3). This is the
# never-submit invariant — nothing unmarked can ever reach the drop-dir.
UNMARKED="$WORK/unmarked-draft.md"
printf '%s\n' "# A finding write-up with no human-gate marker at all." > "$UNMARKED"
"$DELIVER" --id "example-fresh@abc123:rounding-drift" --draft-file "$UNMARKED" --drop-dir "$DROP" \
  >/dev/null 2>"$WORK/deliver-refuse.err"
RC=$?
[ "$RC" -eq 3 ] \
  && ok "H4a (M4->deliver): an UNMARKED draft is refused exit 3 — the never-submit human gate holds" \
  || bad "H4a FAILED: an unmarked draft exited $RC (want 3 = refused)"
[ -d "$DROP" ] && bad "H4a FAILED: the drop-dir was created for a refused draft" \
  || ok "H4a: nothing was staged for the refused draft"

# HANDOFF H4b — the POSITIVE: a canned draft carrying SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW stages cleanly.
DRAFT="$WORK/marked-draft.md"
{
  printf '%s\n' "SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW"
  printf '%s\n' "FIELD|title|Rounding drift in redeemShares leaks value on partial withdrawal"
  printf '%s\n' "FIELD|severity|High"
  printf '%s\n' ""
  printf '%s\n' "This canned draft stands in for report-writer.ag's render (an LLM render cannot run offline);"
  printf '%s\n' "the demo asserts only the deliver-submission INTERFACE contract, not the draft's content."
} > "$DRAFT"
SUBID="example-fresh@abc123:rounding-drift"
STAGED="$("$DELIVER" --id "$SUBID" --draft-file "$DRAFT" --target example-fresh --severity High \
  --drop-dir "$DROP" 2>"$WORK/deliver.err")"
RC=$?
[ "$RC" -eq 0 ] && ok "H4b (M4->deliver): the marked draft stages cleanly (exit 0)" \
  || bad "H4b FAILED: the marked draft exited $RC (want 0)"
[ -f "$STAGED/manifest.json" ] \
  && ok "H4b: deliver-submission staged a manifest.json under the drop-dir ($STAGED)" \
  || bad "H4b FAILED: no manifest.json at the staged path '$STAGED'"

# ==========================================================================================================
note "STAGE 6 (M5) — submission-outcomes.sh --summary: the staged submission appears in the rollup ..."
# HANDOFF H5: M5 walks the SAME drop-dir deliver-submission staged into and reports the submission. With no
# .outcome-ingested marker yet (the platform reply lands days later, out of band), the outcome is `pending`.
M5_OUT="$("$M5" --summary --drop-dir "$DROP" 2>"$WORK/m5.err")"
RC=$?
[ "$RC" -eq 0 ] && ok "M5 exits 0" || bad "M5 exited $RC (want 0)"
M5_ROW="$(printf '%s\n' "$M5_OUT" | awk -F'\t' -v sid="$SUBID" '$1==sid{print; f=1} END{if(!f) print ""}')"
if [ -n "$M5_ROW" ]; then
  ok "H5 (deliver->M5): the staged submission appears in M5's rollup"
  T="$(printf '%s' "$M5_ROW" | awk -F'\t' '{print $2}')"
  SEV="$(printf '%s' "$M5_ROW" | awk -F'\t' '{print $3}')"
  OC="$(printf '%s' "$M5_ROW" | awk -F'\t' '{print $4}')"
  [ "$T" = "example-fresh" ] && [ "$SEV" = "High" ] \
    && ok "H5: the row carries deliver-submission's target/severity (example-fresh/High)" \
    || bad "H5 FAILED: row target/severity mismatch (got target=$T severity=$SEV)"
  [ "$OC" = "pending" ] \
    && ok "H5: the outcome is 'pending' — awaiting the human-gated platform reply (never auto-filled)" \
    || bad "H5 FAILED: outcome is '$OC' (want 'pending' — no outcome recorded offline)"
else
  bad "H5 FAILED: the staged submission id '$SUBID' is absent from M5's rollup"
fi
grep -q '^submission-outcomes.sh: rollup .*pending=1 total=1' "$WORK/m5.err" \
  && ok "H5: M5's rollup line counts exactly the one pending staged submission (pending=1 total=1)" \
  || bad "H5 FAILED: unexpected M5 rollup line: $(grep '^submission-outcomes.sh: rollup ' "$WORK/m5.err")"

# ==========================================================================================================
echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the six funnel stages composed end-to-end on synthetic fixtures — M1 dropped the \$0-Medium row"
  note "      and handed a valid queue to M2, which re-ranked the audited target below the fresh one; M3 GO'd"
  note "      that fresh top target and emitted the exclusion set; M4 hunted the GO target and ledgered the"
  note "      SKIP target skipped-known WITHOUT spending a hunt; deliver-submission refused the unmarked draft"
  note "      (never-submit gate) and staged the marked one; and M5 rolled the staged submission up as pending."
  note "      Offline + deterministic. The hunt is a MOCK — the REAL hunt is flat-cyborg-only via"
  note "      hunt-flat-cyborg.sh, and the REAL submission is a human click. This demo is PLUMBING ONLY."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
