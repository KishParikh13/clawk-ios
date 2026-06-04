import SwiftUI

struct ProjectPickerPopover: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var catalog: ProjectCatalog
    @ObservedObject var pinned: ProjectStore
    let onSelect: (Project?) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var customPath = ""
    @State private var showingAll = false
    @State private var branchProject: Project?
    @State private var branches: [ProjectBranch] = []
    @State private var isLoadingBranches = false
    @State private var branchError: String?
    @State private var switchError: String?
    @State private var pendingBranchSwitch: PendingBranchSwitch?
    @State private var showingDirtyPrompt = false

    private var quickProjects: [Project] {
        ProjectCatalog.filter(ProjectCatalog.merge(recents: catalog.recents, pinned: pinned.pinned), query: query)
    }

    private var allProjects: [Project] {
        ProjectCatalog.filter(catalog.all, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Project")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    section("Home") {
                        projectButton(.home)
                    }

                    section("Pinned and Recent") {
                        if quickProjects.isEmpty {
                            Text(catalog.errorMessage ?? "No recent folders")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(quickProjects) { project in
                                projectButton(project)
                            }
                        }
                    }

                    section("Browse") {
                        Button {
                            showingAll = true
                            Task {
                                await catalog.loadAll(client: client)
                            }
                        } label: {
                            Label("All Code folders", systemImage: "folder")
                        }
                        .buttonStyle(.plain)

                        if showingAll {
                            ForEach(allProjects) { project in
                                projectButton(project)
                            }
                        }
                    }

                    section("Path") {
                        HStack(spacing: 8) {
                            TextField("~/Code/project", text: $customPath)
                                .textFieldStyle(.roundedBorder)

                            Button("Use") {
                                select(customProject)
                            }
                            .disabled(customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if let branchProject {
                        branchSection(branchProject)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360, height: 460)
        .task {
            await catalog.loadRecents(client: client)
        }
        .confirmationDialog(
            "Save changes before switching branches?",
            isPresented: $showingDirtyPrompt,
            titleVisibility: .visible
        ) {
            Button("Stash changes") {
                retryPendingBranchSwitch(action: .stash)
            }
            Button("Commit as WIP") {
                retryPendingBranchSwitch(action: .wipCommit)
            }
            Button("Discard changes", role: .destructive) {
                retryPendingBranchSwitch(action: .discard)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(dirtyPromptMessage)
        }
    }

    private var customProject: Project {
        let clean = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = clean.split(separator: "/").last.map(String.init) ?? clean
        return Project(name: name.isEmpty ? clean : name, path: clean, relPath: clean)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func projectButton(_ project: Project) -> some View {
        HStack(spacing: 6) {
            Button {
                select(project.path == nil ? nil : project)
            } label: {
                ProjectPopoverRow(project: project)
            }
            .buttonStyle(.plain)

            if project.path != nil {
                Button {
                    loadBranches(for: project)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Switch branch")
            }
        }
    }

    private func select(_ project: Project?) {
        pinned.pin(project)
        onSelect(project)
        onClose()
    }

    @ViewBuilder
    private func branchSection(_ project: Project) -> some View {
        section("Branches") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(project.name)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if isLoadingBranches {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let branchError {
                    Text(branchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let switchError {
                    Text(switchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if branches.isEmpty && !isLoadingBranches {
                    Text("No branches found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(branches) { branch in
                        branchButton(branch, project: project)
                    }
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func branchButton(_ branch: ProjectBranch, project: Project) -> some View {
        Button {
            switchBranch(branch, project: project)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(branch.name)
                        .font(.caption)
                        .lineLimit(1)
                    if let worktreePath = branch.worktreePath, worktreePath != project.path {
                        Text(worktreePath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if branch.isRemote {
                        Text("remote")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadBranches(for project: Project) {
        guard let path = project.path else { return }
        branchProject = project
        branches = []
        branchError = nil
        switchError = nil
        isLoadingBranches = true
        Task {
            do {
                branches = try await client.fetchProjectBranches(projectPath: path)
                branchError = nil
            } catch {
                branchError = error.localizedDescription
            }
            isLoadingBranches = false
        }
    }

    private func switchBranch(_ branch: ProjectBranch, project: Project, dirtyAction: ProjectDirtyAction? = nil) {
        guard let path = project.path else { return }
        pendingBranchSwitch = nil
        switchError = nil
        Task {
            do {
                let result = try await client.switchProjectBranch(projectPath: path, branch: branch.name, dirtyAction: dirtyAction)
                if result.requiresDirtyAction == true {
                    pendingBranchSwitch = PendingBranchSwitch(project: project, branch: branch, dirtyFiles: result.dirtySummary?.changedFiles ?? [])
                    showingDirtyPrompt = true
                } else if result.ok {
                    select(result.project ?? Project(name: project.name, path: path, relPath: project.relPath, branch: branch.name))
                } else {
                    switchError = result.error ?? "Could not switch branch"
                }
            } catch {
                switchError = error.localizedDescription
            }
        }
    }

    private func retryPendingBranchSwitch(action: ProjectDirtyAction) {
        guard let pendingBranchSwitch else { return }
        switchBranch(pendingBranchSwitch.branch, project: pendingBranchSwitch.project, dirtyAction: action)
    }

    private var dirtyPromptMessage: String {
        guard let files = pendingBranchSwitch?.dirtyFiles, !files.isEmpty else {
            return "This project has uncommitted changes."
        }
        let shown = files.prefix(4).joined(separator: ", ")
        let suffix = files.count > 4 ? " and \(files.count - 4) more" : ""
        return "Uncommitted changes: \(shown)\(suffix)"
    }
}

private struct PendingBranchSwitch {
    let project: Project
    let branch: ProjectBranch
    let dirtyFiles: [String]

    init(project: Project, branch: ProjectBranch, dirtyFiles: [String] = []) {
        self.project = project
        self.branch = branch
        self.dirtyFiles = dirtyFiles
    }
}

private struct ProjectPopoverRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.path == nil ? "house" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var detail: String {
        if let branch = project.branch, !branch.isEmpty {
            return "\(project.relPath) - \(branch)"
        }
        return project.relPath
    }
}
