#!/bin/bash
# run-stage3-docker.sh — Docker-based Stage 3 multinode orchestrator (#439).
#
# Sibling-alternative to run-stage3-multinode.sh. Where the SSH variant
# drives a real laptop+server pair through an SSH master channel + a
# port-forward, this orchestrator boots two podman containers on the
# same host and federates them via podman's host loopback bridge
# (host.containers.internal). Same tribe split (2 laptop / 3 server),
# same target rotation, same death threshold, same OpenAI backend
# defaults; the SSH variant remains untouched for later operator use.
#
# Why Docker: nine SSH-tier network events in one pilot night (race on
# remote serve.pid mkdir, login-shell PATH lookup miss, rsync push
# colliding with the federation's own write of bug-ledger.jsonl, ...)
# pushed us to a fully local 2-container shape that exercises the same
# federation surface without the SSH surface area. The SSH-based pilot
# is still the production target for the cross-host shape; this
# orchestrator is the dev/iteration loop.
#
# Tribe split rationale: 2-on-laptop / 3-on-server reflects the
# operator's typical resource asymmetry. We preserve that split here so
# telemetry produced by Docker pilots is comparable to the SSH variant's
# output by row-shape (2 + 3 tribe rows, same per-node `node` column in
# telemetry-combined.csv).
#
# Containers communicate via podman's `host.containers.internal` alias,
# which resolves to the host's loopback bridge (10.0.2.2 / equivalent on
# rootless podman). Each container runs an `agentis serve` on a host-
# mapped port (laptop 9100 → host 9100, server 9101 → host 9101); their
# federation.peers list contains the OTHER node's host port via that
# alias so reachability is symmetric.
#
# Env vars:
#   STAGE3_WALL_CLOCK_S        Wall-clock cap in seconds. Default: 21600
#                              (6h full pilot). 30-min smoke runs at 1800.
#   STAGE3_ROTATION_INTERVAL_S Seconds between TARGET_DIR rotations.
#                              Default: 600 (10 min); bumped from 1200
#                              in #544 chunk 2 because the 10-target
#                              rotation (A..J) needs shorter dwell to
#                              cycle through all targets inside a 6h
#                              smoke run.
#   STAGE3_DEATH_THRESHOLD     CB level at which a hunter is culled.
#                              Default: 300 (Stage 2 was 100).
#   STAGE3_TRIBE_POOL_CAP      #485 finite-pool: max value of the
#                              shared tribe pool. Bounds reward credit;
#                              when pool == cap, additional TPs yield 0
#                              reward (zero-sum competition). Default 0
#                              = OFF (legacy uncapped pool).
#   STAGE3_TRIBE_METABOLIC_COST  #485 finite-pool: per-tick CB drain
#                              from shared tribe pool, paid by every
#                              hunter just for existing. Creates
#                              carrying-capacity pressure (more hunters
#                              = more drain). Default 0 = OFF.
#   STAGE3_TRIBE_INITIAL_POOL  #487 finite-pool follow-up: starting
#                              capital for the shared tribe pool. Lets
#                              tribes accumulate replication budget
#                              before metabolic drain or DEATH_THRESHOLD
#                              culls them. Default 20000 (#544 chunk 2);
#                              bumped from 0 to give each tribe a
#                              ~10-generation replication-budget runway
#                              before the cold-start METABOLIC_COST
#                              drain bites — keeps the long-wall-clock
#                              smoke alive past the first burst phase.
#                              Set to 0 to recover legacy cold-start
#                              economy.
#   STAGE3_MAX_REPLICAS        #549 burn-rate mitigation: cap replicas
#                              per tribe so concurrent LLM-call traffic
#                              stays under the Claude Code flat-rate
#                              ceiling. Default 3 yields ~15 concurrent
#                              daemons across 5 tribes (5 source + 10
#                              replicas) vs take-10's observed 26-daemon
#                              peak that exhausted the budget at T+25min.
#   STAGE3_HUNTER_TICK_MS      #552 burn-rate extension: hunter tick
#                              interval (ms). Default 240000 (240s) is
#                              4x the start-colony.sh hardcoded 60000;
#                              preserves total LLM-call budget per smoke
#                              but stretches wall clock 4x, giving
#                              emergence observation a longer continuous
#                              window within the Claude Code flat-rate
#                              5h ceiling. Threaded into env_passthrough
#                              as HUNTER_TICK_MS; each tribe's
#                              start-colony.sh tick_interval_for()
#                              hunter branch reads it (fallback 60000).
#   STAGE3_CLAUDE_CAVEMAN      #554 burn-rate mitigation: when "1",
#                              passes --tools "" --system-prompt <min>
#                              --effort low to claude CLI. Strips
#                              Claude Code session overhead from ~38K
#                              to ~11K tokens per hunter call. Stays
#                              on flat-rate (does NOT use --bare which
#                              would force API key auth). Default "0".
#   STAGE3_HUNTER_MAX_AGE      #487 follow-up: per-hunter age cap. Each
#                              hunter increments its own age counter
#                              (keyed on PPID, no shared-state RMW race)
#                              and suicides via `agentis daemon stop`
#                              when age > MAX_AGE. Default 0 = OFF (no
#                              per-hunter age mortality; tribe-wide
#                              cascade still applies as before).
#   STAGE3_HUNTER_PROMPT_MAX_BYTES
#                              #520 M98 v3 PR 1/3: clamp on the per-pid
#                              `hunter:<pid>:hunting_prompt` body length
#                              at bootstrap-read AND on every PR 2/3
#                              evolution rewrite. Default 4096 covers
#                              every pre-#505 seed (~3 KB max) with
#                              headroom for evolution rewrites.
#                              Threaded into env_passthrough so
#                              hunter.ag reads it via
#                              `exec sh "printenv HUNTER_PROMPT_MAX_BYTES"`.
#   STAGE3_HUNTER_PROMPT_EVOLUTION_THRESHOLD
#                              #520 M98 v3 PR 2/3: K verified findings
#                              required before the hunter fires the
#                              meta-prompt evolution path. Default 3.
#                              Lower => faster prompt drift but more
#                              extra LLM calls; higher => slower drift,
#                              fewer rewrites. Surfaces to hunter.ag via
#                              env_passthrough +
#                              `printenv HUNTER_PROMPT_EVOLUTION_THRESHOLD`.
#   STAGE3_HUNTER_PROMPT_GEN_CAP
#                              #520 M98 v3 PR 2/3: max generations per
#                              lineage before the next evolution resets
#                              the hunting prompt to the tribe's seed
#                              and bumps `hunter:<pid>:lineage_id`.
#                              Default 10. Prevents unbounded recursive
#                              degeneration; lineage telemetry traceable
#                              via the `lineage_id` memo (consumed by
#                              `analyse-stage3.py`'s per-class fitness
#                              curves).
#   STAGE3_HUNTER_PROMPT_LEVENSHTEIN_FLOOR
#                              #520 M98 v3 PR 2/3: minimum dissimilarity
#                              (in integer percent, 0..100) between the
#                              old prompt and an LLM-proposed rewrite for
#                              the rewrite to be accepted. Default 5
#                              (5%). A rewrite below the floor is
#                              treated as no-op: old prompt retained,
#                              generation not bumped, buffer untouched.
#   STAGE3_DAEMON_CB_PER_TICK  Per-tick CB replenishment written into
#                              hermetic .agentis/config as
#                              `daemon.cb_per_tick` (#528). Default 2000
#                              — well above the agentis-core default of
#                              100 which empirically bricks LLM-heavy
#                              tribes-bench daemons after ~10 ticks once
#                              the `cb 200000000;` lifetime budget
#                              drains (M98 v3 evolution-path ticks spend
#                              ~250-300 CB on prompt + meta-prompt +
#                              schema-sanity ping + exec-sh helpers).
#                              Lower this only when intentionally
#                              reproducing CB-exhaustion behaviour.
#   STAGE3_LLM_BACKEND         llm.backend value injected into both
#                              hermetic configs. Default: openai (#445).
#   STAGE3_OPENAI_MODEL        Model id when STAGE3_LLM_BACKEND=openai.
#                              Default: gpt-4o-mini.
#   STAGE3_OPENAI_ENDPOINT     Chat-completions URL.
#                              Default: https://api.openai.com/v1/chat/completions.
#   STAGE3_OPENAI_KEY_ENV      Name of the env var that carries the
#                              OpenAI API key. Default: OPENAI_API_KEY.
#   STAGE3_OPENAI_TIMEOUT_MS   Per-request timeout (ms). Default: 180000.
#   STAGE3_HOST_CLAUDE_DIR     #535: when STAGE3_LLM_BACKEND=claude,
#                              host directory bind-mounted into both
#                              containers' `/root/.claude` (read-write
#                              so the Claude Code CLI can refresh
#                              session tokens). Default: $HOME/.claude
#                              on the orchestrator host. Required when
#                              backend=claude; orchestrator exits 1
#                              when the directory does not exist.
#                              SECURITY NOTE: mounting ~/.claude
#                              exposes .credentials.json (the host
#                              operator's Claude Code session token)
#                              to the containers. Acceptable on a
#                              single-user dev machine; on shared CI
#                              runners, provision a dedicated session.
#   STAGE3_LAPTOP_PORT         Host port for the laptop container's
#                              agentis serve. Default: 9100.
#   STAGE3_SERVER_PORT         Host port for the server container's
#                              agentis serve. Default: 9101.
#   STAGE3_LAPTOP_WORKER_PORT  Host port for the laptop container's
#                              agentis worker (replicate dispatch target).
#                              Default: 9200.
#   STAGE3_SERVER_WORKER_PORT  Host port for the server container's
#                              agentis worker. Default: 9201.
#   STAGE3_WORKER_SECRET       Shared secret for cross-container worker
#                              auth. Default: auto-generated per run via
#                              the same idiom as start-federation.sh
#                              (16 bytes urandom, base64-trimmed).
#                              Override only for debugging — restarting
#                              one container with a stale value while the
#                              other holds the auto-generated secret will
#                              break replicate() auth.
#   STAGE3_IMAGE_TAG           Image tag built from Containerfile.stage3.
#                              Default: tribes-bench-stage3:latest.
#   STAGE3_LAPTOP_TRIBES       Space-separated tribe list for the laptop
#                              container. Default: "tribe-alpha tribe-beta".
#   STAGE3_SERVER_TRIBES       Space-separated tribe list for the server
#                              container.
#                              Default: "tribe-gamma tribe-delta tribe-epsilon".
#   STAGE3_TARGET_A_DIR        Repo-relative path to the rotation-A
#                              target dir. Default:
#                              targets/stage2/smallvec-v0.6.13.
#   STAGE3_TARGET_A_BUGS       Repo-relative path to the rotation-A
#                              bugs.json. Default: targets/stage2/bugs.json.
#   STAGE3_TARGET_B_DIR        Rotation-B target dir.
#                              Default: targets/stage3/bumpalo-v3.2.0.
#   STAGE3_TARGET_B_BUGS       Rotation-B bugs.json.
#                              Default: targets/stage3/bugs.json.
#   STAGE3_TARGET_C_DIR        Optional rotation-C target dir
#                              (Stage 4 Phase 1 chunk 1, #519). When set,
#                              the rotation timer round-robins A,B,C
#                              instead of alternating A/B. Suggested:
#                              targets/stage4-crossbeam-deque-v0.7.2.
#   STAGE3_TARGET_C_BUGS       Optional rotation-C bugs.json.
#                              Required when STAGE3_TARGET_C_DIR is set.
#                              Suggested:
#                              targets/stage4-crossbeam-deque-v0.7.2/bugs.json.
#   STAGE3_TARGET_D_DIR        Optional rotation-D target dir (#519).
#                              Suggested: targets/stage4-owning_ref-v0.4.1.
#   STAGE3_TARGET_D_BUGS       Optional rotation-D bugs.json (#519).
#                              Suggested:
#                              targets/stage4-owning_ref-v0.4.1/bugs.json.
#   STAGE3_TARGET_E_DIR        Optional rotation-E target dir (#519).
#                              Suggested: targets/stage4-generator-v0.6.25.
#   STAGE3_TARGET_E_BUGS       Optional rotation-E bugs.json (#519).
#                              Suggested:
#                              targets/stage4-generator-v0.6.25/bugs.json.
#   STAGE3_TARGET_F_DIR        Optional rotation-F target dir
#                              (Stage 4 Phase 1 chunk 2, #544). When set,
#                              the rotation timer round-robins A..F (and
#                              any further configured slots) instead of
#                              stopping at the A-E set. Suggested:
#                              targets/stage4-ticketed_lock-v0.3.0.
#   STAGE3_TARGET_F_BUGS       Optional rotation-F bugs.json (#544).
#                              Required when STAGE3_TARGET_F_DIR is set.
#                              Suggested:
#                              targets/stage4-ticketed_lock-v0.3.0/bugs.json.
#   STAGE3_TARGET_G_DIR        Optional rotation-G target dir (#544).
#                              Suggested: targets/stage4-lock_api-v0.3.4.
#   STAGE3_TARGET_G_BUGS       Optional rotation-G bugs.json (#544).
#                              Suggested:
#                              targets/stage4-lock_api-v0.3.4/bugs.json.
#   STAGE3_TARGET_H_DIR        Optional rotation-H target dir (#544).
#                              Suggested: targets/stage4-atomic-option-v0.1.2.
#   STAGE3_TARGET_H_BUGS       Optional rotation-H bugs.json (#544).
#                              Suggested:
#                              targets/stage4-atomic-option-v0.1.2/bugs.json.
#   STAGE3_TARGET_I_DIR        Optional rotation-I target dir (#544).
#                              Suggested: targets/stage4-atom-v0.3.5.
#   STAGE3_TARGET_I_BUGS       Optional rotation-I bugs.json (#544).
#                              Suggested:
#                              targets/stage4-atom-v0.3.5/bugs.json.
#   STAGE3_TARGET_J_DIR        Optional rotation-J target dir (#544).
#                              Suggested: targets/stage4-syncpool-v0.1.5.
#   STAGE3_TARGET_J_BUGS       Optional rotation-J bugs.json (#544).
#                              Suggested:
#                              targets/stage4-syncpool-v0.1.5/bugs.json.
#   STAGE3_DRY_RUN             1 = echo every command (with `+ ` prefix),
#                              do not build the image, do not spawn
#                              containers, do not exec rotation memos,
#                              exit 0. Default: 0. Equivalent to passing
#                              the --dry-run flag.
#
# Flags:
#   --dry-run    See STAGE3_DRY_RUN.
#
# Output layout (under tribes-bench/runs/stage3-docker-<ts>/):
#   run-meta.json             start ts, end ts, wall clock, rotation
#                             interval, death threshold, llm backend,
#                             container ids
#   orchestrator.log          orchestrator's own log
#   laptop-node/              bind-mounted into stage3-laptop:/run-root
#     bootstrap.sh
#     .agentis/               hermetic agentis root (laptop-side)
#     <tribe>.log
#     bug-ledger.jsonl
#     knowledge-market.csv
#   server-node/              bind-mounted into stage3-server:/run-root
#     (same shape as laptop-node)
#   rotations.csv             one row per rotation event
#                             (ts,target_dir,bugs_manifest)
#
# Exit codes:
#   0   pilot completed
#   1   prerequisite missing (podman, jq, python3) or invalid env var
#   2   image build failed
#   3   container spawn failed

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

# --- Argument parsing ---
DRY_RUN="${STAGE3_DRY_RUN:-0}"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            # #537: extract every leading comment line (from after the shebang
            # until the first non-comment line). Pre-#537 used a fixed
            # `sed -n '2,98p'` range that truncated as the env-var docblock
            # grew past line 98 — STAGE3_HOST_CLAUDE_DIR (#535), STAGE3_LLM_BACKEND,
            # STAGE3_OPENAI_*, STAGE3_DAEMON_CB_PER_TICK (#528) were all hidden.
            awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SCRIPT_PATH"
            exit 0
            ;;
        *)
            echo "run-stage3-docker: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# --- Env-var defaults + validation ---
WALL_CLOCK="${STAGE3_WALL_CLOCK_S:-21600}"
ROTATION_INTERVAL="${STAGE3_ROTATION_INTERVAL_S:-600}"
DEATH_THRESHOLD="${STAGE3_DEATH_THRESHOLD:-300}"
# #485 finite-pool R&D substrate: zero-sum reward economy + carrying-capacity
# dynamics for niche/hierarchy emergence. Defaults are 0 = OFF (legacy
# unbounded pool, byte-identical to v1.7.4). Set non-zero to activate Option 2.
TRIBE_POOL_CAP="${STAGE3_TRIBE_POOL_CAP:-0}"
TRIBE_METABOLIC_COST="${STAGE3_TRIBE_METABOLIC_COST:-0}"
TRIBE_INITIAL_POOL="${STAGE3_TRIBE_INITIAL_POOL:-20000}"
# #549 burn-rate mitigation: cap replicas per tribe to keep concurrent
# LLM-call traffic under Claude Code flat-rate ceiling. Default 3 yields
# ~15 concurrent daemons across 5 tribes (5 source + 10 replicas) vs
# take-10's observed 26-daemon peak that exhausted the budget at T+25min.
STAGE3_MAX_REPLICAS_VAL="${STAGE3_MAX_REPLICAS:-3}"
# #552 burn-rate extension: hunter tick interval (ms). Default 240000
# (240s) is 4x the start-colony.sh hardcoded 60000; preserves total
# LLM-call budget per smoke but stretches wall clock 4x, giving
# emergence observation longer continuous window within Claude Code
# flat-rate 5h ceiling.
STAGE3_HUNTER_TICK_MS_VAL="${STAGE3_HUNTER_TICK_MS:-240000}"
# #554 burn-rate mitigation: caveman Claude CLI mode. When on, the
# orchestrator passes --tools "" --system-prompt <minimal> --effort low
# to claude CLI to strip default Claude Code session overhead from
# ~38K to ~11K tokens per hunter call. Stays on flat-rate (no --bare).
# Default off to keep current behaviour as baseline until validation
# smoke confirms quality parity.
STAGE3_CLAUDE_CAVEMAN_VAL="${STAGE3_CLAUDE_CAVEMAN:-0}"
# Minimal system prompt used in caveman mode. ~200 tokens (vs ~38K
# default Claude Code system prompt). Single-line for shell-escape
# simplicity through bootstrap.sh + .agentis/config layers.
STAGE3_CAVEMAN_SYSTEM_PROMPT='You are a Rust unsafe-code static analyzer. Return ONLY valid JSON matching the requested schema. Do not explain or chain-of-thought outside the JSON.'
# #487 follow-up: per-hunter age mortality. Each hunter has its own
# monotonic age counter keyed on PPID; suicides via `agentis daemon stop`
# when age > HUNTER_MAX_AGE. Eliminates the shared-state RMW race the
# tribe-pool drain pattern hits. Default 0 = OFF (byte-identical to
# v1.7.5; tribe-wide cascade still applies as before).
HUNTER_MAX_AGE="${STAGE3_HUNTER_MAX_AGE:-0}"
# #489 follow-up: fitness-driven selection with rising threshold. Each
# hunter tracks its own per-PPID fitness counter; reward on verified
# findings + replicates, penalty on false positives. Threshold creeps
# up at HUNTER_FITNESS_CREEP_PER_MINUTE units per minute. Default 0
# = OFF (byte-identical to v1.7.5 + #489).
HUNTER_FITNESS_CREEP_PER_MINUTE="${STAGE3_HUNTER_FITNESS_CREEP_PER_MINUTE:-0}"
HUNTER_FITNESS_THRESHOLD_BASELINE="${STAGE3_HUNTER_FITNESS_THRESHOLD_BASELINE:-0}"
HUNTER_FITNESS_REWARD_VERIFIED="${STAGE3_HUNTER_FITNESS_REWARD_VERIFIED:-10}"
HUNTER_FITNESS_PENALTY_FALSEPOS="${STAGE3_HUNTER_FITNESS_PENALTY_FALSEPOS:-5}"
HUNTER_FITNESS_REWARD_REPLICATE="${STAGE3_HUNTER_FITNESS_REWARD_REPLICATE:-5}"
# Grace period (ms) for newborn hunters before selection-death kicks in.
# Without grace, replicas (start at fit=0) die before they get a tick to
# call prompt() and score a verified finding -- population collapses.
# Default 180000ms = 3 minutes = 3 ticks at 60s tick interval.
HUNTER_FITNESS_GRACE_MS="${STAGE3_HUNTER_FITNESS_GRACE_MS:-180000}"
# #490 follow-up: time-based reproductive replication. When set > 0,
# hunters whose fitness exceeds this threshold replicate per-tick
# (decoupled from verified findings) subject to pool/max_replicas.
# Default 0 = OFF (byte-identical to v1.7.5 + #489 + #490 -- only the
# existing M2-Malthusian finding-gated replicate path fires).
HUNTER_REPRODUCTIVE_FITNESS_THRESHOLD="${STAGE3_HUNTER_REPRODUCTIVE_FITNESS_THRESHOLD:-0}"
# #520 M98 v3 PR 1/3: per-hunter LLM-evolved hunting-prompt byte clamp.
# Hunters read this on bootstrap and clamp the seed-prompt body length
# (substring 0..N) before writing it to `hunter:<pid>:hunting_prompt`.
# PR 2/3 reuses the same clamp on every evolution rewrite. Default 4096
# covers every pre-#505 seed (~3 KB max) with headroom for the PR 2/3
# evolution rewrites. Set via STAGE3_HUNTER_PROMPT_MAX_BYTES. Surfaces
# via env_passthrough so hunter.ag reads it through
# `exec sh "printenv HUNTER_PROMPT_MAX_BYTES"`.
HUNTER_PROMPT_MAX_BYTES="${STAGE3_HUNTER_PROMPT_MAX_BYTES:-4096}"
# #520 M98 v3 PR 2/3: K verified findings before the hunter fires the
# meta-prompt evolution path. Default 3. Surfaces via env_passthrough.
HUNTER_PROMPT_EVOLUTION_THRESHOLD="${STAGE3_HUNTER_PROMPT_EVOLUTION_THRESHOLD:-3}"
# #520 M98 v3 PR 2/3: max generations per lineage before the next
# evolution resets to the tribe's seed and bumps lineage_id. Default 10.
HUNTER_PROMPT_GEN_CAP="${STAGE3_HUNTER_PROMPT_GEN_CAP:-10}"
# #520 M98 v3 PR 2/3: minimum dissimilarity (integer percent, 0..100)
# for an LLM-proposed prompt rewrite to be accepted. Default 5 (5%).
HUNTER_PROMPT_LEVENSHTEIN_FLOOR="${STAGE3_HUNTER_PROMPT_LEVENSHTEIN_FLOOR:-5}"
DAEMON_CB_PER_TICK="${STAGE3_DAEMON_CB_PER_TICK:-2000}"
LLM_BACKEND="${STAGE3_LLM_BACKEND:-openai}"
OPENAI_MODEL="${STAGE3_OPENAI_MODEL:-gpt-4o-mini}"
OPENAI_ENDPOINT="${STAGE3_OPENAI_ENDPOINT:-https://api.openai.com/v1/chat/completions}"
OPENAI_KEY_ENV="${STAGE3_OPENAI_KEY_ENV:-OPENAI_API_KEY}"
OPENAI_TIMEOUT_MS="${STAGE3_OPENAI_TIMEOUT_MS:-180000}"
LAPTOP_PORT="${STAGE3_LAPTOP_PORT:-9100}"
SERVER_PORT="${STAGE3_SERVER_PORT:-9101}"
LAPTOP_WORKER_PORT="${STAGE3_LAPTOP_WORKER_PORT:-9200}"
SERVER_WORKER_PORT="${STAGE3_SERVER_WORKER_PORT:-9201}"
IMAGE_TAG="${STAGE3_IMAGE_TAG:-tribes-bench-stage3:latest}"
LAPTOP_TRIBES_RAW="${STAGE3_LAPTOP_TRIBES:-tribe-alpha tribe-beta}"
SERVER_TRIBES_RAW="${STAGE3_SERVER_TRIBES:-tribe-gamma tribe-delta tribe-epsilon}"
TARGET_A_DIR_REL="${STAGE3_TARGET_A_DIR:-targets/stage2/smallvec-v0.6.13}"
TARGET_A_BUGS_REL="${STAGE3_TARGET_A_BUGS:-targets/stage2/bugs.json}"
TARGET_B_DIR_REL="${STAGE3_TARGET_B_DIR:-targets/stage3/bumpalo-v3.2.0}"
TARGET_B_BUGS_REL="${STAGE3_TARGET_B_BUGS:-targets/stage3/bugs.json}"
# Stage 4 Phase 1 chunk 1 (#519) — optional C/D/E slots. When all three
# *_DIR vars are unset the rotation falls back to byte-identical A/B
# alternation. When any *_DIR is set its paired *_BUGS must also be set;
# missing pairs are silently skipped (the rotation arm is dropped from
# the round-robin so a partially-configured operator override never
# emits an empty memo).
TARGET_C_DIR_REL="${STAGE3_TARGET_C_DIR:-}"
TARGET_C_BUGS_REL="${STAGE3_TARGET_C_BUGS:-}"
TARGET_D_DIR_REL="${STAGE3_TARGET_D_DIR:-}"
TARGET_D_BUGS_REL="${STAGE3_TARGET_D_BUGS:-}"
TARGET_E_DIR_REL="${STAGE3_TARGET_E_DIR:-}"
TARGET_E_BUGS_REL="${STAGE3_TARGET_E_BUGS:-}"
# Stage 4 Phase 1 chunk 2 (#544) — optional F/G/H/I/J slots. Same
# pairwise-empty fallback policy as C/D/E (#519): a partially-configured
# operator override (DIR set, BUGS unset, or vice versa) drops that arm
# from the round-robin so the rotation never emits an empty memo.
TARGET_F_DIR_REL="${STAGE3_TARGET_F_DIR:-}"
TARGET_F_BUGS_REL="${STAGE3_TARGET_F_BUGS:-}"
TARGET_G_DIR_REL="${STAGE3_TARGET_G_DIR:-}"
TARGET_G_BUGS_REL="${STAGE3_TARGET_G_BUGS:-}"
TARGET_H_DIR_REL="${STAGE3_TARGET_H_DIR:-}"
TARGET_H_BUGS_REL="${STAGE3_TARGET_H_BUGS:-}"
TARGET_I_DIR_REL="${STAGE3_TARGET_I_DIR:-}"
TARGET_I_BUGS_REL="${STAGE3_TARGET_I_BUGS:-}"
TARGET_J_DIR_REL="${STAGE3_TARGET_J_DIR:-}"
TARGET_J_BUGS_REL="${STAGE3_TARGET_J_BUGS:-}"

val=""
for var_name in WALL_CLOCK ROTATION_INTERVAL DEATH_THRESHOLD \
                OPENAI_TIMEOUT_MS LAPTOP_PORT SERVER_PORT \
                LAPTOP_WORKER_PORT SERVER_WORKER_PORT \
                STAGE3_MAX_REPLICAS_VAL \
                STAGE3_HUNTER_TICK_MS_VAL; do
    eval "val=\${$var_name}"
    case "$val" in
        ''|*[!0-9]*)
            echo "run-stage3-docker: $var_name must be a positive integer (got: $val)" >&2
            exit 1
            ;;
    esac
done
unset val

# #554 burn-rate mitigation: STAGE3_CLAUDE_CAVEMAN is a boolean toggle
# (0 or 1), not an integer; validate separately from the positive-int loop.
case "$STAGE3_CLAUDE_CAVEMAN_VAL" in
    0|1) ;;
    *)
        echo "run-stage3-docker: STAGE3_CLAUDE_CAVEMAN must be 0 or 1 (got '$STAGE3_CLAUDE_CAVEMAN_VAL')" >&2
        exit 2
        ;;
esac

# Convert space-separated tribe lists into arrays (set -u + IFS-default
# splitting cooperate as long as we don't quote the expansion here).
# shellcheck disable=SC2206
LAPTOP_TRIBES=( $LAPTOP_TRIBES_RAW )
# shellcheck disable=SC2206
SERVER_TRIBES=( $SERVER_TRIBES_RAW )

# --- Per-run worker secret (#465) ---
# Mirrors the start-federation.sh:64 idiom so cross-container
# replicate() lands on a peer `agentis worker` with matching auth.
# Operator override via STAGE3_WORKER_SECRET is supported but
# discouraged outside debugging — see header.
WORKER_SECRET="${STAGE3_WORKER_SECRET:-$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 16)}"

# --- Per-run hermetic dir ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$FED_DIR/runs/stage3-docker-$TS"
ORCH_LOG="$RUN_DIR/orchestrator.log"
ROTATIONS_CSV="$RUN_DIR/rotations.csv"
RUN_META="$RUN_DIR/run-meta.json"

LAPTOP_DIR="$RUN_DIR/laptop-node"
SERVER_DIR="$RUN_DIR/server-node"

# --- Dry-run / real-run dispatch helpers ---
emit_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '+ %s\n' "$*"
    else
        printf '+ %s\n' "$*" >>"$ORCH_LOG"
        # shellcheck disable=SC2294
        eval "$@"
    fi
}

emit_step() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '# %s\n' "$*"
    else
        printf '# %s\n' "$*" >>"$ORCH_LOG"
    fi
}

# --- Prerequisite checks (skipped in dry-run for portability) ---
if [ "$DRY_RUN" = "0" ]; then
    for bin in podman jq python3; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            echo "run-stage3-docker: $bin not found on PATH" >&2
            exit 1
        fi
    done
    # OpenAI key pre-flight (only when openai backend is selected). We
    # check via `eval` so STAGE3_OPENAI_KEY_ENV can name a non-default
    # env var (e.g. OPENAI_API_KEY_PILOT).
    if [ "$LLM_BACKEND" = "openai" ]; then
        eval "openai_key_value=\${$OPENAI_KEY_ENV:-}"
        if [ -z "${openai_key_value:-}" ]; then
            echo "run-stage3-docker: \$$OPENAI_KEY_ENV is empty (required for llm.backend=openai)" >&2
            exit 1
        fi
        unset openai_key_value
    fi
    mkdir -p "$RUN_DIR" "$LAPTOP_DIR" "$SERVER_DIR"
    : >"$ORCH_LOG"
    : >"$ROTATIONS_CSV"
    printf 'ts,target_dir,bugs_manifest\n' >"$ROTATIONS_CSV"
fi

emit_step "run-stage3-docker: starting (dry_run=$DRY_RUN)"
emit_step "run dir: $RUN_DIR"
emit_step "wall clock: ${WALL_CLOCK}s, rotation: ${ROTATION_INTERVAL}s, death threshold: ${DEATH_THRESHOLD}"
emit_step "max replicas per tribe: $STAGE3_MAX_REPLICAS_VAL"
emit_step "hunter tick interval: ${STAGE3_HUNTER_TICK_MS_VAL} ms"
if [ "$STAGE3_CLAUDE_CAVEMAN_VAL" = "1" ]; then
    emit_step "caveman mode: enabled (--tools '' --system-prompt minimal --effort low)"
else
    emit_step "caveman mode: disabled (default Claude CLI overhead)"
fi
emit_step "tribes: laptop=[${LAPTOP_TRIBES[*]}] server=[${SERVER_TRIBES[*]}]"
emit_step "image tag: $IMAGE_TAG"
emit_step "host ports: laptop=$LAPTOP_PORT server=$SERVER_PORT"
emit_step "worker ports: laptop=$LAPTOP_WORKER_PORT server=$SERVER_WORKER_PORT"
emit_step "generated worker secret (len=${#WORKER_SECRET})"

# --- 1) Build (or reuse) the container image ---
build_image() {
    emit_step "checking for existing image $IMAGE_TAG (build if missing)"
    emit_cmd "podman image exists $IMAGE_TAG || podman build -t $IMAGE_TAG -f $TOOLS_DIR/Containerfile.stage3 $FED_DIR"
}

# --- 2) Per-node bootstrap script generator ---
# write_bootstrap emits a self-contained bash script into <node-dir>/
# bootstrap.sh that, when executed inside the container, performs:
#   1. agentis init in /run-root (idempotent — already-initialised root
#      is a no-op)
#   2. Append federation/llm config lines to .agentis/config (peers
#      reach the other node via host.containers.internal:<peer-port>)
#   3. Copy tribe scaffolding + tools/ + targets/ + calibration.toml from
#      the read-only /repo bind-mount into /run-root
#   4. Spawn `agentis serve` on the in-container port
#   5. Spawn each tribe's start-colony.sh with DEATH_THRESHOLD +
#      AGENTIS_ROOT exported
#   6. Block until /run-root/.shutdown is touched by the host orchestrator
write_bootstrap() {
    role="$1"             # laptop | server
    node_dir="$2"         # $LAPTOP_DIR or $SERVER_DIR
    self_port="$3"        # in-container serve port (also host port)
    peer_port="$4"        # peer serve port (federation discovery)
    self_worker_port="$5" # in-container worker port (#465)
    peer_worker_port="$6" # peer worker port — replicate() target (#465)
    tribes_str="$7"       # space-separated

    bootstrap_path="$node_dir/bootstrap.sh"
    emit_step "generating bootstrap script for $role at $bootstrap_path"

    if [ "$DRY_RUN" = "1" ]; then
        # Echo a synthesised path-only command line so the dry-run
        # transcript covers each bootstrap.sh write without inflating
        # the dry-run output with the full multi-line file body.
        emit_cmd "write-bootstrap role=$role path=$bootstrap_path self_port=$self_port peer_port=$peer_port self_worker_port=$self_worker_port peer_worker_port=$peer_worker_port tribes=\"$tribes_str\""
        return
    fi

    {
        printf '#!/bin/bash\n'
        printf '# Auto-generated by run-stage3-docker.sh — runs inside the container.\n'
        printf 'set -euo pipefail\n'
        printf 'cd /run-root\n'
        printf 'agentis init >/dev/null 2>&1 || true\n'
        # #474 + #476: resolve host.containers.internal once at bootstrap
        # start so the config block (colony.workers) AND the memo seed
        # (peer_worker_addr) both see the IP form. parse_workers in
        # agentis-core accepts hostnames in colony.workers but
        # SocketAddr::parse() in perform_replication() rejects them, so
        # both must be resolved at container exec time.
        printf 'PEER_HOST_IP=$(getent hosts host.containers.internal | awk '\''{print $1}'\'')\n'
        # Mirror run-stage2.sh lines 193-263 setup. Without these keys
        # the agent runtime silently degrades: exec sh in .ag agents
        # cannot see TARGET_DIR / VERIFIER_PATH (no env_passthrough),
        # learn() rows never land in .agentis/experience/ (experience
        # disabled), telemetry events vanish (telemetry disabled), and
        # slow LLM rounds trigger watchdog kill cascade (default
        # heartbeat = tick_interval * 2 = 120s; openai gpt-4o-mini at
        # 20k tokens can take 90+ seconds).
        printf '{\n'
        printf '  printf "federation.enabled = true\\n"\n'
        printf '  printf "federation.peers = host.containers.internal:%s\\n"\n' "$peer_port"
        printf '  printf "exec.env_passthrough = COLONY_DIR,TRIBE_NAME,TARGET_DIR,TARGET_FILE,BUGS_MANIFEST,VERIFIER_PATH,RUN_DIR,BUG_LEDGER_PATH,INITIAL_CB,BASE_COST,K_MALTHUSIAN,MAX_REPLICAS,REWARD_FULL,REWARD_SUBSEQUENT,LEDGER_REWARD_FULL,LEDGER_REWARD_SUBSEQUENT,DEATH_THRESHOLD,AGENTIS_ROOT,HUNTER_INITIAL_FITNESS,HUNTER_INITIAL_VARIANT,HUNTER_PROMPT_MAX_BYTES,HUNTER_PROMPT_EVOLUTION_THRESHOLD,HUNTER_PROMPT_GEN_CAP,HUNTER_PROMPT_LEVENSHTEIN_FLOOR\\n"\n'
        printf '  printf "experience.enabled = true\\n"\n'
        printf '  printf "telemetry.enabled = true\\n"\n'
        printf '  printf "daemon.heartbeat_interval_ms = 600000\\n"\n'
        # #476: agentis daemon wires colony_peers (which carries
        # colony.secret for replicate AUTH) only when BOTH messaging.distributed
        # is true AND colony.workers is set. Without this, the replicate caller
        # skips the AUTH handshake and sends MSG_REPLICATE (0x1B) directly,
        # which the worker rejects with "expected AUTH (0x09), got 0x1b".
        printf '  printf "messaging.distributed = true\\n"\n'
        printf '  printf "colony.workers = %%s:%%s\\n" "$PEER_HOST_IP" "%s"\n' "$peer_worker_port"
        printf '  printf "llm.backend = %s\\n"\n' "$LLM_BACKEND"
        # #528: bump daemon.cb_per_tick well above the agentis-core default (100)
        # so M98 v3 evolution-path ticks (which can spend 250-300 CB on prompt
        # + meta-prompt + schema-sanity ping + exec-sh helpers) don't drain
        # the daemon's 200M lifetime budget within ~10 ticks.
        printf '  printf "daemon.cb_per_tick = %s\\n"\n' "$DAEMON_CB_PER_TICK"
        # #544 chunk 2: bump memo.max_keys above the agentis-core default
        # (500, #555) to cover ~50 hunters × ~100 distinct per-pid keys
        # under the post-#544 population scaling (max_replicas_per_tribe
        # = 10, STAGE3_TRIBE_INITIAL_POOL default 20000). Without this
        # bump the long-wall-clock smoke wedges on `memo: max 500 keys
        # exceeded` once the replica fleet saturates, with the agents
        # still appearing `state = running` in `daemon list` (the
        # tick_success_rate-on-RATE-column signal lands in v1.4.4+).
        printf '  printf "memo.max_keys = 50000\\n"\n'
        if [ "$LLM_BACKEND" = "openai" ]; then
            printf '  printf "llm.openai.endpoint = %s\\n"\n' "$OPENAI_ENDPOINT"
            printf '  printf "llm.openai.model = %s\\n"\n' "$OPENAI_MODEL"
            printf '  printf "llm.openai.api_key_env = %s\\n"\n' "$OPENAI_KEY_ENV"
            printf '  printf "llm.openai.timeout_ms = %s\\n"\n' "$OPENAI_TIMEOUT_MS"
        fi
        # #554 burn-rate mitigation: when caveman mode is on, inject
        # llm.command + llm.args to drive the claude CLI with minimal
        # session overhead (--tools "" --system-prompt <minimal> --effort
        # low). Strips Claude Code default system prompt + tools manifest
        # from each hunter call (~38K → ~11K tokens). Stays on flat-rate
        # OAuth (no --bare). Default off keeps the emitted config
        # byte-identical to the pre-#554 baseline.
        if [ "$STAGE3_CLAUDE_CAVEMAN_VAL" = "1" ]; then
            escaped_caveman_prompt=$(printf '%s' "$STAGE3_CAVEMAN_SYSTEM_PROMPT" | sed 's/"/\\"/g')
            printf '  printf "llm.command = claude\\n"\n'
            printf '  printf "llm.args = -p --output-format json --tools \\"\\" --system-prompt \\"%s\\" --effort low\\n"\n' "$escaped_caveman_prompt"
        fi
        printf '  printf "colony.secret = %%s\\n" "$WORKER_SECRET"\n'
        printf '} >> .agentis/config\n'
        # Bring tribes-bench/tools first, then merge in the repo-root tools/
        # which carries platform helpers (parse-toml.sh, kill-federation.sh)
        # that start-colony.sh's `<fed>/tools/parse-toml.sh` lookup needs.
        # The two source dirs have non-overlapping filenames so the order
        # is stable; cp -n is a defensive no-clobber in case a future
        # rename ever introduces a collision.
        printf 'cp -r /repo/tribes-bench/tools /run-root/tools\n'
        printf 'cp -rn /repo/tools/. /run-root/tools/\n'
        printf 'cp -r /repo/tribes-bench/targets /run-root/targets\n'
        printf 'cp /repo/tribes-bench/calibration.toml /run-root/calibration.toml\n'
        for tribe in $tribes_str; do
            printf 'cp -r /repo/tribes-bench/%s /run-root/%s\n' "$tribe" "$tribe"
        done
        # agentis sandbox refuses any path outside <agentis-root>/sandbox/.
        # run-stage2.sh handles this by copying targets INTO the sandbox
        # tree (see lines 187-190 of run-stage2.sh) and exporting
        # TARGET_DIR_SANDBOX as a relative path. Mirror that pattern here
        # so hunter agents can read the planted-bug source files at tick
        # time without "path outside sandbox" errors.
        printf 'mkdir -p /run-root/.agentis/sandbox\n'
        printf 'cp -r /run-root/targets/stage2 /run-root/.agentis/sandbox/targets-stage2\n'
        printf 'cp -r /run-root/targets/stage3 /run-root/.agentis/sandbox/targets-stage3 2>/dev/null || true\n'
        printf 'cp -r /run-root/targets/stage0 /run-root/.agentis/sandbox/targets-stage0 2>/dev/null || true\n'
        printf 'cp -r /run-root/targets/stage1 /run-root/.agentis/sandbox/targets-stage1 2>/dev/null || true\n'
        # Seed propose-tier confidence (default tier without seed is
        # dormant; tribes-bench Stage 2 convention is propose at 0.7,
        # mirrored from run-stage2.sh line 272). Without this seed the
        # hunter ticks at conf=0 → dormant → no LLM call → no findings.
        printf '(cd /run-root && agentis memo set hunter:confidence 0.7 >/dev/null 2>&1 || true)\n'
        # Stage 3 cross-node replication (#460 PR B + #465): seed the
        # peer-worker address list so hunter's
        # select_replication_target() rotates the replicate(target) call
        # across nodes. Each container gets exactly one peer (the other
        # node), reachable at host.containers.internal on the peer's
        # WORKER port (not the serve port — replicate dispatch needs an
        # `agentis worker` listener on the matching shared secret).
        # Indexed key + count memo shape is read by the hunter helper
        # via recall_latest("...:peer_worker_addr:0") plus
        # recall_latest("...:peer_worker_count").
        # #474: agentis-core perform_replication() parses target via
        # SocketAddr::parse() which rejects hostnames; PEER_HOST_IP is
        # resolved earlier (after agentis init) and reused here so the
        # memo seed contains IP:port.
        printf '(cd /run-root && agentis memo set tribes-bench:peer_worker_addr:0 "$PEER_HOST_IP:%s" >/dev/null 2>&1 || true)\n' "$peer_worker_port"
        printf '(cd /run-root && agentis memo set tribes-bench:peer_worker_count 1 >/dev/null 2>&1 || true)\n'
        printf 'agentis serve 0.0.0.0:%s > /run-root/serve.log 2>&1 &\n' "$self_port"
        printf 'echo $! > /run-root/serve.pid\n'
        # Stage 3 cross-container replicate dispatch (#465): a peer's
        # replicate(target) call lands on this worker. WORKER_SECRET is
        # injected via `podman run -e WORKER_SECRET=...` and must match
        # on both nodes for auth to succeed. Bind 0.0.0.0 so podman's
        # host-bridge maps host:<self_worker_port> → container:<self_worker_port>.
        # Pure-bash poll on /dev/tcp avoids relying on iproute2 / netcat
        # being present in the base image (Containerfile.stage3 ships
        # only python3/jq/git/curl/ca-certificates). Cap at 30 iterations
        # (~15s) so a broken worker does not hang bootstrap forever.
        printf 'agentis worker 0.0.0.0:%s --secret "$WORKER_SECRET" --max-concurrent 8 > /run-root/worker.log 2>&1 &\n' "$self_worker_port"
        printf 'echo $! > /run-root/worker.pid\n'
        printf 'for _ in $(seq 1 30); do\n'
        printf '    if (exec 3<>/dev/tcp/127.0.0.1/%s) 2>/dev/null; then exec 3<&-; exec 3>&-; break; fi\n' "$self_worker_port"
        printf '    sleep 0.5\n'
        printf 'done\n'
        for tribe in $tribes_str; do
            # Pass TARGET_DIR + TARGET_FILE + BUGS_MANIFEST + VERIFIER_PATH
            # as env into start-colony.sh so the hunter resolves planted-
            # bug source files inside the sandbox. TARGET_DIR is a path
            # RELATIVE to /run-root/.agentis/sandbox/ (agentis sandbox
            # convention). The rotation timer overrides these via memo
            # writes once the first rotation interval elapses, but the
            # bootstrap default lets daemons land on a working Stage 2
            # target on tick 1 instead of the broken Stage 0 fallback.
            # BUG_LEDGER_PATH gives start-colony.sh the host-side ledger
            # file to seed the tribe-<name>:bug_ledger memo from. Without
            # it, hunters verify findings but the JSONL ledger never
            # grows (visible in experience but missing from bug-ledger).
            printf 'DEATH_THRESHOLD=%s POOL_CAP=%s METABOLIC_COST=%s INITIAL_POOL=%s HUNTER_MAX_AGE=%s HUNTER_FITNESS_CREEP_PER_MINUTE=%s HUNTER_FITNESS_THRESHOLD_BASELINE=%s HUNTER_FITNESS_REWARD_VERIFIED=%s HUNTER_FITNESS_PENALTY_FALSEPOS=%s HUNTER_FITNESS_REWARD_REPLICATE=%s HUNTER_FITNESS_GRACE_MS=%s HUNTER_REPRODUCTIVE_FITNESS_THRESHOLD=%s HUNTER_PROMPT_MAX_BYTES=%s HUNTER_PROMPT_EVOLUTION_THRESHOLD=%s HUNTER_PROMPT_GEN_CAP=%s HUNTER_PROMPT_LEVENSHTEIN_FLOOR=%s MAX_REPLICAS=%s HUNTER_TICK_MS=%s AGENTIS_ROOT=/run-root/.agentis TARGET_DIR=targets-stage2/smallvec-v0.6.13 TARGET_FILE=lib.rs BUGS_MANIFEST=/run-root/.agentis/sandbox/targets-stage2/bugs.json VERIFIER_PATH=/run-root/tools/verify-finding-stage2.sh BUG_LEDGER_PATH=/run-root/bug-ledger.jsonl LEDGER_REWARD_FULL=200 LEDGER_REWARD_SUBSEQUENT=50 bash /run-root/%s/scripts/start-colony.sh > /run-root/%s.log 2>&1 &\n' \
                "$DEATH_THRESHOLD" "$TRIBE_POOL_CAP" "$TRIBE_METABOLIC_COST" "$TRIBE_INITIAL_POOL" "$HUNTER_MAX_AGE" "$HUNTER_FITNESS_CREEP_PER_MINUTE" "$HUNTER_FITNESS_THRESHOLD_BASELINE" "$HUNTER_FITNESS_REWARD_VERIFIED" "$HUNTER_FITNESS_PENALTY_FALSEPOS" "$HUNTER_FITNESS_REWARD_REPLICATE" "$HUNTER_FITNESS_GRACE_MS" "$HUNTER_REPRODUCTIVE_FITNESS_THRESHOLD" "$HUNTER_PROMPT_MAX_BYTES" "$HUNTER_PROMPT_EVOLUTION_THRESHOLD" "$HUNTER_PROMPT_GEN_CAP" "$HUNTER_PROMPT_LEVENSHTEIN_FLOOR" "$STAGE3_MAX_REPLICAS_VAL" "$STAGE3_HUNTER_TICK_MS_VAL" "$tribe" "$tribe"
        done
        printf 'while [ ! -e /run-root/.shutdown ]; do sleep 5; done\n'
        printf 'exit 0\n'
    } >"$bootstrap_path"
    chmod +x "$bootstrap_path"
}

write_bootstraps() {
    write_bootstrap "laptop" "$LAPTOP_DIR" "$LAPTOP_PORT" "$SERVER_PORT" \
        "$LAPTOP_WORKER_PORT" "$SERVER_WORKER_PORT" "${LAPTOP_TRIBES[*]}"
    write_bootstrap "server" "$SERVER_DIR" "$SERVER_PORT" "$LAPTOP_PORT" \
        "$SERVER_WORKER_PORT" "$LAPTOP_WORKER_PORT" "${SERVER_TRIBES[*]}"
}

# --- 3) Spawn the two containers ---
# Note on host.containers.internal: this is podman's documented analog
# of docker's host.docker.internal and resolves to the host's loopback
# bridge under both rootful and rootless podman 4.x+. If a future host's
# podman setup misses this alias (some legacy CNI configs), pass
# --add-host host.containers.internal:<host-bridge-ip> to both runs.
#
# #535: when STAGE3_LLM_BACKEND=claude, the orchestrator bind-mounts the
# host operator's $STAGE3_HOST_CLAUDE_DIR (default $HOME/.claude) into
# each container's /root/.claude (read-write so the Claude Code CLI can
# refresh session tokens). The OpenAI-backend code path is unchanged
# when STAGE3_LLM_BACKEND=openai (default).
#
# Operator security notes:
#   1. Mounting ~/.claude exposes the host's .credentials.json (Claude
#      Code session token) to the container. On a single-user dev
#      machine this is acceptable; on shared CI runners operators
#      should provision a dedicated Claude Code session.
#   2. Do NOT debug the credentials path with raw `cat` or `stat` —
#      the token will end up in terminal scrollback. Use `test -r
#      <file>` for existence checks.
#   3. #540: the `:z` SELinux relabel option appended below mutates
#      the SELinux type of $STAGE3_HOST_CLAUDE_DIR on the host
#      (typically `user_home_t` → `container_file_t`). This is
#      required on SELinux-enforcing distros (Fedora, RHEL, openSUSE)
#      where `user_home_t` is denied to `container_t` processes —
#      without `:z` the container sees `Permission denied` on every
#      file under the mount despite UID/permission bits being correct.
#      `:z` is a no-op on SELinux-disabled hosts (Ubuntu, Debian).
spawn_containers() {
    local CLAUDE_MOUNT_FLAG=""
    if [ "$LLM_BACKEND" = "claude" ]; then
        local HOST_CLAUDE_DIR="${STAGE3_HOST_CLAUDE_DIR:-$HOME/.claude}"
        if [ -d "$HOST_CLAUDE_DIR" ]; then
            # #540: append `:z` so podman applies a shared SELinux
            # relabel — required on SELinux-enforcing hosts. No-op
            # on SELinux-disabled hosts.
            CLAUDE_MOUNT_FLAG="-v $HOST_CLAUDE_DIR:/root/.claude:rw,z"
        else
            echo "run-stage3-docker: STAGE3_HOST_CLAUDE_DIR=$HOST_CLAUDE_DIR does not exist" >&2
            echo "                   set STAGE3_HOST_CLAUDE_DIR or install Claude Code first" >&2
            exit 1
        fi
    fi
    emit_step "spawning stage3-laptop container (host port $LAPTOP_PORT, worker port $LAPTOP_WORKER_PORT)"
    emit_cmd "podman run -d --name stage3-laptop -p $LAPTOP_PORT:$LAPTOP_PORT -p $LAPTOP_WORKER_PORT:$LAPTOP_WORKER_PORT -e $OPENAI_KEY_ENV=\"\${$OPENAI_KEY_ENV:-}\" -e WORKER_SECRET=\"$WORKER_SECRET\" -v $REPO_ROOT:/repo:ro -v $LAPTOP_DIR:/run-root:rw $CLAUDE_MOUNT_FLAG $IMAGE_TAG /run-root/bootstrap.sh"
    emit_step "spawning stage3-server container (host port $SERVER_PORT, worker port $SERVER_WORKER_PORT)"
    emit_cmd "podman run -d --name stage3-server -p $SERVER_PORT:$SERVER_PORT -p $SERVER_WORKER_PORT:$SERVER_WORKER_PORT -e $OPENAI_KEY_ENV=\"\${$OPENAI_KEY_ENV:-}\" -e WORKER_SECRET=\"$WORKER_SECRET\" -v $REPO_ROOT:/repo:ro -v $SERVER_DIR:/run-root:rw $CLAUDE_MOUNT_FLAG $IMAGE_TAG /run-root/bootstrap.sh"
}

# --- 4) Target rotation timer (runs on the host, not inside containers) ---
# The rotation loop sleeps ROTATION_INTERVAL, alternates target_dir +
# bugs_manifest between the two planted-bug surfaces, and re-exports
# them into BOTH containers via `podman exec ... agentis memo set`.
# Daemons re-read on each tick. Path values use container-side absolute
# paths (/run-root/targets/...), since memos are read inside containers.
# Memo key alignment: hunters read hunter:target_dir + hunter:target_file
# (seeded by start-colony.sh at bootstrap). We overwrite those keys here
# so rotation actually changes what hunters target. The bugs_manifest write
# is a no-op stub for a future verifier-side change (see issue #546).
rotation_timer() {
    emit_step "starting target-rotation timer (interval=${ROTATION_INTERVAL}s)"
    # Stage 4 Phase 1 chunk 1 (#519) + chunk 2 (#544): if any of
    # TARGET_C..J_DIR_REL is set together with its paired *_BUGS_REL,
    # fall through to the array-based round-robin branch. Otherwise emit
    # the byte-identical legacy A/B alternation so the default
    # invocation stays unchanged.
    extra_targets=""
    if [ -n "$TARGET_C_DIR_REL" ] && [ -n "$TARGET_C_BUGS_REL" ]; then
        extra_targets="$extra_targets C"
    fi
    if [ -n "$TARGET_D_DIR_REL" ] && [ -n "$TARGET_D_BUGS_REL" ]; then
        extra_targets="$extra_targets D"
    fi
    if [ -n "$TARGET_E_DIR_REL" ] && [ -n "$TARGET_E_BUGS_REL" ]; then
        extra_targets="$extra_targets E"
    fi
    if [ -n "$TARGET_F_DIR_REL" ] && [ -n "$TARGET_F_BUGS_REL" ]; then
        extra_targets="$extra_targets F"
    fi
    if [ -n "$TARGET_G_DIR_REL" ] && [ -n "$TARGET_G_BUGS_REL" ]; then
        extra_targets="$extra_targets G"
    fi
    if [ -n "$TARGET_H_DIR_REL" ] && [ -n "$TARGET_H_BUGS_REL" ]; then
        extra_targets="$extra_targets H"
    fi
    if [ -n "$TARGET_I_DIR_REL" ] && [ -n "$TARGET_I_BUGS_REL" ]; then
        extra_targets="$extra_targets I"
    fi
    if [ -n "$TARGET_J_DIR_REL" ] && [ -n "$TARGET_J_BUGS_REL" ]; then
        extra_targets="$extra_targets J"
    fi
    if [ -z "$extra_targets" ]; then
        emit_cmd "( phase=0; while true; do sleep $ROTATION_INTERVAL; phase=\$((1 - phase)); if [ \"\$phase\" = \"0\" ]; then td=/run-root/$TARGET_A_DIR_REL; bm=/run-root/$TARGET_A_BUGS_REL; else td=/run-root/$TARGET_B_DIR_REL; bm=/run-root/$TARGET_B_BUGS_REL; fi; tf=\$(podman exec stage3-laptop python3 -c \"import json,collections; j=json.load(open('\$bm')); fs=[b.get('file','') for b in j.get('bugs',[])]; c=collections.Counter(fs); print(c.most_common(1)[0][0] if c else 'lib.rs')\" 2>/dev/null || echo lib.rs); printf '%s,%s,%s\\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"\$td\" \"\$bm\" >>$ROTATIONS_CSV; podman exec stage3-laptop agentis memo set hunter:target_dir \"\$td\" >/dev/null 2>&1 || true; podman exec stage3-laptop agentis memo set hunter:target_file \"\$tf\" >/dev/null 2>&1 || true; podman exec stage3-laptop agentis memo set hunter:bugs_manifest \"\$bm\" >/dev/null 2>&1 || true; podman exec stage3-server agentis memo set hunter:target_dir \"\$td\" >/dev/null 2>&1 || true; podman exec stage3-server agentis memo set hunter:target_file \"\$tf\" >/dev/null 2>&1 || true; podman exec stage3-server agentis memo set hunter:bugs_manifest \"\$bm\" >/dev/null 2>&1 || true; done ) >>$RUN_DIR/rotation.log 2>&1 & echo \$! >$RUN_DIR/rotation.pid"
    else
        # Round-robin across A, B, plus whichever of C/D/E/F/G/H/I/J
        # were configured. Each iteration picks the next entry by integer
        # modulo of a monotonic counter; bash 4 `${arr[idx]}` indexing
        # with `${!var}` indirect expansion resolves
        # TARGET_<K>_DIR_REL / TARGET_<K>_BUGS_REL for K in {A..J}.
        targets_init="targets=(A B)"
        for k in $extra_targets; do
            targets_init="$targets_init; targets+=($k)"
        done
        emit_cmd "( $targets_init; i=0; n=\${#targets[@]}; while true; do sleep $ROTATION_INTERVAL; k=\${targets[\$((i % n))]}; i=\$((i+1)); td_var=\"TARGET_\${k}_DIR_REL\"; bm_var=\"TARGET_\${k}_BUGS_REL\"; td=/run-root/\${!td_var}; bm=/run-root/\${!bm_var}; tf=\$(podman exec stage3-laptop python3 -c \"import json,collections; j=json.load(open('\$bm')); fs=[b.get('file','') for b in j.get('bugs',[])]; c=collections.Counter(fs); print(c.most_common(1)[0][0] if c else 'lib.rs')\" 2>/dev/null || echo lib.rs); printf '%s,%s,%s\\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"\$td\" \"\$bm\" >>$ROTATIONS_CSV; podman exec stage3-laptop agentis memo set hunter:target_dir \"\$td\" >/dev/null 2>&1 || true; podman exec stage3-laptop agentis memo set hunter:target_file \"\$tf\" >/dev/null 2>&1 || true; podman exec stage3-laptop agentis memo set hunter:bugs_manifest \"\$bm\" >/dev/null 2>&1 || true; podman exec stage3-server agentis memo set hunter:target_dir \"\$td\" >/dev/null 2>&1 || true; podman exec stage3-server agentis memo set hunter:target_file \"\$tf\" >/dev/null 2>&1 || true; podman exec stage3-server agentis memo set hunter:bugs_manifest \"\$bm\" >/dev/null 2>&1 || true; done ) >>$RUN_DIR/rotation.log 2>&1 & echo \$! >$RUN_DIR/rotation.pid"
    fi
}

stop_rotation_timer() {
    emit_step "stopping target-rotation timer"
    emit_cmd "kill \$(cat $RUN_DIR/rotation.pid 2>/dev/null) 2>/dev/null || true"
}

# --- 5) Cleanup trap ---
# Cleanup is idempotent: stop sends SIGTERM with a 5s grace, rm -f
# nukes whatever's left. Both calls swallow errors so a partially-
# failed spawn (only one of the two containers up) still tears down
# whatever did come up.
install_cleanup_trap() {
    emit_step "installing cleanup trap (stop + rm both containers)"
    emit_cmd "trap 'stop_rotation_timer; podman stop --time 5 stage3-laptop stage3-server 2>/dev/null || true; podman rm -f stage3-laptop stage3-server 2>/dev/null || true' EXIT INT TERM"
}

# --- 6) Shutdown signal to both containers ---
signal_shutdown() {
    emit_step "signalling shutdown to both containers (touch /run-root/.shutdown)"
    emit_cmd "podman exec stage3-laptop touch /run-root/.shutdown 2>/dev/null || true"
    emit_cmd "podman exec stage3-server touch /run-root/.shutdown 2>/dev/null || true"
}

# --- 7) run-meta.json ---
write_run_meta() {
    emit_step "writing run-meta.json"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    emit_cmd "python3 -c 'import json,sys; json.dump({\"started_at\":\"$started_at\",\"wall_clock_s\":$WALL_CLOCK,\"rotation_interval_s\":$ROTATION_INTERVAL,\"death_threshold\":$DEATH_THRESHOLD,\"llm_backend\":\"$LLM_BACKEND\",\"image_tag\":\"$IMAGE_TAG\",\"nodes\":[{\"role\":\"laptop\",\"container\":\"stage3-laptop\",\"host_port\":$LAPTOP_PORT,\"tribes\":\"${LAPTOP_TRIBES[*]}\".split()},{\"role\":\"server\",\"container\":\"stage3-server\",\"host_port\":$SERVER_PORT,\"tribes\":\"${SERVER_TRIBES[*]}\".split()}]}, open(\"$RUN_META\",\"w\"), indent=2)'"
}

# --- 8) Verify artefacts on host ---
verify_artefacts() {
    emit_step "verifying per-node artefacts on host (bug-ledger.jsonl + telemetry.csv)"
    emit_cmd "ls -la $LAPTOP_DIR/bug-ledger.jsonl $LAPTOP_DIR/telemetry.csv 2>/dev/null || true"
    emit_cmd "ls -la $SERVER_DIR/bug-ledger.jsonl $SERVER_DIR/telemetry.csv 2>/dev/null || true"
}

# --- 9) Stitch via analyse-stage3.py ---
# analyse-stage3.py takes the run-dir + --server-runs subdir. The
# laptop hermetic root is expected at <run-dir>/.agentis/, but in this
# Docker layout the laptop root lives at <run-dir>/laptop-node/.agentis/.
# Until analyse-stage3.py grows a --laptop-runs flag (follow-up issue),
# we still invoke it with --server-runs server-node so the server side
# is stitched correctly; the laptop side may report missing artefacts
# until the follow-up lands. Captured non-fatally with || true.
stitch_telemetry() {
    emit_step "running analyse-stage3.py to stitch laptop + server telemetry"
    emit_cmd "python3 $TOOLS_DIR/analyse-stage3.py $RUN_DIR --laptop-dir laptop-node --server-runs server-node >>$ORCH_LOG 2>&1 || true"
}

# --- Orchestration body ---
install_cleanup_trap
build_image
write_bootstraps
write_run_meta
spawn_containers
rotation_timer

if [ "$DRY_RUN" = "1" ]; then
    emit_step "dry-run complete; no containers spawned"
    exit 0
fi

emit_step "sleeping ${WALL_CLOCK}s for pilot wall clock"
sleep "$WALL_CLOCK"

signal_shutdown
verify_artefacts
stitch_telemetry

emit_step "run-stage3-docker: done"
echo "[run-stage3-docker] run dir: $RUN_DIR"
