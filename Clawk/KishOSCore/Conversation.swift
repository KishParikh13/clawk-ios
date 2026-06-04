import Foundation

struct Conversation: Identifiable, Codable, Equatable {
    var id: UUID
    var threadId: String
    var title: String
    var idea: String
    var messages: [ChatMessage]
    var events: [String]
    var engine: String
    var elapsedMs: Int?
    var isRunning: Bool
    var updatedAt: Date
    var lastError: String?
    var approvals: [ApprovalRequest]

    enum CodingKeys: String, CodingKey {
        case id
        case threadId
        case title
        case idea
        case messages
        case events
        case engine
        case elapsedMs
        case isRunning
        case updatedAt
        case lastError
        case approvals
    }

    init(
        id: UUID = UUID(),
        threadId: String? = nil,
        firstMessage: String,
        now: Date = Date()
    ) {
        let generatedId = id
        self.id = generatedId
        self.threadId = threadId ?? "mac-\(generatedId.uuidString.lowercased())"
        self.title = Self.title(for: firstMessage)
        self.idea = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        self.messages = [ChatMessage(sender: .user, text: firstMessage, createdAt: now)]
        self.events = ["session created", "sent to kish-agent"]
        self.engine = "claude"
        self.elapsedMs = nil
        self.isRunning = false
        self.updatedAt = now
        self.lastError = nil
        self.approvals = []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        threadId = try container.decode(String.self, forKey: .threadId)
        title = try container.decode(String.self, forKey: .title)
        idea = try container.decode(String.self, forKey: .idea)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        events = try container.decode([String].self, forKey: .events)
        engine = try container.decode(String.self, forKey: .engine)
        elapsedMs = try container.decodeIfPresent(Int.self, forKey: .elapsedMs)
        isRunning = try container.decode(Bool.self, forKey: .isRunning)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        approvals = try container.decodeIfPresent([ApprovalRequest].self, forKey: .approvals) ?? []
    }

    static func title(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New chat" }
        if trimmed.count <= 42 { return trimmed }
        return String(trimmed.prefix(41)) + "..."
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Sender: String, Codable {
        case user
        case agent
    }

    var id: UUID
    var sender: Sender
    var text: String
    var createdAt: Date
    var deliveryState: MessageDeliveryState
    var activityEvents: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case sender
        case text
        case createdAt
        case deliveryState
        case activityEvents
    }

    init(
        id: UUID = UUID(),
        sender: Sender,
        text: String,
        createdAt: Date = Date(),
        deliveryState: MessageDeliveryState = .sent,
        activityEvents: [String] = []
    ) {
        self.id = id
        self.sender = sender
        self.text = text
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.activityEvents = activityEvents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sender = try container.decode(Sender.self, forKey: .sender)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        deliveryState = try container.decode(MessageDeliveryState.self, forKey: .deliveryState)
        activityEvents = try container.decodeIfPresent([String].self, forKey: .activityEvents) ?? []
    }
}

enum MessageDeliveryState: String, Codable {
    case sending
    case sent
    case failed
}

struct ChatResult: Equatable {
    let text: String
    let engine: String
    let elapsedMs: Int?
    let events: [String]
    var approvals: [ApprovalRequest] = []
}

struct ApprovalRequest: Identifiable, Codable, Equatable {
    let id: String
    var threadId: String
    var questions: [ApprovalQuestion]
    var createdAt: Int?
    var expiresAt: Int?
    var summary: String
}

struct ApprovalQuestion: Codable, Equatable {
    var header: String
    var question: String
    var multiSelect: Bool?
    var options: [ApprovalOption]
}

struct ApprovalOption: Codable, Equatable {
    var label: String
    var description: String
}

enum SidebarSelection: Hashable {
    case newChat
    case conversation(UUID)
    case settings
    case roadmap
}
