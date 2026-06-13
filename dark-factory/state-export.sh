#!/usr/bin/env bash
# state-export.sh — export / import / verify a trained dark-factory federation's EVOLVED STATE.
#
# The value of a *trained* federation is its evolved state: the accumulated learned `memo`
# (fitness weights, taxonomy/method state) and the content-addressed Merkle DAG of audited
# patterns. This packages that state into a portable, integrity-checked artifact so a trained
# instance can be moved between machines — or transferred to a buyer.
#
# It deliberately EXCLUDES the federation IDENTITY (private key), per-deployment config, and
# the transient sandbox: a buyer/importer keeps their OWN identity and only inherits the
# learned state. This is the technical enabler for distributing a trained federation
# (agentis-core#864).
#
# Usage:
#   state-export.sh export <rundir> <out.tar.gz>
#   state-export.sh verify <artifact.tar.gz>
#   state-export.sh import <artifact.tar.gz> <dest-rundir>
set -uo pipefail

# Evolved state = learned memo + the content-addressed DAG. NOT identity/config/sandbox.
STATE_PATHS="memo objects refs HEAD"
EXCLUDED="identity (private key), config, sandbox"

die() { echo "state-export: $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
manifest_field() { grep -o "\"$1\": *\"[^\"]*\"" "$2" | head -1 | sed 's/.*: *"//; s/"$//'; }

cmd="${1:-}"; shift 2>/dev/null || true

case "$cmd" in
  export)
    rd="${1:-}"; out="${2:-}"
    [ -d "$rd/.agentis" ] || die "no .agentis store in '$rd'"
    [ -n "$out" ] || die "usage: export <rundir> <out.tar.gz>"
    inc=""; for p in $STATE_PATHS; do [ -e "$rd/.agentis/$p" ] && inc="$inc .agentis/$p"; done
    [ -n "$inc" ] || die "no evolved-state paths present in $rd/.agentis"
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2086
    tar -C "$rd" -czf "$tmp/state.tar.gz" $inc || die "tar failed"
    memo_keys=$( [ -d "$rd/.agentis/memo" ] && find "$rd/.agentis/memo" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0 )
    dag_objs=$( [ -d "$rd/.agentis/objects" ] && find "$rd/.agentis/objects" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0 )
    digest="$(sha "$tmp/state.tar.gz")"
    cat > "$tmp/manifest.json" <<EOF
{
  "artifact": "dark-factory-evolved-state",
  "agentis_version": "$(agentis version 2>/dev/null || echo unknown)",
  "included": "$(echo $inc | sed 's/\.agentis\///g')",
  "excluded": "$EXCLUDED",
  "memo_keys": $memo_keys,
  "dag_objects": $dag_objs,
  "state_sha256": "$digest",
  "exported_at": "${STATE_EXPORT_TS:-unset}"
}
EOF
    tar -C "$tmp" -czf "$out" manifest.json state.tar.gz || die "package failed"
    rm -rf "$tmp"
    echo "exported -> $out"
    echo "  memo keys: $memo_keys | dag objects: $dag_objs | sha256: $digest"
    echo "  excluded (kept private to the seller): $EXCLUDED"
    ;;

  verify)
    art="${1:-}"; [ -f "$art" ] || die "no artifact '$art'"
    tmp="$(mktemp -d)"; tar -C "$tmp" -xzf "$art" 2>/dev/null || die "unpack failed"
    [ -f "$tmp/manifest.json" ] || die "no manifest in artifact"
    want="$(manifest_field state_sha256 "$tmp/manifest.json")"
    got="$(sha "$tmp/state.tar.gz")"
    cat "$tmp/manifest.json"; rm -rf "$tmp"
    [ "$want" = "$got" ] && echo "INTEGRITY OK ($got)" || die "INTEGRITY FAIL: manifest=$want actual=$got"
    ;;

  import)
    art="${1:-}"; dest="${2:-}"
    [ -f "$art" ] || die "no artifact '$art'"
    [ -n "$dest" ] || die "usage: import <artifact.tar.gz> <dest-rundir>"
    tmp="$(mktemp -d)"; tar -C "$tmp" -xzf "$art" 2>/dev/null || die "unpack failed"
    want="$(manifest_field state_sha256 "$tmp/manifest.json")"
    got="$(sha "$tmp/state.tar.gz")"
    [ "$want" = "$got" ] || die "INTEGRITY FAIL: manifest=$want actual=$got"
    mkdir -p "$dest"
    # The importer keeps its OWN identity + config: init a fresh store if absent, then overlay
    # only the learned state (memo) + content-addressed DAG blobs (objects) onto it.
    [ -d "$dest/.agentis" ] || ( cd "$dest" && agentis init >/dev/null 2>&1 ) || die "agentis init failed in $dest"
    mkdir -p "$dest/.agentis/memo" "$dest/.agentis/objects"
    tar -C "$tmp" -xzf "$tmp/state.tar.gz" 2>/dev/null
    [ -d "$tmp/.agentis/memo" ]    && cp -a "$tmp/.agentis/memo/."    "$dest/.agentis/memo/"    2>/dev/null || true
    [ -d "$tmp/.agentis/objects" ] && cp -a "$tmp/.agentis/objects/." "$dest/.agentis/objects/" 2>/dev/null || true
    rm -rf "$tmp"
    echo "imported evolved state -> $dest/.agentis (kept local identity/config)"
    echo "  (memo + content-addressed DAG blobs overlaid; identity NOT transferred)"
    ;;

  *) die "usage: state-export.sh export|verify|import ..." ;;
esac
