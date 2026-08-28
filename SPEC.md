# Thread

An iOS app with a local knowledge graph and measured retrieval quality.

## What Thread Is

Thread is an iOS app where you talk and the AI remembers. You hold a button, speak your thought, and release. The app transcribes it, classifies the input type, routes it to the right workstream, and builds a knowledge graph from everything you have said. On the next message it retrieves relevant context from that graph via on-device vector search and injects it into the Claude API call.

Three intelligence layers run underneath. Apple's NLContextualEmbedding handles semantic search. Apple's Foundation Models handle classification and structured extraction. Claude handles reasoning. The first two are free, offline, and instant, which means everything except the final reasoning call happens on the device.

The screen is for reviewing your thinking, not for entering it. A dark, information-dense UI shows workstreams, the extracted context graph, and the retrieval scores that produced each answer.

**The claim this project makes:** building a memory system is the easy part. Proving the memory retrieves the right thing is the part almost nobody does. Thread ships with a labeled eval set that scores decay-weighted semantic retrieval against two baselines on the same data.

---

## Three Properties

**Continuity.** The app maintains a local knowledge graph of everything discussed, organized into workstreams. Opening a thread retrieves semantically relevant history and injects it into the API call. After every response, an on-device LLM extracts structured context (facts, decisions, open questions, action items), which is embedded and stored locally.

**On-device by default.** Embedding, classification, extraction, summarization, and retrieval never leave the phone. Only the final reasoning question goes to the network, and it carries a token-budgeted context payload rather than a full history dump. When the network is unavailable the app degrades to on-device generation instead of failing.

**Measured, not assumed.** Retrieval quality is scored against a hand-labeled set. The relevance-decay strategy is validated against a recency-only baseline and a semantic-only baseline on identical data. This is the spine of the project.

---

## Architecture

```
User speaks or types
        |
        v
NLContextualEmbedding ---> Vector search ---> Relevant nodes
        |                                          |
        v                                          v
Foundation Models -------> Compact context     Claude API (SSE)
(on-device, free)          assembly            (heavy reasoning)
        |                                          |
        v                                          v
Classification,                            Streamed response
extraction, tagging                        rendered in thread
```

### Layer 1: NLContextualEmbedding (retrieval)

- Apple's BERT-based 512-dimensional sentence embeddings
- On-device, offline, zero inference cost
- Accelerate/vDSP for fast cosine similarity
- Mean-pooled token vectors, L2 normalized

### Layer 2: Foundation Models (local processing)

- ~3B parameter on-device LLM via the Foundation Models framework (iOS 26)
- Structured extraction via `@Generable` (facts, decisions, action items, open questions)
- Workstream summarization into compact context blobs
- Content tagging via specialized adapter
- Voice input classification and routing
- All on-device, offline-capable, zero inference cost

### Layer 3: Claude API (reasoning)

- Server-Sent Events streaming via pure URLSession async bytes
- Receives a pre-assembled context payload from Layers 1 and 2
- Token budgeting: workstream summary, top-K relevant nodes, recent messages
- Provider-agnostic via `LLMStreamingProvider`
- Automatic fallback to Foundation Models when the network is unavailable

---

## Technical Decisions

**These are imperative preferences. Locked.** They live in `.claude/rules/DECISIONS.md` so they survive compaction and no later session "improves" a choice that was deliberate.

| Decision | Rationale |
| --- | --- |
| SwiftData over Core Data | Declarative API, `#Unique`/`#Index` macros, iOS 26 native |
| NLContextualEmbedding over external vector DB | On-device, no network dependency, free, sufficient for a local corpus |
| Foundation Models for extraction | Zero cost, offline, fast enough for background processing |
| Actor isolation for services | Thread-safe by construction, no manual locking |
| Actor isolation scoped to stateful services | Services owning mutable state or resources are actors; pure scoring and transformation types are non-actor by design |
| Explicit `nonisolated` on non-actor types | Project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so types intended to be isolation-free must say so |
| `@concurrent` for CPU work | Swift 6 Approachable Concurrency, explicit background opt-in |
| SpeechAnalyzer over SFSpeechRecognizer | iOS 26 API, modular, offline-first, Swift Concurrency native |
| Relevance decay (14-day half-life) | Prevents stale context from dominating retrieval |
| `decayStrength` = 0.25 | Bounds decay's authority over ranking independently of the half-life's curve shape (see `ContextEngine.swift` for the full derivation and the vacuous-range caveat) |
| Retrieval strategy parameterized | Enables clean eval comparison against identical data |
| Superseded-node links | Makes "topically near but wrong" a first-class retrieval case rather than an eval afterthought |
| Extraction confidence scoring | Enables escalation to Claude for low-confidence extractions; also drives UI dimming |
| Provider protocol abstraction | Swap providers, enables offline fallback and deterministic testing |
| Raw `String` storage for enums | `#Predicate` and `#Index` only work with primitive types |

**Declarative, agent's call:** view composition, animation timing, internal helper structure, naming below the type level, test organization. Standing clause for every session: *if you find a design that better achieves the contract than the one specified, raise it as an option before implementing it.*

---

## Development Process

The project is built with an AI coding agent under a fixed harness. The constraints below exist because they are what make the results checkable by someone who did not write them.

**Contract-driven.** Each unit of work has a `CONTRACT_*.md` naming the checkable outcomes, the files in scope, and the files explicitly out of scope. A task is done only when its contract is satisfied. Tests are never edited to make them pass.

**Verification in a fresh context.** Every diff is reviewed in a session that did not write it, against a five-dimension rubric — spec fidelity (must score 4+), correctness, test quality, concurrency and actor isolation safety, and scope discipline. Same-context self-review produces shallow agreement. Research and implementation likewise never share a context: plan, write the plan to a file, clear, implement from the plan.

**iOS 26 API signatures are extracted, not recalled.** FoundationModels, Speech, and NaturalLanguage postdate most model training data, and a model will invent plausible signatures for them. The real initializers and method signatures are read out of the SDK's `.swiftinterface` files and headers into `.claude/rules/ios26-apis.md`, with the SDK version recorded.

**Eval integrity.** Every query, every `relevant_node_ids` set, and especially every `irrelevant_but_tempting` set is human-authored. The agent never generates or modifies them. The eval runner was written in a session that had never seen the retrieval strategy implementation. Any change to decay half-life, top-K, or scoring re-runs the full three-strategy comparison and reports deltas.

**Harness layout**

```
CLAUDE.md                      (auto-loads; routing + fallback triggers)
CONTRACT.template.md
CONTRACT_core_loop.md
CONTRACT_models.md
CONTRACT_context_engine.md
CONTRACT_eval.md
.claude/rules/
  DECISIONS.md                 (no paths: — loads unconditionally)
  verify.md                    (no paths: — loads unconditionally)
  swiftdata.md                 (paths: **/*.swift)
  ios26-apis.md                (paths: scoped to Core)
  evals.md                     (paths: Eval/**)
  ui.md                        (paths: **/Views/**, **/*View.swift)
```

Auto memory disabled via `autoMemoryEnabled: false` in project settings. Deployment target iOS 26.4, Swift 6. Scheme `Threads`, test target `ThreadsTests`. Builds and tests run through Xcode's `mcpbridge` MCP server rather than a third-party wrapper.

---

## Data Models (SwiftData)

### Workstream

The primary organizational unit. A project, a decision, an open question.

- `id: UUID`
- `title: String`
- `summary: String`
- `status: String` (raw value of `WorkstreamStatus`)
- `isPinned: Bool`
- `createdAt: Date`
- `updatedAt: Date`
- `compactContext: String` (Foundation Models generated, injected into API calls)
- `tags: [String]`
- `messages: [Message]` (cascade delete, inverse)
- `contextNodes: [ContextNode]` (cascade delete, inverse)

### Message

- `id: UUID`
- `role: MessageRole` (user / assistant / system)
- `content: String`
- `createdAt: Date`
- `contentBlocksData: Data?` (JSON-encoded structured blocks)
- `isEmbedded: Bool`
- `estimatedTokens: Int` (~4 chars per token)
- `workstream: Workstream?`

### ContextNode

The atoms of the knowledge graph.

- `id: UUID`
- `content: String`
- `nodeType: ContextNodeType` (fact / decision / openQuestion / reference / actionItem / insight)
- `createdAt: Date`
- `lastAccessedAt: Date`
- `embeddingData: Data?` (512 doubles as raw bytes, 4KB per node)
- `relevanceScore: Double` (14-day half-life decay)
- `sourceMessageID: UUID?`
- `supersededByID: UUID?` — set when a later node replaces this one. Superseded nodes are down-weighted in retrieval and dimmed in the Context tab. This is the schema-level version of "the decision changed," and it is what makes the eval's tempting-but-wrong cases principled.
- `extractionConfidence: Double` — Foundation Models confidence for this extraction. Below threshold, escalate the extraction to Claude. Cheap to store, and it is the honest answer to "what happens when the 3B model gets it wrong."
- `workstream: Workstream?`

### ProactiveSurfacing

Retained in the schema, not built as a feature in this cycle.

- `id: UUID`
- `content: String`
- `triggerReason: String`
- `createdAt: Date`
- `wasEngaged: Bool`
- `relatedWorkstreamID: UUID?`

---

## Build Status

Update this section whenever a file lands, before anything else in this document.

### Built and verified

**/Models**

- `SwiftDataModels.swift` — four `@Model` classes with `#Unique`, `#Index`, and relationships. Enums stored as raw Strings. Tests green: create/fetch per model, `#Predicate` filtering on the raw String status, cascade delete, 512-double embedding round-trip.

**/Core**

- `ContextEngine.swift` — `EmbeddingService` (actor; NLContextualEmbedding wrapper with vDSP cosine similarity) and `ContextRetrievalEngine` (explicitly `nonisolated` struct; payload assembly, token budgeting, relevance decay, `decayStrength` bounding). Retrieval is parameterized by strategy and returns nodes with their scores.
- `LLMProvider.swift` — `LLMStreamingProvider` protocol, `ClaudeSSEProvider` (SSE over `URLSession.AsyncBytes`, no SDK), `OnDeviceFallbackProvider` (Foundation Models), and `LLMProviderFactory`. Covers streaming SSE parsing, API key resolution precedence, request encoding, transparent failover, and refusal handling. Not yet wired into an orchestrator.

**/ThreadsTests**

- `RetrievalSet.json` — 36-node synthetic corpus, six supersession chains, 30 hand-authored labeled queries. Frozen and committed as a standalone commit for provenance. Human-authored; never agent-modified.
- `RetrievalEval.swift` — three-strategy eval runner. Fixed evaluation clock, deterministic node IDs, no caching, macro-averaged precision@5 / recall@5, tier-2 assertions as inequalities rather than golden numbers. Runs on physical device only.
- `LLMProviderTests.swift` — SSE parser state machine against canned event lines, request-body shape, key resolution, factory routing and failover, and the Claude provider over a stubbed `URLProtocol` transport.
- `ModelContainerHelper.swift` — per-test in-memory `ModelContainer`.

### Not yet built

**/Core**

- `OnDeviceIntelligence.swift` — Foundation Models integration, four `@Generable` types (`ExtractedContext`, `WorkstreamSummary`, `ProactiveAnalysis`, `ContentTags`), separate `LanguageModelSession` per task type.
- `ThreadOrchestrator.swift` — the full message lifecycle through a single `send()` entry point.

**/App**

- `ThreadsApp.swift` exists with real-schema `ModelContainer` configuration. API key wiring not yet built.

**/Features**

- `WorkstreamListView.swift` — not built.
- `ConversationView.swift` — not built.

**Consequence:** no message can currently be sent end to end. The eval ran ahead of the core loop, since it depends only on the models and `ContextEngine`. The orchestrator and a minimal send/receive UI are the outstanding work.

---

## Message Lifecycle

1. Save user message to SwiftData
2. Embed user message (background, non-blocking)
3. Retrieve relevant context via cosine similarity against stored node embeddings
4. Build conversation history within token budget (walk backwards until limit)
5. Assemble context payload as system prompt (workstream summary plus relevant nodes)
6. Stream LLM response (primary provider, automatic fallback on failure)
7. Save assistant message
8. Extract context nodes via Foundation Models (background)
9. Score extraction confidence; escalate to Claude below threshold
10. Mark superseded nodes where a new decision replaces an earlier one
11. Embed new context nodes
12. Update workstream summary every 10 messages

---

## The Eval Layer

This is the differentiator and it runs early, not last. It depends only on `ContextEngine` and a bundled node set, so it does not wait on voice, UI, or the orchestrator.

The labeled set is capped at 30 queries. This task expands to fill available time; the cap is deliberate.

**Labeling integrity, non-negotiable.** Every query, every `relevant_node_ids` set, and especially every `irrelevant_but_tempting` set is human-authored. If the agent writes the labels, the tempting-node cases will be exactly the ones its own strategy already handles and the eval measures nothing. Enforced by `.claude/rules/evals.md`.

### 1. Labeled retrieval set (`ThreadsTests/RetrievalSet.json`)

A fixed graph of 36 context nodes for one synthetic workstream: facts established, decisions made, open questions, action items, and some deliberately stale or superseded. Then 30 labeled queries.

```json
{
  "query": "what did we decide about the auth migration",
  "relevant_node_ids": ["node_12", "node_23"],
  "irrelevant_but_tempting": ["node_08"]
}
```

`irrelevant_but_tempting` is what makes this an eval rather than a smoke test: nodes that are topically adjacent but wrong. A superseded decision, a resolved question, a stale fact. Recency-only fails here. Decay-weighted semantic retrieval should win, and the `supersededByID` field is what lets it.

Because the node set is hand-labeled and synthetic, the eval measures retrieval in isolation and is not contaminated by extraction quality. That separation is deliberate.

**As built.** 36 nodes, six supersession chains (`n01→n05`, `n10→n09`, `n11→n15`, `n16→n23`, `n20→n24`, `n25→n29`), dates spanning 2026-06-02 to 2026-07-31. The 30 queries partition into 12 current-state (correct answer is the successor, the superseded predecessor is the tempting node), 5 historical (correct answer is itself superseded), and 13 touching no supersession chain.

### 2. Eval runner (`ThreadsTests/RetrievalEval.swift`)

Built in a session that has never seen the retrieval strategy implementation. Runs each query through three configs against the identical node set, scoring precision@5 and recall@5:

- **semantic-only** — cosine similarity, no decay
- **recency-only** — most recent nodes, no semantic ranking (the baseline)
- **decay-weighted semantic** — cosine multiplied by relevance decay (the actual strategy)

Assertions are inequalities, never golden numbers, so no constant goes stale when half-life, top-K, or scoring changes. The comparison table is emitted via `print()` plus `Attachment.record`; nothing is written to disk and no numbers are checked in.

### 3. Results

**First run.** Decay-weighted semantic produced an identical top-5 to recency-only on 30/30 queries and was identical in every aggregate cell. The contract's current-state and aggregate assertions both failed.

**Diagnosis.** Semantic similarity across the 36 candidates within a single query spans only ~1.24× (all 1,080 query-node pairs land in 0.72–0.97), while the 14-day decay factor spans 0.052–0.982 across the corpus's ~60-day date range — an 18.8× range. Multiplying a near-constant term by a wide-ranging one lets decay determine the ordering alone. Normalizing the semantic term was necessary but not sufficient; an 18.8× multiplicative decay still swamped a fully normalized 0–1 similarity.

**Fix.** `decayStrength` (default 0.25), forming `1 − s·(1 − decayFactor)`, bounding decay's authority over ranking separately from the shape of the decay curve. The 14-day half-life is untouched, since that locked decision is about the curve's shape. Multiplicative form retained per `CONTRACT_context_engine.md`. Value selected as the midpoint of the joint passing region, confirmed by a second sweep run in a session blind to the first's numbers.

**Final table** (physical device, 30 queries, top-K 5, `decayStrength` 0.25):

| Strategy | Precision@5 | Recall@5 | Tempting node in top-5 |
| --- | --- | --- | --- |
| semantic-only | 0.1200 | 0.6000 | 0.3667 |
| recency-only | 0.0333 | 0.1667 | 0.2000 |
| decay-weighted semantic | 0.1333 | 0.6667 | 0.4333 |

Subset breakdown, precision@5:

| Strategy | Current-state (12) | Historical (5) | Unrelated (13) |
| --- | --- | --- | --- |
| semantic-only | 0.1333 | 0.0000 | 0.1538 |
| recency-only | 0.0333 | 0.0000 | 0.0462 |
| decay-weighted semantic | 0.1500 | 0.0000 | 0.1692 |

**Caveats.** These are not footnotes; state them.

- Every query has exactly one relevant node, so precision@5 ≡ recall@5 ÷ 5 exactly at every level of aggregation. The two columns are not independent evidence. Precision@5's ceiling is 0.2, not 1.0 — 0.1333 means 20 of 30 queries hit, not "13% quality."
- Decay-weighted beats semantic-only by 0.0133 aggregate, which is a two-query difference. Do not report it as a large margin.
- Decay-weighted's tempting-node hit rate got *worse* after the fix (0.2000 → 0.4333) and is now above semantic-only's. It is the only aggregate carrying independent signal, and it moved the wrong way. Unexplained.
- The historical subset scores 0.0000 for all three strategies — no strategy ever surfaces a superseded node in the top-5. The `semantic ≥ decay` historical assertion is passing vacuously and is evidence of nothing. n=5 was thin by design; the reality is worse than thin.
- The raw `decayStrength` sweep passes for 0.00–0.45, but `s = 0` makes decay inert and decay-weighted identical to semantic-only, satisfying the non-strict assertion while proving nothing. Quote the non-vacuous range (~0.10–0.45), never the raw boundary.

**Why not Apple's Evaluations framework.** It scores model output quality. This scores retrieval ranking against hand-labeled adjacent-but-wrong nodes. Different problem.

**Environment.** `NLContextualEmbedding` cannot compile its E5 model on the iPhone 17 Pro simulator (`NLNaturalLanguageErrorDomain` Code=7). `requestAssets()` returns `.available`; `load()` fails. Erasing the simulator, booting the base device, and disabling parallel testing changed nothing. The eval and any embedding-dependent test run on a physical device only.

### 4. Extraction spot-check (optional)

Ten sample messages through Foundation Models extraction, scored against a hand-labeled gold set. This is a breadth signal, not the headline. It does not gate the retrieval eval's validity, but extraction quality does gate the end-to-end behavior.

---

## SwiftData Constraints

Hard-won. Apply everywhere. **This section is `.claude/rules/swiftdata.md`** — keep the two in sync, or better, keep only the file and link to it here.

- `#Predicate` only works with primitive stored types (String, Int, Bool, Date, UUID, Double). Never use enums directly. Filter in memory.
- `#Index` can appear only once per `@Model`. Only primitive keypaths. No relationship or enum keypaths.
- `@Query` `SortDescriptor` fails with Bool. Sort in a computed property.
- Enum properties used in predicates must be stored as raw Strings with computed typed accessors.
- `NLContextualEmbedding` uses `init(script:)` or `init(language:)`, not static factory methods.
- `@MainActor` classes cannot reference isolated properties in `deinit`. Use explicit cleanup methods.

---

## UI Direction

Dark mode default, high contrast, minimal color outside semantic indicators. Voice is the primary input and the capture bar is the dominant element. The screen is for reviewing and browsing, not typing prompts. Information-dense. A professional instrument, not a wellness app.

**Color system**

- Background `#0F0F0F`, surface `#1A1A1A`, elevated `#242424`
- Text primary white 90%, secondary white 50%
- Accent `#4A9EFF`
- Facts `#4A9EFF`, Decisions `#FFB84D`, Open Questions `#FF6B6B`, Action Items `#4ADE80`
- Superseded nodes render at 30% opacity with a strikethrough rule

**Screen 1: Home**
Voice capture bar at top (full-width, hold to record, live waveform and transcript). Workstream cards below (title, summary, node count, tags, latest node). Empty state: centered mic, "Hold to capture your first thought."

**Screen 2: Workstream Detail, three tabs**

- **Stream** — conversation flow. User input plain, AI responses with a blue left border, inline cards for extracted context.
- **Context** — knowledge graph. Nodes grouped by type with semantic color borders, relevance scores visible, decayed and superseded nodes dimmed.
- **Insights** — proactive feed. Stubbed this cycle.

**Voice capture bar**
Large mic icon in a rounded rectangle. Long press to record, release to send. Waveform plus live transcript while recording. Medium haptic on start, light on stop. `.glassEffect(.regular.interactive)`.

**Debug inspector**
Long-press any AI response to reveal the assembled system prompt and the live retrieval scores that produced it. This makes the intelligence layer legible.

---

## Scope Boundaries

Deliberately not built in this cycle:

- Intelligent voice routing
- Proactive surfacing and Live Activities
- App Intents, Share Sheet, Spotlight
- Markdown vault and export
- Corpus-wide reprocessing
- Contradiction detection as a user-facing feature; it exists here only as `supersededByID`
- Nightly distillation jobs (not possible on iOS, already handled by relevance decay)
- Any agent tooling beyond the base harness. No third-party MCP servers, memory layers, or skill packs.
