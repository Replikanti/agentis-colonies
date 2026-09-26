# shellcheck shell=bash
# dark-factory/lib/foundry-shim.sh — the per-root TOOLCHAIN RESOLVER of run-zone-hunt.sh's stateful lenses (#2277).
# SOURCED (functions only, no top-level side effect besides sourcing lib/forge-slot.sh). Callers set HERE, REPO
# (the clone root) and OUT (the run's --out) first.
#
# WHY. STAGE 4.5 (deep hunt) and STAGE 4.6 (vector hunt) drive Foundry-only engines. A Hardhat-only project root (no
# foundry.toml) used to be skipped with one stderr line, so a Hardhat contest's deep hunt measured NOTHING and the
# run still looked complete. fs_resolve answers, per project root, "can the stateful lens run here, and in which
# directory?":
#   * foundry.toml present      -> ran / foundry        FS_REPO_DIR = the root itself (nothing written, argv unchanged)
#   * hardhat.config.* present  -> a generated FOUNDRY SHIM working copy under $OUT/.foundry-shim/<slug>/ (see
#                                  lib/foundry_shim.py), probed by ONE `forge build`: ran / foundry-shim, or
#                                  shim-failed with the reason. DF_FOUNDRY_SHIM=0 -> skipped-no-foundry / shim-disabled.
#   * neither                   -> skipped-no-foundry / no-toolchain-config
# The target clone is never written: the shim is a copy, and a dependency install runs in a scratch dir.
#
# LEDGER. Every consult is recorded in $OUT/deep-hunt-status.tsv (TSV, `#` header): stage (deep-hunt|vector-hunt),
# root (`.`, <root> or `-`), zone (`*` for a root row, else the zone id), status, detail. Statuses:
#   ran                 detail foundry | foundry-shim
#   skipped-no-foundry  detail no-toolchain-config | shim-disabled
#   skipped-no-root     detail outside-every-root (a zone of a multi-root map outside every root)
#   shim-failed         detail deps-missing:<pkg,...> | install-failed:<tool> rc=<n> | forge-not-found |
#                       forge-build rc=<n>: <first error line, max 160 chars> | build-error rc=<n>
# fs_summary prints `deep_hunt_status=<agg>` to stderr: `ran` when every row ran, `partial` when some did, else the
# most severe status (shim-failed > skipped-no-foundry > skipped-no-root). A shim failure never aborts the run.
#
# KNOBS (validated by fs_validate_knobs; a bad value exits 2):
#   DF_FOUNDRY_SHIM=0|1                  build shims for Hardhat-only roots (default 1)
#   DF_FOUNDRY_SHIM_INSTALL=0|1          on missing deps, install them from the root's lockfile (default 1): lockfile-
#                                        only (npm ci / frozen yarn / frozen pnpm), always --ignore-scripts, into
#                                        $OUT/.foundry-shim/<slug>.deps/ holding only package.json + the lockfile
#                                        (never .npmrc / .yarnrc*), deleted after the rebuild
#   DF_FOUNDRY_SHIM_INSTALL_TIMEOUT_S=N  install wall cap in seconds (default 600)
#   DF_FOUNDRY_SHIM_BUILD_TIMEOUT_S=N    probe `forge build` wall cap in seconds (default 1800)
#
# Compatibility: bash 3.2+ (no associative arrays), `set -eu` safe (every rc is checked). Never returns non-zero.

# shellcheck source=forge-slot.sh
. "$HERE/lib/forge-slot.sh"

FS_INITED=0

# fs_validate_knobs — exit 2 on a malformed knob (the run-zone-hunt.sh knob-guard shape).
fs_validate_knobs() {
  case "${DF_FOUNDRY_SHIM:-}" in ''|0|1) ;; *) echo "run-zone-hunt.sh: DF_FOUNDRY_SHIM must be unset, 0 or 1 (got '${DF_FOUNDRY_SHIM:-}')" >&2; exit 2 ;; esac
  case "${DF_FOUNDRY_SHIM_INSTALL:-}" in ''|0|1) ;; *) echo "run-zone-hunt.sh: DF_FOUNDRY_SHIM_INSTALL must be unset, 0 or 1 (got '${DF_FOUNDRY_SHIM_INSTALL:-}')" >&2; exit 2 ;; esac
  case "${DF_FOUNDRY_SHIM_INSTALL_TIMEOUT_S:-}" in ''|[1-9]|[1-9]*[0-9]) ;; *) echo "run-zone-hunt.sh: DF_FOUNDRY_SHIM_INSTALL_TIMEOUT_S must be unset or a whole number of seconds (got '${DF_FOUNDRY_SHIM_INSTALL_TIMEOUT_S:-}')" >&2; exit 2 ;; esac
  case "${DF_FOUNDRY_SHIM_INSTALL_TIMEOUT_S:-}" in *[!0-9]*) echo "run-zone-hunt.sh: DF_FOUNDRY_SHIM_INSTALL_TIMEOUT_S must be unset or a whole number of seconds (got '${DF_FOUNDRY_SHIM_INSTALL_TIMEOUT_S:-}')" >&2; exit 2 ;; esac
  case "${DF_FOUNDRY_SHIM_BUILD_TIMEOUT_S:-}" in ''|[1-9]|[1-9]*[0-9]) ;; *) echo "run-zone-hunt.sh: DF_FOUNDRY_SHIM_BUILD_TIMEOUT_S must be unset or a whole number of seconds (got '${DF_FOUNDRY_SHIM_BUILD_TIMEOUT_S:-}')" >&2; exit 2 ;; esac
  case "${DF_FOUNDRY_SHIM_BUILD_TIMEOUT_S:-}" in *[!0-9]*) echo "run-zone-hunt.sh: DF_FOUNDRY_SHIM_BUILD_TIMEOUT_S must be unset or a whole number of seconds (got '${DF_FOUNDRY_SHIM_BUILD_TIMEOUT_S:-}')" >&2; exit 2 ;; esac
  return 0
}

# fs_init — once per invocation: a fresh ledger (header only) and a reset shim dir (created lazily, so a Foundry-only
# run never creates it). Idempotent: STAGE 4.5 and STAGE 4.6 both call it and share the per-invocation root cache.
fs_init() {
  if [ "$FS_INITED" = 1 ]; then return 0; fi
  fs_validate_knobs
  FS_LEDGER="$OUT/deep-hunt-status.tsv"
  FS_DIR="$OUT/.foundry-shim"
  rm -rf "$FS_DIR"
  printf '#stage\troot\tzone\tstatus\tdetail\n' > "$FS_LEDGER"
  FS_INITED=1
  return 0
}

# _fs_timeout <secs> <cmd...> — run under GNU/BSD `timeout` when available (rc 124 = timed out), else unbounded.
_fs_timeout() {
  _fst_s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_fst_s" "$@"
  else
    "$@"
  fi
}

# _fs_cache_get <root> — sets FS_STATUS/FS_DETAIL/FS_REPO_DIR from $FS_DIR/roots.tsv; rc 1 when not cached.
_fs_cache_get() {
  [ -f "$FS_DIR/roots.tsv" ] || return 1
  _fsc_line="$(awk -F'\t' -v r="$1" '$1 == r { print; exit }' "$FS_DIR/roots.tsv" 2>/dev/null || true)"
  [ -n "$_fsc_line" ] || return 1
  FS_STATUS="$(printf '%s\n' "$_fsc_line" | cut -f2)"
  FS_DETAIL="$(printf '%s\n' "$_fsc_line" | cut -f3)"
  FS_REPO_DIR="$(printf '%s\n' "$_fsc_line" | cut -f4)"
  return 0
}

_fs_cache_put() {
  mkdir -p "$FS_DIR"
  printf '%s\t%s\t%s\t%s\n' "$1" "$FS_STATUS" "$FS_DETAIL" "$FS_REPO_DIR" >> "$FS_DIR/roots.tsv"
}

# _fs_slug <root> — the shim dir name: `_root` for `.`, else the root with every non [A-Za-z0-9._-] byte -> `_`;
# a collision with an existing shim gets a numeric suffix.
_fs_slug() {
  if [ "$1" = "." ]; then _fss_base="_root"; else _fss_base="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; fi
  _fss_slug="$_fss_base"; _fss_n=2
  while [ -e "$FS_DIR/$_fss_slug" ]; do _fss_slug="$_fss_base-$_fss_n"; _fss_n=$((_fss_n + 1)); done
  printf '%s' "$_fss_slug"
}

# _fs_build <rootdir> <dest> <log> [--node-modules <dir>] — run the helper; rc = the helper's exit code.
_fs_build() {
  _fsb_root="$1"; _fsb_dest="$2"; _fsb_log="$3"; shift 3
  rm -rf "$_fsb_dest"
  python3 "$HERE/lib/foundry_shim.py" build --root "$_fsb_root" --clone "$REPO" --dest "$_fsb_dest" \
    --exclude "$OUT" "$@" > "$_fsb_log" 2>&1
}

# _fs_install <slug> <lockfile> <tool> — lockfile-only dependency install into $FS_DIR/<slug>.deps/. rc 0 = done.
_fs_install() {
  _fsi_deps="$FS_DIR/$1.deps"; _fsi_lock="$2"; _fsi_tool="$3"
  _fsi_t="${DF_FOUNDRY_SHIM_INSTALL_TIMEOUT_S:-600}"
  rm -rf "$_fsi_deps"; mkdir -p "$_fsi_deps"
  _fsi_pkg="$(dirname "$_fsi_lock")/package.json"
  if [ -f "$_fsi_pkg" ]; then cp "$_fsi_pkg" "$_fsi_deps/package.json"; fi
  cp "$_fsi_lock" "$_fsi_deps/"
  case "$_fsi_tool" in
    npm)
      ( cd "$_fsi_deps" && _fs_timeout "$_fsi_t" npm ci --ignore-scripts --prefer-offline --no-audit --no-fund ) ;;
    yarn)
      _fsi_major="$(yarn --version 2>/dev/null | cut -d. -f1 || true)"
      if [ "${_fsi_major:-1}" = 1 ]; then
        ( cd "$_fsi_deps" && _fs_timeout "$_fsi_t" yarn install --frozen-lockfile --ignore-scripts --prefer-offline )
      else
        ( cd "$_fsi_deps" && _fs_timeout "$_fsi_t" yarn install --immutable --mode=skip-build )
      fi ;;
    pnpm)
      ( cd "$_fsi_deps" && _fs_timeout "$_fsi_t" pnpm install --frozen-lockfile --ignore-scripts --prefer-offline ) ;;
    *) return 127 ;;
  esac
}

# _fs_unresolved <log> — the comma-joined `unresolved=` package keys of a helper log.
_fs_unresolved() {
  sed -n 's/^unresolved=//p' "$1" 2>/dev/null | paste -sd, - || true
}

# fs_resolve <root> — sets FS_STATUS / FS_DETAIL / FS_REPO_DIR for project root <root> (`.` = the clone root).
# Never returns non-zero; a Hardhat root is shimmed and probed at most once per invocation (cached).
fs_resolve() {
  _fs_root="$1"
  FS_STATUS=""; FS_DETAIL=""; FS_REPO_DIR=""
  if [ "$_fs_root" = "." ]; then _fs_dir="$REPO"; else _fs_dir="$REPO/$_fs_root"; fi
  if [ -f "$_fs_dir/foundry.toml" ]; then
    FS_STATUS=ran; FS_DETAIL=foundry; FS_REPO_DIR="$_fs_dir"
    return 0
  fi
  _fs_hh=""
  for _fs_c in hardhat.config.ts hardhat.config.js hardhat.config.cjs hardhat.config.mjs; do
    if [ -f "$_fs_dir/$_fs_c" ]; then _fs_hh="$_fs_c"; break; fi
  done
  if [ -z "$_fs_hh" ]; then
    FS_STATUS=skipped-no-foundry; FS_DETAIL=no-toolchain-config
    return 0
  fi
  if [ "${DF_FOUNDRY_SHIM:-1}" = 0 ]; then
    FS_STATUS=skipped-no-foundry; FS_DETAIL=shim-disabled
    return 0
  fi
  _fs_cache_get "$_fs_root" && return 0
  mkdir -p "$FS_DIR"
  _fs_sl="$(_fs_slug "$_fs_root")"
  _fs_dest="$FS_DIR/$_fs_sl"
  _fs_log="$FS_DIR/$_fs_sl.shim.log"
  echo "run-zone-hunt.sh: [foundry-shim] root '$_fs_root' is Hardhat-only ($_fs_hh) — generating a Foundry shim working copy (#2277)" >&2
  _fs_rc=0; _fs_build "$_fs_dir" "$_fs_dest" "$_fs_log" || _fs_rc=$?
  if [ "$_fs_rc" -eq 4 ] && [ "${DF_FOUNDRY_SHIM_INSTALL:-1}" = 1 ]; then
    _fs_lock="$(sed -n 's/^lockfile=//p' "$_fs_log" | head -1)"
    _fs_tool="$(sed -n 's/^lock_tool=//p' "$_fs_log" | head -1)"
    if [ -n "$_fs_lock" ] && [ -n "$_fs_tool" ] && command -v "$_fs_tool" >/dev/null 2>&1; then
      echo "run-zone-hunt.sh: [foundry-shim] root '$_fs_root': missing deps [$(_fs_unresolved "$_fs_log")] — $_fs_tool install from $(basename "$_fs_lock") (--ignore-scripts, scratch dir) (#2277)" >&2
      _fs_irc=0; _fs_install "$_fs_sl" "$_fs_lock" "$_fs_tool" > "$FS_DIR/$_fs_sl.install.log" 2>&1 || _fs_irc=$?
      if [ "$_fs_irc" -ne 0 ]; then
        FS_STATUS=shim-failed; FS_DETAIL="install-failed:$_fs_tool rc=$_fs_irc"
        rm -rf "$FS_DIR/$_fs_sl.deps/node_modules"
        _fs_cache_put "$_fs_root"
        return 0
      fi
      _fs_rc=0; _fs_build "$_fs_dir" "$_fs_dest" "$_fs_log" --node-modules "$FS_DIR/$_fs_sl.deps/node_modules" || _fs_rc=$?
      rm -rf "$FS_DIR/$_fs_sl.deps/node_modules"
    fi
  fi
  if [ "$_fs_rc" -eq 4 ]; then
    FS_STATUS=shim-failed; FS_DETAIL="deps-missing:$(_fs_unresolved "$_fs_log")"
    _fs_cache_put "$_fs_root"
    return 0
  fi
  if [ "$_fs_rc" -ne 0 ]; then
    FS_STATUS=shim-failed; FS_DETAIL="build-error rc=$_fs_rc"
    _fs_cache_put "$_fs_root"
    return 0
  fi
  if ! command -v forge >/dev/null 2>&1; then
    FS_STATUS=shim-failed; FS_DETAIL=forge-not-found
    _fs_cache_put "$_fs_root"
    return 0
  fi
  # The probe: ONE `forge build` of the shim under a host-wide forge slot. Its out/ and cache/ are removed after, so
  # every per-cell copy of the shim (run-invariant-hunt.sh copies --repo whole) stays sources-only.
  _fs_blog="$FS_DIR/$_fs_sl.build.log"
  acquire_forge_slot
  _fs_frc=0
  ( cd "$_fs_dest" && _fs_timeout "${DF_FOUNDRY_SHIM_BUILD_TIMEOUT_S:-1800}" forge build ) > "$_fs_blog" 2>&1 || _fs_frc=$?
  release_forge_slot
  rm -rf "$_fs_dest/out" "$_fs_dest/cache"
  if [ "$_fs_frc" -ne 0 ]; then
    _fs_err="$(grep -m1 -iE 'error' "$_fs_blog" 2>/dev/null || true)"
    [ -n "$_fs_err" ] || _fs_err="$(grep -m1 . "$_fs_blog" 2>/dev/null || true)"
    _fs_err="$(printf '%s' "$_fs_err" | tr '\t\r' '  ' | cut -c1-160)"
    FS_STATUS=shim-failed; FS_DETAIL="forge-build rc=$_fs_frc: $_fs_err"
    _fs_cache_put "$_fs_root"
    return 0
  fi
  FS_STATUS=ran; FS_DETAIL=foundry-shim; FS_REPO_DIR="$_fs_dest"
  echo "run-zone-hunt.sh: [foundry-shim] root '$_fs_root' -> $FS_REPO_DIR (forge build OK) (#2277)" >&2
  _fs_cache_put "$_fs_root"
  return 0
}

# fs_record <stage> <root> <zone> [<status> <detail>] — append one ledger row (default: the last fs_resolve result),
# deduplicated on (stage, root, zone) so the #2258 scheduler's repeated passes record each row once.
fs_record() {
  _fsr_status="${4:-$FS_STATUS}"; _fsr_detail="${5:-$FS_DETAIL}"
  if awk -F'\t' -v s="$1" -v r="$2" -v z="$3" '$1 == s && $2 == r && $3 == z { f = 1 } END { exit f ? 0 : 1 }' "$FS_LEDGER" 2>/dev/null; then
    return 0
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$_fsr_status" "$_fsr_detail" >> "$FS_LEDGER"
  return 0
}

# fs_summary <stage> — the stage's aggregate status line on stderr.
fs_summary() {
  _fsu_line="$(awk -F'\t' -v s="$1" '
    $1 == s { n++; if ($4 == "ran") k++; else if ($4 == "shim-failed") f++; else if ($4 == "skipped-no-foundry") nf++; else nr++ }
    END {
      agg = "ran"
      if (n > 0 && k < n) {
        if (k > 0) agg = "partial"; else if (f) agg = "shim-failed"; else if (nf) agg = "skipped-no-foundry"; else agg = "skipped-no-root"
      }
      printf "%s (%d/%d root(s) ran)", agg, k, n
    }' "$FS_LEDGER" 2>/dev/null || true)"
  echo "run-zone-hunt.sh: [$1] deep_hunt_status=$_fsu_line — see deep-hunt-status.tsv (#2277)" >&2
  return 0
}
