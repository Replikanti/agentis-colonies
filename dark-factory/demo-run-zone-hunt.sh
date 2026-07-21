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
        s="${SUBSYSTEM:-}"; c="${HUNT_CLASS:-}"
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
if [ "$FAILS" -eq 0 ]; then
  note "PASS — M5 capstone (run-zone-hunt.sh: map -> brief -> discovery -> verify -> audit-pass -> deliver, HALT) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
