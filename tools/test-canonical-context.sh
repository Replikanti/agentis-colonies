#!/bin/bash
# tools/test-canonical-context.sh: drift sentinel + fixture pins for the
# shared canonical-context builder (#1431).
#
# tools/lib/canonical-context.py must emit byte-identical condition strings
# to the inline builders in triage/agents/{labeler,router,prioritizer}.ag —
# otherwise backfilled rules are unreachable from Stage 1 prefix replay and
# Stage 1b BM25 class-confirm. Two layers:
#
#   1. VOCAB drift: the keyword vocabulary literal in the python helper must
#      equal the inline VOCAB literal in EACH agent byte-for-byte (the
#      agents' literals are themselves asserted mutually identical).
#   2. Pinned fixture outputs: known raw issues (GitLab and GitHub shapes)
#      must produce the exact pinned ctx/coarse/action strings for each
#      class, including the priority-like exclusion and scope semantics.
#
# Usage: ./tools/test-canonical-context.sh
# Exit code 0 if all assertions pass, 1 otherwise.

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FED="$REPO_ROOT/dev-apprenticeship"
CANON="$REPO_ROOT/tools/lib/canonical-context.py"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# ----- 1. VOCAB drift -----

# Canonical form: VOCAB=["bug","crash",...] with no whitespace.
PY_VOCAB="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cc", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print("VOCAB=[" + ",".join("\"" + w + "\"" for w in mod.VOCAB) + "]")
' "$CANON")"

for agent in labeler router prioritizer; do
    AG="$FED/triage/agents/$agent.ag"
    # The inline literal lives in an .ag string: "VOCAB=[\"bug\",...]\n".
    # Strip the escaping backslashes to recover the canonical form.
    # \134 is octal for backslash (avoids shellcheck SC1003 on a quoted
    # backslash literal).
    AG_VOCAB="$(grep -o 'VOCAB=\[[^]]*\]' "$AG" | head -1 | tr -d '\134')"
    if [ -z "$AG_VOCAB" ]; then
        fail "$agent: inline VOCAB literal not found"
    elif [ "$AG_VOCAB" = "$PY_VOCAB" ]; then
        pass "$agent: inline VOCAB matches tools/lib/canonical-context.py"
    else
        fail "$agent: VOCAB drift — agent='$AG_VOCAB' helper='$PY_VOCAB'"
    fi
done

# ----- 2. Pinned fixture outputs -----

FIX_DIR="$(mktemp -d)"
trap 'rm -rf "$FIX_DIR"' EXIT

# GitLab-shaped: labeled + assigned + prioritized, author == operator.
cat > "$FIX_DIR/gl.json" <<'JSON'
{"iid": 7, "title": "Crash: segfault in parser build",
 "description": "It fails with panic",
 "labels": ["bug", "P1"],
 "assignees": [{"username": "alice"}],
 "author": {"username": "mholy"},
 "updated_at": "2026-07-01T10:00:00Z"}
JSON

# GitHub-shaped: label objects, no assignee, no priority-like label.
cat > "$FIX_DIR/gh.json" <<'JSON'
{"number": 12, "title": "Update docs for CI", "body": "",
 "labels": [{"name": "documentation"}],
 "assignees": [],
 "user": {"login": "bob"},
 "updated_at": "2026-07-02T10:00:00Z"}
JSON

run_issue() {
    local klass="$1" file="$2"
    ME="mholy" PV="priority::critical, priority::high, P1, P2" \
        python3 "$CANON" issue --class "$klass" < "$file"
}

assert_line() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        pass "$desc"
    else
        fail "$desc — got '$got' want '$want'"
    fi
}

# label class, GitLab fixture: keyword hits from title+description
# (build, crash, panic, segfault — "fails" does NOT match "fail": exact
# token membership, mirrors the agents' `w in toks`), personal scope
# (author == ME), action excludes the priority-like P1.
assert_line "label/gl pinned output" \
    "$(run_issue label "$FIX_DIR/gl.json")" \
    "$(printf '7\tkw=build,crash,panic,segfault scope=personal\tkw=build,crash,panic,segfault\tbug\tCrash: segfault in parser build It fails with panic')"

# route class, GitLab fixture: keywords from title only, ALL labels in ctx
# (sorted; ASCII P1 < bug), action = first assignee.
assert_line "route/gl pinned output" \
    "$(run_issue route "$FIX_DIR/gl.json")" \
    "$(printf '7\tkw=build,crash,segfault labels=P1,bug\tkw=build,crash,segfault\talice\tCrash: segfault in parser build P1 bug')"

# prioritize class, GitLab fixture: ctx carries only NON-priority labels,
# action = the priority-like label.
assert_line "prioritize/gl pinned output" \
    "$(run_issue prioritize "$FIX_DIR/gl.json")" \
    "$(printf '7\tkw=build,crash,segfault labels=bug\tkw=build,crash,segfault\tP1\tCrash: segfault in parser build bug')"

# label class, GitHub fixture: label-object normalization, team scope.
assert_line "label/gh pinned output" \
    "$(run_issue label "$FIX_DIR/gh.json")" \
    "$(printf '12\tkw=ci,docs scope=team\tkw=ci,docs\tdocumentation\tUpdate docs for CI')"

# Undecided cases emit nothing.
assert_line "route/gh undecided (no assignee) emits nothing" \
    "$(run_issue route "$FIX_DIR/gh.json")" ""
assert_line "prioritize/gh undecided (no priority-like label) emits nothing" \
    "$(run_issue prioritize "$FIX_DIR/gh.json")" ""

# ----- 3. triples mode: --since filter + --max + cursor -----

{
    printf '['
    cat "$FIX_DIR/gl.json"
    printf ','
    cat "$FIX_DIR/gh.json"
    printf ']'
} > "$FIX_DIR/all.json"

TRIPLES="$(ME="mholy" PV="P1" python3 "$CANON" triples \
    --classes label,route,prioritize --max 10 \
    --cursor-out "$FIX_DIR/cursor" < "$FIX_DIR/all.json")"
N_ALL="$(printf '%s\n' "$TRIPLES" | grep -c . || true)"
# gl: label + route + prioritize = 3; gh: label only = 1.
assert_line "triples mode emits 4 triples for the 2-issue fixture" "$N_ALL" "4"
assert_line "cursor-out carries the max updated_at" \
    "$(cat "$FIX_DIR/cursor")" "2026-07-02T10:00:00Z"

TRIPLES_SINCE="$(ME="mholy" PV="P1" python3 "$CANON" triples \
    --classes label --since "2026-07-01T10:00:00Z" < "$FIX_DIR/all.json")"
N_SINCE="$(printf '%s\n' "$TRIPLES_SINCE" | grep -c . || true)"
assert_line "--since strictly-greater filter drops the older issue" "$N_SINCE" "1"

# ----- 4. --order oldest + --max: monotonic incremental cursor -----
# The incremental caller (backfill-crystallizer.sh --incremental) MUST use
# oldest-first: with newest-first, a window holding more than --max issues
# would advance the cursor past the un-processed older tail and skip it
# forever. With --order oldest --max 1 on the 2-issue fixture, the OLDER
# issue (gl, 2026-07-01) is processed and the cursor lands on ITS
# timestamp — not on the newest issue's — so the next run picks up gh.
TRIPLES_OLD="$(ME="mholy" PV="P1" python3 "$CANON" triples \
    --classes label --max 1 --order oldest \
    --cursor-out "$FIX_DIR/cursor-old" < "$FIX_DIR/all.json")"
assert_line "--order oldest --max 1 processes the older issue first" \
    "$(printf '%s\n' "$TRIPLES_OLD" | grep -c '"iid": 7' || true)" "1"
assert_line "oldest-first cursor stays at the processed slice's max (monotonic)" \
    "$(cat "$FIX_DIR/cursor-old")" "2026-07-01T10:00:00Z"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
