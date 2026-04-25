# tools/parse-toml.sh: shared TOML key lookup for colony start scripts.
#
# Usage: source this file, then call `parse_toml SECTION KEY`. Expects
# $CONFIG to point at the TOML file to read. Returns the first matching
# value under `[SECTION]` on stdout, preserving internal whitespace and
# stripping matching quotes. Keys outside the requested section are
# ignored so same-name keys in sibling sections do not collide.
#
# Values starting with `secret://` are resolved to plaintext via the
# backend resolver in tools/parse-toml-secret.py (libsecret / macOS
# Keychain / pass / env). Plaintext values pass through unchanged.
# The URI scheme is opt-in — pre-#321 plaintext configs keep working.
#
# All Python logic lives in tools/parse-toml-secret.py to keep this
# script free of heredocs (#172 / #245 / #271 macOS bash 3.2 parser
# bug). See the no-heredoc invariant in CLAUDE.md.
#
# Not executable: source only.
# shellcheck shell=bash

# Resolve the directory holding this script so the python helper can
# be located even when the caller sourced us via a relative path.
# `BASH_SOURCE` is bash-only but every caller already requires bash
# for set -e, arrays, and printf -v.
_PARSE_TOML_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

parse_toml() {
    if [ "$#" -ne 2 ]; then
        echo "parse_toml: usage: parse_toml SECTION KEY (got $# args)" >&2
        return 2
    fi
    python3 "$_PARSE_TOML_DIR/parse-toml-secret.py" "$CONFIG" "$1" "$2"
}
