import Foundation
import os

#if canImport(MWDATCore) && canImport(MWDATCamera)
import MWDATCamera
import MWDATCore

@MainActor
final class GlassesCameraCaptureController: ObservableObject {
    enum Status: String {
        case unavailable
        case available
        case registering
        case registered
        case waitingForDevice
        case streaming
        case failed

        var label: String {
            switch self {
            case .unavailable: return "Unavailable"
            case .available: return "Available"
            case .registering: return "Registering"
            case .registered: return "Registered"
            case .waitingForDevice: return "Waiting"
            case .streaming: return "Ready"
            case .failed: return "Failed"
            }
        }
    }

    @Published private(set) var status: Status = .unavailable
    @Published private(set) var lastError: String?
    @Published private(set) var devices: [DeviceIdentifier] = []
    @Published private(set) var cameraPermission = "Unknown"
    @Published private(set) var hasActiveDevice = false

    private let deviceSelector: AutoDeviceSelector
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var activeDeviceTask: Task<Void, Never>?
    private var sessionStateTask: Task<Void, Never>?
    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var stateToken: AnyListenerToken?
    private var errorToken: AnyListenerToken?
    private var photoToken: AnyListenerToken?
    private var photoContinuation: CheckedContinuation<Data, Error>?
    private let log = Logger(subsystem: "com.kishparikh.clawk", category: "glasses-camera")

    init() {
        self.deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
    }

    var isReadyForCapture: Bool {
        status == .streaming
    }

    var canAttemptCapture: Bool {
        switch status {
        case .available, .registered, .waitingForDevice, .streaming:
            return true
        case .registering, .failed, .unavailable:
            return false
        }
    }

    func start() {
        guard registrationTask == nil else { return }
        status = Self.status(for: Wearables.shared.registrationState)
        debugLog("start registrationState=\(Wearables.shared.registrationState) status=\(status.rawValue)")

        registrationTask = Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                await MainActor.run {
                    self?.status = Self.status(for: state)
                    if state == .registered {
                        self?.lastError = nil
                    }
                    self?.debugLog("registrationStateStream state=\(state) status=\(self?.status.rawValue ?? "unknown")")
                }
            }
        }

        devicesTask = Task { [weak self] in
            for await devices in Wearables.shared.devicesStream() {
                await MainActor.run {
                    self?.devices = devices
                    self?.debugLog("devicesStream count=\(devices.count) devices=\(devices.map { "\($0)" }.joined(separator: ","))")
                    if devices.isEmpty, self?.status == .streaming || self?.status == .waitingForDevice {
                        self?.status = .registered
                    }
                }
            }
        }

        activeDeviceTask = Task { [weak self] in
            guard let self else { return }
            for await device in self.deviceSelector.activeDeviceStream() {
                await MainActor.run {
                    self.hasActiveDevice = device != nil
                    self.debugLog("activeDeviceStream active=\(device != nil) device=\(device.map { "\($0)" } ?? "nil")")
                }
            }
        }
    }

    func register() {
        Task {
            do {
                debugLog("register requested")
                start()
                if Wearables.shared.registrationState == .registered {
                    status = .registered
                    lastError = nil
                    debugLog("register skipped; already registered")
                    return
                }
                status = .registering
                try await Wearables.shared.startRegistration()
                debugLog("register startRegistration returned state=\(Wearables.shared.registrationState)")
            } catch {
                lastError = error.localizedDescription
                status = Self.status(for: Wearables.shared.registrationState)
                if Wearables.shared.registrationState != .registered {
                    status = .failed
                }
                debugLog("register failed error=\(error.localizedDescription)")
            }
        }
    }

    func refreshStatus() {
        Task {
            start()
            let registrationState = Wearables.shared.registrationState
            status = Self.status(for: registrationState)
            debugLog("refreshStatus registrationState=\(registrationState) status=\(status.rawValue) devices=\(devices.count) activeDevice=\(hasActiveDevice)")

            guard registrationState == .registered else {
                cameraPermission = "Not checked"
                return
            }

            do {
                let permissionStatus = try await Wearables.shared.checkPermissionStatus(.camera)
                cameraPermission = "\(permissionStatus)"
                lastError = nil
                debugLog("refreshStatus cameraPermission=\(permissionStatus)")
            } catch {
                cameraPermission = "Check failed"
                lastError = error.localizedDescription
                debugLog("refreshStatus cameraPermission check failed error=\(error.localizedDescription)")
            }
        }
    }

    func requestCameraPermission() {
        Task {
            start()
            let registrationState = Wearables.shared.registrationState
            status = Self.status(for: registrationState)
            guard registrationState == .registered else {
                lastError = CaptureFailure.notRegistered.localizedDescription
                debugLog("requestCameraPermission skipped; not registered state=\(registrationState)")
                return
            }

            do {
                let permissionStatus = try await Wearables.shared.requestPermission(.camera)
                cameraPermission = "\(permissionStatus)"
                if permissionStatus == .granted {
                    lastError = nil
                } else {
                    lastError = "Camera permission is \(permissionStatus)."
                }
                debugLog("requestCameraPermission returned status=\(permissionStatus)")
            } catch {
                cameraPermission = "Request failed"
                lastError = error.localizedDescription
                debugLog("requestCameraPermission failed error=\(error.localizedDescription)")
            }
        }
    }

    func capturePhoto(timeout: TimeInterval = 5.0) async throws -> CapturedMedia {
        debugLog("capturePhoto requested status=\(status.rawValue) registrationState=\(Wearables.shared.registrationState) devices=\(devices.count) permission=\(cameraPermission)")
        do {
            try await ensureStreaming(timeout: timeout)
            guard let stream else {
                debugLog("capturePhoto failed stream=nil")
                throw CaptureFailure.notReady
            }

            let data = try await withCheckedThrowingContinuation { continuation in
                self.photoContinuation = continuation
                let accepted = stream.capturePhoto(format: .jpeg)
                debugLog("capturePhoto command accepted=\(accepted)")
                if !accepted {
                    finishPhotoCapture(.failure(CaptureFailure.captureRejected))
                    return
                }

                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await MainActor.run {
                        self?.finishPhotoCapture(.failure(CaptureFailure.timeout))
                    }
                }
            }
            debugLog("capturePhoto completed bytes=\(data.count)")
            lastError = nil
            await stopCameraStream(reason: "photo completed")

            return CapturedMedia(
                kind: .photo,
                source: .glassesCamera,
                filename: "GlassesPhoto-\(Self.filenameTimestamp()).jpg",
                mimeType: "image/jpeg",
                data: data,
                durationMs: nil
            )
        } catch {
            lastError = error.localizedDescription
            debugLog("capturePhoto failed error=\(error.localizedDescription)")
            await stopCameraStream(reason: "photo failed")
            throw error
        }
    }

    private func ensureStreaming(timeout: TimeInterval) async throws {
        start()
        debugLog("ensureStreaming begin registrationState=\(Wearables.shared.registrationState) status=\(status.rawValue)")

        guard Wearables.shared.registrationState == .registered else {
            debugLog("ensureStreaming notRegistered state=\(Wearables.shared.registrationState)")
            throw CaptureFailure.notRegistered
        }

        let permission = Permission.camera
        var permissionStatus: PermissionStatus
        do {
            permissionStatus = try await Wearables.shared.checkPermissionStatus(permission)
            cameraPermission = "\(permissionStatus)"
            debugLog("camera permission checked status=\(permissionStatus)")
        } catch {
            cameraPermission = "Check failed"
            debugLog("camera permission check failed error=\(error.localizedDescription); requesting permission")
            permissionStatus = try await Wearables.shared.requestPermission(permission)
            cameraPermission = "\(permissionStatus)"
            debugLog("camera permission request after check failure returned status=\(permissionStatus)")
        }
        if permissionStatus != .granted {
            debugLog("camera permission requesting from status=\(permissionStatus)")
            permissionStatus = try await Wearables.shared.requestPermission(permission)
            cameraPermission = "\(permissionStatus)"
            debugLog("camera permission request returned status=\(permissionStatus)")
        }
        guard permissionStatus == .granted else {
            lastError = CaptureFailure.permissionDenied.localizedDescription
            debugLog("camera permission denied status=\(permissionStatus)")
            throw CaptureFailure.permissionDenied
        }
        lastError = nil

        if stream != nil, status == .streaming {
            debugLog("ensureStreaming reusing active stream")
            return
        }

        let session = try await readySession(timeout: timeout)
        debugLog("ensureStreaming session ready state=\(session.state)")
        let config = StreamConfiguration(
            videoCodec: VideoCodec.raw,
            resolution: StreamingResolution.low,
            frameRate: 15
        )
        guard let newStream = try session.addStream(config: config) else {
            debugLog("addStream returned nil")
            throw CaptureFailure.notReady
        }

        stream = newStream
        status = .waitingForDevice
        stateToken = newStream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                self?.handleStreamState(state)
            }
        }
        errorToken = newStream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                self?.lastError = error.localizedDescription
                self?.debugLog("stream error=\(error.localizedDescription)")
            }
        }
        photoToken = newStream.photoDataPublisher.listen { [weak self] data in
            Task { @MainActor in
                self?.debugLog("photoDataPublisher bytes=\(data.data.count)")
                self?.finishPhotoCapture(.success(data.data))
            }
        }

        debugLog("stream start requested")
        await newStream.start()
        try await waitUntilStreaming(timeout: timeout)
        debugLog("stream is streaming")
    }

    private func readySession(timeout: TimeInterval) async throws -> DeviceSession {
        if let deviceSession, deviceSession.state == .started {
            debugLog("readySession reusing started session")
            return deviceSession
        }
        if deviceSession?.state == .stopped {
            debugLog("readySession discarding stopped session")
            deviceSession = nil
        }

        debugLog("readySession createSession devices=\(devices.count)")
        try await waitForActiveDevice(timeout: timeout)
        let session = try Wearables.shared.createSession(deviceSelector: deviceSelector)
        deviceSession = session
        let stateStream = session.stateStream()
        debugLog("readySession starting session initialState=\(session.state)")
        try session.start()

        if session.state == .started {
            debugLog("readySession started synchronously")
            observeSession(session)
            return session
        }

        let deadline = Date().addingTimeInterval(timeout)
        for await state in stateStream {
            debugLog("readySession stateStream state=\(state)")
            if state == .started {
                observeSession(session)
                return session
            }
            if state == .stopped || Date() > deadline {
                break
            }
        }
        throw CaptureFailure.notReady
    }

    private func waitForActiveDevice(timeout: TimeInterval) async throws {
        if hasActiveDevice {
            debugLog("waitForActiveDevice already active")
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        debugLog("waitForActiveDevice begin")
        for await device in deviceSelector.activeDeviceStream() {
            debugLog("waitForActiveDevice active=\(device != nil) device=\(device.map { "\($0)" } ?? "nil")")
            if device != nil {
                hasActiveDevice = true
                return
            }
            if Date() > deadline {
                break
            }
        }
        debugLog("waitForActiveDevice timed out")
        throw CaptureFailure.noEligibleDevice
    }

    private func observeSession(_ session: DeviceSession) {
        sessionStateTask?.cancel()
        sessionStateTask = Task { [weak self] in
            for await state in session.stateStream() {
                await MainActor.run {
                    self?.debugLog("observeSession state=\(state)")
                    if state == .stopped {
                        self?.stream = nil
                        self?.deviceSession = nil
                        self?.status = .registered
                    } else if state == .paused {
                        self?.status = .waitingForDevice
                    }
                }
            }
        }
    }

    private func stopCameraStream(reason: String) async {
        let activeStream = stream
        debugLog("stopCameraStream reason=\(reason) stream=\(activeStream != nil) sessionState=\(deviceSession.map { "\($0.state)" } ?? "nil")")

        stream = nil
        clearStreamListeners()

        if let activeStream {
            await activeStream.stop()
        }

        if deviceSession?.state == .stopped {
            deviceSession = nil
        }

        if Wearables.shared.registrationState == .registered, deviceSession?.state != .paused {
            status = .registered
        } else {
            status = Self.status(for: Wearables.shared.registrationState)
        }
    }

    private func clearStreamListeners() {
        stateToken = nil
        errorToken = nil
        photoToken = nil
    }

    private func waitUntilStreaming(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status == .streaming {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CaptureFailure.timeout
    }

    private func handleStreamState(_ state: StreamState) {
        debugLog("stream state=\(state)")
        switch state {
        case .streaming:
            status = .streaming
        case .waitingForDevice, .starting, .paused, .stopping:
            status = .waitingForDevice
        case .stopped:
            status = .registered
            stream = nil
        }
    }

    private func finishPhotoCapture(_ result: Result<Data, Error>) {
        guard let continuation = photoContinuation else { return }
        photoContinuation = nil
        switch result {
        case .success(let data):
            debugLog("finishPhotoCapture success bytes=\(data.count)")
            continuation.resume(returning: data)
        case .failure(let error):
            debugLog("finishPhotoCapture failure error=\(error.localizedDescription)")
            continuation.resume(throwing: error)
        }
    }

    private func debugLog(_ message: String) {
        log.info("\(message, privacy: .public)")
        print("[GlassesCamera] \(message)")
    }

    private static func status(for registrationState: RegistrationState) -> Status {
        switch registrationState {
        case .registered:
            return .registered
        case .registering:
            return .registering
        case .available:
            return .available
        case .unavailable:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    private static func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private enum CaptureFailure: LocalizedError {
    case notRegistered
    case permissionDenied
    case notReady
    case noEligibleDevice
    case captureRejected
    case timeout

    var errorDescription: String? {
        switch self {
        case .notRegistered:
            return "Register glasses in Settings before using the glasses camera."
        case .permissionDenied:
            return "Glasses camera permission is required."
        case .notReady:
            return "Glasses camera is not ready."
        case .noEligibleDevice:
            return "No eligible glasses camera device is available."
        case .captureRejected:
            return "Glasses did not accept the photo capture request."
        case .timeout:
            return "Glasses photo capture timed out."
        }
    }
}

#else
@MainActor
final class GlassesCameraCaptureController: ObservableObject {
    enum Status: String {
        case unavailable

        var label: String { "Unavailable" }
    }

    @Published private(set) var status: Status = .unavailable
    @Published private(set) var lastError: String?
    @Published private(set) var devices: [String] = []
    @Published private(set) var cameraPermission = "Unavailable"
    @Published private(set) var hasActiveDevice = false

    var isReadyForCapture: Bool { false }
    var canAttemptCapture: Bool { false }

    func start() {}
    func register() {}
    func refreshStatus() {}
    func requestCameraPermission() {}

    func capturePhoto(timeout: TimeInterval = 5.0) async throws -> CapturedMedia {
        throw CaptureFailure.notReady
    }
}

private enum CaptureFailure: LocalizedError {
    case notReady

    var errorDescription: String? {
        "Meta Wearables DAT is not linked in this build."
    }
}
#endif
