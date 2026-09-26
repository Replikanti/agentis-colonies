#!/usr/bin/env python3
# model-attribution.py — #2157 (milestone D3, epic #2130) per-request, per-STAGE model attribution over
# persisted Claude Code transcripts. It answers the D3 honesty question directly: did the ANALYSIS stages
# actually run on Fable, or did Fable silently fall back to Opus (which would VOID any Fable-capability claim)?
#
# The failure mode this guards (see the operator note "Claude Code tichy refusal fallback Fable->Opus 4.8"):
# Claude Code can silently answer a refused Fable request by FALLING BACK to a production model, emitting a
# content block of type "fallback" and NO refusal stop_reason. A run that looks pure-Fable in the config can
# therefore be Opus underneath. This tool reads the persisted transcripts (persistence ON) and, per assistant
# request, records the answering model, whether a fallback content block fired, and whether it was an explicit
# refusal — then rolls those up per STAGE and prints a verdict per stage:
#   PURE-<model>   every request answered by one model family, zero fallbacks   -> the routing held
#   MIXED          >1 model family in the stage (a fallback or a mis-route)      -> attribution contaminated
#   CONTAMINATED   at least one fallback content block                          -> silent Fable->Opus fallback
#
# CONTAMINATION DISCIPLINE: this tool bakes in NO target-specific token and NO protocol name. Model families
# are matched on GENERIC substrings (opus / fable / sonnet / haiku); the STAGE label is supplied by the caller
# (a --stage tag, or the immediate sub-directory name under --dir), never inferred from a contest path.
#
# Usage:
#   model-attribution.py [--json] [--stage NAME] TRANSCRIPT.jsonl ...   # one stage over the given transcripts
#   model-attribution.py [--json] --dir ROOT                           # each immediate sub-dir of ROOT is a
#                                                                        # stage; its *.jsonl are that stage's
#                                                                        # transcripts (recursively)
#   model-attribution.py --self-test                                    # deterministic fixture assertions
#   ... [--since ISO] [--until ISO]    #2262 M3: count only assistant records whose `timestamp` falls in the run
#                                      window (either bound may be omitted). A record WITHOUT a timestamp is KEPT:
#                                      conservative, a window can only turn PURE into MIXED/CONTAMINATED, never
#                                      hide a fallback. A bound without fractional seconds covers its whole second
#                                      (run.meta writes second-resolution UTC). Claude Code keys its transcript
#                                      store by the cwd string, so a re-run in the same dir shares the store with
#                                      a voided earlier attempt: the window separates the two.
#
# Output (stdout, table): one row per stage
#   STAGE \t REQUESTS \t FABLE \t OPUS \t OTHER \t FALLBACK \t REFUSAL \t VERDICT
# then a TOTAL row. With --json, a JSON object keyed by stage instead.
# Only when a window is given, a trailer line `WINDOW \t since \t until \t in \t out \t undated` follows (in =
# dated records inside the window, out = dated records dropped, undated = records kept without a timestamp; an
# open bound prints `-`); with --json the same counts sit under a top-level "_window" key. Without a window the
# output is byte-identical to the pre-window tool.
#
# Exit: 0 = ran (or --self-test held) ; 1 = --self-test regressed ; 2 = bad args ; 3 = no transcripts found.
# Deterministic, offline: reads local files only. No network, no LLM, no forge.
import sys
import os
import json
import glob
import datetime


def model_family(model):
    """Generic family bucket from a model id — no target/protocol token, substring match only."""
    m = (model or "").lower()
    for fam in ("opus", "fable", "sonnet", "haiku"):
        if fam in m:
            return fam
    return "other"


def parse_ts(text):
    """ISO-8601 UTC -> (aware datetime, has_fraction), or None when unparseable. Accepts `Z` / `+00:00`."""
    if not isinstance(text, str) or not text:
        return None
    t = text.strip()
    if t.endswith("Z") or t.endswith("z"):
        t = t[:-1] + "+00:00"
    frac = "." in t.split("T", 1)[-1]
    try:
        dt = datetime.datetime.fromisoformat(t)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt, frac


class Window(object):
    """The --since/--until run window. `since` is inclusive; a second-resolution `until` covers its whole second."""

    def __init__(self, since, until):
        self.since_raw, self.until_raw = since, until
        self.lo = self.hi = None
        self.hi_inclusive = True
        if since:
            p = parse_ts(since)
            if p is None:
                raise ValueError("bad --since timestamp: %r" % since)
            self.lo = p[0]
        if until:
            p = parse_ts(until)
            if p is None:
                raise ValueError("bad --until timestamp: %r" % until)
            self.hi = p[0] if p[1] else p[0] + datetime.timedelta(seconds=1)
            self.hi_inclusive = p[1]
        self.n_in = self.n_out = self.n_undated = 0

    def keep(self, ev):
        """True when an assistant record counts. Records without a (parseable) timestamp are KEPT."""
        p = parse_ts(ev.get("timestamp"))
        if p is None:
            self.n_undated += 1
            return True
        ts = p[0]
        inside = (self.lo is None or ts >= self.lo) and (
            self.hi is None or (ts <= self.hi if self.hi_inclusive else ts < self.hi))
        if inside:
            self.n_in += 1
        else:
            self.n_out += 1
        return inside

    def trailer(self):
        return "WINDOW\t%s\t%s\t%d\t%d\t%d" % (self.since_raw or "-", self.until_raw or "-",
                                                self.n_in, self.n_out, self.n_undated)

    def as_json(self):
        return {"since": self.since_raw or "-", "until": self.until_raw or "-",
                "in": self.n_in, "out": self.n_out, "undated": self.n_undated}


def scan_transcript(path, window=None):
    """Yield (family, is_fallback, is_refusal) per assistant request in one JSONL transcript (inside `window`)."""
    try:
        fh = open(path, encoding="utf-8", errors="ignore")
    except OSError:
        return
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if not isinstance(ev, dict):
                continue
            msg = ev.get("message")
            # Only assistant requests carry an answering model. A transcript may nest the model at the top level
            # or under `message` depending on the exporter; accept either.
            if isinstance(msg, dict) and msg.get("role") == "assistant":
                model = msg.get("model") or ev.get("model", "")
                content = msg.get("content", [])
                stop_reason = msg.get("stop_reason", "")
            elif ev.get("type") == "assistant" and isinstance(msg, dict):
                model = msg.get("model") or ev.get("model", "")
                content = msg.get("content", [])
                stop_reason = msg.get("stop_reason", "")
            else:
                continue
            if window is not None and not window.keep(ev):
                continue
            is_fallback = False
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "fallback":
                        is_fallback = True
                        break
            is_refusal = (stop_reason == "refusal")
            yield (model_family(model), is_fallback, is_refusal)


def aggregate(stage_to_paths, window=None):
    """stage_to_paths: dict stage -> list of transcript paths. Returns dict stage -> counts."""
    out = {}
    for stage in sorted(stage_to_paths):
        req = fam_counts = None
        req = 0
        fam_counts = {"opus": 0, "fable": 0, "sonnet": 0, "haiku": 0, "other": 0}
        fallback = 0
        refusal = 0
        for path in stage_to_paths[stage]:
            for fam, is_fb, is_ref in scan_transcript(path, window):
                req += 1
                fam_counts[fam] = fam_counts.get(fam, 0) + 1
                if is_fb:
                    fallback += 1
                if is_ref:
                    refusal += 1
        families_used = [f for f, n in fam_counts.items() if n > 0]
        if fallback > 0:
            verdict = "CONTAMINATED"
        elif len(families_used) > 1:
            verdict = "MIXED"
        elif len(families_used) == 1:
            verdict = "PURE-" + families_used[0].upper()
        else:
            verdict = "EMPTY"
        out[stage] = {
            "requests": req,
            "fable": fam_counts["fable"],
            "opus": fam_counts["opus"],
            "sonnet": fam_counts["sonnet"],
            "haiku": fam_counts["haiku"],
            "other": fam_counts["other"],
            "fallback": fallback,
            "refusal": refusal,
            "verdict": verdict,
        }
    return out


def render_table(agg):
    rows = ["STAGE\tREQUESTS\tFABLE\tOPUS\tOTHER\tFALLBACK\tREFUSAL\tVERDICT"]
    tot = {"requests": 0, "fable": 0, "opus": 0, "other": 0, "fallback": 0, "refusal": 0}
    for stage in sorted(agg):
        s = agg[stage]
        other = s["sonnet"] + s["haiku"] + s["other"]
        rows.append("%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s" % (
            stage, s["requests"], s["fable"], s["opus"], other, s["fallback"], s["refusal"], s["verdict"]))
        tot["requests"] += s["requests"]
        tot["fable"] += s["fable"]
        tot["opus"] += s["opus"]
        tot["other"] += other
        tot["fallback"] += s["fallback"]
        tot["refusal"] += s["refusal"]
    rows.append("TOTAL\t%d\t%d\t%d\t%d\t%d\t%d\t-" % (
        tot["requests"], tot["fable"], tot["opus"], tot["other"], tot["fallback"], tot["refusal"]))
    return "\n".join(rows)


def collect_dir(root):
    stage_to_paths = {}
    for entry in sorted(os.listdir(root)):
        sub = os.path.join(root, entry)
        if not os.path.isdir(sub):
            continue
        paths = sorted(glob.glob(os.path.join(sub, "**", "*.jsonl"), recursive=True))
        if paths:
            stage_to_paths[entry] = paths
    return stage_to_paths


def run_self_test():
    here = os.path.dirname(os.path.abspath(__file__))
    fx = os.path.join(here, "fixtures", "model-attribution")
    fails = 0

    def ok(m):
        print("  [PASS] %s" % m)

    def bad(m):
        nonlocal fails
        print("  [FAIL] %s" % m)
        fails += 1

    if not os.path.isdir(fx):
        print("model-attribution.py: fixture dir missing: %s" % fx, file=sys.stderr)
        return 3

    agg = aggregate(collect_dir(fx))
    print("model-attribution.py: --self-test over %s" % fx)
    print(render_table(agg))

    # The fixture encodes four stages (contamination-safe, generic stage names):
    #   analysis-fable      : 3 pure-Fable requests, no fallback -> PURE-FABLE (the D1 headline stays clean)
    #   analysis-tainted    : 2 requests, one a Fable->Opus fallback content block -> CONTAMINATED
    #   poc-opus            : 2 pure-Opus requests -> PURE-OPUS (the D2 PoC step, honestly Opus)
    #   poc-toplevel-model  : 1 request with the model id at the TOP LEVEL of the event (not nested under
    #                         `message`) -> PURE-FABLE (#2166: a transcript shape with a top-level `model`
    #                         must not degrade to `other`)
    exp = {
        "analysis-fable": {"requests": 3, "fable": 3, "opus": 0, "fallback": 0, "refusal": 0, "verdict": "PURE-FABLE"},
        "analysis-tainted": {"requests": 2, "fable": 1, "opus": 1, "fallback": 1, "refusal": 0, "verdict": "CONTAMINATED"},
        "poc-opus": {"requests": 2, "fable": 0, "opus": 2, "fallback": 0, "refusal": 0, "verdict": "PURE-OPUS"},
        "poc-toplevel-model": {"requests": 1, "fable": 1, "opus": 0, "fallback": 0, "refusal": 0, "verdict": "PURE-FABLE"},
    }
    for stage, e in exp.items():
        if stage not in agg:
            bad("stage %r missing from the attribution table" % stage)
            continue
        a = agg[stage]
        mism = [k for k in e if a.get(k) != e[k]]
        if not mism:
            ok("stage %r attributed correctly (%d req, fable=%d opus=%d fallback=%d -> %s)"
               % (stage, e["requests"], e["fable"], e["opus"], e["fallback"], e["verdict"]))
        else:
            bad("stage %r mis-attributed on %s: got %r expected %r"
                % (stage, mism, {k: a.get(k) for k in mism}, {k: e[k] for k in mism}))

    # The load-bearing D3 guarantee: the tool FLAGS a silent Fable->Opus fallback rather than counting it as
    # Fable. If analysis-tainted came back PURE-FABLE the tool would be useless for the D1 purity claim.
    if agg.get("analysis-tainted", {}).get("verdict") == "CONTAMINATED":
        ok("a silent Fable->Opus fallback block is flagged CONTAMINATED (not silently counted as Fable)")
    else:
        bad("a fallback content block was NOT flagged — the D1 purity claim would be unprovable")

    # #2262 M3 run-window filter, over its own SIBLING fixture (fixtures/model-attribution-window/) so the table
    # above stays byte-identical. The one stage holds, in one transcript store dir reused by two attempts:
    #   2 Opus records inside the window, 1 undated Opus record (kept), and 1 Fable->Opus FALLBACK record plus 1
    #   Fable record from an EARLIER (voided) attempt, dated before the window.
    wfx = os.path.join(here, "fixtures", "model-attribution-window")
    if not os.path.isdir(wfx):
        bad("window fixture dir missing: %s" % wfx)
    else:
        wpaths = collect_dir(wfx)
        raw = aggregate(wpaths)
        win = Window("2026-01-01T10:00:00Z", "2026-01-01T11:00:00Z")
        windowed = aggregate(wpaths, win)
        st = "rerun-same-cwd"
        rv, wv = raw.get(st, {}).get("verdict"), windowed.get(st, {}).get("verdict")
        if rv == "CONTAMINATED":
            ok("window: the unwindowed read of the shared store is CONTAMINATED by the voided attempt's fallback")
        else:
            bad("window: the unwindowed read should be CONTAMINATED, got %r" % rv)
        if wv == "PURE-OPUS" and windowed[st]["requests"] == 3 and windowed[st]["fallback"] == 0:
            ok("window: --since/--until keeps the 2 in-window + 1 undated records and reads PURE-OPUS")
        else:
            bad("window: the windowed read should be PURE-OPUS over 3 requests, got %r" % windowed.get(st))
        if (win.n_in, win.n_out, win.n_undated) == (2, 2, 1):
            ok("window: trailer counts in=2 out=2 undated=1 (%s)" % win.trailer().replace("\t", " "))
        else:
            bad("window: trailer counts wrong: %s" % win.trailer().replace("\t", " "))
        edge = Window("2026-01-01T10:00:00Z", "2026-01-01T10:59:59Z")
        edge_in = edge.keep({"timestamp": "2026-01-01T10:59:59.900Z"})
        edge_out = edge.keep({"timestamp": "2026-01-01T11:00:00.000Z"})
        if edge_in and not edge_out:
            ok("window: a second-resolution --until covers its whole second (10:59:59.900 in, 11:00:00.000 out)")
        else:
            bad("window: second-resolution --until edge wrong (in=%r out=%r)" % (edge_in, edge_out))

    print()
    if fails == 0:
        print("model-attribution.py: PASS — per-stage attribution counts models, flags fallbacks/refusals, and CONTAMINATES a stage that fell back")
        return 0
    print("model-attribution.py: FAIL — %d assertion(s) regressed" % fails, file=sys.stderr)
    return 1


def main(argv):
    if "--self-test" in argv:
        return run_self_test()
    as_json = False
    stage = None
    root = None
    since = until = None
    paths = []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--json":
            as_json = True
            i += 1
        elif a == "--stage":
            if i + 1 >= len(argv):
                print("model-attribution.py: --stage requires a value", file=sys.stderr)
                return 2
            stage = argv[i + 1]
            i += 2
        elif a == "--dir":
            if i + 1 >= len(argv):
                print("model-attribution.py: --dir requires a value", file=sys.stderr)
                return 2
            root = argv[i + 1]
            i += 2
        elif a in ("--since", "--until"):
            if i + 1 >= len(argv):
                print("model-attribution.py: %s requires a value" % a, file=sys.stderr)
                return 2
            if a == "--since":
                since = argv[i + 1]
            else:
                until = argv[i + 1]
            i += 2
        elif a in ("-h", "--help"):
            print(__doc__ if __doc__ else "see header comment")
            return 0
        elif a.startswith("-"):
            print("model-attribution.py: unknown arg: %s" % a, file=sys.stderr)
            return 2
        else:
            paths.append(a)
            i += 1

    if root:
        if not os.path.isdir(root):
            print("model-attribution.py: --dir not a directory: %s" % root, file=sys.stderr)
            return 3
        stage_to_paths = collect_dir(root)
    elif paths:
        stage_to_paths = {(stage or "stage"): paths}
    else:
        print("model-attribution.py: give transcripts (with optional --stage) or --dir ROOT", file=sys.stderr)
        return 2

    if not stage_to_paths:
        print("model-attribution.py: no transcripts found", file=sys.stderr)
        return 3

    window = None
    if since or until:
        try:
            window = Window(since, until)
        except ValueError as exc:
            print("model-attribution.py: %s" % exc, file=sys.stderr)
            return 2
    agg = aggregate(stage_to_paths, window)
    if as_json:
        if window is not None:
            agg["_window"] = window.as_json()
        print(json.dumps(agg, indent=2, sort_keys=True))
    else:
        print(render_table(agg))
        if window is not None:
            print(window.trailer())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
