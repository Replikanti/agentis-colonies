#!/usr/bin/env bash
# seed-historical-patterns.sh — #1733: seed the invpat:invented:<class> cold-start hint from a curated,
# OFFLINE library of canonical historical DeFi exploit classes (auditor/methods/historical-exploits.md).
#
# This generalizes the single-line `--method-fixture` mechanism `run-autonomous-hunt.sh` already implements
# (run-autonomous-hunt.sh:340-349: parse one `METHOD|...` line, extract its class, `agentis memo set
# invpat:invented:<class> <line>`) from ONE line to N, so a fresh --pattern-store starts with a curated hint
# for every covered class instead of only whichever single class a live invent-method run happened to propose.
#
# recall_pattern() (invariant-prover.ag) already checks `invpat:invented:<class>` as its GENERATION hint when
# no `invpat:latest:<class>` (a prior real FINDING) has been persisted yet for that class — this script writes
# INTO that existing fallback slot; it does not add a new memo namespace and does not touch invariant-prover.ag,
# seed-patterns.ag, or run-autonomous-hunt.sh.
#
# Usage:
#   seed-historical-patterns.sh --pattern-store <dir> [--library <file>] [--agentis <bin>]
#
#   --pattern-store <dir>  REQUIRED. The persistent agentis store to seed. Created (mkdir -p) and
#                          `agentis init`'d if it does not already hold a `.agentis/` dir — mirrors
#                          run-autonomous-hunt.sh:230-235.
#   --library <file>       The METHOD| fixture to read (default: auditor/methods/historical-exploits.md next
#                          to this script).
#   --agentis <bin>        agentis binary (default: `agentis` on PATH).
#
# For each `^METHOD|` line in the library: extract the class via the EXACT pipeline
# run-autonomous-hunt.sh:343-344 uses (`cut -d'|' -f3 | cut -d',' -f1 | tr -d '[:space:]'`), then
# `( cd "$PATTERN_STORE" && "$AGENTIS" memo set "invpat:invented:$CLASS" "$LINE" )`. Prints one
# `SEEDED|<class>|<name>` line per entry, then a trailing `SEEDED-COUNT|<n>` summary.
#
# Missing agentis / an unwritable --pattern-store / an unreadable --library are HARD usage errors (non-zero
# exit), never a silent no-op — a class the operator believes is seeded must actually be seeded or the run
# aborts loudly.
#
# Exit: 0 on success; 2 on usage error; 1 on a store/library failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
PATTERN_STORE=""
LIBRARY="$HERE/auditor/methods/historical-exploits.md"

need() { [ "$1" -ge 2 ] || { echo "seed-historical-patterns.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --pattern-store) need "$#"; PATTERN_STORE="$2"; shift 2 ;;
    --library)       need "$#"; LIBRARY="$2"; shift 2 ;;
    --agentis)       need "$#"; AGENTIS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "seed-historical-patterns.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PATTERN_STORE" ] || { echo "seed-historical-patterns.sh: --pattern-store is required" >&2; exit 2; }

command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || {
  echo "seed-historical-patterns.sh: agentis binary not found ($AGENTIS)" >&2; exit 2;
}

[ -f "$LIBRARY" ] || { echo "seed-historical-patterns.sh: --library not found: $LIBRARY" >&2; exit 2; }
[ -r "$LIBRARY" ] || { echo "seed-historical-patterns.sh: --library not readable: $LIBRARY" >&2; exit 2; }

mkdir -p "$PATTERN_STORE" || { echo "seed-historical-patterns.sh: cannot create --pattern-store dir: $PATTERN_STORE" >&2; exit 1; }
[ -w "$PATTERN_STORE" ] || { echo "seed-historical-patterns.sh: --pattern-store not writable: $PATTERN_STORE" >&2; exit 1; }
PATTERN_STORE="$(cd "$PATTERN_STORE" && pwd)"
[ -d "$PATTERN_STORE/.agentis" ] || ( cd "$PATTERN_STORE" && "$AGENTIS" init >/dev/null 2>&1 ) || {
  echo "seed-historical-patterns.sh: agentis init failed in --pattern-store: $PATTERN_STORE" >&2; exit 1;
}

COUNT=0
while IFS= read -r M_LINE; do
  [ -n "$M_LINE" ] || continue
  M_NAME="$(printf '%s' "$M_LINE" | cut -d'|' -f2)"
  M_CLASS="$(printf '%s' "$M_LINE" | cut -d'|' -f3 | cut -d',' -f1 | tr -d '[:space:]')"
  if [ -z "$M_CLASS" ]; then
    echo "seed-historical-patterns.sh: skipping a METHOD| line with an empty class field: $M_LINE" >&2
    continue
  fi
  ( cd "$PATTERN_STORE" && "$AGENTIS" memo set "invpat:invented:$M_CLASS" "$M_LINE" >/dev/null 2>&1 ) || {
    echo "seed-historical-patterns.sh: agentis memo set failed for class $M_CLASS" >&2; exit 1;
  }
  echo "SEEDED|$M_CLASS|$M_NAME"
  COUNT=$((COUNT + 1))
done <<EOF
$(grep -E '^METHOD\|' "$LIBRARY")
EOF

echo "SEEDED-COUNT|$COUNT"
[ "$COUNT" -gt 0 ] || { echo "seed-historical-patterns.sh: no METHOD| lines found in --library: $LIBRARY" >&2; exit 1; }
exit 0
