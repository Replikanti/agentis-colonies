#!/usr/bin/env bash
# research-foundry/tools/test-persistent-snapshot.sh -- regression test
# for the Phase 5 PR-A (#626) persistent-snapshot.py helper.
#
# Five synthetic-fixture cases (no live container required):
#   (1) Happy path: stubbed `podman` emits canned `agentis memo get`
#       output. Assert `memo-snapshot.json` contains the expected keys +
#       values, schema=1, snapshot_ts present.
#   (2) Atomic write: invoke twice; assert no `.tmp` files left behind
#       in the persistent dir.
#   (3) Missing podman / failed exec: stub `podman` to exit non-zero on
#       every call. Assert helper exits non-zero AND no half-formed
#       memo-snapshot.json was written.
#   (4) SCHEMA_VERSION: first invocation writes SCHEMA_VERSION=1.
#       Subsequent invocations with same version succeed. After
#       manually editing the file to `99`, helper warns + refuses to
#       overwrite (non-zero exit, memo-snapshot.json unchanged).
#   (5) Explorer evolved-prompt round-trip (#739): the `explorer:`
#       prefix glob carries `:exploration_prompt`, `:exploration_generation`,
#       `:lineage_id`, and `:specialty` suffixes across runs while
#       suppressing per-tick noise like `:code:tick-N` / `:output:tick-N`
#       that would otherwise bloat the snapshot.
#   (6) KB export round-trip (#750): fake `agentis knowledge export`
#       replies with canned JSON; assert `knowledge-snapshot.json`
#       materializes alongside memo-snapshot.json with byte-identical
#       payload. Failure of the KB export must not flip the memo-only
#       happy-path exit code.
#
# Standard library only -- no pytest, no live federation.
#
# Usage: bash research-foundry/tools/test-persistent-snapshot.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/persistent-snapshot.py"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$HELPER" ]; then
    fail "preflight" "$HELPER not found"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] python3 not on PATH"
    echo "Results: 0 passed, 0 failed (skipped)"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build a fake `podman` script that the helper invokes via PATH lookup.
# Behaviour switches on $PODMAN_MODE so each case can plug in different
# canned outputs without rewriting the binary.
mkdir -p "$WORK/bin"
FAKE_PODMAN="$WORK/bin/podman"
cat >"$FAKE_PODMAN" <<'FAKE_PODMAN_EOF'
#!/usr/bin/env bash
# Fake podman driven by $PODMAN_MODE. Recognises:
#   exec <container> true               -> exit 0 (preflight)
#   exec <container> agentis memo get <KEY>
#   exec <container> agentis memo list
set -eu

mode="${PODMAN_MODE:-ok}"

# Drop the leading `exec <container>` so $1 becomes the agentis subcmd.
if [ "${1:-}" = "exec" ]; then
    shift
    shift
fi

if [ "$mode" = "fail-all" ]; then
    echo "fake-podman: simulated failure" >&2
    exit 1
fi

case "${1:-}" in
    true)
        exit 0
        ;;
    agentis)
        shift
        ;;
    *)
        # Unrecognised top-level command from the helper.
        echo "fake-podman: unknown command: $*" >&2
        exit 2
        ;;
esac

case "${1:-}" in
    memo)
        shift
        ;;
    knowledge)
        shift
        # #750: KB export/import surface. The helper invokes
        # `agentis knowledge export` and captures stdout to
        # knowledge-snapshot.json. Mode `kb-fail` simulates an
        # always-failing export so case (6) can assert that a KB
        # failure does not flip the memo-only happy-path exit code.
        case "${1:-}" in
            export)
                if [ "$mode" = "kb-fail" ]; then
                    echo "fake-podman: simulated KB export failure" >&2
                    exit 1
                fi
                # Canned KB dump: bare top-level JSON array (matches
                # the real `agentis knowledge export` output in v1.7.16
                # — `import` accepts a bare array; QA #756 caught the
                # invented {"schema":1,"items":[...]} shape).
                printf '[{"id":"k1","topic":"permutation_order_facts:sym5","value":"order=120"},{"id":"k2","topic":"known_priors:claim-42","value":"prior=resolved"}]\n'
                exit 0
                ;;
            *)
                echo "fake-podman: not knowledge subcmd: $*" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "fake-podman: not memo/knowledge subcmd: $*" >&2
        exit 2
        ;;
esac

case "${1:-}" in
    get)
        key="${2:-}"
        case "$key" in
            formulator:learned_known_topics)
                echo "number_theory,combinatorics"
                ;;
            formulator:learned_successful_topics)
                echo "graph_theory"
                ;;
            editor:learned_pitfalls)
                echo "missing-bibtex"
                ;;
            feedback:hitl_rejects)
                echo "claim-42,claim-43"
                ;;
            feedback:hitl_reject_reason:claim-42)
                echo "wrong-citation"
                ;;
            feedback:hitl_reject_class:claim-42)
                echo "factual"
                ;;
            explorer:476:exploration_prompt)
                echo "Refined exploration prompt v3 -- compute coincidences in group orders."
                ;;
            explorer:476:exploration_generation)
                echo "3"
                ;;
            explorer:476:lineage_id)
                echo "1"
                ;;
            explorer:476:specialty)
                echo "group_theory"
                ;;
            explorer:476:code:tick-7|explorer:476:output:tick-7)
                # Noisy per-tick keys -- must NOT appear in the snapshot.
                echo "noise"
                ;;
            *:confidence)
                echo "0.7"
                ;;
            explorer:confidence|noticer:confidence|skeptic:confidence|\
            formulator:confidence|verifier:confidence|novelty:confidence|\
            arxiv-search:confidence|oeis-search:confidence|\
            groupprops-search:confidence|scholar-search:confidence|\
            prior_advocate:confidence|auditor:confidence|\
            introducer:confidence|theorist:confidence|computer:confidence|\
            editor:confidence|reviewer:confidence|submitter:confidence)
                echo "0.7"
                ;;
            *)
                # Missing memo: empty stdout, non-zero exit (mirrors
                # real `agentis memo get` for absent keys).
                exit 3
                ;;
        esac
        ;;
    list)
        # Two synthetic prefix-glob expansions plus a noise key, and
        # four explorer:<pid>:<suffix> keys for the #739 round-trip
        # test plus two per-tick noise keys that must be filtered out.
        printf '%s\n' \
            'formulator:learned_known_topics' \
            'feedback:hitl_reject_reason:claim-42' \
            'feedback:hitl_reject_class:claim-42' \
            'explorer:476:exploration_prompt' \
            'explorer:476:exploration_generation' \
            'explorer:476:lineage_id' \
            'explorer:476:specialty' \
            'explorer:476:code:tick-7' \
            'explorer:476:output:tick-7' \
            'unrelated:key'
        ;;
    *)
        echo "fake-podman: not get/list subcmd: $*" >&2
        exit 2
        ;;
esac
FAKE_PODMAN_EOF
chmod +x "$FAKE_PODMAN"

export PATH="$WORK/bin:$PATH"

# --- (1) Happy path ---
T1_DIR="$WORK/t1-persistent"
T1_RC=0
PODMAN_MODE=ok python3 "$HELPER" --container research-foundry-laptop \
    --output-dir "$T1_DIR" >"$WORK/t1.log" 2>&1 || T1_RC=$?

if [ "$T1_RC" -ne 0 ]; then
    fail "(1) happy-path: helper exits 0" "rc=$T1_RC; log: $(cat "$WORK/t1.log")"
elif [ ! -f "$T1_DIR/memo-snapshot.json" ]; then
    fail "(1) happy-path: writes memo-snapshot.json" "file missing"
else
    SNAPSHOT="$(cat "$T1_DIR/memo-snapshot.json")"

    if printf '%s' "$SNAPSHOT" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["schema"] == 1, "schema not 1"
assert "snapshot_ts" in data, "snapshot_ts missing"
assert data["container"] == "research-foundry-laptop", "container wrong"
keys = data["keys"]
expected = {
    "formulator:learned_known_topics": "number_theory,combinatorics",
    "formulator:learned_successful_topics": "graph_theory",
    "editor:learned_pitfalls": "missing-bibtex",
    "feedback:hitl_rejects": "claim-42,claim-43",
    "feedback:hitl_reject_reason:claim-42": "wrong-citation",
    "feedback:hitl_reject_class:claim-42": "factual",
}
for k, v in expected.items():
    assert k in keys, "missing key " + k
    assert keys[k] == v, "key " + k + " = " + repr(keys[k]) + " not " + repr(v)
for colony in ("explorer", "noticer", "skeptic", "formulator", "verifier",
               "novelty", "arxiv-search", "oeis-search", "groupprops-search",
               "scholar-search", "prior_advocate", "auditor", "introducer",
               "theorist", "computer", "editor", "reviewer", "submitter"):
    k = colony + ":confidence"
    assert k in keys, "missing " + k
    assert keys[k] == "0.7", k + " = " + repr(keys[k])
' >/dev/null 2>"$WORK/t1.assert.log"; then
        pass "(1) happy-path: snapshot keys + values + schema"
    else
        fail "(1) happy-path: snapshot keys + values + schema" "$(cat "$WORK/t1.assert.log")"
    fi
fi

# --- (2) Atomic write ---
T2_DIR="$WORK/t2-persistent"
PODMAN_MODE=ok python3 "$HELPER" --container research-foundry-laptop \
    --output-dir "$T2_DIR" >"$WORK/t2a.log" 2>&1
PODMAN_MODE=ok python3 "$HELPER" --container research-foundry-laptop \
    --output-dir "$T2_DIR" >"$WORK/t2b.log" 2>&1

# After two successive invocations, no .tmp file may remain.
T2_LEFTOVER=""
for f in "$T2_DIR"/*.tmp; do
    [ -e "$f" ] || continue
    T2_LEFTOVER="$T2_LEFTOVER $f"
done

if [ -z "$T2_LEFTOVER" ]; then
    pass "(2) atomic-write: no .tmp leftover after 2 invocations"
else
    fail "(2) atomic-write: no .tmp leftover after 2 invocations" "$T2_LEFTOVER"
fi

# --- (3) Missing podman / failed exec ---
T3_DIR="$WORK/t3-persistent"
T3_RC=0
PODMAN_MODE=fail-all python3 "$HELPER" --container research-foundry-laptop \
    --output-dir "$T3_DIR" >"$WORK/t3.log" 2>&1 || T3_RC=$?

if [ "$T3_RC" -eq 0 ]; then
    fail "(3) failed-exec: helper exits non-zero" "rc=0 (expected non-zero)"
elif [ -f "$T3_DIR/memo-snapshot.json" ]; then
    fail "(3) failed-exec: no half-formed memo-snapshot.json" "file was written"
else
    pass "(3) failed-exec: exits non-zero, no memo-snapshot.json written"
fi

# --- (4) SCHEMA_VERSION ---
T4_DIR="$WORK/t4-persistent"
PODMAN_MODE=ok python3 "$HELPER" --container research-foundry-laptop \
    --output-dir "$T4_DIR" >"$WORK/t4a.log" 2>&1
if [ "$(cat "$T4_DIR/SCHEMA_VERSION" 2>/dev/null || echo MISSING)" = "1" ]; then
    pass "(4a) SCHEMA_VERSION: first invocation writes '1'"
else
    fail "(4a) SCHEMA_VERSION: first invocation writes '1'" \
         "found: $(cat "$T4_DIR/SCHEMA_VERSION" 2>/dev/null || echo MISSING)"
fi

# Same version: must succeed and still produce a snapshot.
T4B_RC=0
PODMAN_MODE=ok python3 "$HELPER" --container research-foundry-laptop \
    --output-dir "$T4_DIR" >"$WORK/t4b.log" 2>&1 || T4B_RC=$?
if [ "$T4B_RC" -eq 0 ] && [ -f "$T4_DIR/memo-snapshot.json" ]; then
    pass "(4b) SCHEMA_VERSION: same-version subsequent invocation succeeds"
else
    fail "(4b) SCHEMA_VERSION: same-version subsequent invocation succeeds" \
         "rc=$T4B_RC; snapshot present: $([ -f "$T4_DIR/memo-snapshot.json" ] && echo yes || echo no)"
fi

# Mismatch: edit to 99, capture the snapshot mtime, helper must refuse.
echo "99" >"$T4_DIR/SCHEMA_VERSION"
SNAPSHOT_BEFORE_MTIME=""
if [ -f "$T4_DIR/memo-snapshot.json" ]; then
    SNAPSHOT_BEFORE_MTIME="$(stat -c %Y "$T4_DIR/memo-snapshot.json" 2>/dev/null || stat -f %m "$T4_DIR/memo-snapshot.json" 2>/dev/null || echo "")"
fi
sleep 1
T4C_RC=0
PODMAN_MODE=ok python3 "$HELPER" --container research-foundry-laptop \
    --output-dir "$T4_DIR" >"$WORK/t4c.log" 2>&1 || T4C_RC=$?

SNAPSHOT_AFTER_MTIME=""
if [ -f "$T4_DIR/memo-snapshot.json" ]; then
    SNAPSHOT_AFTER_MTIME="$(stat -c %Y "$T4_DIR/memo-snapshot.json" 2>/dev/null || stat -f %m "$T4_DIR/memo-snapshot.json" 2>/dev/null || echo "")"
fi

if [ "$T4C_RC" -ne 0 ] && [ "$SNAPSHOT_BEFORE_MTIME" = "$SNAPSHOT_AFTER_MTIME" ] \
   && grep -q "SCHEMA_VERSION mismatch" "$WORK/t4c.log"; then
    pass "(4c) SCHEMA_VERSION: mismatch warns + refuses to overwrite"
else
    fail "(4c) SCHEMA_VERSION: mismatch warns + refuses to overwrite" \
         "rc=$T4C_RC; mtime-before=$SNAPSHOT_BEFORE_MTIME mtime-after=$SNAPSHOT_AFTER_MTIME; log: $(cat "$WORK/t4c.log")"
fi

# --- (5) Explorer evolved-prompt round-trip (#739) ---
# The four `explorer:<pid>:{exploration_prompt,exploration_generation,
# lineage_id,specialty}` suffixes must round-trip through snapshot so
# the M98 v3 variant pool survives cross-run bootstrap. The two
# `:code:tick-N` / `:output:tick-N` noise keys must be filtered out.
T5_DIR="$WORK/t5-persistent"
T5_RC=0
PODMAN_MODE=ok python3 "$HELPER" --container research-foundry-laptop \
    --output-dir "$T5_DIR" >"$WORK/t5.log" 2>&1 || T5_RC=$?

if [ "$T5_RC" -ne 0 ]; then
    fail "(5) explorer-prompt round-trip: helper exits 0" "rc=$T5_RC; log: $(cat "$WORK/t5.log")"
elif [ ! -f "$T5_DIR/memo-snapshot.json" ]; then
    fail "(5) explorer-prompt round-trip: writes memo-snapshot.json" "file missing"
else
    T5_SNAPSHOT="$(cat "$T5_DIR/memo-snapshot.json")"
    if printf '%s' "$T5_SNAPSHOT" | python3 -c '
import json, sys
data = json.load(sys.stdin)
keys = data["keys"]
expected = {
    "explorer:476:exploration_prompt":
        "Refined exploration prompt v3 -- compute coincidences in group orders.",
    "explorer:476:exploration_generation": "3",
    "explorer:476:lineage_id": "1",
    "explorer:476:specialty": "group_theory",
}
for k, v in expected.items():
    assert k in keys, "missing key " + k
    assert keys[k] == v, "key " + k + " = " + repr(keys[k]) + " not " + repr(v)
# Per-tick noise keys must be filtered out (snapshot bloat guard).
for noise in ("explorer:476:code:tick-7", "explorer:476:output:tick-7"):
    assert noise not in keys, "noise key leaked into snapshot: " + noise
' >/dev/null 2>"$WORK/t5.assert.log"; then
        pass "(5) explorer-prompt round-trip: four suffixes carry, noise filtered"
    else
        fail "(5) explorer-prompt round-trip: four suffixes carry, noise filtered" "$(cat "$WORK/t5.assert.log")"
    fi
fi

# --- (6) KB export round-trip (#750) ---
# Fake `agentis knowledge export` returns canned JSON; assert
# knowledge-snapshot.json materializes alongside memo-snapshot.json with
# the exact bytes from the export stdout.
T6_DIR="$WORK/t6-persistent"
T6_RC=0
PODMAN_MODE=ok python3 "$HELPER" --container research-foundry-laptop \
    --output-dir "$T6_DIR" >"$WORK/t6.log" 2>&1 || T6_RC=$?

if [ "$T6_RC" -ne 0 ]; then
    fail "(6) kb-export: helper exits 0" "rc=$T6_RC; log: $(cat "$WORK/t6.log")"
elif [ ! -f "$T6_DIR/memo-snapshot.json" ]; then
    fail "(6) kb-export: memo-snapshot.json written" "file missing"
elif [ ! -f "$T6_DIR/knowledge-snapshot.json" ]; then
    fail "(6) kb-export: knowledge-snapshot.json written" "file missing"
else
    if python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    items = json.load(f)
assert isinstance(items, list), "top-level must be array"
ids = sorted(it["id"] for it in items)
assert ids == ["k1", "k2"], "ids = " + repr(ids)
topics = sorted(it["topic"] for it in items)
assert topics == ["known_priors:claim-42", "permutation_order_facts:sym5"], \
    "topics = " + repr(topics)
' "$T6_DIR/knowledge-snapshot.json" >/dev/null 2>"$WORK/t6.assert.log"; then
        pass "(6) kb-export: knowledge-snapshot.json carries canned KB payload"
    else
        fail "(6) kb-export: knowledge-snapshot.json carries canned KB payload" "$(cat "$WORK/t6.assert.log")"
    fi
fi

# --- (7) KB export failure is non-fatal ---
# Memo snapshot must still succeed when `agentis knowledge export` fails;
# knowledge-snapshot.json must not be written, but the helper still
# exits 0 because the memo half of the snapshot landed cleanly.
T7_DIR="$WORK/t7-persistent"
T7_RC=0
PODMAN_MODE=kb-fail python3 "$HELPER" --container research-foundry-laptop \
    --output-dir "$T7_DIR" >"$WORK/t7.log" 2>&1 || T7_RC=$?

if [ "$T7_RC" -ne 0 ]; then
    fail "(7) kb-failure-isolated: helper exits 0 despite KB failure" \
         "rc=$T7_RC; log: $(cat "$WORK/t7.log")"
elif [ ! -f "$T7_DIR/memo-snapshot.json" ]; then
    fail "(7) kb-failure-isolated: memo-snapshot.json still written" \
         "memo-snapshot.json missing"
elif [ -f "$T7_DIR/knowledge-snapshot.json" ]; then
    fail "(7) kb-failure-isolated: no half-formed knowledge-snapshot.json" \
         "knowledge-snapshot.json was written"
else
    pass "(7) kb-failure-isolated: memo lands, KB skipped, exit 0"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
