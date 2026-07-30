// Photos-picker and file-based media ingestion.

import AVFoundation
import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// User-facing failures produced while importing media.
enum MediaImportError: LocalizedError {
    case missingData
    case invalidImage
    case unsupportedMedia
    case invalidDuration
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
        case .invalidDuration:
            "The selected media has no readable duration."
        case .videoWriterUnavailable:
            "Motionary could not create a video writer."
        case .pixelBufferCreationFailed:
            "Motionary could not allocate a video frame."
        }
    }
}

/// Imported source metadata paired with its project-local URL.
struct ImportedMedia {
    var source: ClipSource
    var storedURL: URL
}

private struct PickedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try PickedVideoFile(url: copyTransferredFile(received.file, fallbackExtension: "mov"))
        }
    }
}

private struct PickedImageFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try PickedImageFile(url: copyTransferredFile(received.file, fallbackExtension: "img"))
        }
    }
}

private func copyTransferredFile(_ sourceURL: URL, fallbackExtension: String) throws -> URL {
    let ext = sourceURL.pathExtension.isEmpty ? fallbackExtension : sourceURL.pathExtension
    let destinationURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).\(ext)")
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
}

/// Copies selected media into project storage and derives render metadata.
struct MediaImportService {
    func importPhotosItem(_ item: PhotosPickerItem, projectID: UUID, projectStore: ProjectStore) async throws
        -> ImportedMedia
    {
        let supportedTypes = item.supportedContentTypes
        if supportedTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let transferred = try await item.loadTransferable(type: PickedVideoFile.self) else {
                throw MediaImportError.missingData
            }
            defer { try? FileManager.default.removeItem(at: transferred.url) }

            var source = try await makeSource(for: transferred.url, fallbackMediaType: .video)
            let storedURL = try projectStore.storeMedia(from: transferred.url, projectID: projectID)
            source.url = storedURL
            return ImportedMedia(source: source, storedURL: storedURL)
        }

        if supportedTypes.contains(where: { $0.conforms(to: .image) }) {
            guard let transferred = try await item.loadTransferable(type: PickedImageFile.self) else {
                throw MediaImportError.missingData
            }
            defer { try? FileManager.default.removeItem(at: transferred.url) }

            let normalized = try MediaConversionHelper.normalizedStillImageFile(
                at: transferred.url,
                maxPixelSize: 2560
            )
            defer { try? FileManager.default.removeItem(at: normalized.url) }
            let storedURL = try projectStore.storeMedia(from: normalized.url, projectID: projectID)
            let naturalSize = CGSizeValue(normalized.size)
            let source = ClipSource(
                url: storedURL,
                mediaType: .image,
                originalDuration: 5,
                naturalSize: naturalSize
            )
            return ImportedMedia(source: source, storedURL: storedURL)
        }

        throw MediaImportError.unsupportedMedia
    }

    func importAudioFromPhotosItem(
        _ item: PhotosPickerItem,
        projectID: UUID,
        projectStore: ProjectStore
    ) async throws -> ImportedMedia {
        guard item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
            let transferred = try await item.loadTransferable(type: PickedVideoFile.self)
        else {
            throw MediaImportError.unsupportedMedia
        }
        defer { try? FileManager.default.removeItem(at: transferred.url) }

        var source = try await makeSource(for: transferred.url, fallbackMediaType: .video)
        guard source.mediaType == .video else {
            throw MediaImportError.unsupportedMedia
        }
        let asset = AVURLAsset(url: transferred.url)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw MediaImportError.unsupportedMedia
        }
        let storedURL = try projectStore.storeMedia(from: transferred.url, projectID: projectID)
        source.url = storedURL
        source.mediaType = .audio
        source.naturalSize = nil
        return ImportedMedia(source: source, storedURL: storedURL)
    }

    func importAudioFile(_ url: URL, projectID: UUID, projectStore: ProjectStore) async throws -> ImportedMedia {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var source = try await makeSource(for: url, fallbackMediaType: .audio)
        let storedURL = try projectStore.storeMedia(from: url, projectID: projectID)
        source.url = storedURL
        return ImportedMedia(source: source, storedURL: storedURL)
    }

    func makeSource(for url: URL, fallbackMediaType: ClipMediaType) async throws -> ClipSource {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw MediaImportError.unsupportedMedia
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else {
            throw MediaImportError.invalidDuration
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        if fallbackMediaType == .audio, audioTracks.first != nil {
            return ClipSource(
                url: url,
                mediaType: .audio,
                originalDuration: duration,
                naturalSize: nil
            )
        }

        if let videoTrack = videoTracks.first {
            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let displayRect = VideoSourceGeometry.displayRect(
                naturalSize: naturalSize,
                transform: preferredTransform
            )
            return ClipSource(
                url: url,
                mediaType: fallbackMediaType == .image ? .image : .video,
                originalDuration: duration,
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
                originalDuration: duration,
                naturalSize: nil
            )
        }

        throw MediaImportError.unsupportedMedia
    }
}
