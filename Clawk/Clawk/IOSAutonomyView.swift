import SwiftUI

struct IOSAutonomyView: View {
    @ObservedObject var client: KishAgentClient
    let onOpenConversation: (String?, String?) async -> Bool

    @State private var selectedSection: IOSAutonomySection = .brief
    @State private var didChooseInitialSection = false
    @State private var summary: AutonomySummary?
    @State private var reviewCards: [ReviewCard] = []
    @State private var runs: [RoutineRun] = []
    @State private var memory: [KishMemory] = []
    @State private var routines: [KishRoutine] = []
    @State private var isLoading = false
    @State private var isRunningBrief = false
    @State private var updatingCardID: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            IOSAutonomyOverview(
                summary: summary,
                latestRun: runs.first,
                isLoading: isLoading,
                isRunningBrief: isRunningBrief,
                onSelect: { selectedSection = $0 },
                onRunBrief: { Task { await runBrief() } },
                relativeText: relativeText(for:)
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Picker("Autonomy section", selection: $selectedSection) {
                ForEach(IOSAutonomySection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            Group {
                if isLoading && summary == nil {
                    IOSAutonomyLoadingView()
                } else if let errorMessage, summary == nil {
                    IOSAutonomyMessageView(
                        systemImage: "exclamationmark.triangle",
                        title: "Autonomy unavailable",
                        message: errorMessage,
                        actionTitle: "Retry",
                        action: { Task { await refresh() } }
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let errorMessage {
                                IOSAutonomyInlineError(message: errorMessage) {
                                    Task { await refresh() }
                                }
                            }

                            content
                        }
                        .padding(16)
                    }
                    .refreshable {
                        await refresh()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(IOSTheme.groupedBackground)
        .task {
            await refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .brief:
            briefSection
        case .review:
            reviewSection
        case .recentRuns:
            recentRunsSection
        case .memory:
            memorySection
        case .routines:
            routinesSection
        }
    }

    private var briefSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IOSAutonomyPanel {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Brief")
                            .font(.headline)
                        Text(summary?.latestBrief.map { relativeText(for: $0.createdAt) } ?? "No brief yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task { await runBrief() }
                    } label: {
                        if isRunningBrief {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Brief me", systemImage: "sparkles")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.callout.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunningBrief)
                }

                if let brief = summary?.latestBrief {
                    Text(brief.summary)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(brief.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                            if section.items.isEmpty {
                                Text("No items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(section.items, id: \.self) { item in
                                    HStack(alignment: .top, spacing: 8) {
                                        Circle()
                                            .fill(Color.secondary.opacity(0.65))
                                            .frame(width: 4, height: 4)
                                            .padding(.top, 7)
                                        Text(item)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    IOSAutonomyEmptyLine(text: "Run a brief to create the first summary.")
                }
            }

            if let summary {
                IOSAutonomyStatsRow(items: [
                    .init(title: "Review", value: "\(summary.pendingReviewCount)", tint: summary.pendingReviewCount > 0 ? .orange : .green),
                    .init(title: "Urgent", value: "\(summary.urgentReviewCount)", tint: summary.urgentReviewCount > 0 ? .red : .secondary),
                    .init(title: "Memory", value: "\(summary.memoryCounts.active)", tint: .blue),
                    .init(title: "Routines", value: "\(summary.routineCounts.enabled)", tint: .green)
                ])
            }
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if reviewCards.isEmpty {
                IOSAutonomyMessageView(
                    systemImage: "checkmark.circle",
                    title: "No open review",
                    message: "Open review cards will appear here."
                )
            } else {
                ForEach(reviewCards) { card in
                    IOSReviewCardView(
                        card: card,
                        isUpdating: updatingCardID == card.id,
                        onPrimary: { Task { await primaryAction(for: card) } },
                        onDismiss: { Task { await update(card, decision: .dismiss) } }
                    )
                }
            }
        }
    }

    private var recentRunsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if runs.isEmpty {
                IOSAutonomyMessageView(
                    systemImage: "clock",
                    title: "No recent runs",
                    message: "Routine runs will appear here."
                )
            } else {
                ForEach(runs) { run in
                    IOSAutonomyPanel {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(run.routineId)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            IOSAutonomyPill(text: run.status.rawValue, tint: tint(for: run.status))
                        }
                        Text(run.error?.message ?? run.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(relativeText(for: run.updatedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let counts = summary?.memoryCounts {
                IOSAutonomyStatsRow(items: [
                    .init(title: "Active", value: "\(counts.active)", tint: .green),
                    .init(title: "Pinned", value: "\(counts.pinned)", tint: .blue),
                    .init(title: "Review", value: "\(counts.needsReview)", tint: counts.needsReview > 0 ? .orange : .secondary),
                    .init(title: "Conflicts", value: "\(counts.conflicted)", tint: counts.conflicted > 0 ? .red : .secondary)
                ])
            }

            if memory.isEmpty {
                IOSAutonomyMessageView(
                    systemImage: "brain",
                    title: "No memory",
                    message: "Saved context will appear here."
                )
            } else {
                ForEach(memory.prefix(20)) { item in
                    IOSAutonomyPanel {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.summary ?? item.text)
                                .font(.callout.weight(.medium))
                                .lineLimit(3)
                            Spacer(minLength: 8)
                            IOSAutonomyPill(text: item.state.rawValue, tint: .secondary)
                        }

                        if item.summary != nil {
                            Text(item.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        if !item.reviewFlags.isEmpty {
                            IOSAutonomyFlagRow(flags: item.reviewFlags.map(\.rawValue))
                        }
                    }
                }
            }
        }
    }

    private var routinesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let counts = summary?.routineCounts {
                IOSAutonomyStatsRow(items: [
                    .init(title: "Enabled", value: "\(counts.enabled)", tint: .green),
                    .init(title: "Proposed", value: "\(counts.proposed)", tint: counts.proposed > 0 ? .orange : .secondary),
                    .init(title: "Paused", value: "\(counts.paused)", tint: counts.paused > 0 ? .orange : .secondary),
                    .init(title: "Disabled", value: "\(counts.disabled)", tint: .secondary)
                ])
            }

            if routines.isEmpty {
                IOSAutonomyMessageView(
                    systemImage: "repeat",
                    title: "No routines",
                    message: "Routines will appear here."
                )
            } else {
                ForEach(routines) { routine in
                    IOSAutonomyPanel {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(routine.name)
                                    .font(.callout.weight(.semibold))
                                Text(routine.template.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            IOSAutonomyPill(text: routine.state.rawValue, tint: tint(for: routine.state))
                        }
                    }
                }
            }
        }
    }

    private func refresh() async {
        isLoading = true
        errorMessage = nil
        do {
            async let fetchedSummary = client.fetchAutonomySummary()
            async let fetchedCards = client.fetchReviewCards()
            async let fetchedRuns = client.fetchRoutineRuns()
            async let fetchedMemory = client.fetchMemory()
            async let fetchedRoutines = client.fetchRoutines()

            let (nextSummary, nextCards, nextRuns, nextMemory, nextRoutines) = try await (
                fetchedSummary,
                fetchedCards,
                fetchedRuns,
                fetchedMemory,
                fetchedRoutines
            )

            summary = nextSummary
            reviewCards = nextCards
            runs = nextRuns.sorted { $0.updatedAt > $1.updatedAt }
            memory = nextMemory.sorted { $0.updatedAt > $1.updatedAt }
            routines = nextRoutines.sorted { $0.updatedAt > $1.updatedAt }

            if !didChooseInitialSection {
                selectedSection = nextCards.isEmpty ? .brief : .review
                didChooseInitialSection = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func runBrief() async {
        guard !isRunningBrief else { return }
        isRunningBrief = true
        errorMessage = nil
        let manualID = "manual_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let key = "routine:routine_dailyBrief:manual:\(manualID)"

        do {
            let result = try await client.runDailyBrief(
                idempotencyKey: key,
                trigger: RoutineRunTrigger(type: .manual, manualRunId: manualID)
            )
            await refresh()
            let opened = await onOpenConversation(result.conversationId, result.threadId)
            if !opened {
                errorMessage = "Brief created, but the conversation is not available yet."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isRunningBrief = false
    }

    private func primaryAction(for card: ReviewCard) async {
        if card.recommendedAction == .openConversation {
            let opened = await onOpenConversation(card.conversationId, card.threadId)
            if !opened {
                errorMessage = "Conversation is not available yet."
            }
            return
        }

        await update(card, decision: card.recommendedAction)
    }

    private func update(_ card: ReviewCard, decision: RecommendedAction) async {
        guard updatingCardID == nil else { return }
        updatingCardID = card.id
        errorMessage = nil
        do {
            _ = try await client.updateReviewCard(card.id, decision: decision)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
        updatingCardID = nil
    }

    private func relativeText(for date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func tint(for state: RoutineRunState) -> Color {
        switch state {
        case .done:
            return .green
        case .failed:
            return .red
        case .needsApproval, .needsReview:
            return .orange
        case .queued, .running:
            return .blue
        }
    }

    private func tint(for state: RoutineState) -> Color {
        switch state {
        case .enabled:
            return .green
        case .paused, .proposed:
            return .orange
        case .disabled:
            return .secondary
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct IOSAutonomyOverview: View {
    let summary: AutonomySummary?
    let latestRun: RoutineRun?
    let isLoading: Bool
    let isRunningBrief: Bool
    let onSelect: (IOSAutonomySection) -> Void
    let onRunBrief: () -> Void
    let relativeText: (Date) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Autonomy")
                        .font(.headline.weight(.semibold))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onRunBrief) {
                    if isRunningBrief {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Brief", systemImage: "sparkles")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.callout.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || isRunningBrief)
                .accessibilityLabel("Run daily brief")
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                IOSAutonomySignalCard(
                    title: "Review",
                    value: reviewValue,
                    detail: reviewDetail,
                    systemImage: "checklist",
                    tint: reviewTint,
                    action: { onSelect(.review) }
                )
                IOSAutonomySignalCard(
                    title: "Latest Brief",
                    value: briefValue,
                    detail: briefDetail,
                    systemImage: "doc.text",
                    tint: .blue,
                    action: { onSelect(.brief) }
                )
                IOSAutonomySignalCard(
                    title: "Last Run",
                    value: runValue,
                    detail: runDetail,
                    systemImage: "clock.arrow.circlepath",
                    tint: latestRun.map { tint(for: $0.status) } ?? .secondary,
                    action: { onSelect(.recentRuns) }
                )
                IOSAutonomySignalCard(
                    title: "Memory",
                    value: memoryValue,
                    detail: memoryDetail,
                    systemImage: "brain.head.profile",
                    tint: memoryTint,
                    action: { onSelect(.memory) }
                )
            }
        }
    }

    private var statusText: String {
        if isLoading && summary == nil {
            return "Loading status"
        }
        if let summary {
            return "Updated \(relativeText(summary.updatedAt))"
        }
        return "Waiting for kish-agent"
    }

    private var reviewValue: String {
        guard let summary else { return "..." }
        return "\(summary.pendingReviewCount)"
    }

    private var reviewDetail: String {
        guard let summary else { return "Open cards" }
        if summary.urgentReviewCount > 0 {
            return "\(summary.urgentReviewCount) urgent"
        }
        return summary.pendingReviewCount == 1 ? "Needs input" : "Need input"
    }

    private var reviewTint: Color {
        guard let summary else { return .secondary }
        if summary.urgentReviewCount > 0 { return .red }
        return summary.pendingReviewCount > 0 ? .orange : .green
    }

    private var briefValue: String {
        summary?.latestBrief == nil ? "None" : "Ready"
    }

    private var briefDetail: String {
        if let createdAt = summary?.latestBrief?.createdAt {
            return relativeText(createdAt)
        }
        return "Run one now"
    }

    private var runValue: String {
        latestRun?.status.summaryText ?? "None"
    }

    private var runDetail: String {
        if let latestRun {
            return relativeText(latestRun.updatedAt)
        }
        return "No runs yet"
    }

    private var memoryValue: String {
        guard let counts = summary?.memoryCounts else { return "..." }
        return "\(counts.active + counts.pinned)"
    }

    private var memoryDetail: String {
        guard let counts = summary?.memoryCounts else { return "Known context" }
        let flagged = counts.needsReview + counts.sensitive + counts.conflicted
        return flagged > 0 ? "\(flagged) flagged" : "Clean"
    }

    private var memoryTint: Color {
        guard let counts = summary?.memoryCounts else { return .secondary }
        return (counts.needsReview + counts.sensitive + counts.conflicted) > 0 ? .orange : .blue
    }

    private func tint(for state: RoutineRunState) -> Color {
        switch state {
        case .done:
            return .green
        case .failed:
            return .red
        case .needsApproval, .needsReview:
            return .orange
        case .queued, .running:
            return .blue
        }
    }
}

private struct IOSAutonomySignalCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .padding(12)
            .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(0.24)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }
}

private extension RoutineRunState {
    var summaryText: String {
        switch self {
        case .queued:
            return "Queued"
        case .running:
            return "Running"
        case .needsApproval:
            return "Needs Approval"
        case .needsReview:
            return "Needs Review"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        }
    }
}

private enum IOSAutonomySection: String, CaseIterable, Identifiable {
    case brief
    case review
    case recentRuns
    case memory
    case routines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief:
            return "Brief"
        case .review:
            return "Review"
        case .recentRuns:
            return "Recent Runs"
        case .memory:
            return "Memory"
        case .routines:
            return "Routines"
        }
    }
}

private struct IOSReviewCardView: View {
    let card: ReviewCard
    let isUpdating: Bool
    let onPrimary: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        IOSAutonomyPanel {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.kind.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                IOSAutonomyPill(text: card.recommendedAction.rawValue, tint: .blue)
            }

            Text(card.body)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !card.reviewFlags.isEmpty {
                IOSAutonomyFlagRow(flags: card.reviewFlags.map(\.rawValue))
            }

            HStack(spacing: 10) {
                Button(action: onDismiss) {
                    Text("Dismiss")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isUpdating)

                Button(action: onPrimary) {
                    HStack(spacing: 6) {
                        if isUpdating {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(primaryTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isUpdating)
            }
            .font(.callout.weight(.semibold))
        }
    }

    private var primaryTitle: String {
        switch card.recommendedAction {
        case .openConversation:
            return "Open"
        case .approve:
            return "Approve"
        case .reject:
            return "Reject"
        case .resolve:
            return "Resolve"
        case .dismiss:
            return "Dismiss"
        case .editMemory:
            return "Edit memory"
        case .enableRoutine:
            return "Enable"
        case .pauseRoutine:
            return "Pause"
        case .retryRun:
            return "Retry"
        }
    }
}

private struct IOSAutonomyPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(IOSTheme.hairline))
    }
}

private struct IOSAutonomyStatItem: Identifiable {
    let title: String
    let value: String
    let tint: Color

    var id: String { title }
}

private struct IOSAutonomyStatsRow: View {
    let items: [IOSAutonomyStatItem]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.value)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(item.tint)
                    Text(item.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(IOSTheme.hairline))
            }
        }
    }
}

private struct IOSAutonomyPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct IOSAutonomyFlagRow: View {
    let flags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(flags, id: \.self) { flag in
                    IOSAutonomyPill(text: flag, tint: .orange)
                }
            }
        }
    }
}

private struct IOSAutonomyLoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading Autonomy")
                .font(.callout.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }
}

private struct IOSAutonomyMessageView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(20)
    }
}

private struct IOSAutonomyInlineError: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Retry", action: onRetry)
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
        }
        .padding(10)
        .background(IOSTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(IOSTheme.hairline))
    }
}

private struct IOSAutonomyEmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}
