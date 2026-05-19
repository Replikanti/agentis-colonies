#!/usr/bin/env bash
# research-foundry/tools/test-jitter.sh -- regression test for the #670
# per-tick `_jitter_sleep()` helper added to all 18 research-foundry .ag
# files (5 explorers + 17 non-explorer colonies). The helper spreads API
# requests across the 56-daemon container so the run stays under Claude's
# ~100 req/min ceiling; the RESEARCH_JITTER_DISABLED=1 env knob bypasses
# the sleep for tests and deterministic replays.
#
# Pure-grep assertions, no agentis runtime required:
#   (a) each of the 18 .ag files defines `fn _jitter_sleep() -> int`.
#   (b) the helper body reads RESEARCH_JITTER_DISABLED via printenv and
#       short-circuits when the value is "1".
#   (c) the helper body sleeps for `awk 'BEGIN{srand();print rand()*5}'`
#       seconds (i.e. uniform on [0, 5)).
#   (d) each `fn tick(...)` calls the helper via `let _ = _jitter_sleep();`.
#
# Usage: bash research-foundry/tools/test-jitter.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

COLONIES="explorer noticer skeptic formulator verifier novelty arxiv-search oeis-search groupprops-search scholar-search prior_advocate auditor introducer theorist computer editor reviewer submitter"

for c in $COLONIES; do
    ag_file="$FED_DIR/$c/agents/$c.ag"
    if [ ! -f "$ag_file" ]; then
        fail "$c.ag exists" "$ag_file not found"
        continue
    fi

    # (a) helper defined
    if grep -Fq "fn _jitter_sleep() -> int {" "$ag_file"; then
        pass "(a) $c.ag defines _jitter_sleep()"
    else
        fail "(a) $c.ag defines _jitter_sleep()" "definition missing"
    fi

    # (b) reads RESEARCH_JITTER_DISABLED + short-circuits on "1"
    if grep -Fq 'printenv RESEARCH_JITTER_DISABLED' "$ag_file" \
       && grep -Fq 'if disabled == "1" { return 0; };' "$ag_file"; then
        pass "(b) $c.ag honours RESEARCH_JITTER_DISABLED"
    else
        fail "(b) $c.ag honours RESEARCH_JITTER_DISABLED" "disable check missing"
    fi

    # (c) sleeps awk-rand 0..5
    if grep -Fq "sleep \$(awk 'BEGIN{srand();print rand()*5}')" "$ag_file"; then
        pass "(c) $c.ag uses awk-srand jitter on [0, 5)"
    else
        fail "(c) $c.ag uses awk-srand jitter on [0, 5)" "awk-srand sleep missing"
    fi

    # (d) tick() calls helper
    if awk '
        /^fn tick\(/ { in_tick = 1; depth = 0 }
        in_tick {
            n = gsub(/\{/, "{")
            depth += n
            n = gsub(/\}/, "}")
            depth -= n
            if (/let _ = _jitter_sleep\(\);/) { found = 1 }
            if (depth <= 0 && /\}/) { in_tick = 0 }
        }
        END { exit (found ? 0 : 1) }
    ' "$ag_file"; then
        pass "(d) $c.ag tick() calls _jitter_sleep()"
    else
        fail "(d) $c.ag tick() calls _jitter_sleep()" "call site missing in fn tick"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
