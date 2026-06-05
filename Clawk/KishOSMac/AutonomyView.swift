import SwiftUI

struct AutonomyView: View {
    @ObservedObject var client: KishAgentClient
    var onOpenConversation: (String?, String?) -> Void = { _, _ in }

    @State private var selectedSection: AutonomySection = .brief
    @State private var summary: AutonomySummary?
    @State private var reviewCards: [ReviewCard] = []
    @State private var runs: [RoutineRun] = []
    @State private var memories: [KishMemory] = []
    @State private var routines: [KishRoutine] = []
    @State private var isLoading = false
    @State private var isBriefing = false
    @State private var errorMessage: String?
    @State private var actingReviewCardID: String?
    @State private var didChooseInitialSection = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Header(title: "Autonomy", subtitle: subtitle)
                    Spacer()
                    Button {
                        Task { await runBrief() }
                    } label: {
                        if isBriefing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Brief me", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    .disabled(isBriefing || isLoading)

                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(isLoading || isBriefing)
                    .help("Refresh")
                }

                Picker("Section", selection: $selectedSection) {
                    ForEach(AutonomySection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                AutonomyOverviewPanel(
                    summary: summary,
                    latestRun: runs.first,
                    isLoading: isLoading,
                    isBriefing: isBriefing,
                    onSelect: { selectedSection = $0 },
                    onRunBrief: { Task { await runBrief() } }
                )

                if isLoading && summary == nil && reviewCards.isEmpty {
                    LoadingPanel()
                } else {
                    selectedContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            await refresh()
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .brief:
            BriefSection(brief: summary?.latestBrief)
        case .review:
            ReviewSection(
                cards: reviewCards,
                actingReviewCardID: actingReviewCardID,
                onResolve: { card, decision in
                    Task { await resolve(card, decision: decision) }
                },
                onOpenConversation: { conversationId, threadId in
                    onOpenConversation(conversationId, threadId)
                }
            )
        case .runs:
            RunsSection(runs: runs)
        case .memory:
            MemorySection(memories: memories, counts: summary?.memoryCounts)
        case .routines:
            RoutinesSection(routines: routines, counts: summary?.routineCounts)
        }
    }

    private var subtitle: String {
        if let summary {
            let reviewText = summary.pendingReviewCount == 1 ? "1 review" : "\(summary.pendingReviewCount) reviews"
            return "\(reviewText) · Updated \(Self.dateTime.string(from: summary.updatedAt))"
        }
        return client.status
    }

    private func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let nextSummary = try await client.fetchAutonomySummary()
            let nextCards = try await client.fetchReviewCards(state: .open)
            let nextRuns = try await client.fetchRoutineRuns()
            let nextMemories = try await client.fetchMemory()
            let nextRoutines = try await client.fetchRoutines()

            summary = nextSummary
            reviewCards = nextCards
            runs = Array(nextRuns.sorted { $0.updatedAt > $1.updatedAt }.prefix(8))
            memories = Array(nextMemories.sorted { $0.updatedAt > $1.updatedAt }.prefix(8))
            routines = nextRoutines.sorted { $0.updatedAt > $1.updatedAt }

            if !didChooseInitialSection {
                selectedSection = nextCards.isEmpty ? .brief : .review
                didChooseInitialSection = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runBrief() async {
        isBriefing = true
        errorMessage = nil
        defer { isBriefing = false }

        let manualID = "manual_\(UUID().uuidString.lowercased())"
        do {
            let result = try await client.runDailyBrief(
                idempotencyKey: "routine:routine_dailyBrief:manual:\(manualID)",
                trigger: RoutineRunTrigger(type: .manual, manualRunId: manualID)
            )
            didChooseInitialSection = true
            selectedSection = .brief
            await refresh()
            onOpenConversation(result.conversationId, result.threadId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolve(_ card: ReviewCard, decision: RecommendedAction) async {
        actingReviewCardID = card.id
        errorMessage = nil
        defer { actingReviewCardID = nil }

        do {
            _ = try await client.updateReviewCard(card.id, decision: decision)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    fileprivate static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d h:mm a")
        return formatter
    }()
}

private struct AutonomyOverviewPanel: View {
    let summary: AutonomySummary?
    let latestRun: RoutineRun?
    let isLoading: Bool
    let isBriefing: Bool
    let onSelect: (AutonomySection) -> Void
    let onRunBrief: () -> Void

    var body: some View {
        AutonomyPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("At a Glance")
                            .font(.headline)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        onRunBrief()
                    } label: {
                        if isBriefing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Brief me", systemImage: "sparkles")
                        }
                    }
                    .disabled(isLoading || isBriefing)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    AutonomySignalCard(
                        title: "Review",
                        value: reviewValue,
                        detail: reviewDetail,
                        systemImage: "checklist",
                        tint: reviewTint,
                        action: { onSelect(.review) }
                    )
                    AutonomySignalCard(
                        title: "Latest Brief",
                        value: briefValue,
                        detail: briefDetail,
                        systemImage: "doc.text",
                        tint: .blue,
                        action: { onSelect(.brief) }
                    )
                    AutonomySignalCard(
                        title: "Last Run",
                        value: runValue,
                        detail: runDetail,
                        systemImage: "clock.arrow.circlepath",
                        tint: latestRun.map { $0.status.tint } ?? .secondary,
                        action: { onSelect(.runs) }
                    )
                    AutonomySignalCard(
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
    }

    private var statusText: String {
        if isLoading && summary == nil {
            return "Loading status"
        }
        if let summary {
            return "Updated \(AutonomyView.dateTime.string(from: summary.updatedAt))"
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
            return AutonomyView.dateTime.string(from: createdAt)
        }
        return "Run one now"
    }

    private var runValue: String {
        latestRun?.status.displayText ?? "None"
    }

    private var runDetail: String {
        if let latestRun {
            return AutonomyView.dateTime.string(from: latestRun.updatedAt)
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
}

private struct AutonomySignalCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                    Text(title)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.medium))

                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.28)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }
}

private enum AutonomySection: String, CaseIterable, Identifiable {
    case brief
    case review
    case runs
    case memory
    case routines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: return "Brief"
        case .review: return "Review"
        case .runs: return "Recent Runs"
        case .memory: return "Memory"
        case .routines: return "Routines"
        }
    }
}

private struct BriefSection: View {
    let brief: DailyBrief?

    var body: some View {
        AutonomyPanel {
            if let brief {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Latest Brief")
                            .font(.headline)
                        Spacer()
                        Text(AutonomyView.dateTime.string(from: brief.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(brief.summary)
                        .font(.callout)
                        .textSelection(.enabled)

                    ForEach(brief.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(section.items, id: \.self) { item in
                                Text(item)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            } else {
                EmptyPanelText("No brief yet.")
            }
        }
    }
}

private struct ReviewSection: View {
    let cards: [ReviewCard]
    let actingReviewCardID: String?
    let onResolve: (ReviewCard, RecommendedAction) -> Void
    let onOpenConversation: (String?, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if cards.isEmpty {
                AutonomyPanel {
                    EmptyPanelText("No open review cards.")
                }
            } else {
                ForEach(cards) { card in
                    AutonomyPanel {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(card.title)
                                    .font(.headline)
                                Spacer()
                                Text(card.kind.displayText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text(card.body)
                                .font(.callout)
                                .textSelection(.enabled)

                            HStack(spacing: 6) {
                                Text("Recommended: \(card.recommendedAction.displayText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(card.reviewFlags, id: \.rawValue) { flag in
                                    Text(flag.displayText)
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.secondary.opacity(0.10), in: Capsule())
                                }
                            }

                            HStack {
                                Spacer()
                                Button("Dismiss") {
                                    onResolve(card, .dismiss)
                                }
                                Button(card.recommendedAction.displayText) {
                                    if card.recommendedAction == .openConversation {
                                        onOpenConversation(card.conversationId, card.threadId)
                                    } else {
                                        onResolve(card, card.recommendedAction)
                                    }
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                            .disabled(actingReviewCardID == card.id)
                        }
                    }
                }
            }
        }
    }
}

private struct RunsSection: View {
    let runs: [RoutineRun]

    var body: some View {
        AutonomyPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Runs")
                    .font(.headline)

                if runs.isEmpty {
                    EmptyPanelText("No recent runs.")
                } else {
                    ForEach(runs) { run in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(run.status.tint)
                                .frame(width: 7, height: 7)
                            Text(run.status.displayText)
                                .frame(width: 92, alignment: .leading)
                            Text(run.routineId)
                                .lineLimit(1)
                            Spacer()
                            Text(AutonomyView.dateTime.string(from: run.updatedAt))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }
}

private struct MemorySection: View {
    let memories: [KishMemory]
    let counts: AutonomyMemoryCounts?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let counts {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                    StatusRow(title: "Active", value: "\(counts.active)", tint: .green)
                    StatusRow(title: "Pinned", value: "\(counts.pinned)", tint: .blue)
                    StatusRow(title: "Needs Review", value: "\(counts.needsReview)", tint: counts.needsReview > 0 ? .orange : .secondary)
                    StatusRow(title: "Conflicted", value: "\(counts.conflicted)", tint: counts.conflicted > 0 ? .red : .secondary)
                }
            }

            AutonomyPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Memory")
                        .font(.headline)

                    if memories.isEmpty {
                        EmptyPanelText("No memory available.")
                    } else {
                        ForEach(memories) { memory in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(memory.summary ?? memory.text)
                                    .font(.caption)
                                    .lineLimit(3)
                                HStack {
                                    Text(memory.state.rawValue.capitalized)
                                    Text("\(Int(memory.confidence * 100))%")
                                    Text(AutonomyView.dateTime.string(from: memory.updatedAt))
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}

private struct RoutinesSection: View {
    let routines: [KishRoutine]
    let counts: AutonomyRoutineCounts?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let counts {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                    StatusRow(title: "Enabled", value: "\(counts.enabled)", tint: .green)
                    StatusRow(title: "Proposed", value: "\(counts.proposed)", tint: counts.proposed > 0 ? .orange : .secondary)
                    StatusRow(title: "Paused", value: "\(counts.paused)", tint: .secondary)
                    StatusRow(title: "Disabled", value: "\(counts.disabled)", tint: .secondary)
                }
            }

            AutonomyPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Routines")
                        .font(.headline)

                    if routines.isEmpty {
                        EmptyPanelText("No routines available.")
                    } else {
                        ForEach(routines) { routine in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(routine.state.tint)
                                    .frame(width: 7, height: 7)
                                Text(routine.name)
                                    .lineLimit(1)
                                Spacer()
                                Text(routine.state.displayText)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }
}

private struct LoadingPanel: View {
    var body: some View {
        AutonomyPanel {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Autonomy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct EmptyPanelText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AutonomyPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

private extension ReviewCardKind {
    var displayText: String {
        rawValue.camelCaseDisplay
    }
}

private extension RecommendedAction {
    var displayText: String {
        rawValue.camelCaseDisplay
    }
}

private extension MemoryReviewFlag {
    var displayText: String {
        rawValue.camelCaseDisplay
    }
}

private extension RoutineRunState {
    var displayText: String {
        rawValue.camelCaseDisplay
    }

    var tint: Color {
        switch self {
        case .done:
            return .green
        case .failed:
            return .red
        case .needsReview, .needsApproval, .running, .queued:
            return .orange
        }
    }
}

private extension RoutineState {
    var displayText: String {
        rawValue.capitalized
    }

    var tint: Color {
        switch self {
        case .enabled:
            return .green
        case .proposed:
            return .orange
        case .paused, .disabled:
            return .secondary
        }
    }
}

private extension String {
    var camelCaseDisplay: String {
        reduce(into: "") { output, character in
            if character.isUppercase && !output.isEmpty {
                output.append(" ")
            }
            output.append(character)
        }
        .capitalized
    }
}
