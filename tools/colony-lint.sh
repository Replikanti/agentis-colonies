#!/usr/bin/env bash
# colony-lint.sh: validates colony structure, config, and scripts
#
# Autodiscovers federations and colonies in the repo.
# Exit code 0 = all checks pass, 1 = one or more failures, 2 = unmet prerequisites.
#
# Usage: ./tools/colony-lint.sh [path-to-repo-root]
#
# Runs on bash 3.2+ (stock macOS /bin/bash) and bash 4+. Avoid bash-4-only
# constructs below (associative arrays, ${var^^}, mapfile, backslash-newline
# inside case-pattern labels — see #121 for that last one).

set -euo pipefail

# #272: Re-entrancy marker. Test 4 of `tools/test-colony-lint-bash32.sh`
# (added in this PR) runs the lint with a stub-python3 PATH to verify the
# new tomllib/tomli SKIP path. Without this marker, the lint would
# discover that test, run it, and recurse forever (CI hits the 6h
# ceiling). Tests can read this var to detect the nested run.
export AGENTIS_COLONY_LINT_NESTED="${AGENTIS_COLONY_LINT_NESTED:-0}"

# --- Flag parsing ---
# `--boot-smoke` opts the operator in to tools/test-boot-smoke.sh (#760).
# That test spawns a real ~45s research-foundry container, so it is NOT
# part of the default discovery loop -- only invoked when the flag is set.
# Everything else stays a positional REPO_ROOT for backward compat.
BOOT_SMOKE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --boot-smoke) BOOT_SMOKE=1; shift ;;
        --) shift; break ;;
        -*) echo "colony-lint: unknown flag: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PASS=0
FAIL=0
SKIP=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; SKIP=$((SKIP + 1)); }

# --- Discover federations ---
# A federation is a top-level directory with a README.md, excluding dotdirs,
# tools/, and templates/ (the templates/ tree from #322 is a contributor-only
# catalog of pre-built `.ag` templates, not a runtime federation — its
# `.ag` files are linted only after they have been scaffolded into a real
# colony via tools/scaffold-agent.sh).
federations=()
for dir in "$REPO_ROOT"/*/; do
    name="$(basename "$dir")"
    case "$name" in
        .*|tools|templates) continue ;;
    esac
    if [ -f "$dir/README.md" ]; then
        federations+=("$name")
    fi
done

if [ ${#federations[@]} -eq 0 ]; then
    fail "no federations found (top-level dirs with README.md)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# --- Probe TOML parser availability (#272) ---
# stdlib `tomllib` arrived in Python 3.11; macOS /usr/bin/python3 (3.9) lacks
# both it and `tomli`. Probe once so per-colony TOML validation degrades to
# one [SKIP] instead of N tracebacks.
has_toml_parser=0
if python3 -c 'import tomllib' 2>/dev/null \
    || python3 -c 'import tomli' 2>/dev/null; then
    has_toml_parser=1
fi

# --- Discover colonies within each federation ---
# A colony is a subdirectory of a federation that has a config/ dir.
for fed in "${federations[@]}"; do
    fed_path="$REPO_ROOT/$fed"

    colonies=()
    for dir in "$fed_path"/*/; do
        [ -d "$dir" ] || continue
        if [ -d "$dir/config" ]; then
            colonies+=("$(basename "$dir")")
        fi
    done

    if [ ${#colonies[@]} -eq 0 ]; then
        skip "$fed: no colonies found"
        continue
    fi

    for colony in "${colonies[@]}"; do
        prefix="$fed/$colony"
        col_path="$fed_path/$colony"

        # --- Structure checks ---
        structure_ok=true
        for required in README.md config/colony.example.toml scripts/start-colony.sh agents; do
            if [ ! -e "$col_path/$required" ]; then
                fail "$prefix: missing $required"
                structure_ok=false
            fi
        done

        if [ -f "$col_path/scripts/start-colony.sh" ] && [ ! -x "$col_path/scripts/start-colony.sh" ]; then
            fail "$prefix: start-colony.sh is not executable"
            structure_ok=false
        fi

        if $structure_ok; then
            pass "$prefix: structure OK"
        fi

        # --- TOML validation ---
        config="$col_path/config/colony.example.toml"
        if [ -f "$config" ] && [ "$has_toml_parser" = 0 ]; then
            skip "$prefix: config check (no TOML parser; install tomli or use Python 3.11+)"
        elif [ -f "$config" ]; then
            toml_errors=$(python3 -c "
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib

# #316 M1: scan the raw text for the both-forms-present case so we emit a
# migration-friendly error instead of the bare TOMLDecodeError tomllib
# would otherwise raise. Mirror checks for both [forge.github] and
# [forge.gitlab].
with open(sys.argv[1], 'r', encoding='utf-8') as _f:
    _raw_lines = [ln.strip() for ln in _f]

errors = []
for _backend in ('github', 'gitlab'):
    _has_single = any(ln == '[forge.' + _backend + ']' for ln in _raw_lines)
    _has_multi  = any(ln == '[[forge.' + _backend + ']]' for ln in _raw_lines)
    if _has_single and _has_multi:
        errors.append('config has both [forge.' + _backend + '] and [[forge.' + _backend + ']] — drop the [forge.' + _backend + '] block (single-table form retired in v2.0.0; run tools/migrate-to-multi-repo.sh)')

if errors:
    print('\n'.join(errors))
    sys.exit(1)

with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)

if 'colony' not in data:
    errors.append('missing [colony] section')
if 'gitlab' in data:
    errors.append('legacy top-level [gitlab] section still present — retired in #256 PR 7 (v1.0.0). Move keys under [forge.gitlab].')
if 'forge' not in data or not isinstance(data.get('forge'), dict):
    errors.append('missing [forge] section (post-#256: required)')
else:
    forge_type = data['forge'].get('type')
    if forge_type not in ('gitlab', 'github', 'none'):
        errors.append(f'[forge].type must be \"gitlab\", \"github\", or \"none\" (got {forge_type!r})')
    elif forge_type == 'none':
        # ADR-0003 explicitly allows non-forge federations. forge.type = \"none\"
        # is the explicit opt-out (#373): the [forge] block is present so the
        # post-#256 schema check still passes, but no [forge.gitlab] / [forge.github]
        # sub-block is required and any present sub-block is ignored. ADR-0002
        # remains normative for forge-bound colonies.
        pass
    elif forge_type == 'gitlab':
        # Pre-#316 contract preserved: gitlab uses 'project' (not 'owner'/
        # 'repo'); legacy single-table presence is the only post-#256
        # invariant. Multi-repo for gitlab is symmetric to github but the
        # required-keys list differs (project vs owner/repo); M1 ships
        # github-only key validation per the plan, gitlab still gets the
        # presence-only check it had before.
        sub = data['forge'].get('gitlab')
        if sub is None:
            errors.append('[forge].type = \"gitlab\" but [forge.gitlab] (or [[forge.gitlab]]) is missing')
        elif isinstance(sub, list) and not sub:
            errors.append('[[forge.gitlab]] array is empty (need >= 1 entry)')
    elif forge_type == 'github':
        # #316 M1: accept either a single-table [forge.github] OR an
        # array-of-tables [[forge.github]]. tomllib surfaces the latter as a
        # Python list, the former as a dict. Both forms in one file are
        # rejected by the raw-text pre-check above, so by the time we get
        # here we know we are looking at exactly one shape.
        gh = data['forge'].get('github')
        if gh is None:
            errors.append('[forge].type = \"github\" but [forge.github] (or [[forge.github]]) is missing')
        elif isinstance(gh, list):
            # Multi-repo schema (#316 M1). Each entry must carry owner+repo.
            if not gh:
                errors.append('[[forge.github]] array is empty (need >= 1 entry)')
            for i, entry in enumerate(gh):
                if not isinstance(entry, dict):
                    errors.append(f'[[forge.github]][{i}] is not a table')
                    continue
                for required_key in ('owner', 'repo'):
                    if not entry.get(required_key):
                        errors.append(f'[[forge.github]][{i}] missing required key: {required_key}')
        elif isinstance(gh, dict):
            # M6 (#316): single-table form retired in v2.0.0.
            errors.append('[forge.github] single-table form is retired in v2.0.0 (#316 M6). Run tools/migrate-to-multi-repo.sh <colony.toml> to convert to [[forge.github]] array form.')
        else:
            errors.append(f'[forge.github] is wrong type: {type(gh).__name__}')
if 'llm' not in data:
    errors.append('missing [llm] section')
if 'agents' not in data or not isinstance(data['agents'], list) or len(data['agents']) == 0:
    errors.append('missing or empty [[agents]] section')

if errors:
    print('\n'.join(errors))
    sys.exit(1)

# Check agent source files exist (or .gitkeep as placeholder)
agents_dir = sys.argv[2]
for agent in data['agents']:
    source = agent.get('source', '')
    source_path = sys.argv[3] + '/' + source
    if not __import__('os').path.isfile(source_path):
        # Allow if agents dir has .gitkeep (colony is in early stage)
        gitkeep = agents_dir + '/.gitkeep'
        if not __import__('os').path.isfile(gitkeep):
            errors.append(f'agent \"{agent.get(\"name\", \"?\")}\" source \"{source}\" not found')

if errors:
    print('\n'.join(errors))
    sys.exit(1)
" "$config" "$col_path/agents" "$col_path" 2>&1) || true

            if [ -z "$toml_errors" ]; then
                pass "$prefix: config OK"
            else
                while IFS= read -r line; do
                    fail "$prefix: $line"
                done <<< "$toml_errors"
            fi
        fi

        # --- Shellcheck ---
        sh_files=()
        while IFS= read -r -d '' f; do
            sh_files+=("$f")
        done < <(find "$col_path" -name "*.sh" -print0 2>/dev/null)

        if [ ${#sh_files[@]} -gt 0 ]; then
            if command -v shellcheck &>/dev/null; then
                if shellcheck "${sh_files[@]}" &>/dev/null; then
                    pass "$prefix: shellcheck OK"
                else
                    fail "$prefix: shellcheck errors"
                    # Display-only re-run: under `set -euo pipefail` the
                    # pipeline inherits shellcheck's nonzero exit and would
                    # abort the whole lint before the summary line.
                    shellcheck "${sh_files[@]}" 2>&1 | head -30 || true
                fi
            else
                # CI installs shellcheck unconditionally (see .github/workflows/ci.yml),
                # so this skip only applies to local runs without shellcheck installed.
                # Shellcheck errors in CI always fail the run via the FAIL counter below.
                skip "$prefix: shellcheck not installed"
            fi
        fi

        # --- Daemon flag whitelist guardrail (#71) ---
        # Validates that every `agentis daemon` invocation in start-colony.sh
        # uses only flags from the case-statement allowlist below. Catches the
        # drift class that produced #68 (stale --backend / --enable-exec flags
        # that silently ran for months then started failing after agentis-core
        # v1.1.4 added strict flag validation).
        #
        # The allowlist must match DAEMON_FLAGS in agentis-core/src/cli/daemon.rs.
        # If core adds a new daemon flag, add it here too.
        start_script="$col_path/scripts/start-colony.sh"
        if [ -f "$start_script" ]; then
            bad_flags=$(awk -f "$REPO_ROOT/tools/colony-lint-flag-allowlist.awk" "$start_script" | while read -r flag; do
                # Pattern is deliberately on one line: bash 3.2 (stock macOS)
                # miscompiles backslash-newline inside case-pattern labels
                # (#121). Keep all alternatives on a single line.
                case "$flag" in
                    --tick-interval|--cb-per-tick|--prompt-timeout-s|--colony|--deadline|--priority|--enable-migration|--enable-replication|--allow-replica-replication|--enable-exec|--enable-messaging|--deny-exec|--config-override|--help|-h) ;;
                    *) echo "$flag" ;;
                esac
            done)

            if [ -z "$bad_flags" ]; then
                pass "$prefix: start-colony.sh daemon flags OK"
            else
                while IFS= read -r flag; do
                    fail "$prefix: start-colony.sh uses unknown daemon flag: $flag"
                done <<< "$bad_flags"
            fi
        fi

        # --- Markdown link check ---
        md_files=()
        while IFS= read -r -d '' f; do
            md_files+=("$f")
        done < <(find "$col_path" -name "*.md" -print0 2>/dev/null)

        # Also check federation README
        if [ -f "$fed_path/README.md" ]; then
            md_files+=("$fed_path/README.md")
        fi

        links_ok=true
        for md in "${md_files[@]}"; do
            md_dir="$(dirname "$md")"
            # Extract markdown links: [text](./path) or [text](path)
            while IFS= read -r link; do
                # Skip external URLs, anchors, and empty
                case "$link" in
                    http://*|https://*|mailto:*|\#*|"") continue ;;
                esac
                # Resolve relative to the markdown file's directory
                target="$md_dir/$link"
                # Strip anchor from link
                target="${target%%#*}"
                if [ ! -e "$target" ]; then
                    fail "$prefix: broken link in $(basename "$md"): $link"
                    links_ok=false
                fi
            done < <(grep -oP '\[.*?\]\(\K[^)]+' "$md" 2>/dev/null || true)
        done

        if $links_ok && [ ${#md_files[@]} -gt 0 ]; then
            pass "$prefix: markdown links OK"
        fi
    done
done

# --- Root README check ---
if [ -f "$REPO_ROOT/README.md" ]; then
    root_links_ok=true
    while IFS= read -r link; do
        case "$link" in
            http://*|https://*|mailto:*|\#*|"") continue ;;
        esac
        target="$REPO_ROOT/$link"
        target="${target%%#*}"
        if [ ! -e "$target" ]; then
            fail "README.md: broken link: $link"
            root_links_ok=false
        fi
    done < <(grep -oP '\[.*?\]\(\K[^)]+' "$REPO_ROOT/README.md" 2>/dev/null || true)
    if $root_links_ok; then
        pass "README.md: links OK"
    fi
fi

# --- Root CLAUDE.md check (#194) ---
# CLAUDE.md is loaded into every Claude session and frequently links to
# doc/ reference pages. A stale link there is a silent context leak —
# the agent quotes a dead path as authoritative — so mirror the README
# link check.
if [ -f "$REPO_ROOT/CLAUDE.md" ]; then
    claude_links_ok=true
    while IFS= read -r link; do
        case "$link" in
            http://*|https://*|mailto:*|\#*|"") continue ;;
        esac
        target="$REPO_ROOT/$link"
        target="${target%%#*}"
        if [ ! -e "$target" ]; then
            fail "CLAUDE.md: broken link: $link"
            claude_links_ok=false
        fi
    done < <(grep -oP '\[.*?\]\(\K[^)]+' "$REPO_ROOT/CLAUDE.md" 2>/dev/null || true)
    if $claude_links_ok; then
        pass "CLAUDE.md: links OK"
    fi
fi

# --- doc/ directory check (#194) ---
# Reference docs under doc/ link back to other doc/ files, to tools/
# and to agents under dev-apprenticeship/. Same check: file-relative
# resolution, strip anchors, report broken targets.
if [ -d "$REPO_ROOT/doc" ]; then
    doc_links_ok=true
    doc_files=()
    while IFS= read -r -d '' f; do
        doc_files+=("$f")
    done < <(find "$REPO_ROOT/doc" -name "*.md" -print0 2>/dev/null)
    for md in "${doc_files[@]}"; do
        md_dir="$(dirname "$md")"
        rel="${md#"$REPO_ROOT"/}"
        while IFS= read -r link; do
            case "$link" in
                http://*|https://*|mailto:*|\#*|"") continue ;;
            esac
            target="$md_dir/$link"
            target="${target%%#*}"
            if [ ! -e "$target" ]; then
                fail "$rel: broken link: $link"
                doc_links_ok=false
            fi
        done < <(grep -oP '\[.*?\]\(\K[^)]+' "$md" 2>/dev/null || true)
    done
    if $doc_links_ok && [ ${#doc_files[@]} -gt 0 ]; then
        pass "doc/: markdown links OK (${#doc_files[@]} files)"
    fi
fi

# --- Agentis validation (optional) ---
# `agentis commit` requires an .agentis/ directory in CWD, so we init a temp
# repo once and run all commits from inside it.
if command -v agentis &>/dev/null; then
    agentis_version=$(agentis version 2>/dev/null || echo "unknown")
    echo ""
    echo "Agentis found: $agentis_version"
    lint_tmp=$(mktemp -d)
    trap 'rm -rf "$lint_tmp"' EXIT
    (cd "$lint_tmp" && agentis init &>/dev/null) || true

    # --- Capability probe: tier() builtin (#177) ---
    # The tier-branch lint below requires the `tier()` builtin shipped by
    # Replikanti/agentis-core#537. Version-string parsing is brittle because
    # the release carrying tier() has not been tagged at the time this code
    # ships — so probe the capability directly by evaluating a minimal .ag
    # that calls tier(). If the probe fails we skip the tier-branch check
    # and surface a clear error instead of crashing every agent check.
    tier_probe_ok=false
    probe_tmp=$(mktemp -d)
    (cd "$probe_tmp" && agentis init &>/dev/null) || true
    printf 'fn tick(r:string)->void{print(tier("x"));}\n' > "$probe_tmp/_probe.ag"
    if (cd "$probe_tmp" && agentis go "_probe.ag") &>/dev/null; then
        tier_probe_ok=true
    fi
    rm -rf "$probe_tmp"

    if ! $tier_probe_ok; then
        fail "agentis binary does not support tier() builtin (#177 requires Replikanti/agentis-core#537); upgrade agentis before running tier-branch lint"
    fi

    for fed in "${federations[@]}"; do
        for dir in "$REPO_ROOT/$fed"/*/; do
            [ -d "$dir/config" ] || continue
            colony="$(basename "$dir")"
            ag_files=()
            # Phase 7 PR-A (#628): exclude `<colony>/agents/.evolve/`
            # candidate-gen-N files from the per-agent .ag glob. The
            # auto-evolve-ab.sh harness lifecycle owns those files;
            # treating them as production agents here would fail the
            # tier-coverage lint mid-mutation.
            while IFS= read -r -d '' f; do
                ag_files+=("$f")
            done < <(find "$dir/agents" -maxdepth 1 -name "*.ag" -print0 2>/dev/null)

            if [ ${#ag_files[@]} -gt 0 ]; then
                for ag in "${ag_files[@]}"; do
                    if (cd "$lint_tmp" && agentis commit "$ag") &>/dev/null; then
                        pass "$fed/$colony: $(basename "$ag") syntax OK"
                    else
                        fail "$fed/$colony: $(basename "$ag") syntax error"
                    fi

                    # --- Tier-branch convention (#177) ---
                    # For every agent that defines fn tick(...), enforce the
                    # four-tier contract from ADR-0001:
                    #   1. at least one tier("...") call
                    #   2. all four tiers covered: shadow / propose /
                    #      review-gated / autonomous. The canonical pattern
                    #      from CLAUDE.md collapses shadow (and dormant)
                    #      into the else-fallthrough, so the literal
                    #      "shadow" may be absent — when the other three
                    #      non-shadow tiers are present AND a tier() call
                    #      exists, shadow is treated as implicitly covered.
                    #   3. no raw `confidence >= <number>` literals
                    # Escape hatch: a line `// tiers: partial` in the file
                    # skips rule #2 but never rule #1 or #3.
                    if $tier_probe_ok && grep -qE '^\s*fn\s+tick\s*\(' "$ag"; then
                        ag_rel="$fed/$colony/$(basename "$ag")"
                        tier_ok=true

                        # #316 M4: post-M3 agents use repo_tier(name, owner, repo)
                        # instead of tier(name); both forms satisfy the ADR-0001
                        # tier-call requirement. The first regex matches the
                        # legacy single-arg tier("..."); the second matches the
                        # M4 multi-arg repo_tier("...", owner, repo) call.
                        if grep -qE '\btier\s*\(\s*"[^"]+"\s*\)' "$ag" \
                            || grep -qE '\brepo_tier\s*\(\s*"[^"]+"\s*,' "$ag"; then
                            has_tier_call=true
                        else
                            has_tier_call=false
                            fail "$ag_rel: missing tier(\"...\") or repo_tier(\"...\", ...) call (required by ADR-0001 / #316 M4)"
                            tier_ok=false
                        fi

                        if grep -qE '^\s*//\s*tiers:\s*partial' "$ag"; then
                            partial_ok=true
                        else
                            partial_ok=false
                        fi

                        if ! $partial_ok; then
                            missing_explicit=""
                            for tier_name in propose review-gated autonomous; do
                                if ! grep -qE "\"$tier_name\"" "$ag"; then
                                    missing_explicit="$missing_explicit $tier_name"
                                fi
                            done
                            has_shadow_literal=false
                            if grep -qE '"shadow"' "$ag"; then
                                has_shadow_literal=true
                            fi
                            if [ -n "$missing_explicit" ]; then
                                fail "$ag_rel: missing tier literal(s):$missing_explicit"
                                tier_ok=false
                            elif ! $has_shadow_literal && ! $has_tier_call; then
                                fail "$ag_rel: missing tier literal(s): shadow (no tier() call to imply else-fallthrough)"
                                tier_ok=false
                            fi
                        fi

                        if grep -nE '\bconfidence\s*>=\s*[0-9]+(\.[0-9]+)?' "$ag" >/dev/null; then
                            fail "$ag_rel: raw confidence >= <number> literal (use tier() per ADR-0001)"
                            tier_ok=false
                        fi

                        # --- M4 per-repo tier convention (#316 M4) ---
                        # Agents that fan out per-repo (post-M3 fn tick_for_repo)
                        # must read tier via repo_tier(name, owner, repo) so the
                        # per-repo confidence memo wins over the legacy unscoped
                        # key. A bare `let my_tier = tier("...")` inside such an
                        # agent silently shares tier across every repo the
                        # colony serves, defeating M4's per-repo divergence.
                        # Escape hatch: `// colony-lint: m4-direct-tier-ok` for
                        # intentional opt-out (e.g. an inner-helper that always
                        # wants legacy semantics regardless of repo scope).
                        if grep -qE '^\s*fn\s+tick_for_repo\s*\(' "$ag"; then
                            if grep -qE '//\s*colony-lint:\s*m4-direct-tier-ok' "$ag"; then
                                : # opt-out present, skip both rules
                            else
                                if grep -nE 'let\s+my_tier\s*=\s*tier\s*\(' "$ag" >/dev/null; then
                                    fail "$ag_rel: direct tier() call inside tick_for_repo (use repo_tier per #316 M4)"
                                    tier_ok=false
                                fi
                                if ! grep -qE 'fn\s+repo_tier\s*\(' "$ag"; then
                                    fail "$ag_rel: missing repo_tier() helper (required by #316 M4)"
                                    tier_ok=false
                                fi
                            fi
                        fi

                        if $tier_ok; then
                            pass "$ag_rel: tier-branch convention OK"
                        fi
                    fi
                done
            fi
        done
    done
else
    skip "agentis validation (binary not found)"
fi

# --- Check .ag files for unsafe exec sh concatenation (#57) ---
# Grep-level guardrail against the shell-injection class of bug that
# slipped through in #49. Scans every .ag file under the repo root and
# fails the lint if any LLM-tainted value is concatenated into an
# `exec sh` command without a `shell_escape(...)` or `to_string(...)` wrap.
if [ -x "$REPO_ROOT/tools/check-exec-sh.sh" ]; then
    check_out="$("$REPO_ROOT/tools/check-exec-sh.sh" "$REPO_ROOT" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "check-exec-sh: no unsafe concat into exec sh"
    else
        fail "check-exec-sh: unsafe concat into exec sh"
        printf '%s\n' "$check_out"
    fi
fi

# --- Check .ag files for direct backend-wrapper calls (ADR-0002, #256) ---
# Colonies that ship a concrete github-api.sh MUST route .ag calls through
# scripts/forge-api.sh — a hardcoded gitlab-api.sh / github-api.sh path
# silently breaks on the other backend (start-colony.sh exports only the
# env for the selected FORGE_TYPE, and .ag try/catch swallows the failure).
if [ -x "$REPO_ROOT/tools/check-forge-dispatch.sh" ]; then
    check_out="$("$REPO_ROOT/tools/check-forge-dispatch.sh" "$REPO_ROOT" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "check-forge-dispatch: .ag agents route through forge-api.sh"
    else
        fail "check-forge-dispatch: direct backend-wrapper call from .ag file"
        printf '%s\n' "$check_out"
    fi
fi

# --- Check ticking colonies for unguarded prompt() (#200 / #201 / #205 / #208 / #210) ---
# The implementation, planning, code-review, and triage colonies tick
# frequently; a `prompt()` that is not gated on a memo-based staleness
# check drives ~60 LLM calls/hour per stuck issue or stuck MR. This
# grep-level check fails the lint if any `*.ag` file under those four
# colonies has a `prompt()` not preceded (within the same function) by
# `recall_latest()` or a call to a gate fn.
if [ -x "$REPO_ROOT/tools/check-prompt-gate.sh" ]; then
    check_out="$("$REPO_ROOT/tools/check-prompt-gate.sh" "$REPO_ROOT" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "check-prompt-gate: all ticking prompts (impl/planning/code-review/triage) memo-gated"
    else
        fail "check-prompt-gate: unguarded prompt() in ticking colony"
        printf '%s\n' "$check_out"
    fi
fi

# --- Check getenv() knobs against the install.sh allowlist (#1428) ---
# getenv() reads the SANITIZED env: a var missing from the
# exec.env_passthrough allowlist written by dev-apprenticeship/install.sh
# never reaches the .ag runtime, so the operator knob is silently inert
# (proven live on the #1424 burn-in, #1426). This check fails the lint when
# a dev-apprenticeship agent reads a getenv() var that is neither
# allowlisted nor annotated `// colony-lint: getenv-unregistered-ok`, and
# when an allowlisted getenv knob is missing from the #1437 residue-check
# list in install.sh.
if [ -x "$REPO_ROOT/tools/check-getenv-allowlist.sh" ]; then
    check_out="$("$REPO_ROOT/tools/check-getenv-allowlist.sh" "$REPO_ROOT" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "check-getenv-allowlist: every dev-apprenticeship getenv() knob allowlisted or waived (#1428)"
    elif [ "$check_rc" -eq 2 ]; then
        fail "check-getenv-allowlist: infra/usage error (exit 2 — not a knob finding)"
        printf '%s\n' "$check_out"
    else
        fail "check-getenv-allowlist: unregistered getenv() knob — silently inert (#1428)"
        printf '%s\n' "$check_out"
    fi
fi

# --- Check substrate purity: no NEW embedded interpreter in .ag (#1587/#1608) ---
# Agent logic belongs in `.ag`, not inside an embedded `python3 -c` / awk / sed
# one-liner shelled out through `exec sh`. Phase 0 (#1588) purged ~148 legacy
# escapes; the rest are inventoried on the #1587 epic. This is the ratchet's
# regression-prevention half (#1608): a NEW embedded interpreter in a
# dev-apprenticeship agent that is neither on the script's file:function:phase
# allowlist nor annotated `// substrate-purity: deferred (<reason>)` fails the
# lint ([NEW-ESCAPE]); a completed rewrite that leaves its allowlist row behind
# fails too ([STALE-ALLOWLIST]) — so the debt can only shrink.
if [ -x "$REPO_ROOT/tools/check-substrate-purity.sh" ]; then
    check_out="$("$REPO_ROOT/tools/check-substrate-purity.sh" "$REPO_ROOT" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "check-substrate-purity: no NEW embedded interpreter in dev-apprenticeship exec sh (#1587)"
    elif [ "$check_rc" -eq 2 ]; then
        fail "check-substrate-purity: infra/usage error (exit 2 — not a purity finding)"
        printf '%s\n' "$check_out"
    else
        fail "check-substrate-purity: NEW embedded interpreter or stale allowlist entry (#1587)"
        printf '%s\n' "$check_out"
    fi
fi

# --- Check reality-check feedback-loop wiring (#1453) ---
# A dev-apprenticeship agent that writes to the forge (opens an MR, posts a
# note, tags/releases, merges) must either wire the reality-check feedback
# loop (a `<agent>:pending_verdict` memo, per doc/feedback-loop.md's 4-step
# idiom) or carry a documented `// colony-lint: reality-check-waived: ...`
# waiver. This is the regression guard for the #1453 federation-wide
# rollout: a new acting agent, or a new acting call site, that skips both
# wiring and waiver fails the lint.
if [ -x "$REPO_ROOT/tools/check-reality-check.sh" ]; then
    check_out="$("$REPO_ROOT/tools/check-reality-check.sh" "$REPO_ROOT" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "check-reality-check: every dev-apprenticeship acting agent wired or waived (#1453)"
    elif [ "$check_rc" -eq 2 ]; then
        fail "check-reality-check: infra/usage error (exit 2 — not a wiring finding)"
        printf '%s\n' "$check_out"
    else
        fail "check-reality-check: forge write verb without reality-check wiring or waiver (#1453)"
        printf '%s\n' "$check_out"
    fi
fi

# --- Check LLM prompt strings for bare push() examples (#943) ---
# `push(list, x)` in agentis is PURE — it returns a new list and does
# NOT mutate the input. Several research-foundry agents embed `.ag`
# source as example code inside their LLM prompt strings; an example
# that uses `push(acc, x);` without capturing the return value teaches
# the LLM to discard the new list. The empirical failure mode (#943):
# 48 of 50 explorer codes used bare `push(acc, x);` -> 0 preprints over
# multiple federation runs. This lint blocks the pattern at edit time.
# Authors can suppress an intentional cold-path example with
# `// colony-lint: prompt-push-ok`.
if [ -x "$REPO_ROOT/tools/check-llm-prompt-list-ops.sh" ]; then
    check_out="$("$REPO_ROOT/tools/check-llm-prompt-list-ops.sh" "$REPO_ROOT" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "check-llm-prompt-list-ops: no bare push() examples in research-foundry LLM prompts (#943)"
    else
        fail "check-llm-prompt-list-ops: bare push() example inside LLM prompt string"
        printf '%s\n' "$check_out"
    fi
fi

# --- Check learn() tag schema in tribes-bench hunters (#492) ---
# `tribes-bench/` fitness aggregation reads free-form `learn()` tags as
# authoritative — auto-promote / selection-fitness classifies experience
# rows by tag (acted / replicated / reward=<int> / ...). An evolved
# hunter could emit `learn("hunt", ..., "success", ["acted", "reward=999"])`
# without producing a verified finding and harvest selection reward.
# This static lint blocks unknown literal tags at edit-time. Dynamic
# tag construction (variable refs / `+`-concat tag lists) is a known
# evasion gap — WARN by default, FAIL under
# `COLONY_LINT_STRICT_LEARN_TAGS=1`. See the script header for the full
# Loose category (b) context.
if [ -x "$REPO_ROOT/tools/check-learn-tags.sh" ]; then
    check_out="$("$REPO_ROOT/tools/check-learn-tags.sh" "$REPO_ROOT" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "check-learn-tags: tribes-bench + research-fed learn() tag streams match per-call-site schema (#492, #622)"
    else
        fail "check-learn-tags: schema violation in learn() tag stream (#492, #622)"
        printf '%s\n' "$check_out"
    fi
fi

# --- learn() / recommend() topic-match guard (#622 PR-3) ---
# `recommend("<topic>", ...)` topics in a `.ag` file must be a subset
# of the `learn("<topic>", ...)` topics in the same file; otherwise
# the recommend has no scored history and confidence drift is silent.
# Scoped to tribes-bench + the three research feds (same per-call-site
# set as check-learn-tags); dev-apprenticeship is excluded until its
# pre-existing topic-split is migrated.
if [ -x "$REPO_ROOT/tools/check-learn-recommend-topic-match.sh" ]; then
    check_out="$("$REPO_ROOT/tools/check-learn-recommend-topic-match.sh" "$REPO_ROOT" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "check-learn-recommend-topic-match: recommend() topics are a subset of learn() topics per agent (#622)"
    else
        fail "check-learn-recommend-topic-match: recommend()/learn() topic mismatch (#622)"
        printf '%s\n' "$check_out"
    fi
fi

# --- replay:current_<role>_pid regression guard (#663 Phase 9 PR-A) ---
# Phase 9 PR-A replaced the replica-unsafe `replay:current_<role>_pid`
# LWW handoff with `_pick_upstream_by_confidence(role, output_key, tick)`.
# Downstream `.ag` files must NOT regress to the LWW pattern.
if [ -x "$REPO_ROOT/tools/check-no-replay-current-pid.sh" ]; then
    check_out="$("$REPO_ROOT/tools/check-no-replay-current-pid.sh" "$REPO_ROOT" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "check-no-replay-current-pid: no replay:current_<role>_pid references in research-foundry/ (#663)"
    else
        fail "check-no-replay-current-pid: replay:current_<role>_pid regression (#663 Phase 9 PR-A)"
        printf '%s\n' "$check_out"
    fi
fi

# --- Top-of-tick last_check heartbeat (#697) ---
# All 18 research-foundry .ag agents must write `<colony>:last_check`
# at the top of `fn tick(...)` (after `_jitter_sleep()`) so the
# dashboard's #686 memo-freshness liveness probe reflects daemon-alive
# even when early-return gates skip the bottom-of-tick refresh.
if [ -x "$REPO_ROOT/research-foundry/tools/test-last-check-early.sh" ]; then
    check_out="$(bash "$REPO_ROOT/research-foundry/tools/test-last-check-early.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "test-last-check-early: all 18 research-foundry .ag agents write last_check at top of fn tick (#697)"
    else
        fail "test-last-check-early: top-of-tick last_check write missing/misplaced in research-foundry/ (#697)"
        printf '%s\n' "$check_out"
    fi
fi

# --- Per-daemon --prompt-timeout-s flag (#802) ---
# Every `agentis daemon /run-root/.../agents/<colony>.ag` spawn line in
# `research-foundry/tools/run-research.sh` must carry `--prompt-timeout-s
# "$DAEMON_PROMPT_TIMEOUT_S"` so a stuck upstream `prompt()` returns as a
# tick-level error within the wall-clock cap rather than holding the
# entire watchdog heartbeat budget (1800s default) and inviting a
# SIGKILL on the daemon.
if [ -x "$REPO_ROOT/research-foundry/tools/test-prompt-timeout-flag.sh" ]; then
    check_out="$(bash "$REPO_ROOT/research-foundry/tools/test-prompt-timeout-flag.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "test-prompt-timeout-flag: every research-foundry daemon spawn line carries --prompt-timeout-s (#802)"
    else
        fail "test-prompt-timeout-flag: daemon spawn line missing --prompt-timeout-s in research-foundry/ (#802)"
        printf '%s\n' "$check_out"
    fi
fi

# --- Mathlib novelty check helper (#955) ---
# The research-foundry theorist runs `mathlib-novelty-check.sh` after
# Lean reports `verified` to split the verdict into verified_novel vs
# verified_duplicate. The helper must extract the last theorem block,
# fuzzy-match against a Mathlib source tree, and degrade gracefully on
# empty input / missing Mathlib root.
if [ -x "$REPO_ROOT/research-foundry/tools/test-mathlib-novelty-check.sh" ]; then
    check_out="$(bash "$REPO_ROOT/research-foundry/tools/test-mathlib-novelty-check.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "test-mathlib-novelty-check: theorist mathlib novelty cross-check helper + theorist.ag wiring (#955)"
    else
        fail "test-mathlib-novelty-check: theorist mathlib novelty helper / theorist.ag wiring drifted (#955)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory submission-triage gates (#1456/#1458) ---
# submit-triage.sh scores staged findings (READY / INCOMPLETE / DUP-RISK), flags impact-credibility
# (IMPACT quant/qual?) and duplicate-risk (NOVELTY via --known-issues), and never contacts a platform.
# demo-submit-triage.sh is pure bash (no agentis / no network) so it runs on CI runners.
if [ -x "$REPO_ROOT/dark-factory/demo-submit-triage.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-submit-triage.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: submit-triage gates (impact/dedup/precedence, never-submits) (#1456/#1458)"
    else
        fail "dark-factory: submit-triage gates regressed (#1456/#1458)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory report-quality e2e (#1456/#1457) ---
# A real VERIFIED audit must stage an Immunefi-shaped report.md (impact quantification mapped to the
# Immunefi bands) + a REPRODUCTION.md manifest, quantify funds-at-risk ONLY from a real snapshot, and
# disclose the owner rebind. Needs the agentis runtime + rustc, so it SKIPs (exit 0) on runners lacking
# them — a no-op on CI, a real gate locally / where the toolchain is present.
if [ -x "$REPO_ROOT/dark-factory/demo-report-quality.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-report-quality.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: report-quality e2e (report + REPRODUCTION.md, quantified-from-snapshot) (#1456/#1457)"
    else
        fail "dark-factory: report-quality e2e regressed (#1456/#1457)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory bounty-weighted audit queue (#1459) ---
# prospector-queue.sh turns the prospector colony's qualified, bounty-annotated dossiers into a
# run-batch-consumable audit queue RANKED BY EXPECTED PAYOUT, keeps the boolean qualification gates as the
# floor (a big bounty on a non-qualifying target never enters the queue), carries the in-scope commit +
# address into each row, and has no platform egress. demo-prospector-queue.sh is pure bash/python3 (no
# agentis / no network) so it runs on CI runners.
if [ -x "$REPO_ROOT/dark-factory/demo-prospector-queue.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-prospector-queue.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: bounty-weighted audit queue (rank-by-payout, gates-are-floor, no-egress) (#1459)"
    else
        fail "dark-factory: bounty-weighted audit queue regressed (#1459)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory Immunefi intake + post-audit-delta discovery (#1506) ---
# audit-delta.sh is a pure git-diff detector that surfaces the files a target changed SINCE the audit it froze
# on — the post-audit residual is where an audited protocol's rewardable bug lives. run-immunefi-intake.sh ranks
# an OPERATOR-SUPPLIED programs JSON (no live Immunefi fetch, ever) by bounty + that delta term, emitting the
# same run-batch-consumable TSV. demo-immunefi-intake.sh is pure bash/git/python3 (a throwaway `git init`
# fixture, no network / no agentis) so it runs on CI runners.
if [ -x "$REPO_ROOT/dark-factory/demo-immunefi-intake.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-immunefi-intake.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: Immunefi intake + post-audit-delta discovery (audit-delta + run-immunefi-intake) (#1506)"
    else
        fail "dark-factory: Immunefi intake + post-audit-delta discovery regressed (#1506)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory Immunefi --live discovery mapper + audit-density penalty (#1592/#1599) ---
# run-immunefi-intake.sh --live/--bounties MAPS the public bounties.json into the operator-programs schema and
# folds a live-only discovery_bonus (freshness + audit-scarcity + accounting-fit MINUS a competition/named-firm
# audit-density penalty, clamped >=0) into the score, surfacing kyc/aud/comp markers inside scope_hint col 5.
# demo-immunefi-live.sh is pure bash/python3 over a canned fixture (via the --bounties offline hatch, no network)
# so it runs on CI runners; its fixture-pair assertions gate the #1599 penalty.
if [ -x "$REPO_ROOT/dark-factory/demo-immunefi-live.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-immunefi-live.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: Immunefi --live discovery mapper + audit-density penalty (#1592/#1599)"
    else
        fail "dark-factory: Immunefi --live discovery mapper + audit-density penalty regressed (#1592/#1599)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory repo-git-history audit-density probe (#1609) ---
if [ -x "$REPO_ROOT/dark-factory/demo-audit-history-probe.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-audit-history-probe.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: repo-git-history audit-density probe (fix-audit/finding-ref/firm signals, offline SKIP) (#1609)"
    else
        fail "dark-factory: repo-git-history audit-density probe regressed (#1609)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory zone-mapping: auto-derive scope.tsv from a target (#1612, epic #1611 M1) ---
# map-zones.sh (shell plumbing) + auditor/agents/zone-mapper.ag (substrate classification) auto-derive a
# target's DISCOVERY manifest: locate/group in-scope sources into ZONES, LOC + advisory hardening_score
# (audit-delta churn + git age, never a gate), function-slice big contracts, and delegate subsystem x
# bug-class classification to the substrate -> zones.json + scope.tsv (the pipe-delimited manifest
# run-discovery.sh --scope reads verbatim). run-discovery.sh gains an opt-in --list-cells dry-run for the
# offline round-trip. demo-map-zones.sh is pure bash/git/python3 over a throwaway git fixture with a
# --fixture substrate stub (no network / no LLM) so it runs on CI runners; it also source-guards
# zone-mapper.ag and runs it live via --backend mock when agentis is present.
if [ -x "$REPO_ROOT/dark-factory/demo-map-zones.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-map-zones.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: zone-mapping (map-zones.sh + zone-mapper.ag -> zones.json + scope.tsv, --list-cells round-trip) (#1612)"
    else
        fail "dark-factory: zone-mapping regressed (#1612)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory brief-generation: per-zone hunt briefs that prime the discovery hunt (#1619, epic #1611 M2) ---
# gen-briefs.sh (shell plumbing) + auditor/agents/brief-writer.ag (substrate authoring) turn M1's zones.json +
# scope.tsv into a per-zone brief in the EXACT format hunter.ag consumes via SCOPE_BRIEF: header + bug-class
# list, the substrate DEPTH body (invariants-to-break + folded audit residual + prior-pattern hints), the
# in/out-of-scope boundaries, and the honesty mandate. run-discovery.sh gains an additive, opt-in --brief
# acknowledgement inside its --list-cells dry-run (prints BRIEF|<abs>|<lines>) so the round-trip proves a
# generated brief resolves offline; the shipped hunt path stays byte-identical. demo-gen-briefs.sh is pure
# bash/git/python3 over a throwaway git fixture with a --fixture body stub (no network / no LLM) so it runs on
# CI runners; it also source-guards brief-writer.ag and runs it live via --backend mock when agentis is present.
if [ -x "$REPO_ROOT/dark-factory/demo-gen-briefs.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-gen-briefs.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: brief-generation (gen-briefs.sh + brief-writer.ag -> per-zone briefs, --brief round-trip) (#1619)"
    else
        fail "dark-factory: brief-generation regressed (#1619)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory parallel fan-out: bounded-concurrency hunt over (subsystem x class) cells (#1625, epic #1611 M3) ---
# run-discovery.sh gains an opt-in --jobs N (-j N, default 1) bounded-concurrency fan-out: up to
# min(N, LLM_MAX_DISCOVERY_CELLS=4) cells hunt concurrently, EACH in its own isolated agentis store (cp -r of
# the initialised template) so concurrent builds/memo writes never race, with results aggregated AFTER the
# pool drains in manifest order. --jobs 1 (default) is byte-for-byte identical to the pre-M3 serial hunt.
# demo-discovery-parallel.sh is pure bash/python3 driving a fast offline stub through the existing --agentis
# seam (no live agentis / forge / network): asserts serial==golden, concurrency observed + cap never
# exceeded (incl. the LLM_MAX_DISCOVERY_CELLS clamp), aggregation==serial, per-cell isolation, and degrade.
if [ -x "$REPO_ROOT/dark-factory/demo-discovery-parallel.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-discovery-parallel.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: parallel fan-out (run-discovery.sh --jobs N bounded-concurrency + isolated per-cell store, serial byte-identical) (#1625)"
    else
        fail "dark-factory: parallel fan-out regressed (#1625)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory verify integration: the M3 -> verify bridge (#1630, epic #1611 M4) ---
# verify-findings.sh drives the refute gate (run-refute.sh, as-is) over EVERY candidate in an M3
# discovery-results.json and aggregates the CONFIRMED-only survivors into verified_findings.json (seam-3 schema).
# It is READ-ONLY over discovery-results.json and has no submit verb. demo-verify-findings.sh is pure
# bash/python3 driving a fast offline refute stub through the existing --agentis seam (no live agentis / forge /
# network): asserts the schema keys, CONFIRMED-only filtering (REFUTED dropped), the read-only invariant
# (discovery-results.json byte-unchanged), a degrade (ungate-able candidate skipped not fatal), and never-submit.
if [ -x "$REPO_ROOT/dark-factory/demo-verify-findings.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-verify-findings.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: verify integration (verify-findings.sh: refute gate -> CONFIRMED-only verified_findings.json, read-only) (#1630)"
    else
        fail "dark-factory: verify integration regressed (#1630)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory zone-hunt capstone: map -> brief -> discovery -> verify -> audit-pass -> deliver (#1630, epic #1611 M5) ---
# run-zone-hunt.sh chains the shipped M1..M4 + delivery entrypoints into ONE autonomous zone-hunt and EDITS none
# of them; it HALTS every finding at PENDING-HUMAN-REVIEW (enforced by run-audit-pass's terminal + deliver-
# submission's marker-refuse) and adds ZERO egress. Per-finding errors are logged + skipped (the batch finishes).
# demo-run-zone-hunt.sh is pure bash/git/python3 over a throwaway git fixture with ONE --agentis stub + the
# M1/M2/M5 --fixture seams (no live agentis / forge / network): asserts the chain is wired, the HALT on every
# delivered path, never-submit (no egress, no draft for a scope-blocked finding), and per-finding propagation.
if [ -x "$REPO_ROOT/dark-factory/demo-run-zone-hunt.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-run-zone-hunt.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: zone-hunt capstone (run-zone-hunt.sh: map->brief->discovery->verify->audit-pass->deliver, HALT at PENDING-HUMAN-REVIEW) (#1630)"
    else
        fail "dark-factory: zone-hunt capstone regressed (#1630)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory integration-seam / composability lens: the C15 bug-class hunt lens (#1644, epic #1611) ---
# A first-class C15 taxonomy class + a PROMPT-ONLY zone-mapper detection rule (tag integration/adapter zones —
# *Adapter/*Guard/*Bridge/*Oracle/*Wrapper/*Router/*Strategy or external-protocol importers) + a conditional
# brief-writer seamClause (mirrors residualClause/boundaryClause: fires on the comma-bounded ,C15, token,
# empty otherwise so a non-C15 brief is BYTE-IDENTICAL). demo-seam-lens.sh is pure bash/git/python3 over a
# throwaway git fixture (fixtures/seam-lens/ — integration contracts + a plain-token negative control) with a
# --fixture stub (no network / no LLM) so it runs on CI runners: asserts the C15 tag round-trips into scope.tsv
# only on integration zones, the C15 briefs carry the 6-heuristic seam hunt guide, the plain zone stays
# seam-free, detection-semantics consistency, and the taxonomy/zone-mapper/brief-writer source guards; it also
# runs the pipeline live via --backend mock when agentis is present.
if [ -x "$REPO_ROOT/dark-factory/demo-seam-lens.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-seam-lens.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: integration-seam lens (C15 taxonomy class + zone-mapper detection + brief-writer seamClause, no-C15 byte-identical) (#1644)"
    else
        fail "dark-factory: integration-seam lens regressed (#1644)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory new-listing watcher: freshness-first Immunefi target selection (#1623) ---
if [ -x "$REPO_ROOT/dark-factory/demo-watch-new-listings.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-watch-new-listings.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: new-listing watcher (launch-window + first-seen freshness, ledger dedup) (#1623)"
    else
        fail "dark-factory: new-listing watcher regressed (#1623)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory competition watcher: Sherlock + Cantina + CodeHawks freshness watch (#1635, #1643) ---
if [ -x "$REPO_ROOT/dark-factory/demo-watch-competitions.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-watch-competitions.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: competition watcher (Sherlock RUNNING + Cantina non-complete + CodeHawks date-derived, ledger dedup, offline SKIP) (#1635, #1643)"
    else
        fail "dark-factory: competition watcher regressed (#1635, #1643)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory snapshot owner-rebind hard assert (#1457) ---
# The snapshot-replay harness reads the account's real on-chain owner and emits an explicit
# OWNER REBIND / MATCH / MISMATCH marker; with EXPECT_PROGRAM_OWNER (run-audit --expect-owner) it
# HARD-ASSERTS owner-match, refusing a mismatch as INCONCLUSIVE so a re-owned copy is never reported
# VERIFIED. demo-owner-assert.sh source-guards the harness + run-audit wiring (CI-safe) and, when the
# poc_snapshot binary is present (Solana toolchain), also runs the 3 modes live.
if [ -x "$REPO_ROOT/dark-factory/demo-owner-assert.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-owner-assert.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: snapshot owner-rebind hard assert (explicit marker + EXPECT_PROGRAM_OWNER) (#1457)"
    else
        fail "dark-factory: snapshot owner-rebind hard assert regressed (#1457)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory audit-aware residual-hunt foundation (#1485) ---
# fetch-audits.sh ingests a target's public audit reports (extract text; clean SKIP offline) so the hunt
# knows the KNOWN-issue boundary; novelty-gate.sh rejects a finding that restates a known issue (matched by
# shared target function/identifier + salient-term overlap) while passing a genuinely-novel one — so the
# engine never surfaces a known/already-reported bug (a rejected submission). demo-audit-hunter.sh is pure
# bash/python3 (localhost fetch, no external network) so it runs on CI runners.
if [ -x "$REPO_ROOT/dark-factory/demo-audit-hunter.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-audit-hunter.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: audit-aware residual-hunt foundation (fetch-audits + novelty-gate) (#1485)"
    else
        fail "dark-factory: audit-aware residual-hunt foundation regressed (#1485)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory audit-aware DEVISE stage in the substrate (#1487) ---
# audit-scout.ag is the .ag embodiment of the audit-awareness above: it ingests a target's OWN audit reports
# (via the fetch-audits.sh muscle) and devises the RESIDUAL attack surface — what N prior auditors MISSED, the
# only rewardable part of an audited target — feeding the hunter/invariant-prover engines residual-focused
# specs and novelty-gate the exclusion boundary. This is the discover->evaluate->DEVISE->attack flow's missing
# DEVISE step, made a federation decision rather than a shell orchestrator. demo-audit-scout.sh source-guards
# the wiring (CI-safe, no toolchain) and runs the agent live end-to-end when agentis is present.
if [ -x "$REPO_ROOT/dark-factory/demo-audit-scout.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-audit-scout.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: audit-aware DEVISE stage (audit-scout.ag) (#1487)"
    else
        fail "dark-factory: audit-aware DEVISE stage regressed (#1487)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory dup-risk estimator (#1503) ---
# dup-scout.ag estimates the "already-reported" probability of a CONFIRMED finding from observable repo/audit
# evidence (git freshness, patch-status, fix-velocity, audit coverage) so the human SUBMIT decision is
# evidence-based rather than a blind guess — the stage between VERIFY and the human-gated submit. It never
# submits. demo-dup-scout.sh source-guards the wiring (CI-safe) and runs the agent live over a throwaway
# git-repo fixture when agentis is present.
if [ -x "$REPO_ROOT/dark-factory/demo-dup-scout.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-dup-scout.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: dup-risk estimator (dup-scout.ag) (#1503)"
    else
        fail "dark-factory: dup-risk estimator regressed (#1503)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory scope+eligibility gate (#1511) ---
# scope-gate.ag classifies a CONFIRMED finding as PAYABLE only when its location is an in-scope asset AND its
# impact is eligible + not an out-of-scope/known-issues (incl. audit-noted) carve-out — the correctness barrier
# that killed two live sessions (Lombard: out-of-scope asset; Onyx: excluded carve-out) before DEVISE/PoC spend.
# It never submits. demo-scope-gate.sh source-guards the wiring (CI-safe) + runs the agent live over a fixture
# scope when agentis is present.
if [ -x "$REPO_ROOT/dark-factory/demo-scope-gate.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-scope-gate.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: scope+eligibility gate (scope-gate.ag) (#1511)"
    else
        fail "dark-factory: scope+eligibility gate regressed (#1511)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory impact-substantiation gate (#1522) ---
# impact-gate.ag runs AFTER scope-gate and BEFORE human submit: it classifies a CONFIRMED+PoC'd finding as
# SUBSTANTIATED only when the PoC drives the impact through the protocol's OWN mechanism (not a hand-fed/simulated
# state), the loss needs no PRIVILEGED trigger, and the victim has an on-chain-provable pre-existing claim — the
# validity barrier that a live Onyx submission failed (hand-fed NAV post = front-run of a privileged action). It
# never submits. demo-impact-gate.sh source-guards the wiring (CI-safe) + runs the agent live over a fixture PoC
# when agentis is present.
if [ -x "$REPO_ROOT/dark-factory/demo-impact-gate.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-impact-gate.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: impact-substantiation gate (impact-gate.ag) (#1522)"
    else
        fail "dark-factory: impact-substantiation gate regressed (#1522)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory submission report formatter (#1508) ---
# report-writer.ag renders a confirmed finding + its PoC + the scope-gate/impact-gate/dup-scout verdicts into
# an Immunefi-shaped 4-section submission draft (Brief/Intro, Vulnerability Details, Impact Details,
# References) — the last human-gated artifact before submit. It never submits. demo-report-writer.sh
# source-guards the wiring (CI-safe) + runs the agent live over a fixture finding+PoC when agentis is present.
if [ -x "$REPO_ROOT/dark-factory/demo-report-writer.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-report-writer.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: submission report formatter (report-writer.ag) (#1508)"
    else
        fail "dark-factory: submission report formatter regressed (#1508)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory human<->federation feedback loop (#1526) ---
# deliver-submission.sh stages a report-writer draft into an operator DROP-DIRECTORY under a stable submission id
# (refusing any draft lacking the SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW human-gate marker), and feedback-intake.ag
# reads the operator-filled outcome back into learning — the platform outcome's success/failure signal is
# DETERMINISTIC from the verdict enum, attributed to the responsible gate's own learn() topic. Neither submits.
# demo-feedback-loop.sh proves delivery + the deterministic signal offline (source-guarded) + runs the agent live
# when agentis is present.
if [ -x "$REPO_ROOT/dark-factory/demo-feedback-loop.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-feedback-loop.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: human<->federation feedback loop (deliver + intake) (#1526)"
    else
        fail "dark-factory: human<->federation feedback loop regressed (#1526)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory coordinator submission-pass integration (#1509, epic #1505 capstone) ---
# coordinator.ag gains a THIRD mode (gated on PASS_ENABLED, byte-identical when unset): a fixed-order
# submission pass scope->devise->poc->impact->dup->report->HALT that threads each shipped stage's verdict into
# the next and HARD-halts on a blocking gate (scope not payable / devise no-residual / poc not finding /
# impact not substantiated), dup HIGH advisory. It NEVER submits — the terminal best case is the report-writer's
# own SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW. demo-audit-pass.sh source-guards the wiring (CI-safe) + runs the
# deterministic offline pass over PASS_FIXTURE fact-states when agentis is present.
if [ -x "$REPO_ROOT/dark-factory/demo-audit-pass.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-audit-pass.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: coordinator submission-pass integration (#1509)"
    else
        fail "dark-factory: coordinator submission-pass integration regressed (#1509)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory capability bench — deterministic safety stage (#1490) ---
# run-capability-bench.sh measures whether the discover->devise->attack->novelty pipeline surfaces an
# audit-SURVIVING bug and never re-surfaces a known one, scored against a fixture's ground truth. Its
# STAGE 1 (novelty discrimination) is deterministic and backend-free: a `boundary` restatement must be
# rejected KNOWN and the `residual` finding must pass NOVEL. That safety property gates here; the live
# STAGE 2 devise-recall (--live, needs a real LLM backend) is operator-run and never on CI.
if [ -x "$REPO_ROOT/dark-factory/bench/run-capability-bench.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/bench/run-capability-bench.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: capability bench novelty-discrimination (#1490)"
    else
        fail "dark-factory: capability bench novelty-discrimination regressed (#1490)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory corpus bench — deterministic self-test (sibling of #1490, scored against real concluded
# Sherlock contests instead of a synthetic fixture). Its default (no-flag) action is --self-test: extract-gt.sh's
# judging-README parser must byte-match a bundled fixture's expected truth.tsv. No network, no LLM. The real
# --live measurement (fetch real contests, run the real federation, score recall) is operator-run, never on CI.
if [ -x "$REPO_ROOT/dark-factory/bench/corpus-bench/run-corpus-bench.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/bench/corpus-bench/run-corpus-bench.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: corpus bench GT-extraction self-test"
    else
        fail "dark-factory: corpus bench GT-extraction self-test regressed"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory severity-first deep-hunt A/B (#1713) ---
# deep-hunt-ab.sh --self-test drives run-zone-hunt.sh over fixtures/deep-hunt/ TWICE through one --agentis
# stub (no network / LLM / forge): once breadth-only, once with --deep-hunt --invariant-fixture, and asserts
# the deep lens adds a source=invariant-hunt High finding (bench-scored a HIT via score-match.py) that the
# breadth pass missed — the ON-vs-OFF High-recall delta, proven offline. The real --live measurement is
# operator-run on an isolated non-contending zone, never on CI.
if [ -x "$REPO_ROOT/dark-factory/bench/corpus-bench/deep-hunt-ab.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/bench/corpus-bench/deep-hunt-ab.sh" --self-test 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: severity-first deep-hunt A/B self-test (#1713)"
    else
        fail "dark-factory: severity-first deep-hunt A/B self-test regressed (#1713)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory generation-recall harness (#1730) ---
# generation-recall.sh scores the GENERATOR's hypotheses (the breadth hunter's pre-refute candidates + the
# deep-hunt lens's INVARIANT|<file:fn>|<verdict> targets, verdict IGNORED) against ground truth, isolating the
# GENERATION step from fuzzer/refuter confirmation — so generation-recall > verified-recall exposes the #1716
# expressiveness gap (a CLEAN invariant that NAMED a real bug is a generation HIT the fuzzer dropped). A thin
# adapter (hypotheses-to-leads.py) projects both artifacts into the lead shape the FROZEN score-match.py
# consumes, so extract-gt.sh / score-match.py stay byte-identical. demo-generation-recall.sh source-guards the
# wiring (CI-safe, no forge/LLM) + runs the harness's --self-test and asserts the generation-vs-verified delta.
if [ -x "$REPO_ROOT/dark-factory/demo-generation-recall.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-generation-recall.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: generation-recall harness self-test (#1730)"
    else
        fail "dark-factory: generation-recall harness self-test regressed (#1730)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory invariant-hunt target-linkage gate (#1471) ---
# The invariant-hunt generation path could produce a false FINDING when the LLM substituted its own toy
# contract of the same name instead of importing the in-scope target. forge-invariant.sh gained a
# --require-import / --require-contract gate that the prover threads in ONLY in pure fresh-deploy mode; a test
# that does not import the target, or shadows it with a same-named toy, is HARNESS_ERROR before any fuzzing.
# demo-invariant-linkage.sh source-guards the wiring (CI-safe) and, when forge is present, runs the gate live.
if [ -x "$REPO_ROOT/dark-factory/demo-invariant-linkage.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-invariant-linkage.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: invariant-hunt target-linkage gate (reject substituted target, fresh-deploy-only) (#1471)"
    else
        fail "dark-factory: invariant-hunt target-linkage gate regressed (#1471)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory invariant-hunt harness-gen repair scaffold + error-context (#1720) ---
# The deep-hunt path returned HARNESS_ERROR too often because its 4 repair rounds were under-anchored: the
# canonical InvBase/targetContracts/_bound boilerplate was only described in prose (not a compiling skeleton),
# and the compile-error excerpt kept only the error TEXT, not the solc source context. invariant-prover.ag now
# injects a boilerplate-only compiling skeleton (harness_skeleton -> sharedScaffold) into the FIRST prompt AND
# re-injects it on every repair round (threaded through the repair chain), and error_excerpt keeps the
# -->/gutter/caret source-context lines. demo-invariant-repair.sh source-guards the wiring (CI-safe, no
# toolchain) + proves the widened error filter keeps that context over a canned solc error block.
if [ -x "$REPO_ROOT/dark-factory/demo-invariant-repair.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-invariant-repair.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: invariant-hunt harness-gen repair scaffold + error-context (#1720)"
    else
        fail "dark-factory: invariant-hunt harness-gen repair scaffold + error-context regressed (#1720)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory invariant-hunt audit-informed invariant seeding (#1722) ---
# The #1716 A/B isolated invariant EXPRESSIVENESS (not plumbing) as the deep-hunt limit. run-invariant-hunt.sh
# gains an optional --audit-context <file> (a target's spec / audit-scope doc); it is staged into the rundir and
# threaded to invariant-prover.ag as INV_AUDIT_CONTEXT. The prover reads it via the sandboxed cat_file and
# prepends a new audit_seed() block to the existing generate_test seed chain, steering the LLM to formalize a
# protocol-SPECIFIC value-conservation property. Purely additive (empty context => byte-identical prompt); the
# fuzzer stays the sole verdict and the #1471 linkage gate is untouched. demo-invariant-audit-seed.sh source-
# guards the wiring + proves the unreadable-context exit-2 error offline (CI-safe, no LLM/forge/agentis).
if [ -x "$REPO_ROOT/dark-factory/demo-invariant-audit-seed.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-invariant-audit-seed.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: invariant-hunt audit-informed invariant seeding (#1722)"
    else
        fail "dark-factory: invariant-hunt audit-informed invariant seeding regressed (#1722)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory invariant-hunt mutant-kill validation (#1724) ---
# The invariant-hunt track judged bugs with the forge-invariant.sh stateful fuzzer, but nothing measured
# whether a GENERATED invariant is EXPRESSIVE enough to catch real bugs (the #1716 A/B limit). #1724 adds a
# standardized, per-TARGET_CLASS MUTANT KILL-SET (evm-harness/mutants/) + a runnable harness
# (evm-harness/mutant-kill.sh) that drives each fixture through the SAME forge-invariant.sh gate and reports
# KILLED/SURVIVED (exit 1=FINDING=KILLED, 0=CLEAN=SURVIVED, 2=HARNESS_ERROR=ERROR). Each class encodes a
# three-way DISCRIMINATION (good KILLS mutant + SURVIVES clean twin, toothless SURVIVES mutant). The gate and
# its verdict/marker/#1471 contract are untouched. demo-invariant-mutant-kill.sh source-guards the fixtures +
# manifest + harness wiring (CI-safe) and, when forge is present, runs mutant-kill.sh --self-test live.
if [ -x "$REPO_ROOT/dark-factory/demo-invariant-mutant-kill.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-invariant-mutant-kill.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: invariant-hunt mutant-kill validation (kill-set + discrimination self-test) (#1724)"
    else
        fail "dark-factory: invariant-hunt mutant-kill validation regressed (#1724)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory invariant-hunt Handler adversarial/multi-actor action checklist (#1725) ---
# The #1716 A/B isolated a DELTA gap: the LLM names a plausible deep invariant but the Handler it writes never
# gives the fuzzer the ADVERSARIAL action space needed to actually break it. #1725 adds action_checklist_hint()
# / action_checklist_prompt() to invariant-prover.ag, keyed off the existing TARGET_CLASS (no new env var), a
# one-line hint woven into the Handler's Solidity comment and a fuller MUST-include checklist appended to the
# generation prompt, across 5 protocol-CLASS branches (vault/ERC4626, lending/CDP, staking, AMM, reentrancy)
# plus a generic multi-actor+perturbation default. The verdict/marker/#1471 gate contract is untouched.
# demo-invariant-handler-actions.sh source-guards the wiring + per-class coverage (CI-safe, no LLM/forge).
if [ -x "$REPO_ROOT/dark-factory/demo-invariant-handler-actions.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-invariant-handler-actions.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: invariant-hunt Handler adversarial/multi-actor action checklist (#1725)"
    else
        fail "dark-factory: invariant-hunt Handler adversarial/multi-actor action checklist (#1725)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory invariant-hunt metamorphic-relation prompt lever (#1726 M1) ---
# The #1716 A/B showed the fuzzer reaches a plausible ABSOLUTE-predicate invariant but rarely the harder-to-state
# property where the rare Highs live. #1726 M1 adds metamorphic_relation_prompt() to invariant-prover.ag (keyed
# off the existing TARGET_CLASS via class_to_keyword, no new env var) and a `=== METAMORPHIC RELATIONS ===` block
# to sharedScaffold, framing the ONE invariant as an OPTIONAL round-trip / commutativity / monotonicity relation
# (an ALTERNATIVE shape, never a second property). demo-invariant-metamorphic.sh source-guards the wiring, all 5
# per-class relation menus (plus the default), and the untouched verdict/marker/#1471 gate (CI-safe, no LLM/forge).
if [ -x "$REPO_ROOT/dark-factory/demo-invariant-metamorphic.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-invariant-metamorphic.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: invariant-hunt metamorphic-relation prompt lever (#1726 M1)"
    else
        fail "dark-factory: invariant-hunt metamorphic-relation prompt lever (#1726 M1)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory multi-contract deep-hunt wiring (#1726 M2) ---
# The composable-fresh multi-contract engine already ships end-to-end (run-invariant-hunt.sh --aux -> INV_AUX ->
# compose_fresh_seed -> multi-register targetContracts() -> #1077 both-real HARNESS_ERROR); it was just never
# REACHED from the autonomous deep-hunt path. #1726 M2 is confined to run-zone-hunt.sh: a new --deep-hunt-aux-max
# <N> flag (default 0 = OFF = byte-identical) threads a value-custody zone's SECONDARY co-custody .sol as --aux,
# REUSING the already-safety-gated engine verbatim (zero .ag / gate change). demo-invariant-multi-target.sh
# source-guards the flag/default/validation, the STAGE 4.5 aux-column emission + both invocations, the aux-max=0
# byte-identical guard, and that the reused #1077/#1471 safety path is byte-present (CI-safe, no LLM/forge).
if [ -x "$REPO_ROOT/dark-factory/demo-invariant-multi-target.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-invariant-multi-target.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: multi-contract deep-hunt wiring (#1726 M2)"
    else
        fail "dark-factory: multi-contract deep-hunt wiring (#1726 M2)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory invariant-hunt teeth-signal learning loop (#1728) ---
# The deep-hunt learned from a FINDING (persist_pattern -> invpat:latest: -> recall_pattern) but a CLEAN
# dead-ended: a TOOTHLESS invariant (too weak to break) and a CREDIBLE one (target really clean under a KILLING
# invariant) were indistinguishable. #1728 wires the #1724 mutant-kill seam in as a LEARNING signal that fires
# STRICTLY AFTER the fuzzer verdict + the INVARIANT| marker: on a CLEAN only, invariant-prover.ag runs
# mutant-kill.sh --class/--invariant in ONE shell_escape()d exec (mutant iteration stays inside the harness),
# parses the kill ratio with flat builtins, and classifies the CLEAN into credible (K>=1 -> reward `partial` +
# persist to a NEW invpat:teeth:<class> recall tier, recalled BELOW invpat:latest: so a FINDING is never
# overridden) / toothless (killed nothing -> not persisted) / unmeasured (SKIP/error/all-ERROR -> today's
# behaviour, byte-identical). run-invariant-hunt.sh stages the kill-set + threads MUTANT_KILL. The FUZZER stays
# the sole verdict; verdict_of/final_verdict/the marker/the #1471 gate + the FINDING->invpat:latest: path are
# byte-untouched. demo-invariant-teeth-learning.sh source-guards the wiring (CI-safe) and, under forge, pins the
# exact C-erc4626 kill ratios teeth_of() keys on.
if [ -x "$REPO_ROOT/dark-factory/demo-invariant-teeth-learning.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-invariant-teeth-learning.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: invariant-hunt teeth-signal learning loop (mutant-kill acceptance + invpat:teeth: tier) (#1728)"
    else
        fail "dark-factory: invariant-hunt teeth-signal learning loop regressed (#1728)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory invariant-hunt cross-run ensemble/union replay (#1731) ---
# Run-to-run variance (#1716) meant a class that produced a good invariant on one run produced nothing on the
# next, and only the WINNER's descriptor survived. #1731 accumulates EVERY generated invariant (on a FINDING OR
# a CLEAN, not only winners) and REPLAYS that accumulated UNION against a fresh target cheaply (no extra LLM).
# SEED: invariant-prover.ag's persist_corpus() writes the descriptor into a NEW lowest-precedence
# invpat:corpus:<class> recall tier in ONE O(1) memo_write (no per-element .ag loop), default-off via INV_CORPUS.
# REPLAY: run-invariant-hunt.sh keeps the full test SOURCE per class under --pattern-store/corpus/<class>/ and,
# under a default-off --replay-corpus flag, loops that BOUNDED set (content-addressed dedup + --corpus-max
# most-recent eviction) re-running the SAME staged fuzzer gate per file in pure shell — reusing the #1471 link
# gate so a foreign-import replay is HARNESS_ERROR, never a false verdict. The FUZZER stays the sole verdict;
# verdict_of/final_verdict/the marker/the #1471 gate + the FINDING->invpat:latest:/teeth paths are byte-untouched;
# default-off the pipeline is byte-identical. demo-invariant-corpus-replay.sh source-guards the wiring (CI-safe)
# and, under forge + agentis, pins >=2 replay rows + the --corpus-max cap.
if [ -x "$REPO_ROOT/dark-factory/demo-invariant-corpus-replay.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-invariant-corpus-replay.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: invariant-hunt cross-run corpus/ensemble replay (invpat:corpus: tier + runner replay loop) (#1731)"
    else
        fail "dark-factory: invariant-hunt cross-run corpus/ensemble replay regressed (#1731)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory historical-exploit-class pattern seeding (#1733) ---
# A static, offline library of 7 canonical historical DeFi exploit CLASSES (auditor/methods/
# historical-exploits.md, one entry per C1/C2/C5/C6/C8/C11/C16 taxonomy id, hand-authored, no
# scraping) generalizes the single-line --method-fixture mechanism run-autonomous-hunt.sh already
# implements: seed-historical-patterns.sh seeds each entry into invpat:invented:<class> (the SAME
# cold-start hint recall_pattern() already consults when no invpat:latest:<class> real FINDING
# exists yet), using the exact class-extraction pipeline the --method-fixture leg uses. No new
# memo namespace, no touch to invariant-prover.ag / seed-patterns.ag / run-autonomous-hunt.sh.
# demo-historical-patterns.sh source-guards the library schema (exactly 7 entries, 6 fields each,
# no class-key collision) and the seeder wiring (CI-safe) and, when agentis is present, seeds a
# throwaway pattern-store and reads back a class entry verbatim.
if [ -x "$REPO_ROOT/dark-factory/demo-historical-patterns.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-historical-patterns.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: historical-exploit-class pattern seeding (library schema + seeder wiring) (#1733)"
    else
        fail "dark-factory: historical-exploit-class pattern seeding regressed (#1733)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory concrete-exploit PoC-gen (hardhat / non-invariant foundry) (#1507) ---
# The SECOND PoC class alongside the invariant machinery: poc-writer.ag writes ONE concrete attack-SEQUENCE test
# (not a property-fuzz handler) and the toolchain-parametric gate (evm-harness/hardhat-poc.sh /
# evm-harness/forge-poc.sh) JUDGES it. A concrete PoC is written to PASS iff the exploit works, so the gate
# INVERTS the runner's polarity — a PASSING test is a FINDING, a FAILING test is CLEAN, and a compile/tooling
# error or a #1471 linkage reject is HARNESS_ERROR. demo-poc-gen.sh source-guards the wiring + exercises the
# verdict-parse over captured mocha JSON + the #1471 linkage-reject (all CI-safe, no toolchain); the full npm /
# LLM live paths are toolchain-gated and SKIP on CI.
if [ -x "$REPO_ROOT/dark-factory/demo-poc-gen.sh" ]; then
    check_out="$(bash "$REPO_ROOT/dark-factory/demo-poc-gen.sh" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "dark-factory: PoC-gen for hardhat/non-invariant classes (concrete-exploit gates, linkage, verdict-parse) (#1507)"
    else
        fail "dark-factory: PoC-gen for hardhat/non-invariant classes regressed (#1507)"
        printf '%s\n' "$check_out"
    fi
fi

# --- dark-factory --grant-pii guard on live/exec .ag invocations (#1690) ---
# The PII heuristic that blocked hunter.ag (#1675/#1676) and then zone-mapper.ag (#1690) can trip on
# ANY invocation that transmits target source / scope / findings / PoCs / persisted patterns (all benign
# public Solidity + operator-authored text — never real PII) to the model. When prompt() is blocked, a
# downstream fallback echoes the raw prompt as if it were the model's reply and the whole map->hunt->verify
# chain stalls. This guard ratchets the fix: every `agentis go <name>.ag` invocation under dark-factory/
# that carries --enable-exec or --enable-eval-ag MUST also carry --grant-pii, or an explicit
# `# no-pii: <reason>` waiver, so a fourth independent rediscovery fails CI instead of surfacing live.
# Grep-only (no agentis / no network); it also matches the `GO=(go <name>.ag ...)` array form and the
# heredoc-emitted runner string. Comment lines are skipped, and the content-free `share-patterns.ag`
# call is excluded automatically (it carries no --enable-exec).
if [ -d "$REPO_ROOT/dark-factory" ]; then
    pii_offenders=""
    # -I skips binary; iterate every .sh under dark-factory recursively.
    while IFS= read -r sh_file; do
        # For each candidate invocation line (has `go <name>.ag` AND an exec/eval flag), skip pure
        # comment lines and any line already carrying --grant-pii or a `# no-pii:` waiver; the rest fail.
        while IFS=: read -r ln_no ln_txt; do
            [ -n "$ln_no" ] || continue
            case "$ln_txt" in
                *--grant-pii*) continue ;;
                *"# no-pii:"*) continue ;;
            esac
            # Skip lines whose first non-blank character is `#` (prose/comment references).
            stripped="${ln_txt#"${ln_txt%%[![:space:]]*}"}"
            case "$stripped" in \#*) continue ;; esac
            pii_offenders="${pii_offenders}${sh_file#"$REPO_ROOT/"}:${ln_no}: ${stripped}
"
        done <<EOF
$(grep -nE 'go[[:space:]]+[A-Za-z0-9_./-]+\.ag' "$sh_file" 2>/dev/null | grep -E 'enable-exec|enable-eval-ag' || true)
EOF
    done <<EOF
$(find "$REPO_ROOT/dark-factory" -type f -name '*.sh' 2>/dev/null || true)
EOF
    if [ -z "$pii_offenders" ]; then
        pass "dark-factory: every --enable-exec/--enable-eval-ag .ag invocation carries --grant-pii (or a # no-pii: waiver) (#1690)"
    else
        fail "dark-factory: .ag invocation with --enable-exec/--enable-eval-ag is missing --grant-pii (#1690) — add --grant-pii or a '# no-pii: <reason>' waiver:"
        printf '%s' "$pii_offenders"
    fi
fi

# --- tier-branch double learn() guard (#636) ---
# Every `_publish_<role>(...)` / `_submitter_<phase>(...)` helper in
# research-foundry/ must gate its top-level `learn(..., ["emitted", ...])`
# row on `if my_tier == "propose"`. At autonomous / review-gated tiers
# the inline tier branch already emits an acted / review-gated row; an
# unconditional helper-level emitted row inflates the ACTING_TAGS row
# count 2x per tick once auto-promote starts firing.
if [ -x "$REPO_ROOT/tools/check-no-duplicate-learn.sh" ]; then
    check_out="$("$REPO_ROOT/tools/check-no-duplicate-learn.sh" "$REPO_ROOT" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "check-no-duplicate-learn: research-foundry helpers gate emitted learn() on propose tier (#636)"
    else
        fail "check-no-duplicate-learn: helper emits unconditional emitted learn() (#636)"
        printf '%s\n' "$check_out"
    fi
fi

# --- Plaintext token detection (#321) ---
# Walks `[forge.*]` sections in every colony.toml / colony.example.toml
# under the repo and flags `token` / `*api_key*` / `*secret*` values
# that are neither `secret://...` (vault-stored) nor `${VAR}` (env
# expansion). Default behaviour is WARN so legacy plaintext configs
# (the everything-pre-#321 baseline) keep CI green; set
# COLONY_LINT_STRICT_SECRETS=1 to upgrade to a hard fail.
secret_lint_findings=""
secret_lint_count=0
while IFS= read -r -d '' cfg; do
    in_forge=0
    while IFS= read -r line; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        case "$stripped" in
            \[forge.*\]*)
                # Matches both legacy `[forge.github]` and #316 M1
                # array-of-tables `[[forge.github]]` headers — the
                # trailing `*` in the glob consumes the second `]` and
                # another `[`. Scope check is intentionally loose: any
                # line under any [forge.*] table gets token-scanned.
                in_forge=1
                continue
                ;;
            \[*)
                in_forge=0
                continue
                ;;
        esac
        [ "$in_forge" = "0" ] && continue
        case "$stripped" in
            \#*) continue ;;
            "") continue ;;
        esac
        # Only inspect lines shaped like `key = "value"` where the key
        # carries token / api_key / secret in its name.
        case "$stripped" in
            token*=*|*api_key*=*|*secret*=*) ;;
            *) continue ;;
        esac
        # Strip up through the first `=` and any surrounding whitespace.
        rhs="${stripped#*=}"
        rhs="${rhs#"${rhs%%[![:space:]]*}"}"
        # Drop surrounding double quotes (single-quoted is also fine).
        case "$rhs" in
            \"*\") rhs="${rhs#\"}"; rhs="${rhs%\"*}" ;;
            \'*\') rhs="${rhs#\'}"; rhs="${rhs%\'*}" ;;
        esac
        # Empty / placeholder / template values aren't tokens — skip.
        case "$rhs" in
            ""|"<"*">"|"your-"*) continue ;;
        esac
        # Vault-stored or env-expanded values are explicitly allowed.
        case "$rhs" in
            secret://*) continue ;;
            \$\{*\}*) continue ;;
            \$*) continue ;;
        esac
        # If we got here, the value is plaintext. Only flag obvious
        # token-shaped strings (glpat-, ghp_, github_pat_) — anything
        # else is likely a placeholder or a non-secret config knob.
        case "$rhs" in
            glpat-*|ghp_*|github_pat_*)
                secret_lint_findings="${secret_lint_findings}
$cfg: plaintext token detected (consider migrating to secret:// — see dev-apprenticeship/README.md#security)"
                secret_lint_count=$((secret_lint_count + 1))
                ;;
        esac
    done < "$cfg"
done < <(find "$REPO_ROOT" -type f \( -name "colony.toml" -o -name "colony.example.toml" \) -print0 2>/dev/null)

if [ "$secret_lint_count" -eq 0 ]; then
    pass "check-secrets: no plaintext forge tokens found in colony.toml files"
elif [ "${COLONY_LINT_STRICT_SECRETS:-0}" = "1" ]; then
    fail "check-secrets: $secret_lint_count plaintext token(s) (COLONY_LINT_STRICT_SECRETS=1)"
    printf '%s\n' "$secret_lint_findings"
else
    pass "check-secrets: scan complete (warning mode — set COLONY_LINT_STRICT_SECRETS=1 to fail)"
    if [ "$secret_lint_count" -gt 0 ]; then
        printf '[WARN] %d plaintext token(s) found:\n' "$secret_lint_count"
        printf '%s\n' "$secret_lint_findings"
    fi
fi

# --- Bash-3.2 forbidden-construct lint for #321 scripts ---
# tools/secret-set.sh and tools/test-secret-resolver.sh MUST run on
# stock macOS /bin/bash (3.2). Per the issue refinement: no heredocs,
# no associative arrays, no ${var^^}/${var,,}, no mapfile/readarray.
# Greps the source for the forbidden patterns and fails on hit.
# Mirrors the check-exec-sh.sh style.
bash32_targets=""
for f in "$REPO_ROOT/tools/secret-set.sh" "$REPO_ROOT/tools/test-secret-resolver.sh"; do
    [ -f "$f" ] && bash32_targets="$bash32_targets $f"
done
if [ -n "$bash32_targets" ]; then
    bash32_findings=""
    bash32_count=0
    for f in $bash32_targets; do
        # Strip comment lines and shebang before scanning. We feed the
        # cleaned source to grep on stdin so the per-pattern check stays
        # one expression each (mirrors the simpler check-exec-sh.sh style).
        # The sed pipeline removes:
        #   - leading-#-comment lines (with optional whitespace)
        #   - inline `# ...` trailing comments after a real statement.
        # Quoted-`#` inside strings is not perfectly preserved, but for
        # this script (no `#` literals inside quoted forge tokens) the
        # heuristic is good enough.
        cleaned="$(sed -e 's/^[[:space:]]*#.*//' -e 's/[[:space:]]#[[:space:]].*//' "$f")"
        # Heredoc: `<<EOF`, `<<'EOF'`, `<<-EOF`, `<<"EOF"`.
        if printf '%s\n' "$cleaned" | grep -E '<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z_0-9]*['"'"'"]?' >/dev/null 2>&1; then
            bash32_findings="${bash32_findings}
$f: heredoc detected (forbidden under bash 3.2)"
            bash32_count=$((bash32_count + 1))
        fi
        # Associative arrays.
        if printf '%s\n' "$cleaned" | grep -E 'declare[[:space:]]+-A[[:space:]]' >/dev/null 2>&1; then
            bash32_findings="${bash32_findings}
$f: declare -A detected (associative arrays not in bash 3.2)"
            bash32_count=$((bash32_count + 1))
        fi
        # Case-flip parameter expansion: `${var^^}` / `${var,,}`.
        if printf '%s\n' "$cleaned" | grep -E '\$\{[A-Za-z_][A-Za-z_0-9]*[\^,]{1,2}\}' >/dev/null 2>&1; then
            bash32_findings="${bash32_findings}
$f: case-flip parameter expansion detected (\${var^^}/\${var,,} not in bash 3.2)"
            bash32_count=$((bash32_count + 1))
        fi
        # mapfile / readarray.
        if printf '%s\n' "$cleaned" | grep -E '\b(mapfile|readarray)\b' >/dev/null 2>&1; then
            bash32_findings="${bash32_findings}
$f: mapfile/readarray detected (not in bash 3.2)"
            bash32_count=$((bash32_count + 1))
        fi
    done
    if [ "$bash32_count" -eq 0 ]; then
        pass "check-bash32: #321 scripts free of bash-4-only constructs"
    else
        fail "check-bash32: $bash32_count bash-4-only construct(s) in #321 scripts"
        printf '%s\n' "$bash32_findings"
    fi
fi

# --- CHANGELOG consistency (#218, #252) ---
# Warn-only for feature PRs that touch any versioned component
# (dev-apprenticeship/, federation-dashboard/) without updating its
# CHANGELOG.md; hard-fail for release PRs (VERSION bumped) that skip the
# CHANGELOG bump. No-op in local runs (GITHUB_BASE_REF unset).
if [ -x "$REPO_ROOT/tools/check-changelog.sh" ]; then
    check_out="$("$REPO_ROOT/tools/check-changelog.sh" "$REPO_ROOT" 2>&1)" && check_rc=0 || check_rc=$?
    if [ "$check_rc" -eq 0 ]; then
        pass "check-changelog: CHANGELOG consistency OK"
        # Surface the [WARN] line (if any) so the operator sees the reminder
        # without the lint failing.
        if printf '%s' "$check_out" | grep -Fq "[WARN]"; then
            printf '%s\n' "$check_out"
        fi
    else
        fail "check-changelog: release PR missing CHANGELOG update"
        printf '%s\n' "$check_out"
    fi
fi

# --- Lint tools themselves ---
if command -v shellcheck &>/dev/null; then
    tools_dir="$REPO_ROOT/tools"
    if [ -d "$tools_dir" ]; then
        tool_scripts=()
        while IFS= read -r -d '' f; do
            tool_scripts+=("$f")
        done < <(find "$tools_dir" -name "*.sh" -print0 2>/dev/null)

        if [ ${#tool_scripts[@]} -gt 0 ]; then
            if shellcheck "${tool_scripts[@]}" &>/dev/null; then
                pass "tools: shellcheck OK"
            else
                fail "tools: shellcheck errors"
                # Display-only re-run (see the per-federation shellcheck
                # block): `|| true` keeps set -e/pipefail from aborting
                # the lint before the summary line.
                shellcheck "${tool_scripts[@]}" 2>&1 | head -30 || true
            fi
        fi
    fi
fi

# --- Lint federation-root scripts (#1554) ---
# Federation-root `*.sh` (e.g. dark-factory/run-audit.sh) sit outside any
# colony's `config/`-having subdirectory, so the per-colony shellcheck block
# above never sees them. Lint them here at `-S warning` (error + warning
# only), NOT the default severity used by the per-colony/tools blocks above:
# at default severity these 82 previously-unlinted scripts across 6
# federations carry ~242 findings, almost all cosmetic info/style nits — a
# separate follow-up cleanup, out of scope for #1554. `-S warning` still
# catches the class of regression #1554 asks for (unquoted expansions,
# fragile heredocs, unused vars, loop/glob footguns) without demanding a
# style-only rewrite of scripts nobody had linted before.
if command -v shellcheck &>/dev/null; then
    for fed in "${federations[@]}"; do
        fed_path="$REPO_ROOT/$fed"
        fed_root_scripts=()
        while IFS= read -r -d '' f; do
            fed_root_scripts+=("$f")
        done < <(find "$fed_path" -maxdepth 1 -name "*.sh" -print0 2>/dev/null)

        if [ ${#fed_root_scripts[@]} -gt 0 ]; then
            if shellcheck -S warning "${fed_root_scripts[@]}" &>/dev/null; then
                pass "$fed: shellcheck OK (root, -S warning)"
            else
                fail "$fed: shellcheck errors"
                # Display-only re-run (see the per-colony shellcheck block):
                # `|| true` keeps set -e/pipefail from aborting the lint
                # before the summary line.
                shellcheck -S warning "${fed_root_scripts[@]}" 2>&1 | head -30 || true
            fi
        fi
    done
else
    # CI installs shellcheck unconditionally (see .github/workflows/ci.yml),
    # so this skip only applies to local runs without shellcheck installed.
    skip "federation-root: shellcheck not installed"
fi

# --- Tools unit tests ---
test_scripts=()
while IFS= read -r -d '' f; do
    test_scripts+=("$f")
done < <(find "$REPO_ROOT/tools" -name "test-*.sh" -print0 2>/dev/null)

for t in "${test_scripts[@]}"; do
    # #272: Re-entrancy marker so test scripts that re-invoke
    # colony-lint.sh (e.g. test-colony-lint-bash32.sh test 4) can
    # detect the nested run and skip the recursive step.
    case "$(basename "$t")" in
        test-kill-endpoint.sh|test-kill-federation.sh)
            # #329: these tests exercise kill-federation.sh which sends
            # SIGTERM/SIGKILL to processes matching `agentis daemon-inner`
            # in the host's scope. Despite cwd-filter (#296), in practice
            # they still kill the operator's live federation when invoked
            # from a worktree or shared lint pipeline. Run only when
            # explicitly requested via AGENTIS_RUN_KILL_TESTS=1 (CI-only
            # in isolated environments).
            if [ "${AGENTIS_RUN_KILL_TESTS:-0}" = "1" ]; then
                if AGENTIS_COLONY_LINT_NESTED=1 bash "$t" &>/dev/null; then
                    pass "tools: $(basename "$t") unit tests"
                else
                    fail "tools: $(basename "$t") unit tests"
                    # Display-only re-run: `|| true` keeps set -e/pipefail
                    # from aborting the lint on the failing test's rc.
                    AGENTIS_COLONY_LINT_NESTED=1 bash "$t" 2>&1 | tail -20 || true
                fi
            else
                skip "tools: $(basename "$t") (destructive — set AGENTIS_RUN_KILL_TESTS=1 to run)"
            fi
            ;;
        test-boot-smoke.sh)
            # #760: spawns a real ~45s research-foundry container. Opt-in
            # only via `--boot-smoke` (handled in the dedicated block
            # below). Default discovery loop MUST NOT run it -- otherwise
            # CI workers without podman or without the image fail or
            # block on container teardown. The opt-in block below
            # invokes the script with its full output captured.
            skip "tools: $(basename "$t") (boot-level smoke — use --boot-smoke to opt in)"
            ;;
        *)
            if AGENTIS_COLONY_LINT_NESTED=1 bash "$t" &>/dev/null; then
                pass "tools: $(basename "$t") unit tests"
            else
                fail "tools: $(basename "$t") unit tests"
                # Display-only re-run: `|| true` keeps set -e/pipefail
                # from aborting the lint on the failing test's rc.
                AGENTIS_COLONY_LINT_NESTED=1 bash "$t" 2>&1 | tail -20 || true
            fi
            ;;
    esac
done

# --- Boot-level smoke (#760, opt-in via --boot-smoke) ---
# tools/test-boot-smoke.sh spawns a real research-foundry container and
# wall-clocks ~45s. Skipped by default so the lint stays fast and runnable
# on CI workers without podman. Operators MUST set the flag before merging
# any PR that touches research-foundry/tools/ or research-foundry/*/agents/*.ag
# (the substrate-touching paths #758 lived in).
if [ "$BOOT_SMOKE" = "1" ]; then
    bs="$REPO_ROOT/tools/test-boot-smoke.sh"
    if [ ! -f "$bs" ]; then
        fail "tools: test-boot-smoke.sh missing at $bs (--boot-smoke requested)"
    else
        echo ""
        echo "--- Boot-smoke (--boot-smoke set; real container, ~45s) ---"
        bs_out="$(AGENTIS_COLONY_LINT_NESTED=1 bash "$bs" 2>&1)" && bs_rc=0 || bs_rc=$?
        printf '%s\n' "$bs_out"
        if [ "$bs_rc" -eq 0 ]; then
            pass "tools: test-boot-smoke.sh"
        else
            fail "tools: test-boot-smoke.sh (exit $bs_rc)"
        fi
    fi
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
