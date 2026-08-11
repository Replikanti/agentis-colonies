#!/usr/bin/env bash
# demo-refute-feedback.sh — OFFLINE, DETERMINISTIC proof of the #1887 refuter -> hunter CONSTRAINT channel:
# the other half of the loop demo-discovery-parallel.sh block 19 pins. Block 19 drives a STUB `agentis`, so it
# can only prove the SHELL wiring; this file drives the chain end to end —
#
#   refuter reply (CONSTRAINT| + VERDICT|)  ->  run-refute.sh  ->  refute-constraints.tsv
#                                           ->  refute-to-knowledge.sh  ->  corpus JSON
#                                           ->  agentis knowledge import  ->  run-discovery.sh
#                                           ->  a REAL hunter.ag cell whose PROMPT carries the constraint
#
# and it does the last step at OUTPUT level with a real `agentis` interpreting the real `hunter.ag`, because
# an input-level check (config written, env var set) is exactly the trap #1885 closed.
#
# Assertions:
#   1) SCRAPE INVARIANCE (the load-bearing safety property). A refuter reply carrying a `CONSTRAINT|` line
#      IMMEDIATELY BEFORE its `VERDICT|REFUTED|` line produces a refute-report.md that is BYTE-IDENTICAL to
#      the one produced by the same reply WITHOUT that line. The report is what verify-findings.sh scrapes
#      with `awk -F'|'`, so a shifted field there would silently corrupt every verdict + reason downstream.
#   2) HARVEST. The constraint lands in `<out>/refute-constraints.tsv` as `<class>\t<file:fn>\t<sentence>`;
#      a PTY-WRAPPED constraint sentence is rejoined whole (the #1705 defect, on the new line); a REAL
#      verdict harvests nothing; and a candidate the #1699 C6 fallback RECOVERS to REAL harvests nothing
#      either (the gate's own second read overturned the standard the first one applied).
#   3) FEEDER. refute-to-knowledge.sh aggregates duplicate (class, sentence) pairs into one entry with a
#      higher `samples`, sorts deterministically, and produces a corpus that is byte-stable across two runs
#      (modulo the wall-clock `created_ms` stamp, the sibling bench feeder's convention). Empty input is a
#      valid empty corpus at exit 0, and `--store` merges into an accumulating corpus without losing samples.
#   4) LIVE CONSUME (needs the agentis binary; clean [SKIP] otherwise). A real `agentis` runs the real
#      `hunter.ag` against a fake `claude` that DUMPS the prompt (the demo-blackboard.sh / block-18h idiom).
#      ON arm (`REFUTE_CONSTRAINTS_JSON` set): the cell logs `REFUTE-CONSTRAINTS|` and the prompt carries the
#      constraint sentence AND the anti-Goodhart clause. OFF arm: neither appears anywhere, and the cell
#      still produces its `SAFE` sentinel — i.e. the channel is inert by default at OUTPUT level, not just
#      in the config. This is the assertion that fails if the `+ cons` splice is deleted from the prompt.
#   5) READ-ONLY / NEVER-SUBMIT: no network / no submission verb on refute-to-knowledge.sh's exec lines.
#
# Usage:  dark-factory/demo-refute-feedback.sh
# Requires: python3 (the floor); layer 4 additionally needs `agentis`. Exit: 0 = all assertions held.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', no process substitution, literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REFUTE="$HERE/run-refute.sh"
FEEDER="$HERE/refute-to-knowledge.sh"
DISCOVERY="$HERE/run-discovery.sh"
HUNTER_AG="$HERE/auditor/agents/hunter.ag"
REFUTER_AG="$HERE/auditor/agents/refuter.ag"

FAILS=0
note() { echo "demo-refute-feedback.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
for s in "$REFUTE" "$FEEDER" "$DISCOVERY"; do
  [ -x "$s" ] || { note "script not found / not executable: $s" >&2; exit 3; }
done
[ -f "$HUNTER_AG" ] && [ -f "$REFUTER_AG" ] || { note "hunter.ag / refuter.ag missing" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-refute-feedback.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The one sentence the whole chain carries. Deliberately target-INDEPENDENT (no protocol/contract nouns) —
# that is the refuter's contract, and the property that makes a constraint transferable at all.
SENTENCE="an externally-set integration parameter counts as privileged configuration unless the claim names the unprivileged trigger and the concrete divergence it causes"

# ----------------------------------------------------------------------------------------------------------
# (0) SOURCE GUARDS (always, CI-safe): the two halves that cannot be silently inert.
# ----------------------------------------------------------------------------------------------------------
note "0) source guards: the emit contract and the read are both wired ..."
if grep -q 'CONSTRAINT|' "$REFUTER_AG" && grep -q 'IMMEDIATELY BEFORE' "$REFUTER_AG"; then
  ok "refuter.ag's answer contract asks for a CONSTRAINT| line placed BEFORE the verdict (after it, _join_wrapped_verdict would swallow it into the reason)"
else
  bad "refuter.ag no longer asks for a CONSTRAINT| line before the VERDICT| line"
fi
if grep -q 'query_knowledge("refute-constraint"' "$HUNTER_AG" && grep -q '+ cons$' "$HUNTER_AG"; then
  ok "hunter.ag reads the refute-constraint knowledge AND splices the block into its instruction"
else
  bad "hunter.ag's constraint read or its instruction splice is missing — the corpus would be imported and never used"
fi
if grep -q 'knowledge.enabled = true' "$DISCOVERY"; then
  ok "run-discovery.sh writes knowledge.enabled = true (the read hard-errors without it and the cell's stdout is discarded)"
else
  bad "run-discovery.sh does not write knowledge.enabled = true"
fi

# ----------------------------------------------------------------------------------------------------------
# (a) The offline refute stub through the --agentis seam. STUB_MODE selects the reply shape; every shape
#     ends with the SAME VERDICT| line, so any report difference is caused by the constraint line alone.
# ----------------------------------------------------------------------------------------------------------
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    fn="${CAND_FILE_FN:-}"
    cls="${CAND_CLASS:-}"
    # The C6 fallback arm: the assigned class is refuted (with a constraint), the C6 re-read RECOVERS it.
    if [ "$cls" = "C6" ]; then
      echo "VERDICT|REAL|$fn|$cls|recovered under the accounting lens"
      exit 0
    fi
    case "${STUB_MODE:-with}" in
      without)
        # The control: the identical verdict with NO constraint line.
        echo "VERDICT|REFUTED|$fn|$cls|the caller must hold a privileged role for that path"
        ;;
      wrapped)
        # A PTY-wrapped constraint: the sentence continues on lines carrying no CONSTRAINT| prefix.
        echo "CONSTRAINT|$cls|an externally-set integration parameter counts as privileged configuration"
        echo "    unless the claim names the unprivileged trigger and the concrete"
        echo "    divergence it causes"
        echo "VERDICT|REFUTED|$fn|$cls|the caller must hold a privileged role for that path"
        ;;
      real)
        echo "VERDICT|REAL|$fn|$cls|no guard stops the unprivileged caller"
        ;;
      *)
        echo "CONSTRAINT|$cls|${STUB_SENTENCE:-a constraint}"
        echo "VERDICT|REFUTED|$fn|$cls|the caller must hold a privileged role for that path"
        ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

CODEDIR="$WORK/code"; mkdir -p "$CODEDIR"
printf 'contract Adapter { function setParam(uint256 p) external {} }\n' > "$CODEDIR/adapter.sol"
# The C6-fallback fixture: a value-moving function DECLARATION plus an amount-deduction idiom, the
# compound-AND signal run-refute.sh::fallback_class_for requires before it spends a second read.
printf 'contract Gateway { function swap(uint256 amount) public { amount -= fee; } }\n' > "$CODEDIR/gateway.sol"
printf 'Adapter.sol:setParam | C15 | High | anyone can repoint the adapter | adapter.sol\n' > "$WORK/cands.tsv"
printf 'Gateway.sol:swap | C15 | High | the fee is short-deducted before the swap | gateway.sol\n' > "$WORK/cands-fb.tsv"

# ----------------------------------------------------------------------------------------------------------
# (1) SCRAPE INVARIANCE: with vs without the constraint line, the report must not move by one byte.
# ----------------------------------------------------------------------------------------------------------
note "1) the CONSTRAINT| line does not perturb refute-report.md (what verify-findings.sh scrapes) ..."
STUB_SENTENCE="$SENTENCE" STUB_MODE=with "$REFUTE" --candidates "$WORK/cands.tsv" --code-dir "$CODEDIR" \
  --backend mock --agentis "$STUB" --out "$WORK/with" >/dev/null 2>"$WORK/with.err"
RC_WITH=$?
STUB_MODE=without "$REFUTE" --candidates "$WORK/cands.tsv" --code-dir "$CODEDIR" \
  --backend mock --agentis "$STUB" --out "$WORK/without" >/dev/null 2>"$WORK/without.err"
RC_WITHOUT=$?
if [ "$RC_WITH" -eq 0 ] && [ "$RC_WITHOUT" -eq 0 ]; then
  ok "run-refute.sh exits 0 on both the constraint-carrying and the constraint-free reply"
else
  bad "run-refute.sh exited $RC_WITH (with) / $RC_WITHOUT (without)"
  sed 's/^/      /' "$WORK/with.err" >&2
fi
if cmp -s "$WORK/with/refute-report.md" "$WORK/without/refute-report.md"; then
  ok "1) refute-report.md is BYTE-IDENTICAL with and without the constraint line — the verdict + reason verify-findings.sh reads with awk -F'|' cannot shift"
else
  bad "1) the constraint line changed refute-report.md — the downstream awk -F'|' field read is at risk:"
  diff "$WORK/without/refute-report.md" "$WORK/with/refute-report.md" | sed 's/^/      /' >&2
fi
# The scrape itself, run exactly as verify-findings.sh runs it, on both reports.
_scrape() {
  awk -F'|' '
    NF>=5 { v=$4; gsub(/[[:space:]]/,"",v);
      if (v=="REAL"||v=="REFUTED"||v=="ERROR") { r=$5; sub(/^[[:space:]]+/,"",r); sub(/[[:space:]]+$/,"",r);
        print v "\t" r; exit } }
  ' "$1"
}
SC_WITH="$(_scrape "$WORK/with/refute-report.md")"
SC_WITHOUT="$(_scrape "$WORK/without/refute-report.md")"
if [ -n "$SC_WITHOUT" ] && [ "$SC_WITH" = "$SC_WITHOUT" ]; then
  ok "1b) the verify-findings.sh verdict scrape returns the identical '$SC_WITH' from both reports"
else
  bad "1b) the scraped verdict/reason differ: '$SC_WITH' vs '$SC_WITHOUT'"
fi

# ----------------------------------------------------------------------------------------------------------
# (2) HARVEST: the TSV row, the wrapped sentence, the REAL verdict, and the C6-fallback recovery.
# ----------------------------------------------------------------------------------------------------------
note "2) the harvested refute-constraints.tsv ..."
CT="$WORK/with/refute-constraints.tsv"
if [ -f "$CT" ] && [ "$(wc -l < "$CT" | tr -d ' ')" = "1" ] \
   && [ "$(cut -f1 "$CT")" = "C15" ] && [ "$(cut -f2 "$CT")" = "Adapter.sol:setParam" ] \
   && [ "$(cut -f3 "$CT")" = "$SENTENCE" ]; then
  ok "2a) the REFUTED candidate produced exactly one <class>\\t<file:fn>\\t<constraint> row carrying the verbatim sentence"
else
  bad "2a) the harvested row is wrong/missing:"; sed 's/^/      /' "$CT" 2>/dev/null >&2
fi

STUB_MODE=wrapped "$REFUTE" --candidates "$WORK/cands.tsv" --code-dir "$CODEDIR" \
  --backend mock --agentis "$STUB" --out "$WORK/wrapped" >/dev/null 2>&1
WCT="$WORK/wrapped/refute-constraints.tsv"
if [ "$(cut -f3 "$WCT" 2>/dev/null)" = "$SENTENCE" ]; then
  ok "2b) a PTY-WRAPPED constraint sentence is rejoined whole (the #1705 defect, closed on the new line too)"
else
  bad "2b) the wrapped constraint was truncated: '$(cut -f3 "$WCT" 2>/dev/null)'"
fi
if cmp -s "$WORK/wrapped/refute-report.md" "$WORK/without/refute-report.md"; then
  ok "2b2) the wrapped constraint left refute-report.md byte-identical too (its continuation lines never reach the verdict record)"
else
  bad "2b2) the wrapped constraint perturbed refute-report.md:"
  diff "$WORK/without/refute-report.md" "$WORK/wrapped/refute-report.md" | sed 's/^/      /' >&2
fi

STUB_MODE=real "$REFUTE" --candidates "$WORK/cands.tsv" --code-dir "$CODEDIR" \
  --backend mock --agentis "$STUB" --out "$WORK/real" >/dev/null 2>&1
if [ -f "$WORK/real/refute-constraints.tsv" ] && [ ! -s "$WORK/real/refute-constraints.tsv" ]; then
  ok "2c) a REAL verdict harvests NOTHING (the file exists and is empty — an honest empty record, not a missing one)"
else
  bad "2c) a REAL verdict harvested a constraint (or the file was not created)"
fi

STUB_SENTENCE="$SENTENCE" STUB_MODE=with "$REFUTE" --candidates "$WORK/cands-fb.tsv" --code-dir "$CODEDIR" \
  --backend mock --agentis "$STUB" --out "$WORK/fallback" >/dev/null 2>"$WORK/fallback.err"
if grep -q 'retrying under C6' "$WORK/fallback.err" && grep -q '| REAL |' "$WORK/fallback/refute-report.md"; then
  if [ -f "$WORK/fallback/refute-constraints.tsv" ] && [ ! -s "$WORK/fallback/refute-constraints.tsv" ]; then
    ok "2d) a candidate the #1699 C6 fallback RECOVERED to REAL harvests no constraint — the gate's own second read overturned the standard the first applied"
  else
    bad "2d) a C6-recovered candidate still harvested a constraint:"; sed 's/^/      /' "$WORK/fallback/refute-constraints.tsv" >&2
  fi
else
  bad "2d) the C6 fallback fixture did not recover (no retry logged, or the row is not REAL) — the assertion would be vacuous"
fi

# ----------------------------------------------------------------------------------------------------------
# (3) FEEDER: aggregation, determinism, the empty case, and the opt-in --store merge.
# ----------------------------------------------------------------------------------------------------------
note "3) refute-to-knowledge.sh: aggregation, determinism, empty input, --store merge ..."
DUP_TSV="$WORK/dup.tsv"
{
  printf 'C15\tAdapter.sol:setParam\t%s\n' "$SENTENCE"
  printf 'C15\tOther.sol:reconfigure\t%s\n' "$SENTENCE"
  printf 'C6\tGateway.sol:swap\ta short deduction is only a bug when the shortfall is shown to leave the system\n'
} > "$DUP_TSV"
"$FEEDER" --in "$DUP_TSV" --out "$WORK/corpus-1.json" >/dev/null 2>&1
FRC1=$?
"$FEEDER" --in "$DUP_TSV" --out "$WORK/corpus-2.json" >/dev/null 2>&1
FRC2=$?
if [ "$FRC1" -eq 0 ] && [ "$FRC2" -eq 0 ] && python3 - "$WORK/corpus-1.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(d) == 2, "expected 2 aggregated entries, got %d" % len(d)
by = {e["condition"]: e for e in d}
assert by["class C15"]["samples"] == 2, "the duplicate (class, sentence) pair did not aggregate: %r" % by["class C15"]
assert by["class C6"]["samples"] == 1, "the singleton entry is wrong: %r" % by["class C6"]
for e in d:
    assert e["action"] == "refute-constraint", "wrong action: %r" % e["action"]
    assert e["author"] == "refuter", "wrong author: %r" % e["author"]
    assert e["category"] == "constraint", "wrong category: %r" % e["category"]
    assert e["id"].startswith("refute-constraint-"), "wrong id shape: %r" % e["id"]
    assert set(e.keys()) == {"action", "author", "category", "condition", "confidence", "created_ms",
                             "id", "recommendation", "samples", "success_rate", "tags"}, \
        "unexpected key set: %r" % sorted(e.keys())
assert [e["condition"] for e in d] == sorted(e["condition"] for e in d), "entries are not sorted by class"
PY
then ok "3a) duplicate (class, sentence) pairs aggregate into ONE entry with samples=2; the key set + sort order match the bench feeder's conventions"
else bad "3a) the feeder aggregation / schema assertion failed"
fi
# Byte-stability across runs, modulo the wall-clock stamp (the sibling bench feeder emits created_ms the
# same way). Everything a hunter can ever SEE — ids, conditions, sentences, samples, order — must be stable.
grep -v '"created_ms"' "$WORK/corpus-1.json" > "$WORK/corpus-1.norm"
grep -v '"created_ms"' "$WORK/corpus-2.json" > "$WORK/corpus-2.norm"
if cmp -s "$WORK/corpus-1.norm" "$WORK/corpus-2.norm"; then
  ok "3b) two feeder runs over the same input produce a byte-identical corpus (modulo the created_ms wall-clock stamp) — the corpus is reproducible, so an A/B arm is re-derivable"
else
  bad "3b) two feeder runs produced different corpora:"
  diff "$WORK/corpus-1.norm" "$WORK/corpus-2.norm" | sed 's/^/      /' >&2
fi
: > "$WORK/empty.tsv"
"$FEEDER" --in "$WORK/empty.tsv" --out "$WORK/corpus-empty.json" >/dev/null 2>&1
ERC=$?
if [ "$ERC" -eq 0 ] && [ "$(tr -d ' \n' < "$WORK/corpus-empty.json")" = "[]" ]; then
  ok "3c) empty input is a valid EMPTY corpus at exit 0 (data, not an error) — a run in which nothing was refuted stays usable"
else
  bad "3c) empty input did not yield '[]' at exit 0 (exit $ERC, content '$(cat "$WORK/corpus-empty.json" 2>/dev/null)')"
fi
# --store: the opt-in accumulating merge. Two merges of the same run must double the samples, never the rows.
STORE="$WORK/persistent.json"
"$FEEDER" --in "$DUP_TSV" --out "$WORK/corpus-s1.json" --store "$STORE" >/dev/null 2>&1
"$FEEDER" --in "$DUP_TSV" --out "$WORK/corpus-s2.json" --store "$STORE" >/dev/null 2>&1
if python3 - "$STORE" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(d) == 2, "the merge duplicated rows instead of summing samples: %d entries" % len(d)
by = {e["condition"]: e for e in d}
assert by["class C15"]["samples"] == 4, "samples did not accumulate across merges: %r" % by["class C15"]
assert by["class C6"]["samples"] == 2, "samples did not accumulate across merges: %r" % by["class C6"]
PY
then ok "3d) the opt-in --store merge accumulates samples into a stable row set (default OFF; the bench arm never uses it — a frozen corpus is what keeps a measurement re-derivable)"
else bad "3d) the --store merge lost or duplicated rows"
fi

# ----------------------------------------------------------------------------------------------------------
# (4) LIVE CONSUME: a REAL agentis interpreting the REAL hunter.ag, ON vs OFF, asserted on the PROMPT.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "4) live hunter consume — no agentis binary on PATH"
else
  note "4) live: a real hunter.ag cell with and without the corpus (prompt-level, the #1885 lesson) ..."
  LREPO="$WORK/live-target"; mkdir -p "$LREPO/contracts/vault"
  printf 'contract Vault { function deposit() public {} }\n' > "$LREPO/contracts/vault/Vault.sol"
  printf 'vault deposits | C15 | contracts/vault/Vault.sol\n' > "$WORK/live-scope.tsv"
  printf '# brief\nInvariants to break: share accounting.\nKnown issues to exclude: none.\n' > "$WORK/live-brief.md"
  LIVE_BIN="$WORK/live-bin"; mkdir -p "$LIVE_BIN"
  LIVE_PROMPTS="$WORK/live-prompts"; rm -rf "$LIVE_PROMPTS"; mkdir -p "$LIVE_PROMPTS"
  # The fake LLM: dump the prompt (instruction + payload, on stdin) and answer the sentinel the cell needs.
  cat > "$LIVE_BIN/claude" <<EOF
#!/usr/bin/env bash
set -eu
PROMPT="\$(cat)"
printf '%s' "\$PROMPT" > "$LIVE_PROMPTS/prompt.\$\$"
echo SAFE
exit 0
EOF
  chmod +x "$LIVE_BIN/claude"

  # The corpus the ON arm imports: one C15 constraint (the cell's class) + one C6 constraint that must NOT
  # leak into a C15 cell's prompt — the class filter is part of what is being proven.
  LIVE_TSV="$WORK/live-constraints.tsv"
  {
    printf 'C15\tAdapter.sol:setParam\t%s\n' "$SENTENCE"
    printf 'C6\tGateway.sol:swap\tOTHERCLASSSENTINEL a short deduction must be shown to leave the system\n'
  } > "$LIVE_TSV"
  "$FEEDER" --in "$LIVE_TSV" --out "$WORK/live-corpus.json" >/dev/null 2>&1

  # --- OFF arm: no corpus. --backend claude is REQUIRED: it is the backend that honours llm.command.
  OFF_OUT="$WORK/live-off"
  PATH="$LIVE_BIN:$PATH" "$DISCOVERY" --repo "$LREPO" --scope "$WORK/live-scope.tsv" \
    --brief "$WORK/live-brief.md" --backend claude --out "$OFF_OUT" --jobs 1 \
    >/dev/null 2>"$WORK/live-off.err"
  OFF_RC=$?
  OFF_PROMPTS="$WORK/off-prompts"; rm -rf "$OFF_PROMPTS"; mv "$LIVE_PROMPTS" "$OFF_PROMPTS"; mkdir -p "$LIVE_PROMPTS"

  # --- ON arm: the same run with the corpus exported.
  ON_OUT="$WORK/live-on"
  REFUTE_CONSTRAINTS_JSON="$WORK/live-corpus.json" PATH="$LIVE_BIN:$PATH" \
    "$DISCOVERY" --repo "$LREPO" --scope "$WORK/live-scope.tsv" --brief "$WORK/live-brief.md" \
    --backend claude --out "$ON_OUT" --jobs 1 >/dev/null 2>"$WORK/live-on.err"
  ON_RC=$?
  ON_PROMPTS="$WORK/on-prompts"; rm -rf "$ON_PROMPTS"; mv "$LIVE_PROMPTS" "$ON_PROMPTS"

  if [ "$OFF_RC" -ne 0 ] || [ "$ON_RC" -ne 0 ]; then
    bad "4) a live arm exited non-zero (off $OFF_RC / on $ON_RC)"
    tail -20 "$WORK/live-on.err" | sed 's/^/      /' >&2
  else
    ok "4) both live arms exit 0 (a real agentis interpreting the real hunter.ag)"
  fi

  # OFF arm: the SAFE sentinel proves the cell really ran; the absence proves the default is inert at
  # OUTPUT level, not merely unconfigured.
  if grep -rq '^SAFE' "$OFF_OUT"/run/hunt_*.log 2>/dev/null; then
    ok "4a) the OFF cell produced its SAFE sentinel — the positive control (without it 4b would pass vacuously)"
  else
    bad "4a) the OFF cell produced no SAFE sentinel — the cell never really ran"
  fi
  if grep -rq 'REFUTE-CONSTRAINTS|' "$OFF_OUT"/run/hunt_*.log 2>/dev/null \
     || grep -rql "$SENTENCE" "$OFF_PROMPTS" 2>/dev/null; then
    bad "4b) the OFF arm carries the sentinel or the constraint text — the channel is NOT inert by default"
  else
    ok "4b) with no corpus the OFF cell logs no REFUTE-CONSTRAINTS| sentinel and its prompt carries no constraint text"
  fi

  # ON arm: the sentinel AND the text in the prompt. The prompt check is the one that fails if the `+ cons`
  # splice is deleted while the sentinel print survives (or vice versa).
  if grep -rq 'REFUTE-CONSTRAINTS|vault deposits|C15|1' "$ON_OUT"/run/hunt_*.log 2>/dev/null; then
    ok "4c) the ON cell logs REFUTE-CONSTRAINTS|<subsystem>|<class>|<n> with the class-filtered count"
  else
    bad "4c) the ON cell logged no REFUTE-CONSTRAINTS| sentinel with the expected fields"
  fi
  if python3 - "$ON_PROMPTS" "$SENTENCE" <<'PY'
import sys, os

pdir, sentence = sys.argv[1], sys.argv[2]
prompts = []
for n in sorted(os.listdir(pdir)):
    with open(os.path.join(pdir, n), encoding="utf-8", errors="replace") as fh:
        prompts.append(fh.read())
assert len(prompts) == 1, "expected exactly one dumped prompt, got %d" % len(prompts)
p = prompts[0]
assert sentence in p, "the constraint sentence never reached the model"
assert "WHAT AN INDEPENDENT SKEPTIC REJECTED" in p, "the constraint block header never reached the model"
# The anti-Goodhart clause is load-bearing: a hunter told what the gate rejects can learn to produce
# gate-PLEASING claims, and the metric this channel is judged on is ground-truth rare recall.
assert "NEVER weaken, re-frame or invent a claim to satisfy the gate" in p, \
    "the anti-Goodhart clause is missing from the block"
# The class filter: a C6 constraint must not appear in a C15 cell's prompt.
assert "OTHERCLASSSENTINEL" not in p, "a constraint filed under a DIFFERENT class leaked into this cell"
PY
  then ok "4d) the ON cell's PROMPT carries the constraint sentence, the block header and the anti-Goodhart clause, and NO other class's constraint (the class filter holds)"
  else bad "4d) the constraint block did not reach the live hunter's prompt (or leaked another class)"
  fi
  if grep -rq '^SAFE' "$ON_OUT"/run/hunt_*.log 2>/dev/null; then
    ok "4e) the ON cell still produces its SAFE sentinel — the extra block does not break the reply contract"
  else
    bad "4e) the ON cell lost its SAFE sentinel"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# (5) READ-ONLY / NEVER-SUBMIT posture of the new feeder.
# ----------------------------------------------------------------------------------------------------------
note "5) read-only / never-submit posture ..."
if grep -vE '^[[:space:]]*#' "$FEEDER" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "refute-to-knowledge.sh invokes a network/submission verb on an executable line"
else
  ok "refute-to-knowledge.sh has no network / no submission verb on any executable line"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #1887 refuter -> hunter constraint channel holds end to end (emit -> scrape -> feed -> import -> consume)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed (see #1887)" >&2
exit 1
