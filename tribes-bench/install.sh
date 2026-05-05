#!/bin/bash
# install.sh: idempotent setup for the tribes-bench federation.
#
# Stage 0 (#363) is a wiring test, not a real federation: there are no
# external credentials to prompt for and no [forge] config to copy.
# Install only:
#   1. Copy each tribe's colony.example.toml to colony.toml so
#      start-colony.sh has something to read.
#   2. Seed each hunter agent's confidence memo to 0.7 (mid-`propose`
#      tier per ADR-0001) so the very first tick lands on the propose
#      branch instead of `dormant`.
#
# Run-time hermetic seeding (per-run AGENTIS_ROOT under runs/<ts>/) is
# performed by tools/run-stage0.sh, which also sets AGENTIS_ROOT before
# launching the federation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_NAME="$(basename "$SCRIPT_DIR")"

# §9 risk 7: refuse install if the agentis runtime cannot reach the M2
# floor. The federation's hunters call `knowledge_buy` / `knowledge_sell`
# unconditionally; pre-v1.5.0 daemons quarantine on first tick.
"$SCRIPT_DIR/tools/check-agentis-version.sh"

echo "Installing $FED_NAME federation..."

for tribe in tribe-alpha tribe-beta tribe-gamma tribe-delta tribe-epsilon; do
    example="$SCRIPT_DIR/$tribe/config/colony.example.toml"
    target="$SCRIPT_DIR/$tribe/config/colony.toml"
    if [ ! -f "$target" ] && [ -f "$example" ]; then
        cp "$example" "$target"
        echo "  copied $tribe/config/colony.toml from example"
    fi
done

if command -v agentis >/dev/null 2>&1; then
    # Seed both tribes at confidence 0.7 (mid-`propose` tier). The
    # hermetic per-run root used by run-stage0.sh re-seeds in its own
    # AGENTIS_ROOT, so this only matters for ad-hoc runs against the
    # operator's persistent store.
    agentis memo set hunter:confidence 0.7 >/dev/null 2>&1 || true
    echo "  seeded hunter:confidence = 0.7 (propose tier)"
else
    echo "  agentis CLI not found on PATH — skipping memo seed"
    echo "  (run-stage0.sh will seed inside the per-run hermetic root)"
fi

echo
echo "Done."
echo
echo "Next steps:"
echo "  1. (optional) install dashboard: bash federation-dashboard/install.sh"
echo "  2. run a 30-min verdict pair:    bash tribes-bench/tools/run-verdict-pair.sh"
echo "  3. open dashboard at http://localhost:8420 (after starting it)"
