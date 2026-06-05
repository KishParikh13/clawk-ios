import AVFoundation
import Foundation
import os

@MainActor
final class LiveCallController: NSObject, ObservableObject {
    enum CallState: String {
        case connecting
        case listening
        case userSpeaking
        case sendingTurn
        case capturingMedia
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
            case .capturingMedia: return "Capturing"
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
            updateSoundscape(from: oldValue)
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
    private let initialProject: Project?
    private let onConversationStarted: (UUID) -> Void
    private let captureMediaHandler: ((CaptureIntent, UUID?, String?) async throws -> [ChatAttachment])?
    private let apple = AppleSpeaker()
    private let gemini = GeminiSpeaker()
    private let soundscape = CallSoundscape()
    private let liveActivity = KishOSLiveActivityController.shared
    private let log = Logger(subsystem: "com.kishparikh.clawk", category: "livecall")
    private var elapsedTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?
    private var activeSendTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    private var narrateTask: Task<Void, Never>?
    private var isVocalizing = false
    private var hasLiveActivitySession = false
    /// Guards `finalizeCurrentUtterance` against a manual `submitCurrentUtterance`
    /// tap racing the auto-finalize task. Both run on the @MainActor, but each
    /// awaits inside the body, so without this a second entrant could run the
    /// body twice (e.g. call `beginListening()` mid-send). Set on entry, reset on
    /// every exit path.
    private var isFinalizing = false

    init(
        client: KishAgentClient,
        workspace: KishOSWorkspace,
        voice: VoiceController,
        initialConversationID: UUID?,
        initialProject: Project?,
        onConversationStarted: @escaping (UUID) -> Void,
        captureMediaHandler: ((CaptureIntent, UUID?, String?) async throws -> [ChatAttachment])? = nil
    ) {
        self.client = client
        self.workspace = workspace
        self.voice = voice
        self.activeConversationID = initialConversationID
        self.initialProject = initialConversationID == nil ? initialProject : nil
        self.onConversationStarted = onConversationStarted
        self.captureMediaHandler = captureMediaHandler
        super.init()
    }

    func start() async {
        guard state == .connecting || state == .failed else { return }
        state = .connecting
        failureMessage = nil
        startElapsedTimer()
        syncLiveActivity()
        await client.refreshHealth()
        let audioReady = await voice.beginCallAudio()
        guard audioReady else {
            failureMessage = voice.status
            state = .failed
            return
        }
        soundscape.play(.callStart)
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
            finalizeTask?.cancel()
            _ = voice.stopRecording()
            activeUserPartial = ""
            state = .listening
        } else if state == .listening {
            Task { await beginListening() }
        }
    }

    func toggleOutput() {
        isOutputEnabled.toggle()
        if !isOutputEnabled {
            let wasSpeaking = state == .agentSpeaking
            stopSpeaking()
            if wasSpeaking {
                Task { await beginListening() }
            }
        }
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
        elapsedTask?.cancel()
        let threadId = activeConversationID.flatMap { workspace.conversation(id: $0)?.threadId }
        activeSendTask?.cancel()
        if let activeConversationID,
           workspace.conversation(id: activeConversationID)?.isRunning == true {
            workspace.cancelActiveResponse(in: activeConversationID)
        }
        _ = voice.stopRecording()
        voice.endCallAudio()
        stopSpeaking()
        soundscape.play(.callEnd)   // detached, survives the teardown below
        soundscape.end()
        activeUserPartial = ""
        activeAgentText = ""
        state = .ended
        liveActivity.endLiveCall()
        hasLiveActivitySession = false
        if let threadId {
            Task { try? await client.cancel(threadId: threadId) }
        }
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

        stopSpeaking()

        await voice.startRecording()
        state = voice.isRecording ? .listening : .failed
        if !voice.isRecording {
            failureMessage = voice.status
        }
    }

    private func scheduleUtteranceFinalization(for transcript: String) {
        // Only auto-finalize substantial utterances. One-letter or one-noise
        // partials wait — when the user keeps speaking, handleTranscriptChange
        // reschedules with the longer transcript, which eventually qualifies.
        // Manual send (submitCurrentUtterance) is never gated by this.
        guard LiveVoiceHeuristics.shouldAutoFinalizeUtterance(transcript) else {
            finalizeTask?.cancel()
            return
        }
        finalizeTask?.cancel()
        finalizeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.35))
            await MainActor.run {
                guard let self,
                      !self.isMuted,
                      self.activeUserPartial == transcript,
                      self.state == .userSpeaking
                else { return }
                self.submitCurrentUtterance()
            }
        }
    }

    private func finalizeCurrentUtterance() async {
        // A manual submitCurrentUtterance tap can race the auto-finalize task.
        // Both run on the @MainActor, but the body awaits, so without this guard
        // a second entrant could run the body twice (e.g. beginListening()
        // mid-send). Reset on every exit path below.
        guard !isFinalizing else { return }
        isFinalizing = true
        defer { isFinalizing = false }

        finalizeTask?.cancel()
        // Never send a partial that the user has already abandoned by ending
        // the call. (Mute/discard route through here too via manual send, where
        // sending the captured text is the desired behavior.)
        guard state != .ended else { return }
        let spokenText = voice.stopRecording() ?? activeUserPartial
        let clean = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        activeUserPartial = ""

        guard !clean.isEmpty else {
            await beginListening()
            return
        }

        if let intent = CaptureIntentDetector.detect(in: clean) {
            await captureAndSendUserTurn(originalText: clean, intent: intent)
        } else {
            await sendUserTurn(clean, attachments: [])
        }
    }

    private func captureAndSendUserTurn(originalText: String, intent: CaptureIntent) async {
        guard let captureMediaHandler else {
            await sendUserTurn(originalText, attachments: [])
            return
        }

        state = .capturingMedia
        do {
            let threadId = activeConversationID.flatMap { workspace.conversation(id: $0)?.threadId }
            let attachments = try await captureMediaHandler(intent, activeConversationID, threadId)
            guard !attachments.isEmpty else {
                await beginListening()
                return
            }
            let prompt = intent.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? originalText : intent.prompt
            await sendUserTurn(prompt, attachments: attachments)
        } catch is CancellationError {
            await beginListening()
        } catch {
            await recoverFromCaptureFailure(error)
        }
    }

    private func recoverFromCaptureFailure(_ error: Error) async {
        failureMessage = error.localizedDescription
        activeAgentText = ""
        activeUserPartial = ""
        stopSpeaking()

        guard !isMuted else {
            state = .listening
            return
        }

        await voice.startRecording()
        if !voice.isRecording {
            _ = await voice.beginCallAudio()
            await voice.startRecording()
        }

        state = .listening
        if !voice.isRecording, !voice.status.isEmpty {
            let status = voice.status
            failureMessage = "\(error.localizedDescription) \(status)"
        }
    }

    private func sendUserTurn(_ text: String, attachments: [ChatAttachment]) async {
        if client.isDisconnected {
            let conversation = queueUserTurn(text, attachments: attachments)
            activeConversationID = conversation.id
            onConversationStarted(conversation.id)
            failureMessage = "Saved locally. Reconnect to send."
            state = .failed
            return
        }

        guard let conversation = appendUserTurn(text, attachments: attachments) else {
            failureMessage = "Could not create call transcript."
            state = .failed
            return
        }

        activeConversationID = conversation.id
        onConversationStarted(conversation.id)
        let messageID = conversation.messages.last?.id
        let payload = messageTextForAgent(text, attachments: attachments)
        let requestAttachments = chatRequestAttachments(for: attachments)

        state = .sendingTurn
        activeAgentText = ""
        workspace.beginAgentResponse(in: conversation.id)

        activeSendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.client.sendStreaming(
                    payload,
                    threadId: conversation.threadId,
                    conversationId: conversation.id,
                    attachments: requestAttachments,
                    projectPath: conversation.projectPath
                ) { event in
                    await self.handleStreamEvent(event, conversationId: conversation.id)
                }
                self.workspace.apply(result, to: conversation.id)
                self.syncLiveActivity(detailOverride: "Reply ready")
                self.speak(result.text)
            } catch {
                if self.isCancellation(error) {
                    self.workspace.cancelActiveResponse(in: conversation.id)
                    self.failureMessage = nil
                    self.activeAgentText = ""
                    if self.state != .ended {
                        await self.beginListening()
                    }
                    return
                }
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

    private func appendUserTurn(_ text: String, attachments: [ChatAttachment]) -> Conversation? {
        if let activeConversationID,
           let existing = workspace.appendUserMessage(text, to: activeConversationID, attachments: attachments) {
            return existing
        }
        return workspace.createConversation(
            firstMessage: text,
            attachments: attachments,
            projectPath: initialProject?.path,
            projectName: initialProject?.name
        )
    }

    private func queueUserTurn(_ text: String, attachments: [ChatAttachment]) -> Conversation {
        if let activeConversationID,
           let existing = workspace.queueUserMessage(text, to: activeConversationID, attachments: attachments) {
            return existing
        }
        return workspace.queueConversation(
            firstMessage: text,
            attachments: attachments,
            projectPath: initialProject?.path,
            projectName: initialProject?.name
        )
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
                narrateReasoning(text)
            }
        case "tool":
            if let tool = event.tool {
                state = .agentThinking
                workspace.appendActivity("tool: \(tool.name)", to: conversationId)
            }
        case "approval":
            if let approval = event.approval {
                _ = voice.stopRecording()
                stopSpeaking()
                soundscape.play(.question)
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
        // The agent's final answer is ready: interrupt any reasoning narration,
        // chime, then read the final answer. Chime regardless of whether we end
        // up speaking it (output may be off or the text trims to empty).
        stopSpeaking()
        soundscape.play(.replyReady)

        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            Task { await beginListening() }
            return
        }

        // Output toggle off OR a spoken-reply mode that produces nothing both
        // mean "don't speak" — go back to listening like the empty path. The
        // FULL reply is already recorded in chat via workspace.apply(...).
        guard isOutputEnabled else {
            Task { await beginListening() }
            return
        }

        let mode = LiveVoiceHeuristics.SpokenReplyMode.current
        guard let spoken = LiveVoiceHeuristics.spokenText(from: clean, mode: mode) else {
            Task { await beginListening() }
            return
        }

        state = .agentSpeaking
        syncLiveActivity(detailOverride: "Replying")
        soundscape.setAmbient(.none)   // duck the working bed for the spoken voice

        speakTask = Task { [weak self] in
            guard let self else { return }
            await self.vocalize(spoken)
            if Task.isCancelled { return }
            await self.advanceAfterSpeaking()
        }
    }

    /// Read an intermediate reasoning/activity line aloud while the agent works,
    /// so you hear it thinking. Drops lines that arrive while one is still being
    /// spoken (stay live, do not back up). The final reply interrupts this via
    /// `speak()`. Only runs during the working window, never over the reply.
    private func narrateReasoning(_ text: String) {
        guard isOutputEnabled, !isVocalizing else { return }
        guard state == .agentThinking || state == .sendingTurn else { return }
        // Only read natural-language thinking aloud. Tool/shell commands, code,
        // and paths are dropped so the agent does not read bash at you.
        guard let prose = LiveVoiceHeuristics.narratableThinking(from: text) else { return }

        isVocalizing = true
        narrateTask = Task { [weak self] in
            guard let self else { return }
            await self.vocalize(prose)
            self.isVocalizing = false
        }
    }

    /// Speak `text` once via the preferred voice: Gemini when a key is configured,
    /// always falling back to Apple's on-device voice on any failure.
    private func vocalize(_ text: String) async {
        if gemini.isConfigured {
            do {
                try await gemini.play(text)
            } catch {
                if Task.isCancelled { return }
                log.error("gemini tts failed, using apple voice: \(error.localizedDescription, privacy: .public)")
                await apple.play(text)
            }
        } else {
            await apple.play(text)
        }
    }

    /// Stop any in-flight speech (final reply and reasoning narration) and cancel
    /// their tasks.
    private func stopSpeaking() {
        speakTask?.cancel()
        speakTask = nil
        narrateTask?.cancel()
        narrateTask = nil
        isVocalizing = false
        apple.stop()
        gemini.stop()
    }

    /// After a reply finishes speaking, return to listening unless the call has
    /// moved on (ended, asking a question, or failed).
    private func advanceAfterSpeaking() async {
        guard state != .ended, state != .needsAnswer, state != .failed else { return }
        await beginListening()
    }

    /// Drive the ambient bed from each state change: a calm waiting pad while
    /// listening, a working pad while the agent runs (the whole send/think/stream
    /// window is grouped so the pad does not flutter as streaming flips state).
    /// `speak()` ducks it to silence for the spoken reply. One-shot earcons fire
    /// from semantic turn boundaries (see sendUserTurn/speak/approval), not here,
    /// except the error tone, which only fires on a real transition into failure.
    private func updateSoundscape(from old: CallState) {
        switch state {
        case .listening, .userSpeaking, .needsAnswer:
            soundscape.setAmbient(.waiting)
        case .sendingTurn, .capturingMedia, .agentThinking, .agentSpeaking:
            soundscape.setAmbient(.working)
        case .connecting, .failed, .ended:
            soundscape.setAmbient(.none)
        }

        if state == .failed && old != .failed {
            soundscape.play(.error)
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

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        guard let agentError = error as? AgentClientError else { return false }
        if case .cancelled = agentError {
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
        case .capturingMedia:
            return "Taking a photo"
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
