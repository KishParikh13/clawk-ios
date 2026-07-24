import Foundation

@MainActor
final class KishAgentClient: ObservableObject {
    static let defaultBaseURL = URL(string: "http://kishs-mac-mini-1:17891")!
    private static let agentURLDefaultsKey = "KishOSAgentBaseURL"

    @Published private var activeSendCount = 0
    @Published var status = "Checking"
    @Published var miniStatus = "Checking"
    @Published var httpStatus = "Checking"
    @Published var agentStatus = "Checking"
    @Published var chatStatus = "Idle"
    @Published var agentProtocolStatus = "Checking"
    @Published var detail = "Starting up"
    @Published var toolInventory = ToolInventory.empty
    @Published var toolInventoryStatus = "Checking"
    @Published var agentURLString: String

    private var baseURL: URL
    private let session: URLSession
    private let userDefaults: UserDefaults
    private var pollingStarted = false

    var isSending: Bool {
        activeSendCount > 0
    }

    var isDisconnected: Bool {
        status == "Offline" || httpStatus == "Offline" || agentStatus == "Offline" || chatStatus == "Offline"
    }

    var canSendQueuedMessages: Bool {
        !isSending && httpStatus == "Online" && agentStatus == "Online" && chatStatus == "Ready"
    }

    init(
        baseURL: URL? = nil,
        session: URLSession = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        let savedURL = userDefaults.string(forKey: Self.agentURLDefaultsKey).flatMap(URL.init(string:))
        self.baseURL = baseURL ?? savedURL ?? Self.defaultBaseURL
        self.agentURLString = Self.displayString(for: self.baseURL)
        self.session = session
    }

    @discardableResult
    func updateBaseURL(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              url.host != nil
        else {
            detail = "Invalid agent URL"
            status = "Error"
            return false
        }

        baseURL = url
        agentURLString = Self.displayString(for: url)
        userDefaults.set(agentURLString, forKey: Self.agentURLDefaultsKey)
        markChecking()
        return true
    }

    func resetBaseURL() {
        baseURL = Self.defaultBaseURL
        agentURLString = Self.displayString(for: Self.defaultBaseURL)
        userDefaults.removeObject(forKey: Self.agentURLDefaultsKey)
        markChecking()
    }

    func reconnect() async {
        await refreshHealth()
    }

    func startHealthPolling() async {
        guard !pollingStarted else { return }
        pollingStarted = true

        while !Task.isCancelled {
            await refreshHealth()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func refreshHealth() async {
        if isSending { return }
        markChecking()

        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 8

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let health = try Self.decoder.decode(HealthResponse.self, from: data)

            if statusCode == 200 && health.ok {
                miniStatus = "Online"
                httpStatus = "Online"
                agentStatus = "Online"
                agentProtocolStatus = Self.agentProtocolStatus(for: health)
                chatStatus = "Ready"
                status = "Ready"
                detail = Self.healthDetail(for: health)
                await refreshToolInventory()
            } else if statusCode == 200 {
                markAgentUnavailable("kish-agent is not ready")
            } else {
                markBridgeError("kish-agent returned HTTP \(statusCode)")
            }
        } catch let error as URLError {
            markNetworkError(error)
        } catch {
            markBridgeError("Unexpected health response")
        }
    }

    func send(
        _ message: String,
        threadId: String,
        attachments: [ChatRequestAttachment] = [],
        references: [ChatRequestReference] = [],
        projectPath: String? = nil
    ) async throws -> ChatResult {
        beginSending()
        defer { endSending() }

        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 180
            request.httpBody = try JSONEncoder().encode(ChatRequest(threadId: threadId, message: message, conversationId: nil, attachments: attachments, references: references, projectPath: projectPath))

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)

            if decoded.ok, let text = decoded.text {
                status = "Ready"
                chatStatus = "Ready"
                detail = "Reply received"
                return ChatResult(
                    text: text,
                    engine: decoded.engine ?? "claude",
                    elapsedMs: decoded.elapsedMs,
                    events: decoded.events ?? [],
                    approvals: decoded.approvals ?? []
                )
            }

            status = "Error"
            chatStatus = "Error"
            let message = decoded.error ?? "Agent returned HTTP \(statusCode)"
            detail = message
            markChatRequestFailure(message)
            throw AgentClientError.requestFailed(message)
        } catch let error as URLError {
            markNetworkError(error)
            let mapped = AgentClientError.network(error)
            throw mapped
        } catch {
            status = "Error"
            chatStatus = "Error"
            detail = error.localizedDescription
            throw error
        }
    }

    func sendStreaming(
        _ message: String,
        threadId: String,
        conversationId: UUID? = nil,
        attachments: [ChatRequestAttachment] = [],
        references: [ChatRequestReference] = [],
        projectPath: String? = nil,
        onEvent: @escaping (AgentStreamEvent) async -> Void
    ) async throws -> ChatResult {
        beginSending()
        defer { endSending() }

        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("chat-stream"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 180
            request.httpBody = try JSONEncoder().encode(ChatRequest(threadId: threadId, message: message, conversationId: conversationId, attachments: attachments, references: references, projectPath: projectPath))

            let (bytes, response) = try await session.bytes(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                markChatRequestFailure("Agent returned HTTP \(statusCode)")
                throw AgentClientError.requestFailed("Agent returned HTTP \(statusCode)")
            }

            var final: ChatResult?
            for try await line in bytes.lines {
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let data = Data(line.utf8)
                let event = try JSONDecoder().decode(AgentStreamEvent.self, from: data)
                await onEvent(event)

                if event.type == "final" {
                    if event.cancelled == true {
                        status = "Ready"
                        chatStatus = "Ready"
                        detail = "Stopped"
                        throw AgentClientError.cancelled
                    } else if event.ok == true, let text = event.text {
                        final = ChatResult(
                            text: text,
                            engine: event.engine ?? "claude",
                            elapsedMs: event.elapsedMs,
                            events: event.events ?? [],
                            approvals: event.approvals ?? []
                        )
                    } else {
                        throw AgentClientError.requestFailed(event.error ?? "Agent stream failed")
                    }
                } else if event.type == "status", let eventStatus = event.status {
                    status = eventStatus == "waiting_approval" ? "Question" : "Sending"
                    chatStatus = eventStatus == "waiting_approval" ? "Question" : "Sending"
                    detail = eventStatus
                }
            }

            guard let final else {
                throw AgentClientError.requestFailed("Agent stream ended without a final response")
            }

            status = "Ready"
            chatStatus = "Ready"
            detail = "Reply received"
            return final
        } catch AgentClientError.cancelled {
            status = "Ready"
            chatStatus = "Ready"
            detail = "Stopped"
            throw AgentClientError.cancelled
        } catch let error as URLError {
            if error.code == .cancelled {
                status = "Ready"
                chatStatus = "Ready"
                detail = "Stopped"
                throw AgentClientError.cancelled
            }
            markNetworkError(error)
            let mapped = AgentClientError.network(error)
            throw mapped
        } catch {
            status = "Error"
            chatStatus = "Error"
            detail = error.localizedDescription
            throw error
        }
    }

    func cancel(threadId: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("cancel"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        request.httpBody = try JSONEncoder().encode(CancelRequest(threadId: threadId))

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let decoded = try JSONDecoder().decode(BasicResponse.self, from: data)
            guard statusCode == 200, decoded.ok else {
                throw AgentClientError.requestFailed(decoded.error ?? "Cancel returned HTTP \(statusCode)")
            }
            status = "Ready"
            chatStatus = "Ready"
            detail = "Stopped"
        } catch let error as URLError {
            throw AgentClientError.network(error)
        }
    }

    func uploadAttachment(
        _ payload: PendingAttachmentPayload,
        conversationId: UUID? = nil,
        threadId: String? = nil
    ) async throws -> UploadedAttachment {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("attachments"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            payload: payload,
            conversationId: conversationId,
            threadId: threadId
        )

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let decoded = try Self.decoder.decode(AttachmentUploadResponse.self, from: data)
            guard statusCode == 200, decoded.ok, let attachment = decoded.attachment else {
                let message = decoded.error ?? "Attachment upload returned HTTP \(statusCode)"
                throw AgentClientError.requestFailed(message)
            }
            return attachment
        } catch let error as URLError {
            markNetworkError(error)
            throw AgentClientError.network(error)
        } catch {
            throw error
        }
    }

    func answerApproval(_ approvalId: String, approved: Bool, answer: String? = nil) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("approve"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(ApprovalAnswerRequest(approvalId: approvalId, approved: approved, answer: answer))

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try JSONDecoder().decode(BasicResponse.self, from: data)
        guard statusCode == 200 && decoded.ok else {
            throw AgentClientError.requestFailed(decoded.error ?? "Approval failed")
        }
    }

    func fetchConversations() async throws -> [Conversation] {
        var request = URLRequest(url: baseURL.appendingPathComponent("conversations"))
        request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try Self.decoder.decode(ConversationListResponse.self, from: data)
        guard statusCode == 200 && decoded.ok else {
            throw AgentClientError.requestFailed(decoded.error ?? "Conversation sync returned HTTP \(statusCode)")
        }
        return decoded.conversations
    }

    func fetchProjects(all: Bool = false) async throws -> [Project] {
        var components = URLComponents(url: baseURL.appendingPathComponent("projects"), resolvingAgainstBaseURL: false)!
        if all {
            components.queryItems = [URLQueryItem(name: "all", value: "1")]
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try Self.decoder.decode(ProjectListResponse.self, from: data)
        guard statusCode == 200 && decoded.ok else {
            throw AgentClientError.requestFailed(decoded.error ?? "Project list returned HTTP \(statusCode)")
        }
        return decoded.projects ?? []
    }

    func fetchProjectBranches(projectPath: String) async throws -> [ProjectBranch] {
        var components = URLComponents(url: baseURL.appendingPathComponent("projects/branches"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: projectPath)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try Self.decoder.decode(ProjectBranchListResponse.self, from: data)
        guard statusCode == 200 && decoded.ok else {
            if statusCode == 404 {
                throw AgentClientError.requestFailed("Branch switching needs the updated kish-agent")
            }
            throw AgentClientError.requestFailed(decoded.error ?? "Branch list returned HTTP \(statusCode)")
        }
        return decoded.branches ?? []
    }

    func fetchProjectFiles(projectPath: String, branch: String? = nil) async throws -> [ProjectFile] {
        var components = URLComponents(url: baseURL.appendingPathComponent("projects/files"), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "path", value: projectPath),
            URLQueryItem(name: "limit", value: "5000"),
            URLQueryItem(
                name: "exclude",
                value: "node_modules,.git,build,dist,.next,.nuxt,.turbo,.cache,.parcel-cache,.svelte-kit,.vercel,coverage,out,target,vendor,Pods,DerivedData,.build,.gradle,.expo"
            ),
        ]
        if let branch, !branch.isEmpty {
            queryItems.append(URLQueryItem(name: "branch", value: branch))
        }
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try Self.decoder.decode(ProjectFileListResponse.self, from: data)
        guard statusCode == 200 && decoded.ok else {
            if statusCode == 404 {
                throw AgentClientError.requestFailed("File references need the updated kish-agent")
            }
            throw AgentClientError.requestFailed(decoded.error ?? "Project files returned HTTP \(statusCode)")
        }
        return decoded.files ?? []
    }

    func switchProjectBranch(projectPath: String, branch: String, dirtyAction: ProjectDirtyAction? = nil) async throws -> ProjectBranchSwitchResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("projects/switch-branch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(ProjectBranchSwitchRequest(projectPath: projectPath, branch: branch, dirtyAction: dirtyAction))

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try Self.decoder.decode(ProjectBranchSwitchResponse.self, from: data)
        guard decoded.ok || decoded.requiresDirtyAction == true else {
            throw AgentClientError.requestFailed(decoded.error ?? "Branch switch returned HTTP \(statusCode)")
        }
        return decoded
    }

    func deleteConversation(_ id: UUID) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("conversations/\(id.uuidString.lowercased())"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try Self.decoder.decode(BasicResponse.self, from: data)
        guard statusCode == 200 && decoded.ok else {
            throw AgentClientError.requestFailed(decoded.error ?? "Conversation delete returned HTTP \(statusCode)")
        }
    }

    func refreshToolInventory() async {
        do {
            toolInventory = try await fetchToolInventory()
            toolInventoryStatus = "Ready"
        } catch {
            toolInventoryStatus = "Unavailable"
        }
    }

    func fetchToolInventory() async throws -> ToolInventory {
        var request = URLRequest(url: baseURL.appendingPathComponent("tools"))
        request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try Self.decoder.decode(ToolInventoryResponse.self, from: data)
        guard statusCode == 200 && decoded.ok else {
            throw AgentClientError.requestFailed(decoded.error ?? "Tool inventory returned HTTP \(statusCode)")
        }
        return ToolInventory(
            commands: decoded.commands ?? [],
            engines: decoded.engines ?? [],
            recentTools: decoded.recentTools ?? [],
            updatedAt: decoded.updatedAt
        )
    }

    private func markOffline(_ message: String) {
        miniStatus = "Offline"
        httpStatus = "Offline"
        agentStatus = "Offline"
        agentProtocolStatus = "Offline"
        chatStatus = "Offline"
        toolInventoryStatus = "Offline"
        status = "Offline"
        detail = message
    }

    private func beginSending() {
        activeSendCount += 1
        status = "Sending"
        chatStatus = "Sending"
    }

    private func endSending() {
        activeSendCount = max(activeSendCount - 1, 0)
    }

    private func markChecking() {
        miniStatus = "Checking"
        httpStatus = "Checking"
        agentStatus = "Checking"
        agentProtocolStatus = "Checking"
        if chatStatus != "Sending" && chatStatus != "Question" {
            chatStatus = "Checking"
        }
        status = "Checking"
        detail = "Checking kish-agent"
    }

    private func markNetworkError(_ error: URLError) {
        let mapped = AgentClientError.network(error)
        markOffline(mapped.localizedDescription)
    }

    private func markBridgeError(_ message: String) {
        miniStatus = "Online"
        httpStatus = "Error"
        agentStatus = "Offline"
        agentProtocolStatus = "Unavailable"
        chatStatus = "Offline"
        toolInventoryStatus = "Unavailable"
        status = "Error"
        detail = message
    }

    private func markAgentUnavailable(_ message: String) {
        miniStatus = "Online"
        httpStatus = "Online"
        agentStatus = "Offline"
        agentProtocolStatus = "Unavailable"
        chatStatus = "Offline"
        toolInventoryStatus = "Unavailable"
        status = "Offline"
        detail = message
    }

    private func markChatRequestFailure(_ message: String) {
        miniStatus = "Online"
        httpStatus = "Online"
        agentStatus = "Online"
        agentProtocolStatus = "Ready"
        chatStatus = "Error"
        status = "Error"
        detail = message
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func displayString(for url: URL) -> String {
        var output = url.absoluteString
        if output.hasSuffix("/") {
            output.removeLast()
        }
        return output
    }

    private static let requiredAgentEndpoints: Set<String> = [
        "health",
        "chat-stream",
        "cancel",
        "conversations",
        "attachments",
        "approve",
        "projects",
        "projects/files",
        "projects/branches",
        "projects/switch-branch",
        "tools"
    ]

    private static func agentProtocolStatus(for health: HealthResponse) -> String {
        guard let endpoints = health.endpoints, !endpoints.isEmpty else {
            return "Unknown"
        }
        return missingRequiredEndpoints(from: endpoints).isEmpty ? "Ready" : "Needs update"
    }

    private static func healthDetail(for health: HealthResponse) -> String {
        let version = health.version ?? health.apiVersion ?? health.protocolVersion
        let versionText = version.map { " \($0)" } ?? ""

        guard let endpoints = health.endpoints, !endpoints.isEmpty else {
            return "Connected to kish-agent\(versionText)"
        }

        let missing = missingRequiredEndpoints(from: endpoints)
        guard !missing.isEmpty else {
            return "Connected to kish-agent\(versionText)"
        }

        let preview = missing.prefix(3).joined(separator: ", ")
        let suffix = missing.count > 3 ? ", ..." : ""
        return "kish-agent\(versionText) is missing \(preview)\(suffix)"
    }

    private static func missingRequiredEndpoints(from reportedEndpoints: [String]) -> [String] {
        let normalized = Set(reportedEndpoints.map { endpoint in
            endpoint
                .trimmingCharacters(in: CharacterSet(charactersIn: " /"))
                .lowercased()
        })
        return requiredAgentEndpoints
            .filter { !normalized.contains($0) }
            .sorted()
    }

    private static func multipartBody(
        boundary: String,
        payload: PendingAttachmentPayload,
        conversationId: UUID?,
        threadId: String?
    ) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        func appendField(name: String, value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        appendField(name: "filename", value: payload.filename)
        appendField(name: "mimeType", value: payload.mimeType)
        if let conversationId {
            appendField(name: "conversationId", value: conversationId.uuidString.lowercased())
        }
        if let threadId {
            appendField(name: "threadId", value: threadId)
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(escapedMultipartValue(payload.filename))\"\r\n")
        append("Content-Type: \(payload.mimeType)\r\n\r\n")
        body.append(payload.data)
        append("\r\n")
        append("--\(boundary)--\r\n")
        return body
    }

    private static func escapedMultipartValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

struct ChatRequestAttachment: Codable, Equatable {
    let id: String
    let filename: String
    let mimeType: String?
    let kind: String?
}

struct ChatRequestReference: Codable, Equatable {
    let path: String
    let title: String
    let kind: String
    let repoPath: String?
    let branch: String?
    let relPath: String?

    init(
        path: String,
        title: String,
        kind: String,
        repoPath: String? = nil,
        branch: String? = nil,
        relPath: String? = nil
    ) {
        self.path = path
        self.title = title
        self.kind = kind
        self.repoPath = repoPath
        self.branch = branch
        self.relPath = relPath
    }
}

struct UploadedAttachment: Decodable, Equatable {
    let id: String
    let filename: String
    let mimeType: String?
    let byteCount: Int?
    let kind: String?
}

struct PendingAttachmentPayload: Equatable {
    let attachmentId: UUID
    let filename: String
    let mimeType: String
    let data: Data
}

final class AttachmentPayloadCache {
    static let shared = AttachmentPayloadCache()

    private let fileManager: FileManager
    private let rootURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.rootURL = supportURL
            .appendingPathComponent("KishOS", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
    }

    func store(data: Data, attachmentId: UUID, filename: String) throws -> String {
        let safeFilename = Self.safeFilename(filename)
        let directory = rootURL.appendingPathComponent(attachmentId.uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(safeFilename, isDirectory: false)
        try data.write(to: fileURL, options: [.atomic])
        return "\(attachmentId.uuidString.lowercased())/\(safeFilename)"
    }

    func payload(for attachment: ChatAttachment) throws -> PendingAttachmentPayload {
        guard let localFilename = attachment.localFilename else {
            throw AttachmentPayloadCacheError.missingLocalFile
        }
        let fileURL = try resolvedURL(for: localFilename)
        let data = try Data(contentsOf: fileURL)
        return PendingAttachmentPayload(
            attachmentId: attachment.id,
            filename: attachment.title,
            mimeType: attachment.mimeType ?? "application/octet-stream",
            data: data
        )
    }

    func removePayload(for attachment: ChatAttachment) {
        guard let localFilename = attachment.localFilename,
              let directoryName = localFilename.split(separator: "/").first
        else {
            return
        }
        let directory = rootURL.appendingPathComponent(String(directoryName), isDirectory: true)
        try? fileManager.removeItem(at: directory)
    }

    func cachedFileURL(for attachment: ChatAttachment) -> URL? {
        guard let localFilename = attachment.localFilename else { return nil }
        return try? resolvedURL(for: localFilename)
    }

    private func resolvedURL(for localFilename: String) throws -> URL {
        let parts = localFilename.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.contains("..") && !$0.contains("/") })
        else {
            throw AttachmentPayloadCacheError.invalidLocalFile
        }
        return rootURL
            .appendingPathComponent(parts[0], isDirectory: true)
            .appendingPathComponent(parts[1], isDirectory: false)
    }

    private static func safeFilename(_ filename: String) -> String {
        let cleaned = filename
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0\r\n"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "attachment" : cleaned
    }
}

enum AttachmentPayloadCacheError: LocalizedError {
    case missingLocalFile
    case invalidLocalFile

    var errorDescription: String? {
        switch self {
        case .missingLocalFile:
            return "Could not read that file."
        case .invalidLocalFile:
            return "Could not read that file."
        }
    }
}

private struct ChatRequest: Encodable {
    let threadId: String
    let message: String
    let conversationId: UUID?
    let attachments: [ChatRequestAttachment]
    let references: [ChatRequestReference]
    let projectPath: String?

    enum CodingKeys: String, CodingKey {
        case threadId
        case message
        case conversationId
        case attachments
        case references
        case projectPath
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadId, forKey: .threadId)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(conversationId, forKey: .conversationId)
        try container.encodeIfPresent(projectPath, forKey: .projectPath)
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
        if !references.isEmpty {
            try container.encode(references, forKey: .references)
        }
    }
}

private struct CancelRequest: Encodable {
    let threadId: String
}

private struct ProjectBranchSwitchRequest: Encodable {
    let projectPath: String
    let branch: String
    let dirtyAction: ProjectDirtyAction?
}

private struct ConversationListResponse: Decodable {
    let ok: Bool
    let conversations: [Conversation]
    let error: String?
}

struct ToolInventory: Decodable, Equatable {
    static let empty = ToolInventory(commands: [], engines: [], recentTools: [], updatedAt: nil)

    let commands: [ToolCapability]
    let engines: [ToolCapability]
    let recentTools: [RecentToolCapability]
    let updatedAt: Date?

    var availableCommands: [ToolCapability] {
        commands.filter(\.isAvailable)
    }

    var unavailableCommands: [ToolCapability] {
        commands.filter { !$0.isAvailable }
    }

    var availableEngines: [ToolCapability] {
        engines.filter(\.isAvailable)
    }

    var unavailableEngines: [ToolCapability] {
        engines.filter { !$0.isAvailable }
    }

    var unavailableCapabilities: [ToolCapability] {
        unavailableEngines + unavailableCommands
    }

    var hasAnyCapabilities: Bool {
        !commands.isEmpty || !engines.isEmpty || !recentTools.isEmpty
    }

    var compactSummary: String {
        guard hasAnyCapabilities else { return "Unavailable" }
        var parts: [String] = []
        if !availableCommands.isEmpty {
            parts.append("\(availableCommands.count) tools")
        }
        if !availableEngines.isEmpty {
            parts.append("\(availableEngines.count) engines")
        }
        if !recentTools.isEmpty {
            parts.append("\(recentTools.count) recent")
        }
        if !unavailableCapabilities.isEmpty {
            parts.append("\(unavailableCapabilities.count) unavailable")
        }
        return parts.isEmpty ? "Unavailable" : parts.joined(separator: " · ")
    }
}

struct ToolCapability: Decodable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let status: String
    let detail: String?

    var isAvailable: Bool {
        status.localizedCaseInsensitiveContains("available")
            || status.localizedCaseInsensitiveContains("ready")
            || status.localizedCaseInsensitiveContains("online")
    }
}

struct RecentToolCapability: Decodable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let count: Int
    let lastSeen: Date?
}

struct ToolInventoryResponse: Decodable, Equatable {
    let ok: Bool
    let commands: [ToolCapability]?
    let engines: [ToolCapability]?
    let recentTools: [RecentToolCapability]?
    let updatedAt: Date?
    let error: String?
}

private struct ChatResponse: Decodable {
    let ok: Bool
    let threadId: String?
    let engine: String?
    let text: String?
    let error: String?
    let elapsedMs: Int?
    let events: [String]?
    let approvals: [ApprovalRequest]?
}

private struct HealthResponse: Decodable {
    let ok: Bool
    let version: String?
    let apiVersion: String?
    let protocolVersion: String?
    let endpoints: [String]?
}

private struct BasicResponse: Decodable {
    let ok: Bool
    let error: String?
}

private struct AttachmentUploadResponse: Decodable {
    let ok: Bool
    let attachment: UploadedAttachment?
    let error: String?
}

private struct ApprovalAnswerRequest: Encodable {
    let approvalId: String
    let approved: Bool
    let answer: String?
}

struct AgentStreamEvent: Decodable, Equatable {
    let type: String
    let status: String?
    let threadId: String?
    let engine: String?
    let text: String?
    let tool: AgentToolEvent?
    let approval: ApprovalRequest?
    let approvalId: String?
    let answer: String?
    let timedOut: Bool?
    let ok: Bool?
    let error: String?
    let elapsedMs: Int?
    let events: [String]?
    let approvals: [ApprovalRequest]?
    let cancelled: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case status
        case threadId
        case engine
        case text
        case tool
        case approval
        case approvalId
        case answer
        case timedOut
        case ok
        case error
        case elapsedMs
        case events
        case approvals
        case cancelled
    }
}

struct AgentToolEvent: Decodable, Equatable {
    let name: String
    let input: [String: String]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        if let raw = try? container.decode([String: String].self, forKey: .input) {
            input = raw
        } else {
            input = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case input
    }
}

enum AgentClientError: LocalizedError {
    case requestFailed(String)
    case network(URLError)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            return message
        case .network(let error):
            switch error.code {
            case .timedOut:
                return "Request timed out"
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return "Cannot reach kish-agent"
            default:
                return error.localizedDescription
            }
        case .cancelled:
            return "Stopped."
        }
    }
}
