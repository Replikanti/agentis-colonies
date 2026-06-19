#!/usr/bin/env python3
"""backtest-carry-llm.py -- walk-forward LLM-vs-naive carry-basket backtest
(#1175 M2 value-gate).

Before building the full daemon + M98-evolution carry stack, answer the honest
gating question: does an LLM-selected carry basket beat a naive rank rule
OUT-OF-SAMPLE? (The directional full-evolution stack converged to FLAT/no-edge,
so gate the LLM's value before investing in the heavy machinery.)

Walk-forward: every REBALANCE days, at time t:
  - build per-symbol TRAILING funding stats over the prior LOOKBACK days
    (selection uses only PAST data);
  - LLM (claude -p) picks a delta-neutral basket {positions:[{symbol,weight}]}
    from those stats (prompted to favour persistent positive funding, low
    turnover, avoid lumpy/negative);
  - NAIVE rule picks top-K by trailing mean funding, equal weight;
  - both baskets are settled FORWARD [t, t+REBALANCE) (out-of-sample) by the
    repo's deterministic carry-verify.sh, with turnover cost vs the prior basket.
Aggregate net carry per strategy; the comparison is the gate.

Uses: tools/carry-verify.sh (#1175 M1) for settlement, `claude -p` for the LLM.
Standard library only.
"""
import argparse
import csv
import datetime
import json
import os
import re
import subprocess
import sys

REPO_FUNDING = None  # set from args


def to_ms(s):
    if s.isdigit():
        return int(s)
    return int(datetime.datetime.strptime(s, "%Y-%m-%d").replace(
        tzinfo=datetime.timezone.utc).timestamp() * 1000)


def load_funding(funding_dir, symbols):
    series = {}
    for sym in symbols:
        path = os.path.join(funding_dir, sym + ".csv")
        if not os.path.isfile(path):
            continue
        rows = []
        with open(path, newline="") as fh:
            for r in csv.DictReader(fh):
                rows.append((int(r["fundingTime"]), float(r["fundingRate"])))
        rows.sort()
        if rows:
            series[sym] = rows
    return series


def trailing_stats(rows, t0, t1):
    vals = [fr for (t, fr) in rows if t0 <= t < t1]
    if not vals:
        return None
    mean = sum(vals) / len(vals)
    pos = sum(1 for v in vals if v > 0)
    return {"mean": mean, "pos_ratio": pos / len(vals), "n": len(vals),
            "ann_pct": mean * 3 * 365 * 100}


def build_context(stats):
    lines = ["symbol,trailing_funding_annualised_pct,positive_funding_ratio,events"]
    for sym in sorted(stats, key=lambda s: stats[s]["ann_pct"], reverse=True):
        st = stats[sym]
        lines.append("%s,%.2f,%.2f,%d" % (sym, st["ann_pct"], st["pos_ratio"], st["n"]))
    return "\n".join(lines)


def llm_pick(context, top_k, prev_positions):
    prev_str = json.dumps({"positions": [{"symbol": s, "weight": round(w, 3)}
                                         for s, w in prev_positions.items()]})
    prompt = (
        "You are a delta-neutral funding-CARRY portfolio manager. A delta-neutral "
        "position (short perp + long spot) collects the perpetual funding rate when "
        "funding is positive, with no price-direction bet. Below is the TRAILING "
        "funding profile per symbol (annualised %, positive-event ratio, sample size).\n\n"
        + context +
        "\n\nChoose a basket of up to %d symbols to hold delta-neutral for the next period. "
        "Favour PERSISTENT positive funding (high positive_funding_ratio AND positive "
        "annualised); AVOID lumpy (high annualised but low ratio) and negative-funding "
        "symbols. Keep turnover LOW: prefer keeping the previous basket unless a symbol's "
        "funding clearly deteriorated (transaction costs punish churn). Weights are "
        "fractions of capital and must sum to <= 1.0 (remainder = cash; choose cash if "
        "few symbols have durable positive funding).\n\n"
        "Previous basket: %s\n\n"
        "Reply with ONLY a single-line minified JSON object and nothing else: "
        '{\"positions\":[{\"symbol\":\"LINKUSDT\",\"weight\":0.25}, ...]} '
        "(empty positions list = all cash)." % (top_k, prev_str)
    )
    try:
        out = subprocess.run(["claude", "-p", prompt], capture_output=True,
                             text=True, timeout=120)
        raw = out.stdout.strip()
    except Exception as e:  # noqa: BLE001
        sys.stderr.write("llm call failed: %s\n" % e)
        return {}
    m = re.search(r"\{.*\}", raw, re.DOTALL)
    if not m:
        sys.stderr.write("llm returned no JSON: %s\n" % raw[:120])
        return {}
    try:
        obj = json.loads(re.sub(r"\s*\n\s*", " ", m.group(0)))
    except Exception:
        return {}
    out_pos = {}
    for p in obj.get("positions", []):
        try:
            out_pos[str(p["symbol"]).upper()] = float(p.get("weight", 0.0))
        except Exception:
            continue
    return out_pos


def naive_topk(stats, top_k):
    ranked = [s for s in sorted(stats, key=lambda s: stats[s]["mean"], reverse=True)
              if stats[s]["mean"] > 0 and stats[s]["pos_ratio"] >= 0.55]
    chosen = ranked[:top_k]
    if not chosen:
        return {}
    w = round(1.0 / len(chosen), 4)
    return {s: w for s in chosen}


def settle(verifier, funding_dir, positions, prev, t0, t1, cost_rt):
    env = dict(os.environ)
    env["DECISION_JSON"] = json.dumps({"positions": [{"symbol": s, "weight": w}
                                                     for s, w in positions.items()]})
    env["FUNDING_DIR"] = funding_dir
    env["SETTLE_START"] = str(t0)
    env["SETTLE_END"] = str(t1)
    env["COST_BPS_ROUNDTRIP"] = str(cost_rt)
    env["PREV_POSITIONS_JSON"] = json.dumps({"positions": [{"symbol": s, "weight": w}
                                                          for s, w in prev.items()]})
    p = subprocess.run(["bash", verifier], env=env, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("carry-verify rc=%d: %s" % (p.returncode, p.stderr.strip()))
    return json.loads(p.stdout.strip())


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--funding-dir", required=True)
    ap.add_argument("--verifier", required=True)
    ap.add_argument("--symbols", required=True)
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--rebalance-days", type=float, default=14.0)
    ap.add_argument("--lookback-days", type=float, default=21.0)
    ap.add_argument("--top-k", type=int, default=4)
    ap.add_argument("--cost-bps-roundtrip", type=float, default=20.0)
    args = ap.parse_args(argv)

    symbols = [s.strip().upper() for s in args.symbols.split(",") if s.strip()]
    series = load_funding(args.funding_dir, symbols)
    t_start = to_ms(args.start)
    t_end = to_ms(args.end)
    lookback_ms = int(args.lookback_days * 86400000)
    rebalance_ms = int(args.rebalance_days * 86400000)
    harvest_start = t_start + lookback_ms

    llm_prev, naive_prev = {}, {}
    llm_net, naive_net = [], []
    folds = []
    t = harvest_start
    while t < t_end:
        fwd_end = min(t + rebalance_ms, t_end)
        stats = {}
        for s in series:
            st = trailing_stats(series[s], t - lookback_ms, t)
            if st:
                stats[s] = st
        ctx = build_context(stats)
        llm_pos = llm_pick(ctx, args.top_k, llm_prev)
        naive_pos = naive_topk(stats, args.top_k)
        lv = settle(args.verifier, args.funding_dir, llm_pos, llm_prev, t, fwd_end, args.cost_bps_roundtrip)
        nv = settle(args.verifier, args.funding_dir, naive_pos, naive_prev, t, fwd_end, args.cost_bps_roundtrip)
        llm_net.append(lv["net_bps"])
        naive_net.append(nv["net_bps"])
        folds.append({
            "t": t,
            "llm_basket": sorted(llm_pos.keys()), "llm_net_bps": lv["net_bps"],
            "naive_basket": sorted(naive_pos.keys()), "naive_net_bps": nv["net_bps"],
        })
        llm_prev, naive_prev = llm_pos, naive_pos
        t = fwd_end

    days = (t_end - harvest_start) / 86400000.0
    def ann(net):
        return round(sum(net) / 100.0 / days * 365, 3) if days else 0.0  # net is bps; /100 -> %
    out = {
        "window": {"start": args.start, "end": args.end, "harvest_days": round(days, 1)},
        "params": {"rebalance_days": args.rebalance_days, "lookback_days": args.lookback_days,
                   "top_k": args.top_k, "cost_bps_roundtrip": args.cost_bps_roundtrip},
        "rebalances": len(folds),
        "llm_total_net_bps": round(sum(llm_net), 2), "llm_annualised_pct": ann(llm_net),
        "naive_total_net_bps": round(sum(naive_net), 2), "naive_annualised_pct": ann(naive_net),
        "llm_beats_naive_oos": sum(llm_net) > sum(naive_net),
        "folds": folds,
    }
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
