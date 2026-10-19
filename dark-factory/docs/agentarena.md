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
is the intake's job (#2326). It writes nothing outside the inbox and touches no Slack, memo or export sink.
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
| 400 | `bad-request` | Bad `Content-Length`, short body, invalid JSON, not an object, missing or non-string `*_url`. |
| 400 | `bad-task-id` | `task_id` fails the pattern above. The log line records only its length and character classes. |
| 401 | `unauthorized` | Missing, wrong or repeated `Authorization` header. |
| 404 | `not-found` | Any path other than exactly `/webhook` (query strings included). |
| 405 | `method-not-allowed` | `/webhook` with a method other than POST (`Allow: POST`). |
| 411 | `length-required` | `Transfer-Encoding` present or `Content-Length` missing. |
| 413 | `too-large` | Declared `Content-Length` above 65536; the body is never read. |
| 500 | `write-failed` | The inbox write failed. |
| 503 | `busy` | More than 16 requests in flight (legitimate concurrency is about 1). |

A client that stalls for more than 5 s is dropped.

### Inbox contract

The consumer (#2326) reads `$DARK_FACTORY_DIR/agentarena/inbox/`:

- one file per task, `<task_id>.json`, mode `0600`, in directories of mode `0700`;
- the content is the notification as canonical JSON (sorted keys, no whitespace, ASCII escapes) plus one
  trailing newline;
- a file appears complete or not at all (written to a temp file, fsynced, then hard-linked into place);
- the first notification for a task_id wins; a re-delivery while the file exists is acknowledged and dropped;
- dot-prefixed `.incoming-*` files are in-progress temp files and must be ignored.

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
