@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import Motionary

@Suite(.serialized)
struct PreviewProxyTests {
    @MainActor
    @Test func coldPreviewUsesOriginalWhileProxyWarms() async throws {
        let sourceURL = try await makeLongGOPVideo()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-cold-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = PreviewProxyStore(directory: directory)
        let metadata = try await MediaAssetCache.shared.metadata(for: sourceURL)
        let clip = TimelineClip(name: "Cold source", source: ClipSource(url: sourceURL, mediaType: .video,
            originalDuration: metadata.duration, naturalSize: CGSizeValue(width: 1920, height: 1080)),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: metadata.duration))
        let project = EditorProject(title: "Cold preview", renderSettings: RenderSettings(width: 960, height: 540),
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
        let service = CompositionRenderService(previewProxyStore: store)
        let start = ProcessInfo.processInfo.systemUptime
        let cold = try #require(try await service.preparePreview(for: project, quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology]))
        let coldMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        #expect(try sourceURLs(cold.composition).contains(sourceURL))
        #expect(!service.previewSupportsExactScrubbing)
        let proxyStart = ProcessInfo.processInfo.systemUptime
        let proxy = try #require(try await store.prepare(source: metadata))
        let remainingProxyMS = (ProcessInfo.processInfo.systemUptime - proxyStart) * 1000
        #expect(try await store.availableProxy(source: metadata)?.url == proxy.url)
        let warm = try #require(try await service.preparePreview(for: project, quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology]))
        #expect(try sourceURLs(warm.composition).contains(proxy.url))
        // Background completion must not mutate an already installed graph.
        #expect(try sourceURLs(cold.composition).contains(sourceURL))
        print("RELIABILITY cold_preview_ms=\(coldMS) remaining_proxy_ms=\(remainingProxyMS)")
    }

    @Test func proxyBitrateImprovesImageFidelityAtSameResolution() async throws {
        let sourceURL = try await makeLongGOPVideo()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-quality-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: directory)
        }
        let metadata = try await MediaAssetCache.shared.metadata(for: sourceURL)
        let oldStore = PreviewProxyStore(directory: directory, bitsPerPixelFrame: 0.45)
        let newStore = PreviewProxyStore(directory: directory, bitsPerPixelFrame: 0.9)
        let old = try #require(try await oldStore.prepare(source: metadata))
        let new = try #require(try await newStore.prepare(source: metadata))
        #expect(old.encodedSize == new.encodedSize)
        #expect(old.url != new.url)
        let context = CIContext()
        func sample(_ url: URL, time: Double) async throws -> [UInt8] {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.maximumSize = CGSize(width: 720, height: 404)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cgImage = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let input = CIImage(cgImage: cgImage)
            let scaled = input.transformed(by: CGAffineTransform(scaleX: 320 / input.extent.width,
                                                                   y: 180 / input.extent.height))
            var pixels = [UInt8](repeating: 0, count: 320 * 180 * 4)
            context.render(scaled, toBitmap: &pixels, rowBytes: 320 * 4,
                           bounds: CGRect(x: 0, y: 0, width: 320, height: 180), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return pixels
        }
        var oldError = 0, newError = 0
        for time in [0.5, 1.0, 2.0] {
            let original = try await sample(sourceURL, time: time)
            let oldPixels = try await sample(old.url, time: time)
            let newPixels = try await sample(new.url, time: time)
            oldError += zip(original, oldPixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            newError += zip(original, newPixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        }
        #expect(newError < oldError, "Higher bitrate should preserve more source detail")
        let oldSize = try #require(try old.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let newSize = try #require(try new.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        print("PROXY QUALITY old_error=\(oldError) new_error=\(newError) old_bytes=\(oldSize) new_bytes=\(newSize)")
    }

    @MainActor
    @Test func longGOPSourceUsesAllIntraProxiesOnlyForPreviewAndMeasuresActualFrames() async throws {
        var stage = "source-fixture"
        do {
            let sourceURL = try await makeLongGOPVideo()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-test-\(UUID())")
            defer {
                try? FileManager.default.removeItem(at: sourceURL)
                try? FileManager.default.removeItem(at: directory)
            }
            let store = PreviewProxyStore(directory: directory)
            let metadata = try await MediaAssetCache.shared.metadata(for: sourceURL)
            let startPreparation = ProcessInfo.processInfo.systemUptime
            stage = "proxy-transcode"
            let proxy = try #require(try await store.prepare(source: metadata))
            let preparationMS = (ProcessInfo.processInfo.systemUptime - startPreparation) * 1000
            let proxyMetadata = try await MediaAssetCache.shared.metadata(for: proxy.url)
            #expect(proxyMetadata.naturalSize == CGSize(width: 960, height: 540))
            #expect(abs(proxyMetadata.duration - metadata.duration) < 1 / 60)
            let originalSync = try await syncFrameCounts(sourceURL)
            let proxySync = try await syncFrameCounts(proxy.url)
            #expect(originalSync.sync < originalSync.total / 4)
            #expect(proxySync.sync == proxySync.total)
            #expect(proxySync.total == originalSync.total)
            #expect(try await store.prepare(source: metadata)?.url == proxy.url)

            let clip = TimelineClip(name: "1080p60 Long GOP", source: ClipSource(
                url: sourceURL, mediaType: .video, originalDuration: metadata.duration,
                naturalSize: CGSizeValue(width: 1920, height: 1080)),
                timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: metadata.duration))
            var project = EditorProject(title: "Real scrub benchmark",
                renderSettings: RenderSettings(width: 960, height: 540, frameRate: 60),
                tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
            if case .media(var item) = project.tracks[0].items[0] {
                item.visuals.mask = ItemMask(shape: .ellipse, widthScale: 0.8, heightScale: 0.8)
                item.visuals.blendMode = .screen
                let noir = try #require(EffectRegistry.shared.makeEffect(moduleID: .noir))
                item.visuals.effectStack = EffectStack(effects: [noir])
                item.visuals.transform.rotationDegrees.baseValue = 10
                project.tracks[0].items[0] = .media(item)
            }
            let originalService = CompositionRenderService(previewProxyStore: nil)
            let proxyService = CompositionRenderService(previewProxyStore: store)
            let invalidation: EditorInvalidation = [.previewFrame, .compositionTopology]
            stage = "prepare-original"
            let original = try #require(try await originalService.preparePreview(
                for: project, quality: .balanced, invalidation: invalidation))
            stage = "prepare-proxy"
            let optimized = try #require(try await proxyService.preparePreview(
                for: project, quality: .balanced, invalidation: invalidation))
            let originalInstruction = try #require(original.videoComposition?.instructions.first as? MotionaryVideoCompositionInstruction)
            let optimizedInstruction = try #require(optimized.videoComposition?.instructions.first as? MotionaryVideoCompositionInstruction)
            #expect(originalInstruction.renderSize == optimizedInstruction.renderSize)
            #expect(proxyService.previewSupportsExactScrubbing)
            #expect(!originalService.previewSupportsExactScrubbing)
            #expect(optimizedInstruction.clips[0].sourceTransform == proxy.sourcePixelTransform.concatenating(originalInstruction.clips[0].sourceTransform))
            #expect(try sourceURLs(optimized.composition).contains(proxy.url))
            stage = "prepare-export"
            let exported = try await proxyService.makeComposition(for: project)
            #expect(try sourceURLs(exported.composition).contains(sourceURL))
            #expect(try !sourceURLs(exported.composition).contains(proxy.url))

            // Same visual semantics at reduced decoder resolution, including
            // orientation, masks, blend mode, source-space effects and placement.
            stage = "original-image"
            let baselinePixels = try await averageQuadrants(original)
            stage = "proxy-image"
            let optimizedPixels = try await averageQuadrants(optimized)
            #expect(zip(baselinePixels, optimizedPixels).allSatisfy { abs(Int($0) - Int($1)) < 10 })
            stage = "scrub-original"
            let originalTimes = try await measureScrubbing(original)
            stage = "scrub-proxy"
            let proxyTimes = try await measureScrubbing(optimized)
            func description(_ values: [Double]) -> String {
                let ordered = values.sorted()
                return "median=\(ordered[ordered.count / 2]) p95=\(ordered[Int(Double(ordered.count - 1) * 0.95)]) max=\(ordered.last!) ms"
            }
            Attachment.record("1080p60 H.264, GOP=120; same 960x540 compositor; seek-to-actual-CVPixelBuffer, 16 forward + 16 reverse samples after warm-up, pixel-buffer timestamp checked.\nProxy preparation: \(preparationMS) ms\nOriginal forward: \(description(originalTimes.forward))\nOriginal reverse: \(description(originalTimes.reverse))\nProxy forward: \(description(proxyTimes.forward))\nProxy reverse: \(description(proxyTimes.reverse))\nOriginal sync frames: \(originalSync.sync)/\(originalSync.total); proxy: \(proxySync.sync)/\(proxySync.total)",
                              named: "real-scrub-original-vs-proxy.txt")
        } catch {
            throw NSError(domain: "PreviewProxy.\(stage)", code: (error as NSError).code,
                userInfo: [NSUnderlyingErrorKey: error])
        }
    }

    @MainActor
    private func averageQuadrants(_ prepared: PreparedPreview, at time: Double = 0.5) async throws -> [UInt8] {
        let probe = PlayerFrameProbe(asset: prepared.composition, videoComposition: prepared.videoComposition)
        let image = try await probe.image(at: CMTime(seconds: time, preferredTimescale: 60_000))
        let context = CIContext()
        var result: [UInt8] = []
        for x in [0.0, image.extent.width / 2] {
            for y in [0.0, image.extent.height / 2] {
                let average = CIFilter.areaAverage()
                average.inputImage = image.cropped(to: CGRect(x: x, y: y, width: image.extent.width / 2, height: image.extent.height / 2))
                var pixel = [UInt8](repeating: 0, count: 4)
                context.render(try #require(average.outputImage), toBitmap: &pixel, rowBytes: 4,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                result.append(contentsOf: pixel)
            }
        }
        return result
    }

    private func sourceURLs(_ composition: AVComposition) throws -> Set<URL> {
        Set(composition.tracks.filter { $0.mediaType == .video }.flatMap(\.segments).compactMap(\.sourceURL))
    }

    @MainActor
    private func measureScrubbing(_ prepared: PreparedPreview) async throws -> (forward: [Double], reverse: [Double]) {
        let item = AVPlayerItem(asset: prepared.composition)
        item.videoComposition = prepared.videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        var forward: [Double] = []
        var reverse: [Double] = []
        for index in 0..<40 {
            let target = index < 20 ? 0.2 + Double(index) / 10 : 3.5 - Double(index - 20) / 10
            let time = CMTime(seconds: target, preferredTimescale: 600)
            let start = ProcessInfo.processInfo.systemUptime
            let finished = await withCheckedContinuation { continuation in
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
                    continuation.resume(returning: $0)
                }
            }
            #expect(finished)
            var frame: CVPixelBuffer?
            for _ in 0..<1000 {
                var presentedTime = CMTime.invalid
                frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &presentedTime)
                if frame != nil, presentedTime.isNumeric,
                    abs(CMTimeGetSeconds(presentedTime) - target) <= 1 / 120 + 0.000_01 { break }
                frame = nil
                if item.status == .failed { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            _ = try #require(frame, "Seek completed without producing a preview frame")
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            if index >= 4 && index < 20 { forward.append(elapsed) }
            if index >= 24 { reverse.append(elapsed) }
        }
        return (forward, reverse)
    }

    private func syncFrameCounts(_ url: URL) async throws -> (sync: Int, total: Int) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var total = 0
        var sync = 0
        while let sample = output.copyNextSampleBuffer() {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            if attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true { sync += 1 }
            total += 1
        }
        #expect(reader.status == .completed)
        return (sync, total)
    }

    private func makeLongGOPVideo() async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("long-gop-\(UUID()).mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 120,
                    AVVideoAllowFrameReorderingKey: true, AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
            ])
            input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
            ])
            writer.add(input)
            guard writer.startWriting() else { throw MediaImportError.videoWriterUnavailable }
            writer.startSession(atSourceTime: .zero)
            let context = CIContext(options: [.cacheIntermediates: false])
            let pattern = CIFilter.checkerboardGenerator()
            pattern.width = 24
            let base = pattern.outputImage!
            let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            for index in 0..<240 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                try autoreleasepool {
                    var buffer: CVPixelBuffer?
                    guard let pool = adaptor.pixelBufferPool,
                        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
                        let buffer else { throw MediaImportError.pixelBufferCreationFailed }
                    let image = base.transformed(by: CGAffineTransform(translationX: CGFloat(index * 3), y: CGFloat(index)))
                    context.render(image.cropped(to: bounds), to: buffer)
                    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 60)) else {
                        throw writer.error ?? MediaImportError.videoWriterUnavailable
                    }
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? MediaImportError.videoWriterUnavailable
            }
            return url
        }.value
    }
}
