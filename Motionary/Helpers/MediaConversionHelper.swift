// Image decoding plus the isolated AVFoundation clock source used by generated layers.

import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct NormalizedStillImage {
    let url: URL
    let size: CGSize
}

enum MediaConversionHelper {
    /// Returns a temporary 2x2 movie that only supplies AVFoundation's
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

    /// Writes an orientation-applied still image to a temporary PNG so render
    /// metadata and stored pixels use the same upright coordinate system.
    static func normalizedStillImageFile(
        at url: URL,
        maxPixelSize: CGFloat = 4096
    ) throws -> NormalizedStillImage {
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

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw MediaImportError.invalidImage
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation as String: CGImagePropertyOrientation.up.rawValue] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw MediaImportError.invalidImage
        }

        return NormalizedStillImage(
            url: outputURL,
            size: CGSize(width: image.width, height: image.height)
        )
    }

    /// Creates the single shared 2x2 clock track required by AVFoundation for
    /// generated-only intervals. It never carries user-visible image pixels.
    fileprivate static func writeBlankVideoClock(
        duration: Double,
        frameRate: Int32
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let videoSize = CGSize(width: 2, height: 2)
        let frameDuration = CMTime(value: 1, timescale: max(frameRate, 1))
        let stillDuration = CMTime(
            seconds: max(duration, CMTimeGetSeconds(frameDuration)),
            preferredTimescale: 600
        )
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(videoSize.width),
                AVVideoHeightKey: Int(videoSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 1_000,
                    AVVideoExpectedSourceFrameRateKey: frameRate,
                    AVVideoMaxKeyFrameIntervalKey: Int(frameRate)
                ]
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw MediaImportError.videoWriterUnavailable
        }
        writer.add(writerInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(videoSize.width),
                kCVPixelBufferHeightKey as String: Int(videoSize.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
            ]
        )
        let framePixelBuffer = try blackClockPixelBuffer(size: videoSize)
        guard writer.startWriting() else {
            throw writer.error ?? MediaImportError.videoWriterUnavailable
        }
        writer.startSession(atSourceTime: .zero)

        do {
            let frameCount = max(
                Int(ceil(CMTimeGetSeconds(stillDuration) * Double(max(frameRate, 1)))),
                1
            )
            for frameIndex in 0..<frameCount {
                try Task.checkCancellation()
                while !writerInput.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                let time = CMTime(value: CMTimeValue(frameIndex), timescale: max(frameRate, 1))
                guard adaptor.append(framePixelBuffer, withPresentationTime: time) else {
                    throw writer.error ?? MediaImportError.videoWriterUnavailable
                }
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

    private static func blackClockPixelBuffer(size: CGSize) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw MediaImportError.videoWriterUnavailable
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(
                baseAddress,
                0,
                CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
            )
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
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

        let result = try await MediaConversionHelper.writeBlankVideoClock(
            duration: CMTimeGetSeconds(
                CMTime(value: durationTicks, timescale: 600)
            ),
            frameRate: safeFrameRate
        )
        urls[key] = result
        return result
    }
}
