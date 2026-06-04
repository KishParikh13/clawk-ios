import XCTest
@testable import KishOS

@MainActor
final class ConversationTests: XCTestCase {
    func testConversationTitleTrimsWhitespace() {
        XCTAssertEqual(Conversation.title(for: "  check logs  "), "check logs")
    }

    func testConversationTitleTruncatesLongPrompts() {
        let title = Conversation.title(for: "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz")

        XCTAssertEqual(title.count, 44)
        XCTAssertTrue(title.hasSuffix("..."))
    }

    func testNewConversationUsesStableThreadIdFromConversationId() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let conversation = Conversation(id: id, firstMessage: "hello")

        XCTAssertEqual(conversation.threadId, "mac-11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(conversation.messages.first?.text, "hello")
    }

    func testChatAttachmentDecodesOlderTextAttachmentWithoutUploadFields() throws {
        let json = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "kind": "text",
          "title": "Clipboard",
          "text": "hello",
          "createdAt": "2026-06-04T05:20:00.000Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let attachment = try decoder.decode(ChatAttachment.self, from: json)

        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.uploadState, .ready)
        XCTAssertNil(attachment.uploadId)
        XCTAssertNil(attachment.localFilename)
    }

    func testAgentStatusUsesPendingQuestion() {
        var conversation = Conversation(firstMessage: "book a flight")
        conversation.approvals = [
            ApprovalRequest(
                id: "approval-1",
                threadId: conversation.threadId,
                questions: [
                    ApprovalQuestion(
                        header: "Question 1",
                        question: "Which flight should I book?",
                        multiSelect: false,
                        options: []
                    )
                ],
                createdAt: nil,
                expiresAt: nil,
                summary: "Choose a flight"
            )
        ]

        XCTAssertEqual(conversation.agentStatusSummary?.tone, .needsAnswer)
        XCTAssertEqual(conversation.agentStatusSummary?.title, "Needs answer")
        XCTAssertEqual(conversation.agentStatusSummary?.detail, "Which flight should I book?")
    }

    func testAgentStatusShowsQueuedMessages() {
        var conversation = Conversation(firstMessage: "check this later")
        conversation.messages[0].deliveryState = .queued

        XCTAssertEqual(conversation.agentStatusSummary?.tone, .queued)
        XCTAssertEqual(conversation.agentStatusSummary?.title, "Saved locally")
        XCTAssertEqual(conversation.agentStatusSummary?.detail, "1 message will send when connected.")
    }

    func testAgentStatusFiltersDuplicateActivity() {
        var conversation = Conversation(firstMessage: "summarize the repo")
        conversation.isRunning = true
        conversation.messages.append(
            ChatMessage(
                sender: .agent,
                text: "I found the main app structure.",
                deliveryState: .sending,
                activityEvents: [
                    "waiting for reply",
                    "tool: Reading project files",
                    "summarize the repo",
                    "I found the main app structure."
                ]
            )
        )

        XCTAssertEqual(conversation.agentStatusSummary?.tone, .working)
        XCTAssertEqual(conversation.agentStatusSummary?.title, "Using tools")
        XCTAssertEqual(conversation.agentStatusSummary?.detail, "Reading project files")
    }
}
