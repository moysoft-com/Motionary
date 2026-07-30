// Foreground matte generation using Vision, bidirectional optical flow, and HEVC with alpha.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import VideoToolbox
import Vision

enum BackgroundRemovalError: LocalizedError {
    case noVideoTrack
    case noForeground
    case cannotReadSource
    case cannotCreateMatte

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "This clip does not contain visual media."
        case .noForeground:
            "No clear foreground subject was found in this clip."
        case .cannotReadSource:
            "The source frames could not be read for background removal."
        case .cannotCreateMatte:
            "The background-removal matte could not be created."
        }
    }
}

struct ForegroundMaskFrame {
    let width: Int
    let height: Int
    var values: [Float]
}

protocol ForegroundSegmenting {
    func mask(
        for pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> ForegroundMaskFrame
}

struct VisionForegroundSegmenter: ForegroundSegmenting {
    func mask(
        for pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> ForegroundMaskFrame {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([request])
        guard let observation = request.results?.first,
            !observation.allInstances.isEmpty
        else { throw BackgroundRemovalError.noForeground }

        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )
        return Self.copyMask(maskBuffer, targetWidth: CVPixelBufferGetWidth(pixelBuffer), targetHeight: CVPixelBufferGetHeight(pixelBuffer))
    }

    private static func copyMask(
        _ pixelBuffer: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int
    ) -> ForegroundMaskFrame {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<Float>.stride
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return ForegroundMaskFrame(
                width: targetWidth,
                height: targetHeight,
                values: Array(repeating: 0, count: targetWidth * targetHeight)
            )
        }
        let source = baseAddress.assumingMemoryBound(to: Float.self)
        var values = Array(repeating: Float(0), count: targetWidth * targetHeight)
        for y in 0..<targetHeight {
            let sourceY = min(Int(Double(y) / Double(max(targetHeight, 1)) * Double(sourceHeight)), sourceHeight - 1)
            for x in 0..<targetWidth {
                let sourceX = min(Int(Double(x) / Double(max(targetWidth, 1)) * Double(sourceWidth)), sourceWidth - 1)
                values[y * targetWidth + x] = min(max(source[sourceY * sourceStride + sourceX], 0), 1)
            }
        }
        return ForegroundMaskFrame(width: targetWidth, height: targetHeight, values: values)
    }
}

struct BackgroundRemovalService {
    private let segmenter: any ForegroundSegmenting

    init(segmenter: any ForegroundSegmenting = VisionForegroundSegmenter()) {
        self.segmenter = segmenter
    }

    func generateMatte(
        sourceURL: URL,
        sourceRange: TimeRangeValue,
        destinationURL: URL,
        fingerprint: String? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> BackgroundRemovalArtifact {
        let sourceFingerprint: String
        if let fingerprint {
            sourceFingerprint = fingerprint
        } else {
            sourceFingerprint = try await MediaFingerprint.sha256(for: sourceURL)
        }
        let segmenter = self.segmenter
        let task = Task.detached(priority: .userInitiated) {
            try await Self.process(
                sourceURL: sourceURL,
                sourceRange: sourceRange,
                destinationURL: destinationURL,
                sourceFingerprint: sourceFingerprint,
                segmenter: segmenter,
                progress: progress
            )
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    private struct AnalyzedFrame {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
        let mask: ForegroundMaskFrame
    }

    private static func process(
        sourceURL: URL,
        sourceRange: TimeRangeValue,
        destinationURL: URL,
        sourceFingerprint: String,
        segmenter: any ForegroundSegmenting,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> BackgroundRemovalArtifact {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BackgroundRemovalError.noVideoTrack
        }
        let preferredTransform = try await track.load(.preferredTransform)
        let orientation = imageOrientation(for: preferredTransform)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: sourceRange.start.cmTime,
            duration: max(sourceRange.duration, 1 / 600).cmTime
        )
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw BackgroundRemovalError.cannotReadSource }
        reader.add(output)
        guard reader.startReading() else { throw BackgroundRemovalError.cannotReadSource }

        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-matte.mov")
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: temporaryURL)

        var matteWriter: BackgroundMatteWriter?
        var current: AnalyzedFrame?
        var forwardSupportForCurrent: ForegroundMaskFrame?
        var readFrameIndex = 0
        var foundForeground = false

        func nextFrame() throws -> AnalyzedFrame? {
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                let sourceTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                var timestamp = CMTimeSubtract(sourceTimestamp, sourceRange.start.cmTime)
                if timestamp < .zero || readFrameIndex == 0 { timestamp = .zero }
                readFrameIndex += 1
                let mask: ForegroundMaskFrame
                do {
                    mask = try autoreleasepool {
                        try segmenter.mask(for: pixelBuffer, orientation: orientation)
                    }
                    foundForeground = true
                } catch BackgroundRemovalError.noForeground {
                    let width = CVPixelBufferGetWidth(pixelBuffer)
                    let height = CVPixelBufferGetHeight(pixelBuffer)
                    mask = ForegroundMaskFrame(
                        width: width,
                        height: height,
                        values: Array(repeating: 0, count: width * height)
                    )
                }
                return AnalyzedFrame(
                    pixelBuffer: pixelBuffer,
                    presentationTime: timestamp,
                    mask: mask
                )
            }
            return nil
        }

        do {
            current = try nextFrame()
            guard current != nil else { throw BackgroundRemovalError.cannotReadSource }

            while let activeFrame = current {
                try Task.checkCancellation()
                let next = try nextFrame()
                if matteWriter == nil {
                    matteWriter = try BackgroundMatteWriter(
                        url: temporaryURL,
                        width: activeFrame.mask.width,
                        height: activeFrame.mask.height,
                        transform: preferredTransform
                    )
                }

                let backwardSupport: ForegroundMaskFrame?
                let forwardSupportForNext: ForegroundMaskFrame?
                if let next {
                    forwardSupportForNext = try? autoreleasepool {
                        try opticalFlowWarp(
                            sourceBuffer: activeFrame.pixelBuffer,
                            targetBuffer: next.pixelBuffer,
                            sourceMask: activeFrame.mask
                        )
                    }
                    backwardSupport = try? autoreleasepool {
                        try opticalFlowWarp(
                            sourceBuffer: next.pixelBuffer,
                            targetBuffer: activeFrame.pixelBuffer,
                            sourceMask: next.mask
                        )
                    }
                } else {
                    forwardSupportForNext = nil
                    backwardSupport = nil
                }

                let stabilizedMask = stabilized(
                    activeFrame.mask,
                    previousSupport: forwardSupportForCurrent,
                    nextSupport: backwardSupport
                )
                try await matteWriter?.append(
                    stabilizedMask,
                    at: activeFrame.presentationTime
                )
                if next == nil, readFrameIndex == 1, sourceRange.duration > 1 / 30 {
                    try await matteWriter?.append(
                        stabilizedMask,
                        at: CMTime(
                            seconds: sourceRange.duration - 1 / 30,
                            preferredTimescale: 600
                        )
                    )
                }
                progress(min(max(activeFrame.presentationTime.seconds / max(sourceRange.duration, 0.001), 0), 1) * 0.96)
                current = next
                forwardSupportForCurrent = forwardSupportForNext
            }

            guard reader.status == .completed || reader.status == .reading else {
                throw reader.error ?? BackgroundRemovalError.cannotReadSource
            }
            guard foundForeground else { throw BackgroundRemovalError.noForeground }
            guard let matteWriter else { throw BackgroundRemovalError.cannotCreateMatte }
            try await matteWriter.finish(duration: sourceRange.duration.cmTime)
            try Task.checkCancellation()
            try atomicallyInstall(temporaryURL, at: destinationURL)
            progress(1)
        } catch {
            reader.cancelReading()
            matteWriter?.cancel()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        return BackgroundRemovalArtifact(
            url: destinationURL,
            sourceRange: sourceRange,
            sourceFingerprint: sourceFingerprint
        )
    }

    private static func imageOrientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = Int(transform.a.rounded())
        let b = Int(transform.b.rounded())
        let c = Int(transform.c.rounded())
        let d = Int(transform.d.rounded())
        switch (a, b, c, d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        case (0, 1, 1, 0): return .rightMirrored
        case (0, -1, -1, 0): return .leftMirrored
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        default: return .up
        }
    }

    private static func opticalFlowWarp(
        sourceBuffer: CVPixelBuffer,
        targetBuffer: CVPixelBuffer,
        sourceMask: ForegroundMaskFrame
    ) throws -> ForegroundMaskFrame {
        let request = VNTrackOpticalFlowRequest()
        request.computationAccuracy = .high
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        try VNImageRequestHandler(cvPixelBuffer: sourceBuffer, options: [:]).perform([request])
        try VNImageRequestHandler(cvPixelBuffer: targetBuffer, options: [:]).perform([request])
        guard let flowBuffer = request.results?.first?.pixelBuffer else {
            throw BackgroundRemovalError.cannotCreateMatte
        }

        CVPixelBufferLockBaseAddress(flowBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flowBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(flowBuffer) else {
            throw BackgroundRemovalError.cannotCreateMatte
        }
        let flowWidth = CVPixelBufferGetWidth(flowBuffer)
        let flowHeight = CVPixelBufferGetHeight(flowBuffer)
        let flowStride = CVPixelBufferGetBytesPerRow(flowBuffer) / MemoryLayout<SIMD2<Float>>.stride
        let flow = baseAddress.assumingMemoryBound(to: SIMD2<Float>.self)
        var warped = Array(repeating: Float(0), count: sourceMask.width * sourceMask.height)

        for y in 0..<sourceMask.height {
            let flowY = min(Int(Double(y) / Double(max(sourceMask.height, 1)) * Double(flowHeight)), flowHeight - 1)
            for x in 0..<sourceMask.width {
                let value = sourceMask.values[y * sourceMask.width + x]
                guard value > 0.005 else { continue }
                let flowX = min(Int(Double(x) / Double(max(sourceMask.width, 1)) * Double(flowWidth)), flowWidth - 1)
                let vector = flow[flowY * flowStride + flowX]
                guard vector.x.isFinite, vector.y.isFinite else { continue }
                let scaleX = Double(sourceMask.width) / Double(max(flowWidth, 1))
                let scaleY = Double(sourceMask.height) / Double(max(flowHeight, 1))
                let projectedX = min(
                    max(Double(x) + Double(vector.x) * scaleX, 0),
                    Double(sourceMask.width - 1)
                )
                let projectedY = min(
                    max(Double(y) + Double(vector.y) * scaleY, 0),
                    Double(sourceMask.height - 1)
                )
                let targetX = Int(projectedX.rounded())
                let targetY = Int(projectedY.rounded())
                let index = targetY * sourceMask.width + targetX
                warped[index] = max(warped[index], value)
            }
        }
        return ForegroundMaskFrame(width: sourceMask.width, height: sourceMask.height, values: warped)
    }

    private static func stabilized(
        _ current: ForegroundMaskFrame,
        previousSupport: ForegroundMaskFrame?,
        nextSupport: ForegroundMaskFrame?
    ) -> ForegroundMaskFrame {
        guard previousSupport != nil || nextSupport != nil else { return current }
        var values = current.values
        for index in values.indices {
            var support: Float = 0
            var count: Float = 0
            if let previousSupport, previousSupport.values.indices.contains(index) {
                support += previousSupport.values[index]
                count += 1
            }
            if let nextSupport, nextSupport.values.indices.contains(index) {
                support += nextSupport.values[index]
                count += 1
            }
            guard count > 0 else { continue }
            support /= count
            let temporalWeight: Float = abs(values[index] - support) < 0.45 ? 0.22 : 0.08
            values[index] = values[index] * (1 - temporalWeight) + support * temporalWeight
        }
        return ForegroundMaskFrame(width: current.width, height: current.height, values: values)
    }

    private static func atomicallyInstall(_ temporaryURL: URL, at destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }
}

private final class BackgroundMatteWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    init(url: URL, width: Int, height: Int, transform: CGAffineTransform) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.95,
                    kVTCompressionPropertyKey_AlphaChannelMode as String: kVTAlphaChannelMode_PremultipliedAlpha,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        guard writer.canAdd(input) else { throw BackgroundRemovalError.cannotCreateMatte }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? BackgroundRemovalError.cannotCreateMatte
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ mask: ForegroundMaskFrame, at time: CMTime) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw BackgroundRemovalError.cannotCreateMatte
        }
        var outputBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
            let outputBuffer
        else { throw BackgroundRemovalError.cannotCreateMatte }

        CVPixelBufferLockBaseAddress(outputBuffer, [])
        guard let baseAddress = CVPixelBufferGetBaseAddress(outputBuffer) else {
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])
            throw BackgroundRemovalError.cannotCreateMatte
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        let destination = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<mask.height {
            let row = destination.advanced(by: y * bytesPerRow)
            for x in 0..<mask.width {
                let alpha = UInt8((min(max(mask.values[y * mask.width + x], 0), 1) * 255).rounded())
                let offset = x * 4
                row[offset] = alpha
                row[offset + 1] = alpha
                row[offset + 2] = alpha
                row[offset + 3] = alpha
            }
        }
        CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        CVBufferSetAttachment(
            outputBuffer,
            kCVImageBufferAlphaChannelModeKey,
            kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
            .shouldPropagate
        )
        guard adaptor.append(outputBuffer, withPresentationTime: max(time, .zero)) else {
            throw writer.error ?? BackgroundRemovalError.cannotCreateMatte
        }
    }

    func finish(duration: CMTime) async throws {
        writer.endSession(atSourceTime: max(duration, CMTime(value: 1, timescale: 600)))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? BackgroundRemovalError.cannotCreateMatte
        }
    }

    func cancel() {
        writer.cancelWriting()
    }
}

private extension Double {
    var cmTime: CMTime {
        CMTime(seconds: self.isFinite ? self : 0, preferredTimescale: 600)
    }
}
