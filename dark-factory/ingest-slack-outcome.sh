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
# NEVER-SUBMIT INVARIANT (unchanged): every network call this script makes is to `https://slack.com/api/...` on the
# operator's OWN workspace. It adds NO bounty-platform egress and never submits — reading a thread + confirming is
# an operator-workspace action, exactly like the notify.sh page and the notify-submission.sh delivery.
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
# Usage:  ingest-slack-outcome.sh (--stage <staged-drop-dir> | --all) [--drop-dir DIR]
# Requires: bash + python3 + curl (+ agentis to fold into learning). Exit: 0 always (best-effort); 2 = bad args.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"
DROP_DIR="${DROP_DIR:-$DIR/drop}"

STAGE=""
ALL=0
while [ $# -gt 0 ]; do case "$1" in
  --stage)    [ "$#" -ge 2 ] || { echo "ingest-slack-outcome.sh: --stage requires a value" >&2; exit 2; }; STAGE="$2"; shift 2;;
  --all)      ALL=1; shift;;
  --drop-dir) [ "$#" -ge 2 ] || { echo "ingest-slack-outcome.sh: --drop-dir requires a value" >&2; exit 2; }; DROP_DIR="$2"; shift 2;;
  -h|--help)  sed -n '2,44p' "$0"; exit 0;;
  *) echo "ingest-slack-outcome.sh: unknown arg: $1" >&2; exit 2;;
esac; done

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

# signal_upper <disposition> -> the DETERMINISTIC signal (uppercase), the SAME disposition->signal map
# feedback-intake.ag pins: accepted->SUCCESS, rejected/closed/duplicate/out-of-scope->FAILURE, needs-info->PARTIAL.
# Runtime-absent fallback ONLY: when agentis is on PATH the confirmation signal is taken from the FEEDBACK line's
# .ag-computed field, never from here (#1561).
signal_upper() {
  case "$1" in
    accepted)                              echo SUCCESS ;;
    rejected|closed|duplicate|out-of-scope) echo FAILURE ;;
    needs-info)                            echo PARTIAL ;;
    *)                                     echo PARTIAL ;;
  esac
}

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

# process_stage <staged-drop-dir> -> reads the thread, captures the operator's outcome reply into OUTCOME.md, folds
# it into learning via feedback-intake.ag, posts a confirmation, and marks the stage ingested. Every step is
# best-effort; a per-stage failure returns 0 (warn + skip) so `--all` never crashes a batch.
process_stage() {
  local stage="$1"
  local mf thread_ts channel replies sel reply_ts platform_response verdict payout submissionId
  local intake_out intake_line fbk_disp fbk_conf fbk_stage fbk_signal cfg pend

  [ -d "$stage" ] || { echo "ingest-slack-outcome.sh: not a directory, skipping: $stage" >&2; return 0; }
  mf="$stage/manifest.json"
  [ -f "$mf" ] || { echo "ingest-slack-outcome.sh: no manifest.json, skipping: $stage" >&2; return 0; }

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

  fbk_disp=""; fbk_conf=""; fbk_stage="(stage n/a)"; fbk_signal=""

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
