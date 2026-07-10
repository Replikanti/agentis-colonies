#!/usr/bin/env bash
# ingest-slack-outcome.sh — the READER half of the human<->federation feedback loop over a Slack THREAD (#1557 /
# #1561, epic #1505). notify-submission.sh (#1541) delivers the submission package to a Slack thread and prompts the
# operator to REPLY IN THAT THREAD starting with `outcome:` then the platform's RAW response VERBATIM; this script
# reads that reply back (`conversations.replies`), captures the response into `OUTCOME.md`'s `platform_response:`
# block (plus the OPTIONAL operator `verdict:`/`payout:` override lines), runs `feedback-intake.ag` (the #1526 learn
# path — now a CLASSIFIER, #1561), posts a confirmation, and is idempotent via a per-stage marker.
#
# CONFIDENCE GATE (#1561): feedback-intake.ag's AUTHORITATIVE `FEEDBACK|<disp>|<conf>|<stage>|<SIGNAL>|...` line
# carries an .ag-COMPUTED signal. A `HOLD` (a low-confidence / unclear classification) is NOT learned: this reader
# posts a threaded CONFIRMATION REQUEST, writes a `.pending-confirmation` marker (keyed on the selected reply ts so a
# cron never re-spams), and does NOT write `.outcome-ingested` — a later, clearer operator reply can still be learned.
# An operator `verdict:` override always wins (bypasses the gate). Learned outcomes get the `.outcome-ingested` marker.
#
# TRIGGER MODEL (honest): the dark-factory federation is SERVERLESS / one-shot — there is NO always-on Slack
# socket/events listener. This reader is OPERATOR- or CRON-triggered: run it (`--stage <dir>` or `--all`) after the
# operator has replied in the thread. The outcome DATA lives in Slack (one place); ingesting it is a triggered
# READ, not a push. A suggested (NOT installed) crontab line is documented in README.md.
#
# SCOPE: reading a public channel's thread via `conversations.replies` needs the Slack app's `channels:history`
# scope (granted on the operator's token). Re-installing the app for the new scope mints a fresh `xoxb` token —
# re-store it as the `secret://` secret.
#
# OUTCOME->ACTION ROUTER (#1562): once an outcome is CLASSIFIED (the FEEDBACK line above), a DETERMINISTIC bash
# `case` (route_actions, never an LLM) turns `disposition + root_cause` into the next action(s). CHEAP actions are
# local, reversible writes applied immediately (mark-dead -> dead-targets.txt; tune-gate -> a gate-tuning/<stage>.md
# calibration NOTE; needs-info-draft -> a FOLLOWUP.md stub; reinforce -> a winning-path note). SPENDY actions
# (re-devise / hunt-deeper) are PROPOSE-then-GREENLIGHT: the router posts a `propose:` message into the thread and
# writes `.route-proposed`; the spend runs ONLY after a later operator `go` reply, which always writes the durable
# RE-HUNT.md record + `.route-greenlit`. GREENLIT DISPATCH (#1567): when a target dir resolves (--target-dir, or a
# manifest `local_repo`/`target_dir`) AND run-audit-pass.sh + setsid are present, the `go` AUTO-INVOKES the
# feedback-informed re-hunt DETACHED (`run-audit-pass.sh --live --reviewer-feedback <reason> --target-dir …`, the
# code-edit-job.sh setsid convention) — the reviewer reason threads into audit-scout.ag's DEVISE prompt. When no
# target dir resolves (or setsid/bin is absent), the fallback is the command HAND-OFF the operator runs from
# RE-HUNT.md (not a coordinator-style auto-invoke). Either way run-audit-pass.sh never submits (its terminal best
# case is a PENDING-HUMAN-REVIEW draft). The tune-gate note is a recorded calibration HOOK, NOT a behavior change
# (the gates do not `recall()` it yet, and the
# router never calls `learn()` a second time, so an outcome is never double-counted). Three per-outcome markers keep
# it idempotent: `.route-applied` (cheap actions ran + any spendy proposed, once), `.route-proposed` (a spendy
# proposal is outstanding), `.route-greenlit` (the hand-off ran). The greenlight pass runs at the TOP of
# process_stage — BEFORE the `.outcome-ingested` short-circuit — so a `--all` cron re-enters to catch a later `go`.
#
# NEVER-SUBMIT INVARIANT (unchanged): every network call this script makes is to `https://slack.com/api/...` on the
# operator's OWN workspace. It adds NO bounty-platform egress and never submits — reading a thread, confirming,
# proposing/marking/drafting, writing a RE-HUNT.md hand-off, and (on greenlight) launching the LOCAL run-audit-pass.sh
# re-hunt are operator-workspace + local actions, exactly like the notify.sh page and the notify-submission.sh
# delivery. RE-HUNT.md carries no submit primitive; run-audit-pass.sh never submits (a PENDING-HUMAN-REVIEW draft).
#
# Config (env):
#   DARK_FACTORY_SLACK_BOT_TOKEN   the bot token (`xoxb-…`, a `secret://…` URI resolved via
#                                  tools/parse-toml-secret.py --resolve, or raw). No token -> exit 0 no-op.
#   DARK_FACTORY_DIR / DROP_DIR    the operator drop-dir root (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/drop).
#   DARK_FACTORY_AUDITOR_DIR       the auditor colony dir feedback-intake.ag runs FROM (default $SCRIPT_DIR/auditor).
# The resolved token appears ONLY in the `Authorization: Bearer` header — never argv, never echoed.
#
# LEARN PERSISTENCE (load-bearing): feedback-intake.ag runs FROM the auditor colony dir (NOT a throwaway mktemp) so
# its `learn()` PERSISTS in the colony's durable experience store — a mktemp run dir would evaporate the lesson,
# defeating the loop.
#
# Usage:  ingest-slack-outcome.sh (--stage <staged-drop-dir> | --all) [--drop-dir DIR] [--target-dir DIR]
#         ingest-slack-outcome.sh --route-preview <disposition> <root_cause>   # pure: print the action list, exit 0
# Requires: bash + python3 + curl (+ agentis to fold into learning). Exit: 0 always (best-effort); 2 = bad args.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"
DROP_DIR="${DROP_DIR:-$DIR/drop}"

# route_actions <disposition> <root_cause> -> space-separated tagged action tokens (cheap:*/spendy:*). The
# DETERMINISTIC outcome->action map (#1562), never an LLM. Routing keys on the action TYPE (disposition +
# root_cause); the tune-gate/reinforce TARGET gate is the classifier's `stage` field, applied by the caller.
#   accepted, *                                        -> reinforce + hunt-deeper (find MORE on a paying target)
#   needs-info, *                                      -> needs-info-draft (a FOLLOWUP.md stub for the operator)
#   rejected, impact-not-substantiated|insufficient-poc-> tune-gate + re-devise (the finding needs a stronger case)
#   rejected, out-of-scope-asset|known-issue|duplicate -> mark-dead + tune-gate (this target/commit is spent)
#   rejected, none|other                               -> tune-gate (record only; no spend without guidance)
#   out-of-scope, *                                    -> mark-dead + tune-gate
#   duplicate, *                                       -> mark-dead + tune-gate
#   unclear, *                                         -> (empty — never reached: a HOLD returns before routing)
route_actions() {
  case "$1" in
    accepted)     echo "cheap:reinforce spendy:hunt-deeper" ;;
    needs-info)   echo "cheap:needs-info-draft" ;;
    rejected)
      case "$2" in
        impact-not-substantiated|insufficient-poc) echo "cheap:tune-gate spendy:re-devise" ;;
        out-of-scope-asset|known-issue|duplicate)  echo "cheap:mark-dead cheap:tune-gate" ;;
        *)                                          echo "cheap:tune-gate" ;;
      esac ;;
    out-of-scope) echo "cheap:mark-dead cheap:tune-gate" ;;
    duplicate)    echo "cheap:mark-dead cheap:tune-gate" ;;
    *)            echo "" ;;
  esac
}

STAGE=""
ALL=0
ROUTE_PREVIEW=0
RP_DISP=""
RP_ROOT=""
TARGET_DIR_OVERRIDE=""
while [ $# -gt 0 ]; do case "$1" in
  --stage)    [ "$#" -ge 2 ] || { echo "ingest-slack-outcome.sh: --stage requires a value" >&2; exit 2; }; STAGE="$2"; shift 2;;
  --all)      ALL=1; shift;;
  --drop-dir) [ "$#" -ge 2 ] || { echo "ingest-slack-outcome.sh: --drop-dir requires a value" >&2; exit 2; }; DROP_DIR="$2"; shift 2;;
  --target-dir) [ "$#" -ge 2 ] || { echo "ingest-slack-outcome.sh: --target-dir requires a value" >&2; exit 2; }; TARGET_DIR_OVERRIDE="$2"; shift 2;;
  --route-preview) [ "$#" -ge 3 ] || { echo "ingest-slack-outcome.sh: --route-preview requires <disposition> <root_cause>" >&2; exit 2; }; ROUTE_PREVIEW=1; RP_DISP="$2"; RP_ROOT="$3"; shift 3;;
  -h|--help)  sed -n '2,57p' "$0"; exit 0;;
  *) echo "ingest-slack-outcome.sh: unknown arg: $1" >&2; exit 2;;
esac; done

# --route-preview: a PURE introspection mode (no token, no Slack) — print the deterministic action list, exit 0.
# Parsed EARLY, before token resolution and the --stage|--all required check, so the demo can pin the map per row.
if [ "$ROUTE_PREVIEW" -eq 1 ]; then
  route_actions "$RP_DISP" "$RP_ROOT"
  exit 0
fi

if [ -z "$STAGE" ] && [ "$ALL" -eq 0 ]; then
  echo "ingest-slack-outcome.sh: one of --stage <dir> or --all is required" >&2; exit 2
fi
if [ -n "$STAGE" ] && [ "$ALL" -eq 1 ]; then
  echo "ingest-slack-outcome.sh: --stage and --all are mutually exclusive" >&2; exit 2
fi

# Resolve the bot token (secret:// -> plaintext; a raw `xoxb-…` is returned verbatim, the deliver-submission.sh
# precedent). No token at all -> clean exit-0 no-op (mirrors notify-submission.sh's offline fallback).
BOT_TOKEN_RAW="${DARK_FACTORY_SLACK_BOT_TOKEN:-}"
if [ -z "$BOT_TOKEN_RAW" ]; then
  echo "[outcome:slack] no DARK_FACTORY_SLACK_BOT_TOKEN — nothing to ingest from Slack (no-op)"
  exit 0
fi
BOT_TOKEN=""
if [ -f "$SCRIPT_DIR/../tools/parse-toml-secret.py" ]; then
  BOT_TOKEN="$(python3 "$SCRIPT_DIR/../tools/parse-toml-secret.py" --resolve "$BOT_TOKEN_RAW" 2>/dev/null)"
else
  BOT_TOKEN="$BOT_TOKEN_RAW"
fi
if [ -z "$BOT_TOKEN" ]; then
  echo "ingest-slack-outcome.sh: bot token resolved empty (secret:// miss?) — no-op" >&2
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ingest-slack-outcome.sh: curl not found but a token is configured — cannot read the thread (no-op)" >&2
  exit 0
fi

INTAKE_DIR="${DARK_FACTORY_AUDITOR_DIR:-$SCRIPT_DIR/auditor}"
# The feedback-informed re-hunt entry point (#1567). Overridable so the offline demo can inject a stub, mirroring
# DARK_FACTORY_AUDITOR_DIR. run-audit-pass.sh NEVER submits — its terminal best case is a PENDING-HUMAN-REVIEW draft.
RUN_AUDIT_PASS="${DARK_FACTORY_RUN_AUDIT_PASS:-$SCRIPT_DIR/run-audit-pass.sh}"

# _slack_get_bot_user -> the bot's own user_id via auth.test (Bearer only), or "" (best-effort: on any failure the
# caller falls back to filtering bot messages by bot_id/subtype presence).
_slack_get_bot_user() {
  local resp http body
  resp="$(curl -sS -H "Authorization: Bearer $BOT_TOKEN" -X POST -w '\n%{http_code}' \
    "https://slack.com/api/auth.test" 2>/dev/null)"
  http="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  case "$http" in 2*) : ;; *) return 0 ;; esac
  SLACK_BODY="$body" python3 -c '
import json, os, sys
try:
    o = json.loads(os.environ.get("SLACK_BODY", "") or "")
except Exception:
    sys.exit(0)
if isinstance(o, dict) and o.get("ok") is True:
    sys.stdout.write(str(o.get("user_id", "")))
' 2>/dev/null
}

# _fetch_replies <channel> <ts> -> prints the raw JSON body on stdout + returns 0 when HTTP 2xx AND ok:true; else
# returns 1 (transient/permission failure — the caller skips WITHOUT a marker so a later run retries). A single page
# is sufficient: a bounty thread is tiny (the delivery + a handful of snippet posts + one operator reply), well
# under Slack's default page size, so no cursor pagination is needed.
_fetch_replies() {
  local channel="$1" ts="$2" resp http body ok
  resp="$(curl -sS -H "Authorization: Bearer $BOT_TOKEN" -X POST \
    --data-urlencode "channel=$channel" --data-urlencode "ts=$ts" \
    -w '\n%{http_code}' "https://slack.com/api/conversations.replies" 2>/dev/null)"
  http="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  case "$http" in 2*) : ;; *) return 1 ;; esac
  ok="$(SLACK_BODY="$body" python3 -c '
import json, os, sys
try:
    o = json.loads(os.environ.get("SLACK_BODY", "") or "")
except Exception:
    sys.stdout.write("0"); sys.exit(0)
sys.stdout.write("1" if isinstance(o, dict) and o.get("ok") is True else "0")' 2>/dev/null)"
  [ "$ok" = "1" ] || return 1
  printf '%s' "$body"
}

# _slack_confirm <channel> <thread_ts> <text> -> a threaded chat.postMessage (Bearer, 2xx AND ok:true). Best-effort:
# returns non-zero on any failure, never fatal.
_slack_confirm() {
  local channel="$1" thread="$2" text="$3" payload resp http body ok
  payload="$(SLACK_CH="$channel" SLACK_THREAD="$thread" SLACK_TXT="$text" python3 -c 'import json, os; print(json.dumps({"channel": os.environ["SLACK_CH"], "thread_ts": os.environ["SLACK_THREAD"], "text": os.environ["SLACK_TXT"]}))')"
  resp="$(curl -sS -H "Authorization: Bearer $BOT_TOKEN" -H 'Content-Type: application/json; charset=utf-8' \
    -X POST -d "$payload" -w '\n%{http_code}' "https://slack.com/api/chat.postMessage" 2>/dev/null)"
  http="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  case "$http" in 2*) : ;; *) return 1 ;; esac
  ok="$(SLACK_BODY="$body" python3 -c '
import json, os, sys
try:
    o = json.loads(os.environ.get("SLACK_BODY", "") or "")
except Exception:
    sys.stdout.write("0"); sys.exit(0)
sys.stdout.write("1" if isinstance(o, dict) and o.get("ok") is True else "0")' 2>/dev/null)"
  [ "$ok" = "1" ]
}

BOT_USER_ID="$(_slack_get_bot_user)"

# _mf_field <manifest.json> <key> -> a top-level string field (deterministic, no jq), or "" on any failure.
_mf_field() {
  python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2],""))
except Exception: pass' "$1" "$2" 2>/dev/null || true
}

# _sanitize <text> -> a filename-safe token (the classifier `stage` becomes gate-tuning/<stage>.md).
_sanitize() { printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/-/g'; }

# ==========================================================================================================
# OUTCOME->ACTION ROUTER (#1562). CHEAP helpers are local, reversible writes; SPENDY helpers are
# propose-then-greenlight. None call learn() (feedback-intake.ag already learned the deterministic signal), none
# egress to a bounty platform, and none auto-invoke a hunt (the greenlit action is a command HAND-OFF).
# ==========================================================================================================

# _apply_mark_dead <stage> <manifest> <root_cause> <submission_id> -> append `target@<commit>\treason\tsid\tts` to
# $DIR/dead-targets.txt (consumed by the intake ranker's --dead-targets skip). Grep-guarded on the `target@commit`
# key so re-runs never dup. A target that a platform rejected out-of-scope / as a known-issue is not re-queued.
_apply_mark_dead() {
  local stage="$1" mf="$2" root="$3" sid="$4" target commit key ddfile tab
  tab="$(printf '\t')"
  target="$(_mf_field "$mf" target)"
  commit="$(_mf_field "$mf" in_scope_commit)"
  if [ -z "$target" ]; then
    echo "ingest-slack-outcome.sh: no target in manifest, skipping mark-dead for $stage" >&2
    return 0
  fi
  key="$target@$commit"
  ddfile="$DIR/dead-targets.txt"
  mkdir -p "$DIR"
  if [ -f "$ddfile" ] && grep -qF "$key$tab" "$ddfile" 2>/dev/null; then
    return 0
  fi
  printf '%s\t%s\t%s\t%s\n' "$key" "$root" "$sid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$ddfile"
}

# _apply_tune_note <stage-field> <root_cause> <submission_id> <details> -> append a durable, attributed calibration
# NOTE to $DIR/gate-tuning/<stage>.md. HONEST: feedback-intake.ag already learn()s the deterministic signal on the
# gate's own topic — this note does NOT call learn() again (no double-count); the gates do not recall() it into
# their prompts yet (a recorded HOOK, not a behavior change).
_apply_tune_note() {
  local stage_field="$1" root="$2" sid="$3" details="$4" gtdir gtfile
  gtdir="$DIR/gate-tuning"
  mkdir -p "$gtdir"
  gtfile="$gtdir/$(_sanitize "$stage_field").md"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) $sid tighten: $root — $details" >> "$gtfile"
}

# _apply_reinforce_note <stage-field> <submission_id> <details> -> append a winning-path note on `accepted` (records
# the path that paid off). Same gate-tuning/<stage>.md store; NO re-learn() (feedback-intake already learned SUCCESS).
_apply_reinforce_note() {
  local stage_field="$1" sid="$2" details="$3" gtdir gtfile
  gtdir="$DIR/gate-tuning"
  mkdir -p "$gtdir"
  gtfile="$gtdir/$(_sanitize "$stage_field").md"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) $sid reinforce: winning path accepted — $details" >> "$gtfile"
}

# _apply_needs_info_draft <stage> <question> -> write $stage/FOLLOWUP.md, a SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW
# stub carrying the reviewer's requested question VERBATIM + a pointer to submission-draft.md. The deterministic
# stub is the GUARANTEED artifact; when agentis is on PATH it is best-effort ENRICHED by report-writer.ag (never
# fatal, the stub survives either way — the mock-backend precedent).
_apply_needs_info_draft() {
  local stage="$1" question="$2" f enrich
  f="$stage/FOLLOWUP.md"
  {
    printf '%s\n' "SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW"
    printf '%s\n' "# FOLLOWUP — the platform asked for more information (needs-info). Answer it in submission-draft.md,"
    printf '%s\n' "# then re-deliver via deliver-submission.sh. This is a DRAFT for human review; never auto-submitted."
    printf '%s\n' ""
    printf '%s\n' "## The reviewer's question (verbatim)"
    printf '%s\n' "$question"
    printf '%s\n' ""
    printf '%s\n' "See ./submission-draft.md for the original finding to extend."
  } > "$f"
  # Best-effort enrichment (only if agentis + report-writer.ag are present): append whatever the report writer
  # emits under a clearly-marked section. Fully non-fatal; the deterministic stub above is what the loop relies on.
  if command -v agentis >/dev/null 2>&1 && [ -f "$INTAKE_DIR/agents/report-writer.ag" ]; then
    enrich="$( cd "$INTAKE_DIR" && env SUBMISSION_DIR="$stage" agentis go agents/report-writer.ag --enable-exec --grant-pii 2>/dev/null )" || true
    if [ -n "$enrich" ]; then
      {
        printf '%s\n' ""
        printf '%s\n' "## report-writer.ag draft (best-effort, unverified — review before use)"
        printf '%s\n' "$enrich"
      } >> "$f"
    fi
  fi
}

# _propose_spendy <action> <target> <reason> <channel> <thread_ts> <stage> <outcome_reply_ts> -> post a `propose:`
# message into the thread (via _slack_confirm, so the ↻ glyph is emitted through python3 json.dumps, never dash
# printf) and write $stage/.route-proposed. PROPOSE != EXECUTE: the spend runs ONLY on a later operator `go` reply.
_propose_spendy() {
  local action="$1" target="$2" reason="$3" channel="$4" thread="$5" stage="$6" outcome_ts="$7" verb
  case "$action" in
    spendy:hunt-deeper) verb="hunt-deeper" ;;
    *)                  verb="re-hunt" ;;
  esac
  _slack_confirm "$channel" "$thread" \
    "↻ propose: $verb $target with feedback: $reason — reply \`go\` to run" \
    || echo "ingest-slack-outcome.sh: propose-spendy post failed for $stage (best-effort)" >&2
  {
    printf '%s\n' "action=$action"
    printf '%s\n' "reason=$reason"
    printf '%s\n' "outcome_reply_ts=$outcome_ts"
  } > "$stage/.route-proposed"
}

# _run_spendy_handoff <stage> <channel> <thread_ts> <manifest> <action> <reason> -> the GREENLIT action. ALWAYS
# writes $stage/RE-HUNT.md (the durable record: target@commit + the reviewer reason as guidance + a ready-to-run
# `run-audit-pass.sh …` command pre-filled from the manifest, operator clone path the ONE placeholder) and, after
# the branch, .route-greenlit. DISPATCH (#1567): resolve a target dir (--target-dir override, else a manifest
# `local_repo`/`target_dir`); when it resolves to a directory AND run-audit-pass.sh is executable AND setsid is
# present, AUTO-INVOKE the feedback-informed re-hunt DETACHED (the code-edit-job.sh setsid convention) and post
# `▶ re-hunt launched …`. Otherwise the command HAND-OFF: RE-HUNT.md is what the operator runs (not a
# coordinator-style auto-invoke), posted as `▶ greenlit …`. Never submits — the re-hunt's best case is a
# PENDING-HUMAN-REVIEW draft; RE-HUNT.md carries no submit primitive.
_run_spendy_handoff() {
  local stage="$1" channel="$2" thread="$3" mf="$4" action="$5" reason="$6"
  local target commit title location impact sev verb td rh_out pid
  target="$(_mf_field "$mf" target)"
  commit="$(_mf_field "$mf" in_scope_commit)"
  title="$(_mf_field "$mf" finding_title)"
  location="$(_mf_field "$mf" finding_location)"
  impact="$(_mf_field "$mf" finding_impact)"
  sev="$(_mf_field "$mf" severity_band)"
  case "$action" in
    spendy:hunt-deeper) verb="hunt-deeper" ;;
    *)                  verb="re-hunt" ;;
  esac
  {
    printf '%s\n' "# RE-HUNT — greenlit record for $target@$commit ($verb)"
    printf '%s\n' "#"
    printf '%s\n' "# run-audit-pass.sh threads --reviewer-feedback into the devise (#1567), so the command below re-runs"
    printf '%s\n' "# the pass AROUND the rejection reason. When a target dir was resolvable this re-hunt was ALSO auto-"
    printf '%s\n' "# invoked detached on greenlight (see .re-hunt-pid); otherwise run it yourself. Never submits."
    printf '%s\n' ""
    printf '%s\n' "## Reviewer guidance (why the last attempt was rejected)"
    printf '%s\n' "$reason"
    printf '%s\n' ""
    printf '%s\n' "## Finding to strengthen"
    printf '%s\n' "target:        $target@$commit"
    printf '%s\n' "title:         $title"
    printf '%s\n' "location:      $location"
    printf '%s\n' "impact:        $impact"
    printf '%s\n' "severity:      $sev"
    printf '%s\n' ""
    printf '%s\n' "## Ready-to-run command (fill in the operator's local clone path)"
    printf '%s\n' '```sh'
    printf '%s\n' "dark-factory/run-audit-pass.sh --live --backend claude \\"
    printf '%s\n' "  --reviewer-feedback $(_shq "$reason") \\"
    printf '%s\n' "  --target-dir <OPERATOR_CLONE_PATH_FOR_${target}@${commit}> \\"
    printf '%s\n' "  --finding-title $(_shq "$title") \\"
    printf '%s\n' "  --finding-location $(_shq "$location") \\"
    printf '%s\n' "  --finding-impact $(_shq "$impact") \\"
    printf '%s\n' "  --severity-band $(_shq "$sev") \\"
    printf '%s\n' "  --out $(_shq "$stage/re-hunt-out")"
    printf '%s\n' '```'
  } > "$stage/RE-HUNT.md"

  # DISPATCH: resolve a target dir (override wins, then a manifest local_repo/target_dir). When it resolves AND the
  # re-hunt binary + setsid are present, AUTO-INVOKE detached; else fall back to the RE-HUNT.md command HAND-OFF.
  td="$TARGET_DIR_OVERRIDE"
  [ -n "$td" ] || td="$(_mf_field "$mf" local_repo)"
  [ -n "$td" ] || td="$(_mf_field "$mf" target_dir)"
  if [ -n "$td" ] && [ -d "$td" ] && [ -x "$RUN_AUDIT_PASS" ] && command -v setsid >/dev/null 2>&1; then
    rh_out="$stage/re-hunt-out"
    mkdir -p "$rh_out"
    # SC2016: the $RH_* refs are deliberately INSIDE the single-quoted setsid body — they expand in the DETACHED
    # child from its inherited env, NOT in this launcher (the code-edit-job.sh discipline; no untrusted concat, the
    # LLM-tainted reason never reaches a command line here). Only --live/--backend/--reviewer-feedback/--target-dir/
    # --finding-*/--out are passed; run-audit-pass.sh never submits (its best case is a PENDING-HUMAN-REVIEW draft).
    export RH_BIN="$RUN_AUDIT_PASS" RH_TD="$td" RH_REASON="$reason" RH_TITLE="$title" \
           RH_LOC="$location" RH_IMPACT="$impact" RH_SEV="$sev" RH_OUT="$rh_out"
    # shellcheck disable=SC2016
    setsid bash -c '"$RH_BIN" --live --backend claude --reviewer-feedback "$RH_REASON" --target-dir "$RH_TD" --finding-title "$RH_TITLE" --finding-location "$RH_LOC" --finding-impact "$RH_IMPACT" --severity-band "$RH_SEV" --out "$RH_OUT" > "$RH_OUT/re-hunt.log" 2>&1' </dev/null >/dev/null 2>&1 &
    pid=$!
    printf '%s' "$pid" > "$stage/.re-hunt-pid"
    disown "$pid" 2>/dev/null || true
    _slack_confirm "$channel" "$thread" "▶ re-hunt launched (pid $pid) — feedback threaded" \
      || echo "ingest-slack-outcome.sh: re-hunt-launched post failed for $stage (best-effort)" >&2
  else
    _slack_confirm "$channel" "$thread" "▶ greenlit — $verb $target handed off (see RE-HUNT.md)" \
      || echo "ingest-slack-outcome.sh: greenlit post failed for $stage (best-effort)" >&2
  fi
  printf '%s\n' "greenlit $(date -u +%Y-%m-%dT%H:%M:%SZ) action=$action target=$target@$commit" > "$stage/.route-greenlit"
}

# _shq <text> -> single-quote a value for the RE-HUNT.md command template (a documentation artifact, never exec'd
# by this script; the operator runs it). Empty -> ''.
_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# _greenlight_check <stage> <channel> <thread_ts> <manifest> -> re-read the thread; if a non-bot reply whose trimmed
# text is `go` (case-insensitive) with ts > the recorded outcome_reply_ts exists, fire the hand-off. No `go` -> a
# silent no-op (no post), so a --all cron re-enters cheaply until the operator replies.
_greenlight_check() {
  local stage="$1" channel="$2" thread_ts="$3" mf="$4"
  local outcome_ts action reason replies go_hit
  [ -f "$stage/.route-proposed" ] || return 0
  outcome_ts="$(grep '^outcome_reply_ts=' "$stage/.route-proposed" 2>/dev/null | head -1 | cut -d= -f2-)"
  action="$(grep '^action='            "$stage/.route-proposed" 2>/dev/null | head -1 | cut -d= -f2-)"
  reason="$(grep '^reason='            "$stage/.route-proposed" 2>/dev/null | head -1 | cut -d= -f2-)"
  if ! replies="$(_fetch_replies "$channel" "$thread_ts")"; then
    return 0
  fi
  go_hit="$(SLACK_BODY="$replies" BOT_UID="${BOT_USER_ID:-}" OUTCOME_TS="$outcome_ts" python3 -c '
import json, os, sys
try:
    o = json.loads(os.environ.get("SLACK_BODY", "") or "")
except Exception:
    sys.exit(0)
msgs = o.get("messages", []) if isinstance(o, dict) else []
bot_uid = os.environ.get("BOT_UID", "")
try:
    floor = float(os.environ.get("OUTCOME_TS", "") or "0")
except Exception:
    floor = 0.0
for m in msgs:
    if not isinstance(m, dict):
        continue
    if m.get("bot_id") or m.get("subtype"):
        continue
    if bot_uid and m.get("user") == bot_uid:
        continue
    text = m.get("text", "")
    if not isinstance(text, str) or text.strip().lower() != "go":
        continue
    try:
        ts = float(m.get("ts", "") or "0")
    except Exception:
        ts = 0.0
    if ts > floor:
        sys.stdout.write("1"); sys.exit(0)
' 2>/dev/null)"
  [ "$go_hit" = "1" ] || return 0
  _run_spendy_handoff "$stage" "$channel" "$thread_ts" "$mf" "$action" "$reason"
}

# _route_apply <stage> <manifest> <disposition> <root_cause> <stage-field> <submission_id> <channel> <thread_ts>
#              <outcome_reply_ts> <question> -> run every cheap:* action for the classified outcome and, if any
# spendy:* action is mapped, PROPOSE it (no execute). Writes .route-applied (routed once per outcome).
_route_apply() {
  local stage="$1" mf="$2" disp="$3" root="$4" stage_field="$5" sid="$6"
  local channel="$7" thread="$8" reply_ts="$9" question="${10}"
  local actions a target
  actions="$(route_actions "$disp" "$root")"
  target="$(_mf_field "$mf" target)"
  for a in $actions; do
    case "$a" in
      cheap:mark-dead)        _apply_mark_dead "$stage" "$mf" "$root" "$sid" ;;
      cheap:tune-gate)        _apply_tune_note "$stage_field" "$root" "$sid" "$disp" ;;
      cheap:reinforce)        _apply_reinforce_note "$stage_field" "$sid" "$disp" ;;
      cheap:needs-info-draft) _apply_needs_info_draft "$stage" "$question" ;;
      spendy:*)               _propose_spendy "$a" "$target" "$root" "$channel" "$thread" "$stage" "$reply_ts" ;;
    esac
  done
  printf '%s\n' "routed $(date -u +%Y-%m-%dT%H:%M:%SZ) disposition=$disp root=$root actions=$actions" > "$stage/.route-applied"
}

# process_stage <staged-drop-dir> -> reads the thread, captures the operator's outcome reply into OUTCOME.md, folds
# it into learning via feedback-intake.ag, posts a confirmation, and marks the stage ingested. Every step is
# best-effort; a per-stage failure returns 0 (warn + skip) so `--all` never crashes a batch.
process_stage() {
  local stage="$1"
  local mf thread_ts channel replies sel reply_ts platform_response verdict payout submissionId
  local intake_out intake_line fbk_disp fbk_conf fbk_stage fbk_signal fbk_root cfg pend
  local gl_thread gl_channel

  [ -d "$stage" ] || { echo "ingest-slack-outcome.sh: not a directory, skipping: $stage" >&2; return 0; }
  mf="$stage/manifest.json"
  [ -f "$mf" ] || { echo "ingest-slack-outcome.sh: no manifest.json, skipping: $stage" >&2; return 0; }

  # GREENLIGHT PASS (#1562), BEFORE the `.outcome-ingested` short-circuit so a `--all` cron re-enters to catch a
  # later operator `go` reply on an already-PROPOSED spendy action. No proposal outstanding / already greenlit ->
  # a cheap no-op. A `go` reply fires the RE-HUNT.md hand-off (never a hunt auto-invoke).
  if [ -f "$stage/.route-proposed" ] && [ ! -f "$stage/.route-greenlit" ]; then
    gl_thread="$(_mf_field "$mf" slack_thread_ts)"
    gl_channel="$(_mf_field "$mf" slack_channel)"
    if [ -n "$gl_thread" ] && [ -n "$gl_channel" ]; then
      _greenlight_check "$stage" "$gl_channel" "$gl_thread" "$mf"
    fi
  fi

  if [ -e "$stage/.outcome-ingested" ]; then
    echo "ingest-slack-outcome.sh: already ingested, skipping: $stage" >&2
    return 0
  fi

  # The thread + channel notify-submission.sh (#1557) recorded on delivery. Either absent -> not a bot-mode staged
  # thread (or delivery failed) -> skip WITHOUT a marker.
  thread_ts="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("slack_thread_ts",""))' "$mf" 2>/dev/null || true)"
  channel="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("slack_channel",""))' "$mf" 2>/dev/null || true)"
  if [ -z "$thread_ts" ] || [ -z "$channel" ]; then
    echo "ingest-slack-outcome.sh: no slack_thread_ts/slack_channel in manifest (not a bot-mode thread), skipping: $stage" >&2
    return 0
  fi

  if ! replies="$(_fetch_replies "$channel" "$thread_ts")"; then
    echo "ingest-slack-outcome.sh: conversations.replies failed for $stage (transient/permission) — will retry" >&2
    return 0
  fi

  # SELECT the operator reply: drop bot messages (bot_id present OR a subtype OR user==our auth.test id), keep those
  # whose text has a `^outcome:` line (the #1561 default) OR a `^verdict:` line (an operator override, backward-compat),
  # take the LATEST by ts; then CAPTURE `platform_response` (everything after the `outcome:` marker, VERBATIM,
  # multi-line — the classifier reads it) + the OPTIONAL override `verdict:`/`payout:` lines. Prints a one-line JSON
  # {reply_ts, platform_response, verdict, payout}, or nothing when no qualifying reply exists.
  sel="$(SLACK_BODY="$replies" BOT_UID="${BOT_USER_ID:-}" python3 -c '
import json, os, re, sys
try:
    o = json.loads(os.environ.get("SLACK_BODY", "") or "")
except Exception:
    sys.exit(0)
msgs = o.get("messages", []) if isinstance(o, dict) else []
bot_uid = os.environ.get("BOT_UID", "")
cands = []
for m in msgs:
    if not isinstance(m, dict):
        continue
    if m.get("bot_id") or m.get("subtype"):
        continue
    if bot_uid and m.get("user") == bot_uid:
        continue
    text = m.get("text", "")
    if not isinstance(text, str):
        continue
    if not re.search(r"(?im)^\s*(outcome|verdict)\s*:", text):
        continue
    cands.append((str(m.get("ts", "")), text))
if not cands:
    sys.exit(0)
def tskey(c):
    try:
        return float(c[0])
    except Exception:
        return 0.0
cands.sort(key=tskey)
reply_ts, text = cands[-1]
# platform_response = everything from the `outcome:` marker to the end of the reply, VERBATIM (multi-line).
pr_lines = []
capturing = False
for ln in text.splitlines():
    mo = re.match(r"(?i)^\s*outcome\s*:[ \t]*(.*)$", ln)
    if mo is not None:
        capturing = True
        rest = mo.group(1)
        if rest.strip() != "":
            pr_lines.append(rest)
        continue
    if capturing:
        pr_lines.append(ln)
platform_response = "\n".join(pr_lines).strip("\n")
def field(name):
    m = re.search(r"(?im)^\s*" + re.escape(name) + r"\s*:\s*(.*?)\s*$", text)
    return m.group(1).strip() if m else ""
d = {
    "reply_ts":          reply_ts,
    "platform_response": platform_response,
    "verdict":           field("verdict"),
    "payout":            field("payout"),
}
sys.stdout.write(json.dumps(d))
' 2>/dev/null)"

  if [ -z "$sel" ]; then
    echo "ingest-slack-outcome.sh: no operator reply with an outcome: (or override verdict:) line in the $stage thread yet — will retry" >&2
    return 0
  fi

  reply_ts="$(SEL="$sel"          python3 -c 'import json,os; print(json.loads(os.environ["SEL"]).get("reply_ts",""))'          2>/dev/null || true)"
  platform_response="$(SEL="$sel" python3 -c 'import json,os; print(json.loads(os.environ["SEL"]).get("platform_response",""))' 2>/dev/null || true)"
  verdict="$(SEL="$sel"           python3 -c 'import json,os; print(json.loads(os.environ["SEL"]).get("verdict",""))'           2>/dev/null || true)"
  payout="$(SEL="$sel"            python3 -c 'import json,os; print(json.loads(os.environ["SEL"]).get("payout",""))'            2>/dev/null || true)"

  # The canonical submission_id comes from manifest.json (never the reply) — the correlation key.
  submissionId="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("submission_id",""))' "$mf" 2>/dev/null || true)"

  # WRITE OUTCOME.md in the #1561 schema (a `platform_response: |` block, 2-space indented via python3 — avoids
  # sed/awk indent subtleties), plus the aligned `verdict:`/`payout:` override lines ONLY when the operator supplied
  # an override (so feedback-intake.ag's `^verdict:` grep stays inert on the classifier path). Values passed via ENV.
  OUT_SID="$submissionId" OUT_PR="$platform_response" OUT_V="$verdict" OUT_P="$payout" \
  python3 -c '
import os, sys
sid = os.environ.get("OUT_SID", "")
pr  = os.environ.get("OUT_PR", "")
v   = os.environ.get("OUT_V", "").strip()
p   = os.environ.get("OUT_P", "").strip()
out = []
out.append("# OUTCOME — captured from the Slack thread by ingest-slack-outcome.sh (#1561); classified into learning.")
out.append("# submission_id: %s   (do NOT edit — correlation key; authoritative copy in manifest.json)" % sid)
out.append("platform_response: |")
body = pr if pr != "" else "(no platform_response pasted — see the operator override below)"
for ln in body.splitlines():
    out.append("  " + ln)
if v:
    out.append("verdict:        %s   # operator override" % v)
if p:
    out.append("payout:         %s   # operator override" % p)
sys.stdout.write("\n".join(out) + "\n")
' > "$stage/OUTCOME.md"

  fbk_disp=""; fbk_conf=""; fbk_stage="(stage n/a)"; fbk_signal=""; fbk_root=""

  # RUN feedback-intake.ag FROM the auditor colony dir (durable store) so learn() PERSISTS. Ensure .agentis + the
  # three config keys (append ONLY the missing ones, each grep-guarded so re-runs never dup a line). If agentis is
  # not on PATH we still wrote OUTCOME.md, but WARN and do NOT mark the stage (operator/cron re-runs once installed).
  if command -v agentis >/dev/null 2>&1; then
    mkdir -p "$INTAKE_DIR"
    if [ ! -d "$INTAKE_DIR/.agentis" ]; then
      ( cd "$INTAKE_DIR" && agentis init >/dev/null 2>&1 || true )
    fi
    mkdir -p "$INTAKE_DIR/.agentis"
    cfg="$INTAKE_DIR/.agentis/config"
    [ -f "$cfg" ] || : > "$cfg"
    grep -q '^learning.enabled'   "$cfg" 2>/dev/null || echo "learning.enabled = true"   >> "$cfg"
    grep -q '^experience.enabled' "$cfg" 2>/dev/null || echo "experience.enabled = true" >> "$cfg"
    grep -q 'SUBMISSION_DIR'      "$cfg" 2>/dev/null || echo "exec.env_passthrough = SUBMISSION_DIR" >> "$cfg"
    # --grant-pii: the platform_response text can carry addresses/identifiers that trip the PII heuristic; benign.
    intake_out="$( cd "$INTAKE_DIR" && env SUBMISSION_DIR="$stage" agentis go agents/feedback-intake.ag --enable-exec --enable-messaging --grant-pii 2>&1 )" || true
    # The AUTHORITATIVE FEEDBACK|<disp>|<conf>|<stage>|<SIGNAL>|<root_cause>|<rationale> line (signal is .ag-computed).
    intake_line="$(printf '%s\n' "$intake_out" | grep -E '^FEEDBACK\|' | head -1)"
    fbk_disp="$(printf '%s\n'   "$intake_line" | awk -F'|' '{print $2}')"
    fbk_conf="$(printf '%s\n'   "$intake_line" | awk -F'|' '{print $3}')"
    fbk_stage="$(printf '%s\n'  "$intake_line" | awk -F'|' '{print $4}')"
    fbk_signal="$(printf '%s\n' "$intake_line" | awk -F'|' '{print $5}')"
    fbk_root="$(printf '%s\n'   "$intake_line" | awk -F'|' '{print $6}')"
    [ -n "$fbk_stage" ] || fbk_stage="(stage n/a)"
  else
    echo "ingest-slack-outcome.sh: agentis not on PATH — wrote OUTCOME.md for $stage but deferring learn(); NOT marking ingested (re-run once the runtime is installed)" >&2
    return 0
  fi

  # CONFIDENCE GATE result. HOLD (a low-confidence / unclear classification, .ag-computed) is NOT a learn: ask a
  # human to confirm and DEFER — no `.outcome-ingested`. A `.pending-confirmation` marker keyed on the selected reply
  # ts stops a `--all` cron from re-posting the same request every sweep (post ONCE per distinct operator reply).
  pend="$stage/.pending-confirmation"
  if [ "$fbk_signal" = "HOLD" ]; then
    if [ -f "$pend" ] && grep -q "reply_ts=$reply_ts" "$pend" 2>/dev/null; then
      echo "ingest-slack-outcome.sh: HOLD already flagged for $stage (reply_ts=$reply_ts) — not re-posting (awaiting a clearer operator reply)" >&2
      return 0
    fi
    _slack_confirm "$channel" "$thread_ts" \
      "couldn't classify this outcome confidently ($fbk_disp/$fbk_conf) — reply again with a clearer 'outcome:' paste, or an explicit 'verdict: <accepted|rejected|duplicate|needs-info|out-of-scope>' to override" \
      || echo "ingest-slack-outcome.sh: confirmation-request post failed for $stage (best-effort)" >&2
    printf '%s\n' "held $(date -u +%Y-%m-%dT%H:%M:%SZ) reply_ts=$reply_ts disposition=$fbk_disp confidence=$fbk_conf" > "$pend"
    return 0
  fi

  # LEARNED: a threaded confirmation (best-effort). The SIGNAL is the .ag-computed FEEDBACK field; the stage is
  # feedback-intake's attribution.
  _slack_confirm "$channel" "$thread_ts" "outcome recorded -- learned $fbk_signal on $fbk_stage" \
    || echo "ingest-slack-outcome.sh: confirmation post failed for $stage (best-effort) — outcome already captured" >&2

  # IDEMPOTENCY: mark the stage ONLY after a learned capture+intake (never double-learn). A HOLD returns above WITHOUT
  # a marker so a later, clearer reply can still be learned.
  printf '%s\n' "ingested $(date -u +%Y-%m-%dT%H:%M:%SZ) disposition=$fbk_disp signal=$fbk_signal stage=$fbk_stage" > "$stage/.outcome-ingested"
  rm -f "$pend"

  # ROUTE PASS (#1562): turn the classified outcome into the next action(s). Deterministic (route_actions, a bash
  # case), routed once per outcome (`.route-applied`). Cheap actions apply immediately (local, reversible writes);
  # a spendy action is only PROPOSED here — it runs on a later `go` reply via the greenlight pass above.
  if [ ! -f "$stage/.route-applied" ]; then
    _route_apply "$stage" "$mf" "$fbk_disp" "$fbk_root" "$fbk_stage" "$submissionId" \
      "$channel" "$thread_ts" "$reply_ts" "$platform_response"
  fi
  return 0
}

if [ "$ALL" -eq 1 ]; then
  found=0
  for d in "$DROP_DIR"/*/; do
    [ -d "$d" ] || continue
    found=1
    process_stage "${d%/}" || true
  done
  [ "$found" -eq 1 ] || echo "ingest-slack-outcome.sh: no staged dirs under $DROP_DIR (nothing to ingest)" >&2
else
  process_stage "$STAGE" || true
fi

exit 0
