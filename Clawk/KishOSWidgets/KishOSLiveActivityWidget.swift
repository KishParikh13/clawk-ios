#if canImport(ActivityKit)
import ActivityKit
import SwiftUI
import WidgetKit

struct KishOSLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KishOSCallActivityAttributes.self) { context in
            LockScreenCallActivity(state: context.state)
                .padding(14)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusMark(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.compactCountText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if !context.state.detail.isEmpty {
                            Text(context.state.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !context.state.runningTitles.isEmpty {
                            RunningTitleStrip(titles: stateTitles(context.state.runningTitles, max: 2))
                        } else if let firstTitle = context.state.primaryListTitle {
                            Text(firstTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                StatusMark(state: context.state)
            } compactTrailing: {
                Text(context.state.compactCountText)
                    .font(.caption2.weight(.semibold).monospacedDigit())
            } minimal: {
                StatusMark(state: context.state)
            }
        }
    }

    private func stateTitles(_ titles: [String], max: Int) -> [String] {
        Array(titles.prefix(max))
    }
}

private struct LockScreenCallActivity: View {
    let state: KishOSCallActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            StatusMark(state: state)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(state.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Text(state.mode == "call" ? state.startedAt : state.updatedAt, style: state.mode == "call" ? .timer : .relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Text(state.status)
                        .font(.caption.weight(.semibold))
                    if !state.detail.isEmpty {
                        Text(state.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if !state.runningTitles.isEmpty {
                    RunningSessionList(titles: state.runningTitles, overflowCount: max(0, state.runningCount - state.runningTitles.count))
                }

                if !state.reviewTitles.isEmpty {
                    SessionTitleLine(prefix: "Review", titles: state.reviewTitles)
                }

                if !state.sessionTitles.isEmpty {
                    SessionTitleLine(prefix: state.mode == "call" ? "Recent" : "Sessions", titles: state.sessionTitles)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

private struct RunningSessionList: View {
    let titles: [String]
    let overflowCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(titles.prefix(3).enumerated()), id: \.offset) { _, title in
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.orange)
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if overflowCount > 0 {
                Text("+\(overflowCount) more working")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct RunningTitleStrip: View {
    let titles: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.orange)
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct SessionTitleLine: View {
    let prefix: String
    let titles: [String]

    var body: some View {
        Text("\(prefix): \(titles.joined(separator: ", "))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct StatusMark: View {
    let state: KishOSCallActivityAttributes.ContentState

    var body: some View {
        if state.showsSpinner {
            ProgressView()
                .controlSize(.small)
                .tint(.orange)
        } else {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)
        }
    }

    private var tint: Color {
        switch state.status {
        case "Listening", "Speaking":
            return .green
        case "Working", "Sending", "Connecting", "Question", "Review":
            return .orange
        case "Unread":
            return .orange
        case "Recent":
            return .blue
        case "Failed":
            return .red
        default:
            return .secondary
        }
    }
}

private extension KishOSCallActivityAttributes.ContentState {
    var primaryListTitle: String? {
        reviewTitles.first ?? sessionTitles.first
    }

    var showsSpinner: Bool {
        mode == "call" || runningCount > 0 || status == "Working" || status == "Sending" || status == "Connecting"
    }

    var compactCountText: String {
        if mode == "call" {
            return status
        }
        if runningCount > 0 {
            return "\(runningCount)"
        }
        if unreadCount > 0 {
            return "\(unreadCount)"
        }
        if reviewCount > 0 {
            return "\(reviewCount)"
        }
        return status
    }
}
#endif
