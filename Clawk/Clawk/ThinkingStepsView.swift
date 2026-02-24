import SwiftUI

// MARK: - Thinking Steps View
/// Displays real-time thinking steps and tool calls during agent processing
struct ThinkingStepsView: View {
    let steps: [ThinkingStep]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(steps) { step in
                ThinkingStepRow(step: step)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ThinkingStepRow: View {
    let step: ThinkingStep
    @State private var isExpanded = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Icon based on type
            ThinkingStepIcon(step: step)
                .frame(width: 20, height: 20)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.displayText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(isExpanded ? nil : 1)
                    
                    Spacer()
                    
                    // Duration badge for completed tool calls
                    if let duration = step.durationMs {
                        Text("\(duration)ms")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    // Status indicator
                    if let status = step.status {
                        StatusDot(status: status)
                    }
                }
                
                // Expandable details
                if isExpanded, step.type == .toolCall || step.type == .toolResult {
                    if let toolName = step.toolName {
                        Text("Tool: \(toolName)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }
}

struct ThinkingStepIcon: View {
    let step: ThinkingStep
    
    var body: some View {
        Group {
            switch step.type {
            case .thinking:
                // Animated dots for thinking
                ThinkingDots()
            case .toolCall:
                Image(systemName: "wrench.fill")
                    .font(.caption)
                    .foregroundColor(.blue)
            case .toolResult:
                Image(systemName: statusIcon)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
        }
    }
    
    private var statusIcon: String {
        switch step.status {
        case "ok", "success":
            return "checkmark.circle.fill"
        case "error", "failed":
            return "xmark.circle.fill"
        default:
            return "info.circle.fill"
        }
    }
    
    private var statusColor: Color {
        switch step.status {
        case "ok", "success":
            return .green
        case "error", "failed":
            return .red
        default:
            return .orange
        }
    }
}

// MARK: - Animated Thinking Dots
struct ThinkingDots: View {
    @State private var animationPhase = 0
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.blue.opacity(opacity(for: index)))
                    .frame(width: 4, height: 4)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                animationPhase = 3
            }
        }
    }
    
    private func opacity(for index: Int) -> Double {
        let base = Double(index) * 0.3
        let animated = Double(animationPhase) * 0.3
        return 0.3 + min(0.7, max(0, animated - base))
    }
}

// MARK: - Status Dot
struct StatusDot: View {
    let status: String
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
    
    private var color: Color {
        switch status {
        case "ok", "success": return .green
        case "error", "failed": return .red
        case "pending", "running": return .orange
        default: return .gray
        }
    }
}

// MARK: - Chat Message with Thinking
struct ChatMessageView: View {
    let message: GatewayMessage
    let agentIdentity: AgentIdentity?
    let isCurrentUser: Bool
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !isCurrentUser {
                // Agent avatar
                AgentAvatar(identity: agentIdentity)
            }
            
            VStack(alignment: isCurrentUser ? .trailing : .leading, spacing: 4) {
                // Sender name
                if !isCurrentUser, let name = agentIdentity?.name {
                    Text(name)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                }
                
                // Message bubble
                MessageBubble(
                    content: message.content,
                    isUser: isCurrentUser,
                    color: agentIdentity?.color ?? "#6B7280"
                )
                
                // Thinking (only for assistant messages)
                if !isCurrentUser, let thinking = message.thinking {
                    DisclosureGroup("Thinking") {
                        Text(thinking)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(8)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                }
                
                // Tool calls
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(toolCalls, id: \.id) { toolCall in
                            ToolCallBadge(toolCall: toolCall)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                
                // Timestamp
                Text(formatTime(message.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
            }
            
            if isCurrentUser {
                Spacer()
            }
        }
        .padding(.horizontal, 8)
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Agent Avatar
struct AgentAvatar: View {
    let identity: AgentIdentity?
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: identity?.color ?? "#6B7280") ?? .gray)
                .frame(width: 32, height: 32)
            
            Text(identity?.emoji ?? "🤖")
                .font(.title3)
        }
    }
}

// MARK: - Message Bubble
struct MessageBubble: View {
    let content: String
    let isUser: Bool
    let color: String
    
    var body: some View {
        Text(content)
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .cornerRadius(16)
            .cornerRadius(isUser ? 16 : 4, corners: isUser ? [.topLeft, .topRight, .bottomLeft] : [.topRight, .bottomLeft, .bottomRight])
    }
    
    private var backgroundColor: Color {
        if isUser {
            return Color(hex: color) ?? .blue
        } else {
            return Color(.secondarySystemBackground)
        }
    }
    
    private var foregroundColor: Color {
        isUser ? .white : .primary
    }
}

// MARK: - Tool Call Badge
struct ToolCallBadge: View {
    let toolCall: ToolCall
    @State private var showDetails = false
    
    var body: some View {
        Button(action: { showDetails.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "wrench.fill")
                    .font(.caption2)
                Text(toolCall.name)
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.1))
            .foregroundColor(.blue)
            .cornerRadius(4)
        }
        .sheet(isPresented: $showDetails) {
            ToolCallDetailView(toolCall: toolCall)
        }
    }
}

// MARK: - Tool Call Detail View
struct ToolCallDetailView: View {
    let toolCall: ToolCall
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                Section("Tool") {
                    Text(toolCall.name)
                        .font(.headline)
                }
                
                Section("Arguments") {
                    if toolCall.arguments.isEmpty {
                        Text("No arguments")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(toolCall.arguments.keys.sorted()), id: \.self) { key in
                            HStack {
                                Text(key)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                if let value = toolCall.arguments[key] as? String {
                                    Text(value)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                
                Section("Timestamp") {
                    Text(toolCall.timestamp, style: .date)
                    Text(toolCall.timestamp, style: .time)
                }
            }
            .navigationTitle("Tool Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Corner Radius Extension
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Thinking Step Extensions
extension ThinkingStep {
    var displayText: String {
        switch type {
        case .thinking:
            return content
        case .toolCall:
            if let toolName = toolName {
                return "Using \(toolName)..."
            }
            return content
        case .toolResult:
            if let toolName = toolName {
                return "\(toolName) completed"
            }
            return content
        }
    }
}

// MARK: - Preview
struct ThinkingStepsView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            ThinkingStepsView(steps: [
                ThinkingStep(id: "1", content: "Considering options...", timestamp: Date(), type: .thinking),
                ThinkingStep(id: "2", content: "Using web_search...", timestamp: Date(), type: .toolCall, toolName: "web_search"),
                ThinkingStep(id: "3", content: "web_search completed", timestamp: Date(), type: .toolResult, toolName: "web_search", status: "ok", durationMs: 450)
            ])
            
            Divider()
            
            ChatMessageView(
                message: GatewayMessage(
                    id: "1",
                    role: "assistant",
                    content: "I found some interesting results for you!",
                    timestamp: Date(),
                    thinking: "Let me search for the latest information..."
                ),
                agentIdentity: AgentIdentity(name: "Claude", creature: "AI", vibe: "Helpful", emoji: "🧠", color: "#A78BFA"),
                isCurrentUser: false
            )
        }
        .padding()
    }
}
