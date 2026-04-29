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

# parse_toml_array_count SECTION
# Echo the number of `[[SECTION]]` array-of-tables entries in $CONFIG.
# Returns `0` (and exit 0) on missing — compatible with legacy single-table
# configs that have zero `[[SECTION]]` entries. Added in #316 M1.
parse_toml_array_count() {
    if [ "$#" -ne 1 ]; then
        echo "parse_toml_array_count: usage: parse_toml_array_count SECTION (got $# args)" >&2
        return 2
    fi
    python3 "$_PARSE_TOML_DIR/parse-toml-secret.py" --array-count "$CONFIG" "$1"
}

# parse_toml_array_get SECTION IDX KEY
# Echo the value of KEY in the IDX-th (0-indexed) `[[SECTION]]` entry.
# Empty stdout when the index is out of range or the key is missing.
# `secret://` URIs are resolved to plaintext before being printed
# (mirrors `parse_toml`). Added in #316 M1.
parse_toml_array_get() {
    if [ "$#" -ne 3 ]; then
        echo "parse_toml_array_get: usage: parse_toml_array_get SECTION IDX KEY (got $# args)" >&2
        return 2
    fi
    python3 "$_PARSE_TOML_DIR/parse-toml-secret.py" --array-get "$CONFIG" "$1" "$2" "$3"
}

# parse_toml_array_keys SECTION IDX
# Echo (newline-separated) the key names declared in the IDX-th
# `[[SECTION]]` entry, in source order. Empty stdout when IDX is out of
# range. Added in #316 M1.
parse_toml_array_keys() {
    if [ "$#" -ne 2 ]; then
        echo "parse_toml_array_keys: usage: parse_toml_array_keys SECTION IDX (got $# args)" >&2
        return 2
    fi
    python3 "$_PARSE_TOML_DIR/parse-toml-secret.py" --array-keys "$CONFIG" "$1" "$2"
}

# parse_toml_array_get_inline SECTION IDX KEY SUBKEY
# Echo the SUBKEY value of an inline TOML table assigned to KEY in the
# IDX-th (0-indexed) `[[SECTION]]` entry. For example, given an entry
#   [[forge.github]]
#   labels = { trigger = "needs-triage" }
# `parse_toml_array_get_inline forge.github 0 labels trigger` echoes
# `needs-triage`. Empty stdout when the index, key, or subkey is missing.
# Added in #316 M5a so per-repo trigger-label memo seeding can read inline-
# table values without paying for a heavyweight TOML library.
parse_toml_array_get_inline() {
    if [ "$#" -ne 4 ]; then
        echo "parse_toml_array_get_inline: usage: parse_toml_array_get_inline SECTION IDX KEY SUBKEY (got $# args)" >&2
        return 2
    fi
    python3 "$_PARSE_TOML_DIR/parse-toml-secret.py" --array-get-inline "$CONFIG" "$1" "$2" "$3" "$4"
}
