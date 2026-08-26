# PLAN: Context Engine

Implementation plan for `CONTRACT_context_engine.md`. No Swift code was written in
the planning session that produced this file.

## Context

`CONTRACT_models.md` is done: `Threads/Models/SwiftDataModels.swift` has the four
`@Model` classes, `ThreadsTests/ModelContainerHelper.swift` has the in-memory
container factory, and `ThreadsTests/SwiftDataModelTests.swift` has 7 passing tests.
That satisfies this contract's precondition.

`ContextEngine.swift` is the project's differentiator: it's the entire dependency
surface of the retrieval eval (`.claude/rules/evals.md` — written in a *later*
session that has never seen this implementation, scored on precision@5/recall@5
across three strategies). Every design choice here either makes that later eval
session's job mechanical, or makes it fight the code. The two things that matter
most: the strategy parameter has to be genuinely load-bearing (not a switch that
silently does the same thing three ways), and every retrieval-relevant number has
to come back as data, not get consumed internally and thrown away.

Outcome: `Threads/Core/ContextEngine.swift` with `EmbeddingService` (actor wrapping
`NLContextualEmbedding`, vDSP cosine similarity, `Data` codec) and
`ContextRetrievalEngine` (a stateless struct: strategy-parameterized scoring,
decay, superseded down-weighting, token-budgeted payload assembly), plus
`ThreadsTests/ContextEngineTests.swift` proving every contract test bullet.

### Decision settled with the user during planning

| Question | Answer |
| --- | --- |
| DECISIONS.md locks "actor isolation for services" — is `ContextRetrievalEngine` an actor? | **No, a plain struct.** It's stateless computation over inputs the caller already holds — no shared mutable resource to protect. Making it an actor would force every call async and require sending non-`Sendable` `@Model` objects (`ContextNode`, `Message`) across an isolation boundary, which Swift 6 strict concurrency rejects. `EmbeddingService` stays an actor — it wraps the one actual stateful resource (`NLContextualEmbedding`, loaded once, expensive) — but the engine only ever exchanges `Sendable` value types with it (`[Double]` vectors, `Data`), never a `@Model` instance. |

---

## File: `Threads/Core/ContextEngine.swift` (new — `Core/` doesn't exist yet)

### `EmbeddingService` — actor

```swift
actor EmbeddingService {
    enum EmbeddingError: Error { case modelUnavailable }

    private let model: NLContextualEmbedding

    init(language: NLLanguage = .english) throws {
        guard let model = NLContextualEmbedding(language: language) else {
            throw EmbeddingError.modelUnavailable
        }
        self.model = model
        try model.load()
    }

    func embed(_ text: String) throws -> [Double]   // mean-pooled, L2-normalized, 512-dim

    nonisolated static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double  // vDSP
    nonisolated static func encode(_ vector: [Double]) -> Data
    nonisolated static func decode(_ data: Data) -> [Double]
}
```

- **Initializer**: `init(language:)`, per contract and `.claude/rules/ios26-apis.md`
  (`init(script:)`/`init(language:)`, never the static factory
  `contextualEmbeddings(for:)`). `NLContextualEmbedding` is stateful (holds a loaded
  model) and expensive to load — that's what makes it an actor: concurrent embed
  calls serialize instead of racing.
- **`embed(_:)`**: calls `model.embeddingResult(for:language:)`, then must
  mean-pool the per-token vectors and L2-normalize. **Risk flagged below** — the
  exact Swift overlay signature for enumerating token vectors is not nailed down
  in `ios26-apis.md`.
- **`cosineSimilarity`/`encode`/`decode`** are `nonisolated static` — pure math, no
  actor state touched, so they're callable synchronously without `await` and
  without ever constructing the actor. This is what makes the cosine-identity test
  and the `Data` round-trip test synchronous (only the dimension/normalization test,
  which needs a real loaded model, has to be `async`).
- **`encode`/`decode`** use the same raw-bytes-via-`withUnsafeBufferPointer` /
  `copyBytes`-into-a-fresh-buffer pattern already established in
  `SwiftDataModelTests.encode`/`.decode` — bit-exact, alignment-safe, and
  byte-compatible with `ContextNode.embeddingData` (512 doubles = 4096 bytes) by
  construction, since both sides use the identical layout.

### Retrieval strategy & config

```swift
enum RetrievalStrategy: Sendable, Equatable {
    case semanticOnly, recencyOnly, decayWeightedSemantic
}

struct RetrievalConfig: Sendable, Equatable {
    var strategy: RetrievalStrategy
    var topK: Int = 5
    var halfLifeDays: Double = 14.0       // DECISIONS.md default
    var supersededPenalty: Double = 0.5   // multiplicative, separable from decay
    var tokenBudget: Int = 4096           // anchored to SystemLanguageModel.contextSize
}
```

Every contract-mandated parameter (strategy, top-K, half-life) lives on this one
config struct, constructed fresh per call — nothing is a file-level constant. The
eval runner builds three `RetrievalConfig`s differing only in `.strategy` and calls
the same engine against the same node array three times.

### Value types returned to callers (payload is data, not a side effect)

```swift
struct ScoredContextNode: Sendable, Equatable {
    let nodeID: UUID
    let content: String
    let nodeType: String
    let score: Double
    let isSuperseded: Bool
    let createdAt: Date
}

struct MessageSnapshot: Sendable, Equatable {
    let messageID: UUID
    let role: String
    let content: String
    let estimatedTokens: Int
    let createdAt: Date
}

struct ContextPayload: Sendable, Equatable {
    let workstreamSummary: String
    let relevantNodes: [ScoredContextNode]
    let recentMessages: [MessageSnapshot]
    let estimatedTokenCount: Int
}
```

All three are plain `Sendable` value types — no `@Model` reference anywhere in a
returned type. This is what satisfies "the assembled payload is retrievable as a
value" and lets the Day 5-6 debug inspector and the eval hold onto a
`ContextPayload`/`[ScoredContextNode]` without any actor-crossing or SwiftData
context-liveness concerns.

### `ContextRetrievalEngine` — plain struct, no actor

```swift
struct ContextRetrievalEngine {
    // Full scored + sorted list, every node, no slicing. This is what the eval
    // inspects for precision@5/recall@5 and what the three-strategy test compares.
    func rankedNodes(
        for queryEmbedding: [Double],
        in nodes: [ContextNode],
        config: RetrievalConfig,
        now: Date = .now
    ) -> [ScoredContextNode]

    // Walks ranked nodes (top-K slice) then recentMessages (newest-first),
    // stopping the instant the next item would exceed tokenBudget. Never
    // truncates an item's content to make it fit.
    func assemblePayload(
        workstreamSummary: String,
        rankedNodes: [ScoredContextNode],
        recentMessages: [Message],
        config: RetrievalConfig
    ) -> ContextPayload

    // Convenience: rank then assemble.
    func retrieve(
        queryEmbedding: [Double],
        nodes: [ContextNode],
        recentMessages: [Message],
        workstreamSummary: String,
        config: RetrievalConfig,
        now: Date = .now
    ) -> ContextPayload
}
```

Everything here is synchronous, non-`async`, non-isolated. Callers hold
`[ContextNode]`/`[Message]` fetched from their own `ModelContext` (on whatever
actor that context lives on) and pass them straight in — no isolation boundary is
crossed, so the non-`Sendable`-ness of `@Model` classes never becomes a problem.
Only `Sendable` value types (`[Double]`, `ContextPayload`, `[ScoredContextNode]`)
ever leave the engine.

**Scoring** (private, inside the engine):

```
base score by strategy:
  .semanticOnly            → cosineSimilarity(query, decode(node.embeddingData))
  .recencyOnly              → 1 / (1 + ageInDays)                         // ignores embedding entirely
  .decayWeightedSemantic    → cosineSimilarity(...) × pow(0.5, ageInDays / halfLifeDays)

final score = base score × (node.supersededByID != nil ? config.supersededPenalty : 1.0)
```

The superseded multiplier is a separate private function
(`supersededMultiplier(isSuperseded:penalty:)`) that never sees `halfLifeDays` or
age, and the decay function (`decayFactor(createdAt:now:halfLifeDays:)`) never sees
`supersededByID` — that separation is what "the down-weighting is separable from
the decay calculation" is checking for. The multiplier is applied after the
strategy switch, uniformly across all three strategies, since supersession is a
schema-level correctness signal, not something specific to one retrieval strategy.

A node with no `embeddingData` (not yet embedded) scores `0` for the
similarity-dependent strategies rather than throwing — retrieval must degrade
gracefully for nodes mid-pipeline, and nothing in the contract asks for an error
path here.

`now: Date` is an injectable parameter (default `.now`) specifically so decay
tests are deterministic — fixtures set `createdAt` relative to a fixed `now`
rather than racing the wall clock.

**Token budgeting**: `estimateTokens(_ text: String) -> Int { max(1, text.count / 4) }`
for the workstream summary and node content (matches the "~4 chars per token"
heuristic SPEC.md already uses for `Message.estimatedTokens`). Messages use their
own stored `estimatedTokens` directly rather than re-deriving it. The workstream
summary is always included first and its cost is never checked against the budget
— it's the floor of the payload, not a candidate that can be dropped. Nodes (from
the top-K slice of `rankedNodes`) are added score-descending while they fit;
messages are added newest-first while they fit. The first item that would exceed
the budget stops the walk for that list entirely — it is not skipped in favor of
a smaller later item, and nothing is truncated mid-item.

---

## File: `ThreadsTests/ContextEngineTests.swift` (new)

`@Suite(.serialized) struct ContextEngineTests`, reusing
`makeInMemoryContainer()` from `ThreadsTests/ModelContainerHelper.swift`. Six tests
map 1:1 to the contract's `Tests` bullets; a seventh is added beyond what the
contract strictly lists, flagged separately below.

1. **`cosineSimilarityOnHandComputableVectors`** — synchronous, no actor, no
   container. `EmbeddingService.cosineSimilarity([1,0,0],[1,0,0]) == 1`,
   `([1,0],[0,1]) == 0`, `([1,0],[-1,0]) == -1`.

2. **`embeddedStringProduces512NormalizedDimensions`** — `async throws`. Constructs
   a real `EmbeddingService`, `await`s `embed("some representative sentence")`,
   asserts `count == 512` and `sqrt(sum of squares) ≈ 1` within a small tolerance
   (e.g. `1e-6`) — magnitude, not `#expect(... == 1)`, since normalization is
   floating-point.

3. **`embeddingDataRoundTripsBitExact`** — synchronous. Same shape as the models
   session's embedding round-trip test: build a 512-`Double` array with edge
   values, `encode`, `decode`, assert `bitPattern` equality element-wise. This is
   the same guarantee `SwiftDataModelTests` already proves for the *storage* side;
   this test proves `EmbeddingService`'s codec produces byte-identical output to
   that same layout, so the two are provably interchangeable.

4. **`threeStrategiesProduceDifferentOrderings`** — synchronous, uses a real
   `ModelContainer`. Fixture: workstream + 3 `ContextNode`s inserted via a context
   — node A (high cosine similarity to a fixed query vector, old `createdAt`),
   node B (lower similarity, very recent `createdAt`), node C (middle similarity,
   middle age). Fetch back, run `rankedNodes` three times with configs differing
   only in `.strategy`, assert at least two of the three resulting `nodeID` orderings
   differ from each other (semantic-only leads with A, recency-only leads with B).
   This is the test that proves the strategy parameter is load-bearing rather than
   a switch that produces the same order three times.

5. **`decayActuallyDecays`** — synchronous. Two nodes with the **identical**
   embedding, one `createdAt` = `now`, one `createdAt` = `now - 30 days`. Fixed
   `now` passed into `rankedNodes`. Assert:
   - under `.semanticOnly`: the two scores are **equal** (age plays no role at
     all — a stronger, unambiguous claim than "ordering doesn't reflect age",
     which would be vulnerable to sort-stability accidents on a tie)
   - under `.decayWeightedSemantic`: the newer node's score is strictly greater
     than the older node's score.

6. **`supersededNodeRanksBelowEquivalentNonSuperseded`** — synchronous. Two nodes,
   identical embedding and `createdAt`, only difference is `supersededByID` set
   vs. `nil`. Scored under `.semanticOnly` specifically (isolates the assertion to
   the superseded multiplier alone, with decay's exponential term out of the
   picture as a confound). Assert the non-superseded node's score is strictly
   greater.

7. **(Beyond the contract's explicit `Tests` list, added for spec fidelity on the
   token-budgeting "Done means" bullet)** — **`payloadStopsAtTokenBudgetWithoutTruncating`**.
   Fixture with a workstream summary and several nodes/messages sized so the
   budget is exhausted partway through the ranked list. Assert: every included
   node/message is present with its **full, untruncated** content; the first item
   that would have exceeded the budget is **absent entirely** (not partially
   included); `estimatedTokenCount` matches the sum of what was actually included.
   This is called out explicitly as an addition, not a contract requirement, per
   `DECISIONS.md`'s standing clause — happy to drop it if it's considered scope
   creep relative to the contract's literal `Tests` bullets.

Suite-level: `.serialized`, and every test that touches SwiftData builds its own
container via `makeInMemoryContainer()` — same belt-and-braces approach as
`SwiftDataModelTests`. Tests 1–3 and 5–6 don't strictly need a container (they can
construct `ContextNode` instances unmanaged and only read plain properties), but
4 and 7 do need real fetched instances to be representative, so for consistency
every node fixture across the file goes through insert → save → fetch on a fresh
in-memory container, matching the models session's established pattern rather
than mixing managed and unmanaged instances across tests in the same file.

---

## Known risks to resolve during implementation (not resolved by this plan)

- **Token-vector enumeration signature is explicitly unverified.**
  `.claude/rules/ios26-apis.md` flags `NLContextualEmbeddingResult`'s
  `enumerateTokenVectorsInRange:usingBlock:` / `tokenVectorAtIndex:tokenRange:` as
  `NS_REFINED_FOR_SWIFT` with "the exact overlay signature isn't visible from the
  header alone; verify against current Apple documentation before relying on
  parameter order/types." This is the one piece of `embed(_:)` that cannot be
  written from this plan or from memory. The implementation session must use
  `mcp__xcode__DocumentationSearch` (or equivalent) to pin down the real Swift
  signature before writing the mean-pooling loop, per CLAUDE.md's fallback
  trigger, and — if the real signature meaningfully differs from what's assumed
  here — add it to `ios26-apis.md` rather than silently improvising.
- **Model asset availability in the test environment.** `embed(_:)` requires
  `NLContextualEmbedding` assets to be resolvable on the simulator running the
  tests. If `load()` throws in that environment, that's an infra/environment
  problem to surface, not a reason to mock away the real framework — the contract
  requires wrapping the real `NLContextualEmbedding`.

---

## Verification

Run via the `xcode` MCP tools, per CLAUDE.md.

1. Confirm the precondition first: `RunAllTests` on `ThreadsTests` should already
   be green (7 model tests + the template's `example()`) before any new code is
   written.
2. `BuildProject` — scheme `Threads`, iPhone 17 Pro simulator. Zero errors; check
   warnings for Swift 6 concurrency complaints (an accidental `Sendable` crossing
   would surface here first).
3. `RunSomeTests` on `ContextEngineTests` while iterating.
4. `RunAllTests` on `ThreadsTests` for the final pass. Report the exact test count.

Self-check against the contract before declaring done:
- [ ] `NLContextualEmbedding` initialized via `init(language:)` or `init(script:)`
      only — no static factory method anywhere
- [ ] No `NLContextualEmbedding`-related signature written that isn't backed by
      `.claude/rules/ios26-apis.md` or a doc-verified addition to it
- [ ] `RetrievalStrategy` is a case actually switched on inside the scoring
      function — not an unused parameter
- [ ] `halfLifeDays` and `topK` are read from `RetrievalConfig`, not hardcoded
      anywhere in the scoring or assembly code
- [ ] Superseded down-weighting and decay are two separate private functions,
      neither one referencing the other's inputs
- [ ] `ContextPayload`/`ScoredContextNode` are `Sendable` value types with no
      `@Model` reference
- [ ] No file created outside `Core/ContextEngine.swift` and `ThreadsTests/`
      (no `OnDeviceIntelligence.swift`, `LLMProvider.swift`,
      `ThreadOrchestrator.swift`, any view, any eval file)
- [ ] No test edited to make it pass

Then hand off to a **fresh session** for review against `.claude/rules/verify.md`,
neutral prompt, spec fidelity must score 4+. Tell the verifier to additionally
confirm: no unverified `NLContextualEmbedding` signature, the strategy parameter
is genuinely load-bearing, and decay half-life / top-K are parameters rather than
constants — exactly as the contract's `Verification` section asks.
