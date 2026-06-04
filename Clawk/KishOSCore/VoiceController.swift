import AVFoundation
import Foundation
import Speech

@MainActor
final class VoiceController: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var status = "Off"

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

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
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
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
