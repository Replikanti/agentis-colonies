#!/usr/bin/env bash
# demo-cell-watchdog.sh — OFFLINE, DETERMINISTIC proof of lib/cell-watchdog.sh (#1982). No agentis, no LLM, no
# network: it drives the watchdog over tiny local stub "engines" and pins the load-bearing behaviour —
#   (a) a HUNG engine (writes once, then goes silent) is force-killed once its cell dir is stale, well before it
#       would finish on its own; the wrapper returns non-zero so the caller's fail-forward path fires.
#   (b) a LIVE engine (writes a heartbeat every second) is NEVER killed and its exit code is preserved.
#   (c) STALE=0 disables the watchdog (pure pass-through): the engine's exit code is returned verbatim.
# Uses tiny (2-4s) bounds so the whole demo runs in seconds.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CELLWD="$HERE/lib/cell-watchdog.sh"

FAILS=0
note() { echo "demo-cell-watchdog.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -f "$CELLWD" ] || { note "cell-watchdog.sh not found: $CELLWD" >&2; exit 3; }
command -v setsid >/dev/null 2>&1 || { note "setsid not available — cell-watchdog is pass-through on this host; skipping kill assertions" >&2; \
  note "(c) pass-through still testable ..."; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-cell-watchdog.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CELL="$WORK/cell"; mkdir -p "$CELL"

# ----------------------------------------------------------------------------------------------------------
# (a) HUNG engine — writes once then sleeps far past the stale bound. Watchdog must kill it EARLY.
cat > "$WORK/hung.sh" <<EOF
#!/usr/bin/env bash
echo start > "$CELL/heartbeat"
sleep 30
EOF
chmod +x "$WORK/hung.sh"

if command -v setsid >/dev/null 2>&1; then
  note "a) a hung (silent) cell is force-killed once stale, not left to run ..."
  rm -f "$CELL/heartbeat"
  _t0=$(date +%s)
  bash "$CELLWD" "$CELL" 2 1 -- bash "$WORK/hung.sh" >/dev/null 2>&1
  _rc=$?
  _t1=$(date +%s); _el=$(( _t1 - _t0 ))
  if [ "$_rc" -ne 0 ] && [ "$_el" -lt 15 ]; then
    ok "a) hung cell killed in ${_el}s (rc=$_rc != 0) — well before the 30s stub end; caller fail-forwards"
  else
    bad "a) hung cell NOT bounded (rc=$_rc, elapsed=${_el}s; expected non-zero rc within ~5s)"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# (b) LIVE engine — heartbeats every second, exits 0. Watchdog must NOT kill it; exit code preserved.
cat > "$WORK/live.sh" <<EOF
#!/usr/bin/env bash
for _i in 1 2 3 4 5; do echo beat > "$CELL/heartbeat"; sleep 1; done
exit 0
EOF
chmod +x "$WORK/live.sh"

if command -v setsid >/dev/null 2>&1; then
  note "b) a live (heartbeating) cell is never false-killed; its exit code is preserved ..."
  rm -f "$CELL/heartbeat"
  bash "$CELLWD" "$CELL" 3 1 -- bash "$WORK/live.sh" >/dev/null 2>&1
  _rc=$?
  if [ "$_rc" -eq 0 ]; then
    ok "b) live cell ran to completion (rc=0) — a working cell is never false-killed"
  else
    bad "b) live cell was wrongly killed (rc=$_rc, expected 0)"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# (c) STALE=0 disables the watchdog: pure pass-through, engine exit code returned verbatim.
cat > "$WORK/rc7.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$WORK/rc7.sh"
note "c) STALE=0 disables the watchdog (pass-through): engine exit code returned verbatim ..."
bash "$CELLWD" "$CELL" 0 1 -- bash "$WORK/rc7.sh" >/dev/null 2>&1
_rc=$?
if [ "$_rc" -eq 7 ]; then
  ok "c) pass-through returns the engine's exit code verbatim (rc=7)"
else
  bad "c) pass-through did not preserve the exit code (rc=$_rc, expected 7)"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — cell-watchdog.sh bounds a hung cell, spares a live one, and passes through when disabled (#1982)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
