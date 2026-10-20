#!/usr/bin/env bash
# demo-agentarena-intake.sh — OFFLINE, DETERMINISTIC proof of the AgentArena shadow intake (epic #2317).
#
# M1 (#2325) covers the front door, agentarena-webhook.py:
#   1. source guards — no outbound HTTP / subprocess module in the receiver, constant-time token compare,
#      fullmatch task_id guard, no command-line token option, and the canary literal below equals the
#      receiver's SELFTEST_CANARY (drift fails);
#   2. `agentarena-webhook.py --self-test` exits 0 and never prints the canary;
#   3. startup refusals before binding: token unset -> 2, secret://env/<unset> -> 3, --bind 0.0.0.0 -> 2
#      (also with an unresolvable secret: the bind is checked first);
#   4. a live loopback receiver driven by curl: 401 without / with a wrong token, 413 on a declared
#      65537-byte body, 202 + a byte-exact canonical inbox file on the happy path, nothing written by the
#      rejects, exit 0 on SIGTERM, no canary in the receiver log.
# M1 (#2326) adds the fetch/unpack step, run-agentarena-intake.sh + lib/agentarena-intake.py:
#   5. (a) source guards on the helper — no outbound-HTTP module import, no zipfile extract()/extractall(),
#          its TASK_ID_RE literal equals the receiver's, INTAKE_CANARY below equals its SELFTEST_CANARY;
#      (b) `run-agentarena-intake.sh --self-test` exits 0 and never prints the canary;
#      (c) zip-slip through the shell entry: a fixture inbox file + an archive with ../../outside/pwned.txt and
#          /abs/pwned.txt members, run through the offline hatch with AGENTARENA_API_KEY unset -> exit 4,
#          manifest intake.status=refused reason=zip-slip, no pwned.txt anywhere, no repo/, and the temp root
#          differs only by agentarena/demo-slip-1/{manifest.json,.lock,details.json};
#      (d) the offline happy path -> unpacked, top dir stripped, dirs 0700 / files 0600.
# #2328 and #2329 extend this demo with the deadline and staging cases.
#
# No network beyond 127.0.0.1, no agentis, no LLM. The token reaches curl through a header FILE (-H @file),
# never argv; the receiver is tracked by its $! PID and reaped by the EXIT trap (never matched by name).
# Section 5 never calls curl: the offline hatch reads local fixture files.
#
# Usage:  dark-factory/demo-agentarena-intake.sh
# Requires: python3 (curl for section 4, SKIPped without it). Exit: 0 = all assertions held; non-zero = failure.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RECV="$HERE/agentarena-webhook.py"
INTAKE="$HERE/run-agentarena-intake.sh"
INTAKE_PY="$HERE/lib/agentarena-intake.py"
# Must equal SELFTEST_CANARY in agentarena-webhook.py (asserted below).
CANARY="agentarena-selftest-canary-5f1d8c27e04b"
# Must equal SELFTEST_CANARY in lib/agentarena-intake.py (asserted below).
INTAKE_CANARY="agentarena-intake-selftest-canary-9b3e61d07a2c"

FAILS=0
note() { echo "demo-agentarena-intake.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
is()   { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got $1, want $2)"; fi; } # <got> <want> <label>

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -f "$RECV" ] || { note "agentarena-webhook.py not found: $RECV" >&2; exit 3; }
[ -f "$INTAKE_PY" ] || { note "lib/agentarena-intake.py not found: $INTAKE_PY" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-agentarena.XXXXXX")"
RPID=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
    if [ -n "$RPID" ]; then
        kill "$RPID" 2>/dev/null
        wait "$RPID" 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- 1. source guards ---------------------------------------------------------------------------------
note "1. source guards"
if grep -Eq '^[[:space:]]*(import|from)[[:space:]]+(urllib\.request|http\.client|requests|urllib3|httpx|aiohttp|subprocess)([[:space:]]|$|,)' "$RECV" \
   || grep -Eq '^[[:space:]]*from[[:space:]]+(urllib|http)[[:space:]]+import[[:space:]].*(request|client)' "$RECV" \
   || grep -Eq '^[[:space:]]*import[[:space:]].*(subprocess|urllib\.request|http\.client)' "$RECV"; then
    bad "receiver imports an outbound-HTTP or subprocess module"
else
    ok "no urllib.request/http.client/requests/urllib3/httpx/aiohttp/subprocess import"
fi
if grep -q 'hmac\.compare_digest' "$RECV"; then ok "token compared with hmac.compare_digest"; else bad "hmac.compare_digest missing"; fi
if grep -q 'TASK_ID_RE\.fullmatch' "$RECV"; then ok "task_id guarded with fullmatch"; else bad "TASK_ID_RE.fullmatch missing"; fi
if grep -q -- '--token' "$RECV"; then bad "receiver has a command-line token option"; else ok "no command-line token option"; fi
if grep -qF "SELFTEST_CANARY = \"$CANARY\"" "$RECV"; then
    ok "demo canary == receiver SELFTEST_CANARY"
else
    bad "demo canary drifted from the receiver's SELFTEST_CANARY"
fi

# --- 2. self-test -------------------------------------------------------------------------------------
note "2. --self-test"
st_out="$(python3 "$RECV" --self-test 2>&1)"; st_rc=$?
if [ "$st_rc" -eq 0 ]; then ok "--self-test exits 0"; else bad "--self-test exit $st_rc"; printf '%s\n' "$st_out"; fi
case "$st_out" in
    *"$CANARY"*) bad "--self-test output contains the canary" ;;
    *) ok "--self-test output has no canary" ;;
esac

# --- 3. startup refusals ------------------------------------------------------------------------------
note "3. startup refusals"
refuse() { # <want-rc> <label> <cmd...>
    want="$1"; label="$2"; shift 2
    "$@" >"$WORK/refuse.out" 2>"$WORK/refuse.err"; rc=$?
    if [ "$rc" -eq "$want" ]; then ok "$label -> exit $want"; else bad "$label -> exit $rc (want $want)"; fi
    if grep -qF "$CANARY" "$WORK/refuse.out" "$WORK/refuse.err"; then bad "$label: canary leaked to output"; fi
}
refuse 2 "WEBHOOK_AUTH_TOKEN unset" \
    env -u WEBHOOK_AUTH_TOKEN DARK_FACTORY_DIR="$WORK/df-refuse" python3 "$RECV" --port 0
refuse 3 "secret://env/<unset>" \
    env -u DEMO_AGENTARENA_UNSET WEBHOOK_AUTH_TOKEN=secret://env/DEMO_AGENTARENA_UNSET \
    DARK_FACTORY_DIR="$WORK/df-refuse" python3 "$RECV" --port 0
refuse 2 "--bind 0.0.0.0 without --allow-non-loopback" \
    env WEBHOOK_AUTH_TOKEN=secret://env/DEMO_AGENTARENA_TOKEN DEMO_AGENTARENA_TOKEN="$CANARY" \
    DARK_FACTORY_DIR="$WORK/df-refuse" python3 "$RECV" --bind 0.0.0.0 --port 0
refuse 2 "--bind 0.0.0.0 + unresolvable secret (bind refused before any secret lookup)" \
    env -u DEMO_AGENTARENA_UNSET WEBHOOK_AUTH_TOKEN=secret://env/DEMO_AGENTARENA_UNSET \
    DARK_FACTORY_DIR="$WORK/df-refuse" python3 "$RECV" --bind 0.0.0.0 --port 0
if [ -e "$WORK/df-refuse" ]; then bad "a refused startup created state"; else ok "refused startups wrote no state"; fi

# --- 4. live loopback ---------------------------------------------------------------------------------
note "4. live loopback receiver"
if ! command -v curl >/dev/null 2>&1; then
    echo "  [SKIP] curl not installed — live loopback section skipped"
else
    DF="$WORK/df"
    INBOX="$DF/agentarena/inbox"
    WEBHOOK_AUTH_TOKEN=secret://env/DEMO_AGENTARENA_TOKEN DEMO_AGENTARENA_TOKEN="$CANARY" DARK_FACTORY_DIR="$DF" \
        python3 "$RECV" --port 0 --port-file "$WORK/port" >"$WORK/recv.out" 2>"$WORK/recv.log" &
    RPID=$!
    i=0
    while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    PORT="$(cat "$WORK/port" 2>/dev/null)"
    if [ -z "$PORT" ]; then
        bad "receiver did not publish its port within 5 s"
        cat "$WORK/recv.log"
    else
        ok "receiver listening on 127.0.0.1:$PORT"
        URL="http://127.0.0.1:$PORT/webhook"
        printf 'Authorization: token %s\n' "$CANARY" >"$WORK/auth.hdr"
        printf 'Authorization: token %s\n' "wrong-$CANARY" >"$WORK/wrong.hdr"
        # Non-canonical on purpose (spacing, key order): the inbox file must be the canonical form.
        printf '%s' '{ "task_repository_url": "https://example.invalid/r.zip", "task_id": "demo-task-1", "post_findings_url": "https://example.invalid/f", "task_details_url": "https://example.invalid/d" }' >"$WORK/payload.json"
        printf '%s\n' '{"post_findings_url":"https://example.invalid/f","task_details_url":"https://example.invalid/d","task_id":"demo-task-1","task_repository_url":"https://example.invalid/r.zip"}' >"$WORK/expected.json"
        hit() { curl -s -o "$WORK/resp.body" -w '%{http_code}' --max-time 5 "$@"; }

        code="$(hit -X POST -H 'Content-Type: application/json' --data-binary @"$WORK/payload.json" "$URL")"
        is "$code" 401 "auth-reject: no Authorization -> 401"
        code="$(hit -X POST -H @"$WORK/wrong.hdr" --data-binary @"$WORK/payload.json" "$URL")"
        is "$code" 401 "auth-reject: wrong token -> 401"
        code="$(hit -X POST -H @"$WORK/auth.hdr" -H 'Content-Length: 65537' "$URL")"
        is "$code" 413 "oversize-reject: declared 65537 bytes (headers only) -> 413"
        if [ -z "$(find "$DF" -type f 2>/dev/null)" ]; then
            ok "rejects wrote nothing"
        else
            bad "a reject wrote a file"
        fi

        code="$(hit -X POST -H @"$WORK/auth.hdr" -H 'Content-Type: application/json' --data-binary @"$WORK/payload.json" "$URL")"
        if [ "$code" = 202 ] && [ "$(cat "$WORK/resp.body")" = '{"status":"accepted"}' ]; then
            ok "happy path: 202 {\"status\":\"accepted\"}"
        else
            bad "happy path -> $code $(cat "$WORK/resp.body")"
        fi
        if cmp -s "$INBOX/demo-task-1.json" "$WORK/expected.json"; then
            ok "inbox/demo-task-1.json is the byte-exact canonical line"
        else
            bad "inbox file missing or not canonical"
        fi
        if [ "$(find "$DF" -type f | wc -l)" -eq 1 ]; then ok "exactly one file under DARK_FACTORY_DIR"; else bad "unexpected files under DARK_FACTORY_DIR"; fi
    fi

    kill -TERM "$RPID" 2>/dev/null
    wait "$RPID"; rc=$?
    RPID=""
    is "$rc" 0 "SIGTERM -> receiver exit 0"
    if grep -qF "$CANARY" "$WORK/recv.log" "$WORK/recv.out"; then
        bad "receiver log contains the canary"
    else
        ok "receiver log has no canary"
    fi
    if grep -q 'outcome=accepted task_id=demo-task-1' "$WORK/recv.log"; then ok "accept logged"; else bad "accept not logged"; fi
fi

# --- 5. intake fetch/unpack (#2326) --------------------------------------------------------------------
note "5. intake fetch/unpack (#2326)"
# (a) source guards
if grep -Eq '^[[:space:]]*(import|from)[[:space:]]+(urllib\.request|http\.client|requests|urllib3|httpx|aiohttp)([[:space:]]|$|,)' "$INTAKE_PY" \
   || grep -Eq '^[[:space:]]*from[[:space:]]+(urllib|http)[[:space:]]+import[[:space:]].*(request|client)' "$INTAKE_PY" \
   || grep -Eq '^[[:space:]]*import[[:space:]].*(urllib\.request|http\.client|requests|httpx|aiohttp)' "$INTAKE_PY"; then
    bad "intake helper imports an outbound-HTTP module"
else
    ok "intake: no urllib.request/http.client/requests/urllib3/httpx/aiohttp import"
fi
if grep -Eq '\.extract(all)?\(' "$INTAKE_PY"; then
    bad "intake helper calls zipfile extract()/extractall()"
else
    ok "intake: no extract()/extractall() call (own validating extraction loop)"
fi
recv_re="$(grep -E '^TASK_ID_RE = ' "$RECV")"
intake_re="$(grep -E '^TASK_ID_RE = ' "$INTAKE_PY")"
if [ -n "$recv_re" ] && [ "$recv_re" = "$intake_re" ]; then
    ok "intake: TASK_ID_RE literal == the receiver's"
else
    bad "intake TASK_ID_RE drifted from the receiver's"
fi
if grep -qF "SELFTEST_CANARY = \"$INTAKE_CANARY\"" "$INTAKE_PY"; then
    ok "demo INTAKE_CANARY == intake SELFTEST_CANARY"
else
    bad "demo INTAKE_CANARY drifted from the intake's SELFTEST_CANARY"
fi
# (b) self-test through the shell entry
ist_out="$(bash "$INTAKE" --self-test 2>&1)"; ist_rc=$?
if [ "$ist_rc" -eq 0 ]; then ok "run-agentarena-intake.sh --self-test exits 0"; else bad "intake --self-test exit $ist_rc"; printf '%s\n' "$ist_out"; fi
case "$ist_out" in
    *"$INTAKE_CANARY"*) bad "intake --self-test output contains the canary" ;;
    *) ok "intake --self-test output has no canary" ;;
esac
# (c) zip-slip through the shell entry, offline hatch, key unset
IR="$WORK/intake-root"
IDF="$IR/df"
mkdir -p "$IDF/agentarena/inbox" "$IR/outside" "$WORK/fx"
chmod 700 "$IDF/agentarena" "$IDF/agentarena/inbox"
printf '%s\n' 'sentinel' >"$IR/outside/sentinel.txt"
for t in demo-slip-1 demo-ok-1; do
    printf '{"post_findings_url":"https://agentarena.nethermind.io/f","task_details_url":"https://agentarena.nethermind.io/d","task_id":"%s","task_repository_url":"https://agentarena.nethermind.io/r"}\n' "$t" \
        >"$IDF/agentarena/inbox/$t.json"
    printf '{"id":"%s","selectedFiles":["src/A.sol"]}\n' "$t" >"$WORK/fx/$t.details.json"
done
python3 -I - "$WORK/fx" <<'EOF'
import os, sys, zipfile
fx = sys.argv[1]
with zipfile.ZipFile(os.path.join(fx, "demo-slip-1.zip"), "w") as z:
    z.writestr("proj/src/A.sol", "contract A {}\n")
    z.writestr("../../outside/pwned.txt", "pwned\n")
    z.writestr("/abs/pwned.txt", "pwned\n")
with zipfile.ZipFile(os.path.join(fx, "demo-ok-1.zip"), "w") as z:
    z.writestr("proj/", "")
    z.writestr("proj/src/A.sol", "contract A {}\n")
    z.writestr("proj/README.md", "fixture\n")
EOF
snap() { (cd "$IR" && find . | LC_ALL=C sort); }
snap >"$WORK/snap.before"
env -u AGENTARENA_API_KEY DARK_FACTORY_DIR="$IDF" bash "$INTAKE" --task demo-slip-1 \
    --details-file "$WORK/fx/demo-slip-1.details.json" --zip-file "$WORK/fx/demo-slip-1.zip" \
    >"$WORK/slip.out" 2>"$WORK/slip.err"; rc=$?
snap >"$WORK/snap.after"
is "$rc" 4 "zip-slip: shell entry -> exit 4"
TD="$IDF/agentarena/demo-slip-1"
mstat="$(python3 -I -c 'import json,sys; i=json.load(open(sys.argv[1]))["intake"]; print(i["status"], i["reason"])' "$TD/manifest.json" 2>/dev/null)"
is "$mstat" "refused zip-slip" "zip-slip: manifest intake.status=refused reason=zip-slip"
if [ -z "$(find "$WORK" -name pwned.txt)" ] && [ ! -e /abs/pwned.txt ]; then ok "zip-slip: no pwned.txt anywhere"; else bad "zip-slip: a pwned.txt was written"; fi
if [ ! -e "$TD/repo" ]; then ok "zip-slip: no repo/"; else bad "zip-slip: repo/ exists"; fi
printf '%s\n' ./df/agentarena/demo-slip-1 ./df/agentarena/demo-slip-1/.lock \
    ./df/agentarena/demo-slip-1/details.json ./df/agentarena/demo-slip-1/manifest.json | LC_ALL=C sort >"$WORK/snap.want"
LC_ALL=C comm -13 "$WORK/snap.before" "$WORK/snap.after" >"$WORK/snap.added"
if cmp -s "$WORK/snap.added" "$WORK/snap.want" && [ -z "$(LC_ALL=C comm -23 "$WORK/snap.before" "$WORK/snap.after")" ]; then
    ok "zip-slip: the temp root differs only by agentarena/demo-slip-1/{manifest.json,.lock,details.json}"
else
    bad "zip-slip: unexpected change under the temp root"
    cat "$WORK/snap.added"
fi
if grep -q 'task_id=demo-slip-1 status=refused reason=zip-slip' "$WORK/slip.err"; then ok "zip-slip: refusal logged"; else bad "zip-slip: refusal not logged"; fi
if grep -q 'pwned\|outside\|nethermind' "$WORK/slip.err" "$TD/manifest.json"; then bad "zip-slip: a member name or URL reached the log/manifest"; else ok "zip-slip: no member name or URL in the log or manifest"; fi
# (d) offline happy path
env -u AGENTARENA_API_KEY DARK_FACTORY_DIR="$IDF" bash "$INTAKE" --task demo-ok-1 \
    --details-file "$WORK/fx/demo-ok-1.details.json" --zip-file "$WORK/fx/demo-ok-1.zip" >/dev/null 2>"$WORK/ok.err"; rc=$?
is "$rc" 0 "happy: shell entry -> exit 0"
OR="$IDF/agentarena/demo-ok-1/repo"
mstat="$(python3 -I -c 'import json,sys; i=json.load(open(sys.argv[1]))["intake"]; print(i["status"], i["top_dir_stripped"], i["files"])' "$IDF/agentarena/demo-ok-1/manifest.json" 2>/dev/null)"
is "$mstat" "unpacked True 2" "happy: manifest unpacked, top_dir_stripped, 2 files"
if [ "$(cat "$OR/src/A.sol" 2>/dev/null)" = "contract A {}" ] && [ -f "$OR/README.md" ]; then
    ok "happy: repo/src/A.sol + repo/README.md (top dir stripped)"
else
    bad "happy: unpacked tree missing or not stripped"
fi
modes="$(python3 -I -c 'import os,stat,sys; print(" ".join(oct(stat.S_IMODE(os.stat(p).st_mode)) for p in sys.argv[1:]))' "$OR" "$OR/src" "$OR/src/A.sol" "$OR/README.md")"
is "$modes" "0o700 0o700 0o600 0o600" "happy: dirs 0700, files 0600"

if [ "$FAILS" -eq 0 ]; then
    note "PASS"
    exit 0
fi
note "FAIL ($FAILS)"
exit 1
