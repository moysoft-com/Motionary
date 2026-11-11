// Timeline thumbnail tiles, generation, and actor-isolated image caches.

import AVFoundation
import SwiftUI
import UIKit

struct TimelineThumbnailTile: View {
    let clip: TimelineClip
    let media: ClipMediaDescriptor
    let speedMap: SpeedMap
    let tileIndex: Int
    let tileWidth: CGFloat
    let height: CGFloat
    let secondsPerTile: Double
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
            if let loaded = await loadImage() {
                guard !Task.isCancelled else { return }
                image = loaded
                return
            }

            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            if let loaded = await loadImage() {
                guard !Task.isCancelled else { return }
                image = loaded
            }
        }
    }

    private func loadImage() async -> UIImage? {
        await TimelineThumbnailLoader.tileImage(
            for: clip,
            media: media,
            speedMap: speedMap,
            tileIndex: tileIndex,
            tileWidth: tileWidth,
            tileHeight: height,
            secondsPerTile: secondsPerTile,
            displayScale: displayScale
        )
    }

    private var taskID: String {
        [
            clip.id.uuidString,
            "\(tileIndex)",
            "\(Int(tileWidth.rounded()))",
            "\(Int(height.rounded()))",
            "\(Int((displayScale * 100).rounded()))",
            String(format: "%.6f", secondsPerTile),
            media.mediaID.rawValue.uuidString,
            clip.mediaType.rawValue,
            "\(speedMap.topologySignature)",
            String(format: "%.3f", clip.sourceRange.start),
            String(format: "%.3f", clip.sourceRange.duration)
        ].joined(separator: "|")
    }
}

/// Exclusive checkout pool for thumbnail image generators. Many timeline tiles
/// share one source asset; reusing its already-loaded asset/generator across
/// tiles avoids recreating `AVURLAsset` + `AVAssetImageGenerator` per tile.
/// A generator is checked out to exactly one task, so concurrent tiles never
/// mutate the same generator; the pool is keyed by any content identity the URL
/// already carries and does not extend the tile cache's own freshness.
private final class TimelineThumbnailGeneratorPool: @unchecked Sendable {
    static let shared = TimelineThumbnailGeneratorPool()

    private let lock = NSLock()
    private final class Bucket {
        var generators: [AVAssetImageGenerator] = []
    }

    private let available: NSCache<NSURL, Bucket> = {
        let cache = NSCache<NSURL, Bucket>()
        cache.countLimit = 16
        return cache
    }()
    private let maximumPerURL = 2

    func checkout(url: URL) -> AVAssetImageGenerator {
        lock.lock()
        let generator = available.object(forKey: url as NSURL)?.generators.popLast()
        lock.unlock()
        return generator ?? AVAssetImageGenerator(asset: AVURLAsset(url: url))
    }

    func checkin(_ generator: AVAssetImageGenerator, url: URL) {
        lock.lock()
        defer { lock.unlock() }
        let key = url as NSURL
        let bucket = available.object(forKey: key) ?? Bucket()
        if bucket.generators.count < maximumPerURL {
            bucket.generators.append(generator)
            available.setObject(bucket, forKey: key)
        }
    }

}

private actor TimelineThumbnailGenerationLimiter {
    static let shared = TimelineThumbnailGenerationLimiter(limit: 2)

    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = max(limit, 1)
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

actor TimelineThumbnailTileCache {
    static let shared = TimelineThumbnailTileCache()
    private let tileCache = NSCache<NSString, UIImage>()
    private struct TileLoad {
        let id: UUID
        let task: Task<UIImage?, Never>
        var waiters: Set<UUID>
    }

    private var inFlight: [String: TileLoad] = [:]
    private let diskRoot: URL = {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("timeline-thumbnails", isDirectory: true)
    }()

    init() {
        tileCache.countLimit = 240
        tileCache.totalCostLimit = 96 * 1_024 * 1_024
        try? FileManager.default.createDirectory(at: diskRoot, withIntermediateDirectories: true)
    }

    func tileImage(
        for clip: TimelineClip,
        media: ClipMediaDescriptor,
        speedMap: SpeedMap,
        tileIndex: Int,
        tileWidth: CGFloat,
        tileHeight: CGFloat,
        secondsPerTile: Double,
        displayScale: CGFloat
    ) async -> UIImage? {
        let localTimelineTime =
            clip.mediaType == .image
            ? 0
            : min(
                max(Double(tileIndex) * secondsPerTile + secondsPerTile * 0.5, 0),
                max(speedMap.timelineDuration(sourceDuration: clip.sourceRange.duration) - 0.001, 0))
        let localSourceTime = speedMap.sourceTime(
            at: localTimelineTime,
            sourceDuration: clip.sourceRange.duration
        )
        let sourceTime = clip.sourceRange.start + localSourceTime
        let key = cacheKey(
            media: media,
            sourceTime: sourceTime,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            displayScale: displayScale
        )

        if let cached = tileCache.object(forKey: key as NSString) {
            return cached
        }
        guard !Task.isCancelled else { return nil }
        let waiter = UUID()
        let task: Task<UIImage?, Never>
        if var load = inFlight[key] {
            load.waiters.insert(waiter)
            inFlight[key] = load
            task = load.task
        } else {
            let id = UUID()
            let url = diskURL(forKey: key)
            task = Task(priority: .utility) {
                let image = await Self.loadTile(
                    at: url, clip: clip, media: media, sourceTime: sourceTime,
                    targetSize: CGSize(width: tileWidth, height: tileHeight), displayScale: displayScale
                )
                guard inFlight[key]?.id == id else { return nil }
                inFlight[key] = nil
                if let image {
                    tileCache.setObject(image, forKey: key as NSString, cost: imageCost(image))
                }
                return image
            }
            inFlight[key] = TileLoad(id: id, task: task, waiters: [waiter])
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.cancelWaiter(waiter, forKey: key) }
        }
    }

    private func cancelWaiter(_ waiter: UUID, forKey key: String) {
        guard var load = inFlight[key], load.waiters.remove(waiter) != nil else { return }
        if load.waiters.isEmpty {
            load.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = load
        }
    }

    private nonisolated static func loadTile(
        at url: URL, clip: TimelineClip, media: ClipMediaDescriptor,
        sourceTime: Double, targetSize: CGSize, displayScale: CGFloat
    ) async -> UIImage? {
        await TimelineThumbnailGenerationLimiter.shared.acquire()
        let image: UIImage?
        if Task.isCancelled {
            image = nil
        } else if let data = try? Data(contentsOf: url),
            let cached = UIImage(data: data, scale: max(displayScale, 1))
        {
            image = cached
        } else {
            image = await TimelineThumbnailLoader.generateImage(
                for: clip, media: media, sourceTime: sourceTime,
                targetSize: targetSize, displayScale: displayScale
            )
            if !Task.isCancelled, let data = image?.pngData() {
                try? data.write(to: url, options: [.atomic])
            }
        }
        await TimelineThumbnailGenerationLimiter.shared.release()
        return image
    }

    func trimForMemoryPressure() {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        tileCache.removeAllObjects()
    }

    private func cacheKey(
        media: ClipMediaDescriptor,
        sourceTime: Double,
        tileWidth: CGFloat,
        tileHeight: CGFloat,
        displayScale: CGFloat
    ) -> String {
        [
            media.mediaID.rawValue.uuidString,
            media.mediaType.rawValue,
            "source-v2",
            String(format: "%.3f", sourceTime),
            "\(Int(tileWidth.rounded()))",
            "\(Int(tileHeight.rounded()))",
            "\(Int((displayScale * 100).rounded()))"
        ].joined(separator: "|")
    }

    private func imageCost(_ image: UIImage) -> Int {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        return max(pixelWidth * pixelHeight * 4, 1)
    }

    private func diskURL(forKey key: String) -> URL {
        let hashed = key.data(using: .utf8)?.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_") ?? key
        return diskRoot.appendingPathComponent("\(hashed).png")
    }


}

enum TimelineThumbnailLoader {
    static func image(
        for clip: TimelineClip,
        media: ClipMediaDescriptor,
        speedMap: SpeedMap,
        timelineTime: Double,
        targetHeight: CGFloat,
        displayScale: CGFloat = 2
    ) async -> UIImage? {
        let localTimelineTime = min(
            max(timelineTime - clip.timelineStart, 0),
            max(speedMap.timelineDuration(sourceDuration: clip.sourceRange.duration) - 0.001, 0)
        )
        let localSourceTime = speedMap.sourceTime(
            at: localTimelineTime,
            sourceDuration: clip.sourceRange.duration
        )
        let sourceTime = clip.sourceRange.start + localSourceTime
        let targetSize = CGSize(
            width: max(targetHeight, 120),
            height: max(targetHeight, 120)
        )
        return await generateImage(
            for: clip,
            media: media,
            sourceTime: sourceTime,
            targetSize: targetSize,
            displayScale: displayScale
        )
    }

    static func tileImage(
        for clip: TimelineClip,
        media: ClipMediaDescriptor,
        speedMap: SpeedMap,
        tileIndex: Int,
        tileWidth: CGFloat,
        tileHeight: CGFloat,
        secondsPerTile: Double,
        displayScale: CGFloat
    ) async -> UIImage? {
        await TimelineThumbnailTileCache.shared.tileImage(
            for: clip,
            media: media,
            speedMap: speedMap,
            tileIndex: tileIndex,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            secondsPerTile: secondsPerTile,
            displayScale: displayScale
        )
    }

    fileprivate static func generateImage(
        for clip: TimelineClip,
        media: ClipMediaDescriptor,
        sourceTime: Double,
        targetSize: CGSize,
        displayScale: CGFloat
    ) async -> UIImage? {
        let url = media.url
        if media.mediaType == .image {
            return await Task<UIImage?, Never>.detached(priority: .utility) {
                guard let image = try? MediaConversionHelper.downsampledImage(
                    at: url,
                    maxPixelSize: max(
                        targetSize.width * displayScale,
                        targetSize.height * displayScale,
                        24
                    )
                ), let cgImage = image.cgImage else { return nil }
                return UIImage(
                    cgImage: cgImage,
                    scale: max(displayScale, 1),
                    orientation: .up
                )
            }.value
        }
        let sourceStart = clip.sourceRange.start
        let sourceEnd = clip.sourceRange.end
        return await Task<UIImage?, Never>.detached(priority: .utility) {
            let generator = TimelineThumbnailGeneratorPool.shared.checkout(url: url)
            defer { TimelineThumbnailGeneratorPool.shared.checkin(generator, url: url) }
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(
                width: max(targetSize.width * displayScale, 24),
                height: max(targetSize.height * displayScale, 24)
            )
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
            // Deduped while preserving order: a tile needs the first (nearest)
            // candidate only; duplicate times would only repeat a failed
            // decode.
            var fallbacks: [Double] = []
            var seen: Set<Int64> = []
            for seconds in [
                sourceTime,
                min(max(sourceTime + 0.04, sourceStart), sourceEnd),
                max(sourceStart, min(sourceEnd, sourceStart + max(clip.sourceRange.duration, 0.001) * 0.5)),
                sourceStart,
                0
            ] {
                guard seconds.isFinite else { continue }
                let key = Int64((max(seconds, 0) * 600).rounded())
                guard seen.insert(key).inserted else { continue }
                fallbacks.append(seconds)
            }
            guard
                let cgImage = await copyImage(
                    using: generator,
                    fallbackSeconds: fallbacks
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
