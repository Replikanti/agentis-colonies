#!/bin/sh
# demo-contest-finder.sh — proof of the live audit-contest finder (#2312): dark-factory/find-live-contests.sh
# running auditor/agents/contest-finder.ag.
#
# Part A (everywhere, CI included) source-asserts the structural contract:
#   one PLATFORMS list with the five names; the agent header documents endpoint, `auth: none`, shape and status
#   vocabulary per platform plus the Code4rena probe; no prompt() and no `exec sh` in the agent; every
#   getenv("CF_...") the agent reads is on the launcher's exec.env_passthrough line (an unlisted knob would be
#   silently inert, the #1426 class); the launcher never greps, cuts or edits the agent's output.
# Part B (only when `agentis` is on PATH, otherwise [SKIP]) runs the REAL launcher, which runs the REAL agent
#   through `agentis go`, on recorded responses (fixtures/contest-finder/, recorded 2026-11-12) and inline
#   synthetic ones, with the clock pinned by --now. Live platforms are served by a POSIX `sh` stub `curl` this
#   demo writes first on PATH: it maps the URL host plus the `page` query to fixture files, can answer a given
#   HTTP code or exit like a refused connection, and logs every call. No case touches the network. Every run that
#   finishes is checked for exactly one STATUS line per platform, in PLATFORMS order, then one RUN line, and every
#   line against the output grammar.
#
# Dash-safe: `set -u` only, no arrays, no `[[`, no `$'...'`, no hex printf escapes; multibyte fixture text is
# written literally (fixtures/contest-finder/sherlock-lookalikes.json carries the look-alike bytes).
#
# Usage:  dark-factory/demo-contest-finder.sh
# Exit: 0 = every assertion held (Part B SKIPs when agentis is absent); 1 = a regression.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${CONTEST_FINDER_LAUNCHER:-$HERE/find-live-contests.sh}"
AGENT="$HERE/auditor/agents/contest-finder.ag"
FIX="$HERE/fixtures/contest-finder"

FAILS=0
PASSES=0
note() { echo "demo-contest-finder.sh: $*"; }
ok()   { echo "  [PASS] $*"; PASSES=$((PASSES + 1)); }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }
# check <msg>: PASS when the command just before the call succeeded; check_rc <rc> <msg> for a saved status.
check_rc() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }
check() { rc=$?; check_rc "$rc" "$1"; }

TAB="$(printf '\t')"

[ -f "$AGENT" ] || { note "agent not found: $AGENT"; exit 1; }
[ -f "$LAUNCHER" ] || { note "launcher not found: $LAUNCHER"; exit 1; }

# =============================================================================================================
# Part A — source asserts
# =============================================================================================================
note "Part A: source asserts"

grep -q '^let PLATFORMS = \["IMMUNEFI", "CODEHAWKS", "SHERLOCK", "CANTINA", "CODE4RENA"\];$' "$AGENT"
check "A1 the agent has one PLATFORMS list with the five platforms"
[ "$(grep -c '^let PLATFORMS' "$AGENT")" = 1 ]
check "A1 PLATFORMS is declared exactly once"

HEADER="$(sed -n '1,/^let /p' "$AGENT")"
a2=0
for p in IMMUNEFI CODEHAWKS SHERLOCK CANTINA CODE4RENA; do
  printf '%s\n' "$HEADER" | grep -q "^// $p\$" || { a2=1; echo "    header has no block for $p"; }
done
for k in 'endpoint:' 'shape:' 'vocab:'; do
  [ "$(printf '%s\n' "$HEADER" | grep -c "^//   $k")" -ge 5 ] || { a2=1; echo "    header lacks '$k' for every platform"; }
done
[ "$(printf '%s\n' "$HEADER" | grep -c 'auth: none')" -ge 5 ] || { a2=1; echo "    header lacks 'auth: none' for every platform"; }
printf '%s\n' "$HEADER" | grep -q '^//   probe: ' || { a2=1; echo "    header lacks the Code4rena probe record"; }
check_rc $a2 "A2 the agent header documents endpoint, auth, shape and vocabulary per platform plus the Code4rena probe"

if grep -v '^[[:space:]]*//' "$AGENT" | grep -qE 'prompt\(|exec sh'; then a3=1; else a3=0; fi
check_rc $a3 "A3 no prompt() and no exec sh in the agent"

PASS_LINE="$(grep 'exec.env_passthrough = ' "$LAUNCHER" | head -n 1)"
a4=0
VARS="$(grep -o 'getenv("CF_[A-Z0-9_]*")' "$AGENT" | sed 's/getenv("\(.*\)")/\1/' | sort -u)"
while IFS= read -r v; do
  [ -n "$v" ] || continue
  printf '%s\n' "$PASS_LINE" | grep -qE "[ ,]$v(,|\"|\$)" || { a4=1; echo "    $v is read by the agent but not on the passthrough line"; }
done <<EOF
$VARS
EOF
if grep -v '^[[:space:]]*//' "$AGENT" | grep -q 'getenv([^"]'; then a4=1; echo "    a getenv() with a non-literal name cannot be checked"; fi
grep -q 'getenv("CF_' "$AGENT" || a4=1
check_rc $a4 "A4 every getenv(\"CF_...\") in the agent is on the launcher's exec.env_passthrough line"

if grep -v '^[[:space:]]*#' "$LAUNCHER" | grep -qE '(^|[^A-Za-z_-])(grep|sed|awk|cut|tr|head)([[:space:]]|$)'; then a5=1; else a5=0; fi
# shellcheck disable=SC2016 # a literal $OUT is the text searched for
grep -q '^cat "\$OUT"$' "$LAUNCHER" || a5=1
check_rc $a5 "A5 the launcher prints the agent's output verbatim and never greps, cuts or edits it"

# =============================================================================================================
# Part B — the real launcher + the real agent through `agentis go`
# =============================================================================================================
if ! command -v agentis >/dev/null 2>&1; then
  skip "Part B: agentis not on PATH, install the runtime to run the behavior cases"
  if [ "$FAILS" -eq 0 ]; then note "PASS ($PASSES checks, Part B skipped)"; exit 0; fi
  note "FAIL ($FAILS failed)"; exit 1
fi
note "Part B: behavior through agentis go"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-contest-finder.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export DARK_FACTORY_DIR="$WORK/dfdir"
STUB="$WORK/stub"
mkdir -p "$WORK/bin" "$STUB" "$WORK/data"

# The stub curl. Its data dir is baked in, because exec children see only the allowlisted environment.
cat > "$WORK/bin/curl" <<EOF
#!/bin/sh
STUB='$STUB'
EOF
cat >> "$WORK/bin/curl" <<'EOF'
out="" ; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -A|-H|-w|--max-time) shift 2 ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *immunefi.com*) plat=immunefi ;;
  *codehawks*) plat=codehawks ;;
  *sherlock*) plat=sherlock ;;
  *cantina*) plat=cantina ;;
  *code4rena*) plat=code4rena ;;
  *) plat=unknown ;;
esac
page=1
case "$url" in *\?*)
  q="${url#*\?}"
  set -f
  oldifs="$IFS"; IFS='&'
  for kv in $q; do case "$kv" in page=*) page="${kv#page=}" ;; esac; done
  IFS="$oldifs"
  set +f ;;
esac
echo "$plat page=$page url=$url" >> "$STUB/calls.log"
if [ -f "$STUB/$plat-$page.exit" ]; then
  echo "curl: ($(cat "$STUB/$plat-$page.exit")) stub failure" >&2
  exit "$(cat "$STUB/$plat-$page.exit")"
fi
code=200
[ -f "$STUB/$plat-$page.code" ] && code="$(cat "$STUB/$plat-$page.code")"
if [ -f "$STUB/$plat-$page.json" ]; then
  [ -n "$out" ] && cp "$STUB/$plat-$page.json" "$out"
else
  code=404
fi
printf '%s' "$code"
EOF
chmod +x "$WORK/bin/curl"
PATH="$WORK/bin:$PATH"
export PATH

N0=1794441600        # 2026-11-12T00:00:00Z
REC_NOW=1794873600   # 2026-11-17T00:00:00Z: nothing in the recordings is live
F1=1796083200        # 2026-12-01T00:00:00Z
F2=1797292800        # 2026-12-15T00:00:00Z
P1=1790812800        # 2026-10-01T00:00:00Z

stub_reset() { rm -f "$STUB"/*; }
stub_calls() { grep -c "^$1 " "$STUB/calls.log" 2>/dev/null || echo 0; }

# grammar <out> <n_status>: STATUS lines in PLATFORMS order (extra names last), one RUN line last, every line
# well-formed.
grammar() {
  g=0
  n="$(grep -c '^STATUS' "$1")"
  [ "$n" = "$2" ] || { g=1; echo "    expected $2 STATUS lines, got $n"; }
  [ "$(grep -c '^RUN' "$1")" = 1 ] || { g=1; echo "    expected one RUN line"; }
  tail -n 1 "$1" | grep -q '^RUN' || { g=1; echo "    the last line is not RUN"; }
  order="$(grep '^STATUS' "$1" | cut -f2 | head -n 5 | tr '\n' ' ')"
  [ "$order" = "IMMUNEFI CODEHAWKS SHERLOCK CANTINA CODE4RENA " ] || { g=1; echo "    STATUS order: $order"; }
  ROW_RE="^[A-Z0-9]+${TAB}[^${TAB}]*${TAB}ends=([0-9]{4}-[0-9]{2}-[0-9]{2}|-)${TAB}prize=[^${TAB}]+${TAB}kyc=(yes|no|-)${TAB}status=[^${TAB}]+${TAB}url=[^${TAB}]+\$"
  ST_RE="^STATUS${TAB}[A-Z0-9]+${TAB}(ok|fetch-failed|parse-failed|unsupported)${TAB}live=[0-9]+${TAB}items=[0-9]+(${TAB}pages=[0-9]+)?(${TAB}statuses=[^${TAB}]+)?(${TAB}reason=[^${TAB}]+)?\$"
  RUN_RE="^RUN${TAB}[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z${TAB}platforms=[0-9]+${TAB}ok=[0-9]+${TAB}cb_spent=[0-9]+\$"
  badl="$(grep -vE "$ROW_RE" "$1" | grep -vE "$ST_RE" | grep -vE "$RUN_RE")"
  [ -z "$badl" ] || { g=1; echo "    malformed line(s):"; printf '%s\n' "$badl" | sed 's/^/      /'; }
  return $g
}

# run_case <name> "<platforms the caller feeds itself>" <args...>: the other platforms get the recordings.
# Sets OUT and RC; a finished run is grammar-checked.
run_case() {
  name="$1"; own="$2"; shift 2
  for p in IMMUNEFI CODEHAWKS SHERLOCK CANTINA CODE4RENA; do
    case " $own " in *" $p "*) continue ;; esac
    case "$p" in
      IMMUNEFI)  set -- "$@" --immunefi-from "$FIX/immunefi.json" ;;
      CODEHAWKS) set -- "$@" --codehawks-from "$FIX/codehawks-trpc.json" ;;
      SHERLOCK)  set -- "$@" --sherlock-from "$FIX/sherlock-p1.json" --sherlock-from "$FIX/sherlock-p2.json" ;;
      CANTINA)   set -- "$@" --cantina-from "$FIX/cantina.json" ;;
      CODE4RENA) set -- "$@" --code4rena-from "$FIX/code4rena-p1.json" ;;
    esac
  done
  OUT="$WORK/$name.out"
  "$LAUNCHER" "$@" > "$OUT" 2> "$WORK/$name.err"
  RC=$?
  if [ "$RC" = 0 ]; then
    grammar "$OUT" "${NSTATUS:-5}"
    check "$name: five STATUS lines in PLATFORMS order, one RUN line last, every line well-formed"
  fi
}

line() { grep -qxF "$2" "$1"; }
row_count() { grep -c "^$2${TAB}" "$1"; }
status_line() { grep "^STATUS${TAB}$2${TAB}" "$1"; }
expect_status() {
  got="$(status_line "$1" "$2")"
  if [ "$got" = "$3" ]; then ok "$4"; else bad "$4"; echo "    want: $3"; echo "    got:  $got"; fi
}
S() { printf 'STATUS\t%s\t%s\tlive=%s\titems=%s' "$1" "$2" "$3" "$4"; shift 4; for x in "$@"; do printf '\t%s' "$x"; done; }

# sh_item <id> <status> <starts_at|null> <ends_at|null> [title] [private]
sh_item() {
  printf '{"id":%s,"title":"%s","status":"%s","private":%s,"starts_at":%s,"ends_at":%s,"prize_pool":1000,"token":"USDC"}' \
    "$1" "${5:-Contest $1}" "$2" "${6:-false}" "$3" "$4"
}
# sh_page <file> <has_next> <total> <items-json>
sh_page() { printf '{"page":1,"items":[%s],"total":%s,"has_next":%s,"pages":1}\n' "$4" "$3" "$2" > "$1"; }
# c4_page <file> <nextPage|null> <total> <audits-json>
c4_page() { printf '{"data":{"audits":[%s]},"pagination":{"total":%s,"nextPage":%s,"perPage":100}}\n' "$4" "$3" "$2" > "$1"; }
c4_item() {
  # shellcheck disable=SC2016 # "$10,000" is literal prize text
  printf '{"uid":"%s","slug":"%s","title":"%s","status":%s,"codeAccess":"%s","startTime":"%s","endTime":"%s","formattedAmount":"$10,000 in USDC"}' \
    "$1" "$1" "${6:-Audit $1}" "$2" "$3" "$4" "$5"
}
D="$WORK/data"

# ---------------------------------------------------------------------------------------------------------------
note "case_ok_rows"
cat > "$D/ch-live.json" <<'EOF'
[{"result":{"data":[{"id":"ch1","name":"Fresh Hawk","urlSlug":"2026-10-fresh-hawk","githubUrl":"https://github.com/example/fresh-hawk","startDate":"2026-10-15T12:00:00.000Z","endDate":"2026-10-29T12:00:00.000Z","finalised":false,"inviteOnly":false,"reward":20000,"currency":"usdc","requiresKyc":false}]}}]
EOF
sh_page "$D/sh-live.json" false 1 "$(sh_item 4242 RUNNING 1792000000 1792800000 'Fresh Vault')"
c4_page "$D/c4-live.json" null 1 "$(c4_item 2026-10-fresh '"Active"' public 2026-10-15T20:00:00.000Z 2026-10-30T20:00:00.000Z)"
run_case case_ok_rows "CODEHAWKS SHERLOCK CANTINA CODE4RENA" --now 1792454400 \
  --codehawks-from "$D/ch-live.json" --sherlock-from "$D/sh-live.json" --cantina-from "$FIX/cantina-live.json" \
  --code4rena-from "$D/c4-live.json"
for p in IMMUNEFI CODEHAWKS SHERLOCK CANTINA CODE4RENA; do
  [ "$(row_count "$OUT" "$p")" = 1 ]; check "case_ok_rows: one live $p row"
done
line "$OUT" "$(printf 'CANTINA\tRevert v4lend Competition\tends=2026-11-03\tprize=50000 USDC\tkyc=yes\tstatus=live\turl=https://cantina.xyz/competitions/e275368c-547d-4d91-a418-053ad31082a8')"
check "case_ok_rows: the CANTINA row survives end to end through the launcher"
line "$OUT" "$(printf 'IMMUNEFI\tAudit Competition | Plether\tends=2026-11-16\tprize=80000\tkyc=no\tstatus=boosted\turl=https://immunefi.com/audit-competition/plether/information/')"
check "case_ok_rows: the recorded live Immunefi competition is emitted with the host finder's end date"
line "$OUT" "$(printf 'CODEHAWKS\tFresh Hawk\tends=2026-10-29\tprize=20000usdc\tkyc=no\tstatus=open\turl=https://codehawks.cyfrin.io/c/2026-10-fresh-hawk')"
check "case_ok_rows: CodeHawks row fields"
line "$OUT" "$(printf 'SHERLOCK\tFresh Vault\tends=2026-10-24\tprize=1000 USDC\tkyc=-\tstatus=RUNNING\turl=https://audits.sherlock.xyz/contests/4242')"
check "case_ok_rows: Sherlock row fields"
[ "$(grep -c "${TAB}ok${TAB}" "$OUT")" = 5 ] && tail -n 1 "$OUT" | grep -q "${TAB}ok=5${TAB}"
check "case_ok_rows: five ok STATUS lines and ok=5 on the RUN line"

# ---------------------------------------------------------------------------------------------------------------
note "case_ok_empty"
run_case case_ok_empty "" --now "$REC_NOW"
[ "$RC" = 0 ] && [ "$(grep -Evc '^(STATUS|RUN)' "$OUT")" = 0 ]
check "case_ok_empty: the recordings at 2026-11-17 give no rows"
expect_status "$OUT" IMMUNEFI "$(S IMMUNEFI ok 0 4)" "case_ok_empty: IMMUNEFI ok live=0"
expect_status "$OUT" CODEHAWKS "$(S CODEHAWKS ok 0 45)" "case_ok_empty: CODEHAWKS ok live=0"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK ok 0 20 pages=2 statuses=FINISHED:20)" "case_ok_empty: SHERLOCK ok live=0 over two pages"
expect_status "$OUT" CANTINA "$(S CANTINA ok 0 3 statuses=complete:2,judging:1)" "case_ok_empty: CANTINA ok live=0"
expect_status "$OUT" CODE4RENA "$(S CODE4RENA ok 0 4 pages=1 statuses=Completed:2,Pre-Contest:1,-:1)" "case_ok_empty: CODE4RENA ok live=0, null counted as -"

# ---------------------------------------------------------------------------------------------------------------
note "case_fetch_transport / case_fetch_http"
stub_reset; echo 7 > "$STUB/cantina-1.exit"
run_case case_fetch_transport "CANTINA" --now "$REC_NOW"
expect_status "$OUT" CANTINA "$(S CANTINA fetch-failed 0 0 reason=transport-7)" "case_fetch_transport: a refused connection is fetch-failed reason=transport-7"
[ "$(grep -c "${TAB}ok${TAB}" "$OUT")" = 4 ]; check "case_fetch_transport: the other four platforms are unaffected"
stub_reset; echo 503 > "$STUB/cantina-1.code"; cp "$FIX/cantina.json" "$STUB/cantina-1.json"
run_case case_fetch_http "CANTINA" --now "$REC_NOW"
expect_status "$OUT" CANTINA "$(S CANTINA fetch-failed 0 0 reason=http-503)" "case_fetch_http: HTTP 503 is fetch-failed reason=http-503"
[ "$(grep -c "${TAB}ok${TAB}" "$OUT")" = 4 ]; check "case_fetch_http: the other four platforms are unaffected"

# ---------------------------------------------------------------------------------------------------------------
note "case_no_curl"
mkdir -p "$WORK/nocurl"
for t in bash sh env dirname mktemp rm mkdir cp cat date tail timeout agentis; do
  tp="$(command -v "$t" 2>/dev/null)" && ln -sf "$tp" "$WORK/nocurl/$t"
done
OUT="$WORK/case_no_curl.out"
PATH="$WORK/nocurl" "$LAUNCHER" --now "$REC_NOW" > "$OUT" 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(grep -c "^STATUS${TAB}[A-Z0-9]*${TAB}fetch-failed${TAB}live=0${TAB}items=0.*reason=transport-spawn\$" "$OUT")" = 5 ]
check "case_no_curl: without curl every platform reports fetch-failed, never silence"

# ---------------------------------------------------------------------------------------------------------------
note "case_agent_failed"
agent_failed_ok() { [ "$RC" = 3 ] && [ "$(wc -l < "$OUT" | tr -d ' ')" = 1 ] && grep -q "^STATUS${TAB}ALL${TAB}agent-failed${TAB}reason=$1${TAB}at=" "$OUT"; }
printf '#!/bin/sh\nexit 1\n' > "$WORK/agentis-fails"; chmod +x "$WORK/agentis-fails"
OUT="$WORK/af1.out"; AGENTIS="$WORK/agentis-fails" "$LAUNCHER" > "$OUT" 2>/dev/null; RC=$?
agent_failed_ok 'init-failed'; check "case_agent_failed: an agentis that exits 1 gives one STATUS ALL agent-failed line, exit 3"
OUT="$WORK/af2.out"; AGENTIS="$WORK/no-such-agentis" "$LAUNCHER" > "$OUT" 2>/dev/null; RC=$?
agent_failed_ok 'agentis-not-found'; check "case_agent_failed: a missing agentis gives the agent-failed line, exit 3"
sed 's/^cb [0-9]*;$/cb 300;/' "$AGENT" > "$WORK/cb300.ag"
OUT="$WORK/af3.out"; CONTEST_FINDER_AG="$WORK/cb300.ag" "$LAUNCHER" --now "$REC_NOW" --immunefi-from "$FIX/immunefi.json" \
  --codehawks-from "$FIX/codehawks-trpc.json" --sherlock-from "$FIX/sherlock-p1.json" --sherlock-from "$FIX/sherlock-p2.json" \
  --cantina-from "$FIX/cantina.json" --code4rena-from "$FIX/code4rena-p1.json" > "$OUT" 2>/dev/null; RC=$?
agent_failed_ok 'exit-1'; check "case_agent_failed: an agent that runs out of budget (cb 300) gives the agent-failed line, exit 3"
[ -s "$DARK_FACTORY_DIR/contest-finder-last-failure.log" ]; check "case_agent_failed: the failed run's log is kept"

# ---------------------------------------------------------------------------------------------------------------
note "case_sherlock_walk_has_next"
stub_reset
sh_page "$STUB/sherlock-1.json" true 3 "$(sh_item 11 FINISHED $P1 $P1),$(sh_item 12 FINISHED $P1 $P1)"
sh_page "$STUB/sherlock-2.json" false 3 "$(sh_item 13 FINISHED $P1 $P1)"
run_case case_sherlock_walk_has_next "SHERLOCK" --now "$N0"
[ "$(stub_calls sherlock)" = 2 ] && grep -q '^sherlock page=1 url=.*[?&]page=1&per_page=100$' "$STUB/calls.log" \
  && grep -q '^sherlock page=2 url=.*[?&]page=2&per_page=100$' "$STUB/calls.log"
check "case_sherlock_walk_has_next: exactly two Sherlock calls, page=1 and page=2, each with per_page=100"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK ok 0 3 pages=2 statuses=FINISHED:3)" "case_sherlock_walk_has_next: ok pages=2 items=3"

# ---------------------------------------------------------------------------------------------------------------
note "case_sherlock_walk_empty_page"
stub_reset
sh_page "$STUB/sherlock-1.json" true 2 "$(sh_item 21 FINISHED $P1 $P1),$(sh_item 22 FINISHED $P1 $P1)"
sh_page "$STUB/sherlock-2.json" false 2 ""
run_case case_sherlock_walk_empty_a "SHERLOCK" --now "$N0"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK ok 0 2 pages=1 statuses=FINISHED:2)" "case_sherlock_walk_empty_page: an empty page 2 ends the walk, total covered -> ok"
stub_reset
items=""; i=1
while [ "$i" -le 20 ]; do items="$items${items:+,}$(sh_item $((300 + i)) FINISHED $P1 $P1)"; i=$((i + 1)); done
sh_page "$STUB/sherlock-1.json" true 25 "$items"
sh_page "$STUB/sherlock-2.json" true 25 ""
run_case case_sherlock_walk_empty_b "SHERLOCK" --now "$N0"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK fetch-failed 0 20 pages=1 statuses=FINISHED:20 'reason=short-walk seen=20 total=25')" \
  "case_sherlock_walk_empty_page: 20 seen of a declared 25 -> fetch-failed short-walk"

# ---------------------------------------------------------------------------------------------------------------
note "case_sherlock_past_end_error_body"
stub_reset
sh_page "$STUB/sherlock-1.json" true 2 "$(sh_item 31 FINISHED $P1 $P1),$(sh_item 32 FINISHED $P1 $P1)"
cp "$FIX/sherlock-past-end.json" "$STUB/sherlock-2.json"
run_case case_past_end_a "SHERLOCK" --now "$N0"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK ok 0 2 pages=1 statuses=FINISHED:2)" "case_sherlock_past_end_error_body: the past-end error body ends the walk -> ok"
sh_page "$STUB/sherlock-1.json" true 3 "$(sh_item 31 FINISHED $P1 $P1),$(sh_item 32 FINISHED $P1 $P1)"
run_case case_past_end_b "SHERLOCK" --now "$N0"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK fetch-failed 0 2 pages=1 statuses=FINISHED:2 'reason=short-walk seen=2 total=3')" \
  "case_sherlock_past_end_error_body: then the integrity check decides (short of total -> fetch-failed)"

# ---------------------------------------------------------------------------------------------------------------
note "case_page_cap"
stub_reset; i=1
while [ "$i" -le 20 ]; do
  sh_page "$STUB/sherlock-$i.json" true 100 "$(sh_item $((400 + i)) FINISHED $P1 $P1)"
  c4_page "$STUB/code4rena-$i.json" $((i + 1)) 100 "$(c4_item "cap-$i" '"Completed"' public 2026-01-01T00:00:00.000Z 2026-01-02T00:00:00.000Z)"
  i=$((i + 1))
done
run_case case_page_cap_a "SHERLOCK CODE4RENA" --now "$N0"
[ "$(stub_calls sherlock)" = 20 ] && [ "$(stub_calls code4rena)" = 20 ]
check "case_page_cap: exactly 20 calls per walked platform at the cap"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK fetch-failed 0 20 pages=20 statuses=FINISHED:20 reason=page-cap)" "case_page_cap: Sherlock has_next at page 20 -> fetch-failed page-cap"
expect_status "$OUT" CODE4RENA "$(S CODE4RENA fetch-failed 0 20 pages=20 statuses=Completed:20 reason=page-cap)" "case_page_cap: Code4rena nextPage at page 20 -> fetch-failed page-cap"
stub_reset; i=1
while [ "$i" -le 19 ]; do
  hn=true; np=$((i + 1)); [ "$i" = 19 ] && { hn=false; np=null; }
  sh_page "$STUB/sherlock-$i.json" "$hn" 19 "$(sh_item $((400 + i)) FINISHED $P1 $P1)"
  c4_page "$STUB/code4rena-$i.json" "$np" 19 "$(c4_item "cap-$i" '"Completed"' public 2026-01-01T00:00:00.000Z 2026-01-02T00:00:00.000Z)"
  i=$((i + 1))
done
run_case case_page_cap_b "SHERLOCK CODE4RENA" --now "$N0"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK ok 0 19 pages=19 statuses=FINISHED:19)" "case_page_cap: Sherlock ending on page 19 -> ok pages=19"
expect_status "$OUT" CODE4RENA "$(S CODE4RENA ok 0 19 pages=19 statuses=Completed:19)" "case_page_cap: Code4rena ending on page 19 -> ok pages=19"

# ---------------------------------------------------------------------------------------------------------------
note "case_midwalk_failure / case_live_first_item / case_live_on_last_page"
stub_reset
sh_page "$STUB/sherlock-1.json" true 4 "$(sh_item 501 RUNNING $P1 $F1 'Mid One')"
sh_page "$STUB/sherlock-2.json" true 4 "$(sh_item 502 RUNNING $P1 $F1 'Mid Two')"
sh_page "$STUB/sherlock-3.json" true 4 "$(sh_item 503 RUNNING $P1 $F1 'Mid Three')"
echo 503 > "$STUB/sherlock-3.code"
sh_page "$STUB/sherlock-4.json" false 4 "$(sh_item 504 RUNNING $P1 $F1 'Mid Four')"
run_case case_midwalk_failure "SHERLOCK" --now "$N0"
[ "$(row_count "$OUT" SHERLOCK)" = 2 ] && grep -q "^SHERLOCK${TAB}Mid One${TAB}" "$OUT" && grep -q "^SHERLOCK${TAB}Mid Two${TAB}" "$OUT"
check "case_midwalk_failure: rows from pages 1-2 are still emitted"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK fetch-failed 2 2 pages=2 statuses=RUNNING:2 reason=http-503)" "case_midwalk_failure: a 503 on page 3 of 4 -> fetch-failed http-503"
stub_reset
sh_page "$STUB/sherlock-1.json" true 5 "$(sh_item 601 RUNNING $P1 $F1 'First Item'),$(sh_item 602 FINISHED $P1 $P1)"
sh_page "$STUB/sherlock-2.json" true 5 "$(sh_item 603 FINISHED $P1 $P1)"
sh_page "$STUB/sherlock-3.json" false 5 "$(sh_item 604 FINISHED $P1 $P1),$(sh_item 605 RUNNING $P1 $F1 'Last Item')"
run_case case_live_pages "SHERLOCK" --now "$N0"
grep -q "^SHERLOCK${TAB}First Item${TAB}" "$OUT"; check "case_live_first_item: a live first item of page 1 is emitted"
grep -q "^SHERLOCK${TAB}Last Item${TAB}" "$OUT"; check "case_live_on_last_page: a live contest only a full walk reaches is emitted"

# ---------------------------------------------------------------------------------------------------------------
note "case_dup_ids_across_pages"
stub_reset
sh_page "$STUB/sherlock-1.json" true 3 "$(sh_item 701 RUNNING $P1 $F1 'Dup Live'),$(sh_item 702 FINISHED $P1 $P1)"
sh_page "$STUB/sherlock-2.json" false 3 "$(sh_item 701 RUNNING $P1 $F1 'Dup Live'),$(sh_item 703 FINISHED $P1 $P1)"
run_case case_dup_ids "SHERLOCK" --now "$N0"
[ "$(row_count "$OUT" SHERLOCK)" = 1 ]; check "case_dup_ids_across_pages: an id on two pages gives one row"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK ok 1 3 pages=2 statuses=FINISHED:2,RUNNING:2)" "case_dup_ids_across_pages: counted once in items, seen >= total passes"

# ---------------------------------------------------------------------------------------------------------------
note "case_ties"
sh_page "$D/sh-ties.json" false 3 "$(sh_item 801 RUNNING $P1 $F1 'Zeta'),$(sh_item 802 RUNNING $P1 $F1 'Alpha'),$(sh_item 803 RUNNING $P1 $F2 'Same Title')"
cat > "$D/ca-ties.json" <<'EOF'
[{"id":"c-801","name":"Same Title","url":"https://cantina.xyz/competitions/c-801","timeframe":{"start":"2026-10-01T00:00:00Z","end":"2026-12-01T00:00:00Z"},"status":"live","kind":"public_contest","kycRequired":false}]
EOF
run_case case_ties "SHERLOCK CANTINA" --now "$N0" --sherlock-from "$D/sh-ties.json" --cantina-from "$D/ca-ties.json"
[ "$(grep "^SHERLOCK${TAB}" "$OUT" | cut -f2 | tr '\n' '|')" = "Zeta|Alpha|Same Title|" ]
check "case_ties: two live contests with the same end are both emitted, in source order"
[ "$(grep -c "^[A-Z0-9]*${TAB}Same Title${TAB}" "$OUT")" = 2 ]; check "case_ties: the same title on two platforms gives both rows"

# ---------------------------------------------------------------------------------------------------------------
note "case_bounds_end"
sh_page "$D/sh-end.json" false 2 "$(sh_item 901 RUNNING $P1 $N0 'End Equals Now'),$(sh_item 902 RUNNING $P1 $((N0 + 1)) 'End Plus One')"
cat > "$D/ca-end.json" <<'EOF'
[{"id":"c-901","name":"Cantina End Equals Now","timeframe":{"start":"2026-10-01T00:00:00Z","end":"2026-11-12T00:00:00Z"},"status":"live","kind":"public_contest"},
 {"id":"c-902","name":"Cantina End Plus One","timeframe":{"start":"2026-10-01T00:00:00Z","end":"2026-11-12T00:00:01Z"},"status":"live","kind":"public_contest"}]
EOF
c4_page "$D/c4-end.json" null 2 "$(c4_item c4-901 '"Active"' public 2026-10-01T00:00:00.000Z 2026-11-12T00:00:00.000Z 'C4 End Equals Now'),$(c4_item c4-902 '"Active"' public 2026-10-01T00:00:00.000Z 2026-11-12T00:00:01.000Z 'C4 End Plus One')"
run_case case_bounds_end "SHERLOCK CANTINA CODE4RENA" --now "$N0" --sherlock-from "$D/sh-end.json" --cantina-from "$D/ca-end.json" --code4rena-from "$D/c4-end.json"
[ "$(grep -c 'End Equals Now' "$OUT")" = 0 ]; check "case_bounds_end: end == now is not live (epoch, ISO, ISO with .000)"
[ "$(grep -c 'End Plus One' "$OUT")" = 3 ]; check "case_bounds_end: end == now + 1 s is live (epoch, ISO, ISO with .000)"

# ---------------------------------------------------------------------------------------------------------------
note "case_bounds_start"
sh_page "$D/sh-start.json" false 2 "$(sh_item 911 NEWSTATE $N0 $F1 'Start Equals Now'),$(sh_item 912 NEWSTATE $((N0 + 1)) $F1 'Start Plus One')"
cat > "$D/ch-start.json" <<'EOF'
[{"result":{"data":[
 {"id":"h1","name":"Hawk Start Equals Now","urlSlug":"h1","githubUrl":"https://github.com/example/h1","startDate":"2026-11-12T00:00:00.000Z","endDate":"2026-12-01T00:00:00.000Z","finalised":false,"inviteOnly":false},
 {"id":"h2","name":"Hawk Start Plus One","urlSlug":"h2","githubUrl":"https://github.com/example/h2","startDate":"2026-11-12T00:00:01.000Z","endDate":"2026-12-01T00:00:00.000Z","finalised":false,"inviteOnly":false}]}}]
EOF
run_case case_bounds_start "SHERLOCK CODEHAWKS" --now "$N0" --sherlock-from "$D/sh-start.json" --codehawks-from "$D/ch-start.json"
[ "$(grep -c 'Start Equals Now' "$OUT")" = 2 ]; check "case_bounds_start: start == now is live (unknown-status window rule, CodeHawks)"
[ "$(grep -c 'Start Plus One' "$OUT")" = 0 ]; check "case_bounds_start: start == now + 1 s is not live"
grep -q "^SHERLOCK${TAB}Start Equals Now${TAB}.*${TAB}status=NEWSTATE${TAB}" "$OUT"; check "case_bounds_start: an unknown status surfaces with its raw value"

# ---------------------------------------------------------------------------------------------------------------
note "case_reversed_window"
sh_page "$D/sh-rev.json" false 2 "$(sh_item 921 NEWSTATE $F2 $F1 'Reversed Unknown'),$(sh_item 922 RUNNING $F2 $F1 'Reversed Running')"
cat > "$D/ch-rev.json" <<'EOF'
[{"result":{"data":[{"id":"h3","name":"Hawk Reversed","urlSlug":"h3","githubUrl":"https://github.com/example/h3","startDate":"2026-12-15T00:00:00.000Z","endDate":"2026-12-01T00:00:00.000Z","finalised":false,"inviteOnly":false}]}}]
EOF
run_case case_reversed_window "SHERLOCK CODEHAWKS" --now "$N0" --sherlock-from "$D/sh-rev.json" --codehawks-from "$D/ch-rev.json"
! grep -q 'Reversed Unknown' "$OUT"; check "case_reversed_window: unknown status with start > end is not live"
grep -q "^SHERLOCK${TAB}Reversed Running${TAB}" "$OUT"; check "case_reversed_window: a LIVE status with end > now is live"
! grep -q 'Hawk Reversed' "$OUT"; check "case_reversed_window: CodeHawks with a future start is not live"

# ---------------------------------------------------------------------------------------------------------------
note "case_immunefi_text_date_boundary"
cat > "$D/imm-boundary.json" <<'EOF'
[{"project":"Boundary Comp","slug":"boundary-comp","endDate":"2026-11-16T10:00:00.000Z","kyc":false,"maxBounty":50000,
  "boostedIntroLive":"| Competition ends | Nov 16, 2026 |","boostedIntroStartingIn":"","boostedLeaderboard":[],
  "rewards":[{"assetType":"smart_contract"}]}]
EOF
run_case case_imm_boundary_a "IMMUNEFI" --now 1794787199 --immunefi-from "$D/imm-boundary.json"
line "$OUT" "$(printf 'IMMUNEFI\tBoundary Comp\tends=2026-11-16\tprize=50000\tkyc=no\tstatus=boosted\turl=https://immunefi.com/audit-competition/boundary-comp/information/')"
check "case_immunefi_text_date_boundary: at 2026-11-15T23:59:59Z the text date (Nov 16) is still live"
run_case case_imm_boundary_b "IMMUNEFI" --now 1794787200 --immunefi-from "$D/imm-boundary.json"
[ "$(row_count "$OUT" IMMUNEFI)" = 0 ]
check "case_immunefi_text_date_boundary: at 2026-11-16T00:00:00Z it is over (the text date counts from 00:00 UTC, endDate ignored)"

# ---------------------------------------------------------------------------------------------------------------
note "case_immunefi_text_precedence / case_immunefi_scope / case_immunefi_boosted_marker"
cat > "$D/imm-rules.json" <<'EOF'
[{"project":"Text Future EndDate Past","slug":"a-text","endDate":"2026-10-01T10:00:00.000Z","kyc":true,"maxBounty":1,
  "boostedIntroLive":"| Competition ends | Dec 1, 2026 |","boostedIntroStartingIn":"","boostedLeaderboard":[],"rewards":[{"assetType":"smart_contract"}]},
 {"project":"No Text EndDate Future","slug":"b-end","endDate":"2026-12-01T10:00:00.000Z","kyc":false,"maxBounty":2,
  "boostedIntroLive":"intro without a date","boostedIntroStartingIn":"","boostedLeaderboard":[],"rewards":[{"assetType":"smart_contract"}]},
 {"project":"No Text EndDate Past","slug":"b-past","endDate":"2026-10-01T10:00:00.000Z","kyc":false,"maxBounty":3,
  "boostedIntroLive":"intro without a date","boostedIntroStartingIn":"","boostedLeaderboard":[],"rewards":[{"assetType":"smart_contract"}]},
 {"project":"Four Letter Month","slug":"c-sept","endDate":"2026-12-02T10:00:00.000Z","kyc":false,"maxBounty":4,
  "boostedIntroLive":"| Competition ends | Sept 5, 2026 |","boostedIntroStartingIn":"","boostedLeaderboard":[],"rewards":[{"assetType":"smart_contract"}]},
 {"project":"StartingIn Text","slug":"d-start","endDate":"2026-10-01T10:00:00.000Z","kyc":false,"maxBounty":5,
  "boostedIntroLive":"live intro","boostedIntroStartingIn":"| Competition ends | Dec 3, 2026 |","boostedLeaderboard":[],"rewards":[{"assetType":"smart_contract"}]},
 {"project":"Web App Only","slug":"e-web","endDate":"2026-12-01T10:00:00.000Z","kyc":false,"maxBounty":6,
  "boostedIntroLive":"| Competition ends | Dec 1, 2026 |","boostedIntroStartingIn":"","boostedLeaderboard":[],"rewards":[{"assetType":"websites_and_applications"}]},
 {"project":"Leaderboard Only","slug":"f-lb","endDate":"2026-12-01T10:00:00.000Z","kyc":false,"maxBounty":7,
  "boostedIntroLive":"","boostedIntroStartingIn":"","boostedLeaderboard":[{"placeholder":"entry"}],"rewards":[{"assetType":"websites_and_applications"},{"assetType":"smart_contract"}]},
 {"project":"Not Boosted","slug":"g-plain","endDate":"2026-12-01T10:00:00.000Z","kyc":false,"maxBounty":8,
  "boostedIntroLive":"","boostedIntroStartingIn":"","boostedLeaderboard":[],"rewards":[{"assetType":"smart_contract"}]}]
EOF
run_case case_imm_rules "IMMUNEFI" --now "$N0" --immunefi-from "$D/imm-rules.json"
grep -q "^IMMUNEFI${TAB}Text Future EndDate Past${TAB}ends=2026-12-01${TAB}prize=1${TAB}kyc=yes${TAB}" "$OUT"
check "case_immunefi_text_precedence: a future text date beats a past endDate"
grep -q "^IMMUNEFI${TAB}No Text EndDate Future${TAB}ends=2026-12-01${TAB}" "$OUT" && ! grep -q 'No Text EndDate Past' "$OUT"
check "case_immunefi_text_precedence: without text, endDate decides"
grep -q "^IMMUNEFI${TAB}Four Letter Month${TAB}ends=2026-12-02${TAB}" "$OUT"
check "case_immunefi_text_precedence: 'Sept 5, 2026' does not match, endDate is the fallback"
grep -q "^IMMUNEFI${TAB}StartingIn Text${TAB}ends=2026-12-03${TAB}" "$OUT"
check "case_immunefi_text_precedence: boostedIntroStartingIn is read when boostedIntroLive has no date"
! grep -q 'Web App Only' "$OUT"; check "case_immunefi_scope: a boosted future competition with no smart_contract asset is not live"
grep -q "^IMMUNEFI${TAB}Leaderboard Only${TAB}" "$OUT"; check "case_immunefi_boosted_marker: a leaderboard-only boosted competition with a future end is live"
! grep -q 'Not Boosted' "$OUT"; check "case_immunefi_boosted_marker: a non-boosted program with a future endDate is not live"

# ---------------------------------------------------------------------------------------------------------------
note "case_codehawks_rules"
cat > "$D/ch-rules.json" <<'EOF'
[{"result":{"data":[
 {"id":"r1","name":"Hawk No Start","urlSlug":"r1","githubUrl":"https://github.com/example/r1","endDate":"2026-12-01T00:00:00.000Z","finalised":false,"inviteOnly":false,"reward":7.25,"currency":"eth","requiresKyc":true},
 {"id":"r2","name":"Hawk Finalised","urlSlug":"r2","githubUrl":"https://github.com/example/r2","startDate":"2026-11-01T00:00:00.000Z","endDate":"2026-12-01T00:00:00.000Z","finalised":true,"inviteOnly":false},
 {"id":"r3","name":"Hawk Invite Only","urlSlug":"r3","githubUrl":"https://github.com/example/r3","startDate":"2026-11-01T00:00:00.000Z","endDate":"2026-12-01T00:00:00.000Z","finalised":false,"inviteOnly":true},
 {"id":"r4","name":"Hawk No Repo","urlSlug":"r4","githubUrl":"","startDate":"2026-11-01T00:00:00.000Z","endDate":"2026-12-01T00:00:00.000Z","finalised":false,"inviteOnly":false}]}}]
EOF
run_case case_codehawks_rules "CODEHAWKS" --now "$N0" --codehawks-from "$D/ch-rules.json"
line "$OUT" "$(printf 'CODEHAWKS\tHawk No Start\tends=2026-12-01\tprize=7.25eth\tkyc=yes\tstatus=open\turl=https://codehawks.cyfrin.io/c/r1')"
check "case_codehawks_rules: no startDate with a future end is live"
[ "$(row_count "$OUT" CODEHAWKS)" = 1 ]; check "case_codehawks_rules: finalised, inviteOnly and an empty githubUrl are not live"

# ---------------------------------------------------------------------------------------------------------------
note "case_sherlock_vocab"
sh_page "$D/sh-vocab.json" false 5 "$(sh_item 1101 RUNNING $P1 $F1 'Running Private' true),$(sh_item 1102 RUNNING $P1 null 'Running Null End'),$(sh_item 1103 CREATED $P1 $F1 'Created Open'),$(sh_item 1104 LIVE $P1 $F1 'Unknown LIVE Open'),$(sh_item 1105 WEIRD $P1 $((N0 - 10)) 'Unknown Closed')"
run_case case_sherlock_vocab "SHERLOCK" --now "$N0" --sherlock-from "$D/sh-vocab.json"
! grep -q 'Running Private' "$OUT"; check "case_sherlock_vocab: RUNNING + private -> no row"
grep -q "^SHERLOCK${TAB}Running Null End${TAB}ends=-${TAB}" "$OUT"; check "case_sherlock_vocab: RUNNING + ends_at null -> row with ends=-"
! grep -q 'Created Open' "$OUT"; check "case_sherlock_vocab: CREATED with an open window -> no row"
grep -q "^SHERLOCK${TAB}Unknown LIVE Open${TAB}.*${TAB}status=LIVE${TAB}" "$OUT"; check "case_sherlock_vocab: unknown LIVE with an open window -> row status=LIVE"
! grep -q 'Unknown Closed' "$OUT"; check "case_sherlock_vocab: unknown status with a closed window -> no row"

# ---------------------------------------------------------------------------------------------------------------
note "case_c4_vocab"
c4_page "$D/c4-vocab.json" null 7 "$(c4_item v1 '"Active"' public 2026-11-01T00:00:00.000Z 2026-12-01T00:00:00.000Z 'C4 Active Open'),$(c4_item v2 '"LiveJudging"' public 2026-11-01T00:00:00.000Z 2026-12-01T00:00:00.000Z 'C4 LiveJudging Open'),$(c4_item v3 '"Active"' public 2026-10-01T00:00:00.000Z 2026-11-01T00:00:00.000Z 'C4 Active Past'),$(c4_item v4 '"Active"' certified 2026-11-01T00:00:00.000Z 2026-12-01T00:00:00.000Z 'C4 Certified'),$(c4_item v5 '"Active"' top_secret 2026-11-01T00:00:00.000Z 2026-12-01T00:00:00.000Z 'C4 Top Secret'),$(c4_item v6 null public 2026-10-01T00:00:00.000Z 2026-11-01T00:00:00.000Z 'C4 Null Closed'),$(c4_item v7 '"Pre-Contest"' public 2026-11-20T00:00:00.000Z 2026-12-01T00:00:00.000Z 'C4 PreContest Future')"
run_case case_c4_vocab "CODE4RENA" --now "$N0" --code4rena-from "$D/c4-vocab.json"
# shellcheck disable=SC2016 # "$10,000" is literal prize text
line "$OUT" "$(printf 'CODE4RENA\tC4 Active Open\tends=2026-12-01\tprize=$10,000 in USDC\tkyc=-\tstatus=Active\turl=https://code4rena.com/audits/v1')"
check "case_c4_vocab: Active, public, open -> row"
grep -q "^CODE4RENA${TAB}C4 LiveJudging Open${TAB}" "$OUT"; check "case_c4_vocab: LiveJudging, public, open -> row"
[ "$(row_count "$OUT" CODE4RENA)" = 2 ]; check "case_c4_vocab: Active past end, certified, top_secret, null closed and Pre-Contest future -> no row"
expect_status "$OUT" CODE4RENA "$(S CODE4RENA ok 2 7 pages=1 statuses=Active:4,LiveJudging:1,Pre-Contest:1,-:1)" "case_c4_vocab: null counted as -"

# ---------------------------------------------------------------------------------------------------------------
note "case_cantina_vocab"
cat > "$D/ca-vocab.json" <<'EOF'
[{"id":"k1","name":"Cantina Live Public","timeframe":{"start":"2026-11-01T00:00:00Z","end":"2026-12-01T00:00:00Z"},"status":"live","kind":"public_contest","kycRequired":false,"totalRewardPot":"10000","currencyCode":"USDC"},
 {"id":"k2","name":"Cantina Live Private","timeframe":{"start":"2026-11-01T00:00:00Z","end":"2026-12-01T00:00:00Z"},"status":"live","kind":"private_contest"},
 {"id":"k3","name":"Cantina Judging","timeframe":{"start":"2026-11-01T00:00:00Z","end":"2026-12-01T00:00:00Z"},"status":"judging","kind":"public_contest"},
 {"id":"k4","name":"Cantina Unknown Open","timeframe":{"start":"2026-11-01T00:00:00Z","end":"2026-12-01T00:00:00Z"},"status":"active_new","kind":"public_contest"}]
EOF
run_case case_cantina_vocab "CANTINA" --now "$N0" --cantina-from "$D/ca-vocab.json"
line "$OUT" "$(printf 'CANTINA\tCantina Live Public\tends=2026-12-01\tprize=10000 USDC\tkyc=no\tstatus=live\turl=https://cantina.xyz/competitions/k1')"
check "case_cantina_vocab: live + public_contest + open -> row"
! grep -q 'Cantina Live Private' "$OUT" && ! grep -q 'Cantina Judging' "$OUT"; check "case_cantina_vocab: private_contest and judging -> no row"
grep -q "^CANTINA${TAB}Cantina Unknown Open${TAB}.*${TAB}status=active_new${TAB}" "$OUT"; check "case_cantina_vocab: an unknown status with an open window -> row"

# ---------------------------------------------------------------------------------------------------------------
note "case_status_lookalikes"
run_case case_lookalikes "SHERLOCK" --now "$N0" --sherlock-from "$FIX/sherlock-lookalikes.json"
[ "$(row_count "$OUT" SHERLOCK)" = 1 ] && grep -q "^SHERLOCK${TAB}Look-alike 0${TAB}" "$OUT"
check "case_status_lookalikes: only the exact RUNNING value is LIVE; look-alikes fall to the window rule (no bounds -> no row)"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK ok 1 6 pages=1 'statuses=RUNNING:1,RUNNING :1,RUNNlNG:1,running:1,?other:2')" \
  "case_status_lookalikes: counted as their raw value or ?other (Cyrillic, zero-width space)"

# ---------------------------------------------------------------------------------------------------------------
note "case_status_regex_meta"
cat > "$D/ca-meta.json" <<'EOF'
[{"id":"m1","name":"Meta Star","status":"A.*","kind":"public_contest"},{"id":"m2","name":"Meta Paren","status":"(","kind":"public_contest"}]
EOF
run_case case_status_regex_meta "CANTINA" --now "$N0" --cantina-from "$D/ca-meta.json"
expect_status "$OUT" CANTINA "$(S CANTINA ok 0 2 'statuses=?other:2')" "case_status_regex_meta: regex metacharacters are data, counted as ?other, no rows"

# ---------------------------------------------------------------------------------------------------------------
note "case_status_drift"
items=""; i=1; want=""
while [ "$i" -le 25 ]; do
  sv="s$(printf '%02d' "$i")"
  items="$items${items:+,}{\"id\":\"d$i\",\"name\":\"Drift $i\",\"status\":\"$sv\",\"kind\":\"public_contest\"}"
  [ "$i" -le 20 ] && want="$want${want:+,}$sv:1"
  i=$((i + 1))
done
printf '[%s]\n' "$items" > "$D/ca-drift.json"
run_case case_status_drift "CANTINA" --now "$N0" --cantina-from "$D/ca-drift.json"
expect_status "$OUT" CANTINA "$(S CANTINA ok 0 25 "statuses=$want,+more:5")" "case_status_drift: a drifted vocabulary lists the top 20 values and counts the rest as +more"

# ---------------------------------------------------------------------------------------------------------------
note "case_title_escaping"
cat > "$D/ca-title.json" <<'EOF'
[{"id":"t1","name":"Tab\there\nnew \\ back é","timeframe":{"start":"2026-11-01T00:00:00Z","end":"2026-12-01T00:00:00Z"},"status":"live","kind":"public_contest"}]
EOF
run_case case_title_escaping "CANTINA" --now "$N0" --cantina-from "$D/ca-title.json"
[ "$(row_count "$OUT" CANTINA)" = 1 ] && [ "$(grep "^CANTINA${TAB}" "$OUT" | awk -F"$TAB" '{print NF}')" = 7 ] \
  && grep "^CANTINA${TAB}" "$OUT" | grep -qF 'é'
check "case_title_escaping: tab, newline and backslash keep the row on one line with 7 fields; non-ASCII is preserved"

# ---------------------------------------------------------------------------------------------------------------
note "case_missing_fields"
cat > "$D/ca-missing.json" <<'EOF'
[{"id":"mf1","name":"No Url No Prize","timeframe":{"start":"2026-11-01T00:00:00Z","end":"2026-12-01T00:00:00Z"},"status":"live","kind":"public_contest"}]
EOF
printf '{"page":1,"items":[{"id":1201,"title":"No Prize","status":"RUNNING","private":false,"starts_at":%s,"ends_at":%s}],"total":1,"has_next":false}\n' "$P1" "$F1" > "$D/sh-missing.json"
printf '{"data":{"audits":[{"uid":"mf3","slug":"2026-11-no-prize","title":"C4 No Prize","status":"Active","codeAccess":"public","startTime":"2026-11-01T00:00:00.000Z","endTime":"2026-12-01T00:00:00.000Z"}]},"pagination":{"total":1,"nextPage":null}}\n' > "$D/c4-missing.json"
run_case case_missing_fields "SHERLOCK CANTINA CODE4RENA" --now "$N0" --cantina-from "$D/ca-missing.json" --sherlock-from "$D/sh-missing.json" --code4rena-from "$D/c4-missing.json"
line "$OUT" "$(printf 'CANTINA\tNo Url No Prize\tends=2026-12-01\tprize=-\tkyc=-\tstatus=live\turl=https://cantina.xyz/competitions/mf1')"
check "case_missing_fields: Cantina without url/prize -> prize=- and a URL built from the id"
line "$OUT" "$(printf 'SHERLOCK\tNo Prize\tends=2026-12-01\tprize=-\tkyc=-\tstatus=RUNNING\turl=https://audits.sherlock.xyz/contests/1201')"
check "case_missing_fields: Sherlock without prize_pool -> prize=-"
grep -q "^CODE4RENA${TAB}C4 No Prize${TAB}ends=2026-12-01${TAB}prize=-${TAB}" "$OUT"; check "case_missing_fields: Code4rena without formattedAmount -> prize=-"

# ---------------------------------------------------------------------------------------------------------------
note "case_iso_offset"
cat > "$D/ca-offset.json" <<'EOF'
[{"id":"o1","name":"Offset Unknown","timeframe":{"start":"2026-11-01T00:00:00+02:00","end":"2026-12-01T00:00:00+02:00"},"status":"opening","kind":"public_contest"},
 {"id":"o2","name":"Offset Live","timeframe":{"start":"2026-11-01T00:00:00+02:00","end":"2026-11-02T00:00:00+02:00"},"status":"live","kind":"public_contest"}]
EOF
run_case case_iso_offset "CANTINA" --now "$N0" --cantina-from "$D/ca-offset.json"
! grep -q 'Offset Unknown' "$OUT"; check "case_iso_offset: an offset timestamp is unparseable, so the window rule cannot open an unknown status"
grep -q "^CANTINA${TAB}Offset Live${TAB}ends=-${TAB}" "$OUT"; check "case_iso_offset: a LIVE status with an unparseable end stays live (ends=-)"

# ---------------------------------------------------------------------------------------------------------------
note "case_epoch_render"
sh_page "$D/sh-epoch.json" false 4 "$(sh_item 1301 RUNNING 0 86399 'E1'),$(sh_item 1302 RUNNING 0 951782400 'E2'),$(sh_item 1303 RUNNING 0 1777307400 'E3'),$(sh_item 1304 RUNNING 0 4102444799 'E4')"
run_case case_epoch_render "SHERLOCK" --now 0 --sherlock-from "$D/sh-epoch.json"
[ "$(grep "^SHERLOCK${TAB}E[1-4]${TAB}" "$OUT" | cut -f3 | tr '\n' ' ')" = "ends=1970-01-01 ends=2000-02-29 ends=2026-04-27 ends=2099-12-31 " ]
check "case_epoch_render: 86399, 951782400, 1777307400, 4102444799 render as 1970-01-01, 2000-02-29, 2026-04-27, 2099-12-31 (--now 0 counts as set)"

# ---------------------------------------------------------------------------------------------------------------
note "case_candidate_cap"
mk_cap() {
  items=""; i=1
  while [ "$i" -le "$1" ]; do items="$items${items:+,}$(sh_item $((2000 + i)) FINISHED $P1 $F1)"; i=$((i + 1)); done
  sh_page "$2" false "$1" "$items"
}
mk_cap 60 "$D/sh-cap60.json"; mk_cap 61 "$D/sh-cap61.json"
run_case case_candidate_cap_60 "SHERLOCK" --now "$N0" --sherlock-from "$D/sh-cap60.json"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK ok 0 60 pages=1 statuses=FINISHED:60)" "case_candidate_cap: 60 candidates are processed -> ok"
run_case case_candidate_cap_61 "SHERLOCK" --now "$N0" --sherlock-from "$D/sh-cap61.json"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK parse-failed 0 61 pages=1 statuses=FINISHED:61 'reason=too-many-candidates n=61')" "case_candidate_cap: 61 -> parse-failed too-many-candidates n=61"

# ---------------------------------------------------------------------------------------------------------------
note "case_unsupported_fallthrough"
sed 's/^let PLATFORMS = \["IMMUNEFI", "CODEHAWKS", "SHERLOCK", "CANTINA", "CODE4RENA"\];$/let PLATFORMS = ["IMMUNEFI", "CODEHAWKS", "SHERLOCK", "CANTINA", "CODE4RENA", "NEWPLATFORM"];/' "$AGENT" > "$WORK/six.ag"
CONTEST_FINDER_AG="$WORK/six.ag"; NSTATUS=6; export CONTEST_FINDER_AG
run_case case_unsupported_fallthrough "" --now "$REC_NOW"
unset CONTEST_FINDER_AG NSTATUS
expect_status "$OUT" NEWPLATFORM "$(S NEWPLATFORM unsupported 0 0)" "case_unsupported_fallthrough: a listed platform with no channel reports unsupported"

# ---------------------------------------------------------------------------------------------------------------
note "case_from_path_forms / case_from_unreadable"
cp "$FIX/cantina-live.json" "$WORK/with space.json"
ln -s "$FIX/codehawks-trpc.json" "$WORK/ch-link.json"
cp "$FIX/immunefi.json" "$WORK/imm-rel.json"
OUT="$WORK/case_from_path_forms.out"
( cd "$WORK" && "$LAUNCHER" --now 1792454400 --immunefi-from imm-rel.json --codehawks-from ch-link.json \
    --cantina-from "with space.json" --sherlock-from "$FIX/sherlock-p1.json" --sherlock-from "$FIX/sherlock-p2.json" \
    --code4rena-from "$FIX/code4rena-p1.json" ) > "$OUT" 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(row_count "$OUT" CANTINA)" = 1 ] && [ "$(row_count "$OUT" IMMUNEFI)" = 1 ] \
  && [ "$(status_line "$OUT" CODEHAWKS)" = "$(S CODEHAWKS ok 0 45)" ]
check "case_from_path_forms: a relative path, a symlink and a name with a space all work"
OUT="$WORK/case_from_unreadable.out"
"$LAUNCHER" --cantina-from "$WORK/no-such-file.json" > "$OUT" 2>/dev/null; RC=$?
[ "$RC" = 2 ] && [ ! -s "$OUT" ]; check "case_from_unreadable: a missing --*-from file is a usage error (exit 2)"
run_case case_missing_fixture_page "SHERLOCK" --now "$REC_NOW" --sherlock-from "$FIX/sherlock-p1.json"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK fetch-failed 0 10 pages=1 statuses=FINISHED:10 reason=missing-fixture-page)" \
  "case_from_unreadable: offline mode asking for a page not given -> fetch-failed missing-fixture-page"

# ---------------------------------------------------------------------------------------------------------------
note "case_url_file_scheme"
REAL_CURL=""
for d in /usr/bin /bin /usr/local/bin; do [ -x "$d/curl" ] && { REAL_CURL="$d/curl"; break; }; done
if [ -z "$REAL_CURL" ]; then
  skip "case_url_file_scheme: no curl installed"
else
  mkdir -p "$WORK/realcurl"; ln -sf "$REAL_CURL" "$WORK/realcurl/curl"
  OUT="$WORK/case_url_file_scheme.out"
  PATH="$WORK/realcurl:$PATH" "$LAUNCHER" --now "$REC_NOW" --immunefi-from "$FIX/immunefi.json" --codehawks-from "$FIX/codehawks-trpc.json" \
    --sherlock-from "$FIX/sherlock-p1.json" --sherlock-from "$FIX/sherlock-p2.json" --code4rena-from "$FIX/code4rena-p1.json" \
    --cantina-url "file://$FIX/cantina.json" > "$OUT" 2>/dev/null; RC=$?
  [ "$RC" = 0 ] && [ "$(status_line "$OUT" CANTINA)" = "$(S CANTINA fetch-failed 0 0 reason=http-000)" ]
  check "case_url_file_scheme: a file:// URL gives http_code 000 -> fetch-failed http-000, not a silent success"
fi

# ---------------------------------------------------------------------------------------------------------------
note "case_parse_*"
: > "$D/empty.json"
printf '<!doctype html><html><body>maintenance</body></html>\n' > "$D/garbage.html"
printf '{"foo":1}\n' > "$D/shape.json"
printf '{"page":1,"items":[],"total":0,"has_next":false,"pages":0}\n' > "$D/sh-empty.json"
printf '[{"id":"u1","name":"ab\377cd"}]\n' > "$D/bad-utf8.json"
printf '[]\n' > "$D/empty-list.json"
run_case case_parse_a "IMMUNEFI CODEHAWKS SHERLOCK CANTINA CODE4RENA" --now "$N0" --immunefi-from "$D/empty.json" \
  --codehawks-from "$D/garbage.html" --sherlock-from "$D/sh-empty.json" --cantina-from "$D/shape.json" --code4rena-from "$D/bad-utf8.json"
expect_status "$OUT" IMMUNEFI "$(S IMMUNEFI parse-failed 0 0 reason=empty-body)" "case_parse_empty_body: an empty body -> parse-failed empty-body"
expect_status "$OUT" CODEHAWKS "$(S CODEHAWKS parse-failed 0 0 reason=json)" "case_parse_garbage: an HTML body -> parse-failed json"
expect_status "$OUT" SHERLOCK "$(S SHERLOCK parse-failed 0 0 pages=0 reason=empty-list)" "case_parse_empty_list: items [] with total 0 on page 1 -> parse-failed empty-list"
expect_status "$OUT" CANTINA "$(S CANTINA parse-failed 0 0 reason=shape)" "case_parse_shape: {\"foo\":1} -> parse-failed shape"
expect_status "$OUT" CODE4RENA "$(S CODE4RENA parse-failed 0 0 pages=0 reason=read)" "case_parse_bad_utf8: invalid UTF-8 -> parse-failed read"
run_case case_parse_b "CANTINA" --now "$N0" --cantina-from "$D/empty-list.json"
expect_status "$OUT" CANTINA "$(S CANTINA parse-failed 0 0 reason=empty-list)" "case_parse_empty_list: a bare [] -> parse-failed empty-list"
[ "$(grep -c "${TAB}ok${TAB}" "$OUT")" = 4 ]; check "case_parse_*: one platform's parse failure leaves the others ok"

# ---------------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then note "PASS ($PASSES checks)"; exit 0; fi
note "FAIL ($FAILS failed, $PASSES passed)"
exit 1
