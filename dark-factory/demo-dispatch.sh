#!/usr/bin/env bash
# demo-dispatch.sh — #1014 M1: OFFLINE, DETERMINISTIC proof that the `hunt` DISPATCH now lives in the
# substrate, with NO network and NO real LLM.
#
# run-coordinator.sh used to route the coordinator's chosen `hunt` through a shell `case` (stub_outcome /
# real_outcome) to derive the gate verdict, then fed it back. M1 moves that ONTO the substrate: in ONE
# `agentis go coordinator.ag`, the coordinator DECIDES the hunt (prints `ACTION|hunt|...`), emits it over
# the IN-PROCESS bus (`dark-factory:dispatch`), and a sibling agent fn (hunt_dispatch, mirroring
# auditor/agents/dispatcher.ag) `listen`s it, derives the verdict from the HUNT_FIXTURE fact, writes it to
# the DURABLE `coordinator:last_outcome` memo, and prints `DISPATCH|hunt|...`. The shell loop then READS
# the verdict from that memo (the only substrate-native cross-process channel) instead of a shell `case`.
#
# This demo proves the four things that make it real:
#   (1) ONE `agentis go` prints BOTH the decision (`ACTION|hunt|...`) and the dispatch (`DISPATCH|hunt|...`)
#       — same process, NO shell `case` between them.
#   (2) A SEPARATE `agentis memo get coordinator:last_outcome` reads back `hunt|<sub>|<cls>|<verdict>` (the
#       verdict crossed the process boundary via the durable memo, as it does to the shell loop).
#   (3) A re-run reproduces the (1) markers BYTE-for-BYTE (deterministic; the verdict is a fixture, not RNG).
#   (4) The verdict MATCHES the HUNT_FIXTURE rule deterministically — flip the fixture, the verdict flips.
#
# Everything is deterministic and offline: the coordinator's choice is a fact+policy argmax (no RNG), the
# dispatch verdict comes from HUNT_FIXTURE (no LLM, no prompt()), and the backend is `mock` (zero cost).
#
# Usage:  dark-factory/demo-dispatch.sh
# Requires: the `agentis` binary on PATH. Exit 0 = all four proven; non-zero = an assertion failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
command -v agentis >/dev/null 2>&1 || { echo "demo-dispatch.sh: agentis binary not on PATH" >&2; exit 3; }
COORD_AG="$HERE/auditor/agents/coordinator.ag"
DISPATCH_AG="$HERE/auditor/agents/dispatcher.ag"
[ -f "$COORD_AG" ]   || { echo "demo-dispatch.sh: coordinator agent not found at $COORD_AG" >&2; exit 3; }
[ -f "$DISPATCH_AG" ] || { echo "demo-dispatch.sh: dispatcher agent not found at $DISPATCH_AG" >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
note() { echo "demo-dispatch.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

# A fresh single-step agentis store with experience enabled (so the coordinator can learn()/decide()) and
# the dispatch facts whitelisted. $1 = store dir. Configured EXACTLY like run-coordinator.sh.
init_store() {
  _d="$1"; mkdir -p "$_d"; cp "$COORD_AG" "$_d/coordinator.ag"; cp "$DISPATCH_AG" "$_d/dispatcher.ag"
  ( cd "$_d" && agentis init >/dev/null 2>&1 )
  {
    echo "llm.backend = mock"
    echo "trace.level = normal"
    echo "exec.env_passthrough = SCOPE,CLASS_FITNESS,POLICY,PENDING,BUDGET,DRY_STREAK,DRY_CAP,PREV_ACTION,PREV_KEY,LAST_OUTCOME,DISPATCH_ENABLED,HUNT_FIXTURE,DISPATCH_ARGS"
    echo "exec.default_timeout_ms = 30000"
    echo "learning.enabled = true"
    echo "experience.enabled = true"
  } > "$_d/.agentis/config"
}

# Run ONE combined decision+dispatch in store $1 with the env in $2.. (KEY=VALUE pairs). Prints the run's
# stdout filtered to the ACTION| / DISPATCH| markers (the two lines the demo asserts on), in order. The
# coordinator decides a hunt and dispatches it in the SAME process because DISPATCH_ENABLED is set.
run_combined() {
  _store="$1"; shift
  ( cd "$_store" && env \
      SCOPE="${SCOPE:-}" CLASS_FITNESS="${CLASS_FITNESS:-}" POLICY="${POLICY:-}" \
      PENDING="${PENDING:-}" BUDGET="${BUDGET:-10}" DRY_STREAK="${DRY_STREAK:-0}" DRY_CAP="${DRY_CAP:-3}" \
      PREV_ACTION="${PREV_ACTION:-}" PREV_KEY="${PREV_KEY:-}" LAST_OUTCOME="${LAST_OUTCOME:-}" \
      DISPATCH_ENABLED=1 HUNT_FIXTURE="${HUNT_FIXTURE:-}" \
      "$@" agentis go coordinator.ag --enable-exec --enable-messaging 2>/dev/null ) \
    | grep -E '^(ACTION|DISPATCH)\|'
}

# A SEPARATE process reads the durable verdict memo (the cross-process channel the shell loop uses).
read_outcome_memo() { ( cd "$1" && agentis memo get coordinator:last_outcome ) 2>/dev/null | tail -1; }

# Run the STANDALONE dispatcher.ag (its DISPATCH_ARGS entry) in store $1 for `subsystem|class` $2 with the
# HUNT_FIXTURE in $3. This exercises auditor/agents/dispatcher.ag directly — the same fns coordinator.ag
# inlines — so the demo doubles as a SYNC-GUARD: the standalone agent must produce the byte-identical
# DISPATCH| marker + memo as the inlined coordinator path, or the two copies have drifted.
run_standalone() {
  ( cd "$1" && env DISPATCH_ARGS="$2" HUNT_FIXTURE="$3" \
      agentis go dispatcher.ag --enable-exec --enable-messaging 2>/dev/null ) \
    | grep -E '^DISPATCH\|'
}

# A scope where vault accounting|C1 is the clearly highest-fitness lens, so the coordinator chooses to HUNT
# it (the action the dispatch covers). The fixture maps that subsystem to a definite verdict.
SCOPE_FX=$'vault accounting|C1\nreentrancy|C8\ncross-chain|C3'
FIT_FX="C1=0.55;C8=0.10;C3=-0.20"

echo "=================================================================================="
echo " (1) ONE agentis go prints BOTH ACTION|hunt|... and DISPATCH|hunt|... (same process)"
echo "=================================================================================="

init_store "$WORK/confirm"
OUT1=$(SCOPE="$SCOPE_FX" CLASS_FITNESS="$FIT_FX" PENDING="" BUDGET=10 DRY_STREAK=0 \
       HUNT_FIXTURE="vault*=confirmed;reentr*=refuted" run_combined "$WORK/confirm")
note "single-go markers:"
printf '%s\n' "$OUT1" | sed 's/^/    /'

ACTION_LINE="$(printf '%s\n' "$OUT1" | grep -E '^ACTION\|hunt\|' | head -1)"
DISPATCH_LINE="$(printf '%s\n' "$OUT1" | grep -E '^DISPATCH\|hunt\|' | head -1)"
case "$ACTION_LINE"   in ACTION\|hunt\|vault\ accounting\|C1\|*)   ok "ACTION| decision present: chose to HUNT vault accounting|C1";; *) bad "expected an 'ACTION|hunt|vault accounting|C1|...' line, got '$ACTION_LINE'";; esac
case "$DISPATCH_LINE" in DISPATCH\|hunt\|vault\ accounting\|C1\|confirmed) ok "DISPATCH| outcome present in the SAME process: confirmed";; *) bad "expected 'DISPATCH|hunt|vault accounting|C1|confirmed', got '$DISPATCH_LINE'";; esac
if [ -n "$ACTION_LINE" ] && [ -n "$DISPATCH_LINE" ]; then
  ok "decision AND dispatch came from one agentis go — no shell case between them"
else
  bad "the single go did not emit both the ACTION| and the DISPATCH| line"
fi

echo
echo "=================================================================================="
echo " (2) A SEPARATE process reads the durable verdict from coordinator:last_outcome"
echo "=================================================================================="

MEMO="$(read_outcome_memo "$WORK/confirm")"
note "coordinator:last_outcome (read in a separate agentis process) -> $MEMO"
case "$MEMO" in hunt\|vault\ accounting\|C1\|confirmed) ok "memo holds 'hunt|<sub>|<cls>|<verdict>' = hunt|vault accounting|C1|confirmed";; *) bad "expected 'hunt|vault accounting|C1|confirmed' in the memo, got '$MEMO'";; esac

echo
echo "=================================================================================="
echo " (3) A re-run reproduces the markers BYTE-for-BYTE (deterministic, no RNG)"
echo "=================================================================================="

init_store "$WORK/confirm2"
OUT2=$(SCOPE="$SCOPE_FX" CLASS_FITNESS="$FIT_FX" PENDING="" BUDGET=10 DRY_STREAK=0 \
       HUNT_FIXTURE="vault*=confirmed;reentr*=refuted" run_combined "$WORK/confirm2")
if [ "$OUT1" = "$OUT2" ]; then
  ok "two independent runs produced byte-identical ACTION|/DISPATCH| markers"
else
  bad "the two runs DIFFERED:"
  diff <(printf '%s\n' "$OUT1") <(printf '%s\n' "$OUT2") | sed 's/^/      /' >&2 || true
fi

echo
echo "=================================================================================="
echo " (4) The verdict MATCHES the HUNT_FIXTURE rule — flip the fixture, the verdict flips"
echo "=================================================================================="

# SAME decision facts, a DIFFERENT fixture rule for the chosen subsystem -> the dispatch verdict must
# follow the fixture (confirmed earlier, refuted now), proving the verdict is the fixture's, not fixed.
init_store "$WORK/refute"
OUT3=$(SCOPE="$SCOPE_FX" CLASS_FITNESS="$FIT_FX" PENDING="" BUDGET=10 DRY_STREAK=0 \
       HUNT_FIXTURE="vault*=refuted;reentr*=confirmed" run_combined "$WORK/refute")
DISPATCH3="$(printf '%s\n' "$OUT3" | grep -E '^DISPATCH\|hunt\|' | head -1)"
MEMO3="$(read_outcome_memo "$WORK/refute")"
note "fixture vault*=refuted -> dispatch: $DISPATCH3"
case "$DISPATCH3" in DISPATCH\|hunt\|vault\ accounting\|C1\|refuted) ok "same decision, fixture vault*=refuted -> DISPATCH verdict = refuted (follows the fixture)";; *) bad "expected 'DISPATCH|hunt|vault accounting|C1|refuted', got '$DISPATCH3'";; esac
case "$MEMO3" in hunt\|vault\ accounting\|C1\|refuted) ok "memo verdict also flipped to refuted";; *) bad "expected the memo to flip to 'hunt|vault accounting|C1|refuted', got '$MEMO3'";; esac

# And a no-match subsystem must default to dry (the stub_outcome END rule), deterministically.
init_store "$WORK/dry"
OUT4=$(SCOPE="$SCOPE_FX" CLASS_FITNESS="$FIT_FX" PENDING="" BUDGET=10 DRY_STREAK=0 \
       HUNT_FIXTURE="oracle*=confirmed" run_combined "$WORK/dry")
DISPATCH4="$(printf '%s\n' "$OUT4" | grep -E '^DISPATCH\|hunt\|' | head -1)"
note "fixture with no rule for the chosen subsystem -> dispatch: $DISPATCH4"
case "$DISPATCH4" in DISPATCH\|hunt\|vault\ accounting\|C1\|dry) ok "no matching fixture rule -> DISPATCH verdict = dry (the benign default)";; *) bad "expected the default 'dry' verdict, got '$DISPATCH4'";; esac

echo
echo "=================================================================================="
echo " (5) The STANDALONE dispatcher.ag produces the SAME marker + memo as the inlined path (sync-guard)"
echo "=================================================================================="

# coordinator.ag inlines dispatcher.ag's verdict fns (agentis `go` has no file includes). Run the standalone
# dispatcher.ag with the SAME chosen hunt + fixture as case (1) and assert byte-identical DISPATCH| + memo —
# this both EXERCISES dispatcher.ag (its only direct entry point) and CATCHES drift between the two copies.
init_store "$WORK/standalone"
SA_DISPATCH="$(run_standalone "$WORK/standalone" "vault accounting|C1" "vault*=confirmed;reentr*=refuted")"
SA_MEMO="$(read_outcome_memo "$WORK/standalone")"
note "standalone dispatcher.ag marker -> $SA_DISPATCH"
if [ -n "$DISPATCH_LINE" ] && [ "$SA_DISPATCH" = "$DISPATCH_LINE" ]; then
  ok "standalone dispatcher.ag DISPATCH| == the inlined coordinator path (the two copies are in sync)"
else
  bad "standalone dispatcher.ag marker '$SA_DISPATCH' != inlined '$DISPATCH_LINE' — the copies have DRIFTED"
fi
if [ -n "$MEMO" ] && [ "$SA_MEMO" = "$MEMO" ]; then
  ok "standalone dispatcher.ag memo == the inlined coordinator path memo"
else
  bad "standalone dispatcher.ag memo '$SA_MEMO' != inlined '$MEMO' — the copies have DRIFTED"
fi

echo
echo "=================================================================================="
if [ "$FAILS" -eq 0 ]; then
  note "ALL proven offline + deterministically. The hunt DECISION and its DISPATCH now happen in ONE"
  note "agentis go; the gate verdict crosses back via the durable coordinator:last_outcome memo; the"
  note "verdict is the fixture's (it flips when the fixture flips); a re-run is byte-identical; and the"
  note "standalone dispatcher.ag stays byte-identical to the inlined coordinator copy (sync-guard)."
  exit 0
fi
note "FAILED: $FAILS assertion(s) did not hold — see above."
exit 1
