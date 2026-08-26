//
//  ContextEngineTests.swift
//  ThreadsTests
//

import Foundation
import Testing
import SwiftData
@testable import Threads

@Suite(.serialized)
struct ContextEngineTests {

    // MARK: - Cosine similarity on hand-computable vectors

    @Test func cosineSimilarityOnHandComputableVectors() {
        #expect(EmbeddingService.cosineSimilarity([1, 0, 0], [1, 0, 0]) == 1)
        #expect(EmbeddingService.cosineSimilarity([1, 0], [0, 1]) == 0)
        #expect(EmbeddingService.cosineSimilarity([1, 0], [-1, 0]) == -1)
    }

    // MARK: - Real embedding: 512 dimensions, L2 normalized

    @Test func embeddedStringProduces512NormalizedDimensions() async throws {
        let service = try EmbeddingService()
        let vector = try await service.embed("Some representative sentence about a workstream.")

        #expect(vector.count == 512)
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        #expect(abs(magnitude - 1) < 1e-6)
    }

    // MARK: - Data round trip, bit-exact

    @Test func embeddingDataRoundTripsBitExact() {
        var values = (0..<512).map { Double($0) * 0.001 }
        values[0] = .pi
        values[1] = .leastNormalMagnitude
        values[2] = -0.0
        values[3] = 1.0e100

        let data = EmbeddingService.encode(values)
        #expect(data.count == 512 * MemoryLayout<Double>.size)

        let decoded = EmbeddingService.decode(data)
        #expect(decoded.count == 512)
        for i in 0..<512 {
            #expect(decoded[i].bitPattern == values[i].bitPattern)
        }
    }

    // MARK: - Three strategies produce different orderings

    @Test func threeStrategiesProduceDifferentOrderings() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let queryVector = [1.0, 0.0, 0.0]

        // A: high similarity, old.
        let nodeA = ContextNode(
            content: "A",
            createdAt: now.addingTimeInterval(-60 * 86400),
            embeddingData: EmbeddingService.encode([1.0, 0.0, 0.0])
        )
        // B: low similarity, very recent.
        let nodeB = ContextNode(
            content: "B",
            createdAt: now.addingTimeInterval(-1 * 86400),
            embeddingData: EmbeddingService.encode([0.0, 1.0, 0.0])
        )
        // C: middle similarity, middle age.
        let nodeC = ContextNode(
            content: "C",
            createdAt: now.addingTimeInterval(-14 * 86400),
            embeddingData: EmbeddingService.encode([0.7071, 0.7071, 0.0])
        )

        context.insert(nodeA)
        context.insert(nodeB)
        context.insert(nodeC)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ContextNode>())
        let engine = ContextRetrievalEngine()

        func order(_ strategy: RetrievalStrategy) -> [UUID] {
            let config = RetrievalConfig(strategy: strategy)
            return engine.rankedNodes(for: queryVector, in: fetched, config: config, now: now).map(\.nodeID)
        }

        let semanticOrder = order(.semanticOnly)
        let recencyOrder = order(.recencyOnly)
        let decayOrder = order(.decayWeightedSemantic)

        #expect(semanticOrder.first == nodeA.id)
        #expect(recencyOrder.first == nodeB.id)

        let orderingsDiffer = semanticOrder != recencyOrder
            || semanticOrder != decayOrder
            || recencyOrder != decayOrder
        #expect(orderingsDiffer)
    }

    // MARK: - Decay actually decays

    @Test func decayActuallyDecays() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let sharedEmbedding = EmbeddingService.encode([1.0, 0.0, 0.0])
        let newerNode = ContextNode(content: "newer", createdAt: now, embeddingData: sharedEmbedding)
        let olderNode = ContextNode(content: "older", createdAt: now.addingTimeInterval(-30 * 86400), embeddingData: sharedEmbedding)

        context.insert(newerNode)
        context.insert(olderNode)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ContextNode>())
        let engine = ContextRetrievalEngine()
        let queryVector = [1.0, 0.0, 0.0]

        let semanticConfig = RetrievalConfig(strategy: .semanticOnly)
        let semanticScores = engine.rankedNodes(for: queryVector, in: fetched, config: semanticConfig, now: now)
        let semanticByID = Dictionary(uniqueKeysWithValues: semanticScores.map { ($0.nodeID, $0.score) })
        #expect(semanticByID[newerNode.id] == semanticByID[olderNode.id])

        let decayConfig = RetrievalConfig(strategy: .decayWeightedSemantic)
        let decayScores = engine.rankedNodes(for: queryVector, in: fetched, config: decayConfig, now: now)
        let decayByID = Dictionary(uniqueKeysWithValues: decayScores.map { ($0.nodeID, $0.score) })
        #expect(decayByID[newerNode.id]! > decayByID[olderNode.id]!)
    }

    // MARK: - Superseded node ranks below equivalent non-superseded node

    @Test func supersededNodeRanksBelowEquivalentNonSuperseded() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let sharedEmbedding = EmbeddingService.encode([1.0, 0.0, 0.0])
        let activeNode = ContextNode(content: "active", createdAt: now, embeddingData: sharedEmbedding)
        let supersededNode = ContextNode(
            content: "superseded",
            createdAt: now,
            embeddingData: sharedEmbedding,
            supersededByID: UUID()
        )

        context.insert(activeNode)
        context.insert(supersededNode)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ContextNode>())
        let engine = ContextRetrievalEngine()
        let queryVector = [1.0, 0.0, 0.0]

        let config = RetrievalConfig(strategy: .semanticOnly)
        let scores = engine.rankedNodes(for: queryVector, in: fetched, config: config, now: now)
        let byID = Dictionary(uniqueKeysWithValues: scores.map { ($0.nodeID, $0.score) })

        #expect(byID[activeNode.id]! > byID[supersededNode.id]!)
    }

    // MARK: - Token budget stops without truncating

    @Test func payloadStopsAtTokenBudgetWithoutTruncating() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let summary = String(repeating: "s", count: 40) // 10 tokens
        let matchingEmbedding = EmbeddingService.encode([1.0, 0.0, 0.0])
        let orthogonalEmbedding = EmbeddingService.encode([0.0, 1.0, 0.0])

        // node1/node2 score 1 (matching embedding); node3 scores 0 (orthogonal),
        // so it always ranks last regardless of SwiftData's unordered fetch —
        // ranking must not depend on fetch order to make this test deterministic.
        let node1 = ContextNode(content: String(repeating: "a", count: 40), createdAt: now, embeddingData: matchingEmbedding) // 10 tokens
        let node2 = ContextNode(content: String(repeating: "b", count: 40), createdAt: now.addingTimeInterval(-1), embeddingData: matchingEmbedding) // 10 tokens
        let node3 = ContextNode(content: String(repeating: "c", count: 400), createdAt: now.addingTimeInterval(-2), embeddingData: orthogonalEmbedding) // 100 tokens, won't fit

        context.insert(node1)
        context.insert(node2)
        context.insert(node3)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ContextNode>())
        let engine = ContextRetrievalEngine()
        let queryVector = [1.0, 0.0, 0.0]

        // Budget: 10 (summary) + 10 (node1) + 10 (node2) = 30 exactly; node3 (100) must not fit.
        let config = RetrievalConfig(strategy: .semanticOnly, topK: 3, tokenBudget: 30)
        let ranked = engine.rankedNodes(for: queryVector, in: fetched, config: config, now: now)
        let payload = engine.assemblePayload(
            workstreamSummary: summary,
            rankedNodes: ranked,
            recentMessages: [],
            config: config
        )

        #expect(payload.relevantNodes.count == 2)
        #expect(payload.relevantNodes.allSatisfy { $0.content.count == 40 })
        #expect(!payload.relevantNodes.contains { $0.nodeID == node3.id })
        #expect(payload.estimatedTokenCount == 30)
    }
}
