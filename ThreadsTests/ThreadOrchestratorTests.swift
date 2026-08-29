//
//  ThreadOrchestratorTests.swift
//  ThreadsTests
//
//  `EmbeddingService.embed` and `OnDeviceIntelligence`'s generation calls both
//  fail on the simulator (no Apple Intelligence, and `NLContextualEmbedding`
//  cannot compile its model here — see SPEC.md's Environment note), so these
//  tests exercise real `ThreadOrchestrator` instances wired to real
//  `EmbeddingService`/`OnDeviceIntelligence` values and confirm the pipeline
//  degrades gracefully rather than trying to assert on model output. Wiring
//  that does not depend on either model — retrieval assembly, escalation,
//  supersession, the summary-interval gate — is exercised for real, via a
//  stub `LLMStreamingProvider` and the same in-memory `ModelContainer`
//  helper the rest of the suite uses.
//

import Foundation
import Testing
import SwiftData
@testable import Threads

// MARK: - Test doubles

/// Captures the last `LLMRequest` it was asked to stream, synchronously at
/// call time — before any chunk is consumed — so a test can drain the
/// orchestrator's returned stream and then inspect exactly what was sent.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: LLMRequest?

    var value: LLMRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set(_ request: LLMRequest) {
        lock.lock()
        defer { lock.unlock() }
        _value = request
    }
}

private nonisolated struct StubProvider: LLMStreamingProvider {
    let identifier: String
    var available = true
    let chunks: [LLMStreamChunk]
    let capture: RequestBox?

    init(identifier: String = "stub", available: Bool = true, chunks: [LLMStreamChunk], capture: RequestBox? = nil) {
        self.identifier = identifier
        self.available = available
        self.chunks = chunks
        self.capture = capture
    }

    func isAvailable() async -> Bool { available }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, any Error> {
        capture?.set(request)
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private func collect(_ stream: AsyncThrowingStream<LLMStreamChunk, any Error>) async throws -> [LLMStreamChunk] {
    var chunks: [LLMStreamChunk] = []
    for try await chunk in stream { chunks.append(chunk) }
    return chunks
}

private func makeOrchestrator(
    container: ModelContainer,
    primary: any LLMStreamingProvider,
    fallback: (any LLMStreamingProvider)? = nil,
    configuration: ThreadOrchestrator.Configuration = ThreadOrchestrator.Configuration()
) throws -> ThreadOrchestrator {
    ThreadOrchestrator(
        modelContainer: container,
        embeddingService: try EmbeddingService(),
        intelligence: OnDeviceIntelligence(),
        providerFactory: LLMProviderFactory(
            primary: primary,
            fallback: fallback ?? primary,
            reachability: StaticReachability(available: true)
        ),
        configuration: configuration
    )
}

@discardableResult
private func makeWorkstream(
    in container: ModelContainer,
    title: String = "Ledger migration",
    compactContext: String = ""
) throws -> UUID {
    let context = ModelContext(container)
    let workstream = Workstream(title: title, compactContext: compactContext)
    context.insert(workstream)
    try context.save()
    return workstream.id
}

// MARK: - Pure prompt/formatting logic

@Suite struct OrchestrationPromptsTests {

    @Test func estimateTokensIsAtLeastOne() {
        #expect(OrchestrationPrompts.estimateTokens("") == 1)
        #expect(OrchestrationPrompts.estimateTokens("hi") == 1)
        #expect(OrchestrationPrompts.estimateTokens(String(repeating: "a", count: 40)) == 10)
    }

    @Test func systemPromptCombinesSummaryAndRelevantNodes() {
        let payload = ContextPayload(
            workstreamSummary: "Moving the ledger to Postgres.",
            relevantNodes: [
                ScoredContextNode(
                    nodeID: UUID(),
                    content: "The ledger moves to Postgres.",
                    nodeType: ContextNodeType.decision.rawValue,
                    score: 0.9,
                    isSuperseded: false,
                    createdAt: .now
                ),
            ],
            recentMessages: [],
            estimatedTokenCount: 10
        )
        let prompt = OrchestrationPrompts.systemPrompt(for: payload)

        #expect(prompt.contains("Moving the ledger to Postgres."))
        #expect(prompt.contains("[decision]"))
        #expect(prompt.contains("The ledger moves to Postgres."))
    }

    @Test func systemPromptMarksSupersededNodes() {
        let payload = ContextPayload(
            workstreamSummary: "",
            relevantNodes: [
                ScoredContextNode(
                    nodeID: UUID(),
                    content: "The ledger stays on SQLite.",
                    nodeType: ContextNodeType.decision.rawValue,
                    score: 0.4,
                    isSuperseded: true,
                    createdAt: .now
                ),
            ],
            recentMessages: [],
            estimatedTokenCount: 5
        )
        #expect(OrchestrationPrompts.systemPrompt(for: payload).contains("(superseded)"))
    }

    @Test func systemPromptOmitsEmptySections() {
        let payload = ContextPayload(workstreamSummary: "", relevantNodes: [], recentMessages: [], estimatedTokenCount: 0)
        #expect(OrchestrationPrompts.systemPrompt(for: payload).isEmpty)
    }

    @Test func llmMessagesReverseNewestFirstIntoOldestFirst() {
        let snapshots = [
            MessageSnapshot(messageID: UUID(), role: MessageRole.assistant.rawValue, content: "Second.", estimatedTokens: 4, createdAt: Date(timeIntervalSince1970: 2)),
            MessageSnapshot(messageID: UUID(), role: MessageRole.user.rawValue, content: "First.", estimatedTokens: 4, createdAt: Date(timeIntervalSince1970: 1)),
        ]
        let messages = OrchestrationPrompts.llmMessages(from: snapshots)

        #expect(messages.map(\.content) == ["First.", "Second."])
        #expect(messages.map(\.role) == [.user, .assistant])
    }

    @Test func llmMessagesDropSystemMessagesRatherThanMisassigningThem() {
        let snapshots = [
            MessageSnapshot(messageID: UUID(), role: MessageRole.user.rawValue, content: "Hi.", estimatedTokens: 2, createdAt: Date(timeIntervalSince1970: 2)),
            MessageSnapshot(messageID: UUID(), role: MessageRole.system.rawValue, content: "Background.", estimatedTokens: 2, createdAt: Date(timeIntervalSince1970: 1)),
        ]
        let messages = OrchestrationPrompts.llmMessages(from: snapshots)

        #expect(messages.count == 1)
        #expect(messages[0].content == "Hi.")
    }

    @Test func summaryIsDueOnlyAtIntervalBoundaries() {
        #expect(OrchestrationPrompts.isSummaryDue(messageCount: 10, interval: 10))
        #expect(OrchestrationPrompts.isSummaryDue(messageCount: 20, interval: 10))
        #expect(!OrchestrationPrompts.isSummaryDue(messageCount: 9, interval: 10))
        #expect(!OrchestrationPrompts.isSummaryDue(messageCount: 11, interval: 10))
        #expect(!OrchestrationPrompts.isSummaryDue(messageCount: 0, interval: 10))
    }
}

// MARK: - Escalation prompt building and parsing

@Suite struct EscalationPromptBuilderTests {

    private let exchange = ConversationExchange(
        workstreamTitle: "Ledger migration",
        userMessage: "Should we move the ledger?",
        assistantMessage: "Given the write volume, yes."
    )

    @Test func requestNumbersEachItemAndCarriesTheExchange() {
        let items = [
            CalibratedExtraction(content: "shaky one", nodeType: ContextNodeType.fact.rawValue, confidence: 0.2, supersedes: "", needsEscalation: true),
            CalibratedExtraction(content: "shaky two", nodeType: ContextNodeType.fact.rawValue, confidence: 0.1, supersedes: "", needsEscalation: true),
        ]
        let request = EscalationPromptBuilder.request(for: items, exchange: exchange)

        #expect(request.messages.count == 1)
        #expect(request.messages[0].content.contains("1. [fact] shaky one"))
        #expect(request.messages[0].content.contains("2. [fact] shaky two"))
        #expect(request.messages[0].content.contains("Should we move the ledger?"))
        #expect(request.systemPrompt.contains(EscalationPromptBuilder.omitMarker))
    }

    @Test func parseMapsLinesPositionallyOntoOriginals() {
        let originals = [
            CalibratedExtraction(content: "shaky one", nodeType: ContextNodeType.fact.rawValue, confidence: 0.2, supersedes: "", needsEscalation: true),
            CalibratedExtraction(content: "shaky two", nodeType: ContextNodeType.decision.rawValue, confidence: 0.1, supersedes: "old text", needsEscalation: true),
        ]
        let response = "1. Corrected fact one.\n2. OMIT"
        let result = EscalationPromptBuilder.parse(response, originals: originals)

        #expect(result.count == 1)
        #expect(result[0].content == "Corrected fact one.")
        #expect(result[0].nodeType == ContextNodeType.fact.rawValue)
        #expect(result[0].confidence == 1.0)
        #expect(result[0].needsEscalation == false)
    }

    @Test func parsePreservesSupersedesFromTheOriginal() {
        let originals = [
            CalibratedExtraction(content: "shaky", nodeType: ContextNodeType.decision.rawValue, confidence: 0.2, supersedes: "old decision", needsEscalation: true),
        ]
        let result = EscalationPromptBuilder.parse("1. Corrected decision.", originals: originals)

        #expect(result[0].supersedes == "old decision")
    }

    @Test func omitIsCaseInsensitive() {
        let originals = [
            CalibratedExtraction(content: "shaky", nodeType: ContextNodeType.fact.rawValue, confidence: 0.2, supersedes: "", needsEscalation: true),
        ]
        #expect(EscalationPromptBuilder.parse("omit", originals: originals).isEmpty)
    }

    @Test func shortResponseYieldsFewerItemsRatherThanCrashing() {
        let originals = [
            CalibratedExtraction(content: "a", nodeType: ContextNodeType.fact.rawValue, confidence: 0.2, supersedes: "", needsEscalation: true),
            CalibratedExtraction(content: "b", nodeType: ContextNodeType.fact.rawValue, confidence: 0.2, supersedes: "", needsEscalation: true),
        ]
        let result = EscalationPromptBuilder.parse("1. Only one line.", originals: originals)

        #expect(result.count == 1)
    }
}

// MARK: - send(): steps 1, 6, 7 against a stub provider

@Suite(.serialized) struct ThreadOrchestratorSendTests {

    @Test func userAndAssistantMessagesAreBothPersisted() async throws {
        let container = try makeInMemoryContainer()
        let workstreamID = try makeWorkstream(in: container)
        let orchestrator = try makeOrchestrator(
            container: container,
            primary: StubProvider(chunks: [.text("Hi "), .text("there."), .done(LLMCompletion(providerIdentifier: "stub"))])
        )

        let chunks = try await collect(orchestrator.send("Hello", workstreamID: workstreamID))
        #expect(chunks.contains(.text("Hi ")))

        let verifyContext = ModelContext(container)
        let messages = try verifyContext.fetch(FetchDescriptor<Message>()).sorted { $0.createdAt < $1.createdAt }

        #expect(messages.count == 2)
        #expect(messages[0].roleValue == .user)
        #expect(messages[0].content == "Hello")
        #expect(messages[1].roleValue == .assistant)
        #expect(messages[1].content == "Hi there.")
    }

    @Test func sendingToAMissingWorkstreamThrowsRatherThanCreatingOne() async throws {
        let container = try makeInMemoryContainer()
        let orchestrator = try makeOrchestrator(container: container, primary: StubProvider(chunks: []))

        await #expect(throws: ThreadOrchestratorError.self) {
            _ = try await collect(orchestrator.send("Hello", workstreamID: UUID()))
        }
    }

    @Test func fallsBackAutomaticallyWhenThePrimaryFailsBeforeAnyOutput() async throws {
        let container = try makeInMemoryContainer()
        let workstreamID = try makeWorkstream(in: container)
        struct Boom: Error {}
        let orchestrator = try makeOrchestrator(
            container: container,
            primary: StubProvider(identifier: "primary", available: false, chunks: []),
            fallback: StubProvider(identifier: "fallback", chunks: [.text("Fallback answer."), .done(LLMCompletion(providerIdentifier: "fallback"))])
        )

        _ = try await collect(orchestrator.send("Hello", workstreamID: workstreamID))

        let verifyContext = ModelContext(container)
        let assistant = try verifyContext.fetch(FetchDescriptor<Message>()).first { $0.roleValue == .assistant }
        #expect(assistant?.content == "Fallback answer.")
    }

    @Test func systemPromptAndMessageHistoryReflectRetrievedContext() async throws {
        let container = try makeInMemoryContainer()
        let workstreamID = try makeWorkstream(in: container, compactContext: "The team is migrating the ledger to Postgres.")

        // Seed an existing node. Its embedding is a synthetic vector encoded
        // with `EmbeddingService.encode` directly — a hand-computable value
        // rather than a real one, since `NLContextualEmbedding` cannot
        // compile its model on the simulator (SPEC.md's Environment note).
        let seedContext = ModelContext(container)
        let workstream = try #require(
            try seedContext.fetch(FetchDescriptor<Workstream>(predicate: #Predicate { $0.id == workstreamID })).first
        )
        let node = ContextNode(content: "The ledger moves to Postgres.", nodeType: .decision)
        node.embeddingData = EmbeddingService.encode([Double](repeating: 1.0, count: 512))
        node.workstream = workstream
        seedContext.insert(node)
        try seedContext.save()

        let capture = RequestBox()
        let orchestrator = try makeOrchestrator(
            container: container,
            primary: StubProvider(chunks: [.text("Sure."), .done(LLMCompletion(providerIdentifier: "stub"))], capture: capture)
        )

        _ = try await collect(orchestrator.send("What did we decide?", workstreamID: workstreamID))

        let request = try #require(capture.value)
        #expect(request.systemPrompt.contains("The team is migrating the ledger to Postgres."))
        #expect(request.systemPrompt.contains("The ledger moves to Postgres."))
        #expect(request.messages.last?.content == "What did we decide?")
        #expect(request.messages.last?.role == .user)
    }
}

// MARK: - applyExtraction(): steps 10-11 without a working on-device model

@Suite(.serialized) struct ThreadOrchestratorExtractionTests {

    @Test func newNodeIsCreatedWithTheGivenSourceMessage() async throws {
        let container = try makeInMemoryContainer()
        let workstreamID = try makeWorkstream(in: container)
        let orchestrator = try makeOrchestrator(container: container, primary: StubProvider(chunks: []))
        let sourceMessageID = UUID()

        try await orchestrator.applyExtraction(
            CalibratedExtraction(content: "The ledger moves to Postgres.", nodeType: ContextNodeType.decision.rawValue, confidence: 0.9, supersedes: "", needsEscalation: false),
            workstreamID: workstreamID,
            sourceMessageID: sourceMessageID
        )

        let verifyContext = ModelContext(container)
        let nodes = try verifyContext.fetch(FetchDescriptor<ContextNode>())
        #expect(nodes.count == 1)
        #expect(nodes[0].content == "The ledger moves to Postgres.")
        #expect(nodes[0].nodeTypeValue == .decision)
        #expect(nodes[0].sourceMessageID == sourceMessageID)
        #expect(nodes[0].supersededByID == nil)
    }

    @Test func aRealSupersedingCaseLinksTheOldNodeToTheNew() async throws {
        let container = try makeInMemoryContainer()
        let workstreamID = try makeWorkstream(in: container)

        let seedContext = ModelContext(container)
        let workstream = try #require(
            try seedContext.fetch(FetchDescriptor<Workstream>(predicate: #Predicate { $0.id == workstreamID })).first
        )
        let oldNode = ContextNode(content: "The ledger stays on SQLite.", nodeType: .decision)
        oldNode.workstream = workstream
        seedContext.insert(oldNode)
        try seedContext.save()
        let oldNodeID = oldNode.id

        let orchestrator = try makeOrchestrator(container: container, primary: StubProvider(chunks: []))
        try await orchestrator.applyExtraction(
            CalibratedExtraction(content: "The ledger moves to Postgres.", nodeType: ContextNodeType.decision.rawValue, confidence: 0.9, supersedes: "The ledger stays on SQLite.", needsEscalation: false),
            workstreamID: workstreamID,
            sourceMessageID: UUID()
        )

        let verifyContext = ModelContext(container)
        let nodes = try verifyContext.fetch(FetchDescriptor<ContextNode>())
        let old = try #require(nodes.first { $0.id == oldNodeID })
        let new = try #require(nodes.first { $0.id != oldNodeID })

        #expect(old.supersededByID == new.id)
        #expect(new.supersededByID == nil)
    }

    @Test func alreadySupersededNodeIsNotRetargeted() async throws {
        let container = try makeInMemoryContainer()
        let workstreamID = try makeWorkstream(in: container)
        let priorSuccessorID = UUID()

        let seedContext = ModelContext(container)
        let workstream = try #require(
            try seedContext.fetch(FetchDescriptor<Workstream>(predicate: #Predicate { $0.id == workstreamID })).first
        )
        let oldNode = ContextNode(content: "The ledger stays on SQLite.", nodeType: .decision, supersededByID: priorSuccessorID)
        oldNode.workstream = workstream
        seedContext.insert(oldNode)
        try seedContext.save()
        let oldNodeID = oldNode.id

        let orchestrator = try makeOrchestrator(container: container, primary: StubProvider(chunks: []))
        try await orchestrator.applyExtraction(
            CalibratedExtraction(content: "The ledger moves to Postgres, again.", nodeType: ContextNodeType.decision.rawValue, confidence: 0.9, supersedes: "The ledger stays on SQLite.", needsEscalation: false),
            workstreamID: workstreamID,
            sourceMessageID: UUID()
        )

        let verifyContext = ModelContext(container)
        let old = try #require(try verifyContext.fetch(FetchDescriptor<ContextNode>()).first { $0.id == oldNodeID })
        #expect(old.supersededByID == priorSuccessorID)
    }

    @Test func noMatchingTextMeansNothingIsSuperseded() async throws {
        let container = try makeInMemoryContainer()
        let workstreamID = try makeWorkstream(in: container)

        let seedContext = ModelContext(container)
        let workstream = try #require(
            try seedContext.fetch(FetchDescriptor<Workstream>(predicate: #Predicate { $0.id == workstreamID })).first
        )
        let unrelated = ContextNode(content: "The API uses REST.", nodeType: .fact)
        unrelated.workstream = workstream
        seedContext.insert(unrelated)
        try seedContext.save()

        let orchestrator = try makeOrchestrator(container: container, primary: StubProvider(chunks: []))
        try await orchestrator.applyExtraction(
            CalibratedExtraction(content: "New fact.", nodeType: ContextNodeType.fact.rawValue, confidence: 0.9, supersedes: "Nothing on file matches this.", needsEscalation: false),
            workstreamID: workstreamID,
            sourceMessageID: UUID()
        )

        let verifyContext = ModelContext(container)
        let nodes = try verifyContext.fetch(FetchDescriptor<ContextNode>())
        #expect(nodes.allSatisfy { $0.supersededByID == nil })
    }
}

// MARK: - escalate(): step 9 against a stub provider, no on-device model needed

@Suite(.serialized) struct ThreadOrchestratorEscalationTests {

    @Test func escalationReplacesLowConfidenceContentWithClaudesAnswer() async throws {
        let container = try makeInMemoryContainer()
        let orchestrator = try makeOrchestrator(
            container: container,
            primary: StubProvider(chunks: [.text("1. Corrected fact one.\n2. OMIT"), .done(LLMCompletion(providerIdentifier: "stub"))])
        )
        let items = [
            CalibratedExtraction(content: "shaky one", nodeType: ContextNodeType.fact.rawValue, confidence: 0.2, supersedes: "", needsEscalation: true),
            CalibratedExtraction(content: "shaky two", nodeType: ContextNodeType.fact.rawValue, confidence: 0.1, supersedes: "", needsEscalation: true),
        ]
        let exchange = ConversationExchange(workstreamTitle: "T", userMessage: "u", assistantMessage: "a")

        let result = await orchestrator.escalate(items, exchange: exchange)

        #expect(result.count == 1)
        #expect(result[0].content == "Corrected fact one.")
        #expect(result[0].confidence == 1.0)
        #expect(result[0].needsEscalation == false)
    }

    @Test func escalatingAnEmptyListNeverCallsTheProvider() async throws {
        let container = try makeInMemoryContainer()
        let orchestrator = try makeOrchestrator(container: container, primary: StubProvider(chunks: [.text("should not run")]))

        let result = await orchestrator.escalate([], exchange: ConversationExchange(workstreamTitle: "T", userMessage: "u", assistantMessage: "a"))
        #expect(result.isEmpty)
    }
}
