#!/usr/bin/env python3
"""Email the arXiv submission tarball + cover letter via SMTP.

Usage: send-arxiv-email.py <claim_id> <from_addr> <to_addr> <cover_path> <tarball_path>

Reads the cover letter from `cover_path` and the tarball from
`tarball_path`, constructs a single `email.message.EmailMessage` with
Subject `"arXiv submission: <claim_id>"`, attaches the tarball as
`application/gzip` named `submission.tar.gz`, and sends via SMTP to
the host/port from `PREPRINT_SMTP_HOST` (default `localhost`) and
`PREPRINT_SMTP_PORT` (default `25`).

On success prints `sent` to stdout; on any failure prints
`smtp-error:<exception>` to stdout. Always exits 0 so the submitter
pipeline can read the result line and persist it to the ledger
verbatim — matches the legacy contract: the shell-out's `catch e {
"smtp-error:exec-failed"; }` and the inline python's `print("smtp-
error:"+str(e))` are interchangeable from the caller's perspective.

Extracted from inline `python3 -c '...'` in submitter.ag for Wave 7v
of the exec-sh purge (agentis substrate `compute_python_args` cannot
take an inline -c string; it requires a script path on disk).
"""

import email.message
import os
import smtplib
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 6:
        print("smtp-error:usage")
        return 0
    claim_id = argv[1]
    from_addr = argv[2]
    to_addr = argv[3]
    cover_path = argv[4]
    tarball_path = argv[5]
    m = email.message.EmailMessage()
    m["Subject"] = f"arXiv submission: {claim_id}"
    m["From"] = from_addr
    m["To"] = to_addr
    try:
        with open(cover_path, "r") as f:
            cover = f.read()
        m.set_content(cover)
        with open(tarball_path, "rb") as f:
            data = f.read()
        m.add_attachment(
            data,
            maintype="application",
            subtype="gzip",
            filename="submission.tar.gz",
        )
        host = os.environ.get("PREPRINT_SMTP_HOST", "localhost")
        port = int(os.environ.get("PREPRINT_SMTP_PORT", "25"))
        s = smtplib.SMTP(host, port, timeout=30)
        s.send_message(m)
        s.quit()
        print("sent")
    except Exception as e:
        print(f"smtp-error:{e}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
