import SwiftUI

private enum IOSTheme {
    static let background = Color(uiColor: .systemBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
    static let hairline = Color.secondary.opacity(0.18)
}

struct KishOSIOSRootView: View {
    @StateObject private var client = KishAgentClient()
    @StateObject private var workspace = KishOSWorkspace()
    @StateObject private var voice = VoiceController()

    @State private var selectedConversationID: UUID?
    @State private var showingConversations = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    ChatScreen(
                        client: client,
                        conversation: selectedConversation,
                        isSending: currentIsRunning,
                        approvals: selectedConversation?.approvals ?? [],
                        voice: voice,
                        onSend: send,
                        onQuestionAnswer: answerQuestion
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

                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: startNewChat) {
                                Image(systemName: "square.and.pencil")
                            }
                            .accessibilityLabel("New chat")
                        }
                    }

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
                            onSelect: { id in
                                selectedConversationID = id
                                closeConversations()
                            },
                            onNewChat: {
                                startNewChat()
                                closeConversations()
                            },
                            onDelete: deleteConversation,
                            onClose: closeConversations
                        )
                        .frame(width: sidebarWidth(for: geometry.size.width))
                        .frame(maxHeight: .infinity)
                        .background(IOSTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 24, x: 10, y: 0)
                        .padding(.vertical, 8)
                        .padding(.leading, 8)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: showingConversations)
            }
            .task {
                await client.startHealthPolling()
            }
            .task {
                await startSharedConversationSyncLoop()
            }
            .onAppear {
                selectedConversationID = selectedConversationID ?? workspace.conversations.first?.id
            }
        }
    }

    private var selectedConversation: Conversation? {
        guard let selectedConversationID else { return nil }
        return workspace.conversation(id: selectedConversationID)
    }

    private var currentIsRunning: Bool {
        selectedConversation?.isRunning ?? client.isSending
    }

    private func startNewChat() {
        selectedConversationID = nil
    }

    private func closeConversations() {
        withAnimation(.easeInOut(duration: 0.22)) {
            showingConversations = false
        }
    }

    private func sidebarWidth(for containerWidth: CGFloat) -> CGFloat {
        min(340, max(292, containerWidth * 0.86))
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let conversation: Conversation
        if let selectedConversationID,
           let existing = workspace.appendUserMessage(trimmed, to: selectedConversationID) {
            conversation = existing
        } else {
            conversation = workspace.createConversation(firstMessage: trimmed)
            selectedConversationID = conversation.id
        }

        Task {
            do {
                workspace.beginAgentResponse(in: conversation.id)
                let result = try await client.sendStreaming(trimmed, threadId: conversation.threadId, conversationId: conversation.id) { event in
                    handleStreamEvent(event, conversationId: conversation.id)
                }
                workspace.apply(result, to: conversation.id)
                await syncSharedConversations()
            } catch {
                workspace.applyFailure(error, to: conversation.id)
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
        workspace.appendActivity("answered question", to: selectedConversationID)
        workspace.removeApproval(approval.id, from: selectedConversationID)

        Task {
            do {
                try await client.answerApproval(approval.id, approved: true, answer: trimmed)
            } catch {
                workspace.appendActivity(error.localizedDescription, to: selectedConversationID)
            }
        }
    }

    private func deleteConversation(_ id: UUID) {
        workspace.deleteConversation(id)
        if selectedConversationID == id {
            selectedConversationID = workspace.conversations.first?.id
        }
        Task {
            try? await client.deleteConversation(id)
        }
    }

    private func syncSharedConversations() async {
        do {
            let remote = try await client.fetchConversations()
            workspace.mergeRemoteConversations(remote)
            selectedConversationID = selectedConversationID ?? workspace.conversations.first?.id
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
}

private struct ChatScreen: View {
    @ObservedObject var client: KishAgentClient
    let conversation: Conversation?
    let isSending: Bool
    let approvals: [ApprovalRequest]
    @ObservedObject var voice: VoiceController
    let onSend: (String) -> Void
    let onQuestionAnswer: (ApprovalRequest, String) -> Void

    @State private var draft = ""

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

            if let lastError = conversation?.lastError {
                IOSErrorBar(message: lastError)
            }

            if let pendingQuestion = approvals.first {
                IOSQuestionComposer(approval: pendingQuestion) { answer in
                    onQuestionAnswer(pendingQuestion, answer)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                IOSComposer(
                    draft: $draft,
                    isSending: client.isSending,
                    isDisabled: client.isSending || isSending,
                    voice: voice,
                    onSend: sendDraft
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            IOSConnectionBar(client: client, voice: voice)
        }
        .background(IOSTheme.background)
        .animation(.easeInOut(duration: 0.2), value: approvals.first?.id)
        .animation(.easeInOut(duration: 0.2), value: client.isSending || isSending)
    }

    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !client.isSending, !isSending, approvals.isEmpty else { return }
        draft = ""
        onSend(trimmed)
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

                IOSMarkdownText(text: message.text, isUser: message.sender == .user)
                    .padding(.horizontal, message.sender == .user ? 13 : 0)
                    .padding(.vertical, message.sender == .user ? 10 : 0)
                    .background(message.sender == .user ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 17))
                    .foregroundStyle(message.sender == .user ? .white : .primary)
                    .textSelection(.enabled)

                if message.sender == .agent {
                    Spacer(minLength: 48)
                }
            }
        }
    }
}

private struct IOSActivityBlock: View {
    let events: [String]
    let messageText: String
    let previousUserText: String
    let isRunning: Bool
    @State private var isExpanded = true

    var body: some View {
        if !visibleEvents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 10)
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
                    VStack(alignment: .leading, spacing: 8) {
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(IOSTheme.hairline))
            .onAppear {
                isExpanded = isRunning
            }
            .onChange(of: isRunning) { _, newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
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
    let isSending: Bool
    let isDisabled: Bool
    @ObservedObject var voice: VoiceController
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleDictation) {
                Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic")
            }
            .foregroundStyle(voice.isRecording ? .red : .secondary)
            .disabled(isDisabled)

            TextField(voice.isRecording ? "Listening" : "Ask KishOS", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .onSubmit(onSend)
                .disabled(isDisabled)

            Button(action: onSend) {
                if isSending {
                    ProgressView()
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDisabled || isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .opacity(isDisabled ? 0.62 : 1)
        .padding(10)
        .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(IOSTheme.hairline))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func toggleDictation() {
        Task {
            if let transcript = await voice.toggleRecording() {
                appendTranscript(transcript)
            }
        }
    }

    private func appendTranscript(_ transcript: String) {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = existing.isEmpty ? clean : "\(existing) \(clean)"
    }
}

private struct IOSQuestionComposer: View {
    let approval: ApprovalRequest
    let onAnswer: (String) -> Void

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
                Button("Send selected") {
                    onAnswer(selectedOptions.sorted().joined(separator: ", "))
                }
                .buttonStyle(.borderedProminent)
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

    var body: some View {
        HStack(spacing: 8) {
            StatusChip(title: "Mini", online: client.miniStatus == "Online")
            StatusChip(title: "Agent", online: client.agentStatus == "Online")
            StatusChip(title: "Chat", online: client.chatStatus == "Ready")
            StatusChip(title: "Mic", online: voice.isRecording)
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
    let online: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(online ? .green : .secondary)
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .accessibilityLabel(title)
        .accessibilityValue(online ? "On" : "Off")
    }
}

private struct ConversationPicker: View {
    let conversations: [Conversation]
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onNewChat: () -> Void
    let onDelete: (UUID) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button(action: onNewChat) {
                    Label("New chat", systemImage: "plus.bubble")
                }

                Section("Conversations") {
                    ForEach(conversations) { conversation in
                        Button {
                            onSelect(conversation.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conversation.title)
                                        .lineLimit(1)
                                    Text(conversation.idea)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if selectedID == conversation.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                onDelete(conversation.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close conversations")
                }
            }
        }
    }
}

private struct IOSErrorBar: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(IOSTheme.secondaryBackground)
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
