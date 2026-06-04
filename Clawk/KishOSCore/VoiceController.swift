import AVFoundation
import Foundation
import Speech

@MainActor
final class VoiceController: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var status = "Off"
    @Published var waveformLevels = Array(repeating: CGFloat(0.04), count: 32)

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func toggleRecording() async -> String? {
        if isRecording {
            return stopRecording()
        }

        await startRecording()
        return nil
    }

    func startRecording() async {
        guard !isRecording else { return }
        guard recognizer?.isAvailable == true else {
            status = "Speech unavailable"
            return
        }

        let authorized = await requestAuthorization()
        guard authorized else {
            status = "Mic blocked"
            return
        }

        do {
            try configureAudioSession()
        } catch {
            status = "Audio error"
            return
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
            deactivateAudioSession()
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

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        isRecording = false
        status = "Ready"
        waveformLevels = Array(repeating: CGFloat(0.04), count: 32)
        deactivateAudioSession()

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
