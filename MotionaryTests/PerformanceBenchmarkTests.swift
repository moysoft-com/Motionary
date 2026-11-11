import AVFoundation
import CoreImage
import CryptoKit
import Testing
import UIKit

@testable import Motionary

@Suite(.serialized)
struct PerformanceBenchmarkTests {
    @MainActor @Test func denseEffects() async throws {
        let project = try makeProject()
        let service = CompositionRenderService()
        let session = UUID()
        let clock = ContinuousClock()
        let preparationStart = clock.now
        let preview = try #require(
            try await service.preparePreview(
                for: project, quality: .balanced,
                invalidation: [.previewFrame, .compositionTopology], renderSessionID: session
            ))
        print("PERF prepare \(milliseconds(preparationStart.duration(to: clock.now))) ms")
        let generator = AVAssetImageGenerator(asset: preview.composition)
        generator.videoComposition = preview.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for i in 0..<4 {
            _ = try await generator.image(at: CMTime(value: Int64(i + 10), timescale: 30))
        }

        let ci = CIContext()
        var hash = SHA256()
        var timings: [Double] = []
        for i in 0..<30 {
            let time = CMTime(value: Int64(16 + (i * 13) % 49), timescale: 30)
            let start = clock.now
            let image = try await generator.image(at: time).image
            timings.append(milliseconds(start.duration(to: clock.now)))
            digest(image, context: ci, into: &hash)
        }
        report("random seek", timings)
        print("PERF preview hash \(hash.finalize())")

        let seek = CMTime(value: 31, timescale: 30)
        _ = try await generator.image(at: seek)
        service.livePreviewState.setInteractiveQualityOverride(true)
        var live: [Double] = []
        var liveHash = SHA256()
        let movingID = project.tracks[3].items[4].id
        for i in 0..<35 {
            var transform = ClipTransform()
            transform.positionX.baseValue = Double(i % 13 - 6) / 20
            let start = clock.now
            service.livePreviewState.setTransform(transform, for: movingID)
            let buffer: CVPixelBuffer? = await withCheckedContinuation { continuation in
                if !service.livePreviewState.renderPausedFrame(
                    at: seek.seconds, sessionID: session,
                    completion: { continuation.resume(returning: $0) })
                {
                    continuation.resume(returning: nil)
                }
            }
            let rendered = try #require(buffer)
            if i >= 5 {
                live.append(milliseconds(start.duration(to: clock.now)))
                let image = CIImage(cvPixelBuffer: rendered)
                digest(image, context: ci, into: &liveHash)
            }
        }
        report("live edit", live)
        print("PERF live hash \(liveHash.finalize())")

        service.livePreviewState.setInteractiveQualityOverride(false)
        service.livePreviewState.clearOverride(for: movingID)
        try await measurePlayback(preview)

        let start = clock.now
        let url = try await VideoExportService().export(
            project: project,
            settings: .recommended(for: project), progress: { _ in })
        print("PERF export \(milliseconds(start.duration(to: clock.now))) ms")
        defer { try? FileManager.default.removeItem(at: url) }
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        exported.requestedTimeToleranceBefore = .zero
        exported.requestedTimeToleranceAfter = .zero
        var exportHash = SHA256()
        for frame in [0, 14, 15, 16, 31, 57, 80] {
            let image = try await exported.image(at: CMTime(value: Int64(frame), timescale: 30)).image
            digest(image, context: ci, into: &exportHash)
        }
        print("PERF export hash \(exportHash.finalize())")
    }

    @MainActor @Test func editorInputWith2400Cuts() throws {
        let media = MediaAsset(
            id: MediaID(),
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/perf-input.mp4"),
                mediaType: .video, originalDuration: 2))
        let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .waveWarp))
        let tracks = (0..<24).map { lane in
            let items = (0..<100).map { cut in
                var clip = MediaTimelineItem(
                    name: "Clip \(cut)", mediaID: media.id, mediaType: .video,
                    timelineStart: Double(cut) * 0.25, sourceRange: TimeRangeValue(start: 0, duration: 0.25))
                clip.visuals.effectStack = EffectStack(effects: [effect])
                return TimelineItem.media(clip)
            }
            return TimelineTrack(name: "Track \(lane)", kind: .visual, items: items)
        }
        let project = EditorProject(title: "Dense editor input", mediaLibrary: [media.id: media], tracks: tracks)
        let model = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project))
        defer { model.stop() }
        let item = try #require(tracks.last?.items.last)
        model.updateSelection(clipID: item.id, trackID: tracks.last?.id)
        let clock = ContinuousClock()
        var transport: [Double] = []
        for i in 0..<600 {
            let time = Double(i) / 30
            let start = clock.now
            model.updateCurrentTime(model.clampedPlayableTime(time))
            transport.append(milliseconds(start.duration(to: clock.now)))
        }
        #expect(model.currentTime == 599.0 / 30)
        report("2400 cuts transport main actor", Array(transport.dropFirst(20)))

        model.updateCurrentTime(item.timelineStart + 0.1)
        var slider: [Double] = []
        for i in 0..<800 {
            let start = clock.now
            model.setSelectedKeyframeValue(
                Double(i % 50) / 50,
                target: .effectMix(effect.id), interactive: true)
            slider.append(milliseconds(start.duration(to: clock.now)))
        }
        #expect(model.selectedTimelineItem?.editableVisuals?.effectStack.effects.first?.mix.baseValue == 0.98)
        #expect(model.project.mediaLibrary == project.mediaLibrary)
        #expect(model.duration == project.duration)
        report("2400 cuts effect slider main actor", Array(slider.dropFirst(20)))
        model.finishInteractiveEdit(rebuild: false)
        #expect(model.undoStack.count == 1)
        model.undo()
        #expect(model.project.tracks == project.tracks)
        model.project.tracks[0].items[0].timelineStart = 30
        #expect(model.duration == 30.25)
    }

    @MainActor @Test func previewPreparationWith2400GeneratedCuts() async throws {
        let tracks = (0..<24).map { lane in
            let mediaID = MediaID()
            let items = (0..<100).map { cut in
                TimelineItem.shape(
                    ShapeTimelineItem(
                        name: "Shape", mediaID: mediaID,
                        shape: ClipShape(kind: .rectangle, color: .white, width: 200, height: 120),
                        timelineStart: Double(cut * 150 + lane) / 600,
                        sourceRange: TimeRangeValue(start: 0, duration: 0.25)))
            }
            return TimelineTrack(name: "Shape \(lane)", kind: .shape, items: items)
        }
        let project = EditorProject(
            title: "Dense preview preparation",
            renderSettings: RenderSettings(width: 960, height: 540, frameRate: 30), tracks: tracks)
        let service = CompositionRenderService()
        _ = try await service.preparePreview(
            for: project, quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology])
        var timings: [Double] = []
        let clock = ContinuousClock()
        var instructionCount = 0
        for _ in 0..<12 {
            let start = clock.now
            let preview = try #require(
                try await service.preparePreview(
                    for: project, quality: .balanced, invalidation: [.previewFrame]
                ))
            timings.append(milliseconds(start.duration(to: clock.now)))
            let composition = try #require(preview.videoComposition)
            instructionCount = composition.instructions.count
            #expect(composition.sourceTrackIDForFrameTiming != kCMPersistentTrackID_Invalid)
        }
        report("2400 generated cuts descriptor refresh", Array(timings.dropFirst(2)))
        print("PERF 2400 generated cuts instructions=\(instructionCount)")
        #expect(instructionCount == 1)
    }

    @MainActor @Test func scrubThroughDecodedCutsWithEffects() async throws {
        var project = try makeProject()
        var sourceProject = project
        sourceProject.tracks = Array(project.tracks.suffix(2))
        let url = try await VideoExportService().export(
            project: sourceProject,
            settings: .recommended(for: sourceProject), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }

        let media = MediaAsset(
            id: MediaID(),
            source: ClipSource(
                url: url, mediaType: .video,
                originalDuration: 3, naturalSize: CGSizeValue(width: 960, height: 540)))
        project.mediaLibrary[media.id] = media
        for lane in 0..<3 {
            let items = (0..<12).map { cut in
                var item = MediaTimelineItem(
                    name: "Video cut \(cut)", mediaID: media.id, mediaType: .video,
                    timelineStart: Double(cut) * 0.25 + Double(lane) / 30,
                    sourceRange: TimeRangeValue(start: Double((cut * 7 + lane * 11) % 60) / 30, duration: 0.25))
                item.visuals.transform.scale.baseValue = ScaleValue(x: 0.8, y: 0.8)
                item.visuals.transform.positionX.baseValue = Double(lane - 1) / 4
                item.visuals.transform.opacity.baseValue = 0.75
                return TimelineItem.media(item)
            }
            project.tracks.append(TimelineTrack(name: "Video layer \(lane)", kind: .visual, items: items))
        }

        let model = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project))
        defer { model.stop() }
        let prepared = try #require(
            try await model.renderService.preparePreview(
                for: project, quality: .balanced, invalidation: [.previewFrame, .compositionTopology],
                renderSessionID: model.previewRenderSessionID
            ))
        let videoTracks = try await prepared.composition.loadTracks(withMediaType: .video)
        print("PERF decoded project video composition tracks=\(videoTracks.count)")
        #expect(videoTracks.count == 7)
        if Self.supportsExactDecodedReference {
            let referenceService = CompositionRenderService(reusesPreviewVideoTracks: false)
            let reference = try #require(
                try await referenceService.preparePreview(
                    for: project, quality: .balanced, invalidation: [.previewFrame, .compositionTopology]
                ))
            let referenceVideoTracks = try await reference.composition.loadTracks(withMediaType: .video)
            #expect(referenceVideoTracks.count == 37)
            let context = CIContext()
            func frameDigest(asset: AVAsset, composition: AVVideoComposition?) async throws -> SHA256.Digest {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.videoComposition = composition
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                var hash = SHA256()
                for frame in [4, 7, 8, 9, 15, 21, 31, 43, 66, 72, 83, 87] {
                    let time = CMTime(value: Int64(frame), timescale: 30)
                    digest(try await generator.image(at: time).image, context: context, into: &hash)
                }
                return hash.finalize()
            }
            let pooledDigest = try await frameDigest(
                asset: prepared.composition, composition: prepared.videoComposition)
            let separateDigest = try await frameDigest(
                asset: reference.composition, composition: reference.videoComposition)
            print("PERF decoded exact preview hash \(pooledDigest); separate tracks hash \(separateDigest)")
            #expect(pooledDigest == separateDigest)
        }
        let item = AVPlayerItem(asset: prepared.composition)
        item.videoComposition = prepared.videoComposition
        model.replacePreviewPlayer(with: item)
        model.installPreviewItemHealthObservers(for: item)
        let player = try #require(model.player)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        let preview = PreviewPlayerContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        preview.playerLayer.player = player
        host.view.addSubview(preview)
        defer {
            preview.playerLayer.player = nil
            window.isHidden = true
            window.rootViewController = nil
        }
        item.seekingWaitsForVideoCompositionRendering = true
        let positioned = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        try #require(positioned)
        model.beginScrub()

        let clock = ContinuousClock()
        var rendered: [Double] = []
        var input: [Double] = []
        var missed = 0
        for i in 0..<28 {
            let time = Double(4 + i * 17 % 80) / 30
            let start = clock.now
            model.updateScrub(to: time)
            let inputTime = milliseconds(start.duration(to: clock.now))
            #expect(model.currentTime == time)
            let target = model.currentScrubPresentationTime()
            func presented() -> Bool {
                guard let time = model.livePreviewPresentation.frameTime else { return false }
                return abs(time - target) <= 1 / 30 + 0.000_1
            }
            while !presented(), start.duration(to: clock.now) < .milliseconds(600) {
                try await Task.sleep(for: .milliseconds(2))
            }
            if !presented() {
                missed += 1
                print(
                    "PERF missed decoded scrub target=\(target) player=\(player.currentTime().seconds) rendered=\(String(describing: model.livePreviewPresentation.frameTime)) status=\(item.status.rawValue)"
                )
            }
            if i >= 4 {
                if presented() { rendered.append(milliseconds(start.duration(to: clock.now))) }
                input.append(inputTime)
            }
        }
        print("PERF decoded scrub missed=\(missed)/28")
        if !rendered.isEmpty { report("decoded scrub to rendered buffer", rendered) }
        #expect(missed == 0)
        report("decoded scrub input main actor", input)
        let final = 1.7
        model.endScrub(at: final)
        let end = clock.now
        while model.isScrubbing, end.duration(to: clock.now) < .seconds(5) {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(!model.isScrubbing)
        #expect(abs(player.currentTime().seconds - final) < 0.001)
        #expect(model.previewRecoveryAttemptCount == 0)
    }

    private static var supportsExactDecodedReference: Bool {
        #if targetEnvironment(simulator)
            // The iOS 18.6 simulator's image generator returns -12815 for
            // exact seeks in the unpooled reference composition.
            if #unavailable(iOS 26.0) { return false }
        #endif
        return true
    }

    @MainActor
    private func measurePlayback(_ preview: PreparedPreview) async throws {
        let item = AVPlayerItem(asset: preview.composition)
        item.videoComposition = preview.videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        defer { player.pause() }
        let clock = ContinuousClock()
        let positioned = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        try #require(positioned)
        let started = clock.now
        player.playImmediately(atRate: 1)
        var frameTimes = Set<Int64>()
        var previousArrival: ContinuousClock.Instant?
        var intervals: [Double] = []
        var heartbeat: [Double] = []
        var lastPoll = clock.now
        while started.duration(to: clock.now) < .seconds(5), player.currentTime().seconds < 2.99 {
            let now = clock.now
            heartbeat.append(milliseconds(lastPoll.duration(to: now)))
            lastPoll = now
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            var presented = CMTime.invalid
            if time.isNumeric, output.hasNewPixelBuffer(forItemTime: time),
                output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &presented) != nil,
                presented.isNumeric, frameTimes.insert(presented.convertScale(600, method: .default).value).inserted
            {
                if let previousArrival { intervals.append(milliseconds(previousArrival.duration(to: now))) }
                previousArrival = now
            }
            try await Task.sleep(for: .milliseconds(4))
        }
        print(
            "PERF playback frames=\(frameTimes.count)/90 position=\(player.currentTime().seconds) wall=\(milliseconds(started.duration(to: clock.now))) ms"
        )
        if !intervals.isEmpty { report("playback delivery intervals", intervals) }
        report("playback main actor poll", Array(heartbeat.dropFirst()))
    }

    private func makeProject() throws -> EditorProject {
        func id(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
        }
        func effect(_ module: EffectModuleID, _ value: Int) throws -> EffectInstance {
            var effect = try #require(EffectRegistry.shared.makeEffect(moduleID: module))
            effect.id = id(value)
            return effect
        }
        let tracks = try (0..<12).map { lane in
            let items = try (0..<12).map { cut in
                let index = lane * 12 + cut
                let color = RGBAColor(
                    red: Double((lane * 3 + cut) % 7) / 6,
                    green: Double((lane + cut * 3) % 11) / 10, blue: 0.8, alpha: 1)
                var item = ShapeTimelineItem(
                    id: id(index + 1), name: "Cut \(cut)", mediaID: MediaID(),
                    shape: ClipShape(
                        kind: .rectangle, color: color,
                        width: Double(180 + lane * 14), height: Double(80 + lane * 5)),
                    timelineStart: Double(cut) * 0.25, sourceRange: TimeRangeValue(start: 0, duration: 0.25))
                item.visuals.transform.positionX = AnimatableProperty(
                    baseValue: 0,
                    keyframes: [
                        Keyframe(time: 0, value: Double(lane % 4 - 2) / 3),
                        Keyframe(time: 0.25, value: Double(lane % 4 - 2) / 3 + 0.4)
                    ])
                item.visuals.transform.positionY.baseValue = Double(lane / 4 - 1) / 2
                item.visuals.transform.opacity.baseValue = 0.85
                if lane % 4 == 0 {
                    item.visuals.effectStack = EffectStack(effects: [try effect(.waveWarp, 1_000 + index)])
                }
                return TimelineItem.shape(item)
            }
            return TimelineTrack(id: id(300 + lane), name: "Layer \(lane)", kind: .shape, items: items)
        }
        var distortion = AdjustmentTimelineItem(
            id: id(400), timelineStart: 0, duration: 3,
            targets: AdjustmentLayerTargets(mode: .selected, trackIDs: Set(tracks.prefix(8).map(\.id))))
        distortion.visuals.effectStack = EffectStack(effects: [
            try effect(.waveWarp, 401), try effect(.displacementMap, 404)
        ])
        distortion.visuals.transform.positionY = AnimatableProperty(
            baseValue: 0,
            keyframes: [
                Keyframe(time: 0, value: -0.1), Keyframe(time: 3, value: 0.1)
            ])
        var blur = AdjustmentTimelineItem(id: id(402), timelineStart: 0, duration: 3)
        var motionBlur = try effect(.motionBlur, 403)
        motionBlur.parameters["shutter"] = EffectParameterState(baseValue: .scalar(360))
        blur.visuals.effectStack = EffectStack(effects: [motionBlur])
        return EditorProject(
            title: "Dense performance fixture",
            renderSettings: RenderSettings(width: 960, height: 540, frameRate: 30),
            tracks: [
                TimelineTrack(id: id(410), name: "Shutter", kind: .visual, items: [.adjustment(blur)]),
                TimelineTrack(id: id(411), name: "Distortion", kind: .visual, items: [.adjustment(distortion)])
            ] + tracks)
    }

    private func digest(_ image: CGImage, context: CIContext, into hash: inout SHA256) {
        digest(CIImage(cgImage: image), context: context, into: &hash)
    }

    private func digest(_ image: CIImage, context: CIContext, into hash: inout SHA256) {
        let row = Int(image.extent.width) * 4
        var pixels = Data(count: row * Int(image.extent.height))
        pixels.withUnsafeMutableBytes {
            context.render(
                image, toBitmap: $0.baseAddress!, rowBytes: row, bounds: image.extent,
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        hash.update(data: pixels)
    }

    private func report(_ name: String, _ times: [Double]) {
        let sorted = times.sorted()
        print(
            "PERF \(name) n=\(times.count) median=\(sorted[times.count / 2]) p95=\(sorted[Int(ceil(Double(times.count) * 0.95)) - 1]) max=\(sorted.last!) ms"
        )
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
