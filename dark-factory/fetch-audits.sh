#!/usr/bin/env bash
# fetch-audits.sh — INGEST a target's public audit reports (#1485). The audit-aware residual hunt begins here:
# the reward is only in what the target's OWN audits MISSED, so the hunter must first read those audits to know
# the EXCLUSION boundary (known findings = not rewardable) and the CONCERN map (auditor-flagged-uncertain areas
# = highest residual density). This is the operator's one allowed network step (like snapshot-rpc.sh / fetch-
# target.sh): download each audit URL and, for a PDF, extract text with `pdftotext` so the downstream boundary
# extractor + analyst can read it offline.
#
# Sherlock/Cantina/Code4rena contests link their audit PDFs on public buckets; a protocol's own audits are on
# its repo/site. Point this at those URLs.
#
# Usage: fetch-audits.sh [--out <dir>] [--manifest <file>] [<url>...]
#   --out <dir>       output dir for the extracted text + index (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/audits).
#   --manifest <file> read newline-joined audit URLs from <file> (in addition to any <url> args).
#   <url>...          one or more audit URLs (PDF / md / txt / html).
# Output: <out>/NN-<slug>.txt per source + <out>/index.tsv (`url<TAB>file<TAB>bytes<TAB>status`).
# Requires: curl; `pdftotext` (poppler-utils) for PDFs. No network / no curl -> [SKIP] + exit 0 (CI-safe).
# READ-ONLY: only fetches public audit docs; never authenticates, never submits, never posts.
set -u

DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

nv() { [ "$1" -ge 2 ] || { echo "fetch-audits.sh: $2 requires a value" >&2; exit 2; }; }
OUT="$DIR/audits" ; MANIFEST="" ; URLS=()
while [ $# -gt 0 ]; do case "$1" in
  --out)      nv "$#" "$1"; OUT="$2"; shift 2;;
  --manifest) nv "$#" "$1"; MANIFEST="$2"; shift 2;;
  -h|--help)  sed -n '2,21p' "$0"; exit 0;;
  -*)         echo "fetch-audits.sh: unknown flag: $1" >&2; exit 2;;
  *)          URLS+=("$1"); shift;;
esac; done

if [ -n "$MANIFEST" ]; then
  [ -r "$MANIFEST" ] || { echo "fetch-audits.sh: --manifest not readable: $MANIFEST" >&2; exit 2; }
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && URLS+=("$line")
  done < "$MANIFEST"
fi

[ "${#URLS[@]}" -gt 0 ] || { echo "fetch-audits.sh: no audit URLs (pass <url>... or --manifest <file>)" >&2; exit 2; }

command -v curl >/dev/null 2>&1 || { echo "[SKIP] curl not installed — cannot fetch audits" >&2; exit 0; }
HAVE_PDFTOTEXT=0; command -v pdftotext >/dev/null 2>&1 && HAVE_PDFTOTEXT=1

mkdir -p "$OUT"
INDEX="$OUT/index.tsv"; : > "$INDEX"

# slugify a URL's basename into a filesystem-safe stem.
slug_of() { printf '%s' "${1##*/}" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64; }

got=0; skipped=0; i=0
for url in "${URLS[@]}"; do
  i=$((i+1))
  case "$url" in http://*|https://*) ;; *) echo "fetch-audits: skip non-http url: $url" >&2; skipped=$((skipped+1)); continue;; esac
  stem="$(printf '%02d-%s' "$i" "$(slug_of "$url")")"
  raw="$OUT/$stem"
  # Fetch (bounded; a transient failure is a skip, not a crash).
  if ! curl -fsSL --max-time 60 -A 'Mozilla/5.0' "$url" -o "$raw" 2>/dev/null; then
    echo "fetch-audits: [SKIP] fetch failed: $url" >&2
    printf '%s\t%s\t%s\t%s\n' "$url" "-" "0" "fetch-failed" >> "$INDEX"
    skipped=$((skipped+1)); continue
  fi
  # Extract text: PDF -> pdftotext; otherwise keep as-is (md/txt/html).
  base="$stem"; for ext in .pdf .txt .md .html .htm; do base="${base%"$ext"}"; done
  txt="$OUT/$base.txt"
  if head -c 5 "$raw" 2>/dev/null | grep -q '%PDF-'; then
    if [ "$HAVE_PDFTOTEXT" -eq 1 ]; then
      pdftotext -layout "$raw" "$txt" 2>/dev/null || : > "$txt"
      status="pdf-extracted"
    else
      echo "fetch-audits: [SKIP] pdftotext missing — kept raw PDF for $url (install poppler-utils to extract)" >&2
      txt="$raw"; status="pdf-raw"
    fi
  else
    [ "$txt" = "$raw" ] || cp "$raw" "$txt"
    status="text"
  fi
  bytes="$(wc -c < "$txt" 2>/dev/null | tr -d ' ')"
  printf '%s\t%s\t%s\t%s\n' "$url" "$txt" "${bytes:-0}" "$status" >> "$INDEX"
  got=$((got+1))
  echo "fetch-audits: $status -> $txt (${bytes:-0} bytes)" >&2
done

echo "fetch-audits: extracted ${got} audit doc(s), skipped ${skipped} -> $OUT (index: $INDEX)" >&2
[ "$got" -gt 0 ] || { echo "[SKIP] no audit docs fetched (network down / all failed)" >&2; exit 0; }
