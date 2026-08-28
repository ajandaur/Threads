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
    /// How much authority the decay term has over ranking, in `0...1`. The
    /// half-life sets the *shape* of the decay curve; this sets how far that
    /// curve is allowed to move a score — `1 - strength * (1 - decayFactor)`.
    /// At 0 decay is inert; at 1 a node one half-life old loses half its score
    /// outright.
    ///
    /// Separate from `halfLifeDays` because they answer different questions.
    /// A raw 14-day half-life spans 18.8x across this corpus's ~60-day range,
    /// which multiplicatively swamps any semantic term no matter how it is
    /// scaled — an exact match 24 days old (0.30) loses to a mediocre one a
    /// day old (0.98). Widening the half-life would fix that too, but the
    /// 14-day half-life is a locked decision and it is the decay *shape* that
    /// decision is about, so the authority gets its own knob instead.
    ///
    /// **0.25 is tuned, not arbitrary — don't collapse this into a constant.**
    /// Two independent sweeps over `0...1` in 0.05 steps, each running the
    /// frozen `comparisonTable` eval on a physical device (the simulator cannot
    /// compile the embedding model), landed on the same value; the second ran
    /// in a session blind to the first's numbers. Both took the midpoint of the
    /// region where both eval objectives hold at once — current-state
    /// precision@5 at its plateau maximum and aggregate precision@5 at or near
    /// its maximum, `0.20...0.30` in the blind sweep. Deliberately not the
    /// argmax: aggregate precision@5 peaks at 0.20, but every fixture query has
    /// exactly one relevant node, so that metric is `hits / 150` and the peak is
    /// a one-query lead over 0.25 — inside the noise `RetrievalEval`'s own
    /// reading notes warn about. 0.25 sits a full grid step from both edges of
    /// the joint region, so it is the least sensitive to one query flipping
    /// either way.
    ///
    /// **Do not read the eval's passing range as `0.00...0.45`.** The comparison
    /// test does pass across all of it, bounded by the current-state assertion
    /// alone, but the bottom of that range is vacuous: at 0 decay goes inert and
    /// `.decayWeightedSemantic` becomes numerically identical to `.semanticOnly`,
    /// which satisfies the non-strict assertions while measuring nothing (0 also
    /// fails `decayActuallyDecays`, and at 0.05 the decay-weighted column is
    /// still identical to semantic-only in every aggregate). The meaningful
    /// range is roughly `0.10...0.45`. Relatedly, the eval's historical-subset
    /// assertion cannot currently fail — semantic-only scores 0 there, so
    /// `semantic >= decay` holds for any non-negative result — so the whole
    /// range is defended by the current-state assertion alone.
    ///
    /// Re-tuning re-runs the full three-strategy comparison and reports deltas,
    /// per `.claude/rules/evals.md`. No cherry-picking a single rerun.
    var decayStrength: Double = 0.25
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
        // Similarity is normalized across the whole candidate set, so it has to
        // be computed for every node before any node can be scored. That makes
        // this a two-pass operation rather than the one-pass `map` it looks like.
        let similarities = nodes.map { similarity(queryEmbedding: queryEmbedding, node: $0) }
        let semanticScores = normalizedSimilarities(similarities)

        return zip(nodes, semanticScores)
            .map { node, semantic in
                let base = baseScore(
                    strategy: config.strategy,
                    semantic: semantic,
                    node: node,
                    now: now,
                    halfLifeDays: config.halfLifeDays,
                    decayStrength: config.decayStrength
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
        semantic: Double,
        node: ContextNode,
        now: Date,
        halfLifeDays: Double,
        decayStrength: Double
    ) -> Double {
        switch strategy {
        case .semanticOnly:
            return semantic
        case .recencyOnly:
            let ageInDays = max(0, now.timeIntervalSince(node.createdAt) / 86400)
            return 1.0 / (1.0 + ageInDays)
        case .decayWeightedSemantic:
            return semantic * decayMultiplier(
                createdAt: node.createdAt,
                now: now,
                halfLifeDays: halfLifeDays,
                strength: decayStrength
            )
        }
    }

    private func similarity(queryEmbedding: [Double], node: ContextNode) -> Double {
        guard let data = node.embeddingData else { return 0 }
        let vector = EmbeddingService.decode(data)
        guard vector.count == queryEmbedding.count else { return 0 }
        return EmbeddingService.cosineSimilarity(queryEmbedding, vector)
    }

    /// Raw cosine over mean-pooled `NLContextualEmbedding` vectors does not use
    /// the `-1...1` its type suggests. Measured over this corpus (36 nodes x 30
    /// queries) every pair lands in `0.72...0.97`, and within a single query the
    /// 36 candidates span only ~0.14 — a max/min ratio of 1.24. The discriminating
    /// signal is the variation above that floor, not the absolute value, so the
    /// raw number is the wrong quantity to multiply anything by: a 1.24x spread
    /// against a decay term spanning 18.8x contributes nothing to the ordering.
    ///
    /// Min-max across the candidate set rescales that variation to the full
    /// `0...1`. Ranking is unchanged for `.semanticOnly` (the transform is
    /// monotone), so this costs nothing there while making the semantic term
    /// mean the same thing in both strategies the eval compares.
    ///
    /// The trade-off is that scores become set-relative: the same node scores
    /// differently against a different candidate set, and the weakest candidate
    /// always scores 0. Callers that display a score (the debug inspector) are
    /// showing a rank within one retrieval, not an absolute affinity.
    private func normalizedSimilarities(_ similarities: [Double]) -> [Double] {
        guard let lowest = similarities.min(), let highest = similarities.max() else {
            return similarities
        }
        let range = highest - lowest
        // Degenerate set (one node, or every candidate equally similar): there is
        // no variation to rescale. Return a uniform 1 rather than a uniform 0, so
        // decay and the superseded penalty still separate the nodes instead of
        // every score collapsing to zero.
        guard range > 1e-12 else { return similarities.map { _ in 1.0 } }
        return similarities.map { ($0 - lowest) / range }
    }

    /// Pure exponential decay — this is the curve the 14-day half-life decision
    /// names. Never sees `supersededByID`; kept separable from supersession
    /// down-weighting.
    private func decayFactor(createdAt: Date, now: Date, halfLifeDays: Double) -> Double {
        guard halfLifeDays > 0 else { return 1.0 }
        let ageInDays = max(0, now.timeIntervalSince(createdAt) / 86400)
        return pow(0.5, ageInDays / halfLifeDays)
    }

    /// `decayFactor` compressed toward 1 by `strength`, so decay adjusts a
    /// ranking the semantic term drives rather than replacing it. At `strength`
    /// 1 this is `decayFactor` unchanged; at 0 it is inert.
    private func decayMultiplier(
        createdAt: Date,
        now: Date,
        halfLifeDays: Double,
        strength: Double
    ) -> Double {
        let factor = decayFactor(createdAt: createdAt, now: now, halfLifeDays: halfLifeDays)
        let clamped = min(max(strength, 0), 1)
        return 1 - clamped * (1 - factor)
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
