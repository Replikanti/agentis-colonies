# contest-finder fixtures (#2312)

Recorded responses for `auditor/agents/contest-finder.ag`, used by `demo-contest-finder.sh` through the
launcher's `--<platform>-from` hatch and its stub `curl`. Recorded 2026-11-12 with keyless GETs. Each file
is trimmed to the fields the agent reads; the page metadata (`total`, `has_next`, `nextPage`) is rewritten
so every file stays internally consistent.

| File | Endpoint | Content |
|------|----------|---------|
| `immunefi.json` | `https://immunefi.com/public-api/bounties.json` | 4 of 218 programs: the live boosted competition (ends 2026-11-16), a past boost, a web-app-only boost, a standing bounty. Fields: `project`, `slug`, `endDate`, `kyc`, `maxBounty`, `boostedIntroLive`, `boostedIntroStartingIn`, `boostedLeaderboard`, `rewards[].assetType`. Leaderboard entries are replaced by one placeholder, so no third-party handles are stored. |
| `codehawks-trpc.json` | `https://codehawks.cyfrin.io/trpc/competitions.getCompetitions?batch=1&input=...` | All 45 contests in the tRPC envelope `[{"result":{"data":[...]}}]`, trimmed to `id`, `name`, `urlSlug`, `githubUrl`, `startDate`, `endDate`, `finalised`, `inviteOnly`, `reward`, `currency`, `requiresKyc`. |
| `sherlock-p1.json`, `sherlock-p2.json` | `https://mainnet-contest.sherlock.xyz/contests?page=N` | The first two real pages (10 items each, all FINISHED), with `total` 20 and `has_next` true then false, so they form a complete two-page walk. |
| `sherlock-past-end.json` | same, a page past the last one | The 36-byte `{"error":"unable to load contests"}` body Sherlock answers with HTTP 200. |
| `cantina.json` | `https://cantina.xyz/api/v0/competitions` | 3 of 145: the one `judging` entry, a `complete` public contest, a `private_contest`. |
| `cantina-live.json` | same | The judging entry with its status set to `live`, the value a 2026-10-17 probe saw. |
| `code4rena-p1.json` | `https://code4rena.com/api/v1/audits?perPage=100&page=N` | 4 of 475 audits (Completed, null status, Pre-Contest, a top_secret one) with `pagination.total` 4 and `nextPage` null. |
| `sherlock-lookalikes.json` | synthetic | RUNNING and five look-alikes (`RUNNlNG`, a trailing space, lower case, a Cyrillic first letter, a zero-width space), stored as literal bytes. |

The clock is pinned by `--now` in every test, so the recorded dates never rot.
