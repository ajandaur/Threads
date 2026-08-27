//
//  RetrievalEval.swift
//  ThreadsTests
//
//  Retrieval eval runner for CONTRACT_eval.md. Scores three retrieval
//  strategies over the human-labeled corpus in RetrievalSet.json and emits a
//  three-strategy comparison table.
//
//  This runner is written against the contract's public interface only. It
//  calls `rankedNodes` three ways and measures the result; it knows nothing
//  about how `baseScore`, `decayFactor`, or `supersededMultiplier` compute a
//  score. No expected score is hardcoded anywhere — every assertion below is
//  an inequality or a mechanical arithmetic check, so nothing goes stale when
//  half-life, top-K, or scoring changes.
//

import Foundation
import SwiftData
import Testing
@testable import Threads

// MARK: - Fixture decoding

/// Marker used only to locate the test bundle. There is no SPM `Bundle.module`
/// here; `RetrievalSet.json` is routed to the test target's Resources phase by
/// the `ThreadsTests` synchronized root group.
private final class EvalBundleMarker {}

struct FixtureNode: Decodable {
    let id: String
    let content: String
    let nodeType: String
    let createdAt: String
    let supersededBy: String?
}

struct FixtureQuery: Decodable {
    let query: String
    let relevantNodeIDs: [String]
    let temptingNodeIDs: [String]

    enum CodingKeys: String, CodingKey {
        case query
        case relevantNodeIDs = "relevant_node_ids"
        case temptingNodeIDs = "irrelevant_but_tempting"
    }
}

struct Fixture: Decodable {
    let nodes: [FixtureNode]
    let queries: [FixtureQuery]
}

enum EvalError: Error, CustomStringConvertible {
    case fixtureResourceMissing
    case unrecognizedNodeType(String, nodeID: String)
    case unparsableDate(String, nodeID: String)
    case danglingSupersededReference(String, fromNodeID: String)
    case malformedGeneratedUUID(String)
    case nodeMissingAfterFetch(UUID)
    case unknownFixtureNodeID(String)

    var description: String {
        switch self {
        case .fixtureResourceMissing:
            return "RetrievalSet.json is not present in the test bundle. A silently empty corpus would make every metric 0 and every inequality vacuously pass."
        case .unrecognizedNodeType(let raw, let nodeID):
            return "Node \(nodeID) has nodeType '\(raw)', which is not a ContextNodeType case."
        case .unparsableDate(let raw, let nodeID):
            return "Node \(nodeID) has createdAt '\(raw)', which is not an ISO 8601 internet date-time."
        case .danglingSupersededReference(let target, let source):
            return "Node \(source) is supersededBy '\(target)', which is not a node in the fixture."
        case .malformedGeneratedUUID(let string):
            return "Generated node UUID '\(string)' is not a valid UUID."
        case .nodeMissingAfterFetch(let uuid):
            return "Node \(uuid) was inserted but did not come back from the fetch."
        case .unknownFixtureNodeID(let id):
            return "Label references node '\(id)', which is not in the fixture."
        }
    }
}

// MARK: - Query subsets

/// The fixture's queries carry no `id` field, so a query is identified by its
/// zero-based index into the `queries` array. Each entry pairs that index with
/// the node ID the fixture labels relevant for it — a drift tripwire, checked
/// by `assertSubsetsMatchFixture` before any subset is used. Positional lists
/// would otherwise re-point silently if `RetrievalSet.json` were reordered.
///
/// The partition itself is a visible test-author decision, not something
/// re-derived from the fixture at runtime.

/// The relevant node is a successor, and at least one tempting node is the
/// predecessor it superseded. Decay should help here.
private let currentStateQueries: [(index: Int, relevantNodeID: String)] = [
    (0, "n05"), (2, "n09"), (3, "n15"), (4, "n15"), (5, "n23"), (6, "n23"),
    (7, "n24"), (8, "n24"), (9, "n29"), (10, "n29"), (11, "n15"), (12, "n09"),
]

/// The relevant node is itself superseded — the query asks for the older state
/// on purpose. Decay should hurt here.
private let historicalQueries: [(index: Int, relevantNodeID: String)] = [
    (25, "n25"), (26, "n16"), (27, "n20"), (28, "n11"), (29, "n10"),
]

/// Neither side of the query touches a supersession chain. Listed so the three
/// subsets provably partition all 30 queries.
private let unrelatedQueries: [(index: Int, relevantNodeID: String)] = [
    (1, "n06"), (13, "n06"), (14, "n06"), (15, "n03"), (16, "n03"), (17, "n08"),
    (18, "n30"), (19, "n31"), (20, "n35"), (21, "n36"), (22, "n34"), (23, "n17"),
    (24, "n26"),
]

// MARK: - Metrics

/// Precision@k divides by `k`, not by the number retrieved, so a short result
/// list is penalized rather than scored as if it were full length.
func precisionAtK(retrieved: [UUID], relevant: Set<UUID>, k: Int) -> Double {
    guard k > 0 else { return 0 }
    let hits = retrieved.prefix(k).count { relevant.contains($0) }
    return Double(hits) / Double(k)
}

func recallAtK(retrieved: [UUID], relevant: Set<UUID>, k: Int) -> Double {
    guard !relevant.isEmpty else { return 0 }
    let hits = retrieved.prefix(k).count { relevant.contains($0) }
    return Double(hits) / Double(relevant.count)
}

/// Aggregates are macro-averages: the unweighted mean across queries. Every
/// query in this fixture has exactly one relevant node, so macro- and
/// micro-averaging coincide here; macro is stated explicitly so the number
/// stays well-defined if that ever changes.
func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

// MARK: - Result types

struct EvalRow: Sendable, Equatable {
    let queryIndex: Int
    let retrievedCount: Int
    let precisionAt5: Double
    let recallAt5: Double
    let hitTemptingNode: Bool
}

struct StrategyResult: Sendable {
    let strategy: RetrievalStrategy
    let rows: [EvalRow]

    func rows(at indices: [Int]) -> [EvalRow] {
        let wanted = Set(indices)
        return rows.filter { wanted.contains($0.queryIndex) }
    }

    func meanPrecisionAt5(at indices: [Int]) -> Double {
        mean(rows(at: indices).map(\.precisionAt5))
    }

    var aggregatePrecisionAt5: Double { mean(rows.map(\.precisionAt5)) }
    var aggregateRecallAt5: Double { mean(rows.map(\.recallAt5)) }
    var aggregateTemptingHitRate: Double {
        mean(rows.map { $0.hitTemptingNode ? 1.0 : 0.0 })
    }
}

struct EvalReport: Sendable {
    let results: [StrategyResult]
    /// The labels as decoded, so the drift tripwire can check the subset lists
    /// without re-reading the fixture.
    let relevantNodeIDsByQueryIndex: [[String]]
    /// How many nodes in the built corpus actually carry a `supersededByID`.
    /// Checked against the fixture so a supersession link dropped on the way
    /// into SwiftData fails loudly — silently unlinked nodes would leave the
    /// current-state and historical assertions measuring nothing.
    let supersededNodeCount: Int

    func result(for strategy: RetrievalStrategy) -> StrategyResult? {
        results.first { $0.strategy == strategy }
    }
}

// MARK: - Harness

enum RetrievalEvalHarness {

    /// Fixed evaluation clock: 2026-08-01T00:00:00Z, one day after the newest
    /// node in the fixture. `rankedNodes` defaults `now` to `.now`, which with
    /// a 14-day half-life would drift the decay numbers on every run.
    static let evaluationNow = Date(timeIntervalSince1970: 1_785_542_400)

    static func loadFixture() throws -> Fixture {
        let bundle = Bundle(for: EvalBundleMarker.self)
        guard let url = bundle.url(forResource: "RetrievalSet", withExtension: "json") else {
            throw EvalError.fixtureResourceMissing
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Fixture node IDs are `"n01"`-style strings; `ContextNode.id` is a UUID.
    /// Deriving the UUID from the fixture array index keeps IDs identical
    /// across runs, which `Date`-free reproducibility depends on.
    private static func deterministicUUID(forIndex index: Int) throws -> UUID {
        let string = String(format: "00000000-0000-0000-0000-%012d", index)
        guard let uuid = UUID(uuidString: string) else {
            throw EvalError.malformedGeneratedUUID(string)
        }
        return uuid
    }

    /// Runs every fixture query against every requested strategy on one
    /// freshly built in-memory corpus.
    ///
    /// Nothing is cached between calls: embeddings are recomputed and the
    /// container is rebuilt from scratch each time. A memoized corpus would
    /// make the reproducibility test vacuous — it would compare a value to
    /// itself.
    static func run(strategies: [RetrievalStrategy]) async throws -> EvalReport {
        let fixture = try loadFixture()

        // Embed everything before any SwiftData object exists. The non-Sendable
        // ModelContext and [ContextNode] are then never held across an `await`.
        let service = try EmbeddingService()
        var nodeVectors: [[Double]] = []
        nodeVectors.reserveCapacity(fixture.nodes.count)
        for node in fixture.nodes {
            nodeVectors.append(try await service.embed(node.content))
        }
        var queryVectors: [[Double]] = []
        queryVectors.reserveCapacity(fixture.queries.count)
        for query in fixture.queries {
            queryVectors.append(try await service.embed(query.query))
        }

        // Fixture ID -> deterministic UUID, in one pass, so the second pass can
        // resolve forward `supersededBy` references (n10 -> n09 points ahead).
        var uuidByFixtureID: [String: UUID] = [:]
        for (index, node) in fixture.nodes.enumerated() {
            uuidByFixtureID[node.id] = try deterministicUUID(forIndex: index)
        }

        let formatter = ISO8601DateFormatter()
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        for (index, fixtureNode) in fixture.nodes.enumerated() {
            guard let nodeType = ContextNodeType(rawValue: fixtureNode.nodeType) else {
                // Deliberately not the model's `?? .fact` fallback, which would
                // mask a typo in the fixture as a silently misfiled node.
                throw EvalError.unrecognizedNodeType(fixtureNode.nodeType, nodeID: fixtureNode.id)
            }
            guard let createdAt = formatter.date(from: fixtureNode.createdAt) else {
                throw EvalError.unparsableDate(fixtureNode.createdAt, nodeID: fixtureNode.id)
            }
            var supersededByID: UUID?
            if let target = fixtureNode.supersededBy {
                guard let resolved = uuidByFixtureID[target] else {
                    throw EvalError.danglingSupersededReference(target, fromNodeID: fixtureNode.id)
                }
                supersededByID = resolved
            }

            context.insert(ContextNode(
                id: try deterministicUUID(forIndex: index),
                content: fixtureNode.content,
                nodeType: nodeType,
                createdAt: createdAt,
                // Pinned to createdAt rather than left to default to `.now`, so
                // no wall-clock value enters the model graph regardless of
                // whether scoring reads it.
                lastAccessedAt: createdAt,
                embeddingData: EmbeddingService.encode(nodeVectors[index]),
                supersededByID: supersededByID
            ))
        }
        try context.save()

        // SwiftData fetches are unordered and `sorted(by:)` is not guaranteed
        // stable, so exact score ties could reorder between runs. Re-sorting
        // into fixture order fixes the input ordering.
        let fetched = try context.fetch(FetchDescriptor<ContextNode>())
        let fetchedByID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        let orderedNodes: [ContextNode] = try fixture.nodes.indices.map { index in
            let uuid = try deterministicUUID(forIndex: index)
            guard let node = fetchedByID[uuid] else {
                throw EvalError.nodeMissingAfterFetch(uuid)
            }
            return node
        }

        let engine = ContextRetrievalEngine()
        var results: [StrategyResult] = []

        for strategy in strategies {
            // Defaults for everything else (topK 5, halfLifeDays 14,
            // supersededPenalty 0.5), so the configs differ by strategy alone.
            let config = RetrievalConfig(strategy: strategy)
            var rows: [EvalRow] = []

            for (queryIndex, fixtureQuery) in fixture.queries.enumerated() {
                // `rankedNodes`, not `retrieve`: `retrieve` routes through
                // `assemblePayload`, which applies `config.tokenBudget` and can
                // drop a node that ranked in the top 5. That would confound the
                // metric with a budgeting concern the contract does not ask
                // about.
                let ranked = engine.rankedNodes(
                    for: queryVectors[queryIndex],
                    in: orderedNodes,
                    config: config,
                    now: evaluationNow
                )
                let topK = Array(ranked.prefix(config.topK)).map(\.nodeID)

                let relevant = Set(try fixtureQuery.relevantNodeIDs.map {
                    guard let uuid = uuidByFixtureID[$0] else {
                        throw EvalError.unknownFixtureNodeID($0)
                    }
                    return uuid
                })
                let tempting = Set(try fixtureQuery.temptingNodeIDs.map {
                    guard let uuid = uuidByFixtureID[$0] else {
                        throw EvalError.unknownFixtureNodeID($0)
                    }
                    return uuid
                })

                rows.append(EvalRow(
                    queryIndex: queryIndex,
                    retrievedCount: topK.count,
                    precisionAt5: precisionAtK(retrieved: topK, relevant: relevant, k: config.topK),
                    recallAt5: recallAtK(retrieved: topK, relevant: relevant, k: config.topK),
                    hitTemptingNode: !tempting.isDisjoint(with: topK)
                ))
            }

            results.append(StrategyResult(strategy: strategy, rows: rows))
        }

        return EvalReport(
            results: results,
            relevantNodeIDsByQueryIndex: fixture.queries.map(\.relevantNodeIDs),
            supersededNodeCount: orderedNodes.count { $0.supersededByID != nil }
        )
    }
}

// MARK: - Reporting

func displayName(_ strategy: RetrievalStrategy) -> String {
    switch strategy {
    case .semanticOnly: return "semantic-only"
    case .recencyOnly: return "recency-only"
    case .decayWeightedSemantic: return "decay-weighted semantic"
    }
}

private func fixed(_ value: Double) -> String {
    String(format: "%.4f", value)
}

private func padded(_ text: String) -> String {
    text.padding(toLength: 23, withPad: " ", startingAt: 0)
}

/// Builds the comparison table fresh on every run. Nothing is written to disk
/// and no numbers are checked in, so a change to half-life, top-K, or scoring
/// produces a new table rather than a patched one.
func markdownReport(_ report: EvalReport) -> String {
    var out = "## Retrieval eval — three-strategy comparison\n\n"
    out += "36 nodes, 30 queries, top-5, evaluation clock 2026-08-01T00:00:00Z.\n\n"

    out += "| Strategy | Precision@5 | Recall@5 | Tempting node in top-5 |\n"
    out += "| --- | --- | --- | --- |\n"
    for result in report.results {
        out += "| \(padded(displayName(result.strategy)))"
        out += " | \(fixed(result.aggregatePrecisionAt5))"
        out += " | \(fixed(result.aggregateRecallAt5))"
        out += " | \(fixed(result.aggregateTemptingHitRate)) |\n"
    }

    out += "\n### Subset breakdown — precision@5\n\n"
    out += "| Strategy | Current-state (n=\(currentStateQueries.count))"
    out += " | Historical (n=\(historicalQueries.count))"
    out += " | Unrelated (n=\(unrelatedQueries.count)) |\n"
    out += "| --- | --- | --- | --- |\n"
    for result in report.results {
        out += "| \(padded(displayName(result.strategy)))"
        out += " | \(fixed(result.meanPrecisionAt5(at: currentStateQueries.map(\.index))))"
        out += " | \(fixed(result.meanPrecisionAt5(at: historicalQueries.map(\.index))))"
        out += " | \(fixed(result.meanPrecisionAt5(at: unrelatedQueries.map(\.index)))) |\n"
    }

    out += """

    Notes on reading these numbers:
    - Every query in the fixture has exactly one relevant node, so precision@5
      is exactly recall@5 ÷ 5 at every level of aggregation. The two columns are
      not independent evidence; the tempting-node column is the only aggregate
      carrying signal the other two do not.
    - The subset means rest on 12 and 5 queries. One query flipping moves the
      historical mean by 0.04 precision. Treat a passing subset inequality as
      weak evidence, not a headline.

    """
    return out
}

// MARK: - Tests

@Suite(.serialized)
struct RetrievalEvalTests {

    private static let allStrategies: [RetrievalStrategy] =
        [.semanticOnly, .recencyOnly, .decayWeightedSemantic]

    // MARK: Tier 1 — mechanical correctness of the metric arithmetic

    @Test func metricArithmeticOnSyntheticFixture() {
        // Five retrieved nodes; three labeled relevant, two of which were
        // retrieved. Hand-computable: precision = 2/5, recall = 2/3.
        let retrieved = (0..<5).map { _ in UUID() }
        let unretrievedRelevant = UUID()
        let relevant: Set<UUID> = [retrieved[1], retrieved[3], unretrievedRelevant]

        #expect(precisionAtK(retrieved: retrieved, relevant: relevant, k: 5) == 0.4)
        #expect(recallAtK(retrieved: retrieved, relevant: relevant, k: 5) == 2.0 / 3.0)
    }

    @Test func precisionDividesByKNotByRetrievedCount() {
        // Only two retrieved, one of them relevant. Precision@5 is 1/5, not
        // 1/2 — a short result list must not score as if it were full length.
        let retrieved = (0..<2).map { _ in UUID() }
        let relevant: Set<UUID> = [retrieved[0]]

        #expect(precisionAtK(retrieved: retrieved, relevant: relevant, k: 5) == 0.2)
        #expect(recallAtK(retrieved: retrieved, relevant: relevant, k: 5) == 1.0)
    }

    @Test func aggregationIsMeanNotSum() {
        let result = StrategyResult(strategy: .semanticOnly, rows: [
            EvalRow(queryIndex: 0, retrievedCount: 5, precisionAt5: 0.2, recallAt5: 1.0, hitTemptingNode: true),
            EvalRow(queryIndex: 1, retrievedCount: 5, precisionAt5: 0.0, recallAt5: 0.0, hitTemptingNode: false),
        ])

        #expect(result.aggregatePrecisionAt5 == 0.1)
        #expect(result.aggregateRecallAt5 == 0.5)
        #expect(result.aggregateTemptingHitRate == 0.5)
        #expect(result.meanPrecisionAt5(at: [1]) == 0.0)
    }

    // MARK: Tier 2 — the real corpus

    @Test(arguments: [RetrievalStrategy.semanticOnly, .recencyOnly, .decayWeightedSemantic])
    func strategyExecutesAllQueries(_ strategy: RetrievalStrategy) async throws {
        let report = try await RetrievalEvalHarness.run(strategies: [strategy])
        let result = try #require(report.result(for: strategy))

        #expect(result.rows.count == 30)
        #expect(result.rows.map(\.queryIndex) == Array(0..<30))
        for row in result.rows {
            #expect(row.retrievedCount == 5, "query \(row.queryIndex) returned \(row.retrievedCount) nodes")
            #expect((0...1).contains(row.precisionAt5), "query \(row.queryIndex) precision \(row.precisionAt5)")
            #expect((0...1).contains(row.recallAt5), "query \(row.queryIndex) recall \(row.recallAt5)")
        }
    }

    @Test func subsetIndicesStillMatchFixtureLabels() throws {
        let fixture = try RetrievalEvalHarness.loadFixture()
        #expect(fixture.nodes.count == 36)
        #expect(fixture.queries.count == 30)

        let all = currentStateQueries + historicalQueries + unrelatedQueries
        #expect(Set(all.map(\.index)) == Set(0..<30), "the three subsets must partition all 30 queries")
        #expect(all.count == 30, "no query may appear in two subsets")

        for entry in all {
            #expect(
                fixture.queries[entry.index].relevantNodeIDs == [entry.relevantNodeID],
                "query index \(entry.index) is labeled relevant to \(fixture.queries[entry.index].relevantNodeIDs), not [\(entry.relevantNodeID)] — RetrievalSet.json may have been reordered"
            )
        }
    }

    @Test func comparisonTable() async throws {
        let report = try await RetrievalEvalHarness.run(strategies: Self.allStrategies)

        // Supersession is the mechanism the current-state and historical
        // assertions below actually test. If the links did not survive the
        // trip into SwiftData, those assertions would measure nothing.
        let fixture = try RetrievalEvalHarness.loadFixture()
        let expectedSuperseded = fixture.nodes.count { $0.supersededBy != nil }
        #expect(expectedSuperseded == 6)
        #expect(report.supersededNodeCount == expectedSuperseded)

        let table = markdownReport(report)
        print(table)
        Attachment.record(table, named: "retrieval-eval.md")

        let semantic = try #require(report.result(for: .semanticOnly))
        let recency = try #require(report.result(for: .recencyOnly))
        let decay = try #require(report.result(for: .decayWeightedSemantic))

        let currentState = currentStateQueries.map(\.index)
        #expect(
            decay.meanPrecisionAt5(at: currentState) >= semantic.meanPrecisionAt5(at: currentState),
            "decay-weighted \(decay.meanPrecisionAt5(at: currentState)) < semantic-only \(semantic.meanPrecisionAt5(at: currentState)) on current-state queries"
        )

        let historical = historicalQueries.map(\.index)
        #expect(
            semantic.meanPrecisionAt5(at: historical) >= decay.meanPrecisionAt5(at: historical),
            "semantic-only \(semantic.meanPrecisionAt5(at: historical)) < decay-weighted \(decay.meanPrecisionAt5(at: historical)) on historical queries"
        )

        #expect(
            decay.aggregatePrecisionAt5 > recency.aggregatePrecisionAt5,
            "decay-weighted \(decay.aggregatePrecisionAt5) is not above recency-only \(recency.aggregatePrecisionAt5) across all 30"
        )
    }

    // MARK: Tier 3 — reproducibility

    @Test func reproducibleAcrossRuns() async throws {
        let first = try await RetrievalEvalHarness.run(strategies: Self.allStrategies)
        let second = try await RetrievalEvalHarness.run(strategies: Self.allStrategies)

        #expect(first.results.count == second.results.count)
        for (lhs, rhs) in zip(first.results, second.results) {
            #expect(lhs.strategy == rhs.strategy)
            #expect(lhs.rows.count == rhs.rows.count)
            for (a, b) in zip(lhs.rows, rhs.rows) {
                #expect(a.queryIndex == b.queryIndex)
                #expect(a.precisionAt5.bitPattern == b.precisionAt5.bitPattern)
                #expect(a.recallAt5.bitPattern == b.recallAt5.bitPattern)
                #expect(a.hitTemptingNode == b.hitTemptingNode)
            }
            #expect(lhs.aggregatePrecisionAt5.bitPattern == rhs.aggregatePrecisionAt5.bitPattern)
            #expect(lhs.aggregateRecallAt5.bitPattern == rhs.aggregateRecallAt5.bitPattern)
        }

        #expect(markdownReport(first) == markdownReport(second))
    }
}
