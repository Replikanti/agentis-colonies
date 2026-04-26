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
#   Test 11: scaffold dependency-updater into a fresh fixture; assert
#            the file lands at the expected path AND passes structural
#            tier-branch checks (a single tier("dependency_updater")
#            call, four canonical-tier branches, end-of-tick
#            memo_write).
#   Test 12: scaffold security-scanner; assert every audit-tool
#            dispatch path is wrapped in `shell_escape(...)` (no raw
#            string concat into `exec sh ...post-note` etc).
#   Test 13: scaffold release-manager; assert the `cb <N>;` header
#            in the rendered file matches the template's value
#            (regression guard against scaffolder substitutions
#            accidentally rewriting the budget).
#
# Live-federation safety: every fixture is built under $TMPDIR_TEST
# (mktemp -d). The tests never write to $REPO_ROOT/dev-apprenticeship/.
#
# Note on lint scope: tests 11-13 do structural grep-based checks rather
# than invoking the full agentis binary lint, since headless `.ag`
# linting against synthetic fixtures would require an `agentis` install
# on every CI runner (the colony-lint.sh `.ag` syntax check skips
# gracefully when the binary is absent — see CLAUDE.md "Validation").
# The structural checks cover the canonical-pattern requirements from
# CLAUDE.md "Agent conventions": one `tier()` call, all-tier dispatch,
# `memo_write("<agent>:last_check", now)` at end of tick, dynamic
# values in `exec sh` wrapped via `shell_escape()`.
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

# ----- Test 11: dependency-updater scaffolds + structural tier-branch check -----
build_fed_colony "$FAKE_FED" "dep-updater-target"
DEP_TEMPLATE="$REPO_ROOT/templates/agents/dependency-updater.ag"
if [ ! -f "$DEP_TEMPLATE" ]; then
    fail "dependency-updater template missing" "expected $DEP_TEMPLATE"
else
    set +e
    OUT="$("$TOOL" dependency-updater "$FAKE_FED" dep-updater-target 2>&1)"; RC=$?
    set -e
    DEP_DEST="$FAKE_FED/dep-updater-target/agents/dependency-updater.ag"
    if [ "$RC" -ne 0 ] || [ ! -f "$DEP_DEST" ]; then
        fail "dependency-updater scaffold" "rc=$RC, out=$OUT, dest_exists=$( [ -f "$DEP_DEST" ] && echo yes || echo no )"
    else
        # Structural tier-branch checks. Group results so we report a
        # single PASS for the whole structural block.
        # shellcheck disable=SC2015 # Each grep is a separate logical
        # check; we want to short-circuit on the first failure with a
        # descriptive message rather than chain &&s into one opaque rc.
        TIER_HITS="$(grep -c 'tier("dependency_updater")' "$DEP_DEST" || true)"
        SHADOW_HIT="$(grep -c '\["observed", "dependency-updater"\]' "$DEP_DEST" || true)"
        PROPOSE_HIT="$(grep -c '\["emitted", "dependency-updater"\]' "$DEP_DEST" || true)"
        REVIEW_HIT="$(grep -c '\["review-gated", "dependency-updater"\]' "$DEP_DEST" || true)"
        ACTED_HIT="$(grep -c '\["acted", "dependency-updater"\]' "$DEP_DEST" || true)"
        MEMO_HIT="$(grep -c 'memo_write("dependency_updater:last_check"' "$DEP_DEST" || true)"
        CB_HIT="$(grep -cE '^cb 100;' "$DEP_DEST" || true)"

        if [ "$TIER_HITS" -lt 1 ]; then
            fail "dependency-updater tier-branch" "no tier(\"dependency_updater\") call found"
        elif [ "$SHADOW_HIT" -lt 1 ] || [ "$PROPOSE_HIT" -lt 1 ] || [ "$REVIEW_HIT" -lt 1 ] || [ "$ACTED_HIT" -lt 1 ]; then
            fail "dependency-updater tier-branch" "missing one of the four canonical-tier learn() tags (shadow=$SHADOW_HIT propose=$PROPOSE_HIT review-gated=$REVIEW_HIT acted=$ACTED_HIT)"
        elif [ "$MEMO_HIT" -lt 1 ]; then
            fail "dependency-updater memo_write" "no memo_write(\"dependency_updater:last_check\", ...) call found"
        elif [ "$CB_HIT" -ne 1 ]; then
            fail "dependency-updater cb header" "expected exactly one 'cb 100;' line, got $CB_HIT"
        else
            pass "dependency-updater scaffolds + tier-branch + memo_write + cb 100 header all present"
        fi
    fi
fi

# ----- Test 12: security-scanner scaffolds + every exec sh wrapped via shell_escape -----
build_fed_colony "$FAKE_FED" "sec-scanner-target"
SEC_TEMPLATE="$REPO_ROOT/templates/agents/security-scanner.ag"
if [ ! -f "$SEC_TEMPLATE" ]; then
    fail "security-scanner template missing" "expected $SEC_TEMPLATE"
else
    set +e
    OUT="$("$TOOL" security-scanner "$FAKE_FED" sec-scanner-target 2>&1)"; RC=$?
    set -e
    SEC_DEST="$FAKE_FED/sec-scanner-target/agents/security-scanner.ag"
    if [ "$RC" -ne 0 ] || [ ! -f "$SEC_DEST" ]; then
        fail "security-scanner scaffold" "rc=$RC, out=$OUT, dest_exists=$( [ -f "$SEC_DEST" ] && echo yes || echo no )"
    else
        # Pull every line that contains both `exec sh` and a `+ ` (the
        # marker for string concat into the shell command) and assert
        # each one references shell_escape on the same line. The handful
        # of `exec sh "$COLONY_DIR/scripts/forge-api.sh ..."` lines that
        # are pure single-string literals do not contain `+` and are
        # therefore not flagged. Lines marked with the
        # `// colony-lint: safe-exec-concat` directive on the previous
        # line are linted manually — we additionally count those to
        # catch a bait-and-switch where the directive is added without
        # an actual shell_escape() call.
        UNSAFE="$( (grep -nE 'exec sh.*\+ ' "$SEC_DEST" | grep -v 'shell_escape(') || : )"
        DIRECTIVES="$(grep -c 'colony-lint: safe-exec-concat' "$SEC_DEST" || true)"
        if [ -n "$UNSAFE" ]; then
            fail "security-scanner shell_escape" "exec sh with string concat lacking shell_escape on at least one line: $UNSAFE"
        elif [ "$DIRECTIVES" -lt 1 ]; then
            # We expect at least one safe-exec-concat directive (the
            # nested concat in the autonomous create-issue path). If the
            # template is later refactored to inline shell_escape on
            # every line, this can drop — but for now its absence is a
            # signal the wrong file was rendered.
            fail "security-scanner shell_escape directives" "expected at least one 'colony-lint: safe-exec-concat' directive in the rendered file"
        else
            pass "security-scanner scaffolds + every exec sh string-concat is shell_escape-wrapped"
        fi
    fi
fi

# ----- Test 13: release-manager scaffolds + cb header matches template -----
build_fed_colony "$FAKE_FED" "release-mgr-target"
REL_TEMPLATE="$REPO_ROOT/templates/agents/release-manager.ag"
if [ ! -f "$REL_TEMPLATE" ]; then
    fail "release-manager template missing" "expected $REL_TEMPLATE"
else
    set +e
    OUT="$("$TOOL" release-manager "$FAKE_FED" release-mgr-target 2>&1)"; RC=$?
    set -e
    REL_DEST="$FAKE_FED/release-mgr-target/agents/release-manager.ag"
    if [ "$RC" -ne 0 ] || [ ! -f "$REL_DEST" ]; then
        fail "release-manager scaffold" "rc=$RC, out=$OUT, dest_exists=$( [ -f "$REL_DEST" ] && echo yes || echo no )"
    else
        # Grep the template for its `cb <N>;` header and compare against
        # the rendered destination — they must match byte-for-byte
        # (the scaffolder MUST NOT rewrite the cb budget).
        TEMPLATE_CB="$(grep -m1 -E '^cb [0-9]+;' "$REL_TEMPLATE" || true)"
        DEST_CB="$(grep -m1 -E '^cb [0-9]+;' "$REL_DEST" || true)"
        if [ -z "$TEMPLATE_CB" ]; then
            fail "release-manager cb header" "template has no cb <N>; line"
        elif [ "$TEMPLATE_CB" != "$DEST_CB" ]; then
            fail "release-manager cb header" "template cb='$TEMPLATE_CB' but rendered cb='$DEST_CB' — scaffolder is rewriting the budget"
        elif [ "$TEMPLATE_CB" != "cb 150;" ]; then
            # Belt-and-braces: the template's cb value is what the
            # PR-2 plan committed to (cb 150 for release-manager).
            # If a future PR retunes the budget, update this string.
            fail "release-manager cb header" "expected 'cb 150;' (per #322 PR2 plan), got '$TEMPLATE_CB'"
        else
            pass "release-manager scaffolds + cb header round-trips byte-for-byte ($TEMPLATE_CB)"
        fi
    fi
fi

# ----- Summary -----
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
