import SwiftUI

enum ProjectPickerMode {
    case project
    case referenceFiles
}

private enum ProjectPickerStep: Equatable {
    case project
    case branch
    case branchStatus
    case files
    case fileDetail
    case referenceReview
}

private enum ProjectPickerRoute: Hashable {
    case branch
    case branchStatus
    case files(String, Int)
    case fileDetail(Int)
    case referenceReview(Int)

    var step: ProjectPickerStep {
        switch self {
        case .branch:
            return .branch
        case .branchStatus:
            return .branchStatus
        case .files:
            return .files
        case .fileDetail:
            return .fileDetail
        case .referenceReview:
            return .referenceReview
        }
    }
}

struct ProjectPickerSheet: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var catalog: ProjectCatalog
    @ObservedObject var pinned: ProjectStore
    @StateObject private var referenceFavorites = ReferenceFavoriteStore()
    var title = "Project"
    var includesHome = true
    var pinsSelection = true
    var mode: ProjectPickerMode = .project
    var selectedProject: Project?
    var initialReferenceProject: Project?
    var initialBranchProject: Project?
    var startsAtBranch = false
    let onSelect: (Project?) -> Void
    var onSelectReferences: ([ChatReference]) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var branchQuery = ""
    @State private var fileQuery = ""
    @State private var navigationPath: [ProjectPickerRoute] = []
    @State private var showingAll = false
    @State private var step: ProjectPickerStep = .project
    @State private var branchProject: Project?
    @State private var selectedBranch: ProjectBranch?
    @State private var expandedProjectPath: String?
    @State private var branches: [ProjectBranch] = []
    @State private var files: [ProjectFile] = []
    @State private var selectedFilePaths: Set<String> = []
    @State private var selectedFileReferences: [String: ChatReference] = [:]
    @State private var selectedFolderReferences: [String: ChatReference] = [:]
    @State private var pendingReferenceKeys: Set<String> = []
    @State private var fileSelectionHostPath: String?
    @State private var fileSelectionBranchName: String?
    @State private var fileProject: Project?
    @State private var selectedFile: ProjectFile?
    @State private var fileBrowserRelPath = ""
    @State private var fileBrowserBackStack: [String] = []
    @State private var fileDisplayLimit = 10
    @State private var referenceRootDisplayLimit = 10
    @State private var isLoadingBranches = false
    @State private var isLoadingFiles = false
    @State private var branchError: String?
    @State private var fileError: String?
    @State private var switchError: String?
    @State private var pendingBranchSwitch: PendingBranchSwitch?
    @State private var showingDirtyPrompt = false
    @State private var didApplyInitialReferenceProject = false
    @State private var isSearchPresented = false
    @State private var navigationToken = 0

    private var displayedProjects: [Project] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredPath = initialReferenceProject?.path
        let base: [Project]
        if showingAll || !cleanQuery.isEmpty {
            base = ProjectCatalog.merge(recents: catalog.all, pinned: pinned.pinned)
        } else {
            base = ProjectCatalog.merge(recents: catalog.recents, pinned: pinned.pinned)
        }
        return ProjectCatalog.filter(base, query: query).filter { project in
            guard let preferredPath, let path = project.path else { return true }
            return path != preferredPath
        }
    }

    private var filteredBranches: [ProjectBranch] {
        let cleanQuery = branchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return branches }
        return branches.filter { branch in
            branch.name.localizedCaseInsensitiveContains(cleanQuery)
                || branch.worktreePath?.localizedCaseInsensitiveContains(cleanQuery) == true
        }
    }

    private var filteredFiles: [ProjectFile] {
        let cleanQuery = fileQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentFolderFiles = files.filter { file in
            guard shouldIncludeProjectFile(file) else { return false }
            return relativeFilePath(file, in: fileBrowserRelPath) != nil
        }
        guard !cleanQuery.isEmpty else { return currentFolderFiles }
        return currentFolderFiles.filter { file in
            guard let localPath = relativeFilePath(file, in: fileBrowserRelPath) else { return false }
            return localPath.localizedCaseInsensitiveContains(cleanQuery)
                || file.name.localizedCaseInsensitiveContains(cleanQuery)
        }
    }

    private var visibleFileTreeFiles: [ProjectFile] {
        filteredFiles
    }

    private var fileTree: [ProjectFileTreeNode] {
        ProjectFileTreeBuilder.children(for: visibleFileTreeFiles, in: fileBrowserRelPath)
    }

    private var codeRootFolderNodes: [ReferenceFolderTreeNode] {
        guard isCodeRootFolder else { return [] }
        let cleanQuery = fileQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = ProjectCatalog.merge(recents: catalog.recents, pinned: pinned.pinned)
            + catalog.all
            + [initialReferenceProject].compactMap { $0 }
        var entries: [String: (project: Project, order: Int, forceVisible: Bool)] = [:]

        for (index, project) in sources.enumerated() {
            guard let child = codeRootChildProject(from: project) else { continue }
            let key = normalizedReferencePath(child.path ?? child.relPath)
            if let existing = entries[key] {
                entries[key] = (
                    preferredCodeRootProject(existing.project, child),
                    min(existing.order, index),
                    existing.forceVisible
                )
            } else {
                entries[key] = (child, index, false)
            }
        }

        for (index, node) in fileTree.enumerated() where node.file == nil {
            let childPath = "~/Code/\(node.name)"
            let child = Project(
                name: node.name,
                path: childPath,
                relPath: childPath,
                lastModified: node.latestModified
            )
            let key = normalizedReferencePath(childPath)
            let order = sources.count + index
            if let existing = entries[key] {
                entries[key] = (
                    preferredCodeRootProject(existing.project, child),
                    min(existing.order, order),
                    existing.forceVisible || isSearchingFiles
                )
            } else {
                entries[key] = (child, order, isSearchingFiles)
            }
        }

        let filtered = entries.values.filter { entry in
            guard !cleanQuery.isEmpty else { return true }
            if entry.forceVisible {
                return true
            }
            return ProjectCatalog.filter([entry.project], query: cleanQuery).isEmpty == false
        }

        return filtered
            .sorted { lhs, rhs in
                if let lhsDate = lhs.project.lastModified, let rhsDate = rhs.project.lastModified, lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                if lhs.project.lastModified != nil && rhs.project.lastModified == nil {
                    return true
                }
                if lhs.project.lastModified == nil && rhs.project.lastModified != nil {
                    return false
                }
                if lhs.order != rhs.order {
                    return lhs.order < rhs.order
                }
                return lhs.project.name.localizedCaseInsensitiveCompare(rhs.project.name) == .orderedAscending
            }
            .map { entry in
                ReferenceFolderTreeNode(
                    id: normalizedReferencePath(entry.project.path ?? entry.project.relPath),
                    name: entry.project.name,
                    project: entry.project,
                    children: []
                )
            }
    }

    private var visibleCodeRootFolderNodes: [ReferenceFolderTreeNode] {
        if isSearchingFiles {
            return codeRootFolderNodes
        }
        return Array(codeRootFolderNodes.prefix(fileDisplayLimit))
    }

    private var visibleFileTree: [ProjectFileTreeNode] {
        if isSearchingFiles {
            return fileTree
        }
        return Array(fileTree.prefix(fileDisplayLimit))
    }

    private var hasMoreFileTreeItems: Bool {
        !isSearchingFiles && activeFileListCount > visibleFileListCount
    }

    private var shouldShowFileTreeCount: Bool {
        activeFileListCount > 0 && (activeFileListCount != visibleFileListCount || isSearchingFiles || isCodeRootFolder)
    }

    private var activeFileListCount: Int {
        isCodeRootFolder ? codeRootFolderNodes.count : fileTree.count
    }

    private var visibleFileListCount: Int {
        isCodeRootFolder ? visibleCodeRootFolderNodes.count : visibleFileTree.count
    }

    private var hasFileListContent: Bool {
        isCodeRootFolder ? !codeRootFolderNodes.isEmpty : !filteredFiles.isEmpty
    }

    private var isSearchingFiles: Bool {
        !fileQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isCodeRootFolder: Bool {
        normalizedReferencePath(fileProject?.path ?? "") == "~/Code" && fileBrowserRelPath.isEmpty
    }

    private var selectedReferenceCount: Int {
        selectedFileReferences.count + selectedFolderReferences.count
    }

    private var selectedReferences: [ChatReference] {
        let folderReferences = selectedFolderReferences.values.sorted { lhs, rhs in
            lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
        let fileReferences = selectedFileReferences.values.sorted { lhs, rhs in
            lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
        return folderReferences + fileReferences
    }

    private var visibleFavoriteReferences: [ChatReference] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return referenceFavorites.favorites }
        return referenceFavorites.favorites.filter { reference in
            reference.title.localizedCaseInsensitiveContains(cleanQuery)
                || reference.path.localizedCaseInsensitiveContains(cleanQuery)
                || reference.relPath?.localizedCaseInsensitiveContains(cleanQuery) == true
        }
    }

    private var referenceRootTree: [ReferenceFolderTreeNode] {
        ReferenceFolderTreeBuilder.roots(for: referenceRootProjects)
    }

    private var visibleReferenceRootTree: [ReferenceFolderTreeNode] {
        Array(referenceRootTree.prefix(referenceRootDisplayLimit))
    }

    private var hasMoreReferenceRoots: Bool {
        referenceRootTree.count > visibleReferenceRootTree.count
    }

    private var referenceRootProjects: [Project] {
        let fixedRoots = [
            Project(name: "Code", path: "~/Code", relPath: "~/Code"),
            Project(name: "Desktop", path: "~/Desktop", relPath: "~/Desktop"),
            Project(name: "Downloads", path: "~/Downloads", relPath: "~/Downloads"),
        ]
        let catalogProjects = ProjectCatalog.merge(
            recents: catalog.all.isEmpty ? catalog.recents : catalog.all,
            pinned: pinned.pinned
        )
        let combined = fixedRoots + catalogProjects + [initialReferenceProject].compactMap { $0 }
        var seen = Set<String>()
        let unique = combined.compactMap { project -> Project? in
            let key = normalizedReferencePath(project.path ?? project.relPath)
            guard !key.isEmpty, !seen.contains(key) else { return nil }
            seen.insert(key)
            return project
        }
        return ProjectCatalog.filter(unique, query: query)
    }

    private var pathSearchProject: Project? {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("/") || clean.hasPrefix("~/") || clean.hasPrefix("./") || clean.hasPrefix("../") else {
            return nil
        }
        let name = clean.split(separator: "/").last.map(String.init) ?? clean
        return Project(name: name.isEmpty ? clean : name, path: clean, relPath: clean)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            pickerList(for: .project)
                .navigationDestination(for: ProjectPickerRoute.self) { route in
                    pickerList(for: route.step)
                }
                .task {
                    await catalog.loadRecents(client: client)
                    if mode == .referenceFiles {
                        await catalog.loadAll(client: client)
                    }
                    applyInitialBranchProjectIfNeeded()
                }
                .onChange(of: navigationPath) { _, newPath in
                    step = newPath.last?.step ?? .project
                }
                .onChange(of: isSearchPresented) { _, isPresented in
                    guard isPresented, step == .project, query.isEmpty else { return }
                    query = "~/"
                    Task {
                        await catalog.loadAll(client: client)
                    }
                }
                .onChange(of: query) { _, newValue in
                    guard step == .project else { return }
                    let clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    referenceRootDisplayLimit = 10
                    Task {
                        await catalog.loadAll(client: client)
                    }
                }
                .onChange(of: fileQuery) { _, _ in
                    fileDisplayLimit = initialFileDisplayLimit(for: fileBrowserRelPath)
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
    }

    private func pickerList(for listStep: ProjectPickerStep) -> some View {
        List {
            switch listStep {
            case .project:
                projectListSections
            case .branch:
                branchListSections
            case .branchStatus:
                branchStatusSections
            case .files:
                fileListSection
            case .fileDetail:
                fileDetailSections
            case .referenceReview:
                referenceReviewSections
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.custom(12))
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle(title(for: listStep))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if listStep == .project {
                    Button("Cancel") {
                        dismiss()
                    }
                } else {
                    Button("Back") {
                        goBack()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if mode == .referenceFiles && (listStep == .project || listStep == .files) {
                    Button(addButtonTitle) {
                        navigateForward(to: .referenceReview)
                    }
                    .disabled(selectedReferenceCount == 0)
                } else if mode == .project && listStep == .project {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if listStep == .referenceReview {
                Button {
                    finishReferenceSelection()
                } label: {
                    Text(finalAddButtonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedReferenceCount == 0)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(.regularMaterial)
            }
        }
        .searchable(text: searchBinding(for: listStep), isPresented: $isSearchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt(for: listStep))
    }

    private func selectionControl(isSelected: Bool, isUpdating: Bool, size: CGFloat = 20) -> some View {
        ZStack {
            if isUpdating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: isSelected ? "minus.circle" : "plus.circle")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 44, height: 36)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var projectListSections: some View {
        if mode == .referenceFiles {
            Section {
                ReferenceHomeDefaultRow()
            }

            if !visibleFavoriteReferences.isEmpty {
                Section("Favorites") {
                    ForEach(visibleFavoriteReferences) { reference in
                        ReferenceFavoriteRow(
                            reference: reference,
                            isSelected: isReferenceSelected(reference),
                            onToggleSelected: {
                                toggleFavoriteReferenceSelection(reference)
                            },
                            onUnfavorite: {
                                referenceFavorites.remove(reference)
                            },
                            onOpen: {
                                openFavoriteReference(reference)
                            }
                        )
                    }
                }
            }

            if let pathSearchProject {
                Button {
                    open(project: pathSearchProject)
                } label: {
                    Label(pathSearchProject.relPath, systemImage: "folder.badge.questionmark")
                }
            }

            Section {
                if referenceRootTree.isEmpty {
                    Text(catalog.errorMessage ?? "No folders")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleReferenceRootTree) { node in
                        ReferenceFolderTreeRow(
                            node: node,
                            depth: 0,
                            isSelected: { selectedFolderReferences[folderSelectionKey($0.path ?? $0.relPath)] != nil },
                            isUpdating: { pendingReferenceKeys.contains(folderSelectionKey($0.path ?? $0.relPath)) },
                            onToggle: toggleReferenceFolder,
                            onOpen: open(project:)
                        )
                    }

                    if hasMoreReferenceRoots {
                        Button {
                            loadMoreReferenceRoots()
                        } label: {
                            Label("Load 10 more", systemImage: "plus.circle")
                        }
                    }
                }
            } footer: {
                Text("Home is default. Add refs for specificity.")
            }
        } else {
            Button {
                showingAll = true
                Task {
                    await catalog.loadAll(client: client)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)

                    Text("Browse all folders")
                        .foregroundStyle(Color.accentColor)
                }
            }

            if includesHome {
                projectButton(.home, showsDetail: false)
            }

            if let pathSearchProject {
                Button {
                    open(project: pathSearchProject)
                } label: {
                    Label(pathSearchProject.relPath, systemImage: "folder.badge.questionmark")
                }
            }

            if displayedProjects.isEmpty {
                Text(catalog.errorMessage ?? "No folders")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayedProjects) { project in
                    projectButton(project)
                }
            }
        }
    }

    @ViewBuilder
    private var branchListSections: some View {
        if let branchProject {
            selectedProjectSection(branchProject)

            if mode == .referenceFiles {
                Section {
                    Button {
                        loadFiles(for: branchProject, hostPath: branchProject.path, branchName: branchProject.branch)
                    } label: {
                        Label("Browse current files", systemImage: "folder")
                    }
                }
            }

            Section("Select Branch") {
                if isLoadingBranches {
                    Label {
                        Text("Loading branches")
                            .foregroundStyle(.secondary)
                    } icon: {
                        ProgressView()
                    }
                } else if let branchError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(branchError)
                            .font(.caption)
                            .foregroundStyle(.red)
                        if mode == .referenceFiles {
                            Button {
                                loadFiles(for: branchProject, hostPath: branchProject.path)
                            } label: {
                                Label("Browse files anyway", systemImage: "folder")
                            }
                        }
                    }
                } else if let switchError {
                    Text(switchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if branches.isEmpty {
                    Button {
                        if mode == .referenceFiles {
                            loadFiles(for: branchProject, hostPath: branchProject.path)
                        } else {
                            select(branchProject)
                        }
                    } label: {
                        Label(mode == .referenceFiles ? "Browse files" : "Use this project", systemImage: "folder")
                    }
                } else if filteredBranches.isEmpty {
                    Text("No branches match")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredBranches) { branch in
                        branchButton(branch, project: branchProject)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var branchStatusSections: some View {
        if let branchProject, let selectedBranch {
            selectedProjectSection(branchProject)

            Section("Branch") {
                LabeledContent("Name", value: selectedBranch.name)
                LabeledContent("Status", value: selectedBranch.isCurrent ? "Current branch" : selectedBranch.isRemote ? "Remote branch" : "Local branch")
                if let worktreePath = selectedBranch.worktreePath {
                    LabeledContent("Worktree", value: worktreePath)
                }
            }

            Section("Git status") {
                if let switchError {
                    Text(switchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let pending = pendingBranchSwitch,
                          pending.project.path == branchProject.path,
                          pending.branch.name == selectedBranch.name {
                    if pending.dirtyFiles.isEmpty {
                        Text("There are uncommitted changes, but the server did not return file names.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pending.dirtyFiles, id: \.self) { file in
                            Label(file, systemImage: "exclamationmark.circle")
                                .font(.callout)
                        }
                    }
                } else {
                    Text("Git status will be checked before switching branches.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Options") {
                if let pending = pendingBranchSwitch,
                   pending.project.path == branchProject.path,
                   pending.branch.name == selectedBranch.name {
                    Button {
                        retryPendingBranchSwitch(action: .stash)
                    } label: {
                        Label("Stash changes and switch", systemImage: "tray.and.arrow.down")
                    }

                    Button {
                        retryPendingBranchSwitch(action: .wipCommit)
                    } label: {
                        Label("Commit WIP and switch", systemImage: "checkmark.circle")
                    }

                    Button(role: .destructive) {
                        retryPendingBranchSwitch(action: .discard)
                    } label: {
                        Label("Discard changes and switch", systemImage: "trash")
                    }
                } else {
                    Button {
                        switchBranch(selectedBranch, project: branchProject)
                    } label: {
                        Label(selectedBranch.isCurrent ? "Use current branch" : "Switch to this branch", systemImage: "arrow.triangle.branch")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var fileListSection: some View {
        if fileProject != nil {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentFolderTitle)
                            .font(.headline)
                        if let detail = currentFolderDetail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if let currentFolderReference {
                        Button {
                            referenceFavorites.toggle(currentFolderReference)
                        } label: {
                            Image(systemName: referenceFavorites.isFavorite(currentFolderReference) ? "star.fill" : "star")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 44, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                    Button {
                        toggleCurrentFolderReference()
                    } label: {
                        selectionControl(
                            isSelected: isCurrentFolderSelected,
                            isUpdating: currentFolderReference.map { pendingReferenceKeys.contains(folderSelectionKey($0.path)) } ?? false,
                            size: 22
                        )
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }

            Section {
                inlineBranchPicker
            }

            Section {
                if isLoadingFiles && !hasFileListContent {
                    Label {
                        Text("Loading files")
                            .foregroundStyle(.secondary)
                    } icon: {
                        ProgressView()
                    }
                } else if let fileError, !isCodeRootFolder {
                    Text(fileError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !hasFileListContent {
                    Text(isSearchingFiles ? "No files match" : "No files found")
                        .foregroundStyle(.secondary)
                } else {
                    if isCodeRootFolder {
                        ForEach(visibleCodeRootFolderNodes) { node in
                            ReferenceFolderTreeRow(
                                node: node,
                                depth: 0,
                                isSelected: { selectedFolderReferences[folderSelectionKey($0.path ?? $0.relPath)] != nil },
                                isUpdating: { pendingReferenceKeys.contains(folderSelectionKey($0.path ?? $0.relPath)) },
                                onToggle: toggleReferenceFolder,
                                onOpen: open(project:)
                            )
                        }
                    } else {
                        ForEach(visibleFileTree) { node in
                            ProjectFileTreeRow(
                                node: node,
                                depth: 0,
                                isSelected: { selectedFileReferences[$0.path] != nil },
                                isFileUpdating: { pendingReferenceKeys.contains(folderSelectionKey($0.path)) },
                                isFolderSelected: { node in
                                    guard let reference = folderReference(for: node) else { return false }
                                    return selectedFolderReferences[folderSelectionKey(reference.path)] != nil
                                },
                                isFolderUpdating: { node in
                                    guard let reference = folderReference(for: node) else { return false }
                                    return pendingReferenceKeys.contains(folderSelectionKey(reference.path))
                                },
                                onToggle: toggleFile,
                                onToggleFolder: toggleFileTreeFolder,
                                onOpen: { file in
                                    selectedFile = file
                                    navigateForward(to: .fileDetail)
                                },
                                onOpenFolder: openFileTreeFolder
                            )
                        }
                    }

                    if visibleFileListCount == 0 {
                        Text("No items in \(currentFolderTitle)")
                            .foregroundStyle(.secondary)
                    }

                    if hasMoreFileTreeItems {
                        Button {
                            loadMoreFiles()
                        } label: {
                            Label("Load 10 more", systemImage: "plus.circle")
                        }
                    }

                    if shouldShowFileTreeCount {
                        Text("Showing \(visibleFileListCount) of \(activeFileListCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(isCodeRootFolder ? "Folders" : displayedFileBranch.map { "Files on \($0)" } ?? "Files")
            } footer: {
                if selectedReferenceCount == 0 {
                    Text("Select one or more files or folders.")
                }
            }
        }
    }

    @ViewBuilder
    private var inlineBranchPicker: some View {
        if mode == .referenceFiles {
            if isLoadingBranches {
                Label {
                    Text("Loading branches")
                        .foregroundStyle(.secondary)
                } icon: {
                    ProgressView()
                }
            } else if !branches.isEmpty {
                Menu {
                    ForEach(branches) { branch in
                        Button {
                            browseBranch(branch, project: branchProject ?? fileProject)
                        } label: {
                            Label(branch.name, systemImage: selectedBranchName == branch.name ? "checkmark" : "arrow.triangle.branch")
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)
                        Text("Branch")
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text(displayedFileBranch ?? "Current")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let branchError {
                Text(branchError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var fileDetailSections: some View {
        if let selectedFile {
            Section("File") {
                LabeledContent("Name", value: fileDisplayName(selectedFile))
                LabeledContent("Relative path", value: selectedFile.relPath)
                LabeledContent("Path", value: selectedFile.path)
                if let repoPath = selectedFile.repoPath {
                    LabeledContent("Repo", value: repoPath)
                }
                if let branch = selectedFile.branch ?? fileProject?.branch {
                    LabeledContent("Branch", value: branch)
                }
            }

            Section("Selection") {
                Button {
                    toggleFile(selectedFile)
                } label: {
                    Label(
                        selectedFileReferences[selectedFile.path] != nil ? "Remove from references" : "Add to references",
                        systemImage: selectedFileReferences[selectedFile.path] != nil ? "minus.circle" : "plus.circle"
                    )
                }

                if let reference = fileReference(for: selectedFile) {
                    Button {
                        referenceFavorites.toggle(reference)
                    } label: {
                        Label(
                            referenceFavorites.isFavorite(reference) ? "Unpin file" : "Pin file",
                            systemImage: referenceFavorites.isFavorite(reference) ? "star.fill" : "star"
                        )
                    }
                }
            }

            Section("Contents") {
                Text("File contents are not available from the current project files API.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var addButtonTitle: String {
        selectedReferenceCount == 0 ? "Add" : "Add \(selectedReferenceCount)"
    }

    private var finalAddButtonTitle: String {
        selectedReferenceCount == 1 ? "Add 1 reference" : "Add \(selectedReferenceCount) references"
    }

    @ViewBuilder
    private var referenceReviewSections: some View {
        Section {
            if selectedReferences.isEmpty {
                Text("No references selected")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(selectedReferences) { reference in
                    ReferenceReviewRow(reference: reference) {
                        removeReference(reference)
                    }
                }
            }
        } footer: {
            Text("Remove anything you do not want included.")
        }
    }

    private func projectButton(_ project: Project, showsDetail: Bool? = nil) -> some View {
        let isSelected = isProjectSelected(project)
        return Button {
            open(project: project)
        } label: {
            HStack(spacing: 10) {
                ProjectPickerRow(project: project, showsDetail: showsDetail ?? showsProjectDetail(project), isSelected: isSelected)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                }
                if project.path != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func isProjectSelected(_ project: Project) -> Bool {
        guard mode == .project else { return false }
        if project.path == nil {
            return selectedProject?.path == nil
        }
        return selectedProject?.path == project.path
    }

    private func showsProjectDetail(_ project: Project) -> Bool {
        project.path != nil
    }

    @ViewBuilder
    private func selectedProjectSection(_ project: Project) -> some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.headline)
                    Text(project.relPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Change") {
                    clearProjectSelection()
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }

    private func open(project: Project) {
        if project.path == nil {
            select(nil)
        } else if mode == .referenceFiles {
            loadReferenceFiles(for: project)
        } else {
            loadBranches(for: project)
        }
    }

    private func shouldBrowseFilesDirectly(_ project: Project) -> Bool {
        guard let path = project.path else { return false }
        let normalizedPath = normalizedReferencePath(path)
        if normalizedPath == "~" {
            return true
        }
        let knownPaths = Set(((catalog.recents + catalog.all).compactMap(\.path) + pinned.pinned.map(\.path)).map(normalizedReferencePath))
        return !knownPaths.contains(normalizedPath)
    }

    private func applyInitialReferenceProjectIfNeeded() {
        guard mode == .referenceFiles,
              !didApplyInitialReferenceProject,
              let project = initialReferenceProject,
              project.path != nil else { return }
        didApplyInitialReferenceProject = true
        loadReferenceFiles(for: project)
    }

    private func applyInitialBranchProjectIfNeeded() {
        guard startsAtBranch,
              !didApplyInitialReferenceProject,
              let project = initialBranchProject ?? initialReferenceProject,
              project.path != nil else { return }
        didApplyInitialReferenceProject = true
            if mode == .referenceFiles {
                loadReferenceFiles(for: project)
            } else {
            loadBranches(for: project)
        }
    }

    private func select(_ project: Project?) {
        if pinsSelection {
            pinned.pin(project)
        }
        onSelect(project)
        dismiss()
    }

    private func branchButton(_ branch: ProjectBranch, project: Project) -> some View {
        Button {
            if mode == .referenceFiles {
                browseBranch(branch, project: project)
            } else {
                selectedBranch = branch
                pendingBranchSwitch = nil
                switchError = nil
                navigateForward(to: .branchStatus)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedBranchName == branch.name ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedBranchName == branch.name ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(branch.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if branch.isCurrent {
                        Text("Current branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let worktreePath = branch.worktreePath, worktreePath != project.path {
                        Text(worktreePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if branch.isRemote {
                        Text("Remote branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func loadBranches(for project: Project) {
        guard let path = project.path else { return }
        branchProject = project
        expandedProjectPath = path
        branchQuery = ""
        branches = []
        branchError = nil
        switchError = nil
        resetFileSelection()
        isLoadingBranches = true
        navigateForward(to: .branch)
        Task {
            do {
                let loadedBranches = try await client.fetchProjectBranches(projectPath: path)
                if expandedProjectPath == path {
                    branches = loadedBranches
                    branchError = nil
                }
            } catch {
                if expandedProjectPath == path {
                    branchError = error.localizedDescription
                }
            }
            if expandedProjectPath == path {
                isLoadingBranches = false
            }
        }
    }

    private func loadReferenceFiles(for project: Project) {
        guard let path = project.path else { return }
        if normalizedReferencePath(path) == "~/Code" {
            Task {
                await catalog.loadAll(client: client)
            }
        }
        branchProject = project
        expandedProjectPath = path
        branchQuery = ""
        branches = []
        branchError = nil
        switchError = nil
        isLoadingBranches = false
        loadFiles(for: project, hostPath: project.path, branchName: project.branch)

        guard !shouldBrowseFilesDirectly(project) else { return }
        isLoadingBranches = true
        Task {
            do {
                let loadedBranches = try await client.fetchProjectBranches(projectPath: path)
                if expandedProjectPath == path {
                    branches = loadedBranches
                    branchError = nil
                }
            } catch {
                if expandedProjectPath == path {
                    branchError = error.localizedDescription
                }
            }
            if expandedProjectPath == path {
                isLoadingBranches = false
            }
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
                    selectedBranch = branch
                    step = .branchStatus
                } else if result.ok {
                    let selectedProject = result.project ?? Project(name: project.name, path: path, relPath: project.relPath, branch: branch.name)
                    if mode == .referenceFiles {
                        loadFiles(for: selectedProject, hostPath: path, branchName: branch.name, resetsFolderPath: false)
                    } else {
                        select(selectedProject)
                    }
                } else {
                    switchError = result.error ?? "Could not switch branch"
                }
            } catch {
                switchError = error.localizedDescription
            }
        }
    }

    private func browseBranch(_ branch: ProjectBranch, project: Project?) {
        guard let project, let path = project.path else { return }
        loadFiles(
            for: Project(name: project.name, path: path, relPath: project.relPath, branch: branch.name),
            hostPath: path,
            branchName: branch.name,
            resetsFolderPath: false
        )
    }

    private func retryPendingBranchSwitch(action: ProjectDirtyAction) {
        guard let pendingBranchSwitch else { return }
        switchBranch(pendingBranchSwitch.branch, project: pendingBranchSwitch.project, dirtyAction: action)
    }

    private func loadFiles(for project: Project, hostPath: String?, branchName: String? = nil, resetsFolderPath: Bool = true) {
        guard let path = project.path else { return }
        fileSelectionHostPath = hostPath ?? path
        fileSelectionBranchName = branchName
        fileProject = project
        files = []
        if resetsFolderPath {
            fileBrowserRelPath = ""
            fileBrowserBackStack = []
        }
        fileDisplayLimit = initialFileDisplayLimit(for: fileBrowserRelPath)
        fileQuery = ""
        fileError = nil
        isLoadingFiles = true
        if step == .files {
            step = .files
        } else {
            navigateForward(to: .files)
        }
        Task {
            do {
                let loadedFiles = try await client.fetchProjectFiles(projectPath: path, branch: branchName)
                if fileProject?.path == path && fileSelectionBranchName == branchName {
                    files = loadedFiles.contains { $0.lastModified != nil } ? loadedFiles.sorted(by: fileSort) : loadedFiles
                    fileError = nil
                }
            } catch {
                if fileProject?.path == path && fileSelectionBranchName == branchName {
                    fileError = error.localizedDescription
                }
            }
            if fileProject?.path == path && fileSelectionBranchName == branchName {
                isLoadingFiles = false
            }
        }
    }

    private func clearProjectSelection() {
        branchProject = nil
        expandedProjectPath = nil
        branchQuery = ""
        branches = []
        branchError = nil
        switchError = nil
        isLoadingBranches = false
        resetFileSelection()
        navigateBackward(to: .project)
    }

    private func goBack() {
        switch step {
        case .project:
            break
        case .branch:
            clearProjectSelection()
        case .branchStatus:
            selectedBranch = nil
            pendingBranchSwitch = nil
            switchError = nil
            navigateBackward(to: .branch)
        case .files:
            if mode == .referenceFiles, let previousFolder = fileBrowserBackStack.popLast() {
                fileBrowserRelPath = previousFolder
                fileDisplayLimit = initialFileDisplayLimit(for: previousFolder)
                navigateBackward(to: .files)
            } else {
                resetFileSelection()
                navigateBackward(to: mode == .referenceFiles || branchProject == nil ? .project : .branch)
            }
        case .fileDetail:
            selectedFile = nil
            navigateBackward(to: .files)
        case .referenceReview:
            let previousStep = navigationPath.dropLast().last?.step ?? .project
            navigateBackward(to: previousStep)
        }
    }

    private func fileDisplayName(_ file: ProjectFile) -> String {
        if file.name == file.relPath {
            return file.name
        }
        return file.name.isEmpty ? file.relPath : file.name
    }

    private func relativeFilePath(_ file: ProjectFile, in folderPath: String) -> String? {
        let cleanFolderPath = folderPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanFolderPath.isEmpty else {
            return file.relPath
        }
        let prefix = cleanFolderPath + "/"
        guard file.relPath.hasPrefix(prefix) else { return nil }
        return String(file.relPath.dropFirst(prefix.count))
    }

    private func shouldIncludeProjectFile(_ file: ProjectFile) -> Bool {
        let excludedParts = Set([
            ".build",
            ".cache",
            ".expo",
            ".git",
            ".gradle",
            ".next",
            ".nuxt",
            ".parcel-cache",
            ".svelte-kit",
            ".turbo",
            ".vercel",
            "Build",
            "DerivedData",
            "Pods",
            "build",
            "coverage",
            "dist",
            "node_modules",
            "out",
            "target",
            "vendor",
        ])
        let relParts = file.relPath.split(separator: "/").map(String.init)
        let pathParts = file.path.split(separator: "/").map(String.init)
        return relParts.allSatisfy { !excludedParts.contains($0) }
            && pathParts.allSatisfy { !excludedParts.contains($0) }
    }

    private func codeRootChildProject(from project: Project) -> Project? {
        let path = normalizedReferencePath(project.path ?? project.relPath)
        let prefix = "~/Code/"
        guard path.hasPrefix(prefix) else { return nil }
        let remainder = String(path.dropFirst(prefix.count))
        guard let firstPart = remainder.split(separator: "/", maxSplits: 1).first else { return nil }
        let name = String(firstPart)
        let childPath = "\(prefix)\(name)"
        let isDirectChild = remainder == name
        return Project(
            name: name,
            path: isDirectChild ? (project.path ?? childPath) : childPath,
            relPath: childPath,
            branch: isDirectChild ? project.branch : nil,
            lastModified: project.lastModified
        )
    }

    private func preferredCodeRootProject(_ lhs: Project, _ rhs: Project) -> Project {
        if let lhsDate = lhs.lastModified, let rhsDate = rhs.lastModified {
            return rhsDate > lhsDate ? rhs : lhs
        }
        if lhs.lastModified == nil && rhs.lastModified != nil {
            return rhs
        }
        return lhs
    }

    private func fileSort(_ lhs: ProjectFile, _ rhs: ProjectFile) -> Bool {
        let lhsHidden = lhs.relPath.split(separator: "/").first?.hasPrefix(".") == true
        let rhsHidden = rhs.relPath.split(separator: "/").first?.hasPrefix(".") == true
        if lhsHidden != rhsHidden {
            return !lhsHidden
        }
        if let lhsDate = lhs.lastModified, let rhsDate = rhs.lastModified, lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        if lhs.lastModified != nil && rhs.lastModified == nil {
            return true
        }
        if lhs.lastModified == nil && rhs.lastModified != nil {
            return false
        }
        let lhsDepth = lhs.relPath.filter { $0 == "/" }.count
        let rhsDepth = rhs.relPath.filter { $0 == "/" }.count
        if lhsDepth != rhsDepth {
            return lhsDepth < rhsDepth
        }
        return lhs.relPath.localizedCaseInsensitiveCompare(rhs.relPath) == .orderedAscending
    }

    private func resetFileSelection() {
        fileQuery = ""
        files = []
        fileBrowserRelPath = ""
        fileBrowserBackStack = []
        fileDisplayLimit = 10
        fileSelectionHostPath = nil
        fileSelectionBranchName = nil
        fileProject = nil
        fileError = nil
        isLoadingFiles = false
    }

    private func toggleFile(_ file: ProjectFile) {
        guard let reference = fileReference(for: file) else { return }
        markReferenceUpdating(reference.path)
        if selectedFileReferences[file.path] != nil {
            selectedFileReferences.removeValue(forKey: file.path)
            selectedFilePaths.remove(file.path)
        } else {
            selectedFileReferences[file.path] = reference
            selectedFilePaths.insert(file.path)
        }
    }

    private func toggleCurrentFolderReference() {
        guard let reference = currentFolderReference else { return }
        let key = folderSelectionKey(reference.path)
        markReferenceUpdating(reference.path)
        if selectedFolderReferences[key] != nil {
            selectedFolderReferences.removeValue(forKey: key)
        } else {
            selectedFolderReferences[key] = reference
        }
    }

    private func toggleReferenceFolder(_ project: Project) {
        guard let reference = folderReference(for: project) else { return }
        let key = folderSelectionKey(reference.path)
        markReferenceUpdating(reference.path)
        if selectedFolderReferences[key] != nil {
            selectedFolderReferences.removeValue(forKey: key)
        } else {
            selectedFolderReferences[key] = reference
        }
    }

    private func toggleFileTreeFolder(_ node: ProjectFileTreeNode) {
        guard let reference = folderReference(for: node) else { return }
        let key = folderSelectionKey(reference.path)
        markReferenceUpdating(reference.path)
        if selectedFolderReferences[key] != nil {
            selectedFolderReferences.removeValue(forKey: key)
        } else {
            selectedFolderReferences[key] = reference
        }
    }

    private func markReferenceUpdating(_ path: String) {
        let key = folderSelectionKey(path)
        pendingReferenceKeys.insert(key)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            pendingReferenceKeys.remove(key)
        }
    }

    private func openFileTreeFolder(_ node: ProjectFileTreeNode) {
        guard node.file == nil else { return }
        fileBrowserBackStack.append(fileBrowserRelPath)
        fileBrowserRelPath = node.path
        fileDisplayLimit = initialFileDisplayLimit(for: node.path)
        navigateForward(to: .files)
    }

    private func loadMoreFiles() {
        fileDisplayLimit = min(fileDisplayLimit + 10, activeFileListCount)
    }

    private func loadMoreReferenceRoots() {
        referenceRootDisplayLimit = min(referenceRootDisplayLimit + 10, referenceRootTree.count)
    }

    private func initialFileDisplayLimit(for relPath: String) -> Int {
        if normalizedReferencePath(fileProject?.path ?? "") == "~/Code", relPath.isEmpty {
            return 50
        }
        return 10
    }

    private func finishReferenceSelection() {
        let references = selectedReferences
        guard !references.isEmpty else { return }
        onSelectReferences(references)
        dismiss()
    }

    private func removeReference(_ reference: ChatReference) {
        markReferenceUpdating(reference.path)
        switch reference.kind {
        case .file:
            selectedFileReferences.removeValue(forKey: reference.path)
            selectedFilePaths.remove(reference.path)
        case .folder:
            selectedFolderReferences.removeValue(forKey: folderSelectionKey(reference.path))
        }
        if selectedReferenceCount == 0, step == .referenceReview {
            goBack()
        }
    }

    private func isReferenceSelected(_ reference: ChatReference) -> Bool {
        switch reference.kind {
        case .file:
            return selectedFileReferences[reference.path] != nil
        case .folder:
            return selectedFolderReferences[folderSelectionKey(reference.path)] != nil
        }
    }

    private func toggleFavoriteReferenceSelection(_ reference: ChatReference) {
        markReferenceUpdating(reference.path)
        switch reference.kind {
        case .file:
            if selectedFileReferences[reference.path] != nil {
                selectedFileReferences.removeValue(forKey: reference.path)
                selectedFilePaths.remove(reference.path)
            } else {
                selectedFileReferences[reference.path] = reference
                selectedFilePaths.insert(reference.path)
            }
        case .folder:
            let key = folderSelectionKey(reference.path)
            if selectedFolderReferences[key] != nil {
                selectedFolderReferences.removeValue(forKey: key)
            } else {
                selectedFolderReferences[key] = reference
            }
        }
    }

    private func openFavoriteReference(_ reference: ChatReference) {
        switch reference.kind {
        case .folder:
            let project = Project(
                name: reference.title,
                path: reference.path,
                relPath: reference.relPath ?? reference.path,
                branch: reference.branch
            )
            open(project: project)
        case .file:
            toggleFavoriteReferenceSelection(reference)
        }
    }

    private func fileReference(for file: ProjectFile) -> ChatReference? {
        ChatReference(
            kind: .file,
            title: file.relPath,
            path: file.path,
            repoPath: file.repoPath,
            branch: file.branch ?? fileProject?.branch,
            relPath: file.relPath
        )
    }

    private func folderReference(for project: Project) -> ChatReference? {
        guard let path = project.path else { return nil }
        return ChatReference(
            kind: .folder,
            title: project.relPath == project.name ? project.name : project.relPath,
            path: path,
            repoPath: project.path,
            branch: project.branch,
            relPath: project.relPath
        )
    }

    private func folderReference(for node: ProjectFileTreeNode) -> ChatReference? {
        guard node.file == nil,
              let project = fileProject,
              let basePath = fileSelectionHostPath ?? project.path else { return nil }
        let path = joinedPath(basePath, node.path)
        return ChatReference(
            kind: .folder,
            title: node.path,
            path: path,
            repoPath: project.path,
            branch: displayedFileBranch ?? project.branch,
            relPath: node.path
        )
    }

    private var currentFolderReference: ChatReference? {
        guard let project = fileProject else { return nil }
        if fileBrowserRelPath.isEmpty {
            return folderReference(for: project)
        }
        guard let basePath = fileSelectionHostPath ?? project.path else { return nil }
        let path = joinedPath(basePath, fileBrowserRelPath)
        return ChatReference(
            kind: .folder,
            title: fileBrowserRelPath,
            path: path,
            repoPath: project.path,
            branch: displayedFileBranch ?? project.branch,
            relPath: fileBrowserRelPath
        )
    }

    private var isCurrentFolderSelected: Bool {
        guard let reference = currentFolderReference else { return false }
        return selectedFolderReferences[folderSelectionKey(reference.path)] != nil
    }

    private var currentFolderTitle: String {
        if fileBrowserRelPath.isEmpty {
            return fileProject?.name ?? "Folder"
        }
        return fileBrowserRelPath.split(separator: "/").last.map(String.init) ?? fileBrowserRelPath
    }

    private var currentFolderDetail: String? {
        guard let reference = currentFolderReference else { return nil }
        let detail = reference.relPath ?? reference.path
        return detail == currentFolderTitle ? nil : detail
    }

    private var selectedBranchName: String? {
        if mode == .referenceFiles {
            return displayedFileBranch ?? branches.first(where: \.isCurrent)?.name
        }
        return branches.first(where: \.isCurrent)?.name
    }

    private var displayedFileBranch: String? {
        fileSelectionBranchName
            ?? fileProject?.branch
            ?? files.first(where: { ($0.branch ?? "").isEmpty == false })?.branch
            ?? branches.first(where: \.isCurrent)?.name
    }

    private func navigateForward(to nextStep: ProjectPickerStep) {
        step = nextStep
        guard let route = route(for: nextStep, token: navigationToken + 1) else {
            navigationPath.removeAll()
            return
        }
        navigationToken += 1
        navigationPath.append(route)
    }

    private func navigateBackward(to previousStep: ProjectPickerStep) {
        step = previousStep
        if previousStep == .project {
            navigationPath.removeAll()
        } else if !navigationPath.isEmpty {
            navigationPath.removeLast()
        }
    }

    private func route(for routeStep: ProjectPickerStep, token: Int) -> ProjectPickerRoute? {
        switch routeStep {
        case .project:
            return nil
        case .branch:
            return .branch
        case .branchStatus:
            return .branchStatus
        case .files:
            return .files(fileBrowserRelPath, token)
        case .fileDetail:
            return .fileDetail(token)
        case .referenceReview:
            return .referenceReview(token)
        }
    }

    private func title(for titleStep: ProjectPickerStep) -> String {
        switch titleStep {
        case .project:
            return mode == .referenceFiles ? "References" : "Select project"
        case .branch:
            return "Select branch"
        case .branchStatus:
            return "Branch details"
        case .files:
            return mode == .referenceFiles ? "Select references" : "Select files"
        case .fileDetail:
            return "File details"
        case .referenceReview:
            return "Review references"
        }
    }

    private func searchPrompt(for promptStep: ProjectPickerStep) -> String {
        switch promptStep {
        case .project:
            return mode == .referenceFiles ? "Search files or paste a path" : "Search projects or paste a path"
        case .branch:
            return "Search branches"
        case .branchStatus:
            return "Branch details"
        case .files:
            return "Search files"
        case .fileDetail:
            return "File details"
        case .referenceReview:
            return "Review references"
        }
    }

    private func searchBinding(for bindingStep: ProjectPickerStep) -> Binding<String> {
        switch bindingStep {
        case .project:
            return $query
        case .branch:
            return $branchQuery
        case .branchStatus:
            return $branchQuery
        case .files:
            return $fileQuery
        case .fileDetail:
            return $fileQuery
        case .referenceReview:
            return $query
        }
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
}

private struct ReferenceFolderTreeNode: Identifiable, Hashable {
    let id: String
    let name: String
    let project: Project
    let children: [ReferenceFolderTreeNode]
}

private struct ReferenceFolderTreeBuilder {
    var name: String
    var path: String
    var project: Project?
    var children: [String: ReferenceFolderTreeBuilder] = [:]

    static func roots(for projects: [Project]) -> [ReferenceFolderTreeNode] {
        var root = ReferenceFolderTreeBuilder(name: "", path: "", project: nil)
        for project in projects {
            let displayPath = referenceDisplayPath(project)
            let parts = referencePathParts(displayPath)
            guard !parts.isEmpty else { continue }
            root.insert(project, displayPath: displayPath, parts: parts[...])
        }
        return root.sortedChildren()
    }

    mutating func insert(_ project: Project, displayPath: String, parts: ArraySlice<String>) {
        guard let part = parts.first else { return }
        let childPath = path.isEmpty ? part : "\(path)/\(part)"
        let childDisplayPath = "~/" + childPath
        let fallbackProject = Project(name: part, path: childDisplayPath, relPath: childDisplayPath)
        var child = children[part] ?? ReferenceFolderTreeBuilder(name: part, path: childPath, project: fallbackProject)
        if parts.count == 1 {
            child.project = Project(
                name: project.name,
                path: project.path ?? displayPath,
                relPath: displayPath,
                branch: project.branch,
                lastModified: project.lastModified
            )
        } else {
            child.insert(project, displayPath: displayPath, parts: parts.dropFirst())
        }
        children[part] = child
    }

    func makeNode() -> ReferenceFolderTreeNode? {
        guard let project else { return nil }
        return ReferenceFolderTreeNode(
            id: normalizedReferencePath(project.path ?? project.relPath),
            name: name,
            project: project,
            children: sortedChildren()
        )
    }

    private func sortedChildren() -> [ReferenceFolderTreeNode] {
        children.values
            .compactMap { $0.makeNode() }
            .sorted { lhs, rhs in
                let order = ["Home": 0, "Code": 1, "Desktop": 2, "Downloads": 3]
                let lhsOrder = order[lhs.name] ?? Int.max
                let rhsOrder = order[rhs.name] ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

private struct ReferenceReviewRow: View {
    let reference: ChatReference
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: reference.kind == .folder ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(reference.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    private var detail: String? {
        let pathDetail = reference.relPath ?? reference.path
        let branchDetail = reference.branch.flatMap { $0.isEmpty ? nil : $0 }
        if let branchDetail, pathDetail != reference.title {
            return "\(pathDetail) - \(branchDetail)"
        }
        if let branchDetail {
            return branchDetail
        }
        return pathDetail == reference.title ? nil : pathDetail
    }
}

private struct ReferenceFavoriteRow: View {
    let reference: ChatReference
    let isSelected: Bool
    let onToggleSelected: () -> Void
    let onUnfavorite: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: reference.kind == .folder ? "folder" : "doc.text")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reference.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onToggleSelected) {
                Image(systemName: isSelected ? "minus.circle" : "plus.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Button(action: onUnfavorite) {
                Image(systemName: "star.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    private var detail: String? {
        let pathDetail = reference.relPath ?? reference.path
        if let branch = reference.branch, !branch.isEmpty, pathDetail != reference.title {
            return "\(pathDetail) - \(branch)"
        }
        if let branch = reference.branch, !branch.isEmpty {
            return branch
        }
        return pathDetail == reference.title ? nil : pathDetail
    }
}

private struct ReferenceHomeDefaultRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "house")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Home")
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Default")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
    }
}

private struct ReferenceFolderTreeRow: View {
    let node: ReferenceFolderTreeNode
    let depth: Int
    let isSelected: (Project) -> Bool
    let isUpdating: (Project) -> Bool
    let onToggle: (Project) -> Void
    let onOpen: (Project) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onOpen(node.project)
            } label: {
                folderLabel
            }
            .buttonStyle(.plain)

            Button {
                onToggle(node.project)
            } label: {
                selectionControl(isSelected: isSelected(node.project), isUpdating: isUpdating(node.project))
            }
            .buttonStyle(.borderless)

            Button {
                onOpen(node.project)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    private var folderLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if shouldShowDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var detail: String {
        if let branch = node.project.branch, !branch.isEmpty {
            return "\(node.project.relPath) - \(branch)"
        }
        return node.project.relPath
    }

    private var shouldShowDetail: Bool {
        detail != node.name && detail != node.project.path
    }

    private func selectionControl(isSelected: Bool, isUpdating: Bool) -> some View {
        ZStack {
            if isUpdating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: isSelected ? "minus.circle" : "plus.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 44, height: 36)
        .contentShape(Rectangle())
    }
}

private struct ProjectFileTreeNode: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let file: ProjectFile?
    let children: [ProjectFileTreeNode]
    let latestModified: Date?
    let sortOrder: Int

    var fileCount: Int {
        if file != nil {
            return 1
        }
        return children.reduce(0) { $0 + $1.fileCount }
    }
}

private struct ProjectFileTreeBuilder {
    var name: String
    var path: String
    var file: ProjectFile?
    var sortOrder: Int = Int.max
    var children: [String: ProjectFileTreeBuilder] = [:]

    static func roots(for files: [ProjectFile]) -> [ProjectFileTreeNode] {
        var root = ProjectFileTreeBuilder(name: "", path: "", file: nil)
        for (index, file) in files.enumerated() {
            let parts = file.relPath.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            root.insert(file, parts: parts[...], order: index)
        }
        return root.sortedChildren()
    }

    static func children(for files: [ProjectFile], in folderPath: String) -> [ProjectFileTreeNode] {
        let cleanFolderPath = folderPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanFolderPath.isEmpty else {
            return roots(for: files)
        }

        var root = ProjectFileTreeBuilder(name: "", path: cleanFolderPath, file: nil)
        let prefix = cleanFolderPath + "/"
        for (index, file) in files.enumerated() {
            guard file.relPath.hasPrefix(prefix) else { continue }
            let relativeChildPath = String(file.relPath.dropFirst(prefix.count))
            let parts = relativeChildPath.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            root.insert(file, parts: parts[...], order: index)
        }
        return root.sortedChildren()
    }

    mutating func insert(_ file: ProjectFile, parts: ArraySlice<String>, order: Int) {
        sortOrder = min(sortOrder, order)
        guard let part = parts.first else { return }
        if parts.count == 1 {
            children[part] = ProjectFileTreeBuilder(name: part, path: file.relPath, file: file, sortOrder: order)
            return
        }

        let childPath = path.isEmpty ? part : "\(path)/\(part)"
        var child = children[part] ?? ProjectFileTreeBuilder(name: part, path: childPath, file: nil)
        child.insert(file, parts: parts.dropFirst(), order: order)
        children[part] = child
    }

    func makeNode() -> ProjectFileTreeNode {
        let childNodes = sortedChildren()
        return ProjectFileTreeNode(
            id: file?.path ?? "folder:\(path)",
            name: name,
            path: path,
            file: file,
            children: childNodes,
            latestModified: file?.lastModified ?? childNodes.compactMap(\.latestModified).max(),
            sortOrder: sortOrder
        )
    }

    private func sortedChildren() -> [ProjectFileTreeNode] {
        children.values
            .map { $0.makeNode() }
            .sorted { lhs, rhs in
                let lhsIsFolder = lhs.file == nil
                let rhsIsFolder = rhs.file == nil
                if lhsIsFolder != rhsIsFolder {
                    return lhsIsFolder
                }
                if let lhsDate = lhs.latestModified, let rhsDate = rhs.latestModified, lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                if lhs.latestModified != nil && rhs.latestModified == nil {
                    return true
                }
                if lhs.latestModified == nil && rhs.latestModified != nil {
                    return false
                }
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

private struct ProjectFileTreeRow: View {
    let node: ProjectFileTreeNode
    let depth: Int
    let isSelected: (ProjectFile) -> Bool
    let isFileUpdating: (ProjectFile) -> Bool
    let isFolderSelected: (ProjectFileTreeNode) -> Bool
    let isFolderUpdating: (ProjectFileTreeNode) -> Bool
    let onToggle: (ProjectFile) -> Void
    let onToggleFolder: (ProjectFileTreeNode) -> Void
    let onOpen: (ProjectFile) -> Void
    let onOpenFolder: (ProjectFileTreeNode) -> Void

    var body: some View {
        if let file = node.file {
            fileRow(file)
        } else {
            HStack(spacing: 10) {
                Button {
                    onOpenFolder(node)
                } label: {
                    rowOpenContent {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(node.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(node.fileCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                selectionButton(isSelected: isFolderSelected(node), isUpdating: isFolderUpdating(node)) {
                    onToggleFolder(node)
                }

                Button {
                    onOpenFolder(node)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(depth) * 14)
        }
    }

    private func fileRow(_ file: ProjectFile) -> some View {
        HStack(spacing: 10) {
            Button {
                onOpen(file)
            } label: {
                rowOpenContent {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(file))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if shouldShowDetail(file) {
                            Text(file.relPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            selectionButton(isSelected: isSelected(file), isUpdating: isFileUpdating(file)) {
                onToggle(file)
            }

            Button {
                onOpen(file)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    private func rowOpenContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func selectionButton(isSelected: Bool, isUpdating: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if isUpdating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isSelected ? "minus.circle" : "plus.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 44, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private func displayName(_ file: ProjectFile) -> String {
        if file.name == file.relPath {
            return file.name
        }
        return file.name.isEmpty ? file.relPath : file.name
    }

    private func shouldShowDetail(_ file: ProjectFile) -> Bool {
        let name = displayName(file)
        return file.relPath != name
    }
}

private func referenceDisplayPath(_ project: Project) -> String {
    let raw = project.relPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("~") || raw.hasPrefix("/") {
        return normalizedReferencePath(raw)
    }
    if let path = project.path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return normalizedReferencePath(path)
    }
    return normalizedReferencePath(raw)
}

private func referencePathParts(_ path: String) -> [String] {
    let normalized = normalizedReferencePath(path)
    if normalized == "~" {
        return ["Home"]
    }
    let withoutHome = normalized.hasPrefix("~/") ? String(normalized.dropFirst(2)) : normalized
    let withoutRoot = withoutHome.hasPrefix("/") ? String(withoutHome.dropFirst()) : withoutHome
    return withoutRoot.split(separator: "/").map(String.init)
}

private func normalizedReferencePath(_ path: String) -> String {
    var clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return "" }
    let home = NSHomeDirectory()
    if clean == home {
        clean = "~"
    } else if clean.hasPrefix(home + "/") {
        clean = "~" + clean.dropFirst(home.count)
    } else if let macUserFolderPath = normalizedMacUserFolderPath(clean) {
        clean = macUserFolderPath
    }
    while clean.count > 1 && clean.hasSuffix("/") {
        clean.removeLast()
    }
    return clean
}

private func normalizedMacUserFolderPath(_ path: String) -> String? {
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count >= 3, parts[0] == "Users" else { return nil }
    let folder = parts[2]
    guard ["Code", "Desktop", "Downloads"].contains(folder) else { return nil }
    return "~/" + parts.dropFirst(2).joined(separator: "/")
}

private func folderSelectionKey(_ path: String) -> String {
    normalizedReferencePath(path)
}

private func joinedPath(_ base: String, _ relPath: String) -> String {
    let cleanBase = normalizedReferencePath(base)
    let cleanRel = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !cleanRel.isEmpty else { return cleanBase }
    if cleanBase.hasSuffix("/") {
        return cleanBase + cleanRel
    }
    return cleanBase + "/" + cleanRel
}

private struct ProjectPickerRow: View {
    let project: Project
    var showsDetail = true
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: project.path == nil ? "house" : "folder")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .foregroundStyle(.primary)
                if showsDetail && shouldShowDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
    }

    private var detail: String {
        if let branch = project.branch, !branch.isEmpty {
            return "\(project.relPath) - \(branch)"
        }
        return project.relPath
    }

    private var shouldShowDetail: Bool {
        detail != project.name && detail != project.path
    }
}
