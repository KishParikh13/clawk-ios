import SwiftUI

struct ProjectPickerSheet: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var catalog: ProjectCatalog
    @ObservedObject var pinned: ProjectStore
    let onSelect: (Project?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var customPath = ""
    @State private var showingAll = false

    private var quickProjects: [Project] {
        ProjectCatalog.filter(ProjectCatalog.merge(recents: catalog.recents, pinned: pinned.pinned), query: query)
    }

    private var allProjects: [Project] {
        ProjectCatalog.filter(catalog.all, query: query)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    projectButton(.home)
                }

                Section("Pinned and Recent") {
                    if quickProjects.isEmpty {
                        Text(catalog.errorMessage ?? "No recent folders")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(quickProjects) { project in
                            projectButton(project)
                        }
                    }
                }

                Section("Browse") {
                    Button {
                        showingAll = true
                        Task {
                            await catalog.loadAll(client: client)
                        }
                    } label: {
                        Label("All Code folders", systemImage: "folder")
                    }

                    if showingAll {
                        ForEach(allProjects) { project in
                            projectButton(project)
                        }
                    }
                }

                Section("Path") {
                    HStack(spacing: 8) {
                        TextField("~/Code/project", text: $customPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button("Use") {
                            select(customProject)
                        }
                        .disabled(customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Project")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await catalog.loadRecents(client: client)
            }
        }
    }

    private var customProject: Project {
        let clean = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = clean.hasPrefix("~/") ? clean : clean
        let name = expanded.split(separator: "/").last.map(String.init) ?? expanded
        return Project(name: name.isEmpty ? expanded : name, path: expanded, relPath: expanded)
    }

    private func projectButton(_ project: Project) -> some View {
        Button {
            select(project.path == nil ? nil : project)
        } label: {
            ProjectPickerRow(project: project)
        }
    }

    private func select(_ project: Project?) {
        pinned.pin(project)
        onSelect(project)
        dismiss()
    }
}

private struct ProjectPickerRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: project.path == nil ? "house" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
}
