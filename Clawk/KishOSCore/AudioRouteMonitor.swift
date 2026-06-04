import AVFoundation
import Foundation

@MainActor
final class AudioRouteMonitor: ObservableObject {
    @Published private(set) var inputName = "System"
    @Published private(set) var outputName = "System"
    @Published private(set) var status = "System"
    @Published private(set) var activationDetail = ""
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
            Task { await activatePreferredHandsFreeRoute() }
        } else {
            clearPreferredInput()
            activationDetail = ""
        }
        refresh()
    }

    func activatePreferredHandsFreeRoute(timeout: TimeInterval = 2.0) async {
        #if os(iOS)
        guard prefersHandsFreeRoute else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            if let preferredInput = preferredInput(from: session.availableInputs ?? []) {
                try? session.setPreferredInput(preferredInput)
                await waitForRouteActivation(preferredInput: preferredInput, timeout: timeout)
            } else {
                activationDetail = "No external input"
                refresh()
            }
        } catch {
            status = "Unavailable"
            activationDetail = error.localizedDescription
        }
        #else
        refresh()
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
        return name.contains("rb meta")
            || name.contains("ray-ban")
            || name.contains("ray ban")
            || name.contains("rayban")
            || name.contains("meta")
            || name.contains("glasses")
    }

    private func isHandsFreeCapable(_ input: AVAudioSessionPortDescription) -> Bool {
        Self.handsFreePortTypes.contains(input.portType)
    }

    private func waitForRouteActivation(preferredInput: AVAudioSessionPortDescription, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            refresh()
            if currentRouteUsesPreferredInput(preferredInput) || routeUsesHandsFree(AVAudioSession.sharedInstance().currentRoute) {
                activationDetail = "Using \(routeDetail)"
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        refresh()
        activationDetail = "Fallback \(routeDetail)"
    }

    private func currentRouteUsesPreferredInput(_ preferredInput: AVAudioSessionPortDescription) -> Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains { input in
            input.portType == preferredInput.portType && input.portName == preferredInput.portName
        }
    }

    private func routeUsesHandsFree(_ route: AVAudioSessionRouteDescription) -> Bool {
        let ports = route.inputs.map(\.portType) + route.outputs.map(\.portType)
        return ports.contains { Self.handsFreePortTypes.contains($0) }
    }

    private func routeStatus(for route: AVAudioSessionRouteDescription) -> String {
        let ports = route.inputs.map(\.portType) + route.outputs.map(\.portType)
        let names = (route.inputs.map(\.portName) + route.outputs.map(\.portName)).joined(separator: " ").lowercased()

        if names.contains("rb meta")
            || names.contains("ray-ban")
            || names.contains("ray ban")
            || names.contains("rayban")
            || names.contains("meta")
            || names.contains("glasses") {
            return "Glasses"
        }
        if ports.contains(.bluetoothHFP) || ports.contains(.bluetoothA2DP) || ports.contains(.bluetoothLE) {
            return "Bluetooth"
        }
        if ports.contains(.headsetMic) || ports.contains(.headphones) {
            return "Headset"
        }
        if route.inputs.isEmpty && route.outputs.isEmpty {
            return "Unavailable"
        }
        return "System"
    }

    private static let handsFreePortTypes: Set<AVAudioSession.Port> = [
        .bluetoothHFP,
        .bluetoothLE,
        .bluetoothA2DP,
        .headsetMic,
        .headphones
    ]
    #endif
}
