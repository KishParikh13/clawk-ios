import XCTest
@testable import KishOS

final class LiveVoiceHeuristicsTests: XCTestCase {
    private func auto(_ text: String) -> Bool {
        LiveVoiceHeuristics.shouldAutoFinalizeUtterance(text)
    }

    func testEmptyIsFalse() {
        XCTAssertFalse(auto(""))
    }

    func testWhitespaceOnlyIsFalse() {
        XCTAssertFalse(auto("   "))
        XCTAssertFalse(auto("\n\t  "))
    }

    func testSingleLetterIsFalse() {
        XCTAssertFalse(auto("a"))
    }

    func testTwoCharSingleWordIsFalse() {
        // "ok" = 1 word, 2 chars → false
        XCTAssertFalse(auto("ok"))
    }

    func testFourCharSingleWordIsFalse() {
        // "okay" = 1 word, 4 chars → false
        XCTAssertFalse(auto("okay"))
    }

    func testGoIsFalse() {
        // "go" = 1 word, 2 chars → false
        XCTAssertFalse(auto("go"))
    }

    func testTwoWordsIsTrue() {
        // "yes please" = 2 words → true
        XCTAssertTrue(auto("yes please"))
    }

    func testGoNowIsTrue() {
        // "go now" = 2 words → true
        XCTAssertTrue(auto("go now"))
    }

    func testLongSingleWordIsTrue() {
        // "affirmative" = 1 word, 11 chars → true
        XCTAssertTrue(auto("affirmative"))
    }

    // MARK: - Exact boundaries

    func testSevenCharSingleWordIsFalse() {
        // 7 non-whitespace chars, 1 word → false
        XCTAssertEqual("seven12".count, 7)
        XCTAssertFalse(auto("seven12"))
    }

    func testEightCharSingleWordIsTrue() {
        // 8 non-whitespace chars, 1 word → true
        XCTAssertEqual("eight123".count, 8)
        XCTAssertTrue(auto("eight123"))
    }

    func testEightCharBoundaryIgnoresWhitespace() {
        // "abc defg" = 2 words → true via word count regardless of chars,
        // but confirm an 8-char single token surrounded by spaces still counts
        // by char rule once trimmed. Use a single 8-char word with padding.
        XCTAssertTrue(auto("  computer  ")) // 8 chars, 1 word
    }

    func testOneWordSevenCharsExactlyFalse() {
        // boundary: exactly 7 → false
        XCTAssertFalse(auto("1234567"))
    }

    func testOneWordEightCharsExactlyTrue() {
        // boundary: exactly 8 → true
        XCTAssertTrue(auto("12345678"))
    }

    // MARK: - Whitespace handling

    func testLeadingTrailingWhitespaceTrimmed() {
        XCTAssertTrue(auto("   go now   "))
        XCTAssertFalse(auto("   go   "))
    }

    func testTwoShortWordsCountByWordRule() {
        // "a b" = 2 words, 2 non-whitespace chars → true via word rule
        XCTAssertTrue(auto("a b"))
    }

    func testNewlineSeparatedWordsCountAsTwo() {
        XCTAssertTrue(auto("hi\nthere"))
    }

    func testCollapsedMultipleSpacesStillTwoWords() {
        XCTAssertTrue(auto("yes    please"))
    }
}
