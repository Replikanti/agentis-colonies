#!/bin/bash
# tools/test-dashboard-gates.sh: smoke test for the confidence_gates / cap
# parser used by the federation dashboard (#160).
#
# Runs the same regex the dashboard uses against every .ag file in
# dev-apprenticeship/ and asserts the extracted set of gate levels matches the
# manually-curated table in #160. Catches two regressions:
#   - someone changes the regex in federation-dashboard.sh and forgets here
#   - someone edits an .ag file and removes / adds a gate the table assumes
#
# Self-contained, no external deps beyond python3. Exits 0 on full pass.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FED_DIR="$REPO_ROOT/dev-apprenticeship"

if [ ! -d "$FED_DIR" ]; then
    echo "[SKIP] dev-apprenticeship federation not present"
    exit 0
fi

python3 - "$FED_DIR" <<'PY'
import os, re, sys

fed_dir = sys.argv[1]

# Manually curated from issue #160. Each entry: (gates, cap)
# Mirrors the "Observed capability gaps" table in the issue body.
EXPECTED = {
    # planning observers — only suggest gate, no act-level
    'risk_assessor':     ([0.6],         None),
    'task_decomposer':   ([0.6],         None),
    'scope_estimator':   ([0.6],         None),
    # planning writer
    'plan_reviewer':     ([0.6, 0.85],   None),
    # code-review (5 agents) — act-only gates
    'logic_reviewer':    ([0.85],        None),
    'security_reviewer': ([0.85],        None),
    'style_reviewer':    ([0.85],        None),
    'test_reviewer':     ([0.85],        None),
    'approval_decider':  ([0.6, 0.85],   None),
    # triage (4 agents)
    'router':            ([0.6, 0.85],   None),
    'prioritizer':       ([0.6, 0.85],   None),
    'labeler':           ([0.6, 0.85],   0.85),  # has clamp_auto cap
    'issue_creator':     ([0.6, 0.85],   None),
    # implementation (4 agents)
    'code_writer':       ([0.6, 0.85],   None),
    'test_writer':       ([0.6, 0.85],   None),
    'refactorer':        ([0.6, 0.85],   None),
    'commit_composer':   ([0.6, 0.85],   None),
    # release (4 agents)
    'release_checker':   ([0.6, 0.85],   None),
    'ship_decider':      ([0.6, 0.85],   None),
    'changelog_writer':  ([0.6, 0.85],   None),
    'version_bumper':    ([0.6, 0.85],   None),
}

# Same regex as federation-dashboard.sh
GATE_RE = re.compile(r'\bif\s+confidence\s+>=\s+([0-9]+(?:\.[0-9]+)?)')
CLAMP_RE = re.compile(r'\bfn\s+clamp_auto\s*\(')
CAP_RE = re.compile(r'\blet\s+cap\s*=\s*([0-9]+(?:\.[0-9]+)?)')

passed = 0
failed = 0
seen = set()

for colony in sorted(os.listdir(fed_dir)):
    ag_dir = os.path.join(fed_dir, colony, 'agents')
    if not os.path.isdir(ag_dir):
        continue
    for fn in sorted(os.listdir(ag_dir)):
        if not fn.endswith('.ag'):
            continue
        agent = fn[:-3]
        seen.add(agent)
        with open(os.path.join(ag_dir, fn)) as f:
            text = f.read()
        gates_set = sorted({float(m) for m in GATE_RE.findall(text)})
        cap = None
        if CLAMP_RE.search(text):
            cm = CAP_RE.search(text)
            if cm:
                cap = float(cm.group(1))
        if agent not in EXPECTED:
            print(f'[FAIL] {agent}: not in expected table — add it or remove the .ag')
            failed += 1
            continue
        exp_gates, exp_cap = EXPECTED[agent]
        if gates_set != sorted(exp_gates):
            print(f'[FAIL] {agent}: gates={gates_set!r} expected {sorted(exp_gates)!r}')
            failed += 1
            continue
        if cap != exp_cap:
            print(f'[FAIL] {agent}: cap={cap!r} expected {exp_cap!r}')
            failed += 1
            continue
        print(f'[PASS] {agent} gates={gates_set} cap={cap}')
        passed += 1

missing = set(EXPECTED) - seen
for m in sorted(missing):
    print(f'[FAIL] {m}: in expected table but no .ag found')
    failed += 1

# Cap-drift guard: today only `clamp_auto` is recognised as a confidence cap.
# If a future .ag introduces a different capping idiom the dashboard parser
# will miss it silently. Flag any mention of `cap` near a confidence literal
# that is NOT inside a clamp_auto function so the parser gets extended.
CAP_CONTEXT_RE = re.compile(r'\bcap\b.{0,40}\b(?:confidence|0\.[0-9]+)', re.IGNORECASE)
for colony in sorted(os.listdir(fed_dir)):
    ag_dir = os.path.join(fed_dir, colony, 'agents')
    if not os.path.isdir(ag_dir):
        continue
    for fn in sorted(os.listdir(ag_dir)):
        if not fn.endswith('.ag'):
            continue
        with open(os.path.join(ag_dir, fn)) as f:
            text = f.read()
        if CLAMP_RE.search(text):
            continue  # known idiom, parser handles it
        if CAP_CONTEXT_RE.search(text):
            agent = fn[:-3]
            print(f'[FAIL] {agent}: found `cap` near confidence without clamp_auto \u2014 extend the dashboard parser to recognise the new capping idiom')
            failed += 1

print(f'\nResults: {passed} passed, {failed} failed')
sys.exit(0 if failed == 0 else 1)
PY
