import XCTest
@testable import KishOS

@MainActor
final class ProjectStoreTests: XCTestCase {
    func testProjectStorePinsMostRecentProjectAndPersists() {
        let suiteName = "ProjectStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "PinnedProjects"
        let store = ProjectStore(userDefaults: defaults, key: key)
        let project = Project(
            name: "clawk-ios",
            path: "/Users/kishparikh/Code/clawk-ios",
            relPath: "~/Code/clawk-ios",
            branch: "main"
        )

        store.pin(project)

        XCTAssertEqual(store.pinned.count, 1)
        XCTAssertEqual(store.pinned.first?.name, "clawk-ios")
        XCTAssertEqual(store.pinned.first?.path, "/Users/kishparikh/Code/clawk-ios")
        XCTAssertEqual(ProjectStore(userDefaults: defaults, key: key).pinned, store.pinned)
    }

    func testProjectCatalogMergeAndFilter() {
        let pinned = [
            PinnedProject(name: "outside", path: "/Users/kishparikh/Desktop/outside", relPath: "~/Desktop/outside")
        ]
        let recents = [
            Project(name: "clawk-ios", path: "/Users/kishparikh/Code/clawk-ios", relPath: "~/Code/clawk-ios", branch: "main"),
            Project(name: "outside", path: "/Users/kishparikh/Desktop/outside", relPath: "~/Desktop/outside")
        ]

        let merged = ProjectCatalog.merge(recents: recents, pinned: pinned)
        let filtered = ProjectCatalog.filter(merged, query: "clawk")

        XCTAssertEqual(merged.map(\.name), ["outside", "clawk-ios"])
        XCTAssertEqual(filtered.map(\.name), ["clawk-ios"])
    }
}
