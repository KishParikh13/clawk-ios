import SwiftUI

// MARK: - Session Chat View

struct SessionChatView: View {
    let session: DashboardSession
    @EnvironmentObject var store: MessageStore
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [SessionMessage] = []
    @State private var isLoading = true
    @State private var showingCopiedAlert = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Session header
                SessionHeader(session: session)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                
                // Messages list
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                        }
                    }
                    .padding()
                }
                
                // Action buttons
                HStack(spacing: 16) {
                    Button(action: { copySessionId() }) {
                        Label("Copy ID", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: { refreshMessages() }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("Session Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                refreshMessages()
            }
            .alert("Session ID Copied", isPresented: $showingCopiedAlert) {
                Button("OK", role: .cancel) {}
            }
        }
    }
    
    private func refreshMessages() {
        isLoading = true
        store.fetchSessionMessages(sessionId: session.id) { fetchedMessages in
            messages = fetchedMessages
            isLoading = false
            // Haptic feedback on refresh
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }
    
    private func copySessionId() {
        UIPasteboard.general.string = session.id
        showingCopiedAlert = true
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
}

// MARK: - Session Header

struct SessionHeader: View {
    let session: DashboardSession
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.agentEmoji ?? "🤖")
                    .font(.largeTitle)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.agentName ?? session.agentId ?? "Unknown Agent")
                        .font(.headline)
                    
                    if let model = session.model {
                        Text(model)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                StatusBadge(status: session.status ?? "idle")
            }
            
            HStack(spacing: 16) {
                StatItem(icon: "message.fill", value: "\(session.messageCount ?? 0)")
                StatItem(icon: "dollarsign.circle.fill", value: String(format: "%.3f", session.totalCost ?? 0))
                if let tokens = session.tokensUsed?.input ?? session.tokensUsed?.output {
                    StatItem(icon: "cylinder.split.1x2", value: formatTokens(tokens))
                }
            }
            
            if let path = session.projectPath {
                Label(path, systemImage: "folder.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            if let startedAt = session.startedAt {
                Label("Started: \(timeAgo(from: startedAt))", systemImage: "clock")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
    
    private func timeAgo(from dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: dateString) else { return dateString }
        let relativeFormatter = RelativeDateTimeFormatter()
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

struct StatItem: View {
    let icon: String
    let value: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

struct StatusBadge: View {
    let status: String
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(status)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .cornerRadius(8)
    }
    
    private var color: Color {
        switch status {
        case "active": return .green
        case "idle": return .orange
        case "completed", "done": return .gray
        case "error", "failed": return .red
        default: return .blue
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: SessionMessage
    
    var body: some View {
        HStack {
            if isUser {
                Spacer()
            }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .padding(12)
                    .background(isUser ? Color.blue : Color(.secondarySystemBackground))
                    .foregroundColor(isUser ? .white : .primary)
                    .cornerRadius(16)
                
                HStack(spacing: 8) {
                    Text(message.role.capitalized)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if let cost = message.cost, cost > 0 {
                        Text("$\(String(format: "%.4f", cost))")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    
                    if let timestamp = message.timestamp {
                        Text(formatTime(timestamp))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Tool calls indicator
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    HStack {
                        Image(systemName: "wrench.fill")
                            .font(.caption2)
                        Text("\(toolCalls.count) tool call\(toolCalls.count == 1 ? "" : "s")")
                            .font(.caption2)
                    }
                    .foregroundColor(.orange)
                    .padding(.top, 2)
                }
            }
            
            if !isUser {
                Spacer()
            }
        }
    }
    
    private var isUser: Bool {
        message.role == "user"
    }
    
    private func formatTime(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        return timeFormatter.string(from: date)
    }
}

// MARK: - Enhanced Session Row (for Sessions Tab)

struct EnhancedSessionRow: View {
    let session: DashboardSession
    @State private var showingChat = false
    @State private var showingCopiedAlert = false
    
    var body: some View {
        Button(action: { showingChat = true }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(session.agentEmoji ?? "🤖")
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.agentName ?? session.agentId ?? "Unknown")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        if let model = session.model {
                            Text(model)
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    
                    Spacer()
                    
                    StatusDot(status: session.status ?? "idle")
                }
                
                HStack(spacing: 12) {
                    if let cost = session.totalCost, cost > 0 {
                        Label("$\(String(format: "%.3f", cost))", systemImage: "dollarsign.circle")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    
                    if let tokens = session.tokensUsed?.input ?? session.tokensUsed?.output {
                        Label(formatTokens(tokens), systemImage: "cylinder.split.1x2")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let count = session.messageCount, count > 0 {
                        Label("\(count)", systemImage: "message")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let updatedAt = session.updatedAt {
                        Label(timeAgo(from: updatedAt), systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let path = session.projectPath {
                    Text(path)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $showingChat) {
            SessionChatView(session: session)
                .environmentObject(MessageStore())
        }
        .contextMenu {
            Button(action: { copySessionId() }) {
                Label("Copy Session ID", systemImage: "doc.on.doc")
            }
            
            if let agentId = session.agentId {
                Button(action: { /* Ping agent action */ }) {
                    Label("Ping \(agentId)", systemImage: "waveform")
                }
            }
            
            if let path = session.projectPath {
                Button(action: { UIPasteboard.general.string = path }) {
                    Label("Copy Project Path", systemImage: "folder")
                }
            }
        }
        .alert("Copied!", isPresented: $showingCopiedAlert) {
            Button("OK", role: .cancel) {}
        }
    }
    
    private func copySessionId() {
        UIPasteboard.general.string = session.id
        showingCopiedAlert = true
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
    
    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
    
    private func timeAgo(from dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: dateString) else { return dateString }
        let relativeFormatter = RelativeDateTimeFormatter()
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Preview

struct SessionChatView_Previews: PreviewProvider {
    static var previews: some View {
        SessionChatView(session: DashboardSession(
            id: "test-session-id",
            agentId: "engineer",
            agentName: "Engineer",
            agentEmoji: "⚙️",
            agentColor: "#FCD34D",
            model: "claude-sonnet-4-6",
            messageCount: 15,
            totalCost: 0.456,
            tokensUsed: TokenUsage(input: 5000, output: 2000, cached: 1000),
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)),
            projectPath: "/Users/kishparikh/Projects/test",
            source: "codex",
            status: "active",
            folderTrail: nil
        ))
        .environmentObject(MessageStore())
    }
}
