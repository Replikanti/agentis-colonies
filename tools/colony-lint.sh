#!/bin/bash
# colony-lint.sh: validates colony structure, config, and scripts
#
# Autodiscovers federations and colonies in the repo.
# Exit code 0 = all checks pass, 1 = one or more failures.
#
# Usage: ./tools/colony-lint.sh [path-to-repo-root]

set -euo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PASS=0
FAIL=0
SKIP=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; SKIP=$((SKIP + 1)); }

# --- Discover federations ---
# A federation is a top-level directory with a README.md, excluding dotdirs and tools.
federations=()
for dir in "$REPO_ROOT"/*/; do
    name="$(basename "$dir")"
    case "$name" in
        .*|tools) continue ;;
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
        if [ -f "$config" ]; then
            toml_errors=$(python3 -c "
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib

with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)

errors = []
if 'colony' not in data:
    errors.append('missing [colony] section')
if 'gitlab' not in data:
    errors.append('missing [gitlab] section')
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

    for fed in "${federations[@]}"; do
        for dir in "$REPO_ROOT/$fed"/*/; do
            [ -d "$dir/config" ] || continue
            colony="$(basename "$dir")"
            ag_files=()
            while IFS= read -r -d '' f; do
                ag_files+=("$f")
            done < <(find "$dir/agents" -name "*.ag" -print0 2>/dev/null)

            if [ ${#ag_files[@]} -gt 0 ]; then
                for ag in "${ag_files[@]}"; do
                    if (cd "$lint_tmp" && agentis commit "$ag") &>/dev/null; then
                        pass "$fed/$colony: $(basename "$ag") syntax OK"
                    else
                        fail "$fed/$colony: $(basename "$ag") syntax error"
                    fi
                done
            fi
        done
    done
else
    skip "agentis validation (binary not found)"
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

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
