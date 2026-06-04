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

    var queuedUserMessageCount: Int {
        messages.filter { $0.sender == .user && $0.deliveryState == .queued }.count
    }

    var runState: ConversationRunState {
        if !approvals.isEmpty {
            return .waitingForQuestion
        }
        if queuedUserMessageCount > 0 {
            return .queued
        }
        if lastError != nil {
            return .failed
        }
        if isRunning {
            let agentEvents = messages
                .filter { $0.sender == .agent && $0.deliveryState == .sending }
                .flatMap(\.activityEvents)
            if agentEvents.contains(where: { $0.localizedCaseInsensitiveContains("tool:") }) {
                return .runningTools
            }
            return .sending
        }
        return .done
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
    var attachments: [ChatAttachment]

    enum CodingKeys: String, CodingKey {
        case id
        case sender
        case text
        case createdAt
        case deliveryState
        case activityEvents
        case attachments
    }

    init(
        id: UUID = UUID(),
        sender: Sender,
        text: String,
        createdAt: Date = Date(),
        deliveryState: MessageDeliveryState = .sent,
        activityEvents: [String] = [],
        attachments: [ChatAttachment] = []
    ) {
        self.id = id
        self.sender = sender
        self.text = text
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.activityEvents = activityEvents
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sender = try container.decode(Sender.self, forKey: .sender)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        deliveryState = try container.decode(MessageDeliveryState.self, forKey: .deliveryState)
        activityEvents = try container.decodeIfPresent([String].self, forKey: .activityEvents) ?? []
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
    }
}

struct ChatAttachment: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
        case file
        case url
    }

    var id: UUID
    var kind: Kind
    var title: String
    var text: String?
    var createdAt: Date

    init(id: UUID = UUID(), kind: Kind, title: String, text: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.createdAt = createdAt
    }

    static func textContext(_ text: String, title: String = "Clipboard") -> ChatAttachment {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatAttachment(kind: .text, title: title, text: clean)
    }
}

enum MessageDeliveryState: String, Codable {
    case queued
    case sending
    case sent
    case failed
}

enum ConversationRunState: String, Codable {
    case queued
    case sending
    case waitingForQuestion
    case runningTools
    case failed
    case done

    var label: String {
        switch self {
        case .queued:
            return "Queued"
        case .sending:
            return "Sending"
        case .waitingForQuestion:
            return "Question"
        case .runningTools:
            return "Tools"
        case .failed:
            return "Failed"
        case .done:
            return "Done"
        }
    }

    var isActive: Bool {
        self != .done
    }
}

struct QueuedMessage: Equatable {
    let conversation: Conversation
    let message: ChatMessage
}

func messageTextForAgent(_ text: String, attachments: [ChatAttachment]) -> String {
    let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !attachments.isEmpty else { return cleanText }

    let renderedAttachments = attachments.enumerated().compactMap { index, attachment -> String? in
        switch attachment.kind {
        case .text:
            guard let text = attachment.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return """
            [Context \(index + 1): \(attachment.title)]
            \(text)
            [/Context \(index + 1)]
            """
        case .image, .file, .url:
            return "[Context \(index + 1): \(attachment.title)]"
        }
    }

    guard !renderedAttachments.isEmpty else { return cleanText }
    return "\(renderedAttachments.joined(separator: "\n\n"))\n\nUser message:\n\(cleanText)"
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
