import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct FileTextPickerView: UIViewControllerRepresentable {
    let onResult: (Result<ChatAttachment, Error>) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onResult: (Result<ChatAttachment, Error>) -> Void
        private let onCancel: () -> Void

        init(onResult: @escaping (Result<ChatAttachment, Error>) -> Void, onCancel: @escaping () -> Void) {
            self.onResult = onResult
            self.onCancel = onCancel
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onResult(.failure(FileTextPickerError.noFile))
                return
            }

            Task {
                let result = Self.attachment(from: url)
                await MainActor.run {
                    self.onResult(result)
                }
            }
        }

        private static func attachment(from url: URL) -> Result<ChatAttachment, Error> {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let title = url.lastPathComponent.isEmpty ? "File" : url.lastPathComponent
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let id = UUID()
                let mimeType = Self.mimeType(for: url)
                let localFilename = try AttachmentPayloadCache.shared.store(data: data, attachmentId: id, filename: title)
                let previewText = String(data: Data(data.prefix(200_000)), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .success(
                    ChatAttachment(
                        id: id,
                        kind: Self.kind(for: mimeType),
                        title: title,
                        text: previewText?.isEmpty == false ? previewText : nil,
                        mimeType: mimeType,
                        byteCount: data.count,
                        localFilename: localFilename,
                        uploadState: .local
                    )
                )
            } catch {
                return .failure(error)
            }
        }

        private static func mimeType(for url: URL) -> String {
            if let type = UTType(filenameExtension: url.pathExtension),
               let mimeType = type.preferredMIMEType {
                return mimeType
            }
            return "application/octet-stream"
        }

        private static func kind(for mimeType: String) -> ChatAttachment.Kind {
            mimeType.lowercased().hasPrefix("image/") ? .image : .file
        }
    }
}

enum FileTextPickerError: LocalizedError {
    case noFile

    var errorDescription: String? {
        "No file selected."
    }
}
