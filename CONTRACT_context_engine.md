# CONTRACT: Context Engine

`ContextEngine.swift` holds `EmbeddingService` and `ContextRetrievalEngine`. This file plus a bundled node set is the entire dependency surface of the retrieval eval, which is the project's differentiator. Build it so the eval can run against it without modification.

## Preconditions
- [ ] `SwiftDataModels.swift` green, ThreadTests passing

## Done means

### EmbeddingService

- [ ] Wraps `NLContextualEmbedding` using `init(script:)` or `init(language:)`. Do not use a static factory. Verify the initializer against `.claude/rules/ios26-apis.md` before writing it.
- [ ] Produces a 512-dimension vector for a given `String`, mean-pooled across token vectors, L2 normalized.
- [ ] Exposes cosine similarity computed via Accelerate/vDSP.
- [ ] Encodes and decodes vectors to and from `Data` compatibly with `ContextNode.embeddingData` (512 doubles as raw bytes).

### ContextRetrievalEngine

- [ ] **Retrieval strategy is a parameter from the first line of code, not retrofitted.** The engine accepts a strategy configuration and the eval runner must be able to call it three ways against an identical node set without touching this file.
- [ ] Three strategies are expressible through that parameter: semantic-only (cosine, no decay), recency-only (most recent, no semantic ranking), decay-weighted semantic (cosine × relevance decay).
- [ ] Relevance decay half-life is a parameter with a 14-day default, not a constant baked into the scoring function.
- [ ] Top-K is a parameter, not hardcoded.
- [ ] Superseded nodes (`supersededByID` non-nil) are down-weighted in scoring, and the down-weighting is separable from the decay calculation.
- [ ] Token budgeting assembles a payload of workstream summary + top-K relevant nodes + recent messages, and stops at the budget rather than truncating arbitrarily.
- [ ] The assembled payload is retrievable as a value, not only sent onward. The debug inspector on Day 5-6 needs to display it, and the eval needs to inspect ranking.
- [ ] Retrieval returns nodes **with their scores**, not just an ordered list. Precision@5 scoring and the debug inspector both need the numbers.

### Tests

- [ ] Cosine similarity is tested on hand-computable vectors: identical vectors return 1, orthogonal vectors return 0, opposite vectors return -1. If this test does not exist, every retrieval number downstream is unverified.
- [ ] A test asserts an embedded string produces exactly 512 dimensions and is L2 normalized (magnitude ≈ 1).
- [ ] A test round-trips a vector through `Data` encoding and back, bit-exact.
- [ ] A test calls retrieval with all three strategy configurations against the same fixture nodes and asserts the orderings differ. This proves the parameterization is real rather than nominal.
- [ ] A test asserts decay actually decays: two nodes with identical embeddings but different `createdAt` rank in age order under decay-weighted, and do not under semantic-only.
- [ ] A test asserts a superseded node ranks below an equivalent non-superseded node.
- [ ] Each test uses its own in-memory `ModelContainer`, or the suite is `.serialized`, reusing the helper from the models session.

### Build
- [ ] Builds clean for iPhone 17 Pro simulator, iOS 26.4 deployment target, Swift 6
- [ ] ThreadTests passes, N tests, none edited to pass

## Files in scope
`Core/ContextEngine.swift`, `ThreadTests/` (new tests only)

**If a precondition of this work requires editing a file not listed here, stop and raise it before making the edit.**

## Out of scope
`OnDeviceIntelligence.swift`, `LLMProvider.swift`, `ThreadOrchestrator.swift`, any view, any eval runner or eval fixture, extraction logic, the Claude API. Do not create these files.

The eval runner is explicitly out of scope and must be written in a later session that has not seen this implementation, per `.claude/rules/evals.md`.

## Verification
Fresh session, `.claude/rules/verify.md` rubric. Spec fidelity must score 4+.

Verifier should additionally confirm: no `NLContextualEmbedding` signature was written that does not appear in `.claude/rules/ios26-apis.md`, the strategy parameter is genuinely load-bearing rather than an unused argument, and the decay half-life and top-K are parameters rather than constants.
