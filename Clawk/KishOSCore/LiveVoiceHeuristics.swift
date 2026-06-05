import Foundation

/// Pure, testable heuristics for the hands-free live voice surface.
///
/// These functions have no side effects and no UIKit/AVFoundation
/// dependencies so the macOS test target can exercise them directly.
enum LiveVoiceHeuristics {
    /// Whether a partial transcript is substantial enough to auto-finalize
    /// (i.e. auto-submit after the silence delay) without the user manually
    /// sending.
    ///
    /// Returns `true` when the trimmed text has at least 2 words OR at least
    /// 8 non-whitespace characters. This keeps one-letter or one-noise
    /// partials (a stray "a", "ok", "go") from auto-sending while the user is
    /// still gathering their thought. Manual send is never gated by this.
    ///
    /// Empty or whitespace-only input returns `false`.
    static func shouldAutoFinalizeUtterance(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        if words.count >= 2 { return true }

        let nonWhitespaceCount = trimmed.reduce(into: 0) { count, character in
            if !character.isWhitespace { count += 1 }
        }
        return nonWhitespaceCount >= 8
    }
}
