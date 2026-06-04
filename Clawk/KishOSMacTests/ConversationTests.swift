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
}
