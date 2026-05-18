# cross-fed-memo/ (host-local state, do not commit content)

Shared scratch directory for the `cross-fed:*` memo namespace defined
in [`../doc/cross-fed-memo.md`](../doc/cross-fed-memo.md). The contents
of this directory are regenerated on every tick by
`tools/cross-fed-bridge.sh` from each federation's
`<fed_dir>/.agentis/memo/cross-fed:*` keys.

**Only `.gitkeep` (and this README) are tracked.** Every file written
here by the bridge -- `method/<fed>/<id>.json`,
`method-body/<fed>/<id>.txt`, `fitness/...`, `applicable-to/...`,
`import-log/...`, `pollination-ledger.jsonl` -- is host-local state.
The `.gitignore` at the repo root ensures git ignores the rest of the
tree.

Part of Phase 8 PR-1 of
[#629](https://github.com/Replikanti/agentis-colonies/issues/629). PR-1
is the foundation only: no federation reads or writes the namespace
yet. PR-2, PR-3, PR-4 wire the agent paths.
