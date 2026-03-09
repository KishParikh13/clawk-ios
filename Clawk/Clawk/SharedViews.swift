import SwiftUI

// MARK: - Flow Layout (shared)
/// Responsive flow layout that wraps children to new rows

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + result.positions[index].x,
                             y: bounds.minY + result.positions[index].y),
                proposal: .unspecified
            )
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
                self.size.width = max(self.size.width, x)
            }
            self.size.height = y + rowHeight
        }
    }
}

// MARK: - Status Dot (shared)

struct StatusDot: View {
    let status: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colorForStatus)
                .frame(width: 6, height: 6)
            Text(status)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var colorForStatus: Color {
        switch status {
        case "active", "running", "ok", "success": return .green
        case "pending", "queued": return .blue
        case "completed", "done": return .gray
        case "blocked", "error", "failed": return .red
        case "idle": return .orange
        default: return .orange
        }
    }
}

// MARK: - Status Badge (shared)

struct StatusBadge: View {
    let status: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(status)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .cornerRadius(8)
    }

    private var color: Color {
        switch status {
        case "active": return .green
        case "idle": return .orange
        case "completed", "done": return .gray
        case "error", "failed": return .red
        default: return .blue
        }
    }
}

// MARK: - Empty State View (shared)

struct EmptyStateView: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(message)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding()
    }
}

// MARK: - Stat Card (shared)

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(color)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Stat Badge (shared)

struct StatBadge: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .cornerRadius(8)
    }
}

// MARK: - Corner Radius Extension

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Token Formatting Helper

func formatTokens(_ tokens: Int) -> String {
    if tokens >= 1_000_000 {
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    } else if tokens >= 1_000 {
        return String(format: "%.1fK", Double(tokens) / 1_000)
    }
    return "\(tokens)"
}

// MARK: - Time Ago Helper

func timeAgo(from dateString: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
    guard let date = date else { return dateString }
    let relativeFormatter = RelativeDateTimeFormatter()
    return relativeFormatter.localizedString(for: date, relativeTo: Date())
}

// MARK: - Cost Display Helpers

enum CostDisplayMode: String, CaseIterable, Identifiable {
    case apiEquivalent = "api_equivalent"
    case effectiveBilled = "effective_billed"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apiEquivalent:
            return "API Equivalent"
        case .effectiveBilled:
            return "Effective Billed"
        }
    }
}

struct CostDisplayPreferences {
    static let modeKey = "costDisplayMode"
    static let openAISubscriptionKey = "costIncludesOpenAISubscription"
    static let anthropicSubscriptionKey = "costIncludesAnthropicSubscription"

    let mode: CostDisplayMode
    let openAISubscription: Bool
    let anthropicSubscription: Bool

    var usesEffectiveBilledCost: Bool {
        mode == .effectiveBilled
    }

    var appliesSubscriptionCoverage: Bool {
        usesEffectiveBilledCost && (openAISubscription || anthropicSubscription)
    }

    static var current: CostDisplayPreferences {
        let defaults = UserDefaults.standard
        return CostDisplayPreferences(
            mode: CostDisplayMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .apiEquivalent,
            openAISubscription: defaults.bool(forKey: openAISubscriptionKey),
            anthropicSubscription: defaults.bool(forKey: anthropicSubscriptionKey)
        )
    }
}

private enum BillingProvider {
    case openAI
    case anthropic
}

private func detectedBillingProvider(model: String?, source: String? = nil) -> BillingProvider? {
    let raw = [model, source]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

    guard !raw.isEmpty else { return nil }

    let tokens = Set(raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))

    if raw.contains("claude") || tokens.contains("anthropic") || tokens.contains("claude") {
        return .anthropic
    }

    if raw.contains("gpt-")
        || raw.contains("chatgpt")
        || tokens.contains("openai")
        || tokens.contains("gpt")
        || tokens.contains("codex")
        || tokens.contains("o1")
        || tokens.contains("o3")
        || tokens.contains("o4") {
        return .openAI
    }

    return nil
}

func isSubscriptionCovered(model: String?, source: String? = nil, preferences: CostDisplayPreferences) -> Bool {
    guard preferences.appliesSubscriptionCoverage else { return false }

    switch detectedBillingProvider(model: model, source: source) {
    case .openAI:
        return preferences.openAISubscription
    case .anthropic:
        return preferences.anthropicSubscription
    case .none:
        return false
    }
}

func displayedCost(_ apiCost: Double?, model: String?, source: String? = nil, preferences: CostDisplayPreferences) -> Double? {
    guard let apiCost else { return nil }
    if isSubscriptionCovered(model: model, source: source, preferences: preferences) {
        return 0
    }
    return apiCost
}

func formatCurrency(_ amount: Double, precision: Int = 2) -> String {
    let safeAmount = max(0, amount)
    return "$\(String(format: "%.\(precision)f", safeAmount))"
}

func costDisplayText(_ apiCost: Double?, model: String?, source: String? = nil, precision: Int = 2, preferences: CostDisplayPreferences) -> String? {
    guard let apiCost else { return nil }

    if isSubscriptionCovered(model: model, source: source, preferences: preferences), apiCost > 0 {
        return "Included"
    }

    guard let adjustedCost = displayedCost(apiCost, model: model, source: source, preferences: preferences),
          adjustedCost > 0 else {
        return nil
    }

    return formatCurrency(adjustedCost, precision: precision)
}
