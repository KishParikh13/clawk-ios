import AVFoundation
import Foundation

@MainActor
final class AudioRouteMonitor: ObservableObject {
    @Published private(set) var inputName = "System"
    @Published private(set) var outputName = "System"
    @Published private(set) var status = "System"

    private var isStarted = false

    var statusLabel: String {
        status
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
        let route = AVAudioSession.sharedInstance().currentRoute
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

    #if os(iOS)
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
