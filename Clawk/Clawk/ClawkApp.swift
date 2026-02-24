import SwiftUI

@main
struct ClawkApp: App {
    @StateObject private var messageStore = MessageStore()
    
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem {
                        Label("Messages", systemImage: "bubble.left.and.bubble.right")
                    }
                    .environmentObject(messageStore)
                
                DashboardView()
                    .tabItem {
                        Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                    }
                    .environmentObject(messageStore)
            }
        }
    }
}
