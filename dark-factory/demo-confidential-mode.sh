#!/usr/bin/env bash
# demo-confidential-mode.sh — OFFLINE, DETERMINISTIC proof of confidential mode (#2327, epic #2317 M1): task code and
# its derivatives never reach a learning, export or host-state sink outside the task and run dirs.
#
# Setup: a fake HOME (.claude/, .claude.json, a DARK_FACTORY_DIR with hunts/, a hunted-targets ledger and an existing
# pattern store), stub `curl` and `gh` on PATH that log their argv and bodies to an egress log OUTSIDE HOME, a raw
# example DARK_FACTORY_SLACK_WEBHOOK, GH_TOKEN set, and an --agentis stub (one zone, one CONFIRMED finding) that also
# logs TMPDIR / DF_CONFIDENTIAL / DF_EXTERNAL_CACHE / CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC.
#
#   1. lib/confidential.py --self-test and lib/confidential.sh --self-test.
#   2. SET BY THE INTAKE: run-agentarena-intake.sh (offline hatch) leaves DF-CONFIDENTIAL in the task dir.
#   3. CONFIDENTIAL RUN: run-zone-hunt.sh over <task>/repo into <task>/hunt WITHOUT --confidential (the marker is
#      enough): exit 0, `[confidential] on`, the marker in <out> and <out>/verify, the pinned env, one reduced
#      webhook body per staged finding (exactly the allowed keys, no title); then refute-to-knowledge.sh,
#      bench-to-knowledge.sh (on a `cp -R` copy of <out>), state-export.sh export and ingest-slack-outcome.sh --stage
#      each exit 4; the fake HOME snapshot (task dir excluded) is IDENTICAL before and after.
#   4. CONTROL: the same run and feeders on an unmarked copy — the registry file appears, the webhook carries
#      submission_id / target / draft_path, the feeders write into HOME, ingest exits 0, and the snapshot compare lists
#      exactly those sink paths (the check can see every sink it guards).
#   5. deliver-submission.sh with --poc-file and the bot env: `gh gist create` and chat.postMessage appear only for the
#      unmarked drop dir.
#   6. REFUSALS (HOME unchanged): --confidential --pattern-store -> 2 (and the same argv without the switch runs),
#      run-invariant-hunt.sh --pattern-store over the task repo -> 2, --backend claude -> 2, DF_NO_SANDBOX=1
#      --backend flat-cyborg -> 3, --drop-dir $DARK_FACTORY_DIR/drop -> 2, DF_EXTERNAL_CACHE outside -> 2,
#      DF_CONFIDENTIAL=yes -> 2, a live STAGE 5 -> stage5=skipped-confidential.
#   7. INVENTORY: docs/confidential-sinks.tsv schema; every row's probe exercised above (or `[SKIP] live` for the
#      PR 2 rows); ratchets (no `cross-fed:` key in a dark-factory .ag; only lib/confidential.sh calls the helper's
#      marker-check subcommand directly); drift guard (every hunt-tree script that touches DARK_FACTORY_DIR or $HOME is
#      named in a writer cell, and every direct run-zone-hunt.sh child is on the hunt-tree list).
#
# No network, no LLM, no agentis: bash, python3 and git only.
#
# Usage:  dark-factory/demo-confidential-mode.sh
# Requires: bash + python3 + git. Exit: 0 = all assertions held; non-zero = a regression.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ZONEHUNT="$HERE/run-zone-hunt.sh"
INTAKE="$HERE/run-agentarena-intake.sh"
CONFPY="$HERE/lib/confidential.py"
CONFSH="$HERE/lib/confidential.sh"
TSV="$HERE/docs/confidential-sinks.tsv"
FIXTURE_DIR="$HERE/fixtures/zone-map"
ZONES_FIXTURE="$FIXTURE_DIR/zones.fixture.txt"
BRIEFS_FIXTURE="$FIXTURE_DIR/briefs.fixture.txt"
PASS_FIXTURE="scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted"

FAILS=0
note() { echo "demo-confidential-mode.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
is()   { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; } # <got> <want> <label>

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
for f in "$ZONEHUNT" "$INTAKE" "$CONFPY" "$CONFSH" "$TSV" "$ZONES_FIXTURE" "$BRIEFS_FIXTURE"; do
  [ -f "$f" ] || { note "required file missing: $f" >&2; exit 3; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-confidential.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"
EXERCISED="$WORK/exercised.txt"; : > "$EXERCISED"
# exercised <row-id>... — record that an inventory row's probe ran and held (section 7 checks the coverage).
exercised() { for _e in "$@"; do printf '%s\n' "$_e" >> "$EXERCISED"; done; }

# ---------------------------------------------------------------------------------------------------------------
# Setup: fake HOME, stubs, env.
# ---------------------------------------------------------------------------------------------------------------
FH="$WORK/home"
DF="$FH/.dark-factory"
mkdir -p "$FH/.claude/projects" "$DF/hunts" "$DF/patterns/.agentis/memo" "$DF/agentarena/inbox"
printf '%s\n' '{"projects":{}}' > "$FH/.claude.json"
printf '%s\n' 'immunefi:demo	2026-01-01	clean' > "$DF/hunted-targets.tsv"
printf '%s\n' 'pattern' > "$DF/patterns/.agentis/memo/invpat:latest:C1"
chmod 700 "$DF/agentarena" "$DF/agentarena/inbox"
STUBBIN="$WORK/bin"; mkdir -p "$STUBBIN"
EGRESS="$WORK/egress.jsonl"; : > "$EGRESS"
ENVLOG="$WORK/env.log"; : > "$ENVLOG"

cat > "$STUBBIN/curl" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
argv = sys.argv[1:]
body = ""
for i, a in enumerate(argv):
    if a in ("-d", "--data", "--data-binary", "--data-raw") and i + 1 < len(argv):
        body = argv[i + 1]
with open(os.environ["DEMO_EGRESS"], "a") as f:
    f.write(json.dumps({"tool": "curl", "argv": argv, "body": body}) + "\n")
reply = json.dumps({"ok": True, "ts": "1.0", "channel": "C0DEMO", "upload_url": "https://upload.example.invalid/u",
                    "file_id": "F1", "files": [{"id": "F1"}]})
if "-o" in argv and "/dev/null" in argv:
    sys.stdout.write("200")
elif "-w" in argv:
    sys.stdout.write(reply + "\n200")
else:
    sys.stdout.write(reply)
EOF
cat > "$STUBBIN/gh" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
argv = sys.argv[1:]
with open(os.environ["DEMO_EGRESS"], "a") as f:
    f.write(json.dumps({"tool": "gh", "argv": argv, "body": ""}) + "\n")
if argv[:2] == ["gist", "create"]:
    print("https://gist.example.invalid/demo")
EOF
chmod +x "$STUBBIN/curl" "$STUBBIN/gh"

# The --agentis stub (cut down from demo-run-zone-hunt.sh): one zone (vault deposits / C1) answers one candidate,
# the refuter keeps it, the coordinator drafts. Every `go` logs the confidential-mode env.
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"
sub="${2:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  memo)
    if [ "$sub" = "get" ] && [ "${3:-}" = "coordinator:pass_result" ] && [ -f .agentis/pass_result ]; then
      cat .agentis/pass_result
    fi
    exit 0 ;;
  go)
    {
      echo "TMPDIR=${TMPDIR:-}"
      echo "DF_CONFIDENTIAL=${DF_CONFIDENTIAL:-}"
      echo "DF_EXTERNAL_CACHE=${DF_EXTERNAL_CACHE:-}"
      echo "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}"
    } >> "$DEMO_ENVLOG"
    case "$sub" in
      hunter.ag)
        if [ -n "${DEPTH_TARGET:-}" ]; then echo "SAFE"; exit 0; fi
        if [ "${SUBSYSTEM:-}" = "vault deposits" ] && [ "${HUNT_CLASS:-}" = "C1" ]; then
          echo "CANDIDATE|contracts/vault/Vault.sol:deposit:10|C1|High|external depositor mints free shares|donate an asset to inflate the share price"
        else
          echo "SAFE"
        fi
        exit 0 ;;
      refuter.ag)
        echo "VERDICT|REAL|${CAND_FILE_FN:-}|${CAND_CLASS:-}|survived a hostile read"
        exit 0 ;;
      coordinator.ag)
        out="${SUBMISSION_DRAFT_OUT:-}"
        if [ -n "$out" ]; then
          {
            echo "SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW"
            echo "FIELD|title|Vault.deposit share inflation at ${FINDING_LOCATION:-}"
            echo "FIELD|severity|${SEVERITY_BAND:-}"
            echo ""
            echo "A human reviews this draft and files it manually."
          } > "$out"
        fi
        printf '%s' "PENDING-HUMAN-REVIEW" > .agentis/pass_result
        echo "PASS|PENDING-HUMAN-REVIEW"
        exit 0 ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

export HOME="$FH"
export DARK_FACTORY_DIR="$DF"
export PATH="$STUBBIN:$PATH"
export DEMO_EGRESS="$EGRESS" DEMO_ENVLOG="$ENVLOG"
export DARK_FACTORY_SLACK_WEBHOOK="https://hooks.example.invalid/services/T0/B0/demo"
export GH_TOKEN="demo-token-not-real"
export MONITOR_NOTIFY_MAX_RETRIES=0 MONITOR_NOTIFY_BACKOFF_S=0
unset DF_CONFIDENTIAL DF_EXTERNAL_CACHE DF_NO_SANDBOX DARK_FACTORY_SLACK_BOT_TOKEN DARK_FACTORY_SLACK_CHANNEL \
      MONITOR_WEBHOOK_URL MONITOR_SLACK_BOT_TOKEN MONITOR_SLACK_CHANNEL CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC

snap() { python3 -I "$CONFPY" snapshot "$FH" --exclude "$TASK" > "$1"; }
# egress_since <line-count> — the egress log entries appended after that line.
egress_since() { tail -n +"$(($1 + 1))" "$EGRESS"; }
lines() { wc -l < "$1" | tr -d ' '; }
hunt() { # hunt <repo> <out> [extra args...] — the offline run-zone-hunt.sh invocation every section reuses.
  _r="$1"; _o="$2"; shift 2
  bash "$ZONEHUNT" --repo "$_r" --out "$_o" --scope-hint contracts --backend mock --agentis "$STUB" \
    --map-fixture "$ZONES_FIXTURE" --brief-fixture "$BRIEFS_FIXTURE" --in-scope "the whole program" "$@"
}

# ---------------------------------------------------------------------------------------------------------------
note "1) helper self-tests ..."
if python3 -I "$CONFPY" --self-test >"$WORK/st.py.out" 2>&1; then ok "lib/confidential.py --self-test"; else bad "lib/confidential.py --self-test"; cat "$WORK/st.py.out"; fi
if bash "$CONFSH" --self-test >"$WORK/st.sh.out" 2>&1; then ok "lib/confidential.sh --self-test"; else bad "lib/confidential.sh --self-test"; cat "$WORK/st.sh.out"; fi

# ---------------------------------------------------------------------------------------------------------------
note "2) the intake marks the task dir ..."
TASK="$DF/agentarena/t-demo"
mkdir -p "$WORK/fx/src/proj"
cp -R "$FIXTURE_DIR/contracts" "$WORK/fx/src/proj/contracts"
rm -rf "$WORK/fx/src/proj/contracts/registry"
python3 -I - "$WORK/fx/src" "$WORK/fx/t-demo.zip" <<'EOF'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w") as z:
    for dp, dirs, files in os.walk(src):
        dirs.sort()
        for n in sorted(files):
            p = os.path.join(dp, n)
            z.write(p, os.path.relpath(p, src))
EOF
printf '%s\n' '{"id":"t-demo","selectedFiles":["contracts/vault/Vault.sol"]}' > "$WORK/fx/t-demo.details.json"
printf '{"post_findings_url":"https://agentarena.nethermind.io/f","task_details_url":"https://agentarena.nethermind.io/d","task_id":"t-demo","task_repository_url":"https://agentarena.nethermind.io/r"}\n' \
  > "$DF/agentarena/inbox/t-demo.json"
env -u AGENTARENA_API_KEY bash "$INTAKE" --task t-demo --details-file "$WORK/fx/t-demo.details.json" \
  --zip-file "$WORK/fx/t-demo.zip" >/dev/null 2>"$WORK/intake.err"; rc=$?
is "$rc" 0 "intake (offline hatch) -> exit 0"
if [ -f "$TASK/DF-CONFIDENTIAL" ] && [ -f "$TASK/repo/contracts/vault/Vault.sol" ]; then
  ok "the task dir carries DF-CONFIDENTIAL and the unpacked repo"
else
  bad "task dir marker or repo missing"; cat "$WORK/intake.err"
fi

# ---------------------------------------------------------------------------------------------------------------
note "3) a hunt over the task dir is confidential without the flag ..."
OUT="$TASK/hunt"
snap "$WORK/home.before"
E0="$(lines "$EGRESS")"
hunt "$TASK/repo" "$OUT" --pass-fixture "$PASS_FIXTURE" >"$WORK/conf.out" 2>"$WORK/conf.err"; rc=$?
is "$rc" 0 "confidential run -> exit 0"
if grep -q "\[confidential\] on (marker $TASK/DF-CONFIDENTIAL)" "$WORK/conf.err"; then
  ok "the run announces '[confidential] on' naming the task marker"
else
  bad "no '[confidential] on (marker <task>/DF-CONFIDENTIAL)' line"; tail -30 "$WORK/conf.err"
fi
if [ -f "$OUT/DF-CONFIDENTIAL" ] && [ -f "$OUT/verify/DF-CONFIDENTIAL" ]; then ok "the marker is in <out> and <out>/verify"; else bad "marker missing in <out> or <out>/verify"; fi
for want in "TMPDIR=$OUT/.tmp" "DF_CONFIDENTIAL=1" "DF_EXTERNAL_CACHE=$OUT/external-cache" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"; do
  if grep -qxF "$want" "$ENVLOG" && [ "$(sort -u "$ENVLOG" | grep -c "^${want%%=*}=")" -eq 1 ]; then
    ok "every substrate call saw $want"
  else
    bad "substrate env: $want not seen on every call"
  fi
done
exercised tmp external-cache claude-nonessential
if grep -q '\[registry\] confidential hunt' "$WORK/conf.err" && [ -z "$(ls -A "$DF/hunts")" ]; then
  ok "not registered on the hunt dashboard"; exercised hunt-registry
else
  bad "a confidential hunt was registered"
fi
STAGED="$(find "$OUT/drop" -mindepth 1 -maxdepth 1 -type d | head -1)"
if [ -n "$STAGED" ] && [ -f "$STAGED/submission-draft.md" ]; then ok "the finding was staged inside the task dir"; else bad "no staged finding under <out>/drop"; fi
egress_since "$E0" > "$WORK/conf.egress"
if python3 -I - "$WORK/conf.egress" "$OUT" <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
hooks = [r for r in rows if r["tool"] == "curl" and "hooks.example.invalid" in " ".join(r["argv"])]
assert len(hooks) == 1, "want 1 webhook call, got %d (all egress: %r)" % (len(hooks), rows)
assert len(rows) == 1, "unexpected egress: %r" % rows
alert = json.loads(json.loads(hooks[0]["body"])["content"])
assert set(alert) == {"kind", "verdict", "severity", "severity_band", "ref", "confidential", "message"}, sorted(alert)
assert alert["ref"] == sys.argv[2] and alert["confidential"] is True and alert["severity"] == "high", alert
assert "Vault" not in hooks[0]["body"] and "deposit" not in hooks[0]["body"], "a finding title or location leaked"
EOF
then ok "one webhook body, exactly the allowed keys, ref = the run's marked root, no title/location"; exercised slack-webhook
else bad "the confidential webhook body is not the reduced alert"
fi
# The feeders refuse the run's outputs.
python3 -I - "$OUT/verify/refute-constraints.tsv" <<'EOF'
import os, sys
p = sys.argv[1]
if not os.path.exists(p):
    open(p, "w").write("C1\tcontracts/vault/Vault.sol:deposit\tthe donation is accounted before minting\n")
EOF
bash "$HERE/refute-to-knowledge.sh" --from-verify "$OUT/verify" --out "$FH/r2k.json" >/dev/null 2>"$WORK/r2k.err"; rc=$?
is "$rc" 4 "refute-to-knowledge.sh --from-verify <out>/verify -> exit 4"
cp -R "$OUT/verify" "$WORK/verify-copy"
bash "$HERE/refute-to-knowledge.sh" --from-verify "$WORK/verify-copy" --out "$FH/r2k.json" >/dev/null 2>&1; rc=$?
is "$rc" 4 "refute-to-knowledge.sh on a copy of verify/ alone -> exit 4 (the verify/ marker travels)"
mkdir -p "$WORK/bench-work/c1"
cp -R "$OUT" "$WORK/bench-work/c1/zone-hunt-out"
bash "$HERE/bench/corpus-bench/bench-to-knowledge.sh" --work "$WORK/bench-work" --out "$FH/hf.json" >/dev/null 2>&1; rc=$?
is "$rc" 4 "bench-to-knowledge.sh on a cp -R copy of <out> -> exit 4"
mkdir -p "$OUT/state-rd/.agentis/memo"; printf '%s\n' learned > "$OUT/state-rd/.agentis/memo/k1"
bash "$HERE/state-export.sh" export "$OUT/state-rd" "$FH/state.tgz" >/dev/null 2>&1; rc=$?
is "$rc" 4 "state-export.sh export of a rundir under <out> -> exit 4"
DARK_FACTORY_SLACK_BOT_TOKEN=xoxb-demo bash "$HERE/ingest-slack-outcome.sh" --stage "$STAGED" >/dev/null 2>&1; rc=$?
is "$rc" 4 "ingest-slack-outcome.sh --stage <a staged task finding> -> exit 4"
[ ! -e "$FH/r2k.json" ] && [ ! -e "$FH/hf.json" ] && [ ! -e "$FH/state.tgz" ] \
  && { ok "no feeder wrote its output"; exercised refute-constraints hunt-fitness state-export outcome-learning; } \
  || bad "a feeder wrote its output despite the refusal"
snap "$WORK/home.after"
if python3 -I "$CONFPY" compare "$WORK/home.before" "$WORK/home.after" > "$WORK/conf.diff"; then
  ok "the fake HOME (task dir excluded) is IDENTICAL after the run and the four feeders"; exercised hunted-targets
else
  bad "the confidential run changed the fake HOME:"; sed 's/^/      /' "$WORK/conf.diff"
fi
if [ "$(lines "$EGRESS")" -eq "$((E0 + 1))" ]; then ok "no egress beyond the one reduced webhook call"; else bad "unexpected egress after the run"; egress_since "$E0"; fi

# ---------------------------------------------------------------------------------------------------------------
note "4) control: the same run without the switch ..."
CTRL="$WORK/ctrl"
mkdir -p "$CTRL"
cp -R "$TASK/repo" "$CTRL/repo"
rm -f "$CTRL/repo/DF-CONFIDENTIAL"
snap "$WORK/ctrl.before"
E0="$(lines "$EGRESS")"
hunt "$CTRL/repo" "$CTRL/hunt" --pass-fixture "$PASS_FIXTURE" --drop-dir "$DF/drop" >"$WORK/ctrl.out" 2>"$WORK/ctrl.err"; rc=$?
is "$rc" 0 "control run -> exit 0"
if grep -q '\[confidential\]' "$WORK/ctrl.err" || [ -e "$CTRL/hunt/DF-CONFIDENTIAL" ]; then bad "the control run went confidential"; else ok "the control run prints no [confidential] line and writes no marker"; fi
if python3 -I - "$EGRESS" "$E0" <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]).read().splitlines()[int(sys.argv[2]):] if l.strip()]
hooks = [r for r in rows if r["tool"] == "curl" and "hooks.example.invalid" in " ".join(r["argv"])]
assert len(hooks) == 1, rows
alert = json.loads(json.loads(hooks[0]["body"])["content"])
assert {"submission_id", "target", "draft_path"} <= set(alert), sorted(alert)
EOF
then ok "the control webhook carries submission_id, target and draft_path"
else bad "the control webhook body lacks the full alert"
fi
python3 -I - "$CTRL/hunt/verify/refute-constraints.tsv" <<'EOF'
import os, sys
p = sys.argv[1]
if not os.path.exists(p):
    open(p, "w").write("C1\tcontracts/vault/Vault.sol:deposit\tthe donation is accounted before minting\n")
EOF
bash "$HERE/refute-to-knowledge.sh" --from-verify "$CTRL/hunt/verify" --out "$FH/r2k.json" >/dev/null 2>&1; r1=$?
mkdir -p "$WORK/ctrl-bench/c1"; cp -R "$CTRL/hunt" "$WORK/ctrl-bench/c1/zone-hunt-out"
bash "$HERE/bench/corpus-bench/bench-to-knowledge.sh" --work "$WORK/ctrl-bench" --out "$FH/hf.json" >/dev/null 2>&1; r2=$?
mkdir -p "$CTRL/hunt/state-rd/.agentis/memo"; printf '%s\n' learned > "$CTRL/hunt/state-rd/.agentis/memo/k1"
bash "$HERE/state-export.sh" export "$CTRL/hunt/state-rd" "$FH/state.tgz" >/dev/null 2>&1; r3=$?
CSTAGED="$(find "$DF/drop" -mindepth 1 -maxdepth 1 -type d | head -1)"
bash "$HERE/ingest-slack-outcome.sh" --stage "$CSTAGED" >/dev/null 2>&1; r4=$?
is "$r1 $r2 $r3 $r4" "0 0 0 0" "control feeders: refute-to-knowledge, bench-to-knowledge, state-export -> 0; ingest -> 0 (its no-token no-op)"
snap "$WORK/ctrl.after"
python3 -I "$CONFPY" compare "$WORK/ctrl.before" "$WORK/ctrl.after" > "$WORK/ctrl.diff"
SLUG="${CSTAGED##*/}"
printf '%s\n' "+ .dark-factory/drop" "+ .dark-factory/drop/$SLUG" "+ .dark-factory/drop/$SLUG/OUTCOME.md" \
  "+ .dark-factory/drop/$SLUG/manifest.json" "+ .dark-factory/drop/$SLUG/submission-draft.md" \
  "+ .dark-factory/hunts/repo.json" "+ hf.json" "+ r2k.json" "+ state.tgz" | LC_ALL=C sort > "$WORK/ctrl.want"
LC_ALL=C sort "$WORK/ctrl.diff" > "$WORK/ctrl.got"
if cmp -s "$WORK/ctrl.got" "$WORK/ctrl.want"; then
  ok "the control compare lists exactly the sink paths (registry, shared drop, three feeder outputs)"
  exercised shared-drop
else
  bad "the control compare is not the expected sink set:"; diff "$WORK/ctrl.want" "$WORK/ctrl.got" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------------------------------------------
note "5) deliver-submission.sh with a PoC and the bot env ..."
printf 'SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW\nFIELD|title|Vault.deposit share inflation\n' > "$WORK/draft.md"
printf 'contract PocTest {}\n' > "$WORK/Poc_demo.t.sol"
deliver() { # deliver <drop-dir> — one direct stage with a PoC, the bot env set.
  DARK_FACTORY_SLACK_BOT_TOKEN=xoxb-demo DARK_FACTORY_SLACK_CHANNEL=C0DEMO \
    bash "$HERE/deliver-submission.sh" --id "demo@abc:poc" --draft-file "$WORK/draft.md" --severity High \
    --poc-file "$WORK/Poc_demo.t.sol" --drop-dir "$1" >/dev/null 2>&1
}
E0="$(lines "$EGRESS")"
deliver "$TASK/direct-drop"; rc=$?
egress_since "$E0" > "$WORK/d.marked"
is "$rc" 0 "deliver into a marked drop dir -> exit 0"
if ! grep -q '"gist", "create"' "$WORK/d.marked" && ! grep -q 'chat.postMessage' "$WORK/d.marked" \
   && [ ! -e "$TASK/direct-drop/demo@abc-poc/poc/GIST_README.md" ] && [ ! -e "$TASK/direct-drop/demo@abc-poc/poc/GIST_COMMAND.txt" ] \
   && grep -q '"gist_url": "disabled:confidential"' "$TASK/direct-drop/demo@abc-poc/manifest.json"; then
  ok "marked drop dir: no gh gist create, no chat.postMessage, no gist files, gist_url disabled:confidential"
  exercised gist slack-bot
else
  bad "marked drop dir: a gist or bot call happened"; cat "$WORK/d.marked"
fi
E0="$(lines "$EGRESS")"
deliver "$WORK/plain-drop"; rc=$?
egress_since "$E0" > "$WORK/d.plain"
if [ "$rc" -eq 0 ] && grep -q '"gist", "create"' "$WORK/d.plain" && grep -q 'chat.postMessage' "$WORK/d.plain"; then
  ok "unmarked drop dir: gh gist create and chat.postMessage both happen (the stubs can see both)"
else
  bad "unmarked drop dir: expected a gist and a bot post"; cat "$WORK/d.plain"
fi

# ---------------------------------------------------------------------------------------------------------------
note "6) refusals (the fake HOME stays unchanged) ..."
snap "$WORK/ref.before"
refused() { # refused <want-rc> <label> <cmd...> — the run exits <want-rc> and says why.
  _want="$1"; _label="$2"; shift 2
  "$@" >"$WORK/ref.out" 2>"$WORK/ref.err"; _rc=$?
  if [ "$_rc" -eq "$_want" ] && grep -qi 'confidential' "$WORK/ref.err"; then ok "$_label -> exit $_want"; return 0; fi
  bad "$_label (got exit $_rc, want $_want)"; tail -5 "$WORK/ref.err" | sed 's/^/      /'; return 1
}
r_ps=0
refused 2 "--confidential --pattern-store on an unmarked --out" hunt "$CTRL/repo" "$WORK/adhoc" --confidential --pattern-store "$DF/patterns" --pass-fixture "$PASS_FIXTURE" || r_ps=1
refused 2 "run-invariant-hunt.sh --pattern-store over the task repo" bash "$HERE/run-invariant-hunt.sh" --repo "$TASK/repo" --target contracts/vault/Vault.sol --pattern-store "$DF/patterns" --out "$TASK/inv" || r_ps=1
r_cl=0
refused 2 "--backend claude on the task" bash "$ZONEHUNT" --repo "$TASK/repo" --out "$TASK/hunt-r" --backend claude || r_cl=1
refused 3 "DF_NO_SANDBOX=1 --backend flat-cyborg on the task" env DF_NO_SANDBOX=1 bash "$ZONEHUNT" --repo "$TASK/repo" --out "$TASK/hunt-r" --backend flat-cyborg || r_cl=1
[ "$r_cl" -eq 0 ] && exercised unsandboxed-claude
refused 2 "--drop-dir \$DARK_FACTORY_DIR/drop on the task" hunt "$TASK/repo" "$TASK/hunt-r" --drop-dir "$DF/drop" && exercised shared-drop
refused 2 "DF_EXTERNAL_CACHE outside the task" env DF_EXTERNAL_CACHE="$DF/external" bash "$ZONEHUNT" --repo "$TASK/repo" --out "$TASK/hunt-r" --backend mock || true
refused 2 "DF_CONFIDENTIAL=yes" env DF_CONFIDENTIAL=yes bash "$ZONEHUNT" --repo "$CTRL/repo" --out "$WORK/adhoc2" --backend mock || true
hunt "$TASK/repo" "$TASK/hunt-live" >"$WORK/live.out" 2>"$WORK/live.err"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'stage5=skipped-confidential' "$WORK/live.err" && [ ! -d "$TASK/hunt-live/audit-pass" ]; then
  ok "a live STAGE 5 is skipped (stage5=skipped-confidential, exit 0, no audit-pass/)"; exercised stage5-unsandboxed
else
  bad "a live STAGE 5 was not skipped (exit $rc)"; tail -5 "$WORK/live.err" | sed 's/^/      /'
fi
snap "$WORK/ref.after"
if python3 -I "$CONFPY" compare "$WORK/ref.before" "$WORK/ref.after" > "$WORK/ref.diff"; then
  ok "the fake HOME is unchanged across every refusal and the skipped STAGE 5"
else
  bad "a refusal changed the fake HOME:"; sed 's/^/      /' "$WORK/ref.diff"; r_ps=1
fi
# The same argv without the switch is not refused (outside the snapshot window: it registers on the dashboard).
hunt "$CTRL/repo" "$WORK/adhoc" --pattern-store "$DF/patterns" --pass-fixture "$PASS_FIXTURE" >/dev/null 2>"$WORK/adhoc.err"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q '\[confidential\]' "$WORK/adhoc.err"; then ok "the same --pattern-store argv without --confidential runs (exit 0)"; else bad "the non-confidential --pattern-store run failed (exit $rc)"; r_ps=1; fi
[ "$r_ps" -eq 0 ] && exercised pattern-dag

# ---------------------------------------------------------------------------------------------------------------
note "7) the sink inventory ..."
if python3 -I - "$TSV" <<'EOF'
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
assert rows[0] == ["id", "kind", "location", "writer", "guard", "probe"], rows[0]
body = rows[1:]
assert all(len(r) == 6 and all(c.strip() for c in r) for r in body), "a row without 6 non-empty columns"
ids = [r[0] for r in body]
assert len(ids) == len(set(ids)), "duplicate ids"
kinds = {"learn", "export", "egress", "registry", "host-state", "cache", "transient"}
probes = {"snapshot", "stub", "feeder", "refuse", "env", "static", "live", "none"}
assert all(r[1] in kinds for r in body), [r[:2] for r in body if r[1] not in kinds]
assert all(r[5] in probes for r in body), [(r[0], r[5]) for r in body if r[5] not in probes]
EOF
then ok "docs/confidential-sinks.tsv: header, 6 columns, unique ids, kind/probe from the closed vocabularies"
else bad "docs/confidential-sinks.tsv schema"
fi
# Ratchet: no dark-factory .ag writes a cross-fed: memo key (the cross-fed-memo row's static probe).
if grep -rl --include='*.ag' 'cross-fed:' "$HERE" >/dev/null 2>&1; then
  bad "a dark-factory .ag references a cross-fed: key"; grep -rl --include='*.ag' 'cross-fed:' "$HERE" | sed 's/^/      /'
else
  ok "ratchet: no dark-factory .ag references a cross-fed: key"; exercised cross-fed-memo
fi
# Ratchet: only lib/confidential.sh calls the helper's subcommand directly (the pattern is split so this file
# does not match itself).
SUBCMD="is-""confidential"
DIRECT="$(grep -rl --include='*.sh' -e "$SUBCMD" "$HERE" "$HERE/../tools" 2>/dev/null | grep -v '/lib/confidential\.sh$' || true)"
if [ -z "$DIRECT" ]; then ok "ratchet: no bash file but lib/confidential.sh calls $SUBCMD directly"; else bad "direct $SUBCMD callers: $DIRECT"; fi
# Every row's probe was exercised above, or is a PR 2 live probe.
while IFS='	' read -r rid _k _l _w _g probe; do
  [ "$rid" = "id" ] && continue
  case "$probe" in
    none) ;;
    live) echo "  [SKIP] live: $rid (#2331, demo-claude-sandboxed.sh)" ;;
    *) if grep -qxF "$rid" "$EXERCISED"; then ok "inventory row '$rid' ($probe) exercised"; else bad "inventory row '$rid' ($probe) was not exercised"; fi ;;
  esac
done < "$TSV"
# Drift guard: the hunt tree (run-zone-hunt.sh and its children). Every direct child must be on this list, and
# every listed script that touches DARK_FACTORY_DIR or $HOME on an executable line must be named in a writer cell.
HUNT_TREE="run-zone-hunt.sh map-zones.sh gen-briefs.sh run-discovery.sh verify-findings.sh run-audit-pass.sh
deliver-submission.sh finding-payability-gate.sh run-invariant-hunt.sh run-vector-hunt.sh deep-hunt-gate.sh
run-refute.sh run-poc.sh run-symbolic.sh notify-submission.sh render-run-evidence.sh resolve-external.sh
onchain-fact.sh audit-delta.sh detect-core-dep.sh monitor/scripts/notify.sh auditor/scripts/run-gate-agent.sh
auditor/slice-fns.sh evm-harness/forge-poc.sh evm-harness/forge-invariant.sh evm-harness/hardhat-poc.sh
evm-harness/halmos-verify.sh evm-harness/detect-toolchain.sh evm-harness/mutant-kill.sh
evm-harness/extract-solidity-symbols.sh lib/cell-watchdog.sh lib/deep-hunt-cell.sh lib/deep-hunt-sched.sh
lib/foundry-shim.sh lib/forge-slot.sh lib/flat-cyborg-env.sh lib/run-agent-validated.sh lib/ensure-claude-trust.sh
lib/claude-sandboxed.sh lib/dup-risk-gate.sh lib/severity-classify.sh lib/confidential.sh lib/impact-lens.py
lib/inheritance.py lib/lens-surface-matrix.py lib/project_roots.py lib/zone-coverage.py lib/foundry_shim.py
lib/claude-json-scope.py lib/cluster-findings.py lib/refute-batch.py lib/scope-assumptions.py lib/usage_limit.py
lib/composition-surfaces.py lib/confidential.py"
drift=0
for child in $(grep -oE '\$HERE/[A-Za-z0-9_./-]+\.(sh|py)' "$ZONEHUNT" | sed 's|^\$HERE/||' | sort -u); do
  case " $(printf '%s' "$HUNT_TREE" | tr '\n' ' ') " in
    *" $child "*) ;;
    *) bad "drift: run-zone-hunt.sh child $child is not on the hunt-tree list"; drift=1 ;;
  esac
done
WRITERS="$(cut -f4 "$TSV")"
for s in $HUNT_TREE; do
  [ -f "$HERE/$s" ] || { bad "drift: hunt-tree script $s does not exist"; drift=1; continue; }
  if grep -v '^[[:space:]]*#' "$HERE/$s" | grep -qE 'DARK_FACTORY_DIR|\$HOME|\$\{HOME'; then
    case "$WRITERS" in
      *"$s"*) ;;
      *) bad "drift: $s touches DARK_FACTORY_DIR/\$HOME but no inventory writer cell names it"; drift=1 ;;
    esac
  fi
done
[ "$drift" -eq 0 ] && ok "drift guard: every direct child is listed; every hunt-tree script touching DARK_FACTORY_DIR/\$HOME is in the inventory"

if [ "$FAILS" -eq 0 ]; then
  note "PASS"
  exit 0
fi
note "FAIL ($FAILS)"
exit 1
