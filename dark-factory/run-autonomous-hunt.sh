#!/usr/bin/env bash
# run-autonomous-hunt.sh — Integration M1 (#1037): the self-orchestrating coordinator AUTONOMOUSLY chooses
# and LIVE-runs the stateful-invariant fuzzer on a target, end-to-end.
#
# WHAT IT IS. This is the integration entrypoint that closes the loop between the #1014 self-orchestrating
# coordinator and the #1035 stateful-invariant fuzzer (`evm-harness/forge-invariant.sh`). It drives ONE
# `agentis go coordinator.ag` in ORCHESTRATE mode: the coordinator reads the FACTS (a pending candidate
# representing the target, the evolving policy) and DECIDES — by a policy-weighted argmax, never a fixed
# sequence — to route the candidate through the `invariant-hunt` VERIFY action. That action runs the REAL
# forge invariant fuzzer over the target test via `forge-invariant.sh` and maps its exit code to the gate
# outcome: 1=FINDING -> confirmed, 0=CLEAN -> refuted, 2/else=HARNESS_ERROR -> dry. The CHOICE of engine is
# the coordinator's evolving policy; the FINDING/CLEAN VERDICT is the FUZZER's shrunk witness — NEVER the LLM.
#
# This mirrors how `symbolic-prove` was given a live route (#1032 / demo-symbolic-orchestrate-live.sh): the
# coordinator CHOOSES the engine, the gate's exit code is the sound verdict, and the outcome evolves the
# policy. Submission stays human-gated; this colony never posts to a bounty platform.
#
# Usage:
#   run-autonomous-hunt.sh --repo <foundry-root> --target <Invariant.t.sol>
#                          [--match <prefix>] [--backend mock|flat-cyborg|claude]
#                          [--runs N] [--depth D] [--seed S] [--steps N] [--out <dir>]
#                          [--agentis <bin>]
#
#   --repo <dir>      Foundry project root (must hold foundry.toml) the fuzzer runs in. REQUIRED.
#   --target <file>   The invariant `*.t.sol` the fuzzer scopes to (absolute or relative to --repo). REQUIRED.
#   --match <prefix>  Invariant function-name prefix forge runs (default "invariant").
#   --backend <b>     LLM backend for the agentis store (default mock — the DECISION is offline-deterministic;
#                     the verdict is the fuzzer's, so no LLM is needed for the integration loop).
#   --runs N          Optional forge invariant runs budget (search width); forwarded to the gate.
#   --depth D         Optional forge invariant depth budget (calls per sequence); forwarded to the gate.
#   --seed S          Optional forge --fuzz-seed for a reproducible search; forwarded to the gate.
#   --steps N         Loop step bound (default 2): one decision routes the candidate to invariant-hunt; the
#                     next attributes its outcome to the policy (proving outcome -> policy evolution).
#   --out <dir>       Output dir for the run (default: ./autonomous-hunt-out). A fresh agentis store is built
#                     under <out>/run.
#   --agentis <bin>   agentis binary (default: `agentis` on PATH).
#
# Exit: 0 on a clean run that reached ORCHESTRATE|done; 2 on usage error; 3 on a missing prerequisite; 1 on a
# run failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
REPO=""
TARGET=""
MATCH="invariant"
BACKEND="mock"
RUNS=""
DEPTH=""
SEED=""
STEPS_N=2
OUT="$PWD/autonomous-hunt-out"

need() { [ "$1" -ge 2 ] || { echo "run-autonomous-hunt.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    need "$#"; REPO="$2"; shift 2 ;;
    --target)  need "$#"; TARGET="$2"; shift 2 ;;
    --match)   need "$#"; MATCH="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --runs)    need "$#"; RUNS="$2"; shift 2 ;;
    --depth)   need "$#"; DEPTH="$2"; shift 2 ;;
    --seed)    need "$#"; SEED="$2"; shift 2 ;;
    --steps)   need "$#"; STEPS_N="$2"; shift 2 ;;
    --out)     need "$#"; OUT="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-autonomous-hunt.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "run-autonomous-hunt.sh: --repo <foundry project root> required" >&2; exit 2; }
[ -f "$REPO/foundry.toml" ] || { echo "run-autonomous-hunt.sh: --repo is not a foundry project (no foundry.toml): $REPO" >&2; exit 2; }
[ -n "$TARGET" ] || { echo "run-autonomous-hunt.sh: --target <Invariant.t.sol> required" >&2; exit 2; }
[ -n "$MATCH" ] || { echo "run-autonomous-hunt.sh: --match prefix must be non-empty" >&2; exit 2; }
case "$STEPS_N" in (*[!0-9]*|'') echo "run-autonomous-hunt.sh: --steps must be a non-negative integer" >&2; exit 2 ;; esac
[ "$STEPS_N" -ge 1 ] || { echo "run-autonomous-hunt.sh: --steps must be >= 1 (one decision routes the candidate, the next attributes its outcome)" >&2; exit 2; }
for v in "$RUNS" "$DEPTH" "$SEED"; do
  case "$v" in '') ;; *[!0-9]*) echo "run-autonomous-hunt.sh: --runs/--depth/--seed must be whole numbers" >&2; exit 2 ;; esac
done

# Resolve the target to an ABSOLUTE path (the colony runs from the rundir, a different cwd; the exec sandbox
# cannot read a relative/home-rooted path). Accept either an absolute/relative file OR a path under --repo.
if [ -f "$TARGET" ]; then
  TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
elif [ -f "$REPO/$TARGET" ]; then
  TARGET="$(cd "$REPO" && pwd)/$TARGET"
else
  echo "run-autonomous-hunt.sh: --target test not found: $TARGET" >&2; exit 2
fi
REPO="$(cd "$REPO" && pwd)"

command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-autonomous-hunt.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

COORD_AG="$HERE/auditor/agents/coordinator.ag"
# Resolve the stateful-fuzzing gate to an ABSOLUTE path (relative to this script's own location) and pass it
# as FORGE_INVARIANT — the same env path invariant-prover.ag / run-invariant-hunt.sh use. No install location
# is hardcoded; forge is the caller's PATH responsibility, exactly as forge-invariant.sh requires.
FORGE_INVARIANT="$HERE/evm-harness/forge-invariant.sh"
[ -f "$COORD_AG" ]        || { echo "run-autonomous-hunt.sh: coordinator agent not found at $COORD_AG" >&2; exit 3; }
[ -f "$FORGE_INVARIANT" ] || { echo "run-autonomous-hunt.sh: forge-invariant gate not found at $FORGE_INVARIANT" >&2; exit 3; }

mkdir -p "$OUT" || { echo "run-autonomous-hunt.sh: cannot create --out dir: $OUT" >&2; exit 1; }
OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN" || { echo "run-autonomous-hunt.sh: cannot create run dir: $RUN" >&2; exit 1; }
cp "$COORD_AG" "$RUN/coordinator.ag"

# A single shared agentis store for the whole orchestrate run (the policy the coordinator writes one step
# must be visible to the next). init FIRST (before any .agentis/ subdir), else HEAD is unset.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p"; echo "llm.cli_timeout_ms = 600000"; }
  [ "$BACKEND" = "flat-cyborg" ] && echo "llm.cli_timeout_ms = 600000"
  echo "trace.level = normal"
  echo "exec.env_passthrough = SCOPE,CLASS_FITNESS,POLICY,PENDING,BUDGET,DRY_STREAK,DRY_CAP,PREV_ACTION,PREV_KEY,LAST_OUTCOME,DISPATCH_ENABLED,DISPATCH_FIXTURE,HUNT_FIXTURE,ORCHESTRATE_ENABLED,STEPS,SYM_POLICY_TT,INV_POLICY_TT,SYM_REPO,SYM_SPEC,SYM_FUNCTION,HALMOS_VERIFY,FORGE_INVARIANT,INV_REPO,INV_TARGET,INV_MATCH,INV_RUNS,INV_DEPTH,INV_SEED"
  # A forge invariant run (build + a few hundred fuzzed sequences) far exceeds the 10s/30s defaults — match
  # run-invariant-hunt.sh's 600s budget so the live fuzzer has room to run inside the loop.
  echo "exec.default_timeout_ms = 600000"
  # The whole point: every decision is recorded as experience so coordinator:policy:<type> reweights.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

# SEED the in-substrate loop's INITIAL invariant-hunt policy weight high enough that score_invariant
# (94 + 4x lead) beats score_refute (100): lead >= ~1.6 lifts invariant-hunt above refute. We use 2.0
# (= INV_POLICY_TT 20000 ten-thousandths) so the coordinator AUTONOMOUSLY chooses invariant-hunt from step 0.
# This stands in for the policy a PRIOR run would have evolved — the fuzzer's witnesses paying off and the
# colony having learned to lean on the stateful engine for this candidate. (agentis offers no float->int
# builtin, so the integer is supplied directly, exactly like run-coordinator.sh's SYM_POLICY_TT.)
INV_POLICY_TT=20000

# A single pending candidate represents the target — the same shape the orchestrate loop expects (seeded into
# PENDING so a VERIFY action, here invariant-hunt, is the chosen action immediately). The SCOPE/CLASS_FITNESS
# carry one cell so the post-verify fallback (after the candidate is consumed) has a lens to fall back to.
SCOPE="vault accounting|C1"
CLASS_FITNESS="C1=0.5500"
PENDING="cand-0|vault accounting|C1"

# STEPS is a BOUND, not a sequence authority (agentis has no range(); a reduce over this list bounds the loop
# at <steps> iterations). BUDGET matches so the loop runs exactly <steps> decisions worst-case.
STEPS=""
if [ "$STEPS_N" -gt 0 ]; then
  STEPS="$(awk -v n="$STEPS_N" 'BEGIN{ for (i=0;i<n;i++){ printf "%s%d", (i?"\n":""), i } }')"
fi

RUN_LOG="$RUN/orchestrate.log"
# ONE in-substrate run drives the autonomous hunt. ORCHESTRATE_ENABLED selects the loop; DISPATCH_ENABLED keeps
# each action's dispatch in-substrate; DISPATCH_FIXTURE is EMPTY so invariant-hunt takes its LIVE route (the
# REAL forge-invariant gate over INV_REPO/INV_TARGET). INV_POLICY_TT seeds the policy so the engine is chosen.
( cd "$RUN" && env \
    SCOPE="$SCOPE" \
    CLASS_FITNESS="$CLASS_FITNESS" \
    PENDING="$PENDING" \
    BUDGET="$STEPS_N" \
    DRY_CAP=3 \
    STEPS="$STEPS" \
    INV_POLICY_TT="$INV_POLICY_TT" \
    ORCHESTRATE_ENABLED=1 \
    DISPATCH_ENABLED=1 \
    DISPATCH_FIXTURE="" \
    FORGE_INVARIANT="$FORGE_INVARIANT" \
    INV_REPO="$REPO" \
    INV_TARGET="$TARGET" \
    INV_MATCH="$MATCH" \
    INV_RUNS="$RUNS" \
    INV_DEPTH="$DEPTH" \
    INV_SEED="$SEED" \
    "$AGENTIS" go coordinator.ag --enable-exec --enable-messaging ) >"$RUN_LOG" 2>&1 \
  || { echo "run-autonomous-hunt.sh: in-substrate autonomous hunt failed (see $RUN_LOG)" >&2; exit 1; }

grep -E '^ORCHESTRATE\|' "$RUN_LOG" >/dev/null 2>&1 \
  || { echo "run-autonomous-hunt.sh: orchestration did not complete (no ORCHESTRATE| marker; see $RUN_LOG)" >&2; exit 1; }

# Surface the AUTONOMOUS DECISION TRAIL: the coordinator's ACTION| lines (what it chose + why) and the
# DISPATCH| lines (the fuzzer's verdict for each). The full run log (incl. the LIVE-route message + any
# shrunk witness) is at $RUN_LOG.
echo "run-autonomous-hunt.sh: autonomous decision trail:" >&2
grep -E '^(ACTION|DISPATCH)\|' "$RUN_LOG" | while IFS= read -r line; do
  echo "run-autonomous-hunt.sh: $line" >&2
done

# The FINAL VERDICT for the routed candidate is the durable coordinator:last_outcome memo (the substrate-native
# cross-process channel): `<type>|<args>|<verdict>`. The verdict is the fuzzer's shrunk witness, never the LLM.
OUTCOME="$( ( cd "$RUN" && "$AGENTIS" memo get coordinator:last_outcome ) 2>/dev/null | tail -1 )"
POLICY_AFTER="$( ( cd "$RUN" && "$AGENTIS" memo get coordinator:policy_after ) 2>/dev/null )"
echo "run-autonomous-hunt.sh: final coordinator:last_outcome = [$OUTCOME]" >&2
echo "run-autonomous-hunt.sh: policy AFTER the run        = [$POLICY_AFTER]" >&2
echo "run-autonomous-hunt.sh: full run log -> $RUN_LOG" >&2
exit 0
