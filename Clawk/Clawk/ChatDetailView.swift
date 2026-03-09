import SwiftUI

// MARK: - Chat Detail View (Full-page chat, pushed from ChatListView)

struct ChatDetailView: View {
    @EnvironmentObject var gateway: GatewayConnection
    @EnvironmentObject var dashboardAPI: DashboardAPIClient
    let session: GatewaySession?

    @State private var messageText = ""
    @State private var showingDebugLog = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            GatewayStatusBar(connection: gateway)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(gateway.messages) { message in
                            ChatMessageView(
                                message: message,
                                agentIdentity: gateway.agentIdentity,
                                isCurrentUser: message.role == "user"
                            )
                            .id(message.id)
                        }

                        // Waiting for response indicator + status
                        if gateway.isWaitingForResponse && gateway.thinkingSteps.isEmpty {
                            VStack(spacing: 4) {
                                TypingIndicator()
                                if let status = gateway.chatStatus {
                                    Text(status)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 44)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .id("typing")
                        }

                        // Chat error display
                        if let error = gateway.chatError {
                            ChatErrorView(error: error, onRetry: {
                                if let lastUserMsg = gateway.messages.last(where: { $0.role == "user" }) {
                                    gateway.chatError = nil
                                    gateway.sendMessage(lastUserMsg.content)
                                }
                            })
                            .id("error")
                        }

                        if !gateway.thinkingSteps.isEmpty {
                            ThinkingStepsView(steps: gateway.thinkingSteps)
                                .id("thinking")
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: gateway.messages.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: gateway.thinkingSteps.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: gateway.chatError) {
                    scrollToBottom(proxy)
                }
            }

            MessageInputBar(
                text: $messageText,
                isEnabled: gateway.isConnected,
                onSend: sendMessage
            )
            .focused($isInputFocused)
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Button(action: { showingDebugLog = true }) {
                        Image(systemName: "ant.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ConnectionIndicator(isConnected: gateway.isConnected)
                }
            }
        }
        .sheet(isPresented: $showingDebugLog) {
            NavigationView {
                GatewayDebugLogView(gateway: gateway)
            }
        }
        .onAppear {
            if let session = session {
                gateway.switchToSession(session)
                loadSessionHistory(sessionId: session.id)
            } else {
                gateway.startNewChat()
            }
        }
    }

    private var navTitle: String {
        if let session = session {
            return session.agentName ?? session.agentId ?? "Chat"
        }
        return gateway.agentIdentity?.name ?? "New Chat"
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        gateway.sendMessage(text)
        messageText = ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if !gateway.thinkingSteps.isEmpty {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if gateway.chatError != nil {
                proxy.scrollTo("error", anchor: .bottom)
            } else if gateway.isWaitingForResponse {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let lastMessage = gateway.messages.last {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    private func loadSessionHistory(sessionId: String) {
        Task {
            do {
                let messages = try await dashboardAPI.fetchSessionMessages(sessionId: sessionId)
                let recent = messages.count > 100 ? Array(messages.suffix(100)) : messages
                gateway.loadMessages(from: recent)
            } catch {
                print("[Chat] Failed to load session history: \(error)")
            }
        }
    }
}
