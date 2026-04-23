#!/bin/bash
# install.sh - Set up the Dev Apprenticeship federation
#
# Checks prerequisites, copies config templates, writes GitLab
# credentials into all 5 colony configs, and optionally seeds
# agent confidence values.
#
# Usage: ./install.sh

set -e

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
COLONIES=(triage code-review planning implementation release)
ALL_AGENTS=(
    router prioritizer labeler issue_creator
    logic_reviewer style_reviewer security_reviewer test_reviewer approval_decider
    scope_estimator risk_assessor task_decomposer plan_reviewer
    code_writer test_writer refactorer commit_composer
    ship_decider changelog_writer version_bumper release_checker
)
MIN_VERSION="1.4.1"

# --- Helpers ---

info()  { printf '  %s\n' "$*"; }
ok()    { printf '  [ok] %s\n' "$*"; }
fail()  { printf '  [!!] %s\n' "$*"; }
ask()   { printf '\n  %s ' "$1"; }

# Read a prompt line, validate against a regex, re-prompt on failure.
# Usage: prompt_validated VAR_NAME "Prompt:" '^regex$' "hint shown on reject" [--secret]
prompt_validated() {
    local __var="$1" __prompt="$2" __re="$3" __hint="$4" __secret="$5"
    local __val
    while true; do
        ask "$__prompt"
        if [ "$__secret" = "--secret" ]; then
            read -rs __val
            echo ""
        else
            read -r __val
        fi
        if [ -z "$__val" ]; then
            fail "Value is required. $__hint"
            continue
        fi
        if [[ "$__val" =~ $__re ]]; then
            printf -v "$__var" '%s' "$__val"
            return 0
        fi
        fail "Invalid format. $__hint"
    done
}

check_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 found ($(command -v "$1"))"
        return 0
    else
        fail "$1 not found"
        return 1
    fi
}

# Compare two semver strings. Returns 0 if $1 >= $2.
version_gte() {
    printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n -C
}

# --- 1. Prerequisites ---

echo ""
echo "Dev Apprenticeship - Federation Setup"
echo "======================================"
echo ""
echo "Checking prerequisites..."

MISSING=0
check_cmd agentis  || MISSING=1
check_cmd python3  || MISSING=1
check_cmd git      || MISSING=1

if [ "$MISSING" -eq 1 ]; then
    echo ""
    fail "Missing prerequisites. Install them and re-run."
    echo ""
    info "agentis: https://github.com/Replikanti/agentis"
    info "python3: your system package manager"
    exit 1
fi

# Check agentis version. v1.1.6 added `--enable-exec` / `--enable-messaging`
# (required by start-colony.sh) and the #492 quarantine oscillation fix.
# v1.1.7 then fixed #499 (agentis_root walk-up), without which the watchdog
# silently falls back to a 2000 ms heartbeat timeout and kills any agent
# whose prompts take longer — on a cold Claude CLI that is every agent.
# v1.1.8 made the daemon honor `pii_transmit = allow` from config and
# added `exec.default_timeout_ms`; before that, the federation could not
# complete a single tick on any real GitLab project (issue #107) because
# every prompt containing author emails was denied and every curl past
# 10 s timed out. v1.2.2 adds `agentis daemon prune` + `effective_state`
# zombie-registry reconciliation (#518), without which an in-place binary
# upgrade SIGKILLs every watchdog and leaves the federation in a state
# where `daemon list` keeps reporting "running" for processes that no
# longer exist. v1.2.2 also fails loud at spawn when a program uses
# `recommend`/`adapt`/`score_options`/`recommend_federated`/
# `score_options_federated` without `learning.enabled = true` (#519) —
# every agent in this federation calls `recommend(...)`, so older
# builds would silently tick-error-loop forever when the three learning
# keys were not all set. Older builds either fail with `capability denied:
# exec_foreign`, never receive emit/listen, get killed by the watchdog
# every tick, fail every single tick on PII + ExecTimeout, leak zombie
# daemons after every upgrade, or silently tick-error on adaptive calls.
# v1.4.0 added the `tier()` builtin (#539) that all 21 agents branch on
# for the four-tier confidence gating defined in ADR-0001; older builds
# crash at parse time on every `.ag` file in this repo. v1.4.1 then
# fixed `learn()` to populate `fitness_delta` from the `outcome`
# argument (Success=+0.15, Partial=+0.02, Timeout=-0.05,
# Failure=-0.15, Error=-0.15) instead of hardcoding 0.0 (#542). Without
# that fix, every experience row carries `delta=0`, which makes the
# auto-promote `delta_slope_acting` gate (#186) a no-op, the dashboard
# evolve flat-slope threshold (#163) uncalibratable, and any
# consumer reading `delta` from `.agentis/experience/*.jsonl` blind to
# failure vs. success.
AGENTIS_VERSION=$(agentis --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
info "agentis version: $AGENTIS_VERSION (minimum: $MIN_VERSION)"

if ! version_gte "$AGENTIS_VERSION" "$MIN_VERSION"; then
    fail "agentis >= $MIN_VERSION required (tier() builtin for four-tier confidence gating; fitness_delta wiring from the outcome argument to learn()). Please update."
    exit 1
fi

# --- 2. Copy configs ---

echo ""
echo "Setting up colony configs..."

CONFIGS_EXISTED=0
for colony in "${COLONIES[@]}"; do
    CONFIG_DIR="$SCRIPT_DIR/$colony/config"
    if [ -f "$CONFIG_DIR/colony.toml" ]; then
        info "$colony: colony.toml already exists"
        CONFIGS_EXISTED=$((CONFIGS_EXISTED + 1))
    else
        cp "$CONFIG_DIR/colony.example.toml" "$CONFIG_DIR/colony.toml"
        ok "$colony: created colony.toml"
    fi
done

if [ "$CONFIGS_EXISTED" -eq 5 ]; then
    echo ""
    ask "All configs already exist. Overwrite with fresh templates? [y/N]:"
    read -r OVERWRITE
    if [ "$OVERWRITE" = "y" ] || [ "$OVERWRITE" = "Y" ]; then
        for colony in "${COLONIES[@]}"; do
            cp "$SCRIPT_DIR/$colony/config/colony.example.toml" "$SCRIPT_DIR/$colony/config/colony.toml"
            ok "$colony: overwritten"
        done
    else
        info "Keeping existing configs. GitLab credentials will be updated."
    fi
fi

# --- 3a. Forge backend selection (ADR-0002, #256) ---

echo ""
echo "Forge backend"
echo "============="
echo "All 5 colonies connect to the same forge (GitLab or GitHub)."
echo ""

# FEDERATION_FORGE_TYPE env var short-circuits the prompt for unattended
# installs. Anything other than "gitlab" / "github" is rejected.
if [ -n "${FEDERATION_FORGE_TYPE:-}" ]; then
    case "$FEDERATION_FORGE_TYPE" in
        gitlab|github)
            FORGE_TYPE="$FEDERATION_FORGE_TYPE"
            info "FEDERATION_FORGE_TYPE=$FORGE_TYPE (unattended selection)"
            ;;
        *)
            fail "FEDERATION_FORGE_TYPE must be 'gitlab' or 'github' (got '$FEDERATION_FORGE_TYPE')"
            exit 1
            ;;
    esac
else
    # Interactive prompt; default is "gitlab" for PR 1 parity with pre-#256
    # installs. The full GitHub backend (per-colony github-api.sh wrappers,
    # .ag agent audits) ships across PRs 2-6 of #256. Selecting "github"
    # now is supported for config scaffolding; at runtime forge-api.sh
    # returns exit 99 with a clear pointer to the ADR until the per-colony
    # wrappers land.
    ask "Forge backend [1] GitLab (default)  [2] GitHub:"
    read -r FORGE_CHOICE
    case "$FORGE_CHOICE" in
        2|github|GitHub|GITHUB) FORGE_TYPE="github" ;;
        *)                       FORGE_TYPE="gitlab" ;;
    esac
fi

if [ "$FORGE_TYPE" = "github" ]; then
    echo ""
    fail "GitHub backend selected."
    info "Foundation (ADR-0002 + config schema + forge-api.sh dispatcher)"
    info "is available from PR 1 of issue #256. Per-colony github-api.sh"
    info "wrappers ship in PRs 2-6; at runtime, forge-api.sh currently"
    info "exits 99 for FORGE_TYPE=github. Track progress at:"
    info "  https://github.com/Replikanti/agentis-colonies/issues/256"
    echo ""
    ask "Continue with GitHub scaffolding anyway? [y/N]:"
    read -r CONTINUE_GITHUB
    case "$CONTINUE_GITHUB" in
        y|Y|yes|YES) info "Proceeding with GitHub scaffolding." ;;
        *)
            info "Aborting install. Re-run and select GitLab, or wait for PRs 2-6 of #256."
            exit 0
            ;;
    esac
fi

# --- 3. GitLab credentials ---

echo ""
echo "GitLab configuration"
echo "All 5 colonies connect to the same GitLab project."
echo ""

# Separate prompt for credentials. The existing "overwrite templates"
# prompt only controls colony.example.toml -> colony.toml copies; it
# does not gate credential writes. If the operator re-runs install.sh
# purely to rotate the PAT (or to update url/project), we must still
# prompt before silently overwriting — otherwise a typo at the URL
# prompt corrupts 5 working configs with no recovery path other than
# redoing the install. See #116 gap 5.
WRITE_CREDS=1
if [ "$CONFIGS_EXISTED" -eq 5 ]; then
    ask "Update GitLab credentials in existing configs? [Y/n]:"
    read -r UPDATE_CREDS
    case "$UPDATE_CREDS" in
        n|N)
            WRITE_CREDS=0
            info "Keeping existing GitLab credentials. Skipping prompts."
            ;;
    esac
fi

if [ "$WRITE_CREDS" -eq 1 ]; then
    # URL char class includes `_` because corporate self-hosted DNS
    # routinely uses underscores in hostnames (RFC-noncompliant but
    # widespread) — rejecting them was a regression in PR #122 v1.
    prompt_validated GITLAB_URL \
        "GitLab URL (e.g. https://gitlab.com):" \
        '^https?://[A-Za-z0-9._-]+(:[0-9]+)?(/.*)?$' \
        "Must start with http:// or https://"

    # Project regex accepts group/project AND subgroup nesting
    # (group/subgroup/.../project) because GitLab Premium lets you
    # nest groups and start-colony.sh already URL-encodes the whole
    # path to %2F before calling the API. The earlier "exactly two
    # segments" form in PR #122 v1 rejected valid GitLab paths.
    prompt_validated GITLAB_PROJECT \
        "GitLab project path (e.g. my-org/my-project or group/subgroup/project):" \
        '^[^/[:space:]]+(/[^/[:space:]]+)+$' \
        "Must be at least group/project, segments separated by / with no whitespace or empty segments."

    prompt_validated GITLAB_TOKEN \
        "GitLab personal access token (glpat-...):" \
        '^glpat-[A-Za-z0-9_-]+$' \
        "Must start with 'glpat-' followed by the token body." \
        --secret

    # #104: operator GitLab username for personal/team knowledge
    # tagging. Optional — if left blank, agents tag everything as
    # "team" (pre-#104 behavior). The regex matches GitLab's username
    # rules (alphanumeric, dots, dashes, underscores, minimum 2 chars).
    ask "Your GitLab username for personal/team knowledge tagging (optional, press Enter to skip):"
    read -r GITLAB_ME
    if [ -n "$GITLAB_ME" ] && ! [[ "$GITLAB_ME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]+$ ]]; then
        fail "Invalid GitLab username. Must be alphanumeric with . _ - (no leading special char)."
        GITLAB_ME=""
    fi

    echo ""
    echo "Writing credentials to colony configs..."

    for colony in "${COLONIES[@]}"; do
        CONFIG="$SCRIPT_DIR/$colony/config/colony.toml"
        # Write credentials by matching TOML keys (works on both fresh and existing configs).
        # The credential substitutions also hit the [forge.gitlab] block (same key names)
        # so [gitlab] and [forge.gitlab] stay in sync during the migration overlap.
        python3 - "$CONFIG" "$GITLAB_URL" "$GITLAB_TOKEN" "$GITLAB_PROJECT" "$GITLAB_ME" "$FORGE_TYPE" <<'PY'
import sys, re
path, url, token, project, me, forge_type = sys.argv[1:7]
with open(path) as f:
    content = f.read()
content = re.sub(r'(url\s*=\s*)"[^"]*"', lambda m: m.group(1) + '"' + url + '"', content)
content = re.sub(r'(token\s*=\s*)"[^"]*"', lambda m: m.group(1) + '"' + token + '"', content)
content = re.sub(r'(project\s*=\s*)"[^"]*"', lambda m: m.group(1) + '"' + project + '"', content)
# #104: `me` key. Only update if the template declared one; do not
# inject into existing configs that predate #104 (operator can add
# it manually if they want personal/team tagging). Anchor with ^ +
# line flag so `name = ` / `some = ` don't match.
content = re.sub(r'(?m)^(me\s*=\s*)"[^"]*"', lambda m: m.group(1) + '"' + me + '"', content)
# #256: [forge].type selects the active backend. Section-scoped rewrite
# so the literal key `type = "..."` inside [forge] is the only one
# touched (there is no ambiguity today, but future sections may reuse
# the word `type` and we want to fail loudly if that ever happens).
def _set_forge_type(content, value):
    lines = content.splitlines(keepends=True)
    in_forge = False
    out = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('[') and stripped.endswith(']'):
            sect = stripped[1:-1].strip()
            in_forge = (sect == 'forge')
        if in_forge and re.match(r'\s*type\s*=\s*"[^"]*"', line):
            line = re.sub(r'(type\s*=\s*)"[^"]*"', lambda m: m.group(1) + '"' + value + '"', line, count=1)
        out.append(line)
    return ''.join(out)
content = _set_forge_type(content, forge_type)
with open(path, 'w') as f:
    f.write(content)
PY
        ok "$colony"
        chmod 600 "$CONFIG" 2>/dev/null || \
            info "$colony: could not chmod 600 $CONFIG (filesystem may not support it)"
    done
fi

# --- 4. Initialize agentis (if not already done) ---
#
# Always run `agentis init` from the federation root (parent of SCRIPT_DIR),
# not from the operator's cwd. If we used cwd, `bash /path/to/install.sh`
# invoked from anywhere outside the federation would create a new empty
# `.agentis/` next to the caller (e.g. in $HOME), and the lifecycle +
# config-writing blocks below would then configure *that* directory
# instead of the federation's.

FED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ""
if [ -d "$FED_ROOT/.agentis" ]; then
    info "agentis already initialized"
else
    echo "Initializing agentis..."
    (cd "$FED_ROOT" && agentis init 2>/dev/null) || true
    ok "agentis init"
fi

# Enable lifecycle tracking (required for colony health/ps). Resolve
# AGENTIS_DIR to an absolute path so downstream blocks (symlink target,
# config path) never depend on the invoker's cwd.
AGENTIS_DIR="$FED_ROOT/.agentis"

if [ -d "$AGENTIS_DIR" ]; then
    mkdir -p "$AGENTIS_DIR/lifecycle"
    ok "lifecycle tracking enabled"

    # Write the defaults that every colony in this federation needs.
    #
    # These keys are not set by `agentis init`; without them a fresh checkout
    # of dev-apprenticeship cannot complete a single tick on a real LLM
    # backend (see Replikanti/agentis-colonies#88 for the full debug
    # transcript). Each key is only written if missing so re-running
    # install.sh is idempotent and never clobbers operator-tuned values.
    #
    #   daemon.tick_interval_ms     — 60000ms safe default. start-colony.sh
    #                                 now sets per-agent intervals via CLI
    #                                 (#146: reactive agents at 180000-
    #                                 300000ms, active agents keep 60000),
    #                                 so the CLI flag always wins at startup.
    #                                 This config entry is defense-in-depth
    #                                 for operators who launch a daemon
    #                                 directly (e.g. debug sessions), where
    #                                 without the config key the watchdog
    #                                 uses the 1 s default.
    #   daemon.heartbeat_interval_ms — 3× tick is long enough for a
    #                                  Claude CLI cold start (typ. 5-30 s).
    #                                  Default 2× tick is fine for mock,
    #                                  but kills real-LLM agents mid-tick.
    #   daemon.cb_per_tick          — 2000 covers ~40 prompt() calls per
    #                                 tick. Default 100 overflows on the
    #                                 first prompt (50 CB each) and makes
    #                                 the agent look unhealthy from tick 1.
    #   experience.enabled          — learn() is a no-op without this;
    #                                 daemons throw "experience not
    #                                 enabled" on every tick.
    #   exec.env_passthrough        — agentis strips the env before running
    #                                 `exec sh`. Agents need COLONY_DIR
    #                                 (to resolve $COLONY_DIR/scripts/...
    #                                 paths) and GITLAB_* (so gitlab-api.sh
    #                                 authenticates against the instance
    #                                 configured by start-colony.sh).
    #   exec.default_timeout_ms     — gitlab-api.sh calls curl with a
    #                                 per-attempt `--max-time` of
    #                                 `$GITLAB_CURL_MAX_TIME` (default
    #                                 90 s, see #115/#117). The agentis
    #                                 default 10 s exec-sh timeout — and
    #                                 even the previous 45 s bump —
    #                                 would SIGKILL curl mid-response.
    #                                 120 s gives a single 90 s attempt
    #                                 its full budget plus 30 s of
    #                                 process spawn / JSON-parse / first
    #                                 retry-backoff headroom. Operators
    #                                 who lean on the retry loop for
    #                                 slow endpoints can raise this via
    #                                 the generated `.agentis/config`.
    #   pii_transmit                — GitLab API payloads always contain
    #                                 author/assignee emails and phone-
    #                                 shaped numbers in descriptions.
    #                                 Without this grant the PII guard
    #                                 denies every prompt() on the first
    #                                 tick and the federation never makes
    #                                 progress. Only honored by the daemon
    #                                 path from agentis v1.1.8 onward.
    #   learning.enabled +           triage/router and triage/prioritizer
    #   knowledge.enabled             (and several code-review agents) call
    #                                 recommend() from the adaptive engine
    #                                 on every tick. In agentis-core
    #                                 (evaluator/mod.rs:8093), recommend()
    #                                 requires all three of adaptive_engine
    #                                 (gated by learning.enabled), the
    #                                 experience_store (gated by
    #                                 experience.enabled — already above),
    #                                 AND the knowledge_base (gated by
    #                                 knowledge.enabled). Missing any one
    #                                 aborts the tick with a different
    #                                 "<component> not enabled" message.
    #                                 Setting only learning.enabled would
    #                                 flip the error from "adaptive engine
    #                                 not enabled" (issue #110) to
    #                                 "knowledge base not enabled" on the
    #                                 very next tick, so we write both.
    AGENTIS_CONFIG="$AGENTIS_DIR/config"
    # Agentis init should have created this; create it explicitly so the
    # key-writing below is not silently skipped if init was interrupted.
    if [ ! -f "$AGENTIS_CONFIG" ]; then
        touch "$AGENTIS_CONFIG"
        info "created $AGENTIS_CONFIG"
    fi
    write_key() {
        local key="$1"
        local value="$2"
        # Idempotent upsert of `<key> = <value>` in `<AGENTIS_CONFIG>`.
        # The grep pattern `^<escaped-key>[[:space:]]*=` requires a
        # whitespace-or-equals boundary right after the key, so keys that
        # are proper prefixes of other keys (e.g. `daemon.tick_interval`
        # vs `daemon.tick_interval_ms`) do not collide: the `_` in
        # `_ms = ...` is neither whitespace nor `=`. If a future key is
        # added whose name ends in `[[:space:]=]`, revisit this guarantee.
        # POSIX `[[:space:]]` keeps the pattern portable to BSD grep
        # (macOS) where `\s` is treated as a literal `s`.
        local grep_key
        grep_key=$(printf '%s' "$key" | sed 's/\./\\./g')
        if ! grep -q "^${grep_key}[[:space:]]*=" "$AGENTIS_CONFIG" 2>/dev/null; then
            printf '%s = %s\n' "$key" "$value" >> "$AGENTIS_CONFIG"
            ok "$key = $value"
        else
            info "$key already configured"
        fi
    }
    write_key 'federation.enabled'           'true'
    write_key 'knowledge.federation_enabled' 'true'
    write_key 'daemon.tick_interval_ms'      '60000'
    write_key 'daemon.heartbeat_interval_ms' '180000'
    write_key 'daemon.cb_per_tick'           '2000'
    write_key 'experience.enabled'           'true'
    write_key 'exec.env_passthrough'         'COLONY_DIR,GITLAB_*'
    write_key 'exec.default_timeout_ms'      '120000'
    write_key 'pii_transmit'                 'allow'
    write_key 'knowledge.enabled'            'true'
    write_key 'learning.enabled'             'true'

    # Lock down the federation config alongside colony.toml. No secrets
    # are written here today, but llm.* keys operators add manually may
    # include api-key env names or inline tokens.
    chmod 600 "$AGENTIS_CONFIG" 2>/dev/null || true
fi

# Create per-colony .agentis symlinks so commands run from a colony dir
# (e.g. `agentis doctor`) find the federation's .agentis instead of
# spawning a divergent empty one in cwd (see issue #88 body, part 2).
if [ -d "$AGENTIS_DIR" ]; then
    for colony in "${COLONIES[@]}"; do
        COLONY_AGENTIS="$SCRIPT_DIR/$colony/.agentis"
        if [ -L "$COLONY_AGENTIS" ] && [ ! -e "$COLONY_AGENTIS" ]; then
            # Dangling symlink (target moved or removed). Re-point it.
            ln -sfn "$AGENTIS_DIR" "$COLONY_AGENTIS"
            ok "$colony/.agentis -> $AGENTIS_DIR (repaired dangling symlink)"
        elif [ -L "$COLONY_AGENTIS" ]; then
            info "$colony/.agentis symlink already present"
        elif [ -e "$COLONY_AGENTIS" ]; then
            # Real directory found — likely a divergent empty .agentis from
            # a past `agentis doctor` run in cwd. Leave it alone; operator
            # should inspect and remove manually.
            fail "$colony/.agentis exists and is not a symlink — skipping (remove manually if empty)"
        else
            ln -s "$AGENTIS_DIR" "$COLONY_AGENTIS"
            ok "$colony/.agentis -> $AGENTIS_DIR"
        fi
    done
fi

# --- 5. Seed confidence ---

echo ""
echo "Agent confidence seeding"
echo ""
echo "Agents start silent (confidence = 0.0). You choose the starting tier:"
echo ""
echo "  0.4  - shadow (recommended, observe-only; see ADR-0001)"
echo "  0.6  - propose (emit suggestions on the bus)"
echo "  0.8  - review-gated (draft external writes under human review)"
echo "  0.95 - autonomous (terminal writes without a second gate)"
echo "  skip - Do not seed, configure manually later"
echo ""

ask "Starting confidence [0.4]:"
read -r CONFIDENCE
CONFIDENCE="${CONFIDENCE:-0.4}"

if [ "$CONFIDENCE" != "skip" ]; then
    # Validate: must be a number between 0.0 and 1.0
    if ! python3 -c "v=float('$CONFIDENCE'); assert 0.0 <= v <= 1.0" 2>/dev/null; then
        fail "Invalid confidence value: $CONFIDENCE (must be 0.0 to 1.0)"
        exit 1
    fi
    echo ""
    echo "Seeding all 21 agents at $CONFIDENCE..."
    # #173 / #176: idempotent seeding. Never downgrade an existing memo
    # value — an operator may have deliberately promoted an agent before
    # re-running install.sh. Only write when the memo is missing or its
    # value is strictly below the new seed.
    SEED_FAILED=0
    SEED_KEPT=0
    SEED_WROTE=0
    for agent in "${ALL_AGENTS[@]}"; do
        existing="$(agentis memo get "${agent}:confidence" 2>/dev/null || true)"
        keep=0
        if [ -n "$existing" ]; then
            if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)" "$existing" "$CONFIDENCE" 2>/dev/null; then
                keep=1
            fi
        fi
        if [ "$keep" -eq 1 ]; then
            SEED_KEPT=$((SEED_KEPT + 1))
        else
            if ! agentis memo set "${agent}:confidence" "$CONFIDENCE" 2>/dev/null; then
                fail "Failed to seed ${agent}:confidence"
                SEED_FAILED=1
            else
                SEED_WROTE=$((SEED_WROTE + 1))
            fi
        fi
    done
    if [ "$SEED_FAILED" -eq 1 ]; then
        fail "Some seeds failed. Is agentis initialized? Try: agentis init"
    else
        ok "Seeded $SEED_WROTE agents at $CONFIDENCE (kept $SEED_KEPT already at or above)"
    fi
fi

# --- 5b. Seed operator identity for personal/team tagging (#104) ---
#
# Agents read `gitlab:me` via recall_latest() to classify learned
# activity as `personal` (operator's own) vs `team`. Seeding here
# (rather than requiring a memo set step post-install) keeps all
# identity wiring in one place.
if [ -n "${GITLAB_ME:-}" ]; then
    echo ""
    (cd "$FED_ROOT" && agentis memo set gitlab:me "$GITLAB_ME" 2>/dev/null) \
        && ok "Seeded gitlab:me = $GITLAB_ME" \
        || fail "Failed to seed gitlab:me (agents will tag everything as 'team')"
fi

# --- 6. LLM backend ---

echo ""
echo "LLM backend"
echo ""
info "Agentis needs an LLM backend configured in .agentis/config."
info "Examples:"
echo ""
echo "    # Claude via CLI"
echo "    llm.backend = cli"
echo "    llm.command = claude"
echo ""
echo "    # Ollama (local)"
echo "    llm.backend = http"
echo "    llm.endpoint = http://localhost:11434/v1/chat/completions"
echo "    llm.model = llama3"
echo ""
echo "    # Any OpenAI-compatible API"
echo "    llm.backend = http"
echo "    llm.endpoint = https://api.example.com/v1/chat/completions"
echo "    llm.api_key_env = MY_API_KEY"
echo ""

# --- 7. Auto-promote scheduling (#148 / #216) ---
#
# `tools/auto-promote.sh` needs periodic invocation to do its job
# (classify experience rows, promote agents up the tier ladder,
# trigger evolution). Instead of splicing a crontab entry that would
# outlive the federation, we persist the operator's preference in a
# federation-scoped TOML file. `start-federation.sh` reads it on
# startup and spawns a sidecar loop that dies when the federation is
# torn down. No state lingers system-wide.

echo ""
echo "Auto-promote scheduling"
echo ""
info "tools/auto-promote.sh (#148) promotes agents up the tier ladder and"
info "triggers evolution when acting-row fitness passes configured thresholds."
info "It needs periodic invocation."
info ""
info "If enabled, start-federation.sh spawns a sidecar that runs it every 30 min"
info "while the federation is up. The sidecar dies when the federation is torn"
info "down (Ctrl-C, kill-federation.sh) — no lingering crontab entry."
info ""
info "Note: dry_run: true is the default in tools/auto-promote-config.yaml, so"
info "nothing actually acts until you flip it."

AUTO_PROMOTE_INSTALL_FILE="$SCRIPT_DIR/.auto-promote-install.toml"

ask "Enable auto-promote scheduling? [Y/n]:"
read -r AUTO_PROMOTE_ANSWER
AUTO_PROMOTE_ANSWER="${AUTO_PROMOTE_ANSWER:-Y}"

case "$AUTO_PROMOTE_ANSWER" in
    [Yy]|[Yy][Ee][Ss])
        mkdir -p "$SCRIPT_DIR/.agentis/logs"
        cat > "$AUTO_PROMOTE_INSTALL_FILE" <<'EOF'
# Auto-promote scheduler settings (#148 / #216).
#
# Written by dev-apprenticeship/install.sh. Read by start-federation.sh
# to decide whether to spawn the scheduler sidecar. Re-run install.sh
# to change your mind.
[auto_promote]
enabled = true
interval_s = 1800
EOF
        ok "Scheduling enabled — sidecar will run every 30 min once federation is up."
        ok "Log: .agentis/logs/auto-promote.log"
        info "Reminder: dry_run: true is still on in auto-promote-config.yaml."
        ;;
    *)
        cat > "$AUTO_PROMOTE_INSTALL_FILE" <<'EOF'
# Auto-promote scheduler settings (#148 / #216).
#
# Written by dev-apprenticeship/install.sh. Set enabled = true and
# re-run install.sh to enable scheduling later.
[auto_promote]
enabled = false
interval_s = 1800
EOF
        ok "Scheduling disabled. Re-run ./install.sh and answer Y to enable later."
        ;;
esac

# --- 8. Federation dashboard (separately-versioned standalone) ---
#
# The dashboard was extracted to its own component in #252. This step
# offers to download and install the version pinned by this federation
# (.dashboard-version, kept in sync with federation-dashboard releases).
# The dashboard is optional: the federation runs without it. Skip with
# FEDERATION_DASHBOARD_SKIP=1 in the environment.

DASHBOARD_PIN_FILE="$SCRIPT_DIR/.dashboard-version"
if [ -f "$DASHBOARD_PIN_FILE" ]; then
    DASHBOARD_PIN="$(tr -d '[:space:]' < "$DASHBOARD_PIN_FILE")"
else
    DASHBOARD_PIN=""
fi

DASHBOARD_TAG="federation-dashboard-v${DASHBOARD_PIN}"
DASHBOARD_TARBALL="federation-dashboard-v${DASHBOARD_PIN}.tar.gz"
DASHBOARD_URL="https://github.com/Replikanti/agentis-colonies/releases/download/${DASHBOARD_TAG}/${DASHBOARD_TARBALL}"

echo ""
echo "Federation dashboard"
echo ""

if [ -z "$DASHBOARD_PIN" ]; then
    info "No .dashboard-version pin found. Skipping dashboard install."
    info "Install manually later from https://github.com/Replikanti/agentis-colonies/releases"
elif [ "${FEDERATION_DASHBOARD_SKIP:-0}" = "1" ]; then
    info "FEDERATION_DASHBOARD_SKIP=1 — skipping dashboard install."
    info "Re-run ./install.sh without that env var to install later."
else
    info "The dashboard is a separately-versioned standalone component (#252)."
    info "This federation pins federation-dashboard v${DASHBOARD_PIN}."
    info "Default install: \${XDG_DATA_HOME:-\$HOME/.local/share}/federation-dashboard/"
    info "                 + symlink at \${XDG_BIN_HOME:-\$HOME/.local/bin}/federation-dashboard"

    ask "Install federation-dashboard v${DASHBOARD_PIN} now? [Y/n]:"
    read -r DASHBOARD_ANSWER
    DASHBOARD_ANSWER="${DASHBOARD_ANSWER:-Y}"

    case "$DASHBOARD_ANSWER" in
        [Yy]|[Yy][Ee][Ss])
            if ! command -v curl >/dev/null 2>&1; then
                fail "curl not found — cannot download dashboard tarball."
                info "Install curl, or fetch the tarball manually from $DASHBOARD_URL"
            else
                DASHBOARD_TMP="$(mktemp -d)"
                trap 'rm -rf "$DASHBOARD_TMP"' EXIT
                info "Downloading $DASHBOARD_URL"
                if ! curl -fsSL -o "$DASHBOARD_TMP/$DASHBOARD_TARBALL" "$DASHBOARD_URL"; then
                    fail "Download failed. Skipping dashboard install."
                    info "Install manually later: see federation-dashboard/README.md"
                elif ! tar -xzf "$DASHBOARD_TMP/$DASHBOARD_TARBALL" -C "$DASHBOARD_TMP"; then
                    fail "Extract failed. Skipping dashboard install."
                else
                    DASHBOARD_EXTRACTED="$DASHBOARD_TMP/federation-dashboard-v${DASHBOARD_PIN}"
                    if [ ! -x "$DASHBOARD_EXTRACTED/install.sh" ]; then
                        fail "Tarball did not contain expected install.sh — skipping."
                    elif ! "$DASHBOARD_EXTRACTED/install.sh"; then
                        fail "federation-dashboard install.sh exited non-zero."
                    else
                        ok "federation-dashboard v${DASHBOARD_PIN} installed."
                        ok "Run: ./dashboard.sh"
                    fi
                fi
                rm -rf "$DASHBOARD_TMP"
                trap - EXIT
            fi
            ;;
        *)
            info "Skipping dashboard install."
            info "To install later, fetch and run install.sh from:"
            info "  $DASHBOARD_URL"
            ;;
    esac
fi

# --- Done ---

echo ""
echo "======================================"
echo "Setup complete."
echo ""
echo "Start the federation:"
echo "  ./start-federation.sh"
echo ""
echo "Or start individual colonies:"
for colony in "${COLONIES[@]}"; do
    echo "  ./$colony/scripts/start-colony.sh"
done
echo ""
echo "Monitor:"
echo "  agentis daemon list"
echo ""
