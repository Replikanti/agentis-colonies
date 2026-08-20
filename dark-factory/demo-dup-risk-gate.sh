#!/usr/bin/env bash
# demo-dup-risk-gate.sh — OFFLINE, DETERMINISTIC proof of lib/dup-risk-gate.sh (#1983). No network, no LLM: it
# builds a throwaway git repo with commits at CONTROLLED dates and a fixed --now, and pins the band the
# git-history dup-risk heuristic must emit for each case — the exact signal that would have flagged the TermMax
# C15 finding (Critical, but a 139-day-old duplicate) as HIGH before any effort was spent.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/lib/dup-risk-gate.sh"

FAILS=0
note() { echo "demo-dup-risk-gate.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -f "$GATE" ] || { note "dup-risk-gate.sh not found: $GATE" >&2; exit 3; }
command -v git >/dev/null 2>&1 || { note "git not installed" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-dup-risk-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
R="$WORK/repo"; mkdir -p "$R"
git -C "$R" init -q
git -C "$R" config user.email t@t; git -C "$R" config user.name t

# A pinned reference clock; every commit date + query is relative to it, so the demo is date-independent.
NOW=1800000000
DAY=86400
commit_at() {   # commit_at <days-before-NOW> <file> <content> <msg>
  _ts=$(( NOW - $1 * DAY ))
  printf '%s\n' "$3" > "$R/$2"
  GIT_AUTHOR_DATE="@$_ts +0000" GIT_COMMITTER_DATE="@$_ts +0000" git -C "$R" add -A
  GIT_AUTHOR_DATE="@$_ts +0000" GIT_COMMITTER_DATE="@$_ts +0000" git -C "$R" commit -qm "$4"
}
band() {   # band <args...> -> prints just the band field
  bash "$GATE" --now "$NOW" "$@" 2>/dev/null | cut -d'|' -f2
}

# History: an OLD vulnerable file (200d), and a SEPARATE recently-touched file (5d).
commit_at 200 Router.sol "vulnerable router code" "init v2 router"
commit_at 5   NewFeature.sol "brand new surface" "add new feature"
# HEAD is 5d old (the newest commit); an explicit old ref lets us test a mature target too.
OLD_REF=$(git -C "$R" rev-list --max-parents=0 HEAD)   # the 200d-old root commit

# (1) mature target, old vulnerable file -> HIGH (the C15 shape)
note "1) mature target + long-unchanged vulnerable code -> HIGH (the C15 duplicate shape) ..."
b=$(band --repo "$R" --commit "$OLD_REF" --file Router.sol)
[ "$b" = "HIGH" ] && ok "1) HIGH on a 200d target whose vulnerable Router.sol is 200d unchanged" \
                   || bad "1) expected HIGH, got '$b'"

# (2) fresh target -> LOW (recently launched, likely first)
note "2) freshly-launched target -> LOW ..."
b=$(band --repo "$R" --file NewFeature.sol)   # HEAD (5d old) + a 5d file
[ "$b" = "LOW" ] && ok "2) LOW on a 5d-old target/surface (un-picked-over)" \
                 || bad "2) expected LOW, got '$b'"

# (3) mature target but RECENTLY-introduced vulnerable code -> LOW (fresh code even on an old target)
note "3) old target but freshly-introduced vulnerable code -> LOW ..."
b=$(band --repo "$R" --commit HEAD --file NewFeature.sol)   # target HEAD, file touched 5d ago
[ "$b" = "LOW" ] && ok "3) LOW when the vulnerable code itself is fresh (< fresh-days), even on an older repo" \
                 || bad "3) expected LOW, got '$b'"

# (4) mid-range -> MEDIUM (tuned via flags so the demo is band-boundary explicit)
note "4) mid-range target/code -> MEDIUM ..."
b=$(bash "$GATE" --now "$NOW" --repo "$R" --commit "$OLD_REF" --file Router.sol --fresh-days 30 --mature-days 500 2>/dev/null | cut -d'|' -f2)
[ "$b" = "MEDIUM" ] && ok "4) MEDIUM when the 200d surface is below a 500d maturity bar (verify-before-invest)" \
                    || bad "4) expected MEDIUM, got '$b'"

# (5) machine line shape: DUP-RISK|<band>|<target_age>|<finding_age>|<reason>
note "5) machine-parseable output contract ..."
line=$(bash "$GATE" --now "$NOW" --repo "$R" --commit "$OLD_REF" --file Router.sol 2>/dev/null)
case "$line" in
  DUP-RISK\|HIGH\|200\|200\|*) ok "5) emits DUP-RISK|HIGH|200|200|<reason> (fields: band|target_age|finding_age|reason)" ;;
  *) bad "5) machine line shape wrong: '$line'" ;;
esac

# (6) WIRING: deliver-submission.sh auto-populates manifest.dup_risk from the target's git history when the
# operator passes no --dup-risk. Uses a REAL-now-relative fixture (a commit 200 real-days ago) so the band is
# stable regardless of run date, and a writeup-only draft (no --poc-file) so no gist/network is touched.
DELIVER="$HERE/deliver-submission.sh"
if [ -x "$DELIVER" ]; then
  note "6) deliver-submission.sh records an auto dup-risk band into the manifest (no --dup-risk given) ..."
  RR="$WORK/repo2"; mkdir -p "$RR"
  git -C "$RR" init -q; git -C "$RR" config user.email t@t; git -C "$RR" config user.name t
  _rold=$(( $(date +%s) - 200 * DAY ))            # 200 real-days ago -> HIGH on the default 90d maturity bar
  printf 'vulnerable\n' > "$RR/Router.sol"
  GIT_AUTHOR_DATE="@$_rold +0000" GIT_COMMITTER_DATE="@$_rold +0000" git -C "$RR" add -A
  GIT_AUTHOR_DATE="@$_rold +0000" GIT_COMMITTER_DATE="@$_rold +0000" git -C "$RR" commit -qm init
  _rref=$(git -C "$RR" rev-parse HEAD)
  DROP="$WORK/drop"
  printf '<!-- SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW -->\ntest\n' > "$WORK/draft.md"
  bash "$DELIVER" --id "wiretest@x:y" --draft-file "$WORK/draft.md" --target wiretest --commit "$_rref" \
    --location "Router.sol:fn:1" --target-dir "$RR" --drop-dir "$DROP" >/dev/null 2>&1
  _mf=$(ls "$DROP"/*/manifest.json 2>/dev/null | head -1)
  _band=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('dup_risk',''))" "$_mf" 2>/dev/null)
  [ "$_band" = "HIGH" ] && ok "6) deliver-submission.sh auto-records dup_risk=HIGH for a 200d-unchanged surface (no manual --dup-risk)" \
                        || bad "6) expected manifest dup_risk=HIGH, got '${_band}' (manifest: ${_mf:-none})"
else
  note "6) deliver-submission.sh not found/executable — skipping wiring assertion" >&2
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — dup-risk-gate.sh flags picked-over targets HIGH and fresh ones LOW from git history (#1983)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
