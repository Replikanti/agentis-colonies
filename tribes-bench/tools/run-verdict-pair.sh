#!/bin/bash
# run-verdict-pair.sh — orchestrate one ecosystem + one baseline pilot
# and print the resulting comparison.md inline.
#
# This is the operator-friendly wrapper for the Stage 2 M3 (#394)
# 3-step recipe documented in tribes-bench/README.md. It compresses the
# five separate commands the operator otherwise has to type — run-stage2,
# run-baseline, two `ls -td` lookups, analyse-stage2 — into one
# invocation that echoes each command on its own line with a leading
# `+ ` prefix BEFORE executing it. Operators who want to copy any
# individual step can do so from the echoed line.
#
# Defaults match the README's quick-start (1800s = 30min for fast
# verdict). Override via the existing run-stage2 / run-baseline env
# vars if a longer pilot is wanted.
#
# Flags:
#   --dry-run        Echo every command but do not execute.
#   --skip-stage2    Skip the run-stage2.sh step (use the latest
#                    runs/<ts> directory that already exists).
#   --skip-baseline  Skip the run-baseline.sh step (use the latest
#                    runs/baseline-<ts> directory that already exists).
#
# Exit codes:
#   0   verdict pair completed and comparison.md printed
#   1   prerequisite missing or unknown flag
#   2   run-stage2.sh failed
#   3   run-baseline.sh failed
#   4   analyse-stage2.py failed
#   5   no eligible runs/<ts> or runs/baseline-<ts> directory found

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"

DRY_RUN=0
SKIP_STAGE2=0
SKIP_BASELINE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --skip-stage2)
            SKIP_STAGE2=1
            shift
            ;;
        --skip-baseline)
            SKIP_BASELINE=1
            shift
            ;;
        -h|--help)
            sed -n '2,30p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "run-verdict-pair: unknown flag: $1" >&2
            exit 1
            ;;
    esac
done

# Default wall clocks for a fast 30-minute verdict pair. Operators who
# already exported STAGE2_WALL_CLOCK_S / STAGE2_BASELINE_WALL_CLOCK_S
# keep their override.
export STAGE2_WALL_CLOCK_S="${STAGE2_WALL_CLOCK_S:-1800}"
export STAGE2_BASELINE_WALL_CLOCK_S="${STAGE2_BASELINE_WALL_CLOCK_S:-1800}"

# `+ <cmd>` echo helper. Always prints to stdout; runs the command
# unless --dry-run is set.
run() {
    echo "+ $*"
    if [ "$DRY_RUN" -eq 0 ]; then
        "$@"
    fi
}

# Resolve "the latest runs/<ts>/ that is NOT a baseline-* dir" via
# `ls -td`. Mirrors the ad-hoc procedure operators already use.
latest_eco_dir() {
    # shellcheck disable=SC2012
    ls -td "$FED_DIR"/runs/*/ 2>/dev/null \
        | grep -v '/runs/baseline-' \
        | head -1 \
        | sed 's:/$::'
}

latest_baseline_dir() {
    # shellcheck disable=SC2012
    ls -td "$FED_DIR"/runs/baseline-*/ 2>/dev/null \
        | head -1 \
        | sed 's:/$::'
}

# --- Step 1: ecosystem run ---
if [ "$SKIP_STAGE2" -eq 0 ]; then
    if ! run bash "$TOOLS_DIR/run-stage2.sh"; then
        echo "run-verdict-pair: run-stage2.sh failed" >&2
        exit 2
    fi
fi

# --- Step 2: baseline run ---
if [ "$SKIP_BASELINE" -eq 0 ]; then
    if ! run bash "$TOOLS_DIR/run-baseline.sh"; then
        echo "run-verdict-pair: run-baseline.sh failed" >&2
        exit 3
    fi
fi

# --- Step 3: resolve dirs and run the comparison ---
ECO_DIR="$(latest_eco_dir || true)"
BASELINE_DIR="$(latest_baseline_dir || true)"

if [ "$DRY_RUN" -eq 0 ]; then
    if [ -z "$ECO_DIR" ] || [ ! -d "$ECO_DIR" ]; then
        echo "run-verdict-pair: no ecosystem run dir found under $FED_DIR/runs/" >&2
        exit 5
    fi
    if [ -z "$BASELINE_DIR" ] || [ ! -d "$BASELINE_DIR" ]; then
        echo "run-verdict-pair: no baseline run dir found under $FED_DIR/runs/baseline-*" >&2
        exit 5
    fi
else
    # Dry-run sentinel paths so the echoed analyse line has something
    # concrete to show.
    ECO_DIR="${ECO_DIR:-$FED_DIR/runs/<eco-ts>}"
    BASELINE_DIR="${BASELINE_DIR:-$FED_DIR/runs/baseline-<bl-ts>}"
fi

echo "[run-verdict-pair] ecosystem run: $ECO_DIR"
echo "[run-verdict-pair] baseline run:  $BASELINE_DIR"

if ! run python3 "$TOOLS_DIR/analyse-stage2.py" "$ECO_DIR" --baseline "$BASELINE_DIR/telemetry.csv"; then
    echo "run-verdict-pair: analyse-stage2.py failed" >&2
    exit 4
fi

# --- Step 4: print comparison.md inline ---
COMPARISON_MD="$ECO_DIR/comparison.md"
run cat "$COMPARISON_MD"
