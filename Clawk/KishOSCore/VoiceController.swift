import AVFoundation
import Foundation
import os
import Speech

@MainActor
final class VoiceController: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var status = "Off"
    @Published var waveformLevels = Array(repeating: CGFloat(0.04), count: 32)

    /// When `true` (default, dictation behavior), `startRecording()` configures the
    /// audio session and `stopRecording()` deactivates it. When `false`, an external
    /// owner (the live call) holds the session across listen/speak/listen turns, so
    /// recording must NOT configure or tear down the session between turns.
    var managesAudioSession = true

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private let log = Logger(subsystem: "com.kishparikh.clawk", category: "livevoice")

    /// Call mode: when `true`, the audio engine runs continuously for the whole
    /// call. Each listen turn only swaps the recognition request in and out; the
    /// engine and the Bluetooth link stay up so the app keeps running in the
    /// background and spoken replies reach the glasses.
    private var continuousEngine = false
    private var interruptionObserver: NSObjectProtocol?

    /// Thread-safe handle the audio tap reads on the realtime thread. Holds the
    /// current recognition request only while a listen turn is active; nil means
    /// the engine still runs (keeping audio alive) but mic input is discarded.
    private final class RequestHolder: @unchecked Sendable {
        var request: SFSpeechAudioBufferRecognitionRequest?
    }
    private let requestHolder = RequestHolder()

    func toggleRecording() async -> String? {
        if isRecording {
            return stopRecording()
        }

        await startRecording()
        return nil
    }

    /// Start the continuous full-duplex engine for a live call. The session must
    /// already be configured and active (the call owns it). The engine then runs
    /// for the whole call so the app stays alive in the background and the glasses
    /// link stays up. Returns false if speech/mic is unavailable.
    func beginCallAudio() async -> Bool {
        guard !continuousEngine else { return true }
        guard recognizer?.isAvailable == true else {
            status = "Speech unavailable"
            return false
        }
        let authorized = await requestAuthorization()
        guard authorized else {
            status = "Mic blocked"
            return false
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [requestHolder, weak self] buffer, _ in
            // Feed the recognizer and animate the waveform only while a listen
            // turn is active. Between turns the engine keeps running (app stays
            // alive, glasses link held) but mic input is discarded.
            guard let activeRequest = requestHolder.request else { return }
            activeRequest.append(buffer)
            let level = Self.normalizedLevel(from: buffer)
            Task { @MainActor [weak self] in
                self?.appendWaveformLevel(level)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            continuousEngine = true
            startInterruptionObserver()
            log.info("call audio engine started")
            return true
        } catch {
            input.removeTap(onBus: 0)
            status = "Mic error"
            log.error("call audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Stop the continuous engine at call end. Does NOT deactivate the session;
    /// the route monitor owns session lifecycle.
    func endCallAudio() {
        guard continuousEngine else { return }
        requestHolder.request = nil
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        continuousEngine = false
        isRecording = false
        waveformLevels = Array(repeating: CGFloat(0.04), count: 32)
        stopInterruptionObserver()
        log.info("call audio engine stopped")
    }

    private func startInterruptionObserver() {
        #if os(iOS)
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        #endif
    }

    private func stopInterruptionObserver() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard continuousEngine,
              let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            log.info("audio interruption began")
        case .ended:
            log.info("audio interruption ended; reactivating engine")
            try? AVAudioSession.sharedInstance().setActive(true, options: [])
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try? audioEngine.start()
            }
        @unknown default:
            break
        }
    }
    #endif

    func startRecording() async {
        guard !isRecording else { return }

        if continuousEngine {
            // Call mode: the engine is already running. Just open a fresh
            // recognition turn; the tap starts feeding it via requestHolder.
            recognitionTask?.cancel()
            recognitionTask = nil
            transcript = ""
            waveformLevels = Array(repeating: CGFloat(0.04), count: 32)

            let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.taskHint = .dictation
            request = recognitionRequest
            requestHolder.request = recognitionRequest

            recognitionTask = recognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil {
                        self.stopRecording()
                    }
                }
            }
            isRecording = true
            status = "Listening"
            return
        }

        guard recognizer?.isAvailable == true else {
            status = "Speech unavailable"
            return
        }

        let authorized = await requestAuthorization()
        guard authorized else {
            status = "Mic blocked"
            return
        }

        if managesAudioSession {
            do {
                try configureAudioSession()
            } catch {
                status = "Audio error"
                return
            }
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        transcript = ""
        waveformLevels = Array(repeating: CGFloat(0.04), count: 32)

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        request = recognitionRequest

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak recognitionRequest] buffer, _ in
            recognitionRequest?.append(buffer)
            let level = Self.normalizedLevel(from: buffer)
            Task { @MainActor [weak self] in
                self?.appendWaveformLevel(level)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            status = "Listening"
        } catch {
            if managesAudioSession {
                deactivateAudioSession()
            }
            status = "Mic error"
            return
        }

        recognitionTask = recognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil {
                    self.stopRecording()
                }
            }
        }
    }

    @discardableResult
    func stopRecording() -> String? {
        guard isRecording else { return nil }

        if continuousEngine {
            // Call mode: end this listen turn but keep the engine and session
            // alive so audio keeps flowing in the background between turns.
            requestHolder.request = nil
            request?.endAudio()
            recognitionTask?.cancel()
            request = nil
            recognitionTask = nil
            isRecording = false
            status = "Ready"
            waveformLevels = Array(repeating: CGFloat(0.04), count: 32)
            let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            transcript = ""
            return clean.isEmpty ? nil : clean
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        isRecording = false
        status = "Ready"
        waveformLevels = Array(repeating: CGFloat(0.04), count: 32)
        if managesAudioSession {
            deactivateAudioSession()
        }

        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        return clean.isEmpty ? nil : clean
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    private func configureAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func appendWaveformLevel(_ level: CGFloat) {
        waveformLevels.append(level)
        if waveformLevels.count > 32 {
            waveformLevels.removeFirst(waveformLevels.count - 32)
        }
    }

    nonisolated private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelData = buffer.floatChannelData else { return 0.04 }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else { return 0.04 }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sum += sample * sample
            }
        }

        let mean = sum / Float(channelCount * frameCount)
        let rms = sqrt(max(mean, 0))
        let decibels = 20 * log10(max(rms, 0.000_01))
        let linear = min(max((decibels + 58) / 48, 0), 1)
        let dramatic = pow(linear, 0.56)
        return CGFloat(max(0.035, min(1, dramatic)))
    }
}
