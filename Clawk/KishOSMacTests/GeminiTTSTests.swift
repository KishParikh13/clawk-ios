import XCTest
@testable import KishOS

final class GeminiTTSTests: XCTestCase {

    // MARK: - WAV wrapper

    func testWavHeaderIsForty4BytesPlusPCM() {
        let pcm = Data(repeating: 0xAB, count: 100)
        let wav = GeminiTTS.wavData(fromPCM: pcm)
        XCTAssertEqual(wav.count, 44 + 100)
    }

    func testWavHasRiffWaveFmtDataMarkers() {
        let wav = GeminiTTS.wavData(fromPCM: Data([0x01, 0x02, 0x03, 0x04]))
        func ascii(_ range: Range<Int>) -> String {
            String(decoding: wav[range], as: UTF8.self)
        }
        XCTAssertEqual(ascii(0..<4), "RIFF")
        XCTAssertEqual(ascii(8..<12), "WAVE")
        XCTAssertEqual(ascii(12..<16), "fmt ")
        XCTAssertEqual(ascii(36..<40), "data")
    }

    func testWavHeaderEncodesFormatLittleEndian() {
        let pcm = Data(repeating: 0, count: 8)
        let wav = GeminiTTS.wavData(fromPCM: pcm, sampleRate: 24_000, channels: 1, bitsPerSample: 16)

        func u32(_ offset: Int) -> Int {
            Int(wav[offset]) | (Int(wav[offset + 1]) << 8) | (Int(wav[offset + 2]) << 16) | (Int(wav[offset + 3]) << 24)
        }
        func u16(_ offset: Int) -> Int {
            Int(wav[offset]) | (Int(wav[offset + 1]) << 8)
        }

        XCTAssertEqual(u32(4), 36 + pcm.count)   // RIFF chunk size
        XCTAssertEqual(u32(16), 16)              // fmt subchunk size
        XCTAssertEqual(u16(20), 1)               // PCM format tag
        XCTAssertEqual(u16(22), 1)               // channels
        XCTAssertEqual(u32(24), 24_000)          // sample rate
        XCTAssertEqual(u32(28), 24_000 * 1 * 16 / 8) // byte rate
        XCTAssertEqual(u16(32), 2)               // block align
        XCTAssertEqual(u16(34), 16)              // bits per sample
        XCTAssertEqual(u32(40), pcm.count)       // data chunk size
    }

    func testWavRoundTripsPCMBytes() {
        let pcm = Data([0x10, 0x20, 0x30, 0x40, 0x50, 0x60])
        let wav = GeminiTTS.wavData(fromPCM: pcm)
        XCTAssertEqual(wav.suffix(pcm.count), pcm)
    }

    // MARK: - Response parsing

    private func response(base64 audio: String, key: String = "inlineData") -> Data {
        let json = """
        {"candidates":[{"content":{"parts":[{"\(key)":{"mimeType":"audio/pcm","data":"\(audio)"}}]}}]}
        """
        return Data(json.utf8)
    }

    func testAudioBase64ExtractsInlineData() {
        let data = response(base64: "QUJD")
        XCTAssertEqual(GeminiTTS.audioBase64(fromResponse: data), "QUJD")
    }

    func testAudioBase64AcceptsSnakeCaseKey() {
        let data = response(base64: "QUJD", key: "inline_data")
        XCTAssertEqual(GeminiTTS.audioBase64(fromResponse: data), "QUJD")
    }

    func testAudioBase64ReturnsNilForMalformed() {
        XCTAssertNil(GeminiTTS.audioBase64(fromResponse: Data("{}".utf8)))
        XCTAssertNil(GeminiTTS.audioBase64(fromResponse: Data("not json".utf8)))
        XCTAssertNil(GeminiTTS.audioBase64(fromResponse: Data(#"{"candidates":[]}"#.utf8)))
    }

    func testPCMDecodesBase64() {
        // "QUJD" is base64 for "ABC".
        let pcm = GeminiTTS.pcm(fromResponse: response(base64: "QUJD"))
        XCTAssertEqual(pcm, Data("ABC".utf8))
    }

    // MARK: - Request body

    func testRequestBodyRequestsAudioWithVoice() {
        let body = GeminiTTS.requestBody(text: "hello", voiceName: "Kore")
        let config = body["generationConfig"] as? [String: Any]
        XCTAssertEqual(config?["responseModalities"] as? [String], ["AUDIO"])
        let speech = config?["speechConfig"] as? [String: Any]
        let voice = (speech?["voiceConfig"] as? [String: Any])?["prebuiltVoiceConfig"] as? [String: Any]
        XCTAssertEqual(voice?["voiceName"] as? String, "Kore")
    }
}
