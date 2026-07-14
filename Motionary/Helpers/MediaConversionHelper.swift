// Image normalization and still-image video conversion.

import AVFoundation
import ImageIO
import UIKit

/// Converts imported still images into orientation-safe video assets for the shared render pipeline.
enum MediaConversionHelper {
    static let stillVideoSourceFrameCount = 1

    /// Returns a temporary one-frame movie that only supplies AVFoundation's
    /// timing source for generated visual layers such as text.
    static func blankVideoClockURL(duration: Double, frameRate: Int32) async throws -> URL {
        try await BlankVideoClockCache.shared.url(
            duration: duration,
            frameRate: frameRate
        )
    }

    /// Loads an image without decoding its full source resolution into memory.
    static func downsampledImage(at url: URL, maxPixelSize: CGFloat = 4096) throws -> UIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MediaImportError.invalidImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MediaImportError.invalidImage
        }
        return UIImage(cgImage: image)
    }

    /// Redraws an image so its pixels use upright orientation metadata.
    static func normalizedImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else {
            return image
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false

        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Writes a still image as a fixed-duration, single-frame movie.
    static func imageToVideo(image: UIImage, duration: Double, frameRate: Int32 = 30) async throws -> URL {
        try await writeImageToVideo(
            image: image,
            duration: duration,
            frameRate: frameRate
        )
    }

    private static func writeImageToVideo(
        image: UIImage,
        duration: Double,
        frameRate: Int32
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let normalizedImage = normalizedImage(image)
        guard let cgImage = normalizedImage.cgImage else {
            throw MediaImportError.invalidImage
        }

        let videoSize = CGSize(
            width: max(cgImage.width - cgImage.width % 2, 2),
            height: max(cgImage.height - cgImage.height % 2, 2)
        )
        let frameDuration = CMTime(value: 1, timescale: max(frameRate, 1))
        let stillDuration = CMTime(
            seconds: max(duration, CMTimeGetSeconds(frameDuration)),
            preferredTimescale: 600
        )
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        let encodedImage = UIGraphicsImageRenderer(
            size: videoSize,
            format: rendererFormat
        ).image { _ in
            normalizedImage.draw(in: CGRect(origin: .zero, size: videoSize))
        }
        guard let jpegData = encodedImage.jpegData(compressionQuality: 0.96) else {
            throw MediaImportError.invalidImage
        }

        var formatDescription: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_JPEG,
                width: Int32(videoSize.width),
                height: Int32(videoSize.height),
                extensions: nil,
                formatDescriptionOut: &formatDescription
            ) == noErr,
            let formatDescription
        else {
            throw MediaImportError.videoWriterUnavailable
        }

        var blockBuffer: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: jpegData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: jpegData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ) == noErr,
            let blockBuffer
        else {
            throw MediaImportError.videoWriterUnavailable
        }
        let copyStatus = jpegData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: jpegData.count
            )
        }
        guard copyStatus == noErr else {
            throw MediaImportError.videoWriterUnavailable
        }

        var timing = CMSampleTimingInfo(
            duration: stillDuration,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = jpegData.count
        var sampleBuffer: CMSampleBuffer?
        guard
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            ) == noErr,
            let sampleBuffer
        else {
            throw MediaImportError.videoWriterUnavailable
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw MediaImportError.videoWriterUnavailable
        }
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw writer.error ?? MediaImportError.videoWriterUnavailable
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try Task.checkCancellation()
            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard writerInput.append(sampleBuffer) else {
                throw writer.error ?? MediaImportError.videoWriterUnavailable
            }

            writer.endSession(atSourceTime: stillDuration)
            writerInput.markAsFinished()
            await writer.finishWriting()

            if let error = writer.error {
                throw error
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        return outputURL
    }
}

private actor BlankVideoClockCache {
    static let shared = BlankVideoClockCache()

    private struct Key: Hashable {
        let durationTicks: Int64
        let frameRate: Int32
    }

    private var urls: [Key: URL] = [:]

    func url(duration: Double, frameRate: Int32) async throws -> URL {
        let safeFrameRate = max(frameRate, 1)
        let minimumDuration = 1 / Double(safeFrameRate)
        let durationTicks = CMTime(
            seconds: max(duration, minimumDuration),
            preferredTimescale: 600
        ).value
        let key = Key(durationTicks: durationTicks, frameRate: safeFrameRate)
        if let cached = urls[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 2),
            format: format
        ).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let result = try await MediaConversionHelper.imageToVideo(
            image: image,
            duration: CMTimeGetSeconds(
                CMTime(value: durationTicks, timescale: 600)
            ),
            frameRate: safeFrameRate
        )
        urls[key] = result
        return result
    }
}
