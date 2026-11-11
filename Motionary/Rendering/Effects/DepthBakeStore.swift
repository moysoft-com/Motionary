import AVFoundation
import CoreImage
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Depth analysis is addressed by source time and written atomically. The
/// stabilized track is evaluated lazily, so a seek never analyzes an entire clip.
final class DepthBakeStore: @unchecked Sendable {
    static let shared = DepthBakeStore()
    static let width = 518
    static let height = 392
    static let rate = 24.0
    static let preparationProgress = Notification.Name("MotionaryDepthPreparationProgress")
    private let inferenceLock = NSLock()
    private let directoryLock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let images = NSCache<NSString, CGImage>()
    private let rawSamples = NSCache<NSString, NSData>()
    private let root: URL

    struct Analysis: Sendable {
        let directory: URL
        let track: VideoTrack?
        let stillFile: URL?
    }

    struct VideoTrack: Sendable {
        let source: EffectTemporalSource
        let sampleRanges: [CMTimeRange]
        let duration: Double
        let rawDirectory: URL
        let directory: URL
        let strength: Float
    }

    private init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DepthMaps-v7", isDirectory: true)
        images.totalCostLimit = 32 * 1024 * 1024
        images.countLimit = 160
        rawSamples.totalCostLimit = 8 * 1024 * 1024
    }

    static func projectDirectory(in projectFolder: URL) -> URL {
        projectFolder.appendingPathComponent("DepthMaps-v7", isDirectory: true)
    }

    static func prepare(_ clips: [RenderClipDescriptor], projectDirectory: URL?) async throws -> [RenderClipDescriptor] {
        var prepared = clips
        var rangesByURL: [URL: [CMTimeRange]] = [:]
        var identityByURL: [URL: String] = [:]
        for index in clips.indices {
            let clip = clips[index]
            for effect in clip.effectStack.effects where effect.moduleID == .depthMap && effect.isEnabled {
                try Task.checkCancellation()
                let directory = (projectDirectory ?? shared.root).appendingPathComponent(effect.id.uuidString, isDirectory: true)
                let track: VideoTrack?
                if let source = clip.temporalSource {
                    let ranges: [CMTimeRange]
                    if let cached = rangesByURL[source.url] {
                        ranges = cached
                    } else {
                        ranges = try await sampleRanges(for: source.url)
                        rangesByURL[source.url] = ranges
                    }
                    let identity = identityByURL[source.url] ?? sourceIdentity(source.url, projectDirectory: projectDirectory)
                    identityByURL[source.url] = identity
                    track = try shared.makeTrack(source: source, effect: effect, directory: directory,
                                                 sampleRanges: ranges, sourceIdentity: identity)
                } else {
                    track = nil
                    try shared.createDirectory(directory)
                }
                let stillFile: URL?
                if let url = clip.stillImageURL {
                    let identity = identityByURL[url] ?? sourceIdentity(url, projectDirectory: projectDirectory)
                    identityByURL[url] = identity
                    stillFile = directory.appendingPathComponent("source-\(hash(Data(identity.utf8))).png")
                } else {
                    stillFile = nil
                }
                prepared[index].depthAnalyses[effect.id] = Analysis(
                    directory: directory, track: track, stillFile: stillFile
                )
            }
        }
        return prepared
    }

    private static func sampleRanges(for url: URL) async throws -> [CMTimeRange] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MetalRenderingError.sourceFrameUnavailable
        }
        let (trackRange, segments) = try await track.load(.timeRange, .segments)
        let editedRanges = segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
        let ranges = (editedRanges.isEmpty ? [trackRange] : editedRanges)
            .filter { $0.start.isNumeric && $0.end.isNumeric && $0.duration > .zero }
        guard !ranges.isEmpty else { throw MetalRenderingError.sourceFrameUnavailable }
        return ranges
    }

    private static func sourceIdentity(_ url: URL, projectDirectory: URL?) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let location = url.deletingLastPathComponent() == projectDirectory?.deletingLastPathComponent()
            ? url.lastPathComponent : url.absoluteString
        return "\(location)|\(modified)|\(size)"
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func stability(of effect: EffectInstance) -> String {
        if case .option(let value)? = EffectRegistry.shared.resolvedValue(for: "depthStability", in: effect, at: 0) { return value }
        return "Medium"
    }

    private func makeTrack(source: EffectTemporalSource, effect: EffectInstance, directory: URL,
                           sampleRanges: [CMTimeRange], sourceIdentity: String) throws -> VideoTrack {
        let duration = source.speedMap.timelineDuration(sourceDuration: source.sourceDuration)
        guard duration.isFinite, duration > 0, duration < Double(Int.max / 2) / Self.rate else {
            throw MetalRenderingError.sourceFrameUnavailable
        }
        let transform = source.sourceOrientation
        let xLength = max(hypot(transform.a, transform.b), 0.000001)
        let yLength = max(hypot(transform.c, transform.d), 0.000001)
        let orientation = [transform.a / xLength, transform.b / xLength, transform.c / yLength, transform.d / yLength]
            .map { String(format: "%.5f", Double($0)) }.joined(separator: ",")
        let rawKey = Self.hash(Data("\(sourceIdentity)|\(orientation)".utf8))
        let rawDirectory = directory.appendingPathComponent(rawKey, isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let speed = try encoder.encode(source.speedMap).base64EncodedString()
        let stability = Self.stability(of: effect)
        let trackKey = Self.hash(Data("\(source.sourceStart)|\(source.sourceDuration)|\(speed)|\(stability)".utf8))
        let trackDirectory = rawDirectory.appendingPathComponent(trackKey, isDirectory: true)
        try createDirectory(trackDirectory)
        var rawSource = source
        rawSource.adjustments = AdjustmentSettings()
        rawSource.depthSourceRevision = sourceIdentity
        return VideoTrack(source: rawSource, sampleRanges: sampleRanges, duration: duration,
                          rawDirectory: rawDirectory, directory: trackDirectory,
                          strength: stability == "High" ? 0.85 : stability == "Off" ? 0 : 0.6)
    }

    private func createDirectory(_ url: URL) throws {
        try directoryLock.withLock {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// A removed effect loses all analysis variants. Disable, mute and undo
    /// history do not require rescanning or evicting unrelated effects.
    static func removeUnusedAnalyses(in projectFolder: URL, retaining effectIDs: Set<UUID>) {
        let directory = projectDirectory(in: projectFolder)
        let manager = FileManager.default
        let retired = shared.directoryLock.withLock {
            let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return entries.compactMap { entry -> URL? in
                let id = UUID(uuidString: entry.lastPathComponent)
                if let id, effectIDs.contains(id) { return nil }
                let retired = directory.appendingPathComponent("retired-\(UUID())")
                guard (try? manager.moveItem(at: entry, to: retired)) != nil else { return nil }
                return retired
            }
        }
        if !retired.isEmpty {
            shared.images.removeAllObjects()
            shared.rawSamples.removeAllObjects()
        }
        for entry in retired { try? manager.removeItem(at: entry) }
    }

    // Explicit preparation is also used by clients that require a complete
    // standalone analysis before consuming it.
    static func prepare(source: EffectTemporalSource, effect: EffectInstance) async throws {
        let ranges = try await sampleRanges(for: source.url)
        let track = try shared.makeTrack(source: source, effect: effect,
            directory: shared.root.appendingPathComponent(effect.id.uuidString),
            sampleRanges: ranges, sourceIdentity: sourceIdentity(source.url, projectDirectory: nil))
        for index in 0...Int(ceil(track.duration * rate)) {
            try Task.checkCancellation()
            _ = try shared.sample(track, index: index)
        }
    }

    static func prepare(_ clips: [RenderClipDescriptor]) async throws {
        for clip in try await prepare(clips, projectDirectory: nil) {
            for analysis in clip.depthAnalyses.values {
                guard let track = analysis.track else { continue }
                for index in 0...Int(ceil(track.duration * rate)) {
                    try Task.checkCancellation()
                    _ = try shared.sample(track, index: index)
                }
            }
        }
    }

    func image(source: EffectTemporalSource, effect: EffectInstance, time: Double) throws -> CIImage {
        let track = try makeTrack(source: source, effect: effect,
            directory: root.appendingPathComponent(effect.id.uuidString), sampleRanges: [],
            sourceIdentity: Self.sourceIdentity(source.url, projectDirectory: nil))
        return try image(track: track, time: time, allowInference: false)
    }

    private func sample(_ track: VideoTrack, index: Int, allowInference: Bool = true) throws -> CIImage {
        let file = track.directory.appendingPathComponent("\(index).png")
        if let existing = try? load(file) { return existing }
        guard allowInference else { throw MetalRenderingError.sourceFrameUnavailable }
        return try inferenceLock.withLock {
            if let existing = try? load(file) { return existing }
            func raw(_ index: Int) throws -> [UInt8] {
                let time = min(Double(index) / Self.rate, max(0, track.duration - 0.0001))
                let sourceTime = track.source.sourceStart
                    + track.source.speedMap.sourceTime(at: time, sourceDuration: track.source.sourceDuration)
                let ticks = CMTime(seconds: max(sourceTime, 0), preferredTimescale: 60_000).value
                let file = track.rawDirectory.appendingPathComponent("\(ticks).lzfse")
                let key = file.path as NSString
                if let cached = rawSamples.object(forKey: key) { return Array(cached as Data) }
                if let compressed = try? NSData(contentsOf: file, options: []),
                    let bytes = try? compressed.decompressed(using: .lzfse) as Data,
                    bytes.count == Self.width * Self.height
                {
                    rawSamples.setObject(bytes as NSData, forKey: key, cost: bytes.count)
                    return Array(bytes)
                }
                let pixels = try autoreleasepool {
                    let input = try track.source.image(at: time,
                        fitting: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                        quality: .export, videoSampleRanges: track.sampleRanges)
                    return try infer(input)
                }
                let bytes = Data(pixels) as NSData
                let compressed = try bytes.compressed(using: .lzfse) as Data
                do {
                    try compressed.write(to: file, options: .atomic)
                    rawSamples.setObject(bytes, forKey: key, cost: bytes.length)
                } catch where !FileManager.default.fileExists(atPath: track.rawDirectory.path) {
                    // An export can still reference a snapshot whose effect
                    // was removed from the project during the export.
                }
                return pixels
            }
            let current = try raw(index)
            let last = Int(ceil(track.duration * Self.rate))
            let pixels: [UInt8]
            if track.strength > 0, index > 0, index < last {
                pixels = Self.stabilized(current, previous: try raw(index - 1),
                                         next: try raw(index + 1), strength: track.strength)
            } else {
                pixels = current
            }
            return try store(pixels, at: file)
        }
    }

    /// Symmetric local filtering has no playback-order dependency or trailing
    /// history. Large changes are rejected to protect moving edges and cuts.
    static func stabilized(_ current: [UInt8], previous: [UInt8]?, next: [UInt8]?, strength: Float) -> [UInt8] {
        guard strength > 0, let previous, let next,
              previous.count == current.count, next.count == current.count else { return current }
        let difference = zip(previous, next).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(max(1, current.count))
        guard difference < 35 else { return current }
        return current.indices.map { index in
            let center = Float(current[index]), before = Float(previous[index]), after = Float(next[index])
            guard abs(before - center) < 28, abs(after - center) < 28 else { return current[index] }
            let median = max(min(before, center), min(max(before, center), after))
            return UInt8(clamping: Int((center + (median - center) * strength).rounded()))
        }
    }

    private func infer(_ image: CIImage) throws -> [UInt8] {
        var input: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, Self.width, Self.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &input)
        guard status == kCVReturnSuccess, let input else { throw MetalRenderingError.pixelBufferTextureCreationFailed(status) }
        let local = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(Self.width) / image.extent.width, y: CGFloat(Self.height) / image.extent.height))
        context.render(local, to: input, bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let buffer = try DepthModel.shared.predict(input)
        // Core Image on iOS 18 requires four-byte alignment even for L8.
        let rowBytes = (Self.width + 3) / 4 * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * Self.height)
        context.render(CIImage(cvPixelBuffer: buffer), toBitmap: &bytes, rowBytes: rowBytes,
            bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray())
        var pixels = [UInt8]()
        pixels.reserveCapacity(Self.width * Self.height)
        for row in 0..<Self.height {
            let start = row * rowBytes
            pixels.append(contentsOf: bytes[start..<(start + Self.width)])
        }
        return pixels
    }

    private func store(_ bytes: [UInt8], at url: URL) throws -> CIImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: Self.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        do {
            try write(image, to: url)
            return try load(url)
        } catch where !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            // A retired effect can still be rendered by an earlier snapshot.
        }
        return CIImage(cgImage: image)
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let temp = url.appendingPathExtension("\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MetalRenderingError.sourceFrameUnavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MetalRenderingError.sourceFrameUnavailable }
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }

    private func load(_ url: URL) throws -> CIImage {
        if let image = images.object(forKey: url.path as NSString) { return CIImage(cgImage: image) }
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw MetalRenderingError.sourceFrameUnavailable }
        images.setObject(image, forKey: url.path as NSString, cost: image.bytesPerRow * image.height)
        // Core Image's bitmap -> PNG -> image round trip preserves the model's
        // coordinates. A mirror correction here misaligns depth and source.
        return CIImage(cgImage: image)
    }

    func image(track: VideoTrack, time: Double, allowInference: Bool = true) throws -> CIImage {
        guard time.isFinite else { throw MetalRenderingError.sourceFrameUnavailable }
        let position = min(max(time, 0), track.duration) * Self.rate
        let index = Int(floor(position))
        let a = try sample(track, index: index, allowInference: allowInference)
        let last = Int(ceil(track.duration * Self.rate))
        guard index < last, position > Double(index) else { return a }
        let b = try sample(track, index: index + 1, allowInference: allowInference)
        return a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: position - Double(index)])
    }

    func still(_ image: CIImage, effectID: UUID, directory: URL? = nil, sourceFile: URL? = nil) throws -> CIImage {
        let file: URL
        if let sourceFile {
            file = sourceFile
        } else {
            // Generated and cutout images are addressed by their actual input
            // pixels since text, shape, masks and source alpha can animate.
            let local = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(Self.width) / image.extent.width,
                                                   y: CGFloat(Self.height) / image.extent.height))
            var pixels = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
            context.render(local, toBitmap: &pixels, rowBytes: Self.width * 4,
                bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            let key = Self.hash(Data(pixels))
            file = (directory ?? root).appendingPathComponent("still-\(key).png")
        }
        if let cached = try? load(file) { return cached }
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        if let cached = try? load(file) { return cached }
        let preparationID = UUID()
        NotificationCenter.default.post(name: Self.preparationProgress, object: nil,
            userInfo: ["id": preparationID, "effectID": effectID, "progress": 0.0, "indeterminate": true])
        defer {
            NotificationCenter.default.post(name: Self.preparationProgress, object: nil,
                userInfo: ["id": preparationID])
        }
        if directory == nil { try createDirectory(root) }
        return try store(infer(image), at: file)
    }

}
