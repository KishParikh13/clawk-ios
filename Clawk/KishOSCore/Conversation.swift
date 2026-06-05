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
    var lastReadAt: Date?
    var projectPath: String?
    var projectName: String?
    var branch: String?
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
        case lastReadAt
        case projectPath
        case projectName
        case branch
        case lastError
        case approvals
    }

    init(
        id: UUID = UUID(),
        threadId: String? = nil,
        firstMessage: String,
        now: Date = Date(),
        projectPath: String? = nil,
        projectName: String? = nil
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
        self.lastReadAt = now
        self.projectPath = projectPath
        self.projectName = projectName
        self.branch = nil
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
        lastReadAt = try container.decodeIfPresent(Date.self, forKey: .lastReadAt)
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
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

    var updatedTimestampText: String {
        Self.timestampText(for: updatedAt)
    }

    var updatedDetailText: String {
        "Updated \(updatedTimestampText)"
    }

    var displayProjectName: String {
        let clean = (projectName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Home" : clean
    }

    var projectBadgeText: String {
        let cleanBranch = (branch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanBranch.isEmpty ? displayProjectName : "\(displayProjectName) \(cleanBranch)"
    }

    var transcriptText: String {
        messages.map { message in
            let speaker = message.sender == .user ? "User" : "KishOS"
            let timestamp = Self.timestampText(for: message.createdAt)
            return "\(speaker) (\(timestamp)):\n\(message.text)"
        }
        .joined(separator: "\n\n")
    }

    static func timestampText(for date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("MMM d h:mm a")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy h:mm a")
        }
        return formatter.string(from: date)
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

    var isUnread: Bool {
        guard let lastReadAt else { return true }
        return updatedAt > lastReadAt
    }

    var needsReview: Bool {
        !approvals.isEmpty || lastError != nil || queuedUserMessageCount > 0 || (runState == .done && isUnread)
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

    func matchesSearch(_ query: String) -> Bool {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return true }

        let searchableParts: [String] = [
            title,
            idea,
            threadId,
            projectName ?? "",
            projectPath ?? "",
            branch ?? "",
            messages.map(\.text).joined(separator: " "),
            messages.flatMap { $0.attachments.map(\.title) }.joined(separator: " "),
            messages.flatMap { $0.references.map { "\($0.title) \($0.path)" } }.joined(separator: " ")
        ]

        return searchableParts.contains { part in
            part.localizedCaseInsensitiveContains(clean)
        }
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
    var references: [ChatReference]

    enum CodingKeys: String, CodingKey {
        case id
        case sender
        case text
        case createdAt
        case deliveryState
        case activityEvents
        case attachments
        case references
    }

    init(
        id: UUID = UUID(),
        sender: Sender,
        text: String,
        createdAt: Date = Date(),
        deliveryState: MessageDeliveryState = .sent,
        activityEvents: [String] = [],
        attachments: [ChatAttachment] = [],
        references: [ChatReference] = []
    ) {
        self.id = id
        self.sender = sender
        self.text = text
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.activityEvents = activityEvents
        self.attachments = attachments
        self.references = references
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
        references = try container.decodeIfPresent([ChatReference].self, forKey: .references) ?? []
    }
}

struct ChatReference: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case file
        case folder
    }

    var id: UUID
    var kind: Kind
    var title: String
    var path: String
    var repoPath: String?
    var branch: String?
    var relPath: String?
    var createdAt: Date
    var isLocked: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case path
        case repoPath
        case branch
        case relPath
        case createdAt
        case isLocked
    }

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        path: String,
        repoPath: String? = nil,
        branch: String? = nil,
        relPath: String? = nil,
        createdAt: Date = Date(),
        isLocked: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.repoPath = repoPath
        self.branch = branch
        self.relPath = relPath
        self.createdAt = createdAt
        self.isLocked = isLocked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        path = try container.decode(String.self, forKey: .path)
        repoPath = try container.decodeIfPresent(String.self, forKey: .repoPath)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        relPath = try container.decodeIfPresent(String.self, forKey: .relPath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }

    var promptToken: String {
        "@\(title)"
    }
}

struct ChatAttachment: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
        case file
        case url
    }

    enum UploadState: String, Codable, Equatable {
        case local
        case uploading
        case ready
        case failed
    }

    var id: UUID
    var kind: Kind
    var title: String
    var text: String?
    var createdAt: Date
    var mimeType: String?
    var byteCount: Int?
    var uploadId: String?
    var localFilename: String?
    var uploadState: UploadState
    var uploadError: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case text
        case createdAt
        case mimeType
        case byteCount
        case uploadId
        case localFilename
        case uploadState
        case uploadError
    }

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        text: String? = nil,
        createdAt: Date = Date(),
        mimeType: String? = nil,
        byteCount: Int? = nil,
        uploadId: String? = nil,
        localFilename: String? = nil,
        uploadState: UploadState? = nil,
        uploadError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.createdAt = createdAt
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.uploadId = uploadId
        self.localFilename = localFilename
        self.uploadState = uploadState ?? Self.defaultUploadState(kind: kind, uploadId: uploadId, localFilename: localFilename)
        self.uploadError = uploadError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount)
        uploadId = try container.decodeIfPresent(String.self, forKey: .uploadId)
        localFilename = try container.decodeIfPresent(String.self, forKey: .localFilename)
        uploadState = try container.decodeIfPresent(UploadState.self, forKey: .uploadState)
            ?? Self.defaultUploadState(kind: kind, uploadId: uploadId, localFilename: localFilename)
        uploadError = try container.decodeIfPresent(String.self, forKey: .uploadError)
    }

    static func textContext(_ text: String, title: String = "Clipboard") -> ChatAttachment {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatAttachment(kind: .text, title: title, text: clean, uploadState: .ready)
    }

    var needsUpload: Bool {
        (kind == .image || kind == .file) && uploadId == nil
    }

    var isReadyForSend: Bool {
        !needsUpload || uploadState == .ready
    }

    private static func defaultUploadState(kind: Kind, uploadId: String?, localFilename: String?) -> UploadState {
        if uploadId != nil || kind == .text || kind == .url {
            return .ready
        }
        if localFilename != nil {
            return .local
        }
        return .failed
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

struct PreparedAgentMessage: Equatable {
    let conversation: Conversation
    let message: String
    let attachments: [ChatRequestAttachment]
    let references: [ChatRequestReference]
}

func defaultAttachmentPrompt(for attachments: [ChatAttachment]) -> String {
    attachments.isEmpty ? "" : "Look at the attached file(s) and respond."
}

func defaultContextPrompt(attachments: [ChatAttachment], references: [ChatReference]) -> String {
    if !attachments.isEmpty && !references.isEmpty {
        return "Look at the attached and referenced file(s) and respond."
    }
    if !references.isEmpty {
        return "Look at the referenced file(s) and respond."
    }
    return defaultAttachmentPrompt(for: attachments)
}

func chatRequestAttachments(for attachments: [ChatAttachment]) -> [ChatRequestAttachment] {
    attachments.compactMap { attachment in
        guard let uploadId = attachment.uploadId else { return nil }
        return ChatRequestAttachment(
            id: uploadId,
            filename: attachment.title,
            mimeType: attachment.mimeType,
            kind: attachment.kind.rawValue
        )
    }
}

func chatRequestReferences(for references: [ChatReference]) -> [ChatRequestReference] {
    references.map { reference in
        ChatRequestReference(
            path: reference.path,
            title: reference.title,
            kind: reference.kind.rawValue,
            repoPath: reference.repoPath,
            branch: reference.branch,
            relPath: reference.relPath
        )
    }
}

func messageTextForAgent(_ text: String, attachments: [ChatAttachment], references: [ChatReference] = []) -> String {
    let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let userText = cleanText.isEmpty ? defaultContextPrompt(attachments: attachments, references: references) : cleanText
    guard !attachments.isEmpty || !references.isEmpty else { return cleanText }

    var contextIndex = 0
    let renderedAttachments = attachments.compactMap { attachment -> String? in
        contextIndex += 1
        switch attachment.kind {
        case .text:
            guard let text = attachment.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return """
            [Context \(contextIndex): \(attachment.title)]
            \(text)
            [/Context \(contextIndex)]
            """
        case .image, .file, .url:
            return "[Context \(contextIndex): \(attachment.title)]"
        }
    }

    let renderedReferences = references.map { reference in
        contextIndex += 1
        let kindLabel = reference.kind == .folder ? "Folder reference" : "File reference"
        var lines = [
            "[Context \(contextIndex): \(kindLabel) \(reference.promptToken)]",
            "Path: \(reference.path)",
        ]
        if let repoPath = reference.repoPath, let branch = reference.branch, let relPath = reference.relPath {
            lines.append(contentsOf: [
                "Git repo: \(repoPath)",
                "Git branch: \(branch)",
                "Repository path: \(relPath)",
                "Read exact branch content with: git -C \(repoPath) show \(branch):\(relPath)",
            ])
        }
        lines.append("[/Context \(contextIndex)]")
        return lines.joined(separator: "\n")
    }

    let renderedContexts = renderedAttachments + renderedReferences
    guard !renderedContexts.isEmpty else { return userText }
    return "\(renderedContexts.joined(separator: "\n\n"))\n\nUser message:\n\(userText)"
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
    case autonomy
    case settings
    case roadmap
}
