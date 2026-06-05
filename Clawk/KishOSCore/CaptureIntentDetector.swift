import Foundation

enum CaptureIntentDetector {
    static func detect(in text: String) -> CaptureIntent? {
        let clean = normalized(text)
        guard !clean.isEmpty else { return nil }

        if containsAny(clean, videoTriggers) {
            return CaptureIntent(
                mediaKind: .video,
                source: sourcePreference(in: clean),
                prompt: cleanedPrompt(from: text, triggerPatterns: videoCleanupPatterns)
            )
        }

        guard containsAny(clean, photoTriggers) else { return nil }
        return CaptureIntent(
            mediaKind: .photo,
            source: sourcePreference(in: clean),
            prompt: cleanedPrompt(from: text, triggerPatterns: photoCleanupPatterns)
        )
    }

    private static let photoTriggers = [
        "take a picture",
        "take a photo",
        "snap a picture",
        "snap a photo",
        "take pic",
        "take photo",
        "take picture",
        "use the glasses camera",
        "use glasses camera",
        "glasses camera",
        "phone camera",
        "use the camera",
        "look at this",
        "what am i looking at",
        "what is in front of me",
        "what do you see"
    ]

    private static let videoTriggers = [
        "record a video",
        "take a video",
        "capture video",
        "record this"
    ]

    private static let photoCleanupPatterns = [
        "take a picture",
        "take a photo",
        "snap a picture",
        "snap a photo",
        "take pic",
        "take photo",
        "take picture",
        "use the glasses camera",
        "use glasses camera",
        "glasses camera",
        "phone camera",
        "use the camera",
        "with my glasses",
        "with glasses",
        "using my glasses",
        "using glasses",
        "on my glasses",
        "on glasses",
        "from my glasses",
        "from glasses",
        "through my glasses",
        "through glasses",
        "with my phone",
        "with phone",
        "using my phone",
        "using phone",
        "on my phone",
        "on phone",
        "look at this and",
        "look at this",
        "what am i looking at",
        "what is in front of me",
        "what do you see"
    ]

    private static let videoCleanupPatterns = [
        "record a video",
        "take a video",
        "capture video",
        "record this"
    ]

    private static func sourcePreference(in normalizedText: String) -> MediaCaptureSource {
        if normalizedText.contains("glasses camera")
            || normalizedText.contains("with my glasses")
            || normalizedText.contains("with glasses")
            || normalizedText.contains("using my glasses")
            || normalizedText.contains("using glasses")
            || normalizedText.contains("on my glasses")
            || normalizedText.contains("on glasses")
            || normalizedText.contains("from my glasses")
            || normalizedText.contains("from glasses")
            || normalizedText.contains("through my glasses")
            || normalizedText.contains("through glasses") {
            return .glassesCamera
        }
        if normalizedText.contains("phone camera")
            || normalizedText.contains("with my phone")
            || normalizedText.contains("with phone")
            || normalizedText.contains("using my phone")
            || normalizedText.contains("using phone")
            || normalizedText.contains("on my phone")
            || normalizedText.contains("on phone") {
            return .phoneCamera
        }
        return .automatic
    }

    private static func containsAny(_ text: String, _ candidates: [String]) -> Bool {
        candidates.contains { text.contains($0) }
    }

    private static func cleanedPrompt(from original: String, triggerPatterns: [String]) -> String {
        let cleanOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = cleanOriginal.lowercased()

        for pattern in triggerPatterns.sorted(by: { $0.count > $1.count }) {
            prompt = prompt.replacingOccurrences(of: pattern, with: "")
        }

        let conjunctions = [
            #"^\s*(and|then|please|can you|could you|would you)\b\s*"#,
            #"\s+(and|then)\s*$"#
        ]
        for pattern in conjunctions {
            prompt = prompt.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        prompt = prompt
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))

        guard !prompt.isEmpty else {
            return fallbackPrompt(for: triggerPatterns)
        }

        return prompt.prefix(1).uppercased() + prompt.dropFirst()
    }

    private static func fallbackPrompt(for triggerPatterns: [String]) -> String {
        triggerPatterns == videoCleanupPatterns
            ? "Look at the attached video and respond."
            : "Look at the attached image and respond."
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s-]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
