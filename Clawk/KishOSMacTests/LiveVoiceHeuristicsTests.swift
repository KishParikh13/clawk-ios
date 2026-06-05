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

    // MARK: - SpokenReplyMode.spokenText

    private typealias Mode = LiveVoiceHeuristics.SpokenReplyMode

    private func spoken(_ reply: String, _ mode: Mode) -> String? {
        LiveVoiceHeuristics.spokenText(from: reply, mode: mode)
    }

    func testOffAlwaysNil() {
        XCTAssertNil(spoken("hello there", .off))
        XCTAssertNil(spoken("", .off))
        XCTAssertNil(spoken("```code```", .off))
        XCTAssertNil(spoken("a much longer reply with several words", .off))
    }

    func testFullStripsCodeFenceKeepsProse() {
        let reply = """
        Here is the plan.
        ```
        let x = 1
        print(x)
        ```
        That is all.
        """
        let result = spoken(reply, .full)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Here is the plan."))
        XCTAssertTrue(result!.contains("That is all."))
        XCTAssertFalse(result!.contains("let x = 1"))
        XCTAssertFalse(result!.contains("```"))
    }

    func testFullPreservesPlainProse() {
        let reply = "Just some normal prose with no code at all."
        XCTAssertEqual(spoken(reply, .full), reply)
    }

    func testFullEmptyAfterTrimmingIsNil() {
        XCTAssertNil(spoken("   \n  ", .full))
        // A reply that is ONLY a code fence has no prose to speak.
        XCTAssertNil(spoken("```\nlet x = 1\n```", .full))
    }

    func testConciseNormalProseIsNonNil() {
        let reply = "Deployed the change and verified it works."
        let result = spoken(reply, .concise)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, reply)
    }

    func testConciseStripsCodeAndInlineCode() {
        let reply = """
        I updated `config.swift` and ran the build.
        ```
        swift build
        ```
        It passed.
        """
        let result = spoken(reply, .concise)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.contains("swift build"))
        XCTAssertFalse(result!.contains("`"))
        XCTAssertFalse(result!.contains("config.swift"))
    }

    func testConcisePrefersFirstParagraph() {
        let reply = """
        The fix is done.

        Here are a bunch of additional details that should not be spoken aloud first.
        """
        let result = spoken(reply, .concise)
        XCTAssertEqual(result, "The fix is done.")
    }

    func testConciseCapsLength() {
        // Build a long multi-paragraph reply well over 280 chars in one paragraph.
        let sentence = "This sentence has a number of words that add up over time. "
        let longParagraph = String(repeating: sentence, count: 12) // ~700 chars
        let reply = longParagraph + "\n\nSecond paragraph that should be ignored."
        let result = spoken(reply, .concise)
        XCTAssertNotNil(result)
        // Cap is ~280 chars; ellipsis adds one. Allow a small boundary slack.
        XCTAssertLessThanOrEqual(result!.count, 281)
        // Ends sensibly: either on a sentence boundary or with a truncation mark.
        let last = result!.last!
        XCTAssertTrue(last == "." || last == "!" || last == "?" || last == "…")
        // Did not bleed into the second paragraph.
        XCTAssertFalse(result!.contains("Second paragraph"))
    }

    func testConciseMidSentenceTruncationAppendsEllipsis() {
        // A single sentence with no internal punctuation, longer than the budget,
        // must be cut on a word boundary and get an ellipsis.
        let word = "alpha "
        let oneLongSentence = String(repeating: word, count: 80) // ~480 chars, no period
        let result = spoken(oneLongSentence, .concise)
        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result!.count, 281)
        XCTAssertTrue(result!.hasSuffix("…"))
        // Cut on a word boundary: the char before the ellipsis is a full word char,
        // and there is no stray partial word fragment.
        XCTAssertTrue(result!.hasSuffix("alpha…"))
    }

    func testConciseNoTruncationHasNoEllipsis() {
        let reply = "Short enough to speak whole."
        let result = spoken(reply, .concise)
        XCTAssertEqual(result, reply)
        XCTAssertFalse(result!.hasSuffix("…"))
    }

    func testConciseEmptyAfterStrippingIsNil() {
        XCTAssertNil(spoken("```\nonly code here\n```", .concise))
        XCTAssertNil(spoken("   ", .concise))
    }

    // MARK: - SpokenReplyMode.current

    func testCurrentDefaultsToFull() {
        let key = Mode.storageKey
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        XCTAssertEqual(Mode.current, .full)
    }

    func testCurrentReadsStoredValue() {
        let key = Mode.storageKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(Mode.full.rawValue, forKey: key)
        XCTAssertEqual(Mode.current, .full)
        UserDefaults.standard.set(Mode.off.rawValue, forKey: key)
        XCTAssertEqual(Mode.current, .off)
    }

    // MARK: - SpokenReplyMode.title

    func testTitleMapping() {
        XCTAssertEqual(Mode.concise.title, "Concise")
        XCTAssertEqual(Mode.full.title, "Full")
        XCTAssertEqual(Mode.off.title, "Off")
    }

    // MARK: - narratableThinking

    private func narratable(_ text: String) -> String? {
        LiveVoiceHeuristics.narratableThinking(from: text)
    }

    func testProseReasoningIsNarrated() {
        XCTAssertNotNil(narratable("Let me check your calendar for tomorrow."))
        XCTAssertNotNil(narratable("Looking at the recent emails now."))
        XCTAssertEqual(narratable("Searching the codebase for the bug."),
                       "Searching the codebase for the bug.")
    }

    func testBashCommandsAreNotNarrated() {
        XCTAssertNil(narratable("cd /Users/kishparikh && grep -rn foo ."))
        XCTAssertNil(narratable("grep -rn \"foo\" ."))
        XCTAssertNil(narratable("xcodebuild -project Clawk.xcodeproj build"))
        XCTAssertNil(narratable("/usr/bin/swift build"))
        XCTAssertNil(narratable("$ ls -la"))
        XCTAssertNil(narratable("git commit -m \"x\""))
    }

    func testCodeBlocksAndShortNoiseAreNotNarrated() {
        XCTAssertNil(narratable("```\nlet x = 1\n```"))
        XCTAssertNil(narratable("ok"))
        XCTAssertNil(narratable("   "))
    }

    func testInlineCommandStrippedFromProse() {
        let result = narratable("I'll run `git log` to see the recent commits")
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.contains("git") ?? true)   // the backtick span is removed
        XCTAssertTrue(result?.contains("recent commits") ?? false)
    }

    func testMixedLinesKeepProseDropCommands() {
        let result = narratable("Let me search the codebase.\ngrep -rn foo .\nThen I will summarize.")
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("search the codebase") ?? false)
        XCTAssertTrue(result?.contains("summarize") ?? false)
        XCTAssertFalse(result?.contains("grep") ?? true)
    }
}
