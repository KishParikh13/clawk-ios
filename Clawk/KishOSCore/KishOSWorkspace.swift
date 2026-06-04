import Foundation

@MainActor
final class KishOSWorkspace: ObservableObject {
    @Published private(set) var conversations: [Conversation]
    @Published private(set) var storeError: String?

    private let store: ConversationStoring
    private var deletedConversationIDs: Set<UUID>
    private var remoteConversationIDs: Set<UUID>

    init(store: ConversationStoring = JSONConversationStore()) {
        self.store = store
        do {
            self.conversations = try store.load()
            self.storeError = nil
        } catch {
            self.conversations = []
            self.storeError = error.localizedDescription
        }
        do {
            self.deletedConversationIDs = try store.loadDeletedConversationIDs()
        } catch {
            self.deletedConversationIDs = []
            self.storeError = error.localizedDescription
        }
        do {
            self.remoteConversationIDs = try store.loadRemoteConversationIDs()
        } catch {
            self.remoteConversationIDs = []
            self.storeError = error.localizedDescription
        }
    }

    var queuedMessageCount: Int {
        conversations.reduce(0) { count, conversation in
            count + conversation.messages.filter { $0.sender == .user && $0.deliveryState == .queued }.count
        }
    }

    func createConversation(
        firstMessage: String,
        now: Date = Date(),
        deliveryState: MessageDeliveryState = .sending,
        attachments: [ChatAttachment] = []
    ) -> Conversation {
        var conversation = Conversation(firstMessage: firstMessage, now: now)
        conversation.messages[0].deliveryState = deliveryState
        conversation.messages[0].attachments = attachments
        conversation.isRunning = deliveryState == .sending
        if deliveryState == .queued {
            conversation.events = ["saved locally", "will send when connected"]
        }
        conversations.insert(conversation, at: 0)
        persist()
        return conversation
    }

    func appendUserMessage(
        _ text: String,
        to id: UUID,
        now: Date = Date(),
        deliveryState: MessageDeliveryState = .sending,
        attachments: [ChatAttachment] = []
    ) -> Conversation? {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return nil }
        conversations[index].messages.append(ChatMessage(sender: .user, text: text, createdAt: now, deliveryState: deliveryState, attachments: attachments))
        conversations[index].events = deliveryState == .queued
            ? ["saved locally", "will send when connected"]
            : ["sent to kish-agent", "continuing \(conversations[index].threadId)"]
        conversations[index].isRunning = deliveryState == .sending
        conversations[index].lastError = nil
        conversations[index].approvals = []
        conversations[index].updatedAt = now
        let conversation = conversations[index]
        sortAndPersist()
        return conversation
    }

    func queueConversation(firstMessage: String, now: Date = Date(), attachments: [ChatAttachment] = []) -> Conversation {
        createConversation(firstMessage: firstMessage, now: now, deliveryState: .queued, attachments: attachments)
    }

    func queueUserMessage(_ text: String, to id: UUID, now: Date = Date(), attachments: [ChatAttachment] = []) -> Conversation? {
        appendUserMessage(text, to: id, now: now, deliveryState: .queued, attachments: attachments)
    }

    func prepareRetryLastFailedMessage(in id: UUID, now: Date = Date()) -> (conversation: Conversation, message: String)? {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              let messageIndex = conversations[index].messages.lastIndex(where: { $0.sender == .user && $0.deliveryState == .failed })
        else {
            return nil
        }

        let userMessage = conversations[index].messages[messageIndex]
        let message = messageTextForAgent(userMessage.text, attachments: userMessage.attachments)
        conversations[index].messages[messageIndex].deliveryState = .sending
        conversations[index].events = ["retrying request", "continuing \(conversations[index].threadId)"]
        conversations[index].isRunning = true
        conversations[index].lastError = nil
        conversations[index].updatedAt = now
        let conversation = conversations[index]
        sortAndPersist()
        return (conversation, message)
    }

    func nextQueuedMessage() -> QueuedMessage? {
        conversations
            .flatMap { conversation in
                conversation.messages
                    .filter { $0.sender == .user && $0.deliveryState == .queued }
                    .map { QueuedMessage(conversation: conversation, message: $0) }
            }
            .min { lhs, rhs in
                lhs.message.createdAt < rhs.message.createdAt
            }
    }

    func prepareQueuedMessageForSending(conversationID: UUID, messageID: UUID, now: Date = Date()) -> (conversation: Conversation, message: String)? {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID && $0.sender == .user && $0.deliveryState == .queued })
        else {
            return nil
        }

        let userMessage = conversations[conversationIndex].messages[messageIndex]
        let message = messageTextForAgent(userMessage.text, attachments: userMessage.attachments)
        conversations[conversationIndex].messages[messageIndex].deliveryState = .sending
        conversations[conversationIndex].events = ["sending queued message", "continuing \(conversations[conversationIndex].threadId)"]
        conversations[conversationIndex].isRunning = true
        conversations[conversationIndex].lastError = nil
        conversations[conversationIndex].approvals = []
        conversations[conversationIndex].updatedAt = now
        let conversation = conversations[conversationIndex]
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

    func requeueMessageAfterOfflineFailure(conversationID: UUID, messageID: UUID, now: Date = Date()) -> Bool {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID && $0.sender == .user })
        else {
            return false
        }

        let hasAgentProgress = conversations[conversationIndex].messages.contains { message in
            guard message.sender == .agent, message.deliveryState == .sending else { return false }
            let visibleText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let visibleEvents = message.activityEvents.filter { $0 != "waiting for reply" }
            return !visibleText.isEmpty || !visibleEvents.isEmpty
        }
        guard !hasAgentProgress else { return false }

        conversations[conversationIndex].messages[messageIndex].deliveryState = .queued
        conversations[conversationIndex].messages.removeAll { message in
            message.sender == .agent && message.deliveryState == .sending
        }
        conversations[conversationIndex].events = ["saved locally", "will send when connected"]
        conversations[conversationIndex].isRunning = false
        conversations[conversationIndex].lastError = nil
        conversations[conversationIndex].updatedAt = now
        sortAndPersist()
        return true
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

    func recordApprovalAnswerAccepted(_ approvalId: String, in id: UUID, now: Date = Date()) {
        updateConversation(id) { conversation in
            conversation.approvals.removeAll { $0.id == approvalId }
            conversation.events.append("answered question")
            conversation.events = Array(conversation.events.suffix(30))
            conversation.updatedAt = now
        }
    }

    func recordApprovalAnswerRejected(_ approvalId: String, in id: UUID, now: Date = Date()) {
        updateConversation(id) { conversation in
            conversation.approvals.removeAll { $0.id == approvalId }
            conversation.events.append("cancelled question")
            conversation.events = Array(conversation.events.suffix(30))
            conversation.updatedAt = now
        }
    }

    func recordApprovalAnswerFailure(_ message: String, in id: UUID, now: Date = Date()) {
        guard !message.isEmpty else { return }
        updateConversation(id) { conversation in
            conversation.events.append(message)
            conversation.events = Array(conversation.events.suffix(30))
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
        deletedConversationIDs.insert(id)
        persist()
        persistDeletedConversationIDs()
    }

    func conversation(id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    func mergeRemoteConversations(_ remote: [Conversation]) {
        let remoteIDs = Set(remote.map(\.id))
        var byId = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

        for missingRemoteID in remoteConversationIDs.subtracting(remoteIDs) {
            byId.removeValue(forKey: missingRemoteID)
            deletedConversationIDs.insert(missingRemoteID)
        }

        for remoteConversation in remote {
            guard !deletedConversationIDs.contains(remoteConversation.id) else { continue }
            if let localConversation = byId[remoteConversation.id],
               localConversation.updatedAt >= remoteConversation.updatedAt {
                continue
            }
            byId[remoteConversation.id] = remoteConversation
        }

        remoteConversationIDs = remoteConversationIDs.union(remoteIDs).subtracting(deletedConversationIDs)
        conversations = byId.values.sorted { $0.updatedAt > $1.updatedAt }
        persist()
        persistDeletedConversationIDs()
        persistRemoteConversationIDs()
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

    private func persistDeletedConversationIDs() {
        do {
            try store.saveDeletedConversationIDs(deletedConversationIDs)
        } catch {
            storeError = error.localizedDescription
        }
    }

    private func persistRemoteConversationIDs() {
        do {
            try store.saveRemoteConversationIDs(remoteConversationIDs)
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
