//
//  ContextEngine.swift
//  Threads
//

import Accelerate
import Foundation
import NaturalLanguage

// MARK: - EmbeddingService

actor EmbeddingService {
    enum EmbeddingError: Error {
        case modelUnavailable
    }

    private let model: NLContextualEmbedding
    private var isLoaded = false

    init(language: NLLanguage = .english) throws {
        guard let model = NLContextualEmbedding(language: language) else {
            throw EmbeddingError.modelUnavailable
        }
        self.model = model
    }

    /// Requests on-device assets if they aren't resolved yet, then loads the
    /// model. Assets must be requested (and awaited) before `load()` can
    /// succeed, so this can't happen synchronously in `init`.
    private func ensureLoaded() async throws {
        guard !isLoaded else { return }
        if !model.hasAvailableAssets {
            guard try await model.requestAssets() == .available else {
                throw EmbeddingError.modelUnavailable
            }
        }
        try model.load()
        isLoaded = true
    }

    /// Mean-pooled, L2-normalized embedding vector for `text`.
    func embed(_ text: String) async throws -> [Double] {
        try await ensureLoaded()
        let result = try model.embeddingResult(for: text, language: nil)

        var sum = [Double](repeating: 0, count: model.dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for i in 0..<vector.count {
                sum[i] += vector[i]
            }
            tokenCount += 1
            return true
        }

        guard tokenCount > 0 else { return sum }
        let mean = sum.map { $0 / Double(tokenCount) }

        let magnitude = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return mean }
        return mean.map { $0 / magnitude }
    }

    nonisolated static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot = 0.0
        vDSP_dotprD(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var normASquared = 0.0
        vDSP_dotprD(a, 1, a, 1, &normASquared, vDSP_Length(a.count))
        var normBSquared = 0.0
        vDSP_dotprD(b, 1, b, 1, &normBSquared, vDSP_Length(b.count))

        let denominator = normASquared.squareRoot() * normBSquared.squareRoot()
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }

    nonisolated static func encode(_ vector: [Double]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated static func decode(_ data: Data) -> [Double] {
        var out = [Double](repeating: 0, count: data.count / MemoryLayout<Double>.size)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }
}

// MARK: - Retrieval strategy & config

// Explicitly `nonisolated`: the app target defaults to MainActor isolation
// (`SWIFT_DEFAULT_ACTOR_ISOLATION`), and these values must be freely usable
// from any isolation domain — the eval runner, the debug inspector, tests.
// `Sendable` alone does not opt a type out of that default.

nonisolated enum RetrievalStrategy: Sendable, Equatable {
    case semanticOnly
    case recencyOnly
    case decayWeightedSemantic
}

nonisolated struct RetrievalConfig: Sendable, Equatable {
    var strategy: RetrievalStrategy
    var topK: Int = 5
    var halfLifeDays: Double = 14.0
    var supersededPenalty: Double = 0.5
    var tokenBudget: Int = 4096
}

// MARK: - Value types returned to callers

nonisolated struct ScoredContextNode: Sendable, Equatable {
    let nodeID: UUID
    let content: String
    let nodeType: String
    let score: Double
    let isSuperseded: Bool
    let createdAt: Date
}

nonisolated struct MessageSnapshot: Sendable, Equatable {
    let messageID: UUID
    let role: String
    let content: String
    let estimatedTokens: Int
    let createdAt: Date
}

nonisolated struct ContextPayload: Sendable, Equatable {
    let workstreamSummary: String
    let relevantNodes: [ScoredContextNode]
    let recentMessages: [MessageSnapshot]
    let estimatedTokenCount: Int
}

// MARK: - ContextRetrievalEngine

/// Stateless computation over caller-held inputs — no shared mutable resource
/// to protect, so this is a plain struct rather than an actor. Explicitly
/// `nonisolated` because the app target defaults to MainActor isolation
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION`); this type must stay callable
/// synchronously from any isolation domain. Only `Sendable` value types cross
/// in and out.
nonisolated struct ContextRetrievalEngine {

    func rankedNodes(
        for queryEmbedding: [Double],
        in nodes: [ContextNode],
        config: RetrievalConfig,
        now: Date = .now
    ) -> [ScoredContextNode] {
        nodes
            .map { node in
                let base = baseScore(
                    strategy: config.strategy,
                    queryEmbedding: queryEmbedding,
                    node: node,
                    now: now,
                    halfLifeDays: config.halfLifeDays
                )
                let isSuperseded = node.supersededByID != nil
                let final = base * supersededMultiplier(
                    isSuperseded: isSuperseded,
                    penalty: config.supersededPenalty
                )
                return ScoredContextNode(
                    nodeID: node.id,
                    content: node.content,
                    nodeType: node.nodeType,
                    score: final,
                    isSuperseded: isSuperseded,
                    createdAt: node.createdAt
                )
            }
            .sorted { $0.score > $1.score }
    }

    func assemblePayload(
        workstreamSummary: String,
        rankedNodes: [ScoredContextNode],
        recentMessages: [Message],
        config: RetrievalConfig
    ) -> ContextPayload {
        var tokenCount = estimateTokens(workstreamSummary)

        var includedNodes: [ScoredContextNode] = []
        for node in rankedNodes.prefix(config.topK) {
            let nodeTokens = estimateTokens(node.content)
            guard tokenCount + nodeTokens <= config.tokenBudget else { break }
            includedNodes.append(node)
            tokenCount += nodeTokens
        }

        var includedMessages: [MessageSnapshot] = []
        let newestFirst = recentMessages.sorted { $0.createdAt > $1.createdAt }
        for message in newestFirst {
            guard tokenCount + message.estimatedTokens <= config.tokenBudget else { break }
            includedMessages.append(
                MessageSnapshot(
                    messageID: message.id,
                    role: message.role,
                    content: message.content,
                    estimatedTokens: message.estimatedTokens,
                    createdAt: message.createdAt
                )
            )
            tokenCount += message.estimatedTokens
        }

        return ContextPayload(
            workstreamSummary: workstreamSummary,
            relevantNodes: includedNodes,
            recentMessages: includedMessages,
            estimatedTokenCount: tokenCount
        )
    }

    func retrieve(
        queryEmbedding: [Double],
        nodes: [ContextNode],
        recentMessages: [Message],
        workstreamSummary: String,
        config: RetrievalConfig,
        now: Date = .now
    ) -> ContextPayload {
        let ranked = rankedNodes(for: queryEmbedding, in: nodes, config: config, now: now)
        return assemblePayload(
            workstreamSummary: workstreamSummary,
            rankedNodes: ranked,
            recentMessages: recentMessages,
            config: config
        )
    }

    // MARK: Scoring

    private func baseScore(
        strategy: RetrievalStrategy,
        queryEmbedding: [Double],
        node: ContextNode,
        now: Date,
        halfLifeDays: Double
    ) -> Double {
        switch strategy {
        case .semanticOnly:
            return similarity(queryEmbedding: queryEmbedding, node: node)
        case .recencyOnly:
            let ageInDays = max(0, now.timeIntervalSince(node.createdAt) / 86400)
            return 1.0 / (1.0 + ageInDays)
        case .decayWeightedSemantic:
            let sim = similarity(queryEmbedding: queryEmbedding, node: node)
            return sim * decayFactor(createdAt: node.createdAt, now: now, halfLifeDays: halfLifeDays)
        }
    }

    private func similarity(queryEmbedding: [Double], node: ContextNode) -> Double {
        guard let data = node.embeddingData else { return 0 }
        let vector = EmbeddingService.decode(data)
        guard vector.count == queryEmbedding.count else { return 0 }
        return EmbeddingService.cosineSimilarity(queryEmbedding, vector)
    }

    /// Never sees `supersededByID` — kept separable from supersession down-weighting.
    private func decayFactor(createdAt: Date, now: Date, halfLifeDays: Double) -> Double {
        guard halfLifeDays > 0 else { return 1.0 }
        let ageInDays = max(0, now.timeIntervalSince(createdAt) / 86400)
        return pow(0.5, ageInDays / halfLifeDays)
    }

    /// Never sees `createdAt`/`halfLifeDays` — kept separable from decay.
    private func supersededMultiplier(isSuperseded: Bool, penalty: Double) -> Double {
        isSuperseded ? penalty : 1.0
    }

    // MARK: Token budgeting

    private func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}
