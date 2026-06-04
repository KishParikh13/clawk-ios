import Foundation

protocol ConversationStoring {
    func load() throws -> [Conversation]
    func save(_ conversations: [Conversation]) throws
    func loadDeletedConversationIDs() throws -> Set<UUID>
    func saveDeletedConversationIDs(_ ids: Set<UUID>) throws
}

extension ConversationStoring {
    func loadDeletedConversationIDs() throws -> Set<UUID> {
        []
    }

    func saveDeletedConversationIDs(_ ids: Set<UUID>) throws {}
}

struct JSONConversationStore: ConversationStoring {
    let fileURL: URL
    let deletedConversationIDsURL: URL
    var encoder = JSONEncoder()
    var decoder = JSONDecoder()

    init(fileURL: URL = Self.defaultFileURL(), deletedConversationIDsURL: URL? = nil) {
        self.fileURL = fileURL
        self.deletedConversationIDsURL = deletedConversationIDsURL ?? Self.defaultDeletedConversationIDsURL(for: fileURL)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> [Conversation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([Conversation].self, from: data)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ conversations: [Conversation]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(conversations)
        try data.write(to: fileURL, options: [.atomic])
    }

    func loadDeletedConversationIDs() throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: deletedConversationIDsURL.path) else {
            return []
        }

        let data = try Data(contentsOf: deletedConversationIDsURL)
        return Set(try decoder.decode([UUID].self, from: data))
    }

    func saveDeletedConversationIDs(_ ids: Set<UUID>) throws {
        let directory = deletedConversationIDsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sortedIDs = ids.sorted { $0.uuidString < $1.uuidString }
        let data = try encoder.encode(sortedIDs)
        try data.write(to: deletedConversationIDsURL, options: [.atomic])
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("KishOS", isDirectory: true)
            .appendingPathComponent("conversations.json")
    }

    private static func defaultDeletedConversationIDsURL(for fileURL: URL) -> URL {
        fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("deleted-conversations.json")
    }
}
