#!/usr/bin/env bash
# run-coordinator.sh — #1014: the thin DISPATCHER for the self-orchestrating discovery loop.
#
# WHAT IT IS (and is NOT). This script does NOT decide the audit workflow. Each step it asks
# auditor/agents/coordinator.ag for ONE decision — `coordinator.ag` reads the current FACTS (scope,
# per-class lens fitness, the shared blackboard, pending unverified candidates, remaining budget, the
# previous action's gate OUTCOME) and the evolving POLICY, and emits exactly one
#   ACTION|<type>|<args>|<rationale citing the facts>
# line (type in {hunt, refute, poc-screen, invent-method, stop}). This loop then DISPATCHES that action,
# captures its OUTCOME (a FACT from a gate, never an LLM judgement), feeds the outcome back, and repeats
# until the coordinator says `stop` or the step budget is spent. The DECISION + its evolution are the
# coordinator's; the loop only executes the chosen action and carries state between steps.
#
# This replaces the DECISION-MAKING that run-discovery.sh's fixed (subsystem x class) fan-out + an
# operator used to do — fixed order, externally chosen target/method/when-to-stop. The fan-out scripts
# remain valid executors; what moves into the substrate here is the CHOICE of what to run next, from
# facts + a policy that improves by outcome. (Follow-up, tracked on epic #1014: move dispatch itself into
# the substrate via emit/listen so even this loop disappears; multi-target portfolio decisions.)
#
# HOW THE POLICY EVOLVES (mirrors evolve-fitness.sh). coordinator.ag records the previous action's
# outcome with the SAME learn() call hunter.ag/fitness-driver.ag use:
#   learn("coordinator", "<action-type>", ..., success|failure, [...])
# (+0.15 per confirmed-finding success, -0.15 per dry/refuted failure). The CUMULATIVE delta per
# action-type key IS `coordinator:policy:<action-type>` — this script reads it back from
# .agentis/experience/*.jsonl exactly as evolve-fitness.sh's read_fitness does, and passes it in as the
# POLICY fact on the next call. So the policy that ranks the options is DATA that improves across steps.
#
# DISPATCH MODES.
#   --executor real   (default) route hunt->hunter.ag, refute->refuter.ag, poc-screen->poc-screener.ag,
#                     invent-method->method-inventor.ag, deriving the OUTCOME from the agent's verdict
#                     line. Requires the per-action env a real run would set (TARGET_DIR/IN_SCOPE/...);
#                     this mode is the integration surface for a live audit and needs a reasoning
#                     backend (--backend flat-cyborg, flat-rate default; or --backend claude, metered)
#                     for the agents to actually reason. (The decision is still offline-deterministic.)
#   --executor stub --fixture <f>   OFFLINE + DETERMINISTIC: dispatch each chosen action to a scripted
#                     outcome read from a fixture (`<action-type> <args-glob> -> confirmed|dry|refuted`).
#                     No LLM, no network — used by demo-coordinator.sh to prove the loop reproducibly.
#
# Usage:
#   run-coordinator.sh --scope <file> [--class-fitness <file>] [--budget N] [--dry-cap K]
#                      [--executor real|stub] [--fixture <f>] [--backend mock|flat-cyborg|claude]
#                      [--out <dir>] [--agentis <bin>]
#
# Scope manifest (one huntable cell per line; `#` and blank lines ignored), pipe-delimited:
#   <subsystem label> | <class id>          e.g.  vault accounting | C1
# Class-fitness file (optional; one per line) seeds the per-lens fitness fact:
#   <class id> | <fitness float>            e.g.  C1 | 0.45
# Fixture (stub mode; one rule per line, first match wins; `*` glob on args):
#   <action-type> | <args-glob> | <confirmed|dry|refuted>   e.g.  hunt | vault* | confirmed
#   NB: the rule is split on `|`, so <args-glob> must NOT contain a literal `|`. A hunt's args are
#   `subsystem|class`; match them with a subsystem-prefix glob (`vault*`) whose trailing `*` spans the
#   `|class` suffix — `vault accounting|C1` would be mis-split (the class read as the outcome field).
#
# Exit: 0 on a clean run that reached `stop`/budget; 2 on usage error; 3 on missing prerequisite.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
SCOPE_FILE=""
CLASSFIT_FILE=""
BUDGET=12
DRY_CAP=3
EXECUTOR="real"
FIXTURE=""
BACKEND="mock"
OUT="$PWD/coordinator-out"

need() { [ "$1" -ge 2 ] || { echo "run-coordinator.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --scope)         need "$#"; SCOPE_FILE="$2"; shift 2 ;;
    --class-fitness) need "$#"; CLASSFIT_FILE="$2"; shift 2 ;;
    --budget)        need "$#"; BUDGET="$2"; shift 2 ;;
    --dry-cap)       need "$#"; DRY_CAP="$2"; shift 2 ;;
    --executor)      need "$#"; EXECUTOR="$2"; shift 2 ;;
    --fixture)       need "$#"; FIXTURE="$2"; shift 2 ;;
    --backend)       need "$#"; BACKEND="$2"; shift 2 ;;
    --out)           need "$#"; OUT="$2"; shift 2 ;;
    --agentis)       need "$#"; AGENTIS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-coordinator.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$SCOPE_FILE" ] || { echo "run-coordinator.sh: --scope <file> is required" >&2; exit 2; }
[ -f "$SCOPE_FILE" ] || { echo "run-coordinator.sh: --scope not found: $SCOPE_FILE" >&2; exit 2; }
case "$BUDGET"  in (*[!0-9]*|'') echo "run-coordinator.sh: --budget must be a non-negative integer" >&2; exit 2 ;; esac
case "$DRY_CAP" in (*[!0-9]*|'') echo "run-coordinator.sh: --dry-cap must be a non-negative integer" >&2; exit 2 ;; esac
case "$EXECUTOR" in real|stub) : ;; *) echo "run-coordinator.sh: --executor must be real|stub" >&2; exit 2 ;; esac
[ "$EXECUTOR" = "stub" ] && { [ -n "$FIXTURE" ] || { echo "run-coordinator.sh: --executor stub needs --fixture <f>" >&2; exit 2; }; [ -f "$FIXTURE" ] || { echo "run-coordinator.sh: --fixture not found: $FIXTURE" >&2; exit 2; }; }
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-coordinator.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

COORD_AG="$HERE/auditor/agents/coordinator.ag"
[ -f "$COORD_AG" ] || { echo "run-coordinator.sh: coordinator agent not found at $COORD_AG" >&2; exit 3; }

mkdir -p "$OUT" || { echo "run-coordinator.sh: cannot create --out dir: $OUT" >&2; exit 1; }
OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN" || { echo "run-coordinator.sh: cannot create run dir: $RUN" >&2; exit 1; }
cp "$COORD_AG" "$RUN/coordinator.ag"

# Single shared agentis store for the WHOLE loop: the policy experience the coordinator writes one step
# must be visible to the next step's policy read (and to the blackboard the coordinator consults). init
# FIRST (before any .agentis/ subdir), else HEAD is unset.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p"; echo "llm.cli_timeout_ms = 600000"; }
  [ "$BACKEND" = "flat-cyborg" ] && echo "llm.cli_timeout_ms = 600000"
  echo "trace.level = normal"
  echo "exec.env_passthrough = SCOPE,CLASS_FITNESS,POLICY,PENDING,BUDGET,DRY_STREAK,DRY_CAP,PREV_ACTION,PREV_KEY,LAST_OUTCOME"
  echo "exec.default_timeout_ms = 30000"
  # The whole point: every decision is recorded as experience so coordinator:policy:<type> reweights.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

EXP="$RUN/.agentis/experience/main.jsonl"

# --- policy reader: cumulative delta per action-type from the experience store. The coordinator's
# evolving POLICY. Mirrors evolve-fitness.sh::read_fitness (and tools/colony-fitness.py) exactly: sum the
# experience `delta` per `in` key for action=="coordinator". Emits `type=delta;type2=delta2` for the
# POLICY env fact (one line; "" when the store is cold). -------------------------------------------
read_policy() {
  [ -f "$EXP" ] || { printf '%s' ""; return 0; }
  python3 - "$EXP" <<'PY'
import json, os, sys
path = sys.argv[1]
agg = {}
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
            if r.get("action") != "coordinator":
                continue
            k = r.get("in", "")
            if not k:
                continue
            agg[k] = agg.get(k, 0.0) + float(r.get("delta", 0.0))
print(";".join("%s=%.4f" % (k, agg[k]) for k in sorted(agg)))
PY
}

# Seed the per-lens CLASS_FITNESS fact from --class-fitness (`class|float` -> `class=float;...`). Static
# for the run (a fuller integration would read it live from the hunt experience like read_policy does).
CLASS_FITNESS=""
if [ -n "$CLASSFIT_FILE" ]; then
  [ -f "$CLASSFIT_FILE" ] || { echo "run-coordinator.sh: --class-fitness not found: $CLASSFIT_FILE" >&2; exit 2; }
  CLASS_FITNESS="$(awk -F'|' '
    { c=$1; v=$2; gsub(/^[ \t]+|[ \t]+$/,"",c); gsub(/^[ \t]+|[ \t]+$/,"",v); }
    c=="" || c ~ /^#/ { next }
    { printf "%s%s=%s", sep, c, v; sep=";" }
  ' "$CLASSFIT_FILE")"
fi

# SCOPE fact: the huntable cells as newline-joined `subsystem|class`, from the scope manifest.
SCOPE="$(awk -F'|' '
  { s=$1; c=$2; gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/^[ \t]+|[ \t]+$/,"",c); }
  s=="" || s ~ /^#/ { next }
  { printf "%s%s|%s", sep, s, c; sep="\n" }
' "$SCOPE_FILE")"

# --- stub executor: scripted outcome for a chosen action from the fixture (first match wins; `*` glob on
# the action ARGS). Returns confirmed|dry|refuted on stdout; `dry` if no rule matches (a benign default).
# The fixture line is split on `|` into type|glob|outcome, so the glob must not contain a literal `|`
# (see the Fixture note in the header): a subsystem-prefix glob matches a `subsystem|class` hunt arg.
stub_outcome() {
  _atype="$1"; _aargs="$2"
  awk -F'|' -v at="$_atype" -v ar="$_aargs" '
    function trim(x){ gsub(/^[ \t]+|[ \t]+$/,"",x); return x }
    { t=trim($1); g=trim($2); o=trim($3) }
    t=="" || t ~ /^#/ { next }
    {
      # glob -> regex: escape regex metachars, then turn \* into .*
      gg=g; gsub(/[.[\]()+^${}|\\]/,"\\\\&",gg); gsub(/\*/,".*",gg)
      if (t==at && ar ~ ("^" gg "$")) { print o; found=1; exit }
    }
    END { if (!found) print "dry" }
  ' "$FIXTURE"
}

# --- real executor: dispatch to the matching agent and DERIVE the outcome from its verdict line. This is
# the v1 integration surface; it needs the per-action env a live audit would set (TARGET_DIR/IN_SCOPE/
# CODE_PATH/...). With --backend mock the agents do not reason, so this path needs a reasoning backend
# (--backend flat-cyborg, flat-rate default; or --backend claude, metered) for wiring;
# the offline+deterministic proof uses --executor stub. We keep the routing explicit and honest.
real_outcome() {
  _atype="$1"; _aargs="$2"
  case "$_atype" in
    hunt)
      # hunter.ag prints `CANDIDATE|...` (a lead -> treat as a candidate to verify, outcome=dry until
      # verified) or `SAFE` (outcome=dry). A live loop would queue the CANDIDATE into PENDING; without the
      # target env wired here we cannot run the real read, so signal the missing wiring loudly.
      echo "run-coordinator.sh: real hunt dispatch needs TARGET_DIR/IN_SCOPE/SCOPE_BRIEF/TAXONOMY/SLICER wired (see run-discovery.sh); use --executor stub for the offline demo" >&2
      printf '%s' "dry" ;;
    refute|poc-screen|invent-method)
      echo "run-coordinator.sh: real $_atype dispatch needs the candidate code/env wired (see run-refute.sh / screen-leads.sh / run-method-discovery.sh); use --executor stub for the offline demo" >&2
      printf '%s' "dry" ;;
    *) printf '%s' "dry" ;;
  esac
}

# --- the loop. State carried between steps: PENDING (unverified candidates), DRY_STREAK, BUDGET, and the
# PREV action/outcome the coordinator attributes to its policy. The coordinator DECIDES; we DISPATCH. ---
PENDING=""
DRY_STREAK=0
PREV_ACTION=""
PREV_KEY=""
LAST_OUTCOME=""
STEP=0
TRACE="$OUT/decisions.tsv"
: > "$TRACE"

echo "run-coordinator.sh: policy BEFORE the run: [$(read_policy)]" >&2

while [ "$STEP" -lt "$BUDGET" ]; do
  REMAINING=$((BUDGET - STEP))
  POLICY="$(read_policy)"

  DEC_LOG="$RUN/decision_$STEP.log"
  # ONE decision: hand the coordinator every FACT; it returns exactly one ACTION| line.
  ( cd "$RUN" && env \
      SCOPE="$SCOPE" \
      CLASS_FITNESS="$CLASS_FITNESS" \
      POLICY="$POLICY" \
      PENDING="$PENDING" \
      BUDGET="$REMAINING" \
      DRY_STREAK="$DRY_STREAK" \
      DRY_CAP="$DRY_CAP" \
      PREV_ACTION="$PREV_ACTION" \
      PREV_KEY="$PREV_KEY" \
      LAST_OUTCOME="$LAST_OUTCOME" \
      "$AGENTIS" go coordinator.ag --enable-exec --enable-messaging ) >"$DEC_LOG" 2>&1 \
    || { echo "run-coordinator.sh: coordinator call failed at step $STEP (see $DEC_LOG)" >&2; exit 1; }

  ACTION_LINE="$(grep -E '^ACTION\|' "$DEC_LOG" | head -1)"
  [ -n "$ACTION_LINE" ] || { echo "run-coordinator.sh: no ACTION line at step $STEP (see $DEC_LOG)" >&2; exit 1; }

  # Parse `ACTION|<type>|<args>|<rationale>`. <args> is a SINGLE `|`-field for refute/poc-screen
  # (a `cand-id`) and "" for invent-method/stop, but TWO fields for a hunt (`subsystem|class`). So the
  # field where the rationale begins is type-dependent — a flat `cut -f3`/`-f4-` would otherwise drop a
  # hunt's class into the rationale and build a malformed `cand-N|subsystem` PENDING id. Mirrors the
  # field shape demo-coordinator.sh's `expect` helper documents.
  ATYPE="$(printf '%s' "$ACTION_LINE" | cut -d'|' -f2)"
  if [ "$ATYPE" = "hunt" ]; then
    AARGS="$(printf '%s' "$ACTION_LINE" | cut -d'|' -f3-4)"
    ARATIONALE="$(printf '%s' "$ACTION_LINE" | cut -d'|' -f5-)"
  else
    AARGS="$(printf '%s' "$ACTION_LINE" | cut -d'|' -f3)"
    ARATIONALE="$(printf '%s' "$ACTION_LINE" | cut -d'|' -f4-)"
  fi
  printf 'step=%s\taction=%s\targs=%s\tpolicy=[%s]\trationale=%s\n' "$STEP" "$ATYPE" "$AARGS" "$POLICY" "$ARATIONALE" >> "$TRACE"
  echo "run-coordinator.sh: step $STEP -> $ATYPE${AARGS:+ $AARGS}  ($ARATIONALE)" >&2

  if [ "$ATYPE" = "stop" ]; then
    echo "run-coordinator.sh: coordinator decided STOP at step $STEP" >&2
    break
  fi

  # DISPATCH the chosen action and capture its gate OUTCOME (a FACT, fed back next step).
  if [ "$EXECUTOR" = "stub" ]; then
    OUTCOME="$(stub_outcome "$ATYPE" "$AARGS")"
  else
    OUTCOME="$(real_outcome "$ATYPE" "$AARGS")"
  fi
  echo "run-coordinator.sh:   dispatch outcome: $OUTCOME" >&2

  # Update carried state from the outcome (these are FACTS, not decisions):
  #  * a hunt that 'confirmed' surfaces a NEW candidate lead -> push it onto PENDING for verification.
  #  * refute/poc-screen consume the first pending candidate (the one the coordinator pointed at),
  #    regardless of confirmed/refuted — the gate has now spoken on it either way.
  #  * dry/refuted advance the dry streak; a confirmed finding resets it.
  case "$ATYPE" in
    hunt)
      if [ "$OUTCOME" = "confirmed" ]; then
        CAND="cand-$STEP|$AARGS"
        PENDING="$(printf '%s\n%s' "$PENDING" "$CAND" | grep -v '^$' || true)"
      fi ;;
    refute|poc-screen)
      # consume the first pending candidate (the one the coordinator pointed at)
      PENDING="$(printf '%s\n' "$PENDING" | grep -v '^$' | tail -n +2 || true)" ;;
  esac

  if [ "$OUTCOME" = "confirmed" ]; then
    DRY_STREAK=0
  else
    DRY_STREAK=$((DRY_STREAK + 1))
  fi

  PREV_ACTION="$ATYPE"
  PREV_KEY="$AARGS"
  LAST_OUTCOME="$OUTCOME"
  STEP=$((STEP + 1))
done

# Feed the FINAL action's outcome back so its policy delta is recorded too (the loop above attributes the
# previous outcome on the NEXT call; a terminal `stop`/budget has no next call). One last coordinator
# invocation with BUDGET=0 forces a stop AND records the last attribution, then exits.
if [ -n "$PREV_ACTION" ]; then
  ( cd "$RUN" && env \
      SCOPE="$SCOPE" CLASS_FITNESS="$CLASS_FITNESS" POLICY="$(read_policy)" PENDING="$PENDING" \
      BUDGET=0 DRY_STREAK="$DRY_STREAK" DRY_CAP="$DRY_CAP" \
      PREV_ACTION="$PREV_ACTION" PREV_KEY="$PREV_KEY" LAST_OUTCOME="$LAST_OUTCOME" \
      "$AGENTIS" go coordinator.ag --enable-exec --enable-messaging ) >"$RUN/decision_final.log" 2>&1 || true
fi

POLICY_AFTER="$(read_policy)"
echo "run-coordinator.sh: policy AFTER the run:  [$POLICY_AFTER]" >&2
echo "run-coordinator.sh: decision trace -> $TRACE" >&2
printf '%s' "$POLICY_AFTER" > "$OUT/policy-after.txt"
exit 0
