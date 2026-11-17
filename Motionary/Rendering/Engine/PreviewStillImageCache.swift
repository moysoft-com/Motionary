import CoreImage
import Foundation
import ImageIO
import UIKit

/// Decoded, oriented source images ready for the preview's first GPU upload.
/// The original extent keeps placement and effect coordinates in source pixels.
final class PreviewStillImageCache: @unchecked Sendable {
    struct Image {
        let pixels: CGImage
        let originalSize: CGSize

        var image: CIImage { CIImage(cgImage: pixels) }
    }

    struct Source: Sendable {
        let url: URL
        let identity: String?

        func key(maximumDimension: Int) -> NSString {
            "\(maximumDimension):\(identity ?? url.standardizedFileURL.path)" as NSString
        }
    }

    private struct Window: Equatable {
        let sessionID: UUID
        let bucket: Int
        let maximumDimension: Int
    }

    private final class Entry {
        let image: Image
        init(_ image: Image) { self.image = image }
    }

    private let images = NSCache<NSString, Entry>()
    private let queue = DispatchQueue(label: "com.moysoft.motionary.preview-stills", qos: .utility)
    private let lock = NSLock()
    private var window: Window?
    private var memoryWarning: NSObjectProtocol?

    init() {
        images.totalCostLimit = 96 * 1024 * 1024
        images.countLimit = 24
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.removeAll() }
    }

    deinit {
        if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) }
    }

    static func maximumDimension(renderSize: CGSize) -> Int {
        // Leave headroom for the usual cover crop while keeping photo layers
        // and their mattes well below the original camera raster.
        min(Int((max(renderSize.width, renderSize.height) * 1.6).rounded(.up)), 2_048)
    }

    func image(for source: Source, maximumDimension: Int) -> Image? {
        let key = source.key(maximumDimension: maximumDimension)
        if let cached = images.object(forKey: key) { return cached.image }
        let hasAccess = source.url.startAccessingSecurityScopedResource()
        defer { if hasAccess { source.url.stopAccessingSecurityScopedResource() } }
        guard maximumDimension > 0,
            let reader = CGImageSourceCreateWithURL(source.url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0,
            let pixels = CGImageSourceCreateThumbnailAtIndex(reader, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maximumDimension, max(width, height)),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        else { return nil }
        let transposed = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        let size = CGSize(width: transposed ? height : width, height: transposed ? width : height)
        let image = Image(pixels: pixels, originalSize: size)
        images.setObject(Entry(image), forKey: key, cost: pixels.bytesPerRow * pixels.height)
        return image
    }

    func prepare(
        clips: [RenderClipDescriptor], at time: Double, maximumDimension: Int, sessionID: UUID
    ) {
        let bucket = Int(max(time, 0) / 4)
        let requestedWindow = Window(sessionID: sessionID, bucket: bucket, maximumDimension: maximumDimension)
        lock.lock()
        guard requestedWindow != window else { lock.unlock(); return }
        window = requestedWindow
        lock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrent(requestedWindow) else { return }
            let start = Double(bucket) * 4
            let nearby = clips.filter {
                $0.stillImageURL != nil && $0.timelineStart <= start + 9 && $0.timelineStart + $0.duration > start - 2
            }.sorted {
                max($0.timelineStart, start) < max($1.timelineStart, start)
            }
            var seen = Set<NSString>()
            for clip in nearby {
                guard let url = clip.stillImageURL else { continue }
                var sources = [Source(url: url, identity: clip.stillImageCacheIdentity)]
                if clip.backgroundRemoval?.requiresForegroundMatte == true, let matte = clip.backgroundMaskImageURL {
                    sources.append(Source(url: matte, identity: nil))
                }
                for source in sources {
                    guard seen.count < 16, self.isCurrent(requestedWindow) else { return }
                    guard seen.insert(source.key(maximumDimension: maximumDimension)).inserted else { continue }
                    _ = autoreleasepool { self.image(for: source, maximumDimension: maximumDimension) }
                }
            }
        }
    }

    func removeAll() {
        lock.lock()
        window = nil
        images.removeAllObjects()
        lock.unlock()
    }

    private func isCurrent(_ requestedWindow: Window) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return window == requestedWindow
    }
}
