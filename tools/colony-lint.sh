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
                    shellcheck "${sh_files[@]}" 2>&1 | head -30
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
                    --tick-interval|--cb-per-tick|--colony|--deadline|--priority|--enable-migration|--enable-replication|--allow-replica-replication|--enable-exec|--enable-messaging|--deny-exec|--config-override|--help|-h) ;;
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
                shellcheck "${tool_scripts[@]}" 2>&1 | head -30
            fi
        fi
    fi
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
                    AGENTIS_COLONY_LINT_NESTED=1 bash "$t" 2>&1 | tail -20
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
                AGENTIS_COLONY_LINT_NESTED=1 bash "$t" 2>&1 | tail -20
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
