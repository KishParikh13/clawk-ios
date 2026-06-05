import AVFoundation
import UIKit

final class ProgrammaticPhoneCameraCapture: NSObject, @unchecked Sendable {
    static let shared = ProgrammaticPhoneCameraCapture()

    enum CaptureError: LocalizedError {
        case noCamera
        case cameraPermissionDenied
        case sessionFailed(String)
        case captureFailed(String)
        case dataMissing

        var errorDescription: String? {
            switch self {
            case .noCamera:
                return "No rear camera is available."
            case .cameraPermissionDenied:
                return "Camera permission is required."
            case .sessionFailed(let message):
                return "Camera session failed: \(message)"
            case .captureFailed(let message):
                return "Photo capture failed: \(message)"
            case .dataMissing:
                return "Captured photo had no image data."
            }
        }
    }

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.kishparikh.clawk.phone-camera-capture")
    private var isConfigured = false
    private var continuation: CheckedContinuation<Data, Error>?

    func capturePhoto() async throws -> CapturedMedia {
        try await ensureCameraPermission()
        try await configureIfNeeded()
        let data = try await captureJPEGData()
        let filename = "PhonePhoto-\(Self.filenameTimestamp()).jpg"
        return CapturedMedia(
            kind: .photo,
            source: .phoneCamera,
            filename: filename,
            mimeType: "image/jpeg",
            data: data,
            durationMs: nil
        )
    }

    private func ensureCameraPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                throw CaptureError.cameraPermissionDenied
            }
        default:
            throw CaptureError.cameraPermissionDenied
        }
    }

    private func configureIfNeeded() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                if self.isConfigured {
                    continuation.resume()
                    return
                }

                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    continuation.resume(throwing: CaptureError.noCamera)
                    return
                }

                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo

                    guard self.session.canAddInput(input) else {
                        self.session.commitConfiguration()
                        continuation.resume(throwing: CaptureError.sessionFailed("Could not add camera input."))
                        return
                    }
                    self.session.addInput(input)

                    guard self.session.canAddOutput(self.output) else {
                        self.session.commitConfiguration()
                        continuation.resume(throwing: CaptureError.sessionFailed("Could not add photo output."))
                        return
                    }
                    self.session.addOutput(self.output)
                    self.session.commitConfiguration()
                    self.isConfigured = true
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: CaptureError.sessionFailed(error.localizedDescription))
                }
            }
        }
    }

    private func captureJPEGData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                guard self.continuation == nil else {
                    continuation.resume(throwing: CaptureError.captureFailed("A photo capture is already running."))
                    return
                }

                self.continuation = continuation
                if !self.session.isRunning {
                    self.session.startRunning()
                }

                self.sessionQueue.asyncAfter(deadline: .now() + 0.25) {
                    let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                    self.output.capturePhoto(with: settings, delegate: self)
                }
            }
        }
    }

    private static func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

extension ProgrammaticPhoneCameraCapture: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let continuation = self.continuation
        self.continuation = nil

        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }

        if let error {
            continuation?.resume(throwing: CaptureError.captureFailed(error.localizedDescription))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            continuation?.resume(throwing: CaptureError.dataMissing)
            return
        }

        continuation?.resume(returning: Self.downsizedJPEG(data) ?? data)
    }

    private static func downsizedJPEG(_ data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.74) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let width = image.size.width
        let height = image.size.height
        let longEdge = max(width, height)
        guard longEdge > maxDimension else {
            return image.jpegData(compressionQuality: quality)
        }

        let scale = maxDimension / longEdge
        let newSize = CGSize(width: width * scale, height: height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
