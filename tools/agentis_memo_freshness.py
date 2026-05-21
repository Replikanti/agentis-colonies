"""
Shared memo-freshness helpers used by federation-dashboard's collector
and tools/auto-promote-decisions.py to derive containerized-daemon
liveness from <agent>:last_check memo timestamps instead of the
agentis daemon list state field (which lies for containerized
federations -- see #683 / #686 / #697 / #700 / #705 / #706).

Public API:
  STALENESS_TICKS -- int (env-clamped, default 3)
  read_memo_raw(fed_dir, key) -> Optional[str]
  parse_last_check_epoch(raw) -> Optional[float]
  resolve_tick_interval_ms(agent, colony, fed_dir, fed_tools_dir=None) -> int

The fed_tools_dir kwarg of resolve_tick_interval_ms defaults to the
directory containing this module (preserves the __file__-relative
behaviour from auto-promote-decisions.py); pass an explicit dir to
preserve the argv-routed behaviour from federation-dashboard-collector.py.
Single source of truth extracted in #709 from prior mirrored copies in
federation-dashboard/lib/federation-dashboard-collector.py (#683, #697,
#700) and tools/auto-promote-decisions.py (#706, #708).
"""
import datetime
import os
import subprocess
from typing import Optional


try:
    STALENESS_TICKS = max(1, int(os.environ.get("FEDERATION_DASHBOARD_STALENESS_TICKS", "3")))
except (TypeError, ValueError):
    STALENESS_TICKS = 3


# Cache resolved tick intervals per (agent, colony) so the helper is not
# re-spawned on every record when the same agent appears across multiple
# repos (rare today, but cheap insurance against future fan-out).
_tick_interval_cache: dict = {}


def read_memo_raw(fed_dir: str, key: str) -> Optional[str]:
    try:
        proc = subprocess.run(
            ['agentis', 'memo', 'get', key],
            cwd=fed_dir, capture_output=True, text=True, timeout=2,
        )
    except (subprocess.SubprocessError, OSError):
        return None
    if proc.returncode != 0:
        return None
    raw = (proc.stdout or '').strip()
    return raw or None


def parse_last_check_epoch(raw: Optional[str]) -> Optional[float]:
    if not raw:
        return None
    try:
        dt = datetime.datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ")
        return dt.replace(tzinfo=datetime.timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def resolve_tick_interval_ms(agent: str, colony: str, fed_dir: str, fed_tools_dir: Optional[str] = None) -> int:
    cache_key = (agent, colony)
    if cache_key in _tick_interval_cache:
        return _tick_interval_cache[cache_key]
    interval = 60000
    if fed_tools_dir is None:
        fed_tools_dir = os.path.dirname(os.path.abspath(__file__))
    if fed_tools_dir and colony:
        helper = os.path.join(fed_tools_dir, 'resolve-tick-interval.py')
        colony_dir = os.path.join(fed_dir, colony)
        if os.path.isfile(helper) and os.path.isdir(colony_dir):
            try:
                proc = subprocess.run(
                    ['python3', helper, agent, colony_dir],
                    capture_output=True, text=True, timeout=2,
                )
                if proc.returncode == 0:
                    try:
                        interval = int((proc.stdout or '').strip())
                        if interval <= 0:
                            interval = 60000
                    except (TypeError, ValueError):
                        interval = 60000
            except (subprocess.SubprocessError, OSError):
                interval = 60000
    _tick_interval_cache[cache_key] = interval
    return interval
