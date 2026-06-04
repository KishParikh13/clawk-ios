import SwiftUI
import SwiftData

// MARK: - Gateway Chat View
/// Native chat interface using direct OpenClaw Gateway WebSocket
struct GatewayChatView: View {
    @StateObject private var gateway = GatewayConnection()
    @State private var messageText = ""
    @State private var showingSettings = false
    @State private var scrollToBottom = false
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Connection status
                GatewayStatusBar(connection: gateway)
                
                // Messages list
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
                            
                            // Thinking steps (show while processing)
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
                    .onAppear {
                        // Auto-scroll to bottom on appear
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToBottom(proxy)
                        }
                    }
                }
                
                // Input area
                MessageInputBar(
                    text: $messageText,
                    isEnabled: gateway.isConnected,
                    onSend: sendMessage
                )
                .focused($isInputFocused)
            }
            .navigationTitle(gateway.agentIdentity?.name ?? "Chat")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    ConnectionIndicator(isConnected: gateway.isConnected)
                }
            }
            .sheet(isPresented: $showingSettings) {
                GatewaySettingsView(gateway: gateway)
            }
            .onAppear {
                if !gateway.isConnected && !gateway.isConnecting {
                    gateway.connect()
                }
            }
            .onDisappear {
                // Don't disconnect - keep connection for background
            }
        }
    }
    
    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        gateway.sendMessage(text)
        messageText = ""
    }
    
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let lastMessage = gateway.messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        } else if !gateway.thinkingSteps.isEmpty {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("thinking", anchor: .bottom)
            }
        }
    }
}

// MARK: - Gateway Status Bar
struct GatewayStatusBar: View {
    @ObservedObject var connection: GatewayConnection
    
    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if let error = connection.connectionError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
            
            if !connection.isConnected {
                Button("Reconnect") {
                    connection.connect()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }
    
    private var statusColor: Color {
        if connection.isConnected { return .green }
        if connection.isConnecting { return .orange }
        return .red
    }
    
    private var statusText: String {
        if connection.isConnected { return "Live" }
        if connection.isConnecting { return "Connecting..." }
        return "Offline"
    }
}

// MARK: - Connection Indicator
struct ConnectionIndicator: View {
    let isConnected: Bool
    
    var body: some View {
        Circle()
            .fill(isConnected ? Color.green : Color.red)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 2)
            )
    }
}

// MARK: - Message Input Bar
struct MessageInputBar: View {
    @Binding var text: String
    let isEnabled: Bool
    let onSend: () -> Void
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask KishOS", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .disabled(!isEnabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .overlay(Capsule().stroke(Color(.separator).opacity(0.35)))
            
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(canSend ? Color(.label) : Color(.systemGray4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private var canSend: Bool {
        isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Gateway Settings View
struct GatewaySettingsView: View {
    @ObservedObject var gateway: GatewayConnection
    @Environment(\.dismiss) private var dismiss
    
    @State private var host = "localhost"
    @State private var port = "18789"
    @State private var showClearConfirmation = false
    
    var body: some View {
        NavigationView {
            Form {
                Section("Gateway Connection") {
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    
                    Button(gateway.isConnected ? "Disconnect" : "Connect") {
                        if gateway.isConnected {
                            gateway.disconnect()
                        } else {
                            // Reinitialize with new settings
                            dismiss()
                        }
                    }
                    .foregroundColor(gateway.isConnected ? .red : .blue)
                }
                
                Section("Agent Identity") {
                    if let identity = gateway.agentIdentity {
                        HStack {
                            Text("Name")
                            Spacer()
                            Text(identity.name)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("Creature")
                            Spacer()
                            Text(identity.creature)
                                .foregroundColor(.secondary)
                        }
                        
                        if let vibe = identity.vibe {
                            HStack {
                                Text("Vibe")
                                Spacer()
                                Text(vibe)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            Text("Emoji")
                            Spacer()
                            Text(identity.emoji)
                        }
                    } else {
                        Text("No identity synced yet")
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("Chat History") {
                    Button("Clear Messages") {
                        showClearConfirmation = true
                    }
                    .foregroundColor(.red)
                    
                    Text("\(gateway.messages.count) messages")
                        .foregroundColor(.secondary)
                }
                
                Section("Debug") {
                    Text("Device Token: \(gateway.publicDeviceToken.prefix(8))...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Gateway Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Clear Messages?", isPresented: $showClearConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    gateway.clearMessages()
                }
            } message: {
                Text("This will delete all messages in the current session.")
            }
        }
    }
}

// MARK: - Preview
struct GatewayChatView_Previews: PreviewProvider {
    static var previews: some View {
        GatewayChatView()
    }
}
