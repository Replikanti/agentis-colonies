#!/usr/bin/env bash
# research-foundry/tools/test-last-check-early.sh -- regression test for
# the #697 top-of-tick `<colony>:last_check` memo write added to all 18
# research-foundry .ag files.
#
# Pre-#697 the heartbeat memo was only written at the bottom of
# `fn tick(...)`, which 15 of 18 colonies skip via early-return gates
# (waiting on upstream signals). The dashboard's #686 memo-freshness
# liveness probe then flipped those agents to `pid_alive=false` despite
# their daemons being alive and ticking. #697 moves the write to the top
# of every tick (immediately after `_jitter_sleep()`) while keeping the
# existing end-of-tick write as an idempotent refresh on happy paths.
#
# Pure-grep/awk assertions, no agentis runtime required. For each of the
# 18 .ag files assert:
#   (a) exactly one heartbeat line
#       `let _last_check_now = try { exec sh "date -u +%Y-%m-%dT%H:%M:%SZ"; } catch e { ""; };`
#       exists.
#   (b) its line number is strictly less than the line number of the
#       first `return;` statement inside `fn tick()`'s body (= guaranteed
#       to fire before any early-return gate).
#   (c) its line number equals the `_jitter_sleep()` call line + 1
#       (jitter happens before heartbeat, preserving #670 ordering).
#   (d) the existing end-of-tick `memo_write("<colony>:last_check", now)`
#       still exists (idempotency invariant preserved).
#
# Usage: bash research-foundry/tools/test-last-check-early.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

COLONIES="explorer noticer skeptic formulator verifier novelty arxiv-search oeis-search groupprops-search scholar-search prior_advocate auditor introducer theorist computer editor reviewer submitter"

HEARTBEAT='let _last_check_now = try { exec sh "date -u +%Y-%m-%dT%H:%M:%SZ"; } catch e { ""; };'

for c in $COLONIES; do
    ag_file="$FED_DIR/$c/agents/$c.ag"
    if [ ! -f "$ag_file" ]; then
        fail "$c.ag exists" "$ag_file not found"
        continue
    fi

    # (a) exactly one heartbeat line
    heartbeat_count="$(grep -Fc "$HEARTBEAT" "$ag_file" || true)"
    if [ "$heartbeat_count" = "1" ]; then
        pass "(a) $c.ag has exactly one top-of-tick heartbeat line"
    else
        fail "(a) $c.ag has exactly one top-of-tick heartbeat line" \
             "found $heartbeat_count occurrences (want 1)"
    fi

    heartbeat_line="$(grep -Fn "$HEARTBEAT" "$ag_file" | head -1 | cut -d: -f1)"
    jitter_line="$(awk '/^fn tick\(/ {in_tick=1} in_tick && /let _ = _jitter_sleep\(\);/ {print NR; exit}' "$ag_file")"
    tick_return_line="$(awk '
        /^fn tick\(/ { in_tick = 1; depth = 0 }
        in_tick {
            n = gsub(/\{/, "{"); depth += n
            n = gsub(/\}/, "}"); depth -= n
            if (/return;/ && !found) { found = NR }
            if (depth <= 0 && /\}/) { in_tick = 0 }
        }
        END { if (found) print found }
    ' "$ag_file")"

    # (b) heartbeat line < first `return;` in fn tick body
    if [ -n "$heartbeat_line" ] && [ -n "$tick_return_line" ]; then
        if [ "$heartbeat_line" -lt "$tick_return_line" ]; then
            pass "(b) $c.ag heartbeat (line $heartbeat_line) fires before first early-return (line $tick_return_line)"
        else
            fail "(b) $c.ag heartbeat fires before first early-return" \
                 "heartbeat=$heartbeat_line not < return=$tick_return_line"
        fi
    elif [ -n "$heartbeat_line" ] && [ -z "$tick_return_line" ]; then
        pass "(b) $c.ag heartbeat (line $heartbeat_line) fires before first early-return (no return; in fn tick)"
    else
        fail "(b) $c.ag heartbeat fires before first early-return" \
             "could not locate heartbeat or return line"
    fi

    # (c) heartbeat line == jitter line + 1
    if [ -n "$heartbeat_line" ] && [ -n "$jitter_line" ]; then
        expected=$((jitter_line + 1))
        if [ "$heartbeat_line" = "$expected" ]; then
            pass "(c) $c.ag heartbeat (line $heartbeat_line) is _jitter_sleep() + 1"
        else
            fail "(c) $c.ag heartbeat is _jitter_sleep() + 1" \
                 "heartbeat=$heartbeat_line jitter=$jitter_line expected=$expected"
        fi
    else
        fail "(c) $c.ag heartbeat is _jitter_sleep() + 1" \
             "could not locate heartbeat or jitter line"
    fi

    # (d) end-of-tick memo_write("<colony>:last_check", now) still present
    if grep -Fq "memo_write(\"$c:last_check\", now)" "$ag_file"; then
        pass "(d) $c.ag end-of-tick memo_write(\"$c:last_check\", now) preserved"
    else
        fail "(d) $c.ag end-of-tick memo_write(\"$c:last_check\", now) preserved" \
             "idempotent end-of-tick refresh missing"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
