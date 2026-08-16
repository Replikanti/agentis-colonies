#!/usr/bin/env bash
# demo-run-zone-hunt.sh — OFFLINE, DETERMINISTIC end-to-end proof of the M5 capstone (#1630, epic #1611):
# run-zone-hunt.sh chains the shipped M1..M4 + delivery entrypoints into ONE autonomous zone-hunt
# (map-zones -> gen-briefs -> per-zone run-discovery -> merge -> verify-findings -> run-audit-pass ->
# deliver-submission) and HALTS every finding at the human-gate. The whole chain is driven by ONE fast stub
# wired through the --agentis seam + the M1/M2/M5 --fixture seams (NO live agentis / forge / network).
#
# Assertions (the plan's a-d):
#   a) CHAIN WIRED: zones.json + scope.tsv (M1), one brief per zone (M2), one per-zone discovery run + a merged
#      discovery-results.merged.json (M3), a CONFIRMED-only verified_findings.json (M4), and staged draft(s) (M5).
#   b) HALT: every delivered finding's pass-result.txt == PENDING-HUMAN-REVIEW and every staged draft carries the
#      SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW human-gate marker.
#   c) NEVER-SUBMIT: no network/submission verb on run-zone-hunt.sh's executable lines, no Slack env is set (the
#      operator page is a no-op), and NO draft is staged for the OOSCOPE finding (its scope gate blocks it).
#   d) PER-FINDING PROPAGATION: a finding whose submission pass HARD-FAILS (the coordinator stub exits 1) is
#      logged + skipped, the batch still finishes, the healthy finding still stages, and the capstone exits 0.
#   e) #1826 ORDER: STAGE 3 hunts value-custody zones first, deterministically across runs.
#   f-j) #1830 COVERAGE RECORD + BUDGET + RE-HUNT:
#      f) the record is TOTAL (one entry per zones.json zone, in #1826 order) and the default path is INERT.
#      g) THE ONE THAT MATTERS — a --run-cell-budget-truncated run is DISTINGUISHABLE from a clean sweep: the
#         denied zones are present as budget_exhausted and are exactly the non-custody tail (a best-effort
#         packing implementation fails this), with a negative control pinning the silent-absence defect.
#      h) a zone whose run-discovery.sh exits non-zero is recorded `failed` with its exit code, not swallowed.
#      i) --rehunt-gaps re-enters ONLY the gap zones, merges the UNION, preserves a failed attempt's artifacts
#         in discovery/<zid>.attempt-<n> + attempts[], and guards its prerequisites with exit 3.
#      j) every new flag fails fast with exit 2 on a bad value / an illegal combination.
#   k-n) #1830 REVIEW FINDINGS (each assertion fails without its fix):
#      k) a zone that ran ZERO cells (in zones.json, absent from scope.tsv) is `unscoped` and a GAP — never a
#         `hunted_*` negative, which would re-create the silent-absence defect inside the record.
#      l) the merge is a UNION across attempts: a re-hunt that yields less than the attempt it archived cannot
#         delete a candidate from discovery-results.merged.json.
#      m) a cap that `--classes` cannot enforce exactly (a zone spanning >1 scope.tsv line) DENIES the zone
#         instead of charging N while running L x N cells with mis-assigned classes.
#      n) a full re-sweep carries `attempts[]` over and the next re-hunt archives to the first FREE
#         `.attempt-<n>`, so no archive is ever destroyed and --rehunt-max-attempts really bounds.
#      o) the merge unions CANDIDATES per cell: a later attempt that surfaces MORE (but different) leads on a
#         cell cannot drop the earlier attempt's lead, and a partial carry is counted + reported.
#      (k) covers BOTH zero-cell triggers — the unclassified zone and the classified zone whose name
#         map-zones.sh's clean() rewrote — so narrowing the guard back to "no classes" fails CI.
#   p-t) #1827 WITHIN-CONTRACT DEPTH (`--zone-depth-cells`, default 0 = OFF) + its #1850 ALLOCATION
#        (`--zone-depth-lens-quota`, default unset = run-discovery.sh owns it):
#      p) INERT BY DEFAULT: with the flag absent, the run-discovery.sh argv STAGE 3 actually executes carries
#         NO --depth-max-cells and NO --depth-lens-quota (asserted against a recorded argv, not inferred from
#         an artifact).
#      q) DEPTH GIVES WAY FIRST: under a cell budget the depth allowance is trimmed to whatever headroom is
#         left ABOVE the zone's planned breadth cells — and where the cap is at/below the breadth count depth
#         is 0 and the existing class-truncation path runs unchanged (same classes, same charge, same argv).
#      r) HONEST CHARGE: cells_charged = breadth + depth, cells_planned still means "what --list-cells
#         measured", the detail names the split, and a zone that FINDS NO LEAD still shows the cap charged
#         while spending 0 depth cells (depth is not enumerable ex ante, so the cap is charged up front).
#      s) NO DOUBLE CHARGE: a --rehunt-gaps pass with depth on completes the record without any zone ever
#         being charged more than one attempt's breadth + depth.
#      t) #1850 ALLOCATION FORWARDING: --zone-depth-lens-quota reaches every hunted zone as
#         --depth-lens-quota, is recorded in the coverage detail and in each zone's totals, and does NOT
#         change what depth costs — cells_charged is still breadth + the depth cap. With the knob unset the
#         depth-on argv is byte-identical to a pre-#1850 one (asserted inside (r)).
#   v) #1880 TOTAL DEPTH BUDGET (`--total-depth-cells`, default 0 = OFF): the per-zone depth allowance is
#      lowered to min(--zone-depth-cells, N / zone count) uniformly across the sweep.
#      v1) SCALING: at --zone-depth-cells 3 --total-depth-cells 8 over 4 zones every zone is hunted at 2
#          (neither the nominal 3 nor 0, so the assertion cannot pass vacuously), the summed depth charge is
#          exactly the ceiling, the detail names the scaling, and the record carries budget.depth_*.
#      v2) CEILING BELOW ZONE COUNT: 3 cells over 4 zones gives 0 — no --depth-max-cells anywhere, a detail
#          naming the TOTAL-budget cause (never the cell-budget headroom one), and a record field-for-field
#          identical to a --zone-depth-cells 0 twin.
#      v3) INERTNESS: with --total-depth-cells absent, depth behaves exactly as #1827 shipped it and the
#          record's `budget` object gains NO depth keys (the exact-dict pin in block (f) is the twin guard).
#      v4) VALIDATION: a bad value and a ceiling with depth off both fail fast with exit 2.
#   w) #1930 FINDING-LEVEL PAYABILITY GATE (`--pay-floor`, default unset = OFF): with `--pay-floor high` the
#      stub's MEDIUM finding lands in `unpayable[]` of verify/verified_findings.payable.json and gets NO
#      audit-pass dir and NO staged draft, the two HIGH findings keep their shipped behaviour,
#      verify/verified_findings.json is UNCHANGED (delivery is narrowed, the verification record is not), the
#      drop is named on stderr rather than showing up as a silently shorter banner, the floor also reaches the
#      STAGE 2 briefs, and `--pay-floor`/`--pay-mode` misuse exits 2. Every other block in this file runs
#      WITHOUT the flag and therefore doubles as the byte-identity guarantee.
#   u) #1863 --jobs FORWARDING: --jobs reaches BOTH substrate-heavy stages — STAGE 3's run-discovery.sh AND
#      STAGE 4's verify-findings.sh (static, over the source) — and an end-to-end --jobs 2 stub run produces a
#      verify/verified_findings.json byte-identical to the default run's (the fan-out changes wall-clock, never
#      the verdict set). The stages are sequential, so one flag never stacks two concurrency ceilings.
#
# Usage:  dark-factory/demo-run-zone-hunt.sh
# Requires: git + python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', no process substitution, literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ZONEHUNT="$HERE/run-zone-hunt.sh"
FIXTURE_DIR="$HERE/fixtures/zone-map"
ZONES_FIXTURE="$FIXTURE_DIR/zones.fixture.txt"
BRIEFS_FIXTURE="$FIXTURE_DIR/briefs.fixture.txt"

FAILS=0
note() { echo "demo-run-zone-hunt.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
[ -x "$ZONEHUNT" ] || { note "run-zone-hunt.sh not found / not executable: $ZONEHUNT" >&2; exit 3; }
[ -f "$ZONES_FIXTURE" ]  || { note "zones.fixture.txt not found: $ZONES_FIXTURE" >&2; exit 3; }
[ -f "$BRIEFS_FIXTURE" ] || { note "briefs.fixture.txt not found: $BRIEFS_FIXTURE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-run-zone-hunt.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# (a) A throwaway git target: the fixture contracts/ tree (zoned) + two OUT-OF-ZONE files the two sentinel
#     candidates reference. --scope-hint contracts keeps map-zones from zoning OOSCOPE/ and EXPLODE/, but the
#     files exist so the refute gate can resolve each candidate's code file.
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target"
mkdir -p "$REPO"
cp -R "$FIXTURE_DIR/contracts" "$REPO/contracts"
# #1834: contracts/registry/ is a map-zones.sh fn_names()-regression fixture for demo-map-zones.sh only,
# isolated in its own zone so it never interacts with THIS capstone's #1826/#1830 zone-count/order pins
# (this script's zones.fixture.txt classifications now include it too, since both demos share the fixture
# tree). Drop it here rather than touch every hardcoded zone-count/order assertion below.
rm -rf "$REPO/contracts/registry"
mkdir -p "$REPO/OOSCOPE" "$REPO/EXPLODE"
printf 'contract Thing { function foo() public {} }\n' > "$REPO/OOSCOPE/Thing.sol"
printf 'contract Boom { function bang() public {} }\n'  > "$REPO/EXPLODE/Boom.sol"
git -C "$REPO" init -q
git -C "$REPO" config user.email demo@example.invalid
git -C "$REPO" config user.name "demo"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "audited baseline"

# ----------------------------------------------------------------------------------------------------------
# (b) The ONE offline stub through the --agentis seam. It stands in for hunter.ag / refuter.ag / coordinator.ag
#     + `memo get`. Deterministic, no LLM/forge/network. The three candidates encode the three delivery paths:
#     a healthy one (delivered), an OOSCOPE/ one (scope-blocked, no draft), an EXPLODE/ one (hard-fails the pass).
# ----------------------------------------------------------------------------------------------------------
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"
sub="${2:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  memo)
    if [ "$sub" = "get" ] && [ "${3:-}" = "coordinator:pass_result" ] && [ -f .agentis/pass_result ]; then
      cat .agentis/pass_result
    fi
    exit 0 ;;
  go)
    case "$sub" in
      hunter.ag)
        # DEMO_HUNTER_SILENT: every cell answers SAFE. Used by block (l) to make a re-hunt yield LESS than the
        # attempt it archived. UNSET (the default) => this branch is inert and blocks (a)-(k) are unchanged.
        if [ -n "${DEMO_HUNTER_SILENT:-}" ]; then echo "SAFE"; exit 0; fi
        # #1827: a DEPTH cell mirrors hunter.ag's DEPTH-CELL| diagnostic and answers SAFE, so blocks (p)-(s)
        # measure the CELL ACCOUNTING without perturbing the verified/delivered finding set the other blocks
        # pin. DEPTH_TARGET is empty on every breadth cell, so this branch is inert for blocks (a)-(o).
        if [ -n "${DEPTH_TARGET:-}" ]; then
          echo "DEPTH-CELL|${SUBSYSTEM:-}|${HUNT_CLASS:-}|${DEPTH_TARGET:-}"
          echo "SAFE"
          exit 0
        fi
        s="${SUBSYSTEM:-}"; c="${HUNT_CLASS:-}"
        # DEMO_HUNTER_TWO_LEADS: the vault/C1 cell answers with TWO DIFFERENT candidates instead of the usual
        # one. Used by block (o) to make a re-hunt yield MORE candidates than the attempt it archived, on the
        # SAME cell. UNSET (the default) => inert.
        if [ -n "${DEMO_HUNTER_TWO_LEADS:-}" ] && [ "$s" = "vault deposits" ] && [ "$c" = "C1" ]; then
          echo "CANDIDATE|contracts/vault/Vault.sol:mint:20|C1|Medium|a second, unrelated lead|noise-1"
          echo "CANDIDATE|contracts/vault/Vault.sol:redeem:30|C1|Medium|a third, unrelated lead|noise-2"
          exit 0
        fi
        if [ "$s" = "vault deposits" ] && [ "$c" = "C1" ]; then
          echo "CANDIDATE|contracts/vault/Vault.sol:deposit:10|C1|High|external depositor mints free shares|donate an asset to inflate the share price"
        elif [ "$s" = "price oracle" ] && [ "$c" = "C2" ]; then
          echo "CANDIDATE|OOSCOPE/Thing.sol:foo:1|C2|Medium|a lead on an out-of-scope asset path|the scope gate will block this"
        elif [ "$s" = "liquidation engine" ] && [ "$c" = "C10" ]; then
          echo "CANDIDATE|EXPLODE/Boom.sol:bang:1|C10|High|a lead whose submission pass hard-fails|the coordinator stub exits non-zero here"
        else
          echo "SAFE"
        fi
        exit 0 ;;
      refuter.ag)
        echo "VERDICT|REAL|${CAND_FILE_FN:-}|${CAND_CLASS:-}|survived a hostile read"
        exit 0 ;;
      coordinator.ag)
        loc="${FINDING_LOCATION:-}"
        case "$loc" in
          EXPLODE/*)
            echo "coordinator stub: forced hard failure for $loc" >&2
            exit 1 ;;
          OOSCOPE/*)
            printf '%s' "BLOCKED-SCOPE" > .agentis/pass_result
            echo "PASS|BLOCKED-SCOPE"
            exit 0 ;;
          *)
            out="${SUBMISSION_DRAFT_OUT:-}"
            if [ -n "$out" ]; then
              {
                echo "SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW"
                echo "FIELD|title|verified finding at $loc"
                echo "FIELD|severity|${SEVERITY_BAND:-}"
                echo ""
                echo "A human reviews this draft and files it manually. This is never auto-submitted."
              } > "$out"
            fi
            printf '%s' "PENDING-HUMAN-REVIEW" > .agentis/pass_result
            echo "PASS|PENDING-HUMAN-REVIEW"
            exit 0 ;;
        esac ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

# ----------------------------------------------------------------------------------------------------------
# Run the capstone fully offline: --map-fixture + --brief-fixture (M1/M2 stubs), --pass-fixture (M5 stub path),
# the --agentis stub for every substrate call, and a --scope-hint that keeps OOSCOPE/ + EXPLODE/ un-zoned.
# ----------------------------------------------------------------------------------------------------------
OUT="$WORK/zh"
DROP="$OUT/drop"
note "running run-zone-hunt.sh end-to-end (offline: map/brief/pass fixtures + --agentis stub) ..."
"$ZONEHUNT" --repo "$REPO" --out "$OUT" --drop-dir "$DROP" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" \
  >"$WORK/zh.out" 2>"$WORK/zh.err"
RC=$?
[ "$RC" -eq 0 ] && ok "run-zone-hunt.sh exits 0 after the batch (a clean halt on every finding)" \
  || { bad "run-zone-hunt.sh exited $RC"; sed 's/^/      /' "$WORK/zh.err" | tail -40 >&2; }

# ----------------------------------------------------------------------------------------------------------
# (a) CHAIN WIRED — every stage produced its output.
# ----------------------------------------------------------------------------------------------------------
note "a) the chain is wired zones -> briefs -> per-zone discovery -> merged -> verified -> drafts ..."
[ -f "$OUT/map/zones.json" ] && [ -f "$OUT/map/scope.tsv" ] \
  && ok "M1: map-zones.sh emitted zones.json + scope.tsv" || bad "M1 outputs missing"
[ -f "$OUT/briefs/briefs/zone_briefs.json" ] \
  && ok "M2: gen-briefs.sh emitted per-zone briefs + the index" || bad "M2 briefs missing"
if python3 - "$OUT/map/zones.json" "$OUT/briefs/briefs" "$OUT/discovery" <<'PY'
import sys, os, json
zones = json.load(open(sys.argv[1], encoding="utf-8"))
briefs, disc = sys.argv[2], sys.argv[3]
assert len(zones) >= 3, "expected >= 3 mapped zones, got %d" % len(zones)
for z in zones:
    zid = z["id"]
    assert os.path.exists(os.path.join(briefs, "brief_%s.md" % zid)), "no brief for zone %r" % zid
    assert os.path.isfile(os.path.join(disc, zid, "discovery-results.json")), "no discovery run for zone %r" % zid
PY
then ok "one brief AND one per-zone discovery run per mapped zone (per-zone --only/--brief loop)"
else bad "per-zone brief/discovery wiring assertion failed"
fi
[ -f "$OUT/discovery/discovery-results.merged.json" ] \
  && ok "M3: per-zone discovery-results.json merged into discovery-results.merged.json" || bad "merged discovery results missing"
VJ="$OUT/verify/verified_findings.json"
if [ -f "$VJ" ] && python3 - "$VJ" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["gate"] == "refute", "gate != refute"
assert d["totals"]["verified"] == 3, "expected 3 verified findings, got %r" % d["totals"]["verified"]
locs = sorted(v["location"] for v in d["verified"])
assert locs == ["EXPLODE/Boom.sol:bang:1", "OOSCOPE/Thing.sol:foo:1", "contracts/vault/Vault.sol:deposit:10"], "verified set wrong: %r" % locs
PY
then ok "M4: verify-findings.sh confirmed all 3 candidates into verified_findings.json"
else bad "M4 verified_findings.json assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (b) HALT — every delivered finding halted at PENDING-HUMAN-REVIEW and every staged draft carries the marker.
# ----------------------------------------------------------------------------------------------------------
note "b) HALT at PENDING-HUMAN-REVIEW on every delivered path ..."
HEALTHY_PR="$OUT/audit-pass/contracts-vault-Vault-sol-deposit-10/pass-result.txt"
if [ -f "$HEALTHY_PR" ] && [ "$(cat "$HEALTHY_PR")" = "PENDING-HUMAN-REVIEW" ]; then
  ok "the healthy finding's run-audit-pass halted at PENDING-HUMAN-REVIEW (never a submit)"
else
  bad "the healthy finding did not halt at PENDING-HUMAN-REVIEW"
fi
NSTAGED="$(ls -d "$DROP"/*/ 2>/dev/null | wc -l | tr -d ' ')"
[ "$NSTAGED" -eq 1 ] && ok "exactly one draft staged into the drop-dir (the healthy finding)" \
  || bad "expected exactly 1 staged draft, found $NSTAGED"
_marker_ok=1
for d in "$DROP"/*/; do
  [ -d "$d" ] || continue
  if [ -f "$d/submission-draft.md" ] && grep -q 'SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW' "$d/submission-draft.md"; then
    :
  else
    _marker_ok=0
  fi
done
[ "$_marker_ok" -eq 1 ] && ok "every staged draft carries the SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW human-gate marker" \
  || bad "a staged draft is missing the human-gate marker"

# ----------------------------------------------------------------------------------------------------------
# (c) NEVER-SUBMIT — no egress verb, no Slack env, and NO draft for the OOSCOPE finding.
# ----------------------------------------------------------------------------------------------------------
note "c) never-submit posture ..."
if grep -vE '^[[:space:]]*#' "$ZONEHUNT" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "run-zone-hunt.sh invokes a network/submission verb on an executable line"
else
  ok "run-zone-hunt.sh has no network / no submission verb on any executable line (zero egress)"
fi
if [ -z "${DARK_FACTORY_SLACK_WEBHOOK:-}" ] && [ -z "${DARK_FACTORY_SLACK_BOT_TOKEN:-}" ] && [ -z "${MONITOR_WEBHOOK_URL:-}" ]; then
  ok "no Slack/webhook env set -> deliver-submission's operator page is a silent no-op (no egress)"
else
  bad "a Slack/webhook env was set in the demo (would exercise an egress path)"
fi
OOSCOPE_PR="$OUT/audit-pass/OOSCOPE-Thing-sol-foo-1/pass-result.txt"
if [ -f "$OOSCOPE_PR" ] && [ "$(cat "$OOSCOPE_PR")" = "BLOCKED-SCOPE" ]; then
  ok "the OOSCOPE finding's scope gate returned BLOCKED-SCOPE"
else
  bad "the OOSCOPE finding did not reach BLOCKED-SCOPE"
fi
if [ -f "$OOSCOPE_PR" ] && [ ! -f "$OUT/audit-pass/OOSCOPE-Thing-sol-foo-1/submission-draft.md" ] \
   && ! ls -d "$DROP"/*OOSCOPE* >/dev/null 2>&1 && ! ls -d "$DROP"/*Thing* >/dev/null 2>&1; then
  ok "NO draft was written or staged for the scope-blocked OOSCOPE finding (nothing to submit)"
else
  bad "a draft leaked for the scope-blocked OOSCOPE finding"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) PER-FINDING PROPAGATION — the EXPLODE finding hard-fails its pass; the batch still finished + staged the
#     healthy finding + exited 0.
# ----------------------------------------------------------------------------------------------------------
note "d) per-finding error propagation ..."
if grep -q "finding 'EXPLODE-Boom-sol-bang-1' failed" "$WORK/zh.err"; then
  ok "the hard-failing EXPLODE finding was logged as failed + skipped (not fatal to the batch)"
else
  bad "the EXPLODE finding's failure was not logged/skipped as expected"
fi
if grep -q 'per-finding failures (skipped): 1' "$WORK/zh.err" \
   && grep -q 'delivered (staged, PENDING HUMAN REVIEW): 1' "$WORK/zh.err"; then
  ok "the batch summary shows 1 delivered + 1 skipped failure (the batch finished over every finding)"
else
  bad "the batch summary did not reflect 1 delivered + 1 per-finding failure"
fi
[ "$RC" -eq 0 ] && ok "the capstone exited 0 despite the per-finding hard failure" \
  || bad "the capstone did not exit 0 after a per-finding failure"

# ----------------------------------------------------------------------------------------------------------
# (e) #1826: STAGE 3 hunts value-custody zones first. The fixture's four real zones are a mix that is NOT
#     custody-sorted alphabetically pre-fix (`CUSTODY|contracts_vault|true`, `CUSTODY|contracts_oracle|false`,
#     `CUSTODY|contracts_liquidation|true`, `CUSTODY|contracts_governance|false` -- directory order is
#     governance, liquidation, oracle, vault). This pins acceptance criteria 1 and 3 (every custody zone before
#     any non-custody zone, so a truncated run only ever loses the lowest-priority zones) and, via a second
#     independent run diffed against the first, criterion 2 (byte-identical order across runs).
# ----------------------------------------------------------------------------------------------------------
note "e) STAGE 3 hunts value-custody zones first, deterministically ..."
ZONE_LIST="$OUT/.zone-list.tsv"
if [ -f "$ZONE_LIST" ]; then
  ZIDS="$(cut -f1 "$ZONE_LIST" | tr '\n' ',')"
  if [ "$ZIDS" = "contracts_liquidation,contracts_vault,contracts_governance,contracts_oracle," ]; then
    ok "the two custody zones (contracts_liquidation, contracts_vault) precede the two non-custody zones (contracts_governance, contracts_oracle), each group id-ordered"
  else
    bad "unexpected .zone-list.tsv order: $ZIDS"
  fi
else
  bad ".zone-list.tsv not found at $ZONE_LIST"
fi

OUT2="$WORK/zh2"
DROP2="$OUT2/drop"
"$ZONEHUNT" --repo "$REPO" --out "$OUT2" --drop-dir "$DROP2" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" \
  >"$WORK/zh2.out" 2>"$WORK/zh2.err"
RC2=$?
ZONE_LIST2="$OUT2/.zone-list.tsv"
if [ "$RC2" -eq 0 ] && [ -f "$ZONE_LIST2" ] && diff -u "$ZONE_LIST" "$ZONE_LIST2" >"$WORK/zone-list.diff" 2>&1; then
  ok "a second independent run produces a byte-identical .zone-list.tsv (deterministic order)"
else
  bad "a second run's .zone-list.tsv differs from the first (or the second run failed, rc=$RC2):"
  sed 's/^/      /' "$WORK/zone-list.diff" 2>/dev/null | head -40 >&2
fi

# ----------------------------------------------------------------------------------------------------------
# #1717: --deep-hunt-repair-rounds is declared + threaded into BOTH $INVHUNT deep-hunt call sites (source
# guard, mirrors --deep-hunt-max-targets above), plus one offline, LLM-free CLI check that the new flag is
# actually wired into arg-validation (fails fast before any heavy stage).
# ----------------------------------------------------------------------------------------------------------
note "#1717 --deep-hunt-repair-rounds wiring ..."
if grep -q 'DEEP_HUNT_REPAIR_ROUNDS=4' "$ZONEHUNT"; then
  ok "run-zone-hunt.sh declares DEEP_HUNT_REPAIR_ROUNDS with default 4"
else
  bad "run-zone-hunt.sh missing the DEEP_HUNT_REPAIR_ROUNDS=4 default"
fi
if [ "$(grep -c -- '--repair-rounds "\$DEEP_HUNT_REPAIR_ROUNDS"' "$ZONEHUNT")" -eq 2 ]; then
  ok "run-zone-hunt.sh threads --repair-rounds \"\$DEEP_HUNT_REPAIR_ROUNDS\" into both \$INVHUNT deep-hunt call sites"
else
  bad "run-zone-hunt.sh does not thread --repair-rounds into both \$INVHUNT deep-hunt call sites"
fi
BADVAL_ERR="$WORK/deep-hunt-repair-rounds-badval.err"
"$ZONEHUNT" --repo "$HERE" --deep-hunt --deep-hunt-repair-rounds notanumber >/dev/null 2>"$BADVAL_ERR"
BADVAL_RC=$?
if [ "$BADVAL_RC" -eq 2 ] && grep -q -- '--deep-hunt-repair-rounds must be a positive integer' "$BADVAL_ERR"; then
  ok "run-zone-hunt.sh --deep-hunt-repair-rounds notanumber fails fast with exit 2 + the usage error"
else
  bad "run-zone-hunt.sh --deep-hunt-repair-rounds notanumber did not fail fast as expected (exit $BADVAL_RC):"
  sed 's/^/      /' "$BADVAL_ERR" | head -10 >&2
fi

# ----------------------------------------------------------------------------------------------------------
# #1914 (M1): --composable-lens adds ONE class-agnostic general-solvency row (`SYS-solvency`) per custody /
# composition surface to the STAGE 4.5 selection, on top of the per-class rows. Source guard + the CLI badval
# check (same shape as the --deep-hunt-repair-rounds block above): the knob is declared DEFAULT-OFF, is threaded
# as the 6th argv of the selection python, and is a usage error without --deep-hunt. The BEHAVIOURAL contract
# (default-OFF byte-identity of .deep-hunt-targets.tsv, the additive SYS-solvency row with its aux column, and
# the routing into composable-fresh mode) is pinned offline by tools/test-deep-hunt-composable-lens.sh.
# ----------------------------------------------------------------------------------------------------------
note "#1914 --composable-lens wiring ..."
if grep -q '^DEEP_HUNT_COMPOSABLE_LENS=0$' "$ZONEHUNT"; then
  ok "run-zone-hunt.sh declares DEEP_HUNT_COMPOSABLE_LENS with default 0 (the general lens is OFF by default)"
else
  bad "run-zone-hunt.sh missing the DEEP_HUNT_COMPOSABLE_LENS=0 default"
fi
# shellcheck disable=SC2016  # matching the literal argv line, $ must not expand
# (#1930 appended "$PREFERRED_LENSES" as the next positional of the SAME argv line — the composable flag is
# still the argument immediately before it, so this guard keeps pinning the threading it was written for.)
if grep -q -- '"\$DEEP_HUNT_COMPOSABLE_LENS" "\$PREFERRED_LENSES" > "\$DEEP_TARGETS"' "$ZONEHUNT"; then
  ok "run-zone-hunt.sh threads \$DEEP_HUNT_COMPOSABLE_LENS into the STAGE 4.5 selection python"
else
  bad "run-zone-hunt.sh does not thread \$DEEP_HUNT_COMPOSABLE_LENS into the STAGE 4.5 selection python"
fi
CL_REQ_ERR="$WORK/composable-lens-requires.err"
"$ZONEHUNT" --repo "$HERE" --composable-lens >/dev/null 2>"$CL_REQ_ERR"
CL_REQ_RC=$?
if [ "$CL_REQ_RC" -eq 2 ] && grep -q -- '--composable-lens requires --deep-hunt' "$CL_REQ_ERR"; then
  ok "run-zone-hunt.sh --composable-lens WITHOUT --deep-hunt fails fast with exit 2 + the usage error"
else
  bad "run-zone-hunt.sh --composable-lens without --deep-hunt did not fail fast as expected (exit $CL_REQ_RC):"
  sed 's/^/      /' "$CL_REQ_ERR" | head -10 >&2
fi

# ----------------------------------------------------------------------------------------------------------
# #1774: --deep-hunt-only applies ONLY the STAGE 4.5 lens over an EXISTING breadth --out (the seam
# deep-hunt-ab.sh --live uses to SHARE one breadth pass across OFF/ON). Two offline, LLM-free CLI guards pin its
# contract (mirroring the --deep-hunt-repair-rounds badval pattern above): (i) it REQUIRES --deep-hunt, and
# (ii) over an --out lacking the reused artifacts (map/zones.json + verify/verified_findings.json) it exits 3.
# ----------------------------------------------------------------------------------------------------------
note "#1774 --deep-hunt-only wiring ..."
DHO_REQ_ERR="$WORK/deep-hunt-only-requires.err"
"$ZONEHUNT" --repo "$HERE" --deep-hunt-only >/dev/null 2>"$DHO_REQ_ERR"
DHO_REQ_RC=$?
if [ "$DHO_REQ_RC" -eq 2 ] && grep -q -- '--deep-hunt-only requires --deep-hunt' "$DHO_REQ_ERR"; then
  ok "run-zone-hunt.sh --deep-hunt-only WITHOUT --deep-hunt fails fast with exit 2 + the usage error"
else
  bad "run-zone-hunt.sh --deep-hunt-only without --deep-hunt did not fail fast as expected (exit $DHO_REQ_RC):"
  sed 's/^/      /' "$DHO_REQ_ERR" | head -10 >&2
fi
DHO_PRE_ERR="$WORK/deep-hunt-only-prereq.err"
DHO_EMPTY_OUT="$WORK/deep-hunt-only-empty-out"
"$ZONEHUNT" --repo "$REPO" --out "$DHO_EMPTY_OUT" --deep-hunt --deep-hunt-only >/dev/null 2>"$DHO_PRE_ERR"
DHO_PRE_RC=$?
if [ "$DHO_PRE_RC" -eq 3 ] && grep -q -- '--deep-hunt-only requires an existing' "$DHO_PRE_ERR"; then
  ok "run-zone-hunt.sh --deep-hunt-only over an --out lacking the reused breadth artifacts fails fast with exit 3"
else
  bad "run-zone-hunt.sh --deep-hunt-only over an empty --out did not fail fast as expected (exit $DHO_PRE_RC):"
  sed 's/^/      /' "$DHO_PRE_ERR" | head -10 >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (u) #1863: --jobs is forwarded to BOTH substrate-heavy stages. STAGE 4 (verify-findings.sh) used to gate
# every merged candidate strictly serially while STAGE 3 fanned out, which made the refute gate the run's
# serial TAIL. A STATIC pin (the --repair-rounds idiom above) counts the forwarded call sites, and a DYNAMIC
# one re-runs the whole capstone at --jobs 2 and demands a byte-identical verified_findings.json — the fan-out
# is a scheduling change, never a verdict change.
# ----------------------------------------------------------------------------------------------------------
note "#1863 --jobs forwarding (STAGE 3 hunt cells AND STAGE 4 verify gates) ..."
if [ "$(grep -cF -- '--jobs "$JOBS"' "$ZONEHUNT")" -eq 2 ]; then
  ok "run-zone-hunt.sh threads --jobs \"\$JOBS\" into BOTH call sites (STAGE 3 run-discovery.sh + STAGE 4 verify-findings.sh)"
else
  bad "run-zone-hunt.sh does not thread --jobs into both the STAGE 3 and the STAGE 4 call sites"
fi
OUT_J2="$WORK/zh-jobs2"
"$ZONEHUNT" --repo "$REPO" --out "$OUT_J2" --drop-dir "$OUT_J2/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" --jobs 2 \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" \
  >"$WORK/zh-jobs2.out" 2>"$WORK/zh-jobs2.err"
RCJ2=$?
[ "$RCJ2" -eq 0 ] && ok "run-zone-hunt.sh --jobs 2 exits 0 end-to-end (offline stub)" \
  || { bad "the --jobs 2 capstone run exited $RCJ2"; sed 's/^/      /' "$WORK/zh-jobs2.err" | tail -30 >&2; }
if cmp -s "$OUT/verify/verified_findings.json" "$OUT_J2/verify/verified_findings.json"; then
  ok "the --jobs 2 run's verify/verified_findings.json is BYTE-IDENTICAL to the default run's (STAGE 4 fan-out is verdict-neutral end-to-end)"
else
  bad "the --jobs 2 run's verified_findings.json diverged from the default run's:"
  diff "$OUT/verify/verified_findings.json" "$OUT_J2/verify/verified_findings.json" | sed 's/^/      /' >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (f) #1830: the COVERAGE RECORD is TOTAL and the default path stays INERT. Over run 1 (no budget flag at all)
#     the record must already account for EVERY zone in zones.json, in the #1826 priority order, all hunted,
#     with the budget knobs reported OFF — i.e. adding the record changed no behaviour, only added evidence.
#     Block (e) above still diffs .zone-list.tsv byte-for-byte across two runs; that is the gate on having
#     moved its generation into `zone-coverage.py init`.
# ----------------------------------------------------------------------------------------------------------
note "f) #1830 the coverage record is total and the default (budget-OFF) path is inert ..."
COV="$OUT/coverage/zone-coverage.json"
if [ -f "$COV" ] && python3 - "$COV" "$OUT/map/zones.json" "$OUT/.zone-list.tsv" <<'PY'
import sys, json
rec = json.load(open(sys.argv[1], encoding="utf-8"))
zones = json.load(open(sys.argv[2], encoding="utf-8"))
order = [l.split("\t")[0] for l in open(sys.argv[3], encoding="utf-8").read().splitlines() if l.strip()]
assert rec["schema"] == "zone-coverage/v1", "wrong schema: %r" % rec["schema"]
assert len(rec["zones"]) == len(zones) == 4, "record covers %d of %d zones" % (len(rec["zones"]), len(zones))
assert [z["id"] for z in rec["zones"]] == order, "record order != .zone-list.tsv order"
bad = [(z["id"], z["status"]) for z in rec["zones"] if z["status"] not in ("hunted", "hunted_empty")]
assert not bad, "not every zone was hunted: %r" % bad
assert rec["complete"] is True, "complete != True"
assert rec["gap_zones"] == [], "gap_zones != []: %r" % rec["gap_zones"]
assert rec["budget"] == {"unit": "cells", "per_zone": 0, "run": 0}, "budget knobs not OFF: %r" % rec["budget"]
for z in rec["zones"]:
    assert z["budget_truncated"] is False, "%s reports budget_truncated with budgets OFF" % z["id"]
    assert z["cells_charged"] == z["cells_planned"], "%s charged %r of %r planned cells" % (
        z["id"], z["cells_charged"], z["cells_planned"])
PY
then ok "the record accounts for ALL 4 zones in #1826 priority order, all hunted, budget knobs OFF + untruncated"
else bad "the run-1 coverage record assertion failed"
fi
if python3 - "$OUT/discovery/discovery-results.merged.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["coverage"]["complete"] is True, "merged coverage.complete != True"
assert d["coverage"]["gap_zones"] == [], "merged coverage.gap_zones != []"
assert d["totals"]["failed"] == 0, "merged totals.failed != 0: %r" % d["totals"]["failed"]
PY
then ok "discovery-results.merged.json gained coverage.complete + the propagated totals.failed (additive keys)"
else bad "the merged-JSON coverage/totals.failed assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (g) #1830 THE ONE THAT MATTERS — a TRUNCATED run is DISTINGUISHABLE from a clean sweep. The fixture's cell
#     counts are liquidation 2 + vault 3 + governance 2 + oracle 2 = 9, so --run-cell-budget 5 admits exactly
#     the two VALUE-CUSTODY zones and denies the two non-custody ones. Asserted: the denied zones are PRESENT
#     in the record as budget_exhausted (not absent, not hunted_empty), the denied set is exactly the
#     non-custody tail (a best-effort packing implementation FAILS here, which is the point — packing would
#     silently invert #1826), and the gap is visible on stderr and in the merged file.
# ----------------------------------------------------------------------------------------------------------
note "g) #1830 a budget-truncated run is distinguishable from a clean sweep ..."
OUT3="$WORK/zh3"
"$ZONEHUNT" --repo "$REPO" --out "$OUT3" --drop-dir "$OUT3/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --run-cell-budget 5 \
  >"$WORK/zh3.out" 2>"$WORK/zh3.err"
RC3=$?
[ "$RC3" -eq 0 ] && ok "a budget-truncated run still exits 0 (the budget shapes coverage, it is not an error)" \
  || { bad "the --run-cell-budget run exited $RC3"; sed 's/^/      /' "$WORK/zh3.err" | tail -20 >&2; }
if python3 - "$OUT3/coverage/zone-coverage.json" <<'PY'
import sys, json
rec = json.load(open(sys.argv[1], encoding="utf-8"))
ids = [z["id"] for z in rec["zones"]]
assert len(ids) == 4, "the record dropped a zone under a budget: %r" % ids
denied = [z["id"] for z in rec["zones"] if z["status"] == "budget_exhausted"]
assert denied == ["contracts_governance", "contracts_oracle"], "denied set wrong: %r" % denied
hunted = [z["id"] for z in rec["zones"] if z["status"] in ("hunted", "hunted_empty")]
assert hunted == ["contracts_liquidation", "contracts_vault"], "admitted set wrong: %r" % hunted
assert rec["complete"] is False, "a truncated run reported complete"
assert rec["gap_zones"] == ["contracts_governance", "contracts_oracle"], "gap_zones wrong: %r" % rec["gap_zones"]
# THE #1826 INTERACTION: the cut falls on exactly the non-custody tail — never on a value-custody zone.
noncustody = [z["id"] for z in rec["zones"] if not z["value_custody"]]
assert denied == noncustody, "the budget denied %r, not the non-custody tail %r" % (denied, noncustody)
assert rec["budget"]["run"] == 5, "the record does not report the run budget: %r" % rec["budget"]
PY
then ok "all 4 zones are in the record; the 2 denied ones are budget_exhausted and are EXACTLY the non-custody tail (#1826 holds)"
else bad "the truncated-run coverage assertion failed"
fi
if grep -q 'COVERAGE GAP:' "$WORK/zh3.err"; then
  ok "STAGE 3 printed the fail-loud COVERAGE GAP banner to stderr"
else
  bad "no COVERAGE GAP banner on stderr for the truncated run"
fi
if python3 - "$OUT3/discovery/discovery-results.merged.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["coverage"]["complete"] is False, "merged file reports a truncated run as complete"
assert d["coverage"]["by_status"]["budget_exhausted"] == 2, "merged by_status wrong: %r" % d["coverage"]["by_status"]
PY
then ok "a consumer reading ONLY discovery-results.merged.json can see the truncation (coverage.complete == false)"
else bad "the merged file hid the truncation"
fi
# The NEGATIVE CONTROL that pins the defect itself: the filesystem alone shows 2 hunted zones out of 4 mapped
# — exactly the shape a real target hit (1 of 7 zones hunted, merged file looking clean). The record is the
# only artifact that accounts for all 4.
if python3 - "$OUT3" <<'PY'
import sys, os, json, glob
out = sys.argv[1]
fs_zones = sorted(os.path.basename(os.path.dirname(p))
                  for p in glob.glob(os.path.join(out, "discovery", "*", "discovery-results.json")))
mapped = json.load(open(os.path.join(out, "map", "zones.json"), encoding="utf-8"))
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
assert len(fs_zones) == 2, "expected 2 zone dirs with results, got %r" % fs_zones
assert len(mapped) == 4, "expected 4 mapped zones, got %d" % len(mapped)
assert len(rec["zones"]) == 4, "the record accounts for %d of 4 zones" % len(rec["zones"])
PY
then ok "negative control: the discovery dirs alone show 2 of 4 zones (the silent-absence shape) — only the record accounts for all 4"
else bad "the negative-control assertion failed"
fi
# The OTHER budget branch: 0 < cap < planned SHORTENS the class list instead of denying the zone. With
# --zone-cell-budget 2 only `vault deposits` (3 planned cells) is over the cap, so it is hunted with
# --classes C1,C6 and flagged budget_truncated — a QUALIFIER, not a status: the zone WAS hunted, but its
# result is not a rigorous negative, so it still counts as a gap.
OUT6="$WORK/zh6"
"$ZONEHUNT" --repo "$REPO" --out "$OUT6" --drop-dir "$OUT6/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-cell-budget 2 \
  >"$WORK/zh6.out" 2>"$WORK/zh6.err"
RC6=$?
if [ "$RC6" -eq 0 ] && python3 - "$OUT6" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
by_id = dict((z["id"], z) for z in rec["zones"])
v = by_id["contracts_vault"]
assert v["status"] in ("hunted", "hunted_empty"), "the truncated zone is %r, not hunted" % v["status"]
assert v["budget_truncated"] is True, "the over-cap zone is not flagged budget_truncated"
assert v["cells_planned"] == 3 and v["cells_charged"] == 2, "planned/charged wrong: %r/%r" % (
    v["cells_planned"], v["cells_charged"])
assert v["classes_hunted"] == ["C1", "C6"], "the shortened class list is %r" % v["classes_hunted"]
for zid in ("contracts_liquidation", "contracts_governance", "contracts_oracle"):
    assert by_id[zid]["budget_truncated"] is False, "%s was truncated at cap 2 with 2 planned cells" % zid
assert rec["complete"] is False, "a budget_truncated zone must keep the run out of `complete`"
assert rec["gap_zones"] == ["contracts_vault"], "gap_zones wrong: %r" % rec["gap_zones"]
merged = json.load(open(os.path.join(out, "discovery", "discovery-results.merged.json"), encoding="utf-8"))
assert merged["totals"]["cells"] == 8, "expected 8 cells under the per-zone cap, got %r" % merged["totals"]["cells"]
PY
then ok "--zone-cell-budget 2 SHORTENS the over-cap zone to its first 2 classes + flags budget_truncated (still a gap)"
else bad "the per-zone cap / budget_truncated assertion failed (exit $RC6)"
fi
OUT5="$WORK/zh5"
"$ZONEHUNT" --repo "$REPO" --out "$OUT5" --drop-dir "$OUT5/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --run-cell-budget 5 --require-coverage 100 \
  >"$WORK/zh5.out" 2>"$WORK/zh5.err"
RC5=$?
if [ "$RC5" -eq 4 ] && [ ! -f "$OUT5/verify/verified_findings.json" ] && [ -f "$OUT5/coverage/zone-coverage.json" ]; then
  ok "--require-coverage 100 halts the same truncated run with exit 4 BEFORE verify/deliver, record still on disk"
else
  bad "--require-coverage 100 did not halt as expected (exit $RC5)"
fi

# ----------------------------------------------------------------------------------------------------------
# (h) #1830: a FAILED zone is RECORDED, not swallowed. A second stub fails `agentis init` for exactly one
#     zone's out-dir, which makes run-discovery.sh itself exit non-zero for that zone (it runs init under
#     set -e with cwd inside the zone dir). The capstone's posture is unchanged — a per-zone failure is still
#     non-fatal — but the zone is now `failed` with its exit code instead of a log line and nothing else.
# ----------------------------------------------------------------------------------------------------------
note "h) #1830 a failed zone is recorded with its exit code, not swallowed ..."
STUB_FAIL="$WORK/agentis-stub-failzone"
sed 's|^  init) mkdir -p .agentis; exit 0 ;;|  init)\n    case "$PWD" in */discovery/contracts_governance/*) exit 1 ;; esac\n    mkdir -p .agentis; exit 0 ;;|' "$STUB" > "$STUB_FAIL"
chmod +x "$STUB_FAIL"
OUT4="$WORK/zh4"
"$ZONEHUNT" --repo "$REPO" --out "$OUT4" --drop-dir "$OUT4/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB_FAIL" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" \
  >"$WORK/zh4.out" 2>"$WORK/zh4.err"
RC4=$?
[ "$RC4" -eq 0 ] && ok "a per-zone discovery failure is still non-fatal — the capstone exits 0 (posture unchanged)" \
  || { bad "the failed-zone run exited $RC4"; sed 's/^/      /' "$WORK/zh4.err" | tail -20 >&2; }
if python3 - "$OUT4/coverage/zone-coverage.json" <<'PY'
import sys, json
rec = json.load(open(sys.argv[1], encoding="utf-8"))
by_id = dict((z["id"], z) for z in rec["zones"])
gov = by_id["contracts_governance"]
assert gov["status"] == "failed", "the failing zone is %r, not failed" % gov["status"]
assert gov["exit_code"], "the failed zone carries no non-zero exit_code: %r" % gov["exit_code"]
others = [z["status"] for z in rec["zones"] if z["id"] != "contracts_governance"]
assert all(s in ("hunted", "hunted_empty") for s in others), "the other zones are %r" % others
assert rec["complete"] is False, "a run with a failed zone reported complete"
assert rec["gap_zones"] == ["contracts_governance"], "gap_zones wrong: %r" % rec["gap_zones"]
PY
then ok "the failed zone is recorded status=failed with its exit code; the run is NOT complete"
else bad "the failed-zone coverage assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (i) #1830: the re-hunt is TARGETED, RE-ENTRANT, and does not collapse `failed` into `not_reached`.
# ----------------------------------------------------------------------------------------------------------
note "i) #1830 --rehunt-gaps re-enters only the gap zones and preserves prior evidence ..."
"$ZONEHUNT" --repo "$REPO" --out "$OUT3" --drop-dir "$OUT3/drop" \
  --backend mock --agentis "$STUB" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --rehunt-gaps \
  >"$WORK/zh3r.out" 2>"$WORK/zh3r.err"
RC3R=$?
if [ "$RC3R" -eq 0 ] && ! grep -q '\[M1\] mapping zones' "$WORK/zh3r.err" \
   && ! grep -q '\[M2\] generating' "$WORK/zh3r.err" \
   && [ "$(grep -c '\[M3\] hunting zone' "$WORK/zh3r.err")" -eq 2 ] \
   && grep -q "hunting zone 'governance'" "$WORK/zh3r.err" \
   && grep -q "hunting zone 'price oracle'" "$WORK/zh3r.err"; then
  ok "i.1: --rehunt-gaps skipped STAGE 1/2 and hunted EXACTLY the 2 budget-denied zones"
else
  bad "i.1: --rehunt-gaps did not re-enter exactly the gap zones (exit $RC3R)"
  sed 's/^/      /' "$WORK/zh3r.err" | tail -20 >&2
fi
if python3 - "$OUT3" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
assert rec["complete"] is True, "the re-hunt did not close the gap: %r" % rec["gap_zones"]
assert rec["gap_zones"] == [], "gap_zones != [] after the re-hunt: %r" % rec["gap_zones"]
merged = json.load(open(os.path.join(out, "discovery", "discovery-results.merged.json"), encoding="utf-8"))
assert merged["totals"]["cells"] == 9, "union merge wrong: %r cells (a clean sweep is 9)" % merged["totals"]["cells"]
assert merged["coverage"]["complete"] is True, "the merged file still reports a gap"
PY
then ok "i.1: after the re-hunt the record is complete and the merge is the UNION (9 cells = the clean-sweep total)"
else bad "i.1: the post-re-hunt union/completeness assertion failed"
fi
"$ZONEHUNT" --repo "$REPO" --out "$OUT4" --drop-dir "$OUT4/drop" \
  --backend mock --agentis "$STUB" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --rehunt-gaps \
  >"$WORK/zh4r.out" 2>"$WORK/zh4r.err"
RC4R=$?
if [ "$RC4R" -eq 0 ] && [ -d "$OUT4/discovery/contracts_governance.attempt-1/run" ] \
   && [ -f "$OUT4/discovery/contracts_governance.attempt-1/run/hunter.ag" ]; then
  ok "i.2: the failed attempt's artifacts were MOVED to discovery/<zid>.attempt-1 (not destroyed by re-entry)"
else
  bad "i.2: the failed zone's prior artifacts were not preserved (exit $RC4R)"
fi
if python3 - "$OUT4/coverage/zone-coverage.json" <<'PY'
import sys, json
rec = json.load(open(sys.argv[1], encoding="utf-8"))
gov = dict((z["id"], z) for z in rec["zones"])["contracts_governance"]
assert len(gov["attempts"]) == 1, "attempts != 1: %r" % gov["attempts"]
a = gov["attempts"][0]
assert a["status"] == "failed", "the pushed attempt is %r, not the failed one" % a["status"]
assert a["exit_code"], "the pushed attempt lost its non-zero exit code: %r" % a["exit_code"]
assert a["artifacts"] == "discovery/contracts_governance.attempt-1", "artifacts path wrong: %r" % a["artifacts"]
assert gov["status"] in ("hunted", "hunted_empty"), "the re-hunted zone is %r" % gov["status"]
assert rec["complete"] is True, "the re-hunt did not close the gap"
PY
then ok "i.2: the prior failed attempt survives in attempts[] with its exit code; the zone is now hunted"
else bad "i.2: the attempts[] preservation assertion failed"
fi
# i.4: a PARTIAL zone (budget_truncated) is deliberately NOT in the default work list — a re-hunt would redo
# cells that already produced results — and is reached only under --rehunt-include-partial, which treats it as
# a `retry` (prior artifacts moved aside, prior state pushed into attempts[]).
"$ZONEHUNT" --repo "$REPO" --out "$OUT6" --drop-dir "$OUT6/drop" \
  --backend mock --agentis "$STUB" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --rehunt-gaps --rehunt-include-partial \
  >"$WORK/zh6r.out" 2>"$WORK/zh6r.err"
RC6R=$?
if [ "$RC6R" -eq 0 ] && [ "$(grep -c '\[M3\] hunting zone' "$WORK/zh6r.err")" -eq 1 ] \
   && [ -d "$OUT6/discovery/contracts_vault.attempt-1" ] && python3 - "$OUT6" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
v = dict((z["id"], z) for z in rec["zones"])["contracts_vault"]
assert v["budget_truncated"] is False, "the re-hunt did not clear budget_truncated"
assert v["cells_charged"] == 3 and v["classes_hunted"] == ["C1", "C6", "C11"], "re-hunt was still capped: %r" % v
assert len(v["attempts"]) == 1 and v["attempts"][0]["status"] in ("hunted", "hunted_empty"), \
    "the truncated attempt was not preserved: %r" % v["attempts"]
assert rec["complete"] is True, "the partial re-hunt did not close the gap: %r" % rec["gap_zones"]
merged = json.load(open(os.path.join(out, "discovery", "discovery-results.merged.json"), encoding="utf-8"))
assert merged["totals"]["cells"] == 9, "union merge wrong: %r cells" % merged["totals"]["cells"]
PY
then ok "i.4: --rehunt-include-partial re-hunts the truncated zone in full, preserves the partial attempt, closes the gap"
else bad "i.4: the --rehunt-include-partial assertion failed (exit $RC6R)"
fi
NOCOV="$WORK/zh-nocov"
cp -R "$OUT" "$NOCOV"
rm -rf "$NOCOV/coverage"
REHUNT_PRE_ERR="$WORK/rehunt-prereq.err"
"$ZONEHUNT" --repo "$REPO" --out "$NOCOV" --backend mock --agentis "$STUB" --rehunt-gaps \
  >/dev/null 2>"$REHUNT_PRE_ERR"
REHUNT_PRE_RC=$?
if [ "$REHUNT_PRE_RC" -eq 3 ] && grep -q -- '--rehunt-gaps requires an existing' "$REHUNT_PRE_ERR" \
   && grep -q 'coverage/zone-coverage.json' "$REHUNT_PRE_ERR"; then
  ok "i.3: --rehunt-gaps over an --out lacking the coverage record fails fast with exit 3, naming the artifact"
else
  bad "i.3: --rehunt-gaps missing-record guard did not fire as expected (exit $REHUNT_PRE_RC):"
  sed 's/^/      /' "$REHUNT_PRE_ERR" | head -10 >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (j) #1830 flag validation, fail-fast (the #1717 badval idiom — no heavy stage runs).
# ----------------------------------------------------------------------------------------------------------
note "j) #1830 budget / re-hunt flag validation fails fast ..."
badflag() {
  bf_desc="$1"; bf_expect="$2"; shift 2
  bf_err="$WORK/badflag.err"
  "$ZONEHUNT" --repo "$HERE" "$@" >/dev/null 2>"$bf_err"
  bf_rc=$?
  if [ "$bf_rc" -eq 2 ] && grep -q -- "$bf_expect" "$bf_err"; then
    ok "$bf_desc fails fast with exit 2 + the usage error"
  else
    bad "$bf_desc did not fail fast as expected (exit $bf_rc):"
    sed 's/^/      /' "$bf_err" | head -5 >&2
  fi
}
badflag "--zone-cell-budget notanumber" 'must be a non-negative integer' --zone-cell-budget notanumber
badflag "--run-cell-budget -1" 'must be a non-negative integer' --run-cell-budget -1
badflag "--require-coverage 101" 'integer percentage 0-100' --require-coverage 101
badflag "--rehunt-include-partial without --rehunt-gaps" 'requires --rehunt-gaps' --rehunt-include-partial
badflag "--rehunt-gaps with --deep-hunt-only" 'cannot be combined with --deep-hunt-only' \
  --rehunt-gaps --deep-hunt --deep-hunt-only

# ----------------------------------------------------------------------------------------------------------
# (k) #1830 review finding 1: a zone that ran ZERO cells must NEVER derive a `hunted_*` status. `map-zones.sh`
#     writes a scope.tsv line only `if not skeleton and classes and z["id"] not in failed_zones`, so an
#     UNCLASSIFIED zone (and a `classification_failed` zone) is in zones.json, gets a brief from gen-briefs.sh
#     (which iterates zones.json), passes the brief guard, and then `run-discovery.sh --only <name>` matches no
#     manifest line, runs 0 cells and exits 0 with `totals:{cells:0,candidates:0,failed:0}`. Deriving
#     `hunted_empty` there re-created the silent-absence defect INSIDE the record: complete: true, no banner,
#     `--require-coverage 100` passing, while a real zone was never looked at.
# ----------------------------------------------------------------------------------------------------------
note 'k) #1830 a zone that ran ZERO cells is unscoped (a gap), never a negative ...'
REPO_K="$WORK/target-unscoped"
mkdir -p "$REPO_K"
cp -R "$FIXTURE_DIR/contracts" "$REPO_K/contracts"
# #1834: see the (a) REPO setup above -- drop the isolated fn_names()-regression fixture so it doesn't
# perturb this block's hardcoded 6-zone count.
rm -rf "$REPO_K/contracts/registry"
mkdir -p "$REPO_K/contracts/rewards" "$REPO_K/contracts/accrual"
printf 'contract Rewards { function claim() public {} function accrue() public {} }\n' > "$REPO_K/contracts/rewards/Rewards.sol"
printf 'contract Accrual { function tick() public {} }\n' > "$REPO_K/contracts/accrual/Accrual.sol"
git -C "$REPO_K" init -q
git -C "$REPO_K" config user.email demo@example.invalid
git -C "$REPO_K" config user.name "demo"
git -C "$REPO_K" add -A
git -C "$REPO_K" commit -qm "audited baseline"
# TWO independent triggers for the same sink, because the guard is keyed on the OUTCOME (zero cells ran), not
# on any single cause — if it is ever narrowed back to "no classes in zones.json", trigger B must fail CI.
#   trigger A (contracts_rewards): NO ZONE| line at all -> unclassified -> map-zones.sh writes no scope line.
#   trigger B (contracts_accrual): a fully CLASSIFIED zone whose name contains a BACKTICK. map-zones.sh keeps
#     the name verbatim in zones.json but runs it through clean() (`[|`\r\n]` -> space) for scope.tsv, so the
#     zone HAS a scope line — under a different subsystem string — and `--only "<zones.json name>"` matches
#     nothing. Zero cells, exit 0, and pre-fix that derived a clean `hunted_empty`.
ZONES_K="$WORK/zones-unscoped.fixture.txt"
cp "$ZONES_FIXTURE" "$ZONES_K"
printf 'ZONE|contracts_accrual|`accrual` engine|C1,C6|Interest accrual, named with a backtick the mapper must strip\n' >> "$ZONES_K"
BRIEFS_K="$WORK/briefs-unscoped.fixture.txt"
cp "$BRIEFS_FIXTURE" "$BRIEFS_K"
{
  echo "DARK-FACTORY:BRIEF-BEGIN|contracts_rewards"
  echo "Attack the reward accrual accounting."
  echo "DARK-FACTORY:BRIEF-END"
  echo "DARK-FACTORY:BRIEF-BEGIN|contracts_accrual"
  echo "Attack the interest index."
  echo "DARK-FACTORY:BRIEF-END"
} >> "$BRIEFS_K"
OUTK="$WORK/zh-unscoped"
"$ZONEHUNT" --repo "$REPO_K" --out "$OUTK" --drop-dir "$OUTK/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_K" --brief-fixture "$BRIEFS_K" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" \
  >"$WORK/zhk.out" 2>"$WORK/zhk.err"
RCK=$?
if [ "$RCK" -eq 0 ] && python3 - "$OUTK" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
zones = json.load(open(os.path.join(out, "map", "zones.json"), encoding="utf-8"))
by_id = dict((z["id"], z) for z in rec["zones"])
assert len(rec["zones"]) == len(zones) == 6, "record/zones.json size mismatch: %d/%d" % (len(rec["zones"]), len(zones))
# trigger A - unclassified zone, no scope.tsv line at all.
a = by_id["contracts_rewards"]
assert a["status"] == "unscoped", "trigger A zone is %r, not unscoped" % a["status"]
assert a["cells"] == 0 and a["cells_planned"] == 0, "unexpected cell counts: %r" % a
# trigger B - a CLASSIFIED zone whose zones.json name was rewritten by map-zones.sh's clean() before it
# reached scope.tsv, so the zone HAS a scope line under a different subsystem string and --only matches
# nothing. This is the trigger a "no classes in zones.json" guard would miss - the plausible future refactor.
b = by_id["contracts_accrual"]
zb = [z for z in zones if z["id"] == "contracts_accrual"][0]
assert zb["bug_classes_likely"], "trigger B must be a CLASSIFIED zone, else it degenerates into trigger A"
assert "`" in zb["name"], "trigger B needs the raw backticked name in zones.json: %r" % zb["name"]
scope = open(os.path.join(out, "map", "scope.tsv"), encoding="utf-8").read()
assert "accrual" in scope, "trigger B needs a scope line (under the CLEANED name)"
assert zb["name"] not in scope, "trigger B needs the scope line under a DIFFERENT subsystem string"
assert b["status"] == "unscoped", "trigger B zone is %r, not unscoped" % b["status"]
assert b["cells"] == 0, "trigger B zone ran %r cells" % b["cells"]
# THE SINK: no zone may ever be `hunted_*` with zero cells run.
bad = [z["id"] for z in rec["zones"] if z["status"].startswith("hunted") and z["cells"] == 0]
assert not bad, "zones claim a hunted status with 0 cells: %r" % bad
assert rec["complete"] is False, "a run that never looked at a real zone reported complete"
assert sorted(rec["gap_zones"]) == ["contracts_accrual", "contracts_rewards"], \
    "gap_zones wrong: %r" % rec["gap_zones"]
PY
then ok 'BOTH zero-cell triggers are unscoped gaps: the unclassified zone AND the classified zone whose name clean() rewrote'
else bad "the unscoped-zone assertion failed (exit $RCK)"
fi
if grep -q 'COVERAGE GAP:' "$WORK/zhk.err" && grep -q 'has NO line in scope.tsv' "$WORK/zhk.err"; then
  ok "the unscoped zone is named on stderr and raises the COVERAGE GAP banner"
else
  bad "the unscoped zone did not surface on stderr"
fi
"$ZONEHUNT" --repo "$REPO_K" --out "$WORK/zh-unscoped2" --drop-dir "$WORK/zh-unscoped2/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_K" --brief-fixture "$BRIEFS_K" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --require-coverage 100 \
  >/dev/null 2>"$WORK/zhk2.err"
RCK2=$?
[ "$RCK2" -eq 4 ] && ok "--require-coverage 100 now REFUSES the run that never looked at that zone (exit 4)" \
  || bad "--require-coverage 100 passed a run with an unhunted zone (exit $RCK2)"

# ----------------------------------------------------------------------------------------------------------
# (l) #1830 review finding 2: a re-hunt must never DELETE evidence from the merged file. The re-entry moves
#     discovery/<zid> to <zid>.attempt-<n>; if the merge excluded those dirs, a re-hunt that yields LESS than
#     the attempt it archived would silently drop real candidates AND report a better coverage verdict. The
#     merge is therefore a UNION across attempts, deduplicated by (subsystem, class, files), most-candidates
#     wins — a later SAFE never erases an earlier CANDIDATE (refuting is STAGE 4's job).
# ----------------------------------------------------------------------------------------------------------
note "l) #1830 the merge is a union across attempts — a re-hunt cannot delete a candidate ..."
OUTL="$WORK/zh-union"
"$ZONEHUNT" --repo "$REPO" --out "$OUTL" --drop-dir "$OUTL/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-cell-budget 1 \
  >"$WORK/zhl1.out" 2>"$WORK/zhl1.err"
RCL1=$?
# Pass 2 re-hunts the truncated zones with a hunter that finds NOTHING this time.
DEMO_HUNTER_SILENT=1 "$ZONEHUNT" --repo "$REPO" --out "$OUTL" --drop-dir "$OUTL/drop" \
  --backend mock --agentis "$STUB" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --rehunt-gaps --rehunt-include-partial --rehunt-max-attempts 3 \
  >"$WORK/zhl2.out" 2>"$WORK/zhl2.err"
RCL2=$?
if [ "$RCL1" -eq 0 ] && [ "$RCL2" -eq 0 ] && python3 - "$OUTL" <<'PY'
import sys, os, json, glob
out = sys.argv[1]
merged = json.load(open(os.path.join(out, "discovery", "discovery-results.merged.json"), encoding="utf-8"))
archived = {}
for p in sorted(glob.glob(os.path.join(out, "discovery", "*.attempt-*", "discovery-results.json"))):
    archived[p] = json.load(open(p, encoding="utf-8"))["totals"]["candidates"]
lost = sum(archived.values())
assert lost >= 1, "the fixture did not archive an attempt holding a candidate: %r" % archived
# The candidate the second, emptier attempt did NOT reproduce must still be in the merged file.
assert merged["totals"]["candidates"] >= lost, \
    "the re-hunt LOST %d archived candidate(s): merged carries %d" % (lost, merged["totals"]["candidates"])
assert merged["merge"]["policy"] == "union-across-attempts", "merge policy not declared: %r" % merged.get("merge")
assert merged["merge"]["carried_over_cells"] >= 1, "nothing was carried over from the archived attempt"
assert merged["totals"]["cells"] == 9, "the union double-counted or lost cells: %r" % merged["totals"]["cells"]
cand_locs = [c for cell in merged["cells"] for c in cell.get("candidates", [])]
assert any("Vault.sol" in c for c in cand_locs), "the archived vault candidate is not in cells[]: %r" % cand_locs
PY
then ok "a re-hunt that finds LESS than the attempt it archived keeps every prior candidate in the merged file"
else bad "the union-across-attempts assertion failed (exit $RCL1/$RCL2)"
fi

# ----------------------------------------------------------------------------------------------------------
# (m) #1830 review finding 3: `--classes` is a per-manifest-LINE override in run-discovery.sh, not a cell
#     filter. map-zones.sh keys scope lines on clean(name) with no dedup, so two zones can share a subsystem
#     name; a class-prefix "cap of N" would then admit L x N cells and apply classes to files the mapper never
#     assigned them to. The admitted count is MEASURED with a second --list-cells probe; when it does not land
#     exactly on the cap the zone is DENIED rather than mis-charged.
# ----------------------------------------------------------------------------------------------------------
note "m) #1830 a cap that cannot be enforced denies the zone instead of mis-charging it ..."
REPO_M="$WORK/target-dupname"
mkdir -p "$REPO_M/contracts/v1" "$REPO_M/contracts/v2"
printf 'contract A { function f() public {} }\n' > "$REPO_M/contracts/v1/A.sol"
printf 'contract B { function g() public {} }\n' > "$REPO_M/contracts/v2/B.sol"
git -C "$REPO_M" init -q
git -C "$REPO_M" config user.email demo@example.invalid
git -C "$REPO_M" config user.name "demo"
git -C "$REPO_M" add -A
git -C "$REPO_M" commit -qm "audited baseline"
mkdir -p "$REPO_M/contracts/solo"
printf 'contract C { function h() public {} }\n' > "$REPO_M/contracts/solo/C.sol"
git -C "$REPO_M" add -A
git -C "$REPO_M" commit -qm "solo zone"
ZONES_M="$WORK/zones-dupname.fixture.txt"
{
  echo "ZONE|contracts_v1|vault|C1,C6,C11|first vault dir"
  echo "ZONE|contracts_v2|vault|C2,C9|second vault dir with the SAME name"
  # A third, uniquely-named zone with ONE cell — trivially enforceable at cap 2, and NOT value-custody so it
  # is hunted LAST. If an unenforceability denial stopped the loop, this zone would be denied too.
  echo "ZONE|contracts_solo|solo keeper|C6|uniquely named, 1 cell"
  echo "CUSTODY|contracts_v1|true"
  echo "CUSTODY|contracts_v2|true"
  echo "CUSTODY|contracts_solo|false"
} > "$ZONES_M"
BRIEFS_M="$WORK/briefs-dupname.fixture.txt"
{
  echo "DARK-FACTORY:BRIEF-BEGIN|contracts_v1"
  echo "Break the first vault."
  echo "DARK-FACTORY:BRIEF-END"
  echo "DARK-FACTORY:BRIEF-BEGIN|contracts_v2"
  echo "Break the second vault."
  echo "DARK-FACTORY:BRIEF-END"
  echo "DARK-FACTORY:BRIEF-BEGIN|contracts_solo"
  echo "Break the keeper."
  echo "DARK-FACTORY:BRIEF-END"
} > "$BRIEFS_M"
OUTM="$WORK/zh-dupname"
"$ZONEHUNT" --repo "$REPO_M" --out "$OUTM" --drop-dir "$OUTM/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_M" --brief-fixture "$BRIEFS_M" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-cell-budget 2 \
  >"$WORK/zhm.out" 2>"$WORK/zhm.err"
RCM=$?
if [ "$RCM" -eq 0 ] && python3 - "$OUTM" <<'PY'
import sys, os, json
out = sys.argv[1]
lines = [l for l in open(os.path.join(out, "map", "scope.tsv"), encoding="utf-8").read().splitlines()
         if l.strip() and not l.startswith("#")]
subs = [l.split("|")[0].strip() for l in lines]
assert subs.count("vault") == 2, "the fixture did not produce two scope lines with one name: %r" % subs
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
by_id = dict((z["id"], z) for z in rec["zones"])
v1 = by_id["contracts_v1"]
assert v1["status"] == "budget_unenforceable", "the unenforceable cap produced %r" % v1["status"]
assert v1["budget_truncated"] is False, "an unenforceable cap was recorded as a truncation"
assert "not enforceable" in v1["detail"], "the denial is not explained: %r" % v1["detail"]
# THE INVARIANT: no zone may ever RUN more cells than the budget CHARGED it.
over = [(z["id"], z["cells"], z["cells_charged"]) for z in rec["zones"] if z["cells"] > z["cells_charged"]]
assert not over, "zones ran more cells than they were charged: %r" % over
assert rec["complete"] is False and "contracts_v1" in rec["gap_zones"], "the denied zone is not a gap"
# R2a: unenforceability is a PER-ZONE property, so the sweep must CONTINUE. contracts_solo is 1 cell against
# a cap of 2 — trivially enforceable, unrelated to the mis-named zones, and hunted LAST (non-custody).
solo = by_id["contracts_solo"]
assert solo["status"] in ("hunted", "hunted_empty"), \
    "an unenforceability denial stopped the sweep: contracts_solo is %r" % solo["status"]
assert solo["cells"] == 1, "contracts_solo did not actually run: %r" % solo
# R2b: never claim a run budget was exhausted when there is no run budget.
assert rec["budget"]["run"] == 0, "this case is meant to run with NO --run-cell-budget: %r" % rec["budget"]
liars = [(z["id"], z["detail"]) for z in rec["zones"] if "run cell budget" in (z["detail"] or "")]
assert not liars, "details blame a run budget that does not exist: %r" % liars
PY
then ok "a zone spanning two scope.tsv lines is DENIED as budget_unenforceable, the sweep CONTINUES, and no detail blames a run budget that does not exist"
else bad "the unenforceable-cap assertion failed (exit $RCM)"
fi

# ----------------------------------------------------------------------------------------------------------
# (n) #1830 review finding 4: a FULL re-sweep into an existing --out must not reset `attempts[]` while the
#     `.attempt-<n>` dirs stay on disk — that both un-bounds --rehunt-max-attempts and makes the next re-hunt
#     reuse a suffix that already exists, destroying the preserved evidence. attempts[] is carried over by
#     `init`, and the archive suffix is the first FREE one on disk, never a record-derived counter.
# ----------------------------------------------------------------------------------------------------------
note "n) #1830 a full re-sweep preserves the retry history and never clobbers an archive ..."
# OUT4 already holds one archived attempt for contracts_governance (block i.2).
"$ZONEHUNT" --repo "$REPO" --out "$OUT4" --drop-dir "$OUT4/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB_FAIL" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" \
  >"$WORK/zhn1.out" 2>"$WORK/zhn1.err"
RCN1=$?
if [ "$RCN1" -eq 0 ] && python3 - "$OUT4/coverage/zone-coverage.json" <<'PY'
import sys, json
rec = json.load(open(sys.argv[1], encoding="utf-8"))
g = dict((z["id"], z) for z in rec["zones"])["contracts_governance"]
assert len(g["attempts"]) == 1, "the full re-sweep reset attempts[] to %r" % g["attempts"]
assert g["status"] == "failed", "the re-swept zone is %r" % g["status"]
PY
then ok "a full re-sweep into an existing --out CARRIES attempts[] over (the give-up counter is not reset)"
else bad "the full-re-sweep attempts[] preservation assertion failed (exit $RCN1)"
fi
ATT1_BEFORE="$(ls "$OUT4/discovery/contracts_governance.attempt-1" 2>/dev/null | tr '\n' ',')"
# STUB_FAIL again, so the zone stays a gap and the give-up bound below has something to bind on.
"$ZONEHUNT" --repo "$REPO" --out "$OUT4" --drop-dir "$OUT4/drop" \
  --backend mock --agentis "$STUB_FAIL" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --rehunt-gaps --rehunt-max-attempts 3 \
  >"$WORK/zhn2.out" 2>"$WORK/zhn2.err"
RCN2=$?
ATT1_AFTER="$(ls "$OUT4/discovery/contracts_governance.attempt-1" 2>/dev/null | tr '\n' ',')"
if [ "$RCN2" -eq 0 ] && [ -d "$OUT4/discovery/contracts_governance.attempt-1" ] \
   && [ -d "$OUT4/discovery/contracts_governance.attempt-2" ] \
   && [ "$ATT1_BEFORE" = "$ATT1_AFTER" ] && [ -n "$ATT1_BEFORE" ]; then
  ok "the next re-hunt archives to .attempt-2 — .attempt-1 is untouched, no archive is ever deleted"
else
  bad "the re-hunt clobbered or skipped an archive (exit $RCN2; before='$ATT1_BEFORE' after='$ATT1_AFTER')"
fi
"$ZONEHUNT" --repo "$REPO" --out "$OUT4" --drop-dir "$OUT4/drop" \
  --backend mock --agentis "$STUB" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --rehunt-gaps --rehunt-max-attempts 1 \
  >"$WORK/zhn3.out" 2>"$WORK/zhn3.err"
RCN3=$?
if [ "$RCN3" -eq 0 ] && grep -q 'leaving it alone' "$WORK/zhn3.err" \
   && [ "$(grep -c '\[M3\] hunting zone' "$WORK/zhn3.err")" -eq 0 ]; then
  ok "--rehunt-max-attempts is a REAL bound across re-sweeps: the over-cap zone is left alone, nothing re-hunts"
else
  bad "--rehunt-max-attempts did not bind after a full re-sweep (exit $RCN3)"
fi

# ----------------------------------------------------------------------------------------------------------
# (o) #1830 review residual R1: the merge must union CANDIDATES, not elect a winning cell. "Most candidates
#     wins" still dropped leads in the adjacent case: an attempt that surfaced ONE real lead loses wholesale to
#     a later attempt on the SAME cell that surfaced TWO unrelated ones — silently, with carried_over_cells
#     staying 0. Same bug class as review finding 2, one step narrower.
# ----------------------------------------------------------------------------------------------------------
note "o) #1830 the merge unions candidates per cell — a richer later attempt cannot drop an earlier lead ..."
OUTO="$WORK/zh-candunion"
"$ZONEHUNT" --repo "$REPO" --out "$OUTO" --drop-dir "$OUTO/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-cell-budget 1 \
  >"$WORK/zho1.out" 2>"$WORK/zho1.err"
RCO1=$?
# The re-hunt returns TWO different candidates on the very cell that produced the real lead in pass 1.
DEMO_HUNTER_TWO_LEADS=1 "$ZONEHUNT" --repo "$REPO" --out "$OUTO" --drop-dir "$OUTO/drop" \
  --backend mock --agentis "$STUB" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --rehunt-gaps --rehunt-include-partial --rehunt-max-attempts 3 \
  >"$WORK/zho2.out" 2>"$WORK/zho2.err"
RCO2=$?
if [ "$RCO1" -eq 0 ] && [ "$RCO2" -eq 0 ] && python3 - "$OUTO" <<'PY'
import sys, os, json
out = sys.argv[1]
merged = json.load(open(os.path.join(out, "discovery", "discovery-results.merged.json"), encoding="utf-8"))
cands = [c for cell in merged["cells"] for c in (cell.get("candidates") or [])]
# The pass-1 lead and BOTH pass-2 leads must all be present: no attempt's candidates are ever discarded.
assert any("Vault.sol:deposit:10" in c for c in cands), \
    "the earlier attempt's lead was DROPPED by a richer later attempt: %r" % cands
assert any("Vault.sol:mint:20" in c for c in cands), "a later lead is missing: %r" % cands
assert any("Vault.sol:redeem:30" in c for c in cands), "a later lead is missing: %r" % cands
# The union happens INSIDE one cell entry, so the cell count must not grow.
c1 = [cell for cell in merged["cells"] if cell.get("subsystem") == "vault deposits" and cell.get("class") == "C1"]
assert len(c1) == 1, "the vault/C1 cell was duplicated instead of unioned: %d entries" % len(c1)
assert len(c1[0]["candidates"]) == 3, "the cell holds %r, expected all 3 leads" % c1[0]["candidates"]
assert len(cands) == len(set(cands)), "the union emitted duplicate candidate strings: %r" % cands
# And a partial carry must be as VISIBLE as a whole one.
assert merged["merge"]["carried_over_cells"] >= 1, \
    "a partial carry was silent: carried_over_cells = %r" % merged["merge"]["carried_over_cells"]
PY
then ok "all 3 leads survive (1 from the archived attempt + 2 from the re-hunt) in ONE unioned cell, and the partial carry is counted"
else bad "the candidate-union assertion failed (exit $RCO1/$RCO2)"
fi
if grep -q 'carried over from a prior attempt' "$WORK/zho2.err"; then
  ok "the partial carry is also reported on stderr (not only in the merged file)"
else
  bad "the partial carry was not reported on stderr"
fi

# ----------------------------------------------------------------------------------------------------------
# (p)-(s) #1827 WITHIN-CONTRACT DEPTH. STAGE 3's run-discovery.sh invocation is the thing under test, so it is
#     driven through a SHIM directory: every dark-factory entry point is symlinked into it EXCEPT
#     run-discovery.sh, which is a recorder that appends its argv and then execs the real one. run-zone-hunt.sh
#     resolves its siblings from `dirname $0`, so running the symlinked capstone out of the shim makes the
#     argv observable WITHOUT adding a seam to the shipped script.
# ----------------------------------------------------------------------------------------------------------
note "p) #1827 with --zone-depth-cells absent, STAGE 3's run-discovery.sh argv carries no --depth-max-cells ..."
SHIM="$WORK/shim"
mkdir -p "$SHIM"
for _f in "$HERE"/*; do
  _b="$(basename "$_f")"
  [ "$_b" = "run-discovery.sh" ] && continue
  ln -s "$_f" "$SHIM/$_b"
done
{
  printf '#!/bin/sh\n'
  printf 'printf "%%s\\n" "$*" >> "$DF_ARGV_LOG"\n'
  printf 'exec "$DF_REAL_DISCOVERY" "$@"\n'
} > "$SHIM/run-discovery.sh"
chmod +x "$SHIM/run-discovery.sh"

ARGV_OFF="$WORK/argv-depth-off.log"; : > "$ARGV_OFF"
OUTP="$WORK/zh-depth-off"
DF_ARGV_LOG="$ARGV_OFF" DF_REAL_DISCOVERY="$HERE/run-discovery.sh" \
  "$SHIM/run-zone-hunt.sh" --repo "$REPO" --out "$OUTP" --drop-dir "$OUTP/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" \
  >"$WORK/zhp.out" 2>"$WORK/zhp.err"
RCP=$?
[ "$RCP" -eq 0 ] && ok "the shimmed capstone runs the same chain and exits 0 (the recorder is transparent)" \
  || { bad "the shimmed depth-off run exited $RCP"; sed 's/^/      /' "$WORK/zhp.err" | tail -20 >&2; }
if [ -s "$ARGV_OFF" ] && ! grep -q -- '--depth-max-cells' "$ARGV_OFF" \
   && ! grep -q -- '--depth-lens-quota' "$ARGV_OFF"; then
  ok "p) not one recorded run-discovery.sh invocation (hunt or --list-cells probe) carries --depth-max-cells or --depth-lens-quota"
else
  bad "p) a --depth-max-cells / --depth-lens-quota argument appeared with the depth flags absent (or nothing was recorded)"
fi

# ----------------------------------------------------------------------------------------------------------
# (r) HONEST CHARGE, with the fixture's per-zone breadth counts (liquidation 2, vault 3, governance 2,
#     oracle 2). At --zone-depth-cells 2 with NO budget every zone is charged its planned breadth + 2, and
#     `contracts_governance` — whose cells all answer SAFE — proves the cap is charged UP FRONT: charged 4,
#     spent 2. Undercounting depth to look cheap is exactly the failure this design refuses.
# ----------------------------------------------------------------------------------------------------------
note "r) #1827 cells_charged = breadth + depth; a lead-less zone still shows the cap charged, 0 spent ..."
ARGV_ON="$WORK/argv-depth-on.log"; : > "$ARGV_ON"
OUTR="$WORK/zh-depth-on"
DF_ARGV_LOG="$ARGV_ON" DF_REAL_DISCOVERY="$HERE/run-discovery.sh" \
  "$SHIM/run-zone-hunt.sh" --repo "$REPO" --out "$OUTR" --drop-dir "$OUTR/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-depth-cells 2 \
  >"$WORK/zhr.out" 2>"$WORK/zhr.err"
RCR=$?
[ "$RCR" -eq 0 ] && ok "the --zone-depth-cells 2 run exits 0" \
  || { bad "the depth-on run exited $RCR"; sed 's/^/      /' "$WORK/zhr.err" | tail -20 >&2; }
if [ "$(grep -c -- '--depth-max-cells 2' "$ARGV_ON")" -eq 4 ]; then
  ok "r) each of the 4 hunted zones was invoked with --depth-max-cells 2 (the --list-cells probes are not)"
else
  bad "r) expected 4 hunt invocations carrying --depth-max-cells 2, got $(grep -c -- '--depth-max-cells 2' "$ARGV_ON")"
fi
# #1850: with the allocation knob UNSET, a depth-on argv is byte-identical to the pre-#1850 one — the default
# lives in run-discovery.sh and is never re-spelled here (two spellings of one default is how they drift).
if ! grep -q -- '--depth-lens-quota' "$ARGV_ON"; then
  ok "r1b) with --zone-depth-lens-quota unset the depth-on argv gains no --depth-lens-quota (run-discovery.sh owns the default)"
else
  bad "r1b) an unset --zone-depth-lens-quota still forwarded --depth-lens-quota into the STAGE 3 argv"
fi
if python3 - "$OUTR" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
by_id = dict((z["id"], z) for z in rec["zones"])
# planned breadth per zone stays what --list-cells measured; the charge gains the depth CAP.
want_planned = {"contracts_liquidation": 2, "contracts_vault": 3, "contracts_governance": 2, "contracts_oracle": 2}
for zid, planned in want_planned.items():
    z = by_id[zid]
    assert z["cells_planned"] == planned, "%s cells_planned %r != %r" % (zid, z["cells_planned"], planned)
    assert z["cells_charged"] == planned + 2, "%s charged %r, expected breadth %d + depth 2" % (
        zid, z["cells_charged"], planned)
    assert "depth" in (z.get("detail") or ""), "%s detail does not name the breadth/depth split: %r" % (
        zid, z.get("detail"))
# The zone whose breadth cells all answered SAFE spends NOTHING on depth, yet is still charged the cap.
gov = by_id["contracts_governance"]
assert gov["cells"] == 2, "the lead-less zone ran %r cells, expected only its 2 breadth cells" % gov["cells"]
assert gov["cells"] < gov["cells_charged"], "the up-front cap charge is not visible on the lead-less zone"
# Zones WITH a lead really spent depth cells, and each zone's own results file reports the split.
for zid, planned, spent in (("contracts_liquidation", 2, 4), ("contracts_vault", 3, 5), ("contracts_oracle", 2, 4)):
    d = json.load(open(os.path.join(out, "discovery", zid, "discovery-results.json"), encoding="utf-8"))
    assert d["totals"]["cells"] == spent, "%s ran %r cells, expected %d" % (zid, d["totals"]["cells"], spent)
    assert d["totals"]["depth_cells"] == spent - planned, "%s depth_cells %r" % (zid, d["totals"]["depth_cells"])
    depth = [c for c in d["cells"] if c.get("phase") == "depth"]
    assert len(depth) == spent - planned, "%s phase-tagged %d of %d depth cells" % (zid, len(depth), spent - planned)
    for c in depth:
        assert "@" in c["files"], "%s depth cell payload is not narrowed to file@fn: %r" % (zid, c["files"])
gd = json.load(open(os.path.join(out, "discovery", "contracts_governance", "discovery-results.json"), encoding="utf-8"))
assert gd["totals"]["depth_cells"] == 0, "the lead-less zone spent %r depth cell(s)" % gd["totals"]["depth_cells"]
assert rec["complete"] is True, "the depth-on sweep is not complete"
PY
then ok "r) every zone charged breadth+2 with the split in its detail; leads spend depth cells, the lead-less zone spends 0 while still charged the cap"
else bad "r) the depth charge/accounting assertion failed"
fi
# The capstone's downstream stages are untouched by depth: the same 3 findings still verify.
if python3 - "$OUTR/verify/verified_findings.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["totals"]["verified"] == 3, "depth changed the verified finding count: %r" % d["totals"]["verified"]
PY
then ok "r2) the depth pass did not perturb STAGE 4: the same 3 findings verify"
else bad "r2) the depth pass changed the verified finding set"
fi

# ----------------------------------------------------------------------------------------------------------
# (q) DEPTH GIVES WAY FIRST. Two arms of the same budget interaction:
#     q1 `--zone-cell-budget 4 --zone-depth-cells 2`: only `vault deposits` (3 planned) has less than 2 cells
#        of headroom, so its depth allowance shrinks to 1 while its breadth CLASS LIST IS UNTOUCHED.
#     q2 `--zone-cell-budget 2 --zone-depth-cells 2`: no zone has ANY headroom, so depth is 0 everywhere and
#        the existing class-truncation path runs EXACTLY as it does with depth off (block (g)'s OUT6 run) —
#        same classes, same charge, same budget_truncated flag, and no --depth-max-cells in the argv.
# ----------------------------------------------------------------------------------------------------------
note "q) #1827 under a cell budget, depth is trimmed BEFORE a single breadth class is dropped ..."
OUTQ1="$WORK/zh-depth-q1"
"$ZONEHUNT" --repo "$REPO" --out "$OUTQ1" --drop-dir "$OUTQ1/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-cell-budget 4 --zone-depth-cells 2 \
  >"$WORK/zhq1.out" 2>"$WORK/zhq1.err"
RCQ1=$?
if [ "$RCQ1" -eq 0 ] && python3 - "$OUTQ1" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
by_id = dict((z["id"], z) for z in rec["zones"])
# Every zone stays under the cap of 4, and NONE is class-truncated: depth absorbed the whole squeeze.
for z in rec["zones"]:
    assert z["cells_charged"] <= 4, "%s charged %r over the cap of 4" % (z["id"], z["cells_charged"])
    assert z["budget_truncated"] is False, "%s dropped a breadth class while depth was still on" % z["id"]
v = by_id["contracts_vault"]
assert v["cells_planned"] == 3 and v["cells_charged"] == 4, \
    "the squeezed zone charged %r of %r planned" % (v["cells_charged"], v["cells_planned"])
assert v["classes_hunted"] == ["C1", "C6", "C11"], "the squeezed zone's class list was shortened: %r" % v["classes_hunted"]
d = json.load(open(os.path.join(out, "discovery", "contracts_vault", "discovery-results.json"), encoding="utf-8"))
assert d["totals"]["depth_cells"] == 1, "the squeezed zone got %r depth cells, expected the 1 cell of headroom" % d["totals"]["depth_cells"]
PY
then ok "q1) at cap 4 the squeezed zone keeps ALL 3 breadth classes and its depth allowance shrinks 2 -> 1"
else bad "q1) the depth-shrinks-first assertion failed (exit $RCQ1)"
fi
ARGV_Q2="$WORK/argv-depth-q2.log"; : > "$ARGV_Q2"
OUTQ2="$WORK/zh-depth-q2"
DF_ARGV_LOG="$ARGV_Q2" DF_REAL_DISCOVERY="$HERE/run-discovery.sh" \
  "$SHIM/run-zone-hunt.sh" --repo "$REPO" --out "$OUTQ2" --drop-dir "$OUTQ2/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-cell-budget 2 --zone-depth-cells 2 \
  >"$WORK/zhq2.out" 2>"$WORK/zhq2.err"
RCQ2=$?
# The DEPTH-OFF twin of the same run (block (g)'s zh6 --out is mutated by the (i.2) re-hunt, so this needs
# its own baseline). The truncation path must be indistinguishable from it on every substantive field.
# (`detail` additionally names the trimmed depth pass; that is the whole point of trimming visibly.)
OUTQ2OFF="$WORK/zh-depth-q2-off"
"$ZONEHUNT" --repo "$REPO" --out "$OUTQ2OFF" --drop-dir "$OUTQ2OFF/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-cell-budget 2 \
  >"$WORK/zhq2off.out" 2>"$WORK/zhq2off.err"
if [ "$RCQ2" -eq 0 ] && ! grep -q -- '--depth-max-cells' "$ARGV_Q2" && python3 - "$OUTQ2" "$OUTQ2OFF" <<'PY'
import sys, os, json
def rec(p):
    return json.load(open(os.path.join(p, "coverage", "zone-coverage.json"), encoding="utf-8"))
on, off = rec(sys.argv[1]), rec(sys.argv[2])
fields = ("id", "status", "cells_planned", "cells_charged", "classes_hunted", "budget_truncated", "cells")
a = [tuple(z[f] if not isinstance(z[f], list) else tuple(z[f]) for f in fields) for z in on["zones"]]
b = [tuple(z[f] if not isinstance(z[f], list) else tuple(z[f]) for f in fields) for z in off["zones"]]
assert a == b, "the truncation path diverged with depth on:\n  on  = %r\n  off = %r" % (a, b)
assert on["complete"] == off["complete"] and on["gap_zones"] == off["gap_zones"], "derived fields diverged"
for z in on["zones"]:
    assert "trimmed to 0" in (z.get("detail") or ""), "%s does not record that depth was trimmed: %r" % (
        z["id"], z.get("detail"))
PY
then ok "q2) with no headroom, depth is 0, the argv gains nothing, and the class-truncation path matches the depth-off run field for field"
else bad "q2) the no-headroom truncation path diverged from the depth-off run (exit $RCQ2)"
fi

# ----------------------------------------------------------------------------------------------------------
# (s) NO DOUBLE CHARGE across a re-hunt: a zone's cells_charged is the cost of ONE attempt (breadth + the
#     depth cap), rewritten per attempt — never accumulated into a number that grows with attempts[].
# ----------------------------------------------------------------------------------------------------------
note "s) #1827 a --rehunt-gaps pass with depth on never charges a zone more than one attempt ..."
OUTS="$WORK/zh-depth-rehunt"
"$ZONEHUNT" --repo "$REPO" --out "$OUTS" --drop-dir "$OUTS/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --run-cell-budget 8 --zone-depth-cells 2 \
  >"$WORK/zhs1.out" 2>"$WORK/zhs1.err"
RCS1=$?
"$ZONEHUNT" --repo "$REPO" --out "$OUTS" --drop-dir "$OUTS/drop" \
  --backend mock --agentis "$STUB" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --rehunt-gaps --run-cell-budget 8 --zone-depth-cells 2 \
  >"$WORK/zhs2.out" 2>"$WORK/zhs2.err"
RCS2=$?
if [ "$RCS1" -eq 0 ] && [ "$RCS2" -eq 0 ] && python3 - "$OUTS" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
denied = [z["id"] for z in rec["zones"] if z["status"] == "budget_exhausted"]
assert not denied, "the re-hunt left %r denied" % denied
assert rec["complete"] is True, "the re-hunt did not complete the record"
for z in rec["zones"]:
    # ONE attempt's cost, never a running total: breadth + at most the depth cap.
    assert z["cells_charged"] <= z["cells_planned"] + 2, \
        "%s charged %r, more than one attempt of %r breadth + 2 depth" % (z["id"], z["cells_charged"], z["cells_planned"])
    assert z["cells"] <= z["cells_planned"] + 2, "%s ran %r cells, more than one attempt" % (z["id"], z["cells"])
PY
then ok "s) the re-hunt completes the record and no zone is charged (or runs) more than one attempt's breadth + depth"
else bad "s) the re-hunt double-charged or failed to complete (exit $RCS1/$RCS2)"
fi

# ----------------------------------------------------------------------------------------------------------
# (t) #1850 ALLOCATION FORWARDING. `--zone-depth-lens-quota 2` must reach EVERY hunted zone as
#     `--depth-lens-quota 2` (never the --list-cells probes, which enumerate breadth only), be recorded in the
#     coverage detail AND in each zone's own totals, and change NOTHING about cost: the charge is still
#     breadth + the depth cap, exactly as block (r) pins it with the knob unset. An allocation that quietly
#     moved the charge would make the two A/B arms non-comparable, which is the whole point of the knob.
#     The quota under test is deliberately NOT run-discovery.sh's default of 3: a zone would record a 3 even
#     with the forwarding removed, so a 3 here would make the totals assertion vacuous.
# ----------------------------------------------------------------------------------------------------------
note "t) #1850 --zone-depth-lens-quota reaches every hunted zone and does not move the charge ..."
ARGV_T="$WORK/argv-depth-quota.log"; : > "$ARGV_T"
OUTT="$WORK/zh-depth-quota"
DF_ARGV_LOG="$ARGV_T" DF_REAL_DISCOVERY="$HERE/run-discovery.sh" \
  "$SHIM/run-zone-hunt.sh" --repo "$REPO" --out "$OUTT" --drop-dir "$OUTT/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-depth-cells 2 --zone-depth-lens-quota 2 \
  >"$WORK/zht.out" 2>"$WORK/zht.err"
RCT=$?
[ "$RCT" -eq 0 ] && ok "the --zone-depth-cells 2 --zone-depth-lens-quota 2 run exits 0" \
  || { bad "the quota run exited $RCT"; sed 's/^/      /' "$WORK/zht.err" | tail -20 >&2; }
if [ "$(grep -c -- '--depth-lens-quota 2' "$ARGV_T")" -eq 4 ]; then
  ok "t) each of the 4 hunted zones was invoked with --depth-lens-quota 2 (the --list-cells probes are not)"
else
  bad "t) expected 4 hunt invocations carrying --depth-lens-quota 2, got $(grep -c -- '--depth-lens-quota 2' "$ARGV_T")"
fi
if python3 - "$OUTT" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
by_id = dict((z["id"], z) for z in rec["zones"])
want_planned = {"contracts_liquidation": 2, "contracts_vault": 3, "contracts_governance": 2, "contracts_oracle": 2}
for zid, planned in want_planned.items():
    z = by_id[zid]
    # The allocation is an ORDERING, never a cost: the charge is byte-identical to block (r)'s.
    assert z["cells_charged"] == planned + 2, "%s charged %r, expected breadth %d + depth 2" % (
        zid, z["cells_charged"], planned)
    assert "lens quota 2" in (z.get("detail") or ""), "%s detail does not name the quota: %r" % (
        zid, z.get("detail"))
for zid in want_planned:
    d = json.load(open(os.path.join(out, "discovery", zid, "discovery-results.json"), encoding="utf-8"))
    assert d["totals"]["depth_lens_quota"] == 2, "%s totals.depth_lens_quota %r" % (
        zid, d["totals"].get("depth_lens_quota"))
assert rec["complete"] is True, "the quota sweep is not complete"
PY
then ok "t2) every zone records the quota in its coverage detail and in totals.depth_lens_quota, and the charge is unchanged (breadth + the depth cap)"
else bad "t2) the quota record / charge assertion failed"
fi
badflag "--zone-depth-cells notanumber" 'must be a non-negative integer' --zone-depth-cells notanumber
badflag "--zone-depth-lens-quota notanumber" "must be a positive integer (got 'notanumber')" --zone-depth-lens-quota notanumber
badflag "--zone-depth-lens-quota 0" "must be >= 1 (got '0')" --zone-depth-lens-quota 0

# ----------------------------------------------------------------------------------------------------------
# (v) #1880 TOTAL DEPTH BUDGET. `--zone-depth-cells` is a PER-ZONE maximum, so the sweep admits depth x zone
#     count cells and a many-zone contest silently costs a multiple of what the flag reads. The ceiling lowers
#     the per-zone allowance to min(--zone-depth-cells, N / zone count) uniformly, and is INERT when absent.
#     The fixture's four zones (breadth 2/3/2/2) make the arithmetic checkable by hand.
# ----------------------------------------------------------------------------------------------------------
note "v1) #1880 --total-depth-cells 8 over 4 zones scales the per-zone depth allowance 3 -> 2 ..."
ARGV_V1="$WORK/argv-total-depth-v1.log"; : > "$ARGV_V1"
OUTV1="$WORK/zh-total-depth-v1"
DF_ARGV_LOG="$ARGV_V1" DF_REAL_DISCOVERY="$HERE/run-discovery.sh" \
  "$SHIM/run-zone-hunt.sh" --repo "$REPO" --out "$OUTV1" --drop-dir "$OUTV1/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-depth-cells 3 --total-depth-cells 8 \
  >"$WORK/zhv1.out" 2>"$WORK/zhv1.err"
RCV1=$?
[ "$RCV1" -eq 0 ] && ok "the --zone-depth-cells 3 --total-depth-cells 8 run exits 0" \
  || { bad "the #1880 scaling run exited $RCV1"; sed 's/^/      /' "$WORK/zhv1.err" | tail -20 >&2; }
# 8 / 4 = 2 — deliberately neither the nominal 3 nor 0, so neither "the flag was ignored" nor "depth was
# switched off" can satisfy this assertion.
if [ "$(grep -c -- '--depth-max-cells 2' "$ARGV_V1")" -eq 4 ] && ! grep -q -- '--depth-max-cells 3' "$ARGV_V1"; then
  ok "v1) all 4 hunted zones were invoked with the SCALED --depth-max-cells 2, and never with the nominal 3"
else
  bad "v1) expected 4 hunt invocations at the scaled --depth-max-cells 2, got $(grep -c -- '--depth-max-cells 2' "$ARGV_V1")"
fi
if python3 - "$OUTV1" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
want_planned = {"contracts_liquidation": 2, "contracts_vault": 3, "contracts_governance": 2, "contracts_oracle": 2}
spent = 0
for z in rec["zones"]:
    planned = want_planned[z["id"]]
    assert z["cells_planned"] == planned, "%s cells_planned %r != %r" % (z["id"], z["cells_planned"], planned)
    assert z["cells_charged"] == planned + 2, "%s charged %r, expected breadth %d + the scaled depth 2" % (
        z["id"], z["cells_charged"], planned)
    assert "scaled from 3" in (z.get("detail") or ""), "%s detail does not name the scaling: %r" % (
        z["id"], z.get("detail"))
    spent += z["cells_charged"] - planned
# The whole point: the SWEEP's depth charge is bounded by the ceiling, not by the per-zone flag.
assert spent == 8, "the sweep charged %r depth cell(s), expected the full ceiling of 8" % spent
assert rec["budget"]["depth_total"] == 8, "budget.depth_total %r" % rec["budget"].get("depth_total")
assert rec["budget"]["depth_per_zone"] == 2, "budget.depth_per_zone %r" % rec["budget"].get("depth_per_zone")
assert rec["complete"] is True, "the #1880-scaled sweep is not complete"
PY
then ok "v1) every zone charged breadth + the SCALED 2, the sweep's depth charge is exactly the 8-cell ceiling, and the record carries budget.depth_total/depth_per_zone"
else bad "v1) the #1880 scaling / accounting assertion failed"
fi

note "v2) #1880 a ceiling below the zone count gives 0 depth everywhere, with its OWN cause in the detail ..."
ARGV_V2="$WORK/argv-total-depth-v2.log"; : > "$ARGV_V2"
OUTV2="$WORK/zh-total-depth-v2"
DF_ARGV_LOG="$ARGV_V2" DF_REAL_DISCOVERY="$HERE/run-discovery.sh" \
  "$SHIM/run-zone-hunt.sh" --repo "$REPO" --out "$OUTV2" --drop-dir "$OUTV2/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-depth-cells 3 --total-depth-cells 3 \
  >"$WORK/zhv2.out" 2>"$WORK/zhv2.err"
RCV2=$?
# The DEPTH-OFF twin of the same sweep: with the allowance at 0 the run must be indistinguishable from one
# that never asked for depth at all (the (q2) comparison idiom, on the same fields).
OUTV2OFF="$WORK/zh-total-depth-v2-off"
"$ZONEHUNT" --repo "$REPO" --out "$OUTV2OFF" --drop-dir "$OUTV2OFF/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-depth-cells 0 \
  >"$WORK/zhv2off.out" 2>"$WORK/zhv2off.err"
if [ "$RCV2" -eq 0 ] && ! grep -q -- '--depth-max-cells' "$ARGV_V2" && python3 - "$OUTV2" "$OUTV2OFF" <<'PY'
import sys, os, json
def rec(p):
    return json.load(open(os.path.join(p, "coverage", "zone-coverage.json"), encoding="utf-8"))
on, off = rec(sys.argv[1]), rec(sys.argv[2])
fields = ("id", "status", "cells_planned", "cells_charged", "classes_hunted", "budget_truncated", "cells")
a = [tuple(z[f] if not isinstance(z[f], list) else tuple(z[f]) for f in fields) for z in on["zones"]]
b = [tuple(z[f] if not isinstance(z[f], list) else tuple(z[f]) for f in fields) for z in off["zones"]]
assert a == b, "the zeroed-depth sweep diverged from the depth-off one:\n  on  = %r\n  off = %r" % (a, b)
assert on["complete"] == off["complete"] and on["gap_zones"] == off["gap_zones"], "derived fields diverged"
for z in on["zones"]:
    detail = z.get("detail") or ""
    # The two causes of "depth 0" must stay distinguishable: this one is the sweep-level ceiling, NOT the
    # per-zone cell-budget headroom trim (which this run never sets).
    assert "total depth budget" in detail, "%s does not name the total-budget cause: %r" % (z["id"], detail)
    assert "no headroom" not in detail, "%s blames the cell budget for a total-budget trim: %r" % (z["id"], detail)
assert on["budget"]["depth_per_zone"] == 0, "budget.depth_per_zone %r" % on["budget"].get("depth_per_zone")
PY
then ok "v2) 3 cells over 4 zones admits no depth at all: no --depth-max-cells in the argv, the record matches the depth-off twin field for field, and the detail names the TOTAL budget (not the cell-budget headroom)"
else bad "v2) the below-zone-count ceiling assertion failed (exit $RCV2)"
fi

note "v3) #1880 with --total-depth-cells absent, depth is exactly what #1827 shipped and budget gains no keys ..."
ARGV_V3="$WORK/argv-total-depth-v3.log"; : > "$ARGV_V3"
OUTV3="$WORK/zh-total-depth-v3"
DF_ARGV_LOG="$ARGV_V3" DF_REAL_DISCOVERY="$HERE/run-discovery.sh" \
  "$SHIM/run-zone-hunt.sh" --repo "$REPO" --out "$OUTV3" --drop-dir "$OUTV3/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --zone-depth-cells 3 \
  >"$WORK/zhv3.out" 2>"$WORK/zhv3.err"
RCV3=$?
if [ "$RCV3" -eq 0 ] && [ "$(grep -c -- '--depth-max-cells 3' "$ARGV_V3")" -eq 4 ] && python3 - "$OUTV3" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
# THE INERTNESS PIN: with the ceiling off the record's budget object is byte-identical to a pre-#1880 one —
# no depth_total, no depth_per_zone. (Block (f) pins the same dict on the depth-OFF default path.)
assert rec["budget"] == {"unit": "cells", "per_zone": 0, "run": 0}, \
    "the depth-on record gained #1880 keys with the ceiling off: %r" % rec["budget"]
for z in rec["zones"]:
    assert "#1880" not in (z.get("detail") or ""), "%s detail mentions the ceiling with it off: %r" % (
        z["id"], z.get("detail"))
PY
then ok "v3) with the ceiling absent every zone keeps the nominal --depth-max-cells 3 and the record's budget object gains NO depth keys"
else bad "v3) the #1880-off inertness assertion failed (exit $RCV3)"
fi

badflag "--total-depth-cells notanumber" 'must be a non-negative integer' \
  --zone-depth-cells 3 --total-depth-cells notanumber
badflag "--total-depth-cells without --zone-depth-cells" 'a total depth ceiling with depth off is a no-op' \
  --total-depth-cells 8

# ----------------------------------------------------------------------------------------------------------
# (w) #1930 FINDING-LEVEL PAYABILITY GATE. The offline capstone's hunter stub yields exactly one MEDIUM
#     candidate (OOSCOPE/Thing.sol:foo:1) alongside two HIGH ones, and all three are verified — so
#     --pay-floor high has a real, uniquely-identifiable sub-floor finding to gate. THE POINT: a Medium lead on
#     a program whose rewards table starts at High earns $0, so it must not consume an audit pass, a staged
#     draft or a human review — while the verification record itself stays intact for corpus-bench/dashboard
#     readers.
# ----------------------------------------------------------------------------------------------------------
note "w) #1930 --pay-floor high keeps the Medium finding out of delivery without touching the verify record ..."
OUTW="$WORK/zh-pay-floor"
"$ZONEHUNT" --repo "$REPO" --out "$OUTW" --drop-dir "$OUTW/drop" --scope-hint contracts \
  --backend mock --agentis "$STUB" \
  --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" --pay-floor high \
  >"$WORK/zhw.out" 2>"$WORK/zhw.err"
RCW=$?
[ "$RCW" -eq 0 ] && ok "w) the --pay-floor high run exits 0" \
  || { bad "w) the --pay-floor run exited $RCW"; sed 's/^/      /' "$WORK/zhw.err" | tail -20 >&2; }

if python3 - "$OUTW" <<'PY'
import sys, os, json
out = sys.argv[1]
ver = os.path.join(out, "verify")
gated_path = os.path.join(ver, "verified_findings.payable.json")
assert os.path.isfile(gated_path), "the gate wrote no verified_findings.payable.json"
gated = json.load(open(gated_path, encoding="utf-8"))
unpay = {v["location"] for v in gated.get("unpayable", [])}
kept = {v["location"] for v in gated.get("verified", [])}
assert "OOSCOPE/Thing.sol:foo:1" in unpay, "the Medium finding is not in unpayable[]: %r" % unpay
assert kept == {"contracts/vault/Vault.sol:deposit:10", "EXPLODE/Boom.sol:bang:1"}, \
    "the payable set is wrong: %r" % kept
assert gated["pay_floor"] == "high", "pay_floor %r" % gated.get("pay_floor")
assert gated["totals"]["verified"] == 2 and gated["totals"]["unpayable"] == 1, "totals %r" % gated["totals"]
# THE INVARIANT: the verification record itself is UNTOUCHED — only DELIVERY is narrowed.
raw = json.load(open(os.path.join(ver, "verified_findings.json"), encoding="utf-8"))
assert raw["totals"]["verified"] == 3, "verified_findings.json was rewritten by the gate: %r" % raw["totals"]
assert "unpayable" not in raw and "pay_floor" not in raw, "the gate leaked keys into verified_findings.json"
assert all("pay_verdict" not in v for v in raw["verified"]), "the gate annotated verified_findings.json in place"
PY
then ok "w) the Medium finding is moved to unpayable[] of verify/verified_findings.payable.json; verify/verified_findings.json is UNCHANGED"
else bad "w) the pay-gate artifact assertion failed"
fi

# The sub-floor finding gets NO audit pass and NO staged draft — the whole point of gating before STAGE 5.
if [ ! -d "$OUTW/audit-pass/OOSCOPE-Thing-sol-foo-1" ] \
   && ! ls -d "$OUTW/drop"/*OOSCOPE* >/dev/null 2>&1 && ! ls -d "$OUTW/drop"/*Thing* >/dev/null 2>&1; then
  ok "w) the unpayable Medium finding gets NO audit-pass dir and NO staged draft (no human review spent on \$0)"
else
  bad "w) the unpayable Medium finding still consumed an audit pass / staged a draft"
fi
# The payable findings keep their shipped behaviour exactly (one delivered, one per-finding failure).
if grep -q 'delivered (staged, PENDING HUMAN REVIEW): 1' "$WORK/zhw.err" \
   && grep -q 'per-finding failures (skipped): 1' "$WORK/zhw.err" \
   && grep -q '2 verified finding(s)' "$WORK/zhw.err"; then
  ok "w) the two payable findings keep their shipped behaviour (1 delivered, 1 per-finding failure)"
else
  bad "w) the payable findings' delivery behaviour changed under the gate"
fi
# The drop must be VISIBLE: a silently shorter banner is the same defect #1830 fixed for zone coverage.
if grep -q '\[pay-gate\] payable 2, unpayable 1 (floor=high, mode=drop)' "$WORK/zhw.err"; then
  ok "w) the run names the drop on stderr ([pay-gate] payable 2, unpayable 1)"
else
  bad "w) no [pay-gate] summary line on stderr:"; grep -i 'pay-gate' "$WORK/zhw.err" | sed 's/^/      /' >&2
fi
# The briefs carry the floor, so the hunter is steered by the same number that gates the delivery.
if grep -q 'Pay floor: HIGH' "$OUTW/briefs/briefs/brief_contracts_vault.md" 2>/dev/null; then
  ok "w) --pay-floor also reaches STAGE 2: the zone briefs state the floor"
else
  bad "w) the zone briefs do not carry the pay floor"
fi

badflag "--pay-floor notaseverity" 'must be one of critical|high|medium|low' --pay-floor notaseverity
badflag "--pay-mode without --pay-floor" 'a finding pay mode with no floor is a no-op' --pay-mode flag

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — M5 capstone (run-zone-hunt.sh: map -> brief -> discovery -> verify -> audit-pass -> deliver, HALT) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
