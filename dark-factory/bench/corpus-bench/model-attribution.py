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
#
# Output (stdout, table): one row per stage
#   STAGE \t REQUESTS \t FABLE \t OPUS \t OTHER \t FALLBACK \t REFUSAL \t VERDICT
# then a TOTAL row. With --json, a JSON object keyed by stage instead.
#
# Exit: 0 = ran (or --self-test held) ; 1 = --self-test regressed ; 2 = bad args ; 3 = no transcripts found.
# Deterministic, offline: reads local files only. No network, no LLM, no forge.
import sys
import os
import json
import glob


def model_family(model):
    """Generic family bucket from a model id — no target/protocol token, substring match only."""
    m = (model or "").lower()
    for fam in ("opus", "fable", "sonnet", "haiku"):
        if fam in m:
            return fam
    return "other"


def scan_transcript(path):
    """Yield (family, is_fallback, is_refusal) per assistant request in one JSONL transcript."""
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
                model = msg.get("model", "")
                content = msg.get("content", [])
                stop_reason = msg.get("stop_reason", "")
            elif ev.get("type") == "assistant" and isinstance(msg, dict):
                model = msg.get("model", "")
                content = msg.get("content", [])
                stop_reason = msg.get("stop_reason", "")
            else:
                continue
            is_fallback = False
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "fallback":
                        is_fallback = True
                        break
            is_refusal = (stop_reason == "refusal")
            yield (model_family(model), is_fallback, is_refusal)


def aggregate(stage_to_paths):
    """stage_to_paths: dict stage -> list of transcript paths. Returns dict stage -> counts."""
    out = {}
    for stage in sorted(stage_to_paths):
        req = fam_counts = None
        req = 0
        fam_counts = {"opus": 0, "fable": 0, "sonnet": 0, "haiku": 0, "other": 0}
        fallback = 0
        refusal = 0
        for path in stage_to_paths[stage]:
            for fam, is_fb, is_ref in scan_transcript(path):
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

    # The fixture encodes three stages (contamination-safe, generic stage names):
    #   analysis-fable   : 3 pure-Fable requests, no fallback -> PURE-FABLE (the D1 headline stays clean)
    #   analysis-tainted : 2 requests, one a Fable->Opus fallback content block -> CONTAMINATED
    #   poc-opus         : 2 pure-Opus requests -> PURE-OPUS (the D2 PoC step, honestly Opus)
    exp = {
        "analysis-fable": {"requests": 3, "fable": 3, "opus": 0, "fallback": 0, "refusal": 0, "verdict": "PURE-FABLE"},
        "analysis-tainted": {"requests": 2, "fable": 1, "opus": 1, "fallback": 1, "refusal": 0, "verdict": "CONTAMINATED"},
        "poc-opus": {"requests": 2, "fable": 0, "opus": 2, "fallback": 0, "refusal": 0, "verdict": "PURE-OPUS"},
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

    agg = aggregate(stage_to_paths)
    if as_json:
        print(json.dumps(agg, indent=2, sort_keys=True))
    else:
        print(render_table(agg))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
