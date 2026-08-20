#!/usr/bin/env bash
# severity-classify.sh --impact "<in-scope impact text>" [--privileged yes|no] [--interaction none|uncommon]
#                      [--platform immunefi]                                                        (#1984)
#
# Maps a finding's SELECTED in-scope impact to the bounty PLATFORM's severity tier, so the report's claimed
# severity always matches the impact the operator picked (and the platform's own scale) instead of a hand-set
# guess. Default platform = Immunefi's 4-tier Smart Contract table:
#   Critical  direct theft of funds (at-rest OR in-motion, NOT unclaimed yield); permanent freezing of funds;
#             protocol insolvency; governance-result manipulation; unauthorized minting; theft/permanent-freeze
#             of NFTs; predictable/manipulable RNG abuse.
#   High      theft of UNCLAIMED yield/royalties; permanent freezing of UNCLAIMED yield/royalties; TEMPORARY
#             freezing of funds/NFTs.
#   Medium    SC unable to operate for lack of funds; block stuffing; griefing (no profit motive); theft of gas;
#             unbounded gas consumption.
#   Low       contract fails to deliver promised returns without losing value.
#
# DOWNGRADE CLAUSE (platform rule): "if the exploit requires elevated privileges or uncommon user interaction the
# level may be downgraded or rejected." --privileged yes OR --interaction uncommon downgrades ONE tier and flags
# it; a permissionless, no-victim-interaction exploit keeps its impact tier (the TermMax C15 case: direct theft
# of funds, permissionless -> Critical, exactly what Immunefi confirmed).
#
# Emits ONE machine-parseable line on stdout + a human summary on stderr:
#   SEVERITY|<Critical|High|Medium|Low>|<matched-rule>|<downgrade-note-or-->
# Exit 0 on a classification; 2 on operator error (missing --impact / bad flag).
set -u

IMPACT="" ; PRIV="no" ; INTER="none" ; PLATFORM="immunefi"
while [ $# -gt 0 ]; do case "$1" in
  --impact)      IMPACT="${2:-}"; shift 2;;
  --privileged)  PRIV="${2:-}"; shift 2;;
  --interaction) INTER="${2:-}"; shift 2;;
  --platform)    PLATFORM="${2:-}"; shift 2;;
  -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) echo "severity-classify.sh: unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$IMPACT" ] || { echo "severity-classify.sh: --impact <text> is required" >&2; exit 2; }
case "$PLATFORM" in immunefi) : ;; *) echo "severity-classify.sh: unsupported --platform: $PLATFORM (only 'immunefi')" >&2; exit 2;; esac

# case-insensitive haystack
_l=$(printf '%s' "$IMPACT" | tr '[:upper:]' '[:lower:]')
has() { case "$_l" in *"$1"*) return 0;; *) return 1;; esac; }

# Order matters: the UNCLAIMED-yield/royalty carve-out (High) must win over the generic theft/freeze-of-funds
# (Critical) match, and TEMPORARY freezing (High) over PERMANENT freezing (Critical). BUT the Critical impact
# text itself reads "...funds ... OTHER THAN unclaimed yield" — so an "other than unclaimed" / "than unclaimed"
# phrasing is a Critical marker, NOT the High unclaimed carve-out; it must not trip the High branch.
band="" ; rule=""
if { has "unclaimed yield" || has "unclaimed royalt" || has "unclaimed"; } && ! has "than unclaimed"; then
  band="High"; rule="theft/permanent-freeze of UNCLAIMED yield/royalties"
elif has "temporary freez" || has "temporarily freez"; then
  band="High"; rule="temporary freezing of funds/NFTs"
elif has "insolven" || has "direct theft" || has "theft of any" || has "theft of user fund" \
     || has "theft of funds" || has "steal" || has "drain" \
     || has "permanent freez" || has "permanently freez" || has "govern" || has "unauthorized mint" \
     || has "unauthorised mint" || { has "theft" && has "fund"; } || { has "theft" && has "nft"; }; then
  band="Critical"; rule="direct theft / permanent freeze of funds/NFTs, insolvency, governance, or unauthorized minting"
elif has "griefing" || has "block stuffing" || has "theft of gas" || has "unbounded gas" \
     || has "unable to operate" || has "lack of token funds" || has "lack of funds"; then
  band="Medium"; rule="griefing / block-stuffing / gas / SC-unable-to-operate"
elif has "fails to deliver" || has "promised return"; then
  band="Low"; rule="fails to deliver promised returns without value loss"
else
  band="Medium"; rule="no clear in-scope impact keyword matched — defaulting to Medium; verify against the program's impact list"
fi

# downgrade clause
_order="Critical High Medium Low"
_next() { case "$1" in Critical) echo High;; High) echo Medium;; Medium) echo Low;; *) echo Low;; esac; }
downgrade="-"
if [ "$PRIV" = "yes" ] || [ "$INTER" = "uncommon" ]; then
  _reason=""
  [ "$PRIV" = "yes" ] && _reason="elevated privileges"
  [ "$INTER" = "uncommon" ] && _reason="${_reason:+$_reason + }uncommon user interaction"
  _lower=$(_next "$band")
  downgrade="downgraded ${band}->${_lower} ($_reason); the program may downgrade further or reject"
  band="$_lower"
fi

echo "SEVERITY|$band|$rule|$downgrade"
echo "severity-classify.sh: $band — $rule${downgrade:+ | $downgrade}" >&2
