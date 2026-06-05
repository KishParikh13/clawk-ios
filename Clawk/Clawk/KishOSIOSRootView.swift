import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private let mediaCaptureLog = Logger(subsystem: "com.kishparikh.clawk", category: "media-capture")

private func mediaCaptureDebugLog(_ message: String) {
    mediaCaptureLog.info("\(message, privacy: .public)")
    print("[MediaCapture] \(message)")
}

enum IOSTheme {
    static let background = Color(uiColor: .systemBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let elevatedBackground = Color(uiColor: .tertiarySystemBackground)
    static let hairline = Color.secondary.opacity(0.18)
}

private enum IOSChatSelection: Equatable {
    case newChat
    case conversation(UUID)
    case autonomy
    case settings
}

struct KishOSIOSRootView: View {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var client = KishAgentClient()
    @StateObject private var workspace = KishOSWorkspace()
    @StateObject private var voice = VoiceController()
    @StateObject private var audio = AudioRouteMonitor()
    @StateObject private var glassesCamera = GlassesCameraCaptureController()
    @StateObject private var wake = WakePhraseController()
    @StateObject private var projectCatalog = ProjectCatalog()
    @StateObject private var projectStore = ProjectStore()

    @State private var selection: IOSChatSelection = .newChat
    @State private var showingConversations = false
    @State private var isDrainingQueuedMessages = false
    @State private var activeCallController: LiveCallController?
    @State private var callStartTask: Task<Void, Never>?
    @State private var activeSendTasks: [UUID: Task<Void, Never>] = [:]
    @State private var pendingCallSnapshotReview: CallSnapshotReviewItem?
    @State private var pendingCallSnapshotContinuation: CheckedContinuation<Bool, Never>?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                NavigationStack {
                    Group {
                        if selection == .settings {
                            IOSSettingsPage(
                                client: client,
                                audio: audio,
                                glassesCamera: glassesCamera,
                                wake: wake,
                                agentURL: client.agentURLString,
                                onReconnect: reconnect
                            )
                            .navigationTitle("Control Panel")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button(action: openSidebar) {
                                        Image(systemName: "sidebar.left")
                                    }
                                    .accessibilityLabel("Conversations")
                                }
                            }
                        } else if selection == .autonomy {
                            IOSAutonomyView(
                                client: client,
                                onOpenConversation: openAutonomyConversation
                            )
                            .navigationTitle("Autonomy")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button(action: openSidebar) {
                                        Image(systemName: "sidebar.left")
                                    }
                                    .accessibilityLabel("Conversations")
                                }
                            }
                        } else {
                    ChatScreen(
                        client: client,
                        projectCatalog: projectCatalog,
                        projectStore: projectStore,
                        conversation: selectedConversation,
                        isSending: currentIsRunning,
                                runState: selectedConversation?.runState,
                                agentStatus: selectedConversation?.agentStatusSummary,
                                queuedMessageCount: selectedConversation?.queuedUserMessageCount ?? workspace.queuedMessageCount,
                                approvals: selectedConversation?.approvals ?? [],
                        voice: voice,
                        audio: audio,
                        glassesCamera: glassesCamera,
                        callController: activeCallController,
                                onSend: send,
                                onStop: stopSelectedConversation,
                                onStartCall: startLiveCall,
                                onEndCall: endLiveCall,
                                onRetry: retrySelectedConversation,
                                onQuestionAnswer: answerQuestion,
                                onQuestionCancel: cancelQuestion
                            )
                            .navigationTitle(selectedConversation?.title ?? "KishOS")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button(action: openSidebar) {
                                        Image(systemName: "sidebar.left")
                                    }
                                    .accessibilityLabel("Conversations")
                                }

                                ToolbarItem(placement: .principal) {
                                    IOSChatHeaderTitle(conversation: selectedConversation)
                                }

                                ToolbarItem(placement: .topBarTrailing) {
                                    Button(action: startNewChat) {
                                        Image(systemName: "square.and.pencil")
                                    }
                                    .accessibilityLabel("New chat")
                                }
                            }
                        }
                    }
                    .toolbar(showingConversations ? .hidden : .visible, for: .navigationBar)
                    .toolbar(activeCallController == nil ? .visible : .hidden, for: .navigationBar)
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
                        glassesCamera.start()
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
                        refreshStatusSurfaces()
                    }
                    .onChange(of: selectedConversationID) {
                        markSelectedConversationRead()
                        refreshStatusSurfaces()
                    }
                    .onChange(of: scenePhase) {
                        markSelectedConversationRead()
                        refreshStatusSurfaces()
                    }
                    .onChange(of: voice.isRecording) { _, isRecording in
                        audio.refresh(isRecording: isRecording)
                        refreshWakeSuppression()
                    }
                    .onChange(of: currentIsRunning) {
                        refreshWakeSuppression()
                        requestNotificationsForActiveWorkIfNeeded()
                    }
                    .onChange(of: activeCallController?.activeConversationID) {
                        refreshWakeSuppression()
                    }
                    .onChange(of: wake.detectionCount) { oldValue, newValue in
                        guard newValue > oldValue else { return }
                        handleWakeDetected()
                    }
                    .sheet(item: $pendingCallSnapshotReview) { item in
                        IOSSnapshotReviewView(
                            item: item.snapshot,
                            onAttach: {
                                completeCallSnapshotReview(accepted: true)
                            },
                            onRetake: {
                                completeCallSnapshotReview(accepted: false, removing: item.snapshot.attachment)
                            },
                            onCancel: {
                                completeCallSnapshotReview(accepted: false, removing: item.snapshot.attachment)
                            }
                        )
                        .presentationDetents([.large])
                        .interactiveDismissDisabled()
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
                        isAutonomySelected: selection == .autonomy,
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
                        onOpenSettings: {
                            openSettings()
                            closeConversations()
                        },
                        onOpenAutonomy: {
                            openAutonomy()
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
        selectedConversation?.isRunning ?? false
    }

    private func startNewChat() {
        selection = .newChat
    }

    private func openSettings() {
        selection = .settings
    }

    private func openAutonomy() {
        selection = .autonomy
    }

    private func startLiveCall() {
        guard activeCallController == nil else { return }
        wake.updateSuppression(true)
        let controller = LiveCallController(
            client: client,
            workspace: workspace,
            voice: voice,
            initialConversationID: selectedConversationID,
            initialProject: nil,
            onConversationStarted: { id in
                selection = .conversation(id)
            },
            captureMediaHandler: captureMediaForCall
        )
        activeCallController = controller
        callStartTask = Task {
            audio.start()
            voice.managesAudioSession = false
            await audio.beginCallSession()
            guard !Task.isCancelled, activeCallController === controller else {
                audio.endCallSession()
                voice.managesAudioSession = true
                return
            }
            await controller.start()
        }
    }

    private func endLiveCall() {
        callStartTask?.cancel()
        callStartTask = nil
        activeCallController?.endCall()
        activeCallController = nil
        refreshWakeSuppression()
        refreshLiveActivitySummary()
        // Keep the call's audio session alive briefly so the call-end sound can
        // play out, then release it — unless a new call has already claimed it.
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard activeCallController == nil else { return }
            audio.endCallSession()
            voice.managesAudioSession = true
        }
    }

    private func handleWakeDetected() {
        guard !currentIsRunning else { return }
        if showingConversations {
            closeConversations()
        }
        startLiveCall()
    }

    private func refreshWakeSuppression() {
        wake.updateSuppression(voice.isRecording || currentIsRunning || activeCallController != nil)
    }

    private func requestNotificationsForActiveWorkIfNeeded() {
        guard currentIsRunning, scenePhase == .active else { return }
        Task {
            await KishOSStatusNotificationController.shared.requestAuthorizationIfNeeded()
        }
    }

    private func refreshLiveActivitySummary() {
        KishOSLiveActivityController.shared.updateSummary(
            conversations: workspace.conversations,
            selectedConversationID: selectedConversationID
        )
    }

    private func refreshStatusSurfaces() {
        refreshLiveActivitySummary()
        KishOSStatusNotificationController.shared.update(
            conversations: workspace.conversations,
            isSceneActive: scenePhase == .active
        )
    }

    private func markSelectedConversationRead() {
        guard scenePhase == .active else { return }
        guard let selectedConversation else { return }
        workspace.markConversationRead(selectedConversation.id, at: selectedConversation.updatedAt)
    }

    private func closeConversations() {
        withAnimation(.easeInOut(duration: 0.22)) {
            showingConversations = false
        }
    }

    private func openSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            showingConversations = true
        }
    }

    private func reconnect() {
        Task {
            await client.reconnect()
        }
    }

    private func sidebarWidth(for containerWidth: CGFloat) -> CGFloat {
        min(356, max(304, containerWidth * 0.84))
    }

    private func captureMediaForCall(intent: CaptureIntent, conversationID: UUID?, threadId: String?) async throws -> [ChatAttachment] {
        guard intent.mediaKind == .photo else {
            throw CapturedMediaAttachmentError.unsupportedMediaKind
        }

        let media = try await capturePhotoMedia(for: intent)
        var attachment = try ChatAttachment.capturedMedia(media)
        let accepted = await reviewCallSnapshot(attachment: attachment, intent: intent, source: media.source)
        guard accepted else {
            AttachmentPayloadCache.shared.removePayload(for: attachment)
            throw CancellationError()
        }

        attachment = try await uploadCapturedAttachment(attachment, conversationId: conversationID, threadId: threadId)
        return [attachment]
    }

    private func capturePhotoMedia(for intent: CaptureIntent) async throws -> CapturedMedia {
        mediaCaptureDebugLog("call capturePhotoMedia intentSource=\(intent.source.rawValue) mediaKind=\(intent.mediaKind.rawValue) audioHasGlasses=\(audio.hasGlassesConnected) datStatus=\(glassesCamera.status.rawValue) datCanAttempt=\(glassesCamera.canAttemptCapture) datPermission=\(glassesCamera.cameraPermission)")
        switch intent.source {
        case .phoneCamera:
            mediaCaptureDebugLog("call capture source=phone explicit")
            return try await ProgrammaticPhoneCameraCapture.shared.capturePhoto()
        case .glassesCamera:
            mediaCaptureDebugLog("call capture source=glasses explicit")
            return try await glassesCamera.capturePhoto()
        case .automatic:
            if audio.hasGlassesConnected || glassesCamera.canAttemptCapture {
                mediaCaptureDebugLog("call capture source=glasses automatic")
                return try await glassesCamera.capturePhoto()
            }
            mediaCaptureDebugLog("call capture source=phone automatic no-glasses-signal")
            return try await ProgrammaticPhoneCameraCapture.shared.capturePhoto()
        }
    }

    private func reviewCallSnapshot(attachment: ChatAttachment, intent: CaptureIntent, source: MediaCaptureSource) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingCallSnapshotContinuation = continuation
            pendingCallSnapshotReview = CallSnapshotReviewItem(
                snapshot: SnapshotReviewItem(
                    attachment: attachment,
                    sourceType: nil,
                    captureSource: source
                ),
                intent: intent
            )
        }
    }

    private func completeCallSnapshotReview(accepted: Bool, removing attachment: ChatAttachment? = nil) {
        if let attachment {
            AttachmentPayloadCache.shared.removePayload(for: attachment)
        }
        pendingCallSnapshotReview = nil
        pendingCallSnapshotContinuation?.resume(returning: accepted)
        pendingCallSnapshotContinuation = nil
    }

    private func uploadCapturedAttachment(_ attachment: ChatAttachment, conversationId: UUID?, threadId: String?) async throws -> ChatAttachment {
        var current = attachment
        let payload = try AttachmentPayloadCache.shared.payload(for: current)
        let uploaded = try await client.uploadAttachment(payload, conversationId: conversationId, threadId: threadId)
        current.title = uploaded.filename
        current.mimeType = uploaded.mimeType ?? current.mimeType
        current.byteCount = uploaded.byteCount ?? current.byteCount
        current.uploadId = uploaded.id
        current.uploadState = .ready
        current.uploadError = nil
        if uploaded.kind == ChatAttachment.Kind.image.rawValue {
            current.kind = .image
        }
        return current
    }

    private func send(_ text: String, attachments: [ChatAttachment], references: [ChatReference]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingText = trimmed.isEmpty ? defaultContextPrompt(attachments: attachments, references: references) : trimmed
        guard (!outgoingText.isEmpty || !references.isEmpty), attachments.allSatisfy(\.isReadyForSend) else { return }
        let requestAttachments = chatRequestAttachments(for: attachments)
        let requestReferences = chatRequestReferences(for: references)

        if client.isDisconnected {
            queue(outgoingText, attachments: attachments, references: references)
            return
        }

        let conversation: Conversation
        if let selectedConversationID,
           let existing = workspace.appendUserMessage(outgoingText, to: selectedConversationID, attachments: attachments, references: references) {
            conversation = existing
        } else {
            conversation = workspace.createConversation(
                firstMessage: outgoingText,
                attachments: attachments,
                references: references,
                projectPath: nil,
                projectName: nil
            )
            selection = .conversation(conversation.id)
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
        guard let conversation = selectedConversation, conversation.isRunning else { return }
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

    private func queue(_ text: String, attachments: [ChatAttachment], references: [ChatReference]) {
        let conversation: Conversation
        if let selectedConversationID,
           let existing = workspace.queueUserMessage(text, to: selectedConversationID, attachments: attachments, references: references) {
            conversation = existing
        } else {
            conversation = workspace.queueConversation(
                firstMessage: text,
                attachments: attachments,
                references: references,
                projectPath: nil,
                projectName: nil
            )
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
                    attachments: retry.attachments,
                    references: retry.references,
                    projectPath: retry.conversation.projectPath
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

    private func openAutonomyConversation(conversationId: String?, threadId: String?) async -> Bool {
        await syncSharedConversations()

        if let conversationId,
           let uuid = UUID(uuidString: conversationId),
           workspace.conversation(id: uuid) != nil {
            selection = .conversation(uuid)
            return true
        }

        if let threadId,
           let conversation = workspace.conversation(threadId: threadId) {
            selection = .conversation(conversation.id)
            return true
        }

        return false
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

private struct ChatScreen: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var projectCatalog: ProjectCatalog
    @ObservedObject var projectStore: ProjectStore
    let conversation: Conversation?
    let isSending: Bool
    let runState: ConversationRunState?
    let agentStatus: AgentStatusSummary?
    let queuedMessageCount: Int
    let approvals: [ApprovalRequest]
    @ObservedObject var voice: VoiceController
    @ObservedObject var audio: AudioRouteMonitor
    @ObservedObject var glassesCamera: GlassesCameraCaptureController
    let callController: LiveCallController?
    let onSend: (String, [ChatAttachment], [ChatReference]) -> Void
    let onStop: () -> Void
    let onStartCall: () -> Void
    let onEndCall: () -> Void
    let onRetry: (() -> Void)?
    let onQuestionAnswer: (ApprovalRequest, String) -> Void
    let onQuestionCancel: (ApprovalRequest) -> Void

    @State private var draft = ""
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var pendingReferences: [ChatReference] = []
    @State private var inlineCaptureStatus: IOSCaptureInlineStatus?
    @Namespace private var composerNamespace

    private var messages: [ChatMessage] {
        conversation?.messages ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if let callController {
                IOSInlineCallHeader(
                    controller: callController,
                    audio: audio,
                    miniStatus: client.miniStatus,
                    chatStatus: client.chatStatus
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))

                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if messages.isEmpty {
                            if let callController, callController.activeUserPartial.isEmpty {
                                IOSLiveVoiceHero(
                                    state: callController.state,
                                    routeState: audio.routeState,
                                    routeLabel: audio.callRouteLabel,
                                    routeKind: audio.activeRouteKind
                                )
                            } else {
                                EmptyIOSChat()
                            }
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

                        if let callController, !callController.activeUserPartial.isEmpty {
                            IOSCallPartialTurn(text: callController.activeUserPartial)
                                .id("active-user")
                        }

                        if let inlineCaptureStatus {
                            IOSCaptureStatusTurn(status: inlineCaptureStatus)
                                .id(inlineCaptureStatus.id)
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
                .onChange(of: callController?.activeUserPartial) {
                    scrollToBottom(proxy)
                }
                .onChange(of: inlineCaptureStatus?.id) {
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
                if let callController {
                    IOSCallModeComposer(
                        state: callController.state,
                        transcript: callController.activeUserPartial,
                        levels: voice.waveformLevels,
                        isMuted: callController.isMuted,
                        isOutputEnabled: callController.isOutputEnabled,
                        canSubmitSpeech: !callController.activeUserPartial.isEmpty,
                        namespace: composerNamespace,
                        onMute: callController.toggleMute,
                        onOutput: callController.toggleOutput,
                        onSubmitSpeech: callController.submitCurrentUtterance,
                        onEnd: onEndCall
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                    ))
                } else {
                    IOSComposer(
                        draft: $draft,
                        attachments: $pendingAttachments,
                        references: $pendingReferences,
                        client: client,
                        projectCatalog: projectCatalog,
                        projectStore: projectStore,
                        isSending: isSending,
                        isDisabled: isSending,
                        runState: runState,
                        voice: voice,
                        audio: audio,
                        glassesCamera: glassesCamera,
                        namespace: composerNamespace,
                        onCaptureStatusChange: { status in
                            inlineCaptureStatus = status
                        },
                        onSend: sendDraft,
                        onStop: onStop,
                        onStartCall: onStartCall
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

        }
        .background(IOSTheme.background)
        .animation(.easeInOut(duration: 0.2), value: approvals.first?.id)
        .animation(.easeInOut(duration: 0.2), value: isSending)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: callController != nil)
        .animation(.easeInOut(duration: 0.2), value: queuedMessageCount)
        .animation(.easeInOut(duration: 0.2), value: agentStatus?.detail)
        .onChange(of: voice.transcript) { _, transcript in
            callController?.handleTranscriptChange(transcript)
        }
    }

    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (hasDraft || hasSendableAttachment || hasReference),
              pendingAttachments.allSatisfy(\.isReadyForSend),
              !isSending,
              approvals.isEmpty
        else {
            return
        }
        let attachments = pendingAttachments
        let references = pendingReferences
        draft = ""
        pendingAttachments = []
        pendingReferences = pendingReferences.filter(\.isLocked)
        if inlineCaptureStatus?.state == .succeeded {
            inlineCaptureStatus = nil
        }
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if callController?.activeUserPartial.isEmpty == false {
                proxy.scrollTo("active-user", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
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
                HStack(spacing: 4) {
                    Text(conversation.projectBadgeText)
                    Text("•")
                    Text(conversation.updatedDetailText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: 220)
    }
}

private struct IOSInlineCallHeader: View {
    @ObservedObject var controller: LiveCallController
    @ObservedObject var audio: AudioRouteMonitor
    let miniStatus: String
    let chatStatus: String

    var body: some View {
        HStack(spacing: 9) {
            IOSInlineCallStatusDot(value: controller.state.label)

            VStack(alignment: .leading, spacing: 0) {
                Text("Live voice")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(controller.state.label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Text(Self.formatElapsed(controller.elapsedSeconds))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            IOSRouteChip(
                state: audio.routeState,
                label: audio.callRouteLabel,
                kind: audio.activeRouteKind
            )

            ForEach(connectionLabels, id: \.self) { label in
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(IOSTheme.background)
    }

    private static func formatElapsed(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remaining = seconds % 60
        return String(format: "%d:%02d", minutes, remaining)
    }

    private var connectionLabels: [String] {
        var labels: [String] = []
        if !Self.isHealthyMiniStatus(miniStatus) {
            labels.append("Mini \(miniStatus)")
        }
        if !Self.isHealthyChatStatus(chatStatus) {
            labels.append("Chat \(chatStatus)")
        }
        return labels
    }

    private static func isHealthyMiniStatus(_ status: String) -> Bool {
        status == "Online" || status == "Checking"
    }

    private static func isHealthyChatStatus(_ status: String) -> Bool {
        status == "Ready" || status == "Idle" || status == "Checking" || status == "Sending"
    }
}

private struct IOSInlineCallStatusDot: View {
    let value: String

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 10, height: 10)
    }

    private var tint: Color {
        switch value {
        case "Listening", "Speaking":
            return .green
        case "Working", "Sending", "Connecting", "Question":
            return .orange
        case "Failed":
            return .red
        default:
            return .secondary
        }
    }
}

/// View-layer presentation for the truthful `RouteState`. Single source for the
/// color and glyph so the header chip and the idle hero never disagree.
private enum IOSRoutePresentation {
    static func tint(for state: RouteState) -> Color {
        switch state {
        case .externalActive: return .green
        case .switching: return .orange
        case .lost: return .orange
        case .blocked: return .red
        case .externalAvailable: return .secondary
        case .system: return .secondary
        }
    }

    static func glyph(for state: RouteState, kind: AudioRouteKind) -> String {
        switch state {
        case .externalActive:
            switch kind {
            case .glasses: return "eyeglasses"
            case .headset: return "headphones"
            default: return "dot.radiowaves.left.and.right"
            }
        case .switching: return "dot.radiowaves.left.and.right"
        case .lost: return "exclamationmark.triangle.fill"
        case .blocked: return "exclamationmark.octagon.fill"
        case .externalAvailable: return "dot.radiowaves.left.and.right"
        case .system: return "iphone"
        }
    }
}

/// Compact truthful route chip for the in-call header. Color and glyph come from
/// `routeState`; the text is `callRouteLabel`. This is the single place route truth
/// is shown in the header (call state stays separate, on the left).
private struct IOSRouteChip: View {
    let state: RouteState
    let label: String
    let kind: AudioRouteKind

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: IOSRoutePresentation.glyph(for: state, kind: kind))
                .font(.system(size: 11, weight: .semibold))
                .opacity(state == .switching && pulse ? 0.4 : 1)

            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
        .onAppear { startPulseIfNeeded() }
        .onChange(of: state) { _, _ in startPulseIfNeeded() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Route: \(label)")
    }

    private var tint: Color {
        IOSRoutePresentation.tint(for: state)
    }

    private func startPulseIfNeeded() {
        guard state == .switching else {
            pulse = false
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

/// Calm hands-free idle state shown when a call is active but the chat is still
/// empty. Replaces the blank screen with a centered live-voice surface: a breathing
/// mic glyph, a short prompt, and the truthful route. Disappears once messages land.
private struct IOSLiveVoiceHero: View {
    let state: LiveCallController.CallState
    let routeState: RouteState
    let routeLabel: String
    let routeKind: AudioRouteKind

    @State private var breathe = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 132, height: 132)
                    .scaleEffect(breathe ? 1.06 : 0.94)

                Circle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 92, height: 92)

                Image(systemName: glyph)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
            .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathe)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(subhead)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            IOSRouteChip(state: routeState, label: routeLabel, kind: routeKind)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
        .padding(.horizontal, 24)
        .onAppear { breathe = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(subhead) Route: \(routeLabel)")
    }

    private var glyph: String {
        switch state {
        case .agentSpeaking: return "waveform"
        case .agentThinking, .sendingTurn: return "ellipsis"
        case .failed: return "exclamationmark.triangle"
        default: return "mic.fill"
        }
    }

    private var headline: String {
        switch state {
        case .connecting: return "Connecting"
        case .agentThinking, .sendingTurn: return "Working on it"
        case .agentSpeaking: return "Speaking"
        case .needsAnswer: return "Waiting on you"
        case .failed: return "Call ended"
        default: return "Live voice on"
        }
    }

    private var subhead: String {
        switch state {
        case .connecting: return "Setting up the call."
        case .agentThinking, .sendingTurn: return "Hold on, the reply is coming."
        case .agentSpeaking: return "Reading the reply aloud."
        case .needsAnswer: return "Answer to keep going."
        case .failed: return "Tap end to close out."
        default: return "Listening, just talk. Hands-free."
        }
    }
}

private struct IOSCallPartialTurn: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 5) {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(text)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct IOSCallModeComposer: View {
    let state: LiveCallController.CallState
    let transcript: String
    let levels: [CGFloat]
    let isMuted: Bool
    let isOutputEnabled: Bool
    let canSubmitSpeech: Bool
    let namespace: Namespace.ID
    let onMute: () -> Void
    let onOutput: () -> Void
    let onSubmitSpeech: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            IOSComposerTranscriptText(text: surfaceText)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

            HStack(alignment: .center, spacing: 8) {
                Button(action: onMute) {
                    Circle()
                        .fill(isMuted ? Color(uiColor: .systemOrange).opacity(0.18) : IOSTheme.elevatedBackground)
                        .overlay {
                            Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(isMuted ? Color(uiColor: .systemOrange) : Color(uiColor: .label))
                        }
                        .overlay(Circle().stroke(IOSTheme.hairline))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isMuted ? "Unmute" : "Mute")
                .matchedGeometryEffect(id: "composerLeadingButton", in: namespace)

                IOSWaveformBars(levels: levels)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .padding(.leading, 4)
                    .padding(.trailing, 12)

                Button(action: auxiliaryAction) {
                    Image(systemName: auxiliaryIconName)
                        .font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(auxiliaryForeground)
                .frame(width: 40, height: 40)
                .background(auxiliaryBackground, in: Circle())
                .overlay(Circle().stroke(auxiliaryStroke))
                .accessibilityLabel(auxiliaryAccessibilityLabel)
                .matchedGeometryEffect(id: "composerAuxiliaryButton", in: namespace)

                Button(action: onEnd) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(uiColor: .systemRed), in: Circle())
                .accessibilityLabel("End call")
                .matchedGeometryEffect(id: "composerTrailingButton", in: namespace)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 5)
        }
        .background(IOSTheme.background, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).stroke(IOSTheme.hairline))
        .matchedGeometryEffect(id: "composerSurface", in: namespace)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    private var surfaceText: String {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            return clean
        }
        if isMuted {
            return "Muted"
        }
        switch state {
        case .connecting:
            return "Connecting"
        case .agentThinking, .sendingTurn:
            return "Working"
        case .capturingMedia:
            return "Capturing"
        case .agentSpeaking:
            return "Speaking"
        case .needsAnswer:
            return "Question"
        case .failed:
            return "Call failed"
        case .ended:
            return "Call ended"
        case .listening, .userSpeaking:
            return ""
        }
    }

    private var auxiliaryIconName: String {
        if canSubmitSpeech {
            return "arrow.up"
        }
        return isOutputEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"
    }

    private var auxiliaryForeground: Color {
        canSubmitSpeech ? .white : Color(uiColor: .label)
    }

    private var auxiliaryBackground: Color {
        if canSubmitSpeech {
            return Color(uiColor: .label)
        }
        return isOutputEnabled ? IOSTheme.elevatedBackground : Color(uiColor: .systemOrange).opacity(0.18)
    }

    private var auxiliaryStroke: Color {
        canSubmitSpeech ? Color.clear : IOSTheme.hairline
    }

    private var auxiliaryAccessibilityLabel: String {
        if canSubmitSpeech {
            return "Submit speech"
        }
        return isOutputEnabled ? "Turn audio off" : "Turn audio on"
    }

    private func auxiliaryAction() {
        if canSubmitSpeech {
            onSubmitSpeech()
        } else {
            onOutput()
        }
    }
}

private struct IOSCaptureInlineStatus: Identifiable, Equatable {
    enum State: Equatable {
        case capturing
        case succeeded
        case failed
    }

    let id: UUID
    var state: State
    var title: String
    var detail: String

    init(id: UUID = UUID(), state: State, title: String, detail: String) {
        self.id = id
        self.state = state
        self.title = title
        self.detail = detail
    }
}

private struct IOSCaptureStatusTurn: View {
    let status: IOSCaptureInlineStatus

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    statusIcon
                    Text(status.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(IOSTheme.hairline))

            Spacer(minLength: 48)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.title). \(status.detail)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status.state {
        case .capturing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 18, height: 18)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .frame(width: 18, height: 18)
        }
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

                    if !message.references.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(message.references) { reference in
                                IOSReferenceChip(reference: reference)
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
        message.deliveryState == .failed ? .red : .secondary
    }
}

private struct IOSActivityBlock: View {
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
    @Binding var references: [ChatReference]
    @ObservedObject var client: KishAgentClient
    @ObservedObject var projectCatalog: ProjectCatalog
    @ObservedObject var projectStore: ProjectStore
    let isSending: Bool
    let isDisabled: Bool
    let runState: ConversationRunState?
    @ObservedObject var voice: VoiceController
    @ObservedObject var audio: AudioRouteMonitor
    @ObservedObject var glassesCamera: GlassesCameraCaptureController
    let namespace: Namespace.ID
    let onCaptureStatusChange: (IOSCaptureInlineStatus?) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onStartCall: () -> Void

    @State private var showingCameraPicker = false
    @State private var showingPhotoPicker = false
    @State private var showingFilePicker = false
    @State private var showingReferencePicker = false
    @State private var pendingSnapshotReview: SnapshotReviewItem?
    @State private var pendingSnapshotIntent: CaptureIntent?
    @State private var pendingSnapshotAutoSend = false
    @State private var attachmentError: String?
    @State private var isCapturingRequestedPhoto = false
    @State private var autoSendAfterUploadAttachmentID: UUID?

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

            if !references.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(references) { reference in
                            IOSReferenceChip(
                                reference: reference,
                                onToggleLock: {
                                    toggleReferenceLock(reference)
                                },
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
            } else if hasBlockedAttachment {
                Text(blockedAttachmentText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if voice.isRecording {
                        IOSComposerTranscriptText(text: voice.transcript)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
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
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

                HStack(alignment: .center, spacing: 6) {
                    if voice.isRecording {
                        Button(action: cancelDictation) {
                            Circle()
                                .fill(Color.red.opacity(0.14))
                                .overlay {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.red)
                                }
                                .overlay(Circle().stroke(IOSTheme.hairline))
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop dictation")
                        .matchedGeometryEffect(id: "composerLeadingButton", in: namespace)

                        IOSWaveformBars(levels: voice.waveformLevels)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .padding(.horizontal, 4)
                    } else {
                        Menu {
                            Button("Camera", systemImage: "camera") {
                                attachmentError = nil
                                showingCameraPicker = true
                            }
                            Button("Choose a photo", systemImage: "photo") {
                                attachmentError = nil
                                showingPhotoPicker = true
                            }
                            Button("Upload a file", systemImage: "document.on.document") {
                                attachmentError = nil
                                showingFilePicker = true
                            }
                            Button {
                                startDictation()
                            } label: {
                                Label("Dictation", systemImage: "mic.fill")
                            }
                            Divider()
                            Button {
                                attachmentError = nil
                                showingReferencePicker = true
                            } label: {
                                Label("Reference", systemImage: "at")
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
                                .frame(width: 40, height: 40)
                        }
                        .menuOrder(.fixed)
                        .tint(Color(uiColor: .label))
                        .disabled(isDisabled)
                        .accessibilityLabel("Add")
                        .matchedGeometryEffect(id: "composerLeadingButton", in: namespace)
                    }

                    Spacer(minLength: 6)

                    Button(action: trailingAction) {
                        if (hasUploadingAttachment || isCapturingRequestedPhoto) && !isWorking {
                            ProgressView()
                                .frame(width: 18, height: 18)
                        } else {
                            Image(systemName: trailingIconName)
                                .font(.system(size: 15, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(trailingButtonForegroundColor)
                    .tint(trailingButtonForegroundColor)
                    .frame(width: 40, height: 40)
                    .background(trailingButtonColor, in: Circle())
                    .disabled(trailingButtonDisabled)
                    .accessibilityLabel(trailingAccessibilityLabel)
                    .matchedGeometryEffect(id: "composerTrailingButton", in: namespace)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
            }
            .background(IOSTheme.background, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).stroke(IOSTheme.hairline))
            .matchedGeometryEffect(id: "composerSurface", in: namespace)
        }
        .opacity(isDisabled ? 0.62 : 1)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .sheet(isPresented: $showingCameraPicker) {
            CameraAttachmentPickerView(sourceType: .camera, onResult: { result in
                handleSnapshotSelection(result, sourceType: .camera)
                showingCameraPicker = false
            }, onCancel: {
                showingCameraPicker = false
            })
        }
        .sheet(isPresented: $showingPhotoPicker) {
            CameraAttachmentPickerView(sourceType: .photoLibrary, onResult: { result in
                handleSnapshotSelection(result, sourceType: .photoLibrary)
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
        .sheet(isPresented: $showingReferencePicker) {
            ProjectPickerSheet(
                client: client,
                catalog: projectCatalog,
                pinned: projectStore,
                title: "References",
                includesHome: true,
                pinsSelection: false,
                mode: .referenceFiles,
                onSelect: { project in
                    handleReferenceProjectSelection(project)
                    showingReferencePicker = false
                },
                onSelectReferences: { references in
                    handleReferenceSelections(references)
                    showingReferencePicker = false
                }
            )
        }
        .sheet(item: $pendingSnapshotReview) { item in
            IOSSnapshotReviewView(
                item: item,
                onAttach: {
                    acceptSnapshotReview(item, prompt: nil)
                },
                onRetake: {
                    retakeSnapshotReview(item)
                },
                onCancel: {
                    discardSnapshotReview(item)
                }
            )
            .presentationDetents([.large])
        }
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSendableContent: Bool {
        hasDraft || !references.isEmpty || attachments.contains { $0.isReadyForSend }
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

    private var isWorking: Bool {
        runState?.isActive == true
    }

    private var trailingIconName: String {
        if isWorking {
            return "stop.fill"
        }
        if voice.isRecording {
            return "checkmark"
        }
        if hasSendableContent {
            return "arrow.up"
        }
        return "phone.fill"
    }

    private var trailingButtonColor: Color {
        if trailingButtonDisabled {
            return Color(uiColor: .systemGray4)
        }
        if isWorking {
            return Color(uiColor: .systemRed)
        }
        if voice.isRecording {
            return Color(uiColor: .label)
        }
        return Color(uiColor: .label)
    }

    private var trailingButtonForegroundColor: Color {
        if trailingButtonDisabled {
            return Color(uiColor: .secondaryLabel)
        }
        if isWorking {
            return .white
        }
        return Color(uiColor: .systemBackground)
    }

    private var trailingButtonDisabled: Bool {
        if isWorking {
            return false
        }
        if voice.isRecording {
            return false
        }
        if hasSendableContent {
            return isDisabled || isSending || hasUploadingAttachment || hasBlockedAttachment || isCapturingRequestedPhoto
        }
        return isDisabled || isSending || hasUploadingAttachment || hasBlockedAttachment || isCapturingRequestedPhoto
    }

    private var trailingAccessibilityLabel: String {
        if isWorking {
            return "Stop"
        }
        if voice.isRecording {
            return "Accept dictation"
        }
        if !hasSendableContent && audio.hasGlassesConnected {
            return "Start call"
        }
        return hasSendableContent ? "Send" : "Start call"
    }

    private func trailingAction() {
        if isWorking {
            onStop()
        } else if voice.isRecording {
            acceptDictation()
        } else if hasSendableContent {
            if let intent = CaptureIntentDetector.detect(in: draft), attachments.isEmpty {
                startAIRequestedCapture(intent)
            } else {
                onSend()
            }
        } else {
            onStartCall()
        }
    }

    private func handleSnapshotSelection(_ result: Result<ChatAttachment, Error>, sourceType: UIImagePickerController.SourceType) {
        switch result {
        case .success(let attachment):
            attachmentError = nil
            pendingSnapshotIntent = nil
            pendingSnapshotAutoSend = false
            pendingSnapshotReview = SnapshotReviewItem(attachment: attachment, sourceType: sourceType)
        case .failure(let error):
            attachmentError = error.localizedDescription
        }
    }

    private func acceptSnapshotReview(_ item: SnapshotReviewItem, prompt: String?) {
        let intent = pendingSnapshotIntent
        let shouldAutoSend = pendingSnapshotAutoSend
        pendingSnapshotIntent = nil
        pendingSnapshotAutoSend = false
        pendingSnapshotReview = nil
        if let intent {
            draft = intent.prompt
            onCaptureStatusChange(IOSCaptureInlineStatus(
                state: .succeeded,
                title: "Photo attached",
                detail: "Sending the captured photo with your request."
            ))
        } else if let prompt {
            appendText(prompt)
        }
        handleAttachmentSelection(.success(item.attachment), autoSendAfterUpload: shouldAutoSend)
    }

    private func retakeSnapshotReview(_ item: SnapshotReviewItem) {
        pendingSnapshotReview = nil
        AttachmentPayloadCache.shared.removePayload(for: item.attachment)
        if let intent = pendingSnapshotIntent {
            pendingSnapshotIntent = nil
            pendingSnapshotAutoSend = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                startAIRequestedCapture(intent)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if item.sourceType == .camera {
                showingCameraPicker = true
            } else {
                showingPhotoPicker = true
            }
        }
    }

    private func discardSnapshotReview(_ item: SnapshotReviewItem) {
        pendingSnapshotIntent = nil
        pendingSnapshotAutoSend = false
        pendingSnapshotReview = nil
        onCaptureStatusChange(nil)
        AttachmentPayloadCache.shared.removePayload(for: item.attachment)
    }

    private func handleAttachmentSelection(_ result: Result<ChatAttachment, Error>, autoSendAfterUpload: Bool = false) {
        switch result {
        case .success(let attachment):
            attachmentError = nil
            var pending = attachment
            if pending.needsUpload {
                pending.uploadState = .uploading
            }
            attachments.append(pending)
            if autoSendAfterUpload {
                autoSendAfterUploadAttachmentID = pending.id
            }
            if pending.needsUpload {
                uploadAttachment(pending.id)
            } else if autoSendAfterUpload {
                autoSendAfterUploadAttachmentID = nil
                onSend()
            }
        case .failure(let error):
            attachmentError = error.localizedDescription
        }
    }

    private func handleReferenceSelection(_ result: Result<ChatReference, Error>) {
        switch result {
        case .success(let reference):
            attachmentError = nil
            guard !references.contains(where: { $0.path == reference.path }) else { return }
            references.append(reference)
        case .failure(let error):
            attachmentError = error.localizedDescription
        }
    }

    private func handleReferenceProjectSelection(_ project: Project?) {
        guard let project, let path = project.path else { return }
        let reference = ChatReference(
            kind: .folder,
            title: project.name,
            path: path
        )
        handleReferenceSelection(.success(reference))
    }

    private func handleReferenceSelections(_ selectedReferences: [ChatReference]) {
        for reference in selectedReferences {
            handleReferenceSelection(.success(reference))
        }
    }

    private func removeReference(_ reference: ChatReference) {
        references.removeAll { $0.id == reference.id }
    }

    private func toggleReferenceLock(_ reference: ChatReference) {
        guard let index = references.firstIndex(where: { $0.id == reference.id }) else { return }
        references[index].isLocked.toggle()
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
                if autoSendAfterUploadAttachmentID == attachmentId {
                    autoSendAfterUploadAttachmentID = nil
                    onSend()
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
            await audio.activatePreferredHandsFreeRoute()
            await voice.startRecording()
        }
    }

    private func startAIRequestedCapture(_ intent: CaptureIntent) {
        guard intent.mediaKind == .photo else {
            attachmentError = "Video capture is not ready yet."
            onCaptureStatusChange(IOSCaptureInlineStatus(
                state: .failed,
                title: "Video capture unavailable",
                detail: "Photo capture is available now; video capture is not ready yet."
            ))
            return
        }

        attachmentError = nil
        isCapturingRequestedPhoto = true
        onCaptureStatusChange(IOSCaptureInlineStatus(
            state: .capturing,
            title: "Taking photo",
            detail: "Using \(requestedCaptureSourceTitle(for: intent))."
        ))
        Task {
            do {
                let media: CapturedMedia
                mediaCaptureDebugLog("chat capture intentSource=\(intent.source.rawValue) mediaKind=\(intent.mediaKind.rawValue) audioHasGlasses=\(audio.hasGlassesConnected) datStatus=\(glassesCamera.status.rawValue) datCanAttempt=\(glassesCamera.canAttemptCapture) datPermission=\(glassesCamera.cameraPermission)")
                switch intent.source {
                case .phoneCamera:
                    mediaCaptureDebugLog("chat capture source=phone explicit")
                    media = try await ProgrammaticPhoneCameraCapture.shared.capturePhoto()
                case .glassesCamera:
                    mediaCaptureDebugLog("chat capture source=glasses explicit")
                    media = try await glassesCamera.capturePhoto()
                case .automatic:
                    if audio.hasGlassesConnected || glassesCamera.canAttemptCapture {
                        mediaCaptureDebugLog("chat capture source=glasses automatic")
                        media = try await glassesCamera.capturePhoto()
                    } else {
                        mediaCaptureDebugLog("chat capture source=phone automatic no-glasses-signal")
                        media = try await ProgrammaticPhoneCameraCapture.shared.capturePhoto()
                    }
                }
                let attachment = try ChatAttachment.capturedMedia(media)
                onCaptureStatusChange(IOSCaptureInlineStatus(
                    state: .succeeded,
                    title: "Photo captured",
                    detail: "Captured from \(capturedSourceTitle(for: media.source)). Review it before sending."
                ))
                pendingSnapshotIntent = intent
                pendingSnapshotAutoSend = true
                pendingSnapshotReview = SnapshotReviewItem(
                    attachment: attachment,
                    sourceType: nil,
                    captureSource: media.source
                )
            } catch {
                attachmentError = error.localizedDescription
                onCaptureStatusChange(IOSCaptureInlineStatus(
                    state: .failed,
                    title: "Photo capture failed",
                    detail: error.localizedDescription
                ))
            }
            isCapturingRequestedPhoto = false
        }
    }

    private func capturedSourceTitle(for source: MediaCaptureSource) -> String {
        switch source {
        case .phoneCamera:
            return "the phone camera"
        case .glassesCamera:
            return "the glasses camera"
        case .automatic:
            return "the selected camera"
        }
    }

    private func requestedCaptureSourceTitle(for intent: CaptureIntent) -> String {
        switch intent.source {
        case .phoneCamera:
            return "the phone camera"
        case .glassesCamera:
            return "the glasses camera"
        case .automatic:
            return (audio.hasGlassesConnected || glassesCamera.canAttemptCapture) ? "the glasses camera" : "the phone camera"
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
        appendText(clean)
    }

    private func appendText(_ text: String) {
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = existing.isEmpty ? text : "\(existing) \(text)"
    }
}

private struct CallSnapshotReviewItem: Identifiable {
    let id = UUID()
    let snapshot: SnapshotReviewItem
    let intent: CaptureIntent
}

private struct SnapshotReviewItem: Identifiable {
    let id = UUID()
    let attachment: ChatAttachment
    let sourceType: UIImagePickerController.SourceType?
    let captureSource: MediaCaptureSource

    init(
        attachment: ChatAttachment,
        sourceType: UIImagePickerController.SourceType?,
        captureSource: MediaCaptureSource? = nil
    ) {
        self.attachment = attachment
        self.sourceType = sourceType
        self.captureSource = captureSource ?? .phoneCamera
    }
}

private struct IOSSnapshotReviewView: View {
    let item: SnapshotReviewItem
    let onAttach: () -> Void
    let onRetake: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Group {
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.system(size: 34, weight: .semibold))
                            Text("Image unavailable")
                                .font(.headline)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                HStack(spacing: 10) {
                    Button(retakeTitle, action: onRetake)
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                    Spacer(minLength: 16)

                    Button("Add", action: onAttach)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.accentColor)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(IOSTheme.background)
            .navigationTitle("Snapshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private var previewImage: UIImage? {
        guard let url = AttachmentPayloadCache.shared.cachedFileURL(for: item.attachment) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private var retakeTitle: String {
        if item.sourceType == .photoLibrary {
            return "Change"
        }
        return "Retake"
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
    let levels: [CGFloat]

    private var cleanTranscript: String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IOSComposerTranscriptText(text: cleanTranscript)
            IOSWaveformBars(levels: levels)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.vertical, cleanTranscript.isEmpty ? 9 : 8)
    }
}

private struct IOSComposerTranscriptText: View {
    let text: String

    private var cleanText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Text(cleanText.isEmpty ? "Listening" : cleanText)
            .font(.callout)
            .foregroundStyle(cleanText.isEmpty ? .tertiary : .primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(cleanText.isEmpty ? "Listening" : cleanText)
    }
}

private struct IOSWaveformBars: View {
    let levels: [CGFloat]

    private var displayLevels: [CGFloat] {
        let targetCount = 32
        let clean = levels.map { min(max($0, 0.035), 1) }
        if clean.count >= targetCount {
            return Array(clean.suffix(targetCount))
        }
        return Array(repeating: CGFloat(0.035), count: targetCount - clean.count) + clean
    }

    private func barWidth(for availableWidth: CGFloat) -> CGFloat {
        let totalSpacing = CGFloat(max(0, displayLevels.count - 1)) * 4
        return max(3, min(7, (availableWidth - totalSpacing) / CGFloat(displayLevels.count)))
    }

    private func barHeight(_ value: CGFloat) -> CGFloat {
        let shaped = pow(value, 0.72)
        return max(5, min(30, 5 + shaped * 27))
    }

    private func barColor(for value: CGFloat) -> Color {
        Color(uiColor: .label)
            .opacity(0.42 + min(max(value, 0), 1) * 0.52)
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 4) {
                ForEach(Array(displayLevels.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(barColor(for: value))
                        .frame(
                            width: barWidth(for: proxy.size.width),
                            height: barHeight(value)
                        )
                        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.72), value: value)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .clipped()
        }
        .frame(height: 24)
        .accessibilityHidden(true)
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

private struct IOSReferenceChip: View {
    let reference: ChatReference
    var onToggleLock: (() -> Void)?
    var onRemove: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if let onToggleLock {
            chipContent
                .contextMenu {
                    Button {
                        onToggleLock()
                    } label: {
                        Label(reference.isLocked ? "Unlock" : "Lock", systemImage: reference.isLocked ? "lock.open" : "lock")
                    }
                }
        } else {
            chipContent
        }
    }

    private var chipContent: some View {
        HStack(spacing: 6) {
            Image(systemName: reference.kind == .folder ? "folder" : "doc.text")
                .font(.caption2.weight(.semibold))
            Text(reference.promptToken)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if reference.isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.semibold))
                    .accessibilityLabel("Locked")
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(reference.title)")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(IOSTheme.elevatedBackground, in: Capsule())
        .overlay(Capsule().stroke(IOSTheme.hairline))
    }
}

private struct ConversationPicker: View {
    let conversations: [Conversation]
    let selectedID: UUID?
    let isAutonomySelected: Bool
    @ObservedObject var client: KishAgentClient
    @ObservedObject var audio: AudioRouteMonitor
    @ObservedObject var wake: WakePhraseController
    let onSelect: (UUID) -> Void
    let onNewChat: () -> Void
    let onOpenSettings: () -> Void
    let onOpenAutonomy: () -> Void
    let onDelete: (UUID) -> Void
    let onCopyTranscript: (Conversation) -> Void
    let onCopyChatID: (Conversation) -> Void
    let onClose: () -> Void

    @State private var searchQuery = ""

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

                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .background(IOSTheme.elevatedBackground.opacity(0.9), in: Circle())
                .overlay(Circle().stroke(IOSTheme.hairline))
                .accessibilityLabel("New chat")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(IOSTheme.elevatedBackground.opacity(0.85), in: Circle())
                .overlay(Circle().stroke(IOSTheme.hairline))
                .accessibilityLabel("Close conversations")
            }
            .padding(.horizontal, 18)
            .padding(.top, 64)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Search chats", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .submitLabel(.search)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(IOSTheme.elevatedBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(IOSTheme.hairline)
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 18)

            Button(action: onOpenAutonomy) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isAutonomySelected ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Autonomy")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Brief, inbox, memory, routines")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if isAutonomySelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 54)
            .background(isAutonomySelected ? Color.accentColor.opacity(0.10) : IOSTheme.elevatedBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(IOSTheme.hairline))
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
            } else if filteredConversations.isEmpty {
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("No matches")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredConversations) { conversation in
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

                            if conversation.id != filteredConversations.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.hidden)
            }

            IOSConnectionPanel(
                client: client,
                audio: audio,
                onOpenSettings: onOpenSettings
            )
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 48)
        }
        .background(IOSTheme.groupedBackground.opacity(0.72))
        .onAppear {
            audio.refresh()
        }
    }

    private var sortedConversations: [Conversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var filteredConversations: [Conversation] {
        sortedConversations.filter { $0.matchesSearch(searchQuery) }
    }

    private var pendingDecisionConversations: [Conversation] {
        filteredConversations.filter { !$0.approvals.isEmpty }
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

}

private struct IOSConnectionPanel: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var audio: AudioRouteMonitor
    let onOpenSettings: () -> Void

    var body: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 10) {
                Circle()
                    .fill(overallTint)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("KishOS settings")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(overallSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(IOSTheme.hairline))
    }

    private var overallSummary: String {
        if [client.miniStatus, client.agentStatus, client.chatStatus, audio.statusLabel].allSatisfy(iosIsHealthyStatus) {
            return "Ready to help"
        }
        if client.isDisconnected {
            return "Needs connection"
        }
        if client.isSending {
            return "Working"
        }
        return [client.miniStatus, client.agentStatus, client.chatStatus, audio.statusLabel]
            .filter { !iosIsHealthyStatus($0) }
            .map(iosFriendlyStatus)
            .first ?? "Checking"
    }

    private var overallTint: Color {
        switch overallSummary {
        case "Ready to help":
            return .green
        case "Needs connection":
            return .red
        case "Working", "Checking":
            return .orange
        default:
            return .secondary
        }
    }
}

private struct IOSSettingsPage: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var audio: AudioRouteMonitor
    @ObservedObject var glassesCamera: GlassesCameraCaptureController
    @ObservedObject var wake: WakePhraseController
    let agentURL: String
    let onReconnect: () -> Void

    @AppStorage(LiveVoiceHeuristics.SpokenReplyMode.storageKey)
    private var spokenReplyMode: LiveVoiceHeuristics.SpokenReplyMode = .full

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Bot Health")
                            .font(.headline)
                        Spacer()
                        IOSSettingsStatusPill(title: connectionSummary, tint: connectionTint)
                    }

                    Button(action: onReconnect) {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.clockwise")
                            Text("Check link")
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .font(.callout.weight(.semibold))
                        .frame(height: 42)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(uiColor: .label))

                    Button {
                        audio.refresh()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.clockwise")
                            Text("Check audio")
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .font(.callout.weight(.semibold))
                        .frame(height: 42)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    HStack(spacing: 8) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.secondary)
                        Text(agentURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Call Settings")
                        .font(.headline)

                    Toggle(isOn: Binding(
                        get: { wake.isEnabled },
                        set: { wake.setEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wake phrase")
                            Text("Start listening by voice.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Spoken replies")
                            Spacer()
                            Picker("Spoken replies", selection: $spokenReplyMode) {
                                ForEach(LiveVoiceHeuristics.SpokenReplyMode.allCases, id: \.self) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        Text("How replies are read aloud in live voice.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Glasses Camera Control")
                            .font(.headline)
                        Spacer()
                        IOSSettingsStatusPill(title: glassesCameraOverallTitle, tint: glassesCameraOverallTint)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(glassesConnectionTint)
                            .frame(width: 34, height: 34)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(glassesConnectionTitle)
                                .font(.callout.weight(.semibold))
                            Text(glassesConnectionDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 8)

                        IOSSettingsStatusPill(title: glassesConnectionPillTitle, tint: glassesConnectionTint)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(glassesConnectionTitle). \(glassesConnectionDetail)")

                    Toggle(isOn: Binding(
                        get: { audio.prefersHandsFreeRoute },
                        set: { audio.setPrefersHandsFreeRoute($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Go hands-free")
                            Text(audio.glassesSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    IOSSettingsDiagnosticRow(
                        icon: "checkmark.seal",
                        title: "Registration",
                        detail: glassesCameraRegistrationDetail,
                        status: glassesCamera.status.label,
                        tint: glassesCameraRegistrationTint
                    )

                    IOSSettingsDiagnosticRow(
                        icon: "eyeglasses",
                        title: "Camera device",
                        detail: glassesCameraDeviceDetail,
                        status: glassesCameraDeviceTitle,
                        tint: glassesCameraDeviceTint
                    )

                    IOSSettingsDiagnosticRow(
                        icon: "camera",
                        title: "Camera permission",
                        detail: glassesCameraPermissionDetail,
                        status: glassesCameraPermissionTitle,
                        tint: glassesCameraPermissionTint
                    )

                    IOSSettingsDiagnosticRow(
                        icon: "dot.radiowaves.left.and.right",
                        title: "AI capture",
                        detail: glassesCameraCaptureDetail,
                        status: glassesCameraCaptureTitle,
                        tint: glassesCameraCaptureTint
                    )

                    if let lastError = glassesCamera.lastError, !lastError.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .frame(width: 26, height: 26)
                                .accessibilityHidden(true)
                            Text(lastError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    VStack(spacing: 8) {
                        Button {
                            glassesCamera.refreshStatus()
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.clockwise")
                                Text("Check camera status")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                            }
                            .font(.callout.weight(.semibold))
                            .frame(height: 40)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(IOSSettingsActionButtonStyle(kind: .primary))

                        Button {
                            glassesCamera.requestCameraPermission()
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "camera.badge.ellipsis")
                                Text("Request camera permission")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                            }
                            .font(.callout.weight(.semibold))
                            .frame(height: 40)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(IOSSettingsActionButtonStyle(kind: .secondary))

                        if glassesCameraCanRegister {
                            Button {
                                glassesCamera.register()
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "link.badge.plus")
                                    Text("Register with Meta AI")
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.78)
                                }
                                .font(.callout.weight(.semibold))
                                .frame(height: 40)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(IOSSettingsActionButtonStyle(kind: .secondary))
                        }
                    }
                }
                .settingsCard()
            }
            .padding(16)
        }
        .background(IOSTheme.groupedBackground)
        .onAppear {
            audio.refresh()
            glassesCamera.refreshStatus()
        }
    }

    private var connectionSummary: String {
        if client.isDisconnected {
            return "Not connected"
        }
        if client.isSending {
            return "Working"
        }
        if [client.miniStatus, client.agentStatus, client.chatStatus].allSatisfy(iosIsHealthyStatus) {
            return "Connected"
        }
        return "Checking"
    }

    private var connectionTint: Color {
        switch connectionSummary {
        case "Connected":
            return .green
        case "Working", "Checking":
            return .orange
        default:
            return .red
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

    private var glassesCameraRegistrationDetail: String {
        switch glassesCamera.status.rawValue {
        case "registered", "streaming", "waitingForDevice":
            return "Clawk is registered with Meta AI for DAT camera access."
        case "registering":
            return "Meta AI registration is in progress."
        case "available":
            return "Register once with Meta AI before camera capture."
        case "failed":
            return "Registration needs attention. Use Check camera status first."
        default:
            return "Meta AI registration is not available in this build or environment."
        }
    }

    private var glassesCameraRegistrationTint: Color {
        switch glassesCamera.status.rawValue {
        case "registered", "streaming", "waitingForDevice":
            return .green
        case "registering", "available":
            return .orange
        case "failed":
            return .red
        default:
            return .secondary
        }
    }

    private var glassesCameraDeviceTitle: String {
        if glassesCamera.hasActiveDevice {
            return "Eligible"
        }
        if !glassesCamera.devices.isEmpty {
            return "Seen"
        }
        return "No device"
    }

    private var glassesCameraDeviceDetail: String {
        if glassesCamera.hasActiveDevice {
            return "An eligible glasses camera device is active."
        }
        if glassesCamera.devices.count == 1 {
            return "One glasses device is visible, but not active for camera yet."
        }
        if glassesCamera.devices.count > 1 {
            return "\(glassesCamera.devices.count) glasses devices are visible; waiting for an eligible camera device."
        }
        return "Keep glasses connected, nearby, powered on, and in Developer Mode."
    }

    private var glassesCameraDeviceTint: Color {
        if glassesCamera.hasActiveDevice {
            return .green
        }
        if !glassesCamera.devices.isEmpty {
            return .orange
        }
        return .secondary
    }

    private var glassesCameraPermissionTitle: String {
        let normalized = glassesCamera.cameraPermission.lowercased()
        if normalized.contains("granted") {
            return "Granted"
        }
        if normalized.contains("denied") || normalized.contains("failed") {
            return "Needs check"
        }
        if normalized.contains("unknown") || normalized.contains("not checked") {
            return "Unknown"
        }
        return glassesCamera.cameraPermission
    }

    private var glassesCameraPermissionDetail: String {
        let normalized = glassesCamera.cameraPermission.lowercased()
        if normalized.contains("granted") {
            return "Meta AI has granted camera access for glasses capture."
        }
        if normalized.contains("failed") {
            return "Permission status could not be checked. Use the permission button to open Meta AI."
        }
        if normalized.contains("denied") {
            return "Open Meta AI permission flow and allow camera access."
        }
        return "Camera permission is checked through Meta AI after registration."
    }

    private var glassesCameraPermissionTint: Color {
        let normalized = glassesCamera.cameraPermission.lowercased()
        if normalized.contains("granted") {
            return .green
        }
        if normalized.contains("denied") || normalized.contains("failed") {
            return .red
        }
        return .secondary
    }

    private var glassesCameraPermissionGranted: Bool {
        glassesCamera.cameraPermission.lowercased().contains("granted")
    }

    private var glassesCameraReadyForRequest: Bool {
        glassesCamera.isReadyForCapture || (glassesCamera.status.rawValue == "registered" && glassesCamera.hasActiveDevice && glassesCameraPermissionGranted)
    }

    private var glassesCameraOverallTitle: String {
        if glassesCameraReadyForRequest {
            return "Ready"
        }
        if glassesCamera.status.rawValue != "registered" {
            return "Register"
        }
        if !glassesCamera.hasActiveDevice {
            return "Waiting"
        }
        if !glassesCameraPermissionGranted {
            return "Needs permission"
        }
        return "Blocked"
    }

    private var glassesCameraOverallTint: Color {
        if glassesCameraReadyForRequest {
            return .green
        }
        if glassesCamera.status.rawValue == "failed" {
            return .red
        }
        if glassesCamera.status.rawValue == "registered" || glassesCamera.status.rawValue == "available" {
            return .orange
        }
        return .secondary
    }

    private var glassesCameraCaptureTitle: String {
        if glassesCameraReadyForRequest {
            return glassesCamera.isReadyForCapture ? "Streaming" : "Ready"
        }
        if glassesCamera.status.rawValue != "registered" {
            return "Register first"
        }
        if !glassesCamera.hasActiveDevice {
            return "Waiting"
        }
        if !glassesCameraPermissionGranted {
            return "Needs permission"
        }
        return "Blocked"
    }

    private var glassesCameraCaptureTint: Color {
        if glassesCameraReadyForRequest {
            return .green
        }
        if glassesCamera.status.rawValue == "failed" {
            return .red
        }
        if glassesCamera.status.rawValue == "registered" || glassesCamera.hasActiveDevice {
            return .orange
        }
        return .secondary
    }

    private var glassesCameraCaptureDetail: String {
        if glassesCameraReadyForRequest {
            return "AI photo requests will use the glasses camera."
        }
        if glassesCamera.hasActiveDevice {
            return "Device is eligible; grant camera permission to enable capture."
        }
        if glassesCamera.canAttemptCapture {
            return "Waiting for an eligible glasses camera device."
        }
        return "Register with Meta AI before capture."
    }

    private var glassesCameraCanRegister: Bool {
        switch glassesCamera.status.rawValue {
        case "available", "failed", "unavailable":
            return true
        default:
            return false
        }
    }
}

private struct IOSSettingsStatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.84)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(IOSTheme.secondaryBackground, in: Capsule())
    }
}

private struct IOSSettingsDiagnosticRow: View {
    let icon: String
    let title: String
    let detail: String
    let status: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.88)
            }

            Spacer(minLength: 8)

            IOSSettingsStatusPill(title: status, tint: tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail). \(status).")
    }
}

private struct IOSSettingsActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .background(backgroundColor(configuration: configuration), in: Capsule())
            .overlay {
                if kind == .secondary {
                    Capsule()
                        .strokeBorder(IOSTheme.hairline, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary:
            return .white
        case .secondary:
            return Color(uiColor: .label)
        }
    }

    private func backgroundColor(configuration: Configuration) -> Color {
        switch kind {
        case .primary:
            return configuration.isPressed ? Color.accentColor.opacity(0.78) : Color.accentColor
        case .secondary:
            return configuration.isPressed ? IOSTheme.secondaryBackground.opacity(0.72) : IOSTheme.secondaryBackground
        }
    }
}

private func iosIsHealthyStatus(_ value: String) -> Bool {
    switch value {
    case "Online", "Ready", "On", "System", "Built-in", "Bluetooth", "Glasses", "Headset", "Idle":
        return true
    default:
        return false
    }
}

private func iosFriendlyStatus(_ value: String) -> String {
    switch value {
    case "Online", "Ready", "On":
        return "Ready"
    case "System", "Built-in":
        return "Phone"
    case "Bluetooth", "Glasses", "Headset":
        return value
    case "Sending":
        return "Working"
    case "Checking":
        return "Checking"
    case "Listening":
        return "Listening"
    case "Idle":
        return "Ready"
    case "Question":
        return "Needs answer"
    case "Error":
        return "Problem"
    case "Offline", "Unavailable":
        return "Not connected"
    default:
        return value
    }
}

private extension View {
    func settingsCard() -> some View {
        self
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IOSTheme.hairline))
    }
}

private struct IOSCapabilityDetails: View {
    let inventory: ToolInventory
    let inventoryStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if inventoryStatus != "Ready" || !inventory.hasAnyCapabilities {
                capabilityLine(title: "Tools", detail: inventoryStatus, available: false)
            } else {
                IOSCapabilityGroup(
                    title: "Engines",
                    lines: inventory.availableEngines.prefix(3).map {
                        IOSCapabilityLine(title: $0.name, detail: $0.detail ?? $0.status, available: true)
                    }
                )
                IOSCapabilityGroup(
                    title: "Tools",
                    lines: inventory.availableCommands.prefix(5).map {
                        IOSCapabilityLine(title: $0.name, detail: $0.detail ?? $0.status, available: true)
                    }
                )
                IOSCapabilityGroup(
                    title: "Recent",
                    lines: inventory.recentTools.prefix(5).map {
                        IOSCapabilityLine(title: $0.name, detail: "\($0.count)", available: true)
                    }
                )
                IOSCapabilityGroup(
                    title: "Needs setup",
                    lines: inventory.unavailableCapabilities.prefix(4).map {
                        IOSCapabilityLine(title: $0.name, detail: $0.detail ?? $0.status, available: false)
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func capabilityLine(title: String, detail: String, available: Bool) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(available ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct IOSCapabilityGroup: View {
    let title: String
    let lines: [IOSCapabilityLine]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(lines) { line in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(line.available ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(line.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(line.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct IOSCapabilityLine: Identifiable {
    var id: String { "\(title)-\(detail)-\(available)" }
    let title: String
    let detail: String
    let available: Bool
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
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(conversation.title)
                            .font(.headline.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if conversation.runState.isActive {
                            IOSRunStatePill(runState: conversation.runState)
                        }

                        Spacer(minLength: 8)

                        Text(updatedText)
                            .font(.callout)
                            .foregroundStyle(metadataForeground)
                            .lineLimit(1)

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }

                    Text(rowDetail)
                        .font(.subheadline)
                        .foregroundStyle(metadataForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
    }

    private var rowBackground: Color {
        isSelected ? Color.accentColor.opacity(0.10) : Color.clear
    }

    private var metadataForeground: Color {
        isSelected ? Color(uiColor: .label).opacity(0.74) : Color(uiColor: .secondaryLabel)
    }

    private var rowDetail: String {
        if conversation.runState.isActive {
            return "\(conversation.projectBadgeText) - \(conversation.runState.label)"
        }
        return conversation.projectBadgeText
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
