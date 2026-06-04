import Foundation

struct Project: Codable, Equatable, Identifiable, Hashable {
    var id: String { path ?? "home" }

    let name: String
    let path: String?
    let relPath: String
    let branch: String?
    let lastModified: Date?

    init(
        name: String,
        path: String?,
        relPath: String? = nil,
        branch: String? = nil,
        lastModified: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.relPath = relPath ?? name
        self.branch = branch
        self.lastModified = lastModified
    }

    static let home = Project(name: "Home", path: nil, relPath: "~")
}

struct ProjectListResponse: Decodable, Equatable {
    let ok: Bool
    let projects: [Project]?
    let error: String?
}

struct PinnedProject: Codable, Equatable, Identifiable, Hashable {
    var id: String { path }

    let name: String
    let path: String
    let relPath: String
    let branch: String?

    init(project: Project) {
        self.name = project.name
        self.path = project.path ?? ""
        self.relPath = project.relPath
        self.branch = project.branch
    }

    init(name: String, path: String, relPath: String, branch: String? = nil) {
        self.name = name
        self.path = path
        self.relPath = relPath
        self.branch = branch
    }

    var project: Project {
        Project(name: name, path: path, relPath: relPath, branch: branch)
    }
}
