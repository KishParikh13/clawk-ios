import SwiftUI
import SwiftData

@main
struct ClawkApp: App {
    @StateObject private var messageStore = MessageStore()
    
    var body: some Scene {
        WindowGroup {
            TabView {
                // Native Gateway Chat (new - direct WebSocket)
                GatewayChatView()
                    .tabItem {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                
                // Relay Messages (existing - via backend)
                ContentView()
                    .tabItem {
                        Label("Messages", systemImage: "bell.fill")
                    }
                    .environmentObject(messageStore)
                
                // System Dashboard (existing)
                DashboardView()
                    .tabItem {
                        Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                    }
                    .environmentObject(messageStore)
            }
        }
        .modelContainer(for: [PersistedMessage.self, PersistedSession.self, AgentIdentityRecord.self])
    }
}
