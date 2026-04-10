#!/bin/bash
# tools/parse-toml.sh: shared TOML key lookup for colony start scripts.
#
# Usage: source this file, then call `parse_toml KEY`. Expects $CONFIG to
# point at the TOML file to read. Returns the first matching value on
# stdout, preserving internal whitespace and stripping matching quotes.
#
# Not executable: source only.
# shellcheck shell=bash

parse_toml() {
    python3 - "$CONFIG" "$1" <<'PY'
import sys
path, key = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    for raw in f:
        line = raw.split("#", 1)[0].rstrip("\n")
        stripped = line.lstrip()
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
