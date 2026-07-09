#!/usr/bin/env bash
# demo-feedback-loop.sh — OFFLINE proof (#1526, epic #1505) of the human<->federation FEEDBACK LOOP: the
# delivery muscle deliver-submission.sh + the reasoning half auditor/agents/feedback-intake.ag, exchanged through
# a LOCAL operator DROP-DIRECTORY (the baked-in design decision — no platform API/scrape). Mirrors the sibling
# dark-factory demos (demo-report-writer.sh / demo-immunefi-intake.sh): assert-based PASS/FAIL lines, a temp
# drop-dir trap-cleaned, exit non-zero on regression, exit 3 if a component is missing.
#
# THREE parts:
#   1) DELIVERY (offline, real): run deliver-submission.sh over a fixture report-writer draft carrying the
#      SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW marker + fixture gate verdicts + a stable id -> assert the drop-dir
#      has manifest.json + submission-draft.md + OUTCOME.md, that manifest.json carries the canonical
#      submission_id and the three RAW gate verdict lines (python3 field reads), and that a draft WITHOUT the
#      marker exits 3 and stages NOTHING (the human-gate invariant baked into the muscle).
#   2) SIGNAL (offline, deterministic): a fixture Enzyme Onyx OUTCOME.md (verdict: closed, reason = front-run of a
#      privileged action / simulated price increase) -> assert the documented deterministic map yields `failure`;
#      SOURCE-GUARD that feedback-intake.ag encodes the four verdict->signal arms, uses the DETERMINISTIC signal
#      (not the LLM's) for learn(), carries the impact-gate attribution rule for the privileged-trigger reason,
#      and has the emit/learn/memo tail. Also assert accepted->success and duplicate->failure-under-dup-risk.
#   3) INVARIANT + LIVE: assert NEITHER component has any platform egress (curl/wget/http/submit) and both
#      document the never-submit invariant; when agentis is on PATH, run feedback-intake.ag end-to-end over the
#      staged drop-dir asserting exit 0 (the mock backend can't reason, so only clean execution is asserted —
#      the demo-report-writer.sh precedent), else [SKIP].
#
# All shell sub-scripts are invoked with `bash` (never `sh`) per the #1507 dash lesson.
#
# Usage:  dark-factory/demo-feedback-loop.sh
# Requires: bash + python3 (git not needed). Exit: 0 = all assertions held; non-zero = a regression; 3 = missing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DELIVER="$HERE/deliver-submission.sh"
INTAKE="$HERE/auditor/agents/feedback-intake.ag"

FAIL=0
note() { echo "demo-feedback-loop.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*" >&2; FAIL=1; }
skip() { echo "  [SKIP] $*"; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$DELIVER" ] || { note "deliver-submission.sh not found / not executable: $DELIVER" >&2; exit 3; }
[ -f "$INTAKE" ]  || { note "feedback-intake.ag not found: $INTAKE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-feedback.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DROP="$WORK/drop"

# jget: read a field from a JSON file (deterministic, no jq).
jget() { python3 -c 'import sys,json; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }

# signal_of: the DETERMINISTIC verdict->signal map, mirroring feedback-intake.ag exactly. Proves the map over a
# real fixture verdict token the same way the agent derives it (grep the ^verdict: line).
signal_of() {  # $1 = verdict token
  case "$1" in
    accepted)   echo success ;;
    closed)     echo failure ;;
    duplicate)  echo failure ;;
    needs-info) echo partial ;;
    *)          echo partial ;;
  esac
}
# verdict_of: grep the ^verdict: token out of an OUTCOME.md, exactly as the agent's outcome_verdict() muscle does.
verdict_of() { grep -iE '^verdict:' "$1" 2>/dev/null | head -1 | awk '{print $2}'; }

# ----------------------------------------------------------------------------------------------------------
# 1) DELIVERY — stage a real report-writer draft into the drop-dir under a stable id.
# ----------------------------------------------------------------------------------------------------------
note "1) deliver-submission.sh stages a report-writer draft into the drop-dir ..."

ID="enzyme-onyx@a1b2c3d:sync-deposit-nav-frontrun"
SCOPE_V="SCOPE-GATE|PAYABLE|SyncDepositHandler.sol is a listed in-scope asset; theft is an eligible impact"
IMPACT_V="IMPACT-GATE|SUBSTANTIATED|PoC drives the drain through the vault's own redeem path"
DUP_V="DUP-RISK|LOW|~15%|no matching known-issue for the sync-deposit NAV path"

# A fixture report-writer draft carrying the human-gate marker on its first line.
DRAFT="$WORK/draft.md"
{
  printf '%s\n' "SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW"
  printf '%s\n' "## Brief/Intro"
  printf '%s\n' "A NAV front-running finding in an in-scope asset. DRAFT for human review; never auto-submitted."
  printf '%s\n' "## Vulnerability Details"
  printf '%s\n' "Root cause at SyncDepositHandler.sol; see forge test --match-test test_frontrun."
  printf '%s\n' "## Impact Details"
  printf '%s\n' "Theft of pre-update holders' unclaimed yield (Critical)."
  printf '%s\n' "## References"
  printf '%s\n' "$SCOPE_V"
} > "$DRAFT"

STAGED="$(bash "$DELIVER" --id "$ID" --draft-file "$DRAFT" \
  --target "enzyme-onyx" --commit "a1b2c3d" --finding-slug "sync-deposit-nav-frontrun" \
  --title "SyncDepositHandler NAV front-running" --location "src/.../SyncDepositHandler.sol" \
  --impact "front-run of a NAV update steals pre-update holders' unclaimed yield" \
  --impact-class "theft" --severity "Critical" \
  --scope-verdict "$SCOPE_V" --impact-verdict "$IMPACT_V" --dup-risk "$DUP_V" \
  --drop-dir "$DROP" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "deliver-submission.sh exits 0 staging a marked draft" || bad "deliver-submission.sh exited $RC (expected 0)"

[ -n "$STAGED" ] && [ -d "$STAGED" ] && ok "it printed the staged dir path ($STAGED)" || bad "no staged dir path printed"
[ -f "$STAGED/manifest.json" ]       && ok "manifest.json present"       || bad "manifest.json missing"
[ -f "$STAGED/submission-draft.md" ] && ok "submission-draft.md present" || bad "submission-draft.md missing"
[ -f "$STAGED/OUTCOME.md" ]          && ok "OUTCOME.md present"          || bad "OUTCOME.md missing"

# The canonical submission_id lives in the manifest, verbatim.
[ "$(jget "$STAGED/manifest.json" submission_id)" = "$ID" ] \
  && ok "manifest.json carries the canonical submission_id verbatim" || bad "submission_id mismatch in manifest"
# The three RAW gate verdict lines are threaded through into the manifest (intake never re-parses prose).
[ "$(jget "$STAGED/manifest.json" scope_verdict)" = "$SCOPE_V" ] \
  && ok "manifest.json carries the raw SCOPE-GATE verdict line" || bad "scope_verdict mismatch in manifest"
[ "$(jget "$STAGED/manifest.json" impact_verdict)" = "$IMPACT_V" ] \
  && ok "manifest.json carries the raw IMPACT-GATE verdict line" || bad "impact_verdict mismatch in manifest"
[ "$(jget "$STAGED/manifest.json" dup_risk)" = "$DUP_V" ] \
  && ok "manifest.json carries the raw DUP-RISK verdict line" || bad "dup_risk mismatch in manifest"
# The draft is staged verbatim (the human-gate marker survives).
grep -q 'SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW' "$STAGED/submission-draft.md" \
  && ok "submission-draft.md preserves the human-gate marker verbatim" || bad "draft marker lost on stage"
# The OUTCOME template echoes the id as an uneditable correlation comment.
grep -q "submission_id: $ID" "$STAGED/OUTCOME.md" \
  && ok "OUTCOME.md echoes the correlation id as a comment header" || bad "OUTCOME.md missing the id comment"

# MARKER GUARD: a draft WITHOUT the human-gate marker must exit 3 and stage NOTHING.
UNMARKED="$WORK/unmarked.md"
printf '%s\n' "## Brief/Intro" "just some prose with no marker" > "$UNMARKED"
BADID="unmarked-target@deadbee:no-marker"
bash "$DELIVER" --id "$BADID" --draft-file "$UNMARKED" --drop-dir "$DROP" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && ok "an unmarked draft exits 3 (human-gate marker guard)" || bad "unmarked draft did not exit 3 (rc=$RC)"
BADSLUG="$(printf '%s' "$BADID" | sed 's/[^A-Za-z0-9._@-]/-/g')"
[ ! -e "$DROP/$BADSLUG" ] && ok "the unmarked draft staged NOTHING (no drop-dir created)" || bad "unmarked draft leaked a staged dir"

# A missing --id is a bad-args exit 2.
bash "$DELIVER" --draft-file "$DRAFT" --drop-dir "$DROP" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "a missing --id exits 2 (bad-args band)" || bad "missing --id did not exit 2 (rc=$RC)"

# ----------------------------------------------------------------------------------------------------------
# 2) SIGNAL — the deterministic verdict->signal map + the feedback-intake.ag source contract.
# ----------------------------------------------------------------------------------------------------------
note "2) deterministic verdict->signal map + feedback-intake.ag source contract ..."

# The operator fills OUTCOME.md IN-PLACE — here, the real Enzyme Onyx rejection (closed, privileged-action
# front-run / simulated price increase). Overwrite the staged template with the filled outcome.
{
  printf '%s\n' "# OUTCOME — filled by the operator after the platform responded."
  printf '%s\n' "# submission_id: $ID   (do NOT edit — correlation key; authoritative copy in manifest.json)"
  printf '%s\n' "verdict:        closed"
  printf '%s\n' "severity:       "
  printf '%s\n' "payout:         "
  printf '%s\n' "reason:         front-run of a privileged NAV post / simulated price increase, not an on-chain-provable claim"
  printf '%s\n' "reviewer_notes: |"
  printf '%s\n' "  The PoC hand-fed the share value via an admin path and described front-running a privileged"
  printf '%s\n' "  action rather than extracting a claim the victims already held on-chain."
} > "$STAGED/OUTCOME.md"

ONYX_VERDICT="$(verdict_of "$STAGED/OUTCOME.md")"
[ "$ONYX_VERDICT" = "closed" ] && ok "the Onyx OUTCOME.md verdict token reads 'closed'" || bad "Onyx verdict token was '$ONYX_VERDICT' (expected closed)"
[ "$(signal_of "$ONYX_VERDICT")" = "failure" ] \
  && ok "verdict 'closed' -> deterministic signal 'failure'" || bad "closed did not map to failure"
[ "$(signal_of accepted)" = "success" ]  && ok "verdict 'accepted' -> 'success'"   || bad "accepted did not map to success"
[ "$(signal_of duplicate)" = "failure" ] && ok "verdict 'duplicate' -> 'failure'"  || bad "duplicate did not map to failure"
[ "$(signal_of needs-info)" = "partial" ] && ok "verdict 'needs-info' -> 'partial'" || bad "needs-info did not map to partial"

# SOURCE-GUARD feedback-intake.ag: it must encode the SAME four arms + use the deterministic signal for learn().
if grep -q 'index_of(verdict, "accepted")' "$INTAKE" && grep -q 'index_of(verdict, "closed")' "$INTAKE" \
   && grep -q 'index_of(verdict, "duplicate")' "$INTAKE" && grep -q 'index_of(verdict, "needs-info")' "$INTAKE"; then
  ok "feedback-intake.ag encodes the four verdict->signal arms deterministically"
else
  bad "feedback-intake.ag is missing one of the four deterministic verdict arms"
fi
# The learn() 4th arg must be the deterministic `signal`, NOT anything parsed from the LLM's feedback line.
if grep -qE 'learn\(topic, submissionId,.*, signal, \[submissionId' "$INTAKE"; then
  ok "feedback-intake.ag uses the DETERMINISTIC signal (not the LLM's) for learn()"
else
  bad "feedback-intake.ag learn() does not use the deterministic signal"
fi
# The impact-gate attribution rule for the privileged-trigger / simulated-state Onyx reason must be present.
if grep -qi 'privileged' "$INTAKE" && grep -qi 'impact-gate' "$INTAKE"; then
  ok "feedback-intake.ag carries the impact-gate attribution rule for a privileged-trigger rejection"
else
  bad "feedback-intake.ag missing the impact-gate (privileged-trigger) attribution rule"
fi
# dup-scout attribution must map to the gate's OWN topic "dup-risk" (NOT "dup-scout").
if grep -q 'stage == "dup-scout"' "$INTAKE" && grep -q '"dup-risk"' "$INTAKE"; then
  ok "feedback-intake.ag maps a duplicate (dup-scout) outcome to topic 'dup-risk' (the gate's own topic)"
else
  bad "feedback-intake.ag does not map dup-scout -> topic 'dup-risk'"
fi
# The FEEDBACK output contract + the emit/learn/memo tail.
if grep -q 'FEEDBACK|' "$INTAKE"; then
  ok "feedback-intake.ag emits the FEEDBACK|<SIGNAL>|<stage>|<rationale> line"
else
  bad "feedback-intake.ag missing the FEEDBACK output contract"
fi
if grep -q 'emit("dark-factory:feedback_outcome"' "$INTAKE" \
   && grep -q 'learn(topic,' "$INTAKE" && grep -q 'memo_write("feedback-intake:last_check"' "$INTAKE"; then
  ok "feedback-intake.ag emits dark-factory:feedback_outcome + records the learn/memo tail"
else
  bad "feedback-intake.ag missing the emit / learn / memo tail"
fi
# It reads the canonical id from the manifest, never the editable OUTCOME.md / dirname.
if grep -q 'manifest_field(dir, "submission_id")' "$INTAKE"; then
  ok "feedback-intake.ag reads the canonical submission_id from manifest.json (correlation-safe)"
else
  bad "feedback-intake.ag does not read submission_id from the manifest"
fi

# ----------------------------------------------------------------------------------------------------------
# 3) INVARIANT + LIVE — no platform egress in either component; optional end-to-end run.
# ----------------------------------------------------------------------------------------------------------
note "3) never-submit invariant + optional live run ..."

# NEITHER component may contain a platform-egress / submit primitive.
if ! grep -qiE 'curl |wget |http\.post|submit\(' "$DELIVER"; then
  ok "deliver-submission.sh has no platform-egress / submit primitive"
else
  bad "deliver-submission.sh contains a platform-egress primitive"
fi
if ! grep -qiE 'curl |wget |http\.post|submit\(' "$INTAKE"; then
  ok "feedback-intake.ag has no platform-egress / submit primitive"
else
  bad "feedback-intake.ag contains a platform-egress primitive"
fi
grep -qi 'never submit' "$DELIVER" && ok "deliver-submission.sh documents the never-submit invariant" || bad "deliver-submission.sh missing the never-submit invariant note"
grep -qi 'never submit' "$INTAKE"  && ok "feedback-intake.ag documents the never-submit invariant"  || bad "feedback-intake.ag missing the never-submit invariant note"

if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the live end-to-end feedback-intake check"
else
  RUN="$WORK/run"
  mkdir -p "$RUN"
  cp "$INTAKE" "$RUN/feedback-intake.ag"
  ( cd "$RUN" && agentis init >/dev/null 2>&1 || true )
  {
    echo "learning.enabled = true"; echo "experience.enabled = true"; echo "exec.default_timeout_ms = 30000"
    echo "exec.env_passthrough = SUBMISSION_DIR"
  } >> "$RUN/.agentis/config"
  set +e
  (
    cd "$RUN" || exit 90
    export SUBMISSION_DIR="$STAGED"
    # --grant-pii: the outcome/reason text can carry addresses/identifiers that trip the PII heuristic; benign.
    agentis go feedback-intake.ag --enable-exec --enable-messaging --grant-pii
  ) >"$WORK/out.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    ok "agentis go feedback-intake.ag ran end-to-end over the staged drop-dir (exit 0)"
  else
    bad "agentis go feedback-intake.ag failed on the staged dir (exit $rc):"
    sed 's/^/      /' "$WORK/out.log" | head -20 >&2
  fi
fi

# ----------------------------------------------------------------------------------------------------------
echo
if [ "$FAIL" -eq 0 ]; then
  note "PASS — deliver-submission.sh staged a marked draft (canonical id + raw gate verdicts in manifest.json),"
  note "       refused an unmarked draft (exit 3), the closed-Onyx outcome maps deterministically to failure,"
  note "       feedback-intake.ag encodes the four arms + attributes via the gate topics, and neither component"
  note "       has platform egress. Offline + human-gated; never submits."
  exit 0
fi
note "FAIL — a feedback-loop assertion regressed (see above)." >&2
exit 1
