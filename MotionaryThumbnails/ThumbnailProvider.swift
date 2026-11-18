import AVFoundation
import ImageIO
import QuickLookThumbnailing
import UIKit

final class ThumbnailProvider: QLThumbnailProvider {
    private struct Header: Decodable {
        let movieExtension: String
        let movieBytes: UInt64
        let posterJPEG: Data?
    }

    override func provideThumbnail(
        for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
    ) {
        Task {
            do {
                handler(try await videoReply(for: request), nil)
            } catch {
                handler(nil, error)
            }
        }
    }

    private func videoReply(for request: QLFileThumbnailRequest) async throws -> QLThumbnailReply {
        let frame = try await poster(for: request)
        let frameSize = CGSize(width: frame.width, height: frame.height)
        let maximum = request.maximumSize
        let fit = AVMakeRect(aspectRatio: frameSize, insideRect: CGRect(origin: .zero, size: maximum))
        let size = CGSize(
            width: max(fit.width, min(maximum.width, request.minimumSize.width)),
            height: max(fit.height, min(maximum.height, request.minimumSize.height))
        )
        let bounds = CGRect(origin: .zero, size: size)
        let videoRect = AVMakeRect(aspectRatio: frameSize, insideRect: bounds)
        let badge = UIImage(named: "MotionaryFileBadge", in: Bundle(for: ThumbnailProvider.self), compatibleWith: nil)
        let shortSide = min(videoRect.width, videoRect.height)
        let margin = shortSide * 0.075

        return QLThumbnailReply(contextSize: size, currentContextDrawing: {
            UIColor.black.setFill()
            UIRectFill(bounds)
            UIImage(cgImage: frame).draw(in: videoRect)

            if let badge {
                let width = shortSide * 0.22
                let height = width * badge.size.height / badge.size.width
                badge.draw(in: CGRect(
                    x: videoRect.minX + margin, y: videoRect.maxY - margin - height,
                    width: width, height: height
                ))
            }
            return true
        })
    }

    private func poster(for request: QLFileThumbnailRequest) async throws -> CGImage {
        let url = request.fileURL
        let accessible = url.startAccessingSecurityScopedResource()
        defer { if accessible { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try MotionaryVideoContainer.readHeader(Header.self, from: file)
        try MotionaryVideoContainer.validateMovie(in: file, extension: header.movieExtension, bytes: header.movieBytes)
        let pixelSize = max(1, min(512, ceil(max(request.maximumSize.width, request.maximumSize.height) * request.scale)))
        if let data = header.posterJPEG,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(pixelSize),
            ] as CFDictionary)
        {
            return image
        }

        let movie = try MotionaryVideoContainer.extractMovie(
            from: file, extension: header.movieExtension, bytes: header.movieBytes
        )
        defer { try? FileManager.default.removeItem(at: movie.deletingLastPathComponent()) }
        return try await MotionaryVideoContainer.posterFrame(from: AVURLAsset(url: movie), maximumPixelSize: pixelSize)
    }
}
