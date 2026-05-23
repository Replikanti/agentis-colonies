#!/usr/bin/env bash
# research-foundry/tools/check-corpus-balance.sh -- relaxed-threshold
# guard around corpus-inventory.py for the 5-bucket coarse classifier
# (#768).
#
# This is the PR-1 piece of issue #768: an informational balance check
# that confirms the corpus is not lopsided in any single classified
# bucket. The original issue suggested a 25%-per-bucket ceiling, but
# the current 24-paper baseline is too small AND the keyword classifier
# misses most abstracts (see corpus-inventory.py's WARNING line), so a
# 25% cap would fail trivially on the all-unclassified case.
#
# Relaxed contract: no *classified* bucket may exceed 50% of the total.
# The unclassified pool is reported but not gated -- PR-2 (paper
# additions, deferred) is where unclassified gets meaningfully reduced.
#
# Exit codes:
#   0  pass (no classified bucket > 50%)
#   1  fail (some classified bucket > 50%)
#   2  corpus-inventory.py missing or refused to run

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVENTORY="$SCRIPT_DIR/corpus-inventory.py"
THRESHOLD_PCT="50"

if [ ! -f "$INVENTORY" ]; then
    echo "check-corpus-balance: corpus-inventory.py missing at $INVENTORY" >&2
    exit 2
fi

if ! REPORT="$(python3 "$INVENTORY" --json)"; then
    echo "check-corpus-balance: corpus-inventory.py --json failed" >&2
    exit 2
fi

# Pipe the JSON report into a python helper. No inline heredoc -- keeps
# the script portable across macOS bash 3.2 and matches the auto-promote
# pattern (CLAUDE.md "never inline heredocs").
printf '%s' "$REPORT" | python3 -c "
import json, sys
threshold = float(sys.argv[1])
report = json.loads(sys.stdin.read())
total = report.get('total', 0)
if total <= 0:
    print('check-corpus-balance: empty corpus')
    sys.exit(2)
buckets = report.get('buckets', {})
fail = False
for name, count in sorted(buckets.items()):
    pct = 100.0 * count / total
    flag = ''
    if pct > threshold:
        flag = '  FAIL (> {0:.0f}%)'.format(threshold)
        fail = True
    print('  {0:18}{1:>4} ({2:5.1f}%){3}'.format(name, count, pct, flag))
unclassified = report.get('unclassified', 0)
print('  {0:18}{1:>4} ({2:5.1f}%)  (informational only)'.format(
    'unclassified', unclassified, 100.0 * unclassified / total))
print('')
if fail:
    print('check-corpus-balance: FAIL -- classified bucket exceeds {0:.0f}% cap'.format(
        threshold))
    sys.exit(1)
print('check-corpus-balance: PASS -- no classified bucket exceeds {0:.0f}%'.format(
    threshold))
sys.exit(0)
" "$THRESHOLD_PCT"
