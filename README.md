# Thread

**An iOS app where you talk and the AI remembers.**

Hold a button, speak a thought, release. Thread transcribes it, classifies it, routes it to the right workstream, and builds a local knowledge graph from everything you've said. On your next message, it retrieves the relevant pieces of that graph via on-device vector search and injects them into the LLM call — so the AI shows up already knowing the context, instead of starting from zero.

Three intelligence layers, most of them free and offline:

| Layer | Framework | Job |
|---|---|---|
| Retrieval | `NLContextualEmbedding` (Apple, on-device) | Semantic search over the knowledge graph |
| Extraction | Foundation Models (Apple, on-device, iOS 26) | Classification, structured extraction, summarization |
| Reasoning | Claude API | The one call that leaves the device |

The claim this project makes: **building a memory system is the easy part. Proving the memory retrieves the right thing is the part almost nobody does.** Thread ships with a hand-labeled retrieval eval that scores decay-weighted semantic retrieval against two baselines on identical data — that eval is in progress now (see below).

---

## Status

This is a portfolio project built in daily increments against written contracts, each independently tested and verified in a fresh review pass before moving on. Here's where it actually stands:

**Built and tested**
- ✅ **SwiftData schema** — `Workstream`, `Message`, `ContextNode`, `ProactiveSurfacing`, with `#Unique`/`#Index` macros, cascade-delete relationships, and enums stored as raw `String` (required for `#Predicate` compatibility). 7 tests.
- ✅ **`ContextEngine`** — `EmbeddingService` (actor wrapping `NLContextualEmbedding`, mean-pooled + L2-normalized 512-dim vectors, vDSP cosine similarity) and `ContextRetrievalEngine` (semantic / recency / decay-weighted retrieval, all three swappable via one config parameter, not three code paths). 7 tests, plus a documented, non-mocked simulator limitation on one (see [Known limitations](#known-limitations)).

**In progress**
- 🚧 **Retrieval eval** — hand-labeling ~30 queries against a synthetic 40-node graph now, before any eval-runner code gets written. The runner will be built in a session that has never seen the retrieval strategy's implementation, on purpose (see [How this was built](#how-this-was-built)).

**Not started**
- ⬜ Core message loop (send → retrieve → stream → extract → store)
- ⬜ Voice capture (`SpeechAnalyzer`)
- ⬜ UI — dark, voice-first, with a debug inspector that surfaces the assembled prompt and live retrieval scores
- ⬜ Claude API streaming provider + on-device fallback

The full day-by-day plan is in [`SPEC.md`](./SPEC.md).

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

**Retrieval** — Apple's BERT-based 512-dim sentence embeddings, mean-pooled from subword token vectors and L2-normalized, compared via Accelerate/vDSP cosine similarity. Fully on-device, zero inference cost.

**Extraction** — a ~3B parameter on-device model via Foundation Models, producing structured `@Generable` output (facts, decisions, action items, open questions) and workstream summaries.

**Reasoning** — the only call that touches the network. Receives a token-budgeted context payload (workstream summary + top-K relevant nodes + recent messages) rather than a full history dump, streamed via SSE, with automatic fallback to on-device generation if the network is unavailable.

---

## Engineering decisions

These were made deliberately and locked before implementation, not discovered along the way:

| Decision | Rationale |
|---|---|
| SwiftData over Core Data | Declarative API, `#Unique`/`#Index` macros, iOS 26 native |
| `NLContextualEmbedding` over an external vector DB | On-device, no network dependency, free, sufficient for a local corpus |
| Foundation Models for extraction | Zero cost, offline, fast enough for background processing |
| Actor isolation for services | Thread-safe by construction, no manual locking |
| `@concurrent` for CPU work | Swift 6.2 Approachable Concurrency, explicit background opt-in |
| Relevance decay, 14-day half-life | Prevents stale context from dominating retrieval |
| Retrieval strategy parameterized, not hardcoded | Enables a clean eval comparison against identical data |
| Superseded-node links (`supersededByID`) | Makes "topically near but wrong" a first-class retrieval case instead of an eval afterthought |
| Extraction confidence scoring | Enables escalation to Claude on low-confidence extractions; drives UI dimming |
| Raw `String` storage for enums | `#Predicate` and `#Index` only work with primitive stored types |

Full list, with the standing clause that governs anything not on it, in [`.claude/rules/DECISIONS.md`](./.claude/rules/DECISIONS.md).

---

## The eval (in progress)

This is the part of the project the write-up will lead with. A fixed graph of ~40 hand-authored context nodes — facts, decisions, open questions, action items, and some deliberately stale or superseded — paired with 25–30 labeled queries, each carrying a `relevant_node_ids` set and an `irrelevant_but_tempting` set (topically adjacent nodes that are wrong: a superseded decision, a resolved question, a stale fact).

Once labeled, a runner scores precision@5 and recall@5 across three retrieval strategies on identical data:

- **semantic-only** — cosine similarity, no decay
- **recency-only** — most recent nodes, no semantic ranking (baseline)
- **decay-weighted semantic** — cosine × relevance decay (the actual strategy)

Two rules keep the result honest: every query and every label is hand-authored — an agent never generates or grades its own eval data — and the eval runner is written in a session that has never seen the retrieval strategy's implementation, so it can't accidentally get tuned to match. Both are enforced in [`.claude/rules/evals.md`](./.claude/rules/evals.md).

---

## How this was built

Built with Claude Code driving an agentic workflow against Xcode's official MCP bridge (`xcrun mcpbridge`), under a small set of enforced constraints:

- **Contract-driven.** Every unit of work starts as a `CONTRACT_*.md` — specific, checkable "done means" criteria, explicit files-in-scope, explicit out-of-scope — written before implementation begins.
- **Fresh-session verification.** Every contract is reviewed against [`.claude/rules/verify.md`](./.claude/rules/verify.md) in a session that didn't write the code, scored 0–5 across spec fidelity, correctness, test quality, concurrency safety, and scope discipline. Same-context self-review produces shallow agreement, so it isn't allowed.
- **No API guessing.** iOS 26 frameworks (`NLContextualEmbedding`, Foundation Models, `SpeechAnalyzer`) are new enough that models trained before mid-2026 confidently invent plausible-but-wrong signatures. Real signatures are pulled from Apple's own documentation and the SDK's `.swiftinterface` files before being used, and logged to [`.claude/rules/ios26-apis.md`](./.claude/rules/ios26-apis.md) so they're verified once, not re-guessed every session.
- **Locked architecture decisions.** The table above lives in a rules file an agent reads automatically every session and cannot silently "improve."
- **Eval integrity.** Covered above — never self-labeled, never self-graded.

The point isn't that an agent wrote the code. It's that the code is held to the same bar an engineer would hold a teammate to: a spec, a diff, an independent review, and a test suite that would actually fail if the behavior broke.

---

## Known limitations

- One `ContextEngine` test (`embeddedStringProduces512NormalizedDimensions`) reproducibly fails on the iPhone 17 Pro Simulator with `NLNaturalLanguageErrorDomain Code=7 "E5 model compilation failed"` — the simulator failing to compile Apple's on-device embedding model, not a defect in the wrapper code. This was a flagged risk before implementation started, not a surprise discovered after. The test exercises the real framework rather than a mock, on purpose, and stays that way; it should be re-checked on a physical device.

---

## Tech stack

Swift 6 (strict concurrency) · SwiftData · SwiftUI · `NLContextualEmbedding` · Foundation Models · Accelerate/vDSP · `SpeechAnalyzer` (planned) · Claude API (SSE streaming) · Swift Testing

## Building

Requires Xcode 26.3+, iOS 26.4 SDK, an iPhone 17 Pro simulator (or compatible device).

```
open Threads.xcodeproj
# Scheme: Threads · Test target: ThreadsTests
```

Build and test via Xcode directly, or through the `xcode` MCP tool surface if you have Claude Code wired up the same way this project was built.
