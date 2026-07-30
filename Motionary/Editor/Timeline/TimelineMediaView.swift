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
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
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

private actor TimelineThumbnailGenerationLimiter {
    static let shared = TimelineThumbnailGenerationLimiter(limit: 3)

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
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var activeProjectID: UUID?
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

    func setActiveProject(_ projectID: UUID) {
        if activeProjectID != projectID {
            activeProjectID = projectID
        }
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
            tileIndex: tileIndex,
            sourceTime: sourceTime,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            displayScale: displayScale
        )

        if let cached = tileCache.object(forKey: key as NSString) {
            return cached
        }
        if let diskImage = loadDiskImage(forKey: key) {
            tileCache.setObject(diskImage, forKey: key as NSString, cost: imageCost(diskImage))
            return diskImage
        }

        if let task = inFlight[key] {
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }

        let task = Task<UIImage?, Never> {
            await TimelineThumbnailGenerationLimiter.shared.acquire()
            guard !Task.isCancelled else {
                await TimelineThumbnailGenerationLimiter.shared.release()
                return nil
            }
            let image = await TimelineThumbnailLoader.generateImage(
                for: clip,
                media: media,
                sourceTime: sourceTime,
                targetSize: CGSize(width: tileWidth, height: tileHeight),
                displayScale: displayScale
            )
            await TimelineThumbnailGenerationLimiter.shared.release()
            return image
        }
        inFlight[key] = task
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inFlight[key] = nil
        if let image {
            tileCache.setObject(image, forKey: key as NSString, cost: imageCost(image))
            storeDiskImage(image, forKey: key)
        }
        return image
    }

    func removeAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        tileCache.removeAllObjects()
        activeProjectID = nil
    }

    func trimForMemoryPressure() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        tileCache.removeAllObjects()
    }

    private func cacheKey(
        media: ClipMediaDescriptor,
        tileIndex: Int,
        sourceTime: Double,
        tileWidth: CGFloat,
        tileHeight: CGFloat,
        displayScale: CGFloat
    ) -> String {
        [
            media.mediaID.rawValue.uuidString,
            media.mediaType.rawValue,
            "\(tileIndex)",
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

    private func loadDiskImage(forKey key: String) -> UIImage? {
        let url = diskURL(forKey: key)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        return image
    }

    private func storeDiskImage(_ image: UIImage, forKey key: String) {
        guard let data = image.pngData() else { return }
        try? data.write(to: diskURL(forKey: key), options: [.atomic])
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
