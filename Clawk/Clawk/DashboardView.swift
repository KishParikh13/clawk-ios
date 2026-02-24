import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var store: MessageStore
    @State private var selectedTab = 0
    @State private var isRefreshing = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Connection status bar
                ConnectionStatusBar()
                    .environmentObject(store)
                
                // Tab selector
                Picker("View", selection: $selectedTab) {
                    Text("Overview").tag(0)
                    Text("Agents").tag(1)
                    Text("Sessions").tag(2)
                    Text("Cron").tag(3)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                ScrollView {
                    VStack(spacing: 16) {
                        switch selectedTab {
                        case 0:
                            OverviewTab()
                                .environmentObject(store)
                        case 1:
                            AgentsTab()
                                .environmentObject(store)
                        case 2:
                            SessionsTab()
                                .environmentObject(store)
                        case 3:
                            CronTab()
                                .environmentObject(store)
                        default:
                            OverviewTab()
                                .environmentObject(store)
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await refreshData()
                }
            }
            .navigationTitle("Dashboard")
        }
    }
    
    private func refreshData() async {
        isRefreshing = true
        
        // Haptic feedback on refresh
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        store.manualRefresh()
        
        // Small delay to show refresh indicator
        try? await Task.sleep(nanoseconds: 500_000_000)
        isRefreshing = false
    }
}

// MARK: - Share Button

struct ShareButton: View {
    let store: MessageStore
    @State private var showingShareSheet = false
    
    var body: some View {
        Button(action: { showingShareSheet = true }) {
            Image(systemName: "square.and.arrow.up")
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: [generateShareText()])
        }
    }
    
    private func generateShareText() -> String {
        var text = "OpenClaw Dashboard Summary\n\n"
        
        if let agents = store.dashboardSnapshot?.agents {
            text += "Agents: \(agents.count)\n"
        }
        
        if let sessions = store.dashboardSnapshot?.sessions {
            let active = sessions.filter { $0.status == "active" }.count
            text += "Sessions: \(sessions.count) (Active: \(active))\n"
        }
        
        if let summary = store.openclawStatus?.summary {
            text += "Cron Jobs: \(summary.totalCronJobs)\n"
        }
        
        if let cost = store.dashboardSnapshot?.totalCost {
            text += "Total Cost: $\(String(format: "%.2f", cost))\n"
        }
        
        if let lastUpdate = store.lastDashboardUpdate {
            let formatter = RelativeDateTimeFormatter()
            text += "\nLast updated: \(formatter.localizedString(for: lastUpdate, relativeTo: Date()))"
        }
        
        return text
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Connection Status Bar

struct ConnectionStatusBar: View {
    @EnvironmentObject var store: MessageStore
    
    var body: some View {
        HStack(spacing: 12) {
            // WebSocket connection
            HStack(spacing: 4) {
                Circle()
                    .fill(store.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(store.isConnected ? "Live" : "Offline")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Dashboard data connection
            HStack(spacing: 4) {
                Circle()
                    .fill(store.dashboardConnected ? Color.blue : Color.orange)
                    .frame(width: 8, height: 8)
                Text(store.dashboardConnected ? "Data" : "Stale")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Last update time
            if let lastUpdate = store.lastDashboardUpdate {
                Text(timeAgo(from: lastUpdate))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }
    
    private func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Overview Tab

struct OverviewTab: View {
    @EnvironmentObject var store: MessageStore
    
    var body: some View {
        VStack(spacing: 16) {
            // Stats Cards
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatCard(
                    title: "Active Sessions",
                    value: "\(sessionCount)",
                    icon: "bubble.left.and.bubble.right.fill",
                    color: .blue
                )
                
                StatCard(
                    title: "Agents",
                    value: "\(agentCount)",
                    icon: "person.2.fill",
                    color: .green
                )
                
                StatCard(
                    title: "Total Cost",
                    value: totalCost,
                    icon: "dollarsign.circle.fill",
                    color: .orange
                )
                
                StatCard(
                    title: "Cron Jobs",
                    value: "\(cronJobCount)",
                    icon: "clock.arrow.circlepath",
                    color: .purple
                )
            }
            
            // Tasks section
            if !store.tasks.isEmpty {
                TasksSection()
                    .environmentObject(store)
            }
            
            // Stale heartbeats warning
            if let staleCount = store.openclawStatus?.summary?.staleHeartbeats, staleCount > 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("\(staleCount) stale heartbeat\(staleCount == 1 ? "" : "s")")
                        .font(.subheadline)
                    Spacer()
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
            
            // Pending tasks
            if let stats = store.taskStats, stats.pending ?? 0 > 0 {
                HStack {
                    Image(systemName: "list.bullet.clipboard.fill")
                        .foregroundColor(.blue)
                    Text("\(stats.pending ?? 0) pending task\((stats.pending ?? 0) == 1 ? "" : "s")")
                        .font(.subheadline)
                    Spacer()
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
    
    private var sessionCount: Int {
        store.dashboardSnapshot?.sessions?.count ?? 0
    }
    
    private var agentCount: Int {
        store.dashboardSnapshot?.agents?.count ?? 0
    }
    
    private var totalCost: String {
        let cost = store.dashboardSnapshot?.totalCost ?? 0
        return String(format: "%.2f", cost)
    }
    
    private var cronJobCount: Int {
        store.openclawStatus?.summary?.totalCronJobs ?? 0
    }
}

// MARK: - Tasks Section

struct TasksSection: View {
    @EnvironmentObject var store: MessageStore
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Active Tasks")
                    .font(.headline)
                Spacer()
                if let stats = store.taskStats {
                    HStack(spacing: 8) {
                        StatusBadge(count: stats.active, color: .green, label: "active")
                        StatusBadge(count: stats.pending, color: .blue, label: "pending")
                        StatusBadge(count: stats.blocked, color: .red, label: "blocked")
                    }
                }
            }
            
            ForEach(store.tasks.prefix(5)) { task in
                TaskRow(task: task)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct StatusBadge: View {
    let count: Int?
    let color: Color
    let label: String
    
    var body: some View {
        if let count = count, count > 0 {
            HStack(spacing: 2) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text("\(count) \(label)")
                    .font(.caption2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
        }
    }
}

struct TaskRow: View {
    let task: DashboardTask
    
    var body: some View {
        HStack(spacing: 12) {
            Text(task.agent_emoji ?? "🤖")
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(task.agent_name ?? task.agent_id ?? "Unknown")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    StatusDot(status: task.status)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct StatusDot: View {
    let status: String
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colorForStatus)
                .frame(width: 6, height: 6)
            Text(status)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var colorForStatus: Color {
        switch status {
        case "active", "running": return .green
        case "pending", "queued": return .blue
        case "completed", "done": return .gray
        case "blocked", "error", "failed": return .red
        default: return .orange
        }
    }
}

// MARK: - Agents Tab

struct AgentsTab: View {
    @EnvironmentObject var store: MessageStore
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let agents = store.dashboardSnapshot?.agents, !agents.isEmpty {
                ForEach(agents) { agent in
                    AgentCard(agent: agent)
                }
            } else {
                EmptyStateView(
                    icon: "person.2.slash",
                    message: "No agents connected"
                )
            }
        }
    }
}

struct AgentCard: View {
    let agent: DashboardAgent
    @State private var showingPingConfirmation = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Agent avatar with color
                ZStack {
                    Circle()
                        .fill(agentColor)
                        .frame(width: 48, height: 48)
                    
                    Text(agent.emoji ?? "🤖")
                        .font(.title2)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.headline)
                    
                    if let model = agent.model {
                        Text(model)
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    
                    if let skillCount = agent.skills?.count, skillCount > 0 {
                        Text("\(skillCount) skills")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    StatusDot(status: agent.status ?? "unknown")
                    
                    // Ping button
                    Button(action: { showingPingConfirmation = true }) {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }
            
            if let skills = agent.skills, !skills.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(skills.prefix(8)) { skill in
                        SkillBadge(skill: skill)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .contextMenu {
            Button(action: { showingPingConfirmation = true }) {
                Label("Ping Agent", systemImage: "waveform")
            }
            
            if let agentId = agent.id {
                Button(action: { UIPasteboard.general.string = agentId }) {
                    Label("Copy Agent ID", systemImage: "doc.on.doc")
                }
            }
        }
        .alert("Ping \(agent.name)?", isPresented: $showingPingConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Ping") {
                // Haptic feedback
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
            }
        } message: {
            Text("Send a wake message to \(agent.name)")
        }
    }
    
    private var agentColor: Color {
        guard let colorString = agent.color else {
            return Color.gray
        }
        return Color(hex: colorString) ?? Color.gray
    }
}

struct SkillBadge: View {
    let skill: AgentSkill
    
    var body: some View {
        HStack(spacing: 2) {
            Text(skill.icon ?? "🔹")
                .font(.caption)
            Text(skill.name)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(6)
    }
}

// MARK: - Sessions Tab

struct SessionsTab: View {
    @EnvironmentObject var store: MessageStore
    @State private var isRefreshing = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Stats summary
            if let sessions = store.dashboardSnapshot?.sessions {
                SessionsStatsHeader(sessions: sessions)
            }
            
            if let sessions = store.dashboardSnapshot?.sessions, !sessions.isEmpty {
                ForEach(sessions.prefix(50)) { session in
                    EnhancedSessionRow(session: session)
                        .environmentObject(store)
                }
            } else {
                EmptyStateView(
                    icon: "bubble.left.and.bubble.right.slash",
                    message: "No active sessions"
                )
            }
        }
    }
}

struct SessionsStatsHeader: View {
    let sessions: [DashboardSession]
    
    var body: some View {
        HStack(spacing: 16) {
            StatBadge(
                count: sessions.filter { $0.status == "active" }.count,
                label: "Active",
                color: .green
            )
            
            StatBadge(
                count: sessions.filter { $0.status == "idle" }.count,
                label: "Idle",
                color: .orange
            )
            
            StatBadge(
                count: sessions.count,
                label: "Total",
                color: .blue
            )
            
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct StatBadge: View {
    let count: Int
    let label: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .cornerRadius(8)
    }
}

struct SessionCard: View {
    let session: DashboardSession
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.id.prefix(8))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Spacer()
                
                if let cost = session.totalCost, cost > 0 {
                    Text("$\(String(format: "%.3f", cost))")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            HStack(spacing: 12) {
                if let agentId = session.agentId {
                    Label(agentId, systemImage: "person.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                if let tokens = session.totalTokens, tokens > 0 {
                    Label(formatTokens(tokens), systemImage: "cylinder.split.1x2")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                if let count = session.messageCount, count > 0 {
                    Label("\(count)", systemImage: "message.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            if let model = session.model {
                Text(model)
                    .font(.caption2)
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }
    
    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}

// MARK: - Cron Tab

struct CronTab: View {
    @EnvironmentObject var store: MessageStore
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Summary cards
            if let summary = store.openclawStatus?.summary {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(
                        title: "Total Jobs",
                        value: "\(summary.totalCronJobs)",
                        icon: "clock.badge.checkmark",
                        color: .blue
                    )
                    
                    StatCard(
                        title: "Enabled",
                        value: "\(summary.enabledCronJobs)",
                        icon: "checkmark.circle.fill",
                        color: .green
                    )
                    
                    StatCard(
                        title: "Errors",
                        value: "\(summary.cronErrors)",
                        icon: "exclamationmark.triangle.fill",
                        color: summary.cronErrors > 0 ? .red : .gray
                    )
                    
                    StatCard(
                        title: "Heartbeats",
                        value: "\(summary.heartbeatCount)",
                        icon: "heart.fill",
                        color: .pink
                    )
                }
            }
            
            // Cron jobs list
            if let jobs = store.openclawStatus?.cronJobs, !jobs.isEmpty {
                Text("Cron Jobs")
                    .font(.headline)
                    .padding(.top)
                
                ForEach(jobs) { job in
                    CronJobRow(job: job)
                }
            }
            
            // Heartbeats list
            if let heartbeats = store.openclawStatus?.heartbeats, !heartbeats.isEmpty {
                Text("Heartbeats")
                    .font(.headline)
                    .padding(.top)
                
                ForEach(heartbeats) { heartbeat in
                    HeartbeatRow(heartbeat: heartbeat)
                }
            }
            
            if store.openclawStatus == nil {
                EmptyStateView(
                    icon: "clock.arrow.2.circlepath",
                    message: "No cron data available"
                )
            }
        }
    }
}

struct CronJobRow: View {
    let job: CronJob
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(job.schedule)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let agentId = job.agentId {
                    Text(agentId)
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
            
            Spacer()
            
            if job.isHeartbeat {
                Image(systemName: "heart.fill")
                    .foregroundColor(.pink)
                    .font(.caption)
            }
            
            if !job.enabled {
                Text("OFF")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }
    
    private var statusIcon: String {
        switch job.status {
        case "ok": return "checkmark.circle.fill"
        case "error": return "xmark.circle.fill"
        case "running": return "arrow.triangle.2.circlepath"
        case "disabled": return "pause.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }
    
    private var statusColor: Color {
        switch job.status {
        case "ok": return .green
        case "error": return .red
        case "running": return .blue
        case "disabled": return .gray
        default: return .orange
        }
    }
}

struct HeartbeatRow: View {
    let heartbeat: Heartbeat
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(heartbeat.agentId)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if let every = heartbeat.every {
                    Text(every)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let model = heartbeat.model {
                    Text(model)
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
            
            Spacer()
            
            if !heartbeat.enabled {
                Text("OFF")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }
    
    private var statusIcon: String {
        switch heartbeat.status {
        case "ok": return "heart.fill"
        case "stale": return "heart.slash.fill"
        case "disabled": return "pause.fill"
        default: return "questionmark"
        }
    }
    
    private var statusColor: Color {
        switch heartbeat.status {
        case "ok": return .pink
        case "stale": return .orange
        case "disabled": return .gray
        default: return .secondary
        }
    }
}

// MARK: - Supporting Views

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(color)
            
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct EmptyStateView: View {
    let icon: String
    let message: String
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(message)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding()
    }
}

// MARK: - Flow Layout for Skills

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
                
                self.size.width = max(self.size.width, x)
            }
            
            self.size.height = y + rowHeight
        }
    }
}

// MARK: - Preview

struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
            .environmentObject(MessageStore())
    }
}
