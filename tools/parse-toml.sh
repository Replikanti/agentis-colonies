#!/bin/bash
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
    python3 - "$CONFIG" "$1" "$2" <<'PY'
import sys
path, section, key = sys.argv[1], sys.argv[2], sys.argv[3]
target_header = "[" + section + "]"
in_section = False
with open(path, "r", encoding="utf-8") as f:
    for raw in f:
        line = raw.split("#", 1)[0].rstrip("\n")
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_section = (stripped == target_header)
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
