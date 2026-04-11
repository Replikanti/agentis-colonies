# tools/parse-toml.sh: shared TOML key lookup for colony start scripts.
#
# Usage: source this file, then call `parse_toml SECTION KEY`. Expects
# $CONFIG to point at the TOML file to read. Returns the first matching
# value under `[SECTION]` on stdout, preserving internal whitespace and
# stripping matching quotes. Keys outside the requested section are
# ignored so same-name keys in sibling sections do not collide.
#
# Not executable: source only.
# shellcheck shell=bash

parse_toml() {
    if [ "$#" -ne 2 ]; then
        echo "parse_toml: usage: parse_toml SECTION KEY (got $# args)" >&2
        return 2
    fi
    python3 - "$CONFIG" "$1" "$2" <<'PY'
import sys
path, section, key = sys.argv[1], sys.argv[2], sys.argv[3]


def strip_inline_comment(line):
    """Strip a trailing `# comment` from a TOML line, respecting quoted
    strings so a `#` inside `"..."` or `'...'` is preserved."""
    out = []
    quote = None
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(line[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
        else:
            if ch == "#":
                break
            if ch in ('"', "'"):
                quote = ch
            out.append(ch)
        i += 1
    return "".join(out)


in_section = False
with open(path, "r", encoding="utf-8") as f:
    for raw in f:
        line = strip_inline_comment(raw).rstrip("\n")
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            # Allow `[ gitlab ]` with interior whitespace per TOML spec.
            sect_name = stripped[1:-1].strip()
            in_section = (sect_name == section)
            continue
        if not in_section:
            continue
        if not stripped.startswith(key):
            continue
        rest = stripped[len(key):].lstrip()
        if not rest.startswith("="):
            continue
        value = rest[1:].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        print(value)
        break
PY
}
