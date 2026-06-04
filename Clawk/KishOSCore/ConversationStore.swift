import Foundation

protocol ConversationStoring {
    func load() throws -> [Conversation]
    func save(_ conversations: [Conversation]) throws
}

struct JSONConversationStore: ConversationStoring {
    let fileURL: URL
    var encoder = JSONEncoder()
    var decoder = JSONDecoder()

    init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
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

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("KishOS", isDirectory: true)
            .appendingPathComponent("conversations.json")
    }
}
