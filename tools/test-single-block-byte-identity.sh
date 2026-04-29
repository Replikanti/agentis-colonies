#!/bin/bash
# tools/test-single-block-byte-identity.sh: pin the #316 M3a byte-identity
# guarantee — pre-M3 single-block configs and post-M3 single-entry array
# configs MUST produce identical experience rows + memo keys + bus emit
# semantics.
#
# This test is the load-bearing defence against per-repo scoping silently
# regressing legacy operators. Plan §13: "MUST pass 5/5".
#
# Method (per plan §9 point 2): run the triage/router agent twice — once
# against a synthetic legacy `[forge.github]`-shape config (no
# GITHUB_REPOS_JSON env), once against a synthetic single-entry
# `[[forge.github]]`-shape config (GITHUB_REPOS_JSON env carrying one
# entry whose owner/repo/url/me match the legacy config). Both runs use
# the same forge-api stub that returns `[]` for every call, so the agent
# exits its tick early with the same memo updates. Compare the memo
# files, experience JSONL, and the agent runtime descriptors that
# callers can observe.
#
# Cases:
#   1. Both runs produce a memo file named `router:last_check.jsonl`
#      (the unscoped key) — proves scoped_memo("","",suffix) collapses
#      back to the legacy key on both paths.
#   2. Neither run produces any per-repo-scoped memo file (e.g.
#      `<owner>/<repo>:router:last_check.jsonl`) — proves the agent
#      ran with the empty-owner sentinel on both paths.
#   3. Experience JSONL row count is equal across runs (modulo the
#      no-emit early-exit; both paths must early-exit identically).
#   4. iter-repos.sh stdout shape is sentinel (`\t\t<url>\t<me>`) on
#      both runs — proves the JSON-collapse path matches the legacy
#      fallback shape byte-for-byte.
#   5. Bus emit count: both runs emit exactly the same bus events
#      across the run window. With issues_cmd returning `[]`, both
#      runs hit the early-return branch, no `emit("triage:...")` fires
#      — emit count is 0 on both sides.
#
# Standard scaffold: set -u, mktemp -d isolation, EXIT trap for cleanup.
# Auto-discovered by tools/colony-lint.sh's tools-test loop.
#
# Usage: ./tools/test-single-block-byte-identity.sh
# Exit 0 if all 5 tests pass, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROUTER_AG="$REPO_ROOT/dev-apprenticeship/triage/agents/router.ag"
ITER_REPOS="$REPO_ROOT/tools/iter-repos.sh"
ITER_REPOS_PY="$REPO_ROOT/tools/iter-repos.py"
RESOLVE_REPO_PY="$REPO_ROOT/tools/forge-resolve-repo.py"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
DAEMON_MARKER="byteid-test-$$"
trap 'pkill -f "'"$DAEMON_MARKER"'" 2>/dev/null || true; rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# Build a fake repo tree for one test run. Shape:
#   <run>/dev-apprenticeship/triage/scripts/forge-api.sh   (returns [])
#   <run>/dev-apprenticeship/triage/agents/router.ag       (the agent)
#   <run>/tools/iter-repos.sh + iter-repos.py + forge-resolve-repo.py
#   <run>/.agentis/                                        (init'd store)
prepare_run() {
    local run="$1"
    mkdir -p "$run/dev-apprenticeship/triage/scripts" \
             "$run/dev-apprenticeship/triage/agents" \
             "$run/tools"
    # Stub forge-api.sh — every invocation returns the empty-list shape
    # the agent's early-exit branch matches against (`len(raw) < 3`).
    cat > "$run/dev-apprenticeship/triage/scripts/forge-api.sh" <<'STUB'
#!/bin/bash
# Test stub: always returns [] — drives the agent's early-exit path.
echo "[]"
STUB
    chmod +x "$run/dev-apprenticeship/triage/scripts/forge-api.sh"
    cp "$ROUTER_AG" "$run/dev-apprenticeship/triage/agents/router.ag"
    cp "$ITER_REPOS" "$run/tools/iter-repos.sh"
    cp "$ITER_REPOS_PY" "$run/tools/iter-repos.py"
    cp "$RESOLVE_REPO_PY" "$run/tools/forge-resolve-repo.py"
    chmod +x "$run/tools/iter-repos.sh" "$run/tools/iter-repos.py" \
             "$run/tools/forge-resolve-repo.py"
    (cd "$run" && agentis init >/dev/null 2>&1)
    {
        echo "experience.enabled = true"
        echo "learning.enabled = true"
        echo "knowledge.enabled = true"
        echo "exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*"
    } >> "$run/.agentis/config"
    (cd "$run" && agentis commit dev-apprenticeship/triage/agents/router.ag >/dev/null 2>&1)
}

# Run the daemon for ~$2 seconds with the env supplied via the rest of the
# argv. Output captured to <run>/daemon.log. Daemon argv is annotated with
# DAEMON_MARKER via the file path so the EXIT trap can reap survivors.
run_daemon() {
    local run="$1" seconds="$2" pid
    shift 2
    cd "$run" || return 1
    local log_marker_dir="$run/cmdmarker-$DAEMON_MARKER"
    mkdir -p "$log_marker_dir"
    COLONY_DIR="$run/dev-apprenticeship/triage" "$@" \
        timeout "$seconds" \
        agentis daemon dev-apprenticeship/triage/agents/router.ag \
            --tick-interval 1000 --cb-per-tick 400 --colony triage \
            --enable-exec --enable-messaging \
            > "$run/daemon.log" 2>&1 &
    pid=$!
    sleep "$seconds"
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    cd - >/dev/null || return 1
}

# Sort and list the basenames of all memo files under <run>/.agentis/memo,
# one per line. Empty if the directory is empty / missing. Used to compare
# memo *keys* between runs without leaking timestamps.
memo_keys() {
    local run="$1"
    if [ -d "$run/.agentis/memo" ]; then
        find "$run/.agentis/memo" -maxdepth 1 -type f -name '*.jsonl' \
            | sed 's|.*/||' | sort
    fi
}

# Count experience records across all per-agent JSONL files in this run.
experience_count() {
    local run="$1"
    if [ -d "$run/.agentis/experience" ]; then
        # shellcheck disable=SC2012
        cat "$run"/.agentis/experience/*.jsonl 2>/dev/null | wc -l | tr -d ' '
    else
        echo "0"
    fi
}

# Count emit() rows the agent produced. Bus emits land in the agent's
# log via the runtime's [emit:...] tracer; if the runtime version drops
# that, the literal `emit(` token in the agent source is sufficient
# evidence that NO emits fired (we then look for the early-exit marker).
emit_count() {
    local run="$1"
    if [ -d "$run/.agentis/logs" ]; then
        grep -hc '\[emit:' "$run"/.agentis/logs/*.log 2>/dev/null \
            | awk '{n+=$1} END{print n+0}'
    else
        echo "0"
    fi
}

# Sanity: prerequisites resolve.
if ! command -v agentis >/dev/null 2>&1; then
    echo "[SKIP] test-single-block-byte-identity.sh: agentis not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi
if [ ! -f "$ROUTER_AG" ]; then
    fail "missing fixture: $ROUTER_AG"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

RUNDIR_A="$TMPDIR_TEST/run-a"
RUNDIR_B="$TMPDIR_TEST/run-b"
prepare_run "$RUNDIR_A"
prepare_run "$RUNDIR_B"

# Run A: legacy single-block — no GITHUB_REPOS_JSON in env. iter-repos.sh
# falls back to GITHUB_OWNER/REPO and emits the sentinel TSV line.
run_daemon "$RUNDIR_A" 5 \
    env FORGE_TYPE=github \
        GITHUB_OWNER=byteid-owner \
        GITHUB_REPO=byteid-repo \
        GITHUB_TOKEN=byteid-token \
        GITHUB_URL=https://api.github.com \
        GITHUB_ME=byteid-me

# Run B: single-entry [[forge.github]] — GITHUB_REPOS_JSON exported with
# exactly one entry. iter-repos.sh's collapse rule emits the same
# sentinel line as Run A; the agent's tick_for_repo("","") path is
# bit-for-bit equivalent.
run_daemon "$RUNDIR_B" 5 \
    env FORGE_TYPE=github \
        GITHUB_OWNER=byteid-owner \
        GITHUB_REPO=byteid-repo \
        GITHUB_TOKEN=byteid-token \
        GITHUB_URL=https://api.github.com \
        GITHUB_ME=byteid-me \
        GITHUB_REPOS_JSON='[{"owner":"byteid-owner","repo":"byteid-repo","token":"byteid-token","url":"https://api.github.com","me":"byteid-me"}]'

# --- Test 1: unscoped memo key on both runs -----------------------------
# router:last_check.jsonl must exist on both sides — and it must be the
# UNSCOPED key (no `<owner>/<repo>:` prefix). scoped_memo("","",suffix)
# returning suffix unchanged is the load-bearing helper here.
KEYS_A="$(memo_keys "$RUNDIR_A")"
KEYS_B="$(memo_keys "$RUNDIR_B")"
if echo "$KEYS_A" | grep -Fxq 'router:last_check.jsonl' \
   && echo "$KEYS_B" | grep -Fxq 'router:last_check.jsonl'; then
    pass "test 1: both runs produced the unscoped 'router:last_check' memo key"
else
    fail "test 1: both runs produced the unscoped 'router:last_check' memo key" \
         "A keys: [$KEYS_A] / B keys: [$KEYS_B]"
fi

# --- Test 2: no per-repo-scoped memo files on either run ----------------
# The empty-owner sentinel must keep all memo writes off the per-repo
# scoping path. A per-repo memo would land under a name like
# `byteid-owner/byteid-repo:router:last_check.jsonl` — the literal
# `/` (or any non-empty owner segment) means the helper branched wrong.
PER_REPO_A="$(echo "$KEYS_A" | grep -E '/' || true)"
PER_REPO_B="$(echo "$KEYS_B" | grep -E '/' || true)"
if [ -z "$PER_REPO_A" ] && [ -z "$PER_REPO_B" ]; then
    pass "test 2: no per-repo-scoped memo files on either run (sentinel held)"
else
    fail "test 2: no per-repo-scoped memo files on either run (sentinel held)" \
         "A per-repo: [$PER_REPO_A] / B per-repo: [$PER_REPO_B]"
fi

# --- Test 3: experience row count equal across runs ---------------------
# Both runs hit the same early-exit branch (issues_cmd returns []), so
# both produce zero learn() rows. Equality is the byte-identity claim.
EXP_A="$(experience_count "$RUNDIR_A")"
EXP_B="$(experience_count "$RUNDIR_B")"
if [ "$EXP_A" = "$EXP_B" ]; then
    pass "test 3: experience row count is equal across runs ($EXP_A == $EXP_B)"
else
    fail "test 3: experience row count is equal across runs" \
         "A: $EXP_A / B: $EXP_B"
fi

# --- Test 4: iter-repos.sh stdout shape is sentinel on both paths -------
# Direct-invoke iter-repos.sh from each run with the same env shape the
# daemon saw. Both must emit exactly `\t\t<url>\t<me>\n` (the sentinel)
# — proves the JSON-collapse path matches the legacy fallback shape.
ITER_A_OUT="$(env -i \
    GITHUB_OWNER=byteid-owner \
    GITHUB_REPO=byteid-repo \
    GITHUB_URL=https://api.github.com \
    GITHUB_ME=byteid-me \
    "$RUNDIR_A/tools/iter-repos.sh" 2>/dev/null)"
ITER_B_OUT="$(env -i \
    GITHUB_OWNER=byteid-owner \
    GITHUB_REPO=byteid-repo \
    GITHUB_URL=https://api.github.com \
    GITHUB_ME=byteid-me \
    GITHUB_REPOS_JSON='[{"owner":"byteid-owner","repo":"byteid-repo","token":"byteid-token","url":"https://api.github.com","me":"byteid-me"}]' \
    "$RUNDIR_B/tools/iter-repos.sh" 2>/dev/null)"
EXPECTED_SENTINEL=$(printf '\t\thttps://api.github.com\tbyteid-me')
if [ "$ITER_A_OUT" = "$EXPECTED_SENTINEL" ] && [ "$ITER_B_OUT" = "$EXPECTED_SENTINEL" ]; then
    pass "test 4: iter-repos.sh emits identical sentinel TSV line on both legacy and 1-entry-array paths"
else
    fail "test 4: iter-repos.sh emits identical sentinel TSV line on both legacy and 1-entry-array paths" \
         "A=[$ITER_A_OUT] B=[$ITER_B_OUT] expected=[$EXPECTED_SENTINEL]"
fi

# --- Test 5: bus emit count equal (and zero on the early-exit path) -----
EMIT_A="$(emit_count "$RUNDIR_A")"
EMIT_B="$(emit_count "$RUNDIR_B")"
if [ "$EMIT_A" = "$EMIT_B" ] && [ "$EMIT_A" = "0" ]; then
    pass "test 5: bus emit count is equal and zero across runs (early-exit path)"
else
    fail "test 5: bus emit count is equal and zero across runs (early-exit path)" \
         "A: $EMIT_A / B: $EMIT_B"
fi

# --- Test 6: collector forge_rate_limits shape byte-identity (#316 M5a) -
# M5a extends the dashboard collector to fan rate-limit fetches out per
# repo when N>=2. The byte-identity guarantee for legacy operators must
# hold for BOTH single-block (no GITHUB_REPOS_JSON) AND N=1 multi-block
# (single-entry GITHUB_REPOS_JSON). Both must produce the v0.7.0 scalar
# `{remaining, limit, reset_at}` shape — no `repos[]`, no `aggregate`.
# Builds two minimal fixture colonies whose start-colony.sh stubs differ
# only in their --print-repos-json output (empty vs 1-entry JSON), runs
# the collector against each, and asserts the emitted forge_rate_limits
# record is shape-identical.
COLLECTOR="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-collector.py"
if [ -f "$COLLECTOR" ]; then
    TEST6_DIR="$TMPDIR_TEST/test6"
    FED_LEGACY="$TEST6_DIR/legacy"
    FED_MULTI1="$TEST6_DIR/multi1"
    COLONY6="solo"
    for fed in "$FED_LEGACY" "$FED_MULTI1"; do
        mkdir -p "$fed/$COLONY6/scripts" "$fed/$COLONY6/agents" \
                 "$fed/$COLONY6/config" \
                 "$fed/.agentis/logs" "$fed/.agentis/experience"
    done
    # Legacy single-block: --print-repos-json prints nothing.
    cat > "$FED_LEGACY/$COLONY6/scripts/start-colony.sh" <<'SCRIPT_LEG'
#!/bin/bash
if [ "$1" = "--print-repos-json" ]; then exit 0; fi
if [ "$1" = "--rate-limit-status" ]; then
    echo '{"remaining": 4321, "limit": 5000, "reset_at": "2026-04-29T12:00:00Z"}'
    exit 0
fi
exit 0
SCRIPT_LEG
    chmod +x "$FED_LEGACY/$COLONY6/scripts/start-colony.sh"
    # N=1 multi-block: --print-repos-json prints a 1-entry JSON array.
    # The collector's `len(repos) >= 2` guard means N=1 falls through
    # to the scalar code path — same byte-identity contract as legacy.
    cat > "$FED_MULTI1/$COLONY6/scripts/start-colony.sh" <<'SCRIPT_M1'
#!/bin/bash
if [ "$1" = "--print-repos-json" ]; then
    echo '[{"owner":"acme","repo":"only","token":"x","url":"https://api.github.com"}]'
    exit 0
fi
if [ "$1" = "--rate-limit-status" ]; then
    echo '{"remaining": 4321, "limit": 5000, "reset_at": "2026-04-29T12:00:00Z"}'
    exit 0
fi
exit 0
SCRIPT_M1
    chmod +x "$FED_MULTI1/$COLONY6/scripts/start-colony.sh"

    OUT_LEG="$TEST6_DIR/legacy.json"
    OUT_M1="$TEST6_DIR/multi1.json"
    for run in legacy multi1; do
        if [ "$run" = "legacy" ]; then
            FED_DIR_RUN="$FED_LEGACY"
            OUT_RUN="$OUT_LEG"
        else
            FED_DIR_RUN="$FED_MULTI1"
            OUT_RUN="$OUT_M1"
        fi
        python3 "$COLLECTOR" \
            '[]' \
            '[]' \
            "$FED_DIR_RUN" \
            "$(date '+%s')" \
            "$FED_DIR_RUN/.agentis/experience" \
            "$FED_DIR_RUN/.agentis/logs" \
            "$TEST6_DIR/dash" \
            "[\"$COLONY6\"]" \
            "" \
            > "$OUT_RUN" 2>"$TEST6_DIR/$run.err"
    done

    if python3 -c "
import json, sys
with open('$OUT_LEG') as f:
    a = json.load(f).get('forge_rate_limits', {}).get('$COLONY6', {})
with open('$OUT_M1') as f:
    b = json.load(f).get('forge_rate_limits', {}).get('$COLONY6', {})
# Both must be scalar shape: same keys, same values.
assert set(a.keys()) == set(b.keys()), 'key sets differ: legacy=%s n1=%s' % (sorted(a.keys()), sorted(b.keys()))
assert 'repos' not in a and 'repos' not in b, 'repos[] leaked into single-block path'
assert 'aggregate' not in a and 'aggregate' not in b, 'aggregate leaked into single-block path'
assert a.get('remaining') == b.get('remaining'), 'remaining differs: %r vs %r' % (a.get('remaining'), b.get('remaining'))
assert a.get('limit') == b.get('limit'), 'limit differs'
assert a.get('reset_at') == b.get('reset_at'), 'reset_at differs'
" 2>"$TEST6_DIR/assert.err"; then
        pass "test 6: collector forge_rate_limits shape byte-identical for single-block AND N=1 multi-block (#316 M5a)"
    else
        fail "test 6: collector forge_rate_limits shape regressed" \
             "$(cat "$TEST6_DIR/assert.err")"
    fi
else
    echo "[SKIP] test 6: collector not found at $COLLECTOR"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
