#!/usr/bin/env bash
# demo-monitor.sh — proof of value for the Dark Factory monitor colony
# (#1889, extended to the real cross-daemon delivery path by #1891).
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
#      invariant-watcher's MONITOR_* env contract, start-colony.sh exporting it,
#      and the #1891 store hand-off SHAPE: the coordinator writes
#      `monitor:alert:pending`, the notifier READS it (and no longer `listen()`s
#      for `monitor:alert`), and nothing else writes the delivery key — the
#      single-writer property the dedup design rests on. Holds with no runtime.
#   2) LIVE ([SKIP] unless agentis + anvil + cast are all present): boot anvil,
#      deploy the fixture, derive a real watch-spec via run-live-watch.sh
#      --spec-fixture, and daemon_guard_spawn THREE real daemons — the shipped
#      invariant-watcher.ag + coordinator.ag + notifier.ag, one process each,
#      exactly the layout scripts/start-colony.sh creates. It asserts, at OUTPUT
#      level:
#        (a) the live notifier.ag delivers a page to the sink through the real
#            scripts/notify.sh (its heartbeat POST arrives — notifier.ag's
#            forward() -> notify.sh -> sink proven end to end);
#        (b) the live invariant-watcher.ag reads the fixture as `ok` while the
#            invariant HOLDS (a positive control — the agent is really reading,
#            not stuck), then FLIPS to `verdict":"violated"` in its durable
#            blackboard memo once mintUnbacked() breaks solvency (the real agent
#            DETECTING the live break);
#        (c) DELIVERED THROUGH THE STORE: the coordinator daemon fuses that
#            signal, writes `monitor:alert:pending`, and the SEPARATE notifier
#            daemon reads it and pages the sink — a `"kind":"fused"` body lands
#            in the sink with no bypass anywhere in the chain;
#        (d) DEDUP: with the invariant still violated, further ticks do NOT
#            re-page — the fused count stays exactly 1 (a store read has no
#            implicit dequeue, so `notifier:last_delivered` is load-bearing);
#        (e) NEW ALERT: posting a second blackboard signal (`monitor:signal:pause`
#            = paused, as the pause-state-watcher would) changes the fused
#            signature, so the coordinator re-pages and the sink count reaches 2.
#
# Why a store hand-off and not the bus (#1891): on agentis v1.28.0 emit()/listen()
# are IN-PROCESS, so a bus event never crosses the daemon boundary that the
# shipped one-.ag-per-process layout creates (agentis-core #961, rigorously
# reproduced). The colony therefore routes the last mile over the same shared
# blackboard the watcher -> coordinator hop already used. Cells (c)-(e) exercise
# that hop for real across three separate daemons; nothing is bypassed. (The
# #1889 revision of this demo drove notify.sh by hand at this point because the
# bus hop was dead — that stopgap is gone.)
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
  ok "notifier.ag forwards each alert to scripts/notify.sh (the store -> webhook bridge)"
else
  bad "notifier.ag does not reference scripts/notify.sh — the delivery bridge is gone"
fi

# --- the #1891 store hand-off SHAPE (the cross-daemon-safe delivery contract) ---
# The bus is #961-blind between daemons, so the last mile MUST ride the shared
# blackboard: the coordinator writes `monitor:alert:pending`, the notifier reads
# it, and nothing else writes it (single writer => no last-writer-wins drop).
if grep -qF 'memo_write("monitor:alert:pending"' "$AGENTS/coordinator.ag"; then
  ok "coordinator.ag writes the fused alert to the monitor:alert:pending store key (#1891)"
else
  bad "coordinator.ag no longer writes monitor:alert:pending — the delivery hand-off is gone (#1891)"
fi

if grep -qF 'recall_latest("monitor:alert:pending")' "$AGENTS/notifier.ag"; then
  ok "notifier.ag reads the fused alert off monitor:alert:pending (the cross-daemon-safe inbox)"
else
  bad "notifier.ag does not read monitor:alert:pending — the notifier inbox is disconnected (#1891)"
fi

if grep -qF 'listen("monitor:alert"' "$AGENTS/notifier.ag"; then
  bad "notifier.ag still listen()s for monitor:alert — the in-process bus never delivers across daemons (#961)"
else
  ok "notifier.ag does NOT listen() on the bus (the #961-blind hop is gone)"
fi

if grep -qF 'memo_write("notifier:last_delivered"' "$AGENTS/notifier.ag"; then
  ok "notifier.ag records notifier:last_delivered (a store read has no dequeue — dedup is load-bearing)"
else
  bad "notifier.ag has no notifier:last_delivered marker — a persisted alert would re-page every tick (#1891)"
fi

WATCHER_AGENTS="flow-watcher governance-watcher invariant-watcher liquidity-watcher oracle-watcher pause-state-watcher"
stray_emit=""
for a in $WATCHER_AGENTS; do
  grep -qF 'emit("monitor:alert"' "$AGENTS/$a.ag" && stray_emit="$stray_emit $a"
done
if [ -z "$stray_emit" ]; then
  ok "no watcher emits a direct monitor:alert — every signal reaches the page via the coordinator's fusion"
else
  bad "watcher(s) still emit a dead direct monitor:alert on the #961-blind bus:$stray_emit"
fi

stray_writer=""
for a in $WATCHER_AGENTS notifier; do
  grep -qF 'memo_write("monitor:alert:pending"' "$AGENTS/$a.ag" && stray_writer="$stray_writer $a"
done
if [ -z "$stray_writer" ]; then
  ok "the coordinator is the SOLE writer of monitor:alert:pending (no last-writer-wins race)"
else
  bad "second writer(s) of monitor:alert:pending break the single-writer contract:$stray_writer"
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
  note "2) live: real invariant-watcher.ag + coordinator.ag + notifier.ag (3 daemons) over a local anvil + SolvencyFixture ..."

  # shellcheck source=/dev/null
  . "$LIB"
  # shellcheck source=/dev/null
  . "$DAEMON_GUARD"
  export SOLVENCY_FIXTURE_BIN="$MON/lib/solvency-fixture.bin"

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-monitor.XXXXXX")"
  SINK_LOG="$WORK/sink.log"
  SINK_PID=""
  : > "$SINK_LOG"

  # One EXIT trap reaps every live resource: the three daemons (group-scoped via
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
    ( cd "$WORK" && agentis memo set "coordinator:confidence" "0.7" >/dev/null 2>&1 || true )
    ( cd "$WORK" && agentis memo set "notifier:confidence" "0.7" >/dev/null 2>&1 || true )

    # --- e) spawn the REAL, checked-in agents (absolute paths, no copy) ---
    # THREE separate daemons under one daemon-guard scope — the exact layout
    # scripts/start-colony.sh creates, so the watcher -> coordinator -> notifier
    # chain is exercised across process boundaries, not inside one runtime.
    CASTBIN="$(command -v cast)"
    daemon_guard_init "$WORK"
    IW_ENV="MONITOR_CAST=$CASTBIN MONITOR_RPC_URL=$RPC MONITOR_TARGET=$ADDR MONITOR_INV_SPEC=$WORK/watch-spec.json COLONY_DIR=$MON MONITOR_WEBHOOK_URL=$SINK_URL"
    # shellcheck disable=SC2086 # IW_ENV is a deliberate space-separated env prefix
    daemon_guard_spawn --cwd "$WORK" --log "$WORK/iw.log" -- \
      env $IW_ENV agentis daemon "$AGENTS/invariant-watcher.ag" \
        --colony monitor --enable-exec --enable-messaging --tick-interval 3000 >/dev/null
    # shellcheck disable=SC2086
    daemon_guard_spawn --cwd "$WORK" --log "$WORK/co.log" -- \
      env $IW_ENV agentis daemon "$AGENTS/coordinator.ag" \
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

    # --- i) DELIVERED THROUGH THE STORE (#1891): the coordinator daemon fuses the ---
    #        watcher's signal, writes monitor:alert:pending, and the SEPARATE
    #        notifier daemon reads it and pages the sink. Nothing in this cell is
    #        driven by the demo — every hop is a live daemon. The delivered POST
    #        body is JSON-in-JSON escaped, so match the `fused` token (unique to
    #        the coordinator's consolidated payload, `"kind":"fused"`).
    fused_found=0
    if [ -n "$ALERT" ]; then
      i=0
      while [ "$i" -lt 40 ]; do
        grep -q 'fused' "$SINK_LOG" 2>/dev/null && { fused_found=1; break; }
        sleep 1
        i=$((i + 1))
      done
      if [ "$fused_found" -eq 1 ]; then
        ok "the fused page was DELIVERED across THREE daemons via the store hand-off (coordinator -> monitor:alert:pending -> notifier -> notify.sh -> sink) — no bypass"
      else
        bad "no fused page reached the sink through monitor:alert:pending (see $WORK/co.log and $WORK/nf.log)"
      fi
    else
      skip "no violation detected upstream — the store-delivery assertions are skipped"
    fi

    # --- j) DEDUP: the condition PERSISTS, so further ticks must NOT re-page. ---
    #        A store read has no implicit dequeue: without notifier:last_delivered
    #        the same pending alert would be forwarded on every single tick.
    if [ "$fused_found" -eq 1 ]; then
      sleep 18   # ~6 further ticks at --tick-interval 3000
      fused_n="$(grep -c 'fused' "$SINK_LOG" 2>/dev/null || true)"
      if [ "${fused_n:-0}" -eq 1 ]; then
        ok "a persistent violation paged EXACTLY ONCE over ~6 further ticks (notifier:last_delivered dedup holds)"
      else
        bad "a persistent violation was re-paged ${fused_n:-0} times — the delivery dedup is broken (see $WORK/nf.log)"
      fi

      # --- k) NEW ALERT: a second blackboard signal (as the pause-state-watcher ---
      #        would post) changes the fused signature, so the coordinator must
      #        re-page and the notifier must deliver again.
      ( cd "$WORK" && agentis memo set "monitor:signal:pause" \
          '{"watcher":"pause","verdict":"paused","severity":"high"}' >/dev/null 2>&1 || true )
      repage=0
      i=0
      while [ "$i" -lt 40 ]; do
        fused_n="$(grep -c 'fused' "$SINK_LOG" 2>/dev/null || true)"
        [ "${fused_n:-0}" -ge 2 ] && { repage=1; break; }
        sleep 1
        i=$((i + 1))
      done
      if [ "$repage" -eq 1 ]; then
        ok "a CHANGED fused picture (a second watcher signal) paged again — the dedup suppresses repeats, not new alerts"
      else
        bad "a changed fused picture never re-paged (count stuck at ${fused_n:-0}) — new alerts are being swallowed (see $WORK/co.log)"
      fi
    else
      skip "no fused page delivered — the dedup / new-alert assertions are skipped"
    fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the monitor colony's detect -> deliver path holds on the real agents (#1889, #1891)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed (#1889, #1891)" >&2
exit 1
