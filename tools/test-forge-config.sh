#!/bin/bash
# tools/test-forge-config.sh: verify the #256 forge-abstraction end state.
#
# #256 PR 1 (foundation) adds:
#  - [forge] section (with type, [forge.gitlab], commented [forge.github]) to
#    every colony.example.toml
#  - per-colony scripts/forge-api.sh dispatcher that reads $FORGE_TYPE
#  - start-colony.sh exports FORGE_TYPE from [forge].type (default "gitlab")
# #256 PRs 2-6 ship the per-colony github-api.sh wrappers.
# #256 PR 7 (MAJOR, v1.0.0) retires the legacy top-level [gitlab] section.
#
# This test locks the full post-#256 contract in place.
#
# Usage: ./tools/test-forge-config.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"

# Test 5 swaps each colony's real gitlab-api.sh with a printf shim so
# the dispatcher-forwarding assertion does not require a real GitLab.
# We *must* restore the originals no matter how this script exits —
# a Ctrl+C / OOM / set -e abort that leaves the shim in place turns
# every colony's committed gitlab-api.sh into a 3-line stub. Track the
# backup pairs in an array and restore in the EXIT trap.
declare -a SHIMMED_REALS=()
declare -a SHIMMED_BACKUPS=()
restore_shims() {
    local i
    for i in "${!SHIMMED_REALS[@]}"; do
        local real="${SHIMMED_REALS[$i]}"
        local backup="${SHIMMED_BACKUPS[$i]}"
        if [ -f "$backup" ] && [ -f "$real" ]; then
            cp -f "$backup" "$real" 2>/dev/null || true
            chmod +x "$real" 2>/dev/null || true
        fi
    done
}
trap 'restore_shims; rm -rf "$TMPDIR_TEST"' EXIT INT TERM

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

COLONIES="triage planning implementation code-review release"

# -----------------------------------------------------------------------------
# Test 1: every colony.example.toml has [forge] with type = "gitlab" default
# -----------------------------------------------------------------------------
for colony in $COLONIES; do
    cfg="$REPO_ROOT/dev-apprenticeship/$colony/config/colony.example.toml"
    if [ ! -f "$cfg" ]; then
        fail "$colony: colony.example.toml missing"
        continue
    fi
    if ! grep -qE '^\[forge\]$' "$cfg"; then
        fail "$colony: [forge] section missing from colony.example.toml"
        continue
    fi
    if ! grep -qE '^type = "gitlab"$' "$cfg"; then
        fail "$colony: [forge].type must default to \"gitlab\""
        continue
    fi
    if ! grep -qE '^\[forge\.gitlab\]$' "$cfg"; then
        fail "$colony: [forge.gitlab] block missing"
        continue
    fi
    if ! grep -qE '^# \[\[forge\.github\]\]$' "$cfg"; then
        fail "$colony: commented-out [[forge.github]] array-of-tables block missing (operators need a template to uncomment; #316 M6 retired the single-table form)"
        continue
    fi
    pass "$colony: [forge] + [forge.gitlab] + commented [[forge.github]] present in colony.example.toml"
done

# -----------------------------------------------------------------------------
# Test 2: dispatcher exists, is executable, forwards to gitlab-api.sh by default
# -----------------------------------------------------------------------------
for colony in $COLONIES; do
    disp="$REPO_ROOT/dev-apprenticeship/$colony/scripts/forge-api.sh"
    if [ ! -x "$disp" ]; then
        fail "$colony: forge-api.sh missing or not executable" "$disp"
        continue
    fi
    if ! grep -q 'FORGE_TYPE=' "$disp"; then
        fail "$colony: forge-api.sh does not reference FORGE_TYPE"
        continue
    fi
    # Single-quoted pattern is intentional — we want to match the literal
    # text `case "$FORGE_TYPE"` inside the dispatcher, not shell-expand it.
    # shellcheck disable=SC2016
    if ! grep -qF 'case "$FORGE_TYPE"' "$disp"; then
        fail "$colony: forge-api.sh missing FORGE_TYPE case dispatch"
        continue
    fi
    if ! grep -q 'gitlab-api.sh' "$disp"; then
        fail "$colony: forge-api.sh does not reference gitlab-api.sh backend"
        continue
    fi
    if ! grep -q 'github-api.sh' "$disp"; then
        fail "$colony: forge-api.sh does not reference github-api.sh backend (needed for #256 PRs 2-6)"
        continue
    fi
    pass "$colony: forge-api.sh dispatcher present and references both backends"
done

# -----------------------------------------------------------------------------
# Test 3: dispatcher behaviour under FORGE_TYPE=github
# -----------------------------------------------------------------------------
# Two cases per colony, decided by whether github-api.sh has shipped:
#   (a) skeleton state (no github-api.sh yet): exit 99 + ADR + issue pointers
#       — same contract as when PR 1 landed
#   (b) shipped (github-api.sh present): dispatcher execs the wrapper, which
#       fails at its own env-check with rc=1 because GITHUB_TOKEN et al. are
#       not set in the test shell. Assert that rc=1 and the error message
#       names the three required env vars — proves routing works and surfaces
#       an actionable message to operators who forgot to configure
#       [forge.github].
# This keeps the test stable as PRs 2-6 of #256 land additional wrappers.
for colony in $COLONIES; do
    disp="$REPO_ROOT/dev-apprenticeship/$colony/scripts/forge-api.sh"
    gh_backend="$REPO_ROOT/dev-apprenticeship/$colony/scripts/github-api.sh"
    out="$TMPDIR_TEST/$colony.github.log"
    set +e
    # Scrub any inherited GITHUB_* env so the shipped-backend branch can
    # deterministically trip the env-check in github-api.sh regardless of
    # whether the operator's shell already has a PAT exported. FORGE_TYPE
    # still takes effect (case arm below sets it explicitly).
    unset GITHUB_TOKEN GITHUB_OWNER GITHUB_REPO GITHUB_URL GITHUB_ME 2>/dev/null || true
    FORGE_TYPE=github bash "$disp" any-command >"$out" 2>&1
    rc=$?
    set -e
    if [ -x "$gh_backend" ]; then
        # Case (b): backend shipped. Dispatcher should exec it; the wrapper
        # itself should fail at env-check with exit 1 naming the required vars.
        if [ "$rc" = "1" ] && grep -q "GITHUB_TOKEN" "$out" && grep -q "GITHUB_OWNER" "$out" && grep -q "GITHUB_REPO" "$out"; then
            pass "$colony: FORGE_TYPE=github routes to github-api.sh (env-check fires with clear message)"
        else
            fail "$colony: FORGE_TYPE=github routing to github-api.sh broken" "rc=$rc body=$(head -c 300 "$out")"
        fi
    else
        # Case (a): skeleton state. Dispatcher itself surfaces the ADR pointer
        # and exits 99.
        if [ "$rc" = "99" ] \
           && grep -q "not yet implemented" "$out" \
           && grep -q "ADR-0002" "$out" \
           && grep -q "issues/256" "$out"; then
            pass "$colony: FORGE_TYPE=github returns exit 99 with ADR + issue pointers (skeleton)"
        else
            fail "$colony: FORGE_TYPE=github should exit 99 with clear message + ADR + issue pointers" "rc=$rc body=$(head -c 300 "$out")"
        fi
    fi
done

# -----------------------------------------------------------------------------
# Test 4: dispatcher returns exit 2 for unknown FORGE_TYPE
# -----------------------------------------------------------------------------
for colony in $COLONIES; do
    disp="$REPO_ROOT/dev-apprenticeship/$colony/scripts/forge-api.sh"
    out="$TMPDIR_TEST/$colony.unknown.log"
    set +e
    FORGE_TYPE=bogus bash "$disp" any-command >"$out" 2>&1
    rc=$?
    set -e
    if [ "$rc" = "2" ] && grep -q "unknown FORGE_TYPE" "$out"; then
        pass "$colony: unknown FORGE_TYPE returns exit 2 with clear message"
    else
        fail "$colony: unknown FORGE_TYPE should exit 2 with clear message" "rc=$rc body=$(head -c 200 "$out")"
    fi
done

# -----------------------------------------------------------------------------
# Test 5: dispatcher forwards to gitlab-api.sh with argv preserved
# -----------------------------------------------------------------------------
# Shim gitlab-api.sh via PATH isn't enough because forge-api.sh resolves it
# from $SCRIPT_DIR, not PATH. Instead we shim by copying a stub over each
# colony's real gitlab-api.sh for the duration of the test. Backups are
# tracked in SHIMMED_REALS/SHIMMED_BACKUPS so the EXIT trap restores the
# originals even on Ctrl+C / set -e abort (otherwise a fatal mid-loop leaves
# the repo with stubs in place of the committed gitlab-api.sh files).
for colony in $COLONIES; do
    sd="$REPO_ROOT/dev-apprenticeship/$colony/scripts"
    real="$sd/gitlab-api.sh"
    if [ ! -f "$real" ]; then
        fail "$colony: gitlab-api.sh missing in scripts/" "$real"
        continue
    fi
    backup="$TMPDIR_TEST/gitlab-api.sh.$colony.bak"
    cp "$real" "$backup"
    # Register for trap-based restore BEFORE writing the shim so a crash
    # between cp+register and the shim install still restores correctly.
    SHIMMED_REALS+=("$real")
    SHIMMED_BACKUPS+=("$backup")
    cat > "$real" <<'SHIM'
#!/bin/bash
printf 'gitlab-shim argv=%s\n' "$*"
exit 77
SHIM
    chmod +x "$real"

    out="$TMPDIR_TEST/$colony.forward.log"
    set +e
    FORGE_TYPE=gitlab bash "$sd/forge-api.sh" first-arg --flag value >"$out" 2>&1
    rc=$?
    set -e

    # Synchronous restore (in addition to the EXIT trap) so subsequent
    # tests see the real gitlab-api.sh rather than the shim.
    cp "$backup" "$real"
    chmod +x "$real"

    if [ "$rc" = "77" ] && grep -q 'gitlab-shim argv=first-arg --flag value' "$out"; then
        pass "$colony: FORGE_TYPE=gitlab forwards argv verbatim to gitlab-api.sh"
    else
        fail "$colony: dispatch to gitlab-api.sh broken" "rc=$rc body=$(head -c 200 "$out")"
    fi
done

# -----------------------------------------------------------------------------
# Test 6: start-colony.sh exports FORGE_TYPE with default "gitlab"
# -----------------------------------------------------------------------------
for colony in $COLONIES; do
    start="$REPO_ROOT/dev-apprenticeship/$colony/scripts/start-colony.sh"
    # Single-quoted patterns are intentional — we want to match literal
    # `$(...)` and `${...}` shell syntax in the target script, not
    # shell-expand them here.
    # shellcheck disable=SC2016
    if ! grep -qF 'FORGE_TYPE=$(parse_toml forge type)' "$start"; then
        fail "$colony: start-colony.sh does not parse [forge].type via parse_toml"
        continue
    fi
    # shellcheck disable=SC2016
    if ! grep -qF 'FORGE_TYPE="${FORGE_TYPE:-gitlab}"' "$start"; then
        fail "$colony: start-colony.sh does not default FORGE_TYPE to \"gitlab\""
        continue
    fi
    if ! grep -qE '^export FORGE_TYPE$' "$start"; then
        fail "$colony: start-colony.sh does not export FORGE_TYPE"
        continue
    fi
    pass "$colony: start-colony.sh parses + defaults + exports FORGE_TYPE"
done

# -----------------------------------------------------------------------------
# Test 7: install.sh forge-choice prompt + FEDERATION_FORGE_TYPE env short-circuit
# -----------------------------------------------------------------------------
install="$REPO_ROOT/dev-apprenticeship/install.sh"
if ! grep -q 'FEDERATION_FORGE_TYPE' "$install"; then
    fail "install.sh: FEDERATION_FORGE_TYPE env short-circuit missing"
else
    pass "install.sh: FEDERATION_FORGE_TYPE env short-circuit present"
fi
if ! grep -q 'Forge backend' "$install"; then
    fail "install.sh: 'Forge backend' prompt section missing"
else
    pass "install.sh: interactive forge-choice prompt present"
fi
# The [forge].type rewrite must run UNCONDITIONALLY (outside the WRITE_CREDS
# branch) — otherwise an operator re-running install.sh purely to switch
# forge (or answering "n" to the credential-update prompt) never has their
# selection persisted. We assert this by pattern-matching the section
# header that introduces the unconditional rewrite.
if ! grep -q 'Setting \[forge\].type = ' "$install"; then
    fail "install.sh: unconditional [forge].type rewrite missing — forge selection would not persist when WRITE_CREDS=0"
else
    pass "install.sh: unconditional [forge].type rewrite present"
fi
# The FEDERATION_FORGE_TYPE short-circuit must skip the credential-update
# prompt when configs already exist. Pattern-match the short-circuit comment.
if ! grep -q 'FEDERATION_FORGE_TYPE set and configs exist' "$install"; then
    fail "install.sh: FEDERATION_FORGE_TYPE does not short-circuit the credential-update prompt for existing configs"
else
    pass "install.sh: FEDERATION_FORGE_TYPE short-circuits the credential-update prompt"
fi
# #256 PR 7 (v1.0.0): the legacy GitHub-confirm abort gate ("Continue with
# GitHub scaffolding anyway?" + "Aborting install. Re-run and select GitLab")
# was removed when the per-colony github-api.sh wrappers landed — both
# backends are first-class. Assert the gate stays gone.
if grep -q 'Continue with GitHub scaffolding' "$install"; then
    fail "install.sh: legacy GitHub-confirm abort gate is still present (must be removed in #256 PR 7)"
else
    pass "install.sh: legacy GitHub-confirm abort gate removed"
fi
if grep -q 'Aborting install. Re-run and select GitLab' "$install"; then
    fail "install.sh: legacy 'Re-run and select GitLab' abort message still present (must be removed in #256 PR 7)"
else
    pass "install.sh: legacy abort-to-GitLab message removed"
fi
# #256 PR 7 (v1.0.0): install.sh must prompt for GitHub credentials when
# FORGE_TYPE=github, and must NOT write to the retired top-level [gitlab]
# section. Pattern-match the conditional branches and the cred_sections set.
if ! grep -q 'FORGE_TYPE" = "github"' "$install"; then
    fail "install.sh: FORGE_TYPE=github credential branch missing"
else
    pass "install.sh: FORGE_TYPE=github credential branch present"
fi
if ! grep -qE "cred_sections = \\{'forge\\.gitlab'\\}" "$install"; then
    fail "install.sh: legacy [gitlab] still in cred_sections set (must be removed in PR 7)"
else
    pass "install.sh: cred_sections writes to [forge.gitlab] only (legacy [gitlab] retired)"
fi
# -----------------------------------------------------------------------------
# Test 7b: colony.example.toml must NOT carry a top-level [gitlab] section
# -----------------------------------------------------------------------------
for colony in $COLONIES; do
    cfg="$REPO_ROOT/dev-apprenticeship/$colony/config/colony.example.toml"
    if grep -qE '^\[gitlab\]$' "$cfg"; then
        fail "$colony: legacy top-level [gitlab] section still present in colony.example.toml (retired in #256 PR 7)"
    else
        pass "$colony: legacy [gitlab] section absent from colony.example.toml"
    fi
done

# -----------------------------------------------------------------------------
# Test 8: ADR-0002 exists and is indexed
# -----------------------------------------------------------------------------
adr="$REPO_ROOT/doc/adr/ADR-0002-forge-abstraction.md"
if [ ! -f "$adr" ]; then
    fail "ADR-0002 missing at $adr"
else
    pass "ADR-0002 present"
fi
if ! grep -q 'ADR-0002-forge-abstraction.md' "$REPO_ROOT/doc/adr/README.md"; then
    fail "ADR-0002 not indexed in doc/adr/README.md"
else
    pass "ADR-0002 indexed in doc/adr/README.md"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
