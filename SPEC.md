What Thread Is
Thread is an iOS app where you talk and the AI remembers. You hold a button, speak your thought, and release. The app transcribes it, classifies the input type, routes it to the right workstream, and builds a knowledge graph from everything you have said. On the next message it retrieves relevant context from that graph via on-device vector search and injects it into the Claude API call.
Three intelligence layers run underneath. Apple's NLContextualEmbedding handles semantic search. Apple's Foundation Models handle classification and structured extraction. Claude handles reasoning. The first two are free, offline, and instant, which means everything except the final reasoning call happens on the device.
The screen is for reviewing your thinking, not for entering it. A dark, information-dense UI shows workstreams, the extracted context graph, and the retrieval scores that produced each answer.
The claim this project makes: building a memory system is the easy part. Proving the memory retrieves the right thing is the part almost nobody does. Thread ships with a labeled eval set that scores decay-weighted semantic retrieval against two baselines on the same data.
Three Properties
Continuity. The app maintains a local knowledge graph of everything discussed, organized into workstreams. Opening a thread retrieves semantically relevant history and injects it into the API call. After every response, an on-device LLM extracts structured context (facts, decisions, open questions, action items), which is embedded and stored locally.
On-device by default. Embedding, classification, extraction, summarization, and retrieval never leave the phone. Only the final reasoning question goes to the network, and it carries a token-budgeted context payload rather than a full history dump. When the network is unavailable the app degrades to on-device generation instead of failing.
Measured, not assumed. Retrieval quality is scored against a hand-labeled set. The relevance-decay strategy is validated against a recency-only baseline and a semantic-only baseline on identical data. This is the spine of the project and the section the blog post leads with.
Architecture
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
​
Layer 1: NLContextualEmbedding (retrieval)
Apple's BERT-based 512-dimensional sentence embeddings
On-device, offline, zero inference cost
Accelerate/vDSP for fast cosine similarity
Mean-pooled token vectors, L2 normalized
Layer 2: Foundation Models (local processing)
~3B parameter on-device LLM via the Foundation Models framework (iOS 26)
Structured extraction via @Generable (facts, decisions, action items, open questions)
Workstream summarization into compact context blobs
Content tagging via specialized adapter
Voice input classification and routing
All on-device, offline-capable, zero inference cost
Layer 3: Claude API (reasoning)
Server-Sent Events streaming via pure URLSession async bytes
Receives a pre-assembled context payload from Layers 1 and 2
Token budgeting: workstream summary, top-K relevant nodes, recent messages
Provider-agnostic via LLMStreamingProvider
Automatic fallback to Foundation Models when the network is unavailable
Technical Decisions
These are imperative preferences. Locked. They live in DECISIONS.md (see the harness section) so they survive compaction and no later session "improves" a choice that was deliberate.
Decision
Rationale
SwiftData over Core Data
Declarative API, #Unique/#Index macros, iOS 26 native
NLContextualEmbedding over external vector DB
On-device, no network dependency, free, sufficient for a local corpus
Foundation Models for extraction
Zero cost, offline, fast enough for background processing
Actor isolation for services
Thread-safe by construction, no manual locking
@concurrent for CPU work
Swift 6.2 Approachable Concurrency, explicit background opt-in
SpeechAnalyzer over SFSpeechRecognizer
iOS 26 API, modular, offline-first, Swift Concurrency native
Relevance decay (14-day half-life)
Prevents stale context from dominating retrieval
Retrieval strategy parameterized
Enables clean eval comparison against identical data
Superseded-node links
Makes "topically near but wrong" a first-class retrieval case rather than an eval afterthought
Extraction confidence scoring
Enables escalation to Claude for low-confidence extractions; also drives UI dimming
Provider protocol abstraction
Swap providers, enables offline fallback and deterministic testing
Raw String storage for enums
#Predicate and #Index only work with primitive types
Declarative, agent's call: view composition, animation timing, internal helper structure, naming below the type level, test organization. Standing clause for every session: if you find a design that better achieves the contract than the one specified, raise it as an option before implementing it.
Agent Harness Setup (Day 0, ~90 minutes)
Do this before touching the compilation errors. Nothing here is a third-party dependency.
1. Wire Claude Code to Xcode
Since Xcode 26.3, Apple ships an MCP server that bridges an external agent into a running Xcode process: builds, tests, real-time diagnostics, documentation search, Swift REPL, and SwiftUI previews.
claude mcp add --scope user --transport stdio xcode -- xcrun mcpbridge
claude mcp list   # verify: xcode - Connected
​
Requirements and gotchas:
Xcode 26.3 or later.
Enable the MCP server inside Xcode settings before an external agent can connect.
Xcode must be running with the project open. Xcode shows an indicator while an external tool is connected.
Expect a permission dialog on new connections.
Do not install XcodeBuildMCP or any other Xcode MCP server yet. 82 tools versus Apple's 20 is context bloat with heavy overlap. Add one only if you hit a specific wall Apple's server can't clear.
2. The files
CLAUDE.md at repo root, under 30 lines. An index, not a manual.
# Thread

iOS 26, Swift 6.2, SwiftData. Scheme: Thread. Test target: ThreadTests.
Simulator: iPhone 17 Pro. Build and test through the `xcode` MCP tools.

## Routing
- Before writing SwiftData code: read `rules/swiftdata.md`. Non-negotiable.
- Before using any iOS 26 framework (FoundationModels, SpeechAnalyzer,
  NLContextualEmbedding): read `rules/ios26-apis.md`, then verify against
  Apple documentation. Do not recall these APIs from memory.
- Before touching `Eval/`: read `rules/evals.md`.
- Before reviewing a diff: read `rules/verify.md`.
- Before changing architecture: read `DECISIONS.md`. Those are locked.

## Task completion
A task is done only when the active `CONTRACT_*.md` is satisfied.
Never edit a test to make it pass. If the contract is ambiguous, stop and ask.

## Reporting
Report all findings, including "no issues found."
Never manufacture a finding to satisfy a request.

## After compaction or /clear
Re-read this file, the active contract, and the files the contract names
before continuing.
​
DECISIONS.md — the Technical Decisions table above, verbatim, plus the declarative clause.
rules/swiftdata.md — the SwiftData Constraints section below, verbatim. This is the single highest-value file in the project. Six hard-won constraints that an agent will otherwise violate repeatedly, every session.
rules/ios26-apis.md — generated once, on Day 0, and this is the step that saves the most wasted iterations. Models trained before mid-2026 do not know the real surface of FoundationModels, SpeechAnalyzer, or @Generable, and they will invent plausible signatures. Have the agent:
Run xcrun --show-sdk-path --sdk iphoneos.
Read the .swiftinterface files under each framework's .swiftmodule directory for FoundationModels, Speech, and NaturalLanguage.
Write the real initializers, types, and method signatures you actually use into rules/ios26-apis.md, with the SDK version noted at the top.
rules/evals.md — the integrity rules that make the headline number defensible:
All 30 queries, all relevant_node_ids, and all irrelevant_but_tempting sets are authored by the human. The agent must never generate or modify them. If the agent labels the eval, it grades its own homework and the first interview question destroys the claim.
Never write the eval runner and the retrieval strategy in the same session.
Any change to decay half-life, top-K, or scoring re-runs the full three-strategy comparison and reports deltas.
rules/verify.md — the rubric for every fresh-context review. Score 0–5, cite specific lines, separate blocking issues from suggestions:
Spec fidelity — does this achieve the active contract? (Must score 4+.)
Correctness and edge cases.
Test quality — would these tests fail if the behavior broke?
Concurrency and actor isolation safety.
Scope discipline — no drive-by edits outside the contract.
CONTRACT.template.md, copied per task:
# CONTRACT: <task name>

## Done means
- [ ] <specific, checkable outcome>
- [ ] Project builds clean for iPhone 17 Pro simulator
- [ ] ThreadTests passes, N tests, none edited to pass
- [ ] <screenshot or recording condition, where behavior is visual>

## Files in scope
<paths>

## Out of scope
<paths and behaviors the agent must not touch>

## Verification
Fresh session, `rules/verify.md` rubric. Spec fidelity must score 4+.
​
Write CONTRACT_core_loop.md and CONTRACT_eval.md on Day 0, before either is built.
3. Which surface for what
Work
Tool
Models, ContextEngine, eval runner, tests, git, README, blog post
Claude Code CLI, bridged to Xcode
Days 5–6 UI and the debug inspector
Xcode's Claude Agent panel — preview capture and iteration is native there, and 26.6 added light/dark and type-size variant rendering to the preview tool
Breakpoints, Instruments, actor isolation bugs, Days 7–8 voice
You, in Xcode, no agent. Live mic behavior and permissions are not agent-verifiable
Never have both agents editing simultaneously. Keep Xcode open for building and previewing, edit from the CLI, let Xcode pick up disk changes.
4. The working loop
Research and implementation never share a context. Plan mode, write the plan to a file, /clear, implement from the plan.
Verify in a fresh session against rules/verify.md. Same-context self-review produces shallow agreement.
Neutral prompts. "Trace the logic of each component and report all findings," not "find the bug."
Never mention Ledger, EOB, or Voice Bridge while building Thread.
Monthly: have the agent read every file in rules/, list contradictions and dead rules, and ask you what to keep.
Data Models (SwiftData)
Workstream
The primary organizational unit. A project, a decision, an open question.
id: UUID
title: String
summary: String
status: String (raw value of WorkstreamStatus)
isPinned: Bool
createdAt: Date
updatedAt: Date
compactContext: String (Foundation Models generated, injected into API calls)
tags: [String]
messages: [Message] (cascade delete, inverse)
contextNodes: [ContextNode] (cascade delete, inverse)
Message
id: UUID
role: MessageRole (user / assistant / system)
content: String
createdAt: Date
contentBlocksData: Data? (JSON-encoded structured blocks)
isEmbedded: Bool
estimatedTokens: Int (~4 chars per token)
workstream: Workstream?
ContextNode
The atoms of the knowledge graph.
id: UUID
content: String
nodeType: ContextNodeType (fact / decision / openQuestion / reference / actionItem / insight)
createdAt: Date
lastAccessedAt: Date
embeddingData: Data? (512 doubles as raw bytes, 4KB per node)
relevanceScore: Double (14-day half-life decay)
sourceMessageID: UUID?
supersededByID: UUID? — set when a later node replaces this one. Superseded nodes are down-weighted in retrieval and dimmed in the Context tab. This is the schema-level version of "the decision changed," and it is what makes the eval's tempting-but-wrong cases principled.
extractionConfidence: Double — Foundation Models confidence for this extraction. Below threshold, escalate the extraction to Claude. Cheap to store, and it is the honest answer to "what happens when the 3B model gets it wrong."
workstream: Workstream?
ProactiveSurfacing
Retained in the schema, not built as a feature in this cycle.
id: UUID
content: String
triggerReason: String
createdAt: Date
wasEngaged: Bool
relatedWorkstreamID: UUID?
Core Files (already built)
/Models
SwiftDataModels.swift — four @Model classes with #Unique, #Index, and relationships. Enums stored as raw Strings.
/Core
ContextEngine.swift — EmbeddingService (NLContextualEmbedding wrapper with vDSP cosine similarity) and ContextRetrievalEngine (payload assembly, token budgeting, relevance decay). Retrieval is parameterized by strategy so the eval runner can swap configs against identical data.
OnDeviceIntelligence.swift — Foundation Models integration with four @Generable types (ExtractedContext, WorkstreamSummary, ProactiveAnalysis, ContentTags). Separate LanguageModelSession per task type.
LLMProvider.swift — LLMStreamingProvider protocol, ClaudeSSEProvider, OnDeviceFallbackProvider, LLMProviderFactory.
ThreadOrchestrator.swift — coordinates the full message lifecycle through a single send() entry point.
/App
ThreadApp.swift — @main, ModelContainer configuration, API key management.
/Features
WorkstreamListView.swift — home screen, workstreams sorted by pinned and recency, in-memory filtering.
ConversationView.swift — chat interface, streaming token display, provider indicator, retry on error.
/ (harness, Day 0)
CLAUDE.md, DECISIONS.md, CONTRACT.template.md, CONTRACT_core_loop.md, CONTRACT_eval.md
rules/swiftdata.md, rules/ios26-apis.md, rules/evals.md, rules/verify.md
Message Lifecycle
Save user message to SwiftData
Embed user message (background, non-blocking)
Retrieve relevant context via cosine similarity against stored node embeddings
Build conversation history within token budget (walk backwards until limit)
Assemble context payload as system prompt (workstream summary plus relevant nodes)
Stream LLM response (primary provider, automatic fallback on failure)
Save assistant message
Extract context nodes via Foundation Models (background)
Score extraction confidence; escalate to Claude below threshold
Mark superseded nodes where a new decision replaces an earlier one
Embed new context nodes
Update workstream summary every 10 messages
The Eval Layer
This is the differentiator and it runs early, not last. It depends only on ContextEngine and a bundled node set, so it does not wait on voice, UI, or the orchestrator.
Cap the labeled set at 30 queries. If a clean comparison is not producing by end of the allotted day, ship the partial result and write it up honestly. This task expands to fill available time. Do not let it.
Labeling integrity, non-negotiable. You author every query, every relevant_node_ids set, and especially every irrelevant_but_tempting set. Budget roughly two hours. If the agent writes the labels, the tempting-node cases will be exactly the ones its own strategy already handles, the eval measures nothing, and the first question any interviewer asks about a self-built eval is who labeled it. Enforced by rules/evals.md.
1. Labeled retrieval set (Eval/RetrievalSet.swift or bundled JSON)
A fixed graph of ~40 context nodes for one synthetic workstream: facts established, decisions made, open questions, action items, and some deliberately stale or superseded. Then 25 to 30 labeled queries.
{
  "query": "what did we decide about the auth migration",
  "relevant_node_ids": ["node_12", "node_23"],
  "irrelevant_but_tempting": ["node_08"]
}
​
irrelevant_but_tempting is what makes this an eval rather than a smoke test: nodes that are topically adjacent but wrong. A superseded decision, a resolved question, a stale fact. Recency-only fails here. Decay-weighted semantic retrieval should win, and the supersededByID field is what lets it.
Because the node set is hand-labeled and synthetic, the eval measures retrieval in isolation and is not contaminated by extraction quality. That separation is deliberate and worth stating in the write-up.
2. Eval runner (Eval/RetrievalEval.swift)
Built in a session that has never seen the retrieval strategy implementation. Runs each query through three configs against the identical node set, scoring precision@5 and recall@5:
semantic-only — cosine similarity, no decay
recency-only — most recent nodes, no semantic ranking (the baseline)
decay-weighted semantic — cosine multiplied by relevance decay (the actual strategy)
Output is a three-by-two table. The sentence you want to be able to say: decay-weighted semantic retrieval improved precision@5 by X% over recency-only and Y% over semantic-only on a 30-query labeled set. That sentence is worth more than any three architecture bullets.
Prefer an XCTest case over a debug-menu action; it shows up as a test, runs in CI, and gives CONTRACT_eval.md a deterministic done-condition. Fall back to a debug-menu runner only if the SwiftData test harness fights you.
3. Extraction spot-check (optional)
Ten sample messages through Foundation Models extraction, scored against a hand-labeled gold set. This is a breadth signal, not the headline. It does not gate the retrieval eval's validity, but extraction quality does gate the demo, so run it as a sanity check before recording. Cut it entirely before touching the retrieval eval.
SwiftData Constraints
Hard-won. Apply everywhere. This section is rules/swiftdata.md — keep the two in sync, or better, keep only the file and link to it here.
#Predicate only works with primitive stored types (String, Int, Bool, Date, UUID, Double). Never use enums directly. Filter in memory.
#Index can appear only once per @Model. Only primitive keypaths. No relationship or enum keypaths.
@Query SortDescriptor fails with Bool. Sort in a computed property.
Enum properties used in predicates must be stored as raw Strings with computed typed accessors.
NLContextualEmbedding uses init(script:) or init(language:), not static factory methods.
@MainActor classes cannot reference isolated properties in deinit. Use explicit cleanup methods.
UI Direction
Dark mode default, high contrast, minimal color outside semantic indicators. Voice is the primary input and the capture bar is the dominant element. The screen is for reviewing and browsing, not typing prompts. Information-dense. A professional instrument, not a wellness app.
Color system
Background #0F0F0F, surface #1A1A1A, elevated #242424
Text primary white 90%, secondary white 50%
Accent #4A9EFF
Facts #4A9EFF, Decisions #FFB84D, Open Questions #FF6B6B, Action Items #4ADE80
Superseded nodes render at 30% opacity with a strikethrough rule
Screen 1: Home
Voice capture bar at top (full-width, hold to record, live waveform and transcript). Workstream cards below (title, summary, node count, tags, latest node). Empty state: centered mic, "Hold to capture your first thought."
Screen 2: Workstream Detail, three tabs
Stream — conversation flow. User input plain, AI responses with a blue left border, inline cards for extracted context.
Context — knowledge graph. Nodes grouped by type with semantic color borders, relevance scores visible, decayed and superseded nodes dimmed.
Insights — proactive feed. Stubbed this cycle.
Voice capture bar
Large mic icon in a rounded rectangle. Long press to record, release to send. Waveform plus live transcript while recording. Medium haptic on start, light on stop. .glassEffect(.regular.interactive).
Debug inspector
Long-press any AI response to reveal the assembled system prompt and the live retrieval scores that produced it. This makes the intelligence layer legible and is the single most persuasive thing in the demo.
Build Plan (Day 0 + 12 days)
The change from the previous plan: the eval moves to days 3-4. It is the differentiator and it has the fewest dependencies in the project, so it should not sit behind voice and UI, which are the components most likely to slip.
Day 0: Harness. The Agent Harness Setup section in full. xcrun mcpbridge wired and verified, CLAUDE.md, DECISIONS.md, four rules files (including the generated rules/ios26-apis.md), and both contracts written before either is built. No feature code today.
Days 1-2: Core loop. Clear remaining compilation errors against CONTRACT_core_loop.md. Verify end to end: send message, Claude responds, nodes extracted, follow-up retrieves context, response shows awareness. Screen-record it the moment it works. That recording is the insurance demo and everything else is polish.
Days 3-4: Retrieval eval. You hand-label ~30 queries first, in your own session, before any agent work. Then the runner, in a fresh context. Precision@5 and recall@5 across the three strategies. Produce the comparison table. Protect these two days above everything else in the schedule.
Days 5-6: UI and debug inspector. Dark theme, voice-first layout, Context tab with semantic colors and dimming. Work in Xcode's agent panel here so preview capture is native. Build the inspector in this window so it survives a slip.
Days 7-8: Voice. AudioStreamManager with SpeechAnalyzer. Wire the capture bar to the orchestrator. Manual verification, not agentic. Fall back to SFSpeechRecognizer without hesitation if SpeechAnalyzer costs more than half a day.
Days 9-10: Polish. Liquid Glass on the capture bar and tab selector. Haptics. Spring animations for streaming and node appearance. Optional extraction spot-check if there is room.
Days 11-12: Ship. Blog post. Ninety-second demo video with voiceover, including a beat on the debug inspector and one on the eval table. Push to GitHub. Update resume.
Do not build
Intelligent voice routing (future work in the post)
Proactive surfacing and Live Activities (future work)
App Intents, Share Sheet, Spotlight (future work)
Markdown vault and export
Corpus-wide reprocessing
Contradiction detection as a user-facing feature; it exists here only as supersededByID
App icon and launch screen
Nightly distillation jobs (not possible on iOS, already handled by relevance decay)
Voice Bridge / healthcare telephony
Any agent tooling beyond the Day 0 harness. No third-party MCP servers, memory layers, or skill packs.
Blog Post
Title: How I Measured Whether My AI's Memory Actually Works (and Built It on iOS)
Opening: Every AI conversation starts from zero. You explain your context, the AI answers, the session ends, and next time you start over. Thread fixes that on iOS with a local knowledge graph and on-device retrieval. But building a memory system is the easy part. The part almost nobody does is proving the memory surfaces the right thing. So I built a labeled eval set and measured it: decay-weighted semantic retrieval against recency-only and semantic-only baselines. Here is what the numbers said and the architecture that produced them.
Structure
The problem. Why AI conversations forget, and why the naive fixes (dump all history, or rank by recency) fail.
The three-layer solution. On-device embeddings for retrieval, on-device LLM for extraction, Claude for reasoning.
The eval. How retrieval quality was measured, the three strategies compared, the results table, why the labeled node set is synthetic (so the eval measures retrieval rather than extraction), and who labeled it. Lead the technical substance here.
The iOS engineering. SwiftData constraints, actor isolation, concurrency decisions, token budgeting.
What is next. Proactive surfacing, App Intents, and where the architecture generalizes. One closing paragraph on context continuity as a patient-safety problem in healthcare, kept as a coda rather than the frame.
Deliverables

Day 0 harness: mcpbridge connected, CLAUDE.md, DECISIONS.md, four rules files, two contracts

Core loop working: voice in, context retrieved, response shows awareness

Screen recording of the context continuity demo

Retrieval eval: ~30 human-labeled queries, precision@5 and recall@5, three-strategy table

Debug inspector showing system prompt and retrieval scores

Dark mode voice-first UI

Context tab with semantic colors, decay dimming, superseded rendering

Voice capture via SpeechAnalyzer (or SFSpeechRecognizer fallback)

Optional: extraction spot-check

Blog post, leading with the eval

Ninety-second demo video with voiceover

Code on GitHub

Resume updated
Links
GitHub: TODO
Blog post: TODO
Demo video: TODO
