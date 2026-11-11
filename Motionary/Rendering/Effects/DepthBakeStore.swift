import AVFoundation
import CoreImage
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Immutable, time-addressed depth tracks. Inference runs during composition
/// preparation, never in video rendering or in response to a scrub request.
final class DepthBakeStore: @unchecked Sendable {
    static let shared = DepthBakeStore()
    static let width = 518
    static let height = 392
    static let rate = 24.0
    static let preparationProgress = Notification.Name("MotionaryDepthPreparationProgress")
    private let bakeLock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let images = NSCache<NSString, CGImage>()
    private let root: URL

    private init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DepthTracks-v6", isDirectory: true)
        images.totalCostLimit = 32 * 1024 * 1024
        images.countLimit = 100
    }

    static func prepare(_ clips: [RenderClipDescriptor]) async throws {
        for clip in clips {
            guard let source = clip.temporalSource else { continue }
            for effect in clip.effectStack.effects where effect.moduleID == .depthMap && effect.isEnabled {
                try Task.checkCancellation()
                try await prepare(source: source, effect: effect)
            }
        }
    }

    static func prepare(source: EffectTemporalSource, effect: EffectInstance) async throws {
        let work = Task.detached(priority: .userInitiated) { try await shared.prepareTrack(source: source, effect: effect) }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func prepareTrack(source: EffectTemporalSource, effect: EffectInstance) async throws {
        let directory = root.appendingPathComponent(try signature(source, effect), isDirectory: true)
        if hasCompletedTrack(at: directory) { return }
        let asset = AVURLAsset(url: source.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MetalRenderingError.sourceFrameUnavailable
        }
        let (trackRange, segments) = try await track.load(.timeRange, .segments)
        let editedRanges = segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
        let sampleRanges = (editedRanges.isEmpty ? [trackRange] : editedRanges)
            .filter { $0.start.isNumeric && $0.end.isNumeric && $0.duration > .zero }
        guard !sampleRanges.isEmpty else { throw MetalRenderingError.sourceFrameUnavailable }
        try bake(source: source, effect: effect, directory: directory,
                 sampleRanges: sampleRanges)
    }

    private func hasCompletedTrack(at directory: URL) -> Bool {
        bakeLock.lock()
        defer { bakeLock.unlock() }
        return reuseCompletedTrack(at: directory)
    }

    /// Called under the bake lock so pruning cannot race with reuse.
    private func reuseCompletedTrack(at directory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("complete").path) else { return false }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
        return true
    }

    private func signature(_ source: EffectTemporalSource, _ effect: EffectInstance) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let speed = try encoder.encode(source.speedMap).base64EncodedString()
        let stability = Self.stability(of: effect)
        let transform = source.sourceOrientation
        let xLength = max(hypot(transform.a, transform.b), 0.000001)
        let yLength = max(hypot(transform.c, transform.d), 0.000001)
        let orientation = [transform.a / xLength, transform.b / xLength, transform.c / yLength, transform.d / yLength]
            .map { String(format: "%.5f", Double($0)) }.joined(separator: ",")
        let identity = "\(source.url.absoluteString)|\(modified)|\(source.sourceStart)|\(source.sourceDuration)|\(speed)|\(orientation)|\(stability)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func stability(of effect: EffectInstance) -> String {
        if case .option(let value)? = EffectRegistry.shared.resolvedValue(for: "depthStability", in: effect, at: 0) { return value }
        return "Medium"
    }

    private func bake(source: EffectTemporalSource, effect: EffectInstance,
                      directory: URL, sampleRanges: [CMTimeRange]) throws {
        bakeLock.lock()
        defer { bakeLock.unlock() }
        try Task.checkCancellation()
        let complete = directory.appendingPathComponent("complete")
        if reuseCompletedTrack(at: directory) { return }
        let preparationID = UUID()
        func report(_ progress: Double?) {
            NotificationCenter.default.post(name: Self.preparationProgress, object: nil,
                userInfo: ["id": preparationID, "effectID": effect.id, "progress": progress as Any])
        }
        report(0)
        defer { report(nil) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            if !FileManager.default.fileExists(atPath: complete.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let duration = source.speedMap.timelineDuration(sourceDuration: source.sourceDuration)
        guard duration.isFinite, duration > 0 else { throw MetalRenderingError.sourceFrameUnavailable }
        let count = Int(ceil(duration * Self.rate)) + 1
        let stability = Self.stability(of: effect)
        let strength: Float = stability == "High" ? 0.85 : stability == "Off" ? 0 : 0.6
        var rawSource = source
        rawSource.adjustments = AdjustmentSettings()
        var previous: [UInt8]?
        var current: [UInt8]?
        func sample(_ index: Int) throws -> [UInt8] {
            try Task.checkCancellation()
            return try autoreleasepool {
                let time = min(Double(index) / Self.rate, max(0, duration - 0.0001))
                let input = try rawSource.image(at: time,
                    fitting: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                    quality: .export, videoSampleRanges: sampleRanges)
                return try infer(input)
            }
        }
        current = try sample(0)
        for index in 0..<count {
            try Task.checkCancellation()
            let next = index + 1 < count ? try sample(index + 1) : nil
            let stabilized = Self.stabilized(current!, previous: previous, next: next, strength: strength)
            try write(stabilized, to: directory.appendingPathComponent("\(index).png"))
            if index % 8 == 0 || index == count - 1 { report(Double(index + 1) / Double(count)) }
            previous = current
            current = next
        }
        try Data().write(to: complete, options: .atomic)
        prune(except: directory)
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

    private func write(_ bytes: [UInt8], to url: URL) throws {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: Self.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let temp = url.appendingPathExtension("tmp")
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

    func image(source: EffectTemporalSource, effect: EffectInstance, time: Double) throws -> CIImage {
        let directory = root.appendingPathComponent(try signature(source, effect))
        let duration = source.speedMap.timelineDuration(sourceDuration: source.sourceDuration)
        let position = min(max(time, 0), duration) * Self.rate
        let index = Int(floor(position))
        let a = try load(directory.appendingPathComponent("\(index).png"))
        let last = Int(ceil(duration * Self.rate))
        guard index < last, position > Double(index) else { return a }
        let b = try load(directory.appendingPathComponent("\(index + 1).png"))
        return a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: position - Double(index)])
    }

    func still(_ image: CIImage, effectID: UUID) throws -> CIImage {
        // A still is content-addressed at model resolution, so output controls
        // and editor rebuilds do not cause another inference.
        let local = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(Self.width) / image.extent.width, y: CGFloat(Self.height) / image.extent.height))
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        context.render(local, toBitmap: &pixels, rowBytes: Self.width * 4,
            bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let key = SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent("still-\(key).png")
        if let cached = try? load(file) { return cached }
        bakeLock.lock()
        defer { bakeLock.unlock() }
        if let cached = try? load(file) { return cached }
        let preparationID = UUID()
        NotificationCenter.default.post(name: Self.preparationProgress, object: nil,
            userInfo: ["id": preparationID, "effectID": effectID, "progress": 0.0, "indeterminate": true])
        defer {
            NotificationCenter.default.post(name: Self.preparationProgress, object: nil,
                userInfo: ["id": preparationID])
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(infer(image), to: file)
        return try load(file)
    }

    private func prune(except current: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let ordered = files.filter { $0 != current }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        // Keep a small number of completed analyses; active instructions may
        // still refer to them, so only remove tracks older than a week.
        for url in ordered.dropFirst(8) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if Date().timeIntervalSince(date) > 7 * 86400 { try? FileManager.default.removeItem(at: url) }
        }
    }
}
