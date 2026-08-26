//
//  ModelContainerHelper.swift
//  ThreadsTests
//

import Foundation
import SwiftData
@testable import Threads

func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([
        Workstream.self,
        Message.self,
        ContextNode.self,
        ProactiveSurfacing.self,
    ])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}
