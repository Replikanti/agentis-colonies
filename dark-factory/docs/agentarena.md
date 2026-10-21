# AgentArena intake

dark-factory's shadow intake for AgentArena tasks (epic #2317). The platform notifies a registered webhook
once per task; the intake fetches the task, hunts it and posts findings back. This page documents the pieces
that have landed so far.

## Webhook receiver

`dark-factory/agentarena-webhook.py` (#2325) is the intake's front door. It is a stdlib-only Python HTTP
server that:

- accepts exactly `POST /webhook` with `Authorization: token <WEBHOOK_AUTH_TOKEN>` (constant-time compare,
  checked before any body byte is read);
- accepts a body only with a declared `Content-Length` of at most 65536 bytes (64 KiB). The notification is
  four short strings, well under 1 KB, so the cap leaves room for fields the platform may add while bounding
  what a token holder can write;
- requires a JSON object with string `task_repository_url`, `task_details_url` and `post_findings_url`, and a
  `task_id` of 1-128 characters from `[A-Za-z0-9_-]` that starts with a letter or digit (no `.`, `/`, `\`,
  NUL, whitespace or leading `-`, so the id is safe as a file name and as a shell argument);
- writes the notification atomically to `$DARK_FACTORY_DIR/agentarena/inbox/<task_id>.json` and answers
  `202 {"status":"accepted"}`.

It does **not** fetch the task, check URL policy, start any subprocess or open any outbound connection; that
is the intake's job ([Intake: fetch and unpack](#intake-fetch-and-unpack)). It writes nothing outside the inbox and touches no Slack, memo or export sink.
The token never appears in argv, in a log line or in a response.

### Running it

```bash
WEBHOOK_AUTH_TOKEN='secret://libsecret/agentarena/webhook' \
    dark-factory/agentarena-webhook.py [--bind 127.0.0.1] [--port 8421] [--port-file PATH]
dark-factory/agentarena-webhook.py --self-test     # offline, exit 0/1
```

| Env | Meaning |
|-----|---------|
| `WEBHOOK_AUTH_TOKEN` | Required; the receiver refuses to run unauthenticated. Recommended form: a `secret://libsecret/...`, `secret://keychain/...` or `secret://pass/...` URI, resolved in-process by `tools/parse-toml-secret.py`. A raw value is accepted as-is. |
| `DARK_FACTORY_DIR` | State root, default `~/.dark-factory`. |

| Flag | Meaning |
|------|---------|
| `--bind ADDR` | IP literal to bind, default `127.0.0.1`. Hostnames are refused. |
| `--port N` | Default `8421` (distinct from the dashboards' 8420); `0` picks an ephemeral port. |
| `--port-file PATH` | After binding, write the bound port to PATH atomically (for `--port 0` callers). |
| `--allow-non-loopback` | Permit a non-loopback `--bind`. Only for a TLS-terminating front on the same host or container; see [Exposure](#exposure). |
| `--self-test` | Offline self-test against a loopback instance with a temp state dir. |

Exit codes: `0` clean shutdown (SIGTERM/SIGINT) or self-test passed, `1` self-test failed, `2` usage/config
error (token unset, refused bind address), `3` `secret://` resolution failed, `4` bind failed.

### Responses

Every response closes the connection and carries a fixed JSON body; request data is never echoed. Each
request logs one stderr line with the status, a fixed outcome token and, once validated, the task_id.

| Status | Outcome | When |
|--------|---------|------|
| 202 | `accepted` | New notification written to the inbox. |
| 202 | `duplicate` | `<task_id>.json` already exists; the first file wins and is left untouched. |
| 400 | `bad-request` | Bad or duplicate `Content-Length`, short body, invalid JSON, not an object, missing or non-string `*_url`, or JSON a strict parser would reject: `NaN`/`Infinity`, a number that overflows to infinity (`1e999`), a lone surrogate escape (`"\ud800"`), nesting deeper than 32. |
| 400 | `timeout` | The body did not arrive before the request deadline (below). |
| 400 | `bad-task-id` | `task_id` fails the pattern above. The log line records only its length and character classes. |
| 401 | `unauthorized` | Missing, wrong or repeated `Authorization` header. |
| 404 | `not-found` | Any path other than exactly `/webhook` (query strings included). |
| 405 | `method-not-allowed` | `/webhook` with a method other than POST (`Allow: POST`). |
| 411 | `length-required` | `Transfer-Encoding` present or `Content-Length` missing. |
| 413 | `too-large` | Declared `Content-Length` above 65536; the body is never read. |
| 500 | `write-failed` | The inbox write failed. |
| 503 | `busy` | More than 16 requests in flight (legitimate concurrency is about 1). |

Each connection must deliver its whole request (request line, headers and body) within 10 s of being
accepted, however slowly it sends, and no single read may stall for more than 5 s. A client that misses the
deadline while still sending headers is disconnected without a response (logged as `status=0
outcome=timeout`), so slow-drip clients cannot hold the 16 in-flight slots. Keeping the receiver busy then
needs a sustained connection flood, which the TLS-terminating front is expected to rate-limit.

### Inbox contract

The consumer ([Intake: fetch and unpack](#intake-fetch-and-unpack)) reads `$DARK_FACTORY_DIR/agentarena/inbox/`:

- one file per task, `<task_id>.json`, mode `0600`, in directories of mode `0700`;
- the content is the notification as canonical, strict RFC 8259 JSON (sorted keys, no whitespace, ASCII
  escapes, finite numbers only, no lone surrogates, nesting depth at most 32) plus one
  trailing newline;
- a file appears complete or not at all (written to a temp file, fsynced, then hard-linked into place);
- the first notification for a task_id wins; a re-delivery while the file exists is acknowledged and dropped;
- dot-prefixed `.incoming-*` files are in-progress temp files and must be ignored.

## Intake: fetch and unpack

`dark-factory/run-agentarena-intake.sh` (#2326) consumes the inbox. Per task it fetches the TaskResponse
(`task_details_url`) and the repo zip (`task_repository_url`) with the platform's `X-API-Key`, validates both
and unpacks the code into `$DARK_FACTORY_DIR/agentarena/<task_id>/`. The script is a thin shim; all logic is
in `dark-factory/lib/agentarena-intake.py` (stdlib only, Python >= 3.8). HTTP goes through `curl` (>= 7.63).
The intake is read-only toward the platform: it never reads or requests `post_findings_url`.

### Running it

```bash
AGENTARENA_API_KEY='secret://libsecret/agentarena/api-key' dark-factory/run-agentarena-intake.sh --task <id>
AGENTARENA_API_KEY='secret://libsecret/agentarena/api-key' dark-factory/run-agentarena-intake.sh --all
dark-factory/run-agentarena-intake.sh --task <id> --details-file details.json --zip-file repo.zip   # offline
dark-factory/run-agentarena-intake.sh --self-test     # offline, exit 0/1
```

| Env | Meaning |
|-----|---------|
| `AGENTARENA_API_KEY` | Live path only. A `secret://` URI resolved in-process by `tools/parse-toml-secret.py`, or the raw key. It reaches curl as one header line on stdin (`-H @-`), never in argv, and is removed from curl's environment together with `WEBHOOK_AUTH_TOKEN` and any variable holding the same value. |
| `AGENTARENA_API_HOSTS` | Comma-separated host suffixes the key may be sent to. Default `agentarena.nethermind.io`. |
| `DARK_FACTORY_DIR` | State root, default `~/.dark-factory`. |

| Flag | Meaning |
|------|---------|
| `--task <id>` | Process `inbox/<id>.json`. |
| `--all` | One sweep of `inbox/*.json`, sorted by name, dot-files ignored. No daemon or watch loop. |
| `--details-file F --zip-file F` | Offline hatch: both or neither, `--task` only. Reads local files instead of fetching; no network, no key resolved, no URL policy. |
| `--max-files N` | Archive member cap (default 50000). |
| `--max-bytes N` | Cap on the uncompressed total, also the download cap (default 1 GiB). |
| `--curl PATH` | curl binary (default `curl` on PATH). |
| `--self-test` | Offline self-test with a stub curl and a temp state root. |

Exit codes: `0` unpacked, skipped or no-op (for `--all` always, unless a usage or secret error stops the
sweep), `1` self-test failed, `2` usage/config error (bad task id, key unset on the live path, bad flag
combination), `3` `secret://` resolution failed, `4` refused (terminal policy violation), `5` deferred
(retryable).

### Pipeline

For each task, in this order:

1. **Inbox.** `inbox/<id>.json` must be a JSON object whose `task_id` equals the file stem, with string
   `task_details_url` and `task_repository_url`. Otherwise the task is refused and nothing is written.
2. **URL policy** (live path), on both URLs before any request: scheme `https`, no userinfo, port absent or
   443, the host is not an IP literal, and it equals an `AGENTARENA_API_HOSTS` suffix or is a subdomain of one.
   A violation defers the task (`reason=url-policy`, the log line names `AGENTARENA_API_HOSTS`) with nothing
   written. The platform's API host is not documented yet, so a first real task on another host lands here:
   that is fail-closed by design. Then the key is resolved, still before anything is written.
3. **Task dir and lock.** `agentarena/<id>/` (mode 0700) and an exclusive non-blocking `flock` on
   `<id>/.lock`; a busy lock defers. A task whose manifest already has a terminal status (`unpacked`, `skip`,
   `refused`) is a logged no-op. Leftovers of a crashed run (`.staging-*`, `*.part`, an unrecorded `repo/`) are
   removed.
4. **Fetch details.** One curl call per hop with `-q --proto =https --max-redirs 0 -s -H @-`, never `-L`:
   curl re-sends custom `-H` headers on every followed redirect, including to other hosts. Redirects (301, 302,
   303, 307, 308) are followed by hand, at most 3, each target must be https without userinfo, and the key is
   attached only to hops that pass the full URL policy (so a presigned storage host never sees it). The body is
   streamed into `.details.part` and curl is killed at the cap. URLs are never logged.
5. **Validate details.** At most 2 MiB, a strict JSON object (`NaN`/`Infinity` rejected), `selectedFiles`
   absent or a list of strings. Stored as `details.json` (0600, bytes as received). If neither `id` nor
   `taskId` equals the task_id, the manifest records `details_id_match: false` and the log line carries
   `warn=details-id-mismatch`; this is not a refusal, because the docs do not say which field carries the
   notification id (#2331 settles it).
6. **Chain gate** (OOS3). Only EVM tasks are hunted. If `selectedFiles` is non-empty and no entry ends in
   `.sol`, `.vy` or `.yul` (case-insensitive), the task is skipped `non-evm` and the zip is never fetched. If
   `selectedFiles` is empty, the same test runs on the archive's member names after the pre-scan, before
   anything is extracted. There is no Solana switch while #2335 is open.
7. **Fetch the zip** the same way into `.repo.zip.part`, capped at `--max-bytes`. Its sha256 is recorded.
8. **Central-directory pre-scan**, before any byte is written; the first violation refuses the whole archive.
   Python's `extract()`/`extractall()` are never used: they rewrite hostile names instead of refusing them and
   enforce no caps.
9. **Extract** into `.staging-<pid>/`, then `rename` to `repo/`. A single shared top-level directory is
   stripped (the agent template resolves `selectedFiles` against it, and it keeps the repo's name out of the
   manifest). Directories are created 0700 and files 0600 with `O_EXCL|O_NOFOLLOW` (no exec bits). Copies are
   streamed with a running byte count, so a lying size header or an overlapping-entry bomb stops at the cap.
   In-repo symlinks are never materialized: they are skipped and counted in `symlinks_skipped`.

Every exit path deletes the zip part and the staging dir. A refusal leaves only `manifest.json`, `.lock` and
possibly `details.json`.

### Statuses

`intake.status` in the manifest, with the `reason` token:

| Status | Reason | When |
|--------|--------|------|
| `unpacked` | (empty) | `repo/` is in place. |
| `skip` | `non-evm` | No `.sol`/`.vy`/`.yul` in `selectedFiles`, or in the archive when `selectedFiles` is empty. |
| `refused` | `details-too-large`, `details-invalid` | TaskResponse over 2 MiB, not a strict JSON object, or a bad `selectedFiles`. |
| `refused` | `zip-too-large` | The download exceeded `--max-bytes`. |
| `refused` | `zip-invalid` | Not a zip, an encrypted member, unsupported compression, or a corrupt stream. |
| `refused` | `too-many-files`, `too-many-bytes` | Over `--max-files`; declared or actually streamed bytes over `--max-bytes`, or a member larger than its header says. |
| `refused` | `zip-slip` | A member name (after mapping `\` to `/`) that is absolute (`/...`, `C:`) or has a `..` component. |
| `refused` | `zip-bad-name` | A control character, a component over 255 bytes, or a path over 4096 bytes. |
| `refused` | `zip-duplicate` | Two members that normalize to the same path, or one path used as both a file and a directory. |
| `refused` | `zip-special-file` | A FIFO, device or socket member. |
| `refused` | `zip-symlink-escape` | A symlink whose target is absolute or resolves outside the repo root. |
| `deferred` | `fetch-http-<code>`, `fetch-curl-<n>`, `fetch-redirect-policy`, `fetch-too-many-redirects` | A fetch failed; the next run retries. |
| `deferred` | `extract-io-error`, `io-error` | A local I/O failure (for example a full disk). |

Refusals before the task dir exists (inbox problems: `inbox-missing`, `inbox-invalid`, `inbox-id-mismatch`)
and deferrals before it (`url-policy`, `lock-busy`) are logged but write no manifest. Each task logs one
stderr line: `agentarena-intake: <UTC> task_id=<id> status=<s> reason=<token> entries=N bytes=N`, with ids,
numbers and enum tokens only.

### Caps

| Cap | Default | Why |
|-----|---------|-----|
| Archive members (`--max-files`) | 50,000 | On 29 local audit-target checkouts (several are one repo at different commits), `git ls-files --recurse-submodules` peaks at 12,419 files, median about 1,200: 4x headroom. Below about 12.5k a real repo of the measured kind is refused; above, the only gain is more inodes a hostile archive can cost. |
| Uncompressed total and download (`--max-bytes`) | 1 GiB | The measured peak is 315 MiB of tracked bytes including submodules: about 3x headroom. Below about 320 MiB the largest measured repo is refused; above, a bomb can take more of the disk the hunts share. One knob covers both because a zip holds at most its members' bytes plus per-entry headers. |
| TaskResponse | 2 MiB | Metadata plus free-text `additionalDocs`/`qaResponses`; 2 MiB is about 1,000 pages of plain text. Smaller risks refusing a pasted spec; larger only grows what a hostile endpoint can make us store. |
| Redirect hops | 3 | One hop covers a redirect to presigned storage, 3 tolerates one more canonicalizing hop; beyond that is a loop. |
| curl `--max-time` | 120 s details, 1800 s zip | 2 MiB at >= 17 KB/s and 1 GiB at >= 0.6 MB/s. A slower intake would eat into a deadline-bounded hunt, whose default margin is 45 min (#2328). |

The caps were calibrated on our own audit targets, not on AgentArena tasks; the manifest records `entries`
and `bytes` so the first real tasks can recalibrate them.

### Task dir and manifest contract

```
$DARK_FACTORY_DIR/agentarena/<task_id>/
  manifest.json   the handoff contract below
  .lock           flock(2) target for every stage that touches the task dir
  details.json    the TaskResponse, bytes as received (0600)
  repo/           the repo root (0700 dirs, 0600 files)
```

```json
{"schema":"agentarena-task/1","task_id":"<id>",
 "intake":{"status":"unpacked|skip|refused|deferred","reason":"<token or empty>","chain":"evm|non-evm|unknown",
   "details_sha256":"...","details_bytes":0,"details_id_match":true,
   "zip_sha256":"...","zip_bytes":0,"entries":0,"files":0,"bytes":0,"symlinks_skipped":0,"top_dir_stripped":true,
   "max_files":0,"max_bytes":0,"offline":false,"attempts":1,"started_at":"<UTC ISO>","finished_at":"<UTC ISO>"}}
```

- The manifest holds only numbers, ids, hashes and enum tokens: no file names, URLs or text. The retention
  purge (#2330) keeps it when it removes the code.
- It is written atomically (temp file, fsync, `os.replace`) under `<id>/.lock`.
- Later stages add their own top-level key (`hunt` for #2328, `staging` for #2329, `submit` for #2332) by
  read-modify-write under `<id>/.lock` plus an atomic replace, and never rewrite `intake`. The intake itself
  preserves other top-level keys when it rewrites `intake` on a retry.
- `attempts` counts runs that reached the task dir; a deferred task is retried by the next run.

## Exposure

Exposing the receiver to the platform is the operator's choice (#2320) and is not automated. Two generic
options:

- **Tunnel:** a tunnel client on the host terminates TLS at the tunnel provider and forwards to
  `http://127.0.0.1:8421`.
- **VM:** a small public VM runs a TLS-terminating reverse proxy that forwards to the receiver listening on
  loopback on that VM.

In both, TLS terminates in front of the receiver and the front forwards to a loopback listener. Register
exactly `https://<public-host>/webhook` with the platform, then use the platform's Test connection button.

Never expose the receiver over plain HTTP: the token travels in the `Authorization` header and would be sent
in cleartext. The receiver therefore refuses a non-loopback `--bind`; `--allow-non-loopback` exists only for a
TLS-terminating front that reaches the receiver over a private interface on the same host or container.
