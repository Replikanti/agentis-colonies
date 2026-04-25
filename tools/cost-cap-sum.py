#!/usr/bin/env python3
"""cost-cap-sum.py - Reduce <fed>/<colony>/.agentis/spend/*.jsonl into a
breach-evaluation payload for tools/cost-cap.sh (#318).

Mode-aware:
  metered  → sums cost_usd for today (UTC) and current YYYY-MM. Reads
             the per-token spend rows the agentis daemon publishes when
             the LLM backend reports usage (#311). Rows with null /
             missing cost_usd contribute 0.
  flat     → counts rows for today / month / hour and computes the
             current request-per-minute rate over slope_window_min vs.
             a trailing 24h baseline (excluding the active window).
             Subscription / Ollama plans where cost_usd is meaningless.

Output is a single JSON object on stdout:
  {
    "mode": "metered" | "flat",
    "now_utc_iso": "...",
    "period_day":   "YYYY-MM-DD",  (UTC)
    "period_month": "YYYY-MM",
    "metered": {  # populated when mode = metered
      "daily_usd":   <float>,
      "monthly_usd": <float>,
      "row_count":   <int>,
      "unknown_cost_pct": <float>  # 0.0–1.0; cost_source != "real" share
    },
    "flat": {     # populated when mode = flat
      "daily_requests":   <int>,
      "monthly_requests": <int>,
      "hourly_requests":  <int>,
      "current_rate":     <float>,  # requests / minute over slope_window_min
      "baseline_rate":    <float>,  # requests / minute over 24h trailing baseline
      "slope_multiplier": <float | None>  # current_rate / baseline_rate (None if baseline_rate == 0)
    }
  }

Args (positional):
    1: mode             — "metered" | "flat"
    2: spend_glob       — glob pattern for spend log files (e.g.
                          "<fed>/*/.agentis/spend/*.jsonl")
    3: slope_window_min — int, only consulted when mode = flat (else 0)

Exits non-zero on bad usage; emits {} on no-data so the sidecar can
distinguish "no rows" (active no-op) from "broken helper" (alert).
"""
import datetime
import glob
import json
import sys


def _utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def _row_ts(row):
    ts = row.get('ts')
    if isinstance(ts, (int, float)) and ts > 0:
        try:
            return datetime.datetime.fromtimestamp(float(ts), tz=datetime.timezone.utc)
        except (OSError, OverflowError, ValueError):
            return None
    iso = row.get('ts_iso') or row.get('iso_ts')
    if isinstance(iso, str) and iso:
        try:
            s = iso.replace('Z', '+00:00')
            dt = datetime.datetime.fromisoformat(s)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.timezone.utc)
            return dt
        except ValueError:
            return None
    return None


def _read_rows(spend_glob):
    rows = []
    for path in sorted(glob.glob(spend_glob)):
        try:
            with open(path, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rows.append(json.loads(line))
                    except (json.JSONDecodeError, ValueError):
                        continue
        except OSError:
            continue
    return rows


def _evaluate_metered(rows, now):
    today = now.strftime('%Y-%m-%d')
    month = now.strftime('%Y-%m')
    daily_usd = 0.0
    monthly_usd = 0.0
    unknown = 0
    counted = 0
    for r in rows:
        dt = _row_ts(r)
        if dt is None:
            continue
        cost = r.get('cost_usd')
        try:
            cost_f = float(cost) if cost is not None else 0.0
        except (TypeError, ValueError):
            cost_f = 0.0
        src = r.get('cost_source') or ''
        if src and src != 'real':
            unknown += 1
        counted += 1
        rmonth = dt.strftime('%Y-%m')
        rday = dt.strftime('%Y-%m-%d')
        if rmonth == month:
            monthly_usd += cost_f
            if rday == today:
                daily_usd += cost_f
    unknown_pct = (unknown / counted) if counted > 0 else 0.0
    return {
        'daily_usd': round(daily_usd, 6),
        'monthly_usd': round(monthly_usd, 6),
        'row_count': counted,
        'unknown_cost_pct': round(unknown_pct, 4),
    }


def _evaluate_flat(rows, now, slope_window_min):
    today = now.strftime('%Y-%m-%d')
    month = now.strftime('%Y-%m')
    daily = 0
    monthly = 0
    hourly = 0
    hour_ago = now - datetime.timedelta(hours=1)
    window = max(1, int(slope_window_min)) if slope_window_min else 60
    window_start = now - datetime.timedelta(minutes=window)
    baseline_start = now - datetime.timedelta(hours=24)
    in_window = 0
    in_baseline = 0
    for r in rows:
        dt = _row_ts(r)
        if dt is None:
            continue
        rmonth = dt.strftime('%Y-%m')
        rday = dt.strftime('%Y-%m-%d')
        if rmonth == month:
            monthly += 1
            if rday == today:
                daily += 1
                if dt >= hour_ago:
                    hourly += 1
        if dt >= window_start:
            in_window += 1
        elif dt >= baseline_start:
            in_baseline += 1
    current_rate = in_window / float(window) if window > 0 else 0.0
    baseline_minutes = 24 * 60 - window
    baseline_rate = (in_baseline / float(baseline_minutes)) if baseline_minutes > 0 else 0.0
    if baseline_rate > 0:
        slope_multiplier = current_rate / baseline_rate
    else:
        slope_multiplier = None
    return {
        'daily_requests': daily,
        'monthly_requests': monthly,
        'hourly_requests': hourly,
        'current_rate': round(current_rate, 4),
        'baseline_rate': round(baseline_rate, 4),
        'slope_multiplier': (round(slope_multiplier, 4) if slope_multiplier is not None else None),
    }


def main():
    if len(sys.argv) < 3:
        sys.stderr.write('Usage: %s <mode> <spend_glob> [slope_window_min]\n' % sys.argv[0])
        return 2
    mode = sys.argv[1]
    spend_glob = sys.argv[2]
    try:
        slope_window_min = int(sys.argv[3]) if len(sys.argv) > 3 else 60
    except ValueError:
        slope_window_min = 60
    if mode not in ('metered', 'flat'):
        sys.stderr.write('Unknown mode: %s (expected metered|flat)\n' % mode)
        return 2
    rows = _read_rows(spend_glob)
    now = _utc_now()
    out = {
        'mode': mode,
        'now_utc_iso': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'period_day': now.strftime('%Y-%m-%d'),
        'period_month': now.strftime('%Y-%m'),
    }
    if mode == 'metered':
        out['metered'] = _evaluate_metered(rows, now)
    else:
        out['flat'] = _evaluate_flat(rows, now, slope_window_min)
    print(json.dumps(out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
