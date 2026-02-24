import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var store: MessageStore
    @State private var dashboardData: DashboardData?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Tab selector
                Picker("View", selection: $selectedTab) {
                    Text("Overview").tag(0)
                    Text("Sessions").tag(1)
                    Text("Agents").tag(2)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                if isLoading {
                    ProgressView("Loading dashboard...")
                        .padding()
                } else if let error = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        Text("Error loading dashboard")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Retry") {
                            loadDashboard()
                        }
                        .padding()
                    }
                } else if let data = dashboardData {
                    ScrollView {
                        VStack(spacing: 16) {
                            switch selectedTab {
                            case 0:
                                OverviewTab(data: data)
                            case 1:
                                SessionsTab(sessions: data.sessions.list)
                            case 2:
                                AgentsTab(agents: data.agents.list)
                            default:
                                OverviewTab(data: data)
                            }
                        }
                        .padding()
                    }
                } else {
                    Text("Pull to refresh")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: loadDashboard) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .onAppear {
                loadDashboard()
            }
            .refreshable {
                loadDashboard()
            }
        }
    }
    
    private func loadDashboard() {
        isLoading = true
        errorMessage = nil
        
        let url = Config.apiURL.appendingPathComponent("/dashboard/overview")
        var request = URLRequest(url: url)
        request.setValue(Config.deviceToken, forHTTPHeaderField: "x-device-token")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                
                if let error = error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                
                guard let data = data else {
                    self.errorMessage = "No data received"
                    return
                }
                
                do {
                    self.dashboardData = try JSONDecoder().decode(DashboardData.self, from: data)
                } catch {
                    self.errorMessage = "Failed to parse data: \(error.localizedDescription)"
                    print("Parse error: \(error)")
                }
            }
        }.resume()
    }
}

// MARK: - Data Models

struct DashboardData: Codable {
    let status: String
    let timestamp: TimeInterval
    let sessions: SessionData
    let agents: AgentData
    let costs: CostData
    let clawk: ClawkData
}

struct SessionData: Codable {
    let active: Int
    let list: [SessionItem]
}

struct SessionItem: Codable, Identifiable {
    var id: String { key }
    let key: String
    let kind: String
    let model: String?
    let totalTokens: Int?
    let updatedAt: TimeInterval
}

struct AgentData: Codable {
    let count: Int
    let list: [AgentItem]
}

struct AgentItem: Codable, Identifiable {
    let id: String
    let model: String?
    let heartbeat: String?
    let workspace: String?
}

struct CostData: Codable {
    let totalTokens: Int
    let estimatedCost: String
}

struct ClawkData: Codable {
    let deviceConnected: Bool
    let pendingMessages: Int
    let totalDevices: Int
}

// MARK: - Tab Views

struct OverviewTab: View {
    let data: DashboardData
    
    var body: some View {
        VStack(spacing: 16) {
            // Status Cards
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatusCard(
                    title: "Active Sessions",
                    value: "\(data.sessions.active)",
                    icon: "bubble.left.and.bubble.right.fill",
                    color: .blue
                )
                
                StatusCard(
                    title: "Agents",
                    value: "\(data.agents.count)",
                    icon: "person.2.fill",
                    color: .green
                )
                
                StatusCard(
                    title: "Total Tokens",
                    value: formatTokens(data.costs.totalTokens),
                    icon: "cylinder.split.1x2",
                    color: .orange
                )
                
                StatusCard(
                    title: "Est. Cost",
                    value: "$\(data.costs.estimatedCost)",
                    icon: "dollarsign.circle.fill",
                    color: .purple
                )
            }
            
            // Clawk Status
            VStack(alignment: .leading, spacing: 8) {
                Text("Clawk Status")
                    .font(.headline)
                
                HStack {
                    Image(systemName: data.clawk.deviceConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(data.clawk.deviceConnected ? .green : .red)
                    Text(data.clawk.deviceConnected ? "Device Connected" : "Device Offline")
                    Spacer()
                }
                
                HStack {
                    Image(systemName: "envelope.fill")
                        .foregroundColor(.blue)
                    Text("\(data.clawk.pendingMessages) pending messages")
                    Spacer()
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            
            // Last Updated
            Text("Last updated: \(formatDate(data.timestamp))")
                .font(.caption)
                .foregroundColor(.secondary)
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
    
    private func formatDate(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = RelativeDateTimeFormatter()
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct SessionsTab: View {
    let sessions: [SessionItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active Sessions (\(sessions.count))")
                .font(.headline)
            
            ForEach(sessions) { session in
                SessionRow(session: session)
            }
        }
    }
}

struct SessionRow: View {
    let session: SessionItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.key)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            
            HStack {
                Label(session.kind, systemImage: "tag.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if let tokens = session.totalTokens {
                    Text("\(tokens) tokens")
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
}

struct AgentsTab: View {
    let agents: [AgentItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agents (\(agents.count))")
                .font(.headline)
            
            ForEach(agents) { agent in
                AgentRow(agent: agent)
            }
        }
    }
}

struct AgentRow: View {
    let agent: AgentItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(agent.id)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let heartbeat = agent.heartbeat {
                    Text(heartbeat)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            if let model = agent.model {
                Text(model)
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            
            if let workspace = agent.workspace {
                Text(workspace)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }
}

struct StatusCard: View {
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
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
    }
}
