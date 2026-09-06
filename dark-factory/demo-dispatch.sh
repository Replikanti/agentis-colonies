#!/usr/bin/env bash
# demo-dispatch.sh — #1014 M2: OFFLINE, DETERMINISTIC proof that EVERY action's DISPATCH now lives in the
# substrate, with NO network and NO real LLM.
#
# run-coordinator.sh used to route the coordinator's chosen action through a shell `case` (stub_outcome /
# real_outcome) to derive the gate verdict, then fed it back. M1 moved the `hunt` slice onto the substrate;
# M2 GENERALISES it to every action type. In ONE `agentis go coordinator.ag`, the coordinator DECIDES the
# action (prints `ACTION|<type>|...`), emits it over the IN-PROCESS bus (`dark-factory:dispatch`,
# payload `<type>|<args>`), and a sibling agent fn (dispatch, mirroring auditor/agents/dispatcher.ag)
# `listen`s it, derives the verdict from the DISPATCH_FIXTURE fact, writes it to the DURABLE
# `coordinator:last_outcome` memo, and prints `DISPATCH|<type>|...`. The shell loop then READS the verdict
# from that memo (the only substrate-native cross-process channel) instead of a shell `case`.
#
# This demo proves, for EACH real action type (hunt / refute / poc-screen / invent-method):
#   (1) ONE `agentis go` prints BOTH the decision (`ACTION|<type>|...`) and the dispatch (`DISPATCH|<type>|...`)
#       — same process, NO shell `case` between them.
#   (2) A SEPARATE `agentis memo get coordinator:last_outcome` reads back `<type>|<args>|<verdict>` (the
#       verdict crossed the process boundary via the durable memo, as it does to the shell loop).
#   (3) The STANDALONE dispatcher.ag (its DISPATCH_ARGS entry) produces the byte-identical `DISPATCH|`
#       marker + memo as the inlined coordinator path — a SYNC-GUARD so the two copies of the verdict fns
#       can't silently drift (agentis `go` has no file includes, so coordinator.ag inlines the same fns).
#       The guard asserts byte-identity on the FIXTURE path. dispatcher.ag also mirrors the live
#       symbolic-prove route (#1032); the newer live routes (invariant-hunt / auto-harness execution)
#       live ONLY in coordinator.ag and are intentionally not mirrored here — coordinator.ag, not this
#       standalone copy, is the production entry point (see dispatcher.ag's ROLE/SCOPE header, #1049).
# Plus, for hunt: a re-run is byte-identical (deterministic, no RNG), and the verdict follows the fixture
# (flip the fixture, the verdict flips; a no-match subsystem defaults to dry).
#
# Everything is deterministic and offline: the coordinator's choice is a fact+policy argmax (no RNG), the
# dispatch verdict comes from DISPATCH_FIXTURE (no LLM, no prompt()), and the backend is `mock` (zero cost).
#
# Usage:  dark-factory/demo-dispatch.sh
# Requires: the `agentis` binary on PATH. Exit 0 = all proven; non-zero = an assertion failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# #2119: wide flat-cyborg PTY by default for every flat-cyborg config emission (see the helper header).
# shellcheck source=lib/flat-cyborg-env.sh
# shellcheck disable=SC1091
. "$HERE/lib/flat-cyborg-env.sh"
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
    echo "exec.env_passthrough = SCOPE,CLASS_FITNESS,POLICY,PENDING,BUDGET,DRY_STREAK,DRY_CAP,PREV_ACTION,PREV_KEY,LAST_OUTCOME,DISPATCH_ENABLED,DISPATCH_FIXTURE,HUNT_FIXTURE,DISPATCH_ARGS"
    echo "exec.default_timeout_ms = 30000"
    echo "learning.enabled = true"
    echo "experience.enabled = true"
  } > "$_d/.agentis/config"
}

# Run ONE combined decision+dispatch in store $1 with the env in $2.. (KEY=VALUE pairs). Prints the run's
# stdout filtered to the ACTION| / DISPATCH| markers (the two lines the demo asserts on), in order. The
# coordinator decides an action and dispatches it in the SAME process because DISPATCH_ENABLED is set.
run_combined() {
  _store="$1"; shift
  # --grant-pii: scope/pending text can carry addresses/identifiers that trip the PII heuristic;
  # benign fixture, kept uniform with the other flagged demos + recurrence defense (#1690).
  ( cd "$_store" && env \
      SCOPE="${SCOPE:-}" CLASS_FITNESS="${CLASS_FITNESS:-}" POLICY="${POLICY:-}" \
      PENDING="${PENDING:-}" BUDGET="${BUDGET:-10}" DRY_STREAK="${DRY_STREAK:-0}" DRY_CAP="${DRY_CAP:-3}" \
      PREV_ACTION="${PREV_ACTION:-}" PREV_KEY="${PREV_KEY:-}" LAST_OUTCOME="${LAST_OUTCOME:-}" \
      DISPATCH_ENABLED=1 DISPATCH_FIXTURE="${DISPATCH_FIXTURE:-}" \
      "$@" agentis go coordinator.ag --enable-exec --enable-messaging --grant-pii 2>/dev/null ) \
    | grep -E '^(ACTION|DISPATCH)\|'
}

# A SEPARATE process reads the durable verdict memo (the cross-process channel the shell loop uses).
read_outcome_memo() { ( cd "$1" && agentis memo get coordinator:last_outcome ) 2>/dev/null | tail -1; }

# Run the STANDALONE dispatcher.ag (its DISPATCH_ARGS entry) in store $1 for the chosen `<type>|<args>` $2
# with the DISPATCH_FIXTURE in $3. This exercises auditor/agents/dispatcher.ag directly — the same fns
# coordinator.ag inlines — so the demo doubles as a SYNC-GUARD: the standalone agent must produce the
# byte-identical DISPATCH| marker + memo as the inlined coordinator path, or the two copies have drifted.
run_standalone() {
  # --grant-pii: dispatch args can carry addresses/identifiers that trip the PII heuristic; benign
  # fixture, kept uniform with the other flagged demos + recurrence defense (#1690).
  ( cd "$1" && env DISPATCH_ARGS="$2" DISPATCH_FIXTURE="$3" \
      agentis go dispatcher.ag --enable-exec --enable-messaging --grant-pii 2>/dev/null ) \
    | grep -E '^DISPATCH\|'
}

# Prove one action type end-to-end: the coordinator (driven by the per-state env exported by the caller)
# DECIDES $1=<type> with $2=<args>, dispatches it in-substrate to $3=<verdict>, the verdict crosses back via
# the durable memo, and the STANDALONE dispatcher.ag reproduces the byte-identical marker + memo (sync-guard).
# $4 = DISPATCH_FIXTURE, $5 = a label, $6 = store subdir. The decision-env vars (SCOPE/PENDING/POLICY/...)
# are read from the caller's exported environment so each type can set the fact-state that elicits it.
prove_action() {
  _type="$1"; _args="$2"; _verdict="$3"; _fixture="$4"; _label="$5"; _sub="$6"
  _store="$WORK/$_sub"
  init_store "$_store"
  _out="$(DISPATCH_FIXTURE="$_fixture" run_combined "$_store")"
  note "$_label — single-go markers:"
  printf '%s\n' "$_out" | sed 's/^/    /'
  _action="$(printf '%s\n' "$_out" | grep -E "^ACTION\\|$_type\\|" | head -1)"
  _dispatch="$(printf '%s\n' "$_out" | grep -E "^DISPATCH\\|$_type\\|" | head -1)"
  _want_dispatch="DISPATCH|$_type|$_args|$_verdict"
  _want_memo="$_type|$_args|$_verdict"
  # (1) one go printed both the decision and the dispatch
  if [ -n "$_action" ]; then ok "ACTION| decision present: chose $_type ${_args:-<no args>}"
  else bad "expected an 'ACTION|$_type|...' line, got '$_action'"; fi
  if [ "$_dispatch" = "$_want_dispatch" ]; then ok "DISPATCH| outcome present in the SAME process: $_verdict"
  else bad "expected '$_want_dispatch', got '$_dispatch'"; fi
  if [ -n "$_action" ] && [ -n "$_dispatch" ]; then ok "decision AND dispatch came from one agentis go — no shell case between them"
  else bad "the single go did not emit both the ACTION| and the DISPATCH| line"; fi
  # (2) a separate process reads the durable verdict
  _memo="$(read_outcome_memo "$_store")"
  if [ "$_memo" = "$_want_memo" ]; then ok "separate-process memo read = '$_want_memo'"
  else bad "expected '$_want_memo' in the memo, got '$_memo'"; fi
  # (3) the standalone dispatcher.ag is byte-identical (sync-guard)
  _sa_store="$WORK/${_sub}-sa"
  init_store "$_sa_store"
  _sa_dispatch="$(run_standalone "$_sa_store" "$_type|$_args" "$_fixture")"
  _sa_memo="$(read_outcome_memo "$_sa_store")"
  if [ -n "$_dispatch" ] && [ "$_sa_dispatch" = "$_dispatch" ]; then ok "standalone dispatcher.ag DISPATCH| == the inlined coordinator path (in sync)"
  else bad "standalone DISPATCH| '$_sa_dispatch' != inlined '$_dispatch' — the copies have DRIFTED"; fi
  if [ -n "$_memo" ] && [ "$_sa_memo" = "$_memo" ]; then ok "standalone dispatcher.ag memo == the inlined coordinator path memo"
  else bad "standalone memo '$_sa_memo' != inlined '$_memo' — the copies have DRIFTED"; fi
}

# A scope where vault accounting|C1 is the clearly highest-fitness lens, so the coordinator chooses to HUNT
# it when no candidate is pending. The fixture maps each subsystem/candidate to a definite verdict.
SCOPE_FX=$'vault accounting|C1\nreentrancy|C8\ncross-chain|C3'
FIT_FX="C1=0.55;C8=0.10;C3=-0.20"

echo "=================================================================================="
echo " (A) HUNT — one go prints ACTION|hunt|... + DISPATCH|hunt|...; verdict via memo; sync-guard"
echo "=================================================================================="
# No pending candidate + a clearly top lens -> the coordinator chooses to HUNT vault accounting|C1.
export SCOPE="$SCOPE_FX" CLASS_FITNESS="$FIT_FX" POLICY="" PENDING="" BUDGET=10 DRY_STREAK=0
prove_action hunt "vault accounting|C1" confirmed \
  "hunt|vault*=confirmed;reentr*=refuted" "HUNT/confirmed" "hunt"

echo
echo "=================================================================================="
echo " (B) REFUTE — a pending candidate -> verify via refute; verdict via memo; sync-guard"
echo "=================================================================================="
# A pending unverified candidate present -> the coordinator chooses to VERIFY it (refute outranks a hunt).
export SCOPE="$SCOPE_FX" CLASS_FITNESS="$FIT_FX" POLICY="" PENDING="cand-9|vault accounting|C1" BUDGET=10 DRY_STREAK=0
prove_action refute "cand-9" refuted \
  "refute|cand-9=refuted;hunt|vault*=confirmed" "REFUTE/refuted" "refute"

echo
echo "=================================================================================="
echo " (C) POC-SCREEN — a pending candidate + poc policy lifted -> screen it; verdict via memo; sync-guard"
echo "=================================================================================="
# A pending candidate AND a learned poc-screen policy weight that lifts poc-screen above refute -> the
# coordinator chooses the cheap eval_ag pre-screen first.
export SCOPE="$SCOPE_FX" CLASS_FITNESS="$FIT_FX" POLICY="poc-screen=2.0" PENDING="cand-9|vault accounting|C1" BUDGET=10 DRY_STREAK=0
prove_action poc-screen "cand-9" confirmed \
  "poc-screen|cand-9=confirmed;refute|cand-9=refuted" "POC-SCREEN/confirmed" "poc"

echo
echo "=================================================================================="
echo " (D) INVENT-METHOD — no huntable cell + no candidate -> invent a method; verdict via memo; sync-guard"
echo "=================================================================================="
# Empty scope (nothing huntable) and no pending candidate -> the coordinator chooses the META move.
export SCOPE="" CLASS_FITNESS="" POLICY="" PENDING="" BUDGET=10 DRY_STREAK=0
prove_action invent-method "" confirmed \
  "invent-method|*=confirmed" "INVENT-METHOD/confirmed" "invent"

echo
echo "=================================================================================="
echo " (E) DETERMINISM + the verdict follows the fixture (HUNT, re-run + fixture flip)"
echo "=================================================================================="
# Re-run case (A) into a fresh store and assert byte-identical ACTION|/DISPATCH| markers (no RNG).
export SCOPE="$SCOPE_FX" CLASS_FITNESS="$FIT_FX" POLICY="" PENDING="" BUDGET=10 DRY_STREAK=0
init_store "$WORK/det1"
OUT_D1=$(DISPATCH_FIXTURE="hunt|vault*=confirmed;reentr*=refuted" run_combined "$WORK/det1")
init_store "$WORK/det2"
OUT_D2=$(DISPATCH_FIXTURE="hunt|vault*=confirmed;reentr*=refuted" run_combined "$WORK/det2")
if [ "$OUT_D1" = "$OUT_D2" ]; then
  ok "two independent HUNT runs produced byte-identical ACTION|/DISPATCH| markers (deterministic)"
else
  bad "the two runs DIFFERED:"; diff <(printf '%s\n' "$OUT_D1") <(printf '%s\n' "$OUT_D2") | sed 's/^/      /' >&2 || true
fi

# SAME decision facts, a DIFFERENT fixture rule for the chosen subsystem -> the verdict must follow the
# fixture (confirmed above, refuted now), proving the verdict is the fixture's, not fixed.
init_store "$WORK/flip"
OUT_FLIP=$(DISPATCH_FIXTURE="hunt|vault*=refuted;reentr*=confirmed" run_combined "$WORK/flip")
DISPATCH_FLIP="$(printf '%s\n' "$OUT_FLIP" | grep -E '^DISPATCH\|hunt\|' | head -1)"
note "fixture hunt|vault*=refuted -> dispatch: $DISPATCH_FLIP"
case "$DISPATCH_FLIP" in DISPATCH\|hunt\|vault\ accounting\|C1\|refuted) ok "same decision, fixture flipped -> DISPATCH verdict = refuted (follows the fixture)";; *) bad "expected 'DISPATCH|hunt|vault accounting|C1|refuted', got '$DISPATCH_FLIP'";; esac

# And a no-match subsystem must default to dry (the old stub_outcome END rule), deterministically.
init_store "$WORK/dry"
OUT_DRY=$(DISPATCH_FIXTURE="hunt|oracle*=confirmed" run_combined "$WORK/dry")
DISPATCH_DRY="$(printf '%s\n' "$OUT_DRY" | grep -E '^DISPATCH\|hunt\|' | head -1)"
note "fixture with no rule for the chosen subsystem -> dispatch: $DISPATCH_DRY"
case "$DISPATCH_DRY" in DISPATCH\|hunt\|vault\ accounting\|C1\|dry) ok "no matching fixture rule -> DISPATCH verdict = dry (the benign default)";; *) bad "expected the default 'dry' verdict, got '$DISPATCH_DRY'";; esac

echo
echo "=================================================================================="
if [ "$FAILS" -eq 0 ]; then
  note "ALL proven offline + deterministically. For EVERY action type (hunt / refute / poc-screen /"
  note "invent-method) the DECISION and its DISPATCH happen in ONE agentis go; the gate verdict crosses"
  note "back via the durable coordinator:last_outcome memo; the standalone dispatcher.ag stays"
  note "byte-identical to the inlined coordinator copy (sync-guard); a re-run is byte-identical; and the"
  note "verdict is the fixture's (it flips when the fixture flips, defaults to dry when no rule matches)."
  exit 0
fi
note "FAILED: $FAILS assertion(s) did not hold — see above."
exit 1
