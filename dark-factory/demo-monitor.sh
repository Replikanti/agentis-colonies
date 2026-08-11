#!/usr/bin/env bash
# demo-monitor.sh — proof of value for the Dark Factory monitor colony (#1889).
#
# The monitor colony is a paid-monitoring proposition: it must (a) DETECT a
# protocol invariant breaking on live chain state and (b) DELIVER that as a page
# to a customer's webhook. This demo proves both on the REAL, checked-in agents
# (no copy — a change to a shipped .ag is what the demo exercises), over a
# throwaway local anvil + the minimal SolvencyFixture, with an OUTPUT-level
# assertion (a POST body a real HTTP sink receives), per the
# "gate on OUTPUT, not INPUT" lesson.
#
# Two layers, modelled on demo-experience-flags.sh:
#   1) SOURCE GUARD (always, CI-safe): the wiring must exist regardless of
#      toolchain — the 8 agent files, notifier.ag -> scripts/notify.sh, the
#      invariant-watcher's MONITOR_* env contract, and start-colony.sh exporting
#      it. Holds even with no runtime installed.
#   2) LIVE ([SKIP] unless agentis + anvil + cast are all present): boot anvil,
#      deploy the fixture, derive a real watch-spec via run-live-watch.sh
#      --spec-fixture, and daemon_guard_spawn the REAL invariant-watcher.ag +
#      notifier.ag. It asserts, at OUTPUT level:
#        (a) the live notifier.ag delivers a page to the sink through the real
#            scripts/notify.sh (its heartbeat POST arrives — notifier.ag's
#            forward() -> notify.sh -> sink proven end to end);
#        (b) the live invariant-watcher.ag reads the fixture as `ok` while the
#            invariant HOLDS (a positive control — the agent is really reading,
#            not stuck), then FLIPS to `verdict":"violated"` in its durable
#            blackboard memo once mintUnbacked() breaks solvency (the real agent
#            DETECTING the live break);
#        (c) that exact violation payload the watcher produced is DELIVERED to
#            the sink through the real scripts/notify.sh — invoked exactly as
#            notifier.ag invokes it — so a broken invariant becomes a delivered
#            page (`verdict":"violated"` lands in the sink).
#
# LIMITATION (stated, not hidden): on agentis v1.28.0 the emit()/listen() bus is
# IN-PROCESS — an emit() from the invariant-watcher daemon is NOT delivered to
# the separately-spawned notifier daemon's listen() (verified: a minimal
# cross-daemon emit/listen pair never delivers; `agentis colony send` rejects the
# `monitor:alert` event name). So the demo does NOT rely on that cross-process
# hop: it proves the watcher's live detection (b) and the notifier's live
# delivery (a) independently on the real agents, and bridges them (c) with the
# watcher's REAL output payload driven through the notifier's REAL delivery call.
# Every piece — fixture, anvil, watch-spec derivation, cast reads, verdict logic,
# notify.sh delivery, sink receipt — is the shipped code; only the in-process bus
# hop between two daemons (an agentis runtime limitation, not this colony's code)
# is bypassed.
#
# Read-only / non-custodial: the only chain is a local anvil this demo boots and
# tears down; the fixture is self-test scaffolding, never a real target.
#
# Exit 0 = guards hold (or Layer 2 cleanly skipped); 1 = a regression.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
MON="$HERE/monitor"
AGENTS="$MON/agents"
LIB="$MON/lib/solvency-fixture.sh"
RUN_LIVE_WATCH="$HERE/run-live-watch.sh"
DAEMON_GUARD="$REPO_ROOT/tools/lib/daemon-guard.sh"

FAILS=0
note() { echo "demo-monitor.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*" >&2; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE GUARD (always): the monitor wiring must exist regardless of toolchain.
# ----------------------------------------------------------------------------------------------------------
note "1) source-guard: the monitor colony's detect -> deliver wiring ..."

MONITOR_AGENTS="coordinator flow-watcher governance-watcher invariant-watcher liquidity-watcher notifier oracle-watcher pause-state-watcher"
missing=""
for a in $MONITOR_AGENTS; do
  [ -f "$AGENTS/$a.ag" ] || missing="$missing $a"
done
if [ -z "$missing" ]; then
  ok "all 8 monitor agents present (coordinator + 6 watchers + notifier)"
else
  bad "monitor agent file(s) missing:$missing"
fi

if grep -q 'scripts/notify.sh' "$AGENTS/notifier.ag"; then
  ok "notifier.ag forwards each alert to scripts/notify.sh (the bus -> webhook bridge)"
else
  bad "notifier.ag does not reference scripts/notify.sh — the delivery bridge is gone"
fi

miss_env=""
for v in MONITOR_INV_SPEC MONITOR_TARGET MONITOR_RPC_URL; do
  grep -q "getenv(\"$v\")" "$AGENTS/invariant-watcher.ag" || miss_env="$miss_env $v"
done
if [ -z "$miss_env" ]; then
  ok "invariant-watcher.ag reads the MONITOR_INV_SPEC / MONITOR_TARGET / MONITOR_RPC_URL env contract"
else
  bad "invariant-watcher.ag missing getenv for:$miss_env"
fi

miss_exp=""
for v in MONITOR_INV_SPEC MONITOR_TARGET MONITOR_RPC_URL MONITOR_CAST MONITOR_WEBHOOK_URL; do
  grep -Eq "^export .*\b$v\b|\b$v\b" "$MON/scripts/start-colony.sh" || miss_exp="$miss_exp $v"
done
if [ -z "$miss_exp" ]; then
  ok "start-colony.sh exports the watcher/notifier env contract (MONITOR_CAST/RPC_URL/TARGET/INV_SPEC/WEBHOOK_URL)"
else
  bad "start-colony.sh does not export:$miss_exp"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) LIVE (agentis + anvil + cast gated): the real agents over a local anvil + fixture.
# ----------------------------------------------------------------------------------------------------------
have_all=1
for dep in agentis anvil cast; do
  command -v "$dep" >/dev/null 2>&1 || have_all=0
done

if [ "$have_all" -eq 0 ]; then
  skip "agentis / anvil / cast not all on PATH — install the toolchain to run the live detect+deliver cells"
else
  note "2) live: real invariant-watcher.ag + notifier.ag over a local anvil + SolvencyFixture ..."

  # shellcheck source=/dev/null
  . "$LIB"
  # shellcheck source=/dev/null
  . "$DAEMON_GUARD"
  export SOLVENCY_FIXTURE_BIN="$MON/lib/solvency-fixture.bin"

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-monitor.XXXXXX")"
  SINK_LOG="$WORK/sink.log"
  SINK_PID=""
  : > "$SINK_LOG"

  # One EXIT trap reaps every live resource: the two daemons (group-scoped via
  # daemon-guard), anvil, the sink, and the workspace — no orphan survives.
  # shellcheck disable=SC2317,SC2329  # trap-invoked cleanup; older shellcheck flags SC2317, newer SC2329
  cleanup() {
    _rc=$?
    daemon_guard_teardown "$WORK" >/dev/null 2>&1 || true
    [ -n "$SINK_PID" ] && kill "$SINK_PID" 2>/dev/null || true
    fixture_stop "${FIXTURE_ANVIL_PID:-}"
    rm -rf "$WORK" 2>/dev/null || true
    return "$_rc"
  }
  trap cleanup EXIT INT TERM

  # --- a) boot anvil + deploy the fixture (supply == assets: the invariant HOLDS) ---
  PORT="$(fixture_pick_port)"
  RPC="http://127.0.0.1:$PORT"
  if ! fixture_start_anvil "$PORT" "$WORK/anvil.log"; then
    bad "anvil failed to come up (see $WORK/anvil.log)"
  else
    ADDR="$(fixture_deploy "$RPC" 1000 1000)"
    case "$ADDR" in
      0x*) ok "deployed SolvencyFixture at $ADDR (totalSupply=1000 == totalAssets=1000, invariant holds)" ;;
      *)   bad "fixture deploy failed (no contract address)"; ADDR="" ;;
    esac
  fi

  if [ -n "${ADDR:-}" ]; then
    # --- b) derive a real watch-spec via run-live-watch.sh --spec-fixture ---
    printf '%s\n' '[{"label":"solvency","lhs_sig":"totalSupply()","rhs_sig":"totalAssets()","rhs_const":"","rel":"le","margin_bp":0}]' \
      > "$WORK/spec-fixture.json"
    if sh "$RUN_LIVE_WATCH" --address "$ADDR" --rpc-url "$RPC" \
         --spec-fixture "$WORK/spec-fixture.json" --out "$WORK/watch-spec.json" >"$WORK/rlw.log" 2>&1 \
       && [ -s "$WORK/watch-spec.json" ]; then
      ok "run-live-watch.sh --spec-fixture derived a watch-spec (the derive-once CLI step) at watch-spec.json"
    else
      bad "run-live-watch.sh --spec-fixture did not emit a watch-spec (see $WORK/rlw.log)"
    fi

    # --- c) local HTTP sink: append every POST body (the customer's webhook receiver stand-in) ---
    SINK_PORT="$(fixture_pick_port)"
    SINK_URL="http://127.0.0.1:$SINK_PORT"
    cat > "$WORK/sink.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
LOG = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(n) if n else b""
        with open(LOG, "ab") as f:
            f.write(body + b"\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a):
        pass
HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY
    # Plain background (NOT setsid): SINK_PID is then the real python pid the trap
    # can kill — a setsid launcher exits immediately and would orphan the sink.
    python3 "$WORK/sink.py" "$SINK_LOG" "$SINK_PORT" >/dev/null 2>&1 &
    SINK_PID=$!
    sleep 0.5

    # --- d) isolated agentis workspace: env allowlist + experience/learning + confidence seed ---
    ( cd "$WORK" && agentis init >/dev/null 2>&1 || true )
    {
      echo "experience.enabled = true"
      echo "learning.enabled = true"
      echo "exec.default_timeout_ms = 30000"
      echo "exec.env_passthrough = MONITOR_CAST,MONITOR_RPC_URL,MONITOR_TARGET,MONITOR_INV_SPEC,COLONY_DIR,MONITOR_WEBHOOK_URL"
    } >> "$WORK/.agentis/config"
    ( cd "$WORK" && agentis memo set "invariant-watcher:confidence" "0.7" >/dev/null 2>&1 || true )
    ( cd "$WORK" && agentis memo set "notifier:confidence" "0.7" >/dev/null 2>&1 || true )

    # --- e) spawn the REAL, checked-in agents (absolute paths, no copy) ---
    CASTBIN="$(command -v cast)"
    daemon_guard_init "$WORK"
    IW_ENV="MONITOR_CAST=$CASTBIN MONITOR_RPC_URL=$RPC MONITOR_TARGET=$ADDR MONITOR_INV_SPEC=$WORK/watch-spec.json COLONY_DIR=$MON MONITOR_WEBHOOK_URL=$SINK_URL"
    # shellcheck disable=SC2086 # IW_ENV is a deliberate space-separated env prefix
    daemon_guard_spawn --cwd "$WORK" --log "$WORK/iw.log" -- \
      env $IW_ENV agentis daemon "$AGENTS/invariant-watcher.ag" \
        --colony monitor --enable-exec --enable-messaging --tick-interval 3000 >/dev/null
    # shellcheck disable=SC2086
    daemon_guard_spawn --cwd "$WORK" --log "$WORK/nf.log" -- \
      env $IW_ENV agentis daemon "$AGENTS/notifier.ag" \
        --colony monitor --enable-exec --enable-messaging --tick-interval 3000 >/dev/null

    # --- f) baseline: watcher reads `ok`, notifier delivers a heartbeat to the sink ---
    # Give both daemons a few ticks with the invariant still holding.
    base_ok=0
    i=0
    while [ "$i" -lt 15 ]; do
      _sig="$( cd "$WORK" && agentis memo get "monitor:signal:invariant" 2>/dev/null )"
      case "$_sig" in
        *'"verdict":"ok"'*) base_ok=1; break ;;
      esac
      sleep 1
      i=$((i + 1))
    done
    if [ "$base_ok" -eq 1 ]; then
      ok "invariant-watcher.ag read the fixture LIVE as \"verdict\":\"ok\" while solvency holds (positive control — the agent is really reading, not stuck)"
    else
      bad "invariant-watcher.ag never wrote a live \"verdict\":\"ok\" baseline (see $WORK/iw.log)"
    fi

    # The delivered POST body is JSON-in-JSON ({"content":"{\"kind\":\"heartbeat\"...}"}),
    # so match the token `heartbeat` (unique to the notifier heartbeat payload) rather
    # than an unescaped field form.
    hb_found=0
    i=0
    while [ "$i" -lt 20 ]; do
      grep -q 'heartbeat' "$SINK_LOG" 2>/dev/null && { hb_found=1; break; }
      sleep 1
      i=$((i + 1))
    done
    if [ "$hb_found" -eq 1 ]; then
      ok "notifier.ag delivered a heartbeat to the sink via the real scripts/notify.sh (forward() -> notify.sh -> webhook proven end to end)"
    else
      bad "notifier.ag never delivered a heartbeat to the sink (the forward() -> notify.sh bridge is broken; see $WORK/nf.log)"
    fi

    # --- g) break the invariant on the live fixture ---
    fixture_break "$RPC" "$ADDR" 500
    note "injected mintUnbacked(500): totalSupply now $(fixture_read "$RPC" "$ADDR" 'totalSupply()') > totalAssets $(fixture_read "$RPC" "$ADDR" 'totalAssets()')"

    # --- h) the live invariant-watcher.ag DETECTS the break in its durable memo ---
    ALERT=""
    i=0
    while [ "$i" -lt 25 ]; do
      _sig="$( cd "$WORK" && agentis memo get "monitor:signal:invariant" 2>/dev/null )"
      case "$_sig" in
        *'"verdict":"violated"'*) ALERT="$_sig"; break ;;
      esac
      sleep 1
      i=$((i + 1))
    done
    if [ -n "$ALERT" ]; then
      ok "invariant-watcher.ag DETECTED the live break: \"verdict\":\"violated\" in its blackboard memo (real agent, real cast reads, real verdict logic)"
    else
      bad "invariant-watcher.ag never flipped to \"verdict\":\"violated\" after the break (see $WORK/iw.log)"
    fi

    # --- i) DELIVER that exact violation payload through the real notify.sh (the ---
    #        notifier's own delivery call) -> assert it lands in the sink. ---
    if [ -n "$ALERT" ]; then
      MONITOR_WEBHOOK_URL="$SINK_URL" MONITOR_ALERT_BODY="$ALERT" \
        sh "$MON/scripts/notify.sh" "$ALERT" >"$WORK/deliver.log" 2>&1 || true
      # `violated` appears in the sink only for this delivered violation page (the
      # body is JSON-in-JSON escaped, so match the token, not an unescaped field form).
      del_found=0
      i=0
      while [ "$i" -lt 10 ]; do
        grep -q 'violated' "$SINK_LOG" 2>/dev/null && { del_found=1; break; }
        sleep 1
        i=$((i + 1))
      done
      if [ "$del_found" -eq 1 ]; then
        ok "the violation was DELIVERED to the sink through the real scripts/notify.sh — a broken invariant becomes a delivered page"
      else
        bad "the violation payload did not reach the sink through notify.sh (see $WORK/deliver.log)"
      fi
    else
      skip "no violation payload captured — delivery assertion skipped (upstream detection failed)"
    fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the monitor colony's detect -> deliver path holds on the real agents (#1889)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed (#1889)" >&2
exit 1
