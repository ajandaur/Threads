//
//  SwiftDataModelTests.swift
//  ThreadsTests
//

import Foundation
import Testing
import SwiftData
@testable import Threads

@Suite(.serialized)
struct SwiftDataModelTests {

    // MARK: - Create and fetch, one test per model

    @Test func createAndFetchWorkstream() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let workstream = Workstream(
            title: "Test Workstream",
            summary: "A summary",
            status: .archived,
            isPinned: true,
            tags: ["tag1", "tag2"]
        )
        context.insert(workstream)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Workstream>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Test Workstream")
        #expect(fetched.first?.summary == "A summary")
        #expect(fetched.first?.statusValue == .archived)
        #expect(fetched.first?.isPinned == true)
        #expect(fetched.first?.tags == ["tag1", "tag2"])
    }

    @Test func createAndFetchMessage() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let message = Message(role: .assistant, content: "Hello", estimatedTokens: 42)
        context.insert(message)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Message>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.content == "Hello")
        #expect(fetched.first?.roleValue == .assistant)
        #expect(fetched.first?.estimatedTokens == 42)
    }

    @Test func createAndFetchContextNode() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let node = ContextNode(content: "Some fact", nodeType: .decision, relevanceScore: 0.75)
        context.insert(node)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ContextNode>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.content == "Some fact")
        #expect(fetched.first?.nodeTypeValue == .decision)
        #expect(fetched.first?.relevanceScore == 0.75)
    }

    @Test func createAndFetchProactiveSurfacing() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let surfacing = ProactiveSurfacing(content: "Heads up", triggerReason: "stale context")
        context.insert(surfacing)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ProactiveSurfacing>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.content == "Heads up")
        #expect(fetched.first?.triggerReason == "stale context")
    }

    // MARK: - Trap-check: #Predicate against the raw String property

    @Test func filterWorkstreamByStatusUsingPredicate() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let active = Workstream(title: "Active one")
        active.statusValue = .active
        let archived = Workstream(title: "Archived one")
        archived.statusValue = .archived
        let resolved = Workstream(title: "Resolved one")
        resolved.statusValue = .resolved

        context.insert(active)
        context.insert(archived)
        context.insert(resolved)
        try context.save()

        // This predicate compiles only because `status` is a stored String.
        // Against an enum-typed stored property, #Predicate does not compile.
        let target = WorkstreamStatus.archived.rawValue
        let descriptor = FetchDescriptor<Workstream>(
            predicate: #Predicate { $0.status == target }
        )
        let results = try context.fetch(descriptor)

        #expect(results.count == 1)
        #expect(results.first?.title == "Archived one")
    }

    // MARK: - Cascade delete

    @Test func deletingWorkstreamCascadesToChildren() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let workstream = Workstream(title: "Parent")
        context.insert(workstream)

        let message1 = Message(content: "m1")
        let message2 = Message(content: "m2")
        message1.workstream = workstream
        message2.workstream = workstream
        context.insert(message1)
        context.insert(message2)

        let node1 = ContextNode(content: "n1")
        let node2 = ContextNode(content: "n2")
        node1.workstream = workstream
        node2.workstream = workstream
        context.insert(node1)
        context.insert(node2)

        try context.save()

        context.delete(workstream)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Workstream>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ContextNode>()) == 0)
    }

    // MARK: - Embedding round trip

    @Test func embeddingDataRoundTripsFiveHundredTwelveDoubles() throws {
        let container = try makeInMemoryContainer()

        var values = (0..<512).map { Double($0) * 0.001 }
        values[0] = .pi
        values[1] = .leastNormalMagnitude
        values[2] = -0.0
        values[3] = 1.0e100

        let writeContext = ModelContext(container)
        let node = ContextNode(content: "embedded")
        node.embeddingData = Self.encode(values)
        writeContext.insert(node)
        try writeContext.save()

        // Read back through a fresh context so the value genuinely crosses the store.
        let readContext = ModelContext(container)
        let fetched = try readContext.fetch(FetchDescriptor<ContextNode>())
        let data = try #require(fetched.first?.embeddingData)

        #expect(data.count == 512 * MemoryLayout<Double>.size)

        let decoded = Self.decode(data)
        #expect(decoded.count == 512)
        for i in 0..<512 {
            // Bit-pattern equality, not `==`: -0.0 == 0.0 under IEEE 754,
            // which would mask a sign-bit-flipping bug during round-trip.
            #expect(decoded[i].bitPattern == values[i].bitPattern)
        }
    }

    private static func encode(_ values: [Double]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decode(_ data: Data) -> [Double] {
        var out = [Double](repeating: 0, count: data.count / MemoryLayout<Double>.size)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }
}
