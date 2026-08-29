//
//  ThreadsApp.swift
//  Threads
//
//  Created by Anmol  Jandaur on 8/16/26.
//

import SwiftUI
import SwiftData

@main
struct ThreadsApp: App {
    var sharedModelContainer: ModelContainer
    var orchestrator: ThreadOrchestrator

    init() {
        let schema = Schema([
            Workstream.self,
            Message.self,
            ContextNode.self,
            ProactiveSurfacing.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        sharedModelContainer = container

        do {
            orchestrator = try ThreadOrchestrator.makeDefault(modelContainer: container)
        } catch {
            fatalError("Could not create ThreadOrchestrator: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ThreadView(orchestrator: orchestrator)
        }
        .modelContainer(sharedModelContainer)
    }
}
