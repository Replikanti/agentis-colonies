#!/bin/bash
# tools/test-snapshot-publish-bound.sh: regression tests for the #1466 fix —
# the triage shared-snapshot publish path used to fail silently once the
# compressed envelope exceeded the runtime's ~10240-byte memo value cap, while
# the freshness `:ts` key kept refreshing, so agents trusted a fresh ts that
# pointed at a stale snapshot. Two independent fixes are covered:
#
#   Bounding (dev-apprenticeship/triage/scripts/snapshot-compress.py):
#     1. An oversize envelope is bounded to <= the cap (per-issue description
#        truncation) with the item count preserved.
#     2. Truncated descriptions carry the explicit `…[+<N> chars]` marker and
#        the envelope gains a `bounded.desc_cap` key.
#     3. Bounding is deterministic (byte-identical across runs).
#     4. A low SNAPSHOT_MEMO_MAX_BYTES forces a harder (smaller) desc cap and
#        still fits.
#     5. Under-cap input is byte-identical regardless of the cap and carries no
#        `bounded` key (pins the #1112 byte-stability DoD + --self-test).
#
#   Coupling (dev-apprenticeship/triage/scripts/start-colony.sh publish_snapshot):
#     6. An oversize snapshot write leaves `:ts` UNwritten and logs a loud
#        `[snapshot] ERROR` to stderr (AC1/AC2/AC4).
#     7. An under-cap snapshot write refreshes both the snapshot and `:ts` (AC1).
#
# The coupling cases run against a self-contained fixture tree (real
# start-colony.sh + parse-toml.sh, stub forge-api.sh + stub `agentis` on PATH),
# so they pass on CI runners with no agentis binary. Fixtures are dash-safe
# (stub scripts are #!/bin/sh, no printf '\xHH', no bashisms).
#
# Usage: ./tools/test-snapshot-publish-bound.sh
# Exit 0 on full pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPRESS="$REPO_ROOT/dev-apprenticeship/triage/scripts/snapshot-compress.py"
START_COLONY="$REPO_ROOT/dev-apprenticeship/triage/scripts/start-colony.sh"
PARSE_TOML="$REPO_ROOT/tools/parse-toml.sh"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# --- Fixtures: raw GitLab issue arrays via python3 (dash-safe, no printf esc) ---
# gen_issues <n> <desc_len> -> raw JSON array on stdout, each issue carrying a
# DISTINCT multi-char description so structural interning cannot collapse them
# to one chunk (that would defeat the size bound the test is exercising).
gen_issues() {
    N="$1" DLEN="$2" python3 -c '
import json, os
n = int(os.environ["N"]); dlen = int(os.environ["DLEN"])
out = []
for i in range(1, n + 1):
    body = ("issue-%d " % i) * ((dlen // 8) + 1)
    out.append({
        "iid": i,
        "title": "problem number %d needs attention" % i,
        "labels": ["bug"],
        "state": "opened",
        "description": body[:dlen],
        "author": {"username": "reporter%d" % i},
    })
print(json.dumps(out))
'
}

# --- Test 1: oversize envelope bounded to <= cap, count preserved ---
RAW1="$(gen_issues 14 2500)"
OUT1="$(printf '%s' "$RAW1" | SNAPSHOT_MEMO_MAX_BYTES=10240 python3 "$COMPRESS" issues 2>/dev/null)"
BYTES1="$(printf '%s' "$OUT1" | wc -c | tr -d ' ')"
COUNT1="$(OUT="$OUT1" python3 -c 'import os,json;print(json.loads(os.environ["OUT"])["count"])')"
if [ "$BYTES1" -le 10240 ] && [ "$COUNT1" = "14" ]; then
    pass "1: oversize envelope bounded to <= 10240 ($BYTES1 bytes), count=14 preserved"
else
    fail "1: oversize envelope bound" "bytes=$BYTES1 (<=10240?), count=$COUNT1 (=14?)"
fi

# --- Test 2: truncated descriptions carry explicit marker + bounded.desc_cap ---
HAS_MARKER="$(case "$OUT1" in *"chars]"*) echo yes ;; *) echo no ;; esac)"
DESC_CAP="$(OUT="$OUT1" python3 -c 'import os,json;e=json.loads(os.environ["OUT"]);print(e.get("bounded",{}).get("desc_cap","MISSING"))')"
if [ "$HAS_MARKER" = "yes" ] && [ "$DESC_CAP" != "MISSING" ]; then
    pass "2: truncation marker present, bounded.desc_cap=$DESC_CAP emitted"
else
    fail "2: truncation marker + bounded key" "marker=$HAS_MARKER, desc_cap=$DESC_CAP"
fi

# --- Test 3: bounding is deterministic (byte-identical across runs) ---
OUT1B="$(printf '%s' "$RAW1" | SNAPSHOT_MEMO_MAX_BYTES=10240 python3 "$COMPRESS" issues 2>/dev/null)"
if [ "$OUT1" = "$OUT1B" ]; then
    pass "3: bounding deterministic (two runs byte-identical)"
else
    fail "3: bounding determinism" "two runs differ"
fi

# --- Test 4: low cap forces a harder (smaller) desc cap and still fits ---
RAW4="$(gen_issues 3 2500)"
OUT4="$(printf '%s' "$RAW4" | SNAPSHOT_MEMO_MAX_BYTES=600 python3 "$COMPRESS" issues 2>/dev/null)"
BYTES4="$(printf '%s' "$OUT4" | wc -c | tr -d ' ')"
DESC_CAP4="$(OUT="$OUT4" python3 -c 'import os,json;print(json.loads(os.environ["OUT"]).get("bounded",{}).get("desc_cap","MISSING"))')"
if [ "$BYTES4" -le 600 ] && [ "$DESC_CAP4" != "MISSING" ] && [ "$DESC_CAP4" -lt 512 ]; then
    pass "4: cap=600 fits ($BYTES4 bytes) at a smaller desc_cap=$DESC_CAP4"
else
    fail "4: low cap harder truncation" "bytes=$BYTES4 (<=600?), desc_cap=$DESC_CAP4 (<512?)"
fi

# --- Test 5: under-cap input is byte-identical regardless of cap, no bounded key ---
RAW5="$(gen_issues 2 40)"
OUT5_DEFAULT="$(printf '%s' "$RAW5" | python3 "$COMPRESS" issues 2>/dev/null)"
# A huge cap can NEVER bound, so its output is exactly compress()'s form. The
# default-cap run must match it byte-for-byte for a small input (no bounding
# artifact) — this pins byte-stability (#1112) + the --self-test invariant.
OUT5_HUGE="$(printf '%s' "$RAW5" | SNAPSHOT_MEMO_MAX_BYTES=1000000 python3 "$COMPRESS" issues 2>/dev/null)"
HAS_BOUNDED="$(case "$OUT5_DEFAULT" in *'"bounded"'*) echo yes ;; *) echo no ;; esac)"
if [ "$OUT5_DEFAULT" = "$OUT5_HUGE" ] && [ "$HAS_BOUNDED" = "no" ]; then
    pass "5: under-cap output byte-identical to unbounded compress(), no bounded key"
else
    fail "5: under-cap byte-stability" "identical=$([ "$OUT5_DEFAULT" = "$OUT5_HUGE" ] && echo yes || echo no), bounded=$HAS_BOUNDED"
fi

# --- Coupling fixture: build a self-contained 3-level fed tree -----------------
# start-colony.sh resolves REPO_ROOT = <scripts>/../../.. and the fed root as
# REPO_ROOT/dev-apprenticeship, sources REPO_ROOT/tools/parse-toml.sh, and runs
# <COLONY_DIR>/scripts/forge-api.sh. Mirror that layout exactly.
FEDTREE="$TMPDIR_TEST/fedtree"
COLONY_SCRIPTS="$FEDTREE/dev-apprenticeship/triage/scripts"
COLONY_CONFIG="$FEDTREE/dev-apprenticeship/triage/config"
STUB_BIN="$FEDTREE/bin"
MEMO_DIR="$FEDTREE/memo-writes"
mkdir -p "$FEDTREE/tools" "$COLONY_SCRIPTS" "$COLONY_CONFIG" "$STUB_BIN" "$MEMO_DIR"

cp "$PARSE_TOML" "$FEDTREE/tools/parse-toml.sh"
# parse-toml.sh delegates all TOML/secret parsing to this sibling helper.
cp "$REPO_ROOT/tools/parse-toml-secret.py" "$FEDTREE/tools/parse-toml-secret.py"
cp "$START_COLONY" "$COLONY_SCRIPTS/start-colony.sh"
chmod +x "$COLONY_SCRIPTS/start-colony.sh"

cat > "$COLONY_CONFIG/colony.toml" <<'TOML'
[forge]
type = "gitlab"

[forge.gitlab]
url = "https://gitlab.example.invalid"
token = "fixture-token"
project = "group/project"
me = "fixture-bot"
TOML

# Stub forge-api.sh: emit the pre-canned envelope from $STUB_SNAP_FILE for the
# `snapshot issues` verb. Dash-safe (#!/bin/sh, no bashisms).
cat > "$COLONY_SCRIPTS/forge-api.sh" <<'SH'
#!/bin/sh
if [ "$1" = "snapshot" ]; then
    cat "$STUB_SNAP_FILE"
    exit 0
fi
exit 0
SH
chmod +x "$COLONY_SCRIPTS/forge-api.sh"

# Stub `agentis`: model the runtime memo value cap. `memo set` on the snapshot
# key fails (exit 1) when the value exceeds $STUB_MEMO_CAP; every accepted write
# records a marker file named after the sanitized key so the test can assert
# exactly which keys were written. Dash-safe.
cat > "$STUB_BIN/agentis" <<'SH'
#!/bin/sh
if [ "$1" = "memo" ] && [ "$2" = "set" ]; then
    key="$3"
    val="$4"
    len="$(printf '%s' "$val" | wc -c | tr -d ' ')"
    cap="${STUB_MEMO_CAP:-10240}"
    if [ "$key" = "gitlab:snapshot:issues" ] && [ "$len" -gt "$cap" ]; then
        exit 1
    fi
    safe="$(printf '%s' "$key" | tr ':' '_')"
    : > "$STUB_MEMO_DIR/$safe"
    exit 0
fi
exit 0
SH
chmod +x "$STUB_BIN/agentis"

# Canned envelopes (valid dicts with count>0 so the non-empty guard passes).
BIG_SNAP="$FEDTREE/big.json"
SMALL_SNAP="$FEDTREE/small.json"
python3 -c '
import json
big = {"v":1,"collection":"issues","count":1,"fields":["title"],
       "chunks":[{"title":"x"*500,"labels":["bug"],"state":"opened"}],
       "items":[{"k":1,"c":0}]}
small = {"v":1,"collection":"issues","count":1,"fields":["title"],
         "chunks":[{"title":"t","labels":[],"state":"opened"}],
         "items":[{"k":1,"c":0}]}
open("'"$BIG_SNAP"'","w").write(json.dumps(big,sort_keys=True,separators=(",",":")))
open("'"$SMALL_SNAP"'","w").write(json.dumps(small,sort_keys=True,separators=(",",":")))
'

run_refresh() {
    # run_refresh <snap_file> <stderr_out>
    PATH="$STUB_BIN:$PATH" \
    STUB_SNAP_FILE="$1" \
    STUB_MEMO_DIR="$MEMO_DIR" \
    STUB_MEMO_CAP=200 \
        bash "$COLONY_SCRIPTS/start-colony.sh" --snapshot-refresh \
        >/dev/null 2>"$2" || true
}

# --- Test 6: oversize snapshot -> ts UNwritten + loud ERROR (AC4/AC2/AC1) ---
rm -f "$MEMO_DIR"/*
ERR6="$TMPDIR_TEST/err6.log"
run_refresh "$BIG_SNAP" "$ERR6"
TS_WRITTEN=no; [ -f "$MEMO_DIR/gitlab_snapshot_issues_ts" ] && TS_WRITTEN=yes
ERR_LOGGED="$(grep -q '\[snapshot\] ERROR' "$ERR6" && echo yes || echo no)"
if [ "$TS_WRITTEN" = "no" ] && [ "$ERR_LOGGED" = "yes" ]; then
    pass "6: oversize snapshot leaves :ts unwritten + logs [snapshot] ERROR to stderr"
else
    fail "6: coupling on oversize" "ts_written=$TS_WRITTEN (want no), err_logged=$ERR_LOGGED (want yes)"
fi

# --- Test 7: under-cap snapshot -> both snapshot and :ts written (AC1) ---
rm -f "$MEMO_DIR"/*
ERR7="$TMPDIR_TEST/err7.log"
run_refresh "$SMALL_SNAP" "$ERR7"
SNAP_WRITTEN=no; [ -f "$MEMO_DIR/gitlab_snapshot_issues" ] && SNAP_WRITTEN=yes
TS_WRITTEN7=no; [ -f "$MEMO_DIR/gitlab_snapshot_issues_ts" ] && TS_WRITTEN7=yes
if [ "$SNAP_WRITTEN" = "yes" ] && [ "$TS_WRITTEN7" = "yes" ]; then
    pass "7: under-cap snapshot refreshes both snapshot and :ts"
else
    fail "7: coupling on under-cap" "snap_written=$SNAP_WRITTEN, ts_written=$TS_WRITTEN7 (both want yes)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
