"""
Shared memo-freshness helpers used by federation-dashboard's collector
and tools/auto-promote-decisions.py to derive containerized-daemon
liveness from <agent>:last_check memo timestamps instead of the
agentis daemon list state field (which lies for containerized
federations -- see #683 / #686 / #697 / #700 / #705 / #706).

Public API:
  STALENESS_TICKS -- int (env-clamped, default 15) -- global fallback
  STALENESS_TICKS_BY_ROLE -- dict[str, int] -- per-role override table
  staleness_ticks_for(role) -> int -- per-role lookup with global fallback
  read_memo_raw(fed_dir, key) -> Optional[str]
  parse_last_check_epoch(raw) -> Optional[float]
  resolve_tick_interval_ms(agent, colony, fed_dir, fed_tools_dir=None) -> int

Per-role staleness rationale (#736): a single global window cannot fit
all role types. Tick-driven roles (research-foundry explorer/noticer/
skeptic/verifier/formulator/novelty) write `last_check` every tick, so a
5-tick window is the right liveness signal. Listen-driven research-foundry
roles (auditor, editor, submitter, theorist, computer, prior_advocate,
introducer, reviewer + the 4 search colonies) only wake on bus events
and routinely go quiet for 30+ minutes when no work matches their topic
filter; a 60-tick window (2h at 120s/tick) covers normal quiet stretches
without flagging healthy daemons. dev-apprenticeship roles (reactive
GitLab-bound colonies) use a 30-tick window (30 min at 60s/tick or 2.5h
at 300s/tick). Unknown roles (evolved variants, new federations, test
fixtures) fall through to the global STALENESS_TICKS (#716 default 15).

Global rationale (#716): at the prior default of 3, every quiet listener
flipped to `pid_alive=false` and the promote-tier cascade SKIPped the
affected roles. `15` covered the 10-minute quiet window on both the 60s
dev-apprenticeship tick (15 min) and the 120s research-foundry tick
(30 min) while still flagging genuinely dead daemons within one operator
pulse. #736 keeps `15` as the fallback for unknown roles. Tick-driven
federations that want tighter classification keep the
`FEDERATION_DASHBOARD_STALENESS_TICKS` env override (clamped to >= 1),
which applies to the global fallback only -- per-role table values are
intentional defaults baked in for known roles.

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
    STALENESS_TICKS = max(1, int(os.environ.get("FEDERATION_DASHBOARD_STALENESS_TICKS", "15")))
except (TypeError, ValueError):
    STALENESS_TICKS = 15


# #736: per-role staleness windows. See module docstring for rationale.
# Unknown roles fall back to STALENESS_TICKS (15) via staleness_ticks_for().
STALENESS_TICKS_BY_ROLE = {
    # Tick-driven research-foundry roles (busy every tick, ~5-tick liveness)
    "explorer": 5,
    "noticer": 5,
    "skeptic": 5,
    "verifier": 5,
    "formulator": 5,
    "novelty": 5,
    # Listen-driven research-foundry roles (60 ticks = 2h at 120s/tick)
    "auditor": 60,
    "editor": 60,
    "submitter": 60,
    "theorist": 60,
    "computer": 60,
    "prior_advocate": 60,
    "introducer": 60,
    "reviewer": 60,
    # Search colonies (HTTP-bound, intermittent)
    "arxiv-search": 60,
    "oeis-search": 60,
    "scholar-search": 60,
    "groupprops-search": 60,
    # dev-apprenticeship roles (GitLab-bound; 30 ticks = 30 min at 60s/tick
    # or 2.5h at 300s/tick for reactive colonies)
    "router": 30,
    "prioritizer": 30,
    "labeler": 30,
    "issue_creator": 30,
    "logic_reviewer": 30,
    "style_reviewer": 30,
    "security_reviewer": 30,
    "test_reviewer": 30,
    "approval_decider": 30,
    "scope_estimator": 30,
    "risk_assessor": 30,
    "task_decomposer": 30,
    "plan_reviewer": 30,
    "code_writer": 30,
    "test_writer": 30,
    "refactorer": 30,
    "commit_composer": 30,
    "ship_decider": 30,
    "changelog_writer": 30,
    "version_bumper": 30,
    "release_checker": 30,
}


def staleness_ticks_for(role: str) -> int:
    """Look up the staleness window (ticks) for a role.

    Returns the per-role value from STALENESS_TICKS_BY_ROLE when the role
    is known, otherwise falls back to the global STALENESS_TICKS (#716,
    env-clamped, default 15). Unknown roles cover evolved variants,
    new federations, and test fixtures.
    """
    return STALENESS_TICKS_BY_ROLE.get(role, STALENESS_TICKS)


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
