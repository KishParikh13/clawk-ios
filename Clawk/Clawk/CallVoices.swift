import AVFoundation
import Foundation
import os

/// Spoken-voice backends for the live call. Both run on the main actor and expose
/// the same `play`/`stop` shape so `LiveCallController` can pick Gemini when a key
/// is configured and fall back to Apple otherwise. Playback rides the call's
/// existing audio session, so output follows the active route (glasses/headset).

private let voiceLog = Logger(subsystem: "com.kishparikh.clawk", category: "callvoice")

enum CallVoiceError: Error {
    case notConfigured
    case http(Int)
    case noAudio
    case playbackFailed
}

/// Look up a bundled sound by base name, trying mp3 (Kish's real assets) then
/// wav (synthesized fallbacks for error/question).
private func soundURL(_ name: String) -> URL? {
    Bundle.main.url(forResource: name, withExtension: "mp3")
        ?? Bundle.main.url(forResource: name, withExtension: "wav")
}

/// A one-shot player that retains itself until playback finishes, so it can
/// outlive the call controller (used for the call-end sound, which plays while
/// the call is tearing down).
@MainActor
private final class DetachedOneShot: NSObject, AVAudioPlayerDelegate {
    private static var live = Set<DetachedOneShot>()
    private var player: AVAudioPlayer?

    static func play(_ name: String, volume: Float) {
        guard let url = soundURL(name), let p = try? AVAudioPlayer(contentsOf: url) else {
            voiceLog.error("\(name, privacy: .public) missing or unreadable")
            return
        }
        let holder = DetachedOneShot()
        holder.player = p
        p.delegate = holder
        p.volume = volume
        live.insert(holder)
        p.play()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in DetachedOneShot.live.remove(self) }
    }
}

/// The call's audio cues: two distinct ambient loops (a calm drone while awaiting
/// you, a warmer bed while the agent works) that crossfade, plus one-shot earcons
/// for call start, reply ready, call end, error, and question. Everything rides
/// the active call session, so it follows the route to the glasses. Volumes are
/// intentionally easy to tune. `end()` tears it down; the call-end sound is fired
/// detached so it survives teardown.
@MainActor
final class CallSoundscape {
    enum Ambient { case none, waiting, working }
    enum Earcon: String {
        case callStart = "call_start"
        case replyReady = "reply_ready"
        case callEnd = "call_end"
        case error = "earcon_error"
        case question = "earcon_question"
    }

    private var waiting: AVAudioPlayer?
    private var working: AVAudioPlayer?
    private var earcons: [Earcon: AVAudioPlayer] = [:]
    private var current: Ambient = .none

    private let waitingVolume: Float = 0.30
    private let workingVolume: Float = 0.20   // sits under the spoken reasoning
    private let earconVolume: Float = 0.85

    private func loop(_ name: String) -> AVAudioPlayer? {
        guard let url = soundURL(name), let p = try? AVAudioPlayer(contentsOf: url) else {
            voiceLog.error("\(name, privacy: .public) missing or unreadable")
            return nil
        }
        p.numberOfLoops = -1
        p.volume = 0
        p.prepareToPlay()
        return p
    }

    func setAmbient(_ ambient: Ambient) {
        guard ambient != current else { return }
        current = ambient

        if waiting == nil { waiting = loop("waiting_ambient") }
        if working == nil { working = loop("working_ambient") }

        let players: [(AVAudioPlayer?, Float)] = [
            (waiting, ambient == .waiting ? waitingVolume : 0),
            (working, ambient == .working ? workingVolume : 0)
        ]
        for (player, target) in players {
            guard let player else { continue }
            if target > 0 && !player.isPlaying { player.play() }
            player.setVolume(target, fadeDuration: 0.5)
        }
    }

    func play(_ earcon: Earcon) {
        // The call-end sound must outlive controller teardown.
        if earcon == .callEnd {
            DetachedOneShot.play(earcon.rawValue, volume: earconVolume)
            return
        }
        let player: AVAudioPlayer
        if let existing = earcons[earcon] {
            player = existing
        } else {
            guard let url = soundURL(earcon.rawValue), let p = try? AVAudioPlayer(contentsOf: url) else {
                voiceLog.error("\(earcon.rawValue, privacy: .public) missing or unreadable")
                return
            }
            p.volume = earconVolume
            p.prepareToPlay()
            earcons[earcon] = p
            player = p
        }
        player.currentTime = 0
        player.play()
    }

    func end() {
        waiting?.stop(); waiting = nil
        working?.stop(); working = nil
        for player in earcons.values { player.stop() }
        earcons.removeAll()
        current = .none
    }
}

/// Apple's on-device `AVSpeechSynthesizer`, bridged to async so it composes with
/// the Gemini path. Instant and offline, used as the always-available fallback.
@MainActor
final class AppleSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var finish: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    func play(_ text: String) async {
        await withCheckedContinuation { continuation in
            finish = continuation
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.0
            synth.speak(utterance)
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        resume()
    }

    private func resume() {
        guard let finish else { return }
        self.finish = nil
        finish.resume()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }
}

/// Cloud voice via `gemini-3.1-flash-tts-preview`. Fetches PCM, wraps it in WAV,
/// and plays it through the call session. Throws on any failure so the caller
/// can fall back to Apple. The API key is injected at build time from the
/// `GEMINI_API_KEY` environment into Info.plist (`GeminiAPIKey`).
@MainActor
final class GeminiSpeaker: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var finish: CheckedContinuation<Void, Never>?
    private let voiceName: String

    init(voiceName: String = GeminiTTS.defaultVoice) {
        self.voiceName = voiceName
        super.init()
    }

    static var apiKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "GeminiAPIKey") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isConfigured: Bool { Self.apiKey != nil }

    func play(_ text: String) async throws {
        guard let apiKey = Self.apiKey else { throw CallVoiceError.notConfigured }

        var request = URLRequest(url: GeminiTTS.endpoint())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(
            withJSONObject: GeminiTTS.requestBody(text: text, voiceName: voiceName)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            voiceLog.error("gemini tts http \(http.statusCode, privacy: .public)")
            throw CallVoiceError.http(http.statusCode)
        }
        guard let pcm = GeminiTTS.pcm(fromResponse: data), !pcm.isEmpty else {
            throw CallVoiceError.noAudio
        }

        let wav = GeminiTTS.wavData(fromPCM: pcm)
        let audioPlayer = try AVAudioPlayer(data: wav)
        audioPlayer.delegate = self
        player = audioPlayer
        audioPlayer.prepareToPlay()
        guard audioPlayer.play() else { throw CallVoiceError.playbackFailed }

        await withCheckedContinuation { continuation in
            finish = continuation
        }
    }

    func stop() {
        player?.stop()
        player = nil
        resume()
    }

    private func resume() {
        guard let finish else { return }
        self.finish = nil
        finish.resume()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.resume()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.player = nil
            self.resume()
        }
    }
}
