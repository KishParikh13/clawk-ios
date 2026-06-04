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

    func testJSONStoreSavesAndLoadsRemoteConversationIDs() throws {
        let fileURL = temporaryFileURL()
        let store = JSONConversationStore(fileURL: fileURL)
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

        try store.saveRemoteConversationIDs([id])

        let loaded = try JSONConversationStore(fileURL: fileURL).loadRemoteConversationIDs()
        XCTAssertEqual(loaded, [id])
    }

    func testWorkspaceFollowUpKeepsSameThreadId() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let conversation = workspace.createConversation(
            firstMessage: "first",
            projectPath: "/Users/kishparikh/Code/clawk-ios",
            projectName: "clawk-ios"
        )
        let threadId = conversation.threadId

        let updated = workspace.appendUserMessage("second", to: conversation.id)

        XCTAssertEqual(updated?.threadId, threadId)
        XCTAssertEqual(updated?.projectPath, "/Users/kishparikh/Code/clawk-ios")
        XCTAssertEqual(updated?.projectName, "clawk-ios")
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

    func testCancelActiveResponseClearsRunningPlaceholderWithoutFailure() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let conversation = workspace.createConversation(firstMessage: "first")
        workspace.beginAgentResponse(in: conversation.id)

        workspace.cancelActiveResponse(in: conversation.id)

        let updated = workspace.conversation(id: conversation.id)
        XCTAssertEqual(updated?.messages.count, 1)
        XCTAssertEqual(updated?.messages.first?.sender, .user)
        XCTAssertEqual(updated?.messages.first?.deliveryState, .sent)
        XCTAssertEqual(updated?.events, ["stopped"])
        XCTAssertFalse(updated?.isRunning ?? true)
        XCTAssertNil(updated?.lastError)
        XCTAssertTrue(updated?.approvals.isEmpty == true)
        XCTAssertEqual(store.savedConversations.first?.events, ["stopped"])
    }

    func testMarkConversationReadPersistsWithoutChangingUpdatedAt() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let createdAt = Date(timeIntervalSince1970: 100)
        let conversation = workspace.createConversation(firstMessage: "first", now: createdAt)
        let replyAt = Date(timeIntervalSince1970: 200)
        workspace.apply(ChatResult(text: "reply", engine: "claude", elapsedMs: 12, events: []), to: conversation.id, now: replyAt)

        workspace.markConversationRead(conversation.id, at: replyAt)

        let updated = workspace.conversation(id: conversation.id)
        XCTAssertEqual(updated?.updatedAt, replyAt)
        XCTAssertEqual(updated?.lastReadAt, replyAt)
        XCTAssertFalse(updated?.isUnread == true)
        XCTAssertEqual(store.savedConversations.first?.lastReadAt, replyAt)
    }

    func testWorkspaceMigratesLoadedConversationsWithoutReadStateAsRead() {
        let store = MemoryConversationStore()
        let updatedAt = Date(timeIntervalSince1970: 200)
        var conversation = Conversation(firstMessage: "older", now: Date(timeIntervalSince1970: 100))
        conversation.updatedAt = updatedAt
        conversation.lastReadAt = nil
        store.savedConversations = [conversation]

        let workspace = KishOSWorkspace(store: store)

        let migrated = workspace.conversation(id: conversation.id)
        XCTAssertEqual(migrated?.lastReadAt, updatedAt)
        XCTAssertFalse(migrated?.isUnread == true)
        XCTAssertEqual(store.savedConversations.first?.lastReadAt, updatedAt)
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

    func testQueueConversationSavesMessageLocallyWithoutRunning() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)

        let conversation = workspace.queueConversation(
            firstMessage: "offline",
            projectPath: "/Users/kishparikh/Code/kish-agent",
            projectName: "kish-agent"
        )

        XCTAssertEqual(conversation.messages.first?.deliveryState, .queued)
        XCTAssertEqual(conversation.projectPath, "/Users/kishparikh/Code/kish-agent")
        XCTAssertEqual(conversation.projectName, "kish-agent")
        XCTAssertFalse(conversation.isRunning)
        XCTAssertEqual(workspace.queuedMessageCount, 1)
        XCTAssertEqual(store.savedConversations.first?.messages.first?.deliveryState, .queued)
        XCTAssertEqual(store.savedConversations.first?.projectName, "kish-agent")
    }

    func testNextQueuedMessageReturnsOldestAndPrepareMarksSending() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let newer = workspace.queueConversation(firstMessage: "newer", now: Date(timeIntervalSince1970: 200))
        let older = workspace.queueConversation(firstMessage: "older", now: Date(timeIntervalSince1970: 100))

        let queued = workspace.nextQueuedMessage()

        XCTAssertEqual(queued?.conversation.id, older.id)
        XCTAssertEqual(queued?.message.text, "older")

        let prepared = workspace.prepareQueuedMessageForSending(
            conversationID: older.id,
            messageID: queued!.message.id,
            now: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(prepared?.message, "older")
        XCTAssertEqual(workspace.conversation(id: older.id)?.messages.first?.deliveryState, .sending)
        XCTAssertTrue(workspace.conversation(id: older.id)?.isRunning == true)
        XCTAssertEqual(workspace.conversation(id: newer.id)?.messages.first?.deliveryState, .queued)
    }

    func testQueuedMessagePreservesAttachmentsAndPreparesContextPayload() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let attachment = ChatAttachment.textContext("local note", title: "Clipboard")
        let conversation = workspace.queueConversation(firstMessage: "use this", attachments: [attachment])
        let messageID = conversation.messages[0].id

        let prepared = workspace.prepareQueuedMessageForSending(
            conversationID: conversation.id,
            messageID: messageID
        )

        XCTAssertEqual(workspace.conversation(id: conversation.id)?.messages.first?.attachments, [attachment])
        XCTAssertEqual(
            prepared?.message,
            """
            [Context 1: Clipboard]
            local note
            [/Context 1]

            User message:
            use this
            """
        )
    }

    func testQueuedMessagePreservesReferencesAndPreparesContextPayload() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let reference = ChatReference(kind: .folder, title: "kish-agent", path: "/Users/kishparikh/Code/kish-agent")
        let conversation = workspace.queueConversation(firstMessage: "check this", references: [reference])
        let messageID = conversation.messages[0].id

        let prepared = workspace.prepareQueuedMessageForSending(
            conversationID: conversation.id,
            messageID: messageID
        )

        XCTAssertEqual(workspace.conversation(id: conversation.id)?.messages.first?.references, [reference])
        XCTAssertEqual(prepared?.references, [
            ChatRequestReference(path: "/Users/kishparikh/Code/kish-agent", title: "kish-agent", kind: "folder")
        ])
        XCTAssertEqual(
            prepared?.message,
            """
            [Context 1: Folder reference @kish-agent]
            Path: /Users/kishparikh/Code/kish-agent
            [/Context 1]

            User message:
            check this
            """
        )
    }

    func testOfflineFailureRequeuesMessageAndRemovesEmptyAgentPlaceholder() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let conversation = workspace.createConversation(firstMessage: "send")
        let messageID = conversation.messages[0].id

        workspace.beginAgentResponse(in: conversation.id)
        let requeued = workspace.requeueMessageAfterOfflineFailure(conversationID: conversation.id, messageID: messageID)

        XCTAssertTrue(requeued)
        let updated = workspace.conversation(id: conversation.id)
        XCTAssertEqual(updated?.messages.count, 1)
        XCTAssertEqual(updated?.messages.first?.deliveryState, .queued)
        XCTAssertFalse(updated?.isRunning == true)
        XCTAssertNil(updated?.lastError)
    }

    func testOfflineFailureDoesNotRequeueAfterAgentProgress() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let conversation = workspace.createConversation(firstMessage: "send")
        let messageID = conversation.messages[0].id

        workspace.beginAgentResponse(in: conversation.id)
        workspace.appendStreamingText("partial", to: conversation.id)

        let requeued = workspace.requeueMessageAfterOfflineFailure(conversationID: conversation.id, messageID: messageID)

        XCTAssertFalse(requeued)
        XCTAssertEqual(workspace.conversation(id: conversation.id)?.messages.first?.deliveryState, .sending)
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

    func testRemoteMergePreservesLocalReadStateOnNewerRemoteConversation() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let older = Date(timeIntervalSince1970: 100)
        let readAt = Date(timeIntervalSince1970: 150)
        let newer = Date(timeIntervalSince1970: 200)
        var local = Conversation(id: id, firstMessage: "local", now: older)
        local.updatedAt = older
        local.lastReadAt = readAt
        var remote = Conversation(id: id, firstMessage: "remote", now: older)
        remote.updatedAt = newer
        remote.lastReadAt = nil

        workspace.mergeRemoteConversations([local])
        workspace.mergeRemoteConversations([remote])

        let merged = workspace.conversation(id: id)
        XCTAssertEqual(merged?.title, "remote")
        XCTAssertEqual(merged?.updatedAt, newer)
        XCTAssertEqual(merged?.lastReadAt, readAt)
        XCTAssertTrue(merged?.isUnread == true)
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
        workspace.mergeRemoteConversations([oldConversation, newConversation])

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

    func testRemoteMergeRemovesPreviouslySeenConversationMissingFromRemote() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let remote = Conversation(id: id, firstMessage: "remote")

        workspace.mergeRemoteConversations([remote])
        workspace.mergeRemoteConversations([])

        XCTAssertNil(workspace.conversation(id: id))
        XCTAssertTrue(store.savedConversations.isEmpty)
        XCTAssertEqual(store.savedDeletedConversationIDs, [id])
        XCTAssertTrue(store.savedRemoteConversationIDs.isEmpty)
    }

    func testRemoteMergeEmptyResponsePreservesLocalOnlyConversation() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let local = workspace.createConversation(firstMessage: "local draft")

        workspace.mergeRemoteConversations([])

        XCTAssertEqual(workspace.conversation(id: local.id)?.title, "local draft")
        XCTAssertEqual(store.savedConversations.first?.id, local.id)
        XCTAssertTrue(store.savedDeletedConversationIDs.isEmpty)
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

    func testApprovalAnswerRejectedClearsPendingApproval() {
        let store = MemoryConversationStore()
        let workspace = KishOSWorkspace(store: store)
        let conversation = workspace.createConversation(firstMessage: "first")
        let approval = makeApproval(id: "approval-1", threadId: conversation.threadId)

        workspace.setApprovals([approval], for: conversation.id)
        workspace.recordApprovalAnswerRejected(approval.id, in: conversation.id)

        let updated = workspace.conversation(id: conversation.id)
        XCTAssertEqual(updated?.approvals, [])
        XCTAssertTrue(updated?.events.contains("cancelled question") == true)
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
    var savedRemoteConversationIDs: Set<UUID> = []

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

    func loadRemoteConversationIDs() throws -> Set<UUID> {
        savedRemoteConversationIDs
    }

    func saveRemoteConversationIDs(_ ids: Set<UUID>) throws {
        savedRemoteConversationIDs = ids
    }
}
