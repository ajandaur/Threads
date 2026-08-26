//
//  SwiftDataModels.swift
//  Threads
//

import Foundation
import SwiftData

// MARK: - Enums (stored as raw String on the models, never as a stored enum property)

enum WorkstreamStatus: String, Codable, CaseIterable, Sendable {
    case active, archived, resolved
}

enum MessageRole: String, Codable, CaseIterable, Sendable {
    case user, assistant, system
}

enum ContextNodeType: String, Codable, CaseIterable, Sendable {
    case fact, decision, openQuestion, reference, actionItem, insight
}

// MARK: - Workstream

@Model
final class Workstream {
    #Unique<Workstream>([\.id])
    #Index<Workstream>([\.updatedAt])

    var id: UUID = UUID()
    var title: String = ""
    var summary: String = ""
    var status: String = WorkstreamStatus.active.rawValue
    var isPinned: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var compactContext: String = ""
    var tags: [String] = []

    @Relationship(deleteRule: .cascade, inverse: \Message.workstream)
    var messages: [Message] = []

    @Relationship(deleteRule: .cascade, inverse: \ContextNode.workstream)
    var contextNodes: [ContextNode] = []

    var statusValue: WorkstreamStatus {
        get { WorkstreamStatus(rawValue: status) ?? .active }
        set { status = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String = "",
        summary: String = "",
        status: WorkstreamStatus = .active,
        isPinned: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        compactContext: String = "",
        tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.status = status.rawValue
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.compactContext = compactContext
        self.tags = tags
    }
}

// MARK: - Message

@Model
final class Message {
    #Unique<Message>([\.id])
    #Index<Message>([\.createdAt])

    var id: UUID = UUID()
    var role: String = MessageRole.user.rawValue
    var content: String = ""
    var createdAt: Date = Date.now
    var contentBlocksData: Data? = nil
    var isEmbedded: Bool = false
    var estimatedTokens: Int = 0
    var workstream: Workstream?

    var roleValue: MessageRole {
        get { MessageRole(rawValue: role) ?? .user }
        set { role = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        role: MessageRole = .user,
        content: String = "",
        createdAt: Date = .now,
        contentBlocksData: Data? = nil,
        isEmbedded: Bool = false,
        estimatedTokens: Int = 0,
        workstream: Workstream? = nil
    ) {
        self.id = id
        self.role = role.rawValue
        self.content = content
        self.createdAt = createdAt
        self.contentBlocksData = contentBlocksData
        self.isEmbedded = isEmbedded
        self.estimatedTokens = estimatedTokens
        self.workstream = workstream
    }
}

// MARK: - ContextNode

@Model
final class ContextNode {
    #Unique<ContextNode>([\.id])
    #Index<ContextNode>([\.createdAt])

    var id: UUID = UUID()
    var content: String = ""
    var nodeType: String = ContextNodeType.fact.rawValue
    var createdAt: Date = Date.now
    var lastAccessedAt: Date = Date.now
    var embeddingData: Data? = nil
    var relevanceScore: Double = 1.0
    var sourceMessageID: UUID? = nil
    var supersededByID: UUID? = nil
    var extractionConfidence: Double = 1.0
    var workstream: Workstream?

    var nodeTypeValue: ContextNodeType {
        get { ContextNodeType(rawValue: nodeType) ?? .fact }
        set { nodeType = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        content: String = "",
        nodeType: ContextNodeType = .fact,
        createdAt: Date = .now,
        lastAccessedAt: Date = .now,
        embeddingData: Data? = nil,
        relevanceScore: Double = 1.0,
        sourceMessageID: UUID? = nil,
        supersededByID: UUID? = nil,
        extractionConfidence: Double = 1.0,
        workstream: Workstream? = nil
    ) {
        self.id = id
        self.content = content
        self.nodeType = nodeType.rawValue
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.embeddingData = embeddingData
        self.relevanceScore = relevanceScore
        self.sourceMessageID = sourceMessageID
        self.supersededByID = supersededByID
        self.extractionConfidence = extractionConfidence
        self.workstream = workstream
    }
}

// MARK: - ProactiveSurfacing

@Model
final class ProactiveSurfacing {
    #Unique<ProactiveSurfacing>([\.id])
    #Index<ProactiveSurfacing>([\.createdAt])

    var id: UUID = UUID()
    var content: String = ""
    var triggerReason: String = ""
    var createdAt: Date = Date.now
    var wasEngaged: Bool = false
    var relatedWorkstreamID: UUID? = nil

    init(
        id: UUID = UUID(),
        content: String = "",
        triggerReason: String = "",
        createdAt: Date = .now,
        wasEngaged: Bool = false,
        relatedWorkstreamID: UUID? = nil
    ) {
        self.id = id
        self.content = content
        self.triggerReason = triggerReason
        self.createdAt = createdAt
        self.wasEngaged = wasEngaged
        self.relatedWorkstreamID = relatedWorkstreamID
    }
}
