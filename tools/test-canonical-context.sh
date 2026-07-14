#!/bin/bash
# tools/test-canonical-context.sh: drift sentinel + fixture pins for the
# shared canonical-context builder (#1431).
#
# tools/lib/canonical-context.py must emit byte-identical condition strings
# to the inline builders in triage/agents/{labeler,router,prioritizer}.ag —
# otherwise backfilled rules are unreachable from Stage 1 prefix replay and
# Stage 1b BM25 class-confirm. Two layers:
#
#   1. VOCAB drift: the keyword vocabulary literal in the python helper must
#      equal the inline VOCAB literal in EACH agent byte-for-byte (the
#      agents' literals are themselves asserted mutually identical).
#   2. Pinned fixture outputs: known raw issues (GitLab and GitHub shapes)
#      must produce the exact pinned ctx/coarse/action strings for each
#      class, including the priority-like exclusion and scope semantics.
#
# Usage: ./tools/test-canonical-context.sh
# Exit code 0 if all assertions pass, 1 otherwise.

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FED="$REPO_ROOT/dev-apprenticeship"
CANON="$REPO_ROOT/tools/lib/canonical-context.py"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# ----- 1. VOCAB drift (#1638 P3 cluster A) -----
# The inline python `VOCAB=["bug",...]` literal is gone; the three .ag builders
# now feed the native token_hits(text, vocab) builtin a comma-list constant
# triage_vocab_csv(). Assert (a) that constant is byte-identical across the three
# files and (b) it decodes (comma-split) to the same 26 words as
# tools/lib/canonical-context.py VOCAB — otherwise backfilled rules are
# unreachable from Stage 1 prefix replay / Stage 1b BM25 class-confirm.
PY_VOCAB_CSV="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cc", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(",".join(mod.VOCAB))
' "$CANON")"

# Extract the single-line `return "...";` body of fn triage_vocab_csv().
extract_vocab_csv() {
    awk '/fn triage_vocab_csv\(\)/{f=1} f&&/return/{print; exit}' "$1" \
        | sed -E 's/.*return "([^"]*)";.*/\1/'
}

CSV_REF=""
for agent in labeler router prioritizer; do
    AG="$FED/triage/agents/$agent.ag"
    CSV="$(extract_vocab_csv "$AG")"
    if [ -z "$CSV" ]; then
        fail "$agent: triage_vocab_csv() constant not found"
        continue
    fi
    if [ -z "$CSV_REF" ]; then CSV_REF="$CSV"; fi
    if [ "$CSV" != "$CSV_REF" ]; then
        fail "$agent: triage_vocab_csv() drift vs labeler — '$CSV'"
    elif [ "$CSV" = "$PY_VOCAB_CSV" ]; then
        pass "$agent: triage_vocab_csv() matches canonical-context.py VOCAB"
    else
        fail "$agent: triage_vocab_csv() != canonical-context.py VOCAB — agent='$CSV' helper='$PY_VOCAB_CSV'"
    fi
done

# ----- 2. Pinned fixture outputs -----

FIX_DIR="$(mktemp -d)"
trap 'rm -rf "$FIX_DIR"' EXIT

# GitLab-shaped: labeled + assigned + prioritized, author == operator.
cat > "$FIX_DIR/gl.json" <<'JSON'
{"iid": 7, "title": "Crash: segfault in parser build",
 "description": "It fails with panic",
 "labels": ["bug", "P1"],
 "assignees": [{"username": "alice"}],
 "author": {"username": "mholy"},
 "updated_at": "2026-07-01T10:00:00Z"}
JSON

# GitHub-shaped: label objects, no assignee, no priority-like label.
cat > "$FIX_DIR/gh.json" <<'JSON'
{"number": 12, "title": "Update docs for CI", "body": "",
 "labels": [{"name": "documentation"}],
 "assignees": [],
 "user": {"login": "bob"},
 "updated_at": "2026-07-02T10:00:00Z"}
JSON

run_issue() {
    local klass="$1" file="$2"
    ME="mholy" PV="priority::critical, priority::high, P1, P2" \
        python3 "$CANON" issue --class "$klass" < "$file"
}

assert_line() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        pass "$desc"
    else
        fail "$desc — got '$got' want '$want'"
    fi
}

# label class, GitLab fixture: keyword hits from title+description
# (build, crash, panic, segfault — "fails" does NOT match "fail": exact
# token membership, mirrors the agents' `w in toks`), personal scope
# (author == ME), action excludes the priority-like P1.
assert_line "label/gl pinned output" \
    "$(run_issue label "$FIX_DIR/gl.json")" \
    "$(printf '7\tkw=build,crash,panic,segfault scope=personal\tkw=build,crash,panic,segfault\tbug\tCrash: segfault in parser build It fails with panic')"

# route class, GitLab fixture: keywords from title only, ALL labels in ctx
# (sorted; ASCII P1 < bug), action = first assignee.
assert_line "route/gl pinned output" \
    "$(run_issue route "$FIX_DIR/gl.json")" \
    "$(printf '7\tkw=build,crash,segfault labels=P1,bug\tkw=build,crash,segfault\talice\tCrash: segfault in parser build P1 bug')"

# prioritize class, GitLab fixture: ctx carries only NON-priority labels,
# action = the priority-like label.
assert_line "prioritize/gl pinned output" \
    "$(run_issue prioritize "$FIX_DIR/gl.json")" \
    "$(printf '7\tkw=build,crash,segfault labels=bug\tkw=build,crash,segfault\tP1\tCrash: segfault in parser build bug')"

# label class, GitHub fixture: label-object normalization, team scope.
assert_line "label/gh pinned output" \
    "$(run_issue label "$FIX_DIR/gh.json")" \
    "$(printf '12\tkw=ci,docs scope=team\tkw=ci,docs\tdocumentation\tUpdate docs for CI')"

# Undecided cases emit nothing.
assert_line "route/gh undecided (no assignee) emits nothing" \
    "$(run_issue route "$FIX_DIR/gh.json")" ""
assert_line "prioritize/gh undecided (no priority-like label) emits nothing" \
    "$(run_issue prioritize "$FIX_DIR/gh.json")" ""

# ----- 3. triples mode: --since filter + --max + cursor -----

{
    printf '['
    cat "$FIX_DIR/gl.json"
    printf ','
    cat "$FIX_DIR/gh.json"
    printf ']'
} > "$FIX_DIR/all.json"

TRIPLES="$(ME="mholy" PV="P1" python3 "$CANON" triples \
    --classes label,route,prioritize --max 10 \
    --cursor-out "$FIX_DIR/cursor" < "$FIX_DIR/all.json")"
N_ALL="$(printf '%s\n' "$TRIPLES" | grep -c . || true)"
# gl: label + route + prioritize = 3; gh: label only = 1.
assert_line "triples mode emits 4 triples for the 2-issue fixture" "$N_ALL" "4"
assert_line "cursor-out carries the max updated_at" \
    "$(cat "$FIX_DIR/cursor")" "2026-07-02T10:00:00Z"

TRIPLES_SINCE="$(ME="mholy" PV="P1" python3 "$CANON" triples \
    --classes label --since "2026-07-01T10:00:00Z" < "$FIX_DIR/all.json")"
N_SINCE="$(printf '%s\n' "$TRIPLES_SINCE" | grep -c . || true)"
assert_line "--since strictly-greater filter drops the older issue" "$N_SINCE" "1"

# ----- 4. --order oldest + --max: monotonic incremental cursor -----
# The incremental caller (backfill-crystallizer.sh --incremental) MUST use
# oldest-first: with newest-first, a window holding more than --max issues
# would advance the cursor past the un-processed older tail and skip it
# forever. With --order oldest --max 1 on the 2-issue fixture, the OLDER
# issue (gl, 2026-07-01) is processed and the cursor lands on ITS
# timestamp — not on the newest issue's — so the next run picks up gh.
TRIPLES_OLD="$(ME="mholy" PV="P1" python3 "$CANON" triples \
    --classes label --max 1 --order oldest \
    --cursor-out "$FIX_DIR/cursor-old" < "$FIX_DIR/all.json")"
assert_line "--order oldest --max 1 processes the older issue first" \
    "$(printf '%s\n' "$TRIPLES_OLD" | grep -c '"iid": 7' || true)" "1"
assert_line "oldest-first cursor stays at the processed slice's max (monotonic)" \
    "$(cat "$FIX_DIR/cursor-old")" "2026-07-01T10:00:00Z"

# ----- 5. #1435: empty-keyword issues never mint a "kw=" condition -----
# A title with no VOCAB word ("Add dark mode toggle") would distill the
# bare "kw=" coarse condition, which prefix-matches EVERY context of the
# class once crystallized. The builder must skip such issues for ALL
# classes (the agents guard the same way at their distill sites).
cat > "$FIX_DIR/nokw.json" <<'JSON'
{"iid": 20, "title": "Add dark mode toggle", "description": "",
 "labels": ["ui", "P2"],
 "assignees": [{"username": "carol"}],
 "author": {"username": "mholy"},
 "updated_at": "2026-07-03T10:00:00Z"}
JSON

assert_line "#1435 label class skips an empty-keyword issue" \
    "$(run_issue label "$FIX_DIR/nokw.json")" ""
assert_line "#1435 route class skips an empty-keyword issue" \
    "$(run_issue route "$FIX_DIR/nokw.json")" ""
assert_line "#1435 prioritize class skips an empty-keyword issue" \
    "$(run_issue prioritize "$FIX_DIR/nokw.json")" ""

# ----- 6. #1436: is_pri is exact vocab membership, not substring -----
# The old `l2 in pv` substring test classified fragment labels as
# priority-like ("it" ⊂ "priority", "cal" ⊂ "critical", "block" ⊂ a
# free-text "blocker"), corrupting issue selection, context splitting and
# backfilled actions. Membership over the comma-split vocab set fixes it;
# the deterministic rules (priority* / ^P<digits>$ / urgent) are unchanged.
run_issue_pv() {
    local klass="$1" file="$2" pv="$3"
    ME="mholy" PV="$pv" python3 "$CANON" issue --class "$klass" < "$file"
}

DEFAULT_PV="priority::critical, priority::high, priority::medium, priority::low, P1, P2, P3, P4, urgent"

cat > "$FIX_DIR/it.json" <<'JSON'
{"iid": 30, "title": "Crash in parser", "description": "",
 "labels": ["it"],
 "assignees": [],
 "author": {"username": "bob"},
 "updated_at": "2026-07-04T10:00:00Z"}
JSON

# "it" is a substring of "priority" — pre-#1436 it was misclassified as a
# priority label, so the prioritize class treated the issue as already
# prioritized (bogus action "it") and the label class dropped "it" from
# its action. Post-fix: not priority-like.
assert_line "#1436 'it' label is NOT priority-like (prioritize emits nothing)" \
    "$(run_issue_pv prioritize "$FIX_DIR/it.json" "$DEFAULT_PV")" ""
assert_line "#1436 'it' label stays in the label-class action" \
    "$(run_issue_pv label "$FIX_DIR/it.json" "$DEFAULT_PV")" \
    "$(printf '30\tkw=crash scope=team\tkw=crash\tit\tCrash in parser')"

# Explicit membership still works: an operator listing bare "high" in the
# vocab makes it priority-like — exactly, not accidentally.
cat > "$FIX_DIR/high.json" <<'JSON'
{"iid": 31, "title": "Crash in parser", "description": "",
 "labels": ["high", "bug"],
 "assignees": [],
 "author": {"username": "bob"},
 "updated_at": "2026-07-04T11:00:00Z"}
JSON
assert_line "#1436 explicit vocab entry 'high' IS priority-like (action = high)" \
    "$(run_issue_pv prioritize "$FIX_DIR/high.json" "high, low")" \
    "$(printf '31\tkw=crash labels=bug\tkw=crash\thigh\tCrash in parser bug')"
assert_line "#1436 'high' is NOT priority-like under the default vocab" \
    "$(run_issue_pv prioritize "$FIX_DIR/high.json" "$DEFAULT_PV")" ""

# Free-text vocab fragments no longer leak: "block" must not match a
# vocab containing "blocker".
cat > "$FIX_DIR/block.json" <<'JSON'
{"iid": 32, "title": "Crash in parser", "description": "",
 "labels": ["block", "blocker"],
 "assignees": [],
 "author": {"username": "bob"},
 "updated_at": "2026-07-04T12:00:00Z"}
JSON
assert_line "#1436 free-text vocab: 'blocker' matches, fragment 'block' does not" \
    "$(run_issue_pv prioritize "$FIX_DIR/block.json" "blocker, important")" \
    "$(printf '32\tkw=crash labels=block\tkw=crash\tblocker\tCrash in parser block')"

# Drift guard: prioritizer.ag now carries ZERO inline python. #1638 P3 cluster A
# retired canonical_priority_context's python (2 -> 1) and cluster B2 retired the
# last one — score_priority_verdict_key's reality-check pv_set (1 -> 0), which is
# now a native regex_find_all(PRISET) compare. The tokenized pv form survives only
# in the out-of-scope library backfill (canonical-context.py, checked below).
PRI_AG_FILE="$FED/triage/agents/prioritizer.ag"
PV_SET_COUNT="$(grep -c 'pv_set={t.strip() for t in pv.split' "$PRI_AG_FILE" || true)"
assert_line "#1638 B2 prioritizer.ag carries zero inline python pv_set sites" \
    "$PV_SET_COUNT" "0"
if grep -q 'def pv_tokens(pv):' "$CANON"; then
    pass "#1436 canonical-context.py carries pv_tokens()"
else
    fail "#1436 canonical-context.py missing pv_tokens()"
fi

# ----- 7. #1638 P3 cluster A: native builders byte-identical to the retired
# python one-liners (agentis go). -----
# canonical_{label,route,priority}_context are now native `.ag` (embedded
# `python3 -c` removed). Their ctx+iid feed the crystallizer KnowledgeEntry id,
# so each must be byte-identical to the retired one-liner on every fixture.
# We drive the REAL .ag functions via `agentis go` (the #1613 / adv_parse
# precedent — no hand-kept oracle can drift from the shipped path) and match
# stdout against pinned expected values. Skipped when agentis is absent.
if command -v agentis >/dev/null 2>&1; then
    AG_TMP="$(mktemp -d)"
    (cd "$AG_TMP" && agentis init) >/dev/null 2>&1

    # Pull one top-level `fn NAME(...) { ... }` verbatim (closing `}` at col 0).
    extract_fn() {
        awk -v n="$2" 'BEGIN{p="^fn "n"\\("} $0 ~ p {f=1} f{print} /^}/{if(f) f=0}' "$1"
    }
    # A raw JSON string -> a valid `.ag` double-quoted literal.
    aglit() { python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'; }

    COMMON_FNS="triage_vocab_csv void_to_empty joinc joins str_replace_all ws_to_space dedupe_space collapse row_index"

    # run_builder <agent.ag> <extra-fns> <call-expr>
    run_builder() {
        local file="$1" extra="$2" expr="$3" fn
        {
            echo "cb 5000;"
            for fn in $COMMON_FNS $extra; do extract_fn "$file" "$fn"; echo; done
            echo "print($expr);"
        } > "$AG_TMP/probe.ag"
        (cd "$AG_TMP" && agentis go probe.ag 2>/dev/null) | grep -v '^\[genesis\]'
    }

    LBL="$FED/triage/agents/labeler.ag"
    RTR="$FED/triage/agents/router.ag"
    PRI="$FED/triage/agents/prioritizer.ag"

    ag_label() { local j; j="$(printf '%s' "$1" | aglit)"; run_builder "$LBL" "canonical_label_context" "canonical_label_context($j, \"$2\")"; }
    ag_route() { local j; j="$(printf '%s' "$1" | aglit)"; run_builder "$RTR" "canonical_route_context" "canonical_route_context($j)"; }
    ag_pri()   { local j p; j="$(printf '%s' "$1" | aglit)"; p="$(printf '%s' "$2" | aglit)"; run_builder "$PRI" "member is_pri regex_escape pvalt canonical_priority_context" "canonical_priority_context($j, $p)"; }

    # --- labeler ---
    assert_line "AG label: personal scope + sorted kw" \
        "$(ag_label '[{"iid":7,"title":"Crash: segfault in parser build","description":"It fails with panic","labels":[],"author":{"username":"mholy"}}]' "mholy")" \
        "$(printf '7\tmholy\tkw=build,crash,panic,segfault scope=personal\tCrash: segfault in parser build It fails with panic')"
    assert_line "AG label: team scope (author != me)" \
        "$(ag_label '[{"iid":7,"title":"Crash: segfault in parser build","description":"It fails with panic","labels":[],"author":{"username":"mholy"}}]' "alice")" \
        "$(printf '7\tmholy\tkw=build,crash,panic,segfault scope=team\tCrash: segfault in parser build It fails with panic')"
    assert_line "AG label: all labeled -> empty" \
        "$(ag_label '[{"iid":7,"title":"bug","labels":["x"],"author":{"username":"mholy"}}]' "mholy")" ""
    assert_line "AG label: non-list raw -> empty" \
        "$(ag_label '{"iid":7}' "mholy")" ""
    assert_line "AG label: missing iid -> empty" \
        "$(ag_label '[{"title":"bug crash","labels":[]}]' "mholy")" ""
    # exact 26-word vocab hit set, lexicographic kw= (empty ME -> team scope).
    assert_line "AG label: full 26-word vocab hits sorted" \
        "$(ag_label '[{"iid":9,"title":"docs readme feature ci build test bug crash error fail segfault panic exception documentation enhancement request question security vuln cve performance perf slow regression refactor dependency","labels":[],"author":{"username":"z"}}]' "")" \
        "$(printf '9\tz\tkw=bug,build,ci,crash,cve,dependency,docs,documentation,enhancement,error,exception,fail,feature,panic,perf,performance,question,readme,refactor,regression,request,security,segfault,slow,test,vuln scope=team\tdocs readme feature ci build test bug crash error fail segfault panic exception documentation enhancement request question security vuln cve performance perf slow regression refactor dependency')"
    # whitespace collapse: a tab and a newline in the title -> single spaces.
    assert_line "AG label: whitespace collapse (tab+newline+runs)" \
        "$(ag_label '[{"iid":5,"title":"bug\tcrash  \n build","description":"","labels":[],"author":{"username":"mholy"}}]' "mholy")" \
        "$(printf '5\tmholy\tkw=bug,build,crash scope=personal\tbug crash build')"
    # [:1200] byte truncation.
    TRUNC_JSON="$(python3 -c 'import json; print(json.dumps([{"iid":11,"title":"bug "*400,"description":"","labels":[],"author":{"username":"z"}}]))')"
    TRUNC_Q="$(python3 -c 'import re; print(re.sub(r"\s+"," ",("bug "*400)+" ").strip()[:1200])')"
    assert_line "AG label: q truncated to 1200 bytes" \
        "$(ag_label "$TRUNC_JSON" "")" \
        "$(printf '11\tz\tkw=bug scope=team\t%s' "$TRUNC_Q")"

    # --- router ---
    assert_line "AG route: ALL labels in ctx (sorted, ASCII P1 < bug)" \
        "$(ag_route '[{"iid":7,"title":"Crash segfault build","labels":["bug","P1"],"assignees":[]}]')" \
        "$(printf '7\tkw=build,crash,segfault labels=P1,bug\tCrash segfault build P1 bug')"
    assert_line "AG route: all assigned -> empty" \
        "$(ag_route '[{"iid":7,"title":"bug","labels":[],"assignees":[{"username":"alice"}]}]')" ""
    assert_line "AG route: picks first unassigned (2nd issue)" \
        "$(ag_route '[{"iid":7,"title":"bug","labels":[],"assignees":[{"username":"a"}]},{"iid":9,"title":"docs ci","labels":["z","a"],"assignees":[]}]')" \
        "$(printf '9\tkw=ci,docs labels=a,z\tdocs ci a z')"
    assert_line "AG route: special chars in label kept, TSV well-formed" \
        "$(ag_route '[{"iid":6,"title":"fix bug","labels":["needs, review","P1"],"assignees":[]}]')" \
        "$(printf '6\tkw=bug labels=P1,needs, review\tfix bug P1 needs, review')"

    # --- prioritizer ---
    DPV="priority::critical, priority::high, priority::medium, priority::low, P1, P2, P3, P4, urgent"
    assert_line "AG prioritize: non-priority labels only in ctx" \
        "$(ag_pri '[{"iid":7,"title":"Crash segfault build","labels":["bug"]}]' "$DPV")" \
        "$(printf '7\tkw=build,crash,segfault labels=bug\tCrash segfault build bug')"
    # priority label at index >=1 (labels[1]=P2) proves the K-col projection.
    assert_line "AG prioritize: priority label at index >=1 -> issue is prioritized, picks 2nd" \
        "$(ag_pri '[{"iid":7,"title":"bug crash","labels":["area","P2"]},{"iid":9,"title":"docs","labels":["z"]}]' "$DPV")" \
        "$(printf '9\tkw=docs labels=z\tdocs z')"
    # custom-pv: "low" is priority-like only because the operator vocab lists it.
    assert_line "AG prioritize: custom-pv membership skips prioritized, picks 2nd" \
        "$(ag_pri '[{"iid":5,"title":"bug","labels":["low"]},{"iid":7,"title":"crash test","labels":["area"]}]' "high, low")" \
        "$(printf '7\tkw=crash,test labels=area\tcrash test area')"
    # all rows prioritized (P1 + urgent) -> greedy false-positive closed by VERIFY.
    assert_line "AG prioritize: all-prioritized -> empty (greedy VERIFY)" \
        "$(ag_pri '[{"iid":7,"title":"bug","labels":["P1"]},{"iid":9,"title":"crash","labels":["urgent"]}]' "$DPV")" ""

    # ----- #1638 CB fix: raw-JSON VERIFY equivalence (byte-identity with the
    # retired per-label is_pri filter) -----
    # canonical_priority_context now VERIFYs the chosen issue with ONE regex
    # (PRISET) over the raw JSON label array instead of a per-label is_pri walk.
    # PRISET mirrors is_pri's grammar quote-anchored: a priority label makes the
    # issue "already prioritized" -> "" (fail SAFE); a non-priority label leaves
    # it selectable -> emits the line. Cases mirror the #1638 byte-identity table.
    assert_line "#1638 AG prioritize: 'p12x' is NOT priority (p<digits> needs a closing quote)" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["p12x"]}]' "$DPV")" \
        "$(printf '7\tkw=crash labels=p12x\tCrash p12x')"
    assert_line "#1638 AG prioritize: 'deprioritize' is NOT priority (not a startswith prefix)" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["deprioritize"]}]' "$DPV")" \
        "$(printf '7\tkw=crash labels=deprioritize\tCrash deprioritize')"
    assert_line "#1638 AG prioritize: 'xpriority' is NOT priority (not a startswith prefix)" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["xpriority"]}]' "$DPV")" \
        "$(printf '7\tkw=crash labels=xpriority\tCrash xpriority')"
    assert_line "#1638 AG prioritize: 'priorityqueue' IS priority (startswith) -> empty" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["priorityqueue"]}]' "$DPV")" ""
    assert_line "#1638 AG prioritize: 'Priority::High' IS priority (startswith, case-folded) -> empty" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["Priority::High"]}]' "$DPV")" ""
    # KEY safety net: a priority label at index >=9 is OUTSIDE the K=8 projection
    # (iid + labels[0..8]), so PRILINE cannot see it and the greedy capture would
    # wrongly pick this issue; the FLAT VERIFY reads the FULL raw label array and
    # catches it -> "" (the projection cutoff cannot leak a prioritized issue).
    assert_line "#1638 AG prioritize: priority label at index >=9 caught by full-array VERIFY -> empty" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["a0","a1","a2","a3","a4","a5","a6","a7","a8","priority::high"]}]' "$DPV")" ""
    # custom-pv exact-vs-prefix: 'high' listed in pv is a fullmatch member, but
    # 'highway' (prefix only) is NOT priority (PRISET closes the branch on ").
    assert_line "#1638 AG prioritize: 'highway' is NOT priority under custom pv 'high' (member is exact)" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["highway","bug"]}]' "high, low")" \
        "$(printf '7\tkw=crash labels=bug,highway\tCrash bug highway')"
    # punctuation labels: pva regex_escapes pv tokens and raw label metachars sit
    # only inside the literal quoted PRISET branch, never interpreted as regex.
    assert_line "#1638 AG prioritize: punctuation labels are NOT priority, TSV well-formed" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["c++","re[gex]"]}]' "$DPV")" \
        "$(printf '7\tkw=crash labels=c++,re[gex]\tCrash c++ re[gex]')"
    # #1638 QA: PRISET must restore is_pri's to_lower(trim(l)) for space-padded
    # priority labels. Without the `[ ]*` tolerance the padded label slips past the
    # raw-JSON VERIFY and leaks into nonpri; with it, a padded priority label makes
    # the issue "already prioritized" -> "" (byte-identical to the python oracle,
    # which strips-then-is_pri). Non-padded controls stay green above.
    assert_line "#1638 QA AG prioritize: '  P1  ' (space-padded) IS priority -> empty" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["  P1  ","bug"]}]' "$DPV")" ""
    assert_line "#1638 QA AG prioritize: '  urgent  ' (space-padded) IS priority -> empty" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["  urgent  "]}]' "$DPV")" ""
    assert_line "#1638 QA AG prioritize: '  priority::high  ' (space-padded) IS priority -> empty" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["  priority::high  "]}]' "$DPV")" ""
    assert_line "#1638 QA AG prioritize: '  high  ' (space-padded custom-pv) IS priority -> empty" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["  high  ","bug"]}]' "high, low")" ""
    # Control: the SAME custom-pv 'high' unpadded is likewise priority (proves the
    # padded case is caught by trim tolerance, not by a spurious match).
    assert_line "#1638 QA AG prioritize: 'highway' (padded 'high' is NOT a prefix match) -> line" \
        "$(ag_pri '[{"iid":7,"title":"Crash","labels":["  highway  ","bug"]}]' "high, low")" \
        "$(printf '7\tkw=crash labels=bug,highway\tCrash bug highway')"

    # ----- #1638 CB fix: label-count sweep under the enforced cb cap -----
    # The retired per-label is_pri VERIFY cost ~283 CB/label (~363 on a heavier
    # vocab) and overflowed the live cb_per_tick=2000 at ~5 labels on the chosen
    # issue; the flat raw-JSON VERIFY drops the slope to ~58 CB/label (the shared
    # output-join floor). Assert canonical_priority_context COMPLETES under a
    # `cb 2000;` header (== the enforced cb_per_tick) for a chosen issue carrying
    # 0..20 non-priority labels -- the regression the old code failed at 4+ labels.
    # Uses the production-default 4-token priority::* vocab (pvalt -> "").
    DEFPV="priority::critical, priority::high, priority::medium, priority::low"
    ag_pri_cap2000() {
        # OK   = completes (no CognitiveOverload) and emits the non-empty line
        # OVERFLOW = the cb 2000 cap was exceeded; EMPTY = no output
        local j p out fn
        j="$(printf '%s' "$1" | aglit)"; p="$(printf '%s' "$2" | aglit)"
        {
            echo "cb 2000;"
            for fn in $COMMON_FNS member is_pri regex_escape pvalt canonical_priority_context; do extract_fn "$PRI" "$fn"; echo; done
            echo "print(canonical_priority_context($j, $p));"
        } > "$AG_TMP/pri_cap.ag"
        out="$( (cd "$AG_TMP" && agentis go pri_cap.ag 2>&1) | grep -v '^\[genesis\]' )"
        if printf '%s' "$out" | grep -q CognitiveOverload; then echo "OVERFLOW"
        elif [ -n "$out" ]; then echo "OK"; else echo "EMPTY"; fi
    }
    for NL in 0 1 2 4 8 12 16 20; do
        NL_JSON="$(python3 -c 'import json,sys; n=int(sys.argv[1]); print(json.dumps([{"iid":7,"title":"Crash segfault build","labels":["area%d"%i for i in range(n)]}]))' "$NL")"
        assert_line "#1638 AG prioritize: canonical_priority_context completes under cb 2000 at $NL labels" \
            "$(ag_pri_cap2000 "$NL_JSON" "$DEFPV")" "OK"
    done

    rm -rf "$AG_TMP"
else
    echo "[SKIP] agentis not on PATH — skipping native-builder byte-identity probes"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
