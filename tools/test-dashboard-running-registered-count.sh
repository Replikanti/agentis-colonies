#!/bin/bash
# tools/test-dashboard-running-registered-count.sh: regression test for
# #1351 — the federation health banner's healthy branch must use the
# REGISTERED agent count as the denominator, not the running count.
#
# Bug: renderFedHealthBanner()'s !degraded branch built
#   running.length + '/' + running.length + ' running daemons alive'
# deriving both numerator and denominator from the running set, so it
# always rendered an all-green "N/N" bar — actively hiding a federation
# where registered agents are stopped/failed (e.g. "16/16" while 5 of 21
# daemons were down). It also contradicted the "Agents Running" stat box,
# which already shows running/registered (`running + '/' + totalAgents`).
#
# Fix: the denominator is now agents.length (the registered count), so
# running < registered is visible ("16/21"), and a distinct
# "N stopped (name1, name2, name3, ...)" segment is pushed to the banner
# detail naming the stopped/failed agents whenever any registered agent is
# not running.
#
# This pins the fix with a fixture of 16 running + 5 stopped daemons and
# asserts the banner reads "16/21" (never "16/16") and lists the stopped
# agents. Behavioural (node) when available — it extracts and runs the real
# renderFedHealthBanner() against the fixture — with a static template guard
# fallback when node is absent (same shape as test-timeline-rendering.sh T67).
#
# Usage: ./tools/test-dashboard-running-registered-count.sh
# Exit 0 on full pass.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_HTML="$REPO_ROOT/federation-dashboard/lib/federation-dashboard.html.template"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if [ ! -r "$TEMPLATE_HTML" ]; then
    fail "0: federation-dashboard.html.template not readable" "$TEMPLATE_HTML"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

T1_ERR="$TMPDIR_TEST/t1.err"
if command -v node >/dev/null 2>&1; then
    # --- Behavioural: extract renderFedHealthBanner() from the template,
    #     run it against a 16-running / 5-stopped fixture, assert the
    #     rendered detail. ---
    if TEMPLATE_HTML="$TEMPLATE_HTML" node <<'JS' 2>"$T1_ERR"
const fs = require('fs');
const tpl = fs.readFileSync(process.env.TEMPLATE_HTML, 'utf8');
const start = tpl.indexOf('function renderFedHealthBanner');
const end = tpl.indexOf('// --- Stats Row ---', start);
if (start < 0 || end < 0) { process.stderr.write('could not extract renderFedHealthBanner\n'); process.exit(2); }
const fnSrc = tpl.slice(start, end);

const elStub = { classList: { remove() {}, add() {} }, innerHTML: '' };
globalThis.document = { getElementById: () => elStub };
globalThis.esc = s => String(s);
globalThis.nowEpoch = 1000000;

// 16 of 21 registered daemons running. Running daemons are pid_alive so the
// federation classifies HEALTHY and the !degraded branch (where the fix
// lives) is exercised. The 5 stopped daemons must surface in the detail.
const fixture = [];
for (let i = 0; i < 16; i++) {
  fixture.push({ state: 'running', pid: 100 + i, pid_alive: true, name: 'run_' + i });
}
for (let i = 0; i < 5; i++) {
  fixture.push({ state: 'stopped', pid: 0, pid_alive: false, name: 'stopped_' + i });
}

globalThis.agents = fixture;
globalThis.sidecar = { installed: false, enabled: false };
globalThis.sidecars = [];
const data = {};
elStub.innerHTML = '';
// Direct sloppy eval: defines renderFedHealthBanner in this scope and runs
// it; the function's free vars resolve to the globals set above.
eval(fnSrc + '\nrenderFedHealthBanner(data);');
const detail = elStub.innerHTML;

const fails = [];
function check(cond, msg) { if (!cond) fails.push(msg); }

// The fix: denominator is the registered count (21), not running (16).
check(/16\/21 running daemons alive/.test(detail),
      'expected "16/21 running daemons alive", got: ' + detail);
// The bug: must NEVER render the all-green "16/16".
check(!/16\/16/.test(detail),
      'must NOT render "16/16" (running as its own denominator), got: ' + detail);
// Verdict stays Healthy — the gap is surfaced, not escalated to Degraded.
check(/Healthy/.test(detail),
      'verdict should still read Healthy, got: ' + detail);
// The stopped/failed daemons are named distinctly.
check(/5 stopped \(/.test(detail),
      'expected "5 stopped (...)" segment naming the down daemons, got: ' + detail);
check(/stopped_0/.test(detail),
      'expected first stopped daemon name in the detail, got: ' + detail);
// More than 3 stopped -> truncated with ", ...".
check(/, \.\.\.\)/.test(detail),
      'expected ", ...)" truncation for >3 stopped daemons, got: ' + detail);

if (fails.length) { process.stderr.write(fails.join('\n') + '\n'); process.exit(1); }
process.exit(0);
JS
    then
        pass "1: health banner renders 16/21 (registered denominator) + names 5 stopped daemons (#1351)"
    else
        fail "1: health banner denominator/stopped-breakdown wrong (#1351)" \
             "$(tr '\n' ' ' < "$T1_ERR" 2>/dev/null)"
    fi
else
    # node unavailable on this runner: static template guard on the
    # renderFedHealthBanner() healthy branch so the denominator fix can't
    # silently regress to running-as-its-own-denominator.
    if python3 - "$TEMPLATE_HTML" <<'PY' 2>"$T1_ERR"
import sys, re
with open(sys.argv[1]) as f:
    html = f.read()
m = re.search(r'function renderFedHealthBanner\b.*?// --- Stats Row ---', html, re.DOTALL)
if not m:
    sys.stderr.write('renderFedHealthBanner not found\n'); sys.exit(2)
body = m.group(0)
# The denominator must be the registered count (agents.length), paired with
# the running numerator.
if "running.length + '/' + agents.length" not in body:
    sys.stderr.write("healthy branch does not pair running numerator with agents.length denominator\n"); sys.exit(3)
# The bug pattern (running as its own denominator) must be gone.
if "running.length + '/' + running.length" in body:
    sys.stderr.write("BUG: running.length used as its own denominator still present\n"); sys.exit(4)
# Stopped/failed daemons must be surfaced distinctly.
if "a.state !== 'running'" not in body:
    sys.stderr.write("stopped-daemon filter (state !== running) missing\n"); sys.exit(5)
if 'stopped (' not in body:
    sys.stderr.write('"N stopped (...)" detail segment missing\n'); sys.exit(6)
sys.exit(0)
PY
    then
        pass "1: health banner denominator fix present (static; node absent) (#1351)"
    else
        fail "1: health banner denominator template guard failed (#1351)" \
             "$(tr '\n' ' ' < "$T1_ERR" 2>/dev/null)"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
