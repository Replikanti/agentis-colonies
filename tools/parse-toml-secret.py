#!/usr/bin/env python3
"""parse-toml-secret.py - TOML key lookup with optional secret-URI resolution.

Replaces the inline python heredoc that used to live in
tools/parse-toml.sh. Same input/output contract: read $1 as the
TOML path, $2 as the section, $3 as the key; print the first matching
value on stdout. New in #321: if the resolved value starts with
`secret://`, dispatch to a backend resolver and print the plaintext
token instead.

Extraction follows the auto-promote-config-parser.py / federation-
dashboard-*.py precedent (#170, #172, #245): the macOS bash 3.2
parser miscompiles python heredocs in some shapes, and a separate
.py file invoked via `python3 tools/parse-toml-secret.py ...` sidesteps
the bug. See the no-heredoc invariant in CLAUDE.md and the bash-3.2
portability refinement on issue #321.

URI grammar (additive, opt-in):

    secret://libsecret/<service>/<key>     Linux GNOME-Keyring
    secret://keychain/<service>/<account>  macOS
    secret://pass/<path>                   passwordstore.org
    secret://env/<VAR>                     existing ${VAR} idiom

Backends are dispatched via subprocess.run; URI segments are
URL-decoded before they reach argv. Any segment containing a
backslash followed by a newline is rejected up front (defence
against argv injection on `secret-tool` / `security`).

Failure modes:

    exit 0  resolved (plaintext printed to stdout)
    exit 2  usage error
    exit 3  backend binary missing on PATH
    exit 4  key not found in vault (no token leaked)
    exit 5  vault locked / unavailable
    exit 6  unknown scheme / malformed URI

Args (positional):
    1: path     — TOML file
    2: section  — `[<section>]` to scope key lookup to
    3: key      — TOML key under that section

A two-arg invocation `parse-toml-secret.py --resolve <value>` is
also supported for callers that already have the raw TOML value and
just want the secret-URI dispatch (used by the unit tests).
"""
import os
import subprocess
import sys
import urllib.parse


# ---------------- TOML lookup ----------------

def _strip_inline_comment(line):
    """Strip a trailing `# comment` from a TOML line, respecting quoted
    strings so a `#` inside `"..."` or `'...'` is preserved."""
    out = []
    quote = None
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(line[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
        else:
            if ch == "#":
                break
            if ch in ('"', "'"):
                quote = ch
            out.append(ch)
        i += 1
    return "".join(out)


def lookup(path, section, key):
    """Return the raw TOML value for `[section] key = ...`, or '' if absent."""
    in_section = False
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = _strip_inline_comment(raw).rstrip("\n")
            stripped = line.strip()
            if stripped.startswith("[") and stripped.endswith("]"):
                sect_name = stripped[1:-1].strip()
                in_section = (sect_name == section)
                continue
            if not in_section:
                continue
            if not stripped.startswith(key):
                continue
            rest = stripped[len(key):].lstrip()
            if not rest.startswith("="):
                continue
            value = rest[1:].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                value = value[1:-1]
            return value
    return ''


# ---------------- Array-of-tables lookup (#316 M1) ----------------

def _array_lookup(path, section):
    """Return list[dict] for every `[[<section>]]` block in source order.

    Each dict carries the raw `key = value` pairs found inside that array
    entry, with surrounding quotes stripped (mirrors `lookup()`).

    Single-table headers `[<section>]` and any other `[...]` headers
    close the currently open entry (a single-table sibling section ends
    array-entry parsing for `<section>`).

    `secret://` URIs are returned as-is — the caller resolves on demand
    via `--array-get`, never at walk time, so callers that only count
    do not pay a `secret-tool` round-trip per entry.
    """
    entries = []
    in_array = False
    array_header = "[[" + section + "]]"
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = _strip_inline_comment(raw).rstrip("\n")
            stripped = line.strip()
            if stripped.startswith("[[") and stripped.endswith("]]"):
                hdr = stripped[2:-2].strip()
                if hdr == section:
                    entries.append({})
                    in_array = True
                else:
                    in_array = False
                continue
            if stripped.startswith("[") and stripped.endswith("]"):
                in_array = False
                continue
            if not in_array:
                continue
            if "=" not in stripped:
                continue
            key_part, _, value_part = stripped.partition("=")
            k = key_part.strip()
            if not k:
                continue
            value = value_part.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                value = value[1:-1]
            entries[-1][k] = value
    return entries


def _array_main(argv):
    """Dispatch the three new array-of-tables argv shapes.

    --array-count <path> <section>            -> integer count on stdout
    --array-get   <path> <section> <idx> <key> -> scalar (resolves secret://)
    --array-keys  <path> <section> <idx>       -> newline-separated key list
    """
    op = argv[0]
    if op == '--array-count':
        if len(argv) != 3:
            sys.stderr.write('Usage: %s --array-count <path> <section>\n' % sys.argv[0])
            return 2
        _, path, section = argv
        entries = _array_lookup(path, section)
        sys.stdout.write('%d\n' % len(entries))
        return 0
    if op == '--array-get':
        if len(argv) != 5:
            sys.stderr.write('Usage: %s --array-get <path> <section> <idx> <key>\n' % sys.argv[0])
            return 2
        _, path, section, idx_str, key = argv
        try:
            idx = int(idx_str)
        except ValueError:
            sys.stderr.write('parse-toml-secret: --array-get IDX must be an integer (got %r)\n' % idx_str)
            return 2
        entries = _array_lookup(path, section)
        if idx < 0 or idx >= len(entries):
            return 0
        value = entries[idx].get(key, '')
        if not value:
            return 0
        if value.startswith('secret://'):
            sys.stdout.write(resolve(value))
            sys.stdout.write('\n')
        else:
            sys.stdout.write(value)
            sys.stdout.write('\n')
        return 0
    if op == '--array-keys':
        if len(argv) != 4:
            sys.stderr.write('Usage: %s --array-keys <path> <section> <idx>\n' % sys.argv[0])
            return 2
        _, path, section, idx_str = argv
        try:
            idx = int(idx_str)
        except ValueError:
            sys.stderr.write('parse-toml-secret: --array-keys IDX must be an integer (got %r)\n' % idx_str)
            return 2
        entries = _array_lookup(path, section)
        if idx < 0 or idx >= len(entries):
            return 0
        for k in entries[idx].keys():
            sys.stdout.write(k)
            sys.stdout.write('\n')
        return 0
    sys.stderr.write('parse-toml-secret: unknown array op %r\n' % op)
    return 2


# ---------------- secret:// resolution ----------------

def _decode_segment(seg):
    """URL-decode a URI path segment and reject backslash+newline."""
    decoded = urllib.parse.unquote(seg)
    if '\\\n' in decoded or '\\\r' in decoded:
        sys.stderr.write('parse-toml-secret: refusing segment with backslash+newline (argv injection guard)\n')
        sys.exit(6)
    return decoded


def _which(cmd):
    """POSIX `command -v` equivalent. Returns absolute path or None."""
    for d in os.environ.get('PATH', '').split(os.pathsep):
        if not d:
            continue
        candidate = os.path.join(d, cmd)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _resolve_libsecret(parts):
    if len(parts) < 2:
        sys.stderr.write('parse-toml-secret: libsecret URI needs <service>/<key>\n')
        sys.exit(6)
    service = _decode_segment(parts[0])
    key = _decode_segment('/'.join(parts[1:]))
    if _which('secret-tool') is None:
        sys.stderr.write('parse-toml-secret: secret-tool not on PATH (libsecret backend unavailable)\n')
        sys.exit(3)
    try:
        result = subprocess.run(
            ['secret-tool', 'lookup', 'service', service, 'key', key],
            capture_output=True, text=True, check=False,
        )
    except OSError as e:
        sys.stderr.write('parse-toml-secret: secret-tool spawn failed: %s\n' % e)
        sys.exit(5)
    if result.returncode != 0:
        sys.stderr.write('parse-toml-secret: libsecret key not found (service=%s)\n' % service)
        sys.exit(4)
    out = result.stdout
    if out.endswith('\n'):
        out = out[:-1]
    if not out:
        sys.stderr.write('parse-toml-secret: libsecret returned empty value\n')
        sys.exit(4)
    return out


def _resolve_keychain(parts):
    if len(parts) < 2:
        sys.stderr.write('parse-toml-secret: keychain URI needs <service>/<account>\n')
        sys.exit(6)
    service = _decode_segment(parts[0])
    account = _decode_segment('/'.join(parts[1:]))
    if _which('security') is None:
        sys.stderr.write('parse-toml-secret: security not on PATH (macOS keychain backend unavailable)\n')
        sys.exit(3)
    try:
        result = subprocess.run(
            ['security', 'find-generic-password', '-s', service, '-a', account, '-w'],
            capture_output=True, text=True, check=False,
        )
    except OSError as e:
        sys.stderr.write('parse-toml-secret: security spawn failed: %s\n' % e)
        sys.exit(5)
    if result.returncode != 0:
        sys.stderr.write('parse-toml-secret: keychain key not found (service=%s)\n' % service)
        sys.exit(4)
    out = result.stdout
    if out.endswith('\n'):
        out = out[:-1]
    if not out:
        sys.stderr.write('parse-toml-secret: keychain returned empty value\n')
        sys.exit(4)
    return out


def _resolve_pass(parts):
    if not parts or not parts[0]:
        sys.stderr.write('parse-toml-secret: pass URI needs <path>\n')
        sys.exit(6)
    path = _decode_segment('/'.join(parts))
    if _which('pass') is None:
        sys.stderr.write('parse-toml-secret: pass not on PATH (passwordstore backend unavailable)\n')
        sys.exit(3)
    try:
        result = subprocess.run(
            ['pass', 'show', path],
            capture_output=True, text=True, check=False,
        )
    except OSError as e:
        sys.stderr.write('parse-toml-secret: pass spawn failed: %s\n' % e)
        sys.exit(5)
    if result.returncode != 0:
        first_err = (result.stderr or '').splitlines()
        hint = first_err[0] if first_err else 'unknown error'
        sys.stderr.write('parse-toml-secret: pass cannot resolve %s (%s)\n' % (path, hint))
        # Distinguish locked GPG agent (recoverable on next call) from
        # missing entry (config bug). Best effort — `pass` does not have
        # a stable exit-code contract for this distinction.
        if 'gpg' in hint.lower() or 'lock' in hint.lower():
            sys.exit(5)
        sys.exit(4)
    out = result.stdout
    if '\n' in out:
        out = out.split('\n', 1)[0]
    if not out:
        sys.stderr.write('parse-toml-secret: pass returned empty value for %s\n' % path)
        sys.exit(4)
    return out


def _resolve_env(parts):
    if not parts or not parts[0]:
        sys.stderr.write('parse-toml-secret: env URI needs <VAR>\n')
        sys.exit(6)
    var = _decode_segment(parts[0])
    val = os.environ.get(var)
    if val is None or val == '':
        sys.stderr.write('parse-toml-secret: env var %s unset or empty\n' % var)
        sys.exit(4)
    return val


def resolve(value):
    """Dispatch a `secret://...` URI to its backend. Returns plaintext."""
    if not value.startswith('secret://'):
        return value
    rest = value[len('secret://'):]
    if not rest:
        sys.stderr.write('parse-toml-secret: empty URI after scheme\n')
        sys.exit(6)
    segments = rest.split('/')
    backend = segments[0]
    rest_parts = segments[1:]
    if backend == 'libsecret':
        return _resolve_libsecret(rest_parts)
    if backend == 'keychain':
        return _resolve_keychain(rest_parts)
    if backend == 'pass':
        return _resolve_pass(rest_parts)
    if backend == 'env':
        return _resolve_env(rest_parts)
    sys.stderr.write('parse-toml-secret: unknown backend %r (expected libsecret/keychain/pass/env)\n' % backend)
    sys.exit(6)


# ---------------- entry point ----------------

def main():
    argv = sys.argv[1:]
    # `--resolve <value>` two-arg mode for callers that already have the raw value.
    if len(argv) == 2 and argv[0] == '--resolve':
        value = argv[1]
        if value.startswith('secret://'):
            sys.stdout.write(resolve(value))
            sys.stdout.write('\n')
        else:
            sys.stdout.write(value)
            sys.stdout.write('\n')
        return 0
    # New (#316 M1): array-of-tables count + per-index lookup. Three argv shapes:
    #   --array-count <path> <section>            -> integer count on stdout
    #   --array-get   <path> <section> <idx> <key> -> scalar value or empty
    #   --array-keys  <path> <section> <idx>       -> newline-separated key list
    # `<section>` is the inner-table name, e.g. `forge.github`. The lookup
    # walks `[[<section>]]` headers in order, 0-indexed.
    if argv and argv[0] in ('--array-count', '--array-get', '--array-keys'):
        return _array_main(argv)
    if len(argv) != 3:
        sys.stderr.write('Usage: %s <path> <section> <key>\n' % sys.argv[0])
        sys.stderr.write('   or: %s --resolve <value>\n' % sys.argv[0])
        return 2
    path, section, key = argv
    value = lookup(path, section, key)
    if not value:
        # Empty / missing key — preserve the legacy passthrough (just print
        # the empty line so the shell-side $(...) capture is empty).
        return 0
    if value.startswith('secret://'):
        sys.stdout.write(resolve(value))
        sys.stdout.write('\n')
    else:
        sys.stdout.write(value)
        sys.stdout.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
