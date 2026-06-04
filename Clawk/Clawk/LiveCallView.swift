import SwiftUI

struct LiveCallView: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var workspace: KishOSWorkspace
    @ObservedObject var voice: VoiceController
    @ObservedObject var audio: AudioRouteMonitor

    @StateObject private var controller: LiveCallController
    let onDismiss: () -> Void

    init(
        client: KishAgentClient,
        workspace: KishOSWorkspace,
        voice: VoiceController,
        audio: AudioRouteMonitor,
        initialConversationID: UUID?,
        onConversationStarted: @escaping (UUID) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.client = client
        self.workspace = workspace
        self.voice = voice
        self.audio = audio
        self.onDismiss = onDismiss
        _controller = StateObject(
            wrappedValue: LiveCallController(
                client: client,
                workspace: workspace,
                voice: voice,
                initialConversationID: initialConversationID,
                onConversationStarted: onConversationStarted
            )
        )
    }

    private var conversation: Conversation? {
        controller.activeConversationID.flatMap { workspace.conversation(id: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            LiveCallHeader(
                title: conversation?.title ?? "KishOS",
                state: controller.state,
                elapsedSeconds: controller.elapsedSeconds,
                route: audio.statusLabel,
                miniStatus: client.miniStatus,
                chatStatus: client.chatStatus,
                onClose: endAndDismiss
            )

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let conversation {
                            ForEach(conversation.messages) { message in
                                LiveCallMessageRow(message: message)
                                    .id(message.id)
                            }
                        }

                        if !controller.activeUserPartial.isEmpty {
                            LiveCallPartialRow(title: "You", text: controller.activeUserPartial)
                                .id("active-user")
                        }

                        if shouldShowThinkingRow {
                            LiveCallThinkingRow()
                                .id("thinking")
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
                .onChange(of: conversation?.messages.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: controller.activeUserPartial) {
                    scrollToBottom(proxy)
                }
                .onChange(of: controller.activeAgentText) {
                    scrollToBottom(proxy)
                }
            }

            if let approval = conversation?.approvals.first {
                LiveCallQuestionCard(
                    approval: approval,
                    onAnswer: { controller.answer(approval, with: $0) },
                    onCancel: { controller.cancel(approval) }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            } else if let failure = controller.failureMessage {
                LiveCallFailureBar(message: failure) {
                    Task { await controller.start() }
                }
            }

            LiveCallControls(
                state: controller.state,
                isMuted: controller.isMuted,
                isOutputEnabled: controller.isOutputEnabled,
                canSubmitSpeech: !controller.activeUserPartial.isEmpty,
                onMute: controller.toggleMute,
                onOutput: controller.toggleOutput,
                onSubmitSpeech: controller.submitCurrentUtterance,
                onInterrupt: controller.interruptAndListen,
                onEnd: endAndDismiss
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            audio.start()
            await audio.activatePreferredHandsFreeRoute()
            await controller.start()
        }
        .onChange(of: voice.transcript) { _, transcript in
            controller.handleTranscriptChange(transcript)
        }
        .onChange(of: voice.isRecording) { _, isRecording in
            audio.refresh(isRecording: isRecording)
        }
    }

    private func endAndDismiss() {
        controller.endCall()
        onDismiss()
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            if !controller.activeUserPartial.isEmpty {
                proxy.scrollTo("active-user", anchor: .bottom)
            } else if let last = conversation?.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            } else if shouldShowThinkingRow {
                proxy.scrollTo("thinking", anchor: .bottom)
            }
        }
    }

    private var shouldShowThinkingRow: Bool {
        guard controller.state == .agentThinking || controller.state == .sendingTurn else { return false }
        let activeAssistantMessage = conversation?.messages.last {
            $0.sender == .agent && $0.deliveryState == .sending
        }
        let activeText = activeAssistantMessage?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return activeText.isEmpty
    }
}

private struct LiveCallHeader: View {
    let title: String
    let state: LiveCallController.CallState
    let elapsedSeconds: Int
    let route: String
    let miniStatus: String
    let chatStatus: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    LiveCallStatusDot(value: state.label)
                    Text(state.label)
                    Text(Self.formatElapsed(elapsedSeconds))
                    Text(route)
                    ForEach(connectionLabels, id: \.self) { label in
                        Text(label)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            .accessibilityLabel("Close call")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
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

private struct LiveCallStatusDot: View {
    let value: String

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
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

private struct LiveCallMessageRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 5) {
            Text(message.sender == .user ? "You" : "KishOS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(message.text.isEmpty ? "Working" : message.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, message.sender == .user ? 13 : 0)
                .padding(.vertical, message.sender == .user ? 10 : 0)
                .background(message.sender == .user ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 17))
                .foregroundStyle(message.sender == .user ? .white : .primary)
        }
        .frame(maxWidth: .infinity, alignment: message.sender == .user ? .trailing : .leading)
    }
}

private struct LiveCallPartialRow: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: title == "You" ? .trailing : .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .foregroundStyle(title == "You" ? .white : .primary)
                .padding(.horizontal, title == "You" ? 13 : 0)
                .padding(.vertical, title == "You" ? 10 : 0)
                .background(title == "You" ? Color.accentColor.opacity(0.82) : Color.clear, in: RoundedRectangle(cornerRadius: 17))
                .opacity(0.78)
        }
        .frame(maxWidth: .infinity, alignment: title == "You" ? .trailing : .leading)
    }
}

private struct LiveCallThinkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Working")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct LiveCallQuestionCard: View {
    let approval: ApprovalRequest
    let onAnswer: (String) -> Void
    let onCancel: () -> Void

    @State private var otherAnswer = ""

    private var question: ApprovalQuestion {
        approval.questions.first ?? ApprovalQuestion(header: "Question", question: approval.summary, multiSelect: false, options: [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.question)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)

            ForEach(question.options, id: \.label) { option in
                Button {
                    onAnswer(option.label)
                } label: {
                    HStack {
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
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                TextField("Other", text: $otherAnswer, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 10))

                Button {
                    onAnswer(otherAnswer)
                    otherAnswer = ""
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(otherAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct LiveCallFailureBar: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

private struct LiveCallControls: View {
    let state: LiveCallController.CallState
    let isMuted: Bool
    let isOutputEnabled: Bool
    let canSubmitSpeech: Bool
    let onMute: () -> Void
    let onOutput: () -> Void
    let onSubmitSpeech: () -> Void
    let onInterrupt: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            CallControlButton(
                systemName: isMuted ? "mic.slash.fill" : "mic.fill",
                title: "Mute",
                isActive: isMuted,
                action: onMute
            )

            CallControlButton(
                systemName: isOutputEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                title: "Audio",
                isActive: !isOutputEnabled,
                action: onOutput
            )

            if state == .userSpeaking || canSubmitSpeech {
                CallControlButton(
                    systemName: "arrow.up.circle.fill",
                    title: "Send",
                    isProminent: true,
                    action: onSubmitSpeech
                )
            } else {
                CallControlButton(
                    systemName: "hand.raised.fill",
                    title: "Interrupt",
                    action: onInterrupt
                )
            }

            CallControlButton(
                systemName: "phone.down.fill",
                title: "End",
                isDestructive: true,
                action: onEnd
            )
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CallControlButton: View {
    let systemName: String
    let title: String
    var isActive = false
    var isProminent = false
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(background, in: Circle())
                    .foregroundStyle(foreground)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var background: Color {
        if isDestructive { return .red }
        if isProminent { return .accentColor }
        if isActive { return .orange.opacity(0.18) }
        return Color(uiColor: .secondarySystemBackground)
    }

    private var foreground: Color {
        if isDestructive || isProminent { return .white }
        return .primary
    }
}
