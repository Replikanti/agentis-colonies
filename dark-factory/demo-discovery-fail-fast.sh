#!/usr/bin/env bash
# demo-discovery-fail-fast.sh — regression guard for the #2017 discovery fail-fast: cap the in-process retry
# budget of a runaway hunter cell WITHOUT killing recovery of a transient timeout.
#
# ROOT CAUSE (#2017): a non-terminating value-seam read blows through the per-cell llm.cli_timeout_ms with ZERO
# output; agentis-core then re-runs a `[llm.timeout]` `1 + llm.max_retries` times (src/llm.rs
# `attempts = 1 + max_retries`, default max_retries = 2 => 3 attempts), so a single hang costs ~3x the budget —
# up to ~90 min on an 1800s-capped dense zone. run-discovery.sh never set llm.max_retries, so every hunter cell
# inherited the default 3 attempts.
#
# FIX (two halves): (a) hunter.ag now carries a bounded-termination clause so a value-conservation lens converges
# to a terminal verdict within one budget instead of chasing consumers forever (that is the SOURCE fix — not
# testable offline, it needs a live LLM). (b) run-discovery.sh writes `llm.max_retries = 1`: it caps a genuine
# runaway at 2x the budget (down from 3x) while KEEPING one in-process retry, so a TRANSIENT timeout (a
# host-overheat de-bunch, an llm-session-slot wait, a one-off PTY/API spike) still recovers on attempt 2 instead
# of becoming an immediate FAILED cell + false `hunted_degraded` zone. Dropping to 0 would kill that recovery.
#
# Two layers (mirrors demo-experience-flags.sh / demo-cell-watchdog.sh):
#   1) SOURCE GUARD (always, CI-safe, pure grep): run-discovery.sh must emit `llm.max_retries = 1` — NOT `= 0`
#      (kills transient recovery) and NOT `>= 2` / absent (default 3 attempts). Fails the regression with no LLM.
#   2) END-TO-END MUTATION (agentis-gated, [SKIP] without agentis): drive a REAL offline `agentis go` over a
#      trivial `prompt()` probe with a stub backend, and assert the ATTEMPT budget at OUTPUT level —
#        (2a) PERSISTENT timeout, max_retries=1 -> exactly ONE `[LLM retry` line, ~2x the budget (cap holds);
#        (2b) PERSISTENT timeout, max_retries=2 -> TWO `[LLM retry` lines, ~3x the budget (strictly worse — the
#             default this fix replaces), proving `= 1` bounds the waste;
#        (2c) TRANSIENT timeout (a stateful stub that times out on attempt 1, then returns a reply on attempt 2),
#             max_retries=1 -> RECOVERS: the probe prints its REPLY, no error, exactly ONE retry line. This is
#             the load-bearing reason for `= 1` over `= 0`.
#      NO live LLM — closes the "green stub proves nothing" gap. Generous timing bounds keep it non-flaky.
#
# Read-only, offline, never-submit. Exit 0 = guard holds (or cleanly skipped); 1 = a regression; 3 = missing script.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DISCOVERY="$HERE/run-discovery.sh"

FAILS=0
note() { echo "demo-discovery-fail-fast.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -x "$DISCOVERY" ] || { note "run-discovery.sh not found / not executable: $DISCOVERY" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE GUARD (always): run-discovery.sh emits `llm.max_retries = 1` — bounded but not zero.
# ----------------------------------------------------------------------------------------------------------
note "1) source-guard: run-discovery.sh emits llm.max_retries = 1 (one retry: bounded, keeps transient recovery) ..."
if grep -Eq 'echo "llm\.max_retries = 0"' "$DISCOVERY"; then
  bad "run-discovery.sh emits llm.max_retries = 0 — this kills in-process recovery of a TRANSIENT timeout (an immediate FAILED cell -> false hunted_degraded) (#2017)"
elif grep -Eq 'echo "llm\.max_retries = [2-9]' "$DISCOVERY"; then
  bad "run-discovery.sh emits llm.max_retries >= 2 — a runaway would still burn 3x+ the per-cell budget (#2017)"
  grep -nE 'echo "llm\.max_retries = [2-9]' "$DISCOVERY" | sed 's/^/      /' >&2
elif grep -Eq 'echo "llm\.max_retries = 1"' "$DISCOVERY"; then
  ok "run-discovery.sh emits llm.max_retries = 1 — caps a runaway at 2x the budget while keeping one transient retry"
else
  bad "run-discovery.sh emits NO explicit llm.max_retries — the per-cell config inherits the default 3 attempts (#2017)"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) END-TO-END MUTATION (agentis-gated): the attempt budget + transient recovery over a real `agentis go`.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the live attempt-budget + transient-recovery mutation (layer 2)"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-discovery-fail-fast.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  ( cd "$WORK" && agentis init >/dev/null 2>&1 )

  # A trivial one-shot probe: a single prompt() whose backend behaviour we control via the stub below.
  cat > "$WORK/probe.ag" <<'AG'
cb 3000;
let r = prompt("say hi", "") -> string;
print("REPLY|" + r);
AG

  BUDGET_MS=1500

  # PERSISTENT stub = `sleep 30` (prompt piped to stdin and ignored): the child outlives the tiny
  # llm.cli_timeout_ms on EVERY attempt, so the completion loop always raises LlmError::Timeout (the retryable
  # path). TRANSIENT stub = a stateful script that times out on attempt 1 then returns a reply on attempt 2.
  cat > "$WORK/transient-stub.sh" <<EOF
#!/usr/bin/env bash
# Attempt counter persists across the backend's in-process retries within one agentis go.
C="$WORK/attempt.count"
n=\$(cat "\$C" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' "\$n" > "\$C"
# exec so the timeout kill lands on THIS process (no orphaned sleep holding the stdout pipe open).
if [ "\$n" -le 1 ]; then exec sleep 30; else printf 'TRANSIENT-RECOVERED\n'; fi
EOF
  chmod +x "$WORK/transient-stub.sh"

  gen_cfg() {  # gen_cfg <max_retries> <command> [args]
    {
      echo "llm.backend = claude"
      echo "llm.command = $2"
      [ -n "${3:-}" ] && echo "llm.args = $3"
      echo "llm.cli_timeout_ms = $BUDGET_MS"
      echo "llm.max_retries = $1"
      echo "trace.level = normal"
    } > "$WORK/.agentis/config"
  }

  run_probe() {   # run_probe <max_retries> <command> <args> <log> -> echoes elapsed seconds
    gen_cfg "$1" "$2" "$3"
    _t0=$(date +%s)
    ( cd "$WORK" && agentis go probe.ag ) > "$4" 2>&1 || true
    _t1=$(date +%s)
    echo $(( _t1 - _t0 ))
  }

  note "2) live mutation: attempt budget (max_retries=1 caps a runaway at 2x) + transient recovery (attempt 2) ..."

  # --- (2a) persistent timeout, max_retries = 1 -> ONE retry line, ~2x the budget -----------------------
  EL1="$(run_probe 1 sleep 30 "$WORK/retry1.log")"
  RETRIES1="$(grep -c '\[LLM retry' "$WORK/retry1.log" 2>/dev/null || true)"
  if grep -q '\[llm.timeout\]\|timed out' "$WORK/retry1.log" 2>/dev/null && [ "$RETRIES1" -eq 1 ]; then
    ok "max_retries=1: a persistent runaway was retried ONCE ($RETRIES1 '[LLM retry 1/1' line), ~2x the budget (${EL1}s)"
  else
    bad "max_retries=1: expected exactly 1 '[LLM retry' line on the timeout path, saw $RETRIES1 (elapsed ${EL1}s)"
    grep -n '\[LLM retry\|timed out\|Error' "$WORK/retry1.log" 2>/dev/null | head -4 | sed 's/^/      /' >&2
  fi

  # --- (2b) persistent timeout, max_retries = 2 (the OLD default) -> TWO retry lines, ~3x the budget -----
  EL2="$(run_probe 2 sleep 30 "$WORK/retry2.log")"
  RETRIES2="$(grep -c '\[LLM retry' "$WORK/retry2.log" 2>/dev/null || true)"
  if [ "$RETRIES2" -eq 2 ] && [ "$RETRIES1" -eq 1 ] && [ "$EL1" -lt "$EL2" ]; then
    ok "the same hang cost ${EL1}s at max_retries=1 (1 retry) vs ${EL2}s at the default max_retries=2 (2 retries) — the cap bounds the waste"
  else
    bad "the one-retry cap did not bound the waste (max_retries=1 ${EL1}s/${RETRIES1} retries vs max_retries=2 ${EL2}s/${RETRIES2} retries)"
  fi

  # --- (2c) TRANSIENT timeout, max_retries = 1 -> RECOVERS on attempt 2 (the reason for 1 over 0) --------
  rm -f "$WORK/attempt.count"
  ELT="$(run_probe 1 "$WORK/transient-stub.sh" "" "$WORK/transient.log")"
  RETRIEST="$(grep -c '\[LLM retry' "$WORK/transient.log" 2>/dev/null || true)"
  if grep -q '^REPLY|TRANSIENT-RECOVERED' "$WORK/transient.log" 2>/dev/null \
       && ! grep -q 'runtime error' "$WORK/transient.log" 2>/dev/null && [ "$RETRIEST" -eq 1 ]; then
    ok "max_retries=1: a TRANSIENT timeout recovered on attempt 2 (REPLY printed, no error, 1 retry) — max_retries=0 would have FAILED here (${ELT}s)"
  else
    bad "max_retries=1: a transient timeout did NOT recover (expected 'REPLY|TRANSIENT-RECOVERED', no runtime error, 1 retry; saw $RETRIEST retries in ${ELT}s)"
    grep -n 'REPLY|\|\[LLM retry\|runtime error\|timed out' "$WORK/transient.log" 2>/dev/null | head -4 | sed 's/^/      /' >&2
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — run-discovery.sh caps a runaway hunter cell at 2x budget while keeping transient recovery (#2017)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed (see #2017)" >&2
exit 1
