#!/bin/sh
# notify.sh — hardened alert notifier for the Monitor colony (Dark Factory).
#
# POSTs an alert payload to a Discord/Slack incoming webhook. Read-only /
# non-custodial: it only sends an outbound notification — it never signs, never
# touches funds, and holds no secret in the repo (the webhook URL is read from
# the environment).
#
# Usage:
#   MONITOR_WEBHOOK_URL=https://... ./scripts/notify.sh '<alert text>'
#   echo '<alert text>' | MONITOR_WEBHOOK_URL=https://... ./scripts/notify.sh
#
# With NO webhook configured it prints the alert to stdout and exits 0 (a no-op
# sink), so the colony works out of the box without a configured webhook.
#
# Hardening (#1094), all optional — unset config preserves the single-webhook
# behaviour exactly:
#   * Retry/backoff — a transient webhook failure (5xx / curl network error) is
#     retried with bounded exponential backoff so a single failure does not drop
#     a page. Tunables: MONITOR_NOTIFY_MAX_RETRIES (default 3),
#     MONITOR_NOTIFY_BACKOFF_S (initial backoff seconds, default 2, doubled each
#     retry). A 4xx (a bad request / mis-configured webhook) is NOT retried.
#   * Sink-side dedup — a page is keyed on its alert SIGNATURE (severity + kind +
#     verdict, or the whole body when those are absent) and suppressed if an
#     identical signature was sent within MONITOR_NOTIFY_DEDUP_COOLDOWN_S
#     (default 0 = disabled). Defence-in-depth over the coordinator's bus-level
#     dedup. Last-sent signatures persist to a small state file
#     (MONITOR_NOTIFY_STATE_DIR, default ${XDG_STATE_HOME:-$HOME/.local/state}/
#     dark-factory-monitor).
#   * Severity routing — `warn` vs `high` route to different channels via
#     MONITOR_WEBHOOK_URL_WARN / MONITOR_WEBHOOK_URL_HIGH, each falling back to
#     MONITOR_WEBHOOK_URL when unset. Severity is read from the alert JSON's
#     "severity" field (high|warn|low|info|none); a non-JSON body routes to the
#     base URL.
#   * Slack bot-mode single post (#1541) — when MONITOR_SLACK_BOT_TOKEN (an
#     `xoxb-…`, scope chat:write) AND MONITOR_SLACK_CHANNEL (`C0…`) are set, the
#     alert is delivered via a single chat.postMessage (Bearer auth, JSON
#     {channel,text}) instead of the webhook; SUCCESS = HTTP 2xx AND ok==true (a
#     `200 {"ok":false}` is a delivery failure, exit 4). Optional
#     MONITOR_SLACK_CHANNEL_WARN / _HIGH route per severity, mirroring the webhook
#     _WARN/_HIGH pattern. Bot vars UNSET -> the webhook path + stdout no-op are
#     byte-identical to before. The RICH threaded full-package sender is a
#     separate script (dark-factory/notify-submission.sh); this is the single-post
#     path only. The token is only ever placed in the Authorization header.
#
# POSIX sh / dash-safe: no bashisms, no arrays, no `\xHH` printf escapes. CI runs
# this under `sh` = dash.
#
# Exit codes: 0 ok (sent, deduped, or stdout fallback), 2 usage error, 3 curl
# missing while a webhook IS configured, 4 permanent delivery failure after
# exhausting retries.

set -eu

# Read the alert message from $1 if given, else from stdin.
if [ "$#" -ge 1 ]; then
    MSG="$1"
else
    MSG="$(cat)"
fi

if [ -z "${MSG:-}" ]; then
    echo "notify.sh: empty alert message" >&2
    exit 2
fi

# --- severity routing ----------------------------------------------------------
# Read the "severity" field from the alert JSON; "" when the body is not JSON or
# carries no severity. python3 is already a hard dependency of the federation.
SEVERITY="$(NOTIFY_MSG="$MSG" python3 -c '
import json, os, sys
try:
    obj = json.loads(os.environ["NOTIFY_MSG"])
    sys.stdout.write(str(obj.get("severity", "")) if isinstance(obj, dict) else "")
except Exception:
    sys.stdout.write("")
')"

BASE_URL="${MONITOR_WEBHOOK_URL:-}"
case "$SEVERITY" in
    high)
        WEBHOOK="${MONITOR_WEBHOOK_URL_HIGH:-$BASE_URL}"
        ;;
    warn)
        WEBHOOK="${MONITOR_WEBHOOK_URL_WARN:-$BASE_URL}"
        ;;
    *)
        WEBHOOK="$BASE_URL"
        ;;
esac

# --- delivery mode (#1541, additive) -------------------------------------------
# A Slack BOT token + channel take precedence over the webhook: a single
# chat.postMessage (Bearer auth, JSON {channel,text}) so the monitor colony (and
# the #1538 finding-ready ping) can page a bot workspace too. The RICH threaded
# full-package sender is a separate script (dark-factory/notify-submission.sh);
# this is only the SINGLE-post path. Bot vars UNSET -> MODE resolves exactly as
# the pre-#1541 webhook selection did, so the webhook path and the stdout no-op
# fallback are byte-identical to before. Optional MONITOR_SLACK_CHANNEL_WARN /
# _HIGH override the base channel per severity, mirroring the webhook routing.
MODE=""
BOT_CHANNEL=""
if [ -n "${MONITOR_SLACK_BOT_TOKEN:-}" ] && [ -n "${MONITOR_SLACK_CHANNEL:-}" ]; then
    MODE=bot
    case "$SEVERITY" in
        high) BOT_CHANNEL="${MONITOR_SLACK_CHANNEL_HIGH:-$MONITOR_SLACK_CHANNEL}" ;;
        warn) BOT_CHANNEL="${MONITOR_SLACK_CHANNEL_WARN:-$MONITOR_SLACK_CHANNEL}" ;;
        *)    BOT_CHANNEL="$MONITOR_SLACK_CHANNEL" ;;
    esac
elif [ -n "$WEBHOOK" ]; then
    MODE=webhook
fi

# No delivery target configured for this severity -> print to stdout and succeed
# (the default no-op sink, behaviour preserved when nothing is configured).
if [ -z "$MODE" ]; then
    echo "[monitor:alert] $MSG"
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "notify.sh: curl not found but a webhook is configured" >&2
    exit 3
fi

# --- sink-side dedup -----------------------------------------------------------
# A stable signature for this alert: severity + kind + verdict when the body is
# JSON, else a hash of the whole body. The same condition yields the same
# signature, so an identical page within the cooldown window is suppressed.
COOLDOWN_S="${MONITOR_NOTIFY_DEDUP_COOLDOWN_S:-0}"
case "$COOLDOWN_S" in
    ''|*[!0-9]*) COOLDOWN_S=0 ;;
esac

if [ "$COOLDOWN_S" -gt 0 ]; then
    SIGNATURE="$(NOTIFY_MSG="$MSG" python3 -c '
import hashlib, json, os, sys
body = os.environ["NOTIFY_MSG"]
try:
    obj = json.loads(body)
    if isinstance(obj, dict):
        sig = "|".join(str(obj.get(k, "")) for k in ("severity", "kind", "verdict"))
    else:
        sig = ""
except Exception:
    sig = ""
if not sig.strip("|"):
    sig = "raw:" + hashlib.sha256(body.encode("utf-8")).hexdigest()[:16]
sys.stdout.write(hashlib.sha256(sig.encode("utf-8")).hexdigest()[:16])
')"

    STATE_DIR="${MONITOR_NOTIFY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dark-factory-monitor}"
    STATE_FILE="$STATE_DIR/notify-dedup.state"
    mkdir -p "$STATE_DIR"
    NOW_S="$(date -u +%s)"

    # Look up the last-sent timestamp for this signature (state lines: "<sig> <ts>").
    LAST_TS=0
    if [ -f "$STATE_FILE" ]; then
        FOUND="$(grep -- "^$SIGNATURE " "$STATE_FILE" 2>/dev/null | tail -n 1 || true)"
        if [ -n "$FOUND" ]; then
            LAST_TS="${FOUND#* }"
            case "$LAST_TS" in
                ''|*[!0-9]*) LAST_TS=0 ;;
            esac
        fi
    fi

    AGE_S=$((NOW_S - LAST_TS))
    # A negative age (clock rollback after a write, or a tampered state file) must
    # NEVER suppress a genuine page — only a fresh, in-cooldown duplicate is dropped
    # (QA #1103: defence on the page-delivery path).
    if [ "$LAST_TS" -gt 0 ] && [ "$AGE_S" -ge 0 ] && [ "$AGE_S" -lt "$COOLDOWN_S" ]; then
        echo "notify.sh: suppressed duplicate alert (signature $SIGNATURE, ${AGE_S}s < ${COOLDOWN_S}s cooldown)"
        exit 0
    fi

    # Record this send (drop the prior line for this signature, keep the rest,
    # then append the fresh timestamp). Atomic via a temp file + mv.
    TMP_STATE="$STATE_FILE.tmp.$$"
    if [ -f "$STATE_FILE" ]; then
        grep -v -- "^$SIGNATURE " "$STATE_FILE" 2>/dev/null > "$TMP_STATE" || true
    else
        : > "$TMP_STATE"
    fi
    echo "$SIGNATURE $NOW_S" >> "$TMP_STATE"
    mv "$TMP_STATE" "$STATE_FILE"
fi

# --- retry/backoff knobs (shared by both delivery modes) -----------------------
# Bounded exponential retry on a transient failure. curl exit codes: 22 = HTTP
# >= 400 (with -f); we re-probe the actual status to distinguish a retryable 5xx
# from a permanent 4xx. A curl transport error (non-22 non-zero) is retryable.
MAX_RETRIES="${MONITOR_NOTIFY_MAX_RETRIES:-3}"
case "$MAX_RETRIES" in
    ''|*[!0-9]*) MAX_RETRIES=3 ;;
esac
BACKOFF_S="${MONITOR_NOTIFY_BACKOFF_S:-2}"
case "$BACKOFF_S" in
    ''|*[!0-9]*) BACKOFF_S=2 ;;
esac

# --- Slack bot-mode single post (#1541) ----------------------------------------
# chat.postMessage with a Bearer token + JSON {channel,text}. SUCCESS = HTTP 2xx
# AND the body's ok==true (python3 parse) — a `200 {"ok":false,"error":…}` is a
# delivery FAILURE (exit 4), never success. A 5xx / transport error retries with
# the same bounded backoff as the webhook path. The token is passed ONLY in the
# Authorization header and never echoed (a failure prints only the Slack error
# code). Reached only when MODE=bot; the webhook path below is untouched.
if [ "$MODE" = bot ]; then
    BOT_PAYLOAD="$(NOTIFY_MSG="$MSG" NOTIFY_CHANNEL="$BOT_CHANNEL" python3 -c 'import json, os; print(json.dumps({"channel": os.environ["NOTIFY_CHANNEL"], "text": os.environ["NOTIFY_MSG"]}))')"
    attempt=0
    delay="$BACKOFF_S"
    while : ; do
        set +e
        RESP="$(curl -sS \
            -H "Authorization: Bearer $MONITOR_SLACK_BOT_TOKEN" \
            -H 'Content-Type: application/json; charset=utf-8' \
            -X POST \
            -d "$BOT_PAYLOAD" \
            -w '\n%{http_code}' \
            "https://slack.com/api/chat.postMessage" 2>/dev/null)"
        CURL_RC=$?
        set -e
        HTTP_CODE="$(printf '%s\n' "$RESP" | tail -n 1)"
        BODY="$(printf '%s\n' "$RESP" | sed '$d')"
        if [ "$CURL_RC" -eq 0 ]; then
            case "$HTTP_CODE" in
                2*)
                    OKV="$(NOTIFY_BODY="$BODY" python3 -c '
import json, os, sys
try:
    o = json.loads(os.environ.get("NOTIFY_BODY", "") or "")
except Exception:
    sys.stdout.write("err:parse_error"); sys.exit(0)
if isinstance(o, dict) and o.get("ok") is True:
    sys.stdout.write("ok")
else:
    sys.stdout.write("err:" + (str(o.get("error", "unknown")) if isinstance(o, dict) else "not_json"))
')"
                    if [ "$OKV" = ok ]; then
                        echo "notify.sh: alert delivered to Slack bot channel $BOT_CHANNEL (HTTP $HTTP_CODE)"
                        exit 0
                    fi
                    echo "notify.sh: Slack bot rejected the alert (${OKV#err:}) — not retrying" >&2
                    exit 4
                    ;;
            esac
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -gt "$MAX_RETRIES" ]; then
            echo "notify.sh: bot delivery failed after $MAX_RETRIES retries (curl_rc=$CURL_RC http=$HTTP_CODE)" >&2
            exit 4
        fi
        echo "notify.sh: transient bot failure (curl_rc=$CURL_RC http=$HTTP_CODE) — retry $attempt/$MAX_RETRIES in ${delay}s" >&2
        sleep "$delay"
        delay=$((delay * 2))
    done
fi

# --- webhook payload (#1094, unchanged) ----------------------------------------
# JSON-escape the message into a `{"content": "..."}` body that both Discord and
# a Slack incoming webhook accept. The message is passed via the environment
# (NOTIFY_MSG) so no untrusted text is interpolated into the python source —
# dash-safe and injection-safe.
PAYLOAD="$(NOTIFY_MSG="$MSG" python3 -c 'import json, os; print(json.dumps({"content": os.environ["NOTIFY_MSG"]}))')"

attempt=0
delay="$BACKOFF_S"
while : ; do
    # Capture the HTTP status; -s quiet, -S show transport errors. Do NOT use -f
    # here so a 4xx/5xx still yields a status code rather than just exit 22.
    set +e
    HTTP_CODE="$(curl -sS \
        -o /dev/null \
        -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -X POST \
        -d "$PAYLOAD" \
        "$WEBHOOK" 2>/dev/null)"
    CURL_RC=$?
    set -e

    if [ "$CURL_RC" -eq 0 ]; then
        case "$HTTP_CODE" in
            2*)
                echo "notify.sh: alert delivered to webhook (HTTP $HTTP_CODE)"
                exit 0
                ;;
            4*)
                echo "notify.sh: webhook rejected the alert (HTTP $HTTP_CODE) — not retrying" >&2
                exit 4
                ;;
            *)
                : # 5xx (or other) -> retryable, fall through
                ;;
        esac
    fi

    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$MAX_RETRIES" ]; then
        echo "notify.sh: delivery failed after $MAX_RETRIES retries (curl_rc=$CURL_RC http=$HTTP_CODE)" >&2
        exit 4
    fi
    echo "notify.sh: transient failure (curl_rc=$CURL_RC http=$HTTP_CODE) — retry $attempt/$MAX_RETRIES in ${delay}s" >&2
    sleep "$delay"
    delay=$((delay * 2))
done
