// Real encoded media verifies source mapping through preview, ripple, and export.

import AVFoundation
import Combine
import CoreImage
import Testing
import UIKit

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
    @Test func timelineThumbnailRequestsSurviveMemoryPressure() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = ClipSource(url: url, mediaType: .video, originalDuration: 4)
        let clip = TimelineClip(
            name: "Thumbnail colors", source: source, timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        let media = ClipMediaDescriptor(asset: MediaAsset(id: clip.mediaID, source: source))
        let cache = TimelineThumbnailTileCache()

        @Sendable func loadTile(_ index: Int) async -> UIImage? {
            await cache.tileImage(
                for: clip, media: media, speedMap: .constant(speed: 1),
                tileIndex: index, tileWidth: 160, tileHeight: 96, secondsPerTile: 1, displayScale: 1
            )
        }

        async let first = loadTile(0)
        async let second = loadTile(1)
        async let third = loadTile(2)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(5))
            await cache.trimForMemoryPressure()
        }
        let tiles = await [first, second, third]
        for (index, tile) in tiles.enumerated() {
            let channels = pixel(try #require(tile?.cgImage))
            let dominant = Int(channels[index])
            for (channel, value) in channels.prefix(3).enumerated() where channel != index {
                #expect(dominant - Int(value) > 100, "Unexpected colors for tile \(index): \(channels)")
            }
        }
    }

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
    @Test(arguments: [false, true])
    func easedTimeRemappingUsesTheMappedFramesInPreviewAndExport(reverses: Bool) async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = TimelineClip(
            name: "Remapped video",
            source: ClipSource(
                url: url, mediaType: .video,
                originalDuration: 4, naturalSize: CGSizeValue(width: 160, height: 96)), timelineStart: 0.5,
            sourceRange: TimeRangeValue(start: 0.2, duration: 3.6))
        var project = EditorProject(
            title: "Time Remapping",
            renderSettings: RenderSettings(width: 160, height: 96, frameRate: 30),
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
        var remap = try #require(TimeRemap(sourceDuration: 3.6, timelineDuration: 2))
        remap.setSourceTime(2.6, at: 1, tolerance: 0.001)
        remap.setInterpolation(KeyframeCurvePreset.easeInOut.interpolation, at: 0)
        remap.setInterpolation(KeyframeCurvePreset.easeOut.interpolation, at: 1)
        if reverses {
            remap.setSourceTime(3.6, at: 0, tolerance: 0.001)
            remap.setSourceTime(0.55, at: 1, tolerance: 0.001)
            remap.setSourceTime(0.55, at: 2, tolerance: 0.001)
        }
        var map = SpeedMap.constant
        map.timeRemap = remap
        project.setSpeedMap(for: clip.id, speedMap: map)

        let service = CompositionRenderService(previewProxyStore: nil)
        let preview = try #require(try await service.preparePreview(
            for: project, quality: .balanced, invalidation: [.previewFrame, .compositionTopology]))
        let export = try await VideoExportService().export(
            project: project, settings: .recommended(for: project), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: export) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: export))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let probe = PlayerFrameProbe(asset: preview.composition, videoComposition: preview.videoComposition)
        let context = CIContext()
        for frame in [6, 14, 25, 29, 30, 31, 45, 58, 59] {
            let offset = Double(frame) / 30
            let time = CMTime(value: Int64(frame + 15), timescale: 30)
            let expectedTime = CMTime(
                seconds: clip.sourceRange.start + remap.sourceTime(at: offset), preferredTimescale: 60_000)
            let expected = try await nativeSourcePixel(url: url, at: expectedTime)
            let previewImage = try await probe.image(at: time)
            let previewPixel = pixel(try #require(context.createCGImage(previewImage, from: previewImage.extent)))
            let exportPixel = pixel(try await generator.image(at: time).image)
            #expect(zip(previewPixel, expected).allSatisfy { abs(Int($0) - Int($1)) < 8 },
                    "Preview at \(offset): \(previewPixel), source \(expected)")
            #expect(zip(exportPixel, expected).allSatisfy { abs(Int($0) - Int($1)) < 8 },
                    "Export at \(offset): \(exportPixel), source \(expected)")
        }
    }

    @MainActor
    @Test func audioOutlivesItsTrackOnlyAsSilenceWithoutLosingTheTrack() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("short-track-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let samples = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        samples.frameLength = samples.frameCapacity
        let channel = try #require(samples.floatChannelData?[0])
        for index in 0..<Int(samples.frameLength) {
            channel[index] = Float(sin(Double(index) * 2 * .pi * 440 / format.sampleRate) * 0.2)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: samples)
        }
        let clip = TimelineClip(name: "Music", source: ClipSource(url: url, mediaType: .audio,
            originalDuration: 1.05), timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1.05))
        let project = EditorProject(title: "Short audio track",
            tracks: [TimelineTrack(name: "Music", kind: .audio, clips: [clip])])
        let service = CompositionRenderService(previewProxyStore: nil)
        let preview = try #require(try await service.preparePreview(for: project, quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology, .audioMix]))
        let track = try #require(preview.composition.tracks.first { $0.mediaType == .audio })
        #expect(track.segments.contains { !$0.isEmpty })
        #expect(abs(track.timeRange.end.seconds - 1) < 0.002)
        let reader = try AVAssetReader(asset: preview.composition)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        #expect(reader.startReading())
        let first = try #require(output.copyNextSampleBuffer())
        #expect(first.presentationTimeStamp.seconds < 0.01)
        #expect(first.numSamples > 0)
        reader.cancelReading()
        let exported = try await service.makeComposition(for: project)
        #expect(exported.composition.tracks.contains { $0.mediaType == .audio })
    }

    @MainActor
    @Test func repeatedRemappedClipsShareTheirSourceDecoder() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = ClipSource(url: url, mediaType: .video, originalDuration: 4,
                                naturalSize: CGSizeValue(width: 160, height: 96))
        let first = TimelineClip(name: "First", source: source, timelineStart: 0,
                                 sourceRange: TimeRangeValue(start: 0, duration: 4))
        let second = TimelineClip(name: "Second", source: source, timelineStart: 4,
                                  sourceRange: TimeRangeValue(start: 0, duration: 4))
        let overlap = TimelineClip(name: "Overlap", source: source, timelineStart: 2,
                                   sourceRange: TimeRangeValue(start: 0, duration: 4))
        var project = EditorProject(title: "Repeated source",
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [first, second]),
                     TimelineTrack(name: "Overlay", kind: .visual, clips: [overlap])])
        var map = SpeedMap.constant
        map.timeRemap = try #require(TimeRemap(sourceDuration: 4, timelineDuration: 4))
        project.setSpeedMap(for: first.id, speedMap: map)
        project.setSpeedMap(for: second.id, speedMap: map)
        project.setSpeedMap(for: overlap.id, speedMap: map)
        let service = CompositionRenderService(previewProxyStore: nil)
        let preview = try #require(try await service.preparePreview(for: project, quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology]))
        let instruction = try #require(preview.videoComposition?.instructions.first as? MotionaryVideoCompositionInstruction)
        let firstDecoder = try #require(instruction.clips.first { $0.clipID == first.id }?.temporalSource?.remapVideo?.decoder)
        let secondDecoder = try #require(instruction.clips.first { $0.clipID == second.id }?.temporalSource?.remapVideo?.decoder)
        let overlapDecoder = try #require(instruction.clips.first { $0.clipID == overlap.id }?.temporalSource?.remapVideo?.decoder)
        #expect(firstDecoder === secondDecoder)
        #expect(firstDecoder !== overlapDecoder)
    }

    @MainActor
    @Test func undoOfRemappedSourceTimeRestoresTheDisplayedFrame() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = TimelineClip(name: "Undo remap", source: ClipSource(url: url, mediaType: .video,
            originalDuration: 4, naturalSize: CGSizeValue(width: 160, height: 96)),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 4))
        let track = TimelineTrack(name: "Video", kind: .visual, clips: [clip])
        var project = EditorProject(title: "Undo remap",
            renderSettings: RenderSettings(width: 160, height: 96, frameRate: 30), tracks: [track])
        var speed = SpeedMap.constant
        speed.timeRemap = try #require(TimeRemap(sourceDuration: 4, timelineDuration: 4))
        project.setSpeedMap(for: clip.id, speedMap: speed)
        let model = EditorViewModel(projectID: UUID(), projectStore: ProjectStore(),
                                    initialContent: ProjectContent(editorProject: project))
        defer { model.stop() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 160, height: 96))
        let host = UIViewController()
        window.rootViewController = host
        let playerView = PreviewRendererView.Host(frame: host.view.bounds)
        playerView.playbackLayer = AVPlayerLayer()
        host.view.addSubview(playerView)
        window.isHidden = false
        let playerBinding = model.$player.sink { playerView.playbackLayer?.player = $0 }
        defer { playerBinding.cancel(); window.isHidden = true }
        model.selectTimelineItem(clip.id, trackID: track.id)
        model.updateCurrentTime(1)
        await model.rebuildPreview(seekTo: 1, invalidation: [.previewFrame, .compositionTopology, .audioMix],
                                   generation: model.previewGeneration)
        let session = try #require(model.beginSelectedTimeRemapEdit(itemID: clip.id))
        model.setSelectedRemappedSourceTime(3.2, in: session)
        model.finishInteractiveEdit(delayRebuild: false)
        await model.rebuildTask?.value
        let editedExpected = try await nativeSourcePixel(url: url, at: CMTime(seconds: 3.2, preferredTimescale: 600))
        let context = CIContext()
        var editedMatched = false
        for _ in 0..<200 {
            if let frame = model.livePreviewPresentation.frame
                ?? model.renderService.livePreviewState.cachedFrame(at: 1, sessionID: model.previewRenderSessionID),
                let image = context.createCGImage(CIImage(cvPixelBuffer: frame),
                    from: CGRect(x: 0, y: 0, width: 160, height: 96)),
                zip(pixel(image), editedExpected).allSatisfy({ abs(Int($0) - Int($1)) < 8 })
            {
                editedMatched = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(editedMatched, "The edited frame must be shown before testing undo")
        // A paused playhead can be between project frames after a scroll or
        // a playback stop. Undo and redo must still replace the visible frame.
        model.updateCurrentTime(1.017)
        model.undo()
        await model.rebuildTask?.value
        guard case .media(let restored) = model.selectedTimelineItem else {
            Issue.record("Expected remapped video")
            return
        }
        #expect(abs(restored.speedMap.sourceTime(at: 1, sourceDuration: 4) - 1) < 0.000_001)
        let instruction = try #require(model.player?.currentItem?.videoComposition?.instructions.first
            as? MotionaryVideoCompositionInstruction)
        let temporal = try #require(instruction.clips.first?.temporalSource)
        #expect(abs(temporal.speedMap.sourceTime(at: 1, sourceDuration: 4) - 1) < 0.000_001)
        let expected = try await nativeSourcePixel(url: url, at: CMTime(seconds: 1, preferredTimescale: 600))
        var matched = false
        for _ in 0..<200 {
            if let frame = model.livePreviewPresentation.frame
                ?? model.renderService.livePreviewState.cachedFrame(at: 1, sessionID: model.previewRenderSessionID),
                let image = context.createCGImage(CIImage(cvPixelBuffer: frame),
                    from: CGRect(x: 0, y: 0, width: 160, height: 96))
            {
                let actual = pixel(image)
                if zip(actual, expected).allSatisfy({ abs(Int($0) - Int($1)) < 8 }) {
                    matched = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(matched, "Undo should replace the live edit with the restored source frame")
        model.redo()
        await model.rebuildTask?.value
        var redoneMatched = false
        for _ in 0..<200 {
            if let frame = model.livePreviewPresentation.frame
                ?? model.renderService.livePreviewState.cachedFrame(at: 1, sessionID: model.previewRenderSessionID),
                let image = context.createCGImage(CIImage(cvPixelBuffer: frame),
                    from: CGRect(x: 0, y: 0, width: 160, height: 96)),
                zip(pixel(image), editedExpected).allSatisfy({ abs(Int($0) - Int($1)) < 8 })
            {
                redoneMatched = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(redoneMatched, "Redo should display the edited source frame at a fractional playhead position")
    }

    @MainActor
    @Test func remapDecoderKeepsCorrectFramesAcrossLargeScrubJumps() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let decoder = RemapFrameDecoder(asset: asset, track: track,
            range: try await track.load(.timeRange), rawSize: CGSize(width: 160, height: 96), frameRate: 30)
        let context = CIContext()
        for frame in [2, 61, 12, 91, 60, 32, 95, 29] {
            let time = CMTime(value: Int64(frame), timescale: 30)
            let image = CIImage(cvPixelBuffer: try decoder.frame(at: time))
            let actual = pixel(try #require(context.createCGImage(image, from: image.extent)))
            let expected = try await nativeSourcePixel(url: url, at: time)
            #expect(zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) < 8 })
        }
    }

    @MainActor
    @Test func remappedAudioDoesNotOutlastTheVideoClockAtFractionalProjectEnd() async throws {
        let videoURL = try await makeVideo()
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("fractional-remap-\(UUID()).caf")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
        }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / format.sampleRate) * 0.2)
        }
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let duration = 3.643939393939394
        let video = TimelineClip(
            name: "Video", source: ClipSource(url: videoURL, mediaType: .video, originalDuration: 4,
                naturalSize: CGSizeValue(width: 160, height: 96)),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: duration))
        let audio = TimelineClip(
            name: "Audio", source: ClipSource(url: audioURL, mediaType: .audio, originalDuration: 4),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: duration))
        var project = EditorProject(
            title: "Fractional end", renderSettings: RenderSettings(width: 160, height: 96, frameRate: 60),
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [video]),
                     TimelineTrack(name: "Audio", kind: .audio, clips: [audio])])
        var remap = try #require(TimeRemap(sourceDuration: duration, timelineDuration: duration))
        remap.setSourceTime(2.4166666666666665, at: 2, tolerance: 0.001)
        remap.setSourceTime(1.85, at: 2.216666666666667, tolerance: 0.001)
        remap.setSourceTime(2.5833333333333335, at: 2.4166666666666665, tolerance: 0.001)
        var speed = SpeedMap.constant
        speed.timeRemap = remap
        project.setSpeedMap(for: audio.id, speedMap: speed)
        let service = CompositionRenderService(previewProxyStore: nil)
        let preview = try #require(try await service.preparePreview(
            for: project, quality: .balanced, invalidation: [.previewFrame, .compositionTopology]))
        let audioTrack = try #require(preview.composition.tracks.first { $0.mediaType == .audio })
        let clockID = try #require(preview.videoComposition?.sourceTrackIDForFrameTiming)
        let clock = try #require(preview.composition.track(withTrackID: clockID))
        #expect(audioTrack.timeRange.end <= clock.timeRange.end)
        #expect(audioTrack.segments.filter { !$0.isEmpty }.count == 1)
        let native = try await service.makeComposition(for: project)
        let nativeTrack = try #require(native.composition.tracks(withMediaType: .audio).first)
        #expect(nativeTrack.segments.filter { !$0.isEmpty }.count >= 3)
        #expect(nativeTrack.timeRange.end == audioTrack.timeRange.end)
        let probe = PlayerFrameProbe(asset: preview.composition, videoComposition: preview.videoComposition)
        for seconds in [0.0, 1.0, 2.05, 2.3, 3.0] {
            _ = try await probe.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        }
    }

    @MainActor
    @Test func densePersistedRemapRendersAfterRepeatedDirectionChanges() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = TimelineClip(
            name: "Dense remap",
            source: ClipSource(url: url, mediaType: .video, originalDuration: 4,
                               naturalSize: CGSizeValue(width: 160, height: 96)),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 4))
        var project = EditorProject(
            title: "Dense remap",
            renderSettings: RenderSettings(width: 160, height: 96, frameRate: 30),
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
        var remap = try #require(TimeRemap(sourceDuration: 4, timelineDuration: 4))
        for index in 1..<40 {
            let time = Double(index) / 10
            remap.setSourceTime(index.isMultiple(of: 2) ? 0.5 : 3.5, at: time, tolerance: 0.001)
        }
        remap = try JSONDecoder().decode(TimeRemap.self, from: JSONEncoder().encode(remap))
        var speed = SpeedMap.constant
        speed.timeRemap = remap
        project.setSpeedMap(for: clip.id, speedMap: speed)
        let service = CompositionRenderService(previewProxyStore: nil)
        let preview = try #require(try await service.preparePreview(
            for: project, quality: .balanced, invalidation: [.previewFrame, .compositionTopology]))
        let probe = PlayerFrameProbe(asset: preview.composition, videoComposition: preview.videoComposition)
        let context = CIContext()
        for frame in [3, 6, 15, 30, 57, 87, 114] {
            let time = CMTime(value: Int64(frame), timescale: 30)
            let image = try await probe.image(at: time)
            let actual = pixel(try #require(context.createCGImage(image, from: image.extent)))
            let expected = try await nativeSourcePixel(url: url, at: CMTime(
                seconds: remap.sourceTime(at: time.seconds), preferredTimescale: 60_000))
            #expect(zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) < 8 })
        }
    }

    @MainActor
    @Test func remapSourceTimeChangesCanRenderWithoutReplacingThePreviewItem() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = TimelineClip(
            name: "Live source time",
            source: ClipSource(url: url, mediaType: .video, originalDuration: 4,
                               naturalSize: CGSizeValue(width: 160, height: 96)),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 4))
        var project = EditorProject(
            title: "Live remap",
            renderSettings: RenderSettings(width: 160, height: 96, frameRate: 30),
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
        var remap = try #require(TimeRemap(sourceDuration: 4, timelineDuration: 4))
        var speed = SpeedMap.constant
        speed.timeRemap = remap
        project.setSpeedMap(for: clip.id, speedMap: speed)

        let service = CompositionRenderService(previewProxyStore: nil)
        let sessionID = UUID()
        let preview = try #require(try await service.preparePreview(
            for: project, quality: .balanced, invalidation: [.previewFrame, .compositionTopology],
            renderSessionID: sessionID))
        let probe = PlayerFrameProbe(asset: preview.composition, videoComposition: preview.videoComposition)
        let time = CMTime(value: 15, timescale: 30)
        _ = try await probe.image(at: time)
        let context = CIContext()
        for sourceTime in [2.5, 0.5, 4, 1.5, 3.5, 0] {
            remap.setSourceTime(sourceTime, at: time.seconds, tolerance: 0.001)
            speed.timeRemap = remap
            service.livePreviewState.setSpeedMap(speed, for: clip.id)
            let frame: CVPixelBuffer? = await withCheckedContinuation { continuation in
                if !service.livePreviewState.renderPausedFrame(at: time.seconds, sessionID: sessionID,
                    completion: { continuation.resume(returning: $0) })
                {
                    continuation.resume(returning: nil)
                }
            }
            let image = CIImage(cvPixelBuffer: try #require(frame))
            let actual = pixel(try #require(context.createCGImage(image, from: image.extent)))
            let expected = try await nativeSourcePixel(url: url, at: CMTime(
                seconds: min(sourceTime, 119.0 / 30), preferredTimescale: 60_000))
            #expect(zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) < 8 },
                    "Live edit at source \(sourceTime): \(actual), expected \(expected)")
        }
    }

    @MainActor
    @Test func extendedRemapWithoutKeyframesRendersTheHeldSourceFrame() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = TimelineClip(
            name: "Held frame",
            source: ClipSource(url: url, mediaType: .video, originalDuration: 4,
                               naturalSize: CGSizeValue(width: 160, height: 96)),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 4))
        var project = EditorProject(
            title: "Extended held frame",
            renderSettings: RenderSettings(width: 160, height: 96, frameRate: 30),
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
        var remap = try #require(TimeRemap(sourceDuration: 4, timelineDuration: 4))
        remap.toggleKeyframe(at: 0, tolerance: 0.001)
        remap.toggleKeyframe(at: 4, tolerance: 0.001)
        remap.setSourceTime(1.5, at: 1, tolerance: 0.001)
        remap = remap.sliced(fromTimelineTime: 0, duration: 6)
        var speed = SpeedMap.constant
        speed.timeRemap = remap
        project.setSpeedMap(for: clip.id, speedMap: speed)
        let service = CompositionRenderService(previewProxyStore: nil)
        let preview = try #require(try await service.preparePreview(
            for: project, quality: .balanced, invalidation: [.previewFrame, .compositionTopology]))
        let probe = PlayerFrameProbe(asset: preview.composition, videoComposition: preview.videoComposition)
        let expected = try await nativeSourcePixel(url: url, at: CMTime(seconds: 1.5, preferredTimescale: 600))
        let context = CIContext()
        for seconds in [0.5, 3.5, 5.9] {
            let image = try await probe.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            let actual = pixel(try #require(context.createCGImage(image, from: image.extent)))
            #expect(zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) < 8 })
        }
    }

    @MainActor
    @Test func retimedPreviewMixKeepsMusicAtStartAndUpdatesInPlaceAfterVolumeEdit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-mix-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / format.sampleRate) * 0.3)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let source = ClipSource(url: url, mediaType: .audio, originalDuration: 2)
        let retimed = TimelineClip(
            name: "Retimed", source: source, timelineStart: 0.5,
            sourceRange: TimeRangeValue(start: 0, duration: 2))
        let music = TimelineClip(
            name: "Music", source: source, timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2))
        var project = EditorProject(title: "Mixed preview audio", tracks: [
            TimelineTrack(name: "Retimed", kind: .audio, clips: [retimed]),
            TimelineTrack(name: "Music", kind: .audio, clips: [music]),
        ])
        var remap = try #require(TimeRemap(sourceDuration: 2, timelineDuration: 1.5))
        remap.setInterpolation(KeyframeCurvePreset.easeInOut.interpolation, at: 0)
        var map = SpeedMap.constant
        map.timeRemap = remap
        project.setSpeedMap(for: retimed.id, speedMap: map)

        let service = CompositionRenderService(previewProxyStore: nil)
        let first = try #require(try await service.preparePreview(
            for: project, quality: .balanced, invalidation: [.compositionTopology, .audioMix]))
        #expect(first.composition.tracks(withMediaType: .audio).count == 2)
        let loudPeak = try Self.earlyAudioPeak(of: first)
        #expect(loudPeak > 0.15)

        let location = try #require(project.itemLocation(id: music.id))
        guard case .media(var item) = project.tracks[location.track].items[location.item] else {
            Issue.record("Expected music clip")
            return
        }
        item.visuals.volume = AnimatableProperty(baseValue: 0.25)
        project.replaceItem(id: music.id, with: .media(item))
        let edited = try #require(try await service.preparePreview(
            for: project, quality: .balanced, invalidation: [.audioMix]))
        #expect(!edited.topologyWasRebuilt)
        #expect(edited.composition === first.composition)
        let quietPeak = try Self.earlyAudioPeak(of: edited)
        #expect(quietPeak > loudPeak * 0.15 && quietPeak < loudPeak * 0.36)
    }

    @MainActor
    @Test func extractedMovieAudioStartsAtTheRetainedSourceTimeAfterASeek() async throws {
        let videoURL = try await makeVideo()
        let folder = FileManager.default.temporaryDirectory
        let audioURL = folder.appendingPathComponent("seek-audio-\(UUID()).caf")
        let movieURL = folder.appendingPathComponent("seek-movie-\(UUID()).mov")
        defer {
            for url in [videoURL, audioURL, movieURL] { try? FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: PreviewRetimedAudio.directory(for: movieURL))
        }

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 168_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            let amplitude: Float = frame < 96_000 ? 0.05 : 0.45
            samples[frame] = amplitude * Float(sin(Double(frame) * 2 * .pi * 440 / format.sampleRate))
        }
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }

        let movie = AVMutableComposition()
        let video = try #require(try await AVURLAsset(url: videoURL).loadTracks(withMediaType: .video).first)
        let audio = try #require(try await AVURLAsset(url: audioURL).loadTracks(withMediaType: .audio).first)
        let videoTrack = try #require(movie.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try #require(movie.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(try await video.load(.timeRange), of: video, at: .zero)
        try audioTrack.insertTimeRange(try await audio.load(.timeRange), of: audio, at: CMTime(value: 1, timescale: 2))
        let export = try #require(AVAssetExportSession(asset: movie, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: movieURL, as: .mov)

        let clip = TimelineClip(
            name: "Extracted audio",
            source: ClipSource(url: movieURL, mediaType: .audio, originalDuration: 4),
            timelineStart: 1,
            sourceRange: TimeRangeValue(start: 0.75, duration: 3)
        )
        var project = EditorProject(title: "Movie audio seek", tracks: [
            TimelineTrack(name: "Audio", kind: .audio, clips: [clip])
        ])
        let item = try #require(project.item(id: clip.id))
        project.tracks[0].items = [try #require(item.split(at: 1)).right]
        let service = CompositionRenderService(previewProxyStore: nil)
        let preview = try #require(try await service.preparePreview(
            for: project, quality: .balanced, invalidation: [.compositionTopology, .audioMix]))
        let track = try #require(preview.composition.tracks(withMediaType: .audio).first)
        let segment = try #require(track.segments.first { !$0.isEmpty })
        #expect(segment.sourceURL?.pathExtension == "caf")
        #expect(segment.timeMapping.source.start == .zero)
        #expect(segment.timeMapping.target.start.seconds == 2)
        #expect(try Self.earlyAudioPeak(of: preview, at: 2.25) < 0.1)
        #expect(try Self.earlyAudioPeak(of: preview, at: 3) > 0.35)
    }

    private static func earlyAudioPeak(of preview: PreparedPreview, at time: Double = 0) throws -> Float {
        let composition = preview.composition
        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 600),
                                       duration: CMTime(value: 1, timescale: 25))
        let output = AVAssetReaderAudioMixOutput(audioTracks: composition.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = preview.audioMix
        try #require(reader.canAdd(output))
        reader.add(output)
        try #require(reader.startReading())
        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer(), let block = sample.dataBuffer {
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.stride)
            try #require(!values.isEmpty)
            let status = values.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            try #require(status == noErr)
            peak = max(peak, values.lazy.map { abs($0) }.max() ?? 0)
        }
        try #require(reader.status == .completed)
        return peak
    }

    @Test func audioRemappingKeepsContinuousTrackEditsAndTheSelectedPitchMode() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remap-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000))
        buffer.frameLength = 144_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / format.sampleRate) * 0.3)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let clip = TimelineClip(
            name: "Remapped audio",
            source: ClipSource(url: url, mediaType: .audio, originalDuration: 3),
            timelineStart: 0.5, sourceRange: TimeRangeValue(start: 0.25, duration: 2))
        var project = EditorProject(
            title: "Time Remapping Audio",
            tracks: [TimelineTrack(name: "Audio", kind: .audio, clips: [clip])])
        var remap = try #require(TimeRemap(sourceDuration: 2, timelineDuration: 1.5))
        remap.setInterpolation(KeyframeCurvePreset.easeInOut.interpolation, at: 0)
        var map = SpeedMap.constant
        map.timeRemap = remap
        project.setSpeedMap(for: clip.id, speedMap: map)

        let service = CompositionRenderService()
        let rendered = try await service.makeComposition(for: project)
        let track = try #require(rendered.composition.tracks(withMediaType: .audio).first)
        let edits = track.segments.filter { !$0.isEmpty }
        #expect(edits.count > 1)
        #expect(edits.first?.timeMapping.target.start.seconds == 0.5)
        #expect(edits.last?.timeMapping.target.end.seconds == 2)
        #expect(edits.first?.timeMapping.source.start.seconds == 0.25)
        #expect(edits.last?.timeMapping.source.end.seconds == 2.25)
        #expect(zip(edits, edits.dropFirst()).allSatisfy {
            $0.timeMapping.target.end == $1.timeMapping.target.start
                && $0.timeMapping.source.end == $1.timeMapping.source.start
        })
        #expect(rendered.audioMix?.inputParameters.first?.audioTimePitchAlgorithm == .timeDomain)

        let location = try #require(project.itemLocation(id: clip.id))
        guard case .media(var media) = project.tracks[location.track].items[location.item] else {
            Issue.record("Expected audio media")
            return
        }
        let fixedPitch = try #require(try await service.preparePreview(for: project, quality: .balanced,
            invalidation: [.compositionTopology, .audioMix]))
        let fixedTrack = try #require(fixedPitch.composition.tracks(withMediaType: .audio).first)
        let fixedSegment = try #require(fixedTrack.segments.first { !$0.isEmpty })
        #expect(fixedTrack.segments.filter { !$0.isEmpty }.count == 1)
        media.pitchFollowsSpeed = true
        project.replaceItem(id: clip.id, with: .media(media))
        let changedPitch = try #require(try await service.preparePreview(for: project, quality: .balanced,
            invalidation: [.audioMix]))
        #expect(changedPitch.topologyWasRebuilt)
        let changedTrack = try #require(changedPitch.composition.tracks(withMediaType: .audio).first)
        let changedSegment = try #require(changedTrack.segments.first { !$0.isEmpty })
        #expect(changedSegment.sourceURL != fixedSegment.sourceURL)
        #expect(changedSegment.timeMapping.target == fixedSegment.timeMapping.target)
        let pitchFollowsSpeed = try await service.makeComposition(for: project)
        #expect(pitchFollowsSpeed.audioMix?.inputParameters.first?.audioTimePitchAlgorithm == .varispeed)
        remap.setSourceTime(2, at: 0, tolerance: 0.001)
        remap.setSourceTime(0, at: 1, tolerance: 0.001)
        remap.setSourceTime(0, at: 1.5, tolerance: 0.001)
        map.timeRemap = remap
        project.setSpeedMap(for: clip.id, speedMap: map)
        let reversed = try await service.makeComposition(for: project)
        let reversedTrack = try #require(reversed.composition.tracks(withMediaType: .audio).first)
        let firstEdit = try #require(reversedTrack.segments.first { !$0.isEmpty })
        let reversedURL = try #require(firstEdit.sourceURL)
        #expect(reversedURL != url)
        let audibleEnd = reversedTrack.segments.last { !$0.isEmpty }?.timeMapping.target.end.seconds
        #expect(audibleEnd == 1.5)
        #expect(reversed.composition.duration.seconds >= 2)

        let originalPCM = try AVAudioFile(forReading: url)
        let reversedPCM = try AVAudioFile(forReading: reversedURL)
        let originalTail = try #require(AVAudioPCMBuffer(pcmFormat: originalPCM.processingFormat, frameCapacity: 32))
        let reversedHead = try #require(AVAudioPCMBuffer(pcmFormat: reversedPCM.processingFormat, frameCapacity: 32))
        originalPCM.framePosition = originalPCM.length - 32
        try originalPCM.read(into: originalTail)
        try reversedPCM.read(into: reversedHead)
        let tail = try #require(originalTail.floatChannelData?[0])
        let head = try #require(reversedHead.floatChannelData?[0])
        for index in 0..<32 { #expect(abs(tail[31 - index] - head[index]) < 0.0001) }

    }

    @MainActor
    @Test func previewReusesTheSourceDecoderWhenItsTimelineMappingChanges() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = TimelineClip(
            name: "Remapped source",
            source: ClipSource(url: url, mediaType: .video, originalDuration: 4),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        var project = EditorProject(title: "Source decoder reuse", tracks: [
            TimelineTrack(name: "Video", kind: .visual, clips: [clip])
        ])
        var map = SpeedMap.constant
        map.timeRemap = try #require(TimeRemap(sourceDuration: 4, timelineDuration: 4))
        project.setSpeedMap(for: clip.id, speedMap: map)
        let service = CompositionRenderService(previewProxyStore: nil)

        let original = try #require(try await service.preparePreview(
            for: project, quality: .balanced, invalidation: [.previewFrame, .compositionTopology, .audioMix]))
        let originalInstruction = try #require(
            original.videoComposition?.instructions.first as? MotionaryVideoCompositionInstruction)
        let originalSource = try #require(originalInstruction.clips.first?.temporalSource)

        map.timeRemap = try #require(TimeRemap(sourceDuration: 4, timelineDuration: 2))
        project.setSpeedMap(for: clip.id, speedMap: map)
        let updated = try #require(try await service.preparePreview(
            for: project, quality: .balanced, invalidation: [.previewFrame, .compositionTopology, .audioMix]))
        let updatedInstruction = try #require(
            updated.videoComposition?.instructions.first as? MotionaryVideoCompositionInstruction)
        let updatedSource = try #require(updatedInstruction.clips.first?.temporalSource)

        #expect(updated.topologyWasRebuilt)
        #expect(updatedSource.speedMap == map)
        let decoder = try #require(originalSource.remapVideo?.decoder)
        #expect(updatedSource.remapVideo?.decoder === decoder)
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
