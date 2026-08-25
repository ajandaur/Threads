# CONTRACT: Retrieval Eval

This contract must be sufficient on its own. The session implementing this must never have seen the retrieval strategy implementation. If you are that session: do not read `ContextEngine.swift`'s retrieval internals beyond the public interface needed to call it three ways.

## Inputs (already provided by the human, do not generate or modify)
- A bundled labeled node set: ~40 context nodes for one synthetic workstream (facts, decisions, open questions, action items, some deliberately stale or superseded)
- 25-30 labeled queries, each with `relevant_node_ids` and `irrelevant_but_tempting` node ID sets, per `.claude/rules/evals.md`

## Done means
- [ ] Eval runner exists (prefer a Swift Testing `@Test(arguments:)` case over a debug-menu action — must be CI-runnable and deterministic)
- [ ] Runner executes all 30 queries against three retrieval configs on the identical node set:
  - semantic-only (cosine similarity, no decay)
  - recency-only (most recent nodes, no semantic ranking — the baseline)
  - decay-weighted semantic (cosine × relevance decay — the actual strategy)
- [ ] Runner computes precision@5 and recall@5 per query per strategy
- [ ] Output is a three-strategy comparison table (aggregate precision@5 and recall@5 per strategy)
- [ ] Every test run uses its own in-memory `ModelContainer` (Swift Testing parallelizes by default; SwiftData containers are not shared-safe) or the suite is marked `.serialized`
- [ ] Re-running the eval after any change to decay half-life, top-K, or scoring produces a fresh table, not a patched one
- [ ] Project builds clean for iPhone 17 Pro simulator
- [ ] Result is reproducible: running twice on unchanged code produces the same numbers

## Files in scope
`Eval/RetrievalSet.swift` (or bundled JSON), `Eval/RetrievalEval.swift`, test target only.

## Out of scope
Modifying the labeled queries or node set. Modifying `ContextEngine`'s retrieval logic. Extraction spot-check (separate, optional, out of this contract).

## Verification
Fresh session, `.claude/rules/verify.md` rubric. Spec fidelity must score 4+. Verifier should confirm the runner was NOT written in the same session as retrieval-strategy work, per `.claude/rules/evals.md`.
