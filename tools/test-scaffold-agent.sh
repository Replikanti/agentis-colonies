#!/bin/bash
# tools/test-scaffold-agent.sh: unit tests for tools/scaffold-agent.sh (#322).
#
# Validates:
#   Test 1: scaffold canary into a fresh fake colony — file appears at
#           the expected path, content round-trips byte-for-byte.
#   Test 2: re-scaffold same template same target -> exit 1
#           (destination conflict, file untouched).
#   Test 3: re-scaffold with --force -> exit 0, destination overwritten.
#   Test 4: bogus <template> -> exit 2 with "available templates: ..."
#           in stderr listing the canary.
#   Test 5: bogus <federation> -> exit 2.
#   Test 6: bogus <colony> (federation exists, colony absent or missing
#           start-colony.sh) -> exit 2.
#   Test 7: --name <local-name> rename works; destination basename
#           reflects the override, not the template name.
#
# Live-federation safety: every fixture is built under $TMPDIR_TEST
# (mktemp -d). The tests never write to $REPO_ROOT/dev-apprenticeship/.
#
# Usage: ./tools/test-scaffold-agent.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$SCRIPT_DIR/scaffold-agent.sh"
TEMPLATE_FILE="$REPO_ROOT/templates/agents/stale-issue-closer.ag"

if [ ! -x "$TOOL" ]; then
    echo "[FAIL] scaffold-agent.sh missing or not executable: $TOOL" >&2
    exit 1
fi
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "[FAIL] canary template missing: $TEMPLATE_FILE" >&2
    exit 1
fi

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: ${2:-}"; FAIL=$((FAIL + 1)); }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# build_fed_colony <fed_root> <colony_name>
# Builds the minimum colony skeleton scaffold-agent.sh demands:
#   <fed>/<colony>/agents/                — destination dir
#   <fed>/<colony>/scripts/start-colony.sh  — conformance probe target
#   <fed>/<colony>/config/colony.example.toml — for parity with real colonies
build_fed_colony() {
    fed_root="$1"
    colony_name="$2"
    mkdir -p "$fed_root/$colony_name/agents"
    mkdir -p "$fed_root/$colony_name/scripts"
    mkdir -p "$fed_root/$colony_name/config"
    : > "$fed_root/$colony_name/scripts/start-colony.sh"
    chmod +x "$fed_root/$colony_name/scripts/start-colony.sh"
    : > "$fed_root/$colony_name/config/colony.example.toml"
}

FAKE_FED="$TMPDIR_TEST/myfed"
build_fed_colony "$FAKE_FED" "triage"

# ----- Test 1: happy path -----
set +e
OUT="$("$TOOL" stale-issue-closer "$FAKE_FED" triage 2>&1)"; RC=$?
set -e
DEST="$FAKE_FED/triage/agents/stale-issue-closer.ag"
if [ "$RC" -eq 0 ] && [ -f "$DEST" ] && echo "$OUT" | grep -Fq "scaffolded stale-issue-closer -> "; then
    if cmp -s "$TEMPLATE_FILE" "$DEST"; then
        pass "happy path: canary scaffolds + content round-trips"
    else
        fail "happy-path content" "scaffolded file differs from template (the canary has no substitution tokens, so it should be byte-identical)"
    fi
else
    fail "happy path" "rc=$RC, out=$OUT, dest_exists=$( [ -f "$DEST" ] && echo yes || echo no )"
fi

# ----- Test 2: destination conflict -> exit 1 -----
# Mark the existing scaffolded file so we can detect overwrite.
echo "// sentinel-test2" >> "$DEST"
SENTINEL_BEFORE="$(grep -c '^// sentinel-test2$' "$DEST" || true)"
set +e
OUT="$("$TOOL" stale-issue-closer "$FAKE_FED" triage 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -Fq "agent already exists at" && echo "$OUT" | grep -Fq -- "--force to overwrite"; then
    SENTINEL_AFTER="$(grep -c '^// sentinel-test2$' "$DEST" || true)"
    if [ "$SENTINEL_BEFORE" = "$SENTINEL_AFTER" ]; then
        pass "destination conflict: exit 1 + destination untouched"
    else
        fail "destination conflict" "exit 1 but destination was modified (sentinel before=$SENTINEL_BEFORE after=$SENTINEL_AFTER)"
    fi
else
    fail "destination conflict" "rc=$RC, out=$OUT"
fi

# ----- Test 3: --force overwrites -----
set +e
OUT="$("$TOOL" stale-issue-closer "$FAKE_FED" triage --force 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -Fq "scaffolded stale-issue-closer -> "; then
    if grep -Fq "^// sentinel-test2$" "$DEST"; then
        fail "force overwrite" "destination still contains test-2 sentinel — not actually overwritten"
    elif cmp -s "$TEMPLATE_FILE" "$DEST"; then
        pass "--force: overwrite succeeds, destination matches template"
    else
        fail "force overwrite content" "destination differs from template after overwrite"
    fi
else
    fail "--force" "rc=$RC, out=$OUT"
fi

# ----- Test 4: bogus template -> exit 2, lists available -----
set +e
OUT="$("$TOOL" nope-template "$FAKE_FED" triage 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 2 ] && \
   echo "$OUT" | grep -Fq "template not found: nope-template" && \
   echo "$OUT" | grep -Fq "available templates:" && \
   echo "$OUT" | grep -Fq "stale-issue-closer"; then
    pass "bogus template: exit 2 + lists available"
else
    fail "bogus template" "rc=$RC, out=$OUT"
fi

# ----- Test 5: bogus federation -> exit 2 -----
set +e
OUT="$("$TOOL" stale-issue-closer "$TMPDIR_TEST/no-such-fed" triage 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -Fq "federation directory not found"; then
    pass "bogus federation: exit 2"
else
    fail "bogus federation" "rc=$RC, out=$OUT"
fi

# ----- Test 6a: colony absent -> exit 2 -----
set +e
OUT="$("$TOOL" stale-issue-closer "$FAKE_FED" no-such-colony 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -Fq "colony directory not found"; then
    pass "bogus colony (absent): exit 2"
else
    fail "bogus colony (absent)" "rc=$RC, out=$OUT"
fi

# ----- Test 6b: colony present but non-conformant (no start-colony.sh) -> exit 2 -----
NONCONFORMANT="$TMPDIR_TEST/myfed/nonconformant"
mkdir -p "$NONCONFORMANT/agents"
# Note: deliberately no scripts/start-colony.sh and no scripts/ dir.
set +e
OUT="$("$TOOL" stale-issue-closer "$FAKE_FED" nonconformant 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -Fq "start-colony.sh"; then
    pass "non-conformant colony (no start-colony.sh): exit 2"
else
    fail "non-conformant colony" "rc=$RC, out=$OUT"
fi

# ----- Test 6c: colony has scripts/start-colony.sh but no agents/ -> exit 2 -----
NOAGENTS="$TMPDIR_TEST/myfed/no-agents"
mkdir -p "$NOAGENTS/scripts"
: > "$NOAGENTS/scripts/start-colony.sh"
chmod +x "$NOAGENTS/scripts/start-colony.sh"
set +e
OUT="$("$TOOL" stale-issue-closer "$FAKE_FED" no-agents 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -Fq "agents/"; then
    pass "non-conformant colony (no agents/): exit 2"
else
    fail "non-conformant colony (no agents/)" "rc=$RC, out=$OUT"
fi

# ----- Test 7: --name rename -----
build_fed_colony "$FAKE_FED" "rename-target"
set +e
OUT="$("$TOOL" stale-issue-closer "$FAKE_FED" rename-target --name custom_local_name 2>&1)"; RC=$?
set -e
RENAME_DEST="$FAKE_FED/rename-target/agents/custom_local_name.ag"
DEFAULT_DEST="$FAKE_FED/rename-target/agents/stale-issue-closer.ag"
if [ "$RC" -eq 0 ] && [ -f "$RENAME_DEST" ] && [ ! -f "$DEFAULT_DEST" ] && \
   echo "$OUT" | grep -Fq "agents/custom_local_name.ag"; then
    if cmp -s "$TEMPLATE_FILE" "$RENAME_DEST"; then
        pass "--name: destination basename overridden, content matches template"
    else
        fail "rename content" "renamed file differs from template"
    fi
else
    fail "--name rename" "rc=$RC, out=$OUT, rename_exists=$( [ -f "$RENAME_DEST" ] && echo yes || echo no ), default_exists=$( [ -f "$DEFAULT_DEST" ] && echo yes || echo no )"
fi

# ----- Test 8 (bonus): repo-relative federation arg works -----
# scaffold-agent.sh's resolver tries $REPO_ROOT/<arg> first, then absolute.
# Build a federation under REPO_ROOT/.test-scaffold-fed/ and clean it up
# afterward. Live-federation safety: name-spaced via .test- prefix and
# fully removed in the trap; never touches dev-apprenticeship/.
RR_FED="$REPO_ROOT/.test-scaffold-fed"
RR_COLONY="$RR_FED/c0"
trap 'rm -rf "$TMPDIR_TEST" "$RR_FED"' EXIT
mkdir -p "$RR_COLONY/agents" "$RR_COLONY/scripts" "$RR_COLONY/config"
: > "$RR_COLONY/scripts/start-colony.sh"
chmod +x "$RR_COLONY/scripts/start-colony.sh"
set +e
OUT="$("$TOOL" stale-issue-closer .test-scaffold-fed c0 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 0 ] && [ -f "$RR_COLONY/agents/stale-issue-closer.ag" ] && \
   echo "$OUT" | grep -Fq "scaffolded stale-issue-closer -> .test-scaffold-fed/c0/agents/stale-issue-closer.ag"; then
    pass "repo-relative federation arg resolves correctly + stdout uses repo-rel path"
else
    fail "repo-relative federation" "rc=$RC, out=$OUT"
fi

# ----- Summary -----
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
