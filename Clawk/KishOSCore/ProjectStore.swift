import Foundation

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var pinned: [PinnedProject]

    private let userDefaults: UserDefaults
    private let key: String

    init(userDefaults: UserDefaults = .standard, key: String = "KishOSPinnedProjects") {
        self.userDefaults = userDefaults
        self.key = key
        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([PinnedProject].self, from: data) {
            self.pinned = decoded
        } else {
            self.pinned = []
        }
    }

    func pin(_ project: Project?) {
        guard let project, let path = project.path, !path.isEmpty else { return }
        let pinnedProject = PinnedProject(project: project)
        pinned.removeAll { $0.path == path }
        pinned.insert(pinnedProject, at: 0)
        pinned = Array(pinned.prefix(12))
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(pinned) else { return }
        userDefaults.set(data, forKey: key)
    }
}

@MainActor
final class ReferenceFavoriteStore: ObservableObject {
    @Published private(set) var favorites: [ChatReference]

    private let userDefaults: UserDefaults
    private let key: String

    init(userDefaults: UserDefaults = .standard, key: String = "KishOSFavoriteReferences") {
        self.userDefaults = userDefaults
        self.key = key
        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ChatReference].self, from: data) {
            self.favorites = decoded
        } else {
            self.favorites = []
        }
    }

    func isFavorite(_ reference: ChatReference) -> Bool {
        favorites.contains { Self.favoriteKey($0) == Self.favoriteKey(reference) }
    }

    func toggle(_ reference: ChatReference) {
        if isFavorite(reference) {
            remove(reference)
        } else {
            add(reference)
        }
    }

    func remove(_ reference: ChatReference) {
        let key = Self.favoriteKey(reference)
        favorites.removeAll { Self.favoriteKey($0) == key }
        persist()
    }

    private func add(_ reference: ChatReference) {
        let key = Self.favoriteKey(reference)
        favorites.removeAll { Self.favoriteKey($0) == key }
        favorites.insert(reference, at: 0)
        favorites = Array(favorites.prefix(24))
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        userDefaults.set(data, forKey: key)
    }

    private static func favoriteKey(_ reference: ChatReference) -> String {
        "\(reference.kind.rawValue):\(normalizedPath(reference.path)):\(reference.branch ?? "")"
    }

    private static func normalizedPath(_ path: String) -> String {
        var clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.count > 1 && clean.hasSuffix("/") {
            clean.removeLast()
        }
        return clean
    }
}

@MainActor
final class ProjectCatalog: ObservableObject {
    @Published private(set) var recents: [Project] = []
    @Published private(set) var all: [Project] = []
    @Published private(set) var errorMessage: String?

    func loadRecents(client: KishAgentClient) async {
        do {
            recents = try await client.fetchProjects(all: false)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadAll(client: KishAgentClient) async {
        do {
            all = try await client.fetchProjects(all: true)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func merge(recents: [Project], pinned: [PinnedProject]) -> [Project] {
        let pinnedProjects = pinned.map(\.project)
        let pinnedPaths = Set(pinnedProjects.compactMap(\.path))
        return pinnedProjects + recents.filter { project in
            guard let path = project.path else { return true }
            return !pinnedPaths.contains(path)
        }
    }

    static func filter(_ projects: [Project], query: String) -> [Project] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return projects }
        return projects.filter { project in
            project.name.localizedCaseInsensitiveContains(clean)
                || project.relPath.localizedCaseInsensitiveContains(clean)
                || (project.path?.localizedCaseInsensitiveContains(clean) == true)
                || (project.branch?.localizedCaseInsensitiveContains(clean) == true)
        }
    }
}
