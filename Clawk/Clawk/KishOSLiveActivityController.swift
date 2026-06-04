#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

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
            sessionTitles: [],
            reviewTitles: latestSummary?.reviewTitles ?? [],
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
            .filter { $0.needsLiveActivityReview(selectedConversationID: selectedConversationID, recentCutoff: recentCutoff) }
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

        let runningCount = conversations.filter(\.isRunning).count
        let sessionTitles = Array(recent.map(\.title).prefix(Self.maxSessionTitles))
        let reviewTitles = Array(review.map(\.title).prefix(Self.maxReviewTitles))
        let status: String
        if !review.isEmpty {
            status = "Review"
        } else if runningCount > 0 {
            status = "Working"
        } else {
            status = "Recent"
        }

        let detail = Self.summaryDetail(
            sessionCount: recent.count,
            reviewCount: review.count,
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
            sessionTitles: sessionTitles,
            reviewTitles: reviewTitles,
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

    private static func summaryDetail(sessionCount: Int, reviewCount: Int, runningCount: Int) -> String {
        var parts: [String] = []
        if runningCount > 0 {
            parts.append("\(runningCount) running")
        }
        if sessionCount > 0 {
            parts.append("\(sessionCount) recent")
        }
        if reviewCount > 0 {
            parts.append("\(reviewCount) review")
        }
        return parts.joined(separator: " · ")
    }

    private static let recentWindow: TimeInterval = 5 * 60
    private static let maxSessionTitles = 4
    private static let maxReviewTitles = 3
}

private extension Conversation {
    func needsLiveActivityReview(selectedConversationID: UUID?, recentCutoff: Date) -> Bool {
        if !approvals.isEmpty || lastError != nil || queuedUserMessageCount > 0 {
            return true
        }
        return runState == .done && updatedAt >= recentCutoff && id != selectedConversationID
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
