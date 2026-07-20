#!/usr/bin/env bash
# research-foundry/tools/test-invariants.sh -- pins the environmental
# invariant modules under research-foundry/config/invariants/ (#1736).
#
# The three source-shape .inv modules reproduce auto-evolve-ab.sh's
# validity checks 3a/3b/3c verbatim via agentis-core payload v2 (#938):
#   parse-ok.inv      -> parse_ok         (check 3a: `agentis commit` parse gate)
#   tier-coverage.inv -> tier_coverage_ok (check 3b: tier() call + 3 literals)
#   cb-line.inv       -> has_cb_line      (check 3c: `cb <N>;` line)
#
# Two layers, mirroring the repo's agentis-optional convention (cf.
# test-auto-evolve-ab.sh): grammar assertions run always (pure grep);
# the fixture-based cull/pass assertions run only when `agentis`
# (>= v1.24.0, which ships `agentis invariant check`) is on PATH and are
# skipped otherwise.
#
# Usage: bash research-foundry/tools/test-invariants.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"
INV_DIR="$FED_DIR/config/invariants"

PASS=0
FAIL=0
SKIP=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Layer 1: grammar (module -> expected v2 source-shape field) -------
# Each .inv must carry exactly one `class = inviolable` directive and
# exactly one `when <field> == false` clause naming the field it mirrors.
# The boolean literal is UNQUOTED (== false, never == "false") -- a
# quoted literal is a type mismatch that agentis rejects at load.
check_module() {
    local file="$1" field="$2"
    local path="$INV_DIR/$file"
    if [ ! -f "$path" ]; then
        fail "grammar: $file exists" "missing at $path"
        return
    fi
    # Strip comments + blank lines so directive counts are exact.
    local body
    body="$(grep -vE '^[[:space:]]*(#|$)' "$path")"

    local class_count
    class_count="$(printf '%s\n' "$body" | grep -cE '^class[[:space:]]*=' || true)"
    if [ "$class_count" -eq 1 ] && printf '%s\n' "$body" | grep -qE '^class[[:space:]]*=[[:space:]]*inviolable[[:space:]]*$'; then
        pass "grammar: $file has exactly one 'class = inviolable' directive"
    else
        fail "grammar: $file class directive" "want exactly one 'class = inviolable', got $class_count class line(s)"
    fi

    local when_count
    when_count="$(printf '%s\n' "$body" | grep -cE '^when[[:space:]]' || true)"
    if [ "$when_count" -eq 1 ] && printf '%s\n' "$body" | grep -qE "^when[[:space:]]+${field}[[:space:]]*==[[:space:]]*false[[:space:]]*$"; then
        pass "grammar: $file has exactly one 'when $field == false' clause"
    else
        fail "grammar: $file when clause" "want exactly one 'when $field == false', got $when_count when line(s)"
    fi

    # Guard against a quoted boolean literal (silently never fires).
    if printf '%s\n' "$body" | grep -qE '==[[:space:]]*"'; then
        fail "grammar: $file boolean literal unquoted" "found a quoted literal (== \"...\"), which agentis rejects"
    else
        pass "grammar: $file boolean literal is unquoted"
    fi
}

check_module "parse-ok.inv" "parse_ok"
check_module "tier-coverage.inv" "tier_coverage_ok"
check_module "cb-line.inv" "has_cb_line"

# --- Layer 2: fixture-based cull/pass (requires agentis >= v1.24.0) -----
if ! command -v agentis >/dev/null 2>&1; then
    skip "invariant check fixtures (agentis not on PATH)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    [ "$FAIL" -eq 0 ]
    exit $?
fi

WORK="$TMP/work"
mkdir -p "$WORK"
( cd "$WORK" && agentis init >/dev/null 2>&1 ) || true
# Point the harness config at the checked-in module dir (absolute path;
# the daemon/CLI run from a fixed WORKDIR in the real container too).
printf 'evolution.invariants_dir = %s\n' "$INV_DIR" >> "$WORK/.agentis/config"

# Valid fixture: parses, has a cb line, and the full tier contract.
cat > "$TMP/valid.ag" <<'AGEOF'
cb 200;
fn tick(_r: string) -> void {
    let t = tier("probe");
    if t == "autonomous" { } else { if t == "review-gated" { } else { if t == "propose" { } else { } } }
}
AGEOF

# parse_ok violation: syntax error; cb line + tier literals present as
# TEXT so only parse-ok fires.
cat > "$TMP/bad-parse.ag" <<'AGEOF'
cb 200;
// "propose" "review-gated" "autonomous" tier("x")
fn tick(_r: string) -> void { let broken = @@@ ; }
AGEOF

# tier_coverage_ok violation: parses, has cb line, but no tier contract.
cat > "$TMP/bad-tier.ag" <<'AGEOF'
cb 200;
fn tick(_r: string) -> void { let x = 1; }
AGEOF

# has_cb_line violation: parses, has the tier contract, but no `cb <N>;`.
cat > "$TMP/bad-cb.ag" <<'AGEOF'
fn tick(_r: string) -> void {
    let t = tier("probe");
    if t == "autonomous" { } else { if t == "review-gated" { } else { if t == "propose" { } else { } } }
}
AGEOF

# `agentis invariant check` self-exits: 0=pass, 3=cull, 1=error.
inv_check() {
    local fixture="$1"
    ( cd "$WORK" && agentis invariant check "$fixture" --json ) >/dev/null 2>&1
}

inv_check "$TMP/valid.ag" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    pass "fixture: valid candidate passes (exit 0)"
else
    fail "fixture: valid candidate passes" "expected exit 0, got $rc"
fi

for pair in "bad-parse.ag:parse_ok" "bad-tier.ag:tier_coverage_ok" "bad-cb.ag:has_cb_line"; do
    fx="${pair%%:*}"; field="${pair##*:}"
    inv_check "$TMP/$fx" && rc=0 || rc=$?
    if [ "$rc" -eq 3 ]; then
        pass "fixture: $field violation is culled (exit 3)"
    else
        fail "fixture: $field violation is culled" "expected exit 3, got $rc"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
