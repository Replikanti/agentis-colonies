# Dark-factory audit method registry

The methods the federation can apply. The method-discovery meta-loop
(`run-method-discovery.sh`) appends `invented` methods here only after they pass the
known-bug control gate. Machine-readable lines:

`METHOD|<name>|<bug-classes>|<technique>|<how-to-invoke>|<status>|<fitness>`

METHOD|breadth-screen|C1-C14|per (subsystem x bug-class) reason-first adversarial LLM pass over sliced in-scope contracts|run-discovery.sh|builtin|0.50
METHOD|function-slicing|*|extract `file@fn` slices (contract header + named fns) so big contracts fit the LLM budget|slice-fns.sh|builtin|0.60
METHOD|brief-ingestion|*|fold the target's own audit docs / known-issues into the hunt anchor to exclude documented findings|run-discovery.sh --brief|builtin|0.70
METHOD|deep-cross-function-audit|C5-C12|whole-contract read, enumerate invariants, trace the call-graph, build sequenced multi-actor attack hypotheses|deep-audit subagent|builtin|0.55
METHOD|poc-build-run|*|build a forge harness over mocks, write + run a test to reproduce/refute a hypothesis|forge-verify.sh|builtin|0.65
METHOD|adversarial-refute|*|independently try to REFUTE each candidate vs real control-flow (default to refuted on doubt); now substrate-native (auditor/agents/refuter.ag), #999|run-refute.sh|builtin|0.75
METHOD|fork-differential|*|clone the upstream parent, diff, audit ONLY the delta (the lines the upstream auditors never saw)|fork-diff subagent|builtin|0.80
METHOD|onchain-verify|C5,C14|Sourcify verified source + public-RPC eth_call + keccak selector/role checks on the live deployment|recall.sh / cast|builtin|0.50
