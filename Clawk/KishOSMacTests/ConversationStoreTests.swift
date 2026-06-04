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

    func testJSONStoreSavesAndLoadsDeletedConversationIDs() throws {
        let fileURL = temporaryFileURL()
        let store = JSONConversationStore(fileURL: fileURL)
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

        try store.saveDeletedConversationIDs([id])

        let loaded = try JSONConversationStore(fileURL: fileURL).loadDeletedConversationIDs()
        XCTAssertEqual(loaded, [id])
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
        XCTAssertEqual(store.savedDeletedConversationIDs, [conversation.id])
    }

    func testRemoteMergeKeepsNewerLocalConversation() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        var local = Conversation(id: id, firstMessage: "local", now: older)
        local.updatedAt = newer
        var remote = Conversation(id: id, firstMessage: "remote", now: older)
        remote.updatedAt = older

        workspace.mergeRemoteConversations([local])
        workspace.mergeRemoteConversations([remote])

        let merged = workspace.conversation(id: id)
        XCTAssertEqual(merged?.title, "local")
        XCTAssertEqual(merged?.updatedAt, newer)
        XCTAssertEqual(store.savedConversations.first?.title, "local")
    }

    func testRemoteMergeAppliesNewerRemoteConversation() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        var local = Conversation(id: id, firstMessage: "local", now: older)
        local.updatedAt = older
        var remote = Conversation(id: id, firstMessage: "remote", now: older)
        remote.updatedAt = newer

        workspace.mergeRemoteConversations([local])
        workspace.mergeRemoteConversations([remote])

        let merged = workspace.conversation(id: id)
        XCTAssertEqual(merged?.title, "remote")
        XCTAssertEqual(merged?.updatedAt, newer)
        XCTAssertEqual(store.savedConversations.first?.title, "remote")
    }

    func testRemoteMergeAddsNewConversationAndSortsByUpdatedAt() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        var oldConversation = Conversation(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            firstMessage: "old",
            now: older
        )
        oldConversation.updatedAt = older
        var newConversation = Conversation(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            firstMessage: "new",
            now: newer
        )
        newConversation.updatedAt = newer

        workspace.mergeRemoteConversations([oldConversation])
        workspace.mergeRemoteConversations([newConversation])

        XCTAssertEqual(workspace.conversations.map(\.title), ["new", "old"])
        XCTAssertEqual(store.savedConversations.map(\.title), ["new", "old"])
    }

    func testRemoteMergeDoesNotResurrectLocallyDeletedConversation() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        var remote = Conversation(id: id, firstMessage: "remote", now: older)
        remote.updatedAt = newer

        workspace.mergeRemoteConversations([remote])
        workspace.deleteConversation(id)
        workspace.mergeRemoteConversations([remote])

        XCTAssertNil(workspace.conversation(id: id))
        XCTAssertTrue(store.savedConversations.isEmpty)
        XCTAssertEqual(store.savedDeletedConversationIDs, [id])
    }

    func testApprovalAnswerAcceptedClearsPendingApproval() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let conversation = workspace.createConversation(firstMessage: "first")
        let approval = makeApproval(id: "approval-1", threadId: conversation.threadId)

        workspace.setApprovals([approval], for: conversation.id)
        workspace.recordApprovalAnswerAccepted(approval.id, in: conversation.id)

        let updated = workspace.conversation(id: conversation.id)
        XCTAssertEqual(updated?.approvals, [])
        XCTAssertTrue(updated?.events.contains("answered question") == true)
        XCTAssertEqual(store.savedConversations.first?.approvals, [])
    }

    func testApprovalAnswerFailureKeepsPendingApproval() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let conversation = workspace.createConversation(firstMessage: "first")
        let approval = makeApproval(id: "approval-1", threadId: conversation.threadId)

        workspace.setApprovals([approval], for: conversation.id)
        workspace.recordApprovalAnswerFailure("approval not found", in: conversation.id)

        let updated = workspace.conversation(id: conversation.id)
        XCTAssertEqual(updated?.approvals, [approval])
        XCTAssertTrue(updated?.events.contains("approval not found") == true)
        XCTAssertEqual(store.savedConversations.first?.approvals, [approval])
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("conversations.json")
    }

    private func makeApproval(id: String, threadId: String) -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            threadId: threadId,
            questions: [
                ApprovalQuestion(
                    header: "Question",
                    question: "Continue?",
                    multiSelect: false,
                    options: [ApprovalOption(label: "Yes", description: "Continue")]
                )
            ],
            createdAt: 1760000000,
            expiresAt: 1760000300,
            summary: "Continue?"
        )
    }
}

private final class MemoryConversationStore: ConversationStoring {
    var savedConversations: [Conversation] = []
    var savedDeletedConversationIDs: Set<UUID> = []

    func load() throws -> [Conversation] {
        savedConversations
    }

    func save(_ conversations: [Conversation]) throws {
        savedConversations = conversations
    }

    func loadDeletedConversationIDs() throws -> Set<UUID> {
        savedDeletedConversationIDs
    }

    func saveDeletedConversationIDs(_ ids: Set<UUID>) throws {
        savedDeletedConversationIDs = ids
    }
}
