#!/bin/bash
# tools/test-start-colony-per-repo-labels.sh: unit tests for #316 M5a —
# per-repo trigger label memo seeding by start-colony.sh.
#
# M5a extends triage / planning / implementation start-colony.sh memo
# seeding so that when the colony runs against [[forge.github]] array
# entries (REPO_COUNT > 0), each entry that declares an inline
# `labels = { trigger = "..." }` table seeds an `<owner>__<repo>:<colony>:
# labels:trigger` memo. Single-block configs (REPO_COUNT = 0) skip the
# new loop entirely so the legacy unscoped seeds stay byte-identical.
#
# Cases:
#   1. Single-block: only the legacy unscoped memos are seeded; no
#      `<owner>__<repo>:` memo writes happen at all.
#   2. Multi-repo (N=2) with `labels = { trigger = "..." }` per entry:
#      both `<owner>__<repo>:triage:labels:trigger` memos are seeded
#      AND the legacy unscoped seeds still fire.
#   3. Multi-repo (N=2) with `labels` block missing on one entry:
#      the entry without `labels` is silently skipped; the entry with
#      `labels` seeds its memo.
#
# Standard scaffold: set -eu, mktemp -d isolation, EXIT trap for cleanup.
# Auto-discovered by tools/colony-lint.sh's tools-test loop.
#
# Usage: ./tools/test-start-colony-per-repo-labels.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
START_TRIAGE="$REPO_ROOT/dev-apprenticeship/triage/scripts/start-colony.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
cleanup() {
    pkill -f 'fake-daemon-for-test-316m5a' 2>/dev/null || true
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# Shim `agentis` so all `agentis memo set ...` calls land in a log file.
# Each invocation appends one line: `memo set <key> <value>`. Daemon
# launches still execute (rewritten to `sleep`) so the script reaches
# the post-memo-seeding `agentis daemon` arm; the EXIT-trap pkill -f
# marker reaps the strays.
SHIM_DIR="$TMPDIR_TEST/shim"
mkdir -p "$SHIM_DIR"
MEMO_LOG="$TMPDIR_TEST/memo-calls.log"
: > "$MEMO_LOG"
cat > "$SHIM_DIR/agentis" <<SHIM
#!/bin/bash
if [ "\${1:-}" = "memo" ] && [ "\${2:-}" = "set" ]; then
    printf 'memo set %s %s\n' "\${3:-}" "\${4:-}" >> "$MEMO_LOG"
    exit 0
fi
if [ "\${1:-}" = "daemon" ] && [ "\${2:-}" = "list" ]; then
    printf '[]\n'
    exit 0
fi
if [ "\${1:-}" = "daemon" ]; then
    exec -a fake-daemon-for-test-316m5a sleep 2
fi
exit 0
SHIM
chmod +x "$SHIM_DIR/agentis"

# Run start-colony.sh against $1, capturing all memo calls into MEMO_LOG.
# Truncates MEMO_LOG before each call so per-test assertions see only
# the new run's writes. Returns the script's exit code; stdout/stderr
# captured to TMPDIR_TEST/{stdout,stderr} for forensic inspection.
run_start() {
    local config="$1" rc=0
    : > "$MEMO_LOG"
    PATH="$SHIM_DIR:$PATH" timeout 4 bash "$START_TRIAGE" "$config" \
        >"$TMPDIR_TEST/stdout" 2>"$TMPDIR_TEST/stderr" || rc=$?
    pkill -f 'fake-daemon-for-test-316m5a' 2>/dev/null || true
    return $rc
}

memo_count_for_key() {
    grep -c "^memo set $1 " "$MEMO_LOG" 2>/dev/null || true
}

memo_value_for_key() {
    grep "^memo set $1 " "$MEMO_LOG" 2>/dev/null | head -1 | sed -E 's|^memo set [^ ]+ ||'
}

count_per_repo_memos() {
    grep -cE '^memo set [^ ]+__[^ ]+:[^ ]+:' "$MEMO_LOG" 2>/dev/null || true
}

# --- Test 1: single-block legacy regression --------------------------
# A pre-#316 single-block colony.toml with `triage.labels.priority` set
# must seed exactly the legacy `triage:labels:priority` memo and skip
# the per-repo seeding loop entirely (no `<owner>__<repo>:` memo
# writes). Byte-identity for v1.3.0 operators.
CFG1="$TMPDIR_TEST/single.toml"
{
    printf '%s\n' '[forge]'
    printf '%s\n' 'type = "github"'
    printf '%s\n' ''
    printf '%s\n' '[forge.github]'
    printf '%s\n' 'url = "https://api.github.com"'
    printf '%s\n' 'owner = "single-owner"'
    printf '%s\n' 'repo = "single-repo"'
    printf '%s\n' 'token = "single-token"'
    printf '%s\n' 'me = "single-me"'
    printf '%s\n' ''
    printf '%s\n' '[triage.labels]'
    printf '%s\n' 'priority = "P0, P1, P2"'
} > "$CFG1"

# Daemon-launch returns non-zero from sleep timeout; we don't care
# about start-colony.sh's exit code, only the MEMO_LOG contents.
run_start "$CFG1" || true

LEGACY_COUNT="$(memo_count_for_key 'triage:labels:priority')"
LEGACY_VALUE="$(memo_value_for_key 'triage:labels:priority')"
PER_REPO_COUNT="$(count_per_repo_memos)"
if [ "$LEGACY_COUNT" -ge 1 ] \
   && [ "$LEGACY_VALUE" = "P0, P1, P2" ] \
   && [ "$PER_REPO_COUNT" = "0" ]; then
    pass "test 1: single-block seeds only legacy unscoped memo (no per-repo memos)"
else
    fail "test 1: single-block seeds only legacy unscoped memo (no per-repo memos)" \
         "legacy_count=$LEGACY_COUNT legacy_value='$LEGACY_VALUE' per_repo_count=$PER_REPO_COUNT log:$(cat "$MEMO_LOG")"
fi

# --- Test 2: multi-repo N=2 with labels per entry --------------------
# Both `[[forge.github]]` entries declare `labels = { trigger = "..." }`.
# The legacy unscoped seed must still fire (back-compat for vocabulary
# memos) AND each entry must seed its `<owner>__<repo>:triage:labels:
# trigger` memo with the right value.
CFG2="$TMPDIR_TEST/multi-2.toml"
{
    printf '%s\n' '[forge]'
    printf '%s\n' 'type = "github"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "frontend"'
    printf '%s\n' 'token = "x"'
    printf '%s\n' 'me = "acme-me"'
    printf '%s\n' 'labels = { trigger = "needs-frontend-triage" }'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "backend"'
    printf '%s\n' 'token = "y"'
    printf '%s\n' 'me = "acme-me"'
    printf '%s\n' 'labels = { trigger = "needs-backend-triage" }'
    printf '%s\n' ''
    printf '%s\n' '[triage.labels]'
    printf '%s\n' 'priority = "P0, P1, P2"'
} > "$CFG2"

run_start "$CFG2" || true

LEGACY_VALUE2="$(memo_value_for_key 'triage:labels:priority')"
FRONTEND_VALUE="$(memo_value_for_key 'acme__frontend:triage:labels:trigger')"
BACKEND_VALUE="$(memo_value_for_key 'acme__backend:triage:labels:trigger')"
if [ "$LEGACY_VALUE2" = "P0, P1, P2" ] \
   && [ "$FRONTEND_VALUE" = "needs-frontend-triage" ] \
   && [ "$BACKEND_VALUE" = "needs-backend-triage" ]; then
    pass "test 2: multi-repo (N=2) seeds per-repo trigger memos AND legacy unscoped vocabulary"
else
    fail "test 2: multi-repo (N=2) seeds per-repo trigger memos AND legacy unscoped vocabulary" \
         "legacy='$LEGACY_VALUE2' frontend='$FRONTEND_VALUE' backend='$BACKEND_VALUE' log:$(cat "$MEMO_LOG")"
fi

# --- Test 3: multi-repo N=2 with labels missing on one entry ---------
# Only entry [0] declares `labels`. Entry [1] has no `labels` block;
# the per-repo loop must silently skip it (no error, no memo write)
# and still seed the entry-[0] memo.
CFG3="$TMPDIR_TEST/multi-mixed.toml"
{
    printf '%s\n' '[forge]'
    printf '%s\n' 'type = "github"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "with-labels"'
    printf '%s\n' 'token = "x"'
    printf '%s\n' 'labels = { trigger = "labeled-trigger" }'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "without-labels"'
    printf '%s\n' 'token = "y"'
} > "$CFG3"

run_start "$CFG3" || true

LABELED_VALUE="$(memo_value_for_key 'acme__with-labels:triage:labels:trigger')"
UNLABELED_COUNT="$(memo_count_for_key 'acme__without-labels:triage:labels:trigger')"
if [ "$LABELED_VALUE" = "labeled-trigger" ] && [ "$UNLABELED_COUNT" = "0" ]; then
    pass "test 3: missing labels block in entry silently skipped"
else
    fail "test 3: missing labels block in entry silently skipped" \
         "labeled='$LABELED_VALUE' unlabeled_count=$UNLABELED_COUNT log:$(cat "$MEMO_LOG")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
