#!/usr/bin/env python3
"""federation-dashboard-renderer.py - Render index.html from template + data.

Extracted from federation-dashboard.sh in #172 to eliminate the entire class
of bash heredoc parser bugs. The previous fix (#170) only extracted Python
heredocs nested in $(); the JS/CSS/HTML heredocs that remained still triggered
the macOS bash 3.2 / 5.3 parser at line 962 (escaped single quote inside a
quoted heredoc body).

This script reads the static template `federation-dashboard.html.template`
and substitutes 10 named sentinels with values supplied as positional args.

DO NOT inline this back into federation-dashboard.sh: the regression test
test-timeline-rendering.sh #16 enforces zero heredocs in the shell script.

Args (positional):
    1: template_path     path to federation-dashboard.html.template
    2: output_path       where to write the rendered HTML
    3: fed_name          federation display name
    4: fed_name_js       JSON-encoded fed_name (e.g. "\"dev\"")
    5: colony_count      int as string
    6: agent_count       int as string
    7: epoch             int as string
    8: timestamp         human-readable timestamp string
    9: collector_json    JSON blob (string) or "@<path>" to read from file (#293)
   10: history_json      JSON blob (string) or "@<path>" to read from file (#293)
   11: remediation_json  JSON blob (string) or "@<path>" to read from file (#293)
   12: colony_list_js    JS array literal (already formatted)

The `@<path>` prefix on argv[9..11] is a #293 workaround for Linux's
MAX_ARG_STRLEN (128 KB per single argv string): after several hours of
accumulation the collector / history / remediation JSON blobs cross that
threshold and exec(2) fails with E2BIG. The wrapper spools large payloads
to temp files; values without the `@` prefix still pass through unchanged
for backward compatibility.
"""
import os
import re
import sys


def _read(arg):
    """Resolve `@<path>` argv prefix to file contents; otherwise pass through."""
    if arg.startswith('@'):
        with open(arg[1:], 'r', encoding='utf-8') as f:
            return f.read()
    return arg


def main():
    if len(sys.argv) != 13:
        sys.stderr.write(
            'Usage: %s template output fed_name fed_name_js '
            'colony_count agent_count epoch timestamp '
            'collector_json history_json remediation_json colony_list_js\n'
            % sys.argv[0]
        )
        sys.exit(2)

    template_path = sys.argv[1]
    output_path = sys.argv[2]
    substitutions = {
        '{{FED_NAME}}': sys.argv[3],
        '{{FED_NAME_JS}}': sys.argv[4],
        '{{COLONY_COUNT}}': sys.argv[5],
        '{{AGENT_COUNT}}': sys.argv[6],
        '{{EPOCH}}': sys.argv[7],
        '{{TIMESTAMP}}': sys.argv[8],
        '{{COLLECTOR_JSON}}': _read(sys.argv[9]),
        '{{HISTORY}}': _read(sys.argv[10]),
        '{{REMEDIATION}}': _read(sys.argv[11]),
        '{{COLONY_LIST_JS}}': sys.argv[12],
    }

    with open(template_path, 'r', encoding='utf-8') as f:
        html = f.read()

    # Single-pass substitution (#366): a value (notably {{COLLECTOR_JSON}}) can
    # contain the literal text of another sentinel — e.g. an agent's experience
    # row whose `out` field discusses "{{HISTORY}}" while reasoning about a
    # template change. A sequential `for s in subs: html.replace(s, v)` would
    # then re-substitute that literal in the next iteration and inject the
    # history payload into the collector data string, breaking
    # `const data = ...;` parsing in the browser. re.sub() advances past the
    # replacement value, so any sentinel literal inside a value is left intact.
    pattern = re.compile('|'.join(re.escape(s) for s in substitutions))
    html = pattern.sub(lambda m: substitutions[m.group(0)], html)

    tmp = output_path + '.tmp.' + str(os.getpid())
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(html)
    os.replace(tmp, output_path)


if __name__ == '__main__':
    main()
