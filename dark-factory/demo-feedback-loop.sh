#!/usr/bin/env bash
# demo-feedback-loop.sh — OFFLINE proof (#1526, epic #1505) of the human<->federation FEEDBACK LOOP: the
# delivery muscle deliver-submission.sh + the reasoning half auditor/agents/feedback-intake.ag, exchanged through
# a LOCAL operator DROP-DIRECTORY (the baked-in design decision — no platform API/scrape). Mirrors the sibling
# dark-factory demos (demo-report-writer.sh / demo-immunefi-intake.sh): assert-based PASS/FAIL lines, a temp
# drop-dir trap-cleaned, exit non-zero on regression, exit 3 if a component is missing.
#
# FIVE parts:
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
#   4) NOTIFY (offline, #1538): the finding-ready Slack/Discord alert deliver-submission.sh pages on a successful
#      stage, reusing monitor/scripts/notify.sh. A `curl` STUB on PATH proves no real network is ever reached.
#      Asserts: no-webhook = offline no-op (exit 0, alert on STDERR only, curl never invoked); the alert payload
#      shape (submission_id/severity/gate verdicts/draft_path/message); a bad webhook value never flips
#      deliver-submission.sh's own exit code (retries forced to 0 so no real sleep is reached); the source pins
#      `bash`, never `sh`, for the notify.sh invocation; and — the single most load-bearing check in this file —
#      that deliver-submission.sh's documented stdout contract (the staged path, ONE line, nothing else) still
#      holds with a webhook configured, proving the notify subprocess's stdout is correctly redirected to stderr.
#   5) POC ARTIFACT SET (offline, #1540): the complete Immunefi PoC-form bundle deliver-submission.sh now stages
#      when a PoC is supplied — the verbatim PoC source under poc/, a captured passing run-log (poc-run.txt), a
#      generated REPRODUCE.md, the FIELD->immunefi_fields manifest extraction, and the operator's-OWN-GitHub
#      secret gist auto-created via `gh gist create --secret`. A `gh` STUB on PATH (mirroring the part-4 curl
#      stub) proves the gist command shape + the graceful no-token fallback (bundled command + placeholder) with
#      NO network. Asserts: byte-identical poc/run-log, REPRODUCE.md content, nested immunefi_fields, the stubbed
#      gist URL in the manifest, the one-line stdout contract WITH the gist stub active, the marker guard running
#      BEFORE any poc staging/gist, writeup-only degradation, and the no-FIELD default-to-"" case.
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
# 4) NOTIFY — the finding-ready Slack/Discord alert deliver-submission.sh pages on a successful stage (#1538).
# ----------------------------------------------------------------------------------------------------------
note "4) finding-ready Slack/Discord alert (deliver-submission.sh -> monitor/scripts/notify.sh) ..."

# A curl STUB on PATH: logs every invocation (to $CURL_LOG) and always fails fast (exit 1, no real I/O) — proves
# no real network is ever reached, and would fail loudly if a gate here were wrong.
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
{
  printf '%s\n' "#!/bin/sh"
  printf '%s\n' 'echo "$*" >> "$CURL_LOG"'
  printf '%s\n' "exit 1"
} > "$FAKEBIN/curl"
chmod +x "$FAKEBIN/curl"

NID="notify-fixture@dead:beef"
NSCOPE="SCOPE-GATE|PAYABLE|fixture"
NIMPACT="IMPACT-GATE|SUBSTANTIATED|fixture"
NDUP="DUP-RISK|LOW|~5%|fixture"

# --- (a) no webhook configured = an offline no-op: exit 0, alert on STDERR only, curl never reached. ----------
NOTIFY_ERR="$WORK/notify-stderr.log"
CURL_LOG="$WORK/curl-calls.log"
env -u DARK_FACTORY_SLACK_WEBHOOK -u MONITOR_WEBHOOK_URL -u MONITOR_WEBHOOK_URL_WARN -u MONITOR_WEBHOOK_URL_HIGH \
  CURL_LOG="$CURL_LOG" PATH="$FAKEBIN:$PATH" \
  bash "$DELIVER" --id "$NID" --draft-file "$DRAFT" --scope-verdict "$NSCOPE" --impact-verdict "$NIMPACT" \
    --dup-risk "$NDUP" --severity Critical --drop-dir "$WORK/drop-notify-a" \
  >"$WORK/notify-stdout-a.log" 2>"$NOTIFY_ERR"; RC=$?
[ "$RC" -eq 0 ] && ok "no-webhook stage still exits 0" || bad "no-webhook stage exited $RC (expected 0)"
grep -q '\[monitor:alert\]' "$NOTIFY_ERR" \
  && ok "the finding-ready alert reached notify.sh's no-op fallback on STDERR" || bad "no [monitor:alert] line found on stderr"
[ ! -e "$CURL_LOG" ] && ok "curl was never invoked (no network reached)" || bad "curl was invoked with no webhook configured: $(cat "$CURL_LOG")"

# --- (b) payload shape: submission_id + severity + gate verdicts + draft_path + message. -----------------------
ALERT_JSON="$(grep '\[monitor:alert\]' "$NOTIFY_ERR" | head -1 | sed 's/^\[monitor:alert\] //')"
PAYLOAD_OK="$(ALERT_JSON="$ALERT_JSON" NID="$NID" NSCOPE="$NSCOPE" NIMPACT="$NIMPACT" NDUP="$NDUP" python3 -c '
import json, os
try:
    obj = json.loads(os.environ["ALERT_JSON"])
except Exception as e:
    print("parse-error:" + str(e))
else:
    ok = (
        obj.get("submission_id") == os.environ["NID"]
        and obj.get("severity") == "high"
        and obj.get("scope_verdict") == os.environ["NSCOPE"]
        and obj.get("impact_verdict") == os.environ["NIMPACT"]
        and obj.get("dup_risk") == os.environ["NDUP"]
        and str(obj.get("draft_path", "")).endswith("/submission-draft.md")
        and "relay to the platform" in obj.get("message", "")
        and "feedback-intake.ag" in obj.get("message", "")
    )
    print("ok" if ok else "shape-mismatch:" + json.dumps(obj))
')"
[ "$PAYLOAD_OK" = "ok" ] \
  && ok "the finding-ready alert carries submission_id/severity(high)/gate verdicts/draft_path/message" \
  || bad "alert payload shape mismatch: $PAYLOAD_OK"

# --- (c) a bad/bogus webhook must never flip deliver-submission.sh's own exit code (retries=0, no real sleep). --
DROP_C="$WORK/drop-notify-c"
NID_C="notify-fixture@dead:c0de"
CURL_LOG_C="$WORK/curl-calls-c.log"
DARK_FACTORY_SLACK_WEBHOOK="not-a-real-webhook" MONITOR_NOTIFY_MAX_RETRIES=0 \
  CURL_LOG="$CURL_LOG_C" PATH="$FAKEBIN:$PATH" \
  bash "$DELIVER" --id "$NID_C" --draft-file "$DRAFT" --severity Medium --drop-dir "$DROP_C" \
  >/dev/null 2>"$WORK/notify-stderr-c.log"; RC=$?
[ "$RC" -eq 0 ] && ok "a bogus webhook never flips deliver-submission.sh's own exit code" || bad "bogus webhook flipped exit to $RC (expected 0)"
BADSLUG_C="$(printf '%s' "$NID_C" | sed 's/[^A-Za-z0-9._@-]/-/g')"
[ -f "$DROP_C/$BADSLUG_C/manifest.json" ] && [ -f "$DROP_C/$BADSLUG_C/submission-draft.md" ] && [ -f "$DROP_C/$BADSLUG_C/OUTCOME.md" ] \
  && ok "staging still completed cleanly despite the bogus webhook" || bad "staging was corrupted by the bogus webhook path"

# --- (d) source guard: bash, never sh/dot-source, for the notify.sh invocation (#1507/#1534 dash lesson). ------
grep -q 'bash "\$SCRIPT_DIR/monitor/scripts/notify.sh"' "$DELIVER" \
  && ok "deliver-submission.sh invokes notify.sh via bash (source-pinned)" || bad "deliver-submission.sh does not bash-invoke notify.sh as expected"
if grep -qE '(^|[^a-zA-Z])sh[[:space:]]+"?\$SCRIPT_DIR/monitor/scripts/notify\.sh"?' "$DELIVER" \
   || grep -qE '\.[[:space:]]+"?\$SCRIPT_DIR/monitor/scripts/notify\.sh"?' "$DELIVER"; then
  bad "deliver-submission.sh invokes notify.sh via sh/dot-source (dash-safety regression)"
else
  ok "deliver-submission.sh does not invoke notify.sh via sh/dot-source"
fi

# --- (e) STDOUT-CONTRACT regression guard (load-bearing): with a webhook CONFIGURED, stdout is STILL exactly ---
# the staged path — the one assertion that would catch a missing `>&2` on the notify invocation.
DROP_E="$WORK/drop-notify-e"
NID_E="notify-fixture@dead:c0ffee"
CURL_LOG_E="$WORK/curl-calls-e.log"
STDOUT_E="$(DARK_FACTORY_SLACK_WEBHOOK="not-a-real-webhook" MONITOR_NOTIFY_MAX_RETRIES=0 \
  CURL_LOG="$CURL_LOG_E" PATH="$FAKEBIN:$PATH" \
  bash "$DELIVER" --id "$NID_E" --draft-file "$DRAFT" --severity Low --drop-dir "$DROP_E" 2>/dev/null)"
LINES_E="$(printf '%s\n' "$STDOUT_E" | wc -l | tr -d ' ')"
[ "$LINES_E" = "1" ] && ok "deliver-submission.sh's stdout is exactly ONE line with a webhook configured" \
  || bad "stdout had $LINES_E lines (expected 1) — the notify subprocess's stdout may be leaking"
EXPECT_E="$DROP_E/$(printf '%s' "$NID_E" | sed 's/[^A-Za-z0-9._@-]/-/g')"
[ "$STDOUT_E" = "$EXPECT_E" ] \
  && ok "stdout is exactly the staged path — no [monitor:alert] leakage into stdout" \
  || bad "stdout did not equal the staged path: [$STDOUT_E]"

# ----------------------------------------------------------------------------------------------------------
# 5) POC ARTIFACT SET — the complete Immunefi PoC-form bundle (#1540): poc/<source> + poc-run.txt + REPRODUCE.md
#    + the FIELD->immunefi_fields manifest extraction + the operator's-OWN-GitHub secret gist. A `gh` STUB on
#    PATH proves the gist command shape offline + the no-token fallback. No network anywhere.
# ----------------------------------------------------------------------------------------------------------
note "5) complete PoC-form artifact set + secret-gist auto-create (offline, gh stubbed) ..."

# Restore the script's documented `set -uo pipefail` (NO -e) mode: part 3's optional agentis live-run block flips
# `set -e` on and leaves it on when the runtime is present, which would otherwise abort this section on the
# INTENTIONAL exit-3 marker-guard probe below (assertions here gate on explicit RC / && ok || bad, not on -e).
set +e

# jget_nested: read a nested field (immunefi_fields.<k>) from a JSON file, deterministic, no jq.
jget_nested() { python3 -c 'import sys,json; print(json.load(open(sys.argv[1])).get(sys.argv[2],{}).get(sys.argv[3],""))' "$1" "$2" "$3"; }

# A `gh` STUB on PATH (mirrors the part-4 curl stub): logs every invocation to $GH_LOG, prints a fixed fake URL
# for `gist create`, and exits per GH_STUB_MODE for `auth status` (authed->0, notoken->1). No real network.
FAKE_GIST_URL="https://gist.github.com/local-demo/0000000000000000000000000000dead"
{
  printf '%s\n' "#!/bin/sh"
  printf '%s\n' 'echo "$*" >> "$GH_LOG"'
  printf '%s\n' 'case "$1" in'
  printf '%s\n' "  gist) echo \"$FAKE_GIST_URL\"; exit 0 ;;"
  printf '%s\n' '  auth) [ "${GH_STUB_MODE:-authed}" = notoken ] && exit 1; exit 0 ;;'
  printf '%s\n' 'esac'
  printf '%s\n' 'exit 0'
} > "$FAKEBIN/gh"
chmod +x "$FAKEBIN/gh"

# Fixtures: a marked draft carrying the five FIELD| lines, a tiny foundry PoC, a fixture passing run-log.
PID="enzyme-onyx@a1b2c3d:sync-deposit-nav-frontrun-poc"
PDRAFT="$WORK/poc-draft.md"
{
  printf '%s\n' "SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW"
  printf '%s\n' "FIELD|project|Enzyme Onyx"
  printf '%s\n' "FIELD|asset|SyncDepositHandler.sol"
  printf '%s\n' "FIELD|impact|Theft of pre-update holders unclaimed yield"
  printf '%s\n' "FIELD|severity|Critical"
  printf '%s\n' "FIELD|title|SyncDepositHandler NAV front-running"
  printf '%s\n' ""
  printf '%s\n' "## Brief/Intro"
  printf '%s\n' "A NAV front-running finding. DRAFT for human review; never auto-submitted."
  printf '%s\n' "## References"
  printf '%s\n' "$SCOPE_V"
} > "$PDRAFT"

PPOC="$WORK/Poc_frontrun.t.sol"
{
  printf '%s\n' "// SPDX-License-Identifier: MIT"
  printf '%s\n' "pragma solidity ^0.8.20;"
  printf '%s\n' "contract PocFrontrun {"
  printf '%s\n' "  function test_frontrun() external pure {"
  printf '%s\n' "    require(true, \"exploit reproduced\");"
  printf '%s\n' "  }"
  printf '%s\n' "}"
} > "$PPOC"
POC_BASENAME="$(basename "$PPOC")"

PRUN="$WORK/poc-run-fixture.txt"
{
  printf '%s\n' "Running 1 test for test/Poc_frontrun.t.sol:PocFrontrun"
  printf '%s\n' "[PASS] test_frontrun() (gas: 21000)"
  printf '%s\n' "Suite result: ok. 1 passed; 0 failed; 0 skipped"
} > "$PRUN"

pid_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9._@-]/-/g'; }

# --- (a) full artifact set + gh authed: byte-identical poc, run-log, REPRODUCE.md, nested fields, gist URL. ----
DROP5A="$WORK/drop-poc-a"; GH_LOG_A="$WORK/gh-a.log"
STAGED5A="$(env GH_STUB_MODE=authed GITHUB_TOKEN=fake GH_LOG="$GH_LOG_A" PATH="$FAKEBIN:$PATH" \
  bash "$DELIVER" --id "$PID" --draft-file "$PDRAFT" --target enzyme-onyx --severity Critical \
    --poc-file "$PPOC" --poc-run "$PRUN" --poc-kind foundry --poc-match test \
    --drop-dir "$DROP5A" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "(a) stage with --poc-file/--poc-run/--poc-kind + gh authed exits 0" || bad "(a) exited $RC (expected 0)"
LINES_5A="$(printf '%s\n' "$STAGED5A" | wc -l | tr -d ' ')"
if [ "$LINES_5A" = "1" ] && [ "$STAGED5A" = "$DROP5A/$(pid_slug "$PID")" ]; then
  ok "(a) stdout is exactly ONE line == the staged path (gh stub active — the gist URL never leaks to stdout)"
else
  bad "(a) stdout not a one-line staged path: [$STAGED5A]"
fi
cmp -s "$PPOC" "$STAGED5A/poc/$POC_BASENAME" \
  && ok "(a) poc/$POC_BASENAME is byte-identical to the fixture PoC (cmp)" || bad "(a) poc source not byte-identical"
cmp -s "$PRUN" "$STAGED5A/poc-run.txt" \
  && ok "(a) poc-run.txt equals the fixture run-log (cmp)" || bad "(a) poc-run.txt mismatch"
if grep -q 'forge test' "$STAGED5A/REPRODUCE.md" && grep -q -- '--match' "$STAGED5A/REPRODUCE.md" \
   && grep -q "$POC_BASENAME" "$STAGED5A/REPRODUCE.md" && grep -q '\[PASS\]' "$STAGED5A/REPRODUCE.md"; then
  ok "(a) REPRODUCE.md carries the forge command + --match + the poc basename + [PASS]"
else
  bad "(a) REPRODUCE.md missing forge/--match/basename/[PASS]"
fi
[ "$(jget_nested "$STAGED5A/manifest.json" immunefi_fields project)"  = "Enzyme Onyx" ]                        && ok "(a) manifest immunefi_fields.project == the FIELD value"  || bad "(a) immunefi_fields.project mismatch"
[ "$(jget_nested "$STAGED5A/manifest.json" immunefi_fields asset)"    = "SyncDepositHandler.sol" ]             && ok "(a) manifest immunefi_fields.asset == the FIELD value"    || bad "(a) immunefi_fields.asset mismatch"
[ "$(jget_nested "$STAGED5A/manifest.json" immunefi_fields impact)"   = "Theft of pre-update holders unclaimed yield" ] && ok "(a) manifest immunefi_fields.impact == the FIELD value" || bad "(a) immunefi_fields.impact mismatch"
[ "$(jget_nested "$STAGED5A/manifest.json" immunefi_fields severity)" = "Critical" ]                          && ok "(a) manifest immunefi_fields.severity == the FIELD value" || bad "(a) immunefi_fields.severity mismatch"
[ "$(jget_nested "$STAGED5A/manifest.json" immunefi_fields title)"    = "SyncDepositHandler NAV front-running" ] && ok "(a) manifest immunefi_fields.title == the FIELD value"  || bad "(a) immunefi_fields.title mismatch"
[ "$(jget "$STAGED5A/manifest.json" gist_url)" = "$FAKE_GIST_URL" ] \
  && ok "(a) manifest gist_url == the stubbed gist URL" || bad "(a) gist_url mismatch: $(jget "$STAGED5A/manifest.json" gist_url)"
[ "$(python3 -c 'import sys,json; print(",".join(json.load(open(sys.argv[1])).get("poc_files",[])))' "$STAGED5A/manifest.json")" = "$POC_BASENAME" ] \
  && ok "(a) manifest poc_files lists the staged basename" || bad "(a) manifest poc_files mismatch"
if grep -q 'gist create' "$GH_LOG_A" && grep -q -- '--secret' "$GH_LOG_A" && grep -q "poc/$POC_BASENAME" "$GH_LOG_A"; then
  ok "(a) the gh log shows 'gist create --secret ... poc/<file>'"
else
  bad "(a) gh log missing gist create/--secret/poc file: $(cat "$GH_LOG_A" 2>/dev/null)"
fi

# --- (b) no-token fallback: gist_url == placeholder, GIST_COMMAND.txt bundled, gh never runs `gist create`. -----
DROP5B="$WORK/drop-poc-b"; GH_LOG_B="$WORK/gh-b.log"
STAGED5B="$(env -u GITHUB_TOKEN -u GH_TOKEN GH_STUB_MODE=notoken GH_LOG="$GH_LOG_B" PATH="$FAKEBIN:$PATH" \
  bash "$DELIVER" --id "$PID" --draft-file "$PDRAFT" --target enzyme-onyx --severity Critical \
    --poc-file "$PPOC" --poc-run "$PRUN" --poc-kind foundry --drop-dir "$DROP5B" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "(b) no-token stage still exits 0 (graceful degradation)" || bad "(b) exited $RC (expected 0)"
GIST_URL_B="$(jget "$STAGED5B/manifest.json" gist_url)"
printf '%s' "$GIST_URL_B" | grep -q 'PENDING' \
  && ok "(b) manifest gist_url is the PENDING placeholder" || bad "(b) gist_url not a placeholder: $GIST_URL_B"
[ -f "$STAGED5B/poc/GIST_COMMAND.txt" ] && grep -q 'gh gist create --secret' "$STAGED5B/poc/GIST_COMMAND.txt" \
  && ok "(b) poc/GIST_COMMAND.txt exists + carries the exact 'gh gist create --secret' command" || bad "(b) GIST_COMMAND.txt missing/incomplete"
if grep -q 'auth status' "$GH_LOG_B" && ! grep -q 'gist create' "$GH_LOG_B"; then
  ok "(b) gh log shows only 'auth status', never 'gist create' (no egress without a token)"
else
  bad "(b) gh log unexpected (expected auth status, no gist create): $(cat "$GH_LOG_B" 2>/dev/null)"
fi

# --- (c) writeup-only: no poc flags, no gh -> stages cleanly, poc fields empty, no poc/ dir. -------------------
DROP5C="$WORK/drop-poc-c"
STAGED5C="$(env -u GITHUB_TOKEN -u GH_TOKEN \
  bash "$DELIVER" --id "$PID" --draft-file "$PDRAFT" --target enzyme-onyx --severity Critical \
    --drop-dir "$DROP5C" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "(c) writeup-only stage (no poc flags) exits 0" || bad "(c) exited $RC (expected 0)"
[ -f "$STAGED5C/manifest.json" ] && [ -f "$STAGED5C/submission-draft.md" ] && [ -f "$STAGED5C/OUTCOME.md" ] \
  && ok "(c) draft + manifest + OUTCOME present in writeup-only mode" || bad "(c) missing core artifacts"
if [ "$(python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); print(len(d.get("poc_files",[])), repr(d.get("poc_run","")), repr(d.get("reproduce","")))' "$STAGED5C/manifest.json")" = "0 '' ''" ]; then
  ok "(c) poc_files/poc_run/reproduce are empty in writeup-only mode (clean degradation)"
else
  bad "(c) writeup-only manifest has unexpected poc fields"
fi
[ ! -d "$STAGED5C/poc" ] && ok "(c) no poc/ dir created in writeup-only mode" || bad "(c) poc/ dir leaked in writeup-only mode"

# --- (d) marker guard FIRST: an UNMARKED draft + --poc-file exits 3 and stages NOTHING (no poc/ leaked, no gh). -
DROP5D="$WORK/drop-poc-d"; GH_LOG_D="$WORK/gh-d.log"
UNMARKED5="$WORK/unmarked-poc.md"
printf '%s\n' "## Brief/Intro" "no marker here" > "$UNMARKED5"
UID5="unmarked-poc@dead:no-marker"
env GH_STUB_MODE=authed GITHUB_TOKEN=fake GH_LOG="$GH_LOG_D" PATH="$FAKEBIN:$PATH" \
  bash "$DELIVER" --id "$UID5" --draft-file "$UNMARKED5" --poc-file "$PPOC" --drop-dir "$DROP5D" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && ok "(d) an unmarked draft WITH --poc-file exits 3 (marker guard runs FIRST)" || bad "(d) did not exit 3 (rc=$RC)"
[ ! -e "$DROP5D/$(pid_slug "$UID5")" ] && ok "(d) the unmarked+poc draft staged NOTHING (no poc/ dir leaked)" || bad "(d) unmarked draft leaked a stage"
[ ! -f "$GH_LOG_D" ] && ok "(d) gh was never invoked for a refused draft (guard before gist)" || bad "(d) gh invoked despite the marker guard: $(cat "$GH_LOG_D" 2>/dev/null)"

# --- (e) no-FIELD draft: a marked draft without any FIELD| lines -> immunefi_fields all default to "". ---------
DROP5E="$WORK/drop-poc-e"
NOFIELD="$WORK/nofield-draft.md"
{
  printf '%s\n' "SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW"
  printf '%s\n' "## Brief/Intro"
  printf '%s\n' "A finding with no FIELD lines. DRAFT; never auto-submitted."
} > "$NOFIELD"
EID5="nofield@dead:no-fields"
STAGED5E="$(env -u GITHUB_TOKEN -u GH_TOKEN \
  bash "$DELIVER" --id "$EID5" --draft-file "$NOFIELD" --drop-dir "$DROP5E" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "(e) a marked draft without FIELD| lines exits 0 (graceful)" || bad "(e) exited $RC (expected 0)"
if [ "$(python3 -c 'import sys,json; f=json.load(open(sys.argv[1])).get("immunefi_fields",{}); print("".join(f.get(k,"x") for k in ["project","asset","impact","severity","title"]))' "$STAGED5E/manifest.json")" = "" ]; then
  ok "(e) immunefi_fields values all default to \"\" on a no-FIELD draft"
else
  bad "(e) immunefi_fields not all-empty on a no-FIELD draft"
fi

# --- source guards: gist_ready gate, best-effort gh call, the operator's-own-GitHub / not-a-submission header. --
grep -q 'gist_ready()' "$DELIVER" \
  && ok "(guard) deliver-submission.sh defines the gist_ready() capability gate" || bad "(guard) gist_ready() helper missing"
grep -q 'gh gist create --secret' "$DELIVER" \
  && ok "(guard) the gist auto-create uses 'gh gist create --secret'" || bad "(guard) secret-gist create call missing"
grep -qE 'gh gist create --secret.*\|\| true' "$DELIVER" \
  && ok "(guard) the live gist create is best-effort (|| true — never fails a good stage)" || bad "(guard) gist create is not || true guarded"
grep -qi "operator's OWN GitHub" "$DELIVER" \
  && ok "(guard) the header documents the gist as the operator's OWN GitHub" || bad "(guard) missing the operator's-own-GitHub gist note"
grep -qi 'NOT a bounty-platform submission' "$DELIVER" \
  && ok "(guard) the header keeps the not-a-platform-submission invariant explicit" || bad "(guard) missing the not-a-platform-submission note"

# ----------------------------------------------------------------------------------------------------------
echo
if [ "$FAIL" -eq 0 ]; then
  note "PASS — deliver-submission.sh staged a marked draft (canonical id + raw gate verdicts in manifest.json),"
  note "       refused an unmarked draft (exit 3), the closed-Onyx outcome maps deterministically to failure,"
  note "       feedback-intake.ag encodes the four arms + attributes via the gate topics, neither component has"
  note "       platform egress, and the finding-ready Slack/Discord alert (#1538) is offline-safe by default and"
  note "       never corrupts the staged-path stdout contract even with a webhook configured. And (#1540) the"
  note "       complete PoC-form artifact set stages byte-intact (poc/ source + poc-run.txt + REPRODUCE.md +"
  note "       FIELD->immunefi_fields), the operator's-own-GitHub secret gist auto-creates (gh stubbed) with a"
  note "       graceful no-token fallback, and the marker guard still runs BEFORE any poc staging/gist. Never submits."
  exit 0
fi
note "FAIL — a feedback-loop assertion regressed (see above)." >&2
exit 1
