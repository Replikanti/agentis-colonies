#!/usr/bin/env bash
# demo-watch-code-changes.sh — OFFLINE, DETERMINISTIC proof (#2128, epic #2120 M1) of watch-code-changes.sh:
# the read-only code-CHANGE watcher over an Immunefi bounties.json on two axes (github HEAD/tags via
# `git ls-remote`; ERC-1967 impl-slot via `cast storage`). Mirrors demo-apply-audit-density.sh's assert-based
# [PASS]/[FAIL] accounting — a hand-written tiny bounties.json fixture + a canned `--probe-cmd` STUB keyed on
# $PROBE_KIND/$PROBE_REPO/$PROBE_ADDR, so NO network (`git ls-remote`/`cast` are never invoked) and the real
# ~/.dark-factory is never touched.
#
# Asserts:
#   AC1 — COLD START over the fixture: state/ is seeded but changes.tsv has ZERO data rows (first sight is a
#         baseline, never a change).
#   AC2 — after rewinding a `head` state entry AND an `impl` state entry to older values, the next run emits
#         EXACTLY ONE `head` row and EXACTLY ONE `impl` row, each with the correct old->new, the correct
#         repo_or_addr, and the correct chain (head chain='-', impl chain=<resolved>).
#   AC3 — a program with null githubUrl and no address asset is skipped cleanly: no state file, no row, a
#         [SKIP] note on stderr.
#   AC4 — address/chain field-variance (a fresh state dir): assets across etherscan.io, bscscan.com,
#         arbiscan.io, optimistic.etherscan.io (proves most-specific-FIRST: NOT mislabelled ethereum), an
#         `…/address/0x…#code` suffix, and a non-address github asset URL -> one impl row per address with the
#         right chain, and the non-address URL yields no row.
#   AC5 — an all-zero impl word (EOA / non-proxy) and an empty (unreachable) impl read are BOTH skipped: never
#         baselined, never a row — a transient outage cannot flap.
#   AC6 — #2138 regression: a program whose assets list the SAME address 4x on one chain (already deduped
#         upstream) AND the same address again on a SECOND chain (a real deterministic-deploy shape) -> cold
#         start emits ZERO rows and baselines each (chain,addr) independently. This is the exact live shape
#         that violated cold-start-zero: without a chain-keyed state line, the second chain's first-ever read
#         collided with the first chain's freshly-written baseline and looked like a phantom change.
#   AC7 — after AC6's cold baseline, rewinding ONLY the second chain's state entry emits EXACTLY ONE impl row,
#         carrying that chain (not the other one) — a genuine per-chain impl move is still detected correctly.
#
# Usage:  dark-factory/demo-watch-code-changes.sh
# Requires: python3. Exit: 0 = all assertions held; non-zero = a failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/watch-code-changes.sh"

FAILS=0
note() { echo "demo-watch-code-changes.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$WATCH" ] || { note "watch-code-changes.sh not found / not executable: $WATCH" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-watch-code-changes.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# Fixture bounties.json (a top-level array, the real Immunefi shape):
#   alpha : githubUrl + one etherscan address        -> both axes exercised.
#   gamma : githubUrl + five explorer-domain address variants + one non-address github asset URL.
#   beta  : null githubUrl, only a docs + website URL -> skipped cleanly (AC3).
#   delta : one all-zero-impl address + one unreachable address, no repo -> both impl reads skipped (AC5).
# ----------------------------------------------------------------------------------------------------------
BJSON="$WORK/bounties.json"
cat > "$BJSON" <<'JSON'
[
 {"slug":"alpha","githubUrl":"https://github.com/example/alpha","ecosystem":["Ethereum"],"language":["Solidity"],
  "assets":[{"url":"https://etherscan.io/address/0x1111111111111111111111111111111111111111"}]},
 {"slug":"gamma","githubUrl":"https://github.com/example/gamma","ecosystem":["Ethereum","BSC","Arbitrum","Optimism"],
  "language":["Solidity"],
  "assets":[
   {"url":"https://etherscan.io/address/0x2222222222222222222222222222222222222222"},
   {"url":"https://bscscan.com/address/0x3333333333333333333333333333333333333333"},
   {"url":"https://arbiscan.io/address/0x4444444444444444444444444444444444444444"},
   {"url":"https://optimistic.etherscan.io/address/0x5555555555555555555555555555555555555555"},
   {"url":"https://etherscan.io/address/0x6666666666666666666666666666666666666666#code"},
   {"url":"https://github.com/example/gamma-extra"}]},
 {"slug":"beta","githubUrl":null,"ecosystem":["Ethereum"],"language":["Solidity"],
  "assets":[{"url":"https://docs.beta.example/whitepaper"},{"url":"https://beta.example"}]},
 {"slug":"delta","githubUrl":null,"ecosystem":["Ethereum"],"language":["Solidity"],
  "assets":[
   {"url":"https://etherscan.io/address/0x7777777777777777777777777777777777777777"},
   {"url":"https://etherscan.io/address/0x8888888888888888888888888888888888888888"}]},
 {"slug":"epsilon","githubUrl":null,"ecosystem":["Ethereum","Arbitrum"],"language":["Solidity"],
  "assets":[
   {"url":"https://etherscan.io/address/0x9999999999999999999999999999999999999999"},
   {"url":"https://etherscan.io/address/0x9999999999999999999999999999999999999999"},
   {"url":"https://etherscan.io/address/0x9999999999999999999999999999999999999999"},
   {"url":"https://etherscan.io/address/0x9999999999999999999999999999999999999999"},
   {"url":"https://arbiscan.io/address/0x9999999999999999999999999999999999999999"}]}
]
JSON

# The --probe-cmd STUB: keyed on $PROBE_KIND, then $PROBE_REPO (lsremote) / $PROBE_ADDR (impl). Prints canned
# `git ls-remote` lines and canned impl words; 0x7777 -> all-zero, 0x8888 -> empty (unreachable). Values are
# STABLE across runs, so the ONLY thing that produces a change row is a rewound state entry.
STUB='case "$PROBE_KIND" in
  lsremote)
    case "$PROBE_REPO" in
      *example/alpha) printf "%s\tHEAD\n%s\trefs/tags/v1.0.0\n%s\trefs/tags/v1.0.0^{}\n" \
                        1111aaaaHEADSHA 2222bbbbTAGSHA 2222bbbbTAGSHA ;;
      *example/gamma) printf "%s\tHEAD\n%s\trefs/tags/v2.0.0\n" 3333ccccHEADSHA 4444ddddTAGSHA ;;
      *) ;;
    esac
    ;;
  impl)
    case "$PROBE_ADDR" in
      0x7777777777777777777777777777777777777777)
        printf "0x0000000000000000000000000000000000000000000000000000000000000000\n" ;;
      0x8888888888888888888888888888888888888888) ;;   # empty = unreachable RPC
      0x9999999999999999999999999999999999999999)
        # #2138: the SAME address deployed on two chains reads a DIFFERENT impl word on each —
        # a real deterministic-deploy shape. Chain-keyed on $PROBE_CHAIN (set by the caller loop).
        case "$PROBE_CHAIN" in
          ethereum) printf "0x00000000000000000000000000000000000000000000000000000000ee9999\n" ;;
          arbitrum) printf "0x00000000000000000000000000000000000000000000000000000000ab9999\n" ;;
        esac
        ;;
      *) printf "0x000000000000000000000000%s\n" "${PROBE_ADDR#0x}" | cut -c1-66 ;;
    esac
    ;;
esac'

state_file_of() { echo "$1/state/immunefi:$2.state"; }   # state file path for a slug

# ----------------------------------------------------------------------------------------------------------
note "AC1) cold start over the fixture -> state seeded, zero change rows ..."
S1="$WORK/s1"
"$WATCH" --bounties-from "$BJSON" --state-dir "$S1" --probe-cmd "$STUB" >/dev/null 2>"$WORK/err1.txt"
RC=$?
[ "$RC" -eq 0 ] && ok "cold run exits 0" || bad "cold run exited $RC (expected 0)"
COLD_ROWS="$(grep -cv '^#' "$S1/changes.tsv" 2>/dev/null || true)"
[ "$COLD_ROWS" -eq 0 ] && ok "AC1: changes.tsv has 0 data rows on cold start (got $COLD_ROWS)" \
  || bad "AC1 FAILED: cold start emitted $COLD_ROWS row(s), expected 0"
[ -f "$(state_file_of "$S1" alpha)" ] && ok "AC1: alpha state file seeded" || bad "AC1 FAILED: no alpha state file"
[ -f "$(state_file_of "$S1" gamma)" ] && ok "AC1: gamma state file seeded" || bad "AC1 FAILED: no gamma state file"

# AC3 (asserted off the cold run): beta skipped cleanly, delta produced no state file.
[ -e "$(state_file_of "$S1" beta)" ] && bad "AC3 FAILED: beta got a state file despite no repo/address" \
  || ok "AC3: beta (null githubUrl, no address asset) produced no state file"
grep -q "immunefi:beta" "$WORK/err1.txt" && ok "AC3: a [SKIP] note names beta on stderr" \
  || bad "AC3 FAILED: no beta skip note on stderr"
# AC5 setup: delta's two addresses were both skipped -> no delta state file at all.
[ -e "$(state_file_of "$S1" delta)" ] && bad "AC5 FAILED: delta got a state file (all-zero/empty should skip)" \
  || ok "AC5: delta (all-zero + unreachable impl) produced no state file on cold start"

# ----------------------------------------------------------------------------------------------------------
note "AC2) rewind one head entry + one impl entry -> exactly one head row and one impl row ..."
ALPHA_SF="$(state_file_of "$S1" alpha)"
GAMMA_SF="$(state_file_of "$S1" gamma)"
# Capture the baselined (current) values so we can assert the emitted old->new precisely.
# State schema (#2138): kind<TAB>chain<TAB>repo_or_addr<TAB>value — chain is threaded into the key so a
# per-chain baseline is independent (head/tag rows carry chain='-').
NEW_HEAD="$(awk -F'\t' '$1=="head"{print $4; exit}' "$ALPHA_SF")"
NEW_IMPL="$(awk -F'\t' '$1=="impl" && $3=="0x2222222222222222222222222222222222222222"{print $4; exit}' "$GAMMA_SF")"
# Rewind: set the stored value to an OLD one; the STUB still returns the NEW value -> exactly one change each.
awk -F'\t' 'BEGIN{OFS="\t"} $1=="head"{$4="deadbeefoldhead"} {print}' "$ALPHA_SF" > "$ALPHA_SF.tmp" && mv "$ALPHA_SF.tmp" "$ALPHA_SF"
awk -F'\t' 'BEGIN{OFS="\t"} ($1=="impl" && $3=="0x2222222222222222222222222222222222222222"){$4="0x000000000000000000000000oldimploldimploldimploldimploldim"} {print}' \
  "$GAMMA_SF" > "$GAMMA_SF.tmp" && mv "$GAMMA_SF.tmp" "$GAMMA_SF"

"$WATCH" --bounties-from "$BJSON" --state-dir "$S1" --probe-cmd "$STUB" >/dev/null 2>/dev/null
HEAD_ROWS="$(grep -v '^#' "$S1/changes.tsv" | awk -F'\t' '$4=="head"' | grep -c .)"
IMPL_ROWS="$(grep -v '^#' "$S1/changes.tsv" | awk -F'\t' '$4=="impl"' | grep -c .)"
TAG_ROWS="$(grep -v '^#' "$S1/changes.tsv" | awk -F'\t' '$4=="tag"' | grep -c .)"
[ "$HEAD_ROWS" -eq 1 ] && ok "AC2: exactly one head row emitted (got $HEAD_ROWS)" \
  || bad "AC2 FAILED: $HEAD_ROWS head rows, expected 1"
[ "$IMPL_ROWS" -eq 1 ] && ok "AC2: exactly one impl row emitted (got $IMPL_ROWS)" \
  || bad "AC2 FAILED: $IMPL_ROWS impl rows, expected 1"
[ "$TAG_ROWS" -eq 0 ] && ok "AC2: no tag row (the tag set was unchanged)" \
  || bad "AC2 FAILED: $TAG_ROWS tag rows, expected 0 (tag set unchanged)"

# The head row: program alpha, chain '-', repo_or_addr the repo, old->new correct.
HR="$(grep -v '^#' "$S1/changes.tsv" | awk -F'\t' '$4=="head"{print; exit}')"
h_prog="$(printf '%s' "$HR" | cut -f2)"; h_chain="$(printf '%s' "$HR" | cut -f3)"
h_roa="$(printf '%s' "$HR" | cut -f5)"; h_old="$(printf '%s' "$HR" | cut -f6)"; h_new="$(printf '%s' "$HR" | cut -f7)"
[ "$h_prog" = "immunefi:alpha" ] && ok "AC2: head row program = immunefi:alpha" || bad "AC2 FAILED: head program = $h_prog"
[ "$h_chain" = "-" ] && ok "AC2: head row chain = '-' (source change is chain-agnostic)" || bad "AC2 FAILED: head chain = $h_chain (want '-')"
[ "$h_roa" = "https://github.com/example/alpha" ] && ok "AC2: head row repo_or_addr = the repo" || bad "AC2 FAILED: head repo_or_addr = $h_roa"
{ [ "$h_old" = "deadbeefoldhead" ] && [ "$h_new" = "$NEW_HEAD" ]; } \
  && ok "AC2: head old->new = deadbeefoldhead -> $NEW_HEAD" || bad "AC2 FAILED: head old->new = $h_old -> $h_new (want deadbeefoldhead -> $NEW_HEAD)"

# The impl row: program gamma, chain ethereum, repo_or_addr the 0x2222 address, old->new correct.
IR="$(grep -v '^#' "$S1/changes.tsv" | awk -F'\t' '$4=="impl"{print; exit}')"
i_prog="$(printf '%s' "$IR" | cut -f2)"; i_chain="$(printf '%s' "$IR" | cut -f3)"
i_roa="$(printf '%s' "$IR" | cut -f5)"; i_new="$(printf '%s' "$IR" | cut -f7)"
[ "$i_prog" = "immunefi:gamma" ] && ok "AC2: impl row program = immunefi:gamma" || bad "AC2 FAILED: impl program = $i_prog"
[ "$i_chain" = "ethereum" ] && ok "AC2: impl row chain = ethereum (etherscan.io)" || bad "AC2 FAILED: impl chain = $i_chain (want ethereum)"
[ "$i_roa" = "0x2222222222222222222222222222222222222222" ] && ok "AC2: impl row repo_or_addr = the 0x2222 address" || bad "AC2 FAILED: impl repo_or_addr = $i_roa"
[ "$i_new" = "$NEW_IMPL" ] && ok "AC2: impl new value matches the probe read" || bad "AC2 FAILED: impl new = $i_new (want $NEW_IMPL)"

# ----------------------------------------------------------------------------------------------------------
note "AC4) address/chain field-variance (fresh state, rewind ALL gamma impl entries) ..."
S2="$WORK/s2"
"$WATCH" --bounties-from "$BJSON" --state-dir "$S2" --probe-cmd "$STUB" >/dev/null 2>/dev/null   # cold baseline
GAMMA_SF2="$(state_file_of "$S2" gamma)"
# Rewind every gamma impl entry so each address re-emits once with its resolved chain.
awk -F'\t' 'BEGIN{OFS="\t"} $1=="impl"{$4="oldvalue"} {print}' "$GAMMA_SF2" > "$GAMMA_SF2.tmp" && mv "$GAMMA_SF2.tmp" "$GAMMA_SF2"
"$WATCH" --bounties-from "$BJSON" --state-dir "$S2" --probe-cmd "$STUB" >/dev/null 2>/dev/null

chain_of() { grep -v '^#' "$S2/changes.tsv" | awk -F'\t' -v a="$1" '$4=="impl" && $5==a{print $3; exit}'; }
check_chain() {
  got="$(chain_of "$1")"
  [ "$got" = "$2" ] && ok "AC4: $1 -> chain $2" || bad "AC4 FAILED: $1 -> chain '$got' (want $2)"
}
check_chain 0x2222222222222222222222222222222222222222 ethereum
check_chain 0x3333333333333333333333333333333333333333 bsc
check_chain 0x4444444444444444444444444444444444444444 arbitrum
check_chain 0x5555555555555555555555555555555555555555 optimism   # optimistic.etherscan.io, NOT ethereum
check_chain 0x6666666666666666666666666666666666666666 ethereum   # …/address/0x…#code suffix stripped
GAMMA_IMPL_ROWS="$(grep -v '^#' "$S2/changes.tsv" | awk -F'\t' '$4=="impl"' | grep -c .)"
[ "$GAMMA_IMPL_ROWS" -eq 5 ] && ok "AC4: exactly 5 impl rows (the non-address github asset yielded none)" \
  || bad "AC4 FAILED: $GAMMA_IMPL_ROWS impl rows, expected 5 (non-address URL should be skipped)"

# ----------------------------------------------------------------------------------------------------------
note "AC5) all-zero + unreachable impl reads never emit and never baseline ..."
# Across BOTH S1 and S2 runs above, delta never got a state file and never emitted a row.
DELTA_ROWS_S1="$(grep -v '^#' "$S1/changes.tsv" 2>/dev/null | awk -F'\t' '$2=="immunefi:delta"' | grep -c . || true)"
DELTA_ROWS_S2="$(grep -v '^#' "$S2/changes.tsv" 2>/dev/null | awk -F'\t' '$2=="immunefi:delta"' | grep -c . || true)"
{ [ "$DELTA_ROWS_S1" -eq 0 ] && [ "$DELTA_ROWS_S2" -eq 0 ]; } \
  && ok "AC5: delta emitted zero rows across both runs (all-zero + unreachable both skipped)" \
  || bad "AC5 FAILED: delta emitted rows (S1=$DELTA_ROWS_S1 S2=$DELTA_ROWS_S2)"
[ -e "$(state_file_of "$S2" delta)" ] && bad "AC5 FAILED: delta got a state file in S2" \
  || ok "AC5: delta still has no state file (never baselined a transient/non-proxy read)"

# ----------------------------------------------------------------------------------------------------------
note "AC6) #2138 regression: same address 4x on one chain + the same address on a second chain -> cold" \
     "start emits ZERO rows for it, baselined once per (chain,addr) ..."
EPSILON_SF="$(state_file_of "$S1" epsilon)"
EPSILON_ROWS_S1="$(grep -v '^#' "$S1/changes.tsv" | awk -F'\t' '$2=="immunefi:epsilon"' | grep -c . || true)"
[ "$EPSILON_ROWS_S1" -eq 0 ] && ok "AC6: epsilon emitted 0 rows on cold start (got $EPSILON_ROWS_S1)" \
  || bad "AC6 FAILED: epsilon emitted $EPSILON_ROWS_S1 row(s) on cold start, expected 0 (cold-start-zero violated)"
EPSILON_STATE_LINES="$(grep -c . "$EPSILON_SF" 2>/dev/null || echo 0)"
[ "$EPSILON_STATE_LINES" -eq 2 ] && ok "AC6: epsilon has exactly 2 state lines (one per chain, addr deduped 4x->1 per chain)" \
  || bad "AC6 FAILED: epsilon has $EPSILON_STATE_LINES state line(s), expected 2"
grep -q "^impl	ethereum	0x9999999999999999999999999999999999999999	" "$EPSILON_SF" \
  && ok "AC6: epsilon baselined on ethereum" || bad "AC6 FAILED: no ethereum state line for epsilon"
grep -q "^impl	arbitrum	0x9999999999999999999999999999999999999999	" "$EPSILON_SF" \
  && ok "AC6: epsilon baselined on arbitrum (independent of the ethereum baseline)" \
  || bad "AC6 FAILED: no arbitrum state line for epsilon"

note "AC7) rewind ONLY the arbitrum epsilon entry -> exactly one impl row, carrying chain=arbitrum ..."
awk -F'\t' 'BEGIN{OFS="\t"} ($1=="impl" && $2=="arbitrum" && $3=="0x9999999999999999999999999999999999999999"){$4="oldvalue"} {print}' \
  "$EPSILON_SF" > "$EPSILON_SF.tmp" && mv "$EPSILON_SF.tmp" "$EPSILON_SF"
"$WATCH" --bounties-from "$BJSON" --state-dir "$S1" --probe-cmd "$STUB" >/dev/null 2>/dev/null
EPSILON_ROWS_S1B="$(grep -v '^#' "$S1/changes.tsv" | awk -F'\t' '$2=="immunefi:epsilon"' | grep -c . || true)"
[ "$EPSILON_ROWS_S1B" -eq 1 ] && ok "AC7: exactly one epsilon row after the rewind (got $EPSILON_ROWS_S1B)" \
  || bad "AC7 FAILED: $EPSILON_ROWS_S1B epsilon row(s) after rewind, expected 1"
ER="$(grep -v '^#' "$S1/changes.tsv" | awk -F'\t' '$2=="immunefi:epsilon"{print; exit}')"
e_chain="$(printf '%s' "$ER" | cut -f3)"; e_roa="$(printf '%s' "$ER" | cut -f5)"; e_new="$(printf '%s' "$ER" | cut -f7)"
[ "$e_chain" = "arbitrum" ] && ok "AC7: emitted row carries chain=arbitrum (not the ethereum baseline)" \
  || bad "AC7 FAILED: emitted row chain = $e_chain (want arbitrum)"
[ "$e_roa" = "0x9999999999999999999999999999999999999999" ] && ok "AC7: emitted row addr correct" \
  || bad "AC7 FAILED: emitted row addr = $e_roa"
[ "$e_new" = "0x00000000000000000000000000000000000000000000000000000000ab9999" ] && ok "AC7: emitted new value matches the arbitrum probe read" \
  || bad "AC7 FAILED: emitted new = $e_new"

# ----------------------------------------------------------------------------------------------------------
echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: watch-code-changes.sh baselined on cold start (zero rows), then on a rewound state emitted"
  note "      EXACTLY one head + one impl change with correct old->new / chain / repo_or_addr, resolved every"
  note "      explorer domain to the right chain (optimistic.etherscan.io -> optimism, #code stripped, a"
  note "      non-address URL skipped), skipped the no-repo/no-address program cleanly, and never baselined"
  note "      or flapped on an all-zero or unreachable impl read. Offline + deterministic; the real"
  note "      ~/.dark-factory is never touched."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
