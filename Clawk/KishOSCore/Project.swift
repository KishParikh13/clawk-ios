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

struct ProjectBranch: Codable, Equatable, Identifiable, Hashable {
    var id: String { name }

    let name: String
    let isCurrent: Bool
    let isRemote: Bool
    let worktreePath: String?
}

struct ProjectBranchListResponse: Decodable, Equatable {
    let ok: Bool
    let branches: [ProjectBranch]?
    let error: String?
}

struct ProjectFile: Codable, Equatable, Identifiable, Hashable {
    var id: String { path }

    let name: String
    let path: String
    let relPath: String
    let repoPath: String?
    let branch: String?
    let lastModified: Date?
    let size: Int64?

    init(
        name: String,
        path: String,
        relPath: String,
        repoPath: String? = nil,
        branch: String? = nil,
        lastModified: Date? = nil,
        size: Int64? = nil
    ) {
        self.name = name
        self.path = path
        self.relPath = relPath
        self.repoPath = repoPath
        self.branch = branch
        self.lastModified = lastModified
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case relPath
        case repoPath
        case branch
        case lastModified
        case modifiedAt
        case modified
        case modifiedTime
        case updatedAt
        case mtime
        case mtimeMs
        case modifiedMs
        case lastModifiedMs
        case size
        case byteSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        relPath = try container.decode(String.self, forKey: .relPath)
        repoPath = try container.decodeIfPresent(String.self, forKey: .repoPath)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        lastModified = Self.decodeDate(
            from: container,
            keys: [.lastModified, .modifiedAt, .modified, .modifiedTime, .updatedAt, .mtime, .mtimeMs, .modifiedMs, .lastModifiedMs]
        )
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
            ?? container.decodeIfPresent(Int64.self, forKey: .byteSize)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(relPath, forKey: .relPath)
        try container.encodeIfPresent(repoPath, forKey: .repoPath)
        try container.encodeIfPresent(branch, forKey: .branch)
        try container.encodeIfPresent(lastModified, forKey: .lastModified)
        try container.encodeIfPresent(size, forKey: .size)
    }

    private static func decodeDate(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Date? {
        for key in keys {
            if let date = try? container.decodeIfPresent(Date.self, forKey: key) {
                return date
            }
            if let rawString = try? container.decodeIfPresent(String.self, forKey: key),
               let date = ISO8601DateFormatter().date(from: rawString) {
                return date
            }
            if let rawNumber = try? container.decodeIfPresent(Double.self, forKey: key) {
                let seconds = rawNumber > 10_000_000_000 ? rawNumber / 1_000 : rawNumber
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }
}

struct ProjectFileListResponse: Decodable, Equatable {
    let ok: Bool
    let files: [ProjectFile]?
    let truncated: Bool?
    let error: String?
}

enum ProjectDirtyAction: String, Codable, Equatable, CaseIterable {
    case stash
    case discard
    case wipCommit = "wip_commit"
}

struct ProjectDirtySummary: Codable, Equatable {
    let isDirty: Bool
    let changedFiles: [String]
}

struct ProjectBranchSwitchResponse: Decodable, Equatable {
    let ok: Bool
    let project: Project?
    let error: String?
    let requiresDirtyAction: Bool?
    let dirtySummary: ProjectDirtySummary?
    let usedExistingWorktree: Bool?
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
