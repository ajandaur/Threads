# Thread

**An iOS app where you talk and the AI remembers.**

Hold a button, speak a thought, release. Thread transcribes it, classifies it, routes it to the right workstream, and builds a local knowledge graph. On your next message it retrieves the relevant pieces via on-device vector search and injects them into the LLM call — so the AI shows up already knowing the context.

| Layer | Framework | Job |
|---|---|---|
| Retrieval | `NLContextualEmbedding` (on-device) | Semantic search over the knowledge graph |
| Extraction | Foundation Models (on-device, iOS 26) | Classification, structured extraction, summarization |
| Reasoning | Claude API | The one call that leaves the device |

The claim: **building a memory system is the easy part. Proving it retrieves the right thing is the part almost nobody does.** Thread ships a hand-labeled retrieval eval — and that eval currently says the strategy this project was built around **loses to plain semantic search**. See [The eval](#the-eval).

---

## Demo

_A recording of the current build: type a message, watch it round-trip through retrieval, Foundation Models, and Claude, and land back in the thread._

[Demo.mov.zip](https://github.com/user-attachments/files/31604892/Demo.mov.zip)

---

## Status

Portfolio project, built in daily increments against written contracts, each verified in a fresh review session.

**Built and tested**
- ✅ **SwiftData schema** — `Workstream`, `Message`, `ContextNode`, `ProactiveSurfacing`, with cascade-delete relationships and enums stored as raw `String` for `#Predicate` compatibility. 7 tests.
- ✅ **`ContextEngine`** — `EmbeddingService` (actor over `NLContextualEmbedding`, 512-dim, mean-pooled, L2-normalized) and `ContextRetrievalEngine` (three strategies behind one config parameter, not three code paths). 7 tests.
- ✅ **Retrieval eval** — 36 hand-labeled nodes, 30 hand-labeled queries, three strategies, comparison table regenerated on every run. 7 tests.
- ✅ **`LLMProvider`** — Claude over SSE streaming, with on-device (Foundation Models) fallback and provider failover. 44 tests.
- ✅ **`OnDeviceIntelligence`** — on-device extraction, summarization, and tagging via Foundation Models, actor-isolated with per-task locking. 40 tests.
- ✅ **`ThreadOrchestrator`** — the full `send()` lifecycle: save → embed → retrieve → stream → persist, then background extraction, escalation, and summary. 22 tests.
- ✅ **Minimal chat UI** — `ThreadOrchestrator` wired into the app; a scrolling thread view and a send box, enough to exercise the whole loop end to end on device. Unstyled by design — the real UI pass hasn't started (see [`rules/ui.md`](./.claude/rules/ui.md)).

**Open**
- 🚧 `decay-weighted semantic` collapses onto the recency baseline. A real finding, not a test defect — the fix belongs in `ContextEngine`'s scoring, not the eval.

**Not started**
- ⬜ Voice capture (`SpeechAnalyzer`)
- ⬜ Real UI pass — dark, voice-first, node-type colors, debug inspector for retrieval scores

Day-by-day plan in [`SPEC.md`](./SPEC.md).

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

**Retrieval** — 512-dim sentence embeddings, mean-pooled from subword vectors and L2-normalized, cosine similarity via Accelerate/vDSP. On-device, zero inference cost.

**Extraction** — on-device model via Foundation Models, producing structured `@Generable` output and workstream summaries.

**Reasoning** — the only call that touches the network. Receives a token-budgeted payload (summary + top-K nodes + recent messages) rather than a full history dump, with on-device fallback when offline.

---

## Engineering decisions

Made deliberately and locked before implementation, not discovered along the way:

| Decision | Rationale |
|---|---|
| SwiftData over Core Data | Declarative API, `#Unique`/`#Index` macros, iOS 26 native |
| `NLContextualEmbedding` over an external vector DB | On-device, no network dependency, free |
| Foundation Models for extraction | Zero cost, offline, fast enough for background work |
| Actor isolation for services | Thread-safe by construction, no manual locking |
| Relevance decay, 14-day half-life | Prevents stale context from dominating retrieval |
| Retrieval strategy parameterized, not hardcoded | Enables a clean eval comparison on identical data |
| Superseded-node links (`supersededByID`) | Makes "topically near but wrong" a first-class retrieval case |
| Raw `String` storage for enums | `#Predicate` and `#Index` only work with primitive stored types |

Full list in [`.claude/rules/DECISIONS.md`](./.claude/rules/DECISIONS.md).

---

## The eval

36 hand-authored nodes (facts, decisions, open questions, action items, including six supersession pairs where a later node replaces an earlier one) and 30 labeled queries, each carrying a `relevant_node_ids` set and an `irrelevant_but_tempting` set — topically adjacent nodes that are wrong.

| Strategy | Precision@5 | Recall@5 | Tempting node in top-5 |
|---|---|---|---|
| semantic-only | **0.1200** | **0.6000** | 0.3667 |
| recency-only | 0.0333 | 0.1667 | 0.2000 |
| decay-weighted semantic | 0.0333 | 0.1667 | 0.2000 |

**Decay-weighted semantic ties the recency baseline exactly and loses to plain semantic search by 3.6×.** Not a coincidence of averages — the two return an identical top-5 on 30 of 30 queries.

Likely cause: semantic similarity on this corpus sits in a band about 0.005 wide, while the decay factor ranges over an order of magnitude. Multiplying a near-constant term by a wildly variable one lets the variable term decide the ranking outright.

Nothing was tuned in response. The corpus and the assertions are frozen, and the test stays red until `ContextEngine`'s scoring is fixed.

Two limits worth naming: the five "historical" queries score 0.0000 for every strategy, so that assertion currently passes as `0 ≥ 0`; and the eval can't yet distinguish "decay helps" from "decay stopped participating."

Integrity rules, enforced in [`.claude/rules/evals.md`](./.claude/rules/evals.md): every label is hand-authored, and the runner was written in a session that had never seen the retrieval implementation, so it can't be tuned to match. Numbers regenerate from scratch each run — two runs verified bit-identical.

---

## How this was built

Claude Code driving an agentic workflow against Xcode's MCP bridge, under enforced constraints:

- **Contract-driven.** Every unit of work starts as a `CONTRACT_*.md` with checkable "done means" criteria and explicit files-in-scope, written before implementation.
- **Fresh-session verification.** Code is reviewed against [`.claude/rules/verify.md`](./.claude/rules/verify.md) by a session that didn't write it, scored across spec fidelity, correctness, test quality, concurrency safety, and scope discipline. Same-context self-review produces shallow agreement.
- **No API guessing.** iOS 26 signatures are pulled from the SDK's `.swiftinterface` files and logged to [`.claude/rules/ios26-apis.md`](./.claude/rules/ios26-apis.md), verified once rather than re-guessed every session.
- **Locked decisions.** The table above lives in a rules file an agent reads every session and cannot silently "improve."
- **Eval integrity.** Never self-labeled, never self-graded.

The point isn't that an agent wrote the code. It's that the code is held to the bar you'd hold a teammate to: a spec, a diff, an independent review, and tests that fail when the behavior breaks.

---

## Known limitations

`NLContextualEmbedding` cannot compile its model on the simulator (`NLNaturalLanguageErrorDomain Code=7 "E5 model compilation failed"`), so the four tests needing a real embedding fail there and pass on a physical iPhone 17 Pro. There's no simulator fallback — iOS 26.5 is the only runtime above the project's 26.4 deployment target. **Run the suite on a device.** These tests exercise the real framework rather than a mock, on purpose, and stay that way. `ThreadOrchestrator` degrades gracefully when this happens — a failed embed becomes an empty vector rather than a failed send — so the app still functions on the simulator with degraded retrieval.

`ThreadOrchestrator` creates its `ModelContext` during `init()`, which currently runs on the main thread, but the actor's own methods then touch that context from a background executor — SwiftData logs `ModelContext: Unbinding from the main queue... consider using a ModelActor` at runtime. Observed live, not yet fixed; the correct shape is likely `ThreadOrchestrator` as a `ModelActor` rather than a plain `actor` holding a `ModelContext`.

---

## Tech stack

Swift 6 (strict concurrency) · SwiftData · SwiftUI · `NLContextualEmbedding` · Foundation Models · Accelerate/vDSP · `SpeechAnalyzer` (planned) · Claude API (SSE streaming) · Swift Testing

## Building

Requires Xcode 26.3+, iOS 26.4 SDK, and an iPhone 17 Pro.

```
open Threads.xcodeproj
# Scheme: Threads · Test target: ThreadsTests
```

Run the full suite on a device — see [Known limitations](#known-limitations).
