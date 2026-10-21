#!/usr/bin/env bash
# run-agentarena-intake.sh — AgentArena intake: fetch and unpack inbox tasks (#2326, epic #2317 M1).
#
# Consumes the notifications agentarena-webhook.py (#2325) dropped into $DARK_FACTORY_DIR/agentarena/inbox/
# and, per task, fetches the TaskResponse (task_details_url) and the repo zip (task_repository_url) with the
# platform's X-API-Key, validates and unpacks them into $DARK_FACTORY_DIR/agentarena/<task_id>/
# (details.json, repo/, manifest.json). Read-only toward the platform: post_findings_url is never touched.
# All logic lives in lib/agentarena-intake.py (stdlib only); this is the named entry point.
#
# Usage: run-agentarena-intake.sh (--task <id> | --all) [--details-file F --zip-file F] [--max-files N]
#                                 [--max-bytes N] [--curl PATH] [-h]
#        run-agentarena-intake.sh --self-test
#   --task         : process inbox/<id>.json.
#   --all          : one sweep of inbox/*.json, sorted, dot-files ignored (no daemon, no watch loop).
#   --details-file : offline hatch (with --zip-file, --task only): read the TaskResponse and the repo zip from
#   --zip-file       local files instead of fetching. No network, no key resolved.
#   --max-files    : archive member cap (default 50000).
#   --max-bytes    : uncompressed-total cap, also the download cap (default 1 GiB).
#   --curl         : curl binary (default: curl on PATH). Needs curl >= 7.63 (-H @- and %{stderr}).
#   --self-test    : offline self-test (stub curl, temp state root), exit 0/1.
#
# Env:
#   AGENTARENA_API_KEY    live path only: a secret:// URI (resolved in-process by tools/parse-toml-secret.py) or
#                         the raw key. Reaches curl on stdin, never argv; stripped from curl's env.
#   AGENTARENA_API_HOSTS  comma-separated host suffixes the key may go to (default agentarena.nethermind.io).
#                         An inbox URL off the allowlist defers the task with reason=url-policy.
#   DARK_FACTORY_DIR      state root, default ~/.dark-factory.
#
# Exit: 0 unpacked / skip / no-op (--all: always, unless a usage or secret error occurs); 1 self-test failed;
#       2 usage/config; 3 secret resolution failed; 4 refused (terminal); 5 deferred (retryable).
# Statuses (manifest intake.status): unpacked | skip (non-evm) | refused <reason> | deferred <reason>.
# Full reference: docs/agentarena.md#intake-fetch-and-unpack.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
exec python3 -I "$HERE/lib/agentarena-intake.py" "$@"
