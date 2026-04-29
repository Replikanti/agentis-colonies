#!/bin/bash
# tools/test-cross-repo-refs.sh: unit tests for the #317 cross-repo
# reference detection helpers.
#
# 7 test cases, per plan §7:
#   1. Scanner positive — body containing `acme/backend#42` plus prose.
#   2. Scanner negative — path-like (`foo/bar/baz#1`), line ref (`x/y#L42`),
#      no-slash forms — all rejected.
#   3. Scanner self-ref filter — `--self acme/own` drops `acme/own#7`,
#      keeps `other/repo#3`.
#   4. Cache TTL fresh — put + immediate get returns the record.
#   5. Cache TTL expired — put + sleep past TTL_SECS=1 + get returns miss.
#   6. Resolver with stub forge-api — success path renders markdown +
#      out-of-config-repo path tombstones silently. Also asserts cache
#      file does NOT contain substring `token` (case-insensitive).
#   7. closed-by index roundtrip + idempotency — record same (src,tgt)
#      twice, lookup returns one entry.
#
# Standard scaffold: set -eu, mktemp -d isolation, EXIT trap for cleanup.
# Auto-discovered by tools/colony-lint.sh's tools-test loop.
#
# Usage: ./tools/test-cross-repo-refs.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCAN="$SCRIPT_DIR/scan-cross-repo-refs.sh"
CACHE="$SCRIPT_DIR/cross-repo-cache.sh"
RESOLVE="$SCRIPT_DIR/resolve-cross-repo-ref.sh"
CLOSED="$SCRIPT_DIR/closed-by-index.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# --- Test 1: scanner positive --------------------------------------------
OUT="$TMPDIR_TEST/t1.out"
printf 'fixes acme/backend#42 and another bar/baz#17 thanks' \
    | "$SCAN" >"$OUT" 2>/dev/null
if grep -qx 'acme/backend#42' "$OUT" && grep -qx 'bar/baz#17' "$OUT" && [ "$(wc -l <"$OUT")" -eq 2 ]; then
    pass "test 1: scanner positive — emits both refs deduped"
else
    fail "test 1: scanner positive — emits both refs deduped" \
         "got='$(tr '\n' '|' <"$OUT")'"
fi

# --- Test 2: scanner negative (path/line-ref/no-slash) -------------------
OUT="$TMPDIR_TEST/t2.out"
printf 'a path foo/bar/baz#1 and line ref x/y#L42 and bare#5 should not match' \
    | "$SCAN" >"$OUT" 2>/dev/null
# foo/bar/baz#1 -> the "/baz" portion has a leading "/" which should fail
# the left-boundary lookbehind for the *outer* match (lookbehind sees `/`).
# x/y#L42 -> #L42 form is filtered by the (?!L\d) negative lookahead.
# bare#5 -> no slash -> regex doesn't match.
if [ ! -s "$OUT" ]; then
    pass "test 2: scanner negative — path-like / line-ref / no-slash all rejected"
else
    fail "test 2: scanner negative — path-like / line-ref / no-slash all rejected" \
         "got='$(tr '\n' '|' <"$OUT")'"
fi

# --- Test 3: scanner self-ref filter -------------------------------------
OUT="$TMPDIR_TEST/t3.out"
printf 'self-ref acme/own#7 and cross other/repo#3 here' \
    | "$SCAN" --self acme/own >"$OUT" 2>/dev/null
if grep -qx 'other/repo#3' "$OUT" && ! grep -q 'acme/own' "$OUT"; then
    pass "test 3: scanner --self filters self-references"
else
    fail "test 3: scanner --self filters self-references" \
         "got='$(tr '\n' '|' <"$OUT")'"
fi

# --- Test 4: cache TTL fresh --------------------------------------------
COLONY_DIR_T4="$TMPDIR_TEST/t4-fed/colony"
mkdir -p "$COLONY_DIR_T4"
RECORD_T4='{"owner":"acme","repo":"backend","number":42,"title":"hello","state":"opened","labels":["bug"],"fetched_at":"2026-04-28T14:32:11Z"}'
printf '%s' "$RECORD_T4" | "$CACHE" put --colony-dir "$COLONY_DIR_T4" acme backend 42 >/dev/null
# Set a generous TTL so the test isn't sensitive to clock drift.
GOT_T4="$(CROSS_REPO_CACHE_TTL_SECS=99999999999 "$CACHE" get --colony-dir "$COLONY_DIR_T4" acme backend 42 2>/dev/null | tr -d '\n')"
EXPECTED_T4="$RECORD_T4"
if [ "$GOT_T4" = "$EXPECTED_T4" ]; then
    pass "test 4: cache TTL fresh — put + get returns identical record"
else
    fail "test 4: cache TTL fresh — put + get returns identical record" \
         "got='$GOT_T4' expected='$EXPECTED_T4'"
fi

# --- Test 5: cache TTL expired ------------------------------------------
COLONY_DIR_T5="$TMPDIR_TEST/t5-fed/colony"
mkdir -p "$COLONY_DIR_T5"
# Forge a record with an old fetched_at timestamp (2020-01-01) so any
# positive TTL trips the expiry branch without sleep dependency.
RECORD_T5='{"owner":"acme","repo":"backend","number":42,"title":"old","state":"opened","labels":[],"fetched_at":"2020-01-01T00:00:00Z"}'
printf '%s' "$RECORD_T5" | "$CACHE" put --colony-dir "$COLONY_DIR_T5" acme backend 42 >/dev/null
rc_t5=0
CROSS_REPO_CACHE_TTL_SECS=1 "$CACHE" get --colony-dir "$COLONY_DIR_T5" acme backend 42 >/dev/null 2>&1 || rc_t5=$?
if [ "$rc_t5" -eq 1 ]; then
    pass "test 5: cache TTL expired — get returns miss (exit 1)"
else
    fail "test 5: cache TTL expired — get returns miss (exit 1)" \
         "rc=$rc_t5 (expected 1)"
fi

# --- Test 6: resolver with stub forge-api -------------------------------
COLONY_DIR_T6="$TMPDIR_TEST/t6-fed/colony"
mkdir -p "$COLONY_DIR_T6/scripts"
# Stub forge-api.sh: exit 0 with normalized GitLab-shape issue JSON for
# acme/backend#42; exit 2 for any other --repo (mimics the real
# dispatcher's out-of-config behaviour).
cat >"$COLONY_DIR_T6/scripts/forge-api.sh" <<'STUB'
#!/bin/bash
set -e
CMD="$1"; shift
NUM=""
REPO=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        *) if [ -z "$NUM" ]; then NUM="$1"; fi; shift ;;
    esac
done
if [ "$CMD" != "get-issue" ]; then exit 2; fi
if [ "$REPO" = "acme/backend" ] && [ "$NUM" = "42" ]; then
    cat <<JSON
{"iid":42,"title":"Login crash on Safari","description":"…","state":"opened","labels":["bug","P1"],"assignees":[],"author":{"username":"alice"},"created_at":"2026-04-28T10:00:00Z","updated_at":"2026-04-28T11:00:00Z","user_notes_count":3}
JSON
    exit 0
fi
exit 2
STUB
chmod +x "$COLONY_DIR_T6/scripts/forge-api.sh"

OUT="$TMPDIR_TEST/t6.out"
printf 'acme/backend#42\nout-of-config/repo#99\n' \
    | "$RESOLVE" --colony-dir "$COLONY_DIR_T6" --max 5 >"$OUT" 2>/dev/null
if grep -q '## Cross-repo references mentioned in this PR' "$OUT" \
    && grep -q 'acme/backend#42' "$OUT" \
    && grep -q 'Login crash on Safari' "$OUT" \
    && ! grep -q 'out-of-config' "$OUT"; then
    pass "test 6a: resolver — success path renders markdown, out-of-config silenced"
else
    fail "test 6a: resolver — success path renders markdown, out-of-config silenced" \
         "out='$(cat "$OUT")'"
fi

# Token leak guard: cache record must not contain the substring "token"
# (case-insensitive) — neither raw forge response nor reshaped record
# carries auth bytes by design.
CACHE_FILE_T6="$TMPDIR_TEST/t6-fed/.agentis/cross-repo-cache/acme__backend__42.json"
if [ -f "$CACHE_FILE_T6" ]; then
    if grep -iq 'token' "$CACHE_FILE_T6"; then
        fail "test 6b: token-leak guard — cache file MUST NOT contain 'token'" \
             "cache='$(cat "$CACHE_FILE_T6")'"
    else
        pass "test 6b: token-leak guard — cache file does not contain 'token' (case-insensitive)"
    fi
else
    fail "test 6b: token-leak guard — cache file does not contain 'token' (case-insensitive)" \
         "cache file missing: $CACHE_FILE_T6"
fi

# Tombstone for out-of-config repo: a JSON record with state=unresolvable.
TOMBSTONE_T6="$TMPDIR_TEST/t6-fed/.agentis/cross-repo-cache/out-of-config__repo__99.json"
if [ -f "$TOMBSTONE_T6" ] && grep -q 'unresolvable' "$TOMBSTONE_T6"; then
    pass "test 6c: resolver — out-of-config repo writes tombstone (state=unresolvable)"
else
    fail "test 6c: resolver — out-of-config repo writes tombstone (state=unresolvable)" \
         "tombstone='$( [ -f "$TOMBSTONE_T6" ] && cat "$TOMBSTONE_T6" || echo MISSING )'"
fi

# --- Test 7: closed-by index roundtrip + idempotency --------------------
COLONY_DIR_T7="$TMPDIR_TEST/t7-fed/colony"
mkdir -p "$COLONY_DIR_T7"
"$CLOSED" record --colony-dir "$COLONY_DIR_T7" \
    --src-owner acme --src-repo frontend --src-iid 47 \
    --tgt-owner acme --tgt-repo backend --tgt-iid 123 >/dev/null
# Second call with identical (src, tgt) — should be a no-op insert.
"$CLOSED" record --colony-dir "$COLONY_DIR_T7" \
    --src-owner acme --src-repo frontend --src-iid 47 \
    --tgt-owner acme --tgt-repo backend --tgt-iid 123 >/dev/null
LOOK_T7="$("$CLOSED" lookup --colony-dir "$COLONY_DIR_T7" \
    --tgt-owner acme --tgt-repo backend --tgt-iid 123 2>/dev/null)"
COUNT_T7=$(printf '%s' "$LOOK_T7" | python3 -c 'import sys,json; print(len(json.loads(sys.stdin.read() or "[]")))')
if [ "$COUNT_T7" = "1" ] && printf '%s' "$LOOK_T7" | grep -q 'frontend'; then
    pass "test 7: closed-by index — record idempotent on (src,tgt); lookup returns 1 entry"
else
    fail "test 7: closed-by index — record idempotent on (src,tgt); lookup returns 1 entry" \
         "count=$COUNT_T7 lookup='$LOOK_T7'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
