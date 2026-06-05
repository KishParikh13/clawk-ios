import Foundation

enum MediaCaptureKind: String, Codable, Equatable {
    case photo
    case video
}

enum MediaCaptureSource: String, Codable, Equatable {
    case automatic
    case phoneCamera
    case glassesCamera
}

struct CaptureIntent: Equatable {
    var mediaKind: MediaCaptureKind
    var source: MediaCaptureSource
    var prompt: String
}

struct CapturedMedia: Equatable {
    var kind: MediaCaptureKind
    var source: MediaCaptureSource
    var filename: String
    var mimeType: String
    var data: Data
    var durationMs: Int?
}

enum CapturedMediaAttachmentError: LocalizedError {
    case unsupportedMediaKind

    var errorDescription: String? {
        switch self {
        case .unsupportedMediaKind:
            return "That capture type is not supported yet."
        }
    }
}

extension ChatAttachment {
    static func capturedMedia(_ media: CapturedMedia) throws -> ChatAttachment {
        switch media.kind {
        case .photo:
            let id = UUID()
            let localFilename = try AttachmentPayloadCache.shared.store(
                data: media.data,
                attachmentId: id,
                filename: media.filename
            )
            return ChatAttachment(
                id: id,
                kind: .image,
                title: media.filename,
                mimeType: media.mimeType,
                byteCount: media.data.count,
                localFilename: localFilename,
                uploadState: .local
            )
        case .video:
            throw CapturedMediaAttachmentError.unsupportedMediaKind
        }
    }
}

