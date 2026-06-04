import AVFoundation
import Foundation

@MainActor
final class AudioRouteMonitor: ObservableObject {
    @Published private(set) var inputName = "System"
    @Published private(set) var outputName = "System"
    @Published private(set) var status = "System"
    @Published private(set) var availableInputNames: [String] = []
    @Published var prefersHandsFreeRoute = false

    private var isStarted = false
    private let userDefaults: UserDefaults
    private static let prefersHandsFreeRouteKey = "KishOSPrefersHandsFreeRoute"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.prefersHandsFreeRoute = userDefaults.bool(forKey: Self.prefersHandsFreeRouteKey)
    }

    var statusLabel: String {
        status
    }

    var routeDetail: String {
        inputName == outputName ? inputName : "\(inputName) -> \(outputName)"
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        refresh()

        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        #endif
    }

    func refresh(isRecording: Bool = false) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        availableInputNames = session.availableInputs?.map(\.portName) ?? []
        inputName = route.inputs.first?.portName ?? "iPhone"
        outputName = route.outputs.first?.portName ?? "iPhone"
        status = isRecording ? "Listening" : routeStatus(for: route)
        #elseif os(macOS)
        inputName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "System"
        outputName = "System"
        status = isRecording ? "Listening" : "System"
        #else
        inputName = "System"
        outputName = "System"
        status = isRecording ? "Listening" : "System"
        #endif
    }

    func setPrefersHandsFreeRoute(_ enabled: Bool) {
        prefersHandsFreeRoute = enabled
        userDefaults.set(enabled, forKey: Self.prefersHandsFreeRouteKey)
        if enabled {
            activatePreferredHandsFreeRoute()
        } else {
            clearPreferredInput()
        }
        refresh()
    }

    func activatePreferredHandsFreeRoute() {
        #if os(iOS)
        guard prefersHandsFreeRoute else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            if let preferredInput = preferredInput(from: session.availableInputs ?? []) {
                try session.setPreferredInput(preferredInput)
            }
            refresh()
        } catch {
            status = "Unavailable"
        }
        #endif
    }

    private func clearPreferredInput() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setPreferredInput(nil)
        } catch {
            status = "Unavailable"
        }
        #endif
    }

    #if os(iOS)
    private func preferredInput(from inputs: [AVAudioSessionPortDescription]) -> AVAudioSessionPortDescription? {
        inputs.first(where: isGlassesLike) ?? inputs.first(where: isHandsFreeCapable)
    }

    private func isGlassesLike(_ input: AVAudioSessionPortDescription) -> Bool {
        let name = input.portName.lowercased()
        return name.contains("ray-ban") || name.contains("rayban") || name.contains("meta") || name.contains("glasses")
    }

    private func isHandsFreeCapable(_ input: AVAudioSessionPortDescription) -> Bool {
        switch input.portType {
        case .bluetoothHFP, .bluetoothLE, .headsetMic:
            return true
        default:
            return false
        }
    }

    private func routeStatus(for route: AVAudioSessionRouteDescription) -> String {
        let ports = route.inputs.map(\.portType) + route.outputs.map(\.portType)
        let names = (route.inputs.map(\.portName) + route.outputs.map(\.portName)).joined(separator: " ").lowercased()

        if names.contains("ray-ban") || names.contains("meta") || names.contains("glasses") {
            return "Glasses"
        }
        if ports.contains(.bluetoothHFP) || ports.contains(.bluetoothA2DP) || ports.contains(.bluetoothLE) {
            return "Bluetooth"
        }
        if route.inputs.isEmpty && route.outputs.isEmpty {
            return "Unavailable"
        }
        return "System"
    }
    #endif
}
