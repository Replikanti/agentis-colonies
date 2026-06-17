# Monitor Fleet — multi-tenant operations (#1099)

The monitor colony watches **one** target per instance, configured via env vars
([`config/colony.example.toml`](../config/colony.example.toml) `[monitor]`). A
managed service watching **N** protocols needs per-target isolation and fleet
operations without hand-editing one global environment. The fleet layer
([`../fleet.sh`](../fleet.sh)) adds exactly that — as a **new layer on top of**
the existing [`scripts/start-colony.sh`](../scripts/start-colony.sh). It wraps
that script; it does not modify it.

NON-custodial / read-only throughout: the fleet only orchestrates the read-only
monitor colony. No agent signs a transaction or touches funds. The per-target
webhook URL is the only secret, and it lives in the operator's chmod-600
`target.env`, never in the repo.

## Isolation model

Each watched target lives in its own slot under a target-keyed base dir
(`$MONITOR_FLEET_DIR`, default `$HOME/.agentis-monitor`):

```
$MONITOR_FLEET_DIR/
  <slug>/
    target.env     this target's config (address, chain, RPC, webhook(s),
                   watch-spec, tiers) — one KEY=value per line, sourced.
    colony.toml    copied from config/colony.example.toml (schema parity).
    .agentis/      this target's OWN agentis state:
                     daemon/   its private daemon registry (PIDs + heartbeats)
                     memo/      its private blackboard — learned baselines and
                                per-agent tiers never cross between targets
                     logs/      its private logs
```

`agentis` resolves its store from the cwd's `.agentis/`. The fleet launches the
**unmodified** `start-colony.sh` with `cwd = <slug>/`, so each target gets a
private daemon registry, a private memo blackboard (baselines never bleed across
clients), and private logs. Two targets cannot collide.

Because each target reads its own `target.env`, an alert for target A is built
from target A's address and routed to target A's webhook — it can never land in
target B's channel.

## Subcommands

```
fleet.sh add <slug> <0xaddress> [--chain N] [--rpc URLS] [--webhook URL]
                                [--webhook-warn URL] [--webhook-high URL]
                                [--spec PATH] [--cast PATH] [--force]
fleet.sh start <slug> | --all
fleet.sh stop  <slug> | --all
fleet.sh list
fleet.sh status [<slug>]
fleet.sh path  <slug>
```

Common flags (any subcommand): `--fleet-dir DIR` (override the base dir, also
`$MONITOR_FLEET_DIR`), `--dry-run` (print what start/stop would do without
launching/killing), `-h` / `--help`.

### add

Scaffolds a target's slot, copies the colony template into it for schema parity,
and writes a chmod-600 `target.env` from the supplied flags. The human-facing
config-unit reference is [`config/target.example.toml`](../config/target.example.toml)
— every key there maps 1:1 to a `MONITOR_*` name in `target.env`.

```sh
fleet.sh add aave 0xAAAA...AAAA \
  --chain 1 \
  --rpc https://mainnet.example/rpc \
  --webhook https://hooks.example/aave \
  --spec /etc/monitor/aave/watch-spec.json
```

Derive the `--spec` watch-spec once with `run-live-watch.sh` (see the federation
root scripts), then point `--spec` at the emitted JSON. With no RPC / cast a
watcher reads nothing and only observes — it never raises a false alert.

### start

Sources the target's `target.env`, exports every `MONITOR_*` it sets, initialises
the target's own `.agentis` store on first run, and invokes `start-colony.sh`
from inside the slot. `start --all` does this for every added target.

```sh
fleet.sh start aave
fleet.sh start --all
```

### stop

Stops a target's daemons by invoking
[`tools/kill-federation.sh`](../../../tools/kill-federation.sh) with
`--fed-dir <slot>`, which scopes the shutdown to that target's registry (#440).
Other targets survive. `stop --all` stops every target, each scoped to its own
registry.

```sh
fleet.sh stop aave        # compound keeps running
fleet.sh stop --all
```

### list / status

`list` enumerates every added target with its address and live-daemon count.
`status [<slug>]` prints the per-target slot, address, RPC, registry path, and
live-daemon count (all targets when no slug is given). Liveness is read from the
slot's registry `*.pid` files cross-checked with `kill -0` — `agentis daemon
list` is unreliable across sleep/restart, so the fleet checks the OS directly.

```sh
fleet.sh list
fleet.sh status aave
```

## Per-target dashboard scoping

The standalone `federation-dashboard` reads a federation's `.agentis` state from
a fed-dir. Point it at a single target's slot to scope it to that one client:

```sh
federation-dashboard "$MONITOR_FLEET_DIR/aave" 8420
```

Each slot is a self-contained fed-dir (its own `.agentis/daemon` registry), so a
dashboard pointed at `aave/` shows only aave's daemons, never compound's. Run one
dashboard per client (on distinct ports) for fully isolated, per-tenant views.

## Environment overrides

| Variable | Purpose |
|----------|---------|
| `MONITOR_FLEET_DIR` | Base dir for all target slots (default `$HOME/.agentis-monitor`). |
| `MONITOR_START_COLONY` | Path to `start-colony.sh` (default: the sibling `scripts/start-colony.sh`). |
| `MONITOR_KILL_FEDERATION` | Path to `kill-federation.sh` (default: resolved from `tools/`). |
| `AGENTIS_BIN` | The `agentis` binary (default `agentis` on PATH). |

## Exit codes

`0` ok, `2` usage error, `3` unknown / missing target, `4` launch / stop failure,
`5` missing dependency (`agentis` / `start-colony.sh` / `kill-federation.sh`).

## Onboarding a target — end to end

1. Derive the watch-spec once (`run-live-watch.sh`), or start with the
   single-invariant flags. See the operator [runbook](runbook.md) for the full
   onboarding flow (tiers, shadow→propose promotion, backtest).
2. `fleet.sh add <slug> <0xaddress> --rpc ... --webhook ... --spec ...`.
3. `fleet.sh start <slug>`.
4. `fleet.sh status <slug>` to confirm live daemons.
5. Repeat per client. `fleet.sh list` is the fleet roster; `fleet.sh stop
   <slug>` retires one client without touching the rest.
