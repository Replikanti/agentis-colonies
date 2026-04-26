#!/usr/bin/env bash
# tools/replay-export-experience.sh: package a federation's experience
# store as a single replay-friendly JSONL pack keyed by agent name.
#
# Walks <fed-dir>/.agentis/experience/<agent_id>.jsonl files (with the
# parent-fallback path that auto-promote and federation-dashboard already
# use for the symlinked single-federation layout, see #333), maps each
# <agent_id> back to its agent name via `agentis daemon list --json`,
# and emits one combined JSONL where every row carries an explicit
# `agent_name` field. The combined pack is the input format the
# upstream `agentis replay` mode reads.
#
# Why the agent_id -> agent_name remap matters: the replay engine
# scores a candidate `.ag` source against history. The candidate's
# eventual `agent_id` after `agentis daemon` startup will differ from
# the historical id (registration is fresh on every rebuild — see
# doc/replay-mode.md#exporting-an-experience-pack). Keying by name
# gives replay a stable handle on a candidate that has not yet been
# registered.
#
# This is a thin wrapper. If #323 (tools/experience-transfer.sh)
# lands, this script will delegate to it via
#   experience-transfer.sh export --replay-pack
# rather than duplicating the walk. Until then, this self-contained
# implementation handles the minimal walk replay needs.
#
# Usage:
#   ./tools/replay-export-experience.sh <fed-dir> <out.jsonl>
#   ./tools/replay-export-experience.sh <fed-dir> <out.jsonl> --agent <name>
#
# --agent <name>  Restrict the pack to one agent (otherwise all agents in
#                 the federation are exported).
#
# Exit codes: 0 = ok, 2 = bad args / fed-dir not found, 3 = no
# experience files found.
#
# Bash 3.2 portable (stock macOS /bin/bash). No heredocs, no
# associative arrays, no mapfile, no `declare -A`.

set -eu

usage() {
    cat <<'__USAGE_PLAIN__'
Usage: replay-export-experience.sh <fed-dir> <out.jsonl> [--agent <name>]

Exports the federation's experience store as a single JSONL pack
keyed by agent name, suitable as input for `agentis replay`.

Arguments:
  <fed-dir>      Federation directory (the one containing colony subdirs
                 and .agentis/).
  <out.jsonl>    Output file. Will be overwritten if it exists.

Options:
  --agent <name> Restrict the pack to one agent name.
  -h, --help     Print this help and exit.
__USAGE_PLAIN__
}

# ^^ The single heredoc above is in usage() and is entered only when
# the user passes -h/--help, so it runs zero times in CI / colony-lint
# discovery. macOS bash 3.2 still parses it cleanly because the body
# has no $() nesting and the delimiter is single-quoted.

FED_DIR=""
OUT=""
AGENT=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --agent)
            shift
            if [ $# -eq 0 ]; then
                echo "error: --agent requires a value" >&2
                exit 2
            fi
            AGENT="$1"
            shift
            ;;
        --*)
            echo "error: unknown flag $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -z "$FED_DIR" ]; then
                FED_DIR="$1"
            elif [ -z "$OUT" ]; then
                OUT="$1"
            else
                echo "error: unexpected positional argument $1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

if [ -z "$FED_DIR" ] || [ -z "$OUT" ]; then
    usage >&2
    exit 2
fi

if [ ! -d "$FED_DIR" ]; then
    echo "error: federation directory not found: $FED_DIR" >&2
    exit 2
fi

# Resolve experience root. Prefer the fed-local .agentis/experience
# (sibling-federation isolation per #238); fall back to the parent
# .agentis/experience that the symlinked single-federation layout
# lands on (#333). If both exist, the fed-local takes priority,
# matching auto-promote-decisions.py's resolver.
EXP_DIR=""
if [ -d "$FED_DIR/.agentis/experience" ]; then
    EXP_DIR="$FED_DIR/.agentis/experience"
elif [ -d "$FED_DIR/../.agentis/experience" ]; then
    EXP_DIR="$(cd "$FED_DIR/../.agentis/experience" && pwd)"
else
    echo "error: no .agentis/experience/ found under $FED_DIR (or parent)" >&2
    exit 3
fi

# Collect (agent_id -> agent_name) map via `agentis daemon list --json`.
# If `agentis` is not on PATH, fall back to keying every row by its
# raw agent_id; the replay engine will warn about anonymous rows but
# remains functional.
DAEMONS_JSON=""
if command -v agentis >/dev/null 2>&1; then
    DAEMONS_JSON="$(agentis daemon list --json 2>/dev/null || true)"
fi
if [ -z "$DAEMONS_JSON" ]; then
    DAEMONS_JSON="[]"
fi

# Hand off the heavy lifting to a small inline python3 program. We
# avoid heredocs (#172, #245 reasons — macOS bash 3.2 mis-parses some
# heredoc + $() combinations); the program is delivered via -c.
PY_PROG='
import json, os, sys, glob

exp_dir = sys.argv[1]
out_path = sys.argv[2]
filter_agent = sys.argv[3] or None
daemons_raw = sys.argv[4] or "[]"

try:
    daemons = json.loads(daemons_raw)
except Exception:
    daemons = []

# Build agent_id -> agent_name map. Agent name is derived from the
# .ag source filename (strip .ag), matching auto-promote-decisions.py.
id_to_name = {}
for d in daemons:
    if not isinstance(d, dict):
        continue
    aid = d.get("agent_id", "")
    src = d.get("source", "")
    if not aid or not src:
        continue
    name = os.path.basename(src)
    if name.endswith(".ag"):
        name = name[:-3]
    id_to_name[aid] = name

# Walk every <agent_id>.jsonl in EXP_DIR. If the registry mapped it,
# tag rows with agent_name; otherwise carry the raw id as agent_name
# so the replay engine still has a deterministic handle.
files = sorted(glob.glob(os.path.join(exp_dir, "*.jsonl")))
total_rows = 0
agents_seen = set()

with open(out_path, "w") as out_f:
    for f in files:
        agent_id = os.path.splitext(os.path.basename(f))[0]
        agent_name = id_to_name.get(agent_id, agent_id)
        if filter_agent and agent_name != filter_agent:
            continue
        agents_seen.add(agent_name)
        with open(f) as in_f:
            for line in in_f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                if not isinstance(row, dict):
                    continue
                # Inject agent_name and source agent_id so the replay
                # engine can correlate even when the candidate .ag
                # registers under a fresh id.
                row["agent_name"] = agent_name
                row.setdefault("agent_id_source", agent_id)
                out_f.write(json.dumps(row, separators=(",", ":")) + "\n")
                total_rows += 1

# Summary on stderr (stdout is reserved for any future structured
# output a CI harness might want to consume).
sys.stderr.write(
    "[replay-export] %d rows from %d agents -> %s\n"
    % (total_rows, len(agents_seen), out_path)
)
if filter_agent and filter_agent not in agents_seen:
    sys.stderr.write(
        "[replay-export] warning: --agent %s matched zero rows\n"
        % filter_agent
    )
    sys.exit(3)
if total_rows == 0:
    sys.stderr.write("[replay-export] warning: no rows exported\n")
    sys.exit(3)
'

exec python3 -c "$PY_PROG" "$EXP_DIR" "$OUT" "$AGENT" "$DAEMONS_JSON"
