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

    var agentStatusSummary: AgentStatusSummary? {
        if let approval = approvals.first {
            let question = approval.questions.first?.question.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = approval.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentStatusSummary(
                tone: .needsAnswer,
                title: "Needs answer",
                detail: question.isEmpty ? (summary.isEmpty ? "Question pending" : summary) : question
            )
        }

        let queuedCount = queuedUserMessageCount
        if queuedCount > 0 {
            return AgentStatusSummary(
                tone: .queued,
                title: "Saved locally",
                detail: "\(queuedCount) message\(queuedCount == 1 ? "" : "s") will send when connected."
            )
        }

        if let lastError, !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AgentStatusSummary(tone: .failed, title: "Stopped", detail: lastError)
        }

        guard isRunning else { return nil }

        let runningAgentMessage = messages.last { $0.sender == .agent && $0.deliveryState == .sending }
        let latestUserText = messages.last { $0.sender == .user }?.text ?? ""
        let latestActivity = runningAgentMessage.flatMap {
            visibleActivityEvents(for: $0, previousUserText: latestUserText, isRunning: true).last
        }

        return AgentStatusSummary(
            tone: runState == .runningTools ? .working : .running,
            title: runState == .runningTools ? "Using tools" : "Working",
            detail: latestActivity ?? "Waiting for reply"
        )
    }

    func visibleActivityEvents(for message: ChatMessage, previousUserText: String, isRunning: Bool) -> [String] {
        message.activityEvents.compactMap { event in
            let normalized = Self.normalizedActivityEvent(event)
            let normalizedMessage = Self.normalizedActivityEvent(message.text)
            let normalizedUser = Self.normalizedActivityEvent(previousUserText)
            guard !normalized.isEmpty else { return nil }
            guard !Self.isDuplicate(normalized, of: normalizedMessage) else { return nil }
            guard !Self.isDuplicate(normalized, of: normalizedUser) else { return nil }
            guard !Self.hiddenActivityEvents.contains(normalized) else { return nil }
            guard !normalized.contains("askuserquestion") else { return nil }
            if !isRunning && normalized == "waiting for reply" {
                return nil
            }
            let display = Self.displayActivityEvent(event)
            return display.isEmpty ? nil : display
        }
    }

    static func displayActivityEvent(_ text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var changed = true
        while changed {
            changed = false
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != output {
                output = trimmed
                changed = true
            }

            let textualPrefixes = ["thinking:", "reasoning:", "tool:"]
            for prefix in textualPrefixes where output.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
                output.removeFirst(prefix.count)
                changed = true
            }

            while let first = output.unicodeScalars.first,
                  !CharacterSet.alphanumerics.contains(first) {
                let second = output.dropFirst().unicodeScalars.first
                if (first == "*" || first == "-" || first == "`"),
                   let second,
                   CharacterSet.alphanumerics.contains(second) {
                    break
                }
                output.removeFirst()
                changed = true
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedActivityEvent(_ text: String) -> String {
        displayActivityEvent(text)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func isDuplicate(_ event: String, of text: String) -> Bool {
        guard !event.isEmpty, !text.isEmpty else { return false }
        let trimmedEvent = event.trimmingCharacters(in: CharacterSet(charactersIn: "…."))
        return event == text || text.hasPrefix(trimmedEvent) || event.hasPrefix(text)
    }

    private static var hiddenActivityEvents: Set<String> {
        [
            "approval needed",
            "approval answered",
            "waiting for approval",
            "question asked",
            "question answered",
            "waiting for answer"
        ]
    }
}

struct AgentStatusSummary: Equatable {
    enum Tone: Equatable {
        case running
        case working
        case needsAnswer
        case queued
        case failed
    }

    let tone: Tone
    let title: String
    let detail: String
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
