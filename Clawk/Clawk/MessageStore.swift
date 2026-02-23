import Foundation
import Combine
import UIKit

struct ClawkMessage: Identifiable, Codable {
    let id: String
    let type: String
    let message: String
    let actions: [String]
    let timestamp: TimeInterval
    var responded: Bool
    var response: String?
}

class MessageStore: NSObject, ObservableObject {
    @Published var messages: [ClawkMessage] = []
    @Published var isConnected = false
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectTimer: Timer?
    
    override init() {
        super.init()
        connect()
        pairDevice()
    }
    
    func pairDevice() {
        let url = Config.apiURL.appendingPathComponent("/pair")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "deviceToken": Config.deviceToken,
            "deviceName": UIDevice.current.name
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
    
    func connect() {
        var request = URLRequest(url: Config.websocketURL)
        request.timeoutInterval = 5
        
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.delegate = self
        webSocketTask?.resume()
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        reconnectTimer?.invalidate()
    }
    
    private func reconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.connect()
        }
    }
    
    private func receive() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                default:
                    break
                }
                self?.receive() // Keep listening
                
            case .failure(let error):
                print("WebSocket error: \(error)")
                DispatchQueue.main.async {
                    self?.isConnected = false
                }
                self?.reconnect()
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              var message = try? JSONDecoder().decode(ClawkMessage.self, from: data) else {
            return
        }
        
        DispatchQueue.main.async {
            self.messages.insert(message, at: 0)
        }
    }
    
    func respond(to message: ClawkMessage, with action: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let index = self.messages.firstIndex(where: { $0.id == message.id }) else { return }
            
            self.messages[index].responded = true
            self.messages[index].response = action
            
            let response: [String: Any] = [
                "messageId": message.id,
                "action": action,
                "timestamp": Date().timeIntervalSince1970
            ]
            
            if let data = try? JSONSerialization.data(withJSONObject: response) {
                self.webSocketTask?.send(.string(String(data: data, encoding: .utf8)!)) { _ in }
            }
        }
    }
}

extension MessageStore: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            self.isConnected = true
        }
        receive()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
        }
        reconnect()
    }
}
