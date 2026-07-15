#!/usr/bin/env bash
# demo-coordinator.sh — #1014: OFFLINE, DETERMINISTIC proof that the self-orchestrating coordinator
# (auditor/agents/coordinator.ag) satisfies BOTH acceptance criteria, with NO network and NO real LLM.
#
# The discovery colony used to take its workflow from a FIXED script (run-discovery.sh's (subsystem x
# class) fan-out) and an external operator (target/method/when-to-stop). #1014 moves the DECISION into the
# substrate: each step, coordinator.ag reads the FACTS + an evolving POLICY and chooses ONE next action.
# This demo proves the two things that makes it real:
#
#   (a) FACT-DRIVEN, NOT A FIXED ORDER. The coordinator is asked to decide under THREE distinct
#       fact-states and the chosen action DIFFERS by the facts:
#         * a pending unverified candidate present     -> it chooses to VERIFY it (refute)
#         * no candidate + a clearly highest-fitness lens -> it chooses to HUNT that lens (not some
#           fixed-first cell): with C8 the top lens it picks C8, and when C1 is the top lens it picks C1
#           (same option list, the CHOICE follows the fitness fact)
#         * budget exhausted                            -> it chooses STOP
#       If any of these did not diverge as the facts dictate, the demo FAILS.
#
#   (b) THE DECISION POLICY EVOLVES. Driving the loop where one action-type (hunt) repeatedly yields
#       CONFIRMED findings and another (refute) repeatedly comes back REFUTED, the demo reads
#       coordinator:policy:<type> (cumulative experience delta per action-type, the SAME mechanic
#       evolve-fitness.sh measures for lenses) BEFORE and AFTER, and asserts the rewarded type's weight
#       ROSE while the wasteful type's weight FELL. If the policy did not move, the demo exits non-zero.
#
# Everything is deterministic: the coordinator's choice is a fact+policy argmax (no RNG), and the
# dispatch outcomes come from a fixture, not an LLM. A re-run reproduces byte-for-byte. The backend is
# `mock` — no prompt(), no API, zero cost. (coordinator.ag does call the substrate `decide` builtin to
# SELECT from its fact-ranked option list; offline `decide` resolves to the top-ranked option, so the
# selection stays deterministic and is the coordinator's fact+policy ranking.)
#
# Usage:  dark-factory/demo-coordinator.sh
# Requires: the `agentis` binary on PATH. Exit 0 = both criteria proven; non-zero = a criterion failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
command -v agentis >/dev/null 2>&1 || { echo "demo-coordinator.sh: agentis binary not on PATH" >&2; exit 3; }
COORD_AG="$HERE/auditor/agents/coordinator.ag"
[ -f "$COORD_AG" ] || { echo "demo-coordinator.sh: coordinator agent not found at $COORD_AG" >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
note() { echo "demo-coordinator.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

# A fresh single-step agentis store with experience enabled (so the coordinator can learn()/decide()).
# $1 = store dir. Configured EXACTLY like run-coordinator.sh.
init_store() {
  _d="$1"; mkdir -p "$_d"; cp "$COORD_AG" "$_d/coordinator.ag"
  ( cd "$_d" && agentis init >/dev/null 2>&1 )
  {
    echo "llm.backend = mock"
    echo "trace.level = normal"
    echo "exec.env_passthrough = SCOPE,CLASS_FITNESS,POLICY,PENDING,BUDGET,DRY_STREAK,DRY_CAP,PREV_ACTION,PREV_KEY,LAST_OUTCOME"
    echo "exec.default_timeout_ms = 30000"
    echo "learning.enabled = true"
    echo "experience.enabled = true"
  } > "$_d/.agentis/config"
}

# Run ONE coordinator decision in store $1 with the fact-env in $2.. (KEY=VALUE pairs). Prints the
# The chosen action as `<type>|<args>|` — the ACTION line with the leading `ACTION|` token stripped and
# the trailing rationale dropped. The line is `ACTION|<type>|<args>|<rationale>` where <args> for a hunt
# is `subsystem|class` (2 segments) and the rationale CAN itself contain a `|` (it quotes the cell name),
# so we cannot field-split on the rationale. Instead the coordinator emits the action prefix in a fixed
# shape: type is field 2, args is field 3 for a single-segment action (refute/poc-screen/stop) and fields
# 3-4 for a hunt (subsystem|class). We return `type|args|` and the caller glob-matches that PREFIX, which
# is unambiguous regardless of the rationale tail. All other env defaults to a benign value.
decide_line() {
  _store="$1"; shift
  # --grant-pii: scope/pending text can carry addresses/identifiers that trip the PII heuristic;
  # benign fixture, kept uniform with the other flagged demos + recurrence defense (#1690).
  ( cd "$_store" && env \
      SCOPE="${SCOPE:-}" CLASS_FITNESS="${CLASS_FITNESS:-}" POLICY="${POLICY:-}" \
      PENDING="${PENDING:-}" BUDGET="${BUDGET:-10}" DRY_STREAK="${DRY_STREAK:-0}" DRY_CAP="${DRY_CAP:-3}" \
      PREV_ACTION="${PREV_ACTION:-}" PREV_KEY="${PREV_KEY:-}" LAST_OUTCOME="${LAST_OUTCOME:-}" \
      "$@" agentis go coordinator.ag --enable-exec --enable-messaging --grant-pii 2>/dev/null ) \
    | grep -E '^ACTION\|' | head -1
}

# Cumulative policy weight for one action-type from a store's experience jsonl (mirrors
# evolve-fitness.sh::read_fitness and run-coordinator.sh::read_policy). Prints a float (0 if absent).
policy_weight() {
  _exp="$1/.agentis/experience/main.jsonl"; _type="$2"
  python3 - "$_exp" "$_type" <<'PY'
import json, os, sys
path, want = sys.argv[1], sys.argv[2]
tot = 0.0
if os.path.exists(path):
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("action") == "coordinator" and r.get("in") == want:
                tot += float(r.get("delta", 0.0))
print("%.4f" % tot)
PY
}

# float comparison helper: `cmp_gt A B` -> exit 0 iff A > B.
cmp_gt() { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a > b) }'; }

# A scope where C8 has the higher fitness in one state and C1 in the other (to prove the HUNT choice
# follows the fitness FACT, not a fixed cell order).
SCOPE_FX=$'vault accounting|C1\nreentrancy|C8\ncross-chain|C3'

echo "=================================================================================="
echo " (a) FACT-DRIVEN, NOT A FIXED ORDER — distinct facts must yield distinct actions"
echo "=================================================================================="

# The action TYPE of a full `ACTION|<type>|...` line (field 2).
atype() { printf '%s' "$1" | cut -d'|' -f2; }

# --- State A: a pending unverified candidate -> VERIFY (refute), not hunt. -------------------------
init_store "$WORK/a"
A=$(SCOPE="$SCOPE_FX" CLASS_FITNESS="C1=0.45;C8=0.30;C3=-0.20" PENDING="cand-7|vault accounting|C1" \
    BUDGET=10 DRY_STREAK=0 decide_line "$WORK/a")
note "State A (pending candidate present)            -> $A"
case "$A" in ACTION\|refute\|cand-7\|*) ok "pending candidate -> chose to VERIFY it (refute cand-7)";; *) bad "expected 'ACTION|refute|cand-7|...', got '$A'";; esac

# --- State B: no candidate, C8 is the top lens -> HUNT reentrancy|C8. ------------------------------
init_store "$WORK/b"
B=$(SCOPE="$SCOPE_FX" CLASS_FITNESS="C1=0.10;C8=0.55;C3=-0.20" PENDING="" \
    BUDGET=10 DRY_STREAK=0 decide_line "$WORK/b")
note "State B (no candidate; top lens = C8)          -> $B"
case "$B" in ACTION\|hunt\|reentrancy\|C8\|*) ok "no candidate + top lens C8 -> chose to HUNT reentrancy|C8";; *) bad "expected 'ACTION|hunt|reentrancy|C8|...', got '$B'";; esac

# --- State B': SAME options, now C1 is the top lens -> HUNT vault accounting|C1 (choice follows the
#     fitness FACT, proving it is not a fixed cell order). ------------------------------------------
init_store "$WORK/bp"
BP=$(SCOPE="$SCOPE_FX" CLASS_FITNESS="C1=0.55;C8=0.10;C3=-0.20" PENDING="" \
     BUDGET=10 DRY_STREAK=0 decide_line "$WORK/bp")
note "State B' (no candidate; top lens = C1)         -> $BP"
case "$BP" in ACTION\|hunt\|vault\ accounting\|C1\|*) ok "same options, top lens C1 -> chose to HUNT vault accounting|C1 (not a fixed cell)";; *) bad "expected 'ACTION|hunt|vault accounting|C1|...', got '$BP'";; esac

# --- State C: budget exhausted -> STOP. ------------------------------------------------------------
init_store "$WORK/c"
C=$(SCOPE="$SCOPE_FX" CLASS_FITNESS="C1=0.45;C8=0.30;C3=-0.20" PENDING="" \
    BUDGET=0 DRY_STREAK=0 decide_line "$WORK/c")
note "State C (budget exhausted)                     -> $C"
case "$C" in ACTION\|stop\|*) ok "budget exhausted -> chose STOP";; *) bad "expected 'ACTION|stop|...', got '$C'";; esac

# --- The CORE assertion of (a): the three fact-states produced THREE DIFFERENT action types. -------
TA="$(atype "$A")"; TB="$(atype "$B")"; TC="$(atype "$C")"
if [ "$TA" != "$TB" ] && [ "$TB" != "$TC" ] && [ "$TA" != "$TC" ]; then
  ok "the three fact-states chose THREE DIFFERENT actions ($TA / $TB / $TC) — not a fixed order"
else
  bad "fact-states did not diverge: A=$TA B=$TB C=$TC"
fi

echo
echo "=================================================================================="
echo " (b) THE DECISION POLICY EVOLVES — rewarded action-type rises, wasteful one falls"
echo "=================================================================================="

# One shared store: drive a sequence where every HUNT confirms (a real finding -> success) and every
# REFUTE comes back refuted (wasted a step -> failure). We feed the PREVIOUS action's outcome on each
# call (exactly what run-coordinator.sh does), so coordinator.ag's learn() reweights the policy. The
# coordinator's CHOICE on each call is incidental here — what we measure is the policy DELTA per type.
init_store "$WORK/evolve"
EV="$WORK/evolve"

# Record one decision-outcome attribution: PREV_ACTION=$1 with LAST_OUTCOME=$2 (+ a forced-stop BUDGET so
# the call only does the attribution + a trivial decision; we ignore the chosen action here).
attribute() {
  SCOPE="$SCOPE_FX" CLASS_FITNESS="C1=0.30" PENDING="" BUDGET=10 DRY_STREAK=0 \
    PREV_ACTION="$1" PREV_KEY="$3" LAST_OUTCOME="$2" decide_line "$EV" >/dev/null
}

HUNT_BEFORE=$(policy_weight "$EV" hunt)
REFUTE_BEFORE=$(policy_weight "$EV" refute)
note "policy BEFORE: hunt=$HUNT_BEFORE  refute=$REFUTE_BEFORE"

# 4 confirmed hunts, 4 refuted refutes (interleaved, deterministic).
N=4
i=1
while [ "$i" -le "$N" ]; do
  attribute hunt   confirmed "vault accounting|C1"
  attribute refute refuted   "cand-$i"
  i=$((i + 1))
done

HUNT_AFTER=$(policy_weight "$EV" hunt)
REFUTE_AFTER=$(policy_weight "$EV" refute)
note "policy AFTER : hunt=$HUNT_AFTER  refute=$REFUTE_AFTER  (after $N confirmed hunts + $N refuted refutes)"

if cmp_gt "$HUNT_AFTER" "$HUNT_BEFORE"; then
  ok "hunt policy ROSE ($HUNT_BEFORE -> $HUNT_AFTER) — the action-type that confirmed findings gained weight"
else
  bad "hunt policy did NOT rise ($HUNT_BEFORE -> $HUNT_AFTER)"
fi
if cmp_gt "$REFUTE_BEFORE" "$REFUTE_AFTER"; then
  ok "refute policy FELL ($REFUTE_BEFORE -> $REFUTE_AFTER) — the wasteful action-type lost weight"
else
  bad "refute policy did NOT fall ($REFUTE_BEFORE -> $REFUTE_AFTER)"
fi
# And the evolved ranking must now prefer hunt over refute by policy.
if cmp_gt "$HUNT_AFTER" "$REFUTE_AFTER"; then
  ok "evolved policy now ranks hunt ABOVE refute ($HUNT_AFTER > $REFUTE_AFTER)"
else
  bad "evolved policy does not rank hunt above refute ($HUNT_AFTER vs $REFUTE_AFTER)"
fi

echo
echo "=================================================================================="
if [ "$FAILS" -eq 0 ]; then
  note "BOTH acceptance criteria PROVEN offline + deterministically. The coordinator decides from"
  note "FACTS (divergent actions by fact-state) and its decision policy EVOLVES by outcome."
  exit 0
fi
note "FAILED: $FAILS assertion(s) did not hold — see above."
exit 1
