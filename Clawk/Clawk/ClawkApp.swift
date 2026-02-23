import SwiftUI

@main
struct ClawkApp: App {
    @StateObject private var messageStore = MessageStore()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(messageStore)
        }
    }
}
