#!/bin/sh
# notify.sh — thin alert notifier for the Monitor colony (Dark Factory).
#
# POSTs an alert payload to a Discord/Slack incoming webhook when
# MONITOR_WEBHOOK_URL is set. Read-only / non-custodial: it only sends an
# outbound notification — it never signs, never touches funds, and holds no
# secret in the repo (the webhook URL is read from the environment).
#
# Usage:
#   MONITOR_WEBHOOK_URL=https://... ./scripts/notify.sh '<alert text>'
#   echo '<alert text>' | MONITOR_WEBHOOK_URL=https://... ./scripts/notify.sh
#
# With MONITOR_WEBHOOK_URL unset it prints the alert to stdout and exits 0 (a
# no-op sink), so the colony works out of the box without a configured webhook.
#
# POSIX sh / dash-safe: no bashisms, no arrays, no `\xHH` printf escapes. CI runs
# this under `sh` = dash.
#
# Exit codes: 0 ok (sent, or stdout fallback), 2 usage error, 3 curl missing
# while a webhook IS configured.

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

WEBHOOK="${MONITOR_WEBHOOK_URL:-}"

# No webhook configured -> print to stdout and succeed (the default no-op sink).
if [ -z "$WEBHOOK" ]; then
    echo "[monitor:alert] $MSG"
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "notify.sh: curl not found but MONITOR_WEBHOOK_URL is set" >&2
    exit 3
fi

# JSON-escape the message body with python3 (a `{"content": "..."}` payload that
# both Discord and a Slack incoming webhook accept). python3 is already a hard
# dependency of the federation (parse-toml.sh / start-colony.sh use it), so this
# adds no new requirement and is robust against quotes/newlines in the payload.
# The message is passed via the environment (NOTIFY_MSG) so no untrusted text is
# interpolated into the python source — dash-safe and injection-safe.
PAYLOAD="$(NOTIFY_MSG="$MSG" python3 -c 'import json, os; print(json.dumps({"content": os.environ["NOTIFY_MSG"]}))')"

# POST it. -s quiet, -S show errors, -f fail on HTTP error so the exit code
# reflects delivery. The webhook URL is the only secret and comes from the env.
curl -sS -f \
    -H 'Content-Type: application/json' \
    -X POST \
    -d "$PAYLOAD" \
    "$WEBHOOK" >/dev/null

echo "notify.sh: alert delivered to webhook"
exit 0
