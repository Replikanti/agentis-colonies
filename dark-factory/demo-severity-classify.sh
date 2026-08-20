#!/usr/bin/env bash
# demo-severity-classify.sh — OFFLINE, DETERMINISTIC proof of lib/severity-classify.sh (#1984). No network, no
# LLM: it pins the platform impact->tier mapping for each Immunefi Smart Contract band + the downgrade clause,
# and proves deliver-submission.sh records the derived band into the manifest when no --severity is given —
# the exact gap behind the TermMax C15 stage (hand-set `high`; the table yields `Critical`, which Immunefi
# confirmed).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/lib/severity-classify.sh"

FAILS=0
note() { echo "demo-severity-classify.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -f "$S" ] || { note "severity-classify.sh not found: $S" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-severity-classify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

sev() { bash "$S" "$@" 2>/dev/null | cut -d'|' -f2; }

# ---- tier mapping ----------------------------------------------------------------------------------------
note "1) impact->tier mapping (Immunefi Smart Contract table) ..."
while IFS='|' read -r want impact; do
  [ -n "$want" ] || continue
  got=$(sev --impact "$impact")
  [ "$got" = "$want" ] && ok "1) '$want' <- '$impact'" \
                       || bad "1) '$impact' -> got '$got', want '$want'"
done <<'EOF'
Critical|Direct theft of any user funds, whether at-rest or in-motion, other than unclaimed yield
Critical|Theft of user funds from the router, at-rest or in-motion
Critical|Permanent freezing of funds
Critical|Protocol insolvency
High|Theft of unclaimed yield
High|Permanent freezing of unclaimed yield
High|Temporary freezing of funds
Medium|Griefing — no profit motive, damage to the protocol
Medium|Unbounded gas consumption
Low|Contract fails to deliver promised returns, but doesn't lose value
EOF

# ---- the carve-outs that trip a naive matcher ------------------------------------------------------------
note "2) UNCLAIMED-yield beats generic theft-of-funds; TEMPORARY beats PERMANENT freezing ..."
[ "$(sev --impact 'Theft of unclaimed yield')" = "High" ] \
  && ok "2) 'theft of unclaimed yield' -> High (not Critical)" || bad "2) unclaimed-yield carve-out wrong"
[ "$(sev --impact 'Temporary freezing of funds')" = "High" ] \
  && ok "2) 'temporary freezing of funds' -> High (not Critical)" || bad "2) temporary-freeze carve-out wrong"

# ---- downgrade clause ------------------------------------------------------------------------------------
note "3) downgrade clause: elevated privileges / uncommon interaction lowers one tier ..."
[ "$(sev --impact 'Direct theft of funds' --privileged yes)" = "High" ] \
  && ok "3) Critical theft + elevated privileges -> High (downgraded)" || bad "3) privileged downgrade wrong"
[ "$(sev --impact 'Direct theft of funds' --interaction uncommon)" = "High" ] \
  && ok "3) Critical theft + uncommon interaction -> High (downgraded)" || bad "3) interaction downgrade wrong"
[ "$(sev --impact 'Direct theft of funds')" = "Critical" ] \
  && ok "3) permissionless, no-interaction theft keeps Critical (no downgrade — the C15 case)" || bad "3) permissionless should stay Critical"

# ---- machine-line contract -------------------------------------------------------------------------------
note "4) machine-parseable output contract ..."
line=$(bash "$S" --impact 'Direct theft of any user funds' 2>/dev/null)
case "$line" in
  SEVERITY\|Critical\|*\|*) ok "4) emits SEVERITY|<band>|<rule>|<downgrade-note> (Critical for direct theft)" ;;
  *) bad "4) machine line shape wrong: '$line'" ;;
esac

# ---- deliver-submission.sh wiring ------------------------------------------------------------------------
DELIVER="$HERE/deliver-submission.sh"
if [ -x "$DELIVER" ]; then
  note "5) deliver-submission.sh auto-derives the severity band from --impact when no --severity is given ..."
  DROP="$WORK/drop"
  printf '<!-- SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW -->\ntest\n' > "$WORK/draft.md"
  bash "$DELIVER" --id "sevtest@x:y" --draft-file "$WORK/draft.md" --target sevtest \
    --impact "Direct theft of any user funds, at-rest or in-motion" --drop-dir "$DROP" >/dev/null 2>&1
  _mf=$(ls "$DROP"/*/manifest.json 2>/dev/null | head -1)
  _band=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('severity_band',''))" "$_mf" 2>/dev/null)
  [ "$_band" = "Critical" ] && ok "5) manifest severity_band=Critical auto-derived from a theft-of-funds impact (no manual --severity)" \
                            || bad "5) expected manifest severity_band=Critical, got '${_band}' (manifest: ${_mf:-none})"
else
  note "5) deliver-submission.sh not found/executable — skipping wiring assertion" >&2
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — severity-classify.sh maps impact->tier per the platform table (+ downgrade clause), auto-recorded at delivery (#1984)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
