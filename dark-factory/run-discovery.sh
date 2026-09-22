#!/usr/bin/env bash
# run-discovery.sh — custom-code DISCOVERY entrypoint for the Dark Factory federation.
#
# run-audit.sh drives the DAG fork-MATCHER (auditor.ag): it fires only where in-scope code RECURS a
# known-bug pattern, so it returns nothing on a bespoke protocol. run-discovery.sh drives the colony's
# DISCOVERY agent (auditor/agents/hunter.ag): a taxonomy-driven, adversarial, per-(subsystem x bug-class)
# audit of CUSTOM multi-contract code — the colony-native, substrate-driven version of a hand-run
# multi-agent pass. The hunter runs ENTIRELY through the agentis substrate (prompt/emit/learn). Learning/
# experience are ENABLED below: hunter.ag ends its tick with `learn("hunt", ...)`, and it is that WRITE the
# flag gates — agentis hard-errors `experience not enabled` on the call and then DISCARDS the cell's whole
# stdout, so the CANDIDATE|/SAFE sentinel vanishes (#1881/#1878) — even though the per-run store is wiped
# fresh on every invocation and so carries no CROSS-run reweighting (#1866).
#
# A surfaced CANDIDATE is a LEAD, not a finding. It is UNVERIFIED until the operator reproduces it through
# evm-harness/forge-verify.sh (a real Foundry PoC that PASSES only if the exploit fires). Only a forge-
# VERIFIED candidate is a finding worth a human-gated submission. This tool NEVER contacts a bounty
# platform and NEVER auto-submits — surfacing harness-checkable leads is the whole job.
#
# Usage:
#   run-discovery.sh --repo <dir> --scope <scope.tsv> --brief <brief.md> [options]
#
# Scope manifest (one subsystem per line; `#` and blank lines ignored):
#   <subsystem label> | <classid,classid,...> | <file[,file...]>     (files relative to --repo)
# A file may be FUNCTION-SLICED as `file@fn1+fn2+...` to feed those functions (+ the contract header,
# + the same-file internal/private callees they transitively reach — #2150, bounded by slice-fns.sh's
# own 3-hop / 2000-line caps) instead of the whole file. Use it for big/complex contracts whose
# whole-file payload overflows the LLM per-call budget — without it the deep liquidation cells time out.
# e.g.
#   savings + rewards | C1,C6,C11 | contracts/SavingsVault.sol,contracts/RewardsDistributor.sol
#   vault liquidation | C10       | contracts/Vault.sol@liquidate+seize+_redeem
#
# Options:
#   --repo <dir>        Cloned target repo root (clone with fetch-target.sh). REQUIRED.
#   --scope <file>      Subsystem x class x files manifest (see above). REQUIRED.
#   --brief <file>      Protocol brief: invariants-to-break + known-issues-to-exclude + trust model. REQUIRED.
#   --appendix <file>   #1865 OPTIONAL sidecar written by map-zones.sh (`<subsystem>\t<token>\t<base>`, TAB-
#                       delimited). It names, per manifest line, the ONE #1861 inheritance-appendix token in
#                       that line's file list and the abstract base it implements — a fact the manifest itself
#                       cannot carry, since the token has the same `file@fn+fn` shape as any other slice. The
#                       hunter then LABELS that payload section and gains the resolved-behaviour + anchoring
#                       rules. Absent (the default) => the whole path is inert and the prompt is byte-identical.
#                       A row is used only if its token literally appears in that line's file list.
#   --taxonomy <file>   bug-taxonomy.md (default: bundled ./auditor/bug-taxonomy.md).
#   --only <subsystem>  Hunt only the line whose subsystem label matches (smoke test / re-run one slice).
#   --classes <ids>     Override EVERY line's class list with this comma list (e.g. C1,C2 for a cheap probe).
#   --backend <mock|flat-cyborg|claude>  LLM backend (default: flat-cyborg = flat-rate PTY wrapper;
#                       claude = metered -p API; mock = offline-deterministic wiring smoke).
#   --out <dir>         Output dir for the run + leads (default: ./discovery-out).
#   --agentis <bin>     agentis binary (default: `agentis` on PATH).
#   --jobs <N>, -j <N>  OPT-IN bounded-concurrency fan-out (#1625, epic #1611 M3). Hunt up to N
#                       (subsystem x class) cells CONCURRENTLY instead of serially (default N=1 = serial).
#                       Concurrency is HARD-CAPPED at min(N, LLM_MAX_DISCOVERY_CELLS=4) so N concurrent
#                       agentis go / forge / solc processes cannot OOM-thrash a single host — the cap never
#                       fails open. Under --jobs > 1 each cell gets its OWN isolated agentis store/workdir
#                       (a `cp -r` of the initialised $RUN template), so concurrent memo/build writes never
#                       race; a consequence is that the #1001 shared-blackboard cross-cell steering is
#                       DISABLED under parallelism (every cell's board starts empty) — a documented
#                       throughput-vs-steering trade. Results are aggregated AFTER the pool drains in
#                       MANIFEST order, so the finding set is deterministic + independent of completion
#                       order. --jobs 1 (the default) keeps the ONE shared store WITH live #1001 steering
#                       and is BYTE-FOR-BYTE identical to the pre-M3 hunt.
#   --tier2             #2217 OPT-IN SECOND TIER (default OFF = every code path inert and the emitted
#                       discovery-results.json byte-identical to a pre-#2217 run). With it, the checks this
#                       run DERIVED and did not settle — the #2223 `unresolved_ids` + `uncited_ids` carries —
#                       are lifted out of their cell objects into a TOP-LEVEL `tier2[]` array with a derived
#                       location, ranked and capped per zone (see the #2217 block below for the schema).
#                       Costs ZERO extra LLM calls and changes no prompt: every input is already in the cell
#                       logs this run produced. `DF_TIER2=1` is the same switch for a caller that composes
#                       argv elsewhere (run-zone-hunt.sh inherits the env, so one export covers a whole hunt).
#                       A tier-2 record is NOT a candidate and carries NO severity — it says only "this check
#                       was derived and left open".
#   --external-resolve  #2235 PR B OPT-IN EXTERNAL-PROTOCOL READING (default OFF = every path below inert and
#                       the assembled prompt byte-identical to a pre-#2235 run). Copies resolve-external.sh
#                       into every cell dir, binds the external cache into the hunt sandbox, and hands the
#                       cell a VERB: resolve an external SYMBOL (never a URL) to source it can open, then cite
#                       the `path:line` it read as `EXTERNAL-CITED` on the TRACE line for that check. The
#                       harness RE-OPENS every such citation from the audited repo or that cache — never from
#                       the network — and requires the cited lines to state the fact; a citation that does not
#                       re-open marks THAT check uncited (the #2230 per-check semantics), never the cell.
#                       Budget: DF_EXTERNAL_BUDGET (default 5) NETWORK resolutions per cell, counted in a
#                       per-cell state file; vendored hits and cache hits are free, and the cache is shared
#                       per run so a second cell in the same zone pays nothing for a symbol already resolved.
#                       `DF_EXTERNAL_RESOLVE=1` is the same switch for a caller that composes argv elsewhere.
#                       Independent of OPERATIONALIZE_LENS by design (#2235 STOP-1 decision 2).
#                       It also hands the cell the #2235 PR C ON-CHAIN verb (onchain-fact.sh): one bounded
#                       `cast call` whose RESULT lands in the same cache, cited as
#                       `ONCHAIN <chain>:<address>:<selector>@<block> = <result>` and re-opened by the harness
#                       FROM THAT CACHE, never from the network. Same knob, so there is one switch, not two.
#   --fork-url <rpc>    #2235 PR C: the RPC endpoint onchain-fact.sh reads deployed state through (http(s),
#                       validated with the same shape check as run-invariant-hunt.sh). It is ALWAYS the
#                       operator's: it is never printed into a prompt, never cached and never taken from the
#                       model. WITHOUT it the on-chain verb still ships and still answers — with
#                       `unavailable|no-rpc`, which leaves the dependent check UNRESOLVED and can never
#                       become a silent CLEAN (issue #2235 STOP-1 decision 4). Inert without
#                       --external-resolve (nothing is copied and no cell is told about the verb).
#   --fork-block <n>    #2235 PR C: pin every on-chain read to one block, so the cache key — and therefore
#                       what the harness re-opens — is reproducible across cells and re-asks. Requires
#                       --fork-url. Without it each cell pins its own block once via `cast block-number`.
#   --depth-max-cells <N>  #1827 WITHIN-CONTRACT DEPTH PASS. 0 (default) = OFF = the run is byte-identical
#                       to before. With N > 0, AFTER every breadth cell has run, re-hunt the functions a
#                       breadth candidate already flagged: one EXTRA cell per (flagged function x alternative
#                       lens), payload narrowed to that single function (`file@fn` through slice-fns.sh) and
#                       the already-known lead(s) injected VERBATIM as an exclusion, so the model must find a
#                       mechanistically DIFFERENT bug or answer SAFE. Class order per location = the zone's
#                       OTHER classes first (in manifest order), the producing class LAST; locations are
#                       ranked High-before-Medium, then by candidate count, then by first appearance, and the
#                       cap is spread by the QUOTA-ROUND-ROBIN below so it never burns entirely on the first
#                       flagged function. Depth cells are REAL cells: counted in the run total,
#                       present in `cells[]` (tagged `"phase":"depth"`), and charged by run-zone-hunt.sh's
#                       admission rule — never a hidden second prompt inside an existing cell. ONE pass, never
#                       a loop: the target list is computed once from the breadth set, so a depth candidate can
#                       never spawn further depth cells.
#   --depth-lens-quota <N>  #1850 ALLOCATION of the --depth-max-cells cap across the flagged locations.
#                       N (default 1, must be >= 1) = how many CONSECUTIVE lenses one location gets before the
#                       plan moves to the next one; after every location has had N the rounds repeat (positions
#                       N+1..2N, and so on) until the cap is spent. N=1 degenerates to the shipped
#                       one-class-per-location-per-pass spread BYTE-FOR-BYTE, which is why the old allocation
#                       needs no second code path. #1827's breadth-first spread never gave any location more
#                       than 1-2 lenses, so the mechanism the depth pass exists for — hunting ONE function
#                       under several lenses — was never exercised; N=3 is the smallest quota that clears
#                       "hunted under >= 3 distinct lenses" while still reaching the rank-4 location at the
#                       caps we measure with. Per-location spend is naturally bounded by the number of classes
#                       the ZONE advertises (a location's lens list IS the zone's class list), so this can
#                       never burn a whole cap on one function. Ranking, the pair multiset and the cap
#                       semantics (min(cap, planned pairs)) are UNCHANGED — only the emission order moves.
#   --depth-from <file>  #1857 DEPTH-ONLY RE-ENTRY. Consume a RECORDED run's `discovery-results.json` (NOT the
#                       raw `run/results-cells.jsonl`, which carries no provenance), seed this run's cell
#                       accumulator with that run's BREADTH cells, and run ONLY the depth pass over them. The
#                       breadth pass is NOT re-hunted: two arms that differ only in `--depth-lens-quota` then
#                       share ONE breadth sample, so the difference between them is the allocation and not
#                       breadth variance — which is the confound that made #1850's A/B unreadable. Requires
#                       `--depth-max-cells > 0` (a depth-only run with no depth budget is a no-op) and
#                       `--brief`; REFUSES `--scope`, `--only`, `--classes` and `--list-cells` (exit 2) because
#                       none of them can affect a plan derived from recorded cells — the zone class order comes
#                       from the recorded `class` fields, not from the manifest. Needs python3 (exit 3).
#                       Exit 2 = the operator typed something that cannot be honoured (bad flag combo, missing
#                       file, cap 0); exit 3 = the artifact does not match this target (recorded `repo` or
#                       `commit` mismatch, a depth target that no longer exists, an input with no breadth cell).
#                       HONESTY: an input recorded BEFORE this flag existed carries no `commit`, so a stale
#                       checkout of the SAME repo at a DIFFERENT commit is UNDETECTABLE — such a run prints an
#                       UNVERIFIED banner and continues. Re-entering against the checkout that produced the
#                       input is the OPERATOR's responsibility; `depth_from.commit` puts it on the record.
#   --list-cells, -n    DRY RUN (#1612): print one `CELL|<subsystem>|<class>|<files>` line per cell this
#                       manifest WOULD hunt, then exit 0 — BEFORE any agentis init / config / report side
#                       effect. Needs neither --brief nor an agentis binary; the round-trip check for
#                       map-zones.sh's auto-generated scope.tsv. The shipped hunt path is byte-identical.
#                       #1619: when --brief is ALSO given, --list-cells first validates it, resolves it to an
#                       absolute path, and prints `BRIEF|<abs>|<line-count>` — the offline proof that a
#                       generated brief resolves + is what would be handed to the hunter as SCOPE_BRIEF.
#                       #1827: depth cells are NOT enumerable ex ante (they depend on the breadth RESULTS),
#                       so --list-cells still prints the breadth cells only; run-zone-hunt.sh charges the
#                       depth CAP up front instead — the conservative choice.
#
# Env:
#   REFUTE_CONSTRAINTS_JSON  #1887 OPT-IN, default UNSET = OFF = byte-identical behaviour. Path to a
#                       refute-to-knowledge.sh corpus (`refute-constraint` KnowledgeEntry rows distilled from
#                       an EARLIER target's REFUTED verdicts). When set and readable it is imported into the
#                       run store ONCE, before the cell loop, so every cell's isolated copy carries the SAME
#                       frozen, read-only corpus; hunter.ag then prepends the constraints filed under that
#                       cell's class. Nothing writes knowledge, so `--jobs N` stays equal to serial. A shell
#                       env read here — deliberately NOT an exec.env_passthrough entry (mirrors
#                       map-zones.sh's HUNT_FITNESS_JSON). An import failure is logged and the hunt continues.
#   DF_TRACE_MAX_REASKS  #2214 Lever 1: how many times a cell that answered WITHOUT a candidate while at
#                       least one derived `OPCHECK|` went unanswered is RE-ASKED before its shortfall is
#                       recorded. #2223: the re-ask NAMES the open check ids, and what happens after it
#                       depends on how much is left — a TOTAL shortfall is a FAILED `untraced-opcheck` cell, a
#                       partial one is an `ok` cell carrying `untraced_ids`/`uncited_ids` (see the #2223 block
#                       below). Default 1 (one re-ask, the bounded cost the gate was designed with); 0 =
#                       gate-only (record the shortfall, never re-ask); garbage => 1.
#                       Read by this SHELL, so it needs no exec.env_passthrough entry — the #1426 trap
#                       applies to `getenv()` inside an `.ag` agent only. The whole gate is INERT whenever
#                       OPERATIONALIZE_LENS is off (no directive => no `OPCHECK|` line => no shortfall),
#                       which is the production default.
#   SEVERITY_RUBRIC     #2245 iteration 2 OPT-IN, default UNSET = OFF. `1` injects hunter.ag's contest-severity
#                       dismissal rubric + the CLOSED ground list into the shared RULES block and asks the cell
#                       for one `DISMISS|<file:function[:line]>|<ground-id>|<evidence>` line per lead it matched
#                       and did not report. Unset / any other value leaves the assembled prompt BYTE-IDENTICAL
#                       to the pre-#2245 one, and leaves the gate below inert (no sentinel => no shortfall).
#                       INDEPENDENT of OPERATIONALIZE_LENS (issue #2245 STOP-1 decision 3): the measured
#                       dismissals happened in lens-OFF cells too, and coupling the two would make the arm a
#                       two-variable experiment. It rides exec.env_passthrough, else getenv() could not see it.
#                       The SAME export also reaches run-refute.sh's gate, so one variable covers both halves.
#   DF_RUBRIC_MAX_REASKS  #2245 iteration 2: how many times a cell that answered WITHOUT a candidate while it
#                       dismissed at least one lead on an INSUFFICIENT ground is re-asked before the surviving
#                       locations are PROMOTED to tier-1 `Medium` candidates. Default 1; 0 = gate-only (record
#                       and promote, never re-ask); garbage => 1. Read by this SHELL, so it needs no
#                       exec.env_passthrough entry — the #1426 trap applies to `getenv()` inside an `.ag` only.
#   DISMISS_REASK_GROUNDS  #2245 iteration 2: the open `<loc> (<ground>)` list the ground re-ask names. Set by
#                       run_cell ONLY on that re-ask (and only inside a rubric-ON cell), so it is empty on every
#                       first attempt and that prompt is unchanged. It rides exec.env_passthrough for the #1426
#                       reason: unregistered, the re-ask would silently replay the same prompt.
#   DF_EXTERNAL_RESOLVE #2235: `1` turns the external-protocol reading on, exactly like `--external-resolve`
#                       (any other value, and unset, leave it OFF — the default), so one export covers every
#                       zone of a run-zone-hunt.sh hunt.
#   DF_EXTERNAL_CACHE   #2235: the cache root the resolver writes and the harness re-opens citations from
#                       (default `${DARK_FACTORY_DIR:-$HOME/.dark-factory}/external`, the host-wide state-dir
#                       convention). It is the ONE extra directory bound into the hunt sandbox, and only when
#                       --external-resolve is on. It holds external-protocol source only — never target code,
#                       never judging or ground-truth data.
#   DF_EXTERNAL_BUDGET  #2235: NETWORK resolutions allowed PER CELL (default 5; read by resolve-external.sh
#                       itself and quoted into the directive, so the number the model is told and the number
#                       enforced cannot drift).
#   DF_ONCHAIN_BUDGET   #2235 PR C: on-chain CALLS allowed PER CELL (default 5; read by onchain-fact.sh
#                       itself and quoted into the directive, on the same no-drift contract). A cache hit is
#                       free, so a value a sibling cell already read costs nothing.
#   DF_TIER2            #2217: `1` turns the second tier on, exactly like `--tier2` (any other value, and
#                       unset, leave it OFF — the default). It exists because run-zone-hunt.sh calls this
#                       script with a fixed argv: one `export DF_TIER2=1` covers every zone of a hunt.
#   DF_TIER2_MAX_PER_ZONE  #2217: the PER-ZONE cap on tier-2 records (default 3; `0` forces the feature OFF
#                       even with --tier2; garbage => 3). The measured supply is ~5 unsettled checks per
#                       zone-run (#2214 archive: 15 over 21 cells in one arm, 14 in the other), so this cap
#                       BINDS and the ranking below is load-bearing rather than decoration. Records the cap
#                       discards are counted in `totals.tier2_dropped`, never silently dropped.
#   DF_TIER2_RARE_CLASSES  #2217: the RARE-CLASS PRIORITY LIST the cap ranks by, as one comma list (default
#                       `C19,C20,C21,C22,C23,C24`). It is a priority list and nothing more — not a rarity
#                       oracle, and it makes no claim about any individual record. One env-overridable list
#                       so a future out-of-class lens joins it without a code change.
#                       All three are read by this SHELL, so none needs an exec.env_passthrough entry.
#
# #2214 PR C — CITATION DISCIPLINE ON A DISMISSAL (heuristics, deliberately shallow):
#   The measured residual cause of the #2214 rare-row miss is not routing and not follow-through but the
#   DISMISSAL: a traced check closed CLEAN on "a trusted deployer picks that pairing / it is a deploy-time
#   misconfiguration" without ever checking what the audited repo itself configures, and a sibling check
#   closed CLEAN on an asserted EXTERNAL-protocol fact ("it returns a normalised ratio by construction") that
#   was never verified and is false for some markets. `_uncited_dismissals()` below turns both into the
#   EXISTING untraced-opcheck gate (no new status vocabulary, same one re-ask, same FAILED reason):
#     * CONFIG grounds  — a `TRACE|...|CLEAN...|` whose verdict+evidence span matches
#                         /misconfig|trusted[ -](role|deployer)|privileged[ -](role|deployer)|deploy-time|
#                          deployment[ -]configuration|configuration[ -](choice|invariant)/i
#                         and carries NO `path:<line>` citation UNDER `test/`, `tests/`, `script/`, `scripts/`,
#                         `deploy/` or `docs/` — a `.sol` under `src/` only names the flag it declares, not
#                         what the repo actually ships for it (#2225) — OR (when a repo_dir is given, #2225
#                         QA fix) cites one whose FILE DOES NOT EXIST under the target repo: a fabricated or
#                         hallucinated `path:line` is not "in this repository" either.
#     * EXTERNAL grounds — a `TRACE|...|CLEAN...|` whose verdict+evidence span matches
#                         /documented|by construction|by design|always returns|normali[sz]ed|normali[sz]es|
#                          1e18|decimals|guarantee[sd]?/i
#                         and either cites no `path:line` at all (#2225: a URL, a bare source-file name and a
#                         bare interface identifier no longer discharge this branch — only a repo `path:line`
#                         does), or (when a repo_dir is given) cites one whose FILE DOES NOT EXIST under the
#                         target repo (#2225 QA fix — same fabricated-citation rule as CONFIG grounds above),
#                         or whose file DOES exist but whose cited line range states none of the fact tokens
#                         the TRACE relies on (`1e18|decimals|WAD|ONE|normali|scale|order`) — a citation that
#                         only NAMES the file, without stating the property, is not verification either. With
#                         NO repo_dir, both branches fall back to the pre-#2225 citation-SHAPE-only check —
#                         documented behaviour, not a gap: the content genuinely cannot be resolved without a
#                         repo to read it against.
#   Both are HEURISTICS over model-emitted free text — a regex cannot decide whether a sentence is really a
#   scope argument, and the EXTERNAL content check is a cheap `sed -n 'a,bp' | grep -qiE` over the cited
#   range, not a semantic read (that stays the OPERATOR read, like the trace-evidence rule above). They are
#   tuned to be cheap when wrong: a false positive costs ONE re-ask of a cell that has no candidate to lose, a
#   false negative simply leaves the pre-PR-C behaviour. The detectors only ever see `TRACE|` lines, which
#   exist only when the #2211 lens is ON, so the production default (lens OFF) is untouched.
#
# #2223 — PER-CHECK PAIRING BY ID, AND THE EXACT STATUS SEMANTICS OF THE FOLLOW-THROUGH GATE:
#   GRAMMAR (lens-gated, so a lens-OFF prompt is byte-identical): the hunter numbers each derived check
#   `OPCHECK|#k|<construct>|<invariant>` (k = its ordinal within THIS cell) and answers it under the same
#   number `TRACE|#k|<CLEAN|BUG|UNRESOLVED>|<evidence>`. The id is the pairing key — never the check text,
#   which a paraphrase changes and a copy-paste repeats.
#   WHY: the pre-#2223 rule compared COUNTS, and the #2222 QA showed N distinct but semantically unrelated
#   TRACE lines satisfy it exactly. Counting is not following through.
#   RULES: `id` whenever at least one OPCHECK line is numbered; `count` (the pre-#2223 arithmetic, byte for
#   byte) only for a cell that numbered none. The decider is recorded per cell as `untraced_rule`.
#   A TRACE naming an id this cell never derived discharges nothing and is counted as `trace_orphans`.
#   The #2224/#2227 citation rules apply PER TRACE: an uncited dismissal marks THAT check (its id lands in
#   `uncited_ids`), never the whole cell.
#
#   STATUS SEMANTICS (what a cell's recorded status means, exhaustively — no new status vocabulary):
#     * the cell never ANSWERED (chrome miss / `[llm.timeout]`) => FAILED, with its own existing reason. The
#       follow-through gate never claims such a cell.
#     * lens ON, no candidate, and EVERY derived check left unanswered after the bounded re-ask (the #2213
#       shape: checks derived, none traced) => FAILED `untraced-opcheck`, exactly as before. This is the ONLY
#       remaining wholesale failure, and it still makes the zone `hunted_degraded` via totals.failed.
#     * lens ON, no candidate, and SOME checks unanswered after the re-ask => status `ok`, with `untraced_ids`
#       / `uncited_ids` naming them and `untraced` counting them. NOT failed: the checks the cell DID settle
#       are real results, and a correct `UNRESOLVED` carry among them must survive — the #2214 M3 `dismissal`
#       r1 C23 cell carried the rare row as `UNRESOLVED` correctly and was discarded for ONE unrelated uncited
#       line in the same cell. The honest consequence, stated rather than hidden: such a cell no longer marks
#       its zone degraded on its own, so a partial shortfall is visible ONLY through these per-cell fields and
#       the stderr line scrape_cell_log prints.
#     * a cell that produced a CANDIDATE is never re-asked and never failed; its shortfall is recorded the
#       same per-check way (unchanged from #2214 in intent, now with ids).
#     * `UNRESOLVED` checks are carried in `unresolved_ids` WITH the check's own text (plus the `unresolved`
#       count) — the record #2217 consumes to turn a rare-class UNRESOLVED into a second-tier candidate.
#   RE-ASK: one (DF_TRACE_MAX_REASKS, default 1), and it NAMES the open ids through TRACE_REASK_IDS, which
#   hunter.ag renders inside the lens block. Empty on every first attempt => that prompt is unchanged.
#
# #2245 ITERATION 2 — THE DISMISSAL-GROUND GATE, AND ITS EXACT STATUS SEMANTICS:
#   MEASURED CAUSE: iteration 1 closed the generation gap on the held-out shape (3 of 3 runs reached the
#   ground-truth mechanism) and lost it 3 of 3 times downstream, every time on ONE criterion applied at the
#   hunter's SAFE or at the refute gate's REFUTED: "no unprivileged attacker gain and no funds locked => not a
#   bug". The contest rubric accepts those rows as Medium. So this gate does not touch routing or generation.
#   GRAMMAR (knob-gated, so a knob-OFF prompt is byte-identical): with SEVERITY_RUBRIC=1 hunter.ag carries the
#   severity rubric + a CLOSED ground list and writes `DISMISS|<file:function[:line]>|<ground-id>|<evidence>`
#   for every lead it matched to the class pattern and did not report. Exactly four ground ids are INSUFFICIENT
#   (`no-attacker`, `trusted-config`, `alt-path`, `dust-unquantified`) — each alone AND in any union — and five
#   are SUFFICIENT with the evidence each names (`guard`, `unreachable`, `no-loss`, `known-issue`,
#   `immaterial-quantified`). A missing/empty/unrecognised id counts as insufficient (_rubric_sufficient_grounds
#   is therefore the single decider, and the four insufficient ids need no second list in this shell).
#   THE GATE: grouped BY LOCATION, because the measured loss stacked three insufficient grounds on one lead.
#   One re-ask (DF_RUBRIC_MAX_REASKS, default 1) NAMES the open locations through DISMISS_REASK_GROUNDS.
#   STATUS SEMANTICS (no new status vocabulary, and this gate NEVER fails a cell):
#     * knob off, or no `SEVERITY-RUBRIC|` sentinel in the log => gap 0, gate inert, JSON key set unchanged.
#     * a cell with a CANDIDATE|, a `.novalid` or a `.timeout` marker is never re-asked (the first has a lead to
#       lose, the other two never answered and already own their FAILED reason).
#     * shortfall survives the re-ask => each surviving location whose `file:function` RESOLVES in this cell's
#       own file list becomes a NORMAL tier-1 `Medium` candidate (status stays `ok`), recorded as
#       `rubric_promoted`; a location that does not resolve is DROPPED and only counted.
#     * `dismissals` (the compliance dosage) and `insufficient_dismissals` are recorded per cell either way.
#   A promoted candidate is still an unproven LEAD: it is judged by the refute gate and needs a PASSING Foundry
#   PoC before it is a finding, exactly like a model-emitted one. Tier 1 rather than a tier-2 record because
#   verify-findings.sh keeps tier-2 verdicts out of `verified[]` by construction (issue #2245 STOP-1 decision 2).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# #2119: wide flat-cyborg PTY by default for every flat-cyborg config emission (see the helper header).
# shellcheck source=lib/flat-cyborg-env.sh
# shellcheck disable=SC1091
. "$HERE/lib/flat-cyborg-env.sh"
# #1707: shared reply-shape validation + retry for the hunter substrate call (see the helper header).
# shellcheck source=lib/run-agent-validated.sh
# shellcheck disable=SC1091
. "$HERE/lib/run-agent-validated.sh"
DF_AGENT_MAX_ATTEMPTS="$(df_max_attempts)"
# #2214 Lever 1: the re-ask ceiling for the OPCHECK->TRACE follow-through gate (see the Env block above).
# Validated exactly like df_max_attempts, except the floor is 0 (0 = gate-only, no re-ask).
DF_TRACE_MAX_REASKS="${DF_TRACE_MAX_REASKS:-1}"
case "$DF_TRACE_MAX_REASKS" in ''|*[!0-9]*) DF_TRACE_MAX_REASKS=1 ;; esac
# #2245 iteration 2: the re-ask ceiling for the dismissal-GROUND gate (see the Env block above). Validated
# exactly like DF_TRACE_MAX_REASKS, floor 0 (0 = gate-only: record + promote, never re-ask). The gate itself is
# inert without the SEVERITY-RUBRIC| sentinel, so this value is irrelevant on a default (knob-off) run.
DF_RUBRIC_MAX_REASKS="${DF_RUBRIC_MAX_REASKS:-1}"
case "$DF_RUBRIC_MAX_REASKS" in ''|*[!0-9]*) DF_RUBRIC_MAX_REASKS=1 ;; esac
# agentis-core#993: pre-accept Claude Code's workspace-trust dialog for every dir a
# hunter session cd's into (the shared $RUN store on the serial/depth path, each
# isolated cell dir on the parallel path), else the flat-cyborg/claude session
# blocks on the dialog and exits 75.
# shellcheck source=lib/ensure-claude-trust.sh
# shellcheck disable=SC1091
. "$HERE/lib/ensure-claude-trust.sh"
AGENTIS="agentis"
REPO="" ; SCOPE="" ; BRIEF="" ; TAXONOMY="" ; ONLY="" ; CLASSES_OVERRIDE=""
# #1865: opt-in inheritance-appendix sidecar; empty = OFF, every code path below is inert.
APPENDIX_TSV=""
BACKEND="flat-cyborg" ; MODEL="" ; OUT="$PWD/discovery-out"
LIST_CELLS=""   # #1612: opt-in dry-run; empty = the shipped hunt path, byte-identical.
JOBS=1          # #1625: opt-in bounded-concurrency fan-out; 1 = serial, byte-identical to the pre-M3 hunt.
DEPTH_MAX_CELLS=0  # #1827: opt-in within-contract depth pass; 0 = OFF, the whole path is inert.
# #1850: consecutive lenses per location per round. Default 1 = the #1827 spread, byte-for-byte.
# 3 concentrates the budget and DID produce the first rare row depth has ever found (plaza M-12, via a
# second lens on exitBalancerPool), but the run that showed it also lost four mid/consensus rows whose loss
# is NOT attributable — both arms re-hunted the stochastic breadth pass, so that A/B cannot separate an
# allocation effect from breadth variance. The default stays at the measured-safe value until a
# breadth-fixed A/B justifies moving it; `--depth-lens-quota 3` is available for that experiment.
DEPTH_LENS_QUOTA=1
# #1857: opt-in depth-only re-entry; empty = OFF, every code path below is inert and the shipped hunt is unchanged.
DEPTH_FROM=""
# #2217: opt-in second tier (see --tier2 above); 0 = OFF = the default, every tier-2 code path inert.
TIER2=0
# #2235 PR B: opt-in external-protocol reading; 0 = OFF = the default, every path below inert.
case "${DF_EXTERNAL_RESOLVE:-}" in 1) EXT_RESOLVE=1 ;; *) EXT_RESOLVE=0 ;; esac
# #2235 PR C: the operator's RPC for the on-chain verb. Empty = no endpoint = every on-chain read answers
# `unavailable|no-rpc` and the dependent check stays UNRESOLVED (STOP-1 decision 4) — never a silent CLEAN.
FORK_URL="${FORK_URL:-}" ; FORK_BLOCK="${FORK_BLOCK:-}"

need() { [ "$1" -ge 2 ] || { echo "run-discovery.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$#"; REPO="$2"; shift 2 ;;
    --scope) need "$#"; SCOPE="$2"; shift 2 ;;
    --brief) need "$#"; BRIEF="$2"; shift 2 ;;
    --appendix) need "$#"; APPENDIX_TSV="$2"; shift 2 ;;
    --taxonomy) need "$#"; TAXONOMY="$2"; shift 2 ;;
    --only) need "$#"; ONLY="$2"; shift 2 ;;
    --classes) need "$#"; CLASSES_OVERRIDE="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --model) need "$#"; MODEL="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --jobs|-j) need "$#"; JOBS="$2"; shift 2 ;;
    --depth-max-cells) need "$#"; DEPTH_MAX_CELLS="$2"; shift 2 ;;
    --depth-lens-quota) need "$#"; DEPTH_LENS_QUOTA="$2"; shift 2 ;;
    --depth-from) need "$#"; DEPTH_FROM="$2"; shift 2 ;;
    --tier2) TIER2=1; shift ;;
    --external-resolve) EXT_RESOLVE=1; shift ;;
    --fork-url) need "$#"; FORK_URL="$2"; shift 2 ;;
    --fork-block) need "$#"; FORK_BLOCK="$2"; shift 2 ;;
    --list-cells|-n) LIST_CELLS=1; shift ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-discovery.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

# #1625: --jobs must be a positive integer (validated even under --list-cells, which then ignores it).
case "$JOBS" in ''|*[!0-9]*) echo "run-discovery.sh: --jobs must be a positive integer (got '$JOBS')" >&2; exit 2 ;; esac
[ "$JOBS" -ge 1 ] || { echo "run-discovery.sh: --jobs must be >= 1 (got '$JOBS')" >&2; exit 2; }
# #1827: --depth-max-cells uses the same integer validation + exit-2 shape (also validated under --list-cells,
# which then ignores it — depth cells are not enumerable ex ante).
case "$DEPTH_MAX_CELLS" in ''|*[!0-9]*) echo "run-discovery.sh: --depth-max-cells must be a non-negative integer (got '$DEPTH_MAX_CELLS')" >&2; exit 2 ;; esac
# #1850: --depth-lens-quota is a POSITIVE integer — 0 lenses per location would emit an empty plan at a
# non-zero cap, i.e. silently disable a depth pass the operator asked for. Same fail-fast shape as --jobs.
case "$DEPTH_LENS_QUOTA" in ''|*[!0-9]*) echo "run-discovery.sh: --depth-lens-quota must be a positive integer (got '$DEPTH_LENS_QUOTA')" >&2; exit 2 ;; esac
[ "$DEPTH_LENS_QUOTA" -ge 1 ] || { echo "run-discovery.sh: --depth-lens-quota must be >= 1 (got '$DEPTH_LENS_QUOTA')" >&2; exit 2; }
# #2235 PR C: fork-arg shape validation, the SAME shape run-invariant-hunt.sh uses for the same two flags
# (an operator typo must surface here, as a usage error, not as an opaque `cast` failure inside a cell).
# A malformed endpoint is a hard exit rather than a degrade-to-no-rpc: the operator asked for on-chain reads.
case "$FORK_URL" in
  '') ;;
  http://*|https://*) ;;
  *) echo "run-discovery.sh: --fork-url must be an http(s) URL (got: $FORK_URL)" >&2; exit 2 ;;
esac
case "$FORK_BLOCK" in '') ;; *[!0-9]*) echo "run-discovery.sh: --fork-block must be a whole number" >&2; exit 2 ;; esac
[ -z "$FORK_BLOCK" ] || [ -n "$FORK_URL" ] || { echo "run-discovery.sh: --fork-block requires --fork-url" >&2; exit 2; }
# #2217: the second tier is OFF unless the operator asked for it, through EITHER the flag or the env (the env
# exists because run-zone-hunt.sh calls this script with a fixed argv). The cap is validated like every other
# integer knob here except that garbage degrades to the default instead of failing the run — it is an env knob,
# not an argv one, so an unusable value must not abort a hunt the operator already paid for. A cap of 0 forces
# the whole feature OFF, which keeps "0 = inert" true for the cap the same way it is for --depth-max-cells.
if [ "${DF_TIER2:-}" = "1" ]; then TIER2=1; fi
DF_TIER2_MAX_PER_ZONE="${DF_TIER2_MAX_PER_ZONE:-3}"
case "$DF_TIER2_MAX_PER_ZONE" in ''|*[!0-9]*) DF_TIER2_MAX_PER_ZONE=3 ;; esac
[ "$DF_TIER2_MAX_PER_ZONE" -gt 0 ] || TIER2=0
# #1857: the depth-only re-entry's ARGV contract. Everything here is an exit 2 — the operator asked for
# something that cannot be honoured — and it is checked BEFORE the --repo/--scope/--brief requirements below,
# so a refused flag combination is named rather than reported as a missing manifest. The refused flags are
# refused rather than validated: a plan derived from RECORDED cells takes its zone class order from those
# cells' own `class` fields, so --scope/--only/--classes could not change it and accepting them would be a
# silent lie. --list-cells is refused for the same reason (depth cells are not enumerable ex ante).
if [ -n "$DEPTH_FROM" ]; then
  [ -f "$DEPTH_FROM" ] || { echo "run-discovery.sh: --depth-from file not found: $DEPTH_FROM" >&2; exit 2; }
  [ -z "$LIST_CELLS" ]       || { echo "run-discovery.sh: --depth-from cannot be combined with --list-cells (depth cells are not enumerable ex ante)" >&2; exit 2; }
  [ -z "$ONLY" ]             || { echo "run-discovery.sh: --depth-from cannot be combined with --only (the plan comes from the recorded cells, not from a manifest)" >&2; exit 2; }
  [ -z "$CLASSES_OVERRIDE" ] || { echo "run-discovery.sh: --depth-from cannot be combined with --classes (the plan comes from the recorded cells, not from a manifest)" >&2; exit 2; }
  [ -z "$SCOPE" ]            || { echo "run-discovery.sh: --depth-from cannot be combined with --scope (the plan comes from the recorded cells, not from a manifest)" >&2; exit 2; }
  [ "$DEPTH_MAX_CELLS" -gt 0 ] || { echo "run-discovery.sh: --depth-from needs --depth-max-cells > 0 (a depth-only run with no depth budget is a no-op)" >&2; exit 2; }
  command -v python3 >/dev/null 2>&1 || { echo "run-discovery.sh: --depth-from needs python3 to read the recorded run" >&2; exit 3; }
fi

[ -n "$REPO" ]  && [ -d "$REPO" ]  || { echo "run-discovery.sh: --repo <cloned repo dir> required (clone it with fetch-target.sh)" >&2; exit 2; }
# #1857: --scope is the manifest the BREADTH pass walks; a depth-only re-entry hunts no breadth cell, so it is
# required only on the shipped path (and refused above on the re-entry one).
if [ -z "$DEPTH_FROM" ]; then
  [ -n "$SCOPE" ] && [ -f "$SCOPE" ] || { echo "run-discovery.sh: --scope <subsystem|classes|files manifest> required" >&2; exit 2; }
fi
# #1865: the sidecar is OPTIONAL, but a path the operator typed and that does not exist is a typo, not an
# opt-out — fail fast rather than run the whole hunt with the framing silently off.
if [ -n "$APPENDIX_TSV" ]; then
  [ -f "$APPENDIX_TSV" ] || { echo "run-discovery.sh: --appendix file not found: $APPENDIX_TSV" >&2; exit 2; }
fi
# #1612: --list-cells needs no --brief (it never hunts) — guard the brief requirement behind it.
if [ -z "$LIST_CELLS" ]; then
  [ -n "$BRIEF" ] && [ -f "$BRIEF" ] || { echo "run-discovery.sh: --brief <invariants + known-issues + trust model> required (this anchors the hunt and excludes known issues)" >&2; exit 2; }
fi

# #1612 dry-run short-circuit: enumerate the (subsystem x class) cells this manifest WOULD hunt and exit,
# BEFORE any agentis init / config / report side effect. Runs the SAME normalization as the hunt loop below
# (trim + `''|\#*` skip + --only/--classes + comma class split), so the enumerated cells match the manifest
# byte-for-byte. Needs neither --brief nor an agentis binary — the offline round-trip for map-zones.sh's
# auto-generated scope.tsv. With no --list-cells every guard above is inert and the hunt path is unchanged.
if [ -n "$LIST_CELLS" ]; then
  # #1619 (epic #1611 M2): opt-in, byte-identical-default brief acknowledgement. When --brief is ALSO given,
  # validate + resolve it to absolute (the same idiom as the hunt path's line ~111) and print BRIEF|<abs>|<lines>
  # BEFORE the cell enumeration — the offline (no-agentis) proof that a generated brief resolves and is what
  # would be handed to every cell as SCOPE_BRIEF. With no --brief, BRIEF="" so this block is skipped and the
  # M1 --list-cells output is unchanged.
  if [ -n "$BRIEF" ]; then
    [ -f "$BRIEF" ] || { echo "run-discovery.sh: --brief file not found: $BRIEF" >&2; exit 2; }
    BRIEF_ABS="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"
    BRIEF_LINES="$(wc -l < "$BRIEF" | tr -d ' ')"
    printf 'BRIEF|%s|%s\n' "$BRIEF_ABS" "$BRIEF_LINES"
  fi
  while IFS='|' read -r SUBSYS CLS_CSV FILES_CSV || [ -n "${SUBSYS:-}" ]; do
    SUBSYS="$(printf '%s' "$SUBSYS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$SUBSYS" in ''|\#*) continue ;; esac
    CLS_CSV="$(printf '%s' "$CLS_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    FILES_CSV="$(printf '%s' "$FILES_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$ONLY" ] && [ "$SUBSYS" != "$ONLY" ] && continue
    [ -n "$CLASSES_OVERRIDE" ] && CLS_CSV="$CLASSES_OVERRIDE"
    [ -n "$FILES_CSV" ] || continue
    OLDIFS="$IFS"; IFS=','
    for CLS in $CLS_CSV; do
      IFS="$OLDIFS"
      CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$CLS" ] || { IFS=','; continue; }
      printf 'CELL|%s|%s|%s\n' "$SUBSYS" "$CLS" "$FILES_CSV"
      IFS=','
    done
    IFS="$OLDIFS"
  done < "$SCOPE"
  exit 0
fi

[ -n "$TAXONOMY" ] || TAXONOMY="$HERE/auditor/bug-taxonomy.md"
[ -f "$TAXONOMY" ] || { echo "run-discovery.sh: taxonomy not found: $TAXONOMY" >&2; exit 2; }
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-discovery.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

# Resolve every operator path to ABSOLUTE — the colony runs from a different cwd, so a relative path
# would silently miss (the hunter reads files via absolute TARGET_DIR/<rel>).
REPO="$(cd "$REPO" && pwd)"
BRIEF="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"
TAXONOMY="$(cd "$(dirname "$TAXONOMY")" && pwd)/$(basename "$TAXONOMY")"
[ -z "$DEPTH_FROM" ] || DEPTH_FROM="$(cd "$(dirname "$DEPTH_FROM")" && pwd)/$(basename "$DEPTH_FROM")"
# #1857: the commit this run actually read, recorded in discovery-results.json so a LATER --depth-from can
# refuse a stale checkout. A SOFT dependency: a non-git target (or no git at all) degrades to "unknown" and
# never fails the run. It pins the commit, not the content — an uncommitted edit is invisible to rev-parse.
COMMIT="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"

HUNTER="$HERE/auditor/agents/hunter.ag"
[ -f "$HUNTER" ] || { echo "run-discovery.sh: hunter agent not found at $HUNTER" >&2; exit 3; }

# #1857 PROVENANCE GUARD — every refusal that can be decided from the recorded artifact ALONE fires HERE,
# before the output dir exists, so a refused re-entry leaves nothing behind. Exit 3 throughout: the artifact
# does not match this target (the #1840 fail-closed precedent), as opposed to the exit-2 argv refusals above.
# What it CANNOT detect is stated in the header and printed as a banner: an input recorded before `commit`
# existed cannot pin the source tree, so a stale checkout of the SAME repo is the operator's responsibility.
_probe_recorded_run() {
  python3 - "$1" <<'PY'
import sys, json
p = sys.argv[1]
try:
    with open(p, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception as exc:                    # any read/parse failure is fatal - never a silently empty replay
    sys.stderr.write("run-discovery.sh: --depth-from: %s is not readable JSON (%s)\n" % (p, exc))
    raise SystemExit(3)
if not isinstance(d, dict) or not isinstance(d.get("cells"), list):
    sys.stderr.write("run-discovery.sh: --depth-from: %s is not a discovery-results.json object with a cells[] array\n" % p)
    raise SystemExit(3)
# The depth filter is a CORRECTNESS requirement, not hygiene: a depth candidate fed back into the ranking
# moves both the location order and the per-location lens order, so replaying an unfiltered file computes a
# DIFFERENT plan than the run it claims to re-enter.
breadth = [c for c in d["cells"] if isinstance(c, dict) and c.get("phase") != "depth"]
if not breadth:
    sys.stderr.write("run-discovery.sh: --depth-from: %s records 0 breadth cell(s) - nothing to plan a depth pass from\n" % p)
    raise SystemExit(3)
# ONE FACT PER LINE, never a TSV: `commit` is absent on every artifact recorded before it existed, and a tab
# IFS collapses runs of tabs (tab is IFS whitespace), which would silently shift an empty field's successor
# into it — i.e. read the CELL COUNT as the recorded commit.
sys.stdout.write("\n".join([
    str(d.get("repo") or ""),
    str(d.get("commit") or ""),
    str(len(breadth)),
    str(sum(len(c.get("candidates") or []) for c in breadth)),
]) + "\n")
PY
}
DF_REPO="" ; DF_COMMIT="" ; DF_CELLS=0 ; DF_CANDIDATES=0
if [ -n "$DEPTH_FROM" ]; then
  DF_FACTS="$(_probe_recorded_run "$DEPTH_FROM")" || exit 3
  {
    read -r DF_REPO
    read -r DF_COMMIT
    read -r DF_CELLS
    read -r DF_CANDIDATES
  } <<EOF
$DF_FACTS
EOF
  [ "$DF_REPO" = "$(basename "$REPO")" ] || {
    echo "run-discovery.sh: --depth-from: the input was recorded against repo '$DF_REPO', but --repo is '$(basename "$REPO")'" >&2; exit 3; }
  if [ -z "$DF_COMMIT" ]; then
    echo "run-discovery.sh: --depth-from: the input records no commit; re-entry provenance is UNVERIFIED" >&2
    echo "run-discovery.sh:   ↳ a stale checkout of '$DF_REPO' at a DIFFERENT commit cannot be detected from this artifact — re-entering against the checkout that produced it is YOUR responsibility" >&2
  elif [ "$DF_COMMIT" != "$COMMIT" ]; then
    echo "run-discovery.sh: --depth-from: the input was recorded at commit $DF_COMMIT, but --repo is at $COMMIT" >&2; exit 3
  fi
fi

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
# #2125: thread the sandbox bind vars into the agentis invocation (run_flat_cyborg does not env_clear, so they
# reach lib/claude-sandboxed.sh via the flat-cyborg subprocess). RUN covers both the serial cwd and $RUN/cell-*.
export HUNT_SANDBOX_REPO="$REPO" HUNT_SANDBOX_RUN="$RUN"
cp "$HUNTER" "$RUN/hunter.ag"
cp "$HERE/auditor/slice-fns.sh" "$RUN/slice-fns.sh"   # function-level slicer (scope `file@fn1+fn2`)

# #2235 PR B: external-protocol reading. ALL of it is empty/absent unless --external-resolve opted in, which
# is what keeps the default prompt byte-identical and the sandbox view unchanged.
#   * the resolver is COPIED into $RUN (and, below, into every per-cell dir) next to slice-fns.sh, because the
#     hunt sandbox binds the toolchain, the repo and the RUN dir — the colonies checkout is NOT visible from
#     inside it, so a path into $HERE would simply not exist for the driven session;
#   * the CACHE is host-wide and shared across cells/zones on purpose (a symbol another cell already resolved
#     costs nothing), and it is bound into the sandbox by lib/claude-sandboxed.sh through HUNT_SANDBOX_EXTERNAL;
#   * the BUDGET is per cell: one state file per cell under $RUN/external-budget/.
# #2235 PR C: the on-chain reader rides the SAME knob — one switch, not two. It is copied and announced even
# when no RPC is configured, because that is what turns an unverifiable deployed-state claim into an honest
# `unavailable|no-rpc` -> UNRESOLVED instead of a remembered value (issue #2235 STOP-1 decision 4).
EXTERNAL_RESOLVER="" ; EXTERNAL_CACHE="" ; EXTERNAL_BUDGET="" ; EXTERNAL_BUDGET_DIR=""
ONCHAIN_FACT="" ; ONCHAIN_BUDGET="" ; ONCHAIN_BUDGET_DIR=""
if [ "$EXT_RESOLVE" -eq 1 ]; then
  [ -f "$HERE/resolve-external.sh" ] || {
    echo "run-discovery.sh: --external-resolve: resolve-external.sh not found at $HERE" >&2; exit 3; }
  cp "$HERE/resolve-external.sh" "$RUN/resolve-external.sh"
  chmod +x "$RUN/resolve-external.sh" 2>/dev/null || true
  EXTERNAL_RESOLVER="$RUN/resolve-external.sh"
  [ -f "$HERE/onchain-fact.sh" ] || {
    echo "run-discovery.sh: --external-resolve: onchain-fact.sh not found at $HERE" >&2; exit 3; }
  cp "$HERE/onchain-fact.sh" "$RUN/onchain-fact.sh"
  chmod +x "$RUN/onchain-fact.sh" 2>/dev/null || true
  ONCHAIN_FACT="$RUN/onchain-fact.sh"
  EXTERNAL_CACHE="${DF_EXTERNAL_CACHE:-${DARK_FACTORY_DIR:-$HOME/.dark-factory}/external}"
  mkdir -p "$EXTERNAL_CACHE"
  EXTERNAL_CACHE="$(cd "$EXTERNAL_CACHE" && pwd)"
  EXTERNAL_BUDGET="${DF_EXTERNAL_BUDGET:-5}"
  case "$EXTERNAL_BUDGET" in ''|*[!0-9]*) EXTERNAL_BUDGET=5 ;; esac
  EXTERNAL_BUDGET_DIR="$RUN/external-budget"
  mkdir -p "$EXTERNAL_BUDGET_DIR"
  ONCHAIN_BUDGET="${DF_ONCHAIN_BUDGET:-5}"
  case "$ONCHAIN_BUDGET" in ''|*[!0-9]*) ONCHAIN_BUDGET=5 ;; esac
  ONCHAIN_BUDGET_DIR="$RUN/onchain-budget"
  mkdir -p "$ONCHAIN_BUDGET_DIR"
  # The ONE extra sandbox bind (#2235 STOP-1 decision 3c): exported only on this branch, so an OFF run gives
  # lib/claude-sandboxed.sh exactly the bind set it had before.
  export HUNT_SANDBOX_EXTERNAL="$EXTERNAL_CACHE"
  echo "run-discovery.sh: external-protocol reading ON — cache $EXTERNAL_CACHE, <= $EXTERNAL_BUDGET network resolve(s)/cell" >&2
  # The endpoint is reported as configured / not configured and NEVER echoed: an RPC URL routinely carries a key.
  if [ -n "$FORK_URL" ]; then
    echo "run-discovery.sh: on-chain fact check ON — endpoint configured, <= $ONCHAIN_BUDGET call(s)/cell${FORK_BLOCK:+, block $FORK_BLOCK}" >&2
  else
    echo "run-discovery.sh: on-chain fact check ON — NO endpoint configured (--fork-url): every read answers 'unavailable|no-rpc' and leaves its check UNRESOLVED" >&2
  fi
fi

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )

# #1955 Lever 1a: SCALE the per-cell LLM timeout with the zone's SOURCE WEIGHT. A thin zone keeps the
# 1200s floor; a dense one (multi-contract market/order logic) gets proportionally more time, hard-capped at
# 1800s. HUNT_SRC_LOC = sum of `wc -l` over the DISTINCT in-scope files this run will hunt — walked from
# $SCOPE with the SAME filter the --list-cells path uses (trim SUBSYS, skip blank/comment, honour --only,
# split FILES_CSV on commas, drop any `@fn` slice suffix, dedup). This is a side-effect-free WEIGHT PROBE:
# a missing/unreadable file contributes 0 and never fails the hunt. #2103: the floor and cap are now
# env-overridable (DF_HUNT_TIMEOUT_FLOOR_MS / DF_HUNT_TIMEOUT_CAP_MS) — an opus-heavy lens cell can need more
# than the 1800000ms default cap, and this scale-up is lens-reasoning-driven, not zone-size-driven, so a
# smaller ZONE_SPLIT_LOC alone cannot avoid it. An invalid override (non-numeric, empty, or 0) falls back to
# the default with a warning rather than aborting the run — this is a safety-relevant knob, not a CLI flag,
# so it degrades rather than exits (mirrors the CELL_CAP/LLM_MAX_DISCOVERY_CELLS precedent below). No upper
# sanity ceiling on the cap override by design: the exec_timeout/watchdog stays the real backstop. The
# scaling slope (STEP_MS/STEP_LOC) is unchanged and stays a fixed literal — out of scope for #2103.
HUNT_TIMEOUT_FLOOR="${DF_HUNT_TIMEOUT_FLOOR_MS:-1200000}"
HUNT_TIMEOUT_STEP_MS=300000
HUNT_TIMEOUT_STEP_LOC=400
HUNT_TIMEOUT_CAP="${DF_HUNT_TIMEOUT_CAP_MS:-1800000}"
case "$HUNT_TIMEOUT_FLOOR" in
  ''|*[!0-9]*) echo "run-discovery.sh: DF_HUNT_TIMEOUT_FLOOR_MS must be a positive integer (got '$HUNT_TIMEOUT_FLOOR') -- using default 1200000" >&2; HUNT_TIMEOUT_FLOOR=1200000 ;;
esac
[ "$HUNT_TIMEOUT_FLOOR" -ge 1 ] || { echo "run-discovery.sh: DF_HUNT_TIMEOUT_FLOOR_MS must be >= 1 -- using default 1200000" >&2; HUNT_TIMEOUT_FLOOR=1200000; }
case "$HUNT_TIMEOUT_CAP" in
  ''|*[!0-9]*) echo "run-discovery.sh: DF_HUNT_TIMEOUT_CAP_MS must be a positive integer (got '$HUNT_TIMEOUT_CAP') -- using default 1800000" >&2; HUNT_TIMEOUT_CAP=1800000 ;;
esac
[ "$HUNT_TIMEOUT_CAP" -ge 1 ] || { echo "run-discovery.sh: DF_HUNT_TIMEOUT_CAP_MS must be >= 1 -- using default 1800000" >&2; HUNT_TIMEOUT_CAP=1800000; }
[ "$HUNT_TIMEOUT_FLOOR" -gt "$HUNT_TIMEOUT_CAP" ] && { echo "run-discovery.sh: DF_HUNT_TIMEOUT_FLOOR_MS ($HUNT_TIMEOUT_FLOOR) exceeds the cap ($HUNT_TIMEOUT_CAP) -- raising the cap to the floor" >&2; HUNT_TIMEOUT_CAP=$HUNT_TIMEOUT_FLOOR; }
HUNT_SCOPE_FILES=""
# A --depth-from re-entry forbids --scope (line ~196): the plan comes from the recorded cells, so $SCOPE is
# empty. Skip the probe then (HUNT_SRC_LOC stays 0 -> the floor timeout), never `< ""` (a crash). `_` discards
# the class field (SC2034: it is deliberately unused — the weight is per FILE, independent of the lens).
if [ -n "$SCOPE" ] && [ -f "$SCOPE" ]; then
  while IFS='|' read -r WS_SUBSYS _ WS_FILES || [ -n "${WS_SUBSYS:-}" ]; do
    WS_SUBSYS="$(printf '%s' "$WS_SUBSYS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$WS_SUBSYS" in ''|\#*) continue ;; esac
    [ -n "$ONLY" ] && [ "$WS_SUBSYS" != "$ONLY" ] && continue
    WS_FILES="$(printf '%s' "$WS_FILES" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$WS_FILES" ] || continue
    WS_OLDIFS="$IFS"; IFS=','
    for WS_F in $WS_FILES; do
      IFS="$WS_OLDIFS"
      WS_F="$(printf '%s' "$WS_F" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      WS_F="${WS_F%%@*}"                                 # strip any `file@fn1+fn2` slice suffix to the path
      [ -n "$WS_F" ] || { IFS=','; continue; }
      HUNT_SCOPE_FILES="$HUNT_SCOPE_FILES$WS_F
"
      IFS=','
    done
    IFS="$WS_OLDIFS"
  done < "$SCOPE"
fi
HUNT_SRC_LOC=0
while IFS= read -r WS_F; do
  [ -n "$WS_F" ] || continue
  WS_LOC=0
  if [ -r "$REPO/$WS_F" ]; then WS_LOC="$(wc -l < "$REPO/$WS_F" 2>/dev/null | tr -d ' ')"; fi
  case "$WS_LOC" in ''|*[!0-9]*) WS_LOC=0 ;; esac
  HUNT_SRC_LOC=$((HUNT_SRC_LOC + WS_LOC))
done <<EOF
$(printf '%s' "$HUNT_SCOPE_FILES" | sort -u)
EOF
HUNT_TIMEOUT_MS=$(( HUNT_TIMEOUT_FLOOR + HUNT_TIMEOUT_STEP_MS * (HUNT_SRC_LOC / HUNT_TIMEOUT_STEP_LOC) ))
[ "$HUNT_TIMEOUT_MS" -gt "$HUNT_TIMEOUT_CAP" ] && HUNT_TIMEOUT_MS=$HUNT_TIMEOUT_CAP

{
  echo "llm.backend = $BACKEND"
  # #1955: ONE attempt, now SIZED to the zone. A deep adversarial read of complex liquidation/redemption
  # logic legitimately runs 4-8 min even on a function-level slice (the reasoning, not the payload, is the
  # cost); 300s made the hard cells time out 3x and return nothing, so one longer attempt beats wasted
  # retries. That attempt is scaled to $HUNT_SRC_LOC LOC of in-scope source (floor 1200s, +300s / 400 LOC,
  # hard-capped 1800s) so a dense zone gets proportionally more head-room while a thin one keeps a tight
  # budget — and, per Lever 1b, a genuine [llm.timeout] now fails FAST + distinguishably instead of costing
  # N wasted outer retries. Keep cells focused with `file@fn` slicing so the common case stays fast.
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p${MODEL:+ --model $MODEL}"; echo "llm.cli_timeout_ms = $HUNT_TIMEOUT_MS"; }
  # idle_ms 12000 (> native 4000 default): kept as a latency knob only (#1925) -- do NOT ratchet it further.
  # Completion is gated on the wrapper's closing sentinel from flat-cyborg >= 0.13.0 (idle_gate_open()); idle_ms
  # only bounds how fast a marker-less (sentinel-less) reply is accepted once the screen goes quiet. If a stage
  # looks flaky, file it against the completion path, not this value.
  [ "$BACKEND" = "flat-cyborg" ] && { echo "llm.cli_timeout_ms = $HUNT_TIMEOUT_MS"; echo "llm.flat_cyborg.idle_ms = 12000"; echo "llm.flat_cyborg.result_file_dir = $RUN"; echo "llm.model = ${MODEL:-opus}"; }
  # #2125: sandbox the driven Claude Code session (bubblewrap view = toolchain + repo + run dir only, web tools
  # denied). Emit the target only when bwrap is available and the operator has not opted out — otherwise the
  # bare `claude` runs (lib/claude-sandboxed.sh would fall through anyway, but not emitting keeps configs clean).
  [ "$BACKEND" = "flat-cyborg" ] && [ -z "${DF_NO_SANDBOX:-}" ] && command -v bwrap >/dev/null 2>&1 && echo "llm.flat_cyborg.target = $HERE/lib/claude-sandboxed.sh"
  # #2017: cap in-process retries at ONE. A runaway / non-terminating generation (the #1955/#1957 class) blows
  # through llm.cli_timeout_ms with ZERO output; agentis-core then re-runs a `[llm.timeout]` `1 + llm.max_retries`
  # times (default max_retries = 2 => 3 attempts, so ~3x the per-cell budget — up to ~90 min on a 1800s-capped
  # dense zone — all wasted on the same hang). `llm.max_retries = 1` caps a timed-out cell at 2x the budget
  # (down from 3x). We keep ONE retry rather than 0 on purpose: a TRANSIENT timeout (a host-overheat de-bunch, an
  # llm-session-slot wait, a one-off PTY/API spike that would complete on attempt 2) must still recover in-process
  # — dropping to 0 would turn every such blip into an immediate FAILED cell (and a false `hunted_degraded`
  # zone). The genuine logic-free runaway is handled at the SOURCE by hunter.ag's #2017 bounded-termination
  # clause (it emits a terminal verdict within one budget instead of chasing unbounded cross-contract reasoning),
  # so this knob only bounds the WASTE of the residual timeout path. Verified against the runtime (src/llm.rs
  # `attempts = 1 + max_retries`, honoured by both the `claude` (CliBackend) and `flat-cyborg` branches above),
  # so it stays backend-agnostic and entirely colonies-side — no core change. Non-timeout TUI-chrome flakes still
  # additionally recover through the #1707 outer loop's 5 attempts in lib/run-agent-validated.sh, and the #1955
  # Lever 1b guard refuses to re-run that outer loop on a genuine `[llm.timeout]`. demo-discovery-fail-fast.sh
  # pins this emission, the one-retry cap, and that a transient timeout still recovers on the second attempt.
  echo "llm.max_retries = 1"
  # #2195: agentis-core #999 decoupled timeout retries from `max_retries` into a NEW
  # `llm.timeout_retries` knob (default 0 = fail-fast). Without this, `llm.max_retries = 1`
  # above no longer governs the `[llm.timeout]` path under a #999 agentis, so a TRANSIENT
  # timeout (see the #2017 rationale above) would never recover. Opt in explicitly to keep
  # the same 2x-budget cap on a persistent runaway while still recovering on attempt 2.
  echo "llm.timeout_retries = 1"
  echo "trace.level = normal"
  # The hunter reads source + the brief/taxonomy through exec sh; pass through its whole env contract.
  # #1827 DEPTH_TARGET/DEPTH_KNOWN MUST be on this allowlist: getenv() reads the SANITIZED env, so an
  # unregistered knob silently returns "" and the whole depth pass would be inert (the #1426/#1428 failure
  # mode). demo-discovery-parallel.sh asserts the stub actually receives them.
  # #1865 APPENDIX_FILE/APPENDIX_BASE ride the same rule for the same reason: unregistered => "" => the
  # hunter would concatenate the derived slice with no label and no judging rule, exactly as before the fix.
  # #2157 CALLEE_TRUST rides the same rule: getenv() reads the SANITIZED env, so without it here the D3 A/B
  # OFF toggle would be silently inert (CALLEE_TRUST=0 could never reach hunter.ag). Unset => "" => ON.
  # #2211 OPERATIONALIZE_LENS rides it too, with the opposite polarity: only "1" opts IN, so without this entry
  # the opt-in could never reach hunter.ag and the whole directive would be unreachable (unset => "" => OFF).
  # #2223 TRACE_REASK_IDS rides it for the same reason, but is set by run_cell ONLY on a follow-through re-ask:
  # unregistered => "" => the re-ask would silently replay the same prompt instead of naming the open checks.
  # #2235 EXTERNAL_RESOLVER/EXTERNAL_CACHE/EXTERNAL_BUDGET_STATE/EXTERNAL_BUDGET ride it for exactly the #1426
  # reason: hunter.ag gates the whole resolver directive on getenv("EXTERNAL_RESOLVER"), which reads the
  # SANITISED env — unregistered => "" => --external-resolve would be silently inert, and the other three are
  # quoted into the command line the directive prints, so a missing one would hand the model a broken command.
  # All four are EMPTY on a default run, so registering them changes nothing there.
  # #2235 PR C ONCHAIN_FACT/ONCHAIN_BUDGET_STATE/ONCHAIN_BUDGET/FORK_BLOCK ride it for the same #1426 reason.
  # FORK_URL deliberately does NOT: hunter.ag never reads the endpoint (onchain-fact.sh does, from the cell's
  # own environment), and keeping it off the sanitised env is what guarantees an RPC URL — routinely a
  # key-bearing secret — can never be interpolated into a prompt.
  # #2245 iteration 2 SEVERITY_RUBRIC/DISMISS_REASK_GROUNDS ride it for exactly the #1426 reason: hunter.ag
  # gates the whole rubric on getenv("SEVERITY_RUBRIC"), which reads the SANITISED env — unregistered => "" =>
  # the opt-in could never reach the agent and the feature would be silently inert. DISMISS_REASK_GROUNDS is
  # set by run_cell ONLY on a ground re-ask: unregistered => "" => the re-ask would replay the same prompt
  # instead of naming the open locations. Both are EMPTY on a default run, so registering them changes nothing.
  echo "exec.env_passthrough = TARGET_DIR,IN_SCOPE,SCOPE_BRIEF,TAXONOMY,HUNT_CLASS,SUBSYSTEM,SLICER,DEPTH_TARGET,DEPTH_KNOWN,APPENDIX_FILE,APPENDIX_BASE,CALLEE_TRUST,OPERATIONALIZE_LENS,TRACE_REASK_IDS,EXTERNAL_RESOLVER,EXTERNAL_CACHE,EXTERNAL_BUDGET_STATE,EXTERNAL_BUDGET,ONCHAIN_FACT,ONCHAIN_BUDGET_STATE,ONCHAIN_BUDGET,FORK_BLOCK,SEVERITY_RUBRIC,DISMISS_REASK_GROUNDS"
  echo "exec.default_timeout_ms = 30000"
  # Learning/experience are ENABLED: hunter.ag ends its tick with `learn("hunt", ...)`, and it is that WRITE
  # the flag gates (#1878 measured it on agentis v1.28.0 — `experience.enabled = false` makes learn() raise
  # `runtime error: experience not enabled`, and ANY runtime error makes agentis discard the program's whole
  # accumulated stdout). So #1866/#1877's "structurally inert, safe to disable" premise was wrong for this
  # script: disabling them breaks every hunt cell (no CANDIDATE|/SAFE sentinel -> 5 failed attempts ->
  # FAILED), even though the cp -r isolation means nothing is ever read back. Regression restored here.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
  # #1887: the knowledge store must be enabled for hunter.ag's query_knowledge("refute-constraint", …) read.
  # This is MANDATORY, not a nicety: without it the call raises `knowledge base not enabled`, and — exactly
  # like the experience flag above — a runtime error makes agentis DISCARD the cell's whole stdout, so every
  # cell would report a false SAFE/FAILED (#1877's silent zero). It therefore ships in the SAME change as the
  # query_knowledge call. Harmless with no corpus imported: query_knowledge returns [] and the block is "".
  # (map-zones.sh:knowledge.enabled does the same for zone-mapper.ag's #1711 read.)
  echo "knowledge.enabled = true"
} > "$RUN/.agentis/config"

# #993: trust the shared $RUN store up front (the serial + depth paths cd into it,
# and the parallel path additionally trusts each isolated cell dir at creation).
# mock never spawns claude, so skip it. Best-effort — never fails the hunt.
case "$BACKEND" in flat-cyborg|claude) df_ensure_claude_trust "$RUN" ;; esac

# #1887 LEARN->ACT bridge: if the operator points REFUTE_CONSTRAINTS_JSON at a refute-to-knowledge.sh output,
# import it into THIS run's store (just wiped + re-init'd above) BEFORE the cell loop — and therefore before
# the per-cell `cp -r "$RUN/.agentis"`, so every cell gets the SAME corpus and no cell can accumulate into a
# sibling's. Unset/unreadable -> skipped -> today's behaviour exactly. --replace is mandatory (a re-import
# without it accumulates samples). Not an exec.env_passthrough entry: this is a shell-level env read here,
# not an `.ag` getenv() — the same wiring as map-zones.sh's HUNT_FITNESS_JSON.
if [ -n "${REFUTE_CONSTRAINTS_JSON:-}" ] && [ -r "${REFUTE_CONSTRAINTS_JSON:-}" ]; then
  ( cd "$RUN" && "$AGENTIS" knowledge import "$REFUTE_CONSTRAINTS_JSON" --replace ) \
    || echo "run-discovery.sh: refute-constraint import failed (continuing)" >&2
fi

REPORT="$OUT/discovery-report.md"
{
  echo "# Dark Factory — custom-code discovery leads"
  echo
  echo "- repo: \`$(basename "$REPO")\`   backend: $BACKEND"
  # #1857: a depth-only re-entry hunted NO breadth cell — say so on the record, next to the provenance of the
  # breadth sample it reused, so the table below is never read as "this run found these leads".
  [ -n "$DEPTH_FROM" ] && echo "- depth-only re-entry (#1857): $DF_CELLS breadth cell(s) carried from \`$DEPTH_FROM\`; recorded commit ${DF_COMMIT:-none (UNVERIFIED)}, current HEAD $COMMIT"
  echo "- Each CANDIDATE below is an UNVERIFIED LEAD. It is a finding ONLY after it reproduces through"
  echo "  \`evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>\` (PoC PASSES = exploit fires)."
  echo "- Submission is a separate, explicit human action. This colony never posts to a platform."
  echo
  echo "| Subsystem | Class | Lead (file:fn:line / severity / exploit / PoC sketch) |"
  echo "|---|---|---|"
} > "$REPORT"

CELLS=0 ; CANDIDATES=0 ; STEERS=0 ; FAILED_CELLS=0
# #1707: FAILED_CELLS counts cells whose hunter reply never carried a CANDIDATE|/SAFE sentinel after
# DF_AGENT_MAX_ATTEMPTS retries (TUI chrome / no answer). Such a cell is NOT a rigorous negative — it is
# surfaced as a distinct FAILED row + a "status":"failed" JSON record, never silently folded into "0 candidates".
# #2214 adds a SECOND way into that counter with the same meaning: an `untraced-opcheck` cell (a directive-ON
# SAFE that left derived checks untraced after the bounded re-ask). Inert whenever OPERATIONALIZE_LENS is off.
# #1001: rows recording where one cell's lead STEERED a later cell (the blackboard coordination loop),
# folded into the report at the end. Kept separate from $REPORT so it can be appended as its own table.
COORD="$RUN/coordination.tsv"; : > "$COORD"
# #1625: per-cell JSON accumulator for the additive discovery-results.json (written on BOTH the serial and
# the parallel path). One object per cell, appended in MANIFEST order; it never mutates $REPORT's bytes.
CELLS_JSONL="$RUN/results-cells.jsonl"; : > "$CELLS_JSONL"
# #2217: the run-scoped tier-2 accumulator. Created ONLY when the feature is on, so an OFF run writes no new
# file at all; the records live here rather than in the cell objects, which is what keeps every existing
# per-cell key set (and _plan_depth_cells's forward key scan) byte-identical.
TIER2_TSV="$RUN/tier2.tsv"
if [ "$TIER2" -eq 1 ]; then : > "$TIER2_TSV"; fi

# #1625 (epic #1611 M3): concurrency ceiling. The effective parallelism is min(--jobs, CELL_CAP); the cap is
# a HARD limit (never fail-open) so N concurrent agentis go / forge / solc processes cannot OOM-thrash a
# single host. Conservative default 4; tune per host via LLM_MAX_DISCOVERY_CELLS.
CELL_CAP="${LLM_MAX_DISCOVERY_CELLS:-4}"
case "$CELL_CAP" in ''|*[!0-9]*) CELL_CAP=4 ;; esac
[ "$CELL_CAP" -ge 1 ] || CELL_CAP=4
# --jobs > 1 uses `wait -n` (bash >= 4.3). On an older bash, degrade to the serial path rather than misbehave.
if [ "$JOBS" -gt 1 ]; then
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; then
    echo "run-discovery.sh: --jobs > 1 needs bash >= 4.3 (wait -n) — running serially instead" >&2
    JOBS=1
  fi
fi

# --- factored cell primitives: run_cell + scrape_cell_log are called IDENTICALLY by the serial loop and the
# deferred parallel-aggregation pass, so --jobs 1 stays byte-for-byte identical to the pre-M3 hunt (#1625). ---

# _json_str <s> — emit <s> as a JSON string literal (escape backslash + double-quote; cell output is single-line).
_json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# _json_id_array — #2223: read check ids on stdin, print them as the INSIDE of a JSON array (`2,5`), or
# nothing when there are none. The caller decides whether to emit the key at all, which is what keeps every
# id field absent (not `[]`) on a cell that has nothing to report.
_json_id_array() {
  ja_out=""
  while IFS= read -r ja_id; do
    [ -n "$ja_id" ] || continue
    if [ -z "$ja_out" ]; then ja_out="$ja_id"; else ja_out="$ja_out,$ja_id"; fi
  done
  printf '%s' "$ja_out"
}

# _join_wrapped_candidates <log> — reconstruct one logical line per `CANDIDATE|...` record from a hunt log,
# undoing flat-cyborg's PTY-capture line wrap (#1705). A `CANDIDATE|file:fn:line|class|severity|exploit|poc`
# record's exploit/poc_sketch prose routinely exceeds one physical line; the raw log then carries the tail
# as continuation lines with no `CANDIDATE|` prefix, which a bare `grep 'CANDIDATE|'` silently drops. Here a
# `CANDIDATE|` line opens/flushes a record; a `BLACKBOARD-*` line, a `DEPTH-CELL|` line (#1827), an
# `APPENDIX-CONTEXT|` line (#1865), a `REFUTE-CONSTRAINTS|` line (#1887), a `CALLEE-TRUST|` line (#2145), an
# `OPERATIONALIZE|` line or a model-emitted `OPCHECK|` line (#2211) or a model-emitted `TRACE|` line (#2214)
# or a `SEVERITY-RUBRIC|` line or a model-emitted `DISMISS|` line (#2245 iteration 2)
# or a blank line closes the current record
# without starting a new one
# (these are the only meaningful boundary tokens in a hunt log — see hunter.ag's own framing); any other line
# while a record is open is a continuation, appended with a single space (terminal wrap breaks on column
# width, not on meaningful newlines — a stray space is a cosmetic artifact, not data loss). Emits one
# reconstructed line per record, in log order.
_join_wrapped_candidates() {
  jwc_log="$1"
  awk '
    /^[[:space:]]*CANDIDATE\|/ {
      if (rec != "") print rec
      rec = $0
      next
    }
    /^[[:space:]]*BLACKBOARD-/ || /^[[:space:]]*DEPTH-CELL\|/ || /^[[:space:]]*APPENDIX-CONTEXT\|/ || /^[[:space:]]*REFUTE-CONSTRAINTS\|/ || /^[[:space:]]*CALLEE-TRUST\|/ || /^[[:space:]]*OPERATIONALIZE\|/ || /^[[:space:]]*EXTERNAL-RESOLVE\|/ || /^[[:space:]]*ONCHAIN-FACT\|/ || /^[[:space:]]*SEVERITY-RUBRIC\|/ || /^[[:space:]]*DISMISS\|/ || /^[[:space:]]*OPCHECK\|/ || /^[[:space:]]*TRACE\|/ || /^[[:space:]]*$/ {
      if (rec != "") { print rec; rec = "" }
      next
    }
    {
      if (rec != "") {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        rec = rec " " line
      }
    }
    END { if (rec != "") print rec }
  ' "$jwc_log"
}

# --- #2214 Lever 1: the OPCHECK -> TRACE FOLLOW-THROUGH GATE ------------------------------------------------
# The measured gap (#2213 forensics, archived treatment arm): cells derived 5-12 `OPCHECK|` checks, wrote them
# out in full compliance with the #2211 directive, then answered SAFE with ZERO of them traced in the reply —
# 4 of 6 cells on the target zone. Compliance with an emission contract is not follow-through, and prompt text
# is not a gate (#2213's null is the evidence). So the contract is closed HERE, on the OUTPUT: a cell that
# answers without a candidate while it left derived checks untraced is NOT a rigorous negative.

# _distinct_sentinel_count <TOKEN> <log> — how many DISTINCT `<TOKEN>|...` lines the log carries. Whitespace-
# trimmed and `^[[:space:]]*`-anchored exactly like the `ac_opn` dosage count below, because both tokens are
# MODEL-emitted free text and a PTY capture routinely indents them.
_distinct_sentinel_count() {
  dsc_tok="$1"; dsc_log="$2"
  dsc_n="$(grep -E "^[[:space:]]*${dsc_tok}\|" "$dsc_log" 2>/dev/null \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u | grep -c . || true)"
  case "$dsc_n" in ''|*[!0-9]*) dsc_n=0 ;; esac
  printf '%s\n' "$dsc_n"
}

# _distinct_trace_lines <log> — the DISTINCT, whitespace-trimmed `TRACE|` lines of one cell log, one per
# output line. Same normalisation as _distinct_sentinel_count, so the citation detectors below count exactly
# the lines that arithmetic counts (a pasted trace line is one line on both sides).
_distinct_trace_lines() {
  dtl_log="$1"
  grep -E '^[[:space:]]*TRACE\|' "$dtl_log" 2>/dev/null \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u || true
}

# --- #2223: PER-CHECK PAIRING BY ID -------------------------------------------------------------------------
# The #2222 QA counter-example: 3 `OPCHECK|` lines answered by 3 distinct but semantically UNRELATED `TRACE|`
# lines satisfy a COUNT rule exactly. So the directive now numbers each derived check (`OPCHECK|#k|...`) and
# asks for its answer under the same number (`TRACE|#k|<verdict>|<evidence>`), and the pairing below is done
# on that id: a paraphrase cannot break it and an unrelated trace line cannot discharge a check.
#
# The id is the check's ORDINAL WITHIN THE CELL, never a global identity — cells are independent hunts.
# Everything here is whitespace-trimmed and `^[[:space:]]*`-anchored for the same reason the count rule is:
# these are MODEL-emitted lines captured through a PTY, which routinely indents them.

# _ids_of_lines — read sentinel lines on stdin, print the distinct check ids they carry (the `#k` in field 2,
# `#` stripped), ascending. A line whose field 2 is not a bare `#<digits>` carries no id and is skipped here;
# it is accounted for by the callers (an un-numbered OPCHECK is a shortfall, an un-numbered TRACE answers
# nothing). Per-line `sed` rather than `tr -d` on the stream: `tr` would also eat the newlines.
_ids_of_lines() {
  cut -d'|' -f2 | sed 's/[[:space:]]//g' | grep -E '^#[0-9]+$' | sed 's/^#//' | sort -n -u
}

# _check_ids <TOKEN> <log> — the distinct check ids the log's `<TOKEN>|` lines carry, ascending.
_check_ids() {
  ci_tok="$1"; ci_log="$2"
  [ -f "$ci_log" ] || return 0
  grep -E "^[[:space:]]*${ci_tok}\|" "$ci_log" 2>/dev/null \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | _ids_of_lines
}

# _count_stdin — how many non-empty lines arrive on stdin, as a validated integer.
_count_stdin() {
  cs_n="$(grep -c . || true)"
  case "$cs_n" in ''|*[!0-9]*) cs_n=0 ;; esac
  printf '%s\n' "$cs_n"
}

# _untraced_rule <log> — which pairing rule decides this cell: `id` when at least one OPCHECK line carries an
# id, `count` when the cell wrote OPCHECK lines but numbered none (an older transcript, or a model that
# ignored the numbering half of the contract). Prints NOTHING when the cell carries no OPCHECK line at all —
# i.e. every cell with the lens off, which is why the additive JSON field below is absent there.
_untraced_rule() {
  ur_log="$1"
  [ -f "$ur_log" ] || return 0
  grep -qE '^[[:space:]]*OPCHECK\|' "$ur_log" 2>/dev/null || return 0
  if grep -qE '^[[:space:]]*OPCHECK\|[[:space:]]*#[0-9]+[[:space:]]*\|' "$ur_log" 2>/dev/null; then
    printf 'id\n'
  else
    printf 'count\n'
  fi
}

# _missing_check_ids <log> — the OPCHECK ids with NO TRACE line of the same id: the untraced checks under the
# id rule, ascending. This is the whole pairing rule — set difference on ids, no text similarity anywhere.
_missing_check_ids() {
  mci_log="$1"
  [ -f "$mci_log" ] || return 0
  mci_tr=" $(_check_ids TRACE "$mci_log" | tr '\n' ' ')"
  for mci_id in $(_check_ids OPCHECK "$mci_log"); do
    case "$mci_tr" in *" $mci_id "*) ;; *) printf '%s\n' "$mci_id" ;; esac
  done
}

# _orphan_trace_ids <log> — the TRACE ids that name NO OPCHECK id of this cell, ascending. A trace answering a
# check that was never derived is a defect of its own (a renumbered or invented answer), so it is counted and
# reported (`trace_orphans`) rather than silently ignored — but it never discharges anything.
_orphan_trace_ids() {
  oti_log="$1"
  [ -f "$oti_log" ] || return 0
  oti_op=" $(_check_ids OPCHECK "$oti_log" | tr '\n' ' ')"
  for oti_id in $(_check_ids TRACE "$oti_log"); do
    case "$oti_op" in *" $oti_id "*) ;; *) printf '%s\n' "$oti_id" ;; esac
  done
}

# _unnumbered_opchecks <log> — how many DISTINCT OPCHECK lines carry no id while the cell is under the id
# rule. Such a check cannot be paired with anything, so it counts toward the shortfall (and so re-asks the
# cell) even though it has no id to name in the re-ask.
_unnumbered_opchecks() {
  uo_log="$1"
  [ -f "$uo_log" ] || { printf '0\n'; return 0; }
  grep -E '^[[:space:]]*OPCHECK\|' "$uo_log" 2>/dev/null \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u \
    | grep -vE '^OPCHECK\|[[:space:]]*#[0-9]+[[:space:]]*\|' | _count_stdin
}

# _uncited_dismissal_lines <log> [repo_dir] [cache_dir] — #2214 PR C: the DISTINCT traced CLEANs of this cell that
# dismissed a check without the citation their grounds require (see the heuristics block in the header), one
# per output line. #2223 split the LINES out of the counter so the same detector can be read two ways: as an
# integer (_uncited_dismissals, the count rule) or per check id (_uncited_check_ids, the id rule) — one
# detector, two projections, so the two rules can never disagree about what is uncited.
# The count is ADDED to the follow-through shortfall by _opcheck_trace_gap below, so an uncited dismissal is
# untraced for the existing gate: same one re-ask, same `untraced-opcheck` FAILED reason, no new status
# vocabulary. [repo_dir] is OPTIONAL and empty is documented behaviour, not a gap: with no repo_dir the
# check stays the pre-#2225 citation-SHAPE-only check (a well-formed `path:line` counts, on EITHER branch,
# because the content genuinely cannot be resolved without a repo to read it against). When repo_dir IS
# given, both branches go further, per the plan's own definition of VERIFIED ("the cited text is IN THIS
# REPOSITORY"): a `path:line` whose FILE DOES NOT EXIST under repo_dir counts as UNCITED — a fabricated or
# hallucinated citation is by construction not in the repository, so it must not be treated the same as one
# the caller simply cannot check. On the EXTERNAL branch only, a file that DOES exist also has its cited
# line range read for the fact tokens the TRACE relies on (#2225): a range that names the file but states
# none of them is uncited too. The CONFIG branch stops at existence — rule 1 requires ONLY a citation of
# what the repo configures (config_realizability_rule() in hunter.ag), not a specific fact token in range.
#
# [cache_dir] is #2235 PR B's third acceptance branch and the SAME kind of optional seam: the root of the
# resolve-external.sh cache. A TRACE carrying the `EXTERNAL-CITED` evidence kind is cited only when ALL of
#   (i) the cited path resolves under repo_dir OR under cache_dir — a path under neither is uncited and is
#       never opened, so no file outside the two roots the harness owns can be cited at all;
#   (ii) the file exists;
#   (iii) the cited line range literally states one of the fact tokens (the SAME #2227 content check),
# hold. Otherwise the line flows into the existing per-check uncited path (#2230): THAT check degrades, no new
# status vocabulary, never a whole-cell failure. Empty cache_dir (every run without --external-resolve) keeps
# today's behaviour exactly — there is then no cache to re-open anything from.
#
# #2235 PR C adds the FOURTH branch on the same contract, for a claim about DEPLOYED STATE rather than source.
# A TRACE carrying `ONCHAIN <chain>:<address>:<selector>@<block> = <result>` is cited only when the on-chain
# cache under cache_dir holds a record for exactly that call AND that block whose RESULT is exactly the cited
# value. The lookup is a file read under cache_dir — never a network call, so re-judging a log needs no RPC
# and an endpoint that has since changed cannot rewrite a verdict. A cited value that was never read, was read
# at another block, or disagrees with what was cached is uncited; and because onchain-fact.sh caches NOTHING
# on an `unavailable` answer (no endpoint, revert, spent budget), a check resting on one can never be closed.
#
# The regexes live HERE rather than in globals so the function is self-contained: demo-operationalize-lens.sh
# slices it out of this file by line range and sources it, and a detector that depended on script-level state
# would silently behave differently there than in production. [repo_dir] is an explicit PARAMETER for the
# same reason — the function never reads the caller's $REPO global.
#
# The span searched is fields 3..N of the TRACE line (verdict + evidence), NOT the evidence field alone: the
# measured cells routinely merge the two ("CLEAN — a VALID configuration exists ... a privileged deploy-time
# misconfiguration"), and a detector anchored on field 4 would miss exactly the shape it was built for.
_uncited_dismissal_lines() {
  ud_log="$1"
  ud_repo="${2:-}"
  ud_cache="${3:-}"
  [ -f "$ud_log" ] || return 0
  # Configuration-grounds vocabulary and the repo citation it must carry. #2225: the citation must sit UNDER
  # a directory that records what the repo actually SHIPS (deploy/test/script/docs evidence) — a `.sol` under
  # `src/` only names the flag it declares, which is exactly the shape the measured H-8 dismissals used.
  ud_cfg_re='misconfig|trusted[ -](role|deployer)|privileged[ -](role|deployer)|deploy-time|deployment[ -]configuration|configuration[ -](choice|invariant)'
  ud_cfg_pathline_re='(^|[^A-Za-z0-9_])(test|tests|script|scripts|deploy|docs)/[A-Za-z0-9_/.-]+\.(sol|ts|js|md|json|toml|ya?ml):[0-9]+(-[0-9]+)?'
  # External-fact vocabulary: an assertion about behaviour this payload does not settle. #2225: the ONLY
  # citation shape that can discharge it is a repo `path:line` (optionally a `path:a-b` range) — a URL, a
  # bare source-file name and a bare interface identifier NAME something without pointing at text that states
  # what it does, which is exactly the shape #2214 M-12 measured closing a false CLEAN.
  ud_ext_re='documented|by construction|by design|always returns|normali[sz]ed|normali[sz]es|1e18|decimals|guarantee[sd]?'
  ud_pathline_re='[A-Za-z0-9_/.-]+\.(sol|ts|js|md|json|toml|ya?ml):[0-9]+(-[0-9]+)?'
  # The fact tokens the TRACE relies on: a cited range that states none of these only NAMES the file, it does
  # not STATE the scaling/decimals/normalisation/ordering property the check depends on.
  ud_fact_re='1e18|decimals|WAD|ONE|normali|scale|order'
  # #2235: the evidence kind a cell may only produce after it actually RESOLVED the external symbol. It is
  # matched before the two #2214 branches because a resolved citation discharges BOTH of their grounds.
  ud_extcited_re='EXTERNAL-CITED'
  # #2235 PR C: the on-chain evidence kind and the citation it must carry. The call id and the block are
  # exactly what onchain-fact.sh printed, so the harness can rebuild the cache path from the TRACE line alone.
  ud_onchain_re='ONCHAIN'
  ud_oncall_re='[0-9]{1,10}:0x[0-9a-fA-F]{40}:[A-Za-z_][A-Za-z0-9_]*\([]A-Za-z0-9_,[]*\)@[0-9]+'
  # Same shape as ud_pathline_re plus `@`, because a cached upstream clone lives under
  # `<cache>/repo/<host>/<org>/<name>@<ref>/…` — without the `@` the match would start MID-PATH and a real
  # cache citation could never resolve. Kept separate so the #2225/#2227 branches keep their exact regex.
  ud_xpathline_re='[A-Za-z0-9_@/.-]+\.(sol|ts|js|md|json|toml|ya?ml):[0-9]+(-[0-9]+)?'
  while IFS= read -r ud_line; do
    [ -n "$ud_line" ] || continue
    # Only a CLEAN is a dismissal: BUG is a finding and UNRESOLVED is the honest verdict this rule asks for.
    ud_verdict="$(printf '%s\n' "$ud_line" | cut -d'|' -f3)"
    case "$ud_verdict" in *[Cc][Ll][Ee][Aa][Nn]*) ;; *) continue ;; esac
    ud_span="$(printf '%s\n' "$ud_line" | cut -d'|' -f3-)"
    # #2235 PR C: the ONCHAIN branch, judged BEFORE the source branches for the same reason PR B's is — an
    # accepted on-chain citation answers rules 1 and 2 outright, and a rejected one must not then be re-judged
    # by a branch that would call it uncited for the wrong reason. `EXTERNAL-CITED` carries no `ONCHAIN`
    # substring, so the two kinds never contend for the same line.
    if printf '%s\n' "$ud_span" | grep -q "$ud_onchain_re"; then
      ud_ocite="$(printf '%s\n' "$ud_span" | grep -oE "$ud_oncall_re" | head -1)"
      # The cited VALUE: the token after the `=` that follows the call id, matched as ONE span with the same
      # ERE the call id uses (never a second, BRE-flavoured expression — the two could then disagree about
      # what they matched). Trailing prose punctuation and the backticks a model likes to wrap a value in are
      # stripped, and the comparison is case-insensitive so a hex word cited in another case still matches.
      ud_opair="$(printf '%s\n' "$ud_span" \
        | grep -oE "${ud_oncall_re}[[:space:]]*=[[:space:]]*[^[:space:]]+" | head -1)"
      ud_ovalue="$(printf '%s' "${ud_opair##*=}" | tr -d ' `"'"'"',;' | sed 's/\.$//' | tr 'A-Z' 'a-z')"
      ud_ook=0
      if [ -z "$ud_cache" ]; then
        # No cache root to re-open against: the same shape-only contract the other branches keep in that case.
        [ -n "$ud_ocite" ] && [ -n "$ud_ovalue" ] && ud_ook=1
      elif [ -n "$ud_ocite" ] && [ -n "$ud_ovalue" ]; then
        ud_oid="${ud_ocite%@*}"
        ud_oblock="${ud_ocite##*@}"
        ud_ochain="${ud_oid%%:*}"
        ud_orest="${ud_oid#*:}"
        ud_oaddr="$(printf '%s' "${ud_orest%%:*}" | tr 'A-F' 'a-f')"
        ud_odir="$ud_cache/onchain/$ud_ochain/$ud_oaddr/$ud_oblock"
        if [ -d "$ud_odir" ]; then
          for ud_orec in "$ud_odir"/*.tsv; do
            [ -f "$ud_orec" ] || continue
            # Field 1 is the call id the reader emitted, field 4 the result it cached. A record for another
            # call (same address, different selector) is skipped rather than matched on its value alone.
            ud_oreccall="$(cut -f1 "$ud_orec" 2>/dev/null | head -1 | tr 'A-F' 'a-f')"
            [ "$ud_oreccall" = "$(printf '%s' "$ud_oid" | tr 'A-F' 'a-f')" ] || continue
            ud_orecval="$(cut -f4 "$ud_orec" 2>/dev/null | head -1 | tr 'A-Z' 'a-z')"
            if [ -n "$ud_orecval" ] && [ "$ud_orecval" = "$ud_ovalue" ]; then ud_ook=1; break; fi
          done
        fi
      fi
      if [ "$ud_ook" -eq 0 ]; then printf '%s\n' "$ud_line"; fi
      continue
    fi
    # #2235 PR B: the EXTERNAL-CITED branch. A cell that RESOLVED the fact and cites what it read has done
    # exactly what rules 1 and 2 ask for, so an accepted citation ends the judgement of this line — and a
    # citation the harness cannot re-open ends it the other way, without falling through to the branches
    # below, whose repo-relative resolution would call every cache path uncited for the wrong reason.
    if printf '%s\n' "$ud_span" | grep -q "$ud_extcited_re"; then
      ud_xcite="$(printf '%s\n' "$ud_span" | grep -oE "$ud_xpathline_re" | head -1)"
      ud_xok=0
      if [ -z "$ud_repo" ] && [ -z "$ud_cache" ]; then
        # No root to resolve against: the same shape-only contract the two branches below keep in that case.
        [ -n "$ud_xcite" ] && ud_xok=1
      elif [ -n "$ud_xcite" ]; then
        ud_xfile="${ud_xcite%%:*}"
        ud_xrange="${ud_xcite#*:}"
        case "$ud_xrange" in
          *-*) ud_xa="${ud_xrange%-*}"; ud_xb="${ud_xrange#*-}" ;;
          *)   ud_xa="$ud_xrange"; ud_xb="$ud_xrange" ;;
        esac
        # (i) the path must land INSIDE one of the two roots. A relative path is repo-relative (the #2227
        # shape); an absolute one must be a prefix match on a root. `..` is refused outright rather than
        # normalised, so a prefix match can never be walked back out of the root it matched.
        ud_xabs=""
        case "$ud_xfile" in
          *..*) : ;;
          /*)
            if [ -n "$ud_cache" ] && [ "${ud_xfile#"$ud_cache"/}" != "$ud_xfile" ]; then ud_xabs="$ud_xfile"
            elif [ -n "$ud_repo" ] && [ "${ud_xfile#"$ud_repo"/}" != "$ud_xfile" ]; then ud_xabs="$ud_xfile"
            fi ;;
          *) [ -n "$ud_repo" ] && ud_xabs="$ud_repo/$ud_xfile" ;;
        esac
        # (ii) it must exist and (iii) the cited range must STATE the fact — the unchanged #2227 content check.
        if [ -n "$ud_xabs" ] && [ -f "$ud_xabs" ] \
           && sed -n "${ud_xa},${ud_xb}p" "$ud_xabs" 2>/dev/null | grep -qiE "$ud_fact_re"; then
          ud_xok=1
        fi
      fi
      if [ "$ud_xok" -eq 0 ]; then printf '%s\n' "$ud_line"; fi
      continue
    fi
    if printf '%s\n' "$ud_span" | grep -Eqi "$ud_cfg_re"; then
      if ! printf '%s\n' "$ud_span" | grep -Eq "$ud_cfg_pathline_re"; then
        printf '%s\n' "$ud_line"
        continue
      fi
      # #2225 QA fix: shape-accepted is not enough — a citation whose file does not
      # exist under the target repo cannot be evidence of what the repo ships either.
      # Only checked when repo_dir is given (see the header: empty repo_dir keeps the
      # pre-#2225 shape-only check, since the content cannot be resolved either way).
      if [ -n "$ud_repo" ]; then
        ud_cfg_cite="$(printf '%s\n' "$ud_span" | grep -oE "$ud_pathline_re" | head -1)"
        if [ -n "$ud_cfg_cite" ] && [ ! -f "$ud_repo/${ud_cfg_cite%%:*}" ]; then
          printf '%s\n' "$ud_line"
          continue
        fi
      fi
    fi
    if printf '%s\n' "$ud_span" | grep -Eqi "$ud_ext_re"; then
      ud_cite="$(printf '%s\n' "$ud_span" | grep -oE "$ud_pathline_re" | head -1)"
      if [ -z "$ud_cite" ]; then
        # No repo path:line at all — the #2225-dropped URL/bare-name/bare-interface shapes land here too.
        printf '%s\n' "$ud_line"
      elif [ -n "$ud_repo" ]; then
        ud_file="${ud_cite%%:*}"
        ud_range="${ud_cite#*:}"
        case "$ud_range" in
          *-*) ud_a="${ud_range%-*}"; ud_b="${ud_range#*-}" ;;
          *)   ud_a="$ud_range"; ud_b="$ud_range" ;;
        esac
        if [ ! -f "$ud_repo/$ud_file" ]; then
          # #2225 QA fix: a citation to a file that does not exist under the repo
          # cannot state anything either — uncited, not an unverifiable pass-through.
          printf '%s\n' "$ud_line"
        elif ! sed -n "${ud_a},${ud_b}p" "$ud_repo/$ud_file" 2>/dev/null | grep -qiE "$ud_fact_re"; then
          # The file resolves and its cited range says none of the fact tokens: it names the file, not the fact.
          printf '%s\n' "$ud_line"
        fi
      fi
    fi
  done <<EOF
$(_distinct_trace_lines "$ud_log")
EOF
}

# _uncited_dismissals <log> [repo_dir] [cache_dir] — the COUNT of those lines, the integer the count-rule
# shortfall adds (see _opcheck_trace_gap). Kept as its own entry point so the count rule keeps the exact
# arithmetic it was measured with; the id rule uses _uncited_check_ids below instead, which attributes each
# one to its check. Both optional roots thread straight through — never a second opinion about what is cited.
_uncited_dismissals() {
  _uncited_dismissal_lines "$1" "${2:-}" "${3:-}" | _count_stdin
}

# _uncited_check_ids <log> [repo_dir] [cache_dir] — #2223: the ids of the checks whose TRACE line is an uncited dismissal,
# ascending. Only ids this cell actually DERIVED are reported: an uncited trace carrying an orphan id answers
# no check of this cell (it is counted as an orphan instead), and one carrying no id at all cannot be
# attributed — its check is already reported as untraced. This is what makes the citation rules of #2224/#2227
# apply PER TRACE: they mark THAT check unresolved/uncited, never the whole cell.
_uncited_check_ids() {
  uci_log="$1"; uci_repo="${2:-}"; uci_cache="${3:-}"
  [ -f "$uci_log" ] || return 0
  uci_op=" $(_check_ids OPCHECK "$uci_log" | tr '\n' ' ')"
  for uci_id in $(_uncited_dismissal_lines "$uci_log" "$uci_repo" "$uci_cache" | _ids_of_lines); do
    case "$uci_op" in *" $uci_id "*) printf '%s\n' "$uci_id" ;; esac
  done
}

# _unresolved_trace_count <log> — #2214 PR C: how many DISTINCT checks this cell carried as UNRESOLVED. The
# additive per-cell `unresolved` field _accumulate_cell writes, and the stderr note scrape_cell_log prints,
# are what keep an honest "I could not settle this" from folding silently into a clean-looking SAFE.
_unresolved_trace_count() {
  utc_log="$1"
  if [ ! -f "$utc_log" ]; then printf '0\n'; return 0; fi
  utc_n="$(_distinct_trace_lines "$utc_log" | cut -d'|' -f3 | grep -ci 'UNRESOLVED' || true)"
  case "$utc_n" in ''|*[!0-9]*) utc_n=0 ;; esac
  printf '%s\n' "$utc_n"
}

# _unresolved_check_ids <log> — #2223: the checks this cell carried as UNRESOLVED, one `<id>\t<check text>`
# row per id, ascending. The text is the OPCHECK line's own wording (its fields after the id), so the carry
# survives the cell without the reader having to go back to the log — this is the row #2217 consumes when it
# turns an UNRESOLVED on a rare-class check into a second-tier candidate. A cell under the count rule emits
# no rows (its traces name no check), which is why the additive JSON field is absent there.
_unresolved_check_ids() {
  uci2_log="$1"
  [ -f "$uci2_log" ] || return 0
  awk '
    function idof(l,   g, m, v) {
      m = split(l, g, "|"); if (m < 2) return "";
      v = g[2]; gsub(/[[:space:]]/, "", v);
      if (v !~ /^#[0-9]+$/) return "";
      sub(/^#/, "", v); return v;
    }
    { line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line) }
    index(line, "OPCHECK|") == 1 {
      id = idof(line)
      if (id != "") {
        n = split(line, f, "|"); t = ""
        for (i = 3; i <= n; i++) { t = (t == "" ? f[i] : t "|" f[i]) }
        txt[id] = t
      }
      next
    }
    index(line, "TRACE|") == 1 {
      id = idof(line)
      if (id != "") {
        n = split(line, f, "|")
        if (n >= 3 && toupper(f[3]) ~ /UNRESOLVED/) { unres[id] = 1 }
      }
      next
    }
    END { for (k in unres) print k "\t" (k in txt ? txt[k] : "") }
  ' "$uci2_log" | sort -n
}

# --- #2217 PR A: SECOND-TIER (tier-2) RECORDS ---------------------------------------------------------------
# WHAT THIS CARRIES. The #2223 per-check breakdown already records, per cell, WHICH derived checks the cell
# left open: `unresolved_ids` (with the check's own OPCHECK text) and `uncited_ids` (a CLEAN dismissal without
# the citation its grounds require). Those records die inside the cell object — nothing downstream can act on
# one. A tier-2 record is that SAME decision, carried to the top of the run with a location it can be looked
# up by. It costs ZERO extra LLM calls and changes no prompt: every input already exists in the cell log this
# run produced, and the derivation below is pure shell.
#
# A TIER-2 RECORD IS NOT A CANDIDATE. It says "the cell derived this check and did not settle it", nothing
# more: no severity is assessed (`severity` ships EMPTY, by construction), it never enters `candidates[]`, and
# it is never a finding. Letting one reach the refute gate is a separate, separably-gated change (#2217 PR C).
#
# SOURCE SET (the #2217 STOP-1 decision): `unresolved_ids` + `uncited_ids` ONLY. Every CLEAN dismissal would be
# ~50 records per cell and would bury the signal under the cap's ranking.
#
# SCHEMA — top-level `tier2[]` of discovery-results.json, emitted ONLY when the feature is ON and non-empty:
#   subsystem   the manifest label of the cell that derived the check
#   class       the bug class that cell hunted (C1..C24)
#   id          the check's ordinal WITHIN THAT CELL (the #2223 `OPCHECK|#k` id) — never a global identity
#   kind        "unresolved" (a TRACE answered UNRESOLVED) | "uncited" (a CLEAN dismissal with no valid citation)
#   location    "<path>:<function>" when it could be derived from the check's own text, else "<path>" (fallback)
#   loc_source  "opcheck" = derived from the CHECK TEXT | "zone" = fell back to this cell's file list
#   loc_rule    "contract-fn" | "contract-only" | "fn-grep" | "file-only" — WHICH rule produced it (see
#               _tier2_location)
#   severity    ALWAYS "" — a tier-2 record carries no severity assessment
#   check       the OPCHECK line's own wording (its fields 3..n)
#   why         the TRACE line's evidence span (its fields 4..n) — the cell's own reason for not settling it
# plus `totals.tier2` (records kept) and `totals.tier2_dropped` (records the per-zone cap discarded). Both
# totals and the array ride the same emit-only-when-non-empty discipline as every additive field above, so a
# run with the feature OFF — or ON with no unsettled check anywhere — is BYTE-IDENTICAL to a pre-#2217 run.
#
# The functions below are self-contained (no script-level global, every knob read inline with its default) for
# the reason the citation detectors are: demo-operationalize-lens.sh slices them out of this file by line range
# and sources them, and a helper that depended on caller state would behave differently there than in
# production — which is exactly what the slicing exists to prevent.

# _tier2_flat <s> — one-line, trimmed text. TAB is the record separator of the accumulator below, so a tab (or
# a stray newline) inside a model-emitted check text would silently shift every later column; it is collapsed
# to a space HERE, once, rather than guarded for at each read site.
_tier2_flat() {
  printf '%s' "$1" | tr '\t\n' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# _opcheck_text <log> <id> — the wording of the OPCHECK line carrying <id> (its fields 3..n, `|` preserved), or
# nothing. First occurrence wins, so a repeated check cannot make the derivation depend on log length.
_opcheck_text() {
  ot_log="$1"; ot_id="$2"
  [ -f "$ot_log" ] || return 0
  grep -E '^[[:space:]]*OPCHECK\|' "$ot_log" 2>/dev/null \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | awk -F'|' -v want="$ot_id" '
        { v = $2; gsub(/[[:space:]]/, "", v) }
        v == "#" want {
          t = ""; for (i = 3; i <= NF; i++) { t = (t == "" ? $i : t "|" $i) }
          print t; exit
        }'
}

# _trace_evidence <log> <id> — the EVIDENCE SPAN of the TRACE line carrying <id> (fields 4..n of
# `TRACE|#k|<verdict>|<evidence>`), or nothing. This is the cell's own "why": for an UNRESOLVED check it is
# what it could not settle, for an uncited CLEAN it is the unsupported ground it closed on. First occurrence
# wins (same determinism rule as above).
_trace_evidence() {
  te_log="$1"; te_id="$2"
  [ -f "$te_log" ] || return 0
  grep -E '^[[:space:]]*TRACE\|' "$te_log" 2>/dev/null \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | awk -F'|' -v want="$te_id" '
        { v = $2; gsub(/[[:space:]]/, "", v) }
        v == "#" want {
          t = ""; for (i = 4; i <= NF; i++) { t = (t == "" ? $i : t "|" $i) }
          print t; exit
        }'
}

# _unresolved_check_rows <log> — the UNRESOLVED carry as `<id>\t<check text>\t<why>` rows, ascending. The first
# two columns are _unresolved_check_ids's own output (that function is REUSED rather than re-implemented, so
# the shipped `unresolved_ids` JSON stays byte-identical and the two cannot drift); the third is the TRACE
# line's evidence span.
_unresolved_check_rows() {
  ucr_log="$1"
  [ -f "$ucr_log" ] || return 0
  while IFS='	' read -r ucr_id ucr_txt; do
    [ -n "$ucr_id" ] || continue
    printf '%s\t%s\t%s\n' "$ucr_id" "$(_tier2_flat "$ucr_txt")" "$(_tier2_flat "$(_trace_evidence "$ucr_log" "$ucr_id")")"
  done <<EOF
$(_unresolved_check_ids "$ucr_log")
EOF
}

# _uncited_check_rows <log> [repo_dir] [cache_dir] — the same row shape for the checks whose TRACE closed
# CLEAN on an UNCITED dismissal (_uncited_check_ids decides which those are; both optional roots thread
# straight through to it, so the tier-2 source set is exactly the set the #2225/#2227/#2235 detectors flag —
# never a second opinion about it).
_uncited_check_rows() {
  ukr_log="$1"; ukr_repo="${2:-}"; ukr_cache="${3:-}"
  [ -f "$ukr_log" ] || return 0
  for ukr_id in $(_uncited_check_ids "$ukr_log" "$ukr_repo" "$ukr_cache"); do
    printf '%s\t%s\t%s\n' "$ukr_id" \
      "$(_tier2_flat "$(_opcheck_text "$ukr_log" "$ukr_id")")" \
      "$(_tier2_flat "$(_trace_evidence "$ukr_log" "$ukr_id")")"
  done
}

# _tier2_emit_loc <loc> <loc_source> <loc_rule> — print the derived location triple, but ONLY when <loc> passes
# the pinned shape `<path>.sol:<function>`: a bare path, exactly one `:`, no `@fn` slice suffix, no `~(...)`
# tail, no whitespace. score-match.py's lead_location() parses exactly that into (basename, function); a
# location outside it cannot be pair-credited and would be worse than the honest zone fallback. Returns
# non-zero (so the caller falls through to the next rule) when the shape does not hold.
_tier2_emit_loc() {
  printf '%s\n' "$1" | grep -qE '^[A-Za-z0-9_./-]+\.sol:[A-Za-z_][A-Za-z0-9_]*$' || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

# _tier2_emit_bare_loc <path> <loc_source> <loc_rule> — the same gate as _tier2_emit_loc for a location that
# names a FILE and NO function: a bare path, no `:` at all, no decoration. The contract-only rule below claims
# exactly that much ("the check names THIS contract") and must not invent a function half to satisfy a shape
# gate written for locations that have one.
_tier2_emit_bare_loc() {
  printf '%s\n' "$1" | grep -qE '^[A-Za-z0-9_./-]+\.sol$' || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

# _tier2_resolve_file <basename> <files-csv> — the path IN THIS CELL'S file list whose basename is <basename>
# (exact match first, then case-insensitive), or nothing. A `file@fn+fn` slice token (#2150) names the same
# file, so the `@` tail is stripped before comparing. Resolving against the CELL's own list — never a repo-wide
# search — is what keeps a derived location inside the payload the model actually read.
_tier2_resolve_file() {
  trf_want="$1"; trf_rest="$2,"; trf_ci=""
  while [ -n "$trf_rest" ]; do
    trf_one="${trf_rest%%,*}"; trf_rest="${trf_rest#*,}"
    trf_one="${trf_one%%@*}"
    [ -n "$trf_one" ] || continue
    trf_base="${trf_one##*/}"
    if [ "$trf_base" = "$trf_want" ]; then printf '%s\n' "$trf_one"; return 0; fi
    if [ -z "$trf_ci" ] \
       && [ "$(printf '%s' "$trf_base" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$trf_want" | tr 'A-Z' 'a-z')" ]; then
      trf_ci="$trf_one"
    fi
  done
  if [ -n "$trf_ci" ]; then printf '%s\n' "$trf_ci"; fi
  return 0
}

# _tier2_location <check-text> <files-csv> [repo_dir] — DETERMINISTIC location derivation, printed as
# `<location>\t<loc_source>\t<loc_rule>`. The precedence is pinned (first rule that yields a well-shaped
# location wins) and nothing here consults an LLM:
#   L1 contract-fn — the check text names its own location. Either literally (`Foo.sol:_calcRate`) or as a
#      `Contract.function` mention (`FooOracle._calcRate`), scanned left to right; the file half is resolved
#      against THIS cell's file list. loc_source = "opcheck".
#   L1c contract-only — no `Contract.function` pair anywhere: a check text may name the contract it is about
#      and nothing else (`<Contract> <flag> selecting <rateA> vs <rateB> ...`). Scan the CAPITALISED
#      identifiers left to right and take the first whose `<Name>.sol` resolves against THIS cell's file list —
#      the resolve IS the gate, so a capitalised word naming no zone file costs nothing. When the text also
#      carries a call-shaped `name(` whose DECLARATION lives in that same file, the function half is appended;
#      a function declared in some OTHER file is not (it would contradict the contract just resolved).
#      loc_source = "opcheck". Before this rule such a text fell through to L3 and was located at the zone's
#      FIRST file — a name no scoreboard can credit against the contract the check actually named (#2217 M5).
#   L2 fn-grep     — no resolvable file half: take the first call-shaped mention (`_calcRate(`) and find the
#      first file of this cell's list (IN CSV ORDER, so ambiguity resolves deterministically) that declares
#      `function <fn>`. Needs [repo_dir] to read the files; without it the rule is skipped. loc_source = "opcheck".
#   L3 file-only   — neither resolves: the FIRST file of the cell's list, with NO function. loc_source =
#      "zone". Documented consequence: score-match.py's pair rule needs a function, so such a record cannot be
#      pair-credited at all — which is why the ranking below puts it LAST under the cap.
# Backticks, quotes, commas and parentheses are decoration a model wraps mentions in, never part of a path or
# an identifier, so they are blanked before matching (parentheses are KEPT for L2, which matches on them).
_tier2_location() {
  tl_text="$1"; tl_files="$2"; tl_repo="${3:-}"
  tl_paren="$(printf '%s' "$tl_text" | sed "s/[\`\"',]/ /g")"
  tl_clean="$(printf '%s' "$tl_paren" | tr '()' '  ')"
  # L1a: an explicit `<file>.sol:<function>` mention.
  tl_hit="$(printf '%s' "$tl_clean" | grep -oE '[A-Za-z0-9_./-]+\.sol:[A-Za-z_][A-Za-z0-9_]*' | head -1 || true)"
  if [ -n "$tl_hit" ]; then
    tl_hb="${tl_hit%%:*}"; tl_hb="${tl_hb##*/}"
    tl_p="$(_tier2_resolve_file "$tl_hb" "$tl_files")"
    if [ -n "$tl_p" ] && _tier2_emit_loc "$tl_p:${tl_hit##*:}" opcheck contract-fn; then return 0; fi
  fi
  # L1b: a `Contract.function` mention. `Foo.sol` is a FILE, not a call — skipped, L1a already had its turn.
  for tl_m in $(printf '%s' "$tl_clean" | grep -oE '[A-Z][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*' || true); do
    tl_fn="${tl_m#*.}"
    case "$tl_fn" in sol) continue ;; esac
    tl_p="$(_tier2_resolve_file "${tl_m%%.*}.sol" "$tl_files")"
    if [ -n "$tl_p" ] && _tier2_emit_loc "$tl_p:$tl_fn" opcheck contract-fn; then return 0; fi
  done
  # L1c: a BARE CONTRACT NAME, resolved against this cell's own file list (see the precedence note above).
  for tl_c in $(printf '%s' "$tl_clean" | grep -oE '[A-Z][A-Za-z0-9_]*' || true); do
    tl_p="$(_tier2_resolve_file "$tl_c.sol" "$tl_files")"
    [ -n "$tl_p" ] || continue
    if [ -n "$tl_repo" ] && [ -f "$tl_repo/$tl_p" ]; then
      for tl_fn in $(printf '%s' "$tl_paren" | grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' | tr -d ' (' || true); do
        grep -qE "function[[:space:]]+${tl_fn}[[:space:]]*\(" "$tl_repo/$tl_p" 2>/dev/null || continue
        if _tier2_emit_loc "$tl_p:$tl_fn" opcheck contract-only; then return 0; fi
      done
    fi
    if _tier2_emit_bare_loc "$tl_p" opcheck contract-only; then return 0; fi
  done
  # L2: a call-shaped mention, grepped for its declaration across this cell's files in CSV order.
  tl_call="$(printf '%s' "$tl_paren" | grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' | head -1 | tr -d ' (' || true)"
  if [ -n "$tl_call" ] && [ -n "$tl_repo" ]; then
    tl_rest="$tl_files,"
    while [ -n "$tl_rest" ]; do
      tl_one="${tl_rest%%,*}"; tl_rest="${tl_rest#*,}"
      tl_one="${tl_one%%@*}"
      [ -n "$tl_one" ] || continue
      if [ -f "$tl_repo/$tl_one" ] \
         && grep -qE "function[[:space:]]+${tl_call}[[:space:]]*\(" "$tl_repo/$tl_one" 2>/dev/null \
         && _tier2_emit_loc "$tl_one:$tl_call" opcheck fn-grep; then
        return 0
      fi
    done
  fi
  # L3: the zone fallback. No shape gate — a bare path is all this rule claims to know.
  tl_first="${tl_files%%,*}"; tl_first="${tl_first%%@*}"
  printf '%s\tzone\tfile-only\n' "$tl_first"
}

# _tier2_rare <class> — 0 when <class> is on the RARE-CLASS PRIORITY LIST, 1 otherwise. The list
# (DF_TIER2_RARE_CLASSES, default `C19,C20,C21,C22,C23,C24` — the classes the #1782 multi-class lens program
# minted for rare rows) is a PRIORITY LIST and nothing else: it decides which record survives the cap first,
# it is NOT a rarity oracle and it makes no claim about any individual record. Env-overridable as ONE list so a
# future out-of-class lens joins it without a code change.
_tier2_rare() {
  t2c_list="${DF_TIER2_RARE_CLASSES:-C19,C20,C21,C22,C23,C24}"
  case ",$t2c_list," in *",$1,"*) printf '0\n' ;; *) printf '1\n' ;; esac
}

# _tier2_records <subsystem> <class> <files-csv> <log> [repo_dir] [cache_dir] — every tier-2 record ONE cell log yields, as
# TAB-separated rows, unresolved rows first and each kind in ascending check id. Columns 1-3 are the RANK KEYS
# (see _tier2_select); the rest is the record:
#   1 rare(0|1)  2 kind(0=unresolved,1=uncited)  3 loc_rule(0=contract-fn,1=contract-only,2=fn-grep,3=file-only)
#   4 kind  5 class  6 subsystem  7 id  8 location  9 loc_source  10 loc_rule  11 check  12 why
_tier2_records() {
  t2r_subsys="$1"; t2r_cls="$2"; t2r_files="$3"; t2r_log="$4"; t2r_repo="${5:-}"; t2r_cache="${6:-}"
  [ -f "$t2r_log" ] || return 0
  t2r_rare="$(_tier2_rare "$t2r_cls")"
  for t2r_kind in unresolved uncited; do
    if [ "$t2r_kind" = unresolved ]; then t2r_krank=0; else t2r_krank=1; fi
    while IFS='	' read -r t2r_id t2r_check t2r_why; do
      case "$t2r_id" in ''|*[!0-9]*) continue ;; esac
      t2r_loc="$(_tier2_location "$t2r_check" "$t2r_files" "$t2r_repo")"
      t2r_l="$(printf '%s' "$t2r_loc" | cut -f1)"
      t2r_src="$(printf '%s' "$t2r_loc" | cut -f2)"
      t2r_rule="$(printf '%s' "$t2r_loc" | cut -f3)"
      case "$t2r_rule" in
        contract-fn)   t2r_lrank=0 ;;
        contract-only) t2r_lrank=1 ;;
        fn-grep)       t2r_lrank=2 ;;
        *)             t2r_lrank=3 ;;
      esac
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$t2r_rare" "$t2r_krank" "$t2r_lrank" "$t2r_kind" "$t2r_cls" "$(_tier2_flat "$t2r_subsys")" \
        "$t2r_id" "$t2r_l" "$t2r_src" "$t2r_rule" "$t2r_check" "$t2r_why"
    done <<EOF
$(if [ "$t2r_kind" = unresolved ]; then _unresolved_check_rows "$t2r_log"; else _uncited_check_rows "$t2r_log" "$t2r_repo" "$t2r_cache"; fi)
EOF
  done
}

# _tier2_select <tsv> <cap> — the records that survive the PER-ZONE CAP, in rank order. Rank = rare class
# first, then unresolved before uncited, then the location rule (contract-fn > contract-only > fn-grep > file-only), then the
# accumulator's own order — which is MANIFEST cell order, then ascending check id, because _accumulate_cell is
# called in manifest order on the serial, parallel (post-drain) and depth paths alike. `sort -s` is what makes
# that last tie-break the input order rather than an arbitrary one.
# The cap is applied HERE, over the whole zone, AFTER every cell has been accumulated — never per cell — so the
# selection is identical under `--jobs 1` and `--jobs N`. cap 0 (or garbage) selects nothing.
_tier2_select() {
  t2s_tsv="$1"; t2s_cap="$2"
  [ -f "$t2s_tsv" ] || return 0
  case "$t2s_cap" in ''|*[!0-9]*) return 0 ;; esac
  [ "$t2s_cap" -gt 0 ] || return 0
  sort -s -t'	' -k1,1n -k2,2n -k3,3n "$t2s_tsv" | head -n "$t2s_cap"
}

# _tier2_json_array — read selected rows on stdin, print the INSIDE of the `tier2[]` array (no brackets), or
# nothing. Same contract as _json_id_array: the CALLER decides whether the key is emitted at all, which is what
# keeps the key ABSENT (not `[]`) on a run with nothing to carry.
_tier2_json_array() {
  t2j_out=""
  # The three leading RANK columns are consumed by _tier2_select's sort, never by the record itself; they are
  # read into named variables (rather than dropped) so the column contract is legible at the read site.
  # shellcheck disable=SC2034
  while IFS='	' read -r t2j_rare t2j_kr t2j_lr t2j_kind t2j_cls t2j_sub t2j_id t2j_loc t2j_src t2j_rule t2j_check t2j_why; do
    case "$t2j_id" in ''|*[!0-9]*) continue ;; esac
    t2j_obj="{\"subsystem\":$(_json_str "$t2j_sub"),\"class\":$(_json_str "$t2j_cls"),\"id\":$t2j_id,\"kind\":$(_json_str "$t2j_kind"),\"location\":$(_json_str "$t2j_loc"),\"loc_source\":$(_json_str "$t2j_src"),\"loc_rule\":$(_json_str "$t2j_rule"),\"severity\":\"\",\"check\":$(_json_str "$t2j_check"),\"why\":$(_json_str "$t2j_why")}"
    if [ -z "$t2j_out" ]; then t2j_out="$t2j_obj"; else t2j_out="$t2j_out,$t2j_obj"; fi
  done
  printf '%s' "$t2j_out"
}

# _tier2_top_json <tsv> <on> <cap> — the TOP-LEVEL `,"tier2":[...]` fragment, or EXACTLY 0 bytes when the
# feature is off, the cap is 0, or the run carried nothing. Concatenating 0 bytes is a no-op, which is how the
# byte-identity contract of a feature-OFF run is met by construction rather than by assertion.
_tier2_top_json() {
  [ "$2" = "1" ] || return 0
  t2t_arr="$(_tier2_select "$1" "$3" | _tier2_json_array)"
  [ -n "$t2t_arr" ] || return 0
  printf ',"tier2":[%s]' "$t2t_arr"
}

# _tier2_totals_json <tsv> <on> <cap> — the `,"tier2":N,"tier2_dropped":M` fragment for the `totals` object,
# under the same gate and the same 0-byte contract. `tier2_dropped` is what the cap DISCARDED: a supply that
# exceeds the cap must be visible, never silently truncated.
_tier2_totals_json() {
  [ "$2" = "1" ] || return 0
  t2u_kept="$(_tier2_select "$1" "$3" | _count_stdin)"
  t2u_all="$(grep -c . "$1" 2>/dev/null || true)"
  case "$t2u_all" in ''|*[!0-9]*) t2u_all=0 ;; esac
  [ "$t2u_kept" -gt 0 ] || return 0
  printf ',"tier2":%s,"tier2_dropped":%s' "$t2u_kept" "$((t2u_all - t2u_kept))"
}

# _opcheck_trace_gap <log> [repo_dir] [cache_dir] — the follow-through shortfall of ONE cell log, printed as a single
# integer: how many derived checks this cell did not follow through. [repo_dir] threads straight through to
# the citation detectors (#2225/#2227); omit it to fall back to the citation-shape check alone.
#
# HOW A TRACE IS MATCHED TO ITS OPCHECK — #2223 replaced the count proxy with per-check pairing, and which
# rule decided is on the record (`untraced_rule` in the cell object, _untraced_rule above):
#   * `id` rule (the contract as it now ships): the cell numbered its checks, so untraced = OPCHECK ids with
#     no TRACE line of the same id, PLUS the ids whose TRACE closed CLEAN on an uncited dismissal
#     (_uncited_check_ids), PLUS any DISTINCT OPCHECK line the cell left un-numbered (it can be paired with
#     nothing). Text is never compared: a paraphrase cannot break the pairing, and N unrelated TRACE lines
#     cannot discharge N checks — the #2222 QA counter-example, which the count rule accepted.
#   * `count` rule (fallback, ONLY for a cell whose OPCHECK lines carry no id at all — an older transcript,
#     or a model that ignored the numbering): the pre-#2223 arithmetic, byte for byte — (distinct OPCHECK) -
#     (distinct TRACE), floored at 0, plus the uncited-dismissal count. `sort -u` on both sides is what keeps
#     it honest in either direction: a repeated check cannot inflate the requirement and a pasted trace line
#     cannot discharge N checks with one line.
# Whether a TRACE's evidence really settles its check stays an OPERATOR read (the #2214 anti-Goodhart rule),
# not something this shell pretends to decide.
#
# Prints 0 when the log carries no `OPCHECK|` line at all — which is EVERY cell whenever OPERATIONALIZE_LENS
# is off (the production default), so the gate is inert there rather than merely cheap.
_opcheck_trace_gap() {
  otg_log="$1"
  otg_repo="${2:-}"
  otg_cache="${3:-}"
  if [ ! -f "$otg_log" ]; then printf '0\n'; return 0; fi
  if [ "$(_untraced_rule "$otg_log")" = "id" ]; then
    otg_mis="$(_missing_check_ids "$otg_log" | _count_stdin)"
    otg_unnum="$(_unnumbered_opchecks "$otg_log")"
    otg_unc="$(_uncited_check_ids "$otg_log" "$otg_repo" "$otg_cache" | _count_stdin)"
    printf '%s\n' "$((otg_mis + otg_unnum + otg_unc))"
    return 0
  fi
  otg_op="$(_distinct_sentinel_count OPCHECK "$otg_log")"
  otg_tr="$(_distinct_sentinel_count TRACE "$otg_log")"
  otg_gap=0
  if [ "$otg_op" -gt "$otg_tr" ]; then otg_gap=$((otg_op - otg_tr)); fi
  # #2214 PR C: a check traced to an UNCITED dismissal was not followed through either — it was closed on an
  # unchecked scope heuristic or an unverified external fact — so it is added to the SAME shortfall and rides
  # the SAME gate. No new status vocabulary.
  otg_unc="$(_uncited_dismissals "$otg_log" "$otg_repo" "$otg_cache")"
  printf '%s\n' "$((otg_gap + otg_unc))"
}

# _shortfall_id_list <log> [repo_dir] [cache_dir] — #2223: the checks the re-ask must name, as `#2, #5` (untraced first,
# then the uncited ones, each id once, ascending). Empty when the cell is under the count rule, which cannot
# name a check — there the re-ask stays the pre-#2223 verbatim replay.
_shortfall_id_list() {
  sil_log="$1"; sil_repo="${2:-}"; sil_cache="${3:-}"
  [ -f "$sil_log" ] || return 0
  [ "$(_untraced_rule "$sil_log")" = "id" ] || return 0
  sil_out=""
  for sil_id in $( { _missing_check_ids "$sil_log"; _uncited_check_ids "$sil_log" "$sil_repo" "$sil_cache"; } | sort -n -u ); do
    if [ -z "$sil_out" ]; then sil_out="#$sil_id"; else sil_out="$sil_out, #$sil_id"; fi
  done
  printf '%s\n' "$sil_out"
}

# _all_checks_untraced <log> — #2223: true only when the cell answered NOTHING it derived — every OPCHECK id
# is missing a TRACE of that id (id rule), or the cell wrote OPCHECK lines and not a single TRACE line (count
# rule). This is the ONLY shape that still fails a cell wholesale (the #2213 shape: 5-12 checks derived, zero
# traced, verdict SAFE). A PARTIAL shortfall is recorded per check instead — see the status semantics in the
# header — because a cell that answered most of its checks, and carried one honestly as UNRESOLVED, is not
# the same thing as a cell that abandoned the method (the #2214 M3 dismissal r1 C23 loss).
_all_checks_untraced() {
  acu_log="$1"
  [ -f "$acu_log" ] || return 1
  if [ "$(_untraced_rule "$acu_log")" = "id" ]; then
    acu_ids="$(_check_ids OPCHECK "$acu_log" | _count_stdin)"
    [ "$acu_ids" -gt 0 ] || return 1
    [ "$(_missing_check_ids "$acu_log" | _count_stdin)" -eq "$acu_ids" ]
    return $?
  fi
  acu_op="$(_distinct_sentinel_count OPCHECK "$acu_log")"
  [ "$acu_op" -gt 0 ] || return 1
  [ "$(_distinct_sentinel_count TRACE "$acu_log")" -eq 0 ]
}

# _untraced_safe <log> [repo_dir] [cache_dir] — true when <log> is the exact thing the gate exists to refuse: a
# directive-ON cell that answered with NO candidate while at least one derived check went unanswered (untraced
# or closed on an uncited dismissal). #2223: this is the RE-ASK predicate — it fires on a shortfall of ONE
# check, because that is the cheapest moment to recover it — and it is NOT, by itself, the FAILED predicate:
# only _all_checks_untraced still fails a cell wholesale. Four guards, in order:
#   * a #1707 chrome miss / #1955 terminal timeout already OWNS this cell's FAILED reason (and scrape_cell_log
#     checks those markers first), so re-asking it here would spend a call on a cell that never answered;
#   * no `OPERATIONALIZE|` sentinel => the lens was off for this cell => nothing to gate;
#   * a cell that produced a LEAD is never re-asked (a re-ask could lose it) and never failed — its shortfall
#     is recorded as the `untraced` field by _accumulate_cell instead;
#   * finally the arithmetic itself. [repo_dir] threads straight through to _opcheck_trace_gap (#2225).
_untraced_safe() {
  us_log="$1"
  us_repo="${2:-}"
  us_cache="${3:-}"
  if [ ! -f "$us_log" ]; then return 1; fi
  if [ -f "$us_log.novalid" ] || [ -f "$us_log.timeout" ]; then return 1; fi
  if ! grep -qE '^[[:space:]]*OPERATIONALIZE\|' "$us_log" 2>/dev/null; then return 1; fi
  if grep -v '^BLACKBOARD-' "$us_log" 2>/dev/null | grep -q 'CANDIDATE|'; then return 1; fi
  [ "$(_opcheck_trace_gap "$us_log" "$us_repo" "$us_cache")" -gt 0 ]
}

# --- #2245 iteration 2: THE DISMISSAL-GROUND GATE ----------------------------------------------------------
# The measured gap (iteration 1, three runs on the frozen base): 3 of 3 runs REACHED the ground-truth mechanism
# and 0 of 3 KEPT it, and every loss applied one criterion — "no unprivileged attacker gain and no funds locked
# => not a bug" — at the hunter's SAFE or at the refute gate's REFUTED. hunter.ag now carries the contest
# severity rubric + a CLOSED ground list and must write one `DISMISS|<file:function[:line]>|<ground-id>|
# <evidence>` line per lead it matched and did not report (SEVERITY_RUBRIC=1 only). This is the OUTPUT half:
# prompt text is not a gate (the #2213 lesson), so the grounds are checked HERE.
#
# Everything below is INERT by construction when the knob is off: `_rubric_dismissal_gap` returns 0 unless the
# log carries the honesty-gated `SEVERITY-RUBRIC|` sentinel, exactly like `_opcheck_trace_gap` returns 0 for a
# log with no `OPCHECK|` line. No sentinel, no gate, no re-ask, no promotion, no extra JSON key.

# _rubric_sufficient_grounds — the CLOSED list of ground ids a dismissal may stand on, as one space-separated
# line. It is the shell twin of the list inside hunter.ag/refuter.ag's severity_rubric_block(), and the ONE
# decider this gate uses: a ground that is not on this list is insufficient, which is exactly the rubric's
# "a missing, empty or unrecognised ground id counts as INSUFFICIENT" rule — so the four INSUFFICIENT ids need
# no second list here and cannot drift out of sync with one. run-refute.sh declares a byte-identical function
# (demo-severity-rubric.sh diffs the two, and both against the prompt text).
_rubric_sufficient_grounds() {
  printf '%s\n' 'guard unreachable no-loss known-issue immaterial-quantified'
}

# _dismiss_lines <log> — the DISTINCT, whitespace-trimmed `DISMISS|` records of one cell log, one per output
# line, with any PTY prefix ahead of the token stripped. Leading-whitespace tolerant and `sort -u`-normalised
# exactly like _distinct_trace_lines, because `DISMISS|` is MODEL-emitted free text and a PTY capture routinely
# indents (and occasionally prefixes) it. `sort -u` is what keeps a repeated dismissal from inflating the gap.
_dismiss_lines() {
  dl_log="$1"
  [ -f "$dl_log" ] || return 0
  grep -E '^[[:space:]]*DISMISS\|' "$dl_log" 2>/dev/null \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u | grep . || true
}

# _dismiss_ground <line> — field 3 of a `DISMISS|` record, trimmed and lowercased. Empty for a malformed line,
# which the rubric already treats as insufficient, so no separate malformed branch is needed anywhere.
_dismiss_ground() {
  printf '%s' "$1" | cut -d'|' -f3 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]'
}

# _insufficient_dismissal_rows <log> — one `<location>\t<ground-id>\t<evidence>` row per location whose DISMISS
# lines carry ONLY insufficient or unrecognised grounds, in the NORMALISED record order (_dismiss_lines applies
# `sort -u`, so the order is lexicographic rather than log order — deterministic, which is what the re-ask
# addressing and the promotion both need). The UNION rule of the rubric
# is implemented here and is the whole point of grouping by LOCATION rather than by line: the measured loss
# stacked THREE insufficient grounds on one lead, so any number of them still leaves the location open, while a
# single SUFFICIENT ground on that same location closes it. The row keeps the FIRST insufficient line's ground
# and evidence, which is what the re-ask names and what a promoted candidate carries.
_insufficient_dismissal_rows() {
  idr_log="$1"
  [ -f "$idr_log" ] || return 0
  _dismiss_lines "$idr_log" | awk -F'|' -v suff="$(_rubric_sufficient_grounds)" '
    BEGIN { n = split(suff, a, " "); for (i = 1; i <= n; i++) S[a[i]] = 1 }
    {
      loc = $2; g = tolower($3); ev = $4
      sub(/^[[:space:]]+/, "", loc); sub(/[[:space:]]+$/, "", loc)
      sub(/^[[:space:]]+/, "", g);   sub(/[[:space:]]+$/, "", g)
      sub(/^[[:space:]]+/, "", ev);  sub(/[[:space:]]+$/, "", ev)
      if (loc == "") next
      if (!(loc in seen)) { seen[loc] = 1; order[++k] = loc }
      if (g in S) { ok[loc] = 1; next }
      if (!(loc in ground)) { ground[loc] = g; evid[loc] = ev }
    }
    END { for (i = 1; i <= k; i++) if (!(order[i] in ok)) print order[i] "\t" ground[order[i]] "\t" evid[order[i]] }
  '
}

# _insufficient_dismissal_locs <log> — just the locations of the rows above (the gate reads this, the promotion
# reads the rows).
_insufficient_dismissal_locs() {
  _insufficient_dismissal_rows "$1" | cut -f1
}

# _rubric_dismissal_gap <log> — the ground shortfall of ONE cell log as a single integer: how many DISTINCT
# locations this cell dismissed without a sufficient ground. Prints 0 when the log carries no
# `SEVERITY-RUBRIC|` sentinel — which is EVERY cell whenever SEVERITY_RUBRIC is off (the production default) —
# so the gate is inert there by construction rather than merely cheap, the same contract as _opcheck_trace_gap.
# Whether a SUFFICIENT ground's cited evidence really settles the lead stays an OPERATOR read (the #2214
# anti-Goodhart rule): this shell decides only whether a ground id is on the closed list.
_rubric_dismissal_gap() {
  rdg_log="$1"
  if [ ! -f "$rdg_log" ]; then printf '0\n'; return 0; fi
  if ! grep -qE '^[[:space:]]*SEVERITY-RUBRIC\|' "$rdg_log" 2>/dev/null; then printf '0\n'; return 0; fi
  rdg_n="$(_insufficient_dismissal_locs "$rdg_log" | grep -c . || true)"
  case "$rdg_n" in ''|*[!0-9]*) rdg_n=0 ;; esac
  printf '%s\n' "$rdg_n"
}

# _rubric_reask_needed <log> — the RE-ASK predicate, with the same four guards as _untraced_safe and in the
# same order:
#   * a #1707 chrome miss / #1955 terminal timeout already OWNS this cell's FAILED reason, so re-asking it
#     would spend a call on a cell that never answered;
#   * no `SEVERITY-RUBRIC|` sentinel => the rubric was off for this cell => nothing to gate;
#   * a cell that produced a LEAD is never re-asked (a re-ask could lose it) — and its dismissals are still
#     recorded per cell by _accumulate_cell;
#   * finally the arithmetic itself.
# RE-ASK SAFETY is #1707's argument unchanged: a cell with no `CANDIDATE|` posted nothing to the blackboard and
# emit()ed no lead, so a re-ask cannot double-post.
_rubric_reask_needed() {
  rrn_log="$1"
  if [ ! -f "$rrn_log" ]; then return 1; fi
  if [ -f "$rrn_log.novalid" ] || [ -f "$rrn_log.timeout" ]; then return 1; fi
  if ! grep -qE '^[[:space:]]*SEVERITY-RUBRIC\|' "$rrn_log" 2>/dev/null; then return 1; fi
  if grep -v '^BLACKBOARD-' "$rrn_log" 2>/dev/null | grep -q 'CANDIDATE|'; then return 1; fi
  [ "$(_rubric_dismissal_gap "$rrn_log")" -gt 0 ]
}

# _rubric_open_grounds <log> — the open locations the re-ask must name, as `<loc> (<ground>), <loc> (<ground>)`.
# Empty when there are none. It names only what the CELL ITSELF wrote down, so nothing of this harness's own
# judgement enters the prompt.
_rubric_open_grounds() {
  rog_out=""
  while IFS='	' read -r rog_loc rog_g; do
    [ -n "$rog_loc" ] || continue
    rog_one="$rog_loc (${rog_g:-no ground given})"
    if [ -z "$rog_out" ]; then rog_out="$rog_one"; else rog_out="$rog_out, $rog_one"; fi
  done <<EOF
$(_insufficient_dismissal_rows "$1" | cut -f1,2)
EOF
  printf '%s\n' "$rog_out"
}

# _rubric_promote <log> <class> <files> — the PROMOTION half of the gate (issue #2245 STOP-1 decision 2): when a
# location's dismissal is STILL insufficient after the bounded re-ask, synthesise a TIER-1 candidate for it into
# "<log>.rubric-promoted" — one `RUBRIC-PROMOTED|<loc>|<ground-id>` provenance line followed by one
# `CANDIDATE|<loc>|class=<cls>|Medium|<the cell's own evidence>|<PoC sketch>` line.
#
# WHY TIER 1 AND NOT A TIER-2 RECORD: verify-findings.sh puts tier-2 verdicts in a separate top-level `tier2[]`
# array and NEVER in `verified[]`, so a tier-2 record cannot reach verified_findings.json by construction — the
# pre-registered measurement for this iteration would be unreadable. Precision is held by the gates that stay
# live: a promoted lead is still judged by the refute gate and still needs a PASSING PoC before it is a finding,
# it is capped at `Medium`, it fires at most ONCE per location, and it exists only because the MODEL wrote a
# `DISMISS|` line naming a location that RESOLVES inside this cell's own file list (_tier2_resolve_file +
# _tier2_emit_loc, the shipped validators — an unresolvable location is DROPPED, never guessed).
#
# The cell LOG is never written to: it stays a pure model transcript, and the sidecar's suffix deliberately does
# not end in `.log` so `find -name 'hunt_*.log'` readouts and the hunt dashboard keep seeing one log per cell.
# ACCEPTED ASYMMETRY, documented rather than hidden: a promoted candidate is NOT posted to the #1001 blackboard
# — hunter.ag posts only what the model itself emitted — so it does not steer later cells.
_rubric_promote() {
  rp_log="$1"; rp_cls="$2"; rp_files="$(printf '%s' "$3" | tr '\n' ',')"
  [ -f "$rp_log" ] || return 0
  rp_out="$rp_log.rubric-promoted"
  rm -f "$rp_out"
  while IFS='	' read -r rp_loc rp_ground rp_ev; do
    [ -n "$rp_loc" ] || continue
    # `file:function[:line]` -> the basename and the function half; an optional `:line` tail is dropped
    # (_tier2_emit_loc pins exactly `<path>.sol:<function>`, which is what score-match.py can parse).
    case "$rp_loc" in *:*) ;; *) continue ;; esac
    rp_base="${rp_loc%%:*}"; rp_base="${rp_base##*/}"
    rp_fn="${rp_loc#*:}"; rp_fn="${rp_fn%%:*}"
    [ -n "$rp_base" ] && [ -n "$rp_fn" ] || continue
    rp_path="$(_tier2_resolve_file "$rp_base" "$rp_files")"
    [ -n "$rp_path" ] || continue
    rp_row="$(_tier2_emit_loc "$rp_path:$rp_fn" rubric dismissal || true)"
    [ -n "$rp_row" ] || continue
    rp_final="${rp_row%%	*}"
    # A `|` inside the model's evidence would add a field to the candidate record every downstream reader
    # splits on, so it is mapped to `/` exactly like run-refute.sh's _clean_reason does for a verdict reason.
    rp_ev_clean="$(printf '%s' "$rp_ev" | tr '|' '/' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//')"
    [ -n "$rp_ev_clean" ] || rp_ev_clean="dismissed on the insufficient ground '$rp_ground' with no evidence given"
    printf 'RUBRIC-PROMOTED|%s|%s\n' "$rp_final" "$rp_ground" >> "$rp_out"
    printf 'CANDIDATE|%s|class=%s|Medium|%s|PoC sketch: reproduce the admitted state, call the documented path, and assert the revert or the value delta\n' \
      "$rp_final" "$rp_cls" "$rp_ev_clean" >> "$rp_out"
  done <<EOF
$(_insufficient_dismissal_rows "$rp_log")
EOF
}

# _rubric_promoted_candidates <log> — the promoted `CANDIDATE|` records of one cell, or nothing. This is the ONE
# reader through which a shell-promoted lead enters the pipeline; _cell_candidates below unions it with the
# model-emitted records at both scrape sites, so a promoted lead reaches $REPORT, `candidates[]`, the depth plan
# and the refute gate exactly like a model-emitted one.
_rubric_promoted_candidates() {
  rpc_log="$1"
  [ -s "$rpc_log.rubric-promoted" ] || return 0
  grep -E '^CANDIDATE\|' "$rpc_log.rubric-promoted" 2>/dev/null || true
}

# _rubric_promoted_count <log> — how many locations this cell's gate promoted (0 without the sidecar).
_rubric_promoted_count() {
  rpn_log="$1"
  rpn_n="$(grep -cE '^RUBRIC-PROMOTED\|' "$rpn_log.rubric-promoted" 2>/dev/null || true)"
  case "$rpn_n" in ''|*[!0-9]*) rpn_n=0 ;; esac
  printf '%s\n' "$rpn_n"
}

# _cell_candidates <log> — every candidate record of one cell: the model-emitted (PTY-unwrapped) ones first,
# then the #2245 promoted ones. Both scrape sites call THIS, so the two paths cannot disagree about what a cell
# produced. With the knob off the second half emits nothing and the output is byte-identical to
# _join_wrapped_candidates alone.
_cell_candidates() {
  _join_wrapped_candidates "$1" 2>/dev/null || true
  _rubric_promoted_candidates "$1"
}

# _accumulate_cell <subsys> <cls> <files> <log> [status] [phase] — append ONE JSON object for this cell to
# $CELLS_JSONL (additive; feeds discovery-results.json). Never touches $REPORT. [status] defaults to "ok";
# a #1707 no-sentinel-after-retries cell is recorded as "failed" so the JSON distinguishes it from a clean
# (0-candidate) negative. [phase] (#1827) is "depth" ONLY on a depth cell — a breadth cell's object gains no
# key at all, so the depth-off JSON is byte-identical to the pre-#1827 one.
# #1865: `appendix` is derived from the LOG (the hunter's own APPENDIX-CONTEXT| sentinel), not from a new
# parameter — the same idiom as `coordination` below, and it records what the AGENT actually framed rather
# than what the shell intended to stage. It is appended LAST in the printf, after `phase`, so
# _plan_depth_cells's forward key scan (subsystem -> class -> files -> status -> candidates) is untouched and
# a cell with no appendix keeps its exact key set.
# #2211: `opchecks` is derived from the LOG the same way (the model's own OPCHECK| lines) and appended LAST,
# after `appendix`, for the same reason — it is the #2211 M2 A/B's cheap per-cell dosage metric, and a cell
# that emitted none keeps its exact key set.
# #2214: `traces` (distinct TRACE| lines) and `untraced` (the follow-through shortfall) follow it, LAST and
# again only when non-zero — so a directive-OFF cell's key set stays byte-identical to the pre-#2214 one and
# _plan_depth_cells's forward key scan is untouched. `untraced` is what puts a shortfall on the record for a
# cell that DID produce candidates: such a cell is scraped and reported normally (never re-asked, never
# failed), so this field is the only place its abandoned checks are visible to the readout.
# #2214 PR C: `unresolved` (distinct checks traced UNRESOLVED) follows them, LAST and again only when
# non-zero. An UNRESOLVED check is the honest verdict the citation rules ask for, and this counter is what
# stops it from folding silently into a clean-looking negative.
# #2223: `untraced_rule` (`id`|`count`, absent when the cell wrote no OPCHECK line), `trace_orphans` (TRACE
# ids naming no check of this cell, non-zero only) and the per-check breakdown `untraced_ids` / `uncited_ids` /
# `unresolved_ids` (each `[{"id":N,"check":"..."}]` for the last one) follow them, LAST and only when
# non-empty. They are what makes a PARTIAL shortfall readable without the cell log: an `ok` cell can now say
# WHICH checks it left open, and an UNRESOLVED carry survives with the check's own text for #2217 to consume.
_accumulate_cell() {
  ac_subsys="$1"; ac_cls="$2"; ac_files="$3"; ac_log="$4"; ac_status="${5:-ok}"; ac_phase="${6:-}"
  ac_phase_json=""
  if [ "$ac_phase" = "depth" ]; then ac_phase_json=',"phase":"depth"'; fi
  ac_cands=""
  while IFS= read -r ac_line; do
    [ -n "$ac_line" ] || continue
    ac_c="$(printf '%s' "$ac_line" | sed 's/^.*\(CANDIDATE|\)/\1/; s/^CANDIDATE|//')"
    ac_c="$(_json_str "$ac_c")"
    if [ -z "$ac_cands" ]; then ac_cands="$ac_c"; else ac_cands="$ac_cands,$ac_c"; fi
  done < <(_cell_candidates "$ac_log" 2>/dev/null || true)
  ac_coord=""
  if grep -q '^BLACKBOARD-FOCUS|' "$ac_log" 2>/dev/null; then
    ac_f="$(grep '^BLACKBOARD-FOCUS|' "$ac_log" | head -1 | sed 's/^BLACKBOARD-FOCUS|//')"
    ac_coord="$(_json_str "$ac_f")"
  fi
  ac_appendix_json=""
  if grep -q '^APPENDIX-CONTEXT|' "$ac_log" 2>/dev/null; then
    ac_a="$(grep '^APPENDIX-CONTEXT|' "$ac_log" | head -1 | sed 's/^APPENDIX-CONTEXT|//')"
    ac_appendix_json=",\"appendix\":$(_json_str "$ac_a")"
  fi
  ac_opchecks_json=""
  # Leading-whitespace tolerant like the boundary predicate above: OPCHECK| lines are MODEL-emitted, so a PTY
  # capture can indent them, and an anchored '^OPCHECK|' would silently undercount the dosage metric.
  ac_opn="$(grep -cE '^[[:space:]]*OPCHECK\|' "$ac_log" 2>/dev/null || true)"
  case "$ac_opn" in ''|*[!0-9]*) ac_opn=0 ;; esac
  if [ "$ac_opn" -gt 0 ]; then ac_opchecks_json=",\"opchecks\":$ac_opn"; fi
  ac_traces_json=""
  ac_trn="$(_distinct_sentinel_count TRACE "$ac_log")"
  if [ "$ac_trn" -gt 0 ]; then ac_traces_json=",\"traces\":$ac_trn"; fi
  ac_untraced_json=""
  ac_un="$(_opcheck_trace_gap "$ac_log" "$REPO" "$EXTERNAL_CACHE")"
  if [ "$ac_un" -gt 0 ]; then ac_untraced_json=",\"untraced\":$ac_un"; fi
  ac_unresolved_json=""
  ac_unres="$(_unresolved_trace_count "$ac_log")"
  if [ "$ac_unres" -gt 0 ]; then ac_unresolved_json=",\"unresolved\":$ac_unres"; fi
  # #2223: which pairing rule decided this cell, the orphan count, and the PER-CHECK breakdown. All five keys
  # follow the same discipline as every additive field above — appended LAST, emitted only when they carry
  # something — so a lens-OFF cell (no OPCHECK line => no rule, no ids) keeps its exact pre-#2223 key set and
  # _plan_depth_cells's forward key scan is untouched.
  ac_rule_json=""
  ac_rule="$(_untraced_rule "$ac_log")"
  if [ -n "$ac_rule" ]; then ac_rule_json=",\"untraced_rule\":\"$ac_rule\""; fi
  ac_orphans_json=""
  ac_orph="$(_orphan_trace_ids "$ac_log" | _count_stdin)"
  if [ "$ac_orph" -gt 0 ]; then ac_orphans_json=",\"trace_orphans\":$ac_orph"; fi
  ac_untraced_ids_json=""
  ac_untraced_ids="$(_missing_check_ids "$ac_log" | _json_id_array)"
  if [ -n "$ac_untraced_ids" ]; then ac_untraced_ids_json=",\"untraced_ids\":[$ac_untraced_ids]"; fi
  ac_uncited_ids_json=""
  ac_uncited_ids="$(_uncited_check_ids "$ac_log" "$REPO" "$EXTERNAL_CACHE" | _json_id_array)"
  if [ -n "$ac_uncited_ids" ]; then ac_uncited_ids_json=",\"uncited_ids\":[$ac_uncited_ids]"; fi
  # The UNRESOLVED carry, with the check's own text: this is the row #2217 consumes to turn an honest "I could
  # not settle this" on a rare-class check into a second-tier candidate instead of a silent clean sweep.
  ac_unresolved_ids_json=""
  ac_unresolved_ids=""
  while IFS='	' read -r ac_ur_id ac_ur_txt; do
    [ -n "$ac_ur_id" ] || continue
    ac_ur_obj="{\"id\":$ac_ur_id,\"check\":$(_json_str "$ac_ur_txt")}"
    if [ -z "$ac_unresolved_ids" ]; then ac_unresolved_ids="$ac_ur_obj"; else ac_unresolved_ids="$ac_unresolved_ids,$ac_ur_obj"; fi
  done < <(_unresolved_check_ids "$ac_log" 2>/dev/null || true)
  if [ -n "$ac_unresolved_ids" ]; then ac_unresolved_ids_json=",\"unresolved_ids\":[$ac_unresolved_ids]"; fi
  # #2245 iteration 2: the dismissal dosage + the gate's two outcomes. Appended LAST, after every #2223 key, and
  # ONLY when non-zero — so a rubric-OFF cell (no DISMISS| line, no sentinel => all three are 0) keeps its exact
  # pre-#2245 key set and _plan_depth_cells's forward key scan (subsystem -> class -> files -> status ->
  # candidates) is untouched. `dismissals` is the compliance-dosage metric the arm readout needs: a SAFE reply
  # with zero DISMISS lines is non-compliance, and an output gate cannot see a lead that was never written down.
  ac_dismissals_json=""
  ac_dis="$(_dismiss_lines "$ac_log" | grep -c . || true)"
  case "$ac_dis" in ''|*[!0-9]*) ac_dis=0 ;; esac
  if [ "$ac_dis" -gt 0 ]; then ac_dismissals_json=",\"dismissals\":$ac_dis"; fi
  ac_insuff_json=""
  ac_insuff="$(_rubric_dismissal_gap "$ac_log")"
  if [ "$ac_insuff" -gt 0 ]; then ac_insuff_json=",\"insufficient_dismissals\":$ac_insuff"; fi
  ac_promoted_json=""
  ac_prom="$(_rubric_promoted_count "$ac_log")"
  if [ "$ac_prom" -gt 0 ]; then ac_promoted_json=",\"rubric_promoted\":$ac_prom"; fi
  printf '{"subsystem":%s,"class":%s,"files":%s,"status":%s,"candidates":[%s],"coordination":[%s]%s%s%s%s%s%s%s%s%s%s%s%s%s%s}\n' \
    "$(_json_str "$ac_subsys")" "$(_json_str "$ac_cls")" "$(_json_str "$ac_files")" \
    "$(_json_str "$ac_status")" "$ac_cands" "$ac_coord" "$ac_phase_json" "$ac_appendix_json" \
    "$ac_opchecks_json" "$ac_traces_json" "$ac_untraced_json" "$ac_unresolved_json" \
    "$ac_rule_json" "$ac_orphans_json" "$ac_untraced_ids_json" "$ac_uncited_ids_json" "$ac_unresolved_ids_json" \
    "$ac_dismissals_json" "$ac_insuff_json" "$ac_promoted_json" >> "$CELLS_JSONL"
  # #2217: the tier-2 carry, appended to the RUN-scoped accumulator AFTER the cell object is written and
  # gated on the feature flag — so an OFF run does no extra work, writes no extra file, and emits the same
  # bytes it did before #2217. _accumulate_cell is called in MANIFEST order on the serial, parallel
  # (post-drain) and depth paths alike, which is what makes this file's order the cap's last tie-break.
  if [ "$TIER2" -eq 1 ]; then
    _tier2_records "$ac_subsys" "$ac_cls" "$ac_files" "$ac_log" "$REPO" "$EXTERNAL_CACHE" >> "$TIER2_TSV"
  fi
}

# _appendix_for <subsystem> <files_csv> — #1865: the (token, base) pair the --appendix sidecar records for
# THIS manifest line, printed as `<token>\t<base>`, or nothing. Two guards make the sidecar advisory-and-safe:
#   * no --appendix (or no row for this subsystem) => nothing, i.e. the framing is simply off for this cell;
#   * SELF-CHECK: the row is used only when its token literally appears in this line's FILES_CSV. map-zones.sh
#     keys scope.tsv lines on clean(name) with no dedup, so a subsystem name can match SEVERAL manifest lines
#     (the ambiguity run-zone-hunt.sh already documents at its per-zone cap probe). Framing a line that does
#     not carry the token would tell the hunter its contract is abstract about a payload that has no
#     appendix section at all — the check makes that impossible.
_appendix_for() {
  [ -n "$APPENDIX_TSV" ] || return 0
  af_row="$(awk -F'	' -v s="$1" '$1 == s { print $2 "	" $3; exit }' "$APPENDIX_TSV" 2>/dev/null || true)"
  [ -n "$af_row" ] || return 0
  af_tok="${af_row%%	*}"
  [ -n "$af_tok" ] || return 0
  case ",$2," in
    *",$af_tok,"*) printf '%s\n' "$af_row" ;;
  esac
}

# run_cell <dir> <subsys> <cls> <in_scope> <log> [depth_target] [depth_known] [appendix_file] [appendix_base]
# — invoke the hunter for ONE
# (subsystem x class) cell into <log>. Serial passes dir=$RUN (the shared store); parallel passes an isolated
# per-cell store. Never trips set -e (the invocation ends `|| echo …`), so a failed cell degrades (its log is
# still scraped), not aborts. #1827: the two trailing params are EMPTY on every breadth cell (the hunter's
# depth block is then "" and its prompt is byte-identical); a depth cell passes the `file@fn` under review and
# the already-known lead(s) that must not be re-reported.
# #1865: params 8/9 carry the appendix pair for a BREADTH cell whose payload holds the derived implementor.
# They are EMPTY on every depth cell by construction: a depth payload IS the narrowed function, so framing it
# as "your contract is abstract, the last section implements it" would be a lie about that payload.
run_cell() {
  rc_dir="$1"; rc_subsys="$2"; rc_cls="$3"; rc_in_scope="$4"; rc_log="$5"
  rc_depth_target="${6:-}"; rc_depth_known="${7:-}"
  rc_appendix_file="${8:-}"; rc_appendix_base="${9:-}"
  # #2223: the ids the follow-through re-ask must name. EMPTY on the first attempt (and on every count-rule
  # cell), so the first prompt — and every lens-OFF prompt — is byte-identical to the pre-#2223 one.
  rc_reask_ids=""
  # #2245 iteration 2: the open dismissal locations the GROUND re-ask must name. EMPTY on the first attempt (and
  # on every rubric-OFF cell), so the first prompt — and every rubric-OFF prompt — is byte-identical to the
  # pre-#2245 one.
  rc_dismiss_grounds=""
  # #2235: one budget-state file per CELL, named after this cell's log so the two can never disagree about
  # which cell they belong to. "" when --external-resolve is off, which makes all four env entries below empty
  # and hunter.ag's directive exactly "". The file is NOT reset between re-asks: a re-ask is the same cell, so
  # it keeps spending the same cell's budget rather than being handed a fresh one.
  rc_ext_state=""
  if [ -n "$EXTERNAL_BUDGET_DIR" ]; then
    rc_ext_base="${rc_log##*/}"
    rc_ext_state="$EXTERNAL_BUDGET_DIR/${rc_ext_base%.log}"
  fi
  # #2235 PR C: the same per-cell bookkeeping for the on-chain CALL budget, in its own file so the two verbs
  # cannot spend each other's bound. It also memoises this cell's pinned block (onchain-fact.sh writes a
  # `<state>.block-<chain>` sibling), which is what keeps every call of a cell on ONE cache key.
  rc_oc_state=""
  if [ -n "$ONCHAIN_BUDGET_DIR" ]; then
    rc_oc_base="${rc_log##*/}"
    rc_oc_state="$ONCHAIN_BUDGET_DIR/${rc_oc_base%.log}"
  fi
  echo "run-discovery.sh: hunting $rc_cls on '$rc_subsys' ..." >&2
  # shellcheck disable=SC2317  # invoked by name through df_run_agent_validated
  _rc_attempt() {
    ( cd "$rc_dir" && env \
        TARGET_DIR="$REPO" \
        IN_SCOPE="$rc_in_scope" \
        SCOPE_BRIEF="$BRIEF" \
        TAXONOMY="$TAXONOMY" \
        HUNT_CLASS="$rc_cls" \
        SUBSYSTEM="$rc_subsys" \
        SLICER="$rc_dir/slice-fns.sh" \
        DEPTH_TARGET="$rc_depth_target" \
        DEPTH_KNOWN="$rc_depth_known" \
        APPENDIX_FILE="$rc_appendix_file" \
        APPENDIX_BASE="$rc_appendix_base" \
        TRACE_REASK_IDS="$rc_reask_ids" \
        SEVERITY_RUBRIC="${SEVERITY_RUBRIC:-}" \
        DISMISS_REASK_GROUNDS="$rc_dismiss_grounds" \
        EXTERNAL_RESOLVER="${EXTERNAL_RESOLVER:+$rc_dir/resolve-external.sh}" \
        EXTERNAL_CACHE="$EXTERNAL_CACHE" \
        EXTERNAL_BUDGET_STATE="$rc_ext_state" \
        EXTERNAL_BUDGET="$EXTERNAL_BUDGET" \
        ONCHAIN_FACT="${ONCHAIN_FACT:+$rc_dir/onchain-fact.sh}" \
        ONCHAIN_BUDGET_STATE="$rc_oc_state" \
        ONCHAIN_BUDGET="$ONCHAIN_BUDGET" \
        FORK_URL="$FORK_URL" \
        FORK_BLOCK="$FORK_BLOCK" \
        "$AGENTIS" go hunter.ag --enable-exec --enable-messaging --grant-pii ) >"$1" 2>&1 || \
        echo "run-discovery.sh: hunter run failed for $rc_cls/'$rc_subsys' (see $1)" >&2
  }
  # #1707: validate the hunter reply carries a CANDIDATE|/SAFE sentinel and RETRY on TUI chrome / no answer,
  # instead of scraping an empty log as a rigorous negative. The retry lives INSIDE run_cell (called by both
  # the serial and parallel paths) and failure is signalled via a "$rc_log.novalid" MARKER FILE, not an exit
  # code — a backgrounded `run_cell &` loses its return across `wait -n`, but the marker survives for the
  # deferred manifest-order aggregation in scrape_cell_log. Never trips set -e (|| true).
  df_run_agent_validated "$DF_AGENT_MAX_ATTEMPTS" "run-discovery.sh: $rc_cls/'$rc_subsys'" "$rc_log" hunter "" _rc_attempt || true
  # #2214 Lever 1 — GATE ON OUTPUT. A reply that carries the #2211 sentinel, no candidate, and fewer distinct
  # TRACE| than OPCHECK| lines is a cell that derived its checks and then abandoned them: NOT a rigorous
  # negative, and never silently trusted. Re-ask the SAME validated attempt up to DF_TRACE_MAX_REASKS times
  # (default 1); if the shortfall survives, drop a "$rc_log.untraced" marker holding the remaining gap, which
  # scrape_cell_log turns into a DISTINCT FAILED row. RE-ASK SAFETY is #1707's argument unchanged: a cell with
  # no CANDIDATE| posted nothing to the blackboard and emit()ed no lead, so a re-ask cannot double-post.
  # The superseded attempt is kept as "$rc_log.untraced-attempt-N" — a suffix deliberately NOT ending in
  # `.log`, so `find -name 'hunt_*.log'` readouts and the hunt dashboard keep seeing exactly one log per cell.
  rm -f "$rc_log.untraced"
  rc_reask=1
  while [ "$rc_reask" -le "$DF_TRACE_MAX_REASKS" ] && _untraced_safe "$rc_log" "$REPO" "$EXTERNAL_CACHE"; do
    # #2223: name the checks. The re-ask carries the ids into the prompt (TRACE_REASK_IDS -> hunter.ag's
    # trace_reask_block), so the model is told WHICH checks it left open instead of being handed the same
    # prompt again — the count rule could not name one, which is why the pre-#2223 re-ask was a verbatim
    # replay. Empty for a count-rule cell: there the re-ask stays exactly what it was.
    rc_reask_ids="$(_shortfall_id_list "$rc_log" "$REPO" "$EXTERNAL_CACHE")"
    echo "run-discovery.sh:   ↳ untraced-opcheck: $rc_cls/'$rc_subsys' answered with $(_opcheck_trace_gap "$rc_log" "$REPO" "$EXTERNAL_CACHE") unanswered check(s)${rc_reask_ids:+ ($rc_reask_ids)} — re-asking ($rc_reask/$DF_TRACE_MAX_REASKS)" >&2
    mv -f "$rc_log" "$rc_log.untraced-attempt-$rc_reask" 2>/dev/null || true
    df_run_agent_validated "$DF_AGENT_MAX_ATTEMPTS" "run-discovery.sh: $rc_cls/'$rc_subsys' (trace re-ask $rc_reask)" "$rc_log" hunter "" _rc_attempt || true
    rc_reask=$((rc_reask + 1))
  done
  rc_reask_ids=""
  # #2223: the FAILED marker is written ONLY for a TOTAL shortfall — a cell that answered none of the checks
  # it derived. A cell that answered some of them keeps `status":"ok"` and reports the open ones per check
  # (untraced_ids/uncited_ids), because failing it wholesale discards the checks it DID settle — including a
  # correct UNRESOLVED carry, which is exactly what the #2214 M3 dismissal r1 C23 cell lost.
  if _untraced_safe "$rc_log" "$REPO" "$EXTERNAL_CACHE" && _all_checks_untraced "$rc_log"; then
    _opcheck_trace_gap "$rc_log" "$REPO" "$EXTERNAL_CACHE" > "$rc_log.untraced"
  fi
  # #2245 iteration 2 — THE DISMISSAL-GROUND GATE, a SECOND bounded re-ask with the same shape as the
  # follow-through one above. A reply that carries the rubric sentinel, no candidate, and at least one location
  # dismissed on a ground the closed list treats as INSUFFICIENT is not a rigorous negative: it is the exact
  # shape the iteration-1 forensics measured (the cell wrote the ground-truth mechanism out and then ruled it
  # out on "trusted-owner config / no attacker / another exit remains"). Re-ask up to DF_RUBRIC_MAX_REASKS
  # times (default 1) NAMING the open locations and their grounds; if the shortfall survives, PROMOTE each
  # surviving location to a tier-1 `Medium` candidate (_rubric_promote). Re-ask safety is #1707's argument
  # unchanged: a cell with no CANDIDATE| posted nothing to the blackboard and emit()ed no lead.
  # The superseded attempt is kept as "$rc_log.rubric-attempt-N" — a suffix deliberately NOT ending in `.log`,
  # so `find -name 'hunt_*.log'` readouts and the hunt dashboard keep seeing exactly one log per cell.
  # This gate NEVER fails a cell: a promoted candidate is a normal candidate, and a surviving shortfall with no
  # resolvable location is recorded (insufficient_dismissals) rather than turned into a FAILED row.
  rm -f "$rc_log.rubric-promoted"
  rc_rubric=1
  while [ "$rc_rubric" -le "$DF_RUBRIC_MAX_REASKS" ] && _rubric_reask_needed "$rc_log"; do
    rc_dismiss_grounds="$(_rubric_open_grounds "$rc_log")"
    echo "run-discovery.sh:   ↳ insufficient-dismissal: $rc_cls/'$rc_subsys' dismissed $(_rubric_dismissal_gap "$rc_log") lead(s) on an insufficient ground${rc_dismiss_grounds:+ ($rc_dismiss_grounds)} — re-asking ($rc_rubric/$DF_RUBRIC_MAX_REASKS)" >&2
    mv -f "$rc_log" "$rc_log.rubric-attempt-$rc_rubric" 2>/dev/null || true
    df_run_agent_validated "$DF_AGENT_MAX_ATTEMPTS" "run-discovery.sh: $rc_cls/'$rc_subsys' (ground re-ask $rc_rubric)" "$rc_log" hunter "" _rc_attempt || true
    rc_rubric=$((rc_rubric + 1))
  done
  rc_dismiss_grounds=""
  if _rubric_reask_needed "$rc_log"; then
    _rubric_promote "$rc_log" "$rc_cls" "$rc_in_scope"
  fi
}

# scrape_cell_log <subsys> <cls> <log> <files> [phase] — the (byte-identical) post-cell scrape: surface the
# #1001 BLACKBOARD-FOCUS coordination row (+ $COORD, STEERS), scrape CANDIDATE| rows into $REPORT
# (+ CANDIDATES), and accumulate the cell into the additive JSON. Called in MANIFEST order on both paths
# (deterministic). [phase] (#1827) is "depth" only for a depth cell and is forwarded to _accumulate_cell.
scrape_cell_log() {
  sc_subsys="$1"; sc_cls="$2"; sc_log="$3"; sc_files="$4"; sc_phase="${5:-}"
  # #1707: a cell whose reply never produced a CANDIDATE|/SAFE sentinel after DF_AGENT_MAX_ATTEMPTS retries
  # (TUI chrome / no answer) carries a "$sc_log.novalid" marker. Do NOT treat its empty log as a rigorous
  # negative: surface it as a DISTINCT FAILED row + counter so it is visible, not silently folded into
  # "0 candidates". Recorded as "status":"failed" in the additive JSON.
  # #1955 Lever 1b: a cell whose reply was a genuine `[llm.timeout]` (the per-cell prompt exceeded the scaled
  # timeout budget) carries a "$sc_log.timeout" marker dropped by df_run_agent_validated. Surface it as a
  # DISTINCT FAILED reason BEFORE the generic .novalid branch below — the timeout marker rides alongside
  # .novalid (a timeout IS a no-valid-sentinel failure), so this ordering is what makes it distinguishable
  # from TUI chrome. The JSON "status":"failed" is UNCHANGED (byte-compatible with zone-coverage derivation);
  # the discriminator lives only in the row text + stderr line, and --rehunt-gaps is the recovery path.
  if [ -f "$sc_log.timeout" ]; then
    echo "run-discovery.sh:   ↳ FAILED: $sc_cls/'$sc_subsys' LLM call timed out (per-cell prompt exceeded the timeout budget; re-hunt with --rehunt-gaps)" >&2
    printf '| %s | %s | FAILED — LLM call timed out (per-cell prompt exceeded the timeout budget; re-hunt with --rehunt-gaps) |\n' \
      "$sc_subsys" "$sc_cls" >> "$REPORT"
    FAILED_CELLS=$((FAILED_CELLS + 1))
    _accumulate_cell "$sc_subsys" "$sc_cls" "$sc_files" "$sc_log" failed "$sc_phase"
    return 0
  fi
  if [ -f "$sc_log.novalid" ]; then
    echo "run-discovery.sh:   ↳ FAILED: $sc_cls/'$sc_subsys' produced no CANDIDATE|/SAFE reply after $DF_AGENT_MAX_ATTEMPTS attempts (NOT a rigorous negative)" >&2
    printf '| %s | %s | FAILED — no CANDIDATE|/SAFE reply after %s attempts (NOT a rigorous negative) |\n' \
      "$sc_subsys" "$sc_cls" "$DF_AGENT_MAX_ATTEMPTS" >> "$REPORT"
    FAILED_CELLS=$((FAILED_CELLS + 1))
    _accumulate_cell "$sc_subsys" "$sc_cls" "$sc_files" "$sc_log" failed "$sc_phase"
    return 0
  fi
  # #2214 Lever 1: a cell that answered WITHOUT a candidate while it left derived OPCHECK(s) untraced, and
  # still did so after run_cell's bounded re-ask, carries a "$sc_log.untraced" marker holding the surviving
  # gap. It is a FAILED cell for the SAME reason the two branches above are: it is not a rigorous negative.
  # Placed AFTER them so a chrome/timeout failure keeps its own (more specific) reason, and BEFORE the
  # CANDIDATE scrape because such a cell has no candidate to scrape by construction.
  # The JSON "status":"failed" is deliberately UNCHANGED — byte-compatible with lib/zone-coverage.py's
  # hunted_degraded derivation (exit 0 AND totals.failed > 0), so the zone lands as DEGRADED rather than as a
  # trusted clean sweep, with no new status vocabulary for the dashboard/generation-recall to learn. The
  # discriminator is the `untraced-opcheck` token in the row text + stderr line (the #1955 `.timeout`
  # precedent) and the per-cell `untraced` field in the additive JSON.
  if [ -f "$sc_log.untraced" ]; then
    sc_untr="$(cat "$sc_log.untraced" 2>/dev/null || true)"
    case "$sc_untr" in ''|*[!0-9]*) sc_untr=1 ;; esac
    echo "run-discovery.sh:   ↳ FAILED (untraced-opcheck): $sc_cls/'$sc_subsys' answered SAFE with $sc_untr untraced OPCHECK(s) (NOT a rigorous negative; re-hunt with --rehunt-gaps)" >&2
    printf '| %s | %s | FAILED — untraced-opcheck: SAFE with %s untraced OPCHECK(s) (NOT a rigorous negative) |\n' \
      "$sc_subsys" "$sc_cls" "$sc_untr" >> "$REPORT"
    FAILED_CELLS=$((FAILED_CELLS + 1))
    _accumulate_cell "$sc_subsys" "$sc_cls" "$sc_files" "$sc_log" failed "$sc_phase"
    return 0
  fi
  # #2223: a PARTIAL shortfall — the cell answered some of its checks and left others untraced or closed on an
  # uncited dismissal, after the bounded re-ask. It is recorded `ok` (the answers it DID produce are real
  # results, and the cell may carry a correct UNRESOLVED), so the operator gets the open ids here and the
  # per-check fields in the JSON, not a discarded cell. This is deliberately NOT a FAILED row: only a cell
  # that answered NONE of its checks is not a result at all.
  sc_open_ids="$(_shortfall_id_list "$sc_log" "$REPO" "$EXTERNAL_CACHE")"
  if [ -n "$sc_open_ids" ]; then
    echo "run-discovery.sh:   ↳ $sc_cls/'$sc_subsys' left check(s) $sc_open_ids unanswered after the re-ask (recorded as \"untraced_ids\"/\"uncited_ids\" on an \"ok\" cell; this cell's negative is NOT a rigorous clean sweep)" >&2
  fi
  # #2214 PR C: an UNRESOLVED check never folds silently into SAFE. Such a cell is NOT failed and NOT
  # re-asked — the verdict is the honest one the citation rules ask for — but its negative is not a rigorous
  # clean sweep either, so the count is surfaced to the operator here and recorded as the additive
  # `unresolved` field by _accumulate_cell below.
  sc_unres="$(_unresolved_trace_count "$sc_log")"
  if [ "$sc_unres" -gt 0 ]; then
    echo "run-discovery.sh:   ↳ $sc_unres UNRESOLVED check(s): $sc_cls/'$sc_subsys' could not settle them from its payload (recorded as \"unresolved\"; this cell's negative is NOT a rigorous clean sweep)" >&2
  fi
  # #2245 iteration 2: the dismissal-ground readout. A surviving insufficient dismissal is NOT a failed cell —
  # the gate's answer is the promotion, not a discarded cell — but it is not a rigorous clean sweep either, so
  # both numbers are surfaced here and recorded as the additive `insufficient_dismissals` / `rubric_promoted`
  # fields by _accumulate_cell below. Silent on every rubric-OFF cell (the gap is 0 without the sentinel).
  sc_rubric_gap="$(_rubric_dismissal_gap "$sc_log")"
  if [ "$sc_rubric_gap" -gt 0 ]; then
    echo "run-discovery.sh:   ↳ $sc_rubric_gap insufficient dismissal(s): $sc_cls/'$sc_subsys' ruled out lead(s) on a ground the closed list does not accept ($(_rubric_open_grounds "$sc_log")); this cell's negative is NOT a rigorous clean sweep" >&2
  fi
  sc_promoted="$(_rubric_promoted_count "$sc_log")"
  if [ "$sc_promoted" -gt 0 ]; then
    echo "run-discovery.sh:   ↳ PROMOTED $sc_promoted dismissed lead(s) to Medium candidate(s) after the ground re-ask: $sc_cls/'$sc_subsys' (still judged by the refute gate and the PoC gate)" >&2
  fi
  # #1001 coordination: the hunter reads a shared BLACKBOARD before it prompts and posts every
  # CANDIDATE back to it, so a lead an EARLIER cell found steers later cells (corroborate / pivot).
  # Surface both halves of that loop to the operator and the report: BLACKBOARD-FOCUS| = THIS cell was
  # steered by a sibling's lead; BLACKBOARD-POST| = this cell posted a lead for later cells.
  if grep -q '^BLACKBOARD-FOCUS|' "$sc_log"; then
    FOCUS_LINE="$(grep '^BLACKBOARD-FOCUS|' "$sc_log" | head -1 | sed 's/^BLACKBOARD-FOCUS|//')"
    echo "run-discovery.sh:   ↳ COORDINATION: $sc_cls/'$sc_subsys' steered by the blackboard ($FOCUS_LINE)" >&2
    printf '| %s | %s | steered by blackboard — %s |\n' "$sc_subsys" "$sc_cls" "$FOCUS_LINE" >> "$COORD"
    STEERS=$((STEERS + 1))
  fi
  # #1865: the hunter prints APPENDIX-CONTEXT|<token> when it FRAMED a payload section as the derived
  # implementor of an abstract base. Surface it to the operator (the twin of verify-findings.sh's gate-side
  # line), so a candidate located in a file the zone does not own is attributable while the run is happening.
  if grep -q '^APPENDIX-CONTEXT|' "$sc_log"; then
    APX_LINE="$(grep '^APPENDIX-CONTEXT|' "$sc_log" | head -1 | sed 's/^APPENDIX-CONTEXT|//')"
    echo "run-discovery.sh:   ↳ implementation appendix attached: $APX_LINE" >&2
  fi
  # The hunter's contract: a `CANDIDATE|file:fn:line|class|severity|exploit|poc` line, or `SAFE`.
  # Exclude the hunter's own `BLACKBOARD-*` diagnostic lines: they echo a lead summary (which no longer
  # carries a bare `CANDIDATE|` token, but stay defensive) and must never be scraped as findings.
  # #2245 iteration 2: the `|| [ -s ... ]` half is load-bearing — a cell whose only candidate came from the
  # ground gate's PROMOTION has no `CANDIDATE|` line in its own log, so without it the promoted lead would be
  # accumulated into the JSON (via _cell_candidates) and never reach $REPORT or the CANDIDATES counter.
  if grep -v '^BLACKBOARD-' "$sc_log" | grep -q 'CANDIDATE|' || [ -s "$sc_log.rubric-promoted" ]; then
    while IFS= read -r LINE; do
      CAND="$(printf '%s' "$LINE" | sed 's/^.*\(CANDIDATE|\)/\1/')"
      BODY="$(printf '%s' "$CAND" | sed 's/^CANDIDATE|//; s/|/ \/ /g')"
      printf '| %s | %s | %s |\n' "$sc_subsys" "$sc_cls" "$BODY" >> "$REPORT"
      CANDIDATES=$((CANDIDATES + 1))
    done < <(_cell_candidates "$sc_log")
    if grep -q '^BLACKBOARD-POST|' "$sc_log"; then
      echo "run-discovery.sh:   ↳ posted a lead to the blackboard for later cells to focus on" >&2
    fi
  fi
  _accumulate_cell "$sc_subsys" "$sc_cls" "$sc_files" "$sc_log" ok "$sc_phase"
}

# _plan_depth_cells <cap> <known-dir> — #1827: read the ACCUMULATED breadth cells in $CELLS_JSONL and print
# the depth plan, one TSV row per depth cell: `<subsystem>\t<class>\t<file@fn>\t<known-leads file>`. Also
# writes each flagged location's already-known lead block to <known-dir>/known-<rank>.txt (multi-line, so it
# cannot ride on the TSV row). Prints nothing when no breadth cell surfaced a usable location.
#
# It reads $CELLS_JSONL — NOT the blackboard memo — precisely because that accumulator is written in MANIFEST
# order on BOTH the serial and the --jobs > 1 path (under parallelism every cell's board is empty, so a
# memo-derived target list would differ per path). One code path, one order, one depth set.
#
# Ranking (deterministic, no ties left to the shell): (a) severity High before Medium before other, (b) more
# breadth candidates first, (c) first appearance in manifest order. Per location the class order is the zone's
# classes that did NOT produce a lead there (in manifest order) FIRST, then the producing one(s) LAST — at both
# diagnosing sites the co-located miss lives under a DIFFERENT taxonomy class than the hit, so a cross-lens
# re-read is the higher-yield draw and same-class exhaustion is the fallback. The cap is then spent by the
# #1850 QUOTA-ROUND-ROBIN: `quota` consecutive lenses per location, in rounds, so the budget CONCENTRATES on
# the top-ranked functions without ever burning entirely on the first one (quota = 1 is the #1827 spread).
#
# The JSON scan is a real (tiny) string scanner rather than a `,`-split: _json_str escapes `\` and `"`, and a
# hunter's exploit prose routinely contains quotes — splitting on `","` would mis-slice such a record.
_plan_depth_cells() {
  awk -v cap="$1" -v kdir="$2" -v quota="$3" '
    # Index of the value opening-quote for <key> at or after <from>; 0 when absent.
    function nextkey(s, from, key,   q) {
      q = index(substr(s, from), key)
      if (q == 0) return 0
      return from + q - 1 + length(key)
    }
    # Decode the JSON string whose opening quote is at s[p]; sets G_STR + G_POS (just past the close quote).
    function jsread(s, p,   out, c) {
      out = ""; p = p + 1
      while (p <= length(s)) {
        c = substr(s, p, 1)
        if (c == "\\") { out = out substr(s, p + 1, 1); p = p + 2; continue }
        if (c == "\"") { G_STR = out; G_POS = p + 1; return }
        out = out c; p = p + 1
      }
      G_STR = out; G_POS = p
    }
    # Should location a be ranked AFTER location b?
    function worse(a, b) {
      if (loc_sev[a] != loc_sev[b]) return (loc_sev[a] > loc_sev[b])
      if (loc_count[a] != loc_count[b]) return (loc_count[a] < loc_count[b])
      return (loc_first[a] > loc_first[b])
    }
    BEGIN { ci = 0; nloc = 0 }
    {
      line = $0; pos = 1
      k = nextkey(line, pos, "\"subsystem\":"); if (k == 0) next
      jsread(line, k); subsys = G_STR; pos = G_POS
      k = nextkey(line, pos, "\"class\":");     if (k == 0) next
      jsread(line, k); cls = G_STR; pos = G_POS
      k = nextkey(line, pos, "\"files\":");     if (k == 0) next
      jsread(line, k); pos = G_POS
      k = nextkey(line, pos, "\"status\":");    if (k == 0) next
      jsread(line, k); status = G_STR; pos = G_POS
      ci++
      # The zone class order IS the manifest (scope.tsv) order: first appearance wins. A cell that FAILED
      # still contributes its class here — the class was hunted, it just produced no usable reply.
      if (!((subsys SUBSEP cls) in zcls_seen)) {
        zcls_seen[subsys SUBSEP cls] = 1
        zn[subsys]++
        zcls[subsys, zn[subsys]] = cls
      }
      if (status != "ok") next
      k = index(substr(line, pos), "\"candidates\":[")
      if (k == 0) next
      pos = pos + k - 1 + length("\"candidates\":[")
      while (1) {
        c = substr(line, pos, 1)
        if (c == "" || c == "]") break
        if (c != "\"") { pos++; continue }
        jsread(line, pos); cand = G_STR; pos = G_POS
        # `file:fn[:line]|class|severity|exploit|poc` — the location is the head field.
        b = index(cand, "|")
        if (b > 0) head = substr(cand, 1, b - 1); else head = cand
        i1 = index(head, ":")
        if (i1 < 2) continue                       # no `file:fn` -> nothing to narrow the payload to
        file = substr(head, 1, i1 - 1)
        rest = substr(head, i1 + 1)
        i2 = index(rest, ":")
        if (i2 > 0) fn = substr(rest, 1, i2 - 1); else fn = rest
        if (fn == "") continue
        # SECURITY: file/fn come from the LOCATION field of a hunter-written CANDIDATE line -- LLM output,
        # NOT operator-curated scope.tsv content. loc_target (file@fn) becomes the IN_SCOPE of a depth cell,
        # and cat_file() in hunter.ag concatenates IN_SCOPE UNESCAPED into an exec sh command (pre-#1827
        # code, safe only while IN_SCOPE was always trusted config). A prompt-injected or hostile target
        # could make the hunter emit a location carrying shell metacharacters or a dot-dot traversal, so
        # reject anything that is not a plain repo-relative path / identifier BEFORE it becomes a target.
        if (file !~ /^[A-Za-z0-9_.\/-]+$/) continue
        if (file ~ /(^|\/)\.\.(\/|$)/) continue
        if (file ~ /^\//) continue
        if (fn !~ /^[A-Za-z0-9_$]+$/) continue
        sev = 2
        nf = split(cand, F, "|")
        if (nf >= 3) {
          s3 = tolower(F[3])
          if (index(s3, "high") > 0) sev = 0
          else if (index(s3, "medium") > 0) sev = 1
        }
        key = subsys SUBSEP file SUBSEP fn
        if (!(key in loc_seen)) {
          loc_seen[key] = 1
          nloc++
          loc_key[nloc] = key
          loc_subsys[key] = subsys
          loc_target[key] = file "@" fn
          loc_first[key] = ci
          loc_sev[key] = sev
          loc_count[key] = 0
          loc_known[key] = ""
        }
        if (sev < loc_sev[key]) loc_sev[key] = sev
        loc_count[key]++
        loc_prod[key, cls] = 1
        if (loc_known[key] == "") loc_known[key] = "- " cand
        else loc_known[key] = loc_known[key] "\n- " cand
      }
    }
    END {
      if (nloc == 0) exit 0
      for (i = 1; i <= nloc; i++) ord[i] = loc_key[i]
      for (i = 2; i <= nloc; i++) {                 # insertion sort: n is the flagged-location count
        v = ord[i]; j = i - 1
        while (j >= 1 && worse(ord[j], v)) { ord[j + 1] = ord[j]; j-- }
        ord[j + 1] = v
      }
      maxn = 0
      for (i = 1; i <= nloc; i++) {
        key = ord[i]; s = loc_subsys[key]; m = 0
        for (j = 1; j <= zn[s]; j++) { c = zcls[s, j]; if (!((key, c) in loc_prod)) { m++; clsl[key, m] = c } }
        for (j = 1; j <= zn[s]; j++) { c = zcls[s, j]; if ((key, c) in loc_prod)  { m++; clsl[key, m] = c } }
        clsn[key] = m
        if (m > maxn) maxn = m
        kf = kdir "/known-" i ".txt"
        print loc_known[key] > kf
        close(kf)
        loc_kf[key] = kf
      }
      # #1850 QUOTA-ROUND-ROBIN. Each location gets `quota` CONSECUTIVE lenses before the plan moves on;
      # after every location has had its quota the rounds repeat (positions quota+1..2*quota, and so on)
      # until the cap is spent. At quota == 1 this degenerates to the #1827 `for pass { for location }`
      # spread BYTE-FOR-BYTE, which is why that allocation needs no second code path. A location with fewer
      # remaining lenses than the quota emits all it has and the stream continues — no reserved-but-unspent
      # quota, so the plan is one ordered stream truncated at `cap`, work-conserving by construction.
      emitted = 0
      for (rnd = 0; rnd * quota < maxn; rnd++) {
        progressed = 0
        for (i = 1; i <= nloc; i++) {
          key = ord[i]
          for (q = 1; q <= quota; q++) {
            p = rnd * quota + q
            if (p > clsn[key]) break            # the lens list of this location is exhausted for this round
            if (emitted >= cap) exit 0
            printf "%s\t%s\t%s\t%s\n", loc_subsys[key], clsl[key, p], loc_target[key], loc_kf[key]
            emitted++
            progressed = 1
          }
        }
        if (!progressed) break
      }
    }
  ' "$CELLS_JSONL"
}

# _seed_from_recorded_run — #1857: the DEPTH-ONLY RE-ENTRY. Instead of hunting the breadth pass, seed
# $CELLS_JSONL with the BREADTH cells of a recorded `discovery-results.json` and let the run fall straight
# into the unchanged #1827 depth block below: _plan_depth_cells + run_cell + scrape_cell_log are reused
# VERBATIM, so the plan a re-entry computes is the plan the original run computed. That is the whole property
# this exists to buy, and it is why the re-entry is not a second script.
#
# The cells are re-emitted with `separators=(",",":")` + `ensure_ascii=False`, which reproduces _json_str's
# output byte-for-byte on both preserved plaza arms — the carried records are the SOURCE records, not an
# approximation, so verify-findings.sh -> score-match.py score a depth-only arm exactly like a full run.
#
# The carried breadth cells are ALSO re-rendered into $REPORT/$COORD with the same transformations
# scrape_cell_log uses, and the counters are seeded from the recorded run, so a depth-only report is not
# misleadingly empty of the breadth leads its depth plan was derived from.
_seed_from_recorded_run() {
  sr_rows="$RUN/depth-from-rows.tsv"
  python3 - "$DEPTH_FROM" "$CELLS_JSONL" "$sr_rows" <<'PY'
import sys, json
src, jsonl, rows = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding="utf-8") as fh:
    d = json.load(fh)
breadth = [c for c in d["cells"] if isinstance(c, dict) and c.get("phase") != "depth"]
with open(jsonl, "w", encoding="utf-8") as out:
    for c in breadth:
        out.write(json.dumps(c, ensure_ascii=False, separators=(",", ":")) + "\n")
def flat(s):
    # The row file is TSV read back by the shell; a tab/newline inside a hunter-written string would split it.
    return str(s).replace("\t", " ").replace("\r", " ").replace("\n", " ")
with open(rows, "w", encoding="utf-8") as out:
    for c in breadth:
        sub, cls = flat(c.get("subsystem", "")), flat(c.get("class", ""))
        if c.get("status") != "ok":
            # Mirrors scrape_cell_log's early return: a #1707 failed cell contributes its FAILED row and
            # nothing else — never silently folded into "0 candidates".
            out.write("\t".join(["failed", sub, cls, ""]) + "\n")
            continue
        for cand in (c.get("candidates") or []):
            out.write("\t".join(["cand", sub, cls, flat(cand)]) + "\n")
        for co in (c.get("coordination") or []):
            out.write("\t".join(["steer", sub, cls, flat(co)]) + "\n")
PY
  CELLS="$DF_CELLS"
  while IFS='	' read -r SR_KIND SR_SUBSYS SR_CLS SR_BODY || [ -n "${SR_KIND:-}" ]; do
    case "$SR_KIND" in
      cand)
        SR_RENDERED="$(printf '%s' "$SR_BODY" | sed 's/|/ \/ /g')"
        printf '| %s | %s | %s |\n' "$SR_SUBSYS" "$SR_CLS" "$SR_RENDERED" >> "$REPORT"
        CANDIDATES=$((CANDIDATES + 1)) ;;
      steer)
        printf '| %s | %s | steered by blackboard — %s |\n' "$SR_SUBSYS" "$SR_CLS" "$SR_BODY" >> "$COORD"
        STEERS=$((STEERS + 1)) ;;
      failed)
        printf '| %s | %s | FAILED — carried from the recorded run, no CANDIDATE|/SAFE reply (NOT a rigorous negative) |\n' \
          "$SR_SUBSYS" "$SR_CLS" >> "$REPORT"
        FAILED_CELLS=$((FAILED_CELLS + 1)) ;;
    esac
  done < "$sr_rows"
  echo "run-discovery.sh: depth-only re-entry — carried $CELLS breadth cell(s) / $CANDIDATES candidate(s) from $DEPTH_FROM; NO breadth cell is re-hunted" >&2
}

# Manifest loop: one subsystem per line, `subsystem | classes | files`. Run the hunter once per
# (subsystem x class) — that cell is the colony-native analogue of one focused audit agent.
# #1857: --depth-from replaces the whole breadth pass with the recorded one; the serial and parallel blocks
# below are textually untouched, so the shipped path cannot be reached by the re-entry and vice versa.
if [ -n "$DEPTH_FROM" ]; then
  _seed_from_recorded_run
elif [ "$JOBS" -le 1 ]; then
  # SERIAL path (default): the current loop, byte-for-byte identical to the pre-M3 hunt — run_cell then
  # scrape_cell_log inline in manifest order against the ONE shared $RUN store (live #1001 steering).
  while IFS='|' read -r SUBSYS CLS_CSV FILES_CSV || [ -n "${SUBSYS:-}" ]; do
    # trim + skip blanks/comments
    SUBSYS="$(printf '%s' "$SUBSYS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$SUBSYS" in ''|\#*) continue ;; esac
    CLS_CSV="$(printf '%s' "$CLS_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    FILES_CSV="$(printf '%s' "$FILES_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$ONLY" ] && [ "$SUBSYS" != "$ONLY" ] && continue
    [ -n "$CLASSES_OVERRIDE" ] && CLS_CSV="$CLASSES_OVERRIDE"
    [ -n "$FILES_CSV" ] || { echo "run-discovery.sh: subsystem '$SUBSYS' has no files; skipping" >&2; continue; }

    # IN_SCOPE is newline-separated (hunter splits on \n); convert the manifest's comma list.
    IN_SCOPE="$(printf '%s' "$FILES_CSV" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)"
    SLUG="$(printf '%s' "$SUBSYS" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
    # #1865: resolve the appendix pair ONCE per manifest line (every class cell of a line shares the payload).
    APXF="" ; APXB=""
    APX_ROW="$(_appendix_for "$SUBSYS" "$FILES_CSV")"
    if [ -n "$APX_ROW" ]; then APXF="${APX_ROW%%	*}"; APXB="${APX_ROW#*	}"; fi

    OLDIFS="$IFS"; IFS=','
    for CLS in $CLS_CSV; do
      IFS="$OLDIFS"
      CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$CLS" ] || { IFS=','; continue; }
      CELLS=$((CELLS + 1))
      CELL_LOG="$RUN/hunt_${SLUG}_${CLS}.log"
      run_cell "$RUN" "$SUBSYS" "$CLS" "$IN_SCOPE" "$CELL_LOG" "" "" "$APXF" "$APXB"
      scrape_cell_log "$SUBSYS" "$CLS" "$CELL_LOG" "$FILES_CSV"
      IFS=','
    done
    IFS="$OLDIFS"
  done < "$SCOPE"
else
  # PARALLEL path (#1625, --jobs > 1): expand the manifest into an ORDERED cell list, give EACH cell its OWN
  # isolated agentis store (a cp -r of the initialised $RUN template) so concurrent memo/build writes never
  # race — which means every cell's blackboard is EMPTY and #1001 cross-cell steering is disabled here (the
  # documented throughput-vs-steering trade). Launch under a HARD `wait -n` slot capped at effective_jobs =
  # min(--jobs, CELL_CAP); after the pool drains, scrape each cell in MANIFEST order (the SAME scrape_cell_log)
  # so the aggregated finding set is identical + independent of completion order.
  CELL_SUBSYS=() ; CELL_CLS=() ; CELL_INSCOPE=() ; CELL_FILES=() ; CELL_DIR=() ; CELL_LOGP=()
  CELL_APXF=() ; CELL_APXB=()   # #1865: the per-line appendix pair, resolved with the manifest line itself
  while IFS='|' read -r SUBSYS CLS_CSV FILES_CSV || [ -n "${SUBSYS:-}" ]; do
    SUBSYS="$(printf '%s' "$SUBSYS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$SUBSYS" in ''|\#*) continue ;; esac
    CLS_CSV="$(printf '%s' "$CLS_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    FILES_CSV="$(printf '%s' "$FILES_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$ONLY" ] && [ "$SUBSYS" != "$ONLY" ] && continue
    [ -n "$CLASSES_OVERRIDE" ] && CLS_CSV="$CLASSES_OVERRIDE"
    [ -n "$FILES_CSV" ] || { echo "run-discovery.sh: subsystem '$SUBSYS' has no files; skipping" >&2; continue; }
    IN_SCOPE="$(printf '%s' "$FILES_CSV" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)"
    SLUG="$(printf '%s' "$SUBSYS" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
    APXF="" ; APXB=""
    APX_ROW="$(_appendix_for "$SUBSYS" "$FILES_CSV")"
    if [ -n "$APX_ROW" ]; then APXF="${APX_ROW%%	*}"; APXB="${APX_ROW#*	}"; fi
    OLDIFS="$IFS"; IFS=','
    for CLS in $CLS_CSV; do
      IFS="$OLDIFS"
      CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$CLS" ] || { IFS=','; continue; }
      CELLS=$((CELLS + 1))
      CELL_SUBSYS+=("$SUBSYS") ; CELL_CLS+=("$CLS") ; CELL_INSCOPE+=("$IN_SCOPE")
      CELL_FILES+=("$FILES_CSV") ; CELL_DIR+=("$RUN/cell-${SLUG}_${CLS}") ; CELL_LOGP+=("$RUN/hunt_${SLUG}_${CLS}.log")
      CELL_APXF+=("$APXF") ; CELL_APXB+=("$APXB")
      IFS=','
    done
    IFS="$OLDIFS"
  done < "$SCOPE"

  effective_jobs="$JOBS"
  if [ "$effective_jobs" -gt "$CELL_CAP" ]; then
    echo "run-discovery.sh: --jobs $JOBS exceeds the hard cap LLM_MAX_DISCOVERY_CELLS=$CELL_CAP; clamping concurrency to $CELL_CAP" >&2
    effective_jobs="$CELL_CAP"
  fi
  echo "run-discovery.sh: parallel fan-out over ${#CELL_SUBSYS[@]} cell(s), up to $effective_jobs concurrent (isolated per-cell stores; #1001 cross-cell steering off under --jobs > 1)" >&2

  # Launch under a hard job-slot: keep at most effective_jobs run_cell processes live at any instant.
  live=0 ; idx=0 ; ncells=${#CELL_SUBSYS[@]}
  while [ "$idx" -lt "$ncells" ]; do
    while [ "$live" -ge "$effective_jobs" ]; do
      wait -n 2>/dev/null || true
      live=$((live - 1))
    done
    cdir="${CELL_DIR[$idx]}"
    rm -rf "$cdir"; mkdir -p "$cdir"
    cp -r "$RUN/.agentis" "$cdir/.agentis"        # isolated store: an empty blackboard, no cross-cell race
    cp "$RUN/hunter.ag" "$cdir/hunter.ag"
    cp "$RUN/slice-fns.sh" "$cdir/slice-fns.sh"
    # #2235: the resolver rides the same idiom as the slicer — copied INTO the cell dir, because that dir is
    # what the hunt sandbox binds; a path outside it does not exist for the driven session. No-op when off.
    if [ -n "$EXTERNAL_RESOLVER" ]; then cp "$RUN/resolve-external.sh" "$cdir/resolve-external.sh"; fi
    if [ -n "$ONCHAIN_FACT" ]; then cp "$RUN/onchain-fact.sh" "$cdir/onchain-fact.sh"; fi
    # #993: trust this cell dir HERE (foreground, serialized) — never inside the
    # backgrounded run_cell subshell, where concurrent whole-file writes would race.
    case "$BACKEND" in flat-cyborg|claude) df_ensure_claude_trust "$cdir" ;; esac
    run_cell "$cdir" "${CELL_SUBSYS[$idx]}" "${CELL_CLS[$idx]}" "${CELL_INSCOPE[$idx]}" "${CELL_LOGP[$idx]}" \
      "" "" "${CELL_APXF[$idx]}" "${CELL_APXB[$idx]}" &
    live=$((live + 1))
    idx=$((idx + 1))
  done
  while [ "$live" -gt 0 ]; do
    wait -n 2>/dev/null || true
    live=$((live - 1))
  done

  # Deferred aggregation: scrape every cell's log in MANIFEST order (order-independent of finish order).
  idx=0
  while [ "$idx" -lt "$ncells" ]; do
    scrape_cell_log "${CELL_SUBSYS[$idx]}" "${CELL_CLS[$idx]}" "${CELL_LOGP[$idx]}" "${CELL_FILES[$idx]}"
    idx=$((idx + 1))
  done
fi

# #1827 DEPTH PASS — ONE pass, after ALL breadth cells, on BOTH the serial and the parallel path (the plan is
# derived from the same manifest-ordered $CELLS_JSONL, so the depth set is identical either way). Each depth
# cell is a FULL cell: it increments $CELLS, runs through the unchanged run_cell + scrape_cell_log, and lands
# in cells[] tagged "phase":"depth". Targets are computed ONCE, BEFORE the first depth cell runs, so a depth
# candidate can never spawn further depth cells (the #1830 --rehunt-gaps rule: one pass, never a loop).
DEPTH_CELLS=0
if [ "$DEPTH_MAX_CELLS" -gt 0 ]; then
  DEPTH_KNOWN_DIR="$RUN/depth-known"; mkdir -p "$DEPTH_KNOWN_DIR"
  DEPTH_PLAN="$RUN/depth-plan.tsv"
  _plan_depth_cells "$DEPTH_MAX_CELLS" "$DEPTH_KNOWN_DIR" "$DEPTH_LENS_QUOTA" > "$DEPTH_PLAN"
  DEPTH_PLANNED="$(grep -c . "$DEPTH_PLAN" 2>/dev/null || true)"
  # #1857: the ONE provenance guard that reaches the WORKING TREE. Every other refusal is decided from the
  # artifact alone (before the output dir exists); this one needs the computed plan, so it fires here — still
  # BEFORE the first depth cell runs. A target the checkout no longer carries means the tree moved under the
  # recorded run, which is exactly the stale-checkout case the commit key cannot catch on an old artifact.
  if [ -n "$DEPTH_FROM" ]; then
    while IFS= read -r DG_TARGET; do
      [ -n "$DG_TARGET" ] || continue
      DG_FILE="${DG_TARGET%%@*}"
      [ -f "$REPO/$DG_FILE" ] || { echo "run-discovery.sh: --depth-from: the depth plan targets '$DG_FILE', which does not exist under $REPO — the checkout moved under the recorded run" >&2; exit 3; }
    done < <(cut -f3 "$DEPTH_PLAN" | sort -u)
  fi
  echo "run-discovery.sh: depth pass — ${DEPTH_PLANNED:-0} extra cell(s) over the flagged functions (cap $DEPTH_MAX_CELLS, lens quota $DEPTH_LENS_QUOTA per location per round)" >&2
  while IFS='	' read -r D_SUBSYS D_CLS D_TARGET D_KNOWNF || [ -n "${D_SUBSYS:-}" ]; do
    [ -n "$D_SUBSYS" ] || continue
    CELLS=$((CELLS + 1))
    DEPTH_CELLS=$((DEPTH_CELLS + 1))
    D_SLUG="$(printf '%s' "$D_SUBSYS" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
    D_LOG="$RUN/depth_${D_SLUG}_${D_CLS}_${DEPTH_CELLS}.log"
    D_KNOWN="$(cat "$D_KNOWNF" 2>/dev/null || true)"
    echo "run-discovery.sh:   ↳ DEPTH: re-reading $D_TARGET under $D_CLS (excluding the known lead(s))" >&2
    # IN_SCOPE is the NARROWED `file@fn` — cat_file() routes it through the existing slice-fns.sh slicer, so
    # the payload is that one function plus its contract header. It also keeps the depth cell's (subsystem,
    # class, files) key DISTINCT from the breadth cell's, which is what run-zone-hunt.sh's merge dedupes on.
    run_cell "$RUN" "$D_SUBSYS" "$D_CLS" "$D_TARGET" "$D_LOG" "$D_TARGET" "$D_KNOWN"
    scrape_cell_log "$D_SUBSYS" "$D_CLS" "$D_LOG" "$D_TARGET" depth
  done < "$DEPTH_PLAN"
fi

# #1707: only a run with ZERO candidates AND ZERO failed cells is a rigorous NEGATIVE. A cell that FAILED
# validation (chrome / no answer) is NOT evidence of cleanliness, so its presence suppresses this line —
# the FAILED rows above already make those cells visible as unassessed, not clean.
if [ "$CANDIDATES" -eq 0 ] && [ "$FAILED_CELLS" -eq 0 ]; then
  echo "| _(none)_ | — | rigorous NEGATIVE — no candidate of any hunted class survived. A clean result on audited code is a valid outcome; nothing is submitted. |" >> "$REPORT"
fi
{
  echo
  echo "---"
  echo "Cells run: $CELLS    Candidates surfaced: $CANDIDATES (all UNVERIFIED — forge-verify each before it counts)."
  # #1857: without this line `Cells run: N` reads as "N cells were hunted", which a depth-only re-entry did not do.
  [ -n "$DEPTH_FROM" ] && echo "Of those, $DF_CELLS breadth cell(s) were CARRIED from \`$DEPTH_FROM\` (NOT re-hunted); $DEPTH_CELLS depth cell(s) were hunted by this run."
} >> "$REPORT"

# #1001: append the coordination table — where a lead from one cell STEERED a later cell via the shared
# blackboard. This is what makes the run more than a sum of independent audits: emit it whenever any
# cell was steered, so the operator can see the inter-agent influence (and audit it).
if [ "$STEERS" -gt 0 ]; then
  {
    echo
    echo "## Inter-agent coordination (blackboard, #1001)"
    echo
    echo "A cell that surfaces a CANDIDATE posts it to a shared in-run blackboard; every later cell reads"
    echo "the board and is steered to corroborate a sibling's hit or pivot to a related surface. Cells"
    echo "steered this run:"
    echo
    echo "| Subsystem | Class | Steer |"
    echo "|---|---|---|"
    cat "$COORD"
  } >> "$REPORT"
fi

# #1625: additive machine-readable sibling of discovery-report.md — the same accumulator, emitted on BOTH
# paths. It does not affect discovery-report.md's bytes (the byte-identical invariant targets the report).
RESULTS_JSON="$OUT/discovery-results.json"
CELLS_ARR="$(paste -sd, "$CELLS_JSONL" 2>/dev/null || true)"
# #1827: totals.depth_cells appears ONLY when --depth-max-cells > 0, so a depth-off run's JSON keys are
# byte-identical to the pre-#1827 ones. `cells` is the TOTAL (breadth + depth) — depth never hides.
# #1850: totals.depth_lens_quota rides the SAME gate and records WHICH allocation produced these cells, so no
# future reader can compare two depth arms without seeing that they were spent differently.
DEPTH_TOTAL_JSON=""
if [ "$DEPTH_MAX_CELLS" -gt 0 ]; then DEPTH_TOTAL_JSON=",\"depth_cells\":$DEPTH_CELLS,\"depth_lens_quota\":$DEPTH_LENS_QUOTA"; fi
# #1857: `commit` is recorded on EVERY run (a soft git dependency that degrades to "unknown"), so a LATER
# --depth-from can refuse a stale checkout; `depth_from` rides the same emit-only-when-set gate as the depth
# totals, so a run without the flag keeps its exact key set.
DEPTH_FROM_JSON=""
if [ -n "$DEPTH_FROM" ]; then
  DEPTH_FROM_JSON=",\"depth_from\":{\"source\":$(_json_str "$DEPTH_FROM"),\"repo\":$(_json_str "$DF_REPO"),\"commit\":$(_json_str "$DF_COMMIT"),\"carried_cells\":$DF_CELLS,\"carried_candidates\":$DF_CANDIDATES}"
fi
# #2217: the second tier. Both fragments are EXACTLY 0 bytes unless the feature is on AND the run carried a
# record the cap kept, so a feature-OFF run — and a feature-ON run with nothing unsettled — emits byte-identical
# JSON to a pre-#2217 run. The cap is applied HERE, over the whole zone, after every cell has been accumulated,
# which is what makes the selection independent of --jobs.
TIER2_JSON=""
TIER2_TOTALS_JSON=""
if [ "$TIER2" -eq 1 ]; then
  TIER2_JSON="$(_tier2_top_json "$TIER2_TSV" 1 "$DF_TIER2_MAX_PER_ZONE")"
  TIER2_TOTALS_JSON="$(_tier2_totals_json "$TIER2_TSV" 1 "$DF_TIER2_MAX_PER_ZONE")"
fi
printf '{"repo":%s,"commit":%s,"backend":%s,"jobs":%s%s,"cells":[%s],"totals":{"cells":%s,"candidates":%s,"steers":%s,"failed":%s%s%s}%s}\n' \
  "$(_json_str "$(basename "$REPO")")" "$(_json_str "$COMMIT")" "$(_json_str "$BACKEND")" "$JOBS" "$DEPTH_FROM_JSON" "$CELLS_ARR" \
  "$CELLS" "$CANDIDATES" "$STEERS" "$FAILED_CELLS" "$DEPTH_TOTAL_JSON" "$TIER2_TOTALS_JSON" "$TIER2_JSON" > "$RESULTS_JSON"

echo >&2
DEPTH_BANNER=""
if [ "$DEPTH_MAX_CELLS" -gt 0 ]; then DEPTH_BANNER=" ($DEPTH_CELLS depth)"; fi
echo "================ DISCOVERY: $CELLS cells$DEPTH_BANNER, $CANDIDATES candidate(s), $STEERS blackboard-steered, $FAILED_CELLS failed ================" >&2
echo "run-discovery.sh: leads at $REPORT" >&2
# #2217: say what the second tier carried, and say what it is NOT. A tier-2 record is an UNSETTLED check, not
# a lead: it never enters the candidate count above and nothing here verifies or submits one.
if [ -n "$TIER2_JSON" ]; then
  TIER2_KEPT="$(_tier2_select "$TIER2_TSV" "$DF_TIER2_MAX_PER_ZONE" | _count_stdin)"
  TIER2_ALL="$(grep -c . "$TIER2_TSV" 2>/dev/null || true)"
  case "$TIER2_ALL" in ''|*[!0-9]*) TIER2_ALL=0 ;; esac
  echo "run-discovery.sh: tier-2: $TIER2_KEPT of $TIER2_ALL unsettled check(s) carried (cap $DF_TIER2_MAX_PER_ZONE/zone) — these are UNSETTLED CHECKS, not candidates, and carry no severity" >&2
fi
if [ "$CANDIDATES" -gt 0 ]; then
  echo "run-discovery.sh: NEXT = verify each lead with evm-harness/forge-verify.sh; only a PASSING PoC is a finding. Submission stays human-gated." >&2
else
  echo "run-discovery.sh: no candidates — rigorous negative. Nothing to verify, nothing submitted." >&2
fi
