// Background generation of persisted project poster frames for the dashboard.

@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import UIKit

enum ProjectPosterError: LocalizedError {
    case noVisualContent
    case noVideoFrame
    case imageEncodingFailed
    case readerUnavailable
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVisualContent:
            "The project does not contain visual content."
        case .noVideoFrame:
            "The project poster frame could not be rendered."
        case .imageEncodingFailed:
            "The project poster image could not be encoded."
        case .readerUnavailable:
            "The project poster reader is unavailable."
        case .readerFailed(let message):
            "The project poster reader failed: \(message)"
        }
    }
}

final class ProjectPosterService: @unchecked Sendable {
    static let shared = ProjectPosterService()

    private let renderService: CompositionRenderService
    private let context = CIContext()
    private let maximumDimension: Double

    init(
        renderService: CompositionRenderService = CompositionRenderService(),
        maximumDimension: Double = 640
    ) {
        self.renderService = renderService
        self.maximumDimension = maximumDimension
    }

    func renderPoster(
        for project: EditorProject,
        outputURL: URL
    ) async throws {
        let posterTime = try firstVisibleTime(in: project)
        let renderSettings = posterRenderSettings(for: project.renderSettings)
        let rendered = try await renderService.makePosterComposition(
            for: project,
            renderSettings: renderSettings
        )
        try Task.checkCancellation()
        guard rendered.hasVideo, let videoComposition = rendered.videoComposition else {
            throw ProjectPosterError.noVisualContent
        }
        let data = try renderFramePNG(
            from: rendered,
            videoComposition: videoComposition,
            at: posterTime,
            frameRate: renderSettings.frameRate
        )
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: [.atomic])
    }

    private func renderFramePNG(
        from rendered: RenderedComposition,
        videoComposition: AVVideoComposition,
        at time: Double,
        frameRate: Int32
    ) throws -> Data {
        let videoTracks = rendered.composition.tracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ProjectPosterError.noVisualContent }

        let reader = try AVAssetReader(asset: rendered.composition)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(time, 0), preferredTimescale: 600),
            duration: CMTime(value: 1, timescale: max(frameRate, 1))
        )
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ProjectPosterError.readerUnavailable }
        reader.add(output)
        guard reader.startReading() else {
            throw ProjectPosterError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }
        defer { reader.cancelReading() }
        guard let sampleBuffer = output.copyNextSampleBuffer(),
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            if let error = reader.error {
                throw ProjectPosterError.readerFailed(error.localizedDescription)
            }
            throw ProjectPosterError.noVideoFrame
        }
        return try pngData(from: pixelBuffer)
    }

    private func pngData(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let cgImage = context.createCGImage(image, from: extent),
            let data = UIImage(cgImage: cgImage).pngData()
        else {
            throw ProjectPosterError.imageEncodingFailed
        }
        return data
    }

    private func posterRenderSettings(for settings: RenderSettings) -> RenderSettings {
        let width = Double(max(settings.width, 1))
        let height = Double(max(settings.height, 1))
        let scale = min(1, maximumDimension / max(width, height))

        func evenDimension(_ value: Double) -> Int {
            let rounded = max(Int((value * scale).rounded()), 2)
            return rounded.isMultiple(of: 2) ? rounded : rounded - 1
        }

        return RenderSettings(
            width: evenDimension(width),
            height: evenDimension(height),
            frameRate: max(settings.frameRate, 1),
            backgroundColor: settings.backgroundColor
        )
    }

    private func firstVisibleTime(in project: EditorProject) throws -> Double {
        let candidates = project.tracks
            .filter { !$0.isMuted && ($0.kind == .visual || $0.kind == .shape || $0.kind == .text) }
            .flatMap(\.items)
            .compactMap { item -> Double? in
                switch item {
                case .media(let media) where media.mediaType != .audio && media.timelineDuration > 0:
                    media.timelineStart
                case .shape(let shape) where shape.sourceRange.duration > 0:
                    shape.timelineStart
                case .text(let text) where text.duration > 0:
                    text.timelineStart
                case .media, .shape, .text, .caption, .adjustment, .compound:
                    nil
                }
            }
        guard let first = candidates.min() else { throw ProjectPosterError.noVisualContent }
        let frameDuration = 1 / Double(max(project.renderSettings.frameRate, 1))
        return min(first + frameDuration * 0.5, max(project.duration - frameDuration * 0.5, first))
    }
}
