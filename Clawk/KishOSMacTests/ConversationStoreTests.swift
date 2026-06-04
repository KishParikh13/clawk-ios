import XCTest
@testable import KishOS

@MainActor
final class ConversationStoreTests: XCTestCase {
    func testJSONStoreSavesAndLoadsConversations() throws {
        let fileURL = temporaryFileURL()
        let store = JSONConversationStore(fileURL: fileURL)
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let conversation = Conversation(id: id, firstMessage: "remember this")

        try store.save([conversation])
        let loaded = try store.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, id)
        XCTAssertEqual(loaded[0].threadId, "mac-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(loaded[0].messages.first?.text, "remember this")
    }

    func testWorkspaceFollowUpKeepsSameThreadId() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let conversation = workspace.createConversation(firstMessage: "first")
        let threadId = conversation.threadId

        let updated = workspace.appendUserMessage("second", to: conversation.id)

        XCTAssertEqual(updated?.threadId, threadId)
        XCTAssertEqual(updated?.messages.map(\.text), ["first", "second"])
        XCTAssertEqual(updated?.messages.last?.deliveryState, .sending)
    }

    func testWorkspacePersistsAfterEachMutation() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let conversation = workspace.createConversation(firstMessage: "first")

        workspace.apply(ChatResult(text: "reply", engine: "claude", elapsedMs: 12, events: ["done"]), to: conversation.id)

        XCTAssertEqual(store.savedConversations.count, 1)
        XCTAssertEqual(store.savedConversations[0].messages.map(\.text), ["first", "reply"])
        XCTAssertFalse(store.savedConversations[0].isRunning)
    }

    func testRetryLastFailedMessageKeepsThreadIdAndMarksSending() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let conversation = workspace.createConversation(firstMessage: "first")
        workspace.applyFailure(AgentClientError.requestFailed("nope"), to: conversation.id)

        let retry = workspace.prepareRetryLastFailedMessage(in: conversation.id)

        XCTAssertEqual(retry?.message, "first")
        XCTAssertEqual(retry?.conversation.threadId, conversation.threadId)
        XCTAssertEqual(retry?.conversation.messages.first?.deliveryState, .sending)
        XCTAssertNil(retry?.conversation.lastError)
    }

    func testRenameAndDeletePersist() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let conversation = workspace.createConversation(firstMessage: "first")

        workspace.renameConversation(conversation.id, title: "renamed")

        XCTAssertEqual(store.savedConversations.first?.title, "renamed")

        workspace.deleteConversation(conversation.id)

        XCTAssertTrue(store.savedConversations.isEmpty)
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("conversations.json")
    }
}

private final class MemoryConversationStore: ConversationStoring {
    var savedConversations: [Conversation] = []

    func load() throws -> [Conversation] {
        savedConversations
    }

    func save(_ conversations: [Conversation]) throws {
        savedConversations = conversations
    }
}
