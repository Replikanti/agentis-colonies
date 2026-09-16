#!/usr/bin/env bash
# demo-resolve-external.sh — OFFLINE, DETERMINISTIC self-test of resolve-external.sh (#2235, PR A).
#
# NOTHING here reaches the network and NOTHING here runs an LLM. The resolver's two outbound seams are
# replaced with fixture readers:
#   DF_SOURCIFY_CMD   -> cats fixtures/external/sourcify/<chain>/<address>.json (a canned v2 fields=source
#                        body), so the REAL unpacking code runs against a real-shaped response
#   DF_GIT_CLONE_CMD  -> clones a local BARE repo the demo builds from fixtures/external/upstream-seed/
#   DF_ETH_STORAGE_CMD-> returns a canned ERC-1967 storage word (the proxy branch)
# Every seam appends one line to a log, so "how many requests did that cost" is an assertion, not a hope.
# The real ~/.dark-factory is never touched: DARK_FACTORY_DIR and --cache-dir point into a temp dir.
#
#   AC1  (a) vendored          a symbol declared under the repo's lib/ resolves to path:line, ZERO seams
#   AC2  (b) sourcify          an address named in script/Deploy.s.sol resolves through the canned response
#   AC3  (c1) upstream comment a github URL in the repo's own header comment -> shallow clone -> path:line
#   AC4  (c2) upstream manifest a vendored package.json "repository" -> the other upstream repo
#   AC5  priority              vendored beats the address; the address beats the upstream clone
#   AC6  cache-first           a second resolution of the same symbol costs ZERO seam invocations
#   AC7  budget                the 6th NETWORK resolution against one --budget-state is budget-exhausted
#   AC8  offline               --offline never invokes a seam, and a vendored hit still resolves
#   AC15 terminal reason (#2238) the three "nothing to go on" refusals are DISTINCT and each reachable
#   AC16 vendored roots (#2240) `src/interfaces/external/` resolves; an uninitialised submodule refuses
#                        with `submodule-empty` (AC15/AC16 run HERE, before the sweeps below, so the
#                        vocabulary (AC9), two-roots (AC12) and grammar (AC14) checks cover their output)
#   AC9  closed vocabulary     every `unresolved` reason the script can emit is one of the documented eight
#   AC10 refusal               a URL, an over-long symbol, a malformed address and an unknown flag exit 2
#   AC11 proxy                 an ERC-1967 proxy: no RPC -> proxy-unresolved; RPC -> the impl is fetched
#   AC12 two roots             every emitted path is under --repo or under the cache root, and re-opens
#   AC13 host allowlist        the script names no host outside ALLOWED_HOSTS (with a dead-guard control)
#   AC14 grammar               exactly one stdout line per call, matching the EXTERNAL| grammar
#
# Usage: dark-factory/demo-resolve-external.sh
# Exit:  0 = all assertions held; non-zero = a failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RESOLVER="$HERE/resolve-external.sh"
FX="$HERE/fixtures/external"

FAILS=0
note() { echo "demo-resolve-external.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -x "$RESOLVER" ] || { note "resolve-external.sh not found / not executable: $RESOLVER" >&2; exit 3; }
[ -d "$FX/vendored-repo" ] || { note "missing fixture tree: $FX/vendored-repo" >&2; exit 3; }
command -v git >/dev/null 2>&1 || { note "git is required for the upstream fixture" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { note "python3 is required to unpack the Sourcify fixture" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-resolve-external.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REPO="$FX/vendored-repo"
SEAM_LOG="$WORK/seams.log"
: > "$SEAM_LOG"
export SEAM_LOG

# The real state dir is never used: every call writes into $WORK.
export DARK_FACTORY_DIR="$WORK/df"
mkdir -p "$DARK_FACTORY_DIR"

# ----------------------------------------------------------------------------------------------------------
# The local "upstream" fixture: one bare repo the clone seam serves for BOTH upstream URLs.
# ----------------------------------------------------------------------------------------------------------
BARE="$WORK/upstream.git"
SEED="$WORK/seed"
git init -q --bare "$BARE" >/dev/null 2>&1
mkdir -p "$SEED"
cp -R "$FX/upstream-seed/." "$SEED/"
git -C "$SEED" init -q >/dev/null 2>&1
git -C "$SEED" add -A >/dev/null 2>&1
git -C "$SEED" -c user.email=demo@example.invalid -c user.name=demo commit -q -m "upstream fixture" >/dev/null 2>&1
git -C "$SEED" push -q "$BARE" HEAD:refs/heads/main >/dev/null 2>&1
git -C "$BARE" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
export UPSTREAM_BARE="$BARE"

# ----------------------------------------------------------------------------------------------------------
# The three seams. Each logs one line per invocation so request counts are assertable.
# ----------------------------------------------------------------------------------------------------------
cat > "$WORK/stub-sourcify.sh" <<'STUB'
echo "sourcify $SOURCIFY_CHAIN $SOURCIFY_ADDRESS" >> "$SEAM_LOG"
f="$SOURCIFY_FIXTURES/$SOURCIFY_CHAIN/$SOURCIFY_ADDRESS.json"
[ -f "$f" ] || exit 1
cat "$f"
STUB
cat > "$WORK/stub-clone.sh" <<'STUB'
echo "clone $CLONE_URL" >> "$SEAM_LOG"
git clone -q "$UPSTREAM_BARE" "$CLONE_DEST" || exit 1
STUB
cat > "$WORK/stub-storage.sh" <<'STUB'
echo "storage $SLOT_ADDRESS $SLOT_KEY" >> "$SEAM_LOG"
echo "0x0000000000000000000000003333333333333333333333333333333333333333"
STUB

export SOURCIFY_FIXTURES="$FX/sourcify"
SOURCIFY_SEAM="sh $WORK/stub-sourcify.sh"
CLONE_SEAM="sh $WORK/stub-clone.sh"
STORAGE_SEAM="sh $WORK/stub-storage.sh"

seam_count() { grep -c "^$1 " "$SEAM_LOG" 2>/dev/null | head -n 1 || true; }
seam_reset() { : > "$SEAM_LOG"; }

OUT=""; RC=0
# Every invocation below names `bash` EXPLICITLY rather than relying on the shebang or on /bin/sh: the
# resolver is bash-only (`set -o pipefail`, herestrings), so under a dash /bin/sh — what CI runs — an `sh`
# invocation would exit 2 with NO output. hunter.ag's directive names the same interpreter, and
# demo-resolve-cell.sh pins that coupling.
run() { # run the resolver with both network seams live; captures stdout only
    OUT="$(DF_SOURCIFY_CMD="$SOURCIFY_SEAM" DF_GIT_CLONE_CMD="$CLONE_SEAM" \
           bash "$RESOLVER" "$@" 2>"$WORK/stderr.log")"
    RC=$?
}
run_bare() { # no seams configured at all (the defaults would need the network, so pair with --offline)
    OUT="$(bash "$RESOLVER" "$@" 2>"$WORK/stderr.log")"
    RC=$?
}

field() { printf '%s' "$OUT" | cut -d'|' -f"$1"; }
kind()  { field 3; }
loc()   { field 4; }
lines_of_out() { printf '%s\n' "$OUT" | grep -c . ; }

ALL_HITS="$WORK/all-hits.txt"
: > "$ALL_HITS"
record_hit() { [ "$(kind)" != "unresolved" ] && printf '%s\n' "$OUT" >> "$ALL_HITS"; return 0; }

VOCAB="no-vendored-match no-address not-verified-on-sourcify no-upstream-url network-unavailable budget-exhausted submodule-empty bad-input"
ALL_REASONS="$WORK/all-reasons.txt"
: > "$ALL_REASONS"
record_reason() { [ "$(kind)" = "unresolved" ] && field 4 >> "$ALL_REASONS"; return 0; }

check() { record_hit; record_reason; }

# ----------------------------------------------------------------------------------------------------------
note "AC1) (a) vendored: a symbol declared under the audited repo's lib/ resolves to path:line, zero seams ..."
seam_reset
CACHE1="$WORK/cache1"
run --symbol IRateSource.rate --repo "$REPO" --cache-dir "$CACHE1"; check
[ "$RC" -eq 0 ] && [ "$(kind)" = "vendored" ] \
  && ok "AC1: IRateSource.rate -> vendored (rc 0)" \
  || bad "AC1 FAILED: rc=$RC out='$OUT'"
case "$(loc)" in
  "$REPO"/lib/*) ok "AC1: the cited path is inside the audited repo's lib/" ;;
  *) bad "AC1 FAILED: path '$(loc)' is not under $REPO/lib" ;;
esac
AC1_FILE="${OUT%:*}"; AC1_FILE="${AC1_FILE##*|}"
AC1_LINE="$(loc)"; AC1_LINE="${AC1_LINE##*:}"
sed -n "${AC1_LINE}p" "$AC1_FILE" | grep -q '1e18' \
  && ok "AC1: the cited LINE re-opens and literally states the scaling fact (1e18)" \
  || bad "AC1 FAILED: line $AC1_LINE of $AC1_FILE does not state the fact"
[ "$(seam_count sourcify)" = "0" ] && [ "$(seam_count clone)" = "0" ] \
  && ok "AC1: a vendored hit costs ZERO network requests" \
  || bad "AC1 FAILED: seams fired on a vendored hit ($(cat "$SEAM_LOG"))"

# ----------------------------------------------------------------------------------------------------------
note "AC2) (b) sourcify: an address named in the repo's deploy script resolves through the canned body ..."
seam_reset
CACHE2="$WORK/cache2"
run --symbol ExternalQuoteSource --repo "$REPO" --chain 11155111 --cache-dir "$CACHE2"; check
[ "$(kind)" = "sourcify" ] \
  && ok "AC2: ExternalQuoteSource -> sourcify" \
  || bad "AC2 FAILED: out='$OUT'"
case "$(loc)" in
  "$CACHE2"/sourcify/11155111/0x1111111111111111111111111111111111111111/sources/*) \
    ok "AC2: the cited path is the cached verified source of the address from Deploy.s.sol" ;;
  *) bad "AC2 FAILED: path '$(loc)' is not the expected cache entry" ;;
esac
grep -q "^sourcify 11155111 0x1111111111111111111111111111111111111111$" "$SEAM_LOG" \
  && ok "AC2: the address was DISCOVERED in the repo (never supplied by the caller)" \
  || bad "AC2 FAILED: seam log = $(cat "$SEAM_LOG")"
[ "$(seam_count sourcify)" = "1" ] \
  && ok "AC2: exactly one Sourcify request" \
  || bad "AC2 FAILED: $(seam_count sourcify) Sourcify requests"
grep -q "^proxy	proxy-unresolved$" "$CACHE2/sourcify/11155111/0x1111111111111111111111111111111111111111/meta.tsv" \
  && ok "AC2: with no RPC configured the record says proxy-unresolved" \
  || bad "AC2 FAILED: meta.tsv missing the proxy-unresolved marker"

# ----------------------------------------------------------------------------------------------------------
note "AC3) (c1) upstream: a github URL in the repo's OWN header comment -> shallow clone -> path:line ..."
seam_reset
CACHE3="$WORK/cache3"
run --symbol UpstreamRegistry --repo "$REPO" --cache-dir "$CACHE3"; check
[ "$(kind)" = "upstream" ] \
  && ok "AC3: UpstreamRegistry -> upstream" \
  || bad "AC3 FAILED: out='$OUT'"
grep -q "^clone https://github.com/example-org/ext-registry$" "$SEAM_LOG" \
  && ok "AC3: the clone URL came from the audited repo's header comment" \
  || bad "AC3 FAILED: seam log = $(cat "$SEAM_LOG")"
case "$(loc)" in
  "$CACHE3"/repo/github.com/example-org/ext-registry@default/*) ok "AC3: the cited path is inside the cached clone" ;;
  *) bad "AC3 FAILED: path '$(loc)' is not under the clone cache" ;;
esac

# ----------------------------------------------------------------------------------------------------------
note "AC4) (c2) upstream: a vendored package.json \"repository\" names the upstream of a source-less dep ..."
seam_reset
CACHE4="$WORK/cache4"
run --symbol IRegistryLedger --repo "$REPO" --cache-dir "$CACHE4"; check
[ "$(kind)" = "upstream" ] \
  && ok "AC4: IRegistryLedger -> upstream" \
  || bad "AC4 FAILED: out='$OUT'"
grep -q "^clone https://github.com/example-org/ext-ledger$" "$SEAM_LOG" \
  && ok "AC4: the clone URL came from lib/ext-registry/package.json, not from a comment" \
  || bad "AC4 FAILED: seam log = $(cat "$SEAM_LOG")"

# ----------------------------------------------------------------------------------------------------------
note "AC5) priority: vendored beats the deployed address; the address beats the upstream clone ..."
seam_reset
CACHE5="$WORK/cache5"
# IRateSource is vendored AND carries an address in Deploy.s.sol AND its consumer names an upstream repo.
run --symbol IRateSource --repo "$REPO" --chain 11155111 --cache-dir "$CACHE5"; check
[ "$(kind)" = "vendored" ] && [ "$(seam_count sourcify)" = "0" ] && [ "$(seam_count clone)" = "0" ] \
  && ok "AC5: vendored wins over both network paths and spends nothing" \
  || bad "AC5 FAILED: kind=$(kind) seams=$(cat "$SEAM_LOG")"
# ExternalQuoteSource is NOT vendored, carries an address, and its consumer names an upstream repo.
seam_reset
run --symbol ExternalQuoteSource --repo "$REPO" --chain 11155111 --cache-dir "$WORK/cache5b"; check
[ "$(kind)" = "sourcify" ] && [ "$(seam_count clone)" = "0" ] \
  && ok "AC5: the deployed address wins over the upstream clone (no clone attempted)" \
  || bad "AC5 FAILED: kind=$(kind) seams=$(cat "$SEAM_LOG")"

# ----------------------------------------------------------------------------------------------------------
note "AC6) cache-first: a second resolution of the same symbol invokes NO seam and returns the same record ..."
FIRST="$OUT"
seam_reset
run --symbol ExternalQuoteSource --repo "$REPO" --chain 11155111 --cache-dir "$WORK/cache5b"; check
[ "$OUT" = "$FIRST" ] \
  && ok "AC6: the cached resolution is byte-identical to the first" \
  || bad "AC6 FAILED: '$OUT' != '$FIRST'"
[ "$(seam_count sourcify)" = "0" ] && [ "$(seam_count clone)" = "0" ] \
  && ok "AC6: the cache hit costs ZERO network requests" \
  || bad "AC6 FAILED: seams fired on a cache hit ($(cat "$SEAM_LOG"))"
seam_reset
run --symbol UpstreamRegistry --repo "$REPO" --cache-dir "$CACHE3"; check
[ "$(kind)" = "upstream" ] && [ "$(seam_count clone)" = "0" ] \
  && ok "AC6: the cached CLONE is reused too" \
  || bad "AC6 FAILED: kind=$(kind) seams=$(cat "$SEAM_LOG")"

# ----------------------------------------------------------------------------------------------------------
note "AC7) budget: five network resolutions against one --budget-state, the sixth is budget-exhausted ..."
seam_reset
BSTATE="$WORK/budget/cell-1"
i=1
while [ "$i" -le 6 ]; do
    run --symbol UpstreamRegistry --repo "$REPO" --budget-state "$BSTATE" --cache-dir "$WORK/bcache-$i"; check
    if [ "$i" -le 5 ]; then
        [ "$(kind)" = "upstream" ] || bad "AC7 FAILED: resolution $i was '$OUT' (want an upstream hit)"
    else
        [ "$(kind)" = "unresolved" ] && [ "$(field 4)" = "budget-exhausted" ] \
          && ok "AC7: the 6th network resolution refuses with budget-exhausted" \
          || bad "AC7 FAILED: 6th resolution was '$OUT'"
    fi
    i=$((i + 1))
done
[ "$(seam_count clone)" = "5" ] \
  && ok "AC7: exactly 5 clone requests left the host (the 6th never fired a seam)" \
  || bad "AC7 FAILED: $(seam_count clone) clone requests"

# ----------------------------------------------------------------------------------------------------------
note "AC8) --offline: no seam is ever invoked, and a vendored hit still resolves ..."
seam_reset
run --symbol UpstreamRegistry --repo "$REPO" --offline --cache-dir "$WORK/cache8"; check
[ "$(kind)" = "unresolved" ] && [ "$(field 4)" = "network-unavailable" ] \
  && ok "AC8: an offline network resolution refuses with network-unavailable" \
  || bad "AC8 FAILED: out='$OUT'"
[ "$(seam_count clone)" = "0" ] && [ "$(seam_count sourcify)" = "0" ] \
  && ok "AC8: --offline invoked no seam at all" \
  || bad "AC8 FAILED: seams fired under --offline ($(cat "$SEAM_LOG"))"
run_bare --symbol IRateSource --repo "$REPO" --offline --cache-dir "$WORK/cache8"; check
[ "$(kind)" = "vendored" ] \
  && ok "AC8: the vendored path is fully offline (no seam configured at all)" \
  || bad "AC8 FAILED: out='$OUT'"

# ----------------------------------------------------------------------------------------------------------
note "AC15) #2238 terminal reason: the three \"nothing to go on\" refusals are distinct and each reachable ..."
# Before #2238 the upstream step recorded `no-upstream-url` unconditionally, so it outranked both weaker
# reasons and EVERY negative case — a symbol the repo never mentions included — came back as `no-upstream-url`.
# The rule now is APPLICABILITY: a step that could not have applied records nothing.
seam_reset
run_bare --symbol NoSuchThing --repo "$REPO" --offline --cache-dir "$WORK/cache15a"; check
R15A="$(field 4)"
[ "$(kind)" = "unresolved" ] && [ "$R15A" = "no-vendored-match" ] \
  && ok "AC15: a symbol the repo neither vendors nor mentions -> no-vendored-match" \
  || bad "AC15 FAILED: NoSuchThing -> '$OUT' (want unresolved|no-vendored-match)"
[ "$(seam_count clone)" = "0" ] && [ "$(seam_count sourcify)" = "0" ] \
  && ok "AC15: an inapplicable upstream step attempts no request at all" \
  || bad "AC15 FAILED: seams fired for an unmentioned symbol ($(cat "$SEAM_LOG"))"
# Mentioned, but the repo ships no deployment for it and names no upstream: the identity is known, nothing else.
run_bare --symbol IIsolatedFeed --repo "$REPO" --offline --cache-dir "$WORK/cache15b"; check
R15B="$(field 4)"
[ "$R15B" = "no-address" ] \
  && ok "AC15: a symbol the repo mentions with no deployed address and no upstream -> no-address" \
  || bad "AC15 FAILED: IIsolatedFeed -> '$OUT' (want unresolved|no-address)"
# Furthest progress: the repo NAMES an upstream, the clone succeeds, and the declaration is still not there.
# This also proves the override — `no-address` (higher-ranked) was already recorded by the address step.
seam_reset
run --symbol RetiredRegistryView --repo "$REPO" --cache-dir "$WORK/cache15c"; check
R15C="$(field 4)"
[ "$R15C" = "no-upstream-url" ] \
  && ok "AC15: a named upstream that was cloned and lacks the declaration -> no-upstream-url" \
  || bad "AC15 FAILED: RetiredRegistryView -> '$OUT' (want unresolved|no-upstream-url)"
[ "$(seam_count clone)" = "1" ] \
  && ok "AC15: that refusal is reported AFTER the clone actually ran (furthest progress, not bookkeeping)" \
  || bad "AC15 FAILED: $(seam_count clone) clone requests for RetiredRegistryView"
if [ "$R15A" != "$R15B" ] && [ "$R15B" != "$R15C" ] && [ "$R15A" != "$R15C" ]; then
    ok "AC15: the three basic negative cases report three DIFFERENT reasons ($R15A / $R15B / $R15C)"
else
    bad "AC15 FAILED: reasons collapse ($R15A / $R15B / $R15C)"
fi

# ----------------------------------------------------------------------------------------------------------
note "AC16) #2240 vendored roots: src/interfaces/external/ resolves; an empty submodule says so ..."
seam_reset
run_bare --symbol IExtQuoteFeed.latestQuote --repo "$REPO" --offline --cache-dir "$WORK/cache16a"; check
[ "$(kind)" = "vendored" ] \
  && ok "AC16: a symbol vendored under src/interfaces/external/ resolves through step (a)" \
  || bad "AC16 FAILED: IExtQuoteFeed.latestQuote -> '$OUT'"
case "$(loc)" in
  "$REPO"/src/interfaces/external/*) ok "AC16: the cited path is the src/-adjacent vendored root, not lib/" ;;
  *) bad "AC16 FAILED: path '$(loc)' is not under $REPO/src/interfaces/external" ;;
esac
AC16_FILE="${OUT%:*}"; AC16_FILE="${AC16_FILE##*|}"
AC16_LINE="$(loc)"; AC16_LINE="${AC16_LINE##*:}"
sed -n "${AC16_LINE}p" "$AC16_FILE" | grep -q '1e18' \
  && ok "AC16: the cited LINE re-opens and states the scaling fact" \
  || bad "AC16 FAILED: line $AC16_LINE of $AC16_FILE does not state the fact"
[ "$(seam_count sourcify)" = "0" ] && [ "$(seam_count clone)" = "0" ] \
  && ok "AC16: the new root is as free as the others (zero requests)" \
  || bad "AC16 FAILED: seams fired on the src/interfaces/external hit ($(cat "$SEAM_LOG"))"
# ONE root list, used by step (a) AND by the vendored-manifest lookup, so the two can never drift.
[ "$(grep -c 'VENDOR_ROOTS' "$RESOLVER")" -ge 3 ] \
  && ok "AC16: both vendored scans read the same VENDOR_ROOTS list" \
  || bad "AC16 FAILED: VENDOR_ROOTS is not the single source of the root list"
# An UNINITIALISED submodule: git leaves the mount point as an empty directory. A checkout in that state is
# the measured held-out shape, and answering `no-vendored-match` there blames the resolver's scope for it.
SUBREPO="$WORK/submodule-repo"
mkdir -p "$SUBREPO"
cp -R "$REPO/." "$SUBREPO/"
mkdir -p "$SUBREPO/lib/ext-uninitialised"
printf '[submodule "lib/ext-uninitialised"]\n\tpath = lib/ext-uninitialised\n\turl = https://github.com/example-org/ext-uninitialised\n' \
    > "$SUBREPO/.gitmodules"
run_bare --symbol NoSuchThing --repo "$SUBREPO" --offline --cache-dir "$WORK/cache16b"; check
[ "$(field 4)" = "submodule-empty" ] \
  && ok "AC16: a vendored root holding an empty (uninitialised) submodule refuses with submodule-empty" \
  || bad "AC16 FAILED: empty-submodule repo -> '$OUT' (want unresolved|submodule-empty)"
# Dead-guard: the same probe on the SHIPPED fixture (no empty roots) must NOT report it, else the detector
# would be a constant rather than a check.
[ "$R15A" = "no-vendored-match" ] \
  && ok "AC16: the detector is not a constant — the checked-out fixture repo still reports no-vendored-match" \
  || bad "AC16 FAILED: submodule-empty fires on a fully checked-out repo"

# ----------------------------------------------------------------------------------------------------------
note "AC9) closed refusal vocabulary: every reason the script can emit is one of the documented eight ..."
EMITTED="$(LC_ALL=C sort -u "$ALL_REASONS" 2>/dev/null)"
UNKNOWN=""
for r in $EMITTED; do
    case " $VOCAB " in *" $r "*) : ;; *) UNKNOWN="$UNKNOWN $r" ;; esac
done
[ -z "$UNKNOWN" ] \
  && ok "AC9: every reason emitted so far is in the closed vocabulary ($(printf '%s' "$EMITTED" | tr '\n' ' '))" \
  || bad "AC9 FAILED: reason(s) outside the vocabulary:$UNKNOWN"
# Source-guard: the reasons the CODE can produce are exactly the documented set.
SRC_REASONS="$(grep -oE 'note_reason [a-z-]+' "$RESOLVER" | awk '{print $2}'; echo bad-input)"
SRC_UNKNOWN=""
for r in $(printf '%s\n' "$SRC_REASONS" | LC_ALL=C sort -u); do
    case " $VOCAB " in *" $r "*) : ;; *) SRC_UNKNOWN="$SRC_UNKNOWN $r" ;; esac
done
[ -z "$SRC_UNKNOWN" ] \
  && ok "AC9: the script's own note_reason call sites name no reason outside the vocabulary" \
  || bad "AC9 FAILED: script can emit undocumented reason(s):$SRC_UNKNOWN"

# ----------------------------------------------------------------------------------------------------------
note "AC10) refusal: a URL, an over-long symbol, a malformed address and an unknown flag all exit 2 ..."
run_bare --symbol "https://github.com/example-org/ext-registry" --repo "$REPO"
[ "$RC" -eq 2 ] && [ "$OUT" = 'EXTERNAL|?|unresolved|bad-input' ] \
  && ok "AC10: a model-supplied URL is refused (exit 2, one bad-input line, symbol not echoed back)" \
  || bad "AC10 FAILED: rc=$RC out='$OUT'"
LONG="$(printf 'A%.0s' $(seq 1 200))"
run_bare --symbol "$LONG" --repo "$REPO"
[ "$RC" -eq 2 ] && ok "AC10: a 200-character symbol is refused" || bad "AC10 FAILED: long symbol rc=$RC"
run_bare --symbol IRateSource --address deadbeef --repo "$REPO"
[ "$RC" -eq 2 ] && ok "AC10: a malformed --address is refused" || bad "AC10 FAILED: bad address rc=$RC"
run_bare --symbol 'IRateSource; rm -rf /' --repo "$REPO"
[ "$RC" -eq 2 ] && ok "AC10: a symbol carrying shell metacharacters is refused" || bad "AC10 FAILED: metachar rc=$RC"
run_bare --url "https://github.com/example-org/ext-registry"
[ "$RC" -eq 2 ] && ok "AC10: there is no flag that takes a URL (unknown arg -> exit 2)" || bad "AC10 FAILED: --url rc=$RC"
grep -qE '^[[:space:]]*--(url|host|endpoint|server|api)\)' "$RESOLVER" \
  && bad "AC10 FAILED: the resolver accepts a host-shaped flag" \
  || ok "AC10: the argument table contains no --url/--host/--endpoint/--server/--api flag"

# ----------------------------------------------------------------------------------------------------------
note "AC11) ERC-1967 proxy: without an RPC the record says proxy-unresolved; with one the impl is fetched ..."
seam_reset
CACHE11="$WORK/cache11"
run --symbol ProxiedVault --address 0x4444444444444444444444444444444444444444 --chain 11155111 \
    --cache-dir "$CACHE11"; check
[ "$(kind)" = "unresolved" ] && [ "$(field 4)" = "not-verified-on-sourcify" ] \
  && ok "AC11: no RPC -> the proxy's own source is fetched and does not declare the symbol" \
  || bad "AC11 FAILED: out='$OUT'"
grep -q "^proxy	proxy-unresolved$" "$CACHE11/sourcify/11155111/0x4444444444444444444444444444444444444444/meta.tsv" \
  && ok "AC11: meta.tsv records proxy-unresolved (never a silent claim about the implementation)" \
  || bad "AC11 FAILED: meta.tsv = $(cat "$CACHE11/sourcify/11155111/0x4444444444444444444444444444444444444444/meta.tsv" 2>&1)"
seam_reset
CACHE11B="$WORK/cache11b"
OUT="$(DF_SOURCIFY_CMD="$SOURCIFY_SEAM" DF_GIT_CLONE_CMD="$CLONE_SEAM" DF_ETH_STORAGE_CMD="$STORAGE_SEAM" \
       DF_EXTERNAL_RPC="http://127.0.0.1:8545" \
       bash "$RESOLVER" --symbol ProxiedVault --address 0x4444444444444444444444444444444444444444 \
       --chain 11155111 --cache-dir "$CACHE11B" 2>"$WORK/stderr.log")"; RC=$?
check
[ "$(kind)" = "sourcify" ] \
  && ok "AC11: with an RPC configured the implementation behind the slot resolves" \
  || bad "AC11 FAILED: out='$OUT'"
grep -q "^sourcify 11155111 0x3333333333333333333333333333333333333333$" "$SEAM_LOG" \
  && ok "AC11: the IMPLEMENTATION address was fetched, not the proxy" \
  || bad "AC11 FAILED: seam log = $(cat "$SEAM_LOG")"
grep -q "^proxy	0x3333333333333333333333333333333333333333$" \
  "$CACHE11B/sourcify/11155111/0x4444444444444444444444444444444444444444/meta.tsv" \
  && ok "AC11: meta.tsv records the resolved implementation address" \
  || bad "AC11 FAILED: meta.tsv lacks the resolved impl"

# ----------------------------------------------------------------------------------------------------------
note "AC12) two roots: every emitted path is under --repo or under a cache root, and every one re-opens ..."
BADROOT=0; BADOPEN=0; NHITS=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    NHITS=$((NHITS + 1))
    l="$(printf '%s' "$line" | cut -d'|' -f4)"
    p="${l%:*}"; n="${l##*:}"
    case "$p" in
        "$REPO"/*|"$WORK"/*) : ;;
        *) BADROOT=$((BADROOT + 1)); echo "    outside both roots: $p" ;;
    esac
    if [ ! -f "$p" ] || [ -z "$(sed -n "${n}p" "$p" 2>/dev/null)" ]; then
        BADOPEN=$((BADOPEN + 1)); echo "    does not re-open: $p:$n"
    fi
done < "$ALL_HITS"
[ "$NHITS" -gt 0 ] && [ "$BADROOT" -eq 0 ] \
  && ok "AC12: all $NHITS emitted paths live under the audited repo or the cache" \
  || bad "AC12 FAILED: $BADROOT of $NHITS paths outside both roots"
[ "$BADOPEN" -eq 0 ] \
  && ok "AC12: every emitted path:line re-opens to a non-empty line" \
  || bad "AC12 FAILED: $BADOPEN citations do not re-open"

# ----------------------------------------------------------------------------------------------------------
note "AC13) host allowlist: the script names no host outside ALLOWED_HOSTS (plus a dead-guard control) ..."
# The same extractor tools/colony-lint.sh runs: every https?:// and git@ host literal in the file.
# Backslashes are stripped first so a host hidden inside an escaped regex literal (https://host\.tld)
# still yields its full host instead of a truncated prefix.
extract_hosts() {
    sed 's/\\//g' "$1" | grep -oE '(https?://|git@)[A-Za-z0-9][A-Za-z0-9.-]*' \
        | sed -e 's|^https\{0,1\}://||' -e 's|^git@||' | LC_ALL=C sort -u
}
ALLOWED="$(grep -E "^ALLOWED_HOSTS='" "$RESOLVER" | head -n 1 | sed -e "s/^ALLOWED_HOSTS='//" -e "s/'$//")"
[ -n "$ALLOWED" ] \
  && ok "AC13: the allowlist is hard-coded in the script ($ALLOWED)" \
  || bad "AC13 FAILED: ALLOWED_HOSTS is not a hard-coded literal"
OFFLIST=""
for h in $(extract_hosts "$RESOLVER"); do
    case " $ALLOWED " in *" $h "*) : ;; *) OFFLIST="$OFFLIST $h" ;; esac
done
[ -z "$OFFLIST" ] \
  && ok "AC13: no host literal outside the allowlist" \
  || bad "AC13 FAILED: off-allowlist host(s):$OFFLIST"
# Dead-guard control: the extractor must actually catch a planted host, else the check above proves nothing.
cp "$RESOLVER" "$WORK/planted.sh"
echo '# planted control: https://not-an-allowed-host.example/probe' >> "$WORK/planted.sh"
PLANTED=""
for h in $(extract_hosts "$WORK/planted.sh"); do
    case " $ALLOWED " in *" $h "*) : ;; *) PLANTED="$PLANTED $h" ;; esac
done
case " $PLANTED " in
  *" not-an-allowed-host.example "*) ok "AC13: dead-guard control — the extractor does catch a planted off-allowlist host" ;;
  *) bad "AC13 FAILED: the extractor is dead (planted host produced '$PLANTED')" ;;
esac
# The refusal path is live too: an allowlist check exists and is called before every outbound request.
[ "$(grep -c 'host_allowed' "$RESOLVER")" -ge 3 ] \
  && ok "AC13: host_allowed() guards both outbound seams" \
  || bad "AC13 FAILED: host_allowed() is not called on every outbound path"

# ----------------------------------------------------------------------------------------------------------
note "AC14) grammar: exactly one stdout line per call, and it matches the EXTERNAL| contract ..."
GRAMMAR_BAD=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" \
        | grep -qE '^EXTERNAL\|[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?\|(vendored|sourcify|upstream)\|/[^|]+:[0-9]+\|[0-9a-f]{64}$' \
        || { GRAMMAR_BAD=$((GRAMMAR_BAD + 1)); echo "    off-grammar: $line"; }
done < "$ALL_HITS"
[ "$GRAMMAR_BAD" -eq 0 ] \
  && ok "AC14: all $NHITS hit lines match EXTERNAL|<symbol>|<kind>|<path>:<line>|<sha256>" \
  || bad "AC14 FAILED: $GRAMMAR_BAD off-grammar hit lines"
run --symbol UpstreamRegistry --repo "$REPO" --cache-dir "$CACHE3"
[ "$(lines_of_out)" -eq 1 ] \
  && ok "AC14: a call prints exactly one line on stdout" \
  || bad "AC14 FAILED: $(lines_of_out) stdout lines"
grep -qiE '(agentis|claude|flat-cyborg|--backend)' "$RESOLVER" \
  && bad "AC14 FAILED: the resolver reaches for an LLM backend" \
  || ok "AC14: no LLM anywhere in the resolver"

# ----------------------------------------------------------------------------------------------------------
echo
if [ "$FAILS" -eq 0 ]; then
    note "PASS: resolve-external.sh turns a SYMBOL (never a URL) into a re-openable path:line — vendored"
    note "      source first, then the deployed address the audited repo itself names via keyless Sourcify"
    note "      (ERC-1967 implementation resolved when an RPC exists, else recorded proxy-unresolved), then"
    note "      the upstream repo the audited repo's own header or vendored manifest points at. Cache-first,"
    note "      budget-bounded, closed refusal vocabulary, hard-coded host allowlist with a live dead-guard."
    note "      Offline and deterministic: no network, no LLM, the real state dir untouched."
    exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
