#!/usr/bin/env bash
# check-slot-reads.sh — static guard for the slot gates (#2362): a stamp, claim or reap token is read only by the
# library's builtin read helper, and no decision rests on an external binary's output or exit status.
#
# Usage: tools/check-slot-reads.sh LIB...   (tools/lib/llm-session-slot.sh, dark-factory/lib/forge-slot.sh)
# Exit: 0 = every LIB passes; 1 = a violation (printed as FILE:LINE: rule: text); 2 = usage.
#
# An allowlist, not a list of known bad commands. On the code lines (full-line comments dropped) of each LIB:
#   1. Every command word is a shell keyword or builtin from a fixed set, a function the LIB defines, or one of the
#      external commands the gates need for side effects only (mkdir, rm, rmdir, sleep, chmod). `cat`, `grep -q`, `head`,
#      `stat` and any other reader fail here, whatever they are used for, and so does a quoted or expanded command
#      word (`"cat"`, `$CAT`).
#   2. `read` and every input redirection (`<`, `4<`) appear only on the two pinned helper lines: the builtin read
#      in <prefix>_read and the instance pin in <prefix>_dead_empty.
#      Any other command word (a quoted one, an expansion, a split word such as `c\at`) is reported too.
#   3. No pipeline into a command, no backtick, no `<(`, and no command substitution `$(` other than the two that
#      resolve the pool path (`$(<prefix>_slots_dir)` / `$(cd "$COLONY_DIR/.." && pwd)`). `$((` arithmetic is fine.
#   4. The body of <prefix>_read is pinned byte for byte.
# shellcheck disable=SC2094  # violation() only prints the file name; nothing here writes a LIB
set -uo pipefail

[ "$#" -ge 1 ] || { echo "usage: check-slot-reads.sh LIB..." >&2; exit 2; }

BAD=0
violation() { echo "$1:$2: $3: $4"; BAD=1; }

# shellcheck disable=SC2016  # an awk program, expanded by awk
AWK_RULES='
function v(rule, t) { printf "%s:%d: %s: %s\n", F, NR, rule, t; bad = 1 }
BEGIN {
    n = split(FN, a, " "); for (i = 1; i <= n; i++) fn[a[i]] = 1
    n = split("if then else elif fi case esac for while until do done in return break continue printf true false set exit kill umask : [ read mkdir rm rmdir sleep chmod", b, " ")
    for (i = 1; i <= n; i++) ok[b[i]] = 1
    path1 = PRE "_dir=\"$(_llm_slots_dir)\""; path2 = PRE "_dir=\"$(_forge_slots_dir)\""
    path3 = "printf \047%s\047 \"$(cd \"$COLONY_DIR/..\" && pwd)/.agentis/llm-slots\""
}
{
    line = $0; t = line; sub(/^[[:space:]]+/, "", t)
    if (t == "" || substr(t, 1, 1) == "#") next
    # 3. command substitution, backticks, process substitution, pipelines into commands
    if (index(line, "`")) v("backtick", t)
    if (index(line, "<(")) v("process substitution", t)
    if (line ~ /\$\(([^(]|$)/ && t != path1 && t != path2 && t != path3) v("command substitution", t)
    if (line ~ /(^|[^|])\|[[:space:]]*[A-Za-z_{(]/) v("pipeline", t)
    # 2. read and input redirections only on the pinned helper lines
    if (line != RL && line != PL) {
        if (line ~ /(^|[^[:alnum:]_])read([^[:alnum:]_]|$)/) v("read outside " PRE "_read", t)
        q = line; gsub(/\047[^\047]*\047/, "", q); gsub(/"[^"]*"/, "", q)
        if (q ~ /(^|[^<])<($|[^<(])/) v("input redirection outside the pinned helpers", t)
    }
    # 1. command words: neutralise arithmetic and quoted strings, drop case-item labels, split at command boundaries,
    #    skip leading assignments, negation and redirections, and check the first word of every segment
    c = line; gsub(/\$\(\([^)]*\)\)/, "0", c); gsub(/\047[^\047]*\047/, "Q", c); gsub(/"([^"\\]|\\.)*"/, "Q", c)
    sub(/^[[:space:]]*[^()[:space:]|]+([[:space:]]*\|[[:space:]]*[^()[:space:]|]+)*\)/, "", c)
    gsub(/[[:space:]]in[[:space:]]+[^();[:space:]|]+([[:space:]]*\|[[:space:]]*[^();[:space:]|]+)*\)/, " in;", c)
    gsub(/;;|;|&&|\|\||\||\{|\}|\(|\)/, "\n", c)
    gsub(/(^|[[:space:]])(then|do|else|elif|if|while|until)([[:space:]]|$)/, "\n", c)
    m = split(c, seg, "\n")
    for (i = 1; i <= m; i++) {
        x = seg[i]; sub(/^[[:space:]]+/, "", x); sub(/^!+[[:space:]]*/, "", x)
        while (match(x, /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]*/)) x = substr(x, RLENGTH + 1)
        while (match(x, /^[0-9]*[<>]+&?[[:space:]]*[^[:space:]]+[[:space:]]*/)) x = substr(x, RLENGTH + 1)
        split(x, w, /[[:space:]]+/); word = w[1]
        if (word == "" || (word in fn) || (word in ok)) continue
        v("command not on the allowlist (" word ")", t)
    }
}
END { exit bad }
'

for lib in "$@"; do
    [ -f "$lib" ] || { echo "check-slot-reads.sh: no such file: $lib" >&2; exit 2; }
    pre="$(grep -oE '^_[lf]ss_read\(\)' "$lib" | head -1 | sed 's/_read()$//')"
    if [ -z "$pre" ]; then
        violation "$lib" 0 "helper" "no _lss_read/_fss_read helper defined"
        continue
    fi
    read_line="    { IFS= read -r ${pre}_val < \"\$1\" && ${pre}_rs=0; } 2>/dev/null || :"
    # shellcheck disable=SC2016  # the literal source line, nothing to expand
    pin_line='    } 2>/dev/null 4< "$1" || :'

    # 4. the helper body, pinned
    want="$(printf '%s() {\n    %s_val=""\n    %s_rs=1\n%s\n}' "${pre}_read" "$pre" "$pre" "$read_line")"
    got="$(awk -v f="${pre}_read() {" '$0 == f {p=1} p {print} p && /^}/ {exit}' "$lib")"
    [ "$got" = "$want" ] || violation "$lib" 0 "helper" "${pre}_read body differs from the pinned one"

    funcs="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$lib" | sed 's/()$//' | tr '\n' ' ')"
    # Rules 1-3 in one awk pass per LIB (\047 is a single quote).
    if ! awk -v F="$lib" -v PRE="$pre" -v RL="$read_line" -v PL="$pin_line" -v FN="$funcs" "$AWK_RULES" "$lib"; then
        BAD=1
    fi
done

exit "$BAD"
