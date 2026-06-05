import AVFoundation
import Foundation

enum AudioRouteKind: String, Codable {
    case system = "System"
    case builtIn = "Built-in"
    case bluetooth = "Bluetooth"
    case glasses = "Glasses"
    case headset = "Headset"
    case unknown = "Unknown"
}

struct AudioRouteCandidate: Identifiable, Equatable, Codable {
    var id: String { "\(name)-\(portType)-\(isInput)-\(isOutput)" }
    let name: String
    let portType: String
    let kind: AudioRouteKind
    let isInput: Bool
    let isOutput: Bool
    let isActive: Bool
    let isPreferredCandidate: Bool
}

struct AudioCapabilityLine: Identifiable, Equatable {
    var id: String { "\(title)-\(state)-\(detail)" }
    let title: String
    let state: String
    let detail: String
    let isReady: Bool
}

@MainActor
final class AudioRouteMonitor: ObservableObject {
    @Published private(set) var inputName = "System"
    @Published private(set) var outputName = "System"
    @Published private(set) var status = "System"
    @Published private(set) var activationDetail = ""
    @Published private(set) var availableInputNames: [String] = []
    @Published private(set) var availableRoutes: [AudioRouteCandidate] = []
    @Published private(set) var activeRouteKind: AudioRouteKind = .system
    @Published private(set) var preferredRouteName: String?
    @Published var prefersHandsFreeRoute = false

    /// True while a live call owns the audio session (begun by `beginCallSession`,
    /// cleared by `endCallSession`). During this window the session is NOT torn down
    /// between listen/speak turns.
    @Published private(set) var isCallSessionActive = false
    /// Whether an external (glasses/bluetooth/headset) route was seen at any point
    /// during the current call session. Read by P0.3 to derive the "lost" route state.
    @Published private(set) var wasExternalSeenInCallSession = false

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

    var routeModeLabel: String {
        prefersHandsFreeRoute ? "Prefer external" : "System default"
    }

    var hasExternalRouteAvailable: Bool {
        availableRoutes.contains { $0.isPreferredCandidate }
    }

    var isPreferredRouteActive: Bool {
        activeRouteKind == .glasses || activeRouteKind == .bluetooth || activeRouteKind == .headset
    }

    var routeHealthLabel: String {
        if status == "Unavailable" {
            return "Unavailable"
        }
        if prefersHandsFreeRoute {
            if isPreferredRouteActive {
                return "Active"
            }
            return hasExternalRouteAvailable ? "Switching" : "Waiting"
        }
        return "Ready"
    }

    var glassesSummary: String {
        switch activeRouteKind {
        case .glasses:
            return "Glasses active"
        case .bluetooth, .headset:
            return "\(activeRouteKind.rawValue) active"
        default:
            return hasExternalRouteAvailable ? "External available" : "System audio"
        }
    }

    var capabilityLines: [AudioCapabilityLine] {
        [
            AudioCapabilityLine(
                title: "Audio route",
                state: isPreferredRouteActive ? "Ready" : (hasExternalRouteAvailable ? "Available" : "System"),
                detail: routeDetail,
                isReady: status != "Unavailable"
            ),
            AudioCapabilityLine(
                title: "Dictation",
                state: "Ready",
                detail: "Transcript fills the composer before send.",
                isReady: true
            ),
            AudioCapabilityLine(
                title: "Wake phrase",
                state: "Available",
                detail: "Local Speech wake phrase on iPhone.",
                isReady: true
            ),
            AudioCapabilityLine(
                title: "Snapshot ask",
                state: "Ready",
                detail: "Uses iPhone camera/photo upload path.",
                isReady: true
            ),
            AudioCapabilityLine(
                title: "Meta camera",
                state: "Planned",
                detail: "Requires DAT registration and camera permission.",
                isReady: false
            ),
            AudioCapabilityLine(
                title: "Ray-Ban Display",
                state: "Planned",
                detail: "DAT display capability, separate from audio V1.",
                isReady: false
            )
        ]
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
        let availableInputs = session.availableInputs ?? []
        availableInputNames = availableInputs.map(\.portName)
        inputName = route.inputs.first?.portName ?? "iPhone"
        outputName = route.outputs.first?.portName ?? "iPhone"
        activeRouteKind = routeKind(for: route)
        status = isRecording ? "Listening" : activeRouteKind.rawValue
        preferredRouteName = preferredInput(from: availableInputs)?.portName
        availableRoutes = routeCandidates(availableInputs: availableInputs, route: route)
        #elseif os(macOS)
        let inputs = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        inputName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "System"
        outputName = "System"
        activeRouteKind = .system
        status = isRecording ? "Listening" : "System"
        availableInputNames = inputs.map(\.localizedName)
        preferredRouteName = availableInputNames.first(where: Self.isGlassesLikeName) ?? availableInputNames.first(where: Self.isExternalLikeName)
        availableRoutes = inputs.map { device in
            let kind = Self.kind(forName: device.localizedName, fallback: .system)
            return AudioRouteCandidate(
                name: device.localizedName,
                portType: "macOS input",
                kind: kind,
                isInput: true,
                isOutput: false,
                isActive: device.localizedName == inputName,
                isPreferredCandidate: kind == .glasses || kind == .bluetooth || kind == .headset || Self.isExternalLikeName(device.localizedName)
            )
        }
        #else
        inputName = "System"
        outputName = "System"
        status = isRecording ? "Listening" : "System"
        activeRouteKind = .system
        availableInputNames = []
        preferredRouteName = nil
        availableRoutes = []
        #endif

        if isCallSessionActive, isPreferredRouteActive {
            wasExternalSeenInCallSession = true
        }
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

    /// Begin a live-call audio session. The call owns the session for its full
    /// duration. ALWAYS attempts the preferred external input regardless of
    /// `prefersHandsFreeRoute` (force semantics). If no external input exists or
    /// activation throws, the call still runs on phone audio — this never fails the
    /// call. Note: call mode does NOT use `.defaultToSpeaker`.
    func beginCallSession(timeout: TimeInterval = 2.0) async {
        wasExternalSeenInCallSession = false
        isCallSessionActive = true
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            if let preferredInput = preferredInput(from: session.availableInputs ?? []) {
                try? session.setPreferredInput(preferredInput)
                await waitForRouteActivation(preferredInput: preferredInput, timeout: timeout)
            } else {
                activationDetail = "No external input"
            }
        } catch {
            // Never fail the call: mark route unavailable and continue on phone audio.
            status = "Unavailable"
            activationDetail = error.localizedDescription
        }
        #endif
        refresh()
    }

    /// End the live-call audio session: deactivate, clear the preferred input, and
    /// reset call-session route context.
    func endCallSession() {
        isCallSessionActive = false
        wasExternalSeenInCallSession = false
        #if os(iOS)
        clearPreferredInput()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        refresh()
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
        Self.isGlassesLikeName(input.portName)
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

    private func routeKind(for route: AVAudioSessionRouteDescription) -> AudioRouteKind {
        let ports = route.inputs.map(\.portType) + route.outputs.map(\.portType)
        let names = (route.inputs.map(\.portName) + route.outputs.map(\.portName)).joined(separator: " ").lowercased()

        if names.contains("rb meta")
            || names.contains("ray-ban")
            || names.contains("ray ban")
            || names.contains("rayban")
            || names.contains("meta")
            || names.contains("glasses") {
            return .glasses
        }
        if ports.contains(.bluetoothHFP) || ports.contains(.bluetoothA2DP) || ports.contains(.bluetoothLE) {
            return .bluetooth
        }
        if ports.contains(.headsetMic) || ports.contains(.headphones) {
            return .headset
        }
        if route.inputs.isEmpty && route.outputs.isEmpty {
            return .unknown
        }
        if ports.contains(.builtInMic) || ports.contains(.builtInReceiver) || ports.contains(.builtInSpeaker) {
            return .builtIn
        }
        return .system
    }

    private func routeCandidates(availableInputs: [AVAudioSessionPortDescription], route: AVAudioSessionRouteDescription) -> [AudioRouteCandidate] {
        let activeInputs = Set(route.inputs.map { "\($0.portType.rawValue)-\($0.portName)" })
        let activeOutputs = Set(route.outputs.map { "\($0.portType.rawValue)-\($0.portName)" })
        var candidates: [AudioRouteCandidate] = availableInputs.map { input in
            let key = "\(input.portType.rawValue)-\(input.portName)"
            let kind = Self.kind(forName: input.portName, portType: input.portType)
            return AudioRouteCandidate(
                name: input.portName,
                portType: input.portType.rawValue,
                kind: kind,
                isInput: true,
                isOutput: false,
                isActive: activeInputs.contains(key),
                isPreferredCandidate: kind == .glasses || Self.handsFreePortTypes.contains(input.portType)
            )
        }

        for output in route.outputs {
            let key = "\(output.portType.rawValue)-\(output.portName)"
            let kind = Self.kind(forName: output.portName, portType: output.portType)
            let candidate = AudioRouteCandidate(
                name: output.portName,
                portType: output.portType.rawValue,
                kind: kind,
                isInput: false,
                isOutput: true,
                isActive: activeOutputs.contains(key),
                isPreferredCandidate: kind == .glasses || Self.handsFreePortTypes.contains(output.portType)
            )
            if !candidates.contains(where: { $0.name == candidate.name && $0.portType == candidate.portType && $0.isOutput == candidate.isOutput }) {
                candidates.append(candidate)
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.isPreferredCandidate != rhs.isPreferredCandidate {
                return lhs.isPreferredCandidate && !rhs.isPreferredCandidate
            }
            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func kind(forName name: String, portType: AVAudioSession.Port) -> AudioRouteKind {
        if isGlassesLikeName(name) {
            return .glasses
        }
        if portType == .bluetoothHFP || portType == .bluetoothA2DP || portType == .bluetoothLE {
            return .bluetooth
        }
        if portType == .headsetMic || portType == .headphones {
            return .headset
        }
        if portType == .builtInMic || portType == .builtInReceiver || portType == .builtInSpeaker {
            return .builtIn
        }
        return .unknown
    }

    private static let handsFreePortTypes: Set<AVAudioSession.Port> = [
        .bluetoothHFP,
        .bluetoothLE,
        .bluetoothA2DP,
        .headsetMic,
        .headphones
    ]
    #endif

    private static func isGlassesLikeName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("rb meta")
            || normalized.contains("ray-ban")
            || normalized.contains("ray ban")
            || normalized.contains("rayban")
            || normalized.contains("meta")
            || normalized.contains("glasses")
    }

    private static func isExternalLikeName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return isGlassesLikeName(name)
            || normalized.contains("airpods")
            || normalized.contains("beats")
            || normalized.contains("bluetooth")
            || normalized.contains("headset")
            || normalized.contains("headphones")
    }

    private static func kind(forName name: String, fallback: AudioRouteKind) -> AudioRouteKind {
        if isGlassesLikeName(name) {
            return .glasses
        }
        if isExternalLikeName(name) {
            return .bluetooth
        }
        return fallback
    }
}
