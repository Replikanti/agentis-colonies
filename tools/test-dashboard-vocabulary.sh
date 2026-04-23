#!/bin/bash
# tools/test-dashboard-vocabulary.sh: regression guard that
# federation-dashboard stays federation-type-agnostic (#257).
#
# The dashboard ships as a separately-versioned standalone component
# (#252) and auto-discovers colonies from whatever federation it is
# pointed at. It therefore must not hardcode forge-specific vocabulary
# or config-parsing logic. In particular:
#
#   1. The HTML template surfaced to the operator must not mention
#      "GitLab", "MRs", "merge request", or any GITLAB_* env var name.
#   2. The server.py runtime (non-comment lines) must not read forge
#      config or env — all forge wiring lives inside each colony's
#      scripts/start-colony.sh.
#   3. Orphan helpers removed in #257 (parse_toml_section,
#      resolve_tick_interval) must not be reintroduced.
#   4. restart_daemon must delegate to start-colony.sh --restart-agent,
#      not compose `agentis daemon ...` directly.
#
# Usage: ./tools/test-dashboard-vocabulary.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/federation-dashboard/lib"
TEMPLATE="$LIB_DIR/federation-dashboard.html.template"
SERVER_PY="$LIB_DIR/federation-dashboard-server.py"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if [ ! -f "$TEMPLATE" ]; then
    fail "0: template missing" "$TEMPLATE"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
if [ ! -f "$SERVER_PY" ]; then
    fail "0: server.py missing" "$SERVER_PY"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 1: HTML template carries no GitLab-specific vocabulary. ---
t1_ok=1
for pat in GitLab gitlab MRs 'merge request' GITLAB_URL GITLAB_TOKEN GITLAB_PROJECT; do
    if grep -q -- "$pat" "$TEMPLATE"; then
        echo "  template contains forbidden term: $pat"
        t1_ok=0
    fi
done
if [ "$t1_ok" -eq 1 ]; then
    pass "1: template contains no GitLab-specific vocabulary"
else
    fail "1: template contains forge-specific vocabulary (see lines above)"
fi

# --- Test 2: server.py's non-comment lines reference no GITLAB_* env. ---
if python3 - "$SERVER_PY" <<'PY' 2>/dev/null
import sys
bad = []
with open(sys.argv[1]) as f:
    for i, line in enumerate(f, 1):
        stripped = line.lstrip()
        # Skip comment-only lines and docstring lines.
        if stripped.startswith('#') or stripped.startswith('"""') or stripped.startswith("'''"):
            continue
        for term in ('GITLAB_URL', 'GITLAB_TOKEN', 'GITLAB_PROJECT', 'GITLAB_ME', "'gitlab'"):
            if term in line:
                bad.append((i, term, line.rstrip()))
if bad:
    for i, t, l in bad[:5]:
        sys.stderr.write(f'line {i}: {t}: {l}\n')
    sys.exit(1)
sys.exit(0)
PY
then
    pass "2: server.py runtime code never dispatches on forge env vars"
else
    fail "2: server.py contains non-comment GitLab env references"
fi

# --- Test 3: orphan helpers removed in #257 not re-introduced. ---
t3_ok=1
for fn in 'def parse_toml_section' 'def resolve_tick_interval'; do
    if grep -q -- "$fn" "$SERVER_PY"; then
        echo "  server.py re-introduced: $fn"
        t3_ok=0
    fi
done
if [ "$t3_ok" -eq 1 ]; then
    pass "3: orphan helpers (parse_toml_section, resolve_tick_interval) stay removed"
else
    fail "3: orphan helper re-introduced (see lines above)"
fi

# --- Test 4: restart delegates via start-colony.sh --restart-agent, not
#     by composing its own `agentis daemon` invocation.
#     The grep is intentionally strict: a literal `agentis', 'daemon',`
#     argv fragment in a Popen/run call would match, while delegation
#     uses `bash` + `start_script` + `--restart-agent`.
if grep -q -- "'--restart-agent'" "$SERVER_PY"; then
    t4a=1
else
    t4a=0
fi
# No direct daemon-launch Popen/run should survive: the only remaining
# subprocess.run invocations of 'agentis' are for side-channel ops like
# `memo set`, `daemon stop`, `daemon list`, `evolve`, `quarantine`.
# Direct daemon launch would pass the .ag path as argv[2], which the
# pre-#257 code did via `'agentis', 'daemon', agent_file, ...`.
if grep -qE "'agentis', *'daemon', *agent_file" "$SERVER_PY"; then
    t4b=0
else
    t4b=1
fi
if [ "$t4a" -eq 1 ] && [ "$t4b" -eq 1 ]; then
    pass "4: restart delegates via start-colony.sh --restart-agent, no direct agentis-daemon launch"
else
    msg=""
    [ "$t4a" -eq 0 ] && msg="--restart-agent delegation missing"
    [ "$t4b" -eq 0 ] && msg="${msg:+$msg; }direct agentis-daemon launch re-introduced"
    fail "4: restart delegation broken: $msg"
fi

# --- Test 5: manual_command points at start-colony.sh, not agentis daemon. ---
# build_manual_command returns a one-liner that the operator can paste if
# auto-restart fails. #257 contract: that line MUST invoke start-colony.sh
# --restart-agent <name>, not `cd ... && env ... && agentis daemon ...`.
if python3 - "$SERVER_PY" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
m = re.search(r'def build_manual_command\(.*?\)(.*?)^def ', src, re.DOTALL | re.MULTILINE)
if not m:
    sys.stderr.write('build_manual_command not found\n'); sys.exit(2)
body = m.group(1)
if '--restart-agent' not in body:
    sys.stderr.write('build_manual_command does not mention --restart-agent\n'); sys.exit(3)
if 'agentis daemon' in body or 'GITLAB_URL' in body:
    sys.stderr.write('build_manual_command still composes a direct agentis-daemon one-liner\n'); sys.exit(4)
sys.exit(0)
PY
then
    pass "5: build_manual_command emits start-colony.sh --restart-agent form (#257)"
else
    fail "5: build_manual_command still emits pre-#257 direct agentis-daemon form"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
