import Foundation

@MainActor
final class KishOSWorkspace: ObservableObject {
    @Published private(set) var conversations: [Conversation]
    @Published private(set) var storeError: String?

    private let store: ConversationStoring

    init(store: ConversationStoring = JSONConversationStore()) {
        self.store = store
        do {
            self.conversations = try store.load()
            self.storeError = nil
        } catch {
            self.conversations = []
            self.storeError = error.localizedDescription
        }
    }

    func createConversation(firstMessage: String, now: Date = Date()) -> Conversation {
        var conversation = Conversation(firstMessage: firstMessage, now: now)
        conversation.isRunning = true
        conversations.insert(conversation, at: 0)
        persist()
        return conversation
    }

    func appendUserMessage(_ text: String, to id: UUID, now: Date = Date()) -> Conversation? {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return nil }
        conversations[index].messages.append(ChatMessage(sender: .user, text: text, createdAt: now, deliveryState: .sending))
        conversations[index].events = ["sent to kish-agent", "continuing \(conversations[index].threadId)"]
        conversations[index].isRunning = true
        conversations[index].lastError = nil
        conversations[index].approvals = []
        conversations[index].updatedAt = now
        let conversation = conversations[index]
        sortAndPersist()
        return conversation
    }

    func prepareRetryLastFailedMessage(in id: UUID, now: Date = Date()) -> (conversation: Conversation, message: String)? {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              let messageIndex = conversations[index].messages.lastIndex(where: { $0.sender == .user && $0.deliveryState == .failed })
        else {
            return nil
        }

        let message = conversations[index].messages[messageIndex].text
        conversations[index].messages[messageIndex].deliveryState = .sending
        conversations[index].events = ["retrying request", "continuing \(conversations[index].threadId)"]
        conversations[index].isRunning = true
        conversations[index].lastError = nil
        conversations[index].updatedAt = now
        let conversation = conversations[index]
        sortAndPersist()
        return (conversation, message)
    }

    func apply(_ result: ChatResult, to id: UUID, now: Date = Date()) {
        updateConversation(id) { conversation in
            markLastUserMessageSent(in: &conversation)
            if let index = conversation.messages.lastIndex(where: { $0.sender == .agent && $0.deliveryState == .sending }) {
                conversation.messages[index].text = result.text
                conversation.messages[index].deliveryState = .sent
                if !result.events.isEmpty {
                    conversation.messages[index].activityEvents = mergedEvents(
                        conversation.messages[index].activityEvents,
                        with: result.events
                    )
                }
            } else {
                conversation.messages.append(ChatMessage(sender: .agent, text: result.text, createdAt: now, activityEvents: result.events))
            }
            conversation.events = result.events.isEmpty ? ["reply received"] : result.events
            conversation.engine = result.engine
            conversation.elapsedMs = result.elapsedMs
            conversation.isRunning = false
            conversation.lastError = nil
            conversation.approvals = result.approvals
            conversation.updatedAt = now
        }
    }

    func applyFailure(_ error: Error, to id: UUID, now: Date = Date()) {
        updateConversation(id) { conversation in
            markLastUserMessageFailed(in: &conversation)
            let message = error.localizedDescription
            if let index = conversation.messages.lastIndex(where: { $0.sender == .agent && $0.deliveryState == .sending }) {
                conversation.messages[index].text = message
                conversation.messages[index].deliveryState = .failed
                conversation.messages[index].activityEvents = mergedEvents(
                    conversation.messages[index].activityEvents,
                    with: ["request failed"]
                )
            } else {
                conversation.messages.append(ChatMessage(sender: .agent, text: message, createdAt: now, deliveryState: .failed, activityEvents: ["request failed"]))
            }
            conversation.events = ["request failed"]
            conversation.isRunning = false
            conversation.lastError = message
            conversation.updatedAt = now
        }
    }

    func beginAgentResponse(in id: UUID, now: Date = Date()) {
        updateConversation(id) { conversation in
            conversation.messages.append(ChatMessage(sender: .agent, text: "", createdAt: now, deliveryState: .sending, activityEvents: ["waiting for reply"]))
            conversation.events = ["waiting for reply"]
            conversation.isRunning = true
            conversation.lastError = nil
            conversation.approvals = []
            conversation.updatedAt = now
        }
    }

    func appendStreamingText(_ text: String, to id: UUID, now: Date = Date()) {
        guard !text.isEmpty else { return }
        updateConversation(id) { conversation in
            if let index = conversation.messages.lastIndex(where: { $0.sender == .agent && $0.deliveryState == .sending }) {
                conversation.messages[index].text += text
            } else {
                conversation.messages.append(ChatMessage(sender: .agent, text: text, createdAt: now, deliveryState: .sending))
            }
            conversation.updatedAt = now
        }
    }

    func appendActivity(_ text: String, to id: UUID, now: Date = Date()) {
        guard !text.isEmpty else { return }
        updateConversation(id) { conversation in
            conversation.events.append(text)
            conversation.events = Array(conversation.events.suffix(30))
            if let index = conversation.messages.lastIndex(where: { $0.sender == .agent && $0.deliveryState == .sending }) {
                conversation.messages[index].activityEvents = mergedEvents(
                    conversation.messages[index].activityEvents,
                    with: [text]
                )
            }
            conversation.updatedAt = now
        }
    }

    func setApprovals(_ approvals: [ApprovalRequest], for id: UUID, now: Date = Date()) {
        updateConversation(id) { conversation in
            conversation.approvals = approvals
            conversation.updatedAt = now
        }
    }

    func removeApproval(_ approvalId: String, from id: UUID, now: Date = Date()) {
        updateConversation(id) { conversation in
            conversation.approvals.removeAll { $0.id == approvalId }
            conversation.updatedAt = now
        }
    }

    func renameConversation(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateConversation(id) { conversation in
            conversation.title = trimmed
            conversation.updatedAt = Date()
        }
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        persist()
    }

    func conversation(id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    func mergeRemoteConversations(_ remote: [Conversation]) {
        guard !remote.isEmpty else { return }
        var byId = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        for conversation in remote {
            byId[conversation.id] = conversation
        }
        conversations = byId.values.sorted { $0.updatedAt > $1.updatedAt }
        persist()
    }

    private func updateConversation(_ id: UUID, mutate: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&conversations[index])
        sortAndPersist()
    }

    private func sortAndPersist() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    private func persist() {
        do {
            try store.save(conversations)
            storeError = nil
        } catch {
            storeError = error.localizedDescription
        }
    }
}

private func markLastUserMessageSent(in conversation: inout Conversation) {
    guard let index = conversation.messages.lastIndex(where: { $0.sender == .user }) else { return }
    conversation.messages[index].deliveryState = .sent
}

private func markLastUserMessageFailed(in conversation: inout Conversation) {
    guard let index = conversation.messages.lastIndex(where: { $0.sender == .user }) else { return }
    conversation.messages[index].deliveryState = .failed
}

private func mergedEvents(_ existing: [String], with newEvents: [String]) -> [String] {
    var merged = existing
    for event in newEvents where !event.isEmpty && !merged.contains(event) {
        merged.append(event)
    }
    return Array(merged.suffix(30))
}
