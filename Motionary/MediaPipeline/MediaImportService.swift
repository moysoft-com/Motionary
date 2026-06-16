import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum MediaImportError: LocalizedError {
    case missingData
    case invalidImage
    case unsupportedMedia
    case videoWriterUnavailable
    case pixelBufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .missingData:
            "The selected media could not be loaded."
        case .invalidImage:
            "The selected image could not be decoded."
        case .unsupportedMedia:
            "This media type is not supported yet."
        case .videoWriterUnavailable:
            "Motionary could not create a video writer."
        case .pixelBufferCreationFailed:
            "Motionary could not allocate a video frame."
        }
    }
}

struct ImportedMedia {
    var source: ClipSource
    var storedURL: URL
}

struct MediaImportService {
    func importPhotosItem(_ item: PhotosPickerItem, projectID: UUID, projectStore: ProjectStore) async throws -> ImportedMedia {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw MediaImportError.missingData
        }

        let preferredType = item.supportedContentTypes.first
        if preferredType?.conforms(to: .image) == true, let image = UIImage(data: data) {
            let videoURL = try await MediaConversionHelper.imageToVideo(image: image, duration: 5)
            let storedURL = projectStore.storeMedia(from: videoURL, projectID: projectID)
            let naturalSize = image.cgImage.map { CGSizeValue(width: Double($0.width), height: Double($0.height)) }
            let source = ClipSource(
                url: storedURL,
                mediaType: .image,
                originalDuration: 5,
                naturalSize: naturalSize
            )
            return ImportedMedia(source: source, storedURL: storedURL)
        }

        let fileExtension = preferredType?.preferredFilenameExtension ?? "mov"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try data.write(to: tempURL, options: [.atomic])

        let storedURL = projectStore.storeMedia(from: tempURL, projectID: projectID)
        let source = try await makeSource(for: storedURL, fallbackMediaType: .video)
        return ImportedMedia(source: source, storedURL: storedURL)
    }

    func importAudioFile(_ url: URL, projectID: UUID, projectStore: ProjectStore) async throws -> ImportedMedia {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let storedURL = projectStore.storeMedia(from: url, projectID: projectID)
        let source = try await makeSource(for: storedURL, fallbackMediaType: .audio)
        return ImportedMedia(source: source, storedURL: storedURL)
    }

    func makeSource(for url: URL, fallbackMediaType: ClipMediaType) async throws -> ClipSource {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        if let videoTrack = videoTracks.first {
            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            return ClipSource(
                url: url,
                mediaType: fallbackMediaType == .image ? .image : .video,
                originalDuration: duration.isFinite ? duration : 0,
                naturalSize: CGSizeValue(
                    width: Double(abs(displayRect.width)),
                    height: Double(abs(displayRect.height))
                )
            )
        }

        if audioTracks.first != nil {
            return ClipSource(
                url: url,
                mediaType: .audio,
                originalDuration: duration.isFinite ? duration : 0,
                naturalSize: nil
            )
        }

        throw MediaImportError.unsupportedMedia
    }
}
