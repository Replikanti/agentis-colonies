# Operator runbook — Dark Factory monitor

A one-page guide to running the monitor colony against a real protocol: **onboard** a target,
**read** an alert, **respond** to one, and the **scope & SLA** boundary. The monitoring peer of the
[auditor runbook](../../docs/RUNBOOK.md).

The colony is **non-custodial / read-only**: every watcher only **reads** chain state via `cast`/RPC
and the notifier only sends an **outbound** notification. No agent signs a transaction, sends one, or
touches funds — ever. See [Scope & SLA](#4-scope--sla).

---

## 1. Onboard a target

### 1.1 Prerequisites (one-time)

- The **`agentis`** binary on `PATH`.
- Foundry's **`cast`** on `PATH` (the read tool). Note its absolute path: `command -v cast`.
- A read-only **RPC endpoint** for the target chain.
- (Optional) A Discord / Slack / PagerDuty **incoming-webhook URL** for paging.

### 1.2 Derive the watch-spec

The monitor watches **derived protocol invariants**. Derive a target's invariant SET **once** with
[`run-live-watch.sh`](../../run-live-watch.sh) (it reuses the auditor's invariant-prover derivation)
and it emits a small static **watch-spec** the `invariant-watcher` consumes:

```bash
../../run-live-watch.sh \
  --repo "$PWD/target" --target Vault.sol:Vault \
  --address 0xVAULT --rpc-url "$RPC_URL" \
  --out "$PWD/watch-spec.json"
# offline / hand-authored: --spec-fixture <file> takes a watch-spec VERBATIM (no LLM / forge)
```

A watch-spec is a set of **facts to read + compare** — `{label, lhs_sig, rhs_sig | rhs_const, rel,
margin_bp}` per invariant — never a write.

### 1.3 Set RPC / target / tiers / webhook

Export the watch target's environment contract (the full table is in the
[colony README](../README.md#environment-contract)), then add each `MONITOR_*` var to
`exec.env_passthrough` in `.agentis/config` so the sandboxed `exec sh` can read it:

```bash
export MONITOR_CAST="$(command -v cast)"
export MONITOR_RPC_URL="$RPC_URL"
export MONITOR_TARGET=0xVAULT
export MONITOR_INV_SPEC="$PWD/watch-spec.json"     # the derived SET; or the single MONITOR_INV_* contract
# optional sink + severity routing (#1094):
export MONITOR_WEBHOOK_URL='https://...'           # NEVER commit a real URL
export MONITOR_WEBHOOK_URL_HIGH='https://...'      # page channel (falls back to MONITOR_WEBHOOK_URL)
export MONITOR_DEADMAN_WINDOW_S=900                # raise a liveness meta-alert if no tick in 15 min
```

With no `MONITOR_CAST` / `MONITOR_RPC_URL` a watcher reads nothing and only observes — it never
raises a false alert. With no webhook, `notify.sh` prints each alert to stdout (a no-op sink).

### 1.4 Start the colony

```bash
cp config/colony.example.toml config/colony.toml   # first run only
./scripts/start-colony.sh
```

Eight daemons start (six watchers + the fusion `coordinator` + the `notifier` bus→webhook bridge).
Smoke-test the sink without waiting for an alert:

```bash
echo '{"severity":"low","kind":"smoke","verdict":"ok"}' | ./scripts/notify.sh
```

### 1.5 Confirm shadow → propose promotion

A fresh watcher is seeded at **`shadow`** (ADR-0001): it learns the protocol's normal state and pages
**nothing** — the false-positive control. It is promoted to **`propose`** (then `review-gated` /
`autonomous`) only as its `learn()`d verdicts prove real over noise (the federation's auto-promote
sidecar, or a manual `agentis confidence set`). Confirm a watcher is alive and learning:

```bash
agentis memo get invariant-watcher:last_check        # heartbeat — updates every tick
agentis experience list --topic invariant-watch | tail   # the learned baseline / verdict rows
```

**Do not page a client off a `shadow`/`propose` watcher.** Promote to `review-gated`/`autonomous`
only after the [backtest scorecard](../scorecard.md) and a clean live shadow run vouch for it.

### 1.6 Calibrate (the credibility check)

Before a target is "live," validate the watch-spec against history with
[`backtest.sh`](../backtest.sh) and record the row in [`scorecard.md`](../scorecard.md):

```bash
./backtest.sh --rpc-url "$ARCHIVE_RPC" --target 0xVAULT \
  --incident-block <N> --spec watch-spec.json --probe   # archive-node capability check first
./backtest.sh --rpc-url "$ARCHIVE_RPC" --target 0xVAULT \
  --incident-block <N> --spec watch-spec.json           # the full replay → lead time + FP rate
```

A **PASS** (paged before the incident, zero false pages on the quiet window) is the credibility
backbone for promoting the watcher to a paging tier.

---

## 2. Read an alert

Every page is a `monitor:alert` JSON forwarded by the `notifier`. Read three fields first:
**`severity`**, the **watcher / kind**, and the **verdict**.

### 2.1 What each verdict means

| Watcher | Verdict | Meaning |
|---------|---------|---------|
| `invariant` | `violated` | A derived protocol invariant (e.g. `totalSupply() <= totalAssets()`) **does not hold** on-chain — a solvency / accounting break. |
| `invariant` | `margin` | The invariant holds but the gap is within the margin-to-violation band — **thin**, about to flip. |
| `governance` | `impl-changed` / `admin-changed` / `owner-changed` | A proxy's implementation pointer flipped, or the admin / owner rotated — the classic **upgrade-attack** tell, often moments before a malicious implementation drains the protocol. |
| `governance` | `gov-changed` | A role grant or a pending timelock op vs the baseline — a softer governance change. |
| `liquidity` | `drained` | A reserve / TVL proxy **dropped** past the learned band — a sudden drain. |
| `flow` | `outflow-burst` | An abnormal **net outflow** over a window — a flood vs the normal drip. |
| `pause` | `paused` / `unpaused` | The protocol toggled its circuit breaker — pausing itself usually means the team detected something. |
| `oracle` | `stale` / `deviation` / `bounds` | A price feed is stale, deviated from its anchor, or out of sane bounds. |
| any | `ok` | The check passed — a healthy tick (never paged). |
| any | `no-read` | A side could not be read this tick (transient RPC failure / unconfigured reader). **Never** a false page — it is the quietest verdict. |

The `coordinator` **fuses** every watcher's verdict into one consolidated alert and a deduped
condition; the alert carries a `"signals"` map of every watcher's verdict (the dossier).

### 2.2 Severity routing

The fused severity is set by the coordinator's score (`high` ≥ 3, `warn` 1–2, none = 0); an
individual watcher emits `high` (proven-reliable / review-gated tier) or `low` (a `propose` draft).

| Severity | Route | Action |
|----------|-------|--------|
| `high` | `MONITOR_WEBHOOK_URL_HIGH` (→ page channel) | **Page now** — triage immediately (§3). |
| `warn` | `MONITOR_WEBHOOK_URL_WARN` (→ warn channel) | Investigate within the SLA warn window; not yet a client page. |
| `low` / `info` | `MONITOR_WEBHOOK_URL` (base) | A draft / shadow signal — review, do not escalate. |
| `high` + **kind `liveness`** | page channel | The **dead-man's switch** fired — the *monitor itself* is blind (RPC down / a watcher stopped ticking). Fix the monitor before trusting silence (§3.4). |

### 2.3 Ack / escalation path (#1094)

`notify.sh` hardens delivery: bounded **retry/backoff** on a transient webhook failure, **sink-side
dedup** (`MONITOR_NOTIFY_DEDUP_COOLDOWN_S`) so a persistent condition does not re-page every tick, and
per-severity **channel routing**. To **ack** a condition during an incident, raise the dedup cooldown
(or pause the noisy watcher via `start-colony.sh --restart-agent`) so on-call is not re-paged while
working it. **Escalate** a `high` page that is not a known false positive to the client per §3.3.

---

## 3. Respond

### 3.1 Triage steps

1. **Read the dossier** — the alert's `"signals"` map shows which watchers fired together. A lone
   `margin` is weaker than a fused `governance:impl-changed` + `liquidity:drained`.
2. **Confirm the fact** — re-read the same on-chain quantity by hand to rule out an RPC glitch:
   ```bash
   cast call --rpc-url "$MONITOR_RPC_URL" 0xTARGET 'totalSupply()'
   cast call --rpc-url "$MONITOR_RPC_URL" 0xTARGET 'totalAssets()'
   ```
   A `no-read` that clears on retry is a transient, not an incident.
3. **Check governance first** — an `impl-changed` / `admin-changed` is the highest-value
   pre-exploit tell; treat it as in-progress until proven benign (a scheduled upgrade).
4. **Correlate with the chain** — look at the recent transactions to the target around the alert
   block to see whether the condition is an attack or a legitimate operation.

### 3.2 False positive?

A flagged-but-benign condition (a planned upgrade, a large legitimate withdrawal) means the watcher's
band is too tight or its baseline is stale. Widen the band (`MONITOR_LIQ_DROP_BP` /
`MONITOR_FLOW_OUT_BP` / `MONITOR_INV_MARGIN_BP`), or drop the watcher back to `shadow` to relearn, and
record the cause. Re-run [`backtest.sh`](../backtest.sh) on the quiet window to confirm the
false-positive rate returns to zero.

### 3.3 When to page the client

Page the client when a **`high`** alert is **confirmed** (the fact reproduces by hand) and is **not** a
known-benign operation — especially a `governance` change or a fused multi-watcher condition. A
`warn`, a single `margin`, or an unconfirmed `no-read` is investigated internally first. The monitor
**reports and alerts**; it never acts on the client's behalf (§4).

### 3.4 Dead-man's switch (liveness)

A `high` / kind `liveness` alert means no fresh watcher tick was observed within
`MONITOR_DEADMAN_WINDOW_S` — the **pager itself is down** (RPC outage, a crashed daemon). Restore the
monitor before trusting the silence:

```bash
agentis memo get invariant-watcher:last_check     # is it stale?
./scripts/start-colony.sh --restart-agent invariant-watcher
```

### 3.5 Postmortem template

After any real page, record:

```
## Incident <date> — <target>
- Detected: <block / time>, by <which watcher>, severity <high|warn>
- Lead time vs the event: <blocks / minutes> (from the backtest / live page)
- Root cause: <on-chain summary>
- Monitor response: <pages sent, acked at, client notified at>
- True / false positive: <which>; if false, the band / baseline change made
- Follow-up: <watch-spec / band tuning; new invariant added; scorecard row updated>
```

---

## 4. Scope & SLA

### 4.1 Non-custodial guarantee (unambiguous)

The monitor is **read / alert / report only**. Every watcher accesses the chain solely through
`cast call` / `cast storage` / `cast balance` (view reads); the notifier sends only an **outbound**
webhook notification. The colony **never** signs a transaction, **never** sends one, **never** holds
a private key, and **never** moves, pauses, or otherwise touches funds or protocol state. There is no
code path in the colony that can. Pausing a contract, rotating an admin, or executing a remediation
is **always** the client's own action — the monitor surfaces the fact and pages; the human acts.

### 4.2 Response-time SLA tiers

| Severity | Target time-to-page | Target time-to-triage |
|----------|---------------------|-----------------------|
| `high` (confirmed) | within one watcher tick of detection (seconds, plus webhook delivery) | immediate on-call triage |
| `warn` | within one watcher tick | within the warn window (operator-defined, e.g. 1 hour) |
| `low` / `info` | best-effort (review queue) | no on-call obligation |
| `liveness` (dead-man's switch) | within `MONITOR_DEADMAN_WINDOW_S` of the last tick | immediate — the pager is down |

Delivery is hardened (retry/backoff + dedup, #1094) so a single transient webhook failure does not
drop a page. The detection-to-page latency is bounded by the watcher tick interval (see
`start-colony.sh`'s `tick_interval_for`) plus webhook round-trip.

### 4.3 Supported scope

- **Chains:** any EVM chain reachable by a read-only `cast`/RPC endpoint.
- **Protocol shapes:** anything expressible as a **two-sided on-chain invariant** (a view-call vs
  another view-call, or vs a literal bound) — solvency / reserve / accounting invariants
  (`invariant-watcher`), EIP-1967 proxy + owner/admin/role/timelock changes (`governance-watcher`),
  reserve / TVL drains and net-outflow bursts (`liquidity` / `flow`), circuit-breaker state
  (`pause-state`), and price-feed staleness / deviation / bounds (`oracle`).

### 4.4 Explicitly out of scope

- **Any write / custody action** — signing, sending, pausing, upgrading, fund movement (see §4.1).
- **Invariants that are not a simple two-sided live read** — multi-term arithmetic, indexed /
  per-account reads, cross-contract aggregates. These belong to the offline auditor / forge
  derivation, not the live two-`cast` watch path; the watch-spec deliberately under-extracts rather
  than emit an unwatchable invariant.
- **Off-chain or social-layer threats** — frontend compromise, phishing, governance-forum
  manipulation, key leaks. The monitor reads on-chain state only.
- **Mempool / pre-confirmation detection** — the monitor reads confirmed state at the chain head; it
  is not a frontrunning / private-mempool service.
- **Incident remediation** — the monitor pages; the client remediates.
