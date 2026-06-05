import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @StateObject private var audio = AudioRouteMonitor()
    @StateObject private var projectCatalog = ProjectCatalog()
    @StateObject private var projectStore = ProjectStore()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selection: SidebarSelection? = .newChat
    @State private var conversationToRename: Conversation?
    @State private var isDrainingQueuedMessages = false
    @State private var pendingProject: Project?
    @State private var showingProjectPicker = false
    @State private var activeSendTasks: [UUID: Task<Void, Never>] = [:]
    @State private var conversationSearch = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section("Home") {
                    Label("New Chat", systemImage: "plus.bubble")
                        .tag(SidebarSelection.newChat)
                }

                if !workspace.conversations.isEmpty {
                    if !pendingDecisionConversations.isEmpty {
                        Section("Questions") {
                            ForEach(pendingDecisionConversations) { conversation in
                                DecisionRow(conversation: conversation)
                                    .tag(SidebarSelection.conversation(conversation.id))
                            }
                        }
                    }

                    Section("Conversations") {
                        if filteredConversations.isEmpty {
                            Text("No matching chats")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(filteredConversations) { conversation in
                                ConversationRow(
                                    conversation: conversation,
                                    onRename: { conversationToRename = conversation },
                                    onDelete: { deleteConversation(conversation.id) }
                                )
                                    .tag(SidebarSelection.conversation(conversation.id))
                            }
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
            .searchable(text: $conversationSearch, placement: .sidebar, prompt: "Search chats")
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
                .task {
                    await startQueuedMessageLoop()
                }
                .task {
                    audio.start()
                }
                .task {
                    markSelectedConversationRead()
                }
                .onChange(of: selection) {
                    if selection == .newChat {
                        pendingProject = nil
                    }
                    markSelectedConversationRead()
                }
                .onChange(of: workspace.conversations) {
                    markSelectedConversationRead()
                }
                .onChange(of: voice.isRecording) { _, isRecording in
                    audio.refresh(isRecording: isRecording)
                }
        }
        .sheet(item: $conversationToRename) { conversation in
            RenameConversationSheet(conversation: conversation) { title in
                workspace.renameConversation(conversation.id, title: title)
            }
        }
        .popover(isPresented: $showingProjectPicker) {
            ProjectPickerPopover(
                client: client,
                catalog: projectCatalog,
                pinned: projectStore,
                onSelect: { project in
                    pendingProject = project
                },
                onClose: {
                    showingProjectPicker = false
                }
            )
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
                isRunning: false,
                lastError: nil,
                runState: nil,
                agentStatus: nil,
                queuedMessageCount: workspace.queuedMessageCount,
                approvals: [],
                projectName: activeProjectName,
                projectBranch: activeProjectBranch,
                projectPath: activeProjectPath,
                projectLocked: activeProjectIsLocked,
                onSend: { send($0, attachments: $1, references: $2, in: nil) },
                onStop: stopSelectedConversation,
                onPickProject: { showingProjectPicker = true },
                onRetry: nil,
                onCopyTranscript: nil,
                onCopyChatID: nil,
                onRename: nil,
                onDelete: nil,
                onQuestionAnswer: nil,
                onQuestionCancel: nil,
                voice: voice,
                audio: audio,
                reservesTitleControlSpace: isSidebarCollapsed
            )
        case .conversation(let id):
            if let conversation = workspace.conversation(id: id) {
                ChatView(
                    client: client,
                    title: conversation.title,
                    subtitle: conversation.updatedDetailText,
                    messages: conversation.messages,
                    isRunning: conversation.isRunning,
                    lastError: conversation.lastError,
                    runState: conversation.runState,
                    agentStatus: conversation.agentStatusSummary,
                    queuedMessageCount: conversation.queuedUserMessageCount,
                    approvals: conversation.approvals,
                    projectName: activeProjectName,
                    projectBranch: activeProjectBranch,
                    projectPath: activeProjectPath,
                    projectLocked: activeProjectIsLocked,
                    onSend: { send($0, attachments: $1, references: $2, in: conversation.id) },
                    onStop: { stop(conversation) },
                    onPickProject: { showingProjectPicker = true },
                    onRetry: { retry(conversation.id) },
                    onCopyTranscript: { copyToPasteboard(conversation.transcriptText) },
                    onCopyChatID: { copyToPasteboard(conversation.threadId) },
                    onRename: { conversationToRename = conversation },
                    onDelete: { deleteConversation(conversation.id) },
                    onQuestionAnswer: { approval, answer in answerQuestion(approval, answer: answer, in: conversation.id) },
                    onQuestionCancel: { approval in cancelQuestion(approval, in: conversation.id) },
                    voice: voice,
                    audio: audio,
                    reservesTitleControlSpace: isSidebarCollapsed
                )
            } else {
                EmptySelectionView()
            }
        case .roadmap:
            RoadmapView()
        case .settings:
            SettingsView(client: client, voice: voice, audio: audio, storeError: workspace.storeError)
        }
    }

    private var isSidebarCollapsed: Bool {
        columnVisibility == .detailOnly
    }

    private var pendingDecisionConversations: [Conversation] {
        filteredConversations.filter { !$0.approvals.isEmpty }
    }

    private var filteredConversations: [Conversation] {
        workspace.conversations.filter { $0.matchesSearch(conversationSearch) }
    }

    private var activeProjectName: String {
        selectedConversation?.displayProjectName ?? pendingProject?.name ?? "Home"
    }

    private var activeProjectBranch: String? {
        selectedConversation?.branch ?? pendingProject?.branch
    }

    private var activeProjectPath: String? {
        selectedConversation?.projectPath ?? pendingProject?.path
    }

    private var activeProjectIsLocked: Bool {
        selectedConversation != nil
    }

    private var selectedConversation: Conversation? {
        guard case .conversation(let id) = selection else { return nil }
        return workspace.conversation(id: id)
    }

    private func markSelectedConversationRead() {
        guard case .conversation(let id) = selection,
              let conversation = workspace.conversation(id: id)
        else { return }
        workspace.markConversationRead(conversation.id, at: conversation.updatedAt)
    }

    private func retry(_ conversationId: UUID) {
        guard let retry = workspace.prepareRetryLastFailedMessage(in: conversationId) else { return }

        sendPreparedMessage(
            retry.message,
            attachments: retry.attachments,
            references: retry.references,
            in: retry.conversation,
            messageID: nil
        )
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

    private func cancelQuestion(_ approval: ApprovalRequest, in conversationId: UUID) {
        Task {
            do {
                try await client.answerApproval(approval.id, approved: false)
                workspace.recordApprovalAnswerRejected(approval.id, in: conversationId)
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

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func send(_ text: String, attachments: [ChatAttachment], references: [ChatReference], in conversationId: UUID?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingText = trimmed.isEmpty ? defaultContextPrompt(attachments: attachments, references: references) : trimmed
        guard (!outgoingText.isEmpty || !references.isEmpty), attachments.allSatisfy(\.isReadyForSend) else { return }
        let requestAttachments = chatRequestAttachments(for: attachments)
        let requestReferences = chatRequestReferences(for: references)

        if client.isDisconnected {
            queue(outgoingText, attachments: attachments, references: references, in: conversationId)
            return
        }

        let conversation: Conversation
        if let conversationId, let existing = workspace.appendUserMessage(outgoingText, to: conversationId, attachments: attachments, references: references) {
            conversation = existing
        } else {
            conversation = workspace.createConversation(
                firstMessage: outgoingText,
                attachments: attachments,
                references: references,
                projectPath: pendingProject?.path,
                projectName: pendingProject?.name
            )
            selection = .conversation(conversation.id)
            pendingProject = nil
        }

        sendPreparedMessage(
            messageTextForAgent(outgoingText, attachments: attachments, references: references),
            attachments: requestAttachments,
            references: requestReferences,
            in: conversation,
            messageID: conversation.messages.last?.id
        )
    }

    private func sendPreparedMessage(_ text: String, attachments: [ChatRequestAttachment], references: [ChatRequestReference], in conversation: Conversation, messageID: UUID?) {
        let conversationID = conversation.id
        activeSendTasks[conversationID]?.cancel()
        let task = Task {
            defer {
                activeSendTasks[conversationID] = nil
            }
            do {
                workspace.beginAgentResponse(in: conversationID)
                let result = try await client.sendStreaming(
                    text,
                    threadId: conversation.threadId,
                    conversationId: conversationID,
                    attachments: attachments,
                    references: references,
                    projectPath: conversation.projectPath
                ) { event in
                    handleStreamEvent(event, conversationId: conversationID)
                }
                workspace.apply(result, to: conversationID)
                await syncSharedConversations()
            } catch {
                if isCancellation(error) {
                    return
                }
                if isOfflineError(error),
                   let messageID,
                   workspace.requeueMessageAfterOfflineFailure(conversationID: conversationID, messageID: messageID) {
                    return
                }
                workspace.applyFailure(error, to: conversationID)
            }
        }
        activeSendTasks[conversationID] = task
    }

    private func stopSelectedConversation() {
        guard case .conversation(let id) = selection,
              let conversation = workspace.conversation(id: id),
              conversation.isRunning
        else { return }
        stop(conversation)
    }

    private func stop(_ conversation: Conversation) {
        activeSendTasks[conversation.id]?.cancel()
        activeSendTasks[conversation.id] = nil
        workspace.cancelActiveResponse(in: conversation.id)
        Task {
            try? await client.cancel(threadId: conversation.threadId)
            await syncSharedConversations()
        }
    }

    private func queue(_ text: String, attachments: [ChatAttachment], references: [ChatReference], in conversationId: UUID?) {
        let conversation: Conversation
        if let conversationId, let existing = workspace.queueUserMessage(text, to: conversationId, attachments: attachments, references: references) {
            conversation = existing
        } else {
            conversation = workspace.queueConversation(
                firstMessage: text,
                attachments: attachments,
                references: references,
                projectPath: pendingProject?.path,
                projectName: pendingProject?.name
            )
            pendingProject = nil
            selection = .conversation(conversation.id)
        }
        selection = .conversation(conversation.id)
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
                    attachments: prepared.attachments,
                    references: prepared.references,
                    projectPath: prepared.conversation.projectPath
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

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let agentError = error as? AgentClientError, case .cancelled = agentError {
            return true
        }
        return false
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
                if conversation.queuedUserMessageCount > 0 {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                }
            }

            Text(rowDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(conversation.isRunning ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Copy Transcript") {
                copyToPasteboard(conversation.transcriptText)
            }
            Button("Copy Chat ID") {
                copyToPasteboard(conversation.threadId)
            }
            Divider()
            Button("Rename", action: onRename)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var rowDetail: String {
        if conversation.runState.isActive {
            if conversation.queuedUserMessageCount > 0 {
                return "\(conversation.projectBadgeText) - \(conversation.queuedUserMessageCount) queued"
            }
            return "\(conversation.projectBadgeText) - \(conversation.runState.label) - \(conversation.updatedTimestampText)"
        }
        return "\(conversation.projectBadgeText) - \(conversation.updatedDetailText)"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct DecisionRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(conversation.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(conversation.approvals.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(conversation.approvals.first?.summary.isEmpty == false ? conversation.approvals.first?.summary ?? "Needs answer" : "Needs answer")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ChatView: View {
    @ObservedObject var client: KishAgentClient
    let title: String
    let subtitle: String
    let messages: [ChatMessage]
    let isRunning: Bool
    let lastError: String?
    let runState: ConversationRunState?
    let agentStatus: AgentStatusSummary?
    let queuedMessageCount: Int
    let approvals: [ApprovalRequest]
    let projectName: String
    let projectBranch: String?
    let projectPath: String?
    let projectLocked: Bool
    let onSend: (String, [ChatAttachment], [ChatReference]) -> Void
    let onStop: () -> Void
    let onPickProject: () -> Void
    let onRetry: (() -> Void)?
    let onCopyTranscript: (() -> Void)?
    let onCopyChatID: (() -> Void)?
    let onRename: (() -> Void)?
    let onDelete: (() -> Void)?
    let onQuestionAnswer: ((ApprovalRequest, String) -> Void)?
    let onQuestionCancel: ((ApprovalRequest) -> Void)?
    @ObservedObject var voice: VoiceController
    @ObservedObject var audio: AudioRouteMonitor
    let reservesTitleControlSpace: Bool

    @State private var draft = ""
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var pendingReferences: [ChatReference] = []

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(
                title: title,
                subtitle: subtitle,
                projectBadge: projectLocked ? projectLabel : nil,
                runState: runState,
                onCopyTranscript: onCopyTranscript,
                onCopyChatID: onCopyChatID,
                onRename: onRename,
                onDelete: onDelete,
                reservesTitleControlSpace: reservesTitleControlSpace
            )

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if messages.isEmpty {
                            EmptyChatPrompt(
                                projectName: projectName,
                                projectBranch: projectBranch,
                                showsProjectPicker: !projectLocked,
                                onPickProject: onPickProject
                            )
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

            if let agentStatus {
                AgentStatusStrip(summary: agentStatus)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let lastError {
                ErrorRetryBar(message: lastError, onRetry: onRetry)
            }

            if queuedMessageCount > 0 {
                OfflineQueueBar(count: queuedMessageCount, isConnected: client.canSendQueuedMessages)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if client.isDisconnected {
                OfflineQueueBar(count: 0, isConnected: false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let pendingQuestion = approvals.first {
                QuestionComposer(
                    approval: pendingQuestion,
                    onAnswer: { answer in
                        onQuestionAnswer?(pendingQuestion, answer)
                    },
                    onCancel: {
                        onQuestionCancel?(pendingQuestion)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ChatComposer(
                    draft: $draft,
                    attachments: $pendingAttachments,
                    references: $pendingReferences,
                    client: client,
                    isSending: isRunning,
                    isDisabled: isRunning,
                    voice: voice,
                    audio: audio,
                    runState: runState,
                    projectPath: projectPath,
                    allowsReferences: projectLocked,
                    onSend: sendDraft,
                    onStop: onStop
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ConnectionStatusBar(client: client, voice: voice, audio: audio)
        }
        .background(KishOSTheme.chatBackground)
        .animation(.easeInOut(duration: 0.2), value: approvals.first?.id)
        .animation(.easeInOut(duration: 0.2), value: isRunning)
        .animation(.easeInOut(duration: 0.2), value: queuedMessageCount)
        .animation(.easeInOut(duration: 0.2), value: agentStatus?.detail)
    }

    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (hasDraft || hasSendableAttachment || hasReference),
              pendingAttachments.allSatisfy(\.isReadyForSend),
              !isRunning,
              approvals.isEmpty
        else {
            return
        }
        let attachments = pendingAttachments
        let references = pendingReferences
        draft = ""
        pendingAttachments = []
        pendingReferences = pendingReferences.filter(\.isLocked)
        onSend(trimmed, attachments, references)
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSendableAttachment: Bool {
        pendingAttachments.contains { $0.isReadyForSend }
    }

    private var hasReference: Bool {
        !pendingReferences.isEmpty
    }

    private var projectLabel: String {
        let cleanBranch = (projectBranch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanBranch.isEmpty ? projectName : "\(projectName) \(cleanBranch)"
    }

    private func previousUserText(before index: Int) -> String {
        guard index > 0 else { return "" }
        return messages[..<index].last(where: { $0.sender == .user })?.text ?? ""
    }
}

private struct ChatHeader: View {
    let title: String
    let subtitle: String
    let projectBadge: String?
    let runState: ConversationRunState?
    let onCopyTranscript: (() -> Void)?
    let onCopyChatID: (() -> Void)?
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
                    HStack(spacing: 6) {
                        if let projectBadge {
                            Label(projectBadge, systemImage: projectBadge == "Home" ? "house" : "folder")
                                .labelStyle(.titleAndIcon)
                        }
                        Text(subtitle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            if let runState, runState.isActive {
                RunStatePill(runState: runState)
            }

            Spacer()

            if onCopyTranscript != nil || onCopyChatID != nil || onRename != nil || onDelete != nil {
                Menu {
                    if let onCopyTranscript {
                        Button("Copy Transcript", action: onCopyTranscript)
                    }
                    if let onCopyChatID {
                        Button("Copy Chat ID", action: onCopyChatID)
                    }
                    if onCopyTranscript != nil || onCopyChatID != nil {
                        Divider()
                    }
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

private struct AgentStatusStrip: View {
    let summary: AgentStatusSummary

    var body: some View {
        HStack(spacing: 9) {
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
        .background(KishOSTheme.panelBackground)
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

private struct OfflineQueueBar: View {
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
        .background(KishOSTheme.panelBackground)
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
    let projectName: String
    let projectBranch: String?
    let showsProjectPicker: Bool
    let onPickProject: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Ask KishOS")
                .font(.title3.weight(.semibold))

            if showsProjectPicker {
                MacProjectChip(
                    name: projectName,
                    branch: projectBranch,
                    isLocked: false,
                    isDisabled: false,
                    onTap: onPickProject
                )
                .padding(.top, 2)
            }
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
                if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.attachments) { attachment in
                            ContextChip(attachment: attachment)
                        }
                    }
                }

                if !message.references.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.references) { reference in
                            ReferenceChip(reference: reference)
                        }
                    }
                }

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

                if let deliveryText {
                    Label(deliveryText, systemImage: deliveryIcon)
                        .font(.caption2)
                        .foregroundStyle(deliveryTint)
                        .labelStyle(.titleAndIcon)
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

    private var deliveryText: String? {
        guard message.sender == .user else { return nil }
        switch message.deliveryState {
        case .queued:
            return "Saved locally"
        case .sending:
            return nil
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
        switch message.deliveryState {
        case .queued, .sending:
            return .secondary
        case .failed:
            return .red
        case .sent:
            return .secondary
        }
    }
}

private struct AssistantActivityBlock: View {
    let events: [String]
    let messageText: String
    let previousUserText: String
    let isRunning: Bool
    @State private var isExpanded = false
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
                                Circle()
                                    .fill(Color.secondary.opacity(0.55))
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 7)

                                MarkdownText(text: displayEvent(event), isUser: false, font: .caption, color: .secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
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
    @Binding var attachments: [ChatAttachment]
    @Binding var references: [ChatReference]
    @ObservedObject var client: KishAgentClient
    let isSending: Bool
    let isDisabled: Bool
    @ObservedObject var voice: VoiceController
    @ObservedObject var audio: AudioRouteMonitor
    let runState: ConversationRunState?
    let projectPath: String?
    let allowsReferences: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var attachmentError: String?
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            ContextChip(
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

            if !references.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(references) { reference in
                            ReferenceChip(
                                reference: reference,
                                onRemove: {
                                    removeReference(reference)
                                }
                            )
                        }
                    }
                }
            }

            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let blockedAttachmentText {
                Text(blockedAttachmentText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Button(action: toggleDictation) {
                    Image(systemName: dictationIconName)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(voice.isRecording ? .red : .secondary)
                .help(dictationHelp)
                .disabled(isDisabled)

                Button(action: chooseFiles) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Attach files")
                .disabled(isDisabled)

                if allowsReferences {
                    Button(action: chooseReference) {
                        Image(systemName: "at")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reference file or folder")
                    .disabled(isDisabled)
                }

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

                Button(action: trailingAction) {
                    if hasUploadingAttachment && !isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isWorking ? "stop.fill" : "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isWorking ? .red : nil)
                .disabled(trailingButtonDisabled)
            }
        }
        .opacity(isDisabled ? 0.62 : 1)
        .padding(10)
        .background(isDropTarget ? Color.accentColor.opacity(0.08) : KishOSTheme.inputBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isDropTarget ? Color.accentColor.opacity(0.55) : KishOSTheme.hairline)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 18, y: 8)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: handleDrop)
    }

    private func toggleDictation() {
        Task {
            if let transcript = await voice.toggleRecording() {
                appendTranscript(transcript)
            }
        }
    }

    private var hasSendableContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !references.isEmpty || attachments.contains { $0.isReadyForSend }
    }

    private var hasUploadingAttachment: Bool {
        attachments.contains { $0.uploadState == .uploading }
    }

    private var hasBlockedAttachment: Bool {
        attachments.contains { $0.needsUpload && $0.uploadState != .uploading && $0.uploadState != .ready }
    }

    private var blockedAttachmentText: String? {
        attachments.first(where: { $0.needsUpload && $0.uploadState != .uploading && $0.uploadState != .ready })?.uploadError
            ?? (hasBlockedAttachment ? "Attachment needs upload." : nil)
    }

    private var isWorking: Bool {
        runState?.isActive == true
    }

    private var dictationIconName: String {
        if voice.isRecording {
            return "stop.circle.fill"
        }
        return audio.hasGlassesConnected ? "eyeglasses" : "mic"
    }

    private var dictationHelp: String {
        if voice.isRecording {
            return "Stop dictation"
        }
        return audio.hasGlassesConnected ? "Dictate with glasses" : "Dictate"
    }

    private var trailingButtonDisabled: Bool {
        if isWorking {
            return false
        }
        return isDisabled || isSending || hasUploadingAttachment || hasBlockedAttachment || !hasSendableContent
    }

    private func trailingAction() {
        if isWorking {
            onStop()
        } else {
            onSend()
        }
    }

    private func appendTranscript(_ transcript: String) {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = existing.isEmpty ? clean : "\(existing) \(clean)"
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.begin { response in
            guard response == .OK else { return }
            handleFileURLs(panel.urls)
        }
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let projectPath, !projectPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.urls.first else { return }
            handleReferenceURL(url)
        }
    }

    private func handleReferenceURL(_ url: URL) {
        attachmentError = nil
        do {
            let reference = try MacReferenceFactory.reference(from: url)
            guard !references.contains(where: { $0.path == reference.path }) else { return }
            references.append(reference)
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    private func removeReference(_ reference: ChatReference) {
        references.removeAll { $0.id == reference.id }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    DispatchQueue.main.async {
                        attachmentError = error.localizedDescription
                    }
                    return
                }

                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }

                guard let url else { return }
                DispatchQueue.main.async {
                    handleFileURLs([url])
                }
            }
        }

        return true
    }

    private func handleFileURLs(_ urls: [URL]) {
        attachmentError = nil
        for url in urls {
            do {
                var attachment = try MacAttachmentFactory.attachment(from: url)
                if attachment.needsUpload {
                    attachment.uploadState = .uploading
                }
                attachments.append(attachment)
                if attachment.needsUpload {
                    uploadAttachment(attachment.id)
                }
            } catch {
                attachmentError = error.localizedDescription
            }
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
}

private struct MacProjectChip: View {
    let name: String
    let branch: String?
    let isLocked: Bool
    let isDisabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: name == "Home" ? "house" : "folder")
                    .font(.caption.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(KishOSTheme.pillBackground, in: Capsule())
            .overlay(Capsule().stroke(KishOSTheme.hairline))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(isDisabled || isLocked)
        .opacity(isLocked ? 0.72 : 1)
        .help(isLocked ? "Project is fixed for this conversation" : "Choose project")
    }

    private var label: String {
        let cleanBranch = (branch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanBranch.isEmpty ? name : "\(name) \(cleanBranch)"
    }
}

private enum MacAttachmentFactory {
    static func attachment(from url: URL) throws -> ChatAttachment {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw MacAttachmentError.notAFile
        }

        let title = url.lastPathComponent.isEmpty ? "File" : url.lastPathComponent
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let id = UUID()
        let mimeType = mimeType(for: url)
        let localFilename = try AttachmentPayloadCache.shared.store(data: data, attachmentId: id, filename: title)
        let previewText = String(data: Data(data.prefix(200_000)), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ChatAttachment(
            id: id,
            kind: kind(for: mimeType),
            title: title,
            text: previewText?.isEmpty == false ? previewText : nil,
            mimeType: mimeType,
            byteCount: data.count,
            localFilename: localFilename,
            uploadState: .local
        )
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }

    private static func kind(for mimeType: String) -> ChatAttachment.Kind {
        mimeType.lowercased().hasPrefix("image/") ? .image : .file
    }
}

private enum MacReferenceFactory {
    static func reference(from url: URL) throws -> ChatReference {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        guard values.isDirectory == true || values.isRegularFile == true else {
            throw MacAttachmentError.notAFile
        }

        let title = url.lastPathComponent.isEmpty ? "Reference" : url.lastPathComponent
        return ChatReference(
            kind: values.isDirectory == true ? .folder : .file,
            title: title,
            path: url.path
        )
    }
}

private enum MacAttachmentError: LocalizedError {
    case notAFile

    var errorDescription: String? {
        switch self {
        case .notAFile:
            return "Select a file."
        }
    }
}

private struct ContextChip: View {
    let attachment: ChatAttachment
    var onRemove: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil

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
                .font(.caption)
            Text(attachment.title)
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
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry \(attachment.title)")
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.title)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(KishOSTheme.pillBackground, in: Capsule())
        .overlay(Capsule().stroke(strokeTint))
    }

    private func imagePreview(_ image: NSImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: previewWidth, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(strokeTint, lineWidth: attachment.uploadState == .failed ? 1.2 : 0.8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
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

    private var previewImage: NSImage? {
        guard let url = AttachmentPayloadCache.shared.cachedFileURL(for: attachment) else { return nil }
        return NSImage(contentsOf: url)
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
        attachment.uploadState == .failed ? .red.opacity(0.55) : KishOSTheme.hairline
    }
}

private struct ReferenceChip: View {
    let reference: ChatReference
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: reference.kind == .folder ? "folder" : "doc.text")
                .font(.caption)
            Text(reference.promptToken)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(reference.title)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(KishOSTheme.pillBackground, in: Capsule())
        .overlay(Capsule().stroke(KishOSTheme.hairline))
    }
}

private struct RoadmapView: View {
    private let milestones = KishOSMilestone.allCases
    private let capabilities = KishOSFactoryPlan.capabilities

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Header(title: "Roadmap", subtitle: "Done first. Next work at the bottom.")
                    .frame(maxWidth: .infinity, alignment: .leading)

                roadmapSection(
                    title: "Done",
                    capabilities: capabilities.filter { $0.state == .available },
                    isDone: true
                )

                roadmapSection(
                    title: "Not done",
                    capabilities: capabilities.filter { $0.state != .available },
                    isDone: false
                )
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func roadmapSection(title: String, capabilities: [KishOSCapability], isDone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(milestones) { milestone in
                let items = capabilities.filter { $0.milestone == milestone }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(milestone.rawValue) \(milestone.title)")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(items) { capability in
                            RoadmapChecklistRow(
                                capability: capability,
                                statusText: isDone ? nil : notDoneDetail(for: capability),
                                isDone: isDone
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notDoneDetail(for capability: KishOSCapability) -> String {
        switch capability.state {
        case .inProgress:
            return "In progress"
        case .planned:
            return "Planned"
        case .deferred:
            return "Deferred"
        case .off:
            return "Off"
        case .available:
            return ""
        }
    }
}

private struct RoadmapChecklistRow: View {
    let capability: KishOSCapability
    let statusText: String?
    let isDone: Bool

    var body: some View {
        DisclosureGroup {
            Text(capability.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
                .padding(.top, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(isDone ? .green : .secondary)

                Text(capability.title)
                    .font(.callout)

                Text(rowTags)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(.automatic)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private var rowTags: String {
        let tags = statusText.map { [$0] + capability.tags } ?? capability.tags
        return tags.joined(separator: " · ")
    }
}

private struct SettingsView: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var voice: VoiceController
    @ObservedObject var audio: AudioRouteMonitor
    let storeError: String?
    @State private var agentURLDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Header(title: "Settings", subtitle: client.status)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Connection")
                        .font(.headline)

                    HStack(spacing: 8) {
                        TextField("Agent URL", text: $agentURLDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(reconnect)
                        Button("Reconnect", action: reconnect)
                        Button("Reset") {
                            client.resetBaseURL()
                            agentURLDraft = client.agentURLString
                            Task {
                                await client.reconnect()
                            }
                        }
                    }
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

                LazyVGrid(columns: statusColumns, spacing: 8) {
                    StatusRow(title: "Mac mini", value: client.miniStatus, tint: client.miniStatus == "Online" ? .green : .secondary)
                    StatusRow(title: "HTTP", value: client.httpStatus, tint: client.httpStatus == "Online" ? .green : .secondary)
                    StatusRow(title: "Agent", value: client.agentStatus, tint: client.agentStatus == "Online" ? .green : .secondary)
                    StatusRow(title: "History", value: storeError == nil ? "On" : "Error", tint: storeError == nil ? .green : .red)
                    StatusRow(title: "Tools", value: client.toolInventoryStatus, tint: client.toolInventoryStatus == "Ready" ? .green : .secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Audio")
                                .font(.headline)
                            Text(audio.glassesSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(audio.prefersHandsFreeRoute ? "Use System" : "Prefer External") {
                            audio.setPrefersHandsFreeRoute(!audio.prefersHandsFreeRoute)
                        }
                        Button("Refresh") {
                            audio.refresh(isRecording: voice.isRecording)
                        }
                    }

                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(glassesConnectionTint)
                            .frame(width: 30, height: 30)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(glassesConnectionTitle)
                                .font(.callout.weight(.semibold))
                            Text(glassesConnectionDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 8)

                        Text(glassesConnectionPillTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(glassesConnectionTint)
                    }

                    LazyVGrid(columns: statusColumns, spacing: 8) {
                        StatusRow(title: "Input", value: audio.inputName, tint: audio.statusLabel == "Unavailable" ? .red : .green)
                        StatusRow(title: "Output", value: audio.outputName, tint: audio.statusLabel == "Unavailable" ? .red : .green)
                        StatusRow(title: "Route", value: audio.statusLabel, tint: audioTint)
                        StatusRow(title: "Mode", value: audio.routeModeLabel, tint: audio.prefersHandsFreeRoute ? .green : .secondary)
                        StatusRow(title: "Health", value: audio.routeHealthLabel, tint: audioHealthTint)
                    }

                    if !audio.activationDetail.isEmpty {
                        Text(audio.activationDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Routes")
                            .font(.headline)
                        if audio.availableRoutes.isEmpty {
                            Text("No external audio routes exposed by the system.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(audio.availableRoutes) { route in
                                AudioRouteCandidateRow(route: route)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Glasses")
                            .font(.headline)
                        ForEach(audio.capabilityLines) { line in
                            AudioCapabilityRow(line: line)
                        }
                    }
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

                ToolInventorySection(inventory: client.toolInventory)

                if let storeError {
                    Text(storeError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            agentURLDraft = client.agentURLString
            audio.refresh(isRecording: voice.isRecording)
        }
    }

    private var statusColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .top)]
    }

    private var audioTint: Color {
        switch audio.statusLabel {
        case "Glasses", "Bluetooth", "System", "Built-in", "Headset":
            return .green
        case "Listening":
            return .orange
        case "Unavailable":
            return .red
        default:
            return .secondary
        }
    }

    private var audioHealthTint: Color {
        switch audio.routeHealthLabel {
        case "Active", "Ready":
            return .green
        case "Switching", "Waiting":
            return .orange
        case "Unavailable":
            return .red
        default:
            return .secondary
        }
    }

    private var glassesConnectionTitle: String {
        audio.hasGlassesConnected ? "Glasses connected" : "Glasses not connected"
    }

    private var glassesConnectionDetail: String {
        if audio.activeRouteKind == .glasses {
            return "Active on \(audio.routeDetail)."
        }
        if let routeName = audio.availableRoutes.first(where: { $0.kind == .glasses })?.name {
            return "\(routeName) is available for hands-free audio."
        }
        return "Connect Ray-Ban Meta glasses in Bluetooth."
    }

    private var glassesConnectionPillTitle: String {
        audio.hasGlassesConnected ? "Connected" : "Not connected"
    }

    private var glassesConnectionTint: Color {
        audio.hasGlassesConnected ? .green : .secondary
    }

    private func reconnect() {
        guard client.updateBaseURL(agentURLDraft) else { return }
        agentURLDraft = client.agentURLString
        Task {
            await client.reconnect()
        }
    }
}

private struct AudioRouteCandidateRow: View {
    let route: AudioRouteCandidate

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(route.isActive ? .green : (route.isPreferredCandidate ? .orange : .secondary))
                .frame(width: 7, height: 7)
            Text(route.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(routeLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
    }

    private var routeLabel: String {
        var parts = [route.kind.rawValue]
        if route.isInput {
            parts.append("Input")
        }
        if route.isOutput {
            parts.append("Output")
        }
        if route.isActive {
            parts.append("Active")
        }
        return parts.joined(separator: " · ")
    }
}

private struct AudioCapabilityRow: View {
    let line: AudioCapabilityLine

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(line.isReady ? .green : .secondary)
                .frame(width: 7, height: 7)
            Text(line.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(line.state)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
        Text(line.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 15)
            .lineLimit(2)
    }
}

private struct ToolInventorySection: View {
    let inventory: ToolInventory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tools")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 10) {
                ToolGroup(title: "Engines", items: inventory.engines.map { item in
                    ToolLine(title: item.name, detail: item.detail ?? item.status, status: item.status)
                })

                ToolGroup(title: "Commands", items: inventory.commands.map { item in
                    ToolLine(title: item.name, detail: item.status, status: item.status)
                })

                ToolGroup(title: "Recent", items: inventory.recentTools.prefix(6).map { item in
                    ToolLine(title: item.name, detail: "\(item.count)", status: "Available")
                })
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        )
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)]
    }
}

private struct ToolGroup: View {
    let title: String
    let items: [ToolLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
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
    @ObservedObject var audio: AudioRouteMonitor

    var body: some View {
        HStack(spacing: 12) {
            MiniStatusChip(title: "Mini", value: client.miniStatus)
            MiniStatusChip(title: "Agent", value: client.agentStatus)
            MiniStatusChip(title: "Chat", value: client.chatStatus)
            MiniStatusChip(title: "Audio", value: voice.isRecording ? "Listening" : audio.statusLabel)
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
        case "Online", "Ready", "On", "System", "Built-in", "Bluetooth", "Glasses", "Headset":
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

private struct RunStatePill: View {
    let runState: ConversationRunState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(runState.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(KishOSTheme.pillBackground, in: Capsule())
    }

    private var tint: Color {
        switch runState {
        case .queued, .sending, .runningTools, .waitingForQuestion:
            return .orange
        case .failed:
            return .red
        case .done:
            return .green
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
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        )
    }
}
