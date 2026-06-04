import SwiftUI
import UIKit

struct CameraAttachmentPickerView: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onResult: (Result<ChatAttachment, Error>) -> Void
    let onCancel: () -> Void

    init(
        sourceType: UIImagePickerController.SourceType = .camera,
        onResult: @escaping (Result<ChatAttachment, Error>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.sourceType = sourceType
        self.onResult = onResult
        self.onCancel = onCancel
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(sourceType) ? sourceType : .photoLibrary
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(sourceType: sourceType, onResult: onResult, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let sourceType: UIImagePickerController.SourceType
        private let onResult: (Result<ChatAttachment, Error>) -> Void
        private let onCancel: () -> Void

        init(
            sourceType: UIImagePickerController.SourceType,
            onResult: @escaping (Result<ChatAttachment, Error>) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.sourceType = sourceType
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
                onResult(.failure(ImageAttachmentPickerError.noImage))
                return
            }

            picker.dismiss(animated: true)
            let filename = (info[.imageURL] as? URL)?.lastPathComponent ?? (sourceType == .camera ? "Camera.jpg" : "Photo.jpg")
            Task {
                do {
                    let attachment = try await Self.imageAttachment(from: image, filename: filename)
                    await MainActor.run {
                        self.onResult(.success(attachment))
                    }
                } catch {
                    await MainActor.run {
                        self.onResult(.failure(error))
                    }
                }
            }
        }

        private static func imageAttachment(from image: UIImage, filename: String) async throws -> ChatAttachment {
            let normalizedFilename = filename.isEmpty ? "Photo.jpg" : filename
            let data: Data
            let mimeType: String
            if let jpegData = image.jpegData(compressionQuality: 0.92) {
                data = jpegData
                mimeType = "image/jpeg"
            } else if let pngData = image.pngData() {
                data = pngData
                mimeType = "image/png"
            } else {
                throw ImageAttachmentPickerError.unreadableImage
            }

            let id = UUID()
            let localFilename = try AttachmentPayloadCache.shared.store(
                data: data,
                attachmentId: id,
                filename: normalizedFilename
            )
            return ChatAttachment(
                id: id,
                kind: .image,
                title: normalizedFilename,
                mimeType: mimeType,
                byteCount: data.count,
                localFilename: localFilename,
                uploadState: .local
            )
        }
    }
}

enum ImageAttachmentPickerError: LocalizedError {
    case noImage
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .noImage:
            return "No image selected."
        case .unreadableImage:
            return "Could not read that image."
        }
    }
}
