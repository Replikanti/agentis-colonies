#!/usr/bin/env bash
# resolve-external.sh — resolve an EXTERNAL protocol symbol to READABLE SOURCE, deterministically and with
# NO LLM anywhere (#2235, PR A of the external-protocol-reading capability).
#
# WHY
#   A discovery cell sees its zone slice plus whatever interfaces the audited repo vendors. Every claim that
#   turns on how an EXTERNAL protocol actually behaves ("that rate is 1e18-scaled", "that wrapper is 1:1")
#   is therefore either confabulated or answered UNRESOLVED. This script is the missing primitive: given a
#   SYMBOL (or an address), it produces a `path:line` a human or a harness can RE-OPEN, so a citation is a
#   fact about a file on disk rather than a name the model remembered.
#
# RESOLUTION ORDER (first hit wins)
#   (a) vendored   — the audited repo's own `lib/`, `node_modules/`, `dependencies/`, `contracts/lib/`,
#                    `src/interfaces/external/` (#2240 — a real held-out base vendors every external
#                    interface there and nothing under `lib/` at all)
#   (b) sourcify   — a deployed address named in the repo's deploy/test/docs (or --address), fetched KEYLESS
#                    from Sourcify (the shipped recon-from-address.sh / run-change-hunts.sh idiom) into the
#                    cache. An ERC-1967 proxy's implementation slot is resolved when an RPC is configured;
#                    without one the proxy address is fetched and the record says `proxy-unresolved`.
#   (c) upstream   — the GitHub repo the audited repo's OWN interface header names (a comment URL, or a
#                    vendored package's `package.json` "repository"), shallow-cloned into the cache.
#   (d) refusal    — one `unresolved` line with a reason from a CLOSED vocabulary.
#
# INPUTS ARE A SYMBOL OR AN ADDRESS — NEVER A URL. There is no flag that takes a host, and anything that
# looks like one fails input validation. Outbound requests are built from FIXED templates against a
# HARD-CODED host allowlist (see ALLOWED_HOSTS below); tools/colony-lint.sh greps this file for any other
# host. Cache-first: a second resolution of the same symbol touches no network at all.
#
# OUTPUT — exactly one line on stdout, nothing else (diagnostics go to stderr):
#   EXTERNAL|<symbol>|<vendored|sourcify|upstream>|<abs-path>:<line>|<sha256-of-file>
#   EXTERNAL|<symbol>|unresolved|<reason>
#   reasons (CLOSED vocabulary):
#     no-vendored-match         the audited repo neither vendors nor MENTIONS the symbol — nothing to go on
#     no-address                the repo mentions it, but ships no deployed address for it and names no
#                               upstream repo either: the identity is known, the deployment is not
#     not-verified-on-sourcify  the address has no verified Sourcify source, or that source lacks the symbol
#     no-upstream-url           the repo NAMES an upstream for it and that upstream still did not declare it
#                               (refused host, or a clone that lacks the declaration)
#     network-unavailable       --offline, a missing python3/git, or a request that did not come back
#     budget-exhausted          --budget-state already spent DF_EXTERNAL_BUDGET network resolutions
#     submodule-empty           a vendored root holds an UNINITIALISED submodule (an empty directory), so
#                               step (a) could not run against the source the repo means to vendor (#2240)
#     bad-input                 the input is not a symbol/address (exit 2; a URL always lands here)
#   When several steps fail, the MOST INFORMATIVE reason is reported (see reason_rank). #2238: a step that
#   was never APPLICABLE never records a reason — the address and upstream steps stay silent about a symbol
#   the repo does not mention at all — so the three "nothing to go on" reasons map 1:1 onto three DISTINCT
#   states of the audited repo instead of collapsing into whichever step happened to run last.
#   <abs-path> is ALWAYS under --repo or under the cache root — the two roots a harness re-opens.
#
# Usage:
#   resolve-external.sh --symbol <Name|Name.function> [--repo <audited root>] [--address 0x..]
#                       [--chain <id>] [--budget-state <file>] [--cache-dir <dir>] [--offline]
#
# Exit: 0 on any resolution OR any refusal (a cell is never derailed); 2 on bad input ONLY.
#
# Offline proof: dark-factory/demo-resolve-external.sh (three fixtures, zero network).
set -uo pipefail

# ----------------------------------------------------------------------------------------------------------
# HOST ALLOWLIST — hard-coded, enforced before every outbound request. tools/colony-lint.sh extracts every
# https?:// and git@ host literal from this file and fails the lint if one is not on this list (#2235 STOP-1
# decision 3b). Widening it is a reviewed edit here, never a runtime/env decision.
# ----------------------------------------------------------------------------------------------------------
ALLOWED_HOSTS='sourcify.dev repo.sourcify.dev github.com raw.githubusercontent.com'

# ERC-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1.
ERC1967_IMPL_SLOT='0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'

# The vendored roots step (a) scans, and the roots a vendored package manifest is looked up under. ONE list,
# used by both, so the two can never drift. #2240: `src/interfaces/external` is here because a real held-out
# base vendors every external protocol interface under `src/interfaces/external/<protocol>/` and has nothing
# usable under `lib/` at all — without it the dominant, free, offline resolution path never fires there.
VENDOR_ROOTS='lib node_modules dependencies contracts/lib src/interfaces/external'

MAX_FILES="${DF_EXTERNAL_MAX_FILES:-4000}"   # per-root scan cap, keeps a huge monorepo bounded
MAX_HEADER_LINES=120                         # how far into a file a "header comment" reaches
BUDGET="${DF_EXTERNAL_BUDGET:-5}"            # NETWORK resolutions allowed against --budget-state

nv() { [ "$1" -ge 2 ] || { echo "resolve-external.sh: $2 requires a value" >&2; exit 2; }; }

SYMBOL="" ; REPO="" ; ADDRESS="" ; CHAIN="1" ; BUDGET_STATE="" ; CACHE_DIR="" ; OFFLINE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --symbol)       nv "$#" "$1"; SYMBOL="$2"; shift 2 ;;
        --repo)         nv "$#" "$1"; REPO="$2"; shift 2 ;;
        --address)      nv "$#" "$1"; ADDRESS="$2"; shift 2 ;;
        --chain)        nv "$#" "$1"; CHAIN="$2"; shift 2 ;;
        --budget-state) nv "$#" "$1"; BUDGET_STATE="$2"; shift 2 ;;
        --cache-dir)    nv "$#" "$1"; CACHE_DIR="$2"; shift 2 ;;
        --offline)      OFFLINE=1; shift ;;
        -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
        *)              echo "resolve-external.sh: unknown arg $1" >&2
                        echo 'EXTERNAL|?|unresolved|bad-input'; exit 2 ;;
    esac
done

# ----------------------------------------------------------------------------------------------------------
# Input validation. A symbol is an identifier (optionally `Name.function`); an address is 40 hex nibbles; a
# chain is a decimal id. Nothing else is accepted — in particular a URL can never validate, because neither
# `:` nor `/` is in the symbol grammar. On refusal the symbol is NOT echoed back (it may be arbitrary bytes),
# so the one stdout line stays inside the grammar.
# ----------------------------------------------------------------------------------------------------------
bad_input() { echo "resolve-external.sh: $1" >&2; echo 'EXTERNAL|?|unresolved|bad-input'; exit 2; }

[ -n "$SYMBOL" ] || bad_input "--symbol <Name|Name.function> is required"
[ "${#SYMBOL}" -le 128 ] || bad_input "--symbol is longer than 128 characters"
echo "$SYMBOL" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$' \
    || bad_input "--symbol '$SYMBOL' is not a Solidity identifier (a URL or a path is never accepted)"
if [ -n "$ADDRESS" ]; then
    echo "$ADDRESS" | grep -qE '^0x[0-9a-fA-F]{40}$' || bad_input "--address must be 0x + 40 hex digits"
fi
echo "$CHAIN" | grep -qE '^[0-9]{1,10}$' || bad_input "--chain must be a decimal chain id"
if [ -n "$REPO" ]; then
    [ -d "$REPO" ] || bad_input "--repo '$REPO' is not a directory"
    REPO="$(cd "$REPO" && pwd)"
fi

NAME="${SYMBOL%%.*}"
FN=""
case "$SYMBOL" in *.*) FN="${SYMBOL#*.}" ;; esac

CACHE="${CACHE_DIR:-${DARK_FACTORY_DIR:-$HOME/.dark-factory}/external}"
mkdir -p "$CACHE" 2>/dev/null || true

# ----------------------------------------------------------------------------------------------------------
# Refusal bookkeeping: each step records why it failed, and only a MORE informative reason may overwrite a
# less informative one, so the emitted refusal does not depend on which step happened to run last.
# ----------------------------------------------------------------------------------------------------------
# #2238: the rank is "how much did this answer actually tell the caller", NOT "which step ran last".
#   1 no-vendored-match  the repo knows nothing about the symbol (the weakest possible answer)
#   2 no-upstream-url    the repo names no upstream for it (it may still know its deployment)
#   3 no-address         the repo mentions it and ships no deployment for it either
#   4 network-unavailable / 5 not-verified-on-sourcify / 6 budget-exhausted — a step that actually RAN
#   7 submodule-empty    the vendored source the repo means to ship is not checked out: actionable, and it
#                        explains why the free, dominant step (a) could not answer at all (#2240)
# The step that got FURTHEST while still failing (an upstream that was named, cloned and lacked the symbol)
# uses set_reason instead, so its outcome is not outranked by a weaker step's bookkeeping.
REASON="no-vendored-match"
reason_rank() {
    case "$1" in
        no-vendored-match)        echo 1 ;;
        no-upstream-url)          echo 2 ;;
        no-address)               echo 3 ;;
        network-unavailable)      echo 4 ;;
        not-verified-on-sourcify) echo 5 ;;
        budget-exhausted)         echo 6 ;;
        submodule-empty)          echo 7 ;;
        *)                        echo 0 ;;
    esac
}
note_reason() {
    if [ "$(reason_rank "$1")" -ge "$(reason_rank "$REASON")" ]; then REASON="$1"; fi
}
# The furthest-progress override: this step did not merely fail to start, it ran to the end and still did not
# produce the declaration. Used ONLY where that is literally true (see the upstream step).
set_reason() { REASON="$1"; }

log() { echo "resolve-external: $*" >&2; }

# sha256 of a file. posix-portability: deferred (guarded pair — sha256sum on GNU, shasum -a 256 on BSD).
file_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

host_of() { # $1=url -> host
    printf '%s' "$1" | sed -e 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' -e 's|^[^@/]*@||' -e 's|[/:].*$||'
}
host_allowed() { # $1=url
    _h="$(host_of "$1")"
    for _a in $ALLOWED_HOSTS; do [ "$_h" = "$_a" ] && return 0; done
    log "host '$_h' is not on the allowlist ($ALLOWED_HOSTS) — refusing the request"
    return 1
}

# ----------------------------------------------------------------------------------------------------------
# Network budget. Only a request that actually leaves the host counts; a vendored hit and a cache hit are
# free. With no --budget-state there is nothing to count ACROSS calls, so a single invocation still spends at
# most BUDGET requests but the cell-level bound is the caller's to pass in.
# ----------------------------------------------------------------------------------------------------------
BUDGET_SPENT=0
budget_used() {
    if [ -n "$BUDGET_STATE" ] && [ -f "$BUDGET_STATE" ]; then
        _u="$(head -n 1 "$BUDGET_STATE" 2>/dev/null | tr -cd '0-9')"
        echo "${_u:-0}"
    else
        echo "$BUDGET_SPENT"
    fi
}
budget_take() { # 0 = a request may be made (and was charged), 1 = exhausted
    _u="$(budget_used)"
    if [ "$_u" -ge "$BUDGET" ]; then note_reason budget-exhausted; return 1; fi
    BUDGET_SPENT=$((_u + 1))
    if [ -n "$BUDGET_STATE" ]; then
        mkdir -p "$(dirname "$BUDGET_STATE")" 2>/dev/null || true
        echo "$BUDGET_SPENT" > "$BUDGET_STATE" 2>/dev/null || true
    fi
    return 0
}

# ----------------------------------------------------------------------------------------------------------
# emit: the ONE stdout line, plus the cache index row a later run (or an auditor) reads back.
# ----------------------------------------------------------------------------------------------------------
emit_hit() { # $1=kind $2=path $3=line
    _sha="$(file_sha "$2")"
    printf 'EXTERNAL|%s|%s|%s:%s|%s\n' "$SYMBOL" "$1" "$2" "$3" "${_sha:-unknown}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$SYMBOL" "$1" "$2" "$3" "${_sha:-unknown}" "$(now_iso)" \
        >> "$CACHE/index.tsv" 2>/dev/null || true
    exit 0
}
emit_unresolved() {
    printf 'EXTERNAL|%s|unresolved|%s\n' "$SYMBOL" "$REASON"
    exit 0
}

# ----------------------------------------------------------------------------------------------------------
# find_decl <root> — first `contract|interface|library|abstract contract <NAME>` under <root> in C-sorted
# file order (so the answer does not depend on readdir order); when the symbol named a function, the line is
# advanced to that function's declaration inside the same file. Prints "<abs-path>\t<line>".
# ----------------------------------------------------------------------------------------------------------
find_decl() {
    fd_root="$1"
    [ -d "$fd_root" ] || return 1
    fd_files="$(find "$fd_root" \( -name .git -o -name out -o -name cache -o -name artifacts \
        -o -name broadcast -o -name coverage \) -prune -o -type f -name '*.sol' -print 2>/dev/null \
        | LC_ALL=C sort | head -n "$MAX_FILES")"
    [ -n "$fd_files" ] || return 1
    fd_decl="^[[:space:]]*(abstract[[:space:]]+contract|contract|interface|library)[[:space:]]+${NAME}([[:space:]]|\{|$)"
    while IFS= read -r fd_f; do
        [ -n "$fd_f" ] || continue
        fd_line="$(grep -nE "$fd_decl" "$fd_f" 2>/dev/null | head -n 1 | cut -d: -f1)"
        [ -n "$fd_line" ] || continue
        if [ -n "$FN" ]; then
            fd_off="$(awk -v s="$fd_line" 'NR>=s' "$fd_f" 2>/dev/null \
                | grep -nE "^[[:space:]]*function[[:space:]]+${FN}[[:space:]]*\(" | head -n 1 | cut -d: -f1)"
            [ -n "$fd_off" ] && fd_line=$((fd_line + fd_off - 1))
        fi
        printf '%s\t%s\n' "$fd_f" "$fd_line"
        return 0
    done <<< "$fd_files"
    return 1
}

naming_files() { # repo .sol files that mention the symbol, C-sorted, capped
    [ -n "$REPO" ] || return 1
    nf_files="$(find "$REPO" \( -name .git -o -name out -o -name cache -o -name artifacts \
        -o -name broadcast -o -name coverage \) -prune -o -type f -name '*.sol' -print 2>/dev/null \
        | LC_ALL=C sort | head -n "$MAX_FILES")"
    [ -n "$nf_files" ] || return 1
    while IFS= read -r nf_f; do
        [ -n "$nf_f" ] || continue
        grep -qE "(^|[^A-Za-z0-9_])${NAME}([^A-Za-z0-9_]|$)" "$nf_f" 2>/dev/null && printf '%s\n' "$nf_f"
    done <<< "$nf_files"
}

# Does the audited repo MENTION the symbol at all? This is the APPLICABILITY precondition of the address and
# upstream steps (#2238): a repo that never names a symbol cannot be missing a deployment or an upstream repo
# FOR it, so those steps must not record a refusal reason about it — before this gate they did, and their
# (higher-ranked) reason buried both `no-vendored-match` and `no-address` in every "found nothing" case.
# Memoised: naming_files walks the repo once, and the upstream step reuses the SAME candidate list.
UP_CANDS=""
NAMED=""
symbol_is_named() {
    if [ -z "$NAMED" ]; then
        UP_CANDS="$(naming_files || true)"
        if [ -n "$UP_CANDS" ]; then NAMED="yes"; else NAMED="no"; fi
    fi
    [ "$NAMED" = "yes" ]
}

# #2240: a vendored root whose direct child contains NO regular file at all. That is exactly what a git
# submodule looks like in a checkout where `git submodule update` never ran — git creates the mount point and
# leaves it empty — and it is the state a real held-out base was measured in (every `lib/<x>` present, all of
# them empty). Answering `no-vendored-match` there blames the resolver's scope for an incomplete checkout, so
# the refusal names the checkout instead. Prints one path per empty child (nothing when there is none).
empty_vendor_dirs() {
    [ -n "$REPO" ] || return 0
    for ev_root in $VENDOR_ROOTS; do
        [ -d "$REPO/$ev_root" ] || continue
        for ev_d in "$REPO/$ev_root"/*; do
            [ -d "$ev_d" ] || continue
            [ -n "$(find "$ev_d" -type f 2>/dev/null | head -n 1)" ] && continue
            printf '%s\n' "$ev_d"
        done
    done
}

# ----------------------------------------------------------------------------------------------------------
# (a) VENDORED — free, offline, and the dominant path in practice (audited repos vendor their deps).
# ----------------------------------------------------------------------------------------------------------
if [ -n "$REPO" ]; then
    # shellcheck disable=SC2086  # VENDOR_ROOTS is a deliberate word-split list of relative roots
    for vroot in $VENDOR_ROOTS; do
        [ -d "$REPO/$vroot" ] || continue
        if hit="$(find_decl "$REPO/$vroot")"; then
            emit_hit vendored "${hit%%	*}" "${hit##*	}"
        fi
    done
fi
note_reason no-vendored-match
# #2240: distinguish "this repo vendors no declaration of the symbol" from "the source it MEANS to vendor is
# not checked out" — the second is actionable (`git submodule update --init --recursive`) and is why step (a)
# could not answer at all, so it outranks every other refusal.
if [ -n "$(empty_vendor_dirs)" ]; then note_reason submodule-empty; fi

# ----------------------------------------------------------------------------------------------------------
# (b) DEPLOYED ADDRESS -> SOURCIFY. The address comes from --address or from the audited repo's own deploy /
# test / docs material — never from the caller's free text.
# ----------------------------------------------------------------------------------------------------------
discover_address() {
    [ -n "$REPO" ] || return 1
    for da_d in script scripts deploy deployments broadcast test tests docs config .; do
        [ -d "$REPO/$da_d" ] || continue
        da_depth=""
        [ "$da_d" = "." ] && da_depth="-maxdepth 1"
        # shellcheck disable=SC2086  # $da_depth is a deliberate 0-or-2-token find option
        da_files="$(find "$REPO/$da_d" $da_depth -name .git -prune -o -type f \
            \( -name '*.sol' -o -name '*.json' -o -name '*.md' -o -name '*.toml' -o -name '*.txt' \) \
            -print 2>/dev/null | LC_ALL=C sort | head -n "$MAX_FILES")"
        [ -n "$da_files" ] || continue
        while IFS= read -r da_f; do
            [ -n "$da_f" ] || continue
            da_a="$(grep -E -A2 "(^|[^A-Za-z0-9_])${NAME}([^A-Za-z0-9_]|$)" "$da_f" 2>/dev/null \
                | grep -oE '0x[0-9a-fA-F]{40}' | head -n 1)"
            if [ -n "$da_a" ]; then printf '%s\n' "$da_a"; return 0; fi
        done <<< "$da_files"
    done
    return 1
}

# The Sourcify FETCH seam. Default: keyless Sourcify v2 `fields=source` over HTTPS, printing the raw JSON
# body on stdout (the recon-from-address.sh idiom). demo-resolve-external.sh replaces it with a fixture
# reader, so the self-test exercises the real UNPACKING code with zero network.
SOURCIFY_URL_TEMPLATE='https://sourcify.dev/server/v2/contract/CHAIN/ADDRESS?fields=source'
DF_SOURCIFY_CMD_DEFAULT='python3 -c "
import os, sys, urllib.request
url = os.environ[\"SOURCIFY_URL\"]
with urllib.request.urlopen(url, timeout=25) as r:
    sys.stdout.write(r.read().decode(\"utf-8\", \"replace\"))
"'

sourcify_fetch() { # $1=chain $2=address $3=dest-dir ; 0 = sources materialized under $3
    sf_chain="$1"; sf_addr="$2"; sf_dest="$3"
    sf_url="$(printf '%s' "$SOURCIFY_URL_TEMPLATE" | sed -e "s/CHAIN/$sf_chain/" -e "s/ADDRESS/$sf_addr/")"
    host_allowed "$sf_url" || { note_reason network-unavailable; return 1; }
    if [ "$OFFLINE" -eq 1 ]; then note_reason network-unavailable; return 1; fi
    budget_take || return 1
    sf_cmd="${DF_SOURCIFY_CMD:-$DF_SOURCIFY_CMD_DEFAULT}"
    sf_body="$(SOURCIFY_URL="$sf_url" SOURCIFY_CHAIN="$sf_chain" SOURCIFY_ADDRESS="$sf_addr" \
        sh -c "$sf_cmd" 2>/dev/null)"
    if [ -z "$sf_body" ]; then note_reason network-unavailable; return 1; fi
    command -v python3 >/dev/null 2>&1 || { note_reason network-unavailable; return 1; }
    mkdir -p "$sf_dest" 2>/dev/null || { note_reason network-unavailable; return 1; }
    # Flatten the v2 `sources` map into real files under $sf_dest (run-change-hunts.sh's unpacking idiom).
    printf '%s' "$sf_body" | SOURCIFY_DEST="$sf_dest" python3 -c '
import json, os, re, sys
dest = os.environ["SOURCIFY_DEST"]
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
srcs = d.get("sources") or {}
n = 0
for path, ent in srcs.items():
    content = ent.get("content") if isinstance(ent, dict) else ent
    if content is None:
        continue
    safe = re.sub(r"[^A-Za-z0-9._/-]", "_", path).lstrip("/")
    safe = "/".join(p for p in safe.split("/") if p not in ("", ".", ".."))
    if not safe:
        continue
    out = os.path.join(dest, safe)
    os.makedirs(os.path.dirname(out) or dest, exist_ok=True)
    with open(out, "w") as f:
        f.write(content)
    n += 1
raise SystemExit(0 if n else 1)
' 2>/dev/null || { note_reason not-verified-on-sourcify; return 1; }
    return 0
}

# ERC-1967 implementation slot. Only attempted when an RPC is configured; the RPC endpoint is an OPERATOR
# value (DF_EXTERNAL_RPC / FORK_URL / ETH_RPC_URL), never a model-supplied one, and it is the only host
# outside the allowlist this script may talk to (STOP-1 decision 3b).
resolve_impl_slot() { # $1=address -> implementation address, or nothing
    ri_rpc="${DF_EXTERNAL_RPC:-${FORK_URL:-${ETH_RPC_URL:-}}}"
    [ -n "$ri_rpc" ] || return 1
    [ "$OFFLINE" -eq 1 ] && return 1
    ri_cmd="${DF_ETH_STORAGE_CMD:-cast rpc --rpc-url \"\$SLOT_RPC\" eth_getStorageAt \"\$SLOT_ADDRESS\" \"\$SLOT_KEY\" latest}"
    ri_word="$(SLOT_RPC="$ri_rpc" SLOT_ADDRESS="$1" SLOT_KEY="$ERC1967_IMPL_SLOT" sh -c "$ri_cmd" 2>/dev/null \
        | tr -cd '0-9a-fA-FxX' | tail -c 66)"
    case "$ri_word" in
        0x*) : ;;
        *) return 1 ;;
    esac
    ri_impl="0x$(printf '%s' "${ri_word#0x}" | tail -c 40)"
    echo "$ri_impl" | grep -qE '^0x[0-9a-fA-F]{40}$' || return 1
    [ "$ri_impl" = "0x0000000000000000000000000000000000000000" ] && return 1
    printf '%s\n' "$ri_impl"
}

ADDR="$ADDRESS"
[ -n "$ADDR" ] || ADDR="$(discover_address || true)"
if [ -z "$ADDR" ]; then
    # #2238: APPLICABILITY — only a repo that mentions the symbol can be missing a deployment FOR it. For a
    # symbol the repo never names, this step answers nothing and stays silent, leaving the true terminal
    # reason (`no-vendored-match`, or `submodule-empty`) standing.
    symbol_is_named && note_reason no-address
else
    ADDR_LC="$(printf '%s' "$ADDR" | tr 'A-F' 'a-f')"
    SRC_DIR="$CACHE/sourcify/$CHAIN/$ADDR_LC/sources"
    META="$CACHE/sourcify/$CHAIN/$ADDR_LC/meta.tsv"
    if [ ! -d "$SRC_DIR" ]; then
        # Cache MISS. Resolve the proxy first so the cached record is the code that actually runs.
        IMPL="$(resolve_impl_slot "$ADDR_LC" || true)"
        FETCH_ADDR="$ADDR_LC"
        PROXY_FIELD="proxy-unresolved"
        if [ -n "$IMPL" ]; then FETCH_ADDR="$IMPL"; PROXY_FIELD="$IMPL"; fi
        if sourcify_fetch "$CHAIN" "$FETCH_ADDR" "$SRC_DIR"; then
            mkdir -p "$(dirname "$META")" 2>/dev/null || true
            {
                printf 'address\t%s\n' "$ADDR_LC"
                printf 'chain\t%s\n' "$CHAIN"
                printf 'proxy\t%s\n' "$PROXY_FIELD"
                printf 'fetched\t%s\n' "$FETCH_ADDR"
                printf 'fetched_at\t%s\n' "$(now_iso)"
            } > "$META" 2>/dev/null || true
        else
            rmdir "$SRC_DIR" 2>/dev/null || true
        fi
    fi
    if [ -d "$SRC_DIR" ]; then
        if hit="$(find_decl "$SRC_DIR")"; then
            emit_hit sourcify "${hit%%	*}" "${hit##*	}"
        fi
        note_reason not-verified-on-sourcify
    fi
fi

# ----------------------------------------------------------------------------------------------------------
# (c) UPSTREAM REPO named by the audited repo ITSELF. Two sources, in order: a github URL in the header
# comments of a repo file that names the symbol, and the "repository" field of a vendored package the same
# file imports. A URL never comes from the caller.
# ----------------------------------------------------------------------------------------------------------
GITHUB_URL_RE='https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+'

upstream_url() {
    uu_cands="$UP_CANDS"          # memoised by symbol_is_named, which gates this whole step
    [ -n "$uu_cands" ] || return 1
    # c1: a github URL inside a comment in the file's header.
    while IFS= read -r uu_f; do
        [ -n "$uu_f" ] || continue
        uu_u="$(head -n "$MAX_HEADER_LINES" "$uu_f" 2>/dev/null | grep -E '^[[:space:]]*(//|/\*|\*)' \
            | grep -oE "$GITHUB_URL_RE" | head -n 1)"
        if [ -n "$uu_u" ]; then printf '%s\n' "${uu_u%.git}"; return 0; fi
    done <<< "$uu_cands"
    # c2: the "repository" of a vendored package the naming file imports (a dep vendored without its source).
    while IFS= read -r uu_f; do
        [ -n "$uu_f" ] || continue
        uu_segs="$(grep -E '^[[:space:]]*import' "$uu_f" 2>/dev/null \
            | grep -oE '"[^"]+"' | tr -d '"' | cut -d/ -f1 | LC_ALL=C sort -u)"
        [ -n "$uu_segs" ] || continue
        while IFS= read -r uu_seg; do
            [ -n "$uu_seg" ] || continue
            # shellcheck disable=SC2086  # same deliberate word-split list step (a) scans
            for uu_root in $VENDOR_ROOTS; do
                uu_pj="$REPO/$uu_root/$uu_seg/package.json"
                [ -f "$uu_pj" ] || continue
                uu_u="$(grep -A3 '"repository"' "$uu_pj" 2>/dev/null | grep -oE "$GITHUB_URL_RE" | head -n 1)"
                if [ -n "$uu_u" ]; then printf '%s\n' "${uu_u%.git}"; return 0; fi
            done
        done <<< "$uu_segs"
    done <<< "$uu_cands"
    return 1
}

DF_GIT_CLONE_CMD_DEFAULT='git clone --depth 1 -q "$CLONE_URL" "$CLONE_DEST"'

UP_URL=""
if symbol_is_named; then UP_URL="$(upstream_url || true)"; fi
if [ -z "$UP_URL" ]; then
    # #2238: same applicability rule as the address step — a symbol the repo never mentions has no upstream
    # for the repo to name, so this step records nothing rather than overwriting the reason that is true.
    symbol_is_named && note_reason no-upstream-url
else
    if host_allowed "$UP_URL"; then
        UP_SLUG="$(printf '%s' "${UP_URL#https://}" | tr -cs 'A-Za-z0-9._/-' '-')"
        UP_DIR="$CACHE/repo/$UP_SLUG@default"
        if [ ! -d "$UP_DIR" ]; then
            if [ "$OFFLINE" -eq 1 ]; then
                note_reason network-unavailable
            elif budget_take; then
                mkdir -p "$(dirname "$UP_DIR")" 2>/dev/null || true
                if ! CLONE_URL="$UP_URL" CLONE_DEST="$UP_DIR" \
                        sh -c "${DF_GIT_CLONE_CMD:-$DF_GIT_CLONE_CMD_DEFAULT}" >/dev/null 2>&1; then
                    rm -rf "$UP_DIR" 2>/dev/null || true
                    note_reason network-unavailable
                fi
            fi
        fi
        if [ -d "$UP_DIR" ]; then
            if hit="$(find_decl "$UP_DIR")"; then
                emit_hit upstream "${hit%%	*}" "${hit##*	}"
            fi
            # FURTHEST PROGRESS (#2238): the upstream was named, cloned and still did not declare the symbol.
            # That is a stronger statement than any earlier step's bookkeeping, so it is set, not ranked.
            set_reason no-upstream-url
        fi
    else
        set_reason no-upstream-url   # the repo names an upstream this script refuses to talk to
    fi
fi

# ----------------------------------------------------------------------------------------------------------
# (d) REFUSAL — deterministic, from the closed vocabulary, exit 0 so a cell is never derailed.
# ----------------------------------------------------------------------------------------------------------
emit_unresolved
