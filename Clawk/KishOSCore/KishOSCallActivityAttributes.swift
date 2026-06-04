#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

struct KishOSCallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var mode: String
        var title: String
        var status: String
        var detail: String
        var runningTitles: [String]
        var sessionTitles: [String]
        var reviewTitles: [String]
        var runningCount: Int
        var unreadCount: Int
        var reviewCount: Int
        var sessionCount: Int
        var startedAt: Date
        var updatedAt: Date
    }

    var sessionName: String
}
#endif
