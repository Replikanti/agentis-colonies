#!/usr/bin/env bash
# contest-watch.sh — a durable watcher for newly-opened audit competitions.
#
# Polls the audit-competition platforms and notifies when a NEW contest opens, so a fresh permissionless
# contest (where bug density — and the value of an early audit pass — is highest) can be picked up
# day-1. Designed to run as a HOST cron so it survives across sessions:
#
#   chmod +x ~/contest-watch.sh
#   ( crontab -l 2>/dev/null; echo '*/20 * * * * ~/contest-watch.sh >> ~/.dark-factory/watch.log 2>&1' ) | crontab -
#
# On a NEW contest it appends a line to $NOTIFY and (if set) hits $WEBHOOK / runs $ON_NEW. Check
# ~/.dark-factory/watch.log or wire $WEBHOOK to a Slack/Discord/ntfy URL or $ON_NEW to your own alert.
set -eu

DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"
STATE="$DIR/seen-contests.txt"
NOTIFY="$DIR/new-contests.txt"
WEBHOOK="${CONTEST_WATCH_WEBHOOK:-}"   # optional: a POST URL (Slack/Discord/ntfy) to alert
ON_NEW="${CONTEST_WATCH_ON_NEW:-}"     # optional: a command run per new contest, gets the line on stdin
mkdir -p "$DIR"; touch "$STATE"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit_new() {  # $1 = unique key, $2 = human line
  grep -qxF "$1" "$STATE" 2>/dev/null && return 0
  printf '%s\n' "$1" >> "$STATE"
  local line; line="[$(ts)] NEW $2"
  printf '%s\n' "$line" | tee -a "$NOTIFY"
  [ -n "$WEBHOOK" ] && curl -sS --max-time 15 -X POST "$WEBHOOK" \
     -H 'content-type: application/json' --data "{\"text\":$(printf '%s' "$line" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}" >/dev/null 2>&1 || true
  [ -n "$ON_NEW" ] && printf '%s\n' "$line" | sh -c "$ON_NEW" >/dev/null 2>&1 || true
}

# --- Sherlock (cleanest JSON API) ---
# Write the JSON to a file and pass its path as argv[1]; the heredoc is python's stdin (the code), so
# there is no pipe-vs-heredoc stdin clash (shellcheck SC2259).
curl -sS --max-time 20 https://mainnet-contest.sherlock.xyz/contests -o "$DIR/.sherlock.json" 2>/dev/null \
  || echo '[]' > "$DIR/.sherlock.json"
python3 - "$DIR/.sherlock.json" <<'PY' 2>/dev/null | while IFS= read -r row; do
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
# The live API returns a paginated object {"items":[...],"pages":N}; page 1 (newest) holds any RUNNING
# contest. Accept both that and a bare list. (Finished contests fill later pages — not worth paging for.)
items = d if isinstance(d,list) else (d.get('items') if isinstance(d,dict) else [])
for c in (items or []):
    if not isinstance(c,dict): continue
    if str(c.get('status','')).upper()!='RUNNING': continue
    cid=c.get('id'); title=str(c.get('title','')).replace('|',' ')
    print(f"sherlock:{cid}|Sherlock contest RUNNING: {title} (id {cid}) -- https://audits.sherlock.xyz/contests/{cid}")
PY
  key="${row%%|*}"; human="${row#*|}"; emit_new "$key" "$human"
done

# --- Cantina + Code4rena: light HTML probe (best-effort; extend with their APIs if needed) ---
for url in "https://cantina.xyz/competitions" "https://code4rena.com/audits"; do
  H="$(curl -sS --max-time 20 -A 'Mozilla/5.0' "$url" 2>/dev/null || true)"
  # crude: flag if the page mentions an actively-open competition keyword cluster not already seen.
  # (Platforms are SPA/RSC — treat a hit as "go look", keyed by url+date so it pings at most once/day.)
  if printf '%s' "$H" | grep -qiE 'accepting submissions|live competition|submissions open|active competition'; then
    emit_new "probe:$url:$(date -u +%F)" "Possible open competition at $url — verify manually"
  fi
done

echo "[$(ts)] checked (sherlock + cantina + c4); $(wc -l < "$STATE" 2>/dev/null || echo 0) seen total" >&2
