//
//  ThreadOrchestrator.swift
//  Threads
//
//  Layer 4: the message lifecycle. `ContextEngine`, `OnDeviceIntelligence`,
//  and `LLMProvider` are each self-contained and model-free; this file is the
//  one place that owns a `ModelContext` and calls all three in sequence
//  through a single `send()` entry point.
//
//  ## Why an actor with its own `ModelContext`
//
//  `EmbeddingService`, `OnDeviceIntelligence`, and `LLMProviderFactory` are
//  all actors — this follows the same "actor isolation for services"
//  decision, and being a plain actor (rather than `@MainActor`) means the
//  work genuinely runs off the main thread, which is what "background,
//  non-blocking" in the contract asks for rather than merely interleaving
//  with UI work on the same queue.
//
//  A `ModelContext` is confined to a single execution context, so this actor
//  creates its own from the shared `ModelContainer` rather than reusing the
//  UI's `@Environment(\.modelContext)` one. The two never touch each other,
//  and no `@Model` object fetched here crosses back out through an `await` —
//  only `Sendable` value types (`LLMStreamChunk`, `UUID`, `CalibratedExtraction`)
//  cross that boundary. A caller that wants the persisted `Message` or
//  `Workstream` re-fetches it through its own context, the same as any other
//  multi-context SwiftData setup.
//

import Foundation
import SwiftData

// MARK: - Errors

nonisolated enum ThreadOrchestratorError: Error, Equatable, LocalizedError {
    case workstreamNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .workstreamNotFound(let id):
            return "No workstream found with id \(id)."
        }
    }
}

// MARK: - Pure prompt/formatting logic
//
// Split out from the actor for the same reason `IntelligencePrompts` is split
// from `OnDeviceIntelligence`: this is where wiring bugs live (wrong message
// order, a summary trigger that fires every message instead of every tenth),
// and it is testable without a `ModelContainer`, a network, or a model.

nonisolated enum OrchestrationPrompts {

    /// ~4 characters per token, matching `Message.estimatedTokens`'s
    /// documented heuristic and `ContextRetrievalEngine`'s own estimate.
    static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    /// Step 5: workstream summary plus relevant nodes, and nothing else.
    /// `recentMessages` becomes `LLMRequest.messages` instead (see
    /// `llmMessages(from:)`), so conversation history is never duplicated
    /// into the system prompt.
    static func systemPrompt(for payload: ContextPayload) -> String {
        var sections: [String] = []

        let summary = payload.workstreamSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            sections.append("Workstream summary:\n\(summary)")
        }

        if !payload.relevantNodes.isEmpty {
            let nodes = payload.relevantNodes
                .map { node -> String in
                    let marker = node.isSuperseded ? " (superseded)" : ""
                    return "- [\(node.nodeType)\(marker)] \(node.content)"
                }
                .joined(separator: "\n")
            sections.append("Relevant context:\n\(nodes)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// `payload.recentMessages` arrives newest first (see
    /// `ContextRetrievalEngine.assemblePayload`); `LLMRequest.messages` wants
    /// the opposite — oldest first, ending with the current turn. System
    /// messages have no `LLMRole` counterpart and are dropped rather than
    /// mapped onto either side of the conversation.
    static func llmMessages(from snapshots: [MessageSnapshot]) -> [LLMMessage] {
        snapshots.reversed().compactMap { snapshot in
            switch snapshot.role {
            case MessageRole.user.rawValue:
                return LLMMessage(role: .user, content: snapshot.content)
            case MessageRole.assistant.rawValue:
                return LLMMessage(role: .assistant, content: snapshot.content)
            default:
                return nil
            }
        }
    }

    /// Step 12's gate. A standalone predicate rather than logic buried in
    /// the actor, so "every tenth message, not every message" is checkable
    /// without a `ModelContainer` or a working on-device model.
    static func isSummaryDue(messageCount: Int, interval: Int) -> Bool {
        messageCount > 0 && interval > 0 && messageCount % interval == 0
    }
}

// MARK: - Escalation
//
// Step 9. A `CalibratedExtraction` below `ExtractionConfidencePolicy.threshold`
// does not get stored as a fact the 3B model wasn't sure about. Instead the
// original exchange plus every shaky item goes back out to Claude in one
// batched call, and Claude's answer replaces the low-confidence content
// outright rather than being blended with it.

nonisolated enum EscalationPromptBuilder {
    static let omitMarker = "OMIT"

    static func request(for items: [CalibratedExtraction], exchange: ConversationExchange) -> LLMRequest {
        let systemPrompt = """
        You are verifying low-confidence extracted context from a conversation. \
        For each numbered item below, decide whether it is an accurate, \
        self-contained piece of context worth remembering. Respond with exactly \
        one line per item, in the same order, and nothing else: either a \
        corrected one-sentence version of the item, or the single word \
        \(omitMarker) if it is not worth keeping.
        """
        let numbered = items.enumerated()
            .map { index, item in "\(index + 1). [\(item.nodeType)] \(item.content)" }
            .joined(separator: "\n")
        let userContent = """
        User: \(exchange.userMessage)
        Assistant: \(exchange.assistantMessage)

        Items to verify:
        \(numbered)
        """
        return LLMRequest(systemPrompt: systemPrompt, messages: [LLMMessage(role: .user, content: userContent)])
    }

    /// Positional: line *n* answers item *n*. A short or malformed response
    /// simply yields fewer confirmed items rather than throwing — a parse
    /// failure here degrades to "escalation found nothing," not a crash in
    /// the background pipeline.
    static func parse(_ response: String, originals: [CalibratedExtraction]) -> [CalibratedExtraction] {
        let lines = response
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { stripLeadingNumber(String($0)) }

        var results: [CalibratedExtraction] = []
        for (index, original) in originals.enumerated() {
            guard index < lines.count else { break }
            let line = lines[index]
            guard !line.isEmpty, line.caseInsensitiveCompare(omitMarker) != .orderedSame else { continue }
            results.append(
                CalibratedExtraction(
                    content: line,
                    nodeType: original.nodeType,
                    confidence: 1.0,
                    supersedes: original.supersedes,
                    needsEscalation: false
                )
            )
        }
        return results
    }

    /// Strips a leading "1. " / "1)" numbering the model may echo back, so a
    /// literal-minded response still parses.
    private static func stripLeadingNumber(_ rawLine: String) -> String {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard let separatorIndex = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return line }
        let prefix = line[line.startIndex..<separatorIndex]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return line }
        return line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Retrieval inspector capture
//
// A session-scoped, in-memory record of what retrieval produced for each
// assistant turn: the exact system prompt sent and the full scored breakdown
// behind it. The debug inspector reads this on long-press. Deliberately not
// persisted — the scores are set-relative to the candidate set and instant they
// were computed over (see `ContextEngine`'s `normalizedSimilarities`), so a
// snapshot is only meaningful for the run that produced it; recomputing it later
// against a changed graph would show different numbers than the ones that
// actually drove the answer.

/// One retrieval's full trace, captured at `send()` time and keyed by the
/// assistant `Message` it produced.
nonisolated struct RetrievalInspectorSnapshot: Sendable, Equatable {
    let capturedAt: Date
    /// False on a device without Apple Intelligence assets (e.g. the simulator),
    /// where the query embedding is empty and the semantic term collapses to a
    /// uniform placeholder — the inspector flags this so the degenerate scores
    /// are not read as real affinities.
    let queryWasEmbedded: Bool
    let config: RetrievalConfig
    /// The exact assembled system prompt handed to the provider.
    let assembledSystemPrompt: String
    /// Every candidate node, in ranked order, with its full scoring trace.
    let scoredNodes: [RetrievalScoreBreakdown]
    /// The subset that fit the token budget and was actually sent.
    let includedNodeIDs: Set<UUID>
    let estimatedTokenCount: Int
}

/// Holds the most recent retrieval snapshot per assistant message for the life
/// of the process. An actor because it is written from the orchestrator's
/// isolation domain and read from the main actor (the Stream tab's long-press).
actor RetrievalInspectorStore {
    private var snapshots: [UUID: RetrievalInspectorSnapshot] = [:]

    init() {}

    func record(_ snapshot: RetrievalInspectorSnapshot, for messageID: UUID) {
        snapshots[messageID] = snapshot
    }

    func snapshot(for messageID: UUID) -> RetrievalInspectorSnapshot? {
        snapshots[messageID]
    }
}

// MARK: - ThreadOrchestrator

/// The full message lifecycle through a single `send()` entry point.
actor ThreadOrchestrator {

    /// Tunables that are policy, not architecture, gathered here rather than
    /// scattered as call-site literals.
    struct Configuration: Sendable {
        var retrieval: RetrievalConfig
        /// Step 12: how often the standing summary regenerates.
        var summaryInterval: Int

        init(
            retrieval: RetrievalConfig = RetrievalConfig(strategy: .decayWeightedSemantic),
            summaryInterval: Int = 10
        ) {
            self.retrieval = retrieval
            self.summaryInterval = summaryInterval
        }
    }

    private let context: ModelContext
    private let embeddingService: EmbeddingService
    private let intelligence: OnDeviceIntelligence
    private let providerFactory: LLMProviderFactory
    private let retrievalEngine = ContextRetrievalEngine()
    private let configuration: Configuration

    /// Session-scoped capture of the retrieval trace behind each answer, read by
    /// the debug inspector. A `let` of a `Sendable` actor type, so the UI can
    /// reach it synchronously off this actor and `await` its own accessors.
    let inspectorStore: RetrievalInspectorStore

    init(
        modelContainer: ModelContainer,
        embeddingService: EmbeddingService,
        intelligence: OnDeviceIntelligence,
        providerFactory: LLMProviderFactory,
        configuration: Configuration = Configuration(),
        inspectorStore: RetrievalInspectorStore = RetrievalInspectorStore()
    ) {
        self.context = ModelContext(modelContainer)
        self.embeddingService = embeddingService
        self.intelligence = intelligence
        self.providerFactory = providerFactory
        self.configuration = configuration
        self.inspectorStore = inspectorStore
    }

    /// The app's wiring: real embedding, real on-device intelligence, Claude
    /// over SSE with on-device fallback.
    static func makeDefault(
        modelContainer: ModelContainer,
        configuration: Configuration = Configuration()
    ) throws -> ThreadOrchestrator {
        ThreadOrchestrator(
            modelContainer: modelContainer,
            embeddingService: try EmbeddingService(),
            intelligence: OnDeviceIntelligence(),
            providerFactory: .makeDefault(),
            configuration: configuration
        )
    }

    // MARK: send()

    /// Steps 1-7, streamed to the caller; steps 8-12 continue in the
    /// background after this stream finishes. `nonisolated` so a caller gets
    /// the stream back without awaiting entry into the actor — matching
    /// `LLMProviderFactory.stream` and the providers it wraps.
    nonisolated func send(_ text: String, workstreamID: UUID) -> AsyncThrowingStream<LLMStreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.run(text, workstreamID: workstreamID, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ rawText: String,
        workstreamID: UUID,
        into continuation: AsyncThrowingStream<LLMStreamChunk, any Error>.Continuation
    ) async {
        do {
            let workstream = try fetchWorkstream(id: workstreamID)
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

            // Step 1: saved before any network call fires.
            let userMessage = Message(
                role: .user,
                content: text,
                estimatedTokens: OrchestrationPrompts.estimateTokens(text)
            )
            userMessage.workstream = workstream
            context.insert(userMessage)
            try context.save()

            // Step 2: awaiting this suspends the actor rather than blocking a
            // thread. Failure (no Apple Intelligence assets — e.g. the
            // simulator, per SPEC.md's Environment note) degrades to an empty
            // query vector rather than failing the send.
            let queryEmbedding = (try? await embeddingService.embed(text)) ?? []
            userMessage.isEmbedded = !queryEmbedding.isEmpty

            // Steps 3-5. The scored breakdown is computed once and both drives
            // retrieval (via `scoredNode`) and is captured for the debug
            // inspector below, so the two can never show different numbers.
            // `now` is pinned so the inspector's decay reflects the instant
            // retrieval actually ran.
            let now = Date.now
            let scored = retrievalEngine.scoredBreakdown(
                for: queryEmbedding,
                in: workstream.contextNodes,
                config: configuration.retrieval,
                now: now
            )
            let payload = retrievalEngine.assemblePayload(
                workstreamSummary: workstream.compactContext,
                rankedNodes: scored.map(\.scoredNode),
                recentMessages: workstream.messages,
                config: configuration.retrieval
            )
            let request = LLMRequest(
                systemPrompt: OrchestrationPrompts.systemPrompt(for: payload),
                messages: OrchestrationPrompts.llmMessages(from: payload.recentMessages)
            )

            // Step 6.
            var assistantText = ""
            for try await chunk in providerFactory.stream(request) {
                switch chunk {
                case .text(let delta):
                    assistantText += delta
                case .replace(let full):
                    assistantText = full
                case .thinking, .done:
                    break
                }
                continuation.yield(chunk)
            }

            // Step 7.
            let assistantMessage = Message(
                role: .assistant,
                content: assistantText,
                estimatedTokens: OrchestrationPrompts.estimateTokens(assistantText)
            )
            assistantMessage.workstream = workstream
            context.insert(assistantMessage)
            workstream.updatedAt = .now
            try context.save()

            // Capture the retrieval trace behind this answer for the debug
            // inspector, keyed by the assistant message it produced. In-memory
            // and session-scoped (see `RetrievalInspectorStore`).
            await inspectorStore.record(
                RetrievalInspectorSnapshot(
                    capturedAt: now,
                    queryWasEmbedded: !queryEmbedding.isEmpty,
                    config: configuration.retrieval,
                    assembledSystemPrompt: request.systemPrompt,
                    scoredNodes: scored,
                    includedNodeIDs: Set(payload.relevantNodes.map(\.nodeID)),
                    estimatedTokenCount: payload.estimatedTokenCount
                ),
                for: assistantMessage.id
            )

            continuation.finish()

            // Steps 8-12, deliberately not awaited here: the caller's stream
            // has already finished, and a follow-up failure has no one left
            // to report to — see `processFollowUp`.
            let assistantMessageID = assistantMessage.id
            Task { [weak self] in
                await self?.processFollowUp(
                    workstreamID: workstreamID,
                    userText: text,
                    assistantText: assistantText,
                    sourceMessageID: assistantMessageID
                )
            }
        } catch {
            continuation.finish(throwing: error)
        }
    }

    // MARK: Steps 8-12

    private func processFollowUp(
        workstreamID: UUID,
        userText: String,
        assistantText: String,
        sourceMessageID: UUID
    ) async {
        guard let workstream = try? fetchWorkstream(id: workstreamID) else { return }

        let exchange = ConversationExchange(
            workstreamTitle: workstream.title,
            userMessage: userText,
            assistantMessage: assistantText,
            existingContext: fragments(for: workstream.contextNodes)
        )

        // Step 8.
        guard let extracted = try? await intelligence.extractContext(from: exchange), !extracted.isEmpty else {
            await maybeUpdateSummary(for: workstream)
            return
        }

        // Step 9: confident items are stored as-is; the rest go to Claude.
        let confident = extracted.filter { !$0.needsEscalation }
        let shaky = extracted.filter(\.needsEscalation)
        let escalated = await escalate(shaky, exchange: exchange)

        // Steps 10-11.
        for item in confident + escalated {
            await applyExtraction(item, to: workstream, sourceMessageID: sourceMessageID)
        }
        try? context.save()

        // Step 12.
        await maybeUpdateSummary(for: workstream)
    }

    /// `internal` rather than `private`: the escalation round trip is real
    /// logic worth testing directly against a stub `LLMProviderFactory`,
    /// without depending on a working on-device model to produce
    /// low-confidence items to escalate in the first place.
    func escalate(_ items: [CalibratedExtraction], exchange: ConversationExchange) async -> [CalibratedExtraction] {
        guard !items.isEmpty else { return [] }
        let request = EscalationPromptBuilder.request(for: items, exchange: exchange)
        guard let response = try? await collectText(from: providerFactory.stream(request)) else {
            // No verified answer came back — dropped rather than stored
            // unverified.
            return []
        }
        return EscalationPromptBuilder.parse(response, originals: items)
    }

    private func collectText(from stream: AsyncThrowingStream<LLMStreamChunk, any Error>) async throws -> String {
        var text = ""
        for try await chunk in stream {
            switch chunk {
            case .text(let delta): text += delta
            case .replace(let full): text = full
            case .thinking, .done: break
            }
        }
        return text
    }

    /// Fetch-by-id wrapper around `applyExtraction(_:to:sourceMessageID:)` so
    /// steps 10-11 are testable with hand-built `CalibratedExtraction`
    /// values, bypassing `OnDeviceIntelligence` entirely. Only `Sendable`
    /// values cross in — the `Workstream` itself is fetched inside, on this
    /// actor's own context, never handed in from outside.
    func applyExtraction(_ item: CalibratedExtraction, workstreamID: UUID, sourceMessageID: UUID) async throws {
        let workstream = try fetchWorkstream(id: workstreamID)
        await applyExtraction(item, to: workstream, sourceMessageID: sourceMessageID)
        try context.save()
    }

    /// Steps 10-11 for one item: create the node, link supersession, embed it.
    private func applyExtraction(_ item: CalibratedExtraction, to workstream: Workstream, sourceMessageID: UUID) async {
        let node = ContextNode(
            content: item.content,
            nodeType: ContextNodeType(rawValue: item.nodeType) ?? .fact,
            sourceMessageID: sourceMessageID,
            extractionConfidence: item.confidence
        )
        context.insert(node)
        node.workstream = workstream

        if !item.supersedes.isEmpty,
           let superseded = matchSupersededNode(item.supersedes, in: workstream, excluding: node.id) {
            superseded.supersededByID = node.id
        }

        if let vector = try? await embeddingService.embed(item.content) {
            node.embeddingData = EmbeddingService.encode(vector)
        }
    }

    /// Only the first not-yet-superseded match: overwriting an existing
    /// `supersededByID` would silently break a chain another extraction
    /// already established.
    private func matchSupersededNode(_ text: String, in workstream: Workstream, excluding excludedID: UUID) -> ContextNode? {
        let target = ExtractionConfidencePolicy.normalize(text)
        guard !target.isEmpty else { return nil }
        return workstream.contextNodes.first {
            $0.id != excludedID
                && $0.supersededByID == nil
                && ExtractionConfidencePolicy.normalize($0.content) == target
        }
    }

    private func maybeUpdateSummary(for workstream: Workstream) async {
        guard OrchestrationPrompts.isSummaryDue(
            messageCount: workstream.messages.count,
            interval: configuration.summaryInterval
        ) else { return }

        let digest = WorkstreamDigest(
            title: workstream.title,
            fragments: fragments(for: workstream.contextNodes),
            recentMessages: recentSnapshots(for: workstream)
        )
        guard let summary = try? await intelligence.summarize(digest) else { return }

        if !summary.title.isEmpty { workstream.title = summary.title }
        workstream.compactContext = summary.compactContext
        workstream.summary = summary.compactContext
        workstream.updatedAt = .now
        try? context.save()
    }

    private func fragments(for nodes: [ContextNode]) -> [ContextFragment] {
        nodes.map { ContextFragment(content: $0.content, nodeType: $0.nodeType, isSuperseded: $0.supersededByID != nil) }
    }

    private func recentSnapshots(for workstream: Workstream) -> [MessageSnapshot] {
        workstream.messages
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(IntelligencePrompts.maximumDigestMessages)
            .map {
                MessageSnapshot(
                    messageID: $0.id,
                    role: $0.role,
                    content: $0.content,
                    estimatedTokens: $0.estimatedTokens,
                    createdAt: $0.createdAt
                )
            }
    }

    private func fetchWorkstream(id: UUID) throws -> Workstream {
        var descriptor = FetchDescriptor<Workstream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let workstream = try context.fetch(descriptor).first else {
            throw ThreadOrchestratorError.workstreamNotFound(id)
        }
        return workstream
    }
}
