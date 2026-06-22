#!/usr/bin/env bash
# tools/lib/candidate-fingerprint.sh — shared, dependency-free helper that
# prints a stable short fingerprint over an issue candidate's
# (source, location, normalized-title). The dedup key the issue_creator gate
# consumes for #1266 M2 (companion to the candidate queue added in #1273).
#
# candidate_fingerprint <source> <location> <title>
#   Prints the first 12 hex chars of the sha256 of the three inputs joined by
#   a US (0x1f) unit separator. Deterministic: same inputs → same output,
#   different inputs → different output. The title is normalized first
#   (lowercase, fold every whitespace run — including tabs/newlines — to one
#   space, trim) so trivially-different titles collapse onto the same key.
#
# Dependencies: bash + a sha256 tool only — `sha256sum`, falling back to
# `shasum -a 256` (portable across Linux + macOS). No python3, no agentis
# binary; this file is meant to be sourced, so it sets no shell options.
#
# Usage: source this file, then:
#   fp="$(candidate_fingerprint "router" "src/foo.rs:42" "Null deref in parser")"

# candidate_fingerprint <source> <location> <title>
candidate_fingerprint() {
    local src="${1-}" location="${2-}" title="${3-}"
    local sep norm payload digest
    sep=$'\037'  # US (unit separator), 0x1f — collision-resistant join char

    # Normalize the title: lowercase, fold any whitespace run to a single
    # space, then trim the (now single) leading/trailing space.
    norm="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')"
    norm="${norm# }"
    norm="${norm% }"

    payload="${src}${sep}${location}${sep}${norm}"

    if command -v sha256sum >/dev/null 2>&1; then
        digest="$(printf '%s' "$payload" | sha256sum)"
    else
        digest="$(printf '%s' "$payload" | shasum -a 256)"
    fi
    digest="${digest%% *}"  # drop the trailing "  -" filename column

    printf '%s\n' "${digest:0:12}"
}
