# Changelog — dark-factory

All notable changes to the `dark-factory/` federation will be documented in
this file.

This federation follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
at the federation level. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tags use the prefixed form `dark-factory-v<X.Y.Z>` so other federations
in this repo can release independently without collision.

Every release declares its runtime floor as `**Requires:** agentis >= X.Y.Z`.

## [Unreleased]

### Added
- **Complete Immunefi PoC-form artifact set + auto secret-gist in the submission package** (#1540, epic #1505).
  `deliver-submission.sh` grows from staging the prose draft into staging the COMPLETE PoC-form bundle a human
  files out-of-band — additively, keeping every existing invariant byte-intact (the exit-3 marker guard, the
  never-submit / no-bounty-platform-egress contract, the #1538 Slack notify, and the one-line staged-path stdout
  relied on by `demo-feedback-loop.sh` + `feedback-intake.ag`).
  - **New optional inputs** `--poc-file <path>` (REPEATABLE), `--poc-run <path>`, `--poc-kind <foundry|hardhat>`
    (else inferred from the poc-file extension), `--poc-target <C.sol[:Name]>`, `--poc-match <prefix>` bundle the
    verbatim PoC source under `poc/<basename>`, a captured passing run-log as `poc-run.txt`, and a generated
    dash-safe `REPRODUCE.md` (toolchain + the concrete `forge test --match-path …` / `npx hardhat test …` command +
    the expected `[PASS]` line + the inverted-polarity note: a PASSING PoC = the exploit reproduced). A missing
    input warns to stderr and is skipped — the package still stages (writeup-only degradation), exit 0.
  - **FIELD→manifest extraction (folds in #1542's deferred wiring):** the five `FIELD|project|…`/`asset`/`impact`/
    `severity`/`title` lines `report-writer.ag` (#1543) now emits are extracted from the in-memory draft into a
    nested `immunefi_fields` object in `manifest.json` (draft-synced, so the form metadata can never drift — this
    is why the fields are extracted rather than re-declared as `--project`/`--asset` flags). A missing label
    defaults to `""`; every existing manifest key (`submission_id` etc.) is preserved, so `feedback-intake.ag` is
    unaffected. New manifest keys: `immunefi_fields`, `poc_files`, `poc_run`, `reproduce`, `gist_url`.
  - **Secret Gist auto-create** (best-effort, gated by `gist_ready()` = `gh` present AND a token/auth). When a PoC
    is staged, `gh gist create --secret` publishes the PoC source + `REPRODUCE.md` + a generated `GIST_README.md`
    to the operator's OWN GitHub and records the URL into the manifest. The Immunefi PoC form asks for a "secret
    Gist environment to support your PoC"; this gist is a SECOND egress but to the operator's own GitHub — NOT a
    bounty-platform submission; the human-gated-submit + never-submit invariants are unchanged. Best-effort and
    wrapped so it can NEVER fail a stage that already succeeded, with gh's stdout captured (`$(...)`) and all
    chatter routed to stderr so the one-line stdout contract holds. On no token / any failure it degrades to a
    loud stderr warning + `poc/GIST_COMMAND.txt` (the exact `gh gist create --secret` command to run by hand) + a
    `gist_url` placeholder.
  - **`run-poc.sh` run-evidence capture:** on a `FINDING` only, best-effort re-invokes the gate against the warm
    rundir to write a durable passing run-log (`poc-run.txt`) — AFTER the verdict is fixed, so it can NEVER regress
    the classify — and surfaces the runnable-PoC path + run-log on its OWN stdout as additive `POC-FILE|`/`POC-RUN|`
    lines (the coordinator hand-off / `deliver-submission --poc-file/--poc-run` source). All sub-invocations use
    `bash`, never `sh` (the #1507/#1534/#1535 dash lesson); `REPRODUCE.md`/`GIST_README.md`/`GIST_COMMAND.txt` are
    generated via `{ printf …; }` blocks (no heredoc).
  - `demo-feedback-loop.sh` gains an offline `5) POC ARTIFACT SET` section with a `gh` STUB on PATH (mirrors the
    part-4 curl stub): full artifact set + authed gist (byte-identical poc/run-log, REPRODUCE.md content, nested
    `immunefi_fields`, the stubbed gist URL, one-line stdout WITH the stub active), the no-token fallback (placeholder
    + `GIST_COMMAND.txt`, gh never runs `gist create`), writeup-only degradation, the marker guard running BEFORE any
    poc staging/gist, and the no-FIELD default-to-`""` case — no network anywhere. `demo-poc-gen.sh`'s source-guard
    gains the `run-poc.sh` run-evidence / `POC-FILE|`/`POC-RUN|` wiring assertion. **Out of scope (follow-up):**
    threading `run-poc.sh`'s new `POC-FILE|`/`POC-RUN|` stdout into `coordinator.ag`'s submission pass.
- **`report-writer.ag` emits discrete Immunefi form-metadata fields** (#1542). Between the
  `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW` marker and the existing 4-section markdown Description, the agent now
  renders exactly five machine-extractable `FIELD|<label>|<value>` lines — `FIELD|project|`, `FIELD|asset|`,
  `FIELD|impact|`, `FIELD|severity|`, `FIELD|title|` — sourced from two new optional env inputs (`PROJECT_NAME`,
  `FINDING_ASSET`) plus the existing `FINDING_TITLE`/`FINDING_IMPACT`/`SEVERITY_BAND`. Every value is resolved in
  `.ag` code via a deterministic `field_or_unknown()` default (`"<unknown>"` on blank) BEFORE it reaches the
  instruction, so the LLM only echoes already-known values — no formatting drift, no crash, never a blank
  unparseable line. The marker string and the 4-section Description are unchanged; `deliver-submission.sh`'s
  human-gate marker guard is a substring test, unaffected by lines appended after it. Feeds the Slack delivery
  format (#1541) and package bundling (#1540). **Deferred follow-up:** wiring `PROJECT_NAME`/`FINDING_ASSET`
  through `run-audit-pass.sh`'s `exec.env_passthrough` + CLI flags and into `deliver-submission.sh`'s
  `manifest.json` is caller-side plumbing, not part of this change.
- **Finding-ready Slack/Discord alert on `deliver-submission.sh` staging** (#1538, follow-up to #1526). After a
  successful stage, `deliver-submission.sh` now pages the operator with a finding-ready alert, reusing
  `monitor/scripts/notify.sh` (#1092) unconditionally — the same JSON-alert-to-`notify.sh` pattern as
  `monitor/scripts/check-drift.sh`. Opt-in on a configured webhook (`DARK_FACTORY_SLACK_WEBHOOK`, a
  `secret://...` URI resolved via `tools/parse-toml-secret.py --resolve`, falling back to
  `MONITOR_WEBHOOK_URL`); with no webhook configured this is an offline no-op (`notify.sh`'s own stdout
  no-op fallback) — no network, no behaviour change. The notify subprocess's stdout is redirected to stderr
  (`>&2`) so `notify.sh`'s no-webhook fallback line can never corrupt `deliver-submission.sh`'s documented
  stdout contract (the staged path) relied on by `demo-feedback-loop.sh` and `feedback-intake.ag`; the alert
  send is best-effort (`|| true`) so a broken/bogus webhook can never fail a stage that already succeeded.
  The alert is an operator PAGE on the operator's own channel — not a platform submission; the never-submit
  invariant is unchanged. `demo-feedback-loop.sh` gains a new offline `4) NOTIFY` section covering the
  no-webhook no-op, the alert payload shape, a bogus-webhook exit-code regression, the `bash`-not-`sh` source
  guard, and the stdout-contract regression guard.
- **Coordinator submission-pass integration — the epic #1505 CAPSTONE** (#1509, epic #1505). Wires the shipped
  submission stages (scope-gate #1511, audit-scout DEVISE, poc-writer #1507, impact-gate #1522, dup-scout #1503,
  report-writer #1508) into `coordinator.ag` as ONE fixed-order autonomous pass — `discover -> scope -> devise ->
  poc -> impact -> dup -> report -> HALT` — threading each stage's single-line verdict into the next and
  human-gated at submit. Design decision baked in: this is a THIRD coordinator mode, NOT scored argmax actions —
  the stages have a mandatory partial order + hard early-exit, not interchangeable bandit arms, so a policy weight
  must never reorder or skip them.
  - `auditor/agents/coordinator.ag` — a new PASS block, all additive and DARK unless `PASS_ENABLED` is set (the
    existing #1014 ORCHESTRATE_ENABLED reduce loop + the single decide_once path stay BYTE-IDENTICAL when the flag
    is unset — the demo-coordinator.sh no-flag regression guard). `submission_pass()` reduces `pass_step` over the
    fixed `STAGES` order; each step resolves the stage verdict, traces a row + emits `dark-factory:pass_stage` +
    `learn("coordinator-pass", ...)` (so per-stage outcome still evolves by result), threads the verdict forward,
    and HARD-halts on a blocking gate: scope not payable -> `BLOCKED-SCOPE`, devise no-residual -> `NO-RESIDUAL`,
    poc not finding -> `NO-POC`, impact not substantiated -> `BLOCKED-IMPACT`. dup HIGH is ADVISORY (threaded,
    never halts). report is terminal -> `PENDING-HUMAN-REVIEW`. The hard gate predicates (`scope_proceeds`,
    `impact_proceeds`) require the EXACT productive token; anything else (incl. the stub `incomplete`) halts —
    fail-safe toward NOT submitting. The pass NEVER emits a submit or contacts a platform. Result in
    `{PENDING-HUMAN-REVIEW, BLOCKED-SCOPE, NO-RESIDUAL, NO-POC, BLOCKED-IMPACT, INCOMPLETE}`, published to the
    durable `coordinator:pass_trace` / `coordinator:pass_result` memos.
  - Offline determinism (the CI path) via a `PASS_FIXTURE` fact (`scope=payable;devise=residual;poc=finding;
    impact=substantiated;dup=low;report=drafted`) — an absent stage key defaults to that stage's PRODUCTIVE token,
    so a partial fixture short-circuits at the divergent stage. The LIVE path exec-shs a per-stage runner
    (mirroring `run_symbolic_live`) with an honest-stub fallback (absent runner -> `incomplete` -> the pass halts).
  - `run-audit-pass.sh` — the bootstrap (sibling of `run-coordinator.sh`): seeds the finding facts + `STAGES` +
    the per-stage runner paths + optional `PASS_FIXTURE`, extends `exec.env_passthrough` to cover every pass var,
    fires ONE `agentis go coordinator.ag` with `PASS_ENABLED=1`, and reads `coordinator:pass_trace`/`pass_result`
    back. NEVER submits (same human-gate contract as `run-audit.sh`).
  - `auditor/scripts/run-gate-agent.sh` — a thin wrapper that runs any single-verdict-line gate `.ag` in a
    throwaway store and echoes its verdict line (used for the five `.ag` gates on the live path; PoC reuses
    `run-poc.sh`).
  - `demo-audit-pass.sh` (CI-safe, wired into `colony-lint.sh`) — source-guards the wiring, then runs the
    deterministic offline pass over three fact-states: full-proceed -> `PENDING-HUMAN-REVIEW`; out-of-scope asset
    -> `BLOCKED-SCOPE` (downstream rows provably absent); simulated-state impact -> `BLOCKED-IMPACT` (dup/report
    absent); and the never-submit invariant.
- **Human<->federation feedback loop — deliver drafts + intake outcomes into learning** (#1526, epic #1505).
  Closes both ends of the loop through a single operator DROP-DIRECTORY (design decision baked in: a LOCAL
  exchange point — no platform API, no gist, no scrape; offline-testable, operator-mediated, human-gated). A
  confirmed finding's report-writer (#1508) draft is staged for a human to file out-of-band; the platform's
  response is written back into the drop-dir and folded into learning, attributed to the gate that owns the
  lesson. Neither component ever submits.
  - `deliver-submission.sh` — the delivery muscle. Stages a report-writer draft under a stable submission id
    `<target>@<in-scope-commit>:<finding-slug>` into `$DROP_DIR/<slug>/` (default
    `${DARK_FACTORY_DIR:-$HOME/.dark-factory}/drop`) with `manifest.json` (canonical `submission_id` + the three
    RAW gate verdict lines + severity + finding metadata + `created_at` + `status`, via `python3 json.dumps`),
    `submission-draft.md` (verbatim), and an `OUTCOME.md` template the operator fills IN-PLACE. It REFUSES
    (exit 3) any draft lacking the `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW` marker — the human-gate invariant baked
    into the muscle — and has no platform egress (exit 0 staged / 2 bad-args / 3 missing-marker). The canonical id
    lives in `manifest.json`, not the editable template or the dirname, so an operator can never break correlation.
  - `auditor/agents/feedback-intake.ag` — the reasoning half (standalone batch agent, mirrors `scope-gate.ag` /
    `impact-gate.ag` / `report-writer.ag`). Env `SUBMISSION_DIR`. A deterministic muscle reads `manifest.json` +
    `OUTCOME.md`; the success/failure/partial signal is DETERMINISTIC from the operator verdict enum
    (`accepted`->success, `closed`->failure, `duplicate`->failure, `needs-info`->partial) so a mis-reasoning
    backend can never flip a payout into a failure. The LLM's only job is to ATTRIBUTE the outcome to the
    responsible stage; it prints `FEEDBACK|<SIGNAL>|<stage>|<rationale>`, then one `learn()` under that gate's OWN
    topic (`dup-scout`->`dup-risk`, others 1:1) with the deterministic signal, plus a
    `dark-factory:feedback_outcome` emit. Reads only the drop-dir; never submits.
  - `demo-feedback-loop.sh` — offline (bash/python3): DELIVERY (real stage + canonical id + raw verdicts + the
    exit-3 marker guard), SIGNAL (the deterministic verdict->signal map over an Enzyme Onyx `closed` fixture +
    a source-guard of the four arms / deterministic-signal `learn()` / impact-gate attribution / emit-learn-memo
    tail), and INVARIANT+LIVE (no platform egress in either component; runs the agent when agentis is present).
    Wired into `tools/colony-lint.sh`.
- **Immunefi intake + post-audit-delta discovery** (#1506, epic #1505). Two independent, offline-testable shell
  primitives that widen the intake funnel toward Immunefi bounties — the residual-surface half of discovery,
  built on the observation (borne out by the confirmed Lombard finding) that an audited protocol's rewardable
  bug almost never lives in the fortified, N-times-reviewed core but in the DELTA that landed AFTER the audit
  froze. NO new `.ag` agent; both are pure transforms, read-only, and never submit.
  - `audit-delta.sh` — a pure `git diff` detector: `--repo <dir> --since <commit-ish> [--paths <file>]` emits ONE
    JSON object (files changed on `<since>..HEAD`, an optional in-scope `--paths` intersection, the most-recent-
    change age in days, and a `DELTA`/`NO-DELTA` verdict). Never crashes on the `since==HEAD` / empty-diff edge
    (NO-DELTA, null age); exits 3 loudly on a non-git-repo / unresolvable `--since` (a shallow-clone miss surfaces
    as an error, never a silent empty delta), 2 on bad args. A general muscle other callers reuse.
  - `run-immunefi-intake.sh` — ranks an OPERATOR-SUPPLIED programs JSON (`--programs`, REQUIRED). **Design
    decision baked in: Immunefi has NO live fetch path, ever** — WebFetch is proven unreliable against the SPA and
    submission is human-gated, so the operator maintains a small static programs file out-of-band. Freshness keeps
    `status` active; scoring is an additive `bounty_term` (0..70, log-scaled) + `delta_term` (0..30, via
    `audit-delta.sh` when a program points at a local clone; 0 for NO-DELTA / no clone — never degenerate); dedup
    on `immunefi:<id>`. Emits the SAME 5-column TSV `run-batch.sh --queue` already consumes (zero changes to
    run-batch.sh), the scope_hint packing chain/repo/commit/delta/fee/vault for a future EV-gating evaluate stage.
  - `demo-immunefi-intake.sh` — ONE offline, deterministic proof of BOTH primitives (mirroring the #1485
    "two primitives + a CI-safe demo" precedent): a throwaway `git init` fixture drives audit-delta through
    DELTA / NO-DELTA / `--paths` intersection / bad-repo+bad-since (exit 3), and an operator-programs fixture
    drives the ranking (paused dropped by freshness, fresh-delta program outscoring an equal-reward NO-DELTA one,
    a no-local_repo program still ranking by bounty alone, file==stdout parity). Wired into `tools/colony-lint.sh`.
- **Submission report formatter in the substrate** (#1508). The stage AFTER scope-gate (#1511), impact-gate
  (#1522) and dup-scout (#1503) and BEFORE the human-gated submit. Once a finding is CONFIRMED, PoC'd, in-scope,
  impact-substantiated and low-dup, the last manual step of every live session was turning the terse verdict
  lines + the PoC into a platform-shaped report a human can read and file — this agent renders that draft.
  - `auditor/agents/report-writer.ag` — standalone dispatched agent (mirrors `impact-gate.ag` / `scope-gate.ag`).
    Env: `FINDING_TITLE`, `FINDING_LOCATION`, `FINDING_IMPACT`, `POC_FILE`, `SEVERITY_BAND`, `SCOPE_VERDICT`,
    `IMPACT_VERDICT`, `DUP_RISK` — the three upstream verdict lines threaded through verbatim. A deterministic
    PoC-read muscle (sed/grep: embed the test run-steps + a code excerpt) grounds the report in the real test.
    It renders exactly four Immunefi-shaped markdown sections — `## Brief/Intro`, `## Vulnerability Details`,
    `## Impact Details`, `## References` — and leads the response with the machine-checkable marker
    `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW`, making the never-submit / human-gated invariant explicit. The
    References section restates the scope/impact/dup verdict lines verbatim as an honest, evidence-based
    novelty/scope note. It NEVER submits — the output is a draft artifact only.
  - `demo-report-writer.sh` source-guards the wiring (CI-safe: env contract, PoC muscle, 4-section scaffolding,
    output marker, never-submits, emit/learn/memo tail) and runs the agent live over a fixture finding + PoC +
    upstream verdict lines when agentis is present; wired into `tools/colony-lint.sh`.
- **Concrete-exploit-sequence PoC generation for hardhat / non-invariant bug classes** (#1507). The SECOND PoC
  class alongside the forge/invariant machinery (`invariant-prover.ag` + `forge-invariant.sh`). Where the
  invariant path writes a stateful-invariant HANDLER and lets the fuzzer JUDGE over randomized SEQUENCES, this
  path writes ONE hand-driven CONCRETE attack-SEQUENCE test that reproduces a specific bug HYPOTHESIS end-to-end
  (set the pre-state, run the exact attack steps, ASSERT the exploit succeeded), covering the classes the
  invariant path does not — HARDHAT projects (a mocha/ethers exploit test) and hand-driven single-`forge test`
  foundry PoCs.
  - `auditor/agents/poc-writer.ag` — NEW standalone-dispatched agent mirroring `invariant-prover.ag` (env
    contract, `verdict_of`/`outcome_of`/`rc_of`, the #1073-shape bounded compile-repair loop, the emit/learn/memo
    tail). Env: `TARGET_FN`, `TARGET_CLASS`, `BUG_HYPOTHESIS`, `POC_KIND` (hardhat|foundry), `POC_REPO`,
    `POC_OUT`, `POC_HARNESS`, `CODE_PATH`, `TARGET_FIXTURES_DIR`, `POC_FIXTURE`, `POC_MATCH`, `POC_REPAIR_ROUNDS`.
    Emits `POC|<target>|<FINDING|CLEAN|HARNESS_ERROR>` + a `POC-FILE|<path>` line on a FINDING (the runnable PoC
    a human executes) and `dark-factory:poc_verdict`. The verdict is the gate's exit code — never the LLM's
    opinion.
  - **INVERTED verdict polarity** — a concrete-exploit PoC is written to PASS iff the exploit works, so the gate
    maps test-passed -> FINDING (exit 1), test-ran-but-failed -> CLEAN (exit 0), compile/tooling error / no test
    ran / linkage reject -> HARNESS_ERROR (exit 2). The inversion lives ENTIRELY in the gates (documented in each
    header, pinned on CI against captured mocha JSON), so `poc-writer.ag`'s `verdict_of(rc)` stays byte-identical
    to `invariant-prover.ag`'s.
  - `evm-harness/hardhat-poc.sh` — NEW hardhat verdict gate: `--repo`/`--target`/`--require-import`/
    `--require-contract` + a `--classify <reporter-json>` parse-only mode; `npm ci` (lockfile) else
    `npm install --legacy-peer-deps`, `npx hardhat compile`, then `npx hardhat test` through a generated wrapper
    config that forces mocha's `json` reporter; classifies the reporter stats with the inverted polarity. Exit
    codes 0/1/2 match `forge-invariant.sh`.
  - `evm-harness/forge-poc.sh` — NEW foundry CONCRETE-exploit gate (thin sibling of `forge-invariant.sh` for a
    single hand-driven `forge test --match-test test`, NOT `invariant`): same #1471 linkage gate + `--skip`
    harness isolation, same inverted-polarity classify (a matched test with status Success -> FINDING).
  - `evm-harness/detect-toolchain.sh` — NEW file-presence helper: `hardhat` (hardhat.config.*) / `foundry`
    (foundry.toml) / `unknown`; the single point where a caller picks hardhat-vs-forge.
  - **Anti-fabrication #1471 linkage gate** for BOTH gates: the generated PoC must reference the REAL target (an
    import/require path ending in the target basename, or — hardhat — a `getContractFactory("<Name>")`/
    `getContractAt("<Name>"` call) AND must NOT shadow it with a same-named toy contract. A miss is
    HARNESS_ERROR, never a verdict, and (hardhat) runs BEFORE any npm spend.
  - `run-poc.sh` — NEW lean operator runner mirroring `run-invariant-hunt.sh`'s rundir staging + `exec.env_passthrough`;
    auto-detects the toolchain and drives `poc-writer.ag` on the substrate. `evm-harness/hardhat-poc-fixture/` —
    NEW committed offline fixture (a real re-entrancy bug + a PoC that reproduces it + a substituted negative + a
    captured pass/fail/empty mocha JSON) exercising the gate's linkage + verdict-parse paths with NO node.
  - `demo-poc-gen.sh` — NEW CI-safe demo (source-guard + `--classify` verdict-parse + linkage-reject on CI; the
    full npm + LLM live paths toolchain-gated and SKIP on CI); wired into `tools/colony-lint.sh`. A confirmed PoC
    is a LEAD a human triages — this colony NEVER auto-submits.
- **Impact-substantiation / validity gate in the substrate** (#1522). The gate AFTER scope-gate (#1511) and
  BEFORE human submit. scope-gate closes the SCOPE wall (in-scope asset + eligible-impact set + not carved-out);
  it is necessary but NOT sufficient. A live Immunefi submission (Enzyme Onyx, `SyncDepositHandler`
  front-running) that PASSED all three scope-gate barriers was still CLOSED on an impact-validity ground: the
  PoC used a SIMULATED price increase (a hand-fed admin `updateShareValue`) and described front-running of a
  PRIVILEGED admin action, not extraction of an on-chain-provable claim the victims already held.
  - `auditor/agents/impact-gate.ag` — standalone dispatched agent (mirrors `scope-gate.ag` / `dup-scout.ag`).
    Env: `FINDING_IMPACT`, `POC_FILE`, `MECHANISM_NOTES`. A deterministic PoC-smell muscle (grep: `harness_set*`,
    mocks, price setters, admin/owner pranks) feeds an LLM judgement over three validity barriers — OWN-MECHANISM
    (vs a simulated critical transition) / NO-PRIVILEGED-TRIGGER (the loss must not need a trusted role to act) /
    PROVABLE-PRE-EXISTING-CLAIM (on-chain, per the protocol's own accounting). Emits exactly
    `IMPACT-GATE|<SUBSTANTIATED|SIMULATED-STATE|PRIVILEGED-TRIGGER|NO-PROVABLE-CLAIM>|<rationale>` — only
    `SUBSTANTIATED` should proceed to human submit. It NEVER submits. Validated live against the real Onyx PoC:
    verdict `PRIVILEGED-TRIGGER`, mirroring the platform reviewer's exact reasoning.
  - `demo-impact-gate.sh` source-guards the wiring (CI-safe) and runs the agent live over a fixture PoC (the Onyx
    simulated-state + privileged-trigger shape) when agentis is present; wired into `tools/colony-lint.sh`.
- **Scope + eligibility gate in the substrate** (#1511). The highest-leverage correctness check in the bounty
  pipeline: a confirmed finding pays NOTHING (and burns the per-report fee + reputation) unless its LOCATION is
  an in-scope asset AND its IMPACT is an eligible, non-excluded, non-audit-noted class. Two live sessions both
  died exactly here — a real bug in an unlisted module (out-of-scope asset) and a real bug in an in-scope asset
  whose impact was an explicit out-of-scope carve-out — so the gate runs BEFORE any DEVISE/PoC spend.
  - `auditor/agents/scope-gate.ag` — standalone dispatched agent (mirrors `audit-scout.ag` / `dup-scout.ag`).
    Env: `SCOPE_FILE` (the program's own scope: in-scope asset list + out-of-scope/known-issues section +
    eligible-impact set), `FINDING_LOCATION`, `FINDING_IMPACT`. The asset-path match is DETERMINISTIC (grep —
    the muscle); the impact/carve-out judgement is the LLM's over that same scope text. Emits exactly
    `SCOPE-GATE|<PAYABLE|OUT-OF-SCOPE-ASSET|EXCLUDED-CARVEOUT|INELIGIBLE-IMPACT>|<rationale>` — only `PAYABLE`
    should proceed. It NEVER submits.
  - `demo-scope-gate.sh` source-guards the wiring (CI-safe) and runs the agent live over a fixture scope when
    agentis is present; wired into `tools/colony-lint.sh`.
- **Audit-aware residual-hunt foundation** (#1485). The reward on a bounty is only in what a target's OWN
  audits MISSED, so the hunt must be audit-aware — a capability the blind auto-gen lacks (it fabricates toys
  or finds already-known issues). Two reliable shell primitives + a CI-safe demo:
  - `fetch-audits.sh <url…>` / `--manifest <file>` — the operator's one network step: download a target's
    public audit reports and `pdftotext` each PDF to text (SKIPs cleanly offline), writing `<out>/NN-*.txt`
    + an `index.tsv`, so the downstream boundary extractor + analyst read them offline.
  - `novelty-gate.sh --exclusion <file> <finding>` — rejects a finding that restates a KNOWN issue (matched
    by a shared target function/identifier plus salient-term overlap) with exit 1, passes a genuinely-novel
    one with exit 0. Errs toward flagging (a maybe-known finding is held for human review, never auto-staged),
    so the engine never surfaces an already-reported bug.
  - `demo-audit-hunter.sh` (pure bash/python3, localhost fetch — no external network) proves both, wired into
    `tools/colony-lint.sh`. This is the reliable mechanical core of the manual audit-driven hunt; the creative
    hypothesis step (analyst) remains a follow-up `.ag` colony layer. Submission stays strictly human-gated.

### Fixed
- **Coordinator submission-pass LIVE-dispatch wiring** (#1535, follow-up from #1534 QA of the #1509 capstone).
  Three gaps that only bit the operator-gated LIVE path (`run-audit-pass.sh`; the CI/offline path uses
  `PASS_FIXTURE` and never reaches the runners), so they were CI-untested and silently normalized the poc and
  devise stages to `incomplete`:
  - **poc CLI args.** `run_stage_live()` invoked every runner env-only, but `run-poc.sh` is CLI-flag driven
    (`--repo`/`--target`/`--hypothesis`/`--class`), not env. Added a poc-specific `run_poc_live()` branch that
    builds the CLI from `POC_REPO`/`POC_TARGET`/`POC_HYPOTHESIS`/`POC_CLASS` via `getenv()`, each `shell_escape()`d
    (already on `run-audit-pass.sh`'s `exec.env_passthrough`); the five `.ag` gates keep the generic env-only call.
  - **`run-poc.sh` `POC|` emit.** `run-poc.sh` only printed the human-facing `POC: <target> -> <verdict>` arrow
    banner (pinned by `demo-poc-gen.sh`), never the machine-readable `POC|<target>|<verdict>` line the coordinator
    scrapes. Added one additive `echo "POC|$TARGET|$VERD"` on stdout; the arrow banner is untouched.
  - **devise `NO-RESIDUAL` extraction.** `run-gate-agent.sh`'s single-prefix `grep -F "$PREFIX|"` dropped
    audit-scout's bare (non-piped) `NO-RESIDUAL` token before the coordinator ever saw it, so a genuine
    no-residual determination normalized to `incomplete`. Fixed at the root by threading a per-stage
    `VERDICT_NEGATIVE` (`NO-RESIDUAL` for devise, `""` elsewhere) into a new `--negative-token` extraction, plus a
    `--classify-log` pure-shell mode for CI. **`audit-scout.ag` is deliberately left UNTOUCHED** — piping the
    token as `NO-RESIDUAL|<reason>` (the alternative the issue sketched) would be a WORSE, silent regression: both
    `audit-scout.ag::outcome_of()` and `coordinator.ag::devise_class()` do UNANCHORED substring checks for
    `"RESIDUAL|"`, which `"NO-RESIDUAL|reason"` matches at offset 3, flipping a true NO-RESIDUAL into
    success/residual.
  - CI coverage: `demo-audit-pass.sh` gains an always-on offline round-trip through `run-gate-agent.sh
    --classify-log` (bare `NO-RESIDUAL` now surfaced, piped `RESIDUAL|` unchanged, omit-the-flag byte-identical)
    and an agentis-gated stub-runner LIVE dispatch (asserts the poc CLI-arg construction + `POC|...|FINDING`
    parsing); `demo-poc-gen.sh` pins the additive `POC|` emit (always-on source-guard + the gated hardhat e2e).
- **hardhat-poc.sh / forge-poc.sh relative-`--repo`/`--target` path doubling** (#1531, follow-up from #1507 /
  #1529). Hand-invoking either gate with a RELATIVE `--repo`/`--target` produced a doubled path
  (`.../hardhat-poc-fixture/hardhat-poc-fixture/...`) and a false `HARNESS_ERROR` — not reachable via the real
  pipeline (`run-poc.sh`/`demo-poc-gen.sh` always pass absolute paths), so it only bit direct manual invocation.
  Both gates now resolve `--repo` (mirroring `run-poc.sh`'s `REPO="$(cd "$REPO" && pwd)"`) and the resolved
  `--target` to absolute paths right after the existence checks, before they are re-referenced inside a
  `cd "$REPO"` subshell. Absolute-path callers are unaffected. `demo-poc-gen.sh` gains two toolchain-gated
  regression checks (relative `--repo`/`--target` from a different cwd for each gate) that reproduce the exact
  pre-fix failure and confirm the fix.
- **novelty-gate false-negative on a bare boundary-function mention** (#1496). `novelty-gate.sh` flagged a
  candidate as KNOWN whenever it shared a single function/identifier token with an exclusion line, even when
  the candidate discussed a completely different vulnerability class — so a genuinely-novel finding that merely
  *mentions* a boundary function (e.g. `withdraw()`) in an unrelated context was wrongly rejected as a
  duplicate. `salient()` now exposes the vuln-class keyword set separately from the identifier set, and the
  shared-identifier shortcut requires an overlapping vuln-class term too (`shared_funcs AND shared_vk`, not
  `shared_funcs` alone); the plain salient-term overlap threshold (`--min-overlap`) is unchanged. Regression:
  a new `residual` row in `bench/fixtures/rounding-residual/truth.tsv` and a new case in
  `demo-audit-hunter.sh`.
- **Invariant-hunt CODE_PATH resolution for nested `--target`** (#1475). `run-invariant-hunt.sh` defaulted the
  LLM source path (`CODE_PATH`) to `<repo>/src/<target-file>`, so a nested `--target` like
  `src/contracts/vault/Vault.sol:Vault` became `<repo>/src/src/contracts/vault/Vault.sol` (double `src/`) →
  `CODE_PATH` stayed **empty**. That both starved the LLM of the target source (it fabricates a toy of the same
  name) and **disarmed the #1471 linkage gate** (which only arms when `CODE_PATH` is non-empty), so the toy
  reached a FINDING instead of HARNESS_ERROR — proven live on a Symbiotic `Vault` run (FINDING against a test
  that imported nothing and declared its own `contract Vault`). Now resolves `<repo>/<target-file>` first, then
  the `<repo>/src/<basename>` convention — nested, `src/`-prefixed, and bare-basename targets all resolve, so
  the gate arms. Regression: `tools/test-invariant-codepath-resolution.sh`.
- **Invariant-hunt target-linkage gate** (#1471). Closes a false-FINDING hole on the invariant-hunt generation
  path: when the real target is hard to harness, the LLM could silently substitute its OWN toy contract of the
  same name and the fuzzer would "find" a bug it planted THERE — a FINDING against fabricated code with zero
  bounty value (proven live: a Liquity BOLD `StabilityPool` run produced a test that imported nothing and
  defined its own 16-line `contract StabilityPool`). `evm-harness/forge-invariant.sh` gains an optional
  `--require-import <target-src>` (+ `--require-contract <Name>`) gate: BEFORE forge runs, the test must carry
  an `import` line whose path ends with the target basename AND must NOT declare its own `contract <Name>`
  shadow (`StabilityPoolHarness` does not trip it) — a miss is `HARNESS_ERROR` (2), never a verdict. The
  prover (`auditor/agents/invariant-prover.ag`) threads the flags in **only in pure fresh-deploy mode** (no
  `FORK_URL`/`FORK_TARGET`/`FORK_CONTEXT`, a real `CODE_PATH`); in any fork/composability mode — where the
  target is referenced by on-chain address, not a source import — no link args are passed and the gate is
  byte-identical to before. `demo-invariant-linkage.sh` source-guards the wiring and runs the gate live when
  forge is present; wired into `tools/colony-lint.sh`.

### Added
- **Snapshot owner-rebind hard assert** (#1455 epic; #1457). Closes the owner-graph fidelity gap in
  snapshot replay: the `poc_snapshot` harness now **reads the account's real on-chain owner** from the
  dump and emits an explicit, machine-checkable `OWNER REBIND: <real owner> rebound to <program>` marker
  instead of a silent rebind (#1462 shipped only a static disclosure text). With `EXPECT_PROGRAM_OWNER`
  (run-audit `--expect-owner <base58>`, on the sandbox `exec.env_passthrough`) the harness **hard-asserts**
  owner-match — a mismatch is refused as `INCONCLUSIVE` (exit 3) *before* the exploit runs, so a re-owned
  copy is never reported VERIFIED. `run-audit.sh` REPRODUCTION.md/report disclosure updated to quote the
  harness's real-owner line + document the hard-assert; RUNBOOK "Known limitations" updated.
  `demo-owner-assert.sh` source-guards the harness + run-audit wiring (CI-safe) and runs the 3 modes live
  when the Solana toolchain is present; wired into `tools/colony-lint.sh`. (The `--poc` control-side
  "demonstrably invoke the target" hardening beyond #852's structural + target-linkage gate stays an
  operator-trust residual, flagged not closed.)
- **Bounty-weighted target prioritization in the prospector colony** (#1455 epic; #1459). The prospector
  qualifies EVM protocols as monitoring targets on three boolean hard gates; this adds a bounty dimension
  that ORDERS the operator's finite manual-review time by expected payout, without changing what qualifies.
  - **`coordinator.ag` bounty dimension** — the coordinator joins an operator-supplied
    `PROSPECTOR_BOUNTY_META` (`<address>|<reward_usd>|<in_scope_commit>`, matched case-insensitively) onto
    each dossier, adding a `bounty` reward figure + the in-scope `commit` the bounty covers. It is public
    program-page data the operator pastes in — **read-only, no egress** (the agent never fetches it) — and
    is **purely informational + for ordering**: the three hard gates remain the sole floor, and a qualified
    target with no bounty metadata still lists (ranked last). cb headroom 150000 → 200000 for the join.
  - **`prospector-queue.sh`** (new) — turns the qualified, bounty-annotated dossiers into an **audit queue
    ranked by expected payout** in the exact `run-batch.sh` TSV (`score<TAB>key<TAB>url<TAB>title<TAB>scope_hint`,
    bounty desc, ties by key asc). `scope_hint` carries `addr:<address>` (run-batch's autoharness resolver
    keys on it) + `commit:<in-scope-commit>` (the "audited the wrong version" 0-payout guard). Reads the
    `prospector:qualified` blackboard live via `agentis memo`, or `--dossiers <file>` offline; SKIPs cleanly
    when empty. `run-batch.sh --queue <this>` then hunts targets highest-payout-first. Submission stays
    strictly human-gated — the bridge has no platform egress and never posts.
  - **`demo-prospector-queue.sh`** (new, CI-safe: pure bash/python3) proves the rank order, that a big
    bounty on a non-qualifying target never enters the queue (gates are the floor), the `--min-bounty`
    floor, that `run-batch.sh` consumes the queue highest-first and stages nothing on a dry hunt, and the
    no-egress guard. Wired into `tools/colony-lint.sh`.
- **Bounty-funnel hardening: quantified impact, reproduction manifest, dedup + impact triage gates**
  (#1455 epic; #1456, #1457, #1458). Raises the *expected value per verified finding* — the funnel
  stage between `Verdict: VERIFIED` and a paid bounty — while keeping submission strictly human-gated
  (the colony still never posts to a platform).
  - **#1456 quantified impact in `report.md`** — `auditor.ag` now derives the funds-at-risk the
    two-sided PoC demonstrated (from the observed `account.lamports` / `vault.balance` markers, not a
    template constant) into a new `## Impact quantification` section, plus `Impact category` and
    `Severity rationale` table rows that map the finding onto the Immunefi severity bands. Immunefi pays
    on demonstrated fund-loss, not on a violated invariant; a marker-less (e.g. EVM/revm) run degrades to
    an explicit "quantify against the live deployment" note. New SHALLOW leaves `marker_int`,
    `funds_at_risk`, `impact_category_for`, `rubric_line_for`.
  - **#1457 reproduction manifest + owner-rebind disclosure** — `run-audit.sh` stages `REPRODUCTION.md`
    in the submission package: target sha256, harness kind, `rustc`/`cargo`/`agentis` versions,
    backend/sandbox, and a deterministic rerun command, so a platform triager can reproduce against the
    live deployment. On a snapshot-based run BOTH `REPRODUCTION.md` and the generated `report.md`
    snapshot-replay section now **disclose the account-owner rebind** (the harness program is not deployed
    on-chain) rather than shipping a silent mismatch, so the human states it up-front and re-verifies
    against real program-derived ownership before submitting. Also corrects the stale RUNBOOK
    "Known limitations" note: a supplied `BOUNTY_POC`/`--poc` is already gated by the #852 structural +
    per-run target-linkage challenge (a target-agnostic marker-printer is REJECTED as INCONCLUSIVE, not
    VERIFIED); only a sophisticated link-but-never-invoke PoC remains an operator-trust residual.
  - **#1456/#1458 triage gates in `submit-triage.sh`** — the scan gains an **IMPACT** column
    (`quant` / `qual?`) and, with a new `--known-issues <file>` public-disclosure list, a **NOVELTY**
    column that flags an already-disclosed finding as `DUP-RISK` instead of silently `READY` (Immunefi
    pays only the first reporter). The per-candidate checklist gains repro-manifest, impact-quantification,
    and dedup review items. Also fixes `severity_of` to read the real `| Severity (Immunefi) | … |` table
    row (it previously only matched a plain `Severity: …` line). Covered by `demo-submit-triage.sh`
    (offline, deterministic — no agentis, no network). Follow-ups tracked on the epic: the harness-level
    owner-match *assertion* for snapshot replay (the offline disclosure landed here; the hard assert needs
    the Solana toolchain) and bounty-weighted target prioritization in `prospector` (#1459).
  - **Review-driven correctness fix + regression tests (PR #1462)** — `marker_int` is now **line-anchored**
    (mirrors the harness `field()`'s `strip_prefix`) so `account.lamports=` never shadow-matches inside a
    longer key like `token_account.lamports=` in a multi-account dump; previously it could report a
    funds-at-risk figure that diverged from what the attached PoC drains. Added `demo-report-quality.sh`
    (agentis-gated, clean-SKIP on runners without the binary): a real `run-audit.sh --backend mock` VERIFIED
    run asserting the `report.md` impact rows/section, the `REPRODUCTION.md` sha256 + rerun command, the
    snapshot quantified-vs-qualitative split, the owner-rebind disclosure, and the multi-account regression.
    Extended `demo-submit-triage.sh` to cover INCOMPLETE-over-DUP-RISK precedence, the `dup_hit` body-match
    path, the `has_repro` present/MISSING checklist value, a no-trailing-newline known-issues line, and
    `severity_of` word-anchoring (17 assertions). `severity_of` now matches the severity WORD (`grep -iowE`)
    so an unrelated substring on a third-party report (`high`light / al`low` / be`low`) is not misread.
    `demo-report-quality.sh` (agentis-gated) additionally asserts the `shell_escape` command-injection
    defense end-to-end (a metacharacter-laden `BOUNTY_SNAPSHOT` does not execute) and the zero-value marker
    edge (`account.lamports=0` → Qualitative, not a fabricated figure). All three demos are wired into
    `colony-lint` so the CI-runnable checks (bash triage gates + source-level branch coverage) gate merges.
  - **Security hardening (PR #1462 review)** — `funds_at_risk` and `snapshot_state` now wrap the
    `BOUNTY_SNAPSHOT` path in `shell_escape()` before the `cat` in `exec sh` (replacing the
    `safe-exec-concat` waiver), so a hostile snapshot path (e.g. `x; touch pwned` set directly in an
    automation context) cannot inject a shell command. Verified: with a metacharacter-laden value the
    injected command does not run. The value is normally operator-supplied and `-f`-validated by
    `run-audit.sh`, but escaping closes the direct-env-set path too.
- **monitor: read robustness — RPC failover + read consensus, and a watch-spec drift detector** (#1098, #1097).
  Two hardening passes that keep a 24/7 read-only watch honest. NON-custodial / read-only throughout
  (`cast call` / `cast storage` / `cast balance` / `cast code` only — never a signed transaction, never fund
  access); all dynamic values `shell_escape()`d in the `.ag` and quoted in the scripts; big-number-safe (values
  stay strings; no i64 overflow); dash-safe + `set -eu` + shellcheck-clean scripts.
  - **#1098 RPC failover + read consensus** — `monitor/scripts/cast-read.sh` is now the ONE place chain reads
    happen, so failover lives in a single wrapper instead of being copy-pasted across the six watchers'
    `read_uint` / `read_view` / `read_slot` / `read_balance`. It reads a comma-separated `MONITOR_RPC_URLS`
    (falling back to the single `MONITOR_RPC_URL`), tries each endpoint IN ORDER on failure, and — when
    `MONITOR_RPC_CONSENSUS` is set (`1` ⇒ quorum 2, or any `N>=2`) — requires N endpoints to AGREE on the value
    before returning it, so a single lying / lagging node cannot drive a false `violated`. When ALL endpoints
    fail (or consensus can't be reached) it returns the no-read sentinel (empty stdout + non-zero exit),
    DISTINCT from a real verdict and feeding the dead-man's-switch / blind path (#1093). Read-only allowlist:
    only `call` / `storage` / `balance` / `code`; any write subcommand is rejected. The six watchers route
    through it via `MONITOR_CAST_READ` (defaulted to the colony's `scripts/cast-read.sh` by `start-colony.sh`);
    with `MONITOR_RPC_URLS` / `MONITOR_RPC_CONSENSUS` unset a single configured endpoint behaves exactly as
    before.
  - **#1097 watch-spec drift detector + re-derivation hook** — `run-live-watch.sh` now records a fingerprint of
    the deployed target at derivation time next to the spec at `<spec>.fingerprint.json`: the deployed-code hash
    (`cast code`) and the EIP-1967 implementation slot value (`cast storage`). `monitor/scripts/check-drift.sh`
    (a periodic job / cron) re-reads that fingerprint through `cast-read.sh` (so the failover + consensus apply)
    and raises a `monitor:alert` (kind `drift`, severity `high`, verdict `spec-stale`) when the deployed code /
    impl no longer matches — the monitor SAYS it has gone blind on a stale spec rather than silently watching
    stale invariants. No drift ⇒ quiet; a blind RPC re-read ⇒ quiet (never a false drift); an empty captured
    fingerprint ⇒ quiet. The optional re-derivation hook is documented as `run-live-watch.sh --rederive` (re-run
    the derivation to produce a fresh spec + fingerprint and hot-swap `MONITOR_INV_SPEC`; operator-gated).
  - New env contract (`MONITOR_RPC_URLS` / `MONITOR_RPC_CONSENSUS` / `MONITOR_CAST_READ`) is exported by
    `monitor/scripts/start-colony.sh`, documented in `monitor/config/colony.example.toml` (env block +
    `[monitor]` `rpc_urls` / `rpc_consensus` keys), and in `monitor/README.md` (env table + a "Read robustness"
    section and a "Watch-spec drift detection" section). Operators add each new `MONITOR_*` var to
    `exec.env_passthrough` in `.agentis/config`.
- **monitor: multi-tenant / fleet layer** (#1099) — `monitor/fleet.sh` (dash-safe, `set -eu`,
  shellcheck-clean) manages N watched targets as a NEW layer over the unmodified
  `monitor/scripts/start-colony.sh`: each target gets an isolated slot under
  `${MONITOR_FLEET_DIR:-$HOME/.agentis-monitor}/<slug>/` holding its own `target.env` (address, chain, RPC,
  webhook(s), watch-spec, tiers) and its own `.agentis` state (private daemon registry + memo baselines +
  logs), so targets never collide and an alert for target A never routes to target B's webhook. Subcommands
  `add` / `start [--all]` / `stop [--all]` / `list` / `status` / `path`; `stop` scopes the shutdown per-target
  via `kill-federation.sh --fed-dir`. New `monitor/config/target.example.toml` per-target config-unit template
  and `monitor/docs/fleet.md` operator notes (isolation model, per-target dashboard scoping). NON-custodial /
  read-only — the fleet only orchestrates the read-only colony.
- **monitor: backtest / calibration harness + scorecard + operator runbook** (#1101, #1102) — the Path C
  outreach proof. `monitor/backtest.sh` (dash-safe, `set -eu`, shellcheck-clean) points the
  `invariant-watcher`'s deterministic verdict logic at a fork pinned to HISTORICAL block heights around a
  known incident and replays it tick-by-tick via read-only `cast call --block <N>`, reporting (a) the PAGE
  at/before the incident block with its lead time and (b) a quiet pre-incident window's false-positive
  count/rate; it reuses the watcher's read path + verdict tokens (`violated`/`margin`/`ok`/`no-read`) and the
  fuse-to-worst SET rule byte-for-byte, accepts the same watch-spec `run-live-watch.sh` emits (`--spec`) or
  the single-invariant flags, and degrades gracefully (clear message, exit 4, no crash) without an archive
  node. `monitor/scorecard.md` is the credibility-artifact template (incident, lead time, which watcher
  fired, quiet-window false-positive rate), the monitoring peer of `evm-scorecard.md`. `monitor/docs/runbook.md`
  is the operator runbook: onboard a target (`run-live-watch.sh` → watch-spec → tiers → start → shadow→propose
  promotion → backtest), read an alert (verdict meanings, severity routing, ack/escalation via `notify.sh`
  #1094), respond (triage, when to page the client, dead-man's switch, postmortem template), and scope & SLA
  (non-custodial read/alert/report boundary, response-time tiers, supported + out-of-scope). NON-custodial /
  read-only throughout (`cast call` only — never a signed transaction, never fund access).
- **monitor: governance / upgrade + liquidity / flow / pause-state watchers** (#1095, #1096). Four more
  read-only, tier-gated watcher agents feed the monitor coordinator's `monitor:signal:*` blackboard, each with
  the same ADR-0001 emission pattern as `invariant-watcher` / `oracle-watcher` (one `tier()` call per tick,
  branch once; `cb 90000` matches `cb_budget`; `<agent>:last_check` written at the start AND end of every tick;
  a baseline learned via a durable memo; degrade-safe — no reader ⇒ `no-read` ⇒ no false flag; every `exec sh`
  dynamic value `shell_escape()`d). NON-custodial / read-only throughout (`cast call` / `cast storage` /
  `cast balance` only — never a signed transaction, never fund access).
  - **#1095 `governance-watcher.ag`** — the highest-value PRE-exploit early-warning. Reads the two canonical
    EIP-1967 storage slots (implementation `0x360894…d382bbc` + admin `0xb53127…5d6103`) via `cast storage`,
    plus an optional `owner()`/`admin()` view, a role-grant indicator, and a timelock-queue indicator via
    `cast call`, and flags a CHANGE vs the learned per-field baseline (an impl-slot flip / a new admin or owner /
    a role grant or pending timelock op — the upgrade-attack tell). Verdict tokens `impl-changed` /
    `admin-changed` / `owner-changed` / `gov-changed` / `ok` / `no-read`. Posts `monitor:signal:governance`.
  - **#1096 `liquidity-watcher.ag`** — reads a pool / vault reserve or TVL proxy (`totalAssets()` or, with no
    view configured, native `cast balance`) and flags a drop beyond a learned band (`MONITOR_LIQ_DROP_BP`) — a
    sudden drain; a rise is never an anomaly. Verdict `drained` / `ok` / `no-read`. Posts
    `monitor:signal:liquidity`.
  - **#1096 `flow-watcher.ag`** — reads the same level proxy and flags an abnormal net outflow burst over a
    window (a net fall since the previous reading exceeding `MONITOR_FLOW_OUT_BP` of the held reserve). Verdict
    `outflow-burst` / `ok` / `no-read`. Posts `monitor:signal:flow`.
  - **#1096 `pause-state-watcher.ag`** — reads the `paused()` / circuit-breaker boolean and flags a state
    transition vs the learned baseline (a protocol pausing itself is signal; a recovery is surfaced too).
    Verdict `paused` / `unpaused` / `ok` / `no-read`. Posts `monitor:signal:pause`.
  - `coordinator.ag` now fuses the four new `monitor:signal:*` kinds into the consolidated severity score, the
    dedup signature, AND a per-signal dossier (the emitted `monitor:alert` carries a `"signals"` map of every
    watcher's verdict), alongside the existing `invariant` / `oracle` signals — keeping its single-`tier()`-per-
    tick discipline; the fusion math is a watcher-agnostic `reduce` over the signal list.
  - All four agents are registered in `monitor/config/colony.example.toml` (`[[agents]]`, `cb_budget` matching
    `cb`) and `monitor/scripts/start-colony.sh` (`AGENTS`, `tick_interval_for`, and the `MONITOR_GOV_*` /
    `MONITOR_LIQ_*` / `MONITOR_FLOW_*` / `MONITOR_PAUSE_*` env exports). The new env contract is documented in the
    config, `monitor/README.md` (agent table + mermaid + env table + a per-watcher section), and the `[monitor]`
    comment block. Operators add each new `MONITOR_*` var to `exec.env_passthrough` in `.agentis/config`.
- **monitor: alert-delivery pipeline — the bus→webhook bridge, liveness, and a hardened sink** (#1092, #1093,
  #1094). The monitor colony emitted `monitor:alert` on the bus but nothing forwarded it, so in a real
  deployment no page was ever delivered. A new `notifier` agent (`dark-factory/monitor/agents/notifier.ag`,
  `cb 90000`) closes that last-mile gap:
  - **#1092 bus→webhook bridge** — the `notifier` `listen()`s for `monitor:alert` and forwards each alert to
    `scripts/notify.sh` via `exec sh`. The alert JSON is passed through an exported env var
    (`MONITOR_ALERT_BODY`), never interpolated into the shell text, and every other dynamic value is
    `shell_escape()`d. Forwarding is gated purely on the agent's ADR-0001 tier (one `tier()` call/tick, branch
    once); needs `--enable-messaging` + `--enable-exec` (wired into `start-colony.sh` + registered in
    `config/colony.example.toml`).
  - **#1093 heartbeat + dead-man's switch** — a periodic low-severity `heartbeat` is sent through `notify.sh`
    at `MONITOR_HEARTBEAT_INTERVAL_S` cadence (default daily) so silence is meaningful; and a memo-freshness
    dead-man's switch emits a `high`/`liveness` meta-alert when no watcher tick / fresh `*:last_check` memo is
    observed within `MONITOR_DEADMAN_WINDOW_S` (the RPC-blind / colony-down case), deduped against the last
    liveness signature so a persistent outage pages once.
  - **#1094 hardened `notify.sh`** — bounded exponential retry/backoff on a transient webhook failure
    (`5xx`/network; a `4xx` is not retried); sink-side dedup keyed on the alert signature with a cooldown
    window (`MONITOR_NOTIFY_DEDUP_COOLDOWN_S`, persisted to a small state file); and severity routing so
    `warn`/`high` land in different channels (`MONITOR_WEBHOOK_URL_WARN` / `MONITOR_WEBHOOK_URL_HIGH`, each
    falling back to `MONITOR_WEBHOOK_URL`). Dash-safe (`set -eu`, shellcheck clean, no `\xHH` escapes). Unset
    config preserves the original single-webhook stdout-fallback behaviour exactly.

  Non-custodial / read-only throughout: the notifier only reads the bus and sends an outbound notification — it
  never signs and never touches funds.

### Fixed
- **monitor: big-number-safe wei handling in `invariant-watcher` / `oracle-watcher`** (#1109). The two CORE
  watchers still read on-chain quantities through a bare `parse_int`, which SATURATES any value above i64 max
  (9223372036854775807 ≈ 9.22 ETH at 18 dp) to `0`. `invariant-watcher` reads solvency-grade magnitudes like
  `totalAssets()` / `totalSupply()` (a real $100M vault ≈ 1e26 wei), so BOTH sides read as `0`,
  `verdict_of(0, 0, ge)` returned `ok`, and the watcher reported EVERY real protocol healthy regardless of true
  state — solvency-blind on essentially every live target (confirmed: `parse_int("176142539498998091993593571")
  = 0`). The margin band `(|lhs - rhs|) * 10000 / rhs` separately overflowed i64 for any in-range 18-digit side.
  `oracle-watcher` shared the same `reading_to_int` + `(diff * 10000) / base` deviation pattern (mostly escaping
  for 8-dp prices, but unsafe for large / high-decimal feeds). Both watchers now mirror the proven #1095 /
  liquidity-watcher / value-scorer idiom: read each side as a validated DECIMAL STRING (`reading_to_dec` /
  strip-leading-zeros / digits-only validate / `""` no-read sentinel); SCALE >18-digit values down by truncating
  the same number of low-order digits from BOTH (the relation / ratio is preserved; the `""` sentinel survives
  scaling, so cold-start and RPC-blind ticks never false-fire or divide by zero) BEFORE any `parse_int`; and
  compute the basis-point margin / deviation DIVISION-FIRST (`unit = rhs / 10000`; `gap_bp = diff / unit`) so
  there is no large multiply to overflow. `oracle-watcher`'s sanity BOUNDS now compare the un-scaled price
  digit-string against MIN/MAX with the big-decimal comparator (exact for high-decimal feeds). The
  single-invariant `tick()` path, the `MONITOR_INV_SPEC` multi-invariant SET path (`spec_verdict` / `fuse_set`),
  and the alert/signal payloads (which now carry the full magnitudes as quoted JSON strings, like
  liquidity-watcher's `value_for_json`) are all big-number-safe. Everything else is preserved: one `tier()` per
  tick + branch once, `cb 90000`, `<agent>:last_check` at tick start + end, `shell_escape()` on every `exec sh`
  value, the `cast-read.sh` / `MONITOR_CAST_READ` failover read path, the no-read (`""` / `-1`) and cold-start
  sentinels → no false flag, non-custodial read-only. Verified via `agentis repl` with real 1e26 magnitudes: a
  solvent vault (`totalAssets = 176142539498998091993593571` ≥ `totalSupply = 149658545051669083717603536`, rel
  `ge`) now yields `ok` (was a false `0`-based `ok`), the same magnitude underwater (assets < shares) yields
  `violated` (was a false `ok`), a thin-margin case yields `margin`, and cold-start (`-1`) / no-read (`""`) yield
  no flag and no div-by-zero; `oracle-watcher` flags a 5% move on an 18-dp feed as `deviation` (`dev_bp = 500`,
  was blind) and bounds-violations on high-decimal feeds as `bounds`.
- **monitor: big-number-safe wei handling in `liquidity-watcher` / `flow-watcher`** (#1095, #1096). Both
  watchers read an on-chain reserve / level (a TVL proxy in wei) and fed it through a bare `parse_int`, which
  SATURATES any value above i64 max (9223372036854775807 ≈ 9.22 ETH at 18 dp) to `0` — so a 1000-ETH vault
  (1e21 wei) baselined at `0`, and a real drain to 1 ETH read as verdict `ok`: the drain was invisible on
  essentially every real target. The basis-point ratio `(base - reserve) * 10000 / base` separately overflowed
  i64 for any drop past ~0.001 ETH on an 18-dp token, computing `drop_bp = 0`. Both watchers now keep the
  reading + baseline as DECIMAL STRINGS (reusing the prospector `value-scorer`'s big-decimal idiom), SCALE both
  down to ≤18 digits by truncating the same number of low-order digits from BOTH before any `parse_int` (the
  ratio is preserved; the "" no-read / no-baseline sentinel survives scaling, so cold-start and RPC-blind ticks
  never false-fire or divide by zero), and compute the basis-point drop DIVISION-FIRST (`unit = base / 10000`;
  `drop_bp = diff / unit`) so there is no large multiply to overflow. The baseline is persisted as the same
  digit string it is compared in, and the alert/signal payloads carry the full wei magnitudes as JSON strings.
  Verified via `agentis repl`: a 1000-ETH baseline drained to 1 ETH now yields `drained` with `drop_bp ≈ 9990`
  (was `ok`/`drop_bp = 0`), an in-range 5-ETH→2.5-ETH drop yields `drop_bp = 5000`, and cold-start / no-read
  yield no flag.
- **monitor: JSON-escape free-text fields in alert/signal payloads** (#1089). `invariant-watcher` and
  `oracle-watcher` now route the operator-supplied `label`/`addr` through a `json_escape()` helper (escapes
  `\` and `"`) in every alert/signal payload builder, so a label containing a `"` can no longer corrupt the
  emitted JSON. Per-char fold (`.ag` has no string-replace builtin). Verified via `agentis repl`:
  `json_escape("a\"b\\c")` → `a\"b\\c`.
- **`flat-cyborg-claude.sh` uses `--extract-structural`** (#1083, needs flat-cyborg ≥ 0.10.2). claude
  intermittently omits the reply sentinel; strict `--extract` then burned the full `--timeout-ms` and exited
  "no fenced reply", which the agentis caller retried — repeated ~700 s gen hangs ending in HARNESS_ERROR
  (several sweep TIMEOUTs traced to exactly this). With flat-cyborg #55 (v0.10.2), `--extract-structural`
  completes on a SETTLED screen and recovers the reply marker-first → structural-fallback (fast +
  marker-less-tolerant); a marker-ful reply is extracted exactly as before.
- **invariant-prover cuts false-positive findings — realistic input bounds + mocked-dep decimal/type fidelity**
  (#1080, epic #1041). A real autonomous sweep produced two FINDINGs that triaged to harness artifacts, not
  bugs: an oracle target's unbounded price-setter let the fuzzer drive the price to absurd magnitudes
  (`2.26e30`) and trivially break a sanity-band invariant; and a mocked dependency used 18 decimals while the
  target computes that token in 6 (10^12 mismatch) → a spurious solvency break. The `generate_test()` prompt
  now directs the model to (a) `_bound` every fuzzed input — ESPECIALLY external-perturbation actions
  (price/oracle/deviation/donation/fee setters) — to a REALISTIC range, and that a break caused SOLELY by an
  absurd-magnitude input is NOT a finding; and (b) make every mock of an external dependency MATCH the real
  units/decimals/types the target assumes (read from the target source) — a mismatched mock is invalid.
  Regression guard: `tools/test-invariant-prover-false-positives.sh`.
- **invariant-hunt SLIMS the embedded contract source(s) in the generation prompt** (#1079, epic #1041). On a
  real autonomous sweep every cross-contract PAIR (two full contract sources in ONE gen prompt) and one complex
  single-contract target hit the per-run timeout: the flat-cyborg→claude generation hung on a SINGLE gen call
  for ~712 s because the prompt embeds the FULL source of each contract (a pair ≈ 90 KB of Solidity), so all
  cross-contract coverage was lost. The OUTPUT ask was already bounded (#1067); this slims the INPUT.
  `run-invariant-hunt.sh` now stages the target source (`CODE_PATH`) and each `--aux` source (#1075) through a
  portable awk Solidity-source SLIMMER (`slim_sol_source`) instead of a flat `cp`: it drops `//`/`///` line
  comments (full-line + safe trailing), `/* ... */` block comments INCLUDING multi-line NatSpec `/** ... */`
  (a single-pass block-comment state machine — a naive sed cannot span lines robustly), `import ...;` and
  `pragma ...;` statement lines, and squeezes runs of blank lines to one — while KEEPING every line of real
  callable surface + logic: the `contract <Name> is ...` declaration, state variables, every function signature
  AND body, and structs/enums/events/errors. The prover's contract is unchanged — it still `cat_file`s the same
  staged `CODE_PATH`/aux paths and the generation prompt's STRUCTURE is identical; only the embedded source
  content is smaller (roughly halved on heavily-NatSpec'd sources). Trailing-comment stripping is CONSERVATIVE:
  a `//` is stripped from a code line only when no quote (`"`/`'`) precedes it on that line, so a `//` inside a
  string literal is NEVER corrupted (correctness of the staged Solidity over maximal slimming). An empty-output
  guard never ships an empty / truncated `CODE_PATH`: a pathological all-comments/all-import source that slims to
  only blank lines falls back to the ORIGINAL verbatim. A new deterministic guard,
  `tools/test-invariant-hunt-slim-source.sh`, feeds a fixture `.sol` (every comment/import/pragma/blank-run noise
  class + real `contract`/state/function/struct/event/error code) through the live slimmer and asserts the noise
  is removed, the real code survives intact, a string-literal `//` is preserved, and the empty-output fallback
  fires — plus that the runner wires the slimmer into BOTH stagings (grep/awk over the runner, no LLM/forge).
- **invariant-prover ENFORCES both-real cross-contract deployment (composable-fresh)** (#1077, epic #1041). In
  composable-fresh mode (#1075, `INV_AUX` non-empty) the LLM was supposed to deploy + wire the target AND each
  aux contract REAL. Validation on two real pairs showed it instead deployed only the EASIER contract real and
  MOCKED/OMITTED the harder one (`--target dreUSDs --aux dreRewardsDistributor` → real distributor + a
  `RewardVaultMock`; `--target dreUSDManager --aux dreUSDOracle` → real oracle, manager never imported). A CLEAN
  on a harness that mocked the unit-under-test is a FALSE verdict. `auditor/agents/invariant-prover.ag` now
  enforces both-real via validation + targeted repair (reusing the #1073 loop) — NOT a Solidity-parsing deploy
  scaffold, and ONLY active in composable-fresh mode (the #1070-B1 single-target path is byte-identical, the
  offline `HANDLER_FIXTURE` path is untouched). A `missing_real_deploys(testSrc, names)` helper reports, over the
  `{target name} ∪ {each aux name}` set, every contract MISSING BOTH an `import {<name>}` marker AND a
  `new <name>(` marker (the latter covers the plain `new` form and the `new ERC1967Proxy(address(new <name>()...`
  proxy form) — i.e. dropped or mocked. The #1073 repair trigger is EXTENDED: a round also fires when
  composable-fresh AND `missing_real_deploys(...)` is non-empty, with a POINTED repair prompt that names the
  missing contracts ("Your test did NOT deploy these REQUIRED real contracts (you mocked or omitted them): …")
  and tells the model to keep the ones already real. After the `INV_REPAIR_ROUNDS` budget is exhausted, a
  RESIDUAL both-real violation FORCES the emitted verdict to `HARNESS_ERROR` (with a stderr reason: "harness
  mocked/omitted required real contract(s): …") — even if the gate returned CLEAN/FINDING on the partial harness
  — so a FALSE cross-contract CLEAN can never leak; a genuine FINDING/CLEAN on a harness where ALL named
  contracts are real passes through unchanged, and the gate exit code stays the source of FINDING/CLEAN when
  both-real holds. The both-real check is pure string work on the (untrusted) test source (no shell), the loop
  stays bounded by the existing single-assignment recursion (no `while`/`for`), and the stderr reason is
  `shell_escape()`d. A new deterministic guard, `tools/test-invariant-prover-both-real.sh`, pins the both-real
  check, the extra repair trigger, the pointed message, the force-`HARNESS_ERROR`-on-residual-violation override,
  and the single-target/fixture exemption (grep over the `.ag`, no LLM/forge).
- **invariant-prover drives the REAL target, not a mock** (#1070-B1, epic #1041). The live-path generation
  instruction in `auditor/agents/invariant-prover.ag` (`generate_test()`) used to tell the model: import the
  target "if the project ships it there; otherwise inline a minimal copy." On a realistically-sized target the
  model frequently inlined a MOCK of the unit under test and fuzzed the mock, so the FUZZER's verdict was about
  fake code, not the real contract. The bullet is now a STRONG real-target directive — IMPORT and DEPLOY the
  REAL contract under test; a minimal mock of an EXTERNAL dependency (an ERC20 asset, an oracle) is fine, but
  the unit under test MUST be the real imported contract — plus `setUp()` deploy guidance for both a normal
  `constructor(args)` and an OpenZeppelin **upgradeable** contract (an `ERC1967Proxy` +
  `abi.encodeCall(<Target>.initialize, ...)` recipe for the `_disableInitializers()` case). The agent also
  computes the exact relative import path (`CODE_PATH` relative to `dirname(INV_OUT)` via
  `realpath --relative-to`) and injects it as an `import {<Name>} from "<RELPATH>";` line so the model wires
  the import correctly; when no target source is supplied the import-path line is skipped (today's behaviour).
  The #1067 bounding is preserved unchanged — EXACTLY ONE lens-driven invariant + a minimal handler under the
  `~120-line` budget (the real-deploy `setUp()` now counts toward that budget). A new deterministic guard,
  `tools/test-invariant-prover-real-target.sh`, pins the real-target directive + the proxy recipe + the
  import-path injection (grep over the `.ag`, no LLM). The compile-repair loop is a separate follow-up.
- **invariant-prover bounded compile-repair loop** (#1073, epic #1041). With #1069 harness-isolation, a
  `HARNESS_ERROR` (forge exit code not in {0,1}) on the **LLM-generated** path means OUR generated handler
  failed to compile / matched no `invariant_*` — a recoverable fault, not the target's other tests. The prover
  used to do ONE shot (generate → write to `INV_OUT` → run `forge-invariant.sh` → map the exit code to a
  verdict), so a single bad first generation wasted the whole run. `auditor/agents/invariant-prover.ag` now
  runs a BOUNDED compile-repair loop: on a `HARNESS_ERROR` it extracts a capped compiler-error excerpt from
  forge's output, feeds it back to the model with the prior test source (a `repair_instruction()` reasserting
  the same hard constraints — `pragma ^0.8.20`, no forge-std, `targetContracts()`, plain `require()`,
  `<matchPrefix>_*` naming, import+deploy the REAL target, output-only), writes the repaired source through the
  SAME `shell_escape()`d `printf` mechanism (never a heredoc — the test is untrusted), and re-runs the gate.
  The loop is a bounded recursion (single-assignment `.ag` has no `while`/`for`) carrying the
  `(stopped, testSrc, runOut)` state, with the round count from `getenv("INV_REPAIR_ROUNDS")` (default **2** —
  so ≤3 total attempts — on unset/empty/non-numeric; `0` disables repair = today's one-shot). It STOPS the
  moment the gate returns a real verdict (`FINDING`/`CLEAN`), and the verbatim `HANDLER_FIXTURE` path is NEVER
  LLM-repaired (the fold is seeded already-stopped when `usedFixture`). The FINAL emitted verdict, the
  `learn()`/experience outcome, and the `INVARIANT|<file:fn>|<token>` line stay the gate's exit code on the
  LAST attempt — never the LLM's opinion (unchanged contract). `run-invariant-hunt.sh` gains a
  `--repair-rounds N` flag that threads `INV_REPAIR_ROUNDS` through. A new deterministic guard,
  `tools/test-invariant-prover-repair-loop.sh`, pins the loop (grep over the `.ag`, no LLM/forge).

### Added
- **`prospector` colony — qualify EVM protocols as monitoring targets by public on-chain/source signals**
  (#871). A new colony alongside `monitor` + `auditor` that takes a list of candidate EVM protocols and decides
  which ones are worth standing up the `monitor` colony on, and why. NON-custodial / read-only: every agent only
  READS public source/ABI + on-chain state via `cast`/explorer over `exec sh` (each dynamic value
  `shell_escape()`d) — no agent signs a transaction or touches funds, and the value-scorer uses ONLY `cast call`
  / `cast balance` (never `cast send` / a key / a write-RPC). The qualification verdict is a FACT (a source/ABI
  read + a read-only on-chain value read + a deterministic comparison), never an LLM opinion. This PR ships the
  lint-clean foundation: the colony scaffold (`prospector/{agents,config,scripts,README.md}`, `[forge] type =
  "none"` per ADR-0003), the four agents, and the confidence-tiered qualification pipeline.
  - `prospector/agents/intake.ag` — ingests the candidate protocol list from `PROSPECTOR_CANDIDATES` (newline
    `<address>|<chain>[|<metadata>]` cells), validates (`0x` + 40 hex address, integer chain id) + dedups each
    candidate, and writes the normalised `prospector:candidates` blackboard memo.
  - `prospector/agents/source-classifier.ag` — for each candidate reads its verified function-signature surface
    via a configured reader command (`PROSPECTOR_ABI_CMD`, e.g. `cast interface` or a keyless Sourcify ABI fetch;
    the address/chain reach the reader as exported env vars, never interpolated) and classifies whether it
    exposes a DeFi value-invariant family (lending / vault-4626 / AMM / stablecoin / perps / staking / bridge) —
    the monitorability gate. Posts `prospector:classified:<addr>`.
  - `prospector/agents/value-scorer.ag` — for each candidate reads a read-only on-chain value proxy (a `cast
    call` view such as `totalAssets()`, or the contract's native `cast balance`) and decides whether it clears a
    configured value floor — the value-floor gate. The value + floor are compared as BIG-DECIMAL strings (a TVL
    in wei exceeds i64, which `parse_int` cannot hold and which corrupts JSON number parsing downstream), so the
    digit strings are compared digit-wise and carried as JSON strings. Posts `prospector:value:<addr>`.
  - `prospector/agents/coordinator.ag` — fuses the three HARD GATES (verified-source + DeFi-value-invariants +
    value-floor) into a per-target qualification verdict and writes the `prospector:qualified` dossier (per-target:
    qualifies yes/no, the matched family, the failed gate when any, and the suggested invariant to watch — the
    handoff to the `monitor` colony, phrased in the monitor's `MONITOR_INV_*` terms) plus a ranked
    qualifying-target index. Single-assignment helpers, reduce/bounded-recursion (no loops), per the
    `auditor`/`monitor` coordinator pattern.
  - **Confidence-tiered qualification (ADR-0001) as the false-positive control.** Every agent makes ONE `tier()`
    call per tick and branches once; the tier gates PUBLICATION only (the verdict is identical at every tier):
    `shadow`/`dormant` score + write the dossier (no publish), `propose` emits a draft shortlist, `review-gated`/
    `autonomous` publish the ranked dossier index. `cb <N>;` matches `cb_budget`, and every tick begins + ends
    with `memo_write("<agent>:last_check", now)`.
  - `prospector/scripts/start-colony.sh` — ADR-0003-conformant daemon launcher (symlink-safe `$0`, sources
    `parse-toml.sh`, exports the `PROSPECTOR_*` env contract, `--restart-agent`, allowlisted daemon flags).
  - `prospector/README.md` — agent table + mermaid diagram + the env contract + the tier semantics + the
    `monitor`-colony handoff recipe.
  Follow-ups (out of scope here): off-chain qualification signals (web-research scoring) and freshness via
  deploy-time indexing. The colony NEVER signs and NEVER touches funds.
- **`monitor` live-watch runtime — derive a target's invariant SET once, watch the whole set continuously**
  (#1086, builds on the `monitor` colony #1085). The `monitor` colony's `invariant-watcher` evaluated ONE
  env-configured invariant against live on-chain state; dark-factory separately DERIVES a target's deep
  invariants (`run-invariant-hunt.sh` + `auditor/agents/invariant-prover.ag` + `evm-harness/`). This bridges
  the two: derive a target's invariant SET ONCE, emit a static **watch-spec**, then have the watcher re-check
  the WHOLE set continuously — no re-derivation per tick. READ-ONLY / NON-custodial throughout (a watch-spec
  is a set of facts to read + compare; it carries no keys and never describes a write).
  - `run-live-watch.sh` — given a target (`--repo`/`--target` + `--address` + `--rpc-url`), DERIVES the
    invariant set ONCE by REUSING `run-invariant-hunt.sh` (the established invariant-prover derivation entry
    point), then EXTRACTS the live-watchable two-sided comparisons (a view-call vs another view-call, or vs a
    literal bound — `require(a() <= b())` / `require(a() >= <n>)` / `assertLe(a(), b())`) from the generated
    invariant test into a **watch-spec**: a JSON array of `{label, lhs_sig, rhs_sig | rhs_const, rel,
    margin_bp}` objects (`rel` ∈ `le|ge|eq`). Complex multi-term/arithmetic invariants are deliberately
    UNDER-extracted (not a single live two-`cast` comparison) rather than emitted as an unwatchable spec. An
    offline `--spec-fixture <file>` path (the sibling of `run-invariant-hunt.sh`'s `--handler-fixture`) takes a
    hand-authored watch-spec VERBATIM — NO LLM, NO forge — so the derive→spec wiring is provable
    deterministically. POSIX-sh, dash-safe (`set -eu`), shellcheck-clean; all JSON construction goes through
    `python3 json.dumps` (the repo convention) so no signature can corrupt the spec; `--address` (0x + 40 hex)
    and `--rpc-url` (http(s)) are validated.
  - `monitor/agents/invariant-watcher.ag` — now ALSO consumes a derived watch-spec via `MONITOR_INV_SPEC` (an
    absolute PATH to the JSON file, or the JSON array INLINE). When SET, the watcher evaluates EVERY invariant
    in the set against live state each tick — `.ag` has no loops, so the set is walked by BOUNDED RECURSION
    over the array indices (cap 64; the runtime exposes no json-array-length builtin, so the walk stops at the
    first entry with no `lhs_sig`), reading each side with the SAME `shell_escape()`d `cast call` reader and
    the SAME deterministic `verdict_of()` the single-invariant path uses. Each member's verdict is posted to
    its own `monitor:signal:invariant:<label>` blackboard memo (the label is sanitized for the memo-key
    charset; the JSON payload keeps the original label), and the members are FUSED to the worst verdict across
    the set (`violated` > `margin` > `ok`) — one broken member pages the whole set. The fused verdict drives
    the EXISTING tier-gated emission (ONE `tier()` call per tick, branch once, `monitor:alert` on an anomaly),
    and the fused `monitor:signal:invariant` memo the `coordinator` already reads is unchanged. When
    `MONITOR_INV_SPEC` is UNSET the watcher's behaviour is byte-identical to before — the single env-configured
    invariant; `cb 90000` matches `cb_budget`, and every tick still ends with `memo_write(...:last_check)`.
  - `monitor/README.md` (a "Derive → watch the whole invariant set" section + the `MONITOR_INV_SPEC`
    env-contract row), `monitor/config/colony.example.toml`, and `monitor/scripts/start-colony.sh` (exports
    `MONITOR_INV_SPEC`) document the derive→watch flow. The colony stays read-only and never signs / never
    auto-submits.
- **`monitor` colony — continuous protocol monitoring with confidence-tiered alerting** (#1085). A new colony
  alongside `auditor` that continuously WATCHES a target EVM protocol and emits reasoned, high-signal anomaly
  alerts on the bus (`monitor:alert`). NON-custodial / read-only: every watcher only READS chain state via
  `cast`/RPC over `exec sh` (each dynamic value `shell_escape()`d) — no agent signs a transaction or touches
  funds. The hot-path verdicts are FACTS (an on-chain read + a deterministic comparison), never an LLM opinion.
  This PR ships the lint-clean foundation: the colony scaffold (`monitor/{agents,config,scripts,README.md}`,
  `[forge] type = "none"` per ADR-0003), two highest-value watchers, the fusion coordinator, and a webhook sink.
  - `monitor/agents/invariant-watcher.ag` — evaluates a derived protocol invariant (e.g. `totalSupply() <=
    totalAssets()`) against current on-chain state and flags a violation or a thin margin-to-violation. The
    invariant sides, target address, relation, and margin band come from env/config (getenv).
  - `monitor/agents/oracle-watcher.ag` — watches a price feed for deviation (vs a learned baseline) / staleness
    (feed age) / out-of-bounds price, same on-chain read pattern.
  - `monitor/agents/coordinator.ag` — fuses the two watcher signals off the shared `monitor:signal:*` blackboard
    (single-assignment helpers, no loops), dedups a persistent condition against the last emitted signature,
    decides fused severity, and emits one consolidated `monitor:alert`.
  - **Confidence-tiered alerting (ADR-0001) as the false-positive control.** Every agent makes ONE `tier()` call
    per tick and branches once; the tier gates EMISSION only (the verdict is identical at every tier): `shadow`/
    `dormant` observe + learn a baseline (no emit), `propose` emits a DRAFT alert (low severity), `review-gated`/
    `autonomous` emit a DIRECT page (high severity). `cb <N>;` matches `cb_budget`, and every tick ends with
    `memo_write("<agent>:last_check", now)`.
  - `monitor/scripts/start-colony.sh` — ADR-0003-conformant daemon launcher (symlink-safe `$0`, sources
    `parse-toml.sh`, exports the `MONITOR_*` env contract, `--restart-agent`, allowlisted daemon flags).
  - `monitor/scripts/notify.sh` — a thin POSIX-sh / dash-safe notifier that POSTs an alert payload to a
    Discord/Slack webhook when `MONITOR_WEBHOOK_URL` is set (no secret committed; read-only); prints to stdout
    as a no-op sink when unset.
  - `monitor/README.md` — agent table + mermaid diagram + the env contract + the tier semantics.
  Follow-ups (out of scope here): the liquidity / governance / flow watchers, the live-watch runtime (#1086),
  and a dashboard view. The colony NEVER signs, NEVER touches funds, and NEVER posts without a configured sink.
- **invariant-prover cross-contract multi-deploy harnesses (composable-fresh)** (#1075, epic #1041). The
  FRESH-DEPLOY real-target path deployed ONE target (single-contract) + mocked its externals, so the
  highest-value stablecoin bugs — which are CROSS-contract (oracle manipulation → manager mispricing; reward
  accrual → vault share inflation) — were structurally out of a single-contract harness's reach.
  `run-invariant-hunt.sh` gains a repeatable `--aux <Contract.sol[:Name]>` flag (relative to `--repo`, like
  `--target`): each value is validated the way `--target` is (exists, is a `*.sol`), staged into the rundir, and
  threaded to the prover as `INV_AUX` — a sentinel-joined list of `<abs_path>:<Name>` entries (sentinel `@@A@@`,
  which can occur in neither a filesystem path nor a Solidity identifier), also added to
  `exec.env_passthrough`. When `INV_AUX` is non-empty (composable-fresh mode)
  `auditor/agents/invariant-prover.ag` EXTENDS the generation prompt: it injects every auxiliary's source
  (clearly delimited `=== AUX CONTRACT (<name>) ===`), an import line per auxiliary (reusing the #1070-B1
  `import_line`/`rel_import_path`/`cat_file` helpers — no duplicated import/deploy machinery), and a new
  `compose_fresh_seed()` directive: deploy + WIRE the WHOLE system in `setUp()` (deploy the target AND each
  auxiliary, reading their constructors/initializers from the sources — the ERC1967Proxy recipe for upgradeable
  ones — then wire them via their setter/admin functions inferred from the sources), register the relevant
  contracts via `targetContracts()`, write a Handler whose actions SPAN the system, and EXACTLY ONE deep
  cross-contract invariant (NO free value extraction / system solvency holds across any sequence). The size
  budget grows to `~180 lines` in composable-fresh mode (still bounded). The whole composable-fresh extension is
  gated behind a non-empty `INV_AUX`, so with no `--aux` the rendered single-target prompt is **byte-identical**
  to #1070-B1 (verified by md5 of the rendered prompt), and the #1067 bounding, the #1073 compile-repair loop
  (a multi-deploy `setUp()` is MORE likely to need repair, and the new prompt flows through the same
  generate→write→gate→repair path), the fork-based `fork_seed`/`compose_seed` (FM1/FM2-fork), the offline
  `HANDLER_FIXTURE` path, and the verdict-from-gate-exit-code contract are all preserved unchanged. A new
  deterministic guard, `tools/test-invariant-prover-multideploy.sh`, pins the `--aux`→`INV_AUX` threading + the
  composable-fresh directive and asserts the no-`--aux` path is unchanged (grep over the `.ag` + the runner, no
  LLM/forge).
- `submit-triage.sh` — the **human-gated submission triage** layer (#1056, epic #1053). Scans a staging
  root for the verified-FINDING packages `run-audit.sh` / `run-batch.sh` drop under
  `<out>/submission[/<key>]/` and scores each candidate's readiness (**READY** = report.md + a PoC/witness +
  the NOT-SUBMITTED marker; **INCOMPLETE** lists the missing pieces), with a best-effort severity parse and a
  `--checklist <dir>` per-candidate review list. It NEVER contacts a platform — a READY package is a LEAD the
  operator reviews and submits MANUALLY; "take one finding end-to-end to a real submission" is the operator's
  step (a payable target + their platform account/KYC), which this tool only makes fast. `demo-submit-triage.sh`
  proves it offline + deterministically (a complete package -> READY/HIGH, an incomplete one -> INCOMPLETE
  missing `poc`, the checklist prints the manual-submit note, empty root -> SKIP, no egress).
- **FM4 — audit-informed deep-invariant synthesis** (#1058, epic #1041). Generic conservation /
  single-function invariants are what auditors and formal tools check FIRST, so re-deriving them finds
  nothing new. `run-autoharness.sh` gains `--audit-context <file>`: it folds the target's prior audit
  findings + known-gap notes into the generation prompt and instructs the LLM to target what audits MISS
  (cross-function emergent state, deep economic value-extraction, multi-step accounting drift) and to NOT
  re-derive an already-disclosed finding (worthless on a first-reporter bounty). A new `--dry-prompt` mode
  builds + prints the prompt without calling the LLM/forge, making the wiring offline-testable.
  `demo-fm4-audit.sh` asserts (deterministically, no LLM): with `--audit-context` the prompt carries the
  FM4 targeting block + the gap instruction + the do-not-re-report instruction + the disclosed findings
  verbatim; without it the prompt is unchanged (additive); an unreadable context file errors loudly. The
  invariant-quality uplift is the LLM's; this ships and proves the deterministic wiring.
- **FM3 — oracle / price perturbation as a stateful fuzz dimension** (#1057, epic #1041). FM1 forks real
  state and FM2 composes protocols, but the price/oracle stayed STATIC, so the flashloan-funded
  price-manipulation drain (where bounty money concentrates) was unreachable. The harness-generation prompt
  (`run-autoharness.sh`, main + repair) now instructs the LLM: when the target reads a price/oracle (spot
  reserve ratio, `price()`/`getPrice()`/`latestAnswer()`, a DEX quote), expose the price-MOVEMENT vector as a
  fuzzable action (a real swap on the forked pool, a donation/transfer that skews reserves, or a
  manipulable-feed write) so the seed can move the price within attacker-reachable bounds BEFORE the
  borrow/redeem/liquidate. `demo-fm3-oracle.sh` proves the dimension through the real `forge-invariant.sh`
  gate on a two-sided calibration: a spot-priced lender is over-borrowed by a fuzzed move-price->borrow
  sequence (**FINDING**) while the anchor+1%-bound twin rejects the manipulated borrow (**CLEAN**) — 0
  false-VERIFIED, verdict the fuzzer's. SKIPs cleanly without forge.
- `run-batch.sh` — the **batch/continuous runner** that operationalizes the proven engines at volume by
  consuming the #1054 funnel queue (epic #1053). Per `targets.queue` line (highest score first): skip keys
  already in `funnel-ledger.txt` (resumable; reuses the funnel dedup contract); run a hunt under a
  per-target timeout via a pluggable `--hunt-cmd` (the seam — it gets `BATCH_KEY/URL/SCOPE` in env and
  prints a `VERDICT|<confirmed|dry|refuted>` line) or a best-effort default (a resolvable `0x` address ->
  `run-autoharness.sh` given `ETH_RPC`+`FORK_BLOCK`, else `dry`+`needs recon`); the verdict is the engine's,
  NEVER an LLM; on `confirmed`, stage the finding under `<out>/submission/<key>/` marked PENDING HUMAN
  REVIEW — the colony has no platform-egress and **never auto-submits**; append `key<TAB>verdict<TAB>ts` to
  `funnel-ledger.txt` (the funnel dedups it next run) and `policy-outcomes.log`. Bounded by `--max-targets`;
  resumable via the ledger. `demo-batch.sh` proves the loop offline + deterministically (fixture queue +
  stub hunt-cmd -> score order, ledger-skip, staged confirmed, resumable no-op re-run). SKIPs cleanly with
  no queue.
- `run-funnel.sh` — the **target-intake funnel**: turns target selection from a human pick into a ranked,
  freshness-checked, self-deduped queue (#1054, part of epic #1053). Pipeline: **discover** (live RUNNING
  Sherlock contests via its JSON API, reusing `contest-watch.sh`'s `items[]` pattern, plus a best-effort
  Cantina/Code4rena probe) with a `--from <candidates.json>` offline override for deterministic/reproducible
  runs; **freshness** (drop any candidate whose `status` is not RUNNING); **self-dedup** (drop keys
  `platform:id` already in the read-only ledger `${DARK_FACTORY_DIR:-$HOME/.dark-factory}/funnel-ledger.txt`,
  whose `key<TAB>verdict<TAB>ts` rows the #1055 batch runner appends); **score** (a deterministic weighted sum
  documented in-script — recency of `launched_at` 0..40, log-scaled prize/TVL hint 0..25, platform weight
  contest>permanent 0..20, smaller in-scope size 0..15, max 100, ties broken by key ascending); and **emit** a
  ranked TSV `score<TAB>platform:id<TAB>url<TAB>title<TAB>scope_hint` to stdout AND
  `${DARK_FACTORY_DIR}/targets.queue`. No network AND no `--from` → `[SKIP]` + exit 0 (CI-safe). It NEVER
  contacts a platform to submit — a queued target is a LEAD a human (or the #1055 batch runner) triages.
- `demo-funnel.sh` — offline, deterministic proof of the funnel (mirrors the other `demo-*.sh`): feeds a
  fixture candidate list (varying `launched_at`/prize for a non-trivial rank, one non-RUNNING candidate, one
  pre-seeded in a temp ledger) to `run-funnel.sh --from` with `DARK_FACTORY_DIR` pointed at a temp dir, and
  asserts the queue is ranked by score descending, the non-RUNNING candidate is dropped (freshness), the
  ledger-seen candidate is dropped (self-dedup), and the run exits 0. No network, no LLM.

### Documentation
- `dispatcher.ag`: documented as the **standalone sync-guard** canonical copy of the dispatch fn (used by
  `demo-dispatch.sh` to diff against `coordinator.ag`'s inlined dispatch on the offline fixture path).
  It mirrors the fixture path AND the live `symbolic-prove` route (#1032); the newer live routes
  (`invariant-hunt` #1037 / auto-harness #1048 execution) live ONLY in `coordinator.ag` — which, not this
  standalone copy, is the production entry point — and are intentionally not mirrored here, so the
  invariant-hunt/auto-harness divergence flagged in #1049 is by design, not a bug. Resolves #1049
  (comment-only, no behavior change).

### Fixed
- **`forge-invariant.sh` degraded a self-contained harness to HARNESS_ERROR when the TARGET project's own
  tests don't compile** (#1069). `forge test` compiles the whole project, so a real-world target whose own
  `*.t.sol` fail under our forge/solc (e.g. a `view` function the compiler now rejects as state-modifying —
  solc drift) blocked even a fully self-contained generated harness, producing a non-verdict for a reason
  unrelated to our harness or the target's source. The gate now `--skip`s every other `*.sol` under the
  target's `test/` dir from compilation, keeping only the harness + `src`; targets whose tests compile
  cleanly are unaffected. Regression guard: `tools/test-forge-invariant-harness-isolation.sh`.
- **`invariant-prover.ag` `generate_test()` degraded to HARNESS_ERROR on realistically-sized targets**
  (#1067). The live-generation ask asked the model, in ONE completion, for a full `Handler` + abstract
  `InvBase` + a test contract asserting FIVE deep invariants (value-conservation, no-depositor-loss,
  solvency-under-any-sequence, no-free-value-extraction, share-price-monotonicity). On a real contract that
  single generation is too large to return within the LLM timeout, so the engine produced no verdict
  (HARNESS_ERROR). The ask is now **bounded**: EXACTLY ONE deep invariant — the single highest-value property
  for the current bug-class lens (e.g. solvency/collateralization for an accounting lens, share-price
  monotonicity for a vault lens) — plus a MINIMAL handler exposing only the actions needed to exercise that
  one invariant, under an explicit `~120-line` size budget, so the generation returns reliably and compiles.
  Breadth now comes from running the prover across MULTIPLE lenses (one focused invariant per run), not one
  mega-test. All hard constraints are unchanged (`pragma solidity ^0.8.20;`, no forge-std import, the
  StdInvariant `targetContracts()` ABI, plain `require(...)`, the `<matchPrefix>_*` naming, output-only
  Solidity), and the FM1/FM2 fork/compose seeds stay byte-identical when inactive.
  `tools/test-invariant-prover-bounded-gen.sh` pins the bounded ask (no LLM; grep over the `.ag` source).

## [0.2.0] — 2026-06-15

### Added
- `run-autoharness.sh` — **autonomous harness generation + hunt**. Given a target recon spec (deployed
  addresses + function signatures + fork block + the deep invariant to assert), the `$0` flat-cyborg LLM
  backend GENERATES a complete Foundry fork-fuzz harness on its own; a compile-repair loop fixes errors via
  the LLM; then the fuzzer hunts against the REAL forked protocol. No human writes the harness. Proven +
  reproducible: the LLM-generated harness rediscovers the real **Euler $197M audit-surviving bug** on a fork
  at the pre-exploit block, and reports CLEAN on a safe ERC4626 vault (sDAI) — generalises across protocols.
  Closes the harness-automation gap: the federation can go from a target's recon to a verdict autonomously.
  Needs a flat-cyborg backend wrapper + forge + an archive RPC (`[SKIP]`+exit0 otherwise). Example recon:
  `docs/autoharness-euler-example.txt`.


### Changed
- `run-audit.sh`: the default `--backend flat-cyborg` now wires `llm.command` to the new
  `flat-cyborg-claude.sh` wrapper, which drives the **interactive** claude CLI through
  flat-cyborg's PTY ($0 subscription) instead of the metered `claude -p` API. The
  `flat-cyborg` backend branch previously set only the timeout and left `llm.command`
  unset. `--backend claude` (metered `claude -p`) stays an explicit opt-in. Requires
  flat-cyborg >= v0.9.1 (`--extract` implies the screen grid).
- `run-autoharness.sh`: **rejects a vacuous stub harness**. A generated file must carry a real fork
  (`createSelectFork`), a `testFuzz_*(uint256 ...)` fuzz entrypoint, and a `require()` invariant, or it is
  sent back to the compile-repair loop with the full structural requirement re-stated — a live sDAI run
  exposed the LLM occasionally returning a degenerate `1+1==2` sanity test that compiled but hunted nothing.
  The shell-side prompt-fold + empty-retry workaround is removed now that delivery is fixed at the source:
  `flat-cyborg-claude.sh` passes `--wrap-input 72` (folds the long instruction block so it no longer
  overflows claude's editor) and flat-cyborg >= v0.10.0 gates `--extract` on the reply sentinel (a slow
  first reply is no longer captured as empty). Bumps the flat-cyborg floor to **v0.10.0**.
- `run-method-discovery.sh`: the INVENT direct-LLM **fallback** (taken when the substrate-native `agentis go`
  path yields no `METHOD|` line) now routes through the `flat-cyborg-claude.sh` wrapper instead of calling
  `claude -p` directly — so the entire dark-factory federation's live LLM generation is on the flat-rate
  subscription session. `claude -p` remains only as the explicit, opt-in `--backend claude` escape hatch in
  the sibling run scripts. `LLM_WRAP` overrides the wrapper path.


### Added

- **Cross-contract composability — the fuzzer now composes call-SEQUENCES across the target AND the protocols
  it interacts with, so flashloan-funded cross-contract value extraction (the canonical oracle/price-
  manipulation drain) is REACHABLE** (FM2, #1041). Single-contract invariant fuzzing is structurally blind to
  it; this makes the highest-value bug class findable. Builds on FM1 fork mode. **Purely additive** — with no
  `--fork-target` role beyond `target`, FM1/#1035/#1037 behaviour is byte-identical.
  - `run-invariant-hunt.sh` / `run-autonomous-hunt.sh` — a **repeatable `--fork-target '<role>=<addr>'`** that
    accepts a CONTEXT SET of deployed contracts beyond the single target (role ∈ {`target`, `dex`, `flashloan`,
    `oracle`, …}). A bare `--fork-target <addr>` (no `=`) stays the FM1 one-target shorthand (role defaults to
    `target`). Each address is validated as `0x` + 40 hex and each role against `[a-z0-9_]`; a role may not
    repeat. The set is exported to the prover as `FORK_CONTEXT` — a **semicolon-separated `role=addr` list**
    (e.g. `target=0x…;dex=0x…;flashloan=0x…`), parse-safe after validation. `run-autonomous-hunt.sh` forwards it
    via `INV_FORK_CONTEXT` to the coordinator, which appends `--fork-context` to the gate the chosen
    invariant-hunt runs (each value `shell_escape`d via `inv_opt_flag`).
  - `evm-harness/forge-invariant.sh` — accepts and IGNORES a `--fork-context <role=addr;…>` flag (a
    generation-prompt hint; the fuzzer auto-discovers its fuzz targets from the test's `targetContracts()`
    view, so the gate needs nothing from the context) so a composability-mode caller can forward it uniformly
    without an "unknown arg" error. No-fork / no-context behaviour is byte-identical.
  - `auditor/agents/invariant-prover.ag` — when `FORK_CONTEXT` carries MORE than the `target` role the
    generation prompt is extended: *"you may compose calls across these deployed contracts [role→address list];
    model an attacker funded by a flashloan from `<flashloan>` (or `vm.deal` if none); move price via `<dex>`;
    generate a Handler whose actions span all of them, and a deep invariant checking the TARGET's value/
    solvency after the cross-contract sequence — NO free value extraction."* The `HANDLER_FIXTURE` path stays
    authoritative; the `FORK_CONTEXT` addresses reach the prompt as plain text (never a shell). **Additive** —
    a `FORK_CONTEXT` with only `target` (or empty) leaves the FM1 prompt byte-identical (composability fires
    only on >1 role, counted via `regex_find_all("=", ctx)`).
  - **NEW `demo-composability.sh`** — the proof, fully synthetic + offline (no RPC; it demonstrates the
    mechanism the fork path then applies to real protocols). A `MiniAMM` (constant-product `x*y=k` whose `swap`
    moves the spot price), a `LendingVault` that prices deposited collateral at the AMM **spot** price (the
    manipulable-oracle bug) and lends quote against it, and a `FlashLender` (lend + require same-tx repayment).
    Two configs run through `run-invariant-hunt.sh` over the same budget + seed: **(A) composable** —
    `--fork-target target=<vault> --fork-target dex=<amm> --fork-target flashloan=<lender>` with a handler
    spanning all three → **FINDING** (the fuzzer composes flashloan → swap to inflate the collateral spot price
    → borrow against the overvalued collateral → swap back → repay → keep the surplus, breaking
    `invariant_vault_not_drained`; the break is a REAL value extraction, not a hard-coded assert, with a shrunk
    cross-contract witness); **(B) single-contract** — only the vault as target, a vault-only handler, same
    budget/seed → **CLEAN** (the exploit is structurally unreachable without composing the DEX + flashloan; the
    search still exercises the full budget — 256 runs × 64 depth — and holds). The A-FINDING / B-CLEAN split
    proves composability is the lift. `[SKIP]`s + exits 0 without forge/agentis; temp dirs under `${TMPDIR}`,
    trap-cleaned; a fixed `--seed` for reproducibility. The verdict is the FUZZER's exit code (no LLM — a
    deterministic fixture). A FINDING is a LEAD a human triages — this colony never auto-submits.
  - `README.md` / `docs/invariant-hunt.md` — a composability section (the `--fork-target <role>=<addr>` /
    `FORK_CONTEXT` encoding, the flashloan-attacker model, that it composes with FM1 fork mode for real
    targets, the human-gated boundary).

- **Fork-state invariant hunting — the stateful hunter now fuzzes deep invariants against FORKED REAL
  ON-CHAIN STATE (the actual deployed contract at a pinned block), not only a fresh deploy** (FM1, #1041).
  Proven foundation: `forge` invariant-fuzzed 512 sequences against the REAL deployed WETH at mainnet block
  25318855 via a public RPC and the solvency invariant (`totalSupply() <= address(WETH).balance`) held. FM1
  productises that into the hunter. **Purely additive** — with no `--fork-url` the #1035/#1037 behaviour is
  byte-identical.
  - `evm-harness/forge-invariant.sh` — optional `--fork-url <http(s)-rpc> [--fork-block <n>]`. The RPC shape
    (`http(s)://…`) and block (whole number) are validated; `--fork-block` requires `--fork-url`. When set,
    the gate threads forge 1.7.1's own `--fork-url <rpc> [--fork-block-number <n>]` (each value an array
    element, never a concatenated string) into the `forge test` invocation; when unset the forge command is
    **byte-identical** to today. A fork RPC failure (unreachable / rate-limited / "could not instantiate
    forked environment") leaves forge with no parseable result, so the existing no-result path returns
    **HARNESS_ERROR (2)** — never a false CLEAN/FINDING (the FM1 safety contract).
  - `run-invariant-hunt.sh` / `run-autonomous-hunt.sh` — `--fork-url`/`--fork-block` pass-through to the gate
    (the autonomous driver forwards them via `INV_FORK_URL`/`INV_FORK_BLOCK` to the coordinator's chosen
    `invariant-hunt`, and through the `--pattern-store` prover-gate wrapper to the prover). `run-invariant-hunt.sh`
    also exports `FORK_TARGET=<deployed address>` (+ `FORK_URL`/`FORK_BLOCK`) to the prover so the generated
    test can reference the real deployed contract by address. Absent the flags, behaviour is unchanged.
  - `auditor/agents/invariant-prover.ag` — in fork mode (`FORK_TARGET`/`FORK_URL` non-empty) the generation
    prompt is told the target is a **live deployed contract at `<address>`** and to generate a Handler that
    drives its real functions with bounded inputs and funded actors (`vm.deal`), plus a deep invariant checked
    against the forked state (solvency / no-free-value-extraction / share-price monotonicity). The
    `HANDLER_FIXTURE` path stays authoritative; the `--fork-url`/`--fork-block` are forwarded to the gate,
    each `shell_escape`d. **Purely additive** — no `FORK_*` ⇒ the generation prompt + gate command are
    byte-identical. `auditor/agents/coordinator.ag`'s `run_invariant_live` forwards `INV_FORK_URL`/`INV_FORK_BLOCK`
    to the gate the same way (each value `shell_escape`d via `inv_opt_flag`).
  - **NEW `demo-fork-hunt.sh`** — the foundation proof. Probes a public RPC (`ethereum-rpc.publicnode.com`,
    fall back to `eth.drpc.org`); when forge is absent OR no RPC is reachable it `[SKIP]`s and exits 0.
    Otherwise it builds a tiny Foundry project with the proven WETH handler + solvency invariant, forks the
    REAL deployed WETH at block 25318855, and asserts **CLEAN** (the funded handler drove the deployed
    contract's real `deposit()`/`withdraw()` over fuzzed sequences and the invariant held — the machinery ran
    against real forked state), plus a forced-bad `--fork-url http://127.0.0.1:1` → **HARNESS_ERROR (exit 2)**,
    never a false verdict. The RPC is an argument (no key hard-coded); the block is pinned for reproducibility.
    A FINDING here would be a CANDIDATE a human triages — this colony **never auto-submits**.
  - `docs/invariant-hunt.md` — a fork-mode section (the `--fork-url`/`--fork-block`/`FORK_TARGET` contract, the
    RPC-failure→HARNESS_ERROR safety, the human-gated boundary, reproducibility via the pinned block).

- **Method-invention feeds the hunt + DAG pattern memory — the federation invents its own attack methods,
  stores winning ones in the pattern DAG, and self-drives** (Integration M3, #1037, the FINAL milestone). M1
  made the coordinator live-drive the fuzzer; M2 let each lead carry its own context. M3 closes the loop: a
  winning invariant pattern (one that produced a FINDING) is **persisted to the pattern DAG** and **recalled
  to seed future hunts**, and `invent-method` can propose a **new** invariant class the next hunt then uses.
  It **reuses the existing `bugpat:*` DAG infrastructure** — the same `dag_put`/`recall_latest`/`memo_write`
  primitives the fork-matcher seed/recall agents use, in a parallel `invpat:*` namespace — rather than building
  a new store.
  - `auditor/agents/invariant-prover.ag` — two additive hooks around its GENERATE-and-VERIFY step. **RECALL
    before GENERATE:** reads `recall_latest("invpat:latest:<class>")` (falling back to `invpat:invented:<class>`
    — the invent-method hint), prints `RECALL-INVPAT|<class>|<descriptor>` when non-empty, and folds the
    descriptor into the LLM generation seed ("a prior FINDING on this class used this invariant pattern: …;
    adapt it"); on the `HANDLER_FIXTURE` path the fixture stays authoritative but the `RECALL-INVPAT|` line is
    still printed so the loop is observable. **PERSIST on FINDING:** *after* the verdict print (so a persist
    failure can never alter the verdict), and only when `verdict == "FINDING"`, computes a deterministic
    signature `<class>::<target>::<match-prefix>`, `dag_put`s it, writes `invpat:exact:<hash>` +
    `invpat:latest:<class>`, emits `dark-factory:invariant_pattern_learned`, and prints
    `INVPAT-LEARNED|<class>|<descriptor>`. Recall/persist steer GENERATION only — **the verdict stays the
    fuzzer's exit code**; `prior`/the signature flow only into the prompt + the plain-stdout `RECALL-INVPAT|`
    line, never into `exec sh`. **Purely additive** — with no recalled pattern the instruction is
    byte-identical to M2.
  - `run-invariant-hunt.sh` — a `--pattern-store <dir>` flag: a **persistent** agentis store reused across
    runs where the `invpat:*` memos are kept. A bridge (via the `agentis memo` CLI) moves them **in** before
    the prover run (so RECALL sees a prior run's confirmed shapes) and **out** after (so this run's FINDING is
    kept for the next). Absent the flag the per-run store is ephemeral → no cross-run memory (byte-identical).
  - `run-autonomous-hunt.sh` — `--pattern-store <dir>` routes the coordinator's chosen invariant-hunt through
    `invariant-prover.ag` (so persist/recall happen) **without touching `coordinator.ag`**: it hands the
    coordinator a thin prover-gate wrapper as `FORGE_INVARIANT` that speaks the gate's exact CLI + exit
    contract (`1=FINDING/0=CLEAN/2=error`), so `run_invariant_live` + `sym_rc_of`/`sym_outcome_of` are
    byte-identical, while internally routing through the prover in the persistent store (the prover's
    `RECALL-INVPAT|`/`INVPAT-LEARNED|` lines are surfaced into the orchestrate log). A `--method-fixture <file>`
    flag (Part B) consults a deterministic `METHOD|…` method-inventor proposal, parses the proposed bug class,
    and seeds it as `invpat:invented:<class>` so the next hunt's generation consults it as a hint (the live
    `method-inventor.ag` path stays prompt-driven; the fixture proves the wiring without an LLM). Absent
    `--pattern-store` the coordinator calls the bare gate directly — M1/M2 byte-identical.
  - `demo-pattern-memory.sh` — the end-to-end proof, all through `run-autonomous-hunt.sh --pattern-store`:
    **Run 1** on the vulnerable vault A (class C1) → FINDING → the winning pattern is PERSISTED to the shared
    store (`invpat:latest:C1` present + `INVPAT-LEARNED|C1|…`); **Run 2** on a structurally-different
    vulnerable vault B of the SAME class → the prover RECALLs the stored pattern (`RECALL-INVPAT|C1|…`) and
    B → FINDING (discovered → stored in the DAG → recalled → reused ACROSS targets); the **invent-method leg**
    seeds a new invariant class (`invpat:invented:C1`) that the next hunt's generation consults. Honest
    framing: the claim is the MEMORY LOOP works (persist/recall/reuse), not that recall is necessary for the
    fuzzer to find B. `[SKIP]` + exit 0 when forge/agentis are absent (CI convention).
  - `docs/autonomous-hunt.md` — a "Pattern memory (M3)" section documenting the `invpat:{exact,latest,invented}`
    namespace, the persist-on-FINDING / recall-before-generate loop, `--pattern-store`, the prover-gate
    wrapper, and the `invent-method` feed; notes it reuses the `bugpat:*` DAG infra. Wired into `README.md`.
- **Multi-candidate carrying — each pending lead verifies its OWN target, not one shared operator env**
  (Integration M2, #1037). M1's live route read the target from a SINGLE flat env (`INV_REPO`/`INV_TARGET`),
  so every candidate the loop verified hit the same operator-supplied target. M2 makes each candidate carry
  its **own** repo/target context via the durable memo channel, so the loop can verify several pending leads
  and each `invariant-hunt`/`symbolic-prove` runs on the **right** lead — closing the loop from discovery
  (many leads) to a sound verdict on each *specific* lead.
  - `auditor/agents/coordinator.ag` — `run_invariant_live(candId)` and `run_symbolic_live(candId)` now take the
    candidate id (the action `args`, threaded from the `action_outcome` live branches) and resolve repo/target/
    match (and the symbolic `sym_repo`/`sym_spec`/`sym_function`) **per-candidate-first, env-fallback** via a
    new `cand_fact(candId, field, envKey)` helper: read `candidate:<id>:<field>` (the `recall_latest`-durable
    cross-process channel), use it when non-empty, else fall back to the flat M1 env. The live-route **GATE**
    keys on the **resolved** repo+target (per-candidate OR env), so a candidate carrying only its own memo
    (flat env empty) still routes live; with neither it falls through to the honest stub. Run-level forge
    budgets (`INV_RUNS`/`INV_DEPTH`/`INV_SEED`) stay env-only. **Purely additive** — an empty per-candidate
    memo ⇒ the M1 env path ⇒ **byte-identical M1 behaviour** (the `decide_once` scoring and state-field carry
    are untouched; all M1 + sibling goldens stay green). Every resolved value is still `shell_escape()`d.
  - `run-autonomous-hunt.sh` — a repeatable `--candidate '<id>|<repo>|<target>[|<match>]'` flag. Each candidate
    is validated (a foundry dir + an existing target), `agentis memo set candidate:<id>:repo/target/match` into
    the shared store (after `agentis init`, before `agentis go` — NOT in `exec.env_passthrough`, they cross via
    the durable memo channel), and contributes one `<id>|…` cell to `PENDING`. The single `--repo/--target`
    stays as the one-candidate `cand-0` shorthand (full M1 back-compat — `demo-autonomous-hunt.sh` passes
    unchanged). With candidates supplied, `BUDGET`/`STEPS` auto-scale to `>= 2 × candidate-count` so every
    candidate is both routed and attributed; `INV_POLICY_TT` seeding keeps `invariant-hunt` winning the VERIFY
    tier for each.
  - `demo-candidate-carry.sh` — the rigorous proof. Builds the vulnerable inflation vault (project A) + hardened
    twin (project B) in two separate temp foundry projects, drives ONE `run-autonomous-hunt.sh` with TWO
    `--candidate` args, and **leaves the flat `INV_REPO`/`INV_TARGET` env EMPTY** so the ONLY way each candidate
    can resolve a target is via its carried `candidate:<id>:*` memo. Asserts BOTH the autonomous choice
    (`ACTION|invariant-hunt|cand-{0,1}`) and the SPLIT verdict (`DISPATCH|invariant-hunt|cand-0|confirmed` on A,
    `…|cand-1|refuted` on B) — a shared env could not produce two different verdicts, so the split PROVES
    per-candidate carrying. `[SKIP]` + exit 0 when forge/agentis are absent (CI convention).
  - `docs/autonomous-hunt.md` — a "Per-candidate context carrying (M2)" section documenting the
    `candidate:<id>:{repo,target,match,sym_repo,sym_spec,sym_function}` memo convention, the
    per-candidate-first/env-fallback rule, and that `run-discovery.sh`/`hunter.ag` can populate these memos as
    the discovery producer. Wired into `README.md` (the Hunt-autonomously section + the Layout map).
- **The self-orchestrating coordinator AUTONOMOUSLY chooses + LIVE-runs the stateful-invariant fuzzer — a new
  `invariant-hunt` action, end-to-end** (Integration M1, #1037). #1035 shipped the fuzzer as a *callable
  engine* (an operator runs `run-invariant-hunt.sh`); Int M1 wires it into the #1014 self-orchestrating
  coordinator so the **federation itself CHOOSES** to spend it and LIVE-runs it on a target — finding the
  multi-step bug without an operator picking the engine. This mirrors EXACTLY how `symbolic-prove` was added
  as a VERIFY-tier action (#1015 M3) and given a live route (#1032).
  - `auditor/agents/coordinator.ag` — a new `invariant-hunt` action in the VERIFY tier (alongside
    `refute`/`poc-screen`/`symbolic-prove`): `is_action` accepts it, a new `score_invariant(policy)` scores it
    at **base 94** (below `refute`(100) / `poc-screen`(98) / `symbolic-prove`(96) — the stateful fuzzer is the
    most EXPENSIVE verify, a multi-call sequence search, so the cheaper verifies go first by default), with the
    **steep ×4 policy term** so the colony can **learn** to lift it above the others (`94 + 4 × policy` beats
    `refute`(100) at policy > 1.5); a pending candidate still outranks any fresh hunt. The 3-way VERIFY argmax
    is refactored to a single-assignment **4-way climbing argmax** that preserves the default ordering
    `refute > poc-screen > symbolic-prove > invariant-hunt` on ties. It operates on the first pending candidate
    (args = the candidate id) and consumes it from `PENDING`.
  - **The LIVE route:** a new branch in `action_outcome` — when `invariant-hunt` is chosen AND no
    `DISPATCH_FIXTURE` matched AND a live invariant env is present (`FORGE_INVARIANT` gate + `INV_REPO` foundry
    dir + `INV_TARGET` invariant test), `run_invariant_live()` `exec sh`-runs `forge-invariant.sh --repo …
    --target … --match … [--runs/--depth/--seed]` (optional budgets appended only when non-empty, every value
    `shell_escape()`d), captures the exit code via the `__rc=$?` marker, and maps it **1 → confirmed** (FINDING,
    a real multi-step bug with a shrunk witness), **0 → refuted** (CLEAN, the lead is killed in this budget),
    **2/other → dry** (HARNESS_ERROR). The mapping is IDENTICAL to the symbolic route, so it **reuses**
    `sym_rc_of`/`sym_outcome_of`. The branch is **purely additive** — absent any of the three env facts it
    falls through to the existing honest stub, so behaviour with no live env is **byte-identical**. The verdict
    is forge's shrunk witness, **never the LLM** — the **CHOICE** of engine is the policy's, the **VERDICT** is
    the fuzzer's.
  - The in-substrate orchestrate loop carries a 6th policy int (field 21) + seen flag (field 22) for
    `invariant-hunt`, appended **after** the symbolic-prove fields so positions 0–20 are unchanged; a new
    `INV_POLICY_TT` env fact (ten-thousandths) seeds the loop's initial `invariant-hunt` policy so the
    coordinator can choose it from step 0 (exactly as `SYM_POLICY_TT` seeds `symbolic-prove`). `policy_string`
    sorts `invariant-hunt` between `hunt` and `invent-method` (`inva` < `inve`), so a run that never touches it
    renders the same string as before. `auditor/agents/dispatcher.ag` carries the byte-identical `is_action`
    update (the `demo-dispatch.sh` sync-guard asserts the two copies do not drift). **With `ORCHESTRATE_ENABLED`
    absent the single-decision path is byte-identical to before** (the new action never wins any
    `demo-coordinator.sh` fact-state without a seeded policy).
  - `run-autonomous-hunt.sh` — operator entrypoint mirroring `demo-symbolic-orchestrate-live.sh`'s driver.
    `--repo <foundry-root> --target <Invariant.t.sol> [--match <prefix>] [--backend <b>] [--runs N] [--depth D]
    [--seed S] [--steps N] [--out <dir>]`. Resolves `evm-harness/forge-invariant.sh` relative to `$0` into
    `FORGE_INVARIANT`, builds a fresh agentis store, seeds a pending candidate for the target + `INV_POLICY_TT`
    (= +2.0, representing the policy a prior run would have evolved), exports the LIVE env, runs ONE
    `agentis go coordinator.ag --enable-exec --enable-messaging` in ORCHESTRATE mode, prints the autonomous
    decision trail (`ACTION|`/`DISPATCH|`) + the final `coordinator:last_outcome` verdict.
  - `demo-autonomous-hunt.sh` — offline-deterministic proof. Reuses `demo-invariant-hunt.sh`'s inflation-vault
    + hardened-twin scaffolding (same contracts/handler/invariant), drives **`run-autonomous-hunt.sh`** (not
    the fuzzer directly) on each, and asserts: (A) the coordinator AUTONOMOUSLY emitted `ACTION|invariant-hunt|`
    (the coordinator chose the engine, not the operator), (B) `DISPATCH|invariant-hunt|…|confirmed` for the
    vulnerable vault + `…|refuted` for the hardened twin (the LIVE fuzzer's verdict), (C) a `learn` for
    `invariant-hunt` referencing the verdict appears in the store on the step AFTER the verdict (outcome →
    policy). `[SKIP]` + exit 0 when forge/agentis are absent (CI convention).
  - `docs/autonomous-hunt.md` — the end-to-end flow (coordinator chooses → live forge-invariant → sound verdict
    → policy evolves), the verdict→outcome mapping, and the human-gated submit boundary. Wired into `README.md`
    (`## Hunt autonomously (run-autonomous-hunt.sh, Int M1)` + the Layout map). **Requires:** foundry (forge)
    for a real run; optional for the rest of the federation.
- **The stateful-invariant-fuzzing bounty hunter — finds the MULTI-STEP bugs single-function symbolic exec
  misses** (#1035). The symbolic gate (#1015) proves a property over all inputs of ONE function; the refuter
  (#999) is a hostile LLM read of ONE claim. Both miss the **multi-step, stateful** bug — the ERC4626
  inflation attack, an accounting drift that compounds, a re-entrancy that only breaks on the third interleave
  — exactly the class that survives a single-function audit. This MVP ships the engine for that class: the LLM
  writes the deep invariants + the handler, Foundry's stateful fuzzer finds the exploit SEQUENCE, and **the
  verdict is the fuzzer's concrete failing call-sequence, never the LLM's opinion**.
  - `auditor/agents/invariant-prover.ag` — per-target substrate agent (the third GENERATE-AND-VERIFY sibling
    after `refuter.ag` and `symbolic-prover.ag`). It env-ins the target (`TARGET_FN` + class) + the contract
    source, GENERATES a Foundry stateful-invariant test — a `Handler` exposing the protocol's actions as
    bounded actor functions + a set of DEEP `invariant_*` properties (value-conservation, no-depositor-loss,
    solvency-under-any-sequence, no-free-value-extraction, share-price-monotonicity) — verbatim from a
    `HANDLER_FIXTURE` on the offline path or via `prompt()` on the live path (prompt-gate-ok per convention).
    It writes the UNTRUSTED test injection-safely (`printf '%s' <shell_escape(test)>`, NEVER a heredoc),
    VERIFIES it through the fuzzing gate, maps the exit code **1 → FINDING** / **0 → CLEAN** / **else →
    HARNESS_ERROR**, `emit`s `dark-factory:invariant_verdict`, `learn`s the attempt (FINDING=success,
    CLEAN=failure, harness=error) so invariant-prover fitness reweights, and prints `INVARIANT|<target>|
    <verdict>` plus, on a FINDING, the shrunk exploit call-sequence (one `STEP|...` line per call).
  - `evm-harness/forge-invariant.sh` — the callable gate. Runs Foundry's built-in stateful invariant fuzzer
    over a `*.t.sol` (`forge test --match-test invariant --json`), parses the JSON without `jq`, and returns
    **FINDING** (exit 1, with the shrunk exploit sequence surfaced on stderr) / **CLEAN** (exit 0, every
    invariant held across the fuzzed search) / **HARNESS_ERROR** (exit 2, compile/setup error / no invariant
    matched / forge absent). forge-std-free by design: the test registers fuzz targets via the
    `targetContracts()` StdInvariant ABI Foundry auto-discovers and asserts with plain `require(...)`, so it
    compiles in ANY Foundry project with zero remappings. runs/depth tune the search via
    `FOUNDRY_INVARIANT_RUNS`/`_DEPTH`; `--seed` pins forge's fuzz seed for reproducibility.
  - `run-invariant-hunt.sh` — operator entrypoint mirroring `run-symbolic.sh`. `--repo <foundry project>
    --target <Contract.sol[:Name]> [--handler-fixture <file>] [--backend mock|flat-cyborg|claude] [--runs N]
    [--depth D] [--seed S] [--out <dir>]`. Stages a fresh copy of `--repo` into the rundir, drops pre-existing
    `*.t.sol` so the gate scopes to exactly the generated test, drives `invariant-prover.ag` over the
    substrate, and collects the verdict + any shrunk exploit sequence into `<out>/invariant-report.md`.
    Default backend flat-cyborg.
  - `demo-invariant-hunt.sh` — offline-deterministic proof. Builds two tiny Foundry repos — a VULNERABLE
    ERC4626-style vault (no virtual offset) and a HARDENED twin (a large virtual-share/asset offset) — and
    drives the harness with a fixture handler on each: asserts the vulnerable vault → **FINDING** with a
    non-empty shrunk exploit sequence (the inflation attack: donate → seed → victimDeposit), the hardened
    vault → **CLEAN** (no false positive on the fix). A fixed `--seed` makes the search reproducible.
    `[SKIP]` + exit 0 when forge/agentis are absent (CI convention).
  - `docs/invariant-hunt.md` — the thesis (audit-surviving bugs are multi-step/stateful; the LLM writes deep
    invariants + handlers, the fuzzer finds the exploit sequence, the verdict is the fuzzer's), the
    verdict-source contract + verdict→outcome mapping, the deep-invariant taxonomy, fixture-vs-LLM paths,
    honest scope (the engine; coordinator-routing + fan-out are follow-up), and how it relates to #1015 / #1033.
    Wired into `README.md` (`## Hunt multi-step bugs (run-invariant-hunt.sh)` + the Layout map).
- **The LIVE coordinator → Halmos `symbolic-prove` route — REAL symbolic execution inside the autonomous
  loop** (#1032). #1015 M3 proved the *offline* orchestration (a `DISPATCH_FIXTURE` stood in for the sound
  verdict); #1032 closes the **live** slice for an operator-supplied single candidate: when the coordinator
  CHOOSES `symbolic-prove` and a live symbolic context is present, it runs REAL Halmos end-to-end and maps the
  solver's exit code to the gate outcome — never an LLM opinion.
  - `auditor/agents/coordinator.ag` — a new LIVE branch in `action_outcome`: when `symbolic-prove` is chosen
    AND no `DISPATCH_FIXTURE` matched AND a live symbolic env is present (`SYM_REPO` foundry dir + `SYM_SPEC`
    target spec + the `HALMOS_VERIFY` gate path), it `exec sh`-runs `halmos-verify.sh --repo <SYM_REPO>
    --target <SYM_SPEC> --function <prefix>`, captures the exit code via the `__rc=$?` marker, and maps it
    **1 → confirmed** (COUNTEREXAMPLE, a real bug), **0 → refuted** (PROVED, safe), **3/2/other → dry**
    (INCONCLUSIVE / harness). ALL dynamic values are `shell_escape()`d; the gate is resolved via the
    `HALMOS_VERIFY` env path. The branch is **purely additive** — absent any of the three env facts it falls
    through to the existing honest stub, so behaviour with no live env is **byte-identical** (verified:
    `demo-coordinator.sh` is unchanged against `origin/main`). `auditor/agents/dispatcher.ag` carries the
    byte-identical live branch (the `demo-dispatch.sh` sync-guard asserts the two copies do not drift).
  - `run-coordinator.sh` — new `--sym-repo <dir>` + `--sym-spec <file>` flags supply the single-candidate live
    symbolic context (plus `--sym-function <prefix>`, default `check`); they must be supplied together,
    `--sym-repo` must be a Foundry project, `--sym-spec` a readable file. `halmos-verify.sh` is resolved to an
    absolute path and passed as `HALMOS_VERIFY`; `SYM_REPO,SYM_SPEC,SYM_FUNCTION,HALMOS_VERIFY` are whitelisted
    in `exec.env_passthrough`; the per-step `exec.default_timeout_ms` is raised to 180s when a live context is
    supplied (Halmos runs forge build + z3 — tens of seconds). Header/usage document the flags + the
    verdict→outcome mapping.
  - `demo-symbolic-orchestrate-live.sh` — new LIVE demo: builds a tiny Foundry vault with a real
    rounding-direction solvency bug (`convertToAssets` rounds UP, minting value) + its fix (rounds DOWN) and a
    Halmos solvency spec, drives the coordinator with the live env so its chosen `symbolic-prove` runs REAL
    Halmos → the buggy spec returns a COUNTEREXAMPLE → **confirmed**, the fixed spec PROVES the invariant →
    **refuted**; asserts the outcomes flip purely from the solver's verdict. `[SKIP]` + exit 0 when
    forge/halmos/agentis are absent (CI convention). `docs/generate-verify.md` updated: the live coordinator
    route now runs Halmos end-to-end for a supplied candidate, the offline fixture path is the CI proof, and
    multi-candidate code-carrying remains the follow-up.
- **The self-orchestrating coordinator ROUTES a candidate to the SOUND symbolic engine — a new
  `symbolic-prove` action** (#1015 M3). M2 shipped the *callable* generate-and-verify step; M3 wires it into
  the #1014 self-orchestrating coordinator so the federation can **DECIDE** to route a pending candidate
  through the sound symbolic engine, with the verdict weighted into its evolving policy.
  - `auditor/agents/coordinator.ag` — new `symbolic-prove` action in the VERIFY tier (alongside
    `refute`/`poc-screen`): `is_action` accepts it, a new `score_symbolic(policy)` scores it at **base 96**
    (below `refute`(100) and `poc-screen`(98) — routing through the symbolic engine is the most expensive
    verify, so the cheaper verifies go first by default), with the **steepest policy term in the tier** (×4)
    so the colony can **learn** to lift it above either; a pending candidate still outranks any fresh hunt.
    It operates on the first pending candidate (args = the candidate id, like refute/poc-screen) and consumes
    it from `PENDING`. The in-substrate orchestrate loop carries a 5th policy int (field 19) + seen flag
    (field 20) for `symbolic-prove`, appended **after** the existing fields so positions 0–18 are unchanged.
    A new `SYM_POLICY_TT` env fact (ten-thousandths) seeds the loop's initial `symbolic-prove` policy so the
    coordinator can choose it from step 0. **With `ORCHESTRATE_ENABLED` absent the single-decision path is
    BYTE-IDENTICAL to before** (verified against `origin/main` on the `demo-coordinator.sh` fact-states — the
    new action never wins any of those states since `refute` outranks it without a seeded policy).
  - **The verdict→outcome mapping (the epic's thesis):** the SOUND symbolic verdict maps to the coordinator's
    gate-outcome enum **COUNTEREXAMPLE → confirmed** (a real bug with a concrete witness),
    **PROVED → refuted** (the lead is killed *by a proof*, safe), **INCONCLUSIVE → dry**. So the
    confirmed/refuted policy signal the coordinator evolves on now comes from a **sound engine, never an LLM
    opinion**. `auditor/agents/dispatcher.ag` documents the mapping prominently and routes `symbolic-prove`
    to `run-symbolic.sh` on the honest live stub; on the offline path the `DISPATCH_FIXTURE` carries the
    already-mapped outcome (`symbolic-prove|cand*=confirmed` = a COUNTEREXAMPLE, `=refuted` = a PROVED).
  - `run-coordinator.sh` — new `--sym-policy <float>` flag seeds the in-substrate loop's `symbolic-prove`
    policy weight (converted to `SYM_POLICY_TT` ten-thousandths) so an operator can have the coordinator
    choose the symbolic route; usage/header list the new action; the in-loop-vs-store policy cross-check is
    skipped when a seed is supplied (the seed is an in-loop offset not written to the experience store).
  - `demo-symbolic-orchestrate.sh` — offline, deterministic proof: a hunt confirms → pushes a candidate →
    the coordinator **CHOOSES** `symbolic-prove` for it → the SOUND verdict (via fixture) flows back as the
    outcome (a COUNTEREXAMPLE run and a PROVED run, asserting the policy moves in **opposite** directions) →
    the candidate is **consumed** from `PENDING` → the policy **evolves**; deterministic re-run. No real
    Halmos needed for the orchestration proof (the fixture maps the sound verdict, exactly like every other
    action's offline path). `docs/generate-verify.md` / `docs/coordinator.md` / `docs/dispatch.md` / `README.md`
    updated with the action, the score/ordering rationale, and the verdict→outcome mapping.
- **Generate-and-verify — the LLM HYPOTHESIZES a property, Halmos delivers the SOUND verdict** (#1015 M2).
  M1 shipped the *callable* Halmos gate; M2 closes the loop from a *candidate* to a symbolic verdict by
  **generating the spec** the gate runs. New `auditor/agents/symbolic-prover.ag` is a per-candidate substrate
  agent (modelled on `refuter.ag`: `cb 300000;`, one-shot, no `fn tick`; env reads via `getenv`; reads via
  `exec sh` with `// colony-lint: safe-exec-concat`; `emit`/`learn`/`memo_write`): it **GENERATES** a Halmos
  `*.t.sol` property spec for one candidate — verbatim from a `SPEC_FIXTURE` env fact on the offline /
  deterministic path (no LLM), or via `prompt()` on the live path — then **VERIFIES** it by running the M1
  `evm-harness/halmos-verify.sh` through `exec sh` and mapping its exit code to the verdict (`0`→**PROVED**
  = invariant holds for ALL inputs → candidate safe / refuted by a proof; `1`→**COUNTEREXAMPLE** = a concrete
  input is a real bug, CONFIRMED with a witness; `3`→**INCONCLUSIVE**; else→**HARNESS_ERROR**). It `emit`s
  `dark-factory:symbolic_verdict`, `learn`s the attempt (COUNTEREXAMPLE=success / PROVED=failure /
  INCONCLUSIVE=partial / error) so symbolic-prover fitness reweights, and `print`s one
  `SYMBOLIC|<file:fn>|<verdict>` marker. **The verdict is Halmos's exit code, NEVER the LLM's opinion** —
  that is the whole point of the milestone; the LLM's job shrinks to writing the property to check.
  - `run-symbolic.sh` — operator entrypoint mirroring `run-refute.sh`: drives `symbolic-prover.ag` once per
    candidate over the substrate from a `file:fn | class | invariant | code-file | spec-fixture` manifest,
    staging a fresh copy of `--repo` into the rundir (so the sandboxed `exec sh` can write the spec into
    `test/` and run Halmos there) and threading `SPEC_FIXTURE` when provided. Default backend `flat-cyborg`
    (consistent with the other `run-*.sh`); `--backend mock` + a fixture is the offline wiring smoke.
    Collects verdicts into `symbolic-report.md`. A COUNTEREXAMPLE is a CONFIRMED bug but still a **lead** a
    human reviews; submission stays human-gated and this tool NEVER posts.
  - `demo-symbolic.sh` — offline-deterministic proof of the FULL candidate → spec → Halmos → verdict loop
    with a **fixture spec** (no LLM) + **real Halmos**, over two candidates: the honest `transferSafe`
    invariant Halmos PROVES (→ PROVED / safe) and the same invariant against the buggy `transferBuggy` Halmos
    REFUTES (→ COUNTEREXAMPLE / confirmed). Reuses the M1 `evm-harness/halmos-specs` contracts; asserts both
    verdicts and that a re-run is byte-identical (deterministic). Prints `[SKIP]` + exit 0 when
    `halmos`/`forge`/`agentis` are absent (CI convention, like `demo-halmos.sh`).
  - New `docs/generate-verify.md` documents the LLM-hypothesizes / Halmos-proves loop, the verdict-source
    contract (the verdict is the solver's exit code), the offline-fixture vs live-LLM paths, how it composes
    with M1, and the honest scope: M2 is the **callable** generate-and-verify step; coordinator auto-routing
    (deciding *when* to spend a symbolic verify and feeding the verdict into the evolving policy) is a later
    milestone. On the live path, a generated spec that does not compile / imports a missing contract /
    writes an unbounded loop returns **INCONCLUSIVE** (the safe failure mode, never a false PROVED), so
    INCONCLUSIVE is the honest common case for an un-reviewed live spec; the fixture path reaches a sound
    PROVED / COUNTEREXAMPLE today. `README.md` updated (run-symbolic.sh in the verification flow + layout).
    **Requires:** halmos >= 0.3 + foundry (forge) for a real verify; both optional for the rest of the
    federation.
- **Halmos symbolic-execution verification gate — a SOUND oracle that PROVES an invariant or returns a
  concrete counterexample, exhaustive over all inputs** (#1015 M1). New `evm-harness/halmos-verify.sh` runs
  [Halmos](https://github.com/a16z/halmos) (symbolic execution + the z3 SMT solver) over a `*.t.sol` spec
  and parses its `Symbolic test result: N passed; M failed` summary into a structured verdict + exit code:
  **PROVED** (exit 0 — holds for every input), **COUNTEREXAMPLE** (exit 1 — a concrete input violates the
  property, a real bug), **INCONCLUSIVE** (exit 3 — solver `unknown` / timeout / unbounded loop / nothing
  matched), and harness/usage error (exit 2 — bad args, `--repo` not a Foundry project, or `halmos`/`forge`
  absent with an install hint). It is the SYMBOLIC sibling of `evm-harness/forge-verify.sh` (which witnesses
  one concrete exploit path) and an **additional** sound oracle alongside it — `forge-verify.sh` is
  unchanged. Tools are resolved via `PATH` (`command -v`), no install location is hardcoded; the banner
  (`================ HALMOS-VERIFY: <VERDICT> ================`) mirrors `forge-verify.sh`. Ships two
  self-contained example specs under `evm-harness/halmos-specs/` (a `Ledger` with an honest `transferSafe`
  Halmos PROVES value-conserving, a buggy `transferBuggy` Halmos REFUTES with a concrete witness, and an
  under-unrolled-loop spec the gate must report **INCONCLUSIVE** — a soundness guard so a not-fully-explored
  loop is never over-claimed as PROVED) plus `demo-halmos.sh`, which asserts all three verdicts against the
  real solver (deterministic, no mock) and prints a single `[SKIP]` + exit 0 when `halmos`/`forge` are not on
  `PATH` (so CI passes without the toolchain). New
  `docs/halmos.md` documents the verdict/exit contract, toolchain install, and how the gate fits the epic
  (the LLM hypothesizes; Halmos is the sound verdict). Honest scope: M1 is the **callable gate only** —
  auto-routing discovery candidates into it (generate-and-verify) is a later milestone. **Requires:** halmos
  >= 0.3 + foundry (forge) for a real run; both are optional for the rest of the federation.
- **The shell loop is DISSOLVED — the federation self-orchestrates the whole multi-step audit in the
  substrate** (#1014 M3). Through M2 the decision and each action's dispatch lived in the substrate, but a
  thin shell while-loop (`run-coordinator.sh`) still **drove** the loop (per step: one `agentis go`, read the
  verdict memo, push/pop `PENDING`, advance `DRY_STREAK`/`BUDGET`, re-read the policy, append a
  `decisions.tsv` row). M3 moves that **entire loop** into `coordinator.ag`: gated on a new
  `ORCHESTRATE_ENABLED` fact, the top level runs the audit as a `reduce` over a budget-bounded `STEPS` list —
  deciding, dispatching in-substrate, reading the verdict, threading `PENDING` / `DRY_STREAK` / `BUDGET` and
  the **evolving policy** entirely in-process, and accumulating the trace — then writes the final
  `decisions.tsv` body + evolved policy to durable memos (`coordinator:trace`, `coordinator:policy_after`).
  The single-decision top level is refactored into a `decide_once()` fn both paths call; with
  `ORCHESTRATE_ENABLED` **absent** the top level does **exactly one** `decide_once()`, **byte-identical** to
  before (the #1 regression guard — `demo-coordinator.sh` is unchanged). The in-process policy is carried in
  the loop's state in ten-thousandths and rendered `%.4f`, so it stays **byte-identical** to the shell's
  experience-store `read_policy()` sum step for step (the loop also `learn()`s for the durable record).
  `run-coordinator.sh` becomes a **bootstrap**: it seeds the facts + a `STEPS` budget list, fires **one**
  `agentis go coordinator.ag` with `ORCHESTRATE_ENABLED`, and reads the final trace + policy back from the
  memos — the per-step shell loop and all shell-side `PENDING`/`DRY_STREAK`/`BUDGET` threading are removed;
  `--executor stub` (offline) and the `--out` trace contract still work. New `demo-orchestrate.sh` proves
  **one** `agentis go` runs a >=3-step audit with distinct chosen actions and that the resulting
  `decisions.tsv` + evolved policy are **byte-identical** to the M2 shell-loop output for the same
  facts/fixture (re-run byte-identical, mock backend, zero cost). `docs/coordinator.md`, `docs/dispatch.md`,
  and `README.md` updated. Honest scope: the loop self-orchestrates per bootstrap invocation; a long-lived
  daemon-tick reflex (the loop running continuously without a shell bootstrap) is a separate refinement still
  on epic #1014. Because the whole loop now runs in **one** `agentis go`, `coordinator.ag`'s `cb` budget must
  cover every step cumulatively (it was raised 300000 → 2000000 to match the colony `cb_budget` and clear the
  default budget with headroom). `run-coordinator.sh` rejects a `--scope`/`--fixture` cell containing the
  reserved `@@F@@` state-field sentinel. **Requires:** agentis >= 1.19.0.

- **Every action's DISPATCH moved into the substrate** (#1014 M2). M1 moved the `hunt` slice; M2
  **generalises** the dispatch to *all* action types. `dispatcher.ag`'s `hunt_dispatch` becomes a `dispatch`
  agent fn that parses the action `<type>` from the bus payload (`<type>|<args>`) and handles `hunt`,
  `refute`, `poc-screen`, and `invent-method`. The offline verdict now comes from a `DISPATCH_FIXTURE` env
  fact whose rules are `type|glob=verdict;…` (a PREFIX glob matched against the action ARGS — a hunt's
  `subsystem|class`, a refute/poc-screen candidate id, or invent-method's empty args; first match wins,
  default `dry`) — the same `<type>|<glob>|<outcome>` shape `run-coordinator.sh`'s `--fixture` holds.
  `HUNT_FIXTURE` is kept as a backward-compat alias consulted for a `hunt` only when `DISPATCH_FIXTURE` is
  empty. The agent keeps an honest per-type LIVE stub when no fixture is set. It writes
  `coordinator:last_outcome = <type>|<args>|<verdict>` and prints `DISPATCH|<type>|<args>|<verdict>`; the
  standalone `DISPATCH_ARGS` entry now takes `<type>|<args>`. `demo-dispatch.sh` is extended to prove the
  in-substrate dispatch + memo round-trip for **hunt, refute, poc-screen, and invent-method**, each with the
  standalone-dispatcher **sync-guard** (run `dispatcher.ag` standalone, assert its `DISPATCH|`/memo equals
  the inlined coordinator path), plus the hunt determinism + fixture-flip checks; deterministic (run twice,
  byte-identical). `docs/dispatch.md`, `docs/coordinator.md`, and `README.md` updated to say all action
  dispatch is now substrate-native (the shell loop remains; only outcome-computation moved). The dispatch
  block stays **dark** when `DISPATCH_ENABLED` is absent, so a standalone `coordinator.ag` run
  (`demo-coordinator.sh`) is **byte-identical** to before this change. **Requires:** agentis >= 1.19.0.

- **The `hunt` DISPATCH moved into the substrate** (#1014 M1). The self-orchestrating coordinator no longer
  just *decides* a hunt — in **one** `agentis go` it also *dispatches* it. `coordinator.ag` `emit`s the
  chosen hunt over the in-process bus (`dark-factory:dispatch`, payload `hunt|<subsystem>|<class>`) and a
  new sibling agent fn `hunt_dispatch` derives the gate verdict from a `HUNT_FIXTURE` env fact (offline,
  no `prompt()`/LLM; the same subsystem-glob → `confirmed|dry|refuted` shape `stub_outcome()` used) and
  writes it to the durable `coordinator:last_outcome` memo (`hunt|<subsystem>|<class>|<verdict>`). The
  emit→listen→call DAG mirrors `auditor.ag`'s sub-agents; the durable memo is the substrate-native
  cross-process channel (the emit/listen bus is in-process only). New
  `auditor/agents/dispatcher.ag` is the standalone, separately-committable copy of the dispatch fn (agentis
  `go` has no file includes, so `coordinator.ag` inlines the same fns gated on a new `DISPATCH_ENABLED`
  flag). New `demo-dispatch.sh` proves it offline + deterministically: one `agentis go` prints both
  `ACTION|hunt|...` and `DISPATCH|hunt|...`, a separate `agentis memo get` reads the verdict back, a re-run
  is byte-identical, and the verdict follows the fixture. It also runs `dispatcher.ag` standalone (its
  `DISPATCH_ARGS` entry) and asserts its `DISPATCH|`/memo output equals the inlined coordinator path — a
  **sync-guard** so the two copies of the verdict fns can't silently drift. The dispatch block is **dark**
  when `DISPATCH_ENABLED` is absent, so a standalone `coordinator.ag` run (`demo-coordinator.sh`) stays
  byte-identical. New `docs/dispatch.md` documents the in-process-bus + durable-memo model and the
  event/fact contract. **Requires:** agentis >= 1.19.0.

### Changed

- **`run-coordinator.sh` dispatches EVERY action through the substrate** (#1014 M2). The
  `stub_outcome()` / `real_outcome()` shell functions and their `case` dispatch are **removed** — the shell
  computes no action's outcome. For every non-`stop` action the loop reads the verdict from the
  `coordinator:last_outcome` memo the coordinator's in-substrate `dispatch()` writes (one `agentis memo get`
  per step). The full `--fixture` content (all rows, not just the `hunt` rows) is passed as
  `DISPATCH_FIXTURE` (projected to `type|glob=verdict;…`) and added to `exec.env_passthrough`
  (`HUNT_FIXTURE` stays whitelisted for the backward-compat alias). PENDING/DRY_STREAK/BUDGET threading is
  unchanged. Header comment + `docs/coordinator.md` updated to mark dispatch-into-the-substrate **done for
  all action types**.

- **`run-coordinator.sh` dispatches a `hunt` through the substrate** (#1014 M1). The hunt branch of the
  shell `case` (`stub_outcome` / `real_outcome`) is replaced by reading the verdict from the
  `coordinator:last_outcome` memo the coordinator's in-substrate dispatch writes; `DISPATCH_ENABLED=1` +
  `HUNT_FIXTURE` are set on the decision call and added to `exec.env_passthrough`. The other action types
  (`refute` / `poc-screen` / `invent-method` / `stop`) keep their existing shell dispatch unchanged, and
  PENDING/DRY_STREAK/BUDGET threading is unchanged. Header comment + `docs/coordinator.md` updated to move
  "dispatch into the substrate" to **Done for `hunt`**.

- **Default LLM backend across the live-reasoning orchestrators switched from the metered `claude -p`
  path to the flat-rate `flat-cyborg` PTY-wrapper backend** (`llm.backend = flat-cyborg`). `run-audit.sh`,
  `run-discovery.sh`, `run-refute.sh`, and `calibrate-evm.sh` now default `BACKEND=flat-cyborg`;
  `run-method-discovery.sh` and `calibrate-sealevel.sh` (previously hardcoded `claude`) emit a
  `flat-cyborg` config; `run-coordinator.sh` gains a `--backend flat-cyborg` branch (its default stays
  `mock`). `--backend claude` remains the explicit metered `-p` opt-in for fidelity-critical work, and
  `--backend mock` (offline-deterministic) is unchanged. Docs/examples (README, RUNBOOK,
  run-observability) updated to show the flat-rate default. **Requires:** agentis >= 1.19.0 (the
  `flat-cyborg` LLM backend) and a `flat-cyborg` binary with `--no-jitter` (>= v0.9.0) on PATH. Note:
  `--extract` is a TUI screen-scrape — for reads where a refusal/malformed reply must never be misread,
  prefer `--backend claude` (fidelity hardening tracked in `Replikanti/flat-cyborg#42`).

### Fixed

- **Coordinator orchestrate loop double-counted the final action's policy on a `stop`/dry-cap stop** (#1026).
  In `ORCHESTRATE_ENABLED` mode `coordinator.ag` attributes each step's PREVIOUS action inside `step_fn`, and a
  post-loop FINAL ATTRIBUTION block attributes the last action the loop did not get to. On a `stop`/dry-cap
  termination the stop-deciding step's `decide_once` had ALREADY attributed that last executed action, so the
  final block counted it a SECOND time — a run with 2 executed hunts ended `hunt=-0.4500` (3 × −0.15) instead
  of the correct `hunt=-0.3000` (2 × −0.15). The carried state now tracks a `lastAttr` flag (state field
  18); the FINAL ATTRIBUTION fires only for an action the in-loop pass did NOT already attribute — and drops
  both the extra `learn()` AND the extra carried-int delta, so the in-loop policy still equals the
  experience-store `read_policy()` sum. Attribution is now IDEMPOTENT: every EXECUTED action (hunt / refute /
  poc-screen / invent-method) is counted EXACTLY once across both termination paths (budget-exhaustion and
  the dry-cap `stop`); `stop` is a decision, never an executed action, so it is never attributed. The
  per-step `decisions.tsv` trace rows are unchanged (the double-count was in the terminal policy only).
  `demo-orchestrate.sh` gains a #1026 regression guard (proof (5): a dry-cap-terminated run attributes the
  last action exactly once — N executed hunts → N × the delta, not N+1) and its comments note the in-substrate
  policy is now the correct once-per-action attribution (no longer reproducing the M2 shell loop's stop-path
  double-count — that was the bug). The single-decision path (`demo-coordinator.sh`, `ORCHESTRATE_ENABLED`
  absent) is byte-identical, and the budget-exhaustion GOLDEN (`hunt=0.6000;refute=-0.6000`) is unchanged
  (that path never double-counted).
- **`run-coordinator.sh` dispatch dropped a hunt's class** (#1014 v1 follow-up). The coordinator's
  `ACTION|<type>|<args>|<rationale>` line was parsed with a flat `cut -f3`/`-f4-`, but a `hunt`'s
  `<args>` is two `|`-fields (`subsystem|class`) where every other action's is one. The class leaked
  into the logged rationale and the queued PENDING candidate id was built malformed as
  `cand-N|subsystem` instead of the documented `cand-N|subsystem|class`. The parse is now type-aware
  (hunt → fields 3-4 for args, 5- for rationale), mirroring `demo-coordinator.sh`. Also documented the
  stub fixture's subsystem-prefix-glob rule (an args-glob must not contain a literal `|`) and fixed
  `README.md` heading blank-line spacing (MD022).

### Added

- Discovery: **self-orchestrating coordinator — fact-based, evolving decision policy** (v1 of #1014). The
  discovery colony used to take its workflow from a FIXED script (`run-discovery.sh`'s `(subsystem ×
  class)` fan-out) and an external operator (target / method / when-to-stop). A new
  `auditor/agents/coordinator.ag` moves that DECISION-MAKING into the substrate: each `agentis go`
  invocation it reads the current FACTS (open scope, per-class lens fitness, the shared blackboard #1001,
  pending unverified candidates, remaining step budget, and the previous action's gate OUTCOME — a FACT,
  never an LLM judgement) and an evolving POLICY, then chooses ONE next action from
  `hunt|<subsystem>|<class>` · `refute|<cand>` · `poc-screen|<cand>` · `invent-method` · `stop` and emits
  exactly one `ACTION|<type>|<args>|<rationale>` line whose rationale CITES the facts that drove it. The
  choice is a policy-weighted ARGMAX over fact-criteria (verify a pending lead before more hunting; prefer
  a blackboard-flagged subsystem and a higher-fitness lens; stop on budget-exhausted or K consecutive
  dry), then the substrate `decide(options, criteria)` builtin selects from that already-fact-ranked list
  — so the ordering is the coordinator's, from facts+policy, never a fixed order. The decision policy
  EVOLVES by outcome: the coordinator records each action's confirmed-finding → success / dry-or-refuted →
  failure with the SAME `learn()` mechanic the lens-fitness loop uses (#996), so the cumulative experience
  delta per action-type IS `coordinator:policy:<action-type>` and reweights which decisions it leans on.
  `run-coordinator.sh` is a thin DISPATCHER (NOT a decider): it loops {ask the coordinator → execute the
  chosen action → feed the outcome back} until `stop`/budget, reads the cumulative policy back from the
  experience store between calls (mirroring `evolve-fitness.sh`), and routes a real run to
  `hunter`/`refuter`/`poc-screener`/`method-inventor` or an offline stub executor. `demo-coordinator.sh`
  proves BOTH acceptance criteria OFFLINE + DETERMINISTICALLY (mock backend, no network): (a) three
  distinct fact-states choose three DIFFERENT actions — a pending candidate → refute, no-candidate with
  the top lens C8 → hunt C8 while the same options with C1 on top → hunt C1 (the choice follows the
  fitness FACT, not a fixed cell), budget=0 → stop — and (b) over a sequence where hunts confirm and
  refutes are refuted, `coordinator:policy:hunt` ROSE (`+0.000 → +0.600`) while `coordinator:policy:refute`
  FELL (`+0.000 → −0.600`), with the demo exiting non-zero if the policy did not move. v1 boundary
  (`docs/coordinator.md`): the coordinator DECIDES, the shell still DISPATCHES; full event-driven
  substrate dispatch (no shell loop), manifest reprioritisation, and multi-target portfolio decisions stay
  follow-up on the epic. The human-gated submission boundary and the forge-verify / refuter / `eval_ag`
  safety gates are unchanged — they remain FACTS the decision consumes, never bypassed.

- Discovery: **inter-agent coordination via a shared blackboard** — a first coordination primitive so
  hunter cells influence each other within a run, instead of the run being a flat sum of independent
  one-shot audits (#1001). The discovery fan-out runs every (subsystem × class) cell against ONE shared
  agentis memo store, so `hunter.ag` now READS a rolling `dark-factory:blackboard:leads` memo before it
  prompts and WRITES every CANDIDATE back to it (+ emits `dark-factory:lead`). A later cell that finds a
  sibling's lead on the board is STEERED — its prompt gains a FOCUS block telling it to corroborate a
  hit in the same subsystem or pivot toward a related attack surface a sibling already flagged.
  `run-discovery.sh` surfaces both halves of the loop (a `↳ COORDINATION:` log line when a cell is
  steered, a "posted a lead" line when one contributes) and appends an **Inter-agent coordination**
  table to the discovery report. The mechanism is inert on a clean sweep (no finding → no steer → the
  prompt and the existing rigorous-negative contract are byte-identical), so it is additive and does not
  change single-cell behavior. `demo-blackboard.sh` proves the loop end-to-end OFFLINE (deterministic
  fake LLM, no network): an oracle cell posts a stale-price lead and a downstream liquidation cell reads
  it — the demo asserts the liquidation cell's prompt actually carried the oracle lead, so the steer is
  real, not cosmetic. Scoped as ONE coordination step; the broader emergent-behavior vision (a
  coordinator that reprioritizes/prunes the cell manifest from the board) is deliberately left as
  follow-up — no overclaim of emergence.

- Substrate-native lead pre-screen via **`eval_ag`** (#997). The discovery hunter surfaces a CANDIDATE
  as a *prose* PoC sketch — an unverified lead — and the only gate was `evm-harness/forge-verify.sh`, a
  full Foundry deploy + attacker tx that needs the cloned repo + `foundryup` and runs slowly. A new
  cheap gate runs first: `auditor/agents/poc-screener.ag` lowers a lead's machine-checkable invariant to
  a self-contained `.ag` PoC harness and evaluates it through the substrate's `eval_ag` primitive — a
  metered sub-interpreter with its own CB budget. It returns the stable outcome discriminator
  (`success` / `parse_error` / `compile_error` / `inner_cb_exhausted` / …) so the screen distinguishes
  "invariant HELD" (a clean run returning `0`) from "junk harness", and a runaway harness is CONTAINED
  (the inner CB meter trips → `inner_cb_exhausted`) instead of crashing the screener. The harness
  contract mirrors the colony's exit-101 two-sided gate (return `101` = INVARIANT VIOLATED = reproduced).
  `screen-leads.sh` drives it over a `lead-id | harness.ag` manifest and emits a verdict table; every
  screen is recorded via `learn()` + `emit("dark-factory:poc_screened", …)`. A reproduced screen is a
  lead worth the forge-verify cost, NOT a finding — submission stays human-gated.
  - **Demoed end-to-end** (`screen-leads.sh --demo`, zero external prerequisites): a reentrancy-vuln
    harness → `reproduced | success | 101`, its CEI-fixed variant → `held | success | 0`, a malformed
    harness → `indeterminate | parse_error`, and a recursion-bomb harness → `indeterminate |
    inner_cb_exhausted` with the screener surviving.
  - Documented in `docs/SUBSTRATE-PRIMITIVES.md`: which substrate primitives the colony adopted and,
    honestly, why `replicate` (needs a live colony pool + peer; a fatal error otherwise), `delegate`
    (no second in-process cooperating agent), `decide` (a soft choice where the colony deliberately
    keeps a hard mechanical gate), the Lean verifier (wrong proof object for runtime exploit
    reproduction), and confidence-tiers (the colony is one-shot + human-gated, with no autonomous write
    to throttle) do not currently fit.
  - **Correction (#997 QA):** the `eval_ag` containment claim was overstated and is now narrowed to what
    actually holds. `eval_ag` does NOT sandbox `exec` in agentis v1.18.27 — a harness that calls
    `exec sh` from inside `eval_ag` escapes to the host, so the earlier "cannot touch the host" /
    "exec-free grant set" wording was wrong. What `eval_ag` DOES guarantee is **CB-exhaustion
    containment**: a runaway/infinite harness is bounded by the inner CB budget (`inner_cb_exhausted`)
    so it cannot starve or crash the screener. Harnesses must therefore be operator-trusted. The docs /
    agent comments (`README.md`, `docs/SUBSTRATE-PRIMITIVES.md`, `auditor/agents/poc-screener.ag`,
    `screen-leads.sh`) are reworded; the two-sided gate is also clarified as an author convention the
    screener does NOT mechanically enforce (it maps the final int — it cannot detect a missing control
    assertion), with mechanical two-sidedness enforced downstream by the forge-verify gate. No behavior
    change.
- `run-summary.sh` + `docs/run-observability.md` — make a one-shot run **observable** without touching
  the separately-versioned `federation-dashboard` component (#995). dark-factory runs one-shot via
  `agentis go` (no daemons, no `*:confidence` memos), so the dashboard — which assumes daemon-tick
  agents with confidence-tier memos — has nothing to poll. `run-summary.sh` closes that gap on the
  dark-factory side: pointed at a run's `--out` dir it distills the run's on-disk artifacts (the
  agentis experience log + the run report) into one stable JSON at `<out>/run-summary.json` — runs/cells
  executed, candidates found, `learn()` outcomes, **per-class fitness** (`success / attempts`, read from
  the experience store), last-run timestamp, and verdict (discovery: `LEADS`/`SAFE`; audit: the
  `Verdict:` line). It only READS what the run wrote — never mutates the store, never contacts a
  platform. JSON is built with `python3` `json.dumps` (schema `dark-factory/run-summary@1`); `--json`
  emits pure JSON on stdout (jq-safe), `--emit-event` appends one `dark-factory:run_summary` NDJSON line
  to `<out>/events.jsonl` for a tailing monitor. `docs/run-observability.md` documents the schema +
  three consumer shapes (poll the file / tail the event stream / aggregate across runs). Validated
  end-to-end against a real mock-backend discovery run and synthetic discovery/audit fixtures (LEADS +
  SAFE verdicts, non-zero per-class fitness, the no-experience-log fallback). `shellcheck`-clean,
  `bash -n`-clean.
- Substrate-native ADVERSARIAL REFUTATION — the first of the colony's deep audit capabilities ported
  off externally-orchestrated subagents onto the agentis substrate (#999). The deepest steps (deep
  cross-function audit, build-and-run PoC, fork-differential, adversarial refutation) ran as external
  subagents, so the federation was a hybrid: a thin `.ag` layer + heavy external orchestration. This
  ports the `adversarial-refute` step (`auditor/methods/registry.md`) into a real `.ag` agent as the
  proven pattern for the rest:
  - `auditor/agents/refuter.ag` — a substrate agent modelled exactly on `hunter.ag` (cb 300000;
    one-shot, no `fn tick`; env reads via `getenv`; code read via `exec sh` with
    `// colony-lint: safe-exec-concat`; two-arg `prompt(instruction, payload) -> string`; `emit`;
    `print`). It env-ins ONE candidate finding (`file:fn` + claimed exploit + class) and the relevant
    code, runs an INDEPENDENT skeptic that tries to REFUTE the claim against the actual control/data
    flow — defaulting to REFUTED on any doubt so only unambiguous leads survive — `emit`s
    `dark-factory:refute_verdict`, records the attempt via `learn()` (REAL=success, REFUTED=failure, so
    refuter fitness rewards leads that survive a hostile read), and `print`s exactly one
    `VERDICT|REAL|…` / `VERDICT|REFUTED|…` line.
  - `run-refute.sh` — operator entrypoint. Sets up the rundir + `.agentis/config` (env passthrough for
    the candidate contract + `claude` backend) and runs the refuter once per candidate from a
    `file:fn | class | severity | exploit | code-file` manifest, staging each code file into the rundir
    so the sandboxed `exec sh` (which cannot read `$HOME`) can always reach it. Collects verdicts into a
    report. A REAL verdict is a LEAD that survived the gate, not a finding — it still must reproduce
    through `evm-harness/forge-verify.sh` before it counts, and submission stays human-gated; this tool
    never posts to a platform.
  - This is the second gate, AFTER `hunter.ag` surfaces a `CANDIDATE` and BEFORE the operator spends a
    Foundry PoC: a separate skeptic with no stake in the finding must fail to break it.
  - **Demoed end-to-end on the real `claude` backend** over two sample candidates: a guarded `sweep()`
    behind `onlyOwner` was correctly **REFUTED** (the `require(msg.sender == owner)` reverts for any
    unprivileged caller), and a `withdraw()` that sends ETH before zeroing the balance was correctly
    judged **REAL** (CEI violation → reentrancy, no guard) — surviving to the forge gate. The full
    `prompt → VERDICT → emit → learn` loop ran on the substrate (2 experience rows: one success, one
    failure).
  - Follow-up (#999): port the remaining deep capabilities the same way — deep cross-function audit,
    build-and-run PoC (forge/PoC harness via sandboxed `exec`), and fork-differential analysis — so the
    federation owns the full audit pipeline end-to-end rather than depending on an external orchestrator.
- Release wiring (#1002) — `dark-factory` is now a first-class release target. The shared
  `tools/make-federation-bundle.sh dark-factory <X.Y.Z>` already stages a curated tarball from
  `BUNDLE.manifest`; this change registers the `dark-factory-v*` tag prefix in
  `.github/workflows/release.yml` so a tag push builds the bundle and creates/updates the GitHub
  release automatically (same flow as the other federations). `dark-factory/` was already tracked by
  `tools/check-changelog.sh` (added in #965), so the `[Unreleased]` soft-check covers it too. After a
  release PR merges: `git tag dark-factory-v<X.Y.Z> <merge-sha> && git push origin dark-factory-v<X.Y.Z>`.
- `evolve-fitness.sh` + `auditor/agents/fitness-driver.ag` — actually drive the discovery colony's
  evolve/fitness LOOP over several runs and DEMONSTRABLY move per-class/per-method fitness in the agentis
  experience store (#996). Until now `hunter.ag` recorded each hunt via `learn("hunt", "<class>:<subsystem>",
  ..., outcome, [...])`, but nothing drove that loop across runs, so no evolved state accrued. The new
  driver runs the colony's REAL recording path — `fitness-driver.ag` makes the IDENTICAL `learn()` call
  `hunter.ag` makes — over a built-in ground-truth corpus (taxonomy class x subsystem, each with a known
  CANDIDATE/SAFE verdict), repeated for N iterations, then reads the experience store BEFORE and AFTER and
  prints the per-lens fitness delta. It is fully offline and reproducible (`--backend mock` semantics, no
  LLM call — per #996 the point is the fitness LOOP, not LLM quality; verdicts come from the corpus), and
  exits non-zero if the loop fails to move fitness. The built-in corpus encodes a realistic gradient so
  high-yield lenses (vault accounting, rounding, reentrancy) pull ahead while speculative ones (cross-chain,
  pause) fall behind — the colony's evolved ranking of which lenses to lean on. Validated end-to-end:
  60 cells over 6 iterations moved fitness on 9/10 lenses (C1/C6 +0.600, C3 -0.600); re-runs are
  byte-identical. `--corpus` overrides the corpus, `--json` emits a machine-readable before/after table.

- `gen-agent.sh <method-name>` — close the self-extension loop (#1000). The
  method-discovery meta-loop (`method-inventor.ag` + `run-method-discovery.sh`,
  #998) invents and adopts new audit *methods* — reusable hunting techniques
  recorded as `METHOD|name|classes|technique|how-to-invoke|status|fitness` lines
  in `auditor/methods/registry.md` (an `invented` line carries an extra
  control-assertion field before `status`) — but could not turn an adopted method
  into a new AGENT; the agent set was fixed. The generator reads one
  `METHOD|<name>|...` line (parsing both the builtin 7-field and invented 8-field
  shapes) and materialises `auditor/agents/<name>.ag`, a colony-lint-valid
  one-shot discovery agent (modelled on `hunter.ag`: `cb 300000;`, env reads, a
  `safe-exec-concat` file reader, a single adversarial `prompt()`, and an
  `emit()` + `learn()` so the method's per-target fitness reweights over runs —
  the #861 evolve loop, now over a generated method-agent). The method's
  technique / how-to-invoke / control-assertion (or a generic two-sided gate for
  builtin methods) are wired into the agent's instruction; the agent prints one
  `CANDIDATE|...|method=<name>|...` line per finding (else `SAFE`) for the
  forge-verify gate. Refuses to overwrite an existing agent (exit 3) and rejects
  non-kebab-case names (exit 2). Demo: adopted the `stateful-invariant-fuzz`
  method (the multi-transaction-invariant gap the federation itself flagged in
  `auditor/methods/gap-stateful.md`) into the registry and generated
  `auditor/agents/stateful-invariant-fuzz.ag` from it — passes `colony-lint.sh`
  (`agentis commit` syntax + `check-exec-sh`).

- **Method-discovery meta-loop** — `run-method-discovery.sh` + `auditor/agents/method-inventor.ag`
  + `auditor/methods/{registry.md,gap-stateful.md}` + `auditor/method-discovery/controls/` (#998,
  #1003). The federation's self-improvement layer: when the current method-set plateaus, the
  method-inventor proposes ONE new audit method and it is adopted into the registry ONLY if it
  DISCRIMINATES on a known-bug control corpus (a planted accounting/solvency bug — `BuggyBank` —
  caught while the paired clean `SafeBank` twin stays green). That two-sided gate (buggy suite
  FAILS + safe twin PASSES) keeps method invention empirical rather than speculative. An adopted
  `invented` row carries the proposal's control-assertion before `status` (the 8-field shape
  `gen-agent.sh` consumes).

- `state-export.sh` — export / verify / import a *trained* dark-factory federation's EVOLVED STATE
  (#994, #1004): the accumulated learned `memo` plus the content-addressed Merkle DAG of audited
  patterns, packaged into a portable, **checksum-verified** artifact. It deliberately EXCLUDES the
  federation identity (private key), per-deployment config, and the transient sandbox, so an
  importer keeps their OWN identity and only inherits the learned state — the technical enabler for
  distributing a trained federation (agentis-core#864). The checksum proves integrity, not
  authenticity: sign the manifest out-of-band before third-party distribution.

- `contest-watch.sh` — a durable, host-cron-able watcher for newly-opened audit competitions (Sherlock
  API + Cantina/Code4rena probes). On a fresh contest it notifies via a state file / optional webhook /
  optional command, so an early audit pass can start day-1; it survives across sessions, unlike an
  in-session reminder. Validated: detects a RUNNING contest, stays silent when the platforms are dry.

- Discovery: **function-level slicing** + a 600s deep-read budget (#863). A scope entry can now be
  written `file@fn1+fn2` to feed the hunter ONLY those functions (plus the contract header) instead of
  the whole file — `auditor/slice-fns.sh` (awk, brace-matched) extracts them, wired through
  `hunter.ag`'s `cat_file` (via the `SLICER` env) and `run-discovery.sh`. This fixes the deep
  liquidation/redemption cells timing out on big contracts, where a whole-file concat overflowed the
  LLM per-call budget (e.g. a Compound-fork `CToken.sol` 1193→134 lines, a credit-vault
  `CollateralVaultBase.sol` 611→152 lines). The discovery LLM timeout is also raised 300s→600s — the
  reasoning, not the payload, is the real cost, and one 600s attempt beats three wasted 300s retries.

- Custom-code DISCOVERY track — the colony can now hunt bugs in bespoke, never-forked protocols, not
  just match known-fork patterns (#863). The DAG matcher (`auditor.ag`) fires only where in-scope code
  recurs a seeded pattern, so it returns nothing on custom contest code (a fresh stablecoin, a new
  vault). The discovery track closes that gap, entirely on the agentis substrate:
  - `auditor/agents/hunter.ag` — a substrate discovery agent. One invocation hunts ONE bug class over
    ONE subsystem: it slurps the in-scope contracts, loads the taxonomy lens + protocol brief, runs a
    deep adversarial `prompt()`, and records the attempt via `learn()` (+ `emit`) so per-class fitness
    reweights over targets (the #861 evolve loop, now over discovery).
  - `auditor/bug-taxonomy.md` — the discovery knowledge: 14 DeFi bug classes (share-price/ERC4626,
    oracle, cross-chain/LZ, withdrawal-queue, access-control, accounting, sig-replay, reentrancy,
    decimals, liquidation, first-depositor, slippage, compliance, fork-delta), each with a "hunt" lens
    distilled from real audits.
  - `run-discovery.sh` — operator entrypoint. Takes `--repo` + a `--scope` manifest
    (`subsystem | classes | files`) + a `--brief` (invariants-to-break, known-issues-to-exclude, trust
    model) and fans out one substrate hunter per (subsystem × class), collecting `CANDIDATE` leads into
    a report. Never posts to a platform; surfacing harness-checkable leads is the whole job.
  - `evm-harness/forge-verify.sh` — the multi-contract verification gate. A custom protocol needs a full
    Foundry deployment + attacker tx + invariant assertion (not the single-function revm harness), so a
    candidate is VERIFIED only when its `Exploit.t.sol` PoC PASSES against the in-scope repo. A lead that
    does not reproduce is not a finding (no junk submitted).
  - **Proven end-to-end on a live, 3×-audited custom yield-bearing-stablecoin Sherlock contest**: the
    substrate hunter read the ERC4626 savings + rewards-distributor contracts under the C1 share-price
    lens and returned a reasoned `SAFE` — a rigorous negative, the valid outcome on audited code. Wiring
    is mock-smoke-tested; the real claude pass completes the full prompt→verdict→learn loop.

- M4 evolution — the matcher granularity tunes itself by fitness (#861). The fuzzy matcher's
  granularity (shingle-Jaccard threshold × shingle width `k`) is the knob no human can hand-tune:
  too loose floods synthesis, too tight misses forks, and the sweet spot is unknown a priori — a
  search problem, and the fork-pair recall harness IS the fitness function. `auditor/agents/
  pattern-evolver.ag` + `evolve-matcher.sh` search the genome against a held-out fork-pair oracle
  (forkpair-recall.js), record EACH candidate as substrate experience via `learn()`, select the
  F-beta-max config (beta>1 = recall-leaning, since the two-sided gate absorbs false matches), and
  write `evolved:fuzzy_threshold` / `evolved:fuzzy_k`. `run-audit.sh --use-evolved <dir>` adopts that
  config (also `--fuzzy-threshold` / `--fuzzy-k` to set them directly); `fuzzy-match.js` /
  `forkpair-recall.js` gained a `k` arg, and reconn/recall-match pass `FUZZY_K`.
  - **Proven end-to-end on Compound→Venus**: the hand-set default (th=0.35, k=4) scores F-beta 0.549
    (recall 54%); the evolver searched 15 genome points and picked **th=0.25, k=4 → F-beta 0.674
    (recall 85%)** — a config no human chose — then `run-audit --use-evolved` adopted it
    (`adopted evolved matcher granularity threshold=0.25 k=4`) and fuzzy-matched a real fork. The
    granularity is now fitness-driven, not hand-guessed; `--beta` tunes the recall/precision trade.

- M3 held-out recall harness + knowledge-market sharing (#861). Measures whether the seeded DAG
  catches a finding's FORK it did not see seeded, and shares the corpus across the federation:
  - `recall.sh` + `auditor/agents/recall-match.ag` seed with the real `seed-patterns.ag` (zero
    seed-side drift) and match each held-out target with a mirror of reconn's exact + structural
    matchers, then tally exact-only vs structural recall per class + precision on negatives.
  - `evm-harness/make-variants.js` generates realistic fork variants of a seeded function (rename /
    reformat / re-literal = what a real N-day fork is) plus structural negatives (call-kind swap,
    injected guard) that MUST NOT match. Reuses `struct-sig.js`'s exported KEEP set so a renamed
    fork keeps the same signature; `struct-sig.js` now `module.exports` its token rules.
  - `harvest-sherlock.js` handles BOTH Sherlock judging layouts — the old `NNN-H`/`NNN-M` folders
    and the new flat `NNN.md` files (severity inside the file).
  - **Synthetic result** on 41 real shape-based findings from 4 Sherlock contests (164 held-out
    forks): exact-only recall 6%, structural recall 94%. But these forks are GENERATED
    (rename/reformat/re-literal) — exactly the transforms struct-sig was built to be invariant to —
    so 94% is an **upper bound on near-verbatim forks**, not a real-world hit-rate.
  - **Real fork-pair result** (`evm-harness/forkpair-recall.js`, the honest measurement): seed a
    function from one protocol and match the SAME function as actually deployed in a protocol that
    forked it — Compound `CToken.sol` vs its Venus `VToken.sol` fork, 48 shared functions. Exact
    signature recall is **17%** (only the simple getters; the vuln-bearing functions like
    `redeemFresh`/`accrueInterest` are ~2x rewritten in the fork and never hit). Two struct-sig
    fixes surfaced by this (modifier-order canonicalization + `uint`/`uint256` aliasing) lifted it
    from 0% to 17%.
  - **Fuzzy matcher** (`evm-harness/fuzzy-match.js`) — the recall lift for REAL forks. Matches on
    shingle-Jaccard SIMILARITY instead of signature equality, so a restructured fork still hits:
    Compound->Venus fuzzy recall **69% @ 0.30 / 54% @ 0.35 / 46% @ 0.40** (incl. the vuln functions),
    at ~52-67% precision (structurally-similar-but-different functions also match — gate-safe, a
    false candidate costs one inconclusive synthesis, never a finding). Wired into reconn
    (`match_seeded_fuzzy_evm`, the third fallback after exact + structural) and the recall harness.
    Proven end-to-end through the colony: seed Compound `redeemFresh`, audit Venus's real forked
    `redeemFresh` (Jaccard 0.41) -> `SEEDED FUZZY MATCH -> Reentrancy`, guard fired `[High]` where
    exact + structural both missed.
  - Known limitation: the in-`.ag` `strip_comments` accumulates an O(n^2) string heap and overflows
    on a full ~1500-line real contract target (the exact/structural paths run it first). Real
    full-contract auditing needs that rewritten; single-function and mid-size targets are unaffected.
  - `auditor/agents/share-patterns.ag` + `run-audit.sh --share-patterns` publish each seeded
    `bugpat:exact:<hash>` / `bugpat:struct:<hash>` to the knowledge market (`knowledge_sell`, keyed
    by content hash) so other federation members can `knowledge_buy` it — "share the DAG via the
    knowledge market". The buy side is a real economic exchange (the buyer escrows the ask price
    from its CB pool), so importing a shared pattern requires a funded consumer.

- M1+ structural-variant bug-pattern matching (#861) — `evm-harness/struct-sig.js` + a new reconn
  fallback. Exact-hash seed matching (the prior M1) catches only a byte-identical N-day fork of a
  recorded finding; this also catches a RENAMED / REFORMATTED / RE-LITTERED fork. `struct-sig.js`
  normalizes each Solidity function to a parser-free structural signature (identifier names → `_`,
  literals → `0`, keeping Solidity keywords / types / external-call kinds), so a variant collapses to
  the same content hash as the seed — no solc, so it works on a bare harvested fragment too.
  `seed-patterns.ag` now seeds `bugpat:struct:<hash> = class` alongside the exact one (guarded to sigs
  that carry a call-kind or storage-write, so a trivial getter is never seeded), and reconn
  (`match_seeded_any_evm`) tries the exact match first, then the structural fallback. Proven end-to-end
  through the colony: a Reentrancy seed matched a renamed/reformatted variant (`SEEDED STRUCTURAL
  MATCH -> Reentrancy`, guard fired `[High]`) where exact-match returned nothing, while a CEI-reordered
  SAFE version correctly did NOT match. A structurally-edited variant (reordered statements / changed
  expression shape) is out of scope for v1 — that needs an AST/semantic signal. An over-broad match can
  never mint a false finding: it only sets the candidate class; the two-sided synthesis gate stays the
  only source of truth.

### Fixed

- Discovery hunter was blind — `auditor/agents/hunter.ag` now reasons FIRST (#993). The prompt
  drove the LLM straight to a verdict, so it returned `SAFE` even on textbook in-scope bugs. The hunt
  prompt is reordered so the agent must enumerate the bug-class lens and walk the in-scope code
  BEFORE it emits `CANDIDATE`/`SAFE` — surfacing leads it previously missed, with the two-sided
  forge-verify gate still the only path from lead to finding.
- Real FULL-contract auditing — `strip_comments` no longer overflows the string heap (#861). The
  in-`.ag` `strip_comments` builds its result with `reduce(lines, |acc,l| acc + ...)`, which is
  O(n²) string allocation and overflowed the 16 MiB per-tick string heap on a full ~1500-line real
  contract — so reconn/guard died before ever matching, and the colony could only audit extracted
  single functions. agentis has no `join`/`regex_replace` builtin for an in-`.ag` O(n) rewrite, so
  the EVM path now offloads to `evm-harness/strip-comments.js` (O(n), reuses struct-sig.js's
  stripComments); the Rust path keeps the in-`.ag` stripper. Seed + match both offload, so exact
  hashes stay aligned. Proven: the full 84 KB Venus `VToken.sol` (65 functions) now audits
  end-to-end — `distilled 65 sub-graph(s)` → `SEEDED FUZZY MATCH -> Reentrancy` → guard fired
  `[High]`, where before it died in `strip_comments` with `string_heap limit exceeded`.
- Decomposed-synthesis EXPLOIT slot now uses `try_call`/`try_call_value` (revert-tolerant) for the
  attack step instead of `call`/`call_value` (which `die` on a revert). On a secure target the attack
  reverts — which means the invariant HELD — but a plain `call` turned that into a false
  `HARNESS ERROR` (exit 2) that masked the verdict and burned `retry(5)` rounds. Surfaced running the
  colony on a real complex target (Cyfrin Puppy Raffle): the decomposed synthesis produced
  sophisticated correct exploit code and CONTROL passed, but the exploit's `call` reverted → exit 2.
- Real-repo compile robustness in `evm-harness/solc-resolve.js`: (1) handle caret/range pragmas
  (`^0.7.6`, `~0.8.4`, `>=0.7.0 <0.8.0`) by selecting the floor solc version when its minor differs
  from the local pinned build (real repos overwhelmingly use caret pragmas; an exact-pin-only match
  fell through to the local solc and failed with "requires different compiler version"); (2) resolve
  Foundry-default remappings written WITHOUT a trailing slash (`@openzeppelin/contracts=lib/…/contracts`)
  via `path.join` instead of `path.resolve` (the no-trailing-slash remainder starts with `/`, which
  `path.resolve` treated as absolute and discarded the project prefix → "import not found"). Surfaced
  by running the colony on a real OpenZeppelin-based Foundry target (compiles 0.7.6 + resolves OZ imports).

### Added

- M2 harvest — `harvest-sherlock.js` pulls real findings from a Sherlock judging repo (the `NNN-H`/`NNN-M`
  valid-finding folders) into a seed manifest for the DAG bug-pattern matcher (#861). It maps each
  finding's title/lead to one of the colony's verifiable classes (Reentrancy / AccessControl /
  UncheckedCall / OracleManipulation / IntegerOverflow) by keyword cue, extracts the vulnerable function
  from the finding's `solidity` block, and emits `<NNN>.sol` + a `Class|path|func-marker` manifest that
  `run-audit.sh --seed-manifest` feeds to the seeder. Findings whose root cause is NOT one of the five
  classes (subtle / multi-contract logic) are skipped — the harness can't verify them anyway. Proven on
  the Alchemix Sherlock contest: 20 findings -> 4 real patterns seeded with their actual functions.
  (Exact-hash match catches verbatim N-day forks of these; structural-variant matching is the next step.)

- DAG bug-pattern matching — seed the federation's content-addressed DAG with real findings so the
  colony recognizes recurring patterns (N-day forks) on real targets (#861). `seed-patterns.ag` +
  `run-audit.sh --seed-manifest` record a finished-contest finding's vulnerable-function sub-graph as
  `bugpat:exact:<hash> = class`; reconn's new `match_seeded_evm` looks up each target sub-graph against
  the seed (mirroring `distill_subgraphs_evm`'s hashing) and guard fires the matched class **directly**,
  beating the LLM classifier's conservative SAFE on real audited code (which returned SAFE on 13/13 real
  contracts in testing). The two-sided real-EVM gate still verifies, so a stale/over-broad seed can never
  mint a false VERIFIED — worst case one inconclusive synthesis. Proven end-to-end: seed VulnToken's
  `mint` (AccessControl) → a fork (renamed contract, identical `mint`) matches → guard fires via the seed
  (no LLM) → synthesis VERIFIED. Exact-hash match catches byte-identical N-day forks; structural-variant
  matching + a harvest of real findings are the next steps.
- Decomposed EVM PoC synthesis (#982). The synthesis agent no longer asks the LLM for the WHOLE
  `poc.rs` in one prompt — a large OUTPUT that stalls `claude -p` on a non-trivial contract (a real
  target's one-shot never returned at a 600s timeout; a small-output fragment prompt returns in
  ~40s). Instead a fixed skeleton (`evm-harness/poc-skeleton.rs`) carries all the revm-14 boilerplate
  + helpers, and the LLM fills only two small slots — the CONTROL block and the EXPLOIT block (~15
  lines each) — which `evm-harness/assemble-poc.js` splices in. Each generation is small + fast and
  the LLM writes far less error-prone code (the helpers handle the fiddly revm API). The two-sided
  gate (`CONTROL OK:` + `INVARIANT VIOLATED:` + exit 101) is unchanged. Validated end-to-end through
  the live colony: a real OpenZeppelin Foundry target reaches VERIFIED in ~48s on the first attempt.
  Solana / std-only targets keep the single one-shot prompt (their PoCs are smaller).
- Real multi-file Foundry/Hardhat target support (#980). The EVM colony can now compile + run on
  real multi-file projects (OpenZeppelin/lib imports, inheritance, a project-pinned solc), not just
  self-contained single-file contracts. A project-aware compiler (`evm-harness/compile-project.js`
  + shared `evm-harness/solc-resolve.js`) resolves a target contract's imports via the project's
  remappings + layout (lib/ submodules, node_modules) and selects/loads the project's solc version
  (offline from an on-disk soljson cache, host-side `--warm` pre-download); a dep-fetch helper
  (`fetch-target.sh`) clones a target repo with its submodules/deps; `run-audit.sh` gains
  `--repo` / `--in-scope` / `--contract`; and the `auditor.ag` `compile_run` + reconn (`ast.js`)
  paths dispatch to the project compiler when a repo target is set. The colony detects + verifies
  the single-contract bug classes on real code via the unchanged two-sided real-EVM gate; complex
  multi-contract protocol-exploit verification remains the later frontier.
- EVM/Solidity auditing — M4 (agentis-core#858). The EVM calibration corpus + harness, the peer of
  the Solana `calibrate-sealevel.sh` / `sealevel-scorecard.md`. A five-class vuln+safe corpus in
  `evm-harness/contracts/` (Reentrancy + AccessControl reused from M1–M3, plus new UncheckedCall,
  OracleManipulation, and IntegerOverflow pairs — each vuln written to be unambiguously its own
  class, all solc-0.8.26-compileable with committed `contracts/bin/*.bin`), `calibrate-evm.sh`
  (runs `run-audit.sh` over the five class pairs, tallies true-positive / false-VERIFIED /
  non-SAFE, parameterized by `BACKEND`/`AGENTIS`/`EVM_HARNESS_DIR`), and `evm-scorecard.md` (the
  scorecard doc with the corpus table, methodology, and an operator-fillable RESULTS template).

- EVM/Solidity auditing — M2 + M3 (agentis-core#858). **M2**: real Solidity reconn ingest
  (`evm-harness/ast.js`, solc AST → the canonical `{kind,name}` node stream → DAG), replacing
  M1's `.sol` bypass so EVM targets get the full reconn→guard→tracker pipeline (target hash
  unchanged → verdict cache + two-sided gate intact). **M3**: the full EVM class set —
  `classify_evm_llm` returns Reentrancy | AccessControl | UncheckedCall | OracleManipulation |
  IntegerOverflow | Safe, each with a per-class CONTROL/EXPLOIT invariant (`evm_invariant_for`)
  fed to the revm-PoC synthesis, plus the EVM peer of the #852 anti-forgery gate
  (`pocChallenge_<nonce>` injected into the target; a supplied `--poc` must surface the nonce or
  is rejected — fail-safe). Validated end-to-end on the live runtime: AccessControl vuln →
  `VERIFIED` (Critical) + human-gated package, the guarded variant → `SAFE`; reentrancy unchanged.

- EVM/Solidity auditing in the colony — M1 (agentis-core#858). `auditor.ag` now dispatches on
  `EVM_HARNESS_DIR` / a `.sol` target: the LLM writes a self-contained `revm` PoC, the target +
  a generic reentrancy attacker are solc-compiled host-side (`evm-harness/compile.js`, solc 0.8.26
  pinned via `package.json`), and the PoC runs the unchanged two-sided gate (`CONTROL OK:` +
  `INVARIANT VIOLATED:` + `exit 101`) through the real EVM (revm). `run-audit.sh` gains
  `--evm-harness` and accepts `.sol` targets; the submission package preserves the EVM PoC +
  attacker. Validated end-to-end on the live runtime: the reentrancy vault → `VERIFIED` +
  human-gated package; the secure variant → `SAFE` (no false-VERIFY). Scope is the reentrancy
  class with a `.sol` reconn bypass; Solidity reconn ingest (M2) and the broader EVM class set
  (M3) follow.

### Security

- Harden the supplied-`BOUNTY_POC` path so a target-agnostic forged PoC cannot mint a false
  `VERIFIED` (agentis-core#852). The `assess()` two-sided gate is byte-for-byte unchanged; the
  fix lives entirely in the `BOUNTY_POC` branch of `synth_via_prompt()`. A human-supplied PoC
  must now (1) structurally reference the in-scope target/harness for the active mode
  (`poc_exercises_target`) and (2) pass a per-run target-linkage challenge: a fresh nonce const
  is appended to the target the PoC compiles against, the PoC is wrapped to echo it before its
  own `main` runs, and the run output must surface the nonce — a PoC that never links this run's
  target cannot. The documented "simply prints both markers without exercising the target"
  forgery is now rejected (new negative-test fixture `fixtures/forged_marker_printer.rs`). The
  autonomous LLM/template path is untouched, and `calibrate-sealevel.sh` (3/3 true-positive,
  0 false-VERIFIED) still passes because the committed `sealevel/*/poc.rs` link the target and
  surface the nonce. Residual (documented): a sophisticated operator-supplied PoC that links the
  target but never invokes the vulnerable path cannot be distinguished from captured stdout — an
  operator-trust assumption on the explicit override, not an autonomous gap.

### Added

- Operator runbook (V8): `docs/RUNBOOK.md` — a one-page guide an operator follows to run a
  real audit from scratch: prerequisites + one-time offline-toolchain warm, pointing at a
  scope (target, native/anchor harness, optional frozen snapshot, backend), the exact
  `run-audit.sh` command, reading the verdict (VERIFIED / INCONCLUSIVE / SAFE), where the
  report + PoC land, the manual human-gated submission step, the calibration scorecard, and
  known limitations (vuln classes, chains/shapes, the snapshot owner-rebind, the
  operator-supplied-PoC trust boundary).

- Operator entrypoint + human-gated submission package (V7): `run-audit.sh` runs the auditor
  end-to-end against an operator-chosen scope (`--target` program, optional `--harness` /
  `--anchor-harness`, optional `--snapshot`, `--backend`, `--sandbox`) and, on a VERIFIED
  finding, assembles a submission package on disk (`submission/`: the Immunefi-format
  `report.md` embedding the PoC, the PoC source, the target, the snapshot, + a `MANIFEST.txt`
  marked `PENDING HUMAN REVIEW — NOT SUBMITTED`). It NEVER contacts a bounty platform, NEVER
  auto-submits, and NEVER auto-picks a scope — the operator supplies the target, and
  submission is a separate, explicit human action. The colony has zero platform-egress
  builtins (only host-side `prompt()` + sandboxed `exec`). Validated: a VERIFIED run stages a
  complete human-gated package; a non-VERIFIED run stages nothing.

- Real on-chain state snapshot (V4): `snapshot-rpc.sh` fetches accounts from a Solana RPC
  (`getAccountInfo`, base64) host-side and freezes them to a **content-addressed** snapshot
  (real `owner` / `lamports` / `data` — not a hand-written stub). The native vault harness
  gains a `poc_snapshot` bin that seeds the vault account from a frozen snapshot's real
  `lamports` + data bytes and replays the MissingSignerCheck invariant through the real SVM
  **fully offline** (zero network in-sandbox). The colony wires it in: `snapshot_state()`
  recognises the real account format, and when the native harness is active with
  `BOUNTY_SNAPSHOT` set the report's snapshot section is produced by a real offline SVM
  replay (`run_snapshot_replay` / `harness_snap_section`) instead of a std-only stub.
  Validated against a real mainnet account (the USDC mint): the frozen snapshot's real data
  drives a `CONTROL OK` + `INVARIANT VIOLATED` two-sided replay offline. A zero-value /
  foreign snapshot stays inconclusive (no false-VERIFIED).

- Calibration on real `coral-xyz/sealevel-attacks` lessons (V6): an offline,
  Anchor-capable PoC harness (`solana-harness-anchor/` — `anchor-lang` 0.31 +
  `solana-program-test` 2.x + `spl-token`, committed `Cargo.lock`, stable rustc, no SBF
  platform-tools) compiles a real Anchor program and drives it through the real
  `solana-runtime` SVM. The corpus (`sealevel/`) holds three lessons modernized verbatim
  to anchor 0.31 — signer-authorization (`MissingSignerCheck`), account-data-matching
  (`AccountDataMatching`), owner-checks (`MissingOwnerCheck`) — each with insecure + secure
  variants and a verified two-sided exploit PoC. The colony routes to the Anchor harness
  via `SOLANA_ANCHOR_HARNESS_DIR` (a `harness_dir()` helper + anchor branches in
  `poc_instruction` / `compile_run`); detection and the two-sided `assess()` gate are
  unchanged. `calibrate-sealevel.sh` runs the full detect → validate pipeline over the
  corpus and writes `sealevel-scorecard.md`. Demonstrated: the auditor runs end-to-end on a
  real lesson **fully offline inside the hardened sandbox** (host-side only the LLM call;
  the LLM-generated PoC compiles + runs offline through real `solana-program-test`, with a
  human-gated report), with ≥3 true-positive VERIFIED on the insecure lessons and **zero
  false-VERIFIED** on the secure variants — holding even when detection over-flags a secure
  variant, because the two-sided gate (the secure program rejects the exploit) is the source
  of truth, not the detector.

- Program-specific invariant library (V5): each detected vulnerability class now
  drives synthesis through a class-specific invariant (`invariant_for(class)`)
  instead of a single hardcoded signer-drain story. The PoC-generation prompt
  (`poc_instruction(class)`) embeds the right control/exploit invariant per class —
  ownership substitution for `MissingOwnerCheck`, identity mismatch for
  `AccountDataMatching`, program-id redirection for `ArbitraryCPI`, arithmetic wrap
  for `IntegerOverflow`, non-signer authority for `MissingSignerCheck` — and the
  standardized report's severity / summary / impact / remediation are class-aware
  (`severity_for` / `summary_for` / `impact_for` / `remediation_for`). Detection now
  routes every recognised class to synthesis (previously only `MissingSignerCheck`
  was synthesized and `IntegerOverflow` stopped at a "DETECTED" stub). The built-in
  deterministic template is signer-shaped, so a non-`MissingSignerCheck` class with
  no usable LLM-generated PoC resolves to `inconclusive` — never a false-VERIFIED.
  The two-sided gate (`CONTROL OK:` + `INVARIANT VIOLATED:`) is unchanged and still
  blocks rigged/always-fire harnesses for every class.

### Changed

- Detection verdict for `IntegerOverflow` in offline / `mock` mode is now
  `inconclusive` (routed through synthesis with the overflow invariant) rather than
  the previous non-committal `DETECTED`, since no deterministic overflow template
  exists; a real LLM backend generates the two-sided overflow PoC.

- Generalised detection (V3): an LLM-driven classifier (`classify_llm`) reads the
  program source and returns a vulnerability class (`MissingSignerCheck` /
  `MissingOwnerCheck` / `AccountDataMatching` / `ArbitraryCPI` / `IntegerOverflow`
  / `Safe`), generalising past the structural heuristic to real Anchor shapes it
  cannot see (e.g. an `authority: AccountInfo` field that should be a `Signer`).
  It is primary when a real LLM backend is configured; the structural heuristic
  remains the offline / `mock`-deterministic fallback (the mock backend yields no
  class token, so detection falls through unchanged). A mis-classification only
  routes to synthesis — the two-sided real-SVM gate stays the source of truth, so
  it can never cause a false-VERIFIED.

## [0.1.0] — 2026-06-09

**Requires:** agentis >= `1.18.0`

### Added

- Initial dark-factory federation: an autonomous Solana/Anchor bounty
  auditor. A single `auditor` colony runs an `agentis go`-driven audit
  pipeline (reconn → guard → tracker → synthesis) entirely on the agentis
  substrate, fully offline.
- Real LLM-driven two-sided PoC synthesis: the prompt-driven synthesis path
  generates a proof-of-concept that must exercise BOTH a control (an
  authorized caller is accepted → `CONTROL OK:`) and an exploit (an
  unauthorized caller breaks the safety invariant → `INVARIANT VIOLATED:`),
  so a rigged always-fire harness cannot pass the validation gate.
- Offline `solana-program-test` toolchain: a committed harness crate
  (`solana-harness/`) drives the ingested program through the real
  `solana-runtime` SVM (real account model, signer/owner checks, lamport
  conservation) compiled with stable rustc — no SBF platform-tools, no
  network at audit time. The one-time dependency-graph warm build is staged
  by `setup-solana-toolchain.sh`.
- Human-gated submission: a verified finding is written as a standardized
  Immunefi-shaped report and, at `review-gated` / `autonomous` tier, staged
  with a `pending_human_review` marker. The colony NEVER auto-posts to a
  bounty platform — submission is always an explicit human action.

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.2.0...HEAD
[0.2.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/dark-factory-v0.2.0
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/dark-factory-v0.1.0
