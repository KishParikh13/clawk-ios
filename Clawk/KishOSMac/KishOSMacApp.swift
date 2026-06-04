import Foundation
import SwiftUI

private enum KishOSTheme {
    static let chatBackground = Color(nsColor: .textBackgroundColor)
    static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
    static let panelBackground = Color(nsColor: .controlBackgroundColor)
    static let cardBackground = Color(nsColor: .windowBackgroundColor).opacity(0.78)
    static let inputBackground = Color(nsColor: .windowBackgroundColor)
    static let pillBackground = Color.secondary.opacity(0.10)
    static let hairline = Color.secondary.opacity(0.16)
}

@main
struct KishOSMacApp: App {
    var body: some Scene {
        WindowGroup {
            MacRootView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
        }
    }
}

private struct MacRootView: View {
    @StateObject private var client = KishAgentClient()
    @StateObject private var workspace = KishOSWorkspace()
    @StateObject private var voice = VoiceController()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selection: SidebarSelection? = .newChat
    @State private var conversationToRename: Conversation?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section("Home") {
                    Label("New Chat", systemImage: "plus.bubble")
                        .tag(SidebarSelection.newChat)
                }

                if !workspace.conversations.isEmpty {
                    Section("Conversations") {
                        ForEach(workspace.conversations) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                onRename: { conversationToRename = conversation },
                                onDelete: { deleteConversation(conversation.id) }
                            )
                                .tag(SidebarSelection.conversation(conversation.id))
                        }
                    }
                }

                Section("System") {
                    Label("Roadmap", systemImage: "checklist")
                        .tag(SidebarSelection.roadmap)
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .tag(SidebarSelection.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .scrollContentBackground(.hidden)
            .background(KishOSTheme.sidebarBackground)
        } detail: {
            content
                .frame(minWidth: 720, minHeight: 520)
                .ignoresSafeArea(.container, edges: .top)
                .task {
                    await client.startHealthPolling()
                }
                .task {
                    await startSharedConversationSyncLoop()
                }
        }
        .sheet(item: $conversationToRename) { conversation in
            RenameConversationSheet(conversation: conversation) { title in
                workspace.renameConversation(conversation.id, title: title)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection ?? .newChat {
        case .newChat:
            ChatView(
                client: client,
                title: "New chat",
                subtitle: "Start a session",
                messages: [],
                isRunning: client.isSending,
                lastError: nil,
                approvals: [],
                onSend: { send($0, in: nil) },
                onRetry: nil,
                onRename: nil,
                onDelete: nil,
                onQuestionAnswer: nil,
                voice: voice,
                reservesTitleControlSpace: isSidebarCollapsed
            )
        case .conversation(let id):
            if let conversation = workspace.conversation(id: id) {
                ChatView(
                    client: client,
                    title: conversation.title,
                    subtitle: conversation.idea,
                    messages: conversation.messages,
                    isRunning: conversation.isRunning,
                    lastError: conversation.lastError,
                    approvals: conversation.approvals,
                    onSend: { send($0, in: conversation.id) },
                    onRetry: { retry(conversation.id) },
                    onRename: { conversationToRename = conversation },
                    onDelete: { deleteConversation(conversation.id) },
                    onQuestionAnswer: { approval, answer in answerQuestion(approval, answer: answer, in: conversation.id) },
                    voice: voice,
                    reservesTitleControlSpace: isSidebarCollapsed
                )
            } else {
                EmptySelectionView()
            }
        case .roadmap:
            RoadmapView()
        case .settings:
            SettingsView(client: client, voice: voice, storeError: workspace.storeError)
        }
    }

    private var isSidebarCollapsed: Bool {
        columnVisibility == .detailOnly
    }

    private func retry(_ conversationId: UUID) {
        guard let retry = workspace.prepareRetryLastFailedMessage(in: conversationId) else { return }

        Task {
            do {
                workspace.beginAgentResponse(in: retry.conversation.id)
                let result = try await client.sendStreaming(retry.message, threadId: retry.conversation.threadId, conversationId: retry.conversation.id) { event in
                    handleStreamEvent(event, conversationId: retry.conversation.id)
                }
                workspace.apply(result, to: retry.conversation.id)
                await syncSharedConversations()
            } catch {
                workspace.applyFailure(error, to: retry.conversation.id)
            }
        }
    }

    private func answerQuestion(_ approval: ApprovalRequest, answer: String, in conversationId: UUID) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await client.answerApproval(approval.id, approved: true, answer: trimmed)
                workspace.recordApprovalAnswerAccepted(approval.id, in: conversationId)
            } catch {
                workspace.recordApprovalAnswerFailure(error.localizedDescription, in: conversationId)
            }
        }
    }

    private func deleteConversation(_ id: UUID) {
        workspace.deleteConversation(id)
        if selection == .conversation(id) {
            selection = .newChat
        }
        Task {
            try? await client.deleteConversation(id)
        }
    }

    private func send(_ text: String, in conversationId: UUID?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let conversation: Conversation
        if let conversationId, let existing = workspace.appendUserMessage(trimmed, to: conversationId) {
            conversation = existing
        } else {
            conversation = workspace.createConversation(firstMessage: trimmed)
            selection = .conversation(conversation.id)
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

    private func syncSharedConversations() async {
        do {
            let remote = try await client.fetchConversations()
            workspace.mergeRemoteConversations(remote)
        } catch {
            // Keep the local cache usable if the shared backend is unavailable.
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

private struct ConversationRow: View {
    let conversation: Conversation
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(conversation.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if conversation.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                }
            }

            Text(conversation.threadId)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(conversation.isRunning ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Rename", action: onRename)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct ChatView: View {
    @ObservedObject var client: KishAgentClient
    let title: String
    let subtitle: String
    let messages: [ChatMessage]
    let isRunning: Bool
    let lastError: String?
    let approvals: [ApprovalRequest]
    let onSend: (String) -> Void
    let onRetry: (() -> Void)?
    let onRename: (() -> Void)?
    let onDelete: (() -> Void)?
    let onQuestionAnswer: ((ApprovalRequest, String) -> Void)?
    @ObservedObject var voice: VoiceController
    let reservesTitleControlSpace: Bool

    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(
                title: title,
                subtitle: subtitle,
                onRename: onRename,
                onDelete: onDelete,
                reservesTitleControlSpace: reservesTitleControlSpace
            )

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if messages.isEmpty {
                            EmptyChatPrompt()
                        } else {
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                MessageTurn(
                                    message: message,
                                    previousUserText: previousUserText(before: index),
                                    isRunning: isRunning
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .background(KishOSTheme.chatBackground)
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: messages.last?.text) {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if let lastError {
                ErrorRetryBar(message: lastError, onRetry: onRetry)
            }

            if let pendingQuestion = approvals.first {
                QuestionComposer(approval: pendingQuestion) { answer in
                    onQuestionAnswer?(pendingQuestion, answer)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ChatComposer(
                    draft: $draft,
                    isSending: client.isSending,
                    isDisabled: client.isSending || isRunning,
                    voice: voice,
                    onSend: sendDraft
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ConnectionStatusBar(client: client, voice: voice)
        }
        .background(KishOSTheme.chatBackground)
        .animation(.easeInOut(duration: 0.2), value: approvals.first?.id)
        .animation(.easeInOut(duration: 0.2), value: client.isSending || isRunning)
    }

    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !client.isSending, !isRunning, approvals.isEmpty else { return }
        draft = ""
        onSend(trimmed)
    }

    private func previousUserText(before index: Int) -> String {
        guard index > 0 else { return "" }
        return messages[..<index].last(where: { $0.sender == .user })?.text ?? ""
    }
}

private struct ChatHeader: View {
    let title: String
    let subtitle: String
    let onRename: (() -> Void)?
    let onDelete: (() -> Void)?
    let reservesTitleControlSpace: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if shouldShowSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if onRename != nil || onDelete != nil {
                Menu {
                    if let onRename {
                        Button("Rename", action: onRename)
                    }
                    if let onDelete {
                        Button("Delete", role: .destructive, action: onDelete)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(.leading, reservesTitleControlSpace ? 160 : 28)
        .padding(.trailing, 28)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private var shouldShowSubtitle: Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanSubtitle.isEmpty && cleanSubtitle != cleanTitle
    }
}

private struct ErrorRetryBar: View {
    let message: String
    let onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if let onRetry {
                Button("Retry", action: onRetry)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(KishOSTheme.panelBackground)
    }
}

private struct RenameConversationSheet: View {
    let conversation: Conversation
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    init(conversation: Conversation, onSave: @escaping (String) -> Void) {
        self.conversation = conversation
        self.onSave = onSave
        _title = State(initialValue: conversation.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename")
                .font(.headline)

            TextField("Name", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private func save() {
        onSave(title)
        dismiss()
    }
}

private struct EmptyChatPrompt: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Ask KishOS")
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, 120)
    }
}

private struct MessageTurn: View {
    let message: ChatMessage
    let previousUserText: String
    let isRunning: Bool

    var body: some View {
        VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 8) {
            if message.sender == .agent {
                AssistantActivityBlock(
                    events: message.activityEvents,
                    messageText: message.text,
                    previousUserText: previousUserText,
                    isRunning: isRunning && message.deliveryState == .sending
                )
            }

            ChatBubble(message: message)
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.sender == .user {
                Spacer(minLength: 80)
            }

            VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 5) {
                MarkdownText(text: message.text, isUser: message.sender == .user)
                    .textSelection(.enabled)
                    .padding(.horizontal, message.sender == .user ? 13 : 0)
                    .padding(.vertical, message.sender == .user ? 10 : 0)
                    .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(message.sender == .agent ? Color.clear : Color.white.opacity(0.08))
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if message.deliveryState == .failed {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(4)
                        }
                    }
            }
            .frame(maxWidth: message.sender == .user ? 540 : .infinity, alignment: message.sender == .user ? .trailing : .leading)

            if message.sender == .agent {
                Spacer(minLength: 80)
            }
        }
    }

    private var bubbleBackground: Color {
        switch message.sender {
        case .user:
            return .accentColor
        case .agent:
            return .clear
        }
    }
}

private struct AssistantActivityBlock: View {
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
                                .scaleEffect(0.62)
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
                                        .scaleEffect(0.62)
                                        .frame(width: 10, height: 10)
                                        .padding(.top, 3)
                                } else {
                                    Circle()
                                        .fill(Color.secondary.opacity(0.55))
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 7)
                                        .padding(.horizontal, 2.5)
                                }

                                MarkdownText(text: displayEvent(event), isUser: false, font: .caption, color: .secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 620, alignment: .leading)
            .background(KishOSTheme.pillBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(KishOSTheme.hairline)
            )
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
            let normalized = normalizedEvent(event)
            let normalizedMessage = normalizedEvent(messageText)
            let normalizedUser = normalizedEvent(previousUserText)
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

    private func normalizedEvent(_ text: String) -> String {
        var output = MarkdownNormalizer.normalize(text)
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
        var output = MarkdownNormalizer.normalize(text)
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

private struct MarkdownText: View {
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
        let normalized = MarkdownNormalizer.normalize(text)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if let attributed = try? AttributedString(markdown: normalized, options: options) {
            return attributed
        }
        return AttributedString(text)
    }
}

private enum MarkdownNormalizer {
    static func normalize(_ text: String) -> String {
        var output = text
        output = replace(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, in: output, template: #"**$1**"#)
        return output
    }

    private static func replace(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

private struct QuestionComposer: View {
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
                            .background(KishOSTheme.pillBackground, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(KishOSTheme.hairline))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Other", text: $otherAnswer)
                    .textFieldStyle(.roundedBorder)
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
        .background(KishOSTheme.inputBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(KishOSTheme.hairline)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 18, y: 8)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
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

private struct ChatComposer: View {
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
            .buttonStyle(.borderless)
            .foregroundStyle(voice.isRecording ? .red : .secondary)
            .help(voice.isRecording ? "Stop dictation" : "Dictate")
            .disabled(isDisabled)

            VStack(alignment: .leading, spacing: 2) {
                TextField(voice.isRecording ? "Listening" : "Ask KishOS", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit(onSend)
                    .disabled(isDisabled)

                if voice.isRecording && !voice.transcript.isEmpty {
                    Text(voice.transcript)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Button(action: onSend) {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDisabled || isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .opacity(isDisabled ? 0.62 : 1)
        .padding(10)
        .background(KishOSTheme.inputBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(KishOSTheme.hairline)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 18, y: 8)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
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

private struct RoadmapView: View {
    private let milestones = KishOSMilestone.allCases
    private let capabilities = KishOSFactoryPlan.capabilities

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Header(title: "Roadmap", subtitle: "Build order and test checkpoints")

                ForEach(milestones) { milestone in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(milestone.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(milestone.title)
                                .font(.headline)
                            Spacer()
                            Text(milestone.goal)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        let milestoneCapabilities = capabilities.filter { $0.milestone == milestone }
                        if !milestoneCapabilities.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(milestoneCapabilities) { capability in
                                    CapabilityPill(capability: capability)
                                }
                                Spacer()
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(milestone.userCheckpoint, id: \.self) { checkpoint in
                                HStack(alignment: .top, spacing: 7) {
                                    Image(systemName: "circle")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 3)
                                    Text(checkpoint)
                                        .font(.callout)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.quaternary)
                    )
                }
            }
            .padding(22)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct CapabilityPill: View {
    let capability: KishOSCapability

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(capability.title)
            Text(capability.state.rawValue)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.background, in: Capsule())
        .overlay(Capsule().stroke(.quaternary))
    }

    private var tint: Color {
        switch capability.state {
        case .available:
            return .green
        case .inProgress:
            return .orange
        case .planned:
            return .secondary
        case .off:
            return .red
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var voice: VoiceController
    let storeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Header(title: "Settings", subtitle: client.status)

            VStack(spacing: 10) {
                StatusRow(title: "Mac mini", value: client.miniStatus, tint: client.miniStatus == "Online" ? .green : .secondary)
                StatusRow(title: "HTTP", value: client.httpStatus, tint: client.httpStatus == "Online" ? .green : .secondary)
                StatusRow(title: "Agent", value: client.agentStatus, tint: client.agentStatus == "Online" ? .green : .secondary)
                StatusRow(title: "History", value: storeError == nil ? "On" : "Error", tint: storeError == nil ? .green : .red)
                StatusRow(title: "Tools", value: client.toolInventoryStatus, tint: client.toolInventoryStatus == "Ready" ? .green : .secondary)
            }

            ToolInventorySection(inventory: client.toolInventory)

            if let storeError {
                Text(storeError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(22)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ToolInventorySection: View {
    let inventory: ToolInventory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools")
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                ToolGroup(title: "Engines", items: inventory.engines.map { item in
                    ToolLine(title: item.name, detail: item.detail ?? item.status, status: item.status)
                })

                ToolGroup(title: "Commands", items: inventory.commands.map { item in
                    ToolLine(title: item.name, detail: item.status, status: item.status)
                })
            }

            ToolGroup(title: "Recent", items: inventory.recentTools.prefix(8).map { item in
                ToolLine(title: item.name, detail: "\(item.count)", status: "Available")
            })
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        )
    }
}

private struct ToolGroup: View {
    let title: String
    let items: [ToolLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if items.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.status == "Available" ? .green : .secondary)
                            .frame(width: 6, height: 6)
                        Text(item.title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(item.detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ToolLine: Identifiable {
    var id: String { "\(title)-\(detail)-\(status)" }
    let title: String
    let detail: String
    let status: String
}

private struct ConnectionStatusBar: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var voice: VoiceController

    var body: some View {
        HStack(spacing: 12) {
            MiniStatusChip(title: "Mini", value: client.miniStatus)
            MiniStatusChip(title: "Agent", value: client.agentStatus)
            MiniStatusChip(title: "Chat", value: client.chatStatus)
            MiniStatusChip(title: "Mic", value: voice.isRecording ? "Listening" : voice.status)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MiniStatusChip: View {
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
    }

    private var tint: Color {
        switch value {
        case "Online", "Ready", "On":
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

private struct EmptySelectionView: View {
    var body: some View {
        Text("Select a conversation")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Header: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}

private struct StatusRow: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        )
    }
}
