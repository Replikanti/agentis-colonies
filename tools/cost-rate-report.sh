#!/usr/bin/env bash
# cost-rate-report.sh - Per-agent / per-role cost + rate instrumentation
# report (#1114).
#
# Reads each colony's per-prompt spend rows
# (<fed>/<colony>/.agentis/spend/<agent>.jsonl, #311 — one row ~= one prompt)
# plus `agentis stats --json --per-identity`, folds them via the Python
# reducer in tools/cost-rate-report.py, and emits a machine-readable
# cost+rate report per agent and aggregated per role (colony).
#
# Mirrors tools/cost-cap.sh shape: <fed-dir> arg, repo-relative path
# resolution, all Python logic in a separate helper. Per the CLAUDE.md
# no-heredoc invariant, this script never uses heredocs; the reducer logic
# lives in tools/cost-rate-report.py.
#
# Usage:
#     ./tools/cost-rate-report.sh <federation-dir> [--json] [--baseline]
#     ./tools/cost-rate-report.sh --self-test
#
# Modes:
#     (default)    one compact line per role on stdout:
#                  role=<r> prompts=<n> pph=<x> cin=<n> cout=<n> cost=<usd> \
#                      throttle=<n> retries=<n>
#     --json       emit the full structured object (agents + roles).
#     --baseline   additionally stamp the current per-agent number as a
#                  recorded artifact at
#                  <fed>/.agentis/logs/cost-rate-baseline.json so later
#                  improvements are provable against a recorded "before".
#     --self-test  seed a synthetic spend.jsonl + stats fixture in a temp
#                  dir, run the full pipeline, and ASSERT every field
#                  (incl. the throttle-vs-task-error split + baseline stamp).
#                  Exits non-zero on any mismatch.
#
# Throttle vs task-error split (hard DoD line): the throttle counter counts
# forge-429 / [llm.cancelled] rows; the task-error counter counts agent
# failure markers. They are SEPARATE fields end to end (see
# cost-rate-report.py). The LLM-backend HTTP-429 backoff / prompt cache that
# produces [llm.cancelled] rows lives in the agentis runtime / LLM backend
# (handled upstream); this report only observes the resulting rows.

set -eu

# --- Path resolution ---

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

REDUCER="$SCRIPT_DIR/cost-rate-report.py"

# Trailing window (minutes) for prompts_per_hour. Override via env.
WINDOW_MIN="${COST_RATE_WINDOW_MIN:-60}"
case "$WINDOW_MIN" in
    ''|*[!0-9]*) WINDOW_MIN=60 ;;
    *) [ "$WINDOW_MIN" -gt 0 ] || WINDOW_MIN=60 ;;
esac

# Pre-fix baseline (#1114): ~74 KB/agent of chars before the instrumentation
# work began. Stamped into the baseline artifact so improvements are provable.
BASELINE_KB_PER_AGENT="${COST_RATE_BASELINE_KB:-74}"

emit_compact() {
    # $1 = full reducer JSON. Prints one compact line per role.
    python3 -c "
import json, sys
data = json.loads(sys.argv[1] or '{}')
for r in data.get('roles', []):
    print('role=%s prompts=%d pph=%s cin=%d cout=%d cost=%s throttle=%d retries=%d' % (
        r.get('colony') or '-',
        int(r.get('prompts') or 0),
        ('%.4f' % float(r.get('prompts_per_hour') or 0)),
        int(r.get('chars_in') or 0),
        int(r.get('chars_out') or 0),
        ('%.6f' % float(r.get('cost_usd') or 0)),
        int(r.get('throttle_events') or 0),
        int(r.get('retries') or 0),
    ))
" "$1"
}

# stamp_baseline <fed> <reducer_json>: write the recorded pre-fix artifact.
stamp_baseline() {
    local fed="$1" reduced="$2"
    local log_dir="$fed/.agentis/logs"
    mkdir -p "$log_dir" 2>/dev/null || true
    local out="$log_dir/cost-rate-baseline.json"
    python3 -c "
import json, sys, time
reduced = json.loads(sys.argv[1] or '{}')
kb = float(sys.argv[2])
agents = reduced.get('agents', [])
baseline = {
    'ts': int(time.time()),
    'ts_iso': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'baseline_kb_per_agent': kb,
    'window_min': reduced.get('window_min'),
    'agent_count': len(agents),
    'agents': [
        {
            'colony': a.get('colony'),
            'agent': a.get('agent'),
            'prompts': a.get('prompts'),
            'chars_in': a.get('chars_in'),
            'chars_out': a.get('chars_out'),
            'cost_usd': a.get('cost_usd'),
            'throttle_events': a.get('throttle_events'),
            'task_errors': a.get('task_errors'),
            'retries': a.get('retries'),
        }
        for a in agents
    ],
}
with open(sys.argv[3], 'w') as f:
    json.dump(baseline, f)
print(sys.argv[3])
" "$reduced" "$BASELINE_KB_PER_AGENT" "$out"
}

# collect_stats <fed>: emit a JSON map {colony: stats_obj} from
# `agentis stats --json --per-identity` run per colony (cwd-scoped). Missing
# stats / a missing agentis binary degrade to {} (NOT an error) so the report
# still runs against the spend rows alone.
collect_stats() {
    local fed="$1"
    local map="{}"
    if ! command -v agentis >/dev/null 2>&1; then
        echo "$map"
        return 0
    fi
    local colony stats_json
    for colony_dir in "$fed"/*/; do
        [ -d "$colony_dir" ] || continue
        colony="$(basename "$colony_dir")"
        # Skip the federation's own .agentis bookkeeping dir.
        [ "$colony" = ".agentis" ] && continue
        stats_json="$(cd "$colony_dir" && agentis stats --json --per-identity 2>/dev/null || echo '{}')"
        map="$(C="$colony" S="$stats_json" M="$map" python3 -c '
import json, os
try:
    m = json.loads(os.environ.get("M") or "{}")
except Exception:
    m = {}
try:
    s = json.loads(os.environ.get("S") or "{}")
except Exception:
    s = {}
m[os.environ["C"]] = s
print(json.dumps(m))' 2>/dev/null || echo "$map")"
    done
    echo "$map"
}

# run_report <fed> <emit_json> <do_baseline>: shared report driver. Used by
# both the live path and the self-test.
run_report() {
    local fed="$1" emit_json="$2" do_baseline="$3"
    local spend_glob="$fed/*/.agentis/spend/*.jsonl"
    local stats_map reduced
    stats_map="$(collect_stats "$fed")"
    reduced="$(python3 "$REDUCER" "$spend_glob" "$WINDOW_MIN" "$stats_map" 2>/dev/null || echo '{}')"
    if [ "$do_baseline" = "1" ]; then
        stamp_baseline "$fed" "$reduced" >/dev/null
    fi
    if [ "$emit_json" = "1" ]; then
        printf '%s\n' "$reduced"
    else
        emit_compact "$reduced"
    fi
}

# --- --self-test ---

# Global so the EXIT trap can reference it without tripping `set -u` after the
# self_test function frame is gone (the trap fires at script exit, by which
# point a `local tmp` would be out of scope).
SELF_TEST_TMP=""
cleanup_self_test() {
    [ -n "${SELF_TEST_TMP:-}" ] && rm -rf "$SELF_TEST_TMP"
}

self_test() {
    SELF_TEST_TMP="$(mktemp -d)"
    trap cleanup_self_test EXIT
    local tmp="$SELF_TEST_TMP"
    local fed="$tmp/dev-apprenticeship"
    local spend="$fed/triage/.agentis/spend"
    mkdir -p "$spend"

    # Seed a synthetic spend.jsonl for one agent. now-anchored timestamps so
    # the trailing-window rate is deterministic: 3 rows inside a 60-min
    # window. Mix of cost / output_tokens / a throttle row ([llm.cancelled])
    # and a task-error row (outcome=fail) to exercise the split.
    NOW="$(date +%s)"
    SPEND_FILE="$spend/router.jsonl" NOW="$NOW" python3 -c '
import json, os
now = int(os.environ["NOW"])
rows = [
    {"ts": now - 60,  "cost_usd": 0.01, "output_tokens": 100, "cost_source": "real"},
    {"ts": now - 120, "cost_usd": 0.02, "output_tokens": 200, "cost_source": "real"},
    {"ts": now - 180, "cost_usd": None, "output_tokens": 50,  "cost_source": "cancelled"},
    {"ts": now - 240, "cost_usd": 0.03, "output_tokens": 70,  "cost_source": "real", "outcome": "fail"},
]
with open(os.environ["SPEND_FILE"], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
'

    # Stats fixture: avg_input_size = 500 chars/prompt for the triage colony.
    STATS_MAP='{"triage":{"avg_input_size":500.0,"total_prompts":4,"total_cb":20,"avg_cb_per_prompt":5.0}}'

    local reduced
    reduced="$(python3 "$REDUCER" "$fed/*/.agentis/spend/*.jsonl" 60 "$STATS_MAP")"

    local fails=0
    assert_field() {
        # $1 jq-ish python path expr, $2 expected, $3 label
        local got
        got="$(R="$reduced" python3 -c "
import json, os
d = json.loads(os.environ['R'])
$1
print(val)" 2>/dev/null || echo '__ERR__')"
        if [ "$got" = "$2" ]; then
            echo "[PASS] $3 ($got)"
        else
            echo "[FAIL] $3 (got '$got', want '$2')"
            fails=$((fails + 1))
        fi
    }

    # Agent-level assertions (the single router agent record).
    assert_field "val = d['agents'][0]['colony']"           "triage"  "agent colony"
    assert_field "val = d['agents'][0]['agent']"            "router"  "agent name"
    assert_field "val = d['agents'][0]['prompts']"          "4"       "prompts = row count"
    # 4 rows all within the 60-min window: (4/60)*60 = 4.0 prompts/hour.
    assert_field "val = ('%.1f' % d['agents'][0]['prompts_per_hour'])" "4.0" "prompts_per_hour"
    # chars_in proxy = avg_input_size(500) * prompts(4) = 2000.
    assert_field "val = d['agents'][0]['chars_in']"         "2000"    "chars_in proxy"
    # chars_out proxy = sum(output_tokens) = 100+200+50+70 = 420.
    assert_field "val = d['agents'][0]['chars_out']"        "420"     "chars_out proxy"
    # cost_usd = 0.01 + 0.02 + 0(null) + 0.03 = 0.06.
    assert_field "val = ('%.2f' % d['agents'][0]['cost_usd'])" "0.06" "cost_usd (null -> 0)"
    # Throttle-vs-task-error split: 1 throttle ([llm.cancelled]), 1 task error.
    assert_field "val = d['agents'][0]['throttle_events']"  "1"       "throttle_events (split)"
    assert_field "val = d['agents'][0]['task_errors']"      "1"       "task_errors (split)"
    # retries not derivable from spend rows -> 0 (documented note).
    assert_field "val = d['agents'][0]['retries']"          "0"       "retries (0, documented)"

    # Role-level aggregate mirrors the single agent.
    assert_field "val = d['roles'][0]['colony']"            "triage"  "role colony"
    assert_field "val = d['roles'][0]['prompts']"           "4"       "role prompts"
    assert_field "val = d['roles'][0]['throttle_events']"   "1"       "role throttle_events"
    assert_field "val = d['roles'][0]['task_errors']"       "1"       "role task_errors"

    # Compact line shape.
    local compact
    compact="$(emit_compact "$reduced")"
    case "$compact" in
        *"role=triage prompts=4 pph=4.0000 cin=2000 cout=420 cost=0.060000 throttle=1 retries=0"*)
            echo "[PASS] compact line shape" ;;
        *)
            echo "[FAIL] compact line shape (got '$compact')"
            fails=$((fails + 1)) ;;
    esac

    # Baseline stamp.
    stamp_baseline "$fed" "$reduced" >/dev/null
    local baseline_file="$fed/.agentis/logs/cost-rate-baseline.json"
    if [ -f "$baseline_file" ]; then
        local b_kb b_count
        b_kb="$(B="$baseline_file" python3 -c "import json,os;print(json.load(open(os.environ['B']))['baseline_kb_per_agent'])" 2>/dev/null || echo '')"
        b_count="$(B="$baseline_file" python3 -c "import json,os;print(json.load(open(os.environ['B']))['agent_count'])" 2>/dev/null || echo '')"
        if [ "$b_kb" = "74.0" ] && [ "$b_count" = "1" ]; then
            echo "[PASS] baseline stamp (kb=$b_kb agents=$b_count)"
        else
            echo "[FAIL] baseline stamp (kb='$b_kb' agents='$b_count')"
            fails=$((fails + 1))
        fi
    else
        echo "[FAIL] baseline file not written: $baseline_file"
        fails=$((fails + 1))
    fi

    echo ""
    echo "Results: self-test fails=$fails"
    [ "$fails" -eq 0 ]
}

# --- Arg parsing ---

EMIT_JSON=0
DO_BASELINE=0
SELF_TEST=0
FED_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --json)      EMIT_JSON=1; shift ;;
        --baseline)  DO_BASELINE=1; shift ;;
        --self-test) SELF_TEST=1; shift ;;
        -*)
            echo "cost-rate-report.sh: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            if [ -z "$FED_ARG" ]; then
                FED_ARG="$1"
            else
                echo "cost-rate-report.sh: unexpected extra arg: $1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

if [ "$SELF_TEST" = "1" ]; then
    self_test
    exit $?
fi

if [ -z "$FED_ARG" ]; then
    echo "Usage: $0 <federation-dir> [--json] [--baseline]" >&2
    echo "       $0 --self-test" >&2
    exit 1
fi

FED_DIR="$REPO_ROOT/$FED_ARG"
if [ ! -d "$FED_DIR" ]; then
    FED_DIR="$FED_ARG"
fi
if [ ! -d "$FED_DIR" ]; then
    echo "Federation directory not found: $FED_ARG" >&2
    exit 1
fi

run_report "$FED_DIR" "$EMIT_JSON" "$DO_BASELINE"
