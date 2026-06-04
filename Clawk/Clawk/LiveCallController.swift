import AVFoundation
import Foundation

@MainActor
final class LiveCallController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum CallState: String {
        case connecting
        case listening
        case userSpeaking
        case sendingTurn
        case agentThinking
        case agentSpeaking
        case needsAnswer
        case failed
        case ended

        var label: String {
            switch self {
            case .connecting: return "Connecting"
            case .listening: return "Listening"
            case .userSpeaking: return "Listening"
            case .sendingTurn: return "Sending"
            case .agentThinking: return "Working"
            case .agentSpeaking: return "Speaking"
            case .needsAnswer: return "Question"
            case .failed: return "Failed"
            case .ended: return "Ended"
            }
        }
    }

    @Published private(set) var state: CallState = .connecting {
        didSet {
            guard oldValue != state else { return }
            syncLiveActivity()
        }
    }
    @Published private(set) var activeConversationID: UUID? {
        didSet { syncLiveActivity() }
    }
    @Published private(set) var activeUserPartial = ""
    @Published private(set) var activeAgentText = ""
    @Published private(set) var elapsedSeconds = 0
    @Published var isMuted = false
    @Published var isOutputEnabled = true
    @Published var failureMessage: String? {
        didSet { syncLiveActivity() }
    }

    private let client: KishAgentClient
    private let workspace: KishOSWorkspace
    private let voice: VoiceController
    private let onConversationStarted: (UUID) -> Void
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let liveActivity = KishOSLiveActivityController.shared
    private var elapsedTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?
    private var activeSendTask: Task<Void, Never>?
    private var hasLiveActivitySession = false

    init(
        client: KishAgentClient,
        workspace: KishOSWorkspace,
        voice: VoiceController,
        initialConversationID: UUID?,
        onConversationStarted: @escaping (UUID) -> Void
    ) {
        self.client = client
        self.workspace = workspace
        self.voice = voice
        self.activeConversationID = initialConversationID
        self.onConversationStarted = onConversationStarted
        super.init()
        speechSynthesizer.delegate = self
    }

    func start() async {
        guard state == .connecting else { return }
        startElapsedTimer()
        syncLiveActivity()
        await client.refreshHealth()
        await beginListening()
    }

    func handleTranscriptChange(_ transcript: String) {
        guard state == .listening || state == .userSpeaking else { return }
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        activeUserPartial = clean
        state = .userSpeaking
        scheduleUtteranceFinalization(for: clean)
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            _ = voice.stopRecording()
            state = .listening
        } else if state == .listening {
            Task { await beginListening() }
        }
    }

    func toggleOutput() {
        isOutputEnabled.toggle()
        if !isOutputEnabled {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }

    func interruptAndListen() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        activeAgentText = ""
        Task { await beginListening() }
    }

    func submitCurrentUtterance() {
        Task { await finalizeCurrentUtterance() }
    }

    func answer(_ approval: ApprovalRequest, with answer: String) {
        let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let activeConversationID else { return }

        Task {
            do {
                try await client.answerApproval(approval.id, approved: true, answer: clean)
                workspace.recordApprovalAnswerAccepted(approval.id, in: activeConversationID)
                state = .agentThinking
            } catch {
                workspace.recordApprovalAnswerFailure(error.localizedDescription, in: activeConversationID)
                failureMessage = error.localizedDescription
                state = .failed
            }
        }
    }

    func cancel(_ approval: ApprovalRequest) {
        guard let activeConversationID else { return }

        Task {
            do {
                try await client.answerApproval(approval.id, approved: false)
                workspace.recordApprovalAnswerRejected(approval.id, in: activeConversationID)
                await beginListening()
            } catch {
                workspace.recordApprovalAnswerFailure(error.localizedDescription, in: activeConversationID)
                failureMessage = error.localizedDescription
                state = .failed
            }
        }
    }

    func endCall() {
        finalizeTask?.cancel()
        activeSendTask?.cancel()
        elapsedTask?.cancel()
        _ = voice.stopRecording()
        speechSynthesizer.stopSpeaking(at: .immediate)
        activeUserPartial = ""
        activeAgentText = ""
        state = .ended
        liveActivity.endLiveCall()
        hasLiveActivitySession = false
    }

    private func beginListening() async {
        guard state != .ended else { return }
        failureMessage = nil
        activeAgentText = ""
        activeUserPartial = ""

        if isMuted {
            state = .listening
            return
        }

        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        await voice.startRecording()
        state = voice.isRecording ? .listening : .failed
        if !voice.isRecording {
            failureMessage = voice.status
        }
    }

    private func scheduleUtteranceFinalization(for transcript: String) {
        finalizeTask?.cancel()
        finalizeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.35))
            await MainActor.run {
                guard let self,
                      self.activeUserPartial == transcript,
                      self.state == .userSpeaking
                else { return }
                self.submitCurrentUtterance()
            }
        }
    }

    private func finalizeCurrentUtterance() async {
        finalizeTask?.cancel()
        let spokenText = voice.stopRecording() ?? activeUserPartial
        let clean = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        activeUserPartial = ""

        guard !clean.isEmpty else {
            await beginListening()
            return
        }

        await sendUserTurn(clean)
    }

    private func sendUserTurn(_ text: String) async {
        if client.isDisconnected {
            let conversation = queueUserTurn(text)
            activeConversationID = conversation.id
            onConversationStarted(conversation.id)
            failureMessage = "Saved locally. Reconnect to send."
            state = .failed
            return
        }

        guard let conversation = appendUserTurn(text) else {
            failureMessage = "Could not create call transcript."
            state = .failed
            return
        }

        activeConversationID = conversation.id
        onConversationStarted(conversation.id)
        let messageID = conversation.messages.last?.id
        let payload = messageTextForAgent(text, attachments: [])

        state = .sendingTurn
        activeAgentText = ""
        workspace.beginAgentResponse(in: conversation.id)

        activeSendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.client.sendStreaming(
                    payload,
                    threadId: conversation.threadId,
                    conversationId: conversation.id
                ) { event in
                    await self.handleStreamEvent(event, conversationId: conversation.id)
                }
                self.workspace.apply(result, to: conversation.id)
                self.syncLiveActivity(detailOverride: "Reply ready")
                self.speak(result.text)
            } catch {
                if self.isOfflineError(error),
                   let messageID,
                   self.workspace.requeueMessageAfterOfflineFailure(conversationID: conversation.id, messageID: messageID) {
                    self.failureMessage = "Saved locally. Reconnect to send."
                } else {
                    self.workspace.applyFailure(error, to: conversation.id)
                    self.failureMessage = error.localizedDescription
                }
                self.state = .failed
            }
        }
    }

    private func appendUserTurn(_ text: String) -> Conversation? {
        if let activeConversationID,
           let existing = workspace.appendUserMessage(text, to: activeConversationID) {
            return existing
        }
        return workspace.createConversation(firstMessage: text)
    }

    private func queueUserTurn(_ text: String) -> Conversation {
        if let activeConversationID,
           let existing = workspace.queueUserMessage(text, to: activeConversationID) {
            return existing
        }
        return workspace.queueConversation(firstMessage: text)
    }

    private func handleStreamEvent(_ event: AgentStreamEvent, conversationId: UUID) async {
        switch event.type {
        case "text":
            if let text = event.text {
                activeAgentText += text
                state = .agentSpeaking
                workspace.appendStreamingText(text, to: conversationId)
            }
        case "activity":
            if let text = event.text {
                state = .agentThinking
                workspace.appendActivity(text, to: conversationId)
            }
        case "tool":
            if let tool = event.tool {
                state = .agentThinking
                workspace.appendActivity("tool: \(tool.name)", to: conversationId)
            }
        case "approval":
            if let approval = event.approval {
                _ = voice.stopRecording()
                speechSynthesizer.stopSpeaking(at: .immediate)
                workspace.setApprovals([approval], for: conversationId)
                workspace.appendActivity("question asked", to: conversationId)
                state = .needsAnswer
            }
        case "approval_result":
            if let approvalId = event.approvalId {
                workspace.removeApproval(approvalId, from: conversationId)
            }
            workspace.appendActivity(event.timedOut == true ? "question timed out" : "question answered", to: conversationId)
        case "status":
            if event.status == "waiting_approval" {
                workspace.appendActivity("waiting for answer", to: conversationId)
                state = .needsAnswer
            } else if state != .agentSpeaking {
                state = .agentThinking
            }
        default:
            break
        }
    }

    private func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            Task { await beginListening() }
            return
        }

        guard isOutputEnabled else {
            Task { await beginListening() }
            return
        }

        state = .agentSpeaking
        syncLiveActivity(detailOverride: "Replying")
        let utterance = AVSpeechUtterance(string: clean)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        speechSynthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.state != .ended, self.state != .needsAnswer, self.state != .failed else { return }
            await self.beginListening()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.state == .agentSpeaking else { return }
            await self.beginListening()
        }
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run {
                    guard let self, self.state != .ended else { return }
                    self.elapsedSeconds += 1
                }
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

    private func syncLiveActivity(detailOverride: String? = nil) {
        guard state != .ended else {
            liveActivity.endLiveCall()
            hasLiveActivitySession = false
            return
        }

        let title = activeConversationID
            .flatMap { workspace.conversation(id: $0)?.title }
            ?? "KishOS"
        let status = state.label
        let detail = detailOverride ?? liveActivityDetail

        liveActivity.updateLiveCall(title: title, status: status, detail: detail)
        hasLiveActivitySession = true
    }

    private var liveActivityDetail: String {
        if let failureMessage, !failureMessage.isEmpty {
            return clipped(failureMessage)
        }
        switch state {
        case .connecting:
            return "Starting call"
        case .listening:
            return "Waiting for you"
        case .userSpeaking:
            return clipped(activeUserPartial)
        case .sendingTurn:
            return "Sending"
        case .agentThinking:
            return "kish-agent is working"
        case .agentSpeaking:
            return activeAgentText.isEmpty ? "Replying" : clipped(activeAgentText)
        case .needsAnswer:
            return "Answer needed"
        case .failed:
            return "Call paused"
        case .ended:
            return ""
        }
    }

    private func clipped(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 90 else { return clean }
        return String(clean.prefix(87)) + "..."
    }
}
