import AVFoundation
import Foundation
import Speech

@MainActor
final class WakePhraseController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isListening = false
    @Published private(set) var statusLabel = "Off"
    @Published private(set) var lastTranscript = ""
    @Published private(set) var detectionCount = 0

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartTask: Task<Void, Never>?
    private var isSuppressed = false
    private var detectedInCurrentSession = false

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            Task { await startListening() }
        } else {
            stopListening(status: "Off")
        }
    }

    func updateSuppression(_ suppressed: Bool) {
        guard suppressed != isSuppressed else { return }
        isSuppressed = suppressed

        if suppressed {
            stopListening(status: isEnabled ? "Paused" : "Off")
        } else if isEnabled {
            Task { await startListening() }
        }
    }

    func startListening() async {
        guard isEnabled, !isSuppressed, !isListening else { return }
        guard recognizer?.isAvailable == true else {
            statusLabel = "Unavailable"
            return
        }

        let authorized = await requestAuthorization()
        guard authorized else {
            isEnabled = false
            statusLabel = "Blocked"
            return
        }

        do {
            try configureAudioSession()
        } catch {
            statusLabel = "Audio error"
            scheduleRestart()
            return
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        detectedInCurrentSession = false
        lastTranscript = ""

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .search
        request = recognitionRequest

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak recognitionRequest] buffer, _ in
            recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
            statusLabel = "Listening"
        } catch {
            stopListening(status: "Mic error")
            scheduleRestart()
            return
        }

        recognitionTask = recognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.lastTranscript = result.bestTranscription.formattedString
                    self.handleTranscript(self.lastTranscript)
                }
                if error != nil, self.isEnabled, !self.isSuppressed {
                    self.stopListening(status: "Retrying")
                    self.scheduleRestart()
                }
            }
        }
    }

    func stopListening(status: String? = nil) {
        restartTask?.cancel()
        restartTask = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        isListening = false
        detectedInCurrentSession = false
        statusLabel = status ?? (isEnabled ? "Paused" : "Off")

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func handleTranscript(_ transcript: String) {
        let normalized = transcript.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detectedInCurrentSession else { return }
        guard Self.wakePhrases.contains(where: { normalized.contains($0) }) else { return }

        detectedInCurrentSession = true
        detectionCount += 1
        stopListening(status: "Detected")
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.startListening()
        }
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

    private static let wakePhrases = [
        "hey kish",
        "ok kish",
        "okay kish"
    ]
}
