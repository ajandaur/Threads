# Thread — Spec

## What Thread Is

Thread is an iOS app where you talk and the AI remembers. Hold a button, speak your thought, release. The app transcribes it, classifies the input type, routes it to the right workstream, and builds a knowledge graph from everything you've said. On the next message, it retrieves relevant context from that graph via on-device vector search and injects it into the Claude API call.

Three intelligence layers run underneath — Apple's `NLContextualEmbedding` handles semantic search, Apple's Foundation Models handle classification and structured extraction, and Claude handles reasoning. The first two are free, offline, and instant, so everything except the final reasoning call happens on the device.

The screen is for reviewing your thinking, not for entering it: a dark, information-dense UI shows workstreams, the extracted context graph, and the retrieval scores that produced each answer.

**The claim this project makes:** building a memory system is the easy part. Proving the memory retrieves the right thing is the part almost nobody does. Thread ships with a labeled eval set that scores decay-weighted semantic retrieval against two baselines on the same data.

## Three Properties

**Continuity.** The app maintains a local knowledge graph of everything discussed, organized into workstreams. Opening a thread retrieves semantically relevant history and injects it into the API call. After every response, an on-device LLM extracts structured context (facts, decisions, open questions, action items), which is embedded and stored locally.

**On-device by default.** Embedding, classification, extraction, summarization, and retrieval never leave the phone. Only the final reasoning question goes to the network, carrying a token-budgeted context payload rather than a full history dump. When the network is unavailable, the app degrades to on-device generation instead of failing.

**Measured, not assumed.** Retrieval quality is scored against a hand-labeled set. The relevance-decay strategy is validated against a recency-only baseline and a semantic-only baseline on identical data. This is the spine of the project, and the section the blog post leads with.

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

### Layer 1 — `NLContextualEmbedding` (retrieval)
- Apple's BERT-based 512-dimensional sentence embeddings
- On-device, offline, zero inference cost
- Accelerate/vDSP for fast cosine similarity
- Mean-pooled token vectors, L2 normalized

### Layer 2 — Foundation Models (local processing)
- ~3B parameter on-device LLM via the Foundation Models framework (iOS 26)
- Structured extraction via `@Generable` (facts, decisions, action items, open questions)
- Workstream summarization into compact context blobs
- Content tagging via a specialized adapter
- Voice input classification and routing
- All on-device, offline-capable, zero inference cost

### Layer 3 — Claude API (reasoning)
- Server-Sent Events streaming via pure `URLSession` async bytes
- Receives a pre-assembled context payload from Layers 1 and 2
- Token budgeting: workstream summary, top-K relevant nodes, recent messages
- Provider-agnostic via `LLMStreamingProvider`
- Automatic fallback to Foundation Models when the network is unavailable

---

## Technical Decisions

Imperative preferences, locked, and living in [`.claude/rules/DECISIONS.md`](./.claude/rules/DECISIONS.md) so they survive compaction and no later session "improves" a choice that was deliberate.

| Decision | Rationale |
|---|---|
| SwiftData over Core Data | Declarative API, `#Unique`/`#Index` macros, iOS 26 native |
| `NLContextualEmbedding` over an external vector DB | On-device, no network dependency, free, sufficient for a local corpus |
| Foundation Models for extraction | Zero cost, offline, fast enough for background processing |
| Actor isolation for services | Thread-safe by construction, no manual locking |
| `@concurrent` for CPU work | Swift 6.2 Approachable Concurrency, explicit background opt-in |
| `SpeechAnalyzer` over `SFSpeechRecognizer` | iOS 26 API, modular, offline-first, Swift Concurrency native |
| Relevance decay (14-day half-life) | Prevents stale context from dominating retrieval |
| Retrieval strategy parameterized | Enables a clean eval comparison against identical data |
| Superseded-node links | Makes "topically near but wrong" a first-class retrieval case rather than an eval afterthought |
| Extraction confidence scoring | Enables escalation to Claude for low-confidence extractions; also drives UI dimming |
| Provider protocol abstraction | Swap providers, enables offline fallback and deterministic testing |
| Raw `String` storage for enums | `#Predicate` and `#Index` only work with primitive types |

Everything else — view composition, animation timing, internal helper structure, naming below the type level, test organization — is declarative, the agent's call. Standing clause: if a design better achieves the contract than the one specified here, raise it as an option before implementing it.

---

## Data Models (SwiftData)

### `Workstream`
The primary organizational unit — a project, a decision, an open question.

| Field | Type | Notes |
|---|---|---|
| `id` | `UUID` | |
| `title` | `String` | |
| `summary` | `String` | |
| `status` | `String` | raw value of `WorkstreamStatus` |
| `isPinned` | `Bool` | |
| `createdAt` / `updatedAt` | `Date` | |
| `compactContext` | `String` | Foundation Models generated, injected into API calls |
| `tags` | `[String]` | |
| `messages` | `[Message]` | cascade delete, inverse |
| `contextNodes` | `[ContextNode]` | cascade delete, inverse |

### `Message`

| Field | Type | Notes |
|---|---|---|
| `id` | `UUID` | |
| `role` | `MessageRole` | user / assistant / system |
| `content` | `String` | |
| `createdAt` | `Date` | |
| `contentBlocksData` | `Data?` | JSON-encoded structured blocks |
| `isEmbedded` | `Bool` | |
| `estimatedTokens` | `Int` | ~4 chars per token |
| `workstream` | `Workstream?` | |

### `ContextNode`
The atoms of the knowledge graph.

| Field | Type | Notes |
|---|---|---|
| `id` | `UUID` | |
| `content` | `String` | |
| `nodeType` | `ContextNodeType` | fact / decision / openQuestion / reference / actionItem / insight |
| `createdAt` / `lastAccessedAt` | `Date` | |
| `embeddingData` | `Data?` | 512 doubles as raw bytes, 4KB per node |
| `relevanceScore` | `Double` | 14-day half-life decay |
| `sourceMessageID` | `UUID?` | |
| `supersededByID` | `UUID?` | Set when a later node replaces this one. Superseded nodes are down-weighted in retrieval and dimmed in the Context tab — the schema-level version of "the decision changed," and what makes the eval's tempting-but-wrong cases principled. |
| `extractionConfidence` | `Double` | Foundation Models' confidence for this extraction. Below threshold, escalate to Claude. Cheap to store, and the honest answer to "what happens when the 3B model gets it wrong." |
| `workstream` | `Workstream?` | |

### `ProactiveSurfacing`
Retained in the schema, not built as a feature in this cycle.

| Field | Type |
|---|---|
| `id` | `UUID` |
| `content` | `String` |
| `triggerReason` | `String` |
| `createdAt` | `Date` |
| `wasEngaged` | `Bool` |
| `relatedWorkstreamID` | `UUID?` |

---

## Message Lifecycle

1. Save user message to SwiftData
2. Embed user message (background, non-blocking)
3. Retrieve relevant context via cosine similarity against stored node embeddings
4. Build conversation history within token budget (walk backwards until limit)
5. Assemble context payload as system prompt (workstream summary + relevant nodes)
6. Stream LLM response (primary provider, automatic fallback on failure)
7. Save assistant message
8. Extract context nodes via Foundation Models (background)
9. Score extraction confidence; escalate to Claude below threshold
10. Mark superseded nodes where a new decision replaces an earlier one
11. Embed new context nodes
12. Update workstream summary every 10 messages

---

## The Eval Layer

The differentiator, and it runs early rather than last — it depends only on `ContextEngine` and a bundled node set, so it doesn't wait on voice, UI, or the orchestrator.

Cap the labeled set at 30 queries. If a clean comparison isn't producing by end of the allotted day, ship the partial result and write it up honestly — this task expands to fill available time.

**Labeling integrity is non-negotiable.** Every query, every `relevant_node_ids` set, and especially every `irrelevant_but_tempting` set is human-authored (budget ~2 hours). If the agent writes the labels, the tempting-node cases end up being exactly the ones its own strategy already handles, the eval measures nothing, and the first question any interviewer asks about a self-built eval is who labeled it. Enforced by [`.claude/rules/evals.md`](./.claude/rules/evals.md).

### 1. Labeled retrieval set
`Eval/RetrievalSet.swift` (or bundled JSON) — a fixed graph of ~40 context nodes for one synthetic workstream (facts established, decisions made, open questions, action items, some deliberately stale or superseded), plus 25–30 labeled queries:

```json
{
  "query": "what did we decide about the auth migration",
  "relevant_node_ids": ["node_12", "node_23"],
  "irrelevant_but_tempting": ["node_08"]
}
```

`irrelevant_but_tempting` is what makes this an eval rather than a smoke test — nodes that are topically adjacent but wrong: a superseded decision, a resolved question, a stale fact. Recency-only fails here; decay-weighted semantic retrieval should win, and `supersededByID` is what lets it.

Because the node set is hand-labeled and synthetic, the eval measures retrieval in isolation, uncontaminated by extraction quality. That separation is deliberate and worth stating in the write-up.

### 2. Eval runner
`Eval/RetrievalEval.swift` — built in a session that has never seen the retrieval strategy's implementation. Runs each query through three configs against the identical node set, scoring precision@5 and recall@5:

- **semantic-only** — cosine similarity, no decay
- **recency-only** — most recent nodes, no semantic ranking (the baseline)
- **decay-weighted semantic** — cosine × relevance decay (the actual strategy)

Output is a three-by-two table. The sentence to be able to say: *"decay-weighted semantic retrieval improved precision@5 by X% over recency-only and Y% over semantic-only on a 30-query labeled set."* That sentence is worth more than any three architecture bullets.

Prefer a Swift Testing case over a debug-menu action — it shows up as a test, runs in CI, and gives `CONTRACT_eval.md` a deterministic done-condition.

### 3. Extraction spot-check (optional)
Ten sample messages through Foundation Models extraction, scored against a hand-labeled gold set. A breadth signal, not the headline — doesn't gate the retrieval eval's validity, but extraction quality does gate the demo, so run it as a sanity check before recording. Cut it entirely before touching the retrieval eval.

---

## SwiftData Constraints

Hard-won, apply everywhere. Canonical version lives in [`.claude/rules/swiftdata.md`](./.claude/rules/swiftdata.md) — kept in sync here as a quick reference:

- `#Predicate` only works with primitive stored types (`String`, `Int`, `Bool`, `Date`, `UUID`, `Double`). Never use enums directly — filter in memory.
- `#Index` can appear only once per `@Model`. Only primitive keypaths — no relationship or enum keypaths.
- `@Query`'s `SortDescriptor` fails with `Bool`. Sort in a computed property instead.
- Enum properties used in predicates must be stored as raw `String`s with computed typed accessors.
- `NLContextualEmbedding` uses `init(script:)` or `init(language:)`, never a static factory method.
- `@MainActor` classes can't reference isolated properties in `deinit` — use explicit cleanup methods.

---

## UI Direction

Dark mode default, high contrast, minimal color outside semantic indicators. Voice is the primary input and the capture bar is the dominant element. The screen is for reviewing and browsing, not typing prompts — information-dense, a professional instrument rather than a wellness app.

### Color system
| Role | Value |
|---|---|
| Background | `#0F0F0F` |
| Surface | `#1A1A1A` |
| Elevated | `#242424` |
| Text primary | white @ 90% |
| Text secondary | white @ 50% |
| Accent | `#4A9EFF` |
| Facts | `#4A9EFF` |
| Decisions | `#FFB84D` |
| Open Questions | `#FF6B6B` |
| Action Items | `#4ADE80` |

Superseded nodes render at 30% opacity with a strikethrough rule.

### Screen 1 — Home
Voice capture bar at top (full-width, hold to record, live waveform and transcript). Workstream cards below (title, summary, node count, tags, latest node). Empty state: centered mic, "Hold to capture your first thought."

### Screen 2 — Workstream Detail
Three tabs:
- **Stream** — conversation flow. User input plain, AI responses with a blue left border, inline cards for extracted context.
- **Context** — knowledge graph. Nodes grouped by type with semantic color borders, relevance scores visible, decayed and superseded nodes dimmed.
- **Insights** — proactive feed. Stubbed this cycle.

### Voice capture bar
Large mic icon in a rounded rectangle. Long press to record, release to send. Waveform plus live transcript while recording. Medium haptic on start, light on stop. `.glassEffect(.regular.interactive)`.

### Debug inspector
Long-press any AI response to reveal the assembled system prompt and the live retrieval scores that produced it. Makes the intelligence layer legible — the single most persuasive thing in the demo.

---

## Build Plan (Day 0 + 12 days)

The eval sits at days 3–4 rather than at the end: it's the differentiator, has the fewest dependencies in the project, and shouldn't sit behind voice and UI — the components most likely to slip.

| Days | Focus |
|---|---|
| Day 0 | **Harness.** Agent harness wired and verified (`xcrun mcpbridge`), `CLAUDE.md`, `DECISIONS.md`, rules files, both contracts written before either is built. No feature code. |
| 1–2 | **Core loop.** Send message → Claude responds → nodes extracted → follow-up retrieves context → response shows awareness, verified end to end against `CONTRACT_core_loop.md`. Screen-record it the moment it works — that recording is the insurance demo. |
| 3–4 | **Retrieval eval.** Hand-label ~30 queries first, in a human session, before any agent work. Then the runner, in a fresh context. Precision@5 and recall@5 across the three strategies, comparison table produced. Protect these two days above everything else. |
| 5–6 | **UI and debug inspector.** Dark theme, voice-first layout, Context tab with semantic colors and dimming. Build the inspector in this window so it survives a slip. |
| 7–8 | **Voice.** `AudioStreamManager` with `SpeechAnalyzer`, wired to the capture bar and orchestrator. Manual verification, not agentic. Fall back to `SFSpeechRecognizer` without hesitation if `SpeechAnalyzer` costs more than half a day. |
| 9–10 | **Polish.** Liquid Glass on the capture bar and tab selector, haptics, spring animations for streaming and node appearance. Extraction spot-check if there's room. |
| 11–12 | **Ship.** Blog post, 90-second demo video (debug inspector + eval table beats included), push to GitHub, update resume. |

---

## Out of Scope

Explicitly not building this cycle: intelligent voice routing, proactive surfacing and Live Activities, App Intents / Share Sheet / Spotlight, a Markdown vault and export, corpus-wide reprocessing, contradiction detection as a user-facing feature (exists only as `supersededByID`), app icon and launch screen, nightly distillation jobs (unnecessary on iOS — relevance decay already handles it), and any agent tooling beyond the Day 0 harness (no third-party MCP servers, memory layers, or skill packs).

---

## Working Process

- **Research and implementation never share a context.** Plan mode → write the plan to a file → `/clear` → implement from the plan.
- **Verify in a fresh session** against [`.claude/rules/verify.md`](./.claude/rules/verify.md). Same-context self-review produces shallow agreement.
- **Neutral prompts.** "Trace the logic of each component and report all findings," not "find the bug."
- **One agent editing at a time.** Keep Xcode open for building/previewing, edit from the CLI, let Xcode pick up disk changes.
- Which surface for what:
  - Models, `ContextEngine`, eval runner, tests, git, docs → Claude Code CLI, bridged to Xcode
  - UI and the debug inspector (Days 5–6) → Xcode's native Agent panel, for live preview capture
  - Breakpoints, Instruments, actor isolation bugs, voice (Days 7–8) → manual, in Xcode, no agent — live mic behavior isn't agent-verifiable

Full harness details (MCP setup, `CLAUDE.md`, `DECISIONS.md`, rules files, contract template) live in the actual files at the repo root and under [`.claude/`](./.claude) rather than duplicated here.

---

## Blog Post Outline

**Title:** *How I Measured Whether My AI's Memory Actually Works (and Built It on iOS)*

1. **The problem** — why AI conversations forget, and why the naive fixes (dump all history, or rank by recency) fail.
2. **The three-layer solution** — on-device embeddings for retrieval, on-device LLM for extraction, Claude for reasoning.
3. **The eval** — how retrieval quality was measured, the three strategies compared, the results table, why the labeled node set is synthetic, who labeled it. Lead with this.
4. **The iOS engineering** — SwiftData constraints, actor isolation, concurrency decisions, token budgeting.
5. **What's next** — proactive surfacing, App Intents, where the architecture generalizes. One closing paragraph on context continuity as a patient-safety problem in healthcare, as a coda rather than the frame.

---

## Deliverables

- [ ] Day 0 harness: `mcpbridge` connected, `CLAUDE.md`, `DECISIONS.md`, rules files, two contracts
- [ ] Core loop working: voice in, context retrieved, response shows awareness
- [ ] Screen recording of the context continuity demo
- [ ] Retrieval eval: ~30 human-labeled queries, precision@5 and recall@5, three-strategy table
- [ ] Debug inspector showing system prompt and retrieval scores
- [ ] Dark mode voice-first UI
- [ ] Context tab with semantic colors, decay dimming, superseded rendering
- [ ] Voice capture via `SpeechAnalyzer` (or `SFSpeechRecognizer` fallback)
- [ ] Optional: extraction spot-check
- [ ] Blog post, leading with the eval
- [ ] 90-second demo video with voiceover
- [ ] Code on GitHub, resume updated
