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

    /// How much of an agent reply is read aloud in the live voice surface.
    /// The full reply always lands in chat regardless of this mode; this only
    /// affects what is spoken.
    enum SpokenReplyMode: String, CaseIterable, Codable {
        /// Strip code/noise, speak a short summary (first sentence group),
        /// capped to ~280 characters. The default.
        case concise
        /// Speak the full reply, with fenced code blocks removed for speech.
        case full
        /// Speak nothing.
        case off

        static let storageKey = "KishOSSpokenReplyMode"

        var title: String {
            switch self {
            case .concise: return "Concise"
            case .full: return "Full"
            case .off: return "Off"
            }
        }

        /// The currently persisted mode, defaulting to `.concise`.
        static var current: SpokenReplyMode {
            UserDefaults.standard.string(forKey: storageKey)
                .flatMap(SpokenReplyMode.init(rawValue:)) ?? .concise
        }
    }

    /// The approximate character budget for a concise spoken reply.
    private static let conciseCharBudget = 280

    /// Produces the text that should be SPOKEN for a given agent reply and
    /// spoken-reply mode. Pure and deterministic (no I/O) so it is unit-testable.
    ///
    /// - `.off` → `nil` (nothing spoken).
    /// - `.full` → the reply with fenced code blocks removed for speech, but
    ///   otherwise the full prose. `nil` if empty after trimming.
    /// - `.concise` → strips fenced code blocks and inline-code/log noise,
    ///   prefers the first sentence group / paragraph, and caps to ~280
    ///   characters on a word boundary (appending "…" only when truncated).
    ///   `nil` if empty after trimming.
    static func spokenText(from reply: String, mode: SpokenReplyMode) -> String? {
        switch mode {
        case .off:
            return nil
        case .full:
            let stripped = strippingFencedCodeBlocks(reply)
            let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .concise:
            let cleaned = strippingInlineCode(strippingFencedCodeBlocks(reply))
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let summary = firstSentenceGroup(from: trimmed)
            let capped = cappedToBudget(summary, budget: conciseCharBudget)
            return capped.isEmpty ? nil : capped
        }
    }

    /// Removes fenced code blocks (```...```), keeping surrounding prose.
    private static func strippingFencedCodeBlocks(_ text: String) -> String {
        var result = ""
        var insideFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if !insideFence {
                result += line + "\n"
            }
        }
        return result
    }

    /// Removes inline-code spans (`...`) and obvious log noise lines, leaving
    /// readable prose for speech.
    private static func strippingInlineCode(_ text: String) -> String {
        // Drop inline-code spans entirely; speaking backtick contents is noise.
        let withoutInline = text.replacingOccurrences(
            of: "`[^`]*`",
            with: " ",
            options: .regularExpression
        )

        // Drop lines that look like logs / shell noise rather than prose.
        let keptLines = withoutInline.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return true }
            // Shell prompts and command markers.
            if trimmed.hasPrefix("$ ") || trimmed.hasPrefix("> ") { return false }
            // Common log level prefixes.
            let lower = trimmed.lowercased()
            for prefix in ["error:", "warning:", "[error]", "[warn]", "[info]", "[debug]"] {
                if lower.hasPrefix(prefix) { return false }
            }
            return true
        }
        return keptLines.joined(separator: "\n")
    }

    /// Prefers the first paragraph, then trims it to the first sentence group so
    /// the spoken summary leads with the headline rather than the whole reply.
    private static func firstSentenceGroup(from text: String) -> String {
        // First non-empty paragraph (paragraphs separated by blank lines).
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let paragraph = paragraphs.first ?? text.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the paragraph already fits the budget, keep the whole paragraph so
        // we don't chop a short, complete thought mid-way.
        if paragraph.count <= conciseCharBudget {
            return paragraph
        }

        // Otherwise prefer the first sentence(s) that fit the budget.
        var result = ""
        var current = ""
        for character in paragraph {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let candidate = (result + current).trimmingCharacters(in: .whitespaces)
                if candidate.count > conciseCharBudget {
                    // Stop before overflowing; if nothing accumulated yet, fall
                    // through to budget capping below.
                    break
                }
                result += current
                current = ""
            }
        }
        let sentences = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return sentences.isEmpty ? paragraph : sentences
    }

    /// Caps text to `budget` characters on a word boundary, appending "…" only
    /// when truncation actually occurred.
    private static func cappedToBudget(_ text: String, budget: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > budget else { return trimmed }

        let head = String(trimmed.prefix(budget))
        // Cut back to the last whitespace so we don't split a word.
        if let lastSpace = head.lastIndex(where: { $0.isWhitespace }) {
            let word = head[..<lastSpace].trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty {
                return word + "…"
            }
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
