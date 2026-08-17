#!/usr/bin/env bash
# demo-hunt-dashboard-multi.sh — OFFLINE, DETERMINISTIC proof of the #1913 M2 multi-hunt generalization: the
# overview -> detail model over a ${DARK_FACTORY_DIR}/hunts/ descriptor registry, plus the default-safe,
# opt-in, atomic registration hook in run-zone-hunt.sh. No agentis (a trivial `exit 0` substrate stub), no
# LLM, no forge, no network, no server: every assertion drives `hunt-dashboard.py` (registry mode) over a
# checked-in, SCRUBBED zone-hunt-out/ snapshot copied into a mktemp $WORK, and run-zone-hunt.sh over the same
# offline --agentis / --map-fixture seam demo-run-zone-hunt.sh uses.
#
# Assertions:
#   (1) REGISTRY DISCOVERY + OVERVIEW — a registry with 2 descriptors (one finished, one live) yields a
#       2-card overview; the finished card is a static slate (FINISHED, is_live=false) and the live one pulses
#       (LIVE, is_live=true), differentiated by the per-hunt HUNT_DASHBOARD_FAKE_PROC_ALIVE_<ID> seam.
#   (2) DETAIL ROUTING — `--hunt <id>` resolves each hunt to its M1 detail model (correct label + liveness);
#       an unknown id fails cleanly (exit 4).
#   (3) RENDER SMOKE — the overview HTML carries both labels + two `?hunt=` deep-links + a pulse; a detail
#       render carries the `← overview` control (the switcher chrome).
#   (4) EMPTY REGISTRY — a missing registry dir yields a graceful empty overview (count 0, no crash), and the
#       rendered page says so instead of erroring.
#   (5) REGISTRATION HOOK (run-zone-hunt.sh) — with the registry dir ABSENT the launch writes NOTHING and the
#       hunt's OUT artifacts are byte-identical to a run with it PRESENT (the feature is a pure opt-in no-op);
#       with it PRESENT exactly one `<id>.json` is written ATOMICALLY (valid JSON, id/label/root/out/log) and
#       no `.tmp` residue is left behind.
#
# Usage:  dark-factory/demo-hunt-dashboard-multi.sh
# Requires: python3 (the floor) + git (for the run-zone-hunt.sh offline seam). Exit: 0 = all held; non-zero = regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', no process substitution, literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DASH="$HERE/hunt-dashboard/hunt-dashboard.py"
FIX="$HERE/hunt-dashboard/fixtures"
ZONEHUNT="$HERE/run-zone-hunt.sh"
ZM="$HERE/fixtures/zone-map"

FAILS=0
note() { echo "demo-hunt-dashboard-multi.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1     || { echo "[SKIP] git not installed" >&2; exit 0; }
[ -f "$DASH" ] || { note "dashboard not found: $DASH" >&2; exit 3; }
[ -d "$FIX/balancer" ] || { note "fixture not found: $FIX/balancer" >&2; exit 3; }
[ -x "$ZONEHUNT" ] || { note "run-zone-hunt.sh not found / not executable: $ZONEHUNT" >&2; exit 3; }
[ -f "$ZM/zones.fixture.txt" ] || { note "zone-map fixture not found: $ZM/zones.fixture.txt" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-hunt-dashboard-multi.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# Build a fixture registry with two hunts over scrubbed snapshots:
#   vault-finished — the complete balancer snapshot (carries __EXIT__), faked proc-DEAD  -> FINISHED static.
#   vault-live     — the same snapshot with __EXIT__ stripped + a fresh hidden-dir heartbeat, faked proc-ALIVE -> LIVE pulse.
# The per-hunt fake seam (HUNT_DASHBOARD_FAKE_PROC_ALIVE_<ID>) lets ONE overview render carry both states.
# ----------------------------------------------------------------------------------------------------------
REG="$WORK/df/hunts"
mkdir -p "$REG"

FIN="$WORK/finished"; mkdir -p "$FIN"; cp -R "$FIX/balancer/." "$FIN/"
cat > "$REG/finished.json" <<EOF
{ "id": "vault-finished", "label": "Vault (finished)",
  "root": "$FIN", "out": "$FIN/zone-hunt-out", "log": "$FIN/hunt.log",
  "bounty_url": "https://example.invalid/bug-bounty/vault/" }
EOF

LIV="$WORK/live"; mkdir -p "$LIV"; cp -R "$FIX/balancer/." "$LIV/"
grep -v '__EXIT__' "$LIV/hunt.log" > "$LIV/hunt.log.tmp" && mv "$LIV/hunt.log.tmp" "$LIV/hunt.log"
touch "$LIV/zone-hunt-out/briefs/.gen-briefs/run/brief_pkg_vault_contracts.log"
cat > "$REG/live.json" <<EOF
{ "id": "vault-live", "label": "Vault (live)",
  "root": "$LIV", "out": "$LIV/zone-hunt-out", "log": "$LIV/hunt.log" }
EOF

# ----------------------------------------------------------------------------------------------------------
# (1) OVERVIEW — discovery + per-hunt liveness (finished slate vs live pulse) in ONE render.
# ----------------------------------------------------------------------------------------------------------
note "1) registry discovery + overview (finished static slate vs live pulse) ..."
if env HUNT_DASHBOARD_FAKE_PROC_ALIVE_VAULT_FINISHED=0 HUNT_DASHBOARD_FAKE_PROC_ALIVE_VAULT_LIVE=1 \
    python3 "$DASH" --registry-dir "$REG" --emit-model > "$WORK/overview.json" 2>"$WORK/overview.err" \
   && python3 - "$WORK/overview.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
e = []
if m["count"] != 2: e.append("count=%s want 2" % m["count"])
by = {h["id"]: h for h in m["hunts"]}
fin = by.get("vault-finished"); liv = by.get("vault-live")
if not fin or fin["liveness_class"] != "FINISHED" or fin["is_live"] is not False:
    e.append("finished card wrong: %s" % fin)
if not liv or liv["liveness_class"] != "LIVE" or liv["is_live"] is not True:
    e.append("live card wrong: %s" % liv)
# overview cards must carry the live-derived compact summary, not stored state
if fin and not (fin["prog"] == 100.0 and fin["total"] >= 1): e.append("finished prog/total wrong: %s" % fin)
if liv and not (0 <= liv["prog"] <= 100): e.append("live prog out of range: %s" % liv)
# the finished card carries its bounty link through to the overview
if fin and not fin["bounty_url"].startswith("https://"): e.append("finished bounty_url missing: %s" % fin)
if e:
    print("\n".join(e)); sys.exit(1)
PY
then ok "overview lists both hunts; finished = FINISHED static slate (is_live false), live = LIVE pulse (is_live true)"
else bad "overview discovery/liveness model wrong"; sed 's/^/      /' "$WORK/overview.err" | head -3 >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (2) DETAIL ROUTING — each ?hunt=<id> resolves to its M1 detail model; an unknown id fails cleanly.
# ----------------------------------------------------------------------------------------------------------
note "2) detail routing (?hunt=<id> -> the per-hunt M1 dashboard) ..."
env HUNT_DASHBOARD_FAKE_PROC_ALIVE_VAULT_FINISHED=0 \
    python3 "$DASH" --registry-dir "$REG" --hunt vault-finished --emit-model > "$WORK/d_fin.json" 2>/dev/null
env HUNT_DASHBOARD_FAKE_PROC_ALIVE_VAULT_LIVE=1 \
    python3 "$DASH" --registry-dir "$REG" --hunt vault-live --emit-model > "$WORK/d_liv.json" 2>/dev/null
if python3 - "$WORK/d_fin.json" "$WORK/d_liv.json" <<'PY'
import sys, json
fin = json.load(open(sys.argv[1])); liv = json.load(open(sys.argv[2]))
e = []
if fin["label"] != "Vault (finished)": e.append("finished label=%s" % fin["label"])
if fin["liveness"]["class"] != "FINISHED": e.append("finished detail liveness=%s" % fin["liveness"]["class"])
if liv["label"] != "Vault (live)": e.append("live label=%s" % liv["label"])
if liv["liveness"]["class"] != "LIVE": e.append("live detail liveness=%s" % liv["liveness"]["class"])
# the detail model is the full M1 surface (the deep-hunt three-state tag rides along)
if "deep_state" not in fin: e.append("detail model missing deep_state")
if e:
    print("\n".join(e)); sys.exit(1)
PY
then ok "?hunt=vault-finished + ?hunt=vault-live each resolve to the right detail model (label + liveness)"
else bad "detail routing model wrong"
fi
if python3 "$DASH" --registry-dir "$REG" --hunt does-not-exist --emit-model >/dev/null 2>&1; then
  bad "unknown hunt id did not fail"
else
  unk_rc=$?
  if [ "$unk_rc" -eq 4 ]; then ok "an unknown ?hunt=<id> fails cleanly (exit 4), never a stack trace"
  else bad "unknown hunt id exited $unk_rc, want 4"; fi
fi

# ----------------------------------------------------------------------------------------------------------
# (3) RENDER SMOKE — overview HTML carries both cards + deep-links + a pulse; detail carries the ← overview control.
# ----------------------------------------------------------------------------------------------------------
note "3) HTML render smoke (overview grid + detail nav) ..."
if python3 "$DASH" --registry-dir "$REG" --render > "$WORK/overview.html" 2>/dev/null; then
  links="$(grep -o '?hunt=' "$WORK/overview.html" | wc -l | tr -d ' ')"
  if grep -q "Vault (finished)" "$WORK/overview.html" \
     && grep -q "Vault (live)" "$WORK/overview.html" \
     && [ "$links" -ge 2 ] \
     && grep -q 'class="pulse"' "$WORK/overview.html" \
     && grep -q 'meta http-equiv="refresh"' "$WORK/overview.html"; then
    ok "overview HTML carries both labels, >= 2 ?hunt= card deep-links, a pulse dot, and self-refresh"
  else
    bad "overview HTML missing a card / deep-link / pulse (found $links ?hunt= links)"
  fi
else
  bad "overview --render failed"
fi
if python3 "$DASH" --registry-dir "$REG" --hunt vault-finished --render > "$WORK/detail.html" 2>/dev/null; then
  if grep -q "← overview" "$WORK/detail.html" \
     && grep -q "Vault (finished)" "$WORK/detail.html" \
     && grep -q "<td>Type</td><td>Sev</td><td>Class</td><td>Location</td><td>Refute gate</td>" "$WORK/detail.html"; then
    ok "detail HTML is the M1 dashboard + a ← overview switcher control"
  else
    bad "detail HTML missing the ← overview control or the M1 LEADS surface"
  fi
else
  bad "detail --render failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (4) EMPTY REGISTRY — a missing registry dir must render a graceful empty overview, never crash.
# ----------------------------------------------------------------------------------------------------------
note "4) missing registry dir -> graceful empty overview ..."
if python3 "$DASH" --registry-dir "$WORK/no-such-registry" --emit-model > "$WORK/empty.json" 2>/dev/null \
   && python3 - "$WORK/empty.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
assert m["count"] == 0 and m["hunts"] == [], m
PY
then ok "absent registry dir -> count 0, empty hunts list (no crash)"
else bad "empty-registry model wrong"; fi
if python3 "$DASH" --registry-dir "$WORK/no-such-registry" --render 2>/dev/null | grep -q "No active hunts"; then
  ok "absent registry dir -> the overview page says 'No active hunts', not an error"
else
  bad "empty-registry render did not show the empty state"
fi

# ----------------------------------------------------------------------------------------------------------
# (5) REGISTRATION HOOK — run-zone-hunt.sh registers ONLY when the opt-in dir exists, atomically, and the
#     hunt's OUT artifacts are byte-identical whether or not the feature fired (a pure opt-in no-op when off).
# ----------------------------------------------------------------------------------------------------------
note "5) run-zone-hunt.sh registration: opt-in + atomic + byte-identical hunt artifacts when off ..."
RTARGET="$WORK/target"; mkdir -p "$RTARGET/contracts"
printf 'contract V { function f() public {} }\n' > "$RTARGET/contracts/V.sol"
git -C "$RTARGET" init -q
git -C "$RTARGET" config user.email demo@example.invalid
git -C "$RTARGET" config user.name "demo"
git -C "$RTARGET" add -A
git -C "$RTARGET" commit -qm "audited baseline"
STUB="$WORK/agentis-stub"; printf '#!/bin/sh\nexit 0\n' > "$STUB"; chmod +x "$STUB"

# The registration hook writes ONLY to the external registry dir (under DARK_FACTORY_DIR), never into OUT, so
# the RIGHT byte-identity invariant is that the hunt's OUT file SET is untouched by the feature. (A content
# hash of OUT is NOT usable here: zone-coverage.json embeds a wall-clock timestamp, so two independent runs
# differ regardless of this feature — the demo-run-zone-hunt.sh capstone owns the same-seed byte-identity pin.)
tree_files() { ( cd "$1" && find . -type f | LC_ALL=C sort ); }

# (5a) registry dir ABSENT -> no descriptor, clean exit.
OFF_DF="$WORK/off/.dark-factory"; mkdir -p "$OFF_DF"   # the parent exists, but NOT its hunts/ subdir
DARK_FACTORY_DIR="$OFF_DF" "$ZONEHUNT" --repo "$RTARGET" --out "$WORK/out-off" --scope-hint contracts \
  --backend mock --agentis "$STUB" --map-fixture "$ZM/zones.fixture.txt" --brief-fixture "$ZM/briefs.fixture.txt" \
  >"$WORK/zh-off.out" 2>"$WORK/zh-off.err"
OFF_RC=$?
if [ "$OFF_RC" -eq 0 ] && [ ! -e "$OFF_DF/hunts" ]; then
  ok "registry dir absent -> run exits 0 and writes NO descriptor (pure no-op / opt-in off)"
else
  bad "registry-off path wrote something or failed (rc=$OFF_RC, hunts exists: $([ -e "$OFF_DF/hunts" ] && echo yes || echo no))"
  sed 's/^/      /' "$WORK/zh-off.err" | tail -8 >&2
fi

# (5b) registry dir PRESENT -> exactly one atomic descriptor, valid JSON, no .tmp residue.
ON_DF="$WORK/on/.dark-factory"; mkdir -p "$ON_DF/hunts"
DARK_FACTORY_DIR="$ON_DF" "$ZONEHUNT" --repo "$RTARGET" --out "$WORK/out-on" --scope-hint "contracts repo:https://github.com/foo/vault" \
  --backend mock --agentis "$STUB" --map-fixture "$ZM/zones.fixture.txt" --brief-fixture "$ZM/briefs.fixture.txt" \
  >"$WORK/zh-on.out" 2>"$WORK/zh-on.err"
ON_RC=$?
DESC_COUNT="$(find "$ON_DF/hunts" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
TMP_COUNT="$(find "$ON_DF/hunts" -maxdepth 1 -name '.*.tmp.*' | wc -l | tr -d ' ')"
DESC_FILE="$(find "$ON_DF/hunts" -maxdepth 1 -name '*.json' | head -n1)"
if [ "$ON_RC" -eq 0 ] && [ "$DESC_COUNT" = "1" ] && [ "$TMP_COUNT" = "0" ] && [ -n "$DESC_FILE" ] \
   && python3 - "$DESC_FILE" <<'PY'
import sys, json
d = json.load(open(sys.argv[1]))
for k in ("id", "label", "root", "out", "log"):
    assert d.get(k), "descriptor missing %s: %s" % (k, d)
# the repo URL was carried through from the --scope-hint repo:<url> token (zero new plumbing)
assert d.get("repo_url") == "https://github.com/foo/vault", "repo_url not carried from scope_hint: %s" % d
PY
then ok "registry dir present -> exactly ONE atomic descriptor (valid id/label/root/out/log + repo_url from scope_hint), no .tmp residue"
else bad "registry-on registration wrong (rc=$ON_RC, descriptors=$DESC_COUNT, tmp=$TMP_COUNT)"; sed 's/^/      /' "$WORK/zh-on.err" | tail -8 >&2
fi

# (5c) no OUT footprint — the hunt's OUT file set is identical off vs on, and no descriptor leaked into OUT.
if [ -d "$WORK/out-off" ] && [ -d "$WORK/out-on" ]; then
  tree_files "$WORK/out-off" > "$WORK/f-off.txt"
  tree_files "$WORK/out-on"  > "$WORK/f-on.txt"
  leaked="$(find "$WORK/out-on" \( -name '*.json' -path '*hunts*' -o -name '.*.tmp.*' \) 2>/dev/null | wc -l | tr -d ' ')"
  if diff "$WORK/f-off.txt" "$WORK/f-on.txt" >"$WORK/f.diff" 2>&1 && [ "$leaked" = "0" ]; then
    ok "the hunt's OUT file set is IDENTICAL off vs on and no descriptor leaked into OUT (the feature writes only to the external registry)"
  else
    bad "the feature changed the hunt's OUT footprint (file-set diff or leaked descriptor: $leaked):"; sed 's/^/      /' "$WORK/f.diff" | head -12 >&2
  fi
else
  bad "one of the offline runs produced no OUT dir"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #1913 M2 multi-hunt overview->detail model + opt-in atomic registration hold"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
