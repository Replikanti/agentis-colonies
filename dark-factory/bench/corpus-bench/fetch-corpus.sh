#!/usr/bin/env bash
# fetch-corpus.sh — clone the CODE + JUDGING repos for one or every corpus.tsv row into a work dir. Host-side
# network step (like fetch-target.sh / fetch-audits.sh) — nothing here is re-hosted in this repo, only the
# manifest (corpus.tsv) + this fetch logic are committed; the actual contest code/findings live in their own
# public GitHub repos and are cloned fresh on demand.
#
# Usage: fetch-corpus.sh --out <dir> [--corpus <corpus.tsv>] [--id <id>]...
#   --out <dir>      Work dir; each row lands in <out>/<id>/{code,judging}. REQUIRED.
#   --corpus <file>  corpus.tsv (default: corpus.tsv next to this script).
#   --id <id>        Restrict to one row (repeatable). Default: every row in corpus.tsv.
#   -h, --help       This help.
# Exit: 0 all requested rows fetched (or already present) ; 2 bad args ; 3 a clone failed.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CORPUS="$HERE/corpus.tsv"
OUT=""
IDS=""

nv() { [ "$1" -ge 2 ] || { echo "fetch-corpus.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do case "$1" in
  --out)    nv "$#" "$1"; OUT="$2"; shift 2;;
  --corpus) nv "$#" "$1"; CORPUS="$2"; shift 2;;
  --id)     nv "$#" "$1"; IDS="$IDS $2"; shift 2;;
  -h|--help) sed -n '2,12p' "$0"; exit 0;;
  *) echo "fetch-corpus.sh: unknown arg: $1" >&2; exit 2;;
esac; done

[ -n "$OUT" ] || { echo "fetch-corpus.sh: --out <dir> required" >&2; exit 2; }
[ -f "$CORPUS" ] || { echo "fetch-corpus.sh: corpus manifest not found: $CORPUS" >&2; exit 2; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

FETCH_TARGET="$HERE/../../fetch-target.sh"
[ -x "$FETCH_TARGET" ] || FETCH_TARGET=""

FAILED=0
while IFS=$'\t' read -r id code_repo judging_repo _scope_hint; do
  case "$id" in ""|\#*) continue;; esac
  if [ -n "$IDS" ]; then
    case " $IDS " in *" $id "*) : ;; *) continue;; esac
  fi
  row_out="$OUT/$id"
  mkdir -p "$row_out"

  if [ -d "$row_out/code/.git" ]; then
    echo "fetch-corpus.sh: [$id] code already present, skipping" >&2
  else
    echo "fetch-corpus.sh: [$id] cloning code $code_repo -> $row_out/code ..." >&2
    rm -rf "$row_out/code"
    if [ -n "$FETCH_TARGET" ]; then
      bash "$FETCH_TARGET" "https://github.com/$code_repo.git" "$row_out/code" || { echo "fetch-corpus.sh: [$id] code clone failed" >&2; FAILED=1; continue; }
    else
      git clone --depth 1 "https://github.com/$code_repo.git" "$row_out/code" || { echo "fetch-corpus.sh: [$id] code clone failed" >&2; FAILED=1; continue; }
    fi
  fi

  if [ -d "$row_out/judging/.git" ]; then
    echo "fetch-corpus.sh: [$id] judging already present, skipping" >&2
  else
    echo "fetch-corpus.sh: [$id] cloning judging $judging_repo -> $row_out/judging ..." >&2
    rm -rf "$row_out/judging"
    git clone --depth 1 "https://github.com/$judging_repo.git" "$row_out/judging" || { echo "fetch-corpus.sh: [$id] judging clone failed" >&2; FAILED=1; continue; }
  fi
  [ -f "$row_out/judging/README.md" ] || { echo "fetch-corpus.sh: [$id] judging repo has no README.md (unexpected layout)" >&2; FAILED=1; continue; }
  echo "fetch-corpus.sh: [$id] ready ($row_out)" >&2
done < "$CORPUS"

[ "$FAILED" -eq 0 ] || { echo "fetch-corpus.sh: one or more rows failed to fetch" >&2; exit 3; }
exit 0
