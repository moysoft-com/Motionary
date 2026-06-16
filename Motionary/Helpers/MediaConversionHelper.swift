import AVFoundation
import UIKit

enum MediaConversionHelper {
    static func imageToVideo(image: UIImage, duration: Double, frameRate: Int32 = 30) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let cgImage = image.cgImage else {
            throw MediaImportError.invalidImage
        }

        let videoSize = CGSize(width: cgImage.width, height: cgImage.height)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = false

        let sourceBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: videoSize.width,
            kCVPixelBufferHeightKey as String: videoSize.height
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourceBufferAttributes
        )

        guard writer.canAdd(writerInput) else {
            throw MediaImportError.videoWriterUnavailable
        }

        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: frameRate)
        let totalFrames = max(Int(duration * Double(frameRate)), 1)

        for frame in 0..<totalFrames {
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            guard let pixelBufferPool = adaptor.pixelBufferPool else {
                throw MediaImportError.videoWriterUnavailable
            }

            var pixelBufferOut: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBufferOut)
            guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
                throw MediaImportError.pixelBufferCreationFailed
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue |
                CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: Int(videoSize.width),
                height: Int(videoSize.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                throw MediaImportError.pixelBufferCreationFailed
            }

            context.clear(CGRect(origin: .zero, size: videoSize))
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(origin: .zero, size: videoSize))
            UIGraphicsPopContext()
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frame))
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        }

        writerInput.markAsFinished()
        await writer.finishWriting()

        if let error = writer.error {
            throw error
        }

        return outputURL
    }
}

func convertImageToVideo(image: UIImage, duration: Double) async -> URL? {
    try? await MediaConversionHelper.imageToVideo(image: image, duration: duration)
}
