// Timeline thumbnail tiles, generation, and actor-isolated image caches.

import AVFoundation
import SwiftUI
import UIKit

struct TimelineThumbnailTile: View {
    let clip: TimelineClip
    let tileIndex: Int
    let tileWidth: CGFloat
    let height: CGFloat
    let pixelsPerSecond: CGFloat
    let displayScale: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.white.opacity(0.38), Color.white.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .frame(width: tileWidth, height: height)
        .clipped()
        .task(id: taskID) {
            image = nil
            let loaded = await TimelineThumbnailLoader.tileImage(
                for: clip,
                tileIndex: tileIndex,
                tileWidth: tileWidth,
                tileHeight: height,
                pixelsPerSecond: pixelsPerSecond,
                displayScale: displayScale
            )
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    private var taskID: String {
        [
            clip.id.uuidString,
            "\(tileIndex)",
            "\(Int(tileWidth.rounded()))",
            "\(Int(height.rounded()))",
            "\(Int((displayScale * 100).rounded()))",
            clip.source.url.path,
            clip.mediaType.rawValue,
            String(format: "%.3f", clip.sourceRange.start),
            String(format: "%.3f", clip.sourceRange.duration)
        ].joined(separator: "|")
    }
}

actor TimelineThumbnailTileCache {
    static let shared = TimelineThumbnailTileCache()
    private var tileCache: [String: UIImage] = [:]

    func tileImage(
        for clip: TimelineClip,
        tileIndex: Int,
        tileWidth: CGFloat,
        tileHeight: CGFloat,
        pixelsPerSecond: CGFloat,
        displayScale: CGFloat
    ) async -> UIImage? {
        let secondsPerTile = Double(tileWidth / max(pixelsPerSecond, 1))
        let localTime =
            clip.mediaType == .image
            ? 0
            : min(
                max(Double(tileIndex) * secondsPerTile + secondsPerTile * 0.5, 0),
                max(clip.sourceRange.duration - 0.001, 0))
        let sourceTime = clip.sourceRange.start + localTime
        let key = [
            clip.source.url.path,
            clip.mediaType.rawValue,
            "\(tileIndex)",
            String(format: "%.3f", sourceTime),
            "\(Int(tileWidth.rounded()))",
            "\(Int(tileHeight.rounded()))",
            "\(Int((displayScale * 100).rounded()))"
        ].joined(separator: "|")

        if let cached = tileCache[key] {
            return cached
        }

        let image = await TimelineThumbnailLoader.generateImage(
            for: clip,
            sourceTime: sourceTime,
            targetSize: CGSize(width: tileWidth, height: tileHeight),
            displayScale: displayScale
        )
        if let image {
            tileCache[key] = image
        }
        return image
    }
}

enum TimelineThumbnailLoader {
    static func image(for clip: TimelineClip, timelineTime: Double, targetHeight: CGFloat) async -> UIImage? {
        let localTime = min(max(timelineTime - clip.timelineStart, 0), max(clip.sourceRange.duration - 0.01, 0))
        let sourceTime = clip.sourceRange.start + localTime
        return await generateImage(for: clip, sourceTime: sourceTime, targetHeight: targetHeight)
    }

    static func tileImage(
        for clip: TimelineClip,
        tileIndex: Int,
        tileWidth: CGFloat,
        tileHeight: CGFloat,
        pixelsPerSecond: CGFloat,
        displayScale: CGFloat
    ) async -> UIImage? {
        await TimelineThumbnailTileCache.shared.tileImage(
            for: clip,
            tileIndex: tileIndex,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            pixelsPerSecond: pixelsPerSecond,
            displayScale: displayScale
        )
    }

    fileprivate static func generateImage(for clip: TimelineClip, sourceTime: Double, targetHeight: CGFloat) async
        -> UIImage?
    {
        let url = clip.source.url
        let sourceStart = clip.sourceRange.start
        return await Task<UIImage?, Never>.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: max(targetHeight * 2, 120), height: max(targetHeight * 2, 120))
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
            guard
                let cgImage = await copyImage(
                    using: generator,
                    fallbackSeconds: [sourceTime, sourceStart, 0]
                )
            else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }

    fileprivate static func generateImage(
        for clip: TimelineClip, sourceTime: Double, targetSize: CGSize, displayScale: CGFloat
    ) async -> UIImage? {
        let url = clip.source.url
        let sourceStart = clip.sourceRange.start
        let sourceEnd = clip.sourceRange.end
        return await Task<UIImage?, Never>.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(
                width: max(targetSize.width * displayScale, 24),
                height: max(targetSize.height * displayScale, 24)
            )
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
            guard
                let cgImage = await copyImage(
                    using: generator,
                    fallbackSeconds: [
                        sourceTime,
                        min(max(sourceTime + 0.04, sourceStart), sourceEnd),
                        max(sourceStart, min(sourceEnd, sourceStart + max(clip.sourceRange.duration, 0.001) * 0.5)),
                        sourceStart,
                        0
                    ]
                )
            else {
                return nil
            }
            return UIImage(cgImage: cgImage, scale: max(displayScale, 1), orientation: .up)
        }.value
    }

    private static func copyImage(
        using generator: AVAssetImageGenerator,
        fallbackSeconds: [Double]
    ) async -> CGImage? {
        for seconds in fallbackSeconds {
            guard seconds.isFinite else { continue }
            let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                return cgImage
            }
        }

        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.35, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.35, preferredTimescale: 600)
        for seconds in fallbackSeconds {
            guard seconds.isFinite else { continue }
            let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                return cgImage
            }
        }
        return nil
    }
}
