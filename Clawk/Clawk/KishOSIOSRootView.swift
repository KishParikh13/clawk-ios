import SwiftUI
import UIKit

private enum IOSTheme {
    static let background = Color(uiColor: .systemBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let elevatedBackground = Color(uiColor: .tertiarySystemBackground)
    static let hairline = Color.secondary.opacity(0.18)
}

private enum IOSChatSelection: Equatable {
    case newChat
    case conversation(UUID)
}

private struct LiveCallSession: Identifiable {
    let id = UUID()
    let conversationID: UUID?
}

struct KishOSIOSRootView: View {
    @StateObject private var client = KishAgentClient()
    @StateObject private var workspace = KishOSWorkspace()
    @StateObject private var voice = VoiceController()
    @StateObject private var audio = AudioRouteMonitor()
    @StateObject private var wake = WakePhraseController()

    @State private var selection: IOSChatSelection = .newChat
    @State private var showingConversations = false
    @State private var isDrainingQueuedMessages = false
    @State private var liveCallSession: LiveCallSession?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                NavigationStack {
                    ChatScreen(
                        client: client,
                        conversation: selectedConversation,
                        isSending: currentIsRunning,
                        runState: selectedConversation?.runState,
                        agentStatus: selectedConversation?.agentStatusSummary,
                        queuedMessageCount: selectedConversation?.queuedUserMessageCount ?? workspace.queuedMessageCount,
                        approvals: selectedConversation?.approvals ?? [],
                        voice: voice,
                        audio: audio,
                        onSend: send,
                        onRetry: retrySelectedConversation,
                        onQuestionAnswer: answerQuestion,
                        onQuestionCancel: cancelQuestion
                    )
                    .navigationTitle(selectedConversation?.title ?? "KishOS")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    showingConversations = true
                                }
                            } label: {
                                Image(systemName: "sidebar.left")
                            }
                            .accessibilityLabel("Conversations")
                        }

                        ToolbarItem(placement: .principal) {
                            IOSChatHeaderTitle(conversation: selectedConversation)
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            HStack(spacing: 14) {
                                Button(action: startLiveCall) {
                                    Image(systemName: "phone.fill")
                                }
                                .accessibilityLabel("Start call")

                                Button(action: startNewChat) {
                                    Image(systemName: "square.and.pencil")
                                }
                                .accessibilityLabel("New chat")
                            }
                        }
                    }
                    .toolbar(showingConversations ? .hidden : .visible, for: .navigationBar)
                    .task {
                        await client.startHealthPolling()
                    }
                    .task {
                        await startSharedConversationSyncLoop()
                    }
                    .task {
                        await startQueuedMessageLoop()
                    }
                    .task {
                        audio.start()
                    }
                    .task {
                        refreshLiveActivitySummary()
                    }
                    .task {
                        refreshWakeSuppression()
                    }
                    .task {
                        markSelectedConversationRead()
                    }
                    .onChange(of: workspace.conversations) {
                        markSelectedConversationRead()
                        refreshLiveActivitySummary()
                    }
                    .onChange(of: selectedConversationID) {
                        markSelectedConversationRead()
                        refreshLiveActivitySummary()
                    }
                    .onChange(of: voice.isRecording) { _, isRecording in
                        audio.refresh(isRecording: isRecording)
                        refreshWakeSuppression()
                    }
                    .onChange(of: currentIsRunning) {
                        refreshWakeSuppression()
                    }
                    .onChange(of: liveCallSession?.id) {
                        refreshWakeSuppression()
                    }
                    .onChange(of: wake.detectionCount) { oldValue, newValue in
                        guard newValue > oldValue else { return }
                        handleWakeDetected()
                    }
                }
                .disabled(showingConversations)
                .accessibilityHidden(showingConversations)

                if showingConversations {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeConversations()
                        }
                        .transition(.opacity)

                    ConversationPicker(
                        conversations: workspace.conversations,
                        selectedID: selectedConversationID,
                        client: client,
                        audio: audio,
                        wake: wake,
                        onSelect: { id in
                            selection = .conversation(id)
                            closeConversations()
                        },
                        onNewChat: {
                            startNewChat()
                            closeConversations()
                        },
                        onDelete: deleteConversation,
                        onCopyTranscript: { conversation in
                            copyToPasteboard(conversation.transcriptText)
                        },
                        onCopyChatID: { conversation in
                            copyToPasteboard(conversation.threadId)
                        },
                        onClose: closeConversations
                    )
                    .frame(width: sidebarWidth(for: geometry.size.width))
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .clipShape(RoundedCorner(radius: 28, corners: [.topRight, .bottomRight]))
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(IOSTheme.hairline)
                            .frame(width: 1)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 30, x: 10, y: 0)
                    .ignoresSafeArea(edges: .vertical)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: showingConversations)
        }
        .fullScreenCover(item: $liveCallSession) { session in
            LiveCallView(
                client: client,
                workspace: workspace,
                voice: voice,
                audio: audio,
                initialConversationID: session.conversationID,
                onConversationStarted: { id in
                    selection = .conversation(id)
                },
                onDismiss: {
                    liveCallSession = nil
                    refreshWakeSuppression()
                    refreshLiveActivitySummary()
                }
            )
        }
    }

    private var selectedConversation: Conversation? {
        guard let selectedConversationID else { return nil }
        return workspace.conversation(id: selectedConversationID)
    }

    private var selectedConversationID: UUID? {
        if case .conversation(let id) = selection {
            return id
        }
        return nil
    }

    private var currentIsRunning: Bool {
        selectedConversation?.isRunning ?? client.isSending
    }

    private func startNewChat() {
        selection = .newChat
    }

    private func startLiveCall() {
        guard liveCallSession == nil else { return }
        wake.updateSuppression(true)
        liveCallSession = LiveCallSession(conversationID: selectedConversationID)
    }

    private func handleWakeDetected() {
        guard !currentIsRunning else { return }
        if showingConversations {
            closeConversations()
        }
        startLiveCall()
    }

    private func refreshWakeSuppression() {
        wake.updateSuppression(voice.isRecording || currentIsRunning || liveCallSession != nil)
    }

    private func refreshLiveActivitySummary() {
        KishOSLiveActivityController.shared.updateSummary(
            conversations: workspace.conversations,
            selectedConversationID: selectedConversationID
        )
    }

    private func markSelectedConversationRead() {
        guard let selectedConversation else { return }
        workspace.markConversationRead(selectedConversation.id, at: selectedConversation.updatedAt)
    }

    private func closeConversations() {
        withAnimation(.easeInOut(duration: 0.22)) {
            showingConversations = false
        }
    }

    private func sidebarWidth(for containerWidth: CGFloat) -> CGFloat {
        min(356, max(304, containerWidth * 0.84))
    }

    private func send(_ text: String, attachments: [ChatAttachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingText = trimmed.isEmpty ? defaultAttachmentPrompt(for: attachments) : trimmed
        guard !outgoingText.isEmpty, attachments.allSatisfy(\.isReadyForSend) else { return }
        let requestAttachments = chatRequestAttachments(for: attachments)

        if client.isDisconnected {
            queue(outgoingText, attachments: attachments)
            return
        }

        let conversation: Conversation
        if let selectedConversationID,
           let existing = workspace.appendUserMessage(outgoingText, to: selectedConversationID, attachments: attachments) {
            conversation = existing
        } else {
            conversation = workspace.createConversation(firstMessage: outgoingText, attachments: attachments)
            selection = .conversation(conversation.id)
        }

        sendPreparedMessage(
            messageTextForAgent(outgoingText, attachments: attachments),
            attachments: requestAttachments,
            in: conversation,
            messageID: conversation.messages.last?.id
        )
    }

    private func sendPreparedMessage(_ text: String, attachments: [ChatRequestAttachment], in conversation: Conversation, messageID: UUID?) {
        Task {
            do {
                workspace.beginAgentResponse(in: conversation.id)
                let result = try await client.sendStreaming(
                    text,
                    threadId: conversation.threadId,
                    conversationId: conversation.id,
                    attachments: attachments
                ) { event in
                    handleStreamEvent(event, conversationId: conversation.id)
                }
                workspace.apply(result, to: conversation.id)
                await syncSharedConversations()
            } catch {
                if isOfflineError(error),
                   let messageID,
                   workspace.requeueMessageAfterOfflineFailure(conversationID: conversation.id, messageID: messageID) {
                    return
                }
                workspace.applyFailure(error, to: conversation.id)
            }
        }
    }

    private func queue(_ text: String, attachments: [ChatAttachment]) {
        let conversation: Conversation
        if let selectedConversationID,
           let existing = workspace.queueUserMessage(text, to: selectedConversationID, attachments: attachments) {
            conversation = existing
        } else {
            conversation = workspace.queueConversation(firstMessage: text, attachments: attachments)
        }
        selection = .conversation(conversation.id)
    }

    private func retrySelectedConversation() {
        guard let selectedConversationID else { return }
        retry(selectedConversationID)
    }

    private func retry(_ conversationId: UUID) {
        guard let retry = workspace.prepareRetryLastFailedMessage(in: conversationId) else { return }

        Task {
            do {
                workspace.beginAgentResponse(in: retry.conversation.id)
                let result = try await client.sendStreaming(
                    retry.message,
                    threadId: retry.conversation.threadId,
                    conversationId: retry.conversation.id,
                    attachments: retry.attachments
                ) { event in
                    handleStreamEvent(event, conversationId: retry.conversation.id)
                }
                workspace.apply(result, to: retry.conversation.id)
                await syncSharedConversations()
            } catch {
                workspace.applyFailure(error, to: retry.conversation.id)
            }
        }
    }

    private func handleStreamEvent(_ event: AgentStreamEvent, conversationId: UUID) {
        switch event.type {
        case "text":
            if let text = event.text {
                workspace.appendStreamingText(text, to: conversationId)
            }
        case "activity":
            if let text = event.text {
                workspace.appendActivity(text, to: conversationId)
            }
        case "tool":
            if let tool = event.tool {
                workspace.appendActivity("tool: \(tool.name)", to: conversationId)
            }
        case "approval":
            if let approval = event.approval {
                workspace.setApprovals([approval], for: conversationId)
                workspace.appendActivity("question asked", to: conversationId)
            }
        case "approval_result":
            if let approvalId = event.approvalId {
                workspace.removeApproval(approvalId, from: conversationId)
            }
            workspace.appendActivity(event.timedOut == true ? "question timed out" : "question answered", to: conversationId)
        case "status":
            if event.status == "waiting_approval" {
                workspace.appendActivity("waiting for answer", to: conversationId)
            }
        default:
            break
        }
    }

    private func answerQuestion(_ approval: ApprovalRequest, answer: String) {
        guard let selectedConversationID else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            do {
                try await client.answerApproval(approval.id, approved: true, answer: trimmed)
                workspace.recordApprovalAnswerAccepted(approval.id, in: selectedConversationID)
            } catch {
                workspace.recordApprovalAnswerFailure(error.localizedDescription, in: selectedConversationID)
            }
        }
    }

    private func cancelQuestion(_ approval: ApprovalRequest) {
        guard let selectedConversationID else { return }

        Task {
            do {
                try await client.answerApproval(approval.id, approved: false)
                workspace.recordApprovalAnswerRejected(approval.id, in: selectedConversationID)
            } catch {
                workspace.recordApprovalAnswerFailure(error.localizedDescription, in: selectedConversationID)
            }
        }
    }

    private func deleteConversation(_ id: UUID) {
        workspace.deleteConversation(id)
        if selectedConversationID == id {
            selection = .newChat
        }
        Task {
            try? await client.deleteConversation(id)
        }
    }

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    private func syncSharedConversations() async {
        do {
            let remote = try await client.fetchConversations()
            workspace.mergeRemoteConversations(remote)
            if let selectedConversationID, workspace.conversation(id: selectedConversationID) == nil {
                selection = .newChat
            }
        } catch {
            // Keep local conversations usable when the shared backend is unavailable.
        }
    }

    private func startSharedConversationSyncLoop() async {
        while !Task.isCancelled {
            if !client.isSending {
                await syncSharedConversations()
            }
            try? await Task.sleep(for: .seconds(8))
        }
    }

    private func startQueuedMessageLoop() async {
        while !Task.isCancelled {
            if client.canSendQueuedMessages {
                await drainQueuedMessages()
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func drainQueuedMessages() async {
        guard !isDrainingQueuedMessages else { return }
        isDrainingQueuedMessages = true
        defer { isDrainingQueuedMessages = false }

        while client.canSendQueuedMessages, let queued = workspace.nextQueuedMessage() {
            guard let prepared = workspace.prepareQueuedMessageForSending(
                conversationID: queued.conversation.id,
                messageID: queued.message.id
            ) else {
                continue
            }

            do {
                workspace.beginAgentResponse(in: prepared.conversation.id)
                let result = try await client.sendStreaming(
                    prepared.message,
                    threadId: prepared.conversation.threadId,
                    conversationId: prepared.conversation.id,
                    attachments: prepared.attachments
                ) { event in
                    handleStreamEvent(event, conversationId: prepared.conversation.id)
                }
                workspace.apply(result, to: prepared.conversation.id)
                await syncSharedConversations()
            } catch {
                if isOfflineError(error),
                   workspace.requeueMessageAfterOfflineFailure(conversationID: prepared.conversation.id, messageID: queued.message.id) {
                    return
                }
                workspace.applyFailure(error, to: prepared.conversation.id)
            }
        }
    }

    private func isOfflineError(_ error: Error) -> Bool {
        guard let agentError = error as? AgentClientError else { return false }
        if case .network = agentError {
            return true
        }
        return false
    }
}

private struct ChatScreen: View {
    @ObservedObject var client: KishAgentClient
    let conversation: Conversation?
    let isSending: Bool
    let runState: ConversationRunState?
    let agentStatus: AgentStatusSummary?
    let queuedMessageCount: Int
    let approvals: [ApprovalRequest]
    @ObservedObject var voice: VoiceController
    @ObservedObject var audio: AudioRouteMonitor
    let onSend: (String, [ChatAttachment]) -> Void
    let onRetry: (() -> Void)?
    let onQuestionAnswer: (ApprovalRequest, String) -> Void
    let onQuestionCancel: (ApprovalRequest) -> Void

    @State private var draft = ""
    @State private var pendingAttachments: [ChatAttachment] = []

    private var messages: [ChatMessage] {
        conversation?.messages ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if messages.isEmpty {
                            EmptyIOSChat()
                        } else {
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                IOSMessageTurn(
                                    message: message,
                                    previousUserText: previousUserText(before: index),
                                    isRunning: isSending
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: messages.last?.text) {
                    scrollToBottom(proxy)
                }
            }

            if let agentStatus {
                IOSAgentStatusStrip(summary: agentStatus)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let lastError = conversation?.lastError {
                IOSErrorBar(message: lastError, onRetry: onRetry)
            }

            if queuedMessageCount > 0 {
                IOSOfflineQueueBar(count: queuedMessageCount, isConnected: client.canSendQueuedMessages)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if client.isDisconnected {
                IOSOfflineQueueBar(count: 0, isConnected: false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let pendingQuestion = approvals.first {
                IOSQuestionComposer(
                    approval: pendingQuestion,
                    onAnswer: { answer in
                        onQuestionAnswer(pendingQuestion, answer)
                    },
                    onCancel: {
                        onQuestionCancel(pendingQuestion)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                IOSComposer(
                    draft: $draft,
                    attachments: $pendingAttachments,
                    client: client,
                    isSending: client.isSending,
                    isDisabled: client.isSending || isSending,
                    runState: runState,
                    voice: voice,
                    onSend: sendDraft
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            IOSConnectionBar(client: client, voice: voice, audio: audio)
        }
        .background(IOSTheme.background)
        .animation(.easeInOut(duration: 0.2), value: approvals.first?.id)
        .animation(.easeInOut(duration: 0.2), value: client.isSending || isSending)
        .animation(.easeInOut(duration: 0.2), value: queuedMessageCount)
        .animation(.easeInOut(duration: 0.2), value: agentStatus?.detail)
    }

    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (hasDraft || hasSendableAttachment),
              pendingAttachments.allSatisfy(\.isReadyForSend),
              !client.isSending,
              !isSending,
              approvals.isEmpty
        else {
            return
        }
        let attachments = pendingAttachments
        draft = ""
        pendingAttachments = []
        onSend(trimmed, attachments)
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSendableAttachment: Bool {
        pendingAttachments.contains { $0.isReadyForSend }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func previousUserText(before index: Int) -> String {
        guard index > 0 else { return "" }
        return messages[..<index].last(where: { $0.sender == .user })?.text ?? ""
    }
}

private struct IOSChatHeaderTitle: View {
    let conversation: Conversation?

    var body: some View {
        VStack(spacing: 1) {
            Text(conversation?.title ?? "KishOS")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let conversation {
                Text(conversation.updatedDetailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 220)
    }
}

private struct IOSMessageTurn: View {
    let message: ChatMessage
    let previousUserText: String
    let isRunning: Bool

    var body: some View {
        VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 8) {
            if message.sender == .agent {
                IOSActivityBlock(
                    events: message.activityEvents,
                    messageText: message.text,
                    previousUserText: previousUserText,
                    isRunning: isRunning && message.deliveryState == .sending
                )
            }

            HStack {
                if message.sender == .user {
                    Spacer(minLength: 48)
                }

                VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 5) {
                    if !message.attachments.isEmpty {
                        VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 5) {
                            ForEach(message.attachments) { attachment in
                                IOSContextChip(attachment: attachment)
                            }
                        }
                    }

                    IOSMarkdownText(text: message.text, isUser: message.sender == .user)
                        .padding(.horizontal, message.sender == .user ? 13 : 0)
                        .padding(.vertical, message.sender == .user ? 10 : 0)
                        .background(message.sender == .user ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 17))
                        .foregroundStyle(message.sender == .user ? .white : .primary)
                        .textSelection(.enabled)

                    if let deliveryText {
                        Label(deliveryText, systemImage: deliveryIcon)
                            .font(.caption2)
                            .foregroundStyle(deliveryTint)
                    }
                }

                if message.sender == .agent {
                    Spacer(minLength: 48)
                }
            }
        }
    }

    private var deliveryText: String? {
        guard message.sender == .user else { return nil }
        switch message.deliveryState {
        case .queued:
            return "Saved locally"
        case .sending:
            return "Sending"
        case .failed:
            return "Failed"
        case .sent:
            return nil
        }
    }

    private var deliveryIcon: String {
        switch message.deliveryState {
        case .queued:
            return "clock"
        case .sending:
            return "arrow.up"
        case .failed:
            return "exclamationmark.circle"
        case .sent:
            return "checkmark"
        }
    }

    private var deliveryTint: Color {
        message.deliveryState == .failed ? .red : .secondary
    }
}

private struct IOSActivityBlock: View {
    let events: [String]
    let messageText: String
    let previousUserText: String
    let isRunning: Bool
    @State private var isExpanded = true
    private let disclosureAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)

    var body: some View {
        if !visibleEvents.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Button {
                    withAnimation(disclosureAnimation) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 10)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text("\(visibleEvents.count) Steps")
                            .font(.caption.weight(.semibold))
                        if isRunning {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 10, height: 10)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(visibleEvents.suffix(8).enumerated()), id: \.offset) { _, event in
                            HStack(alignment: .top, spacing: 8) {
                                if isRunning && event == visibleEvents.last {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 10, height: 10)
                                        .padding(.top, 3)
                                } else {
                                    Circle()
                                        .fill(Color.secondary.opacity(0.55))
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 7)
                                }

                                IOSMarkdownText(text: displayEvent(event), isUser: false, font: .caption, color: .secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .padding(.leading, 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
            .padding(.vertical, 1)
            .clipped()
            .animation(disclosureAnimation, value: isExpanded)
            .animation(disclosureAnimation, value: visibleEvents.count)
            .onAppear {
                isExpanded = isRunning
            }
            .onChange(of: isRunning) { _, newValue in
                withAnimation(disclosureAnimation) {
                    isExpanded = newValue
                }
            }
        }
    }

    private var visibleEvents: [String] {
        events.filter { event in
            let normalized = normalize(event)
            let normalizedMessage = normalize(messageText)
            let normalizedUser = normalize(previousUserText)
            guard !normalized.isEmpty else { return false }
            guard !isDuplicate(normalized, of: normalizedMessage) else { return false }
            guard !isDuplicate(normalized, of: normalizedUser) else { return false }
            guard !hiddenActivityEvents.contains(normalized) else { return false }
            guard !normalized.contains("askuserquestion") else { return false }
            if !isRunning && normalized == "waiting for reply" {
                return false
            }
            return true
        }
    }

    private func normalize(_ text: String) -> String {
        var output = IOSMarkdownNormalizer.normalize(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let prefixes = activityPrefixes + ["•", "-", "*", "thinking:", "reasoning:", "tool:"]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where output.hasPrefix(prefix) {
                output.removeFirst(prefix.count)
                output = output.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return output.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func isDuplicate(_ event: String, of text: String) -> Bool {
        guard !event.isEmpty, !text.isEmpty else { return false }
        let trimmedEvent = event.trimmingCharacters(in: CharacterSet(charactersIn: "…."))
        return event == text || text.hasPrefix(trimmedEvent) || event.hasPrefix(text)
    }

    private func displayEvent(_ text: String) -> String {
        var output = IOSMarkdownNormalizer.normalize(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for prefix in activityPrefixes where output.hasPrefix(prefix) {
                output.removeFirst(prefix.count)
                output = output.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return output
    }

    private var activityPrefixes: [String] {
        ["💭", "🧠", "💻", "📖", "🔎", "🌐", "📋", "✏️", "📝", "🖼", "❓", "✅", "🔧"]
    }

    private var hiddenActivityEvents: Set<String> {
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

private struct IOSComposer: View {
    @Binding var draft: String
    @Binding var attachments: [ChatAttachment]
    @ObservedObject var client: KishAgentClient
    let isSending: Bool
    let isDisabled: Bool
    let runState: ConversationRunState?
    @ObservedObject var voice: VoiceController
    let onSend: () -> Void

    @State private var showingTextCapture = false
    @State private var showingPhotoPicker = false
    @State private var showingFilePicker = false
    @State private var scanError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            IOSContextChip(
                                attachment: attachment,
                                onRemove: {
                                    AttachmentPayloadCache.shared.removePayload(for: attachment)
                                    attachments.removeAll { $0.id == attachment.id }
                                },
                                onRetry: attachment.uploadState == .failed ? {
                                    retryUpload(attachment.id)
                                } : nil
                            )
                        }
                    }
                }
            }

            if let scanError {
                Text(scanError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if hasBlockedAttachment {
                Text(blockedAttachmentText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .bottom, spacing: 8) {
                if voice.isRecording {
                    IOSComposerCircleButton(
                        systemName: "stop.fill",
                        tint: .red,
                        isEnabled: true,
                        action: cancelDictation
                    )
                    .accessibilityLabel("Stop dictation")
                } else {
                    Menu {
                        Button("Camera", systemImage: "camera") {
                            scanError = nil
                            showingTextCapture = true
                        }
                        Button("Choose a photo", systemImage: "photo") {
                            scanError = nil
                            showingPhotoPicker = true
                        }
                        Button("Select a file", systemImage: "doc") {
                            scanError = nil
                            showingFilePicker = true
                        }
                    } label: {
                        Circle()
                            .fill(IOSTheme.elevatedBackground)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color(uiColor: .label))
                            }
                            .overlay(Circle().stroke(IOSTheme.hairline))
                            .frame(width: 46, height: 46)
                    }
                    .tint(Color(uiColor: .label))
                    .disabled(isDisabled)
                    .accessibilityLabel("Add")
                }

                HStack(alignment: .bottom, spacing: 8) {
                    Group {
                        if voice.isRecording {
                            IOSWaveformInputSurface(transcript: voice.transcript)
                        } else {
                            TextField("Ask KishOS", text: $draft, axis: .vertical)
                                .lineLimit(1...5)
                                .textFieldStyle(.plain)
                                .onSubmit {
                                    if hasSendableContent {
                                        onSend()
                                    }
                                }
                                .disabled(isDisabled)
                                .padding(.leading, 16)
                                .padding(.vertical, 13)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)

                    if let runState, runState.isActive {
                        IOSRunStatePill(runState: runState)
                    }

                    Button(action: trailingAction) {
                        if isSending || hasUploadingAttachment {
                            ProgressView()
                                .frame(width: 18, height: 18)
                        } else {
                            Image(systemName: trailingIconName)
                                .font(.system(size: 15, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(trailingButtonColor, in: Circle())
                    .disabled(trailingButtonDisabled)
                    .accessibilityLabel(trailingAccessibilityLabel)
                    .padding(.trailing, 5)
                    .padding(.vertical, 4)
                }
                .background(IOSTheme.background, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).stroke(IOSTheme.hairline))
            }
        }
        .opacity(isDisabled ? 0.62 : 1)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .sheet(isPresented: $showingTextCapture) {
            CameraTextCaptureView(sourceType: .camera, onResult: { result in
                handleAttachmentSelection(result)
                showingTextCapture = false
            }, onCancel: {
                showingTextCapture = false
            })
        }
        .sheet(isPresented: $showingPhotoPicker) {
            CameraTextCaptureView(sourceType: .photoLibrary, onResult: { result in
                handleAttachmentSelection(result)
                showingPhotoPicker = false
            }, onCancel: {
                showingPhotoPicker = false
            })
        }
        .sheet(isPresented: $showingFilePicker) {
            FileTextPickerView(onResult: { result in
                handleAttachmentSelection(result)
                showingFilePicker = false
            }, onCancel: {
                showingFilePicker = false
            })
        }
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSendableContent: Bool {
        hasDraft || attachments.contains { $0.isReadyForSend }
    }

    private var hasUploadingAttachment: Bool {
        attachments.contains { $0.uploadState == .uploading }
    }

    private var hasBlockedAttachment: Bool {
        attachments.contains { $0.needsUpload && $0.uploadState != .uploading && $0.uploadState != .ready }
    }

    private var blockedAttachmentText: String {
        attachments.first(where: { $0.needsUpload && $0.uploadState != .uploading && $0.uploadState != .ready })?.uploadError
            ?? "Attachment needs upload."
    }

    private var trailingIconName: String {
        if voice.isRecording {
            return "checkmark"
        }
        return hasSendableContent ? "arrow.up" : "mic.fill"
    }

    private var trailingButtonColor: Color {
        if trailingButtonDisabled {
            return Color(uiColor: .systemGray4)
        }
        if voice.isRecording {
            return Color(uiColor: .label)
        }
        return Color(uiColor: .label)
    }

    private var trailingButtonDisabled: Bool {
        if voice.isRecording {
            return false
        }
        if hasSendableContent {
            return isDisabled || isSending || hasUploadingAttachment || hasBlockedAttachment
        }
        return isDisabled || isSending
    }

    private var trailingAccessibilityLabel: String {
        if voice.isRecording {
            return "Accept dictation"
        }
        return hasSendableContent ? "Send" : "Start dictation"
    }

    private func trailingAction() {
        if voice.isRecording {
            acceptDictation()
        } else if hasSendableContent {
            onSend()
        } else {
            startDictation()
        }
    }

    private func handleAttachmentSelection(_ result: Result<ChatAttachment, Error>) {
        switch result {
        case .success(let attachment):
            scanError = nil
            var pending = attachment
            if pending.needsUpload {
                pending.uploadState = .uploading
            }
            attachments.append(pending)
            if pending.needsUpload {
                uploadAttachment(pending.id)
            }
        case .failure(let error):
            scanError = error.localizedDescription
        }
    }

    private func retryUpload(_ attachmentId: UUID) {
        updateAttachment(attachmentId) { attachment in
            attachment.uploadState = .uploading
            attachment.uploadError = nil
        }
        uploadAttachment(attachmentId)
    }

    private func uploadAttachment(_ attachmentId: UUID) {
        guard !client.isDisconnected else {
            updateAttachment(attachmentId) { attachment in
                attachment.uploadState = .failed
                attachment.uploadError = "Reconnect to upload."
            }
            return
        }

        Task {
            guard let attachment = attachments.first(where: { $0.id == attachmentId }) else { return }
            do {
                let payload = try AttachmentPayloadCache.shared.payload(for: attachment)
                let uploaded = try await client.uploadAttachment(payload)
                let shouldKeepLocalPreview = attachment.kind == .image || uploaded.kind == ChatAttachment.Kind.image.rawValue
                if !shouldKeepLocalPreview {
                    AttachmentPayloadCache.shared.removePayload(for: attachment)
                }
                updateAttachment(attachmentId) { current in
                    current.title = uploaded.filename
                    current.mimeType = uploaded.mimeType ?? current.mimeType
                    current.byteCount = uploaded.byteCount ?? current.byteCount
                    current.uploadId = uploaded.id
                    if !shouldKeepLocalPreview {
                        current.localFilename = nil
                    }
                    current.uploadState = .ready
                    current.uploadError = nil
                    if uploaded.kind == ChatAttachment.Kind.image.rawValue {
                        current.kind = .image
                    }
                }
            } catch {
                updateAttachment(attachmentId) { current in
                    current.uploadState = .failed
                    current.uploadError = error.localizedDescription
                }
            }
        }
    }

    private func updateAttachment(_ id: UUID, transform: (inout ChatAttachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        transform(&attachments[index])
    }

    private func startDictation() {
        Task {
            await voice.startRecording()
        }
    }

    private func acceptDictation() {
        if let transcript = voice.stopRecording() {
            appendTranscript(transcript)
        }
    }

    private func cancelDictation() {
        _ = voice.stopRecording()
    }

    private func appendTranscript(_ transcript: String) {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = existing.isEmpty ? clean : "\(existing) \(clean)"
    }
}

private struct IOSComposerCircleButton: View {
    let systemName: String
    let tint: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isEnabled ? tint.opacity(0.14) : Color(uiColor: .systemGray5))
                .overlay {
                    Image(systemName: systemName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isEnabled ? tint : .secondary)
                }
                .overlay(Circle().stroke(IOSTheme.hairline))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct IOSWaveformInputSurface: View {
    let transcript: String
    @State private var isAnimating = false

    private let bars: [CGFloat] = [
        0.34, 0.62, 0.46, 0.82, 0.52, 0.72, 0.38, 0.66,
        0.44, 0.78, 0.48, 0.60, 0.36, 0.68, 0.50, 0.86,
        0.54, 0.74, 0.40, 0.64, 0.46, 0.80, 0.52, 0.70
    ]

    private var cleanTranscript: String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cleanTranscript.isEmpty ? "Listening" : cleanTranscript)
                .font(.callout)
                .foregroundStyle(cleanTranscript.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { proxy in
                HStack(alignment: .center, spacing: 4) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
                        Capsule()
                            .fill(Color(uiColor: .label).opacity(0.86))
                            .frame(
                                width: barWidth(for: proxy.size.width),
                                height: barHeight(value, index: index)
                            )
                            .animation(
                                .easeInOut(duration: 0.55 + Double(index % 3) * 0.08)
                                    .repeatForever(autoreverses: true),
                                value: isAnimating
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .clipped()
            }
            .frame(height: 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cleanTranscript.isEmpty ? "Listening" : cleanTranscript)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.vertical, cleanTranscript.isEmpty ? 9 : 8)
        .onAppear {
            isAnimating = true
        }
    }

    private func barWidth(for availableWidth: CGFloat) -> CGFloat {
        let totalSpacing = CGFloat(max(0, bars.count - 1)) * 4
        return max(3, min(7, (availableWidth - totalSpacing) / CGFloat(bars.count)))
    }

    private func barHeight(_ value: CGFloat, index: Int) -> CGFloat {
        let base = 6 + value * 16
        let delta = isAnimating ? CGFloat((index % 2) == 0 ? 6 : -4) : 0
        return max(6, min(24, base + delta))
    }
}

private struct IOSQuestionComposer: View {
    let approval: ApprovalRequest
    let onAnswer: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedOptions: Set<String> = []
    @State private var otherAnswer = ""

    private var question: ApprovalQuestion {
        approval.questions.first ?? ApprovalQuestion(header: "Question", question: approval.summary, multiSelect: false, options: [])
    }

    private var allowsMultiple: Bool {
        question.multiSelect == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayHeader)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(question.question)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
            }

            if !question.options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(question.options, id: \.label) { option in
                        Button {
                            answer(option.label)
                        } label: {
                            HStack(spacing: 8) {
                                if allowsMultiple {
                                    Image(systemName: selectedOptions.contains(option.label) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedOptions.contains(option.label) ? Color.accentColor : Color.secondary)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.callout)
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(IOSTheme.hairline))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Other", text: $otherAnswer, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(IOSTheme.hairline))
                    .onSubmit(sendOther)

                Button(action: sendOther) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(otherAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if allowsMultiple && !selectedOptions.isEmpty {
                HStack {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Send selected") {
                        onAnswer(selectedOptions.sorted().joined(separator: ", "))
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                HStack {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
            }
        }
        .padding(12)
        .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(IOSTheme.hairline))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var displayHeader: String {
        let clean = question.header.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "Question 1" ? "Question" : clean
    }

    private func answer(_ label: String) {
        if allowsMultiple {
            if selectedOptions.contains(label) {
                selectedOptions.remove(label)
            } else {
                selectedOptions.insert(label)
            }
        } else {
            onAnswer(label)
        }
    }

    private func sendOther() {
        let clean = otherAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        onAnswer(clean)
    }
}

private struct IOSConnectionBar: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var voice: VoiceController
    @ObservedObject var audio: AudioRouteMonitor

    var body: some View {
        HStack(spacing: 8) {
            StatusChip(title: "Mini", value: client.miniStatus)
            StatusChip(title: "Agent", value: client.agentStatus)
            StatusChip(title: "Chat", value: client.chatStatus)
            StatusChip(title: "Audio", value: voice.isRecording ? "Listening" : audio.statusLabel)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

}

private struct StatusChip: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private var tint: Color {
        switch value {
        case "Online", "Ready", "On", "System", "Bluetooth", "Glasses":
            return .green
        case "Sending", "Checking", "Listening", "Question":
            return .orange
        case "Error", "Offline":
            return .red
        default:
            return .secondary
        }
    }
}

private struct IOSRunStatePill: View {
    let runState: ConversationRunState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(runState.isActive ? .orange : .green)
                .frame(width: 6, height: 6)
            Text(runState.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(IOSTheme.elevatedBackground, in: Capsule())
        .overlay(Capsule().stroke(IOSTheme.hairline))
    }
}

private struct IOSContextChip: View {
    let attachment: ChatAttachment
    var onRemove: (() -> Void)?
    var onRetry: (() -> Void)?

    var body: some View {
        if attachment.kind == .image, let previewImage {
            imagePreview(previewImage)
        } else {
            fallbackChip
        }
    }

    private var fallbackChip: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption2.weight(.semibold))
            Text(attachment.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if let stateText {
                Text(stateText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(stateTint)
            }
            if attachment.uploadState == .uploading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12, height: 12)
            }
            if let onRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry \(attachment.title)")
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.title)")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(IOSTheme.elevatedBackground, in: Capsule())
        .overlay(Capsule().stroke(strokeTint))
    }

    private func imagePreview(_ image: UIImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: previewWidth, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(strokeTint, lineWidth: attachment.uploadState == .failed ? 1.2 : 0.8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.62), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(5)
                .accessibilityLabel("Remove \(attachment.title)")
            }

            if attachment.uploadState == .uploading {
                previewStatusOverlay {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                    Text("Uploading")
                        .font(.caption2.weight(.semibold))
                }
            } else if attachment.uploadState == .failed {
                previewStatusOverlay {
                    if let onRetry {
                        Button(action: onRetry) {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .accessibilityLabel("Retry \(attachment.title)")
                    } else {
                        Text("Failed")
                            .font(.caption2.weight(.bold))
                    }
                }
            }
        }
        .frame(width: previewWidth, height: previewHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attachment.title)
        .accessibilityValue(stateText ?? "Ready")
    }

    private func previewStatusOverlay<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 5) {
                content()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.62), in: Capsule())
            .padding(6)
        }
        .frame(width: previewWidth, height: previewHeight)
    }

    private var previewImage: UIImage? {
        guard let url = AttachmentPayloadCache.shared.cachedFileURL(for: attachment) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private var previewWidth: CGFloat {
        onRemove == nil ? 220 : 118
    }

    private var previewHeight: CGFloat {
        onRemove == nil ? 150 : 88
    }

    private var iconName: String {
        switch attachment.kind {
        case .text:
            return "text.alignleft"
        case .image:
            return "photo"
        case .file:
            return "doc"
        case .url:
            return "link"
        }
    }

    private var stateText: String? {
        switch attachment.uploadState {
        case .uploading:
            return "Uploading"
        case .failed:
            return "Failed"
        case .local:
            return attachment.needsUpload ? "Waiting" : nil
        case .ready:
            return nil
        }
    }

    private var stateTint: Color {
        attachment.uploadState == .failed ? .red : .secondary
    }

    private var strokeTint: Color {
        attachment.uploadState == .failed ? .red.opacity(0.55) : IOSTheme.hairline
    }
}

private struct ConversationPicker: View {
    let conversations: [Conversation]
    let selectedID: UUID?
    @ObservedObject var client: KishAgentClient
    @ObservedObject var audio: AudioRouteMonitor
    @ObservedObject var wake: WakePhraseController
    let onSelect: (UUID) -> Void
    let onNewChat: () -> Void
    let onDelete: (UUID) -> Void
    let onCopyTranscript: (Conversation) -> Void
    let onCopyChatID: (Conversation) -> Void
    let onClose: () -> Void

    @State private var agentURLDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("KishOS")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(conversationCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(IOSTheme.elevatedBackground.opacity(0.85), in: Circle())
                .accessibilityLabel("Close conversations")
            }
            .padding(.horizontal, 18)
            .padding(.top, 64)
            .padding(.bottom, 14)

            Button(action: onNewChat) {
                HStack(spacing: 12) {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Text("New chat")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .frame(height: 58)
                .background(IOSTheme.elevatedBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(IOSTheme.hairline)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            IOSConnectionPanel(
                client: client,
                audio: audio,
                wake: wake,
                agentURLDraft: $agentURLDraft,
                onReconnect: reconnect,
                onReset: resetAgentURL
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 18)

            if !pendingDecisionConversations.isEmpty {
                HStack {
                    Text("Questions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

                VStack(spacing: 6) {
                    ForEach(pendingDecisionConversations) { conversation in
                        DecisionPickerRow(
                            conversation: conversation,
                            isSelected: selectedID == conversation.id,
                            onSelect: {
                                onSelect(conversation.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
            }

            HStack {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)

            if conversations.isEmpty {
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("No chats yet")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Start a conversation and it will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(sortedConversations) { conversation in
                            ConversationPickerRow(
                                conversation: conversation,
                                isSelected: selectedID == conversation.id,
                                updatedText: relativeUpdatedText(for: conversation.updatedAt),
                                onSelect: {
                                    onSelect(conversation.id)
                                },
                                onCopyTranscript: {
                                    onCopyTranscript(conversation)
                                },
                                onCopyChatID: {
                                    onCopyChatID(conversation)
                                },
                                onDelete: {
                                    onDelete(conversation.id)
                                }
                            )
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    onDelete(conversation.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(IOSTheme.groupedBackground.opacity(0.72))
        .onAppear {
            agentURLDraft = client.agentURLString
            audio.refresh()
        }
    }

    private var sortedConversations: [Conversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var pendingDecisionConversations: [Conversation] {
        sortedConversations.filter { !$0.approvals.isEmpty }
    }

    private var conversationCountText: String {
        conversations.count == 1 ? "1 conversation" : "\(conversations.count) conversations"
    }

    private func relativeUpdatedText(for date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func reconnect() {
        _ = client.updateBaseURL(agentURLDraft)
        Task {
            await client.reconnect()
            agentURLDraft = client.agentURLString
        }
    }

    private func resetAgentURL() {
        client.resetBaseURL()
        agentURLDraft = client.agentURLString
        Task {
            await client.reconnect()
        }
    }
}

private struct IOSConnectionPanel: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var audio: AudioRouteMonitor
    @ObservedObject var wake: WakePhraseController
    @Binding var agentURLDraft: String
    let onReconnect: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Agent URL", text: $agentURLDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(IOSTheme.hairline))

                Button(action: onReconnect) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Reconnect")

                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Reset agent URL")
            }

            HStack(spacing: 8) {
                StatusChip(title: "Mini", value: client.miniStatus)
                StatusChip(title: "Agent", value: client.agentStatus)
                StatusChip(title: "Chat", value: client.chatStatus)
                StatusChip(title: "Audio", value: audio.statusLabel)
            }

            HStack(spacing: 8) {
                Button {
                    audio.setPrefersHandsFreeRoute(!audio.prefersHandsFreeRoute)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(audio.prefersHandsFreeRoute ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text("External")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(IOSTheme.secondaryBackground, in: Capsule())
                    .overlay(Capsule().stroke(IOSTheme.hairline))
                }
                .buttonStyle(.plain)

                Button {
                    wake.setEnabled(!wake.isEnabled)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(wakeTint)
                            .frame(width: 7, height: 7)
                        Text("Wake")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(IOSTheme.secondaryBackground, in: Capsule())
                    .overlay(Capsule().stroke(IOSTheme.hairline))
                }
                .buttonStyle(.plain)

                Text(wake.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(audio.routeDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(IOSTheme.elevatedBackground.opacity(0.74), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IOSTheme.hairline))
    }

    private var wakeTint: Color {
        if wake.isListening {
            return .green
        }
        return wake.isEnabled ? .orange : .secondary
    }
}

private struct DecisionPickerRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 11) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 34, height: 34)
                    .background(Color.orange.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(conversation.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(conversation.approvals.count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }

                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(isSelected ? Color.orange.opacity(0.14) : IOSTheme.elevatedBackground.opacity(0.74), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.orange.opacity(0.25) : IOSTheme.hairline)
        )
    }

    private var summary: String {
        let clean = conversation.approvals.first?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? "Needs answer" : clean
    }
}

private struct ConversationPickerRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let updatedText: String
    let onSelect: () -> Void
    let onCopyTranscript: () -> Void
    let onCopyChatID: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.13))
                    Image(systemName: isSelected ? "text.bubble.fill" : "text.bubble")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .secondary)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(conversation.title)
                            .font(.callout.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if conversation.runState.isActive {
                            IOSRunStatePill(runState: conversation.runState)
                        }

                        Spacer(minLength: 8)

                        Text(updatedText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(rowDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Transcript", action: onCopyTranscript)
            Button("Copy Chat ID", action: onCopyChatID)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.22) : IOSTheme.hairline)
        )
    }

    private var rowBackground: Color {
        isSelected ? Color.accentColor.opacity(0.10) : IOSTheme.elevatedBackground.opacity(0.74)
    }

    private var rowDetail: String {
        if conversation.runState.isActive {
            return "\(conversation.runState.label) - \(conversation.updatedTimestampText)"
        }
        return conversation.updatedDetailText
    }
}

private struct IOSAgentStatusStrip: View {
    let summary: AgentStatusSummary

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(summary.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(summary.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(IOSTheme.secondaryBackground)
    }

    private var tint: Color {
        switch summary.tone {
        case .running:
            return .orange
        case .working:
            return .blue
        case .needsAnswer:
            return .purple
        case .queued:
            return .secondary
        case .failed:
            return .red
        }
    }
}

private struct IOSErrorBar: View {
    let message: String
    let onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if let onRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Retry")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(IOSTheme.secondaryBackground)
    }
}

private struct IOSOfflineQueueBar: View {
    let count: Int
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isConnected ? "arrow.clockwise" : "wifi.slash")
                .foregroundStyle(isConnected ? .orange : .secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(IOSTheme.secondaryBackground)
    }

    private var message: String {
        if count > 0 {
            return isConnected
                ? "Sending \(count) saved message\(count == 1 ? "" : "s")"
                : "\(count) message\(count == 1 ? "" : "s") saved locally"
        }
        return "Offline. Messages will be saved locally."
    }
}

private struct EmptyIOSChat: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Ask KishOS")
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }
}

private struct IOSMarkdownText: View {
    let text: String
    let isUser: Bool
    var font: Font = .body
    var color: Color? = nil

    var body: some View {
        Text(markdown)
            .font(font)
            .lineSpacing(4)
            .foregroundStyle(color ?? (isUser ? Color.white : Color.primary))
    }

    private var markdown: AttributedString {
        let normalized = IOSMarkdownNormalizer.normalize(text)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if let attributed = try? AttributedString(markdown: normalized, options: options) {
            return attributed
        }
        return AttributedString(text)
    }
}

private enum IOSMarkdownNormalizer {
    static func normalize(_ text: String) -> String {
        replace(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, in: text, template: #"**$1**"#)
    }

    private static func replace(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
