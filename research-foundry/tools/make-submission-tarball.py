#!/usr/bin/env python3
"""Build the arXiv submission tarball from a claim directory.

Usage: make-submission-tarball.py <claim_dir> <reproducibility_ext>

Creates `<claim_dir>/submission.tar.gz` containing the canonical
arXiv submission file set, with all paths flattened to the basename
inside the archive (no `<claim_dir>/` prefix in the entries — matches
the legacy `cd <claim_dir> && tar -czf ...` shell-out contract).

`reproducibility_ext` is the .ag-side extension chooser — either `.py`
(compute_python runs) or `.g` (compute_gap runs) — so the entry is
named `reproducibility.py` or `reproducibility.g` to match the
upstream language.

Total: missing files are silently skipped (the legacy `tar ... || true`
swallowed any tar error). Returns exit_code 0 on success or partial
success, non-zero only on catastrophic OS failure (claim_dir absent).

Extracted from inline `tar -czf ...` shell command in submitter.ag for
Wave 7v of the exec-sh purge — substrate has no tar primitive, but
python stdlib `tarfile` covers the use case without a new builtin.
"""

import os
import sys
import tarfile


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        sys.stderr.write("usage: make-submission-tarball.py <claim_dir> <repro_ext>\n")
        return 2
    claim_dir = argv[1]
    repro_ext = argv[2]
    if not os.path.isdir(claim_dir):
        sys.stderr.write(f"claim_dir not a directory: {claim_dir}\n")
        return 1
    members = [
        "main.tex",
        "refs.bib",
        f"reproducibility{repro_ext}",
        "reproducibility-output.txt",
        "arxiv-metadata.json",
    ]
    archive_path = os.path.join(claim_dir, "submission.tar.gz")
    with tarfile.open(archive_path, "w:gz") as tar:
        for name in members:
            src = os.path.join(claim_dir, name)
            if os.path.isfile(src):
                tar.add(src, arcname=name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
