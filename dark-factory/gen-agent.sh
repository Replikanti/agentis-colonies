#!/usr/bin/env bash
# gen-agent.sh: materialise a colony-lint-VALID `.ag` discovery agent from an
# invented METHOD line in auditor/methods/registry.md (#1000).
#
# The method-discovery loop (method-inventor.ag) invents new audit *methods* —
# reusable hunting techniques — but cannot turn them into new AGENTS; the agent
# set was fixed. This generator closes that self-extension gap: it reads one
#   METHOD|<name>|<classes>|<technique>|<how-to-invoke>|<control-assertion>
# line and writes agents/<name>.ag, an adversarial-audit agent (modelled on
# hunter.ag) whose prompt is wired from the method's technique / how-to-invoke /
# control-assertion. The generated agent is a one-shot discovery agent (no
# `fn tick`), so the ADR-0001 tier-branch lint does not apply to it — same shape
# as hunter.ag. It MUST pass `tools/colony-lint.sh` (agentis `.ag` syntax check
# + check-exec-sh concat safety).
#
# Usage:   dark-factory/gen-agent.sh <method-name>
# Exit:    0 wrote agent; 2 usage / bad method / parse error; 3 agent exists.

set -uo pipefail

# --- Resolve our own dir (symlink-safe) so registry/agents paths are absolute. ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="$SCRIPT_DIR/auditor/methods/registry.md"
AGENTS_DIR="$SCRIPT_DIR/auditor/agents"

usage() {
    echo "usage: $(basename "$0") <method-name>" >&2
    echo "  Reads METHOD|<method-name>|... from $REGISTRY and writes" >&2
    echo "  auditor/agents/<method-name>.ag (a colony-lint-valid discovery agent)." >&2
}

err() { echo "gen-agent: $1" >&2; }

# --- Arg + environment validation. ---
if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
    usage
    exit 2
fi
NAME="$1"

# Restrict the name to a safe filename/emit-suffix shape; this is also the
# `.ag` filename and the `dark-factory:<suffix>` emit topic, so reject anything
# that is not kebab-case alphanumerics.
case "$NAME" in
    *[!a-z0-9-]* | "" | -* | *-)
        err "method name must be kebab-case [a-z0-9-] (no leading/trailing dash): '$NAME'"
        exit 2
        ;;
esac

if [ ! -f "$REGISTRY" ]; then
    err "registry not found: $REGISTRY"
    exit 2
fi

OUT="$AGENTS_DIR/$NAME.ag"
if [ -e "$OUT" ]; then
    err "agent already exists, refusing to overwrite: $OUT"
    exit 3
fi

# --- Pull the matching METHOD line (first match wins). ---
# Match `METHOD|<name>|` anchored at line start so a substring of another
# method name cannot collide.
LINE="$(grep -m1 -E "^METHOD\|${NAME}\|" "$REGISTRY" || true)"
if [ -z "$LINE" ]; then
    err "no 'METHOD|${NAME}|...' line in $REGISTRY"
    exit 2
fi

# --- Split into fields on the literal pipe. ---
# run-method-discovery.sh writes two registry shapes (see auditor/methods/registry.md):
#   builtin : METHOD|name|classes|technique|how-to-invoke|<status=builtin>|<fitness>
#   invented: METHOD|name|classes|technique|how-to-invoke|<control-assertion>|invented|<fitness>
# The head is fixed (tag,name,classes,technique,how-to-invoke); the tail is always
# <status>|<fitness>. Anything BETWEEN how-to-invoke and <status> is the control-assertion
# (present only on `invented` lines). We parse positionally so both shapes work.
# Split on `|` with globbing DISABLED — a builtin line's bug-classes field is a
# literal `*`, which would otherwise pathname-expand into the cwd's filenames.
OLD_IFS="$IFS"
set -f
IFS='|'
# shellcheck disable=SC2206  # intentional word-splitting on the pipe delimiter
FIELDS=( $LINE )
IFS="$OLD_IFS"
set +f

NF="${#FIELDS[@]}"
# Minimum: METHOD,name,classes,technique,how-to-invoke,status,fitness = 7 fields.
if [ "${FIELDS[0]:-}" != "METHOD" ] || [ "$NF" -lt 7 ]; then
    err "malformed METHOD line (expected METHOD|name|classes|technique|how-to-invoke|...|status|fitness): $LINE"
    exit 2
fi

F_NAME="${FIELDS[1]}"
F_CLASSES="${FIELDS[2]}"
F_TECHNIQUE="${FIELDS[3]}"
F_INVOKE="${FIELDS[4]}"
F_FITNESS="${FIELDS[$((NF - 1))]}"
F_STATUS="${FIELDS[$((NF - 2))]}"
# The control-assertion is whatever sits between how-to-invoke (index 4) and the
# status field (index NF-2). For a 7-field builtin line that range is empty; for an
# 8-field invented line it is exactly index 5. A method-inventor that emits extra
# pipes in its control-assertion would land >8 fields — re-join the middle so we do
# not silently drop text.
F_CONTROL=""
if [ "$((NF - 2))" -gt 5 ]; then
    i=5
    while [ "$i" -lt "$((NF - 2))" ]; do
        if [ -z "$F_CONTROL" ]; then
            F_CONTROL="${FIELDS[$i]}"
        else
            F_CONTROL="$F_CONTROL|${FIELDS[$i]}"
        fi
        i=$((i + 1))
    done
fi

# --- Escape a field for embedding inside an `.ag` double-quoted string. ---
# `.ag` string literals are double-quoted; backslash and double-quote are the
# only chars that would break the literal (the registry is a single text line,
# so there are no embedded newlines to worry about). Backslash MUST be escaped
# before the quote so we do not double-process the escape we just inserted.
ag_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

E_CLASSES="$(ag_escape "$F_CLASSES")"
E_TECHNIQUE="$(ag_escape "$F_TECHNIQUE")"
E_INVOKE="$(ag_escape "$F_INVOKE")"
# `invented` methods carry an explicit control-assertion; `builtin` methods do not,
# so fall back to a generic two-sided gate (no privileged role; the documented happy
# path must still hold) — the same discipline hunter.ag's prompt enforces.
if [ -n "$F_CONTROL" ]; then
    E_CONTROL="$(ag_escape "$F_CONTROL")"
else
    E_CONTROL="A candidate counts only if the bug is reachable by an unprivileged external attacker AND the documented happy path still holds (no privileged role required to trigger it)."
fi

# --- Emit the agent. ---
# Modelled on auditor/agents/hunter.ag: `cb 300000;`, env reads, a file-reader
# that offloads to `exec sh` with a `// colony-lint: safe-exec-concat` annotation
# (the linter cannot prove the `${dir}/${rel}` concat safe), a single adversarial
# `prompt(instruction, payload)`, `print()` of the verdict, and an `emit()` +
# `learn()` so the method's per-target fitness reweights over runs (the #861
# evolve loop, now over a generated method-agent).
#
# We do NOT define `fn tick(...)`, so colony-lint's ADR-0001 tier-branch check is
# not triggered (one-shot `agentis go` discovery agent, exactly like hunter.ag).
write_agent() {
    cat <<AGEOF
cb 300000;
// GENERATED by dark-factory/gen-agent.sh from method '${F_NAME}' (#1000). Do not
// hand-edit the wiring below the header; regenerate from auditor/methods/registry.md
// (delete this file first — the generator refuses to overwrite).
//
// Method '${F_NAME}' — a discovery agent that applies ONE invented audit method
// over ONE in-scope subsystem and prints exactly one CANDIDATE|... line per
// finding (else SAFE). It complements hunter.ag (taxonomy-class lens) with a
// method-specific lens; run-discovery.sh / run-audit.sh fan it out the same way
// and feed every candidate into the forge-verify gate before it counts.
//
// Targets bug classes: ${E_CLASSES}
//
// Env (same contract as hunter.ag):
//   TARGET_DIR   repo root of the cloned target
//   IN_SCOPE     newline-separated contract paths (relative to TARGET_DIR)
//   SCOPE_BRIEF  path to a file: invariants-to-break + known-issues-to-exclude + trust model
//   SUBSYSTEM    human label for this slice
// Stdout: exactly one CANDIDATE|file:fn:line|method=${F_NAME}|severity|exploit|poc line per finding, else SAFE.

// Read a whole in-scope file. Dynamic path -> safe-exec-concat (the recall-match.ag
// / hunter.ag precedent: the grep linter cannot see through the \${path} concat).
fn cat_file(path: string) -> string {
    // An empty path makes this `sed -n '1,2000p'  2>/dev/null`, and sed with no
    // file argument reads standard input. The substrate closes stdin on every
    // exec, so today that returns "" rather than leaking — but it spends a
    // subprocess to arrive at the answer the caller already had, and it relies
    // on a substrate guarantee this agent does not state. \$SCOPE_BRIEF below
    // is unset on some paths, so the empty case is reachable. (#2084)
    if len(path) == 0 { return ""; }
    // colony-lint: safe-exec-concat
    return exec sh "sed -n '1,2000p' \${path} 2>/dev/null || true";
}

// Concatenate every in-scope contract into one labelled blob (hunter.ag::scoped_code).
fn scoped_code(dir: string, files: string) -> string {
    return reduce(regex_split("\n", files), |acc: string, rel: string| -> string {
        if len(rel) == 0 { return acc; }
        return acc + "\n\n// ========== " + rel + " ==========\n" + cat_file(dir + "/" + rel);
    }, "");
}

// learn() outcome must be one of {success,failure,partial,timeout,error}: a
// surfaced candidate = success, a rigorous SAFE = failure, so method fitness
// rewards the methods that actually produce leads across targets (#861 evolve loop).
fn outcome_of(verdict: string) -> string {
    if index_of(verdict, "CANDIDATE|") == 0 { return "success"; }
    return "failure";
}

let dir = getenv("TARGET_DIR");
let files = getenv("IN_SCOPE");
let subsystem = getenv("SUBSYSTEM");
let brief = cat_file(getenv("SCOPE_BRIEF"));
let code = scoped_code(dir, files);

// The instruction carries the invented method (technique + how-to-invoke), the
// brief (invariants + known-issues), and a strict output contract; the code is
// the prompt payload (auditor.ag::classify_evm_llm / hunter.ag shape).
let instruction =
    "You are an elite adversarial smart-contract auditor competing in a LIVE audit contest for real money. "
  + "Apply ONE specific audit METHOD to the code below. Find a HIGH or MEDIUM severity bug an EXTERNAL "
  + "attacker (holding NO privileged role) can exploit. This code is likely already audited, so report "
  + "ONLY a bug you are confident survives expert judging — no speculation, no informational notes.\n\n"
  + "=== METHOD: ${F_NAME} (the lens) ===\n"
  + "Technique: ${E_TECHNIQUE}\n"
  + "How to invoke: ${E_INVOKE}\n"
  + "Targets bug classes: ${E_CLASSES}\n\n"
  + "=== CONTROL ASSERTION — a candidate is valid ONLY if this holds ===\n"
  + "${E_CONTROL}\n\n"
  + "=== PROTOCOL BRIEF — invariants whose violation is a valid finding, and KNOWN ISSUES you MUST NOT report ===\n"
  + brief + "\n\n"
  + "=== RULES ===\nOnly Medium/High count. A trusted role acting WITHIN its documented permissions is OUT OF SCOPE; "
  + "a role EXCEEDING its permissions, or any unprivileged user, IS in scope. Never report a listed KNOWN ISSUE. "
  + "Subsystem under review: " + subsystem + ".\n\n"
  + "=== OUTPUT CONTRACT ===\nIf you find a qualifying bug, output EXACTLY one line:\n"
  + "CANDIDATE|<file:function:line>|<method=${F_NAME}>|<severity=Medium|High>|<one-sentence external exploit path>|<concrete foundry PoC sketch: what to deploy, call, and assert>\n"
  + "If after rigorous analysis there is NO qualifying bug this method surfaces in this subsystem, output exactly:\nSAFE\n"
  + "Output nothing else — no preamble, no markdown.";

let verdict = prompt(instruction, code) -> string;

// Surface to the verifier (stdout) and record the attempt so method fitness reweights over time.
print(verdict);
let outcome = outcome_of(verdict);
emit("dark-factory:method_result", "{\"method\":\"${F_NAME}\",\"subsystem\":\"" + subsystem + "\",\"outcome\":\"" + outcome + "\"}");
learn("method", "${F_NAME}:" + subsystem, "method ${F_NAME} on " + subsystem, outcome, ["${F_NAME}", subsystem, outcome]);
memo_write("${F_NAME}:last_check", "done");
AGEOF
}

mkdir -p "$AGENTS_DIR"
if ! write_agent > "$OUT"; then
    err "failed to write $OUT"
    rm -f "$OUT"
    exit 2
fi

echo "gen-agent: wrote $OUT from method '$NAME' (status=$F_STATUS, fitness=$F_FITNESS)"
echo "gen-agent: validate with ./tools/colony-lint.sh (repo root)"
