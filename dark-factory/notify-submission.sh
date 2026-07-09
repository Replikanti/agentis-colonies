#!/usr/bin/env bash
# notify-submission.sh — the RICH full-package Slack BOT-MODE sender for dark-factory (#1541, epic #1505).
#
# Where monitor/scripts/notify.sh pages a single finding-ready ALERT (one webhook POST, one exit code), THIS
# script delivers the COMPLETE, copy-paste-ready Immunefi submission package to a Slack **Bot App**: a main
# `chat.postMessage` carrying the form metadata (Project/Asset/Impact/Severity/Title + the bounty link + the
# secret-gist link), then a THREAD under that message with the long sections (Description, PoC source(s),
# REPRODUCE.md, run-evidence) uploaded as file snippets for one-click copy. Capturing the main message `ts` and
# threading file uploads beneath it is fundamentally more than notify.sh's single-post sink can do, so the rich
# flow lives in its own bash script (see the #1541 plan's rejected-alternative note).
#
# bash, NEVER sh: this script uses bash-only constructs (arrays are avoided, but `${var%$'\n'*}`, `local`, and
# `< <(...)` process substitution are used). It has its own `#!/usr/bin/env bash` shebang and every caller invokes
# it as `bash notify-submission.sh` — never `sh` / dot-source (the #1507/#1534/#1535 dash-safety lesson).
#
# NEVER-SUBMIT INVARIANT (unchanged): a bot post to the operator's OWN Slack workspace is NOT a bounty-platform
# submission — it adds no bounty-platform egress. The pipeline never submits; this is an operator page on an
# operator-owned channel, exactly like the #1538 webhook alert.
#
# Config (env, all resolved by the caller — deliver-submission.sh resolves the secret:// token to plaintext and
# hands it in via the ENVIRONMENT, never argv):
#   DARK_FACTORY_SLACK_BOT_TOKEN   the resolved bot token (`xoxb-…`); Slack app scopes chat:write + files:write
#                                  (+ optional chat:write.public). REQUIRED for bot mode.
#   DARK_FACTORY_SLACK_CHANNEL     the base channel id (`C0…`). REQUIRED for bot mode.
#   DARK_FACTORY_SLACK_CHANNEL_WARN / _HIGH   optional per-severity channel overrides (Critical/High -> _HIGH,
#                                  Medium -> _WARN, else base), mirroring notify.sh's webhook routing.
# With NO token OR NO channel this prints a one-line summary to stdout and exits 0 (offline no-op, mirrors
# notify.sh). The token appears ONLY in the `Authorization: Bearer` header — never echoed, never in a warning
# (a failure prints only the Slack `error` code).
#
# Delivery contract (both chat.postMessage and completeUploadExternal): SUCCESS = HTTP 2xx **AND** the JSON body's
# `ok == true` (parsed by python3 — a `200 {"ok":false,"error":…}` is a FAILURE, not success). A transient failure
# (5xx / non-2xx / curl transport error) retries with bounded backoff (MONITOR_NOTIFY_MAX_RETRIES /
# MONITOR_NOTIFY_BACKOFF_S, the notify.sh knob names); a hard `ok:false` is a LOUD non-retry stderr warning.
# The modern EXTERNAL file-upload flow is used (files.getUploadURLExternal + files.completeUploadExternal, scope
# files:write) — NOT the deprecated files.upload. Every upload is best-effort: any failure warns + skips, never
# fatal (a Slack outage never fails a good stage).
#
# Usage:  notify-submission.sh --stage <staged-drop-dir>
# Requires: bash + python3 + curl. Exit: always 0 for the caller's purposes (best-effort muscle); 2 = bad args.
set -u

STAGE=""
while [ $# -gt 0 ]; do case "$1" in
  --stage) [ "$#" -ge 2 ] || { echo "notify-submission.sh: --stage requires a value" >&2; exit 2; }; STAGE="$2"; shift 2;;
  -h|--help) sed -n '2,54p' "$0"; exit 0;;
  *) echo "notify-submission.sh: unknown arg: $1" >&2; exit 2;;
esac; done

[ -n "$STAGE" ] || { echo "notify-submission.sh: --stage <staged-drop-dir> is required" >&2; exit 2; }
[ -d "$STAGE" ] || { echo "notify-submission.sh: staged dir not found: $STAGE" >&2; exit 2; }

BOT_TOKEN="${DARK_FACTORY_SLACK_BOT_TOKEN:-}"
CHANNEL_BASE="${DARK_FACTORY_SLACK_CHANNEL:-}"
CHANNEL_WARN="${DARK_FACTORY_SLACK_CHANNEL_WARN:-}"
CHANNEL_HIGH="${DARK_FACTORY_SLACK_CHANNEL_HIGH:-}"

# Offline no-op: no bot token OR no channel -> one-line summary on stdout, exit 0 (mirrors notify.sh's fallback).
if [ -z "$BOT_TOKEN" ] || [ -z "$CHANNEL_BASE" ]; then
  echo "[submission:slack] bot-mode not configured (need DARK_FACTORY_SLACK_BOT_TOKEN + DARK_FACTORY_SLACK_CHANNEL) — package at $STAGE not sent to Slack"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "notify-submission.sh: curl not found but bot mode is configured — skipping Slack delivery" >&2
  exit 0
fi

MANIFEST="$STAGE/manifest.json"
if [ ! -f "$MANIFEST" ]; then
  echo "notify-submission.sh: no manifest.json in $STAGE — nothing to send" >&2
  exit 0
fi

# Retry knobs (reuse notify.sh's names; same numeric-guard idiom).
MAX_RETRIES="${MONITOR_NOTIFY_MAX_RETRIES:-3}"
case "$MAX_RETRIES" in ''|*[!0-9]*) MAX_RETRIES=3 ;; esac
BACKOFF_S="${MONITOR_NOTIFY_BACKOFF_S:-2}"
case "$BACKOFF_S" in ''|*[!0-9]*) BACKOFF_S=2 ;; esac

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/notify-submission.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

CHANNEL_ID=""   # the channel the main message is posted to; reused as completeUploadExternal channel_id.

# --- manifest readers (python3, deterministic, no jq) ---------------------------------------------------------
# _mf <dotted-key> -> a scalar string (nested via `immunefi_fields.project`); "" on any miss.
_mf() {
  MF_PATH="$MANIFEST" MF_KEY="$1" python3 -c '
import json, os, sys
try:
    d = json.load(open(os.environ["MF_PATH"]))
except Exception:
    sys.stdout.write(""); sys.exit(0)
v = d
for k in os.environ["MF_KEY"].split("."):
    v = v.get(k, "") if isinstance(v, dict) else ""
sys.stdout.write(str(v) if isinstance(v, (str, int, float)) else "")
' 2>/dev/null
}

# _mf_list <key> -> newline-separated list elements (poc_files); empty when absent/not-a-list.
_mf_list() {
  MF_PATH="$MANIFEST" MF_KEY="$1" python3 -c '
import json, os, sys
try:
    d = json.load(open(os.environ["MF_PATH"]))
except Exception:
    sys.exit(0)
v = d.get(os.environ["MF_KEY"], [])
if isinstance(v, list):
    for x in v:
        sys.stdout.write(str(x) + "\n")
' 2>/dev/null
}

# _build_main_text -> the mrkdwn main-message body (five metadata fields one-per-line for copy-paste, severity
# band, the bounty + gist links when present, and a see-thread pointer). Links use Slack mrkdwn `<url|label>`;
# an empty bounty_url or an empty/placeholder gist_url is omitted.
_build_main_text() {
  MF_PATH="$MANIFEST" python3 -c '
import json, os, sys
try:
    d = json.load(open(os.environ["MF_PATH"]))
except Exception:
    d = {}
f = d.get("immunefi_fields", {}) or {}
def g(k):
    v = f.get(k, "")
    return v if isinstance(v, str) else ""
lines = []
lines.append("*dark-factory submission package* — copy-paste ready for the Immunefi form")
lines.append("")
lines.append("*Project:* " + g("project"))
lines.append("*Asset:* " + g("asset"))
lines.append("*Impact:* " + g("impact"))
lines.append("*Severity:* " + g("severity"))
lines.append("*Title:* " + g("title"))
lines.append("")
band = str(d.get("severity_band", "") or "")
if band:
    lines.append("Severity band: " + band)
bounty = str(d.get("bounty_url", "") or "")
if bounty:
    lines.append("Program: <" + bounty + "|open the bounty program>")
gist = str(d.get("gist_url", "") or "")
if gist and not gist.startswith("<gist URL"):
    lines.append("PoC gist: <" + gist + "|secret gist>")
lines.append("")
lines.append("See this thread for the full Description + PoC snippets (copy-paste each into the form).")
lines.append("Bot post to the operator workspace — NOT a bounty-platform submission.")
sys.stdout.write("\n".join(lines))
' 2>/dev/null
}

# _strip_draft <file> -> the draft body with the ^SUBMISSION-DRAFT| marker line and the ^FIELD| lines removed
# (leading blank lines trimmed) = the clean 4-section Brief/Intro · Vulnerability Details · Impact Details ·
# References body for the Description snippet.
_strip_draft() {
  DRAFT_SRC="$1" python3 -c '
import os, sys
try:
    lines = open(os.environ["DRAFT_SRC"]).read().splitlines()
except Exception:
    sys.exit(0)
out = [l for l in lines if not (l.startswith("SUBMISSION-DRAFT|") or l.startswith("FIELD|"))]
while out and out[0].strip() == "":
    out.pop(0)
sys.stdout.write("\n".join(out) + "\n")
' 2>/dev/null
}

# _parse_ok <json-body> -> "OK\t<ts>" when ok==true, else "ERR\t<error>". The ts field is empty for endpoints
# that do not return one (completeUploadExternal).
_parse_ok() {
  SLACK_BODY="$1" python3 -c '
import json, os, sys
try:
    o = json.loads(os.environ.get("SLACK_BODY", "") or "")
except Exception:
    sys.stdout.write("ERR\tparse_error"); sys.exit(0)
if isinstance(o, dict) and o.get("ok") is True:
    sys.stdout.write("OK\t" + str(o.get("ts", "")))
else:
    sys.stdout.write("ERR\t" + (str(o.get("error", "unknown")) if isinstance(o, dict) else "not_json"))
' 2>/dev/null
}

# _parse_upload_url <json-body> -> "OK\t<upload_url>\t<file_id>" when ok==true AND an upload_url is present,
# else "ERR\t<error>".
_parse_upload_url() {
  SLACK_BODY="$1" python3 -c '
import json, os, sys
try:
    o = json.loads(os.environ.get("SLACK_BODY", "") or "")
except Exception:
    sys.stdout.write("ERR\tparse_error"); sys.exit(0)
if isinstance(o, dict) and o.get("ok") is True and o.get("upload_url"):
    sys.stdout.write("OK\t" + str(o.get("upload_url", "")) + "\t" + str(o.get("file_id", "")))
else:
    sys.stdout.write("ERR\t" + (str(o.get("error", "unknown")) if isinstance(o, dict) else "not_json"))
' 2>/dev/null
}

# _curl_json <url> <json-body> -> sets CURL_RC / CURL_HTTP / CURL_BODY. Bearer + JSON, POST. `-w '\n%{http_code}'`
# appends the status as a final line; the body is everything before it. The token is ONLY in the Authorization
# header, never a positional arg.
CURL_RC=0; CURL_HTTP=""; CURL_BODY=""
_curl_json() {
  local url="$1" body="$2" resp
  resp="$(curl -sS \
    -H "Authorization: Bearer $BOT_TOKEN" \
    -H 'Content-Type: application/json; charset=utf-8' \
    -X POST -d "$body" \
    -w '\n%{http_code}' \
    "$url" 2>/dev/null)"
  CURL_RC=$?
  CURL_HTTP="${resp##*$'\n'}"
  CURL_BODY="${resp%$'\n'*}"
}

# slack_post <channel> <text> -> echoes the message `ts` on stdout and returns 0 on success; warns + returns 1 on
# failure. SUCCESS = 2xx AND ok==true; a hard ok:false is a non-retry loud warning; 5xx/non-2xx/transport retries.
slack_post() {
  local channel="$1" text="$2" payload attempt=0 delay="$BACKOFF_S" parsed status detail
  payload="$(SLACK_CH="$channel" SLACK_TXT="$text" python3 -c 'import json, os; print(json.dumps({"channel": os.environ["SLACK_CH"], "text": os.environ["SLACK_TXT"]}))')"
  while : ; do
    _curl_json "https://slack.com/api/chat.postMessage" "$payload"
    if [ "$CURL_RC" -eq 0 ]; then
      case "$CURL_HTTP" in
        2*)
          parsed="$(_parse_ok "$CURL_BODY")"
          status="${parsed%%$'\t'*}"; detail="${parsed#*$'\t'}"
          if [ "$status" = OK ]; then
            printf '%s\n' "$detail"
            return 0
          fi
          echo "notify-submission.sh: chat.postMessage rejected (slack error: $detail) — not retrying" >&2
          return 1
          ;;
      esac
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$MAX_RETRIES" ]; then
      echo "notify-submission.sh: chat.postMessage failed after $MAX_RETRIES retries (curl_rc=$CURL_RC http=$CURL_HTTP)" >&2
      return 1
    fi
    echo "notify-submission.sh: transient chat.postMessage failure (curl_rc=$CURL_RC http=$CURL_HTTP) — retry $attempt/$MAX_RETRIES in ${delay}s" >&2
    sleep "$delay"; delay=$((delay * 2))
  done
}

# slack_upload <filepath> <title> <thread_ts> -> best-effort file snippet into the thread via the MODERN external
# upload flow: (1) files.getUploadURLExternal, (2) POST the raw bytes to the returned upload_url, (3)
# files.completeUploadExternal into thread_ts. Any failure warns + returns 1 (skip); never fatal.
slack_upload() {
  local filepath="$1" title="$2" thread="$3"
  [ -f "$filepath" ] || { echo "notify-submission.sh: upload skipped, file missing: $filepath" >&2; return 1; }
  local length resp rc gethttp getbody parsed status rest upload_url file_id up_http cbody

  length="$(wc -c < "$filepath" | tr -d ' ')"

  # (1) getUploadURLExternal — form-encoded filename+length (the token stays in the Authorization header only).
  resp="$(curl -sS \
    -H "Authorization: Bearer $BOT_TOKEN" \
    -X POST \
    --data-urlencode "filename=$title" \
    --data-urlencode "length=$length" \
    -w '\n%{http_code}' \
    "https://slack.com/api/files.getUploadURLExternal" 2>/dev/null)"
  rc=$?
  gethttp="${resp##*$'\n'}"; getbody="${resp%$'\n'*}"
  parsed="$(_parse_upload_url "$getbody")"
  status="${parsed%%$'\t'*}"
  case "$gethttp" in 2*) : ;; *) status="ERR" ;; esac
  if [ "$rc" -ne 0 ] || [ "$status" != OK ]; then
    echo "notify-submission.sh: getUploadURLExternal failed for '$title' (${parsed#*$'\t'}) — skipping upload" >&2
    return 1
  fi
  rest="${parsed#*$'\t'}"          # upload_url<TAB>file_id
  upload_url="${rest%%$'\t'*}"
  file_id="${rest#*$'\t'}"

  # (2) POST the raw bytes to the pre-signed upload URL (no token — the URL itself is the credential).
  resp="$(curl -sS -X POST --data-binary "@$filepath" -w '\n%{http_code}' "$upload_url" 2>/dev/null)"
  rc=$?
  up_http="${resp##*$'\n'}"
  if [ "$rc" -ne 0 ]; then
    echo "notify-submission.sh: raw upload POST transport error for '$title' (curl_rc=$rc) — skipping" >&2
    return 1
  fi
  case "$up_http" in 2*) : ;; *) echo "notify-submission.sh: raw upload POST for '$title' returned HTTP $up_http — skipping" >&2; return 1 ;; esac

  # (3) completeUploadExternal — thread the snippet under the main message (thread_ts) in the same channel.
  cbody="$(SLACK_FID="$file_id" SLACK_TITLE="$title" SLACK_CH="$CHANNEL_ID" SLACK_THREAD="$thread" python3 -c 'import json, os; print(json.dumps({"files": [{"id": os.environ["SLACK_FID"], "title": os.environ["SLACK_TITLE"]}], "channel_id": os.environ["SLACK_CH"], "thread_ts": os.environ["SLACK_THREAD"]}))')"
  _curl_json "https://slack.com/api/files.completeUploadExternal" "$cbody"
  case "$CURL_HTTP" in 2*) : ;; *) echo "notify-submission.sh: completeUploadExternal for '$title' returned HTTP $CURL_HTTP — skipping" >&2; return 1 ;; esac
  parsed="$(_parse_ok "$CURL_BODY")"
  if [ "${parsed%%$'\t'*}" != OK ]; then
    echo "notify-submission.sh: completeUploadExternal rejected '$title' (slack error: ${parsed#*$'\t'}) — skipping" >&2
    return 1
  fi
  return 0
}

# --- main -----------------------------------------------------------------------------------------------------
SEV_BAND="$(_mf severity_band)"
case "$SEV_BAND" in
  Critical|High) CHANNEL_ID="${CHANNEL_HIGH:-$CHANNEL_BASE}" ;;
  Medium)        CHANNEL_ID="${CHANNEL_WARN:-$CHANNEL_BASE}" ;;
  *)             CHANNEL_ID="$CHANNEL_BASE" ;;
esac
[ -n "$CHANNEL_ID" ] || CHANNEL_ID="$CHANNEL_BASE"

MAIN_TEXT="$(_build_main_text)"

# Post the main message; capture its ts for threading. A failed post is best-effort: warn + stop (no ts to thread
# file snippets under), never fail the caller.
TS="$(slack_post "$CHANNEL_ID" "$MAIN_TEXT")" || {
  echo "notify-submission.sh: main message not delivered — skipping thread uploads (package still staged at $STAGE)" >&2
  exit 0
}
if [ -z "$TS" ]; then
  echo "notify-submission.sh: main message returned no ts — skipping thread uploads" >&2
  exit 0
fi

# Description snippet: the marker/FIELD-stripped 4-section body.
DESC_FILE="$TMPD/Description.md"
_strip_draft "$STAGE/submission-draft.md" > "$DESC_FILE"
[ -s "$DESC_FILE" ] && slack_upload "$DESC_FILE" "Description.md" "$TS" || true

# Each verbatim PoC source (poc_files[] -> poc/<basename>).
POC_LIST="$(_mf_list poc_files)"
while IFS= read -r pf; do
  [ -n "$pf" ] || continue
  slack_upload "$STAGE/poc/$pf" "$pf" "$TS" || true
done < <(printf '%s\n' "$POC_LIST")

# REPRODUCE.md + the captured run-evidence when present.
REPRODUCE_REL="$(_mf reproduce)"
if [ -n "$REPRODUCE_REL" ] && [ -f "$STAGE/$REPRODUCE_REL" ]; then
  slack_upload "$STAGE/$REPRODUCE_REL" "REPRODUCE.md" "$TS" || true
fi
POC_RUN_REL="$(_mf poc_run)"
if [ -n "$POC_RUN_REL" ] && [ -f "$STAGE/$POC_RUN_REL" ]; then
  slack_upload "$STAGE/$POC_RUN_REL" "poc-run.txt" "$TS" || true
fi

exit 0
