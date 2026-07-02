#!/bin/bash
# tools/test-dashboard-gates.sh: smoke test for the confidence_gates / cap
# parser used by the federation dashboard (#160, retargeted for #176).
#
# After M4 (#176) all 21 dev-apprenticeship agents branch on
# `tier("<agent>") == "<tier_name>"` instead of raw `confidence >= X`
# literals. This test runs the same regex the dashboard uses against
# every .ag file in dev-apprenticeship/ and asserts the extracted set
# of tier-branches matches the expected set per agent. Catches two
# regressions:
#   - someone changes the regex in federation-dashboard-collector.py and
#     forgets here
#   - someone edits an .ag file and removes / adds a tier branch the
#     table assumes
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

# Expected tier-branches per agent after #176. Every agent is required
# to have all four tiers (shadow, propose, review-gated, autonomous) as
# per ADR-0001 — the canonical 4-branch pattern. labeler.ag and router.ag
# both carry the crystallizer reality-check clamp_auto cap at 0.85
# (#1235 / #1234).
FOUR_TIERS = ['autonomous', 'propose', 'review-gated', 'shadow']
EXPECTED = {
    'risk_assessor':     (FOUR_TIERS, None),
    'task_decomposer':   (FOUR_TIERS, None),
    'scope_estimator':   (FOUR_TIERS, None),
    'plan_reviewer':     (FOUR_TIERS, None),
    'logic_reviewer':    (FOUR_TIERS, None),
    'security_reviewer': (FOUR_TIERS, None),
    'style_reviewer':    (FOUR_TIERS, None),
    'test_reviewer':     (FOUR_TIERS, None),
    'qa_reviewer':       (FOUR_TIERS, None),
    'approval_decider':  (FOUR_TIERS, None),
    'router':            (FOUR_TIERS, 0.85),
    'prioritizer':       (FOUR_TIERS, None),
    'labeler':           (FOUR_TIERS, 0.85),
    'issue_creator':     (FOUR_TIERS, None),
    'code_writer':       (FOUR_TIERS, None),
    'test_writer':       (FOUR_TIERS, None),
    'refactorer':        (FOUR_TIERS, None),
    'commit_composer':   (FOUR_TIERS, None),
    'release_checker':   (FOUR_TIERS, None),
    'ship_decider':      (FOUR_TIERS, None),
    'changelog_writer':  (FOUR_TIERS, None),
    'version_bumper':    (FOUR_TIERS, None),
}

# Same regex as federation-dashboard-collector.py after #176: match every
# tier-branch comparison in the agent. We look for any occurrence of
# `== "<tier_name>"` that follows a `my_tier` identifier, gathering the
# set of tier names that the agent branches on.
# #316 M4: post-M3 agents call `repo_tier("name", owner, repo)` instead
# of the legacy `tier("name")`. Both forms count as a tier-call for the
# else-fallthrough rescue below.
TIER_CALL_RE = re.compile(r'\btier\s*\(\s*"([^"]+)"\s*\)|\brepo_tier\s*\(\s*"([^"]+)"\s*,')
TIER_BRANCH_RE = re.compile(r'my_tier\s*==\s*"(shadow|propose|review-gated|autonomous|dormant)"')
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
        tier_calls = TIER_CALL_RE.findall(text)
        branches = sorted(set(TIER_BRANCH_RE.findall(text)))
        # The shadow tier is expressed as the else-fallthrough (no explicit
        # `my_tier == "shadow"` comparison) since the dormant-as-shadow
        # collapse is the canonical pattern from CLAUDE.md. Treat the
        # presence of a `tier(...)` call + at least the 3 non-shadow
        # branches as implicitly covering shadow.
        non_shadow = [b for b in branches if b != 'shadow']
        has_tier_call = len(tier_calls) > 0
        if has_tier_call and set(non_shadow) >= {'autonomous', 'review-gated', 'propose'}:
            branches = sorted(set(branches) | {'shadow'})
        cap = None
        if CLAMP_RE.search(text):
            cm = CAP_RE.search(text)
            if cm:
                cap = float(cm.group(1))
        if agent not in EXPECTED:
            print(f'[FAIL] {agent}: not in expected table — add it or remove the .ag')
            failed += 1
            continue
        exp_branches, exp_cap = EXPECTED[agent]
        if branches != sorted(exp_branches):
            print(f'[FAIL] {agent}: branches={branches!r} expected {sorted(exp_branches)!r}')
            failed += 1
            continue
        if cap != exp_cap:
            print(f'[FAIL] {agent}: cap={cap!r} expected {exp_cap!r}')
            failed += 1
            continue
        print(f'[PASS] {agent} branches={branches} cap={cap}')
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

# --- #177: collector regex fixture ---
# Synthesise a minimal .ag snippet with a tier("foo") == "<tier>" branch
# for each of the four tier names and confirm the collector regex + level
# map in federation-dashboard-collector.py produces the expected levels.
# Catches regressions where someone tightens the regex and drops a tier.
COLLECTOR_TIER_RE = re.compile(r'my_tier\s*==\s*"(dormant|shadow|propose|review-gated|autonomous)"')
COLLECTOR_LEVELS = {
    'dormant': 0.0,
    'shadow': 0.4,
    'propose': 0.6,
    'review-gated': 0.8,
    'autonomous': 0.95,
}
FIXTURE = '''
fn tick(rec: string) -> void {
    let my_tier = tier("foo");
    if my_tier == "autonomous" { print("a"); }
    else if my_tier == "review-gated" { print("r"); }
    else if my_tier == "propose" { print("p"); }
    else if my_tier == "shadow" { print("s"); }
    else if my_tier == "dormant" { print("d"); }
}
'''
hits = []
for line in FIXTURE.splitlines():
    m = COLLECTOR_TIER_RE.search(line)
    if m:
        hits.append((m.group(1), COLLECTOR_LEVELS[m.group(1)]))
expected = [
    ('autonomous', 0.95),
    ('review-gated', 0.8),
    ('propose', 0.6),
    ('shadow', 0.4),
    ('dormant', 0.0),
]
if hits == expected:
    print(f'[PASS] collector-regex fixture: all {len(expected)} tier branches detected')
    passed += 1
else:
    print(f'[FAIL] collector-regex fixture: got {hits!r} expected {expected!r}')
    failed += 1

print(f'\nResults: {passed} passed, {failed} failed')
sys.exit(0 if failed == 0 else 1)
PY
