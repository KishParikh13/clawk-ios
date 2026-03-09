import SwiftUI

// Legacy DashboardView removed — replaced by:
// - LiveOverviewTab, LiveAgentsTab, LiveSessionsTab (LiveDashboardTabs.swift)
// - CronManagementView.swift
// - CostsView.swift
// - ApprovalQueueView.swift

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
