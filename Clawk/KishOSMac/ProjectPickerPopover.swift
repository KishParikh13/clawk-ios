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
                }
            }
        }
        .padding(14)
        .frame(width: 360, height: 460)
        .task {
            await catalog.loadRecents(client: client)
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
        Button {
            select(project.path == nil ? nil : project)
        } label: {
            ProjectPopoverRow(project: project)
        }
        .buttonStyle(.plain)
    }

    private func select(_ project: Project?) {
        pinned.pin(project)
        onSelect(project)
        onClose()
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
