import Foundation
import SwiftData

// MARK: - SwiftData Models for Persistent Chat History

@Model
class PersistedMessage {
    @Attribute(.unique) var id: String
    var sessionId: String
    var role: String
    var content: String
    var timestamp: Date
    var thinking: String?
    var agentId: String?
    var agentName: String?
    var agentEmoji: String?
    var toolCallsData: Data?
    
    init(
        id: String = UUID().uuidString,
        sessionId: String,
        role: String,
        content: String,
        timestamp: Date = Date(),
        thinking: String? = nil,
        agentId: String? = nil,
        agentName: String? = nil,
        agentEmoji: String? = nil,
        toolCalls: [PersistedToolCall]? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.thinking = thinking
        self.agentId = agentId
        self.agentName = agentName
        self.agentEmoji = agentEmoji
        if let toolCalls = toolCalls {
            self.toolCallsData = try? JSONEncoder().encode(toolCalls)
        }
    }
    
    var toolCalls: [PersistedToolCall]? {
        guard let data = toolCallsData else { return nil }
        return try? JSONDecoder().decode([PersistedToolCall].self, from: data)
    }
}

struct PersistedToolCall: Codable {
    let id: String
    let name: String
    let arguments: [String: String]
    let timestamp: Date
    var result: String?
    var durationMs: Int?
}

@Model
class PersistedSession {
    @Attribute(.unique) var id: String
    var agentId: String?
    var agentName: String
    var agentEmoji: String
    var agentColor: String
    var createdAt: Date
    var lastActivityAt: Date
    var messageCount: Int
    var totalCost: Double
    var isArchived: Bool
    
    @Relationship(deleteRule: .cascade, inverse: \PersistedMessage.sessionId)
    var messages: [PersistedMessage]?
    
    init(
        id: String = UUID().uuidString,
        agentId: String? = nil,
        agentName: String,
        agentEmoji: String = "🤖",
        agentColor: String = "#6B7280",
        createdAt: Date = Date(),
        lastActivityAt: Date = Date(),
        messageCount: Int = 0,
        totalCost: Double = 0,
        isArchived: Bool = false
    ) {
        self.id = id
        self.agentId = agentId
        self.agentName = agentName
        self.agentEmoji = agentEmoji
        self.agentColor = agentColor
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.messageCount = messageCount
        self.totalCost = totalCost
        self.isArchived = isArchived
    }
}

@Model
class AgentIdentityRecord {
    @Attribute(.unique) var agentId: String
    var name: String
    var creature: String
    var vibe: String?
    var emoji: String
    var color: String
    var lastUpdated: Date
    
    init(
        agentId: String,
        name: String,
        creature: String,
        vibe: String? = nil,
        emoji: String = "🤖",
        color: String = "#6B7280",
        lastUpdated: Date = Date()
    ) {
        self.agentId = agentId
        self.name = name
        self.creature = creature
        self.vibe = vibe
        self.emoji = emoji
        self.color = color
        self.lastUpdated = lastUpdated
    }
}

// MARK: - Chat History Store

import SwiftUI

@Observable
class ChatHistoryStore {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    
    init() {
        let schema = Schema([PersistedMessage.self, PersistedSession.self, AgentIdentityRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
            modelContext = ModelContext(modelContainer)
        } catch {
            fatalError("Failed to initialize SwiftData: \(error)")
        }
    }
    
    // MARK: - Sessions
    
    func fetchSessions() -> [PersistedSession] {
        let descriptor = FetchDescriptor<PersistedSession>(
            sortBy: [SortDescriptor(\.lastActivityAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
    
    func fetchSession(id: String) -> PersistedSession? {
        let descriptor = FetchDescriptor<PersistedSession>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }
    
    func createSession(
        agentId: String? = nil,
        agentName: String,
        agentEmoji: String = "🤖",
        agentColor: String = "#6B7280"
    ) -> PersistedSession {
        let session = PersistedSession(
            agentId: agentId,
            agentName: agentName,
            agentEmoji: agentEmoji,
            agentColor: agentColor
        )
        modelContext.insert(session)
        try? modelContext.save()
        return session
    }
    
    func updateSessionActivity(_ session: PersistedSession) {
        session.lastActivityAt = Date()
        try? modelContext.save()
    }
    
    func archiveSession(_ session: PersistedSession) {
        session.isArchived = true
        try? modelContext.save()
    }
    
    // MARK: - Messages
    
    func fetchMessages(for sessionId: String) -> [PersistedMessage] {
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
    
    func addMessage(
        to sessionId: String,
        role: String,
        content: String,
        thinking: String? = nil,
        agentId: String? = nil,
        agentName: String? = nil,
        agentEmoji: String? = nil
    ) -> PersistedMessage {
        let message = PersistedMessage(
            sessionId: sessionId,
            role: role,
            content: content,
            thinking: thinking,
            agentId: agentId,
            agentName: agentName,
            agentEmoji: agentEmoji
        )
        modelContext.insert(message)
        
        // Update session
        if let session = fetchSession(id: sessionId) {
            session.messageCount += 1
            session.lastActivityAt = Date()
        }
        
        try? modelContext.save()
        return message
    }
    
    func deleteMessage(_ message: PersistedMessage) {
        modelContext.delete(message)
        try? modelContext.save()
    }
    
    // MARK: - Agent Identity
    
    func fetchAgentIdentity(agentId: String) -> AgentIdentityRecord? {
        let descriptor = FetchDescriptor<AgentIdentityRecord>(
            predicate: #Predicate { $0.agentId == agentId }
        )
        return try? modelContext.fetch(descriptor).first
    }
    
    func saveAgentIdentity(
        agentId: String,
        name: String,
        creature: String,
        vibe: String? = nil,
        emoji: String = "🤖",
        color: String = "#6B7280"
    ) {
        if let existing = fetchAgentIdentity(agentId: agentId) {
            existing.name = name
            existing.creature = creature
            existing.vibe = vibe
            existing.emoji = emoji
            existing.color = color
            existing.lastUpdated = Date()
        } else {
            let identity = AgentIdentityRecord(
                agentId: agentId,
                name: name,
                creature: creature,
                vibe: vibe,
                emoji: emoji,
                color: color
            )
            modelContext.insert(identity)
        }
        try? modelContext.save()
    }
    
    // MARK: - Import from Gateway
    
    func importGatewayMessages(
        _ messages: [GatewayMessage],
        sessionId: String,
        agentId: String? = nil
    ) {
        for message in messages {
            // Check if message already exists
            let descriptor = FetchDescriptor<PersistedMessage>(
                predicate: #Predicate { $0.id == message.id }
            )
            if (try? modelContext.fetch(descriptor).first) != nil {
                continue // Skip duplicates
            }
            
            let persisted = PersistedMessage(
                id: message.id,
                sessionId: sessionId,
                role: message.role,
                content: message.content,
                timestamp: message.timestamp,
                thinking: message.thinking,
                agentId: agentId
            )
            modelContext.insert(persisted)
        }
        try? modelContext.save()
    }
}
