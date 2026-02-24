import Foundation
import Combine

// MARK: - OpenClaw Gateway Protocol

/// Direct WebSocket connection to OpenClaw Gateway (port 18789)
/// Implements the OpenClaw Gateway Protocol for native chat experience
class GatewayConnection: NSObject, ObservableObject {
    
    // MARK: - Published State
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var messages: [GatewayMessage] = []
    @Published var thinkingSteps: [ThinkingStep] = []
    @Published var agentIdentity: AgentIdentity?
    @Published var connectionError: String?
    
    // MARK: - Private Properties
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectTimer: Timer?
    private var heartbeatTimer: Timer?
    private var messageIdCounter = 0
    private var pendingToolCalls: [String: ToolCall] = [:]
    
    // Gateway configuration
    private let gatewayHost: String
    private let gatewayPort: Int
    private var deviceToken: String
    
    // MARK: - Initialization
    init(host: String = "localhost", port: Int = 18789) {
        self.gatewayHost = host
        self.gatewayPort = port
        self.deviceToken = UserDefaults.standard.string(forKey: "gatewayDeviceToken") ?? UUID().uuidString
        super.init()
        
        // Save device token if new
        if UserDefaults.standard.string(forKey: "gatewayDeviceToken") == nil {
            UserDefaults.standard.set(deviceToken, forKey: "gatewayDeviceToken")
        }
    }
    
    // MARK: - Connection Management
    
    func connect() {
        guard !isConnecting && !isConnected else { return }
        
        DispatchQueue.main.async {
            self.isConnecting = true
            self.connectionError = nil
        }
        
        let urlString = "ws://\(gatewayHost):\(gatewayPort)/ws?token=\(deviceToken)"
        guard let url = URL(string: urlString) else {
            connectionError = "Invalid gateway URL"
            isConnecting = false
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.delegate = self
        webSocketTask?.resume()
        
        receiveMessage()
    }
    
    func disconnect() {
        heartbeatTimer?.invalidate()
        reconnectTimer?.invalidate()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
        }
    }
    
    private func reconnect() {
        disconnect()
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }
    
    // MARK: - Message Handling
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleWebSocketMessage(message)
                self?.receiveMessage() // Keep listening
                
            case .failure(let error):
                print("WebSocket error: \(error)")
                DispatchQueue.main.async {
                    self?.connectionError = error.localizedDescription
                    self?.isConnected = false
                    self?.isConnecting = false
                }
                self?.reconnect()
            }
        }
    }
    
    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message else { return }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as? [String: Any] {
                handleGatewayEvent(json)
            }
        } catch {
            print("Failed to parse gateway message: \(error)")
        }
    }
    
    private func handleGatewayEvent(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }
        
        DispatchQueue.main.async { [weak self] in
            switch type {
            case "hello":
                self?.handleHello(json)
            case "message":
                self?.handleChatMessage(json)
            case "thinking":
                self?.handleThinkingStep(json)
            case "toolCall":
                self?.handleToolCall(json)
            case "toolResult":
                self?.handleToolResult(json)
            case "identity":
                self?.handleIdentityUpdate(json)
            case "error":
                self?.connectionError = json["message"] as? String
            default:
                break
            }
        }
    }
    
    // MARK: - Event Handlers
    
    private func handleHello(_ json: [String: Any]) {
        isConnected = true
        isConnecting = false
        
        // Start heartbeat
        startHeartbeat()
        
        // Request identity sync
        sendEvent(["type": "sync_identity"])
    }
    
    private func handleChatMessage(_ json: [String: Any]) {
        guard let id = json["id"] as? String,
              let role = json["role"] as? String,
              let content = json["content"] as? String else { return }
        
        let message = GatewayMessage(
            id: id,
            role: role,
            content: content,
            timestamp: Date(),
            thinking: json["thinking"] as? String,
            toolCalls: nil,
            isStreaming: json["streaming"] as? Bool ?? false
        )
        
        // Update or append message
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        
        // Clear thinking steps when message completes
        if !(json["streaming"] as? Bool ?? false) {
            thinkingSteps.removeAll()
        }
    }
    
    private func handleThinkingStep(_ json: [String: Any]) {
        guard let id = json["id"] as? String,
              let content = json["content"] as? String else { return }
        
        let step = ThinkingStep(
            id: id,
            content: content,
            timestamp: Date(),
            type: .thinking
        )
        
        // Add or update thinking step
        if let index = thinkingSteps.firstIndex(where: { $0.id == id }) {
            thinkingSteps[index] = step
        } else {
            thinkingSteps.append(step)
        }
    }
    
    private func handleToolCall(_ json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else { return }
        
        let toolCall = ToolCall(
            id: id,
            name: name,
            arguments: json["arguments"] as? [String: Any] ?? [:],
            timestamp: Date()
        )
        
        pendingToolCalls[id] = toolCall
        
        let step = ThinkingStep(
            id: id,
            content: "Using \(name)...",
            timestamp: Date(),
            type: .toolCall,
            toolName: name
        )
        
        thinkingSteps.append(step)
    }
    
    private func handleToolResult(_ json: [String: Any]) {
        guard let toolCallId = json["toolCallId"] as? String,
              let status = json["status"] as? String else { return }
        
        // Update thinking step with result
        if let index = thinkingSteps.firstIndex(where: { $0.id == toolCallId }) {
            let duration = json["durationMs"] as? Int
            let step = ThinkingStep(
                id: toolCallId,
                content: thinkingSteps[index].content,
                timestamp: thinkingSteps[index].timestamp,
                type: .toolResult,
                toolName: thinkingSteps[index].toolName,
                status: status,
                durationMs: duration
            )
            thinkingSteps[index] = step
        }
        
        pendingToolCalls.removeValue(forKey: toolCallId)
    }
    
    private func handleIdentityUpdate(_ json: [String: Any]) {
        agentIdentity = AgentIdentity(
            name: json["name"] as? String ?? "Assistant",
            creature: json["creature"] as? String ?? "AI",
            vibe: json["vibe"] as? String,
            emoji: json["emoji"] as? String ?? "🤖",
            color: json["color"] as? String ?? "#6B7280"
        )
    }
    
    // MARK: - Sending Messages
    
    func sendMessage(_ content: String) {
        let event: [String: Any] = [
            "type": "message",
            "id": UUID().uuidString,
            "role": "user",
            "content": content,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        sendEvent(event)
        
        // Add to local messages immediately
        let message = GatewayMessage(
            id: event["id"] as! String,
            role: "user",
            content: content,
            timestamp: Date()
        )
        messages.append(message)
    }
    
    private func sendEvent(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        
        webSocketTask?.send(.string(text)) { error in
            if let error = error {
                print("Failed to send event: \(error)")
            }
        }
    }
    
    // MARK: - Heartbeat
    
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.sendEvent(["type": "ping"])
        }
    }
    
    // MARK: - Persistence
    
    func saveMessages() {
        // Messages are persisted via SwiftData in ChatHistoryStore
    }
    
    func clearMessages() {
        messages.removeAll()
        thinkingSteps.removeAll()
    }
}

// MARK: - URLSessionWebSocketDelegate

extension GatewayConnection: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.isConnecting = false
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
            if let error = error {
                self.connectionError = error.localizedDescription
            }
        }
        reconnect()
    }
}

// MARK: - Models

struct GatewayMessage: Identifiable, Codable {
    let id: String
    let role: String
    let content: String
    let timestamp: Date
    var thinking: String?
    var toolCalls: [ToolCall]?
    var isStreaming: Bool = false
}

struct ThinkingStep: Identifiable, Codable {
    let id: String
    let content: String
    let timestamp: Date
    let type: ThinkingType
    var toolName: String?
    var status: String?
    var durationMs: Int?
    
    enum ThinkingType: String, Codable {
        case thinking
        case toolCall
        case toolResult
    }
}

struct ToolCall: Codable {
    let id: String
    let name: String
    let arguments: [String: Any]
    let timestamp: Date
    
    enum CodingKeys: String, CodingKey {
        case id, name, timestamp
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(timestamp, forKey: .timestamp)
    }
    
    init(id: String, name: String, arguments: [String: Any], timestamp: Date) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.timestamp = timestamp
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        arguments = [:]
    }
}

struct AgentIdentity: Codable {
    let name: String
    let creature: String
    let vibe: String?
    let emoji: String
    let color: String
}
