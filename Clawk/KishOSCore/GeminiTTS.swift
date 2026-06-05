import Foundation

/// Pure helpers for Gemini text-to-speech. Networking and audio playback live in
/// the iOS layer (`CallVoices.swift`); everything here is platform-agnostic and
/// unit-tested. Model: `gemini-3.1-flash-tts-preview`, which returns base64 PCM
/// audio (signed 16-bit little-endian, 24 kHz, mono) on `:generateContent`.
enum GeminiTTS {
    static let model = "gemini-3.1-flash-tts-preview"
    static let sampleRate = 24_000
    static let channels = 1
    static let bitsPerSample = 16
    static let defaultVoice = "Kore"

    static func endpoint() -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    /// The `generateContent` request body for single-speaker speech.
    static func requestBody(text: String, voiceName: String) -> [String: Any] {
        [
            "contents": [["parts": [["text": text]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": ["voiceName": voiceName]
                    ]
                ]
            ]
        ]
    }

    /// Extract the base64 audio payload from a `generateContent` response body.
    /// Path: `candidates[0].content.parts[*].inlineData.data` (first audio part).
    static func audioBase64(fromResponse data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { return nil }

        for part in parts {
            if let inline = part["inlineData"] as? [String: Any] ?? part["inline_data"] as? [String: Any],
               let b64 = inline["data"] as? String,
               !b64.isEmpty {
                return b64
            }
        }
        return nil
    }

    /// Decode the base64 audio payload into raw PCM bytes.
    static func pcm(fromResponse data: Data) -> Data? {
        guard let b64 = audioBase64(fromResponse: data) else { return nil }
        return Data(base64Encoded: b64)
    }

    /// Wrap raw PCM in a 44-byte WAV (RIFF) header so `AVAudioPlayer` can play it.
    static func wavData(
        fromPCM pcm: Data,
        sampleRate: Int = sampleRate,
        channels: Int = channels,
        bitsPerSample: Int = bitsPerSample
    ) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataLength = pcm.count
        let chunkSize = 36 + dataLength

        var header = Data()
        func appendASCII(_ s: String) { header.append(contentsOf: Array(s.utf8)) }
        func appendUInt32LE(_ v: Int) {
            let u = UInt32(truncatingIfNeeded: v)
            header.append(contentsOf: [
                UInt8(u & 0xff),
                UInt8((u >> 8) & 0xff),
                UInt8((u >> 16) & 0xff),
                UInt8((u >> 24) & 0xff)
            ])
        }
        func appendUInt16LE(_ v: Int) {
            let u = UInt16(truncatingIfNeeded: v)
            header.append(contentsOf: [UInt8(u & 0xff), UInt8((u >> 8) & 0xff)])
        }

        appendASCII("RIFF")
        appendUInt32LE(chunkSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32LE(16)            // PCM fmt chunk size
        appendUInt16LE(1)             // audioFormat = PCM
        appendUInt16LE(channels)
        appendUInt32LE(sampleRate)
        appendUInt32LE(byteRate)
        appendUInt16LE(blockAlign)
        appendUInt16LE(bitsPerSample)
        appendASCII("data")
        appendUInt32LE(dataLength)

        var out = header
        out.append(pcm)
        return out
    }
}
