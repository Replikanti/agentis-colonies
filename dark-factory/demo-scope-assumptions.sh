#!/usr/bin/env bash
# demo-scope-assumptions.sh — the gate for #2257: SCOPE-AWARE REFUTE (declared trust / token assumptions, the
# `out-of-scope-premise` ground, default OFF).
#
# What the change is. A refute gate that never sees what a target DECLARES out of scope cannot reject a finding
# whose exploit only works with an excluded asset or environment. So:
#   * lib/scope-assumptions.py `extract` turns the target's own scope docs (SCOPE.md, README.md, or an
#     operator-curated scope-assumptions.md) into a short, deterministic, line-cited block
#     `A<n>|<category>|<source>:<first>[-<last>]|<text>`;
#   * refuter.ag shows that block inside a SEVERITY_RUBRIC=1 prompt only, with ONE extra sufficient ground,
#     `out-of-scope-premise`, whose evidence is `A<n>:"<quote of that row>" premise:"<quote of the claim>"`;
#   * run-refute.sh checks that contract through `scope-assumptions.py check` (the same helper that wrote the
#     block): a pass routes the candidate into out-of-scope.tsv — verdict still REFUTED, reason prefixed, no C6
#     re-read, no constraint harvest; a failure rides the existing bounded re-ask + rubric-dismissals.tsv;
#   * verify-findings.sh --scope-docs <auto|file> builds the block once and surfaces routed candidates in a new
#     `out_of_scope[]` array of verified_findings.json, never in verified[]; run-zone-hunt.sh forwards the flag.
# Trust rows are CONTEXT ONLY (never citable); v1 covers STAGE 4 first-pass findings only. Unset = byte-identical.
#
# #2292 — A ROW NEVER NAMES A SOURCE FILE. A contest README handed to the operator parser used to mint one row per
# line of its in-scope FILE LIST (mostly `exclusion`, `trust` / `token` when a path held `keeper/` or `tokens/`),
# and the refuter then dismissed real findings in exactly the files under review. Three independent layers, each
# pinned below with its own mutant: (1) the operator parser skips a bullet naming a source file BEFORE it picks a
# category and has no `exclusion` fallback (an unclassified bullet is dropped and counted on stderr); (2) the
# decider's sixth contract, `scope-cite-in-scope-file`, refuses an `exclusion` row naming a file of the zone map
# (`--scope-map`); (3) `auto` reads a parent-directory scope doc that is BOUND to the repo (lists a source file
# under the repo's own directory name) — the contest layout — so nobody needs the operator parser for a README.
#
# Seven parts. Parts a-f are the CI floor (no agentis, no forge, no network, no LLM):
#   a) EXTRACTOR — byte-exact goldens for four doc shapes + the operator file, run twice (determinism); every
#      emitted citation range contains its row's text; nothing-declared = 0 bytes; the operator file REPLACES
#      auto; the 40-row / 300-character caps; `|` sanitising; the file-table / code-fence exclusions; and the
#      #2292 contest layout in BOTH modes (no source-file row, nothing from the file list, the stderr count line,
#      the bound / unbound parent doc).
#   b) DECIDER — one pass case and one fixture per contract id; a PTY-wrap-split quote still resolves; a quote
#      taken from one row but cited under another id fails; an exclusion row naming a mapped file (--scope-map).
#   c) SOURCE GUARDS — the marker is the directive's first line; "" with the rubric off or no block; exactly one
#      splice, in the discovery-lead branch, before its TIE-BREAK; the honesty-gated sentinel; the passthrough +
#      cell env + three scraper boundaries; the byte-paired functions and the closed ground list untouched; no
#      iteration-5 token on the refute side; pure-meta directive text (+ negative control); substrate purity.
#   d) run-refute.sh END TO END through an offline --agentis stub — the ACCEPTANCE case (a transfer-fee premise
#      against a "standard tokens only" declaration), the in-scope control, a fabricated id (held + recovered),
#      a trust citation, a PTY-wrapped ground line, the no-block and knob-OFF controls.
#   e) verify-findings.sh END TO END — out_of_scope[] vs verified[], the NEGATIVE CONTROL (no declaration => the
#      same candidate stays verified), knob-OFF byte-identity, --jobs 2 parity, scope-without-rubric inertness.
#   f) MUTATION RESISTANCE — nine mutated copies (premise check dropped, id resolution dropped, trust citable,
#      out-of-scope routed into verified[], C6 skip removed; #2292: the `exclusion` fallback restored, the
#      operator source-file skip dropped, the scope-map contract dropped, the parent binding dropped); each must
#      flip its fixture.
#   g) LIVE UNDER MOCK ([SKIP] without an `agentis` binary) — the real refuter prints the sentinel only with the
#      rubric on AND a non-empty block, and a byte-length probe over the EXTRACTED helpers gives a 0-byte
#      directive under every other combination.
# Nothing here is a precision claim: that needs a new fresh set in a separate run.
#
# Usage:  dark-factory/demo-scope-assumptions.sh
# Exit: 0 = all assertions held; non-zero = a regression.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib/scope-assumptions.py"
REFUTER="$HERE/auditor/agents/refuter.ag"
HUNTER="$HERE/auditor/agents/hunter.ag"
REFUTE="$HERE/run-refute.sh"
DISCOVERY="$HERE/run-discovery.sh"
VERIFY="$HERE/verify-findings.sh"
ZONEHUNT="$HERE/run-zone-hunt.sh"
FIX="$HERE/fixtures/scope-assumptions"

FAILS=0
note() { echo "demo-scope-assumptions.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$LIB" "$REFUTER" "$HUNTER" "$REFUTE" "$DISCOVERY" "$VERIFY" "$ZONEHUNT" "$FIX/discovery-results.json" \
         "$FIX/contest/README.md" "$FIX/contest-results.json" "$FIX/scope-map.tsv" "$FIX/legacy-block.txt"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done
command -v python3 >/dev/null 2>&1 || { note "python3 not installed" >&2; exit 3; }

WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
# Never touch a live hunt registry: every driver run below gets its own throwaway state dir.
DARK_FACTORY_DIR="$WORK/df-state"; export DARK_FACTORY_DIR
mkdir -p "$DARK_FACTORY_DIR"
# Every knob this demo sets per call starts UNSET, whatever the caller's shell exports.
unset SEVERITY_RUBRIC GROUND_EVIDENCE DF_RUBRIC_MAX_REASKS STUB_SCOPE STUB_REASK STUB_UNARMED STUB_CALLS 2>/dev/null || true

# _agfn <file> <fn> — one `.ag` helper, sliced by line range (never a copy that can drift).
_agfn() {
  awk -v want="^fn $2\\\\(" '$0 ~ want {f=1} f{print} f&&/^}$/{exit}' "$1"
}
# _shfn <file> <fn> — the same for a shell function.
_shfn() {
  sed -n "/^$2() {\$/,/^}\$/p" "$1"
}

# The claims, byte-identical to the exploit sentences of fixtures/scope-assumptions/discovery-results.json.
CLAIM_DEP="a fee-on-transfer token credits the depositor with more than the vault received, so later withdrawals drain other depositors"
CLAIM_WD="withdraw has no ownership check, so any caller can reduce another depositor's balance"
CLAIM_FEE="the admin can set the fee to the largest value its setter accepts and strand every pending deposit"

# ==========================================================================================================
# PART a — THE EXTRACTOR
# ==========================================================================================================
note "a1) byte-exact goldens per doc shape, each run twice (determinism) ..."
for shape in repo-tokens repo-table repo-scopemd repo-absent; do
  python3 "$LIB" extract --repo "$FIX/$shape" > "$WORK/$shape.1" 2>"$WORK/$shape.err"; rc1=$?
  python3 "$LIB" extract --repo "$FIX/$shape" > "$WORK/$shape.2" 2>>"$WORK/$shape.err"; rc2=$?
  if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
    bad "$shape: extract exited $rc1/$rc2 ($(head -1 "$WORK/$shape.err"))"
  elif ! cmp -s "$WORK/$shape.1" "$WORK/$shape.2"; then
    bad "$shape: two runs over the same docs differ — the block is not deterministic"
  elif cmp -s "$WORK/$shape.1" "$FIX/$shape.golden"; then
    ok "$shape: $(wc -l < "$WORK/$shape.1" | tr -d ' ') row(s), byte-identical to its golden on both runs"
  else
    bad "$shape: the block drifted from $shape.golden"
    diff "$FIX/$shape.golden" "$WORK/$shape.1" | head -6 | sed 's/^/      /' >&2
  fi
done
python3 "$LIB" extract --repo "$FIX/repo-tokens" --operator "$FIX/operator/scope-assumptions.md" > "$WORK/op.1" 2>"$WORK/op.err"
python3 "$LIB" extract --repo "$FIX/repo-tokens" --operator "$FIX/operator/scope-assumptions.md" > "$WORK/op.2" 2>/dev/null
if cmp -s "$WORK/op.1" "$WORK/op.2" && cmp -s "$WORK/op.1" "$FIX/operator.golden"; then
  ok "operator file: byte-identical to operator.golden on both runs"
else
  bad "operator file: the block drifted from operator.golden or is not deterministic"
fi

note "a2) nothing declared => 0 bytes; the operator file REPLACES auto-extraction ..."
if [ ! -s "$WORK/repo-absent.1" ]; then
  ok "a README with token prose but no scope section yields an EMPTY block (every caller reads that as OFF)"
else
  bad "the no-scope-section fixture produced rows — prose outside a scope section leaked in"
fi
if ! grep -q 'README.md' "$WORK/op.1" && grep -q '^A1|token|scope-assumptions.md:' "$WORK/op.1"; then
  ok "with --operator no README row survives (explicit curation wins) and the operator file is cited by its BASENAME only"
else
  bad "the operator file did not replace auto-extraction, or was cited by a path"
fi
# #2292: the `exclusion` fallback is GONE (this assertion used to pin it). An exclusion must be explicit.
OP_ERR_WANT='scope-assumptions.py: operator file scope-assumptions.md: skipped 0 bullet(s) naming a source file, 1 unclassified bullet(s) (an exclusion must be explicit: put it under a "## exclusion" heading)'
if grep -q '^A2|trust|' "$WORK/op.1" && ! grep -q 'A single bullet with no keyword' "$WORK/op.1" \
   && grep -q '|exclusion|scope-assumptions.md:[0-9]*|Behaviour during the first epoch after launch' "$WORK/op.1"; then
  ok "a '## trust' heading sets its bullets' category; a heading-less, keyword-less bullet is DROPPED; the same kind of bullet under '## exclusion' is kept"
else
  bad "operator heading categories are wrong, or an unclassified bullet still falls back to exclusion (#2292)"
fi
if [ "$(cat "$WORK/op.err")" = "$OP_ERR_WANT" ]; then
  ok "the drop is counted in exactly ONE stderr line that names the '## exclusion' escape hatch (stdout is the block only)"
else
  bad "the operator skip-count line is missing or drifted: '$(cat "$WORK/op.err")'"
fi
if grep -q '^A1|token|SCOPE.md:' "$WORK/repo-scopemd.1" && grep -q '|chain|README.md:' "$WORK/repo-scopemd.1" \
   && [ "$(grep -n 'SCOPE.md' "$WORK/repo-scopemd.1" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'README.md' "$WORK/repo-scopemd.1" | head -1 | cut -d: -f1)" ]; then
  ok "SCOPE.md is read before README.md, and both are cited repo-relative"
else
  bad "the SCOPE.md -> README.md source order is not pinned"
fi
if grep -q '|trust|README.md:11|Out of scope: Findings that need a compromised owner key' "$WORK/repo-table.1"; then
  ok "category PRIORITY holds (trust > token > chain > exclusion): an exclusion that names the owner is a trust row"
else
  bad "the category priority drifted on the table fixture"
fi

note "a3) the file-table and code-fence exclusions; Q/A rows categorised by the QUESTION ..."
if ! grep -qiE '\.(sol|vy|rs)\b' "$WORK/repo-tokens.1" && ! grep -q 'fenced line' "$WORK/repo-tokens.1" \
   && ! grep -q 'nSLOC' "$WORK/repo-tokens.1"; then
  ok "no in-scope file row, no table header and no fenced-code line reached the block"
else
  bad "a source-file row, a table header or a fenced line was extracted"
fi
if grep -q '^A2|token|README.md:19-21|Q: Which tokens .* — A: Standard ERC20 only\. No fee-on-transfer' "$WORK/repo-tokens.1" \
   && ! grep -q 'comply with any specific standard' "$WORK/repo-tokens.1"; then
  ok "a question + its two-line answer is ONE row cited first-last; an unclassifiable Q/A is dropped"
else
  bad "the Q/A pairing, its first-last citation or its categorisation is wrong"
fi

note "a4) every emitted citation range CONTAINS its row's text ..."
python3 - "$LIB" "$FIX" > "$WORK/cite-check.txt" 2>&1 <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("sa", sys.argv[1])
sa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sa)
fix = sys.argv[2]
cases = [("repo-tokens.golden", os.path.join(fix, "repo-tokens")),
         ("repo-table.golden", os.path.join(fix, "repo-table")),
         ("repo-scopemd.golden", os.path.join(fix, "repo-scopemd")),
         ("operator.golden", os.path.join(fix, "operator")),
         ("contest-auto.golden", os.path.join(fix, "contest", "target")),
         ("contest-operator.golden", os.path.join(fix, "contest"))]
bad = checked = 0
for golden, base in cases:
    for line in open(os.path.join(fix, golden), encoding="utf-8"):
        m = sa.ROW_RE.match(line.rstrip("\n"))
        if not m:
            continue
        cite, text = m.group(3), m.group(4)
        src, rng = cite.rsplit(":", 1)
        a, _, b = rng.partition("-")
        a, b = int(a), int(b or a)
        lines = open(os.path.join(base, src), encoding="utf-8").read().split("\n")[a - 1:b]
        window = sa.norm(" ".join(sa.clean(l) for l in lines))
        for part in text.split(" — A: "):
            part = part[3:] if part.startswith("Q: ") else part
            for seg in part.split(": ", 1):
                checked += 1
                if sa.norm(seg) not in window:
                    bad += 1
                    print("MISS %s %s: %r" % (golden, cite, seg))
print("CHECKED=%d BAD=%d" % (checked, bad))
PY
if grep -q '^CHECKED=[1-9][0-9]* BAD=0$' "$WORK/cite-check.txt"; then
  ok "every row's text is inside its cited line range ($(sed -n 's/^CHECKED=\([0-9]*\).*/\1/p' "$WORK/cite-check.txt") segments over six goldens, incl. the '../README.md' parent citations)"
else
  bad "a citation range does not contain its row text"
  head -5 "$WORK/cite-check.txt" | sed 's/^/      /' >&2
fi

note "a5) the caps (40 rows, 300 characters) and the pipe sanitising ..."
CAPREPO="$WORK/cap-repo"; mkdir -p "$CAPREPO"
{
  printf '# Cap fixture\n\n## Known issues\n\n'
  printf -- '- Rounding | truncation in the fee path is accepted by design.\n'
  printf -- '- '
  n=0; while [ "$n" -lt 40 ]; do printf 'an accepted long declaration '; n=$((n + 1)); done
  printf '\n'
  n=1; while [ "$n" -le 55 ]; do printf -- '- Accepted behaviour number %s is a documented design choice.\n' "$n"; n=$((n + 1)); done
} > "$CAPREPO/README.md"
python3 "$LIB" extract --repo "$CAPREPO" > "$WORK/cap.out" 2>/dev/null
CAP_ROWS="$(wc -l < "$WORK/cap.out" | tr -d ' ')"
CAP_MAX="$(awk -F'|' '{ t=$0; sub(/^[^|]*\|[^|]*\|[^|]*\|/, "", t); if (length(t) > m) m = length(t) } END { print m+0 }' "$WORK/cap.out")"
if [ "$CAP_ROWS" = "40" ] && [ "$CAP_MAX" = "300" ] && grep -q '^A40|' "$WORK/cap.out" && ! grep -q '^A41|' "$WORK/cap.out"; then
  ok "57 qualifying lines -> exactly 40 rows in source order; a 1000+ character line is cut to exactly 300"
else
  bad "the caps are wrong (rows=$CAP_ROWS, longest text=$CAP_MAX)"
fi
if grep -q '^A1|known-issue|README.md:5|Rounding / truncation in the fee path' "$WORK/cap.out"; then
  ok "a literal '|' in a declaration is rendered '/', so the row keeps exactly four fields"
else
  bad "a '|' inside a declaration was not sanitised"
fi
python3 "$LIB" extract --repo "$WORK/no-such-dir" > /dev/null 2>&1; RC_NODIR=$?
python3 "$LIB" bogus > /dev/null 2>&1; RC_BOGUS=$?
if [ "$RC_NODIR" = "2" ] && [ "$RC_BOGUS" = "2" ]; then
  ok "a missing --repo and an unknown subcommand are usage errors (exit 2), never an empty block"
else
  bad "usage errors exit $RC_NODIR/$RC_BOGUS, want 2/2"
fi

note "a6) #2292 CONTEST LAYOUT: no row names a source file, in either mode; nothing comes from the file list ..."
CT="$FIX/contest"
python3 "$LIB" extract --repo "$CT/target" > "$WORK/ct-auto.1" 2>"$WORK/ct-auto.err"
python3 "$LIB" extract --repo "$CT/target" > "$WORK/ct-auto.2" 2>/dev/null
python3 "$LIB" extract --repo "$CT/target" --operator "$CT/README.md" > "$WORK/ct-op.1" 2>"$WORK/ct-op.err"
python3 "$LIB" extract --repo "$CT/target" --operator "$CT/README.md" > "$WORK/ct-op.2" 2>/dev/null
for m in auto op; do
  g="$FIX/contest-auto.golden"; [ "$m" = "op" ] && g="$FIX/contest-operator.golden"
  if [ -s "$WORK/ct-$m.1" ] && cmp -s "$WORK/ct-$m.1" "$WORK/ct-$m.2" && cmp -s "$WORK/ct-$m.1" "$g"; then
    ok "contest/$m: $(wc -l < "$WORK/ct-$m.1" | tr -d ' ') row(s), byte-identical to ${g##*/} on both runs"
  else
    bad "contest/$m: the block drifted from ${g##*/} or is not deterministic"
    diff "$g" "$WORK/ct-$m.1" | head -6 | sed 's/^/      /' >&2
  fi
done
# The audit-scope section of the wrapper README, as a line range: no row may be cited from inside it.
CT_S="$(grep -n '^# Audit scope$' "$CT/README.md" | cut -d: -f1)"
CT_E="$(grep -n '^# Out of scope$' "$CT/README.md" | cut -d: -f1)"
CT_BAD=""
for m in auto op; do
  grep -qiE '\.(sol|vy|rs|move|cairo|ts|js)([^[:alnum:]_]|$)' "$WORK/ct-$m.1" && CT_BAD="$CT_BAD $m:source-file-row"
  CT_IN="$(awk -F'|' -v s="$CT_S" -v e="$CT_E" '{ n = $3; sub(/^.*:/, "", n); sub(/-.*$/, "", n); if (n + 0 > s + 0 && n + 0 < e + 0) c++ } END { print c + 0 }' "$WORK/ct-$m.1")"
  [ "$CT_IN" = "0" ] || CT_BAD="$CT_BAD $m:$CT_IN-row(s)-from-the-file-list"
done
if [ -n "$CT_S" ] && [ -n "$CT_E" ] && [ "$CT_S" -lt "$CT_E" ] && [ -z "$CT_BAD" ]; then
  ok "auto AND operator: zero rows naming a source file, zero rows cited from the audit-scope section (lines $CT_S-$CT_E)"
else
  bad "the in-scope file list reached the block:$CT_BAD"
fi
if ! grep -q '|trust|' "$WORK/ct-op.1" \
   && [ "$(grep '|token|' "$WORK/ct-op.1" | cut -d'|' -f3 | tr '\n' ' ')" = "README.md:15 README.md:16 " ] \
   && [ "$(grep -c '|exclusion|' "$WORK/ct-op.1")" = "1" ] && grep -q '|exclusion|README.md:35|Findings that need' "$WORK/ct-op.1"; then
  ok "operator: no trust/token row minted from a 'keeper/' or 'tokens/' PATH (the skip runs before classification), and the one exclusion is the explicit one"
else
  bad "operator: a path was classified by a directory keyword, or boilerplate bullets became exclusions"
fi
CT_ERR_WANT='scope-assumptions.py: operator file README.md: skipped 4 bullet(s) naming a source file, 5 unclassified bullet(s) (an exclusion must be explicit: put it under a "## exclusion" heading)'
if [ "$(cat "$WORK/ct-op.err")" = "$CT_ERR_WANT" ] && [ ! -s "$WORK/ct-auto.err" ]; then
  ok "operator stderr: exactly one line with the exact counts (4 source-file, 5 unclassified); auto stderr is empty"
else
  bad "the skip-count line is wrong ('$(cat "$WORK/ct-op.err")') or auto wrote to stderr"
fi

note "a7) #2292 PARENT DOC: read only when BOUND to the repo, first, cited '../<name>' ..."
if [ "$(cut -d'|' -f3 "$WORK/ct-auto.1" | grep -c '^\.\./README\.md:')" = "$(wc -l < "$WORK/ct-auto.1" | tr -d ' ')" ] \
   && ! grep -qF "$FIX" "$WORK/ct-auto.1" && ! cut -d'|' -f3 "$WORK/ct-auto.1" | grep -q '^/'; then
  ok "a wrapper README one level above the code dir is read although the code dir ships its own README, cited '../README.md' (relative, no host path)"
else
  bad "the bound parent doc was not read, or it is cited by a host path"
fi
# The same wrapper over a code dir with NO doc of its own, and over one whose own README declares things too.
mkdir -p "$WORK/ct-bare/target/src" "$WORK/ct-both"
cp "$CT/README.md" "$WORK/ct-bare/README.md"; cp "$CT/target/src/Vault.sol" "$WORK/ct-bare/target/src/Vault.sol"
cp "$CT/README.md" "$WORK/ct-both/README.md"; cp -R "$FIX/repo-tokens" "$WORK/ct-both/target"
python3 "$LIB" extract --repo "$WORK/ct-bare/target" > "$WORK/ct-bare.out" 2>/dev/null
python3 "$LIB" extract --repo "$WORK/ct-both/target" > "$WORK/ct-both.out" 2>/dev/null
if cmp -s "$WORK/ct-bare.out" "$FIX/contest-auto.golden"; then
  ok "a code dir with no README/SCOPE of its own gets the same block from the bound parent"
else
  bad "the parent doc is not read when the code dir has no doc of its own"
fi
if [ "$(wc -l < "$WORK/ct-both.out" | tr -d ' ')" = "9" ] \
   && [ "$(cut -d'|' -f3 "$WORK/ct-both.out" | sed 's/:.*//' | uniq | tr '\n' ' ')" = "../README.md README.md " ]; then
  ok "source order: every parent row first, then the repo's own (4 + 5 rows, ids renumbered in one sequence)"
else
  bad "the parent -> repo source order is not pinned ($(cut -d'|' -f3 "$WORK/ct-both.out" | sed 's/:.*//' | uniq | tr '\n' ' '))"
fi
# An UNBOUND parent: it declares an exclusion and even lists a source file — but under ANOTHER directory name.
mkdir -p "$WORK/ct-unbound/target"
{
  printf '# Unrelated notes\n\n## Out of scope\n\n'
  printf -- '- Findings in the legacy migration tooling are out of scope.\n\n## Scope\n\n'
  printf -- '- elsewhere/src/Vault.sol\n'
} > "$WORK/ct-unbound/README.md"
cp "$FIX/repo-absent/README.md" "$WORK/ct-unbound/target/README.md"
python3 "$LIB" extract --repo "$WORK/ct-unbound/target" > "$WORK/ct-unbound.out" 2>"$WORK/ct-unbound.err"; RC_UNB=$?
if [ "$RC_UNB" = "0" ] && [ ! -s "$WORK/ct-unbound.out" ] && [ ! -s "$WORK/ct-unbound.err" ]; then
  ok "an unbound parent README (no source file listed under the repo's directory name) contributes 0 rows"
else
  bad "an unrelated parent README leaked $(wc -l < "$WORK/ct-unbound.out" | tr -d ' ') row(s) into the block (rc=$RC_UNB)"
fi

# ==========================================================================================================
# PART b — THE DECIDER
# ==========================================================================================================
BLOCK="$FIX/repo-tokens.golden"
# _dec <evidence> [claim] — the decider's answer for one REFUTE-GROUND evidence span.
_dec() {
  python3 "$LIB" check --block "$BLOCK" --claim "${2:-$CLAIM_DEP}" --evidence "$1" 2>/dev/null
}
note "b1) a compliant line passes and returns the cited row ..."
PASS_OUT="$(_dec 'A2:"Standard ERC20 only. No fee-on-transfer" premise:"a fee-on-transfer token credits"')"
case "$PASS_OUT" in
  "ok	A2	token	README.md:19-21	Q: Which tokens"*"	a fee-on-transfer token credits")
    ok "pass -> ok<TAB>A2<TAB>token<TAB>README.md:19-21<TAB><row text><TAB><premise>" ;;
  *) bad "the compliant line did not pass: '$PASS_OUT'" ;;
esac

note "b2) one fixture per contract id ..."
_expect() {
  _e_want="$1"; _e_label="$2"; _e_got="$(_dec "$3" "${4:-$CLAIM_DEP}")"
  if [ "$_e_got" = "fail	$_e_want" ]; then
    ok "$_e_label -> $_e_want"
  else
    bad "$_e_label -> expected $_e_want, got '$_e_got'"
  fi
}
_expect scope-cite-missing "no A<n> citation at all" 'the docs say standard assets only premise:"a fee-on-transfer token credits"'
_expect scope-cite-missing "a quote shorter than a dozen characters" 'A2:"ERC20 only" premise:"a fee-on-transfer token credits"'
_expect scope-cite-unresolved "an id that is not in the block" 'A9:"Standard ERC20 only. No fee-on-transfer" premise:"a fee-on-transfer token credits"'
_expect scope-cite-unresolved "a quote taken from A2 but cited as A1" 'A1:"Standard ERC20 only. No fee-on-transfer" premise:"a fee-on-transfer token credits"'
_expect scope-cite-unresolved "a quote taken from A2 but cited as A3" 'A3:"Standard ERC20 only. No fee-on-transfer" premise:"a fee-on-transfer token credits"'
_expect scope-not-citable "a trust row (context only)" 'A3:"The admin is a trusted multisig" premise:"the admin can set the fee"' "$CLAIM_FEE"
_expect scope-premise-missing "no premise quote" 'A2:"Standard ERC20 only. No fee-on-transfer"'
_expect scope-premise-missing "a premise shorter than eight characters" 'A2:"Standard ERC20 only. No fee-on-transfer" premise:"a fee"'
_expect scope-premise-unresolved "a premise that is not in the claim" 'A2:"Standard ERC20 only. No fee-on-transfer" premise:"a rebasing token shrinks"'
_expect scope-premise-unresolved "a real premise quoted against the WRONG claim" 'A2:"Standard ERC20 only. No fee-on-transfer" premise:"a fee-on-transfer token credits"' "$CLAIM_WD"

note "b3) a PTY-wrap-split quote still resolves (whitespace-free normalisation) ..."
WRAP_OUT="$(_dec 'A2:"Standard ERC20 on ly. No fee-on- transfer" premise:"a fee-on- transfer token cred its"')"
case "$WRAP_OUT" in
  ok"	A2	"*) ok "quotes split mid-word by a terminal wrap still resolve against the row and the claim" ;;
  *) bad "a wrap-split quote no longer resolves: '$WRAP_OUT'" ;;
esac
RC_USAGE=0; python3 "$LIB" check --block "$BLOCK" --claim x > /dev/null 2>&1 || RC_USAGE=$?
if [ "$RC_USAGE" = "2" ]; then
  ok "a check without --evidence is a usage error (exit 2)"
else
  bad "a check without --evidence exited $RC_USAGE, want 2"
fi

note "b4) #2292: an EXCLUSION row naming a file of the mapped scope is never a ground (--scope-map) ..."
LEG="$FIX/legacy-block.txt"; SMAP="$FIX/scope-map.tsv"
# _decm <evidence> [map] — the decider over the pre-#2292-shaped block, with or without the zone map.
_decm() {
  python3 "$LIB" check --block "$LEG" --claim "$CLAIM_DEP" --evidence "$1" ${2:+--scope-map "$2"} 2>/dev/null
}
PREM='premise:"a fee-on-transfer token credits"'
if [ "$(_decm "A1:\"target/src/Vault.sol\" $PREM" "$SMAP")" = "fail	scope-cite-in-scope-file" ]; then
  ok "a file row (repo-prefixed path vs the mapped 'src/Vault.sol@deposit+withdraw' token) -> scope-cite-in-scope-file"
else
  bad "a file-list exclusion row passed with the map: '$(_decm "A1:\"target/src/Vault.sol\" $PREM" "$SMAP")'"
fi
if [ "$(_decm "A4:\"Router.sol and Wrapper.sol\" $PREM" "$SMAP")" = "fail	scope-cite-in-scope-file" ]; then
  ok "bare file names (a '/'-boundary suffix of a mapped path) -> scope-cite-in-scope-file"
else
  bad "a bare-basename exclusion row passed with the map: '$(_decm "A4:\"Router.sol and Wrapper.sol\" $PREM" "$SMAP")'"
fi
B4_BAD=""
case "$(_decm "A2:\"Findings that need the deployment scripts\" $PREM" "$SMAP")" in ok"	A2	exclusion	"*) ;; *) B4_BAD="$B4_BAD prose-exclusion" ;; esac
case "$(_decm "A3:\"Vault.sol accepts standard ERC20 only\" $PREM" "$SMAP")" in ok"	A3	token	"*) ;; *) B4_BAD="$B4_BAD token-row-naming-a-mapped-file" ;; esac
case "$(_decm "A5:\"lib/vendor/Math.sol is a vendored dependency\" $PREM" "$SMAP")" in ok"	A5	exclusion	"*) ;; *) B4_BAD="$B4_BAD unmapped-file-exclusion" ;; esac
if [ -z "$B4_BAD" ]; then
  ok "still citable with the map: a prose exclusion, a TOKEN row naming a mapped file, an exclusion naming a file OUTSIDE the map"
else
  bad "the in-scope-file contract over-reaches:$B4_BAD"
fi
case "$(_decm "A1:\"target/src/Vault.sol\" $PREM")" in
  ok"	A1	exclusion	"*) ok "without --scope-map the same file row passes — the contract is inert when the flag is absent (byte-identical decider)" ;;
  *) bad "the in-scope-file contract ran without --scope-map" ;;
esac
RC_MAP=0; python3 "$LIB" check --block "$LEG" --claim "$CLAIM_DEP" --evidence "A1:\"target/src/Vault.sol\" $PREM" \
  --scope-map "$WORK/no-such-map.tsv" > /dev/null 2>&1 || RC_MAP=$?
if [ "$RC_MAP" = "3" ]; then
  ok "a --scope-map that cannot be read is exit 3 (unreadable input), never a silent pass"
else
  bad "an unreadable --scope-map exited $RC_MAP, want 3"
fi

# ==========================================================================================================
# PART c — SOURCE GUARDS
# ==========================================================================================================
note "c1) refuter.ag: marker = the directive's first line; \"\" with the rubric off or no block ..."
SAD="$(_agfn "$REFUTER" scope_assumptions_directive)"
if printf '%s\n' "$SAD" | grep -q 'return scope_assumptions_marker() + "\\n"' \
   && _agfn "$REFUTER" scope_assumptions_marker | grep -q 'return "=== DECLARED SCOPE ASSUMPTIONS'; then
  ok "the directive renders scope_assumptions_marker() as its literal FIRST line (what the sentinel greps for)"
else
  bad "the directive does not open with its marker — the sentinel could claim a block that never rendered"
fi
if printf '%s\n' "$SAD" | grep -q 'if !severity_rubric_enabled() { return ""; }' \
   && printf '%s\n' "$SAD" | grep -q 'let block = cat_file(getenv("SCOPE_ASSUMPTIONS_PATH"));' \
   && printf '%s\n' "$SAD" | grep -q 'if len(block) == 0 { return ""; }'; then
  ok "\"\" unless severity_rubric_enabled() AND the staged block is non-empty (nested under the rubric, STOP-1 decision 2)"
else
  bad "the directive's rubric-nesting or empty-block early returns are gone"
fi

note "c2) exactly ONE splice, in the discovery-lead branch, after the rubric and before its TIE-BREAK ..."
S_COUNT="$(grep -c '^ *+ scope_assumptions_directive()$' "$REFUTER" || true)"
L_SC="$(grep -n '^ *+ scope_assumptions_directive()$' "$REFUTER" | head -1 | cut -d: -f1)"
L_R1="$(grep -n '^ *+ severity_rubric_directive()$' "$REFUTER" | head -1 | cut -d: -f1)"
L_T1="$(grep -n 'TIE-BREAK: if after an honest trace' "$REFUTER" | head -1 | cut -d: -f1)"
L_INV="$(grep -n 'This finding is a STATEFUL invariant a property-fuzzer ALREADY BROKE' "$REFUTER" | head -1 | cut -d: -f1)"
if [ "$S_COUNT" = "1" ] && [ -n "$L_SC" ] && [ -n "$L_R1" ] && [ -n "$L_T1" ] && [ -n "$L_INV" ] \
   && [ "$L_R1" -lt "$L_SC" ] && [ "$L_SC" -lt "$L_T1" ] && [ "$L_SC" -lt "$L_INV" ]; then
  ok "one splice at line $L_SC: after the rubric ($L_R1), before the discovery TIE-BREAK ($L_T1), outside the invariant mode ($L_INV)"
else
  bad "the scope splice is wrong (count=$S_COUNT at $L_SC; rubric=$L_R1 tie-break=$L_T1 invariant=$L_INV)"
fi
if grep -q 'if index_of(instruction, scope_assumptions_marker()) >= 0 { print("SCOPE-ASSUMPTIONS|refute|on"); }' "$REFUTER"; then
  ok "the SCOPE-ASSUMPTIONS| sentinel is honesty-gated on the marker being IN the assembled prompt"
else
  bad "the SCOPE-ASSUMPTIONS| sentinel is missing or not gated on the assembled instruction"
fi
L_SENT="$(grep -n 'print("SCOPE-ASSUMPTIONS|refute|on")' "$REFUTER" | head -1 | cut -d: -f1)"
L_PROMPT="$(grep -n '^let verdict = prompt(' "$REFUTER" | head -1 | cut -d: -f1)"
if [ -n "$L_SENT" ] && [ -n "$L_PROMPT" ] && [ "$L_SENT" -lt "$L_PROMPT" ]; then
  ok "the sentinel is printed BEFORE prompt(), so it can never be glued into the verdict reason"
else
  bad "the sentinel is not printed before prompt()"
fi

note "c3) wiring: passthrough, cell env, three scraper boundaries ..."
R_PASS="$(grep 'echo "exec.env_passthrough' "$REFUTE" | head -1)"
W_MISS=""
case "$R_PASS" in *SCOPE_ASSUMPTIONS_PATH*) ;; *) W_MISS="$W_MISS passthrough" ;; esac
# shellcheck disable=SC2016  # the single quotes are deliberate: a LITERAL source match
_shfn "$REFUTE" _rf_attempt >/dev/null 2>&1
# shellcheck disable=SC2016  # literal source text
grep -q '        SCOPE_ASSUMPTIONS_PATH="$SCOPE_IN_RUN" \\$' "$REFUTE" || W_MISS="$W_MISS cell-env"
for fn in _join_wrapped_verdict _join_wrapped_constraint _join_wrapped_ground; do
  _shfn "$REFUTE" "$fn" | grep -q 'SCOPE-ASSUMPTIONS' || W_MISS="$W_MISS boundary:$fn"
done
if [ -z "$W_MISS" ]; then
  ok "SCOPE_ASSUMPTIONS_PATH is allowlisted AND exported into _rf_attempt, and SCOPE-ASSUMPTIONS| closes all three scrapers"
else
  bad "wiring gap (an unregistered knob is silently inert, #1426):$W_MISS"
fi
SENT_TOK='SCOPE-ASSUMPTIONS|'
case "$SENT_TOK" in
  *'VERDICT|'*|*'CANDIDATE|'*) bad "the sentinel token carries a reply-validation substring" ;;
  *) ok "SCOPE-ASSUMPTIONS| contains neither VERDICT| nor CANDIDATE| — the reply validator cannot false-accept on it" ;;
esac
# #2284: verify-findings.sh builds the shared refute argv ONCE (REFUTE_ARGS, which carries the block) and hands it
# to BOTH of its refute invocations (the single-candidate gate and the batched first read).
# shellcheck disable=SC2016  # literal source text
if grep -qF '[ -z "$SCOPE_BLOCK" ] || REFUTE_ARGS+=(--scope-assumptions "$SCOPE_BLOCK")' "$VERIFY" \
   && [ "$(grep -F '"$REFUTE" --' "$VERIFY" | grep -cF '"${REFUTE_ARGS[@]}"')" = "2" ] \
   && [ "$(grep -cF '"$REFUTE" --' "$VERIFY")" = "2" ] \
   && grep -q '${SCOPE_DOCS:+--scope-docs "$SCOPE_DOCS"}' "$ZONEHUNT"; then
  ok "verify-findings.sh passes the block on BOTH refute invocations, and run-zone-hunt.sh forwards --scope-docs to STAGE 4 only when set"
else
  bad "the verify-findings.sh / run-zone-hunt.sh forwarding is incomplete"
fi

# #2292: the zone map rides the SAME guards — a new line each, so the two pins above still match byte for byte.
C3B=""
# shellcheck disable=SC2016  # literal source text
grep -qF '[ -z "$SCOPE_BLOCK" ] || [ -z "$SCOPE_MAP" ] || REFUTE_ARGS+=(--scope-map "$SCOPE_MAP")' "$VERIFY" || C3B="$C3B verify-forward"
# shellcheck disable=SC2016  # literal source text
L_ZD="$(grep -n '^  \${SCOPE_DOCS:+--scope-docs "\$SCOPE_DOCS"} \\$' "$ZONEHUNT" | cut -d: -f1)"
# shellcheck disable=SC2016  # literal source text
L_ZM="$(grep -n '^  \${SCOPE_DOCS:+--scope-map "\$MAP/scope.tsv"} \\$' "$ZONEHUNT" | cut -d: -f1)"
{ [ -n "$L_ZD" ] && [ -n "$L_ZM" ] && [ "$L_ZM" = "$((L_ZD + 1))" ]; } || C3B="$C3B zone-hunt-argv"
# shellcheck disable=SC2016  # literal source text
_shfn "$REFUTE" _scope_ground_state | grep -qF '${SCOPE_MAP:+--scope-map "$SCOPE_MAP"}' || C3B="$C3B decider-call"
# The map is read by the driver-side decider only: never allowlisted, never exported into a cell.
case "$R_PASS" in *SCOPE_MAP*) C3B="$C3B passthrough-leak" ;; esac
grep -qE '^ +SCOPE_MAP="[^"]*" \\$' "$REFUTE" && C3B="$C3B cell-env-leak"
if [ -z "$C3B" ]; then
  ok "--scope-map: verify-findings.sh forwards it only WITH a block, run-zone-hunt.sh only WITH --scope-docs (the next argv line), and it reaches the decider call but never the cell env"
else
  bad "the --scope-map forwarding is wrong:$C3B"
fi

note "c4) the byte-paired functions and the closed ground list are UNTOUCHED ..."
PAIR_BAD=""
for fn in severity_rubric_marker severity_rubric_block ground_evidence_marker ground_evidence_block; do
  _agfn "$HUNTER" "$fn" > "$WORK/h.$fn"; _agfn "$REFUTER" "$fn" > "$WORK/r.$fn"
  { [ -s "$WORK/h.$fn" ] && cmp -s "$WORK/h.$fn" "$WORK/r.$fn"; } || PAIR_BAD="$PAIR_BAD $fn"
done
for fn in _rubric_sufficient_grounds _dismiss_evidence_ok _contract_requirement; do
  _shfn "$DISCOVERY" "$fn" > "$WORK/d.$fn"; _shfn "$REFUTE" "$fn" > "$WORK/f.$fn"
  { [ -s "$WORK/d.$fn" ] && cmp -s "$WORK/d.$fn" "$WORK/f.$fn"; } || PAIR_BAD="$PAIR_BAD $fn"
done
if [ -z "$PAIR_BAD" ]; then
  ok "all seven byte-paired functions are still identical across their pairs"
else
  bad "a byte-paired function drifted:$PAIR_BAD"
fi
if ! _agfn "$REFUTER" severity_rubric_block | grep -q 'out-of-scope-premise' \
   && ! _shfn "$REFUTE" _rubric_sufficient_grounds | grep -q 'out-of-scope-premise' \
   && _agfn "$REFUTER" severity_rubric_directive | grep -q 'return severity_rubric_block() + ground_evidence_directive() + ground_rule() + rubric_reask_block();'; then
  ok "the closed ground list is unchanged (out-of-scope-premise is an ADDITION described by its own directive) and severity_rubric_directive() does not embed the scope block"
else
  bad "the closed ground list or severity_rubric_directive() was edited"
fi
UNT_BAD=""
for f in "$REFUTER" "$REFUTE" "$VERIFY"; do
  grep -q 'PARAM_AUDIT\|PARAM-AUDIT\|PARAM-TRACE\|_param_' "$f" && UNT_BAD="$UNT_BAD ${f##*/}"
done
if [ -z "$UNT_BAD" ]; then
  ok "no iteration-5 parameter-audit token reached the refute side (demo-param-audit.sh's pin)"
else
  bad "an iteration-5 token leaked into:$UNT_BAD"
fi
if grep -q 'v=="REAL"||v=="REFUTED"||v=="ERROR"' "$VERIFY" \
   && ! grep -nE 'VERD="[A-Z-]+"' "$REFUTE" | grep -vqE 'VERD="REAL"'; then
  ok "the verdict vocabulary is still exactly REAL|REFUTED|ERROR — an out-of-scope verdict stays REFUTED"
else
  bad "a new verdict token was introduced"
fi

note "c5) the re-ask phrases cover every contract id the decider emits ..."
REQ_BAD=""
grep -oE 'fail\("scope-[a-z-]+"\)' "$LIB" | sed 's/fail("//; s/")//' | sort -u > "$WORK/scope-ids.txt"
while IFS= read -r cid; do
  _shfn "$REFUTE" _scope_contract_requirement | grep -q "^    $cid)" || REQ_BAD="$REQ_BAD $cid"
done < "$WORK/scope-ids.txt"
N_IDS="$(grep -oE 'fail\("scope-[a-z-]+"\)' "$LIB" | sort -u | wc -l | tr -d ' ')"
# #2292: five -> six (scope-cite-in-scope-file).
if [ -z "$REQ_BAD" ] && [ "$N_IDS" = "6" ] && grep -q '^scope-cite-in-scope-file$' "$WORK/scope-ids.txt"; then
  ok "all six scope contract ids have their own re-ask phrase (a NEW table; _contract_requirement stays byte-paired)"
else
  bad "a scope contract id has no re-ask phrase:$REQ_BAD (ids found: $N_IDS)"
fi
case "$(tr '\n' ' ' < "$REFUTER" | sed 's/"[[:space:]]*+[[:space:]]*"//g')" in
  *'REFUTE-GROUND|out-of-scope-premise|A<n>:\"<at least a dozen characters copied verbatim from row A<n>>\" premise:\"<at least eight characters copied verbatim from the claimed exploit path above>\"'*)
    ok "the prompt shows EXACTLY the evidence grammar the decider parses (A<n>:\"…\" + premise:\"…\", the 12/8 character floors)" ;;
  *) bad "the directive's evidence grammar drifted from the decider's regexes" ;;
esac

note "c6) pure-meta directive text + substrate purity ..."
SCOPE_SLICE="$WORK/scope-slice.ag"
awk '/^\/\/ --- #2257: DECLARED SCOPE ASSUMPTIONS/{f=1} f&&/^\/\/ --- #1938 invariant-hunt judgment mode/{exit} f{print}' "$REFUTER" > "$SCOPE_SLICE"
grep -v '^[[:space:]]*//' "$SCOPE_SLICE" > "$WORK/scope-code.ag"
# The product denylist is READ from demo-severity-rubric.sh (one list, never a second copy that can drift), and this
# file therefore names no product itself.
DENY="$(sed -n "s/^DENY='\(.*\)'\$/\1/p" "$HERE/demo-severity-rubric.sh" | head -1)"
GT_ID='(^|[^[:alnum:]_])[HM]-[0-9]{1,2}([^[:alnum:]_]|$)'
if [ -z "$DENY" ]; then
  bad "could not read the product denylist out of demo-severity-rubric.sh (reshaped?)"
elif [ ! -s "$WORK/scope-code.ag" ] || ! grep -q 'fn scope_assumptions_directive' "$WORK/scope-code.ag"; then
  bad "could not slice the #2257 block out of refuter.ag (header renamed or moved?)"
elif grep -Eq "$DENY" "$WORK/scope-code.ag" || grep -qi 'corpus-bench' "$WORK/scope-code.ag" || grep -EqI "$GT_ID" "$WORK/scope-code.ag"; then
  bad "the scope directive names a product, standard number, file, corpus or ground-truth id"
  grep -nE "$DENY" "$WORK/scope-code.ag" | head -3 | sed 's/^/      /' >&2
else
  ok "the directive text is pure-meta (no product, standard number, file name, corpus or ground-truth id)"
fi
printf 'the vault takes an ERC20 in Foo.sol and GT %s-4 confirms it\n' 'M' > "$WORK/planted.txt"
if grep -Eq "$DENY" "$WORK/planted.txt" && grep -EqI "$GT_ID" "$WORK/planted.txt"; then
  ok "the denylist + ground-truth-id detectors both fire on a planted hint (negative control)"
else
  bad "the purity detectors do not fire on a planted hint — the guard is dead"
fi
if grep -Eq 'exec sh|python3 -c|reduce\(|regex_' "$WORK/scope-code.ag"; then
  bad "the #2257 .ag block introduced an embedded interpreter / regex / reduce (substrate-purity ratchet)"
else
  ok "the #2257 .ag block is builtins-only (cat_file + getenv + O(1) concat; no exec sh, regex or reduce)"
fi
L_B2257="$(grep -n '^// --- #2257: DECLARED SCOPE ASSUMPTIONS' "$REFUTER" | cut -d: -f1)"
L_B2245="$(grep -n '^// --- #2245 iteration 2: CONTEST-SEVERITY DISMISSAL RUBRIC' "$REFUTER" | cut -d: -f1)"
L_B1938="$(grep -n '^// --- #1938 invariant-hunt judgment mode' "$REFUTER" | cut -d: -f1)"
if [ -n "$L_B2257" ] && [ -n "$L_B2245" ] && [ -n "$L_B1938" ] && [ "$L_B2245" -lt "$L_B2257" ] && [ "$L_B2257" -lt "$L_B1938" ]; then
  ok "the block sits inside demo-severity-rubric.sh's substrate-purity slice (#2245 header .. #1938 header)"
else
  bad "the #2257 block moved outside the rubric demo's purity slice"
fi

# ==========================================================================================================
# PART d — run-refute.sh END TO END (offline --agentis stub)
# ==========================================================================================================
STUB="$WORK/agentis-scope-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
# Offline stand-in for `agentis`: mirrors refuter.ag's sentinel honesty contract (the scope sentinel only with the
# rubric on AND a non-empty staged block) and answers per candidate / per mode. Records every call.
set -u
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    fn="${CAND_FILE_FN:-}"; cls="${CAND_CLASS:-}"
    [ -n "${STUB_CALLS:-}" ] && printf '%s|%s|%s\n' "$fn" "$cls" "${RUBRIC_REASK_GROUNDS:-}" >> "$STUB_CALLS"
    armed=0
    if [ "${SEVERITY_RUBRIC:-}" = "1" ]; then
      printf 'SEVERITY-RUBRIC|refute|on\n'
      if [ -n "${SCOPE_ASSUMPTIONS_PATH:-}" ] && [ -s "$SCOPE_ASSUMPTIONS_PATH" ]; then
        printf 'SCOPE-ASSUMPTIONS|refute|on\n'; armed=1
      fi
    fi
    if [ "${STUB_SCOPE:-}" = "filerow" ]; then
      # #2292: a model that dismisses a finding BECAUSE the staged block has a row naming the candidate's own
      # source file — and judges the claim on its merits (REAL) when no such row exists.
      row=""
      [ "$armed" -eq 1 ] && row="$(grep -F -- "${fn%%:*}" "$SCOPE_ASSUMPTIONS_PATH" | head -1)"
      if [ -z "$row" ] && [ "${STUB_UNARMED:-real}" = "same" ]; then
        # The block-less #1699 C6 re-read of a held case: keep the verdict, so the held row is what gets asserted.
        printf 'VERDICT|REFUTED|%s|%s|the claimed path does not hold\n' "$fn" "$cls"; exit 0
      fi
      if [ -z "$row" ]; then
        printf 'VERDICT|REAL|%s|%s|no declaration names this file, so the claim stands on its merits\n' "$fn" "$cls"; exit 0
      fi
      printf 'REFUTE-GROUND|out-of-scope-premise|%s:"%s" premise:"%s"\n' "${row%%|*}" \
        "$(printf '%s' "$row" | cut -d'|' -f4-)" "$(printf '%s' "${CAND_EXPLOIT:-}" | cut -c1-24)"
      printf 'VERDICT|REFUTED|%s|%s|the declared scope lists the file this claim lives in\n' "$fn" "$cls"
      exit 0
    fi
    case "$fn" in
      *:withdraw)
        printf 'VERDICT|REAL|%s|%s|no ownership check stops the unprivileged caller\n' "$fn" "$cls"; exit 0 ;;
      *:setFee) mode="trust"; premise="the admin can set the fee" ;;
      *)
        mode="${STUB_SCOPE:-oos}"; premise="a fee-on-transfer token credits"
        [ -n "${RUBRIC_REASK_GROUNDS:-}" ] && mode="${STUB_REASK:-$mode}"
        # A model shown NO declaration judges the transfer-fee path on its merits: it holds.
        if [ "$armed" -eq 0 ] && [ "${STUB_UNARMED:-real}" = "real" ]; then
          printf 'VERDICT|REAL|%s|%s|with no declaration against it the transfer-fee path over-credits\n' "$fn" "$cls"; exit 0
        fi ;;
    esac
    case "$mode" in
      oos)   printf 'REFUTE-GROUND|out-of-scope-premise|A2:"Standard ERC20 only. No fee-on-transfer" premise:"%s"\n' "$premise" ;;
      fab)   printf 'REFUTE-GROUND|out-of-scope-premise|A9:"Standard ERC20 only. No fee-on-transfer" premise:"%s"\n' "$premise" ;;
      trust) printf 'REFUTE-GROUND|out-of-scope-premise|A3:"The admin is a trusted multisig" premise:"%s"\n' "$premise" ;;
      wrapped)
        printf 'REFUTE-GROUND|out-of-scope-premise|A2:"Standard ERC20 only. No fee-on-\n'
        printf '    transfer" premise:"a fee-on-transfer token\n'
        printf '    credits"\n' ;;
    esac
    printf 'CONSTRAINT|%s|a claim must not rest on an asset behaviour the target excludes\n' "$cls"
    printf 'VERDICT|REFUTED|%s|%s|the declared scope excludes the asset the exploit needs\n' "$fn" "$cls"
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

TOKBLOCK="$WORK/tokens-block.txt"; cp "$FIX/repo-tokens.golden" "$TOKBLOCK"
: > "$WORK/empty-block.txt"
printf 'src/Vault.sol:deposit | C15 | Medium | %s | src/Vault.sol\n' "$CLAIM_DEP" > "$WORK/c-dep.tsv"
printf 'src/Vault.sol:withdraw | C5 | High | %s | src/Vault.sol\n' "$CLAIM_WD" > "$WORK/c-wd.tsv"
printf 'src/Vault.sol:setFee | C23 | Medium | %s | src/Vault.sol\n' "$CLAIM_FEE" > "$WORK/c-fee.tsv"

# _rr <label> <manifest> [extra flag...] — one offline run-refute.sh run; env comes from the caller.
_rr() {
  _rr_label="$1"; _rr_cands="$2"; shift 2
  STUB_CALLS="$WORK/$_rr_label.calls"; export STUB_CALLS; : > "$STUB_CALLS"
  "$REFUTE" --candidates "$_rr_cands" --code-dir "$FIX/repo-tokens" --backend mock --agentis "$STUB" \
    --out "$WORK/$_rr_label" "$@" > "$WORK/$_rr_label.rout" 2>&1 || true
}
_vrow()  { awk -F'|' 'NF>=5 { v=$4; gsub(/[[:space:]]/,"",v); if (v=="REAL"||v=="REFUTED"||v=="ERROR") { print v; exit } }' "$1/refute-report.md" 2>/dev/null; }
_rrow()  { awk -F'|' 'NF>=5 { v=$4; gsub(/[[:space:]]/,"",v); if (v=="REAL"||v=="REFUTED"||v=="ERROR") { r=$5; sub(/^[[:space:]]+/,"",r); sub(/[[:space:]]+$/,"",r); print r; exit } }' "$1/refute-report.md" 2>/dev/null; }
_c6calls() { grep -c '|C6|' "$1" 2>/dev/null || true; }

note "d1) ACCEPTANCE: 'standard tokens only' refutes the transfer-fee premise — final, visible, no C6, no constraint ..."
# The accounting signal really fires on this code (sliced, never copied), so skipping C6 is a decision, not luck.
_shfn "$REFUTE" fallback_class_for > "$WORK/fb.sh"
# shellcheck disable=SC1090,SC1091
. "$WORK/fb.sh"
if [ "$(fallback_class_for "$FIX/repo-tokens/src/Vault.sol" C15)" = "C6" ]; then
  ok "the #1699 accounting signal FIRES on the fixture code (value-moving function + '-=' deduction)"
else
  bad "the fixture code no longer trips the C6 signal — the no-C6 assertion below would prove nothing"
fi
SEVERITY_RUBRIC=1 _rr d-acc "$WORK/c-dep.tsv" --scope-assumptions "$TOKBLOCK"
RA="$WORK/d-acc"
case "$(_vrow "$RA")|$(_rrow "$RA")" in
  'REFUTED|out-of-scope-premise (A2, token): '*) ok "verdict REFUTED, reason prefixed 'out-of-scope-premise (A2, token): '" ;;
  *) bad "acceptance row is wrong: '$(_vrow "$RA")|$(_rrow "$RA")'"; tail -6 "$WORK/d-acc.rout" | sed 's/^/      /' >&2 ;;
esac
if [ -s "$RA/out-of-scope.tsv" ] && [ "$(awk -F'\t' 'NR==1{print NF}' "$RA/out-of-scope.tsv")" = "7" ] \
   && [ "$(cut -f1-5 "$RA/out-of-scope.tsv")" = "C15	src/Vault.sol:deposit	A2	token	README.md:19-21" ] \
   && [ "$(cut -f7 "$RA/out-of-scope.tsv")" = "a fee-on-transfer token credits" ]; then
  ok "one out-of-scope.tsv row: <class> <file:fn> <id> <category> <source> <text> <premise> (7 columns)"
else
  bad "the out-of-scope.tsv row is missing or mis-shaped"
fi
if [ "$(_c6calls "$WORK/d-acc.calls")" = "0" ] && [ ! -e "$RA/run/refute_src_Vault_sol_deposit_c6.log" ]; then
  ok "NO #1699 C6 re-read (it would run without the block and resurrect the excluded premise)"
else
  bad "the C6 fallback ran on an out-of-scope-premise verdict"
fi
if [ ! -s "$RA/refute-constraints.tsv" ] && [ ! -e "$RA/rubric-dismissals.tsv" ] \
   && [ ! -e "$RA/run/refute_src_Vault_sol_deposit_rubric1.log" ]; then
  ok "no constraint harvested (target-specific scope never travels), no re-ask spent, no rubric sidecar"
else
  bad "an out-of-scope verdict harvested a constraint, spent a re-ask or wrote a rubric sidecar"
fi
if grep -q '^Of the REFUTED: 1 on a DECLARED out-of-scope premise' "$RA/refute-report.md" \
   && grep -q '1 refuted (1 on a declared out-of-scope premise)' "$WORK/d-acc.rout"; then
  ok "the report and the summary line both count the routed candidate (as a SUBSET of REFUTED)"
else
  bad "the out-of-scope count is missing from the report/summary"
fi

note "d2) the in-scope control stays REAL ..."
SEVERITY_RUBRIC=1 _rr d-wd "$WORK/c-wd.tsv" --scope-assumptions "$TOKBLOCK"
if [ "$(_vrow "$WORK/d-wd")" = "REAL" ] && [ ! -e "$WORK/d-wd/out-of-scope.tsv" ]; then
  ok "an ownership bug the declarations do not touch survives (REAL), nothing routed"
else
  bad "the in-scope candidate was not REAL or was routed"
fi

note "d3) a FABRICATED id is re-asked once; held -> rubric-insufficient + sidecar; compliant -> routed ..."
SEVERITY_RUBRIC=1 STUB_UNARMED=same STUB_SCOPE=fab STUB_REASK=fab _rr d-fab "$WORK/c-dep.tsv" --scope-assumptions "$TOKBLOCK"
RF="$WORK/d-fab"
if grep -q '|out-of-scope-premise: the quoted text is not in the assumption row you cited' "$WORK/d-fab.calls"; then
  ok "the re-ask NAMES the open contract: 'out-of-scope-premise: <requirement>'"
else
  bad "the re-ask did not name the scope contract ($(tail -1 "$WORK/d-fab.calls"))"
fi
case "$(_vrow "$RF")|$(_rrow "$RF")" in
  'REFUTED|rubric-insufficient: '*) ok "a held contract failure stays REFUTED with the 'rubric-insufficient: ' prefix" ;;
  *) bad "held fabricated id: row is '$(_vrow "$RF")|$(_rrow "$RF")'" ;;
esac
if [ "$(awk -F'\t' 'NR==1{print $3"|"$5}' "$RF/rubric-dismissals.tsv" 2>/dev/null)" = "out-of-scope-premise|scope-cite-unresolved" ] \
   && [ ! -e "$RF/out-of-scope.tsv" ]; then
  ok "rubric-dismissals.tsv records ground out-of-scope-premise with contract id scope-cite-unresolved; nothing routed"
else
  bad "the held-failure sidecar is wrong: '$(awk -F'\t' 'NR==1{print $3"|"$5}' "$RF/rubric-dismissals.tsv" 2>/dev/null)'"
fi
if [ "$(find "$RF/run" -name 'refute_*_rubric*.log' | wc -l | tr -d ' ')" = "1" ]; then
  ok "exactly ONE extra read was spent (the existing DF_RUBRIC_MAX_REASKS budget, no second loop)"
else
  bad "the scope contract spent more than the bounded re-ask"
fi
SEVERITY_RUBRIC=1 STUB_SCOPE=fab STUB_REASK=oos _rr d-rec "$WORK/c-dep.tsv" --scope-assumptions "$TOKBLOCK"
if [ "$(_vrow "$WORK/d-rec")" = "REFUTED" ] && [ -s "$WORK/d-rec/out-of-scope.tsv" ] \
   && [ ! -e "$WORK/d-rec/rubric-dismissals.tsv" ] && [ "$(_c6calls "$WORK/d-rec.calls")" = "0" ]; then
  ok "a compliant re-ask is routed out of scope (final: no sidecar row, no C6)"
else
  bad "a compliant re-ask was not routed"
fi

note "d4) a TRUST citation is never a ground (scope-not-citable) ..."
SEVERITY_RUBRIC=1 _rr d-trust "$WORK/c-fee.tsv" --scope-assumptions "$TOKBLOCK"
if [ "$(awk -F'\t' 'NR==1{print $3"|"$5}' "$WORK/d-trust/rubric-dismissals.tsv" 2>/dev/null)" = "out-of-scope-premise|scope-not-citable" ] \
   && [ ! -e "$WORK/d-trust/out-of-scope.tsv" ] \
   && grep -q 'a trust row is context only' "$WORK/d-trust.calls"; then
  ok "'the admin is trusted' cannot refute an admitted-parameter claim: held as scope-not-citable, re-ask says so"
else
  bad "a trust row was citable, or the failure was not recorded"
fi

note "d5) a PTY-wrapped ground line is joined and still passes, and never leaks into the reason ..."
SEVERITY_RUBRIC=1 STUB_SCOPE=wrapped _rr d-wrap "$WORK/c-dep.tsv" --scope-assumptions "$TOKBLOCK"
case "$(_rrow "$WORK/d-wrap")" in
  'out-of-scope-premise (A2, token): the declared scope excludes the asset the exploit needs')
    ok "a ground wrapped over three physical lines resolves, and the verdict reason is exactly the model's own sentence" ;;
  *) bad "the wrapped ground failed or leaked: '$(_rrow "$WORK/d-wrap")'" ;;
esac

note "d6) CONTROLS: no block => the ground is just an unknown id; rubric OFF => nothing at all ..."
SEVERITY_RUBRIC=1 STUB_UNARMED=same _rr d-noblk "$WORK/c-dep.tsv"
if [ "$(awk -F'\t' 'NR==1{print $3"|"$5}' "$WORK/d-noblk/rubric-dismissals.tsv" 2>/dev/null)" = "out-of-scope-premise|" ] \
   && [ ! -e "$WORK/d-noblk/out-of-scope.tsv" ] && [ "$(_c6calls "$WORK/d-noblk.calls")" = "1" ]; then
  ok "without a staged block the same line is an unrecognised (insufficient) id exactly as before, and C6 runs as before"
else
  bad "the scope layer acted without a staged block"
fi
STUB_UNARMED=same _rr d-off1 "$WORK/c-dep.tsv"
STUB_UNARMED=same _rr d-off2 "$WORK/c-dep.tsv" --scope-assumptions "$TOKBLOCK"
STUB_UNARMED=same SEVERITY_RUBRIC=1 _rr d-off3 "$WORK/c-dep.tsv" --scope-assumptions "$WORK/empty-block.txt"
STUB_UNARMED=same SEVERITY_RUBRIC=1 _rr d-off4 "$WORK/c-dep.tsv"
if cmp -s "$WORK/d-off1/refute-report.md" "$WORK/d-off2/refute-report.md" \
   && cmp -s "$WORK/d-off1/refute-constraints.tsv" "$WORK/d-off2/refute-constraints.tsv" \
   && [ ! -e "$WORK/d-off2/out-of-scope.tsv" ]; then
  ok "rubric OFF: a staged block changes nothing (report + constraints byte-identical to a flagless run)"
else
  bad "with the rubric OFF the block changed an output"
fi
if cmp -s "$WORK/d-off3/refute-report.md" "$WORK/d-off4/refute-report.md" \
   && [ "$(cd "$WORK/d-off3" && find . -type f | sort)" = "$(cd "$WORK/d-off4" && find . -type f | sort)" ]; then
  ok "an EMPTY block file is 'unset': identical report and an identical file list (nothing staged)"
else
  bad "an empty block file was not treated as unset"
fi
RC_INV=0
"$REFUTE" --candidates "$WORK/c-dep.tsv" --code-dir "$FIX/repo-tokens" --backend mock --agentis "$STUB" \
  --out "$WORK/d-inv" --invariant-mode --scope-assumptions "$TOKBLOCK" > /dev/null 2>&1 || RC_INV=$?
if [ "$RC_INV" = "2" ]; then
  ok "--scope-assumptions with --invariant-mode is refused (exit 2; v1 reach = discovery leads, STOP-1 decision 4)"
else
  bad "--scope-assumptions + --invariant-mode exited $RC_INV, want 2"
fi

note "d7) #2292: a cited FILE ROW of the mapped scope is held (scope-cite-in-scope-file), never routed ..."
SEVERITY_RUBRIC=1 STUB_UNARMED=same STUB_SCOPE=filerow _rr d-file "$WORK/c-dep.tsv" --scope-assumptions "$FIX/legacy-block.txt" --scope-map "$FIX/scope-map.tsv"
RFI="$WORK/d-file"
if grep -q '|out-of-scope-premise: the cited row names a file that is under review' "$WORK/d-file.calls"; then
  ok "the re-ask NAMES the new contract: 'out-of-scope-premise: the cited row names a file that is under review …'"
else
  bad "the re-ask did not name the in-scope-file contract ($(tail -1 "$WORK/d-file.calls"))"
fi
case "$(_vrow "$RFI")|$(_rrow "$RFI")" in
  'REFUTED|rubric-insufficient: '*) ok "the held case stays REFUTED with the 'rubric-insufficient: ' prefix (the existing bounded path, no new loop)" ;;
  *) bad "held file-row citation: row is '$(_vrow "$RFI")|$(_rrow "$RFI")'" ;;
esac
if [ "$(awk -F'\t' 'NR==1{print $3"|"$5}' "$RFI/rubric-dismissals.tsv" 2>/dev/null)" = "out-of-scope-premise|scope-cite-in-scope-file" ] \
   && [ ! -e "$RFI/out-of-scope.tsv" ] && [ "$(_c6calls "$WORK/d-file.calls")" = "1" ]; then
  ok "rubric-dismissals.tsv records scope-cite-in-scope-file; nothing routed to out-of-scope.tsv; the #1699 C6 re-read is NOT skipped"
else
  bad "the in-scope-file failure was routed, not recorded, or skipped C6 (sidecar '$(awk -F'\t' 'NR==1{print $3"|"$5}' "$RFI/rubric-dismissals.tsv" 2>/dev/null)', c6=$(_c6calls "$WORK/d-file.calls"))"
fi
SEVERITY_RUBRIC=1 STUB_SCOPE=filerow _rr d-filenomap "$WORK/c-dep.tsv" --scope-assumptions "$FIX/legacy-block.txt"
if [ "$(cut -f3-4 "$WORK/d-filenomap/out-of-scope.tsv" 2>/dev/null)" = "A1	exclusion" ] && [ ! -e "$WORK/d-filenomap/rubric-dismissals.tsv" ]; then
  ok "CONTROL: without --scope-map the same citation is routed exactly as before (the flag is what arms the contract)"
else
  bad "the no-map control did not behave like a pre-#2292 run"
fi
STUB_UNARMED=same SEVERITY_RUBRIC=1 _rr d-maponly "$WORK/c-dep.tsv" --scope-map "$FIX/scope-map.tsv"
RC_NOMAP=0
"$REFUTE" --candidates "$WORK/c-dep.tsv" --code-dir "$FIX/repo-tokens" --backend mock --agentis "$STUB" \
  --out "$WORK/d-badmap" --scope-map "$WORK/no-such-map.tsv" > /dev/null 2>&1 || RC_NOMAP=$?
if cmp -s "$WORK/d-maponly/refute-report.md" "$WORK/d-off4/refute-report.md" \
   && [ "$(cd "$WORK/d-maponly" && find . -type f | sort)" = "$(cd "$WORK/d-off4" && find . -type f | sort)" ] \
   && [ "$RC_NOMAP" = "2" ]; then
  ok "--scope-map without a staged block is ignored (identical report and file list); a missing map file is exit 2"
else
  bad "--scope-map alone changed an output, or a missing map exited $RC_NOMAP (want 2)"
fi

# ==========================================================================================================
# PART e — verify-findings.sh END TO END
# ==========================================================================================================
# The repo dirs share one basename, so every verified_findings.json carries the same "repo" field.
TGT_TOK="$WORK/tok/target"; mkdir -p "$TGT_TOK"; cp -R "$FIX/repo-tokens/." "$TGT_TOK/"
TGT_ABS="$WORK/abs/target"; mkdir -p "$TGT_ABS/src"
cp "$FIX/repo-absent/README.md" "$TGT_ABS/README.md"; cp "$FIX/repo-tokens/src/Vault.sol" "$TGT_ABS/src/Vault.sol"
RES="$FIX/discovery-results.json"
# _vf <label> <repo> [flag...] — one offline verify-findings.sh run; env comes from the caller.
_vf() {
  _vf_label="$1"; _vf_repo="$2"; shift 2
  STUB_CALLS="$WORK/$_vf_label.calls"; export STUB_CALLS; : > "$STUB_CALLS"
  "$VERIFY" --results "$RES" --repo "$_vf_repo" --out "$WORK/$_vf_label" --gate refute --backend mock \
    --agentis "$STUB" "$@" > "$WORK/$_vf_label.vout" 2>&1 || true
}
_jq() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$@" 2>/dev/null; }

note "e1) --scope-docs auto: the transfer-fee lead lands in out_of_scope[], the in-scope one in verified[] ..."
SEVERITY_RUBRIC=1 _vf e-auto "$TGT_TOK" --scope-docs auto
EJ="$WORK/e-auto/verified_findings.json"
if [ "$(_jq "$EJ" '",".join(v["location"] for v in d["verified"])')" = "src/Vault.sol:withdraw" ] \
   && [ "$(_jq "$EJ" '",".join(v["location"] for v in d.get("out_of_scope", []))')" = "src/Vault.sol:deposit" ]; then
  ok "verified[] = [withdraw]; out_of_scope[] = [deposit] — never both"
else
  bad "the partition is wrong (verified=$(_jq "$EJ" '[v["location"] for v in d["verified"]]') out_of_scope=$(_jq "$EJ" '[v["location"] for v in d.get("out_of_scope", [])]'))"
  tail -5 "$WORK/e-auto.vout" | sed 's/^/      /' >&2
fi
if [ "$(_jq "$EJ" 'd["out_of_scope"][0]["label"]+"|"+d["out_of_scope"][0]["verdict"]+"|"+d["out_of_scope"][0]["assumption"]["id"]+"|"+d["out_of_scope"][0]["assumption"]["category"]+"|"+d["out_of_scope"][0]["assumption"]["source"]+"|"+d["out_of_scope"][0]["premise"]')" \
     = "out_of_scope_premise|REFUTED|A2|token|README.md:19-21|a fee-on-transfer token credits" ] \
   && [ "$(_jq "$EJ" 'sorted(d["out_of_scope"][0].keys())')" = "['assumption', 'class', 'exploit', 'file', 'label', 'location', 'poc_sketch', 'premise', 'reason', 'severity', 'subsystem', 'verdict']" ]; then
  ok "the entry carries label, verdict REFUTED, the cited assumption {id, category, source, text} and the premise"
else
  bad "the out_of_scope entry is mis-shaped: $(_jq "$EJ" 'd.get("out_of_scope")')"
fi
if [ "$(_jq "$EJ" 'd["totals"]["out_of_scope"]')" = "1" ] && [ "$(_jq "$EJ" 'd["totals"]["candidates"]')" = "3" ] \
   && [ "$(_jq "$EJ" 'd["totals"]["verified"]')" = "1" ] && [ "$(_jq "$EJ" 'd["totals"]["errored"]')" = "0" ]; then
  ok "totals.out_of_scope = 1, a SUBSET of the implicit refuted count (3 = 1 verified + 0 errored + 2 refuted)"
else
  bad "the totals are wrong: $(_jq "$EJ" 'd["totals"]')"
fi
if cmp -s "$WORK/e-auto/scope-assumptions.txt" "$FIX/repo-tokens.golden" \
   && grep -q -- '-> OUT-OF-SCOPE (declared premise A2)' "$WORK/e-auto.vout" \
   && grep -q ', 1 out-of-scope (declared premise)' "$WORK/e-auto.vout"; then
  ok "the block is written ONCE to <out>/scope-assumptions.txt (== the golden) and the log names the routed lead"
else
  bad "the per-run block record or the OUT-OF-SCOPE log line is missing"
fi
if [ "$(grep -c '^src/Vault.sol:deposit|' "$WORK/e-auto.calls" 2>/dev/null)" = "1" ] \
   && [ "$(grep -c '^src/Vault.sol:deposit|C6|' "$WORK/e-auto.calls" 2>/dev/null)" = "0" ]; then
  ok "the routed deposit lead never reached a C6 re-read inside the gate"
else
  bad "the routed lead was re-read under C6"
fi

note "e2) NEGATIVE CONTROL: no declaration => the SAME lead stays in verified[] ..."
SEVERITY_RUBRIC=1 _vf e-abs "$TGT_ABS" --scope-docs auto
AJ="$WORK/e-abs/verified_findings.json"
if [ ! -s "$WORK/e-abs/scope-assumptions.txt" ] && grep -q 'declared no assumption — scope layer inert' "$WORK/e-abs.vout" \
   && [ "$(_jq "$AJ" '",".join(sorted(v["location"] for v in d["verified"]))')" = "src/Vault.sol:deposit,src/Vault.sol:withdraw" ] \
   && [ "$(_jq "$AJ" '"out_of_scope" in d')" = "False" ]; then
  ok "an empty block is inert: the transfer-fee lead is verified exactly as it would be without the flag"
else
  bad "the no-declaration control is wrong (verified=$(_jq "$AJ" '[v["location"] for v in d["verified"]]'))"
fi

note "e3) KNOB-OFF byte identity, and scope-without-rubric inertness ..."
_vf e-off "$TGT_TOK"
_vf e-norub "$TGT_TOK" --scope-docs auto
if [ "$(_jq "$WORK/e-off/verified_findings.json" '"out_of_scope" in d or "out_of_scope" in d["totals"] or "scope_layer" in d')" = "False" ] \
   && [ -z "$(find "$WORK/e-off" -name 'out-of-scope.tsv' -o -name 'scope-assumptions.txt' | head -1)" ]; then
  ok "flag unset: no out_of_scope / scope_layer key, no out-of-scope.tsv, no scope-assumptions.txt anywhere"
else
  bad "a flagless run grew a scope key or file"
fi
REP_DIFF=""
for r in "$WORK"/e-off/gates/*/refute-out/refute-report.md; do
  rel="${r#"$WORK"/e-off/}"
  cmp -s "$r" "$WORK/e-norub/$rel" || REP_DIFF="$REP_DIFF $rel"
done
OFF_FILES="$(cd "$WORK/e-off" && find . -type f ! -path './.verify-work/*' | sort)"
NORUB_FILES="$(cd "$WORK/e-norub" && find . -type f ! -path './.verify-work/*' ! -name scope-assumptions.txt | sort)"
# The one intended difference is the scope_layer record (the flag WAS requested); everything else must match.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("scope_layer", None); print(json.dumps(d, indent=2))' \
  "$WORK/e-norub/verified_findings.json" > "$WORK/e-norub.noscope.json" 2>/dev/null
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))' \
  "$WORK/e-off/verified_findings.json" > "$WORK/e-off.norm.json" 2>/dev/null
if cmp -s "$WORK/e-off.norm.json" "$WORK/e-norub.noscope.json" && [ -z "$REP_DIFF" ] \
   && [ "$OFF_FILES" = "$NORUB_FILES" ] \
   && [ "$(_jq "$WORK/e-norub/verified_findings.json" 'd["scope_layer"]["state"]')" = "off" ] \
   && grep -q 'SEVERITY_RUBRIC is not 1 — the scope layer is nested under the rubric and is INERT' "$WORK/e-norub.vout"; then
  ok "--scope-docs without SEVERITY_RUBRIC=1: verified_findings.json (minus scope_layer.state=off) + every refute-report.md identical to a flagless run, the only new file is the block record, and the warning is LOUD"
else
  bad "scope-without-rubric was not inert (report diffs:$REP_DIFF)"
fi
RC_BAD=0
"$VERIFY" --results "$RES" --repo "$TGT_TOK" --out "$WORK/e-bad" --scope-docs "$WORK/no-such-file.md" > /dev/null 2>&1 || RC_BAD=$?
if [ "$RC_BAD" = "2" ]; then
  ok "a --scope-docs value that is neither 'auto' nor a file is a usage error (exit 2)"
else
  bad "a bad --scope-docs exited $RC_BAD, want 2"
fi
if [ "$(_jq "$EJ" 'd["scope_layer"]["state"]')" = "on" ] && [ "$(_jq "$AJ" 'd["scope_layer"]["state"]')" = "off" ]; then
  ok "scope_layer records the layer's state whenever --scope-docs was requested (on for e1, off for the empty block of e2)"
else
  bad "scope_layer is missing or wrong (e1=$(_jq "$EJ" 'd.get("scope_layer")') e2=$(_jq "$AJ" 'd.get("scope_layer")'))"
fi

note "e3b) an EXTRACTOR ERROR fails open AND is recorded as scope_layer.state=inert-extractor-error ..."
# A throwaway dark-factory root whose scope helper crashes (exit 3), everything else symlinked to the real tree.
XERR="$WORK/xerr-root"; mkdir -p "$XERR/lib"
for e in "$HERE"/lib/*; do ln -s "$e" "$XERR/lib/$(basename "$e")"; done
rm -f "$XERR/lib/scope-assumptions.py"
printf 'import sys\nsys.stderr.write("scope-assumptions.py: simulated crash\\n")\nsys.exit(3)\n' > "$XERR/lib/scope-assumptions.py"
ln -s "$HERE/auditor" "$XERR/auditor"; ln -s "$REFUTE" "$XERR/run-refute.sh"; cp "$VERIFY" "$XERR/verify-findings.sh"
STUB_CALLS="$WORK/xerr.calls"; export STUB_CALLS; : > "$STUB_CALLS"
SEVERITY_RUBRIC=1 "$XERR/verify-findings.sh" --results "$RES" --repo "$TGT_TOK" --out "$WORK/e-xerr" --gate refute \
  --backend mock --agentis "$STUB" --scope-docs auto > "$WORK/e-xerr.vout" 2>&1; RC_XERR=$?
XJ="$WORK/e-xerr/verified_findings.json"
if [ "$RC_XERR" = "0" ] && [ "$(_jq "$XJ" 'd["scope_layer"]["state"]')" = "inert-extractor-error" ] \
   && _jq "$XJ" 'd["scope_layer"]["reason"]' | grep -q 'simulated crash' \
   && [ "$(_jq "$XJ" '"out_of_scope" in d')" = "False" ] \
   && grep -q 'WARNING: scope extraction failed' "$WORK/e-xerr.vout"; then
  ok "a crashing extractor does not abort STAGE 4, the run completes with the layer off, and verified_findings.json says why"
else
  bad "the extractor-error case is not recorded (rc=$RC_XERR scope_layer=$(_jq "$XJ" 'd.get("scope_layer")'))"
fi

note "e4) --jobs 2 parity ..."
if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 3 ]; }; then
  SEVERITY_RUBRIC=1 _vf e-par "$TGT_TOK" --scope-docs auto --jobs 2
  if cmp -s "$EJ" "$WORK/e-par/verified_findings.json"; then
    ok "--jobs 2 produces a byte-identical verified_findings.json (out_of_scope[] replayed in manifest order)"
  else
    bad "--jobs 2 diverged from the serial run"
    diff "$EJ" "$WORK/e-par/verified_findings.json" | head -6 | sed 's/^/      /' >&2
  fi
else
  skip "bash < 4.3: verify-findings.sh degrades --jobs to serial, parity is trivially true"
fi

note "e5) run-zone-hunt.sh validates --scope-docs before any stage ..."
RC_ZH=0
"$ZONEHUNT" --repo "$TGT_TOK" --out "$WORK/zh" --scope-docs "$WORK/no-such-file.md" > "$WORK/zh.out" 2>&1 || RC_ZH=$?
if [ "$RC_ZH" = "2" ] && grep -q -- "--scope-docs must be 'auto' or an existing file" "$WORK/zh.out"; then
  ok "a typo fails at argument validation (exit 2), not 40 minutes into STAGE 4"
else
  bad "run-zone-hunt.sh --scope-docs validation exited $RC_ZH"
fi

note "e6) #2292 ACCEPTANCE (gated on OUTPUT): on the contest layout the in-scope findings stay in verified[] ..."
# The stub (STUB_SCOPE=filerow) refutes a candidate IFF the staged block has a row naming its source file. So this
# reads verified_findings.json — what a hunt reports — not the block: a file row anywhere flips it.
CRES="$FIX/contest-results.json"
# _vfc <label> <verify-findings.sh> [flag...] — one offline contest-layout run.
_vfc() {
  _vfc_label="$1"; _vfc_bin="$2"; shift 2
  STUB_CALLS="$WORK/$_vfc_label.calls"; export STUB_CALLS; : > "$STUB_CALLS"
  SEVERITY_RUBRIC=1 STUB_SCOPE=filerow "$_vfc_bin" --results "$CRES" --repo "$CT/target" --out "$WORK/$_vfc_label" \
    --gate refute --backend mock --agentis "$STUB" "$@" > "$WORK/$_vfc_label.vout" 2>&1 || true
}
_vfc e-cauto "$VERIFY" --scope-docs auto
_vfc e-cop "$VERIFY" --scope-docs "$CT/README.md"
_vfc e-cmap "$VERIFY" --scope-docs auto --scope-map "$FIX/scope-map.tsv"
CWANT="src/Vault.sol:withdraw,src/tokens/Wrapper.sol:wrap"
for lbl in e-cauto e-cop e-cmap; do
  CJ="$WORK/$lbl/verified_findings.json"
  if [ "$(_jq "$CJ" '",".join(sorted(v["location"] for v in d["verified"]))')" = "$CWANT" ] \
     && [ "$(_jq "$CJ" '"out_of_scope" in d')" = "False" ] && [ "$(_jq "$CJ" 'd["scope_layer"]["state"]')" = "on" ]; then
    ok "$lbl: both in-scope findings are in verified[], out_of_scope is absent, and the scope layer was ON (a real block was staged)"
  else
    bad "$lbl: an in-scope finding was lost (verified=$(_jq "$CJ" '[v["location"] for v in d["verified"]]') out_of_scope=$(_jq "$CJ" 'd.get("out_of_scope")') scope_layer=$(_jq "$CJ" 'd.get("scope_layer")'))"
    tail -4 "$WORK/$lbl.vout" | sed 's/^/      /' >&2
  fi
done
if grep -qF "verify-findings.sh: $CT_ERR_WANT" "$WORK/e-cop.vout" && ! grep -q 'operator file' "$WORK/e-cauto.vout"; then
  ok "the extractor's skip-count line is relayed into the run log (operator mode only)"
else
  bad "the dropped-bullet count never reached the verify-findings.sh log"
fi
if _jq "$WORK/e-cauto/verified_findings.json" 'd["scope_layer"]["reason"]' | grep -q 'in-scope-file guard NOT armed (no --scope-map)' \
   && _jq "$WORK/e-cmap/verified_findings.json" 'd["scope_layer"]["reason"]' | grep -q 'in-scope-file guard armed (--scope-map)' \
   && grep -q 'no --scope-map' "$WORK/e-cauto.vout"; then
  ok "scope_layer.reason says whether the in-scope-file guard is armed (a silently inert guard is the #1426 trap)"
else
  bad "scope_layer.reason does not record the --scope-map state"
fi
RC_VMAP=0
"$VERIFY" --results "$CRES" --repo "$CT/target" --out "$WORK/e-badmap" --scope-docs auto --scope-map "$WORK/no-such-map.tsv" > /dev/null 2>&1 || RC_VMAP=$?
if [ "$RC_VMAP" = "2" ]; then
  ok "a --scope-map that does not exist is a usage error (exit 2) before any side effect"
else
  bad "a bad --scope-map exited $RC_VMAP, want 2"
fi

# ==========================================================================================================
# PART f — MUTATION RESISTANCE (mutated COPIES; the shipped files are never touched)
# ==========================================================================================================
MUT="$WORK/mut"
# _mutdir <name> — a throwaway dark-factory root: symlinks to everything, with the files a mutant replaces copied.
_mutdir() {
  _md="$MUT/$1"; mkdir -p "$_md/lib"
  for e in "$HERE"/lib/*; do ln -s "$e" "$_md/lib/$(basename "$e")"; done
  ln -s "$HERE/auditor" "$_md/auditor"
  cp "$REFUTE" "$_md/run-refute.sh"; cp "$VERIFY" "$_md/verify-findings.sh"
  printf '%s\n' "$_md"
}
# _mutate <file> <python-literal-old> <python-literal-new> — exact-substring replacement; prints CHANGED or SAME.
_mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if old in s:
    open(p, "w").write(s.replace(old, new))
    print("CHANGED")
else:
    print("SAME")
PY
}
_mut_lib() {
  _ml_dir="$(_mutdir "$1")"; rm -f "$_ml_dir/lib/scope-assumptions.py"; cp "$LIB" "$_ml_dir/lib/scope-assumptions.py"
  printf '%s\n' "$_ml_dir"
}

note "f1) drop the premise check -> the premise-unresolved fixture must flip ..."
M1="$(_mut_lib m1)"
if [ "$(_mutate "$M1/lib/scope-assumptions.py" '    if norm(p.group(1)) not in norm(claim):
        return fail("scope-premise-unresolved")
' '')" = "CHANGED" ]; then
  G1="$(python3 "$M1/lib/scope-assumptions.py" check --block "$BLOCK" --claim "$CLAIM_DEP" --evidence 'A2:"Standard ERC20 only. No fee-on-transfer" premise:"a rebasing token shrinks"' | cut -f1)"
  if [ "$G1" = "ok" ]; then ok "mutant without the premise check accepts a premise the claim never made (the fixture flips)"; else bad "the premise-check mutant did not flip ($G1)"; fi
else
  bad "mutation 1 did not apply (decider reshaped?)"
fi

note "f2) drop id resolution -> the cross-row quote fixture must flip ..."
M2="$(_mut_lib m2)"
if [ "$(_mutate "$M2/lib/scope-assumptions.py" 'if rid not in rows or norm(m.group(2)) not in norm(rows[rid][2]):' 'if rid not in rows:')" = "CHANGED" ]; then
  G2="$(python3 "$M2/lib/scope-assumptions.py" check --block "$BLOCK" --claim "$CLAIM_DEP" --evidence 'A1:"Standard ERC20 only. No fee-on-transfer" premise:"a fee-on-transfer token credits"' | cut -f1)"
  if [ "$G2" = "ok" ]; then ok "mutant without quote-in-row resolution accepts A2's text cited as A1 (the fixture flips)"; else bad "the resolution mutant did not flip ($G2)"; fi
else
  bad "mutation 2 did not apply"
fi

note "f3) make trust citable -> the trust fixture must flip ..."
M3="$(_mut_lib m3)"
if [ "$(_mutate "$M3/lib/scope-assumptions.py" '    if cat == "trust":
        return fail("scope-not-citable")
' '')" = "CHANGED" ]; then
  G3="$(python3 "$M3/lib/scope-assumptions.py" check --block "$BLOCK" --claim "$CLAIM_FEE" --evidence 'A3:"The admin is a trusted multisig" premise:"the admin can set the fee"' | cut -f1)"
  if [ "$G3" = "ok" ]; then ok "mutant with citable trust rows lets 'the admin is trusted' kill an admitted-parameter claim (the fixture flips)"; else bad "the trust mutant did not flip ($G3)"; fi
else
  bad "mutation 3 did not apply"
fi

note "f4) route out-of-scope into verified[] -> the e1 fixture must flip ..."
M4="$(_mutdir m4)"
# shellcheck disable=SC2016  # literal source text of the mutated copy
if [ "$(_mutate "$M4/verify-findings.sh" '"$cc_verd" "$cc_reason" "$cc_oos" >> "$OOS_TSV"' '"$cc_verd" "$cc_reason" "$cc_oos" >> "$CONFIRMED_TSV"')" = "CHANGED" ]; then
  STUB_CALLS="$WORK/m4.calls"; export STUB_CALLS; : > "$STUB_CALLS"
  SEVERITY_RUBRIC=1 "$M4/verify-findings.sh" --results "$RES" --repo "$TGT_TOK" --out "$WORK/m4-out" --gate refute \
    --backend mock --agentis "$STUB" --scope-docs auto > /dev/null 2>&1 || true
  if [ "$(_jq "$WORK/m4-out/verified_findings.json" '"src/Vault.sol:deposit" in [v["location"] for v in d["verified"]]')" = "True" ]; then
    ok "mutant routing into confirmed.tsv puts the out-of-scope lead in verified[] (the fixture flips)"
  else
    bad "the routing mutant did not flip"
  fi
else
  bad "mutation 4 did not apply"
fi

note "f5) remove the C6 skip -> the acceptance fixture must flip ..."
M5="$(_mutdir m5)"
# shellcheck disable=SC2016  # literal source text of the mutated copy
if [ "$(_mutate "$M5/run-refute.sh" 'if [ "$VERD" = "REFUTED" ] && [ -z "$SCOPE_OOS_ROW" ]; then
    FB=' 'if [ "$VERD" = "REFUTED" ]; then
    FB=')" = "CHANGED" ]; then
  STUB_CALLS="$WORK/m5.calls"; export STUB_CALLS; : > "$STUB_CALLS"
  SEVERITY_RUBRIC=1 "$M5/run-refute.sh" --candidates "$WORK/c-dep.tsv" --code-dir "$FIX/repo-tokens" --backend mock \
    --agentis "$STUB" --out "$WORK/m5-out" --scope-assumptions "$TOKBLOCK" > /dev/null 2>&1 || true
  if [ "$(_c6calls "$WORK/m5.calls")" = "1" ]; then
    ok "mutant without the skip re-reads the routed lead under C6 (the fixture flips)"
  else
    bad "the C6-skip mutant did not flip"
  fi
else
  bad "mutation 5 did not apply"
fi

note "f6) #2292: restore the 'exclusion' fallback -> the a2 fixture must flip ..."
M6="$(_mut_lib m6)"
if [ "$(_mutate "$M6/lib/scope-assumptions.py" '        cat = section or classify(text)
        if not cat:' '        cat = section or classify(text) or "exclusion"
        if not cat:')" = "CHANGED" ]; then
  python3 "$M6/lib/scope-assumptions.py" extract --repo "$FIX/repo-tokens" --operator "$FIX/operator/scope-assumptions.md" > "$WORK/m6.out" 2>/dev/null
  if grep -q '|exclusion|scope-assumptions.md:[0-9]*|A single bullet with no keyword' "$WORK/m6.out"; then
    ok "mutant with the fallback turns a heading-less, keyword-less bullet back into a citable exclusion (the fixture flips)"
  else
    bad "the fallback mutant did not flip"
  fi
else
  bad "mutation 6 did not apply (operator parser reshaped?)"
fi

note "f7) #2292: drop the operator source-file skip -> the e6 OUTPUT must flip ..."
M7="$(_mut_lib m7)"
if [ "$(_mutate "$M7/lib/scope-assumptions.py" '        if SOURCE_FILE_RE.search(text):
            n_file += 1
            continue
        cat = section or classify(text)' '        cat = section or classify(text)')" = "CHANGED" ]; then
  _vfc m7-out "$M7/verify-findings.sh" --scope-docs "$CT/README.md"
  M7J="$WORK/m7-out/verified_findings.json"
  if [ "$(_jq "$M7J" '",".join(sorted(v["location"] for v in d["verified"]))')" = "src/Vault.sol:withdraw" ] \
     && [ "$(_jq "$M7J" '",".join(v["location"]+"/"+v["assumption"]["category"] for v in d.get("out_of_scope", []))')" = "src/tokens/Wrapper.sol:wrap/token" ]; then
    ok "mutant without the skip mints a 'token' row from the tokens/ PATH and the in-scope finding leaves verified[] (verified_findings.json flips)"
  else
    bad "the source-file-skip mutant did not flip the output (verified=$(_jq "$M7J" '[v["location"] for v in d["verified"]]'))"
  fi
else
  bad "mutation 7 did not apply"
fi

note "f8) #2292: drop the scope-map contract -> the b4 fixture must flip ..."
M8="$(_mut_lib m8)"
if [ "$(_mutate "$M8/lib/scope-assumptions.py" '    if cat == "exclusion" and names_scope_file(text, scope_files):
        return fail("scope-cite-in-scope-file")
' '')" = "CHANGED" ]; then
  G8="$(python3 "$M8/lib/scope-assumptions.py" check --block "$LEG" --claim "$CLAIM_DEP" --evidence "A1:\"target/src/Vault.sol\" $PREM" --scope-map "$SMAP" | cut -f1)"
  if [ "$G8" = "ok" ]; then ok "mutant without the contract lets a file-list row dismiss a finding in that file (the fixture flips)"; else bad "the scope-map mutant did not flip ($G8)"; fi
else
  bad "mutation 8 did not apply"
fi

note "f9) #2292: drop the parent binding -> the unbound-parent fixture must flip ..."
M9="$(_mut_lib m9)"
if [ "$(_mutate "$M9/lib/scope-assumptions.py" '        if not any(binding.search(line) for line in lines):
            continue
' '')" = "CHANGED" ]; then
  python3 "$M9/lib/scope-assumptions.py" extract --repo "$WORK/ct-unbound/target" > "$WORK/m9.out" 2>/dev/null
  if grep -q '|exclusion|\.\./README\.md:[0-9]*|Findings in the legacy migration tooling' "$WORK/m9.out"; then
    ok "mutant without the binding reads an UNRELATED parent README and stages its exclusion (the fixture flips)"
  else
    bad "the parent-binding mutant did not flip"
  fi
else
  bad "mutation 9 did not apply"
fi

# ==========================================================================================================
# PART g — LIVE UNDER MOCK (the AGENT half; needs the agentis binary)
# ==========================================================================================================
if ! command -v agentis >/dev/null 2>&1; then
  note "g) live-under-mock sentinel + byte-length probe ..."
  skip "no agentis binary on PATH — the real refuter cell and the extracted-helper probe cannot run"
else
  note "g1) a real mock refuter cell prints the sentinel ONLY with the rubric on AND a non-empty block ..."
  # _live <label> <block-or-empty> — one real `agentis go refuter.ag` through run-refute.sh (mock backend, no LLM).
  _live() {
    _l_label="$1"; _l_block="$2"
    if [ -n "$_l_block" ]; then
      DF_AGENT_MAX_ATTEMPTS=1 "$REFUTE" --candidates "$WORK/c-dep.tsv" --code-dir "$FIX/repo-tokens" --backend mock \
        --agentis agentis --out "$WORK/$_l_label" --scope-assumptions "$_l_block" > "$WORK/$_l_label.rout" 2>&1 || true
    else
      DF_AGENT_MAX_ATTEMPTS=1 "$REFUTE" --candidates "$WORK/c-dep.tsv" --code-dir "$FIX/repo-tokens" --backend mock \
        --agentis agentis --out "$WORK/$_l_label" > "$WORK/$_l_label.rout" 2>&1 || true
    fi
    printf '%s\n' "$WORK/$_l_label/run/refute_src_Vault_sol_deposit.log"
  }
  L_ON="$(SEVERITY_RUBRIC=1 _live g-on "$TOKBLOCK")"
  L_NOBLK="$(SEVERITY_RUBRIC=1 _live g-noblk "")"
  L_NORUB="$(_live g-norub "$TOKBLOCK")"
  if [ ! -f "$L_ON" ] || [ ! -f "$L_NOBLK" ] || [ ! -f "$L_NORUB" ]; then
    bad "a mock refuter cell produced no log (run-refute.sh did not reach refuter.ag)"
    tail -5 "$WORK/g-on.rout" 2>/dev/null | sed 's/^/      /' >&2
  else
    if grep -q '^SCOPE-ASSUMPTIONS|refute|on$' "$L_ON" && grep -q '^SEVERITY-RUBRIC|refute|on$' "$L_ON"; then
      ok "rubric ON + block: the sentinel fired end-to-end (--scope-assumptions -> env_passthrough -> getenv -> cat_file -> marker in the prompt)"
    else
      bad "rubric ON + block: NO SCOPE-ASSUMPTIONS| sentinel — the block never reached refuter.ag"
    fi
    if grep -q 'SCOPE-ASSUMPTIONS|' "$L_NOBLK" || grep -q 'SCOPE-ASSUMPTIONS|' "$L_NORUB"; then
      bad "the sentinel appeared without the rubric or without a block — the layer is not nested/default-OFF"
    else
      ok "rubric ON without a block, and a block with the rubric OFF: NO sentinel (nested, default OFF)"
    fi
  fi

  note "g2) byte-length probe over the EXTRACTED helpers: 0 bytes under every other combination ..."
  SB="$WORK/probe"; mkdir -p "$SB"
  ( cd "$SB" && agentis init >/dev/null 2>&1 ) || true
  printf 'exec.env_passthrough = SEVERITY_RUBRIC,SCOPE_ASSUMPTIONS_PATH\n' > "$SB/.agentis/config"
  cp "$TOKBLOCK" "$SB/block.txt"; : > "$SB/empty.txt"
  {
    printf 'cb 300000;\n\n'
    for fn in cat_file severity_rubric_enabled scope_assumptions_marker scope_assumptions_directive; do
      _agfn "$REFUTER" "$fn"; printf '\n'
    done
    printf 'let d = scope_assumptions_directive();\n'
    printf 'print("DIRLEN=" + to_string(len(d)));\n'
    printf 'print("MARKERAT=" + to_string(index_of(d, scope_assumptions_marker())));\n'
    printf 'print("ROWAT=" + to_string(index_of(d, "A2|token|README.md:19-21|")));\n'
  } > "$SB/probe.ag"
  # _probe <rubric|""> <path|""> -> "DIRLEN MARKERAT ROWAT"
  _probe() {
    _p_out="$( cd "$SB" && env ${1:+SEVERITY_RUBRIC="$1"} ${2:+SCOPE_ASSUMPTIONS_PATH="$2"} agentis go probe.ag --enable-exec --grant-pii 2>&1 )"
    printf '%s %s %s\n' "$(printf '%s\n' "$_p_out" | sed -n 's/^DIRLEN=//p' | tail -1)" \
      "$(printf '%s\n' "$_p_out" | sed -n 's/^MARKERAT=//p' | tail -1)" \
      "$(printf '%s\n' "$_p_out" | sed -n 's/^ROWAT=//p' | tail -1)"
  }
  P_ON="$(_probe 1 "$SB/block.txt")"
  P_UNSET="$(_probe "" "")"
  P_RUB_ONLY="$(_probe 1 "")"
  P_BLK_ONLY="$(_probe "" "$SB/block.txt")"
  P_ZERO="$(_probe 0 "$SB/block.txt")"
  P_EMPTY="$(_probe 1 "$SB/empty.txt")"
  # shellcheck disable=SC2086  # word-splitting the three-number probe answer is the point
  set -- $P_ON
  if [ "${1:-0}" -gt 0 ] 2>/dev/null && [ "${2:-}" = "0" ] && [ "${3:--1}" -gt 0 ] 2>/dev/null; then
    ok "rubric ON + block: the directive is $1 bytes, opens with its marker and carries the rows verbatim"
  else
    bad "rubric ON + block probe is wrong ('$P_ON')"
  fi
  ZERO_BAD=""
  for pair in "unset:$P_UNSET" "rubric-only:$P_RUB_ONLY" "block-only:$P_BLK_ONLY" "rubric=0:$P_ZERO" "empty-block:$P_EMPTY"; do
    case "${pair#*:}" in "0 "*) ;; *) ZERO_BAD="$ZERO_BAD ${pair%%:*}(${pair#*:})" ;; esac
  done
  if [ -z "$ZERO_BAD" ]; then
    ok "0 bytes with both unset, rubric only, block only, SEVERITY_RUBRIC=0 + block, and an empty block — byte-identical prompts"
  else
    bad "a knob-OFF combination rendered bytes:$ZERO_BAD"
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "ALL ASSERTIONS HELD — scope-aware refute (#2257): a deterministic line-cited block, one extra ground with its"
  note "own citation contract, trust rows context-only, nested under SEVERITY_RUBRIC=1, final routing into"
  note "out_of_scope[] (never verified[]), default OFF and byte-identical when unset. #2292: no row names a source"
  note "file (operator skip before classification, no exclusion fallback, the scope-map contract, the bound parent doc)."
  note "NOTE: nothing above is a precision claim — that needs a new fresh set in a separate run."
  exit 0
fi
note "$FAILS assertion(s) FAILED"
exit 1
