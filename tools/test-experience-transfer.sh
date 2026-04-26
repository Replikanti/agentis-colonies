#!/bin/bash
# tools/test-experience-transfer.sh: unit tests for tools/experience-transfer.sh (#323).
#
# Builds two fake federations on /tmp, seeds donor experience, exports
# from one and imports into the other, then asserts that:
#
#   Test 1:  pack helper round-trips raw row count
#   Test 2:  --since drops rows older than the cutoff
#   Test 3:  --tags filters rows whose tags array intersects the set
#   Test 4:  --max-rows-per-agent caps each agent's payload
#   Test 5:  --scrub strips PII-suspect fields
#   Test 6:  every emitted row carries `donor=<name>` in tags
#   Test 7:  unpack remaps agent NAME -> target agent_id
#   Test 8:  re-import is idempotent (dedupe by sha256)
#   Test 9:  agent missing on target federation is skipped with WARN
#   Test 10: malformed pack (broken tarball) exits non-zero
#   Test 11: schema-version skew exits 3
#   Test 12: top-level shell script exits 1 on bad subcommand
#   Test 13: empty manifest agents list still produces a valid pack
#
# Usage: ./tools/test-experience-transfer.sh
# Exit code 0 if all tests pass, 1 otherwise.
#
# Live-federation safety: every fixture is built under $TMPDIR_TEST
# (via mktemp -d). The script never writes to $REPO_ROOT/.agentis/ or
# any path under dev-apprenticeship/.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHELL_TOOL="$SCRIPT_DIR/experience-transfer.sh"
PY_HELPER="$SCRIPT_DIR/experience-transfer-pack.py"

if [ ! -f "$SHELL_TOOL" ]; then
    echo "[FAIL] shell wrapper missing: $SHELL_TOOL" >&2
    exit 1
fi
if [ ! -f "$PY_HELPER" ]; then
    echo "[FAIL] python helper missing: $PY_HELPER" >&2
    exit 1
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: ${2:-}"; FAIL=$((FAIL + 1)); }

# build_fed <fed_root> <colony> <agent_name> <agent_id>
# Creates the minimum federation skeleton needed by the helper:
#   <fed>/<colony>/agents/<name>.ag        — discovery target
#   <fed>/.agentis/daemon/<colony>/<name>.json  — offline id resolver
build_fed() {
    fed_root="$1"
    colony="$2"
    name="$3"
    agent_id="$4"
    mkdir -p "$fed_root/$colony/agents"
    : > "$fed_root/$colony/agents/$name.ag"
    mkdir -p "$fed_root/.agentis/daemon/$colony"
    printf '{"agent_id":"%s","colony":"%s","agent_name":"%s"}\n' \
        "$agent_id" "$colony" "$name" \
        > "$fed_root/.agentis/daemon/$colony/$name.json"
    mkdir -p "$fed_root/.agentis/experience"
}

# write_rows <agent_id_jsonl_path> <count> <ts_ms> <tag_csv>
# Appends <count> JSON rows to the file, each with the given timestamp
# and the given comma-separated tag list. Other fields are constant
# enough that an importer can dedupe correctly across runs.
write_rows() {
    out="$1"
    count="$2"
    ts="$3"
    tag_csv="$4"
    # Build the tag JSON literal: ["a","b",...]
    tags_json="$(python3 -c 'import json,sys; print(json.dumps([t for t in sys.argv[1].split(",") if t]))' "$tag_csv")"
    i=0
    while [ "$i" -lt "$count" ]; do
        printf '{"action":"observe","agent":"main","cb":7,"ctx":"c","delta":0.05,"env":[],"id":%d,"in":"input %d","out":"o","outcome":"success","tags":%s,"ts":%d}\n' \
            "$i" "$i" "$tags_json" "$ts" \
            >> "$out"
        i=$((i + 1))
    done
}

# count_rows_in_pack <pack> <colony> <agent>
# Counts JSONL rows under experience/<colony>/<agent>.jsonl in the pack.
count_rows_in_pack() {
    pack="$1"
    colony="$2"
    agent="$3"
    python3 -c '
import json, sys, tarfile
pack, colony, agent = sys.argv[1], sys.argv[2], sys.argv[3]
target = "experience/%s/%s.jsonl" % (colony, agent)
n = 0
with tarfile.open(pack, "r:gz") as t:
    try:
        m = t.getmember(target)
    except KeyError:
        print(0)
        sys.exit(0)
    f = t.extractfile(m)
    for line in f.read().decode("utf-8").splitlines():
        if line.strip():
            n += 1
print(n)
' "$pack" "$colony" "$agent"
}

# ---- Build donor federation ----
DONOR="$TMPDIR_TEST/donor"
build_fed "$DONOR" "triage" "router"      "donor-aaa-1"
build_fed "$DONOR" "triage" "prioritizer" "donor-aaa-2"
build_fed "$DONOR" "release" "ship_decider" "donor-aaa-3"

# Use UTC dates so --since math is independent of the test host's TZ.
NOW_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
DAY_MS=86400000
OLD_TS=$((NOW_MS - 30 * DAY_MS))
NEW_TS=$((NOW_MS - 1 * DAY_MS))

write_rows "$DONOR/.agentis/experience/donor-aaa-1.jsonl" 100 "$NEW_TS" "observed,triage"
write_rows "$DONOR/.agentis/experience/donor-aaa-1.jsonl" 50  "$OLD_TS" "observed,triage,forge_user=alice"
write_rows "$DONOR/.agentis/experience/donor-aaa-2.jsonl" 30  "$NEW_TS" "acted,triage"
write_rows "$DONOR/.agentis/experience/donor-aaa-3.jsonl" 20  "$NEW_TS" "emitted,release"

# ---- Build recipient federation (overlap on router + ship_decider) ----
RECIP="$TMPDIR_TEST/recipient"
build_fed "$RECIP" "triage" "router"      "recip-bbb-1"
build_fed "$RECIP" "release" "ship_decider" "recip-bbb-2"
# Note: NO `prioritizer` on recipient — that exercises the missing-agent path.

# ---- Test 1: pack helper round-trips raw row count ----
PACK1="$TMPDIR_TEST/pack1.tar.gz"
"$SHELL_TOOL" export "$DONOR" --out "$PACK1" --donor-name unit-test >/dev/null
ROW_COUNT_R="$(count_rows_in_pack "$PACK1" triage router)"
ROW_COUNT_P="$(count_rows_in_pack "$PACK1" triage prioritizer)"
ROW_COUNT_S="$(count_rows_in_pack "$PACK1" release ship_decider)"
if [ "$ROW_COUNT_R" = "150" ] && [ "$ROW_COUNT_P" = "30" ] && [ "$ROW_COUNT_S" = "20" ]; then
    pass "pack: row counts router=150 prioritizer=30 ship_decider=20"
else
    fail "pack: row counts" "got router=$ROW_COUNT_R prioritizer=$ROW_COUNT_P ship_decider=$ROW_COUNT_S"
fi

# ---- Test 2: --since drops rows older than the cutoff ----
SINCE_DATE="$(python3 -c '
import datetime, sys
ts_ms = int(sys.argv[1]) - 7 * 86400000
print(datetime.datetime.fromtimestamp(ts_ms/1000, tz=datetime.timezone.utc).strftime("%Y-%m-%d"))
' "$NOW_MS")"
PACK2="$TMPDIR_TEST/pack2.tar.gz"
"$SHELL_TOOL" export "$DONOR" --out "$PACK2" --since "$SINCE_DATE" --donor-name unit-test >/dev/null
ROW_COUNT_R2="$(count_rows_in_pack "$PACK2" triage router)"
if [ "$ROW_COUNT_R2" = "100" ]; then
    pass "--since: drops 50 old rows on router (kept 100 new)"
else
    fail "--since router rows" "expected 100 got $ROW_COUNT_R2"
fi

# ---- Test 3: --tags filters by tag intersection ----
PACK3="$TMPDIR_TEST/pack3.tar.gz"
"$SHELL_TOOL" export "$DONOR" --out "$PACK3" --tags acted --donor-name unit-test >/dev/null
ROW_COUNT_P3="$(count_rows_in_pack "$PACK3" triage prioritizer)"
ROW_COUNT_R3="$(count_rows_in_pack "$PACK3" triage router)"
if [ "$ROW_COUNT_P3" = "30" ] && [ "$ROW_COUNT_R3" = "0" ]; then
    pass "--tags acted: keeps prioritizer (30) drops router (0)"
else
    fail "--tags acted" "expected prioritizer=30 router=0 got $ROW_COUNT_P3 / $ROW_COUNT_R3"
fi

# ---- Test 4: --max-rows-per-agent caps payload ----
PACK4="$TMPDIR_TEST/pack4.tar.gz"
"$SHELL_TOOL" export "$DONOR" --out "$PACK4" --max-rows-per-agent 10 --donor-name unit-test >/dev/null
ROW_COUNT_R4="$(count_rows_in_pack "$PACK4" triage router)"
ROW_COUNT_P4="$(count_rows_in_pack "$PACK4" triage prioritizer)"
if [ "$ROW_COUNT_R4" = "10" ] && [ "$ROW_COUNT_P4" = "10" ]; then
    pass "--max-rows-per-agent 10: each agent capped"
else
    fail "--max-rows-per-agent 10" "got router=$ROW_COUNT_R4 prioritizer=$ROW_COUNT_P4"
fi

# ---- Test 5: --scrub strips PII-suspect fields ----
PACK5="$TMPDIR_TEST/pack5.tar.gz"
"$SHELL_TOOL" export "$DONOR" --out "$PACK5" --scrub --donor-name unit-test >/dev/null
SCRUB_OUTPUT="$(python3 -c '
import json, sys, tarfile
pack = sys.argv[1]
with tarfile.open(pack, "r:gz") as t:
    f = t.extractfile(t.getmember("experience/triage/router.jsonl"))
    for line in f.read().decode("utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        if "in" in row:
            print("HAS_IN")
            sys.exit(0)
        for tag in row.get("tags", []):
            if tag.startswith("forge_user="):
                print("HAS_FORGE_USER_TAG")
                sys.exit(0)
print("CLEAN")
' "$PACK5")"
if [ "$SCRUB_OUTPUT" = "CLEAN" ]; then
    pass "--scrub: drops 'in' field and forge_user= tags"
else
    fail "--scrub" "expected CLEAN got $SCRUB_OUTPUT"
fi

# ---- Test 6: every emitted row carries donor=<name> in tags ----
DONOR_TAG_PRESENT="$(python3 -c '
import json, sys, tarfile
pack = sys.argv[1]
with tarfile.open(pack, "r:gz") as t:
    f = t.extractfile(t.getmember("experience/triage/router.jsonl"))
    for line in f.read().decode("utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        if "donor=unit-test" not in row.get("tags", []):
            print("MISSING")
            sys.exit(0)
print("PRESENT")
' "$PACK1")"
if [ "$DONOR_TAG_PRESENT" = "PRESENT" ]; then
    pass "donor=unit-test tag stamped on every row"
else
    fail "donor tag" "expected PRESENT got $DONOR_TAG_PRESENT"
fi

# ---- Test 7: unpack remaps agent NAME -> target agent_id ----
"$SHELL_TOOL" import "$RECIP" "$PACK1" >/dev/null 2>"$TMPDIR_TEST/import.err"
DEST_ROUTER="$RECIP/.agentis/experience/recip-bbb-1.jsonl"
DEST_SHIP="$RECIP/.agentis/experience/recip-bbb-2.jsonl"
if [ -f "$DEST_ROUTER" ] && [ -f "$DEST_SHIP" ]; then
    R_LINES="$(wc -l < "$DEST_ROUTER")"
    S_LINES="$(wc -l < "$DEST_SHIP")"
    R_LINES_TRIM="$(printf '%s' "$R_LINES" | tr -d ' ')"
    S_LINES_TRIM="$(printf '%s' "$S_LINES" | tr -d ' ')"
    if [ "$R_LINES_TRIM" = "150" ] && [ "$S_LINES_TRIM" = "20" ]; then
        pass "unpack: router rows landed in recip-bbb-1.jsonl (150) and ship_decider in recip-bbb-2.jsonl (20)"
    else
        fail "unpack remap" "expected router=150 ship=20 got $R_LINES_TRIM / $S_LINES_TRIM"
    fi
else
    fail "unpack remap" "destination files missing under recipient"
fi

# ---- Test 8: re-import is idempotent (dedupe by sha256) ----
"$SHELL_TOOL" import "$RECIP" "$PACK1" >/dev/null 2>>"$TMPDIR_TEST/import.err"
R_LINES_AFTER="$(wc -l < "$DEST_ROUTER" | tr -d ' ')"
S_LINES_AFTER="$(wc -l < "$DEST_SHIP" | tr -d ' ')"
if [ "$R_LINES_AFTER" = "150" ] && [ "$S_LINES_AFTER" = "20" ]; then
    pass "re-import is idempotent: line counts unchanged"
else
    fail "re-import idempotency" "expected 150/20 got $R_LINES_AFTER / $S_LINES_AFTER"
fi

# ---- Test 9: agent missing on target is skipped with WARN ----
if grep -q "WARN.*prioritizer" "$TMPDIR_TEST/import.err"; then
    pass "missing agent prioritizer reported on stderr"
else
    fail "missing agent warn" "expected WARN about prioritizer in stderr"
fi

# ---- Test 10: malformed pack exits non-zero ----
BAD_PACK="$TMPDIR_TEST/bad.tar.gz"
printf 'this is not a tarball\n' > "$BAD_PACK"
if "$SHELL_TOOL" import "$RECIP" "$BAD_PACK" >/dev/null 2>&1; then
    fail "malformed pack" "expected non-zero exit"
else
    pass "malformed pack exits non-zero"
fi

# ---- Test 11: schema-version skew exits 3 ----
SKEW_PACK="$TMPDIR_TEST/skew.tar.gz"
SKEW_DIR="$TMPDIR_TEST/skew-build"
mkdir -p "$SKEW_DIR"
printf '{"schema_version":99,"donor":"future","agents":[]}\n' > "$SKEW_DIR/manifest.json"
(cd "$SKEW_DIR" && tar -czf "$SKEW_PACK" manifest.json)
set +e
"$SHELL_TOOL" import "$RECIP" "$SKEW_PACK" >/dev/null 2>&1
SKEW_RC=$?
set -e
if [ "$SKEW_RC" = "3" ]; then
    pass "schema-version skew exits 3"
else
    fail "schema-version skew" "expected exit 3 got $SKEW_RC"
fi

# ---- Test 12: top-level shell script exits 1 on bad subcommand ----
set +e
"$SHELL_TOOL" frobnicate "$DONOR" >/dev/null 2>&1
BAD_SUB_RC=$?
set -e
if [ "$BAD_SUB_RC" = "1" ]; then
    pass "bad subcommand exits 1"
else
    fail "bad subcommand" "expected exit 1 got $BAD_SUB_RC"
fi

# ---- Test 13: empty federation produces valid pack with empty agents list ----
EMPTY_FED="$TMPDIR_TEST/empty"
mkdir -p "$EMPTY_FED/.agentis/experience"
EMPTY_PACK="$TMPDIR_TEST/empty.tar.gz"
if "$SHELL_TOOL" export "$EMPTY_FED" --out "$EMPTY_PACK" >/dev/null 2>&1; then
    AGENTS_LEN="$(python3 -c '
import json, tarfile, sys
with tarfile.open(sys.argv[1], "r:gz") as t:
    f = t.extractfile(t.getmember("manifest.json"))
    m = json.loads(f.read())
    print(len(m.get("agents", [])))
' "$EMPTY_PACK")"
    if [ "$AGENTS_LEN" = "0" ]; then
        pass "empty federation produces valid pack (agents=[])"
    else
        fail "empty federation pack" "expected agents=[] got len=$AGENTS_LEN"
    fi
else
    fail "empty federation pack" "export should succeed on empty federation"
fi

# ---- Summary ----
echo ""
echo "Results: PASS=$PASS, FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
