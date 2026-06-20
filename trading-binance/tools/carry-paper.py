#!/usr/bin/env python3
"""carry-paper.py -- periodic paper-trade snapshot for the funding-carry strategy
(#1190). The last gate before real money: track what the regime-gated, unlevered
delta-neutral carry book WOULD do, live, accumulating a real forward
out-of-sample record marked by the deterministic verifier.

Run periodically (e.g. daily via cron). Each run:
  1. score per-symbol TRAILING funding (annualised + positive-event ratio over
     --lookback-days) from <funding-dir>/<SYM>.csv (refresh it first via
     funding-download.py);
  2. select the persistent-positive basket: mean funding > 0 AND pos-ratio >=
     --min-pos-ratio, top --top-k by mean (the #1174 rule);
  3. REGIME GATE (#1184): deploy the basket ONLY if its expected annualised carry
     clears --min-annual-carry-pct; else CASH (calm regimes lose at real cost);
  4. positions are UNLEVERED 1:1 delta-neutral (#1188 -- >2.4x liquidates), so a
     deployed basket is equal-weight summing to 1.0 (cash = empty);
  5. SETTLE the prior snapshot: realised funding the prior basket accrued over
     [prior_ts, now) via tools/carry-verify.sh, minus the turnover cost of
     rebalancing prior->new; append the period net + cumulative to the ledger.

Ledger is JSON-lines (gitignored). Reuses carry-verify.sh (#1175 M1) for
settlement. Standard library only.
"""
import argparse
import csv
import json
import os
import subprocess
import sys


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
    return mean, pos / len(vals)


def carry_verify(verifier, funding_dir, positions, prev, t0, t1, cost_rt):
    env = dict(os.environ)
    env["DECISION_JSON"] = json.dumps({"positions": [{"symbol": s, "weight": w} for s, w in positions.items()]})
    env["FUNDING_DIR"] = funding_dir
    env["SETTLE_START"] = str(int(t0))
    env["SETTLE_END"] = str(int(t1))
    env["COST_BPS_ROUNDTRIP"] = str(cost_rt)
    env["PREV_POSITIONS_JSON"] = json.dumps({"positions": [{"symbol": s, "weight": w} for s, w in prev.items()]})
    p = subprocess.run(["bash", verifier], env=env, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("carry-verify rc=%d: %s" % (p.returncode, p.stderr.strip()))
    return json.loads(p.stdout.strip())


def last_ledger_row(path):
    if not os.path.isfile(path):
        return None
    last = None
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                last = line
    return json.loads(last) if last else None


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--universe", required=True)
    ap.add_argument("--funding-dir", required=True)
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--verifier", required=True)
    ap.add_argument("--top-k", type=int, default=6)
    ap.add_argument("--lookback-days", type=float, default=21.0)
    ap.add_argument("--min-pos-ratio", type=float, default=0.55)
    ap.add_argument("--cost-bps-roundtrip", type=float, default=40.0)
    ap.add_argument("--min-annual-carry-pct", type=float, default=3.0,
                    help="regime gate: deploy only if expected annualised carry clears this")
    ap.add_argument("--now", type=int, default=None, help="epoch ms override (default: latest funding time)")
    args = ap.parse_args(argv)

    symbols = [s.strip().upper() for s in args.universe.split(",") if s.strip()]
    series = load_funding(args.funding_dir, symbols)
    if not series:
        sys.stderr.write("carry-paper: no funding data\n")
        return 2
    now = args.now if args.now is not None else max(rows[-1][0] for rows in series.values())
    lookback_ms = int(args.lookback_days * 86400000)

    # 1-3. score + select + regime-gate
    scored = []
    for s in series:
        st = trailing_stats(series[s], now - lookback_ms, now)
        if not st:
            continue
        mean, pos_ratio = st
        if mean > 0 and pos_ratio >= args.min_pos_ratio:
            scored.append((mean, s))
    scored.sort(reverse=True)
    chosen = [s for (_, s) in scored[:args.top_k]]
    exp_annual_pct = (sum(m for (m, s) in scored[:args.top_k]) / len(chosen) * 3 * 365 * 100) if chosen else 0.0
    deploy = bool(chosen) and exp_annual_pct >= args.min_annual_carry_pct
    if deploy:
        w = round(1.0 / len(chosen), 4)
        positions = {s: w for s in chosen}
        regime = "DEPLOY"
    else:
        positions = {}
        regime = "CASH"

    # 5. settle prior + cumulative
    prior = last_ledger_row(args.ledger)
    period_carry_bps = 0.0
    period_turnover_bps = 0.0
    cumulative = 0.0
    if prior is not None:
        prior_pos = {p["symbol"]: p["weight"] for p in prior.get("positions", [])}
        prior_ts = prior["ts"]
        # realised carry of the prior basket over [prior_ts, now) (no turnover within hold)
        rv = carry_verify(args.verifier, args.funding_dir, prior_pos, prior_pos, prior_ts, now, args.cost_bps_roundtrip)
        period_carry_bps = rv["carry_bps"]
        # turnover cost of rebalancing prior -> new (zero-width window => carry 0, cost only)
        tv = carry_verify(args.verifier, args.funding_dir, positions, prior_pos, now, now, args.cost_bps_roundtrip)
        period_turnover_bps = tv["turnover_cost_bps"]
        cumulative = prior.get("cumulative_net_bps", 0.0)
    else:
        # first snapshot: charge entry cost from cash into the new basket
        tv = carry_verify(args.verifier, args.funding_dir, positions, {}, now, now, args.cost_bps_roundtrip)
        period_turnover_bps = tv["turnover_cost_bps"]

    period_net_bps = round(period_carry_bps - period_turnover_bps, 4)
    cumulative = round(cumulative + period_net_bps, 4)

    row = {
        "ts": now,
        "regime": regime,
        "expected_annual_carry_pct": round(exp_annual_pct, 3),
        "positions": [{"symbol": s, "weight": w} for s, w in positions.items()],
        "period_carry_bps": round(period_carry_bps, 4),
        "period_turnover_bps": round(period_turnover_bps, 4),
        "period_net_bps": period_net_bps,
        "cumulative_net_bps": cumulative,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.ledger)), exist_ok=True)
    with open(args.ledger, "a") as fh:
        fh.write(json.dumps(row, separators=(",", ":")) + "\n")

    print("[carry-paper] %s  regime=%s  exp_annual=%.2f%%  basket=%s" % (
        now, regime, exp_annual_pct, ",".join(positions.keys()) or "CASH"))
    print("  period: carry=%.2f turnover=%.2f net=%.2f bps  |  cumulative=%.2f bps" % (
        period_carry_bps, period_turnover_bps, period_net_bps, cumulative))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
