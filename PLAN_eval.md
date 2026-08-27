# PLAN: Retrieval Eval Runner

## Context

`CONTRACT_eval.md` requires a CI-runnable, deterministic eval that scores three
retrieval strategies over one human-labeled corpus and emits a three-strategy
comparison table. The eval is the project's differentiator, so
`.claude/rules/evals.md` requires that the runner be built by a session that has
never seen the retrieval scoring implementation — otherwise the runner is written
to make the strategy win, and the headline number is worthless.

This session satisfies that constraint. Read: `CLAUDE.md`, `CONTRACT_eval.md`,
`.claude/rules/evals.md`, `.claude/rules/swiftdata.md`, `.claude/rules/ios26-apis.md`,
`.claude/rules/DECISIONS.md`, `.claude/rules/verify.md`,
`Threads/Models/SwiftDataModels.swift`, `ThreadsTests/ContextEngineTests.swift`,
`ThreadsTests/ModelContainerHelper.swift`, `ThreadsTests/RetrievalSet.json`.

From `Threads/Core/ContextEngine.swift` only the public surface was read:
`EmbeddingService` (lines 12–25, plus the `embed`/`cosineSimilarity`/`encode`/`decode`
signature lines), `RetrievalStrategy`, `RetrievalConfig`, `ScoredContextNode`,
`ContextPayload` (lines 90–152), and the `rankedNodes` / `assemblePayload` /
`retrieve` parameter lists. The bodies of `baseScore`, `similarity`, `decayFactor`,
`supersededMultiplier`, and `estimateTokens` were **not** read.

`RetrievalSet.json` was read but **not modified**, and must not be.

---

## Findings from the fixture (read before planning; report honestly)

These correct or refine assumptions in the task framing. None of them is a reason
to change the fixture.

1. **The corpus is 36 nodes, not 32.** 13 decisions, 11 facts, 7 action items,
   5 open questions. Dates run `2026-06-02T10:00:00Z` → `2026-07-31T15:00:00Z`.
   Six supersession pairs: `n01→n05`, `n10→n09`, `n11→n15`, `n16→n23`,
   `n20→n24`, `n25→n29`. No dangling references, no duplicate query text, no
   overlap between a query's `relevant_node_ids` and its `irrelevant_but_tempting`.

2. **Queries have no `id` field.** Keys are exactly `query`,
   `relevant_node_ids`, `irrelevant_but_tempting`. "Enumerated query IDs" must
   therefore mean **zero-based array index** into `queries`. See the drift
   tripwire in Step 3 — indices are positional and would silently re-point if the
   fixture were ever reordered.

3. **The current-state / historical split is 12 / 5 / 13, not ~20 / 5.** Your
   historical count is exactly right; the current-state count is 12, and 13
   queries touch no supersession chain at all. Classifying by "relevant node is a
   successor and a tempting node is its superseded predecessor" (current-state)
   vs. "relevant node is itself superseded" (historical):

   - **Current-state (12):** indices `0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12`
   - **Historical (5):** indices `25, 26, 27, 28, 29`
   - **Neither (13):** indices `1, 13–24` — no supersession relationship; they
     still count toward the all-30 aggregate.

4. **Every query has exactly one relevant node.** So per-query
   precision@5 ∈ {0, 0.2}, recall@5 ∈ {0, 1}, and **precision@5 ≡ recall@5 ÷ 5
   exactly**, at every level of aggregation. The two contract columns are not
   independent. This is a property of the human-authored set, not something to
   fix — it is why the `irrelevant_but_tempting` diagnostic column earns its place
   as the only column carrying independent signal.

5. **Statistical power on the tier-2 subsets is thin.** The historical assertion
   rests on 5 queries; a single query flipping moves that subset mean by 0.04
   precision. Report this alongside the table rather than treating a pass as
   strong evidence. If a tier-2 inequality fails on first run, that is a real
   finding about the corpus or the implementation — do not loosen the assertion.

---

## Step 1 — Amend `CONTRACT_eval.md` first

Per your instruction: fix the contract before implementing, so the agent isn't
resolving scope on its own and the verifier isn't grading against a stale path.
This is the first edit of the implementation session, committed separately.

**Replace the "Files in scope" section** with:

```
## Files in scope
`ThreadsTests/RetrievalSet.json` (human-authored fixture, already committed —
do not modify), `ThreadsTests/RetrievalEval.swift`. Test target only.
```

**Append to "Done means"** (keeping the existing boxes):

```
- [ ] Precision@5/recall@5 arithmetic is correct on a synthetic fixture with a
      hand-computable expected value
- [ ] All 30 queries execute against all 3 strategies without error
- [ ] Decay-weighted precision@5 >= semantic-only precision@5 on current-state
      queries (query indices enumerated in the test file, not re-derived)
- [ ] Semantic-only precision@5 >= decay-weighted precision@5 on historical
      queries (query indices enumerated in the test file)
- [ ] Decay-weighted aggregate precision@5 > recency-only aggregate precision@5,
      across all 30
- [ ] Full three-strategy table is printed/attached as output, not asserted
      against a fixed value
```

Also correct line 3's isolation clause to name the new path, and note in
"Inputs" that the fixture is 36 nodes / 30 queries.

---

## Step 2 — `ThreadsTests/RetrievalEval.swift`

Single new file. `ThreadsTests` is a `PBXFileSystemSynchronizedRootGroup`
(`project.pbxproj:38-41`), so the file is picked up with no project edit, and
`RetrievalSet.json` is already routed to the test target's Resources phase the
same way.

### Fixture decoding

```swift
private struct FixtureNode: Decodable {
    let id: String, content: String, nodeType: String, createdAt: String
    let supersededBy: String?
}
private struct FixtureQuery: Decodable {
    let query: String
    let relevant_node_ids: [String]
    let irrelevant_but_tempting: [String]
}
private struct Fixture: Decodable { let nodes: [FixtureNode]; let queries: [FixtureQuery] }
```

Load with `Bundle(for: EvalBundleMarker.self).url(forResource: "RetrievalSet", withExtension: "json")`,
where `EvalBundleMarker` is a `private final class` declared in this file —
there is no SPM `Bundle.module` here. Throw on a missing resource rather than
returning empty; a silently empty corpus would make every metric 0 and every
inequality vacuously pass.

`nodeType` maps via `ContextNodeType(rawValue:)`. **Throw on an unrecognized raw
value** — do not use the model's `?? .fact` fallback, which would mask a typo.
All four values present in the fixture (`fact`, `decision`, `openQuestion`,
`actionItem`) exist in the enum.

`createdAt` parses with `ISO8601DateFormatter()` (default options handle
`2026-06-02T10:00:00Z`).

### Determinism controls (these are what make the contract's reproducibility box true)

- **Fixed evaluation clock.** `rankedNodes(..., now:)` defaults to `.now`; with a
  14-day half-life, `.now` makes the decay numbers drift every run.
  Hardcode `let evaluationNow = Date(timeIntervalSince1970: 1_785_542_400)`
  (`2026-08-01T00:00:00Z`, one day after the newest node) and pass it explicitly
  on every call.
- **Deterministic node IDs.** `ContextNode.id` is a `UUID`; fixture IDs are
  `"n01"`. Map by fixture array index:
  `UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!`.
  Build a `[String: UUID]` map in one pass, then a second pass to resolve
  `supersededBy` → `supersededByID`, so forward references resolve.
- **`lastAccessedAt` set to `createdAt`**, never left to default to `.now`.
  Removes a wall-clock value from the model graph regardless of whether scoring
  reads it.
- **Fixed input ordering.** SwiftData fetches are unordered and `sorted(by:)` is
  not guaranteed stable, so exact score ties could reorder between runs. After
  `context.fetch(FetchDescriptor<ContextNode>())`, re-sort into fixture order via
  the ID map before passing to `rankedNodes`.

### Harness

```swift
struct EvalRow { let queryIndex: Int; let precisionAt5: Double
                 let recallAt5: Double; let hitTemptingNode: Bool }
struct StrategyResult { let strategy: RetrievalStrategy; let rows: [EvalRow] }
struct EvalReport { let results: [StrategyResult] }

enum RetrievalEvalHarness {
    static func run(strategies: [RetrievalStrategy]) async throws -> EvalReport
}
```

`run` does, in order:

1. Decode the fixture.
2. **Embed everything first, before any SwiftData object exists** — 36 node
   contents + 30 query texts via `EmbeddingService` (`actor`, so `await`).
   Doing embedding first means the non-`Sendable` `ModelContext` and
   `[ContextNode]` are never held across an `await`. The test target does *not*
   set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (only the app target does —
   `project.pbxproj:148,181`), so test code is nonisolated by default and this
   ordering avoids the isolation question entirely.
3. Build a fresh in-memory container via the existing `makeInMemoryContainer()`
   (`ThreadsTests/ModelContainerHelper.swift:10`) — reuse it, do not write a new one.
   Insert all 36 nodes with `embeddingData: EmbeddingService.encode(vector)`, `save()`.
4. Fetch, re-sort into fixture order.
5. For each strategy: `RetrievalConfig(strategy:)` — **defaults only**
   (`topK: 5`, `halfLifeDays: 14`, `supersededPenalty: 0.5`), so the three
   configs differ by strategy alone, as the contract specifies.
6. Per query: `engine.rankedNodes(for: queryVector, in: orderedNodes, config: config, now: evaluationNow)`,
   then `.prefix(5)`.

   **Use `rankedNodes`, not `retrieve`.** `retrieve` routes through
   `assemblePayload`, which applies `config.tokenBudget` and can drop a node that
   ranked in the top 5 — that would confound the metric with a budgeting concern
   the contract does not ask about. `.prefix(5)` is applied by the harness and is
   correct whether or not `rankedNodes` already truncates.

7. Metrics per query (`R` = relevant set, `T` = top-5 IDs, `k` = 5):
   - `precisionAt5 = |R ∩ T| / 5`
   - `recallAt5 = |R ∩ T| / |R|`
   - `hitTemptingNode = !(temptingIDs ∩ T).isEmpty`

   Aggregates are **macro-averages** (unweighted mean across queries), which is
   well-defined here since every query has |R| = 1.

**No caching.** A memoized corpus would make the reproducibility test vacuous —
it would compare a value to itself. Each `run` call recomputes embeddings and
rebuilds the container from scratch. Cost is 66 embed calls per run, six runs
across the suite.

### Output

Build a markdown string and both `print(...)` it and
`Attachment.record(table, named: "retrieval-eval.md")` (`String: Testing.Attachable`,
verified in `Testing.swiftinterface:457`). Two tables:

```
| Strategy | Precision@5 | Recall@5 | Tempting node in top-5 |
| --- | --- | --- | --- |
| semantic-only          | 0.0000 | 0.0000 | 0.0000 |
| recency-only           | 0.0000 | 0.0000 | 0.0000 |
| decay-weighted semantic| 0.0000 | 0.0000 | 0.0000 |

Subset breakdown — precision@5
| Strategy | Current-state (n=12) | Historical (n=5) | Unrelated (n=13) |
```

The second table is not decoration: it is the evidence behind the two tier-2
subset assertions, so a failure is diagnosable from the log without a rerun.
Format all values to 4 decimal places. Nothing is written to disk and no numbers
are checked in — every run produces the table fresh, per the contract's
"fresh table, not a patched one" condition.

---

## Step 3 — Tests

`@Suite(.serialized) struct RetrievalEvalTests` — matching
`ContextEngineTests.swift:11`. Combined with a fresh container per harness run,
this satisfies the contract's container condition by both of its routes.

**Tier 1 — mechanical correctness, fixed expectations are correct here.**

- `metricArithmeticOnSyntheticFixture` — a hand-built 5-node case, no embeddings
  and no real corpus: 3 relevant nodes, 2 of them in the top-5 → assert
  precision@5 == 0.4 and recall@5 == 2.0/3.0. Exercises the metric functions,
  which must be factored out as free functions to be testable in isolation.
- `aggregationIsMeanNotSum` — a two-row synthetic `StrategyResult` with known
  values; asserts the aggregate is the mean.

**Tier 2 — the parameterized case the contract prefers, plus the real-run
inequalities.**

- `@Test(arguments: [RetrievalStrategy.semanticOnly, .recencyOnly, .decayWeightedSemantic])`
  `func strategyExecutesAllQueries(_ strategy:)` — one case per strategy. Asserts
  30 rows, every top-5 non-empty, every metric within `0...1`.
- `func comparisonTable()` — one harness run across all three strategies. Emits
  both tables, then asserts:
  - decay-weighted precision@5 **>=** semantic-only, over the 12 current-state indices
  - semantic-only precision@5 **>=** decay-weighted, over the 5 historical indices
  - decay-weighted aggregate precision@5 **>** recency-only aggregate, over all 30

  Inequalities only. **No expected score is hardcoded anywhere**, so no constant
  goes stale when half-life, top-K, or scoring changes.

- **Drift tripwire.** The subset index lists are positional and the fixture has no
  query IDs, so a reordering would silently re-point them. Store each list as
  `(index, expectedRelevantNodeID)` pairs — e.g. `(0, "n05")`, `(25, "n25")` —
  and assert the pair still matches the decoded fixture before using the subset.
  This is a guard against silent drift, not a re-derivation of the classification;
  the partition itself stays a visible test-author decision in the test file, and
  the fixture is untouched.

**Tier 3 — reproducibility.**

- `func reproducibleAcrossRuns()` — two full independent `run` calls (fresh
  embeddings, fresh containers, no shared state), asserting the per-query rows
  and aggregates are bit-identical via `.bitPattern` comparison, as
  `ContextEngineTests.swift:48` does. This is the contract's "running twice
  produces the same numbers" box, and it is only meaningful because the harness
  does not cache.

Query classification, half-life, top-K, and scoring are never asserted against a
fixed value. The table is the artifact; the headline percentages get read off a
run by hand, not baked into an assertion.

---

## Verification

1. `BuildProject` — scheme `Threads`, iPhone 17 Pro simulator. Must build clean.
2. `RunSomeTests` on `RetrievalEvalTests`. Read the printed table out of the log.
3. Run `RunSomeTests` a second time and diff the two tables — they must be
   character-identical. This is the reproducibility check done by hand, on top of
   the in-suite assertion.
4. `RunAllTests` — confirm the five existing `ContextEngineTests` and the
   SwiftData model tests still pass; the eval must not perturb them.
5. Sanity-check the first run against expectation: recency-only should score
   near-zero on the 12 current-state queries only if the corpus does not favor it
   by date — if recency-only wins outright, that is a finding about the corpus,
   to report rather than tune away.
6. Fresh-session verification per `.claude/rules/verify.md`, scoring all five
   dimensions. The verifier should confirm this runner was written in a session
   that never read the retrieval scoring internals — the Context section above
   records exactly which lines of `ContextEngine.swift` were read.

## Out of scope

No change to `RetrievalSet.json`, to `ContextEngine.swift`, or to any existing
test. No extraction spot-check. No `Eval/` directory.
