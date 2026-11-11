// Real encoded media verifies source mapping through preview, ripple, and export.

import AVFoundation
import CoreImage
import Testing

@testable import Motionary

// The iOS 18 simulator's image generator can fail on custom video
// compositions. Probe the same player output used for interactive preview.
@MainActor
struct PlayerFrameProbe {
    let player: AVPlayer
    private let output: AVPlayerItemVideoOutput

    init(asset: AVAsset, videoComposition: AVVideoComposition?) {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = videoComposition
        item.seekingWaitsForVideoCompositionRendering = true
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
    }

    func image(at time: CMTime) async throws -> CIImage {
        try #require(await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero))
        return try await imageAfterSeek(at: time)
    }

    func imageAfterSeek(at time: CMTime) async throws -> CIImage {
        for _ in 0..<200 {
            var presentedTime = CMTime.invalid
            if let frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &presentedTime),
                presentedTime.isNumeric, abs(presentedTime.seconds - time.seconds) < 1 / 120
            {
                return CIImage(cvPixelBuffer: frame)
            }
            if player.currentItem?.status == .failed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        if let error = player.currentItem?.error { throw error }
        throw NSError(
            domain: "PlayerFrameProbe", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No rendered frame at \(time.seconds) seconds"])
    }
}

@Suite(.serialized)
struct SourceTimingRenderTests {
    @Test func proxyPreservesNativeSourceColor() async throws {
        let url = try await makeVideo(width: 320, height: 192)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("color-proxy-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: directory)
        }
        let metadata = try await MediaAssetCache.shared.metadata(for: url)
        let store = PreviewProxyStore(directory: directory)
        let proxy = try #require(try await store.prepare(source: metadata))
        let time = CMTime(seconds: 1.1, preferredTimescale: 600)
        let expected = try await nativeSourcePixel(url: url, at: time)
        let actual = try await nativeSourcePixel(url: proxy.url, at: time)
        #expect(
            zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) < 8 },
            "Proxy color: \(actual), source \(expected)")
    }

    @MainActor
    @Test func encodedExportPreservesTrimmedSourceColor() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = TimelineClip(
            name: "Export color",
            source: ClipSource(
                url: url, mediaType: .video,
                originalDuration: 4, naturalSize: CGSizeValue(width: 160, height: 96)), timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0.5, duration: 2))
        let project = EditorProject(
            title: "Encoded color", renderSettings: RenderSettings(width: 160, height: 96),
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
        let exported = try await VideoExportService().export(
            project: project, settings: .recommended(for: project),
            progress: { _ in })
        defer { try? FileManager.default.removeItem(at: exported) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for offset in [0.1, 0.7, 1.7] {
            let time = CMTime(seconds: offset, preferredTimescale: 600)
            let expected = try await nativeSourcePixel(
                url: url,
                at: CMTime(seconds: offset + 0.5, preferredTimescale: 600))
            let actual = pixel(try await generator.image(at: time).image)
            #expect(
                zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) < 8 },
                "Encoded color at \(offset): \(actual), source \(expected)")
        }
    }

    @MainActor
    @Test func encodedExportHandlesVideoStartingAfterGap() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = TimelineClip(
            name: "Delayed video",
            source: ClipSource(
                url: url, mediaType: .video,
                originalDuration: 4, naturalSize: CGSizeValue(width: 160, height: 96)),
            timelineStart: 1, sourceRange: TimeRangeValue(start: 0.5, duration: 2))
        let project = EditorProject(
            title: "Video after gap", renderSettings: RenderSettings(width: 160, height: 96),
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
        let exported = try await VideoExportService().export(
            project: project, settings: .recommended(for: project), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: exported) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let gap = pixel(try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image)
        let actual = pixel(try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image)
        let expected = try await nativeSourcePixel(url: url, at: CMTime(seconds: 1, preferredTimescale: 600))
        #expect(gap.prefix(3).allSatisfy { $0 < 10 }, "Gap should show the project background: \(gap)")
        #expect(zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) < 8 },
                "Delayed video: \(actual), source \(expected)")
    }

    @Test func rec709EncodingAndBufferTagsRoundTripColor() throws {
        let colorSpace = try #require(VideoColorSpace.rec709)
        let bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        var buffer: CVPixelBuffer?
        #expect(
            CVPixelBufferCreate(
                nil, 16, 16, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        let image = CIImage(color: CIColor(red: 0.2, green: 0.8, blue: 0.1)).cropped(to: bounds)
        let context = CIContext()
        context.render(image, to: frame, bounds: bounds, colorSpace: colorSpace)
        CVBufferSetAttachment(
            frame, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            frame, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            frame, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        var actual = [UInt8](repeating: 0, count: 4)
        context.render(
            CIImage(cvPixelBuffer: frame), toBitmap: &actual, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let expected = [51, 204, 25, 255]
        #expect(zip(actual, expected).allSatisfy { abs(Int($0) - $1) <= 1 })
    }

    @Test func temporalSamplesMatchDecoderCoordinates() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: 1.1, preferredTimescale: 600),
            duration: CMTime(seconds: 0.1, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        reader.add(output)
        #expect(reader.startReading())
        let sampleBuffer = try #require(output.copyNextSampleBuffer())
        let source = try #require(CMSampleBufferGetImageBuffer(sampleBuffer))
        defer { reader.cancelReading() }
        let resources = try MetalRenderResources.shared().beginFrame()
        defer { resources.abandon() }
        let decoded = try resources.makeSourceImage(from: source)
        let temporal = try EffectTemporalSource(
            url: url, sourceStart: 1.1, sourceDuration: 0.1,
            speedMap: .constant
        ).image(at: 0, fitting: CGRect(x: 0, y: 0, width: 160, height: 96), quality: .export)
        let context = CIContext()
        for point in [CGPoint(x: 5, y: 90), CGPoint(x: 155, y: 5)] {
            func sample(_ image: CIImage) -> [UInt8] {
                var result = [UInt8](repeating: 0, count: 4)
                context.render(
                    image, toBitmap: &result, rowBytes: 4,
                    bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)), format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                return result
            }
            let a = sample(decoded), b = sample(temporal)
            #expect(zip(a, b).allSatisfy { abs(Int($0) - Int($1)) < 8 })
        }
    }

    @Test func decoderColorConversionMatchesCoreImage() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: 1.1, preferredTimescale: 600),
            duration: CMTime(seconds: 0.1, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
            ])
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        let source = try #require(CMSampleBufferGetImageBuffer(sample))
        defer { reader.cancelReading() }
        let context = CIContext()
        let native = pixel(
            try #require(
                context.createCGImage(CIImage(cvPixelBuffer: source), from: CGRect(x: 0, y: 0, width: 160, height: 96)))
        )
        let descriptor = RenderClipDescriptor(
            trackID: 42, backgroundMaskTrackID: nil, clipID: UUID(), timelineStart: 0,
            duration: 1, sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(), effectStack: EffectStack(), mask: nil, backgroundRemoval: nil,
            blendMode: .normal, blendIntensity: 1, shape: nil, text: nil, renderOrder: 0)
        var buffer: CVPixelBuffer?
        #expect(
            CVPixelBufferCreate(
                nil, 160, 96, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &buffer) == kCVReturnSuccess)
        let destination = try #require(buffer)
        try MetalFrameRenderer().render(
            plan: FrameRenderPlan(
                renderSize: CGSize(width: 160, height: 96), renderScale: 1,
                backgroundColor: .black, frameDuration: 1 / 30, clips: [descriptor], quality: .export,
                failurePolicy: .failOnUnavailableEffects), compositionTime: .zero,
            sourceFrame: { $0 == 42 ? source : nil }, destination: destination, isCancelled: { false })
        let actual = pixel(
            try #require(
                context.createCGImage(
                    CIImage(cvPixelBuffer: destination), from: CGRect(x: 0, y: 0, width: 160, height: 96))))
        print(
            "RELIABILITY source_attachments=\(String(describing: CVBufferCopyAttachments(source, .shouldPropagate))) native=\(native) engine=\(actual)"
        )
        #expect(zip(actual, native).allSatisfy { abs(Int($0) - Int($1)) < 4 })
    }

    @MainActor
    @Test func splitRipplePreviewAndExportMatchTheRetainedSourceFrames() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        for speed in [0.5, 1.0, 2.0] {
            let clip = TimelineClip(
                name: "Time coded video",
                source: ClipSource(
                    url: url, mediaType: .video,
                    originalDuration: 4, naturalSize: CGSizeValue(width: 160, height: 96)), timelineStart: 120,
                sourceRange: TimeRangeValue(start: 0.5, duration: 3))
            var project = EditorProject(
                title: "Encoded ripple", renderSettings: RenderSettings(width: 160, height: 96),
                tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
            guard case .media(var item) = project.tracks[0].items[0] else { return }
            item.speedMap = .constant(speed: speed)
            project.tracks[0].items[0] = .media(item)
            let model = EditorViewModel(
                projectID: UUID(), projectStore: ProjectStore(),
                initialContent: ProjectContent(editorProject: project))
            defer { model.stop() }
            model.selectTimelineItem(clip.id, trackID: project.tracks[0].id)
            model.seek(to: 121)
            let retainedID = try #require(model.splitSelectedTimelineItem())
            model.isRippleEditingEnabled = true
            model.selectTimelineItem(clip.id, trackID: project.tracks[0].id)
            model.deleteSelectedClip()
            model.rebuildTask?.cancel()
            model.rebuildTask = nil
            let retained = try #require(model.project.item(id: retainedID))
            let expectedStart = 0.5 + speed
            #expect(retained.sourceRange.start == expectedStart)
            let service = CompositionRenderService(previewProxyStore: nil)
            let preview = try #require(
                try await service.preparePreview(
                    for: model.project, quality: .balanced,
                    invalidation: [.previewFrame, .compositionTopology]))
            let exported = try await service.makeComposition(for: model.project)
            for (composition, videoComposition) in [
                (preview.composition, preview.videoComposition),
                (exported.composition, exported.videoComposition)
            ] {
                let probe = PlayerFrameProbe(asset: composition, videoComposition: videoComposition)
                let context = CIContext()
                for offset in [0.0, 0.1, 0.3] {
                    let time = CMTime(seconds: retained.timelineStart + offset, preferredTimescale: 600)
                    let expectedTime = CMTime(seconds: expectedStart + offset * speed, preferredTimescale: 600)
                    // Compare native YUV through Core Image. An intermediate
                    // 8-bit RGB decode clips excursions before color matching.
                    let b = try await nativeSourcePixel(url: url, at: expectedTime)
                    let actual = try await probe.image(at: time)
                    let a = pixel(try #require(context.createCGImage(actual, from: actual.extent)))
                    #expect(
                        zip(a, b).allSatisfy { abs(Int($0) - Int($1)) < 8 },
                        "Source frame mismatch \(composition === preview.composition ? "preview" : "export") at speed \(speed), timeline offset \(offset): actual \(a), source \(b)"
                    )
                }
            }
        }
    }

    @MainActor
    @Test func previewRendersTheAuthoredFrameAtZero() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = TimelineClip(
            name: "First frame",
            source: ClipSource(
                url: url, mediaType: .video,
                originalDuration: 4, naturalSize: CGSizeValue(width: 160, height: 96)), timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4))
        let project = EditorProject(
            title: "Exact first frame", renderSettings: RenderSettings(width: 160, height: 96),
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
        let service = CompositionRenderService(previewProxyStore: nil)
        let preview = try #require(
            try await service.preparePreview(
                for: project, quality: .balanced,
                invalidation: [.previewFrame, .compositionTopology]))
        let probe = PlayerFrameProbe(asset: preview.composition, videoComposition: preview.videoComposition)
        let model = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project))
        defer { model.stop() }
        model.player = probe.player
        let result = await model.boundedSeek(
            player: probe.player, to: 0, toleranceBefore: .zero,
            toleranceAfter: .zero, timeoutNanoseconds: 5_000_000_000)
        #expect(result == .completed)
        let context = CIContext()
        let first = try await probe.imageAfterSeek(at: .zero)
        let second = try await probe.image(at: CMTime(value: 1, timescale: 30))
        let zero = pixel(try #require(context.createCGImage(first, from: first.extent)))
        let one = pixel(try #require(context.createCGImage(second, from: second.extent)))
        #expect(zero[0] > 240 && zero[1] > 240 && zero[2] > 240)
        #expect(one[0] > 200 && one[1] < 30 && one[2] < 30)
    }

    private func pixel(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            CIImage(cgImage: image), toBitmap: &bytes, rowBytes: 4,
            bounds: CGRect(x: 80, y: 48, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    private func nativeSourcePixel(url: URL, at time: CMTime) async throws -> [UInt8] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: time, duration: CMTime(value: 1, timescale: 30))
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
        reader.add(output)
        #expect(reader.startReading())
        defer { reader.cancelReading() }
        let sampleBuffer = try #require(output.copyNextSampleBuffer())
        let source = try #require(CMSampleBufferGetImageBuffer(sampleBuffer))
        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            CIImage(cvPixelBuffer: source), toBitmap: &bytes, rowBytes: 4,
            bounds: CGRect(x: 80, y: 48, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    private func makeVideo(width: Int = 160, height: Int = 96) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timing-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 60]
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let colors: [CIColor] = [.red, .green, .blue, CIColor(red: 1, green: 1, blue: 0)]
        let context = CIContext()
        for index in 0..<120 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            let pool = try #require(adaptor.pixelBufferPool)
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess)
            let frame = try #require(buffer)
            let color = index == 0 ? CIColor.white : colors[index / 30]
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 12))
                .composited(
                    over: CIImage(color: .black).cropped(
                        to: CGRect(x: width - 20, y: height - 12, width: 20, height: 12))
                )
                .composited(over: CIImage(color: color).cropped(to: bounds))
            context.render(image, to: frame)
            #expect(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }
}
