#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation
import UserNotifications

@MainActor
final class KishOSLiveActivityController {
    static let shared = KishOSLiveActivityController()

    private var activity: Activity<KishOSCallActivityAttributes>?
    private var latestSummary: KishOSCallActivityAttributes.ContentState?
    private var expirationTask: Task<Void, Never>?
    private var isLiveCallActive = false
    private var startedAt = Date()

    private init() {}

    func updateSummary(conversations: [Conversation], selectedConversationID: UUID? = nil, now: Date = Date()) {
        let summary = makeSummaryState(conversations: conversations, selectedConversationID: selectedConversationID, now: now)
        latestSummary = summary.state
        scheduleExpiration(at: summary.expiresAt)

        guard !isLiveCallActive else { return }
        guard let state = summary.state else {
            endActivity()
            return
        }
        upsert(state)
    }

    func updateLiveCall(title: String, status: String, detail: String, now: Date = Date()) {
        let wasLiveCallActive = isLiveCallActive
        isLiveCallActive = true
        if !wasLiveCallActive {
            startedAt = now
        }

        let state = KishOSCallActivityAttributes.ContentState(
            mode: "call",
            title: title,
            status: status,
            detail: detail,
            runningTitles: [title],
            sessionTitles: [],
            reviewTitles: latestSummary?.reviewTitles ?? [],
            runningCount: 1,
            unreadCount: latestSummary?.unreadCount ?? 0,
            reviewCount: latestSummary?.reviewCount ?? 0,
            sessionCount: latestSummary?.sessionCount ?? 0,
            startedAt: startedAt,
            updatedAt: now
        )
        upsert(state)
    }

    func endLiveCall() {
        isLiveCallActive = false
        if let latestSummary {
            upsert(latestSummary)
        } else {
            endActivity()
        }
    }

    private func makeSummaryState(
        conversations: [Conversation],
        selectedConversationID: UUID?,
        now: Date
    ) -> (state: KishOSCallActivityAttributes.ContentState?, expiresAt: Date?) {
        let recentCutoff = now.addingTimeInterval(-Self.recentWindow)
        let review = conversations
            .filter { $0.needsLiveActivityReview(selectedConversationID: selectedConversationID) }
            .sorted { $0.updatedAt > $1.updatedAt }
        let unread = conversations
            .filter { $0.needsLiveActivityUnreadReview(selectedConversationID: selectedConversationID) }
            .sorted { $0.updatedAt > $1.updatedAt }
        let running = conversations
            .filter(\.isRunning)
            .sorted { $0.updatedAt > $1.updatedAt }
        let recent = conversations
            .filter { $0.runState.isActive || $0.updatedAt >= recentCutoff }
            .sorted { lhs, rhs in
                if lhs.runState.isActive != rhs.runState.isActive {
                    return lhs.runState.isActive
                }
                return lhs.updatedAt > rhs.updatedAt
            }

        guard !recent.isEmpty || !review.isEmpty else {
            return (nil, nil)
        }

        let runningCount = running.count
        let unreadCount = unread.count
        let runningTitles = Array(running.map(\.title).prefix(Self.maxRunningTitles))
        let sessionTitles = Array(recent.map(\.title).prefix(Self.maxSessionTitles))
        let reviewTitles = Array(review.map(\.title).prefix(Self.maxReviewTitles))
        let status: String
        if runningCount > 0 {
            status = "Working"
        } else if unreadCount > 0 {
            status = "Unread"
        } else if !review.isEmpty {
            status = "Review"
        } else {
            status = "Recent"
        }

        let detail = Self.summaryDetail(
            sessionCount: recent.count,
            reviewCount: review.count,
            unreadCount: unreadCount,
            runningCount: runningCount
        )
        let expiresAt = review.isEmpty
            ? recent.map(\.updatedAt).max()?.addingTimeInterval(Self.recentWindow)
            : nil

        let state = KishOSCallActivityAttributes.ContentState(
            mode: "summary",
            title: "KishOS",
            status: status,
            detail: detail,
            runningTitles: runningTitles,
            sessionTitles: sessionTitles,
            reviewTitles: reviewTitles,
            runningCount: runningCount,
            unreadCount: unreadCount,
            reviewCount: review.count,
            sessionCount: recent.count,
            startedAt: startedAt,
            updatedAt: now
        )
        return (state, expiresAt)
    }

    private func upsert(_ state: KishOSCallActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let activity {
            Task {
                await activity.update(.init(state: state, staleDate: nil))
            }
        } else {
            startedAt = state.startedAt
            let attributes = KishOSCallActivityAttributes(sessionName: "KishOS")
            do {
                activity = try Activity.request(
                    attributes: attributes,
                    content: .init(state: state, staleDate: nil)
                )
            } catch {
                activity = nil
            }
        }
    }

    private func scheduleExpiration(at date: Date?) {
        expirationTask?.cancel()
        guard let date else { return }
        expirationTask = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self, !self.isLiveCallActive else { return }
                self.latestSummary = nil
                self.endActivity()
            }
        }
    }

    private func endActivity() {
        expirationTask?.cancel()
        expirationTask = nil
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func summaryDetail(sessionCount: Int, reviewCount: Int, unreadCount: Int, runningCount: Int) -> String {
        var parts: [String] = []
        if runningCount > 0 {
            parts.append("\(runningCount) working")
        }
        if unreadCount > 0 {
            parts.append("\(unreadCount) unread")
        }
        let nonUnreadReviewCount = max(0, reviewCount - unreadCount)
        if nonUnreadReviewCount > 0 {
            parts.append(Self.countText(nonUnreadReviewCount, singular: "review"))
        }
        if sessionCount > 0 {
            parts.append("\(sessionCount) recent")
        }
        return parts.joined(separator: " · ")
    }

    private static func countText(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }

    private static let recentWindow: TimeInterval = 5 * 60
    private static let maxRunningTitles = 3
    private static let maxSessionTitles = 4
    private static let maxReviewTitles = 3
}

@MainActor
final class KishOSStatusNotificationController {
    static let shared = KishOSStatusNotificationController()

    private let center = UNUserNotificationCenter.current()
    private let defaultsKey = "KishOSStatusNotificationSignatures"
    private var signatures: [String: String]
    private var authorizationTask: Task<Bool, Never>?

    private init() {
        signatures = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    func requestAuthorizationIfNeeded() async {
        _ = await hasAuthorization()
    }

    func update(conversations: [Conversation], isSceneActive: Bool) {
        guard !isSceneActive else { return }
        let candidates = conversations.compactMap(Self.notificationCandidate(for:))
        guard !candidates.isEmpty else { return }

        Task {
            guard await hasAuthorization() else { return }
            for candidate in candidates {
                schedule(candidate)
            }
        }
    }

    private func hasAuthorization() async -> Bool {
        if let authorizationTask {
            return await authorizationTask.value
        }

        let task = Task<Bool, Never> {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            case .denied:
                return false
            case .notDetermined:
                do {
                    return try await center.requestAuthorization(options: [.alert, .sound, .badge])
                } catch {
                    return false
                }
            @unknown default:
                return false
            }
        }
        authorizationTask = task
        let result = await task.value
        authorizationTask = nil
        return result
    }

    private func schedule(_ candidate: StatusNotificationCandidate) {
        let key = candidate.conversationID.uuidString.lowercased()
        guard signatures[key] != candidate.signature else { return }
        signatures[key] = candidate.signature
        UserDefaults.standard.set(signatures, forKey: defaultsKey)

        let content = UNMutableNotificationContent()
        content.title = candidate.title
        content.body = candidate.body
        content.sound = .default
        content.threadIdentifier = key
        content.userInfo = ["conversationID": key]

        let request = UNNotificationRequest(
            identifier: "kishos.status.\(key).\(candidate.kind)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private static func notificationCandidate(for conversation: Conversation) -> StatusNotificationCandidate? {
        if let approval = conversation.approvals.first {
            let question = approval.questions.first?.question.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = approval.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = question.isEmpty ? summary : question
            return StatusNotificationCandidate(
                conversationID: conversation.id,
                kind: "needs-answer",
                signature: "needs-answer:\(approval.id):\(conversation.updatedAt.timeIntervalSince1970)",
                title: "KishOS needs an answer",
                body: Self.body(title: conversation.title, detail: detail)
            )
        }

        if let lastError = conversation.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !lastError.isEmpty {
            return StatusNotificationCandidate(
                conversationID: conversation.id,
                kind: "failed",
                signature: "failed:\(conversation.updatedAt.timeIntervalSince1970):\(lastError)",
                title: "KishOS stopped",
                body: Self.body(title: conversation.title, detail: lastError)
            )
        }

        if conversation.runState == .done && conversation.isUnread {
            return StatusNotificationCandidate(
                conversationID: conversation.id,
                kind: "done",
                signature: "done:\(conversation.updatedAt.timeIntervalSince1970)",
                title: "KishOS finished",
                body: conversation.title
            )
        }

        return nil
    }

    private static func body(title: String, detail: String) -> String {
        let cleanDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDetail.isEmpty else { return title }
        return "\(title): \(cleanDetail)"
    }
}

private struct StatusNotificationCandidate {
    let conversationID: UUID
    let kind: String
    let signature: String
    let title: String
    let body: String
}

private extension Conversation {
    func needsLiveActivityReview(selectedConversationID: UUID?) -> Bool {
        id != selectedConversationID && needsReview
    }

    func needsLiveActivityUnreadReview(selectedConversationID: UUID?) -> Bool {
        id != selectedConversationID && runState == .done && isUnread
    }
}
#else
@MainActor
final class KishOSLiveActivityController {
    static let shared = KishOSLiveActivityController()
    private init() {}
    func updateSummary(conversations: [Conversation], selectedConversationID: UUID? = nil, now: Date = Date()) {}
    func updateLiveCall(title: String, status: String, detail: String, now: Date = Date()) {}
    func endLiveCall() {}
}
#endif
