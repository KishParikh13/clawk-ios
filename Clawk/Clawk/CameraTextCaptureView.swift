import ImageIO
import SwiftUI
import UIKit
@preconcurrency import Vision

struct CameraTextCaptureView: UIViewControllerRepresentable {
    let onResult: (Result<String, Error>) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onResult: (Result<String, Error>) -> Void
        private let onCancel: () -> Void

        init(onResult: @escaping (Result<String, Error>) -> Void, onCancel: @escaping () -> Void) {
            self.onResult = onResult
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                picker.dismiss(animated: true)
                onResult(.failure(ImageTextExtractionError.noImage))
                return
            }

            picker.dismiss(animated: true)
            Task {
                do {
                    let text = try await ImageTextExtractor.extractText(from: image)
                    await MainActor.run {
                        self.onResult(.success(text))
                    }
                } catch {
                    await MainActor.run {
                        self.onResult(.failure(error))
                    }
                }
            }
        }
    }
}

enum ImageTextExtractor {
    static func extractText(from image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw ImageTextExtractionError.unreadableImage
        }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    let text = (request.results as? [VNRecognizedTextObservation])?
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if text.isEmpty {
                        continuation.resume(throwing: ImageTextExtractionError.noText)
                    } else {
                        continuation.resume(returning: text)
                    }
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(
                    cgImage: cgImage,
                    orientation: orientation,
                    options: [:]
                )

                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum ImageTextExtractionError: LocalizedError {
    case noImage
    case unreadableImage
    case noText

    var errorDescription: String? {
        switch self {
        case .noImage:
            return "No image selected."
        case .unreadableImage:
            return "Could not read that image."
        case .noText:
            return "No text found."
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up:
            self = .up
        case .upMirrored:
            self = .upMirrored
        case .down:
            self = .down
        case .downMirrored:
            self = .downMirrored
        case .left:
            self = .left
        case .leftMirrored:
            self = .leftMirrored
        case .right:
            self = .right
        case .rightMirrored:
            self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
