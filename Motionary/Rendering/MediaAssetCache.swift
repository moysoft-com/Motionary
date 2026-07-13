@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

struct CachedMediaAsset: @unchecked Sendable {
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack?
    let audioTrack: AVAssetTrack?
    let duration: Double
    let naturalSize: CGSize?
    let preferredTransform: CGAffineTransform
}

private struct MediaAssetCacheKey: Hashable {
    let url: URL
    let fileSize: UInt64
    let modificationDate: Date?
}

actor MediaAssetCache {
    static let shared = MediaAssetCache()

    private var entries: [MediaAssetCacheKey: CachedMediaAsset] = [:]
    private var inFlight: [MediaAssetCacheKey: Task<CachedMediaAsset, Error>] = [:]
    private var recency: [MediaAssetCacheKey] = []
    private let countLimit = 64

    func metadata(for url: URL) async throws -> CachedMediaAsset {
        let key = cacheKey(for: url)
        removeStaleEntries(for: url, keeping: key)
        if let cached = entries[key] {
            markRecent(key)
            return cached
        }
        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task<CachedMediaAsset, Error> {
            let asset = AVURLAsset(url: url)
            async let videoTracks = asset.loadTracks(withMediaType: .video)
            async let audioTracks = asset.loadTracks(withMediaType: .audio)
            async let duration = asset.load(.duration)
            let videoTrack = try await videoTracks.first
            let audioTrack = try await audioTracks.first
            let naturalSize = try await videoTrack?.load(.naturalSize)
            let preferredTransform = try await videoTrack?.load(.preferredTransform) ?? .identity
            return CachedMediaAsset(
                asset: asset,
                videoTrack: videoTrack,
                audioTrack: audioTrack,
                duration: CMTimeGetSeconds(try await duration),
                naturalSize: naturalSize,
                preferredTransform: preferredTransform
            )
        }
        inFlight[key] = task
        do {
            let metadata = try await task.value
            entries[key] = metadata
            markRecent(key)
            evictIfNeeded()
            inFlight[key] = nil
            return metadata
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func removeAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        entries.removeAll()
        recency.removeAll()
    }

    private func cacheKey(for url: URL) -> MediaAssetCacheKey {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return MediaAssetCacheKey(
            url: url,
            fileSize: UInt64(max(values?.fileSize ?? 0, 0)),
            modificationDate: values?.contentModificationDate
        )
    }

    private func removeStaleEntries(for url: URL, keeping key: MediaAssetCacheKey) {
        let staleKeys = entries.keys.filter { $0.url == url && $0 != key }
        for staleKey in staleKeys {
            entries[staleKey] = nil
            recency.removeAll { $0 == staleKey }
        }
    }

    private func markRecent(_ key: MediaAssetCacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictIfNeeded() {
        while entries.count > countLimit, let oldest = recency.first {
            recency.removeFirst()
            entries[oldest] = nil
        }
    }
}
