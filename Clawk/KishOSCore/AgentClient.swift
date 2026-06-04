import Foundation

@MainActor
final class KishAgentClient: ObservableObject {
    @Published var isSending = false
    @Published var status = "Checking"
    @Published var miniStatus = "Checking"
    @Published var httpStatus = "Checking"
    @Published var agentStatus = "Checking"
    @Published var chatStatus = "Idle"
    @Published var detail = "Starting up"
    @Published var toolInventory = ToolInventory.empty
    @Published var toolInventoryStatus = "Checking"

    private let baseURL: URL
    private let session: URLSession
    private var pollingStarted = false

    init(
        baseURL: URL = URL(string: "http://kishs-mac-mini-1:17891")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
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
                chatStatus = "Ready"
                status = "Ready"
                detail = "Connected to kish-agent"
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

    func send(_ message: String, threadId: String) async throws -> ChatResult {
        isSending = true
        status = "Sending"
        chatStatus = "Sending"
        defer { isSending = false }

        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 180
            request.httpBody = try JSONEncoder().encode(ChatRequest(threadId: threadId, message: message, conversationId: nil))

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
        onEvent: @escaping (AgentStreamEvent) async -> Void
    ) async throws -> ChatResult {
        isSending = true
        status = "Sending"
        chatStatus = "Sending"
        defer { isSending = false }

        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("chat-stream"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 180
            request.httpBody = try JSONEncoder().encode(ChatRequest(threadId: threadId, message: message, conversationId: conversationId))

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
                    if event.ok == true, let text = event.text {
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
        chatStatus = "Offline"
        toolInventoryStatus = "Offline"
        status = "Offline"
        detail = message
    }

    private func markChecking() {
        miniStatus = "Checking"
        httpStatus = "Checking"
        agentStatus = "Checking"
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
        chatStatus = "Offline"
        toolInventoryStatus = "Unavailable"
        status = "Error"
        detail = message
    }

    private func markAgentUnavailable(_ message: String) {
        miniStatus = "Online"
        httpStatus = "Online"
        agentStatus = "Offline"
        chatStatus = "Offline"
        toolInventoryStatus = "Unavailable"
        status = "Offline"
        detail = message
    }

    private func markChatRequestFailure(_ message: String) {
        miniStatus = "Online"
        httpStatus = "Online"
        agentStatus = "Online"
        chatStatus = "Error"
        status = "Error"
        detail = message
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct ChatRequest: Encodable {
    let threadId: String
    let message: String
    let conversationId: UUID?
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
}

struct ToolCapability: Decodable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let status: String
    let detail: String?
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
}

private struct BasicResponse: Decodable {
    let ok: Bool
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
        }
    }
}
