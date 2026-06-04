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
                    StatusGlyph(status: context.state.status)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.status)
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if !context.state.detail.isEmpty {
                            Text(context.state.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let firstTitle = context.state.primaryListTitle {
                            Text(firstTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                StatusGlyph(status: context.state.status)
            } compactTrailing: {
                Text(context.state.mode == "call" ? context.state.startedAt : context.state.updatedAt, style: context.state.mode == "call" ? .timer : .relative)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                StatusGlyph(status: context.state.status)
            }
        }
    }
}

private struct LockScreenCallActivity: View {
    let state: KishOSCallActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            StatusGlyph(status: state.status)
                .font(.title3)

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

private struct StatusGlyph: View {
    let status: String

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 10, height: 10)
    }

    private var tint: Color {
        switch status {
        case "Listening", "Speaking":
            return .green
        case "Working", "Sending", "Connecting", "Question", "Review":
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
}
#endif
