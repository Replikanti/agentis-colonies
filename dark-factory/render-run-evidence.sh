#!/usr/bin/env bash
# render-run-evidence.sh — render a REAL captured poc-run.txt into a terminal-styled poc-run.png (#1550).
#
# HONESTY GUARD: this renders a PNG of REAL captured terminal output — nothing more. It must ONLY ever be
# invoked on a poc-run.txt that came from an ACTUAL captured PoC run; it must NEVER be called to synthesize a
# `[PASS]`. The renderer draws the input verbatim (only recolouring `[PASS]`/`[FAIL]` lines it already
# contains); it cannot fabricate a passing run. deliver-submission.sh only calls this inside the #1540
# `[ -n "$POC_RUN_REL" ]` guard (which is set only when --poc-run pointed at a real, existing file).
#
# Renderer preference: `freeze` (charmbracelet, on PATH) -> the bundled PIL renderer (render-run-evidence.py) ->
# SKIP. The `freeze` path is OPTIONAL and UNVERIFIED — freeze is NOT installed on the dev host, so its exact
# flags below have never been exercised; on any freeze failure we FALL THROUGH to the PIL branch rather than
# fail. The PIL branch IS verified (Pillow 11.3.0). A host with neither renderer degrades to text-only (the
# caller keeps poc-run.txt and drops poc-run.png) — never fatal.
#
# bash, NEVER sh: this has a bash shebang and every caller invokes it as `bash render-run-evidence.sh` — never
# `sh` / dot-source (the #1507/#1534 dash-safety lesson).
#
# Usage:  render-run-evidence.sh <input.txt> <output.png>
# Requires: bash + (freeze OR python3 with Pillow). Exit: 0 rendered, 1 skipped/no-renderer/render-failed
#           (best-effort signal to the caller), 2 bad args.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$#" -ge 2 ] || { echo "Usage: render-run-evidence.sh <input.txt> <output.png>" >&2; exit 2; }
IN="$1"
OUT="$2"
[ -f "$IN" ] || { echo "render-run-evidence.sh: input not found: $IN" >&2; exit 2; }

# freeze (OPTIONAL, UNVERIFIED — not installed on the dev host): best-effort attempt; on any failure fall
# through to the PIL renderer rather than failing outright.
if command -v freeze >/dev/null 2>&1; then
  if freeze "$IN" -o "$OUT" >/dev/null 2>&1 && [ -s "$OUT" ]; then
    exit 0
  fi
  echo "render-run-evidence.sh: freeze attempt failed — falling through to the PIL renderer" >&2
fi

# PIL renderer (VERIFIED, Pillow present on the dev host).
if python3 -c "import PIL" >/dev/null 2>&1; then
  python3 "$SCRIPT_DIR/render-run-evidence.py" "$IN" "$OUT"
  exit $?
fi

echo "render-run-evidence.sh: no renderer available (freeze/PIL) — skipping poc-run.png" >&2
exit 1
