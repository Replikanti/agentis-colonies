# fixtures/external — offline fixtures for `resolve-external.sh` (#2235)

Consumed only by `dark-factory/demo-resolve-external.sh`. Everything here is SYNTHETIC: the contracts,
the package names, the addresses and the repository URLs are invented for the test and name no real
protocol, product or deployment. Nothing here is fetched, compiled or deployed.

| Path | Resolution step it exercises |
|------|------------------------------|
| `vendored-repo/` | a foundry-shaped audited repo: `lib/` and `src/interfaces/external/` (step a), `script/Deploy.s.sol` (the address step b reads), header comments + a vendored `package.json` (the two upstream URL sources of step c) |
| `sourcify/<chain>/<address>.json` | a canned Sourcify v2 `fields=source` body, served to the resolver through the `DF_SOURCIFY_CMD` seam so the self-test unpacks a real response with zero network |
| `upstream-seed/` | the tree the demo pushes into a local bare git repo, which the `DF_GIT_CLONE_CMD` seam clones instead of reaching GitHub |

`vendored-repo/lib/ext-registry/` deliberately ships a `package.json` and NO sources — a dependency
vendored without its code, which is exactly when the upstream clone is the only way to read it.

Three files exist for the refusal semantics the #2238/#2240 follow-ups pinned:
`src/interfaces/external/quotes/IExtQuoteFeed.sol` is vendored beside the repo's own source instead of
under `lib/` (the real convention #2240 found); `src/Isolated.sol` names a feed the repo knows by NAME
ONLY — no vendored source, no address, no upstream — which is the one shape whose terminal reason is
`no-address`; and `src/Consumer.sol` also names `RetiredRegistryView`, which the `upstream-seed/` tree
deliberately does NOT declare, so the clone runs to the end and still refuses with `no-upstream-url`.
The empty (uninitialised) submodule of the `submodule-empty` case is built by the demo at run time — git
cannot track an empty directory.
