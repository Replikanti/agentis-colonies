
/^[[:space:]]*#/ { next }
/^[[:space:]]*echo/ { next }
/agentis[[:space:]]+daemon/ { in_cmd=1 }
in_cmd {
    for (i=1; i<=NF; i++) {
        tok = $i
        sub(/\\$/, "", tok)
        if (tok == "&" || tok == "") continue
        if (tok ~ /^--[a-zA-Z][a-zA-Z-]*(=.*)?$/) {
            sub(/=.*/, "", tok)
            print tok
        } else if (tok ~ /^-[a-zA-Z]$/) {
            print tok
        }
    }
    if ($0 !~ /\\[[:space:]]*$/) { in_cmd = 0 }
}
